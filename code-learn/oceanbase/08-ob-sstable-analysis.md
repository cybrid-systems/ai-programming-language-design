# 08 — SSTable 存储格式与块编码

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前面 7 篇文章从 MVCC 行数据逐步上探：Row 结构 → Iterator 迭代 → Write Conflict 冲突管理 → Callback 回调链 → Compact 行级压缩 → Memtable Freeze 冻结 → LogStream 与 LS Tree 架构。现在到达持久化存储的最底层——**SSTable 的磁盘格式**。

如果说 MVCC 层是存储引擎的**细胞**，LogStream 是**组织器官**，那么 SSTable 就是**骨骼**——数据最终以文件形式固化到磁盘，由 SSTable 定义其物理布局。

### SSTable 在整个架构中的位置

```
┌──────────────────────────────────────────────────────────────┐
│                        SQL Layer                              │
├──────────────────────────────────────────────────────────────┤
│                    Transaction Layer                          │
├──────────────────────────────────────────────────────────────┤
│                   LogStream + LS Tree                         │
│  ObLS → ObTablet → ObTabletTableStore                        │
│       ┌───────────────┐                                       │
│       │  SSTable Set   │   ← 多个 SSTable 组成分层             │
│       │  L0 L1 L2 L3  │                                       │
│       └───────┬───────┘                                       │
│               ▼                                                │
│       ┌───────────────┐                                       │
│       │  SSTable 文件  │   ← 本文焦点                          │
│       │  磁盘物理格式   │                                       │
│       └───────────────┘                                       │
├──────────────────────────────────────────────────────────────┤
│                   Block Manager                               │
│              ObBlockManager + 异步 I/O                          │
└──────────────────────────────────────────────────────────────┘
```

### 核心概念速览

| 概念 | 对应类/结构 | 位置 | 典型大小 |
|------|-------------|------|----------|
| **Super Block** | `ObServerSuperBlock` | 文件头部 | 固定大小 |
| **Macro Block** | `ObDataMacroBlockMeta` | 物理块 | **2 MB**（默认） |
| **Micro Block** | `ObMicroBlockHeader` + 数据 | Macro Block 内的行组 | ~16-64 KB |
| **Index Tree** | `ObIndexBlockAggregator` | 两级索引 | 可变 |
| **Bloom Filter** | `ObBloomFilter` + `ObBloomFilterCache` | 可选块 | 按行数计算 |
| **Trailer** | 内联元信息 | 文件尾部 | 固定大小 |

---

## 1. SSTable 文件物理布局

SSTable 文件以定长 extent 方式组织。`ob_block_sstable_struct.h:48-56`（doom-lsp 确认）定义了各区域的 magic number：

```cpp
// ob_block_sstable_struct.h:48-56
const int32_t MICRO_BLOCK_HEADER_MAGIC     = 0x0AED0A05;
const int32_t BF_MACRO_BLOCK_HEADER_MAGIC  = 0x0AED0A06;
const int32_t BF_MICRO_BLOCK_HEADER_MAGIC  = 0x0AED0A07;
const int32_t SERVER_SUPER_BLOCK_MAGIC     = 0x0AED0A04;
const int32_t LINKED_MACRO_BLOCK_HEADER_MAGIC = 0x0AED0A08;
```

### 物理布局全景图

```
┌─────────────────────────────────────────────────────────────┐
│                      SSTable 文件                              │
├─────────────────────────────────────────────────────────────┤
│ Super Block (ObServerSuperBlock)                             │
│ ├─ magic      = SERVER_SUPER_BLOCK_MAGIC     @ob_def.h:2544  │
│ ├─ format_version_                                         │
│ ├─ block_size_ = OB_DEFAULT_MACRO_BLOCK_SIZE = 2 MB         │
│ └─ file_id_                                                 │
├─────────────────────────────────────────────────────────────┤
│ Macro Block #1 (Data Block)                                  │
│ ├─ Macro Block Header                                        │
│ │   ├─ type_     (DATA_BLOCK / INDEX_BLOCK / BLOOM_FILTER)  │
│ │   ├─ size_     = 2 MB                                     │
│ │   ├─ checksum_                                             │
│ │   └─ micro_block_count_                                    │
│ ├─ ┌──────────────────────────────────────────────────────┐  │
│ │  │ Micro Block #1                                        │  │
│ │  │ ├─ ObMicroBlockHeader                                 │  │
│ │  │ │   ├─ magic_        = MICRO_BLOCK_HEADER_MAGIC       │  │
│ │  │ │   ├─ version_      = MICRO_BLOCK_HEADER_VERSION_3   │  │
│ │  │ │   ├─ header_size_  = sizeof(ObMicroBlockHeader)     │  │
│ │  │ │   ├─ header_checksum_                               │  │
│ │  │ │   ├─ column_count_ / rowkey_column_count_            │  │
│ │  │ │   ├─ row_count_    (包含的行数)                      │  │
│ │  │ │   ├─ row_store_type_ (FLAT / ENCODING / SELECTIVE)  │  │
│ │  │ │   ├─ original_length_ (压缩前大小)                   │  │
│ │  │ │   ├─ data_length_  / data_zlength_                  │  │
│ │  │ │   ├─ data_checksum_                                 │  │
│ │  │ │   ├─ compressor_type_                               │  │
│ │  │ │   └─ column_checksums_[column_count_]                │  │
│ │  │ ├─ Row Index Array (变长偏移数组)                       │  │
│ │  │ ├─ Row Data (编码后的行数据)                            │  │
│ │  │ └─ Hash Index (可选) @ob_micro_block_header.h:105      │  │
│ │  └──────────────────────────────────────────────────────┘  │
│ ├─ Micro Block #2                                            │
│ ├─ ...                                                        │
│ └─ Micro Block #N                                            │
├─────────────────────────────────────────────────────────────┤
│ Macro Block #2 ...                                           │
├─────────────────────────────────────────────────────────────┤
│ Index Tree Block(s)                                          │
│ ├─ Macro Index (二级索引)                                    │
│ │   ├─ macro_block_id                                        │
│ │   ├─ end_key (该 macro block 中最大 key)                   │
│ │   └─ micro_block_count                                     │
│ ├─ Micro Index (一级索引)                                    │
│ │   ├─ micro_block_offset                                    │
│ │   ├─ row_count                                             │
│ │   └─ end_key                                               │
│ └─ Skip Index Aggregation  @ob_index_block_aggregator.h      │
│     ├─ column_min / column_max (列级极值)                    │
│     ├─ column_null_count (列空值计数)                         │
│     └─ column_sum (列和值)                                   │
├─────────────────────────────────────────────────────────────┤
│ Bloom Filter Block (可选) @ob_bloom_filter_cache.h:31        │
│ ├─ macro_id_ (关联的 Macro Block ID)                         │
│ ├─ prefix_rowkey_len_                                       │
│ ├─ row_count_                                               │
│ ├─ nhash_ / nbit_ (布隆参数)                                 │
│ └─ bits_[nbit_] (bit 数组)                                   │
├─────────────────────────────────────────────────────────────┤
│ Trailer / SSTable Meta                                      │
│ ├─ ObSSTableBasicMeta @ob_sstable_meta.h:92                 │
│ │   ├─ row_count_ / occupy_size_ / original_size_            │
│ │   ├─ data_checksum_                                       │
│ │   ├─ data_macro_block_count_ / data_micro_block_count_    │
│ │   ├─ sstable_format_version_                              │
│ │   ├─ schema_version_                                      │
│ │   └─ upper_trans_version_ / max_merged_trans_version_     │
│ ├─ ObSSTableArray<ObMacroBlockInfo> macro_info_             │
│ └─ ObSSTableArray<ObColumnChecksum> column_ckm_struct_      │
└─────────────────────────────────────────────────────────────┘
```

### 核心常量的源码位置

```
OB_DEFAULT_MACRO_BLOCK_SIZE = 2 << 20  // 2MB
    → deps/oblib/src/lib/ob_define.h:1991

SERVER_SUPER_BLOCK_MAGIC = 0x0AED0A04
    → ob_block_sstable_struct.h:51

MICRO_BLOCK_HEADER_MAGIC = 0x0AED0A05
    → ob_block_sstable_struct.h:48
```

---

## 2. ObSSTable — SSTable 核心类

`ObSSTable` 类定义在 `ob_sstable.h:124`（doom-lsp 确认），它继承自 `ObSSTableBase`，采用引用计数管理生命周期。

### 2.1 核心成员

```cpp
// ob_sstable.h:404-439（doom-lsp 确认）
class ObSSTable {
  // ── 元数据缓存 ──
  ObSSTableMetaCache    meta_cache_;       // @L434
  // ── 元数据 ──
  ObMetaDiskAddr        addr_;             // @L432 — 元数据磁盘地址
  // ── 核心元数据 ──
  ObSSTableMetaHandle   meta_;             // @L439 — SSTable 元数据
  // ── 状态 ──
  bool                  valid_for_reading_; // @L436
  bool                  is_tmp_sstable_;    // @L437

  // ── 元数据缓存（内嵌） ──
  // ob_sstable.h:93-119（doom-lsp 确认）
  struct ObSSTableMetaCache {
    int64_t   version_;
    bool      has_multi_version_row_;
    SSTableCacheStatus status_;
    int64_t   data_macro_block_count_;     // @L102
    int64_t   nested_size_;                // @L103 — 通常=2MB
    int64_t   nested_offset_;              // @L104 — 偏移
    int64_t   total_macro_block_count_;    // @L105
    int64_t   total_use_old_macro_block_count_; // @L106
    int64_t   row_count_;                  // @L107
    int64_t   occupy_size_;                // @L108
    int64_t   max_merged_trans_version_;   // @L109
    int64_t   data_checksum_;              // @L111
    int64_t   upper_trans_version_;        // @L113
    ...
  };
};
```

### 2.2 关键接口

```cpp
// ob_sstable.h - doom-lsp 确认的关键方法

// ── 扫描与查询 ──
int scan(ObStoreCtx &, ...);              // @L151 — 范围扫描
int get(ObStoreCtx &, ...);               // @L156 — 单行点查
int multi_scan(ObStoreCtx &, ...);        // @L161 — 多范围扫描
int multi_get(ObStoreCtx &, ...);         // @L166 — 多行点查

// ── 块级扫描 ──
int scan_macro_block(ObStoreCtx &, ...);  // @L172 — 扫描单个 Macro Block
int scan_micro_block(ObStoreCtx &, ...);  // @L180 — 扫描单个 Micro Block
int scan_index(...);                      // @L194 — 索引扫描

// ── 布隆过滤 ──
bool bf_may_contain_rowkey(...);          // @L199 — 布隆过滤器查询

// ── 元数据 ──
GET_SSTABLE_META_DEFINE_FUNC(get_occupy_size);             // @L286
GET_SSTABLE_META_DEFINE_FUNC(get_total_macro_block_count); // @L288
ObMetaDiskAddr &get_meta();               // @L310
```

---

## 3. Macro Block — 物理块

Macro Block 是 SSTable 文件中的定长物理单元，**默认大小为 2MB**。

### 3.1 关键定义

```cpp
// deps/oblib/src/lib/ob_define.h:1991
const int64_t OB_DEFAULT_MACRO_BLOCK_SIZE = 2 << 20; // 2MB
```

Macro Block 相关结构在 `ob_block_sstable_struct.h` 和 `ob_macro_block_struct.h`（doom-lsp 确认）：

- `ObDataMacroBlockMeta` — `ob_macro_block_struct.h:22` — Macro Block 元信息
- `ObMacroBlocksWriteCtx` — `ob_macro_block_struct.h:23` — 批量写入上下文
- `ObMacroBlockHandle` — `ob_block_manager.h:43` — 块句柄
- `ObMacroBlockWriteInfo` — `ob_block_manager.h:96` — 写入 I/O 信息
- `ObMacroBlockReadInfo` — `ob_block_manager.h:128` — 读取 I/O 信息

### 3.2 Macro Block 的类型

Macro Block 根据用途分为几类：

```
┌──────────────┬─────────────────────┬──────────────────────────┐
│ 类型          │ Magic               │ 内容                      │
├──────────────┼─────────────────────┼──────────────────────────┤
│ DATA BLOCK   │ MICRO_BLOCK_HEADER  │ 行数据的 Micro Blocks     │
│ INDEX BLOCK  │ (less common)       │ Macro/Micro Index Tree    │
│ BLOOM FILTER │ BF_MACRO_BLOCK_HEADER │ Bloom Filter 位数组     │
│ LINKED BLOCK │ LINKED_MACRO_BLOCK  │ 共享引用（Compaction 复用） │
└──────────────┴─────────────────────┴──────────────────────────┘
```

### 3.3 ObBlockManager — Macro Block 生命周期

`ObBlockManager`（`ob_block_manager.h:178`，doom-lsp 确认）负责 Macro Block 的分配、读写、释放：

```cpp
// ob_block_manager.h:178-527 — 关键接口
class ObBlockManager {
  int alloc_block(ObMacroBlockHandle &);           // @L192 — 分配
  int async_read_block(ObMacroBlockReadInfo &);     // @L194 — 异步读
  int async_write_block(ObMacroBlockWriteInfo &);   // @L197 — 异步写
  int write_block(ObMacroBlockWriteInfo &);         // @L200 — 同步写
  int read_block(ObMacroBlockReadInfo &);           // @L203 — 同步读

  int64_t get_free_macro_block_count();             // @L211 — 空闲块数
  int64_t get_used_macro_block_count();             // @L212 — 已用块数

  // Mark-Sweep 回收
  int mark_and_sweep();                             // @L241
  void mark_sstable_blocks(...);                    // @L395 — 标记活跃块

  // 内部状态
  int64_t          default_block_size_;              // @L505 — 通常=2MB
  ObBlockMap       block_map_;                      // @L502 — 块位图
  ObIODevice      *io_device_;                      // @L519 — I/O 设备
};
```

`ObBlockManager` 采用 **mark-and-sweep 算法** 回收废弃的 Macro Block，通过定时任务 `MarkBlockTask`（`ob_block_manager.h:459`）周期性执行。

---

## 4. Micro Block — 行数据存储单元

Micro Block 是 SSTable 中最细粒度的行数据存储单元。每个 Macro Block 包含若干 Micro Blocks。

### 4.1 Micro Block Header

定义在 `ob_micro_block_header.h:24`（doom-lsp 确认），`ObMicroBlockHeader` 类通过固定大小的 header 描述一个 micro block 的元信息：

```cpp
// ob_micro_block_header.h:24-151 — doom-lsp 确认
class ObMicroBlockHeader {
  // ── 版本 ──
  static const int64_t MICRO_BLOCK_HEADER_VERSION_1 = 1;    // @L28
  static const int64_t MICRO_BLOCK_HEADER_VERSION_2 = 2;    // @L29
  static const int64_t MICRO_BLOCK_HEADER_VERSION_3 = 3;    // @L30
  static const int64_t MICRO_BLOCK_HEADER_VERSION_LATEST = 3; // @L31

  // ── 固定字段 ──
  int32_t magic_;                              // @L93 — 0x0AED0A05
  int32_t version_;                            // @L94
  int32_t header_size_;                        // @L95
  int32_t header_checksum_;                    // @L96

  int32_t column_count_;                       // @L97 — 总列数
  int32_t rowkey_column_count_;                // @L98 — Rowkey 列数

  // ── 标志位 union ──
  union {
    struct {
      bool  has_column_checksum_;              // @L101
      bool  has_string_out_row_;               // @L102
      bool  all_lob_in_row_;                   // @L103
      bool  contains_hash_index_;              // @L104 → 快速行定位
      int32_t hash_index_offset_from_end_;     // @L105
      bool  has_min_merged_trans_version_;     // @L106
      int16_t reserved16_;                     // @L107
    };
    int16_t flag16_;                           // @L109
  };

  int32_t row_count_;                          // @L111 — 行数
  int32_t row_store_type_;                     // @L112 — FLAT/ENCODING

  // ── 行索引与扩展信息 union ──
  union {
    struct {
      int8_t  row_index_byte_;                // @L115
      int8_t  extend_value_bit_;              // @L116
      int16_t reserved_;                      // @L117
    };
    struct {
      int8_t  single_version_rows_;           // @L120
      int8_t  contain_uncommitted_rows_;      // @L121
      int8_t  is_last_row_last_flag_;         // @L122
      int8_t  is_first_row_first_flag_;       // @L123
      int8_t  not_used_;                      // @L124
    };
    int32_t opt_;                              // @L126
  };

  // ── 列/压缩信息 ──
  union {
    int32_t var_column_count_;                // @L129
    struct {
      int8_t  compressor_type_;               // @L131 — 压缩算法
      bool    has_row_header_;                // @L132
      int16_t cs_reserved_;                   // @L133
    };
    int32_t opt2_;                             // @L135
  };

  // ── 偏移量 union ──
  union {
    int32_t row_index_offset_;                 // @L139
    int32_t row_data_offset_;                  // @L140
    int32_t row_offset_;                       // @L141
  };

  int32_t original_length_;                    // @L143 — 压缩前大小
  int64_t max_merged_trans_version_;           // @L144 — 最大合并版本
  int32_t data_length_;                        // @L145 — 解压后数据大小
  int32_t data_zlength_;                       // @L146 — 压缩后数据大小
  int32_t data_checksum_;                      // @L147 — 数据校验和

  // ── 列校验和 (变长) ──
  int32_t column_checksums_[];                 // @L149 — 每列一个
};
```

### 4.2 Micro Block 的物理布局

```
┌──────────────────────────────────────────────┐
│ ObMicroBlockHeader（固定大小）                   │
│   magic / version / header_size / checksum     │
│   column_count / row_count / row_store_type    │
│   data_length / data_zlength / data_checksum   │
│   compressor_type / original_length            │
│   column_checksums[...]                        │
├──────────────────────────────────────────────┤
│ Row Index Array（变长）                         │
│   每行 → 该行在 row_data 中的偏移               │
├──────────────────────────────────────────────┤
│ Row Data（编码后的列值）                         │
│   由 row_store_type 决定编码方式：              │
│   • FLAT: ObMicroBufferFlatWriter             │
│   • ENCODING: ObMicroBlockEncoder             │
│   • SELECTIVE: 混合模式                        │
├──────────────────────────────────────────────┤
│ Hash Index（可选） @ob_micro_block_header.h:105 │
│   快速行定位（contains_hash_index_ 标志）       │
└──────────────────────────────────────────────┘
```

### 4.3 Micro Block Writer — 写入流程

`ObMicroBlockWriter`（`ob_micro_block_writer.h:61`）负责将行数据写入 Micro Block：

```cpp
// ob_micro_block_writer.h:61-111 — doom-lsp 确认
class ObMicroBlockWriter {
  static const int64_t INDEX_ENTRY_SIZE    = 4;         // @L63
  static const int64_t DEFAULT_DATA_BUFFER_SIZE = 2MB;  // @L64

  int  init(const ObMicroBlockEncodingCtx &);            // @L70
  int  append_row(const ObStoreRow &);                   // @L71 — 追加一行
  int  build_block();                                    // @L72 — 构建完成
  void reuse();                                          // @L73 — 复用

  int64_t get_block_size();   // @L75 — 块总大小（header + data + index）
  int64_t get_row_count();    // @L76 — 行数
  int64_t get_column_count(); // @L77 — 列数
  int64_t get_original_size();// @L78 — 原始（未压缩）大小

  // ── 内部 ──
  ObArenaAllocator       data_buffer_;       // @L106 — 行数据缓冲区
  ObArenaAllocator       index_buffer_;      // @L107 — 行索引缓冲区
  ObArray<ObColDesc>     col_desc_array_;    // @L105 — 列描述
  ObHashIndexBuilder    *hash_index_builder_;// @L108 — 哈希索引构建器
  int64_t                micro_block_size_limit_; // @L104
  bool                   is_major_;          // @L110
};
```

### 4.4 Micro Block Encoder — 编码写入流程

`ObMicroBlockEncoder`（`encoding/ob_micro_block_encoder.h:34`）是实现列式编码的 Micro Block 写入器：

```cpp
// encoding/ob_micro_block_encoder.h:34-181 — doom-lsp 确认
class ObMicroBlockEncoder {
  static const int64_t MAX_MICRO_BLOCK_ROW_CNT = 4096; // @L42
  static const int64_t DEFAULT_DATA_BUFFER_SIZE = 2MB; // @L53

  int  init(const ObMicroBlockEncodingCtx &); // @L66
  int  append_row(const ObStoreRow &);        // @L68 — 追加行
  int  build_block();                         // @L69 — 编码并构建

  // ── 编码选择核心方法 ──
  int  encoder_detection();                   // @L100 — 检测最优编码
  int  fast_encoder_detect();                 // @L102 — 快速编码检测
  int  prescan();                             // @L103 — 预扫描列值
  int  choose_encoder();                      // @L104 — 选择列编码器
  int  pivot();                               // @L85 — 行到列的转置

  // ── 尝试不同编码器 ──
  int  try_encoder(...);                      // @L114 — 尝试编码器
  int  try_previous_encoder(...);             // @L116 — 尝试历史编码器
  int  try_span_column_encoder(...);          // @L128 — 尝试跨列编码

  // ── 存储 ──
  int  store_data();                          // @L143 — 序列化编码数据
  int  store_encoding_meta_and_fix_cols();    // @L148 — 序列化编码元数据

  // ── 内部字段 ──
  ObMicroBlockEncodingCtx     ctx_;           // @L154 — 编码上下文
  ObArenaAllocator            data_buffer_;   // @L156 — 编码数据缓冲区
  ObArenaAllocator            encoding_meta_allocator_; // @L155 — 元数据分配器
  ObArray<ObColDesc>          col_ctxs_;      // @L177 — 列上下文
  ObArray<ObIColumnEncoder*>  encoders_;      // @L165 — 列编码器数组
  ObArray<ObIColumnEncoder*>  fix_data_encoders_;  // @L166 — 定长列编码器
  ObArray<ObIColumnEncoder*>  var_data_encoders_;  // @L167 — 变长列编码器
  ObArray<ObDatumRow>         datum_rows_;    // @L157 — 行数据暂存
  ObArray<ObDatum*>           all_col_datums_;// @L158 — 列值指针
  int64_t                     string_col_cnt_;// @L175 — 字符串列计数
};
```

---

## 5. 编码引擎 — 73 个文件的列编码体系

OceanBase 的编码引擎位于 `src/storage/blocksstable/encoding/` 目录，包含约 **73 个源文件**。这是 SSTable 存储格式最核心的模块。

### 5.1 列编码器体系

编码器通过 `ObIColumnEncoder` 接口（`encoding/ob_icolumn_encoder.h`）抽象：

```
ObIColumnEncoder (接口)
├── ObRawEncoder          — 原始无编码存储
├── ObConstEncoder        — 常量编码（列值全相同）
├── ObDictEncoder         — 字典编码（低基数）
├── ObRleEncoder          — Run-Length 编码（连续重复）
├── ObStringPrefixEncoder — 字符串前缀压缩
├── ObStringDiffEncoder   — 字符串差值编码
├── ObIntegerBaseDiffEncoder — 整数基值差值编码
├── ObHexStringEncoder    — 十六进制字符串编码
├── ObColumnEqualEncoder  — 等值列编码
├── ObInterColumnSubstringEncoder — 跨列子串编码
└── ObNewColumnEncoder    — 新型列编码
```

### 5.2 编码选择策略

`ObMicroBlockEncoder::choose_encoder()`（`encoding/ob_micro_block_encoder.h:104`）实现了编码器的自动选择。流程如下：

1. **Prescan**（`prescan()` @L103）— 扫描列值，收集统计信息（基数、大小、空值等）
2. **Fast detect**（`fast_encoder_detect()` @L102）— 快速判断明显模式
3. **Encoder detection**（`encoder_detection()` @L100）— 尝试多种编码器，选择最优
4. **Try encoder**（`try_encoder()` @L114-132）— 逐个尝试可行编码器

```
选择策略决策树：

┌─ 全列值为 NULL 或相同？
│   → ObConstEncoder（常量编码）
│
┌─ 整数类型且值在连续范围内？
│   → ObIntegerBaseDiffEncoder（基值差值编码）
│
┌─ 列基数低（≤ 256）？
│   → ObDictEncoder（字典编码）
│   → 可结合 prefix tree 优化（ObMultiPrefixTree）
│
┌─ 列值有频繁重复模式？
│   → ObRleEncoder（Run-Length 编码）
│
┌─ 字符串列且有公共前缀？
│   → ObStringPrefixEncoder（前缀压缩）
│   → ObStringDiffEncoder（差值编码）
│
┌─ 默认
│   → ObRawEncoder（原始编码）
```

### 5.3 编码后的数据格式

编码后的 Micro Block 数据区（`Row Data`）布局：

```
┌──────────────────────────────────────┐
│ Encoding Meta Area                   │
│ ├─ 列编码类型数组 (每列1字节)         │
│ ├─ 编码器元数据 (字典/差值表等)        │
│ └─ 定长列数据 (fix_data)             │
├──────────────────────────────────────┤
│ Variable Data Area                    │
│ ├─ 变长列偏移表                      │
│ └─ 变长列数据 (字符串等)              │
├──────────────────────────────────────┤
│ Row Index (每行在 fix/var 区域偏移)    │
└──────────────────────────────────────┘
```

### 5.4 解码器

`ObMicroBlockDecoder`（`encoding/ob_micro_block_decoder.h:215`）及其配套读取器从编码后的 Micro Block 中恢复行数据：

```cpp
// encoding/ob_micro_block_decoder.h:215-459 — doom-lsp 确认
class ObMicroBlockDecoder : public ObIEncodeBlockReader {
  int  init(const char *block, int64_t size);           // @L239
  int  get_row(int64_t row_id, ObDatumRow &row);        // @L245
  int  compare_rowkey(int64_t row_id, const ObRowkey &);// @L247

  // ── 批量过滤 ──
  int filter_pushdown_filter(...);                       // @L268 — 谓词下推
  int filter_black_filter_batch(...);                    // @L273 — 黑名单过滤

  // ── 解码器缓存 ──
  int cache_decoders(...);                               // @L229 — 缓存解码器
  int update_cached_decoders(...);                       // @L235

  // ── 内部 ──
  ObIColumnDecoder   **decoders_;                        // @L451 — 列解码器数组
  ObColumnDecoderCtx  *ctxs_;                            // @L452 — 解码上下文
  const char          *meta_data_;                       // @L445 — 编码元数据
  const char          *row_data_;                        // @L446 — 行数据
  const int32_t       *fix_row_index_;                   // @L448 — 定长行索引
  const int32_t       *var_row_index_;                   // @L447 — 变长行索引
};
```

重要优化——**解码器缓存**（`cache_decoders()` @L229）：同一个 Micro Block 被多次访问时，解码器可被缓存重用，避免重复解析编码元数据。

---

## 6. Index Block — 两级索引

SSTable 使用**两级索引树**加速数据定位：

### 6.1 索引层次

```
SSTable Index Tree
├── Root Index Block（根索引）
│   ├── Macro Index Entry #1
│   │   ├── macro_id / offset / size
│   │   ├── end_key（该块最大 key）
│   │   └── micro_block_count
│   ├── Macro Index Entry #2
│   └── ...
│
├── Mid Index Block（中间索引，树高度 > 1 时）
│
└── Leaf Index Block（叶子索引）
    ├── Micro Index Entry #1
    │   ├── micro_block_offset（在 Macro Block 内的偏移）
    │   ├── row_count
    │   └── end_key
    └── Micro Index Entry #2
        └── ...
```

### 6.2 ObIndexBlockAggregator — 索引块聚合器

`ObIndexBlockAggregator`（`index_block/ob_index_block_aggregator.h:475`，doom-lsp 确认）负责在构建索引时进行数据聚合：

```cpp
// index_block/ob_index_block_aggregator.h:475-504 — doom-lsp 确认
class ObIndexBlockAggregator {
  int  init(...);                                      // @L482
  int  eval(const ObStoreRow &row);                    // @L483 — 聚合一行
  int  get_index_agg_result(ObAggregateInfo &);        // @L484 — 获取聚合结果

  // ── Skip Index 聚合 ──
  ObSkipIndexAggregator skip_index_aggregator_;        // @L500
  ObAggregateInfo       aggregate_info_;               // @L501
};
```

Skip Index 聚合器 `ObSkipIndexDataAggregator`（`index_block/ob_index_block_aggregator.h:408`）可以在索引块级别存储列级的统计信息，用于查询时的**索引跳过**：

```
Skip Index 存储的信息：
├─ column_min — 列最小值
├─ column_max — 列最大值
├─ column_null_count — 空值计数
├─ column_sum — 数值列和
└─ row_count / macro_block_count / micro_block_count
```

**关键价值**：在执行 `WHERE id > 100 AND id < 200` 这样的范围查询时，扫描可以直接跳过不满足条件的 Macro/Micro Block，大幅减少 IO。

---

## 7. Bloom Filter — 快速排除

布隆过滤器是 SSTable 的可选组件，用于**快速判断某个行 key 是否可能存在于 SSTable 中**。

### 7.1 ObBloomFilter

```cpp
// ob_bloom_filter_cache.h:31-64 — doom-lsp 确认
class ObBloomFilter {
  static const int64_t BLOOM_FILTER_FALSE_POSITIVE_PROB = 0.01; // @L34

  int   init_by_row_count(int64_t row_count);   // @L40
  void  insert(const char *key, int64_t len);    // @L46 — 插入 key
  bool  may_contain(const char *key, int64_t len); // @L48 — 可能存在？
  int64_t calc_nbyte(int64_t row_count);         // @L49 — 计算位数组大小
  int64_t calc_nhash(int64_t row_count);         // @L50 — 计算哈希函数数

  int64_t   nhash_;  // @L62 — 哈希函数个数
  int64_t   nbit_;   // @L63 — 位数组位数
  char     *bits_;   // @L64 — 位数组
};
```

### 7.2 布隆过滤器在 SSTable 中的使用

```
查询路径：

1. 用户请求 SELECT * FROM t WHERE pk = 42

2. ObSSTable::bf_may_contain_rowkey() → @ob_sstable.h:199
   │
   ▼
3. ObBloomFilterCache::may_contain() → @ob_bloom_filter_cache.h:166
   │
   ▼
4. 返回 false → 跳过该 SSTable（避免 IO）
   返回 true  → 进入 Index Tree 检查
```

### 7.3 可选而非强制的原因

1. **假阳性**：布隆过滤器只能判断"肯定不存在"，不能判断"肯定存在"
2. **空间开销**：对于小 SSTable，布隆过滤器的空间成本可能超过收益
3. **自适应构建**：`ObBloomFilterCache`（`ob_bloom_filter_cache.h:140`）可根据空读次数自动决定是否需要构建

```cpp
// ob_bloom_filter_cache.h:237-239 — doom-lsp 确认
static const int64_t BF_BUILD_SPEED_SHIFT = 3;
static const int64_t DEFAULT_EMPTY_READ_CNT_THRESHOLD = 8;
static const int64_t MAX_EMPTY_READ_CNT_THRESHOLD = 256;
```

当空读次数超过阈值时，系统会自动触发布隆过滤器的构建。

---

## 8. 数据流全景

### 8.1 写入路径

```
Memtable Flush / Compaction
    │
    ▼
ObCompactWriter
    │
    ▼
ObMacroBlockWriter (@ob_macro_block_writer.h)
    │
    ├──→ 检测是否达到 2MB 上限
    │
    ▼
ObMicroBlockWriter (@ob_micro_block_writer.h)
  or
ObMicroBlockEncoder (@encoding/ob_micro_block_encoder.h)
    │  (根据 row_store_type 选择)
    │
    ├──→ append_row() 收集行数据
    ├──→ prescan() + encoder_detection() 选择最优编码
    │
    ▼
build_block()
    │
    ├──→ pivot() — 行列转置
    ├──→ choose_encoder() — 为每列选择编码器
    ├──→ try_encoder() / try_previous_encoder()
    ├──→ store_encoding_meta_and_fix_cols()
    ├──→ store_data() — 序列化编码数据
    ├──→ (可选) 压缩 (compressor_type_)
    │
    ▼
完整的 Micro Block（Header + Index + Data）
    │
    ▼
ObBlockManager::async_write_block()
    │
    ▼
写入磁盘文件
```

### 8.2 读取路径

```
SSTable Open
    │
    ├──→ load_meta() — 读取 SSTable Basic Meta
    │
    ▼
查询请求 (点查/范围查)
    │
    ├──→ bf_may_contain_rowkey() (可选, 快速排除)
    │
    ▼
Index Tree 二分查找
    │
    ├──→ scan_index() @ob_sstable.h:194
    ├──→ 二分法定位包含目标 key 的 Macro Block
    ├──→ 进一步定位 Micro Block
    │
    ▼
ObBlockManager::async_read_block()
    │
    ▼
Macro Block 读入内存
    │
    ▼
定位 Micro Block（在其 offset 处）
    │
    ├──→ ObMicroBlockDecoder::init() 解析 header
    │
    ▼
(可选) ObMicroBlockDecoder::cache_decoders()
    │
    ▼
解码行数据
    │
    ├──→ decode_cells() — 逐列解码
    │   ├── ObDictDecoder::decode()
    │   ├── ObConstDecoder::decode()
    │   ├── ObStringPrefixDecoder::decode()
    │   └── ...（根据编码类型选择）
    │
    ▼
ObStoreRow 返回给上层
```

---

## 9. 设计决策分析

### 9.1 为什么使用定长 Macro Block（2MB）？

```cpp
// deps/oblib/src/lib/ob_define.h:1991
const int64_t OB_DEFAULT_MACRO_BLOCK_SIZE = 2 << 20; // 2MB
```

**定长设计的优势**：

1. **简化空间管理**：`ObBlockManager` 可以像操作系统管理内存页一样管理磁盘块，使用位图 `block_map_` 跟踪空闲/已用块
2. **物理对齐**：2MB 通常与文件系统块大小（4KB）对齐，避免跨块 I/O 放大
3. **mark-and-sweep 回收**：定长块使 GC 回收变得简单——只需标记位图中的位
4. **预分配**：`ObBlockManager::resize_file()` 可以高效扩展文件大小

### 9.2 Dict Encoding 与 Raw Encoding 的选择策略

| 条件 | 推荐编码 | 空间节省 |
|------|----------|----------|
| 列值全相同（基数=1） | Const | 几乎 100%（仅存 1 个值） |
| 基数 ≤ 256 | Dict | 高（字节替换） |
| 基数 ≤ 65536 | Dict（大字典） | 中（短整型替换） |
| 整数差值小 | Integer Base Diff | 高（只存差值） |
| 字符串有公共前缀 | String Prefix | 中（只存后缀） |
| 无明显模式 | Raw | 无 |

**选择算法**：`encoder_detection()` 会为每种可行的编码器估算最终大小，选择最小的。

### 9.3 两级索引的粒度权衡

```
文件级 Super Block → 定位 Macro Block
  ↓
Macro Block 索引 → 定位到 2MB 物理块
  ↓
Micro Block 索引 → 定位到 ~16-64KB 行组
  ↓
行索引（Micro Block 内） → 定位到具体行
```

**为什么不只使用一级索引？**

- 如果只有 Macro 索引：每次查询都要扫描 2MB 块内的所有 micro blocks
- 如果只有 Micro 索引：索引条目数量太多，索引树本身会很大
- 两级索引平衡了**索引大小**和**扫描粒度**：每次 I/O 读一个 2MB 块，然后在内存中二分查找 micro block

### 9.4 Bloom Filter 可选而非强制的原因

1. **空间-精度权衡**：假阳性率 1%（`BLOOM_FILTER_FALSE_POSITIVE_PROB = 0.01`）意味着 1% 的查询会穿透
2. **小 SSTable 的额外开销**：一个只有几行数据的 SSTable，布隆过滤器可能和 SSTable 本身一样大
3. **自适应机制**：`ObBloomFilterCache` 根据空读次数动态决定构建，避免不必要的开销

### 9.5 定长 Micro Block 还是变长 Micro Block？

OceanBase 的 Micro Block 实际上是**变长**的，这是有意为之：

- **变长的优势**：行组不是按固定行数划分，而是按**数据量**划分。当一个 Micro Block 中的数据量达到阈值时，就结束该 block
- **阈值控制**：`micro_block_size_limit_`（`ob_micro_block_writer.h:104`）控制每个 Micro Block 的数据大小上限
- **行数上限**：`MAX_MICRO_BLOCK_ROW_CNT = 4096`（`ob_micro_block_encoder.h:42`）用于防止超长行导致的内存问题

### 9.6 编码与压缩的层次关系

```
原始行数据
    │
    ▼
列编码 (Column Encoding) — 逻辑压缩，提取列模式
    │  const、dict、rle、prefix、delta...  
    ▼
区块压缩 (Block Compression) — 物理压缩，逐字节压缩
    │  lz4、zstd、snappy、none...
    ▼
写入磁盘
```

两个层次的作用：

- **编码**：利用**列内**的数据模式（重复值、公共前缀、差值）进行逻辑压缩
- **压缩**：对编码后的字节流进行通用物理压缩

两者互补：编码处理"模式"，压缩处理"熵"。对已编码的数据再压缩，可以进一步减少存储。

### 9.7 为什么 Compaction 要重新编码而非直接复用？

**核心原因**：编码依赖数据集的统计特性。

- **Dict Encoding** 的字典表基于某个 Macro Block 内的列值分布。Compaction 合并多个 SSTable 后，列值的基数、分布可能完全改变
- **Prefix Encoding** 的公共前缀也可能因新数据的加入而变化
- 跨列编码（`ObInterColumnSubstringEncoder`）更是强依赖于特定数据集

但 OceanBase 也提供了**复用机制**：当 Compaction 确定某个 Macro Block 的数据不需要任何修改时，可以使用 `LINKED_MACRO_BLOCK_HEADER_MAGIC` 直接引用旧块（`ob_block_sstable_struct.h:52`），避免重新编码的开销。

---

## 10. 源码索引

| 组件 | 文件 | 关键行号 |
|------|------|----------|
| **SSTable 核心** | `ob_sstable.h` | ObSSTable @L124, meta_cache @L93 |
| **SSTable 元数据** | `ob_sstable_meta.h` | ObSSTableBasicMeta @L92, ObSSTableMeta @L208 |
| **块结构定义** | `ob_block_sstable_struct.h` | Magic @L48-56, ObStorageEnv @L90 |
| **Macro Block 结构** | `ob_macro_block_struct.h` | ObDataMacroBlockMeta @L22 |
| **Macro Block Manager** | `ob_block_manager.h` | ObBlockManager @L178 |
| **Micro Block Header** | `ob_micro_block_header.h` | ObMicroBlockHeader @L24 |
| **Micro Block Writer** | `ob_micro_block_writer.h` | ObMicroBlockWriter @L61 |
| **Micro Block Encoder** | `encoding/ob_micro_block_encoder.h` | ObMicroBlockEncoder @L34 |
| **Micro Block Decoder** | `encoding/ob_micro_block_decoder.h` | ObMicroBlockDecoder @L215 |
| **编码器接口** | `encoding/ob_icolumn_encoder.h` | ObIColumnEncoder |
| **解码器接口** | `encoding/ob_icolumn_decoder.h` | ObIColumnDecoder |
| **字典编码** | `encoding/ob_dict_encoder.h`, `ob_dict_decoder.h` | SIMD 加速 `ob_dict_decoder_simd.cpp` |
| **常量编码** | `encoding/ob_const_encoder.h`, `ob_const_decoder.h` | |
| **整数差值编码** | `encoding/ob_integer_base_diff_encoder.h` | |
| **字符串前缀编码** | `encoding/ob_string_prefix_encoder.h` | |
| **原始编码** | `encoding/ob_raw_encoder.h`, `ob_raw_decoder.h` | SIMD `ob_raw_decoder_simd.cpp` |
| **RLE 编码** | `encoding/ob_rle_encoder.h`, `ob_rle_decoder.h` | |
| **跨列编码** | `encoding/ob_inter_column_substring_encoder.h` | |
| **新列编码** | `encoding/ob_new_column_encoder.h` | |
| **哈希/前缀树** | `encoding/ob_encoding_hash_util.h`, `ob_multi_prefix_tree.h` | |
| **索引块聚合器** | `index_block/ob_index_block_aggregator.h` | ObIndexBlockAggregator @L475 |
| **Index Block 构建** | `index_block/ob_index_block_builder.h` | |
| **Bloom Filter** | `ob_bloom_filter_cache.h` | ObBloomFilter @L31 |
| **Bloom Filter 写入** | `ob_bloom_filter_cache.h` | ObMacroBloomFilterCacheWriter @L259 |
| **编码工具** | `encoding/ob_encoding_util.h` | |
| **位流操作** | `encoding/ob_bit_stream.h` | |

---

## 11. 总结

SSTable 存储格式是 OceanBase 持久化存储的基石。

**核心思想**：
- **定长物理块 + 变长逻辑块**：Macro Block（2MB 定长）提供简单的空间管理，Micro Block（变长行组）提供灵活的读取粒度
- **列式编码压缩**：通过 11 种列编码器自动选择最优压缩策略，结合传统压缩算法实现高压缩比
- **两级索引 + Skip Index**：索引树加速定位，列级统计信息实现索引跳过
- **可选 Bloom Filter**：自适应布隆过滤器减少不必要的 IO

**从第 1 篇到第 8 篇的完整链路**：
```
MVCC Row (行结构)
  → Iterator (迭代器)
    → Write Conflict (冲突管理)
      → Callback (回调链)
        → Compact (行级压缩)
          → Memtable Freeze (冻结)
            → LS Tree (容器架构)
              → SSTable (磁盘格式) ← 这里
```

下一篇文章将从 **Compaction** 入手，分析 SSTable 如何在 Background 任务中被合并、重写和回收。
