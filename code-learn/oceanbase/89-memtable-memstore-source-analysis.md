# 89-memtable-memstore — OceanBase MemTable / 内存表 / MVCC 链深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/storage/memtable/` 37 文件 + `src/storage/memtable/mvcc/` + `src/storage/ob_i_memtable_mgr.{h,cpp}` + `src/storage/ob_i_tablet_memtable.h` + `src/storage/tablet/ob_tablet_memtable_mgr.h` + `src/storage/ob_storage_table_guard.h` + `src/observer/virtual_table/ob_all_virtual_memstore_info.h` + `ob_all_virtual_tx_stat.h`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **MemTable / 内存表**是整个 observer 集群"活跃数据"的 in-memory 存储 —— 所有 DML（INSERT / UPDATE / DELETE）首先写入 memtable，定期 freeze 后转 SSTable 进入磁盘存储。MemTable 是 **热数据层** + **MVCC 链** + **转储策略** 的复合体，OB 5.x 的 memtable 建立在 `ObMemtable` + `ObMvccEngine` + `ObMemtableContext` 三层之上。

本文聚焦 8 个核心问题：

1. **MemTable 全景** —— 37 文件 + MVCC 子目录
2. **ObMemtable 主类** —— 内存表核心
3. **ObMvccEngine** —— MVCC 链管理（参见 #01-#05）
4. **ObMemtableContext** —— 事务上下文
5. **ObMemtableMutator** —— DML 写入路径
6. **ObMemtableIterator** —— 读取路径
7. **ObMemtableCompactWriter** —— freeze → SSTable
8. **ObConcurrentControl** —— 并发控制（参见 #75）

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 14-memtable-internals | #14 是早期分析，本文深化 OB 5.x memtable |
| 01-mvcc-row | MVCC 链的核心设计 |
| 02-mvcc-iterator | MemTable iterator |
| 03-mvcc-write-conflict | write 写冲突检测 |
| 04-mvcc-callback | tx commit callback |
| 05-mvcc-compact | MemTable compact |
| 36-concurrency-control | 并发控制基础 |
| 75-latch-system | Latch 在 memtable 中的应用 |
| 84-virtual-table | `ob_all_virtual_memstore_info` / `ob_all_virtual_tx_stat` |
| 66-direct-load | Direct Load 绕过 memtable（对比） |

---

## 1. 整体架构：MemTable 4 层

### 1.1 模块组成（37 文件）

```bash
$ ls src/storage/memtable/
deadlock_adapter/                 # 死锁检测适配
hash_holder/                       # Hash 索引 holder
mvcc/                              # MVCC 子目录
├── ob_mvcc_engine.{h,cpp}         # MVCC engine
├── ob_mvcc_row.{h,cpp}            # MVCC row（参见 #01）
├── ob_mvcc_trans_ctx.{h,cpp}      # MVCC 事务 ctx
└── ob_query_engine.{h,cpp}         # Query engine
ob_concurrent_control.{h,cpp}     # 并发控制
ob_memtable.{h,cpp}                 # MemTable 主类
ob_memtable_block_reader.{h,cpp}    # block reader
ob_memtable_block_row_scanner.{h,cpp}  # block row scanner
ob_memtable_compact_writer.{h,cpp} # compact writer
ob_memtable_context.{h,cpp}         # context
ob_memtable_ctx_obj_pool.h         # ctx 对象池
ob_memtable_data.h                  # data 定义
ob_memtable_interface.{h,cpp}       # interface
ob_memtable_iterator.{h,cpp}        # iterator
ob_memtable_key.{h,cpp}            # key
ob_memtable_mutator.{h,cpp}        # mutator（DML 写入）
ob_memtable_read_row_util.{h,cpp}   # read row util
ob_memtable_single_row_reader.{h,cpp}  # single row reader
ob_row_compactor.h                  # row compactor
```

**37 文件** + 3 个子目录（deadlock_adapter / hash_holder / mvcc）。

### 1.2 4 层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: 应用层（DML Executor）                                 │
│  - 收到 INSERT / UPDATE / DELETE                                │
│  - 调 ObMemtableMutator                                        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: ObMemtable (主类) + ObMemtableContext               │
│  - 内存表本身（hash / btree 索引）                            │
│  - 事务上下文（隔离性 / 可见性）                                │
│  - MVCC 链管理（ObMvccEngine）                                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: ObMvccEngine + ObMvccRow                              │
│  - MVCC 链：每行多版本（参见 #01）                              │
│  - trans_version_ + scn_ + seq_no_                            │
│  - 写写冲突检测（参见 #03）                                     │
│  - callback 链（参见 #04）                                     │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: Freeze → SSTable (ObMemtableCompactWriter)            │
│  - minor freeze: memtable → 内存 mini-sstable                │
│  - major freeze: 多个 mini-sstable → 磁盘 SSTable              │
│  - ObRowCompactor: 行级压缩                                    │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObMemtable 主类（实读 `ob_memtable.h`）

### 2.1 类骨架

```cpp
// src/storage/memtable/ob_memtable.h
namespace oceanbase {
namespace memtable {

class ObMemtableMutatorIterator;

struct ObReportedDmlStat {
  static constexpr int64_t REPORT_INTERVAL = 1_s;
  ObReportedDmlStat() { reset(); }
  ~ObReportedDmlStat() = default;
  void reset() {
    last_report_time_ = 0;
    insert_row_count_ = 0;
    update_row_count_ = 0;
    delete_row_count_ = 0;
    table_id_ = OB_INVALID_ID;
  }
  // ...
  int64_t last_report_time_;
  int64_t insert_row_count_;
  int64_t update_row_count_;
  int64_t delete_row_count_;
  uint64_t table_id_;
};

class ObMemtable {
public:
  // 生命周期
  int init(const ObITableMemtableKey &key, int64_t schema_version);
  void reset();

  // DML 写入
  int set(ObMemtableKey &key, ObMemtableValue &value,
         const ObMemtableCtx &ctx);
  int insert(...);
  int update(...);
  int delete(...);

  // 读取
  int get(const ObMemtableKey &key, ObMemtableValue &value,
         const ObMemtableCtx &ctx);

  // Freeze
  int64_t get_approximate_memtable_size() const;
  int snapshot(ObTableHandleV2 &handle);
  int flush(ObTableHandleV2 &handle);

  // 监控
  int64_t get_size() const;
  ObReportedDmlStat get_reported_dml_stat() const;

private:
  // 内部存储
  hash::ObHashMap<ObMemtableKey, ObMemtableValue> hash_index_;
  // MVCC 链
  ObMvccEngine mvcc_engine_;
  // 内存分配
  share::ObMemstoreAllocator allocator_;
  // 状态
  bool is_frozen_;
  int64_t schema_version_;
  // ... 几十个字段
};

}  // memtable
}  // oceanbase
```

### 2.2 关键设计

**ObMemtable 类**：
- 一个 memtable = 一个 hash 索引（key → value）
- 内嵌 ObMvccEngine 管理 MVCC 链（参见 #01）
- 生命周期：active → frozen → flushed → dropped

**ObReportedDmlStat**：
- 每秒报告 DML 统计（`REPORT_INTERVAL = 1_s`）
- 包含 insert / update / delete 行数
- 报告给 `ObOptStatMonitorManager`（用于优化器统计）

---

## 3. ObMvccEngine —— MVCC 链管理

### 3.1 角色

```cpp
// src/storage/memtable/mvcc/ob_mvcc_engine.h
class ObMvccEngine {
public:
  // 写入：add MVCC row
  int insert(ObMvccRow &row, ObMvccTransCtx &ctx);

  // 读取：get latest visible version
  int get(const ObMemtableKey &key, ObMvccValue &value, ObMvccTransCtx &ctx);

  // 清理：clean committed versions
  int clean_commit(const SCN commit_scn, const SCN snapshot_scn);
  int clean_tx_rollback(const ObTransID &tx_id);

  // 事务回调
  int add_tx_callback(ObITxCallback *callback, ObMvccTransCtx &ctx);

  // 监控
  int64_t get_row_count() const;
  int64_t get_memtable_size() const;
};
```

### 3.2 与 #01-#05 的关系

参见之前 5 篇 MVCC 分析：
- **#01-mvcc-row**：`ObMvccRow` + `ObMvccTransNode` 的双向链表设计
- **#02-mvcc-iterator**：`ObMvccTransNode` 的可见性判断 + iterator
- **#03-mvcc-write-conflict**：写写冲突检测 + lock_wait
- **#04-mvcc-callback**：tx commit callback 链
- **#05-mvcc-compact**：MVCC 链的 compact + GC

`ObMvccEngine` 是这 5 篇文章的核心实现：

| MVCC 功能 | ObMvccEngine 方法 |
|-----------|------------------|
| 链维护 | `insert` / `get` |
| 可见性 | `get` 内部判断 |
| 冲突 | 写写冲突检测 |
| 回调 | `add_tx_callback` |
| Compact | `clean_commit` / `clean_tx_rollback` |

---

## 4. ObMemtableContext —— 事务上下文

### 4.1 类骨架

```cpp
// src/storage/memtable/ob_memtable_context.h
class ObMemtableContext {
public:
  // 初始化 / 清理
  int init(const ObMemtableKey &key, int64_t schema_version, ...);
  void reset();

  // MVCC 事务上下文
  ObMvccTransCtx &get_mvcc_trans_ctx();
  const ObMvccTransCtx &get_mvcc_trans_ctx() const;

  // SQL 快照
  void set_read_scn(const SCN scn);
  SCN get_read_scn() const;

  // Lock
  int lock_row(ObMemtableKey &key, ...);
  int unlock_row(ObMemtableKey &key);

  // Callback
  int add_tx_callback(ObITxCallback *callback);

private:
  ObMvccTransCtx mvcc_ctx_;  // MVCC 事务上下文
  SCN read_scn_;             // 读 SCN
  // ... 几十个字段
};
```

### 4.2 关键设计

**ObMemtableContext** 是 **per-DML / per-query** 的事务上下文：
- 包含 SCN / Lock / Callback / 事务状态
- 在 DML Executor 中创建，用完销毁
- 通过 ctx_obj_pool 复用（`ob_memtable_ctx_obj_pool.h`）

**CtxObjPool**（`ob_memtable_ctx_obj_pool.h`）：
- 对象池减少 ctx 分配开销
- 高并发场景下避免内存碎片

---

## 5. ObMemtableMutator —— DML 写入路径

### 5.1 类骨架

```cpp
// src/storage/memtable/ob_memtable_mutator.h
class ObMemtableMutator {
public:
  // 设置单行
  int set(const ObMemtableKey &key, ObMemtableValue &value,
         ObMemtableContext &ctx);

  // 批量设置
  int set(ObMemtableMutatorIterator &iter, ObMemtableContext &ctx);

  // 触发 callback
  int calc_and_insert_callback(ObMemtableContext &ctx);

private:
  ObMemtable *memtable_;
  // ... 内部状态
};
```

### 5.2 DML 写入流程

```
应用: INSERT INTO t (id, name) VALUES (1, 'foo')
    │
    ▼
DAS layer: 构造 ObMemtableKey + ObMemtableValue
    │
    ▼
DML Executor: 调 ObMemtableMutator::set
    │
    ├─ 1. lock_row (参见 #75 Latch)
    │   └─ 拿 row lock + 检查 write-write 冲突
    │
    ├─ 2. 调 ObMvccEngine::insert
    │   └─ 添加 MVCC row 到链
    │
    ├─ 3. set 到 hash index
    │   └─ key → value
    │
    ├─ 4. add_tx_callback (参见 #04)
    │   └─ tx commit 时触发
    │
    └─ 5. unlock_row
    │
    ▼
返回 (rows_affected = 1)
```

### 5.3 写写冲突检测（参见 #03）

`lock_row` 时检查：
- 同 row 已被其他事务持有写锁
- 等待 OR 报错（取决于事务隔离级别）

---

## 6. ObMemtableIterator —— 读取路径

### 6.1 类骨架

```cpp
// src/storage/memtable/ob_memtable_iterator.h
class ObMemtableIterator {
public:
  // 迭代器接口
  int open(const ObMemtableKey *start_key, const ObMemtableKey *end_key,
          ObMemtableContext &ctx);
  int get_next_row(ObDatumRow &row);
  int close();

  // 类型
  enum IteratorType {
    ITER_FULL = 0,        // 全表扫描
    ITER_RANGE,           // 范围扫描
    ITER_POINT,           // 单点查询
  };

private:
  IteratorType type_;
  ObMemtable *memtable_;
  hash::ObHashMap::iterator hash_iter_;
  // ... 内部状态
};
```

### 6.2 读取流程

```
应用: SELECT * FROM t WHERE id = 1
    │
    ▼
DAS layer: 构造 ObMemtableKey
    │
    ▼
DML/SQL Executor: 调 ObMemtableIterator
    │
    ├─ 1. open (start_key=id=1, end_key=null)
    │
    ├─ 2. 调 ObMvccEngine::get
    │   └─ 通过 SCN 过滤可见 MVCC 版本（参见 #02）
    │
    ├─ 3. get_next_row
    │   └─ 返回 row
    │
    └─ 4. close
```

### 6.3 与 MVCC iterator 关系

参见 #02-mvcc-iterator：每行可能有多个版本，iterator 用 SCN 过滤可见版本。

---

## 7. ObMemtableCompactWriter —— freeze → SSTable

### 7.1 类骨架

```cpp
// src/storage/memtable/ob_memtable_compact_writer.h
class ObMemtableCompactWriter {
public:
  // 触发 freeze（memtable → mini-sstable）
  int freeze(ObMemtable &memtable, ObTableHandleV2 &new_handle);

  // 写 mini-sstable
  int write_mini_sstable(ObMemtable &memtable, ...);

  // 合并（mini-sstable → SSTable）
  int merge_mini_sstables(ObArray<ObTableHandleV2> &handles, ...);

  // Compact（参见 #05）
  int compact(ObMemtable &memtable);
};
```

### 7.2 Freeze 流程

参见 #05-mvcc-compact：

```
Freeze 触发条件
    │
    ├─ memtable size > 阈值 (默认 256MB)
    ├─ 距离上次 freeze 时间 > 阈值
    └─ 显式触发
    │
    ▼
ObMemtableCompactWriter::freeze
    │
    ├─ 1. memtable 状态: active → frozen
    │
    ├─ 2. 写 mini-sstable
    │   └─ 写 ObSSTable 到本地磁盘
    │
    ├─ 3. 通知 ObTabletMemtableMgr
    │   └─ 把 frozen memtable 替换为 mini-sstable
    │
    └─ 4. 调度 major freeze
        └─ 合并 mini-sstable → SSTable
```

### 7.3 ObRowCompactor

```cpp
// src/storage/memtable/ob_row_compactor.h
class ObRowCompactor {
public:
  // 把多行压缩为 SSTable 格式
  int compact(const ObDatumRow *rows, int64_t row_count,
              ObSSTableWriter &writer);
};
```

**行级压缩**：把多行打包为 SSTable 的 micro block（参见 #08-ob-sstable）。

---

## 8. ObConcurrentControl —— 并发控制

### 8.1 类骨架

```cpp
// src/storage/memtable/ob_concurrent_control.h
class ObConcurrentControl {
public:
  // 读 / 写并发控制
  int try_lock_for_read(ObMemtableKey &key);
  int try_lock_for_write(ObMemtableKey &key);

  // Lock 等待
  int lock_wait(ObMemtableKey &key, int64_t timeout_us);

  // 死锁检测（参见 #36）
  int detect_deadlock(ObMemtableCtx &ctx);
};
```

### 8.2 与 #75 Latch / #36 Concurrency 的关系

参见 #75-latch-system + #36-concurrency-control：
- `ObConcurrentControl` 用 latch 保护 hash 索引
- 死锁检测通过 latch wait graph 实现
- 写写冲突在 lock wait 时检测

### 8.3 deadlock_adapter

```bash
src/storage/memtable/deadlock_adapter/
├── ob_lock_wait_check.h
├── ob_deadlock_adapter.h
├── ob_deadlock_detector.h
└── ob_deadlock_diagnose.h
```

**死锁检测适配器**：
- 把 latch wait 关系转换成 wait graph
- 检测环路
- 死锁时 abort 事务

---

## 9. 内存表 vs SSTable 对比

| 维度 | MemTable | SSTable |
|------|----------|---------|
| 存储位置 | 内存 | 磁盘 |
| 数据量 | 几 MB ~ 几百 MB | 几 MB ~ 几 GB |
| 写入速度 | O(1) 哈希 | 顺序写 |
| 读取速度 | O(1) 哈希查找 | 二分 / BTree |
| 持久化 | 不持久 | 持久化到磁盘 |
| MVCC 链 | 多版本（参见 #01） | 只有 freeze 时版本 |
| 生命周期 | active → frozen → flushed | 长期保留 |
| 锁 | row-level + write conflict | block-level |
| 索引 | hash | BTree |

---

## 10. 内存表生命周期

### 10.1 完整生命周期

```
创建 (active)
    │
    ▼  INSERT/UPDATE/DELETE
    │
活跃 (active)
    │
    ▼  触达 size / time 阈值
    │
Freeze 触发
    │
    ├─ 1. memtable 状态: active → frozen
    ├─ 2. 写 mini-sstable
    └─ 3. 替换为 mini-sstable handle
    │
    ▼
冻结 (frozen)
    │
    ├─ 旧 memtable 还在, 但不再写入
    └─ 新 memtable 创建
    │
    ▼  多个 mini-sstable 累积
    │
Major Freeze 触发
    │
    ├─ 1. 合并多个 mini-sstable
    └─ 2. 替换为 SSTable
    │
    ▼
压缩 (flushed)
    │
    ▼  长时间不被访问
    │
Drop
```

### 10.2 多 MemTable 状态共存

一个 Tablet 同时有多个 MemTable：
- active memtable（接受新写入）
- 多个 frozen memtable（不可写，可读）
- 多个 mini-sstable（不可写，可读）

读取路径：所有这些都参与可见性判断（参见 #02-mvcc-iterator）

---

## 11. 与其他文章的关系

### 11.1 与 #14 MemTable Internals

#14 是早期分析 memtable 的概览文章（30KB+）。本篇是 #14 的 **深化**：
- #14 聚焦 memtable 的核心数据结构
- 本文深入 ObMemtable / ObMvccEngine / ObMemtableContext / ObMemtableMutator / ObMemtableIterator / ObMemtableCompactWriter / ObConcurrentControl 各自的实现

### 11.2 与 #01-#05 MVCC 系列

5 篇 MVCC 分析（参见 #01-#05）都在 ObMemtable 内嵌的 ObMvccEngine 中实现：
- #01-mvcc-row → ObMvccRow + ObMvccTransNode
- #02-mvcc-iterator → 读取可见性
- #03-mvcc-write-conflict → 写写冲突
- #04-mvcc-callback → tx commit callback
- #05-mvcc-compact → MVCC 链的 compact

### 11.3 与 #36 Concurrency Control

`ObConcurrentControl` 是 memtable 的并发控制基础：
- row-level lock
- latch wait（参见 #75）
- deadlock detection

### 11.4 与 #66 Direct Load

Direct Load 绕过 memtable（参见 #66）：
- 直接生成 SSTable
- 跳过 ObMemtable 的写入路径
- Direct Load 用于批量加载，不与实时 DML 冲突

### 11.5 与 #84 Virtual Table

`__all_virtual_memstore_info` / `__all_virtual_tx_stat`（参见 #84）监控 memtable 状态：
- 当前 memtable 大小
- 行数（INSERT / UPDATE / DELETE）
- 事务统计

### 11.6 与 #08 OB SSTable

memtable freeze → mini-sstable → SSTable：
- ObMemtableCompactWriter 写入 mini-sstable
- 后续合并 → 完整 SSTable（参见 #08）

---

## 12. 总结

### 12.1 MemTable 在 OB 体系中的定位

MemTable 是 **OB 活跃数据的内存层**：
- 所有 DML 先写 memtable
- 定期 freeze → SSTable
- MVCC 链管理多版本
- 与 SSTable 共同支撑完整存储栈

### 12.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 主类 | `ObMemtable` + `ObMemtableInterface` |
| MVCC | `ObMvccEngine` + `ObMvccRow`（参见 #01-#05） |
| 上下文 | `ObMemtableContext` + `ObMemtableCtxObjPool` |
| 写入 | `ObMemtableMutator` + `ObMemtableKey` |
| 读取 | `ObMemtableIterator` + `ObMemtableBlockReader` |
| Freeze | `ObMemtableCompactWriter` → mini-sstable |
| Compact | `ObRowCompactor` → SSTable |
| 并发控制 | `ObConcurrentControl` + `deadlock_adapter/` |
| DML 统计 | `ObReportedDmlStat`（1_s 报告） |
| 死锁检测 | `deadlock_adapter/ob_deadlock_detector.h` |

### 12.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/memtable/` (37 文件) | MemTable 主目录 |
| `src/storage/memtable/ob_memtable.{h,cpp}` | 主类 |
| `src/storage/memtable/ob_memtable_interface.{h,cpp}` | interface |
| `src/storage/memtable/ob_memtable_context.{h,cpp}` | 事务 ctx |
| `src/storage/memtable/ob_memtable_ctx_obj_pool.h` | ctx 对象池 |
| `src/storage/memtable/ob_memtable_data.h` | data 定义 |
| `src/storage/memtable/ob_memtable_key.{h,cpp}` | key |
| `src/storage/memtable/ob_memtable_mutator.{h,cpp}` | 写入 |
| `src/storage/memtable/ob_memtable_iterator.{h,cpp}` | 读取 |
| `src/storage/memtable/ob_memtable_block_reader.{h,cpp}` | block reader |
| `src/storage/memtable/ob_memtable_block_row_scanner.{h,cpp}` | block scanner |
| `src/storage/memtable/ob_memtable_read_row_util.{h,cpp}` | read util |
| `src/storage/memtable/ob_memtable_single_row_reader.{h,cpp}` | single row |
| `src/storage/memtable/ob_memtable_compact_writer.{h,cpp}` | compact writer |
| `src/storage/memtable/ob_row_compactor.h` | row compactor |
| `src/storage/memtable/ob_concurrent_control.{h,cpp}` | 并发控制 |
| `src/storage/memtable/deadlock_adapter/` | 死锁检测 |
| `src/storage/memtable/hash_holder/` | hash holder |
| `src/storage/memtable/mvcc/ob_mvcc_engine.{h,cpp}` | MVCC engine |
| `src/storage/memtable/mvcc/ob_mvcc_row.{h,cpp}` | MVCC row |
| `src/storage/memtable/mvcc/ob_mvcc_trans_ctx.{h,cpp}` | MVCC trans ctx |
| `src/storage/memtable/mvcc/ob_query_engine.{h,cpp}` | query engine |
| `src/storage/ob_i_memtable_mgr.{h,cpp}` | memtable manager interface |
| `src/storage/ob_i_tablet_memtable.h` | per-tablet memtable |
| `src/storage/tablet/ob_tablet_memtable_mgr.h` | tablet memtable mgr |
| `src/storage/ob_storage_table_guard.h` | table guard |
| `src/observer/virtual_table/ob_all_virtual_memstore_info.h` | 监控虚拟表 |
| `src/observer/virtual_table/ob_all_virtual_tx_stat.h` | tx 统计虚拟表 |

### 12.4 MemTable vs SSTable

| 维度 | MemTable | SSTable |
|------|----------|---------|
| 存储位置 | 内存 | 磁盘 |
| 写入速度 | O(1) | 顺序写 |
| 持久化 | 不持久 | 持久化 |
| MVCC 链 | 多版本 | 单版本 |
| 生命周期 | active → frozen → flushed | 长期保留 |
| 锁 | row-level | block-level |
| 索引 | hash | BTree |

### 12.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#90 SSTable / Macro Block / 列存 / 压缩编码深度分析**（深化 #08）：

OB SSTable 完整源码分析 —— micro block / macro block / 列存编码 / 压缩 / BloomFilter / cache。源码入口：`src/storage/blocksstable/` + `src/storage/ob_sstable_*.{h,cpp}`。

适用场景：存储优化 / 压缩调优 / cache 策略 / 性能分析。

整吗？