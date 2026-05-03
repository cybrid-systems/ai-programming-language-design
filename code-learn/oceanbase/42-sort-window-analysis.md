# 42 — 排序与窗口函数：Sort Op、Window Function Op

## 概述

排序（Sort）和窗口函数（Window Function）是 SQL 执行引擎中紧密关联的两大算子。排序为窗口函数提供有序的数据基础，而窗口函数在此基础上完成分区内排名、聚合、偏移访问等分析型计算。

OceanBase 的排序算子实现了从简单内存排序到复杂外部分归并排序的完整链路，并提供了向量化执行路径。窗口函数算子位于排序之上，通过堆叠排序实现分区有序性，再以帧（Frame）驱动聚合/非聚合计算。

---

## 1. Sort Op — 排序算子

### 1.1 类层次结构

```cpp
// src/sql/engine/sort/ob_sort_op.h
class ObSortSpec : public ObOpSpec  { /* 行号 30 */ };
class ObSortOp    : public ObOperator { /* 行号 68 */ };
```

`ObSortSpec` 保存排序的元数据（排序列、比较函数、TopN 参数等），`ObSortOp` 负责实际的执行。

此外还有向量化分支：

```cpp
// src/sql/engine/sort/ob_sort_vec_op.h
class ObSortVecSpec : public ObOpSpec  { /* 行号 29 */ };
class ObSortVecOp   : public ObOperator { /* 行号 69 */ };
```

### 1.2 核心数据结构

| 成员 | 位置 | 说明 |
|------|------|------|
| `all_exprs_` | `ObSortSpec` 第 52 行 | 排序表达式 + 输出表达式全集 |
| `sort_collations_` | 第 53 行 | 每列的排序方向（ASC/DESC） |
| `sort_cmp_funs_` | 第 54 行 | 编译好的比较函数数组 |
| `topn_expr_` | 第 44 行 | TopN 限制表达式 |
| `prescan_enabled_` | 第 61 行 | 是否启用 PreScan 优化 |
| `enable_encode_sortkey_opt_` | 第 62 行 | 是否启用排序列编码优化 |

向量化版本增加了分离存储的能力：

```cpp
// ob_sort_vec_op.h 第 48–49 行
ExprFixedArray sk_exprs_;     // sort key 表达式
ExprFixedArray addon_exprs_;  // 附加列表达式
```

### 1.3 执行流程

```
       inner_open()
            │
            ▼
    scan_all_then_sort()
            │
            ├── 从子节点拉取所有行
            ├── 调用 init_sort() 初始化排序实现
            │       │
            │       └── ObSortOpImpl (内存排序 / 外部排序 / TopN)
            │
            ├── sort_impl_.sort()   → 排序
            │
            ▼
    inner_get_next_row()  → 按序返回
```

核心方法对应源码：

| 方法 | 文件 | 行号 |
|------|------|------|
| `ObSortOp::inner_open` | `ob_sort_op.h` | 73 |
| `ObSortOp::inner_rescan` | `ob_sort_op.h` | 74 |
| `ObSortOp::inner_get_next_row` | `ob_sort_op.h` | 75 |
| `ObSortOp::inner_get_next_batch` | `ob_sort_op.h` | 76 |
| `ObSortOp::scan_all_then_sort` | `ob_sort_op.h` | 127 |
| `ObSortVecOp::inner_get_next_batch` | `ob_sort_vec_op.h` | 79 |

### 1.4 TopN 优化

当 SQL 包含 `ORDER BY ... LIMIT N` 时，排序算子可以选择 TopN 路径：

```
    init_sort(tenant_id, row_count, is_batch, topn_cnt)
        │
        └── 如果 topn_cnt < row_count × 某个阈值
                → 使用 Heap Sort (最大堆)
                → 只保留前 N 行
```

TopN 的参数通过表达式动态计算（第 44–46 行），支持 `LIMIT (SELECT ...)` 子查询场景。

### 1.5 外排序 (External Merge Sort)

当数据量超过内存限制时，回退到外部排序：

```cpp
// src/sql/engine/sort/ob_external_merge_sorter.h
template <typename Compare, typename Store_Row, bool has_addon>
class ObExternalMergeSorter { /* 模板类，第 35 行 */ };
```

关键设计：

| 成员 | 行号 | 说明 |
|------|------|------|
| `MAX_MERGE_WAYS` | 38 | 最大归并路数 = 256 |
| `MergeHeap` | 40 | `ObBinaryHeap` 实现的败者树 |
| `init(chunks, merge_ways)` | 46, 92 | 初始化 chunk 迭代器并建堆 |
| `heap_next(chunk)` | 51, 140 | 从堆顶取最小行，补充下一行 |
| `get_next_row(sk_row, addon_row)` | 47, 195 | 返回下一行排序结果 |

**算法流程：**

```
       init()                      heap_next()
          │                            │
          ▼                            ▼
   ┌──────────────┐          ┌──────────────────┐
   │ Chunks[0..N]  │          │   MergeHeap      │
   │ 每个是一个有序  │─────────▶│ (Min-Heap, 256)  │
   │ 的排序 Run    │          │ top() = 当前最小行 │
   └──────────────┘          └──────────────────┘
                                    │
                                    ▼
                           ┌──────────────────┐
                           │ pop → get_next()  │
                           │ → push 下一行     │
                           └──────────────────┘
```

### 1.6 向量化排序 — `ObSortVecOp`

向量化版本将排序键与附加列分离存储（第 108–115 行）：

```
  sk_row_store_   ── 排序键的 TempRowStore
  addon_row_store_ ── 附加列的 TempRowStore
```

关键优化：
- **`SORTKEY_STORE_SEPARATELY_THRESHOLD`**（第 72 行）：当附加列数 >= 8 时分离存储，减少排序时的内存拷贝
- **`enable_single_col_compare_opt_`**（第 66 行）：单排序列 + 无附加列时的快速路径
- **PreScan**（第 95–98 行）：先扫描一遍算子，获取行数信息以决定排序策略

### 1.7 Sort Op 数据流图

```
                    ┌──────────────┐
                    │   子算子输出   │
                    └──────┬───────┘
                           │
                           ▼
               ┌─────────────────────┐
               │  scan_all_then_sort │
               │  (或 Prescan)       │
               └──────────┬──────────┘
                          │
                          ▼
              ┌──────────────────────┐
              │   init_sort() 决策    │
              │                      │
              │  数据量小 → 内存排序   │
              │  数据量大 → 外部排序   │
              │  TopN     → 堆排序    │
              └──────────────────────┘
                          │
                          ▼
              ┌──────────────────────┐
              │  sort_impl_.sort()   │
              │                      │
              │  ┌─ 内存: QuickSort  │
              │  ├─ 外部: Run生成    │
              │  │       → 归并      │
              │  └─ TopN: MaxHeap    │
              └──────────────────────┘
                          │
                          ▼
              ┌──────────────────────┐
              │ inner_get_next_row() │
              │ 逐行返回排序结果      │
              └──────────────────────┘
```

---

## 2. Window Function Op — 窗口函数算子

### 2.1 类层次结构

```cpp
// src/sql/engine/window_function/ob_window_function_op.h
class WinFuncInfo          { /* 行号 37 */ };
class ObWindowFunctionSpec { /* 行号 209 */ };
class ObWindowFunctionOp   { /* 行号 307 */ };

// 窗口函数内部的 Cell 层次
class WinFuncCell                    { /* 行号 579 */ };
class AggrCell : public WinFuncCell  { /* 行号 614 */ };   // 聚合类 (COUNT, SUM, AVG...)
class NonAggrCell : public WinFuncCell { /* 行号 669 */ };  // 非聚合类
  class NonAggrCellRowNumber         { /* 行号 681 */ };
  class NonAggrCellRankLike          { /* 行号 729 */ };
  class NonAggrCellNthValue          { /* 行号 705 */ };
  class NonAggrCellLeadOrLag         { /* 行号 717 */ };
  class NonAggrCellCumeDist          { /* 行号 745 */ };
  class NonAggrCellNtile             { /* 行号 693 */ };
```

### 2.2 WaitList 驱动的帧计算架构

`WinFuncCell` 以链表 `WinFuncCellList`（第 757 行）组织，每个 Cell 对应一个窗口函数。计算模式如下：

```
    WinFuncCellList (DList)
          │
          ├── WinFuncCell[0]  →  wf_idx_ = 0
          │      ├── AggrCell      →  COUNT/SUM/AVG (可逆/不可逆聚合)
          │      └── last_valid_frame_  → 缓存上次帧位置
          │
          ├── WinFuncCell[1]  →  wf_idx_ = 1
          │      └── NonAggrCellRankLike → RANK / DENSE_RANK
          │
          └── ...
```

### 2.3 WinFuncInfo — 窗口函数描述

```cpp
struct WinFuncInfo {                    // ob_window_function_op.h 第 37 行
  WindowType win_type_;                 // 第 106 行: ROWS/RANGE/GROUPS
  ObItemType func_type_;                // 第 107 行: T_MAX, T_MIN, T_WIN_FUN_RANK...
  ExprFixedArray partition_exprs_;      // 第 118 行: PARTITION BY 列
  ExprFixedArray sort_exprs_;           // 第 120 行: ORDER BY 列
  ObSortCollations sort_collations_;    // 第 121 行: 排序列方向
  ObSortFuncs sort_cmp_funcs_;          // 第 122 行: 比较函数
  ExtBound upper_;                      // 第 114 行: 帧上界
  ExtBound lower_;                      // 第 115 行: 帧下界
  bool can_push_down_;                  // 第 123 行: 是否支持下推
};
```

`ExtBound`（第 41 行）定义了窗口帧边界：

```
  ExtBound:
    is_preceding_     → 是否前向
    is_unbounded_     → 是否无界
    between_value_expr_ → 边界值的表达式（ROWS 模式下的偏移量）
    range_bound_expr_   → RANGE 模式下的边界表达式
```

### 2.4 三阶段执行模型

`ObWindowFunctionOp` 用 `ProcessStatus`（第 312 行）管理状态机：

```cpp
enum class ProcessStatus {
  PARTIAL,     // 第 314 行: 阶段1 — 拉取输入行并计算部分结果
  COORINDATE,  // 第 315 行: 阶段2 — 分布式场景下协调全局结果
  FINAL        // 第 316 行: 阶段3 — 输出最终结果
};
```

**执行流程：**

```
  ProcessStatus::PARTIAL
       │
       ├── partial_next_row()     → 拉取子节点行
       │      └── input_one_row() → 存入 RowsStore
       │      └── 遇到分区边界     → 触发 compute()
       │
       ├── (分布式 Mode) coordinate()
       │      └── PX 协调: 合并各 DOP 的部分结果
       │
       ▼
  ProcessStatus::FINAL
       │
       └── final_next_row() → 输出计算结果
```

### 2.5 RowsStore — 行存储与管理

`RowsStore`（第 337 行）是窗口函数的核心数据容器：

```
  RowsStore
    ├── ra_rs_           : ObRADatumStore (可随机访问的行存储)
    ├── begin_idx_       : 当前分区的起始索引
    ├── row_cnt_         : 已计算的行数
    ├── stored_row_cnt_  : 总存储行数（可能包含未计算的后缀分区行）
    └── output_row_idx_  : 已输出的行索引
```

分区内行位置的标签：

```
  [begin_idx_, output_row_idx_)        → 已输出
  [output_row_idx_, row_cnt_)          → 已计算但未输出
  [row_cnt_, stored_row_cnt_)          → 未计算
```

### 2.6 聚合窗口函数 — AggrCell

`AggrCell`（第 614 行）使用 `ObAggregateProcessor` 计算聚合窗口函数，核心是其帧计算：

```cpp
// 帧内逐行累加：
int trans(const ObRADatumStore::StoredRow &row);

// 支持逆操作（滑动窗口）：
int inv_trans(const ObRADatumStore::StoredRow &row);

// 是否支持逆操作：
bool can_inv() const;
```

**帧滑动优化示例：**

```
  帧: ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING

  行号:    0   1   2   3   4   5
  帧(2):         [1, 2, 3]
  帧(3):            [2, 3, 4]

  从帧2 → 帧3：
    inv_trans(行1) → 移出窗口
    trans(行4)     → 加入窗口
```

这个增量更新避免了对每行重新遍历整个帧，是窗口函数性能的关键。

### 2.7 非聚合窗口函数实现

| 类 | 行号 | 说明 |
|----|------|------|
| `NonAggrCellRowNumber` | 681 | `ROW_NUMBER()` — 分区内连续编号 |
| `NonAggrCellRankLike` | 729 | `RANK()` / `DENSE_RANK()` / `PERCENT_RANK()` |
| `NonAggrCellNthValue` | 705 | `NTH_VALUE()` / `FIRST_VALUE()` / `LAST_VALUE()` |
| `NonAggrCellLeadOrLag` | 717 | `LEAD()` / `LAG()` — 偏移访问 |
| `NonAggrCellCumeDist` | 745 | `CUME_DIST()` — 累积分布 |
| `NonAggrCellNtile` | 693 | `NTILE()` — 等深分桶 |

`RankLike` 的排名计算的要点（`ob_window_function_op.h` 第 734 行）：

```
  rank_of_prev_row_  → 上一行的排名缓存

  如果当前行与上一行相等:
    rank = rank_of_prev_row_
  否则 RANK:
    rank = row_idx - frame.head_ + 1
  否则 DENSE_RANK:
    rank = rank_of_prev_row_ + 1
```

### 2.8 ObWindowFunctionSpec — 分布式窗口函数

`ObWindowFunctionSpec`（第 209 行）支持分布式执行：

```cpp
enum WindowFunctionRoleType {
  NORMAL,        // 第 216 行: 常规执行
  PARTICIPATOR,  // 第 217 行: 分布式 DOP 中的参与方
  CONSOLIDATOR   // 第 218 行: 合并方
};
```

| 成员 | 行号 | 说明 |
|------|------|------|
| `single_part_parallel_` | 280 | 单分区并行（相同 PBY 分区由多个线程处理） |
| `range_dist_parallel_` | 281 | 范围分布并行 |
| `rd_wfs_` | 287 | 范围分布窗口函数索引数组 |
| `rd_coord_exprs_` | 290 | COORD 合并时需要传输的表达式 |
| `rd_sort_collations_` | 291 | 范围分布的排序方向 |
| `rd_pby_sort_cnt_` | 293 | PARTITION BY 列在排序键中的数量 |

`rd_sort_cmp` 模板方法（第 247, 1074 行）提供了统一的比较逻辑：

```
  rd_pby_cmp(l, r)       → 比较 PARTITION BY 部分
  rd_oby_cmp(l, r)       → 比较 ORDER BY 部分
  rd_pby_oby_cmp(l, r)   → 比较全部排序列
```

### 2.9 内存管理

`ObWindowFunctionOp` 使用自适应内存管理：

```cpp
// ob_window_function_op.h 第 1059–1070 行
lib::MemoryContext mem_context_;
ObSqlWorkAreaProfile profile_;
ObSqlMemMgrProcessor sql_mem_processor_;
HashPartInfrasMgr hp_infras_mgr_;

int64_t global_mem_limit_version_;    // 全局内存版本
int64_t amm_periodic_cnt_;            // 自适应周期的计数器
```

`update_mem_limit_version_periodically()`（第 970, 1100 行）每 1024 行检查一次内存边界，超出时触发 dump：

```
  update_max_available_mem_size_periodically()
       → 如果超限, extend_max_memory_size()
       → 如果仍然超限, 触发 dump
       → 递增 global_mem_limit_version_
```

### 2.10 Window Function Op 数据流图

```
                ┌──────────────────────┐
                │   子算子输出（已排序）  │
                └──────────┬───────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │    ObWindowFunctionOp │
                │                      │
                │  partial_next_row()  │
                │    ├── 存入 RowsStore │
                │    └── 检测分区边界    │
                │                      │
                │  遇到分区变化时:       │
                │    foreach WinFuncCell│
                │      compute(frame)   │
                │        ├── AggrCell   │
                │        │   trans/inv  │
                │        └── NonAggrCell│
                │            eval()     │
                │                      │
                │  (分布式) coordinate() │
                │    ├── 合并部分结果    │
                │    └── 应用 Patch     │
                │                      │
                │  final_next_row()     │
                └──────────┬───────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │    输出行（含 WF 值）  │
                └──────────────────────┘
```

---

## 3. 流式窗口处理 (Streaming Window Processor)

### 3.1 概述

`StreamingWindowProcessor`（`streaming_window_processor.h` 第 14 行）是向量化窗口函数执行的核心，利用批处理（batch）模式降低帧计算开销。

```cpp
class StreamingWindowProcessor {
  int process_next_batch(const ObBatchRows &child_brs, ObBatchRows &output);  // 第 31 行
};
```

### 3.2 批处理流程

```
  process_next_batch()
    │
    ├── on_batch_start()
    │     └── 检查当前 batch 是否跨越分区边界
    │     └── 从上一 batch 末尾恢复计算状态
    │
    ├── process_batch_of_various_partitions()
    │     ├── 对整个 batch 执行 compute_all_wf_values()
    │     │     └── 每行: process_next_row_streaming()
    │     └── 跨分区时重置帧状态
    │
    └── on_batch_end()
          └── 保存 last_row_ 供下一 batch 使用
```

### 3.3 在 rang_dist 中的应用

`StreamingWindowProcessor` 支持范围分布并行（Range Distribution Parallel），通过 `rd_last_row_` 和 `last_computed_part_rows_` 记录最后一个分区的边界信息。

---

## 4. 窗口函数表达式层 (WinExpr)

### 4.1 设计模式

`win_expr.h` 中的 `IWinExpr` 接口（第 148 行）定义了所有窗口函数计算的抽象：

```
  IWinExpr                        ← 抽象接口
    │
    ├── WinExprWrapper<Derived>   ← CRTP 模板包装
    │     │
    │     ├── NonAggrWinExpr      ← 非聚合窗口函数基类
    │     │     ├── RankLikeExpr  ← RANK / DENSE_RANK
    │     │     ├── RowNumber     ← ROW_NUMBER
    │     │     ├── NthValue      ← NTH_VALUE
    │     │     ├── LeadOrLag     ← LEAD / LAG
    │     │     ├── CumeDist      ← CUME_DIST
    │     │     └── Ntile         ← NTILE
    │     │
    │     └── AggrExpr            ← 聚合窗口函数 (SUM/COUNT/AVG...)
```

每个 `IWinExpr` 实现两种执行模式：

| 方法 | 说明 |
|------|------|
| `process_window()` | 传统行模式：给定帧和行索引，计算单行结果 |
| `process_rows_streaming()` | 流式批模式：给定行范围，批量计算结果 |
| `accum_process_window()` | 增量模式：基于帧变化做增量更新 |
| `process_next_row_streaming()` | 流式单行模式：逐行流式计算 |

### 4.2 执行上下文

```cpp
// 传统模式（win_expr.h）
struct WinExprEvalCtx {           // 第 97 行
  RowStore &input_rows_;
  WinFuncColExpr &win_col_;
};

// 流式模式
struct StreamingWinExprEvalCtx {  // 第 115 行
  WinFuncColExpr &win_col_;
  ObExprPtrIArray& input_exprs_;
  ObEvalCtx& eval_ctx_;
  const ObBatchRows& input_brs_;
};
```

### 4.3 聚合帧的 `need_restart_aggr` 决策

`Frame::need_restart_aggr()`（`win_expr.h`）决定了窗口帧滑动是否需要完全重新计算：

```
  决策逻辑:
    如果新帧和旧帧的重叠很少:
      inc_cost(新增行 + 移出行) > restart_cost(全量行)
        → 完全重新计算

    如果函数不支持逆操作且帧有滑出行:
      → 完全重新计算

    如果 REMOVE_EXTRENUM (MAX/MIN) 且极值索引已移出窗口:
      → 完全重新计算
```

---

## 5. 关键设计决策

### 5.1 排序分离存储

向量化排序将 Sort Key 和 Addon 列分离，当附加列数 >= 8 时生效。这减少了排序过程中的内存带宽消耗，因为比较操作只需访问 Sort Key。

### 5.2 TopN 选择时机

排序算子根据 `topn_cnt` 与行数的比例决定是否启用 TopN 优化路径。TopN 使用最大堆（Binary Heap）仅保留前 N 行，避免全量排序。

### 5.3 窗口帧的增量聚合

`AggrCell` 利用可逆聚合函数（SUM/COUNT/AVG）实现帧滑动时的增量更新。当帧移动时，只需要：
- `inv_trans` 移出窗口的行
- `trans` 移入窗口的行

对于不可逆聚合（MAX/MIN），当极值移出窗口时必须全量重算。

### 5.4 分布式窗口函数

- **单分区并行** (`single_part_parallel_`)：同一分区数据由多个线程处理，通过 DataHub 合并
- **范围分布并行** (`range_dist_parallel_`)：按 ORDER BY 范围切分，每个节点处理一个范围。通过 `rd_patch_` 更新首尾分区的部分聚合结果

### 5.5 自适应内存管理

窗口函数的内存管理使用 `ObSqlMemMgrProcessor` 定期检查内存使用。每 1024 行检查一次，触发扩展或 dump。`RowsStore` 通过 `global_mem_limit_version_` 同步全局内存限制版本。

---

## 6. 源码索引

| 文件 | 核心内容 | 入口行号 |
|------|---------|---------|
| `ob_sort_op.h` | Sort Op 主入口 — `ObSortOp` (68), `ObSortSpec` (30) | 68 |
| `ob_sort_vec_op.h` | 向量化排序 — `ObSortVecOp` (69), `ObSortVecSpec` (29) | 69 |
| `ob_external_merge_sorter.h` | 外排序模板 — `ObExternalMergeSorter` (35), `MAX_MERGE_WAYS` (38) | 35 |
| `ob_window_function_op.h` | 窗口函数主入口 — `WinFuncInfo` (37), `ObWindowFunctionSpec` (209), `ObWindowFunctionOp` (307) | 307 |
| `streaming_window_processor.h` | 流式批处理 — `StreamingWindowProcessor` (14), `process_next_batch` (31) | 14 |
| `win_expr.h` | 窗口表达式层 — `IWinExpr` (148), `NonAggrWinExpr`, `AggrExpr`, `Frame` | 148 |

---

## 7. ASCII 全景图

```
  ┌─────────────────────────────────────────────────────────────┐
  │                    OceanBase 排序+窗口函数体系               │
  └─────────────────────────────────────────────────────────────┘

  数据流:
  ┌─────────┐    Sort    ┌──────────┐   WF Compute   ┌──────────┐
  │ 子算子输出 │────────▶│ 排序结果  │──────────────▶│ 最终结果  │
  └─────────┘           └──────────┘               └──────────┘

  排序模块:
  ┌─────────────────────────────────────────────────────┐
  │  ObSortOp ─── ObSortOpImpl                           │
  │     │            ├── 内存排序 (QuickSort/Stdsort)    │
  │     │            ├── TopN (Max Heap)                 │
  │     │            └── 外排序 (Run生成 + Merge)        │
  │     │                  └── ObExternalMergeSorter     │
  │     │                      └── MergeHeap (256路)     │
  │  ObSortVecOp ─── ObSortVecOpProvider                 │
  │     ├── sk_row_store_   (排序键分离)                  │
  │     └── addon_row_store_                             │
  └─────────────────────────────────────────────────────┘

  窗口函数模块:
  ┌─────────────────────────────────────────────────────┐
  │  ObWindowFunctionOp                                  │
  │     ├── input_rows_ (RowsStore)                      │
  │     ├── wf_list_ (WinFuncCellList)                   │
  │     │    ├── AggrCell (COUNT/SUM/AVG)                │
  │     │    │   └── aggr_processor_                     │
  │     │    └── NonAggrCell (RANK/ROW_NUMBER/LEAD...)   │
  │     │        └── eval()                              │
  │     │                                                │
  │     ├── ProcessStatus (PARTIAL→COORINDATE→FINAL)     │
  │     └── StreamingWindowProcessor                     │
  │          └── process_next_batch()                    │
  │               └── WinExpr层: IWinExpr                │
  │                    ├── AggrExpr  (聚合)               │
  │                    └── NonAggrWinExpr (非聚合)        │
  └─────────────────────────────────────────────────────┘

  Frame:  [head_, tail_)  ← 窗口帧, tail 不包含
  增量计算: trans(new) + inv_trans(expired) = 高效滑动
  内存管理: 每1024行检查, ObSqlMemMgrProcessor 自适应扩展/dump
```

---

## 总结

OceanBase 的排序与窗口函数实现了从单机到分布式的完整体系：

1. **排序层**提供内存排序、外排序、TopN 堆排序三种执行路径，以及向量化批处理接口
2. **窗口函数层**基于排序输出，利用帧滑动增量计算优化分析型查询
3. **分布式支持**通过 `PARTICIPATOR/CONSOLIDATOR` 角色和 DataHub 消息实现 DOP 内的窗口函数并行
4. **流式批处理** (`StreamingWindowProcessor`) 将逐行计算改造为批处理，大幅提升向量化执行效率
5. **自适应内存管理**保证大分区下不会 OOM，通过自动 dump 和恢复保持稳定性
