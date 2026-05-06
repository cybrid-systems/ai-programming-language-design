# 01-innodb-arch — MySQL InnoDB 存储引擎架构总览与核心数据结构

> 基于 MySQL 8.4 主线源码
> 使用 doom-lsp（clangd LSP）进行符号定位
> 分析日期：2026-05-06 | 源码路径：`~/code/mysql`

---

## 0. 概述

**InnoDB** 是 MySQL 的默认存储引擎，提供事务（ACID）、行级锁、MVCC、崩溃恢复等核心能力。作为一个插件式存储引擎，它通过 MySQL 的 `handlerton` 接口注册到 SQL 层。

InnoDB 的核心架构可拆为**六大子系统**：

```
                    MySQL SQL Layer (sql/)
                          │
                     handlerton 接口
                          │
               ┌──────────┴──────────┐
               │     InnoDB          │
               │  (storage/innobase/) │
               │                      │
    ┌──────────┼──────────┬──────────┼──────────┐
    │          │          │          │          │
  Buffer      Log       Lock     Index(B+Tree) Transaction
  Pool      System    System    + Adaptive    System
  (buf/)    (log/)   (lock/)   Hash Index    (trx/)
                                     │
                                 Undo Log
                                 (trx/ + row/)
```

InnoDB 的启动入口在 `srv0start.cc:1330`：

```cpp
// storage/innobase/srv/srv0start.cc:1330 — doom-lsp 确认
dberr_t srv_start(bool create_new_db) {
  // 启动阶段：
  // 1. SRV_START_STATE_NONE → 初始化基础子系统
  // 2. SRV_START_STATE_IO   → 打开表空间文件、启动 IO 线程
  // 3. SRV_START_STATE_PURGE → 启动 purge 线程
  // 4. SRV_START_STATE_STAT → 启动统计信息收集
  srv_start_state = SRV_START_STATE_NONE;
  ...
}
```

---

## 1. Buffer Pool — buf_pool_t

Buffer Pool 是 InnoDB 最大的内存结构，缓存数据页和索引页。`buf_pool_t` 定义在 `buf0buf.h:2293`：

```cpp
// storage/innobase/include/buf0buf.h:2293 — doom-lsp 确认
struct buf_pool_t {
  /** LRU list mutex */
  BufListMutex LRU_list_mutex;

  /** free list mutex */
  BufListMutex free_list_mutex;

  /** Array index of this buffer pool instance */
  ulint instance_no;

  /** Current pool size in bytes */
  ulint curr_pool_size;

  /** LRU list (old blocks at the end) */
  UT_LIST_BASE_NODE_T(buf_page_t) LRU;

  /** Free block list (unused buf_page_t objects) */
  UT_LIST_BASE_NODE_T(buf_page_t) free;

  /** Flush list (dirty pages, ordered by oldest_modification) */
  UT_LIST_BASE_NODE_T(buf_page_t) flush_list;

  /** Number of pages in the LRU list */
  ulint LRU_len;

  /** Number of pages in the free list */
  ulint free_list_len;

  /** Number of pages in the flush list */
  ulint flush_list_len;
};
```

Buffer Pool 的核心页面类型 `buf_page_t` 定义在同一文件的 1164 行：

```cpp
// storage/innobase/include/buf0buf.h:1164 — doom-lsp 确认
class buf_page_t {
  /** @name General fields */
  /** @{ */
  page_id_t id;                  // 空间 ID + 页号
  page_size_t size;              // 页大小（默认 16KB）
  ib_uint32_t buf_fix_count;      // 固定计数
  buf_page_state state;           // 页面状态（FREE, FILE_PAGE 等）
  /** @} */

  /** @name IO fields */
  /** @{ */
  IORequest io;                  // IO 请求描述
  buf_io_fix io_fix;              // IO 固定状态
  /** @} */

  /** @name LSN fields */
  /** @{ */
  lsn_t newest_modification;     // 最新修改 LSN（用于 flush list 排序）
  lsn_t oldest_modification;     // 最旧修改 LSN
  /** @} */

  /** @name LRU fields */
  /** @{ */
  UT_LIST_NODE_T(buf_page_t) LRU;  // LRU 链表节点
  /** @} */
};
```

`buf_block_t`（第 1764 行）扩展了 `buf_page_t`，增加了 `frame`（实际页面数据指针）：

```cpp
// storage/innobase/include/buf0buf.h:1764 — doom-lsp 确认
struct buf_block_t {
  buf_page_t page;                // 基类页面信息
  byte *frame;                     // 页面数据（UNIV_PAGE_SIZE 对齐）
  BPageLock lock;                  // 读写锁
  BPageMutex mutex;                // 页面 mutex
};
```

---

## 2. 事务系统 — trx_t

事务结构 `trx_t` 定义在 `trx0trx.h:675`，包含事务 ID、状态、锁信息等：

```cpp
// storage/innobase/include/trx0trx.h:675 — doom-lsp 确认
struct trx_t {
  /** Transaction ID (assign on first modification) */
  trx_id_t id;

  /** Transaction state (ACTIVE, PREPARED, COMMITTED, etc.) */
  enum trx_state_t state;

  /** MySQL thread handle (for KILL detection) */
  THD *mysql_thd;

  /** Read view for MVCC (consistent snapshot) */
  ReadView *read_view;

  /** Transaction undo log */
  trx_undo_t *undo;

  /** Lock system reference */
  lock_t *lock;

  /** Rollback segments used by this transaction */
  trx_rseg_t *rseg;

  /** Auto-inc lock */
  ib_mutex_t *dict_operation_lock;

  /** Transaction start time */
  time_t start_time;
};
```

事务状态枚举：

```cpp
// storage/innobase/include/trx0types.h:49 — doom-lsp 确认
enum trx_state_t {
  TRX_STATE_NOT_STARTED,   // 尚未开始
  TRX_STATE_ACTIVE,        // 运行中（已执行修改）
  TRX_STATE_PREPARED,      // 两阶段提交已准备
  TRX_STATE_COMMITTED_IN_MEMORY, // 内存中已提交
  TRX_STATE_COMMITTED_IN_DISK,   // 磁盘已提交
};
```

---

## 3. Redo Log — log_t

Redo Log 系统日志结构 `log_t` 定义在 `log0sys.h:77`，是整个 WAL 机制的核心：

```cpp
// storage/innobase/include/log0sys.h:77 — doom-lsp 确认
struct alignas(ut::INNODB_CACHE_LINE_SIZE) log_t {
  /** Redo log buffer */
  byte *buf;

  /** Buffer size */
  lsn_t buf_size;

  /** Latest LSN (last modified LSN + meta) */
  lsn_t lsn;

  /** LSN up to which we have written to OS */
  lsn_t written_to_some_lsn;

  /** LSN up to which we have flushed to disk */
  lsn_t flushed_to_disk_lsn;

  /** Log capacity criteria */
  lsn_t max_modified_age_lsn;

  /** Background write limit */
  lsn_t write_ahead_limit;

  /** When last redo log check was run */
  lsn_t last_checkpoint_lsn;

  /** Log file header/file info */
  Log_files_capacity *files_capacity;
  Log_files_dict *files_dict;
};
```

核心概念：**WAL（Write-Ahead Logging）** — 事务提交前必须将 redo log 写入磁盘。`flushed_to_disk_lsn` 是最近一次持久化的位置，`lsn` 是最新写入缓冲的位置。

---

## 4. 数据字典 — dict_table_t

InnoDB 的字典缓存，每张表对应一个 `dict_table_t` 实例：

```cpp
// storage/innobase/include/dict0mem.h:1925 — doom-lsp 确认
struct dict_table_t {
  /** Table name (db/table) */
  table_name_t name;

  /** Table ID (unique) */
  table_id_t id;

  /** Number of user columns */
  ulint n_cols;

  /** Number of virtual columns */
  ulint n_v_cols;

  /** Column definitions */
  dict_col_t *cols;

  /** Index definitions (clustered + secondary) */
  dict_index_t *first_index;
  dict_index_t *last_index;

  /** Table flags (compressed, page size, etc.) */
  ulint flags;

  /** Flags for the flags2 field */
  ulint flags2;

  /** Number of rows (approximate) */
  ib_int64_t stat_n_rows;

  /** Number of clusters in the table */
  ulint stat_clustered_index_size;

  /** Number of pages for rows */
  ulint stat_n_on_fwd_page;
};
```

---

## 5. 锁系统 — lock_t

InnoDB 的行级锁定义在 `lock0priv.h`：

```cpp
// storage/innobase/include/lock0types.h:43 — doom-lsp 确认
struct lock_t;

// storage/innobase/include/lock0priv.h:54
struct lock_table_t {
  dict_table_t *table;     // 锁定的表
  UT_LIST_NODE_T(lock_t) locks;  // 同一表上的锁链表
};

// 实际行锁类型：
enum lock_mode {
  LOCK_S      = 1,   // Shared (读锁)
  LOCK_X      = 2,   // Exclusive (写锁)
  LOCK_IS     = 3,   // Intention Shared
  LOCK_IX     = 4,   // Intention Exclusive
  LOCK_AUTO_INC = 5, // Auto-increment
};
```

InnoDB 的锁算法（Gap 锁、Next-Key 锁）通过 `lock0lock.cc` 中的 `lock_rec_lock()` 实现。

---

## 6. Mini-Transaction — mtr_t

Mini-Transaction 是 InnoDB 内部最细粒度的持久化单元，所有页面修改都必须通过 `mtr_t`：

```cpp
// storage/innobase/include/mtr0mtr.h:177 — doom-lsp 确认
struct mtr_t {
  /** State: MTR_ACTIVE, MTR_COMMITTING, MTR_COMMITTED */
  ulint state;

  /** Start LSN (assigned at mtr_start) */
  lsn_t start_lsn;

  /** End LSN (assigned at mtr_commit) */
  lsn_t end_lsn;

  /** Log entries in this mini-transaction */
  mtr_buf_t *log;

  /** Number of modified pages */
  ulint n_freed_pages;
  ulint n_freed_pages_size;
  ulint n_logged_debug;
};
```

mtr 的生命周期：

```cpp
// 伪代码表示 mtr 使用模式：
mtr_start(&mtr);                  // 开始 mini-transaction
buf_page_get(page_id, &mtr);      // 获取页面（加入 mtr 追踪）
mlog_write_ulint(ptr, val, &mtr); // 写入 redo log
mtr_commit(&mtr);                  // 提交（释放锁 + 写 log）
```

---

## 7. 页面类型 — page_t

InnoDB 的基本 I/O 单元是 `page_t`：

```cpp
// storage/innobase/include/page0types.h:152 — doom-lsp 确认
typedef byte page_t;

// 页面类型（page0page.h）：
#define FIL_PAGE_INDEX    17855  // B+Tree 索引页
#define FIL_PAGE_RTREE    17856  // R-Tree 索引页
#define FIL_PAGE_TYPE_ALLOCATED 0  // 未分配
#define FIL_PAGE_INODE    3      // 索引节点
#define FIL_PAGE_IBUF_FREE_LIST 4 // 插入缓冲空闲列表
#define FIL_PAGE_TYPE_SYS     5   // 系统页
#define FIL_PAGE_TYPE_TRX_SYS 6   // 事务系统页
#define FIL_PAGE_TYPE_FSP_HDR  7   // 文件空间头
#define FIL_PAGE_TYPE_XDES     8   // 扩展描述符
#define FIL_PAGE_TYPE_BLOB     9   // BLOB 页
```

---

## 8. 数据流：一次查询完整路径

```
SELECT * FROM t WHERE id = 42;
  │
  ├─ MySQL SQL Layer (sql/):
  │   ├─ Parser → sql_lexer.cc (SQL 解析)
  │   ├─ Optimizer → sql_optimizer.cc (选择索引)
  │   └─ Executor → sql_executor.cc (生成 record set)
  │
  ├─ handlerton 接口跳转
  │
  └─ InnoDB (storage/innobase/):
      ├─ dict_table_t → 查找表定义和索引元数据
      ├─ btr_pcur_open → B+Tree 游标定位
      │   ├─ buf_page_get → 从 Buffer Pool 读取页面
      │   │   ├─ LRU 链表命中 → 直接返回
      │   │   └─ LRU 未命中 → 磁盘 I/O (buf_read_page)
      │   └─ page_cur_search_with_match → 页内二分查找
      ├─ lock_t → 行锁加锁 (lock_rec_lock)
      ├─ ReadView → MVCC 一致性读
      └─ 返回行数据 → 返回 MySQL SQL 层
```

---

## 9. 核心子系统总结

| 子系统 | 核心结构 | 源文件 | 行号 |
|--------|---------|--------|------|
| Buffer Pool | `buf_pool_t` | `buf0buf.h` | 2293 |
| Buffer Page | `buf_page_t` | `buf0buf.h` | 1164 |
| Buffer Block | `buf_block_t` | `buf0buf.h` | 1764 |
| Redo Log | `log_t` | `log0sys.h` | 77 |
| 事务 | `trx_t` | `trx0trx.h` | 675 |
| 表定义 | `dict_table_t` | `dict0mem.h` | 1925 |
| 锁结构 | `lock_t` | `lock0types.h` | 43 |
| Mini-Transaction | `mtr_t` | `mtr0mtr.h` | 177 |
| 页面类型 | `page_t` | `page0types.h` | 152 |
| 启动入口 | `srv_start()` | `srv0start.cc` | 1330 |

---

## 10. 启动流程

`srv_start()` 按阶段初始化各子系统：

```
srv_start() @ srv0start.cc:1330
  │
  ├─ SRV_START_STATE_NONE → 初始化缓冲池、日志系统
  │   ├─ buf_pool_init()        → 分配 Buffer Pool 内存
  │   └─ log_sys_init()         → 初始化 Redo Log
  │
  ├─ SRV_START_STATE_IO → 打开表空间、启动 IO 线程
  │   ├─ fil_start()            → 打开所有表空间文件
  │   ├─ recv_recovery_from_checkpoint() → 崩溃恢复
  │   └─ srv_start_threads()    → 启动 IO/刷脏等后台线程
  │
  ├─ SRV_START_STATE_PURGE → 启动 purge
  │   └─ srv_start_purge_threads() → 启动 Undo Purge 线程
  │
  └─ SRV_START_STATE_STAT → 统计信息
      └─ dict_stats_thread()    → 索引统计信息收集
```

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-06 | MySQL 8.4 | 源码路径：`~/code/mysql`*
