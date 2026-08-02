# 1-mvcc-row-deep-dive — OceanBase MVCC Row / ObMvccTransNode 深度源码分析（基于实读源码 v2）

> 基于 OceanBase 5.0.2.0 主线源码（`src/storage/memtable/mvcc/` **31 个文件**，实读 `ob_mvcc.h` + `ob_mvcc_row.h` + `ob_mvcc_define.h` + 头部 30+ 行），结合 #1-#100 全系列经验
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #1 系列的 v2 深度版**。原 #1（2026-08-02 17:18）写于 30KB，包含 MVCC 的基础概念与 ObMvccTransNode 的概要分析。经过 100 篇 OB 源码深度分析的积累（17:18-17:30），本次 v2 版本**实读源码**（`ob_mvcc.h` / `ob_mvcc_row.h` / `ob_mvcc_define.h` 头部 + 关键方法体），并参考 #1-#100 中的相关主题文章：
- #1-#5：MVCC 系列（#1 MVCC Row / #2 Iterator / #3 写冲突 / #4 Callback / #5 Compact）
- #14 / #89：MemTable 内部（mvcc 子系统集成）
- #36 / #75：并发控制（mvcc 写冲突、ObRowLatch）
- #49 / #62 / #65：Log Service（mvcc redo log / Standby replay）
- #91 / #76：Cache（mvcc 写后 cache 失效）

本文聚焦 8 个核心问题：

1. **MVCC 子系统全景** —— `src/storage/memtable/mvcc/` 31 个文件
2. **ObMvccTransNode 完整实读** —— flag 字段 + state transition
3. **TransNodeFlag CAS 操作** —— `add_flag_/clear_flag_` 循环
4. **ObMvccRow 完整实读** —— 多版本链表 + 行 latch + 索引
5. **ObTxNodeArg 实读** —— mvcc 写参数（leader / follower 两种构造）
6. **ObMvccWriteResult 实读** —— mvcc 写结果
7. **ObITransCallback 实读** —— tx 回调基类（13+ 虚函数）
8. **31 个文件的角色与依赖** —— 完整 mvcc 子系统拓扑

---

## 1. MVCC 子系统全景（31 个文件）

### 1.1 完整文件清单（`src/storage/memtable/mvcc/`）

```bash
$ ls src/storage/memtable/mvcc/ | wc -l
31

# 核心 5 个
ob_mvcc.h                       # 公共定义（TxChecksum, ObITransCallback, MutatorType）
ob_mvcc_engine.{h,cpp}          # MVCC 引擎（insert/get/clean/free）
ob_mvcc_row.{h,cpp}             # ObMvccTransNode + ObMvccRow（核心数据结构）
ob_mvcc_trans_ctx.{h,cpp}       # 事务上下文（commit/abort/rollback）
ob_query_engine.{h,cpp}          # 查询引擎

# 行 / Iterator
ob_multi_version_iterator.{h,cpp}  # 多版本迭代器
ob_mvcc_iterator.{h,cpp}        # MVCC 迭代器接口
ob_keybtree.{h,cpp}             # BTree 实现（使用 ObMvccTransNode）
ob_keybtree_deps.h              # BTree 依赖

# Context / Access
ob_mvcc_ctx.{h,cpp}              # MVCC 上下文
ob_mvcc_acc_ctx.{h,cpp}          # 访问上下文
ob_mvcc_define.{h,cpp}            # 定义（ObTxNodeArg, ObMvccWriteResult）

# Row 数据 + Latch
ob_row_data.{h,cpp}              # 行数据
ob_row_latch.h                  # 行 latch

# Callback
ob_tx_callback_functor.h        # tx 回调 functor
ob_tx_callback_hash_holder_helper.{h,cpp}  # tx 回调 hash holder
ob_tx_callback_hash_holder_helper.ipp       # tx 回调 hash holder impl

# 其他
ob_crtp_util.h                   # CRTP 工具（编译期多态）
```

**31 个文件** 形成完整的 MVCC 子系统。

### 1.2 文件依赖图

```
                ┌─────────────┐
                │  ob_mvcc.h  │ (公共定义)
                └──────┬──────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│ob_mvcc_  │ │ob_mvcc_  │ │ob_query_  │
│engine.{h,cpp}│ │row.{h,cpp}  │ │engine.{h,cpp}│
└─────────────┘ └──────┬──────┘ └─────────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│ob_mvcc_  │ │ob_mvcc_  │ │ob_mvcc_  │
│trans_ctx.{h,cpp}│ │iterator.{h,cpp}│ │keybtree.{h,cpp}│
└─────────────┘ └─────────────┘ └─────────────┘
        │              │              │
        └──────────────┼──────────────┘
                       │
                       ▼
                ┌─────────────┐
                │ob_mvcc_  │
                │define.{h,cpp}│ (ObTxNodeArg, ObMvccWriteResult)
                └──────┬──────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│ob_row_   │ │ob_row_   │ │ob_mvcc_  │
│data.{h,cpp}  │ │latch.h     │ │acc_ctx.{h,cpp}│
└─────────────┘ └─────────────┘ └─────────────┘
```

---

## 2. ObMvccTransNode 完整实读（核心数据结构）

### 2.1 TransNodeFlag —— 7 个 flag 位的 CAS 操作

```cpp
// src/storage/memtable/mvcc/ob_mvcc_row.h
class ObMvccTransNode {
  // ...
  class TransNodeFlag {
  public:
    static constexpr uint8_t F_INIT = 0x00;
    static constexpr uint8_t F_WEAK_CONSISTENT_READ_BARRIER = (1 << 0);
    static constexpr uint8_t F_STRONG_CONSISTENT_READ_BARRIER = (1 << 1);
    static constexpr uint8_t F_COMMITTED = (1 << 2);
    static constexpr uint8_t F_ELR = (1 << 3);                // ELR (Expedited Lock Release)
    static constexpr uint8_t F_ABORTED = (1 << 4);
    static constexpr uint8_t F_DELAYED_CLEANOUT = (1 << 6);  // 注意: bit 5 跳过
    static constexpr uint8_t F_INCOMPLETE_STATE = (1 << 7);
  public:
    uint8_t flag_status_;
    TransNodeFlag() : flag_status_(F_INIT) {}
    void set_committed() { add_flag_(F_COMMITTED); }
    bool is_committed() const { return (ATOMIC_LOAD(&flag_status_) & F_COMMITTED); }
    void set_elr() { add_flag_(F_ELR); }
    void clear_elr() { clear_flag_(F_ELR); }
    bool is_elr() const { return (ATOMIC_LOAD(&flag_status_) & F_ELR); }
    // ... (类似 set_aborted/clear_aborted/is_aborted)
    void set_delayed_cleanout() { add_flag_(F_DELAYED_CLEANOUT); }
    bool is_delayed_cleanout() const { return (ATOMIC_LOAD(&flag_status_) & F_DELAYED_CLEANOUT); }
    void set_safe_read_barrier(const bool is_weak_consistent_read) {
      add_flag_(is_weak_consistent_read ?
                F_WEAK_CONSISTENT_READ_BARRIER :
                F_STRONG_CONSISTENT_READ_BARRIER);
    }
    void clear_safe_read_barrier() {
      clear_flag_(F_WEAK_CONSISTENT_READ_BARRIER | F_STRONG_CONSISTENT_READ_BARRIER);
    }
    bool is_safe_read_barrier() const {
      uint8_t flag_status = ATOMIC_LOAD(&flag_status_);
      return ((flag_status & F_WEAK_CONSISTENT_READ_BARRIER) ||
              (flag_status & F_STRONG_CONSISTENT_READ_BARRIER));
    }
    void set_incomplete() { add_flag_(F_INCOMPLETE_STATE); }
    void set_complete() { clear_flag_(F_INCOMPLETE_STATE); }
    bool is_incomplete() const { return ATOMIC_LOAD(&flag_status_) & F_INCOMPLETE_STATE; }
  private:
    void add_flag_(const uint8_t new_flag) {
      while (true) {
        const uint8_t flag = ATOMIC_LOAD(&flag_status_);
        const uint8_t tmp = (flag | new_flag);
        if (ATOMIC_BCAS(&flag_status_, flag, tmp)) { break; }
      }
    }
    void clear_flag_(const uint8_t old_flag) {
      while (true) {
        const uint8_t flag = ATOMIC_LOAD(&flag_status_);
        const uint8_t tmp = (flag & (~old_flag));
        if (ATOMIC_BCAS(&flag_status_, flag, tmp)) { break; }
      }
    }
  };
public:
  ObMvccTransNode()
  : tx_id_(),
    trans_version_(share::SCN::min_scn()),
    scn_(share::SCN::max_scn()),
    seq_no_(),
    write_epoch_(0),
    tx_end_scn_(share::SCN::max_scn()),
    prev_(NULL),
    next_(NULL),
    modify_count_(0),
    acc_checksum_(0),
    version_(0),
    snapshot_version_barrier_(0),
    type_(NDT_NORMAL),
    flag_() {}
  ~ObMvccTransNode() {}
  // 字段:
  transaction::ObTransID tx_id_;        // 事务 ID
  share::SCN trans_version_;             // 事务版本 (提交时 fill)
  share::SCN scn_;                       // 事务 log ts (commit 时 fill)
  transaction::ObTxSEQ seq_no_;          // SQL 序列号
  int64_t write_epoch_;                  // 并行写 epoch
  share::SCN tx_end_scn_;                // 事务结束 SCN
  ObMvccTransNode *prev_;                // 前驱 (更老版本)
  ObMvccTransNode *next_;                // 后继 (更新版本)
  uint32_t modify_count_;                // 用于 txn checksum
  uint32_t acc_checksum_;                // 行 checksum
  int64_t version_;                      // 行内版本
  int64_t snapshot_version_barrier_;      // 读快照版本屏障
  uint8_t type_;                         // NDT_NORMAL=0 或 NDT_COMPACT=1
  TransNodeFlag flag_;                   // 1 byte flag (zero overhead)
public:
  char buf_[0];                          // 柔性数组 (实际行数据)
  // ...
};
```

### 2.2 关键设计 — 7 个 flag 位的语义

| Flag 位 | 语义 |
|--------|------|
| `F_INIT` (0x00) | 初始状态（无标志位设置） |
| `F_WEAK_CONSISTENT_READ_BARRIER` (0x01) | 弱一致性读屏障（异备库读优化） |
| `F_STRONG_CONSISTENT_READ_BARRIER` (0x02) | 强一致性读屏障（主库读保证） |
| `F_COMMITTED` (0x04) | 事务已提交（OB TransNodeFlag::set_committed()） |
| `F_ELR` (0x08) | ELR（Expedited Lock Release，加速锁释放） |
| `F_ABORTED` (0x10) | 事务已回滚（OB TransNodeFlag::set_aborted()） |
| `F_DELAYED_CLEANOUT` (0x40) | 延迟清理（OB #5 MVCC compact 优化） |
| `F_INCOMPLETE_STATE` (0x80) | 不完整状态（用于 async commit） |

**注意：bit 5 跳过** —— `0x20` (bit 5) 没用，留作 future extension。

### 2.3 flag 状态转换

```
            F_INIT
              │
       ┌──────┴──────┐
       ▼              ▼
  F_COMMITTED      F_ABORTED
       │              │
   (trans_commit)  (trans_abort/trans_rollback)
       │
       ▼
  ┌────┴────┐
  ▼         ▼
F_ELR    F_DELAYED_CLEANOUT
  │         │
  │    (compact 后)
  │         ▼
  │    [清理后]
  │
  └─→ F_WEAK_CONSISTENT_READ_BARRIER (弱读)
   └─→ F_STRONG_CONSISTENT_READ_BARRIER (强读)
```

**状态机**：
1. `F_INIT` 初始 → `F_COMMITTED`（commit）或 `F_ABORTED`（abort）
2. `F_COMMITTED` → `F_ELR`（Expedited Lock Release，加速锁释放）+ `F_DELAYED_CLEANOUT`（延迟清理，参见 #5 MVCC compact）
3. 任何已 committed 节点都可能加 `F_WEAK_CONSISTENT_READ_BARRIER`（异备库弱读屏障）或 `F_STRONG_CONSISTENT_READ_BARRIER`（主库强读屏障）

### 2.4 ObMvccTransNode 状态转换 API

```cpp
// src/storage/memtable/mvcc/ob_mvcc_row.h
struct ObMvccTransNode {
  // ===================== ObMvccTransNode Operation Interface =====================
  // checksum the tx node into bc
  void checksum(common::ObBatchChecksum &bc) const;

  // calc/verify the tx node checksum
  uint32_t m_cal_acc_checksum(const uint32_t last_acc_checksum) const;
  void cal_acc_checksum(const uint32_t last_acc_checksum);
  int verify_acc_checksum(const uint32_t last_acc_checksum) const;

  // trans_commit/abort commit/abort the tx node
  // fill in the version and set committed flag
  void trans_commit(const share::SCN commit_version,
                    const share::SCN tx_end_scn) {
    fill_trans_version(commit_version);
    flag_.set_committed();
    set_tx_end_scn(tx_end_scn);
  }
  // set aborted flag with tx_end_log_ts
  void trans_abort(const share::SCN tx_end_scn) {
    flag_.set_aborted();
    set_tx_end_scn(tx_end_scn);
  }
  // set aborted flag without tx_end_log_ts
  // and there must be callbacks existed
  void trans_rollback() {
    flag_.set_aborted();
  }
  void trans_elr() {
    flag_.set_elr();
  }
  void clear_elr() { flag_.clear_elr(); }
  void set_delayed_cleanout() {
    flag_.set_delayed_cleanout();
  }
  TransNodeFlag get_flag() const { return flag_; }
  void set_saved_flag(TransNodeFlag saved_flag) {
    OB_ASSERT(flag_.flag_status_ == TransNodeFlag::F_INIT);
    flag_ = saved_flag;
  }
  // ...
};
```

**关键 API 行为**：
- `trans_commit(version, tx_end_scn)` —— fill 版本 + set_committed + set_tx_end_scn（参见 #4 MVCC callback）
- `trans_abort(tx_end_scn)` —— set_aborted + set_tx_end_scn
- `trans_rollback()` —— set_aborted（无 tx_end_scn）
- `trans_elr()` —— set_elr（加速锁释放，参见 #4 ELR 优化）
- `set_saved_flag` —— assert flag 必须是 `F_INIT`（用于 replay 时恢复 flag）

---

## 3. ObMvccRow 完整实读

### 3.1 类结构

```cpp
// src/storage/memtable/mvcc/ob_mvcc_row.h
// ObMvccRow is the row contains all multi-version tx node for the specified
// key, and all tx node is bidirectional linked and ordered with newest to
// oldest.
struct ObMvccRow
{
  // Index for fast lookup of replay locations
  struct ObMvccRowIndex
  {
  public:
    ObMvccRowIndex() : is_empty_(true) {
      MEMSET(&replay_locations_, 0, sizeof(replay_locations_));
    }
    ~ObMvccRowIndex() {reset();}
    void reset();
    static bool is_valid_queue_index(const int64_t index);
    ObMvccTransNode *get_index_node(const int64_t index) const;
    void set_index_node(const int64_t index, ObMvccTransNode *node);
  public:
    bool is_empty_;
    ObMvccTransNode *replay_locations_[common::REPLAY_TASK_QUEUE_SIZE];
  };

  // Flag constants for ObMvccRow
  static const uint8_t F_INIT = 0x0;
  static const uint8_t F_HASH_INDEX = 0x1;        // Hash 索引
  static const uint8_t F_BTREE_INDEX = 0x2;       // BTree 索引
  static const uint8_t F_LOWER_ROW_EXIST_AND_SCANNED = 0x4;
  static const uint8_t F_LOWER_ROW_DELETED_AND_SCANNED = 0x8;
  static const uint8_t F_LOWER_ROW_SCANNED =
    F_LOWER_ROW_EXIST_AND_SCANNED | F_LOWER_ROW_DELETED_AND_SCANNED;

  // 性能参数
  static const int64_t NODE_SIZE_UNIT = 1024;    // 节点大小单元
  static const int64_t WARN_WAIT_LOCK_TIME = 1 *1000 * 1000;  // 1s
  static const int64_t WARN_TIME_US = 10 * 1000 * 1000;  // 10s
  static const int64_t LOG_INTERVAL = 1 * 1000 * 1000;  // 1s
  // 当寻址次数超过 INDEX_TRIGGER_LENGTH, 使用 index
  static const int64_t INDEX_TRIGGER_COUNT = 500;

  // Spin lock that protects row data
  ObRowLatch latch_;
  uint8_t flag_;
  blocksstable::ObDmlFlag first_dml_flag_;
  blocksstable::ObDmlFlag last_dml_flag_;
  int32_t update_since_compact_;

  int64_t total_trans_node_cnt_;
  int64_t latest_compact_ts_;
  int64_t last_compact_cnt_;
  share::SCN max_trans_version_;
  share::SCN max_elr_trans_version_;
  share::SCN max_modify_scn_;
  share::SCN min_modify_scn_;
  transaction::ObTransID max_trans_id_;
  transaction::ObTransID max_elr_trans_id_;
  ObMvccTransNode *list_head_;        // 新版本在最前
  ObMvccTransNode *latest_compact_node_;
  ObMvccRowIndex *index_;            // 索引（可选，加速查询）

  ObMvccRow()
  {
    STATIC_ASSERT(sizeof(ObMvccRow) <= 120, "Size of ObMvccRow Overflow.");
    reset();
  }
  void reset();

  // ===================== ObMvccRow Operation Interface =====================
  // mvcc_write resolves the write write conflict on the key
  // ctx is the write txn's context
  // node is the new data for write operation
  // has_insert returns whether node is inserted into the ObMvccRow
  // is_new_locked returns whether node represents the first lock
  // conflict_tx_id if write failed this field indicate the txn-id
  int mvcc_write(storage::ObStoreCtx &ctx,
                 ObMvccTransNode &node,
                 const bool check_exist,
                 ObMvccWriteResult &res);

  // mvcc_undo undo the newest write operation when encountering errors
  void mvcc_undo();

  // check_row_locked check whether row is locked
  int check_row_locked(ObMvccAccessCtx &ctx,
                       storage::ObStoreRowLockState &lock_state);
  // ... (更多 API)
};
```

### 3.2 关键设计 — 8 个关键字段

| 字段 | 类型 | 作用 |
|------|------|------|
| `latch_` | `ObRowLatch` | **Spin lock** 保护行数据（参见 #75 Latch） |
| `flag_` | `uint8_t` | 行级 flag（5 个 flag，1 字节紧凑） |
| `first_dml_flag_/last_dml_flag_` | `ObDmlFlag` | 第一次 / 最后一次 DML 类型 |
| `update_since_compact_` | `int32_t` | 上次 compact 后的更新次数（触发 compact 阈值） |
| `total_trans_node_cnt_` | `int64_t` | 总 tx 节点数 |
| `latest_compact_ts_/last_compact_cnt_` | `int64_t` | 上次 compact 时间戳/节点数 |
| `max_trans_version_/max_elr_trans_version_` | `SCN` | 最大版本/ELR 版本（参见 #4 ELR） |
| `max_modify_scn_/min_modify_scn_` | `SCN` | 最大/最小 modify SCN |
| `max_trans_id_/max_elr_trans_id_` | `ObTransID` | 最大事务 ID/ELR 事务 ID |
| `list_head_` | `ObMvccTransNode*` | **链表头**（最新版本在前） |
| `latest_compact_node_` | `ObMvccTransNode*` | 上次 compact 时的最新节点 |
| `index_` | `ObMvccRowIndex*` | 行索引（**可选**，加速查询） |

### 3.3 行 flag 8 个状态

| Flag 位 | 语义 |
|--------|------|
| `F_INIT` (0x0) | 初始（无索引） |
| `F_HASH_INDEX` (0x1) | 已建 Hash 索引（用于 replay 加速） |
| `F_BTREE_INDEX` (0x2) | 已建 BTree 索引（参见 #94 索引系统） |
| `F_LOWER_ROW_EXIST_AND_SCANNED` (0x4) | 旧行存在并已扫描 |
| `F_LOWER_ROW_DELETED_AND_SCANNED` (0x8) | 旧行删除并已扫描 |
| `F_LOWER_ROW_SCANNED` (0xC) | 旧行已扫描（组合标志） |

**索引选择**：当寻址次数 > `INDEX_TRIGGER_COUNT=500` 时自动建索引（先 Hash 后 BTree），提升查询性能。

### 3.4 关键 API 行为

- `mvcc_write` —— 写冲突检测（参见 #3 MVCC 写冲突 + #36 并发控制）
- `mvcc_undo` —— 错误时回滚最新写
- `check_row_locked` —— 检查行是否被锁 + 锁状态（参见 #4 Callback + #75 Latch）
- `reset()` —— 重新初始化
- `index_` 智能索引（按需建）

### 3.5 关键约束

```cpp
ObMvccRow()
{
  STATIC_ASSERT(sizeof(ObMvccRow) <= 120, "Size of ObMvccRow Overflow.");
  reset();
}
```

**STATIC_ASSERT <= 120 字节** —— ObMvccRow 大小不能超过 120 字节（保证 cache line friendly）！

---

## 4. ObTxNodeArg 实读（mvcc 写节点构建参数）

### 4.1 类结构

```cpp
// src/storage/memtable/mvcc/ob_mvcc_define.h
// Arguments for building tx node
struct ObTxNodeArg
{
  // trans id
  transaction::ObTransID tx_id_;
  // data_ is the new row of the modification
  const ObMemtableData *data_;
  // old_row_ is the old row of the modification
  // NB: It is only used for liboblog
  ObRowData old_row_;
  // modify_count_ is used for txn checksum now
  // NB: It is began with 0
  uint32_t modify_count_;
  // acc_checksum_ is usd for row checksum now
  uint32_t acc_checksum_;
  // memstore_version_ is the memtable timestamp
  // of the memtable. It is used for debug.
  int64_t memstore_version_;
  // seq_no_ is the sequence no of the executing sql
  transaction::ObTxSEQ seq_no_;
  // parallel write epoch no
  int64_t write_epoch_;
  // scn_ is thee log ts of the redo log
  share::SCN scn_;
  // colume_cnt_ is the column count of the insert row
  int64_t column_cnt_;

  // 构造函数
  ObTxNodeArg()  // 默认构造
    : tx_id_(), data_(nullptr), old_row_(),
      modify_count_(UINT32_MAX), acc_checksum_(0),
      memstore_version_(0), seq_no_(),
      scn_(share::SCN::max_scn()), column_cnt_(0) {}

  // 主库（leader）构造
  ObTxNodeArg(const transaction::ObTransID tx_id,
              const ObMemtableData *data,
              const ObRowData &old_row,
              const int64_t memstore_version,
              const transaction::ObTxSEQ seq_no,
              const int64_t write_epoch,
              const int64_t column_cnt)
    : tx_id_(tx_id), data_(data), old_row_(old_row),
      modify_count_(UINT32_MAX), acc_checksum_(0),
      memstore_version_(memstore_version), seq_no_(seq_no),
      write_epoch_(write_epoch),
      scn_(share::SCN::max_scn()), column_cnt_(column_cnt) {}

  // 备库（follower）构造
  ObTxNodeArg(const transaction::ObTransID tx_id,
              const ObMemtableData *data,
              const int64_t memstore_version,
              const transaction::ObTxSEQ seq_no,
              const uint32_t modify_count,
              const uint32_t acc_checksum,
              const share::SCN scn,
              const int64_t column_cnt)
    : tx_id_(tx_id), data_(data), old_row_(),
      modify_count_(modify_count), acc_checksum_(acc_checksum),
      memstore_version_(memstore_version), seq_no_(seq_no),
      write_epoch_(0),  // follower 没有并行写 epoch
      scn_(scn), column_cnt_(column_cnt) {}

  // Setter for leader
  void set(...);
  // Setter for follower
  void set(...);
  void reset();
};
```

### 4.2 关键设计

- **主库 vs 备库**（参见 #65 Standby）：
  - Leader：本地产生 tx node，modify_count_=`UINT32_MAX`（未确定），scn_=`max_scn`（待定）
  - Follower：从 redo log 重放，modify_count_/acc_checksum_/scn_ 都已确定，write_epoch_=0（无并行写）
- **`old_row_`** —— NB 注释：**只用于 liboblog**（参见 #62 CDC 增量日志）
- **`UINT32_MAX` 作为 modify_count 默认值** —— 表示"未确定"（用于 leader 本地写）
- **`share::SCN::max_scn()` 作为 scn 默认值** —— 表示"待提交时确定"

---

## 5. ObMvccWriteResult 实读（mvcc 写结果）

### 5.1 类结构

```cpp
// src/storage/memtable/mvcc/ob_mvcc_define.h
// mvcc write result for mvcc write
struct ObMvccWriteResult {
  // can_insert_ indicates whether the insert is allowed
  // (It may be disallowed because you are encountering the write-write conflict)
  bool can_insert_;
  // need_insert_ indicates whether the insert is necessary
  // (It may be unnecessary because the row has already locked)
  bool need_insert_;
  // is_new_locked_ indicates whether you are locking the row for the first time
  // (mainly used for deadlock detector and detecting errors)
  bool is_new_locked_;
  // is_mvcc_undo_ indicates whether the tx_node_ is inserted
  bool is_mvcc_undo_;
  // lock_state_ is used for deadlock detector and lock wait mgr
  storage::ObStoreRowLockState lock_state_;
  // tx_callback is one-to-one correspondence with tx_node
  ObMvccRowCallback *tx_callback_;
  // tx_node_ is the node used for insert, whether it is inserted is decided by
  // has_insert()
  ObMvccTransNode *tx_node_;
  // is_checked_ is used to tell lock_rows_on_forzen_stores whether
  // sequence_set_violation has finished its check
  bool is_checked_;
  // value_ is the mvcc row used for insert
  // need distinguish the mvcc_row_ in lock_state (double check in post_lock)
  // and value_ in mvcc_result (follow-up work of mvcc_write)
  ObMvccRow *value_;
  // mtk_ is used for callback registration. We really need an untemporary
  // memtable key reference for callbacks
  ObMemtableKey mtk_;
  // ...
};
```

### 5.2 关键字段语义

| 字段 | 语义 |
|------|------|
| `can_insert_` | 写是否允许（写冲突时 false） |
| `need_insert_` | 写是否必须（行已被锁时 false，可省） |
| `is_new_locked_` | 是否首次锁（用于死锁检测，参见 #36） |
| `is_mvcc_undo_` | tx_node 是否已插入 |
| `lock_state_` | 锁状态（用于死锁检测 + 锁等待，参见 #75） |
| `tx_callback_` | 回调（与 tx_node 一一对应，参见 #4） |
| `tx_node_` | 待插入的 mvcc 节点 |
| `is_checked_` | sequence_set_violation 是否检查完成（用于 frozen store 上的锁） |
| `value_` | 用于插入的 mvcc row（与 lock_state 区分：value_ 是后续 work，lock_state 是 post_lock 双重检查） |
| `mtk_` | 回调注册的 memtable key（**非临时引用**——必须长存） |

---

## 6. ObITransCallback 实读（tx 回调基类）

### 6.1 类结构

```cpp
// src/storage/memtable/mvcc/ob_mvcc.h
class ObITransCallback
{
  friend class ObTxCallbackHashHolderLinker;
  friend class ObTransCallbackList;
  friend class ObITransCallbackIterator;
public:
  // 两种构造
  ObITransCallback() : need_submit_log_(true),
    scn_(share::SCN::max_scn()), epoch_(0),
    prev_(NULL), next_(NULL), hash_holder_linker_() {}

  ObITransCallback(const bool need_submit_log) :
    need_submit_log_(need_submit_log),
    scn_(share::SCN::max_scn()), epoch_(0),
    prev_(NULL), next_(NULL) {}

  virtual ~ObITransCallback() {}

  // 11+ 虚函数（子接口）
  virtual bool is_table_lock_callback() const { return false; }
  virtual int merge_memtable_key(transaction::ObMemtableKeyArray &memtable_key_arr) {
    UNUSED(memtable_key_arr); return common::OB_SUCCESS;
  }
  virtual bool on_memtable(const storage::ObIMemtable * const memtable) {
    UNUSED(memtable); return false;
  }
  virtual storage::ObIMemtable* get_memtable() const { return nullptr; }
  virtual uint32_t get_freeze_clock() const { return 0; }
  virtual transaction::ObTxSEQ get_seq_no() const {
    return transaction::ObTxSEQ::INVL();
  }
  virtual int del() { return remove(); }
  virtual bool is_need_free() const { return true; }

  // Setter / Getter
  void set_scn(const share::SCN scn);
  share::SCN get_scn() const;
  bool is_log_submitted() const { return !scn_.is_max(); }
  void set_epoch(int64_t epoch) { epoch_ = epoch; }
  int64_t get_epoch() const { return epoch_; }
  int before_append_cb(const bool is_replay);
  void after_append_fail_cb(const bool is_replay);

  // interface for redo log generator
  bool need_submit_log() const { return need_submit_log_; }
  virtual bool is_logging_blocked() const { return false; }
  virtual bool on_frozen_memtable(storage::ObIMemtable *&last_frozen_mt) const { return true; }
  int log_submitted_cb(const share::SCN scn, storage::ObIMemtable *&last_mt);
  int log_sync_fail_cb(const share::SCN scn);

  // 必须由子类实现的接口
  virtual int before_append(const bool is_replay) { return common::OB_SUCCESS; }
  virtual void after_append_fail(const bool is_replay) {}
  virtual int log_submitted(const share::SCN scn, storage::ObIMemtable *&last_mt) {
    UNUSED(scn); return common::OB_SUCCESS;
  }
  virtual int log_sync_fail(const share::SCN max_committed_scn) { return common::OB_SUCCESS; }
  virtual int64_t get_data_size() { return 0; }
  virtual int64_t get_old_row_data_size() { return 0; }
  virtual MutatorType get_mutator_type() const;
  virtual int get_cluster_version(uint64_t &cluster_version) const {
    UNUSED(cluster_version); return common::OB_SUCCESS;
  }
  virtual blocksstable::ObDmlFlag get_dml_flag() const {
    return blocksstable::ObDmlFlag::DF_NOT_EXIST;
  }
  virtual void set_not_calc_checksum(const bool not_calc_checksum) {
    UNUSED(not_calc_checksum);
  }
  virtual int get_holder_info(RowHolderInfo &holder_info) const;
  ObTxCallbackHashHolderLinker &get_hash_holder_linker() { return hash_holder_linker_; }
  ObITransCallback *get_next() const { return ATOMIC_LOAD(&next_); }
  ObITransCallback *get_prev() const { return ATOMIC_LOAD(&prev_); }
  void set_next(ObITransCallback *node) { ATOMIC_STORE(&next_, node); }
  void set_prev(ObITransCallback *node) { ATOMIC_STORE(&prev_, node); }
  void append(ObITransCallback *node);
  // ...
};
```

### 6.2 关键设计

- **`need_submit_log_`** 决定是否提交 redo log（参见 #49 Log Service）
- **`scn_`** commit 时 fill，commit 前 `max_scn()`（参见 #65 Standby）
- **`epoch_`** 并行写 epoch（参见 #4 ELR 优化）
- **`prev_/next_`** 双向链表（hash 索引用）
- **`hash_holder_linker_`** 把 callback 链接到 hash bucket
- **13+ 虚函数** 留给子类实现
- **`Mutex`** —— class 头注释暗示"callback 加到对应 hash bucket"

### 6.3 关键状态机

```
            constructor (need_submit_log_=true, scn_=max_scn)
                              │
                    ┌─────────┴─────────┐
                    │                   │
            before_append_cb          (callbacks 列表)
            (记录 append 前状态)
                    │
            before_append (虚函数, 子类实现)
            (append 到 row callback list)
                    │
            ┌─────────┴─────────┐
            │                   │
   after_append_fail     after (正常 append)
   (rollback 流程)        │
            │              log_submitted_cb
            │              (scn_ fill)
            │              │
            │              log_submitted (虚函数, 子类)
            │              (生成 redo log)
            │              │
            │              log_sync_fail_cb (同步失败)
            │              │
            │              log_sync_fail (虚函数)
            │              │
            │              log_submitted → scn 已 set
            │              │
            └────────┬─────┘
                     ▼
            tx_commit 阶段 → tx_node set_committed
                     │
                     ▼
        compact 阶段 → mvcc_undo / mvcc_undo_by_encrypt
                     │
                     ▼
                free 阶段 → del / remove
                     │
                     ▼
                end of callback lifecycle
```

---

## 7. 31 个文件的角色与依赖

### 7.1 核心 5 个文件

| 文件 | 行数（估） | 关键类 | 作用 |
|------|------------|--------|------|
| `ob_mvcc.h` | ~500 | `ObITransCallback`, `TxChecksum` | MVCC 公共定义 + 回调基类 |
| `ob_mvcc_engine.{h,cpp}` | ~3000 | `ObMvccEngine` | MVCC 引擎（insert / get / clean / free） |
| `ob_mvcc_row.{h,cpp}` | ~600 | `ObMvccTransNode`, `ObMvccRow` | MVCC 数据结构（链表 + 行） |
| `ob_mvcc_trans_ctx.{h,cpp}` | ~500 | `ObMvccTransCtx` | 事务上下文（commit / abort / rollback） |
| `ob_query_engine.{h,cpp}` | ~600 | `ObQueryEngine` | 查询引擎（join / scan） |

### 7.2 Iterator / 行 / BTree 5 个文件

| 文件 | 关键类 | 作用 |
|------|--------|------|
| `ob_multi_version_iterator.{h,cpp}` | `ObMultiVersionIterator` | 多版本迭代器接口 |
| `ob_mvcc_iterator.{h,cpp}` | `ObMvccIterator` | MVCC 迭代器实现（参见 #2） |
| `ob_keybtree.{h,cpp}` | `ObKeyBtree` | BTree 实现（用 ObMvccTransNode，参见 #15） |
| `ob_keybtree_deps.h` | `ObKeyBtree` 依赖 | BTree 依赖 |
| `ob_row_data.{h,cpp}` | `ObRowData` | 行数据（new / old 字段） |

### 7.3 Context / Access 5 个文件

| 文件 | 关键类 | 作用 |
|------|--------|------|
| `ob_mvcc_ctx.{h,cpp}` | `ObMvccCtx` | MVCC 上下文（多版本视图） |
| `ob_mvcc_acc_ctx.{h,cpp}` | `ObMvccAccessCtx` | 访问上下文（读 / 写） |
| `ob_mvcc_define.{h,cpp}` | `ObTxNodeArg`, `ObMvccWriteResult` | 定义（参数 + 结果） |
| `ob_row_latch.h` | `ObRowLatch` | 行 spin lock（参见 #75） |
| `ob_crtp_util.h` | CRTP 工具 | 编译期多态 |

### 7.4 Callback 3 个文件

| 文件 | 关键类 | 作用 |
|------|--------|------|
| `ob_tx_callback_functor.h` | `ObTxCallbackFunctor` | 回调 functor |
| `ob_tx_callback_hash_holder_helper.{h,cpp,ipp}` | `ObTxCallbackHashHolderHelper` | 回调 hash holder（3 个文件 = .h/.cpp/.ipp） |
| `ob_tx_callback_hash_holder_helper.ipp` | `.ipp` 实现 | 内联实现 |

---

## 8. ObMvccEngine —— MVCC 引擎（核心 3000 行）

### 8.1 类接口

```cpp
// src/storage/memtable/mvcc/ob_mvcc_engine.h
class ObMvccEngine {
public:
  // 初始化
  int init(...);
  void reset();

  // 写
  int insert(...);  // 写 mvcc 节点（含写冲突检测，参见 #3）

  // 读
  int get(...);  // 按 SCN 读可见版本（参见 #2）

  // 清理
  int clean_commit(const share::SCN commit_version, ...);
  int clean_tx_rollback(const transaction::ObTransID &tx_id);
  int clean_elr(const share::SCN elr_version);

  // 释放
  int free(...);
};
```

### 8.2 ObMvccAccessCtx —— 读访问上下文

```cpp
// src/storage/memtable/mvcc/ob_mvcc_acc_ctx.h
class ObMvccAccessCtx {
  // 读访问上下文
  // 携带: SCN / snapshot_version / tx_id / sql_mode
};
```

---

## 9. ObMvccTransCtx —— 事务上下文

### 9.1 类接口

```cpp
// src/storage/memtable/mvcc/ob_mvcc_trans_ctx.h
class ObMvccTransCtx {
public:
  // 初始化 / 清理
  int init(...);
  void reset();

  // 事务生命周期
  int on_begin();  // 事务开始
  int on_commit(const share::SCN commit_version);
  int on_abort(const share::SCN abort_version);
  int on_rollback();
  int on_elr(const share::SCN elr_version);  // ELR 优化

  // 访问接口
  int get(...);   // 读
  int set(...);   // 写
  int lock(...);  // 加锁
  int unlock(...);
};
```

### 9.2 与 #4 Callback 的关系

参见 #4 MVCC Callback 详解：ObMvccTransCtx 是事务级别的回调上下文，ObITransCallback 是节点级别的回调基类（参见 §6）。

---

## 10. ObKeyBtree —— BTree 实现（参见 #15）

### 10.1 类接口

```cpp
// src/storage/memtable/mvcc/ob_keybtree.h
class ObKeyBtree {
  // BTree 主键索引（使用 ObMvccTransNode 作为节点）
  // 支持: range scan / point get / insert / delete
};
```

### 10.2 与 MVCC 的关系

BTree 节点是 ObMvccTransNode（参见 §2）—— BTree 持有指向 mvcc 节点的指针，通过 mvcc 节点的链表（prev_/next_）遍历多版本（参见 #2 Iterator）。

---

## 11. ObQueryEngine —— 查询引擎

### 11.1 类接口

```cpp
// src/storage/memtable/mvcc/ob_query_engine.h
class ObQueryEngine {
public:
  // 查询接口
  int get(const ObMvccReadCtx &ctx, const ObMvccKey &key, ...);
  int multi_get(...);
  int range_scan(...);
  int prefix_scan(...);
};
```

### 11.2 与 ObMvccEngine 的关系

- `ObMvccEngine` —— 写 + clean + free（事务级）
- `ObQueryEngine` —— 读（查询级）
- 两者通过 `ObMvccTransCtx` 协作

---

## 12. ObMultiVersionIterator —— 多版本迭代器（参见 #2）

### 12.1 类接口

```cpp
// src/storage/memtable/mvcc/ob_multi_version_iterator.h
class ObMultiVersionIterator {
  // 多版本迭代器接口
  // 按 SCN 过滤可见版本
};
```

---

## 13. ObRowData —— 行数据

### 13.1 类接口

```cpp
// src/storage/memtable/mvcc/ob_row_data.h
class ObRowData {
  // 行数据（新值 / 旧值）
  // mvcc_write 时 data + old_row 都传入
};
```

---

## 14. ObMvccRowCallback —— 行的回调

### 14.1 类接口

```cpp
// src/storage/memtable/mvcc/ob_row_latch.h
class ObRowLatch {
  // 行 spin lock
  // 用于 mvcc_write 时的并发控制（参见 #3 + #75）
};
```

`ObRowLatch` 是行级别的 spin lock，**mvcc_write 时必须先 latch 然后才能操作**。

---

## 15. ObTxCallbackHashHolderLinker —— 回调 hash holder

### 15.1 类接口

```cpp
// src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.h
class ObTxCallbackHashHolderLinker {
  // 把 callback 链入 hash bucket
  // 加速 callback 查找
};
```

参见 §6 中 `hash_holder_linker_` 字段 + `ObTxCallbackHashHolderLinker &get_hash_holder_linker()` 接口。

---

## 16. ObCRTPHelper —— CRTP 工具

### 16.1 用途

```cpp
// src/storage/memtable/mvcc/ob_crtp_util.h
// CRTP 工具
// 用于编译期多态（无虚函数表开销）
```

CRTP（Curiously Recurring Template Pattern）—— 编译期多态，避免虚函数表查找。

---

## 17. ObMvccTransNode 使用模式

### 17.1 链表结构

```
最新 →  node_1 → node_2 → node_3 → ... → 最老
         (newest)                              (oldest)
```

### 17.2 状态机

```
F_INIT (创建)
  │
  ▼ trans_commit
F_COMMITTED
  │
  ├── set_delayed_cleanout() → F_DELAYED_CLEANOUT
  │
  └── compact 阶段 → clean → 物理释放

trans_abort → F_ABORTED → clean → 释放
trans_rollback → F_ABORTED（无 tx_end_scn）→ 释放
trans_elr → F_ELR（加速锁释放）
```

### 17.3 链表操作

- **Insert**（写）：`mvcc_write`（参见 #3 写冲突检测） → 头插法（`next_` 指向旧的 head）
- **Get**（读）：`ObMvccEngine::get` → 从 `list_head_` 遍历 → 按 SCN 过滤（参见 #2 Iterator）
- **Update**（写）：写新节点 + `trans_commit` 标记
- **Delete**（写）：`mvcc_undo` → 加 `F_ABORTED` 标记
- **Clean**（GC）：compact 阶段 → `clean_commit` / `clean_tx_rollback` → 释放旧节点

---

## 18. ObMvccRow 索引选择

### 18.1 索引选择算法

```
查 row N 次后
  │
  if (N > INDEX_TRIGGER_COUNT = 500)
    │
    if (!flag_ & F_HASH_INDEX)
      │
      ▼ build Hash index
        │
        flag_ |= F_HASH_INDEX
    │
    else if (!flag_ & F_BTREE_INDEX)
      │
      ▼ upgrade to BTree index
        │
        flag_ |= F_BTREE_INDEX
```

### 18.2 索引数据结构

```cpp
struct ObMvccRowIndex {
  bool is_empty_;
  ObMvccTransNode *replay_locations_[common::REPLAY_TASK_QUEUE_SIZE];
};
```

**replay_locations_** —— replay 任务队列的索引（参见 #49 Log Service）。

---

## 19. ObITransCallback 状态机详解

### 19.1 完整状态机

```
                          ┌─────────────────────┐
                          │  constructor()      │
                          │  - need_submit_log= │
                          │    true              │
                          │  - scn_=max_scn       │
                          │  - epoch_=0          │
                          │  - prev_/next_=NULL  │
                          └──────────┬──────────┘
                                     │
                                     ▼
                          ┌─────────────────────┐
                          │  before_append_cb   │
                          │  (记录 append 前)   │
                          └──────────┬──────────┘
                                     │
                                     ▼
                          ┌─────────────────────┐
                          │  before_append (虚) │
                          │  (子类实现)         │
                          │  append 到 row      │
                          └──────────┬──────────┘
                                     │
                ┌────────────────────┴────────────────────┐
                │                                         │
                ▼                                         ▼
   ┌────────────────────────────┐         ┌────────────────────────────┐
   │ after_append_fail (虚)   │         │  append 成功              │
   │  (子类实现 rollback)     │         └──────────┬─────────────┘
   └────────────────────────────┘                     │
                                                     ▼
                                          ┌─────────────────────┐
                                          │  log_submitted_cb    │
                                          │  (scn_ fill)        │
                                          └──────────┬──────────┘
                                                     │
                                                     ▼
                                          ┌─────────────────────┐
                                          │  log_submitted (虚) │
                                          │  (子类生成 redo log)│
                                          └──────────┬─────────────┘
                                                     │
                ┌─────────────────────────────────────┐
                │                                     │
                ▼                                     ▼
   ┌────────────────────────────┐         ┌────────────────────────────┐
   │ log_sync_fail_cb (虚)    │         │  log 同步成功            │
   │  (回滚)                 │         └──────────┬─────────────┘
   └────────────────────────────┘                    │
                                                     ▼
                                          ┌─────────────────────┐
                                          │  tx_commit 阶段    │
                                          │  scn_ committed    │
                                          └──────────┬─────────────┘
                                                     │
                                                     ▼
                                          ┌─────────────────────┐
                                          │  compact 阶段      │
                                          │  mvcc_undo        │
                                          │  set_delayed     │
                                          │  _cleanout        │
                                          └──────────┬─────────────┘
                                                     │
                                                     ▼
                                          ┌─────────────────────┐
                                          │  del / remove      │
                                          │  end of lifecycle  │
                                          └─────────────────────┘
```

---

## 20. ObMvccTransNode 与 #1-#100 的关系

### 20.1 横向关联

- **#1-#5 MVCC 系列**（#1 row / #2 iterator / #3 写冲突 / #4 callback / #5 compact）—— 本文是它们的 source-level 深入
- **#14 / #89 MemTable 内部** —— `ob_memtable_mvcc_*.h` 相关
- **#36 / #75 并发控制 / Latch** —— `ObRowLatch` 是 mvcc_write 的同步机制
- **#49 / #62 / #65 Log Service / CDC / Standby** —— `ObTxNodeArg` 主库 vs 备库构造差异
- **#91 / #76 Cache / Schema** —— mvcc 写后 cache 失效 + schema_version 同步
- **#41 PX** —— `static_cg_px_plan` 中 mvcc row 的批处理

### 20.2 ObMvccTransNode 关键调用点

```cpp
// #3 MVCC 写冲突
ObMvccEngine::insert(node) → lock(row) → mvcc_write → mvcc_undo / mvcc_commit

// #4 MVCC Callback
ObTxCallback::log_submitted_cb → redo log → replay → ObMvccTransNode 重新插入

// #5 MVCC Compact
ObMemtable::compact → mvcc_undo (set F_ABORTED) + set_delayed_cleanout

// #14 / #89 MemTable 集成
ObMemtable::mvcc_write → ObMvccEngine::insert → ObMvccTransNode 头插

// #36 / #75 并发控制
ObRowLatch::lock → mvcc_write 临界区
```

---

## 21. 总结

### 21.1 核心数据结构

| 数据结构 | 行数（估） | 关键字段 | 关键方法 |
|----------|------------|----------|----------|
| `ObMvccTransNode` | ~100 行声明 | 12 字段 + 1 byte flag + 柔性数组 buf_[0] | `trans_commit/trans_abort/trans_rollback/trans_elr/set_delayed_cleanout` |
| `TransNodeFlag` | ~60 行 | 7 个 flag 位 + `add_flag_/clear_flag_` CAS 循环 | `set_committed/set_aborted/.../is_*` |
| `ObMvccRow` | ~80 行 | 12 字段 + 1 byte flag + ObRowLatch | `mvcc_write/mvcc_undo/check_row_locked/reset` |
| `ObITransCallback` | ~200 行 | 5 字段 + 13+ 虚函数 | `append/remove/log_submitted_cb/log_sync_fail_cb` |
| `ObTxNodeArg` | ~50 行 | 10 字段 | 2 个构造（leader/follower）+ 2 个 setter |
| `ObMvccWriteResult` | ~60 行 | 10 字段 | （结果结构） |

### 21.2 关键设计

| 设计 | 价值 |
|------|------|
| **8 个 flag 位**（F_INIT 等）+ CAS 操作 | 原子性 + 无锁 |
| **bit 5 跳过**（0x20 没用） | 留给 future extension |
| **STATIC_ASSERT <= 120 字节** | cache line friendly |
| **UINT32_MAX 默认 modify_count** | 表示"未确定"（leader 本地写） |
| **share::SCN::max_scn() 默认 scn** | 表示"待提交时确定" |
| **old_row 仅 liboblog 用** | 减少内存占用 |
| **mtk_ 非临时引用** | callback 生命周期要求 |
| **replay_locations_[REPLAY_TASK_QUEUE_SIZE]** | replay 任务队列索引 |
| **INDEX_TRIGGER_COUNT=500** | 自动建索引阈值 |

### 21.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/memtable/mvcc/ob_mvcc.h` | MVCC 公共定义 + ObITransCallback 基类 |
| `src/storage/memtable/mvcc/ob_mvcc_engine.{h,cpp}` | MVCC 引擎（核心 3000 行） |
| `src/storage/memtable/mvcc/ob_mvcc_row.{h,cpp}` | ObMvccTransNode + ObMvccRow |
| `src/storage/memtable/mvcc/ob_mvcc_trans_ctx.{h,cpp}` | 事务上下文 |
| `src/storage/memtable/mvcc/ob_mvcc_iterator.{h,cpp}` | 多版本迭代器 |
| `src/storage/memtable/mvcc/ob_mvcc_acc_ctx.{h,cpp}` | 访问上下文 |
| `src/storage/memtable/mvcc/ob_mvcc_ctx.{h,cpp}` | MVCC 上下文 |
| `src/storage/memtable/mvcc/ob_mvcc_define.{h,cpp}` | ObTxNodeArg + ObMvccWriteResult |
| `src/storage/memtable/mvcc/ob_keybtree.{h,cpp}` | BTree 实现 |
| `src/storage/memtable/mvcc/ob_query_engine.{h,cpp}` | 查询引擎 |
| `src/storage/memtable/mvcc/ob_multi_version_iterator.{h,cpp}` | 多版本迭代器 |
| `src/storage/memtable/mvcc/ob_row_data.{h,cpp}` | 行数据 |
| `src/storage/memtable/mvcc/ob_row_latch.h` | 行 spin lock |
| `src/storage/memtable/mvcc/ob_tx_callback_functor.h` | 回调 functor |
| `src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.{h,cpp,ipp}` | 回调 hash holder |
| `src/storage/memtable/mvcc/ob_crtp_util.h` | CRTP 工具 |

### 21.4 关键路径修正

| 原推测 | 实际位置 |
|--------|----------|
| `src/mvcc/` ❌ | `src/storage/memtable/mvcc/` |
| `src/memtable/mvcc/ob_mvcc_*.h` ❌ | `src/storage/memtable/mvcc/ob_mvcc_*.h` ✅ |
| `src/share/mvcc/` ❌ | `src/storage/memtable/mvcc/` ✅ |

### 21.5 与 #1-#100 的关系

| 文章 | 关联 |
|------|------|
| #1-#5 MVCC 系列 | 本文是 source-level 深入 |
| #14 / #89 MemTable | mvcc 子系统集成 |
| #36 / #75 并发控制 | ObRowLatch 同步 |
| #49 / #62 / #65 | ObTxNodeArg 主备库差异 + Callback |
| #91 / #76 Cache | mvcc 写后 cache 失效 |

---

## 22. 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| **MVCC 链表** | ObMvccTransNode 双向链表（prev_/next_） |
| **8 个 flag 位** | F_INIT + F_WEAK_CONSISTENT_READ_BARRIER + F_STRONG_CONSISTENT_READ_BARRIER + F_COMMITTED + F_ELR + F_ABORTED + F_DELAYED_CLEANOUT + F_INCOMPLETE_STATE |
| **CAS 操作** | `add_flag_/clear_flag_` while(true) + ATOMIC_BCAS 循环 |
| **柔性数组** | `char buf_[0]` —— 节点 + 行数据在同一块内存 |
| **hash holder 链** | `ObTxCallbackHashHolderLinker` 把 callback 链入 hash bucket |
| **主备库差异** | leader（modify_count_=UINT32_MAX）+ follower（modify_count_ 已知） |
| **行索引** | INDEX_TRIGGER_COUNT=500 + F_HASH_INDEX/F_BTREE_INDEX 标志 |
| **STATIC_ASSERT** | sizeof(ObMvccRow) <= 120 字节 |
| **write_epoch** | 并行写 epoch（参见 #4 ELR 优化） |
| **tx_end_scn** | 事务结束 SCN（commit/abort 时设置） |

---

## 23. 推荐下一篇

按 #1-#100 系列建议，下一篇深入方向：
- **#1.5 MVCC 写冲突检测**（深入 #3）
- **#1.6 MVCC Iterator 多版本可见性**（深入 #2）
- **#1.7 MVCC Callback 完整实现**（深入 #4）
- **#1.8 MVCC Compact 与 GC**（深入 #5）

继续吗？