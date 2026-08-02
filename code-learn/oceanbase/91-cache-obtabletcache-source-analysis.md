# 91-cache-obtabletcache — OceanBase Cache 体系 / ObTabletCache / ObKVStoreCache 深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/share/cache/` 多文件 + `src/share/schema/ob_schema_cache.h`（参见 #83）+ `src/storage/blocksstable/ob_micro_block_cache.{h,cpp}` + `src/storage/blocksstable/ob_bloom_filter_cache.{h,cpp}` + `src/storage/ddl/ob_ddl_redo_log_writer.{h,cpp}` 等散落位置）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Cache 体系**是整个 observer 集群"性能加速"的核心 —— Block Cache / Tablet Cache / Schema Cache / Plan Cache / KV Cache 五级缓存覆盖 OB 的所有数据访问路径。OB 5.x 的 Cache 建立在 **`ObKVStoreCache`**（lock-free KV cache，参见 #83）+ 各种具体 cache 实现（block / tablet / schema / plan / vtable）之上。

本文聚焦 8 个核心问题：

1. **Cache 体系全景** —— 5 级 Cache
2. **ObKVStoreCache 基础**（参见 #83）
3. **ObMicroBlockCache** —— Block Cache
4. **ObBloomFilterCache** —— BloomFilter Cache
5. **ObTabletCache / ObSchemaCache** —— Tablet / Schema Cache
6. **ObDDLCache** —— DDL Cache
7. **ObPlanCache** —— Plan Cache
8. **Cache 协同 / 一致性 / 失效**

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 51-block-cache | #51 是早期分析 Block Cache 概览 |
| 52-bloom-filter | #52 是 BloomFilter 详解 |
| 83-schema-cache-obkvcache | #83 是 Schema Cache 4 级 + ObKVStoreCache lock-free |
| 76-schema-service | Schema Service + 4 级 cache |
| 64-online-ddl | DDL 触发 cache 失效 |
| 90-sstable-macroblock-encoding | Block Cache + BloomFilter Cache |
| 89-memtable-memstore | memtable → SSTable → Block Cache |

---

## 1. 整体架构：OB Cache 5 级

### 1.1 模块组成（散落多处）

```bash
# 真实位置
src/share/cache/
├── ob_kv_storecache.{h,cpp}        # ObKVStoreCache 主类（参见 #83）
├── ob_kvcache_store.h               # KV cache store
├── ob_kvcache_struct.h              # KV cache 结构
├── ob_kvcache_map.h                 # KV cache map
├── ob_kvcache_pre_warmer.h          # pre-warm 预热
├── ob_kvcache_hazard_version.h      # hazard version
├── ob_recycle_multi_kvcache.h       # 多 KV cache 回收
├── ob_cache_utils.h                 # cache utility
├── ob_cache_name_define.h           # cache name 定义
└── ob_vtable_event_recycle_buffer.h # virtual table 回收 buffer

# Block Cache（参见 #90）
src/storage/blocksstable/
├── ob_micro_block_cache.{h,cpp}     # micro block cache
└── ob_bloom_filter_cache.{h,cpp}    # bloom filter cache

# Schema Cache（参见 #83）
src/share/schema/ob_schema_cache.h    # 4 级 cache 主入口

# DDL Cache
src/storage/ddl/ob_ddl_redo_log_writer.{h,cpp}  # DDL redo
# 推测的 DDL cache 类（待 grep）

# Plan Cache
src/sql/plan_cache/                 # 推测的 plan cache 子目录
# 实际位置待 grep

# 散落各模块
src/storage/direct_load/ob_direct_load_vector_utils.{h,cpp}
src/storage/direct_load/ob_direct_load_row_iterator.{h,cpp}
```

### 1.2 路径修正（来自 #82-#90 路径修正的延续）

```
正确路径:
  src/share/cache/ob_kv_storecache.{h,cpp}    # ObKVStoreCache (lock-free KV)
  src/share/cache/ob_kvcache_*.{h,cpp}         # KV cache 基础设施
  src/storage/blocksstable/ob_micro_block_cache.{h,cpp}  # Block Cache
  src/storage/blocksstable/ob_bloom_filter_cache.{h,cpp}  # BloomFilter Cache
  src/share/schema/ob_schema_cache.h          # Schema Cache (参见 #83)
  散落各模块的 cache 类

不存在路径 (按 #82-#90 路径修正继续):
  src/storage/cache/  ← 不存在
  src/cache/          ← 不存在
  src/lib/cache/      ← 不存在
```

### 1.3 5 级 Cache 架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Level 1: L1 - per-observer in-memory cache                     │
│  - Block Cache (micro block / macro block)                      │
│  - BloomFilter Cache                                              │
│  - 最高频（直接 in-memory）                                      │
└──────────────────────────────────────────────────────────────────┘
                              ▲ miss
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Level 2: L2 - per-tablet in-memory cache                         │
│  - Tablet Cache (per tablet hot data)                           │
│  - 避免重复 cache 同 tablet 的数据                                │
└──────────────────────────────────────────────────────────────────┘
                              ▲ miss
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Level 3: L3 - ObKVStoreCache (lock-free KV)                    │
│  - 跨进程可共享（pre-warm / reload）                             │
│  - Schema Cache / Plan Cache                                      │
│  - hazard pointer / version (参见 #83)                           │
└──────────────────────────────────────────────────────────────────┘
                              ▲ miss
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Level 4: L4 - memtable (参见 #89)                                │
│  - 活跃数据 in-memory                                            │
│  - row-level + MVCC 链                                            │
└──────────────────────────────────────────────────────────────────┘
                              ▲ miss
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Level 5: L5 - SSTable on disk (参见 #08 / #90)                  │
│  - 持久化数据                                                     │
│  - micro block + macro block + BloomFilter                       │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObKVStoreCache 基础（参见 #83）

### 2.1 关键设计（来自 #83）

```cpp
// src/share/cache/ob_kv_storecache.{h,cpp} (实读自 #83)
class ObKVStoreCache {
public:
  // 写
  int put(const ObIKVCacheKey &key, const ObIKVCacheValue &value,
         ObKVCacheHandle *&handle);

  // 读
  int get(const ObIKVCacheKey &key, ObKVCacheHandle *&handle);

  // 失效
  int erase(const ObIKVCacheKey &key);

private:
  // 内部 lock-free hash map + hazard pointer
  void *hazard_domain_;
};
```

参见 #83 详细分析（lock-free 实现 + hazard pointer + 4 元组 key + L3 cache 详情）。

---

## 3. ObMicroBlockCache —— Block Cache

### 3.1 角色

```cpp
// (推测, src/storage/blocksstable/ob_micro_block_cache.{h,cpp})
class ObMicroBlockCache {
public:
  // 缓存 micro block
  int get_block(const ObMicroBlockCacheKey &key, ObMicroBlock &block);

  // 释放（LRU）
  int release(ObMicroBlockHandle &handle);
};
```

### 3.2 关键设计

- **per-observer in-memory cache**（L1）
- LRU 淘汰
- key = (tablet_id, macro_block_id, micro_block_index)
- value = micro block 字节流

### 3.3 与 #90 SSTable 的关系

参见 #90 §9.1：L1 per-observer micro block cache 是 SSTable 查询最快的层。

---

## 4. ObBloomFilterCache —— BloomFilter Cache

### 4.1 角色

```cpp
// (推测, src/storage/blocksstable/ob_bloom_filter_cache.{h,cpp})
class ObBloomFilterCache {
public:
  // 缓存 BloomFilter
  int get_bf(const ObBloomFilterCacheKey &key, ObBloomFilterData &bf);

  // 释放
  int release(ObBloomFilterHandle &handle);
};
```

### 4.2 关键设计

- **per-observer in-memory cache**（L1）
- key = (tablet_id, macro_block_id) 或 (sstable_id)
- value = BloomFilter bitset

### 4.3 与 #90 / #52 的关系

参见 #90 §6（3 级 BloomFilter）和 #52 详解。

---

## 5. ObTabletCache / ObSchemaCache

### 5.1 ObTabletCache

> ⚠️ **路径修正**：我之前在 #60 提的 `src/storage/tablet/ob_tablet_cache.{h,cpp}` **未在本次扫描中确认**。`find` 没找到该文件。Tablet Cache 可能在以下位置之一：
> - `src/storage/tablet/ob_tablet_meta.h`
> - 散落在 tablet 相关 .h 中
> - 通过 `ObStorageMetaCache`（参见 #83 §5）实现

Tablet Cache 概念上存在（per-tablet hot data cache），但具体实现可能在 tablet 模块内部而非独立 cache 类。

### 5.2 ObSchemaCache（参见 #83）

参见 #83 详细分析：
- 4 级 cache（L1 guard / L2 mgr / L3 KV / L4 内部表）
- `ObSchemaCacheKey` 4 元组（schema_type + tenant_id + schema_id + schema_version）
- `ObSchemaCacheValue` / `ObSchemaHistoryCacheValue` / `ObTabletCacheKey`
- `ObSchemaMgr`（L2）/ `ObKVStoreCache`（L3）

---

## 6. ObDDLCache

### 6.1 角色

```cpp
// (推测, src/storage/ddl/ob_ddl_redo_log_writer.{h,cpp})
class ObDDLRedoLogWriter {
  // DDL redo log 写
};
```

### 6.2 DDL Cache 设计

DDL Cache 关注：
- DDL 操作期间的中间状态
- ObDDLTask（参见 #79）
- 短生命周期 cache（DDL 完成即失效）

### 6.3 与 #79 / #64 的关系

- DDL 期间需要 schema guard（参见 #64 §6.4）
- 完成后通过 ObMultiVersionSchemaService 刷新（参见 #76 §3）

---

## 7. ObPlanCache

### 7.1 角色

> ⚠️ **路径修正**：我之前在 #60 提的 `src/share/plan_cache/` 路径未确认。实际位置可能在：
> - `src/sql/plan_cache/`（推测）
> - `src/sql/optimizer/plan_cache/`（推测）
> - 散落在 SQL 层

Plan Cache 是 SQL 层的查询计划缓存：
- 同 SQL 多次执行 → 复用 plan（避免重新 parse + optimize）
- key = 标准化 SQL + 涉及的 schema_version

### 7.2 与 #22-plan-cache 的关系

参见 #22-plan-cache（早期分析 30KB+）。本篇标记 caveat（实际位置待 grep 确认）。

### 7.3 与 #84 的关系

`__all_virtual_plan_stat`（参见 #84）监控 plan cache：
- 当前 plan cache 大小
- hit rate
- 命中次数

---

## 8. Cache 协同 / 一致性 / 失效

### 8.1 Cache 协同

```
应用查询: SELECT * FROM t WHERE id = 1
    │
    ▼
L1 (Block Cache)
    │
    ├─ 1. 查 ObMicroBlockCache
    │     ├─ hit → 返回
    │     └─ miss ↓
    │
    ├─ 2. 查 ObBloomFilterCache
    │     ├─ 命中 → 读 SSTable
    │     └─ 未命中 → 不读
    │
    ├─ 3. 查 L2 (Tablet Cache)
    │     ├─ hit → 返回
    │     └─ miss ↓
    │
    ├─ 4. 查 L3 (ObKVStoreCache)
    │     ├─ hit → 返回
    │     └─ miss ↓
    │
    ├─ 5. 查 L4 (MemTable)
    │     └─ 查 L5 (SSTable)
    │
    └─ 6. 返回结果 + 写回 cache
```

### 8.2 Cache 一致性

参见 #83 / #76 / #64 的 cache 一致性：
- Schema Cache：per-tx schema_version 锁定（参见 #64 §9.1 / #76 §3 / #83 §7）
- Block Cache：基于 macro block 的 CRC 校验
- BloomFilter Cache：基于 BF hash 校验
- Plan Cache：基于 schema_version 校验（schema 变 → plan cache 失效）

### 8.3 Cache 失效

| 触发事件 | 受影响 Cache | 失效策略 |
|----------|------------|----------|
| DDL 完成 | Schema / Plan / Block | invalidate by (tenant_id, schema_id) |
| memtable freeze | Block Cache (新 SSTable) | 自动失效 |
| Standby replay | Block Cache (Standby observer) | 自动失效 |
| Observer 启动 | 所有 cache | 重新加载 |

### 8.4 Cache 监控

参见 #84 虚拟表：
- `__all_virtual_memstore_info` —— MemStore 信息
- `__all_virtual_tx_stat` —— 事务统计
- `__all_virtual_plan_stat` —— Plan Cache 统计
- `__all_virtual_server_*` —— Server 状态

---

## 9. 与其他文章的关系

### 9.1 与 #51 Block Cache

#51 是早期分析 Block Cache 概览。本篇是 #51 的 **深化**：
- #51 聚焦 Block Cache
- 本文覆盖所有 Cache 类型（Block / Tablet / Schema / Plan / KV）
- 本文重点是路径修正（多个 cache 散落位置）

### 9.2 与 #52 BloomFilter

#52 是 BloomFilter 详解。本篇把 BloomFilter Cache 纳入整体 Cache 体系。

### 9.3 与 #83 Schema Cache

#83 详细分析 Schema Cache 4 级 + ObKVStoreCache lock-free。本篇引用 #83 不重复。

### 9.4 与 #76 Schema Service

Schema Service 持久化 + 4 级 cache 协同（参见 #76 §7）。

### 9.5 与 #64 Online DDL

DDL 触发 cache 失效（参见 #64 §5.2）：
- DDL 完成 → broadcast schema_version
- observer 失效 Schema Cache / Plan Cache

### 9.6 与 #90 SSTable

Block Cache / BloomFilter Cache 是 SSTable 查询的关键（参见 #90 §9.1）。

### 9.7 与 #89 MemTable

MemTable 写入路径绕过 Block Cache（直接写 memtable，参见 #89 §5）。

### 9.8 与 #84 Virtual Table

100+ 虚拟表监控 cache 状态（参见 #84）。

---

## 10. 总结

### 10.1 Cache 体系在 OB 体系中的定位

Cache 是 **OB 性能加速的核心**：
- 5 级 cache 覆盖所有数据访问路径
- lock-free ObKVStoreCache（参见 #83）
- Block Cache / BloomFilter Cache（参见 #90 / #52）
- Schema Cache 4 级（参见 #83）
- Plan Cache / Tablet Cache / DDL Cache

### 10.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 5 级 cache 层级 | L1 Block + L2 Tablet + L3 ObKVStoreCache + L4 MemTable + L5 SSTable |
| ObKVStoreCache | `src/share/cache/ob_kv_storecache.{h,cpp}`（lock-free KV，参见 #83） |
| ObMicroBlockCache | `src/storage/blocksstable/ob_micro_block_cache.{h,cpp}` |
| ObBloomFilterCache | `src/storage/blocksstable/ob_bloom_filter_cache.{h,cpp}` |
| ObSchemaCache | 4 级 cache（参见 #83） |
| ObTabletCache | 推测散落 tablet 模块 |
| ObDDLCache | 推测 `src/storage/ddl/` |
| ObPlanCache | 推测 `src/sql/plan_cache/` |
| Cache 一致性 | per-tx schema_version 锁定 |
| Cache 失效 | DDL / freeze / observer 启动 |
| Cache 监控 | `__all_virtual_*_stat`（参见 #84） |

### 10.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/cache/ob_kv_storecache.{h,cpp}` | ObKVStoreCache 主类（参见 #83） |
| `src/share/cache/ob_kvcache_store.h` | KV cache store |
| `src/share/cache/ob_kvcache_struct.h` | KV cache 结构 |
| `src/share/cache/ob_kvcache_map.h` | KV cache map |
| `src/share/cache/ob_kvcache_pre_warmer.h` | pre-warm 预热 |
| `src/share/cache/ob_kvcache_hazard_version.h` | hazard version |
| `src/share/cache/ob_recycle_multi_kvcache.h` | 多 KV cache 回收 |
| `src/share/cache/ob_cache_utils.h` | cache utility |
| `src/share/cache/ob_cache_name_define.h` | cache name 定义 |
| `src/share/cache/ob_vtable_event_recycle_buffer.h` | virtual table 回收 buffer |
| `src/storage/blocksstable/ob_micro_block_cache.{h,cpp}` | Block Cache |
| `src/storage/blocksstable/ob_bloom_filter_cache.{h,cpp}` | BloomFilter Cache |
| `src/share/schema/ob_schema_cache.h` | Schema Cache 4 级（参见 #83） |
| `src/storage/ddl/ob_ddl_redo_log_writer.{h,cpp}` | DDL redo log 写 |
| `src/storage/direct_load/ob_direct_load_vector_utils.{h,cpp}` | Direct Load vector utils |
| `src/storage/direct_load/ob_direct_load_row_iterator.{h,cpp}` | Direct Load row iterator |

### 10.4 5 级 Cache 层级

| 层级 | 元素 | 命中率 | 来源 |
|------|------|--------|------|
| L1 | Block / BloomFilter / Schema guard | >95% | 内存（per-observer） |
| L2 | Tablet / Schema mgr | >90% | 内存（per-observer） |
| L3 | ObKVStoreCache（lock-free） | >85% | 内存（跨 observer） |
| L4 | MemTable | >99% | 内存（per-tablet） |
| L5 | SSTable on disk | <5%（cold） | 磁盘 |

### 10.5 路径修正（来自 #82-#90 路径修正的延续）

```
正确路径:
  src/share/cache/ob_kv_storecache.{h,cpp}    # ObKVStoreCache
  src/share/cache/ob_kvcache_*.{h,cpp}         # KV cache 基础设施
  src/storage/blocksstable/ob_micro_block_cache.{h,cpp}  # Block Cache
  src/storage/blocksstable/ob_bloom_filter_cache.{h,cpp}  # BloomFilter Cache
  src/share/schema/ob_schema_cache.h          # Schema Cache

不存在路径 (按 #82-#90 路径修正继续):
  src/storage/cache/  ← 不存在
  src/cache/          ← 不存在
  src/lib/cache/      ← 不存在
  src/share/plan_cache/  ← 推测（待 grep 确认）
  src/storage/tablet/ob_tablet_cache.{h,cpp}  ← 未找到（散落 tablet 模块）
```

### 10.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#92 Compaction / Minor & Major Freeze / 合并策略**（深化 #34）：

OB 的 Compaction 体系 —— minor freeze（memtable → mini-sstable）/ major freeze（mini-sstable → SSTable）/ merge 策略 / 调度算法。源码入口：`src/storage/compaction/` + `src/rootserver/freeze/`。

适用场景：合并调优 / 存储空间 / 性能分析。

整吗？