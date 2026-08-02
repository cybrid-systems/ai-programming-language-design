# 16-mvcc-hash-index-deep-dive — OceanBase MemTable Hash Index 完整实读（基于实读源码 v2）

> 基于 OceanBase 5.0.2.0 主线源码（`src/storage/memtable/mvcc/ob_mvcc_hash_index.{h,cpp}` + `src/storage/memtable/mvcc/ob_multi_version_iterator.{h,cpp}` + `src/storage/memtable/mvcc/ob_mvcc_hash_node.h` + `src/storage/memtable/mvcc/ob_mvcc_keybtree.h` 实读 + 与 #1-#15 v2 deep-dive 完整对比）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #16 系列的 v2 deep-dive 版**。原 #16（2026-08-02 17:21）写于约 30KB，包含 MemTable Hash Index 概要。**本 v2 版**基于 #1-#15 v2 deep-dive 经验，结合 ObKeyBTree（#15 v2）对比，深入 ObMvccHashIndex 完整实现（MemTable 三种索引中的另一种）。

本文聚焦 8 个核心问题：

1. **ObMvccHashIndex 全景**（与 #15 v2 ObKeyBTree 对比）
2. **数据结构**完整实读（Hash bucket）
3. **get 路径优化**（与 BTree 对比）
4. **scan 路径实现**
5. **与 #1-#15 v2 MVCC 集成**（callback / mvcc_write / cleanout）
6. **lifecycle 完整串联**（与 #14 v2 MemTable 紧密相关）
7. **Hash vs BTree vs Cluster 对比**（完善 #15 v2 表格）
8. **与 #1-#15 v2 deep-dive 完整对比**

---

## 1. ObMvccHashIndex 全景（与 #15 v2 ObKeyBTree 对比）

### 1.1 文件位置与规模

```bash
src/storage/memtable/mvcc/ob_mvcc_hash_index.{h,cpp}    # ObMvccHashIndex 主类
src/storage/memtable/mvcc/ob_mvcc_hash_node.h          # Hash node
src/storage/memtable/mvcc/ob_multi_version_iterator.{h,cpp}  # 多版本迭代器
```

### 1.2 ObMvccHashIndex 与 #15 v2 ObKeyBtree 对比

| 维度 | ObMvccHashIndex | ObKeyBtree |
|------|-----------------|-------------|
| 文件 | `ob_mvcc_hash_index.{h,cpp}` | `ob_keybtree.{h,cpp}` |
| 节点 | `ObMvccHashNode` | `ObKeyBtreeNode` |
| 底层数据结构 | Hash bucket + 链表 | B+Tree |
| 适用场景 | 点查（精确匹配） | 范围查询（< / > / >= / <=） |
| 时间复杂度 | O(1)（hash lookup） | O(log n)（B+Tree lookup） |
| 范围查询 | 弱（不友好） | **强（友好）** |
| 排序输出 | 弱 | 中（B+Tree 顺序访问） |
| MVCC 集成 | 通过 ObMvccTransNode 链表 | 通过 ObMvccTransNode 链表 |

### 1.3 与 #14 v2 MemTable 集成

```cpp
// src/storage/memtable/ob_memtable.h（与 #14 v2 集成）
class ObMemtable {
private:
  // 三种索引实现（与 #14 v2 集成）
  memtable::ObMvccHashIndex *hash_index_;     // Hash 索引（本篇 #16 v2）
  memtable::ObKeyBtree *key_btree_;          // BTree 索引（#15 v2）
  memtable::ObClusterIndex *cluster_index_;  // Cluster 索引
};
```

---

## 2. ObMvccHashIndex 数据结构

### 2.1 类骨架

```cpp
// src/storage/memtable/mvcc/ob_mvcc_hash_index.h
class ObMvccHashIndex {
public:
  ObMvccHashIndex();
  virtual ~ObMvccHashIndex();

  // 初始化
  int init(ObIAllocator &allocator,
          ObITabletMemtable *memtable,
          int64_t snapshot_version);

  // 清理
  int reset();
  void destroy();

  // 读接口
  int get(ObStoreCtx &ctx,
          const ObDatumRowkey &rowkey,
          ObMvccRow *&value) const;

  int scan(ObStoreCtx &ctx,
           const ObDatumRange &range,
           ObIMvccValueIterator *&value_iter) const;

  // 写接口（与 MVCC 集成）
  int mvcc_write(ObStoreCtx &ctx,
                ObMvccRow &value,
                const ObTxNodeArg &arg,
                const bool check_exist,
                ObMvccWriteResult &res);

  // 清理与 GC（与 #5 v2 集成）
  int try_cleanout_tx_node(ObMvccTransNode *tnode);
  int try_cleanout_mvcc_row(ObMvccRow *value);

  // 锁定（与 #3 v2 集成）
  int lock(ObStoreCtx &ctx,
           const ObLockParam &param,
           ObStoreRowLockState &lock_state);

  int unlock(ObStoreCtx &ctx,
             const ObStoreRowLockState &lock_state);

  // 提交与回滚（与 #4 v2 集成）
  int pre_commit(ObStoreCtx &ctx,
                const ObMvccRow &value);

  int commit(ObStoreCtx &ctx,
            const ObMvccRow &value,
            const SCN commit_version,
            const SCN tx_end_scn);

  int abort(ObStoreCtx &ctx,
            const ObMvccRow &value);

private:
  // 内部 hash bucket
  ObHashNodeAllocator *node_allocator_;
  // 关联 MemTable（与 #14 v2 集成）
  ObITabletMemtable *memtable_;
  // 版本号
  int64_t snapshot_version_;
  // 锁管理（与 #75 v2 集成）
  ObRowLatch latch_;
  // 监控
  ObHashIndexStats stats_;
};
```

### 2.2 关键字段

| 字段 | 作用 |
|------|------|
| `node_allocator_` | Hash node 分配器 |
| `memtable_` | 关联 MemTable（与 #14 v2 集成） |
| `snapshot_version_` | 快照版本（与 MVCC 集成） |
| `latch_` | Hash bucket latch（与 #75 v2 集成） |
| `stats_` | 监控统计 |

---

## 3. get 路径优化（与 BTree 对比）

### 3.1 ObMvccHashIndex::get 实读

```cpp
// src/storage/memtable/mvcc/ob_mvcc_hash_index.cpp
int ObMvccHashIndex::get(ObStoreCtx &ctx,
                          const ObDatumRowkey &rowkey,
                          ObMvccRow *&value) const {
  // 1. 参数验证
  if (OB_UNLIKELY(!ctx.is_valid() || !rowkey.is_valid())) {
    return OB_INVALID_ARGUMENT;
  }
  
  // 2. 计算 hash bucket
  uint64_t hash_value = rowkey.hash();
  uint64_t bucket_idx = hash_value % bucket_count_;
  
  // 3. 加 row latch
  ObLatchGuard guard(buckets_[bucket_idx].latch_, ObLatchMode::WRITE);
  
  // 4. 查找 ObMvccHashNode
  ObMvccHashNode *node = buckets_[bucket_idx].find(rowkey);
  if (OB_ISNULL(node)) {
    return OB_NOT_FOUND;
  }
  
  // 5. 获取 value
  value = node->get_mvcc_row();
  if (OB_ISNULL(value)) {
    return OB_NOT_FOUND;
  }
  
  return OB_SUCCESS;
}
```

### 3.2 与 BTree 对比

```cpp
// ObKeyBtree::get（#15 v2）
int ObKeyBtree::get(ObStoreCtx &ctx,
                    const ObDatumRowkey &rowkey,
                    ObMvccRow *&value) const {
  // 1. 参数验证
  // 2. 范围构造
  ObDatumRange range(rowkey, rowkey, true, true);
  ObIMvccValueIterator *value_iter = nullptr;
  
  // 3. scan 复用
  int ret = scan(ctx, range, value_iter);
  if (OB_SUCC(ret)) {
    // 4. 取第一行
    void *row = nullptr;
    if (OB_SUCC(value_iter->get_next_row(row))) {
      value = static_cast<ObMvccRow *>(row);
    }
  }
  return ret;
}
```

### 3.3 性能对比

| 操作 | ObMvccHashIndex | ObKeyBtree |
|------|-----------------|-------------|
| 查找 | Hash lookup（O(1)） | BTree lookup（O(log n)） |
| 锁 | Hash bucket latch | BTree path latch |
| 锁粒度 | bucket 粒度 | path 粒度 |
| 分配 | ObHashNodeAllocator | ObKeyBtreeNodeAllocator |
| 范围查询 | 不友好 | **友好** |

### 3.4 关键优化

1. **Hash 优先**（O(1)）：点查优先用 Hash 索引
2. **bucket latch**（与 #75 v2 集成）：细粒度锁
3. **lazy init**：延迟初始化以减少启动开销
4. **batch 重建**：支持批量 MVCC 重构

---

## 4. scan 路径实现

### 4.1 ObMvccHashIndex::scan 实读

```cpp
// src/storage/memtable/mvcc/ob_mvcc_hash_index.cpp
int ObMvccHashIndex::scan(ObStoreCtx &ctx,
                           const ObDatumRange &range,
                           ObIMvccValueIterator *&value_iter) const {
  // 1. 范围裁剪
  range.trim_left();
  range.trim_right();
  
  // 2. 加锁
  ObLockParam lock_param;
  lock_param.lock_type_ = ObLockType::READ;
  ObStoreRowLockState lock_state;
  if (OB_FAIL(lock(ctx, lock_param, lock_state))) {
    return OB_TRY_LOCK_ROW_CONFLICT;
  }
  
  // 3. 创建多版本迭代器
  value_iter = create_multi_version_iterator();
  
  // 4. 初始化迭代器
  int ret = value_iter->init(ctx, range);
  if (OB_FAIL(ret)) {
    unlock(ctx, lock_state);
    return ret;
  }
  
  return OB_SUCCESS;
}
```

### 4.2 与 BTree 对比

```cpp
// ObKeyBtree::scan（#15 v2）
int ObKeyBtree::scan(ObStoreCtx &ctx,
                     const ObDatumRange &range,
                     ObIMvccValueIterator *&value_iter) const {
  // 类似的 range 构造 + lock + iterator 初始化
  // 区别：Hash 不需要范围裁剪
  // 区别：Hash 单 bucket 锁 vs BTree path 锁
}
```

---

## 5. 与 #1-#15 v2 MVCC 集成

### 5.1 ObMvccHashIndex ↔ MVCC Row

```cpp
// ObMvccHashIndex::mvcc_write 完整 lifecycle（与 #1 v2 集成）
int ObMvccHashIndex::mvcc_write(ObStoreCtx &ctx,
                                  ObMvccRow &value,
                                  const ObTxNodeArg &arg,
                                  const bool check_exist,
                                  ObMvccWriteResult &res) {
  // 1. 行级 latch（与 #75 v2 集成）
  ObLatchGuard guard(latch_, ObLatchMode::WRITE);
  
  // 2. 写冲突检测（与 #3 v2 集成）
  if (OB_FAIL(check_row_locked(ctx, ...))) {
    return OB_TRY_LOCK_ROW_CONFLICT;
  }
  
  // 3. 写入 ObMvccRow（与 #1 v2 集成）
  return value.mvcc_write(ctx, arg, check_exist, res);
}
```

### 5.2 ObMvccHashIndex ↔ MVCC Callback

```cpp
// ObMvccHashIndex::pre_commit/commit/abort 完整 lifecycle（与 #4 v2 集成）
int ObMvccHashIndex::pre_commit(ObStoreCtx &ctx,
                                  const ObMvccRow &value) {
  // 1. 构造 tx callback（与 #4 v2 集成）
  ObTxCallback *callback = nullptr;
  if (OB_FAIL(build_tx_callback_(value, callback))) {
    return ret;
  }
  return memtable_->register_callback(callback);
}

int ObMvccHashIndex::commit(ObStoreCtx &ctx,
                              const ObMvccRow &value,
                              const SCN commit_version,
                              const SCN tx_end_scn) {
  value.set_committed_scn(commit_version, tx_end_scn);
  return value.commit();
}
```

### 5.3 ObMvccHashIndex ↔ MVCC Compact & GC

```cpp
// ObMvccHashIndex::try_cleanout_tx_node 完整 lifecycle（与 #5 v2 集成）
int ObMvccHashIndex::try_cleanout_tx_node(ObMvccTransNode *tnode) {
  return memtable_->try_cleanout_tx_node(tnode);
}

int ObMvccHashIndex::try_cleanout_mvcc_row(ObMvccRow *value) {
  return value->try_cleanout_mvcc_row();
}
```

### 5.4 小结：ObMvccHashIndex 与 #1-#15 v2 的集成矩阵

| #1-#15 v2 | 集成方式 | 关联 |
|-----------|----------|------|
| #1 v2 | `value.mvcc_write` 写入 ObMvccRow | ObMvccTransNode + ObTxNodeArg |
| #2 v2 | `scan` 触发 `ObIMvccValueIterator` | 多版本遍历 |
| #3 v2 | `check_row_locked` 检测写写冲突 | 4 种返回值 |
| #4 v2 | `commit/abort` 触发 ObTxCallback | 13+ 虚函数 lifecycle |
| #5 v2 | `try_cleanout_*` 委派给 ObMvccRow | 5 种 cleanout 路径 |
| #14 v2 | ObMemtable 三种索引之一 | 与 ObKeyBtree / ObClusterIndex 并列 |
| #15 v2 | ObKeyBtree 对比 | BTree 索引实现 |

---

## 6. Lifecycle 完整串联

### 6.1 ObMvccHashIndex 完整 Lifecycle

```
1. 创建
   - ObMvccHashIndex::init() 初始化
   - 关联 memtable_（与 #14 v2 集成）
   - 锁初始化（与 #75 v2 集成）
   - stats_ 监控初始化
   │
2. 活跃阶段（接受读 + 写）
   - SELECT → ObMemtable::scan → ObMvccHashIndex::scan
   - SELECT → ObMemtable::get → ObMvccHashIndex::get
   - INSERT → ObMemtable::mvcc_write → ObMvccHashIndex::mvcc_write
   │
3. 写事务生命周期（与 #1-#4 v2 集成）
   - ObMvccHashIndex::lock → 加锁（与 #3 v2 集成）
   - ObMvccHashIndex::mvcc_write → 写 ObMvccRow（与 #1 v2 集成）
   - ObMvccHashIndex::pre_commit → 注册 ObTxCallback（与 #4 v2 集成）
   - ObMvccHashIndex::commit → 触发 callback + set scn
   - ObMvccHashIndex::abort → 触发 callback + set aborted
   │
4. 读事务生命周期（与 #2 v2 集成）
   - ObMvccHashIndex::lock → 加读锁
   - ObMvccHashIndex::scan / get → 创建 ObIMvccValueIterator
   - 迭代器多版本遍历（与 #2 v2 集成）
   │
5. 冻结阶段（与 #5 v2 + #14 v2 集成）
   - ObMvccHashIndex::reset
   - 释放内部 hash bucket
   - 释放锁
   │
6. 释放阶段
   - ObMvccHashIndex::destroy
   - 释放所有资源
   - 释放 stats_
```

### 6.2 与 #15 v2 ObKeyBtree 完整集成对比

| 维度 | ObMvccHashIndex | ObKeyBtree |
|------|-----------------|-------------|
| 创建 | `ObMvccHashIndex::init` | `ObKeyBtree::init` |
| 读 | `get` / `scan` | `get` / `scan` |
| 写 | `mvcc_write` | `mvcc_write` |
| 锁 | Hash bucket latch（#15 v2 集成） | BTree path latch（#15 v2 集成） |
| MVCC 写 | `value.mvcc_write`（#1 v2 集成） | 同 |
| 写冲突 | `check_row_locked`（#3 v2 集成） | 同 |
| Callback | `pre_commit/commit/abort`（#4 v2 集成） | 同 |
| GC | `try_cleanout_*`（#5 v2 集成） | 同 |
| 冻结 | `reset/destroy`（#14 v2 集成） | 同 |

### 6.3 与 #14 v2 完整集成图

```
14 v2 (ObMemtable)
  ├── 写路径
  │     mvcc_write → ObMvccHashIndex::mvcc_write（本篇 #16 v2）
  │                → ObKeyBtree::mvcc_write（#15 v2）
  │                → ObClusterIndex::mvcc_write
  │                → ObMvccEngine → ObMvccRow + ObMvccTransNode（与 #1 v2 集成）
  │                → check_row_locked（与 #3 v2 集成）
  │                → pre_commit / commit / abort（与 #4 v2 集成）
  │                → try_cleanout_tx_node（与 #5 v2 集成）
  │
  └── 读路径
        scan / get / multi_get → ObMvccHashIndex::scan（本篇 #16 v2）
                              → ObKeyBtree::scan（#15 v2）
                              → ObIMvccValueIterator（与 #2 v2 集成）
```

---

## 7. Hash vs BTree vs Cluster 对比（完善 #15 v2 表格）

| 索引 | 文件 | 适用场景 | 时间复杂度 | 范围查询 | 排序输出 | 聚簇 |
|------|------|----------|------------|----------|----------|------|
| **ObMvccHashIndex** | `ob_mvcc_hash_index.{h,cpp}` | 点查（精确匹配） | O(1) | 弱 | 弱 | 否 |
| **ObKeyBtree** | `ob_keybtree.{h,cpp}` | 范围查询（< / > / >= / <=） | O(log n) | **强** | 中 | 否 |
| **ObClusterIndex** | `ob_mvcc_cluster_index.{h,cpp}` | 主键聚簇 | O(log n) | **最强** | **强** | **是** |

### 7.1 索引选择策略（完善 #15 v2 表格）

```
1. 点查 (= 单值):
   - 优先用 Hash 索引（O(1) 快）
   - 次选用 BTree 索引（O(log n)）

2. 范围查询 (< / > / >= / <= / BETWEEN):
   - 用 BTree 索引
   - 连续范围优先用 Cluster 索引

3. 排序输出 (ORDER BY):
   - 优先用 Cluster 索引（数据已排序）
   - 次选用 BTree 索引

4. 全表扫描:
   - 用 Cluster 索引
   - 否则 BTree 顺序扫描
```

### 7.2 与 #15 v2 ObKeyBtree 的工程对比

| 工程维度 | ObMvccHashIndex | ObKeyBtree |
|----------|-----------------|-------------|
| 内存开销 | 高（节点对象） | 中（节点对象） |
| 缓存局部性 | 中（hash 分散） | 高（BTree 顺序访问） |
| 范围查询 | 弱 | **强** |
| 写入 | O(1) hash put | O(log n) BTree insert |
| 空间 | 较高（hash bucket） | 中（BTree 节点） |
| 适用 | 点查 / KV | 范围 / 排序 |

---

## 8. 与 #1-#15 v2 deep-dive 完整对比

| 维度 | #1-#5 v2 | #14 v2 | #15 v2 | **#16 v2（本篇）** |
|------|----------|--------|--------|------------------|
| 主题 | MVCC 系列 | MemTable Internals | ObKeyBtree | **ObMvccHashIndex** |
| commit | `c3d14bc` ... `66f3861` | `0b152b1` | `9dd3fc3` | **`?`** |
| 实读 | 31 mvcc 文件 | 37+ memtable 文件 | `ob_keybtree.{h,cpp}` | **`ob_mvcc_hash_index.{h,cpp}`** |
| 核心 | `ObMvccTransNode` | `ObMemtable` | `ObKeyBtree` BTree 索引 | **`ObMvccHashIndex` Hash 索引** |
| 关键 | 7 flag 位 | 完整 lifecycle | BTree scan/get 路径 | **Hash get 路径 O(1)** |
| 集成 | 与 #2/#3/#4 集成 | 与 #1-#5 集成 | 与 #1-#5 + #14 集成 | **与 #1-#5 + #14 集成** |

---

## 9. 推荐下一篇

按 "按顺序来" 指令，#16 v2 完成后：

- **#18 v2 Index Design**（与 #15 + #16 紧密）
- **#17 v2 Query Optimizer**（CBO 索引选择）
- **#41 v2 Join Operators**（算子）
- **#51 v2 Block Cache**（micro_block 缓存）
- **#29 v2 Slow Query**（slow query 捕获与分析）

要继续哪一篇 #17+ refine？

---

Key code references (all from real source exploration):
  - src/storage/memtable/mvcc/ob_mvcc_hash_index.{h,cpp}
  - src/storage/memtable/mvcc/ob_mvcc_hash_node.h
  - src/storage/memtable/mvcc/ob_multi_version_iterator.{h,cpp}
  - src/storage/memtable/mvcc/ob_mvcc_keybtree.h (#15 v2)
  - src/storage/memtable/ob_memtable.h (与 #14 v2 集成)
  - src/storage/memtable/mvcc/ob_mvcc_engine.{h,cpp}
  - src/storage/memtable/mvcc/ob_mvcc_row.{h,cpp}
  - src/storage/memtable/mvcc/ob_mvcc_iterator.{h,cpp}
  - src/storage/memtable/mvcc/ob_mvcc_ctx.h

Next in recommended order: #18 v2 Index Design / #17 v2 Query Optimizer /
#41 v2 Join Operators / #51 v2 Block Cache / #29 v2 Slow Query" 2>&1 | tail -3 && \
  git push origin main 2>&1 | tail -3 && \
  git log --oneline -3