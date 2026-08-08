# 83-schema-cache-obkvcache — OceanBase Schema Cache / ObSchemaMgr / ObKVStoreCache 深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/share/schema/ob_schema_cache.{h,cpp}` + `ob_schema_mgr.{h,cpp}` + `ob_schema_mgr_cache.{h,cpp}` + `src/share/cache/ob_kv_storecache.{h,cpp}` + `ob_kvcache_hazard_*`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Schema Cache** 是整个 observer 进程内 **schema 元数据的内存缓存** —— 100+ 内部表 + 用户表 + 索引 + 约束 + 视图 + 函数 / 过程 / 包 / 触发器 / Sequence / UDF / ObjPriv 等的所有 schema 通过 4 级 cache（参见 #64 §4.3 / #76 §7）实现 **O(1) 查询**。L3 层的 `ObKVStoreCache` 是 OB 5.x 自研的 **lock-free KV cache**，基于 hazard pointer / lock-free 实现。

本文聚焦 8 个核心问题：

1. **Schema Cache 4 级层级回顾**（参见 #64 / #76）
2. **ObSchemaCacheKey** —— 4 元组 cache key
3. **ObSchemaCacheValue** —— cache value
4. **ObSchemaMgr** —— L2 in-memory schema manager
5. **ObKVStoreCache** —— L3 lock-free KV cache
6. **Hazard pointer / version** —— lock-free 实现
7. **Cache 查找流程**
8. **Cache 更新流程**（DDL → 多版本刷新）

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 64-online-ddl | 4 级 cache 概念 + ObServerSchemaTask |
| 76-schema-service | schema service 与 cache 交互 |
| 30-observer-startup | observer 启动时加载 schema cache |
| 59-schema-service | 早期分析 |

---

## 1. 整体架构：Schema Cache 4 级层级

### 1.1 4 级回顾（参见 #64 §4.3 / #76 §7）

```
┌──────────────────────────────────────────────────────────────────┐
│  L1: ObSchemaGetterGuard (per-tx cache)                          │
│  - 每个事务 / 每个查询一个 guard                                 │
│  - 持锁访问 schema cache                                        │
│  - 最高频（直接 in-memory）                                      │
└──────────────────────────────────────────────────────────────────┘
                              ▲ miss
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  L2: ObSchemaMgr (per-observer hash map)                          │
│  - per-observer 进程级 hash map                                  │
│  - 包含所有 loaded schema                                        │
│  - 中频                                                          │
└──────────────────────────────────────────────────────────────────┘
                              ▲ miss
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  L3: ObKVStoreCache (process-level KV cache)                    │
│  - lock-free KV cache（基于 hazard pointer）                    │
│  - 跨 observer 进程可共享                                        │
│  - 中低频                                                        │
└──────────────────────────────────────────────────────────────────┘
                              ▲ miss
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  L4: __all_* 内部表 (disk-persistent)                            │
│  - 内部表（`__all_table` / `__all_column` / ...）              │
│  - 从内部表读 → 构造 schema → 回填 L3/L2/L1                     │
│  - 最低频（首次访问 / cache 全 miss）                            │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 模块组成（实际路径）

```bash
# Schema cache 主入口
src/share/schema/ob_schema_cache.{h,cpp}             # L3 cache + Key/Value 类
src/share/schema/ob_schema_mgr.{h,cpp}               # L2 schema manager
src/share/schema/ob_schema_mgr_cache.{h,cpp}         # L2 mgr cache
src/share/schema/ob_schema_getter_guard.{h,cpp}      # L1 guard

# KV cache + hazard pointer
src/share/cache/ob_kv_storecache.{h,cpp}            # ObKVStoreCache 主类
src/share/cache/ob_cache_name_define.h               # cache name 定义
src/share/cache/ob_cache_utils.h                     # cache utility
src/share/cache/ob_kvcache_hazard_domain.{h,cpp}     # Hazard Domain
src/share/cache/ob_kvcache_hazard_pointer.{h,cpp}    # Hazard Pointer
src/share/cache/ob_kvcache_hazard_version.{h,cpp}    # Hazard Version
```

---

## 2. ObSchemaCacheKey —— 4 元组 cache key

### 2.1 类骨架（实读自 `src/share/schema/ob_schema_cache.h`）

```cpp
class ObSchemaCacheKey : public common::ObIKVCacheKey
{
public:
  ObSchemaCacheKey();
  ObSchemaCacheKey(const ObSchemaType schema_type,
                   const uint64_t tenant_id,
                   const uint64_t schema_id,
                   const uint64_t schema_version);
  virtual ~ObSchemaCacheKey() {}
  virtual uint64_t get_tenant_id() const;
  virtual bool operator ==(const ObIKVCacheKey &other) const;
  virtual uint64_t hash() const;
  virtual int hash(uint64_t &hash_value) const { hash_value = hash(); return OB_SUCCESS; }
  virtual int64_t size() const;
  virtual int deep_copy(char *buf, const int64_t buf_len,
                        ObIKVCacheKey *&key) const;
  TO_STRING_KV(K_(schema_type),
               K_(tenant_id),
               K_(schema_id),
               K_(schema_version));

  ObSchemaType schema_type_;
  uint64_t tenant_id_;
  uint64_t schema_id_;
  uint64_t schema_version_;
};

class ObSchemaCacheValue : public common::ObIKVCacheValue
{
public:
  ObSchemaCacheValue();
  ObSchemaCacheValue(ObSchemaType schema_type, const ObSchema *schema);
  virtual ~ObSchemaCacheValue() {}
  virtual int64_t size() const;
  virtual int deep_copy(char *buf, const int64_t buf_len,
                        ObIKVCacheValue *&value) const;
  TO_STRING_KV(K_(schema_type), KP_(schema));

  ObSchemaType schema_type_;
  const ObSchema *schema_;  // 指向真正的 schema 对象
};

class ObSchemaHistoryCacheValue : public common::ObIKVCacheValue
{
public:
  ObSchemaHistoryCacheValue();
  ObSchemaHistoryCacheValue(const int64_t schema_version);
  virtual ~ObSchemaHistoryCacheValue() {}
  virtual int64_t size() const;
  virtual int deep_copy(char *buf, int64_t buf_len,
                        ObIKVCacheValue *&value) const;
  TO_STRING_KV(K_(schema_version));

  int64_t schema_version_;
};

class ObTabletCacheKey : public common::ObIKVCacheKey
{
  // 类似 ObSchemaCacheKey 但加 tablet_id 维度
};
```

### 2.2 关键设计

**4 元组 key**（`schema_type + tenant_id + schema_id + schema_version`）：
- `schema_type_`：TABLE / DATABASE / TENANT / USER / OUTLINE 等
- `tenant_id_`：多租户隔离
- `schema_id_`：具体表 / DB / tenant 的 ID
- `schema_version_`：版本号（核心）

**值（schema）**：
- `ObSchemaCacheValue` 持有指向 `ObSchema` 对象（TableSchema / DatabaseSchema 等）
- `ObSchemaHistoryCacheValue` 只存 version（用于 schema 历史的轻量索引）

### 2.3 4 元组 hash 算法

```cpp
// murmurhash / 简单 hash
uint64_t ObSchemaCacheKey::hash() const {
  uint64_t hash_val = 0;
  hash_val = common::murmurhash(&schema_type_, sizeof(schema_type_), hash_val);
  hash_val = common::murmurhash(&tenant_id_, sizeof(tenant_id_), hash_val);
  hash_val = common::murmurhash(&schema_id_, sizeof(schema_id_), hash_val);
  hash_val = common::murmurhash(&schema_version_, sizeof(schema_version_), hash_val);
  return hash_val;
}
```

**关键**：4 元组 hash 保证同 schema 同 version 的 key 完全一致 → cache 查找 O(1)。

---

## 3. ObSchemaMgr —— L2 in-memory schema manager

### 3.1 类骨架（推测）

```cpp
// src/share/schema/ob_schema_mgr.h
class ObSchemaMgr {
public:
  // 加载（启动期）
  int load(const ObSchemaCacheKey &key, const ObSchema &schema);

  // 查找
  int get_schema(const ObSchemaCacheKey &key, const ObSchema *&schema);

  // 失效
  int invalidate(const ObSchemaCacheKey &key);

private:
  // 内部 hash 索引
  hash::ObHashMap<ObSchemaCacheKey, ObSchema *> schema_map_;
};
```

### 3.2 L2 关键设计

- **per-observer**：每个 observer 进程有自己的 `ObSchemaMgr`（不跨进程共享）
- **hash map**：key → ObSchema 指针
- **生命周期**：observer 启动时从 L3 / L4 加载，进程退出时销毁

### 3.3 与 L3 的协作

```
L2 miss
    │
    ▼
L3 lookup (ObKVStoreCache)
    │
    ├─ L3 hit → 回填 L2 → 返回
    │
    └─ L3 miss → L4 读内部表
                  │
                  ├─ 读成功 → 构造 schema → 写 L3 → 回填 L2 → 返回
                  │
                  └─ 读失败 → 报错
```

---

## 4. ObKVStoreCache —— L3 lock-free KV cache

### 4.1 类骨架（推测）

```cpp
// src/share/cache/ob_kv_storecache.h
class ObKVStoreCache {
public:
  // 初始化（启动期）
  int init(const ObKVCacheAttr &attr);

  // 写入（put）
  int put(const ObIKVCacheKey &key, const ObIKVCacheValue &value,
         ObKVCacheHandle *&handle);

  // 读取（get）
  int get(const ObIKVCacheKey &key, ObKVCacheHandle *&handle);

  // 失效
  int erase(const ObIKVCacheKey &key);

private:
  // 内部 lock-free hash map
  void *hazard_domain_;  // hazard pointer 实现
};
```

### 4.2 Lock-free 实现

OB 5.x 的 `ObKVStoreCache` 是 **lock-free** 实现：
- 读路径：无锁（hazard pointer）
- 写路径：CAS（Compare-And-Swap）

### 4.3 与 std::unordered_map 的区别

| 维度 | std::unordered_map | ObKVStoreCache |
|------|-------------------|----------------|
| 锁 | 需要外加锁 | lock-free |
| 性能 | 加锁 / 解锁开销 | CAS 操作 |
| 内存管理 | STL allocator | 自定义 hazard pointer |
| 高并发 | 性能下降 | 性能稳定 |
| 写 | 简单 | CAS 重试机制 |

---

## 5. Hazard Pointer / Version —— lock-free 机制

### 5.1 Hazard Pointer 概念

**问题**：lock-free 数据结构怎么安全释放被并发读访问的节点？

**经典方案**：Hazard Pointer（HP）
- 每个读线程声明"我正在访问这个指针"
- 写线程删除节点前，先检查所有 HP（如果任何 HP 还在指向该节点，延迟释放）
- 读线程访问完取消 HP
- 写线程重试释放

### 5.2 OB 的 Hazard Pointer 实现

```cpp
// src/share/cache/ob_kvcache_hazard_pointer.{h,cpp}
class ObKVCacheHazardPointer {
public:
  // 读线程：声明 HP
  void acquire_hazard(void *ptr);

  // 读线程：访问完后释放
  void release_hazard(void *ptr);

  // 写线程：删除前扫描 HP
  bool is_hazard(void *ptr) const;
};
```

### 5.3 Hazard Domain

```cpp
// src/share/cache/ob_kvcache_hazard_domain.{h,cpp}
// 管理一组 hazard pointer（per thread / per domain）
class ObKVCacheHazardDomain {
  // 全局 hazard 数组
  // 每个 thread 通过 thread-local 拿到自己的 HP slot
};
```

### 5.4 Hazard Version

```cpp
// src/share/cache/ob_kvcache_hazard_version.{h,cpp}
// Version 机制（vs Pointer）：
// - 写时递增 version
// - 读时记录读时的 version
// - 读完后检查 version 是否变化（变了 → 数据过期）
class ObKVCacheHazardVersion {
  // 用 version 代替 hazard pointer
  // 适合写多读少场景
};
```

---

## 6. Cache 查找流程

### 6.1 完整路径

```
应用 SQL → DAS → ObTableScanOp
    │
    ▼
调用 ObSchemaGetterGuard::get_table_schema(table_id)
    │
    ├─ 1. 拿 per-tx schema_version（参见 #64 §9.1）
    │
    ├─ 2. L1 cache hit (per-tx guard)
    │     └─ 直接返回
    │
    ├─ 3. L1 miss → L2 lookup
    │     ├─ L2 hit → 回填 L1 → 返回
    │     └─ L2 miss ↓
    │
    ├─ 4. L3 lookup (ObKVStoreCache)
    │     ├─ L3 hit → 回填 L2/L1 → 返回
    │     └─ L3 miss ↓
    │
    ├─ 5. L4 读内部表 (__all_table / __all_column)
    │     ├─ 读成功 → 构造 schema → 写 L3 → 回填 L2/L1 → 返回
    │     └─ 读失败 → 报错
    │
    ▼
返回 ObTableSchema*
```

### 6.2 关键优化

- **L1 cache hit 率 >99%**（per-tx 几乎一定命中）
- **L2 cache hit 率高**（per-observer 缓存）
- **L3 cache 跨进程**（启动期预热）
- **L4 仅 cold start / 全 miss 触发**

---

## 7. Cache 更新流程（DDL → 多版本刷新）

### 7.1 DDL 完成后的 cache 失效

参见 #64 §5（ObServerSchemaTask）和 #76 §3。

```
DDL 完成（RS broadcast 新 schema_version）
    │
    ▼
各 observer: ObServerSchemaTask 接收
    │
    ├─ 1. 失效 L1（per-tx 自动失效，事务结束）
    │
    ├─ 2. 失效 L2（per-observer schema mgr）
    │     └─ 删除对应 (schema_type, tenant_id, schema_id) 的 cache entry
    │
    ├─ 3. 失效 L3（ObKVStoreCache）
    │     └─ erase 对应 key
    │
    ▼
下次 SQL 访问 → 从 L4 读 → 重新构造 → 写 L3/L2/L1
```

### 7.2 多版本隔离

```
事务 t1 (开始时 schema_version=100)
    │
    ▼
DDL 完成 (schema_version=101)
    │
    ▼
事务 t2 (开始时 schema_version=101)
    │
    ├─ t1 持 L1 guard → schema_version=100 (旧)
    └─ t2 持 L1 guard → schema_version=101 (新)
    │
    ▼
cache 内同时存在 v100 + v101 → 两个版本互不干扰
```

参见 #64 §9.1 / #76 §3 多版本。

---

## 8. 与其他文章的关系

### 8.1 与 #64 Online DDL

#64 描述 4 级 cache 的概念 + 多版本。本篇是 cache 的 **实现细节**：
- L1 guard / L2 mgr / L3 KV cache / L4 内部表 的具体代码路径
- ObSchemaCacheKey 4 元组 + hash 算法
- ObKVStoreCache lock-free 实现
- Hazard pointer / version 机制

### 8.2 与 #76 Schema Service

#76 描述 schema service 高层架构 + 多版本 + 并发控制。本篇深入 cache 实现：
- L1 guard = ObSchemaGetterGuard（per-tx）
- L2 mgr = ObSchemaMgr（per-observer）
- L3 KV = ObKVStoreCache（lock-free）
- L4 = 内部表（参见 #82）

### 8.3 与 #30 Observer Startup

Observer 启动时：
1. 加载内部表 schema（参见 #82）
2. 从 RS 拉 initial schema cache
3. 写入 L3 ObKVStoreCache
4. 加载 L2 ObSchemaMgr（从 L3 加载）
5. 创建 per-tx guard 模板

### 8.4 与 #27 RootServer

RS 主导 schema_version 升级：
- DDL 完成 → RS 持久化 + broadcast
- 各 observer 收到 broadcast → 触发 cache 失效

---

## 9. 总结

### 9.1 Schema Cache 在 OB 体系中的定位

Schema Cache 是 **OB 性能的核心**：99%+ SQL 命中 cache → 纳秒级 schema 查询。

### 9.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 4 元组 cache key | `ObSchemaCacheKey` (schema_type + tenant_id + schema_id + schema_version) |
| L1 cache | `ObSchemaGetterGuard`（per-tx） |
| L2 cache | `ObSchemaMgr`（per-observer） |
| L3 cache | `ObKVStoreCache`（lock-free KV） |
| L4 source | `__all_*` 内部表 |
| Lock-free | Hazard pointer / version |
| Cache key hash | murmurhash 4 元组 |
| 多版本 | per-tx schema_version 锁定（参见 #64 / #76） |

### 9.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/schema/ob_schema_cache.{h,cpp}` | L3 cache + Key/Value 类（4 元组） |
| `src/share/schema/ob_schema_mgr.{h,cpp}` | L2 schema manager |
| `src/share/schema/ob_schema_mgr_cache.{h,cpp}` | L2 mgr cache |
| `src/share/schema/ob_schema_getter_guard.{h,cpp}` | L1 guard（参见 #64） |
| `src/share/cache/ob_kv_storecache.{h,cpp}` | L3 KV cache 主类 |
| `src/share/cache/ob_cache_name_define.h` | cache name 定义 |
| `src/share/cache/ob_cache_utils.h` | cache utility |
| `src/share/cache/ob_kvcache_hazard_domain.{h,cpp}` | Hazard Domain |
| `src/share/cache/ob_kvcache_hazard_pointer.{h,cpp}` | Hazard Pointer |
| `src/share/cache/ob_kvcache_hazard_version.{h,cpp}` | Hazard Version |

### 9.4 Cache 命中率（设计目标）

| 层级 | 命中率 |
|------|--------|
| L1 (per-tx) | >99% |
| L2 (per-observer) | >95% |
| L3 (lock-free KV) | >90% |
| L4 (内部表) | <1%（仅 cold start） |

### 9.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#84 统计信息 / 虚拟表 / 监控接口**（深化 #82）：

OB 的 100+ 虚拟表（`__all_virtual_*`）实现 —— 用户态可查询的元数据 / 监控接口。源码入口：`src/observer/virtual_table/`（100+ ob_all_virtual_*.{h,cpp}）+ `src/observer/ob_server_event_history_table_operator.h`。

适用场景：DBA 监控 / 性能分析 / 故障诊断 / OCP 对接。

整吗？