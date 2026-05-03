# 查询优化器 — 执行计划生成与代价估算

> 分析日期：2026-05-03
> 分析目标：OceanBase 查询优化器（Query Optimizer）
> 源码位置：`src/sql/optimizer/`
> 相关文章：[08-SSTable Index](08-sstable-index.md)、[09-DAS](09-das.md)、[14-Memtable Hash](14-memtable-hash.md)

---

## 1. 概述

查询优化器是 SQL 执行引擎的"大脑"。它的使命是将 SQL 解析树转化为**最优的执行计划**——即在所有可能的执行路径中，选择代价最小的那个。

OceanBase 的优化器位于 `src/sql/optimizer/` 目录，采用类似 Cascades 的架构（但不等同于完整的 Cascades 模型），核心设计理念是：

1. **逻辑计划（Logical Plan）** — 描述"做什么"（如 JOIN、SCAN、FILTER），与物理实现无关
2. **物理计划（Physical Plan）** — 描述"怎么做"（如 HASH JOIN、TABLE SCAN、INDEX LOOKUP），指定具体的算法和访问路径
3. **代价模型（Cost Model）** — 量化不同物理实现的成本（CPU/IO/网络），驱动最优选择

### 1.1 优化器在 SQL 引擎中的位置

```
SQL 字符串
    │
    ▼
┌─────────────┐
│  Parser      │  语法解析 → 生成解析树 (Parse Tree)
└─────────────┘
    │
    ▼
┌─────────────┐
│  Resolver   │  语义解析 → 生成 DML Stmt (AST)
└─────────────┘
    │
    ▼
┌─────────────────────────────────┐
│  Optimizer                      │  ← 本文分析范围
│  ┌───────────────────────────┐  │
│  │ ObOptimizer::optimize()   │  │
│  │   ├─ init_env_info()      │  │  环境初始化
│  │   ├─ generate_plan()      │  │  核心优化流程
│  │   └─ plan_traverse_loop() │  │  计划后处理遍历
│  └───────────────────────────┘  │
└─────────────────────────────────┘
    │  ObLogPlan (逻辑计划)
    ▼
┌──────────────────────┐
│  Plan Rewriter       │  plan rewriting rules
└──────────────────────┘
    │  ObPhysicalPlan (物理计划)
    ▼
┌──────────────────────┐
│  Code Generator      │  生成 ObOpSpec / ObOperator
└──────────────────────┘
    │
    ▼
┌──────────────────────┐
│  Executor (执行引擎)  │  DAS / SQL Engine
└──────────────────────┘
```

### 1.2 核心输入输出

- **输入**: `ObDMLStmt`（解析后的 SQL 语句结构，如 `ObSelectStmt`、`ObInsertStmt` 等）
- **输出**: `ObLogPlan`（逻辑计划树），经过计划遍历后生成为最终可执行的计划
- **上下文**: `ObOptimizerContext`（优化器上下文，持有 session 信息、统计信息、hint 等）

---

## 2. 核心数据结构

### 2.1 优化器入口: `ObOptimizer`

文件: `src/sql/optimizer/ob_optimizer.h` (L175-L248)

```cpp
class ObOptimizer {
public:
    ObOptimizer(ObOptimizerContext &ctx) : ctx_(ctx) {}
    virtual int optimize(ObDMLStmt &stmt, ObLogPlan *&plan);
    // ...
private:
    ObOptimizerContext &ctx_;
};
```

`ObOptimizer::optimize()` 是优化器的入口函数（`ob_optimizer.cpp` L29-L77）：

```
ObOptimizer::optimize(stmt, logical_plan)
    ├── init_env_info(stmt)           ← 初始化并行策略、统计信息、环境参数
    ├── generate_plan_for_temp_table  ← 处理临时表（CTE/With子句）
    ├── create(ObLogPlan)             ← 创建逻辑计划对象
    ├── plan->generate_plan()         ← 核心优化流程
    │     ├── generate_raw_plan()
    │     │     ├── generate_normal_raw_plan()
    │     │     │     └── ObSelectLogPlan::allocate_plan_top()
    │     │     │           ├── candi_allocate_subplan_filter_for_where()
    │     │     │           ├── candi_allocate_group_by()
    │     │     │           ├── candi_allocate_window_function()
    │     │     │           ├── candi_allocate_distinct()
    │     │     │           ├── candi_allocate_order_by()
    │     │     │           ├── candi_allocate_limit()
    │     │     │           └── ...
    │     │     └── generate_plan_tree()
    │     │           ├── generate_join_orders()    ← 连接顺序枚举
    │     │           └── init_candidate_plans()    ← 候选计划初始化
    │     └── do_post_plan_processing()
    └── plan_traverse_loop()
          ├── PX_RESCAN              ← 并行优化
          ├── RUNTIME_FILTER         ← 运行时过滤器
          ├── ALLOC_GI               ← 粒度迭代器
          ├── ALLOC_OP               ← 算子分配
          ├── OPERATOR_NUMBERING     ← 算子编号
          ├── EXCHANGE_NUMBERING     ← Exchange 编号
          ├── ALLOC_EXPR             ← 表达式分配
          ├── PROJECT_PRUNING        ← 投影裁剪
          ├── GEN_SIGNATURE          ← 计划签名
          └── ...
```

### 2.2 逻辑计划: `ObLogPlan`

文件: `src/sql/optimizer/ob_log_plan.h` (L273-L2278)

`ObLogPlan` 是逻辑计划的容器，一个 ObLogPlan 对应一个 SQL 语句的优化。

**关键成员**：
- `stmt_` — 对应的 DML 语句
- `root_` — 计划树的根节点（`ObLogicalOperator`）
- `optimizer_context_` — 优化器上下文
- `candidates_` — 候选计划列表（`CandidatePlan` 的集合）
- `pred_sels_` — 谓词选择率列表

**计划生成流程**：

```cpp
int ObLogPlan::generate_plan()
{
    // 1. 生成原始计划树
    generate_raw_plan()
        ├── init_plan_info()             ← 初始化等值集合等
        └── generate_normal_raw_plan()   ← 特定语句类型的计划生成
    
    // 2. 生成 Join Order（物理计划候选）
    generate_plan_tree()
        ├── generate_join_orders()       ← 枚举连接顺序
        └── init_candidate_plans()       ← 初始化候选计划
    
    // 3. 后处理
    do_post_plan_processing()
    
    // 4. 计划树遍历（多重遍历）
    plan_traverse_loop(...)
}
```

`ObLogPlan::generate_normal_raw_plan()` 的典型实现（以 SELECT 为例）：

```
ObSelectLogPlan::allocate_plan_top()
    ├── candi_allocate_subplan_filter_for_where()
    ├── candi_allocate_hybrid_fusion()
    ├── candi_allocate_count()
    ├── candi_allocate_group_by()
    │     ├── candi_allocate_normal_group_by()
    │     │     ├── candi_allocate_hash_group_by()
    │     │     └── candi_allocate_merge_group_by()
    │     └── candi_allocate_groupingset_group_by()
    ├── candi_allocate_window_function()
    ├── candi_allocate_distinct()
    ├── candi_allocate_for_update()
    ├── candi_allocate_order_by()
    ├── candi_allocate_limit()
    └── candi_allocate_select_into()
```

### 2.3 优化器上下文: `ObOptimizerContext`

文件: `src/sql/optimizer/ob_optimizer_context.h` (L211-L1000+)

这是优化器的"中央仓库"，携带整个优化过程所需的所有信息：

```
ObOptimizerContext
    ├── Query Context (query_ctx_)
    ├── Session Info (session_info_)
    ├── Schema Guard (schema_guard_)
    ├── Exec Context (exec_ctx_)
    ├── Stats Manager (opt_stat_manager_)
    ├── Column Usage Info
    ├── Table Partition Info
    ├── Temp Table Info
    ├── Plan Notes
    ├── Parallel Policy
    ├── Cost Model Type (NORMAL / VECTOR)
    ├── Join Type Enable Flags
    ├── System Statistics (OptSystemStat)
    └── ...
```

### 2.4 逻辑算子: `ObLogicalOperator`

文件: `src/sql/optimizer/ob_logical_operator.h`

逻辑算子是计划树的基本节点。每个逻辑算子对应一个 SQL 操作的概念：

| 逻辑算子类 | 对应操作 |
|---|---|
| `ObLogTableScan` | 表扫描 |
| `ObLogJoin` | 连接（Join） |
| `ObLogGroupBy` | 分组聚合 |
| `ObLogSort` | 排序 |
| `ObLogLimit` | 限制（Limit/Fetch） |
| `ObLogDistinct` | 去重 |
| `ObLogExchange` | 数据交换（PX） |
| `ObLogSubPlanFilter` | 子查询过滤器 |
| `ObLogWindowFunction` | 窗口函数 |
| `ObLogInsert/Update/Delete` | DML 操作 |
| `ObLogSet` | 集合操作（Union/Intersect） |

每个逻辑算子都包含：
- 输出表达式列表（`output_exprs_`）
- 过滤条件列表（`filter_exprs_`、`pushdown_filter_exprs_`）
- 子节点指针
- 代价信息（`cost_`、`card_`）
- 分片信息（`sharding_info_`）

### 2.5 候选计划: `CandidatePlan` 与竞争机制

```cpp
struct CandidatePlan {
    ObLogicalOperator *plan_tree_;  // 候选计划的根节点
};

class ObLogPlan {
    ObCandidatePlans candidates_;  // 所有候选计划
};
```

优化器为每种操作生成多个候选计划（如 HASH JOIN vs MERGE JOIN），通过代价比较选出最优：

```
generate_plan_tree()
    ├── generate_join_orders()          ← 枚举不同的连接顺序和连接算法
    └── init_candidate_plans()
          └── get_minimal_cost_candidate()  ← 选择代价最小的候选计划
                └── 遍历所有候选计划，比较 cost 值
```

---

## 3. 访问路径与代价估算

### 3.1 访问路径估算: `ObAccessPathEstimation`

文件: `src/sql/optimizer/ob_access_path_estimation.h` (L68-L412)

这是连接 SQL 优化器和存储引擎的关键组件。它负责估算每个访问路径（全表扫描、主键扫描、二级索引扫描）的行数和代价。

#### 行数估算方法

OceanBase 支持四种行数估算方法，定义在 `ob_opt_est_cost_model.h` (L36-L43)：

```cpp
enum ObBaseTableEstBasicMethod {
    EST_INVALID   = 0,
    EST_DEFAULT   = 1 << 0,   // 默认估算（无统计信息时使用）
    EST_STAT      = 1 << 1,   // 基于持久化统计信息
    EST_STORAGE   = 1 << 2,   // 基于存储层实时估算
    EST_DS_BASIC  = 1 << 3,   // 动态采样 - 基础统计
    EST_DS_FULL   = 1 << 4,   // 动态采样 - 完整统计
};
```

#### 估算优先级

`ObAccessPathEstimation::choose_best_est_method()` 根据可用性选择最优估算方法：

```
优先级: STAT > STORAGE > DS_FULL > DS_BASIC > DEFAULT
```

具体流程 (`ob_access_path_estimation.cpp`)：

```
estimate_rowcount(ctx, paths, is_inner_path, filter_exprs, method)
    ├── classify_paths(paths, normal_paths, geo_paths, index_merge_paths)
    │     └── 将路径分为普通路径、空间索引路径、索引合并路径
    ├── get_valid_est_methods()
    ├── choose_best_est_method()
    ├── do_estimate_rowcount()
    │     └── 根据选择的方法估算：
    │           ├── process_statistics_estimation()  ← 统计信息估算
    │           ├── process_storage_estimation()     ← 存储层估算
    │           └── process_dynamic_sampling_estimation() ← 动态采样
    └── process_common_estimate_rowcount()  ← 公共处理（选择率计算等）
```

#### 表元数据: `ObTableMetaInfo`

```cpp
struct ObTableMetaInfo {
    int64_t table_row_count_;        // 统计信息中的表总行数
    double part_size_;               // 最佳分区的数据大小
    double average_row_size_;        // 平均行大小
    double row_count_;               // 经过过滤后的行数（关键输出）
    int64_t part_count_;             // 分区数
    int64_t micro_block_size_;       // 微块大小
    int64_t micro_block_count_;      // 微块数量
    // ...
};
```

#### 索引元数据: `ObIndexMetaInfo`

```cpp
struct ObIndexMetaInfo {
    uint64_t index_id_;              // 索引 ID
    int64_t index_micro_block_size_; // 索引微块大小
    double index_part_size_;         // 索引分区数据大小
    bool is_index_back_;             // 是否需要回表
    bool is_unique_index_;           // 是否是唯一索引
    bool is_global_index_;           // 是否全局索引
    int64_t index_micro_block_count_;// 索引微块数量
    // ...
};
```

### 3.2 扫表代价信息: `ObCostTableScanInfo`

```cpp
struct ObCostTableScanInfo {
    uint64_t table_id_;
    uint64_t index_id_;
    ObTableMetaInfo *table_meta_info_;
    ObIndexMetaInfo index_meta_info_;
    
    // 过滤器分类
    ObSqlArray<ObRawExpr*> prefix_filters_;           // 匹配索引前缀的过滤条件
    ObSqlArray<ObRawExpr*> postfix_filters_;           // 回表前的过滤条件
    ObSqlArray<ObRawExpr*> table_filters_;             // 回表后的过滤条件
    
    // 估算结果
    double prefix_filter_sel_;          // 前缀过滤选择率
    double postfix_filter_sel_;         // 后置过滤选择率
    double table_filter_sel_;           // 表过滤选择率
    double logical_query_range_row_count_;  // 逻辑查询范围行数
    double phy_query_range_row_count_;      // 物理查询范围行数
    double index_back_row_count_;           // 需要回表的行数
    double output_row_count_;               // 最终输出行数
    // ...
};
```

---

## 4. 代价估算的关键公式

### 4.1 代价模型参数

文件: `src/sql/optimizer/ob_opt_est_parameter_normal.h`

OceanBase 的代价模型使用了一系列通过 benchmark 标定的常数：

```
// CPU 相关代价（以 CPU 周期数衡量）
NORMAL_CPU_TUPLE_COST                = 0.030 * DEFAULT_CPU_SPEED    // 每行 CPU 基础代价
NORMAL_TABLE_SCAN_CPU_TUPLE_COST     = 0.372 * DEFAULT_CPU_SPEED    // 表扫描每行 CPU 代价
NORMAL_CPU_OPERATOR_COST             = 0.033 * DEFAULT_CPU_SPEED    // 算子 CPU 代价
NORMAL_JOIN_PER_ROW_COST             = 0.292 * DEFAULT_CPU_SPEED    // 连接每行代价
NORMAL_BUILD_HASH_PER_ROW_COST       = 0.252 * DEFAULT_CPU_SPEED    // 构建哈希表每行代价
NORMAL_PROBE_HASH_PER_ROW_COST       = 0.232 * DEFAULT_CPU_SPEED    // 探测哈希表每行代价

// IO 相关代价
NORMAL_MICRO_BLOCK_SEQ_COST          = 4.12 * DISK_SEQ_READ / BLOCK_SIZE   // 顺序读微块代价
NORMAL_MICRO_BLOCK_RND_COST          = 5.45 * DISK_RND_READ / BLOCK_SIZE   // 随机读微块代价
NORMAL_FETCH_ROW_RND_COST            = 2.25 * DEFAULT_CPU_SPEED     // 随机获取一行代价

// 网络相关代价
NORMAL_NETWORK_TRANS_PER_BYTE_COST   = 0.012 * DEFAULT_NETWORK_SPEED // 网络传输每字节代价
```

### 4.2 系统统计信息

```cpp
struct OptSystemStat {
    double cpu_speed_;               // CPU 速度
    double disk_seq_read_speed_;     // 磁盘顺序读速度
    double disk_rnd_read_speed_;     // 磁盘随机读速度
    double network_speed_;           // 网络速度
};
```

系统统计信息可通过 `ob_opt_stat_manager` 持久化存储，若不可用则使用默认值。

### 4.3 扫表代价计算

代价模型接口 (`ob_opt_est_cost.h` 和 `ob_opt_est_cost_model.h`)：

```
cost_table(est_cost_info, parallel, cost)
    ├── cost = 0
    ├── 计算 IO 代价：
    │     ├── 前缀过滤器扫描代价
    │     │     = micro_block_read_count × NORMAL_MICRO_BLOCK_SEQ_COST
    │     │   + row_count × NORMAL_TABLE_SCAN_CPU_TUPLE_COST
    │     ├── 后置过滤器代价
    │     │     = row_count × filter_count × NORMAL_CPU_OPERATOR_COST
    │     └── 回表代价（二级索引）
    │           = index_back_row_count × NORMAL_FETCH_ROW_RND_COST
    │           + index_back_micro_block_count × NORMAL_MICRO_BLOCK_RND_COST
    └── 计算 CPU 代价：
          ├── 表达式计算代价
          └── 投影列代价（按类型区分 INT/NUMBER/CHAR/LOB）
```

```
cost_index_back(est_cost_info, row_count, limit_count, index_back_cost)
    ├── 估算回表行数（逻辑行数 × 选择率）
    ├── 计算回表 IO 代价（随机读微块）
    └── 计算回表 CPU 代价
```

### 4.4 连接代价计算

**Nested Loop Join**:
```
cost = left_cost 
     + left_card × right_cost 
     + left_card × right_card × other_cond_sel × NORMAL_JOIN_PER_ROW_COST
```

**Hash Join**:
```
cost = left_cost 
     + right_cost 
     + right_card × NORMAL_BUILD_HASH_PER_ROW_COST 
     + left_card × NORMAL_PROBE_HASH_PER_ROW_COST 
     + output_card × NORMAL_JOIN_PER_ROW_COST
```

**Merge Join**:
```
cost = left_cost + right_cost 
     + (left_sort_cost + right_sort_cost) if inputs not sorted
     + (left_card + right_card) × NORMAL_JOIN_PER_ROW_COST
```

### 4.5 选择率计算

`ObOptSelectivity` 类负责计算谓词选择率：

```
选择率估算方法：
  ├── 等值条件 (=):       1 / NDV (唯一值数)
  ├── 范围条件 (>, <, BETWEEN): 基于直方图或均匀分布估算
  ├── IN 条件:            IN 元素数 / NDV（裁剪后）
  ├── LIKE 条件:         基于默认选择率（通常 0.01-0.1）
  └── 复合条件 (AND/OR): AND = 乘积，OR = 1 - (1-p1)(1-p2)
```

相关系数模型（`ObEstCorrelationType`）：
- `INDEPENDENT`（独立假设）— 默认，假设列间无相关性
- `PARTIAL`（部分相关）
- `FULL`（完全相关）

---

## 5. 连接顺序优化

### 5.1 连接顺序枚举

文件: `src/sql/optimizer/ob_join_order.h` 和 `ob_join_order_enum*.h`

连接顺序优化是优化器最核心的算法之一。OceanBase 实现了多种连接顺序枚举算法：

```
ObJoinOrder (连接顺序主控)
    ├── 构建表依赖图
    ├── 应用 Skyline Pruning (ob_skyline_prunning.h)
    │     └── 剪枝掉那些"没有优势"的访问路径
    └── 枚举连接顺序
          ├── ObJoinOrderEnum (通用枚举)
          │     └── DPccp 算法 (Dynamic Programming with Connected Subgraph Complement)
          ├── ObJoinOrderEnumIdp (迭代动态规划)
          │     └── IDP (Iterative Dynamic Programming) — 介于穷举和启发式之间
          └── ObJoinOrderEnumPermutation (排列枚举)
                └── 基于排列的枚举（简单场景）
```

**枚举阈值控制**：

```cpp
// 通过系统变量和 hint 控制枚举规模
ctx_.set_join_order_enum_threshold(join_order_enum_threshold);   // 默认 10 个表
ctx_.set_max_permutation(max_permutation);                        // 默认 2000 种排列
ctx_.set_idp_reduction_threshold(idp_reduction_threshold);        // 默认 5000 (IDP 剪枝阈值)
```

### 5.2 连接类型与算法

**支持的连接类型** (`ObJoinType`)：
- INNER JOIN
- LEFT/RIGHT OUTER JOIN
- FULL OUTER JOIN
- SEMI JOIN / ANTI JOIN
- LEFT SEMI / LEFT ANTI

**支持的连接算法**（三种物理实现）：

| 连接算法 | 适用场景 | 代价特征 |
|---|---|---|
| Nested Loop Join | 小表驱动大表，索引查找 | O(left_card × right_lookup_cost) |
| Hash Join | 等值连接，大表 | O(build_cost + probe_cost) |
| Merge Join | 有序输入，非等值连接 | O(left_sort + right_sort + merge) |

### 5.3 连接路径结构

```
ValidPathInfo (ob_join_order.h)
    ├── join_type_          — 连接类型
    ├── local_methods_      — 本地连接方法（NL/HASH/MERGE）
    ├── distributed_methods_ — 分布式连接方法
    ├── left_path_          — 左子树路径
    └── right_path_         — 右子树路径
```

### 5.4 Skyline Pruning（天际线剪枝）

`ObSkylinePrunning`（`ob_skyline_prunning.h`）是一个重要的优化技术：

对于同一张表的多个访问路径，如果路径 A 在**所有维度**（代价、行数等）上都不比路径 B 好，且至少在一个维度上更差，那么路径 A 就是"被支配"的，可以被剪枝。

```
Skyline 维度：
    ├── 代价 (cost)
    ├── 输出行数 (cardinality)
    └── 分片属性 (sharding)
```

---

## 6. 索引选择完整路径

OceanBase 的索引选择是优化器中最关键的决策之一，涉及从解析到执行的完整链路。

### 6.1 索引信息收集

```
SQL Parser 阶段：
    └── Resolver 收集所有可用的索引信息 (ObIndexInfoCache)

优化器阶段：
    ObOptimizer::init_env_info()
        └── 加载表的索引 schema 信息
    
    generate_plan_tree()
        └── generate_join_orders()
              └── 对每张表：
                    ├── 获取表的所有索引
                    ├── 为每个索引生成 AccessPath
                    │     ├── Primary Key Scan (主键扫描)
                    │     ├── Secondary Index Scan (二级索引扫描)
                    │     ├── Index Merge (索引合并)
                    │     └── Skip Scan (跳跃扫描)
                    └── Skyline Pruning 剪枝
```

### 6.2 AccessPath 评估

每个 AccessPath 包含：

```
AccessPath
    ├── 使用的索引 (index_id_)
    ├── 扫描范围 (ranges_)
    ├── 过滤器分类
    │     ├── prefix_filters (索引前缀过滤 → 下推)
    │     ├── postfix_filters (后续过滤)
    │     └── table_filters (回表后过滤)
    ├── 是否需要回表 (index_back_)
    └── 估算结果
          ├── logical_query_range_row_count_
          ├── phy_query_range_row_count_
          ├── index_back_row_count_
          └── output_row_count_
```

### 6.3 索引选择的决策树

```
对于给定的 SQL 条件和表：
    │
    ├── 是否有主键匹配的等值/范围条件？
    │     ├── 是 → 主键扫描 (最快，无回表)
    │     └── 否 → 检查二级索引
    │
    ├── 是否有二级索引的前缀匹配？
    │     ├── 是
    │     │     ├── 索引包含所有需要列？ → 覆盖索引扫描 (无回表)
    │     │     └── 需要回表
    │     │           ├── 回表率低 (< 5%) → 索引扫描
    │     │           └── 回表率高 → 全表扫描可能更优
    │     └── 否 → 全表扫描
    │
    └── 多个索引可同时使用？
          └── 是 → 考虑索引合并 (Index Merge)
```

### 6.4 关键决策：回表成本

`cost_index_back()` 是二级索引扫描代价的核心。回表意味着先从索引中找到主键值，再通过主键访问主表获取其他列。

```cpp
index_back_cost = 
    index_back_row_count × NORMAL_FETCH_ROW_RND_COST  // 回表行CPU代价
    + index_back_micro_block_count × NORMAL_MICRO_BLOCK_RND_COST  // 随机读IO代价
```

当 `index_back_row_count` 接近全表行数时，二级索引扫描的代价可能超过全表扫描。

### 6.5 与前面文章的关联

- **文章 08 (SSTable Index)**: 索引选择的基础 — 优化器需要了解 SSTable 的索引结构（B+ Tree 的组织方式、微块布局）才能准确估算索引扫描的 IO 代价
- **文章 09 (DAS)**: 优化器生成执行计划后，DAS（Direct Access Service）负责实际的扫描执行。优化器在 `gen_das_table_location_info()` 中决定 DAS 扫描的参数
- **文章 14 (Memtable Hash)**: 在内存表中，Memtable 使用 Hash 索引加速点查。优化器需要区分 Memtable 的行数（内存中未刷盘的增量数据）和 SSTable 的行数

---

## 7. 数据流全景

### 7.1 优化器架构图

```
┌──────────────────────────────────────────────────────────────────┐
│                      ObOptimizerContext                          │
│  ┌──────────┐ ┌───────────┐ ┌─────────┐ ┌──────────────────┐   │
│  │ Stmt     │ │ Session   │ │ Schema  │ │ System Statistics│   │
│  └──────────┘ └───────────┘ └─────────┘ └──────────────────┘   │
│  ┌──────────┐ ┌───────────┐ ┌─────────┐ ┌──────────────────┐   │
│  │Query Ctx │ │ Exec Ctx  │ │ OptStat │ │ ColumnUsageInfo  │   │
│  └──────────┘ └───────────┘ └─────────┘ └──────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
                              │
    ┌─────────────────────────┼─────────────────────────┐
    │                         │                         │
    ▼                         ▼                         ▼
┌────────────────┐  ┌──────────────────┐  ┌──────────────────────┐
│ ObOptimizer     │  │ ObAccessPath     │  │ ObJoinOrder          │
│ (入口/编排)      │  │ Estimation       │  │ (连接顺序枚举)        │
│                 │  │ (行数/代价估算)    │  │                      │
│ optimize() ─────┼──► estimate_        │  │ DPccp / IDP /         │
│ generate_plan() │  │ rowcount()       │  │ Permutation           │
│                 │  │ cost_table()     │  │                       │
│ plan_traverse() │  │ cost_nestloop()  │  │ Skyline Pruning       │
└────────────────┘  └──────────────────┘  └──────────────────────┘
                              │                         │
                              ▼                         ▼
┌──────────────────────────────────────────────────────────────────┐
│                    ObLogPlan (逻辑计划容器)                        │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    计划树 (Logical Operator Tree)             │ │
│  │                                                              │ │
│  │              ObLogicalOperator (root)                        │ │
│  │                    │                                         │ │
│  │              ObLogSort / ObLogLimit                          │ │
│  │                    │                                         │ │
│  │              ObLogGroupBy / ObLogDistinct                    │ │
│  │                    │                                         │ │
│  │              ObLogJoin (NL/HASH/MERGE)                       │ │
│  │                 ╱      ╲                                     │ │
│  │    ObLogTableScan    ObLogTableScan                          │ │
│  │       (主键扫描)       (索引扫描+回表)                          │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  CandidatePlan[] (不同执行方案的候选列表)                           │
│      [HashJoin-IndexScan, NLJ-FullScan, MergeJoin-SortScan...]   │
│                   → get_minimal_cost_candidate()                 │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│              plan_traverse_loop (计划树遍历后处理)                  │
│                                                                   │
│  TraverseOp 遍历操作 (Top-down + Bottom-up):                      │
│    ALLOC_EXPR → PROJECT_PRUNING → EXCHANGE_NUMBERING              │
│    → OPERATOR_NUMBERING → ALLOC_OP → GEN_SIGNATURE               │
│    → PX_ESTIMATE_SIZE → ALLOC_STARTUP_EXPR → ADJUST_SCAN_DIRECTION│
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│                    Code Generator → Executor                      │
│  (ob_static_engine_cg.h)                                         │
│    ObLogPlan → ObPhysicalPlan → ObOpSpec[] → ObOperator[]        │
└──────────────────────────────────────────────────────────────────┘
```

### 7.2 计划生成流程

```
输入 SQL: SELECT * FROM t1, t2 WHERE t1.a = t2.b AND t1.c > 100
                                │
                                ▼
    step 1: 语法解析
    ─────────────────
    ObSelectStmt (AST)
    ├── table_items: [t1, t2]
    ├── join_conditions: [t1.a = t2.b]
    └── filters: [t1.c > 100]
    
                                │
                                ▼
    step 2: 创建逻辑计划
    ─────────────────
    ObLogPlan::ObLogPlan(ctx, stmt)
    
                                │
                                ▼
    step 3: generate_plan_tree()
    ─────────────────
    generate_join_orders():
        ├── t1 的访问路径:
        │     ├── PK Scan (全表扫描) - cost: 100, card: 10000
        │     └── Index on c (索引范围扫描) - cost: 50, card: 100
        ├── t2 的访问路径:
        │     ├── PK Scan (全表扫描) - cost: 80, card: 8000
        │     └── Index on b (索引等值查找) - cost: 10, card: 1
        └── 连接顺序枚举:
              ├── (t1 ⋈ t2): t1 作为左表
              │     ├── NLJ: cost = 100 + 10000 * 10 = 100100
              │     ├── HashJoin: cost = 100 + 80 + 8000 * 0.25 + 10000 * 0.23 = 4420
              │     └── MergeJoin: cost = 100 + 80 + sort_cost + merge_cost = 3000
              └── (t2 ⋈ t1): t2 作为左表
                    ├── NLJ: cost = 80 + 8000 * 50 = 400080
                    ├── HashJoin: same as above = 4420
                    └── MergeJoin: same as above = 3000
    
    init_candidate_plans():
        └── 所有候选计划（树结构）:
              [
                NLJ(t1(index_c), t2(index_b)),
                HashJoin(t1, t2),
                MergeJoin(t1_sort, t2_sort),
                ...
              ]
        
        get_minimal_cost_candidate():
            └── 选出候选: MergeJoin(t1, t2)  cost=3000
    
                                │
                                ▼
    step 4: allocate_plan_top()
    ─────────────────
    在 Plan Tree 基础上添加:
        ├── 如果需要排序 → 添加 ObLogSort
        ├── 如果需要限制 → 添加 ObLogLimit
        └── 如果并行 → 添加 ObLogExchange
    
                                │
                                ▼
    step 5: plan_traverse_loop()
    ─────────────────
    遍历计划树，执行所有后处理操作
    
                                │
                                ▼
    step 6: 生成最终计划
    ─────────────────
    ObLogPlan → Code Generator → 执行引擎
```

---

## 8. 动态采样

文件: `src/sql/optimizer/ob_dynamic_sampling.h` (L300-L500)

当持久化统计信息不可用或过期时，优化器可以通过动态采样获取统计信息。

```
ObDynamicSampling
    ├── init(ctx, allocator)
    ├── get_ds_table_param()       — 获取采样参数
    ├── get_ds_table_degree()      — 获取采样并行度
    ├── get_ds_table_part_info()   — 获取分区信息
    └── 采样级别控制:
          ├── DS_BASIC: 快速采样，仅获取 NDV 和行数
          └── DS_FULL: 完整采样，获取直方图等详细信息
```

---

## 9. 设计决策

### 9.1 Cascades 架构 vs 传统 Volcano 模型

OceanBase 的优化器介于两者之间：

| 特性 | Volcano | Cascades | OceanBase |
|---|---|---|---|
| 规则引擎 | 有 | 有 | 部分（Plan Rewriter） |
| 逻辑/物理算子分离 | 隐式 | 显式 | 显式（ObLogicalOperator） |
| 代价驱动的枚举 | 是 | 是 | 是 |
| Memo 结构（共享子计划） | 否 | 是 | 否（CandidatePlan 列表） |
| Top-down 探索 | 否 | 是 | 混合（generate_plan_tree + 各种遍历） |

OceanBase 的核心设计是一个"增强的 Volcano"模型：
- 显式分离了逻辑和物理计划
- 使用 CandidatePlan 列表替代 Memo 结构
- 通过 generate_plan_tree() 进行自底向上的计划枚举
- 通过 plan_traverse_loop() 进行自顶向下的后处理

### 9.2 代价模型的设计

代价模型使用**基于标定的物理代价**，而非简单的行数估算：

```
总代价 = IO 代价 + CPU 代价 + 网络代价 + 内存代价

IO 代价 = ∑(微块数 × 微块读取代价)
CPU 代价 = ∑(行数 × 每行 CPU 代价)
网络代价 = ∑(数据量 × 网络传输代价)
```

优势：
- 可以精确比较不同物理操作的成本
- 支持异构硬件配置（通过系统统计信息调整）

劣势：
- 标定参数需要大量 benchmark 工作
- 参数值与硬件强相关，通用性有限

### 9.3 统计信息收集策略

OceanBase 支持三种策略的混合使用：

```
1. 持久化统计信息 (EST_STAT)
   └── 通过 ANALYZE 命令收集，存储在系统表中
   └── 包含：行数、NDV、直方图、MCV 等
   └── 优先级最高，最准确

2. 存储层估算 (EST_STORAGE)  
   └── 通过 RPC 发送估算请求到存储节点
   └── 存储节点根据实际微块数据估算范围行数
   └── 适用于有精确范围条件但统计信息过期的场景
   └── 使用优先级第二

3. 动态采样 (EST_DS_BASIC / EST_DS_FULL)
   └── 执行阶段采样少量数据
   └── DS_BASIC: 快速获取行数和 NDV
   └── DS_FULL: 获取完整统计信息
   └── 优先级第三

4. 默认估算 (EST_DEFAULT)
   └── 完全无统计信息时使用硬编码默认值
   └── 优先级最低
```

### 9.4 索引选择启发式

```
索引选择的关键因素（按重要性）：
    1. 是否匹配等值条件（'column = value'）→ 最高效
    2. 是否匹配范围条件（'column > value'）→ 高效
    3. 是否是覆盖索引（无需回表）→ 显著减少 IO
    4. 回表率（index_back_row_count / total_rows）→ < 5-10% 时索引扫描优
    5. 索引前缀匹配度（匹配的列数）→ 越多越好
    6. 索引列的 NDV → 高 NDV 的等值条件更高效
    7. 数据分布（直方图）→ 非均匀分布需直方图辅助
```

---

## 10. 与前面文章的关联

### 10.1 文章 08 — SSTable Index

SSTable 的索引结构（B+ Tree 的宏块 → 微块组织）直接影响优化器的 IO 代价估算：
- 微块大小（`micro_block_size_`）决定了顺序/随机读的成本
- 索引键的组织方式决定了 Range Scan 的效率
- 优化器通过 `ObTableMetaInfo::micro_block_count_` 估算扫描的微块数

### 10.2 文章 09 — DAS

DAS 是优化器生成的物理计划的执行者：
- 优化器决定使用 DAS 扫描还是 PX 扫描
- `gen_das_table_location_info()` 将优化器的表分区信息转化为 DAS 位置信息
- DAS 的 Batch Rescan 能力影响 NLJ 的代价估算

### 10.3 文章 14 — Memtable Hash

Memtable 的行数和 SSTable 的行数是分开估算的：
- 优化器在 `ObStorageEstimator::estimate_memtable_row_count()` 中单独估算 Memtable 行数
- Memtable 的 Hash 索引与 SSTable 的 B+ Tree 索引有完全不同的查找成本

### 10.4 共享存储（文章 15-16）

OceanBase 的分布式架构引入了额外的优化维度：
- 分区裁剪（Partition Pruning）— 减少需要扫描的分区
- 数据分布（Data Distribution）— 不同分片的连接需要 Exchange 操作
- 全局索引 vs 本地索引 — 全局索引涉及跨节点访问

---

## 11. 优化器关键路径源码索引

| 功能 | 文件 | 关键类/函数 | 行号 |
|---|---|---|---|
| 优化器入口 | `ob_optimizer.h` | `ObOptimizer` | L175 |
| 优化器入口 | `ob_optimizer.cpp` | `ObOptimizer::optimize()` | L29 |
| 环境初始化 | `ob_optimizer.cpp` | `init_env_info()` | L435 |
| 逻辑计划基类 | `ob_log_plan.h` | `ObLogPlan` | L273 |
| 计划生成 | `ob_log_plan.cpp` | `ObLogPlan::generate_plan()` | L11668 |
| 计划生成 | `ob_log_plan.cpp` | `ObLogPlan::generate_raw_plan()` | L11707 |
| 计划树生成 | `ob_log_plan.cpp` | `ObLogPlan::generate_plan_tree()` | L6821 |
| SELECT 计划 | `ob_select_log_plan.h` | `ObSelectLogPlan` | L42 |
| SELECT 计划分配 | `ob_select_log_plan.cpp` | `ObSelectLogPlan::allocate_plan_top()` | L5927 |
| 优化器上下文 | `ob_optimizer_context.h` | `ObOptimizerContext` | L211 |
| 访问路径估算 | `ob_access_path_estimation.h` | `ObAccessPathEstimation` | L68 |
| 访问路径估算 | `ob_access_path_estimation.cpp` | `estimate_rowcount()` | L28 |
| 代价估算 | `ob_opt_est_cost.h` | `ObOptEstCost` | L26 |
| 代价模型 | `ob_opt_est_cost_model.h` | `ObOptEstCostModel` | L104+ |
| 代价模型参数 | `ob_opt_est_parameter_normal.h` | 各种代价常数 | L1-100 |
| 连接顺序 | `ob_join_order.h` | `ObJoinOrder` | L33+ |
| 连接顺序枚举 | `ob_join_order_enum.h` | `ObJoinOrderEnum` | L1+ |
| 动态采样 | `ob_dynamic_sampling.h` | `ObDynamicSampling` | L300 |
| 选择率 | `ob_opt_selectivity.h` | `OptSelectivityCtx` | L134 |
| 存储估算 | `ob_storage_estimator.h` | `ObStorageEstimator` | L30 |
| 天际线剪枝 | `ob_skyline_prunning.h` | `ObSkylinePrunning` | L1+ |
| 表元信息 | `ob_opt_est_cost_model.h` | `ObTableMetaInfo` | L48-77 |
| 索引元信息 | `ob_opt_est_cost_model.h` | `ObIndexMetaInfo` | L121-145 |
| 扫表代价信息 | `ob_opt_est_cost_model.h` | `ObCostTableScanInfo` | L171+ |
| 连接代价信息 | `ob_opt_est_cost_model.h` | `ObCostNLJoinInfo` | L399+ |
| 排序代价信息 | `ob_opt_est_cost_model.h` | `ObSortCostInfo` | L475+ |
| 逻辑算子基类 | `ob_logical_operator.h` | `ObLogicalOperator` | L1+ |
| 逻辑表扫描 | `ob_log_table_scan.h` | `ObLogTableScan` | L1+ |
| 计划重写器 | `optimizer_plan_rewriter/` | 各种 `ObOptimizeRule` | 子目录 |

---

## 12. 总结

OceanBase 的查询优化器是一个**代价驱动的、面向分布式环境的优化器**，具有以下特点：

1. **多层次计划表示**：从 AST 到逻辑计划，再到物理计划，层层叠加优化
2. **混合统计信息来源**：支持持久化统计信息、存储层估算、动态采样三种方式
3. **丰富的连接算法**：NLJ、Hash Join、Merge Join 三种算法，支持分布式执行
4. **精细的代价模型**：基于标定的 CPU/IO/网络代价参数，区分行存储和列存储
5. **灵活的索引选择**：支持覆盖索引、回表优化、索引合并、Skip Scan

理解优化器的设计是理解 OceanBase SQL 执行引擎的关键——它决定了"一个查询会怎么执行"，是所有性能优化的起点。
