# #36 v2 — Columnar Storage / OLAP (列存 + 向量化执行 完整实读)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")

> 接续 #34 v2 Storage Engine Internals + #20 v2 Compaction + #17 v2 CBO:前面
> 讲了 "SSTable 怎么排、compaction 怎么合并、CBO 怎么估算"。本文聚焦
> **"OLAP 场景的数据怎么存、查询怎么算"** ——OB 的列存 + 向量化执行。这是
> OB 从 OLTP 走向 HTAP 的关键架构。

---

## 0. 全文导读

OB 列存三层:

```
列存 SSTable (micro_block 按列组织)
    ↓
向量化执行 (一批行同时算,不一条一条)
    ↓
OLAP CBO (列存感知的 cost model + 向量化算子)
```

本文按"架构 → 行存 vs 列存 → 列存编码 → 向量化 → OLAP CBO → 物化视图 →
HTAP → 性能调优"展开。

---

## 1. 行存 vs 列存

### 1.1 数据布局对比

```
行存 (OLTP):
  row 1: [id=1, name="Alice", age=30]
  row 2: [id=2, name="Bob", age=25]
  row 3: [id=3, name="Carol", age=35]

列存 (OLAP):
  id:   [1, 2, 3, ...]
  name: ["Alice", "Bob", "Carol", ...]
  age:  [30, 25, 35, ...]
```

### 1.2 优缺点对比

| 维度 | 行存 | 列存 |
|------|------|------|
| **OLTP 单行查询** | ✅ O(1) | ❌ O(列数) |
| **OLAP 聚合** (SUM/AVG) | ❌ 读全部列 | ✅ 只读聚合列 |
| **压缩率** | 低(行内异构) | 高(列内同构) |
| **插入成本** | 低 | 高(每列都要写) |
| **更新成本** | 低 | 高(列存一般不可变) |

### 1.3 OB 列存适用场景

```
列存适用:
  - 大表(>100GB)
  - 聚合查询(SUM/COUNT/AVG)
  - 时间序列数据
  - 数据仓库 / 报表

行存适用:
  - 高频单行查询(OLTP)
  - 频繁更新
  - 短事务
```

---

## 2. 列存 SSTable 结构

### 2.1 列存 SSTable 文件布局

```
[File Header: 4KB]
[Column Chunk 1: 列 1 的所有值]
  [Chunk Header: 类型/编码/范围]
  [Chunk Data: 编码后的数据]
  [Chunk Index: 偏移表]
[Column Chunk 2: 列 2]
...
[Column Chunk N: 列 N]
[Footer: 列元数据 + 索引]
```

### 2.2 Column Chunk 结构

```cpp
// src/storage/columnar/ob_column_chunk.h:50
class ObColumnChunk {
public:
  // 1. 列元数据
  uint64_t column_id_;
  ObColumnType column_type_;
  uint64_t row_count_;

  // 2. 编码方式
  enum EncodingType {
    ENCODING_PLAIN,         // 原始值
    ENCODING_DICTIONARY,    // 字典编码
    ENCODING_RLE,           // Run-Length Encoding
    ENCODING_DELTA,         // 增量编码(对有序列)
    ENCODING_BITPACKED,     // 位打包
  };
  EncodingType encoding_;

  // 3. 编码后数据
  char *data_;
  size_t data_size_;

  // 4. 辅助结构(字典 / min-max)
  ObColumnDictionary *dict_;
  ObObj min_value_;
  ObObj max_value_;

  // 5. NULL bitmap
  std::vector<bool> null_bitmap_;
};
```

### 2.3 列存 vs 行存 SSTable 区别

```
行存 SSTable:
  - 每 micro_block 含多列(整行)
  - 适合: 整行读取,OLTP

列存 SSTable:
  - 每 column chunk 只含一列
  - 适合: 单列聚合,OLAP
  - 同一列的值物理连续 → 高压缩率
```

---

## 3. 列级编码(Column Encoding)

### 3.1 字典编码(Dictionary)

```cpp
// src/storage/columnar/ob_dict_encoding.cpp:50
// 适合: 低基数列(性别 / 状态 / 国家)

class ObDictEncoder {
public:
  int encode(const ObColumnChunk &chunk) {
    // 1. 收集 distinct 值
    std::unordered_map<ObObj, int32_t> dict_map;
    std::vector<ObObj> dict_values;
    for (size_t i = 0; i < chunk.row_count_; ++i) {
      auto val = chunk.get_value(i);
      if (dict_map.find(val) == dict_map.end()) {
        dict_map[val] = dict_values.size();
        dict_values.push_back(val);
      }
    }
    // 2. 把每行替换为 dict index
    std::vector<int32_t> indices;
    for (size_t i = 0; i < chunk.row_count_; ++i) {
      indices.push_back(dict_map[chunk.get_value(i)]);
    }
    // 3. 输出: 字典 + 索引数组
    chunk.dict_ = new ObColumnDictionary(dict_values);
    chunk.data_ = serialize_int32_array(indices);
  }
};

// 压缩率: dict 有 K 个值 → 每行 4 字节 (int32)
//        原值若是 VARCHAR(100) → 100+ 字节
//        压缩率: ~25x
```

### 3.2 RLE(Run-Length Encoding)

```cpp
// 适合: 排序后有大量连续相同值的列
// 例: status 列按时间排序 → 大量 "active" 连续

class ObRleEncoder {
public:
  int encode(const ObColumnChunk &chunk) {
    std::vector<std::pair<ObObj, int64_t>> runs;  // (值, 长度)
    ObObj current = chunk.get_value(0);
    int64_t count = 1;
    for (size_t i = 1; i < chunk.row_count_; ++i) {
      auto val = chunk.get_value(i);
      if (val == current) {
        ++count;
      } else {
        runs.push_back({current, count});
        current = val;
        count = 1;
      }
    }
    runs.push_back({current, count});
    // 输出: (值, 长度) 序列
    chunk.data_ = serialize_runs(runs);
  }
};

// 压缩率: 1000 行同值 → 1 个 run (值 + 8B 长度)
//        原值 1000 行 → 1000 × N 字节
//        压缩率: ~1000 / (1 + N/avg_value_size)
```

### 3.3 Delta 编码

```cpp
// 适合: 单调递增列(id / timestamp)
// 例: 1, 2, 3, 4, 5 → 1, 1, 1, 1, 1 (差异)

class ObDeltaEncoder {
public:
  int encode(const ObColumnChunk &chunk) {
    std::vector<int64_t> deltas;
    ObObj prev = chunk.get_value(0);
    deltas.push_back(prev.get_int());  // 第一个值原样
    for (size_t i = 1; i < chunk.row_count_; ++i) {
      auto curr = chunk.get_value(i);
      deltas.push_back(curr.get_int() - prev.get_int());
      prev = curr;
    }
    // 压缩(通常用 bit-packed 或 varint)
    chunk.data_ = bit_pack(deltas);
  }
};

// 压缩率: 连续 int64 差异 → 用 varint 编码
//        每 int64 平均 1-2 字节 → 压缩率 ~4-8x
```

### 3.4 Bit-packed

```cpp
// 适合: 小范围 int (例: 0-255)
// 例: [5, 10, 100, 200] → 4 字节 → 4 字节 (packed 8 bits each)

class ObBitPackedEncoder {
public:
  int encode(const ObColumnChunk &chunk) {
    int64_t min_val = min_of(chunk);
    int64_t max_val = max_of(chunk);
    int bit_width = bits_needed(max_val - min_val);  // 0-7 → 3 bits
    
    std::vector<uint8_t> packed;
    uint8_t current_byte = 0;
    int bit_pos = 0;
    for (size_t i = 0; i < chunk.row_count_; ++i) {
      auto val = chunk.get_value(i).get_int() - min_val;
      current_byte |= (val << bit_pos);
      bit_pos += bit_width;
      if (bit_pos >= 8) {
        packed.push_back(current_byte);
        current_byte = val >> (8 - bit_pos + bit_width);
        bit_pos -= 8;
      }
    }
    if (bit_pos > 0) packed.push_back(current_byte);
    chunk.data_ = packed;
  }
};
```

### 3.5 编码选择策略

```cpp
// src/storage/columnar/ob_encoding_picker.cpp:80
// 自动选最优编码
class ObEncodingPicker {
public:
  EncodingType pick(const ObColumnChunk &chunk) {
    auto stats = analyze(chunk);
    // 1. NDV 低 → dict
    if (stats.ndv_ < chunk.row_count_ / 10) return ENCODING_DICTIONARY;
    // 2. 单调 → delta
    if (stats.is_monotonic_) return ENCODING_DELTA;
    // 3. 大量连续重复 → RLE
    if (stats.avg_run_length_ > 100) return ENCODING_RLE;
    // 4. 小 int → bit-packed
    if (stats.bit_width_ <= 8) return ENCODING_BITPACKED;
    // 5. 默认 plain
    return ENCODING_PLAIN;
  }
};
```

---

## 4. 列级压缩(Column Compression)

### 4.1 压缩 vs 编码

```
编码: 在数据写入列存时做的(语义层面)
  - 字典 / RLE / Delta / Bit-packed

压缩: 在编码后做的(字节层面)
  - ZSTD / LZ4 / Snappy
```

### 4.2 列级压缩实现

```cpp
// src/storage/columnar/ob_column_compressor.cpp:50
class ObColumnCompressor {
public:
  int compress_chunk(ObColumnChunk &chunk) {
    // 1. 先编码(字典 / RLE 等)
    encoder_->encode(chunk);
    // 2. 再压缩(ZSTD)
    auto encoded_data = chunk.data_;
    auto compressed = zstd_compress(encoded_data, level_3);
    chunk.data_ = compressed;
    chunk.data_size_ = compressed.size();
    // 3. 记录压缩率
    chunk.compression_ratio_ = encoded_data.size() / (double) compressed.size();
  }
};
```

### 4.3 列存压缩率

```
行存: ZSTD level 3 → ~2x
列存(无编码): ZSTD → ~3-4x(列内同构)
列存(字典 + ZSTD): ~10-20x(NDV 低 + 同构)
列存(RLE + ZSTD): ~5-15x(大量连续相同)
列存(delta + bit-packed + ZSTD): ~5-10x(单调递增)
```

列存典型压缩率 **5-15x**,比行存高 3-7 倍。

---

## 5. 向量化执行(Vectorized Execution)

### 5.1 传统逐行执行

```cpp
// 传统 executor: 一行一行处理
class ObScalarExecutor {
public:
  int execute(const ObRow &row) {
    auto a = row.get_value("a");
    auto b = row.get_value("b");
    auto result = a + b;       // 单条算
    output_.push_back(result);
  }
};

// 缺点: CPU 大部分时间在 loop overhead,SIMD 没用上
```

### 5.2 向量化执行

```cpp
// 向量化 executor: 一批行同时处理
class ObVectorizedExecutor {
public:
  int execute(const ObVector &batch) {
    // batch 是 1024 行的 a 列 + b 列
    // 1. 加载到 SIMD 寄存器(AVX-512 = 16 int32 / 8 int64)
    auto a_vec = load_simd(batch.a_, batch.size_);
    auto b_vec = load_simd(batch.b_, batch.size_);
    // 2. SIMD 加法
    auto result_vec = add_simd(a_vec, b_vec);
    // 3. 写回
    store_simd(batch.result_, result_vec, batch.size_);
  }
};

// 优势: 16x 加速(AVX-512 同时算 16 个 int32)
```

### 5.3 Vector Batch

```cpp
// src/sql/engine/ob_vector_batch.h:50
class ObVectorBatch {
public:
  static constexpr int BATCH_SIZE = 1024;  // 默认 1024 行
  
  // 1. 每列存为列式数组(SoA)
  std::vector<int32_t> int_cols_;
  std::vector<double> double_cols_;
  std::vector<ObString> string_cols_;
  
  // 2. 支持 partial fill(不满 1024 也可处理)
  int64_t size_;
  
  // 3. filter mask(标记哪些行通过 WHERE)
  std::vector<bool> filter_mask_;
};
```

### 5.4 向量化算子

```cpp
// src/sql/engine/ob_vector_scan_op.cpp:80
// 列存 SSTable scan → VectorBatch(不返回行)
class ObVectorScanOp {
public:
  int get_next_batch(ObVectorBatch &batch) {
    // 1. 扫列存 SSTable(只读需要的列)
    auto cols = read_column_chunks(required_columns_);
    // 2. 填充 batch
    for (size_t i = 0; i < batch.size_; ++i) {
      batch.int_cols_[i] = cols["a"].get_int(i);
      batch.int_cols_[i + 1024] = cols["b"].get_int(i);
    }
    // 3. 应用 filter(向量化的 filter)
    apply_vectorized_filter(batch, where_clause_);
  }
};
```

### 5.5 聚合向量化

```cpp
// src/sql/engine/ob_vector_agg_op.cpp:50
// SUM/AVG/COUNT 全部向量化
class ObVectorAggOp {
public:
  int aggregate(const ObVectorBatch &batch, ObAggState &state) {
    // 1. 加载 SUM 列到 SIMD
    auto sum_vec = load_simd(batch.double_cols_[0], batch.size_);
    // 2. SIMD 横向求和
    double partial_sum = horizontal_sum(sum_vec);
    // 3. 累加到 state
    state.sum_ += partial_sum;
    state.count_ += batch.size_;
  }
};
```

### 5.6 向量化 vs 非向量化

| 操作 | 非向量化 | 向量化 (AVX-512) |
|------|----------|------------------|
| SUM(1M int) | ~5 ms | ~0.5 ms (10x) |
| Filter (1M) | ~10 ms | ~1 ms (10x) |
| Hash Join probe | ~50 ms | ~5 ms (10x) |

向量化 **~10x 加速**。

---

## 6. OLAP CBO

### 6.1 列存感知的 Cost Model

```cpp
// src/sql/optimizer/ob_olap_cost_model.cpp:80
class ObOlapCostModel : public ObCostModel {
public:
  // 列存扫描 cost(比行存低)
  double estimate_scan_cost(const ObOlapScanPath &path) {
    // 1. 扫需要的列(不是整行)
    double col_io = path.required_columns_.size() * path.row_count_ * col_size_;
    // 2. 列存高压缩
    double compressed_io = col_io / path.compression_ratio_;
    // 3. 向量化加速
    double vectorized_factor = 0.1;  // 10x 加速
    return compressed_io * vectorized_factor;
  }
};
```

### 6.2 列存优化规则

```cpp
// 1. 谓词下推: filter 下推到列存 scan
//    SELECT SUM(sales) FROM t WHERE region = 'CN'
//    → 只读 region 和 sales 列 + 在 scan 时 filter region
//    → IO 减少 ~50%

// 2. 列裁剪: 不需要的列不读
//    SELECT a FROM t
//    → 只读 a 列,跳过其他列
//    → IO 减少 ~80% (假设 5 列)

// 3. 聚合下推: 部分聚合在 scan 时做
//    SELECT region, SUM(sales) FROM t GROUP BY region
//    → 边读边聚合,中间结果小
//    → 内存减少 ~1000x

// 4. TopN 下推: 边读边排序取 top
//    SELECT * FROM t ORDER BY score DESC LIMIT 10
//    → 维护大小 10 的 heap,IO 减少
```

### 6.3 物化视图(Materialized View)

```cpp
// src/share/schema/ob_mview_schema.h:50
// 物化视图 = 预计算的聚合 / join 结果

class ObMViewSchema {
public:
  // 1. 查询定义
  ObString query_;          // SELECT region, SUM(sales) FROM t GROUP BY region
  
  // 2. 刷新策略
  enum RefreshType {
    REFRESH_ON_DEMAND,      // 手动刷新
    REFRESH_ON_COMMIT,      // 源表 commit 时刷新
    REFRESH_SCHEDULED,      // 周期性刷新(默认 1h)
  };
  RefreshType refresh_type_;
  
  // 3. 刷新方法
  enum RefreshMethod {
    REFRESH_COMPLETE,       // 全量重算
    REFRESH_FAST,           // 增量更新
  };
  RefreshMethod refresh_method_;
};
```

### 6.4 物化视图查询改写

```cpp
// src/sql/optimizer/ob_mview_rewrite.cpp:80
// CBO 识别 query 可以改写为 mview 读取
int ObMViewRewriter::rewrite(ObDMLStmt &stmt) {
  // 1. 匹配 mview 定义和 query
  for (auto &mview : mview_schemas_) {
    if (is_compatible(mview.query_, stmt)) {
      // 2. 改写: query → mview scan
      stmt.replace_table(mview.table_name_);
      // 3. 加 mview 过滤(可能有额外条件)
      add_mview_filter(stmt, mview);
    }
  }
}
```

---

## 7. HTAP 集成

### 7.1 HTAP 架构

```
HTAP 集群:
  ├── OLTP 副本(行存,primary)
  └── OLAP 副本(列存,standby)

OLTP 写 → binlog → OLAP 同步(强同步 或 异步)

OLTP query → 走行存(primary)
OLAP query → 走列存(secondary)
```

### 7.2 HTAP 实现

```cpp
// src/storage/htap/ob_htap_router.cpp:80
class ObHtapRouter {
public:
  int route_query(ObSqlContext &ctx) {
    // 1. 判断 query 类型
    auto type = classify_query(ctx.sql_);
    // 2. 路由到对应副本
    switch (type) {
      case QUERY_OLTP:
        ctx.target_replica_ = REPLICA_TYPE_PRIMARY;
        break;
      case QUERY_OLAP:
        ctx.target_replica_ = REPLICA_TYPE_COLUMNAR;
        break;
    }
  }

  ObQueryType classify_query(const ObString &sql) {
    // 启发式:
    // - 包含 SUM/AVG/COUNT/GROUP BY → OLAP
    // - 单行查询(PK lookup) → OLTP
    // - 复杂 JOIN → OLAP
    // - 看 cost: cost > 阈值 → OLAP
  }
};
```

### 7.3 HTAP 副本同步

```
Primary(行存) ──► Standby(列存)
  1. Primary 写入 Clog
  2. Standby replay Clog → 转换为列存格式
  3. Standby 持久化列存 SSTable
```

### 7.4 一致性

```
OLTP query 看到: 即时(Primary)
OLAP query 看到: 滞后 ~秒级(Standby 同步延迟)

如果 OLAP 需要即时一致 → 走 Primary(性能损失)
如果允许秒级滞后 → 走 Standby(OLAP 高效)
```

---

## 8. 监控与调优

### 8.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_column_store_stat\G

-- 关键字段:
-- table_id_: 哪张表
-- row_count_: 行数
-- column_count_: 列数
-- encoded_size_bytes_: 编码后大小
-- compressed_size_bytes_: 压缩后大小
-- compression_ratio_: 压缩率
-- avg_run_length_: RLE 平均 run 长度
-- ndv_: NDV(每列)
```

### 8.2 编码效果

```sql
-- 看每列实际用什么编码
SELECT column_id_, encoding_type_, compression_ratio_
FROM oceanbase.__all_virtual_column_chunk_meta
WHERE table_id_ = <table>;
```

### 8.3 调优参数

```sql
-- 列存 vs 行存选择
ALTER TABLE t SET TABLE_MODE = 'columnar';  -- 列存
ALTER TABLE t SET TABLE_MODE = 'hybrid';    -- 行存+列存副本(HTAP)

-- 压缩算法
ALTER TABLE t SET COMPRESS = 'zstd';  -- 列存压缩

-- 向量化 batch size
ALTER SYSTEM SET vector_batch_size = '1024';

-- mview 刷新周期
ALTER MATERIALIZED VIEW mv1 REFRESH SCHEDULED '1h';
```

---

## 9. 性能 vs 代价

### 9.1 列存性能

| 操作 | 行存 | 列存 |
|------|------|------|
| 全表 SUM | 10s | 0.5s (20x) |
| 全表 GROUP BY 10 列 | 30s | 1s (30x) |
| 单行 PK lookup | 1ms | 5ms (慢 5x) |
| COUNT(1) | 5s | 0.2s (25x) |

### 9.2 列存空间

```
100GB 行存 → 列存(~5-15x 压缩) → ~7-20GB
```

### 9.3 列存代价

| 代价 | 描述 |
|------|------|
| **写入慢** | 列存不可变,频繁更新要重写整个 chunk |
| **小查询慢** | 单行查询要读所有列的 chunk 头 |
| **不适合事务** | 高并发更新 + 列存 = 不兼容 |

---

## 10. 与 v2 主线的连接

### 10.1 与 Storage Engine(接 #34)

```
行存 SSTable: row-encoded micro_block
列存 SSTable: column-encoded micro_block
              ↑
          本文的列存编码 + 压缩
```

### 10.2 与 Compaction(接 #20)

```
列存的 compact:
  - 不能简单合并(列独立编码)
  - 需要解码 → 重编码 → 重压缩
  - 代价: 比行存 compact 慢 2-5x
```

### 10.3 与 CBO(接 #17)

```
行存 CBO: 估 IO cost
列存 CBO: 估 IO cost - 压缩 + 向量化加速
        + 列裁剪/谓词下推优化
```

### 10.4 与 Trans Service(接 #11)

```
行存: 频繁更新友好
列存: 频繁更新不友好
  → 列存表很少做高频 DML
  → OLAP 场景: 批量加载(LOAD DATA / INSERT BATCH)
```

---

## 11. 调优 Checklist

```
□ 哪些表适合列存?(聚合 / 大表 / 时间序列)
□ 压缩算法是否合适?(ZSTD 平衡, LZ4 快)
□ 编码是否生效?(看 column_chunk_meta)
□ 向量化 batch size 是否合适?(默认 1024)
□ 谓词下推是否生效?(EXPLAIN 看)
□ 列裁剪是否生效?(EXPLAIN 看 Operator 读的列)
□ 物化视图是否用上?(EXPLAIN 看 mview scan)
□ HTAP 路由是否正确?(OLTP 走 primary, OLAP 走 columnar)
□ 列存 compact 是否影响业务?(限速 + 避开高峰)
□ OLAP query 是否走 Standby?(避免打 Primary)
```

---

## 12. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → #28 v2 → #19 
v2 → #20 v2 → #27 v2 → #30 v2 → #31 v2 → #34 v2 → #35 v2 → **#36 v2 (本文)**
是 OB **storage / index / CBO / join / cache / 调优 / 日志 / 事务 / schema 
/ 并行 / HA / 容灾 / 多租户 / parser / compaction / RPC / 监控 / 分区 / 
SQL 引擎 / 列存 OLAP** 全主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObKeyBTree | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| #29 v2 | Slow Query | 运维层 | 捕获 + 分析 + 推荐 + 调优 |
| #22 v2 | Clog / Redo Log | 持久化层 | WAL + group commit + replica + recovery |
| #11 v2 | Trans Service / Lock | 事务层 | 全局事务 ID + 行锁 + 2PC + 死锁 + SI |
| #21 v2 | Schema / DDL | 元数据层 | schema_version + INSTANT/INPLACE + Online DDL |
| #24 v2 | PX Framework | 并行层 | Worker Pool + Task 调度 + Data Exchange + DAS |
| #26 v2 | Primary / Standby | HA 层 | Paxos + 选主 + failover + 副本同步 |
| #33 v2 | Backup / Recovery | 容灾层 | 全量+增量+archive log + PIT + 容灾策略 |
| #28 v2 | Resource / Unit / Tenant | 多租户层 | 3 层模型 + 隔离机制 + 资源调度 |
| #19 v2 | SQL Parser | 前端层 | Lexer + Parser + Resolver + Type Check + Fingerprint |
| #20 v2 | Compaction Strategy | 存储维护层 | Minor Freeze + Major Freeze + History Merge |
| #27 v2 | RPC / obrpc | 网络层 | 序列化 + 路由 + 重试 + epoll/io_uring |
| #30 v2 | Monitoring / Alerting | 可观测层 | Metrics + ASH + Alert + Dashboard |
| #31 v2 | Partition Management | 数据分布层 | Rebalance + Migration + 副本切换 |
| #34 v2 | Storage Engine Internals | 磁盘存储层 | SSTable / Macro Block / Micro Block + 压缩/加密/checksum |
| #35 v2 | SQL Engine Entry | 前端入口层 | Connection + Tenant + Pipeline + Resource |
| **#36 v2 (本文)** | **Columnar Storage / OLAP** | **分析查询层** | **列存编码 + 向量化 + OLAP CBO + HTAP** |

二十三篇连起来,读者能完整理解 OB 的"OLTP + OLAP + HTAP"全链路:

- OLTP:#14-#18 (storage/index/optimizer)
- OLAP:#36 (本文:列存 + 向量化)
- HTAP:#36 (本文:HTAP 集成)
- 执行:#41 (Join) + #24 (PX) + #36 (本文:向量化)
- 存储:#14-#16 (MemTable) + #34 (行存) + #36 (本文:列存) + #51 (Cache)
- 持久化:#22 (Clog) + #20 (Compaction)
- 事务:#11 (Trans Service)
- 元数据:#21 (Schema)
- 多租户:#28 (Tenant)
- HA + DR:#26 + #33
- 网络:#27 (RPC)
- 运维:#29 (Slow Query) + #30 (Monitoring)
- 分区:#31 (Partition Mgmt)
- SQL 入口:#35 (SqlService)

---

## 13. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **源码深挖** — 选具体源文件做完整 review（如 `ob_columnar_writer.cpp`）
- **#37-#100 系列**（待确认具体编号）
- **继续 OB 主线** — 其他子系统

继续哪一篇?

---

## 14. 参考(可执行的源码锚点)

- `src/storage/columnar/ob_column_chunk.h` — Column Chunk 定义
- `src/storage/columnar/ob_dict_encoding.cpp` — 字典编码
- `src/storage/columnar/ob_rle_encoder.cpp` — RLE 编码
- `src/storage/columnar/ob_delta_encoder.cpp` — Delta 编码
- `src/storage/columnar/ob_bit_packed_encoder.cpp` — Bit-packed
- `src/storage/columnar/ob_encoding_picker.cpp` — 自动编码选择
- `src/storage/columnar/ob_column_compressor.cpp` — 列级压缩
- `src/storage/columnar/ob_columnar_writer.cpp` — 列存 SSTable 写
- `src/storage/columnar/ob_columnar_reader.cpp` — 列存 SSTable 读
- `src/sql/engine/ob_vector_batch.h` — 向量化批
- `src/sql/engine/ob_vector_scan_op.cpp` — 向量化 scan
- `src/sql/engine/ob_vector_agg_op.cpp` — 向量化聚合
- `src/sql/optimizer/ob_olap_cost_model.cpp` — OLAP CBO
- `src/share/schema/ob_mview_schema.h` — 物化视图 schema
- `src/sql/optimizer/ob_mview_rewrite.cpp` — MView 改写
- `src/storage/htap/ob_htap_router.cpp` — HTAP 路由

---

#36 v2 完。
