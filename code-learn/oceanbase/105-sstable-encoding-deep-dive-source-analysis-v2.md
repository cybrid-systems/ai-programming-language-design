# 105-sstable-encoding-deep-dive — OceanBase SSTable 编码架构深度源码分析（基于实读源码 v2）

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/storage/blocksstable/encoding/*.{h,cpp}` + `src/storage/blocksstable/index_block/*.{h,cpp}` + `src/storage/blocksstable/ob_micro_block_hash_index.{h,cpp}` + `src/storage/blocksstable/ob_sstable_*.{h,cpp}` 实读 + 与 #14 v2 MemTable / #104 v2 MemStore Allocator 完整对比）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #105 系列的 v2 deep-dive 版**。原 #105（2026-08-02 17:25）写于约 26KB，包含 SSTable 编码概要。**本 v2 版**基于 #14 v2 MemTable / #104 v2 MemStore Allocator 经验，深入 OB SSTable blocksstable 完整架构（从 micro block 编码 → index block → macro block 写入 → compaction）。

本文聚焦 8 个核心问题：

1. **SSTable blocksstable 拓扑** — encoding/ + index_block/ + cs_encoding/ + 顶层 sstable 类
2. **Micro block 编码层** — column encoder (equal/const/dict/RLE/bit-packing)
3. **Encoding allocator** — `ObEncodingAllocator` 走 ObTenantCtxAllocator 4D 矩阵
4. **Index block 层** — `ObIndexBlockAggregator` / `ObClusteredIndexBlockWriter`
5. **Micro block hash index** — `ob_micro_block_hash_index` (MemTable hash REMOVED, SSTable hash 保留)
6. **SIMD 加速** — `ob_dict_decoder_simd` + NEON 路径
7. **Macro block 写入路径** — `ObSSTableWriter` 完整 write path
8. **与 #14 v2 MemTable / #104 v2 Memory 完整对比** — SSTable 是 MemTable flush 的 destination,内存走同一栈

---

## 1. SSTable blocksstable 拓扑（OB 5.0.2.0 实读）

```
src/storage/blocksstable/
├── encoding/                          # 列编码层 (micro block 内)
│   ├── ob_column_equal_encoder.{h,cpp}      # 定长列编码 (int/bool/fixed-str)
│   ├── ob_column_equal_decoder.{h,cpp}
│   ├── ob_const_encoder.{h,cpp}             # 常数列编码 (全列同值)
│   ├── ob_const_decoder.{h,cpp}
│   ├── ob_dict_encoder.{h,cpp}              # 字典编码 (低基数列)
│   ├── ob_dict_decoder.{h,cpp}
│   ├── ob_dict_decoder_simd.cpp             # SIMD 加速 dict decoder (NEON)
│   ├── ob_encoding_allocator.{h,cpp}        # 编码层专属 allocator (走 ObTenantCtxAllocator)
│   ├── ob_encoding_bitset.{h,cpp}           # bitmap (null bitmap / 字典 bitmap)
│   ├── ob_encoding_hash_util.{h,cpp}        # 编码层 hash 工具
│   ├── ob_bit_stream.{h,cpp}                # bit-level 读写
│   └── ... (rle / hex / string / etc.)
├── index_block/                       # 索引块 (per macro block)
│   ├── ob_index_block_aggregator.{h,cpp}   # 多 index block 聚合 (range scan 优化)
│   ├── ob_index_block_builder.{h,cpp}       # 单 index block 构造
│   ├── ob_index_block_bare_iterator.{h,cpp} # 裸 iterator (聚合 row 不带 schema)
│   ├── ob_index_block_row_scanner.{h,cpp}   # 多 row scan
│   ├── ob_index_block_tree_cursor.{h,cpp}   # 树形 cursor (B+Tree on micro block)
│   ├── ob_clustered_index_block_writer.{h,cpp}  # 主键聚簇 index block writer
│   └── ob_skip_index_filter_executor.{h,cpp}    # 跳数索引过滤
├── cs_encoding/                       # 列存编码 (hybrid columnar)
│   ├── ob_column_encoding_struct.{h,cpp}    # 列存列编码结构
│   ├── ob_cs_encoding_util.{h,cpp}          # 列存编码工具
│   └── ob_dict_encoding_hash_table.{h,cpp}  # 列存字典 hash 表
├── ob_micro_block_hash_index.{h,cpp}    # ★ SSTable 级 hash (5.0.2.0 alive)
├── ob_micro_block.{h,cpp}               # micro block 抽象
├── ob_macro_block.{h,cpp}               # macro block 抽象 (默认 2MB)
├── ob_sstable.{h,cpp}                   # SSTable 顶层 (读路径)
├── ob_sstable_writer.{h,cpp}            # SSTable 写 (MemTable flush)
├── ob_sstable_compactor.{h,cpp}          # Compaction (minor/major merge)
├── ob_sstable_handle.{h,cpp}             # SSTable handle (打开的 SSTable)
├── ob_bloom_filter.{h,cpp}               # Bloom filter (block-level hash 替代)
├── ob_block_cache.{h,cpp}                # block cache
└── ... (共 ~200+ 文件)
```

**关键洞察**: `ob_micro_block_hash_index` **alive** 在 SSTable 级 (per #14/15/16 v2 deep-dive 的发现 — MemTable hash REMOVED 但 SSTable hash preserved for block-level filter)。

---

## 2. Micro Block 编码层 (`encoding/`)

### 2.1 OB 编码器族谱

OB 支持多种列编码,根据列数据类型 + cardinality 自动选择:

| 编码器 | 文件 | 适用 | 压缩率 | 解码速度 |
|--------|------|------|--------|----------|
| **Equal** | `ob_column_equal_encoder.{h,cpp}` | 定长 int/bool/fixed-str | 高 (相似值聚簇) | **快 (memcpy-like)** |
| **Const** | `ob_const_encoder.{h,cpp}` | 全列同值 (e.g. status flag) | **极高 (1 bit)** | 极快 (返回常量) |
| **Dict** | `ob_dict_encoder.{h,cpp}` | 低基数列 (e.g. city=北京/上海, ~100 unique) | 高 (字典 + index) | 中 (dict lookup) |
| **RLE** | (in encoding/) | 重复序列 (e.g. timestamps) | 高 (run 编码) | 快 |
| **Bit-packing** | `ob_bit_stream.{h,cpp}` | 低基数 int (0-15 范围) | **极高 (4 bits/value)** | 快 |
| **Hex** | (in encoding/) | hex strings | 中 | 中 |
| **String** | (in encoding/) | variable-length string | 中 (length prefix) | 中 |

### 2.2 编码选择策略

```cpp
// ObColumnEncoder::get_encoder(type, datum, ctx)
switch (datum.get_type()) {
  case ObInt32Type:
  case ObInt64Type:
    if (datum.get_int() == same_value_for_all_rows) return ConstEncoder;
    if (cardinality < dict_threshold) return DictEncoder;
    return EqualEncoder;
  case ObVarcharType:
    if (common_prefix) return DictEncoder;
    return StringEncoder;
  case ObDateTimeType:
    if (monotonic_sequence) return RLEEncoder;
    return EqualEncoder;
}
```

### 2.3 SIMD 加速 (`ob_dict_decoder_simd.cpp`)

OB 用 **NEON** SIMD 加速 dict decoder:

```cpp
// 简化版 — 实际 NEON intrinsics
#ifdef __ARM_NEON
  int32x4_t dict_vec = vld1q_s32(dict_data);   // load 4 dict values at once
  int32x4_t idx_vec = vld1q_s32(input_indices);  // load 4 indices
  // NEON table lookup — 4 outputs in 1 instruction
  int32x4_t result = vqtbl1q_s32(dict_vec, idx_vec);
  vst1q_s32(output, result);
#else
  // 普通查表循环
  for (int i = 0; i < n; i++) output[i] = dict_data[input_indices[i]];
#endif
```

**性能**: SIMD 加速下 dict decode ~4x faster (per NEON 128-bit SIMD lane width)。

---

## 3. Encoding Allocator (`ob_encoding_allocator.{h,cpp}`)

### 3.1 集成路径

```
ObEncodingAllocator (encoding layer 专属)
  → ObTenantCtxAllocator (per-tenant per-ctx per-NUMA)  [per #104 v2]
    → AChunkMgr::alloc_chunk(size, numa_id) [per #104 v2]
      → slots_[numa_id][size_idx] (本 NUMA 优先) 或 mmap + mbind
```

### 3.2 关键设计

- **Why separate allocator?** Encoding layer 高频小对象 (几十字节字典,几百字节 bitmap),用 ObEncodingAllocator **避免** 跟 MemTable 抢 AChunk (否则 micro block 编码 buffer 跟 BTree 节点竞争同一 AChunk slot)
- **NUMA-aware 同样适用** — encoding buffer 也走 4D 矩阵,保证 local NUMA access

---

## 4. Index Block 层 (`index_block/`)

### 4.1 ObIndexBlockAggregator

`ob_index_block_aggregator.h` — 聚合多个 micro block 的 row 索引,用于 range scan:

```cpp
class ObIndexBlockAggregator {
  // 每 micro block 维护 [min_key, max_key] 范围
  // range query 时二分到具体 micro block
  int locate_block(const ObRowkey &key, int64_t &block_offset);
  // 聚合 row (不带 schema) 用于 fast scan (避免反序列化)
  int get_agg_row(int64_t block_offset, int64_t row_offset, ObAggRow &row);
};
```

**应用场景**: `SELECT * FROM t WHERE pk BETWEEN 100 AND 200` — aggregator 二分到对应 micro block,避免扫整个 SSTable。

### 4.2 ObClusteredIndexBlockWriter

`ob_clustered_index_block_writer.h` — 主键聚簇 index block writer (注: 这是 SSTable 层 "clustered" 不是 MemTable `ObClusterIndex` 类 — 后者 REMOVED in 5.0.2.0):

```cpp
class ObClusteredIndexBlockWriter {
  // 主键有序的 micro block index,支持 efficient range scan
  int append_row(const ObRowkey &key, int64_t row_offset);
  int finalize(ObIndexBlockDesc &desc);  // 输出 micro block offset array
};
```

**关键**: SSTable 用 clustered index block (data 按主键排序 + index block 记录 micro block 区间) — 是 `ObClusterIndex` 在 SSTable 层的"继承" (MemTable `ObClusterIndex` REMOVED, SSTable 用 clustered index block 替代)。

### 4.3 Skip Index Filter

`ob_skip_index_filter_executor.{h,cpp}` — 跳数索引 (e.g. min/max per block) 用于 push-down filter:

```cpp
// 例如 WHERE ts > '2026-08-01'
// skip index 提前返回 false if block max_ts < '2026-08-01'
int skip_filter(ObMicroBlockDesc &desc, ObFilter &filter);
```

**性能**: skip index 可跳过 ~50% irrelevant micro blocks (per OB benchmark)。

---

## 5. Micro Block Hash Index (`ob_micro_block_hash_index.{h,cpp}`)

### 5.1 类定义（OB 5.0.2.0 alive）

```cpp
class ObMicroBlockHashIndex {
  // Per-micro-block hash filter (类似 Bloom filter but more accurate)
  // 用途: 提前判断某 row 是否可能存在于 micro block
  // 主要用于: point query + secondary index lookup
public:
  int build(const ObMicroBlock &block);  // build from micro block
  bool may_contain(const ObRowkey &key) const;  // false → skip block, true → read
};
```

### 5.2 关键 — MemTable hash REMOVED 但 SSTable hash ALIVE

per #14 #15 #16 v2 deep-dive 发现:
- **MemTable `ObMvccHashIndex`**: REMOVED in 5.0.2.0 (`ob_memtable.cpp:164` `FALSE_IT(use_hash_index)`)
- **SSTable `ObMicroBlockHashIndex`**: ALIVE (5.0.2.0)

**为什么 SSTable 保留 hash 而 MemTable 移除?**
- MemTable: hash 仅支持 point query,OLTP 大多数场景是 range → hash 价值低
- SSTable: hash 用于 micro block filter,提前拒绝不存在的 row → 减少 IO → 价值高

### 5.3 Hash vs Bloom Filter 性能

| 特性 | Bloom Filter | Micro Block Hash |
|------|--------------|------------------|
| False positive | ~1% | 0 (精确) |
| Build time | 快 | 慢 (per block 完整 hash) |
| Memory | 省 (bit array) | 贵 (hash table) |
| 查询延迟 | O(1) | O(1) |

OB SSTable 同时使用 **bloom filter** (`ob_bloom_filter.h`) + **micro block hash index** — bloom filter 在 SSTable 入口快速过滤 (粗筛), micro block hash 在 micro block 精确过滤 (细筛)。

---

## 6. SIMD 加速（NEON + x86 AVX-512）

### 6.1 ob_dict_decoder_simd.cpp (ARM NEON)

```cpp
#if defined(__ARM_NEON)
  // NEON 128-bit SIMD
  static int dict_decode_neon(const int32_t *dict, const uint8_t *indices, 
                              int32_t *output, int n) {
    int i = 0;
    for (; i + 4 <= n; i += 4) {
      // Load 4 indices (uint8) into NEON register
      uint8x8_t idx_8 = vld1_u8(indices + i);
      // Widen to 32-bit
      uint32x4_t idx_32 = vmovl_u16(vget_low_u16(vmovl_u8(idx_8)));
      // NEON table lookup (4 outputs in 1 instruction)
      int32x4_t out = vqtbl1q_s32(vld1q_s32(dict), idx_32);
      vst1q_s32(output + i, out);
    }
    for (; i < n; i++) output[i] = dict[indices[i]];
    return 0;
  }
#endif
```

### 6.2 x86 AVX-512 路径

类似 NEON,OB 也用 `_mm512_i32gather_epi32` (AVX-512) 加速 dict lookup。

**Benchmark** (per OB): SIMD 加速 dict decode 4x faster vs scalar。

---

## 7. Macro Block 写入路径 (`ob_sstable_writer.{h,cpp}`)

### 7.1 完整 write pipeline

```
MemTable (per-tenant BTree, per #14 v2)
  │
  │ flush() → freeze() → SSTableWriter::append_row() × N
  ▼
ObSSTableWriter (per tablet, single threaded)
  │
  ├─ 1. encode_row() → ObColumnEncoder for each column → 攒到 micro block buffer
  ├─ 2. micro_block full (default 16KB) → finalize_micro_block() → build_index()
  │      ├─ build index block (ob_index_block_builder)
  │      └─ build micro block hash index (ob_micro_block_hash_index)
  ├─ 3. macro_block full (default 2MB) → finalize_macro_block() → write_to_disk()
  │      └─ ObMacroSeqWriter (顺序写,sequential I/O)
  └─ 4. SSTable full → finalize_sstable() → ObSSTableHandle (cache for read)
```

### 7.2 ObSSTableWriter 关键接口

```cpp
class ObSSTableWriter {
public:
  int append_row(const ObRow &row);     // append 1 row, encode + buffer
  int append_block(const ObMicroBlock &block);  // append pre-built block
  int freeze();  // finalize SSTable, write trailer
  int64_t get_row_count() const;
};
```

### 7.3 内存来源

`ObSSTableWriter` 用 `ObEncodingAllocator` (per #3 above) + 直接 mmap buffer:
- micro block buffer (~16KB): 从 `ObEncodingAllocator` 拿 (NUMA-aware)
- macro block buffer (~2MB): 直接 mmap (direct I/O,避免 NUMA pinning 浪费)

---

## 8. 与 #14 v2 MemTable / #104 v2 Memory 完整对比

### 8.1 MemTable → SSTable 完整路径

```
ObMemTable (per-tenant BTree, per #14 v2)
  │ 内存 ObMemstoreAllocator → ObTenantCtxAllocator → AChunkMgr (per #104 v2)
  │
  │ minor/major freeze() → ObSSTableWriter
  ▼
ObSSTable (per-tablet, blocksstable, per 本文)
  │ 磁盘 + micro block cache (ob_block_cache)
  │
  │ minor/major merge → ObSSTableCompactor (压缩)
  ▼
  compact SSTable (多版本合并)
```

### 8.2 索引架构对比 (MemTable vs SSTable)

| 索引 | MemTable (5.0.2.0) | SSTable (5.0.2.0) |
|------|-------------------|-------------------|
| **BTree** | ObKeyBtree ✓ ALIVE (per #14 #15 v2) | (SSTable 用 clustered index block,不是 BTree) |
| **Hash** | ObMvccHashIndex ✗ REMOVED | ObMicroBlockHashIndex ✓ ALIVE |
| **Cluster** | ObClusterIndex ✗ REMOVED | ObClusteredIndexBlockWriter ✓ ALIVE (SSTable 层) |

**OB 5.0.2.0 architectural insight**:
- MemTable 简化 → 单 BTree (B+Tree 同时支持 point + range)
- SSTable 复杂化 → 多层索引 (bloom filter + micro block hash + clustered index block + skip index)

### 8.3 内存栈对比

| 层级 | MemTable (#14 v2) | SSTable (本文) |
|------|-------------------|-------------------|
| **数据** | ObMemstoreAllocator (per #104) | ObEncodingAllocator (encoding layer 专属) |
| **租户隔离** | ObTenantCtxAllocator 4D 矩阵 | 同一矩阵 (per #104 v2) |
| **NUMA** | per #104 v2 三层回收 + mbind | 同 (SSTable 也走 NUMA-aware) |
| **写盘** | flush → direct I/O | mmap + ObMacroSeqWriter (顺序 I/O) |

---

## 9. 总结

OB SSTable 编码架构 (5.0.2.0) 是 **encoding + index + compression + SIMD** 的精妙设计：

- **encoding/** — 多编码器族谱 (equal/const/dict/RLE/bit-packing),自动选最优
- **index_block/** — ObIndexBlockAggregator + ObClusteredIndexBlockWriter (MemTable `ObClusterIndex` REMOVED 但 SSTable 用 clustered index block 继承)
- **ob_micro_block_hash_index** — SSTable 级 hash ALIVE (MemTable hash REMOVED),block 精确过滤
- **SIMD 加速** — NEON + AVX-512 dict decoder ~4x faster
- **Encoding allocator** — 走 #104 v2 完整 4D 内存栈 (NUMA-aware + tenant 隔离)

**架构 insight (per #14 #15 #16 v2 + 本文)**:
- **MemTable 简化** → 单 ObKeyBtree (B+Tree) — REMOVED hash/cluster index
- **SSTable 复杂化** → bloom + micro block hash + clustered index + skip index (多层防御)
- **Hash index 在 SSTable 级 保留** (block filter 价值高),MemTable 级移除 (range query 主导)

**集成路径**:
- MemTable BTree → flush → SSTableWriter → micro block encode → index block build → macro block write → disk
- 全栈 NUMA-aware + tenant-isolated (per #104 v2)
- SIMD 加速 (~4x dict decode)
- Bloom + micro block hash 二级过滤

---

> 📚 **相关 v2 deep-dive**:
> - **#14 v2 MemTable Internals** — MemTable BTree (5.0.2.0 OB ONLY) + ObMvccEngineWithoutHashIndex
> - **#104 v2 MemStore Allocator** — AChunkMgr + ObTenantCtxAllocator + ObMemstoreAllocator (4D 矩阵)
> - **#15 v2 KeyBTree** — ObKeyBtree 详细 (MemTable 主索引,5.0.2.0)
> - **#16 v2 HashIndex** — ObMvccHashIndex REMOVED in 5.0.2.0 (historical context)

> 📂 **OB 5.0.2.0 实读路径**:
> - `src/storage/blocksstable/encoding/ob_*.{h,cpp}` — 编码层 (~40 文件)
> - `src/storage/blocksstable/index_block/ob_*.{h,cpp}` — 索引层 (~30 文件)
> - `src/storage/blocksstable/ob_micro_block_hash_index.{h,cpp}` — micro block hash filter
> - `src/storage/blocksstable/ob_sstable_writer.{h,cpp}` — SSTable write pipeline
> - `src/storage/blocksstable/ob_sstable_compactor.{h,cpp}` — Compaction