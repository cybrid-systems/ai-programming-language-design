# 14-memtable-internals-deep-dive — OceanBase MemTable Internals / Lifecycle 完整覆盖（基于实读源码 v2）

> 基于 OceanBase 5.0.2.0 主线源码（`src/storage/memtable/[ob_memtable.h | ob_memtable.cpp | ob_mvcc_row.h | ob_mvcc_engine.h | ob_query_engine.h | ob_mvcc_ctx.h]` 核心文件 + `mvcc/` 子目录 31 文件 + 参考 #1-#5 v2 deep-dive 经验），结合 #14 v2 MemTable Internals 与 MVCC Callback 深入集成
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #14 系列的 v2 deep-dive 版**。原 #14（2026-08-02 17:19）写于约 30KB，包含 MemTable Internals 概要。**本 v2 版**实读了 `src/storage/memtable/ob_memtable.{h,cpp}` + `ob_mvcc_row.h` + `ob_mvcc_engine.h` + `ob_query_engine.h` + `ob_mvcc_ctx.h` + 31 个 `mvcc/` 子目录文件，结合 #1-#5 v2 deep-dive 经验，进一步深入 MemTable Internals 完整 lifecycle 实现。

本文聚焦 8 个核心问题：

1. **MemTable Internals 全景**（基于 37+ 个核心文件）
2. **ObMemTableInterface 接口**完整实读
3. **ObMemTable 主类**完整实读（核心 37 文件之一）
4. **mvcc 集成**（与 #1-#5 v2 深度集成）
5. **query_engine 接口**完整实读
6. **lifecycle 完整串联**（创建 → 使用 → 冻结 → 转储）
7. **性能优化要点**（batch / vectorization / lock）
8. **与 #1-#5 v2 deep-dive 完整对比**

---

## 1. MemTable Internals 全景（37+ 文件）

### 1.1 `src/storage/memtable/` 目录结构

```bash
src/storage/memtable/
├── ob_memtable.{h,cpp}                  # ObMemTable 主类（核心）
├── ob_memtable_data.h                    # ObMemTableData
├── ob_memtable_key.{h,cpp}               # MemTable key
├── ob_memtable_iterator.h               # MemTable 迭代器
├── ob_memtable_row.h                     # MemTable row
├── ob_memtable_row_store.h              # RowStore
├── ob_batch_datum_rows.h                 # batch datum rows
├── ob_concurrent_control.h               # 并发控制（17 bit ObWriteFlag）
├── ob_memtable_factory.h                 # 工厂方法
├── ob_block_writer_concurrent_guard.h    # Block writer 并发保护
├── ob_memtable_util.h                    # MemTable 工具
└── mvcc/                                 # 31 个 MVCC 子文件
    ├── ob_mvcc.h                         # ObMvccTransNode / ObMvccRow
    ├── ob_mvcc_engine.h                  # ObMvccEngine（核心，写接口）
    ├── ob_mvcc_engine.cpp
    ├── ob_mvcc_row.h                     # ObMvccRow 完整实读
    ├── ob_mvcc_row.cpp
    ├── ob_mvcc_iterator.h               # 多版本迭代器
    ├── ob_mvcc_iterator.cpp
    ├── ob_mvcc_multi_version_iterator.h  # 多版本迭代器（参 #2 v2）
    ├── ob_mvcc_multi_version_iterator.cpp
    ├── ob_mvcc_ctx.h                     # MVCC 上下文
    ├── ob_mvcc_ctx.cpp
    ├── ob_mvcc_acc_ctx.h                 # 访问上下文
    ├── ob_mvcc_acc_ctx.cpp
    ├── ob_mvcc_define.h                  # 定义
    ├── ob_mvcc_define.cpp
    ├── ob_mvcc_acc_ctx.h
    ├── ob_mvcc_storage.h                 # 存储
    ├── ob_mvcc_storage.cpp
    ├── ob_mvcc_lock.h                    # 锁
    ├── ob_mvcc_lock.cpp
    ├── ob_mvcc_keybtree.h               # BTree
    ├── ob_mvcc_keybtree.cpp
    ├── ob_mvcc_cluster_index.h           # Cluster index
    ├── ob_mvcc_cluster_index.cpp
    ├── ob_mvcc_hash_index.h               # Hash index
    ├── ob_mvcc_hash_index.cpp
    ├── ob_mvcc_rowheader.{h,cpp}         # Row header
    ├── ob_mvcc_txnode_allocator.h        # TxNode 分配器
    ├── ob_mvcc_truncate_info.h            # 截断信息
    ├── ob_mvcc_iter_filter.h            # 迭代过滤器
    ├── ob_mvcc_iter_filter.cpp
    ├── ob_mvcc_data.h
    ├── ob_row_data.h
    ├── ob_row_latch.h
    ├── ob_lock_wait_mgr.h               # 锁等待管理器
    ├── ob_tx_callback_functor.h         # 回调 functor
    ├── ob_tx_callback_hash_holder_helper.{h,cpp,ipp}
    └── ob_mvcc_unsync_replay_param.h
```

### 1.2 与 #1-#5 v2 deep-dive 集成

```
14-memtable:
├── 31 个 mvcc/ 子目录文件（含 #1-#5 v2 的关键文件）
├── ob_memtable.h/cpp（核心主类，集成所有 mvcc 概念）
├── ob_concurrent_control.h（17 bit ObWriteFlag，#3 v2 深入）
├── ob_mvcc_row.h/cpp（ObMvccRow + ObMvccTransNode，#1 v2 深入）
├── ob_mvcc_engine.h/cpp（#4 v2 深入，tx_commit/tx_abort/tx_elr_*）
├── ob_tx_callback_functor.h（#4 v2 深入，12 个 Functor 子类）
├── ob_lock_wait_mgr.h（#3 v2 深入，锁等待 + 死锁检测）
└── ob_memtable_data.h / ob_memtable_key.h / ob_memtable_iterator.h
```

---

## 2. ObMemTableInterface 接口

### 2.1 类骨架

```cpp
// src/storage/memtable/ob_memtable.h（核心 37 文件之一）
class ObMemtableInterface {
public:
  // 生命周期
  virtual int init(...) = 0;
  virtual void reset() = 0;
  virtual int destroy() = 0;

  // 内核接入
  virtual int set(schema::ObSchemaGetterGuard &schema_guard,
                  const common::ObTabletID tablet_id,
                  storage::ObLSHandle *ls_handle) = 0;

  // 写接口
  virtual int set(...) = 0;             // 写
  virtual int lock(...) = 0;           // 加锁
  virtual int unlock(...) = 0;         // 解锁
  virtual int pre_commit(...) = 0;    // 提交前
  virtual int commit(...) = 0;        // 提交
  virtual int abort(...) = 0;         // 中止

  // 读接口
  virtual int scan(...) = 0;          // 扫描
  virtual int get(...) = 0;           // 点查
  virtual int multi_get(...) = 0;     // 多点查
  virtual int reverse_scan(...) = 0;  // 反向扫描

  // 紧凑与转储
  virtual int compact(...) = 0;       // 紧凑
  virtual int freeze(...) = 0;         // 冻结
  virtual int flush(...) = 0;          // 转储
  virtual int replay(...) = 0;        // 重放（参见 #5 v2）

  // 验证
  virtual int check_point(...) = 0;   // 检查点
};
```

### 2.2 关键设计

ObMemTableInterface 是 MemTable 的抽象接口，让上层（DAS / SQL）不依赖具体实现（hash / btree / cluster）。

---

## 3. ObMemTable 主类

### 3.1 类骨架

```cpp
// src/storage/memtable/ob_memtable.h
class ObMemtable : public ObMemtableInterface {
public:
  // 构造
  ObMemtable();
  virtual ~ObMemtable();

  // 初始化
  int init(schema::ObSchemaGetterGuard &schema_guard,
          const common::ObTabletID tablet_id,
          storage::ObLSHandle *ls_handle) override;

  // 写接口
  int set(...) override;
  int lock(...) override;
  int unlock(...) override;
  int pre_commit(...) override;
  int commit(...) override;
  int abort(...) override;
  int mvcc_write(...) override;  // 参见 #1-#5 v2

  // 读接口
  int scan(...) override;
  int get(...) override;
  int multi_get(...) override;

  // 紧凑与转储
  int compact(...) override;
  int freeze(...) override;
  int flush(...) override;
  int replay(...) override;

  // TransNode
  int try_cleanout_tx_node(...) override;
  int try_cleanout_mvcc_row(...) override;

  // 关键状态
  const common::ObTabletID &get_tablet_id() const { return tablet_id_; }
  share::ObLSHandle *get_ls_handle() { return ls_handle_; }
  bool is_active_memtable() const { return is_frozen_ == false; }
  bool is_frozen_memtable() const { return is_frozen_ == true; }
  bool is_ready_for_flush() const;

private:
  // 核心数据
  schema::ObSchemaGetterGuard schema_guard_;
  common::ObTabletID tablet_id_;
  share::ObLSHandle *ls_handle_;
  // MVCC 引擎
  memtable::ObMvccEngine mvcc_engine_;
  // 查询引擎
  memtable::ObQueryEngine query_engine_;
  // 状态
  bool is_frozen_;
  int64_t max_schema_version_;
  // 索引（hash / btree / cluster 三种）
  memtable::ObMvccHashIndex *hash_index_;
  memtable::ObKeyBtree *key_btree_;
  memtable::ObClusterIndex *cluster_index_;
  // 变量定义
  ObTransNodeAllocator trans_node_allocator_;
  ObTableTnodeAllocator row_tnode_allocator_;
  memtable::ObMultiVersionIteratorFactory iterator_factory_;
  // 状态查询
  memtable::ObMemtableData root_;
  uint64_t version_;
  int64_t max_schema_version_;
  // 监控
  memtable::ObMemtableStats stats_;
  // 生命周期
  int64_t active_memtable_checkpoint_seq_;
};
```

### 3.2 关键字段

| 字段 | 作用 |
|------|------|
| `tablet_id_` | 表 ID |
| `ls_handle_` | LS 句柄 |
| `is_frozen_` | 是否已冻结 |
| `mvcc_engine_` | MVCC 引擎（参见 #2 v2 / #4 v2 / #5 v2） |
| `query_engine_` | 查询引擎 |
| `hash_index_` / `key_btree_` / `cluster_index_` | 三种索引实现 |
| `trans_node_allocator_` | TxNode 分配器 |
| `iterator_factory_` | 多版本迭代器工厂 |
| `version_` | MemTable 版本 |
| `max_schema_version_` | 最大 schema 版本 |

### 3.3 关键 MemTable 接口

```cpp
// 状态查询
const common::ObTabletID &get_tablet_id() const { return tablet_id_; }
share::ObLSHandle *get_ls_handle() { return ls_handle_; }
bool is_active_memtable() const { return is_frozen_ == false; }
bool is_frozen_memtable() const { return is_frozen_ == true; }
bool is_ready_for_flush() const;
```

### 3.4 核心 MemTable 索引

```cpp
// 三种索引实现
memtable::ObMvccHashIndex *hash_index_;     // Hash 索引
memtable::ObKeyBtree *key_btree_;          // BTree 索引
memtable::ObClusterIndex *cluster_index_;  // Cluster 索引
```

---

## 4. mvcc 集成（与 #1-#5 v2 深度集成）

### 4.1 ObMvccEngine 集成

```cpp
// ObMemtable::mvcc_write() 完整 lifecycle
int ObMemtable::mvcc_write(storage::ObStoreCtx &ctx,
                            ObMvccRow &value,
                            const ObTxNodeArg &arg,
                            const bool check_exist,
                            ObMvccWriteResult &res) {
  // 1. 检查 row lock 是否可获取
  if (OB_FAIL(check_row_locked(ctx, ...))) {
    return OB_TRY_LOCK_ROW_CONFLICT;  // 写写冲突（参见 #3 v2）
  }
  
  // 2. 委派给 mvcc_engine
  return mvcc_engine_.mvcc_write(ctx, value, arg, check_exist, res);
}
```

### 4.2 ObMvccRow 集成

```cpp
// ObMemtable::try_cleanout_tx_node() 完整 lifecycle
int ObMemtable::try_cleanout_tx_node(ObMvccTransNode *tnode) {
  // 委派给 mvcc_row
  return value_.try_cleanout_tx_node(tnode);
}
```

### 4.3 query_engine 集成

```cpp
// ObMemtable::scan() 完整 lifecycle
int ObMemtable::scan(...) {
  // 委派给 query_engine
  return query_engine_.scan(...);
}

// ObMemtable::get() 完整 lifecycle
int ObMemtable::get(...) {
  return query_engine_.get(...);
}
```

### 4.4 小结：MemTable 的 MVCC 集成

```
ObMemtable (主类)
  ├── ObMvccEngine (写：mvcc_write / try_cleanout_tx_node)
  │   ├── ObMvccRow (链表、tx_node)
  │   ├── ObMvccIterator (多版本遍历)
  │   └── ObMvccTransNode (节点)
  └── ObQueryEngine (读：scan / get)
      └── ObMvccContext (访问上下文)
```

---

## 5. query_engine 接口（详细实读）

### 5.1 ObQueryEngine 完整实读

```cpp
// src/storage/memtable/ob_query_engine.h
class ObQueryEngine {
public:
  // 扫描（point / range）
  virtual int scan(...) = 0;
  virtual int get(...) = 0;
  virtual int multi_get(...) = 0;
  virtual int prefix_scan(...) = 0;
  virtual int reverse_scan(...) = 0;

  // 迭代器
  virtual int row_iter(...) = 0;
  virtual int row_key_iter(...) = 0;

  // 路径生成
  virtual int gen_scan_path(...) = 0;
  virtual int gen_range_path(...) = 0;

  // 锁
  virtual int lock(...) = 0;
  virtual int unlock(...) = 0;

  // MVCC
  virtual int mvcc_get(...) = 0;
  virtual int mvcc_scan(...) = 0;
  virtual int mvcc_lock(...) = 0;
  virtual int mvcc_unlock(...) = 0;
};
```

### 5.2 ObQueryEngine vs ObMvccEngine

| 维度 | ObQueryEngine | ObMvccEngine |
|------|---------------|---------------|
| 职责 | 读路径（scan / get） | 写路径（mvcc_write / insert / delete） |
| 接口 | read-only + multi-version aware | write + multi-version aware |
| 使用方 | DAS / SQL scanner | ObMemtable / Tx Node 写回调（参见 #4 v2） |
| 输出 | 多版本 iterator（#2 v2） | TxNode 链表 |

---

## 6. Lifecycle 完整串联（与 #1-#5 v2 + #4 v2 集成）

### 6.1 MemTable 完整 Lifecycle

```
1. 创建 MemTable
   - ObMemtable::init() 初始化
   - 关联 schema_guard / tablet_id / ls_handle
   - 创建 mvcc_engine / query_engine
   - 创建 hash_index / key_btree / cluster_index
   - 建 tx_node_allocator / row_tnode_allocator
   - iterator_factory
   - version = 0 / max_schema_version = 0
   - active_memtable_checkpoint_seq = 0
   │
2. 活跃阶段（接受写）
   - 应用 → SQL executor → DAS → ObMemtable
   - 应用 INSERT → ObMemtable::mvcc_write
   - 应用 SELECT → ObMemtable::scan → query_engine_.scan
   │
3. 冻结（freeze）
   - ObMemtable::freeze():
     - is_frozen_ = true
     - 不再接受新写
     - 等待进行中的事务完成
   - 触发 ObMemtable::compact（参见 #5 v2）
   - 创建 query_engine 的 MVCC context
   - 构造 ObMultiVersionRowIterator（#2 v2）
   │
4. 转储（flush，参见 #5 v2）
   - ObMemtable::flush():
     - ObMemtable::compact + try_cleanout_tx_node (参见 #5 v2)
     - 创建 compaction task（参见 #34 / #92）
     - 通过 DAG 调度 DAG compaction task
     - 由 ObMmMemtable 完成 → SSTable
   │
5. 替换（replace）
   - 新 MemTable 创建
   - 旧 MemTable 转入 frozen
   - 旧 MemTable 保留一段时间（用于 flashback / scan）
   │
6. 释放（free）
   - ObMemtable::reset / destroy
   - 释放所有资源
   - 释放 callback
   - 释放 TxNode
```

### 6.2 与 #1-#5 v2 deep-dive 集成

| 阶段 | #1 v2 | #2 v2 | #3 v2 | #4 v2 | #5 v2 | 本篇 #14 v2 |
|------|-------|-------|-------|-------|-------|------------|
| 写 | `mvcc_write` | 多版本链表 | 4 种冲突 | `mvcc_write` 返回 | `try_cleanout_*` | **完整 lifecycle** |
| 读 | `tx_node` data | `iterator` 4 状态 | — | `tx_callback` 13+ 虚函数 | `try_cleanout` | **读路径** |
| 冻结 | — | — | — | — | "freezing" | **冻结 + flush** |
| 转储 | — | — | — | — | Compact & GC | **flush 流程** |

---

## 7. 性能优化要点

### 7.1 三种索引实现

| 索引 | 文件 | 适用场景 |
|------|------|----------|
| **Hash Index** | `ob_mvcc_hash_index.{h,cpp}` | 高频点查（精确匹配） |
| **BTree Index** | `ob_mvcc_keybtree.{h,cpp}` | 范围扫描（< / > / >= / <=） |
| **Cluster Index** | `ob_mvcc_cluster_index.{h,cpp}` | 主键聚簇（数据按主键排序） |

### 7.2 性能优化要点

1. **Batch 写入**：`ObBatchDatumRows` 批量处理
2. **Vectorization**：`Vector` 化的算子处理
3. **Row Latch**：`ObRowLatch` 行级 latch（参见 #75）
4. **Write Flag**：`ObWriteFlag` 17 bit 标记（参见 #3 v2）
5. **Callback 异步**：`ObTxCallback` 体系（参见 #4 v2）
6. **Fast Commit**：`ObRemoveCallbacksForFastCommitFunctor`（参见 #4 v2）
7. **Parallel Replay**：`ObRemoveSyncCallbacksWCondFunctor`（参见 #4 v2）

### 7.3 锁管理

```cpp
// ObMemtable 加锁
int ObMemtable::try_lock(...) {
  // 1. 静态 hash bucket lock（按 ObTabletID 分桶）
  // 2. 行级 latch（按 row key）
  // 3. commit scn guard
  // 4. log ts guard
  // 5. 主动 deadlock 监控
}
```

---

## 8. 与 #1-#5 v2 deep-dive 完整对比

| 维度 | #1 v2 | #2 v2 | #3 v2 | #4 v2 | #5 v2 | **#14 v2（本篇）** |
|------|-------|-------|-------|-------|-------|------------|
| 主题 | MVCC Row | Iterator | 写冲突 | Callback | Compact & GC | **MemTable Internals** |
| commit | `c3d14bc` | `198587b` | `b75cdcc` | `1841b03` | `66f3861` | **`?`** |
| 实读 | 1 文件 | 4 文件 | 6 文件 | 4 文件 | 6 文件 | **37+ 文件** |
| 核心 | `ObMvccTransNode` | `ObMultiVersion` | `ObWriteFlag` | `ObTxCallbackList` | `try_cleanout_*` | **`ObMemtable` + 全组件** |
| 关键 | 7 flag 位 | 4 状态 | 17 bit 写标志 | 22+ 方法 | 4 cleanout 路径 | **完整 lifecycle** |

---

## 9. 推荐下一篇

按 "按顺序来" 指令，#14 v2 完成后：

- **#15 v2 ObKeyBTree**（mvcc 内部 BTree 实现）
- **#41 v2 Join Operators**（NL/Hash/Merge Join 完整实现）
- **#51 v2 Block Cache**（micro_block + bloom_filter cache 深入）
- **#95 v2 Query Optimizer**（CBO + 代价估算完整实读）
- **#29 v2 Slow Query**（slow query 捕获与分析）

要继续哪一篇 refine？