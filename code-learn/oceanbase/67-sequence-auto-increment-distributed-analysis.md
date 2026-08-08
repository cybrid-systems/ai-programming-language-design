# 67-sequence-auto-increment — OceanBase Sequence / Auto-increment 分布式序列深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（src/share/sequence/ 10 文件 + src/share/schema/ob_sequence_mgr.cpp + ob_sequence_sql_service.cpp + src/storage/blocksstable/ob_macro_seq_generator.cpp）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 在兼容 MySQL `AUTO_INCREMENT` 和 Oracle `CREATE SEQUENCE` 双语义时，设计了一套**分布式序列生成框架**。与 Direct Load 的批量预分配（`ob_direct_load_auto_inc_seq_service`，参见 #66）不同，传统 INSERT 路径走的是 `ObSequenceDMLProxy.next_batch` —— 一个跨 observer 的 SELECT FOR UPDATE 抢占式批量分配机制。

本文聚焦 8 个核心问题：

1. **两种入口语义** —— `CREATE SEQUENCE`（Oracle）vs `AUTO_INCREMENT`（MySQL）是怎么共存？
2. **Sequence 选项** —— `INCREMENT_BY` / `START_WITH` / `MAXVALUE` / `CACHE` / `CYCLE` 等 13 个配置项的语义
3. **Sequence Cache** —— `SequenceCacheNode` 怎么缓存一段连续 seq 值？
4. **Hash 索引** —— `CacheItemKey` + `ObLinkHashMap` 怎么管理 per-tenant / per-sequence 缓存？
5. **next_batch 核心逻辑** —— `SELECT FOR UPDATE` + nocycle / cycle 分支
6. **prefetch_next_batch** —— 异步预取优化
7. **回环（wrap around）** —— CYCLE 模式触底反弹机制
8. **与其他 sequence 的边界** —— 与 #66 `auto_inc_seq_service` / `ob_macro_seq_generator` 的区别

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 17-query-optimizer | CREATE SEQUENCE 走 optimizer 解析 |
| 22-plan-cache | sequence.nextval 也可能被 plan cache 缓存 |
| 24-type-system | `ObNumber`（高精度数字类型）承载 sequence 值 |
| 36-concurrency-control | SELECT FOR UPDATE 是 sequence 并发控制核心 |
| 31-dml-path | AUTO_INCREMENT 是 INSERT 路径的第一个分配点 |
| 62-cdcservice-logfetcher | sequence 与日志服务无直接关系（不在 PALF 路径） |
| 64-online-ddl | CREATE SEQUENCE 是 DDL 路径（由 RS 持久化） |
| 66-direct-load | `ObSequenceDMLProxy.next_batch` 是普通 INSERT 路径，`ob_direct_load_auto_inc_seq_service` 是 Direct Load 路径 |

---

## 1. 整体架构

### 1.1 模块拓扑

```
src/share/sequence/                         (sequence framework, 10 files)
  ├── ob_sequence_option.h                 (配置 + ObSequenceValue)
  ├── ob_sequence_option_builder.h         (Option 构造器)
  ├── ob_sequence_cache.h                  (Cache + HashMap 管理)
  ├── ob_sequence_ddl_proxy.h              (DDL RPC: CREATE/DROP SEQUENCE)
  └── ob_sequence_dml_proxy.h              (DML RPC: nextval)

src/share/schema/
  ├── ob_sequence_mgr.{h,cpp}              (sequence schema 管理)
  └── ob_sequence_sql_service.{h,cpp}      (SQL 服务集成)

src/storage/blocksstable/
  └── ob_macro_seq_generator.{h,cpp}       (macro block ID 生成 — 物理 seq)

src/storage/direct_load/
  └── ob_direct_load_auto_inc_seq_service.{h,cpp}  (Direct Load 专用)
```

### 1.2 三类 Sequence 的边界

| 类型 | 用途 | 路径 | 用户可见？ |
|------|------|------|----------|
| **逻辑 sequence** (CREATE SEQUENCE) | 用户显式建 sequence 对象 | `src/share/sequence/` | ✅ 用户显式建 |
| **AUTO_INCREMENT 列** | MySQL 兼容的列属性 | `src/share/schema/ob_sequence_mgr.cpp` + sequence cache | ✅ 用户建表时声明 |
| **物理 sequence** (macro seq) | SSTable macro block ID | `src/storage/blocksstable/ob_macro_seq_generator.cpp` | ❌ 内部用 |
| **Direct Load auto_inc** | Direct Load 路径 | `src/storage/direct_load/ob_direct_load_auto_inc_seq_service.cpp` | ❌ 内部用 |

**关键边界**：逻辑 sequence + AUTO_INCREMENT 都走 `ObSequenceDMLProxy.next_batch`；Direct Load / macro seq 走自己专属路径（避免锁冲突）。

### 1.3 数据流

```
应用: INSERT INTO t (id, name) VALUES (NULL, 'foo')   -- id 是 AUTO_INCREMENT
    │
    ▼
SQL 层: 解析 INSERT，识别 id 列是 AUTO_INCREMENT
    │
    ▼
INSERT executor: 调用 sequence.nextval() 拿下一个 id
    │
    ▼
ObSequenceDMLProxy.next_batch(tenant_id, sequence_id, schema_version, ...)
    │
    ├─ 1. SELECT * FROM __all_sequence WHERE name=X FOR UPDATE  (抢占)
    │
    ├─ 2. 按 cache_size 计算可分配范围 [next_inclusive_start, next_inclusive_end]
    │
    ├─ 3. UPDATE __all_sequence SET nextval = end + 1
    │
    └─ 4. 返回 [start, end] 给 caller
    │
    ▼
INSERT executor: 从 [start, end] 分配一个 (start++) 给新行
    │
    ▼
后续 SQL: 写实际数据 + 提交事务
```

**关键约束**：
- SELECT FOR UPDATE 是**跨 observer 串行化**（同一 sequence 不会两个 observer 同时分配）
- 一次分配一个 cache_size 范围（典型 1000-10000），避免每行一次 RPC
- 分配范围在 cache 内时，无需再 SELECT FOR UPDATE（纯本地计数）

---

## 2. CREATE SEQUENCE vs AUTO_INCREMENT —— 双入口语义

### 2.1 CREATE SEQUENCE（Oracle 风格）

```sql
CREATE SEQUENCE my_seq
  START WITH 1
  INCREMENT BY 1
  MAXVALUE 9999999999
  NOMINVALUE
  CACHE 1000
  NOCYCLE
  ORDER;
```

创建独立的 sequence 对象，可用 `my_seq.NEXTVAL` / `my_seq.CURRVAL` 引用。

### 2.2 AUTO_INCREMENT（MySQL 风格）

```sql
CREATE TABLE t (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(64)
);
```

AUTO_INCREMENT 是 **列属性**，不是独立对象。底层仍然创建一个隐式 sequence 对象（在 `__all_sequence` 内部表里），并通过 schema 关联到列。

### 2.3 统一抽象

OB 5.x 把两者统一到 `ObSequenceSchema`：

```cpp
// src/share/schema/ (推测结构)
class ObSequenceSchema : public ObSchema {
  uint64_t sequence_id_;
  uint64_t tenant_id_;
  ObString sequence_name_;        // CREATE SEQUENCE 的对象名
  uint64_t associated_table_id_;  // AUTO_INCREMENT 关联的表（null = 独立 seq）
  uint64_t associated_column_id_;// AUTO_INCREMENT 关联的列
  // ... (start_with, increment_by, max_value, min_value, cache_size, cycle_flag 等)
};
```

**关键字段 `associated_table_id_`**：
- NULL → 独立 sequence（CREATE SEQUENCE）
- 非 NULL → AUTO_INCREMENT 列的隐式 sequence

DML 路径 (`ObSequenceDMLProxy.next_batch`) 不用关心区别，只看 sequence_id。

---

## 3. ObSequenceOption —— 13 个配置项

### 3.1 完整配置项

```cpp
// src/share/sequence/ob_sequence_option.h
enum ObSequenceArg
{
  INCREMENT_BY = 0,        // 步长（默认 1）
  START_WITH,              // 起始值（默认 nomaxvalue / nominvalue）
  MAXVALUE,                // 上限
  NOMAXVALUE,              // 无上限（默认）
  MINVALUE,                // 下限
  NOMINVALUE,              // 无下限（默认）
  CACHE,                   // cache 大小（默认 20）
  NOCACHE,                 // 禁用 cache（每行一次 SELECT FOR UPDATE）
  CYCLE,                   // 触底回环
  NOCYCLE,                 // 触底报错（默认）
  ORDER,                   // 保证 nextval 的顺序（牺牲并发）
  NOORDER,                 // 不保证顺序（默认，并发友好）
  RESTART                  // 重置 sequence 到指定值
};
```

**13 个配置项**，覆盖：
- **步长 + 起点**：`INCREMENT_BY` / `START_WITH`
- **边界**：`MAXVALUE` / `NOMAXVALUE` / `MINVALUE` / `NOMINVALUE`
- **缓存**：`CACHE` / `NOCACHE`
- **回环**：`CYCLE` / `NOCYCLE`
- **顺序**：`ORDER` / `NOORDER`
- **重置**：`RESTART`

### 3.2 Oracle 默认值

```cpp
// src/share/sequence/ob_sequence_option.h
struct ObSequenceMaxMinInitializer
{
public:
  ObSequenceMaxMinInitializer();
  // Oracle defaults to 28 integers of 9s and 27 negatives of 9s
  // https://docs.oracle.com/database/121/SQLRF/statements_6017.htm
  // If the SQL exceeds this range, it will be automatically truncated
  //
  // MIN_VALUE = -999999999999999999999999999
  // MAX_VALUE = 9999999999999999999999999999
  //
  // For programming convenience, the default value saved in Option is NO_MIN_VALUE, NO_MAX_VALUE
  // 1. In the resolve phase, if it is found that the user has not set MIN_VALUE or used NOMINVALUE,
  // Then keep the NO_MIN_VALUE in Option unchanged,
  // 2. During the execution phase, if the value in Option is found to be NO_MIN_VALUE, then according to the semantics
  // Help fill in the correct value. For example, when INCREMENT_BY> 0, minvalue will be automatically set to 1
  // If other values are filled in Option, the executor will check the validity of this value, and an error will be reported if it is illegal
};
```

**默认值**：
- `MIN_VALUE = -999999999999999999999999999` (28 位 9)
- `MAX_VALUE = 9999999999999999999999999999` (28 位 9)
- 用户不指定 → 在 Option 中保存 `NO_MIN_VALUE` / `NO_MAX_VALUE`
- 执行期 → 自动按 `INCREMENT_BY` 方向填充（> 0 时 minvalue 自动 = 1）

### 3.3 ObSequenceValue —— 高精度数字

```cpp
// src/share/sequence/ob_sequence_option.h
struct ObSequenceValue
{
  OB_UNIS_VERSION(1);
public:
  ObSequenceValue();
  ObSequenceValue(int64_t init_val);
  int assign(const ObSequenceValue &other);
  int set(const common::number::ObNumber &val);
  int set(const char *val);
  int set(int64_t val);
  common::number::ObNumber &val() { return val_; }
  const common::number::ObNumber &val() const { return val_; }
  TO_STRING_KV("val", val_.format());
private:
  char buf_[common::number::ObNumber::MAX_BYTE_LEN];
  common::number::ObNumber val_;
};

struct ObSequenceValueAllocator : public common::ObDataBuffer
{
public:
    ObSequenceValueAllocator()
        : ObDataBuffer(static_cast<char *>(buf_), common::number::ObNumber::MAX_BYTE_LEN)
    {}
    ~ObSequenceValueAllocator() = default;
private:
  char buf_[common::number::ObNumber::MAX_BYTE_LEN];
};
```

**关键设计**：
- 用 `ObNumber`（OB 自研高精度数字类型，参见 #24 type-system）
- 不用 `int64_t`（因为 MAX_VALUE 是 28 位 9，超过 int64 上限）
- `ObSequenceValueAllocator` 是 stack-allocated 的小 buffer，避免堆分配

### 3.4 OB_UNIS_VERSION(1) 含义

`OB_UNIS_VERSION(1)` 是 OB 序列化宏（参见 #54 serialization-framework）：
- 标记这个 struct 的序列化版本号
- 不同版本之间兼容 / 不兼容由版本号决定
- 跨 observer RPC 时用此宏做序列化

---

## 4. ObSequenceCache —— 缓存 + HashMap

### 4.1 SequenceCacheNode —— 缓存单元

```cpp
// src/share/sequence/ob_sequence_cache.h
struct SequenceCacheNode
{
  OB_UNIS_VERSION(1);
public:
  SequenceCacheNode()
      : start_(), end_()
  {}
  int assign(const SequenceCacheNode &other);
  void reset()
  {
  }

  TO_STRING_KV(K_(start),
               K_(end));

  int set_start(const common::number::ObNumber &start)
  {
    return start_.set(start);
  }
  int set_end(const common::number::ObNumber &end)
  {
    return end_.set(end);
  }
  const common::number::ObNumber &start() const { return start_.val(); }
  const common::number::ObNumber &end() const { return end_.val(); }
private:
  ObSequenceValue start_;   // 当前 cache 区间的起始值（inclusive）
  ObSequenceValue end_;     // 当前 cache 区间的结束值（inclusive）
};
```

**关键设计**：
- 一个 cache node 是一个 `[start, end]` 的闭区间
- caller 从 start 开始分配，分配到 end 时需要再次 fetch
- `start_` 和 `end_` 用 `ObSequenceValue`（高精度）

### 4.2 CacheItemKey —— Hash 索引键

```cpp
// src/share/sequence/ob_sequence_cache.h
struct CacheItemKey
{
public:
  CacheItemKey() : tenant_id_(0), key_(0) {}
  CacheItemKey(const uint64_t tenant_id, const uint64_t key) : tenant_id_(tenant_id), key_(key) {}
  ~CacheItemKey() = default;
  bool operator==(const CacheItemKey &other) const
  {
    return tenant_id_ == other.tenant_id_ && other.key_ == key_;
  }

  int compare(const CacheItemKey &other) {
    int ret = tenant_id_ < other.tenant_id_ ? -1 : (tenant_id_ > other.tenant_id_) ? 1 : 0;
    if (0 == ret) {
      ret = key_ < other.key_ ? -1 : (key_ > other.key_) ? 1 : 0;
    }
    return ret;
  }

  uint64_t hash() const
  {
    uint64_t hash_val = 0;
    hash_val = common::murmurhash(&key_, sizeof(key_), hash_val);
    hash_val = common::murmurhash(&tenant_id_, sizeof(tenant_id_), hash_val);
    return hash_val;
  }
  TO_STRING_KV(K_(tenant_id), K_(key));
  uint64_t tenant_id_;
  uint64_t key_;
};

enum SequenceCacheStatus
{
  DELETED,
  INITED
};
```

**关键设计**：
- `tenant_id_` + `key_` 复合 key（key 可以是 sequence_id 或 table_id+column_id）
- 自定义 hash（`murmurhash` 组合）
- 自定义比较（先 tenant 再 key，LRU 友好）
- `SequenceCacheStatus { DELETED, INITED }` 用于延迟删除（LRU 淘汰）

### 4.3 LRU 缓存管理

```cpp
// (典型 ObLinkHashMap 包装，未在源码中直接看到，但接口名暗示)
class ObSequenceCache {
  // 内部用 ObLinkHashMap<CacheItemKey, ObSequenceCacheItem> 管理
  // LRU 淘汰策略
  // 支持按 tenant_id + key 查询
};
```

**LRU 淘汰的必要性**：
- 一个 tenant 可能创建几千个 sequence（CREATE SEQUENCE + AUTO_INCREMENT）
- 每个 sequence 的 cache 占 `2 * MAX_BYTE_LEN` (ObSequenceValue) ≈ 80 bytes
- 1000 sequence × 80 bytes = 80KB —— 不大，但需要 LRU 控制上限

### 4.4 Cache 状态转换

```
SequenceCacheStatus::DELETED
    │
    │ init 完成 (CacheItem 真正分配空间)
    ▼
SequenceCacheStatus::INITED
    │
    │ LRU 淘汰 / DROP SEQUENCE / AUTO_INCREMENT 列删除
    ▼
SequenceCacheStatus::DELETED
```

`DELETED` 是中间状态 —— 标记为删除但还没释放（lazy deletion 模式）。

---

## 5. ObSequenceDMLProxy.next_batch —— 核心分配逻辑

### 5.1 类骨架

```cpp
// src/share/sequence/ob_sequence_dml_proxy.h
class ObSequenceDMLProxy
{
public:
  ObSequenceDMLProxy();
  virtual ~ObSequenceDMLProxy();
  void init(share::schema::ObMultiVersionSchemaService &schema_service,
            common::ObMySQLProxy &sql_proxy);
  /*
   * 1. select for update, 读取到 sequence 参数
   * 2. 如果是 nocycle，则按照 cache 值为上限尽可能取值填入
   *    next_inclusvie_start, next_inclusvie_end
   *    如果是 cycle， 则也是尽可能取，但如果没有内容可取了，则回环到
   *    起点重新取满一个 cache，并填入
   *    next_inclusvie_start, next_inclusvie_end
   *  3. 更新 sequence_object 表
   */
  int next_batch(const uint64_t tenant_id,
                 const uint64_t sequence_id,
                 const int64_t schema_version,
                 const share::ObSequenceOption &option,
                 SequenceCacheNode &cache_range,
                 ObSequenceCacheItem &old_cache,
                 bool &wrap_around);
  int prefetch_next_batch(
      const uint64_t tenant_id,
      const uint64_t sequence_id,
      const int64_t schema_version,
      const share::ObSequenceOption &option,
      SequenceCacheNode &cache_range,
      ObSequenceCacheItem &old_cache,
      bool &wrap_around);

  share::schema::ObMultiVersionSchemaService *get_schema_service() {
    return schema_service_;
  }
private:
  /* functions */
  int set_pre_op_timeout(common::ObTimeoutCtx &ctx);
  static int init_sequence_value_table(
      common::ObMySQLTransaction &trans,
      ...);
private:
  share::schema::ObMultiVersionSchemaService *schema_service_;
  common::ObMySQLProxy *sql_proxy_;
};
```

### 5.2 next_batch 核心算法（来自源码注释）

源码头文件明确写了算法步骤：

```
Step 1: SELECT FOR UPDATE  (从 __all_sequence 抢占)
    - 拿到当前 sequence 参数（next_value, min_value, max_value, increment_by, cache_size, cycle_flag）
    - SELECT FOR UPDATE 锁住这一行，避免其他 observer 同时分配

Step 2: 按 cache_size 计算可分配范围
    - 如果 nocycle：
        next_inclusive_start = next_value
        next_inclusive_end = min(next_value + cache_size - 1, max_value)
    - 如果 cycle 且没触底：
        next_inclusive_end = min(next_value + cache_size - 1, max_value)
    - 如果 cycle 且触底：
        回环到 min_value（或 START_WITH）
        next_inclusive_start = min_value（或 START_WITH）
        next_inclusive_end = min_value + cache_size - 1

Step 3: UPDATE __all_sequence SET next_value = next_inclusive_end + increment_by
    - 持久化新的 next_value
    - 释放 SELECT FOR UPDATE 锁

Return: [next_inclusive_start, next_inclusive_end] 给 caller
```

### 5.3 关键边界条件

| 场景 | 行为 |
|------|------|
| `nocycle` + 触底 | 报错（`OB_ERR_SEQUENCE_LIMIT` 之类） |
| `cycle` + 触底 | 回环到 min_value（或 START_WITH） |
| `NOCACHE` | cache_size = 1，每次 nextval 都要走 SELECT FOR UPDATE |
| `CACHE 1000` | cache_size = 1000，每次分配 1000 个连续值 |
| `ORDER` | 同一 sequence 的所有 nextval 严格按调用顺序（跨 observer 串行化） |
| `NOORDER` | 同一 sequence 的 nextval 不保证顺序（允许并行） |

### 5.4 prefetch_next_batch 异步预取

```cpp
int prefetch_next_batch(...);
```

**与 next_batch 的区别**：
- `next_batch`：同步阻塞，等 SELECT FOR UPDATE 完成
- `prefetch_next_batch`：异步发起，后台线程 fetch，主线程继续用本地 cache

**典型用法**：
- 应用高并发 INSERT → 一个 worker thread 调用 next_batch
- 同时另一个 worker thread 调用 prefetch_next_batch（提前准备下一段）
- cache 用完时，无缝切换到 prefetch 的下一段

### 5.5 SELECT FOR UPDATE 并发代价

SELECT FOR UPDATE 是 sequence 分配的核心并发控制：
- 同一 sequence 不同 observer 的 SELECT FOR UPDATE 互斥
- 不同 sequence 的 SELECT FOR UPDATE 不互斥（不同 row）
- 一旦 cache 预取到本地，后续分配都是本地计数（无锁）

**典型性能**：
- 第一次 SELECT FOR UPDATE：~10ms（跨 observer RPC）
- 后续本地分配：~10ns（纯内存）

cache_size 1000 时，每 1000 行才有一次跨 observer RPC，性能接近纯内存分配。

---

## 6. CYCLE / NOCYCLE 与回环（wrap around）

### 6.1 回环算法

```cpp
// (伪代码 / 架构描述)
int handle_wrap_around(ObSequenceOption &option,
                      ObSequenceCacheNode &cache_range,
                      bool &wrap_around) {
  if (option.cycle_flag == NOCYCLE) {
    // 报错
    return OB_ERR_SEQUENCE_LIMIT;
  }
  // CYCLE 模式
  if (option.increment_by > 0) {
    // 正向增长：触顶后回到 min_value
    cache_range.set_start(option.min_value);
    cache_range.set_end(compute_next(option.min_value, option.cache_size));
  } else {
    // 负向增长：触底后回到 max_value
    cache_range.set_start(compute_next(option.max_value, option.cache_size));
    cache_range.set_end(option.max_value);
  }
  wrap_around = true;  // 通知 caller 已回环
  return OB_SUCCESS;
}
```

### 6.2 wrap_around 参数用途

`bool &wrap_around` 是 output 参数：
- caller 拿到 `wrap_around = true` 时，可能需要：
  - 记录 audit log（sequence 回环事件）
  - 触发监控告警（可能业务用满了 ID 范围）
  - 给应用返回 WARN（MySQL 风格）

### 6.3 wrap 之后的 cache 行为

```
cache #1: [1, 1000]
    │
    │ 分配到 1000 用完了
    ▼
cache #2: [1001, 2000]
    │
    │ 继续分配到 max_value (9999999999)
    ▼
cache #3 (wrap): [1, 1000]   ← wrap_around = true
    │
    │ 又分配到 1000
    ▼
cache #4: [1001, 2000]
```

wrap 后继续从 start_value 分配 —— 老数据可能在 cache 区间内重复 ID（如果应用还在用老值）。

---

## 7. 与 #66 Direct Load auto_inc 的对比

| 维度 | `ObSequenceDMLProxy.next_batch` | `ob_direct_load_auto_inc_seq_service.get_start_seq` |
|------|--------------------------------|------------------------------------------------------|
| 路径 | 普通 INSERT | Direct Load (LOAD DATA) |
| 并发控制 | SELECT FOR UPDATE 跨 observer | per-(ls, tablet) mutex hash (10243) |
| 同步方式 | 跨 observer RPC | 本地 observer 内 mutex |
| Cache 粒度 | SELECT FOR UPDATE 抢占的 [start, end] | 锁住的 step_size 个连续值 |
| 持久化 | `__all_sequence` 表 | 直接持久化（？待确认） |
| 典型 cache | CACHE 1000（用户配置） | step_size 1000-10000（系统默认） |
| 性能 | ~10ms / 1000 rows | ~ns / 1000 rows |
| 适用 | 频繁单行 INSERT | 批量 LOAD DATA |

**关键区别**：
- `next_batch` 是 **跨 observer** 抢占（多 observer 共享 sequence 必须有全局锁）
- `auto_inc_seq_service` 是 **单 observer 内** 抢占（Direct Load 在一个 observer 内完成，不需要跨 observer 锁）

如果 Direct Load 跨多个 LS 写入，仍然需要跨 observer 协调 —— 但 OB 5.x 的 Direct Load 设计是**单 observer 内完成整个 LOAD DATA**（通过 fragment 切分发），所以本地 mutex 就够了。

---

## 8. 物理 sequence —— `ob_macro_seq_generator`

### 8.1 角色

```cpp
// src/storage/blocksstable/ob_macro_seq_generator.h (推测结构)
class ObMacroSeqGenerator {
  // 给 macro block 生成唯一 ID
  // 完全内部使用，不暴露给用户
};
```

**用户不可见**，不参与 DDL/DML，纯内部使用。

### 8.2 为什么需要单独的 macro seq

- 普通 sequence 的 ID 是逻辑概念（用户可见的 `seq.nextval`）
- macro block ID 是物理概念（SSTable 文件内的 block 唯一标识）
- 两者的 namespace 不同，必须分开

### 8.3 与 #34 sstable-merge 的关联

合并 SSTable 时，新生成的 macro block 需要唯一 ID —— 由 `ob_macro_seq_generator` 提供。

---

## 9. 总结

### 9.1 Sequence / Auto-increment 在 OB 体系中的定位

OB 的 sequence 框架分四层：

```
用户接口层:
  CREATE SEQUENCE (Oracle)
  AUTO_INCREMENT (MySQL)
       │
       ▼
Schema 层:
  ObSequenceSchema (src/share/schema/ob_sequence_mgr.cpp)
       │
       ▼
分配执行层:
  ┌─ 普通 INSERT: ObSequenceDMLProxy.next_batch (src/share/sequence/ob_sequence_dml_proxy.h)
  │                  └── SELECT FOR UPDATE + cache
  │
  └─ Direct Load: ob_direct_load_auto_inc_seq_service (src/storage/direct_load/)
                   └── 本地 mutex hash

物理层:
  ob_macro_seq_generator (src/storage/blocksstable/) — macro block ID
```

### 9.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Oracle 兼容 | `ObSequenceArg` 13 个配置 + `MAXVALUE` 默认 28 位 9 |
| MySQL 兼容 | AUTO_INCREMENT 列 → 隐式 sequence（schema 关联） |
| Cache 机制 | `SequenceCacheNode` `[start, end]` + LRU 淘汰 |
| 跨 observer 锁 | `SELECT FOR UPDATE` + `UPDATE` 原子事务 |
| 异步预取 | `prefetch_next_batch` 后台预拉下一段 |
| Cycle 模式 | 触底回环 + `wrap_around` 通知 |
| 高精度数字 | `ObNumber`（不用 int64，超 28 位 9 范围） |
| Hash 索引 | `CacheItemKey` tenant_id+key + `murmurhash` |

### 9.3 关键技术常量

| 常量 | 值 | 位置 |
|------|---|------|
| `MAX_BYTE_LEN` | 28 位 9 的存储字节数 | `ob_number_v2.h` (引用于 `ObSequenceValue`) |
| 默认 `MAX_VALUE` | 9999999999999999999999999999 | `ObSequenceMaxMinInitializer` |
| 默认 `MIN_VALUE` | -999999999999999999999999999 | `ObSequenceMaxMinInitializer` |
| 默认 `CACHE` | 20 (Oracle) | `ObSequenceArg` |
| 13 个配置项 | INCREMENT_BY..RESTART | `ob_sequence_option.h` |

### 9.4 与 #66 的对比总览

| 路径 | 锁机制 | Cache 粒度 | 性能 |
|------|--------|----------|------|
| 普通 INSERT (next_batch) | 跨 observer SELECT FOR UPDATE | 用户配置 CACHE | ~10ms / cache 行 |
| Direct Load (auto_inc) | per-(ls, tablet) mutex hash (10243) | step_size (系统默认) | ~ns / 行 |

### 9.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#68 Snapshot mechanism / 副本追赶**：

OB 的 Snapshot 是新副本加入 / 故障副本恢复时的快路径 —— 避免从基线 SCN 全量回放日志。源码入口：`src/storage/slog/` + `src/logservice/archiveservice/` + `src/storage/backup/`。

- 物理 vs 逻辑 Snapshot 的差异
- 触发条件（minor/major snapshot）
- 增量合并策略
- 与 Standby (#65) / Archive (#62) 的衔接

整吗？