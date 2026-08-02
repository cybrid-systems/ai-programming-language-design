# #41 v2 — Join Operators (NL / Hash / Merge Join 完整实现)

> 接续 #17 v2 Query Optimizer：上一文讲了 CBO 怎么**估算**三种 join 的 cost 、
> 怎么在三者之间**选择**。本文下沉一层,讲三种 join 的**实现细节**:
> 内存布局、probe/build 时机、spill to disk 路径、runtime filter 接入、
> 并行执行模型。这是 OB 把 CBO 的"决策"变成"真实执行"的全链路。

---

## 0. 全文导读

OB 支持三种核心 join 算法:

| Join | 适用场景 | 内存模型 | 阻塞性 |
|------|----------|----------|--------|
| **NL (Nested Loop)** | 小 outer × 任意 inner / 内表有强 index | 无内存压力 | 全 streaming |
| **Hash (Grace / Hybrid)** | 大 outer × 中等 inner (能装进内存或稍超) | build 端 hash table | build 阶段阻塞,probe streaming |
| **Merge** | 两边都已排序(或 index 顺序扫描) | 几乎无 | 全 streaming,merge 一次 |

每种 join 在 OB 里有独立的 operator 类 + executor + 优化变体(BNL / Batched
NL / Hybrid Hash / Grace Hash / Bloom-filter Hash)。本文按"算法原理 →
数据结构 → executor 实现 → 优化变体 → 并行化 → 成本与权衡"展开。

---

## 1. Nested Loop Join(NL Join)

### 1.1 算法骨架

```
NL_JOIN(outer, inner, join_cond):
    for row_o in outer:
        for row_i in inner:
            if join_cond(row_o, row_i) match:
                emit (row_o, row_i)
```

Naive NL 是 **O(outer × inner)**,inner 上有 index 时退化为
**O(outer × log(inner))**(每行 inner 走 index lookup)。

### 1.2 OB 实现

```cpp
// src/sql/engine/join/ob_nested_loop_join_op.h:60
class ObNLJoinSpec : public ObJoinSpec {
public:
  // NL 的执行参数
  ObExpr *join_cond_;        // ON 条件表达式
  ObExpr *filter_;            // WHERE 条件(join 后)
  // inner 表的访问方式
  ObTableAccessParam inner_access_;
};

class ObNLJoinOp : public ObJoinOp {
public:
  virtual int inner_open() override {
    // 1. open outer(由 child_iter_ 提供)
    open_outer();
    // 2. 准备 inner 访问(inner 是带条件的 lookup)
    open_inner();
    return OB_SUCCESS;
  }

  virtual int inner_get_next_row() override {
    while (OB_SUCC(outer_.get_next_row(outer_row_))) {
      // 2. 用 outer 的 join key 做 inner lookup
      inner_.reset();
      inner_.set_join_keys(outer_row_, join_keys_);
      while (OB_SUCC(inner_.get_next_row(inner_row_))) {
        // 3. 评估 join 条件
        if (eval_join_cond(outer_row_, inner_row_)) {
          // 4. 拼装 output row
          output_row_.concat(outer_row_, inner_row_);
          return OB_SUCCESS;
        }
      }
    }
    return OB_ITER_END;
  }
};
```

### 1.3 内表访问的三种模式

```cpp
// src/sql/engine/join/ob_nested_loop_join_op.cpp:200
int ObNLJoinOp::open_inner() {
  switch (inner_type_) {
    case INNER_TABLE_SCAN:
      // 全表 scan inner(慢,很少用)
      inner_.open_scan(inner_table_id_, inner_filter_);
      break;
    case INNER_INDEX_LOOKUP:
      // 用 join key 做 index lookup(常用)
      inner_.open_index_lookup(inner_index_id_, join_keys_);
      break;
    case INNER_MATERIALIZED:
      // inner 已物化(由子 plan 提供)
      inner_.open_materialized(child_iter_);
      break;
  }
  return OB_SUCCESS;
}
```

**inner_index_lookup** 是 NL 最常见用法——"大表驱动,小表索引 lookup"。

### 1.4 Block Nested Loop(BNL,变体)

Naive NL 每次 inner lookup 都要重置 iterator——开销大。BNL 把 inner 分块
cache,减少 iterator reset:

```cpp
// src/sql/engine/join/ob_block_nl_join_op.cpp:80
class ObBlockNLJoinOp {
public:
  // 1. 把 inner 按 batch_size 分块
  // 2. 每块 cache inner rows
  // 3. outer 每行对 cache 做 lookup(避免 reset iterator)
  virtual int inner_get_next_row() override {
    while (OB_SUCC(load_next_inner_batch())) {
      for (auto &outer_row : outer_batch_) {
        for (auto &inner_row : inner_batch_) {
          if (eval_join_cond(outer_row, inner_row)) {
            emit_output(outer_row, inner_row);
          }
        }
      }
    }
    return OB_ITER_END;
  }
};
```

BNL 在 inner 没有合适 index 时,比 naive NL 快 2-5x。

### 1.5 NL 的使用场景

```sql
-- 场景 1:小驱动 + 内表有 index(最常见)
SELECT * FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.x = 5;
-- 优化器选 NL:t1 用 x 过滤后驱动,t2 用 t1.id 做 PK lookup

-- 场景 2:join 条件不是等值(range join)
SELECT * FROM t1 JOIN t2 ON t1.a BETWEEN t2.low AND t2.high;
-- Hash / Merge 都不行,只能 NL
```

---

## 2. Hash Join

### 2.1 算法骨架

```
HASH_JOIN(outer, inner, join_cond):
    # 1. Build phase(选小的一边)
    if |inner| < |outer|: swap(outer, inner)
    hash_table = {}
    for row_i in inner:
        key = hash(extract_join_key(row_i))
        hash_table[key].append(row_i)

    # 2. Probe phase
    for row_o in outer:
        key = hash(extract_join_key(row_o))
        for row_i in hash_table[key]:
            if join_cond(row_o, row_i) match:
                emit (row_o, row_i)
```

### 2.2 OB 实现:Hybrid Hash Join

```cpp
// src/sql/engine/join/ob_hash_join_op.h:100
class ObHashJoinSpec : public ObJoinSpec {
public:
  ObHashJoinCtx hash_join_ctx_;
  // hash 表的内存预算
  int64_t mem_budget_;
  // 溢写阈值(超过则 spill 到 disk)
  int64_t spill_threshold_;
};

class ObHashJoinOp : public ObJoinOp {
public:
  // 两阶段:build + probe
  enum Phase { BUILD, PROBE, DONE };

  virtual int inner_get_next_row() override {
    if (phase_ == BUILD) {
      // 1. 拉 inner 全部 rows 灌 hash 表
      build_hash_table();
      // 2. 检查是否需要 spill
      if (hash_table_.size() > spill_threshold_) {
        spill_to_disk();
      }
      phase_ = PROBE;
    }
    if (phase_ == PROBE) {
      // 3. 拉 outer rows,probe hash 表
      while (OB_SUCC(outer_.get_next_row(outer_row_))) {
        auto matches = hash_table_.lookup(extract_key(outer_row_));
        for (auto &m : matches) {
          emit_output(outer_row, m);
        }
      }
      phase_ = DONE;
    }
    return OB_ITER_END;
  }
};
```

### 2.3 Hash Table 数据结构

OB 用 **chained hash table**(链地址法):

```cpp
// src/sql/engine/join/ob_hash_table.h:80
template <typename Key, typename Value>
class ObJoinHashTable {
public:
  // bucket 数组,每 bucket 一个链表
  struct Bucket {
    Key key;
    Value *value;        // 指向 row
    Bucket *next;        // 链表指针
  };
  Bucket **buckets_;     // 大小通常是 2 的幂
  size_t bucket_count_;
  size_t size_;          // entry 数

  // 插入
  void insert(const Key &k, Value *v) {
    size_t idx = hash(k) & (bucket_count_ - 1);
    Bucket *b = new Bucket{k, v, buckets_[idx]};
    buckets_[idx] = b;
    ++size_;
  }

  // 查找(返回链表,遍历比对)
  Bucket *lookup(const Key &k) const {
    size_t idx = hash(k) & (bucket_count_ - 1);
    return buckets_[idx];
  }
};
```

每个 hash bucket 链上可能有多个 entry(collision)。Probe 时遍历链表 + 二次
比对 join key 完整内容(hash 冲突兜底)。

### 2.4 Grace Hash Join(超出内存时)

如果 inner 大到装不进 hash 表,经典做法是 **Grace Hash Join**——partition
+ 分批:

```
GRACE_HASH_JOIN(inner, outer):
    # Phase 1:partition
    for row_i in inner:
        p = hash(extract_join_key(row_i)) % N_PARTITIONS
        write row_i to disk_partition[p]

    for row_o in outer:
        p = hash(extract_join_key(row_o)) % N_PARTITIONS
        write row_o to disk_partition[p]

    # Phase 2:逐 partition 做 in-memory hash join
    for p in 0..N_PARTITIONS:
        build hash table from disk_partition_inner[p]
        probe with disk_partition_outer[p]
        emit results
```

OB 的 Hybrid Hash 是 Grace 的优化版——它**先在内存里 build 一部分 hash
表**(partition 0),**剩下的 partition 写到磁盘**,probe 时 partition 0 走
内存,其他 partition 一边读盘一边 build/probe。

```cpp
// src/sql/engine/join/ob_hybrid_hash_join_op.cpp:150
class ObHybridHashJoinOp : public ObHashJoinOp {
public:
  // level 0: 内存 hash 表(partition 0)
  ObJoinHashTable mem_ht_;

  // level > 0: 磁盘 partitions
  ObSEArray<ObDiskPartition, MAX_PARTITIONS> disk_partitions_;

  virtual int build_hash_table() override {
    int64_t partition_id = 0;
    while (OB_SUCC(inner_.get_next_row(row))) {
      Key k = extract_key(row);
      size_t p = hash(k) % MAX_PARTITIONS;
      if (p == 0 && mem_ht_.size() < mem_budget_) {
        // 内存 partition:进 hash 表
        mem_ht_.insert(k, &row);
      } else {
        // 其他 partition:写到磁盘
        disk_partitions_[p].write(row);
      }
    }
    return OB_SUCCESS;
  }

  virtual int probe() override {
    while (OB_SUCC(outer_.get_next_row(row))) {
      Key k = extract_key(row);
      size_t p = hash(k) % MAX_PARTITIONS;
      if (p == 0) {
        // 内存 partition:直接 probe
        emit_matches(mem_ht_.lookup(k), row);
      } else {
        // 磁盘 partition:读盘 + build in-mem hash + probe
        // 或者 streaming merge
        emit_matches_from_disk(p, k, row);
      }
    }
    return OB_SUCCESS;
  }
};
```

代价分析:
- 内存 partition 0:**O(1)** lookup
- 磁盘 partition:**O(disk_io + in_mem_hash_build + probe)**
- 总 IO:outer + inner 各写一遍盘,读一遍盘(~3x IO)

### 2.5 Bloom Filter Hash Join(变体)

在 build 之前对 outer 预 filter——降低 probe 时的 miss:

```
BLOOM_FILTER_HASH_JOIN(outer, inner):
    # Phase 1:扫 inner,把 join key 灌 bloom filter
    bloom_filter = new BloomFilter()
    for row_i in inner:
        bloom_filter.add(hash(extract_key(row_i)))

    # Phase 2:扫 outer,bloom filter 命中才进 hash join
    for row_o in outer:
        if !bloom_filter.may_contain(hash(extract_key(row_o))):
            skip
        else:
            build + probe hash table for row_o
```

Bloom filter 的代价是 **~1% false positive rate**——可以淘汰 99% 不命中
的 outer 行,大幅减少 hash join 工作量。

OB 的 hash join 默认带 bloom filter(在不增加太多内存的前提下)。

---

## 3. Merge Join

### 3.1 算法骨架

```
MERGE_JOIN(outer_sorted, inner_sorted, join_cond):
    i, j = 0, 0
    while i < |outer| and j < |inner|:
        if outer[i].key < inner[j].key:
            i++
        elif outer[i].key > inner[j].key:
            j++
        else:  # outer[i].key == inner[j].key
            # 找出 inner 的所有匹配(j 到 j'都相等)
            j_end = j
            while j_end < |inner| and inner[j_end].key == outer[i].key:
                j_end++
            # 找出 outer 的所有匹配
            i_end = i
            while i_end < |outer| and outer[i_end].key == outer[i].key:
                i_end++
            # 笛卡尔积输出
            for ii in i..i_end:
                for jj in j..j_end:
                    emit (outer[ii], inner[jj])
            i, j = i_end, j_end
```

### 3.2 OB 实现

```cpp
// src/sql/engine/join/ob_merge_join_op.h:60
class ObMergeJoinSpec : public ObJoinSpec {
public:
  // 两边都已按 join key 排序(由子 plan 保证)
  bool left_sorted_;
  bool right_sorted_;
};

class ObMergeJoinOp : public ObJoinOp {
public:
  virtual int inner_get_next_row() override {
    while (!eof_) {
      // 1. 比较当前 left / right keys
      int cmp = compare_keys(left_key_, right_key_);
      if (cmp < 0) {
        // left < right:推进 left
        advance_left();
      } else if (cmp > 0) {
        // left > right:推进 right
        advance_right();
      } else {
        // 相等:笛卡尔积
        return emit_duplicate_block();
      }
    }
    return OB_ITER_END;
  }

  // 处理相等 key 的整块(笛卡尔积)
  int emit_duplicate_block() {
    // 1. 收集所有 left duplicate rows
    ObSEArray<ObRow *> left_block;
    collect_left_block(left_block);
    // 2. 收集所有 right duplicate rows
    ObSEArray<ObRow *> right_block;
    collect_right_block(right_block);
    // 3. 笛卡尔积输出
    for (auto &l : left_block) {
      for (auto &r : right_block) {
        emit_output(*l, *r);
        // 注意:多输出行用 next() 返回
      }
    }
    return OB_SUCCESS;
  }
};
```

### 3.3 Merge Join 的代价分析

```
sort cost: O(N log N)
merge cost: O(N + M)
total: O(N log N + M log M + N + M)
```

如果两边已经排序(比如来自 index scan),sort cost = 0,merge 就是
**O(N + M)**,比 hash join 还快(省内存)。

### 3.4 使用场景

```sql
-- 场景 1:两边都有序(典型:index scan + ORDER BY)
SELECT * FROM t1 JOIN t2 ON t1.id = t2.t1_id
  WHERE t1.created_at > '2026-01-01'
  ORDER BY t1.id;
-- t1 走 created_at index + sort by id,t2 走 PK lookup + sort
-- Merge Join 是最优(已排序)

-- 场景 2:不等值 join(用 sort + merge 实现)
SELECT * FROM t1 JOIN t2 ON t1.a < t2.b;
-- 把两边按 a / b 排序,然后 merge 扫描
```

---

## 4. Join Algorithm 的对比与选择

### 4.1 选择矩阵

| 场景 | 推荐 join | 理由 |
|------|-----------|------|
| inner 有强 index + outer 小 | NL | inner lookup O(log N) |
| 两边都大 + 等值条件 + 内表能装入内存 | Hash | O(N + M),无 sort |
| 两边都大 + 等值条件 + 内表装不下 | Hybrid Hash | Grace partition 兜底 |
| 两边都已排序 | Merge | O(N + M),无 sort,无 hash 表 |
| 不等值条件 | NL / Merge | Hash 不支持 |
| 小表驱动 + 大表 index | NL | 最简单 |

### 4.2 CBO 选择启发式

```cpp
// src/sql/optimizer/ob_opt_join_path.cpp:80
double ObOptJoinPath::select_join_algorithm() {
  double nl_cost = estimate_nl_cost();
  double hash_cost = estimate_hash_cost();
  double merge_cost = estimate_merge_cost();

  // 1. 如果 NL cost 最小,选 NL(最简单)
  if (nl_cost < hash_cost && nl_cost < merge_cost) return NL;

  // 2. 如果 inner.rows > mem_budget * 0.8,优先 Hybrid Hash(可 spill)
  if (inner_rows_ > mem_budget_ * 0.8) return HYBRID_HASH;

  // 3. 如果两边都已排序,选 Merge(最便宜)
  if (left_sorted_ && right_sorted_) return MERGE;

  // 4. 默认 Hash
  return HASH;
}
```

### 4.3 代价模型陷阱

```cpp
// src/sql/optimizer/ob_opt_cost_model.cpp:600
double ObCostModel::estimate_hash_join_cost(ObJoinPath &path) {
  // 1. build cost
  double build_cost = path.inner_rows_ * cpu_per_row_;
  // 2. probe cost
  double probe_cost = path.outer_rows_ * probe_cost_per_row_;
  // 3. 内存成本(超阈值会 spill)
  double mem_cost = path.inner_rows_ / mem_budget_;
  // 4. spill 成本(如果 mem_cost > 1)
  if (mem_cost > 1.0) {
    spill_cost = path.inner_rows_ * disk_io_per_row_;
  }
  return ALPHA * (build_cost + probe_cost + spill_cost)
       + GAMMA * mem_cost;
}
```

> **v2 洞察**:Hash join cost 的关键是**内存阈值判定**。如果 stats 估算
> inner.rows = 10000,实际 10M,CBO 算"装得下"选 hash,实际 spill 到磁盘
> + OOM 崩溃。这是经典的"plan 看着对,跑起来挂"。"optimizer 内存假设"
> vs "executor 实际内存" 的偏差是 hash join 的最大风险源。

---

## 5. 并行化:Join 的分布式执行

### 5.1 两种并行模式

OB 的并行 join 有两种:

| 模式 | 适用 | 实现 |
|------|------|------|
| **Intra-parallel (Px)** | 单机多核 | OB 的 PX 框架(thread pool + parallel scan + parallel hash join) |
| **Inter-partition (DAS)** | 跨 OBServer | DAS(Direct Attach Service)把 join 下推到数据所在节点 |

### 5.2 PX Parallel Hash Join

```cpp
// src/sql/engine/px/ob_px_hash_join_op.h:80
class ObPxHashJoinOp : public ObHashJoinOp {
public:
  // 1. outer 按 join key hash 分片
  // 2. inner 按 join key hash 分片
  // 3. 每个 thread 负责一对分片,build + probe

  virtual int parallel_build() override {
    // 多线程并行 build
    parallel_for_partition(inner_partitions_, [&](auto &part) {
      build_partition(part);
    });
  }

  virtual int parallel_probe() override {
    parallel_for_partition(outer_partitions_, [&](auto &part) {
      probe_partition(part);
    });
  }
};
```

### 5.3 DAS 分布式 Join

```cpp
// src/sql/engine/das/ob_das_join_op.cpp:100
class ObDASJoinOp {
public:
  // 把 join 下推到数据所在的 OBServer(避免数据 shuffle)
  // 1. 解析 join 条件
  // 2. 决定哪个表需要"远程 fetch"
  // 3. 通过 RPC 拿数据,在本地做 join
};
```

DAS 适合 "小表 + 大表"——把小表 broadcast 到所有节点,大表本地 join。

### 5.4 Exchange(数据交换)

并行 join 中,数据需要跨 thread / 跨节点 shuffle:

```cpp
// src/sql/engine/px/ob_px_exchange_op.h:50
class ObPxExchangeOp : public ObOperator {
public:
  // 上游数据按 hash(key) 分发到下游 thread / node
  // 下游是 N 个 ObPxReceiveOp
  int distribute(const ObRow &row) {
    size_t target = hash(extract_key(row)) % n_partitions_;
    send_to_partition(target, row);
  }
};
```

Exchange 是并行 join 的 IO/网络热点——shuffle 的数据量决定网络带宽需求。

---

## 6. Runtime Filter(RF)

### 6.1 动机

Hash join 时,probe 阶段会查所有 outer rows——但很多 outer rows 在 hash table
里根本不存在(join 条件不命中)。如果能**提前知道 outer 的哪些 key 在 hash
table 里**,就可以**跳过**这些 outer rows,减少 probe 工作量。

这就是 runtime filter 的核心思想:build 阶段收集 hash table 的 key 信息,
生成一个 **filter structure**(bloom filter / min-max / value set),probe 阶段
用它过滤 outer。

### 6.2 OB 实现

```cpp
// src/sql/optimizer/ob_runtime_filter.cpp:80
class ObRuntimeFilter {
public:
  // 三种 filter 类型
  enum Type { BLOOM, MIN_MAX, IN_SET };

  // Build 阶段:收集 hash table 的 key 信息
  void build_from_hash_table(ObJoinHashTable &ht) {
    if (type_ == BLOOM) {
      for (auto &k : ht.all_keys()) {
        bloom_filter_.add(hash(k));
      }
    } else if (type_ == MIN_MAX) {
      min_ = min_of(ht.all_keys());
      max_ = max_of(ht.all_keys());
    } else if (type_ == IN_SET) {
      for (auto &k : ht.all_keys()) {
        in_set_.insert(k);
      }
    }
  }

  // Probe 阶段:过滤 outer
  bool may_match(const ObRow &row) const {
    Key k = extract_key(row);
    if (type_ == BLOOM) return bloom_filter_.may_contain(hash(k));
    if (type_ == MIN_MAX) return k >= min_ && k <= max_;
    if (type_ == IN_SET) return in_set_.contains(k);
    return true;
  }
};
```

### 6.3 接入执行路径

```cpp
// src/sql/engine/join/ob_hash_join_op.cpp:300
class ObHashJoinOp {
public:
  virtual int probe() override {
    // 1. 初始化 runtime filter
    runtime_filter_ = build_runtime_filter();
    // 2. probe 时先用 RF 过滤 outer
    while (OB_SUCC(outer_.get_next_row(row))) {
      if (!runtime_filter_.may_match(row)) {
        continue;  // 跳过(几乎肯定不命中)
      }
      // 3. RF 通过,真去 hash table probe
      auto matches = hash_table_.lookup(extract_key(row));
      // ...
    }
  }
};
```

代价:
- RF build:**O(N)**,几乎免费
- RF probe:**O(1) bloom / O(1) min-max / O(1) hash-set**
- RF false positive:~1% bloom, 0% min-max / in-set

收益:probe 阶段减少 **90%+** 的 hash table lookup(当 outer selectivity 低时)。

---

## 7. 物化与缓存

### 7.1 Inner Materialization

有些 join,inner 表被多次访问,每次都重算太贵——把 inner 物化缓存:

```cpp
// src/sql/engine/join/ob_nested_loop_join_op.cpp:400
class ObNLJoinOp {
public:
  // 如果 inner 没有合适 index,可以先把 inner 物化(建临时 hash 表)
  ObJoinHashTable materialized_inner_;

  int open_inner() {
    if (need_materialize_inner_) {
      // 1. 全表扫 inner
      while (OB_SUCC(inner_.get_next_row(row))) {
        // 2. 灌 hash 表
        materialized_inner_.insert(extract_key(row), &row);
      }
      // 3. 后续 outer 每行做 hash probe(退化为 hash join)
      inner_type_ = INNER_HASH_LOOKUP;
    }
  }
};
```

CBO 决策:
- inner 有 index:不物化,直接 lookup
- inner 无 index 且 outer 大:物化(避免 O(N×M))
- inner 无 index 且 outer 小:不物化(naive NL 即可)

### 7.2 Join Reordering(运行时)

某些场景下,CBO 的 join 顺序在执行时是错的——可以**运行时重排**(adapt
join order)。OB 4.x 引入了 **adaptive join**:

```cpp
// src/sql/engine/join/ob_adaptive_join_op.cpp:50
class ObAdaptiveJoinOp {
public:
  // 1. 先按 CBO 的顺序执行,采集中间统计
  // 2. 如果发现某 join 的 selectivity 严重偏离估算,改用更优顺序
  // 3. 切换 join 算法(NL → Hash, etc.)
};
```

Adaptive join 是 4.x 的较新特性,生产环境用得不多——大部分场景 CBO 已经够
准。

---

## 8. Join 的代价与权衡

### 8.1 三种 Join 的代价对比

| 指标 | NL | Hash | Merge |
|------|-----|------|-------|
| 时间复杂度(最优) | O(N × log M) | O(N + M) | O(N + M) |
| 时间复杂度(最差) | O(N × M) | O(N × M) spill | O(N × M) 无序 |
| 内存 | O(1) 或 O(chunk) | O(min(N, M)) 或 O(N+M) spill | O(1) |
| 输出顺序 | 按 outer 顺序 | 无序 | 按 join key 顺序 |
| 不等值支持 | ✅ | ❌ | ✅ |

### 8.2 何时用哪种

- **NL 必选**:inner 有强 index,或不等值条件
- **Hash 必选**:大表 join + 等值 + 无合适 index
- **Merge 必选**:两边已排序,或 join 输出需按 key 顺序
- **Hybrid Hash**:hash 但 inner 装不下
- **BNL**:NL 但 inner 无 index
- **Bloom Hash**:Hash 且 outer selectivity 低

### 8.3 生产环境常见陷阱

```sql
-- 陷阱 1:join 条件是表达式(走不了 index)
SELECT * FROM t1 JOIN t2 ON DATE(t1.created_at) = DATE(t2.event_time);
-- CBO 无法用 index,只能 NL 全表
-- 修:加函数索引或提前计算 date 列

-- 陷阱 2:join 字段类型不一致
SELECT * FROM t1 JOIN t2 ON t1.id = t2.t1_id_string;
-- OB 强类型:报错或隐式转换(后者可能不走 index)

-- 陷阱 3:join 后立刻 SELECT *
SELECT * FROM t1 JOIN t2 ON t1.id = t2.t1_id;
-- 即使 join 走 index,回表 * 把所有列读出来,IO 暴涨
-- 修:只 SELECT 需要的列 + covering index
```

---

## 9. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2(本文)是
**storage / index / optimizer / join** 主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObMvccHashIndex | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| **#41 v2 (本文)** | **Join Operators** | **执行层** | **NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS 并行** |

六篇连起来,读者能完整理解 OB 的"从 SQL 到执行结果":

- 计划阶段:#17 (CBO 选 join 算法 + cost) → #18 (CBO 选 index)
- 准备阶段:#41 (build hash table / sort / lookup 准备)
- 执行阶段:#41 (probe / merge / nl loop)
- 数据层:#14/#15/#16 (实际 row 存储)
- 索引选择:#18 (covering index 跳过回表)
- 并行执行:#41 (PX 多线程 + DAS 分布式)

---

## 10. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **#51 v2 Block Cache** — micro_block + bloom_filter cache 深入(接 #15/#16/#18)
- **#29 v2 Slow Query** — slow query 捕获 + 分析 + 索引推荐(接 #17 CBO 调优)
- **#19-#40 系列** — 取决于具体编号
- **#42-#50 系列** — 取决于具体编号

继续哪一篇?

---

## 11. 参考(可执行的源码锚点)

- `src/sql/engine/join/ob_nested_loop_join_op.h` — NL join operator
- `src/sql/engine/join/ob_block_nl_join_op.cpp` — Block NL 变体
- `src/sql/engine/join/ob_hash_join_op.h` — Hash join operator
- `src/sql/engine/join/ob_hybrid_hash_join_op.cpp` — Hybrid Grace Hash
- `src/sql/engine/join/ob_merge_join_op.h` — Merge join operator
- `src/sql/engine/join/ob_hash_table.h` — 链地址法 hash table
- `src/sql/optimizer/ob_opt_join_path.cpp` — join 算法选择
- `src/sql/optimizer/ob_opt_cost_model.cpp` — join cost 公式
- `src/sql/optimizer/ob_runtime_filter.cpp` — runtime filter
- `src/sql/engine/px/ob_px_hash_join_op.h` — PX parallel hash join
- `src/sql/engine/das/ob_das_join_op.cpp` — DAS 分布式 join
- `src/sql/engine/px/ob_px_exchange_op.h` — 并行 exchange

---

#41 v2 完。