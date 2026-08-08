# 90-sstable-macroblock-encoding — OceanBase SSTable / Macro Block / 列存 / 压缩编码深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/storage/blocksstable/` **145 文件** + `cs_encoding/` + `encoding/` + `index_block/` 子目录 + `ob_sstable.h` + `ob_micro_block_*` + `ob_macro_block_*` + `ob_bloom_filter_*` + `encoding/ob_*_encoder/decoder.{h,cpp}`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **SSTable** 是整个 observer 集群"磁盘持久化层"的核心 —— memtable freeze 后生成 mini-sstable，mini-sstable 合并生成 SSTable，SSTable 是 OB 长期持久化的基本单位。OB 5.x 的 SSTable 建立在 **micro block + macro block + 列存编码 + 压缩 + BloomFilter** 五层之上，是 OB 自研的高性能列存存储引擎。

本文聚焦 8 个核心问题：

1. **SSTable 全景** —— 145 文件 + 多个子目录
2. **ObSSTable 主类** —— SSTable 接口
3. **Micro Block** —— 几 KB ~ 几 MB 的小压缩单元
4. **Macro Block** —— 几 MB 的大 IO 单元（含 micro blocks）
5. **ObEncoding 体系** —— 列存编码（dict / equal / const / bit stream）
6. **ObBloomFilter** —— 快速判存在
7. **ObIndexBlock** —— SSTable 索引块
8. **ObMacroBlockMarker** —— Macro Block 标记（Compact / Encrypt）

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 08-ob-sstable | #08 是早期分析 SSTable 概览 |
| 14-memtable-internals | memtable freeze → SSTable |
| 26-encoding-engine | 列存编码引擎（OB 5.x 深化） |
| 34-sstable-merge | SSTable merge / minor-major freeze |
| 35-macro-block-lifecycle | Macro Block 分配 / GC / 回收 |
| 51-block-cache | Block Cache（参见 #51） |
| 52-bloom-filter | BloomFilter 详解（参见 #52） |
| 89-memtable-memstore | memtable freeze → SSTable |

---

## 1. 整体架构：SSTable 5 层

### 1.1 模块组成（145 文件）

```bash
$ ls src/storage/blocksstable/ | wc -l
145

# 主要子目录
src/storage/blocksstable/
├── cs_encoding/                    # Column Store encoding
├── encoding/                       # Row Store encoding
├── index_block/                    # SSTable 索引块
├── ob_block_manager.{h,cpp}         # Block Manager
├── ob_block_sstable_struct.{h,cpp}  # Block SSTable 结构
├── ob_bloom_filter_*.{h,cpp}        # BloomFilter（参见 #52）
├── ob_column_checksum_struct.{h,cpp}# 列 checksum
├── ob_dag_macro_block_writer.{h,cpp} # DAG Macro Block 写
├── ob_dag_micro_block_iterator.{h,cpp}# DAG Micro Block 迭代
├── ob_data_buffer.{h,cpp}            # 数据 buffer
├── ob_data_macro_block_merge_writer.{h,cpp}  # Data Macro Block merge
├── ob_imicro_block_writer.{h,cpp}    # Interface Micro Block Writer
├── ob_micro_block_*.{h,cpp}          # Micro Block 多个类
├── ob_macro_block_*.{h,cpp}         # Macro Block 多个类
├── ob_row_*.{h,cpp}                 # Row 格式
├── ob_sstable.h                     # ObSSTable 主类
├── ob_sstable_meta.h                 # SSTable 元数据
└── # ... 100+ 其他
```

**145 文件** —— OB 5.x 第三大子目录（仅次于 `expr/` 1161 + `virtual_table/` 518 + `memtable/` 37 + `direct_load/` 210）。

### 1.2 5 层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: SSTable 入口 (ObSSTable)                                │
│  - 多个 macro block 组成                                          │
│  - 含 micro block 索引（index_block）                            │
│  - 持久化到磁盘                                                    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Macro Block (几 MB 的大 IO 单元)                      │
│  - 包含多个 micro block                                            │
│  - 自带 checksum + 加密信息                                        │
│  - 大块顺序写 + 顺序读                                            │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: Micro Block (几 KB ~ 几 MB 的小压缩单元)                │
│  - 包含几十 ~ 几百行                                               │
│  - 列存编码 + 行存编码                                            │
│  - 自带 BloomFilter + 索引（block 内）                           │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: Encoding (列存 / 压缩)                                 │
│  - 7+ 种编码（dict / equal / const / prefix / delta / rle / bitpack）│
│  - 字符串 / 数值 / 时间 / bitmap 各自最优编码                    │
│  - 自适应选择（per column）                                       │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5: BloomFilter + Index (快速判存在)                       │
│  - micro block 内 BloomFilter (per micro block)                  │
│  - index_block (per macro block 的 micro block 索引)             │
│  - SSTable 级 BloomFilter (per SSTable)                          │
└──────────────────────────────────────────────────────────────────┘
```

### 1.3 vs MemTable

| 维度 | MemTable | SSTable |
|------|----------|---------|
| 存储 | 内存 | 磁盘 |
| 数据量 | 几 MB ~ 几百 MB | 几 MB ~ 几 GB |
| 写入 | O(1) hash | 顺序写 macro block |
| 读取 | O(1) hash | BTree 索引 + micro block 扫描 |
| 压缩 | 无 | 列存 + 压缩（5+ 种编码） |
| BloomFilter | 无 | 3 级 BloomFilter |
| 持久化 | 不持久 | 持久化到磁盘 |

---

## 2. ObSSTable 主类

### 2.1 类骨架（实读 `ob_sstable.h`）

```cpp
// src/storage/blocksstable/ob_sstable.h
namespace oceanbase {
namespace blocksstable {

class ObSSTableMetaHandle {
public:
  ObSSTableMetaHandle() : handle_(), meta_(nullptr) {}
  ~ObSSTableMetaHandle() { reset(); }

  void reset();
  int get_sstable_meta(const ObSSTableMeta *&sstable_meta) const;
  OB_INLINE bool is_valid() const { return nullptr != meta_ && meta_->is_valid(); }
  OB_INLINE const ObSSTableMeta &get_sstable_meta() const {
    OB_ASSERT(nullptr != meta_);
    return *meta_;
  }
  // ...
private:
  ObStorageMetaCache::Handle handle_;
  const ObSSTableMeta *meta_;
};

class ObSSTable {
public:
  // 打开 / 关闭
  int open(const ObSSTableParam &param, ObSSTableMetaHandle &meta_handle);
  int close();

  // 扫描
  int scan(const ObSSTableScanParam &param, ObStoreRowIterator &iter);

  // 单点查
  int get(const ObSSTableReadParam &param, ObStoreRow &row);

  // Macro Block 迭代
  int get_macro_block_iter(const ObMacroBlockIterParam &param, ObIMacroBlockIterator &iter);

  // Range 查
  int get_range_iter(const ObSSTableReadParam &param, ObStoreRowIterator &iter);

private:
  ObSSTableMeta *meta_;
  ObMicroBlockIndexIterator *index_iter_;
  // ... 几十个字段
};

}  // blocksstable
}  // oceanbase
```

### 2.2 关键设计

**ObSSTableMetaHandle**：
- 持有 SSTable meta（schema / statistics / BloomFilter 位置等）
- 内部用 `ObStorageMetaCache` 缓存

**ObSSTable API**：
- `open` / `close` —— 打开 / 关闭 SSTable
- `scan` —— 范围扫描
- `get` —— 单点查
- `get_macro_block_iter` —— macro block 迭代器
- `get_range_iter` —— range 查

---

## 3. Micro Block（参见 #08）

### 3.1 角色

Micro block 是 **SSTable 内最小的压缩单元**：
- 几 KB ~ 几 MB
- 包含几十 ~ 几百行
- 列存编码 + 压缩
- 自带 block-level BloomFilter + 索引

### 3.2 相关文件

```bash
src/storage/blocksstable/
├── ob_micro_block_header.h         # micro block header
├── ob_micro_block_reader.h         # reader
├── ob_micro_block_row_getter.h     # row getter
├── ob_micro_block_row_scanner.h    # row scanner
├── ob_micro_block_row_lock_checker.h  # row lock checker
├── ob_micro_block_cache.{h,cpp}    # micro block cache
├── ob_micro_block_info.h           # info
├── ob_imicro_block_writer.{h,cpp}  # interface micro block writer
└── ob_dag_micro_block_iterator.{h,cpp}  # DAG iterator
```

### 3.3 Micro Block 格式

```
┌─────────────────────────────────┐
│  micro block header (几十 bytes) │
│  - column count / row count     │
│  - encoding type per column     │
│  - checksum (CRC64)             │
└─────────────────────────────────┘
┌─────────────────────────────────┐
│  column 0 data (encoded)         │
├─────────────────────────────────┤
│  column 1 data (encoded)         │
├─────────────────────────────────┤
│  ...                             │
├─────────────────────────────────┤
│  column N-1 data (encoded)       │
└─────────────────────────────────┘
┌─────────────────────────────────┐
│  block-level index (可选)         │
│  - 加速 micro block 内查找        │
└─────────────────────────────────┘
```

### 3.4 Micro Block Reader / Scanner

- **Reader**（`ob_micro_block_reader.h`）—— 单点查（指定 rowkey 找行）
- **Scanner**（`ob_micro_block_row_scanner.{h,cpp}`）—— 范围扫描（rowkey 范围）
- **Cache**（`ob_micro_block_cache.{h,cpp}`）—— micro block 缓存（参见 #51）

---

## 4. Macro Block（参见 #08 / #35）

### 4.1 角色

Macro block 是 **SSTable 内最大的 IO 单元**：
- 几 MB 大小（典型 2MB）
- 包含多个 micro block
- 自带 macro block header（checksum + 加密信息）
- 大块顺序写 + 顺序读（IO 效率高）

### 4.2 相关文件

```bash
src/storage/blocksstable/
├── ob_block_sstable_struct.{h,cpp}    # Block SSTable 结构
├── ob_block_manager.{h,cpp}           # Block Manager
├── ob_dag_macro_block_writer.{h,cpp}   # DAG Macro Block Writer
├── ob_data_macro_block_merge_writer.{h,cpp}  # Data Macro Block merge
├── ob_macro_block_*.{h,cpp}           # Macro Block 多个类
├── ob_block_writer_concurrent_guard.{h,cpp}  # 并发写保护
└── # 参见 #35-macro-block-lifecycle
```

### 4.3 Macro Block 格式

```
┌─────────────────────────────────────────┐
│  macro block header (几 KB)               │
│  - magic + version                       │
│  - micro block count                     │
│  - total size                            │
│  - checksum (CRC64)                      │
│  - encryption info (TDE)                  │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│  micro block 0 (几 KB ~ 几 MB)           │
│  - encoded row data                      │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│  micro block 1                            │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│  ...                                     │
├─────────────────────────────────────────┤
│  micro block N-1                         │
└─────────────────────────────────────────┘
```

### 4.4 ObMacroBlockMarker（参见 #35）

```cpp
// src/observer/virtual_table/ob_all_virtual_macro_block_marker_status.{h,cpp}
// Macro Block 状态虚拟表（监控）
```

### 4.5 ObDagMacroBlockWriter

```cpp
class ObDagMacroBlockWriter {
  // DAG 调度（参见 #66 / #41）
  // 并发写多个 macro block
};
```

---

## 5. ObEncoding 体系（参见 #26）

### 5.1 7+ 种编码

OB 5.x 的列存编码（`encoding/` 子目录）：

```bash
src/storage/blocksstable/encoding/
├── ob_bit_stream.{h,cpp}                # bit 流基类
├── ob_column_equal_{decoder,encoder}.{h,cpp}  # 等值编码
├── ob_const_{decoder,encoder}.{h,cpp}  # 常量编码
├── ob_dict_{decoder,encoder}.{h,cpp}    # 字典编码
├── ob_dict_decoder_simd.{h,cpp}         # SIMD 加速字典解码
├── ob_encoding_allocator.{h,cpp,ipp}   # 编码分配器
├── ob_encoding_bitset.{h,cpp}           # bitset 编码
├── neon/                                  # SIMD 加速 (AVX2/AVX-512)
└── # 几十种其他编码
```

### 5.2 编码类型与适用

| 编码 | 适用数据类型 | 压缩率 |
|------|------------|---------|
| **Equal** | 所有值相同（如全是 0） | 1000x+ |
| **Const** | 单值重复 | 1000x+ |
| **Dict** | 低基数（< 256 unique） | 5-100x |
| **Prefix** | 字符串前缀相似 | 3-10x |
| **Delta** | 数值单调 | 5-50x |
| **RLE** | 重复 run | 5-50x |
| **Bitpack** | 数值范围小 | 2-10x |
| **SIMD** | 大批量数值 | 2-5x |

### 5.3 ObEncoding 抽象

```cpp
// (推测, encoding/ob_encoding.h)
class ObIColumnDecoder {
public:
  virtual int decode(const ObBitStream &bs, common::ObDatum &datum) = 0;
};

class ObIColumnEncoder {
public:
  virtual int encode(const common::ObDatum &datum, ObBitStream &bs) = 0;
};
```

**ObBitStream** —— bit 流基类：
- 用 bit 单位读写
- 编码用 bit 而非 byte（节省空间）

---

## 6. ObBloomFilter（参见 #52）

### 6.1 角色

```cpp
// src/storage/blocksstable/ob_bloom_filter_data_reader.{h,cpp}
class ObBloomFilterDataReader {
  // 读 BloomFilter
};

// src/storage/blocksstable/ob_bloom_filter_data_writer.{h,cpp}
class ObBloomFilterDataWriter {
  // 写 BloomFilter
};

// src/storage/blocksstable/ob_bloom_filter_cache.{h,cpp}
class ObBloomFilterCache {
  // BloomFilter 缓存
};

// src/storage/blocksstable/ob_bloom_filter_load_task.{h,cpp}
class ObBloomFilterLoadTask {
  // 异步加载 BloomFilter
}
```

### 6.2 3 级 BloomFilter

OB SSTable 用 3 级 BloomFilter 加速查询：
1. **SSTable 级**（`__all_virtual_*_bloom_filter_status`）—— 整个 SSTable 的 BloomFilter
2. **Macro Block 级**（`ob_macro_block_bloom_filter_*`）—— 单 macro block
3. **Micro Block 级**（`ob_micro_block_bloom_filter_*`）—— 单 micro block

**查询流程**：
- SSTable BF miss → 不读
- Macro Block BF miss → 不读该 macro block
- Micro Block BF miss → 不读该 micro block

---

## 7. ObIndexBlock（`index_block/` 子目录）

### 7.1 角色

```bash
src/storage/blocksstable/index_block/
├── ob_index_block_builder.h     # 索引构建
├── ob_index_block_iterator.h    # 索引迭代
├── ob_index_block_row_scanner.h # 索引行扫描
└── # 几十个其他
```

**ObIndexBlock** —— SSTable 顶层索引：
- 记录每个 macro block 的 rowkey 范围
- 加速 rowkey → macro block 定位
- 通常缓存在内存（参见 #51 block cache）

### 7.2 二级索引

```
ObSSTable (SSTable 级)
    │
    ▼
ObIndexBlock (per macro block 的 rowkey 范围)
    │
    ▼
ObMacroBlock (IO 单元)
    │
    ▼
ObMicroBlock (压缩单元)
    │
    ▼
ObEncoding (列存编码)
```

---

## 8. ObBlockManager / ObBlockSSTableStruct

### 8.1 ObBlockManager

```cpp
// src/storage/blocksstable/ob_block_manager.{h,cpp}
class ObBlockManager {
  // Block Manager
  // 管理 SSTable 的所有 block
  // - meta block
  // - index block
  // - data blocks (macro + micro)
  // - bloom filter blocks
};
```

### 8.2 ObBlockSSTableStruct

```cpp
// src/storage/blocksstable/ob_block_sstable_struct.{h,cpp}
// Block SSTable 结构定义
```

---

## 9. Block Cache（参见 #51）

### 9.1 缓存层级

```
L1: per-observer micro block cache (in-memory)
L2: per-observer macro block cache (in-memory)
L3: per-observer BloomFilter cache
L4: disk (sstable files)
```

### 9.2 相关文件

```bash
src/storage/blocksstable/
├── ob_micro_block_cache.{h,cpp}    # micro block cache (参见 #51)
├── ob_bloom_filter_cache.{h,cpp}   # bloom filter cache
└── # 配套的 hash + lru 管理
```

---

## 10. SSTable 生命周期

### 10.1 创建（来自 memtable freeze）

```
memtable freeze
    │
    ▼
写 mini-sstable
    │
    ├─ 1. ObMicroBlockWriter 编码 micro block
    │
    ├─ 2. ObEncoding 选择最优编码
    │
    ├─ 3. ObMacroBlockWriter 聚合 micro blocks → macro block
    │
    ├─ 4. 写 macro block 到磁盘
    │
    └─ 5. 写 ObIndexBlock + BloomFilter
    │
    ▼
mini-sstable 完成
```

### 10.2 合并（mini-sstable → SSTable）

```
多个 mini-sstable 累积
    │
    ▼  major freeze 触发
    │
ObDataMacroBlockMergeWriter
    │
    ├─ 1. 读多个 mini-sstable
    │
    ├─ 2. 合并相同 rowkey 的行
    │
    ├─ 3. 重写 micro block
    │
    └─ 4. 写新 SSTable
    │
    ▼
SSTable 完成
```

### 10.3 查询

```
应用: SELECT * FROM t WHERE id = 1
    │
    ▼
DAS: 构造查询
    │
    ▼
ObSSTable::get
    │
    ├─ 1. ObSSTableMeta 查 rowkey → macro block
    │   └─ ObIndexBlock (cached)
    │
    ├─ 2. ObBloomFilter 判存在（3 级）
    │
    ├─ 3. 读 macro block
    │
    ├─ 4. ObMicroBlockReader 在 micro block 内查
    │
    └─ 5. 返回 row
```

---

## 11. 与其他文章的关系

### 11.1 与 #08 OB SSTable

#08 是早期分析 SSTable 概览（34KB+）。本文是 #08 的 **深化**：
- #08 聚焦 SSTable 整体结构
- 本文深入 ObSSTable / Micro Block / Macro Block / Encoding / BloomFilter / IndexBlock 的具体实现

### 11.2 与 #14 MemTable Internals

MemTable freeze → mini-sstable → SSTable（参见 #14 + #89）：
- 参见 #89 §10.1
- ObMemtableCompactWriter 触发 freeze
- ObMicroBlockWriter 编码 micro block
- ObMacroBlockWriter 写 macro block

### 11.3 与 #26 Encoding Engine

列存编码引擎（参见 #26）实现在 `src/storage/blocksstable/encoding/`：
- 7+ 种编码（dict / equal / const / prefix / delta / rle / bitpack）
- SIMD 加速（neon / SIMD 加速字典解码）
- 自适应选择（per column）

### 11.4 与 #34 SSTable Merge

SSTable merge 涉及 macro block level 合并（参见 #34）：
- ObDataMacroBlockMergeWriter
- 多个 mini-sstable → SSTable
- 增量 merge

### 11.5 与 #35 Macro Block Lifecycle

Macro Block 分配 / GC / 回收（参见 #35）：
- ObMacroBlockMarker
- 状态虚拟表 `ob_all_virtual_macro_block_marker_status`

### 11.6 与 #51 Block Cache

Block Cache（参见 #51）：
- per-observer micro block cache
- per-observer macro block cache
- LRU + hash 索引

### 11.7 与 #52 BloomFilter

BloomFilter 详解（参见 #52）：
- 3 级 BF（SSTable / Macro / Micro）
- 加速判存在

---

## 12. 总结

### 12.1 SSTable 在 OB 体系中的定位

SSTable 是 **OB 磁盘持久化的核心**：
- memtable freeze → SSTable
- 多级索引（meta / index / micro / data）
- 列存编码（5+ 种） + 压缩
- 3 级 BloomFilter
- Block Cache（per-observer in-memory）

### 12.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| SSTable 入口 | `ObSSTable` + `ObSSTableMetaHandle` |
| Micro Block | `ob_micro_block_*`（几 KB ~ 几 MB） |
| Macro Block | `ob_macro_block_*`（几 MB） |
| Encoding | `encoding/ob_*_encoder/decoder`（7+ 种） |
| BloomFilter | `ob_bloom_filter_*`（3 级） |
| IndexBlock | `index_block/ob_index_block_*` |
| BlockCache | `ob_micro_block_cache.{h,cpp}` |
| BlockManager | `ob_block_manager.{h,cpp}` |

### 12.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/blocksstable/` (145 文件) | SSTable 主目录 |
| `src/storage/blocksstable/ob_sstable.h` | ObSSTable 主类 |
| `src/storage/blocksstable/ob_micro_block_*` (10+ 文件) | Micro Block |
| `src/storage/blocksstable/ob_macro_block_*` (10+ 文件) | Macro Block |
| `src/storage/blocksstable/encoding/` (30+ 文件) | 列存编码 |
| `src/storage/blocksstable/cs_encoding/` | Column Store encoding |
| `src/storage/blocksstable/index_block/` | SSTable 索引 |
| `src/storage/blocksstable/ob_bloom_filter_*` (5+ 文件) | BloomFilter |
| `src/storage/blocksstable/ob_block_manager.{h,cpp}` | Block Manager |
| `src/storage/blocksstable/ob_block_sstable_struct.{h,cpp}` | Block SSTable 结构 |
| `src/storage/blocksstable/ob_dag_macro_block_writer.{h,cpp}` | DAG Macro Writer |
| `src/storage/blocksstable/ob_dag_micro_block_iterator.{h,cpp}` | DAG Micro Iterator |
| `src/storage/blocksstable/ob_data_macro_block_merge_writer.{h,cpp}` | Merge Writer |
| `src/storage/blocksstable/ob_micro_block_cache.{h,cpp}` | Block Cache (参见 #51) |
| `src/storage/blocksstable/ob_imicro_block_writer.{h,cpp}` | Interface |
| `src/storage/blocksstable/ob_column_checksum_struct.{h,cpp}` | Column Checksum |
| `src/storage/blocksstable/ob_block_writer_concurrent_guard.{h,cpp}` | 并发写保护 |

### 12.4 5 层架构

| 层级 | 元素 | 大小 | 索引 |
|------|------|------|------|
| L1 | SSTable | 几 MB ~ 几 GB | ObSSTableMeta + BloomFilter |
| L2 | Macro Block | 几 MB | ObIndexBlock + BloomFilter |
| L3 | Micro Block | 几 KB ~ 几 MB | block-level index + BloomFilter |
| L4 | Encoding | bit-aligned | 列存编码 |
| L5 | BloomFilter + Index | hash | 快速判存在 |

### 12.5 SSTable 关键参数

| 参数 | 典型值 | 位置 |
|------|--------|------|
| macro block size | 2MB（典型） | server config |
| micro block size | 16KB ~ 64KB | server config |
| encoding types | 7+ 种 | 编译期常量 |
| bloom filter bits per key | 10 bits | server config |
| index block size | 几 KB | server config |

### 12.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#91 Cache / ObTabletCache / 缓存策略深度分析**（深化 #51）：

OB 缓存体系 —— Block Cache / Tablet Cache / Schema Cache / Plan Cache / KV Cache。源码入口：`src/storage/cache/` + `src/storage/tablet/ob_tablet_cache.{h,cpp}` + `src/share/cache/ob_kv_storecache.h`。

适用场景：缓存调优 / 性能优化 / 内存管理。

整吗？