# 33-subquery-cte — 子查询与 CTE：子查询展开、Recursive CTE 实现

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

前 32 篇文章覆盖了从存储引擎（MVCC、Memtable、SSTable）到 SQL 执行器（DAS、优化器、PX、表达式求值）的完整技术栈。本文分析 SQL 中两个最复杂的查询模式——**子查询（Subquery）** 和 **公共表表达式（CTE）**。

子查询是嵌套在其他查询中的查询，而 CTE 是命名的临时结果集（可递归）。两者的核心挑战在于：

- **子查询**：如何优雅地在主表的逐行迭代中嵌入子查询计算，以及优化器能否将子查询展开为 Join
- **Recursive CTE**：如何实现循环的迭代计算、环路检测（Cycle Detection），以及搜索方法（BFS/DFS）

相关代码位于四个目录：

| 目录 | 用途 | 核心文件 |
|------|------|---------|
| `src/sql/engine/subquery/` | 子查询运行时物理算子 | `ob_subplan_filter_op.h/.cpp`, `ob_subplan_scan_op.h` |
| `src/sql/optimizer/` | 子查询优化器逻辑算子 | `ob_log_subplan_filter.h`, `ob_log_subplan_scan.h` |
| `src/sql/engine/recursive_cte/` | Recursive CTE 运行时 | `ob_recursive_union_op.h/.cpp`, `ob_fake_cte_table_op.h`, `ob_search_method_op.h`, `ob_recursive_inner_data_op.h/.cpp` |
| `sql/engine/set/` | UNION 算子的基础 | `ob_merge_set_op.h`（RecursiveUnion 的基类） |

---

## 1. 子查询类型

OceanBase 支持以下子查询类型：

### 1.1 Scalar Subquery（标量子查询）

```sql
SELECT name, (SELECT MAX(salary) FROM employees) AS max_sal FROM departments;
```

返回单个值，用在表达式位置。

### 1.2 EXISTS / NOT EXISTS

```sql
SELECT * FROM departments d
WHERE EXISTS (SELECT 1 FROM employees e WHERE e.dept_id = d.id);
```

布尔结果子查询，决定外层行是否保留。

### 1.3 IN / NOT IN

```sql
SELECT * FROM employees WHERE dept_id IN (SELECT id FROM departments);
```

等价于多个 OR 条件的集合成员测试。

### 1.4 ANY / ALL

```sql
SELECT * FROM employees WHERE salary > ALL (SELECT salary FROM executives);
```

与比较操作符结合的子查询形式。

### 1.5 Derived Table（派生表）

```sql
SELECT * FROM (SELECT id, name FROM employees) AS t;
```

子查询在 FROM 子句中，充当临时表。

---

## 2. 子查询执行算子

子查询的运行时执行由 `ObSubPlanFilterOp` 和 `ObSubQueryIterator` 协同完成。

### 2.1 ObSubPlanFilterOp——子查询过滤算子

**文件**：`src/sql/engine/subquery/ob_subplan_filter_op.h` (第 108–204 行)

`ObSubPlanFilterOp` 是一个特殊算子，其 **第一个子算子（child 0）是主表，后续子算子（child 1..N）分别是子查询**。它在主表的每次迭代中触发子查询计算。

**核心流程**（`ob_subplan_filter_op.cpp` 第 195-230 行 `inner_open`）：

```
SPF 的拓扑：
         ObSubPlanFilterOp
         /       |        \
   child[0]   child[1]   child[2]
   (主表)     (subquery1) (subquery2)
```

**关键数据结构**：

```cpp
// ob_subplan_filter_op.h:138-170
class ObSubPlanFilterSpec : public ObOpSpec {
  ObFixedArray<ObDynamicParamSetter> rescan_params_;     // 主表→子查询的参数传递
  ObFixedArray<ObDynamicParamSetter> onetime_exprs_;     // 只计算一次的条件
  ObBitSet init_plan_idxs_;     // InitPlan 索引（结果可缓存）
  ObBitSet one_time_idxs_;      // One-Time 索引（只计算不缓存）
  bool enable_das_group_rescan_; // DAS 批量 Rescan
};
```

### 2.2 ObSubQueryIterator——子查询迭代器

**文件**：`ob_subplan_filter_op.h` 第 26-95 行

每个子查询对应一个 `ObSubQueryIterator`。其执行模式取决于子查询分类：

| 类型 | 行为 | 对应 bitset |
|------|------|------------|
| **InitPlan** | 只在 SPF 第一次执行时计算一次，结果缓存到 `ObChunkDatumStore` | `init_plan_idxs_` |
| **One-Time 子查询** | 只计算一次但不缓存结果 | `one_time_idxs_` |
| **相关子查询** | 主表每行都重新计算 | 无标记（默认） |

**缓存机制**（`ob_subplan_filter_op.cpp` 第 45-55 行 `get_next_row`）：

```cpp
int ObSubQueryIterator::get_next_row()
{
  bool is_from_store = init_plan_ && inited_;
  if (is_from_store) {
    // InitPlan：从 store 中取缓存结果
    ret = store_it_.get_next_row(get_output(), op_.get_eval_ctx());
  } else {
    // 非 InitPlan：从子算子读取
    ret = get_next_row_from_child();
  }
}
```

**Hash Cache 优化**（相关子查询的去重）：`ob_subplan_filter_op.h` 第 90-95 行

对于相关子查询，当同一组执行参数再次出现时，`ObSubQueryIterator` 使用 `ObHashMap<DatumRow, ObDatum>` 进行结果缓存。如果 hashmap 中已存在相同参数的结果，直接返回缓存值，避免重新计算。

```cpp
// ob_subplan_filter_op.cpp:88-97
int ObSubQueryIterator::set_refactored(const DatumRow &row,
                                       const ObDatum &result,
                                       const int64_t deep_copy_size)
{
  if (OB_FAIL(hashmap_.set_refactored(row, result))) {
    LOG_WARN("failed to add to hashmap", K(ret));
  } else {
    memory_used_ += deep_copy_size;
  }
}
```

### 2.3 ObSubPlanScanOp——子查询扫描算子

**文件**：`src/sql/engine/subquery/ob_subplan_scan_op.h`

当子查询被优化为 Join 且未完全展开时，`ObSubPlanScanOp` 负责投影子查询的输出列到 SPF 的列空间。

```cpp
class ObSubPlanScanSpec : public ObOpSpec {
  ExprFixedArray projector_;  // [child_output, scan_column] 的偶对数组
};
```

### 2.4 SPF 的逐行执行流程

```
ObSubPlanFilterOp::inner_get_next_row()           ← SPF: 获取下一行
  │
  ├→ handle_next_row()                             ← 获取主表一行
  │   │
  │   ├→ (批处理模式时) 从 left_rows_ 缓冲读取      ← PX/DAS Batch
  │   ├→ child_->get_next_row()                    ← 正常模式：取主表下一行
  │   └→ prepare_rescan_params()                   ← 将主表列值设为子查询执行参数
  │
  ├→ (对每个子查询迭代器)
  │   ├→ ObSubQueryIterator::rewind()              ← 重置子查询扫描
  │   │   ├→ InitPlan: 从 store 取缓存
  │   │   ├→ One-Time: 不做任何操作
  │   │   └→ 相关子查询: children_[i]->rescan()
  │   │
  │   ├→ ObSubQueryIterator::get_next_row()        ← 执行子查询
  │   └→ (子查询结果写入执行参数)                     ← 表达式求值引用
  │
  ├→ handle_update_set()                            ← UPDATE SET =(subquery)
  └→ filter_row() / eval()                          ← 过滤 + 表达式求值
```

---

## 3. 子查询优化（Unnesting & 展开）

子查询不展开时，每次迭代都需要重新扫描子查询子树，代价极高。优化器有两种策略：

### 3.1 子查询展开（Subquery Unnesting）

优化器将子查询**脱胎（unnest）**为 Semi Join / Anti Join 或普通 Join，避免逐行重复计算。

**入口函数**：`ob_log_plan.h` 第 1306-1308 行

```cpp
int candi_allocate_subplan_filter_for_where();  // WHERE 子句的子查询
int candi_allocate_subplan_filter(
    const ObIArray<ObRawExpr *> &subquery_exprs, ...);  // 通用入口
```

**展开触发条件**（典型情况）：
- 子查询不包含聚合函数或窗口函数
- 子查询不包含 LIMIT / DISTINCT
- 子查询不包含递归
- 优化器认为展开后的代价 ≤ 不展开的代价

### 3.2 ObLogSubPlanFilter——优化器逻辑算子

**文件**：`src/sql/optimizer/ob_log_subplan_filter.h`

逻辑 SPF 算子管理优化器层面的子查询执行策略：

```cpp
class ObLogSubPlanFilter : public ObLogicalOperator {
  DistAlgo dist_algo_;             // 分布式执行算法
  ObSqlArray<ObQueryRefRawExpr *> subquery_exprs_;
  ObSqlArray<ObExecParamRawExpr *> exec_params_;
  ObSqlArray<ObExecParamRawExpr *> onetime_exprs_;
  ObBitSet<> init_plan_idxs_;      // InitPlan 索引
  ObBitSet<> one_time_idxs_;       // One-Time 索引
  bool enable_das_group_rescan_;   // DAS 组 Rescan
  ObSqlArray<bool> enable_px_batch_rescans_;  // PX Batch Rescan
};
```

**关键方法**：
- `est_cost()` / `do_re_est_cost()` — 估计执行代价（第 19-20 行）
- `compute_spf_batch_rescan()` — 判断是否启用批量 Rescan
- `compute_sharding_info()` — 分布式分区信息
- `allocate_subquery_id()` — 分配子查询 ID

### 3.3 Semi Join / Anti Join 优化

当子查询被展开后，优化器生成 Semi Join（EXISTS/IN 的等价形式）或 Anti Join（NOT EXISTS/NOT IN）：

```
原始 SQL:
  SELECT * FROM t1 WHERE EXISTS (SELECT 1 FROM t2 WHERE t1.id = t2.id)

优化后（Semi Join）:
  SELECT * FROM t1 SEMI JOIN t2 ON t1.id = t2.id
```

### 3.4 ObLogSubPlanScan——逻辑子查询扫描

**文件**：`src/sql/optimizer/ob_log_subplan_scan.h`

```cpp
class ObLogSubPlanScan : public ObLogicalOperator {
  uint64_t subquery_id_;
  ObString subquery_name_;
  ObSqlArray<ObRawExpr*> access_exprs_;
};
```

当子查询未能完全展开时，`ObLogSubPlanScan` 在优化器层面表示子查询内部的列访问。

### 3.5 分布式执行策略

`ObLogSubPlanFilter` 支持多种分布式策略（`ob_log_subplan_filter.h:` 第 17 行 `dist_algo_`）：

| 策略 | 含义 | 适用场景 |
|------|------|---------|
| `DIST_INVALID_METHOD` | 未选择 | — |
| `DIST_RANDOM_ALL` | 广播所有子查询到所有节点 | 子查询结果集小 |
| `DIST_HASH_ALL` | 哈希分区 | 主表和子查询按相同键分区 |

---

## 4. PX 与 DAS 批量 Rescan

### 4.1 PX Batch Rescan

在 PX 并行执行中，如果主表行量巨大，逐行 Rescan 会导致大量网络交互。`enable_px_batch_rescans_` 标记每个子查询是否支持 **批量 Rescan**。

**实现**（`ob_subplan_filter_op.cpp` 第 1002-1140 行 `handle_next_batch_with_px_rescan`）：

```
1. 从主表批量读取 PX_RESCAN_BATCH_ROW_COUNT (= 4M 参数上限约束的 16KB) 行 → left_rows_
2. left_rows_ 中的每行构建对应的 Rescan 参数
3. 通过 Rescan 参数批量传递给子查询
4. 从 left_rows_ 逐行消费输出结果
```

**常量约束**：
```cpp
static const int64_t MAX_PX_RESCAN_PARAMS_SIZE = 4 << 20; // 4MB
```

当 Rescan 参数累积超过 4MB 时，强制结束当前批量。

### 4.2 DAS Group Rescan

`enable_das_group_rescan_` 是比 PX Batch Rescan 更新的优化。当子查询通过 DAS 访问存储层时，可以将同一组的主表行合并为一次 DAS 请求。

**实现**（`ob_subplan_filter_op.cpp` 第 1142 行 `handle_next_batch_with_group_rescan`）：

```cpp
// ob_subplan_filter_op.cpp:771-781
if (OB_SUCC(ret) && MY_SPEC.enable_das_group_rescan_) {
  int64_t simulate_group_size = - EVENT_CALL(EventTable::EN_DAS_SIMULATE_GROUP_SIZE);
  max_group_size_ = simulate_group_size > 0 ? simulate_group_size : OB_MAX_BULK_JOIN_ROWS;
}
```

DAS Group Rescan 使用 `GroupParamBackupGuard` 来管理批处理参数的绑定与恢复。

---

## 5. Recursive CTE 的执行模型

Recursive CTE 是 SQL 中唯一支持循环计算的语法结构。OceanBase 的实现围绕 `ObRecursiveUnionOp` 展开。

### 5.1 架构总览

```
WITH RECURSIVE cte (n) AS (
  SELECT 1             ← Anchor Member (初始数据)
  UNION ALL
  SELECT n + 1
  FROM cte
  WHERE n < 5          ← Recursive Member (递归引用自身)
)
SELECT * FROM cte;

执行算子树：
      ObRecursiveUnionOp
        /              \
   child[0]          child[1]
 (Anchor Member)   (Recursive Member)
      │                  │
   (SELECT 1)     ObFakeCTETableOp ← CTE 表的读取
                        │
                    (SELECT n+1 ...)
```

**关键算子**：

| 算子 | 功能 | 文件 |
|------|------|------|
| `ObRecursiveUnionOp` | 调度器：协调 Anchor/Recursive 的执行 | `ob_recursive_union_op.h/.cpp` |
| `ObRecursiveInnerDataOp` | 实际状态机（Oracle 和 MySQL 两种变体） | `ob_recursive_inner_data_op.h/.cpp` |
| `ObFakeCTETableOp` | CTE 表的读写（生产者—消费者模型） | `ob_fake_cte_table_op.h` |
| `ObSearchMethodOp` | BFS/DFS 搜索与环路检测 | `ob_search_method_op.h` |

### 5.2 ObRecursiveUnionOp——递归 UNION 调度器

**文件**：`src/sql/engine/recursive_cte/ob_recursive_union_op.h` 第 85-115 行

`ObRecursiveUnionOp` 本身是一个轻量调度器，真正的递归逻辑委托给 `ObRecursiveInnerDataOp`。

**Specification**（第 15-80 行）：

```cpp
class ObRecursiveUnionSpec : public ObOpSpec {
  ObFixedArray<ObSortFieldCollation> sort_collations_;  // SEARCH BY 排序
  ObFixedArray<uint64_t> cycle_by_col_lists_;           // CYCLE BY 环路检测列
  ObFixedArray<ObExpr *> output_union_exprs_;           // UNION 输出表达式
  ObExpr *search_expr_;    // SEARCH 伪列（order_siblings）
  ObExpr *cycle_expr_;     // CYCLE 伪列（is_cycle）
  ObRecursiveInnerDataOracleOp::SearchStrategyType strategy_; // BFS/DFS
  bool is_rcte_distinct_;  // UNION DISTINCT 去重
};
```

**两种模式选择**（`ob_recursive_union_op.cpp` 第 92-124 行 `inner_open`）：

```cpp
if (is_oracle_mode) {
  inner_data_ = new (buf) ObRecursiveInnerDataOracleOp(...);
} else {
  inner_data_ = new (buf) ObRecursiveInnerDataMysqlOp(...);
}
```

### 5.3 ObRecursiveInnerDataOp——递归执行状态机

**文件**：`ob_recursive_inner_data_op.h` 第 84-108 行

使用有限状态机管理递归进度：

```
状态转移：
  R_UNION_READ_LEFT  →  R_UNION_READ_RIGHT  →  R_UNION_END
       │                      │                      │
       └→ Anchor 执行         └→ Recursive 执行       └→ 结束
```

**核心方法**（`ob_recursive_inner_data_op.cpp` 第 601-645 行 `get_next_row`）：

```cpp
int ObRecursiveInnerDataOracleOp::get_next_row()
{
  if (!result_output_.empty()) {
    // 优先输出已有结果
    try_format_output_row(read_rows);
  } else if (R_UNION_READ_LEFT == state_) {
    // 阶段 1：执行左臂（Anchor Member）
    try_get_left_rows(false, 1, read_rows);
    state_ = R_UNION_READ_RIGHT;
  } else if (R_UNION_READ_RIGHT == state_) {
    // 阶段 2：执行右臂（Recursive Member）→ 循环
    try_get_right_rows(false, 1, read_rows);
  } else if (R_UNION_END == state_) {
    ret = OB_ITER_END;
  }
}
```

### 5.4 ObFakeCTETableOp——CTE 中间表

**文件**：`src/sql/engine/recursive_cte/ob_fake_cte_table_op.h`

`ObFakeCTETableOp` 扮演 **生产者-消费者缓冲** 的角色：

- **生产者**：`ObRecursiveUnionOp` 将当前轮次的递归结果写入 CTE 表
- **消费者**：`ObFakeCTETableOp` 的子算子（Recursive Member 内部）从中读取

**关键字段**：

```cpp
// ob_fake_cte_table_op.h:139-159
ObRADatumStore intermedia_table_;              // CTE 中间表（可落盘）
ObRADatumStore::Reader intermedia_data_reader_; // 读取器
int64_t next_read_row_id_;   // 当前已读位置
int64_t round_limit_;        // 本轮上限（用于轮次隔离）
```

**轮次隔离机制**（代码中丰富的 ASCII 注释，第 143-158 行）：

```
                   intermedia_data_reader_.get_row_cnt()
  next_read_row_id_       round_limit_
        |                      |
  ------v----------------------v------------------------------
  | round 1 |     round 2     |        round 3    ...
  -----------------------------------------------------------
                intermedia_table_

每轮结束后 Recursive Union 设置 round_limit_ = intermedia_data_reader_.get_row_cnt()
下一轮中 next_read_row_id_ 只能读取到 round_limit_ 之前的数据。
```

**落盘机制**（第 170-175 行）：

```cpp
inline bool need_dump() const {
  return sql_mem_processor_.get_data_size() > sql_mem_processor_.get_mem_bound();
}
int process_dump();
```

当中间表数据超过内存限制时，`need_dump()` 返回 true，调用 `process_dump()` 将数据落盘。

### 5.5 Oracle 模式：SEARCH 与 CYCLE

Oracle 模式的递归 CTE 支持 `SEARCH` 和 `CYCLE` 子句，由 `ObRecursiveInnerDataOracleOp` 实现。

#### SEARCH 策略

```cpp
enum SearchStrategyType { DEPTH_FRIST, BREADTH_FRIST, BREADTH_FIRST_BULK };
```

| 策略 | 实现类 | 说明 |
|------|--------|------|
| `DEPTH_FRIST` | `ObDepthFirstSearchOp` | 深度优先，使用栈（`search_stack_`）追踪路径 |
| `BREADTH_FRIST` | `ObBreadthFirstSearchOp` | 广度优先，使用队列，构建树结构 |
| `BREADTH_FIRST_BULK` | `ObBreadthFirstSearchBulkOp` | 批量 BFS，批量输出数据 |

**搜索伪列**：搜索方法会在输出的每一行附加上 `order_siblings` 伪列（`search_expr_`），标记该行在递归树中的序号。

#### CYCLE 检测

**文件**：`ob_search_method_op.h` 第 76-95 行

```cpp
class ObCycleHash {
  uint64_t hash() const;    // murmurhash 散列
  bool operator==(const ObCycleHash &other) const;  // 相等比较
};
```

环路检测使用 **哈希集合 + 路径追踪**：

- 深度优先：使用 `ObHashSet<ObCycleHash>` 检测当前路径上的节点是否重复
- 广度优先：使用 `ObBFSTreeNode` 树结构，插入节点时检测是否已存在

```cpp
// ob_search_method_op.h:185-187, DFS 搜索
ObHashSet<ObCycleHash> hash_filter_rows_;          // 路径上的节点哈希
ObArray<ObChunkDatumStore::StoredRow *> current_search_path_;  // 当前递归路径
```

当检测到环路时，对应行标记 `is_cycle_ = true`，由 `cycle_expr_` 输出伪列值。

### 5.6 MySQL 模式：Recursive Union Distinct

MySQL 模式的 `ObRecursiveInnerDataMysqlOp`（`ob_recursive_inner_data_op.h` 第 177-228 行）使用 `ObRCTEHashTable` 实现 `UNION DISTINCT` 的去重。

```cpp
class ObRCTEHashTable : public ObExtendHashTable<ObRCTEStoredRowWrapper> {
  int exist(uint64_t hash_val, const ObIArray<ObExpr *> &exprs, ObEvalCtx *eval_ctx,
            ObRADatumStore::Reader *reader, bool &exist);
};
```

Hash Table 的 entry 包含 `hash_value_` 和 `row_id_`，通过 `row_id_` 索引 CTE 中间表中的数据行进行精确比较。

### 5.7 Recursive CTE 完整执行流程

```
ObRecursiveUnionOp::inner_get_next_row()
  │
  ├→ inner_data_->get_next_row()
  │   │
  │   ├→ [R_UNION_READ_LEFT]
  │   │   ├→ get_all_data_from_left_child()       ← 执行 Anchor Member
  │   │   │   └→ dfs_pump_.add_row() / bfs_pump_.add_row()
  │   │   │
  │   │   ├→ depth_first_union() / breadth_first_union()  ← 组织输出
  │   │   │   └→ result_output_  ← 暂存输出行
  │   │   │
  │   │   └→ fake_cte_table_add_row()             ← 写入 CTE 中间表
  │   │       └→ pump_operator_->add_single_row()
  │   │
  │   │   └→ state_ = R_UNION_READ_RIGHT
  │   │
  │   ├→ [R_UNION_READ_RIGHT]
  │   │   │
  │   │   ├→ get_all_data_from_right_child()       ← 执行 Recursive Member
  │   │   │   │
  │   │   │   ├→ ObFakeCTETableOp 的下一行作为右子算子输入
  │   │   │   └→ 产生新行 → add_row()
  │   │   │
  │   │   ├→ right_op_->rescan()                   ← 重置右子算子
  │   │   │
  │   │   ├→ depth_first_union()                   ← 组织递归结果
  │   │   │   ├→ dfs_pump_.finish_add_row()
  │   │   │   ├→ set_fake_cte_table_empty()
  │   │   │   ├→ get_next_nocycle_node()           ← 环路检测
  │   │   │   └→ fake_cte_table_add_row()          ← 写入下一轮输入
  │   │   │
  │   │   └→ (如果 dfs_pump_ 不为空，继续循环)        ← 递归迭代
  │   │
  │   └→ [R_UNION_END]
  │       └→ return OB_ITER_END
  │
  └→ try_format_output_row()                       ← 输出一行给上层算子
      ├→ assign_to_cur_row()                       ← 将存储行写入表达式
      └→ add_pseudo_column()                       ← 添加 SEARCH/CYCLE 伪列
```

---

## 6. 设计决策

### 6.1 相关子查询的 Hash Cache

OceanBase 为相关子查询中的每一组相同执行参数维护了 hashmap 缓存。设计取舍：

- **优势**：当主表大量行具有相同相关列值时，避免重复计算
- **代价**：hashmap 有 1MB 硬限制（`HASH_MAP_MEMORY_LIMIT = 1024 * 1024`），超过后退化为无缓存
- **触发条件**：hashmap 仅在 `exec_param_idxs_inited_` 为 true 时初始化

### 6.2 子查询展开 vs 不展开

| 策略 | 优势 | 劣势 |
|------|------|------|
| **不展开（SPF 逐行）** | 实现简单，适合小主表 | 大主表时反复扫描子查询 |
| **展开为 Semi Join** | 利用 Join 优化（hash join、索引 join） | 重写逻辑复杂，某些 SQL 语义不能展开 |
| **批量 Rescan** | 折中方案：批量减少 Rescan 次数 | 需要额外存储缓冲（`left_rows_`） |

### 6.3 BFS vs DFS 的选择

Oracle 模式允许用户通过 `SEARCH` 子句指定遍历策略：

- **深度优先（DFS）**：使用 `ObList` 做栈，`ObHashSet` 做环路检测。内存占用小，适合深层递归
- **广度优先（BFS）**：使用 `ObBFSTreeNode` 树结构，需保存整个层的数据。内存占用大，但支持排序
- **广度优先批量（BFS Bulk）**：一次读取整层数据并批量输出，适合 `DAS` 批处理场景

### 6.4 CTE 中间表的落盘策略

`ObFakeCTETableOp` 使用 `ObRADatumStore` 存储中间数据：

- **内存优先**：数据首先写入内存中的 `ObRADatumStore`
- **触发落盘**：当 `sql_mem_processor_.get_data_size() > sql_mem_processor_.get_mem_bound()` 时落盘
- **可恢复**：落盘后数据通过 `Reader` 恢复访问，使用 `sql_mem_processor_` 跟踪内存使用

### 6.5 Oracle 与 MySQL 模式的差异

| 特性 | Oracle 模式 | MySQL 模式 |
|------|-------------|-----------|
| SEARCH 子句 | 支持 BFS/DFS + 伪列 | 不支持 |
| CYCLE 子句 | 支持环路检测 + 伪列 | 不支持 |
| UNION DISTINCT | 通过 `ObRCTEHashTable` 实现 | 通过 `ObRCTEHashTable` 实现 |
| 最大递归深度 | 取决于 `cycle_by_col_lists_` 配置 | `max_recursion_depth_` 控制 |

---

## 7. 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 09-DAS | 子查询的 DAS Group Rescan 通过 DAS 层进行批量键值查询 |
| 17-Optimizer | 子查询展开（unnesting）是优化器的关键决策；代价估计决定是否展开 |
| 21-PX | PX Batch Rescan 在并行执行场景下减少 Rescan 的网络开销 |
| 32-Expr | 子查询的过滤条件通过 `ObDynamicParamSetter` 进行表达式求值传递 |

---

## 8. 源码索引

| 符号 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `ObSubPlanFilterOp` | `ob_subplan_filter_op.h` | 108 | SPF 物理算子，主表+子查询组合执行 |
| `ObSubPlanFilterSpec` | `ob_subplan_filter_op.h` | 138 | SPF 的规格定义（参数/索引） |
| `ObSubQueryIterator` | `ob_subplan_filter_op.h` | 26 | 子查询迭代器（InitPlan/One-Time/相关） |
| `handle_next_row()` | `ob_subplan_filter_op.cpp` | 202 | SPF 逐行执行入口 |
| `handle_next_batch_with_px_rescan()` | `ob_subplan_filter_op.cpp` | 1002 | PX 批量 Rescan |
| `handle_next_batch_with_group_rescan()` | `ob_subplan_filter_op.cpp` | 1142 | DAS 组 Rescan |
| `ObLogSubPlanFilter` | `ob_log_subplan_filter.h` | 14 | 优化器逻辑 SPF 算子 |
| `ObLogSubPlanScan` | `ob_log_subplan_scan.h` | 16 | 优化器逻辑子查询扫描算子 |
| `ObRecursiveUnionOp` | `ob_recursive_union_op.h` | 85 | Recursive CTE 调度器 |
| `ObRecursiveUnionSpec` | `ob_recursive_union_op.h` | 15 | Recursive CTE 规格定义 |
| `ObRecursiveInnerDataOp` | `ob_recursive_inner_data_op.h` | 84 | 递归执行状态机基类 |
| `ObRecursiveInnerDataOracleOp` | `ob_recursive_inner_data_op.h` | 104 | Oracle 模式：SEARCH/CYCLE |
| `ObRecursiveInnerDataMysqlOp` | `ob_recursive_inner_data_op.h` | 177 | MySQL 模式：DISTINCT/去重 |
| `ObFakeCTETableOp` | `ob_fake_cte_table_op.h` | 80 | CTE 中间表（生产者-消费者） |
| `ObDepthFirstSearchOp` | `ob_search_method_op.h` | 178 | DFS 搜索 + 环路检测 |
| `ObBreadthFirstSearchOp` | `ob_search_method_op.h` | 226 | BFS 搜索 + 树结构 |
| `ObBreadthFirstSearchBulkOp` | `ob_search_method_op.h` | 274 | 批量 BFS 搜索 |
| `ObRCTEHashTable` | `ob_recursive_inner_data_op.h` | 47 | UNION DISTINCT 去重哈希表 |
| `ObCycleHash` | `ob_search_method_op.h` | 76 | CYCLE 检测的哈希 key |

---

*本文使用 doom-lsp（clangd LSP）进行符号解析和行号校验。*  
*所有代码行号基于 OceanBase 当前源代码。*
