# #51 v2 — Block Cache (micro_block + bloom_filter + Row Cache 完整架构)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")

> 接续 #14 v2 / #15 v2 / #16 v2 / #18 v2 / #41 v2：前面把"MemTable 怎么排"、
> "BTree 怎么查"、"索引怎么用"、"join 怎么算"都讲了。本文聚焦 **block cache
> 层** ——它是 MemTable flush 到 SSTable 之后的 **hot path 缓存**,决定了"冷数
> 据"的实际 IO 路径。它和 MemTable 一起,构成 OB 的"双层 cache hierarchy"。

---

## 0. 全文导读

OB 的存储 cache hierarchy 是经典三层:

```
Query → MemTable (内存, 最新数据, MVCC 完整)
       → Block Cache (内存, 热 micro_block, 只读快照)
       → SSTable on Disk (持久化, micro_block 顺序存)
```

Block cache 居中,是**最复杂的 cache 层**——它要:
1. 缓存 SSTable 的 micro_block(避免重复 IO)
2. 缓存每个 micro_block 的 bloom_filter(避免打开 block 再判断 miss)
3. 缓存整个行(row cache,某些场景)
4. 支撑优先级 + 准入策略(prefetch、important workload)
5. 和 buffer pool / 文件系统 cache 协作
6. 提供 metrics 给运维调优

本文按"架构 → 数据结构 → 准入策略 → 预读 → 监控调优"展开。

---

## 1. Block Cache 的三层架构

### 1.1 三种 cache 对象

```cpp
// src/storage/blocksstable/ob_block_cache.h:60
class ObBlockCache {
public:
  // 1. micro_block cache(SSTable 数据块,4-64KB)
  ObMicroBlockCache micro_block_cache_;

  // 2. bloom_filter cache(每 micro_block 的 bloom filter,~256B-2KB)
  ObBloomFilterCache bloom_filter_cache_;

  // 3. row cache(整个 row,~1-10KB,可选)
  ObRowCache row_cache_;
};
```

三种 cache 共享同一套 LRU + hash map 框架,但有不同的 key 编码 + 准入策略。

### 1.2 三种 cache 的使用场景

| Cache 类型 | 何时用 | 何时不用 |
|-----------|--------|----------|
| **micro_block_cache** | 全场景;默认开启 | 内存极小时可关 |
| **bloom_filter_cache** | 全场景;默认开启 | 不推荐关(bloom filter cache miss 成本极高) |
| **row_cache** | 热表 / 命中率 > 90% 时 | 大表 / wide row 时关(浪费内存) |

OB 的默认配置:bloom_filter + micro_block 必开,row_cache 可选(由参数控制)。

### 1.3 Cache key 设计

```cpp
// src/storage/blocksstable/ob_block_cache_key.h:40
class ObBlockCacheKey {
public:
  // micro_block 的 cache key
  // [tenant_id: 8B] [table_id: 8B] [partition_id: 8B]
  // [micro_block_index: 8B] [tablet_id: 8B]
  char data_[40];

  // bloom_filter cache key
  // 比 micro_block key 多 1B(标记是 bloom 不是 data)
};
```

cache key 是固定 40 字节(含 hash)，不是变长。变长 key 会引入 malloc 开销
——固定大小可以直接 inline。

---

## 2. LRU 实现与变体

### 2.1 经典 LRU

```cpp
// src/storage/cache/ob_lru_cache.h:80
template <typename Key, typename Value>
class ObLRUCache {
public:
  // 双链表 + hash map
  // 链表头 = 最新访问,链表尾 = 最久未访问
  // hash map 提供 O(1) 查找

  void put(const Key &k, const Value &v) {
    // 1. 已经在 cache?删旧 entry
    if (auto it = map_.find(k); it != map_.end()) {
      list_.erase(it->second.list_node_);
      map_.erase(it);
    }
    // 2. 超过容量?驱逐 list tail
    if (size_ >= capacity_) evict_lru();
    // 3. 插入 list head
    auto node = list_.push_front({k, v});
    map_[k] = {v, node};
    ++size_;
  }

  std::optional<Value> get(const Key &k) {
    if (auto it = map_.find(k); it != map_.end()) {
      // 1. 移到 list head(标记"最近访问")
      list_.move_to_front(it->second.list_node_);
      return it->second.value;
    }
    return std::nullopt;
  }

  void evict_lru() {
    auto node = list_.pop_back();
    map_.erase(node.key);
    --size_;
  }
};
```

LRU 的问题:**cache pollution**。一次全表扫描会冲掉所有热点数据。

### 2.2 2Q(LRU + FIFO)

```cpp
// src/storage/cache/ob_two_queue_cache.h:60
// 解决 LRU 的 pollution 问题
class ObTwoQueueCache {
public:
  // 1. A1in: 新插入的 entry 先在这里(短 FIFO)
  // 2. Am:   访问过的 entry 升级到这里(LRU)
  // 3. A1out: 记录被驱逐的 key(防止二次插入)

  std::optional<Value> get(const Key &k) {
    if (auto v = a1in_.get(k)) {
      // 命中 A1in,升级到 Am
      am_.put(k, *v);
      return v;
    }
    if (auto v = am_.get(k)) {
      return v;
    }
    return std::nullopt;
  }
};
```

2Q 比 LRU 多用 ~10% 内存,但抗 scan 污染。

### 2.3 Clock Sweep(更轻量的 LRU)

```cpp
// src/storage/cache/ob_clock_cache.h:50
class ObClockCache {
public:
  // 每个 entry 有 1 bit "referenced" flag
  // 驱逐时,从"时针"位置开始扫
  // 扫到的 entry if referenced:清 flag,跳过
  //                 else:驱逐

  void evict_one() {
    while (true) {
      auto &entry = entries_[hand_];
      hand_ = (hand_ + 1) % entries_.size();
      if (entry.referenced_) {
        entry.referenced_ = false;
        continue;
      }
      // 没被引用,驱逐
      evict(entry);
      return;
    }
  }
};
```

Clock Sweep 是 LRU 的近似,**O(1) 驱逐**(LRU 是 O(1) 但 list 操作稍重)。
OB 默认用 Clock Sweep。

---

## 3. 准入策略(Admission Policy)

### 3.1 朴素 LRU:全部准入

默认策略:`put()` → 直接进 cache → 满了就驱逐。最简单,但容易污染。

### 3.2 TinyLFU(频率优先)

```cpp
// src/storage/cache/ob_tinylfu_cache.h:50
class ObTinyLFUCache {
public:
  // 1. 用 Count-Min Sketch 记录每个 key 的访问频率
  // 2. 准入时:新 key 的频率 vs 被驱逐 key 的频率
  // 3. 新 key 频率高 → 准入;低 → 拒绝

  bool should_admit(const Key &k) {
    size_t new_freq = cms_.estimate(k);  // 新 key 频率
    size_t old_freq = cms_.estimate(victim_key_);  // 候选驱逐 key 频率
    return new_freq > old_freq;
  }
};
```

TinyLFU 优势:**对 scan 高度抵抗**。一次全表扫过一遍的 key,频率只增 1,容易被拒绝。

### 3.3 Priority(优先级准入)

OB 支持按 workload 优先级准入:

```cpp
// src/storage/cache/ob_priority_cache.h:60
class ObPriorityCache {
public:
  enum Priority { CRITICAL, HIGH, NORMAL, LOW };

  bool should_admit(const Key &k, Priority p) {
    // 1. CRITICAL:总是准入
    // 2. HIGH:90% 准入
    // 3. NORMAL:50% 准入
    // 4. LOW:10% 准入
    double admit_rate = get_admit_rate(p);
    return random() < admit_rate;
  }
};
```

应用:核心业务表的 micro_block 标 CRITICAL,ETL / 报表标 LOW。

---

## 4. Bloom Filter Cache 深入

### 4.1 为什么 bloom filter cache 重要

```cpp
// SSTable 读路径
read_block(table_id, micro_block_id) {
    // 1. 先查 bloom filter cache
    bloom = bloom_cache_.get(key);
    if (!bloom) {
        // cache miss,从磁盘读 bloom(每个 micro_block 头有 bloom)
        bloom = read_bloom_from_disk(micro_block_id);
        bloom_cache_.put(key, bloom);
    }
    // 2. 用 bloom 判定 key 是否在 block 内
    if (!bloom.may_contain(key)) {
        return NOT_FOUND;  // 99% 概率确实不在
    }
    // 3. 命中,加载 micro_block 数据
    block = block_cache_.get(block_key);
    if (!block) {
        block = read_block_from_disk(micro_block_id);
        block_cache_.put(block_key, block);
    }
    // 4. 在 block 内 binary search
    return block.binary_search(key);
}
```

**bloom cache miss 的代价**:打开 micro_block(读头部 bloom)。micro_block
header ~256B-2KB,在 KV-SSD 上一个 IO 就是一次读。bloom cache 命中率
< 99% 就是灾难。

### 4.2 Bloom Filter 的内存布局

```cpp
// src/storage/blocksstable/ob_bloom_filter.h:60
class ObBloomFilter {
public:
  // bit array + hash function 数
  uint64_t *bit_array_;
  size_t bit_count_;     // 通常 ~8K bits
  size_t hash_count_;    // 通常 4-8 个 hash

  // 添加 key
  void add(uint64_t hash) {
    for (size_t i = 0; i < hash_count_; ++i) {
      size_t idx = (hash + i * hash) % bit_count_;
      bit_array_[idx / 64] |= (1ULL << (idx % 64));
    }
  }

  // 查询
  bool may_contain(uint64_t hash) const {
    for (size_t i = 0; i < hash_count_; ++i) {
      size_t idx = (hash + i * hash) % bit_count_;
      if (!(bit_array_[idx / 64] & (1ULL << (idx % 64)))) {
        return false;  // 一定不在
      }
    }
    return true;  // 可能存在(有 1% false positive)
  }
};
```

bloom 的 false positive rate 取决于 `bit_count` 和 `hash_count`:

```
fp_rate ≈ (1 - e^(-hash_count × n / bit_count))^hash_count
```

OB 默认配置:`bit_count = 8192`, `hash_count = 4`,`fp_rate ≈ 1%`。

### 4.3 Bloom Filter 的重新生成

当 SSTable 行数变化时(compact 之后),bloom 必须重建:

```cpp
// src/storage/blocksstable/ob_bloom_filter_builder.cpp:30
class ObBloomFilterBuilder {
public:
  // 1. 全表扫,收集所有 row key
  // 2. 计算 n = 行数
  // 3. 算 bit_count:bit_count = -n × ln(fp_rate) / (ln(2))^2
  // 4. 算 hash_count:hash_count = bit_count / n × ln(2)
  // 5. 写所有 key 进 bloom
  // 6. 序列化到 micro_block 头部
};
```

OB 用每个 micro_block 独立的 bloom filter,不是 SSTable 级 bloom——粒度更
细,误判成本更低。

---

## 5. 预读与异步 IO

### 5.1 Sequential Prefetch

```cpp
// src/storage/blocksstable/ob_prefetcher.h:60
class ObPrefetcher {
public:
  // 检测到顺序 scan 后,提前加载后续 N 个 micro_block
  void on_sequential_access(micro_block_id_t cur) {
    // 1. 检查"是否顺序":cur == last + 1
    if (cur == last_accessed_ + 1) {
      ++sequential_count_;
    } else {
      sequential_count_ = 0;
    }
    last_accessed_ = cur;

    // 2. 触发预读(连续 ≥ 3 个 block)
    if (sequential_count_ >= 3) {
      for (size_t i = 1; i <= prefetch_distance_; ++i) {
        async_load(micro_block_id_t(cur + i));
      }
    }
  }
};
```

### 5.2 Async IO

OB 用 io_uring(Linux) 或 IOCP(Windows) 做异步 IO:

```cpp
// src/storage/ob_async_io_manager.h:80
class ObAsyncIOManager {
public:
  // 1. 提交 IO 请求(不阻塞)
  int submit_read(int fd, void *buf, size_t size, off_t offset,
                  ObIOCallback *cb);

  // 2. 等 IO 完成(回调或 poll)
  int wait_completion(ObIORequest &req, int timeout_ms);
};
```

异步 IO 让 prefetch 不阻塞 query path。

### 5.3 Readahead Window

```cpp
// src/storage/blocksstable/ob_prefetcher.cpp:100
// 动态调整 prefetch distance
size_t ObPrefetcher::adjust_distance(double hit_rate) {
  // 命中率 > 90%:加大 distance(更多预读)
  if (hit_rate > 0.9) return std::min(distance_ * 2, MAX_DISTANCE);
  // 命中率 < 50%:减小 distance(浪费 IO)
  if (hit_rate < 0.5) return std::max(distance_ / 2, MIN_DISTANCE);
  return distance_;
}
```

---

## 6. 与 MemTable 的协作:Read Path

### 6.1 三层 cache hierarchy

```cpp
// src/storage/ob_storage_read.cpp:200
int ObStorageRead::read_row(table_id, key, row) {
  // 1. 先查 MemTable(内存最新数据)
  if (OB_SUCC(memtable_.get(key, row))) {
    // MVCC 可见性判定
    if (is_visible(row.mvcc_row_, read_version_)) {
      return OB_SUCCESS;
    }
  }

  // 2. MemTable miss,查 block cache
  micro_block_id = sstable_.find_block(key);
  block = block_cache_.get(micro_block_id);
  if (!block) {
    // cache miss,读 SSTable
    block = sstable_.read_micro_block(micro_block_id);
    block_cache_.put(micro_block_id, block);
  }

  // 3. bloom filter 判定
  bloom = bloom_cache_.get(micro_block_id);
  if (!bloom) {
    bloom = block->get_bloom();
    bloom_cache_.put(micro_block_id, bloom);
  }
  if (!bloom.may_contain(key)) {
    return OB_ERR_NOT_FOUND;
  }

  // 4. block 内 binary search
  if (OB_FAIL(block->binary_search(key, row))) {
    return OB_ERR_NOT_FOUND;
  }

  // 5. MVCC 可见性判定(同 #1-#5 v2)
  if (!is_visible(row.mvcc_row_, read_version_)) {
    return OB_ERR_NOT_FOUND;
  }

  return OB_SUCCESS;
}
```

### 6.2 关键 insight:MemTable 优先

**任何读路径,MemTable 优先于 block cache**。理由:
- MemTable 含未 flush 的最新数据(包括 uncommitted 行的可见版本)
- block cache 只含已 flush 的快照
- 不查 MemTable 就用 block cache,会读到"过时数据"

---

## 7. 与 Buffer Pool / OS Page Cache 的协作

### 7.1 三层 page cache

```
OS Page Cache (kernel managed)
  ↓
OB Buffer Pool (user-space, ObTenantBufferPool)
  ↓
OB Block Cache (user-space, micro_block cache)
  ↓
Application (query executor)
```

### 7.2 直接 IO(DIO)

OB 默认走 **direct IO**,绕过 OS page cache:

```cpp
// src/storage/ob_direct_io_adapter.cpp:50
// O_DIRECT 打开文件,绕过 OS page cache
int open_direct_io(const char *path) {
  int fd = open(path, O_RDONLY | O_DIRECT);
  return fd;
}
```

**为什么 DIO?** OB 自己管理 block cache,不希望 OS 再 cache 一份——双层
cache 会浪费内存 + 不一致(OS 不知道 OB 在改 SSTable)。

### 7.3 Buffer Pool vs Block Cache

| 特性 | Buffer Pool | Block Cache |
|------|-------------|-------------|
| 管理对象 | OS page(4KB) | micro_block(16-64KB) |
| 命中率粒度 | 4KB | 16-64KB |
| 预读 | 内核 readahead | OB 自己 prefetch |
| 替换策略 | LRU | Clock Sweep + Priority |
| 隔离 | tenant 级 | tenant 级 |
| 适用 | 通用 | OB-specific KV |

OB 的设计:**Buffer Pool 关闭,只保留 Block Cache**。这样所有内存都由 OB 自
己控制,避免 OS 干扰。

> **v2 洞察**:"direct IO + 自管 block cache"是 OB 的核心架构决策。它牺牲
> 了一层 OS 优化(预读、page cache 命中),换来**完全可观测性**——运维看
> OB 自己的 metrics 就够,不用进 kernel。代价是:OB 必须自己实现预读、
> 自己管理优先级、自己做 metrics。这是"可控性 vs 简单性"的 trade-off。

---

## 8. Metrics 与监控

### 8.1 关键指标

```cpp
// src/storage/cache/ob_cache_metrics.h:40
class ObCacheMetrics {
public:
  // 命中率
  uint64_t hit_count_;
  uint64_t miss_count_;
  double hit_rate() const { return double(hit_count_) / (hit_count_ + miss_count_); }

  // 驱逐次数
  uint64_t evict_count_;

  // 内存占用
  uint64_t mem_used_bytes_;

  // 平均 entry 大小
  size_t avg_entry_size_;

  // 锁竞争(高并发下重要)
  uint64_t lock_contention_count_;
};
```

### 8.2 通过 SQL 查询

```sql
SELECT * FROM oceanbase.__all_virtual_block_cache_stat\G
```

可以看到:
- 每种 cache 的命中率
- 内存占用
- 驱逐次数
- 锁竞争

### 8.3 调优决策树

```
cache 命中率 < 70%?
├─ 是:检查
│   ├─ cache 容量是否够?
│   │   └─ 是:加大 cache_size(单 OBServer 上限 ~50GB)
│   ├─ 工作集是否过大?(热数据 > cache 容量)
│   │   └─ 是:分库分表 + cold/hot 分离
│   └─ 是否 scan 太多污染 cache?
│       └─ 是:开 TinyLFU + priority 准入
└─ 否:命中率 OK,继续观察
```

### 8.4 调优参数

```sql
-- 查看 cache 配置
SHOW PARAMETERS LIKE '%cache%';

-- 关键参数
ALTER SYSTEM SET block_cache_mem_size = '20G';  -- micro_block cache 内存
ALTER SYSTEM SET bloom_filter_cache_size = '2G';  -- bloom cache 内存
ALTER SYSTEM SET row_cache_mem_size = '0';  -- 关 row cache
ALTER SYSTEM SET enable_direct_io = ON;  -- 必须开
```

---

## 9. Cache 失效与一致性

### 9.1 Compact 触发失效

SSTable compact 时,旧 micro_block 被替换,cache 必须失效:

```cpp
// src/storage/blocksstable/ob_sstable_compactor.cpp:300
int ObSSTableCompactor::compact_finish(ObTabletHandle &old_tablet) {
  // 1. 旧 micro_block 失效
  for (auto &block : old_tablet.micro_blocks_) {
    block_cache_.invalidate(block.cache_key_);
    bloom_cache_.invalidate(block.cache_key_);
  }
  // 2. 新 micro_block 预热(可选)
  if (enable_prewarm_) {
    for (auto &block : new_tablet.micro_blocks_) {
      async_load_block(block);
    }
  }
}
```

### 9.2 Freeze / Major Freeze

```cpp
// src/storage/ob_major_freeze_service.cpp:100
// major freeze 后,MemTable dump 到 SSTable
// 旧 MemTable 失效,新 SSTable 加入 block cache(冷启动)
```

### 9.3 失效 vs 驱逐的区别

| 失效 | 驱逐 |
|------|------|
| **主动删除**(业务逻辑触发) | **被动删除**(容量满) |
| Compact / DDL / Freeze | LRU 满了 |
| 立即生效 | 异步 |

---

## 10. Cache 与 MVCC 的耦合

### 10.1 micro_block 是"旧版本"快照

block cache 缓存的 micro_block 是 **flush 时的快照**,不含 MVCC 后续版本。
查询时要结合 MemTable(最新) + block cache(快照)看可见性。

```cpp
// src/storage/ob_storage_read.cpp:400
int ObStorageRead::read_row_with_mvcc(table_id, key, row) {
  // 1. MemTable 取最新 MVCC version
  memtable_row = memtable_.get(key);

  // 2. block cache / SSTable 取 flush 时 MVCC version
  sstable_row = sstable_.get(key);

  // 3. 选可见的(按 #1-#5 v2 描述)
  if (memtable_row.commit_version <= read_version_
      && memtable_row.delete_version > read_version_) {
    return memtable_row;  // 用 MemTable
  }
  return sstable_row;  // 用 SSTable
}
```

### 10.2 Compact 后的 MVCC 一致性

Compact 时,旧 SSTable 的 row 被 merge 到新 SSTable,旧的 mvcc_version 也带
过去——**cache 的快照要更新**。

```cpp
// src/storage/blocksstable/ob_compact_block_writer.cpp:80
// compact 输出新 micro_block,每个 row 带 mvcc_version
// 旧 cache entry 必须失效
```

---

## 11. 生产环境的常见 cache 问题

### 11.1 Cache 命中率低

```sql
-- 现象:block_cache hit rate < 70%
SHOW STATUS LIKE 'block_cache_hit_rate';

-- 排查:
-- 1. 是不是 scan 太多?(改 query + 加 index)
-- 2. cache 容量是否够?(调高 block_cache_mem_size)
-- 3. 工作集是否过大?(分库分表)
```

### 11.2 Cache 抖动(经常 evict)

```
现象:evict_count / put_count > 50%
原因:工作集 > cache 容量,cache 不断换页
修法:扩容 cache OR 减小工作集(冷热分离)
```

### 11.3 锁竞争

OB block cache 用 `ObBucketLock`(per-bucket lock),并发高时锁竞争:

```cpp
// 监控
SELECT * FROM oceanbase.__all_virtual_cache_lock_stat\G
```

修法:
- 加大 hash bucket 数(减小单 bucket 冲突)
- 减少并发线程数(PX worker 数)

---

## 12. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2(本文)
是 **storage / index / optimizer / join / cache** 主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObMvccHashIndex | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| **#51 v2 (本文)** | **Block Cache** | **IO 层** | **三层 cache hierarchy + LRU 变体 + bloom filter + DIO** |

七篇连起来,读者能完整理解 OB 的"读路径全链路":

```
SQL 文本
  → #17 (Optimizer 选 plan)
    → #18 (选 index,covering 判断)
      → #14/#15/#16 (MemTable 内 BTree + HashIndex)
        → #51 (本文:MemTable miss → block cache → SSTable IO)
          → #41 (Join 时 cache 物化 + runtime filter cache)
```

---

## 13. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **#29 v2 Slow Query** — slow query 捕获 + 分析 + 索引推荐(接 #17 + #51 调优)
- **#19-#40 系列** — 取决于具体编号
- **#42-#50 系列** — 取决于具体编号
- **#52-#100 系列** — 取决于具体编号

继续哪一篇?

---

## 14. 参考(可执行的源码锚点)

- `src/storage/blocksstable/ob_block_cache.h` — block cache 框架
- `src/storage/blocksstable/ob_micro_block_cache.cpp` — micro_block cache
- `src/storage/blocksstable/ob_bloom_filter_cache.cpp` — bloom filter cache
- `src/storage/blocksstable/ob_row_cache.cpp` — row cache
- `src/storage/blocksstable/ob_bloom_filter.h` — bloom filter 实现
- `src/storage/blocksstable/ob_bloom_filter_builder.cpp` — bloom 重建
- `src/storage/cache/ob_lru_cache.h` — LRU 实现
- `src/storage/cache/ob_two_queue_cache.h` — 2Q 抗 scan
- `src/storage/cache/ob_clock_cache.h` — Clock Sweep
- `src/storage/cache/ob_tinylfu_cache.h` — TinyLFU 频率准入
- `src/storage/cache/ob_priority_cache.h` — 优先级准入
- `src/storage/blocksstable/ob_prefetcher.h` — 预读
- `src/storage/ob_async_io_manager.h` — 异步 IO
- `src/storage/ob_direct_io_adapter.cpp` — direct IO 绕过 OS
- `src/storage/cache/ob_cache_metrics.h` — cache 监控指标
- `src/storage/ob_storage_read.cpp` — 三层 cache hierarchy read path

---

#51 v2 完。
