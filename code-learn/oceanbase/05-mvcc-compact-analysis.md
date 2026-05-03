# 05-mvcc-compact — OceanBase MVCC 版本链的 compaction 与 GC 机制

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

MVCC 的核心优势是读写不互斥，但代价是**版本链会无限增长**。每次写操作（INSERT / UPDATE / DELETE）都在 `ObMvccRow::list_head_` 头部插入一个 `ObMvccTransNode`，链上累积的旧版本越多，遍历读取的性能就越差。

**Compaction（版本链压缩）** 就是解决这个问题的：将多个已提交、对当前快照已不可见的旧版本合并成一个**全列 NDT_COMPACT 节点**，从而缩短版本链长度。

OceanBase 的 compaction 是 **lazy（惰性）的**：它不在写路径上立即压缩，而是等版本链长度超过阈值后，在**读路径或提交路径上顺带触发**。这与 PostgreSQL 的 VACUUM 和 InnoDB 的 purge 有本质区别——后者通常是专用后台线程驱动，而 OceanBase 的 compact 就在普通请求路径上同步完成。

**doom-lsp 确认**：核心代码分布在 4 个文件中：
| 文件 | 行数 | 职责 |
|------|------|------|
| `storage/memtable/mvcc/ob_mvcc_row.h` | ~490 | `ObMvccRow` compact 相关字段与方法声明 |
| `storage/memtable/mvcc/ob_mvcc_row.cpp` | ~1200+ | `need_compact`, `row_compact`, `unlink_trans_node`, `mvcc_undo` |
| `storage/memtable/ob_row_compactor.h` | ~75 | `ObMemtableRowCompactor` 类声明 |
| `storage/memtable/ob_row_compactor.cpp` | ~400 | compact 主体逻辑 |

---

## 1. 核心数据结构

### 1.1 `ObMvccRow` 的 compact 相关字段

```c
// ob_mvcc_row.h:277-330 - doom-lsp 确认
struct ObMvccRow
{
  // ════════ 压缩统计 ════════
  int32_t        update_since_compact_;   // @L317 — 上次压缩后的更新次数
  int64_t        total_trans_node_cnt_;   // @L319 — 版本节点总数
  int64_t        latest_compact_ts_;      // @L320 — 最近一次压缩时间戳
  int64_t        last_compact_cnt_;       // @L321 — 最近一次压缩时合并的节点数

  // ════════ 版本链指针 ════════
  ObMvccTransNode *list_head_;            // @L328 — 最新版本（链表头）
  ObMvccTransNode *latest_compact_node_;  // @L329 — 最近压缩的节点（加速下次压缩的起始搜索）

  // ...
};
```

#### `update_since_compact_` — 压缩触发计数器

这个字段是整个 compact 机制的**触发扳机**。每次事务成功提交时递增：

```c
// ob_mvcc_trans_ctx.cpp:1965 - doom-lsp 确认
(void)ATOMIC_FAA(&value_.update_since_compact_, 1);
```

`ObMvccRow::reset()` 初始化为 0（doom-lsp @ L325）。

#### `latest_compact_node_` — 压缩进度指针

记录最近一次 compact 生成的 NDT_COMPACT 节点地址。下次 compact 时从该节点开始向后搜索，避免重复遍历已压缩的旧版本。初始化为 NULL（doom-lsp @ L330）。

注意方向的含义：`prev_` 指向**更旧**的版本，`next_` 指向**更新**的版本。`latest_compact_node_` 是链上最新的 compact 节点，在其 `prev_` 方向（更旧）的所有节点都已压缩完毕。

### 1.2 `NDT_COMPACT` 节点类型

```c
// ob_mvcc_row.h:40-41 - doom-lsp 确认
static const uint8_t NDT_NORMAL = 0x0;   // 普通版本节点（只保存增量列）
static const uint8_t NDT_COMPACT = 0x1;  // 压缩节点（全列合并）
```

`ObMvccTransNode` 的 `type_` 字段（doom-lsp @ L163）标识节点类型。NDT_COMPACT 节点与其他版本节点**共享同一个结构体** `ObMvccTransNode`，区别在于：

- **NDT_NORMAL**: 只保存增量列（更新的列），通过 `ObDatumRow` 读取时需要与前一版本合并
- **NDT_COMPACT**: 包含行的所有列（全列），读取时无需与前一版本合并

```c
// ob_row_compactor.cpp:299-306 - doom-lsp 确认
new(trans_node) ObMvccTransNode();
trans_node->tx_id_ = save->tx_id_;          // 继承 save 节点的事务 ID
trans_node->seq_no_ = save->seq_no_;        // 继承 save 节点的序列号
trans_node->trans_version_ = save->trans_version_;  // 使用最新的提交版本
trans_node->modify_count_ = save->modify_count_;    // 继承修改次数
trans_node->acc_checksum_ = save->acc_checksum_;    // 继承校验和
trans_node->version_ = save->version_;      // 继承版本号
trans_node->type_ = NDT_COMPACT;            // ★ 标记为压缩类型
trans_node->set_saved_flag(save->get_flag());       // 继承状态标志
trans_node->scn_ = save->scn_;              // 继承 SCN
trans_node->set_snapshot_version_barrier(snapshot_version, flag);  // 设置快照版本屏障
```

### 1.3 `snapshot_version_barrier` — 可见性屏障

压缩节点上带有一个 `snapshot_version_barrier`，用于防止并发读操作访问已压缩版本的**前置版本**（即比 compact node 还旧的节点，应该已经被压缩了）。

```c
// ob_mvcc_row.h:266-269 - doom-lsp 确认
#f NORMAL_READ_BIT         // @L266
#f WEAK_READ_BIT           // @L267
#f COMPACT_READ_BIT        // @L268
#f SNAPSHOT_VERSION_BARRIER_BIT  // @L269
```

在 `construct_compact_node_` 中调用 `set_snapshot_version_barrier(snapshot_version, flag)` 设置屏障值。读迭代器遍历到 NDT_COMPACT 节点时，如果其 `snapshot_version_barrier >= snapshot_version`，说明该压缩节点之后（`next_` 方向）的节点才可见，无需继续向 `prev_` 方向搜索。

---

## 2. 触发路径：什么时候压缩？

Compaction 有三个触发入口，分别对应读路径、提交路径和回放路径。

### 2.1 读路径（`ObMvccEngine::get`）

```c
// ob_mvcc_engine.cpp:95 - doom-lsp 确认
for_read = true;
for_replay = false;
if (!query_flag.is_prewarm()
    && value->need_compact(for_read, for_replay, memtable_->is_delete_insert_table())) {
  int tmp_ret = OB_SUCCESS;
  if (OB_SUCCESS != (tmp_ret = try_compact_row_when_mvcc_read_(
                         ctx.get_snapshot_version(), *value))) {
    // ...
  }
}
```

`try_compact_row_when_mvcc_read_` 函数（doom-lsp 确认 @ L77）：

```c
// ob_mvcc_engine.cpp:77-104 - doom-lsp 确认
int ObMvccEngine::try_compact_row_when_mvcc_read_(const SCN &snapshot_version,
                                                   ObMvccRow &row)
{
  int ret = OB_SUCCESS;
  const int64_t latest_compact_ts = row.latest_compact_ts_;
  const int64_t WEAK_READ_COMPACT_THRESHOLD = 3 * 1000 * 1000;  // 3 秒冷却期

  if (SCN::max_scn() == snapshot_version
      || ObTimeUtility::current_time() < latest_compact_ts + WEAK_READ_COMPACT_THRESHOLD) {
    // 合并场景或 3 秒内刚压缩过则跳过
  } else {
    ObRowLatchGuard guard(row.latch_);  // ★ 读路径上需要持有行锁
    if (OB_FAIL(row.row_compact(memtable_, snapshot_version, engine_allocator_))) {
      // ...
    }
  }
}
```

**关键设计**：读路径上的 compact 持有 `ObRowLatch`（行锁），因为 concurrent_compaction 需要与写入互斥。但读路径本身（`lock_for_read_`）**不持有**行锁——这是并行安全的核心权衡。

### 2.2 提交路径（`ObMvccTransCtx::commit`）

```c
// ob_mvcc_trans_ctx.cpp:1963-1977 - doom-lsp 确认
(void)ATOMIC_FAA(&value_.update_since_compact_, 1);  // 递增更新计数器（doom-lsp @ L1965）

if (value_.need_compact(for_read=false,
                        ctx_.is_for_replay(),
                        memtable_->is_delete_insert_table())) {
  if (ctx_.is_for_replay()) {
    // 回放路径：使用 replay_compact_version 进行压缩
    memtable_->row_compact(&value_,
                           ctx_.get_replay_compact_version(),
                           ObMvccTransNode::WEAK_READ_BIT | ObMvccTransNode::COMPACT_READ_BIT);
  } else {
    // 普通提交路径：使用接近 max_scn 的快照版本
    SCN snapshot_version_for_compact = SCN::minus(SCN::max_scn(), 100);
    memtable_->row_compact(&value_,
                           snapshot_version_for_compact,
                           ObMvccTransNode::NORMAL_READ_BIT);
  }
}
```

**设计决策**：提交路径使用 `SCN::max_scn() - 100` 作为压缩快照版本。这相当于"所有已提交、版本号几乎最大的节点都压缩"。由于提交时持有行锁，这里不需要再额外加锁。

### 2.3 回放路径（Replay）

回放路径与提交路径共享代码入口。区别在于：
- `for_replay = true` 时，`need_compact` 的阈值更高（3x 正常阈值），因为备机压缩频率应更低
- 热点行场景（`index_ != NULL` 且 `for_replay`），阈值提升到 `max(2048, row_compaction_update_limit * 10)`
- 使用 `ctx_.get_replay_compact_version()` 而非 max_scn - 100

### 2.4 `need_compact` 的判断逻辑

```c
// ob_mvcc_row.cpp:473-496 - doom-lsp 确认
bool ObMvccRow::need_compact(const bool for_read,
                             const bool for_replay,
                             const bool is_delete_insert)
{
  if (is_delete_insert) return false;  // delete-insert 表不压缩

  bool bool_ret = false;
  const int32_t updates = ATOMIC_LOAD(&update_since_compact_);

  // 阈值 = for_read/for_replay 时是 3x 正常阈值
  const int32_t compact_trigger = (for_read || for_replay)
      ? ObServerConfig::get_instance().row_compaction_update_limit * 3
      : ObServerConfig::get_instance().row_compaction_update_limit;

  // 备机热点行：极高阈值
  if (NULL != index_ && for_replay) {
    if (updates >= max(2048, ObServerConfig::get_instance().row_compaction_update_limit * 10)) {
      bool_ret = ATOMIC_BCAS(&update_since_compact_, updates, 0);
    }
  } else if (updates >= compact_trigger) {
    bool_ret = ATOMIC_BCAS(&update_since_compact_, updates, 0);
  }

  return bool_ret;
}
```

**CAS loop 确保只有一个线程实际触发 compact**：`ATOMIC_BCAS(&update_since_compact_, updates, 0)` 在满足阈值时原子地将计数器置零，只有成功的线程才返回 true。其他竞争线程抢不到就直接跳过。

**阈值差异化**：
| 场景 | 阈值 | 原因 |
|------|------|------|
| 普通写提交 | `row_compaction_update_limit`（默认约 500） | 提交路径已持有行锁，代价低 |
| 读路径 | 3x 阈值 | 读路径上 compact 需要额外获取行锁，代价高 |
| 备机回放 + 热点行 | `max(2048, 10x 阈值)` | 备机应尽量少压缩热点行 |

---

## 3. 数据流：`row_compact` 完整执行过程

### 3.1 入口：`ObMvccRow::row_compact`

```c
// ob_mvcc_row.cpp:501-519 - doom-lsp 确认
int ObMvccRow::row_compact(ObMemtable *memtable,
                           const SCN snapshot_version,
                           ObIAllocator *node_alloc)
{
  int ret = OB_SUCCESS;
  ObMemtableRowCompactor row_compactor;
  if (OB_FAIL(row_compactor.init(this, memtable, node_alloc))) {
    // ...
  } else if (OB_FAIL(row_compactor.compact(snapshot_version,
                                           ObMvccTransNode::COMPACT_READ_BIT))) {
    // ...
  }
  return ret;
}
```

这是一个薄调度层，实际工作在 `ObMemtableRowCompactor::compact` 中。

`ObMemtable::row_compact`（ob_memtable.cpp:1587）也是一个类似的薄调度层，从提交和回放路径调用：

```c
// ob_memtable.cpp:1587-1609 - doom-lsp 确认
int ObMemtable::row_compact(ObMvccRow *row,
                            const SCN snapshot_version,
                            const int64_t flag)
{
  ObMemtableRowCompactor row_compactor;
  if (OB_FAIL(row_compactor.init(row, this, &local_allocator_))) {
    // ...
  } else if (OB_FAIL(row_compactor.compact(snapshot_version, flag))) {
    // ...
  }
  return ret;
}
```

### 3.2 `ObMemtableRowCompactor::compact` — 三步流程

```c
// ob_row_compactor.cpp:67-104 - doom-lsp 确认
int ObMemtableRowCompactor::compact(const SCN snapshot_version,
                                    const int64_t flag)
{
  // 防御性检查
  if (NULL != row_->latest_compact_node_
      && snapshot_version <= row_->latest_compact_node_->trans_version_) {
    // 已有压缩节点的版本 >= snapshot_version，无需重复压缩
    return ret;
  }

  ObMvccTransNode *start = NULL;

  // Step 1: 找到压缩起始位置
  find_start_pos_(snapshot_version, start);

  // Step 2: 从 start 开始向前遍历，合并所有可见已提交版本为 NDT_COMPACT 节点
  ObMvccTransNode *compact_node = construct_compact_node_(snapshot_version, flag, start);

  // Step 3: 将 compact_node 插入版本链（start 之前）
  if (OB_NOT_NULL(compact_node)) {
    insert_compact_node_(compact_node, start);
  }

  return ret;
}
```

#### Step 1: `find_start_pos_` — 定位压缩起点

```c
// ob_row_compactor.cpp:110-157 - doom-lsp 确认
void ObMemtableRowCompactor::find_start_pos_(const SCN snapshot_version,
                                             ObMvccTransNode *&start)
{
  // 首次压缩：从 list_head 开始向前（prev_ 方向）遍历
  // 后续压缩：从 latest_compact_node_ 开始向后（next_ 方向）遍历
  start = ((NULL == row_->latest_compact_node_)
           ? (row_->list_head_)
           : (row_->latest_compact_node_));

  while (NULL != start) {
    if (NULL == row_->latest_compact_node_) {
      // 首次压缩：从最新向最旧找第一个符合条件的节点
      // 条件：trans_version 已赋值（不是 max_scn）&& < snapshot_version && 已提交
      if (SCN::max_scn() == start->trans_version_
          || snapshot_version < start->trans_version_
          || !start->is_committed()) {
        start = start->prev_;
      } else {
        break;  // 找到符合条件的节点
      }
    } else {
      // 后续压缩：从 latest_compact_node_ 向更新方向找
      while (NULL != start->next_
             && snapshot_version >= start->next_->trans_version_
             && start->next_->is_committed()
             && SCN::max_scn() != start->next_->trans_version_) {
        start = start->next_;
      }
      break;
    }
  }
}
```

**方向解释**（doom-lsp 确认 `prev_` 指向更旧版本，`next_` 指向更新版本）：

首次 compact 时的搜索方向（`latest_compact_node_ == NULL`）：

```
list_head ──→ v5(最新) ──→ v4 ──→ v3 ──→ v2 ──→ v1(最旧)
                ↑ start      ↑        ↑
                (跳过未提交)  (跳过)  (找到符合条件的 → break)
```

后续 compact 时的搜索方向（`latest_compact_node_` 存在）：

```
             compact_node     v7 ──→ v6 ──→ v5 ──→ v4
               ↑                 ↑                    ↑
          latest_compact       start.next_          start
          start=v4 →
                 (v5 已提交且版本 < snapshot → start=v5)
```

#### Step 2: `construct_compact_node_` — 合并并构造 NDT_COMPACT 节点

```c
// ob_row_compactor.cpp:168-349 - doom-lsp 确认
ObMvccTransNode *ObMemtableRowCompactor::construct_compact_node_(
    const SCN snapshot_version,
    const int64_t flag,
    ObMvccTransNode *save)
{
  ObMvccTransNode *cur = save;
  ObDatumRow compact_datum_row;  // 合并后的全行数据
  ObDmlFlag dml_flag = ObDmlFlag::DF_NOT_EXIST;
  int64_t compact_row_cnt = 0;

  while (OB_SUCCESS == ret && NULL != cur) {
    // 1) 尝试清理未决定的节点（delayed cleanout）
    try_cleanout_tx_node_during_compact_(tx_table_guard, cur);

    // 2) 跳过已终止的节点
    if (cur->is_aborted()) { cur = cur->prev_; continue; }

    // 3) 跳过锁节点
    if (DF_LOCK == mtd->dml_flag_) { cur = cur->prev_; continue; }

    // 4) 遇到已有 NDT_COMPACT 节点 → 停止
    if (NDT_COMPACT == cur->type_) { ret = OB_ITER_END; break; }

    // 5) 遇到 DELETE 节点 → 停止（删除后的版本无需保留）
    if (DF_DELETE == mtd->dml_flag_) {
      dml_flag = DF_DELETE;
      compact_row_cnt++;
      ret = OB_ITER_END;
      break;
    }

    // 6) 合并列数据（只读取非 NOP 的列）
    for (int64_t i = 0; i < datum_row->get_column_count(); ++i) {
      if (compact_datum_row.storage_datums_[i].is_nop()) {
        compact_datum_row.storage_datums_[i] = datum_row->storage_datums_[i];
      }
    }
    compact_row_cnt++;
    cur = cur->prev_;  // 继续向前（更旧版本）
  }

  // 合并完成，构造 NDT_COMPACT 节点
  if (compact_row_cnt > 0) {
    trans_node->type_ = NDT_COMPACT;
    trans_node->trans_version_ = save->trans_version_;  // 使用最新版本的 commit ts
    trans_node->set_snapshot_version_barrier(snapshot_version, flag);
    // ... 填充其他字段
  }

  return trans_node;
}
```

**列合并逻辑**：NDT_NORMAL 节点只保存增量列（发生变化的列），未变化的列用 NOP 标记。`construct_compact_node_` 遍历多个版本，对每个列取第一个非 NOP 值，最终得到一个包含**所有列**的全量行。

**中止条件**：
- 遇到 NDT_COMPACT 节点：说明这些版本已经压缩过，停止
- 遇到 DELETE 节点：删除后的版本无需保留，停止
- 遇到未提交/未回滚的节点：防御性停止（`giveup_compaction = true`）

#### Step 3: `insert_compact_node_` — 将压缩节点插入版本链

```c
// ob_row_compactor.cpp:377-400 - doom-lsp 确认
void ObMemtableRowCompactor::insert_compact_node_(ObMvccTransNode *tx_node,
                                                   ObMvccTransNode *start)
{
  // 插入 compact_node 到 start 之前
  ATOMIC_STORE(&(tx_node->prev_), start);
  if (NULL == start->next_) {
    // start 是链表头（最新版本）
    ATOMIC_STORE(&(tx_node->next_), NULL);
    ATOMIC_STORE(&(row_->list_head_), tx_node);  // compact_node 成为新 head
  } else {
    // start 在链表中间
    ATOMIC_STORE(&(tx_node->next_), start->next_);
    ATOMIC_STORE(&(start->next_->prev_), tx_node);
  }
  ATOMIC_STORE(&(start->next_), tx_node);

  // 更新统计
  ATOMIC_STORE(&(row_->latest_compact_node_), tx_node);
  ATOMIC_STORE(&(row_->latest_compact_ts_), end_ts);
  ATOMIC_STORE(&(row_->last_compact_cnt_), tx_node->modify_count_);
  ATOMIC_STORE(&(row_->update_since_compact_), 0);  // 复位计数器
}
```

**插入位置**：compact_node 放在 start（合并的最新版本）的 `next_` 方向。从读视角看，所有在 compact_node 之前（`prev_` 方向）的版本已被合并，读迭代器遇到 compact_node 后可直接返回，无需继续向前搜索。

---

## 4. 版本节点的生命周期与状态机

```
                     ┌─────────────────┐
                     │    F_INIT       │  mvcc_write_ 创建的初始状态
                     │  (未决定状态)    │
                     └────────┬────────┘
                              │
                ┌─────────────┼─────────────┐
                ▼             ▼             ▼
          trans_commit   trans_abort    delayed_cleanout
                │             │             │
                ▼             ▼             ▼
         ┌──────────┐  ┌──────────┐  ┌──────────────┐
         │F_COMMITTED│  │F_ABORTED │  │F_DELAYED_   │
         │          │  │          │  │CLEANOUT      │
         └────┬─────┘  └────┬─────┘  └──────┬───────┘
              │             │               │
              │             │               ├──→ cleanout_tx_node → F_COMMITTED/F_ABORTED
              │             │               │
              ▼             ▼               ▼
        row_compact →  unlink_trans_node  unlink_trans_node
        NDT_COMPACT    (物理摘除)          (物理摘除)
              │
              ▼
        (保留在版本链上，但屏障后旧版本不再被读取)
```

### 4.1 `unlink_trans_node` — 物理摘除

```c
// ob_mvcc_row.cpp:400-472 - doom-lsp 确认
int ObMvccRow::unlink_trans_node(const ObMvccTransNode &node)
{
  ObMvccTransNode **prev = &list_head_;
  ObMvccTransNode *tmp = ATOMIC_LOAD(prev);

  if (is_server_serving) {
    // 正常服务期：从 list_head 开始遍历查找
    while (NULL != tmp && (&node) != tmp) {
      if (NDT_COMPACT == tmp->type_) {
        ret = OB_ERR_UNEXPECTED;  // 防御：不能摘除 compact 节点
      }
      prev = &(tmp->prev_);
      tmp = ATOMIC_LOAD(prev);
    }
  }

  // 双向链表摘除：prev->next = node.prev; node.prev->next = node.next
  ATOMIC_STORE(prev, ATOMIC_LOAD(&(node.prev_)));
  if (NULL != ATOMIC_LOAD(&(node.prev_))) {
    ATOMIC_STORE(&(node.prev_->next_), ATOMIC_LOAD(&(node.next_)));
  }

  // 更新 replay index（如果存在）
  for (int64_t i = 0; i < common::REPLAY_TASK_QUEUE_SIZE; ++i) {
    if (&node == index_->get_index_node(i)) {
      index_->set_index_node(i, ATOMIC_LOAD(&(node.prev_)));
    }
  }

  total_trans_node_cnt_--;  // 减少总节点计数
}
```

**调用者链**（doom-lsp / grep 确认）：
- `ObsMvccTransCtx::commit` → 提交后摘除 LOCK 节点（`DF_LOCK == get_dml_flag()`）
- `ObMvccRow::mvcc_undo` → 回滚时摘除链表头

**防御性检查**：`unlink_trans_node` 遇到 NDT_COMPACT 节点时返回 `OB_ERR_UNEXPECTED`。这是正确的——compact 节点不应被摘除，它应该一直保留在链上作为可见性屏障。

### 4.2 `mvcc_undo` — 回滚时的版本链操作

```c
// ob_mvcc_row.cpp:1031-1040 - doom-lsp 确认
void ObMvccRow::mvcc_undo()
{
  ObRowLatchGuard guard(latch_);  // 持有行锁
  ObMvccTransNode *iter = ATOMIC_LOAD(&list_head_);

  iter->trans_rollback();                  // 回调层面回滚
  ATOMIC_STORE(&(list_head_), iter->prev_);  // list_head 前移
  if (NULL != iter->prev_) {
    ATOMIC_STORE(&(iter->prev_->next_), NULL);  // 新 head 的 next_ 置 null
  }
  total_trans_node_cnt_--;
}
```

`mvcc_undo` 是**有行锁保护下的整体回滚操作**：
1. 对头部节点调用 `trans_rollback()` — 触发回调层面的回滚（撤销 callback 注册等）
2. 将 `list_head_` 指向上一版本 — 物理上"删除"当前最新节点
3. `total_trans_node_cnt_--` — 更新总节点计数

**与 `unlink_trans_node` 的区别**：
- `unlink_trans_node` 是通用的链表摘除，可以摘除**任意位置**的节点（通过遍历查找）
- `mvcc_undo` 是快速路径，只摘除链表头（最新写入的节点），无需遍历
- `mvcc_undo` 额外调用 `trans_rollback()` 处理回调，`unlink_trans_node` 不处理回调

---

## 5. 压缩前后版本链对比

### 5.1 压缩前

```
list_head → v5(NDT_NORMAL, UPDATE age=30, trans_v=150)
            │
            v4(NDT_NORMAL, UPDATE name='bob', trans_v=140)
            │
            v3(NDT_NORMAL, UPDATE age=25, trans_v=130)
            │
            v2(NDT_NORMAL, UPDATE email='a@b.com', trans_v=120)
            │
            v1(NDT_NORMAL, INSERT name='alice',age=20,email='a@c.com', trans_v=100)
```

假设 `snapshot_version = 200`，所有节点均已提交且版本 < 200。

### 5.2 压缩后

```
             compact_node(NDT_COMPACT, name='bob',age=30,email='a@b.com', trans_v=150)
              │        ↑
              │        │
              │      v1~v5 ──→ (这些节点的 prev_ 仍然指向更旧版本，
              │                但迭代器遇到 compact_node 即停止)
              │
list_head → ....
```

**关键点**：
- NDT_COMPACT 节点包含了从 v1 到 v5 所有列的最新值（全列合并）
- `trans_version_` 使用 v5 的最新提交版本（150）
- `set_snapshot_version_barrier(snapshot_version, flag)` 设置版本屏障
- 原节点 v1-v5 仍然存在于链表上（未被物理删除），但读路径遇到 compact_node 后不再向前搜索
- `latest_compact_node_` 指向 compact_node

### 5.3 读路径上的可见性决策

```
迭代器遍历方向（head → prev 方向）：

list_head → ... → v9(committed, 190)
                    v8(committed, 180)
                    compact_node(NDT_COMPACT, barrier=200, trans_v=150)
                    v5(committed, 150)
                    v4(committed, 140)
                    ...

如果 snapshot_version = 170：
  → 从 v9 遍历到 v8，v8 的 trans_v=180 < 170？不，180 > 170 → 跳过
  → v9 的 trans_v=190 > 170 → 跳过
  → v8 的 trans_v=180 > 170 → 跳过
  → compact_node: barrier=200 >= 170? 是 → 直接返回 compact_node 作为可见版本

如果 snapshot_version = 210：
  → v9 trans_v=190 < 210 → 返回 v9（最新提交版本）
```

---

## 6. `delayed_cleanout` 机制与 compact 的关系

### 6.1 什么是 delayed_cleanout？

在 `ObMvccTransNode::flag_` 中，`F_DELAYED_CLEANOUT`（doom-lsp @ L81）标记表示**回调已被移除但事务决定状态尚未写回节点**。

正常流程中，事务提交或回滚时会将决定状态同步写回节点（`set_committed()` / `set_aborted()`）。但在某些场景下（如回调链过长或分布式事务），状态写回可能被延迟。此时节点被标记为 `F_DELAYED_CLEANOUT`，后续读/写操作需要**通过 `tx_table` 查询事务的决定状态**。

### 6.2 compact 中的 cleanout

```c
// ob_row_compactor.cpp:145-165 - doom-lsp 确认
int ObMemtableRowCompactor::try_cleanout_tx_node_during_compact_(
    ObTxTableGuard &tx_table_guard,
    ObMvccTransNode *tnode)
{
  if (!(tnode->is_committed() || tnode->is_aborted())) {
    if (!tnode->is_delayed_cleanout() && !tnode->is_elr()) {
      // 既不是 delayed_cleanout 也不是 ELR，说明节点处于提交中阶段
      // 4.2.4 后多回调列表不合并，会出现多个 TransNode 同时提交
    } else if (OB_FAIL(tx_table_guard.cleanout_tx_node(
                   tnode->tx_id_, *row_, *tnode, false))) {
      TRANS_LOG(WARN, "cleanout tx state failed", K(ret));
    }
  }
}
```

在 compact 过程中，对每个未决定状态的节点尝试 cleanout。通过 `tx_table_guard.cleanout_tx_node` 查找事务的最终状态（提交/回滚），并写回节点。

### 6.3 `mvcc_write_` 中的 delayed_cleanout 处理

```c
// ob_mvcc_row.cpp:845-847 - doom-lsp 确认
if (iter->is_delayed_cleanout() && !(iter->is_committed() || iter->is_aborted()) &&
    OB_FAIL(ctx.mvcc_acc_ctx_.get_tx_table_guards()
               .tx_table_guard_
               .cleanout_tx_node(data_tx_id, *this, *iter, false))) {
  TRANS_LOG(WARN, "cleanout tx state failed", K(ret));
}
```

写入路径上遇到 delayed_cleanout 节点时，先 cleanout 再继续操作。

---

## 7. 设计决策分析

### 7.1 为什么是 lazy compact 而不是 eager compact？

**设计选择**：在版本链长度达到阈值后，在**后续的读/提交路径**上同步压缩。

**原因**：
1. **分摊开销**：每次写操作都做 compact，写延迟不可控。延迟到阈值再触发，将分摊成本摊薄到后续请求
2. **利用已有上下文**：读路径上 compact 可以复用已获得的 `snapshot_version`，无需额外获取
3. **批量合并效益**：一次 compact 合并多个版本（`compact_row_cnt` 通常 > 1），批量操作比逐版本合并效率高

### 7.2 为什么用 NDT_COMPACT 而不是物理删除？

**设计选择**：保留所有旧版本节点，在链上"插入"一个全列合并节点作为可见性屏障。

**原因**：
1. **并发安全**：物理删除需要修改 `prev_->next_` 和 `next_->prev_`，如果有并发读正在遍历版本链，可能出现指针悬空。插入屏障节点不需要修改旧节点的指针，读操作自然在屏障处停止
2. **可见性语义清晰**：`snapshot_version_barrier` 提供了一个声明式的可见性声明——"所有屏障之后的版本已合并，无需向前搜索"
3. **调试和审计**：旧版本节点仍然在链上，有利于问题诊断

### 7.3 为什么读路径 compact 需要持有行锁，但普通读取不需要？

`ObMvccValueIterator::lock_for_read_` 不持有行锁，因为它只做**只读遍历**——通过原子加载 `list_head_` 后沿着 `prev_` 遍历。只要每个节点的 flag 状态更新是原子的，读操作总是安全的。

而 compact 需要**修改**版本链——插入新节点、更新 `latest_compact_node_`、修改 `update_since_compact_`。这些修改必须与并发的写入互斥，所以需要行锁。

### 7.4 为什么备机热点行阈值特别高？

备机（follower）上 compact 的主要目的是：
- 减少版本链长度，加速读操作
- 但备机主要承担一致性读，对版本链长度不敏感

在热点行场景下，过频繁的 compact 会导致：
1. 行锁竞争加剧
2. 额外的 `tx_table` 查询（cleanout 操作）
3. 不必要的内存分配和释放

所以备机热点行的阈值是正常值的 10 倍以上。

### 7.5 compact_node 的 `trans_version_` 为什么不使用所有合并版本的最小值？

`construct_compact_node_` 使用 `save->trans_version_`（即合并的**最新**版本的提交版本）作为 compact_node 的 `trans_version_`。

如果使用最老版本的事务版本，可能导致读操作跳过本应可见的更新；使用最新版本可以保证所有在该版本之后提交的事务都能看到这个 compact 节点。

`snapshot_version_barrier` 的设置处理了可见性的精确控制：读操作如果 `snapshot_version >= barrier`，说明它可以读取屏障之后的节点（包括当前 compact_node）；否则跳过整个 compact 区域。

---

## 8. 源码索引

### `ob_mvcc_row.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `NDT_NORMAL` / `NDT_COMPACT` | L40-41 | 节点类型枚举 |
| `struct ObMvccTransNode` | L71 | 版本节点结构 |
| `struct TransNodeFlag` | L73 | 节点状态标志位 |
| `F_ABORTED` | L80 | 已终止标志 |
| `F_COMMITTED` | L78 | 已提交标志 |
| `F_DELAYED_CLEANOUT` | L81 | 延迟清理标志 |
| `struct ObMvccRow` | L277 | 行结构 |
| `update_since_compact_` | L317 | 压缩计数器 |
| `total_trans_node_cnt_` | L319 | 节点总数 |
| `latest_compact_ts_` | L320 | 最近压缩时间戳 |
| `latest_compact_node_` | L329 | 最近压缩节点指针 |
| `list_head_` | L328 | 版本链表头 |
| `mvcc_undo()` | L358 | 回滚操作 |
| `unlink_trans_node()` | L379 | 摘除节点 |
| `row_compact()` | L385 | 压缩入口 |
| `need_compact()` | L413 | 是否需压缩判断 |

### `ob_mvcc_row.cpp`
| 函数 | 行号 | 说明 |
|------|------|------|
| `ObMvccRow::reset()` | L323 | 初始化 compact 相关字段 |
| `ObMvccRow::unlink_trans_node()` | L400 | 双向链表摘除，防御 NDT_COMPACT |
| `ObMvccRow::need_compact()` | L473 | 阈值判断 + CAS 竞争 |
| `ObMvccRow::row_compact()` | L501 | 调度到 ObMemtableRowCompactor |
| `ObMvccRow::trans_commit()` | L730 | 提交时更新统计信息 |
| `ObMvccRow::mvcc_write_()` | L808 | 写入时 delayed_cleanout 处理 |
| `ObMvccRow::mvcc_undo()` | L1031 | 回滚时摘链表头 |

### `ob_row_compactor.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `class ObMemtableRowCompactor` | L45 | 压缩器类 |
| `init()` | L53 | 初始化 |
| `compact()` | L57 | 主压缩逻辑 |
| `find_start_pos_()` | L60 | 定位压缩起点 |
| `construct_compact_node_()` | L62 | 构造 NDT_COMPACT 节点 |
| `try_cleanout_tx_node_during_compact_()` | L65 | compact 中 cleanout |
| `insert_compact_node_()` | L67 | 插入压缩节点并更新统计 |

### `ob_row_compactor.cpp`
| 函数 | 行号 | 说明 |
|------|------|------|
| `ObMemtableRowCompactor::init()` | L39 | 初始化（doom-lsp 确认） |
| `ObMemtableRowCompactor::compact()` | L67 | 三步流程 + 并发检查 |
| `ObMemtableRowCompactor::find_start_pos_()` | L110 | 首次/后续压缩搜索逻辑 |
| `ObMemtableRowCompactor::try_cleanout_tx_node_during_compact_()` | L145 | 压缩过程中 cleanout |
| `ObMemtableRowCompactor::construct_compact_node_()` | L168 | 遍历合并列、构造 NDT_COMPACT |
| `ObMemtableRowCompactor::insert_compact_node_()` | L377 | ATOMIC_STORE 插入版本链 + 统计复位 |

### 触发路径
| 位置 | 行号 | 触发方式 |
|------|------|---------|
| `ob_mvcc_engine.cpp:try_compact_row_when_mvcc_read_()` | L77 | 读路径触发（3 秒冷却） |
| `ob_mvcc_engine.cpp:get()` | L95 | 读路径 -> need_compact -> row_compact |
| `ob_mvcc_trans_ctx.cpp:commit` | L1965-1977 | 提交路径 -> FAA -> need_compact -> row_compact |
| `ob_memtable.cpp:row_compact()` | L1587 | ObMemtable 层 dispatch |

---

## 9. 总结

OceanBase 的 MVCC 版本链 compaction 机制可以总结为：

1. **触发**：通过 `update_since_compact_` 计数器 + `need_compact` 阈值判断，在读路径、提交路径、回放路径上惰性触发
2. **核心流程**：`find_start_pos_`（定位）→ `construct_compact_node_`（合并）→ `insert_compact_node_`（插入屏障）
3. **NDT_COMPACT 节点**：全列合并的版本屏障节点，保留在链上不被摘除，通过 `snapshot_version_barrier` 控制可见性
4. **delayed_cleanout**：在 compact 过程中对未决定状态的节点进行 cleanout 操作
5. **GC（物理删除）**：通过 `unlink_trans_node` 和 `mvcc_undo` 实现——回滚时摘除链表头，提交后摘除 LOCK 节点
6. **并发安全**：读路径不持行锁（原子遍历），compact 持行锁（修改链结构）

与 PostgreSQL 的 VACUUM 和 InnoDB 的 purge 不同，OceanBase 的版本链 GC 是**半惰性的（lazy）**——它不会主动回收旧版本的内存（旧版本节点仍然存在），而是通过插入屏障节点让读路径知道无需继续搜索。真正的物理删除只发生在回滚和 LOCK 节点摘除时。这种设计更适合 OceanBase 的分布式场景：避免跨节点 GC 协调，同时确保读请求的可预测延迟。
