# 60 — SQL 性能分析深潜 — Profile、Trace、Slow Query 全路径

> 基于 OceanBase CE 主线源码
> 分析范围：`src/share/diagnosis/` + `src/sql/monitor/flt/` + `src/sql/monitor/` + `src/observer/mysql/`
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

本文是 OceanBase 源码分析系列的收官之作。前 59 篇文章覆盖了从存储引擎、事务、日志、分布式通信到 SQL 执行的方方面面。现在，我们需要回答一个终极问题：

> **当一条 SQL 慢的时候，OceanBase 如何告诉你它为什么慢？**

答案是三层诊断体系：

1. **SQL Audit（请求级）** — 文章 29 已详细分析，`gv$sql_audit` 提供每条 SQL 的端到端时间线和资源消耗
2. **Plan Monitor（算子级）** — 文章 29 已分析，`v$plan_monitor` 提供每个物理算子的统计数据
3. **Profile 框架（指标级）** — **本文核心**，每个算子的运行时指标（metric）明细，以 JSON 格式存储在 `RAW_PROFILE` 字段中

在此基础上，Trace 日志（文章 56）和慢查询机制共同构成了完整的诊断链：

```
用户端发现慢
  │
  ▼
SQL Audit 定位慢 SQL (gv$sql_audit)
  │  request_id, elapsed_time, queue_time, execute_time...
  ▼
Plan Monitor 定位瓶颈算子 (v$plan_monitor)
  │  db_time 最大的算子
  ▼
Profile 框架展开算子细节 (RAW_PROFILE)
  │  hash 表碰撞率、join filter 过滤率、IO 等待...
  ▼
Trace 日志逐事件跟踪 (for slow query)
  │  NG_TRACE_EXT 在每个关键路径打点
```

### 本文路线

```
1. Profile 框架     ← ob_runtime_profile.h，核心数据结构
2. 指标系统         ← ob_runtime_metrics.h，ObMetric / ObMergeMetric
3. 算子名称枚举     ← ob_profile_name_def.h，全部算子 + 非算子场景
4. Profile 收集路径 ← ScopedTimer / REGISTER_METRIC / INC_METRIC_VAL
5. 序列化与持久化   ← to_persist_profile / convert_persist_profile_to_realtime
6. Profile 查询 →   ← ob_profile_util.h，通过内 SQL 查询 v$sql_plan_monitor
7. 多执行合并       ← ObMergeMetric + get_merged_profiles()
8. Trace 日志在 SQL  ← ob_trace_log.h，SQL 场景的 NG_TRACE_EXT
9. 慢查询机制       ← trace_log_slow_query_watermark 配置
10. Full Link Trace ← FLT 框架
11. 诊断体系全景     ← 结合文章 29、56、本文
12. 系列回顾         ← 60 篇的技术全景
```

---

## 1. Profile 框架 — ObOpProfile

Profile 框架位于 `src/share/diagnosis/ob_runtime_profile.h`，是 OceanBase 最新引入的算子级运行时指标收集体系。它不再局限于 Plan Monitor 那 10 个固定指标，而是允许每个算子**按需注册任意数量的自定义指标**（metric），并以 JSON 树结构输出。

### 1.1 核心类：ObOpProfile\<MetricType\>

```cpp
// ob_runtime_profile.h — 行 89-205
template<typename MetricType = ObMetric>
class ObOpProfile {
public:
  static constexpr int MAX_METRIC_SLOT_CNT = 
      ObMetricId::MONITOR_STATNAME_END - ObMetricId::MONITOR_STATNAME_BEGIN;
  static constexpr int METRICS_ID_MAP_SLOT{sizeof(uint8_t) * ObMetricId::MONITOR_STATNAME_END};
  static constexpr uint8_t LOCAL_METRIC_CNT = 8;

  explicit ObOpProfile(ObProfileId id, ObIAllocator *alloc, bool enable_rich_format = false);
  
  ObProfileId get_id() const { return id_; }
  const char *get_name_str() const;
  
  // 指标操作
  void get_metric_value(ObMetricId metric_id, bool &exist, uint64_t &value) const;
  const MetricType *get_metric(ObMetricId metric_id) const;
  int get_or_register_metric(ObMetricId metric_id, MetricType *&metric, bool head_insert = false);
  
  // 子 Profile 操作（Profile 是一个树结构）
  int get_or_register_child(ObProfileId id, ObOpProfile<MetricType> *&child);
  int register_child(ObProfileId id, ObOpProfile<MetricType> *&child);
  
  // 输出
  int64_t get_format_size() const;
  int to_format_json(ObIAllocator *alloc, const char *&result, bool with_outside_label = true,
                     metric::Level display_level = metric::Level::STANDARD);
  int pretty_print(ObIAllocator *alloc, const char *&result, ...) const;
  
  // 序列化
  int to_persist_profile(const char *&persist_profile, int64_t &persist_profile_size, 
                         ObIAllocator *alloc) const;
};
```

关键设计：

- **模板化**：`MetricType` 可以是 `ObMetric`（单次执行）或 `ObMergeMetric`（多次执行合并），复用同一套代码
- **树结构**：Profile 是一个 n 叉树，每个算子可以有多个子 Profile（如 HASH JOIN 内部有 build 和 probe 两个阶段）
- **两级存储**：前 8 个 metric 使用栈上数组 `local_metrics_[8]`，后续使用堆上 `non_local_metrics_` 数组，通过 `metrics_id_map_[512]` 做 O(1) 查找
- **无锁并发**：生产和消费线程通过 `ATOMIC_LOAD/STORE` 操作链表

### 1.2 Profile 树结构

Profile 构成一棵与执行计划算子树对齐的树：

```
PHY_HASH_JOIN                          <-- ObProfileId::PHY_HASH_JOIN
├── metric: HASH_ROW_COUNT = 10000     <-- ObMetric
├── metric: HASH_BUCKET_COUNT = 16384
├── child: "build side"               <-- 子 Profile
│   ├── metric: HASH_ROW_COUNT = 5000
│   └── metric: HASH_SLOT_MAX_COUNT = 12
└── child: "probe side"
    ├── metric: HASH_ROW_COUNT = 10000
    └── metric: HASH_SLOT_MAX_COUNT = 8
```

树的根节点对应执行计划的最外层算子（通常是 `PHY_ROOT_TRANSMIT` 或 `PHY_DIRECT_TRANSMIT`）。

### 1.3 内存布局

```cpp
// ob_runtime_profile.h — 行 160-205
private:
  union {
    int32_t name_id_{0};
    struct {
      bool enable_rich_format_ : 1;
      ObProfileId id_ : 31;
    };
  };
  ObIAllocator *alloc_{nullptr};
  
  int64_t metric_count_{0};
  MetricWrap *metric_head_{nullptr};     // 生产线程（执行引擎）写入
  MetricWrap *metric_tail_{nullptr};     // 查询线程（虚拟表）读取
  uint8_t metrics_id_map_[MAX_METRIC_SLOT_CNT];  // metric_id → 数组索引
  MetricWrap local_metrics_[LOCAL_METRIC_CNT];    // 前 8 个指标栈上存储
  ObSEArray<MetricWrap *, 16, ObIAllocator&> non_local_metrics_;  // 后续指标堆上存储
  ObOpProfile<MetricType> *parent_{nullptr};
  ProfileWrap *child_head_{nullptr};     // 子 Profile 链表头
  ProfileWrap *child_tail_{nullptr};     // 子 Profile 链表尾
  ObSEArray<ObOpProfile<MetricType> *, 4, ObIAllocator&> child_array_;
  bool with_label_{true};
```

这里有一对微妙的设计：

- **`metric_head_` vs `metric_tail_`**：执行引擎线程写入新的 metric 时追加到 tail（通过 `ATOMIC_STORE`），保证链表的原子构建；而虚拟表查询线程从 `metric_head_` 开始遍历读取。这种"读写分离"的设计避免了锁竞争
- **`local_metrics_[8]`**：首 8 个 metric 直接嵌入在 `ObOpProfile` 对象中，不需要额外分配内存。这是典型的小对象优化（Small Object Optimization）

### 1.4 关联 ObMonitorNode

Plan Monitor 的核心结构 `ObMonitorNode` 持有一个 `ObProfile *` 指针：

```cpp
// ob_sql_plan_monitor_node_list.h — 行 193-194
ObProfile *profile_{nullptr};
const char *raw_profile_{nullptr};
int64_t raw_profile_len_{0};
```

- `profile_`：运行时指向活跃的 `ObOpProfile<ObMetric>` 对象，算子执行期间持续更新
- `raw_profile_` / `raw_profile_len_`：序列化后的 persist profile（二进制），用于跨线程 / 跨节点传递。在节点提交到环形队列时，通过 `to_persist_profile()` 序列化

---

## 2. 指标系统 — ObMetric / ObMergeMetric

### 2.1 ObMetric — 单次执行指标

```cpp
// ob_runtime_metrics.h — 行 77-93
struct ObMetric {
  OB_INLINE uint64_t value() const { return ATOMIC_LOAD_RLX(&value_); }
  OB_INLINE void inc(uint64_t value) { ATOMIC_AAF(&value_, value); }  // 计数器
  OB_INLINE void set(uint64_t value) { ATOMIC_STORE_RLX(&value_, value); }  // 瞬时值
  int to_format_json(...);
  int pretty_print(...);
private:
  ObMetricId id_;
  uint64_t value_;
};
```

`ObMetric` 非常简单：一个 64 位计数器 + 无锁原子操作。这是因为它需要在**执行引擎的热路径**上被频繁更新，越简单越好。

- `inc()`：用于累计值，如 `HASH_ROW_COUNT`、`IO_READ_BYTES`
- `set()`：用于瞬时值，如 `OPEN_TIME`、`HASH_BUCKET_COUNT`

### 2.2 ObMergeMetric — 多执行合并指标

```cpp
// ob_runtime_metrics.h — 行 96-132
struct ObMergeMetric {
  void update(uint64_t value);
  uint64_t get_sum_value() const;
  uint64_t get_avg_value() const;
  uint64_t get_min_value() const;
  uint64_t get_max_value() const;
  uint64_t get_first_value() const;
  uint64_t get_deviation_value() const;  // 标准差

private:
  ObMetricId id_;
  uint64_t count_{0};
  uint64_t sum_value_{0};
  uint64_t min_value_{0};
  bool is_min_set_{false};
  uint64_t max_value_{0};
  uint64_t first_value_{0};
  double M2_{0.0};  // Welford's algorithm 的平方差累计值
};
```

`ObMergeMetric` 可以在一次遍历中同时计算 **SUM、AVG、MIN、MAX、FIRST、STDDEV** 六种聚合值。这得益于它使用**Welford 在线方差算法**：

```
M2_n = M2_{n-1} + (value - mean_{n-1}) * (value - mean_n)
```

这个算法的好处：
- 单次遍历（不用存储所有值）
- 数值稳定性好
- 内存开销恒定（仅多一个 double）

### 2.3 指标元数据

每个指标通过 `SQL_MONITOR_STATNAME_DEF` 宏定义其元数据（`ob_sql_monitor_statname.h`）：

```cpp
SQL_MONITOR_STATNAME_DEF(HASH_ROW_COUNT, metric::Unit::INT, "total row count",
    "total row count building hash table", M_SUM, metric::Level::CRITICAL)
```

| 字段 | 含义 |
|------|------|
| `HASH_ROW_COUNT` | 枚举名 |
| `metric::Unit::INT` | 单位（INT/BYTES/TIME_NS/TIMESTAMP/CPU_CYCLE）|
| `"total row count"` | 展示名 |
| `"total row count building hash table"` | 描述 |
| `M_SUM` | 聚合方式（SUM/AVG/MIN/MAX/STDDEV 的组合位图）|
| `metric::Level::CRITICAL` | 展示级别（CRITICAL > STANDARD > AD_HOC）|

指标按功能域分组：

| 域 | 示例指标 | 级别 |
|----|---------|------|
| HASH | `HASH_ROW_COUNT`, `HASH_SLOT_MIN/MAX_COUNT`, `HASH_BUCKET_COUNT` | CRITICAL |
| JOIN FILTER | `JOIN_FILTER_FILTERED_COUNT`, `JOIN_FILTER_TOTAL_COUNT` | STANDARD |
| SORT | `SORT_SORTED_ROW_COUNT`, `SORT_INMEM_SORT_TIME` | STANDARD |
| DTL (Data Transport Layer) | `DTL_LOOP_TOTAL_MISS`, `DTL_SEND_RECV_COUNT` | AD_HOC |
| PDML | `PDML_PARTITION_FLUSH_TIME`, `PDML_WRITE_DAS_BUFF_ROW_COUNT` | STANDARD |
| TABLE SCAN | `IO_READ_BYTES`, `TOTAL_READ_ROW_COUNT`, `BLOCKSCAN_BLOCK_CNT` | STANDARD |
| PX | `PX_WAIT_DISPATCH`, `SQC_DESERIALIZE_COST` | STANDARD |
| COMMON | `DB_TIME`, `IO_TIME`, `CPU_TIME`, `OUTPUT_ROWS` | CRITICAL |
| LAKE TABLE | `LAKE_TABLE_SELECTED_FILE_COUNT`, `LAKE_TABLE_READ_COUNT` | CRITICAL |
| HYBRID SEARCH | `HS_OUTPUT_ROW_COUNT`, `HS_TOTAL_TIME`, `HS_ADVANCE_COUNT` | STANDARD |

---

## 3. 算子名称枚举 — ObProfileId

`ob_profile_name_def.h` 使用 X-macro 定义了完整算子枚举。它被两个不同的宏展开：

### 3.1 OP_PROFILE_NAME_DEF — 算子类型

展开为 `ObProfileId` 枚举值，与 `ObPhyOperatorType` 一一对应：

```cpp
OP_PROFILE_NAME_DEF(PHY_INVALID)        // 0
OP_PROFILE_NAME_DEF(PHY_LIMIT)
OP_PROFILE_NAME_DEF(PHY_SORT)
OP_PROFILE_NAME_DEF(PHY_TABLE_SCAN)
OP_PROFILE_NAME_DEF(PHY_MERGE_JOIN)     // 5
// ...
OP_PROFILE_NAME_DEF(PHY_PX_FIFO_RECEIVE) // 68
OP_PROFILE_NAME_DEF(PHY_PX_DIST_TRANSMIT) // 70
// ...
OP_PROFILE_NAME_DEF(PHY_VEC_HASH_JOIN)  // 113
OP_PROFILE_NAME_DEF(PHY_HYBRID_FUSION)  // 138
OP_PROFILE_NAME_DEF(PHY_END)            // 139
```

共约 140 种算子类型，覆盖 DML、Scan、Join、Aggregation、Set、Sort、Window、PX、Vector 化执行、Hybrid Search 等。

### 3.2 OTHER_PROFILE_NAME_DEF — 非算子场景

展开为枚举值从 1000 开始，覆盖非算子执行场景：

```cpp
OTHER_PROFILE_NAME_DEF(LAKE_TABLE_FILE_READER, "Lake Table File Reader", 1000)
OTHER_PROFILE_NAME_DEF(LAKE_TABLE_PREFETCH, "Lake Table Prefetch")
OTHER_PROFILE_NAME_DEF(SQL_COMPILE, "Sql Compile")
OTHER_PROFILE_NAME_DEF(SQL_PARSE, "Sql Parse")
OTHER_PROFILE_NAME_DEF(SQL_RESOLVE, "Sql Resolve")
OTHER_PROFILE_NAME_DEF(SQL_REWRITE, "Sql Rewrite")
OTHER_PROFILE_NAME_DEF(SQL_OPTIMIZE, "Sql Optimize")
OTHER_PROFILE_NAME_DEF(HYBRID_SEARCH_BEGIN, "hybrid search begin", 1015)
OTHER_PROFILE_NAME_DEF(HYBRID_SEARCH, "Hybrid Search")
// ... 约 100 种 Hybrid Search 子操作
OTHER_PROFILE_NAME_DEF(HYBRID_SEARCH_END, "hybrid search end", 1115)
```

这支持了 Profile 框架在**非算子上下文**中的使用，如 SQL 编译阶段的各子阶段（Parse → Resolve → Rewrite → Optimize）都有独立的 Profile。

### 3.3 ObProfileNameSet

```cpp
// ob_profile_name_def.h — 末尾
struct ObProfileNameSet {
  struct ObProfileName { const char *name_{nullptr}; };
  ObProfileNameSet();
  static const char *get_profile_name(ObProfileId type, bool enable_rich_format = false);
private:
  ObProfileName set_[...];
};
```

名称映射表通过 `set_profile_type_name()` 动态构建，支持 `enable_rich_format` 切换显示格式。

---

## 4. Profile 收集路径

Profile 数据收集发生在执行引擎的运行期，通过三组宏和辅助类完成。

### 4.1 宏体系

```cpp
// ob_runtime_profile.h — 行 22-52

// 注册指标到当前 profile（不存在则创建）
#define REGISTER_METRIC(metric_id, metric) \
  if (OB_SUCC(ret)) { \
    ObOpProfile<ObMetric> *profile = get_current_profile(); \
    if (nullptr == profile) { \
    } else if (OB_FAIL(profile->get_or_register_metric(metric_id, metric))) { ... } \
  }

// 累加一个计数（如行数）
#define INC_METRIC_VAL(metric_id, value) \
  if (OB_SUCC(ret)) { \
    ObOpProfile<ObMetric> *profile = get_current_profile(); \
    if (nullptr != profile) { \
      ObMetric *metric = nullptr; \
      if (OB_FAIL(profile->get_or_register_metric(metric_id, metric))) { ... } \
      else { metric->inc(value); } \
    } \
  }

// 设置一个瞬时值（如桶数）
#define SET_METRIC_VAL(metric_id, value) \
  if (OB_SUCC(ret)) { \
    ... metric->set(value); ... \
  }
```

### 4.2 线程本地 Profile 指针

```cpp
// ob_runtime_profile.h — 末尾
template<typename MetricType = ObMetric>
inline ObOpProfile<MetricType> *&get_current_profile() {
  thread_local ObOpProfile<MetricType> *current_profile = nullptr;
  return current_profile;
}
```

所有宏都通过 `get_current_profile()` 获取线程本地的 Profile 指针。执行引擎通过 `ObProfileSwitcher` 在算子树遍历时切换这个指针：

```cpp
class ObProfileSwitcher {
public:
  explicit ObProfileSwitcher(ObProfileId id) {
    old_profile_ = get_current_profile();
    ObOpProfile<ObMetric> *new_profile = nullptr;
    if (nullptr == old_profile_) {
      // disabled
    } else if (OB_FAIL(old_profile_->get_or_register_child(id, new_profile))) {
      // ...
    } else {
      get_current_profile() = new_profile;
    }
  }
  ~ObProfileSwitcher() { get_current_profile() = old_profile_; }
private:
  ObOpProfile<ObMetric> *old_profile_{nullptr};
};
```

典型使用模式：

```cpp
// 在某算子执行 open() 时
{
  ObProfileSwitcher switcher(ObProfileId::PHY_HASH_JOIN);
  // 此时 get_current_profile() 返回的是 PHY_HASH_JOIN 的子 Profile
  INC_METRIC_VAL(ObMetricId::HASH_ROW_COUNT, input_row_count);
  SET_METRIC_VAL(ObMetricId::HASH_BUCKET_COUNT, bucket_count);
} // 析构时自动恢复父 Profile
```

### 4.3 ScopedTimer — 自动计时

`ScopedTimer` 是一个 RAII 计时器，在构造时记录起始时间，析构时自动累加到指定的 metric：

```cpp
// ob_runtime_profile.h — 行 244-279
class ScopedTimer {
public:
  explicit ScopedTimer(ObMetricId metric_id) {
    profile_ = get_current_profile();
    if (nullptr != profile_) {
      start_time_ = OB_TSC_TIMESTAMP.fast_current_time();
    }
  }
  ~ScopedTimer() {
    ObMetric *metric = nullptr;
    if (OB_ISNULL(profile_)) {
    } else if (OB_FAIL(profile_->get_or_register_metric(metric_id_, metric))) {
    } else {
      int64_t elapsed_time = (OB_TSC_TIMESTAMP.fast_current_time() - start_time_) * 1000LL;
      metric->inc(elapsed_time);  // 单位：纳秒
    }
  }
};
```

使用方式：

```cpp
void HashJoinOp::do_hash_build() {
  ScopedTimer timer(ObMetricId::CPU_TIME);
  // ... build hash table ...
}  // 析构时自动累加 CPU_TIME
```

### 4.4 填充通用指标

除了算子特有的指标，每个算子的 Profile 还会填充一组通用指标。这发生在 Profile 从 `ObProfileItem` 重建时：

```cpp
// ob_profile_util.cpp — fill_metrics_into_profile()
FILL_COMMON_METRIC(ObMetricId::WORKAREA_MEM, profile_item.workarea_mem_);
FILL_COMMON_METRIC(ObMetricId::OPEN_TIME, profile_item.open_time_);
FILL_COMMON_METRIC(ObMetricId::CLOSE_TIME, profile_item.close_time_);
FILL_COMMON_METRIC(ObMetricId::FIRST_ROW_TIME, profile_item.first_row_time_);
FILL_COMMON_METRIC(ObMetricId::OUTPUT_BATCHES, profile_item.output_batches_);
FILL_COMMON_METRIC(ObMetricId::OUTPUT_ROWS, profile_item.output_rows_);
FILL_COMMON_METRIC(ObMetricId::IO_TIME, profile_item.io_time_);
FILL_COMMON_METRIC(ObMetricId::CPU_TIME, profile_item.db_time_ - profile_item.io_time_);
FILL_COMMON_METRIC(ObMetricId::DB_TIME, profile_item.db_time_);
```

以及算子的 `OTHERSTAT_1 ~ 10` 自定义字段：

```cpp
FILL_OTHER_STAT(1); FILL_OTHER_STAT(2); // ...
```

---

## 5. 序列化与持久化

Profile 在执行引擎中是实时对象（指针、链表），但需要通过 Plan Monitor 的环形队列跨线程传递，并存储到内存中等待虚拟表查询。这需要**序列化**。

### 5.1 Persist Profile 二进制格式

```cpp
// ob_runtime_profile.h — 行 69-85
struct ObProfileHead {
  union {
    int32_t name_id_;
    struct { bool enable_rich_format_ : 1; ObProfileId id_ : 31; };
  };
  int32_t parent_idx_;
  int64_t offset_;
  int64_t length_;
};

struct ObProfileHeads {
  int64_t head_count_;
  int64_t metric_count_;
  int64_t head_offset_;
};
```

二进制布局（`ob_runtime_profile.cpp` 行 470 注解）：

```
profile 树：
          A
        /   \
       B     C
      / \   / \
     D   E F   G

二进制布局：
| head_count | profile_head_A | profile_head_B | …… | 7 个 profile_head |
|<──────  ObProfileHeads  ────────>|

| metric_id1 value1 metric_id2 value2  …… |  ← profile A 的指标数据
| metric_id1 value1 metric_id2 value2  …… |  ← profile B 的指标数据
……
```

每个 metric 占 16 字节（8 字节 metric_id + 8 字节 value）。CPU_CYCLE 单位的 metric 会在序列化时转换为纳秒：

```cpp
// ob_runtime_profile.cpp — 行 430-435
if (unit == metric::Unit::CPU_CYCLE) {
  static const int64_t scale = (1000 << 20) / OBSERVER_FREQUENCE.get_cpu_frequency_khz();
  metric_value = (metric_value * scale >> 20) * 1000;
}
```

### 5.2 序列化路径

```
算子执行结束
  │
  ▼
ObMonitorNode.profile_->to_persist_profile(raw_profile_, raw_profile_len_, &allocator_)
  │  ├─ get_all_count() 计算 metric 和 profile 数量
  │  ├─ get_persist_profile_size() 计算总大小
  │  ├─ alloc 内存
  │  ├─ 填充 ObProfileHeads 头部
  │  └─ convert_current_profile_to_persist() DFS 遍历树，写入 metric_id + value
  ▼
ObPlanMonitorNodeList::deep_copy_node()
  │  复制节点到环形队列，raw_profile_ 指向序列化后的缓冲区
  ▼
虚拟表查询时，convert_persist_profile_to_realtime() 还原为 ObProfile
  │  从 ObProfileHeads 读取头部，为每个 profile_head 创建 ObProfile 对象
  │  递归重建父子关系，设置每个 metric 的值
  ▼
填充通用指标（fill_metrics_into_profile），输出 JSON 格式到 RAW_PROFILE 字段
```

### 5.3 反序列化（还原）

```cpp
// ob_runtime_profile.cpp — 行 526-616
int convert_persist_profile_to_realtime(const char *persist_profile, const int64_t persist_len,
                                        ObOpProfile<ObMetric> *&profile, ObIAllocator *alloc) {
  // 1. 解析 ObProfileHeads 头部
  const ObProfileHeads *heads = reinterpret_cast<const ObProfileHeads*>(persist_profile);
  
  // 2. 为每个 profile 创建 ObOpProfile 对象
  for (int64_t i = 0; i < profile_cnt; ++i) {
    // 3. 根据 parent_idx_ 建立父子关系
    if (parent_idx != -1) {
      profiles_array[parent_idx]->get_or_register_child(id, new_profile);
    }
    // 4. 反序列化每个 metric
    for (int64_t j = 0; j < cur_metric_cnt; ++j) {
      cur_metric_id = *cur_metric_and_value_ptr++;
      cur_metric_value = *cur_metric_and_value_ptr++;
      // 5. 处理兼容性：忽略未知的 metric_id
      if (cur_metric_id <= MONITOR_STATNAME_BEGIN || 
          cur_metric_id >= MONITOR_STATNAME_END) {
        // 忽略高版本新加的 metric
      } else {
        metric->set(cur_metric_value);
      }
    }
  }
}
```

---

## 6. Profile 查询路径

用户不能直接查询 Profile 的二进制数据。OceanBase 通过 `ObProfileUtil` 提供查询接口。

### 6.1 核心查询

```cpp
// ob_profile_util.h — 行 98-103
static int get_profile_by_id(ObIAllocator *alloc, int64_t session_tenant_id,
    const ObString &trace_id, const ObString &svr_ip, int64_t svr_port,
    int64_t param_tenant_id, bool fetch_all_op, int64_t op_id,
    ObIArray<ObProfileItem> &profile_items);
```

内部执行的内 SQL：

```cpp
// ob_profile_util.cpp — 行 62-87
SELECT SVR_IP, SVR_PORT, THREAD_ID, PLAN_LINE_ID OP_ID, PLAN_DEPTH,
       PLAN_OPERATION, FIRST_REFRESH_TIME OPEN_TIME, LAST_REFRESH_TIME CLOSE_TIME,
       FIRST_CHANGE_TIME FIRST_ROW_TIME, LAST_CHANGE_TIME LAST_ROW_TIME,
       OUTPUT_BATCHES, SKIPPED_ROWS_COUNT, STARTS RESCAN_TIMES, OUTPUT_ROWS,
       DB_TIME, USER_IO_WAIT_TIME IO_TIME,
       WORKAREA_MEM, WORKAREA_MAX_MEM, WORKAREA_TEMPSEG, WORKAREA_MAX_TEMPSEG,
       SQL_ID, PLAN_HASH_VALUE,
       OTHERSTAT_1_ID ~ OTHERSTAT_10_VALUE,
       RAW_PROFILE
FROM OCEANBASE.__ALL_VIRTUAL_SQL_PLAN_MONITOR
WHERE TENANT_ID=? AND TRACE_ID='?' AND ...
ORDER BY PLAN_HASH_VALUE, SQL_ID, PLAN_LINE_ID
```

这条内 SQL 从 `__ALL_VIRTUAL_SQL_PLAN_MONITOR` 虚拟表读取原始数据，包括最关键的 `RAW_PROFILE` 字段（二进制 Profile）。

### 6.2 ProfileItem 数据结构

```cpp
// ob_profile_util.h — 行 20-67
struct ObProfileItem {
  ObAddr addr_;
  int64_t thread_id_{0};
  int64_t op_id_{0};
  int64_t plan_depth_{0};
  ObString op_name_;
  int64_t open_time_, close_time_, first_row_time_, last_row_time_;
  int64_t output_batches_, skipped_rows_, rescan_times_, output_rows_;
  int64_t db_time_, io_time_;
  int64_t workarea_mem_, workarea_max_mem_, workarea_tempseg_, workarea_max_tempseg_;
  ObString sql_id_;
  uint64_t plan_hash_value_{0};
  int64_t other_1_id_ ~ other_10_value_;   // 10 个自定义 K-V
  ObProfile *profile_{nullptr};            // 反序列化后的 Profile 树
};
```

### 6.3 读取流程

```
get_profile_by_id()
  │  构建内 SQL
  ▼
inner_get_profile()
  │  GCTX.sql_proxy_->read() 执行内 SQL
  ▼
循环调用 read_profile_from_result()
  │  1. 读取所有基础字段（GET_INT_VALUE / GET_VARCHAR_VALUE）
  │  2. 解析 RAW_PROFILE 二进制 → convert_persist_profile_to_realtime()
  │  3. 如果 RAW_PROFILE 为空，创建空 Profile（无指标但有算子信息）
  │  4. 填充通用指标（fill_metrics_into_profile）
  ▼
填充到 profile_items 数组
```

---

## 7. 多执行合并 — ObMergedProfile

同一 SQL 模板可能被多次执行（比如同一个绑定变量被不同值调用多次）。`ObProfileUtil::get_merged_profiles()` 将这些多次执行的 Profile 合并为 `ObMergedProfile`。

### 7.1 合并逻辑

```cpp
// ob_profile_util.cpp — 行 128-213
int ObProfileUtil::get_merged_profiles(ObIAllocator *alloc,
    const ObIArray<ObProfileItem> &profile_items,
    ObIArray<ObMergedProfileItem> &merged_profile_items,
    ObIArray<ExecutionBound> &execution_bounds) {
  
  // 以 (sql_id, plan_hash_value, op_id) 为键进行合并
  for (int64_t idx = 0; idx < profile_items.count(); ++idx) {
    if (cur_item.sql_id_ == merged_item.sql_id_
        && cur_item.plan_hash_value_ == merged_item.plan_hash_value_
        && cur_item.op_id_ == merged_item.op_id_) {
      // 同一次执行的同一个算子：merge
      merge_profile(*merged_item.profile_, cur_item.profile_, alloc);
      merged_item.parallel_++;
    } else {
      // 不同算子或不同执行：保存上一个，开始新的
      // 计算 max_db_time_ 用于排序
      // 对 PX 算子特殊处理：累加 CPU_TIME + DUMP_RW_TIME
    }
  }
}
```

合并后的 Profile 使用 `ObMergeMetric`，支持：

```
merge_profile(merged, piece):
  for each metric in piece:
    merged.get_or_register_metric(id) → merged_metric
    merged_metric.update(piece_metric.value())
```

`ObMergeMetric::update()` 内部使用 Welford 算法同时计算 sum/avg/min/max/stddev。

### 7.2 MergedProfileItem

```cpp
// ob_profile_util.h — 行 69-87
struct ObMergedProfileItem {
  int64_t op_id_;
  int64_t plan_depth_;
  uint64_t max_db_time_;        // 用于排序
  int64_t plan_hash_value_;
  ObString sql_id_;
  int64_t parallel_;            // 并行度
  ObMergedProfile *profile_;    // ObOpProfile<ObMergeMetric>
  const char *color_;           // 打印用颜色
  double rate_;                 // 占比
};
```

`color_` 字段支持终端颜色输出，用于 CLI 工具（如 OBDIAG）的可视化展示：

```cpp
const char *ObMergedProfileItem::COLORS[] = {
  "\033[1;38;5;220m",  // 黄色
  "\033[1;38;5;208m",  // 橙色
  "\033[1;38;5;160m",  // 红色
};
```

### 7.3 执行边界划分

同一 `trace_id` 下可能包含多个 SQL 执行（如存储过程中的多条 SQL）。`get_merged_profiles()` 通过跟踪 `plan_hash_value` / `sql_id` 的变化来划分执行边界：

```cpp
struct ExecutionBound {
  int64_t start_idx_;
  int64_t end_idx_;
  int64_t execution_count_;  // 通过 op_id == -1 的条数统计
};
```

---

## 8. Trace 日志在 SQL 场景

文章 56 已经详细分析了 Trace 日志的框架实现。这里补充在 SQL 执行场景下的使用。

### 8.1 SQL 关键路径打点

SQL 执行的关键事件通过 `NG_TRACE_EXT` 宏打点：

```cpp
// 例：obmp_base.cpp 在请求处理结束时
NG_TRACE_EXT(process_end, OB_ID(run_ts), get_run_timestamp());
```

这些 Trace 事件构成了 SQL 执行的时间线：

| Trace 事件 | 位置 | 含义 |
|-----------|------|------|
| `process_end` | `obmp_base.cpp` | 请求处理结束 |
| `query_start` | SQL 引擎入口 | 查询开始 |
| `optimizer_start/end` | 优化器 | 优化阶段耗时 |
| `px_schedule_start/end` | PX 调度 | 并行调度耗时 |
| `execute_start/end` | 执行器 | 执行阶段耗时 |

### 8.2 采样限流

```cpp
#define NG_TRACE_EXT_TIMES(times, ...) \
  if (is_trace_log_enabled() && CHECK_TRACE_TIMES(times, ObCurTraceId::get())) { \
    NG_TRACE_EXT(__VA_ARGS__); \
  }
```

`CHECK_TRACE_TIMES`（`ob_trace_log.h` 行 10-33）使用线程局部 `RLOCAL` 数组追踪每个 `trace_id` 的已打印次数，超过 `times` 后静默：

```cpp
struct TraceArray { uint64_t v_[3]; };  // {trace_id1, trace_id2, count}
RLOCAL(TraceArray, buffer);
```

### 8.3 慢查询强制打印

当 SQL 被判定为慢查询时，系统强制输出 Trace 日志并冲刷缓存：

```cpp
// obmp_base.cpp
if (is_slow) {
  FORCE_PRINT_TRACE(THE_TRACE, "[slow query]");
  FLUSH_TRACE();  // 立即冲刷 Trace 缓存
}
```

`FORCE_PRINT_TRACE`（`ob_trace_log.h` 行 47-54）忽略全局日志级别，仅在 ERROR 级别以下强制输出：

```cpp
#define FORCE_PRINT_TRACE(log_buffer, HEAD) \
  if (is_trace_log_enabled() && OB_LOGGER.get_log_level() != OB_LOG_LEVEL_DBA_ERROR) { \
    OB_PRINT("[TRACE]", OB_LOG_LEVEL_DIRECT(TRACE), HEAD, LOG_KVS("TRACE", *log_buffer)); \
  }
```

---

## 9. 慢查询机制

### 9.1 慢查询判定

OceanBase 使用集群级配置项 `trace_log_slow_query_watermark` 来界定慢查询：

```cpp
// src/share/parameter/ob_parameter_seed.ipp — 行 108
DEF_TIME(trace_log_slow_query_watermark, OB_CLUSTER_PARAMETER, "1s", "[1ms,]", ...);
```

默认值 **1s**，最小可设为 **1ms**。判定标准：

**请求级别**（`obmp_base.cpp` 行 122）：

```cpp
bool is_slow = (elapsed_time > GCONF.trace_log_slow_query_watermark)
    && !THIS_WORKER.need_retry();
```

**执行计划级别**（`ob_physical_plan.cpp` 行 565）：

```cpp
if (record.get_elapsed_time() > GCONF.trace_log_slow_query_watermark) {
  ATOMIC_INC(&(stat_.slow_count_));
}
```

**DAS RPC 级别**（`ob_das_rpc_processor.cpp`）：

```cpp
} else if (elapsed_time >= ObServerConfig::get_instance().trace_log_slow_query_watermark) {
  // 记录慢的 DAS 请求
}
```

**表 API 级别**（`ob_table_audit.h` 行 219）：

```cpp
if (elapsed_time > GCONF.trace_log_slow_query_watermark) {
  // 记录慢的 Table API 请求
}
```

### 9.2 慢查询的诊断输出

慢查询会触发一系列诊断动作：

```
慢查询判定
  │
  ├── FORCE_PRINT_TRACE(THE_TRACE, "[slow query]")
  │    输出该 SQL 的完整 Trace 事件链到 trace.log
  │
  ├── FLUSH_TRACE()
  │    强制冲刷 Trace 缓冲区，确保日志落盘
  │
  ├── AUTO FLUSH FULL LINK TRACE
  │    如果启用了 FLT，自动刷新全链路 Trace
  │
  └── 累积到 ObPlanStat.slow_count_
      用于性能基线统计
```

### 9.3 慢查询的水位传递

FLT（Full Link Trace）框架中，慢查询水位通过 `FLTControlInfo` 在客户端和服务端之间传递：

```cpp
// ob_flt_utils.cpp — 行 157
con.slow_query_thres_ = GCONF.trace_log_slow_query_watermark;
con.show_trace_enable_ = sess.is_use_trace_log();
``` 

这个控制信息通过客户端 RPC 请求的 extra info 传递，让服务端能够在执行前就知道是否需要为这次请求开启 Trace。

### 9.4 与 SQL Audit 的关系

慢查询和 SQL Audit 是互补关系：

| 维度 | SQL Audit (gv$sql_audit) | 慢查询机制 |
|------|--------------------------|-----------|
| 目的 | 全量记录所有 SQL 的执行信息 | 仅对慢的 SQL 做深度诊断 |
| 数据源 | `ObAuditRecordData` → 环形队列 | `ObTraceLog` → Trace 缓冲区 |
| 输出 | `gv$sql_audit` 虚拟表 | `trace.log` 文件 |
| 保留 | 环形队列覆盖（秒级） | 日志文件持久化 |
| 触发 | 每条 SQL 自动记录 | 超过 `trace_log_slow_query_watermark` |
| 信息量 | 80+ 字段的汇总统计 | 全事件链 |

**典型使用场景**：

```
1. DBA 发现业务报慢
2. 查 gv$sql_audit → 找到最慢的几条 SQL
3. 从 ELAPSED_TIME 最大的 SQL 中找到对应的 trace_id
4. 查 trace.log 中该 trace_id 的 [slow query] 日志
5. 分析 Trace 事件链，定位具体哪个阶段慢
6. 查 gv$plan_monitor 中该 request_id 的 RAW_PROFILE
7. 反序列化 Profile 树，找出具体哪个指标异常
```

---

## 10. Full Link Trace（FLT）框架

FLT 是全链路诊断的核心。它让 Trace 信息跨越客户端、OBServer 节点间的 RPC。

### 10.1 初始化

```cpp
// ob_flt_utils.cpp — init_flt_info() 行 79-100
int ObFLTUtils::init_flt_info(Ob20ExtraInfo extra_info,
    sql::ObSQLSessionInfo &session, bool is_client_support_flt, bool enable_flt) {
  
  // 1. 处理客户端传递的 FLT extra info（跨节点传递 trace id）
  if (extra_info.exist_full_link_trace()) {
    process_flt_extra_info(...);
  }
  
  // 2. 初始化 FLT 日志框架
  if (enable_flt) {
    init_flt_log_framework(session, is_client_support_flt);
  }
}
```

### 10.2 环境清理

```cpp
// ob_flt_utils.cpp — clean_flt_env() 行 50-63
void ObFLTUtils::clean_flt_env() {
  if (OBTRACE->is_query_trace()) {
    FLT_END_TRACE();  // 结束查询级 Trace
  } else {
    if (OBTRACE->is_in_transaction()) {
      // 事务级 Trace 不结束（整个事务共享一个 Trace）
    } else {
      FLT_END_TRACE();
    }
  }
}
```

### 10.3 Extra Info 传递

```cpp
// ob_flt_utils.cpp — append_flt_extra_info() 行 106-180
int ObFLTUtils::append_flt_extra_info(..., ObSQLSessionInfo &sess, ...) {
  // 检查是否需要发送控制信息
  if (sess.get_control_info().slow_query_thres_ != GCONF.trace_log_slow_query_watermark) {
    // 配置变更，需要重新发送
  }
  
  // 序列化控制信息（采样率、慢查询阈值）
  con.print_sample_pct_ = sess.get_tenant_print_sample_ppm() / 1000000;
  con.slow_query_thres_ = GCONF.trace_log_slow_query_watermark;
  con.show_trace_enable_ = sess.is_use_trace_log();
  
  // 序列化查询信息（起止时间）
  query_info.query_start_time_ = sess.get_query_start_time();
  query_info.query_end_time_ = current_time;
}
```

---

## 11. 诊断体系全景

现在，让我们把 SQL 性能分析的三大工具体系统一呈现。

### 11.1 三姐妹架构

```                  
                SQL 性能诊断体系
  ┌────────────────────────────────────────────────────────────┐
  │                                                            │
  │  SQL Audit (gv$sql_audit)                                  │
  │  ┌────────────────────────────────────────────────────┐    │
  │  │ ObAuditRecordData → ObRaQueue → gv$sql_audit       │    │
  │  │ 粒度: 请求级                                       │    │
  │  │ 字段: 时间线 + 26 种统计事件 + SQL 元数据            │    │
  │  │ 价值: 快速定位慢 SQL 和瓶颈阶段                      │    │
  │  └───────────────────┬────────────────────────────────┘    │
  │                      │ 发现慢的 request_id                  │
  │                      ▼                                     │
  │  Plan Monitor (v$plan_monitor)                             │
  │  ┌────────────────────────────────────────────────────┐    │
  │  │ ObMonitorNode → ObRaQueue → v$plan_monitor         │    │
  │  │ 粒度: 算子级                                       │    │
  │  │ 字段: 时间 + 行数 + db_time + workarea + OtherStat  │    │
  │  │ 价值: 定位瓶颈算子                                 │    │
  │  └───────────────────┬────────────────────────────────┘    │
  │                      │ 查看 RAW_PROFILE                     │
  │                      ▼                                     │
  │  Profile (RAW_PROFILE 字段)                                │
  │  ┌────────────────────────────────────────────────────┐    │
  │  │ ObOpProfile → to_persist_profile → RAW_PROFILE     │    │
  │  │ 粒度: 指标级                                       │    │
  │  │ 字段: 按需注册的任意指标（HASH、JOIN FILTER、IO...） │    │
  │  │ 价值: 定位具体问题（hash 碰撞、bloom filter 失效等）  │    │
  │  └────────────────────────────────────────────────────┘    │
  │                                                            │
  └────────────────────────────────────────────────────────────┘

  Trace 日志 (trace.log)
  ┌────────────────────────────────────────────────────────────┐
  │ NG_TRACE_EXT 事件链 → FORCE_PRINT_TRACE (slow query)       │
  │ 粒度: 事件级                                               │
  │ 价值: 分布式追踪，跨节点还原请求完整生命周期                  │
  └────────────────────────────────────────────────────────────┘
```

### 11.2 各工具的数据流

```
SQL 执行开始
  │
  ├── 创建 ObProfile（根 Profile）
  │   ├── ObProfileSwitcher 切换到子 Profile
  │   ├── REGISTER_METRIC / INC_METRIC_VAL / SET_METRIC_VAL
  │   ├── ScopedTimer 自动计时
  │   └── 析构 ObProfileSwitcher 恢复父 Profile
  │
  ├── 记录 ObAuditRecordData
  │   ├── record_start() / record_end()
  │   ├── ObExecTimestamp 时间链
  │   └── SQL 元数据
  │
  ├── 更新 ObPlanStat
  │   ├── slow_count_（慢查询计数）
  │   ├── slowest_exec_usec_（最慢执行）
  │   └── table_scan_stat_ 等算子统计
  │
  └── NG_TRACE_EXT 事件打点（条件性）
      └── 如果超时 → FORCE_PRINT_TRACE + FLUSH_TRACE

SQL 执行结束
  │
  ├── ObProfile → to_persist_profile() → RAW_PROFILE
  ├── ObMonitorNode → submit_node() → ObRaQueue
  ├── ObAuditRecordData → add_request_record() → ObRaQueue
  └── ObExecutedSqlStatRecord 累积
```

### 11.3 三种诊断视角

| 视角 | 适用场景 | 关键指标 | 数据源 |
|------|---------|---------|--------|
| **用户视角** | 业务报告慢 | `ELAPSED_TIME`, `QUEUE_TIME` | `gv$sql_audit` |
| **DBA 视角** | 定位瓶颈 | `DB_TIME`, `IO_TIME`, join 算法 | `gv$plan_monitor` |
| **开发者视角** | 根因分析 | hash 碰撞率、cache miss、bloom filter 过滤率 | `RAW_PROFILE` |

---

## 12. 系列回顾 — 60 篇的技术深度

从文章 01 到文章 60，整个系列覆盖了 OceanBase 源码的十大核心领域：

### 存储引擎（01-15）

从 MVCC 行开始，深入 Iterator 机制、事务冲突处理、Callback 体系、Compaction 与冻结、LS Tree 存储层次、SSTable 格式、DAS 分布式访问层、2PC 事务协议、PALF 日志存储、Election 选举算法、Clog 日志系统、Memtable 内存表、KeyBtree 索引结构。

### 分布式核心（11-20，31-40）

选举算法、日志同步、事务协议、迁移复制、分布式执行（PX）、Plan Cache、SQL Parser、类型系统、内存管理、编码引擎、RootServer、GTS 全局时钟。

### SQL 执行引擎（21-30，41-50）

DML 处理、表达式求值、子查询优化、Merge Join、宏块存储、并发控制、路由分发、成员变更、租户管理、MySQL 协议兼容、Join 实现、Sort/Window 函数、聚合操作。

### 基础设施与诊断（51-60）

Block Cache 体系、Bloom Filter 实现、RPC 框架、序列化协议、无锁数据结构、Logger 日志系统（含 Trace）、配置管理、线程模型、Schema 服务，以及本文的 Profile 框架。

### 技术方法论

贯穿始终的技术要点：

```
无锁并发    ：CAS 操作、无锁队列、读写分离（19 篇涉及）
宏展开      ：X-macro（14 篇涉及）
模板特化    ：为不同场景定制（10 篇涉及）
O(1) 查找   ：ID 映射数组（8 篇涉及）
RAII 资源管理：Scoped guard / Switcher（15 篇涉及）
Welford 算法：在线方差计算（本文）
```

---

## 13. 源码索引

### 13.1 Profile 框架

| 文件 | 关键类/结构体 | 行号 | 说明 |
|------|-------------|------|------|
| `src/share/diagnosis/ob_runtime_profile.h` | `ObOpProfile` | 89-205 | 运行时 Profile 树 |
| `src/share/diagnosis/ob_runtime_profile.h` | `ObProfileHead` | 58-68 | 序列化头部 |
| `src/share/diagnosis/ob_runtime_profile.h` | `ObProfileHeads` | 70-78 | Persist Profile 头部 |
| `src/share/diagnosis/ob_runtime_profile.h` | `ObProfileSwitcher` | 216-237 | Profile 上下文切换 |
| `src/share/diagnosis/ob_runtime_profile.h` | `ScopedTimer` | 239-279 | RAII 自动计时 |
| `src/share/diagnosis/ob_runtime_profile.cpp` | convert_to_format_json | 55-135 | JSON 格式化输出 |
| `src/share/diagnosis/ob_runtime_profile.cpp` | pretty_print | 140-223 | 文本格式化输出 |
| `src/share/diagnosis/ob_runtime_profile.cpp` | register_metric | 228-275 | 注册指标 |
| `src/share/diagnosis/ob_runtime_profile.cpp` | register_child | 290-326 | 注册子 Profile |
| `src/share/diagnosis/ob_runtime_profile.cpp` | convert_to_persist | 380-460 | 序列化到 Persist 格式 |
| `src/share/diagnosis/ob_runtime_profile.cpp` | convert_persist_to_realtime | 526-616 | 从 Persist 还原 |
| `src/share/diagnosis/ob_runtime_profile.cpp` | ScopedTimer::~ScopedTimer | 618-630 | 计时器析构累加 |

### 13.2 指标系统

| 文件 | 关键类/结构体 | 行号 | 说明 |
|------|-------------|------|------|
| `src/share/diagnosis/ob_runtime_metrics.h` | `ObMetric` | 77-93 | 单次执行指标 |
| `src/share/diagnosis/ob_runtime_metrics.h` | `ObMergeMetric` | 96-132 | 多执行合并指标（Welford 算法）|
| `src/share/diagnosis/ob_runtime_metrics.h` | `get_metric_name/description/etc` | 39-75 | 指标元数据查询函数 |
| `src/share/diagnosis/ob_sql_monitor_statname.h` | `ObSqlMonitorStatIds` | 全部 | 全部指标枚举定义 |
| `src/share/diagnosis/ob_sql_monitor_statname.h` | `ObMonitorStat` | 全部 | 指标元数据（结构体）|

### 13.3 算子名称

| 文件 | 关键类/结构体 | 行号 | 说明 |
|------|-------------|------|------|
| `src/share/diagnosis/ob_profile_name_def.h` | `OP_PROFILE_NAME_DEF` | 全部 | 140 种算子枚举 |
| `src/share/diagnosis/ob_profile_name_def.h` | `OTHER_PROFILE_NAME_DEF` | 全部 | 110+ 种非算子场景枚举 |
| `src/share/diagnosis/ob_profile_name_def.h` | `ObProfileNameSet` | 末尾 | 名称映射表 |

### 13.4 Profile 查询

| 文件 | 关键类/函数 | 行号 | 说明 |
|------|------------|------|------|
| `src/share/diagnosis/ob_profile_util.h` | `ObProfileItem` | 20-67 | 查询结果条目 |
| `src/share/diagnosis/ob_profile_util.h` | `ObMergedProfileItem` | 69-87 | 合并后条目 |
| `src/share/diagnosis/ob_profile_util.h` | `ObProfileUtil` | 94-121 | 查询/合并工具类 |
| `src/share/diagnosis/ob_profile_util.cpp` | `get_profile_by_id` | 62-96 | 通过 trace_id 查询 Profile |
| `src/share/diagnosis/ob_profile_util.cpp` | `get_merged_profiles` | 128-213 | 多执行合并 |
| `src/share/diagnosis/ob_profile_util.cpp` | `merge_profile` | 216-260 | 递归合并 Profile 树 |
| `src/share/diagnosis/ob_profile_util.cpp` | `read_profile_from_result` | 270-410 | 从 SQL 结果读取 Profile |

### 13.5 Trace 日志

| 文件 | 关键类/宏 | 行号 | 说明 |
|------|----------|------|------|
| `deps/oblib/src/lib/oblog/ob_trace_log.h` | `NG_TRACE_EXT` | 全部 | 事件打点宏 |
| `deps/oblib/src/lib/oblog/ob_trace_log.h` | `CHECK_TRACE_TIMES` | 10-33 | 事件打印限流 |
| `deps/oblib/src/lib/oblog/ob_trace_log.h` | `PRINT_TRACE` / `FORCE_PRINT_TRACE` | 38-54 | Trace 输出 |
| `deps/oblib/src/lib/oblog/ob_trace_log.h` | `ObTraceLogConfig` | 65-80 | Trace 级别配置 |

### 13.6 慢查询

| 文件 | 位置 | 说明 |
|------|------|------|
| `src/observer/mysql/obmp_base.cpp` | 行 122 | 请求级慢查询判定 |
| `src/observer/mysql/obmp_packet_sender.cpp` | 行 673 | 响应发送时的慢查询检测 |
| `src/sql/engine/ob_physical_plan.cpp` | 行 565 | 执行计划级慢查询计数 |
| `src/sql/das/ob_das_rpc_processor.cpp` | 行 269, 445 | DAS RPC 慢查询 |
| `src/observer/table/ob_table_audit.h` | 行 219 | Table API 慢查询 |
| `src/share/parameter/ob_parameter_seed.ipp` | 行 108 | `trace_log_slow_query_watermark` 配置定义 |

### 13.7 FLT 框架

| 文件 | 关键类/函数 | 行号 | 说明 |
|------|------------|------|------|
| `src/sql/monitor/flt/ob_flt_utils.cpp` | `init_flt_info` | 79-100 | FLT 初始化 |
| `src/sql/monitor/flt/ob_flt_utils.cpp` | `clean_flt_env` | 50-63 | FLT 环境清理 |
| `src/sql/monitor/flt/ob_flt_utils.cpp` | `append_flt_extra_info` | 106-180 | Extra Info 组装 |
| `src/sql/monitor/flt/ob_flt_utils.cpp` | `record_flt_last_trace_id` | 9-45 | 保存上一个 Trace ID |

---

*本文基于 OceanBase CE 主线源码分析，doom-lsp 用于符号解析和结构确认。所有行号以源码对应 commit 为准。*

*这是 OceanBase 源码分析 60 篇系列的最后一篇。从第一篇的 MVCC 行开始，到本篇的 Profile 框架结束，我们完整走通了一个分布式数据库从存储引擎到 SQL 可观测性的技术全貌。*
