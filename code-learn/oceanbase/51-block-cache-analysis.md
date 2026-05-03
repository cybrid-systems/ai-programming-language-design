# 51 — Block Cache 体系：Row Cache、Bloom Filter Cache、Cache Suite

> OceanBase CE 源码深度分析系列
> 主题：多级存储缓存体系 — 从 Row Cache 到 Bloom Filter Cache，再到 Cache Suite 的全局协调

---

## 0. 前言

在之前的文章中，我们详细分析了 SSTable 格式（08）和数据完整性校验（46），其中提到了 Bloom Filter 用于快速判断 key 是否存在。但 OceanBase 的缓存体系远不止 Bloom Filter 一个组件。

对于一个分布式数据库来说，IO 是最大的瓶颈。为了尽可能减少磁盘读取，OceanBase 构建了一个**多级缓存体系**：从最上层的行缓存（Row Cache），到中间的微块缓存（Micro Block Cache），再到底层的 Bloom Filter 缓存，以及用于宽表优化的融合行缓存（Fuse Row Cache）。

这些缓存由一个统一的**缓存套件管理器** `ObStorageCacheSuite` 管理。本文将深入分析每一级缓存的设计、实现和协作方式。

---

## 1. 缓存体系全景

```
SQL Query / DAS Scan
        │
        ▼
┌─────────────────────┐      ┌──────────────────┐
│   ObStorageCacheSuite │────▶│  缓存实例注册表   │
│   (Singleton)        │      │  · 缓存名称       │
└────────┬────────────┘      │  · 优先级         │
         │                   │  · 内存限制百分比   │
         │                   └──────────────────┘
         │
         ├──▶ Row Cache (ObRowCache)
         │      Key: tenant_id + tablet_id + rowkey + data_version
         │      Value: 解码后的行 Datum 数组
         │      命中 → 直接返回行数据，完全跳过存储层
         │
         ├──▶ Fuse Row Cache (ObFuseRowCache)
         │      Key: tenant_id + tablet_id + rowkey + schema_column_count
         │      Value: 融合后的行 Datum 数组
         │      命中 → 直接返回宽表行，减少列合并开销
         │
         ├──▶ Multi-Version Fuse Row Cache
         │      Key: (begin_version, end_version] + fuse_row_key
         │      多版本融合行，MVCC 场景下的宽表优化
         │
         ├──▶ Bloom Filter Cache (ObBloomFilterCache)
         │      Key: tenant_id + macro_block_id + prefix_rowkey_len
         │      Value: Bloom Filter 位图
         │      命中 "不包含" → 跳过整个 Macro Block 的 IO
         │
         ├──▶ Micro Block Cache — 数据块 (ObDataMicroBlockCache)
         │      Key: macro_block_id + offset + size (物理) 或 logic_micro_id (逻辑)
         │      Value: 已解码的微块数据
         │      命中 → 避免解码/解压缩
         │
         ├──▶ Micro Block Cache — 索引块 (ObIndexMicroBlockCache)
         │      同上，但缓存的是索引微块，优先级更高
         │
         ├──▶ Storage Meta Cache
         │      存储元数据缓存
         │
         ├──▶ Truncate Info Cache / TTL Filter Info Cache
         │      截断信息 / TTL 过滤缓存
         │
         └──▶ Tablet Split Cache
              DDL 分裂缓存
```

### 1.1 查询路径中的缓存查找顺序

一条点查或范围查询在 DAS 层发起后，缓存的查找顺序如下：

```
DAS Scan Start
    │
    ▼
┌──────────────────┐
│ Row Cache 查找    │  ← 最上层缓存，直接命中数据行
│ (get_row)        │
└──────┬───────────┘
       │
  未命中 ▼
┌──────────────────┐
│ Fuse Row Cache   │  ← 如果访问的列是完整 row 的子集
│ (get_row)        │
└──────┬───────────┘
       │
  未命中 ▼
┌──────────────────┐
│ Bloom Filter     │  ← 检查这个 macro block 是否可能包含目标 key
│ (may_contain)    │
└──────┬───────────┘
       │
  "可能包含" ▼
┌──────────────────┐
│ Micro Block Cache│  ← 查找已解码的微块
│ (get_cache_block)│
└──────┬───────────┘
       │
  未命中 ▼
┌──────────────────┐
│ AIO → IO Scheduler│  ← 异步读盘 + 解码
│ → 解码            │
│ → 写入微块缓存    │  ← 回填所有缓存层级
│ → 写入行缓存      │
│ → 写入 Bloom Filter│
└──────────────────┘
```

---

## 2. ObStorageCacheSuite — 缓存套件管理器

### 2.1 源码位置

- 头文件：`src/storage/blocksstable/ob_storage_cache_suite.h`
- 实现：`src/storage/blocksstable/ob_storage_cache_suite.cpp`

### 2.2 单例模式

```cpp
// ob_storage_cache_suite.h:32
class ObStorageCacheSuite
{
public:
  static ObStorageCacheSuite &get_instance();
  // ...
};

// ob_storage_cache_suite.cpp:40-43
ObStorageCacheSuite &ObStorageCacheSuite::get_instance()
{
  static ObStorageCacheSuite instance_;
  return instance_;
}
```

`ObStorageCacheSuite` 是一个**单例**（Meyer's Singleton），通过 `OB_STORE_CACHE` 宏访问：

```cpp
// ob_storage_cache_suite.h:8
#define OB_STORE_CACHE oceanbase::blocksstable::ObStorageCacheSuite::get_instance()
```

### 2.3 管理的缓存实例

```cpp
// ob_storage_cache_suite.h:72-81 (private fields)
ObIndexMicroBlockCache index_block_cache_;      // 索引微块缓存
ObDataMicroBlockCache user_block_cache_;         // 数据微块缓存
ObRowCache user_row_cache_;                      // 行缓存
ObBloomFilterCache bf_cache_;                    // Bloom Filter 缓存
ObFuseRowCache fuse_row_cache_;                  // 融合行缓存
ObStorageMetaCache storage_meta_cache_;          // 存储元数据缓存
ObMultiVersionFuseRowCache multi_version_fuse_row_cache_; // 多版本融合行缓存
ObMDSInfoKVCacheWrapper mds_info_cache_;        // MDS 信息缓存
ObTabletSplitCache tablet_split_cache_;          // Tablet 分裂缓存
```

共管理 **9 个** 不同类型的缓存实例。

### 2.4 初始化

```cpp
// ob_storage_cache_suite.cpp:46-88
int ObStorageCacheSuite::init(
    const int64_t index_block_cache_priority,    // 索引块缓存优先级
    const int64_t user_block_cache_priority,      // 用户块缓存优先级
    const int64_t user_row_cache_priority,         // 行缓存优先级
    const int64_t fuse_row_cache_priority,         // 融合行缓存优先级
    const int64_t bf_cache_priority,               // Bloom Filter 优先级
    const int64_t bf_cache_miss_count_threshold,   // BF 空读阈值
    const int64_t storage_meta_cache_priority)     // 元数据缓存优先级
```

每个缓存实例通过 `init(name, priority)` 注册到全局 KV Cache 系统。**优先级**（priority）决定了缓存在内存竞争时的保留权重。

### 2.5 缓存分发

```cpp
// ob_storage_cache_suite.h:52-64
ObDataMicroBlockCache &get_block_cache() { return user_block_cache_; }
ObIndexMicroBlockCache &get_index_block_cache() { return index_block_cache_; }
ObDataMicroBlockCache &get_micro_block_cache(const bool is_data_block)
{ return is_data_block ? user_block_cache_ : index_block_cache_; }
ObRowCache &get_row_cache() { return user_row_cache_; }
ObBloomFilterCache &get_bf_cache() { return bf_cache_; }
ObFuseRowCache &get_fuse_row_cache() { return fuse_row_cache_; }
```

`get_micro_block_cache(is_data_block)` 是一个关键的分发方法：根据是否数据块选择数据块缓存或索引块缓存。索引块缓存（priority=10）的默认优先级高于数据块缓存（priority=1）。

---

## 3. ObKVCache 通用缓存基础设施

在分析各个缓存组件之前，先了解它们共同的基石：`ObKVCache`。

### 3.1 核心抽象

```cpp
// src/share/cache/ob_kv_storecache.h:58-59
template <class Key, class Value>
class ObKVCache : public ObIKVCache<Key, Value>
```

所有缓存都继承自 `ObKVCache<Key, Value>`，它提供了：
- `put(key, value)` — 写入缓存
- `get(key, pvalue, handle)` — 读取缓存
- `alloc(tenant_id, key_size, value_size, ...)` — 预分配缓存空间
- `init(name, priority, mem_limit_pct)` — 注册到全局系统

### 3.2 缓存键值对结构

```cpp
// src/share/cache/ob_kvcache_struct.h:60-75
struct ObKVCachePair
{
  uint32_t magic_;           // KVPAIR_MAGIC_NUM = 0x4B564B56 ("KVKV")
  int32_t size_;
  ObIKVCacheKey *key_;
  ObIKVCacheValue *value_;
};
```

Key 和 Value 分别继承 `ObIKVCacheKey` 和 `ObIKVCacheValue`，必须实现：
- `size()` — 占用内存大小
- `deep_copy(buf, buf_len, ...)` — 深拷贝到缓存内存块
- `hash()` / `equal()` — 哈希和相等比较

### 3.3 缓存淘汰策略

```cpp
// src/share/cache/ob_kvcache_struct.h:76-79
enum ObKVCachePolicy
{
  LRU = 0,
  LFU = 1,
  MAX_POLICY = 2
};
```

`ObKVGlobalCache` 支持 LRU 和 LFU 两种淘汰策略，通过**定时 Wash 线程**执行：

```cpp
// src/share/cache/ob_kv_storecache.h:199-200
class ObKVGlobalCache : public lib::ObICacheWasher
```

Wash 线程每隔 `cache_wash_interval` 检查所有缓存实例的内存使用情况。淘汰决策基于**综合评分**：

```cpp
// src/share/cache/ob_kvcache_struct.h:246 (ObKVCacheStoreMemblockInfo)
// score_ 基于：
//   priority_       — 缓存实例的优先级（权重越高越不被淘汰）
//   recent_get_cnt_ — 近期访问频率（越活跃越不被淘汰）
```

当内存使用超过限制时，`flush_washable_mbs()` 会从低分的内存块开始淘汰，直到释放足够内存。这种机制类似于**加权 LRU**，但更精细：高优先级的缓存（如索引块缓存、Bloom Filter）在内存压力下保留的时长更长。

### 3.4 租户级缓存隔离

`ObKVGlobalCache` 支持多租户隔离：
- 每个缓存实例注册时指定 `tenant_id`
- wash 操作可以指定 `tenant_id`，按租户回收
- `sync_wash_mbs(tenant_id, wash_size, ...)` 按租户同步洗刷

---

## 4. ObRowCache — 行缓存

### 4.1 源码位置

- 头文件：`src/storage/blocksstable/ob_row_cache.h`
- 实现：`src/storage/blocksstable/ob_row_cache.cpp`

### 4.2 设计目标

行缓存是缓存体系中**最上层**的缓存。当一条 SQL 点查命中行缓存时，可以**完全跳过存储层**（包括 SSTable 扫描、Bloom Filter 检查、微块解码等所有 IO 操作）。

### 4.3 缓存键

```cpp
// ob_row_cache.h:26-55
class ObRowCacheKey : public common::ObIKVCacheKey
{
  int64_t rowkey_size_;
  int64_t tenant_id_;            // 租户 ID
  ObTabletID tablet_id_;         // Tablet ID（表分区）
  int64_t data_version_;         // 数据版本
  storage::ObITable::TableType table_type_;  // 表类型
  ObDatumRowkey rowkey_;         // 行键
  const ObStorageDatumUtils *datum_utils_;   // Datum 工具方法
};
```

键由 `{tenant_id, tablet_id, data_version, table_type, rowkey}` 五元组唯一确定。这确保了：
- **租户隔离**：不同租户的数据 key 哈希不同
- **分区隔离**：相同 rowkey 在不同分区中独立缓存
- **版本感知**：不同版本的数据版本号不同，新版本不会错误命中旧缓存

### 4.4 缓存值

```cpp
// ob_row_cache.h:60-86
class ObRowCacheValue : public common::ObIKVCacheValue
{
  ObStorageDatum *datums_;       // 解码后的 Datum 数组
  ObDmlRowFlag flag_;            // DML 标记
  int64_t size_;                 // 数据大小
  int64_t column_cnt_;           // 列数
  int64_t start_log_ts_;         // 起始日志时间戳
  MacroBlockId block_id_;        // 所属 Macro Block 的 ID
};
```

关键设计：**空行标记**。

```cpp
// ob_row_cache.h:69-70
inline void set_row_not_exist() { datums_ = nullptr; size_ = 0; }
inline bool is_row_not_exist() const { return 0 == size_; }
```

当查询到一个不存在的行时，不会缓存实际数据（因为没有数据），而是缓存一个 `size_=0` 的空值标记。后续对该行的相同查询可以直接从缓存中获知"此行不存在"，无需再走一次完整的 SSTable 扫描路径。

### 4.5 接口

```cpp
// ob_row_cache.h:117-123
class ObRowCache : public common::ObKVCache<ObRowCacheKey, ObRowCacheValue>
{
public:
  int get_row(const ObRowCacheKey &key, ObRowValueHandle &handle);  // 查询行
  int put_row(const ObRowCacheKey &key, const ObRowCacheValue &value);  // 写入行
};
```

### 4.6 写操作的影响

当 DML 操作（INSERT/UPDATE/DELETE）发生时：
1. 对应的行缓存条目会被**无效化**（`ObKVCacheHandle::reset()` 类型的机制）
2. 行缓存不会主动更新为最新值（由 Memtable 的新版本接管可见性判断）
3. 等 Memtable 冻结合并为 SSTable 后，行缓存需要在新的 SSTable 扫描时重新填充

这是 OceanBase 的 **"读时填充"** 策略：缓存只在读取时建立，写操作只负责失效。

---

## 5. ObFuseRowCache — 融合行缓存

### 5.1 源码位置

- 头文件：`src/storage/blocksstable/ob_fuse_row_cache.h`

### 5.2 设计动机

宽表（包含数百列）是 OceanBase 的典型业务场景。如果一个表有 500 列，但查询只访问 5 列：
- Row Cache 缓存整行 → 空间浪费
- 不缓存 → 每次都要解码整个微块

**Fuse Row Cache** 在两者之间取得平衡：缓存的是按照 Schema 列数"融合"后的完整行，但引入了一个 **schema_column_count** 维度来区分不同的列子集访问模式。

### 5.3 单版本 Fuse Row Cache

```cpp
// ob_fuse_row_cache.h:19-64
class ObFuseRowCacheKey : public common::ObIKVCacheKey
{
  ObFuseRowCacheKeyBase base_;  // tenant_id + tablet_id + rowkey
  // schema_column_count_ 在 ObFuseRowCacheKeyBase 中
};

class ObFuseRowCacheValue : public common::ObIKVCacheValue
{
  ObStorageDatum *datums_;           // 解码后的列数据
  int64_t size_;
  int32_t column_cnt_;               // 列数
  int64_t read_snapshot_version_;    // 读取快照版本
  ObDmlRowFlag flag_;
};
```

### 5.4 多版本 Fuse Row Cache

```cpp
// ob_fuse_row_cache.h:101-131
class ObMultiVersionFuseRowCacheKey : public common::ObIKVCacheKey
{
  ObFuseRowCacheKeyBase base_;
  int64_t begin_version_;    // 开始版本（不包含）
  int64_t end_version_;      // 结束版本（包含）
};
```

多版本版本键添加了 `(begin_version_, end_version_]` 版本范围，使得 MVCC 场景下可以缓存特定版本范围内的融合行。

### 5.5 与 Row Cache 的协作

Row Cache 和 Fuse Row Cache 是缓存*同一行数据*的两个不同入口。查询路径中：
1. 先查 Row Cache（key 包含 data_version + table_type）
2. 没命中则查 Fuse Row Cache（key 包含 schema_column_count）
3. 都没命中 → SSTable 扫描 → 同时回填两个缓存

这种双缓存设计允许不同维度的命中：相同 rowkey 但不同 column_mask 的查询可以从 Fuse Row Cache 复用部分数据。

---

## 6. ObBloomFilterCache — Bloom Filter 缓存

### 6.1 源码位置

- 头文件：`src/storage/blocksstable/ob_bloom_filter_cache.h`
- 实现：`src/storage/blocksstable/ob_bloom_filter_cache.cpp`

### 6.2 Bloom Filter 核心

```cpp
// ob_bloom_filter_cache.h:31-63
class ObBloomFilter
{
public:
  static constexpr double BLOOM_FILTER_FALSE_POSITIVE_PROB = 0.01;  // 1% 误判率
  int init_by_row_count(const int64_t element_count,
                        const double false_positive_prob = BLOOM_FILTER_FALSE_POSITIVE_PROB);
  int insert(const uint32_t key_hash);           // 插入 key 哈希值
  int may_contain(const uint32_t key_hash,        // 可能包含？
                  bool &is_contain) const;
  int merge(const ObBloomFilter &src_bf);         // 合并两个 Bloom Filter
  int64_t calc_nbyte(const int64_t nbit) const;   // 比特数 → 字节数
  double calc_nhash(const double prob) const;      // 误判率 → 哈希函数数量
private:
  common::ObArenaAllocator allocator_;
  int64_t nhash_;   // 哈希函数个数
  int64_t nbit_;    // 位图比特数
  uint8_t *bits_;   // 位图数据
};
```

核心参数：
- **误判率** `BLOOM_FILTER_FALSE_POSITIVE_PROB = 0.01` → 默认允许 1% 的误判率
- `nhash_` 和 `nbit_` 通过 `init_by_row_count(element_count)` 根据行数自动计算
- `insert()` 和 `may_contain()` 使用哈希值（而非原始 key），计算效率高

### 6.3 缓存键和值

```cpp
// ob_bloom_filter_cache.h:68-86
class ObBloomFilterCacheKey : public common::ObIKVCacheKey
{
  uint64_t tenant_id_;            // 租户 ID
  MacroBlockId macro_block_id_;   // Macro Block ID
  int8_t prefix_rowkey_len_;      // 前缀 rowkey 长度（用于分区键前缀 Bloom Filter）
};

// ob_bloom_filter_cache.h:91-125
class ObBloomFilterCacheValue : public common::ObIKVCacheValue
{
  int16_t version_;               // 缓存版本号
  int16_t rowkey_column_cnt_;     // rowkey 列数
  int32_t row_count_;             // Bloom Filter 中的行数
  ObBloomFilter bloom_filter_;    // 实际的 Bloom Filter
};
```

键由 **Macro Block 级别**确定：`{tenant_id, macro_block_id, prefix_rowkey_len}`。
这意味着每个 Macro Block 最多有一个缓存条目（及其前缀变体）。

### 6.4 自适应构建机制

Bloom Filter Cache 最有趣的设计是**自适应构建**。它不会在写入 SSTable 时立即构建 Bloom Filter，而是在**多次空读**后才触发构建：

```cpp
// ob_bloom_filter_cache.h:232-233
int check_need_build(const ObBloomFilterCacheKey &bf_key, bool &need_build);
int check_need_load(const ObBloomFilterCacheKey &bf_key, bool &need_load);
```

核心逻辑在 `inc_empty_read()`（`ob_bloom_filter_cache.cpp:816`）：

1. 每次查询在 Bloom Filter 中未找到某个 key 时，**空读计数** +1
2. 当空读计数超过 `bf_cache_miss_count_threshold_` 时：
   - 如果 SSTable 中已存在 Bloom Filter 数据 → 调度加载 `schedule_load_bloomfilter()`
   - 如果 SSTable 没有预先生成 Bloom Filter → 调度构建 `schedule_build_bloomfilter()`
3. 构建完成后，写回缓存，后续对该 Macro Block 的查询先检查 Bloom Filter

### 6.5 自适应的阈值调节

```cpp
// ob_bloom_filter_cache.h:215-231
inline void auto_bf_cache_miss_count_threshold(const int64_t qsize)
{
  if (OB_UNLIKELY(bf_cache_miss_count_threshold_ <= 0)) {
    // disable bf_cache_, do nothing
  } else {
    // newsize = base * (1 + (qsize / speed) ^ 2)
    uint64_t newsize = static_cast<uint64_t>(qsize) >> BF_BUILD_SPEED_SHIFT;
    newsize = GCONF.bf_cache_miss_count_threshold * (1 + newsize * newsize);
    if (newsize != bf_cache_miss_count_threshold_) {
      bf_cache_miss_count_threshold_ = newsize < MAX_EMPTY_READ_CNT_THRESHOLD
                                     ? newsize : MAX_EMPTY_READ_CNT_THRESHOLD;
    }
  }
}
```

当构建 Bloom Filter 的任务队列变长时（`qsize` 增大），阈值**自动增大**，抑制新的 BF 构建请求，形成负反馈调节。这防止了在高并发下 BF 构建任务雪崩。

### 6.6 多个 may_contain 重载

```cpp
// ob_bloom_filter_cache.h:166-196
int may_contain(const uint64_t tenant_id, const MacroBlockId &macro_block_id,
                const ObDatumRowkey &rowkey, ...);          // 单 key 检查

int may_contain(const uint64_t tenant_id, const MacroBlockId &macro_block_id,
                const storage::ObRowsInfo *rows_info,
                const int64_t rowkey_begin_idx, const int64_t rowkey_end_idx,
                ...);                                       // 批量 row 检查

int may_contain(const uint64_t tenant_id, const MacroBlockId &macro_block_id,
                const storage::ObRowKeysInfo *rowkeys_info,
                const int64_t rowkey_begin_idx, const int64_t rowkey_end_idx,
                ...);                                       // 批量 rowkey 检查
```

三个重载分别支持：单行点查、批量行查询、批量 rowkey 查询。底层的 Bloom Filter 操作是 O(1) 的哈希检查，非常适合批量判断。

### 6.7 写缓存辅助类

```cpp
// ob_bloom_filter_cache.h:259-281
class ObMacroBloomFilterCacheWriter
{
public:
  int init(const int64_t rowkey_column_count, const int64_t row_count);
  int append(const common::ObArray<uint32_t> &hashs);  // 追加哈希值
  bool can_merge(const ObMacroBloomFilterCacheWriter &other);
  int merge(const ObMacroBloomFilterCacheWriter &other);
  int flush_to_cache(const uint64_t tenant_id, const MacroBlockId& macro_id);  // 写入缓存
};
```

`ObMacroBloomFilterCacheWriter` 用于在 SSTable 构建过程中积累 Bloom Filter 数据。它支持 `append()` 追加行哈希，`merge()` 合并多个写入器，最后 `flush_to_cache()` 写入缓存。

---

## 7. ObMicroBlockCache — 微块缓存

### 7.1 源码位置

- 头文件：`src/storage/blocksstable/ob_micro_block_cache.h`
- 实现：`src/storage/blocksstable/ob_micro_block_cache.cpp`

### 7.2 设计目标

微块（Micro Block）是 OceanBase SSTable 中最小的 IO 单元（通常 64KB～256KB）。微块在磁盘上是**压缩/编码**的，读取时需要解码后使用。

微块缓存的目标就是**避免重复解码**：同一微块被多次访问时，直接从缓存返回解码后的数据。

### 7.3 两种 Key 模式

```cpp
// ob_micro_block_cache.h:27-28
enum class ObMicroBlockCacheKeyMode : int8_t
{
  PHYSICAL_KEY_MODE = 0,   // 物理模式
  LOGICAL_KEY_MODE = 1,    // 逻辑模式
};

// ob_micro_block_cache.h:30-81
class ObMicroBlockCacheKey : public common::ObIKVCacheKey
{
  ObMicroBlockCacheKeyMode mode_;
  uint64_t tenant_id_;
  union {
    ObMicroBlockId block_id_;             // 物理模式：macro_id + offset + size
    ObLogicMicroBlockId logic_micro_id_;  // 逻辑模式：逻辑微块 ID
  };
  int64_t data_checksum_;                 // 数据校验和
};
```

- **物理模式**：由 `{macro_block_id, offset_in_macro, size}` 唯一标识一个微块
- **逻辑模式**：由 `{logic_micro_id, data_checksum}` 标识。当微块在合并/Compaction 后物理位置改变但逻辑内容不变时，可以继续命中缓存

```cpp
// 构造物理 key
key.set(tenant_id, macro_block_id, offset, size);

// 构造逻辑 key
key.set(tenant_id, logic_micro_id, data_checksum);
```

### 7.4 缓存值

```cpp
// ob_micro_block_cache.h:89-109
class ObMicroBlockCacheValue : public common::ObIKVCacheValue
{
  ObMicroBlockData block_data_;  // 已解码的微块数据
};
```

简单包装：`ObMicroBlockData` 包含解码后的 `{buf, size, type}`。

### 7.5 缓存结构

```cpp
// ob_micro_block_cache.h:363-376
class ObDataMicroBlockCache
  : public common::ObKVCache<ObMicroBlockCacheKey, ObMicroBlockCacheValue>,
    public ObIMicroBlockCache
{
  // 数据微块缓存
};

// ob_micro_block_cache.h:378-387
class ObIndexMicroBlockCache : public ObDataMicroBlockCache
{
  // 索引微块缓存（继承自数据微块缓存）
};
```

`ObDataMicroBlockCache` 和 `ObIndexMicroBlockCache` 是两个独立的缓存实例。索引微块缓存默认优先级为 10，数据微块缓存默认为 1。

### 7.6 IO 回调机制

读取微块时，通过 IO 回调机制实现"读 + 解码 + 缓存"的一体化：

```cpp
// ob_micro_block_cache.h:183-217
class ObIMicroBlockIOCallback : public common::ObIOCallback
{
protected:
  ObIMicroBlockCache *cache_;           // 目标缓存
  uint64_t tenant_id_;
  MacroBlockId block_id_;
  int64_t offset_;
  ObLogicMicroBlockId logic_micro_id_;
  int64_t data_checksum_;
  ObMicroBlockDesMeta block_des_meta_;
  bool use_block_cache_;
};
```

回调类型有三种：

| 回调类 | 用途 |
|--------|------|
| `ObAsyncSingleMicroBlockIOCallback` | 单微块异步预读 |
| `ObMultiDataBlockIOCallback` | 多微块批量读取 |
| `ObSyncSingleMicroBLockIOCallback` | 同步读取 |

### 7.7 批量预读

```cpp
// ob_micro_block_cache.h:157-171
struct ObMultiBlockIOParam
{
  static const int64_t MAX_MICRO_BLOCK_READ_COUNT = 1 << 12;  // 最多 4096 个微块
  int64_t micro_block_count_;
  int64_t io_read_batch_size_;    // IO 批大小
  int64_t io_read_gap_size_;      // IO 间隙
};
```

`ObMultiBlockIOParam` 支持合并相邻微块为一次 IO 请求。当多个微块在 Macro Block 中物理上相邻时，合并读取能显著提升 IO 效率。

### 7.8 读路径调用链

```
ObIMicroBlockCache::get_cache_block(key, handle)
    │
    ├── 命中 → 返回 ObMicroBlockBufferHandle
    │
    └── 未命中
        │
        ├── ObIMicroBlockCache::prefetch(...) 
        │    → 创建 AsyncSingleMicroBlockIOCallback
        │    → ObObjectManager::async_read_object(...)
        │
        └── IO 完成 → IO 回调
             → ObIMicroBlockIOCallback::inner_process()
             → ObMacroBlockReader 解码微块
             → cache->put_cache_block(...) 写入缓存
             → 返回 ObMicroBlockData
```

---

## 8. 缓存淘汰策略详解

### 8.1 综合评分淘汰

OceanBase 的缓存淘汰不是简单的 LRU，而是基于 **优先级 + 近期访问频率** 的综合评分：

```
score = f(priority_, recent_get_cnt_)
```

`priority_` 是在 `init(name, priority)` 时设置的权重，高优先级缓存条目在内存压力下被保留的几率更高。

### 8.2 默认优先级分布

| 缓存实例 | 默认 Priority | 说明 |
|----------|-------------|------|
| 索引微块缓存 | 10 | 索引块比数据块更重要 |
| 数据微块缓存 | 1 | 可通过参数调整 |
| Bloom Filter 缓存 | 通过 init 参数 | 通常也较高 |
| Row Cache | 通过 init 参数 | 取决于业务模式 |
| Fuse Row Cache | 通过 init 参数 | 宽表场景更重要 |
| Storage Meta Cache | 通过 init 参数 | 元数据稳定 |
| MDS Info Cache | 10 | 固定优先级 |
| Tablet Split Cache | 10 | 固定优先级 |

### 8.3 定时 Wash

```cpp
// src/share/cache/ob_kv_storecache.h:221-227
class KVStoreWashTask: public ObTimerTask
{
  virtual void runTimerTask()
  {
    ObKVGlobalCache::get_instance().wash();
  }
};
```

Wash 任务定期运行。当内存超限时：
1. 按租户遍历缓存实例
2. 对每个缓存实例计算 `score`
3. 从低分到高分淘汰内存块
4. `flush_washable_mbs()` 释放内存

### 8.4 内存限制

每个缓存实例的 `init()` 接受 `mem_limit_pct` 参数（默认 100%），表示该缓存可使用的总内存百分比。实际可用内存由 `ObKVGlobalCache` 的 `max_cache_size` 统一控制。

---

## 9. 缓存的数据流与协作

### 9.1 完整点查路径

```
SQL: SELECT c1, c2 FROM t1 WHERE id = 42

1. DAS Scan 开始
2. 构造 ObRowCacheKey(tenant_id, tablet_id, rowkey, data_version, table_type)
   → ObRowCache::get_row(key, handle)
   │  ┌ 行缓存命中 → 返回 ObRowValueHandle → 直接返回结果
   │  └ 未命中 → 继续
   
3. 构造 ObFuseRowCacheKey(tenant_id, tablet_id, rowkey, schema_column_count)
   → ObFuseRowCache::get_row(key, handle)
   │  ┌ 融合行缓存命中 → 返回数据
   │  └ 未命中 → 继续
   
4. 查找 SSTable
   → 遍历 Macro Block 索引
   → 对每个候选 Macro Block:
   │  ObBloomFilterCache::may_contain(tenant_id, macro_id, rowkey, ...)
   │  ┌ "肯定不存在" → 跳过整个 Macro Block
   │  └ "可能包含" → 继续检查
   │     │
   │     ObDataMicroBlockCache::get_cache_block(key, handle)
   │     ┌ 微块缓存命中 → 返回解码后的数据
   │     └ 未命中 → 异步 IO → 解码 → 写缓存
   
5. 找到行数据后
   → ObRowCache::put_row(key, value)         // 回填行缓存
   → ObFuseRowCache::put_row(key, value)     // 回填融合行缓存
```

### 9.2 范围扫描路径

范围扫描的主要差异在**微块缓存**的使用上：

```
1. 跳过 Row Cache（范围查询一般不查行缓存）
2. 遍历 Macro Block 索引
3. 对 Macro Block:
   → Bloom Filter 批量检查 (ObRowKeysInfo)
4. 需要读取的微块：
   → ObMultiBlockIOParam 合并相邻微块
   → ObDataMicroBlockCache::prefetch_multi_block(...)
   → 批量异步 IO + 解码 + 写缓存
5. 逐个微块扫描行数据
```

### 9.3 写操作对缓存的影响

| 操作类型 | Row Cache | Fuse Row Cache | Bloom Filter | Micro Block Cache |
|---------|-----------|----------------|--------------|-------------------|
| INSERT | 无效化 | 无效化 | 无影响 | 无影响 |
| DELETE | 无效化 | 无效化 | 无影响 | 无影响 |
| UPDATE | 无效化 | 无效化 | 无影响 | 无影响 |
| Major Compaction | 全部无效化 | 全部无效化 | Macro ID 变化导致失效 | 逻辑 key 可能继续命中 |
| Minor Compaction | 部分无效化 | 部分无效化 | 合并后可能重建 | 逻辑 key 可能继续命中 |

**关键设计原则**：写操作只负责失效，不负责更新。缓存是在后续读取时**按需重建**的。

---

## 10. 设计决策分析

### 10.1 为什么需要多级缓存？

| 缓存级别 | 粒度 | 命中收益 | 缓存内容 | 典型大小 |
|---------|------|---------|---------|---------|
| Row Cache | 单行 | 完全跳过 IO + 解码 | 解码后的 Datum 行 | 几百字节/行 |
| Fuse Row Cache | 单行（宽表） | 避免列融合 | 完整的列 Datum 数组 | 几 KB/行 |
| Micro Block Cache | 微块 | 避免重新解码 | 解码后的微块数据 | 64-256 KB/块 |
| Bloom Filter | Macro Block | 跳过整个 Macro Block IO | 位图（几十 KB） | 几十 KB/Macro Block |

不同粒度的缓存服务于不同场景。点查高频场景 Row Cache 最有效；范围扫描场景 Micro Block Cache 复用最有效；点查大量 Macro Block 时 Bloom Filter 消除无效 IO。

### 10.2 为什么 Row Cache 需要包含 data_version？

OceanBase 是 MVCC 数据库，同一行数据可能对应多个版本。如果 Row Cache 不包含 `data_version`，旧版本的读取可能错误命中新版本的数据（或反之）。

将 `data_version` 纳入 cache key 确保：
- 不同快照版本的读取互不干扰
- 当 Compaction 产生新版本时，旧版本缓存不会被污染

### 10.3 为什么 Bloom Filter 是自适应构建的？

```cpp
// ob_bloom_filter_cache.h:238
static const int64_t BF_BUILD_SPEED_SHIFT = 4;
static const int64_t DEFAULT_EMPTY_READ_CNT_THRESHOLD = 100;
static const int64_t MAX_EMPTY_READ_CNT_THRESHOLD = 1000000;
```

自适应构建（而非 SSTable 写入时立即构建）的原因是：

1. **写路径性能**：SSTable 写入时构建 Bloom Filter 会显著增加写入延迟
2. **读模式感知**：只有在某个 Macro Block 被频繁查询但都落空时，才值得构建 Bloom Filter
3. **冷热数据识别**：长期不访问的 Macro Block 永远不会构建 Bloom Filter，节省内存
4. **自限性**：通过 `auto_bf_cache_miss_count_threshold()` 防止队列积压

### 10.4 为什么 Micro Block Cache 支持逻辑 key？

Compaction 是 OceanBase 中持续发生的后台操作。当多个 SSTable 合并时，微块的**物理位置**（所属 Macro Block + offset）会发生变化，但微块的**内容**保持不变。

如果只使用物理 key，Compaction 会导致所有微块缓存全部失效。逻辑 key（`logic_micro_id + data_checksum`）让 Compaction 后的缓存仍然可以命中，大幅减少了 Compaction 后的读 IO。

### 10.5 为什么 Row Cache 和 Fuse Row Cache 共存？

两个缓存都缓存行数据，但面向不同的查询模式：
- **Row Cache**：以 `{data_version, table_type}` 为区分，适合**确定版本的等值查询**
- **Fuse Row Cache**：以 `{schema_column_count}` 为区分，适合**列子集不变的范围/扫描查询**

这种重叠设计允许更灵活的缓存命中策略。在实际查询路径中，两者都会检查，谁先命中就返回谁的数据。

---

## 11. 配置参数与调优

### 11.1 缓存内存配置

OceanBase 通过 `ObKVGlobalCache` 的 `max_cache_size` 控制总缓存大小。各缓存的优先级和内存占比通过 `ObStorageCacheSuite::init()` 传入的参数配置。

实际运行时通过 `reset_priority()` 动态调整优先级：

```cpp
// ob_storage_cache_suite.cpp:90-122
int ObStorageCacheSuite::reset_priority(
    const int64_t index_block_cache_priority,
    const int64_t user_block_cache_priority,
    const int64_t user_row_cache_priority,
    ...
)
```

### 11.2 Bloom Filter 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `bf_cache_miss_count_threshold` | 100 | 空读触发 BF 构建的阈值 |
| `BLOOM_FILTER_FALSE_POSITIVE_PROB` | 0.01 (1%) | Bloom Filter 误判率 |
| `BF_BUILD_SPEED_SHIFT` | 4 | 自适应阈值的速率控制 |
| `MAX_EMPTY_READ_CNT_THRESHOLD` | 1,000,000 | 自适应阈值上限 |

### 11.3 微块缓存配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| 索引微块优先级 | 10 | 较高，保护索引块 |
| 数据微块优先级 | 1 | 可通过 `reset_priority` 调整 |
| `MAX_MICRO_BLOCK_READ_COUNT` | 4096 | 单次批量预读最大微块数 |

---

## 12. ASCII 图 — 内存布局

```
ObKVGlobalCache (全局单例)
├── 内存池 (ObKVMemStore)
│   ├── [Bucket 0]  ─── LRU/LFU MemBlock ─── KVPair ─── KVPair ─── ...
│   ├── [Bucket 1]  ─── LRU/LFU MemBlock ─── KVPair
│   ├── [Bucket 2]  ─── ...
│   └── ...
│
├── 租户隔离
│   ├── Tenant 1002 (应用租户 A)
│   │   ├── user_block_cache      (priority=1)
│   │   ├── user_row_cache        (priority=5)
│   │   ├── bf_cache              (priority=3)
│   │   ├── fuse_row_cache        (priority=5)
│   │   └── index_block_cache     (priority=10)
│   │
│   ├── Tenant 1004 (应用租户 B)
│   │   └── (同上结构)
│   │
│   └── SYS Tenant
│       ├── storage_meta_cache    (priority=10)
│       └── mds_info_cache        (priority=10)
│
└── Wash 定时器
    └── 每 cache_wash_interval 运行
        ├── 计算每个 MemBlock 的 score
        ├── 淘汰低分 MemBlock
        └── 回收内存
```

---

## 13. 源码索引

| 组件 | 头文件 | 实现文件 | 关键行 |
|------|--------|---------|--------|
| ObStorageCacheSuite | `storage/blocksstable/ob_storage_cache_suite.h` | `.cpp` | class @32, init @46, destroy @133 |
| ObRowCache | `storage/blocksstable/ob_row_cache.h` | `.cpp` | Key @26, Value @60, class @117 |
| ObFuseRowCache | `storage/blocksstable/ob_fuse_row_cache.h` | — | Key @19, Value @60, class @78 |
| ObMultiVersionFuseRowCache | `storage/blocksstable/ob_fuse_row_cache.h` | — | Key @101, class @128 |
| ObBloomFilter | `storage/blocksstable/ob_bloom_filter_cache.h` | `.cpp` | class @31, FP prob @34 |
| ObBloomFilterCache | `storage/blocksstable/ob_bloom_filter_cache.h` | `.cpp:816` | may_contain @166, inc_empty_read @816 |
| ObMacroBloomFilterCacheWriter | `storage/blocksstable/ob_bloom_filter_cache.h` | — | class @259 |
| ObDataMicroBlockCache | `storage/blocksstable/ob_micro_block_cache.h` | `.cpp` | class @363 |
| ObIndexMicroBlockCache | `storage/blocksstable/ob_micro_block_cache.h` | — | class @378 |
| ObKVCache (基础设施) | `share/cache/ob_kv_storecache.h` | `.cpp` | class @59, init @378 |
| ObKVGlobalCache | `share/cache/ob_kv_storecache.h` | `.cpp` | class @98, wash @666 |
| ObKVCachePair | `share/cache/ob_kvcache_struct.h` | — | struct @60 |

---

## 14. 总结

OceanBase 的多级缓存体系是一个精心设计的**分层缓存系统**：

1. **Row Cache/Fuse Row Cache** — 在最上层缓存行数据，直接跳过整个存储层
2. **Bloom Filter Cache** — 在 Macro Block 级别快速排除不可能包含目标 key 的块
3. **Micro Block Cache** — 缓存已解码的微块，避免重复解码开销
4. **ObStorageCacheSuite** — 统一的缓存管理器，协调 9+ 类缓存实例

关键设计特色：
- **自适应 Bloom Filter 构建** — 不浪费资源在未访问的数据上
- **逻辑 key 支持** — 让 Compaction 后的缓存继续有效
- **优先级 + 访问频率的淘汰机制** — 比简单 LRU 更精细的控制
- **读时填充 + 写时失效** — 简洁的缓存一致性模型
- **租户级隔离** — 多租户场景下的缓存公平性

这些设计加在一起，使得 OceanBase 在点查、范围扫描、宽表读取等不同负载下都能有效地减少磁盘 IO，而无需开发者手动配置复杂的缓存策略。
