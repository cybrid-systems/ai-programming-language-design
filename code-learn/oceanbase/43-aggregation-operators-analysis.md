# 43 — 聚合与 Group By — Hash/Bloom/Merge Aggregation

> 基于 OceanBase CE 主线源码
> 分析范围：`src/sql/engine/aggregate/`（37 个文件）
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与代码结构分析

---

## 0. 概述

**聚合（Aggregation）是 SQL 执行引擎中仅次于 Join 的核心操作。**

一条 `SELECT COUNT(*), SUM(price) FROM t GROUP BY category` 的执行，核心是**将输入行按分组键分组，并对每组应用聚合函数**。当没有 GROUP BY 时，整张表作为一个组处理。

OceanBase 的聚合算子体系按是否包含 GROUP BY 分为两类：

| 算子 | 文件 | 适用场景 |
|------|------|---------|
| **ScalarAggregateOp** | `ob_scalar_aggregate_op.h/cpp` | 无 GROUP BY 的全局聚合 |
| **HashGroupByOp** | `ob_hash_groupby_op.h/cpp` | 基于哈希的分组聚合 |
| **MergeGroupByOp** | `ob_merge_groupby_op.h/cpp` | 输入已排序时的分组聚合 |
| **HashDistinctOp** | `ob_hash_distinct_op.h/cpp` | 基于哈希的去重算子 |
| **MergeDistinctOp** | `ob_merge_distinct_op.h/cpp` | 输入已排序时的去重算子 |

所有聚合算子通过 **ObAggregateProcessor** 完成聚合函数的实际计算（SUM、COUNT、AVG、MAX、MIN 等），自身只负责"如何分组"的逻辑。

---

## 1. 基类体系 — ObGroupBySpec / ObGroupByOp

### 1.1 ObGroupBySpec（ob_groupby_op.h:25）

所有聚合 spec 的基类，定义了分组和聚合的元信息：

```
class ObGroupBySpec : public ObOpSpec {  // ob_groupby_op.h:25
  AggrInfoFixedArray aggr_infos_;        // line 49 — 聚合函数描述
  ObThreeStageAggrStage aggr_stage_;     // line 51 — 三阶段聚合阶段
  ObFixedArray<int64_t> dist_aggr_group_idxes_; // line 53 — 分组去重函数索引
  int64_t aggr_code_idx_;                // line 54 — 聚合编码表达式索引
  ObExpr *aggr_code_expr_;               // line 55 — 聚合编码表达式
  bool by_pass_enabled_;                 // line 56 — 自适应 bypass 开关
  bool support_fast_single_row_agg_;     // line 58 — COUNT/SUM/MIN/MAX 快速路径
  bool skew_detection_enabled_;          // line 59 — 数据倾斜检测
  bool llc_ndv_est_enabled_;            // line 60 — HyperLogLog NDV 估算
  bool need_last_group_in_3stage_;       // line 62 — 三阶段聚合宏
};
```

### 1.2 ObGroupByOp（ob_groupby_op.h:72）

所有聚合算子的公共基类：

```
class ObGroupByOp : public ObOperator {  // ob_groupby_op.h:72
  ObAggregateProcessor aggr_processor_;  // line 81 — 聚合函数处理器
};
```

核心设计：**分组逻辑由子类实现（Hash/Merge），聚合函数计算统一委托给 `aggr_processor_`**。

---

## 2. HashGroupByOp — 基于哈希的分组聚合

`ObHashGroupByOp` 是 OceanBase 最复杂的聚合算子，实现了从简单内存哈希到磁盘溢出的完整链路。

### 2.1 类层次结构

```
ObHashGroupBySpec : public ObGroupBySpec  // ob_hash_groupby_op.h:40
  group_exprs_       — GROUP BY 列表达式
  cmp_funcs_         — 分组键比较函数
  est_group_cnt_     — 优化器估算的分组数
  distinct_exprs_    — 聚合函数中的 DISTINCT 参数

ObHashGroupByOp : public ObGroupByOp      // ob_hash_groupby_op.h:198
  local_group_rows_  — 哈希表（ObGroupRowHashTable）
  group_store_       — 分组行数据存储
  dumped_group_parts_ — 溢出到磁盘的分区链表
  bypass_ctrl_       — 自适应 bypass 控制
  popular_map_       — 数据倾斜检测用的热点值哈希表
  llc_est_           — HyperLogLog NDV 估算器
```

### 2.2 执行流程

```
       inner_open()
            │
            ▼
    init_mem_context() / init hash table
            │
            ▼
    inner_get_next_row() —— 逐行输出分组结果
            │
            ├── (首次调用) → load_data()
            │       │
            │       ├── 从子节点拉取数据
            │       ├── 为每行计算分组键的 hash 值
            │       ├── 插入哈希表 (set/find cycle)
            │       ├── 按需检测 bypass 切换时机
            │       ├── 内存不足 → 分区溢出到磁盘
            │       └── 数据倾斜 → bypass 路径
            │
            └── 遍历哈希表 → restore_groupby_datum()
                              → aggr_processor_.collect()
                              → 输出一行聚合结果
```

核心方法对应源码：

| 方法 | 文件 | 行号 |
|------|------|------|
| `ObHashGroupByOp::inner_open` | `ob_hash_groupby_op.h` | 228 |
| `ObHashGroupByOp::inner_get_next_row` | `ob_hash_groupby_op.cpp` | 470 |
| `ObHashGroupByOp::load_data` | `ob_hash_groupby_op.cpp` | 901 |
| `ObHashGroupByOp::load_one_row` | `ob_hash_groupby_op.cpp` | 2575 |
| `ObHashGroupByOp::alloc_group_item` | `ob_hash_groupby_op.cpp` | 1148 |
| `ObHashGroupByOp::alloc_group_row` | `ob_hash_groupby_op.cpp` | 1169 |
| `ObHashGroupByOp::setup_dump_env` | `ob_hash_groupby_op.h` | 387 |
| `ObHashGroupByOp::destroy_all_parts` | `ob_hash_groupby_op.h` | 394 |

### 2.3 哈希表结构

#### ObExtendHashTable（ob_exec_hash_struct.h:38）

自动扩展的哈希表——所有 Hash GroupBy / Hash Distinct 的底层数据结构：

```
class ObExtendHashTable<Item> :  // ob_exec_hash_struct.h:38
  BucketArray buckets_     — 使用 ObSegmentArray 的分段桶数组
  int64_t size_            — 已插入元素数
  int64_t probe_cnt_       — 探测计数器（用于 adaptive bypass 决策）

  核心算法：
  - 开放定址法（线性探测）
  - 桶数 = next_pow2(size × SIZE_BUCKET_SCALE)，SIZE_BUCKET_SCALE = 2
  - 当 size × 2 ≥ 桶数时，桶数组翻倍（extend）
  - locate_bucket：线性探测冲突解决，循环终止条件是遇到空桶
```

关键设计 **set** 方法（`ob_exec_hash_struct.h:233`）：

```
set(item):
  1. 如果 size × 2 ≥ 桶数 → extend() 翻倍
  2. 使用 hash_func 计算 hash 值
  3. locate_bucket 找到插入位置
  4. 空桶 → 直接插入；非空 → 头插法链接到 item->next()
  5. size_++
```

#### ObGroupRowHashTable（ob_hash_groupby_op.h:117）

`ObExtendHashTable` 的特化，`ObGroupRowItem` 作为元素：

```
class ObGroupRowHashTable : public ObExtendHashTable<ObGroupRowItem> :
  int init(allocator, gby_exprs, eval_ctx, cmp_funcs, initial_size)  // line 124
  const GroupRowItem *get(item)                                       // line 132
  int likely_equal(left, right, result)                               // line 132

  // 向量化预取优化：
  void prefetch(brs, hash_vals)                                       // line 123
  // 当桶数 > 4096 时，使用 __builtin_prefetch 三遍循环：
  // 1. 预取桶头
  // 2. 预取 item 指针
  // 3. 预取 groupby_store_row_ 数据
```

`likely_equal`（`ob_hash_groupby_op.cpp:101`）的优化：先尝试 `memcmp` 快速路径，失败才回调比较函数。

#### ObGroupRowItem（ob_hash_groupby_op.h:76）

哈希表中的条目：

```
struct ObGroupRowItem :
  ObGroupRowItem *next_  — 链地址法指针
  uint64_t hash_         — 哈希值
  union {
    struct {
      uint64_t batch_idx_:63;   // 批次索引
      uint64_t is_expr_row_:1;  // 数据是否在 expr 中
    };
    GroupRow *group_row_;       // 聚合组行指针
  };
  StoredRow *groupby_store_row_; // 分组键的存储行
  uint16_t cnt_;                // 行计数
```

#### ObHashCtx 与 ObGbyBloomFilter（ob_exec_hash_struct.h:394, 434）

```
class ObHashCtx :              // ob_exec_hash_struct.h:394
  // 哈希上下文，包含 hash 值、行指针等

class ObGbyBloomFilter :       // ob_exec_hash_struct.h:434
  // Bloom Filter，用于溢出分区的快速过滤
  // 在 setup_dump_env 时创建
  // 检测溢出分区的数据是否可能存在匹配
```

### 2.4 Hash Aggregation Variant（ob_hash_agg_variant.h）

`ObAggrHashTableWapper` 封装了两种向量化哈希表变体：

```
using HashAggSetPtr = boost::variant<              // ob_hash_agg_variant.h:30
  ObExtendHashTableVec<ObGroupRowBucket> *,         // 标准桶
  ObExtendHashTableVec<ObGroupRowBucketInline> *>;  // 内联桶（更紧凑）

struct SizeVisitor           — 访问者：获取大小
struct MemUsedVisitor        — 访问者：获取内存使用量
struct InitVisitor           — 访问者：初始化
struct GetBktNumVisitor      — 访问者：获取桶数
struct PrefetchVisitor        — 访问者：CPU 预取
struct ProcessBatchVisitor   — 访问者：批处理
```

这是 **boost::variant + visitor 模式** 的典型应用。`ObAggrHashTableWapper`（`ob_hash_agg_variant.h:422`）通过访问者模式统一操作两种哈希表，而不需要在调用方写 if-else 分支。

核心方法：

```
prepare_hash_table()       — 初始化哈希表
append_batch()             — 批量插入行
process_batch()            — 批量处理聚合
get_next_batch()           — 批量输出结果
prefetch()                 — 硬件预取
process_popular_value_batch() — 热点值处理
```

### 2.5 自适应 Bypass 与数据倾斜处理

`ObAdaptiveByPassCtrl`（`ob_adaptive_bypass_ctrl.h:21`）是 Hash GroupBy 的智能决策引擎。

#### 状态机

```
  STATE_L2_INSERT       — 使用 L2 Cache 大小内存的哈希表
  STATE_L3_INSERT       — 使用 L3 Cache 大小内存（插入全量数据）
  STATE_L2_INSERT_5X    — L2 Cache 的 5 倍（更积极的内存模式）
  STATE_MAX_MEM_INSERT  — 使用最大可用内存
  STATE_PROBE           — 探测阶段：判断是否需要切换到 bypass
  STATE_ANALYZE         — 分析阶段：评估哈希表密度
  STATE_PROCESS_HT      — 处理已有哈希表，切换路径
```

#### 决策逻辑（`gby_process_state`）

```
gby_process_state(probe_cnt, row_cnt, mem_size):
  1. STATE_L2_INSERT:
     - 在 L2 Cache 大小的哈希表中插入行
     - 数据超过 L2 cache → 转入 STATE_PROBE

  2. STATE_PROBE (采样 1000 行):
     - 计算 probe_cnt / row_cnt 比率
     - 比率高 → 哈希重复率高，留在哈希模式
     - 比率低 → 数据基数大，切到 bypass（直接输出）

  3. STATE_ANALYZE:
     - 评估哈希表密度，决定是否切换
     - 统计冲突率，调整 period_cnt 采样周期

  4. STATE_PROCESS_HT:
     - 处理已有的哈希表数据
     - 完成后切换到 bypass 模式
```

#### 三阶段聚合（3-Stage Aggregation）

当 `ObThreeStageAggrStage` 启用时，Hash GroupBy 支持跨节点分阶段聚合：

```
FIRST_STAGE → SECOND_STAGE → THIRD_STAGE

每一阶段逐步对 GROUP BY 列子集做聚合：

以 GROUP BY a, b, c 为例：
  FIRST_STAGE  → GROUP BY a, b, c  (完整分组)
  SECOND_STAGE → GROUP BY a, b     (部分聚合)
  THIRD_STAGE  → GROUP BY a        (最终聚合)
```

#### HyperLogLog NDV 估算

`llc_est_` 使用 HyperLogLog 估算分组基数（NDV），用于 bypass 决策：

```
llc_add_value(hash_value, llc_map)  — ob_hash_groupby_op.h:312
check_llc_ndv()                     — ob_hash_groupby_op.h:319
```

在 `load_data` 采样阶段收集 LLC 数据，通过 HLL 估算总分组数，引导自适应决策。

### 2.6 溢出机制（Hash 到磁盘）

当哈希表超过内存限制时，Hash GroupBy 支持**分区溢出**：

```
need_start_dump(input_rows, est_part_cnt)         — ob_hash_groupby_op.h:385
setup_dump_env(part_id, input_rows, parts, ...)   — ob_hash_groupby_op.h:387
cleanup_dump_env(dump_success, part_id, ...)       — ob_hash_groupby_op.h:391
```

关键常量：

| 常量 | 值 | 说明 |
|------|----|------|
| `MIN_PARTITION_CNT` | 8 | 最小分区数 |
| `MAX_PARTITION_CNT` | 256 | 最大分区数 |
| `MAX_PART_MEM_RATIO` | 0.5 | 分区内存占比上限 |
| `EXTRA_MEM_RATIO` | 0.25 | 额外内存预留比例 |

溢出并非一次性全部写出——**只写出当前不匹配的部分**：

```
  load_data → 对每行计算 hash
           → hash 匹配当前分区 → 插入哈希表
           → hash 不匹配当前分区 → 直接写出到对应分区的磁盘
```

这意味着：一次 `load_data` 调用可能同时处理"一部分行留在内存 + 一部分行写到磁盘"。

### 2.7 Hash GroupBy 数据流图

```
                    ┌──────────────┐
                    │   子算子输出   │
                    └──────┬───────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │    load_data()           │
              │                          │
              │  对于每行:                │
              │  1. clear_evaluated_flag │
              │  2. 计算分组键 hash       │
              │  3. hash表.locate_bucket │
              │  4. 存在 → process       │
              │  5. 不存在 → alloc_group  │
              │           → set到hash表   │
              │  6. 检测 bypass 条件      │
              └──────────┬──────────────┘
                         │
            ┌────────────┴────────────┐
            ▼                         ▼
   ┌─────────────────┐    ┌──────────────────────┐
   │ 内存足够          │    │ 内存不足              │
   │ → 全部在哈希表    │    │ → 分区溢出到磁盘      │
   └────────┬─────────┘    └───────────┬──────────┘
            │                          │
            ▼                          ▼
   ┌─────────────────┐    ┌──────────────────────┐
   │ 遍历哈希表        │    │ 读取溢出分区 → 再次    │
   │ collect结果      │    │ load_data (递归)     │
   └────────┬─────────┘    └───────────┬──────────┘
            │                          │
            └──────────┬───────────────┘
                       ▼
              ┌─────────────────┐
              │ inner_get_next  │
              │ _row() → 输出    │
              │ 一行聚合结果     │
              └─────────────────┘
```

### 2.8 Bypass 自适应决策流程图

```
              ┌────────────────────┐
              │  load_data 采样阶段  │
              └─────────┬──────────┘
                        │
                        ▼
      ┌─────────────────────────────────────┐
      │  STATE_L2_INSERT                    │
      │  (L2 Cache 内的哈希表插入)           │
      └─────────────────┬───────────────────┘
                        │
              超过 L2 Cache?
                        │
               ┌────────┴────────┐
               ▼                 ▼
      ┌──────────────┐  ┌──────────────────┐
      │ STATE_PROBE  │  │ 哈希重复率高?     │
      │ (采样 1000行) │──│ → 留在哈希模式    │
      └──────┬───────┘  │ → 切 STATE_L2_3  │
             │          └──────────────────┘
             ▼
      ┌──────────────┐
      │ STATE_ANALYZE│
      │ 评估哈希密度   │
      └──────┬───────┘
             │
     ┌───────┴───────┐
     ▼               ▼
  ┌────────┐   ┌──────────┐
  │STATE_  │   │  STATE_  │
  │PROCESS_│   │  L2_INSERT│
  │HT →    │   │  (继续)   │
  │bypass  │   └──────────┘
  └────────┘
```

---

## 3. MergeGroupByOp — 基于排序的分组聚合

当输入已经按 GROUP BY 列有序（例如来自索引扫描或 Sort Op 的输出），Merge GroupBy 避免了哈希表的构建开销，采用**扫描 + 累积模式**。

### 3.1 类结构

```
ObMergeGroupBySpec : public ObGroupBySpec  // ob_merge_groupby_op.h:27
  group_exprs_       — GROUP BY 列
  rollup_exprs_      — ROLLUP 列
  has_rollup_        — 是否包含 ROLLUP
  rollup_status_     — ROLLUP 状态（NONE / DISTRIBUTOR / COLLECTOR）
  sort_exprs_        — 排序表达式
  sort_collations_   — 排序方向
  sort_cmp_funcs_    — 排序比较函数
  enable_encode_sort_ — 是否启用排序编码优化
  enable_hash_base_distinct_ — 是否启用基于哈希的 DISTINCT

ObMergeGroupByOp : public ObGroupByOp       // ob_merge_groupby_op.h:92
  last_child_output_          — 上一行输出缓存
  output_queue_cnt_           — 输出队列计数
  output_groupby_rows_        — 输出分组行数组
  inner_sort_                 — 内部排序器（ROLLUP DISTRIBUTOR 场景使用）
  ndv_calculator_             — HyperLogLog NDV 计算器（ROLLUP）
  sql_mem_processor_          — SQL 内存管理器
  hp_infras_mgr_              — 哈希分区基础设施管理器
```

### 3.2 执行流程

```
       inner_open()
            │
            ▼
       init() / init_group_rows()
            │
            ▼
    inner_get_next_row()
            │
            ├── 是 ROLLUP 且正在输出 ROLLUP 行
            │   → rollup_and_calc_results() 逐行输出
            │
            ├── is_end_ → OB_ITER_END
            │
            └── 正常流程：
                │
                ├── 读取第一行 → prepare_and_save_curr_groupby_datums
                │   → aggr_processor_.prepare()
                │
                ├── 循环读取后续行：
                │   │
                │   ├── check_same_group() → 比较分组键
                │   │   │
                │   │   ├── 相同组 → aggr_processor_.process()
                │   │   │
                │   │   └── 不同组 → 保存上一行
                │   │       → restore_groupby_datum()
                │   │       → rollup_and_calc_results()
                │   │       → collect() 输出结果行
                │   │
                │   └── prepare_and_save_curr_groupby_datums → prepare
                │
                └── OB_ITER_END → calc_batch_results
```

核心方法对应源码：

| 方法 | 文件 | 行号 |
|------|------|------|
| `ObMergeGroupByOp::init` | `ob_merge_groupby_op.cpp` | 132 |
| `ObMergeGroupByOp::inner_open` | `ob_merge_groupby_op.h` | 125 |
| `ObMergeGroupByOp::inner_get_next_row` | `ob_merge_groupby_op.cpp` | 610 |
| `ObMergeGroupByOp::check_same_group` | `ob_merge_groupby_op.cpp` | 1543 |
| `ObMergeGroupByOp::aggregate_group_rows` | `ob_merge_groupby_op.h` | 133 |
| `ObMergeGroupByOp::process_batch` | `ob_merge_groupby_op.cpp` | 1325 |
| `ObMergeGroupByOp::rollup_and_calc_results` | `ob_merge_groupby_op.h` | 148 |

### 3.3 check_same_group — 分组键比较（ob_merge_groupby_op.cpp:1543）

```
check_same_group(cur_group_row, diff_pos):
  1. 遍历所有 GROUP BY 表达式
  2. 比较当前行与上一行的分组键 datum
  3. 找到第一个不同的列，写入 diff_pos
  4. 所有列都相同 → diff_pos = OB_INVALID_INDEX
```

### 3.4 ROLLUP 支持

Merge GroupBy 完整支持 GROUP BY ROLLUP：

```
gen_rollup_group_rows(start_diff_idx, end_idx, max_idx, cur_rowid)  — h:185
rollup_and_calc_results(group_id, diff_expr)                        — h:148
rewrite_rollup_column(diff_expr)                                     — h:150
set_rollup_expr_null(group_id)                                       — h:151
```

ROLLUP 数据流：

```
输入已按 (a, b, c) 排序:
  输出：
    GROUP BY (a, b, c)
    GROUP BY (a, b, NULL)
    GROUP BY (a, NULL, NULL)
    GROUP BY (NULL, NULL, NULL)
               ↑
          ROLLUP 层级逐级上卷
```

ROLLUP DISTRIBUTOR 模式（`ob_merge_groupby_op.h:204`）用于并行 ROLLUP，使用 HyperLogLog 估算各层 NDV 以决定候选键：

```
process_rollup_distributor()         — h:204
collect_local_ndvs()                 — h:205
find_candidate_key(ndv_info)         — h:206
```

### 3.5 Merge GroupBy 数据流图

```
                    ┌──────────────┐
                    │  有序输入行    │
                    └──────┬───────┘
                           │
                           ▼
              ┌─────────────────────┐
              │ 取第一行              │
              │ prepare_and_save_    │
              │ curr_groupby_datums  │
              └──────────┬──────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │ aggr_processor_.    │
              │ prepare(group_row)  │
              └──────────┬──────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │  循环取下一行         │
              └──────────┬──────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │ check_same_group()  │
              │                     │
              │ ┌─── 相同组 ───────┐ │
              │ │ process(row)     │ │
              │ └──────────────────┘ │
              │ ┌─── 不同组 ───────┐ │
              │ │ collect(result)  │ │
              │ │ → prepare(next)  │ │
              │ └──────────────────┘ │
              └─────────────────────┘
                         │
                     OB_ITER_END
                         │
                         ▼
              ┌─────────────────────┐
              │ final collect()     │
              │ → 最后一行聚合结果    │
              └─────────────────────┘
```

---

## 4. ScalarAggregateOp — 无 GROUP BY 的全局聚合

最轻量的聚合算子——整个表只有一个组。

### 4.1 类结构

```
ObScalarAggregateSpec : public ObGroupBySpec  // ob_scalar_aggregate_op.h:24
  enable_hash_base_distinct_                   // line 27 — 哈希去重开关

ObScalarAggregateOp : public ObGroupByOp       // ob_scalar_aggregate_op.h:41
  started_           — 是否已经开始执行
  dir_id_            — 内存目录 ID
  hp_infras_mgr_     — 哈希分区管理器（DISTINCT 使用）
```

### 4.2 执行流程（ob_scalar_aggregate_op.cpp:102）

```
inner_get_next_row():
  1. started_ 检查 → 已启动则返回 OB_ITER_END（只输出一行）
  2. 取第一行 → aggr_processor_.prepare(group_row)
  3. 循环取后续行直到 OB_ITER_END:
     → aggr_processor_.process(group_row)
  4. 子节点结束 → aggr_processor_.collect() 输出结果
  5. 空表 → aggr_processor_.collect_for_empty_set()
```

相比 Hash/Merge GroupBy，ScalarAggregate **没有分组逻辑**，所有行都送入同一个 group_row。

### 4.3 向量化实现（ob_scalar_aggregate_vec_op.h）

向量化版本 `ObScalarAggregateVecOp` 直接利用 `inner_get_next_batch` 批量处理。当子节点为空且 `support_fast_single_row_agg_` 为 true 时，通过 COUNT/SUM/MIN/MAX 的快速路径直接返回空集结果，不需要预计算。

---

## 5. Distinct Op — 去重算子

去重算子**不是**独立的物理算子——它是 Hash GroupBy / Merge GroupBy / ScalarAggregate 内部的去重路径。

### 5.1 HashDistinctOp（ob_hash_distinct_op.h:39）

```
ObHashDistinctOp : public ObOperator  // ob_hash_distinct_op.h:39
  // 多阶段处理：
  build_distinct_data()               // 构建去重哈希表
  do_unblock_distinct()               // 非阻塞去重
  do_block_distinct()                 // 阻塞去重
  by_pass_get_next_batch()            // bypass 批量输出
  process_state()                     // 状态机驱动
```

关键设计：

```
process_state():  // ob_hash_distinct_op.h:67
  ┌────────────────────────────────────┐
  │  1. build_distinct_data()          │
  │     构建 (DISTINCT 列 → 哈希表)    │
  │  2. do_unblock_distinct()          │
  │     非阻塞场景：逐行检查哈希表      │
  │  3. do_block_distinct()            │
  │     阻塞场景：全量构建后输出        │
  │  4. by_pass_get_next_batch()       │
  │     自适应 bypass 批量输出          │
  └────────────────────────────────────┘
```

### 5.2 MergeDistinctOp（ob_merge_distinct_op.h:32）

```
ObMergeDistinctOp : public ObOperator  // ob_merge_distinct_op.h:32
  Compare equal()                      // 比较相邻行是否相等
  deduplicate_for_batch()              // 排序去重（类比 sort + distinct）
```

用于**输入已排好序**的场景：逐行读入，与上一行比较，相等则跳过。

---

## 6. Aggregate Processor — 聚合函数计算引擎

`ObAggregateProcessor`（`ob_aggregate_processor.h:344`）是所有聚合算子的**心脏**，负责实际的聚合函数计算。

### 6.1 类结构

```
ObAggregateProcessor :                    // ob_aggregate_processor.h:344
  IAggrFuncCtx                            // line 348 — 聚合函数上下文接口
  LinearInterAggrFuncCtx                  // line 355 — 线性插值上下文
  ExtraResult                             // line 388 — 额外结果（DISTINCT等）
  HashBasedDistinctExtraResult            // line 433 — 基于哈希的 DISTINCT
  TopKFreHistExtraResult                  // line 485 — TopK / 频率直方图
  GroupConcatExtraResult                  // line 500 — GROUP_CONCAT
  HybridHistExtraResult                   // line 567 — 混合直方图
  AggrCell                                // line 623 — 一个组的聚合单元
  ObSelector                              // line 715 — 向量化选择器
  GroupRow                                // line 782 — 聚合组行
  ObAggregateCalcFunc                     // line 1432 — 聚合计算函数
```

### 6.2 核心接口

```
init_group_rows(count)              — 初始化 count 个分组行
prepare(group_row)                  — 准备行（初始化聚合上下文）
process(group_row)                  — 对一行执行聚合
collect()                           — 收集聚合结果到输出表达式
collect_for_empty_set()             — 空集聚合（返回 NULL 行）
process_batch(group_row, brs)       — 批量处理
collect_result_batch()              — 批量收集结果
```

### 6.3 聚合计算函数（ObAggregateCalcFunc, ob_aggregate_processor.h:1432）

支持的主要聚合函数：

| 方法 | 行号 | 说明 |
|------|------|------|
| `max_calc` | 1081 | MAX 计算 |
| `min_calc` | 1086 | MIN 计算 |
| `add_calc` | 1093 | SUM 累加 |
| `approx_count_calc_batch` | 1003 | APPROX_COUNT |
| `top_fre_hist_calc_batch` | 1026 | TOP_FRE_HISTOGRAM |
| `bitwise_calc_batch` | 1033 | BIT_AND/OR/XOR |
| `grouping_calc_batch` | 1040 | GROUPING 函数 |
| `grouping_id_calc_batch` | 1044 | GROUPING_ID 函数 |
| `linear_inter_calc` | 1102 | MEDIAN / PERCENTILE 线性插值 |
| `search_op_expr` | 1099 | JSON 聚合搜索 |
| `get_hybrid_hist_result` | 1157 | 混合直方图 |
| `get_json_arrayagg_result` | 1161 | JSON_ARRAYAGG |
| `get_ora_xmlagg_result` | 1174 | XMLAGG |
| `get_array_agg_result` | 1193 | ARRAY_AGG |

### 6.4 部分聚合 vs 全局聚合

部分聚合（Partial Aggregation）：

```
  max_calc @1081:
    对当前批次的 datum 执行 MAX
    结果保存在 group_row 的 aggr_cell 中
    不输出，保留在处理器内部

  collect @830:
    将 Accumulated 的聚合值
    写入到算子输出表达式
    → 此时才是"产出"
```

三阶段聚合的三个层次：

```
  1. FIRST_STAGE  → 部分聚合（reduce 量）
  2. SECOND_STAGE → 合并部分结果
  3. THIRD_STAGE  → 全局聚合输出
```

### 6.5 哈希去重（HashBasedDistinctExtraResult, ob_aggregate_processor.h:433）

```
HashBasedDistinctExtraResult:
  insert_row(exprs)                           — 插入一行到去重哈希表
  insert_row_for_batch(exprs, batch_size)     — 批量插入
  get_next_unique_hash_table_row(store_row)   — 获取下一行不重复行
  get_next_unique_hash_table_batch(...)       — 批量获取
  build_distinct_data(exprs)                  — 构建去重哈希表
  build_distinct_data_for_batch(exprs, size)  — 批量构建
```

---

## 7. Hash vs Merge GroupBy 的选择策略

优化器根据以下因素选择 Hash 或 Merge GroupBy：

| 因素 | Hash GroupBy | Merge GroupBy |
|------|-------------|---------------|
| 输入有序性 | 不需要 | 需要 |
| 数据重复率高 | 优（哈希表命中率高） | 优（扫描即聚合） |
| 数据基数高 | 可能溢出到磁盘 | 只需扫描 |
| ROLLUP | 不支持（只有 Merge 支持） | 原生支持 |
| 内存占用 | 高（整个哈希表在内存） | 低（只保留一行） |
| 自适应能力 | 强（bypass / 分区溢出） | 弱 |
| 向量化执行 | 支持 | 支持 |

**优化器决策路径**：
1. 如果输入有序 → 倾向于 Merge GroupBy
2. 如果 `est_group_cnt_` 很小 → 倾向于 Hash GroupBy（内存装得下）
3. 如果包含 ROLLUP → 必须 Merge GroupBy
4. 如果 `est_group_cnt_` 很大且无序 → Hash GroupBy + 分区溢出

---

## 8. 设计决策分析

### 8.1 自适应 Bypass —— 避免无意义哈希

核心问题：当分组键基数接近行数（`SELECT DISTINCT pk_col FROM t`）时，哈希表的探测成本与直接输出无异。

Bypass 机制在探测阶段检测到低重复率后，**跳过哈希表构建，直接从子节点读取并输出**。

### 8.2 溢出到磁盘的递归设计

Hash GroupBy 的溢出采用**递归分区**设计：

```
  1. 初始：使用 hash(val) 的高 32bit 作为分区号
  2. 溢出时：将不匹配的行写出到对应分区
  3. 重新 load_data：从磁盘读取一个溢出分区
  4. 再次哈希：使用 hash(val) 的下 32bit
  5. 递归：如果还溢出，继续分区（最多 256 个分区）
```

这种设计保证了**最坏情况下也能完成聚合**，只是性能下降。

### 8.3 预取优化（Prefetch）

`ObGroupRowHashTable::prefetch`（`ob_hash_groupby_op.h:123`）在批处理模式下使用 CPU 预取指令，分三阶段拉取数据到缓存：

```
  阶段1: 预取桶数组（bucket base address）
  阶段2: 预取 item 链表头
  阶段3: 预取 groupby_store_row 数据
```

仅在桶数 > 4096 时启用，避免小表缓存污染。

### 8.4 向量化聚合

每个聚合算子都有 `_vec_op` 变体：

| 原始算子 | 向量化版本 |
|---------|-----------|
| `ObHashGroupByOp` | `ob_hash_groupby_vec_op.h` |
| `ObMergeGroupByOp` | `ob_merge_groupby_vec_op.h` |
| `ObScalarAggregateOp` | `ob_scalar_aggregate_vec_op.h` |
| `ObHashDistinctOp` | `ob_hash_distinct_vec_op.h` |
| `ObMergeDistinctOp` | `ob_merge_distinct_vec_op.h` |
| `ObGroupByOp` | `ob_groupby_vec_op.h` |

向量化版本的主要优化：
- 批量哈希计算（`calc_groupby_exprs_hash_batch`）
- 批量分组键比较（`group_child_batch_rows`）
- 使用 `ObSelector` 记录组内行索引（`ob_aggregate_processor.h:715`）
- 分离排序键与附加列（与 SortVecOp 类似）

---

## 9. 源码索引

### 核心算子

| 文件 | 行数 | 说明 |
|------|------|------|
| `ob_groupby_op.h` | 160 | 分组基类 ObGroupBySpec / ObGroupByOp |
| `ob_scalar_aggregate_op.h` | 70 | ScalarAggregateOp |
| `ob_scalar_aggregate_op.cpp` | 250 | ScalarAggregateOp 实现 |
| `ob_hash_groupby_op.h` | 651 | HashGroupByOp 声明 |
| `ob_hash_groupby_op.cpp` | 3251 | HashGroupByOp 实现 |
| `ob_merge_groupby_op.h` | 292 | MergeGroupByOp 声明 |
| `ob_merge_groupby_op.cpp` | 1981 | MergeGroupByOp 实现 |

### 哈希结构

| 文件 | 行数 | 说明 |
|------|------|------|
| `ob_exec_hash_struct.h` | 520 | ObExtendHashTable、ObGbyBloomFilter |
| `ob_exec_hash_struct.cpp` | <20 | 较少实现（大多 template header-only） |
| `ob_hash_agg_variant.h` | 627 | HashAggVariant（boost::variant） |
| `ob_hash_agg_variant.cpp` | <50 | 较少实现 |

### 聚合处理器

| 文件 | 行数 | 说明 |
|------|------|------|
| `ob_aggregate_processor.h` | 1600+ | ObAggregateProcessor |
| `ob_aggregate_processor.cpp` | 1400+ | 聚合函数实现 |

### 去重算子

| 文件 | 行数 | 说明 |
|------|------|------|
| `ob_distinct_op.h` | 80 | ObDistinctSpec / ObDistinctOp 基类 |
| `ob_hash_distinct_op.h` | 92 | HashDistinctOp |
| `ob_hash_distinct_op.cpp` | 900+ | HashDistinctOp 实现 |
| `ob_merge_distinct_op.h` | 85 | MergeDistinctOp |
| `ob_merge_distinct_op.cpp` | 150 | MergeDistinctOp 实现 |

### 辅助

| 文件 | 行数 | 说明 |
|------|------|------|
| `ob_aggregate_util.h` | 100+ | 聚合工具函数 |
| `ob_adaptive_bypass_ctrl.h` | 120 | 自适应 bypass 控制 |
| `ob_adaptive_bypass_ctrl.cpp` | 150 | bypass 实现 |

### 向量化版本

| 文件 | 说明 |
|------|------|
| `ob_groupby_vec_op.h/cpp` | GroupBy 基类向量化 |
| `ob_hash_groupby_vec_op.h/cpp` | HashGroupBy 向量化 |
| `ob_merge_groupby_vec_op.h/cpp` | MergeGroupBy 向量化 |
| `ob_scalar_aggregate_vec_op.h/cpp` | ScalarAggregate 向量化 |
| `ob_hash_distinct_vec_op.h/cpp` | HashDistinct 向量化 |
| `ob_merge_distinct_vec_op.h/cpp` | MergeDistinct 向量化 |
| `ob_exec_hash_struct_vec.h/cpp` | 哈希结构向量化实现 |

---

## 10. 总结

OceanBase 的聚合算子体系设计清晰：

1. **分层抽象**：`ObGroupByOp` 分离"分组逻辑"与"聚合计算"
2. **多种执行策略**：Hash（内存 + 磁盘溢出）、Merge（有序扫描）、Scalar（单组）
3. **自适应执行**：AutoBypass 在运行时根据数据特征切换策略
4. **去重统一**：Distinct 作为聚合算子的子功能实现
5. **向量化支持**：每种算子都有完整的向量化版本
6. **溢出安全**：Hash GroupBy 的分区溢出保证任意数据量下的正确执行
7. **性能优化**：LLC NDV 估算、CPU 预取、快速 memcmp、小表 bypass
