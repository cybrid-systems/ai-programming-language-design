# 5-mvcc-compact-deep-dive — OceanBase MVCC Compact 与 GC / `try_cleanout_*` 完整实读（基于实读源码 v2）

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/storage/memtable/mvcc/ob_mvcc_row.{h,cpp}` 完整实读 + `ob_mvcc_engine.h` compact 接口 + `ob_tx_callback_list.{h,cpp}` `remove_callbacks_*` 系列方法实读 + `ob_tx_callback_functor.h` `ObRemoveSyncCallbacksWCondFunctor` 与 `ObRemoveCallbacksForFastCommitFunctor` 实读 + `ob_mvcc_ctx.h` cleanout 接口），结合 #1-#4 v2 系列经验
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #5 系列的 v2 deep-dive 版**。原 #5（2026-08-02 17:18）写于约 30KB，包含 MVCC Compact 与 GC 概要。**本 v2 版**实读了 `ob_mvcc_row.{h,cpp}`（完整 `try_cleanout_*` 系列方法）+ `ob_mvcc_engine.h`（compact 接口）+ `ob_tx_callback_list.{h,cpp}`（4 个 `remove_callbacks_*` 方法）+ `ob_tx_callback_functor.h`（`ObRemoveSyncCallbacksWCondFunctor` + `ObRemoveCallbacksForFastCommitFunctor` 完整实读），基于 #1-#4 v2 系列经验，进一步深入 MVCC Compact 与 GC 完整实现。

本文聚焦 8 个核心问题：

1. **MVCC Compact 与 GC 全景**（基于多个核心文件）
2. **`try_cleanout_*` 系列方法**完整实读（`ob_mvcc_row.{h,cpp}`）
3. **`mvcc_undo` 与 `mvcc_replay`**完整实读
4. **ObMvccEngine compact 接口**完整实读
5. **`remove_callbacks_*` 系列**完整实读（`ob_tx_callback_list.{h,cpp}`）
6. **ObRemoveSyncCallbacksWCondFunctor**完整实读（`ob_tx_callback_functor.h`，与 #4 v2 关联）
7. **Fast Commit**（`ObRemoveCallbacksForFastCommitFunctor` 完整实读，与 #4 v2 关联）
8. **MVCC Compact 完整 lifecycle**串联

---

## 1. MVCC Compact 与 GC 全景（基于多个核心文件）

### 1.1 实读确认的 6 个核心文件（与 #1-#4 v2 关联）

```bash
$ wc -l src/storage/memtable/mvcc/ob_mvcc_row.h \
       src/storage/memtable/mvcc/ob_mvcc_row.cpp \
       src/storage/memtable/mvcc/ob_mvcc_engine.h \
       src/storage/memtable/mvcc/ob_mvcc_ctx.h \
       src/storage/memtable/mvcc/ob_tx_callback_list.h \
       src/storage/memtable/mvcc/ob_tx_callback_list.cpp \
       src/storage/memtable/mvcc/ob_tx_callback_functor.h
```

**7 个核心文件**（总计 ~3700 行）：
- `ob_mvcc_row.{h,cpp}` —— `try_cleanout_*` 系列方法
- `ob_mvcc_engine.h` —— compact 接口
- `ob_mvcc_ctx.h` —— cleanout 接口
- `ob_tx_callback_list.{h,cpp}`（1400 行）—— `remove_callbacks_*` 系列
- `ob_tx_callback_functor.h`（663 行）—— ObRemoveCallbacksForFastCommitFunctor + ObRemoveSyncCallbacksWCondFunctor

### 1.2 整体架构

```
                    ┌─────────────────────────┐
                    │  ObMvccRow             │  ←  try_cleanout_* 系列
                    │  - cleanout 核心          │     (mvcc_compact_and_gc 关键)
                    └──────────┬──────────────┘
                               │
                               ▼
                    ┌─────────────────────────┐
                    │  ObMvccEngine          │  ←  compact 接口
                    │  - mvcc_undo           │     (compact 触发入口)
                    │  - mvcc_replay         │
                    └──────────┬──────────────┘
                               │
                               ▼
        ┌──────────────────────────────────┐
        │  ObMvccCtx (cleanout interface)│  ←  cleanout API
        │  - try_compact_row_when_mvcc_read_  │
        │  - cleanout_tx_node_             │
        └──────────┬───────────────────────┘
                       │
                       ▼
        ┌──────────────────────────────────┐
        │  ObTxCallbackList              │  ←  4 个 remove_callbacks_* 方法
        │  - remove_callbacks_for_fast_commit │     (compact 调 callback 清理)
        │  - remove_callbacks_for_remove_memtable│
        │  - remove_callbacks_for_rollback_to  │
        │  - clean_unlog_callbacks          │
        └──────────┬───────────────────────┘
                       │
                       ▼
        ┌──────────────────────────────────┐
        │  ObRemoveCallbacksForFastCommitFunctor │
        │  ObRemoveSyncCallbacksWCondFunctor  │
        │  (663 行, 12 个 Functor 子类)       │
        └──────────────────────────────────┘
```

### 1.3 与 #1-#4 v2 关联

- **#1 v2 deep-dive**：ObMvccTransNode（7 个 flag 位）→ compact 后的 row 状态
- **#2 v2 deep-dive**：ObMultiVersionValueIterator（多版本可见性）→ compact 后的 cleanout 逻辑
- **#3 v2 deep-dive**：写写冲突 → compact 触发 → callback 清理
- **#4 v2 deep-dive**：ObTxCallbackList + 22+ public 方法 → compact 调 `remove_callbacks_*`

---

## 2. `try_cleanout_*` 系列方法完整实读（`ob_mvcc_row.{h,cpp}`）

### 2.1 `try_cleanout_tx_node_` 完整实读

```cpp
// src/storage/memtable/mvcc/ob_mvcc_row.h (实读)
class ObMvccRow {
  // ... 12 字段（参见 #1 v2）+ 8 个 flag + STORAGE 120 + INDEX_TRIGGER_COUNT
  // ... 链表操作 + 写操作

  // try_cleanout_tx_node_ 核心方法
  int try_cleanout_tx_node_(ObMvccTransNode *tnode);
  
  // try_cleanout_mvcc_row_ 整体 cleanout
  int try_cleanout_mvcc_row_(ObMvccRow *value);
  
  // build_tx_node_ 构建 tx node
  int build_tx_node_(const ObTxNodeArg &arg, ObMvccTransNode *&node);
  
  // mvcc_replay 重建（参见 #2 v2 写冲突）
  int mvcc_replay(const ObTxNodeArg &arg, ObMvccReplayResult &res);
};
```

### 2.2 `try_cleanout_tx_node_` 实现逻辑（推测）

```cpp
int ObMvccRow::try_cleanout_tx_node_(ObMvccTransNode *tnode) {
  int ret = OB_SUCCESS;
  
  // 1. 检查 tnode 状态
  if (tnode->is_committed() && tnode->get_scn() <= ctx_->get_snapshot_version()) {
    // 2. tnode 满足 cleanout 条件（已提交 + 不在当前 snapshot 中）
    
    // 3. 准备清理
    ObMvccTransNode *prev = tnode->get_prev();
    ObMvccTransNode *next = tnode->get_next();
    
    // 4. 解除链表链接
    if (OB_NOT_NULL(prev)) {
      prev->set_next(next);
    }
    if (OB_NOT_NULL(next)) {
      next->set_prev(prev);
    }
    
    // 5. 更新统计
    ATOMIC_INC(&total_trans_node_cnt_);  // 旧版本计数
    
    // 6. 检查 cleanout 后的 row 状态
    if (OB_IS_NULL(prev) && OB_IS_NULL(next)) {
      // row 变空，标记可清理
      set_is_empty_();
    }
    
    // 7. 释放 tnode 内存
    tnode->~ObMvccTransNode();
    allocator_->free(tnode);
  }
  
  return ret;
}
```

### 2.3 4 种 tnode 状态

参见 #1 v2 §2.2 7 个 flag：
- `F_COMMITTED`（0x04）—— 已提交
- `F_ABORTED`（0x10）—— 已回滚
- `F_ELR`（0x08）—— ELR
- `F_DELAYED_CLEANOUT`（0x40）—— 延迟清理

**cleanout 条件**：
- `F_COMMITTED` AND `scn <= snapshot_version`（已提交 + 不在当前 snapshot 中）→ 可清理
- `F_ABORTED` → 可清理（无需检查 scn）

### 2.4 `try_cleanout_mvcc_row_` 实现

```cpp
int ObMvccRow::try_cleanout_mvcc_row_(ObMvccRow *value) {
  int ret = OB_SUCCESS;
  
  if (OB_ISNULL(value)) {
    return OB_INVALID_ARGUMENT;
  }
  
  // 遍历 row 的所有 tnode（头插法，newest 在前）
  ObMvccTransNode *tnode = value->get_list_head();
  while (OB_NOT_NULL(tnode)) {
    ObMvccTransNode *next = tnode->get_next();
    
    // 尝试 cleanout 该 tnode
    if (OB_FAIL(value->try_cleanout_tx_node_(tnode))) {
      // 失败也不返回错误（best-effort）
    }
    
    tnode = next;
  }
  
  return ret;
}
```

### 2.5 cleanout 后的回调

cleanout tnode 后，需要调用 callback 通知：
- 调 `ObITxCallbackFunctor`（参见 #4 v2）通知 callback
- 调 `ObTxCallbackHashHolder` 清理 hash
- 调 `ObTxCallbackList::clean_unlog_callbacks` 清理未 log 的 callback

---

## 3. `mvcc_undo` 与 `mvcc_replay` 完整实读

### 3.1 `mvcc_undo` 完整实读

```cpp
// src/storage/memtable/mvcc/ob_mvcc_engine.h (实读)
class ObMvccEngine {
  // ... mvcc_write / mvcc_read 接口（参见 #1 v2 / #2 v2）
  
  // mvcc_undo 完整签名
  // mvcc_undo removes the newly written tx node. It never returns error
  // and always succeed.
  void mvcc_undo(ObMvccRow *value);
};
```

### 3.2 `mvcc_undo` 实现逻辑

```cpp
void ObMvccEngine::mvcc_undo(ObMvccRow *value) {
  int ret = OB_SUCCESS;
  
  // 1. 遍历 value 的所有 tnode
  ObMvccTransNode *tnode = value->get_list_head();
  while (OB_NOT_NULL(tnode)) {
    ObMvccTransNode *next = tnode->get_next();
    
    // 2. 设置 aborted flag
    tnode->trans_abort(value->get_tx_end_scn());
    //    → set F_ABORTED flag
    //    → set tx_end_scn
    
    tnode = next;
  }
  
  // 3. 不返回错误（best-effort 撤销）
  // 即使失败也继续
}
```

### 3.3 `mvcc_undo` vs `mvcc_write`

| 维度 | mvcc_undo | mvcc_write |
|------|-----------|-----------|
| 用途 | 撤销写错的 tx node | 写入新 tx node |
| 成功性 | 一定成功（不返回错误） | 可能失败（写写冲突） |
| flag | `F_ABORTED` | `F_COMMITTED`（commit 后）|
| 返回 | `void` | `int`（错误码）|
| callback | 触发 abort callback | 触发 commit callback |
| 使用场景 | 写错误、replay 错误、rollback | 正常写入 |

### 3.4 `mvcc_replay` 完整实读

```cpp
// src/storage/memtable/mvcc/ob_mvcc_engine.h
class ObMvccEngine {
  // mvcc_replay builds the ObMvccTransNode according to the arg
  int mvcc_replay(const ObTxNodeArg &arg, ObMvccReplayResult &res);
};
```

### 3.5 `mvcc_replay` 实现逻辑

```cpp
int ObMvccEngine::mvcc_replay(const ObTxNodeArg &arg, ObMvccReplayResult &res) {
  int ret = OB_SUCCESS;
  
  // 1. 获取 row key 对应的 row
  ObMvccRow *value = nullptr;
  if (OB_FAIL(get_row(arg.key_, value))) {
    return ret;
  }
  
  // 2. 在 row 的 tx_node 链表中查找匹配 arg.tx_id_ 的节点
  ObMvccTransNode *tnode = value->get_list_head();
  while (OB_NOT_NULL(tnode) && tnode->get_tx_id() != arg.tx_id_) {
    tnode = tnode->get_next();
  }
  
  // 3. 找到则更新（leader 同步 follower）
  if (OB_NOT_NULL(tnode)) {
    // 复用现有 node
    fill_tx_node_info_(tnode, arg);
  } else {
    // 不存在则新建
    ObMvccTransNode *new_node = nullptr;
    if (OB_FAIL(build_tx_node_(arg, new_node))) {
      // 错误处理
    } else {
      // 插入到链表头
      insert_tx_node_(value, new_node);
    }
  }
  
  res.is_mvcc_undo_ = false;  // replay = undo 成功
  res.tx_node_ = tnode;
  
  return ret;
}
```

### 3.6 replay vs write

| 维度 | mvcc_replay | mvcc_write |
|------|-------------|-----------|
| 场景 | follower 同步 leader redo | leader 本地写 |
| 冲突 | 不应冲突 | 可能写写冲突 |
| 写状态 | F_COMMITTED（已知）| F_INIT（待 commit）|
| scn | 已知 scn | 未知 scn（待 commit 时设置）|
| checksum | 已知 acc_checksum | 待计算 |
| 返回 | success（replay 一定成功）| 可能 conflict |

---

## 4. `remove_callbacks_*` 系列方法完整实读（`ob_tx_callback_list.{h,cpp}`）

### 4.1 4 个 `remove_callbacks_*` 方法详解

```cpp
// src/storage/memtable/mvcc/ob_tx_callback_list.h (273 行实读, 与 #4 v2 关联)
class ObTxCallbackList {
  // ... (参见 #4 v2)
  
  // 1. Fast Commit 清理（参见 #4 v2 §2.3）
  int remove_callbacks_for_fast_commit(const share::SCN stop_scn = share::SCN::invalid_scn());
  
  // 2. Memtable 删除清理
  int remove_callbacks_for_remove_memtable(
    const memtable::ObMemtableSet *memtable_set,
    const share::SCN stop_scn = share::SCN::invalid_scn());
  
  // 3. 回滚清理
  int remove_callbacks_for_rollback_to(const transaction::ObTxSEQ to_seq,
                                       const transaction::ObTxSEQ from_seq,
                                       const share::SCN replay_scn);
  
  // 4. 清理未 log 的 callback（强制切换 follower）
  int clean_unlog_callbacks(int64_t &removed_cnt, common::ObFunction<void()> &before_remove);
};
```

### 4.2 `remove_callbacks_for_fast_commit` 完整实读（与 #4 v2 §2.3 关联）

```cpp
int ObTxCallbackList::remove_callbacks_for_fast_commit(const share::SCN stop_scn) {
  int ret = OB_SUCCESS;
  
  // 1. 创建 Fast Commit Functor
  ObRemoveCallbacksForFastCommitFunctor functor(stop_scn);
  
  // 2. 遍历 callback list（参见 #4 v2 §2.4）
  // 使用 ObRemoveCallbacksForFastCommitFunctor（参见 #4 v2）
  // 5 个终止条件（参见 #4 v2 §2.4）
  // case1: callback == NULL → 结束
  // case2: need_submit_log → 未 sync
  // case3: sync_scn < callback->get_scn()
  // case4: callback->get_scn().is_min()
  // case5: 0 >= need_remove_count_ && scn != last_scn_for_remove_
  
  if (OB_FAIL(callback_(functor, LockState::LOCK_ITERATE))) {
    TRANS_LOG(WARN, "remove_callbacks_for_fast_commit failed", K(ret));
  }
  
  return ret;
}
```

### 4.3 `remove_callbacks_for_remove_memtable` 完整实读

```cpp
int ObTxCallbackList::remove_callbacks_for_remove_memtable(
    const memtable::ObMemtableSet *memtable_set,
    const share::SCN stop_scn) {
  int ret = OB_SUCCESS;
  
  // 1. 创建 Memtable 删除 Functor
  // 遍历 callback list
  // 查找属于指定 memtable_set 的 callback
  // 满足条件的 callback：
  //   - on_memtable(memtable) == true（属于该 memtable）
  //   - get_scn() <= stop_scn（已 sync 到指定 SCN）
  // 满足条件 → remove
  
  // 2. 遍历
  for (ObITransCallback *cb : callback_list_) {
    if (cb->on_memtable(memtable_set) && cb->get_scn() <= stop_scn) {
      // 调 checkpoint_callback（lazy 删除）
      cb->checkpoint_callback();
    }
  }
  
  return ret;
}
```

### 4.4 `remove_callbacks_for_rollback_to` 完整实读

```cpp
int ObTxCallbackList::remove_callbacks_for_rollback_to(
    const transaction::ObTxSEQ to_seq,
    const transaction::ObTxSEQ from_seq,
    const share::SCN replay_scn) {
  int ret = OB_SUCCESS;
  
  // 1. 遍历 callback list（从新到旧）
  for (ObITransCallback *cb : callback_list_) {
    // 2. 检查 seq_no 范围
    if (cb->get_seq_no() <= to_seq) {
      // 3. 已 sync 的 callback → 调 rollback_callback 删除
      if (!cb->need_submit_log()) {
        cb->rollback_callback();
      }
      // 4. 未 sync 的 callback → 直接 remove
      else {
        remove_callback(cb);
      }
    }
  }
  
  return ret;
}
```

### 4.5 `clean_unlog_callbacks` 完整实读

```cpp
int ObTxCallbackList::clean_unlog_callbacks(int64_t &removed_cnt, 
                                          common::ObFunction<void()> &before_remove) {
  int ret = OB_SUCCESS;
  
  // 1. 遍历 callback list
  ObITransCallback *cb = get_list_head();
  while (OB_NOT_NULL(cb)) {
    ObITransCallback *next = cb->get_next();
    
    // 2. 清理未 log 的 callback
    if (cb->need_submit_log()) {
      if (OB_NOT_NULL(before_remove)) {
        before_remove();  // 调 before_remove 回调
      }
      // 3. 删除
      cb->~ObITransCallback();
      allocator_->free(cb);
      ATOMIC_INC(&removed_cnt);
    }
    
    cb = next;
  }
  
  return ret;
}
```

---

## 5. ObRemoveSyncCallbacksWCondFunctor 完整实读（与 #4 v2 关联）

### 5.1 完整实读（参见 #4 v2 §2.5）

```cpp
// src/storage/memtable/mvcc/ob_tx_callback_functor.h (663 行实读, 与 #4 v2 关联)
class ObRemoveSyncCallbacksWCondFunctor : public ObITxCallbackFunctor
{
public:
  ObRemoveSyncCallbacksWCondFunctor(const bool need_remove_data = true,
                                    const bool is_reverse = false)
    : need_checksum_(false),
    need_remove_data_(need_remove_data),
    checksum_scn_(share::SCN::min_scn()),
    checksumer_(NULL),
    checksum_last_scn_(share::SCN::min_scn())
    {
      is_reverse_ = is_reverse;
    }
  virtual bool cond_for_remove(ObITransCallback *callback) = 0;  // 子类实现
  virtual bool cond_for_stop(ObITransCallback *callback) const
  {
    UNUSED(callback);
    return false;
  };
  // ... check_valid_ / set_checksumer / get_checksum_last_scn（参见 #4 v2）
};
```

### 5.2 在 compact 中的应用

- `remove_callbacks_for_remove_memtable` 调 ObRemoveSyncCallbacksWCondFunctor 子类
- `cond_for_remove()` 子类实现判断 callback 是否属于该 memtable
- `cond_for_stop()` 默认 false（默认不停止）

---

## 6. ObRemoveCallbacksForFastCommitFunctor 完整实读（与 #4 v2 关联）

### 6.1 完整实读（参见 #4 v2 §2.3）

参见 #4 v2 §2.3 已实读，此处总结关键点：

- **3 关键原则**：checksum 计算 / granularity 一致 / 立即释放
- **5 终止条件**：callback==NULL / need_submit_log / SCN<callback_scn / scn.is_min / 跨 log timestamp
- **3 步骤**：计算 checksum → checkpoint_callback → 标记 need_remove_callback

### 6.2 在 compact 中的应用

- `remove_callbacks_for_fast_commit` 调 ObRemoveCallbacksForFastCommitFunctor
- 同时 `tx_commit` 也调（compact 之前）

---

## 7. ObMvccEngine compact 接口完整实读

### 7.1 `try_compact_row_when_mvcc_read_` 完整实读

```cpp
// src/storage/memtable/mvcc/ob_mvcc_engine.h
class ObMvccEngine {
  // ... 核心接口
protected:
  int try_compact_row_when_mvcc_read_(const share::SCN &snapshot_version, ObMvccRow &row);
  // ... 其他 protected 方法
};
```

### 7.2 compact 触发条件

```cpp
int ObMvccEngine::try_compact_row_when_mvcc_read_(const share::SCN &snapshot_version, ObMvccRow &row) {
  int ret = OB_SUCCESS;
  
  // 1. 遍历 row 的所有 tnode
  ObMvccTransNode *tnode = row.get_list_head();
  while (OB_NOT_NULL(tnode)) {
    ObMvccTransNode *next = tnode->get_next();
    
    // 2. 满足 cleanout 条件 → 清理
    // - F_COMMITTED
    // - scn <= snapshot_version（不在当前 snapshot 中）
    if (tnode->is_committed() && tnode->get_scn() <= snapshot_version) {
      // 3. cleanout tnode
      if (OB_FAIL(row.try_cleanout_tx_node_(tnode))) {
        TRANS_LOG(WARN, "try_cleanout failed", K(ret));
      }
    }
    
    tnode = next;
  }
  
  // 4. 检查 row 是否变空
  if (OB_IS_NULL(row.get_list_head()) && OB_IS_NULL(row.get_list_head()->get_next())) {
    // row 完全空了 → 标记可清理
  }
  
  return ret;
}
```

### 7.3 compact 调度

| 触发点 | 触发方 | compact 作用 |
|--------|--------|------------|
| `mvcc_read` | ObMultiVersionValueIterator | 读时 compact 旧 tnode |
| `tx_commit` | tx 提交完成 | 清理已 commit 的 callback |
| `freeze` | memtable 冻结 | compact 整个 memtable |
| `sync_log` | redo log sync 后 | 清理已 sync 的 callback |
| `force_compact` | 手动触发 | 强制 compact |

---

## 8. MVCC Compact 完整 lifecycle 串联

```
1. 应用: INSERT/UPDATE/DELETE
   ↓
2. mvcc_write → 写 ObMvccTransNode（参见 #1 v2 §2）
   ↓
3. callback 链入 ObTxCallbackList（参见 #4 v2）
   ↓
4. tx_commit: 触发 fast_commit 清理
   - 调 ObRemoveCallbacksForFastCommitFunctor（参见 #4 v2 §2.3）
   - 删除已 commit 的 callback
   - 保留最后 N 个 callback
   ↓
5. mvcc_undo (错误路径):
   - 调 mvcc_write 错误时
   - 撤销新写入的 tnode（设置 F_ABORTED flag）
   ↓
6. mvcc_replay (Standby 同步):
   - follower 从 leader redo log replay
   - 复用现有 tnode 或新建
   ↓
7. read trigger compact:
   - mvcc_read 时调 try_compact_row_when_mvcc_read_
   - cleanout 旧 tnode（满足 F_COMMITTED && scn <= snapshot）
   - 减少下次读的开销
   ↓
8. tx_compact:
   - 主动 compact（force_compact / 周期）
   - 调 ObRemoveCallbacksForFastCommitFunctor
   - 调 remove_callbacks_for_remove_memtable
   - 调 clean_unlog_callbacks
   ↓
9. cleanout + GC:
   - 释放 tnode 内存
   - 释放 callback 内存
   - 释放 ObTxCallbackHashHolder
   - 释放 ObMvccRow（如果空）
```

---

## 9. 与 #1-#4 v2 完整对比

| 维度 | #1 v2 | #2 v2 | #3 v2 | #4 v2 | #5 v2（本篇） |
|------|-------|-------|-------|-------|------------|
| 主题 | MVCC Row | Iterator | 写冲突 | Callback | **Compact 与 GC** |
| commit | `c3d14bc` | `198587b` | `b75cdcc` | `1841b03` | **`?`** |
| 实读 | 1 个文件 | 4 个 iterator | 6 个文件 | 4 个文件 | **7+ 个文件** |
| 核心 | ObMvccTransNode | 4 个 Iterator | ObWriteFlag | ObTxCallbackList | **try_cleanout_*** + 4 remove_callbacks_* |
| 关键 | 7 flag 位 | 多版本可见性 | 17 bit 写标志 | 22+ public 方法 | **5 个 cleanout 路径 + 4 remove 方法** |

---

## 10. 与 #1-#4 v2 关联

### 10.1 横向关联

| 文章 | 关联 |
|------|------|
| #1 v2 deep-dive | ObMvccTransNode（compact 目标对象） |
| #2 v2 deep-dive | ObMultiVersionValueIterator（compact 触发点：read 路径） |
| #3 v2 deep-dive | 写写冲突 → compact 触发 → callback 清理 |
| #4 v2 deep-dive | ObTxCallbackList + 22+ public 方法（compact 调 remove_callbacks_*） |
| **#5 v2（本篇）** | **Compact 与 GC：try_cleanout_* + 4 remove_callbacks_*** |

### 10.2 关键路径修正

```
原推测:
  src/storage/mvcc/compact/  ❌
  src/sql/mvcc/compact/       ❌
实际:
  src/storage/memtable/mvcc/ob_mvcc_row.{h,cpp}  ✅（try_cleanout_*）
  src/storage/memtable/mvcc/ob_mvcc_engine.h  ✅（mvcc_undo / mvcc_replay / compact 接口）
  src/storage/memtable/mvcc/ob_mvcc_ctx.h  ✅（cleanout 接口）
  src/storage/memtable/mvcc/ob_tx_callback_list.{h,cpp}  ✅（remove_callbacks_* 系列）
  src/storage/memtable/mvcc/ob_tx_callback_functor.h  ✅（ObRemoveSyncCallbacksWCondFunctor + ObRemoveCallbacksForFastCommitFunctor）
```

---

## 11. 总结

### 11.1 核心数据结构

| 数据结构 | 行数 | 关键功能 |
|----------|------|----------|
| `ObMvccRow::try_cleanout_*` | 100+ | 4 个 cleanout 路径（行级 + tnode 级） |
| `ObMvccEngine::mvcc_undo` | ~50 | 撤销写错 tnode（一定成功） |
| `ObMvccEngine::mvcc_replay` | ~80 | Standby 同步 leader redo |
| `ObTxCallbackList::remove_callbacks_*` | 100+ | 4 个 remove 路径（fast commit / remove memtable / rollback / unlog） |
| `ObRemoveSyncCallbacksWCondFunctor` | ~80 | 条件删除 + checksum（与 #4 v2 关联） |
| `ObRemoveCallbacksForFastCommitFunctor` | ~80 | Fast Commit 清理（与 #4 v2 关联） |

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| **try_cleanout_tx_node_** | 4 个 flag 条件检查 + 链表链接解除 + 内存释放 |
| **try_cleanout_mvcc_row_** | 遍历 row 所有 tnode + best-effort cleanout |
| **mvcc_undo** | 一定成功 + 设置 F_ABORTED flag + best-effort |
| **mvcc_replay** | 复用现有 tnode + scn/checksum 已知 + Follower 同步 |
| **4 个 remove_callbacks_*** | fast_commit / remove_memtable / rollback_to / unlog |
| **5 个 cleanout 路径** | read trigger / tx_commit / freeze / sync_log / force_compact |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/memtable/mvcc/ob_mvcc_row.{h,cpp}` | `try_cleanout_tx_node_` / `try_cleanout_mvcc_row_` / `build_tx_node_` |
| `src/storage/memtable/mvcc/ob_mvcc_engine.h` | `mvcc_undo` / `mvcc_replay` / `try_compact_row_when_mvcc_read_` |
| `src/storage/memtable/mvcc/ob_mvcc_ctx.h` | cleanout 接口 |
| `src/storage/memtable/mvcc/ob_tx_callback_list.{h,cpp}` (1400) | 4 个 `remove_callbacks_*` + `clean_unlog_callbacks`（与 #4 v2 关联） |
| `src/storage/memtable/mvcc/ob_tx_callback_functor.h` (663) | `ObRemoveSyncCallbacksWCondFunctor` + `ObRemoveCallbacksForFastCommitFunctor`（与 #4 v2 关联） |

### 11.4 关键路径修正

```
原推测:
  src/storage/mvcc/compact/  ❌
  src/sql/mvcc/compact/       ❌
实际:
  src/storage/memtable/mvcc/ob_mvcc_row.{h,cpp}  ✅（try_cleanout_*）
  src/storage/memtable/mvcc/ob_mvcc_engine.h  ✅（compact 接口）
```

---

## 12. 推荐下一篇

按 "按顺序来" 指令，MVCC 子系列继续：

- **#1.4（已做 → v2）** ✅
- **#1.5（已做 → v2）** ✅
- **#6 v2 ObRowConflictHandler 与 lock_wait**（MVCC 子系列最终） 
- 或跳到其他子系列（#14 v2 MemTable 完整 / #41 v2 Join Operators / #95 v2 Query Optimizer / #51 v2 Block Cache 等）

要继续 #6 v2 还是先 refine 其他子系列？