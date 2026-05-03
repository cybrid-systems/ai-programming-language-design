# 26 — 编码引擎深潜 — ObMicroBlockEncoder 与列编码器体系

> 基于 OceanBase 主线源码（commit 最新）
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 编码器路径：`src/storage/blocksstable/encoding/` — 73 个文件，29,203 行代码

---

## 0. 概述

前面 08 篇文章从宏观层面介绍了 SSTable 的块格式——Micro Block 的物理布局、行存储模式和压缩接口。本文将深入 SSTable 存储引擎的内核：**列编码器体系**。

如果说 Micro Block 是存储的骨骼，编码引擎就是肌肉——它在不损失查询性能的前提下，将列数据压缩到极致。OceanBase 的编码器不是事后对块做通用压缩，而是在**写入时**根据每列数据的统计特征智能选择编码方式。

### 编码引擎在存储架构中的位置

```
┌──────────────────────────────────────────────────────────────┐
│                     SQL Layer / Query Engine                   │
├──────────────────────────────────────────────────────────────┤
│                     ObMicroBlockDecoder                       │
│            ← 解码器从编码列还原 ObDatum 行                     │
├──────────────────────────────────────────────────────────────┤
│                     ObMicroBlockEncoder  ★                     │
│   ┌────────────────────────────────────────────────────────┐  │
│   │  编码引擎（本文焦点）                                    │  │
│   │  ObMicroBlockEncoder  →  choose_encoder()              │  │
│   │    ├── DictEncoder     (字典编码 — 低基数)              │  │
│   │    ├── ConstEncoder    (常量编码 — 全相同)              │  │
│   │    ├── StringPrefixEncoder (前缀编码 — 共享前缀)        │  │
│   │    ├── StringDiffEncoder   (差值编码 — 渐变字符串)      │  │
│   │    ├── ColumnEqualEncoder  (等值编码 — 列间冗余)        │  │
│   │    ├── IntegerBaseDiffEncoder (整数差值)                │  │
│   │    ├── RLEEncoder      (游程编码)                       │  │
│   │    └── RawEncoder      (原始存储 — 兜底)                │  │
│   └────────────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────────────┤
│                     ObMacroBlockWriter                        │
│         ↓ 写入 Macro Block 中的 Micro Block 区域               │
├──────────────────────────────────────────────────────────────┤
│                     SSTable 磁盘文件                           │
└──────────────────────────────────────────────────────────────┘
```

### 核心概念速览

| 概念 | 对应类/结构 | 位置 |
|------|-------------|------|
| **Micro 编码器** | `ObMicroBlockEncoder` | `ob_micro_block_encoder.h:34` |
| **编码器接口** | `ObIColumnEncoder` | `ob_icolumn_encoder.h:39` |
| **列编码上下文** | `ObColumnEncodingCtx` | `ob_block_sstable_struct.h:496` |
| **编码器分配器** | `ObEncoderAllocator / ObEncodingPool` | `ob_encoding_allocator.h:50-97` |
| **位流工具** | `ObBitStream` | `ob_bit_stream.h:37` |
| **哈希表（预扫描）** | `ObEncodingHashTable` | `ob_encoding_hash_util.h` |
| **列头** | `ObColumnHeader` | `ob_block_sstable_struct.h:203` |
| **编码类型枚举** | `ObColumnHeader::Type` | `ob_block_sstable_struct.h:203` |
| **存储类映射** | `get_store_class_map()` | `ob_encoding_util.cpp` |

---

## 1. 编码器类型体系

编码引擎支持 9 种编码器，定义在 `ObColumnHeader::Type` 枚举中（`ob_block_sstable_struct.h:203`）：

```cpp
enum Type
{
  RAW,               // 原始存储（兜底）
  DICT,              // 字典编码
  RLE,               // 游程编码
  CONST,             // 常量编码
  INTEGER_BASE_DIFF, // 整数差值编码
  STRING_DIFF,       // 字符串差值编码
  HEX_PACKING,       // 十六进制打包
  STRING_PREFIX,     // 字符串前缀编码
  COLUMN_EQUAL,      // 列等值编码
  COLUMN_SUBSTR,     // 列间子串编码
  MAX_TYPE
};
```

每种类型有其专门的文件对（`ob_{type}_encoder.h/cpp`），继承自 `ObIColumnEncoder` 接口。

### 编码器接口（ObIColumnEncoder）

`ob_icolumn_encoder.h:38` 定义了编码器的纯虚接口：

```cpp
class ObIColumnEncoder {
  // 初始化 — 绑定列上下文和行数据
  virtual int init(const ObColumnEncodingCtx &ctx,
                   const int64_t column_index,
                   const ObConstDatumRowArray &rows) = 0;

  // 遍历数据 — 判断是否适合该编码器（suitable）
  virtual int traverse(bool &suitable) = 0;

  // 计算编码后的总大小
  virtual int64_t calc_size() const = 0;

  // 存储编码元数据
  virtual int store_meta(ObBufferWriter &buf_writer) = 0;

  // 预估元数据空间
  virtual int get_encoding_store_meta_need_space(int64_t &need_size) const = 0;

  // 按行存储数据（位流或固定长度）
  virtual int store_data(int64_t row_id, ObBitStream &bs,
                         char *buf, int64_t len) = 0;

  // 存储固定长列数据
  virtual int store_fix_data(ObBufferWriter &buf_writer) = 0;

  // 返回编码类型
  virtual ObColumnHeader::Type get_type() const = 0;
};
```

---

## 2. ObMicroBlockEncoder — 编码主流程

`ObMicroBlockEncoder`（`ob_micro_block_encoder.h:34`）是编码引擎的核心入口，继承自 `ObIMicroBlockWriter`。它负责：

1. **收集行数据**（`append_row` 分批提交）
2. **行转列**（`pivot` 函数，将行格式转换为列格式）
3. **预扫描列特征**（`prescan`，构建哈希表和前缀树）
4. **选择最佳编码器**（`encoder_detection` → `choose_encoder`）
5. **编码并构建块**（`build_block`，组装最终 Micro Block）

### 2.1 编码主流程时序

```
ObMacroBlockWriter
  │  create_micro_block()
  │  → new ObMicroBlockEncoder
  │
  │  append_row(row)  × N
  │  ┌─────────────────────────────────────┐
  │  │  1. copy_and_append_row()           │
  │  │     行格式 → datum_rows_ +          │
  │  │     all_col_datums_（行转列缓冲区）  │
  │  │  2. 检查行数 / 大小限制              │
  │  └─────────────────────────────────────┘
  │
  │  build_block(buf, size)
  │  ┌─────────────────────────────────────┐
  │  │  1. pivot() → 行转列                │
  │  │  2. encoder_detection()              │
  │  │      ├── prescan() × column_cnt      │
  │  │      │    └── 构建哈希表 & 前缀树    │
  │  │      ├── fast_encoder_detect()       │
  │  │      │    └── 快速路径：指定编码     │
  │  │      │        或 Const（唯一值）     │
  │  │      └── choose_encoder()            │
  │  │           └── 完整编码器选择         │
  │  │  3. store_encoding_meta_and_fix_cols │
  │  │  4. set_row_data_pos()               │
  │  │  5. fill_row_data()                  │
  │  │  6. fill_row_index()                 │
  │  └─────────────────────────────────────┘
  │
  ▼
Micro Block 数据就绪
```

### 2.2 行转列（pivot）

`pivot()` 函数（`ob_micro_block_encoder.cpp:448`）将逐行收集的 `datum_rows_` 转置为每列的 `ObColDatums` 数组。这是后续编码选择的关键前提：

```cpp
int ObMicroBlockEncoder::pivot()
{
  for (int64_t i = 0; i < ctx_.column_cnt_; ++i) {
    ObColDatums &c = *all_col_datums_.at(i);
    c.resize(datum_rows_.count());
    // 按 8 行一批循环展开
    for (pos = 0; pos + 8 <= datum_rows_.count(); pos += 8) {
      c.at(pos + 0) = datum_rows_.at(pos + 0).get_datum(i);
      c.at(pos + 1) = datum_rows_.at(pos + 1).get_datum(i);
      // ... 8 行展开
    }
    // 剩余行
    for (; pos < datum_rows_.count(); ++pos)
      c.at(pos) = datum_rows_.at(pos).get_datum(i);
  }
}
```

### 2.3 构建块（build_block）

`build_block()`（`ob_micro_block_encoder.cpp:561`）是编码的终结阶段。其内部流程精密：

```
build_block()
├── pivot()                          // 行 → 列
├── encoder_detection()              // 分析每列、选择编码器
├── store_encoding_meta_and_fix_cols // 存储编码元数据 + 固定长数据
│   ├── 确定 extend_value_bit (0/1/2)
│   ├── 写入 ObColumnHeader 数组
│   └── 每个编码器：
│       ├── store_meta()            // 编码器元数据
│       └── store_fix_data()        // 固定长列数据
├── set_row_data_pos()              // 确定每行变长数据偏移
├── fill_row_data()                 // 写入变长行数据
├── fill_row_index()                // 写入行索引数组
└── MEMCPY: header + column_headers + encoding_meta + fix data
```

---

## 3. 列预扫描引擎

在编码器选择之前，引擎会对每一列进行**预扫描**（prescan），提取关键统计特征。

### 3.1 列编码上下文（ObColumnEncodingCtx）

`ob_block_sstable_struct.h:496`：

```cpp
struct ObColumnEncodingCtx {
  int64_t null_cnt_;           // NULL 值数量
  int64_t nope_cnt_;           // NOP 值数量
  uint64_t max_integer_;       // 整数列最大值（决定位宽）
  int64_t var_data_size_;      // 变长数据总大小
  int64_t dict_var_data_size_; // 字典变长大小
  int64_t fix_data_size_;      // 固定长大小（-1 表示变长）
  int64_t max_string_size_;    // 最大字符串长度
  ObEncodingHashTable *ht_;         // 值频率哈希表
  ObMultiPrefixTree *prefix_tree_;  // 前缀树（字符串编码）
  bool detected_encoders_[MAX_TYPE];// 各编码器是否可能适用
  bool only_raw_encoding_;     // 仅能用原始编码
  bool is_refed_;              // 是否被其他列引用
  bool need_sort_;             // 字典是否需要排序
  // ...
};
```

### 3.2 预扫描流程（prescan）

`prescan()`（`ob_micro_block_encoder.cpp:1195`）：

```
prescan(column_index)
├── 创建 ObEncodingHashTable (桶数 = 行数 × 2)
├── 创建 ObMultiPrefixTree
├── builder->build(col_datums, col_desc)
│   └── 哈希 + 链表：统计每个唯 一值的行 ID 链表
└── build_column_encoding_ctx(ht, store_class, type_store_size, col_ctx)
    └── 根据存储类型计算：
        ├── ObIntSC/ObUIntSC → max_integer_
        ├── ObStringSC → max_string_size_, var_data_size_
        ├── ObNumberSC → 特殊处理
        └── ObOTimestampSC → 变长/固定判断
```

### 3.3 构建列编码上下文（build_column_encoding_ctx）

`ob_encoding_hash_util.cpp:374` — 这是特征提取的核心函数，根据存储类不同处理逻辑：

```cpp
int build_column_encoding_ctx(ObEncodingHashTable *ht,
    ObObjTypeStoreClass store_class, int64_t type_store_size,
    ObColumnEncodingCtx &col_ctx) {
  col_ctx.null_cnt_ = ht->get_null_list().size_;
  col_ctx.nope_cnt_ = ht->get_nope_list().size_;
  col_ctx.ht_ = ht;

  switch (store_class) {
  case ObIntSC:
  case ObUIntSC:
    // 遍历所有不同值，取 max_integer_
    // 用于确定最小编码位宽
    FOREACH(l, *ht) {
      v = l->header_->datum_->get_uint64() & integer_mask;
      col_ctx.max_integer_ = max(col_ctx.max_integer_, v);
    }
    break;

  case ObStringSC:
  case ObTextSC:
  case ObJsonSC:
    col_ctx.fix_data_size_ = -1;  // 默认变长
    FOREACH(l, *ht) {
      len = l->header_->datum_->len_;
      col_ctx.max_string_size_ = max(col_ctx.max_string_size_, len);
      col_ctx.var_data_size_ += len * l->size_;
      col_ctx.dict_var_data_size_ += len;
      // 检查是否所有值等长
      if (!var_store && fix_data_size_ < 0)
        fix_data_size_ = len;
      else if (len != fix_data_size_)
        fix_data_size_ = -1;  // 变长
    }
    break;
  }
}
```

---

## 4. choose_encoder — 智能编码选择算法

`choose_encoder()`（`ob_micro_block_encoder.cpp:1603`）是编码引擎的**决策核心**。它采用**淘汰制**：从 RawEncoder 开始，逐个尝试更优的编码器，保留压缩率最好的。

### 4.1 决策流程图

```
choose_encoder(column_idx, column_ctx)
│
├── 1. RawEncoder（兜底 — 总能成功）
│     acceptable_size = calc_size() / 4
│
├── 2. DictEncoder（字典编码 — 低基数）
│     如果 size < best → 替换
│
├── 3. 历史编码尝试（try_previous_encoder）
│     → 尝试前一个 Micro Block 使用的编码类型
│
├── 4. ColumnEqualEncoder（列间等值）
│     → 数据与前列相同？只存位图
│     → 如果 size < best → 替换；≤ acceptable → 结束
│
├── 5. InterColSubStrEncoder（列间子串）
│     → 字符串列从参考列取子串
│     → 如果 size < best → 替换；≤ acceptable → 结束
│
├── 6. RLE + ConstEncoder（基数 ≤ 行数/2）
│     RLE：游程编码
│     Const：所有值相同（或少量异常）
│
├── 7. IntegerBaseDiffEncoder（整数列）
│     → 与最小值做差值，存差值（更小位宽）
│
├── 8. StringDiffEncoder（字符串列，且 fix_data_size > 0）
│     → 相邻字符串的差值编码
│
├── 9. StringPrefixEncoder（字符串列）
│     → 共享前缀编码（前缀树）
│
└── 10. HexStringEncoder（字符串列）
      → 十六进制编码（当 diff 和 prefix 不合适时）
```

### 4.2 策略要点

1. **RawEncoder 永远是第一候选**——它必须总是成功，作为兜底方案
2. **acceptable_size** 是从最佳编码器大小的 1/4 确定的——找到更优的编码器后，如果其大小小于等于 `acceptable_size`，就停止搜索（`try_more = false`）
3. **字典编码优先**在低基数数据上表现出色，是最常用的编码器
4. **跨列编码器**（ColumnEqual、InterColumnSubStr）不存储完整数据，只存与前列的差异，因此一旦被使用，被引用列标记 `is_refed_`
5. **启发式剪枝**：RLE 和 Const 只在基数 ≤ 行数一半时尝试；StringDiff 只在固定长字符串列尝试

### 4.3 代码节选

```cpp
// ob_micro_block_encoder.cpp:1603
int ObMicroBlockEncoder::choose_encoder(int64_t column_idx, ObColumnEncodingCtx &cc)
{
  // 1. Raw 兜底
  try_encoder<ObRawEncoder>(e, column_idx);
  ObIColumnEncoder *choose = e;
  int64_t acceptable_size = choose->calc_size() / 4;

  // 2. Dict
  try_encoder<ObDictEncoder>(e, column_idx);
  if (e && e->calc_size() < choose->calc_size()) {
    free_encoder(choose); choose = e;
  }

  // 3. 历史编码
  try_previous_encoder(choose, column_idx, acceptable_size, try_more);

  // 4. ColumnEqual（跨列）
  if (try_more && !cc.is_refed_) {
    try_span_column_encoder<ObColumnEqualEncoder>(e, column_idx);
    if (e && e->calc_size() < choose->calc_size()) { ... }
  }

  // 5. RLE + Const（低基数，基数 <= 行数/2）
  if (try_more && cc.ht_->distinct_cnt() <= datum_rows_.count() / 2) {
    try_encoder<ObRLEEncoder>(e, column_idx);
    try_encoder<ObConstEncoder>(e, column_idx);
  }

  // 6. IntegerBaseDiff（整数列）
  if (try_more && (ObIntSC == sc || ObUIntSC == sc)) {
    try_encoder<ObIntegerBaseDiffEncoder>(e, column_idx);
  }

  // 7. StringDiff（字符串列，固定长）
  if (try_more && is_string_encoding_valid(sc) && cc.fix_data_size_ > 0) {
    try_encoder<ObStringDiffEncoder>(e, column_idx);
  }

  // 8. StringPrefix（字符串列）
  if (try_more && is_string_encoding_valid(sc)) {
    try_encoder<ObStringPrefixEncoder>(e, column_idx);
  }

  // 9. HexString（字符串列兜底）
  if (try_more && is_string_encoding_valid(sc)) {
    try_encoder<ObHexStringEncoder>(e, column_idx);
  }

  // 记录跨列引用
  if (choose 是跨列编码器) {
    col_ctxs_.at(ref_col_idx).is_refed_ = true;
  }
  encoders_.push_back(choose);
}
```

### 4.4 快速路径（fast_encoder_detect）

在调用 `choose_encoder` 之前，`fast_encoder_detect()` 检查两个快捷情况：

```cpp
// ob_micro_block_encoder.cpp:1318
int ObMicroBlockEncoder::fast_encoder_detect(int64_t column_idx, const ObColumnEncodingCtx &cc)
{
  // 情况 1：用户显式指定了编码类型
  if (ctx_.column_encodings_[column_idx] > 0) {
    return try_encoder(e, column_idx, specified_type, ...);
  }

  // 情况 2：仅有一个不同值 → 直接使用 ConstEncoder
  if (cc.ht_->distinct_cnt() <= 1) {
    return try_encoder<ObConstEncoder>(e, column_idx);
  }

  // 情况 3：only_raw_encoding 标记
  if (cc.only_raw_encoding_) {
    return force_raw_encoding(column_idx, true, e);
  }
}
```

---

## 5. 各编码器详细分析

### 5.1 字典编码 — ObDictEncoder

**文件**：`ob_dict_encoder.h/cpp`（403 行）
**类型**：`ObColumnHeader::DICT`
**用途**：低基数列（如状态码、枚举、分类标签）

字典编码是 OceanBase 最常用、最核心的编码器。它的基本原理是：将列中的所有不同值收集到字典表中，每行只存一个字典索引引用。

#### 数据结构

```
┌─────────────────────────────────────────┐
│           Dict Meta Header               │
│  ObDictMetaHeader（packed）               │
│  ├─ version_ = 0                         │
│  ├─ count_ = 不同值数量                    │
│  ├─ data_size_ = 字典值大小               │
│  ├─ row_ref_size_ = 行引用的位宽           │
│  ├─ index_byte_ = 变长字典索引字节数       │
│  └─ attr_ = 属性（FIX_LENGTH/IS_SORTED）  │
├─────────────────────────────────────────┤
│           字典正文（Dictionary Values）     │
│  固定长模式：                              │
│  ┌──────┬──────┬──────┬──────┐            │
│  │ val0 │ val1 │ val2 │ ...  │ ← 等宽     │
│  └──────┴──────┴──────┴──────┘            │
│  变长模式：                              │
│  ┌──────────────┬───────────────┐          │
│  │ index[0..N-1]│ var_data[]   │          │
│  │ (偏移数组)   │ (拼接数据)    │          │
│  └──────────────┴───────────────┘          │
├─────────────────────────────────────────┤
│           行数据（Row References）         │
│  ┌──────┬──────┬──────┬──────┬──────┐      │
│  │ ref0 │ ref1 │ ref2 │ ref3 │ ...  │     │
│  └──────┴──────┴──────┴──────┴──────┘      │
│  每个引用 = 字典索引，位宽 = row_ref_size_  │
│  可能使用 bit_packing（按位存储）             │
└─────────────────────────────────────────┘
```

#### 编码流程

`ob_dict_encoder.cpp:83` — `traverse()`：判断编码是否适用，计算元数据大小

```cpp
int ObDictEncoder::traverse(bool &suitable) {
  suitable = true;
  count_ = ht_->size();  // 不同值数量

  if (store_var_dict()) {
    // 变长字典：索引字节数取决于数据总大小
    dict_index_byte_ = var_data_size_ <= UINT8_MAX ? 1 : 2;
    if (var_data_size_ > UINT16_MAX) dict_index_byte_ = 4;
  } else if (整数列) {
    // 使用 max_integer_ 确定最小编码位宽
    dict_fix_data_size_ = get_int_size(max_integer_);
  }

  // 确定行引用位宽
  int64_t max_ref = count_ - 1;
  if (有 NULL)  max_ref = count_;
  if (有 NOPE)  max_ref = count_ + 1;

  // 选择位打包或字节对齐
  if (bit_packing 适用) {
    desc_.bit_packing_length_ = 位宽;
  } else {
    desc_.fix_data_length_ = 字节对齐大小;
  }
}
```

`ob_dict_encoder.cpp:135` — `build_dict()`：构建有序字典

```cpp
int ObDictEncoder::build_dict() {
  if (need_sort_) {
    // 对哈希表中的链表按值排序（用于前缀编码的优化）
    lib::ob_sort(ht_->begin(), ht_->end(), DictCmp(ret, cmp_func));
    // 重新分配 dict_ref
    int64_t i = 0;
    FOREACH(l, *ht_) {
      FOREACH(n, *l) { n->dict_ref_ = i; }
      ++i;
    }
  }
}
```

#### 解码端

字典解码器 `ob_dict_decoder.cpp`（1,845 行）是编码引擎中最大的单个文件。它处理：

- `decode()`：根据行引用从字典中取出原始值
- `batch_decode()`：SIMD 批量解码
- `filter_by_dict_ref()`：直接对字典引用做过滤（不下推到值）
- `get_percentile()`：百分位查询（统计聚合优化）

#### SIMD 加速解码

`ob_dict_decoder_simd.cpp`（183 行）提供 AVX-512 优化的字典引用比较：

```cpp
// AVX-512 下，一次 16 个行引用的批量比较
// 将 dict_ref 广播到 __m128i，用 _mm_cmp_epu8_mask 并行比较
template <int CMP_TYPE>
struct DictCmpRefAVX512Func_T<1, CMP_TYPE> {
  static void dict_cmp_ref_func(...) {
    __m128i dict_ref_vec = _mm_set1_epi8(casted_dict_ref);
    for (int64_t i = 0; i < row_cnt / 16; ++i) {
      __m128i data_vec = _mm_loadu_si128(filter_col_data + i * 16);
      __mmask16 cmp_res_ref = _mm_cmp_epu8_mask(data_vec, dict_ref_vec, op);
      result.reinterpret_data<uint16_t>()[i] = cmp_res_ref;
    }
  }
};
```

这种设计将**值比较下推到字典引用层**，避免了实际解压数据的开销——查询引擎直接在字典引用上执行过滤。

### 5.2 常量编码 — ObConstEncoder

**文件**：`ob_const_encoder.h/cpp`（411 行）
**类型**：`ObColumnHeader::CONST`
**用途**：列中所有值（或绝大多数值）相同

当列中绝大多数行都是同一个值时，ConstEncoder 只存储该"常数值"，并记录少数异常的偏移。

#### 元数据头

```cpp
struct ObConstMetaHeader {
  uint8_t version_;     // = 0
  uint8_t count_;       // 异常值数量（最多 32）
  uint8_t const_ref_;   // 常量值在字典中的引用
  uint8_t row_id_byte_; // 异常行 ID 的字节数
  uint16_t offset_;     // 异常数据偏移
  char payload_[0];     // 异常数据
} __attribute__((packed));
```

#### 适用条件

`traverse()` 决定是否适用：

- 不同值数量 ≤ `MAX_EXCEPTION_SIZE + 1`（即 ≤ 33）
- 异常行数 ≤ `MAX_EXCEPTION_SIZE`（即 ≤ 32）
- 异常行数 ≤ `MAX_EXCEPTION_PCT`（即行数的 10%，至少 1 行）

```cpp
int ObConstEncoder::traverse(bool &suitable) {
  if (ht_->get_nope_list().size_ - 1 > MAX_EXCEPTION_SIZE + 1) {
    suitable = false;
    return ret;
  }
  // 选择出现次数最多的值作为"常数值"
  FOREACH(l, *ht_) {
    if (l->size_ > max_cnt) {
      max_cnt = l->size_;
      const_list_header_ = l->header_;  // 这就是常量值
    }
  }
  count_ = rows_->count() - max_cnt;
  if (count_ > MAX_EXCEPTION_SIZE
      || count_ > MAX(rows_->count() * MAX_EXCEPTION_PCT / 100, 1L)) {
    suitable = false;
  }
}
```

内部使用 `ObDictEncoder` 作为子编码器来存储异常行数据。

### 5.3 字符串前缀编码 — ObStringPrefixEncoder

**文件**：`ob_string_prefix_encoder.h/cpp`（323 行）
**类型**：`ObColumnHeader::STRING_PREFIX`
**用途**：共享前缀的字符串列（如 URL 路径、文件路径）

#### 原理

- 构建前缀树，找出多个字符串共享的前缀
- 编码时只存储：前缀索引 + 剩余后缀
- 根据 `ObMultiPrefixTree` 输出结果

#### 元数据头

```cpp
struct ObStringPrefixMetaHeader {
  uint8_t version_;       // = 0
  uint8_t count_;         // 前缀数量
  uint32_t offset_;       // 行数据中的变长偏移
  uint32_t length_;       // 行数据长度
  uint32_t max_string_size_;
  uint8_t prefix_index_byte_ : 2; // 前缀索引的位宽
  uint8_t hex_char_array_size_ : 5; // 十六进制字符表大小
  unsigned char hex_char_array_[0];
} __attribute__((packed));

struct ObStringPrefixCellHeader {
  uint8_t ref_ : 4;   // 前缀引用（最多 15 个前缀）
  uint8_t odd_ : 4;   // 后缀长度偏移
  uint16_t len_;      // 公共部分长度
} __attribute__((packed));
```

每个行单元中，`ref_` 引用一个前缀，`len_` 表示与前缀相同部分的长度，实际存储的是 `odd_` 偏移后的后缀差异。

### 5.4 字符串差值编码 — ObStringDiffEncoder

**文件**：`ob_string_diff_encoder.h/cpp`（425 行）
**类型**：`ObColumnHeader::STRING_DIFF`
**用途**：渐进式变化的字符串列（如单调递增的标识符、序列号字符串）

#### 原理

与相邻行的字符串比较，记录**公共前缀长度**和**后缀差值**。编码后每行只存储与前行的差异部分。

#### 数据结构

```cpp
struct ObStringDiffHeader {
  struct DiffDesc {
    uint8_t diff_ : 1;  // 是否有差异
    uint8_t count_ : 7; // 公共前缀长度
  };
  uint8_t version_;
  uint8_t hex_char_array_size_;
  uint16_t string_size_;
  uint32_t offset_;
  uint32_t length_;
  uint8_t diff_desc_cnt_;    // 差异描述符数量
  DiffDesc diff_descs_[0];   // 每个行的差异描述
};
```

`copy_string()` 模板函数根据差异描述恢复字符串。由于需要前向遍历（每行依赖于前一行），这种编码适合顺序扫描解码。

### 5.5 列等值编码 — ObColumnEqualEncoder

**文件**：`ob_column_equal_encoder.h/cpp`（231 行）
**类型**：`ObColumnHeader::COLUMN_EQUAL`
**用途**：多列索引中的冗余列消除

#### 原理

当某一列的值完全等于另一列时（如复合索引中的前缀列），COLUMN_EQUAL 只存储一个位图标记哪些行不相等。

```cpp
class ObColumnEqualEncoder : public ObSpanColumnEncoder {
  int64_t ref_col_idx_;           // 引用的列索引
  ObArray<int64_t> exc_row_ids_;  // 不相等行 ID
  ObBitMapMetaBaseWriter base_meta_writer_;  // 位图编码

  OB_INLINE int is_datum_equal(const ObDatum &left, const ObDatum &right, bool &equal) {
    // 先比较扩展值（NULL/NOP），再按类型比较
    ObStoredExtValue left_ext = get_stored_ext_value(left);
    ObStoredExtValue right_ext = get_stored_ext_value(right);
    if (left_ext != right_ext) { equal = false; }
    else if (left.is_null() || left.is_nop()) { equal = true; }
    else if (整数类型) { equal = (left.get_uint64() == right.get_uint64()); }
    else { equal = ObDatum::binary_equal(left, right); }
  }
};
```

### 5.6 其他编码器

| 编码器 | 文件 | 行数 | 用途 |
|--------|------|------|------|
| **ObRawEncoder** | `ob_raw_encoder.h/cpp` | 95 | 原始存储，不做编码，兜底 |
| **ObRLEEncoder** | `ob_rle_encoder.h/cpp` | 143 | 游程编码，连续重复值 |
| **ObIntegerBaseDiffEncoder** | `ob_integer_base_diff_encoder.h/cpp` | 221 | 整数差值编码，减少位宽 |
| **ObHexStringEncoder** | `ob_hex_string_encoder.h/cpp` | 270 | 十六进制字符打包 |
| **ObInterColSubStrEncoder** | `ob_inter_column_substring_encoder.h/cpp` | 347 | 列间子串编码 |

### 5.7 列间子串编码（InterColumnSubstring）

这是一种**跨列**的编码方式：当字符串列 B 的值是列 A 的子串时，B 仅存储其在 A 中的偏移和长度。

```cpp
// ObInterColSubStrEncoder 继承自 ObSpanColumnEncoder
// traverse() 中检测某行的值是否是参考列值的子串
// 如果是，记录偏移和长度；否则存储完整值
```

这种编码对某些数据模式特别有效——例如，当 `name` 列存储全名，`first_name` 列存储名字时。

---

## 6. 编码器分配器与内存管理

### ObEncoderAllocator（工厂模式）

`ob_encoding_allocator.h:50` 提供基于对象池的编码器/解码器分配：

```cpp
typedef ObEncodingAllocator<ObIColumnEncoder> ObEncoderAllocator;
typedef ObEncodingAllocator<ObIColumnDecoder> ObDecoderAllocator;

// 为每种编码器维护独立的对象池
class ObEncodingAllocator {
  Pool raw_pool_;           // ObRawEncoder 池
  Pool dict_pool_;          // ObDictEncoder 池
  Pool rle_pool_;           // ObRLEEncoder 池
  Pool const_pool_;         // ObConstEncoder 池
  Pool int_diff_pool_;      // ObIntegerBaseDiffEncoder 池
  Pool str_diff_pool_;      // ObStringDiffEncoder 池
  Pool hex_str_pool_;       // ObHexStringEncoder 池
  Pool str_prefix_pool_;    // ObStringPrefixEncoder 池
  Pool column_equal_pool_;  // ObColumnEqualEncoder 池
  Pool column_substr_pool_; // ObInterColSubStrEncoder 池
  Pool *pools_[MAX_TYPE];   // 类型 → 池的映射
};
```

`ObEncodingPool` 维护一个最多 64 个空闲项的链表，`alloc` 时优先使用池中对象，避免重复分配内存：

```cpp
template<typename T>
inline int ObEncodingPool::alloc(T *&item) {
  if (free_cnt_ > 0) {
    item = static_cast<T *>(free_items_[--free_cnt_]);
  } else {
    item = static_cast<T *>(pool_.alloc());
  }
  return OB_SUCCESS;
}
```

---

## 7. 位流工具 — ObBitStream

`ob_bit_stream.h:37` — 编码引擎的底层位操作工具，支持变长整数的位级编码。

核心方法：

```cpp
class ObBitStream {
  // 在位置 offset 写入 cnt 位的值 value
  OB_INLINE int set(int64_t offset, int64_t cnt, int64_t value);
  // 从位置 offset 读取 cnt 位的值
  OB_INLINE int get(int64_t offset, int64_t cnt, int64_t &value);

  // 带溢出保护的内存安全设置
  OB_INLINE static void memory_safe_set(
      unsigned char *buf, int64_t word_off, bool overflow, uint64_t v);
};
```

`ObBitStream` 支持内存安全的 64 位读取/写入，以及三种位解包策略（根据位宽自动选择最优解包函数）。这是 bit_packing 编码模式的基础。

---

## 8. 解码器分析

解码器位于 `ob_{type}_decoder.h/cpp`，与编码器对称。关键解码器：

### 8.1 字典解码器（ObDictDecoder）

`ob_dict_decoder.h/cpp`（1,845 行）—— 最复杂的解码器。

核心解码流程：

```
decode()
├── 解析 ObDictMetaHeader
├── 根据字典类型（定长/变长）定位值区域
├── 从行数据中读取字典引用（ref）
├── 根据 ref 在字典中查找实际值
└── 写入 ObDatum 输出
```

此外支持：
- `batch_decode()`：批量解码优化
- `filter_by_dict_ref()`：不下推算子，直接在字典引用层做过滤
- `get_percentile()`：百分位查询（用于 COUNT、SUM 等聚合的统计信息获取）

### 8.2 SIMD 解码

字典解码过滤器（`ob_dict_decoder_simd.cpp`）在 AVX-512 下加速：

- 一次 16 个行引用的批量比较
- 支持 EQ/NE/LT/LE/GT/GE/BT 等比较操作
- 根据字典引用位宽（1/2/4 字节）特化模板

### 8.3 其他解码器

| 解码器 | 行数 | 特点 |
|--------|------|------|
| `ObConstDecoder` | 1,039 | 处理常量列 + 异常行回退 |
| `ObStringPrefixDecoder` | 362 | 用 ObMultiPrefixTree 重建字符串 |
| `ObStringDiffDecoder` | 442 | 前向差分恢复 |
| `ObColumnEqualDecoder` | 231 | 位图 + 回退列 |
| `ObRawDecoder` | 72 | 直接拷贝 |
| `ObRawDecoderSimd` | (+SIMD) | 用于向量化过滤 |

---

## 9. 设计决策与权衡

### 为什么字典编码是主力？

1. **基数分布规律**：数据库业务中大量列具有低基数特征（性别、状态码、地区编码），字典编码对这些列有最优压缩率
2. **查询加速**：字典编码允许在引用层做过滤（filter_by_dict_ref），不须解压实际值——这是键级性能优化
3. **位宽自适应**：根据字典大小动态选择引用位宽（1/2/4 字节），位打包模式更极致

### 编码效率 vs 解码效率

| | 编码端 (Encoder) | 解码端 (Decoder) |
|--|------------------|------------------|
| **计算密集度** | 高 — 哈希表构建、多种编码器尝试 | 低 — 主要查表 + 拷贝 |
| **内存使用** | 高 — 缓冲区 + 哈希表 + 前缀树 | 低 — 按需解码 |
| **优化重点** | 编码器选择速度 | 批量解码 + SIMD |

设计原则是：**写入慢一点可以接受，读取必须快**。解码器大量使用 SIMD、bit unpack 模板特化和批量解码。

### 编码器选择策略

OceanBase 采用**启发式 + 贪心比较**而不是随机采样：

1. **全量扫描**：prescan 构建整个列的哈希表（O(n) 全量扫描，不是采样）
2. **贪心最佳**：遍历所有编码器，选择压缩率最优的
3. **剪枝优化**：early exit（acceptable_size 机制）、基数阈值（RLE/Const 只试低基数）
4. **历史引导**：try_previous_encoder 利用上一个 Micro Block 的编码选择作为提示

为什么不采样？——编码发生在**写入路径**（Compaction 或 DML），数据已经在内存中，全量扫描的额外开销相对于编码处理很小。

### 与 ObDatum 的兼容性

编码引擎的最终输出必须还原为 `ObDatum`（文章 24 的主题）。解码器通过以下方式确保兼容：

- `ObDictDecoder` 输出的 `ObDatum` 直接指向字典表内存（零拷贝）
- `ObConstDecoder` 为常量和异常行产生正确的 NULL/NOP/值语义
- `ObSpanColumnDecoder` 需要访问参考列的解码结果（级联解码）

---

## 10. 源码索引

| 符号/函数 | 文件 | 行号 | 说明 |
|-----------|------|------|------|
| `ObMicroBlockEncoder` | `ob_micro_block_encoder.h` | 34 | 编码引擎主入口 |
| `pivot()` | `ob_micro_block_encoder.cpp` | 448 | 行转列 |
| `build_block()` | `ob_micro_block_encoder.cpp` | 561 | 构建编码块 |
| `encoder_detection()` | `ob_micro_block_encoder.cpp` | 1259 | 编码器检测 |
| `prescan()` | `ob_micro_block_encoder.cpp` | 1195 | 列预扫描 |
| `fast_encoder_detect()` | `ob_micro_block_encoder.cpp` | 1318 | 快速路径 |
| `choose_encoder()` | `ob_micro_block_encoder.cpp` | 1603 | 编码器选择算法 |
| `ObColumnEncodingCtx` | `ob_block_sstable_struct.h` | 496 | 列编码上下文 |
| `ObColumnHeader::Type` | `ob_block_sstable_struct.h` | 203 | 编码类型枚举（值：RAW/DICT/RLE/CONST/.../MAX_TYPE，至 216 行） |
| `build_column_encoding_ctx()` | `ob_encoding_hash_util.cpp` | 374 | 构建列特征 |
| `ObDictEncoder::traverse()` | `ob_dict_encoder.cpp` | 83 | 字典编码遍历 |
| `ObDictEncoder::build_dict()` | `ob_dict_encoder.cpp` | 135 | 字典构建 |
| `ObDictEncoder::store_meta()` | `ob_dict_encoder.cpp` | 187 | 字典元数据存储 |
| `ObDictEncoder::store_fix_data()` | `ob_dict_encoder.cpp` | 380 | 字典定长数据存储 |
| `ObConstEncoder::traverse()` | `ob_const_encoder.cpp` | 36 | 常量编码遍历 |
| `ObEncoderAllocator` | `ob_encoding_allocator.h` | 60 | 编码器分配器 |
| `ObBitStream` | `ob_bit_stream.h` | 37 | 位流工具 |
| `ObDictMetaHeader` | `ob_dict_encoder.h` | 31 | 字典元数据头 |
| `ObConstMetaHeader` | `ob_const_encoder.h` | 34 | 常量元数据头 |
| `ObStringPrefixMetaHeader` | `ob_string_prefix_encoder.h` | 38 | 前缀编码元数据头 |
| `ObStringPrefixCellHeader` | `ob_string_prefix_encoder.h` | 29 | 前缀编码行数据头 |
| `ObStringDiffHeader` | `ob_string_diff_encoder.h` | 27 | 差值编码元数据头 |
| `ObColumnEqualMetaHeader` | `ob_column_equal_encoder.h` | 25 | 等值编码元数据头 |
| `DictCmpRefAVX512Func_T` | `ob_dict_decoder_simd.cpp` | 23 | SIMD 字典引用比较 |
| `ObIMicroBlockWriter` | `ob_imicro_block_writer.h` | — | Micro 块写入接口 |

### 文件统计

```
src/storage/blocksstable/encoding/ — 总计 73 文件，29,203 行

关键文件大小：
  ob_micro_block_encoder.cpp      1,944 行
  ob_dict_encoder.cpp               403 行
  ob_dict_decoder.cpp             1,845 行
  ob_dict_decoder_simd.cpp          183 行
  ob_const_encoder.cpp              411 行
  ob_const_decoder.cpp            1,039 行
  ob_string_prefix_encoder.cpp      323 行
  ob_string_prefix_decoder.cpp      362 行
  ob_string_diff_encoder.cpp        425 行
  ob_string_diff_decoder.cpp        442 行
  ob_column_equal_encoder.cpp       157 行
  ob_column_equal_decoder.cpp       231 行
  ob_bit_stream.h                   321 行
  ob_encoding_allocator.h/cpp       206 行
  ob_encoding_hash_util.h/cpp       618 行
  ob_encoding_util.h/cpp            731 行
  ob_encoding_bitset.h/cpp          513 行
```

---

> **本文分析基于 OceanBase 主线源码。所有行号通过 doom-lsp（clangd LSP）验证。**
>
> 下一篇预览：**Micro Block 解码器 — 查询时如何从编码列高效还原数据**
