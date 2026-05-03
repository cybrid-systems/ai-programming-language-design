# 55-lockfree — OceanBase 无锁数据结构：ObLink、LF FIFO、HazardList、RetireStation

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前 54 篇文章覆盖了 OceanBase 引擎栈的各个层面，其中第 45 篇文章深入分析了 Latch 体系——一套完整的有锁并发基础设施。但数据库系统的核心场景（索引查找、日志写入、内存分配）对性能有极端要求，**无锁并发**成为了绕不开的课题。

OceanBase 在 `deps/oblib/src/lib/` 中构建了四层无锁基础设施：

| 层 | 文件 | 核心类/函数 | 职责 |
|----|------|------------|------|
| **侵入式链表** | `queue/ob_link.h` | `ObLink`、`ObDLink`、`link_insert/del` | 无锁链表原子操作 (CAS + mark) |
| **Hazard Pointer** | `hash/ob_hazard_pointer.h` | `ObHazardPointer` | 经典 HP 算法：读保护 + 延迟回收 |
| **Hazard Ref** | `allocator/ob_hazard_ref.h` | `HazardRef`、`RetireList`、`HazardHandle` | 升级版：版本号 + 引用计数 + 两阶段退役 |
| **Retire Station** | `allocator/ob_retire_station.h` | `QClock`、`HazardList`、`RetireStation` | Epoch-based Reclamation (EBR) 实现 |
| **LF FIFO Alloc** | `allocator/ob_lf_fifo_allocator.h` | `ObLfFIFOAllocator` | 无锁 FIFO 内存分配器 |

### 为什么需要无锁？

数据库引擎的典型场景：

- **读多写少**：B+-tree 索引查找中，读操作远多于插入/删除。Latch 会让所有读线程串行化
- **高并发内存分配**：每个请求都需要小对象分配，全局锁分配器是瓶颈
- **日志写入路径**：事务日志的提交和后续回收，需要安全的延迟回收机制

无锁的核心矛盾：**读线程正在访问的内存，写线程不能立即释放**。Hazard Pointer、EBR、RCU 都是这个问题的不同解法。

---

## 1. 底层构建块 — ObLink 无锁链表

### 1.1 ObLink — 单链表节点 (queue/ob_link.h)

`queue/ob_link.h` 中的 `ObLink` 是最基础的构建块：

```cpp
// queue/ob_link.h — 第 25-33 行
struct ObLink
{
  ObLink() : next_(NULL) {}
  ~ObLink() { next_ = NULL; }
  ObLink *next_;          // 指向下一个节点
  void reset() { next_ = NULL; }
  bool is_deleted() const { return ((uint64_t)next_) & 1; }  // 最低位 = 删除标记
};
```

关键设计：**最低位 (LSB) 作为删除标记**。

- 正常指针 → `next_` 的最低一位为 0
- 已删除 → 通过 `set_last_bit()` 将 `next_` 的最低位置 1
- 读线程通过 `clear_last_bit()` 获取真实指针

#### 核心操作：`link_insert`

```cpp
// queue/ob_link.h — 第 70-73 行
inline ObLink *link_insert(ObLink *prev, ObLink *target, ObLink *next)
{
  target->next_ = next;
  return ATOMIC_VCAS(&prev->next_, next, target);
}
```

使用原子 CAS（Compare-And-Swap）尝试将 `target` 插入到 `prev` 之后。如果 `prev->next_` 仍指向 `next`，则插入成功；否则说明其他线程已修改，返回旧值，调用方重试。

#### 核心操作：`link_del`

```cpp
// queue/ob_link.h — 第 78-87 行
inline ObLink *link_del(ObLink *prev, ObLink *target, ObLink *&next)
{
  ObLink *ret = NULL;
  if (!is_last_bit_set((uint64_t)(next = (ObLink *)set_last_bit((uint64_t *)(&target->next_))))) {
    if (target != (ret = ATOMIC_VCAS(&prev->next_, target, next))) {
      unset_last_bit((uint64_t *)(&target->next_));
    }
  }
  return ret;
}
```

删除分为两步：

1. **标记 (mark)**：使用 `set_last_bit()` 将 `target->next_` 的最低位置 1，表示"正在被删除"。CAS 循环保证原子性
2. **物理删除 (CAS)**：通过 CAS 将 `prev->next_` 从 `target` 更新为 `target` 的下一个节点。如果 CAS 失败，恢复 `target->next_` 的标记

这种 **"先标记后删除"** 的策略是数据库无锁链表的经典模式。标记位的作用：

- 其他线程发现标记后不会使用该节点
- 避免了 ABA 问题的一个来源：被标记的节点无法被重复插入

#### 搜索模板：`ol_search` / `ol_insert` / `ol_del`

```cpp
// queue/ob_link.h — 第 92-101 行
template<typename T>
T *ol_search(T *start, T *key, T *&prev)
{
  T *next = NULL;
  prev = start;
  while (NULL != (next = (T *)link_next(prev))
         && next->compare(key) < 0) {
    prev = next;
  }
  return next;
}
```

`ol_search` 在有序列表中查找插入位置或目标节点，返回 `prev`（前驱）和 `next`（目标/后继）。`ol_insert` 和 `ol_del` 在 CAS 失败时自动重试：

```cpp
// queue/ob_link.h — 第 207-211 行
template<typename T>
int ol_insert(T* start, T* target)
{
  int err = 0;
  while(-EAGAIN == (err = _ol_insert(start, target)))
    ;
  return err;
}
```

这种 **"如果 CAS 失败就重试"** 的模式，是无锁数据结构的最基础实现。

### 1.2 ObDLink — 双向链表 (queue/ob_link.h)

`ObDLink` 继承自 `ObLink`，增加了 `prev_` 指向前驱：

```cpp
// queue/ob_link.h — 第 234-243 行
struct ObDLink: public ObLink
{
  ObDLink(): ObLink(), prev_(NULL) {}
  ~ObDLink() {}
  void reset() { ObLink::reset(); prev_ = NULL; }
  ObDLink* prev_;
};
```

双向链表的无锁操作更加复杂，因为必须维护 `prev_` 指针的一致性。`dl_insert` 先设置 `target->prev_` 再 CAS，并在 CAS 成功后续通过 `try_correct_prev_link` 修正后继节点的 `prev_`：

```cpp
// queue/ob_link.h — 第 269-278 行
inline int dl_insert(ObDLink* prev, ObDLink* target)
{
  int err = 0;
  target->prev_ = prev;
  while(true) {
    ObLink* next = link_next(prev);
    if (next == link_insert(prev, target, next)) {
      try_correct_prev_link((ObDLink*)next, target);  // 修正后继 prev_
      break;
    }
  }
  return err;
}
```

### 1.3 侵入式链表的使用

`HazardList` (在 `ob_retire_station.h` 中) 直接使用 `ObLink` 作为节点类型：

```cpp
// ob_retire_station.h — 第 120-121 行
class HazardList
{
public:
  typedef ObLink Link;
```

HazardList 的 `push`/`pop` 操作（第 129-145 行）是简单的有锁单链表操作（因为仅在单线程的退役过程中使用），但节点本身（`ObLink`）可以被外部的无锁链表操作。

---

## 2. Hazard Pointer — 读取者的保护伞

Hazard Pointer 是一种经典的无锁内存回收算法，由 Maged M. Michael 在 2004 年提出。核心思想：

> **每个读线程声明自己正在使用的指针（hazard pointer）。写线程在释放内存前，检查所有读线程的 hazard pointer，如果指针仍被引用则延迟释放。**

### 2.1 ObHazardPointer (hash/ob_hazard_pointer.h)

```cpp
// ob_hazard_pointer.h — 第 25-36 行
class ObHazardPointer
{
public:
  // 回调接口：实际释放回收的内存
  class ReclaimCallback {
  public:
    virtual void reclaim_ptr(uintptr_t ptr) = 0;
  };
private:
  ThreadLocalNodeList *hazard_list_;   // 每个线程的 hazard pointer 列表
  ThreadLocalNodeList *retire_list_;   // 每个线程的待回收列表
  ReclaimCallback *reclaim_callback_;  // 实际回收回调
```

`ThreadLocalNodeList` 是一个按线程 ID 索引的 `Node` 数组（`head[OB_MAX_THREAD_NUM_DO_NOT_USE]`），每个线程拥有自己的链表头。

#### protect — 声明保护

```cpp
// ob_hazard_pointer.h — 第 114-156 行
int ObHazardPointer::protect(uintptr_t ptr)
{
  // ... 检查初始化
  int64_t tid = get_itid();
  Node *prev = hazard_list_->head + tid;   // 线程本地链表头
  while (!is_set) {
    Node *p = prev->next;
    while (p != NULL) {
      if (p->ptr == 0) {                     // 找到空槽位
        ATOMIC_STORE(&p->ptr, ptr);          // 写入受保护指针
        is_set = true;
        break;
      }
      prev = p;  p = p->next;
    }
    if (!is_set) {                           // 链表满，添加新节点
      p = op_alloc(Node);
      p->ptr = ptr;
      ATOMIC_STORE(&prev->next, p);          // 原子插入
      is_set = true;
    }
  }
}
```

读线程在访问共享指针前调用 `protect()`，将指针写入本地 hazard list。其他线程看到这个指针就不会释放它。

#### release — 释放保护

```cpp
// ob_hazard_pointer.h — 第 158-188 行
int ObHazardPointer::release(uintptr_t ptr)
{
  Node *p = hazard_list_->head[tid].next;
  while (p != NULL) {
    if (p->ptr == ptr) {
      ATOMIC_STORE(&p->ptr, 0);    // 清空，允许回收
      break;
    }
    p = p->next;
  }
}
```

#### retire — 退役与回收

```cpp
// ob_hazard_pointer.h — 第 190-219 行
int ObHazardPointer::retire(uintptr_t ptr)
{
  Node *head = retire_list_->head + tid;
  node->ptr = ptr;
  node->next = head->next;
  head->next = node;              // 加入当前线程的退役链表
  reclaim();                      // 尝试回收
}

int ObHazardPointer::reclaim()
{
  Node *retire_pre = retire_list_->head + get_itid();
  Node *retire_node = retire_pre->next;
  while (NULL != retire_node) {
    bool is_hazard = false;
    for (int64_t i = 0; !is_hazard && i < max_tid; i++) {
      // 扫描所有线程的 hazard list
      Node *p = hazard_list_->head[i].next;
      while (NULL != p) {
        if (ATOMIC_LOAD(&p->ptr) == retire_node->ptr) {
          is_hazard = true;      // 该指针仍被保护
          break;
        }
        p = p->next;
      }
    }
    if (!is_hazard) {            // 无人保护，安全回收
      reclaim_callback_->reclaim_ptr(cp);
      op_free(retire_node);
    }
  }
}
```

`retire` 将待释放的指针放入当前线程的退役链表，然后立即扫描所有线程的 hazard list。只有当某个退役指针不被任何线程保护时，才调用回调释放。

**优点**：实现简单，读线程开销小（仅一次原子写）。
**缺点**：
- 回收需要扫描所有线程的 hazard list，O(线程数 × 保护指针数)
- 每个读线程需要预先分配 slot（当前实现中链表可动态扩展）
- 没有版本号机制来解决 ABA 问题

### 2.2 Hazard Pointer 的使用

```cpp
// ob_concurrent_hash_map_with_hazard_value.h — 第 123-126 行
class HazardPtrReclaimCallback : public ObHazardPointer::ReclaimCallback
{
  virtual void reclaim_ptr(uintptr_t ptr) override;
};
```

`ObConcurrentHashMapDoNotUseWithHazardValue`（注意类名中的 DoNotUse... 暗示了某种历史包袱）使用 `ObHazardPointer` 保护 Value 指针的并发安全。

---

## 3. Hazard Ref — 版本号驱动的延迟回收

`ob_hazard_ref.h` 提供了更精细的内存回收机制。与经典 Hazard Pointer 不同，Hazard Ref 使用**版本号 (epoch/version)** 来判断是否可以安全回收。

### 3.1 HazardRef — 全局版本管理器

```cpp
// ob_hazard_ref.h — 第 22-68 行
class HazardRef
{
public:
  enum {
    MAX_THREAD_NUM = OB_MAX_THREAD_NUM_DO_NOT_USE,    // 最大线程数
    THREAD_REF_COUNT_LIMIT = 8,                        // 每线程最多 8 个引用
    TOTAL_REF_COUNT_LIMIT = MAX_THREAD_NUM * THREAD_REF_COUNT_LIMIT
  };
  const static uint64_t INVALID_VERSION = UINT64_MAX;

  uint64_t *acquire_ref();           // 获取一个引用槽
  void release_ref(uint64_t *ref);   // 释放引用槽

  uint64_t new_version()             // 产生新版本号
  {
    return ATOMIC_AAF(&cur_ver_, 1);
  }

  uint64_t get_hazard_version()      // 计算最小活跃版本
  {
    uint64_t min_version = ATOMIC_LOAD(&cur_ver_);
    // 扫描所有线程的引用，找到最小的版本号
    for (int64_t i = 0; i < real_used_ref; i++) {
      uint64_t ver = ATOMIC_LOAD(ref_array_ + i);
      if (ver < min_version) {
        min_version = ver;
      }
    }
    return min_version;              // 所有 < min_version 的都是安全的
  }
private:
  uint64_t cur_ver_ CACHE_ALIGNED;   // 全局版本计数器
  uint64_t ref_array_[TOTAL_REF_COUNT_LIMIT];  // 全局引用数组
};
```

核心机制：
1. **读线程**在执行危险操作前，通过 `acquire_ref()` 获取一个引用槽，写入当前版本号
2. **写线程**在回收时，调用 `get_hazard_version()` 获取所有线程中的最小活跃版本号
3. **任何版本号 < min_version 的节点都是安全的**，可以被回收

### 3.2 HazardNode — 退役节点

```cpp
// ob_hazard_ref.h — 第 69-75 行
struct HazardNode
{
  HazardNode(): next_(NULL), version_(0) {}
  void reset() { next_ = NULL; version_ = 0; }
  HazardNode *next_;
  uint64_t version_;    // 退役时记录的版本号
};
```

每个退役节点携带一个 `version_`，表示它是在哪个版本号下退役的。回收时，将该 version 与全局最小活跃版本号比较。

### 3.3 RetireList — 两阶段退役

```cpp
// ob_hazard_ref.h — 第 137-220 行
class RetireList
{
public:
  struct ThreadRetireList {
    HazardNodeList retire_list_;    // 待回收队列（已到回收版本）
    HazardNodeList prepare_list_;   // 预备队列（刚退役，未到回收版本）
  };

  void set_reclaim_version(uint64_t version);  // 设置回收阈值

  void retire(HazardNode* p) {
    // 退役：放入 prepare_list_
    get_thread_retire_list()->prepare_list_.push(p);
  }

  HazardNode *reclaim() {
    // 回收：检查 retire_list_ 头节点版本
    HazardNode *p = retire_list_.head();
    if (p && p->version_ <= hazard_version_) {
      return retire_list_.pop();   // 版本可达，安全回收
    }
    return NULL;
  }
};
```

两阶段设计：
- **prepare_list_**：新退役的节点暂存于此，等待全局版本推进
- **retire_list_**：版本推进后，从 prepare 移入 retire，再检查版本号后可安全回收

### 3.4 RetireListHandle — 操作包装

```cpp
// ob_hazard_ref.h — 第 218-260 行
class RetireListHandle
{
public:
  void retire(int errcode, uint64_t retire_limit) {
    // 1. 将 del_list_ 中的节点放入 retire_list_（退役）
    while(p = del_list_.pop())  retire_list_.retire(p);

    // 2. 如果 prepare_list 超过一半阈值，触发版本推进
    if (retire_list_.get_prepare_size() > retire_limit/2)
      retire_list_.set_retire_version(href_.new_version());

    // 3. 如果 retire_list 超过阈值，设置回收版本
    if (retire_list_.get_retire_size() > retire_limit)
      retire_list_.set_reclaim_version(href_.get_hazard_version());

    // 4. 回收已安全的节点
    while(p = retire_list_.reclaim())  reclaim_list_.push(p);
  }
};
```

整个流程：

```
  [alloc_list_] → add_del() → [del_list_] → retire() → [prepare_list_]
                                                              ↓ new_version()
                                                         [retire_list_]
                                                              ↓ get_hazard_version()
                                                         [reclaim_list_] → 实际释放
```

### 3.5 在 ObHash 中的应用

```cpp
// ob_hash.h — 第 298-299 行
hazard_handle_(host.get_hazard_ref()),
retire_list_handle_(host.get_hazard_ref(), host.get_retire_list())
```

ObHash 的 `Handle` 类同时持有 `HazardHandle`（读保护）和 `RetireListHandle`（写退役），保证读操作安全的同时允许写操作延迟回收。

---

## 4. Retire Station — Epoch-Based Reclamation

`ob_retire_station.h` 实现了 **Epoch-based Reclamation (EBR)**，这是另一种延迟回收机制。与 Hazard Pointer 不同，EBR 不关心具体指针，而是通过全局活跃阶段（epoch）来判断内存安全。

### 4.1 QClock — 准时钟 (Quiescent Clock)

```cpp
// ob_retire_station.h — 第 26-109 行
class QClock
{
public:
  uint64_t enter_critical() {
    // 进入临界区：将当前线程的 slot 时钟设置为全局时钟
    while(!locate(slot_id)->set_clock(get_clock()))
      sched_yield();     // 如果 slot 被人占用，自旋等待
  }

  void leave_critical(uint64_t slot_id) {
    locate(slot_id)->clear_clock();  // 清空 slot
  }

  uint64_t wait_quiescent(uint64_t clock) {
    // 等待所有线程都离开临界区（即 clock 成为安静状态）
    while(!is_quiescent(clock))  PAUSE();
    inc_clock();  // 推进时钟
  }

  bool try_quiescent(uint64_t &clock) {
    if (is_quiescent(clock)) {
      clock = cur_clock;  // 更新当前时钟
      inc_clock();        // 推进
      return true;
    }
    return false;
  }

private:
  uint64_t clock_ CACHE_ALIGNED;      // 全局时钟，每次 quiescent +1
  uint64_t qclock_ CACHE_ALIGNED;     // 缓存的最小安静时钟
  ClockSlot clock_array_[MAX_QCLOCK_SLOT_NUM] CACHE_ALIGNED;  // 每线程 slot
};
```

`QClock` 的精妙在于：

- **每个线程**在 `enter_critical()` 时将当前全局时钟写入自己的 slot，离开时清空（设为 UINT64_MAX）
- **全局时钟**在每次 quiescent state 时递增 1
- **判断安静状态**：对于某个 epoch `E`，所有 slot 中的时钟都必须 > `E`，才说明所有线程都离开了 epoch `E` 之前进入的临界区
- **`calc_quiescent_clock()`** 扫描所有 slot，找到最小的时钟值。如果某个线程迟迟不离开，这个最小值就会卡住，从而阻止回收

### 4.2 HazardList — 退役链表

```cpp
// ob_retire_station.h — 第 117-153 行
class HazardList
{
public:
  typedef ObLink Link;      // 来自 queue/ob_link.h 的 ObLink

  void push(Link* p) {      // 入队（尾插）
    p->next_ = NULL;
    if (NULL == tail_)      head_ = tail_ = p;
    else                    tail_->next_ = p, tail_ = p;
    size_++;
  }

  Link* pop() {             // 出队（头取）
    Link* p = head_;
    if (NULL != head_) {
      head_ = head_->next_;
      if (NULL == head_)    tail_ = NULL;
    }
    if (p) size_--;
    return p;
  }
};
```

`HazardList` 是一个简单的单链表 FIFO 队列，节点类型是 `ObLink`。它的操作是在**单线程上下文中执行**的，因此不需要原子操作。

### 4.3 RetireStation — 退役站

```cpp
// ob_retire_station.h — 第 162-196 行
class RetireStation
{
public:
  struct RetireList {
    void retire(List& reclaim_list, List& retire_list,
                int64_t limit, QClock& qclock) {
      LockGuard lock_guard(lock_);        // 本线程的锁
      retire_list.move_to(prepare_list_);

      // 条件 1: 超过阈值 → 强制推进版本并回收
      if (prepare_list_.size() > limit) {
        retire_clock_ = qclock.wait_quiescent(retire_clock_);
        retire_list_.move_to(reclaim_list);
        prepare_list_.move_to(retire_list_);
      }
      // 条件 2: 每 64 次尝试一次温和推进
      else if (63 == prepare_list_.size() % 64
               && qclock.try_quiescent(retire_clock_)) {
        retire_list_.move_to(reclaim_list);
        prepare_list_.move_to(retire_list_);
      }
    }
    List retire_list_;     // 待回收队列（已到安静 epoch）
    List prepare_list_;    // 预备队列（等待安静 epoch）
  };

  void retire(List& reclaim_list, List& retire_list) {
    get_retire_list().retire(reclaim_list, retire_list, retire_limit_, qclock_);
  }

  void purge(List& reclaim_list) {
    // 强制扫描所有线程，推进全局版本并回收
    for(int i = 0; i < 2; i++)
      for(int64_t id = 0; id < MAX_RETIRE_SLOT_NUM; id++)
        retire_list_[id].retire(reclaim_list, retire_list, -1, qclock_);
  }
};
```

`RetireStation` 的工作流程：

```
  [外部操作]  →  retire list  →  [prepare_list_]
                                      │
                          ┌───────────┴─────────────┐
                          │ 超过阈值?                │
                          │ 或每 64 次命中温和回收?   │
                          └───────────┬─────────────┘
                                      │ 是
                          ┌───────────┘
                          │ wait_quiescent() 或 try_quiescent()
                          ▼
                     [retire_list_]  →  [reclaim_list_]  →  实际释放
```

### 4.4 QClockGuard — RAII 临界区

```cpp
// ob_retire_station.h — 第 208-213 行
class QClockGuard
{
public:
  explicit QClockGuard(QClock& qclock=get_global_qclock())
    : qclock_(qclock), slot_id_(qclock_.enter_critical()) {}
  ~QClockGuard() { qclock_.leave_critical(slot_id_); }
};
```

`QClockGuard` 提供 RAII 封装：构造时进入临界区，析构时离开。典型使用场景：

```cpp
{
  QClockGuard guard;           // 进入临界区，记录当前 epoch
  Node* p = atomic_load(&head);
  if (p != NULL) {
    // 安全访问 p，因为写线程知道本线程还在这个 epoch
    do_something(p);
  }
}                              // 离开临界区，qclock slot 被清空
```

### 4.5 RetireStation 的使用

`ob_link_hashmap.h` 是使用 RetireStation 的典型例子：

```cpp
// ob_link_hashmap.h — 第 573-575 行
static RetireStation& get_retire_station() {
  static RetireStation retire_station(get_global_qclock(), RETIRE_LIMIT);
  return retire_station;
}
```

```cpp
// ob_link_hashmap.h — 第 47-55 行
class BaseRefHandle {
  virtual void retire(Node* node, HazardList& reclaim_list) {
    HazardList retire_list;
    // 将节点加入 RetireStation 的退役链
    retire_station_.retire(reclaim_list, retire_list);
  }
  virtual void purge(HazardList& reclaim_list) {
    retire_station_.purge(reclaim_list);  // 强制回收
  }
};
```

`Guard`（在第 107 行）持有 `QClockGuard`：

```cpp
// ob_link_hashmap.h — 第 107 行
struct Guard : public QClockGuard {
  explicit Guard(RetireStation& retire_station)
    : QClockGuard(retire_station.get_qclock()) {}
};
```

---

## 5. LF FIFO Allocator — 无锁 FIFO 内存分配

`ObLfFIFOAllocator` 是无锁 FIFO（First-In-First-Out）内存分配器，继承自 `ObVSliceAlloc`（虚拟切片分配器）。

```cpp
// ob_lf_fifo_allocator.h — 第 22 行
class ObLfFIFOAllocator: public ObVSliceAlloc
{
public:
  int init(const int64_t page_size,
           const lib::ObMemAttr &attr,
           const int64_t cache_page_count = DEFAULT_CACHE_PAGE_COUNT,
           const int64_t total_limit = INT64_MAX)
  {
    // 1. 设置全局限制
    block_alloc_.set_limit(total_limit);
    // 2. 初始化 ObVSliceAlloc（无锁切片分配）
    ObVSliceAlloc::init(page_size, block_alloc_, mattr_);
    // 3. 设置 arena 数量（= cache_page_count）
    ObVSliceAlloc::set_nway(static_cast<int32_t>(cache_page_count));
  }

  void *alloc(const int64_t size) { return ObVSliceAlloc::alloc(size); }
  void free(void *ptr) { ObVSliceAlloc::free(ptr); }

private:
  BlockAlloc block_alloc_;  // 底层块分配器
};
```

### 5.1 底层机制：ObVSliceAlloc

`ObVSliceAlloc` 在 `ob_vslice_alloc.h` 中实现，其核心是 `ObBlockVSlicer`——将大块内存切片，通过无锁原子操作分配。

```cpp
// ob_vslice_alloc.h — ObBlockVSlicer 的关键字段
int64_t ref_ CACHE_ALIGNED;    // 引用计数（初始值 = K = INT64_MAX）
int64_t pos_ CACHE_ALIGNED;    // 当前分配位置
```

分配算法：

```cpp
Item* alloc_item(int64_t size, int64_t &leak_pos) {
  int64_t pos = ATOMIC_FAA(&pos_, alloc_size);  // 无锁前移 pos
  if (pos + alloc_size <= get_limit()) {
    p = (Item*)(base_ + pos);
    new(p) Item(this, alloc_size);
    ATOMIC_FAA(&ref_, alloc_size);                // 增加引用
  }
  return p;
}
```

- 使用 `ATOMIC_FAA`（Fetch-And-Add）原子性地前移 `pos_` 指针
- 多线程不会冲突，因为每个线程获取的 `pos` 是唯一的
- 当块用尽时（`pos > limit`），标记块为冻结状态并切换到新块

`ObVSliceAlloc` 使用多个 Arena（默认最多 32 个），每个线程通过取模选择 Arena，减少原子操作的冲突：

```cpp
Arena& arena = arena_[get_itid() % nway_];
```

### 5.2 使用场景

`ObConcurrentFIFOAllocator` 包装了 `ObLfFIFOAllocator`，提供更友好的接口：

```cpp
// ob_concurrent_fifo_allocator.h — 第 56 行
ObLfFIFOAllocator inner_allocator_;  // 内部使用无锁 FIFO 分配器
```

---

## 6. 与前面文章应用的关联

### 6.1 ObMtHash 与 Hazard Pointer

第 14 篇文章分析的 ObMtHash 中使用 HashBucket 的 `ObLink` 实现无锁链表。虽然 `ob_mthash.h` 本身不直接使用 `ObHazardPointer`，但 `ob_concurrent_hash_map_with_hazard_value.h` 整合了完整流程：

```
ObMtHash 哈希表
  └── HashBucket 链表 — 使用 ObLink 无锁指针操作
  └── Value 保护 — 使用 ObHazardPointer 保护 Value 不被提前释放
```

### 6.2 ObKeyBtree 与 RetireStation

第 15 篇文章分析的 ObKeyBtree 使用 B-tree 节点链表，在节点分裂/合并时需要使用 EBR 延迟回收被删除的节点。虽然直接源码分析未找到显式的 RetireStation 调用（其延迟回收可能在更上层的 PALF/storage 层实现），但 EBR 无疑是其安全回收的理论基础。

### 6.3 无锁内存分配器

ObLfFIFOAllocator 在整个引擎中广泛使用——任何需要高并发小对象分配的场景都可以看到它的身影，从 `ObConcurrentFIFOAllocator` 到 `ObSmallAllocator`。

### 6.4 PALF 日志回收

在 PALF（Paxos-based Append Log Framework）中，日志条目写完后需要延迟回收，确保所有读线程都完成访问后才释放日志块内存。EBR（RetireStation）天然适合这种延迟回收场景。

---

## 7. 核心算法工作流

### 7.1 Hazard Pointer 工作流

```
┌──── 读线程 T1 ────┐        ┌──── 写线程 T2 ────┐
│                     │        │                     │
│ protect(ptr) ──────│───────│→ hazard_list[t2]     │
│   ├── 写入 T1 的    │        │   看到 ptr 被保护    │
│   │   hazard slot   │        │                     │
│   └── T1 声明使用   │        │ retire(ptr)         │
│                     │        │   ├── 加入退役列表    │
│ 访问 ptr → 安全！   │        │   ├── 扫描 hazard    │
│                     │        │   │   list: T1 保护中 │
│ release(ptr) ──────│───────│→   └── 不可回收，等待  │
│   └── 清空 hazard   │        │                     │
│                     │        │ T1 release → 安全    │
│                     │        │ 回收 ptr → callback  │
└─────────────────────┘        └──────────────────────┘
```

### 7.2 EBR (QClock + RetireStation) 工作流

```
   全局时钟: 1 ──→ 2 ──→ 3 ──→ ...

   线程 T0          线程 T1          线程 T2
   ────────        ────────        ────────
   enter()         enter()         enter()
   | clock=1       | clock=1       | clock=2
   |                |                |
   | 读节点 A       | 读节点 B       | 读节点 C
   |                |                |
   leave()         leave()         leave()
   | slot=MAX      | slot=MAX      | slot=MAX
   |                |                |
   写线程想回收 epoch=1 的节点:
   ├── 检查 slots: T0=MAX, T1=MAX, T2=MAX
   ├── 所有 > 1 → 安全！
   ├── inc_clock() → 全局时钟=4
   └── 释放 epoch=1 的退役节点
```

关键点：**只有所有线程都离开了某个 epoch，这个 epoch 下的退役节点才能被安全释放**。如果有线程长时间停留在临界区中（持有旧 epoch），回收会被阻塞。

### 7.3 Hazard Ref 版本号工作流

```
    全局版本号: 1 ──→ 2 ──→ 3 ──→ 4

    读线程                    写线程
    ────────                 ────────
    acquire_ref()            new_version() → 版本=4
    ├── 引用数组[0] = 当前版本
    │                       retire(NodeX)
    └── 读 NodeX             ├── NodeX.version = 4
                             ├── 加入 prepare_list_
                             │
    release_ref()            └── set_retire_version(4)
    ├── 引用数组[0] = MAX
    │                       get_hazard_version()
    │                        ├── 扫描引用数组
    │                        ├── 找到最小版本 = 2
    │                        └── 所以 <2 的版本可回收
    │
    ... 等待版本推进 ...
    │
                             NodeX.version(4) > min(2)
                             → 不可回收，继续等待
                             → 直到所有引用都 >= 4
```

---

## 8. 设计决策

### 8.1 为什么用侵入式链表而非标准容器？

入侵式链表（`ObLink` 嵌入到业务结构体中）的好处：

- **零额外分配**：链表节点是业务对象的一部分，不需要额外的 `malloc`
- **缓存友好**：节点数据和链表指针在同一 cache line
- **CAS 安全**：可以直接用 `ATOMIC_VCAS(&obj->next_, ...)` 操作嵌入的指针

代价是通用性降低——业务结构体必须显式包含 `ObLink` 字段。

### 8.2 何时用 Hazard Pointer vs Hazard Ref vs EBR？

| 特性 | ObHazardPointer | HazardRef | RetireStation (EBR) |
|------|----------------|-----------|-------------------|
| **粒度** | 按指针保护 | 按版本号保护 | 按 epoch 保护 |
| **读开销** | 1 次原子写 (protect) | 1 次原子写 (acquire) | 1 次原子写 (enter) |
| **写开销** | 扫描所有 HP，O(N) | 扫描引用数组，O(N×8) | 扫描所有 slot，O(N) |
| **阻塞风险** | 无 | 无 | 线程长时间不离开会阻塞回收 |
| **ABA 解决** | 需外部机制 | 版本号天然解决 | epoch 天然解决 |
| **复杂度** | ★☆☆ | ★★★ | ★★☆ |

OceanBase 的设计选择：

- **hash/ob_hazard_pointer.h** (ObHazardPointer)：简单场景，如 Value 指针保护。但命名空间 `hash` 暗示主要用于哈希表
- **allocator/ob_hazard_ref.h** (HazardRef)：通用场景，版本号语义更精确。用于 `ObHash`、`DArray`
- **allocator/ob_retire_station.h** (RetireStation)：更高级的场景。用于 `ObLinkHashMap`，配套 `ObLink` 无锁链表

### 8.3 ABA 问题的预防

无锁数据结构的天敌是 ABA 问题：指针 A 被释放、重用为相同的地址 A'，CAS 误认为没有变化。

OceanBase 的应对：

1. **删除标记 (LSB)**：`link_del` 通过最低位置 1 标记节点"正在被删除"。同一节点无法被再次插入（因为标记位）
2. **Hazard Pointer 延迟回收**：节点不会立即被重用，降低了 ABA 概率
3. **EBR epoch**：一个 epoch 内的节点不会在同一 epoch 内被回收重用

### 8.4 内存屏障策略

```
ObLink 操作：             ATOMIC_VCAS — 隐式全屏障
ObHazardPointer：         ATOMIC_STORE / ATOMIC_LOAD — Release/Acquire 语义
QClock slot 操作：         ATOMIC_BCAS / ATOMIC_STORE — 完全原子
HazardRef 引用操作：       ATOMIC_AAF / ATOMIC_STORE — 原子且屏障
ObVSliceAlloc 分配：       ATOMIC_FAA — 原子递增，不需要完全屏障
```

越底层的操作使用更轻的屏障：

- `ObLink` 的 CAS 操作使用最强的 `__sync_val_compare_and_swap`（full barrier）
- `ObVSliceAlloc` 的 `ATOMIC_FAA` 只需要原子性，不需要顺序一致性
- 在高并发路径上（如内存分配），使用更轻的屏障来最大化吞吐

### 8.5 延迟回收的权衡

延迟回收的核心是**安全性**与**内存效率**的权衡：

- **过晚释放** → 内存占用膨胀，`RetireStation` 中的 `retire_limit` 控制这个阈值
- **过早释放** → use-after-free，灾难性的数据损坏

`RetireStation` 的智能策略：
- **默认阈值+64次尝试**：在性能和内存间找到平衡
- **`purge()` 强制扫描**：在销毁场景下确保所有节点被回收

---

## 9. 源码索引

### 无锁链表

| 符号 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `ObLink` | `queue/ob_link.h` | 25-33 | 无锁单链表节点（含删除标记） |
| `link_next` | `queue/ob_link.h` | 63-65 | 安全读取 next（清除标记） |
| `link_insert` | `queue/ob_link.h` | 70-73 | CAS 插入 |
| `link_del` | `queue/ob_link.h` | 78-87 | 标记+删除 |
| `ol_search` | `queue/ob_link.h` | 92-101 | 有序查找 + 记录前驱 |
| `ol_insert` | `queue/ob_link.h` | 207-211 | 自旋 CAS 插入 |
| `ol_del` | `queue/ob_link.h` | 217-220 | 自旋 CAS 删除 |
| `ObDLink` | `queue/ob_link.h` | 234-243 | 无锁双向链表节点 |
| `dl_insert` | `queue/ob_link.h` | 269-278 | 双向链表插入 |
| `dl_del` | `queue/ob_link.h` | 309-320 | 双向链表删除 |
| `try_correct_prev_link` | `queue/ob_link.h` | 247-261 | `prev_` 修正辅助函数 |
| `ObSLink` | `list/ob_link.h` | 21-56 | 侵入式单向链表（有锁） |
| `ObDLink` | `list/ob_link.h` | 68-192 | 侵入式双向链表（有锁） |
| `CONTAINING_RECORD` | `list/ob_link.h` | 195-196 | 从字段指针取容器对象 |

### Hazard Pointer

| 符号 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `ObHazardPointer` | `hash/ob_hazard_pointer.h` | 25-66 | 经典 HP 实现 |
| `ObHazardPointer::init` | `hash/ob_hazard_pointer.h` | 88-112 | 分配 hazard/retire 列表 |
| `ObHazardPointer::protect` | `hash/ob_hazard_pointer.h` | 114-156 | 声明指针保护 |
| `ObHazardPointer::release` | `hash/ob_hazard_pointer.h` | 158-188 | 释放指针保护 |
| `ObHazardPointer::retire` | `hash/ob_hazard_pointer.h` | 190-219 | 退役+尝试回收 |
| `ObHazardPointer::reclaim` | `hash/ob_hazard_pointer.h` | 221-245 | 扫描所有 HP 安全回收 |
| `HazardPtrReclaimCallback` | `ob_concurrent_hash_map_with_hazard_value.h` | 123-126 | HP 回调适配器 |

### Hazard Ref

| 符号 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `HazardRef` | `allocator/ob_hazard_ref.h` | 22-68 | 版本号驱动的引用管理器 |
| `HazardRef::acquire_ref` | `allocator/ob_hazard_ref.h` | 39 | 获取引用槽 |
| `HazardRef::new_version` | `allocator/ob_hazard_ref.h` | 49-51 | 推进全局版本 |
| `HazardRef::get_hazard_version` | `allocator/ob_hazard_ref.h` | 53-63 | 计算最小活跃版本 |
| `HazardNode` | `allocator/ob_hazard_ref.h` | 69-75 | 退役节点（带版本号） |
| `RetireList` | `allocator/ob_hazard_ref.h` | 137-220 | 两阶段退役管理器 |
| `RetireListHandle` | `allocator/ob_hazard_ref.h` | 218-260 | 高阶操作封装 |
| `HazardHandle` | `allocator/ob_hazard_ref.h` | 200-215 | RAII 引用管理 |

### Retire Station (EBR)

| 符号 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `QClock` | `allocator/ob_retire_station.h` | 26-109 | 准时钟（quiescent clock） |
| `QClock::enter_critical` | `allocator/ob_retire_station.h` | 41-51 | 进入临界区 |
| `QClock::wait_quiescent` | `allocator/ob_retire_station.h` | 63-67 | 等待安静 |
| `QClock::try_quiescent` | `allocator/ob_retire_station.h` | 69-77 | 非阻塞尝试安静 |
| `calc_quiescent_clock` | `allocator/ob_retire_station.h` | 97-103 | 计算最小时钟 |
| `HazardList` | `allocator/ob_retire_station.h` | 117-153 | 退役链表（ObLink 节点） |
| `RetireStation` | `allocator/ob_retire_station.h` | 162-196 | 退役站主类 |
| `RetireStation::retire` | `allocator/ob_retire_station.h` | 176-179 | 退役操作 |
| `RetireStation::purge` | `allocator/ob_retire_station.h` | 186-189 | 强制回收 |
| `QClockGuard` | `allocator/ob_retire_station.h` | 208-213 | RAII 临界区守卫 |
| `get_global_qclock` | `allocator/ob_retire_station.h` | 111-114 | 全局 QClock 单例 |

### LF FIFO Allocator

| 符号 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `ObLfFIFOAllocator` | `allocator/ob_lf_fifo_allocator.h` | 22-57 | 无锁 FIFO 分配器 |
| `ObLfFIFOAllocator::init` | `allocator/ob_lf_fifo_allocator.h` | 29-42 | 初始化（设置 nway） |
| `ObVSliceAlloc` | `allocator/ob_vslice_alloc.h` | 82+ | 基础切片分配器 |
| `ObBlockVSlicer::alloc_item` | `allocator/ob_vslice_alloc.h` | 50-58 | 无锁切片分配 |
| `ObConcurrentFIFOAllocator` | `allocator/ob_concurrent_fifo_allocator.h` | 15-61 | 包装类 |

### 应用层

| 符号 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `BaseRefHandle` | `hash/ob_link_hashmap.h` | 47-60 | RetireStation + QClock 的包装句柄 |
| `Guard (inner)` | `hash/ob_link_hashmap.h` | 107 | QClockGuard 封装 |
| `get_retire_station` | `hash/ob_link_hashmap.h` | 573-575 | RetireStation 单例 |
| `retire_list_` | `hash/ob_hash.h` | 779 | ObHash 的 RetireList |
| `hazard_ref_` | `hash/ob_hash.h` | 778 | ObHash 的 HazardRef |
| `retire_list_handle_` | `hash/ob_hash.h` | 353 | RetireListHandle 在 Handle 中 |

---

## 10. 总结

OceanBase 的无锁基础设施是一个**分层设计**：

1. **最底层**：`ObLink`（CAS+标记位）提供最基本的无锁链表操作原语
2. **指针保护层**：`ObHazardPointer` 和 `HazardRef` 提供不同粒度的读保护机制
3. **内存回收层**：`RetireStation` (EBR) 提供被动感知的延迟回收
4. **应用层**：`ObLfFIFOAllocator` 提供无锁内存分配，直接受益于底层的切片分配机制

这三种延迟回收算法（HP、Hazard Ref、EBR）在 OceanBase 中并存，各自服务于不同的并发场景：

- **HP** 简单直接，适合保护独立指针
- **Hazard Ref** 版本号更精确，适合批量节点管理
- **EBR** 无锁读路径开销极低，适合读极端密集的场景

整个体系的设计取舍反映了 OceanBase 的工程智慧：**没有银弹**，不同的并发模式使用不同的工具，每条路径都用最简化的原语实现最大的吞吐。

---

## Changelog

- commit: `docs(oceanbase): add 55-lockfree-analysis - Lock-free data structures and memory reclamation`
- 文件: `code-learn/oceanbase/55-lockfree-analysis.md`
- 基于 OceanBase 主线源码 `deps/oblib/src/lib/`
- 使用 doom-lsp (clangd) 验证所有符号位置
