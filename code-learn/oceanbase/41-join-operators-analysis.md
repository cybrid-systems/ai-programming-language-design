# 41 — Join 算子 — Hash Join、Nested Loop Join、Merge Join

> 基于 OceanBase CE 主线源码
> 分析范围：`src/sql/engine/join/`（28 个文件）
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与代码结构分析

---

## 0. 概述

**Join — 关系代数的灵魂操作。**

在前面的文章中，我们已经看到了优化器（文章 17）如何根据成本选择 join 类型和执行顺序，以及并行执行（文章 21）如何通过 PX exchange 算子拆分数据。现在，我们终于走到 **join 算子的运行时实现** 面前。

OceanBase 的 join 算子位于 `src/sql/engine/join/`，提供了三种主流 join 算法：

| Join 类型 | 主要文件 | 适用场景 |
|-----------|---------|---------|
| **Hash Join** | `ob_hash_join_op.h/cpp` | 等值连接，大数据量，无索引 |
| **Nested Loop Join** | `ob_nested_loop_join_op.h/cpp` | 小表驱动大表，支持不等值条件 |
| **Merge Join** | `ob_merge_join_op.h/cpp` | 输入已排序，等值连接 |

每种 join 都有对应的 **向量化版本**（`_vec_op.h/cpp`），充分利用批处理加速。

此外还有：
- **ObJoinOp** — 三种 join 的公共基类，位于 `ob_join_op.h/cpp`，提供 join type 判断、条件求值、blank row 生成等基础设施
- **ObJoinFilterOp** — Bloom Filter 运行时过滤下推，位于 `ob_join_filter_op.h/cpp`
- **ObPartitionStore** — 磁盘溢出存储，位于 `ob_partition_store.h/cpp`
- **hash_join/** — 哈希表实现的子目录

---

## 1. 公共基类：ObJoinOp 与 ObJoinSpec

### 1.1 ObJoinSpec（ob_join_op.h:22）

所有 join spec 的基类，定义了 join 的核心元信息：

```cpp
class ObJoinSpec {                          // ob_join_op.h:26
  ObJoinType join_type_;                    // line 33 — INNER、LEFT、RIGHT、FULL OUTER、SEMI、ANTI 等
  ExprArray other_join_conds_;              // line 34 — 非等值 join 条件（other-join-conds）
};
```

join_type_ 的值域由 `ObJoinType` 枚举定义，覆盖了 SQL 标准中的所有 join 类型。优化器在生成执行计划时选择的 join 类型，最终会写入这里。

### 1.2 ObJoinOp（ob_join_op.h:39）

所有 join 算子的基类，从 `ObOp` 继承，定义了 join 专用的接口：

```cpp
class ObJoinOp {                            // ob_join_op.h:42
  // —— 子算子访问 ——
  int get_next_left_row(ObExecContext &ctx, const ObNewRow *&row);  // line 63
  int get_next_right_row(ObExecContext &ctx, const ObNewRow *&row); // line 64

  // —— Join 类型判断 ——
  bool need_left_join();   // line 58 — LEFT JOIN / FULL OUTER
  bool need_right_join();  // line 59 — RIGHT JOIN / FULL OUTER

  // —— Other-join-conds 求值 ——
  int calc_other_conds(ObExecContext &ctx, const ObNewRow &left,
                       const ObNewRow &right, bool &is_match);       // line 61

  // —— Blank row 生成 ——
  int blank_row(ObExecContext &ctx, const ObNewRow *&row);          // line 54
  int blank_row_batch(ObExecContext &ctx, int64_t idx,
                      const ObNewRow *&row);                        // line 55

  bool output_row_produced_;  // line 71
  bool left_row_joined_;      // line 72 — 左行是否已有匹配
};
```

核心设计：

1. **`calc_other_conds()`**（ob_join_op.cpp:61）— 在等值条件匹配后，对候选结果行执行 other-join-conds 的求值。这是 join 条件求值的完整路径：hash/merge 先做等值匹配，再用这个函数检查过滤条件。

2. **`need_left_join() / need_right_join()`** — 根据 join_type_ 判断是否需要为 preserve side 填充零值行。LEFT JOIN 需要 left-join，RIGHT JOIN 需要 right-join，FULL OUTER 两者都需要。

3. **`blank_row()`** — 生成 NULL 填充的零值行，用于 outer join 中 unmatched 行的输出。

4. **`left_row_joined_`** — 辅助标记，用于 outer join：记录当前 probe 的左行是否至少匹配到一个右行。

三种 join 算子通过 `inner_open()`、`inner_get_next_row()`、`inner_get_next_batch()`、`inner_rescan()`、`inner_close()` 这些虚函数接口实现具体的 join 逻辑。

---

## 2. Hash Join — 内存哈希与磁盘溢出

### 2.1 类层次

```
ObHashJoinSpec (ob_hash_join_op.h:258)
  └─ 继承 ObJoinSpec
     存储：
       - equal_join_conds_     (line 268) — 等值 join 条件
       - all_join_keys_        (line 269) — 所有 join key
       - all_hash_funcs_       (line 270) — 哈希函数
       - is_naaj_ / is_sna_    (line 273-275) — NULL-Aware Anti Join / Semi-NAAJ
       - is_shared_ht_         (line 276) — 共享哈希表
       - is_adaptive_          (line 281) — 自适应 join 模式

ObHashJoinOp (ob_hash_join_op.h:290)
  └─ 继承 ObJoinOp
      状态机驱动，约 100+ 成员函数
```

### 2.2 状态机架构

HashJoin 的执行由 **状态机** 驱动，包含三个核心枚举：

```cpp
enum class HJProcessor {      // line 317 — 整体处理策略
  NONE = 0,                   // 未确定
  NEST_LOOP,                  // 嵌套循环（小右表时退化）
  RECURSIVE,                  // 递归分区（数据溢出到磁盘）
  IN_MEMORY,                  // 全内存构建
};

enum class HJState {          // line 311 — 处理阶段
  INIT,                       // 初始状态
  NORMAL,                     // 正常处理中
  NEXT_BATCH,                 // 下一个分区批处理
};

enum class ObJoinState {      // line 324 — 行处理状态
  JS_JOIN_END,                // join 结束
  JS_READ_RIGHT,              // 读取右表（build）
  JS_READ_HASH_ROW,           // 读取哈希表中的行（probe）
  JS_LEFT_ANTI_SEMI,          // LEFT ANTI/SEMI 处理
  JS_FILL_LEFT,               // 填充左表 unmatched 行
};
```

Hash Join 的执行入口是 `ObHashJoinOp::inner_get_next_row()`（ob_hash_join_op.cpp），它循环调用状态机的 `next()` 函数。`next()` 根据当前 `hj_processor_` 类型分发到不同的处理分支：

1. **`IN_MEMORY` → `in_memory_process()`**（line 865）— 全部在内存中完成
2. **`NEST_LOOP` → `nest_loop_process()`**（line 854）— 退化到嵌套循环
3. **`RECURSIVE` → `recursive_process()`**（line 882）— 分区溢出处理

### 2.3 执行流程

```
Hash Join 完整执行流程
═══════════════════════════════════════════════════════════════════

Phase 1: 分析（get_processor_type, line 863）
         │
         ├── 估算内表大小 calc_basic_info()
         ├── 选择处理器类型 (IN_MEMORY / NEST_LOOP / RECURSIVE)
         └── 计算分区数 calc_partition_count()
         
Phase 2: Build Phase（构建哈希表）
         │
         ├── 扫描所有右表行（get_next_right_row）
         ├── 对每行计算 hash 值 (calc_hash_value, line 887)
         ├── 插入哈希表 (build_hash_table_in_memory / build_hash_table_for_recursive)
         │
         └── 如果内存不足：
               ├── dump_build_table() → 溢出到磁盘 (line 876)
               └── 递归处理溢出分区 (recursive_process)

Phase 3: Probe Phase（探测哈希表）
         │
         ├── 扫描左表行（get_next_left_row）
         ├── 对每行计算 hash 值
         ├── 在哈希表中查找匹配 (find_next_matched_tuple, line 901)
         ├── 对匹配行计算 other-join-conds
         └── 输出结果行

Phase 4: 后处理
         │
         ├── LEFT JOIN: fill_left_operate() (line 907)
         ├── LEFT ANTI/SEMI: left_anti_semi_operate() (line 902)
         └── NASJ: null-aware 处理
═══════════════════════════════════════════════════════════════════
```

### 2.4 哈希表结构

哈希表的实现在 `hash_join/join_hash_table.h`，核心结构为 **bucket chain**：

```cpp
class JoinHashTable {                         // join_hash_table.h:23
  ObHashTableCore hash_table_;               // line 61 — 核心哈希表
  int init();                                 // line 27
  int build_prepare();                        // line 30
  int build();                                // line 31
  int probe_prepare();                        // line 32
  int probe_batch();                          // line 33
  int project_matched_rows();                 // line 34
};
```

哈希表的 bucket 定义在 `ob_hash_join_op.h:345` 的 `HTBucket` 结构：

```cpp
struct HTBucket {                             // ob_hash_join_op.h:348
  union {
    struct { uint64_t hash_value_; uint64_t used_; };
    int64_t val_;              // line 354 — 用于 CAS 原子操作
  };
  ObNewRow *stored_row_;                     // line 357 — 存储的行指针
};
```

设计要点：
- **hash_value_** 存储完整哈希值，用于快速冲突检查（先比 hash 再比 key）
- **used_** 标记 bucket 是否占用
- **val_** 使用 64 位原子操作，支持多线程并发构建哈希表
- 每个 bucket 存储的是行指针（`ObNewRow*`），行数据通过专门的 allocator 管理

`PartitionSplitter`（ob_hash_join_op.h:712）负责当数据量超出内存时的分区处理：

```cpp
class PartitionSplitter {                    // ob_hash_join_op.h:715
  int64_t part_count_;                       // line 782 — 分区数量
  ObArray<ObHashJoinPartition> hj_parts_;    // line 783 — 分区列表
  int64_t max_level_;                        // line 784 — 分区层级（1 或 2）
  int64_t part_shift_;                       // line 785 — hash 值的移位数
  int64_t level1_bit_;                       // line 786 — 第一层分区的 bit 数
  int64_t level2_bit_;                       // line 787 — 第二层分区的 bit 数

  int repartition_by_part_array();           // line 756
  int repartition_by_part_histogram();        // line 757
  int build_hash_table_by_part_hist();        // line 758
  int build_hash_table_by_part_array();       // line 760
};
```

分区策略使用 **hash 值的高位比特** 决定分区归属。当一级分区不够时，使用两级分区（`level1_bit_` 和 `level2_bit_`）。`HashJoinHistogram`（line 631）帮助确定每个分区的数据分布，以选择最优的分区方案。

### 2.5 多处理器策略

OceanBase 的 Hash Join 根据数据量选择四种处理模式（`HJProcessor`）：

| 模式 | 触发条件 | 行为 |
|------|---------|------|
| **NONE** | `NONE` | 未确定，仅在初始化阶段 |
| **IN_MEMORY** | 右表数据可以完全放入内存 | 构建全内存哈希表，直接 probe |
| **NEST_LOOP** | 右表行数少（`MAX_NEST_LOOP_RIGHT_ROW_COUNT`，line 1140）或 nest-loop 开启（`ENABLE_HJ_NEST_LOOP`，line 1125） | 构建小哈希表后退化到嵌套循环 |
| **RECURSIVE** | 右表数据溢出内存 | 分区 → 溢出到磁盘 → 逐分区递归处理 |

处理器类型的选择在 `get_processor_type()`（line 863）中完成。当 `HJ_TP_OPT_ENABLED` 开启时，还会考虑 cache-aware 优化（`can_use_cache_aware_opt()` at line 1069）和 bloom filter 优化（`enable_bloom_filter_` at line 1219）。

### 2.6 NAAJ & SNA — Null-Aware Anti Join

Hash Join 对 NULL 敏感的反连接做了特殊处理。`is_naaj_`（line 273）和 `is_sna_`（line 275）标记了 NAAJ / SNA 模式。

在 NAAJ 中，NULL = NULL 不做匹配（SQL 标准行为），所以需要额外的标记行和左/右 null 处理逻辑：
- `is_left_naaj()` / `is_right_naaj()` — 判断哪一侧需要 NAAJ 处理
- `check_join_key_for_naaj()`（line 1089）— 检查 join key 中的 NULL 值
- `join_rows_with_left_null()`（line 913）— 处理左表 NULL 行
- `join_rows_with_right_null()`（line 912）— 处理右表 NULL 行

### 2.7 Hash Join 的向量化版本

向量化 Hash Join 通过 `ob_hash_join_basic.h/cpp` 和 `ob_hash_join_op.cpp` 中的 batch 接口实现。

核心 batch 函数（如 `read_hashrow_batch()` at line 938）每次处理一批行，而不是单行。这样做减少了虚函数调用开销，并利用批处理实现更好的缓存局部性。

---

## 3. Nested Loop Join

### 3.1 类层次

```
ObNestedLoopJoinSpec (ob_nested_loop_join_op.h:25)
  └─ 继承 ObJoinSpec
      存储：
        - group_rescan_ / group_size_  (line 40-41) — 批量 rescan 控制
        - left_rescan_params_ / right_rescan_params_  (line 54-55)
        - left_expr_ids_in_other_cond_  (line 42)

ObNestedLoopJoinOp (ob_nested_loop_join_op.h:70)
  └─ 继承 ObJoinOp
```

### 3.2 执行流程

```
Nested Loop Join 执行流程
═══════════════════════════════════════════════════════════════════

while (get_next_left_row() 成功)：
    │
    ├── left_row_matched = false
    │
    ├── rescan_right_operator()          — 每次外表行变化后，重扫内表
    │      └── inner_rescan() 分发到子算子
    │
    ├── while (get_next_right_row() 成功)：
    │      ├── calc_other_conds()
    │      └── 如果匹配：输出行，left_row_matched = true
    │
    └── 如果是 LEFT JOIN 且 left_row_matched == false：
           └── 输出 blank_right_row()
═══════════════════════════════════════════════════════════════════
```

NLJ 的状态机相对简单：

```cpp
enum class ObJoinState {           // ob_nested_loop_join_op.h:79
  JS_JOIN_END,           // 结束
  JS_READ_LEFT,          // 读左表行（触发右表 rescan）
  JS_READ_RIGHT,         // 读取右表行进行匹配
  JS_STATE_COUNT,
};
```

### 3.3 Batch Rescan 优化

NLJ 的一个重要优化是 **Batch Rescan**（`ob_nested_loop_join_op.h:189` 的 `batch_rescan_ctl_`）。

当左表是多行时，不必每行都 rescan 右表。OceanBase 将左表批量缓存，然后对批量中的每行统一执行 rescan + probe：

```cpp
// 批量 rescan 控制结构
struct BatchRescanCtl {             // 类似结构，在 .h 中通过字段体现
  ObStoreRowIterator left_store_iter_;   // line 183
  ObStoreRow left_store_;                // line 182 — 左表行缓存
  int64_t max_group_size_;               // line 206
  int is_left_end_;                      // line 184
};
```

关键函数：
- `rescan_params_batch_one()`（line 159）— 批量设置 rescan 参数
- `get_next_batch_from_right()`（line 127）— 批量从右表获取数据
- `process_right_batch()`（line 167）— 处理右表批处理结果

Batch Rescan 的原理：

```
普通 NLJ：左表 1行 → rescan 右表 → 匹配 → 左表 2行 → rescan 右表 → ...
Batch NLJ：左表 [1,2,3,4] 行 → rescan 右表 → 对每行匹配 → ...
```

### 3.4 向量化 Nested Loop Join

`ob_nested_loop_join_vec_op.cpp` 实现了向量化版本。核心区别在于使用 `inner_get_next_batch()` 接口处理批量行：

```cpp
int ObNestedLoopJoinVecOp::inner_get_next_batch(ObExecContext &ctx,
    int64_t max_rows, int64_t &read_rows);    // ob_nested_loop_join_op.h:162
```

向量化版本使用了：
- `left_batch_`（line 193）— 左表批量数据
- `stored_rows_`（line 197）— 缓存的右表行
- `left_brs_`（line 200）— 左表 batch row store
- `batch_mem_ctx_`（line 196）— 批次专用内存上下文

---

## 4. Merge Join

### 4.1 类层次

```
ObMergeJoinSpec (ob_merge_join_op.h:38)
  └─ 继承 ObJoinSpec
      存储：
        - equal_cond_infos_      (line 96) — 等值条件信息（含比较函数）
        - merge_directions_      (line 97) — 归并方向（ASC/DESC）
        - is_left_unique_        (line 98) — 左表是否唯一

ObMergeJoinOp (ob_merge_join_op.h:106)
  └─ 继承 ObJoinOp
```

`ObMergeJoinSpec` 中的 `EqualConditionInfo`（line 42）对每个等值连接条件记录了：

```cpp
struct EqualConditionInfo {                // ob_merge_join_op.h:45
  ObExpr *expr_;                            // line 50 — 表达式
  union {
    ObExpr *ns_cmp_func_;                   // line 52 — NULL-safe 比较函数
    ObSerEvalCtxFunc ser_eval_func_;        // line 53 — 序列化求值函数
  };
  bool is_opposite_;                        // line 57 — 方向是否相反
};
```

### 4.2 执行流程

Merge Join 从两端读取排序后的输入，使用双指针归并。

```
Merge Join 执行流程
═══════════════════════════════════════════════════════════════════

合并过程（以 ASC 为例）：

  LEFT (已排序)              RIGHT (已排序)          输出
  ┌──────┐                   ┌──────┐
  │  1   │──┐               │  1   │──┐
  ├──────┤  │               ├──────┤  │          (1, 1)
  │  2   │  │               │  1   │  │          (1, 1)
  ├──────┤  └── 匹配组 ──────├──────┤──┘          (2, 2)
  │  3   │     (左1 vs 右1)  │  2   │
  ├──────┤                   ├──────┤
  │  4   │                   │  3   │
  └──────┘                   └──────┘
```

Merge Join 的状态机比 Hash Join 复杂，因为需要精细控制归并过程：

```cpp
enum class ObJoinState {           // ob_merge_join_op.h:316
  JS_JOIN_END,                     // 结束
  JS_JOIN_BEGIN,                   // 开始新的归并
  JS_LEFT_JOIN,                    // 左表推进
  JS_RIGHT_JOIN_CACHE,             // 右表装入缓存
  JS_RIGHT_JOIN,                   // 右表推进
  JS_READ_CACHE,                   // 读缓存行
  JS_GOING_END_ONLY,               // 仅执行 end 函数
  JS_FULL_CACHE,                   // 完整缓存处理
  JS_EMPTY_CACHE,                  // 空缓存处理
  JS_FILL_CACHE,                   // 填充缓存
  JS_STATE_COUNT,
};
```

### 4.3 ChildRowFetcher

Merge Join 使用 `ChildRowFetcher`（line 128）从左右子算子获取排序后的行：

```cpp
class ChildRowFetcher {                 // ob_merge_join_op.h:130
  int init(ObExecContext &ctx);           // line 135
  int next(const ExprArray &all_exprs,    // line 142
           int64_t &cmp_res);             //      返回比较结果
  void backup();                          // line 168 — 保存当前行
  void restore();                         // line 180 — 恢复保存的行
  void save_last();                       // line 189
  void reuse();                           // line 195
};
```

**backup/restore** 机制是 Merge Join 的关键：当左表的一行与右表的多行匹配时，需要缓存右表的当前位置，在完成左行匹配后恢复，继续处理下一组。这避免了重复扫描。

### 4.4 向量化 Merge Join

向量化版本（`ob_merge_join_vec_op.cpp`）使用 `ChildBatchFetcher`（line 221）批量获取数据，而不是逐行 fetch：

```cpp
class ChildBatchFetcher {               // 定义于 ObMergeJoinOp 内，line 221
  ObBatchRows brs_;                      // — 批量行信息
  int64_t batch_size_;
  MatchGroupArray match_groups_;         // — 匹配组
  // ... backup/restore 机制
  int get_next_small_group();            // line 236
  int get_next_equal_group();            // line 238
  int backup_remain_rows();              // line 243
};
```

Batch 版本的归并过程：

```cpp
enum class BatchJoinState {             // ob_merge_join_op.h:555
  BJS_JOIN_END,
  BJS_JOIN_BEGIN,        // 开始新的 batch 归并
  BJS_JOIN_BOTH,         // 双端归并
  BJS_MATCH_GROUP,       // 处理匹配组
  BJS_OUTPUT_STORE,      // 输出缓存的匹配行
  BJS_OUTPUT_LEFT,       // 输出左表 unmatched 行
  BJS_OUTPUT_RIGHT,      // 输出右表 unmatched 行
};
```

---

## 5. 三种 Join 的对比

```
三种 Join 算子的对比
═══════════════════════════════════════════════════════════════════════════

┌─────────────────┬──────────────────┬──────────────────┬──────────────────┐
│   特性          │   Hash Join      │  Nested Loop     │   Merge Join     │
│                 │                  │   Join           │                  │
├─────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 连接条件        │ 仅等值           │ 任意条件         │ 仅等值           │
│                 │ (equal join      │ (包括不等值、    │ (equal join      │
│                 │  conds)          │ 子查询等)        │  conds)          │
├─────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 输入要求        │ 无               │ 无               │ 两端已排序       │
├─────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 内存消耗        │ 构建哈希表       │ 极小（无构建开销）│ 极小（无需构建） │
│                 │ （可能溢出到磁盘）│                  │                  │
├─────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 时间复杂度      │ O(L + R)         │ O(L × R)         │ O(L + R)         │
│                 │ (build: R,       │ (最差，无索引时)  │ (linear merge)   │
│                 │  probe: L 平均O(1))│                  │                  │
├─────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 磁盘溢出        │ 是 (recursive    │ 否               │ 是 (通过datum    │
│                 │ 分区)            │                  │  store 溢出)     │
├─────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 向量化          │ 是               │ 是               │ 是               │
├─────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 状态机复杂度    │ 复杂 (3 状态机)  │ 简单             │ 复杂 (双指针     │
│                 │ × 多处理器模式)  │                  │ × 缓存管理)      │
├─────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 共享哈希表      │ 是 (PX 多线程    │ 否               │ 否               │
│                 │ 共享 build)      │                  │                  │
├─────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ Bloom Filter    │ 是 (build 时生成 │ 否               │ 否               │
│ 下推            │ probe 时使用)    │                  │                  │
└─────────────────┴──────────────────┴──────────────────┴──────────────────┘
```

---

## 6. Join Filter — Bloom Filter 运行时过滤

### 6.1 概述

`ObJoinFilterOp`（ob_join_filter_op.h:325）是一个 **独立于三种 join 之外的算子**，在 PX 执行计划中作为物理算子插入。它在 Hash Join 的 build 阶段构建 Bloom Filter，然后通过网络广播到 probe 侧的扫描算子，提前过滤掉不需要的行。

### 6.2 两种模式

Join Filter 有两种运行模式：

```cpp
class ObJoinFilterSpec {                 // ob_join_filter_op.h:207
  int mode_;                              // line 261
  int64_t filter_id_;                     // line 262
  ObArray<ObExpr*> join_keys_;            // line 264 — join key 表达式
  ObArray<ObExpr*> hash_funcs_;           // line 265 — 哈希函数
  // ... bloom_filter_ratio_, rf_infos_, etc.
};
```

- **CREATE 模式**（`is_create_mode()`，line 219）：在 build 端构建 Bloom Filter，将 key 的哈希值填入位图
- **USE 模式**（`is_use_mode()`，line 220）：在 probe 端使用 Bloom Filter，在扫描时跳过不可能匹配的行

### 6.3 共享构建

在 PX 场景下，多个 build 线程共享同一个 Bloom Filter：

```cpp
class SharedJoinFilterConstructor {         // ob_join_filter_op.h:46
  int try_acquire_constructor();            // line 49
  int try_release_constructor();            // line 50
  int wait_constructed();                    // line 53
  int notify_constructed();                  // line 54
  bool is_bloom_filter_constructed_;        // line 59
};
```

这保证了多个并行 worker 可以安全地并发填充同一个 Bloom Filter，并且在所有 worker 完成构建后，use 端的线程才能开始过滤。

### 6.4 自适应 Runtime Filter

OceanBase 还支持基于 **HyperLogLog** 的自适应 Bloom Filter 大小：

```cpp
bool use_ndv_runtime_bloom_filter_size_;  // ob_join_filter_op.h:284
// 使用 HyperLogLog 估计 NDV，动态调整 Bloom Filter 大小
int build_ndv_info_before_aggregate();     // line 418
int can_sync_row_count_locally();          // line 413
```

当 join key 的基数较低时，Bloom Filter 可以更小；当基数很高时，Bloom Filter 需要更大的位图来保持较低误判率。

---

## 7. 设计决策

### 7.1 Hash Join Build 表的选择

Hash Join 始终使用 **右表（right child）作为 build 表**。这是因为 OceanBase 的 join 运算符约定：

- `get_next_right_row()` → 构建哈希表（build）
- `get_next_left_row()` → 探测哈希表（probe）

选择哪张表作为右表（build 表）是由 **优化器** 在计划生成阶段决定的。优化器会选择较小的表作为 build 表，使哈希表尽可能小。这与很多数据库的做法一致。

### 7.2 多处理器模式的设计权衡

Hash Join 的三种处理器模式（IN_MEMORY / NEST_LOOP / RECURSIVE）构成了一个 **自动降级链**：IN_MEMORY →（内存不足）→ RECURSIVE；如果是小表则 NEST_LOOP。

这种设计的优势：
1. **内存可控** — 不会因为构建哈希表而超出内存限制
2. **性能自适应** — 小表直接用嵌套循环避免哈希开销
3. **渐进式溢出** — 预分区的数据可以逐步处理，不需要一次性全部溢出

### 7.3 NLJ Batch Rescan 的触发条件

Batch Rescan 优化在 `ObNestedLoopJoinSpec` 中通过 `group_rescan_`（line 40）和 `group_size_`（line 41）控制：

- 左表批量读取多行到 `left_store_`（line 182）
- `group_size_` 指定批量大小
- 对批量内的每行执行右表 probe，减少 rescan 次数
- 适用于外表有重复值或索引的场景

Batch Rescan 的一个关键限制：**子查询（subplan filter）**不能使用 Batch Rescan，因为每次 probe 需要独立的表达式上下文。这正是 `group_rescan_` 标记的用途。

### 7.4 Merge Join 的 backup/restore 机制

当左表的一行对应右表的多行时（group join），Merge Join 需要：

1. 读取左表行 A
2. 读取右表行 1，比较发现相等
3. 继续读取右表行 2、3，都相等
4. 输出 (A,1)、(A,2)、(A,3)
5. 读取左表行 B，比较发现不等
6. 从上次缓存的位置继续读取右表

`ChildRowFetcher::backup()` 和 `restore()` 实现了这一机制。当左表行在右表中有多个匹配时，`backup()` 保存当前位置；当切换到下一个左表行时，`restore()` 恢复到保存的位置。这在批量版本中对应 `backup_remain_rows()`。

### 7.5 Bloom Filter 下推的触发条件

Bloom Filter 下推（Join Filter）不是在所有场景下都生效。它需要满足：

1. 查询在 PX 并行框架下执行
2. Join Filter 作为独立算子插入执行计划
3. **Hash Join** 的等值条件（非 NLJ 或 Merge Join）
4. Build 端的数据量足够大，值得构建 Bloom Filter
5. `enable_bloom_filter_`（ob_hash_join_op.h:1219）在运行时开启

### 7.6 向量化的价值

每种 join 都有向量化版本的根本原因是 **减少虚函数调用和批处理缓存友好性**：

- 行模式：每行一个 `inner_get_next_row()` + 一个 `calc_other_conds()` + ...
- 向量模式：一批行一次 `inner_get_next_batch()` + 批量表达式求值

向量化的核心是 `ObBatchRows`（批量行描述符）结构，包含：
- `size_` — 行数
- `skip_` — 跳过标记（由 Bloom Filter 等设置）
- `all_rows_fetched_` — 是否已全部获取

OceanBase 的向量化引擎在 `src/sql/engine/basic/ob_vec_op.h` 中实现，join 向量化版本在此基础上进行适配。

---

## 8. 源码索引

| 文件 | 关键类/结构 | 行号 | 职责 |
|------|------------|------|------|
| `ob_join_op.h` | `ObJoinSpec` | 22 | Join 共享 spec |
| `ob_join_op.h` | `ObJoinOp` | 39 | Join 算子的基类 |
| `ob_hash_join_op.h` | `ObHashTableSharedTableInfo` | 31 | 共享哈希表信息（PX） |
| `ob_hash_join_op.h` | `ObHashJoinInput` | 54 | Hash Join 输入 |
| `ob_hash_join_op.h` | `ObHashJoinSpec` | 258 | Hash Join spec |
| `ob_hash_join_op.h` | `ObHashJoinOp` | 290 | Hash Join 算子 |
| `ob_hash_join_op.h` | `HTBucket` | 348 | 哈希表 bucket |
| `ob_hash_join_op.h` | `PartHashJoinTable` | 406 | 分区哈希表 |
| `ob_hash_join_op.h` | `HashJoinHistogram` | 631 | 分区直方图 |
| `ob_hash_join_op.h` | `PartitionSplitter` | 712 | 分区拆分器 |
| `ob_hash_join_op.h` | `HJProcessor` | 317 | 处理模式枚举 |
| `ob_hash_join_op.h` | `ObJoinState` | 324 | Join 行状态枚举 |
| `ob_hash_join_op.h` | `HJLoopState` | 337 | 嵌套循环状态枚举 |
| `ob_nested_loop_join_op.h` | `ObNestedLoopJoinSpec` | 25 | NLJ spec |
| `ob_nested_loop_join_op.h` | `ObNestedLoopJoinOp` | 70 | NLJ 算子 |
| `ob_merge_join_op.h` | `ObMergeJoinSpec` | 38 | Merge Join spec |
| `ob_merge_join_op.h` | `ObMergeJoinOp` | 106 | Merge Join 算子 |
| `ob_merge_join_op.h` | `ChildRowFetcher` | 128 | 子算子行获取器 |
| `ob_merge_join_op.h` | `ChildBatchFetcher` | 221 | 批量行获取器 |
| `ob_join_filter_op.h` | `ObJoinFilterSpec` | 207 | Join Filter spec |
| `ob_join_filter_op.h` | `ObJoinFilterOp` | 336 | Join Filter 算子 |
| `ob_join_filter_op.h` | `SharedJoinFilterConstructor` | 46 | 共享 Bloom Filter 构建器 |
| `hash_join/join_hash_table.h` | `JoinHashTable` | 23 | 哈希表模板 |
| `ob_partition_store.h` | `ObPartitionStore` | — | 溢出存储 |
| `ob_basic_nested_loop_join_op.h` | `ObBasicNestedLoopJoinOp` | — | 基本 NLJ（非向量化） |
| `ob_nested_loop_join_vec_op.h` | `ObNestedLoopJoinVecOp` | — | 向量化 NLJ |
| `ob_merge_join_vec_op.h` | `ObMergeJoinVecOp` | — | 向量化 Merge Join |
| `ob_join_vec_op.h` | `ObJoinVecOp` | — | Join 向量化基类 |

所有行号基于 OceanBase CE 主线源码，使用 doom-lsp（clangd LSP）进行符号解析验证。

---

*本文通过 doom-lsp 对 `src/sql/engine/join/` 目录中的 28 个源文件进行了完整的符号解析与结构分析。从三个 join 算子的状态机实现，到公共基类、join filter 的 Bloom Filter 下推，再到向量化扩展，完整覆盖了 OceanBase join 算子的运行时实现。*
