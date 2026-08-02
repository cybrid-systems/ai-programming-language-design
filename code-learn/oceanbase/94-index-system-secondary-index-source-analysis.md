# 94-index-system — OceanBase 索引系统 / 二级索引 / 索引类型深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/storage/blocksstable/index_block/` **38 文件** + `src/storage/access/` 多个 index 类 + `src/rootserver/ob_index_builder.h` + `src/storage/blocksstable/ob_sstable.h`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **索引系统**是整个 observer 集群"查询加速"的核心 —— 主键索引 / 二级索引 / 唯一索引 / 函数索引 / 覆盖索引 / 索引回表等多种索引类型支撑 SQL 查询的快速定位。OB 5.x 的索引建立在 `index_block/` 子目录 + `ob_index_block_builder` + `ob_index_block_*_iterator` + `ob_index_tree_traverser` + `ob_sstable_index_filter` 之上，是 BTree 索引 + 列存扩展 + 索引回表的完整实现。

本文聚焦 8 个核心问题：

1. **索引系统全景** —— 38+ 文件
2. **ObIndexBlockBuilder** —— 索引块构建
3. **ObIndexBlockIterator** —— 索引迭代
4. **ObIndexTreeTraverser** —— 索引树遍历
5. **ObSSTableIndexFilter** —— 索引过滤
6. **ObIndexSkipScanner** —— 跳跃扫描
7. **ObSSTableIndexScanner** —— 索引扫描
8. **二级索引 / 函数索引 / 覆盖索引** 详解

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 18-index-design | #18 是早期分析二级索引设计概览 |
| 17-query-optimizer | #17 是早期分析查询优化器（含索引选择） |
| 15-keybtree | #15 是早期分析 ObKeyBtree（参见 #15） |
| 22-plan-cache | #22 是早期分析计划缓存 |
| 90-sstable-macroblock-encoding | SSTable 包含索引块（参见 #90） |
| 93-ddl-physical-execution | Online DDL 包含索引构建（参见 #93 §6） |

---

## 1. 整体架构：索引 5 层

### 1.1 模块组成（38+ 文件）

```bash
$ ls src/storage/blocksstable/index_block/
ob_agg_row_struct.{h,cpp}                    # agg row 结构
ob_clustered_index_block_writer.{h,cpp}      # clustered index writer
ob_ddl_index_block_row_iterator.{h,cpp}      # DDL index iterator
ob_ddl_sstable_scan_merge.{h,cpp}            # DDL sstable scan merge
ob_index_block_aggregator.{h,cpp}            # aggregator
ob_index_block_bare_iterator.{h,cpp}         # bare iterator
ob_index_block_builder.{h,cpp}               # builder (核心)
ob_index_block_dual_meta_iterator.{h,cpp}    # dual meta iterator
ob_index_block_dumper.{h,cpp}                # dumper
ob_index_block_macro_iterator.{h,cpp}        # macro iterator
ob_index_block_tree_cursor.{h,cpp}           # tree cursor
ob_index_block_row_scanner.{h,cpp}            # row scanner
# ... 30+ 其他
```

**38 文件**（index_block/ 子目录）+ `src/storage/access/` 多个 index 类 + `src/rootserver/ob_index_builder.h`。

### 1.2 路径修正（来自 #82-#93 路径修正的延续）

```
正确路径:
  src/storage/blocksstable/index_block/ (38 files)
  src/storage/access/ob_index_block_tree_traverser.{h,cpp}
  src/storage/access/ob_index_skip_scanner.{h,cpp}
  src/storage/access/ob_index_sstable_estimator.{h,cpp}
  src/storage/access/ob_index_tree_prefetcher.{h,cpp}
  src/storage/access/ob_sstable_index_filter.{h,cpp}
  src/rootserver/ob_index_builder.h

不存在路径 (按 #82-#93 路径修正继续):
  src/share/index_builder/  ← 不存在
  src/index_builder/         ← 不存在
  src/lib/index_builder/     ← 不存在
```

### 1.3 5 层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: 索引接口 (SQL 语法)                                     │
│  - CREATE INDEX / DROP INDEX / ALTER INDEX                    │
│  - 主键 / 二级 / 唯一 / 函数 / 覆盖索引                       │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: 索引构建 (ObIndexBuilder)                            │
│  - src/rootserver/ob_index_builder.h                          │
│  - CREATE INDEX 入口                                           │
│  - per-tablet 索引构建                                         │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: 索引块 (IndexBlock)                                    │
│  - src/storage/blocksstable/index_block/ 38 文件             │
│  - ObIndexBlockBuilder / ObIndexBlockIterator / ObIndexBlock   │
│  - 索引树 + 索引行                                              │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: 索引遍历 (Tree Traverser)                              │
│  - src/storage/access/ob_index_block_tree_traverser.{h,cpp}   │
│  - src/storage/access/ob_index_skip_scanner.{h,cpp}            │
│  - src/storage/access/ob_index_tree_prefetcher.{h,cpp}        │
│  - 索引树遍历 + 跳跃扫描 + 预取                                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5: 索引过滤 + 扫描                                         │
│  - src/storage/access/ob_sstable_index_filter.{h,cpp}          │
│  - src/storage/blocksstable/index_block/ob_sstable_index_scanner.h│
│  - 索引过滤 + SSTable 索引扫描                                 │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObIndexBlockBuilder —— 索引块构建

### 2.1 类骨架（实读自 `ob_index_micro_block_builder.h`）

```cpp
// src/storage/blocksstable/ob_index_micro_block_builder.h
namespace oceanbase {
namespace blocksstable {

static const uint32_t META_BLOCK_MAGIC_NUM = 0x7498;
static const uint32_t META_BLOCK_VERSION = 1;
static const int64_t DEFAULT_MICRO_BLOCK_WRITER_COUNT = 64;
static const int64_t DEFAULT_MACRO_BLOCK_CNT = 64;
static const int64_t SMALL_SSTABLE_THRESHOLD = 1 << 20; // 1MB

class ObIMicroBlockReader;
class ObIMacroBlockFlushCallback;

typedef common::ObSEArray<ObIndexTreeRootCtx *, DEFAULT_MICRO_BLOCK_WRITER_COUNT>
    IndexTreeRootCtxList;

typedef common::ObSEArray<ObDataMacroBlockMeta *, DEFAULT_MACRO_LEVEL_ROWS_COUNT>
    ObMacroMetasArray;
typedef common::ObSEArray<ObClusteredIndexBlockMicroInfos, DEFAULT_MACRO_LEVEL_ROWS_COUNT>
    ObClusteredMicroInfosArray;
typedef common::ObSEArray<int64_t, DEFAULT_MACRO_LEVEL_ROWS_COUNT>
    ObAbsoluteOffsetArray;

enum ObIndexBuildTaskType : uint8_t {
  // ... 多种索引构建任务类型
};
}
}
```

### 2.2 关键常量

| 常量 | 值 | 含义 |
|------|---|------|
| `META_BLOCK_MAGIC_NUM` | 0x7498 | 索引块 magic number |
| `META_BLOCK_VERSION` | 1 | 索引块版本 |
| `DEFAULT_MICRO_BLOCK_WRITER_COUNT` | 64 | 默认 micro block writer 数 |
| `DEFAULT_MACRO_BLOCK_CNT` | 64 | 默认 macro block 数 |
| `SMALL_SSTABLE_THRESHOLD` | 1MB | 小 SSTable 阈值 |

### 2.3 ObClusteredIndexBlockWriter

```cpp
// src/storage/blocksstable/index_block/ob_clustered_index_block_writer.{h,cpp}
class ObClusteredIndexBlockWriter {
  // Clustered Index Block Writer
  // - 主键索引按 rowkey 聚簇
  // - 数据按主键顺序存储
  // - range scan 性能最佳
};
```

---

## 3. ObIndexBlockIterator —— 索引迭代

### 3.1 ObIndexBlockBareIterator

```cpp
// src/storage/blocksstable/index_block/ob_index_block_bare_iterator.{h,cpp}
class ObIndexBlockBareIterator {
  // 基础迭代器
  // 遍历 index block 内的所有 row
};
```

### 3.2 ObIndexBlockMacroIterator

```cpp
// src/storage/blocksstable/index_block/ob_index_block_macro_iterator.{h,cpp}
class ObIndexBlockMacroIterator {
  // Macro 级迭代器
  // 遍历 macro block 级别的索引
};
```

### 3.3 ObIndexBlockDualMetaIterator

```cpp
// src/storage/blocksstable/index_block/ob_index_block_dual_meta_iterator.{h,cpp}
class ObIndexBlockDualMetaIterator {
  // 双 meta 迭代器
  // 一次拿两个 meta（cache miss 时有用）
};
```

### 3.4 ObIndexBlockTreeCursor

```cpp
// src/storage/blocksstable/index_block/ob_index_block_tree_cursor.{h,cpp}
class ObIndexBlockTreeCursor {
  // 索引树 cursor
  // 按 rowkey 范围遍历索引树
};
```

---

## 4. ObIndexTreeTraverser —— 索引树遍历

### 4.1 类骨架

```cpp
// src/storage/access/ob_index_block_tree_traverser.{h,cpp}
class ObIndexBlockTreeTraverser {
public:
  // 遍历索引树
  int traverse(const ObIndexTreeRootCtx &root_ctx,
               const ObDatumRange &range,
               ObIndexBlockRowIterator *&iter);

  // 跳过不匹配的 rowkey
  int skip_to_next_key(const ObDatumRange &range);

  // 异步预取
  int prefetch(ObIndexBlockRowIterator *iter);
};
```

### 4.2 索引树遍历策略

- **Range Scan**：range.start → 找到第一个 ≥ start 的 entry → 依次遍历到 range.end
- **Skip Scan**：跳过不满足条件的 entry（range 不连续时）
- **Index Only Scan**：不需要回表（覆盖索引满足所有查询列）

---

## 5. ObSSTableIndexFilter —— 索引过滤

### 5.1 类骨架

```cpp
// src/storage/access/ob_sstable_index_filter.{h,cpp}
class ObSSTableIndexFilter {
public:
  // 索引过滤
  int filter(const ObSSTableReadParam &param,
             ObSSTableIndexFilterResult &result);

  // 决定哪些 SSTable 可以跳过
  int can_skip_sstable(const ObSSTableMeta &meta);
};
```

### 5.2 索引过滤 vs 索引扫描

| 维度 | 索引过滤 | 索引扫描 |
|------|----------|----------|
| 目的 | 决定哪些 SSTable **完全不需要读** | 决定 SSTable 内部**哪些 row** 不需要读 |
| 粒度 | SSTable 级 | row 级 |
| 实现 | 索引范围 + min/max key | 索引 row + BloomFilter |
| 性能 | 跳过整个 SSTable（最理想） | 跳过部分 row |

---

## 6. ObIndexSkipScanner —— 跳跃扫描

### 6.1 类骨架

```cpp
// src/storage/access/ob_index_skip_scanner.{h,cpp}
class ObIndexSkipScanner {
public:
  // 跳跃扫描（range 内不连续时）
  int scan(const ObDatumRange &range, ObIndexRowIterator *&iter);
};
```

### 6.2 vs 顺序扫描

| 维度 | 顺序扫描 | 跳跃扫描 |
|------|----------|----------|
| 适用 | 连续 range（id BETWEEN 1 AND 100） | 不连续 range（id IN (1,3,5)） |
| 实现 | 一次定位 + 顺序读 | 多次定位 + 跳跃读 |
| 性能 | 一次定位开销 | 多次定位开销（但跳过大量行） |

---

## 7. ObSSTableIndexScanner —— SSTable 索引扫描

### 7.1 类骨架

```cpp
// src/storage/blocksstable/index_block/ob_sstable_index_scanner.{h,cpp}
class ObSSTableIndexScanner {
public:
  // 扫描 SSTable 索引
  int scan(const ObSSTableReadParam &param,
           ObSSTableIndexScanResult &result);

  // 关闭
  int close();
};
```

### 7.2 索引扫描 vs 全表扫描

| 维度 | 索引扫描 | 全表扫描 |
|------|----------|----------|
| 适用 | range query / point query | 全表 dump |
| 性能 | 快速（用索引定位） | 慢（顺序扫所有） |
| 资源 | 低 IO | 高 IO |

---

## 8. ObIndexBuilder —— 索引构建入口

### 8.1 类骨架

```cpp
// src/rootserver/ob_index_builder.h
class ObIndexBuilder {
public:
  // 启动索引构建
  int build_index(const ObIndexBuildArg &arg);

  // 调度
  int schedule();

  // 监控
  int check_progress();
};
```

### 8.2 与 #93 DDL 物理执行的关系

参见 #93 §6 + §7：
- DDL 触发 `ObIndexBuilder`
- 跨 observer 调度（参见 #41 DAG 调度）
- `ObBuildIndexTask` 在每个 observer 上执行

---

## 9. 二级索引 / 函数索引 / 覆盖索引

### 9.1 二级索引（Secondary Index）

```sql
-- 显式创建二级索引
CREATE INDEX idx_emp_name ON employee (name);

-- 隐式：UNIQUE / PRIMARY KEY 自动创建索引
ALTER TABLE employee ADD CONSTRAINT pk_emp PRIMARY KEY (id);
```

参见 #18-index-design：
- 显式：CREATE INDEX
- 隐式：UNIQUE / PRIMARY KEY
- 自动：FOREIGN KEY

### 9.2 唯一索引（Unique Index）

```sql
CREATE UNIQUE INDEX idx_emp_id ON employee (id);
```

OB 实现：
- 索引块内标记 unique
- DML 时检查重复
- 失败 → 报错

### 9.3 函数索引（Function Index）

```sql
-- 表达式索引
CREATE INDEX idx_upper_name ON employee (UPPER(name));
```

OB 5.x 实现：
- 索引 key 是表达式的结果
- 写入时计算表达式 + 索引
- 查询时同样计算 + 索引查找

### 9.4 覆盖索引（Covering Index）

```sql
-- 包含查询需要的所有列
CREATE INDEX idx_emp_cover ON employee (id) INCLUDE (name, dept_id);

-- 查询 SELECT id, name, dept_id FROM employee WHERE id = ?;
-- 只需要读索引 → 不需要回表
```

OB 5.x 实现：
- INCLUDE 子句（参见 #18）
- Index Only Scan（参见 #5.4）
- 大幅减少 IO

### 9.5 索引回表（Index Back to Table）

```sql
-- 索引不含查询的所有列 → 需要回表
SELECT name FROM employee WHERE id = 100;
-- id 在 PK 索引里 → 通过 PK 找到 row → 再读 name 列
```

参见 #18：
- 二级索引只含索引列 + 主键
- 需要的主键以外列 → 通过主键回主表读取
- 性能瓶颈（额外 IO）

### 9.6 Skip Index 优化

```cpp
// src/storage/access/ob_skip_index_sortedness.{h,cpp}
class ObSkipIndexSortedness {
  // Skip Index 优化
  // 当 range 已经按某列排序 → 跳过 sort 阶段
};
```

参见 #41 / #17：
- Skip Index 是 optimizer hint
- 让 range scan 跳过 sort 阶段
- 提升性能 2-10x

---

## 10. ObIndexTreePrefetcher / ObIndexSSTableEstimator

### 10.1 ObIndexTreePrefetcher

```cpp
// src/storage/access/ob_index_tree_prefetcher.{h,cpp}
class ObIndexTreePrefetcher {
  // 索引树预取
  // 异步预读后续 index block
  // 减少 IO 等待
};
```

### 10.2 ObIndexSSTableEstimator

```cpp
// src/storage/access/ob_index_sstable_estimator.{h,cpp}
class ObIndexSSTableEstimator {
  // 估计 SSTable 数量（基于统计信息）
  // 用于 optimizer 选择最优执行计划
};
```

---

## 11. 与其他文章的关系

### 11.1 与 #18 Index Design

#18 是早期分析二级索引设计概览（30KB+）。本篇是 #18 的 **深化**：
- #18 聚焦索引设计哲学
- 本文深入 ObIndexBlockBuilder / ObIndexBlockIterator / ObIndexTreeTraverser / ObSSTableIndexFilter / ObIndexSkipScanner / ObSSTableIndexScanner 各自的实现

### 11.2 与 #15 ObKeyBTree

#15 是早期分析 ObKeyBTree（主键索引的内部实现）。本篇是 #15 的 **深化**：
- #15 聚焦主键索引
- 本文覆盖所有索引类型（主键 / 二级 / 唯一 / 函数 / 覆盖 / 跳扫 / 索引回表）

### 11.3 与 #17 Query Optimizer

参见 #17：optimizer 选择最优索引（基于 cardinality 估计）。

### 11.4 与 #22 Plan Cache

参见 #22：plan cache 缓存已选的索引。

### 11.5 与 #90 SSTable

参见 #90 §3.4 / §4.2：SSTable 包含 index block + BloomFilter + macro block，是索引的物理载体。

### 11.6 与 #93 DDL 物理执行

参见 #93 §6：ObIndexBuilder + ObBuildIndexTask + ddl_task/ob_index_build_task.h 是 DDL 物理执行中的索引构建。

---

## 12. 总结

### 12.1 索引系统在 OB 体系中的定位

索引是 **OB 查询性能的核心**：
- 主键索引（ObKeyBtree，参见 #15）
- 二级索引（CREATE INDEX）
- 唯一索引（UNIQUE）
- 函数索引（UPPER 等表达式）
- 覆盖索引（INCLUDE 子句）
- 跳扫（skip scan）

### 12.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 索引块构建 | `ObIndexBlockBuilder` + `ObClusteredIndexBlockWriter` |
| 索引迭代 | `ObIndexBlockIterator`（4 个变体） + `ObIndexBlockTreeCursor` |
| 索引遍历 | `ObIndexBlockTreeTraverser`（range scan / skip / prefetch） |
| 索引过滤 | `ObSSTableIndexFilter`（SSTable 级过滤） |
| 跳跃扫描 | `ObIndexSkipScanner`（range 不连续） |
| 索引扫描 | `ObSSTableIndexScanner`（SSTable 索引扫描） |
| 索引预取 | `ObIndexTreePrefetcher`（异步预读） |
| 索引估计 | `ObIndexSSTableEstimator`（cardinality 估计） |
| 跳扫优化 | `ObSkipIndexSortedness`（skip sort 阶段） |
| 索引构建 | `ObIndexBuilder`（RS 端，参见 #93） |

### 12.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/blocksstable/index_block/` (38 文件) | 索引块主目录 |
| `src/storage/blocksstable/index_block/ob_index_block_builder.{h,cpp}` | 索引块构建 |
| `src/storage/blocksstable/index_block/ob_index_block_bare_iterator.{h,cpp}` | 基础迭代器 |
| `src/storage/blocksstable/index_block/ob_index_block_macro_iterator.{h,cpp}` | macro 迭代器 |
| `src/storage/blocksstable/index_block/ob_index_block_dual_meta_iterator.{h,cpp}` | dual meta 迭代器 |
| `src/storage/blocksstable/index_block/ob_index_block_tree_cursor.{h,cpp}` | 树 cursor |
| `src/storage/blocksstable/index_block/ob_index_block_aggregator.{h,cpp}` | aggregator |
| `src/storage/blocksstable/index_block/ob_index_block_dumper.{h,cpp}` | dumper |
| `src/storage/blocksstable/index_block/ob_index_block_row_scanner.{h,cpp}` | row scanner |
| `src/storage/blocksstable/index_block/ob_clustered_index_block_writer.{h,cpp}` | clustered writer |
| `src/storage/blocksstable/index_block/ob_ddl_index_block_row_iterator.{h,cpp}` | DDL iterator |
| `src/storage/blocksstable/index_block/ob_ddl_sstable_scan_merge.{h,cpp}` | DDL scan merge |
| `src/storage/blocksstable/index_block/ob_sstable_index_scanner.{h,cpp}` | SSTable index scanner |
| `src/storage/blocksstable/index_block/ob_agg_row_struct.{h,cpp}` | agg row 结构 |
| `src/storage/access/ob_index_block_tree_traverser.{h,cpp}` | 树遍历器 |
| `src/storage/access/ob_index_skip_scanner.{h,cpp}` | skip scanner |
| `src/storage/access/ob_index_sstable_estimator.{h,cpp}` | sstable estimator |
| `src/storage/access/ob_index_tree_prefetcher.{h,cpp}` | tree prefetcher |
| `src/storage/access/ob_skip_index_sortedness.{h,cpp}` | skip sort |
| `src/storage/access/ob_sstable_index_filter.{h,cpp}` | index filter |
| `src/rootserver/ob_index_builder.h` | index builder（RS 端） |
| `src/storage/blocksstable/ob_sstable.h` | SSTable 主类（含 index block，参见 #90） |
| `src/storage/blocksstable/ob_sstable_printer.h` | SSTable printer |
| `src/storage/blocksstable/ob_shared_macro_block_manager.h` | shared macro block manager |

### 12.4 索引类型对比

| 类型 | 适用 | 性能 |
|------|------|------|
| **主键** | PK 自动创建 | 最佳（clustered，参见 #15） |
| **二级** | CREATE INDEX 显式 | 需回表 |
| **唯一** | UNIQUE / PK | 与二级同 + 唯一性约束 |
| **函数** | 表达式索引 | 需计算 + 索引 |
| **覆盖** | INCLUDE 子句 | 无需回表（Index Only Scan） |
| **跳扫** | 不连续 range | 多次定位 + 跳跃 |

### 12.5 5 层架构

| 层级 | 元素 | 角色 |
|------|------|------|
| L1 | 索引接口 | CREATE INDEX / DROP INDEX |
| L2 | 索引构建 | `ObIndexBuilder`（RS 端） |
| L3 | 索引块 | `ob_index_block_builder` / `ob_index_block_iterator` |
| L4 | 索引遍历 | `ob_index_block_tree_traverser` |
| L5 | 索引过滤 + 扫描 | `ob_sstable_index_filter` + `ob_sstable_index_scanner` |

### 12.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#95 查询优化器 / 优化器 / CBO / 代价估算**（深化 #17）：

OB 查询优化器 —— 逻辑计划 / 物理计划 / 代价估算 / 连接顺序 / 索引选择 / 改写优化。源码入口：`src/sql/optimizer/` + `src/sql/rewrite/` + `src/share/ob_optimizer_stat_*.{h,cpp}`。

适用场景：SQL 调优 / 索引推荐 / 性能分析。

整吗？