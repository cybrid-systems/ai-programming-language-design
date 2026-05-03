# 03-mvcc-write-conflict — OceanBase 写写冲突检测与锁等待深度源码分析

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

写写冲突是 MVCC 存储引擎中最常见的并发控制场景。当事务 T1 想要写入行 R，但事务 T2 已经锁定了 R（尚未提交），T1 必须等待 T2 释放锁后才能继续。OceanBase 的写写冲突检测与等待机制涉及三个核心模块的协作：

1. **`ObMvccRow::check_row_locked`**（`ob_mvcc_row.cpp` @ L1118）：检测行是否被锁定，返回锁的持有者信息
2. **`ObRowConflictHandler::post_row_read_conflict`**（`ob_row_conflict_handler.cpp` @ L255）：将冲突信息注册到 `ObLockWaitMgr`
3. **`ObLockWaitMgr`**（`ob_lock_wait_mgr.h` @ L71）：管理锁等待队列，处理本地/远程唤醒，并支持死锁检测

**doom-lsp 确认**：`ob_lock_wait_mgr.cpp` 中 `handle_local_node_` @ L859，`wait_` @ L1127，`post_lock` @ L1547，`register_local_node_to_deadlock_` @ L988，`check_wait_node_session_stat_` @ L1367。

---

## 1. 核心数据结构

### 1.1 `ObStoreRowLockState`——冲突信息描述符

```c
// ob_i_store.h:225-295 - doom-lsp 确认
struct ObStoreRowLockState
{
  bool                 is_locked_;              // 行是否被锁定
  share::SCN            trans_version_;          // 事务提交版本（用于 TSC 判断）
  transaction::ObTransID lock_trans_id_;       // 锁持有者事务 ID
  transaction::ObTxSEQ   lock_data_sequence_;  // 锁的序列号（ObTxSEQ）
  blocksstable::ObDmlFlag lock_dml_flag_;      // 锁的 DML 类型
  bool                 is_delayed_cleanout_;   // 是否延迟清理（决定等待 txn 还是 row）
  memtable::ObMvccRow  *mvcc_row_;             // 行对象指针（用于重新检查）
  share::SCN            trans_scn_;             // 事务 SCN
};
```

### 1.2 `ObLockWaitMgr::Node`——锁等待节点

```c
// ob_lock_wait_mgr.h:85 - doom-lsp 确认（使用 rpc::ObLockWaitNode）
typedef rpc::ObLockWaitNode Node;
// Node 包含：
//   tx_id_:              请求者事务 ID
//   holder_tx_id_:       锁持有者事务 ID
//   hash_:               锁的 hash（行 hash 或事务 hash）
//   lock_seq_:           锁的序列号（用于检测 lock 状态变化）
//   key_:                锁的 key（行 key 或 tablet key）
//   ls_id_, tablet_id_:  位置信息
//   sessid_:             session ID
//   last_wait_hash_:     上次等待的 hash（用于唤醒）
//   is_placeholder_:     是否是占位节点
//   node_type_:          LOCAL / REMOTE_CTRL_SIDE / REMOTE_EXEC_SIDE
```

**Node 类型**（`rpc::ObLockWaitNode::NODE_TYPE`）：
- `LOCAL`：本地事务请求（本地锁等待）
- `REMOTE_CTRL_SIDE`：远程事务的协调者节点（等待锁的释放消息）
- `REMOTE_EXEC_SIDE`：远程事务的执行者节点（持有锁的一方，通知协调者释放）

### 1.3 Hash 表结构

```c
// ob_lock_wait_mgr.h:79-83 - doom-lsp 确认
static const int64_t LOCK_BUCKET_COUNT = 16384;  // 16384 个桶
// hash_ 指向 FixedHash2<Node>，每个桶是一个链表
// sequence_[i]: 每个桶的锁序列号，用于检测锁状态变化
```

---

## 2. `check_row_locked` —— 行锁状态检测

### 2.1 完整实现

```c
// ob_mvcc_row.cpp:1118-1205 - doom-lsp 确认
int ObMvccRow::check_row_locked(ObMvccAccessCtx &ctx,
                                ObStoreRowLockState &lock_state)
{
  int ret = OB_SUCCESS;
  ObRowLatchGuard guard(latch_);  // ★ 获取行锁（排他）
  ObMvccTransNode *iter = ATOMIC_LOAD(&list_head_);
  bool need_retry = true;

  while (OB_SUCC(ret) && need_retry) {
    if (OB_ISNULL(iter)) {
      // Case 1: 链表为空，行当前未被锁定
      lock_state.is_locked_ = false;
      lock_state.trans_version_.set_min();
      lock_state.lock_trans_id_.reset();
      lock_state.lock_dml_flag_ = DF_NOT_EXIST;
      need_retry = false;
    } else {
      const ObTransID data_tx_id = iter->tx_id_;
      if (!(iter->is_committed() || iter->is_aborted())
          && iter->is_delayed_cleanout()
          && OB_FAIL(ctx.get_tx_table_guards().cleanout_tx_node(data_tx_id, *this, *iter, false))) {
        // Case 2: 头节点是 delayed_cleanout 且未决 → 先 cleanout
        // Tip: 和读操作的 lock_for_read 不同，写操作需要等待节点状态确定
      } else if (iter->is_committed() || iter->is_elr()) {
        // Case 3: 头节点已提交或 ELR → 行未被锁定
        lock_state.is_locked_ = false;
        lock_state.lock_trans_id_.reset();
        lock_state.trans_version_ = get_max_trans_version();
        lock_state.lock_dml_flag_ = iter->get_dml_flag();
        need_retry = false;
      } else if (iter->is_aborted()) {
        // Case 4: 头节点已中止 → 跳过，查看下一个节点
        iter = iter->prev_;
        need_retry = true;
      } else {
        // Case 5: 头节点被其他事务锁定（未决状态）★ 核心冲突情况
        lock_state.is_locked_ = true;
        lock_state.trans_version_.set_min();
        lock_state.lock_trans_id_ = data_tx_id;
        lock_state.lock_data_sequence_ = iter->get_seq_no();
        lock_state.lock_dml_flag_ = iter->get_dml_flag();
        lock_state.is_delayed_cleanout_ = iter->is_delayed_cleanout();
        lock_state.trans_scn_ = iter->get_scn();
        lock_state.mvcc_row_ = this;
        need_retry = false;
      }
    }
  }
  return ret;
}
```

### 2.2 锁状态判断的 Case 分析

| Case | 条件 | 结果 | 说明 |
|------|------|------|------|
| 1 | `iter == NULL`（空链表） | `is_locked_ = false` | 行不存在，根本没有锁 |
| 2 | `is_delayed_cleanout && !is_committed && !is_aborted` | cleanout 后重试 | 需要等待事务状态确定 |
| 3 | `is_committed \|\| is_elr` | `is_locked_ = false` | 节点已提交，锁已释放 |
| 4 | `is_aborted` | `iter = iter->prev_` | 节点已回滚，看下一个 |
| **5** | **其他未决状态** | **`is_locked_ = true`** | **其他事务持有锁** |

**Case 5 是真正的锁等待触发点**：`data_tx_id != ctx.tx_id_`（持有者不是自己），`is_committed == false`，`is_aborted == false`。

### 2.3 `is_delayed_cleanout_` 的意义

```c
// ob_mvcc_row.cpp:1159 - doom-lsp 确认
lock_state.is_delayed_cleanout_ = iter->is_delayed_cleanout();
lock_state.trans_scn_ = iter->get_scn();
```

`is_delayed_cleanout_` 决定后续等待策略：
- **`true`**：锁状态需要通过 `ObTxTable` 检查（`recheck_func` 中 `check_row_locked` 使用 `tx_table_guards.check_row_locked`）
- **`false`**：锁状态可以直接通过 `ObMvccRow` 检查（`mvcc_row_->check_row_locked`）

---

## 3. `ObRowConflictHandler::check_row_locked` —— 冲突处理入口

### 3.1 `check_row_locked`（带 `post_lock` 参数）

```c
// ob_row_conflict_handler.cpp:30-75 - doom-lsp 确认
int ObRowConflictHandler::check_row_locked(const storage::ObTableIterParam &param,
                                          storage::ObTableAccessContext &context,
                                          const blocksstable::ObDatumRowkey &rowkey,
                                          const bool by_myself,
                                          const bool post_lock)
{
  // by_myself: 是否由自己触发（死锁检测时 by_myself=true）
  // post_lock: 是否将冲突注册到 lock_wait_mgr
  ObStoreRowLockState lock_state;
  share::SCN max_trans_version = share::SCN::min_scn();
  const ObTransID my_tx_id = acc_ctx.get_tx_id();

  if (OB_FAIL(check_row_locked(param, context, rowkey, lock_state, max_trans_version))) {
    // ...
  } else {
    if (lock_state.is_locked_) {
      if ((by_myself && lock_state.lock_trans_id_ == my_tx_id)
          || (!by_myself && lock_state.lock_trans_id_ != my_tx_id)) {
        ret = OB_TRY_LOCK_ROW_CONFLICT;
        if (post_lock) {
          // ★ 注册到 lock_wait_mgr，进入锁等待
          post_row_read_conflict(acc_ctx, rowkey.get_store_rowkey(),
                                 lock_state, tablet_id, ls_id, 0, 0,
                                 lock_state.trans_scn_);
        }
      }
    } else if (max_trans_version > snapshot_version) {
      ret = OB_TRANSACTION_SET_VIOLATION;  // TSC 错误
    }
  }
}
```

### 3.2 两种错误码

| 错误码 | 场景 | 处理方式 |
|--------|------|----------|
| `OB_TRY_LOCK_ROW_CONFLICT` | 行被其他事务锁定，需要等待 | 注册到 `ObLockWaitMgr`，等待唤醒 |
| `OB_TRANSACTION_SET_VIOLATION` | 行已被提交但版本 > snapshot | 返回 SQL 层重试或抛异常 |

---

## 4. `post_row_read_conflict` —— 注册到锁等待管理器

```c
// ob_row_conflict_handler.cpp:255-340 - doom-lsp 确认
int ObRowConflictHandler::post_row_read_conflict(ObMvccAccessCtx &acc_ctx,
                                                 const ObStoreRowkey &row_key,
                                                 ObStoreRowLockState &lock_state,
                                                 const ObTabletID tablet_id,
                                                 const ObLSID ls_id,
                                                 ...)
{
  int ret = OB_TRY_LOCK_ROW_CONFLICT;
  int64_t current_ts = ObClockGenerator::getClock();
  int64_t lock_wait_expire_ts = acc_ctx.eval_lock_expire_ts(current_ts);

  // 检查锁等待超时
  if (current_ts >= lock_wait_expire_ts) {
    ret = OB_ERR_EXCLUSIVE_LOCK_CONFLICT;  // 锁等待超时
  } else {
    // ★ 构造 recheck_func：用于唤醒后重新检查锁状态
    ObFunction<int(bool&, bool&)> recheck_func([&](bool &locked, bool &wait_on_row) -> int {
      // 如果是 delayed_cleanout：通过 tx_table 检查
      // 否则：通过 mvcc_row 检查
      if (lock_state.is_delayed_cleanout_) {
        tx_table_guards.check_row_locked(tx_id, conflict_tx_id,
                                         lock_data_sequence, trans_scn, lock_state);
      } else {
        lock_state.mvcc_row_->check_row_locked(acc_ctx, lock_state);
      }
      locked = lock_state.is_locked_ && lock_state.lock_trans_id_ != tx_id;
      wait_on_row = !lock_state.is_delayed_cleanout_;
    });

    // 计算 row_hash 和 tx_hash
    uint64_t row_hash = LockHashHelper::hash_rowkey(tablet_id, key);
    uint64_t tx_hash = LockHashHelper::hash_trans(holder_tx_id);

    // 双重检查锁状态（atomic get seq）
    do {
      row_lock_seq = get_seq_(row_hash);
      tx_lock_seq = get_seq_(tx_hash);
      if (OB_FAIL(recheck_func(locked, wait_on_row))) { ... }
    } while (OB_SUCC(ret) && locked);

    if (locked) {
      // ★ 调用 post_lock 注册到 lock_wait_mgr
      tmp_ret = lock_wait_mgr->post_lock(OB_TRY_LOCK_ROW_CONFLICT, ...);
    }
  }
}
```

**双重检查锁状态的原因**：避免在 `get_seq_()` 和 `recheck_func()` 之间锁被释放导致错失唤醒。

---

## 5. `ObLockWaitMgr::post_lock` —— 冲突信息入队

```c
// ob_lock_wait_mgr.cpp:1547-1640 - doom-lsp 确认
int ObLockWaitMgr::post_lock(const int tmp_ret,
                             const ObLSID &ls_id,
                             const ObTabletID &tablet_id,
                             const ObStoreRowkey &row_key,
                             const int64_t timeout,
                             ...)
{
  int ret = OB_SUCCESS;
  if (!is_inited_) {
    ret = OB_NOT_INIT;
  } else if (OB_TRY_LOCK_ROW_CONFLICT == tmp_ret) {
    Key key(&row_key);
    uint64_t row_hash = LockHashHelper::hash_rowkey(tablet_id, key);
    uint64_t tx_hash = LockHashHelper::hash_trans(holder_tx_id);

    // 计算 hash：wait_on_row ? row_hash : tx_hash
    // 这决定是等待"某个行锁"还是"某个事务持有的所有锁"
    uint64_t hash = wait_on_row ? row_hash : tx_hash;

    // ★ 重置等待超时
    reset_head_node_wait_timeout_if_need(hash, lock_ts);

    // 构建 ObRowConflictInfo 并注册到死锁检测器
    cflict_info.init(addr_, ls_id, tablet_id, ...);
    if (OB_SUCCESS != ObTransDeadlockDetectorAdapter::
        get_trans_info_on_participant(...)) {
      // 获取冲突事务的信息（scheduler 地址等）
    }
  }
  return ret;
}
```

---

## 6. `ObLockWaitMgr::handle_local_node_` —— 本地等待处理

```c
// ob_lock_wait_mgr.cpp:859-888 - doom-lsp 确认
int ObLockWaitMgr::handle_local_node_(Node* node, Node*& delete_node, bool &wait_succ)
{
  int ret = OB_SUCCESS;
  bool deadlock_registered = false;
  ObTransID self_tx_id(node->tx_id_);
  ObTransID blocked_tx_id(node->holder_tx_id_);

  begin_row_lock_wait_event(node);

  // ★ Step 1: 注册到死锁检测器
  if (OB_LIKELY(ObDeadLockDetectorMgr::is_deadlock_enabled())) {
    if (OB_UNLIKELY(OB_FAIL(register_local_node_to_deadlock_(self_tx_id,
                                                             blocked_tx_id,
                                                             node)))) {
      DETECT_LOG(WARN, "register to deadlock detector failed", K(ret), K(*node));
    } else {
      deadlock_registered = true;
    }
  }

  // ★ Step 2: 进入 wait_ 等待锁释放
  wait_succ = wait_(node, delete_node, is_placeholder);

  // ★ Step 3: 如果等待失败（超时/被杀死），从死锁检测器注销
  if (OB_UNLIKELY(!wait_succ && deadlock_registered)) {
    ObTransDeadlockDetectorAdapter::unregister_from_deadlock_detector(
        self_tx_id,
        ObTransDeadlockDetectorAdapter::UnregisterPath::LOCK_WAIT_MGR_WAIT_FAILED);
  }
  return ret;
}
```

---

## 7. `ObLockWaitMgr::wait_` —— 核心等待逻辑

```c
// ob_lock_wait_mgr.cpp:1127-1170 - doom-lsp 确认
bool ObLockWaitMgr::wait_(Node* node, Node*& delete_node, bool &is_placeholder)
{
  bool wait_succ = false;
  bool enqueue_succ = false;
  uint64_t hash = node->hash();
  int64_t last_lock_seq = node->lock_seq_;  // 入队时的锁序列号

  CriticalGuard(get_qs());  // ★ 获取 QSync 锁（读写临界区）

  if (node->get_node_type() == rpc::ObLockWaitNode::REMOTE_CTRL_SIDE) {
    // 远程协调者节点：直接入队等待显式唤醒
    (void)insert_node_(node);
    wait_succ = true;
    enqueue_succ = true;
  } else if (check_wakeup_seq_(hash, last_lock_seq, cur_seq)) {
    // 锁序列号未变：锁仍被持有，入队等待
    (void)insert_node_(node);
    wait_succ = true;
    enqueue_succ = true;
    // 双重检查
    if (!check_wakeup_seq_(hash, last_lock_seq, cur_seq)) {
      wait_succ = on_seq_change_after_insert_(node, delete_node, enqueue_succ);
    }
  } else {
    // 锁序列号已变：锁已释放，不需要等待
    wait_succ = on_seq_change_(node, delete_node, enqueue_succ, cur_seq);
  }

  after_wait_(node, delete_node, enqueue_succ, wait_succ, is_placeholder);
  return wait_succ;
}
```

### 7.1 `check_wakeup_seq_` —— 锁状态检测

```c
// ob_lock_wait_mgr.cpp:412 - doom-lsp 确认
// sequence_[hash % LOCK_BUCKET_COUNT] 存储当前锁的序列号
// 如果 lock_seq == sequence_[bucket]，说明锁仍被持有，需要等待
// 如果 lock_seq != sequence_[bucket]，说明锁已释放，可以继续
bool check_wakeup_seq_(uint64_t hash, int64_t last_lock_seq, int64_t &cur_seq) {
  cur_seq = ATOMIC_LOAD(&sequence_[(hash >> 1) % LOCK_BUCKET_COUNT]);
  return last_lock_seq == cur_seq;
}
```

### 7.2 `insert_node_` —— 节点插入

```c
// ob_lock_wait_mgr.cpp:383 - doom-lsp 确认
// 将节点插入 hash 桶的链表头部
// 使用 CriticalGuard(get_qs()) 保证并发安全
```

---

## 8. `register_local_node_to_deadlock_` —— 死锁检测注册

```c
// ob_lock_wait_mgr.cpp:988-1040 - doom-lsp 确认
int ObLockWaitMgr::register_local_node_to_deadlock_(const ObTransID &self_tx_id,
                                                    const ObTransID &blocked_tx_id,
                                                    const Node * const node)
{
  CollectCallBack on_collect_callback(LocalDeadLockCollectCallBack(self_tx_id,
                                                                  node->key_,
                                                                  sess_id_pair,
                                                                  node->get_ls_id(),
                                                                  node->tablet_id_,
                                                                  ObTxSEQ::cast_from_int(node->get_holder_tx_hold_seq_value())));

  if (LockHashHelper::is_rowkey_hash(node->hash())) {
    // ★ 等待行锁：注册 "waiting for row" 边
    DeadLockBlockCallBack deadlock_block_callback(row_holder_mapper_, node->hash());
    ObTransDeadlockDetectorAdapter::lock_wait_mgr_reconstruct_detector_waiting_for_row(
        on_collect_callback,
        deadlock_block_callback,
        fill_virtual_info_callback,
        self_tx_id,
        sess_id_pair);
  } else {
    // ★ 等待事务：注册 "waiting for trans" 边
    ObTransDeadlockDetectorAdapter::lock_wait_mgr_reconstruct_detector_waiting_for_trans(
        on_collect_callback,
        fill_virtual_info_callback,
        blocked_tx_id,
        self_tx_id,
        sess_id_pair);
  }
}
```

**等待图的两类边**：
- **waiting for row**：请求者 → 行（`row_holder_mapper_`）
- **waiting for trans**：请求者 → 持有者事务

---

## 9. 唤醒机制

### 9.1 本地唤醒

```c
// ob_lock_wait_mgr.cpp:447 - doom-lsp 确认
// ObLockWaitMgr::fetch_wait_head(hash)
// 从 hash 桶的链表头部获取第一个等待节点并返回
// 由锁持有者在释放锁时调用
void ObLockWaitMgr::wakeup_(uint64_t hash) {
  CriticalGuard(get_qs());
  Node *head = fetch_wait_head(hash);
  if (head != NULL) {
    // 增加 sequence_ 表示锁已释放
    // 唤醒等待节点
  }
}
```

### 9.2 远程唤醒

```c
// ob_lock_wait_mgr.cpp:308 - doom-lsp 确认
// REMOTE_EXEC_SIDE 节点持有锁，REMOTE_CTRL_SIDE 节点等待锁释放
// 当 REMOTE_EXEC_SIDE 释放锁时，发送 RPC 给协调者
void ObLockWaitMgr::remote_wakeup_(const uint64_t hash, const ObAddr &addr);
```

### 9.3 序列号变化检测

```c
// ob_lock_wait_mgr.cpp:412 - doom-lsp 确认
// 当锁释放时，sequence_[bucket]++，所有等待该锁的节点检测到序列号变化后被唤醒
bool ObLockWaitMgr::check_wakeup_seq_(uint64_t hash, int64_t last_lock_seq, int64_t &cur_seq)
{
  cur_seq = ATOMIC_LOAD(&sequence_[(hash >> 1) % LOCK_BUCKET_COUNT]);
  return last_lock_seq == cur_seq;  // 相等说明锁仍被持有
}
```

---

## 10. 锁等待超时检测

```c
// ob_lock_wait_mgr.cpp:1367 - doom-lsp 确认
void ObLockWaitMgr::check_wait_node_session_stat_(Node *iter,
                                                   Node *&node2del,
                                                   int64_t curr_ts,
                                                   int64_t wait_timeout_ts) {
  // 检查等待节点的 session 是否还存活
  // 如果 session 被 kill，从等待队列中移除
  // 如果等待超时，从等待队列中移除，唤醒后续节点
}
```

**`ObLockWaitMgr::run1()`**（L111）定期（`CHECK_TIMEOUT_INTERVAL = 100ms`）检查所有等待节点，处理超时和 session 死亡。

---

## 11. 完整数据流图

```
T1: 写者（等待者）                          T2: 锁持有者
  │                                            │
  │ check_row_locked()                         │
  │   └─→ iter->is_locked() = true             │
  │       lock_trans_id_ = T2                   │
  │                                            │
  │ post_row_read_conflict()                    │
  │   └─→ post_lock()                          │
  │       └─→ lock_wait_mgr->post_lock()       │
  │                                            │
  │ handle_local_node_()                        │
  │   ├─→ register_local_node_to_deadlock_()   │
  │   │    └─→ 添加 "T1 waiting for row" 边    │
  │   │                                        │
  │   └─→ wait_()                              │
  │        ├─→ check_wakeup_seq_(hash, seq)    │
  │        │    └─→ seq == sequence_[bucket]   │
  │        │         说明锁仍被持有，继续等待    │
  │        └─→ insert_node_(node)              │
  │             └─→ 进入 hash 桶链表等待        │
  │                                            │
  │  ... 等待中 ...                            │
  │                                            │
  │ ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ←│
  │                                            │
  │         T2 提交事务，释放锁                 │
  │              │                             │
  │              ├─→ wakeup_(hash)             │
  │              │    └─→ sequence_[bucket]++   │
  │              │         所有等待节点被唤醒   │
  │              │         check_wakeup_seq    │
  │              │         返回 false（不等了） │
  │              │                             │
  │              └─→ unregister_from_deadlock_ │
  │                                            │
  │ check_wakeup_seq_() 返回 false             │
  │   └─→ on_seq_change_()                     │
  │       wait_succ = false（立即返回）        │
  │                                            │
  │ 被唤醒，T1 继续执行 write                   │
```

---

## 12. 死锁检测

OceanBase 使用 **LCL（Lazy Cycle Detection）** 轻量级死锁检测算法：

```c
// ob_deadlock_detector_mgr.h:85 - doom-lsp 确认
static bool is_deadlock_enabled() {
  return ObServerConfig::get_instance()._lcl_op_interval != 0;
}
```

**LCL 原理**：不主动检测，而是在每次注册等待边时检查是否形成环。如果 T1 等 T2，T2 等 T3，T3 等 T1，则检测到死锁，强制回滚其中一个事务。

```c
// ob_lock_wait_mgr.cpp:869-872 - doom-lsp 确认
if (OB_LIKELY(ObDeadLockDetectorMgr::is_deadlock_enabled())) {
  if (OB_UNLIKELY(OB_FAIL(register_local_node_to_deadlock_(self_tx_id, holder_tx_id, node)))) {
    // 注册失败（可能检测到死锁）
  }
}
```

---

## 13. 与 MySQL InnoDB 的对比

| 维度 | MySQL InnoDB | OceanBase |
|------|-------------|-----------|
| 锁冲突检测 | `lock_wait()` 在 `row0umv.cc` | `check_row_locked()` 在 `ob_mvcc_row.cpp` |
| 等待队列 | 内存队列 + OS CV | `ObLockWaitMgr` Hash 桶 + `CriticalGuard` |
| 锁状态变化检测 | OS 条件变量 | `sequence_[]` 序列号检测 |
| 远程等待 | N/A（单节点）| `REMOTE_CTRL_SIDE` + `REMOTE_EXEC_SIDE` RPC 协作 |
| 死锁检测 | 被动超时检测 | LCL 主动检测（注册边时） |
| 锁等待超时 | `innodb_lock_wait_timeout` | `lock_wait_expire_ts` 计算 |

---

## 14. 源码文件索引

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `ObMvccRow::check_row_locked()` | 1118 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `ObMvccRow::check_row_locked()` Case 5 | 1159 |
| `src/storage/memtable/ob_row_conflict_handler.cpp` | `ObRowConflictHandler::check_row_locked()` | 30 |
| `src/storage/memtable/ob_row_conflict_handler.cpp` | `ObRowConflictHandler::check_row_locked()` with post_lock | 30 |
| `src/storage/memtable/ob_row_conflict_handler.cpp` | `ObRowConflictHandler::post_row_read_conflict()` | 255 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` | `class ObLockWaitMgr` | 71 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.h` | `LOCK_BUCKET_COUNT = 16384` | 79 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `ObLockWaitMgr::handle_local_node_()` | 859 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `ObLockWaitMgr::wait_()` | 1127 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `ObLockWaitMgr::wait_with_deadlock_enabled_()` | 325 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `ObLockWaitMgr::register_local_node_to_deadlock_()` | 988 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `ObLockWaitMgr::post_lock()` | 1547 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `ObLockWaitMgr::check_wait_node_session_stat_()` | 1367 |
| `src/storage/lock_wait_mgr/ob_lock_wait_mgr.cpp` | `ObLockWaitMgr::wakeup_()` | 447 |
| `src/share/deadlock/ob_deadlock_detector_mgr.h` | `ObDeadLockDetectorMgr::is_deadlock_enabled()` | 85 |

---

## 15. 下篇预告

- **04-mvcc-callback**：事务提交回调链与 Paxos 日志同步的协同
- **05-mvcc-compact**：版本链的 compaction/GC 机制
- **06-memtable-freezer**：Memtable 冻结与 SSTable 持久化
- **07-ls-logstream**：LogStream 与分区副本管理
- **08-ob-sstable**：SSTable 存储格式与块编码
- **09-ob-sql-executor**：SQL 执行器与存储层的交互
- **10-ob-transaction**：分布式两阶段提交与事务管理器

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 代码仓库：OceanBase CE*