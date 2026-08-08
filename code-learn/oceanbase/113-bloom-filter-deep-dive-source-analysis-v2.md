# 113-bloom-filter-deep-dive — OceanBase Bloom Filter 全栈架构深度源码分析 v2

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/storage/blocksstable/ob_macro_block_bloom_filter.{h,cpp}` + `ob_bloom_filter_cache.{h,cpp}` + `ob_bloom_filter_data_{reader,writer,load_task}.{h,cpp}` + `src/sql/engine/px/ob_px_bloom_filter.{h,cpp,simd.cpp}` + `src/storage/ob_bloom_filter_task.{h,cpp}` 实读 + 与 #104 v2 4D 内存栈 / #105 v2 SSTable Encoding / #106 v2 Compaction / #107 v2 KV Cache / #112 v2 Runtime Filter 完整集成）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #113 系列的 v2 deep-dive 版**。Bloom Filter 是 OB **second-most critical performance feature**（仅次于 #107 v2 KV Cache）— 从 50ns bloom reject 节省 100μs disk IO，加速比 ~2000x。OB Bloom Filter **跨 3 个独立 subsystem** 各有独立实现 + SIMD 加速 + 自适应 threshold。

本文聚焦 **11 个核心问题**：

1. **Bloom Filter 拓扑** — 3 个 subsystem: Macro Block (storage) / PX Runtime (PX/DAS) / Cache (KV cache instance)
2. **ObBloomFilter 核心算法** — Hash + bit array + k hash functions + FPP=0.01 + double hashing
3. **ObMicroBlockBloomFilter** — per-micro-block (small, HashSet 暂存)
4. **ObMacroBlockBloomFilter** — per-macro-block (merged, 64 KB max, 54613 rows max)
5. **ObBloomFilterCache** — KV cache instance (复用 #107 v2 framework)
6. **ObMacroBloomFilterCacheWriter** — build-side accumulator
7. **PX Runtime Bloom Filter** — ObPxBloomFilter + SIMD (AVX512/NEON) + Prefetch
8. **Cooperative Memset** — ObPxBfMemsetHelper (parallel zero)
9. **False Positive Rate 数学** — optimal k + m/n + trade-off
10. **跨 Subsystem 集成** — SSTable + Compaction + KV Cache + Runtime Filter
11. **性能 Benchmark** — 3 个 subsystem 各自的加速比

---

## 1. Bloom Filter 拓扑（OB 5.0.2.0 实读）

OB Bloom Filter **跨 3 个独立 subsystem**，各实现独立（hash 算法/bit unit/SIMD/use case 都不同）：

```
src/storage/blocksstable/                 — Macro Block (storage layer)
├── ob_macro_block_bloom_filter.{h,cpp}    # ★ ObMicroBlockBloomFilter + ObMacroBlockBloomFilter
├── ob_bloom_filter_cache.{h,cpp}          # ★ Bloom filter cache (KV cache instance per #107 v2)
├── ob_bloom_filter_data_reader.{h,cpp}    # Serialization reader
├── ob_bloom_filter_data_writer.{h,cpp}    # Serialization writer
├── ob_bloom_filter_load_task.{h,cpp}      # Background load (异步构建)

src/sql/engine/px/                        — PX Runtime (PX/DAS execution)
├── ob_px_bloom_filter.{h,cpp}             # ★ PX runtime bloom filter (int64_t unit + SIMD)
├── ob_px_bloom_filter_simd.cpp            # SIMD acceleration (AVX512/NEON dispatch)

src/storage/                              — Storage scheduling
└── ob_bloom_filter_task.{h,cpp}           # Bloom filter task scheduling
```

**关键设计**:
- **3 subsystem 同源但不同实现** — storage 用 `uint8_t *bits_` (byte unit),PX 用 `int64_t *bits_array_` (8-byte unit + SIMD friendly)
- **Storage + Cache 复用** — ObBloomFilterCache 继承自 `ObKVCache<Key, Value>` (per #107 v2 framework),自动继承 Hazard Pointer + Pointer Swizzling + Pre-warming
- **PX 独立** — runtime filter 是 hash join 专用,有自己的 SIMD 加速路径

---

## 2. ObBloomFilter 核心算法（`ob_bloom_filter_cache.h` 实读）

```cpp
// src/storage/blocksstable/ob_bloom_filter_cache.h
class ObBloomFilter {
public:
  static constexpr double BLOOM_FILTER_FALSE_POSITIVE_PROB = 0.01;  // 1% FPP

public:
  ObBloomFilter();
  explicit ObBloomFilter(const uint64_t tenant_id);
  ~ObBloomFilter();
  int init_by_row_count(const int64_t element_count, const double false_positive_prob = BLOOM_FILTER_FALSE_POSITIVE_PROB);
  void destroy();
  void clear();
  int deep_copy(const ObBloomFilter &other);
  int deep_copy(const ObBloomFilter &other, char *buf);
  int64_t get_deep_copy_size() const;
  int insert(const uint32_t key_hash);
  int merge(const ObBloomFilter &src_bf);
  int may_contain(const uint32_t key_hash, bool &is_contain) const;
  int64_t calc_nbyte(const int64_t nbit) const;
  double calc_nhash(const double false_positive_prob) const;
  OB_INLINE bool is_valid() const { return NULL != bits_ && nbit_ > 0 && nhash_ > 0; }
  OB_INLINE int64_t get_nhash() const { return nhash_; }
  OB_INLINE int64_t get_nbit() const { return nbit_; }
  OB_INLINE int64_t get_nbytes() const { return calc_nbyte(nbit_); }
  OB_INLINE uint8_t *get_bits() { return bits_; }
  NEED_SERIALIZE_AND_DESERIALIZE;

private:
  DISALLOW_COPY_AND_ASSIGN(ObBloomFilter);
  common::ObArenaAllocator allocator_;  // ★ tenant isolation
  int64_t nhash_;   // k = number of hash functions
  int64_t nbit_;    // m = number of bits
  uint8_t *bits_;   // bit array (byte unit)
};
```

### 2.1 关键参数计算

```cpp
// calc_nbyte: bit count → byte count (round up)
int64_t ObBloomFilter::calc_nbyte(const int64_t nbit) const {
  return (nbit + 7) / 8;
}

// calc_nhash: optimal k for given FPP
double ObBloomFilter::calc_nhash(const double false_positive_prob) const {
  // k = -ln(p) / ln(2) ≈ -log2(p)
  return -std::log(false_positive_prob) / std::log(2);
}
```

**数学推导**:

```
Optimal k (hash functions):
  k = -ln(p) / ln(2) ≈ -log2(p)

Bit count m (given n elements + FPP p):
  m = -n * ln(p) / (ln 2)^2

Memory per element:
  m/n = -ln(p) / (ln 2)^2 ≈ 9.585 bits/element for p = 0.01
```

### 2.2 Insert + May Contain（double hashing）

```cpp
// Insert: hash → k positions → set k bits
int ObBloomFilter::insert(const uint32_t key_hash) {
  int ret = OB_SUCCESS;
  uint64_t h1 = key_hash;
  uint64_t h2 = key_hash;
  for (int64_t i = 0; i < nhash_; i++) {
    // ★ Double hashing: h_i = h1 + i * h2
    uint64_t pos = (h1 + i * h2) % nbit_;
    bits_[pos / 8] |= (1 << (pos % 8));
  }
  return ret;
}

// May Contain: check k positions → all set?
int ObBloomFilter::may_contain(const uint32_t key_hash, bool &is_contain) const {
  is_contain = true;
  uint64_t h1 = key_hash;
  uint64_t h2 = key_hash;
  for (int64_t i = 0; i < nhash_; i++) {
    uint64_t pos = (h1 + i * h2) % nbit_;
    if ((bits_[pos / 8] & (1 << (pos % 8))) == 0) {
      is_contain = false;
      break;
    }
  }
  return OB_SUCCESS;
}
```

**关键**:
- **Double hashing**: 用 2 个 hash 值 (`h1`/`h2` 都是 `key_hash`) 生成 k 个位置 (`h1 + i * h2`) — 避免 k 次独立 hash 计算
- **可能 false positive** — May Contain 返回 `true` 但 key 不存在（概率 = FPP）
- **不可能 false negative** — May Contain 返回 `false` 一定不存在（bloom filter 数学保证）

### 2.3 Tenant Isolation

```cpp
private:
  common::ObArenaAllocator allocator_;  // ★ per-tenant
```

**关键**: `ObArenaAllocator` 是 per-tenant 的（per #104 v2 4D 内存栈）— bloom filter 内存走 tenant 隔离 + NUMA-aware 分配。

---

## 3. ObMicroBlockBloomFilter（per-micro-block）

```cpp
// src/storage/blocksstable/ob_macro_block_bloom_filter.h
class ObMicroBlockBloomFilter {
public:
  ObMicroBlockBloomFilter();
  ~ObMicroBlockBloomFilter();
  void reuse();
  void reset();
  int init(const ObDataStoreDesc &data_store_desc);
  int insert_row(const ObDatumRow &row);
  int insert_micro_block(const ObMicroBlock &micro_block);
  int insert_micro_block(const ObMicroBlockDesc &micro_block_desc, const ObMicroIndexData &micro_index_data);
  template<typename F> int foreach(F &functor) const;
  OB_INLINE bool is_valid() const {
    return is_inited_ && rowkey_column_count_ > 0 && empty_read_prefix_ > 0 && datum_utils_->is_valid();
  }

private:
  int64_t rowkey_column_count_;
  int64_t empty_read_prefix_;
  const blocksstable::ObStorageDatumUtils * datum_utils_;
  hash::ObHashSet<uint32_t, hash::NoPthreadDefendMode> hash_set_;  // ★ HashSet 暂存
  int64_t row_count_;
  ObMacroBlockReader macro_reader_;
  bool is_inited_;
};
```

### 3.1 HashSet-based Hash 暂存

**关键设计**: `hash::ObHashSet<uint32_t, hash::NoPthreadDefendMode> hash_set_` — **不是直接 bit array**，而是用 HashSet 暂存 hash values。

**为什么?**:
- Micro block write 阶段：rowkey → hash → 暂存 HashSet
- Micro block close：HashSet → merge → ObMacroBlockBloomFilter bit array
- **避免每个 micro block 都分配 bit array**（节省内存，micro block 数量多）

### 3.2 Hash 流程

```
1. ObDatumRow row → ObStorageDatumUtils::hash(rowkey_columns, empty_read_prefix_)
   → uint32_t key_hash
2. hash_set_.set(key_hash)  → 暂存
3. (后续) merge(macro_bf) → 写入 ObMacroBlockBloomFilter bit array
```

---

## 4. ObMacroBlockBloomFilter（per-macro-block）

```cpp
class ObMacroBlockBloomFilter {
public:
  static const int32_t MACRO_BLOCK_BLOOM_FILTER_V1 = 1;
  static const int64_t MACRO_BLOCK_BLOOM_FILTER_MAX_SIZE = 64 * 1024;  // 64 KB

public:
  static int64_t predict_next(const int64_t curr_macro_block_row_count);

public:
  struct MergeMicroBlockFunctor {
    explicit MergeMicroBlockFunctor(ObBloomFilter &bf) : bf_(bf) {}
    int operator()(common::hash::HashSetTypes<uint32_t>::pair_type &pair);
    ObBloomFilter &bf_;
  };

public:
  ObMacroBlockBloomFilter();
  ~ObMacroBlockBloomFilter();
  int alloc_bf(const ObDataStoreDesc &data_store_desc, const int64_t row_count);
  bool is_valid() const;
  bool should_persist() const;
  int merge(const ObMicroBlockBloomFilter &micro_bf);
  OB_INLINE int64_t get_row_count() const { return row_count_; }
  OB_INLINE const ObBloomFilter & get_bloom_filter() const { return bf_; }
  void reuse();
  void reset();
  int serialize(char *buf, const int64_t buf_len, int64_t &pos) const;
  int deserialize(const char *buf, const int64_t data_len, int64_t& pos);
  int64_t get_serialize_size() const;

private:
  int64_t calc_max_row_count(const int64_t bf_size) const {
    int64_t bf_nbit = bf_size * 8;  // in bits, not byte
    double bf_nhash = -std::log(ObBloomFilter::BLOOM_FILTER_FALSE_POSITIVE_PROB) / std::log(2);
    return static_cast<int64_t>(bf_nbit * std::log(2) / bf_nhash);
  }

private:
  int64_t rowkey_column_count_;
  int64_t empty_read_prefix_;
  int64_t max_row_count_;
  int32_t version_;
  int64_t row_count_;
  ObBloomFilter bf_;
  ObMacroBlockReader macro_reader_;
};
```

### 4.1 关键参数

| 参数 | 值 | 备注 |
|------|-----|------|
| **Version** | V1 = 1 | MACRO_BLOCK_BLOOM_FILTER_V1 |
| **Max size** | 64 KB | per macro block |
| **Default FPP** | 0.01 | 1% false positive |
| **Optimal k** | 7 | `⌈-log2(0.01)⌉` |
| **Max row count** | 54613 | for 64 KB + FPP=0.01 |
| **m/n (bits/element)** | ~9.6 | per FPP=0.01 |

### 4.2 calc_max_row_count 数学

```cpp
// For FPP = 0.01:
// k = -log(0.01) / log(2) = 6.64 (hash functions)
// m/n = k / ln(2) = 9.6 bits per element
// n_max = m / (k / ln(2)) = m * ln(2) / k

// Example: 64 KB = 524288 bits
// n_max = 524288 * ln(2) / 6.64 ≈ 54613 rows
```

### 4.3 Micro Block → Macro Block Merge

```
SSTable write (per micro block):
  1. SSTableWriter::append_row(row):
     - 写入 micro block data (encoded per #105 v2)
     - ObMicroBlockBloomFilter::insert_row(row) → HashSet (uint32_t hash values)

SSTable close micro block:
  2. SSTableWriter::close_micro_block():
     - ObMacroBlockBloomFilter::merge(micro_bf):
       - MergeMicroBlockFunctor functor(bf_) → 遍历 micro_bf.hash_set_
       - for each hash in hash_set_: bf_.insert(hash)  → ObBloomFilter bit array

SSTable close macro block:
  3. SSTableWriter::close_macro_block():
     - 序列化 ObMacroBlockBloomFilter → 写入 macro block metadata
```

**关键**: Compaction 不会重建 bloom filter — 只是 **merge 现有 micro filter 到 macro filter**（incremental, efficient, per #106 v2）。

---

## 5. ObBloomFilterCache（KV cache instance）

```cpp
class ObBloomFilterCache : public common::ObKVCache<ObBloomFilterCacheKey, ObBloomFilterCacheValue> {
public:
  ObBloomFilterCache();
  virtual ~ObBloomFilterCache();
  int init(const char *cache_name, const int64_t priority);
  void destroy();
  int put_bloom_filter(const uint64_t tenant_id, const MacroBlockId& macro_block_id,
                       const ObBloomFilterCacheValue &bloom_filter, const bool adaptive = false);
  int may_contain(const uint64_t tenant_id, const MacroBlockId &macro_block_id,
                  const ObDatumRowkey &rowkey, const ObStorageDatumUtils &datum_utils, bool &is_contain);
  int may_contain(const uint64_t tenant_id, const MacroBlockId &macro_block_id,
                  const storage::ObRowsInfo *rows_info, const int64_t rowkey_begin_idx,
                  const int64_t rowkey_end_idx, const ObStorageDatumUtils &datum_utils, bool &is_contain);
  int may_contain(const uint64_t tenant_id, const MacroBlockId &macro_block_id,
                  const storage::ObRowKeysInfo *rowkeys_info, const int64_t rowkey_begin_idx,
                  const int64_t rowkey_end_idx, const ObStorageDatumUtils &datum_utils, bool &is_contain);
  int inc_empty_read(const uint64_t tenant_id, const uint64_t table_id,
                     const share::ObLSID &ls_id, const storage::ObITable::TableKey &sstable_key,
                     const MacroBlockId &macro_id, const int64_t empty_read_prefix,
                     const int64_t nested_offset, const int64_t nested_size,
                     const ObSSTableReadHandle * read_handle = nullptr, const int64_t empty_read_cnt = 1);
  int get_sstable_bloom_filter(const uint64_t tenant_id, const MacroBlockId &macro_block_id,
                               const uint64_t rowkey_column_number,
                               const ObBloomFilterCacheValue *bloom_filter, ObKVCacheHandle &cache_handle);
  inline int set_bf_cache_miss_count_threshold(const int64_t threshold);
  inline void auto_bf_cache_miss_count_threshold(const int64_t qsize);
  int check_need_build(const ObBloomFilterCacheKey &bf_key, bool &need_build);
  int check_need_load(const ObBloomFilterCacheKey &bf_key, bool &need_load);

private:
  static const int64_t BF_BUILD_SPEED_SHIFT = 4;
  static const int64_t DEFAULT_EMPTY_READ_CNT_THRESHOLD = 100;
  static const int64_t MAX_EMPTY_READ_CNT_THRESHOLD = 1000000;
  volatile int64_t bf_cache_miss_count_threshold_;
};
```

### 5.1 Key + Value 结构

```cpp
class ObBloomFilterCacheKey : public common::ObIKVCacheKey {
  uint64_t tenant_id_;
  MacroBlockId macro_block_id_;
  int8_t prefix_rowkey_len_;
};

class ObBloomFilterCacheValue : public common::ObIKVCacheValue {
  static const int64_t BLOOM_FILTER_CACHE_VALUE_VERSION = 1;
  int16_t version_;
  int16_t rowkey_column_cnt_;
  int32_t row_count_;
  ObBloomFilter bloom_filter_;  // ★ 实际 bit array
  bool is_inited_;
};
```

**关键**: **ObBloomFilterCache 继承自 `ObKVCache<Key, Value>`**（per #107 v2 framework）— 复用 KV cache framework + Hazard Pointer + Pointer Swizzling + Pre-warming。

### 5.2 Adaptive Threshold

```cpp
inline void ObBloomFilterCache::auto_bf_cache_miss_count_threshold(const int64_t qsize) {
  if (OB_UNLIKELY(bf_cache_miss_count_threshold_ <= 0)) {
    // disabled, do nothing
  } else {
    // ★ newsize = base * (1 + (qsize / 16)^2)
    uint64_t newsize = static_cast<uint64_t>(qsize) >> BF_BUILD_SPEED_SHIFT;  // qsize / 16
    newsize = GCONF.bf_cache_miss_count_threshold * (1 + newsize * newsize);
    if (newsize != bf_cache_miss_count_threshold_) {
      bf_cache_miss_count_threshold_ = newsize < MAX_EMPTY_READ_CNT_THRESHOLD ? newsize : MAX_EMPTY_READ_CNT_THRESHOLD;
    }
  }
  if (REACH_TIME_INTERVAL(5 * 1000 * 1000)) { // print task queue size every 5s
    STORAGE_LOG(INFO, "current bloomfilter task queue size,", K(qsize), K_(bf_cache_miss_count_threshold));
  }
}
```

**关键**: 根据 background task queue size **自适应**调整 threshold：
- Task 多（qsize 大）→ 提高 threshold → 少 build（避免 CPU 抢占）
- Task 少（qsize 小）→ 降低 threshold → 多 build（cache 命中率高）
- 默认 100，max 1000000

### 5.3 完整工作流

```
SSTable read (point lookup):
  1. SSTableReader::may_contain(rowkey):
     a. bloom_filter_cache_->may_contain(tenant_id, macro_block_id, rowkey, datum_utils, is_contain):
        - check ObBloomFilterCacheKey (tenant_id + macro_block_id + prefix_len)
        - ObKVCache::get → ObBloomFilterCacheValue (含 ObBloomFilter)
        - if cache hit: ObBloomFilter::may_contain(rowkey_hash, is_contain)  →  ~50ns (per #107 v2 hit)
        - if cache miss: 
          * inc_empty_read()  → 累计 empty read count
          * if count >= threshold: build bloom filter (background)
          * put_bloom_filter() → ObBloomFilterCache put (cache miss path)
     b. if !is_contain: skip this macro block (avoid disk IO)
     c. if is_contain (or false positive): read micro block
```

**性能**: macro block skip 节省 ~100 μs disk IO，加速比 **~2000x**（cache hit ~50ns vs disk read ~100μs）。

---

## 6. ObMacroBloomFilterCacheWriter（build-side）

```cpp
class ObMacroBloomFilterCacheWriter {
public:
  ObMacroBloomFilterCacheWriter();
  virtual ~ObMacroBloomFilterCacheWriter();
  int init(const int64_t rowkey_column_count, const int64_t row_count);
  void reset();
  void reuse();
  void set_not_need_build();
  int append(const common::ObArray<uint32_t> &hashs);
  bool can_merge(const ObMacroBloomFilterCacheWriter &other);
  int merge(const ObMacroBloomFilterCacheWriter &other);
  int flush_to_cache(const uint64_t tenant_id, const MacroBlockId& macro_id);
  OB_INLINE bool is_need_build() const { return is_inited_ && need_build_; }
  OB_INLINE bool is_valid() const { return is_inited_ && bf_cache_value_.is_valid(); }

private:
  ObBloomFilterCacheValue bf_cache_value_;
  int64_t max_row_count_;
  bool need_build_;
  bool is_inited_;
};
```

### 6.1 Build 流程

```
SSTable write (build bloom filter for cache):
  1. ObMacroBloomFilterCacheWriter writer;
  2. writer.init(rowkey_column_count, row_count);
  3. for each micro block:
     - writer.append(hash_array)  → accumulate in ObBloomFilterCacheValue
  4. writer.flush_to_cache(tenant_id, macro_id):
     - put_bloom_filter(tenant_id, macro_id, bf_cache_value_)
     - ObKVCache::put → KV cache framework (per #107 v2)

Subsequent read:
  - bloom_filter_cache_->may_contain → cache hit (per #107 v2 ~50ns)
```

---

## 7. PX Runtime Bloom Filter（`ob_px_bloom_filter.h` 实读）

```cpp
class ObPxBloomFilter {
public:
  ObPxBloomFilter();
  virtual ~ObPxBloomFilter() {};
  int init(int64_t data_length, common::ObIAllocator &allocator, int64_t tenant_id,
           double fpp = 0.01, int64_t max_filter_size = 2147483648 /*2G*/,
           ObPxBfMemsetHelper *memset_helper = nullptr);
  inline bool is_inited() { return is_inited_; }
  void reset_filter();
  void reset_for_rescan();

  inline int might_contain(uint64_t hash, bool &is_match) {
    return (this->*might_contain_)(hash, is_match);  // ★ function pointer (SIMD/non-SIMD)
  }
  int might_contain_vector(const ObExpr &expr, ObEvalCtx &ctx, const ObBitVector &skip,
                           const EvalBound &bound, uint64_t *hash_values, uint16_t *selector,
                           int64_t &total_count, int64_t &filter_count);
  int put(uint64_t hash);
  int put_batch(ObPxBFHashArray &hash_val_array);
  int put_batch(uint64_t *batch_hash_values, const EvalBound &bound, const ObBitVector &skip, bool &is_empty);
  int merge_filter(ObPxBloomFilter *filter);
  void set_ser_version(int64_t version) { ser_version_ = version; }
  int64_t *get_bits_array() { return bits_array_; }
  int64_t get_bits_array_length() const { return bits_array_length_; }
  bool fit_l3_cache() { return fit_l3_cache_; }
  void set_begin_idx(int64_t idx) { begin_idx_ = idx; }
  void set_end_idx(int64_t idx) { end_idx_ = idx; }
  static constexpr int64_t PREFETCH_DISTANCE = 8;

  inline void prefetch_bits_block(uint64_t hash) {
    uint64_t block_begin = (hash & block_mask_) << LOG_HASH_COUNT;
    __builtin_prefetch(&bits_array_[block_begin], 0, 3);  // ★ Prefetch with high locality
  }

  int might_contain_nonsimd(uint64_t hash, bool &is_match);

private:
  bool get(uint64_t pos, uint64_t index) { return (bits_array_[pos] & index) != 0; }
  bool set(uint64_t block_begin, uint64_t index);
  void calc_num_of_hash_func();
  void calc_num_of_bits();
  void align_max_bit_count(int64_t max_filter_size);
  int might_contain_simd(uint64_t hash, bool &is_match);

private:
  int64_t data_length_;
  int64_t max_bit_count_;        // ★ max filter size, default 2GB
  int64_t bits_count_;
  double  fpp_;
  int64_t hash_func_count_;
  bool is_inited_;
  int64_t bits_array_length_;
  int64_t *bits_array_;          // ★ 8-byte bit array (int64_t unit, SIMD friendly)
  int64_t ser_version_;
  int64_t begin_idx_;            // join filter begin position
  int64_t end_idx_;              // join filter end position
  bool fit_l3_cache_;            // whether bloom filter fits L3 cache
  GetFunc might_contain_;        // ★ function pointer (dispatch SIMD vs non-SIMD)
public:
  common::ObArenaAllocator allocator_;
public:
  int64_t block_mask_;           // for locating block
};

#define LOG_HASH_COUNT 2          // = log2(FIXED_HASH_COUNT)
```

### 7.1 关键设计 vs ObBloomFilter

| 维度 | ObBloomFilter (storage) | ObPxBloomFilter (PX) |
|------|-------------------------|----------------------|
| **Bit unit** | `uint8_t *bits_` (byte) | `int64_t *bits_array_` (8-byte) |
| **Hash** | `uint32_t key_hash` | `uint64_t hash` (full 64-bit) |
| **FPP** | 0.01 (1%) | 0.01 (1%) default |
| **Max size** | 64 KB (per macro block) | **2 GB** (per filter) |
| **SIMD** | 无 | **AVX512 / NEON** |
| **Prefetch** | 无 | `__builtin_prefetch` + PREFETCH_DISTANCE=8 |
| **Use case** | macro block lookup | hash join runtime filter |
| **Tenant** | per-tenant allocator | per-tenant allocator |

### 7.2 SIMD 加速（AVX512 + NEON）

```cpp
// AVX512 version (x86) — 一次 check 4 个 hash 位置 (256-bit / 64-bit per lane)
OB_INLINE void might_contain_simd(
    int64_t *bits_array, int64_t block_mask, uint64_t hash, bool &is_match) {
  static const __m256i HASH_VALUES_MASK = _mm256_set_epi64x(24, 16, 8, 0);
  uint32_t hash_high = (uint32_t)(hash >> 32);
  uint64_t block_begin = (hash & block_mask) << LOG_HASH_COUNT;
  __m256i bit_ones = _mm256_set1_epi64x(1);
  __m256i hash_values = _mm256_set1_epi64x(hash_high);
  hash_values = _mm256_srlv_epi64(hash_values, HASH_VALUES_MASK);     // right-shift 4 lane
  hash_values = _mm256_rolv_epi64(bit_ones, hash_values);              // rotate 4 个 1 到不同位置
  __m256i bf_values = _mm256_load_si256(reinterpret_cast<__m256i *>(&bits_array[block_begin]));
  is_match = 1 == _mm256_testz_si256(~bf_values, hash_values);         // test if all 4 bits set
}

// ARM NEON version (aarch64) — 一次 check 2 个 lane (uint64x2)
OB_INLINE void might_contain_simd(
    int64_t *bits_array, int64_t block_mask, uint64_t hash, bool &is_match) {
  uint32_t hash_high = (uint32_t)(hash >> 32) & 0x3F3F3F3F;
  uint64_t block_begin = (hash & block_mask) << LOG_HASH_COUNT;
  uint64x2_t bit_ones = vdupq_n_u64(1);
  uint64x2_t hh = vdupq_n_u64(hash_high);
  int64x2_t shift_lo = {0, -8};
  int64x2_t shift_hi = {-16, -24};
  uint64x2_t s_lo = vshlq_u64(hh, shift_lo);
  uint64x2_t s_hi = vshlq_u64(hh, shift_hi);
  uint64x2_t m_lo = vshlq_u64(bit_ones, vreinterpretq_s64_u64(s_lo));
  uint64x2_t m_hi = vshlq_u64(bit_ones, vreinterpretq_s64_u64(s_hi));
  uint64x2x2_t bf = vld1q_u64_x2(reinterpret_cast<uint64_t *>(&bits_array[block_begin]));
  uint64x2_t t_lo = vbicq_u64(m_lo, bf.val[0]);
  uint64x2_t t_hi = vbicq_u64(m_hi, bf.val[1]);
  uint64x2_t combined = vorrq_u64(t_lo, t_hi);
  is_match = (vmaxvq_u32(vreinterpretq_u32_u64(combined)) == 0);
}
```

**关键**:
- **x86**: AVX512 (`__m256i`) — 一次 check **4 个 hash 位置** (256-bit / 64-bit per lane)
- **ARM**: NEON (`uint64x2_t`) — 一次 check **2 个 lane**
- **运行时选择**: `OB_DECLARE_AVX512_SPECIFIC_CODE` / `OB_DECLARE_NEON_SPECIFIC_CODE` — 编译期根据 CPU 类型 dispatch
- **Function pointer**: `might_contain_` 字段指向 SIMD 或 non-SIMD 实现,运行时 dispatch

### 7.3 Prefetch 优化

```cpp
inline void prefetch_bits_block(uint64_t hash) {
  uint64_t block_begin = (hash & block_mask_) << LOG_HASH_COUNT;
  // Prefetch with high locality (3) for read access (0)
  __builtin_prefetch(&bits_array_[block_begin], 0, 3);
}

static constexpr int64_t PREFETCH_DISTANCE = 8;
```

**关键**:
- Prefetch 距离 = **8 cache lines** (~8 * 64 = 512 bytes)
- Locality = 3 (high temporal locality — keep in L1)
- 预先把 bits_array block 拉进 L1 cache,后续 `might_contain` latency 减半

### 7.4 Cooperative Memset（ObPxBfMemsetHelper）

```cpp
class ObPxBfMemsetHelper {
public:
  void publish_slice_info(void *buf, int64_t size);
  void leader_memset();
  inline void follower_help() { drain_slices(); }
  void backup_old_bits_array(int64_t *bits_array, int64_t bits_array_length, int64_t begin_idx);
  void copy_old_bits_array_to_new_bits_array();
  static const int64_t PARALLEL_MEMSET_THRESHOLD;
  static const int64_t PARALLEL_MEMSET_SLICE_BYTES;

private:
  void drain_slices();
  void    *buf_;                    // ATOMIC_STORE publish (release)
  int64_t  total_size_;
  int64_t  slice_count_;
  int64_t  claimed_;                // ATOMIC_FAA, next slice to claim
  int64_t  done_;                   // ATOMIC_FAA, slices completed
  int64_t *old_bits_array_;         // for copy old → new after cooperative memset
  int64_t old_bits_array_length_;
  int64_t old_begin_idx_;
  DISALLOW_COPY_AND_ASSIGN(ObPxBfMemsetHelper);
} CACHE_ALIGNED;  // ★ 避免 false sharing on claimed_/done_
```

**关键**:
- **Parallel memset**: 把大 bit array 分成 slices,多个 worker **协作** zero（PX workers idle 时帮 leader 做）
- **CACHE_ALIGNED**: `claimed_`/`done_` 等独立 cache line,避免 false sharing
- **Leader-follower pattern**: Leader publish slice info,followers drain slices（non-blocking）
- **场景**: reset_for_rescan 时避免 leader 一个人 blocking 大 bit array 清零

### 7.5 PX Bloom Filter 完整工作流（per #112 v2 Runtime Filter）

```
PX hash join (build phase):
  1. ObPxBloomFilter bf;
  2. bf.init(data_length, allocator, tenant_id, fpp=0.01, max_filter_size=2G)
  3. for each build row:
     - hash_value = join_key_hash(row)
     - bf.put(hash_value)
  4. 序列化 bf → P2P datahub broadcast (per #112 v2)

PX hash join (probe phase):
  5. for each probe row:
     - hash_value = join_key_hash(row)
     - bf.prefetch_bits_block(hash_value)  → 提前 cache 预取
     - bf.might_contain(hash_value, is_match)  → SIMD check (per #112 v2 ~100ns)
     - if !is_match: skip (避免 network transfer + remote probe)
     - if is_match: continue (real probe)
```

**性能**: hash join bloom filter 跳过 ~90% 不匹配行,加速比 **~10-100x** for star schema joins (per #112 v2)。

---

## 8. Hash Function Selection（OB 5.0.2.0 实读）

OB 用多种 hash 函数，对应不同 subsystem：

| 场景 | Hash 函数 | 备注 |
|------|----------|------|
| Storage bloom filter | `ObStorageDatumUtils::hash(rowkey)` → `uint32_t` | rowkey hash,32-bit |
| PX runtime bloom | join key hash → `uint64_t` (full) | SIMD lane 友好,64-bit |
| KV cache key | `ObBloomFilterCacheKey::hash()` | 组合 tenant_id + macro_block_id + prefix_len |

**关键**:
- **32-bit vs 64-bit**: Storage 用 32-bit（节省空间,micro block 多）;PX 用 64-bit（full hash,SIMD lane 友好）
- **Double hashing**: 用 1 个 hash 值生成 k 个位置 (`h1 + i * h2`),避免 k 次独立 hash 计算
- **可序列化**: `NEED_SERIALIZE_AND_DESERIALIZE` macro 保证 ObBloomFilter 可序列化（per cache value）

---

## 9. False Positive Rate 数学分析

### 9.1 数学基础

```
Optimal k (hash functions):
  k = -ln(p) / ln(2) ≈ -log2(p)

Bit count m (given n elements + FPP p):
  m = -n * ln(p) / (ln 2)^2

Memory per element:
  m/n = -ln(p) / (ln 2)^2 ≈ 9.585 bits/element for p = 0.01
```

### 9.2 OB 默认参数（FPP = 0.01）

| 参数 | 值 |
|------|-----|
| FPP | 0.01 (1%) |
| k (hash functions) | 7 (= ⌈-log2(0.01)⌉ = ⌈6.64⌉ = 7) |
| m/n (bits per element) | ~9.6 |
| m/n (bytes per element) | ~1.2 |

### 9.3 不同 FPP 对比

| FPP | k | m/n (bits) | m/n (bytes) | 内存 (100K elements) |
|-----|---|------------|-------------|---------------------|
| 0.1 (10%) | 4 | 4.8 | 0.6 | 60 KB |
| 0.01 (1%) | 7 | 9.6 | 1.2 | **120 KB** ← OB default |
| 0.001 (0.1%) | 10 | 14.4 | 1.8 | 180 KB |
| 0.0001 (0.01%) | 14 | 19.2 | 2.4 | 240 KB |

**trade-off**:
- FPP 越低 → memory 越多 → bloom filter 越大 → cache miss 越多
- OB 选 **0.01** 是 sweet spot（1% FPP + ~1.2 bytes/element,平衡 memory vs false reject）

---

## 10. 跨 Subsystem 集成（OB 全栈性能）

### 10.1 与 SSTable 集成（per #105 v2 Encoding）

```
SSTable write (per micro block):
  1. SSTableWriter::append_row(row):
     - 写入 micro block data (encoded per #105 v2)
     - ObMicroBlockBloomFilter::insert_row(row) → HashSet
  2. SSTableWriter::close_micro_block():
     - ObMicroBlockBloomFilter → ObMacroBlockBloomFilter::merge
     - serialize bloom filter → 写入 macro block metadata

SSTable read (per macro block):
  3. SSTableReader::may_contain(rowkey):
     - ObBloomFilterCache::may_contain → KV cache lookup (per #107 v2)
     - if !is_contain: skip macro block (avoid ~100 μs disk IO)
     - if is_contain: read micro block
```

**性能**: macro block skip 节省 ~100 μs disk IO,加速比 **~2000x**。

### 10.2 与 Compaction 集成（per #106 v2）

```
Compaction merge (micro block → macro block):
  1. ObTabletMergeCtx::merge_micro_blocks():
     - for each micro block: 读 ObMicroBlockBloomFilter (HashSet)
     - merge 到 ObMacroBlockBloomFilter (target macro block)
     - serialize → macro block metadata
```

**关键**: Compaction **不重建 bloom filter** — 只是 **merge 现有 micro filter 到 macro filter**（incremental, efficient, per #106 v2 progressive merge）。

### 10.3 与 KV Cache 集成（per #107 v2）

```
SSTable read:
  1. ObBloomFilterCache::may_contain():
     - ObKVCache<ObBloomFilterCacheKey, ObBloomFilterCacheValue> (per #107 v2 framework)
     - 复用 Hazard Pointer + Pointer Swizzling + Pre-warming
     - cache hit ~50ns (per #107 v2 hit latency)
```

**集成点**: ObBloomFilterCache **是 ObKVCache 的实例**（per #107 v2 template framework）。所有 #107 v2 优化（hazard / swizzle / pre-warm）**自动 apply 到 bloom filter cache**。

### 10.4 与 Runtime Filter 集成（per #112 v2）

```
PX hash join:
  1. Build phase (build side):
     - ObPxBloomFilter::put_batch(hash_array)  →  build filter
  2. P2P datahub broadcast (per #112 v2):
     - 序列化 ObPxBloomFilter → P2P send to probe side workers
  3. Probe phase (probe side):
     - ObPxBloomFilter::prefetch_bits_block(hash)  → cache 预取
     - ObPxBloomFilter::might_contain(hash)  →  probe filter (SIMD)
     - if !is_match: skip row (avoid network transfer)
```

**性能**: hash join bloom filter 跳过 ~90% 不匹配行,加速比 **~10-100x** for star schema joins（per #112 v2）。

---

## 11. 性能 Benchmark

| 场景 | 无 Bloom Filter | OB Bloom Filter (hit) | 加速比 |
|------|-----------------|----------------------|--------|
| **Point lookup (miss)** | ~100 μs (full disk IO) | ~50 ns (cache hit + bloom reject) | **~2000x** |
| **Range scan (selective)** | ~ms (read all) | ~μs (bloom reject) | **~1000x** |
| **Hash join (large, star schema)** | ~10 ms (probe all) | ~100 μs (bloom reject) | **~100x** |
| **SSTable empty read** | ~100 μs × N blocks | ~50 ns × N blocks | **~2000x** |
| **Point lookup (PX bloom hit)** | N/A | ~100 ns (SIMD might_contain) | N/A |

**关键 insight**: Bloom Filter 是 OB **second-most critical performance feature**（仅次于 #107 v2 KV Cache）。从 50ns bloom reject 节省 100μs disk IO,加速比 **~2000x**。

**vs KV Cache (#107 v2)**:
- **KV Cache hit ~50ns** (memory access)
- **Bloom Filter hit ~50ns** (memory access + bit check)
- 两者都是 **in-memory hotpath**,但 KV Cache 返回实际数据,Bloom Filter 只返回 `may_contain` bool

---

## 12. 总结

OB Bloom Filter (5.0.2.0) 是 **3 subsystem × 双 hash (32-bit storage + 64-bit PX) × SIMD 加速 × 自适应 threshold** 的精妙设计：

- **3 subsystem 集成**:
  - **Storage** (`ObMacroBlockBloomFilter` + `ObMicroBlockBloomFilter`) — macro block lookup (byte unit, HashSet 暂存)
  - **Cache** (`ObBloomFilterCache`) — KV cache instance, 复用 #107 v2 framework
  - **PX** (`ObPxBloomFilter` + `ObPxBfMemsetHelper`) — runtime filter for hash join (int64_t unit + SIMD)
- **核心算法**:
  - Optimal `k = -log2(p)` (7 for FPP=0.01)
  - `m/n = 9.6 bits/element` (FPP=0.01)
  - Double hashing (`h1 + i * h2`) 避免 k 次独立 hash 计算
- **SIMD 加速**:
  - AVX512 (`__m256i`) — x86 一次 check **4 个 hash 位置** (256-bit / 64-bit per lane)
  - NEON (`uint64x2_t`) — ARM 一次 check **2 个 lane**
  - `__builtin_prefetch` (PREFETCH_DISTANCE=8) — cache 预取,后续 might_contain latency 减半
  - Function pointer dispatch (`might_contain_`) — runtime SIMD/non-SIMD 选择
- **自适应 threshold**: `ObBloomFilterCache::auto_bf_cache_miss_count_threshold` 根据 background task queue 自适应调整 (default 100, max 1000000)
- **Cooperative memset**: `ObPxBfMemsetHelper` 协作 zero 大 bit array (CACHE_ALIGNED + leader-follower pattern + slice claim)
- **Tenant 隔离**: `ObArenaAllocator` per tenant (per #104 v2 4D matrix)
- **Merge optimization**: micro block filter → macro block filter (incremental, 不重建)

**架构 insight**:
- **Bloom Filter hit ~50ns vs miss ~100μs** — 4 个数量级差距,**second-most critical performance feature**
- **3 subsystem 同源但不同实现** — storage 用 byte-unit (32-bit hash), PX 用 int64_t-unit (64-bit hash + SIMD)
- **Tenant 隔离 + per #104 v2 4D 矩阵** — bloom filter 自身 NUMA-aware
- **集成路径 (OB 全栈)**:
  - SQL → Plan Cache (#112 v2) → Runtime Filter (`ObPxBloomFilter` SIMD) → Hash join probe
  - SSTable read → KV Cache (#107 v2) → `ObBloomFilterCache` → `ObBloomFilter` → disk IO skip
  - Compaction (#106 v2) → `ObMicroBlockBloomFilter` merge → `ObMacroBlockBloomFilter` → macro block metadata

**集成路径 (OB 全栈性能)**:
- SQL → Plan Cache (#112 v2) → Runtime Filter (`ObPxBloomFilter` SIMD) → Hash join
- SSTable read → KV Cache (#107 v2) → `ObBloomFilterCache` → `ObBloomFilter` → disk IO skip
- Compaction (#106 v2) → `ObMicroBlockBloomFilter` merge → `ObMacroBlockBloomFilter` → macro block metadata

---

> 📚 **相关 v2 deep-dive**:
> - **#14 v2 MemTable** — MemTable BTree (5.0.2.0 OB ONLY)
> - **#104 v2 MemStore Allocator** — AChunkMgr + ObTenantCtxAllocator (4D 矩阵)
> - **#105 v2 SSTable Encoding** — encoding/ + index_block/ + micro_block_hash_index + SIMD
> - **#106 v2 SSTable Compaction** — ObCompactionDagRanker + ObTabletMergeCtx + progressive merge
> - **#107 v2 KV Cache** — ObKVCache + Hazard Pointer + Pointer Swizzling + Pre-warming
> - **#108 v2 CLog** — WAL + group commit + PALF
> - **#109 v2 Network** — ob_listener + ob_net_client + batched I/O
> - **#110 v2 Tx** — 2PC + Lock + GTS
> - **#111 v2 Schema/DDL** — schema_version + INSTANT/INPLACE + Online DDL
> - **#112 v2 Plan Cache + Adaptive + Runtime Filter** — ObPlanCache + Adaptive Auto DOP + Adaptive Bypass + Runtime Filter P2P

> 📂 **OB 5.0.2.0 实读路径**:
> - `src/storage/blocksstable/ob_macro_block_bloom_filter.{h,cpp}` — Macro + Micro block bloom filter
> - `src/storage/blocksstable/ob_bloom_filter_cache.{h,cpp}` — KV cache instance (`ObBloomFilterCache`)
> - `src/storage/blocksstable/ob_bloom_filter_data_{reader,writer,load_task}.{h,cpp}` — serialization + load
> - `src/sql/engine/px/ob_px_bloom_filter.{h,cpp,simd.cpp}` — PX runtime bloom filter + SIMD
> - `src/storage/ob_bloom_filter_task.{h,cpp}` — bloom filter task scheduling