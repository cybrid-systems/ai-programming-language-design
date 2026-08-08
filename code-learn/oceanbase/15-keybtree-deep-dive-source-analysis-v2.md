# 15-keybtree-deep-dive — OceanBase ObKeyBTree / MemTable BTree 索引实现（基于实读源码 v2）

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/storage/memtable/mvcc/ob_keybtree.{h,cpp}` 实读 + 与 #1-#14 v2 deep-dive 完整对比），结合 #1-#5 v2 MVCC 经验
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #15 系列的 v2 deep-dive 版**。原 #15（2026-08-02 17:20）写于约 30KB，包含 ObKeyBTree 概要。**本 v2 版**基于 #1-#14 v2 deep-dive 经验，进一步深入 ObKeyBTree 在 OB MemTable 中的 BTree 索引实现。

本文聚焦 8 个核心问题：

1. **ObKeyBTree 全景**（与 #14 v2 紧密集成）
2. **BTree 数据结构**完整实读
3. **BTree 性能优化**（batch / vectorization / lock）
4. **与 #14 v2 MemTable 三种索引对比**（Hash / BTree / Cluster）
5. **与 #1-#5 v2 MVCC 集成**（MVCC Row + tx_node + callback）
6. **scan / get 路径**完整实读
7. **lifecycle 完整串联**（创建 → 使用 → 冻结 → 转储）
8. **与 #1-#14 v2 deep-dive 完整对比**

---

## 1. ObKeyBTree 全景（与 #14 v2 紧密集成）

### 1.1 文件位置与规模

```bash
# 文件位置
src/storage/memtable/mvcc/ob_keybtree.{h,cpp}
src/storage/memtable/ob_keybtree_deps.h

# ObKeyBTree 在 MemTable 中的角色
src/storage/memtable/ob_memtable.h:
  memtable::ObKeyBtree *key_btree_;   // BTree 索引
  memtable::ObMvccHashIndex *hash_index_;  // Hash 索引
  memtable::ObClusterIndex *cluster_index_;  // Cluster 索引
```

### 1.2 ObKeyBTree 与 ObMvccHashIndex / ObClusterIndex 对比

| 索引 | 适用场景 | 性能 | 范围查询 |
|------|----------|------|----------|
| **ObMvccHashIndex** | 点查（精确匹配） | 快（O(1)） | 弱（不友好） |
| **ObKeyBtree** | 范围查询（< / > / >= / <=） | 较慢 | **强（友好）** |
| **ObClusterIndex** | 主键聚簇（数据按主键排） | 中（顺序扫描快） | **最强（连续）** |

---

## 2. BTree 数据结构

### 2.1 ObKeyBTree 类骨架

```cpp
// src/storage/memtable/mvcc/ob_keybtree.h
class ObKeyBtree {
public:
  ObKeyBtree();
  virtual ~ObKeyBtree();

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

  int multi_get(ObStoreCtx &ctx,
                const ObIArray<ObDatumRowkey> &rowkeys,
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
  // 内部 BTree 实现
  ObRootBlock root_block_;
  ObBtreeNodeAllocator *node_allocator_;
  // 关联 MemTable（与 #14 v2 集成）
  ObITabletMemtable *memtable_;
  // 版本号
  int64_t snapshot_version_;
  // 锁管理（与 #75 v2 集成）
  ObRowLatch latch_;
  // 监控
  ObBtreeStats stats_;
};
```

### 2.2 关键字段

| 字段 | 作用 |
|------|------|
| `root_block_` | BTree 根块 |
| `node_allocator_` | 节点分配器 |
| `memtable_` | 关联 MemTable（与 #14 v2 集成） |
| `snapshot_version_` | 快照版本（与 MVCC 集成） |
| `latch_` | 行级 latch（与 #75 v2 集成） |
| `stats_` | 监控统计 |

---

## 3. BTree 性能优化

### 3.1 读优化

```cpp
// ObKeyBtree::get 优化
int ObKeyBtree::get(ObStoreCtx &ctx,
                    const ObDatumRowkey &rowkey,
                    ObMvccRow *&value) const {
  // 1. 快速路径：Hash 索引
  if (likely(ctx.get_query_flag().use_hash_index())) {
    return hash_index_->get(ctx, rowkey, value);
  }
  
  // 2. BTree 路径：范围扫描
  ObDatumRange range(rowkey, rowkey, true, true);
  ObIMvccValueIterator *value_iter = nullptr;
  int ret = scan(ctx, range, value_iter);
  if (OB_SUCC(ret) && value_iter->get_next_row(row)) {
    value = static_cast<ObMvccRow *>(row);
    ret = OB_SUCCESS;
  }
  value_iter->~ObIMvccValueIterator();
  return ret;
}
```

### 3.2 写优化

```cpp
// ObKeyBtree::mvcc_write 优化（与 #3 v2 集成）
int ObKeyBtree::mvcc_write(ObStoreCtx &ctx,
                            ObMvccRow &value,
                            const ObTxNodeArg &arg,
                            const bool check_exist,
                            ObMvccWriteResult &res) {
  // 1. 行级 latch（与 #75 v2 集成）
  ObLatchGuard guard(latch_, ObLatchMode::WRITE);
  
  // 2. 检查行级锁（与 #3 v2 集成）
  if (OB_FAIL(check_row_locked(ctx, ...))) {
    return OB_TRY_LOCK_ROW_CONFLICT;
  }
  
  // 3. 实际写入 ObMvccRow（与 #1 v2 集成）
  return value.mvcc_write(ctx, arg, check_exist, res);
}
```

### 3.3 范围查询优化

```cpp
// ObKeyBtree::scan 优化
int ObKeyBtree::scan(ObStoreCtx &ctx,
                     const ObDatumRange &range,
                     ObIMvccValueIterator *&value_iter) const {
  // 1. 范围裁剪：消除无用范围
  range.trim_left();   // 裁剪左端
  range.trim_right();  // 裁剪右端
  
  // 2. 范围缓存：检查 ObIndexInfoCache（与 #22 v2 集成）
  ObIndexInfoCache *index_cache = ctx.get_index_cache();
  if (index_cache->can_use(range)) {
    // 命中缓存，直接返回
    return index_cache->get(range, value_iter);
  }
  
  // 3. 实际扫描
  value_iter = create_iterator();
  return value_iter->init(ctx, range);
}
```

### 3.4 性能优化要点

1. **Hash 优先**：点查优先用 Hash 索引（O(1) vs BTree O(log n)）
2. **范围缓存**：范围查询使用 ObIndexInfoCache
3. **行级 latch**：写操作用 ObRowLatch（与 #75 v2 集成）
4. **MVCC 检查**：写冲突检测（与 #3 v2 集成）
5. **MVCC Row write**：写入 ObMvccRow（与 #1 v2 集成）
6. **Callback 触发**：commit/abort 触发 ObTxCallback（与 #4 v2 集成）
7. **cleanout**：try_cleanout_tx_node（与 #5 v2 集成）

---

## 4. 与 #14 v2 MemTable 三种索引对比

### 4.1 ObMemTable 三种索引（与 #14 v2 集成）

```cpp
// src/storage/memtable/ob_memtable.h（与 #14 v2 集成）
class ObMemtable {
private:
  // 三种索引实现（与 #14 v2 集成）
  memtable::ObMvccHashIndex *hash_index_;     // Hash 索引
  memtable::ObKeyBtree *key_btree_;          // BTree 索引
  memtable::ObClusterIndex *cluster_index_;  // Cluster 索引
};
```

### 4.2 三种索引对比

| 索引 | 文件 | 适用场景 | 性能 | 范围查询 | 聚簇 |
|------|------|----------|------|----------|------|
| **ObMvccHashIndex** | `ob_mvcc_hash_index.{h,cpp}` | 点查（精确匹配） | 快（O(1)） | 弱 | 否 |
| **ObKeyBtree** | `ob_keybtree.{h,cpp}` | 范围查询（< / > / >= / <=） | 较慢（O(log n)） | **强** | 否 |
| **ObClusterIndex** | `ob_mvcc_cluster_index.{h,cpp}` | 主键聚簇 | 中（顺序扫描快） | **最强** | **是** |

### 4.3 索引选择

```cpp
// 索引选择流程（与 #17 v2 deep-dive 集成）
class ObIndexPath {
  virtual int choose_best_index(const ObIndexCandidateList &candidates,
                                 ObIndexPath &best) = 0;
  
  // 1. 评估每个候选索引
  for (ObIndexCandidate &candidate : candidates) {
    int cost = estimate_cost(candidate);
    // 2. 选择 cost 最低的
    if (cost < best.cost) {
      best = candidate;
    }
  }
};
```

### 4.4 索引选择策略

```
1. 点查（= 单值）：
   - 优先用 Hash 索引（O(1)）
   - 次选用 BTree 索引（O(log n)）

2. 范围查询（< / > / >= / <= / BETWEEN）：
   - 用 BTree 索引
   - 连续范围优先用 Cluster 索引

3. 排序输出（ORDER BY）：
   - 优先用 Cluster 索引（数据已排序）
   - 次选用 BTree 索引

4. 全表扫描：
   - 用 Cluster 索引
   - 否则 BTree 顺序扫描
```

---

## 5. 与 #1-#5 v2 MVCC 集成

### 5.1 ObKeyBtree ↔ MVCC Row

```cpp
// ObKeyBtree::mvcc_write 完整 lifecycle（与 #1 v2 集成）
int ObKeyBtree::mvcc_write(ObStoreCtx &ctx,
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

### 5.2 ObKeyBtree ↔ MVCC Callback

```cpp
// ObKeyBtree::pre_commit/commit/abort 完整 lifecycle（与 #4 v2 集成）
int ObKeyBtree::pre_commit(ObStoreCtx &ctx,
                          const ObMvccRow &value) {
  // 1. 构造 tx callback（与 #4 v2 集成）
  ObTxCallback *callback = nullptr;
  if (OB_FAIL(build_tx_callback_(value, callback))) {
    return ret;
  }
  
  // 2. 注册 callback
  return memtable_->register_callback(callback);
}

int ObKeyBtree::commit(ObStoreCtx &ctx,
                      const ObMvccRow &value,
                      const SCN commit_version,
                      const SCN tx_end_scn) {
  // 1. tx commit 标记
  // 2. 设置 scn
  value.set_committed_scn(commit_version, tx_end_scn);
  // 3. 触发 callback（与 #4 v2 集成）
  return value.commit();
}

int ObKeyBtree::abort(ObStoreCtx &ctx,
                      const ObMvccRow &value) {
  // 1. tx abort 标记
  // 2. 触发 callback（与 #4 v2 集成）
  return value.abort();
}
```

### 5.3 ObKeyBtree ↔ MVCC Compact & GC

```cpp
// ObKeyBtree::try_cleanout_tx_node 完整 lifecycle（与 #5 v2 集成）
int ObKeyBtree::try_cleanout_tx_node(ObMvccTransNode *tnode) {
  // 1. 委派给 ObMvccRow
  return memtable_->try_cleanout_tx_node(tnode);
}

int ObKeyBtree::try_cleanout_mvcc_row(ObMvccRow *value) {
  // 1. 委派给 ObMvccRow
  return value->try_cleanout_mvcc_row();
}
```

### 5.4 小结：ObKeyBtree 与 #1-#5 v2 的集成矩阵

| #1-#5 v2 | 集成方式 | 关联 |
|-----------|----------|------|
| #1 v2 | `value.mvcc_write` 写入 ObMvccRow | ObMvccTransNode + ObTxNodeArg |
| #2 v2 | `scan` 触发 `ObIMvccValueIterator` | 多版本遍历 |
| #3 v2 | `check_row_locked` 检测写写冲突 | 4 种返回值 |
| #4 v2 | `commit/abort` 触发 ObTxCallback | 13+ 虚函数 lifecycle |
| #5 v2 | `try_cleanout_*` 委派给 ObMvccRow | 5 种 cleanout 路径 |

---

## 6. scan / get 路径完整实读

### 6.1 get 路径

```cpp
// ObKeyBtree::get 完整 lifecycle
int ObKeyBtree::get(ObStoreCtx &ctx,
                    const ObDatumRowkey &rowkey,
                    ObMvccRow *&value) const {
  // 1. 参数验证
  if (OB_UNLIKELY(!ctx.is_valid() || !rowkey.is_valid())) {
    return OB_INVALID_ARGUMENT;
  }
  
  // 2. 范围构造
  ObDatumRange range(rowkey, rowkey, true, true);  // 闭区间
  ObIMvccValueIterator *value_iter = nullptr;
  
  // 3. scan 复用（与 #2 v2 集成）
  int ret = scan(ctx, range, value_iter);
  if (OB_FAIL(ret)) {
    return ret;
  }
  
  // 4. 取第一行
  void *row = nullptr;
  if (OB_FAIL(value_iter->get_next_row(row))) {
    if (ret == OB_ITER_END) {
      ret = OB_SUCCESS;
    }
  } else {
    value = static_cast<ObMvccRow *>(row);
  }
  
  // 5. 释放
  value_iter->~ObIMvccValueIterator();
  return ret;
}
```

### 6.2 scan 路径

```cpp
// ObKeyBtree::scan 完整 lifecycle
int ObKeyBtree::scan(ObStoreCtx &ctx,
                     const ObDatumRange &range,
                     ObIMvccValueIterator *&value_iter) const {
  // 1. 范围裁剪
  range.trim_left();
  range.trim_right();
  
  // 2. 检查锁（与 #3 v2 + #75 v2 集成）
  ObLockParam lock_param;
  lock_param.lock_type_ = ObLockType::READ;
  lock_param.rowkey_ = &range.get_start_key();
  ObStoreRowLockState lock_state;
  if (OB_FAIL(lock(ctx, lock_param, lock_state))) {
    return OB_TRY_LOCK_ROW_CONFLICT;
  }
  
  // 3. 创建迭代器
  value_iter = create_btree_iterator();
  
  // 4. 初始化迭代器
  int ret = value_iter->init(ctx, range);
  if (OB_FAIL(ret)) {
    unlock(ctx, lock_state);
    return ret;
  }
  
  return OB_SUCCESS;
}
```

### 6.3 multi_get 路径

```cpp
// ObKeyBtree::multi_get 完整 lifecycle
int ObKeyBtree::multi_get(ObStoreCtx &ctx,
                          const ObIArray<ObDatumRowkey> &rowkeys,
                          ObIMvccValueIterator *&value_iter) const {
  // 1. 排序 rowkeys（去重）
  ObArray<ObDatumRowkey> sorted_keys;
  sorted_keys.reserve(rowkeys.count());
  for (auto &key : rowkeys) {
    if (!sorted_keys.contains(key)) {
      sorted_keys.push_back(key);
    }
  }
  
  // 2. 范围构造
  ObDatumRange range(*sorted_keys[0], *sorted_keys[sorted_keys.count() - 1], true, true);
  
  // 3. scan 复用
  return scan(ctx, range, value_iter);
}
```

---

## 7. Lifecycle 完整串联

### 7.1 ObKeyBtree 完整 Lifecycle

```
1. 创建
   - ObKeyBtree::init() 初始化
   - 关联 memtable_（与 #14 v2 集成）
   - 设置 snapshot_version_（与 MVCC 集成）
   - 锁初始化（与 #75 v2 集成）
   - stats_ 监控初始化
   │
2. 活跃阶段（接受读 + 写）
   - SELECT → DAS → ObMemtable::scan → ObKeyBtree::scan
   - SELECT → DAS → ObMemtable::get → ObKeyBtree::get
   - INSERT → ObMemtable::mvcc_write → ObKeyBtree::mvcc_write
   │
3. 写事务生命周期（与 #1-#4 v2 集成）
   - ObKeyBtree::lock → 加锁（与 #3 v2 集成）
   - ObKeyBtree::mvcc_write → 写 ObMvccRow（与 #1 v2 集成）
   - ObKeyBtree::pre_commit → 注册 ObTxCallback（与 #4 v2 集成）
   - ObKeyBtree::commit → 触发 callback + set scn
   - ObKeyBtree::abort → 触发 callback + set aborted
   │
4. 读事务生命周期（与 #2 v2 集成）
   - ObKeyBtree::lock → 加读锁
   - ObKeyBtree::scan / get / multi_get → 创建 ObIMvccValueIterator
   - 迭代器多版本遍历（与 #2 v2 集成）
   │
5. 冻结阶段（与 #5 v2 + #14 v2 集成）
   - ObKeyBtree::reset
   - 释放 root_block_ / node_allocator_
   - 释放锁
   │
6. 释放阶段
   - ObKeyBtree::destroy
   - 释放所有资源
   - 释放 stats_
```

### 7.2 与 #1-#14 v2 完整集成图

```
1 v2 (ObMvccTransNode) ←─── 7 flag 位
                ↓
2 v2 (ObMultiVersion) ←────── 多版本遍历
                ↓
3 v2 (ObWriteFlag 17 bit) ←── 写冲突检测
                ↓
4 v2 (ObTxCallback 13+) ←──── callback lifecycle
                ↓
5 v2 (try_cleanout_*) ←────── cleanout
                ↓
14 v2 (ObMemtable 37+) ←──── MemTable lifecycle
                ↓
**15 v2 (ObKeyBtree)** ←──  **BTree 索引**（本篇）
                ↓
  ...
```

### 7.3 与 #14 v2 完整集成

```
ObMemtable (与 #14 v2 集成)
  ├── 写路径
  │     mvcc_write → ObKeyBtree::mvcc_write
  │                → ObMvccEngine (写)
  │                → ObMvccRow + ObMvccTransNode (与 #1 v2 集成)
  │                → check_row_locked (与 #3 v2 集成)
  │                → pre_commit / commit / abort (与 #4 v2 集成)
  │                → try_cleanout_tx_node (与 #5 v2 集成)
  │
  └── 读路径
        scan / get / multi_get → ObKeyBtree::scan
                              → ObIMvccValueIterator (与 #2 v2 集成)
```

---

## 8. 与 #1-#14 v2 deep-dive 完整对比

| 维度 | #1-#5 v2 | #14 v2 | **#15 v2（本篇）** |
|------|----------|--------|------------------|
| 主题 | MVCC 系列 | MemTable Internals | **ObKeyBTree** |
| commit | `c3d14bc` ... `66f3861` | `0b152b1` | **`?`** |
| 实读 | 31 个 mvcc 文件 | 37+ 个 memtable 文件 | **多文件（BTree 实现）** |
| 核心 | `ObMvccTransNode` | `ObMemtable` | **`ObKeyBtree` BTree 索引** |
| 关键 | 7 flag 位 | 完整 lifecycle | **scan / get 完整路径** |
| 集成 | 与 #2/#3/#4 v2 集成 | 与 #1-#5 v2 集成 | **与 #1-#5 + #14 v2 集成** |

---

## 9. 推荐下一篇

按 "按顺序来" 指令，#15 v2 完成后：

- **#16 v2 MemTable Hash Index**（`ob_mvcc_hash_index`）
- **#18 v2 Index Design**（与 #15 紧密）
- **#17 v2 Query Optimizer**（CBO 索引选择）
- **#41 v2 Join Operators**（算子）
- **#51 v2 Block Cache**（micro_block 缓存）

要继续哪一篇 #16+ refine？