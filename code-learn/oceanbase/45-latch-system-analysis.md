# 45 — ObLatch 体系 — RWLock、Futex、自旋锁

> 基于 OceanBase CE 主线源码
> 分析范围：`deps/oblib/src/lib/lock/`（22 个头文件 + 对应的 .cpp 实现）
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与代码结构分析

---

## 0. 概述

**锁体系是 OceanBase 最底层的基础设施。** 所有并发访问——内存 Hash 表、日志缓冲区、分区间通信、存储引擎的 B+Tree 页访问——最终都通过这一套锁机制来协调。

`deps/oblib/src/lib/lock/` 目录下包含 **22 个头文件** 和若干 .cpp 实现，覆盖了从单字节自旋锁到复杂的 Futex 混合锁的全谱系：

| 锁类型 | 文件 | 用途 |
|--------|------|------|
| **ObLatch** | `ob_latch.h/cpp` | 核心通用读写锁 |
| **ObLatchMutex** | `ob_latch.h/cpp` | 互斥锁（基于 Futex） |
| **ObRWLock** | `ob_rwlock.h/cpp` | 读写锁封装 |
| **ObSpinLock** | `ob_spin_lock.h` | 互斥自旋锁 |
| **SpinRWLock** | `ob_spin_rwlock.h` | 自旋读写锁 |
| **ObSmallSpinLock** | `ob_small_spin_lock.h` | 单比特自旋锁 |
| **ObByteLock** | `ob_small_spin_lock.h` | 单字节锁 |
| **ObPtrSpinLock** | `ob_small_spin_lock.h` | 指针末位锁 |
| **ObFutex** | `ob_futex.h/cpp` | Linux Futex 封装 |
| **ObMutex** | `ob_mutex.h` | 互斥量封装 |
| **ObBucketLock** | `ob_bucket_lock.h/cpp` | 哈希桶锁 |
| **ObLockGuard** | `ob_lock_guard.h` | RAII 守卫 |
| **ObDRWLock** | `ob_drw_lock.h` | Dummy 读写锁（测试用） |

这些锁的关系如下：

```
┌──────────────────────────────────────────────────────────────┐
│  锁体系架构                                                    │
│                                                                │
│  ObFutex ─── ObLatchMutex ─── ObMutex, ObSpinLock            │
│     │                                                         │
│     └────── ObLatch (读写锁, 含有等待队列) ─── ObRWLock       │
│                              ├── SpinRWLock                   │
│                              ├── ObBucketLock                 │
│                              ├── ObSmallSpinLock (1-bit)      │
│                              │   ├── ObByteLock (1-byte)      │
│                              │   └── ObPtrSpinLock (ptr LSB)  │
│                              └── RAII Guard 系列              │
└──────────────────────────────────────────────────────────────┘
```

---

## 1. ObFutex — Linux Futex 封装

### 1.1 Futex 基本原理

Futex（Fast Userspace Mutex）是 Linux 内核提供的一种**混合同步原语**：它在用户态通过原子操作尝试加锁，仅在竞争发生时陷入内核睡眠或唤醒。

OceanBase 的 `ObFutex`（`ob_futex.h:44-68`）封装了这一机制：

```cpp
class ObFutex
{
  ObFutex() : v_(), sys_waiters_() {}
  int32_t &val() { return v_; }
  uint32_t &uval() { return reinterpret_cast<uint32_t&>(v_); }
  int wait(int v, int64_t timeout);
  int wake(int64_t n);
private:
  int v_;              // 核心状态值
  int sys_waiters_;    // 正在内核睡眠的等待者计数
} CACHE_ALIGNED;       // 64 字节对齐避免 False Sharing
```

- `v_`：核心状态值，32 位整数
- `sys_waiters_`：跟踪当前在内核中睡眠的线程数
- `CACHE_ALIGNED`：强制 64 字节对齐，防止多核 CPU 的 False Sharing 问题

### 1.2 wait() 与 wake() 实现

**wait()**（`ob_futex.cpp:26-39`）：

```cpp
int ObFutex::wait(int v, int64_t timeout)
{
  int ret = OB_SUCCESS;
  const auto ts = make_timespec(timeout);
  ATOMIC_INC(&sys_waiters_);
  int eret = futex_wait(&v_, v, &ts);
  if (OB_UNLIKELY(eret != 0)) {
    if (OB_UNLIKELY(eret == ETIMEDOUT)) {
      ret = OB_TIMEOUT;
    }
  }
  ATOMIC_DEC(&sys_waiters_);
  return ret;
}
```

1. 增加 `sys_waiters_` 计数
2. 调用 `futex_wait`（`SYS_futex` 系统调用），在 `v_` 值不变时睡眠
3. 被唤醒或超时后，减少 `sys_waiters_` 计数
4. 超时返回 `OB_TIMEOUT`

**wake()**（`ob_futex.cpp:41-52`）：

```cpp
int ObFutex::wake(int64_t n)
{
  int cnt = 0;
  if (n >= INT32_MAX) {
    cnt = futex_wake(&v_, INT32_MAX);
  } else {
    cnt = futex_wake(&v_, static_cast<int32_t>(n));
  }
  return cnt;
}
```

调用 `futex_wake` 唤醒最多 `n` 个等待者。

### 1.3 Futex Hook

通过弱符号 `futex_hook`（`ob_futex.cpp:20-23`）：

```cpp
int __attribute__((weak)) futex_hook(uint32_t *uaddr, int futex_op,
    uint32_t val, const struct timespec* timeout)
{
  return syscall(SYS_futex, uaddr, futex_op, val, timeout);
}
```

使用 `__attribute__((weak))` 允许外部覆盖（比如测试时注入 mock 实现）。

---

## 2. ObLatchMutex — 基于 Futex 的互斥锁

`ObLatchMutex` 是 OceanBase 中最基础的互斥锁，直接构建在 `ObFutex` 之上。

### 2.1 核心数据结构（`ob_latch.h:91-122`）

```cpp
class ObLatchMutex
{
  // ...
  int lock(const uint32_t latch_id, const int64_t abs_timeout_us = INT64_MAX,
           const bool is_atomic = true);
  int try_lock(const uint32_t latch_id, const uint32_t *puid = NULL);
  int wait(const int64_t abs_timeout_us, const uint32_t uid);
  int unlock();
  // ...
private:
  static const int64_t MAX_SPIN_CNT_AFTER_WAIT = 1;
  static const uint32_t WRITE_MASK = 1<<30;
  static const uint32_t WAIT_MASK = 1<<31;
  lib::ObFutex lock_;
  bool record_stat_;
};
```

**锁状态值编码**（一个 `uint32_t` 承载所有状态）：

```
Bit 31 (WAIT_MASK)   : 是否有等待者
Bit 30 (WRITE_MASK)  : 是否被持有
Bits 0-29            : 持有者的线程 ID (uid)
```

- `lock_ = 0` → 未锁定
- `lock_ = WRITE_MASK | uid` → 被线程 uid 持有
- `lock_ = WRITE_MASK | WAIT_MASK | uid` → 被持有，且有等待者

### 2.2 lock() 实现（`ob_latch.cpp:59-124`）

lock() 采用**三级退避策略**：

1. **自旋阶段**：`low_try_lock()` 循环 CAS（最多 `max_spin_cnt_` 次），每次失败后 `PAUSE()` 指令
2. **让出阶段**：`sched_yield()`，最多 `max_yield_cnt_` 次
3. **睡眠阶段**：调用 `ObFutex::wait()` 陷入内核

```cpp
int ObLatchMutex::lock(const uint32_t latch_id, const int64_t abs_timeout_us,
                       const bool is_atomic)
{
  while (OB_SUCC(ret)) {
    i = low_try_lock(OB_LATCHES[latch_id].max_spin_cnt_, (WRITE_MASK | uid));
    // 自旋成功 → 退出
    if (i < max_spin_cnt_) break;
    // 自旋失败，sched_yield
    if (yield_cnt < max_yield_cnt_) { sched_yield(); continue; }
    // 自旋 + yield 都失败 → Futex 睡眠
    waited = true;
    ret = wait(abs_timeout_us, uid);
  }
}
```

`low_try_lock()`（`ob_latch.h` 内联实现，约 493 行）：

```cpp
OB_INLINE uint64_t ObLatchMutex::low_try_lock(const int64_t max_spin_cnt,
    const uint32_t lock_value)
{
  uint64_t spin_cnt = 0;
  for (; spin_cnt < max_spin_cnt; ++spin_cnt) {
    if (0 == lock_.val()) {
      if (ATOMIC_BCAS(&lock_.val(), 0, lock_value)) {
        reg_lock((uint32_t*)(&lock_.val()));
        break;
      }
    }
    PAUSE();
  }
  return spin_cnt;
}
```

`try_lock()`（`ob_latch.cpp:32-57`）则是单次 CAS 尝试，失败返回 `OB_EAGAIN`。

### 2.3 wait() 实现（`ob_latch.cpp:130-171`）

在进入内核睡眠前，尝试设置 `WAIT_MASK` 位：

```cpp
int ObLatchMutex::wait(const int64_t abs_timeout_us, const uint32_t uid)
{
  while (OB_SUCC(ret)) {
    timeout = abs_timeout_us - ObTimeUtility::current_time();
    if (timeout <= 0) { ret = OB_TIMEOUT; break; }
    lock = lock_.val();
    if (WAIT_MASK == (lock & WAIT_MASK)
        || 0 != (lock = ATOMIC_CAS(&lock_.val(), (lock | WRITE_MASK),
                                   (lock | WAIT_MASK)))) {
      ret = lock_.wait((lock | WAIT_MASK), timeout);  // Futex wait
    }
    // 醒来后再次尝试自旋获取锁
    if (MAX_SPIN_CNT_AFTER_WAIT > low_try_lock(MAX_SPIN_CNT_AFTER_WAIT,
                                                 (WAIT_MASK | WRITE_MASK | uid))) {
      break;
    }
  }
}
```

重要细节：等待期间持有 `WRITE_MASK` 将其他线程屏蔽（写者独占），`WAIT_MASK` 标记等待队列非空。

### 2.4 unlock() 实现（`ob_latch.cpp:175-188`）

```cpp
int ObLatchMutex::unlock()
{
  uint32_t lock = ATOMIC_SET(&lock_.val(), 0);  // 原子清零
  if (0 == lock) return OB_ERR_UNEXPECTED;       // 重复解锁检测
  if (0 != (lock & WAIT_MASK)) {
    lock_.wake(1);  // 有等待者则唤醒一个
  }
  return OB_SUCCESS;
}
```

---

## 3. ObLatch — 核心读写锁

`ObLatch` 是 OceanBase 最核心的锁——支持**读共享 + 写独占**，且内含**等待队列**实现公平调度。

### 3.1 状态编码（`ob_latch.h:298-302`）

ObLatch 使用 `volatile uint32_t lock_` 编码所有状态：

```
Bit 31 (WAIT_MASK)    : 等待队列非空
Bit 30 (WRITE_MASK)   : 写锁持有
Bits 0-29:
  - 写锁持有 → 持有者的线程 ID
  - 无写锁 → 当前读锁计数 (最大 2^24)
```

ObLatch 的特殊设计：**读写锁状态共享一个 32-bit 字**。

### 3.2 读锁定（`ob_latch.h:268-291`）

`LowTryRDLock::operator()()`（读锁尝试函数）：

```cpp
inline int ObLatch::LowTryRDLock::operator()(volatile uint32_t *latch,
    const uint32_t lock, const uint32_t uid, bool &conflict)
{
  if ((0 == (lock & WRITE_MASK)) && (ignore_ || (0 == (lock & WAIT_MASK)))) {
    if ((lock & (~WAIT_MASK)) < MAX_READ_LOCK_CNT) {
      conflict = false;
      if (ATOMIC_BCAS(latch, lock, lock + 1)) {  // 读者计数 +1
        reg_lock((uint32_t*)latch);
        return OB_SUCCESS;
      }
    } else {
      conflict = true;  // 读锁超限
      return OB_SIZE_OVERFLOW;
    }
  } else {
    conflict = true;  // 写锁持有或有等待者
  }
  return OB_EAGAIN;
}
```

关键设计点：
- `ignore_` 参数：为 `true` 时忽略 `WAIT_MASK`（用于等待队列内部加锁）
- `MAX_READ_LOCK_CNT = 1<<24`：最多 16,777,216 个并发读者
- 有写锁时直接返回冲突

### 3.3 写锁定（`ob_latch.h:292-307`）

`LowTryWRLock::operator()()`：

```cpp
inline int ObLatch::LowTryWRLock::operator()(volatile uint32_t *latch,
    const uint32_t lock, const uint32_t uid, bool &conflict)
{
  if (0 == lock || (ignore_ && (WAIT_MASK == lock))) {
    conflict = false;
    if (ATOMIC_BCAS(latch, lock, (lock | (WRITE_MASK | uid)))) {
      reg_lock((uint32_t*)latch);
      return OB_SUCCESS;
    }
  } else {
    conflict = true;
  }
  return OB_EAGAIN;
}
```

写锁要求 `lock_` 为 0（完全空闲），或 `ignore_` 模式下仅 `WAIT_MASK` 被设置。

### 3.4 low_lock() — 核心加锁循环（`ob_latch.cpp:300-348`）

```cpp
template<typename LowTryLock>
OB_INLINE int ObLatch::low_lock(
    const uint32_t latch_id, const int64_t abs_timeout_us,
    const uint32_t uid, const uint32_t wait_mode,
    LowTryLock &lock_func, LowTryLock &lock_func_ignore)
{
  while (OB_SUCC(ret)) {
    // 1. 自旋
    for (i = 0; OB_SUCC(ret) && i < max_spin_cnt_; ++i) {
      if (OB_SUCC(lock_func(&lock_, lock_, uid, conflict))) break;
      PAUSE();
    }
    // 2. 让出 CPU
    if (i >= max_spin_cnt_ && yield_cnt < max_yield_cnt_) {
      sched_yield(); continue;
    }
    // 3. 等待队列
    waited = true;
    ObWaitProc proc(*this, wait_mode);
    ret = ObLatchWaitQueue::get_instance().wait(
        proc, latch_id, uid, lock_func, lock_func_ignore, abs_timeout_us);
  }
}
```

### 3.5 unlock() 实现（`ob_latch.cpp:247-276`）

```cpp
int ObLatch::unlock(const uint32_t *puid)
{
  if (0 != (lock & WRITE_MASK)) {
    // 写锁解锁：清除 WRITE_MASK，保留 WAIT_MASK
    lock = ATOMIC_ANDF(&lock_, WAIT_MASK);
  } else if ((lock & (~WAIT_MASK)) > 0) {
    // 读锁解锁：递减读者计数
    lock = ATOMIC_AAF(&lock_, -1);
  }
  if (WAIT_MASK == lock) {
    ObLatchWaitQueue::get_instance().wake_up(*this);  // 唤醒等待者
  }
}
```

### 3.6 wr2rdlock() — 写锁降级为读锁（`ob_latch.cpp:225-243`）

```cpp
int ObLatch::wr2rdlock(const uint32_t *puid)
{
  // 将 WRITE_MASK | uid 替换为 reader count = 1
  uint32_t lock = lock_;
  while (!ATOMIC_BCAS(&lock_, lock, (lock & WAIT_MASK) + 1)) {
    lock = lock_;
    PAUSE();
  }
  // 唤醒等待队列中的读者（only_rd_wait = true）
  ObLatchWaitQueue::get_instance().wake_up(*this, true);
}
```

写锁降级是一个**极其优雅**的设计——线程先以写者身份操作，完成后再降级为读者持有，同时唤醒后续等待的读者。

### 3.7 与 Linux 内核 mutex 的对比

| 特性 | OceanBase ObLatch | Linux 内核 mutex |
|------|-------------------|------------------|
| 数据结构 | `volatile uint32_t` | `atomic_long_t` + `struct mutex_waiter` |
| 状态编码 | 单字编码：W/R/WAIT | 独立字段 |
| 自旋策略 | 可配置 max_spin_cnt + sched_yield | optimistic spinning |
| 等待队列 | 全局 3079 桶哈希队列 | 每个 mutex 独立链表 |
| 公平性 | 支持 FIFO 和 READ_PREFER | 自有 handoff 机制 |
| 读取计数 | 支持（最多 2^24 个读者） | 纯互斥 |

核心差异：ObLatch 是一个**读写锁**而非互斥锁，同时支持读锁计数和写锁降级。而 Linux 内核的 mutex 是纯互斥锁，没有读共享语义。

---

## 4. ObLatchWaitQueue — 等待队列

### 4.1 设计概述

`ObLatchWaitQueue`（`ob_latch.h:151-202`）是全局单例，用于管理所有 ObLatch 和 ObLatchMutex 的等待者。采用**哈希桶**结构分散锁竞争：

```cpp
class ObLatchWaitQueue
{
  static const uint64_t LATCH_MAP_BUCKET_CNT = 3079;  // 质数
  ObLatchBucket wait_map_[LATCH_MAP_BUCKET_CNT];       // 3079 个桶

  struct ObLatchBucket {
    ObDList<ObWaitProc> wait_list_;  // 等待者双向链表
    ObLatchMutex lock_;              // 桶级保护锁
  } CACHE_ALIGNED;
};
```

- **3079 个桶**（质数，均匀分布）
- 每个桶有自己的 `ObLatchMutex`，避免全局锁竞争
- 桶索引通过 `address % 3079` 计算

### 4.2 wait() 实现（`ob_latch.cpp:71-164`）

```cpp
int ObLatchWaitQueue::wait(ObWaitProc &proc, const uint32_t latch_id,
    const uint32_t uid, LowTryLock &lock_func,
    LowTryLock &lock_func_ignore, const int64_t abs_timeout_us)
{
  // 1. 尝试加锁
  ret = try_lock(bucket, proc, latch_id, uid, lock_func);

  while (OB_EAGAIN == ret) {
    // 2. Futex 睡眠（等待被唤醒或超时）
    ts.tv_sec = timeout / 1000000;
    ts.tv_nsec = 1000 * (timeout % 1000000);
    tmp_ret = futex_wait(&proc.wait_, 1, &ts);

    // 3. 醒来后尝试用 lock_func_ignore 加锁
    while (!conflict) {
      if (OB_SUCC(lock_func_ignore(&latch.lock_, latch.lock_, uid, conflict))) break;
      PAUSE();
    }
  }

  // 4. 如果 wait_ 仍为 1，从等待队列移除
  if (proc.wait_ == 1) {
    bucket.wait_list_.remove(&proc);
    // 如果此 Latch 无其他等待者，清除 WAIT_MASK
    if (!has_wait) {
      ATOMIC_ANDF(&latch.lock_, ~WAIT_MASK);
    }
  }
}
```

`try_lock()`（`ob_latch.cpp:378-415`）：

```cpp
template<typename LowTryLock>
int ObLatchWaitQueue::try_lock(ObLatchBucket &bucket, ObWaitProc &proc,
    const uint32_t latch_id, const uint32_t uid, LowTryLock &lock_func)
{
  lock_bucket(bucket);
  while (true) {
    if (OB_SUCC(lock_func(&latch.lock_, latch.lock_, uid, conflict))) break;
    // 竞争时设置 WAIT_MASK
    if (conflict && ATOMIC_BCAS(&latch.lock_, lock, lock | WAIT_MASK)) break;
  }
  // 加锁失败 → 加入等待队列
  if (policy == LATCH_READ_PREFER && mode == READ_WAIT) {
    bucket.wait_list_.add_first(&proc);   // 读优先：读者插队到队首
  } else {
    bucket.wait_list_.add_last(&proc);    // FIFO：写入队尾
  }
  proc.wait_ = 1;
  unlock_bucket(bucket);
}
```

### 4.3 wake_up() 实现（`ob_latch.cpp:166-245`）

```cpp
int ObLatchWaitQueue::wake_up(ObLatch &latch, const bool only_rd_wait)
{
  lock_bucket(bucket);
  do {
    // 遍历等待列表，收集可唤醒的等待者
    for (iter = bucket.wait_list_.get_first(); ...; ) {
      if (iter->addr_ == &latch) {
        if (READ_WAIT || (WRITE_WAIT && 0 == wake_cnt && !only_rd_wait)) {
          wake_list.add_last(iter);  // 加入唤醒列表
          ++wake_cnt;
        }
        if (WRITE_WAIT && wake_cnt > 0) break;  // 写者只唤醒一个
      }
    }

    // futex_wake 唤醒每个等待者
    for (iter = wake_list.get_first(); ...; ) {
      *pwait = 0;                                            // 清标志
      if (1 == futex_wake(pwait, 1)) ++actual_wake_cnt;      // 唤醒
    }
  } while (actual_wake_cnt == 0 && !only_rd_wait && has_wait);

  unlock_bucket(bucket);
}
```

唤醒策略：
- 默认：先唤醒所有连续读者，然后一个写者
- `only_rd_wait=true`（wr2rdlock）：只唤醒读者
- 至少唤醒一个等待者才退出，避免丢失唤醒

---

## 5. ObRWLock — 读写锁封装

`ObRWLock`（`ob_rwlock.h`）是对 ObLatch 的 RAII 友好封装。

### 5.1 无优先级版本（`ob_rwlock.h:75-88`）

```cpp
template <LockMode lockMode = NO_PRIORITY>
class ObRWLock
{
  ObLatch rwlock_;
  ObRLock<ObLatch> rlock_;
  ObWLock<ObLatch> wlock_;
public:
  ObRLock<ObLatch>* rlock() const { return &rlock_; }
  ObWLock<ObLatch>* wlock() const { return &wlock_; }
};
```

`ObRLock` 和 `ObWLock` 只是对 `ObLatch` 的 `rdlock()`/`wrlock()` 的简单封装。

### 5.2 写优先版本（`ob_rwlock.h:91-113`）— 特化

```cpp
template<>
class ObRWLock<WRITE_PRIORITY>
{
  pthread_rwlock_t rwlock_;
public:
  ObRWLock(uint32_t latch_id) {
    pthread_rwlockattr_setkind_np(&attr,
        PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP);
    pthread_rwlock_init(&rwlock_, &attr);
  }
};
```

写优先版本直接使用 POSIX 线程读写锁（`pthread_rwlock_t`），通过 `PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP` 属性实现写者优先。

**设计决策**：默认版本使用 ObLatch（用户态实现，灵活性高），写优先版本则委托给 POSIX 原生实现。这种混用策略在工业级数据库中并不少见——POSIX 实现经过充分测试，且写者优先语义需要内核支持才能严格保障。

---

## 6. SpinLock 系列

### 6.1 ObSpinLock（`ob_spin_lock.h`）

`ObSpinLock` 是 `ObLatchMutex` 的薄封装：

```cpp
class ObSpinLock
{
  ObLatchMutex latch_;
  uint32_t latch_id_;
public:
  int lock() { return latch_.lock(latch_id_); }
  int trylock() { return latch_.try_lock(latch_id_); }
  int unlock() { return latch_.unlock(); }
  bool self_locked() { return latch_.get_wid() == GETTID(); }
};
typedef lib::ObLockGuard<ObSpinLock> ObSpinLockGuard;
```

尽管名为"自旋锁"，`ObSpinLock` 实际上使用 ObLatchMutex 的**三级退避**策略（自旋 + yield + Futex 睡眠），而非纯自旋。在短临界区场景下，`low_try_lock()` 中自旋 `PAUSE()` 足够先满足绝大部分加锁请求，纯自旋的退化为 Futex 睡眠是兜底行为。

### 6.2 SpinRWLock（`ob_spin_rwlock.h`）

`SpinRWLock` 是 `ObLatch` 的薄封装：

```cpp
class SpinRWLock
{
  ObLatch latch_;
  uint32_t latch_id_;
public:
  bool try_rdlock() { return OB_SUCCESS == latch_.try_rdlock(latch_id_); }
  int rdlock(int64_t abs_timeout_us = INT64_MAX) { return latch_.rdlock(latch_id_, abs_timeout_us); }
  int wrlock(int64_t abs_timeout_us = INT64_MAX) { return latch_.wrlock(latch_id_, abs_timeout_us); }
  int unlock() { return latch_.unlock(); }
};
```

提供 `SpinRLockGuard`、`SpinWLockGuard`、`SpinRLockManualGuard` 等 RAII 守卫。

### 6.3 ObSmallSpinLock — 单比特自旋锁（`ob_small_spin_lock.h`）

这是 OceanBase 中最极致的锁——**仅用 1 个比特位**实现自旋锁。

```cpp
template <typename IntType, int64_t LockBit = 0,
          int64_t MaxSpin = 500, int64_t USleep = 100>
class ObSmallSpinLock
{
  static const IntType LOCK_MASK = static_cast<IntType>(1) << LockBit;
  IntType lock_;
public:
  void init() { lock_ &= ~LOCK_MASK; }

  bool try_lock() {
    IntType lock_val = ATOMIC_LOAD(&lock_);
    if (0 == (lock_val & LOCK_MASK)) {
      return ATOMIC_BCAS(&lock_, lock_val, (lock_val | LOCK_MASK));
    }
    return false;
  }

  void lock(const int64_t event_no = 0) {
    for (; !locked && cnt <= MaxSpin; ++cnt) {
      locked = try_lock();
      if (!locked) PAUSE();
    }
    while (false == try_lock()) {     // 自旋超限后 sleep
      if (MaxSpin <= (cnt++)) {
        cnt = 0; ::usleep(USleep);
      }
      PAUSE();
    }
  }

  void unlock() {
    IntType lock_val = ATOMIC_LOAD(&lock_);
    ATOMIC_SET(&lock_, (lock_val & (~LOCK_MASK)));
  }

  IntType get_data() const { return lock_ & (~LOCK_MASK); }
  void set_data(const IntType &val) {
    lock_ = (val & (~LOCK_MASK)) | (lock_ & LOCK_MASK);
  }
};
```

**使用模式**：

**模式一**：独立的锁对象
```cpp
// 用 uint32_t 的 bit 0 做锁，剩余 31 位存储数据
typedef ObSmallSpinLock<uint32_t, 0> SmallLock;
SmallLock lock;
lock.lock();
lock.set_data(0x02);
uint32_t val = lock.get_data();
lock.unlock();
```

**模式二**：寄生在已有整数中的锁位
```cpp
// 在已有标志位中使用 bit 0 作为自旋锁
uint32_t flag = 0x00;
auto &lock = SmallLock::AsLock(flag);  // reinterpret_cast
lock.init(0x02);  // 初始化数据位
lock.lock();      // 自旋锁占用 bit 0
lock.set_data(0x04);  // 安全设置剩余数据位
uint32_t val = lock.get_data();
lock.unlock();
```

**模式三**：指针末位锁（`ObPtrSpinLock`，`ob_small_spin_lock.h:203-248`）

```cpp
template <typename T>
struct ObPtrSpinLock
{
  typedef uint64_t ValType;
  ObSmallSpinLock<ValType, 0> lock_;

  void init() { lock_.init(); lock_.set_data(0); }
  T* get_ptr() { return reinterpret_cast<T*>(lock_.get_data()); }
  void set_ptr(const T *ptr) { lock_.set_data(reinterpret_cast<ValType>(ptr)); }
};
```

利用指针值永远偶数的特性（malloc 对齐），用其**最低位**作为自旋锁标志位。这是一种极其巧妙的空间优化——零额外内存开销。

**辅助类型**：
- `ObByteLock`：`typedef ObSmallSpinLock<uint8_t, 0> ObByteLock;`（单字节锁）
- `ObByteLockGuard`：配套 RAII 守卫

### 6.4 自旋锁实现对比

| 实现 | 自旋策略 | 睡眠策略 | 内存开销 | 适用场景 |
|------|---------|---------|---------|---------|
| ObSpinLock | `low_try_lock` CAS + PAUSE | Futex 睡眠 | 1 × ObFutex (8B) | 通用短临界区 |
| SpinRWLock | ObLatch spin + yield | ObLatchWaitQueue | 1 × ObLatch (8B) | 读多写少 |
| ObSmallSpinLock | CAS + PAUSE + usleep | usleep | 1 bit (0.125B) | 极致紧凑场景 |
| ObPtrSpinLock | CAS + PAUSE + usleep | usleep | 0 (借用 ptr LSB) | 指针自身加锁 |

---

## 7. ObBucketLock — 哈希桶锁

`ObBucketLock`（`ob_bucket_lock.h:26-70`）是一种**分片锁**——将大量锁按照哈希值分配到少量 ObLatch 实例上，降低内存开销。

```cpp
class ObBucketLock
{
  uint64_t bucket_cnt_;  // 逻辑桶数（可很大）
  uint64_t latch_cnt_;   // 实际锁数（8 个 ObLatch 一组）
  ObLatch *latches_;     // ObLatch 数组
  uint32_t latch_id_;
};
```

**关键映射**（`ob_bucket_lock.h:328-335`）：

```cpp
uint64_t ObBucketLock::bucket_to_latch_idx(const uint64_t bucket_idx) const
{
  return bucket_idx / 8;  // 每 8 个桶共享一个 ObLatch
}

uint64_t ObBucketLock::get_bucket_idx(const uint64_t hash_value) const
{
  return hash_value % bucket_cnt_;
}
```

- 每个实际 ObLatch 保护 8 个逻辑桶
- 支持 `rdlock_all()`/`wrlock_all()` 全局锁定（用于批量操作如检查点）
- 提供全套 RAII Guard：`ObBucketRLockGuard`、`ObBucketWLockGuard`、`ObBucketWLockAllGuard` 等

**使用场景**：OceanBase 的 `BlockManager`、`MemTable` 的哈希索引等需要大量槽位的并发保护。

---

## 8. ObMutex 和 RAII Guards

### 8.1 ObMutex（`ob_mutex.h`）

`ObMutex` 是 `ObLatchMutex` 的简单封装：

```cpp
class ObMutex {
  common::ObLatchMutex latch_;
  uint32_t latch_id_;
public:
  int lock(const int64_t abs_timeout_us = INT64_MAX);
  int trylock();
  int unlock();
};
typedef ObLockGuard<ObMutex> ObMutexGuard;
typedef ObLockGuardWithTimeout<ObMutex> ObMutexGuardWithTimeout;
```

### 8.2 RAII Guard 体系

| Guard 类 | 锁类型 | 文件 |
|----------|--------|------|
| `ObLockGuard<T>` | 任意 lock/unlock 类型 | `ob_lock_guard.h:25` |
| `ObLockGuardWithTimeout<T>` | 支持 timeout 的锁 | `ob_lock_guard.h:83` |
| `ObLatchRGuard` | ObLatch 读锁 | `ob_latch.h:435` |
| `ObLatchWGuard` | ObLatch 写锁 | `ob_latch.h:463` |
| `ObLatchMutexGuard` | ObLatchMutex 锁 | `ob_latch.h:409` |
| `ObSpinLockGuard` | ObSpinLock | `ob_spin_lock.h:101` |
| `SpinRLockGuard` | SpinRWLock 读锁 | `ob_spin_rwlock.h:61` |
| `SpinWLockGuard` | SpinRWLock 写锁 | `ob_spin_rwlock.h:118` |
| `ObSmallSpinLockGuard<T>` | ObSmallSpinLock | `ob_small_spin_lock.h:186` |
| `ObPtrSpinLockGuard<T>` | ObPtrSpinLock | `ob_small_spin_lock.h:250` |
| `ObBucketRLockGuard` | ObBucketLock 读 | `ob_bucket_lock.h:75` |
| `ObBucketWLockGuard` | ObBucketLock 写 | `ob_bucket_lock.h:116` |
| `ObRLockGuard` | ObRWLock 读 | `ob_rwlock.h:117` |
| `ObWLockGuard` | ObRWLock 写 | `ob_rwlock.h:139` |

全部使用 `[[nodiscard]]` 属性，防止返回值被忽略。

---

## 9. 锁的选择策略

| 场景 | 推荐锁 | 理由 |
|------|--------|------|
| 短临界区，低竞争 | `ObSpinLock` / `ObSmallSpinLock` | 纯自旋，低延迟 |
| 读多写少，可阻塞 | `ObLatch` / `SpinRWLock` / `ObRWLock` | 读共享等待队列 |
| 可能阻塞，纯互斥 | `ObLatchMutex` / `ObMutex` | Futex 睡眠 |
| 需要细粒度等待 | `ObFutex` | 用户态 CAS + 内核睡眠 |
| 哈希分片并发 | `ObBucketLock` | 降低锁竞争 |
| 指针自身加锁 | `ObPtrSpinLock` | 零额外内存开销 |
| 读多写少+写者优先 | `ObRWLock<WRITE_PRIORITY>` | POSIX pthread 实现 |
| 极致内存紧缩 | `ObSmallSpinLock` (1 bit) / `ObByteLock` (1 byte) | 极低开销 |
| 写锁降级为读锁 | `ObLatch::wr2rdlock()` | 减少锁释放重获开销 |

---

## 10. 设计决策分析

### 10.1 三级退避：自旋 → yield → Futex 睡眠

所有阻塞型锁（ObLatchMutex、ObLatch）都采用三级退避：

1. **自旋阶段**：CPU 忙等，`PAUSE()` 指令缓解流水线压力 + 减少功耗
2. **yield 阶段**：`sched_yield()` 让出时间片，给其他线程运行机会
3. **Futex 睡眠阶段**：内核介入，线程进入睡眠，不消耗 CPU

**为何不是纯自旋锁？** 分布式数据库的等待时间不可控（可能等待磁盘 IO、网络 RPC），纯自旋会浪费大量 CPU 资源。三级退避在绝大多数短临界区命中自旋阶段，在长临界区优雅降级到内核睡眠。

### 10.2 单字状态编码

ObLatch 和 ObLatchMutex 将读写锁状态、等待标志、持有者 ID、读者计数**全部塞入一个 uint32_t**。这种设计使得：
- 所有状态变更可通过**单次 CAS 或 Fetch-And 操作**完成
- 无锁内部状态，避免读取多字的竞态条件
- `is_locked()` / `is_rdlocked()` / `is_wrlocked()` / `get_wid()` / `get_rdcnt()` 全部通过单次 `ATOMIC_LOAD` 完成

代价是状态位紧张——写锁最多 30-bit 线程 ID（约 10 亿），读者最多 24-bit（约 1677 万），在面对极高并发时需注意。

### 10.3 全局等待队列 vs 局部等待队列

ObLatch 使用**全局哈希等待队列**（3079 个桶），而非每个锁独立维护等待链表。

**优点**：
- 内存零开销——只在需要等待时才分配 `ObWaitProc`（栈上对象）
- 桶数固定 3079，不会随锁数增长

**代价**：
- `wake_up()` 需要遍历桶中链表找到对应 ObLatch 的等待者
- 哈希冲突带来的假共享可能

与 Linux 内核 mutex 的每个锁独立等待队列不同，OceanBase 的设计更偏内存优化。

### 10.4 PAUSE 指令优化

所有自旋循环中都使用 `PAUSE()` 指令（`ob_latch.h` 中的 `low_try_lock`、`ob_small_spin_lock.h` 中的 `lock` 函数）。

`PAUSE()` 在 x86 上是 `REP NOP`（在 ARM 上是 `YIELD`），其作用是：
1. **降低功耗**：自旋时不占满流水线
2. **缓解内存排序**：暗示处理器这是一个自旋等待循环
3. **提高超线程效率**：让另一个逻辑核心更好运行

### 10.5 读写公平性

ObLatch 支持两种公平性策略：

- **LATCH_FIFO**: 严格 FIFO 顺序，写者等待时不打断队列
- **LATCH_READ_PREFER**: 读者优先，新读者可在等待队列之前获取读锁

在 `ObLatchWaitQueue::try_lock()` 中，`READ_PREFER` 策略下的读者被插入等待队列**队首**，而非队尾：

```cpp
if (ObLatchPolicy::LATCH_READ_PREFER == OB_LATCHES[latch_id].policy_
    && ObLatchWaitMode::READ_WAIT == proc.mode_) {
  bucket.wait_list_.add_first(&proc);   // 读者插队
} else {
  bucket.wait_list_.add_last(&proc);    // 写者排队
}
```

`wake_up()` 中也会先唤醒所有连续读者，再唤醒一个写者。

### 10.6 读锁上限保护

```cpp
if ((lock & (~WAIT_MASK)) >= MAX_READ_LOCK_CNT) {
  conflict = true;
  return OB_SIZE_OVERFLOW;
}
```

`MAX_READ_LOCK_CNT = 1<<24 = 16,777,216`，超过此数返回 `OB_SIZE_OVERFLOW` 保护锁状态不溢出。

### 10.7 ObSmallSpinLock 的极致优化

**1 比特实现自旋锁**的技术要点：
1. 同一个整数的高位仍可用于存储数据
2. `reinterpret_cast` 实现类型转换（`AsLock()` 方法）
3. 利用指针对齐保证末位始终为 0（`ObPtrSpinLock`）
4. 自旋超限后 `usleep()` 而非 Futex（保持轻量）
5. 模板参数 `LockBit` 可指定任意比特位位置

---

## 11. 源码索引

| 文件 | 关键结构 | 行号 |
|------|---------|------|
| `deps/oblib/src/lib/lock/ob_latch.h` | `ObLatchMutex` 类定义 | 91 |
| `deps/oblib/src/lib/lock/ob_latch.h` | `ObLatch` 类定义 | 209 |
| `deps/oblib/src/lib/lock/ob_latch.h` | `ObLatchWaitQueue` 类定义 | 151 |
| `deps/oblib/src/lib/lock/ob_latch.h` | `ObWaitProc` 等待者结构 | 125 |
| `deps/oblib/src/lib/lock/ob_latch.h` | `LowTryRDLock` 实现 | 268 |
| `deps/oblib/src/lib/lock/ob_latch.h` | `LowTryWRLock` 实现 | 286 |
| `deps/oblib/src/lib/lock/ob_latch.h` | LatchMutex `low_try_lock` | 493 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatchMutex::lock` | 59 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatchMutex::wait` | 130 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatchMutex::unlock` | 175 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatchWaitQueue::wait` | 71 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatchWaitQueue::wake_up` | 166 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatchWaitQueue::try_lock` | 378 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatch::low_lock`（核心循环） | 300 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatch::rdlock` | 194 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatch::wrlock` | 207 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatch::wr2rdlock` | 225 |
| `deps/oblib/src/lib/lock/ob_latch.cpp` | `ObLatch::unlock` | 247 |
| `deps/oblib/src/lib/lock/ob_futex.h` | `ObFutex` 类定义 | 44 |
| `deps/oblib/src/lib/lock/ob_futex.cpp` | `ObFutex::wait` / `wake` 实现 | 26 |
| `deps/oblib/src/lib/lock/ob_rwlock.h` | `ObRWLock<NO_PRIORITY>` | 75 |
| `deps/oblib/src/lib/lock/ob_rwlock.h` | `ObRWLock<WRITE_PRIORITY>` 特化 | 91 |
| `deps/oblib/src/lib/lock/ob_spin_lock.h` | `ObSpinLock` 类 | 31 |
| `deps/oblib/src/lib/lock/ob_spin_rwlock.h` | `SpinRWLock` 类 | 28 |
| `deps/oblib/src/lib/lock/ob_small_spin_lock.h` | `ObSmallSpinLock` 模板 | 68 |
| `deps/oblib/src/lib/lock/ob_small_spin_lock.h` | `ObPtrSpinLock` 指针锁 | 203 |
| `deps/oblib/src/lib/lock/ob_bucket_lock.h` | `ObBucketLock` 桶锁 | 26 |
| `deps/oblib/src/lib/lock/ob_mutex.h` | `ObMutex` | 31 |
| `deps/oblib/src/lib/lock/ob_lock_guard.h` | `ObLockGuard` / `ObLockGuardWithTimeout` | 25 |

---

## 12. 总结

OceanBase 的锁体系是一套**精心设计的多层次并发控制基础设施**，其设计哲学可以总结为：

1. **单一核心原语 + 多层次封装**：`ObFutex` → `ObLatchMutex` / `ObLatch` → 各种高层锁
2. **三级退避策略**：自旋 → yield → Futex 睡眠，兼顾短临界区延迟和长临界区 CPU 效率
3. **极致内存优化**：从全局单例等待队列（3079 桶）到单比特自旋锁到指针末位锁
4. **位压缩状态编码**：一个 uint32_t 同时承载锁状态、等待标志、持有者 ID 和读者计数
5. **读写锁降级**：`wr2rdlock()` 是 OceanBase 独有的优雅设计
6. **公平性可配置**：FIFO 和 READ_PREFER 两种策略支持不同业务场景
7. **与 Linux 内核深度协作**：通过 Futex 系统调用实现用户态快速路径 + 内核态慢速路径

这一套锁体系为 OceanBase 的上层组件——事务引擎、存储引擎、日志系统——奠定了坚实的并发基础。
