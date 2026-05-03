# 04 — 事务提交回调链与 Paxos 日志同步的协同

## 概述

OceanBase 的分布式事务提交机制中，一个关键设计问题是：**memtable 中的多版本数据（`ObMvccTransNode`）何时、如何感知到事务的最终决策（commit/abort），以及如何与底层的 Paxos 日志复制协同**。

答案在于**事务提交回调链**（Transaction Callback Chain）——一组以 `ObITransCallback` 为基类的回调对象，它们构成双向链表，贯穿了从 `mvcc_write` 写数据、到 Paxos 日志生成/提交/同步、再到最终事务决策的完整生命周期。

本文从源码出发，深度分析回调链的设计与实现。

---

## 1. `ObITransCallback` — 回调链的基石

**文件**: `src/storage/memtable/mvcc/ob_mvcc.h`  
**行号**: `L27-L130`（经 doom-lsp 确认）

`ObITransCallback` 是 OceanBase memtable MVCC 中所有回调对象的抽象基类。它不是普通的"回调接口"——它是一个**有状态的、可链式组织的生命期管理节点**。

### 1.1 核心字段

```cpp
// ob_mvcc.h L66-L86 (经 doom-lsp 确认)
class ObITransCallback {
  struct {
    bool need_submit_log_ : 1;  // L110: 是否需要落 Paxos 日志
  };
  share::SCN scn_;              // L112: Paxos SCN (max_scn 表示未提交)
  int64_t epoch_;               // L113: 写 epoch，用于版本控制
  ObITransCallback *prev_;      // L116: 指向前一个(更旧的)回调
  ObITransCallback *next_;      // L117: 指向后一个(更新的)回调
  ObTxCallbackHashHolderLinker hash_holder_linker_;  // L118: 哈希索引链接
};
```

关键语义：

- **`scn_`**：初始值为 `share::SCN::max_scn()`，表示"日志尚未提交"。一旦 `log_submitted_cb()` 被调用，`scn_` 被设置为 Paxos 分配的 SCN，此时 `is_log_submitted()` 返回 true（`!scn_.is_max()`，L92）。
- **`prev_` / `next_`**：构成**循环双向链表**，以哨兵节点为头。`prev_` 指向**更旧的**回调，`next_` 指向**更新的**回调（与 ObMvccTransNode 的方向一致）。
- **`need_submit_log_`**：位域标志，表示此回调是否需要写入 Paxos 日志。对于 replay 路径，该标志被清除。

### 1.2 生命周期回调点

`ObITransCallback` 定义了 6 个核心虚函数，覆盖了事务回调的完整生命周期：

| 虚函数 | 触发时机 | 行号范围 (ob_mvcc.h) |
|---|---|---|
| `before_append()` | 回调被加入链表前 | L67 |
| `log_submitted()` | 日志已提交到 Paxos | L68 |
| `log_sync_fail()` | 日志同步失败 | L69 |
| `trans_commit()` | 事务最终提交 | L78-L83 |
| `trans_abort()` | 事务最终回滚 | L85-L90 |
| `elr_trans_preparing()` / `elr_trans_revoke()` | ELR 预提交/撤销 | L96-L100 |

这些虚函数由**非虚包装方法** `before_append_cb()`、`log_submitted_cb()`、`log_sync_fail_cb()` 间接调用，包裹层负责状态管理（如设置 `scn_`、清除 `need_submit_log_` 标记）。

---

## 2. `ObMvccRowCallback` — 最核心的子类

**文件**: `src/storage/memtable/mvcc/ob_mvcc_trans_ctx.h`  
**行号**: `L426-L536`（经 doom-lsp 确认）

`ObMvccRowCallback` 是最重要的回调实现。它将一个 `ObMvccTransNode`（行级多版本数据节点）与 `ObTxCallbackList` 的回调管理连接起来。

### 2.1 与 `ObMvccTransNode` 的关联

```cpp
// ob_mvcc_trans_ctx.h L429, L432, L446-L456, L519-L534
class ObMvccRowCallback final : public ObITransCallback {
  ObIMvccCtx &ctx_;           // 事务上下文
  ObMemtableKey key_;         // 行键
  ObMvccRow &value_;          // 所属的 ObMvccRow
  ObMvccTransNode *tnode_;    // 指向对应的多版本数据节点
  ObMemtable *memtable_;      // 所在的 memtable
  // 位域标志
  bool is_link_ : 1;          // tnode_ 是否已插入 ObMvccRow
  bool not_calc_checksum_ : 1;
  bool is_non_unique_local_index_cb_ : 1;
  transaction::ObTxSEQ seq_no_;  // 写操作的序列号
  int64_t column_cnt_;
  uint32_t freeze_clock_;
};
```

`tnode_` 指针是桥接的关键：回调链管理的不是数据本身，而是**指向数据的指针**。数据本身（`ObMvccTransNode`）通过 ObMvccRow 的 `insert_trans_node()` 被链接到行的多版本链上，而回调通过 `callback_list` 被链接到事务的回调链上。两者通过 `ObMvccRowCallback` 串联。

### 2.2 `set()` 方法

```cpp
// ob_mvcc_trans_ctx.h L435-L456 (经 doom-lsp 确认)
void set(const ObMemtableKey *key,
         ObMvccTransNode *node,
         const int64_t data_size,
         const ObRowData &old_row,
         const transaction::ObTxSEQ seq_no,
         const int64_t column_cnt,
         const bool is_non_unique_local_index_cb)
{
  key_.encode(*key);
  tnode_ = node;
  data_size_ = data_size;
  old_row_ = old_row;
  seq_no_ = seq_no;
  if (tnode_) {
    tnode_->set_seq_no(seq_no_);  // 确保节点内 seq_no 一致
  }
  column_cnt_ = column_cnt;
  is_non_unique_local_index_cb_ = is_non_unique_local_index_cb;
}
```

此方法在 `mvcc_write` 后、回调被注册到链表前调用，建立 `ObMvccRowCallback` 与 `ObMvccTransNode` 的绑定关系。

---

## 3. `ObTxCallbackList` — 回调链表的完整生命周期

**文件**: `src/storage/memtable/mvcc/ob_tx_callback_list.h` / `.cpp`

`ObTxCallbackList` 是管理回调链的核心容器。它是一个**循环双向链表**，以哨兵节点 `head_` 为锚点。

### 3.1 数据结构概览

```cpp
// ob_tx_callback_list.h L138-L174 (核心字段, 经 doom-lsp 确认)
class ObTxCallbackList {
  ObITransCallback head_;             // 哨兵节点
  ObITransCallback *log_cursor_;      // 指向下一个待写日志的回调
  int64_t length_;                    // 链表实时长度

  // 总计数器
  int64_t appended_;   // 总共注册的回调数
  int64_t logged_;     // 已写入日志的回调数
  int64_t synced_;     // 已 Paxos 同步的回调数
  int64_t removed_;    // 已移除的回调数
  int64_t unlog_removed_;  // 未写日志就被移除的回调数
  int64_t branch_removed_;

  int64_t data_size_;                    // 总数据大小
  int64_t logged_data_size_;             // 已记日志的数据大小
  int64_t unlogged_and_rollbacked_data_size_;

  share::SCN sync_scn_;                 // 已同步的最大 SCN

  // 多版本 checksum 相关
  TxChecksum batch_checksum_;
  share::SCN checksum_scn_;
  uint64_t checksum_;

  // 4 个 latch，保证并发安全
  mutable common::ObByteLock append_latch_;       // 串行化 append 操作
  mutable common::ObByteLock log_latch_;           // 串行化 fill/flush log
  mutable common::ObByteLock log_submitted_pending_latch_;  // 阻止 log_sync 在 log_submitted 之前执行
  mutable common::ObByteLock iter_synced_latch_;  // 串行化对 synced 回调的操作
};
```

### 3.2 四个计数器的增量不变式

`appended_` ≥ `logged_` ≥ `synced_` ≥ `removed_`，且 `appended_ = logged_ + unlog_removed_`。这些计数器在 `reset()` 中有校验断言（`ob_tx_callback_list.cpp L32-L40`）：

```cpp
// ob_tx_callback_list.cpp L32-L40 (经 doom-lsp 确认)
if (length_ + removed_ != appended_) {
  TRANS_LOG_RET(ERROR, OB_ERR_UNEXPECTED, "BUG:list state insanity", KPC(this));
}
if (length_ + removed_ != logged_ + unlog_removed_) {
  TRANS_LOG_RET(ERROR, OB_ERR_UNEXPECTED, "BUG:list state insanity", KPC(this));
}
```

### 3.3 `append_callback` — 写操作时注册回调

**行号**: `ob_tx_callback_list.cpp L60-L140`

两参数版本（单个回调）和四参数版本（批量回调，用于跨语句合并）都遵循相同模式：

```
1. LockGuard(LOCK_APPEND)          — 串行化 append
2. check_freeze_clock_order_()     — 验证 freeze 时钟顺序
3. before_append_cb(for_replay)    — 调用子类准备逻辑（如 inc_unsubmitted_cnt）
4. append_pos->append(callback)    — 将回调链入 list tail
5. ++appended_, ++length_          — 更新计数器
6. 如果 for_replay: ++logged_, ++synced_  — replay 路径跳过日志
```

append 操作的原子性保证（注释 L58、L143）：

```
NB: 一旦回调成功追加到 callback_list，它可能已经被日志化并在之后释放，
因此 append 成功后不得再访问回调；append 失败后才可以安全访问。
```

### 3.4 `concat_callbacks` — DML 中合并多个回调

**行号**: `ob_tx_callback_list.cpp L224-L251`

当一条 SQL 语句有多个 DML 操作（如 `INSERT INTO t VALUES (1),(2),(3)`），每个 DML 操作会生成独立的 `ObMvccRowCallback` 并追加到不同的子 callback list 中。在语句提交时，这些子 list 通过 `concat_callbacks` 合并到主 list：

```cpp
// ob_tx_callback_list.cpp L224-L251 (经 doom-lsp 确认)
int64_t ObTxCallbackList::concat_callbacks(ObTxCallbackList &that)
{
  LockGuard this_guard(*this, LOCK_MODE::LOCK_ALL);
  LockGuard that_guard(that, LOCK_MODE::LOCK_ALL);
  // 将 that 的链表直接拼接到 this 的 tail
  that_head->set_prev(get_tail());
  that_tail->set_next(&head_);
  get_tail()->set_next(that_head);
  head_.set_prev(that_tail);
  // 更新计数器，fake removal 使 that.reset() 可通过断言
}
```

### 3.5 `fill_log` — 将回调数据填充到 Paxos 日志

**行号**: `ob_tx_callback_list.cpp L603-L631`

```cpp
int ObTxCallbackList::fill_log(ObITransCallback* log_cursor,
                                ObTxFillRedoCtx &ctx,
                                ObITxFillRedoFunctor &functor)
{
  if (log_cursor == &head_) {
    // 没有待写日志的回调
  } else {
    ret = callback_(functor, log_cursor, get_guard(), false, lock_state);
    ctx.helper_->max_seq_no_ = MAX(functor.get_max_seq_no(), ctx.helper_->max_seq_no_);
    ctx.helper_->data_size_ += functor.get_data_size();
    ctx.callback_scope_->data_size_ += functor.get_data_size();
  }
}
```

`fill_log` 从 `log_cursor_` 开始，遍历到链表头，收集所有尚未写日志的回调数据。遍历过程中，`ObITxFillRedoFunctor` 会提取每个回调的 redo 数据并写入 Paxos 日志缓冲区。

关键并发语义：`fill_log` 与 `remove*` 操作在事务上下文的 FLUSH_REDO 锁下互斥。

### 3.6 `submit_log_succ` — 日志提交成功

**行号**: `ob_tx_callback_list.cpp L634-L653`

```
1. 移动 log_cursor_ 到刚提交的批次的末尾
2. logged_ += callbacks.cnt_
3. clear_prepared_log_submitted()
```

当日志被成功提交到 Paxos（即 leader 生成了 Paxos 日志条目但尚未同步到多数派），回调的 `log_submitted()` 虚函数会被逐一遍历调用。对 `ObMvccRowCallback` 来说，这会在 tnode 上设置 `scn_`（`tnode_->fill_scn(scn)`）。

### 3.7 `sync_log_succ` — 日志同步成功（多数派落盘）

**行号**: `ob_tx_callback_list.cpp L656-L671`

```cpp
int ObTxCallbackList::sync_log_succ(const share::SCN scn, int64_t sync_cnt)
{
  ObSmallSpinLockGuard log_submitted_pending_guard(log_submitted_pending_latch_);
  sync_scn_.atomic_store(scn);
  synced_ += sync_cnt;
  return ret;
}
```

这是回调生命周期中的关键转折点——`sync_scn_` 被推进到该批次日志的 SCN，表示此 SCN 之前的所有回调对应的日志已经成功同步到 Paxos 多数派。

**注意**：`sync_log_succ` 与 `submit_log_succ` 是**并发**的！`log_submitted_pending_latch_` 保证 `sync_log_succ` 不会在 `log_submitted_cb` 的回调被调用完之前推进 `sync_scn_`，从而防止 `tx_commit` 在日志尚未完全提交时就回调查看到错误的 `sync_scn_`。

### 3.8 `tx_commit` / `tx_abort` — 事务最终态的回调

```cpp
// ob_tx_callback_list.cpp L781-L818 (经 doom-lsp 确认)
int ObTxCallbackList::tx_commit()
{
  ObTxEndFunctor functor(true/*is_commit*/);
  LockGuard guard(*this, LOCK_MODE::LOCK_ALL);
  if (OB_FAIL(callback_(functor, guard.state_))) { ... }
  // commit 后链表必须为空，否则是 bug
}

int ObTxCallbackList::tx_abort()
{
  ObTxEndFunctor functor(false/*is_commit*/);
  LockGuard guard(*this, LOCK_MODE::LOCK_ALL);
  if (OB_FAIL(callback_(functor, guard.state_))) { ... }
}
```

`ObTxEndFunctor`（`ob_tx_callback_functor.h L388`）根据 `is_commit` 参数调用回调的 `trans_commit()` 或 `trans_abort()`：

- **`trans_commit()`**: commit 前会检查 `callback->get_scn().is_max()`——如果回调的 scn_ 尚未被设置（即日志未提交过），这是一个不变量违规，因为不可能在日志未提交时执行 commit。
- commit 成功后将 `need_remove_callback_` 设为 true，触发回调移除流程（在 `callback_` 的删除循环中执行）。

对 `ObMvccRowCallback` 来说，`trans_commit()`（`ob_mvcc_trans_ctx.cpp L1894-L2025`）执行以下操作：

1. `link_and_get_next_node(next)` — 确保 tnode 被链入 ObMvccRow 的多版本链
2. `value_.trans_commit(commit_version, *tnode_)` — 更新 ObMvccRow 的行元数据（max_trans_version 等）
3. `commit_trans_node_()` — 调用 `tnode_->trans_commit()` 设置 committed 标志和 commit_version
4. `wakeup_row_waiter_if_need_()` — 唤醒等待行锁的其他事务
5. 如果节点是 lock-only（DF_LOCK），直接解链 tnode
6. 检测是否需要触发行压缩 (row_compact)

### 3.9 `sync_log_fail` — 日志同步失败处理

**行号**: `ob_tx_callback_list.cpp L673-L695`

```cpp
int ObTxCallbackList::sync_log_fail(const ObCallbackScope &callbacks,
                                     const share::SCN scn,
                                     int64_t &removed_cnt)
{
  ObSmallSpinLockGuard log_submitted_pending_guard(log_submitted_pending_latch_);
  ObSyncLogFailFunctor functor;
  functor.max_committed_scn_ = scn;
  LockGuard guard(*this, LOCK_MODE::LOCK_ALL);
  // 遍历并移除所有本次失败的 callbacks
  callback_(functor, callbacks, guard.state_);
}
```

`ObMvccRowCallback::log_sync_fail()`（`ob_mvcc_trans_ctx.cpp L2180-L2194`）执行：
1. 从 ObMvccRow 上解链 tnode
2. 更新 memtable 的 max_end_scn

---

## 4. `prev_` / `next_` 方向确认

经过 doom-lsp 精确验证，`ObITransCallback` 的链表方向与 `ObMvccTransNode` 一致：

- **`prev_`**: 指向**更旧**的回调（较早注册的）
- **`next_`**: 指向**更新**的回调（较晚注册的）

在 `ObITransCallback::append()`（`ob_mvcc_trans_ctx.cpp L128-L148`）中确认：

```cpp
void ObITransCallback::append(ObITransCallback *node)
{
  ObITransCallback *next = this->get_next();
  node->set_prev(this);    // node.prev → this (旧的)
  node->set_next(next);    // node.next → next (更旧的 next，即更旧的后面一个)
  this->set_next(node);    // this.next → node (新的)
  next->set_prev(node);
}
```

在 `ObTxCallbackList` 中，链表以哨兵 `head_` 为锚点，循环结构：
- **正向遍历**：`head_.next → head_.next → ... → head_`（从旧到新）
- `get_tail()` = `head_.get_prev()`（最新的回调）
- `log_cursor_` 从旧到新推进

---

## 5. 状态机流转与数据流图

### 5.1 状态机描述

回调的生命周期可表示为 5 个状态，由 4 个维度的计数器体现：

```
  回调已分配 (allocated)
       │
       ▼  append_callback()
  ① APPENDED (appended_++)
       │
       ▼  fill_log() → Paxos 生成日志
  ② LOGGED (logged_++) — 回调中 scn_ 已设置
       │
       ├──▶ ③ SYNCED (synced_++, sync_scn_ 推进) — Paxos 多数派已确认
       │        │
       │        ├──▶ ④ COMMITTED  (trans_commit, removed_++)
       │        │
       │        ├──▶ ④ ABORTED    (trans_abort, removed_++)
       │        │
       │        └──▶ ④ CHECKPOINTED (checkpoint_callback, removed_++)
       │
       └──▶ ③ SYNC_FAIL  (sync_log_fail → log_sync_fail → removed_++)
       
   ② → ③' UNLOGGED_REMOVED (unlog_removed_++)
       用于 clean_unlog_callbacks / rollback_to
```

### 5.2 ASCII 数据流图

```
                        mvcc_write()
                             │
                             ▼
            ┌─────────────────────────────────┐
            │   ObMvccRowCallback::set()      │
            │   ┌───────┐                      │
            │   │ tnode_│───→ ObMvccTransNode  │
            │   └───────┘                      │
            └─────────────────────────────────┘
                             │
              append_callback(head_, tail, length)
                             │
                             ▼  append_pos->append(callback)
            ┌─────────────────────────────────────┐
            │  ObTxCallbackList                   │
            │                                     │
            │  head_(sentinel)                    │
            │   │                                 │
            │   ├─ prev_ ← ... ← cb_oldest        │
            │   │                                 │
            │   └─ next_ → ... → cb_newest        │
            │                                     │
            │  log_cursor_  → 下一个待写日志的点   │
            │                                     │
            │  sync_scn_    → 已同步的最大 SCN      │
            │                                     │
            │  counters: appended_/logged_        │
            │            /synced_/removed_        │
            │                                     │
            │  latches: append_latch_              │
            │           log_latch_                │
            │           log_submitted_pending_     │
            │           iter_synced_latch_         │
            └─────────────────────────────────────┘
                             │
              ╔══════════════╩══════════════════╗
              ║           fill_log()            ║
              ║     (TxCtx FLUSH_REDO lock)     ║
              ║                                 ║
              ║  log_cursor_─→cb1─→cb2─→...    ║
              ║       │              │          ║
              ║       ▼              ▼          ║
              ║  RedoDataNode    RedoDataNode    ║
              ║       │              │          ║
              ║       └──────┬───────┘          ║
              ║              ▼                  ║
              ║         Paxos Log Batch          ║
              ╚══════════════╤══════════════════╝
                             │
              ╔══════════════╩══════════════════╗
              ║       submit_log_succ()         ║
              ║  (Paxos 生成 Propose，未多数派)  ║
              ║                                 ║
              ║  1. 设置回掉 scn_                ║
              ║  2. logged_ += cnt               ║
              ║  3. 移动 log_cursor              ║
              ╚══════════════╤══════════════════╝
                             │
              ╔══════════════╩══════════════════╗
              ║        sync_log_succ()          ║
              ║  (Paxos 多数派确认)              ║
              ║                                 ║
              ║  sync_scn_ = scn               ║
              ║  synced_ += sync_cnt            ║
              ╚══════════════╤══════════════════╝
                             │
              ╔══════════════╩══════════════════╗
              ║         tx_commit()             ║
              ║  (事务决策为提交)                ║
              ║                                 ║
              ║  callback->trans_commit()        ║
              ║    ├─ 设置 tnode committed       ║
              ║    ├─ 填充 commit_version        ║
              ║    ├─ 更新 ObMvccRow 元数据      ║
              ║    ├─ 唤醒行锁等待者             ║
              ║    └─ 触发 row_compact           ║
              ║                                 ║
              ║  callback->del()                 ║
              ║    ├─ removed_++                ║
              ║    └─ 释放回调内存               ║
              ╚══════════════╤══════════════════╝
                             │
                             ▼
                    回调生命周期结束
```

---

## 6. 四把 Latch 的并发控制策略

`ObTxCallbackList` 中有 4 把 latch，各自保护不同的并发域：

| Latch | 保护的内容 | 获取方 |
|---|---|---|
| `append_latch_` | append 操作 + 对 tail 的并发访问 | writer 线程、`submit_log_succ` 在 next 为 tail 时 |
| `log_latch_` | fill_log 与 flush_log 的序列化 | 日志生成器 |
| `log_submitted_pending_latch_` | sync_log_succ 与 submit_log_succ 的偏序关系 | 两者都需获取 |
| `iter_synced_latch_` | 对已同步回调的操作（fast_commit、remove_memtable 等） | 回收/移除线程 |

**`log_submitted_pending_latch_`** 的设计尤为精妙：

```
时间线：
  submit_log_succ (T1)              sync_log_succ (T2)
       │                                  │
       │ acquire(log_submitted_pending_)   │ wait(log_submitted_pending_)
       │                                  │
       │ 设置 logged_, log_cursor_         │ (阻塞等待)
       │                                  │
       │ release(log_submitted_pending_)  │
       │                                  │ acquire → 设置 sync_scn_
       │                                  │ release
       ▼                                  ▼
```

这保证了 `sync_scn_` 永远不会比实际的 `log_cursor_` 更新——如果在 `submit_log_succ` 之前调用了 `sync_log_succ`，`sync_log_succ` 会阻塞等待 `log_submitted_pending_latch_` 释放。

---

## 7. 回调哈希索引 — `ObTxCallbackHashHolderLinker`

**文件**: `src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.h`

回调链除了通过 `prev_`/`next_` 构成的双向链表外，还维护了一个**哈希索引**，用于按键（tablet_id + row_key）快速定位回调。

```cpp
// ob_tx_callback_hash_holder_helper.h L27-L53 (经 doom-lsp 确认)
class ObTxCallbackHashHolderLinker {
  uint64_t hash_key_;      // 由 tablet_id + row_key 计算
  ObTxCallbackHashHolderLinker *newer_node_;  // 更新的（hash 角度）
  ObTxCallbackHashHolderLinker *older_node_;  // 更旧的（hash 角度）
};
```

此结构通过 `ObTxCallbackHashHolderList` 组织，提供按 SCN 排序的插入和擦除：

```cpp
// L70-L72 (经 doom-lsp 确认)
// append logic on leader, insert logic for follower
// callback ordered by scn
int insert_callback(ObTxCallbackHashHolderLinker *new_callback, bool reverse_find_position);
int erase_callback(ObTxCallbackHashHolderLinker *new_callback, bool reverse_find_position);
```

该哈希索引主要用于 **lock wait manager** 的快速查找：当锁等待发生时，`ObLockWaitMgr` 需要定位到指定 row 的所有者事务的回调，哈希索引避免了全链表扫描。

---

## 8. ELR 机制在回调中的体现

Early Lock Release (ELR) 是 OceanBase 的优化机制：对于单日志流 (single LS) 的事务，在 commit 日志**提出后、同步前**就可以提前释放行锁，减少等待时间。

ELR 在回调体系中有两个参与点：

### 8.1 触发 ELR

```cpp
// ob_tx_callback_list.cpp L820-L833 (经 doom-lsp 确认)
int ObTxCallbackList::tx_elr_preparing()
{
  ObTxForAllFunctor functor(
    [](ObITransCallback *callback) -> int {
      return callback->elr_trans_preparing();
    });
  LockGuard guard(*this, LOCK_MODE::LOCK_ALL);
  // 遍历所有回调，对每个调用 elr_trans_preparing
}
```

对于 `ObMvccRowCallback`，`elr_trans_preparing()`（`ob_mvcc_trans_ctx.cpp L1745-L1758`）：
1. 获取行锁（`ObRowLatchGuard`）
2. 调用 `value_.elr(...)` 在 `ObMvccRow` 上设置 `max_elr_trans_version_`
3. 在 tnode 上设置 `F_ELR` 标志

### 8.2 撤销 ELR

```cpp
// ob_tx_callback_list.cpp L835-L848 (经 doom-lsp 确认)
int ObTxCallbackList::tx_elr_revoke()
{
  // 遍历所有回调，调用 elr_trans_revoke()
}
```

如果 commit 日志最终同步失败，需要撤销 ELR：`ObMvccRowCallback::elr_trans_revoke()` 调用 `tnode_->clear_elr()` 清除 `F_ELR` 标志。

---

## 9. 回调类型体系

`ObITransCallback` 有 3 种子类，由 `MutatorType` 标识：

```cpp
// ob_memtable_mutator.h L102-L106 (经 doom-lsp 确认)
enum class MutatorType {
  MUTATOR_ROW = 0,           // ObMvccRowCallback — 行数据回调
  MUTATOR_TABLE_LOCK = 1,    // ObTableLockCallback — 表锁回调
  MUTATOR_ROW_EXT_INFO = 2,  // ObRowExtInfoCallback — 扩展信息回调
};
```

在回调移除阶段（`callback_()` 中的删除逻辑，`ob_tx_callback_list.cpp L310-L324`），根据类型释放不同内存：

```cpp
if (iter->is_table_lock_callback()) {
  callback_mgr_.get_ctx().free_table_lock_callback(iter);
} else if (MutatorType::MUTATOR_ROW_EXT_INFO == iter->get_mutator_type()) {
  callback_mgr_.get_ctx().free_ext_info_callback(iter);
} else {
  callback_mgr_.get_ctx().free_mvcc_row_callback(iter);
}
```

---

## 10. 设计决策分析

### 10.1 为什么用回调链而非直接操作 TransNode？

1. **解耦事务层与存储层**：事务层（`ObPartTransCtx`）通过回调链与 memtable 层交互，不需要直接操作 `ObMvccTransNode` 的链表。
2. **统一生命周期管理**：不同的回调类型（行数据、表锁、扩展信息）共享同一套状态机（append → log → sync → commit/abort/checkpoint）。
3. **checkpoint 支持**：memtable 冻结转储时，`checkpoint_callback()` 将内存中的行锁转换为事务表锁（`transform_row_lock_to_tx_lock`），而无需事务仍在运行。

### 10.2 为什么需要多把 latch 而不是一把大锁？

回调链的不同阶段有截然不同的并发模式：
- **append** 来自 writer 线程，频繁但轻量
- **fill_log / submit_log_succ** 来自日志生成器，批量操作
- **sync_log_succ** 来自 Paxos 回调，可能与 submit 并发
- **fast_commit / remove_memtable** 来自后台清理

用细粒度 latch 允许这些操作在互不干扰的维度上并行执行。

### 10.3 为什么 `log_submitted` 和 `sync_log_succ` 之间需要 `log_submitted_pending_latch_`？

考虑以下竞态：
1. T1: `submit_log_succ()` 完成，更新 `logged_` 和 `log_cursor_`
2. T2: `tx_commit()` 执行，发现回调 scn_ 未设置（因为 T1 尚未执行 `log_submitted_cb`），报错

`log_submitted_pending_latch_` 保证 `sync_log_succ`（以及后续的 `tx_commit` 中调用的 checksum 计算）在 `submit_log_succ` 完全完成之前无法推进 `sync_scn_`。

---

## 11. 总结

OceanBase 的事务提交回调链是一个精心设计的状态机，它：

1. **用 `ObITransCallback` 基类**统一了 memtable 中所有需要参与事务生命周期的对象
2. **用 `ObTxCallbackList`** 管理回调的 5 个阶段（append → logged → synced → committed/aborted），通过 4 个计数器和 4 把 latch 保证并发安全
3. **与 Paxos 日志同步深度协同**：`log_submitted_cb` 在日志提出时设置 SCN，`sync_log_succ` 在多数派确认时推进 `sync_scn_`，`sync_log_fail` 在失败时回滚
4. **通过 `ObMvccRowCallback`** 桥接回调链与行级多版本数据（`ObMvccTransNode`），在 `trans_commit()` 中完成版本填充、行元数据更新、行锁释放和压缩触发
5. **支持 ELR** 机制，在日志同步前提前释放行锁以提高吞吐
6. **维护哈希索引**，支持锁等待管理器的高效查找

回调链是 OceanBase 分布式事务从"本地写数据"到"全局可见"的关键桥梁，理解它是理解整个 memtable 架构的核心。

---

## 使用 doom-lsp 验证的代码位置汇总

| 符号 | 文件 | 行号 | 命令 |
|---|---|---|---|
| `ObITransCallback` | `ob_mvcc.h` | L40 | `def ObITransCallback` |
| `ObMvccRowCallback` | `ob_mvcc_trans_ctx.h` | L426 | `def ObMvccRowCallback` |
| `ObTxCallbackList` | `ob_tx_callback_list.h` | L31 | `def ObTxCallbackList` |
| `ObTxCallbackHashHolderLinker` | `ob_tx_callback_hash_holder_helper.h` | L27 | `def ObTxCallbackHashHolderLinker` |
| `ObTxCallbackList::append_callback` | `.cpp` | L60, L143 | 批量及单节点 |
| `ObTxCallbackList::concat_callbacks` | `.cpp` | L224 | 合并多条 |
| `ObTxCallbackList::fill_log` | `.cpp` | L603 | 填日志 |
| `ObTxCallbackList::submit_log_succ` | `.cpp` | L634 | 日志提交 |
| `ObTxCallbackList::sync_log_succ` | `.cpp` | L656 | 日志同步 |
| `ObTxCallbackList::sync_log_fail` | `.cpp` | L673 | 日志同步失败 |
| `ObTxCallbackList::tx_commit` | `.cpp` | L781 | 事务提交 |
| `ObTxCallbackList::tx_abort` | `.cpp` | L800 | 事务回滚 |
| `ObTxCallbackList::tx_elr_preparing` | `.cpp` | L820 | ELR 预提交 |
| `ObTxCallbackList::tx_elr_revoke` | `.cpp` | L835 | ELR 撤销 |
| `ObMvccRowCallback::before_append` | `ob_mvcc_trans_ctx.cpp` | L1577 | 注册前 |
| `ObMvccRowCallback::log_submitted` | `ob_mvcc_trans_ctx.cpp` | L1591 | 日志提交 |
| `ObMvccRowCallback::trans_commit` | `ob_mvcc_trans_ctx.cpp` | L1894 | 事务提交流程 |
| `ObMvccRowCallback::trans_abort` | `ob_mvcc_trans_ctx.cpp` | L2027 | 事务回滚流程 |
| `ObMvccRowCallback::rollback_callback` | `ob_mvcc_trans_ctx.cpp` | L2050 | 回滚回调 |
| `ObMvccRowCallback::log_sync_fail` | `ob_mvcc_trans_ctx.cpp` | L2180 | 同步失败 |
| `ObMvccRowCallback::elr_trans_preparing` | `ob_mvcc_trans_ctx.cpp` | L1745 | ELR 准备 |
| `ObITransCallback::before_append_cb` | `ob_mvcc_trans_ctx.cpp` | L90 | 基类注册前 |
| `ObITransCallback::log_submitted_cb` | `ob_mvcc_trans_ctx.cpp` | L110 | 基类日志提交 |
| `ObTxEndFunctor` | `ob_tx_callback_functor.h` | L388 | 事务结束 functor |
| `ObCallbackScope` | `ob_redo_log_generator.h` | L25 | 回调范围 |
| `MutatorType` | `ob_memtable_mutator.h` | L102 | 回调类型枚举 |
