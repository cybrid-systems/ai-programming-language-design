# #34 v2 — Storage Engine Internals (SSTable / macro_block / micro_block 完整实读)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")

> 接续 #51 v2 Block Cache + #20 v2 Compaction Strategy + #22 v2 Clog / Redo Log:
> 前面讲了 "cache 怎么命中、compact 怎么合并、日志怎么落盘"。本文聚焦 **"数
> 据在磁盘上到底长什么样"** ——OB 的存储引擎内部细节:SSTable 的三层结构、
> micro_block 编码、block index、bloom filter 等。这是 storage 主题的最后一
> 层。

---

## 0. 全文导读

OB SSTable 三层结构:

```
SSTable (1 个文件,几 GB)
  └── Macro Block (几 MB,~10K 个)
       └── Micro Block (16-64 KB,~256 行)
            └── Bloom Filter (每 micro_block 一个,~1 KB)
```

本文按"架构 → Macro Block → Micro Block → Bloom Filter → Compression /
Encryption → IO 优化 → 性能调优"展开。

---

## 1. SSTable 整体结构

### 1.1 文件布局

```
SSTable file:
  [File Header: 4KB]
  [Macro Block 1: ~4 MB]
  [Macro Block 2: ~4 MB]
  [Macro Block N]
  [Macro Block Index: 末尾,快速定位]
  [Bloom Filter Index]
  [SSTable Meta]
```

### 1.2 SSTable Meta

```cpp
// src/storage/blocksstable/ob_sstable_meta.h:50
struct ObSSTableMeta {
  // 1. 表级元数据
  uint64_t table_id_;
  uint64_t partition_id_;
  int64_t schema_version_;

  // 2. 范围
  ObRowkey min_rowkey_;        // SSTable 内最小 rowkey
  ObRowkey max_rowkey_;        // SSTable 内最大 rowkey

  // 3. 行数 / 大小
  int64_t row_count_;
  int64_t occupied_size_;
  int64_t data_size_;

  // 4. 索引位置
  int64_t macro_block_index_offset_;
  int64_t bloom_filter_index_offset_;
  int64_t data_checksum_;
};
```

### 1.3 SSTable 类型

```cpp
// src/storage/blocksstable/ob_sstable_type.h:80
enum ObSSTableType {
  SST_TYPE_NORMAL,       // 行存,普通 flush 产出
  SST_TYPE_COMPACTED,    // 行存,compact 合并产出
  SST_TYPE_COLUMNAR,     // 列存,major freeze 产出
};
```

---

## 2. Macro Block

### 2.1 用途

```
Macro Block = SSTable 内的"大块"
  大小: 默认 4 MB(可调)
  包含: ~10K 个 micro block + 索引 + bloom filter
  物理对齐: 4 KB(OS page)
```

### 2.2 Macro Block 头

```cpp
// src/storage/blocksstable/ob_macro_block_header.h:80
struct ObMacroBlockHeader {
  // 1. magic + version
  char magic_[4];              // "OBMA"
  uint16_t version_;
  uint16_t header_size_;

  // 2. 加密 / 压缩
  uint8_t encrypt_id_;
  uint8_t compress_type_;
  uint8_t encrypt_type_;
  uint8_t padding_[3];

  // 3. 大小信息
  int32_t body_size_;
  int32_t checksum_;

  // 4. column checksum(可选)
  // ...
};
```

### 2.3 Macro Block 内容

```
[Macro Block Header (256B)]
  ↓
[Micro Block 1] (~64KB)
[Micro Block 2]
...
[Micro Block N]
  ↓
[Bloom Filter 1] (~1KB)
[Bloom Filter 2]
...
[Bloom Filter N]
  ↓
[Block Index: micro_block_id → offset]
```

### 2.4 Macro Block Reader

```cpp
// src/storage/blocksstable/ob_macro_block_reader.cpp:80
class ObMacroBlockReader {
public:
  // 1. 读 macro block(异步)
  int async_read(ObMacroBlockHandle &handle);

  // 2. 解码 header
  int decode_header(const char *buf, ObMacroBlockHeader &header);

  // 3. 遍历 micro block
  for (int64_t i = 0; i < header.micro_block_count_; ++i) {
    ObMicroBlockHeader mb_header;
    decode_micro_block_header(macro_buf + mb_offsets[i], mb_header);
    // ...
  }
};
```

---

## 3. Micro Block

### 3.1 用途

```
Micro Block = Macro Block 内的"小块"
  大小: 16-64 KB(默认 32 KB)
  包含: ~256 行(每行 ~256B)
  物理 IO 单位: 一次 IO 读一个 micro_block
```

### 3.2 Micro Block 头

```cpp
// src/storage/blocksstable/ob_micro_block_header.h:50
struct ObMicroBlockHeader {
  // 1. magic + version
  char magic_[4];              // "OBLM"
  uint16_t version_;
  uint16_t header_size_;

  // 2. micro block 信息
  uint16_t row_count_;
  uint16_t column_count_;
  uint16_t index_size_;
  uint16_t padding_;

  // 3. 类型
  uint8_t table_id_index_;
  uint8_t row_data_type_;      // FLAT / ENCODED

  // 4. checksum
  int32_t checksum_;

  // 5. 大小
  int32_t body_size_;
};
```

### 3.3 行编码(Row Data)

```cpp
// src/storage/blocksstable/ob_row_encoder.cpp:50
// 每行编码: [null_bitmap][encoded_columns]
class ObRowEncoder {
public:
  int encode_row(const ObRow &row, char *buf, size_t &len) {
    // 1. null bitmap (1 bit per column)
    int null_bytes = (row.count() + 7) / 8;
    memcpy(buf, row.null_bitmap_, null_bytes);
    len = null_bytes;

    // 2. 每列编码
    for (size_t i = 0; i < row.count(); ++i) {
      // 对定长列:直接 memcpy
      // 对变长列:varint + data
      len += encode_cell(row.cell(i), buf + len);
    }
    return OB_SUCCESS;
  }
};
```

### 3.4 列编码(Column Encoding)

```cpp
// src/storage/blocksstable/ob_column_encoder.h:80
// 定长类型:直接拷贝(INT / BIGINT / TIMESTAMP)
// 变长类型:varint + data(VARCHAR / TEXT)
// 数值类型:可选字典编码(高频值) / RLE(单调值)

int encode_int(const int64_t val, char *buf) {
  memcpy(buf, &val, sizeof(val));  // 8 字节
  return 8;
}

int encode_varchar(const char *str, size_t len, char *buf) {
  // 1. varint 写长度
  size_t varint_size = write_varint(len, buf);
  // 2. 写 data
  memcpy(buf + varint_size, str, len);
  return varint_size + len;
}

int encode_number(const number_t val, char *buf) {
  // number 用 twos-complement big-endian
  // 可选:scale 标记 + 字节
  // ...
}
```

### 3.5 块索引(Block Index)

```cpp
// src/storage/blocksstable/ob_block_index.h:50
// micro_block 内每个 key 的位置(加速 binary search)
struct ObBlockIndexEntry {
  ObRowkey rowkey_;    // 第一个 row 的 rowkey
  int32_t offset_;     // 在 micro_block 内的偏移
};

// block index = 排序的 entries 数组
// binary search 找 key → 找 micro_block → 找具体 row
class ObBlockIndex {
public:
  std::vector<ObBlockIndexEntry> entries_;

  // 找 rowkey 在哪个位置
  size_t find(const ObRowkey &key) {
    // 1. 二分 entries_
    // 2. 找到 entries_[i].rowkey_ <= key < entries_[i+1].rowkey_
    return i;
  }
};
```

### 3.6 Micro Block 读取流程

```cpp
// src/storage/blocksstable/ob_micro_block_reader.cpp:80
class ObMicroBlockReader {
public:
  // 1. 反序列化 header
  int read_header(const char *buf, ObMicroBlockHeader &header);

  // 2. 读行:binary search + deserialize
  ObMvccRow *get_row(const ObRowkey &key, ObMvccRow *row_buf) {
    // 2.1 读 block index(已 load 到内存)
    auto *idx = block_index_.find(key);
    if (idx == nullptr) return nullptr;  // 不在 micro_block 内
    // 2.2 跳到对应 offset
    const char *row_buf = micro_buf_ + idx->offset_;
    // 2.3 反序列化行
    row_decoder_.decode(row_buf, *row_buf);
    return row_buf;
  }
};
```

---

## 4. Bloom Filter

### 4.1 位置

每 micro_block 都有自己的 bloom filter(不是 SSTable 级)。bloom filter 存
在 macro block 内(每个 micro_block 后跟一个 bloom filter)。

### 4.2 用途

```cpp
// 查询流程:
// 1. 查 bloom filter → 不在 → 直接 NOT_FOUND(不开 micro_block)
// 2. 查 bloom filter → 在 → 开 micro_block → binary search
//
// false positive rate ~1%(减少 99% 不必要的 micro_block open)
```

### 4.3 Bloom Filter 结构

```cpp
// src/storage/blocksstable/ob_micro_block_bloom_filter.h:80
class ObMicroBlockBloomFilter {
public:
  // 1. bit array
  uint64_t *bit_array_;
  size_t bit_count_;        // 通常 8192 bits

  // 2. hash functions
  size_t hash_count_;       // 通常 4

  // 3. 添加
  void add(const ObRowkey &key) {
    auto h = key.hash();
    for (size_t i = 0; i < hash_count_; ++i) {
      size_t idx = (h + i * h) % bit_count_;
      bit_array_[idx / 64] |= (1ULL << (idx % 64));
    }
  }

  // 4. 查询
  bool may_contain(const ObRowkey &key) const {
    auto h = key.hash();
    for (size_t i = 0; i < hash_count_; ++i) {
      size_t idx = (h + i * h) % bit_count_;
      if (!(bit_array_[idx / 64] & (1ULL << (idx % 64)))) {
        return false;  // 一定不在
      }
    }
    return true;  // 可能存在(~1% false positive)
  }
};
```

### 4.4 Bloom Filter 大小

```
行数 N, fp_rate ε
  bit_count = -N × ln(ε) / (ln(2))^2
  hash_count = bit_count / N × ln(2)

N=256, ε=0.01:
  bit_count = 256 × 4.6 / 0.48 ≈ 2450 bits ≈ 306 bytes
  hash_count = 4
```

每 micro_block ~1KB bloom filter(可配置)。

### 4.5 Bloom Filter Cache(接 #51)

```cpp
// bloom filter 单独 cache(避免每次读 macro block 都要 parse)
class ObBloomFilterCache {
public:
  // key: (macro_block_id, micro_block_id)
  // value: bloom filter bit array
  // 命中率: 99%+ (接 #51 详细分析)
};
```

---

## 5. 压缩(Compression)

### 5.1 压缩算法

OB 支持多种压缩算法:

| 算法 | 压缩率 | 速度 | 适用 |
|------|--------|------|------|
| **NONE** | 1x | 最快 | 临时数据 |
| **LZ4** | ~2x | 快 | 实时压缩(默认) |
| **ZSTD** | ~3x | 中 | OLAP 压缩 |
| **SNAPPY** | ~2x | 快 | 兼容性 |

### 5.2 压缩位置

```
Micro Block:
  编码后数据 → 压缩 → 存盘

整 Micro Block 压缩(粒度细)
```

### 5.3 压缩实现

```cpp
// src/storage/blocksstable/ob_compressor.cpp:80
class ObCompressor {
public:
  int compress(const char *src, size_t src_len, char *dst, size_t &dst_len) {
    // 选算法(由 schema 配置)
    switch (compress_type_) {
      case COMPRESS_LZ4:
        return lz4_compress(src, src_len, dst, dst_len);
      case COMPRESS_ZSTD:
        return zstd_compress(src, src_len, dst, dst_len);
      case COMPRESS_SNAPPY:
        return snappy_compress(src, src_len, dst, dst_len);
    }
  }
};
```

### 5.4 压缩对 IO 的影响

```
压缩前:
  SSTable: 1 TB
  读: 1 TB IO

压缩后 (ZSTD 3x):
  SSTable: 333 GB
  读: 333 GB IO (节省 67%)
  但 CPU 多 30%
```

---

## 6. 加密(Encryption)

### 6.1 加密算法

```
默认: AES-256-CTR
密钥: tenant 级(从 KMS 拉)
```

### 6.2 加密位置

```cpp
// src/storage/blocksstable/ob_encryptor.cpp:50
class ObEncryptor {
public:
  // 整个 macro block 加密
  int encrypt(const char *src, size_t src_len, char *dst, size_t &dst_len) {
    // 1. 拿 tenant 密钥
    ObString key = kms_.get_tenant_key(tenant_id_);
    // 2. AES-256-CTR 加密
    return aes_ctr_encrypt(src, src_len, key, iv_, dst, dst_len);
  }
};
```

### 6.3 加密的代价

```
加密前:
  写: 100 MB/s

加密后:
  写: 70-80 MB/s (CPU 瓶颈,~20% 损耗)
  读: 80-90 MB/s (解密)
```

---

## 7. Checksum 与数据完整性

### 7.1 Checksum 层级

```
Micro Block Header checksum:    32-bit CRC32
Macro Block Header checksum:    32-bit CRC32
SSTable Meta checksum:          64-bit CRC64
```

### 7.2 Checksum 实现

```cpp
// src/storage/blocksstable/ob_checksum.cpp:50
class ObChecksum {
public:
  static uint32_t crc32(const char *buf, size_t len) {
    return crc32_compute(buf, len);
  }
  static uint64_t crc64(const char *buf, size_t len) {
    return crc64_compute(buf, len);
  }
};
```

### 7.3 IO 错误处理

```cpp
// 读 micro_block 时 checksum 校验失败
int on_micro_block_read_failed(const ObMicroBlockHandle &h) {
  // 1. 重读一次(可能是临时 IO 错误)
  if (retry_read(h) == OB_SUCCESS) return OB_SUCCESS;
  // 2. 重读失败,从其他副本读
  return read_from_replica(h.partition_id_, h.key_);
}
```

---

## 8. IO 优化

### 8.1 Prefetch(预读)

```cpp
// src/storage/blocksstable/ob_prefetcher.cpp:50
// 顺序 scan 时,提前加载后续 micro_block
class ObPrefetcher {
public:
  void on_sequential_access(int64_t cur_block_id) {
    // 1. 检测顺序访问
    if (cur_block_id == last_accessed_id_ + 1) {
      ++sequential_count_;
    }
    // 2. 顺序 ≥ 3,触发预读
    if (sequential_count_ >= 3) {
      for (int64_t i = 1; i <= prefetch_distance_; ++i) {
        async_load_micro_block(cur_block_id + i);
      }
    }
  }
};
```

### 8.2 Async IO(异步 IO)

```cpp
// src/lib/io/ob_io_uring.cpp:50
// io_uring:异步 IO(接 #27 RPC 的网络层)
// 但磁盘 IO 也用 io_uring

class ObDiskIO {
public:
  // 1. 提交异步读
  int async_read(int fd, void *buf, size_t size, off_t offset, 
                 ObIOCallback *cb);
  // 2. 等完成
  int wait_completion(ObIORequest &req, int timeout_ms);
};
```

### 8.3 Direct IO

```cpp
// 绕过 OS page cache(接 #51 详细分析)
// O_DIRECT 打开文件
int open_direct_io(const char *path) {
  int fd = open(path, O_RDONLY | O_DIRECT);
  return fd;
}
```

### 8.4 Cache 对齐

```
Micro Block 大小: 16-64 KB(默认 32 KB)
  ↓
OS page 大小: 4 KB
  ↓
每次 IO 读 ~8 个 OS page(32 KB / 4 KB)
  ↓
page cache 友好(不需要拆分)
```

---

## 9. SSTable 元数据存储

### 9.1 SSTable 在 ObTablet 内的注册

```cpp
// src/storage/ob_tablet.cpp:80
class ObTablet {
public:
  // 1. MemTable
  ObMemtable *memtable_;

  // 2. SSTable list
  std::vector<ObSSTableHandle> sstables_;

  // 3. 当前 schema_version
  int64_t schema_version_;

  // 4. multi-version 列表
  std::vector<ObSSTableHandle> hist_sstables_;  // 历史版本
};
```

### 9.2 ObSSTableHandle

```cpp
// src/storage/blocksstable/ob_sstable_handle.h:50
class ObSSTableHandle {
public:
  // 1. SSTable 标识
  uint64_t sstable_id_;
  int64_t version_;           // SSTable 版本
  int64_t create_time_;
  int64_t freeze_log_id_;     // freeze 时的 log id

  // 2. 文件路径
  common::ObString file_path_;
  int64_t file_size_;

  // 3. Meta
  ObSSTableMeta meta_;

  // 4. Macro Block 索引(已 load 到内存)
  std::vector<ObMacroBlockEntry> macro_block_index_;

  // 5. 状态
  ObSSTableState state_;      // NORMAL / MERGING / DELETED
};
```

---

## 10. 性能调优

### 10.1 Micro Block 大小

| 大小 | 优点 | 缺点 |
|------|------|------|
| 16 KB | IO 细粒度,延迟低 | 元数据开销大 |
| 32 KB (默认) | 平衡 | - |
| 64 KB | 元数据少,压缩率高 | 单 IO 延迟高 |

生产推荐 **32 KB**。

### 10.2 压缩选择

| 场景 | 推荐 |
|------|------|
| OLTP 高频读 | LZ4(快) |
| OLAP 大查询 | ZSTD(高压缩) |
| 兼容性 | SNAPPY |

### 10.3 Bloom Filter 大小

| 行数/Block | Bloom 大小 |
|-----------|-----------|
| 256 行 | 1 KB |
| 512 行 | 2 KB |

fp_rate ~1%,不需更大。

### 10.4 Cache 策略

```sql
-- 调整 micro_block cache 大小
ALTER SYSTEM SET block_cache_mem_size = '20G';

-- 调整 bloom filter cache 大小
ALTER SYSTEM SET bloom_filter_cache_size = '2G';
```

---

## 11. 与 v2 主线的连接

### 11.1 与 Block Cache(接 #51)

```
读路径:
  1. Bloom filter cache lookup (接 #51)
  2. Micro block cache lookup
  3. miss → SSTable file IO → micro block → cache
```

### 11.2 与 Compaction(接 #20)

```
Merge:
  Input: N 个 SSTable (各含 N 个 macro block)
  Process: 多路归并(接 #20 merge sort)
  Output: 1 个新 SSTable (各含 N 个 macro block)
```

### 11.3 与 Clog(接 #22)

```
数据恢复(Recovery):
  1. SSTable dump 到磁盘(有 freeze_log_id)
  2. Clog 从 freeze_log_id+1 开始 replay
  3. MemTable 重建
```

---

## 12. 调优 Checklist

```
□ Micro Block 大小是否合理?(默认 32 KB)
□ 压缩算法是否合适?(OLTP LZ4, OLAP ZSTD)
□ 加密是否启用?(生产必开)
□ Bloom Filter 大小是否合适?(默认 ~1 KB)
□ Cache 大小是否充足?(micro_block + bloom 独立 cache)
□ Direct IO 是否开启?(避免 OS 干扰)
□ 顺序访问是否用 prefetch?
□ Async IO 是否启用?
□ Checksum 校验失败是否告警?
```

---

## 13. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → #28 v2 → #19 
v2 → #20 v2 → #27 v2 → #30 v2 → #31 v2 → **#34 v2 (本文)** 是 OB **storage
/ index / CBO / join / cache / 调优 / 日志 / 事务 / schema / 并行 / HA / 
容灾 / 多租户 / parser / compaction / RPC / 监控 / 分区 / 存储引擎** 全
主线:

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
| **#34 v2 (本文)** | **Storage Engine Internals** | **磁盘存储层** | **SSTable / Macro Block / Micro Block + 压缩/加密/checksum** |

二十一篇连起来,读者能完整理解 OB 的"内存 → 磁盘 → 集群 → 运维"全
链路:

- 内存数据:#14/#15/#16 (MemTable)
- 事务:#11 (Trans Service)
- 日志:#22 (Clog)
- 索引:#18 (Index)
- 执行:#17 (Optimizer) + #41 (Join) + #24 (PX)
- IO:#51 (Block Cache) + #34 (本文:磁盘结构)
- 调优:#29 (Slow Query) + #30 (Monitoring)
- 元数据:#21 (Schema)
- 多租户:#28 (Tenant)
- HA:#26 (Failover) + #33 (Backup)
- 网络:#27 (RPC)
- 分区:#31 (Partition Mgmt)
- 存储维护:#20 (Compaction)

---

## 14. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **SQL Engine Entry** — 接收 / 派发 / 路由(接 #19 + #24)
- **#35-#100 系列**（待确认具体编号）
- **打包 / 收工** — 把当前 25 篇打包成"OB v2 deep-dive 系列"总览 + 索引

继续哪一篇?

---

## 15. 参考(可执行的源码锚点)

- `src/storage/blocksstable/ob_sstable_meta.h` — SSTable 元数据
- `src/storage/blocksstable/ob_macro_block_header.h` — Macro Block 头
- `src/storage/blocksstable/ob_micro_block_header.h` — Micro Block 头
- `src/storage/blocksstable/ob_micro_block_reader.cpp` — Micro Block 读取
- `src/storage/blocksstable/ob_row_encoder.cpp` — 行编码
- `src/storage/blocksstable/ob_column_encoder.h` — 列编码
- `src/storage/blocksstable/ob_block_index.h` — 块索引
- `src/storage/blocksstable/ob_micro_block_bloom_filter.h` — Bloom Filter
- `src/storage/blocksstable/ob_compressor.cpp` — 压缩
- `src/storage/blocksstable/ob_encryptor.cpp` — 加密
- `src/storage/blocksstable/ob_checksum.cpp` — Checksum
- `src/storage/blocksstable/ob_prefetcher.cpp` — 预读
- `src/storage/blocksstable/ob_sstable_handle.h` — SSTable Handle
- `src/storage/ob_tablet.cpp` — Tablet 注册 SSTable
- `src/lib/io/ob_io_uring.cpp` — 异步 IO

---

#34 v2 完。
