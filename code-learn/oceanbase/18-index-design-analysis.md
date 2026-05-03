# 18 — 索引设计：局部/全局索引、IndexBack、Covering Index

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前面 17 篇文章从 MVCC 行数据一路走到查询优化器。现在聚焦于分布式数据库中一个核心且微妙的设计——**索引系统**。

在单机数据库中，索引设计相对简单：二级索引的叶节点直接包含主键值或物理指针，回表（Index Lookup）就是通过 RowID 去主表读取完整行。但到了分布式环境，索引设计面临几个全新的挑战：

1. **数据分区** — 主表按分区键分布在多个节点，二级索引该如何分？
2. **跨节点回表** — 索引扫描到一个 RowKey，主表行可能在另一个节点，怎么办？
3. **一致性** — 索引更新和主表更新如何保持原子性？
4. **分布式代价** — 全局索引的写入路径涉及两阶段提交，局部索引的查询可能不够 selective

OceanBase 的索引系统给出了工程化的答案：通过 **局部索引（Local Index）** 和 **全局索引（Global Index）** 两种模式来应对上述挑战，并在这个基础上构建了一套完整的索引扫描、回表、过滤和优化的流水线。

### 索引在整个架构中的位置

```
┌──────────────────────────────────────────────────────────────┐
│                    SQL 优化器                                 │
│   ObIndexInfoCache 索引选择   文章 17                          │
├──────────────────────────────────────────────────────────────┤
│                    SQL 执行引擎                                │
│   ObIndexLookupOpImpl  ←  IndexBack 的核心抽象                │
│   ├─ ObLocalIndexLookupOp  (DAS 本地)                         │
│   └─ ObGlobalIndexLookupOpImpl  (跨节点)                      │
│   ObTableScanWithIndexBackOp  (扫描+回表)                     │
├──────────────────────────────────────────────────────────────┤
│                    DAS (Data Access Service)                   │
│   文章 09 — Pushdown 策略                                     │
├──────────────────────────────────────────────────────────────┤
│                    Storage 层                                  │
│   SSTable → Index Tree (ObIndexBlockTreeCursor)              │
│   Index Block → Micro Block (ObIndexBlockRowIterator)        │
│   Index Filter (ObSkipIndexFilterExecutor)                   │
│   文章 08 — SSTable 存储格式                                  │
└──────────────────────────────────────────────────────────────┘
```

---

## 1. 索引类型概览

### 1.1 局部索引（Local Index）

**核心特征：** 索引与主表共享分区键，在同一 Tablet 内。

```
┌───────────────────┐     ┌───────────────────┐
│     Tablet 1       │     │     Tablet 2       │
│  ┌─────┬───────┐  │     │  ┌─────┬───────┐  │
│  │主表  │索引    │  │     │  │主表  │索引    │  │
│  │行1-50│行1-50  │  │     │  │行51-100│行51-100│  │
│  └─────┴───────┘  │     │  └─────┴───────┘  │
│  同分区，同节点     │     │  同分区，同节点     │
└───────────────────┘     └───────────────────┘
```

**优势：**
- 索引扫描后回表在同节点完成，无跨节点 RPC
- 索引与主表一起分区，partition pruning 对主表和索引都有效
- 索引更新不涉及分布式事务

**劣势：**
- 索引前缀必须包含分区键
- 如果查询条件不包含分区键，则无法使用局部索引

### 1.2 全局索引（Global Index）

**核心特征：** 索引按自己的索引列独立分区，与主表的分区方式无关。

```
┌───────────────────┐     ┌───────────────────┐
│  Tablet 1 (主表)   │     │  Tablet 2 (主表)   │
│  ┌──────────────┐  │     │  ┌──────────────┐  │
│  │ 行1-50        │  │     │  │ 行51-100     │  │
│  └──────────────┘  │     │  └──────────────┘  │
└────────┬──────────┘     └────────┬──────────┘
         │                         │
         │     跨节点回表           │
         │     ┌───────────────────┘
         ▼     ▼
┌───────────────────┐
│  Tablet 3 (索引)   │
│  索引行 (按索引列)  │
│  ┌──────────────┐  │
│  │ RowKey→主表...│  │
│  └──────────────┘  │
│  独立分区，任意节点  │
└───────────────────┘
```

**优势：**
- 索引列可以不包含分区键，通用性强
- 适合选择性高的等值查询

**劣势：**
- 回表可能跨节点，增加延迟
- 索引更新的分布式事务成本高
- 全局索引的 partition pruning 能力受限

### 1.3 唯一索引（Unique Index）

OceanBase 的唯一索引在优化器中有特殊处理。在 `ob_index_info_cache.h`（`IndexInfoEntry` 的 `is_unique_index_` 和 `is_valid_unique_index()` 方法）可以看出：

- 既是唯一索引，且查询范围覆盖了所有索引列（`is_index_column_get()`）
- 不包含 NULL 值（MySQL 模式下 NULL != NULL）
- 满足上述条件时，优化器知道最多返回一行，可以做更激进的优化

### 1.4 Covering Index（覆盖索引）

覆盖索引指索引包含了查询所需的所有列，不需要回表。

在 `ObIndexInfoCache` 中，`is_index_back_` 字段标识是否需要回表。如果优化器判断索引列已覆盖所有输出列，则 `is_index_back_ = false`。

代码位置 `ob_index_info_cache.h:202`（doom-lsp 确认）：

```cpp
bool is_index_back() const { return is_index_back_; }
void set_is_index_back(const bool is_index_back) { is_index_back_ = is_index_back; }
```

当 `is_index_back_ == false` 时，执行层直接输出索引行的数据，跳过回表流程。

---

## 2. 核心操作——Index Lookup（索引回表）

### 2.1 ObIndexLookupOpImpl —— 基类抽象

`ob_index_lookup_op_impl.h:28`（doom-lsp 确认）定义的基类是所有回表操作的抽象。

源码注释清晰地表明了设计意图：

```cpp
/*  ObIndexLookupOpImpl is the base class for table scan with index back.
*   It is an abstract class of ObLocalIndexLookupOp and ObGlobalIndexLookupOpImpl.
*   The ObGlobalIndexLookupOpImpl is located in ob_table_scan_op.h
*   The ObLocalIndexLookupOp is located in ob_das_scan_op.h
*/
```

#### LookupType —— 局部 vs 全局

`ob_index_lookup_op_impl.h:31-34`（doom-lsp 确认）：

```cpp
enum LookupType : int32_t
{
  LOCAL_INDEX = 0,
  GLOBAL_INDEX
};
```

#### LookupState —— 回表状态机

`ob_index_lookup_op_impl.h:36-42`（doom-lsp 确认）：

```cpp
enum LookupState : int32_t
{
  INDEX_SCAN,    // 扫描索引表，收集 RowKey
  DO_LOOKUP,     // 用收集的 RowKey 批量回表
  OUTPUT_ROWS,   // 输出回表结果
  FINISHED,      // 完成
  AUX_LOOKUP     // 辅助回表
};
```

### 2.2 状态机驱动

`ob_index_lookup_op_impl.cpp` 中的 `get_next_row()` 实现了一个完整的状态机循环：

```
                 ┌──────────────────────────────┐
                 │         INDEX_SCAN            │
                 │   ├ 循环获取索引行的 RowKey   │
                 │   └ 达到 batch size 或迭代完   │
                 └──────────────┬───────────────┘
                                │ lookup_rowkey_cnt_ > 0
                                ▼
                 ┌──────────────────────────────┐
                 │         DO_LOOKUP             │
                 │   用收集的 RowKey 回查主表     │
                 └──────────────┬───────────────┘
                                │ 回表完成
                                ▼
                 ┌──────────────────────────────┐
                 │        OUTPUT_ROWS            │
                 │   ├ 逐行从主表结果中输出       │
                 │   └ 输出完 → 回到 INDEX_SCAN  │
                 └──────────────┬───────────────┘
                                │ 所有行输出完
                                ▼
                 ┌──────────────────────────────┐
                 │         FINISHED              │
                 │      返回 OB_ITER_END         │
                 └──────────────────────────────┘
```

核心逻辑（`ob_index_lookup_op_impl.cpp`，doom-lsp 确认行号）：

```cpp
// ob_index_lookup_op_impl.cpp，get_next_row() 状态机核心
do {
  switch (state_) {
    case INDEX_SCAN: {
      lookup_rowkey_cnt_ = 0;
      lookup_row_cnt_ = 0;
      reset_lookup_state();
      while (OB_SUCC(ret) && !index_end_ && lookup_rowkey_cnt_ < default_batch_cnt) {
        do_clear_evaluated_flag();
        if (OB_FAIL(get_next_row_from_index_table())) {
          // 索引迭代结束，设置 index_end_
        } else if (OB_FAIL(process_data_table_rowkey())) {
          // 处理 RowKey
        } else {
          ++lookup_rowkey_cnt_;
        }
      }
      if (lookup_rowkey_cnt_ > 0) state_ = DO_LOOKUP;
      else state_ = FINISHED;
      break;
    }
    case DO_LOOKUP: {
      do_index_lookup();  // 批量回表
      state_ = OUTPUT_ROWS;
      break;
    }
    case OUTPUT_ROWS: {
      get_next_row_from_data_table();  // 逐行输出
      // 当前批次输出完 → 回到 INDEX_SCAN
      break;
    }
  }
} while (!got_next_row && OB_SUCC(ret));
```

**Batch 优化**：状态机以 `default_batch_row_count_`（局部索引默认 1000 行）为批量大小。先批量扫描索引收集 RowKey，再批量回表。这种 Batch Index Back 机制显著减少 DAS 调用次数。

### 2.3 ObLocalIndexLookupOp —— DAS 本地回表

`ob_das_scan_op.h:582`（doom-lsp 确认）：

```cpp
class ObLocalIndexLookupOp : public common::ObNewRowIterator, public ObIndexLookupOpImpl
```

关键数据成员：
- `lookup_ctdef_` / `lookup_rtdef_` — 回表的 DAS 执行定义
- `index_ctdef_` / `index_rtdef_` — 索引扫描的 DAS 执行定义
- `rowkey_iter_` — 索引扫描的 RowKey 迭代器
- `lookup_iter_` — 回表结果的迭代器
- `tablet_id_` / `index_tablet_id_` — 主表和索引表的 Tablet ID

**局部索引回表的关键特征**：索引和主表在同一 Tablet、同一 LS，因此回表在同一节点上通过 DAS 完成。

### 2.4 ObGlobalIndexLookupOpImpl —— 全局回表

`ob_table_scan_op.h:52`（doom-lsp 确认）前向声明，与 `ObTableScanOp` 紧密关联。

在 `ob_table_scan_op.cpp:2183`（doom-lsp 确认）可以看到全局回表与局部回表的分界：

```cpp
ObDASIterTreeType tree_type = spec.is_global_index_back() 
    ? ITER_TREE_GLOBAL_LOOKUP 
    : ITER_TREE_TABLE_SCAN;
```

全局回表使用 `ITER_TREE_GLOBAL_LOOKUP` 迭代树类型，这意味着：
- 索引扫描在索引所在的 Tablet 上进行
- 回表时，需要将 RowKey 路由到对应主表 Tablet 所在的节点
- DAS 层需要为每个涉及的主表 Tablet 创建 DAS 任务

---

## 3. ObTableScanWithIndexBackOp —— 扫描+回表的另一种路径

`ob_table_scan_with_index_back_op.h:36`（doom-lsp 确认）：

```cpp
class ObTableScanWithIndexBackOp : public ObTableScanOp
```

这个类提供了另一种回表路径：将索引扫描和主表回表包装在一个 `ObTableScanOp` 子类中。

核心方法：

- `open_index_scan()` — 打开索引扫描子树
- `extract_range_from_index()` — 从索引行中提取主表扫描的 range
- `do_table_scan_with_index()` — 执行回表扫描
- `do_table_rescan_with_index()` — 重新扫描

内部的 `READ_ACTION` 状态机（`ob_table_scan_with_index_back_op.h:39-44`）：

```cpp
enum READ_ACTION
{
  INVALID_ACTION,
  READ_ITERATOR,
  READ_TABLE_PARTITION,
  READ_ITER_END
};
```

这个 `READ_ACTION` 与 `ObIndexLookupOpImpl` 的 `LookupState` 不同，它是针对"先索引扫描、再扩展 range 进行主表扫描"这种特定场景设计的。

两种回表路径的对比：

| 维度 | ObIndexLookupOpImpl 系列 | ObTableScanWithIndexBackOp |
|------|------------------------|---------------------------|
| 基类 | 独立抽象类 | ObTableScanOp 子类 |
| 回表方式 | Batch RowKey → DAS Lookup | Range → Table Scan |
| 适用场景 | 标准二级索引回表 | 特殊场景（如索引满足部分 range） |
| Batch | 批量 RowKey 收集后回表 | 每次通过索引扩展 range |

---

## 4. 索引信息缓存

### 4.1 ObIndexInfoCache

`ob_index_info_cache.h:249`（doom-lsp 确认）：

```cpp
class ObIndexInfoCache
```

这是优化器（文章 17）用于缓存索引信息的结构。它维护一个 `IndexInfoEntry` 数组（最多 `OB_MAX_AUX_TABLE_PER_MAIN_TABLE + 1` 个）。

优化器在生成执行计划时，对每个可用的索引都创建一个 `IndexInfoEntry`，填充其 range 信息、ordering 信息、以及索引属性。

### 4.2 IndexInfoEntry —— 索引元数据结构

`ob_index_info_cache.h:155-240`（doom-lsp 确认），关键字段：

```cpp
// 每个索引作为一个 entry
class IndexInfoEntry {
  uint64_t index_id_;
  bool is_unique_index_;      // 是否唯一索引
  bool is_index_back_;        // 是否需要回表（Covering Index = false）
  bool is_index_global_;      // 是否全局索引
  QueryRangeInfo range_info_; // query range 信息
  OrderingInfo ordering_info_; // 索引序信息
  int64_t interesting_order_info_;  // 索引序被哪些操作使用
  ObTablePartitionInfo *partition_info_;
  ObShardingInfo *sharding_info_;
};
```

### 4.3 QueryRangeInfo —— Range 分析

`ob_index_info_cache.h` 中的 `QueryRangeInfo` 类包含详细的 range 分析结果：
- `equal_prefix_count_` — 等值前缀列数
- `range_prefix_count_` — 范围前缀列数
- `index_column_count_` — 索引列数（不含主键列）
- `ss_ranges_` — Index Skip Scan 的后缀 range

这些信息被优化器用于评估索引的访问代价和选择最优索引。

---

## 5. 存储层——索引块结构

### 5.1 Index Block Tree

SSTable 的索引数据以 **Index Tree（索引树）** 组织。这个索引树是 B+ Tree 的变体，用于在 SSTable 内快速定位行。

`ob_index_block_tree_cursor.h:133`（doom-lsp 确认）：

```cpp
// Methods, status and context to iterate through an index block tree
class ObIndexBlockTreeCursor
```

核心操作：

```
drill_down(rowkey, depth)     —— 从根节点向下钻取到指定深度
pull_up(cascade, reverse)     —— 从叶子节点向上回溯
move_forward(reverse)         —— 在当前层水平移动（下一个/上一个行）
```

#### Index Block Tree 层次结构

```
ObIndexBlockTreeCursor 的状态：
                    ┌──────────────────────────────┐
                    │   Root Micro Block (Level 2)  │ ← 根级索引块
                    │   包含指向下一级的指针          │
                    └──────────────┬───────────────┘
                                   │ drill_down
                                   ▼
                    ┌──────────────────────────────┐
                    │  Intermediate Micro Block     │ ← 中间级
                    │  (Level 1)                    │
                    └──────────────┬───────────────┘
                                   │ drill_down
                                   ▼
                    ┌──────────────────────────────┐
                    │   Leaf Micro Block (Level 0)  │ ← 叶级
                    │   包含实际的行数据或宏块指针    │
                    └──────────────────────────────┘
```

树的高度取决于 SSTable 的大小。每个 `ObIndexBlockTreePathItem` 记录了树路径上的一层：

```cpp
struct ObIndexBlockTreePathItem {
  MacroBlockId macro_block_id_;          // 宏块 ID
  int64_t curr_row_idx_;                 // 当前行索引
  int64_t row_count_;                    // 块内行数
  int64_t start_row_offset_;             // 起始偏移
  ObMicroBlockData block_data_;          // 微块数据
  ObMicroBlockBufferHandle cache_handle_;// 缓存句柄
  bool is_root_micro_block_;
  bool block_from_cache_;                // 是否来自缓存
};
```

### 5.2 Index Block Row Iterator

`ob_index_block_row_scanner.h:139`（doom-lsp 确认）：

```cpp
class ObIndexBlockRowIterator
```

索引块行迭代器提供了在 Index Block 中逐行移动的接口：

```
get_current()   — 获取当前行
get_next()      — 移到下一行
locate_key()    — 定位到指定 Key
locate_range()  — 定位到指定 Range
end_of_block()  — 判断是否块尾
```

它有三种实现：
- `ObIndexBlockRowIterator` — 标准索引块迭代器（TRANSFORMED 格式）
- `ObRAWIndexBlockRowIterator` — RAW 格式索引块迭代器
- 分别对应了 SSTable 的 Transformed 和 Raw 两种索引格式

`ObIndexBlockBareIterator`（`ob_index_block_bare_iterator.h`）则是一个轻量级的裸迭代器，专门用于遍历 Macro Block 内的 Index Micro Block，获取所有 Micro Block 的逻辑 ID。

### 5.3 Index Block Aggregator

`ob_index_block_aggregator.h`（doom-lsp 确认）中的 `ObIndexTreeRootCtx` 和 `ObSSTableMergeRes` 负责在 SSTable 合并时构建 Index Tree：

```cpp
struct ObIndexTreeRootCtx {
  int64_t task_idx_;                           // 任务索引
  ObArray<ObMicroIndexInfo> clustered_micro_info_array_;
  ObIndexTreeInfo index_tree_info_;            // 索引树元信息
  ObIndexBuildTaskType task_type_;             // 任务类型
};

struct ObIndexTreeInfo {
  ObIndexTreeRootBlockDesc root_desc_;         // 根块描述
  int64_t row_count_;                          // 总行数
  int64_t max_merged_trans_version_;           // 最大合并事务版本
  int64_t min_merged_trans_version_;
  bool contain_uncommitted_row_;               // 是否包含未提交行
};
```

构建任务类型（`ObIndexBuildTaskType`）：
- `MERGE_TASK` — 合并构建
- `MERGE_CG_TASK` — 列组合并
- `REBUILD_NORMAL_TASK` — 普通重建
- `REBUILD_DDL_TASK` — DDL 重建
- `REBUILD_BACKUP_TASK` — 备份重建

---

## 6. 索引扫描的完整数据流

### 6.1 局部索引扫描路径

```
SQL 优化器选择局部索引
       │
       ▼
ObTableScanOp
  │  scan_ctdef_ 包含索引表的扫描定义
  │  lookup_ctdef_ 包含主表的回表定义
  │
  ▼
DAS (Data Access Service)
  │  创建 DAS 任务
  │
  ├──► Index Tablet Scan
  │     ObIndexBlockRowIterator.locate_range()
  │     ObIndexBlockTreeCursor.drill_down()
  │     扫描索引块，获取 RowKey
  │
  ├──► Collect RowKey (Batch: 默认1000行)
  │     ObIndexLookupOpImpl::INDEX_SCAN state
  │
  └──► Main Tablet Lookup (同一节点)
        ObLocalIndexLookupOp::do_index_lookup()
        rowkey_iter_ → lookup_iter_
        输出完整行
```

### 6.2 全局索引扫描路径

```
SQL 优化器选择全局索引
       │
       ▼
ObTableScanOp
  │  scan_ctdef_ 包含索引表的扫描定义
  │  lookup_ctdef_ 包含主表的回表定义
  │  is_index_global_ = true
  │
  ▼
DAS (Data Access Service)
  │  tree_type = ITER_TREE_GLOBAL_LOOKUP
  │
  ├──► Index Tablet Scan (索引所在节点)
  │     扫描索引块，获取 RowKey
  │     (可能在不同节点)
  │
  ├──► RowKey → Tablet 路由
  │     根据 RowKey 计算对应的主表 Tablet
  │     可能涉及多个 Tablet
  │
  └──► 跨节点 DAS Lookup Tasks
        每个主表 Tablet 创建一个 DAS 任务
        并行回表，合并结果
```

### 6.3 Covering Index（无回表）路径

```
SQL 优化器判定 is_index_back_ = false
       │
       ▼
ObTableScanOp
  │  lookup_ctdef_ = nullptr (不回表)
  │
  ▼
DAS Index Scan Only
  扫描索引块 → 直接输出索引包含的列
  跳过回表流程，减少 I/O 和网络开销
```

---

## 7. 局部索引 vs 全局索引：设计对比

```
┌─────────────────────────────────────────────────────────────┐
│                   局部索引 (Local Index)                     │
│                                                             │
│  分区键: id                                                 │
│  表:     CREATE TABLE t (id INT, name VARCHAR(50),          │
│                          age INT, PRIMARY KEY(id))          │
│  索引:   CREATE INDEX idx_age ON t(age) LOCAL;              │
│                                                             │
│  Tablet 1 (id: 1-1000)      Tablet 2 (id: 1001-2000)       │
│  ┌──────────────────┐      ┌──────────────────┐             │
│  │ t(id=1-1000)     │      │ t(id=1001-2000)  │             │
│  │ idx_age          │      │ idx_age           │             │
│  │ (age 值会混在)    │      │ (age 值会混在)    │             │
│  │ 但 age=30 的行    │      │ 但 age=30 的行    │             │
│  │ 按 id 分布        │      │ 按 id 分布        │             │
│  └──────────────────┘      └──────────────────┘             │
│                                                             │
│  WHERE age=30:                                              │
│  → 必须在所有 Tablet 上扫描局部索引                           │
│  → 回表在同节点完成                                          │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   全局索引 (Global Index)                     │
│                                                             │
│  分区键: id                                                 │
│  表:     CREATE TABLE t (id INT, name VARCHAR(50),          │
│                          age INT, PRIMARY KEY(id))          │
│  索引:   CREATE INDEX idx_age ON t(age) GLOBAL;             │
│                                                             │
│  Tablet 1 (主表 id:1-1000)  Tablet 2 (主表 id:1001-2000)    │
│  ┌──────────────────┐      ┌──────────────────┐             │
│  │ t(id=1-1000)     │      │ t(id=1001-2000)  │             │
│  └──────────────────┘      └──────────────────┘             │
│                                                             │
│  Tablet 3 (全局索引)         Tablet 4 (全局索引)              │
│  ┌──────────────────┐      ┌──────────────────┐             │
│  │ idx_age(age<40)  │      │ idx_age(age>=40) │             │
│  │ 按 age 分区       │      │ 按 age 分区       │             │
│  └──────────────────┘      └──────────────────┘             │
│                                                             │
│  WHERE age=30:                                              │
│  → 只扫描 Tablet 3（精准 partition pruning）                 │
│  → 回表可能跨节点到 Tablet 1/2                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 8. 设计决策

### 8.1 全局索引 vs 局部索引的选择准则

| 场景 | 推荐索引类型 | 原因 |
|------|-------------|------|
| 查询包含分区键 | **局部索引** | 分区裁剪精准，回表同节点，无分布式开销 |
| 等值查询不包含分区键，高选择性 | **全局索引** | 索引分区可裁剪，少量回表 |
| 范围查询不包含分区键 | **局部索引**（或考虑全表扫描） | 全局索引范围扫描回表量太大 |
| 写入密集型场景 | **局部索引** | 索引更新无分布式事务开销 |
| 唯一约束不需要分区键 | **全局唯一索引** | 唯一性需要全局校验 |
| 实时分析/报表查询 | **全局索引** 或 **Covering Index** | 选择性高的查询避免全表扫描 |

### 8.2 Batch Index Back

`ob_index_lookup_op_impl.cpp` 中的 Batch 机制：

- 默认 batch size：局部索引 1000 行
- 通过 `EVENT_CALL(EventTable::EN_TABLE_LOOKUP_BATCH_ROW_COUNT)` 可动态调整
- 两阶段：批量收集 RowKey → 批量回表

这种设计将多次小 I/O 合并为一次大 I/O，对 SSD 和网络延迟都有显著优化效果。

### 8.3 Covering Index

Covering Index 是最优的索引访问方式。当优化器发现索引包含了查询所需的所有列时，`is_index_back_ = false`，执行层直接返回索引行数据，跳过整个回表流程。

适用场景：
- 查询只涉及少量列，且这些列都在索引中
- 高频查询的访问模式固定，可以设计覆盖索引来消除回表

### 8.4 索引更新的分布式成本

**局部索引更新**：
- 主表和索引在同一 Tablet → 单机事务
- 写入路径简单，性能开销小

**全局索引更新**：
- 主表在 Tablet A，索引在 Tablet B → 涉及两阶段事务
- 写入路径需要跨节点协调
- 对写入性能有显著影响

优化策略：
- 批量化索引更新（DAS 层的 batch DML）
- 异步索引维护（某些场景下）

### 8.5 索引分裂与合并

SSTable 合并过程中，`ObIndexBlockAggregator` 负责重新构建 Index Tree。构建时可以：
- 根据行数决定 Index Tree 的高度
- 聚合同一范围的索引行
- 更新 Bloom Filter 和元信息

Index Block 的格式可以是 `RAW_DATA`、`TRANSFORMED` 或 `BLOCK_TREE`，不同的格式适用于不同的访问模式。

---

## 9. 与前面文章的关联

### 文章 08 — SSTable 存储格式

Index Block 是 SSTable 的索引结构。在 `ob_index_block_tree_cursor.h` 中，`ObIndexBlockTreeCursor` 通过 `drill_down()` 从 SSTable 的根块导航到叶子块，这依赖于 SSTable 的 Macro Block / Micro Block 分层结构。

### 文章 09 — DAS Pushdown 策略

局部索引的回表流程完全在 DAS 框架内执行：
- `ObLocalIndexLookupOp` 继承自 `ObNewRowIterator`，是 DAS 迭代树的一部分
- DAS 的投影下推（Projection Pushdown）和过滤下推（Filter Pushdown）对索引扫描同样适用
- 全局回表使用 `ITER_TREE_GLOBAL_LOOKUP` 迭代树类型

### 文章 17 — 查询优化器

`ObIndexInfoCache` 位于优化器模块（`src/sql/optimizer/`）：
- 优化器为每个候选索引创建 `IndexInfoEntry`
- 根据 QueryRange 分析索引的等值前缀、范围前缀、选择性
- 根据 `is_index_back_`、`is_index_global_` 评估代价
- 最终选择最优索引

---

## 10. 源码索引

| 组件 | 文件 | 关键符号（doom-lsp 确认行号） |
|------|------|-----------------------------|
| **Index Lookup 基类** | `src/sql/engine/table/ob_index_lookup_op_impl.h` | `ObIndexLookupOpImpl` (28), `LookupType` (31), `LookupState` (36) |
| **Index Lookup 实现** | `src/sql/engine/table/ob_index_lookup_op_impl.cpp` | `get_next_row()`, 状态机驱动 |
| **局部索引回表** | `src/sql/das/ob_das_scan_op.h` | `ObLocalIndexLookupOp` (582) |
| **全局索引回表** | `src/sql/engine/table/ob_table_scan_op.h` | `ObGlobalIndexLookupOpImpl` (52 forward decl), `is_global_index_back()` (348) |
| **TableScan+回表** | `src/sql/engine/table/ob_table_scan_with_index_back_op.h` | `ObTableScanWithIndexBackOp` (36), `READ_ACTION` (39) |
| **索引信息缓存** | `src/sql/optimizer/ob_index_info_cache.h` | `ObIndexInfoCache` (249), `IndexInfoEntry` (155), `QueryRangeInfo` |
| **Index Block Tree** | `src/storage/blocksstable/index_block/ob_index_block_tree_cursor.h` | `ObIndexBlockTreeCursor` (133) |
| **Index Block Iterator** | `src/storage/blocksstable/index_block/ob_index_block_row_scanner.h` | `ObIndexBlockRowIterator` (139) |
| **Bare Iterator** | `src/storage/blocksstable/index_block/ob_index_block_bare_iterator.h` | `ObIndexBlockBareIterator` |
| **Index Block 构建** | `src/storage/blocksstable/index_block/ob_index_block_aggregator.h` | `ObIndexTreeRootCtx`, `ObIndexBuildTaskType` |
| **Index Block 构建** | `src/storage/blocksstable/index_block/ob_index_block_builder.h` | Index block 写入器 |
| **Index Filter** | `src/storage/blocksstable/index_block/ob_skip_index_filter_executor.h` | Skip Index 过滤 |

---

## 11. 小结

OceanBase 的索引系统设计体现了分布式数据库的核心权衡：

1. **局部索引**牺牲了索引列的灵活性（必须包含分区键），换取了本地化的查询和更新性能
2. **全局索引**提供了索引列的灵活选择，但代价是跨节点回表和分布式更新
3. **Covering Index**在合适场景下可以完全消除回表，是最优的访问模式
4. **Batch Index Back** 通过批量收集 RowKey 和批量回表，减少 DAS 调用次数
5. 存储层的 **Index Block Tree** 提供了高效的索引定位能力，与 SSTable 的层叠结构配合

选择索引类型本质上是在**查询效率**和**写入成本**之间做权衡，在分布式环境中这个权衡更加复杂——不仅要考虑单节点的 I/O 和 CPU，还要考虑跨节点的网络延迟和分布式事务开销。

---

*下一篇预告：分布式执行引擎中的并行扫描与调度*
