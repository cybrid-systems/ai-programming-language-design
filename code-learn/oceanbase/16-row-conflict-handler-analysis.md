# 16-row-conflict-handler — OceanBase 行级冲突处理的完整路径

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

行级冲突处理是 OceanBase 事务引擎中连接 **MVCC 层锁检测** 与 **SQL/DAS 层事务决策** 的关键桥梁。本文深入分析 `ObRowConflictHandler` 及其关联组件，追踪一行数据从发生冲突到最终被决策的全路径。

### 架构位置

```
SQL 层 (ObDMLService / ObConflictChecker)
    │
    ▼
DAS 层 (ObTableScan / ObTabletScan)
    │
    ▼
存储层 Memtable (ObMemtable::lock / ObMemtable::get)
    │
    ▼
MVCC 引擎 (ObMvccEngine::check_row_locked / mvcc_write)
    │
    ▼
ObRowConflictHandler ──▶ ObLockWaitMgr ──▶ ObDeadLockDetectorAdapter
                            │
                            ▼
                     锁等待 / 重试 / 回滚
```

### 与文章 03 的分工

| 维度 | 文章 03（写写冲突） | 本文（行级冲突处理 |
|------|--------------------|--------------------|
| 重点 | MVCC 层的冲突检测（`check_row_locked` + `mvcc_write` 的 6 种 Case） | 冲突检测后的决策：等待 / 回滚 / 重试 |
| 核心类 | `ObMvccRow` | `ObRowConflictHandler` |
| 锁等待 | 侧重数据结构（`ObLockWaitMgr::Node`） | 侧重入队/出队全路径 |
| 冲突类型 | 写写冲突（Write-Write） | 写写 + 读写 + 主键冲突 + 外键约束冲突 |

**本文的增量**：将 MVCC 层检测到的`lock_state`转化为 DAS/SQL 层的具体行动。

---

## 1. 核心数据结构

### 1.1 `ObStoreRowLockState` — 冲突信息描述符

```cpp
// src/storage/ob_i_store.h:225-295 — doom-lsp 确认
struct ObStoreRowLockState
{
  bool                 is_locked_;             // 行是否被其他事务锁定
  share::SCN           trans_version_;         // 行最新提交版本（TSC 判断用）
  transaction::ObTransID lock_trans_id_;       // 锁持有者事务 ID
  transaction::ObTxSEQ   lock_data_sequence_;  // 锁的 TxNode 序列号
  blocksstable::ObDmlFlag lock_dml_flag_;      // DML 类型（INSERT/UPDATE/DELETE/LOCK）
  bool                 is_delayed_cleanout_;   // 是否延迟清理（决定等待策略）
  memtable::ObMvccRow  *mvcc_row_;             // 行指针（快速重新检查锁状态）
  share::SCN            trans_scn_;            // 事务 SCN（memtable 场景 = tx_node->scn_）
};
```

**关键方法**（增强判断力）：

| 方法 | 用途 |
|------|------|
| `row_exist()` | 判断行是否存在（INSERT/UPDATE/LOCK 视为存在） |
| `row_deleted()` | 判断行是否被删除（DF_DELETE） |
| `is_locked_not_by(trans_id)` | 判断行是否被**其他**事务锁定 |
| `is_row_decided()` | 行的最终状态是否已确定 |
| `is_lock_decided()` | 锁的最终状态是否已确定 |

### 1.2 `ObRowConflictInfo` — 冲突信息的完整元数据

```cpp
// src/storage/memtable/ob_row_conflict_info.h:26-190 — doom-lsp 确认
struct ObRowConflictInfo
{
  common::ObAddr       conflict_happened_addr_;   // 冲突发生的位置（分布式场景）
  share::ObLSID        conflict_ls_;              // 冲突所属 LogStream
  common::ObTabletID   conflict_tablet_;           // 冲突所属 Tablet
  ObStringHolder       conflict_row_key_str_;      // 冲突行的 key
  SessionIDPair        conflict_sess_id_pair_;     // 持有者 Session 信息
  common::ObAddr       conflict_tx_scheduler_;     // 持有者事务的 Scheduler 地址（分布式）
  ObTransID            conflict_tx_id_;            // 持有者事务 ID
  ObTxSEQ              conflict_tx_hold_seq_;      // 持有者持有锁时的序列号
  uint64_t             conflict_hash_;             // 锁等待 hash 值
  int64_t              lock_seq_;                  // 锁等待槽位序列号
  int64_t              abs_timeout_;               // 锁等待绝对超时时间
  ObTransID            self_tx_id_;                // 请求者事务 ID
  // ... 还有 last_compact_cnt_, total_update_cnt_, 各种 session ID
};
```

**设计意图**：`ObRowConflictInfo` 不仅仅传递冲突的基本信息，还包含了分布式事务场景需要的所有元数据——Scheduler 地址、Session 信息、超时时间——使得远程协调者也能准确处理冲突。

---

## 2. `ObRowConflictHandler` 类设计

`ObRowConflictHandler` 是一个**纯静态类**，所有方法都是 `static` 的。它的定位是：**冲突检测后的第一个决策点**。

### 2.1 类的接口总览

```cpp
// src/storage/memtable/ob_row_conflict_handler.h:50-89 — doom-lsp 确认
class ObRowConflictHandler {
public:
  // 第一组：通用行锁检查（两个重载）
  static int check_row_locked(param, context, rowkey,
                              by_myself = false, post_lock = false);
  static int check_row_locked(param, context, rowkey,
                              lock_state, max_trans_version);

  // 第二组：外键约束的冲突检查
  static int check_foreign_key_constraint(param, context, rowkey);
  static int check_foreign_key_constraint_for_memtable(acc_ctx, value, lock_state);
  static int check_foreign_key_constraint_for_sstable(tx_table_guards, ...);

  // 第三组：将冲突注册到锁等待管理器
  static int post_row_read_conflict(acc_ctx, row_key, lock_state,
                                    tablet_id, ls_id, ...);
};
```

**三类方法的职责**：
1. **check_row_locked**：遍历所有存储层（Memtable → SSTable → DDL KV），检测行是否被锁定
2. **check_foreign_key_constraint**：外键约束场景下的冲突检查（读-写冲突的特殊形式）
3. **post_row_read_conflict**：在确认冲突后，将冲突信息注册到 `ObLockWaitMgr`

### 2.2 `check_row_locked`（核心重载）— 遍历所有存储层

```cpp
// src/storage/memtable/ob_row_conflict_handler.cpp:64-153 — doom-lsp 确认
int ObRowConflictHandler::check_row_locked(const ObTableIterParam &param,
                                           ObTableAccessContext &context,
                                           const ObDatumRowkey &rowkey,
                                           ObStoreRowLockState &lock_state,
                                           share::SCN &max_trans_version)
{
  // 从 table_iter_ 遍历所有存储层
  ObIArray<ObITable *> iter_tables;
  ctx->table_iter_->resume();
  while (OB_SUCC(ret)) {
    ObITable *table_ptr = nullptr;
    if (OB_FAIL(ctx->table_iter_->get_next(table_ptr))) {
      if (OB_ITER_END != ret) { ... }
    } else if (OB_FAIL(iter_tables.push_back(table_ptr))) { ... }
  }

  // ▼ 按优先级从新到旧遍历：Memtable → DDL KV → SSTable
  for (int64_t i = stores->count() - 1; OB_SUCC(ret) && i >= 0; i--) {
    lock_state.reset();
    if (stores->at(i)->is_data_memtable()) {
      // Memtable：调用 mvcc_engine_->check_row_locked()
      memtable->get_mvcc_engine().check_row_locked(ctx, &mtk, lock_state);
    } else if (stores->at(i)->is_direct_load_memtable()) {
      // 直接加载的 Memtable（DDL 场景）：调用 ddl_kv->check_row_locked()
      ddl_kv->check_row_locked(param, rowkey, context, lock_state);
    } else if (stores->at(i)->is_sstable()) {
      // SSTable：调用 sstable->check_row_locked()
      // 内部使用 ObMicroBlockRowLockChecker 逐块检查
      sstable->check_row_locked(param, rowkey, context, lock_state);
    }
    // ★ 任意一层检测到锁定立即停止遍历
    if (lock_state.is_locked_) break;
    if (max_trans_version < lock_state.trans_version_)
      max_trans_version = lock_state.trans_version_;
  }
}
```

**遍历策略的关键点**：

- **从最新到最旧遍历**：因为最新的 Memtable 包含最实时的锁信息
- **任一存储层检测到锁立即停止**：避免不必要的遍历开销
- **未锁定时记录 `max_trans_version`**：用于 TSC（Transaction Set Consistency）检查

---

## 3. 冲突检测的完整路径

### 3.1 DAS Insert/Update/Delete 路径

当 DAS 层执行行级 DML 操作时，通过 `ObMemtable::lock()` 或 `ObMemtable::set()` 触发锁检测：

```cpp
// src/storage/memtable/ob_memtable.cpp:618-710 — doom-lsp 确认
int ObMemtable::set(param, context, col_desc, row) {
  // ...
  if (acc_ctx.write_flag_.is_check_row_locked()) {
    // ★ WriteFlag 指示需要检查行锁（外键约束场景）
    if (OB_FAIL(ObRowConflictHandler::check_foreign_key_constraint(
                param, context, tmp_key))) {
      // OB_TRY_LOCK_ROW_CONFLICT / OB_TRANSACTION_SET_VIOLATION
      // 这两种错误码被透传给 DAS/SQL 层
    }
  } else if (OB_FAIL(guard.write_auth(*context.store_ctx_))) {
    // ...
  } else if (OB_FAIL(lock_(param, context, tmp_key, mtk))) {
    // lock_ 内部调用 mvcc_write，在写阶段检查锁
  }
}

int ObMemtable::lock(param, context, rowkey) {
  // 与 set() 类似，但仅锁定不写入数据
  if (acc_ctx.write_flag_.is_check_row_locked()) {
    ObRowConflictHandler::check_foreign_key_constraint(param, context, rowkey);
  } else if (OB_FAIL(lock_(param, context, tmp_key, mtk))) { ... }
}
```

**`is_check_row_locked()` 的触发场景**：DML 操作涉及外键约束（如子表插入需要检查父表对应行的锁状态）。这是 OceanBase 的一个优化——只有涉及外键约束时才执行读路径的锁检查，否则延迟到 `mvcc_write` 时检测写写冲突。

### 3.2 外键约束检查的冲突处理

```cpp
// src/storage/memtable/ob_row_conflict_handler.cpp:156-185 — doom-lsp 确认
int ObRowConflictHandler::check_foreign_key_constraint(param, context, rowkey) {
  // 转换为 DatumRowkey 后调用 check_row_locked(by_myself=false, post_lock=true)
  if (OB_FAIL(check_row_locked(param, context, datum_rowkey,
                               false /*by_myself*/, true /*post_lock*/))) {
    if (OB_TRY_LOCK_ROW_CONFLICT == ret) {
      // ★ 行被锁定 → 直接通过 post_lock=true 注册锁等待
      // （check_row_locked 内部已调用 post_row_read_conflict）
    } else if (OB_TRANSACTION_SET_VIOLATION == ret) {
      // 行已提交但版本 > snapshot → SQL 层决定重试或抛异常
    }
  }
}
```

### 3.3 主键冲突检测

主键冲突（Duplicate Key）不经过 `ObRowConflictHandler`，它在 `ObMvccRow::mvcc_write` 的 Case 4 检测：

```cpp
// src/storage/memtable/mvcc/ob_mvcc_row.cpp — doom-lsp 确认行号需要重新验证
if (check_exist && res.lock_state_.row_exist()) {
  ret = OB_ERR_PRIMARY_KEY_DUPLICATE;  // ★ 主键冲突
}
```

**主键冲突 vs 行锁冲突的区别**：

| 维度 | 主键冲突 | 行锁冲突 |
|------|---------|---------|
| 检测位置 | `mvcc_write`（写阶段） | `check_row_locked`（读阶段） |
| 触发条件 | 插入已存在的行（已提交） | 行被其他未提交事务锁定 |
| 响应 | 立即返回 SQL 层，SQL 层决定 | 进入 `ObLockWaitMgr` 等待或失败 |
| 错误码 | `OB_ERR_PRIMARY_KEY_DUPLICATE` | `OB_TRY_LOCK_ROW_CONFLICT` |

---

## 4. `post_row_read_conflict` — 从冲突检测到锁等待的核心桥梁

```cpp
// src/storage/memtable/ob_row_conflict_handler.cpp:255-340 — doom-lsp 确认
int ObRowConflictHandler::post_row_read_conflict(ObMvccAccessCtx &acc_ctx,
                                                 const ObStoreRowkey &row_key,
                                                 ObStoreRowLockState &lock_state,
                                                 const ObTabletID tablet_id,
                                                 const share::ObLSID ls_id, ...) {
  ObLockWaitMgr *lock_wait_mgr = nullptr;
  ObTransID conflict_tx_id = lock_state.lock_trans_id_;
  ObTxSEQ conflict_tx_hold_seq = lock_state.lock_data_sequence_;
  ObTxDesc *tx_desc = acc_ctx.get_tx_desc();
  int64_t current_ts = common::ObClockGenerator::getClock();
  int64_t lock_wait_expire_ts = acc_ctx.eval_lock_expire_ts(current_ts);

  // Step 1: 检查锁等待是否已超时
  if (current_ts >= lock_wait_expire_ts) {
    ret = OB_ERR_EXCLUSIVE_LOCK_CONFLICT;  // ★ 立即超时，不进入等待
    TRANS_LOG(WARN, "exclusive lock conflict", ...);
  }
  // Step 2: 构造 recheck_func — 唤醒时需要重新检查锁状态
  ObFunction<int(bool&, bool&)> recheck_func([&](bool &locked, bool &wait_on_row) -> int {
    if (lock_state.is_delayed_cleanout_) {
      // 延迟清理 → 通过 ObTxTable 检查（需要查事务表）
      tx_table_guards.check_row_locked(tx_id, conflict_tx_id,
                                       lock_data_sequence, trans_scn, lock_state);
    } else {
      // 普通情况 → 直接通过 mvcc_row 重新检查
      lock_state.mvcc_row_->check_row_locked(acc_ctx, lock_state);
    }
    locked = lock_state.is_locked_ && lock_state.lock_trans_id_ != tx_id;
    wait_on_row = !lock_state.is_delayed_cleanout_;
    return ret;
  });

  // Step 3: 双重检查 — 避免 `get_seq_` 和 `recheck` 之间锁释放
  //         导致永久的锁等待（错过唤醒信号）
  do {
    row_lock_seq = get_seq_(row_hash);
    tx_lock_seq = get_seq_(tx_hash);
    if (OB_FAIL(recheck_func(locked, wait_on_row))) { ... }
  } while (OB_SUCC(ret) && locked);

  // Step 4: 注册到 LockWaitMgr
  ObRowConflictInfo cflict_info;
  tmp_ret = lock_wait_mgr->post_lock(OB_TRY_LOCK_ROW_CONFLICT,
                                     ls_id, tablet_id, row_key,
                                     lock_wait_expire_ts, remote_tx,
                                     ... /* conflict info */,
                                     recheck_func);

  // Step 5: 将冲突信息记录到 TxDesc（用于后续分布式死锁检测）
  tx_desc->add_conflict_info(cflict_info);
}
```

### 4.1 `recheck_func` 的关键作用

`recheck_func` 是在锁唤醒后执行的回调，它决定：
1. 锁是否真的已释放（`locked` 标志）
2. 当前等待的是行锁还是事务锁（`wait_on_row` 标志）

**两种等待策略**：

| `wait_on_row` | `recheck` 路径 | 含义 |
|--------------|----------------|------|
| `true` | `mvcc_row_->check_row_locked()` | 等待**行级**锁释放（普通情况） |
| `false` | `tx_table_guards.check_row_locked()` | 等待**事务**状态确定（延迟清理的情况） |

### 4.2 双重检查的必要性

```cpp
do {
  row_lock_seq = get_seq_(row_hash);     // 记录当前行锁序列号
  tx_lock_seq = get_seq_(tx_hash);       // 记录当前事务锁序列号
  if (OB_FAIL(recheck_func(locked, wait_on_row))) { ... }
} while (OB_SUCC(ret) && locked);
```

**为什么需要双重检查？** 考虑以下竞态条件：

1. T1 检查锁 → 发现被 T2 持有 → 读取 `get_seq_(hash)` = 5
2. T2 释放锁 → `sequence_[bucket]` = 6
3. T1 执行 `recheck_func` → 锁已释放 → `locked` = `false`
4. T1 退出循环，无需等待

如果没有双重检查，可能发生：
1. T1 先执行 `recheck_func` → 锁仍被持有 → `locked` = `true`
2. T2 释放锁 → `sequence_[bucket]` = 6
3. T1 读取 `get_seq_(hash)` = 6
4. T1 进入 `wait_` 等待这个不再被持有的锁 → **永远等不到唤醒**

---

## 5. `ObLockWaitMgr::post_lock` — 冲突信息入队

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp:1547-1640 — doom-lsp 确认
int ObLockWaitMgr::post_lock(const int tmp_ret,
                             const ObLSID &ls_id, ...) {
  if (OB_TRY_LOCK_ROW_CONFLICT == tmp_ret) {
    // 计算 hash 值：wait_on_row → row_hash，否则 → tx_hash
    uint64_t hash = wait_on_row ? row_hash : tx_hash;

    // 设置等待队列头节点的超时时间
    reset_head_node_wait_timeout_if_need(hash, lock_ts);

    // 构建 ObRowConflictInfo，包含分布式信息
    cflict_info.init(addr_, ls_id, tablet_id, ...);

    // 获取冲突事务的 Scheduler 信息（分布式场景需要）
    ObTransDeadlockDetectorAdapter::get_trans_info_on_participant(...);
  }
}
```

---

## 6. 写路径的冲突（`mvcc_write` 的 Case 5/6）

写路径的冲突在 `ObMvccRow::mvcc_write` 中检测（文章 03 已分析）：

```cpp
// src/storage/memtable/mvcc/ob_mvcc_row.cpp — Case 5/6
// Case 5: snapshot 版本 > 头节点行版本（TSC 错误）
// Case 6: 其他事务持有锁 → OB_TRY_LOCK_ROW_CONFLICT
```

写路径的冲突不经过 `post_row_read_conflict`，而是通过 `ObMemtable` 的上层调用者处理：

```cpp
// src/storage/memtable/ob_memtable.cpp:786-800 — doom-lsp 确认
// 写路径冲突 → 在 mvcc_engine->get() 中检测
// 如果 get 返回 OB_TRY_LOCK_ROW_CONFLICT 且是外键检查场景：
if (OB_TRY_LOCK_ROW_CONFLICT == ret){
  ObRowConflictHandler::post_row_read_conflict(
      context.store_ctx_->mvcc_acc_ctx_,
      *parameter_mtk.get_rowkey(),
      lock_state,
      key_.tablet_id_,
      get_ls_id(), ...);
}
```

同样在单行扫描器中有类似调用：

```cpp
// src/storage/memtable/ob_memtable_single_row_reader.cpp:307 — doom-lsp 确认
// 在 get_next_value_iter_ 中检测到冲突时：
if (OB_TRY_LOCK_ROW_CONFLICT == ret) {
  ObRowConflictHandler::post_row_read_conflict(
      context_->store_ctx_->mvcc_acc_ctx_,
      *tmp_rowkey, lock_state,
      context_->tablet_id_,
      context_->ls_id_, ...);
}
```

---

## 7. 冲突解决模式

| 模式 | 错误码 | 触发条件 | 后续行为 |
|------|--------|---------|---------|
| **立即失败** | `OB_ERR_EXCLUSIVE_LOCK_CONFLICT` | 当前时间 ≥ `lock_wait_expire_ts` | 不进入等待队列，直接返回 SQL 层 |
| **锁等待** | `OB_TRY_LOCK_ROW_CONFLICT` | 行被锁定，未超时 | 注册到 `ObLockWaitMgr`，等待唤醒 |
| **TSC 回滚** | `OB_TRANSACTION_SET_VIOLATION` | 行已提交但版本 > snapshot | SQL 层重试或抛异常 |
| **主键冲突** | `OB_ERR_PRIMARY_KEY_DUPLICATE` | 插入已存在行 | SQL 层根据 INSERT 语义决策 |

### 7.1 锁等待的完整状态机

```
     ┌─────────────────────────────────────┐
     │  T1 检测到冲突                       │
     │  check_row_locked() → is_locked=true │
     └──────────┬──────────────────────────┘
                │
                ▼
     ┌──────────────────────────────┐
     │  post_row_read_conflict()    │
     │  ① 检查锁等待超时            │
     │  ② 构造 recheck_func        │
     │  ③ 双重检查锁状态            │
     └──────────┬───────────────────┘
                │
                ▼
     ┌───────────────────────────────────┐
     │  lock_wait_mgr->post_lock()       │
     │  ① 计算 hash（row_hash/tx_hash） │
     │  ② reset_head_node_wait_timeout   │
     │  ③ 构建 ObRowConflictInfo        │
     └──────────┬────────────────────────┘
                │
                ▼
    ┌─────────────────────────────────────────┐
    │  handle_local_node_()                   │
    │  → register_local_node_to_deadlock_()   │
    │  → wait_(node) — 线程阻塞，等待唤醒     │
    └──────┬──────────────────────────────┬───┘
           │                              │
           ▼                              ▼
    ┌──────────────┐             ┌──────────────────┐
    │ 锁释放唤醒     │             │ 超时/Session 杀死 │
    │ T2 提交事务后   │             │ check_timeout()   │
    │ sequence_++    │             │ 检测到超时        │
    │ recheck_func:  │             └────────┬─────────┘
    │ locked=false   │                      ▼
    └───────┬───────┘             ┌──────────────────┐
            │                     │ wait_succ=false   │
            ▼                     │ 从 deadlock 注销  │
    ┌──────────────┐              │ ret = OB_TIMEOUT  │
    │ T1 重试操作   │             └──────────────────┘
    └──────────────┘
```

---

## 8. 读路径的冲突（`check_row_locked` vs 写路径的区别）

### 8.1 读路径调用 `check_row_locked` 的场景

读操作（`ObMemtable::get`/`scan`）在以下场景需要检查行锁：

```cpp
// src/storage/memtable/mvcc/ob_mvcc_engine.cpp:232-249
// ObMvccEngine::get 内部调用：
if (OB_FAIL(value->check_row_locked(ctx, lock_state))) {
  // 返回 OB_TRY_LOCK_ROW_CONFLICT 或 OB_TRANSACTION_SET_VIOLATION
}
```

读路径使用 `ObMvccRow::check_row_locked` 的完整实现（文章 03 的 Case 分析）：

```cpp
// src/storage/memtable/mvcc/ob_mvcc_row.cpp:1130-1195 — doom-lsp 确认
int ObMvccRow::check_row_locked(ObMvccAccessCtx &ctx,
                                ObStoreRowLockState &lock_state) {
  // 获取行锁 → 遍历链表头节点 → 判断节点状态
  // Case 1: 空链表 → is_locked_=false
  // Case 2: 延迟清理 + 未决 → cleanout 后重试
  // Case 3: 已提交/ELR → is_locked_=false
  // Case 4: 已中止 → 跳过看下一个
  // Case 5: 未决 → is_locked_=true（锁被持有）
}
```

### 8.2 读路径 vs 写路径冲突的区别

| 维度 | 读路径冲突 | 写路径冲突 |
|------|-----------|-----------|
| 检测函数 | `ObMvccRow::check_row_locked()` | `ObMvccRow::mvcc_write()` |
| 触发时机 | get/scan 读取时 | write/set 写入时 |
| 返回错误码 | `OB_TRY_LOCK_ROW_CONFLICT` 或 `OB_TRANSACTION_SET_VIOLATION` | 同上 + `OB_ERR_PRIMARY_KEY_DUPLICATE` |
| 调用 `post_row_read_conflict` | 是（外键检查场景） | 是（通过`ObMemtable`上层调用） |
| 额外行为 | 可能被 `OB_ERR_UNEXPECTED` 拦截（非外键检查时） | `mvcc_undo()` 回滚已写入的 TxNode |

### 8.3 读路径对 `OB_ERR_UNEXPECTED` 的防护

```cpp
// src/storage/memtable/ob_memtable_single_row_reader.cpp:307
if (OB_TRY_LOCK_ROW_CONFLICT == ret || OB_TRANSACTION_SET_VIOLATION == ret) {
  if (!context_->query_flag_.is_for_foreign_key_check()) {
    // ★ 非外键检查的读操作碰上冲突 → 转成 OB_ERR_UNEXPECTED
    // 这是防止 DAS 读路径无意义地进入锁等待
    ret = OB_ERR_UNEXPECTED;
  } else if (OB_TRY_LOCK_ROW_CONFLICT == ret) {
    ObRowConflictHandler::post_row_read_conflict(...);  // 注册锁等待
  }
}
```

**设计意图**：普通读操作不需要等待锁释放（MVCC 读不会写数据），只有涉及外键约束的读（如 `SELECT ... FOR UPDATE` 或外键检测）才真正需要等待。非外键的读操作检测到冲突时直接报错，避免无意义的锁等待。

---

## 9. 锁等待管理器（`ObLockWaitMgr`）深度补充

### 9.1 等待队列的数据结构

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.h:71-471 — doom-lsp 确认
class ObLockWaitMgr {
  static const int64_t LOCK_BUCKET_COUNT = 16384;  // 16384 个桶
  Hash *hash_;          // FixedHash2<Node> — 每个桶一个等待链表
  int64_t sequence_[LOCK_BUCKET_COUNT];  // 每个桶的锁序列号

  // 哈希类型（通过 hash 值的高位标志位区分）
  // LockHashHelper：
  //   ROW_FLAG (00) → hash_rowkey(tablet_id, key)
  //   TRANS_FLAG (10) → hash_trans(tx_id)
  //   TABLE_LOCK_FLAG (01) → hash_lock_id(lock_id)
};
```

### 9.2 `handle_local_node_` — 本地等待的完整处理

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp:859-888 — doom-lsp 确认
int ObLockWaitMgr::handle_local_node_(Node* node, Node*& delete_node,
                                      bool &wait_succ) {
  ObTransID self_tx_id(node->tx_id_);
  ObTransID blocked_tx_id(node->holder_tx_id_);

  // Step 1: 注册死锁检测
  if (ObDeadLockDetectorMgr::is_deadlock_enabled()) {
    if (OB_FAIL(register_local_node_to_deadlock_(self_tx_id,
                                                  blocked_tx_id, node))) {
      // 注册失败（可能检测到死锁）
    }
  }

  // Step 2: 开始等待
  wait_succ = wait_(node, delete_node, is_placeholder);

  // Step 3: 等待结束 → 从死锁检测器注销
  if (!wait_succ && deadlock_registered) {
    ObTransDeadlockDetectorAdapter::unregister_from_deadlock_detector(
        self_tx_id, LOCK_WAIT_MGR_WAIT_FAILED);
  }
}
```

### 9.3 `wait_` — 核心等待逻辑

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp:1127-1170 — doom-lsp 确认
bool ObLockWaitMgr::wait_(Node* node, Node*& delete_node, bool &is_placeholder)
{
  uint64_t hash = node->hash();
  int64_t last_lock_seq = node->lock_seq_;  // 入队时的锁序列号

  CriticalGuard(get_qs());  // 获取 QSync 锁（读写临界区）

  if (node->get_node_type() == rpc::ObLockWaitNode::REMOTE_CTRL_SIDE) {
    // 远程协调者节点 → 直接入队等待 RPC 唤醒
    insert_node_(node);
    wait_succ = true;
  } else if (check_wakeup_seq_(hash, last_lock_seq, cur_seq)) {
    // 序列号未变 → 锁仍被持有 → 入队等待
    insert_node_(node);
    wait_succ = true;
    // 双重检查：防止插入后锁被释放
    if (!check_wakeup_seq_(hash, last_lock_seq, cur_seq)) {
      wait_succ = on_seq_change_after_insert_(node, delete_node, enqueue_succ);
    }
  } else {
    // 序列号已变 → 锁已释放 → 不需要等待
    wait_succ = on_seq_change_(node, delete_node, enqueue_succ, cur_seq);
  }
}
```

### 9.4 唤醒机制

**本地唤醒**（锁持有者提交事务时）：

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp:447 — doom-lsp 确认
void ObLockWaitMgr::wakeup(const ObTabletID &tablet_id, const Key& key) {
  uint64_t hash = LockHashHelper::hash_rowkey(tablet_id, key);
  CriticalGuard(get_qs());
  Node* head = fetch_wait_head(hash);
  if (head != nullptr) {
    // ★ 递增序列号：所有等待该锁的节点 detect 序列号变化
    ATOMIC_INC(&sequence_[(hash >> 1) % LOCK_BUCKET_COUNT]);
    // 唤醒等待队列
    repost(node);
  }
}
```

**`check_wakeup_seq_` 核心原理**：

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.h:412 — doom-lsp 确认
bool check_wakeup_seq_(uint64_t hash, int64_t lock_seq, int64_t &cur_seq) {
  cur_seq = ATOMIC_LOAD(&sequence_[(hash >> 1) % LOCK_BUCKET_COUNT]);
  return cur_seq == lock_seq;  // 相等 → 锁仍被持有
}
```

当锁释放时，`wakeup_` 递增 `sequence_[bucket]`，所有等待线程的 `check_wakeup_seq_` 返回 `false`，触发 `on_seq_change_` 停止等待。

---

## 10. 死锁检测集成

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp:988-1040 — doom-lsp 确认
int ObLockWaitMgr::register_local_node_to_deadlock_(const ObTransID &self_tx_id,
                                                     const ObTransID &blocked_tx_id,
                                                     const Node * const node) {
  if (LockHashHelper::is_rowkey_hash(node->hash())) {
    // ★ 等待行锁：注册 "waiting for row" 边
    ObTransDeadlockDetectorAdapter::lock_wait_mgr_reconstruct_detector_waiting_for_row(
        on_collect_callback, deadlock_block_callback, ...);
  } else {
    // ★ 等待事务：注册 "waiting for trans" 边
    ObTransDeadlockDetectorAdapter::lock_wait_mgr_reconstruct_detector_waiting_for_trans(
        on_collect_callback, ...);
  }
}
```

**等待图的边类型**：
- **waiting for row**：T1 → 行（T1 等这个行被释放）
- **waiting for trans**：T1 → T2（T1 等 T2 结束）

**死锁检测的触发时机**：每次注册等待边时，LCL（Lazy Cycle Detection）算法检查是否形成环。

---

## 11. 超时管理

### 11.1 等待超时计算

```cpp
// src/storage/memtable/ob_row_conflict_handler.cpp:265 — doom-lsp 确认
int64_t lock_wait_expire_ts = acc_ctx.eval_lock_expire_ts(current_ts);
// eval_lock_expire_ts 计算：min(锁等待配置, 事务超时时间)
// 与 MySQL 的 innodb_lock_wait_timeout 语义一致
```

### 11.2 周期性超时扫描

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp:111 — doom-lsp 确认
// ObLockWaitMgr::run1() — 后台线程，每 100ms 运行一次
static const int64_t CHECK_TIMEOUT_INTERVAL = 100 * 1000; // 100ms

void ObLockWaitMgr::check_wait_node_session_stat_(Node *iter,
                                                   Node *&node2del,
                                                   int64_t curr_ts,
                                                   int64_t wait_timeout_ts) {
  // 检查等待线程的 session 是否还存活
  // 如果 session 被 kill → 从队列移除
  // 如果等待超时 → 从队列移除，唤醒后续节点
}
```

---

## 12. SSTable 层的冲突检查

OceanBase 的冲突检查不仅限于 Memtable，SSTable 也有自己的锁检查逻辑：

```cpp
// src/storage/blocksstable/ob_sstable.cpp:955 — doom-lsp 确认
int ObSSTable::check_row_locked(param, rowkey, context, lock_state, check_exist) {
  // 创建 ObMicroBlockRowLockChecker
  // 逐块扫描 SSTable 的微块，检测是否有未提交的事务节点
  row_checker.check_row_locked(check_exist, snapshot_version,
                                base_version, inc_major_trans_version, lock_state);
}
```

**SSTable 锁检查的特殊性**：SSTable 中的事务节点可能来自冻结的 Memtable，这些事务可能仍未提交。通过 `ObTxTableGuards::check_row_locked` 查询事务表来确定锁状态：

```cpp
// src/storage/blocksstable/ob_micro_block_row_lock_checker.cpp:149 — doom-lsp 确认
tx_table_guards.check_row_locked(read_trans_id, data_trans_id,
                                  sql_sequence, end_scn, lock_state);
```

---

## 13. `check_foreign_key_constraint_for_*` 系列

### 13.1 Memtable 场景

```cpp
// src/storage/memtable/ob_row_conflict_handler.cpp:187-213 — doom-lsp 确认
int ObRowConflictHandler::check_foreign_key_constraint_for_memtable(
    ObMvccAccessCtx &ctx, ObMvccRow *value, ObStoreRowLockState &lock_state) {
  // 调用 ObMvccRow::check_row_locked
  value->check_row_locked(ctx, lock_state);

  if (lock_state.is_locked_ && my_tx_id != lock_state.lock_trans_id_) {
    ret = OB_TRY_LOCK_ROW_CONFLICT;  // 外键约束的行被锁
  } else if (!lock_state.is_locked_ && lock_state.trans_version_ > snapshot_version) {
    ret = OB_TRANSACTION_SET_VIOLATION;  // TSC 错误
  }
}
```

### 13.2 SSTable 场景

```cpp
// src/storage/memtable/ob_row_conflict_handler.cpp:215-252 — doom-lsp 确认
int ObRowConflictHandler::check_foreign_key_constraint_for_sstable(
    ObTxTableGuards &tx_table_guards, ...) {
  if (!data_trans_id.is_valid()) {
    // 事务已提交，trans_id 无效
    if (trans_version > snapshot_version) {
      ret = OB_TRANSACTION_SET_VIOLATION;
    }
  } else {
    // 未提交 → 通过 TxTable 检查
    tx_table_guards.check_row_locked(read_trans_id, data_trans_id,
                                      sql_sequence, end_scn, lock_state);
    if (lock_state.is_locked_ && read_trans_id != lock_state.lock_trans_id_) {
      ret = OB_TRY_LOCK_ROW_CONFLICT;
    }
  }
}
```

---

## 14. 完整数据流图

```
DAS Insert/Update/Delete
        │
        ▼
ObMemtable::lock / ObMemtable::set
        │
        ▼
┌─ is_check_row_locked()? ────────────────────┐
│  YES:                                        │  NO:
│  check_foreign_key_constraint()              │  mvcc_write()
│    └─ check_row_locked()                     │    └─ mvcc_write() 内部
│         (遍历 Memtable → DDL KV → SSTable)   │       Case 5/6
│         ↓                                    │       ↓
│    is_locked?                                │  OB_TRY_LOCK_ROW_CONFLICT
│    ↓                                         │       ↓
│  YES ── OB_TRY_LOCK_ROW_CONFLICT             │  ObMemtable::get() 检测
│         ↓                                    │       ↓
│    post_row_read_conflict()                  │  post_row_read_conflict()
│         ↓                                    │       │
│    lock_wait_mgr->post_lock() ◄──────────────┘       │
│         │                                             │
│         ▼                                             │
│    handle_local_node_()                                │
│    ├─ register_local_node_to_deadlock_()              │
│    └─ wait_(node)                                     │
│         ├─ check_wakeup_seq_() == true                │
│         │    → 入队等待                                │
│         └─ check_wakeup_seq_() == false               │
│              → 锁已释放，直接继续                        │
│                                                        │
│  NO ── OB_TRANSACTION_SET_VIOLATION                    │
│         ↓                                              │
│    SQL 层: 根据隔离级别决定重试或放弃                     │
└────────────────────────────────────────────────────────┘
```

### 冲突类型决策树

```
check_row_locked 返回 lock_state
        │
        ▼
lock_state.is_locked_?
    │            │
   YES           NO
    │            │
    │            max_trans_version > snapshot_version?
    │               │                │
    │              YES               NO
    │               │                │
    │          TSC 错误          无冲突
    │          (读-写冲突)       (继续执行)
    │               │
    ▼               ▼
lock_trans_id_ ≠ my_tx_id?
    │
   YES ──OB_TRY_LOCK_ROW_CONFLICT──post_row_read_conflict──→ 锁等待
    │
   NO  ──锁是自己持有的 → 继续（同一事务重复锁定）
```

---

## 15. 设计决策分析

### 15.1 为什么冲突检测下沉到 MVCC 层，冲突处理在 RowConflictHandler？

| 层 | 职责 | 理由 |
|----|------|------|
| `ObMvccRow::check_row_locked` | 检测**是否**有锁，返回 `ObStoreRowLockState` | MVCC 层拥有行的完整版本链信息 |
| `ObMvccRow::mvcc_write` | 写入数据时检测写写/主键冲突 | 写入原子性由 MVCC 层保证 |
| `ObRowConflictHandler::post_row_read_conflict` | 注册锁等待，构造 recheck_func | 需要访问上层组件（`ObLockWaitMgr`, `ObTxDesc`） |
| `ObLockWaitMgr::post_lock` | 管理等待队列，协调死锁检测 | 独立的锁等待子系统 |

**分层原因**：MVCC 层关注"**有没有锁**"，RowConflictHandler 关注"**锁了怎么办**"。

### 15.2 锁等待的超时策略

锁等待超时 `lock_wait_expire_ts` 由 `eval_lock_expire_ts` 计算，综合考虑：
- 事务配置的超时时间（`ob_trx_lock_timeout`）
- 语句级别的超时时间
- 全局 `lock_wait_timeout` 配置

超时后返回 `OB_ERR_EXCLUSIVE_LOCK_CONFLICT`（`ER_LOCK_WAIT_TIMEOUT`），与 MySQL 的 `innodb_lock_wait_timeout` 行为一致。

### 15.3 死锁检测的触发时机

- **本地场景**：每次 `handle_local_node_` 调用 `register_local_node_to_deadlock_` 时触发
- **远程场景**：通过 `register_remote_node_to_deadlock_` 在 RPC 中传递死锁检测信息
- **行锁 vs 事务锁**：行锁通过 `row_holder_mapper_` 映射到持有者事务，事务锁直接形成等待边

### 15.4 双重检查模式的价值

`post_row_read_conflict` 中的双重检查（`do...while(locked)`）解决了一个微妙的竞态问题：假设 `recheck_func` 返回锁仍被持有且同时锁被释放，如果仅检查一次，可能读取到过期的 `sequence_[bucket]` 导致永久等待。双重检查确保入队时的快照与当前锁状态一致。

### 15.5 `is_delayed_cleanout_` 的设计权衡

延迟清理（`is_delayed_cleanout_`）意味着事务状态尚未写入 TxTable。这种情况下：
- 无法直接通过 `ObMvccRow` 判断锁状态（因为 TxNode 的状态不确定）
- 需要通过 `ObTxTableGuards::check_row_locked` 查询事务表
- 等待策略变为"等待事务"而非"等待行"（`wait_on_row = false`）

这是一个空间换时间的经典选择：延迟写入 TxTable 减少提交路径的 I/O，但增加了锁等待路径的复杂度。

---

## 16. 与文章 05（compact）的关联

Compact 操作（`ObMvccRow::compact`）会影响冲突检测：

```cpp
// 文章 05 分析的 compact 逻辑
// Compact 会合并已提交的 TxNode，减少版本链长度
// 但 compact 不会影响未提交的节点（锁的持有者）
```

**compact 与冲突检测的交互**：
1. Compact 合并已提交的版本，但**未提交的节点保留在头部**
2. 冲突检测只需要检查头节点 → compact 不改变冲突检测的逻辑
3. 但 compact 可能改变 `last_compact_cnt_`，这个计数器传递给 `ObRowConflictInfo`，用于统计监控

---

## 17. 源码文件索引

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/storage/memtable/ob_row_conflict_handler.h` | `class ObRowConflictHandler` | 50 |
| `src/storage/memtable/ob_row_conflict_handler.cpp` | `check_row_locked()` 第一个重载 | 26 |
| `src/storage/memtable/ob_row_conflict_handler.cpp` | `check_row_locked()` 第二个重载（遍历存储层） | 64 |
| `src/storage/memtable/ob_row_conflict_handler.cpp` | `check_foreign_key_constraint()` | 156 |
| `src/storage/memtable/ob_row_conflict_handler.cpp` | `check_foreign_key_constraint_for_memtable()` | 187 |
| `src/storage/memtable/ob_row_conflict_handler.cpp` | `check_foreign_key_constraint_for_sstable()` | 215 |
| `src/storage/memtable/ob_row_conflict_handler.cpp` | `post_row_read_conflict()` | 255 |
| `src/storage/memtable/ob_row_conflict_info.h` | `struct ObRowConflictInfo` | 26 |
| `src/storage/ob_i_store.h` | `struct ObStoreRowLockState` | 225 |
| `src/storage/memtable/ob_memtable.cpp` | `ObMemtable::set()` lock path | 618 |
| `src/storage/memtable/ob_memtable.cpp` | `ObMemtable::lock()` | 648 |
| `src/storage/memtable/ob_memtable.cpp` | `ObMemtable::get()` conflict handling | 786 |
| `src/storage/memtable/ob_memtable_single_row_reader.cpp` | `get_next_value_iter_()` conflict | 307 |
| `src/storage/memtable/mvcc/ob_mvcc_engine.cpp` | `ObMvccEngine::check_row_locked()` | 232 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `ObMvccRow::check_row_locked()` | 1130 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` | `class ObLockWaitMgr` | 71 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` | `check_wakeup_seq_()` | 412 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `handle_local_node_()` | 859 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `wait_()` | 1127 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `register_local_node_to_deadlock_()` | 988 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `check_wait_node_session_stat_()` | 1367 |
| `src/storage/blocksstable/ob_micro_block_row_lock_checker.cpp` | SSTable 行锁检查 | 1-450 |
| `src/storage/blocksstable/ob_sstable.cpp` | `ObSSTable::check_row_locked()` | 955 |

---

## 18. 总结

`ObRowConflictHandler` 是 OceanBase 事务引擎中承上启下的组件：

1. **承上**：接收 MVCC 层检测到的锁状态（`ObStoreRowLockState`）
2. **决策**：判断冲突类型（锁等待 / TSC / 主键冲突 / 外键约束）
3. **启下**：通过 `ObLockWaitMgr` 注册锁等待，通过 `ObRowConflictInfo` 传递完整的冲突元数据

其设计体现了 OceanBase 存储引擎的核心架构哲学：
- **分层清晰**：MVCC 层只负责检测，处理逻辑独立出来
- **分布式优先**：`ObRowConflictInfo` 包含了完整的分布式元数据
- **兼容 MySQL**：锁等待超时、死锁检测等行为与 MySQL 一致

---

## 下篇预告

- **17-query-optimizer-analysis**：查询优化器与执行计划
- **18-index-design-analysis**：索引设计（局部/全局/覆盖索引）
- **19-partition-migration-analysis**：分区迁移与负载均衡
- **20-backup-recovery-analysis**：备份恢复

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 代码仓库：OceanBase CE*
