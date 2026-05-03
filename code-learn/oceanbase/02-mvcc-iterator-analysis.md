# 02-mvcc-iterator — OceanBase MVCC 读取器与可见性判断深度源码分析

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

MVCC 读取的核心问题是：**给定一个 `ObMvccRow` 的版本链表和 `ObTxSnapshot` 快照，如何找到第一个满足可见性条件的版本节点？**

`ObMvccValueIterator`（`ob_mvcc_iterator.cpp` @ L28）是这一问题的答案。它从 `ObMvccRow::list_head_`（最新版本）开始遍历，通过 `lock_for_read_inner_` 的状态机判断每个节点的可见性。本文将深入分析：

1. `ObMvccValueIterator::lock_for_read_` / `lock_for_read_inner_` 的完整状态机
2. `ObLockForReadArg` 与 `ObTxTableGuards::lock_for_read` 的交互
3. `ObStoreRowLockState` 的 7 个字段及其含义
4. `try_cleanout_tx_node_` 延迟清理机制
5. `ObTxTableGuards` 的 `src_tx_table_guard_` 与 transfer 场景

**doom-lsp 确认**：`ob_mvcc_iterator.cpp` 中 `lock_for_read_` @ L68，`lock_for_read_inner_` @ L104，`try_cleanout_tx_node_` @ L299，`move_to_next_node_` @ L355，`check_row_locked` @ L365。

---

## 1. 核心数据结构

### 1.1 `ObMvccValueIterator`——MVCC 读取迭代器

```c
// ob_mvcc_iterator.h:94-161 - doom-lsp 确认
struct ObMvccValueIterator
{
  bool                 is_inited_;
  ObMvccAccessCtx     *ctx_;           // 访问上下文（snapshot、tx_id 等）
  ObMvccRow           *value_;         // 指向行的指针
  ObMemtableKey       *memtable_key_; // 所在 memtable 的 key
  ObLSID               memtable_ls_id_;
  ObMvccTransNode      *version_iter_; // ★ 解析出的可见版本节点（结果）

  ObMvccTransNode *get_trans_node() const { return version_iter_; }
  ObMvccRow *get_mvcc_row() const { return value_; }
  int get_next_node(const void *&tnode);  // 遍历下一个版本
  void move_to_next_node_();               // 版本迭代推进
  int try_cleanout_tx_node_(ObMvccTransNode *tnode);  // 延迟清理
};
```

**关键**：`version_iter_` 是最终解析出的可见版本指针，外部通过 `get_trans_node()` 获取。如果 `value_` 为 NULL 表示行不存在。

### 1.2 `ObStoreRowLockState`——锁状态描述符

```c
// ob_i_store.h:225-295 - doom-lsp 确认
struct ObStoreRowLockState
{
  bool                 is_locked_;              // 行是否被锁定
  share::SCN            trans_version_;          // 事务提交版本
  transaction::ObTransID lock_trans_id_;       // 锁持有者事务 ID
  transaction::ObTxSEQ   lock_data_sequence_;  // 锁的数据序号（ObTxSEQ）
  blocksstable::ObDmlFlag lock_dml_flag_;      // 锁的 DML 类型
  bool                 is_delayed_cleanout_;   // 是否处于延迟清理状态
  memtable::ObMvccRow  *mvcc_row_;             // 指向行对象
  share::SCN            trans_scn_;             // 事务 SCN（memtable 用 scn_）
};
```

**内联判断方法**（doom-lsp @ ob_i_store.h:235-270）：

```c
inline bool row_exist() const {
  return lock_dml_flag_ == DF_UPDATE ||  // UPDATE 锁意味着行存在
         lock_dml_flag_ == DF_INSERT ||  // INSERT 锁意味着行存在
         lock_dml_flag_ == DF_LOCK;       // 纯 Lock 也意味着行存在
}

inline bool row_deleted() const {
  return lock_dml_flag_ == DF_DELETE;  // DELETE 锁 = 行已被删除
}

inline bool is_row_decided() const {
  // 行状态已确定：要么被锁，要么有版本且 dml_flag 不是 NOT_EXIST
  return is_locked_ ||
    (!trans_version_.is_min() && lock_dml_flag_ != DF_NOT_EXIST);
}
```

### 1.3 `ObLockForReadArg`——读取锁参数

```c
// ob_trans_define.h:232-255 - doom-lsp 确认
struct ObLockForReadArg
{
  ObLockForReadArg(memtable::ObMvccAccessCtx &acc_ctx,
                   ObTransID data_trans_id,
                   ObTxSEQ data_sql_sequence,
                   bool read_latest,
                   bool read_uncommitted,
                   share::SCN scn)
    : mvcc_acc_ctx_(acc_ctx),
    data_trans_id_(data_trans_id),
    data_sql_sequence_(data_sql_sequence),
    read_latest_(read_latest),
    read_uncommitted_(read_uncommitted),
    scn_(scn) {}

  memtable::ObMvccAccessCtx &mvcc_acc_ctx_;  // 读取事务的访问上下文
  ObTransID data_trans_id_;                    // 数据所在事务的 ID
  ObTxSEQ   data_sql_sequence_;               // 数据的序列号
  bool      read_latest_;                     // 是否读取最新数据（Halloween 问题相关）
  bool      read_uncommitted_;               // 是否读取未提交数据
  share::SCN scn_;                           // 数据的 SCN（用于 transfer 场景比较）
};
```

---

## 2. `lock_for_read_` — 入口与屏障设置

### 2.1 `init` 与 `lock_for_read_` 的关系

```c
// ob_mvcc_iterator.cpp:28-65 - doom-lsp 确认
int ObMvccValueIterator::init(ObMvccAccessCtx &ctx,
                              const ObMemtableKey *key,
                              ObMvccRow *value,
                              const ObLSID memtable_ls_id,
                              const ObQueryFlag &query_flag)
{
  int ret = OB_SUCCESS;
  reset();
  ctx_ = &ctx;
  if (OB_UNLIKELY(!ctx.get_snapshot_version().is_valid())) {
    ret = OB_ERR_UNEXPECTED;
  } else if (OB_ISNULL(value)) {
    is_inited_ = true;  // 行不存在
  } else {
    value_ = value;
    memtable_ls_id_ = memtable_ls_id;
    if (OB_FAIL(lock_for_read_(query_flag))) {
      // 解析可见版本位置
    }
    is_inited_ = true;
  }
}
```

### 2.2 遍历入口

```c
// ob_mvcc_iterator.cpp:68-103 - doom-lsp 确认
int ObMvccValueIterator::lock_for_read_(const ObQueryFlag &flag)
{
  int ret = OB_SUCCESS;
  ObMvccTransNode *iter = value_->get_list_head();  // 从最新版本开始
  version_iter_ = NULL;

  while (OB_SUCC(ret) && NULL != iter && NULL == version_iter_) {
    if (OB_FAIL(lock_for_read_inner_(flag, iter))) {
      // 每个节点调用 lock_for_read_inner_ 进行可见性判断
      // 如果可见，version_iter_ 被设置为 iter，循环终止
    }
  }

  // 设置快照版本屏障（防御性检查）
  if (NULL != version_iter_) {
    if (ctx_->is_weak_read()) {
      version_iter_->set_safe_read_barrier(true);
      version_iter_->set_snapshot_version_barrier(ctx_->snapshot_.version_,
                                                  ObMvccTransNode::WEAK_READ_BIT);
    } else if (!flag.is_prewarm() && !version_iter_->is_elr()) {
      version_iter_->set_snapshot_version_barrier(ctx_->snapshot_.version_,
                                                  ObMvccTransNode::NORMAL_READ_BIT);
    }
  }
  return ret;
}
```

**关键洞察**：遍历从 `list_head_`（最新）向旧版本方向走，一旦找到可见版本就停止（`version_iter_ != NULL`）。**MVCC 读取的"最新"语义**：返回的是所有可见版本中"最新的那个"。

---

## 3. `lock_for_read_inner_` — 可见性判断状态机（核心）

```c
// ob_mvcc_iterator.cpp:104-238 - doom-lsp 确认
int ObMvccValueIterator::lock_for_read_inner_(const ObQueryFlag &flag,
                                              ObMvccTransNode *&iter)
```

### 3.1 变量读取顺序——ARM 内存模型的坑

```c
// ob_mvcc_iterator.cpp:115-145 - doom-lsp 确认
// Tip 0: 注意读取不同变量的顺序！
// 我们先更新 version 再读取 state，先读取 state 再读取 version。
// 但编译器可能重排指令顺序（见 ARM 架构的 Dependency Definition 规范）。
// 因此必须使用同步原语（内存屏障）来保证顺序。
const bool is_committed = iter->is_committed();
const bool is_aborted = iter->is_aborted();
const bool is_elr = iter->is_elr();
const bool is_delayed_cleanout = iter->is_delayed_cleanout();
const SCN &scn = iter->get_scn();
const bool is_incomplete = iter->is_incomplete();
// only read elr committed data if reader has created TxCtx
const bool read_elr = OB_NOT_NULL(ctx_->tx_ctx_) && is_elr;
```

**注释中明确指出**：这里的变量读取顺序是**故意设计**的，必须遵守"先 state 后 version"的原则以避免 ARM 上的编译期指令重排。`is_committed()` 等函数内部使用 `ATOMIC_LOAD`，但编译器仍可能将两次独立的 `ATOMIC_LOAD` 重排。

### 3.2 Opt0：跳过不完整的节点

```c
// ob_mvcc_iterator.cpp:147-156
if (is_incomplete) {
  // mvcc_write_ 成功后，SSTable 检查仍可能失败，导致数据处于不完整状态
  // 使用 INCOMPLETE 状态防止此类数据被错误可见
  iter = iter->prev_;
  // Tip: 不完整节点的 trans_version 尚未填充，不可用于可见性判断
}
```

### 3.3 Opt1 + Opt2：数据状态已确定，无需 cleanout

```c
// ob_mvcc_iterator.cpp:158-182
else if ((is_committed || is_aborted || (read_elr && !is_delayed_cleanout))
    // Opt2: 数据未决，但不需要 cleanout（关键条件）
    || (!is_delayed_cleanout
        // transfer 场景：源端和目标端的数据与 tx_table 独立
        && (!ctx_->get_tx_table_guards().src_tx_table_guard_.is_valid() ||
            (memtable_ls_id_.is_valid() &&
             ctx_->get_tx_table_guards().src_tx_table_guard_.get_tx_table()->
             get_ls_id() != memtable_ls_id_))
        && (// Opt2.1: snapshot 读取自己写入的数据
            data_tx_id == snapshot_tx_id ||
            // Opt2.2: read_latest 且数据属于当前读取事务
            (read_latest && data_tx_id == reader_tx_id))))
```

**满足 Opt2 的条件**：
1. `is_delayed_cleanout == false`（不需要 cleanout）
2. 且处于非 transfer-in 场景，或正在读 dest 的 memtable
3. 且数据的事务 ID 等于快照的 tx_id 或读者自己的 tx_id

### 3.4 Case 2：数据已提交

```c
// ob_mvcc_iterator.cpp:165-180
if (is_committed || read_elr) {
  if (read_uncommitted) {
    version_iter_ = iter;  // 需要未提交版本，直接读
  } else if (ctx_->get_snapshot_version() >= iter->trans_version_.atomic_load()) {
    // Case 2.1: snapshot_version >= 节点提交版本 → 可见
    version_iter_ = iter;
  } else {
    // Case 2.2: 提交版本 > snapshot_version → 不可见，跳到更旧的版本
    iter = iter->prev_;
  }
}
```

### 3.5 Case 3：数据已中止

```c
// ob_mvcc_iterator.cpp:181-184
else if (is_aborted) {
  // 已中止的版本永远不可见，直接跳过
  iter = iter->prev_;
}
```

### 3.6 Case 4：数据属于当前执行中的事务

```c
// ob_mvcc_iterator.cpp:185-212
else {
  // 数据正在执行中（未提交、未中止）
  if (read_uncommitted) {
    version_iter_ = iter;  // 读未提交数据
  } else if (read_latest && data_tx_id == reader_tx_id) {
    // 当前事务自己的数据，且要求读最新（如检查存在性）
    version_iter_ = iter;
  } else if (snapshot_tx_id == data_tx_id) {
    if (iter->get_seq_no() <= snapshot_seq_no) {
      // Case 4.2.1: 数据的序列号 <= 读取事务的序列号 → 可见
      // （防止 SQL 层重试导致的重放问题，即 Halloween 问题）
      version_iter_ = iter;
    } else {
      // Case 4.2.2: 序列号更大，但不读最新 → 不可见
      iter = iter->prev_;
    }
  }
}
```

**Halloween 问题**：当一个 UPDATE 语句在执行过程中重新扫描同一条记录时，会把刚才更新的行再次更新。用 `snapshot_seq_no` 做上界可以防止这种事。

### 3.7 Case 5：数据未决且需要 cleanout

```c
// ob_mvcc_iterator.cpp:214-238 - doom-lsp 确认
else {
  // 需要通过 ObTxTable 查询事务的最终状态
  ObLockForReadArg lock_for_read_arg(*ctx_,
                                     data_tx_id,
                                     iter->get_seq_no(),
                                     read_latest,
                                     read_uncommitted,
                                     scn);

  bool can_read = false;
  SCN data_version;
  // ObCleanoutTxNodeOperation: 将查询到的事务状态写入 ObMvccTransNode
  ObCleanoutTxNodeOperation clean_tx_node_op(*value_, *iter, true);
  ObReCheckTxNodeForLockForReadOperation recheck_tx_node_op(*iter, can_read, data_version);
  // lock_for_read: 通过 tx_table 查询 data_tx_id 的提交/中止状态
  if (OB_FAIL(ctx_->get_tx_table_guards().lock_for_read(lock_for_read_arg,
                                                        can_read,
                                                        data_version,
                                                        clean_tx_node_op,
                                                        recheck_tx_node_op))) {
    // 查询失败
  } else if (can_read) {
    // Case 5.1: 通过 tx_table 确认事务已提交，且版本 <= snapshot_version
    // 轮询直到节点状态被真正写入（cleanout 完成）
    while (OB_SUCC(ret)
           && !ctx_->is_standby_read_
           && !read_uncommitted
           && is_effective_trans_version(data_version)
           && !(iter->is_committed() || iter->is_aborted() || iter->is_elr())) {
      // try_cleanout_tx_node_: 再次查询并写入节点状态
      if (OB_FAIL(try_cleanout_tx_node_(iter))) { ... }
      ob_usleep(10);  // 10us 轮询间隔
    }
    version_iter_ = iter;
  } else {
    // Case 5.2: tx_table 查询结果显示不可见（事务回滚）
    iter = iter->prev_;
  }
}
```

---

## 4. `try_cleanout_tx_node_` —— 延迟清理

```c
// ob_mvcc_iterator.cpp:299-313 - doom-lsp 确认
int ObMvccValueIterator::try_cleanout_tx_node_(ObMvccTransNode *tnode)
{
  int ret = OB_SUCCESS;
  ObTxTableGuards &tx_table_guards = ctx_->get_tx_table_guards();
  if (!(tnode->is_committed() || tnode->is_aborted())
      && tnode->is_delayed_cleanout()
      && OB_FAIL(tx_table_guards.cleanout_tx_node(tnode->tx_id_,
                                            *value_,
                                            *tnode,
                                            true /*need_row_latch*/))) {
    TRANS_LOG(WARN, "cleanout tx state failed", K(ret), K(*value_), K(*tnode));
  }
  return ret;
}
```

**延迟清理的触发条件**：
1. 节点 `is_delayed_cleanout() == true`（设置了 `F_DELAYED_CLEANOUT` 标志）
2. 节点尚未 `is_committed()` 或 `is_aborted()`（状态未决）

**cleanout 的作用**：通过 `ObTxTable` 查询事务 `tnode->tx_id_` 的实际状态（已提交/已中止），并将结果原子地写入 `tnode->flag_` 和 `tnode->trans_version_`。之后 `lock_for_read_inner_` 再次进入时就会走 Opt1 分支直接判断。

---

## 5. `ObTxTableGuards` —— 事务状态查询

### 5.1 `ObTxTableGuards` 的双 guard 设计

```c
// ob_tx_table_guards.h:143-170 - doom-lsp 确认
class ObTxTableGuards
{
public:
  storage::ObTxTableGuard tx_table_guard_;  // 目标端的 tx_table
  // 当 DML 在 transfer 过程中执行时，src_tx_table_guard_ 和 src_ls_handle_ 有效
  storage::ObTxTableGuard src_tx_table_guard_;
  storage::ObLSHandle src_ls_handle_;
  ObLSID get_ls_id() const;  // 获取 LS ID

  int lock_for_read(const ObLockForReadArg &lock_for_read_arg,
                    bool &can_read,
                    share::SCN &trans_version,
                    ObCleanoutOp &cleanout_op,
                    ObReCheckOp &recheck_op);

  int cleanout_tx_node(const ObTransID &tx_id,
                       memtable::ObMvccRow &value,
                       memtable::ObMvccTransNode &tnode,
                       const bool need_row_latch);
};
```

### 5.2 `lock_for_read` 的核心逻辑

```c
// ob_tx_table.cpp:277 - doom-lsp 调用位置
// ObTxTable::lock_for_read(arg, can_read, trans_version, cleanout_op, recheck_op)
//
// 输入：data_trans_id（数据所在事务的 ID）
// 输出：can_read（是否可以读取）
//       trans_version（数据的提交版本）
//
// cleanout_op: 将 tx_table 查询到的状态写入 ObMvccTransNode
// recheck_op: 再次检查 can_read（用于验证写入后的状态是否仍然有效）
```

---

## 6. `ObMvccRow::check_row_locked` —— 锁冲突检测

```c
// ob_mvcc_row.h:370-380 - doom-lsp 确认
int ObMvccRow::check_row_locked(ObMvccAccessCtx &ctx,
                                storage::ObStoreRowLockState &lock_state);
```

这个函数用于检测某行是否被其他事务锁定，与 `lock_for_read_` 不同：`lock_for_read_` 解决"读哪个版本"，`check_row_locked` 解决"行是否被锁、谁锁的、锁的什么操作"。

---

## 7. 可见性判断完整数据流图

```
ObMvccValueIterator::init()
  │
  └─→ lock_for_read_(query_flag)
         │
         ├─ iter = value_->get_list_head()  ← 最新版本
         │
         └─ while (iter != NULL && version_iter_ == NULL)
               │
               └─→ lock_for_read_inner_(flag, iter)
                     │
                     ├─ 读取 is_committed, is_aborted, is_elr,
                     │   is_delayed_cleanout, scn, is_incomplete
                     │   ★ 重要：读取顺序必须遵守 "state 前、version 后"
                     │
                     ├─ Opt0: is_incomplete == true → iter = iter->prev_
                     │
                     ├─ Opt1+Opt2: 状态已确定，无需 cleanout
                     │    ├─ Case 2: is_committed
                     │    │    ├─ read_uncommitted → version_iter_ = iter
                     │    │    ├─ snapshot_version >= trans_version → version_iter_ = iter
                     │    │    └─ snapshot_version < trans_version → iter = iter->prev_
                     │    ├─ Case 3: is_aborted → iter = iter->prev_
                     │    └─ Case 4: data_tx_id == reader/snapshot_tx_id
                     │         ├─ seq_no <= snapshot_seq_no → version_iter_ = iter
                     │         └─ seq_no > snapshot_seq_no → iter = iter->prev_
                     │
                     └─ Case 5: 需要 cleanout
                          ├─ lock_for_read_arg = ObLockForReadArg(...)
                          ├─ tx_table.lock_for_read(arg, can_read, data_version,
                          │                        cleanout_op, recheck_op)
                          │    │
                          │    ├─ cleanout_op: 查询 tx_id 状态 → 写入 ObMvccTransNode
                          │    └─ can_read = (data 已提交 && data_version <= snapshot)
                          │
                          ├─ can_read == true
                          │    └─ while (!is_committed/aborted/elr) {
                          │           try_cleanout_tx_node_(iter)  // 轮询 cleanout
                          │           ob_usleep(10)
                          │       }
                          │       version_iter_ = iter
                          │
                          └─ can_read == false
                               └─ iter = iter->prev_
```

---

## 8. `ObTxSnapshot::elr_` 与 Early Lock Release 读取

```c
// ob_trans_define_v4.h:278 - doom-lsp 确认
class ObTxSnapshot
{
  share::SCN    version_;       // 快照版本
  ObTransID    tx_id_;         // 快照创建时正在运行的事务 ID
  ObTxSEQ      scn_;           // 快照 SCN（用于 sequence 检查）
  bool         elr_;           // 是否允许读取 ELR 版本 ★
  bool         force_strongly_read_;  // 是否强制强一致性读
};
```

**`elr_` 字段**：当读取请求的快照允许读取 ELR 版本时（`elr_ == true`），即使 `iter->is_elr()` 为 true（即事务处于 ELR 状态，提交日志已提议但未最终同步），仍可以将该版本视为已提交。这是**弱一致性读取**的优化：Leader 收到 Paxos 提议成功后即可提前释放锁，允许其他事务读取"将要提交"的数据。

---

## 9. transfer 场景下的 `src_tx_table_guard_`

**transfer 场景的特殊性**：当 DML 在数据迁移过程中执行时，源端和目标端的数据与 tx_table 是**独立的**。

```c
// lock_for_read_inner_ @ ob_mvcc_iterator.cpp:158
&& (!ctx_->get_tx_table_guards().src_tx_table_guard_.is_valid() ||
    (memtable_ls_id_.is_valid() &&
     ctx_->get_tx_table_guards().src_tx_table_guard_.get_tx_table()->
     get_ls_id() != memtable_ls_id_))
```

这段逻辑说明：
- 如果 `src_tx_table_guard_` 无效（不在 transfer 中），使用正常的 tx_table
- 如果 `src_tx_table_guard_` 有效，但当前读取的是 dest 的 memtable（`memtable_ls_id_ != src_ls_id`），也使用 dest 的 tx_table
- **否则**（在 transfer 过程中读取 src 的 memtable），必须使用 `src_tx_table_guard_`

**备机读的额外检查**（ob_mvcc_iterator.cpp:271-277）：

```c
if (1 == counter % 10000
    && !MTL_TENANT_ROLE_CACHE_IS_PRIMARY_OR_INVALID()) {
  ctx_->is_standby_read_ = true;
  // 在 transfer 过程中备机可能看到"数据已更新但无法 cleanout"的场景
  // 设置 is_standby_read_ 标志让上层做额外处理
}
```

---

## 10. 源码文件索引

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/storage/memtable/mvcc/ob_mvcc_iterator.cpp` | `ObMvccValueIterator::init()` | 28 |
| `src/storage/memtable/mvcc/ob_mvcc_iterator.cpp` | `ObMvccValueIterator::lock_for_read_()` | 68 |
| `src/storage/memtable/mvcc/ob_mvcc_iterator.cpp` | `ObMvccValueIterator::lock_for_read_inner_()` | 104 |
| `src/storage/memtable/mvcc/ob_mvcc_iterator.cpp` | `ObMvccValueIterator::try_cleanout_tx_node_()` | 299 |
| `src/storage/memtable/mvcc/ob_mvcc_iterator.cpp` | `ObMvccValueIterator::move_to_next_node_()` | 355 |
| `src/storage/memtable/mvcc/ob_mvcc_iterator.cpp` | `ObMvccValueIterator::check_row_locked()` | 365 |
| `src/storage/memtable/mvcc/ob_mvcc_iterator.h` | `struct ObMvccValueIterator` | 94 |
| `src/storage/memtable/mvcc/ob_mvcc_iterator.h` | `struct ObMvccRowIterator` | 166 |
| `src/storage/memtable/mvcc/ob_mvcc_iterator.h` | `struct ObMvccScanRange` | 34 |
| `src/storage/ob_i_store.h` | `struct ObStoreRowLockState` | 225 |
| `src/storage/tx/ob_trans_define.h` | `struct ObLockForReadArg` | 232 |
| `src/storage/tx_table/ob_tx_table_guards.h` | `class ObTxTableGuards` | 143 |
| `src/storage/tx_table/ob_tx_table_guards.h` | `ObTxTableGuards::lock_for_read()` | 113 |
| `src/storage/tx_table/ob_tx_table_guards.h` | `ObTxTableGuards::cleanout_tx_node()` | 131 |
| `src/storage/tx_table/ob_tx_table.cpp` | `ObTxTable::lock_for_read()` | 277 |

---

## 11. 与 MySQL InnoDB 的对比

| 维度 | MySQL InnoDB | OceanBase |
|------|-------------|-----------|
| 可见性判断入口 | `row_search_mvcc()` | `ObMvccValueIterator::lock_for_read_()` |
| 状态查询 | 直接读取 `trx_id` 和 `roll_ptr` | 通过 `ObTxTable`（分布式 tx_table）|
| 未决节点处理 | 读取并等待 | `try_cleanout_tx_node_` + `ObTxTable` |
| transfer 场景 | N/A（单副本）| `src_tx_table_guard_` + `dest_ls_id` 判断 |
| ELR 支持 | 否 | `ObTxSnapshot::elr_` + `is_elr()` 检查 |
| 弱读支持 | `isolation_level=READ_COMMITTED` | `is_weak_read()` + `elr_` 字段 |

**核心区别**：InnoDB 的 MVCC 依赖行内元数据（`trx_id` + `roll_ptr`）直接判断，OceanBase 在分布式场景下需要额外的 `ObTxTable` 作为权威状态来源，因为单副本上的行数据可能尚未反映全局事务的最终结果。

---

## 12. 下篇预告

- **03-mvcc-write-conflict**：写写冲突检测、`check_row_locked`、锁等待与死锁检测
- **04-mvcc-callback**：事务提交回调链与 Paxos 日志同步的协同
- **05-mvcc-compact**：版本链的 compaction/GC 机制
- **06-memtable-freezer**：Memtable 冻结与 SSTable 持久化
- **07-ls-logstream**：LogStream 与分区副本管理
- **08-ob-sstable**：SSTable 存储格式与块编码
- **09-ob-sql-executor**：SQL 执行器与存储层的交互
- **10-ob-transaction**：分布式两阶段提交与事务管理器

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 代码仓库：OceanBase CE*