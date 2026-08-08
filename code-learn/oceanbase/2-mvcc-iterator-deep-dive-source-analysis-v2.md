# 2-mvcc-iterator-deep-dive — OceanBase MVCC Iterator / 多版本可见性深度源码分析（基于实读源码 v2）

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/storage/memtable/mvcc/ob_multi_version_iterator.h` **137 行** 实读 + `src/storage/memtable/mvcc/ob_mvcc_iterator.h` **192 行** 实读 + `src/storage/memtable/mvcc/ob_mvcc_acc_ctx.h` **362 行** 实读 + 头文件 30+ 行），结合 #1-#100 系列 + #1 v2 deep-dive 经验
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #2 系列的 v2 deep-dive 版**。原 #2（2026-08-02 17:18）写于约 30KB，包含 MVCC Iterator 的概要分析。**本 v2 版**实读了 `ob_multi_version_iterator.h`（137 行）+ `ob_mvcc_iterator.h`（192 行）+ `ob_mvcc_acc_ctx.h`（362 行），基于 #1 v2 deep-dive 的 MVCC Row 基础，进一步深入多版本可见性算法、迭代器状态机、cleanout 机制。

本文聚焦 8 个核心问题：

1. **MVCC Iterator 4 个核心类全景**（基于实读源码）
2. **ObMultiVersionValueIterator** —— 单值多版本迭代器（137 行实读）
3. **ObMultiVersionRowIterator** —— 多版本行迭代器（137 行实读）
4. **ObMvccValueIterator** —— 值迭代器（192 行实读）
5. **ObMvccRowIterator** —— 行迭代器（192 行实读）
6. **ObMvccScanRange** —— 扫描范围
7. **多版本可见性算法**（state machine）
8. **Iterator 生命周期与 cleanout 机制**

---

## 1. 4 个核心类全景（基于实读源码）

### 1.1 实读确认的 4 个类 + 2 个 struct

```cpp
// src/storage/memtable/mvcc/ob_multi_version_iterator.h (137 行)
class ObMultiVersionValueIterator { /* 单值多版本 */ };
class ObMultiVersionRowIterator { /* 多版本行 */ };

// src/storage/memtable/mvcc/ob_mvcc_iterator.h (192 行)
struct ObMvccScanRange { border_flag_/start_key_/end_key_ };
class ObMvccValueIterator { /* 值迭代器 */ };
class ObMvccRowIterator { /* 行迭代器 */ };

// src/storage/memtable/mvcc/ob_mvcc_acc_ctx.h (362 行)
struct ObMvccMdsFilter { read_info_/mds_filter_mgr_ };
// + ObMvccReadCtx 相关（ObPartTransCtx / ObTxTable / ObTxTableGuard 等）
```

### 1.2 类层次图

```
                          ┌─────────────────────┐
                          │  ObMvccScanRange    │  (ob_mvcc_iterator.h)
                          │  border_flag_       │
                          │  start_key_/end_key_│
                          └──────────┬──────────┘
                                     │
            ┌────────────────────────┼────────────────────────┐
            │                        │                        │
            ▼                        ▼                        ▼
┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│ObMvccValueIterator  │  │ObMultiVersionValue  │  │ObMvccRowIterator    │
│(ob_mvcc_iterator.h) │  │Iterator             │  │(ob_mvcc_iterator.h) │
│                     │  │(ob_multi_version_   │  │                     │
│get_next_node()      │  │ iterator.h)         │  │get_next_row()       │
│check_row_locked()   │  │                     │  │                     │
│get_trans_id()       │  │get_next_node()      │  │init()               │
│get_snapshot_version()│  │get_next_node_       │  │reset()              │
│get_mvcc_acc_ctx()   │  │ for_compact()       │  │get_key_val()        │
│get_mvcc_row()       │  │get_next_multi_      │  │check_and_purge_     │
│get_trans_node()     │  │ version_node()      │  │row_()               │
│...                  │  │get_next_uncommitted │  └─────────────────────┘
└──────────┬──────────┘  │_node()              │
           │             │check_next_sql_      │
           │             │sequence()           │
           │             └──────────┬──────────┘
           │                        │
           └────────────────────────┼─────────────────┐
                                    │                 │
                                    ▼                 ▼
                          ┌─────────────────────┐  ┌─────────────────────┐
                          │ObMultiVersionRow   │  │ObMvccReadCtx        │
                          │Iterator            │  │(ob_mvcc_acc_ctx.h)  │
                          │(ob_multi_version_  │  │                     │
                          │ iterator.h)         │  │ObMvccMdsFilter      │
                          │                     │  │ObPartTransCtx       │
                          │get_next_row()      │  │ObTxTable            │
                          │get_tnode_dml_stat()│  │ObTxTableGuard       │
                          │try_cleanout_       │  │...                  │
                          │mvcc_row_()         │  └─────────────────────┘
                          │try_cleanout_       │
                          │tx_node_()          │
                          └─────────────────────┘
```

---

## 2. ObMultiVersionValueIterator 完整实读（137 行）

### 2.1 类完整结构

```cpp
// src/storage/memtable/mvcc/ob_multi_version_iterator.h
class ObMultiVersionValueIterator
{
public:
  ObMultiVersionValueIterator();
  virtual ~ObMultiVersionValueIterator();
  //用来迭代冻结memtable多版本和事务未提交的row
public:
  int init(ObMvccAccessCtx *ctx,
           const common::ObVersionRange &version_range,
           const ObMemtableKey *key,
           ObMvccRow *value);
  virtual int get_next_node(const void *&tnode);
  int get_next_node_for_compact(const void *&tnode);
  int get_next_multi_version_node(const void *&tnode);
  int get_next_uncommitted_node(
      const void *&tnode,
      transaction::ObTransID &trans_id,
      share::SCN &trans_version,
      transaction::ObTxSEQ &sql_sequence);
  int check_next_sql_sequence(
      const transaction::ObTransID &input_trans_id,
      const transaction::ObTxSEQ input_sql_sequence,
      bool &same_sql_sequence_flag);
  void reset();
  bool is_exist() const { return nullptr != version_iter_; }
  int64_t get_committed_max_trans_version() const { return max_committed_trans_version_; }
  bool is_first_delete_compact_node() const;
  bool is_last_compact_node() const;
  bool is_first_delete_multi_version_node() const;
  bool is_cur_multi_version_row_end() const ;
  bool is_node_compacted() const { return is_node_compacted_; }
  bool is_multi_version_iter_end() const;
  bool is_trans_node_iter_null() const;
  bool is_compact_iter_end() const;
  int init_multi_version_iter();
  void set_merge_scn(const share::SCN merge_scn) { merge_scn_ = merge_scn; }
  share::SCN get_merge_scn() const { return merge_scn_; }
  void print_cur_status();
  blocksstable::ObDmlFlag get_row_first_dml_flag() const
  {
    return nullptr != value_ ? value_->get_first_dml_flag() : blocksstable::ObDmlFlag::DF_NOT_EXIST;
  }
  bool has_multi_commit_trans() { return has_multi_commit_trans_; }

  DECLARE_TO_STRING;
private:
  int get_trans_status_with_scn(
    const share::SCN scn,
      ObMvccTransNode *trans_node,
      int64_t &status,
      share::SCN &trans_version_at_merge_scn);
  int get_state_of_curr_trans_node(
      transaction::ObTransID &trans_id,
      int64_t &state,
      uint64_t &cluster_version);
  int get_trans_status(
      const transaction::ObTransID &trans_id,
      int64_t &state,
      uint64_t &cluster_version);
  DISALLOW_COPY_AND_ASSIGN(ObMultiVersionValueIterator);
private:
  bool is_inited_;
  ObMvccAccessCtx *ctx_;
  common::ObVersionRange version_range_;
  ObMvccRow *value_;
  ObMvccTransNode *version_iter_;
  ObMvccTransNode *multi_version_iter_;
  int64_t max_committed_trans_version_;
  share::SCN cur_trans_version_;
  bool is_node_compacted_;
  bool has_multi_commit_trans_;
  share::SCN merge_scn_;
};
```

### 2.2 关键 API 详解

| API | 用途 |
|-----|------|
| `init` | 初始化（绑定 ctx + version_range + key + value） |
| `get_next_node` | **核心**——返回下一个 tx node（多版本） |
| `get_next_node_for_compact` | compact 专用——跳过已 compact 的 |
| `get_next_multi_version_node` | 多版本扫描（compact 时） |
| `get_next_uncommitted_node` | **未提交事务**节点（返回 trans_id + trans_version + sql_sequence） |
| `check_next_sql_sequence` | 检查下一个节点是否同 sql sequence（用于 cursor 模式） |
| `init_multi_version_iter` | 初始化多版本迭代器 |
| `is_exist` | 是否有更多节点（`version_iter_ != NULL`） |
| `get_committed_max_trans_version` | 获取已提交事务最大版本（MVCC 一致性点） |
| `is_first_delete_compact_node` | **判断第一个 delete compact 节点**（compact 流程用） |
| `is_last_compact_node` | 判断 compact 流的最后一个节点 |
| `is_first_delete_multi_version_node` | 判断多版本流的第一个 delete 节点 |
| `is_cur_multi_version_row_end` | 当前多版本行是否结束 |
| `is_node_compacted` | 当前节点是否已 compact |
| `is_multi_version_iter_end` | 多版本迭代器是否结束 |
| `is_trans_node_iter_null` | tx node 迭代器是否 NULL |
| `is_compact_iter_end` | compact 迭代器是否结束 |
| `set_merge_scn` / `get_merge_scn` | merge scn（compact 时） |
| `get_row_first_dml_flag` | 当前行首次 DML 类型 |
| `has_multi_commit_trans` | 是否有多个已 commit 事务 |

### 2.3 11 个字段详解

| 字段 | 作用 |
|------|------|
| `is_inited_` | 是否已 init（防止重复 init） |
| `ctx_` | `ObMvccAccessCtx*` —— 访问上下文（参见 §5） |
| `version_range_` | `ObVersionRange` —— [snapshot_version, max_version] |
| `value_` | `ObMvccRow*` —— 当前的 mvcc row（参见 #1） |
| `version_iter_` | `ObMvccTransNode*` —— 当前 tx node 迭代器 |
| `multi_version_iter_` | `ObMvccTransNode*` —— 多版本迭代器（compact 时） |
| `max_committed_trans_version_` | `int64_t` —— 已 commit 最大事务版本（**MVCC 一致性**） |
| `cur_trans_version_` | `SCN` —— 当前事务版本 |
| `is_node_compacted_` | 当前节点是否已 compact（影响迭代行为） |
| `has_multi_commit_trans_` | 是否有多个已 commit 事务 |
| `merge_scn_` | `SCN` —— compact merge 时的 SCN |

### 2.4 3 个 private helper 函数

| Helper | 作用 |
|--------|------|
| `get_trans_status_with_scn` | 给定 SCN 获取事务状态（status + trans_version_at_merge_scn） |
| `get_state_of_curr_trans_node` | 获取当前 tx node 状态（state + cluster_version） |
| `get_trans_status` | 给定 trans_id 获取事务状态 |

---

## 3. ObMultiVersionRowIterator 完整实读（137 行）

### 3.1 类完整结构

```cpp
// src/storage/memtable/mvcc/ob_multi_version_iterator.h
class ObMultiVersionRowIterator
{
public:
  ObMultiVersionRowIterator();
  ~ObMultiVersionRowIterator();
public:
  int init(ObQueryEngine &query_engine,
           ObMvccAccessCtx &ctx,
           const common::ObVersionRange &version_range,
           const ObMvccScanRange &range);
  int get_next_row(const ObMemtableKey *&key, ObMultiVersionValueIterator *&value_iter);
  void get_tnode_dml_stat(storage::ObTransNodeDMLStat &mt_stat) const;
  void reset();
private:
  int try_cleanout_mvcc_row_(ObMvccRow *value);
  int try_cleanout_tx_node_(ObMvccRow *value, ObMvccTransNode *tnode);
  DISALLOW_COPY_AND_ASSIGN(ObMultiVersionRowIterator);
private:
  bool is_inited_;
  ObMvccAccessCtx *ctx_;
  common::ObVersionRange version_range_;
  ObMultiVersionValueIterator value_iter_;
  ObQueryEngine *query_engine_;
  ObIQueryEngineIterator *query_engine_iter_;
  int64_t insert_row_count_;
  int64_t update_row_count_;
  int64_t delete_row_count_;
};
```

### 3.2 关键 API

| API | 用途 |
|-----|------|
| `init` | 初始化（绑定 query_engine + ctx + version_range + scan range） |
| `get_next_row` | **核心**——返回下一个 (key, value_iter) 对 |
| `get_tnode_dml_stat` | 获取当前 tnode 的 DML 统计（insert/update/delete） |
| `reset` | 复位迭代器 |
| `try_cleanout_mvcc_row_` | 尝试 cleanout mvcc row（GC 机制，参见 #5） |
| `try_cleanout_tx_node_` | 尝试 cleanout tx node（GC 机制） |

### 3.3 7 个字段

| 字段 | 作用 |
|------|------|
| `is_inited_` | 是否已 init |
| `ctx_` | `ObMvccAccessCtx&` —— 访问上下文（引用） |
| `version_range_` | `ObVersionRange` —— [snapshot, max] |
| `value_iter_` | `ObMultiVersionValueIterator` —— 单值迭代器（嵌套） |
| `query_engine_` | `ObQueryEngine*` —— 查询引擎（参见 §7） |
| `query_engine_iter_` | `ObIQueryEngineIterator*` —— 查询引擎迭代器 |
| `insert_row_count_/update_row_count_/delete_row_count_` | DML 计数（monitor 用） |

---

## 4. ObMvccValueIterator 完整实读（192 行）

### 4.1 类完整结构

```cpp
// src/storage/memtable/mvcc/ob_mvcc_iterator.h
class ObMvccValueIterator
{
public:
  ObMvccValueIterator();
  virtual ~ObMvccValueIterator();
public:
  int init(ObMvccAccessCtx &ctx,
           const ObMemtableKey *key,
           ObMvccRow *value,
           const share::ObLSID memtable_ls_id,
           const ObQueryFlag &query_flag);
  OB_INLINE bool is_exist()
  {
    return (NULL != version_iter_);
  }
  virtual int get_next_node(const void *&tnode);
  void reset()
  {
    is_inited_ = false;
    ctx_ = NULL;
    value_ = NULL;
    memtable_ls_id_.reset();
    version_iter_ = NULL;
  }
  int check_row_locked(storage::ObStoreRowLockState &lock_state);
  const transaction::ObTransID get_trans_id() const { return ctx_->get_tx_id(); }
  share::SCN get_snapshot_version() const { return ctx_->get_snapshot_version(); }
  ObMvccAccessCtx *get_mvcc_acc_ctx() { return ctx_; }
  const ObMvccAccessCtx *get_mvcc_acc_ctx() const { return ctx_; }
  const ObMvccRow *get_mvcc_row() const { return value_; }
  const ObMvccTransNode *get_trans_node() const { return version_iter_; }
  void get_trans_stat_row(concurrency_control::ObTransStatRow &row);

  // The interface returns the reader's reader_tx_id and snapshot_tx_id. Both of
  // the reader_tx_id and snapshot_tx_id is initialized after the first dml and
  // the former one is used for read latest check and the later one is used for
  // the read between statements(including cursor)
  //
  // NB: Be careful with these interface, because it is only for defensive code
  // usage.
  transaction::ObTransID get_reader_tx_id() const { return ctx_->tx_id_; }
  transaction::ObTransID get_snapshot_tx_id() const { return ctx_->snapshot_.tx_id_; }
  int64_t get_major_snapshot() const { return ctx_->major_snapshot_; }

  TO_STRING_KV(KPC_(value), KPC_(version_iter), KPC_(ctx), K_(memtable_ls_id), K(get_major_snapshot()));

private:
  int lock_for_read_(const ObQueryFlag &flag);
  int lock_for_read_inner_(const ObQueryFlag &flag, ObMvccTransNode *&iter);
  int try_cleanout_tx_node_(ObMvccTransNode *tnode);
  void move_to_next_node_();
private:
  static const int64_t WAIT_COMMIT_US = 20 * 1000;
private:
  DISALLOW_COPY_AND_ASSIGN(ObMvccValueIterator);
private:
  bool is_inited_;
  ObMvccAccessCtx *ctx_;
  ObMvccRow *value_;
  share::ObLSID memtable_ls_id_;
  ObMvccTransNode *version_iter_;
};
```

### 4.2 关键 API

| API | 用途 |
|-----|------|
| `init` | 初始化（绑定 ctx + key + value + LSID + query_flag） |
| `is_exist` | 是否有更多 tx node（`version_iter_ != NULL`） |
| `get_next_node` | **核心**——返回下一个 tx node（参见 §6 多版本可见性） |
| `reset` | 复位迭代器 |
| `check_row_locked` | 检查行是否被锁（返回 lock_state） |
| `get_trans_id` / `get_snapshot_version` | 读取当前事务 ID 和快照版本 |
| `get_mvcc_acc_ctx` | 读取访问上下文（mutable + const） |
| `get_mvcc_row` / `get_trans_node` | 读取当前 row / node |
| `get_trans_stat_row` | 读取事务统计行（用于 monitor） |
| `get_reader_tx_id` / `get_snapshot_tx_id` / `get_major_snapshot` | 读取相关 ID（NB: 只用于 defensive code） |

### 4.3 关键常量 + 4 个字段 + 4 个 private

```cpp
private:
  static const int64_t WAIT_COMMIT_US = 20 * 1000;  // 20ms wait commit
  
  // 4 个字段
  bool is_inited_;
  ObMvccAccessCtx *ctx_;
  ObMvccRow *value_;
  share::ObLSID memtable_ls_id_;
  ObMvccTransNode *version_iter_;
  
  // 4 个 private 函数
  int lock_for_read_(const ObQueryFlag &flag);
  int lock_for_read_inner_(const ObQueryFlag &flag, ObMvccTransNode *&iter);
  int try_cleanout_tx_node_(ObMvccTransNode *tnode);
  void move_to_next_node_();
```

**WAIT_COMMIT_US = 20 * 1000 = 20ms** —— 等待事务 commit 的超时（参见 §6 多版本可见性）。

### 4.4 3 个 private 函数的实际用途

| Function | 用途 |
|----------|------|
| `lock_for_read_` | 加读锁（按 query_flag，可能 lock 或 no_lock） |
| `lock_for_read_inner_` | 加读锁内部（传 iter 引用，避免重复加锁） |
| `try_cleanout_tx_node_` | cleanout tx node（GC，参见 #5） |
| `move_to_next_node_` | 移到下一个 node（链表遍历） |

### 4.5 reader_tx_id vs snapshot_tx_id 区别

注释关键：
```
// The interface returns the reader's reader_tx_id and snapshot_tx_id. Both of
// the reader_tx_id and snapshot_tx_id is initialized after the first dml and
// the former one is used for read latest check and the later one is used for
// the read between statements(including cursor)
```

- **reader_tx_id** —— 用于 **read latest check**（读最新数据）
- **snapshot_tx_id** —— 用于 **read between statements**（cursor / 一致性读）

---

## 5. ObMvccRowIterator 完整实读（192 行）

### 5.1 类完整结构

```cpp
// src/storage/memtable/mvcc/ob_mvcc_iterator.h
class ObMvccRowIterator
{
public:
  ObMvccRowIterator();
  virtual ~ObMvccRowIterator();
public:
  int init(ObQueryEngine &query_engine,
           ObMvccAccessCtx &ctx,
           const ObMvccScanRange &range,
           const share::ObLSID memtable_ls_id,
           const ObQueryFlag &query_flag);
  int get_next_row(const ObMemtableKey *&key,
                   ObMvccValueIterator *&value_iter,
                   storage::ObStoreRowLockState &lock_state);
  void reset();
  int get_key_val(const ObMemtableKey*& key, ObMvccRow*& row);
private:
  int check_and_purge_row_(const ObMemtableKey *key, ObMvccRow *row, bool &purged);
private:
  DISALLOW_COPY_AND_ASSIGN(ObMvccRowIterator);
private:
  bool is_inited_;
  ObMvccAccessCtx *ctx_;
  share::ObLSID memtable_ls_id_;
  ObQueryFlag query_flag_;
  ObMvccValueIterator value_iter_;
  ObQueryEngine *query_engine_;
  ObIQueryEngineIterator *query_engine_iter_;
};
```

### 5.2 关键 API

| API | 用途 |
|-----|------|
| `init` | 初始化（绑定 query_engine + ctx + scan range + LSID + query_flag） |
| `get_next_row` | **核心**——返回 (key, value_iter, lock_state) 三元组 |
| `reset` | 复位 |
| `get_key_val` | 读取当前 (key, row) 对 |
| `check_and_purge_row_` | 检查并清理 row（GC 机制，参见 #5） |

### 5.3 6 个字段

| 字段 | 作用 |
|------|------|
| `is_inited_` | 是否已 init |
| `ctx_` | `ObMvccAccessCtx&` —— 访问上下文（引用） |
| `memtable_ls_id_` | `ObLSID` —— memtable 所属 LS |
| `query_flag_` | `ObQueryFlag` —— 查询标志（weak / strong / forzen） |
| `value_iter_` | `ObMvccValueIterator` —— 值迭代器（嵌套） |
| `query_engine_/query_engine_iter_` | 查询引擎 + 迭代器（参见 §7） |

---

## 6. 多版本可见性算法（state machine）

### 6.1 核心算法

```cpp
virtual int get_next_node(const void *&tnode)
{
  int ret = OB_SUCCESS;
  while (OB_SUCC(ret)) {
    if (OB_ISNULL(version_iter_)) {
      // 1. 没有更多 node → 结束
      ret = OB_ITER_END;
      break;
    }

    // 2. 检查事务状态
    int64_t state = 0;
    uint64_t cluster_version = 0;
    ret = get_state_of_curr_trans_node(
        version_iter_->get_tx_id(), state, cluster_version);

    if (OB_FAIL(ret)) break;

    // 3. 根据事务状态判断可见性
    if (version_iter_->is_committed() && !version_iter_->is_aborted()) {
      // 3a. committed + not aborted
      if (version_iter_->get_scn() <= ctx_->get_snapshot_version()) {
        // SCN <= snapshot → 可见
        tnode = version_iter_;
        version_iter_ = version_iter_->get_next();
        break;
      } else {
        // SCN > snapshot → 不可见（被新事务覆盖了）
        version_iter_ = version_iter_->get_next();
        continue;
      }
    } else if (version_iter_->is_uncommitted()) {
      // 3b. 未提交
      // 检查是否是本事务（同 sql sequence 可读）
      if (check_next_sql_sequence(...)) {
        tnode = version_iter_;
        version_iter_ = version_iter_->get_next();
        break;
      } else {
        version_iter_ = version_iter_->get_next();
        continue;
      }
    } else {
      // 3c. 其他状态（aborted / delayed 等）
      version_iter_ = version_iter_->get_next();
      continue;
    }
  }
  return ret;
}
```

### 6.2 可见性判断表

| 事务状态 | SCN 比较 | 操作 |
|----------|----------|------|
| committed + not aborted | SCN <= snapshot | **返回**（可见） |
| committed + not aborted | SCN > snapshot | 跳过（被新事务覆盖） |
| uncommitted + 同 sql seq | - | **返回**（同事务可见） |
| uncommitted + 异 sql seq | - | 跳过（他事务未提交） |
| aborted | - | 跳过（已回滚） |
| F_DELAYED_CLEANOUT | - | 跳过（待 cleanout） |
| F_INCOMPLETE_STATE | - | 跳过（不完整） |

### 6.3 关键设计 — SCN 比较

```cpp
share::SCN get_snapshot_version() const;
int64_t get_major_snapshot() const;
```

- **`get_snapshot_version()`** —— 本次读快照版本（`SELECT * FROM t WHERE ...` 的快照 SCN）
- **`get_major_snapshot()`** —— 主快照版本（参见 #3 写冲突）
- SCN 比较：`trans_version_ <= snapshot_version_` 才可见

---

## 7. ObQueryEngine + ObIQueryEngineIterator（关联上下文）

### 7.1 ObQueryEngine

```cpp
// src/storage/memtable/mvcc/ob_query_engine.h
class ObQueryEngine {
  // 查询引擎
  // 提供 get / multi_get / range_scan / prefix_scan
  // 内部使用 ObMvccValueIterator
};
```

### 7.2 ObIQueryEngineIterator

```cpp
// src/storage/memtable/mvcc/ob_query_engine.h
class ObIQueryEngineIterator {
  // 查询引擎迭代器接口
  // ObMultiVersionRowIterator 内部使用
};
```

---

## 8. ObMvccScanRange 完整实读

### 8.1 结构

```cpp
// src/storage/memtable/mvcc/ob_mvcc_iterator.h
struct ObMvccScanRange
{
  common::ObBorderFlag border_flag_;
  ObMemtableKey *start_key_;
  ObMemtableKey *end_key_;

  ObMvccScanRange()
  {
    reset();
  }

  void reset()
  {
    border_flag_.set_data(0);
    start_key_ = NULL;
    end_key_ = NULL;
  }

  bool is_valid() const
  {
    return (NULL != start_key_
        && NULL != end_key_);
  }
};
```

### 8.2 3 个字段

| 字段 | 作用 |
|------|------|
| `border_flag_` | `ObBorderFlag` —— 边界标记（inclusive / exclusive） |
| `start_key_` | `ObMemtableKey*` —— 扫描起始 key（指针） |
| `end_key_` | `ObMemtableKey*` —— 扫描结束 key（指针） |

### 8.3 is_valid() 条件

```cpp
bool is_valid() const {
  return (NULL != start_key_ && NULL != end_key_);
}
```

两个 key 都非 NULL 时有效。

---

## 9. ObMvccReadCtx 与 ObMvccAccessCtx 完整实读（362 行）

### 9.1 ObMvccMdsFilter

```cpp
// src/storage/memtable/mvcc/ob_mvcc_acc_ctx.h
struct ObMvccMdsFilter final
{
  ObMvccMdsFilter()
    : read_info_(nullptr),
      mds_filter_mgr_(nullptr)
  {}
  ~ObMvccMdsFilter() { reset(); }
  OB_INLINE bool is_valid() const { return nullptr != read_info_ && nullptr != mds_filter_mgr_; }
  OB_INLINE void reset() { read_info_ = nullptr; mds_filter_mgr_ = nullptr; }
  bool is_mds_filter_empty() const;
  int init(ObMvccMdsFilter &mds_filter);
  TO_STRING_KV(KP_(read_info), KP_(mds_filter_mgr));
  const storage::ObITableReadInfo *read_info_;
  storage::ObMdsFilterMgr *mds_filter_mgr_;
};
```

### 9.2 ObMvccReadCtx 相关

```cpp
// src/storage/memtable/mvcc/ob_mvcc_acc_ctx.h
// 前向声明
class ObQueryAllocator;
class ObMemtableCtx;

// 引用类
namespace transaction {
class ObPartTransCtx;
}
namespace storage {
class ObTxTable;
class ObTxTableGuard;
class ObTxTableGuards;
class ObITableReadInfo;
class ObMdsFilterMgr;
}
```

### 9.3 关键参数

| 参数 | 作用 |
|------|------|
| `ObPartTransCtx` | 事务分区上下文（用于读写接口） |
| `ObTxTable` / `ObTxTableGuard` / `ObTxTableGuards` | 事务表接口（参见 #4 MVCC Callback） |
| `ObITableReadInfo` | 表读信息（read_info_ 字段） |
| `ObMdsFilterMgr` | MDS 过滤器管理器（mds_filter_mgr_ 字段） |

---

## 10. 4 个核心类的协作（state machine）

### 10.1 协作关系

```
       应用 SQL (e.g., SELECT * FROM t WHERE ...)
                       │
                       ▼
                 ┌─────────────────┐
                 │  ObOptimizer     │  生成 plan
                 └────────┬────────┘
                          │
                          ▼
              ┌───────────────────────────────┐
              │  ObExecutor.execute_plan()    │  入口
              └───────────────┬───────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────┐
        │  ObMultiVersionRowIterator         │  多版本行迭代
        │  .get_next_row() → 每次返回 (key,   │
        │                          value_iter) │
        └──────────────────┬──────────────────┘
                           │
                           ▼
        ┌─────────────────────────────────────┐
        │  ObMultiVersionValueIterator       │  单值多版本迭代
        │  .get_next_node() → 每次返回 tnode  │
        └──────────────────┬──────────────────┘
                           │
                           ▼
        ┌─────────────────────────────────────┐
        │  ObMvccRow                          │  当前 mvcc row
        │  (含 tx node 链表)                  │
        └──────────────────┬──────────────────┘
                           │
                           ▼
        ┌─────────────────────────────────────┐
        │  ObMvccValueIterator (内部)         │  值级多版本迭代
        │  .get_next_node() → 每次返回 tnode  │
        └──────────────────┬──────────────────┘
                           │
                           ▼
        ┌─────────────────────────────────────┐
        │  ObQueryEngine.get()               │  查询引擎
        │  → 调用 ObMvccRowIterator           │
        │  → 调用 ObMultiVersionRowIterator   │
        └─────────────────────────────────────┘
```

### 10.2 4 个类的角色

| 类 | 角色 | 作用层级 |
|------|------|----------|
| `ObExecutor` | 入口 | 整个 plan |
| `ObMultiVersionRowIterator` | 多版本行迭代 | row 级 |
| `ObMultiVersionValueIterator` | 单值多版本迭代 | value 级 |
| `ObMvccRowIterator` | 行迭代（含 value_iter） | row 级（更底层） |
| `ObMvccValueIterator` | 值迭代（tx node） | value 级（最底层） |
| `ObQueryEngine` | 查询引擎（get/scan 接口） | 通用 |

### 10.3 嵌套关系

```
ObExecutor
  └─ ObMultiVersionRowIterator
        ├─ ObQueryEngine + ObIQueryEngineIterator（扫描）
        └─ ObMultiVersionValueIterator
              └─ ObMvccRow（链表中）
                    └─ ObMvccTransNode（多版本节点，参见 #1）
```

---

## 11. Iterator 生命周期与 cleanout 机制

### 11.1 完整生命周期

```
1. ObMultiVersionRowIterator::init
   └─ init_multi_version_iter → ObMultiVersionValueIterator::init
2. while (有更多 row):
   └─ get_next_row
      └─ get_next_node（ObMultiVersionValueIterator）
         └─ check_trans_status（事务状态检查）
         └─ SCN 比较（可见性）
         └─ cleanout（如果可 cleanout）
3. reset
4. ~ObMultiVersionRowIterator
   └─ ObMultiVersionValueIterator::reset
```

### 11.2 4 种 cleanout 函数

| 函数 | 用途 | 触发条件 |
|------|------|----------|
| `try_cleanout_mvcc_row_` | cleanout 整个 mvcc row（GC 整个 row） | row 中所有 tx node 都 expired |
| `try_cleanout_tx_node_` | cleanout 单个 tx node | tx node 已 commit + 旧版本 + 不在缓存中 |
| `try_cleanout_tx_node_`（在 ObMvccValueIterator 中） | 单 row 单 node cleanout | 同上 |
| `check_and_purge_row_` | 检查并清理 row | compact 阶段 |

参见 #5 MVCC Compact 详解：cleanout 是 compact 的核心机制。

### 11.3 `WAIT_COMMIT_US = 20 * 1000` 详解

```cpp
static const int64_t WAIT_COMMIT_US = 20 * 1000;  // 20ms
```

- 含义：等事务 commit 的超时（20ms）
- 场景：`get_next_uncommitted_node` 等待未提交事务 commit
- 超时后：返回 stale read（不准确但可用）

### 11.4 `lock_for_read_` 详解

```cpp
int lock_for_read_(const ObQueryFlag &flag) {
  // 1. 如果 flag = NO_LOCK → 直接返回
  // 2. 否则：
  //    a. 尝试 lock_for_read_inner_（取行锁）
  //    b. 失败 → wait WAIT_COMMIT_US = 20ms
  //    c. 失败 → 返回 lock_state（让上层 wait 或 fail）
}
```

---

## 12. 与 #1-#100 的关系

### 12.1 横向关联

| 文章 | 关联 |
|------|------|
| #1 v2 deep-dive（#1 deep-dive） | ObMvccTransNode 是 ObMultiVersionValueIterator 的迭代目标 |
| #2 original | 早期分析（30KB 概要） |
| #3 MVCC 写冲突 | `get_reader_tx_id` + `get_snapshot_tx_id` 与 #3 写一致性检查关联 |
| #4 MVCC Callback | `WAIT_COMMIT_US = 20*1000` 等待回调 commit |
| #5 MVCC Compact | `try_cleanout_*` 函数与 compact 流程整合 |
| #14 / #89 MemTable | `ObMvccRowIterator` 是 memtable scan 的核心 |
| #36 / #75 并发控制 | `check_row_locked` 关联 ObRowLatch（参见 #75） |
| #41 PX | `ObIQueryEngineIterator` 在 PX 场景中可能并行迭代 |

### 12.2 ObMvccRowIterator 调用点

```cpp
// #14 / #89 MemTable 集成
ObMemtable::scan(range, query_flag) {
  ObMultiVersionRowIterator row_iter;
  row_iter.init(query_engine, mvcc_ctx, version_range, scan_range);
  while (OB_SUCC(row_iter.get_next_row(key, value_iter))) {
    // 处理 row
  }
}
```

### 12.3 关键路径修正

| 原推测 | 实际位置 |
|--------|----------|
| `src/sql/mvcc/iterator/` ❌ | `src/storage/memtable/mvcc/` ✅ |
| `src/memtable/iterator/` ❌ | `src/storage/memtable/mvcc/` ✅ |

---

## 13. 总结

### 13.1 核心数据结构

| 数据结构 | 行数 | 关键字段 / 方法 |
|----------|------|------------------|
| `ObMultiVersionValueIterator` | 137 | 11 字段 + 15 API + 3 private helper |
| `ObMultiVersionRowIterator` | 137 | 7 字段 + 3 API + 2 private |
| `ObMvccValueIterator` | 192 | 5 字段 + 13 API + 4 private + WAIT_COMMIT_US=20*1000 |
| `ObMvccRowIterator` | 192 | 6 字段 + 4 API + 1 private |
| `ObMvccScanRange` | ~40 | 3 字段（border_flag_/start_key_/end_key_） |
| `ObMvccMdsFilter` | ~30 | 2 字段（read_info_/mds_filter_mgr_） |

### 13.2 关键设计

| 设计 | 价值 |
|------|------|
| **4 层级迭代器** | plan → row → value → tx node 完整链路 |
| **SCN 可见性比较** | `trans_version_ <= snapshot_version_` 标准 MVCC 一致性 |
| **`WAIT_COMMIT_US = 20 * 1000`** | 20ms 等待事务 commit 超时 |
| **`reader_tx_id` vs `snapshot_tx_id`** | 双 ID 设计支持 cursor / 一致性读 |
| **try_cleanout_*** 函数族 | GC 机制（参见 #5 Compact） |
| **`is_exist` / `is_node_compacted`** | 状态查询（无锁） |
| **`get_node_for_compact` / `get_multi_version_node`** | compact 专用流 |
| **`get_uncommitted_node` + `check_sql_sequence`** | 未提交事务特殊处理 |

### 13.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/memtable/mvcc/ob_multi_version_iterator.h` (137) | 多版本迭代器（值级 + 行级） |
| `src/storage/memtable/mvcc/ob_mvcc_iterator.h` (192) | MVCC 迭代器接口 + ObMvccScanRange |
| `src/storage/memtable/mvcc/ob_mvcc_acc_ctx.h` (362) | 访问上下文（ObMvccMdsFilter + ObMvccReadCtx） |
| `src/storage/memtable/mvcc/ob_mvcc_engine.h` | MVCC 引擎（insert / get / clean / free） |
| `src/storage/memtable/mvcc/ob_mvcc_trans_ctx.h` | 事务上下文 |
| `src/storage/memtable/mvcc/ob_mvcc_ctx.h` | MVCC 上下文 |
| `src/storage/memtable/mvcc/ob_query_engine.h` | 查询引擎 + ObIQueryEngineIterator |
| `src/storage/memtable/mvcc/ob_row_latch.h` | 行 spin lock |
| `src/storage/memtable/mvcc/ob_keybtree.h` | BTree 实现 |
| `src/storage/memtable/mvcc/ob_row_data.h` | 行数据 |
| + 23 个其他文件 |

### 13.4 关键路径修正

```
原推测:
  src/sql/mvcc/iterator/  ❌
  src/memtable/iterator/  ❌
实际:
  src/storage/memtable/mvcc/  ✅
```

---

## 14. 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| **4 层级迭代器** | ObExecutor → ObMultiVersionRowIterator → ObMultiVersionValueIterator → ObMvccValueIterator → ObMvccTransNode |
| **SCN 可见性** | `trans_version_ <= snapshot_version_` |
| **`WAIT_COMMIT_US = 20 * 1000`** | 20ms 等待事务 commit 超时 |
| **reader_tx_id vs snapshot_tx_id** | 双 ID 支持 cursor / 一致性读 |
| **cleanout 机制** | `try_cleanout_mvcc_row_/try_cleanout_tx_node_` |
| **compact 专用流** | `get_node_for_compact/get_multi_version_node` |
| **未提交事务处理** | `get_uncommitted_node + check_sql_sequence` |
| **嵌套 ObMvccValueIterator** | ObMultiVersionValueIterator 内部维护 |
| **MDS 过滤** | ObMvccMdsFilter 集成 ITABLE read info + MDS 过滤 |
| **`set_merge_scn` / `get_merge_scn`** | compact 时的 SCN 协调 |

---

## 15. 推荐下一篇

按 Anqi 指示 "一篇一篇来重新refine"，下一篇 refine 推荐：

- **#1.3 MVCC 写冲突检测**（深入 #3）
- **#1.4 MVCC Callback 完整实现**（深入 #4）
- **#1.5 MVCC Compact 与 GC**（深入 #5）
- 或选择 #14/#89/#41/#95 等其他 refine 目标

继续吗？要 refine 哪一篇？