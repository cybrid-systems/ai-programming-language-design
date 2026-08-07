# 106-atomic-lockfree-data-structure — OceanBase 原子变量应用 (4/4): Lock-free Data Structure 模式

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后)
> 源码锚点:`deps/oblib/src/lib/atomic/ob_atomic.h` + `deps/oblib/src/lib/atomic/atomic128.h` + `deps/oblib/src/lib/lock/ob_latch.cpp` + `deps/oblib/src/lib/lock/ob_qsync_lock.{h,cpp}` + `deps/oblib/src/lib/lock/ob_bucket_qsync_lock.{h,cpp}` + `deps/oblib/src/lib/hash/ob_darray.h` + `deps/oblib/src/lib/tc/deps/drwlock.h` + `deps/oblib/src/lib/tc/deps/batch_pop_queue.h` + `deps/oblib/src/lib/hash/ob_link_hashmap.{h}` + `deps/oblib/src/lib/allocator/ob_slice_alloc.h` + `deps/oblib/src/common/ob_clock_generator.h` + `deps/oblib/src/lib/stat/ob_stat_template.cpp` + `deps/oblib/src/lib/hash/ob_multi_mod_ref_mgr.h` + `src/share/queue/ob_sp_link_queue.h`
> 使用 doom-lsp (clangd LSP) 做符号解析与数据流追踪
> 接续 #103 Counter / #104 Flag / #105 Refcount — 本系列 4 篇收尾

---

## 0. 全文导读

OB 1024 个 atomic 文件中, **Lock-free Data Structure 模式** 是最复杂的一类。用 BCAS / VCAS / FAA 构造无锁的 **latch / mutex / queue / stack / hash map**。本篇是 #103-#106 系列的**收尾**。

| 模式 | 本系列 | 状态 |
|------|--------|------|
| Counter / Metric | #103 | ✅ |
| Flag / State Machine | #104 | ✅ |
| Refcount / Hazard Pointer | #105 | ✅ |
| **Lock-free Data Structure** | **#106 (本篇)** | 📝 |

### Lock-free Data Structure 在 OB 中的分布

| 子模块 | 代表 | 算法 |
|--------|------|------|
| Latch (核心) | `ob_latch` | BCAS + WAIT_MASK 自旋 |
| 简化 mutex | `ob_qsync_lock` | BCAS write_flag_ |
| Per-bucket 锁 | `ob_bucket_qsync_lock` | BCAS write_flag_ × N |
| 可重入锁 | `ob_darray` | BCAS write_uid |
| Reader-Writer lock | `drwlock` | BCAS + FAA reader |
| Stack (Treiber) | `batch_pop_queue` | VCAS top_ |
| Hash Map 链 | `ob_link_hashmap` | VCAS next + BORN_REF |
| Stock 控制 | `ObStockCtrl` | VCAS stock_ 区间编码 |
| 单调时间 | `ObClockGenerator` | BCAS cur_ts_ |
| Stat counter | `ob_stat_template` | BCAS lock_ |
| Cross module spinlock | `ob_multi_mod_ref_mgr` | BCAS lock_ |
| Lock-free queue | `ob_sp_link_queue` | VCAS next_ |
| Hazard Map | `ob_concurrent_hash_map_with_hazard_value` | VCAS + HP + atomic128 |
| 128-bit CAS | `atomic128.h` | `__atomic_compare_exchange` (128 位) |

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #74 Thread Model | `ob_latch` 是 worker 同步基础 |
| #75 Latch System | `ob_latch` 完整 latch 状态机 (本篇聚焦 atomic 原语) |
| #14 MemTable | `ob_link_hashmap` 是 memtable 索引 |
| #11 Trans Service | `ob_sp_link_queue` 是事务队列 |
| #103-105 | atomic 宏的 4 种业务模式 (本篇是综合应用) |

---

## 1. 背景 / 概念

### 1.1 Lock-free 与 Mutex 的对比

| 维度 | Lock-free | OS Mutex (futex) |
|------|-----------|-------------------|
| 取锁延迟 | < 100 ns (纯 atomic) | ~1-5 μs (syscall) |
| 释放延迟 | < 50 ns | ~1 μs |
| 适用 | 临界区 < 1 μs | 临界区 > 1 μs |
| 公平性 | 不保证 | 较公平 |
| 复杂度 | 高 (ABA, 内存序) | 低 |

### 1.2 Lock-free 的 5 种算法

| 算法 | 原理 | OB 用途 |
|------|------|--------|
| **CAS spinlock** | 自旋直到 BCAS 成功 | qsync, darray, multi_mod |
| **Treiber stack** | VCAS top_ | batch_pop_queue |
| **Michael-Scott queue** | VCAS head_ + tail_ | sp_link_queue |
| **VCAS 链** | 每个 node 用 VCAS next_ | link_hashmap |
| **Hazard Pointer** | HP 域 + retire list | concurrent_hash_map |
| **CAS128** | 128-bit CAS (version + ptr) | 表版本号 |

### 1.3 OB atomic 宏的 4 类用法

| 类别 | 宏 | 用途 |
|------|-----|------|
| **修改型** | FAA / AAF / FAS / SAF | 累加 / 累减 |
| **CAS 型** | BCAS / VCAS / CMP_AND_EXCHANGE | 条件改 |
| **交换型** | TAS / SET | 直接换 |
| **读型** | LOAD / STORE (含 ACQ/REL/RLX) | 同步 |

---

## 2. 实现细节

### 2.1 ob_latch — BCAS + WAIT_MASK 自旋 latch

[`deps/oblib/src/lib/lock/ob_latch.cpp:60-90`](deps/oblib/src/lib/lock/ob_latch.cpp):

```cpp
// wrlock (write mode, 独占)
int ObLatch::wrlock(uint32_t uid) {
  uint32_t lock = 0;
  do {
    do {
      lock = ATOMIC_LOAD(&lock_);   // 读当前 lock
      if (0 == (lock & WRITE_MASK)) {  // 没人 wrlock
        break;
      } else {
        // 已 wrlock, 等 — 但要加 WAIT_MASK 表示"有人在等"
        // 加 WAIT_MASK 防止 wrlock 饥饿
        if (0 == (lock & WAIT_MASK)) {
          (void)ATOMIC_BCAS(&lock_, lock, lock | WAIT_MASK);
        }
        PAUSE();
        lock = ATOMIC_LOAD(&lock_);
      }
    } while (true);
  } while (!ATOMIC_BCAS(&lock_, 0, WRITE_MASK | uid));   // ★ BCAS 抢锁
  return OB_SUCCESS;
}

// rdlock (read mode, 共享)
int ObLatch::rdlock() {
  uint32_t lock = ATOMIC_LOAD(&lock_);
  while (true) {
    if (0 == (lock & WRITE_MASK)) {   // 没人 wrlock
      // ★ 多 reader: ref + 1
      if (ATOMIC_BCAS(&lock_, lock, (lock & WAIT_MASK) + 1)) {
        break;
      }
    } else {
      PAUSE();
    }
    lock = ATOMIC_LOAD(&lock_);
  }
  return OB_SUCCESS;
}
```

[`ob_latch.cpp:700-716`](deps/oblib/src/lib/lock/ob_latch.cpp):

```cpp
// rdunlock
void ObLatch::rdunlock() {
  uint32_t lock = 0;
  while (!ATOMIC_BCAS(&lock_, lock, (lock & WAIT_MASK) + 1 - 1)) {   // ★ BCAS ref - 1
    PAUSE();
  }
}
```

**WAIT_MASK 设计**:
- lock_ 是 uint32_t, 高位是 WAIT_MASK, 低位是 ref (reader count) 或 WRITE_MASK
- 读者多时, ref 累加 (BCAS 用 `(lock & WAIT_MASK) + 1`)
- 写者抢锁前先加 WAIT_MASK 标记"有人在等", 防止写饥饿
- 完整的 latch 状态机在 #75 详述

**ob_latch 是 #74 Thread Model 和 #75 Latch System 的基础** — 所有需要锁的地方都优先用 ob_latch, 只有极简场景才用 qsync。

### 2.2 ob_qsync_lock — BCAS 简化 mutex

[`deps/oblib/src/lib/lock/ob_qsync_lock.cpp:40-100`](deps/oblib/src/lib/lock/ob_qsync_lock.cpp):

```cpp
class ObQSyncLock {
public:
  int wrlock() {
    while (!ATOMIC_BCAS(&write_flag_, 0, 1)) {   // ★ BCAS spinlock
      PAUSE();
    }
    return OB_SUCCESS;
  }
  void wrunlock() {
    ATOMIC_STORE(&write_flag_, 0);
  }
  int try_wrlock() {
    if (!ATOMIC_BCAS(&write_flag_, 0, 1)) {
      return OB_EAGAIN;
    }
    return OB_SUCCESS;
  }
  int rdlock() {
    if (OB_UNLIKELY(0 != ATOMIC_LOAD(&write_flag_))) {
      return OB_EAGAIN;
    }
    return OB_SUCCESS;
  }
  void rdunlock() { /* no-op */ }
private:
  uint32_t write_flag_ CACHE_ALIGNED;   // ★ cache line 对齐
};
```

**qsync vs ob_latch 对比**:

| 维度 | qsync | ob_latch |
|------|-------|----------|
| 复杂度 | 极简 (1 个 flag) | 中等 (WAIT_MASK + ref) |
| Reader count | 不支持 (writer 持锁时所有 reader 全拒) | 支持 (ref 累加) |
| 性能 | 略快 (无 mask 计算) | 略慢 |
| 适用 | 短临界区, 几乎无 reader | 需要 reader 重入 |

### 2.3 ob_bucket_qsync_lock — per-bucket 简化 mutex

[`deps/oblib/src/lib/lock/ob_bucket_qsync_lock.h`](deps/oblib/src/lib/lock/ob_bucket_qsync_lock.h):

```cpp
class ObBucketQSyncLock {
public:
  int wrlock(int64_t bucket_id) {
    if (bucket_id >= bucket_count_ || bucket_id < 0) return OB_INVALID_ARGUMENT;
    while (!ATOMIC_BCAS(&write_flags_[bucket_id], 0, 1)) {   // ★ per-bucket BCAS
      PAUSE();
    }
    return OB_SUCCESS;
  }
  void wrunlock(int64_t bucket_id) {
    ATOMIC_STORE(&write_flags_[bucket_id], 0);
  }
private:
  int64_t bucket_count_;
  uint32_t write_flags_[];   // ★ 变长数组, per-bucket 一个 flag
};
```

**per-bucket 设计**: 把一个锁拆成 N 个 bucket, 不同 bucket 的锁独立 — 减少锁竞争 (类似分段锁)。

### 2.4 ob_darray — BCAS 可重入锁

[`deps/oblib/src/lib/hash/ob_darray.h:265-285`](deps/oblib/src/lib/hash/ob_darray.h):

```cpp
class ObDArray {
public:
  int wrlock() {
    while (!ATOMIC_BCAS(write_uid, UNLOCKED, WR_LOCKING)) {   // ★ 状态机: UNLOCKED → WR_LOCKING → WR_LOCKED
      PAUSE();
    }
    return OB_SUCCESS;
  }
private:
  enum WriteUIDState { UNLOCKED, WR_LOCKING, WR_LOCKED };
  WriteUIDState write_uid;   // 多状态 BCAS 自旋锁
};
```

**write_uid 状态机**:
- `UNLOCKED` (0) — 无锁
- `WR_LOCKING` (1) — 抢锁中
- `WR_LOCKED` (2) — 已持锁

(可重入锁: 持锁者可以再次抢锁)

### 2.5 drwlock — BCAS + FAA reader 计数

[`deps/oblib/src/lib/tc/deps/drwlock.h:75-115`](deps/oblib/src/lib/tc/deps/drwlock.h):

```cpp
class DRWLock {
public:
  bool try_rdlock() {
    int64_t *ref = &get_read_ref().value_;
    if (0 == ATOMIC_LOAD(&write_uid_)) {
      ATOMIC_FAA(ref, 1);                                 // ★ reader + 1
      if (0 == ATOMIC_LOAD(&write_uid_)) {
        return true;
      } else {
        ATOMIC_FAA(ref, -1);                              // 回滚
      }
    }
    return false;
  }
  void rdlock() {
    while (!try_rdlock()) PAUSE();
  }
  void rdunlock() {
    int64_t *ref = &get_read_ref().value_;
    ATOMIC_FAA(ref, -1);                                   // ★ reader - 1
  }
  void wrlock() {
    while (!ATOMIC_BCAS(&write_uid_, 0, 1)) PAUSE();       // ★ writer BCAS spin
    for (int64_t i = 0; i < arrlen(read_ref_); i++) {
      while (ATOMIC_LOAD(&read_ref_[i].value_) > 0) PAUSE();   // 等所有 reader 退出
    }
    for (int64_t i = 0; i < arrlen(read_ref_unsafe_); i++) {
      ...
    }
  }
  void wrunlock() {
    ATOMIC_STORE(&write_uid_, 0);
  }
private:
  int64_t write_uid_;     // 0 / 1
  ReadRef read_ref_[];    // per-CPU reader 计数 (per-CPU 减少 false sharing)
};
```

**per-CPU ref**: `read_ref_` 是变长数组, 每个 CPU 一个 ref, 进一步减少 false sharing。

### 2.6 batch_pop_queue — Treiber stack + VCAS top_

[`deps/oblib/src/lib/tc/deps/batch_pop_queue.h:8-30`](deps/oblib/src/lib/tc/deps/batch_pop_queue.h):

```cpp
class BatchPopQueue {
public:
  void push(TCLink* p) {
    TCLink *nv = NULL;
    p->next_ = ATOMIC_LOAD(&top_);                       // ★ 读当前 top
    while (p->next_ != (nv = ATOMIC_VCAS(&top_, p->next_, p))) {   // ★ VCAS top_
      PAUSE();
      p->next_ = nv;                                      // retry
    }
  }
  TCLink* pop() {
    TCLink* h = ATOMIC_TAS(&top_, NULL);                // ★ TAS 一次性取整个 stack
    return link_reverse(h);                              // 反转链表 (push 顺序反向)
  }
private:
  static TCLink* link_reverse(TCLink* h);
  TCLink* top_;   // stack 顶
};
```

**Treiber stack 算法**:
- **push**: 1. 读 top_; 2. p->next_ = top_; 3. VCAS(&top_, old, p) 直到成功
- **pop**: 1. TAS(&top_, NULL) 一次性取走整个 stack (避免 ABA); 2. 反转链表恢复顺序

**为什么 TAS 而非 VCAS 取 stack**: TAS 一次性交换 NULL, 不会被并发 push 干扰, 也不存在 ABA 风险。

### 2.7 ob_link_hashmap — VCAS 链 + BORN_REF

[`deps/oblib/src/lib/hash/ob_link_hashmap.h:60-90`](deps/oblib/src/lib/hash/ob_link_hashmap.h):

```cpp
class DefaultUrefDecFunc {
public:
  static const int32_t BORN_REF = 1024;

  void born(Node* node)    { (void)ATOMIC_AAF(&node->uref_, BORN_REF); }   // ★ 初始
  int32_t end(Node* node)  { return ATOMIC_AAF(&node->uref_, -BORN_REF); }  // ★ 销毁
  int32_t inc(Node* node)  { return ATOMIC_AAF(&node->uref_, 1); }           // ★ in-use +1
  int32_t dec(Node* node)  { return ATOMIC_AAF(&node->uref_, -1); }          // ★ in-use -1
private:
  int32_t uref_;
};
```

[`ob_link_hashmap.h:18-30`](deps/oblib/src/lib/hash/ob_link_hashmap.h) — VCAS 链:

```cpp
// link 节点的 next_ 用 VCAS 更新
while (ov >= cmp && ov != (nv = ATOMIC_VCAS(addr, ov, ov + x))) {
  ov = nv;
}
```

**为什么 VCAS**: 链表插入 / 删除需要保证 `*next` 的原子性 — 否则两个线程同时插入会丢节点。VCAS 保证只有一个能成功修改 `next` 指针。

### 2.8 ob_slice_alloc — VCAS stock_ 区间编码

[`deps/oblib/src/lib/allocator/ob_slice_alloc.h:140-180`](deps/oblib/src/lib/allocator/ob_slice_alloc.h):

```cpp
class ObStockCtrl {
public:
  bool acquire() { return dec_if_gt(K, K) > K; }
  bool release() { return faa(-K) > 0; }
private:
  int32_t faa(int32_t x) { return ATOMIC_FAA(&stock_, x); }
  int32_t aaf(int32_t x) { return ATOMIC_AAF(&stock_, x); }
  int32_t dec_if_gt(int32_t x, int32_t b) {
    int32_t ov = ATOMIC_LOAD(&stock_);
    int32_t nv = 0;
    while (ov > b && ov != (nv = ATOMIC_VCAS(&stock_, ov, ov - x))) {   // ★ VCAS 自旋减
      ov = nv;
    }
    return ov;
  }
  int32_t inc_if_lt(int32_t x, int32_t b) {
    int32_t ov = ATOMIC_LOAD(&stock_);
    int32_t nv = 0;
    while (ov < b && ov != (nv = ATOMIC_VCAS(&stock_, ov, ov + x))) {   // ★ VCAS 自旋加
      ov = nv;
    }
    return ov;
  }
  int32_t cas_or_inc(int32_t cmpv, int32_t newv, int32_t incy);          // ★ CAS-or-inc
private:
  int32_t total_;
  int32_t stock_;
};
```

**dec_if_gt / inc_if_lt**: "如果当前值大于 b, 减 x; 否则保持" — 这是 CAS-then-update 模式, 用 VCAS 自旋直到成功。

[`ob_slice_alloc.h:90`](deps/oblib/src/lib/allocator/ob_slice_alloc.h) — 数组 free list:

```cpp
void push(void* p) {
  void** addr = data_ + ATOMIC_FAA(&push_, 1) % capacity_;     // ★ FAA 取位置
  while (!ATOMIC_BCAS(addr, NULL, p)) { PAUSE(); }            // ★ BCAS 放数据
}

void* pop() {
  void* p = NULL;
  void** addr = data_ + ATOMIC_FAA(&pop_, 1) % capacity_;      // ★ FAA 取位置
  while (NULL == (p = ATOMIC_TAS(addr, NULL))) { PAUSE(); }   // ★ TAS 取数据
  return p;
}
```

**SPSC free list 算法**:
- `push_` / `pop_` 单独 FAA (SPSC 模式, 单生产者 / 单消费者)
- 数据槽用 BCAS / TAS (防止 double-push 或读未写)

### 2.9 ob_clock_generator — BCAS 单调时间

[`deps/oblib/src/common/ob_clock_generator.h:95-108`](deps/oblib/src/common/ob_clock_generator.h):

```cpp
OB_INLINE int64_t ObClockGenerator::safe_inc_us(int64_t cur_ts) {
  int64_t origin_cur_ts = OB_INVALID_TIMESTAMP;
  do {
    origin_cur_ts = ATOMIC_LOAD(&clock_generator_.cur_ts_);
    if (origin_cur_ts < cur_ts) {
      break;
    } else {
      TRANS_LOG_RET(WARN, ..., "timestamp rollback, need advance cur ts", ...);
    }
  } while (false == ATOMIC_BCAS(&clock_generator_.cur_ts_, origin_cur_ts, cur_ts));   // ★ BCAS 单调
  return common::ObTimeUtility::current_time();
}
```

**单调整时间**: 读 → 比较 → BCAS 强制单调 — BCAS 保证只有当 origin_cur_ts 还是当前值时才更新, 防止并发 advance 导致回退。

### 2.10 ob_stat_template — BCAS lock_

[`deps/oblib/src/lib/stat/ob_stat_template.cpp:70-100`](deps/oblib/src/lib/stat/ob_stat_template.cpp):

```cpp
// 写时:
while (!ATOMIC_BCAS(&lock_, 0, WRITE_MASK)) { PAUSE(); }    // ★ WRITE_MASK 表示正在写
...  // 实际写
while (!ATOMIC_BCAS(&lock_, WRITE_MASK, 1)) { PAUSE(); }     // 释放为 1

// 读时:
while (!ATOMIC_BCAS(&lock_, WRITE_MASK, 1)) { PAUSE(); }     // 等写者完成
...  // 实际读
ATOMIC_BCAS(&lock_, 1, 0);                                    // 释放为 0
```

**读写互斥**: 用一个 int 表示 (0=空闲, 1=读中, WRITE_MASK=写中), BCAS 保证读写互斥 + 写写互斥。

### 2.11 ob_multi_mod_ref_mgr — BCAS spinlock

[`deps/oblib/src/lib/hash/ob_multi_mod_ref_mgr.h:30-50`](deps/oblib/src/lib/hash/ob_multi_mod_ref_mgr.h):

```cpp
int inc_ref() {
  while (!ATOMIC_BCAS(&lock_, 0, 1)) { PAUSE(); }    // ★ spinlock 防 ABA
  ATOMIC_INC(&ref_);
  ATOMIC_STORE(&lock_, 0);
  return OB_SUCCESS;
}
```

**cross-module 共享 ref 用 spinlock** — 比 BORN_REF 简单, 但 spinlock 开销大。

### 2.12 ob_sp_link_queue — lock-free queue

[`src/share/queue/ob_sp_link_queue.h`](src/share/queue/ob_sp_link_queue.h):

```cpp
// 类似 batch_pop_queue, 但用 SP/MPMC (单生产者多消费者 / 多生产者多消费者)
// 核心: 头尾指针分离, 用 VCAS 原子更新
// head_ ← push (用 VCAS 串成单链表, atomic next_)
// tail_ ← pop (从 tail_ 开始, 单链表遍历)
```

**SP/MPMC 算法** (Michael-Scott 风格):
- `head_` 和 `tail_` 独立原子
- push: VCAS(&head_, old, new_node)
- pop: VCAS(&tail_, old, next_node) — 注意需要解决 ABA

### 2.13 atomic128 — 128-bit CAS for table version

[`deps/oblib/src/lib/atomic/atomic128.h:25-90`](deps/oblib/src/lib/atomic/atomic128.h):

```cpp
#define CAS128_ASM(src, cmp, with) \
  __atomic_compare_exchange( \
    ((types::uint128_t*)(src)), \
    ((types::uint128_t*)(&(cmp))), \
    ((types::uint128_t*)&(with)), \
    false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)

#define LOAD128(dest, src) \
  __atomic_load(((__uint128_t*)(src)), ((__uint128_t*)(&(dest))), __ATOMIC_SEQ_CST)
```

**用途**: 128-bit CAS 用于 "version + pointer" 一起原子更新:
- 低 64 位: pointer
- 高 64 位: version

`ob_concurrent_hash_map_with_hazard_value` 的 table resize 用 128-bit CAS 一次性原子替换 (ptr + version 一起), 不需要额外的全局锁。

---

## 3. 性能优化

### 3.1 Treiber stack 的 ABA 问题

**ABA**: push(A) → pop → push(B) 复用 A 的地址, VCAS 看到 top 还是 A, 以为没变。
**OB 解决**: pop 用 TAS(&top_, NULL) **一次性取走整个 stack**, 避免 ABA — 不是单个 node 弹出。

### 3.2 per-CPU ref 的 false sharing

[`deps/oblib/src/lib/tc/deps/drwlock.h`](deps/oblib/src/lib/tc/deps/drwlock.h):

```cpp
ReadRef read_ref_[];   // per-CPU 数组
```

每个 CPU 的 ref 在不同 cache line, 减少 false sharing, 高并发读性能接近 linear scaling。

### 3.3 BCAS 自旋的退避

OB 没有指数退避, 全用 PAUSE()。在高度竞争下可能浪费 CPU, 但 OB 自旋锁多用于**临界区 < 100 ns** 场景, 不会卡。

### 3.4 VCAS vs FAA 的选择

| 场景 | 选择 | 原因 |
|------|------|------|
| 累加 (无竞争 read-modify-write) | FAA | 单条指令, 不 retry |
| 链指针更新 | VCAS | 必须有 read-then-CAS 模式 |
| Stock 区间编码 | VCAS | 需要 compare-then-update |
| 多 reader 计数 | FAA | 累加语义 |
| 时间戳单调 | BCAS | 必须 read-compare-CAS |

### 3.5 CACHE_ALIGNED on hot atomic field

```cpp
uint32_t write_flag_ CACHE_ALIGNED;     // qsync
uint64_t push_ CACHE_ALIGNED;           // slice_alloc
ObLink* retire_list_ CACHE_ALIGNED;     // hazard domain
int64_t ref_ CACHE_ALIGNED;             // multi_mod_ref_mgr
```

所有 hot atomic field 都 cache line 对齐, 避免 false sharing。

### 3.6 atomic128 的代价

`__atomic_compare_exchange` 128-bit 在 x86 没有原生支持, 编译器会 fallback 到软实现 (libatomic), 比 64-bit CAS 慢 ~5-10 倍。
仅在 **table resize** 这种罕见场景使用 (ob_concurrent_hash_map_with_hazard_value), 业务热路径不用。

---

## 4. 与 v2 主线的连接

| v2 文章 | Lock-free Data Structure 维度 |
|---------|-------------------------------|
| #74 (Thread Model) | `ob_latch` / `ob_qsync_lock` 是 worker 同步原语 |
| #75 (Latch System) | `ob_latch` 状态机完整 #75 详述, 本篇聚焦 atomic 原语 |
| #14 (MemTable) | `ob_link_hashmap` + `BORN_REF` 是 memtable 索引 |
| #51 (Block Cache) | `ob_sp_link_queue` + HP 是 KV cache 队列 |
| #56 (Logger) | `ob_stat_template` BCAS lock_ 是 logger 统计 |
| #103-105 | atomic 宏在 4 大业务模式的应用 (本篇是综合应用) |

### 主线架构图 (Lock-free Data Structure 层)

```
┌──────────────────────────────────────────────────────────┐
│  Lock-free Data Structure 集群                            │
│                                                          │
│  ob_latch                  (BCAS + WAIT_MASK)            │  ← 通用 latch
│  ob_qsync_lock             (BCAS write_flag_)            │  ← 简化 mutex
│  ob_bucket_qsync_lock      (per-bucket BCAS)              │  ← 分段锁
│  ob_darray                 (BCAS write_uid)               │  ← 可重入锁
│  drwlock                   (BCAS + FAA reader count)      │  ← RWLock
│  batch_pop_queue           (VCAS top_ Treiber)            │  ← Stack
│  ob_link_hashmap           (VCAS next + BORN_REF)         │  ← Hash Map
│  ObStockCtrl               (VCAS stock_ 区间)            │  ← 资源计数
│  ObClockGenerator          (BCAS cur_ts_)                 │  ← 单调时间
│  ob_stat_template                (BCAS lock_)              │  ← Stat counter
│  ob_multi_mod_ref_mgr      (BCAS lock_)                   │  ← Spinlock
│  ob_sp_link_queue          (VCAS head/tail)               │  ← Queue
│  atomic128                 (128-bit CAS)                  │  ← Table version
└──────────────────────────────────────────────────────────┘
                    ▲                       │
                    │ BCAS / VCAS / FAA    │ BCAS / VCAS / FAA
                    │ (lock)               │ (unlock)
                    ▼                       │
┌──────────────────────────────────────────────────────────┐
│  调用方                                                  │
│  - Worker thread (latch 抢锁)                             │
│  - MemTable insert (hash map)                            │
│  - KV cache lookup (queue)                               │
│  - Log writer (stat counter)                             │
└──────────────────────────────────────────────────────────┘
```

---

## 5. 调优 Checklist

| 项 | 检查方法 | 推荐 |
|----|---------|------|
| lock-free 临界区是否 < 1 μs | ftrace / perf | 是 (否则换 futex) |
| 自旋锁是否 PAUSE | grep `while.*BCAS` | 必须 PAUSE |
| 锁字段是否 CACHE_ALIGNED | grep `CACHE_ALIGNED` | hot lock 是 |
| per-CPU/thread 计数是否分段 | 看 read_ref_[] | 高并发下必备 |
| atomic128 仅在罕见场景 | grep `CAS128\|LOAD128` | 应只出现在 table resize |
| BCAS 是否有 break 条件 | 看 retry loop | 必须 (否则死锁) |
| BORN_REF 假设 max_users | 算 max < 1024 | 是 |

---

## 6. 常见故障 case

### Case 1: BCAS 死锁

**现象**: 进程 hang 在 BCAS 自旋, 100% CPU
**原因**:
1. 临界区内拿不到另一个锁 (lock order 反)
2. 临界区内调了 syscall 又回来
3. BORN_REF 用尽
**排查**:
```bash
gdb -p $(pidof observer) -batch -ex "bt" -ex "info threads"
```
**修复**: 拆锁, 或换 futex, 或调大 BORN_REF

### Case 2: latch 写饥饿

**现象**: writer 一直抢不到 ob_latch (reader 持续进入)
**原因**: reader critical section 长, writer busy-spin
**修复**: 减小 reader critical section, 或换 RWLock with priority

### Case 3: ABA 导致 lock-free 数据损坏

**现象**: Treiber stack 节点丢失, hash map 链表损坏
**原因**: ABA 问题没解决 (用了普通 VCAS 而非 TAS 取整个 stack)
**排查**: 检查代码是否用 TAS(&top_, NULL) 一次性取, 而非单节点 pop
**修复**: pop 改用 TAS, 或加版本号 (atomic128)

### Case 4: drwlock reader 不退出

**现象**: wrlock 等不到所有 reader 退出, 进程 hang
**原因**: rdlock / rdunlock 配对错 (漏了 rdunlock, 或 rdunlock 多次)
**排查**: 配对检查, 用 RAII 包装
**修复**: RAII 保证配对, 或加 lock guard

### Case 5: per-CPU ref 数组太小

**现象**: drwlock 高并发下 ref 计数不准确
**原因**: `arrlen(read_ref_)` 小于实际 CPU 数, 多个 CPU 共享 ref
**修复**: 调大 read_ref_ 大小 = CPU 数

### Case 6: atomic128 性能下降

**现象**: table resize 慢, QPS 抖动
**原因**: atomic128 没有原生指令, fallback libatomic
**修复**: 
- 减少 table resize 频率 (调大初始 size)
- 用 mutex 保护 resize 路径 (rare 路径用 mutex 没问题)

---

## 7. 参考 (可执行源码锚点)

| 路径 | 行 | 锚点 |
|------|---|------|
| `deps/oblib/src/lib/atomic/ob_atomic.h` | 23-79 | atomic macro 完整定义 |
| `deps/oblib/src/lib/atomic/atomic128.h` | 25-90 | CAS128 / LOAD128 128-bit CAS |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | 60-90 | wrlock BCAS + WAIT_MASK |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | 700-716 | rdunlock BCAS ref -1 |
| `deps/oblib/src/lib/lock/ob_qsync_lock.cpp` | 40-100 | qsync BCAS write_flag_ |
| `deps/oblib/src/lib/lock/ob_bucket_qsync_lock.h` | (full) | per-bucket qsync |
| `deps/oblib/src/lib/hash/ob_darray.h` | 265-285 | ob_darray BCAS write_uid |
| `deps/oblib/src/lib/tc/deps/drwlock.h` | 75-115 | drwlock BCAS + FAA reader |
| `deps/oblib/src/lib/tc/deps/batch_pop_queue.h` | 8-30 | Treiber stack VCAS top_ |
| `deps/oblib/src/lib/hash/ob_link_hashmap.h` | 18-30, 60-85 | VCAS next + BORN_REF |
| `deps/oblib/src/lib/hash/ob_link_hashmap_deps.h` | 62 | href_ |
| `deps/oblib/src/lib/allocator/ob_slice_alloc.h` | 85-180 | VCAS stock_ + FAA + TAS SPSC |
| `deps/oblib/src/common/ob_clock_generator.h` | 95-108 | BCAS cur_ts_ 单调 |
| `deps/oblib/src/lib/stat/ob_stat_template.cpp` | 70-100 | BCAS lock_ |
| `deps/oblib/src/lib/hash/ob_multi_mod_ref_mgr.h` | 30-50 | BCAS spinlock |
| `deps/oblib/src/lib/hash/ob_concurrent_hash_map_with_hazard_value.h` | (full) | HP-based hash map + atomic128 |
| `deps/oblib/src/lib/hash/ob_hazard_pointer.h` | (full) | ObHazardPointerSet 模板 |
| `src/share/queue/ob_sp_link_queue.h` | (full) | lock-free queue |

---

## 8. Cross-cutting 列表

- **5 种 lock-free 算法**: BCAS spinlock (qsync, multi_mod), VCAS 链 (link_hashmap), Treiber stack (batch_pop_queue), per-CPU ref (drwlock), HP (concurrent_hash_map), atomic128 (table version)
- **BCAS + PAUSE 模板**: 所有 `while(!ATOMIC_BCAS(...)) PAUSE()` 必须, 否则烧 CPU
- **CACHE_ALIGNED on hot field**: qsync write_flag_, slice_alloc push_/pop_, hazard retire_list_ 必须对齐
- **ABA 风险等级**: long-lifecycle 对象 (ClockGenerator cur_ts_) 低, stack (batch_pop_queue) 中, hash map node (link_hashmap) 高 — OB 用 BORN_REF 解决
- **memory order 选择**: 大多数 lock-free 用 SEQ_CST (默认), HP 用 RLX (mb_handle 字段已 SEQ_CST 同步), 限流 / 统计用 ACQ/REL
- **TAS vs VCAS**: pop 用 TAS 一次性取 (避免 ABA), push 用 VCAS retry
- **per-CPU ref**: drwlock 的 read_ref_[] 数组按 CPU 索引, 减少 false sharing
- **ob_latch 是 #74 Thread Model 和 #75 Latch System 的底层**: 所有需要锁的地方优先用 ob_latch
- **BORN_REF 假设**: 最大并发用户数 < 1024, 超过需调大常量
- **atomic128 仅限罕见路径**: 软实现比 64-bit CAS 慢 5-10x, 只用于 table resize

---

## 9. 系列总结 (#103-#106)

**原子变量在 OB 中的 4 大业务模式**:

| 模式 | 篇 | 关键原语 | 业务 |
|------|----|---------|------|
| **Counter / Metric** | #103 | `AAF` / `LOAD` / `FAA` | 统计 / 限流 / 版本 |
| **Flag / State** | #104 | `BCAS` / `LOAD` / `TAS` / `STORE` | 状态机 / lifecycle |
| **Refcount / Hazard** | #105 | `FAA` + `BORN_REF` / HP protocol | 对象生命周期 |
| **Lock-free DS** | #106 | `BCAS` + `VCAS` + `atomic128` | lock-free 数据结构 |

**4 篇累计**: 4 个文件, 约 80KB, 覆盖 OB 1024 个 atomic 文件的所有业务模式。

**OB 原子变量选型决策树**:

```
需要 atomic 吗?
├─ 否 → 普通 int64_t / bool
└─ 是 → 业务是什么?
    ├─ 统计 / 限流 / 版本号 → ATOMIC_AAF / ATOMIC_LOAD (Counter, #103)
    ├─ 状态机 / lifecycle → ATOMIC_BCAS / ATOMIC_LOAD (Flag, #104)
    ├─ 对象生命周期 → 长: FAA / 中: spinlock+BORN_REF / 短: HazardPointer (Refcount, #105)
    └─ 无锁数据结构 → latch / queue / stack / map (Lock-free, #106)
```

**总观**: OB 的 atomic 应用是 C++ 系统编程的典范 — 不滥用 (用 mutex 仍是默认), 但在 hot path 用 lock-free 拿性能, 配合 PAUSE / CACHE_ALIGNED / memory order 精细调优。

---

## 10. 后续可扩展方向

| 方向 | 内容 |
|------|------|
| **OB_ATOMIC_EVENT 剖析** | 原子操作 profiling 框架 (atomic_event.h + atomic_event_recorder) — 在生产环境开 perf mode 看哪些 hot |
| **128-bit CAS 应用** | atomic128 在 table resize / table version 的完整代码 review |
| **Memory order 选择指南** | SEQ_CST vs ACQ vs REL vs RLX 在 OB 哪些场景选用, 性能对比 |
| **OB vs Linux kernel** | RCU / seqlock / per-CPU ref 等 kernel 经典 lock-free 模式, OB 是否借鉴 / 改进 |
| **Lock-free benchmark** | OB 自研 lock-free vs third-party (folly, moodycamel) 性能对比 |
| **PAUSE 指令细节** | x86 `pause` / aarch64 `yield` 的微架构差异, PAUSE 在不同 CPU 上的优化效果 |

要写哪一篇, 给个信号继续。