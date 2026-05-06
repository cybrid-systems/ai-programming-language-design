# 07-innodb-transaction-system — InnoDB 事务系统：ACID 实现

## 0. 概述

InnoDB 事务系统是 MySQL 实现 ACID 特性的核心。它负责管理事务的生命周期——从创建、执行到提交或回滚——并在此基础上构建了 MVCC（多版本并发控制）和崩溃恢复能力。

### ACID 在 InnoDB 中的对应

| ACID 特性 | InnoDB 实现 |
|-----------|-------------|
| **A**tomicity（原子性） | undo log 保证：事务未提交时，通过 undo log 回滚到初始状态 |
| **C**onsistency（一致性） | 事务完整性约束 + redo log + undo log 联合保证 |
| **I**solation（隔离性） | MVCC (ReadView) + 锁系统 (lock_sys) 联合实现 |
| **D**urability（持久性） | redo log + doublewrite buffer 保证已提交事务不丢失 |

### 事务状态机

```c
// trx0types.h:58-73
enum trx_state_t {
  TRX_STATE_NOT_STARTED,       // 未开始
  TRX_STATE_FORCED_ROLLBACK,   // 被强制回滚
  TRX_STATE_ACTIVE,            // 活跃中
  TRX_STATE_PREPARED,          // 已 PREPARE（XA/2PC）
  TRX_STATE_COMMITTED_IN_MEMORY // 内存中已提交
};
```

状态变迁路径：
- **普通事务：** `NOT_STARTED → ACTIVE → COMMITTED_IN_MEMORY → NOT_STARTED`
- **AUTOCOMMIT 只读 SELECT：** `NOT_STARTED → ACTIVE → NOT_STARTED`
- **XA 事务：** `NOT_STARTED → ACTIVE → PREPARED → COMMITTED_IN_MEMORY → NOT_STARTED`
- **恢复的 XA：** `NOT_STARTED → PREPARED → COMMITTED_IN_MEMORY → (freed)`

```c
// trx0trx.h:676 — trx_t 中存储当前执行类别
enum trx_que_t {
  TRX_QUE_RUNNING,       // 正在运行
  TRX_QUE_LOCK_WAIT,     // 等待锁
  TRX_QUE_ROLLING_BACK,  // 正在回滚
  TRX_QUE_COMMITTING     // 正在提交
};
```

### 核心流程

```
BEGIN        →  trx_start_low()       →  分配 trx_id, rollback segment
  │
  ├─ INSERT  → 写 insert undo log     →  修改聚集索引
  ├─ UPDATE  → 写 update undo log     →  修改聚集索引 + 二级索引
  └─ DELETE  → 写 update undo log     →  delete-mark
  │
COMMIT       →  trx_commit()          →  刷 redo log → 释放锁
ROLLBACK     →  trx_rollback()       →  row_undo_step() 依次回退
```

---

## 1. 核心数据结构

### 1.1 trx_t (trx0trx.h:675) — 事务对象

`trx_t` 是 InnoDB 中最核心的数据结构之一，代表一个事务实例。每个 MySQL 连接在使用 InnoDB 时都会关联一个 `trx_t`。

```c
// trx0trx.h:673 — trx_t 结构体
struct trx_t {
  enum isolation_level_t {
    READ_UNCOMMITTED,  // 读未提交
    READ_COMMITTED,    // 读已提交
    REPEATABLE_READ,   // 可重复读（默认）
    SERIALIZABLE       // 可串行化
  };

  mutable TrxMutex mutex;       // 保护 state 和 lock 字段

  uint32_t in_depth;             // TrxInInnoDB 嵌套深度（无锁操作）
  uint32_t in_innodb;            // InnoDB 上下文计数
  bool abort;                    // 是否应该中止

  trx_id_t id;                   // 事务 ID（核心标识）
  trx_id_t no;                   // 事务序列号（serialization number）

  std::atomic<trx_state_t> state; // 事务状态

  ReadView *read_view;           // MVCC 一致性读视图

  // trx0trx.h:787 — 链表节点
  UT_LIST_NODE_T(trx_t) trx_list;     // rw_trx_list 节点
  UT_LIST_NODE_T(trx_t) no_list;      // serialisation_list 节点
  UT_LIST_NODE_T(trx_t) mysql_trx_list; // mysql_trx_list 节点

  trx_lock_t lock;               // 事务锁信息

  bool read_only;                // 是否为只读事务
  bool auto_commit;              // 是否为 AUTOCOMMIT
  uint32_t will_lock;            // 是否会加锁（非0表示会）

  // trx0trx.h:982 — undo 相关
  UndoMutex undo_mutex;          // 保护 undo_no 等字段
  undo_no_t undo_no;             // 下一个 undo 记录号（自增）
  trx_savept_t last_sql_stat_start; // 当前 SQL 语句开始的 undo_no
  trx_rsegs_t rsegs;             // 分配的 rollback segments
  undo_no_t roll_limit;          // 部分回滚的最小 undo_no

  THD *mysql_thd;                // 关联的 MySQL THD
  lsn_t commit_lsn;              // 提交时的 LSN
  std::atomic_uint64_t version;  // 实例版本号（每次 trx_start_low 自增）
  XID *xid;                      // XA 事务 ID
};
```

#### trx_rsegs_t — rollback segment 分配

```c
// trx0trx.h:662 — rollback segments
struct trx_rsegs_t {
  trx_undo_ptr_t m_redo;    // 持久化 undo log（需恢复的表）
  trx_undo_ptr_t m_noredo;  // 临时 undo log（临时表，不恢复）
};
```

`trx_rsegs_t` 分离了持久化和非持久化的 undo 日志。对临时表的修改不需要 crash recovery，因此放在 `m_noredo` 中，其 undo log 不写 redo。

### 1.2 trx_sys_t (trx0sys.h:679) — 全局事务系统

`trx_sys_t` 是单例的全局结构体，管理所有活跃事务、事务 ID 分配、MVCC 视图和 purge 系统。

```c
// trx0sys.h:679 — 事务系统
struct trx_sys_t {
  MVCC *mvcc;                        // MVCC 管理器
  Rsegs tmp_rsegs;                   // 临时表空间的 rollback segments
  std::atomic<uint64_t> rseg_history_len; // 历史链表长度

  std::atomic<trx_id_t> next_trx_id_or_no; // 下一个可用的 trx_id/no

  TrxSysMutex serialisation_mutex;          // 保护 serialisation_list
  UT_LIST_BASE_NODE_T(trx_t, no_list)
      serialisation_list;                   // 序列化链表（按 no 排序）
  std::atomic<trx_id_t> serialisation_min_trx_no; // serialisation_list 最小值

  TrxSysMutex mutex;                         // 主互斥锁

  UT_LIST_BASE_NODE_T(trx_t, trx_list)
      rw_trx_list;                           // 读写事务双向链表
  UT_LIST_BASE_NODE_T(trx_t, mysql_trx_list)
      mysql_trx_list;                        // MySQL 事务双向链表

  trx_ids_t rw_trx_ids;                      // 活跃读写事务 ID 数组（MVCC 快照用）
  Trx_shard shards[TRX_SHARDS_N];            // 按 ID 分片的活跃事务映射

  ulint n_prepared_trx;                      // XA PREPARED 事务数
  bool found_prepared_trx;                   // 是否存在 PREPARED 事务
};
```

#### 链表全局性说明

```c
// trx0sys.h:704 — 三个链表的分工
// rw_trx_list:    所有活跃的读写事务（包括系统事务和恢复事务）
// mysql_trx_list:  所有 MySQL 用户事务（NOT_STARTED 时存在）
// serialisation_list: 已分配 trx->no 但未完成提交的事务
```

`rw_trx_list` 和 `mysql_trx_list` 不是完全重叠的：恢复事务和系统事务只在 `rw_trx_list`，而尚未开始的事务只在 `mysql_trx_list`。

### 1.3 trx_id_t — 事务 ID 类型

```c
// trx0types.h:42
typedef ib_id_t trx_id_t;  // ib_id_t 是 uint64_t
```

事务 ID 是一个全局递增的 64 位无符号整数。InnoDB 保证每个读写事务获得唯一的 ID。

### 1.4 ReadView — MVCC 一致性读

`ReadView` 是 MVCC 的核心：它记录了一个时间点所有活跃的读写事务，从而判断哪些版本的记录对当前事务可见。

```c
// read0types.h:50 — ReadView 类
class ReadView {
  trx_id_t m_low_limit_id;     // 高水位：>= 此值的所有事务不可见
  trx_id_t m_up_limit_id;      // 低水位：< 此值的所有事务可见
  trx_id_t m_creator_trx_id;   // 创建者事务 ID（自身可见）
  ids_t m_ids;                 // 活跃的读写事务 ID 列表（有序）
  trx_id_t m_low_limit_no;     // purge 可清理的 trx->no 上限

  std::atomic_bool m_closed;   // 视图是否已关闭

  // 可见性判断（内联，性能关键路径）
  bool changes_visible(trx_id_t id, const table_name_t &name) const {
    if (id < m_up_limit_id || id == m_creator_trx_id) {
      return (true);          // 低于低水位或自己 → 可见
    }
    check_trx_id_sanity(id, name);
    if (id >= m_low_limit_id) {
      return (false);         // 等于或高于高水位 → 不可见
    } else if (m_ids.empty()) {
      return (true);          // 无活跃事务 → 可见
    }
    // 二分查找是否在活跃列表
    const ids_t::value_type *p = m_ids.data();
    return (!std::binary_search(p, p + m_ids.size(), id));
  }
};
```

可见性规则总结：
- `id < m_up_limit_id`：低水位以下 → **可见**（事务已提交）
- `id >= m_low_limit_id`：高水位及以上 → **不可见**（事务尚未开始）
- `id == m_creator_trx_id`：自己 → **可见**
- `m_ids` 中：**不可见**（活跃中）
- 不在 `m_ids` 中且在高与低水位之间：**可见**（已提交）

---

## 2. 事务 ID 分配

### 2.1 trx_sys_allocate_trx_id() — 分配事务 ID

事务 ID 从全局 `next_trx_id_or_no` 分配，它是一个原子递增计数器。

```c
// trx0sys.ic:204 — 全局 ID 分配器
inline trx_id_t trx_sys_allocate_trx_id_or_no() {
  ut_ad(trx_sys_mutex_own() || trx_sys_serialisation_mutex_own());

  trx_id_t trx_id = trx_sys->next_trx_id_or_no.fetch_add(1);

  if (trx_id % trx_sys_get_trx_id_write_margin() == 0) {
    // 每分配 256 个 ID，回写到系统表空间页
    trx_sys_write_max_trx_id();
  }
  return trx_id;
}

// trx0sys.ic:226 — 分配 trx_id（需持有 trx_sys->mutex）
inline trx_id_t trx_sys_allocate_trx_id() {
  ut_ad(trx_sys_mutex_own());
  return trx_sys_allocate_trx_id_or_no();
}

// trx0sys.ic:233 — 分配 trx->no（需持有 serialisation_mutex）
inline trx_id_t trx_sys_allocate_trx_no() {
  ut_ad(trx_sys_serialisation_mutex_own());
  return trx_sys_allocate_trx_id_or_no();
}
```

关键设计：`trx_id` 和 `trx_no` 共享同一个计数器 `next_trx_id_or_no`。这是因为两者都是单调递增且全局唯一，共享计数器简化了实现且不会出现重叠。

### 2.2 全局递增计数器

```c
// trx0sys.h:720 — 定义
std::atomic<trx_id_t> next_trx_id_or_no;
```

初始化的过程如下，在数据库启动时从系统表空间页读取上次的最大值：

```c
// trx0sys.cc:481 — 启动时初始化
purge_pq_t *trx_sys_init_at_db_start(void) {
  // ...
  mtr_t mtr;
  mtr.start();
  trx_sysf_t *sys_header = trx_sysf_get(&mtr);

  // 从 TRX_SYS 页读取上次的 max trx id
  const trx_id_t max_trx_id =
      mach_read_from_8(sys_header + TRX_SYS_TRX_ID_STORE);

  // 留出余量避免 crash 后 ID 重叠
  trx_sys->next_trx_id_or_no.store(max_trx_id +
                                   2 * TRX_SYS_TRX_ID_WRITE_MARGIN);
  // ...
}
```

```c
// trx0sys.ic:248 — 只读访问
inline trx_id_t trx_sys_get_next_trx_id_or_no() {
  return trx_sys->next_trx_id_or_no.load();
}
```

注意 `2 * TRX_SYS_TRX_ID_WRITE_MARGIN` 的 2 倍余量：因为 `trx_id` 和 `trx_no` 可跨两把不同的 mutex 同时分配，需要防止 crash 后 ID 回绕。

### 2.3 只读事务的延迟分配

```c
// trx0trx.cc:1270 — trx_start_low 中的分配逻辑
if (!trx->read_only &&
    (trx->mysql_thd == nullptr || read_write || trx->ddl_operation)) {
  // 读写事务：立即分配 trx_id
  trx_assign_rseg_durable(trx);

  trx_sys_mutex_enter();
  trx->id = trx_sys_allocate_trx_id();
  trx_sys->rw_trx_ids.push_back(trx->id);
  trx_add_to_rw_trx_list(trx);
  trx->state.store(TRX_STATE_ACTIVE, std::memory_order_relaxed);
  trx_sys_mutex_exit();
  trx_sys_rw_trx_add(trx);
} else {
  trx->id = 0;  // 只读事务不分配 ID

  if (!trx_is_autocommit_non_locking(trx)) {
    if (read_write) {
      // 只读事务但写临时表 → 需要 ID 但不加入 rw_trx_list
      trx_sys_mutex_enter();
      trx->state.store(TRX_STATE_ACTIVE, std::memory_order_relaxed);
      trx->id = trx_sys_allocate_trx_id();
      trx_sys->rw_trx_ids.push_back(trx->id);
      trx_sys_mutex_exit();
      trx_sys_rw_trx_add(trx);
    } else {
      trx->state.store(TRX_STATE_ACTIVE, std::memory_order_relaxed);
    }
  }
}
```

只读事务不分配事务 ID，直到确实需要写入（写临时表）时才分配。AUTOCOMMIT 只读 SELECT 甚至完全不进入任何事务链表。

---

## 3. 事务开始

### 3.1 trx_start_low() — 启动事务 (trx0trx.cc:1270)

`trx_start_low` 是所有事务开始的最终入口。它完成以下工作：

1. 设置 `version`，检测 AUTOCOMMIT/READ ONLY
2. 确定 `read_only` 属性
3. AC-NL-RO 事务：设 `read_only = true`，不分配 ID
4. 读写事务：分配 undo log rollback segment、分配 trx_id、加入 rw_trx_list
5. 只读写临时表：分配 trx_id、加入 rw_trx 分片，但不加入 rw_trx_list

```c
// trx0trx.cc:1270 — 事务开始（核心入口）
static void trx_start_low(trx_t *trx, bool read_write) {
  ++trx->version;

  // 确定 auto_commit 属性
  trx->auto_commit = (trx->api_trx && trx->api_auto_commit) ||
                     thd_trx_is_auto_commit(trx->mysql_thd);

  // 确定 read_only 属性
  trx->read_only = (trx->api_trx && !trx->read_write) ||
                   (!trx->internal && thd_trx_is_read_only(trx->mysql_thd)) ||
                   srv_read_only_mode;

  // AUTOCOMMIT 但可能加锁 → 增加 will_lock
  if (!trx->auto_commit) {
    ++trx->will_lock;
  } else if (trx->will_lock == 0) {
    trx->read_only = true;  // AC-NL-RO
  }

  trx->no = TRX_ID_MAX;  // 初始化序列号

  if (!trx->read_only &&
      (trx->mysql_thd == nullptr || read_write || trx->ddl_operation)) {
    // 读写事务路径
    trx_assign_rseg_durable(trx);          // 分配 rollback segment
    trx_sys_mutex_enter();
    trx->id = trx_sys_allocate_trx_id();    // 分配事务 ID
    trx_sys->rw_trx_ids.push_back(trx->id); // 加入 MVCC 快照数组
    trx_add_to_rw_trx_list(trx);            // 加入 rw_trx_list
    trx->state.store(TRX_STATE_ACTIVE, std::memory_order_relaxed);
    trx_sys_mutex_exit();
    trx_sys_rw_trx_add(trx);               // 加入分片映射
  } else {
    // 只读事务路径
    trx->id = 0;
    trx->state.store(TRX_STATE_ACTIVE, std::memory_order_relaxed);
  }
}
```

### 3.2 trx_start_if_not_started_low() — 按需启动 (trx0trx.cc:3338)

```c
// trx0trx.cc:3338 — 按需启动事务
void trx_start_if_not_started_low(trx_t *trx, bool read_write) {
  switch (trx->state.load(std::memory_order_relaxed)) {
    case TRX_STATE_NOT_STARTED:
    case TRX_STATE_FORCED_ROLLBACK:
      trx_start_low(trx, read_write);
      return;
    case TRX_STATE_ACTIVE:
      if (read_write && trx->id == 0 && !trx->read_only) {
        trx_set_rw_mode(trx);  // 从 RO 升级为 RW
      }
      return;
    case TRX_STATE_PREPARED:
    case TRX_STATE_COMMITTED_IN_MEMORY:
      break;
  }
  ut_error;
}
```

这个函数常用于 DML 操作的开始处：如果事务尚未启动，则启动之；如果已启动但需要写，且当前是只读模式，则升级为读写模式。

### 3.3 AUTOCOMMIT 与显式 START TRANSACTION

```c
// trx0trx.cc:2326 — 自动提交
// 在每一条语句结束后调用 trx_commit()，然后再 trx_start_low() 开始下一条

// 显式事务: BEGIN / START TRANSACTION
// 通过 thd_trx_is_auto_commit(trx->mysql_thd) 返回 false
// 将 trx->auto_commit 设为 false，并执行 ++trx->will_lock 阻止 AC-NL-RO 优化
```

### 3.4 read-only 与 read-write 事务的区别

| 特性 | Read-Only | Read-Write |
|------|-----------|------------|
| trx_id | 0（除非写临时表） | 全局唯一自增 |
| rollback segment | 不需要 | 需要分配 |
| rw_trx_list | 不加入 | 加入 |
| undo log | 不写入 | 写入 |
| MVCC 可见性 | 不参与 | 参与 |
| 优化路径 | AC-NL-RO可完全跳过锁系统 | 标准路径 |

---

## 4. 事务提交

### 4.1 trx_commit() — 入口 (trx0trx.cc:2229)

```c
// trx0trx.cc:2229 — 提交入口
void trx_commit(trx_t *trx) {
  mtr_t *mtr;
  mtr_t local_mtr;

  if (trx_is_rseg_updated(trx)) {
    // 有 undo log → 需要写 redo log
    mtr = &local_mtr;
    mtr_start_sync(mtr);
  } else {
    mtr = nullptr;  // 只读事务无需写 redo
  }

  trx_commit_low(trx, mtr);
}
```

`trx_is_rseg_updated()` 判断事务是否修改了数据（写入了 undo log）。若没有，提交几乎是空操作。

### 4.2 trx_commit_low() — 低层提交 (trx0trx.cc:2137)

```c
// trx0trx.cc:2137 — 低层提交
void trx_commit_low(trx_t *trx, mtr_t *mtr) {
  // FTS 提交（如果有全文索引）
  if (trx->fts_trx != nullptr && trx->undo_no != 0 &&
      trx->lock.que_state != TRX_QUE_ROLLING_BACK) {
    dberr_t error = fts_commit(trx);
    // ...
  }

  bool serialised;
  if (mtr != nullptr) {
    // 写入序列化历史（分配 trx->no，将 undo 加入 purge 队列）
    serialised = trx_write_serialisation_history(trx, mtr);
    // 提交 mini-transaction（写入 redo log）
    mtr_commit(mtr);
  } else {
    serialised = false;
  }

  // 在内存中完成提交
  trx_commit_in_memory(trx, mtr, serialised);
}
```

核心步骤：
1. **`trx_write_serialisation_history()`**：分配 `trx->no`，将 undo log 从 ACTIVE 改为其他状态并加入历史链表
2. **`mtr_commit()`**：提交 mini-transaction，redo log 写入 log buffer
3. **`trx_commit_in_memory()`**：释放锁、关闭 ReadView、清理 undo、设置状态为 NOT_STARTED

### 4.3 trx_write_serialisation_history() — 序列化历史写入 (trx0trx.cc:1537)

```c
// trx0trx.cc:1537 — 序列化历史写入
static bool trx_write_serialisation_history(trx_t *trx, mtr_t *mtr) {
  // 持有 rollback segment mutex，保护 undo log header 操作
  if (trx->rsegs.m_redo.rseg != nullptr && trx_is_redo_rseg_updated(trx)) {
    trx->rsegs.m_redo.rseg->latch();
    own_redo_rseg_mutex = true;
  }

  // 处理 insert undo：设置状态
  if (trx->rsegs.m_redo.insert_undo != nullptr) {
    trx_undo_set_state_at_finish(trx->rsegs.m_redo.insert_undo, mtr);
  }

  // 处理 update undo：分配 trx->no，加入 purge 队列
  if (trx->rsegs.m_redo.update_undo != nullptr ||
      trx->rsegs.m_noredo.update_undo != nullptr) {
    serialised = trx_serialisation_number_get(trx, redo_rseg_undo_ptr,
                                              temp_rseg_undo_ptr);

    // 设置 update undo 状态，加入历史链表
    if (trx->rsegs.m_redo.update_undo != nullptr) {
      page_t *undo_hdr_page;
      undo_hdr_page = trx_undo_set_state_at_finish(
          trx->rsegs.m_redo.update_undo, mtr);
      trx_undo_update_cleanup(trx, undo_ptr, undo_hdr_page, ...);
    }
  }

  // 释放 rollback segment mutex
  // 更新 MySQL binlog 信息
  if (Clone_handler::need_commit_order()) {
    trx_sys_update_mysql_binlog_offset(trx, mtr);
  }
}
```

#### trx_serialisation_number_get() (trx0trx.cc:1478)

```c
// trx0trx.cc:1478 — 分配序列号并加入 purge 队列
static bool trx_serialisation_number_get(
    trx_t *trx,
    trx_undo_ptr_t *redo_rseg_undo_ptr,
    trx_undo_ptr_t *temp_rseg_undo_ptr) {

  // 如果 rollback segment 为空，则创建一个 purge queue entry
  if ((redo_rseg != nullptr && redo_rseg->last_page_no == FIL_NULL) ||
      (temp_rseg != nullptr && temp_rseg->last_page_no == FIL_NULL)) {
    TrxUndoRsegs elem;
    // ...
    added_trx_no = trx_add_to_serialisation_list(trx);
    elem.set_trx_no(trx->no);
    purge_sys->purge_queue->push(std::move(elem));
  } else {
    added_trx_no = trx_add_to_serialisation_list(trx);
  }
  return added_trx_no;
}
```

#### trx_add_to_serialisation_list() (trx0trx.cc:1436)

```c
// trx0trx.cc:1436 — 加入序列化链表
static inline bool trx_add_to_serialisation_list(trx_t *trx) {
  trx_sys_serialisation_mutex_enter();
  trx->no = trx_sys_allocate_trx_no();  // 分配序列号

  if (trx->read_only) {
    trx_sys_serialisation_mutex_exit();
    return false;  // 只读事务不加入 serialisation_list
  }

  // 加入链表尾部（按 no 递增顺序）
  UT_LIST_ADD_LAST(trx_sys->serialisation_list, trx);

  // 如果是链表中第一个，更新最小值
  if (UT_LIST_GET_LEN(trx_sys->serialisation_list) == 1) {
    trx_sys->serialisation_min_trx_no.store(trx->no);
  }
  trx_sys_serialisation_mutex_exit();
  return true;
}
```

### 4.4 trx_commit_in_memory() — 内存提交 (trx0trx.cc:1935)

```c
// trx0trx.cc:1935 — 内存提交
static void trx_commit_in_memory(trx_t *trx, const mtr_t *mtr, bool serialised) {
  trx->must_flush_log_later = false;

  if (trx_is_autocommit_non_locking(trx)) {
    // AC-NL-RO：最轻量的提交路径
    ut_ad(trx->id == 0);
    ut_ad(trx->read_only);
    if (trx->read_view != nullptr) {
      trx_sys->mvcc->view_close(trx->read_view, false);
    }
    trx->state.store(TRX_STATE_NOT_STARTED, std::memory_order_relaxed);
  } else {
    // 读写/只读事务
    trx_release_impl_and_expl_locks(trx, serialised);  // 释放锁
    // 状态已在前面设置为 COMMITTED_IN_MEMORY

    if (trx->read_only || trx->rsegs.m_redo.rseg == nullptr) {
      MONITOR_INC(MONITOR_TRX_RO_COMMIT);
      if (trx->read_view != nullptr) {
        trx_sys->mvcc->view_close(trx->read_view, false);
      }
    } else {
      ut_ad(trx->id > 0);
      MONITOR_INC(MONITOR_TRX_RW_COMMIT);
    }
  }

  // 清理 undo log
  if (mtr != nullptr) {
    if (trx->rsegs.m_redo.insert_undo != nullptr) {
      trx_undo_insert_cleanup(&trx->rsegs.m_redo, false);
    }
    // 可选刷日志
    lsn_t lsn = mtr->commit_lsn();
    if (lsn != 0 && !trx->flush_log_later) {
      trx_flush_log_if_needed(lsn, trx);
    }
    trx->commit_lsn = lsn;
  }

  // 减少 rseg 引用计数
  if (trx->rsegs.m_redo.rseg != nullptr) {
    trx->rsegs.m_redo.rseg->trx_ref_count--;
    trx->rsegs.m_redo.rseg = nullptr;
  }

  // 最终状态设置
  trx_mutex_enter(trx);
  if (trx->abort) {
    trx->state.store(TRX_STATE_FORCED_ROLLBACK, std::memory_order_relaxed);
  } else {
    trx->state.store(TRX_STATE_NOT_STARTED, std::memory_order_relaxed);
  }
  trx_init(trx);  // 重置事务对象以供复用
  trx_mutex_exit(trx);
}
```

### 4.5 trx_commit_complete_for_mysql() — 通知 MySQL 层 (trx0trx.cc:2470)

```c
// trx0trx.cc:2470 — 两阶段提交的第二步
void trx_commit_complete_for_mysql(trx_t *trx) {
  if (trx->id != 0 || !trx->must_flush_log_later ||
      (thd_requested_durability(trx->mysql_thd) == HA_IGNORE_DURABILITY &&
       !trx->ddl_must_flush)) {
    return;
  }
  trx_flush_log_if_needed(trx->commit_lsn, trx);
  trx->must_flush_log_later = false;
  trx->ddl_must_flush = false;
}
```

此函数在 MySQL 层的两阶段提交中扮演角色：当 `prepare_commit_mutex` 被持有时，日志刷盘延迟到释放 mutex 后，以允许 group commit。

### 4.6 两阶段提交（与 binlog 交互）

```
MySQL 两阶段提交流程：

Phase 1 — PREPARE:
  1. trx_prepare() → 设置 undo log 状态为 TRX_UNDO_PREPARED
  2. 写 XID 到 undo log header
  3. 刷 redo log（确保 prepare 持久化）

Phase 2 — COMMIT:
  1. 写 binlog（xa commit 记录）
  2. trx_commit() → trx_write_serialisation_history()
  3. 在 commit 的同一个 mtr 中更新 binlog 位置
  4. trx_commit_in_memory() → 释放锁
```

```c
// trx0trx.cc:2225 — trx_commit_low 中的调用链
trx_commit_low() {
  trx_write_serialisation_history(trx, mtr);  // 写 redo, 分配 trx->no
  mtr_commit(mtr);                              // 提交 mini-transaction
  trx_commit_in_memory(trx, mtr, serialised);  // 内存操作
}
```

### 4.7 提交后 undo log 的回收（purge queue）

提交后，update undo logs 被加入每个 rollback segment 的历史链表：

```c
// trx0purge.cc:352 — 将 update undo 加入历史链表
void trx_purge_add_update_undo_to_history(
    trx_t *trx, trx_undo_ptr_t *undo_ptr,
    page_t *undo_page, bool update_rseg_history_len,
    ulint n_added_logs, mtr_t *mtr) {
  // 将 undo log header 添加到 rseg 的 TRX_RSEG_HISTORY 链表首部
  flst_add_first(rseg_header + TRX_RSEG_HISTORY,
                 undo_header + TRX_UNDO_HISTORY_NODE, mtr);

  trx_sys->rseg_history_len.fetch_add(n_added_logs);

  // 如果历史链表太长，唤醒 purge 线程
  if (trx_sys->rseg_history_len.load() >
      srv_n_purge_threads * srv_purge_batch_size) {
    srv_wake_purge_thread_if_not_active();
  }
}
```

---

## 5. 事务回滚

### 5.1 trx_rollback_low() — 回滚入口 (trx0roll.cc:181)

```c
// trx0roll.cc:181 — 回滚状态机
static dberr_t trx_rollback_low(trx_t *trx) {
  switch (trx->state.load(std::memory_order_relaxed)) {
    case TRX_STATE_NOT_STARTED:
    case TRX_STATE_FORCED_ROLLBACK:
      // 事务尚未开始或已被强制回滚 → 无需操作
      trx->will_lock = 0;
      return DB_SUCCESS;

    case TRX_STATE_ACTIVE:
      // 正常回滚
      return trx_rollback_for_mysql_low(trx);

    case TRX_STATE_PREPARED:
      // XA 回滚：需要将 undo 状态从 PREPARED 改回 ACTIVE
      trx_undo_set_state_at_prepare(trx, undo_ptr->insert_undo, true, &mtr);
      trx_undo_set_state_at_prepare(trx, undo_ptr->update_undo, true, &mtr);
      // 持久化回滚操作（刷 redo）
      mtr.commit();
      return trx_rollback_for_mysql_low(trx);

    case TRX_STATE_COMMITTED_IN_MEMORY:
      break;  // 已提交 → 不应发生
  }
  ut_error;
}
```

### 5.2 trx_rollback_to_savepoint_low() — 具体回滚执行 (trx0roll.cc:79)

```c
// trx0roll.cc:79 — 回滚到 savepoint（或完全回滚）
static void trx_rollback_to_savepoint_low(
    trx_t *trx, trx_savept_t *savept) {

  roll_node = roll_node_create(heap);

  if (savept != nullptr) {
    roll_node->partial = true;
    roll_node->savept = *savept;  // 部分回滚到指定点
  }

  if (trx_is_rseg_updated(trx)) {
    // 构建回滚图并执行
    thr = pars_complete_graph_for_exec(roll_node, trx, heap, nullptr);
    que_run_threads(thr);           // 执行回滚主节点
    que_run_threads(roll_node->undo_thr);  // 执行 undo 子节点
    que_graph_free(/* ... */);
  }

  if (savept == nullptr) {
    trx_rollback_finish(trx);  // 完全回滚后调用 trx_commit()
    MONITOR_INC(MONITOR_TRX_ROLLBACK);
  } else {
    trx->lock.que_state = TRX_QUE_RUNNING;
    MONITOR_INC(MONITOR_TRX_ROLLBACK_SAVEPOINT);
  }
}
```

```c
// trx0roll.cc:1101 — 回滚完成
static void trx_rollback_finish(trx_t *trx) {
  trx_commit(trx);  // 以 commit 的方式完成回滚（清理 undo, 释放锁）
  trx->mod_tables.clear();
  trx->lock.que_state = TRX_QUE_RUNNING;
}
```

### 5.3 row_undo_step() — 逐条回滚 undo records (row0undo.cc:408)

```c
// row0undo.cc:408 — 逐条 undo 记录回滚
que_thr_t *row_undo_step(que_thr_t *thr) {
  undo_node_t *node;
  node = static_cast<undo_node_t *>(thr->run_node);

  err = row_undo(node, thr);  // 执行实际 undo 操作

  trx->error_state = err;

  if (err != DB_SUCCESS) {
    if (err == DB_OUT_OF_FILE_SPACE) {
      ib::fatal(UT_LOCATION_HERE, ER_IB_MSG_1041)
          << "Out of tablespace during rollback.";
    }
    ib::fatal(UT_LOCATION_HERE, ER_IB_MSG_1042)
        << "Error (" << ut_strerr(err) << ") in rollback.";
  }
  return thr;
}
```

#### undo_node_t — undo 执行上下文 (row0undo.h:120)

```c
// row0undo.h:120 — undo 节点状态
struct undo_node_t {
  que_common_t common;      // 查询图节点类型: QUE_NODE_UNDO
  enum undo_exec state;     // 执行状态（FETCH_NEXT, PROCESS 等）
  trx_t &trx;               // 事务引用
  roll_ptr_t roll_ptr;      // 指向 undo log 记录的 rollback pointer
  trx_undo_rec_t *undo_rec; // 当前处理的 undo 记录
  undo_no_t undo_no;        // 当前 undo_no
  ulint rec_type;           // TRX_UNDO_INSERT_REC / TRX_UNDO_UPDATE_REC / ...
  trx_id_t new_trx_id;      // 恢复后的 trx_id
  btr_pcur_t pcur;          // B-tree 持久化游标
  dict_table_t *table;      // 表对象
  upd_t *update;            // UPDATE 的更新向量
  dtuple_t *row;            // 行数据
  dtuple_t *undo_row;       // undo 后的行
  dict_index_t *index;      // 当前处理的索引
  mem_heap_t *heap;         // 内存堆
};
```

### 5.4 针对 INSERT / UPDATE / DELETE 的不同回滚逻辑

```c
// row0undo.cc:61 — 三种 undo 操作
// (1) INSERT 回滚：删除插入的行
//     undo log 中存储了聚集索引记录的 key，通过 key 定位并删除
//     同时清理所有二级索引
//
// (2) DELETE 回滚：取消 delete-mark
//     将记录的 DB_TRX_ID 和 DB_ROLL_PTR 恢复为 undo 中的值
//     清除 delete-mark 标志位
//
// (3) UPDATE 回滚：恢复旧值
//     对于非主键更新：恢复被修改的列
//     对于主键更新（相当于 DELETE+INSERT）：
//       - 删除新行，恢复旧行（如果旧行仍存在）
//     使用 update vector 中的旧值覆盖当前值
```

具体的 undo 实现分布在 `row0uins.cc`（insert undo）、`row0umod.cc`（update undo）等文件中。

---

## 6. 全局事务系统 trx_sys_t

### 6.1 trx_sys_create() — 初始化 (trx0sys.cc:601)

```c
// trx0sys.cc:601 — 事务系统创建
void trx_sys_create(void) {
  trx_sys = static_cast<trx_sys_t *>(
      ut::zalloc_withkey(UT_NEW_THIS_FILE_PSI_KEY, sizeof(*trx_sys)));

  // 初始化两把互斥锁
  mutex_create(LATCH_ID_TRX_SYS, &trx_sys->mutex);
  mutex_create(LATCH_ID_TRX_SYS_SERIALISATION,
               &trx_sys->serialisation_mutex);

  // 初始化三大链表
  UT_LIST_INIT(trx_sys->serialisation_list);
  UT_LIST_INIT(trx_sys->rw_trx_list);
  UT_LIST_INIT(trx_sys->mysql_trx_list);

  // 创建 MVCC 管理器（初始容量 1024 个 ReadView）
  trx_sys->mvcc = ut::new_withkey<MVCC>(
      UT_NEW_THIS_FILE_PSI_KEY, 1024);

  trx_sys->serialisation_min_trx_no.store(0);

  // 初始化分片数组
  new (&trx_sys->rw_trx_ids) trx_ids_t(...);
  for (auto &shard : trx_sys->shards) {
    new (&shard) Trx_shard{};
  }

  new (&trx_sys->tmp_rsegs) Rsegs();
  trx_sys->tmp_rsegs.set_empty();
}
```

### 6.2 trx_sys_init_at_db_start() — 启动时初始化 (trx0sys.cc:481)

```c
// trx0sys.cc:481 — crash recovery 后的系统初始化
purge_pq_t *trx_sys_init_at_db_start(void) {
  purge_queue = ut::new_withkey<purge_pq_t>(UT_NEW_THIS_FILE_PSI_KEY);

  // 扫描所有 rollback segments，恢复 undo 状态
  if (srv_force_recovery < SRV_FORCE_NO_UNDO_LOG_SCAN) {
    trx_rsegs_init(purge_queue);  // 或 trx_rsegs_parallel_init()
  }

  // 从系统表空间 TRX_SYS 页读取 max_trx_id
  trx_sys->next_trx_id_or_no.store(max_trx_id +
                                    2 * TRX_SYS_TRX_ID_WRITE_MARGIN);

  // 处理恢复的活跃事务（需要回滚的）
  if (UT_LIST_GET_LEN(trx_sys->rw_trx_list) > 0) {
    uint64_t rows_to_undo = 0;
    for (auto trx : trx_sys->rw_trx_list) {
      ut_ad(trx->is_recovered);
      if (trx_state_eq(trx, TRX_STATE_ACTIVE)) {
        rows_to_undo += trx->undo_no;
      }
    }
    ib::info(ER_IB_MSG_1198)
        << UT_LIST_GET_LEN(trx_sys->rw_trx_list)
        << " transaction(s) which must be rolled back";
  }

  return purge_queue;
}
```

### 6.3 trx_sys_t.rw_trx_ids — 读写事务 ID 数组

```c
// trx0sys.h:750 — MVCC 快照用
trx_ids_t rw_trx_ids;  // 所有活跃读写事务的 ID，按序排列
```

当创建 ReadView 时，`ReadView::prepare()` 复制这个数组作为快照快照：

```c
// read0read.cc:446 — 创建 ReadView
void ReadView::prepare(trx_id_t id) {
  ut_ad(trx_sys_mutex_own());
  m_creator_trx_id = id;
  m_low_limit_no = trx_get_serialisation_min_trx_no();
  m_low_limit_id = trx_sys_get_next_trx_id_or_no();  // 高水位

  if (!trx_sys->rw_trx_ids.empty()) {
    copy_trx_ids(trx_sys->rw_trx_ids);  // 复制活跃事务列表
  } else {
    m_ids.clear();
  }

  // 低水位 = 活跃事务中最小的 ID
  m_up_limit_id = !m_ids.empty() ? m_ids.front() : m_low_limit_id;
  m_closed.store(false);
}
```

### 6.4 trx_sys_t.shards — 读写事务分片

为了减少锁竞争，活跃的读写事务按 ID 分片存储：

```c
// trx0sys.h:662 — 分片结构
struct Trx_shard {
  ut::Cacheline_padded<ut::Guarded<Trx_by_id_with_min,
                                   LATCH_ID_TRX_SYS_SHARD>>
      active_rw_trxs;
};
```

```c
// trx0sys.ic:262 — 将事务加入分片
static inline void trx_sys_rw_trx_add(trx_t *trx) {
  const trx_id_t trx_id = trx->id;
  const auto trx_shard_no = trx_get_shard_no(trx_id);
  trx_sys->shards[trx_shard_no].active_rw_trxs.latch_and_execute(
      [&](Trx_by_id_with_min &trx_by_id_with_min) {
        trx_by_id_with_min.insert(*trx);
      },
      UT_LOCATION_HERE);
}
```

### 6.5 事务回收 — trx_purge 系统 (trx0purge.cc)

Purge 系统负责在事务提交后，删除不再需要的 undo log 和 delete-marked 记录：

```c
// trx0purge.cc:2396 — 主函数
ulint trx_purge(ulint n_purge_threads, /* ... */) {
  // 计算 DML 延迟（防止 purge 跟不上）
  srv_dml_needed_delay = trx_purge_dml_delay();

  // 更新 purge_sys->view（最老的活跃 ReadView）
  trx_purge_update_oldest_needed();

  // 从 undo log history 中取出待清理的记录
  n_pages_handled = trx_purge_attach_undo_recs(n_purge_threads, batch_size);

  // 等待工作线程完成
  trx_purge_wait_for_workers_to_complete();

  // 截断已处理的历史链表
  trx_purge_truncate();

  // 截断已清空的 undo 表空间
  trx_purge_truncate_undo_spaces();

  return n_pages_handled;
}
```

Purge 使用全局视图 `purge_sys->view`（复制自最老的活跃 ReadView）来决定哪些 undo log 和 delete-marked 已完全不可见并可以物理删除。

```c
// trx0purge.cc:252 — 更新最旧的 ReadView
static void trx_purge_update_oldest_needed() {
  // 从 MVCC 获取最老的活跃视图
  ReadView *oldest_view = trx_sys->mvcc->get_oldest_view();
  if (oldest_view != nullptr) {
    // 只有 m_low_limit_no 更大的视图才能替换当前视图
    if (purge_sys->view == nullptr ||
        oldest_view->m_low_limit_no > purge_sys->view->m_low_limit_no) {
      // 原子替换
      ReadView *old;
      do {
        old = purge_sys->view;
      } while (!purge_sys->view.compare_exchange_weak(old, oldest_view));
    }
  }
}
```

---

## 7. MVCC ReadView

### 7.1 ReadView::prepare() — 创建读视图

如前所述，`ReadView::prepare()` 在 `trx_sys->mutex` 保护下创建视图。它被 `MVCC::view_open()` 调用：

```c
// read0read.cc:499 — 打开或重用视图
void MVCC::view_open(ReadView *&view, trx_t *trx) {
  if (view != nullptr) {
    // 如果视图已关闭且无新活跃事务，重用它
    view = reinterpret_cast<ReadView *>(p & ~1);
    ut_ad(view->m_closed.load());
    // ...
  }

  // 获取空闲视图或新建
  if (view == nullptr) {
    view = get_view();  // 从 m_free 列表取或 new
  }

  // 准备视图（在 trx_sys->mutex 保护下）
  trx_sys_mutex_enter();
  view->prepare(trx->id);
  UT_LIST_ADD_LAST(m_views, view);
  trx_sys_mutex_exit();
}
```

### 7.2 trx_assign_read_view() — 为事务分配视图

```c
// trx0trx.cc:2310 — 分配一致性读视图
ReadView *trx_assign_read_view(trx_t *trx) {
  if (srv_read_only_mode) {
    return nullptr;
  } else if (!MVCC::is_view_active(trx->read_view)) {
    trx_sys->mvcc->view_open(trx->read_view, trx);
  }
  return trx->read_view;
}
```

`is_view_active` 通过检查 `m_creator_trx_id != TRX_ID_MAX` 判断视图是否仍有效。同一事务的后续查询将重用同一个 ReadView（RR 级别）或重新获取（RC 级别）。

### 7.3 不同隔离级别的 ReadView 创建时机

| 隔离级别 | 创建时机 | 行为 |
|---------|---------|------|
| READ UNCOMMITTED | 不创建 | 直接读取最新版本（`< m_up_limit_id` 不成立） |
| READ COMMITTED | 每条语句执行前 | 每次 `trx_assign_read_view()` 都开新视图 |
| REPEATABLE READ | 事务中第一条 SELECT | 整个事务复用同一个 ReadView |
| SERIALIZABLE | 自动转为 LOCK IN SHARE MODE | 不使用 MVCC，依赖锁 |

对于 RC 级别，每次语句开始时重新创建 ReadView 意味着能看到其他事务已提交的最新版本：

```c
// trx0trx.cc:2326 — RC 事务每次语句重新获取视图
// 在 trx_mark_sql_stat_end() 后关闭视图
void trx_mark_sql_stat_end(trx_t *trx) {
  lock_on_statement_end(trx);
  // RC 级别：view 失效，下条语句会创建新视图
  // RR 级别：view 继续有效
}
```

### 7.4 ReadView::changes_visible() 详解

```c
// read0types.h:68 — 内联可见性判断
bool changes_visible(trx_id_t id, const table_name_t &name) const {
  ut_ad(id > 0);

  // Case 1: 低水位以下 → 肯定可见
  if (id < m_up_limit_id || id == m_creator_trx_id) {
    return (true);
  }

  check_trx_id_sanity(id, name);

  // Case 2: 高水位及以上 → 肯定不可见
  if (id >= m_low_limit_id) {
    return (false);
  }

  // Case 3: 无活跃事务 → 可见
  } else if (m_ids.empty()) {
    return (true);
  }

  // Case 4: 在高~低水位之间 → 二分查找
  const ids_t::value_type *p = m_ids.data();
  return (!std::binary_search(p, p + m_ids.size(), id));
}
```

这个函数是 MVCC 的最关键路径——每访问一个记录时都需要调用它判断可见性。因此它被设计为 `inline`，且前两个分支是 O(1) 的，只有 Case 4 需要 O(log n) 的二分查找。

### 7.5 MVCC::view_close() — 关闭视图

```c
// read0read.cc:746 — 关闭视图
void MVCC::view_close(ReadView *&view, bool own_mutex) {
  if (!own_mutex) {
    // AC-NL-RO 路径：只标记 closed
    ptr->m_closed.store(true);
    view = reinterpret_cast<ReadView *>(p | 0x1);
  } else {
    // 普通路径：从 m_views 移到 m_free
    view->close();
    UT_LIST_REMOVE(m_views, view);
    UT_LIST_ADD_LAST(m_free, view);
    view = nullptr;
  }
}
```

AC-NL-RO 事务通过 `own_mutex=false` 路径快速关闭视图，只设置原子标志位，不操作链表。

---

## 8. 自动提交与隐式事务

### 8.1 AUTOCOMMIT 模式下每条 SQL 一个事务

MySQL 默认 AUTOCOMMIT=ON。每条 DML 语句自动被包裹为一个独立事务：

```sql
-- AUTOCOMMIT=ON 下，每条语句等于：
INSERT INTO t VALUES (1);   -- 自动 BEGIN → INSERT → COMMIT
UPDATE t SET c=2 WHERE id=1; -- 自动 BEGIN → UPDATE → COMMIT
```

```c
// trx0trx.cc:1270 — trx_start_low 中的 auto_commit 检测
trx->auto_commit = thd_trx_is_auto_commit(trx->mysql_thd);

// 对于 AC-NL-RO 事务（auto_commit && will_lock==0）
// 状态直接从 NOT_STARTED → ACTIVE → NOT_STARTED，不走完整的提交路径
```

### 8.2 AC-NL-RO 优化路径

**Auto-Commit Non-Locking Read Only** 是最优化的路径。它：
- 不分配 `trx_id`（为 0）
- 不分配 rollback segment
- 不写 undo log
- 不加任何锁
- 不加入任何链表（`!in_rw_trx_list`）
- `trx_commit_in_memory` 中几乎零成本完成

```c
// trx0trx.h:1139 — AC-NL-RO 检测
static inline bool trx_is_autocommit_non_locking(const trx_t *t) {
  return t->auto_commit && t->will_lock == 0;
}
```

### 8.3 事务嵌套模型

InnoDB 不直接支持嵌套事务，但通过 SAVEPOINT 模拟：

```sql
SAVEPOINT sp1;
INSERT INTO t VALUES (1);
SAVEPOINT sp2;
INSERT INTO t VALUES (2);
ROLLBACK TO SAVEPOINT sp1;  -- 回滚到 sp1，只保留第一条
```

```c
// trx0trx.h:992 — savepoints 链表
UT_LIST_BASE_NODE_T_EXTERN(trx_named_savept_t, trx_savepoints)
trx_savepoints{}; // savepoints，最旧的在最前

// trx0roll.cc:79 — 部分回滚使用 savept->least_undo_no 作为回滚点
trx_rollback_to_savepoint_low(trx, savept) {
  if (savept != nullptr) {
    roll_node->partial = true;
    roll_node->savept = *savept;
  }
  // ...执行回滚到指定 undo_no
}
```

---

## 9. 完整数据流

### 9.1 一条 INSERT 的事务生命周期

```
BEGIN（或 AUTOCOMMIT）
  │
  ├─ handler::write_row()
  │   ├─ trx_start_if_not_started_low(trx, true)   // trx0trx.cc:3338
  │   │   └─ trx_start_low(trx, true)              // trx0trx.cc:1270
  │   │       ├─ trx_assign_rseg_durable(trx)       // trx0trx.cc:1241
  │   │       ├─ trx->id = trx_sys_allocate_trx_id() // trx0sys.ic:226
  │   │       ├─ trx_add_to_rw_trx_list(trx)
  │   │       └─ trx->state = TRX_STATE_ACTIVE
  │   │
  │   ├─ btr_cur_optimistic_insert()
  │   │   └─ trx_undo_page_report_insert()          // 写 insert undo log
  │   │       ├─ trx_undo_t::type = TRX_UNDO_INSERT
  │   │       ├─ 记录插入行的主键值
  │   │       └─ 记录 DB_TRX_ID = trx->id
  │   │
  │   └─ 修改聚集索引页 + 二级索引页
  │
  └─ 提交
      ├─ trx_commit()                                // trx0trx.cc:2229
      │   └─ trx_commit_low(trx, mtr)               // trx0trx.cc:2137
      │       ├─ trx_write_serialisation_history()
      │       │   ├─ trx_undo_set_state_at_finish()  // INSERT UNDO → TRX_UNDO_CACHED
      │       │   └─ mtr_commit()                    // 提交 mini-transaction
      │       │
      │       └─ trx_commit_in_memory()               // trx0trx.cc:1935
      │           ├─ trx_release_impl_and_expl_locks()
      │           ├─ trx_undo_insert_cleanup()        // 清理 insert undo
      │           ├─ trx_flush_log_if_needed()        // 刷盘
      │           └─ trx->state = TRX_STATE_NOT_STARTED
      │
      └─ trx_init(trx)                               // 重置供下次使用
```

### 9.2 一条 UPDATE 的事务生命周期

```
UPDATE t SET c=2 WHERE id=1
  │
  ├─ trx_start_if_not_started_low()
  ├─ row_upd_clust_rec()
  │   ├─ 写 update undo log (TRX_UNDO_UPDATE_REC)
  │   │   ├─ 存储旧列值（更新向量）
  │   │   └─ 设置 DB_TRX_ID = trx->id
  │   │
  │   └─ 修改聚集索引页
  │       ├─ 设置 DB_ROLL_PTR → undo log record
  │       └─ 设置 DB_TRX_ID = 当前事务 ID
  │
  ├─ 如有二级索引被更新
  │   ├─ delete-mark 旧二级索引项
  │   └─ 插入新二级索引项
  │
  └─ 提交（与 INSERT 相同）
      └─ 差异在于 commit 后：
          ├─ UPDATE UNDO → TRX_UNDO_TO_PURGE（加入历史链表）
          └─ purge 线程稍后清理 delete-marked 记录
```

### 9.3 一个显式事务（BEGIN → 多条 SQL → COMMIT）的完整路径

```
mysql> BEGIN;       -- 不在 InnoDB 层触发操作，只是设置 MySQL 层状态
mysql> INSERT ...;  -- trx_start_if_not_started_low() → trx_start_low()
                    -- 分配 trx_id, rseg, undo log
                    -- 写 insert undo → 修改数据页

mysql> UPDATE ...;  -- 事务已 ACTIVE，跳过 trx_start_low
                    -- 写 update undo → 数据页 → 二级索引

mysql> SELECT ...;  -- (RR) trx_assign_read_view() → 创建 ReadView
                    -- 使用 ReadView::changes_visible() 判断可见性

mysql> COMMIT;      -- trx_commit()
                    -- Phase 1 (如果 binlog 开启且非只读):
                    --   trx_prepare() → 设置 undo 为 PREPARED
                    --   写 XID
                    -- Phase 2:
                    --   trx_write_serialisation_history()
                    --     → 分配 trx->no
                    --     → insert undo → CACHED
                    --     → update undo → TO_PURGE（加入历史链）
                    --     → 加入 serialisation_list
                    --   mtr_commit()
                    --   trx_commit_in_memory()
                    --     → 释放所有锁
                    --     → trx_undo_insert_cleanup()
                    --     → 刷 redo log
                    --     → state = NOT_STARTED
```

### 9.4 MVCC 一致性读在多版本中的可见性判断

```
场景：RR 隔离级别

时间线：
  T1: trx_id=100, BEGIN ── SELECT (创建 ReadView) ── COMMIT
  T2: trx_id=101, BEGIN ── UPDATE t SET c=2 WHERE id=1 ── COMMIT

ReadView (T1 在第 1 条 SELECT 时创建):
  m_low_limit_id = 102
  m_up_limit_id  = 101   (t1 系统中有 T2 活跃)
  m_ids          = {101} (活跃的读写事务)

T1 的第 2 条 SELECT:
  访问 id=1 的记录：
    DB_TRX_ID = 101
    → changes_visible(101, "t"):
      id(101) >= m_up_limit_id(101)? 否（相等不算 <）
      id(101) == m_creator_trx_id(100)? 否
      id(101) >= m_low_limit_id(102)? 否
      binary_search(m_ids, 101) → 找到
      → return false（不可见）

  因此通过 DB_ROLL_PTR 回溯 undo log，找到 T2 更新前的版本
  → 返回旧值 c=1
```

---

## 10. 关键函数索引

| 函数 | 文件:行 | 作用 |
|------|---------|------|
| `trx_start_low()` | `trx0trx.cc:1270` | 事务启动核心 |
| `trx_start_if_not_started_low()` | `trx0trx.cc:3338` | 按需启动事务 |
| `trx_start_if_not_started_xa_low()` | `trx0trx.cc:3306` | XA 下的按需启动 |
| `trx_commit()` | `trx0trx.cc:2229` | 事务提交入口 |
| `trx_commit_low()` | `trx0trx.cc:2137` | 低层提交 |
| `trx_commit_in_memory()` | `trx0trx.cc:1935` | 内存提交 |
| `trx_commit_complete_for_mysql()` | `trx0trx.cc:2470` | 两阶段提交完成 |
| `trx_write_serialisation_history()` | `trx0trx.cc:1537` | 序列化历史写入 |
| `trx_serialisation_number_get()` | `trx0trx.cc:1478` | 分配序列号 |
| `trx_add_to_serialisation_list()` | `trx0trx.cc:1436` | 加入序列化链表 |
| `trx_assign_rseg_durable()` | `trx0trx.cc:1241` | 分配持久化 rollback segment |
| `trx_assign_rseg_temp()` | `trx0trx.cc:1249` | 分配临时 rollback segment |
| `trx_set_rw_mode()` | `trx0trx.cc:3406` | 只读转读写模式 |
| `trx_assign_read_view()` | `trx0trx.cc:2310` | 分配一致性读视图 |
| `trx_mark_sql_stat_end()` | `trx0trx.cc:2479` | 标记 SQL 语句结束 |
| `trx_rollback_low()` | `trx0roll.cc:181` | 回滚核心 |
| `trx_rollback_for_mysql()` | `trx0roll.cc:269` | MySQL 层回滚入口 |
| `trx_rollback_to_savepoint_low()` | `trx0roll.cc:79` | 回滚到 savepoint |
| `trx_rollback_finish()` | `trx0roll.cc:1101` | 回滚完成处理 |
| `trx_rollback_step()` | `trx0roll.cc:1128` | 回滚图执行步骤 |
| `row_undo_step()` | `row0undo.cc:408` | 逐条 undo record |
| `trx_sys_create()` | `trx0sys.cc:601` | 事务系统初始化 |
| `trx_sys_init_at_db_start()` | `trx0sys.cc:481` | 启动时从崩溃恢复初始化 |
| `trx_sys_close()` | `trx0sys.cc:662` | 事务系统关闭 |
| `trx_sys_allocate_trx_id()` | `trx0sys.ic:226` | 分配事务 ID |
| `trx_sys_allocate_trx_no()` | `trx0sys.ic:233` | 分配序列号 |
| `trx_sys_allocate_trx_id_or_no()` | `trx0sys.ic:204` | 共用 ID/NO 分配器 |
| `trx_sys_rw_trx_add()` | `trx0sys.ic:262` | 添加到分片映射 |
| `ReadView::prepare()` | `read0read.cc:446` | 创建 ReadView |
| `ReadView::changes_visible()` | `read0types.h:68` | 可见性判断 |
| `MVCC::view_open()` | `read0read.cc:499` | 打开 MVCC 视图 |
| `MVCC::view_close()` | `read0read.cc:746` | 关闭 MVCC 视图 |
| `trx_purge()` | `trx0purge.cc:2396` | Purge 主函数 |
| `trx_purge_add_update_undo_to_history()` | `trx0purge.cc:352` | 添加 undo 到历史链表 |
| `trx_purge_remove_log_hdr()` | `trx0purge.cc:440` | 从历史链表移除 |
| `trx_purge_truncate_rseg_history()` | `trx0purge.cc:538` | 截断历史链表 |
| `trx_cleanup_at_db_startup()` | `trx0trx.cc:2247` | 数据库启动时清理 |

---

*本文基于 MySQL 8.4 InnoDB 源代码编写。事务系统是 InnoDB 最复杂的子系统之一，它协调了 undo log、redo log、锁系统、MVCC 和 purge 等多个模块，共同实现了 ACID 语义。理解 `trx_t` 和 `trx_sys_t` 两大核心结构体，以及 trx_start → trx_commit/trx_rollback 这条主线，是掌握整个事务系统的关键。*
