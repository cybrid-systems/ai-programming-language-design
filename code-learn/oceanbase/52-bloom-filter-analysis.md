# 52 — ObBloomFilter 实现：构建、合并、SIMD 加速、自适应

> OceanBase CE 源码深度分析系列
> 主题：Bloom Filter 在两个场景中的实现 — 存储层的宏块过滤与 PX 层的 Join Filter

---

## 0. 前言

在文章 08（SSTable 格式）中，我们提到了 SSTable 尾部有一个 Bloom Filter 区域，用于快速判断某个 key 在 Macro Block 中是否存在。文章 51（Block Cache）则分析了 Bloom Filter Cache 的缓存管理。

本文独立于前面的分析，专注于 **Bloom Filter 本身的实现**。我们将从基础算法实现出发，深入到存储层和 PX（并行执行）层的两种 Bloom Filter 设计，最后分析 SIMD 加速和自适应构建策略。

Bloom Filter 在 OceanBase 中用于两个场景：

1. **存储层** — SSTable/Macro Block 级别的 Bloom Filter。查询时，先查 Bloom Filter，如果说不包含则跳过整个 Macro Block 的 IO。
2. **SQL PX 层** — Hash Join 中的 Bloom Filter Join Filter。构建端（Build 端）将 hash table 的 key 插入 Bloom Filter，探测端（Probe 端）先用 Bloom Filter 过滤不可能匹配的行。

两个场景的 Bloom Filter 实现完全不同：

| 维度 | 存储层 Bloom Filter | PX Bloom Filter |
|------|-------------------|-----------------|
| 位图结构 | 单一位图，逐 bit 操作 | Blocked Bloom Filter，256 字节块 |
| 哈希函数数 | 动态计算 (k = ln(1/p) / ln2) | 固定 4 个 |
| 位数组 | uint8_t 数组 | int64_t 数组，cache-line 对齐 |
| 操作方式 | 字节级位操作 | 字级位操作 + SIMD |
| 构建时机 | 合并过程中构建，自适应触发 | DFO 执行时构建 |
| 误判率 | 默认 1% | 默认 1%（可通过参数调整） |
| 持久化 | 写入 SSTable 尾部 | 不持久化，执行完后释放 |

---

## 1. 前置知识：Bloom Filter

### 1.1 基本概念

Bloom Filter 是一种**空间高效的概率性数据结构**，用于回答"一个元素是否在集合中"。它允许假阳性（false positive）但不允许假阴性（false negative）。

**核心思想**：用一个长度为 m 的位数组和 k 个哈希函数表示一个包含 n 个元素的集合。

### 1.2 操作

```
插入: hash_1(x) → 位置 p1, hash_2(x) → p2, ..., hash_k(x) → pk
      将 bits[p1], bits[p2], ..., bits[pk] 全部置 1

查询: hash_1(x) → p1, ..., hash_k(x) → pk
      如果 ANY bit 为 0 → 肯定不存在
      如果 ALL bits 为 1 → 可能存在（可能误判）
```

### 1.3 最优参数

对于给定的 n（元素数）和期望误判率 p：

```
最优位数组大小: m = -n * ln(p) / (ln2)²
最优哈希函数数: k = m/n * ln2
```

### 1.4 误判率公式

```
fpp = (1 - (1 - 1/m)^(k*n))^k ≈ (1 - e^(-k*n/m))^k
```

### 1.5 Blocked Bloom Filter

PX Bloom Filter 使用 **Blocked Bloom Filter** 变体：
- 位数组分为固定大小的块（256 字节）
- 每个元素通过哈希决定其所属的块
- 块内使用固定数量的哈希函数
- 更好的 CPU 缓存局部性

---

## 2. 存储层 Bloom Filter

### 2.1 核心类：ObBloomFilter

`ObBloomFilter`（`ob_bloom_filter_cache.h:31`）是最底层的 Bloom Filter 实现，提供位数组管理、插入、查询和合并操作。

```cpp
// ob_bloom_filter_cache.h:31-63
class ObBloomFilter
{
public:
  static constexpr double BLOOM_FILTER_FALSE_POSITIVE_PROB = 0.01;  // 默认 1% 误判率

  int init_by_row_count(const int64_t element_count,
                        const double false_positive_prob = BLOOM_FILTER_FALSE_POSITIVE_PROB);
  int insert(const uint32_t key_hash);
  int may_contain(const uint32_t key_hash, bool &is_contain) const;
  int merge(const ObBloomFilter &src_bf);
  // ...
private:
  int64_t nhash_;   // 哈希函数数量 k
  int64_t nbit_;    // 位数组比特数 m
  uint8_t *bits_;   // 位数组
};
```

#### init_by_row_count (ob_bloom_filter_cache.cpp:101-138)

根据元素数和误判率自动计算最优 m 和 k：

```cpp
double num_hashes = calc_nhash(false_positive_prob);  // k = -ln(p) / ln2
int64_t num_bits = static_cast<int64_t>((static_cast<double>(element_count)
                                         * num_hashes / static_cast<double>(std::log(2))));  // m = n*k/ln2
int64_t num_bytes = calc_nbyte(num_bits);
bits_ = (uint8_t *)allocator_.alloc(num_bytes);
memset(bits_, 0, num_bytes);
nhash_ = static_cast<int64_t>(num_hashes);  // 取整
nbit_ = num_bits;
```

#### insert (ob_bloom_filter_cache.cpp:165-179)

使用**双重哈希**生成 k 个哈希位置，避免计算 k 个独立哈希的开销：

```cpp
const uint64_t hash = key_hash;
const uint64_t delta = ((hash >> 17) | (hash << 15)) % nbit_;  // 第二哈希
uint64_t bit_pos = hash % nbit_;                                // 第一哈希
for (int64_t i = 0; i < nhash_; i++) {
  bits_[bit_pos / CHAR_BIT] |= (1 << (bit_pos % CHAR_BIT));
  bit_pos = (bit_pos + delta) < nbit_ ? bit_pos + delta : bit_pos + delta - nbit_;
}
```

思路：`h1 = hash`，`h2 = delta`，第 i 个哈希位置 = `(h1 + i * h2) % m`（通过条件减实现取模）。

#### may_contain (ob_bloom_filter_cache.cpp:192-209)

```cpp
const uint64_t hash = key_hash;
const uint64_t delta = ((hash >> 17) | (hash << 15)) % nbit_;
uint64_t bit_pos = hash % nbit_;
is_contain = true;
for (int64_t i = 0; i < nhash_; ++i) {
  if (0 == (bits_[bit_pos / CHAR_BIT] & (1 << (bit_pos % CHAR_BIT)))) {
    is_contain = false;  // 任何一位为 0 → 肯定不存在
    break;
  }
  bit_pos = (bit_pos + delta) < nbit_ ? bit_pos + delta : bit_pos + delta - nbit_;
}
```

#### merge (ob_bloom_filter_cache.cpp:181-191)

两个 Bloom Filter 合并 = 位或操作：

```cpp
const int64_t nbyte = get_nbytes();
for (int64_t i = 0; i < nbyte; ++i) {
  bits_[i] |= src_bf.bits_[i];
}
```

要求两个 BF 的 `nhash_` 和 `nbit_` 相同（由调用者保证）。

### 2.2 微块级 BF 收集：ObMicroBlockBloomFilter

在 SSTable 合并过程中，Bloom Filter 不是逐行插入到位图的——那样太大太慢。OceanBase 先以微块为单位收集行哈希值，再一次性合并到宏级位图。

```cpp
// ob_macro_block_bloom_filter.h:36-75
class ObMicroBlockBloomFilter
{
  // 为单个 Micro Block 收集 rowkey 哈希
  int insert_row(const ObDatumRow &row);             // 插入单行
  int insert_micro_block(const ObMicroBlock &mb);    // 解码微块，逐行插入
  // ...
private:
  hash::ObHashSet<uint32_t, NoPthreadDefendMode> hash_set_;  // 行哈希集合
  int64_t row_count_;
};
```

`insert_micro_block`（`ob_macro_block_bloom_filter.cpp:121-252`）的流程：

1. 解码微块（解压缩）
2. 获取微块读取器
3. 遍历微块中的每一行
4. 对每行提取 rowkey → 计算 MurmurHash → 存入哈希集合

### 2.3 宏块级 BF：ObMacroBlockBloomFilter

```cpp
// ob_macro_block_bloom_filter.h:78-135
class ObMacroBlockBloomFilter
{
public:
  static const int32_t MACRO_BLOCK_BLOOM_FILTER_V1 = 1;          // 序列化版本
  static const int64_t MACRO_BLOCK_BLOOM_FILTER_MAX_SIZE = 64 * 1024;  // 最大 64KB

  static int64_t predict_next(const int64_t curr_macro_block_row_count);  // 预测行数

  int alloc_bf(const ObDataStoreDesc &desc, const int64_t row_count);     // 根据行数分配 BF
  bool is_valid() const;
  bool should_persist() const;     // 是否要持久化
  int merge(const ObMicroBlockBloomFilter &micro_bf);                      // 合并微块 BF
  int serialize(char *buf, const int64_t buf_len, int64_t &pos) const;
  int deserialize(const char *buf, const int64_t data_len, int64_t &pos);
  // ...
private:
  int64_t calc_max_row_count(const int64_t bf_size) const
  {
    // m = bf_size * 8 bits, k = -ln(p) / ln2
    // n = m * ln2 / k
    int64_t bf_nbit = bf_size * 8;
    double bf_nhash = -std::log(ObBloomFilter::BLOOM_FILTER_FALSE_POSITIVE_PROB) / std::log(2);
    return static_cast<int64_t>(bf_nbit * std::log(2) / bf_nhash);
  }
};
```

关键要点：

- **最大大小**：64KB（`MACRO_BLOCK_BLOOM_FILTER_MAX_SIZE`），确保 Bloom Filter 不会占用过多空间
- **auto-sizing**：`alloc_bf` 根据 `row_count` 自动计算位图大小，但不会超过 64KB
- **`should_persist`**：只有 `row_count > 0 && row_count <= max_row_count_` 时才持久化

### 2.4 合并流程

```
Macro Block 合并过程中的 Bloom Filter 构建

每个 Micro Block:
  ObMicroBlockBloomFilter 收集行哈希到 hash_set_
       ↓
  ObMacroBlockBloomFilter::merge(micro_bf)
       ↓
  MergeMicroBlockFunctor 遍历 hash_set_
       ↓
  ObBloomFilter::insert(hash_val) — 逐个插入位图
       ↓
  所有 Micro Block 完成后
       ↓
  ObMacroBlockBloomFilter — 序列化到 SSTable 尾部
```

`merge` 的具体实现（`ob_macro_block_bloom_filter.cpp:358-374`）：

```cpp
int ObMacroBlockBloomFilter::merge(const ObMicroBlockBloomFilter &micro_bf)
{
  row_count_ += micro_bf.get_row_count();
  if (row_count_ > max_row_count_) {
    // 超过最大行数 → 放弃构建（不持久化）
  } else {
    MergeMicroBlockFunctor functor(bf_);
    micro_bf.foreach(functor);  // 遍历 hash_set，逐行插入
  }
}
```

`predict_next`（`ob_macro_block_bloom_filter.cpp:310-319`）用于预测下一轮合并的行数：

```cpp
int64_t ObMacroBlockBloomFilter::predict_next(const int64_t curr_macro_block_row_count)
{
  return (row_count == 0) ? 0 : (row_count * 1.3 + 1);
}
```

### 2.5 持久化 — Bloom Filter 写入 SSTable

Bloom Filter 持久化到 SSTable 的尾部区域，由 `ObBloomFilterDataWriter` 管理：

```cpp
// ob_bloom_filter_data_writer.h
class ObBloomFilterDataWriter
{
  // append(rowkey, datum_utils) — 逐行插入哈希

  // append(bf_cache_value) — 直接插入已构建的 BF
  // flush_bloom_filter() — 写入 SSTable 尾部

  static const int64_t BLOOM_FILTER_MAX_ROW_COUNT = 1500000L;  // 150 万行上限
};
```

写入层级：

```
ObBloomFilterDataWriter
  → ObBloomFilterCacheValue (包含 ObBloomFilter 位图)
    → ObBloomFilterMacroBlockWriter
      → ObBloomFilterMicroBlockWriter
        → ObBloomFilterMicroBlockHeader (BF 微块头)
        → 压缩的 BF 数据 → Macro Block 尾部
```

### 2.6 缓存的 BF 写入：ObMacroBloomFilterCacheWriter

在自适应构建场景（非合并路径）下，使用 `ObMacroBloomFilterCacheWriter` 将 BF 写入到 `ObBloomFilterCache`，而非持久化到 SSTable。

```cpp
// ob_bloom_filter_cache.h:259-281
class ObMacroBloomFilterCacheWriter
{
  int init(const int64_t rowkey_column_count, const int64_t row_count);
  int append(const common::ObArray<uint32_t> &hashs);           // 追加哈希 batch
  bool can_merge(const ObMacroBloomFilterCacheWriter &other);
  int merge(const ObMacroBloomFilterCacheWriter &other);
  int flush_to_cache(const uint64_t tenant_id, const MacroBlockId& macro_id);  // 写入缓存
};
```

---

## 3. PX Bloom Filter

PX（并行执行）层使用的 Bloom Filter 与存储层完全不同。

### 3.1 设计特点

PX Bloom Filter 采用 **Blocked Bloom Filter** 设计，专为 CPU 效率优化：

```cpp
// ob_px_bloom_filter.h — 关键常量
#define LOG_HASH_COUNT 2          // = log2(FIXED_HASH_COUNT)
#define MIN_FILTER_SIZE 256       // 最小 256 位
#define MAX_BIT_COUNT 17179869184 // 2^34, 最大 2GB 位图
#define BF_BLOCK_SIZE 256         // Block = 256 bits
#define CACHE_LINE_SIZE 64        // CPU 缓存行对齐
#define FIXED_HASH_COUNT 4        // 固定 4 个哈希函数
#define WORD_SIZE 64              // 字大小
#define BLOCK_FILTER_HASH_MASK 0x3F3F3F3F  // 每个字节仅保留低 6 位
```

`ObPxBloomFilter` 使用 int64_t 数组作为位数组：

```cpp
// ob_px_bloom_filter.h — 成员变量
int64_t *bits_array_;       // 位数组（int64_t 数组）
int64_t bits_array_length_; // 数组长度
int64_t bits_count_;        // 位总数
int64_t hash_func_count_;   // 固定 = 4
int64_t block_mask_;        // 块掩码
bool fit_l3_cache_;        // 是否适合 L3 缓存
GetFunc might_contain_;     // 函数指针（SIMD 或非 SIMD）
```

### 3.2 初始化

`init()`（`ob_px_bloom_filter.cpp:44-109`）：

```cpp
int ObPxBloomFilter::init(int64_t data_length, ObIAllocator &allocator, int64_t tenant_id,
                          double fpp = 0.01, int64_t max_filter_size = 2147483648 /*2G*/)
{
  // 1. 计算所需位数
  calc_num_of_bits();

  // 2. 设置哈希函数数（固定 = 4）
  calc_num_of_hash_func();

  // 3. 位数组长度（向上取整到 64 位）
  bits_array_length_ = ceil((double)bits_count_ / 64);

  // 4. 检查是否适合 L3 缓存
  fit_l3_cache_ = bits_array_length_ * sizeof(int64_t) < get_level3_cache_size();

  // 5. 分配内存（cache-line 对齐）
  void *bits_array_buf = allocator.alloc((CACHE_LINE_SIZE + bits_array_length_) * sizeof(int64_t));
  int64_t align_addr = ((reinterpret_cast<int64_t>(bits_array_buf)
                        + CACHE_LINE_SIZE - 1) >> LOG_CACHE_LINE_SIZE) << LOG_CACHE_LINE_SIZE;
  bits_array_ = reinterpret_cast<int64_t *>(align_addr);
  MEMSET(bits_array_, 0, bits_array_length_ * sizeof(int64_t));

  // 6. 自动选择 might_contain 实现（SIMD or non-SIMD）
  bool simd_support = common::is_arch_supported(ObTargetArch::AVX512);
  might_contain_ = simd_support ? &ObPxBloomFilter::might_contain_simd
                   : &ObPxBloomFilter::might_contain_nonsimd;
}
```

### 3.3 位数计算

```cpp
// ob_px_bloom_filter.cpp:126-140
void ObPxBloomFilter::calc_num_of_bits()
{
  // Blocked Bloom Filter 的误判率公式:
  // fpp = (1 - (1 - 1/w)^x)^4, 其中 w=64, x=n/block_count
  int64_t n = ceil(data_length_ * BF_BLOCK_SIZE * log(1 - 1.0 / static_cast<double>(WORD_SIZE))
                    / log(1 - pow(fpp_, 1.0 / static_cast<double>(FIXED_HASH_COUNT))));
  // 向上取整到 2^n - 1
  n = n - 1;
  n |= n >> 1; n |= n >> 2; n |= n >> 4;
  n |= n >> 8; n |= n >> 16; n |= n >> 32;
  // 确保 >= 256 且 <= max_bit_count_
  bits_count_ = ((n < MIN_FILTER_SIZE) ? MIN_FILTER_SIZE
                : (n >= max_bit_count_) ? max_bit_count_ : n + 1);
  block_mask_ = (bits_count_ >> (LOG_HASH_COUNT + 6)) - 1;
}
```

这里的 `block_mask_` 用于从哈希值提取块索引：`block_index = hash & block_mask_`，其中 `bits_count_` 是 2 的幂，所以可以用位与代替取模。

### 3.4 put — 插入操作

```cpp
// ob_px_bloom_filter.cpp:177-192
int ObPxBloomFilter::put(uint64_t hash)
{
  // 1. 定位块: block_begin (以 int64_t 为单位)
  uint64_t block_begin = (hash & block_mask_) << LOG_HASH_COUNT;

  // 2. 从哈希高位提取 4 个字节，每个 6 位
  uint32_t hash_high = ((uint32_t)(hash >> 32) & BLOCK_FILTER_HASH_MASK);
  uint8_t *block_hash_vals = (uint8_t *)&hash_high;

  // 3. 设置 4 个位
  (void)set(block_begin, 1L << block_hash_vals[0]);
  (void)set(block_begin + 1, 1L << block_hash_vals[1]);
  (void)set(block_begin + 2, 1L << block_hash_vals[2]);
  (void)set(block_begin + 3, 1L << block_hash_vals[3]);
}
```

Blocked Bloom Filter 的优势：
- 4 个设置了位的 int64_t 在同一个 cache line（或相邻 cache line）内
- 预取一个 cache line 即可覆盖 8 个 int64_t，覆盖所有 4 个位置

### 3.5 set — 带 CAS 的位设置

```cpp
// ob_px_bloom_filter.cpp:259-268
bool ObPxBloomFilter::set(uint64_t word_index, uint64_t bit_index)
{
  if (!get(word_index, bit_index)) {       // 如果位是 0
    int64_t old_v = 0, new_v = 0;
    do {
      old_v = bits_array_[word_index];
      new_v = old_v | bit_index;
    } while (ATOMIC_CAS(&bits_array_[word_index], old_v, new_v) != old_v);
    return true;
  }
  return false;
}
```

使用 `ATOMIC_CAS` 确保并发安全：多个线程可同时向同一个 Bloom Filter 插入数据。

### 3.6 might_contain_nonsimd — 非 SIMD 查询

```cpp
// ob_px_bloom_filter.cpp:248-258
int ObPxBloomFilter::might_contain_nonsimd(uint64_t hash, bool &is_match)
{
  is_match = true;
  uint64_t block_begin = (hash & block_mask_) << LOG_HASH_COUNT;
  uint32_t hash_high = ((uint32_t)(hash >> 32) & BLOCK_FILTER_HASH_MASK);
  uint8_t *block_hash_vals = (uint8_t *)&hash_high;
  if (!get(block_begin, 1L << block_hash_vals[0])) is_match = false;
  else if (!get(block_begin + 1, 1L << block_hash_vals[1])) is_match = false;
  else if (!get(block_begin + 2, 1L << block_hash_vals[2])) is_match = false;
  else if (!get(block_begin + 3, 1L << block_hash_vals[3])) is_match = false;
}
```

### 3.7 PX Bloom Filter Join 流程

```
PX Hash Join Bloom Filter 数据流

Build 端（Hash Table 构建侧）:
  ┌─────────────────────────┐
  │  多个 DFO 线程并行构建 BF │
  │  ObPxBloomFilter::put()  │
  │  (线程安全 ATOMIC_CAS)   │
  └────────┬────────────────┘
           │ 每个线程的局部 BF
           ▼
  ┌─────────────────────────┐
  │   合并到全局 BF          │
  │  merge_filter()         │
  └────────┬────────────────┘
           │ RPC 传输 BF 数据
           ▼
  ┌─────────────────────────┐
  │  ObPxBloomFilterManager │
  │  全局 BF 管理器         │
  └────────┬────────────────┘

Probe 端（探测侧）:
  ┌─────────────────────────┐
  │  might_contain(hash)    │
  │  might_contain_vector() │ ← 向量化批量查询
  │  (SIMD 加速自动选择)    │
  └────────┬────────────────┘
           ▼
  ┌─────────────────────────┐
  │  不包含 → 过滤掉该行    │
  │  可能包含 → 发送给 Join │
  └─────────────────────────┘
```

### 3.8 merge_filter — 合并操作

```cpp
// ob_px_bloom_filter.cpp:295-306
int ObPxBloomFilter::merge_filter(ObPxBloomFilter *filter)
{
  for (int i = 0; i < filter->bits_array_length_; ++i) {
    int64_t old_v = 0, new_v = 0;
    do {
      old_v = bits_array_[i + filter->begin_idx_];
      new_v = old_v | filter->bits_array_[i];
    } while (old_v != new_v
             && ATOMIC_CAS(&bits_array_[i + filter->begin_idx_], old_v, new_v) != old_v);
  }
}
```

注意：如果 `old_v == new_v`，则跳过 CAS（优化：避免无意义的原子写）。

### 3.9 预取优化

```cpp
// ob_px_bloom_filter.h
inline void prefetch_bits_block(uint64_t hash)
{
  uint64_t block_begin = (hash & block_mask_) << LOG_HASH_COUNT;
  __builtin_prefetch(&bits_array_[block_begin], 0);
}
```

在批量探测时，先对所有哈希值调 `prefetch_bits_block` 进行预取，再逐行查 BF：

```cpp
// ob_px_bloom_filter.cpp:197-201 (put_batch 中的预取)
if (!fit_l3_cache()) {
  for (int64_t i = bound.start(); i < bound.end(); ++i) {
    prefetch_bits_block(batch_hash_values[i]);
  }
}
```

如果 BF 适合 L3 缓存（`fit_l3_cache_`），则不需要预取 — 整个 BF 已经在 L3 中。

### 3.10 分布式 BF 传输

PX Bloom Filter 在 DFO（Data Flow Operator）之间通过 RPC 传输：

```cpp
// ob_px_bloom_filter.h
struct ObPxBFSendBloomFilterArgs
{
  ObPXBloomFilterHashWrapper bf_key_;        // BF 唯一标识
  ObPxBloomFilter bloom_filter_;             // 序列化的 BF 数据
  common::ObSArray<common::ObAddr> next_peer_addrs_;  // 下一跳地址
  ObSendBFPhase phase_;                      // FIRST_LEVEL / SECOND_LEVEL
  int64_t expect_bloom_filter_count_;
  int64_t current_bloom_filter_count_;
};

// RPC 代理
class ObPxBFProxy : public obrpc::ObRpcProxy
{
  RPC_AP(PR1 send_bloom_filter, OB_PX_SEND_BLOOM_FILTER, (sql::ObPxBFSendBloomFilterArgs));
};
```

`ObPxBloomFilter` 实现了 `OB_UNIS_VERSION` 宏，支持自动序列化/反序列化：

```cpp
// 序列化时只发送 begin_idx_ 到 end_idx_ 之间的数据（可能只是整个 BF 的一部分）
for (int i = begin_idx_; i <= end_idx_; ++i) {
  serialization::encode(buf, buf_len, pos, bits_array_[i]);
}
```

---

## 4. SIMD 加速

### 4.1 SIMD might_contain_simd

```cpp
// ob_px_bloom_filter.cpp:19-27
int ObPxBloomFilter::might_contain_simd(uint64_t hash, bool &is_match)
{
#if defined(__x86_64__)
  specific::avx512::inline_might_contain_simd(bits_array_, block_mask_, hash, is_match);
#else
  ret = might_contain_nonsimd(hash, is_match);
#endif
}
```

### 4.2 内联 AVX512 实现

`inline_might_contain_simd` 使用 AVX512 指令在一个 SIMD 操作中检查 4 个哈希位置：

```cpp
// ob_px_bloom_filter.h (common::specific::avx512 命名空间)
OB_INLINE void inline_might_contain_simd(
    int64_t *bits_array, int64_t block_mask, uint64_t hash, bool &is_match)
{
  // 1. 创建移位掩码: {24, 16, 8, 0}
  static const __m256i HASH_VALUES_MASK = _mm256_set_epi64x(24, 16, 8, 0);

  // 2. 获取块起始位置
  uint32_t hash_high = (uint32_t)(hash >> 32);
  uint64_t block_begin = (hash & block_mask) << LOG_HASH_COUNT;

  // 3. 准备位向量: 4 个 1，分别左移 hash_high 的 4 个字节
  __m256i bit_ones = _mm256_set1_epi64x(1);
  __m256i hash_values = _mm256_set1_epi64x(hash_high);
  hash_values = _mm256_srlv_epi64(hash_values, HASH_VALUES_MASK);  // 右移提取每个字节
  hash_values = _mm256_rolv_epi64(bit_ones, hash_values);           // 左移得到位掩码

  // 4. 从位数组加载 4 个 int64_t（整个块）
  __m256i bf_values = _mm256_load_si256((__m256i *)&bits_array[block_begin]);

  // 5. 检查: (~bf_values) & bit_masks == 0? "可能存在"
  is_match = 1 == _mm256_testz_si256(~bf_values, hash_values);
}
```

工作原理：

1. 将 block_begin 处的 4 个 int64_t 加载到 256 位向量 `bf_values`
2. 对 `hash_high` 的 4 个字节（每个 6 位有效），生成 4 个位掩码 `hash_values`
3. `~bf_values` 表示"位为 0 的位置"
4. `_mm256_testz_si256(~bf_values, hash_values)` 测试位掩码是否被 ~bf_values 完全包含
5. 如果 `(~bf_values) & hash_values == 0`（全部相遇），说明所有的位都被设置 → 可能存在
6. 否则 → 肯定不存在

**不使用 SIMD 的版本**需要 4 次 `get` 调用 + 4 次分支判断，SIMD 版本只需 3 条 SIMD 指令 + 1 条 test 指令。

### 4.3 向量化批量探测

`might_contain_vector` 方法支持向量化批量探测：

```cpp
// ob_px_bloom_filter.cpp:742-764
int ObPxBloomFilter::might_contain_vector(const ObExpr &expr, ObEvalCtx &ctx,
                                          const ObBitVector &skip, const EvalBound &bound,
                                          uint64_t *hash_values, int64_t &total_count,
                                          int64_t &filter_count)
{
  // 根据是否所有行活跃、是否支持 SIMD、结果向量格式
  // 通过宏分派到不同的模板实例化版本
  // ...
  BLOOM_FILTER_DISPATCH_ALL_ROWS_ACTIVATE(inner_might_contain,
                                          all_rows_active, support_simd, res_format)
}
```

模板展开链：

```
might_contain_vector()
  → BLOOM_FILTER_DISPATCH_ALL_ROWS_ACTIVATE
    → BLOOM_FILTER_DISPATCH_SIMD
      → BLOOM_FILTER_DISPATCH_RES_FORMAT
        → inner_might_contain<bool ALL_ROWS_ACTIVE, bool SUPPORT_SIMD, typename ResVec>
```

`inner_might_contain` 模板函数会：
1. 先对所有哈希预取 BF 块
2. 再逐行调用 `inline_might_contain_simd` 或 `might_contain_nonsimd`
3. 记录总行数和过滤行数
4. 将结果写入向量（`IntegerFixedVec` 或 `IntegerUniVec`）

---

## 5. 自适应构建策略

### 5.1 问题背景

存储层 Bloom Filter 在 SSTable 合并时构建并持久化到 SSTable 尾部。但并非所有 SSTable 都有 Bloom Filter：
- 老版本的 SSTable 可能没有 BF
- 某些合并策略可能没有构建 BF
- 读取时根据需要动态构建

读取路径中存储层 Bloom Filter 的自适应构建是 OceanBase 的关键优化。

### 5.2 空读计数

`ObBloomFilterCache::inc_empty_read`（`ob_bloom_filter_cache.cpp:822-922`）：

```
流程:

1. 查询在某个 Macro Block 中未找到目标 key（空读）
2. 递增该 Macro Block 的空读计数（存储在 ObEmptyReadBucket 中）
3. 当空读计数 > bf_cache_miss_count_threshold_:
   ┌─ SSTable 已有 BF 数据 → schedule_load_bloomfilter()
   └─ SSTable 无 BF 数据   → schedule_build_bloomfilter()

4. 构建/加载完成后 → put_bloom_filter() 写入缓存
   → reset() 空读计数

5. 后续查询: ObBloomFilterCache::may_contain() 先查缓存
   → 肯定不存在 → 跳过该 Macro Block
   → 可能存在 → 正常 IO
```

### 5.3 阈值自动调节

```cpp
// ob_bloom_filter_cache.h:215-231
inline void auto_bf_cache_miss_count_threshold(const int64_t qsize)
{
  // newsize = base * (1 + (qsize >> 4)^2)
  uint64_t newsize = static_cast<uint64_t>(qsize) >> BF_BUILD_SPEED_SHIFT;  // qsize / 16
  newsize = GCONF.bf_cache_miss_count_threshold * (1 + newsize * newsize);

  if (newsize != bf_cache_miss_count_threshold_) {
    bf_cache_miss_count_threshold_ = newsize < MAX_EMPTY_READ_CNT_THRESHOLD
                                     ? newsize : MAX_EMPTY_READ_CNT_THRESHOLD;
  }
}
```

当构建 BF 的任务队列（`qsize`）增长时，阈值自动增大，减少新的 BF 构建请求。这种**负反馈**机制防止了 BF 构建任务的雪崩效应。

阈值调节参数：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `bf_cache_miss_count_threshold`（初始） | 100 | 通过 GCONF 配置 |
| `BF_BUILD_SPEED_SHIFT` | 4 | 除法因子（2^4 = 16） |
| `MAX_EMPTY_READ_CNT_THRESHOLD` | 1,000,000 | 上限 |
| `DEFAULT_EMPTY_READ_CNT_THRESHOLD` | 100 | 默认初始值 |

### 5.4 自适应构建流程图

```
查询路径: 检查 Bloom Filter（未命中缓存）
    │
    ▼
┌───────────────────┐
│ 查缓存             │
│ may_contain()     │
└───────┬───────────┘
        │
   缓存未命中 ▼
┌───────────────────┐
│ IO 读取 Macro Block│
│ → 未找到目标 key   │
└───────┬───────────┘
        │
   空读事件 ▼
┌───────────────────┐
│ inc_empty_read()  │
│ +1 空读计数       │
└───────┬───────────┘
        │
   空读 > 阈值? ▼
┌───────┴───────────┐
│                   │
│   Yes             │ No → 继续正常查询
│                   │
   ▼
┌────────────────┐
│ SSTable 有 BF?  │
└───────┬────────┘
        │
   Yes  │       No
   ▼    │       ▼
┌────────────┐  ┌──────────────┐
│ schedule_  │  │ schedule_    │
│ load_bf()  │  │ build_bf()   │
└──────┬─────┘  └──────┬───────┘
       │               │
  异步加载 BF     │  重新扫描 SSTable
  到位后写缓存    │  构建 BF 写缓存
       │               │
       ▼               ▼
┌───────────────────────┐
│ put_bloom_filter()    │
│ 写入 BloomFilterCache │
│ → reset 空读计数      │
└───────────────────────┘
        │
        ▼
下次查询这个 Macro Block:
┌───────────────────┐
│ may_contain()     │
│ → 缓存命中        │
│ → "不包含"        │
│ → 跳过该块 IO     │
└───────────────────┘
```

### 5.5 自适应构建的优势

1. **写路径性能**：SSTable 写入时不必须构建 BF，避免写放大
2. **读模式感知**：只在某个 Macro Block 被频繁空读时才触发生成
3. **冷热数据识别**：长期不访问的 Macro Block 永远不会构建 BF
4. **自限性**：负反馈机制防止队列积压
5. **双路径支持**：已有持久化 BF → 加载；无 BF → 构建

### 5.6 PX Bloom Filter 中的"自适应"

PX Bloom Filter 虽然不涉及"空读计数"，但也有自适应逻辑：

1. **SIMD 运行时检测**：`common::is_arch_supported(ObTargetArch::AVX512)` 自动选择 SIMD/non-SIMD 路径
2. **fit_l3_cache_**：如果 BF 适合 L3 缓存，跳过预取优化
3. **分阶段传输**：`FIRST_LEVEL` / `SECOND_LEVEL` 两阶段传输 BF

---

## 6. ASCII 图 — BF 构建和查询流程

### 6.1 存储层 Bloom Filter 构建流程

```
SSTable 合并（Major Compaction）
    │
    ▼
┌──────────────────────────────────────────┐
│ 遍历 Macro Block 中的 Micro Block         │
├──────────────────────────────────────────┤
│                                          │
│  ┌──────────────────┐                    │
│  │ Micro Block 1    │                    │
│  │                  │                    │
│  │ ObMicroBlockBF   │                    │
│  │ hash_set_ = {h1, │                    │
│  │   h2, ..., hn}   │                    │
│  └────────┬─────────┘                    │
│           │ merge(micro_bf)              │
│           ▼                              │
│  ┌──────────────────┐                    │
│  │ Macro Block BF   │                    │
│  │ ObBloomFilter    │                    │
│  │ bits_ += 各行哈希 │                    │
│  └──────────────────┘                    │
│                                          │
│  ┌──────────────────┐                    │
│  │ Micro Block 2    │                    │
│  │ ... (同上)        │                    │
│  └────────┬─────────┘                    │
│           │ ...                          │
│           ▼                              │
│  ┌──────────────────┐                    │
│  │ 所有 Micro Block │                    │
│  │ 合并完成         │                    │
│  └────────┬─────────┘                    │
│           ▼                              │
│  ┌──────────────────────────────────┐    │
│  │ should_persist()?                │    │
│  │ row_count <= max_row_count_?     │    │
│  └───────┬──────────────────────────┘    │
│           │                              │
│       Yes ▼              No              │
│  ┌──────────────┐    ┌──────────────┐    │
│  │ serialize()  │    │ 丢弃 BF      │    │
│  │ 写入 SSTable │    │ (不持久化)   │    │
│  │ 尾部         │    │              │    │
│  └──────────────┘    └──────────────┘    │
│                                          │
└──────────────────────────────────────────┘

SSTable 布局:
┌────────┬────────┬────────┬──────┬──────────┐
│ Macro  │ Micro  │ Micro  │ ...  │ Bloom    │
│ Block  │ Block  │ Block  │      │ Filter   │
│ Header │ 1      │ 2      │      │ Data     │
└────────┴────────┴────────┴──────┴──────────┘
                                    ↑
                          Bloom Filter 尾部区域
```

### 6.2 存储层 BF 查询流程

```
行查询进入 DAS Scan
    │
    ▼
┌────────────────────────┐
│ 查 Row Cache (跳过)    │
└────────┬───────────────┘
         ▼
┌────────────────────────┐
│ 遍历 Macro Block 索引   │
└────────┬───────────────┘
         ▼
┌────────────────────────┐
│ 对候选 Macro Block:    │
│                        │
│  ObBloomFilterCache:   │
│  may_contain()         │
│                        │
│  key = {tenant_id,     │
│         macro_block_id,│
│         prefix_len}    │
└────────┬───────────────┘
         │
     ┌───┴───┐
     │       │
 可能包含  肯定不存在
     │       │
     ▼       ▼
┌────────┐ ┌──────────────┐
│ IO 读取│ │ 跳过该 Macro │
│ 微块   │ │ Block (无 IO) │
└────────┘ └──────────────┘
     │
     ▼
┌────────────────────────┐
│ 微块中仍未找到目标 key  │
│ → inc_empty_read()     │
│   (累加空读计数)        │
└────────────────────────┘

Bloom Filter 查询示例:
Rowkey: "user_42"
Hash: murmurhash("user_42") → 0xABCD1234
                                                ┌─────────────►┌─────┐
Bloom Filter 位数组 (m 位):  001001...010100...  │              │ 1   │
                                               ──┤ nhash_ 次    ├─────┤
对于每个哈希函数:                               │  检查         │ 0 → 不存在!
  bit_pos = (h1 + i*h2) % m                     └─────────────►└─────┘
```

### 6.3 PX Bloom Filter 构建与探测

```
DFO-1: Build 端                                DFO-2: Probe 端
                                                          
┌─────────────────────┐                       ┌─────────────────────┐
│ Build Hash Table    │                       │ 扫描 Probe 表行     │
│ 同时插入 BF: put()  │                       │                     │
│                     │                       │ 对每行:            │
│ hash_table[h1] → v1 │                       │   hash = murmur(   │
│ hash_table[h2] → v2 │                       │     probe_col)     │
│ ...                 │                       │                     │
└──────────┬──────────┘                       │  prefecth_bits_     │
           │                                  │  block(hash)       │
           │ 每行插入 BF                      │                    │
           ▼                                  │  might_contain(    │
┌─────────────────────┐                       │    hash)           │
│ ObPxBloomFilter     │  RPC (部分/全量)      │     → true → 继续  │
│ bits_array_[0..N]  │──────────────────────►  │     → false → 过滤 │
│                     │                       │                    │
│                     │                       │  物化到 Hash Join  │
└─────────────────────┘                       └────────────────────┘

Blocked Bloom Filter 结构:

┌─── Block 0 (256 bits = 4 × int64_t) ──┬─── Block 1 ──┬────────
│ word[0]: [0][0][1][0][0][1]...[0][1] │ word[0]: ... │
│ word[1]: [1][0][0][0][1][1]...[0][0] │ word[1]: ... │
│ word[2]: [0][0][0][0][0][0]...[0][0] │ word[2]: ... │
│ word[3]: [0][1][0][0][0][0]...[0][0] │ word[3]: ... │
└───────────────────────────────────────┴──────────────┴────────

哈希值映射:
  hash[63:0]
    │
    ├── hash[31:0] (低 32 位) → block_index = hash & block_mask_
    │      (定位到哪个 256-bit 块)
    │
    └── hash[63:32] (高 32 位) → 4 个 6-bit 值:
        hash_high & 0x3F        → word[0] 中的位偏移
        (hash_high >> 8) & 0x3F → word[1] 中的位偏移
        (hash_high >> 16) & 0x3F → word[2] 中的位偏移
        (hash_high >> 24) & 0x3F → word[3] 中的位偏移
```

---

## 7. 设计决策分析

### 7.1 为什么在宏块级别而不是微块级别使用 Bloom Filter？

OceanBase 的 `ObMicroBlockBloomFilter` 虽然是微块级别的，但它只在合并过程中作为中间容器使用。持久化和查询使用的 BF 是宏块级别的。

**原因：**

1. **Bin 效率**：Bloom Filter 的位数组在宏块级别（典型几十万行）比微块级别（几百行）使用效率更高。微块太小，BF 的固定开销（序列化头、哈希函数多）占比太大。

2. **IO 粒度**：OceanBase 的 IO 最小单位是宏块（2MB）。跳过微块 IO 的收益有限（微块已经很小），而跳过整个宏块的收益显著。

3. **缓存效率**：宏块级 BF（典型 ~64KB）在 ObBloomFilterCache 中缓存管理效率更高，每个宏块只有一个缓存条目。

4. **存储开销**：如果每个微块都有 BF，SSTable 尾部的 BF 区域会占用过多空间。宏块级将总 BF 大小限制为 `宏块数 * 64KB`。

### 7.2 PX Bloom Filter 与存储层 BF 的区别

| 维度 | 存储层 BF | PX BF |
|------|----------|-------|
| **位图类型** | 标准 Bloom Filter，单一位图 | Blocked Bloom Filter，256-bit 块 |
| **哈希函数** | 动态计算 k，双重哈希 | 固定 4 个，从 32 位高位提取 |
| **位操作** | 逐字节操作 uint8_t | 整字操作 int64_t |
| **并发控制** | 单线程（SSTable 合并） | 多线程（ATOMIC_CAS） |
| **内存分配** | ObArenaAllocator | ObIAllocator + cache-line 对齐 |
| **误判率控制** | 固定 1% | 可配置（_bloom_filter_ratio） |
| **持久化** | 序列化到 SSTable 尾部 | 不持久化，通过 RPC 传输 |
| **SIMD** | 无 | AVX512 加速 |
| **最大大小** | 64 KB | 2 GB（max_filter_size） |

**为什么两个系统采用不同的实现？**

存储层 BF 的主要约束是**空间效率**：需要持久化到 SSTable，占用磁盘空间和缓存。标准 BF 在空间效率上更好（Blocked BF 为了 CPU 优化会多占用一些位）。

PX BF 的主要约束是**CPU 效率**：需要在每行数据的路径上进行插入和探测，而且 PX 是多线程执行的。Blocked BF + SIMD + cache-line 对齐 + CAS 操作的组合在 CPU 效率上远优于标准 BF。

### 7.3 BF 自适应策略的设计权衡

自适应构建（而非 SSTable 写入时立即构建）的决策：

- **写路径性能优先**：SSTable 合并（Major Compaction）是 IO 密集型操作。如果在合并路径中不加限制地构建 BF，会显著增加压缩时间。
- **读模式感知**：不是每个 Macro Block 都需要 BF。如果某个块从未被查询，构建 BF 完全是浪费。
- **冷热分离**：热数据的 BF 会在短时间内达到空读阈值；冷数据的 BF 永远不会触发构建。
- **自限性**：`auto_bf_cache_miss_count_threshold()` 在高并发下自动提升阈值，防止 BF 构建淹没系统。

**潜在问题**：
- 第一次大量空读仍会产生 IO 开销（阈值到达前）
- 竞争条件：多个线程同时触发同一个 Macro Block 的 BF 构建

### 7.4 SIMD 加速方案的选择

OceanBase 选择了 AVX512 来加速 PX Bloom Filter：

```cpp
// 非 SIMD 版本: 4 次内存读取 + 4 次分支
// SIMD 版本: 1 次 256-bit 加载 + 2 次移位 + 1 次 test

// 非 SIMD:
if (!get(block_begin, 1L << v0)) is_match = false;
else if (!get(block_begin+1, 1L << v1)) is_match = false;
// ...

// SIMD (_mm256):
__m256i bf_values = _mm256_load_si256(&bits_array[block_begin]);
is_match = 1 == _mm256_testz_si256(~bf_values, hash_values);
```

AVX512 版本在批量探测中优势更明显：通过 `might_contain_vector`，可以在向量格式的结果上直接批处理，减少函数调用和分支预测失败的代价。

**为什么不使用 SSE/AVX2？** 代码中使用了 `_mm256_rolv_epi64`（AVX512VL 指令）。如果 CPU 不支持 AVX512，回退到非 SIMD 版本。

### 7.5 误判率的业务层面影响

存储层 BF 误判率默认 1%，意味着每 100 次 Bloom Filter 检查中，约有 1 次是误判（认为 key 可能存在，实际不存在）。这导致：

1. **轻微读放大**：误判导致不必要的 IO，但不会影响正确性
2. **业务透明**：BF 的假阳性只影响性能，不影响结果
3. **调优空间**：可以根据业务读写比调整误判率

PX Bloom Filter 的误判率通过 `_bloom_filter_ratio` 配置：

```cpp
// ob_px_bloom_filter.cpp:851
OB_FAIL(filter->init(filter_size, allocator,
      (double)GCONF._bloom_filter_ratio / 100));
```

### 7.6 CAS 与无锁并发

PX Bloom Filter 的 `set()` 和 `merge_filter()` 都使用原子 CAS 操作：

```cpp
do {
  old_v = bits_array_[word_index];
  new_v = old_v | bit_index;
} while (ATOMIC_CAS(&bits_array_[word_index], old_v, new_v) != old_v);
```

**为什么不使用基本的位或赋值？**

在多线程场景下，两个线程同时 `bits_[i] |= mask` 可能造成读-改-写冲突。CAS 循环确保结果是所有线程写入的位掩码的并集。

**性能优化**：`merge_filter` 中增加了 `old_v != new_v` 的短路检查，如果目标位已经是 1，直接跳过 CAS。

### 7.7 为什么 PX BF 使用固定 4 个哈希函数？

Blocked Bloom Filter 使用固定数量哈希函数（FIXED_HASH_COUNT = 4）的原因：

1. **SIMD 对齐**：4 个 int64_t = 256 位 = AVX2/AVX512 寄存器宽度
2. **Cache 行友好**：4 int64_t = 32 字节，小于 64 字节的 cache line，整个块在一个 cache line 内
3. **简化位操作**：从哈希扩展到 4 个位的映射非常简单（提取 4 个字节的低 6 位）

---

## 8. 源码索引

| 组件 | 头文件 | 实现文件 | 关键行号 |
|------|--------|---------|---------|
| **ObBloomFilter**（核心位图 BF） | `storage/blocksstable/ob_bloom_filter_cache.h:31` | `.cpp:41` | init_by_row_count @101, insert @165, may_contain @192, merge @181 |
| **ObBloomFilterCacheKey**（BF 缓存键） | `storage/blocksstable/ob_bloom_filter_cache.h:68` | `.cpp:275` | hash @288, operator== @296 |
| **ObBloomFilterCacheValue**（BF 缓存值） | `storage/blocksstable/ob_bloom_filter_cache.h:91` | `.cpp:323` | init @405, may_contain @438, merge_bloom_filter @470 |
| **ObBloomFilterCache**（BF 缓存管理器） | `storage/blocksstable/ob_bloom_filter_cache.h:151` | `.cpp:570` | put_bloom_filter @576, may_contain @627, inc_empty_read @822, auto_bf_cache_miss_count_threshold @215 |
| **ObMacroBloomFilterCacheWriter**（缓存写入器） | `storage/blocksstable/ob_bloom_filter_cache.h:259` | `.cpp:962` | init @971, append @1005, flush_to_cache @1056 |
| **ObMicroBlockBloomFilter**（微块哈希收集） | `storage/blocksstable/ob_macro_block_bloom_filter.h:36` | `.cpp:35` | init @56, insert_row @95, insert_micro_block @121 |
| **ObMacroBlockBloomFilter**（宏块 BF 构建） | `storage/blocksstable/ob_macro_block_bloom_filter.h:78` | `.cpp:313` | alloc_bf @322, merge @358, should_persist @353, predict_next @310, serialize @382, calc_max_row_count @120 |
| **ObBloomFilterDataWriter**（SSTable 写入） | `storage/blocksstable/ob_bloom_filter_data_writer.h:56` | — | append / flush_bloom_filter |
| **ObBloomFilterMicroBlockWriter**（BF 微块写入） | `storage/blocksstable/ob_bloom_filter_data_writer.h:16` | — | write |
| **ObBloomFilterMacroBlockWriter**（BF 宏块写入） | `storage/blocksstable/ob_bloom_filter_data_writer.h:36` | — | write, init_headers |
| **ObPxBloomFilter**（PX BF 类） | `sql/engine/px/ob_px_bloom_filter.h` | `.cpp:43` | init @44, calc_num_of_bits @126, put @177, might_contain_nonsimd @248, set @259, merge_filter @295, might_contain_vector @742, might_contain_simd @19 (SIMD 文件) |
| **inline_might_contain_simd**（AVX512 内联） | `sql/engine/px/ob_px_bloom_filter.h` | — | SIMD 内联函数（头文件内） |
| **might_contain_simd**（SIMD 入口） | — | `ob_px_bloom_filter_simd.cpp:17` | might_contain_simd @17 |
| **inner_might_contain**（向量化批量探测） | — | `ob_px_bloom_filter.cpp:633` | 模板函数 @633 |
| **BloomFilterPrefetchOP**（预取操作器） | — | `ob_px_bloom_filter.cpp:33` | operator() @38 |
| **BloomFilterProbeOP**（探测操作器） | — | `ob_px_bloom_filter.cpp:604` | operator() @613 |
| **ObPxBloomFilterManager**（PX BF 管理器） | `sql/engine/px/ob_px_bloom_filter.h` | `.cpp:770` | instance() @770, get_px_bloom_filter @799 |
| **ObPxBFSendBloomFilterArgs**（RPC 传输） | `sql/engine/px/ob_px_bloom_filter.h` | — | 结构体定义 |
| **ObPxBFProxy**（RPC 代理） | `sql/engine/px/ob_px_bloom_filter.h` | — | RPC_AP send_bloom_filter |
| **ObSendBloomFilterP**（RPC 处理器） | `sql/engine/px/ob_px_bloom_filter.h` | `.cpp` | process_px_bloom_filter_data |

---

## 9. 总结

OceanBase 的 Bloom Filter 实现展现了两个不同场景下的设计取舍：

**存储层 Bloom Filter**：
- 使用标准的 Bloom Filter 算法，双重哈希生成多个位置
- 构建时先以微块为单位收集哈希（ObMicroBlockBloomFilter），再合并到位图
- 最大 64KB，持久化到 SSTable 尾部
- 自适应构建：仅当空读次数超过阈值时才构建，避免不必要的计算
- 默认 1% 误判率，通过 GCONF 配置

**PX Bloom Filter**：
- 使用 Blocked Bloom Filter 变体，固定 4 个哈希函数
- 位数组 cache-line 对齐，支持 AVX512 SIMD 加速
- 多线程安全（ATOMIC_CAS），支持通过 RPC 分布式传输
- 运行时自动检测 SIMD 支持，回退到非 SIMD 版本
- 支持分阶段传输（first_phase / second_phase）

**共同特征**：
- 都使用 MurmurHash 作为基础哈希函数
- 都通过 `ObTargetArch::AVX512` 运行时检测自适应
- 构建和查询都基于 32/64 位哈希值，而非原始 key

两个系统的 Bloom Filter 实现证明了：**在数据库系统中，Bloom Filter 不是一个单一的算法实现，而是一个需要根据场景深度定制的数据结构和操作原语**。
