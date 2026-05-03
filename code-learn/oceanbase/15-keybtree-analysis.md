# 15-keybtree-analysis — ObKeyBtree：OceanBase 存储引擎的自研 B-Tree

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

B-Tree（或 B+Tree）是数据库存储引擎最基础的数据结构。OceanBase 的 Memtable 默认使用 Hash 索引（`ObMtHash`，见 14-memtable-internals），但代码中同时保留了一个**完整的自研 B-Tree 实现**——`ObKeyBtree`。

这个 B-Tree 不是教科书的简单搬运。它融合了：

- **Copy-on-Write（CoW）写入**——修改节点时复制一份，不阻塞读
- **Epoch-based Reclamation（基于纪元的延迟回收）**——安全释放旧节点
- **MultibitSet 索引层**——叶子节点无序排列 + 位图索引，实现原子插入
- **Per-node RWLock**——精细化的读写锁控制

代码量非常克制：头文件 `ob_keybtree.h` 仅 323 行，实现文件 `ob_keybtree.cpp` 仅 1787 行，deps 头文件 `ob_keybtree_deps.h` 约 650 行。

> **⚠️ 重要澄清**：源码注释明确写道 —— `"OceanBase's keybtree is a btree(we are not b+tree)"`（`ob_keybtree.h@L248`）。尽管名字叫"KeyBtree"，这棵树是 **B-Tree** 而非 B+Tree。内节点和叶子节点都存储 KV 对，区别仅在于叶子节点 level=0 且使用 MultibitSet 做无序索引，而内节点 level>0 且 KV 是有序的。

**doom-lsp 确认**：核心文件：

| 文件 | 行数 | 职责 |
|------|------|------|
| `storage/memtable/mvcc/ob_keybtree_deps.h` | ~650 | 依赖定义：BtreeNode、RWLock、MultibitSet、Handle 等 |
| `storage/memtable/mvcc/ob_keybtree.h` | 323 | ObKeyBtree 容器、BtreeIterator、BtreeRawIterator |
| `storage/memtable/mvcc/ob_keybtree.cpp` | 1787 | 所有模板方法实现 |

---

## 1. 设计动机

### 1.1 为什么自研 B-Tree 而不是用标准库？

1. **并发语义**：数据库 B-Tree 需要支持高并发无锁读 + 写入锁的组合，STL 的 `std::map` / `std::set` 完全不提供并发保证
2. **内存布局定制**：15 个 KV 对 / 节点（`NODE_KEY_COUNT = 15`），精确对齐到缓存行
3. **Copy-on-Write 策略**：写入不原地修改，而是创建新节点副本，写入完成后原子切换指针
4. **Epoch-based Reclamation**：和无锁读配合的延迟回收机制，非 STL 提供
5. **软删除 / 版本链集成**：B-Tree 的 Value 是 `ObMvccRow *`，是 MVCC 版本链的入口

### 1.2 与 Memtable Hash 索引的配合

`ObMemtable` 的 `use_hash_index_` 字段控制使用 Hash 还是 B-Tree：

```cpp
// ob_memtable.h@L582 — doom-lsp 确认
bool use_hash_index_;  // true=ObMtHash, false=ObKeyBtree
```

默认走 Hash 索引（O(1) 行级查找）。B-Tree 在以下场景有价值：
- **范围扫描**（Hash 不支持有序遍历）
- **历史兼容**（早期版本无 Hash 索引）

---

## 2. 核心数据结构

### 2.1 BtreeKV：KV 对 (`ob_keybtree_deps.h@L28`)

```cpp
template<typename BtreeKey, typename BtreeVal>
struct BtreeKV
{
  BtreeKey key_; // 8byte
  BtreeVal val_; // 8byte
};
```

**关键约束**：Key 和 Value 都必须 **8 字节**，且 Value 的低 3 位必须为 0。因为 Value 常被用作指针（指向 `ObMvccRow` 或子节点），低 3 位为 0 确保指针对齐。

### 2.2 BtreeNode：B-Tree 节点 (`ob_keybtree_deps.h@L179`)

```cpp
class BtreeNode {
  void *host_;              // 8byte — 所属 ObKeyBtree
  int16_t level_;           // 2byte — 0=leaf, >=1=internal
  uint16_t magic_num_;      // 2byte — 魔数 0xb7ee
  RWLock lock_;             // 4byte — 读写锁
  MultibitSet index_;       // 8byte — 叶子节点的位置索引
  BtreeKV kvs_[15];         // 240byte — 15 个 KV 对
};
```

**`BtreeNode` 总大小**：`8 + 2 + 2 + 4 + 8 + 240 = 264 字节`，约 4 个缓存行（64 字节/行）。

`prefetch()` 方法（`ob_keybtree_deps.h@L267`）在遍历时预取整个节点到缓存：

```cpp
void prefetch() {
  constexpr int64_t cache_line_cnt = (sizeof(*this) - 1) / CACHE_ALIGN_SIZE + 1;
  for (int64_t i = 0; i < cache_line_cnt; i++) {
    __builtin_prefetch((const char *)this + i * CACHE_ALIGN_SIZE, 0, 3);
  }
}
```

#### 叶子节点 vs 内节点

`is_leaf()` 由 `level_ == 0` 判断。关键差异：

| 特性 | 叶子节点 (level=0) | 内节点 (level>=1) |
|------|-------|---------|
| KV 顺序 | **无序**（通过 index_ 定位） | **有序**（物理位置即逻辑位置） |
| `index_` 使用 | 存储逻辑→物理的映射 | 仅存计数 |
| Value 类型 | 数据指针（如 `ObMvccRow *`） | 子节点指针 |
| `size()` 取值 | 从 `index_` 读取 | 从 `index_` 的 count 字段读取 |

### 2.3 MultibitSet：64 位位置索引 (`ob_keybtree_deps.h@L103`)

这是实现**无锁叶子节点插入**的关键创新。MultibitSet 是一个 64 位位图：

```
 63      60 59    56 ...  8  7   4  3   0
┌─────────┬─────────┬───┬─────┬─────┬─────┐
│ pos_14  │ pos_13  │…  │pos_1│pos_0│count│
└─────────┴─────────┴───┴─────┴─────┴─────┘
  4bits     4bits          4bits  4bits  4bits
```

- **低 4 位**：计数器（`count`），最多 15
- **之后每 4 位**：物理位置索引（position 0-14）
- **总数**：4 + 15 × 4 = 64 位，恰好填满一个 `uint64_t`

**为什么是 15 个 KV 对？**（`ob_keybtree_deps.h@L37-L43`）

```
2^4 = 16 种位置，4 bits/position × 16 个 = 64 bits = 8 bytes
但我们用 4 bits 做计数，剩下 60 bits 只能放 15 个位置（15 × 4 = 60）
```

这是一个**优雅的精确匹配**：15 个 KV 对正好填满 64 位 `MultibitSet`。

**无锁插入的关键**：当往叶子节点插入一个新 KV 时，先物理追加到 `kvs_[count]` 位置，然后通过 `free_insert()` 方法原子更新 MultibitSet（`ob_keybtree_deps.h@L127`）：

```cpp
bool free_insert(int index, uint8_t value) {
  MultibitSet old_v;
  old_v.load(*this);
  MultibitSet new_v(cal_index_(old_v, index, value));
  return ATOMIC_BCAS(&data_, old_v.data_, new_v.data_);
}
```

`cal_index_()` 在已有位置数组中插入一个新位置，所有后续位置的索引自动右移。整个操作是原子的 `CAS`（Compare-And-Swap）—— 如果其他线程同时修改，CAS 会失败并重试。

### 2.4 RWLock：32 位读写锁 (`ob_keybtree_deps.h@L57`)

```cpp
union {
  struct {
    int16_t read_ref_;    // 读引用计数（高 16 位）
    uint16_t writer_id_;  // 写者线程 ID（低 16 位）
  };
  uint32_t lock_;
};
```

- **读锁**：`try_rdlock()` 检查 writer_id 是否为 0，然后读引用计数 +2
- **写锁**：`try_wrlock(uid)` CAS 写入 writer_id，等待 read_ref_ 降为 1（即只有当前线程持有）
- `set_spin()`：将 read_ref_ 置 1，指示写者在等待

这种锁设计使得读锁获取只需要检查写者位，是无锁读的重要辅助。

### 2.5 Path：搜索路径 (`ob_keybtree_deps.h@L345`)

```cpp
class Path {
  int64_t depth_;           // 当前深度
  Item path_[MAX_DEPTH];    // MAX_DEPTH = 16
  bool is_found_;           // 是否精确命中
};
```

`Path` 记录从根到当前节点的完整路径（节点指针 + 在该节点中的位置）。这对**分裂传播**至关重要——当叶子节点分裂时，需要顺着 path 向上回溯修改父节点。

`MAX_DEPTH = 16` 意味着最多支持 16 层 B-Tree，以扇出 15 计算，可容纳约 `15^16 ≈ 6.5×10^18` 个记录，远超任何实际需求。

---

## 3. 核心操作分析

### 3.1 插入：insert

```
ObKeyBtree::insert(key, value)              → ob_keybtree.cpp
  │
  ├─ WriteHandle handle(*this)              → 创建写入句柄
  ├─ handle.acquire_ref()                   → 进入临界区（epoch 保护）
  │
  └─ 循环（OB_EAGAIN 重试）：
       │
       ├─ ATOMIC_LOAD(&root_)               → 快照当前根节点
       ├─ handle.find_path(root, key)        → 从 root 到 leaf 的搜索
       │    │
       │    └─ 逐层调用：
       │         BtreeNode::find_pos()       → 二分搜索定位
       │         path_.push(node, pos)       → 记录路径
       │
       ├─ handle.insert_and_split_upward()  → 插入 + 分裂传播
       │    │
       │    ├─ path_.pop(old_node, pos)      → 取到叶子节点
       │    │
       │    ├─ insert_into_node():
       │    │    │                    ┌─────────────────────┐
       │    │    ├─ 不溢出时：       │ 物理追加 + CAS 更新 │
       │    │    │                    │ index_              │
       │    │    │                    └─────────────────────┘
       │    │    │
       │    │    └─ 溢出时：调用 split_child()
       │    │         ├─ split_child_no_overflow()         → 生成 1 个新节点
       │    │         └─ split_child_cause_recursive_split()→ 生成 2 个新节点
       │    │
       │    └─ 分裂传播循环：
       │         ├─ 有 1 个新节点 → 替换父节点的子指针（ReplaceChild）
       │         ├─ 有 2 个新节点 → 分裂父节点（split_child）
       │         └─ 无父节点 → make_new_root（树长高一层）
       │
       ├─ root 变更时：ATOMIC_BCAS(&root_, old_root, new_root)
       │   └─ 失败 → OB_EAGAIN → 重试整个流程
       │
       └─ 重试时：handle.free_list()        → 清理临时分配
```

**insert_into_node 的并发语义**（`ob_keybtree.cpp`）：

```cpp
if ((count = old_node->size()) != this->index_.size()) {
  // 另一个线程已经完成了插入，我们的 index_ 快照过时了
  ret = OB_EAGAIN;
}
```

这里使用 `index_` 的**快照机制**做乐观并发控制：`WriteHandle` 在 `find_path` 时保存了叶子节点的 `index_` 快照。如果在获取写锁前，其他线程已经修改了该节点（`size()` 变了），则返回 `OB_EAGAIN` 通知调用者重试。这是典型的 **optimistic concurrency** 模式。

### 3.2 查询：get

```
ObKeyBtree::get(key, value)                → ob_keybtree.cpp
  │
  ├─ GetHandle handle(*this)               → 只读句柄
  ├─ handle.acquire_ref()                  → 进入临界区
  └─ handle.get(root_, key, value):
       │
       └─ while(OB_ISNULL(leaf)):
            ├─ root->find_pos(key, is_found, pos)  → 二分搜索
            ├─ pos < 0 → OB_ENTRY_NOT_EXIST
            ├─ root->is_leaf() → leaf = root
            └─ 否则 → root = root->get_val(pos)    → 下探
```

**查询不需要任何锁**。它直接读取 `ATOMIC_LOAD(&root_)` 获得根节点指针，然后逐层向下遍历。每个节点的 KV 使用 `ATOMIC_LOAD`（`get_val()` in deps.h）读取，保证读到一致的值。

### 3.3 删除：del？

`ObKeyBtree` **没有实现显式的删除操作**。数据删除通过 MVCC 机制处理：将 `ObMvccRow` 标记为已删除（compact/cleanout 阶段处理），B-Tree 中的 KV 对不会被物理移除。

这是 OceanBase 的典型设计——Memtable 只追加不删除（类似 LSM-Tree 的写入模式），物理回收由后续的合并（Major Compaction）完成。

---

## 4. 并发控制深度分析

### 4.1 无锁读（Lock-Free Read）

读路径完全无锁：

```
Reader:
  ├─ acquire_ref() → QClock.enter_critical()  → 声明进入临界区
  ├─ ATOMIC_LOAD(&root_)                      → 获取当前根
  ├─ 遍历：节点指针通过 ATOMIC_LOAD 读取       → 不获取任何锁
  └─ release_ref() → QClock.leave_critical()  → 离开临界区
```

读操作只使用 `ATOMIC_LOAD` 原语，不获取任何节点锁。这就是注释中说的 `"uses the techniques of epoch based reclaimation and Copy-on-Write to allow the high capibility under high concurrency"`（`ob_keybtree.h@L249`）。

### 4.2 Copy-on-Write 写入

写入操作使用 CoW 策略：

```
Writer:
  ├─ 写入节点前：
  │   try_wrlock(old_node)                    → 获取写锁
  │   retire_list_.push(old_node)             → 加入退役列表
  │
  ├─ 插入/分裂时：
  │   alloc_node()                            → 从分配器获取新节点
  │   alloc_list_.push(new_node)              → 加入分配列表
  │   new_node 复制 old_node 的数据            → 在新节点上修改
  │
  └─ 完成后：
        ├─ ATOMIC_BCAS(&root_, old, new)      → CAS 切换根指针
        ├─ retire(ret)                        → 成功：退役旧节点
        └─ free_list()                        → 失败：释放新节点
```

**关键特点**：写操作不阻塞读。读操作读取的是旧节点的快照，写入完成后 CAS 切换指针，后续读操作自然看到新节点。旧节点在确认所有活跃读操作都完成后才被回收。

### 4.3 Epoch-based Reclamation 体系

```
┌──────────────────────────────────────────────────┐
│                   QClock                          │
│  (全局单调时钟，enter_critical / leave_critical)   │
└───────────┬──────────────────────┬────────────────┘
            │                      │
            ▼                      ▼
┌───────────────────┐   ┌──────────────────────┐
│   RetireStation   │   │      ObQSync          │
│  (延迟回收管理器)  │   │  (quiescent state 同步)│
└───────────┬───────┘   └──────────────────────┘
            │
            ▼
┌───────────────────┐
│    HazardList      │
│ (待退役节点链表)   │
└───────────────────┘
```

工作流程：

1. **写操作**在修改节点前，将旧节点通过 `retire_list_.push(node)` 加入 HazardList
2. 写入成功后调用 `ObKeyBtree::retire(handle.retire_list_)`：
   - 进入 `CriticalGuard` 保护
   - 调用 `get_retire_station().retire(reclaim_list, retire_list)`
   - `retire_list` 中的节点被放入 RetireStation
   - 从 RetireStation 取回 **可以安全释放** 的节点（已无活跃读者）
   - `free_node(p)` 释放回分配器

3. `CriticalGuard(get_qsync())` 确保在这个线程处于 "critical section" 时，全局 quiescent 状态检查不会误判

4. `WaitQuiescent(get_qsync())` 等待所有已进入临界区的线程离开

### 4.4 写入重试机制

`ObKeyBtree::insert()` 使用 `OB_EAGAIN` 重试循环（`ob_keybtree.cpp`）：

```cpp
while (OB_EAGAIN == ret) {
  // 1. 获取当前 root
  old_root = ATOMIC_LOAD(&root_);
  // 2. 搜索路径
  handle.find_path(old_root, key);
  // 3. 尝试插入（可能失败）
  handle.insert_and_split_upward(key, value, new_root);
  // 4. 如果 root 变更，CAS 尝试更新
  if (old_root != new_root) {
    if (!ATOMIC_BCAS(&root_, old_root, new_root)) {
      ret = OB_EAGAIN;
    }
  }
  // 5. 重试前清理
  if (OB_EAGAIN == ret) {
    handle.free_list();
  }
}
```

触发重试的场景：
- 另一个线程在插入路径中先完成了修改（index_ 快照过时）
- CAS 更新 root 时冲突
- 节点分裂过程中读到的 index_ 不一致

---

## 5. 遍历与批量操作

### 5.1 Iterator (`ob_keybtree_deps.h@L588`)

```cpp
class Iterator {
  const ObKeyBtree &btree_;
  ScanHandle scan_handle_;    // 扫描句柄
  BtreeKey* jump_key_;        // 跳转键（比较优化）
  int cmp_result_;            // 缓存比较结果
  CompHelper &comp_;
  BtreeKey start_key_, end_key_;
  bool start_exclude_, end_exclude_;
  bool scan_backward_;        // 反向扫描
  bool is_iter_end_;          // 迭代结束标志
};
```

**扫描流程**：

```
Iterator::set_key_range(min_key, max_key)
  │
  ├─ scan_handle_.acquire_ref()           → 进入临界区
  └─ scan_handle_.find_path(root, min_key)→ 定位起始位置
       │
       └─ 逐层下探，每层记录 path：
            ├─ 如果 key 存在 → pos = 0（当前位置）
            └─ 如果 key 不存在 → 在大于 key 的最小位置
```

```
Iterator::get_next(key, value)
  │
  ├─ scan_handle_.get(key, value, backward, jump_key)
  │   └─ 从 path 中 pop 出当前位置的 KV
  │
  ├─ comp(key, jump_key, cmp)     → 与 end_key 比较
  │   ├─ cmp < 0  → 超出范围 → OB_ITER_END
  │   ├─ cmp > 0  → scan_forward() / scan_backward() 移动到下一节点
  │   └─ cmp == 0 → 到达 end_key
  │
  └─ scan_forward():
       ├─ path_.pop(node, pos)           → 弹出当前层
       ├─ pos = get_next_active_child(pos)→ 移动到下一个同级位置
       └─ 下探到下一层（如果非叶子节点）
```

**比较优化**（`comp()`）：每次比较 `jump_key_`（当前叶子节点的最后一个 key）与 `end_key_`。如果 `jump_key_` 没变，复用 `cmp_result_`，避免昂贵的行键比较。

### 5.2 BtreeIterator：批量队列 (`ob_keybtree.h@L146`)

`BtreeIterator` 在 `Iterator` 之上封装了一个 **KV 队列**（KVQueue），容量 225 个 KV：

```
BtreeIterator::get_next()
  │
  ├─ kv_queue_.pop(item)    → 优先从缓存队列取
  ├─ 队列为空时 → scan_batch() → 批量扫描 225 个 KV 到队列
  └─ 返回队列中的下一个 KV
```

`scan_batch()`（`ob_keybtree.cpp`）：

```cpp
int scan_batch() {
  iter_->set_key_range(start_key_, start_exclude_, end_key_, end_exclude_);
  while (true) {
    iter_->get_next(item.key_, item.val_);
    kv_queue_.push(item);         // 填满队列（最多 225 个）
    start_key_ = item.key_;       // 更新断点
    start_exclude_ = true;
  }
  iter_->reset();  // 扫描完一批后释放内部 iterator 的临界区
}
```

**设计的精妙之处**：`BtreeIterator` 可以在不持有临界区锁的情况下长时间存活。它批量扫描一批 KV 到队列后立即释放 `Iterator`（`iter_->reset()`），释放临界区。消费者从队列中消费完这批 KV 后，再从断点继续扫描。这避免了长连接扫描阻塞写入。

### 5.3 BtreeRawIterator：无缓存迭代器 (`ob_keybtree.h@L219`)

`BtreeRawIterator` 是对 `Iterator` 的薄包装，不提供 KV 缓存。主要用于**行数估算**和**范围切分**：

```cpp
// 估算元素数量
int estimate_element_count(int64_t &physical_row_count, int64_t &element_count);

// 切分范围（用于并行扫描）
int split_range(int64_t top_level, int64_t btree_node_count,
                int64_t range_count, ObIArray<BtreeKey> &key_array);
```

`estimate_element_count` 使用采样策略：最多采样 500 个叶子节点，然后通过上层节点估算总量。

---

## 6. 节点分配器：BtreeNodeAllocator (`ob_keybtree.h@L78`)

分配器的设计体现了 OceanBase 对 CPU 缓存亲和性的极致追求：

```
BtreeNodeAllocator
  │
  ├─ free_list_array_[64]          → CPU 数分区
  │   └─ 每个分区是一个 BtreeNodeList（无锁链表）
  │
  ├─ push_idx / pop_idx → RLOCAL 变量 + icpu_id() 获取
  │   └─ 确保线程尽量操作本地分区（CPU cache 友好）
  │
  └─ 批量分配（NODE_COUNT_PER_ALLOC = 128）：
       ├─ 从底层 allocator 分配 128 × sizeof(BtreeNode) 连续内存
       ├─ 在内联构造 128 个 BtreeNode
       ├─ 按比例（1024/64=16）分布到所有 64 个 free list 中
       └─ 返回第一个节点
```

**CPU 分区分配策略**：每个线程优先从自己的 CPU 对应的 free list 中 pop 节点。当 free list 为空时，批量分配新节点并**均匀分布到所有 64 个 free list 中**，确保后续所有线程都能从自己的分区获取节点，减少 false sharing。

### BtreeNodeList：无锁链表 (`ob_keybtree.h@L58`)

```cpp
void bulk_push(first, last) {
  tail = ATOMIC_TAS(&tail_, LOCK);    // 自旋锁获取
  last->next_ = tail;
  ATOMIC_STORE(&tail_, first);        // LOCK 位清零
}

pop() {
  if (ATOMIC_LOAD(&tail_)) {
    tail = ATOMIC_TAS(&tail_, LOCK);  // 自旋锁获取
    ATOMIC_STORE(&tail_, tail->next_);
  }
  return tail;
}
```

使用**最低位作为锁标志位**（`LOCK = ~0UL`），通过 `ATOMIC_TAS`（Test-And-Set）实现自旋锁。

---

## 7. ASCII 图解

### 7.1 B-Tree 结构

```
                           ┌──────────────────┐
                           │   ObKeyBtree     │
                           │   root_ ─────────┼────►
                           │   split_info_    │
                           │   size_          │
                           └──────────────────┘

         ┌────────────────────────────────────────────────────┐
         │         BtreeNode (Internal, level=2)             │
         │  ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┐    │
         │  │ K0  │ K1  │ K2  │ K3  │ K4  │ ... │ K14 │    │
         │  │ P0  │ P1  │ P2  │ P3  │ P4  │     │ P14 │    │
         │  └──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬───┴──┘    │
         │  index_ = count 15                                │
         └─────┼──────┼──────┼──────┼──────┼──────┼─────────┘
               │      │      │      │      │      │
    ┌──────────┘      │      │      │      │      └──────────┐
    ▼                 ▼      ▼      ▼      ▼                 ▼
┌──────────┐   ┌──────────┐                         ┌──────────┐
│ Internal │   │ Internal │      ...                 │ Internal │
│ level=1  │   │ level=1  │                         │ level=1  │
└─────┬────┘   └─────┬────┘                         └─────┬────┘
      │               │                                    │
    ┌─┼───┐       ┌───┼───┐                            ┌───┼───┐
    ▼ ▼   ▼       ▼   ▼   ▼                            ▼   ▼   ▼
┌────┐┌────┐┌────┐                                     ┌────┐┌────┐
│Leaf││Leaf││Leaf│     ... (N 个叶子节点)               │Leaf││Leaf│
└──┬─┘└────┘└────┘                                     └──┬─┘└────┘
   │  next_ ─────► next_ ─────► ... ─────► next_ ──► next_
   └──────────────── 叶子链表（水平连接）────────────────────┘
```

### 7.2 叶子节点内部结构

```
叶子节点 (level=0):
┌─────────────────────────────────────────────────────────────┐
│ host_ │ level_ │ magic_ │ RWLock │  index_  │  kvs_[15]    │
│ 8byte │  2byte │  2byte │ 4byte  │  8byte   │  240byte     │
└─────────────────────────────────────────────────────────────┘

MultibitSet 展开：
┌────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┐
│ C  │ P0 │ P1 │ P2 │ P3 │ P4 │ P5 │ P6 │ P7 │ P8 │ P9 │P10 │P11 │P12 │P13 │P14 │
│4bit│4bit│4bit│4bit│4bit│4bit│4bit│4bit│4bit│4bit│4bit│4bit│4bit│4bit│4bit│4bit│
└────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘

例如 count=3, 位置映射: P0=2, P1=5, P2=0
→ 逻辑位置 0 → kvs_[2], 逻辑位置 1 → kvs_[5], 逻辑位置 2 → kvs_[0]
```

### 7.3 搜索路径图

```
搜索 key = "XYZ"：

ObKeyBtree::get("XYZ")
  │
  ├─ ATOMIC_LOAD(&root_) → 节点 A
  │
  ├─ find_pos(A, "XYZ") → 二分搜索，找到区间在内节点 B
  │
  ├─ ATOMIC_LOAD(&A->kvs_[pos].val_) → 节点 B
  │
  ├─ find_pos(B, "XYZ") → 找到区间在内节点 E
  │
  ├─ ATOMIC_LOAD(&B->kvs_[pos].val_) → 节点 E
  │
  └─ find_pos(E, "XYZ") → 叶子节点，找到或返回 OB_ENTRY_NOT_EXIST

路径（无需锁，全程 ATOMIC_LOAD）：
  Root → Node A (level=2) → Node B (level=1) → Node E (level=0, leaf)
```

### 7.4 插入与分裂流程图

```
插入 key="XYZ", value=V:

  ┌─────────────┐
  │  Root A     │
  │ [K0] [K1]   │   level=1
  └──┬───┬──────┘
     │   │
  ┌──▼┐ ┌▼──┐
  │ B │ │ C │        leaf
  └───┘ └───┘

Step 1: find_path("XYZ") → path = [A→B]
Step 2: B 已满（size=15），触发分裂
Step 3: 分配 B1, B2，将 B 的 KV 拆分到 B1/B2
Step 4: 在 B1 或 B2 中插入 ("XYZ", V)
Step 5: 回溯到 A：
        └─ 替换 B 的指针为 B1，插入 B2 的指针和分隔键
Step 6: 如果 A 也满了：
        └─ 分裂 A 为 A1, A2，创建新根 R→[A1, A2]
        └─ ATOMIC_BCAS(&root_, A, R)

最终状态：
  ┌──────────────┐
  │   Root A_new │
  │ [K0][K_new][K1]│     level=1
  └──┬────┬──────┘
     │    │
  ┌──▼┐ ┌▼──┐ ┌▼──┐
  │B1 │ │B2 │ │ C │     leaf
  └───┘ └───┘ └───┘
```

---

## 8. 文件与 SSTable Index Block 的关系

虽然 `ObKeyBtree` 主要用于 Memtable，但 B-Tree 结构在 OceanBase 的**SSTable Index Block** 中也有相似应用。主要区别：

| 方面 | ObKeyBtree (Memtable) | SSTable Index Block |
|------|----------------------|---------------------|
| 数据变异 | 频繁写入 | 只读（SSTable 不可变） |
| 并发策略 | CoW + Epoch | 无并发需求 |
| 节点大小 | 15 KV / 节点 | 一般更大（块级索引） |
| 回收策略 | RetireStation | 直接释放（SSTable 销毁时） |

两者的共同点是都使用 **有序树结构** 支持范围查询。Memtable B-Tree 提供了内存中的有序索引，Compaction 时转换为 SSTable 的 Index Block。

---

## 9. 设计决策总结

### 9.1 为什么用 B-Tree 而非 B+Tree？

这是源码最让人意外的设计决定。B+Tree 在传统数据库存储中更常见（数据只在叶子节点，内节点只存键），但 OceanBase 的 `ObKeyBtree` 选择 B-Tree：

- **内节点也存数据**：内节点的 KV 中也包含数据（Value 为 `ObMvccRow *`），这在内节点较少时可以提高空间利用率
- **简化分裂逻辑**：B-Tree 的 Copy-on-Write 策略中，内节点不需要专门处理叶子链表变更
- **叶子链接**：虽然用了 B-Tree，但 `BtreeNode::next_` 指针为叶子节点提供了水平链接，支持范围扫描

### 9.2 15 KV 对 / 节点的扇出选择

扇出 15 完全由 MultibitSet 的 64 位容量决定。15 的扇出意味着：

- **树高 4 层**可容纳约 `15^4 ≈ 50,625` 个记录
- **树高 6 层**可容纳约 `15^6 ≈ 11,390,625` 个记录
- **树高 10 层**可容纳约 `15^10 ≈ 5.7×10^11` 个记录

Memtable 的典型大小在几百万到几千万行，树高 4-6 层即够用。

### 9.3 无锁读 + 写入锁的组合

这套策略的核心权衡：

| 方面 | 优点 | 缺点 |
|------|------|------|
| 读操作 | 完全无阻塞，原子读取 | 只能看到旧版本快照（但不违反 MVCC） |
| 写操作 | 不阻塞读 | CoW 分配和复制有开销 |
| 内存 | 读操作可以安全持有指针 | 节点延迟回收，内存占用更大 |
| 写冲突 | CAS 失败后优雅重试 | 高冲突下重试开销大 |

### 9.4 Epoch-based Reclamation

相较于传统的 RCU（Read-Copy-Update），OceanBase 的 EBR 实现：

- **Quiescent 状态**：通过 `ObQSync` 跟踪
- **Critical Section**：`QClock::enter_critical()` / `leave_critical()`
- **RetireStation**：管理延迟回收的生命周期

这使得无锁读成为可能——读者进入临界区后，即使写者 CAS 切换了指针，旧节点也不会被立即释放。

### 9.5 为什么没有显式删除

Memtable 的"删除"由 MVCC 的行级删除标记处理，B-Tree 层面不做物理删除。这带来了：

- **简化实现**：不需要节点合并逻辑（教科书 B-Tree 删除的一半复杂度）
- **写放大可接受**：Memtable 本身是短期内存结构，最终会被冻结和转储
- **搜索性能**：已删除的行会被 MVCC 过滤掉，但 B-Tree 中仍然存在，不影响正确性

---

## 10. 源码索引

| 符号 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `ObKeyBtree` | `ob_keybtree.h` | 248 | 顶级 B-Tree 容器 |
| `BtreeNode` | `ob_keybtree_deps.h` | 179 | B-Tree 节点 |
| `BtreeKV` | `ob_keybtree_deps.h` | 28 | KV 对 |
| `BtreeNodeList` | `ob_keybtree.h` | 58 | 无锁链表 |
| `BtreeNodeAllocator` | `ob_keybtree.h` | 78 | CPU 分区节点分配器 |
| `MultibitSet` | `ob_keybtree_deps.h` | 103 | 64 位位置索引 |
| `RWLock` | `ob_keybtree_deps.h` | 57 | 32 位读写锁 |
| `Path` | `ob_keybtree_deps.h` | 345 | 搜索路径 |
| `BaseHandle` | `ob_keybtree_deps.h` | 404 | 基类 Handle（临界区管理） |
| `GetHandle` | `ob_keybtree_deps.h` | 431 | 读取句柄 |
| `ScanHandle` | `ob_keybtree_deps.h` | 444 | 扫描句柄 |
| `WriteHandle` | `ob_keybtree_deps.h` | 479 | 写入句柄（含分裂逻辑） |
| `Iterator` | `ob_keybtree_deps.h` | 588 | 迭代器 |
| `BtreeIterator` | `ob_keybtree.h` | 146 | 带队列缓存的迭代器 |
| `BtreeRawIterator` | `ob_keybtree.h` | 219 | 原生迭代器 |
| `insert()` | `ob_keybtree.cpp` | — | 插入入口（含重试循环） |
| `get()` | `ob_keybtree.cpp` | — | 无锁读取 |
| `insert_and_split_upward()` | `ob_keybtree.cpp` | — | 插入 + 分裂传播 |
| `insert_into_node()` | `ob_keybtree.cpp` | — | 乐观并发插入 |
| `scan_batch()` | `ob_keybtree.cpp` | — | BtreeIterator 批量扫描 |
| `NODE_KEY_COUNT` | `ob_keybtree_deps.h` | 43 | 每节点 15 KV 对 |
| `MAX_CPU_NUM` | `ob_keybtree_deps.h` | 36 | 最大 CPU 数（分配器分区） |

---

## 11. 小结

`ObKeyBtree` 是 OceanBase 中一个被 Hash 索引掩盖但设计精良的自研 B-Tree。它的核心技术在于：

1. **MultibitSet** —— 64 位位图实现叶子节点的原子插入和逻辑重排
2. **Copy-on-Write** —— 写入不阻塞读，通过 CAS 原子切换指针
3. **Epoch-based Reclamation** —— 安全的延迟内存回收，无锁读的基石
4. **CPU 分区分配器** —— 减少 false sharing，提升并发伸缩性
5. **KV 队列缓存** —— 支持长时间存活迭代器而不阻塞写入

虽然 Memtable 默认使用 Hash 索引（O(1) 随机读取），但 B-Tree 实现的优雅和对并发的深入思考，使它成为 OceanBase 存储引擎中值得深入研读的组件。
