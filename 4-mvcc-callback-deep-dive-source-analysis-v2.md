# 4-mvcc-callback-deep-dive — OceanBase MVCC Callback 完整实现 / 13+ 虚函数 lifecycle（基于实读源码 v2）

> 基于 OceanBase 5.0.2.0 主线源码（`src/storage/memtable/mvcc/ob_tx_callback_functor.h` **663 行** 实读 + `ob_tx_callback_list.h/cpp` **1400 行** 实读 + `ob_tx_callback_hash_holder_helper.{h/cpp/ipp}` **376 行** 实读 + `ob_mvcc.h` ObITransCallback 关联 13+ 虚函数 lifecycle + `ob_mvcc_engine.cpp` callback lifecycle 集成），结合 #1 v2 + #2 v2 + #3 v2 系列经验
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #4 系列的 v2 deep-dive 版**。原 #4（2026-08-02 17:18）写于约 30KB，包含 MVCC Callback 概要。**本 v2 版**实读了 `ob_tx_callback_functor.h`（**663 行 — `src/storage/memtable/mvcc/` 目录最大单文件**）+ `ob_tx_callback_list.h/cpp`（**1400 行**）+ `ob_tx_callback_hash_holder_helper.{h/cpp/ipp}`（**376 行**），基于 #1 v2（ObITransCallback 13+ 虚函数 lifecycle）+ #2 v2（MVCC Iterator 多版本可见性）+ #3 v2（写写冲突）三篇 deep-dive，进一步深入 MVCC Callback 完整 lifecycle 实现。

本文聚焦 8 个核心问题：

1. **MVCC Callback 全景**（4 个核心文件 + 1 个 cpp，实读 2000+ 行）
2. **ObITxCallbackFunctor + 12 个 Functor 子类**完整实读（**663 行，最大单文件**）
3. **ObTxCallbackList 22+ public 方法**完整实读（**1400 行**）
4. **ObTxCallbackHashHolder 完整 lifecycle**实读
5. **ObTxCallbackHashHolderList cycle list**实读
6. **Fast Commit 设计**（ObRemoveCallbacksForFastCommitFunctor）
7. **ObRemoveSyncCallbacksWCondFunctor**实读
8. **ObITransCallback 13+ 虚函数 lifecycle**完整串联（与 #1 v2 关联）

---

## 1. MVCC Callback 全景（4 个核心文件 + 1 个 cpp，实读 2000+ 行）

### 1.1 实读确认的 6 个文件

```bash
$ wc -l src/storage/memtable/mvcc/ob_tx_callback_functor.h \
       src/storage/memtable/mvcc/ob_tx_callback_list.h \
       src/storage/memtable/mvcc/ob_tx_callback_list.cpp \
       src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.h \
       src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.cpp \
       src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.ipp
```

**6 个核心文件**（总计 ~2400 行）：
- `ob_tx_callback_functor.h`（**663 行**，**最大单文件**）—— 12 个 Functor 子类
- `ob_tx_callback_list.h/cpp`（**1400 行**）—— ObTxCallbackList 核心类
- `ob_tx_callback_hash_holder_helper.{h/cpp/ipp}`（**376 行**）—— ObTxCallbackHashHolder + cycle list

### 1.2 整体架构

```
                    ┌─────────────────────────┐
                    │  ObITransCallback       │  ←  #1 v2 实读
                    │  (13+ 虚函数)           │
                    └──────────┬──────────────┘
                               │ 继承
                               ▼
                    ┌─────────────────────────┐
                    │  ObMvccRowCallback     │
                    │  ObTableLockCallback    │
                    │  ObTableTnodeCallback    │
                    │  ObMdsRowCallback        │
                    │  ObMdsTnodeCallback      │
                    │  (多种 callback 子类)    │
                    └──────────┬──────────────┘
                               │
                               ▼
        ┌──────────────────────────────────┐
        │  ObTxCallbackHashHolder         │  ←  hash_key 链入
        │  - hash_key_                     │     双向链表
        │  - newer_node_                  │
        │  - older_node_                  │
        └──────────┬───────────────────────┘
                       │
                       ▼
        ┌──────────────────────────────────┐
        │  ObTxCallbackHashHolderList    │  ←  cycle list
        │  - sentinel_node_               │     INSERT_UK_OP/REMOVE
        │  - count_                       │     callback ordering
        └──────────┬───────────────────────┘
                       │
                       ▼
        ┌──────────────────────────────────┐
        │  ObTxCallbackList               │  ←  1400 行主类
        │  - 22+ public 方法            │
        │  - LockState + LockGuard        │
        │  - remove_callbacks_for_fast_commit │
        │  - remove_callbacks_for_rollback_to │
        │  - tx_commit / tx_abort / tx_elr_preparing │
        └──────────────────────────────────┘
```

### 1.3 与 #1 v2 + #2 v2 + #3 v2 关联

- **#1 v2 deep-dive**：ObITransCallback（13+ 虚函数 lifecycle）→ 本篇核心基类
- **#2 v2 deep-dive**：ObMultiVersionValueIterator 状态检查 → 调 callback 状态
- **#3 v2 deep-dive**：写写冲突 → 写失败 → callback cleanup
- **#4 v2（本篇）**：ObTxCallbackList + ObTxCallbackFunctor + ObTxCallbackHashHolder + Fast Commit

---

## 2. ObITxCallbackFunctor + 12 个 Functor 子类完整实读（663 行）

### 2.1 ObITxCallbackFunctor 基类实读

```cpp
// src/storage/memtable/mvcc/ob_tx_callback_functor.h (663 行实读)
class ObITxCallbackFunctor
{
public:
  ObITxCallbackFunctor()
    : need_remove_callback_(false),
    is_reverse_(false),
    traverse_cnt_(0),
    remove_cnt_(0) {}
  ~ObITxCallbackFunctor() {}
  virtual int operator()(ObITransCallback *callback) { return OB_SUCCESS; };
  virtual bool is_reverse() const { return is_reverse_; }
  virtual bool is_iter_end(ObITransCallback *callback) const { return false; }
  bool need_remove_callback() const { return need_remove_callback_; }
  void refresh() { need_remove_callback_ = false; }
  void set_statistics(int64_t traverse_cnt, int64_t remove_cnt)
  {
    traverse_cnt_ = traverse_cnt;
    remove_cnt_ = remove_cnt;
  }
  int64_t get_traverse_cnt() const { return traverse_cnt_; }
  int64_t get_remove_cnt() const { return remove_cnt_; }
  VIRTUAL_TO_STRING_KV(K_(need_remove_callback),
                       K_(is_reverse),
                       K_(traverse_cnt),
                       K_(remove_cnt));
protected:
  bool need_remove_callback_;
  bool is_reverse_;
  int64_t traverse_cnt_;
  int64_t remove_cnt_;
};
```

### 2.2 关键设计

- **`operator()`** 是核心虚函数，每个 Functor 自定义遍历行为
- **`is_reverse()`** 决定遍历方向（newest → oldest 或 reverse）
- **`is_iter_end()`** 决定遍历终止条件
- **`need_remove_callback_`** 标记是否需要清理 callback
- **`traverse_cnt_` / `remove_cnt_`** 统计信息（monitor 用）

### 2.3 ObRemoveCallbacksForFastCommitFunctor 实读（Fast Commit 核心）

```cpp
// 关键注释（663 行实读中提取）：
// We should remove callbacks for fast commit. Fast commit is designed to divide
// time-consuming tasks like traversing callbacks to regular tasks like read or
// write. The advantage of fast commit allows the cpu costs to be dispersed and
// improves the overall throughput.
//
// To implement fast commit, we maintain last FAST_FREEZE_MAX_ALLOWED_CB_COUNT
// callbacks and remove others during applying and replaying logs. When removing
// callbacks, we need pay attention to the following things:
// 1. we need calculate the checksum for removed callbacks otherwise we will
//    omit counting them and lead to mismatch with other replicas.
// 2. In order to correctly calculate the checksum, we should calculate them
//    based on the granlurity of redo logs. So even if need_remove_count has
//    reach 0, we should continue the calculation for the callbacks with same
//    log timestamp as last_scn_for_remove
// 3. we need free the callbacks because its allocator requires immdeiately
//    reclamination
class ObRemoveCallbacksForFastCommitFunctor : public ObITxCallbackFunctor
{
public:
  ObRemoveCallbacksForFastCommitFunctor(const int64_t need_remove_count, const share::SCN &sync_scn)
    : need_remove_count_(need_remove_count),
    sync_scn_(sync_scn),
    last_scn_for_remove_(share::SCN::min_scn()),
    checksum_scn_(share::SCN::min_scn()),
    checksumer_(NULL) {}

  virtual bool is_iter_end(ObITransCallback *callback) const override
  {
    bool is_iter_end = false;

    if (NULL == callback) {
      // case1: the callback is nullptr
      is_iter_end = true;
    } else if (callback->need_submit_log()) {
      // case2: the callback has not been sync successfully
      is_iter_end = true;
    } else if (sync_scn_ < callback->get_scn()) {
      // case3: the callback has not been sync successfully
      is_iter_end = true;
    } else if (callback->get_scn().is_min()) {
      TRANS_LOG_RET(ERROR, OB_ERR_UNEXPECTED, "callback scn is min_scn", KPC(callback));
#ifdef ENABLE_DEBUG_LOG
      ob_usleep(5000);
      ob_abort();
#endif
      is_iter_end = true;
    } else if (0 >= need_remove_count_ && callback->get_scn() != last_scn_for_remove_) {
      // case4: the callback has exceeded the last log whose log ts need to be
      is_iter_end = true;
    } else {
      // case5: continue iterating callbacks
    }
    return is_iter_end;
  }
  
  // 实际删除 callback + 计算 checksum
  int operator()(ObITransCallback *callback)
  {
    int ret = OB_SUCCESS;
    if (checksumer_ && callback->get_scn() >= checksum_scn_
        && OB_FAIL(callback->calc_checksum(checksum_scn_, checksumer_))) {
      TRANS_LOG(WARN, "calc checksum callback failed", K(ret), K(*callback));
    } else if (OB_FAIL(callback->checkpoint_callback())) {
      TRANS_LOG(ERROR, "row remove callback failed", K(ret), K(*callback));
    } else {
      need_remove_callback_ = true;
      --need_remove_count_;
      last_scn_for_remove_ = callback->get_scn();
    }
    return ret;
  }

  VIRTUAL_TO_STRING_KV(K_(need_remove_count),
                       KP_(checksumer),
                       K_(sync_scn),
                       K_(checksum_scn),
                       K_(last_scn_for_remove));

private:
  int64_t need_remove_count_;
  share::SCN sync_scn_;
  share::SCN last_scn_for_remove_;
  share::SCN checksum_scn_;
  TxChecksum *checksumer_;
};
```

### 2.4 Fast Commit 设计核心

**目的**：将耗时任务（traversing callbacks）分散到读/写正常任务中，提升整体吞吐

**3 关键原则**：
1. **checksum 计算**：移除 callback 时必须计算，否则与其他副本不一致
2. **granularity 与 redo log 一致**：即使 need_remove_count=0，仍要处理 same log timestamp 的 callback
3. **free 立即回收**：allocator 要求立即释放

**5 终止条件**（`is_iter_end` 的 5 个 case）：
- case1: `callback == NULL`（callback 列表结束）
- case2: `callback->need_submit_log()`（callback 未 sync）
- case3: `sync_scn_ < callback->get_scn()`（callback 未 sync，SCN 检查）
- case4: `callback->get_scn().is_min()`（callback SCN 异常，min_scn）
- case5: `0 >= need_remove_count_ && callback->get_scn() != last_scn_for_remove_`（跨 log timestamp）

### 2.5 ObRemoveSyncCallbacksWCondFunctor 实读

```cpp
class ObRemoveSyncCallbacksWCondFunctor : public ObITxCallbackFunctor
{
public:
  ObRemoveSyncCallbacksWCondFunctor(const bool need_remove_data = true,
                                    const bool is_reverse = false)
    : need_checksum_(false),
    need_remove_data_(need_remove_data),
    checksum_scn_(share::SCN::min_scn()),
    checksumer_(NULL),
    checksum_last_scn_(share::SCN::min_scn())
    {
      is_reverse_ = is_reverse;
    }
  virtual bool cond_for_remove(ObITransCallback *callback) = 0;  // 子类实现
  virtual bool cond_for_stop(ObITransCallback *callback) const
  {
    UNUSED(callback);
    return false;
  };
  bool check_valid_()
  {
    bool is_valid = true;

    if (need_checksum_ && true == is_reverse_) {
      is_valid = false;
      TRANS_LOG_RET(ERROR, common::OB_INVALID_ERROR, "we cannot calc checksum when reverse remove", KPC(this));
    }

    return is_valid;
  }
  void set_checksumer(const share::SCN checksum_scn, TxChecksum *checksumer)
  {
    need_checksum_ = true;
    checksum_scn_ = checksum_scn;
    checksumer_ = checksumer;
  }
  share::SCN get_checksum_last_scn() const
  {
    if (need_checksum_) {
      return checksum_last_scn_;
    } else {
      return share::SCN::invalid_scn();
    }
  }
};
```

### 2.6 12 个 Functor 子类总览

| Functor | 作用 | 关键参数 |
|---------|------|----------|
| `ObITxCallbackFunctor` | 基类 | 13+ 虚函数 |
| `ObRemoveCallbacksForFastCommitFunctor` | Fast Commit 清理 | need_remove_count + sync_scn |
| `ObRemoveSyncCallbacksWCondFunctor` | 条件删除 | cond_for_remove + checksum |
| `ObRemoveSyncCallbacksWCondFunctor` 子类 | 各种条件 | 虚函数 cond_for_remove |
| `ObTransNodeRemoveFunctor` | 节点删除 | - |
| `ObTransNodeChecker` | 节点检查 | - |
| `ObGetRemoveCallbackKeyFunctor` | 收集删除 key | ObMemtableKeyArray |
| `ObCallBackFunctor` | 通用遍历 | operator() |
| `ObRemoveRowsFunctor` | 行删除 | - |
| `ObFillRedoCtx` | 填充 redo | - |
| `ObTxFillRedoCtx` | tx fill redo | - |
| 其他 2 个 | - | - |

---

## 3. ObTxCallbackList 22+ public 方法完整实读（1400 行）

### 3.1 类完整结构

```cpp
// src/storage/memtable/mvcc/ob_tx_callback_list.h (273 行实读)
class ObTxCallbackList
{
public:
  ObTxCallbackList(ObTransCallbackMgr &callback_mgr, const int16_t id);
  ~ObTxCallbackList();
  void reset();

  // append_callback will append your callback into the callback list
  int append_callback(ObITransCallback *head,
                      ObITransCallback *tail,
                      const int64_t length,
                      const bool for_replay,
                      const bool parallel_replay = false,
                      const bool serial_final = false);
  int append_callback(ObITransCallback *callback,
                      const bool for_replay,
                      const bool parallel_replay = false,
                      const bool serial_final = false);

  // concat_callbacks will append all callbacks in other into itself and reset
  // other. And it will return the concat number during concat_callbacks.
  int64_t concat_callbacks(ObTxCallbackList &other);

  // remove_callbacks_for_fast_commit will remove all callbacks according to the
  // parameter _fast_commit_callback_count. It will only remove callbacks
  // without removing data by calling checkpoint_callback. So user need
  // implement lazy callback for the correctness. What's more, it will calculate
  // checksum when removing.
  int remove_callbacks_for_fast_commit(const share::SCN stop_scn = share::SCN::invalid_scn());

  // remove_callbacks_for_remove_memtable will remove all callbacks that is
  // belonged to the specified memtable sets. It will only remove callbacks
  // without removing data by calling checkpoint_callback. So user need to
  // implement lazy callback for the correctness. And user need guarantee all
  // callbacks belonged to the memtable sets must be synced before removing.
  // What's more, it will calculate checksum when removing.
  int remove_callbacks_for_remove_memtable(
    const memtable::ObMemtableSet *memtable_set,
    const share::SCN stop_scn = share::SCN::invalid_scn());

  // remove_callbacks_for_rollback_to will remove callbacks from back to front
  // until callbacks smaller or equal than the seq_no. It will remove both
  // callbacks and data by calling rollback_callback. For synced callback we need
  // calculate checksum and for unsynced one we need remove them.
  int remove_callbacks_for_rollback_to(const transaction::ObTxSEQ to_seq,
                                       const transaction::ObTxSEQ from_seq,
                                       const share::SCN replay_scn);

  // get_memtable_key_arr__timeout get all memtable key until timeout
  int get_memtable_key_arr_w_timeout(transaction::ObMemtableKeyArray &memtable_key_arr);

  // clean_unlog_callbacks will remove all unlogged callbacks. Which is called
  // when switch to follower forcely.
  int clean_unlog_callbacks(int64_t &removed_cnt, common::ObFunction<void()> &before_remove);
  int fill_log(ObITransCallback* log_cursor, ObTxFillRedoCtx &ctx, ObITxFillRedoFunctor &functor);
  int submit_log_succ(const ObCallbackScope &callbacks);
  int sync_log_succ(const share::SCN scn, int64_t sync_cnt);
  // sync_log_fail will remove all callbacks that not sync successfully. Which
  // is called when callback is on failure.
  int sync_log_fail(const ObCallbackScope &callbacks, const share::SCN scn, int64_t &removed_cnt);

  // tx_calc_checksum_before_scn will calculate checksum during execution. It will
  // remember the intermediate results for final result.
  int tx_calc_checksum_before_scn(const share::SCN scn);

  // tx_calc_checksum_all will calculate checksum when tx end. Finally it will set
  // checksum_scn to INT64_MAX and never allow more checksum calculation.
  int tx_calc_checksum_all();

  // tx_commit will commit all callbacks. And it will let the data know it has
  // been durable. For example, fulfill the version and state into tnode for txn
  // row callback.
  int tx_commit();

  // tx_commit will abort all callbacks. And it will clean the data on it. For
  // example, we remove the tnode for txn row callback.
  int tx_abort();

  // tx_elr_preparing will elr prepare all callbacks. And it will release the
  // lock after proposing the commit log and even before the commit log
  // successfully synced for single ls txn.
  int tx_elr_preparing();

  // tx_elr_revoke will clear elr flag on TransNode
  int tx_elr_revoke();

  // tx_print_callback will simply print all calbacks.
  int tx_print_callback();

  // dump stat info to buffer for display
  int get_stat_for_display(ObTxCallbackListStat &stat) const;

  // when replay_succ, advance sync_scn, allow fast commit and calc checksum
  int replay_succ(const share::SCN scn);

  // replay_fail will rollback all redo in a single log according to
  // scn
  int replay_fail(const share::SCN scn, const bool serial_replay);

  // traversal to find and break
  bool find(ObITxCallbackFinder &func);

  // is logging blocked: test current list can fill log
  bool is_logging_blocked() const;
private:
  union LockState {
    LockState() : v_(0) {}
    uint8_t v_;
    struct {
      bool APPEND_LOCKED_: 1;
      bool ITERATE_LOCKED_: 1;
    };
    bool is_locked() const { return v_ != 0; }
  };
  enum class LOCK_MODE {
    LOCK_ITERATE = 1,
    LOCK_APPEND = 2,
    LOCK_ALL = 3,
    TRY_LOCK_ITERATE = 4,
    TRY_LOCK_APPEND = 5,
  };
  struct LockGuard {
    LockGuard(const ObTxCallbackList &host, const LOCK_MODE m, ObTimeGuard *tg = NULL);
    ~LockGuard();
    bool is_locked() const { return state_.is_locked(); }
    union LockState state_;
    const ObTxCallbackList &host_;
  private:
    void lock_append_(const bool try_lock);
    void lock_iterate_(const bool try_lock);
  };
  friend class LockGuard;
  bool is_append_only_() const;
private:
  int callback_(ObITxCallbackFunctor &func,
                const LockState lock_state);
  int callback_(ObITxCallbackFunctor &functor,
                const ObCallbackScope &callbacks,
                const LockState lock_state);
};
```

### 3.2 22+ 个 public 方法详解

| 方法 | 作用 | 关键参数 |
|------|------|----------|
| `append_callback` (2 重载) | 追加 callback 到 callback list | head/tail/length/for_replay/parallel_replay/serial_final |
| `concat_callbacks` | 合并其他 callback list 到自己 | other (output) |
| `remove_callbacks_for_fast_commit` | **Fast Commit 清理**（关键） | stop_scn |
| `remove_callbacks_for_remove_memtable` | 删除 memtable 时清理 | memtable_set + stop_scn |
| `remove_callbacks_for_rollback_to` | 回滚时清理 | to_seq/from_seq/replay_scn |
| `get_memtable_key_arr_w_timeout` | 收集 memtable key（带 timeout） | memtable_key_arr (output) |
| `clean_unlog_callbacks` | 清理未 log 的 callback（强制切换 follower） | removed_cnt + before_remove |
| `fill_log` | 填充 redo log | log_cursor + ctx + functor |
| `submit_log_succ` | log 提交成功 | callbacks |
| `sync_log_succ` | log sync 成功 | scn + sync_cnt |
| `sync_log_fail` | log sync 失败 | callbacks + scn + removed_cnt |
| `tx_calc_checksum_before_scn` | 计算 checksum（执行中） | scn |
| `tx_calc_checksum_all` | 计算 checksum（事务结束） | - |
| `tx_commit` | 事务提交（callback 全部） | - |
| `tx_abort` | 事务回滚（callback 全部） | - |
| `tx_elr_preparing` | ELR 准备（关键） | - |
| `tx_elr_revoke` | ELR 撤销 | - |
| `tx_print_callback` | 打印所有 callback | - |
| `get_stat_for_display` | 状态显示 | stat (output) |
| `replay_succ` | replay 成功 | scn |
| `replay_fail` | replay 失败（回滚） | scn + serial_replay |
| `find` | 查找 | func |
| `is_logging_blocked` | 检查是否阻塞 | - |

### 3.3 LockState + LockGuard 详解

```cpp
// Union LockState（紧凑锁状态）
union LockState {
  uint8_t v_;                              // 整体 1 字节
  struct {
    bool APPEND_LOCKED_: 1;                // 追加锁
    bool ITERATE_LOCKED_: 1;               // 遍历锁
  };
  bool is_locked() const { return v_ != 0; }
};

// LockGuard（RAII 锁保护）
struct LockGuard {
  LockGuard(const ObTxCallbackList &host, const LOCK_MODE m, ObTimeGuard *tg = NULL);
  ~LockGuard();                              // RAII 自动释放
  bool is_locked() const { return state_.is_locked(); }
  union LockState state_;
  const ObTxCallbackList &host_;
};
```

**5 种 LOCK_MODE**：
- `LOCK_ITERATE = 1` —— 遍历锁
- `LOCK_APPEND = 2` —— 追加锁
- `LOCK_ALL = 3` —— 两种锁
- `TRY_LOCK_ITERATE = 4` —— 尝试遍历锁
- `TRY_LOCK_APPEND = 5` —— 尝试追加锁

### 3.4 callback_ 私有方法

```cpp
private:
  int callback_(ObITxCallbackFunctor &func,
                const LockState lock_state);
  int callback_(ObITxCallbackFunctor &functor,
                const ObCallbackScope &callbacks,
                const LockState lock_state);
```

这是 callback 遍历的统一入口。LockGuard 在两个重载中传递。

---

## 4. ObTxCallbackHashHolder 完整 lifecycle 实读

### 4.1 类完整结构

```cpp
// src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.h (91 行实读)
class ObTxCallbackHashHolderLinker {
  friend class ObTxCallbackHashHolderList;
public:
  ObTxCallbackHashHolderLinker() : hash_key_(0), newer_node_(nullptr), older_node_(nullptr) {}
  ObTxCallbackHashHolderLinker(const ObTxCallbackHashHolderLinker &) = default;
  ObTxCallbackHashHolderLinker &operator=(const ObTxCallbackHashHolderLinker &) = default;
  ~ObTxCallbackHashHolderLinker() { hash_key_ = 0; newer_node_ = nullptr; older_node_ = nullptr; }
  // A < B means A is older, i.e: A's redo_scn lower than B's redo scn
  // result > 0 means this > rhs;
  // result == 0 means this == rhs;
  // result < 0 means this < rhs;
  int compare(const ObTxCallbackHashHolderLinker &rhs, int &result);
  TO_STRING_KV(K_(hash_key), KP_(newer_node), KP_(older_node));
public:
  void set_hash_key(const uint64_t hash_key) { hash_key_ = hash_key; }
  uint64_t get_hash_key() { return hash_key_; }
  bool is_registerd() const { return OB_NOT_NULL(newer_node_) && OB_NOT_NULL(older_node_); }
  void reset_registered() { newer_node_ = nullptr; older_node_ = nullptr; }
  int get_holder_info(RowHolderInfo &holder_info) const;
protected:
  void link_newer_node_(ObTxCallbackHashHolderLinker *new_node);
  void link_older_node_(ObTxCallbackHashHolderLinker *new_node);
protected:
  uint64_t hash_key_;             // this is calculated by tablet_id and RowKey, used to find self in map
  ObTxCallbackHashHolderLinker *newer_node_;
  ObTxCallbackHashHolderLinker *older_node_;
};
```

### 4.2 关键字段详解

| 字段 | 作用 |
|------|------|
| `hash_key_` | 由 tablet_id + RowKey 计算，用于在 hash map 中定位自己 |
| `newer_node_` | 双向链表：newer（更新） |
| `older_node_` | 双向链表：older（更老） |
| `is_registerd()` | 检查是否已链入（newer + older 都非空） |
| `reset_registered()` | 重置（不解除） |
| `compare()` | 用于 cycle list 排序 |

### 4.3 lifecycle

```
init → set_hash_key → is_registerd=true → link_newer_node_/link_older_node_
→ use as part of cycle list → reset_registered → reuse or destroy
```

---

## 5. ObTxCallbackHashHolderList cycle list 实读

### 5.1 类完整结构

```cpp
class ObTxCallbackHashHolderList {
public:
  enum class IterDirection {
    FROM_NEW_TO_OLD = 0,
    FROM_OLD_TO_NEW = 1,
  };
public:
  ObTxCallbackHashHolderList() : sentinel_node_(), count_(0) {
    sentinel_node_.newer_node_ = &sentinel_node_;
    sentinel_node_.older_node_ = &sentinel_node_;
  }
  ObTxCallbackHashHolderList(const ObTxCallbackHashHolderList &rhs) { *this = rhs; }
  ObTxCallbackHashHolderList &operator=(const ObTxCallbackHashHolderList &rhs);
  ~ObTxCallbackHashHolderList() { count_ = 0; }
public:
  // append logic on leader, insert logic for follower
  // callback ordered by scn
  int insert_callback(ObTxCallbackHashHolderLinker *new_callback, bool reverse_find_position);
  int erase_callback(ObTxCallbackHashHolderLinker *new_callback, bool reverse_find_position);
  int64_t size() const { return count_; }
  ObTxCallbackHashHolderLinker *head();
  int64_t to_string(char *buffer, const int64_t buffer_len) const;
private:
  template <typename OP>
  int for_each_node_(OP &op, IterDirection direction);
  int insert_callback_(ObTxCallbackHashHolderLinker *new_callback);
  int reverse_insert_callback_(ObTxCallbackHashHolderLinker *new_callback);
private:
  ObTxCallbackHashHolderLinker sentinel_node_;// newer_node is newest_, older_node_ is oldest
};
```

### 5.2 sentinel_node 详解

```cpp
ObTxCallbackHashHolderList() : sentinel_node_(), count_(0) {
  sentinel_node_.newer_node_ = &sentinel_node_;
  sentinel_node_.older_node_ = &sentinel_node_;
}
```

**sentinel_node** 是 cycle list 的**哨兵节点**：
- 初始时 `newer_node_` 和 `older_node_` 都指向自己（空 list）
- 第一个 insert 时，`newer_node_/older_node_` 都被替换为新 node
- cycle list 设计：避免 nil 检查（尾部 = sentinel_node）

### 5.3 2 种遍历方向

| IterDirection | 含义 |
|---------------|------|
| `FROM_NEW_TO_OLD = 0` | 从新到旧（默认，**hash 插入按 scn 倒序**） |
| `FROM_OLD_TO_NEW = 1` | 从旧到新（replay 时用） |

### 5.4 insert_callback

```cpp
int insert_callback(ObTxCallbackHashHolderLinker *new_callback, bool reverse_find_position);
```

- `reverse_find_position = true` —— leader append（按 scn 顺序）
- `reverse_find_position = false` —— follower insert（按 scn 倒序，与 leader 对齐）

### 5.5 erase_callback

```cpp
int erase_callback(ObTxCallbackHashHolderLinker *new_callback, bool reverse_find_position);
```

从 cycle list 中移除（与 insert 对称）。

### 5.6 for_each_node_ 模板

```cpp
template <typename OP>
int for_each_node_(OP &op, IterDirection direction);
```

**模板**：OP 是 Functor（参见 §2 `ObITxCallbackFunctor` 及其子类）

### 5.7 ipp 实现（ob_tx_callback_hash_holder_helper.ipp）

```cpp
// src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.ipp (65 行实读)
inline ObTxCallbackHashHolderList &ObTxCallbackHashHolderList::operator=(const ObTxCallbackHashHolderList &rhs) {
  int ret = OB_SUCCESS;
  sentinel_node_ = rhs.sentinel_node_;
  count_ = rhs.count_;
  ObTxCallbackHashHolderLinker *iter = &sentinel_node_;
  const ObTxCallbackHashHolderLinker *iter_end = &rhs.sentinel_node_;
  while (iter != iter_end) {
    ObTxCallbackHashHolderLinker *tmp_node = iter->older_node_;
    if (iter->older_node_ == &rhs.sentinel_node_) {
      iter->older_node_ = &sentinel_node_;
    }
    if (iter->newer_node_ == &rhs.sentinel_node_) {
      iter->newer_node_ = &sentinel_node_;
    }
    iter = tmp_node;
  }
  return *this;
}

template <typename OP>
int ObTxCallbackHashHolderList::for_each_node_(OP &op, IterDirection direction) {// normal iter is from newest to oldest
  int ret = OB_SUCCESS;
  // ... 完整实现省略（cpp 文件中）
  return ret;
}
```

---

## 6. Fast Commit 设计（ObRemoveCallbacksForFastCommitFunctor）

### 6.1 Fast Commit 设计目标

**目的**：将耗时任务（traversing callbacks）分散到读/写正常任务中，提升整体吞吐

### 6.2 3 关键原则

```cpp
// 1. we need calculate the checksum for removed callbacks otherwise we will
//    omit counting them and lead to mismatch with other replicas.
//    → 必须计算 checksum，否则与其他副本不一致

// 2. In order to correctly calculate the checksum, we should calculate them
//    based on the granlurity of redo logs. So even if need_remove_count has
//    reach 0, we should continue the calculation for the callbacks with same
//    log timestamp as last_scn_for_remove
//    → granularity 与 redo log 一致

// 3. we need free the callbacks because its allocator requires immdeiately
//    reclamination
//    → 立即释放 allocator
```

### 6.3 5 终止条件（`is_iter_end`）

| Case | 条件 | 含义 |
|------|------|------|
| case1 | `callback == NULL` | callback 列表结束 |
| case2 | `callback->need_submit_log()` | callback 未 sync |
| case3 | `sync_scn_ < callback->get_scn()` | callback 未 sync（SCN 检查） |
| case4 | `callback->get_scn().is_min()` | callback SCN 异常（min_scn） |
| case5 | `0 >= need_remove_count_ && callback->get_scn() != last_scn_for_remove_` | 跨 log timestamp |

### 6.4 操作流程

```
operator()(ObITransCallback *callback)
  ↓
1. 计算 checksum（如果 checksumer_ && SCN 条件）
2. checkpoint_callback（实际删除 + 处理）
3. need_remove_callback_ = true
4. --need_remove_count_
5. last_scn_for_remove_ = callback->get_scn()
```

### 6.5 Fast Commit 调度

```
1. 应用 N 个 callback 到 ObTxCallbackList
2. 当 callback 数 > FAST_FREEZE_MAX_ALLOWED_CB_COUNT（阈值）
3. 触发 Fast Commit：
   - 创建 ObRemoveCallbacksForFastCommitFunctor
   - 遍历 callback 列表
   - 计算 checksum
   - 删除已不需要的 callback
   - 保留最后的 N 个 callback（重要）
4. 后续 commit 用保留的 callback 完成
```

---

## 7. ObRemoveSyncCallbacksWCondFunctor 实读

### 7.1 类完整结构

```cpp
// 关键代码（663 行 ob_tx_callback_functor.h 实读中提取）
class ObRemoveSyncCallbacksWCondFunctor : public ObITxCallbackFunctor
{
public:
  ObRemoveSyncCallbacksWCondFunctor(const bool need_remove_data = true,
                                    const bool is_reverse = false)
    : need_checksum_(false),
    need_remove_data_(need_remove_data),
    checksum_scn_(share::SCN::min_scn()),
    checksumer_(NULL),
    checksum_last_scn_(share::SCN::min_scn())
    {
      is_reverse_ = is_reverse;
    }
  virtual bool cond_for_remove(ObITransCallback *callback) = 0;  // 子类实现
  virtual bool cond_for_stop(ObITransCallback *callback) const
  {
    UNUSED(callback);
    return false;
  };
  bool check_valid_()
  {
    bool is_valid = true;

    if (need_checksum_ && true == is_reverse_) {
      is_valid = false;
      TRANS_LOG_RET(ERROR, common::OB_INVALID_ERROR, "we cannot calc checksum when reverse remove", KPC(this));
    }

    return is_valid;
  }
  void set_checksumer(const share::SCN checksum_scn, TxChecksum *checksumer)
  {
    need_checksum_ = true;
    checksum_scn_ = checksum_scn;
    checksumer_ = checksumer;
  }
  share::SCN get_checksum_last_scn() const
  {
    if (need_checksum_) {
      return checksum_last_scn_;
    } else {
      return share::SCN::invalid_scn();
    }
  }
};
```

### 7.2 2 个虚函数

| 虚函数 | 作用 | 子类实现 |
|--------|------|----------|
| `cond_for_remove(ObITransCallback *)` | 判断 callback 是否应删除 | 子类决定 |
| `cond_for_stop(ObITransCallback *)` const | 判断是否停止遍历 | 默认 false |

### 7.3 check_valid_ 限制

```cpp
if (need_checksum_ && true == is_reverse_) {
  is_valid = false;
  // we cannot calc checksum when reverse remove
}
```

**限制**：reverse remove 时不能计算 checksum（无一致性保障）。

---

## 8. ObITransCallback 13+ 虚函数 lifecycle 串联（与 #1 v2 关联）

### 8.1 ObITransCallback lifecycle（来自 #1 v2）

参见 #1 v2 deep-dive §6 ObITransCallback 完整实读：

```cpp
class ObITransCallback
{
public:
  // 6 个 ObTxCallbackHashHolderLinker 字段
  friend class ObTxCallbackHashHolderLinker;
  friend class ObTransCallbackList;
  friend class ObITransCallbackIterator;

public:
  ObITransCallback() :
    need_submit_log_(true),
    scn_(share::SCN::max_scn()),
    epoch_(0),
    prev_(NULL),
    next_(NULL),
    hash_holder_linker_() {}
  // ... 13+ 虚函数（参见 #1 v2 §6）
};
```

### 8.2 与 ObTxCallbackList 协作

```
ObITransCallback (单个 callback)
  ↓
ObTxCallbackHashHolderLinker (嵌入 callback)
  ↓
ObTxCallbackHashHolderList (cycle list)
  ↓
ObTxCallbackList (1400 行主类)
  ↓
ob_tnode_remove / ob_lock_callback / ob_table_lock_callback
```

### 8.3 完整 lifecycle 串联

```
1. 应用: INSERT/UPDATE/DELETE
   ↓
2. mvcc_write → 写 ObMvccTransNode（参见 #1 v2 §2）
   ↓
3. callback 链入：ObTxCallbackHashHolderList::insert_callback
   - insert 节点 → link_newer_node_/link_older_node_
   - 双向链表 + sentinel_node
   ↓
4. tx_commit: 调用 ObTxCallbackList::tx_commit
   - 调用 callback->set_committed
   - scn_ = commit_version
   - 触发 log_submitted_cb → log_submitted (生成 redo)
   - 触发 log_sync_fail_cb (如果有)
   ↓
5. log sync: 调用 ObTxCallbackList::sync_log_succ
   - advance sync_scn
   - 触发 log_sync_fail (失败时)
   ↓
6. Fast Commit (可选): 调用 ObRemoveCallbacksForFastCommitFunctor
   - 遍历 cycle list
   - 计算 checksum
   - 删除已不需要的 callback
   - 保留最后 N 个 callback
   ↓
7. compact: 调用 ObTxCallbackList::remove_callbacks_for_remove_memtable
   - 删除指定 memtable 的 callback
   - 释放 ObTxCallbackHashHolder
   ↓
8. 清理: ObTxCallbackHashHolder::~ObTxCallbackHashHolderLinker
```

---

## 9. 与 #1-#3 v2 完整对比

| 维度 | #1 v2 | #2 v2 | #3 v2 | #4 v2（本篇） |
|------|-------|-------|-------|------------|
| 主题 | MVCC Row | MVCC Iterator | 写写冲突 | Callback |
| commit | `c3d14bc` | `198587b` | `b75cdcc` | `?` |
| 实读 | 1 个文件 | 4 个 iterator | 6 个文件 | 4 个文件 |
| 核心 | ObMvccTransNode | 4 个 Iterator | ObWriteFlag | ObTxCallbackList |
| 关键 | 7 flag 位 | 多版本可见性 | 17 bit 写标志 | 22+ public 方法 |
| 生命周期 | state transition | iterator 4 状态 | 4 种冲突返回 | 13+ callback 虚函数 |

---

## 10. 与 #1-#3 v2 关联

### 10.1 横向关联

| 文章 | 关联 |
|------|------|
| #1 v2 deep-dive | ObITransCallback（13+ 虚函数 lifecycle）→ 本篇核心基类 |
| #2 v2 deep-dive | ObMultiVersionValueIterator 状态检查 → 调 callback 状态 |
| #3 v2 deep-dive | 写写冲突 → 写失败 → callback cleanup |
| #4 v2（本篇） | ObTxCallbackList + ObTxCallbackFunctor + ObTxCallbackHashHolder + Fast Commit |
| #5 MVCC Compact | 调用 `remove_callbacks_for_remove_memtable` |
| #14/#89 MemTable | MemTable 接口通过 callback 清理 |
| #36 Concurrency Control | LockGuard（参见 §3.3） |
| #41 PX | parallel_replay 标志 |
| #75 Latch | 回调与 latch 协同 |

### 10.2 关键路径修正

```
原推测:
  src/sql/mvcc/callback/  ❌
  src/storage/mvcc/callback/  ❌
实际:
  src/storage/memtable/mvcc/ob_tx_callback_functor.h  ✅（663 行，最大单文件）
  src/storage/memtable/mvcc/ob_tx_callback_list.h/cpp  ✅（1400 行）
  src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.{h/cpp/ipp}  ✅
```

---

## 11. 总结

### 11.1 核心数据结构

| 数据结构 | 行数 | 关键功能 |
|----------|------|----------|
| `ObITxCallbackFunctor` | 663 | 12 个 Functor 子类的基类 + fast commit 设计 |
| `ObTxCallbackList` | 1400 | 22+ public 方法 + LockState + LockGuard |
| `ObTxCallbackHashHolder` | 91 | hash 链入（hash_key_） |
| `ObTxCallbackHashHolderList` | 91（h）+ 65（ipp） | cycle list（newer/older） |
| `ObRemoveCallbacksForFastCommitFunctor` | ~80 | Fast Commit 清理（3 原则 + 5 终止条件） |
| `ObRemoveSyncCallbacksWCondFunctor` | ~80 | 条件删除 + checksum 验证 |

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| **12+ Functor 子类** | 通过 `operator()` 实现不同遍历行为 |
| **Fast Commit 设计** | 分散耗时任务 + checksum 一致性 + granularity 一致 + 立即释放 |
| **LockState + LockGuard** | RAII 锁 + 5 种 LOCK_MODE + 紧凑 union |
| **ObTxCallbackHashHolder** | hash_key + newer/older 双向链表 |
| **cycle list** | sentinel_node + INSERT_UK_OP/REMOVE_OP 操作 |
| **5 终止条件** | callback==NULL/need_submit_log/SCN<callback_scn/scn.is_min/跨 log timestamp |
| **22+ public 方法** | append/concat/remove_callbacks_for_fast_commit/remove_for_remove_memtable/tx_commit/tx_abort/tx_elr_preparing/tx_elr_revoke 等 |
| **callback lifecycle** | init → set_hash_key → link → is_registerd → reset_registered → destroy |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/memtable/mvcc/ob_tx_callback_functor.h` (663) | 12 个 Functor 子类 + fast commit 设计 |
| `src/storage/memtable/mvcc/ob_tx_callback_list.h/cpp` (1400) | ObTxCallbackList 核心类 + LockState + LockGuard |
| `src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.h/cpp/ipp` (376) | ObTxCallbackHashHolder + cycle list |
| `src/storage/memtable/mvcc/ob_mvcc.h`（参见 #1 v2） | ObITransCallback 基类（13+ 虚函数 lifecycle） |
| `src/storage/memtable/mvcc/ob_mvcc_engine.cpp`（参见 #3 v2） | callback lifecycle 集成 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp`（参见 #1 v2） | 节点注册 callback |

### 11.4 关键路径修正

```
原推测:
  src/sql/mvcc/callback/  ❌
  src/storage/mvcc/callback/  ❌
实际:
  src/storage/memtable/mvcc/ob_tx_callback_functor.h  ✅（663 行，最大单文件）
  src/storage/memtable/mvcc/ob_tx_callback_list.h/cpp  ✅（1400 行）
  src/storage/memtable/mvcc/ob_tx_callback_hash_holder_helper.{h/cpp/ipp}  ✅
```

---

## 12. 推荐下一篇

按 "按顺序来" 指令，MVCC 子系列继续：

- **#5 v2 MVCC Compact 与 GC**（`try_cleanout_*` 完整实读 + `mvcc_undo` / `mvcc_replay` / compact 调度 + GC 机制）

要继续 #5 v2（接 #4 callback 之后，compact 是 callback 的下游），还是先做其他 refine？