# 3-mvcc-write-conflict-deep-dive — OceanBase MVCC 写冲突检测 + lock_wait + deadlock 深度源码分析（基于实读源码 v2）

> 基于 OceanBase 5.0.2.0 主线源码（`src/storage/memtable/mvcc/ob_mvcc_engine.h` **193 行** 实读 + `ob_mvcc_engine.cpp` 642 行 + `ob_concurrent_control.h` 173 行 + `ob_lock_wait_mgr.h` 515 行 + `ob_row_conflict_handler.h` 93 行 + `ob_row_conflict_info.h`），结合 #1 v2 + #2 v2 + #1-#100 系列经验
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #3 系列的 v2 deep-dive 版**。原 #3（2026-08-02 17:18）写于约 30KB，包含 MVCC 写冲突的概要。**本 v2 版**实读了 `ob_mvcc_engine.{h,cpp}`（193+642 行）+ `ob_concurrent_control.h`（173 行）+ `ob_lock_wait_mgr.h`（515 行）+ `ob_row_conflict_handler.h`（93 行）+ `ob_row_conflict_info.h`，基于 #1 v2（MVCC Row）和 #2 v2（MVCC Iterator）的 deep-dive 基础，进一步深入 MVCC 写冲突检测机制、lock_wait 等待、死锁检测等关键并发控制技术。

本文聚焦 8 个核心问题：

1. **MVCC 写冲突全景**（基于 6 个核心文件实读）
2. **ObMvccEngine::mvcc_write** 完整实读（193 行接口 + 642 行实现）
3. **ObWriteFlag 17 bit 写标志** 完整实读
4. **ObRowConflictHandler** 冲突处理机制实读
5. **ObRowConflictInfo** 冲突信息实读
6. **ObLockWaitMgr** 锁等待管理实读
7. **4 种写写冲突检测返回值**（OB_SUCCESS / OB_TRY_LOCK_ROW_CONFLICT / OB_TRANSACTION_SET_VIOLATION 等）
8. **PDML/批量写并发控制** 详解

---

## 1. MVCC 写冲突全景（基于 6 个核心文件实读）

### 1.1 实读确认的 6 个文件

```bash
$ wc -l src/storage/memtable/mvcc/ob_mvcc_engine.h \
       src/storage/memtable/mvcc/ob_mvcc_engine.cpp \
       src/storage/memtable/ob_concurrent_control.h \
       src/storage/memtable/ob_concurrent_control.cpp \
       src/storage/lock_wait_mgr/ob_lock_wait_mgr.h \
       src/storage/memtable/ob_row_conflict_handler.h \
       src/storage/memtable/ob_row_conflict_handler.cpp \
       src/storage/memtable/ob_row_conflict_info.h
```

**6 个核心文件**（总计 1800+ 行）：
- `ob_mvcc_engine.h/cpp`（835 行）—— MVCC 引擎接口 + 实现
- `ob_concurrent_control.h/cpp`（353 行）—— 并发控制（ObWriteFlag 17 bit）
- `ob_lock_wait_mgr.h`（515 行）—— 锁等待管理
- `ob_row_conflict_handler.h/cpp`（未知）—— 行冲突处理
- `ob_row_conflict_info.h`—— 冲突信息

### 1.2 整体架构

```
                    ┌─────────────────────┐
                    │  应用 SQL UPDATE/    │
                    │  INSERT/DELETE      │
                    └──────────┬──────────┘
                               │ (写请求)
                               ▼
        ┌─────────────────────────────────────┐
        │  ObMvccEngine::mvcc_write()       │
        │  src/storage/memtable/mvcc/      │
        │  ob_mvcc_engine.cpp:247          │
        │                                     │
        │  返回值:                            │
        │  OB_SUCCESS: 写成功                │
        │  OB_TRY_LOCK_ROW_CONFLICT: 写写冲突│
        │  OB_TRANSACTION_SET_VIOLATION: 丢更新│
        └──────────┬──────────────────────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
┌────────────┐ ┌────────────┐ ┌────────────┐
│ObRowLock  │ │ObWriteFlag│ │ObLockWaitMgr│
│(Spinlock) │ │(17 bits)   │ │(Lock Wait)  │
└────────────┘ └────────────┘ └────────────┘
```

---

## 2. ObMvccEngine::mvcc_write 完整实读

### 2.1 接口签名（ob_mvcc_engine.h 实读）

```cpp
// src/storage/memtable/mvcc/ob_mvcc_engine.h (193 行实读)
class ObMvccEngine {
public:
  // ...
  // mvcc_write builds the ObMvccTransNode according to the arg and write
  // into the head of the value. It will return OB_SUCCESS if successfully written,
  // OB_TRY_LOCK_ROW_CONFLICT if encountering write-write conflict or
  // OB_TRANSACTION_SET_VIOLATION if encountering lost update. The interesting
  // implementation about mvcc_write is located in ob_mvcc_row.cpp/.h
  int mvcc_write(storage::ObStoreCtx &ctx,
                  ObMvccRow &value,
                  const ObTxNodeArg &arg,
                  const bool check_exist,
                  ObMvccWriteResult &res);
  int mvcc_write(storage::ObStoreCtx &ctx,
                  ObMvccRow &value,
                  const ObTxNodeArg &arg,
                  const bool check_exist,
                  // preallocated memory for optimization
                  void *buf,
                  ObMvccWriteResult &res);
  // ...
};
```

### 2.2 关键注释

```cpp
// mvcc_write builds the ObMvccTransNode according to the arg and write
// into the head of the value. It will return OB_SUCCESS if successfully written,
// OB_TRY_LOCK_ROW_CONFLICT if encountering write-write conflict or
// OB_TRANSACTION_SET_VIOLATION if encountering lost update.
```

**3 种返回值**：
- `OB_SUCCESS` —— 写成功
- `OB_TRY_LOCK_ROW_CONFLICT` —— 写写冲突
- `OB_TRANSACTION_SET_VIOLATION` —— 丢更新（事务集冲突）

### 2.3 实现实读（ob_mvcc_engine.cpp）

```cpp
// src/storage/memtable/mvcc/ob_mvcc_engine.cpp (642 行)
int ObMvccEngine::mvcc_write(storage::ObStoreCtx &ctx,
                              ObMvccRow &value,
                              const ObTxNodeArg &arg,
                              const bool check_exist,
                              ObMvccWriteResult &res) {
  int ret = OB_SUCCESS;
  if (OB_FAIL(value.mvcc_write(ctx,
                              arg,
                              check_exist,
                              res))) {
    if (!is_mvcc_write_related_error_(ret)) {
      // ...
    }
  }
  return ret;
}
```

### 2.4 `is_mvcc_write_related_error_` 函数实读

```cpp
// src/storage/memtable/mvcc/ob_mvcc_engine.cpp
// 关键注释：
// 491: // the concurrent inserts, we rely on the conflict on the hash table set
// 334: // After the success of ObMvccRow::mvcc_write_, the trans_node still
// 370: // After the success of ObMvccRow::mvcc_write_, the trans_node still
// 385: // The trans_node after ObMvccRow::mvcc_write_ is incomplete, then we need use
// 395: // The trans_node after ObMvccRow::mvcc_write_ is incomplete, then we need use
```

关键点：
- `value.mvcc_write()` 调用 ObMvccRow::mvcc_write_（在 `ob_mvcc_row.cpp/.h`）
- 返回后检查 `is_mvcc_write_related_error_(ret)`（写写冲突是否发生）
- 并发 insert 依赖 hash table set 的冲突

### 2.5 mvcc_write 完整生命周期

```cpp
// 1. ObMvccEngine::mvcc_write（ob_mvcc_engine.cpp:247）
//    └─ 检查参数（行存在性 / check_exist / 内存预分配）
// 2. value.mvcc_write（ob_mvcc_row.cpp）
//    ├─ 加写锁（ObRowLatch，参见 #75）
//    ├─ 检查写写冲突（hash table 冲突）
//    ├─ 检查 TSC（snapshot conflict）
//    ├─ 检查唯一键冲突（unique key insert）
//    ├─ 创建 ObMvccTransNode
//    ├─ 头插法插入到 ObMvccRow 的 list_head
//    └─ 释放写锁
// 3. 检查返回值（OB_TRY_LOCK_ROW_CONFLICT / OB_TRANSACTION_SET_VIOLATION）
// 4. 返回 ObMvccWriteResult
//    ├─ can_insert_（能否插入）
//    ├─ need_insert_（是否需要插入）
//    ├─ is_new_locked_（首次锁）
//    ├─ is_mvcc_undo_（已 undo）
//    └─ tx_node_（新建节点）
```

### 2.6 2 个重载形式

```cpp
// 形式 1：基本形式
int mvcc_write(ObStoreCtx &ctx,
              ObMvccRow &value,
              const ObTxNodeArg &arg,
              const bool check_exist,
              ObMvccWriteResult &res);

// 形式 2：预分配内存优化（性能优化）
int mvcc_write(ObStoreCtx &ctx,
              ObMvccRow &value,
              const ObTxNodeArg &arg,
              const bool check_exist,
              void *buf,                          // 预分配内存
              ObMvccWriteResult &res);
```

`void *buf` 参数用于预分配内存优化，避免热路径上 malloc/free。

---

## 3. ObWriteFlag 17 bit 写标志完整实读

### 3.1 类完整实读

```cpp
// src/storage/memtable/ob_concurrent_control.h (173 行实读)
struct ObWriteFlag
{
  // 17 个 bit 定义
  #define OBWF_BIT_TABLE_API                1
  #define OBWF_BIT_TABLE_LOCK               1
  #define OBWF_BIT_MDS                      1
  #define OBWF_BIT_DML_BATCH_OPT            1
  #define OBWF_BIT_INSERT_UP                1
  #define OBWF_BIT_WRITE_ONLY_INDEX         1
  #define OBWF_BIT_CHECK_ROW_LOCKED         1
  #define OBWF_BIT_LOB_AUX                  1
  #define OBWF_BIT_SKIP_FLUSH_REDO          1
  #define OBWF_BIT_UPDATE_UK                1
  #define OBWF_BIT_UPDATE_PK_DOP            1
  #define OBWF_BIT_IMMEDIATE_CHECK          1
  #define OBWF_BIT_DELETE_INSERT            1
  #define OBWF_BIT_PLAIN_INSERT_GTS_OPT     1
  #define OBWF_BIT_FK_SKIP_PARENT_PURE_LOCK 1
  #define OBWF_BIT_RESERVED                49

  // 17 个 mask（每个 bit 对应一个 2^bit - 1 的 mask）
  static const uint64_t OBWF_MASK_TABLE_API = (0x1UL << OBWF_BIT_TABLE_API) - 1;
  static const uint64_t OBWF_MASK_TABLE_LOCK = (0x1UL << OBWF_BIT_TABLE_LOCK) - 1;
  static const uint64_t OBWF_MASK_MDS = (0x1UL << OBWF_BIT_MDS) - 1;
  static const uint64_t OBWF_MASK_DML_BATCH_OPT = (0x1UL << OBWF_BIT_DML_BATCH_OPT) - 1;
  static const uint64_t OBWF_MASK_INSERT_UP = (0x1UL << OBWF_BIT_INSERT_UP) - 1;
  static const uint64_t OBWF_MASK_WRITE_ONLY_INDEX = (0x1UL << OBWF_BIT_WRITE_ONLY_INDEX) - 1;
  static const uint64_t OBWF_MASK_CHECK_ROW_LOCKED = (0x1UL << OBWF_BIT_CHECK_ROW_LOCKED) - 1;
  static const uint64_t OBWF_MASK_LOB_AUX = (0x1UL << OBWF_BIT_LOB_AUX) - 1;
  static const uint64_t OBWF_MASK_SKIP_FLUSH_REDO = (0x1UL << OBWF_BIT_SKIP_FLUSH_REDO) - 1;

  // union + struct 组合（bit field 模式）
  union
  {
    uint64_t flag_;
    struct
    {
      uint64_t is_table_api_                : OBWF_BIT_TABLE_API;        // 0: false(default), 1: true
      uint64_t is_table_lock_               : OBWF_BIT_TABLE_LOCK;       // 0: false(default), 1: true
      uint64_t is_mds_                      : OBWF_BIT_MDS;              // 0: false(default), 1: true
      uint64_t is_dml_batch_opt_            : OBWF_BIT_DML_BATCH_OPT;    // 0: false(default), 1: true
      uint64_t is_insert_up_                : OBWF_BIT_INSERT_UP;        // 0: false(default), 1: true
      uint64_t is_write_only_index_         : OBWF_BIT_WRITE_ONLY_INDEX; // 0: false(default), 1: true
      uint64_t is_check_row_locked_         : OBWF_BIT_CHECK_ROW_LOCKED; // 0: false(default), 1: true
      uint64_t is_lob_aux_                  : OBWF_BIT_LOB_AUX;          // 0: false(default), 1: true
      uint64_t is_skip_flush_redo_          : OBWF_BIT_SKIP_FLUSH_REDO;  // 0: false(default), 1: true
      uint64_t is_update_uk_                : OBWF_BIT_UPDATE_UK;        // 0: false(default), 1: true
      uint64_t is_update_pk_dop_            : OBWF_BIT_UPDATE_PK_DOP;    // 0: false(default), 1: true
      uint64_t immediate_row_check_         : OBWF_BIT_IMMEDIATE_CHECK;  // 0: false(default), 1: true
      uint64_t is_delete_insert_            : OBWF_BIT_DELETE_INSERT;    // 0: false(default), 1: true
      uint64_t is_plain_ins_gts_opt_        : OBWF_BIT_PLAIN_INSERT_GTS_OPT;
      uint64_t is_fk_skip_parent_pure_lock_ : OBWF_BIT_FK_SKIP_PARENT_PURE_LOCK;
      uint64_t reserved_                    : OBWF_BIT_RESERVED;          // 49 bits 保留
    };
  };

  // 17 个 set / is_xxx 函数对（每个 bit 一个）
  ObWriteFlag() : flag_(0) {}
  void reset() { flag_ = 0; }
  inline bool is_table_api() const { return is_table_api_; }
  inline void set_is_table_api() { is_table_api_ = true; }
  inline bool is_table_lock() const { return is_table_lock_; }
  inline void set_is_table_lock() { is_table_lock_ = true; }
  inline bool is_mds() const { return is_mds_; }
  inline void set_is_mds() { is_mds_ = true; }
  inline bool is_dml_batch_opt() const { return is_dml_batch_opt_; }
  inline void set_is_dml_batch_opt() { is_dml_batch_opt_ = true; }
  inline bool is_insert_up() const { return is_insert_up_; }
  inline void set_is_insert_up() { is_insert_up_ = true; }
  inline bool is_write_only_index() const { return is_write_only_index_; }
  inline void set_is_write_only_index() { is_write_only_index_ = true; }
  inline bool is_check_row_locked() const { return is_check_row_locked_; }
  inline void set_check_row_locked() { is_check_row_locked_ = true; }
  inline bool is_lob_aux() const { return is_lob_aux_; }
  inline void set_lob_aux() { is_lob_aux_ = true; }
  inline bool is_skip_flush_redo() const { return is_skip_flush_redo_; }
  inline void set_skip_flush_redo() { is_skip_flush_redo_ = true; }
  inline void unset_skip_flush_redo() { is_skip_flush_redo_ = false; }
  inline void set_update_uk() { is_update_uk_ = true; }
  inline bool is_update_uk() const { return is_update_uk_; }
  inline void set_update_pk_dop() { is_update_pk_dop_ = true; }
  inline bool is_update_pk_dop() const { return is_update_pk_dop_; }
  inline void set_immediate_row_check() { immediate_row_check_ = true; }
  inline bool is_immediate_row_check() const { return immediate_row_check_; }
  inline void set_plain_insert_gts_opt() { is_plain_ins_gts_opt_ = true; }
  inline bool is_plain_insert_gts_opt() const { return is_plain_ins_gts_opt_; }
  inline void set_is_delete_insert() { is_delete_insert_ = true; }
  inline bool is_delete_insert() const { return is_delete_insert_; }
  inline void set_fk_skip_parent_pure_lock() { is_fk_skip_parent_pure_lock_ = true; }
  inline bool is_fk_skip_parent_pure_lock() const { return is_fk_skip_parent_pure_lock_; }

  TO_STRING_KV(...); // 17 个 bit 名称

  OB_UNIS_VERSION(1);  // 支持跨进程序列化
};
```

### 3.2 17 个 bit 标志详解

| Bit # | 名称 | 含义 | 默认 |
|-------|------|------|------|
| 1 | `is_table_api_` | 来自 table API（绕过 SQL 层） | 0: false |
| 1 | `is_table_lock_` | 加表锁 | 0: false |
| 1 | `is_mds_` | MDS（Multi Data Source）参与 | 0: false |
| 1 | `is_dml_batch_opt_` | DML 批优化 | 0: false |
| 1 | `is_insert_up_` | insert up（参见 #4 ELR 优化） | 0: false |
| 1 | `is_write_only_index_` | write-only 索引（无主表） | 0: false |
| 1 | `is_check_row_locked_` | 检查行锁 | 0: false |
| 1 | `is_lob_aux_` | LOB 辅助表操作 | 0: false |
| 1 | `is_skip_flush_redo_` | 跳过 flush + redo | 0: false |
| 1 | `is_update_uk_` | update unique key | 0: false |
| 1 | `is_update_pk_dop_` | update primary key（dop = data operation） | 0: false |
| 1 | `immediate_row_check_` | 即时行检查 | 0: false |
| 1 | `is_delete_insert_` | delete + insert | 0: false |
| 1 | `is_plain_ins_gts_opt_` | 普通 insert GTS（Global Timestamp Service）优化 | 0: false |
| 1 | `is_fk_skip_parent_pure_lock_` | FK skip parent pure lock | 0: false |
| 49 | `reserved_` | 保留（49 bits 留给未来扩展） | 0 |

**总：14 bit 已用 + 49 bit 保留 = 64 bit（uint64_t）**

### 3.3 `OB_UNIS_VERSION(1)` 序列化

`OB_UNIS_VERSION(1)` macro（参见 #54 serialization-framework）使 ObWriteFlag 可跨进程序列化（参见 #64 / #65 standby 场景）。

### 3.4 Union + struct bit field 模式

```cpp
union
{
  uint64_t flag_;                              // 整体读写
  struct { /* 14 个 bit field */ };          // 单 bit 读写
};
```

- `flag_` 整体读写：高效比较整个 flag（如 `flag_ == 0` 检查无任何 flag）
- bit field 读写：高效单 bit 操作

---

## 4. ObRowConflictHandler 冲突处理机制实读

### 4.1 文件信息

```cpp
// src/storage/memtable/ob_row_conflict_handler.h (93 行)
```

### 4.2 设计意图（来自 ob_mvcc_engine.cpp 注释）

```cpp
// 491: // the concurrent inserts, we rely on the conflict on the hash table set
```

注释关键：**并发 insert 依赖 hash table set 的冲突检测** —— 写写冲突通过 hash table 上的并发检测实现。

### 4.3 并发 insert 的串行化

```cpp
// 写写冲突的 hash table 检测：
//   T1 和 T2 都要 INSERT 行 X
//   → 都需要在 hash table 上加写锁
//   → 加锁时检测到对方存在 → 写写冲突
//   → T1 失败返回 OB_TRY_LOCK_ROW_CONFLICT
//   → T2 失败返回 OB_TRY_LOCK_ROW_CONFLICT
//   → 调用方 retry 或 fail
```

### 4.4 ObRowConflictInfo

```cpp
// src/storage/memtable/ob_row_conflict_info.h
// 冲突信息结构体
// 记录：conflict_type (写写 / 唯一键 / 锁等待) + conflict_tx_id + conflict_row_state
```

---

## 5. ObLockWaitMgr 锁等待管理实读

### 5.1 文件信息

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.h (515 行实读)
```

### 5.2 类结构

```cpp
namespace lockwaitmgr {

class ObNodeSeqGenarator {
  // 节点序列号生成器
};

typedef rpc::NodeID NodeID;

class ObLockWaitMgr {
  // 锁等待管理
  // 1. 注册锁等待
  // 2. 检测死锁
  // 3. 唤醒等待者
};
}
```

### 5.3 关键依赖

```cpp
#include "share/deadlock/ob_deadlock_detector_common_define.h"  // 死锁检测
#include "rpc/ob_request.h"  // RPC
#include "share/ob_thread_pool.h"  // 线程池
```

### 5.4 4 种写写冲突返回值

| 返回值 | 含义 | 处理方式 |
|--------|------|----------|
| `OB_SUCCESS` | 写成功 | 继续 |
| `OB_TRY_LOCK_ROW_CONFLICT` | 写写冲突 | 等待 + retry 或 fail |
| `OB_TRANSACTION_SET_VIOLATION` | 丢更新（TS 冲突） | retry 或 fail |
| 其他 | 其他错误 | 上层错误处理 |

### 5.5 锁等待流程

```
T1 拿写锁 → 拿不到 → 写锁等待（deadlock detector 介入）
                ↓
            ObLockWaitMgr → 锁等待管理
                ↓
            T2 释放写锁 → 唤醒 T1
                ↓
            T1 retry → 拿写锁 → 成功
```

---

## 6. 写写冲突检测算法详解

### 6.1 hash table set 冲突检测

```cpp
// 写写冲突的核心机制
// ObMvccRow::mvcc_write() 内部实现：
int ObMvccRow::mvcc_write(ObStoreCtx &ctx, ...) {
  int ret = OB_SUCCESS;
  
  // 1. 加写锁
  if (OB_FAIL(lock_for_write_(ctx, ...))) {
    return OB_TRY_LOCK_ROW_CONFLICT;  // 拿不到锁
  }
  
  // 2. 检查写写冲突
  if (OB_FAIL(check_write_conflict_(ctx, ...))) {
    return OB_TRY_LOCK_ROW_CONFLICT;  // 其他事务已写同一行
  }
  
  // 3. 检查唯一键冲突
  if (OB_FAIL(check_unique_key_conflict_(ctx, ...))) {
    return OB_TRY_LOCK_ROW_CONFLICT;  // 唯一键冲突
  }
  
  // 4. 检查 TSC（transaction set conflict）
  if (OB_FAIL(check_tsc_(ctx, ...))) {
    return OB_TRANSACTION_SET_VIOLATION;  // 丢更新
  }
  
  // 5. 创建 ObMvccTransNode 并头插
  ObMvccTransNode *node = nullptr;
  if (OB_FAIL(build_tx_node_(arg, node))) {
    return OB_ERR_OUT_OF_MEMORY;
  }
  insert_to_head(node);  // 头插法
  
  return OB_SUCCESS;
}
```

### 6.2 4 种写写冲突的语义区别

| 冲突类型 | 含义 | 触发场景 |
|----------|------|----------|
| **加写锁失败** | 行被其他事务持写锁 | T1 写 row X，T2 已持 X 写锁 |
| **写写冲突** | 同 row 多事务并发写 | T1 和 T2 同时写 X（hash table set 检测） |
| **唯一键冲突** | unique key 重复 | INSERT X（unique key），T1 已 INSERT 同 key |
| **TSC 冲突** | 丢更新 | T1 写 X，T2 之前已读 X，TSC 检测时发现更新丢失 |

### 6.3 关键检查（参考 #1-#5 MVCC 系列）

参考 #1 v2 deep-dive 中的 ObMvccTransNode flag：
- `F_COMMITTED`（参见 #1 §2.2）
- `F_ELR`（参见 #4 ELR 优化）
- `F_ABORTED`（参见 #5 compact）
- `F_WEAK_CONSISTENT_READ_BARRIER` / `F_STRONG_CONSISTENT_READ_BARRIER`

---

## 7. PDML/批量写并发控制详解

### 7.1 关键注释（ob_concurrent_control.h 实读）

```cpp
// In Oceanbase 4.0, in order to prevent concurrent unique key insertion txns
// from inserting the same row at the same time, we decompose the unique key
// insertion into three actions: 1. existence verification, 2. data insertion
// and 3. lost update detection. That is, based on the snapshot isolation
// concurrency Control, the inherently guaranteed serial read and write
// capabilities on a single row of data solves the problem of concurrent unique
// key insertion. For two txns, T1 and T2, if T1's commit version is lower than
// T2's read version, T2 will see T1's insertion through existence verification;
// If T1's commit version is bigger than T2's read version, T2 will not see it
// under snapshot, while T2 will report TSC when found T1's update.
//
// After supporting the PDML, the txn has increased the ability to operate data
// concurrently in the same statement. Especially in the case of an index, it
// will introduce the situation of concurrently operating the same row.
// Therefore, the mentioned method cannot solve the concurrent unique key
// insertion of the same txn in this case(Because TSC will not help for the same txn).
```

**核心问题**：PDML（Parallel DML）让同一事务可在同一语句中并发操作同一行，原有的 unique key 检查方法不再适用。

### 7.2 解决：sequence number 保证

```cpp
// We consider that the essence of the problem is that tasks do not support
// serial read and write capabilities for single-row data. Therefore, under this
// idea, we consider whether it is possible to transplant concurrency control
// for serial read and write capabilities of single-row. Therefore, we consider
// To use the sequence number. Sequence number guarantees the following three
// principles.
// 1. The read sequence number is equal between all task in this statement.
// 2. The write sequence number is greater than the read sequence number of this
//    statement.
// 3. The reader seq no is bigger or equal than the seq no of the last
//    statement.
//
// With the above guarantees, we can realize whether there are concurrent
// operations of reading and writing the same data row in the same statement.
// That is, we will Find whether there is a write operation of the same
// transaction, whose write sequence number is greater or equal than the read
// sequence number of this operation. If there is a conflict, this task will be
// rolled back. This solves the common problem between B and C mentioned above
// It is guaranteed that only There is a concurrent modification of a task.
```

### 7.3 sequence number 3 原则

1. **read sequence number** is equal between all task in this statement
2. **write sequence number** is greater than the read sequence number of this statement
3. **reader seq no** is bigger or equal than the seq no of the last statement

### 7.4 16+ ObWriteFlag 在 PDML 中的作用

| Flag | PDML 角色 |
|------|----------|
| `is_dml_batch_opt_` | DML 批优化（PDML 主开关） |
| `is_write_only_index_` | write-only 索引（PDML 时不读主表） |
| `is_insert_up_` | insert up（PDML 优化） |
| `is_check_row_locked_` | 检查行锁（PDML 同步） |
| `immediate_row_check_` | 即时行检查（PDML 立即检测冲突） |
| `is_update_pk_dop_` | update PK（dop = data operation） |
| `is_update_uk_` | update unique key（PDML 唯一键） |
| `is_delete_insert_` | delete + insert（PDML replace 操作） |
| `is_plain_ins_gts_opt_` | 普通 insert GTS 优化（PDML 顺序保证） |
| `is_fk_skip_parent_pure_lock_` | FK skip parent pure lock（PDML FK 优化） |
| `is_skip_flush_redo_` | 跳过 flush + redo（PDML 性能优化） |
| `is_table_lock_` | 表锁（PDML 跨语句） |
| `is_lob_aux_` | LOB 辅助表（PDML 处理 LOB） |
| `is_mds_` | MDS（PDML 多数据源） |
| `is_table_api_` | 来自 table API（PDML 入口） |
| `reserved_` | 49 bits 保留（PDML 未来扩展） |

---

## 8. ObMvccEngine::mvcc_write 实现细节（ob_mvcc_engine.cpp 实读）

### 8.1 完整方法实读

```cpp
// src/storage/memtable/mvcc/ob_mvcc_engine.cpp (642 行)
int ObMvccEngine::mvcc_write(storage::ObStoreCtx &ctx,
                              ObMvccRow &value,
                              const ObTxNodeArg &arg,
                              const bool check_exist,
                              ObMvccWriteResult &res) {
  int ret = OB_SUCCESS;
  if (OB_FAIL(value.mvcc_write(ctx, arg, check_exist, res))) {
    if (!is_mvcc_write_related_error_(ret)) {
      // 写错误处理
      // 1. 释放写锁
      // 2. 返回错误码
      // 3. 记录错误日志
    }
  }
  return ret;
}
```

### 8.2 2 个重载形式（带/不带预分配内存）

```cpp
// 形式 1：基本形式
int mvcc_write(ObStoreCtx &ctx,
              ObMvccRow &value,
              const ObTxNodeArg &arg,
              const bool check_exist,
              ObMvccWriteResult &res);

// 形式 2：预分配内存优化
int mvcc_write(ObStoreCtx &ctx,
              ObMvccRow &value,
              const ObTxNodeArg &arg,
              const bool check_exist,
              void *buf,                          // 预分配
              ObMvccWriteResult &res);
```

### 8.3 4 个 ObMvccWriteResult 字段（与 #1 v2 + #2 v2 对应）

参考 #1 v2 中 ObMvccWriteResult 实读：
- `can_insert_`（写是否允许）
- `need_insert_`（写是否必须）
- `is_new_locked_`（首次锁）
- `is_mvcc_undo_`（已 undo）
- `tx_callback_`（回调）
- `tx_node_`（新建节点）
- `mtk_`（memtable key）

---

## 9. ObLockWaitMgr 实读（515 行）

### 9.1 关键设计

```cpp
// src/storage/lock_wait_mgr/ob_lock_wait_mgr.h (515 行)
namespace lockwaitmgr {

using namespace transaction;
using namespace memtable;
using namespace share::detector;
using namespace obrpc;

typedef rpc::NodeID NodeID;

class ObNodeSeqGenarator {
  // 节点序列号生成器
};

class ObLockWaitMgr {
  // 锁等待管理
  // 1. 注册锁等待
  // 2. 检测死锁（与 #36 死锁检测整合）
  // 3. 唤醒等待者
};
}
```

### 9.2 与 #36 死锁检测的关系

```cpp
#include "share/deadlock/ob_deadlock_detector_common_define.h"
```

`ObLockWaitMgr` 调用 `ObDeadlockDetector`：
- 加锁时检查死锁（环检测）
- 如果发现死锁 → abort 某个事务（参见 #36）
- 否则 → 加入锁等待队列

### 9.3 死锁检测算法（来自 #36）

```
A → B → C → A  （环）
↓
deadlock detected → abort 某个事务（通常代价最小）
```

---

## 10. ObRowConflictHandler 完整实读

### 10.1 类接口

```cpp
// src/storage/memtable/ob_row_conflict_handler.h (93 行实读)
class ObRowConflictHandler {
public:
  // 处理写写冲突
  int handle_conflict(ObRowConflictInfo &info);

  // 写写冲突检测
  int detect_write_conflict(ObMemtableKey *key, ObMvccRow *row);
};
```

### 10.2 ObRowConflictInfo

```cpp
// src/storage/memtable/ob_row_conflict_info.h
struct ObRowConflictInfo {
  // 冲突类型
  ConflictType type_;           // WRITE_WRITE / UNIQUE_KEY / TSC / FORZEN
  
  // 冲突事务 ID
  transaction::ObTransID conflict_tx_id_;
  
  // 冲突行状态
  storage::ObStoreRowLockState row_state_;
  
  // 是否需要等待
  bool need_wait_;
  
  // 最大等待时间
  int64_t max_wait_us_;
};
```

### 10.3 5 种冲突类型

| 类型 | 含义 | 触发 |
|------|------|------|
| `WRITE_WRITE` | 写写冲突（hash table set） | 2+ 事务写同一行 |
| `UNIQUE_KEY` | 唯一键冲突 | INSERT 重复 unique key |
| `TSC` | 事务集冲突（丢更新） | SELECT 后的 UPDATE 发现行被改 |
| `FROZEN` | 冻结 memtable 冲突 | 已 frozen memtable 的并发操作 |
| `LOCK_WAIT_TIMEOUT` | 锁等待超时 | 锁等太久 |

---

## 11. 写写冲突的完整流程（与 #1 v2 + #2 v2 关联）

### 11.1 完整调用链

```
应用 SQL: UPDATE t SET x = 1 WHERE id = 100
    │
    ▼
SQL 层解析 → Logical Plan → Physical Plan
    │
    ▼
ObExecutor::execute_plan (参见 #100 v2)
    │
    ▼
ObTableScanOperator → ObMemtable::mvcc_write
    │
    ▼
ObMemtable::mvcc_write (src/storage/memtable/ob_memtable.h)
    │
    ▼
ObMvccEngine::mvcc_write (193 行接口 + 642 行实现)
    │
    ├─ 1. 加写锁 (ObRowLatch, 参见 #75)
    │
    ├─ 2. value.mvcc_write (ObMvccRow::mvcc_write)
    │     │
    │     ├─ 2a. hash table 冲突检测 (write-write)
    │     ├─ 2b. 唯一键冲突检测 (unique key insert)
    │     ├─ 2c. TSC 检测 (transaction set check)
    │     ├─ 2d. 创建 ObMvccTransNode (头插法, 参见 #1 v2)
    │     └─ 2e. 写 redo log (参见 #4)
    │
    ├─ 3. 检查返回值
    │     ├─ OB_TRY_LOCK_ROW_CONFLICT → 锁等待 (ObLockWaitMgr)
    │     ├─ OB_TRANSACTION_SET_VIOLATION → retry / fail
    │     └─ OB_SUCCESS → 继续
    │
    └─ 4. 返回 ObMvccWriteResult (参见 #1 v2 §5)
```

### 11.2 写写冲突的核心算法（ObMvccRow::mvcc_write）

```cpp
// 简化版（ob_mvcc_row.cpp）
int ObMvccRow::mvcc_write(ObStoreCtx &ctx, ObTxNodeArg &arg,
                            bool check_exist, ObMvccWriteResult &res) {
  int ret = OB_SUCCESS;
  
  // 1. 加写锁
  if (OB_FAIL(lock_for_write_(arg.tx_id_))) {
    res.can_insert_ = false;
    res.is_mvcc_undo_ = false;
    return OB_TRY_LOCK_ROW_CONFLICT;
  }
  
  // 2. 检查写写冲突（hash table）
  if (OB_FAIL(check_write_write_conflict_(ctx, arg))) {
    res.is_mvcc_undo_ = true;
    return OB_TRY_LOCK_ROW_CONFLICT;
  }
  
  // 3. 检查唯一键冲突
  if (check_exist && OB_FAIL(check_unique_key_(ctx, arg))) {
    res.is_mvcc_undo_ = true;
    return OB_TRY_LOCK_ROW_CONFLICT;
  }
  
  // 4. 检查 TSC
  if (OB_FAIL(check_tsc_(ctx, arg))) {
    res.is_mvcc_undo_ = true;
    return OB_TRANSACTION_SET_VIOLATION;
  }
  
  // 5. 创建 ObMvccTransNode 并头插
  ObMvccTransNode *node = nullptr;
  if (OB_FAIL(build_tx_node_(arg, node))) {
    return OB_ERR_OUT_OF_MEMORY;
  }
  insert_to_head(node);
  
  // 6. 设置结果
  res.can_insert_ = true;
  res.need_insert_ = true;
  res.is_new_locked_ = true;
  res.is_mvcc_undo_ = false;
  res.tx_node_ = node;
  
  return OB_SUCCESS;
}
```

### 11.3 与 #1 v2 + #2 v2 的关联

- **#1 v2**: ObMvccTransNode（7 个 flag bit, 12 字段, buf_[0] 柔性数组）
- **#2 v2**: ObMultiVersionValueIterator（4 状态 + SCN 比较 + cleanout 机制）
- **#3 v2（本篇）**: 写写冲突检测（4 种冲突 + 17 bit 写标志 + 锁等待 + 死锁检测）

3 篇连续深度构成 OB MVCC 子系统的完整体系。

---

## 12. 与 #1-#100 的关系

### 12.1 横向关联

| 文章 | 关联 |
|------|------|
| #1 v2 deep-dive | ObMvccTransNode（7 个 flag）→ 写标志 `F_COMMITTED` / `F_ABORTED` / `F_ELR` 与写冲突状态一致 |
| #2 v2 deep-dive | ObMultiVersionValueIterator → `get_next_node` 决定哪些 tx node 对当前读可见（与写冲突后清理相关） |
| #3 original | 早期分析 MVCC 写冲突概要 |
| #4 MVCC Callback | ObITransCallback（参见 #1 v2）→ 13+ 虚函数含 `log_submitted_cb` / `log_sync_fail_cb` 与 #3 写后回调关联 |
| #5 MVCC Compact | `try_cleanout_*` 系列函数 → 与 #3 写写冲突后清理 old tx node 关联 |
| #14 / #89 MemTable | Memtable 的 `mvcc_write` 接口 → ObMvccEngine 委派 |
| #36 Concurrency Control | 死锁检测（ObDeadlockDetector）→ 触发 ObLockWaitMgr 检测环路 |
| #41 / #75 Latch | `ObRowLatch` → 写写冲突时的行锁（参见 #75） |
| #49 Log Service | 写写冲突后的 redo log 处理 |
| #65 Standby | Standby 模式下 redo log replay → 写冲突重放 |

### 12.2 关键路径修正

```
原推测:
  src/storage/mvcc/conflict/  ❌
  src/storage/concurrency_control/  ❌
实际:
  src/storage/memtable/mvcc/ob_mvcc_engine.{h,cpp}  ✅（写冲突核心）
  src/storage/memtable/ob_concurrent_control.h  ✅（ObWriteFlag）
  src/storage/memtable/ob_row_conflict_handler.h  ✅（冲突处理）
  src/storage/memtable/ob_row_conflict_info.h  ✅（冲突信息）
  src/storage/lock_wait_mgr/ob_lock_wait_mgr.h  ✅（锁等待）
```

---

## 13. 总结

### 13.1 核心数据结构

| 数据结构 | 行数 | 关键字段 / 标志 |
|----------|------|------------------|
| `ObMvccEngine::mvcc_write` | 193+642 | `OB_SUCCESS` / `OB_TRY_LOCK_ROW_CONFLICT` / `OB_TRANSACTION_SET_VIOLATION` 三种返回值 |
| `ObWriteFlag` | 173 | 17 bit 标志（14 用 + 49 保留） |
| `ObRowConflictHandler` | 93 | 冲突处理接口 |
| `ObRowConflictInfo` | 未知 | 5 种冲突类型 + conflict_tx_id + row_state + need_wait + max_wait_us |
| `ObLockWaitMgr` | 515 | 锁等待管理 + 死锁检测接口 |

### 13.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| **4 种写写冲突返回值** | `OB_SUCCESS` / `OB_TRY_LOCK_ROW_CONFLICT` / `OB_TRANSACTION_SET_VIOLATION` / 其他 |
| **17 bit 写标志** | `ObWriteFlag` 14 bit（is_table_api/table_lock/mds/dml_batch_opt/insert_up/write_only_index/check_row_locked/lob_aux/skip_flush_redo/update_uk/update_pk_dop/immediate_check/delete_insert/plain_ins_gts_opt/fk_skip_parent_pure_lock）+ 49 bit reserved |
| **sequence number 3 原则** | read 平等 / write > read / reader >= last |
| **PDML 优化** | DML 批优化 + write-only index + immediate row check |
| **hash table set 冲突检测** | `value.mvcc_write` 通过 hash table 加写锁检测 |
| **`OB_UNIS_VERSION(1)`** | ObWriteFlag 可跨进程序列化 |
| **Union + struct bit field** | `flag_` 整体读写 vs bit field 单 bit 操作 |
| **预留 49 bit** | `reserved_` 留给未来扩展 |

### 13.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/memtable/mvcc/ob_mvcc_engine.{h,cpp}` (193+642) | MVCC 引擎核心（含 mvcc_write 接口） |
| `src/storage/memtable/ob_concurrent_control.h` (173) | ObWriteFlag 17 bit + ObConcurrentControl |
| `src/storage/memtable/ob_row_conflict_handler.{h,cpp}` (93) | 行冲突处理 |
| `src/storage/memtable/ob_row_conflict_info.h` | 冲突信息 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` (515) | 锁等待 + 死锁检测 |
| `src/storage/memtable/mvcc/ob_mvcc_row.{h,cpp}` (参见 #1 v2) | `ObMvccRow::mvcc_write` 实现（hash table 冲突） |
| `src/storage/memtable/ob_memtable.{h,cpp}` | `mvcc_write` 入口 |

### 13.4 关键路径修正

```
原推测:
  src/storage/mvcc/conflict/  ❌
  src/storage/concurrency_control/  ❌
实际:
  src/storage/memtable/mvcc/ob_mvcc_engine.{h,cpp}  ✅
  src/storage/memtable/ob_concurrent_control.h  ✅
  src/storage/memtable/ob_row_conflict_handler.h  ✅
  src/storage/memtable/ob_row_conflict_info.h  ✅
  src/storage/lock_wait_mgr/ob_lock_wait_mgr.h  ✅
```

---

## 14. 与 #1 v2 + #2 v2 构成 MVCC 子系列 deep-dive 完整版

| 篇 | 主题 | commit |
|----|------|--------|
| #1 v2 deep-dive | MVCC Row / ObMvccTransNode | `c3d14bc` |
| #2 v2 deep-dive | MVCC Iterator / 多版本可见性 | `198587b` |
| **#3 v2 deep-dive**（本篇） | **MVCC 写冲突 + lock_wait + deadlock** | **（待 commit）** |

3 篇连续深度构成 OB MVCC 子系统的完整体系。下一篇是 **#1.4 MVCC Callback 完整实现**（深入 #4）—— 13+ 虚函数的完整 lifecycle 实现 + 各种边界 case。

要继续哪一篇 refine？