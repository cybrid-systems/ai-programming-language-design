# 09-spinlock — Linux 内核自旋锁深度源码分析

> 基于 Linux 7.0.8 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**自旋锁（spinlock）** 是 Linux 内核最基础的同步原语。当锁被持有时，尝试获取的 CPU 忙等待（spin）而非休眠。锁持有者必须在极短时间内释放锁，且临界区内不可休眠。

x86-64 上当前实现为 **queued spinlock（qspinlock）**，由 Waiman Long 于 2015 年引入。三层路径架构：

1. **快速路径（fast path）**：一条 `lock cmpxchg` 指令，零竞争时直接获取
2. **Pending bit 优化（single-waiter）**：一个等待者在 locked 字节上自旋
3. **MCS 队列（multi-waiter）**：多个等待者通过 per-CPU 排队，避免 thundering herd

**doom-lsp 确认**：`include/asm-generic/qspinlock.h` 含 **8 个符号**，`kernel/locking/qspinlock.c` 含 **10 个符号**，`include/asm-generic/qspinlock_types.h` 含 **32-bit 锁字编码**。

---

## 1. 核心数据结构

### 1.1 struct spinlock / raw_spinlock — 两层封装

非 PREEMPT_RT 内核中，`spinlock_t` 只是 `raw_spinlock_t` 的封装，两者等价：

```c
// include/linux/spinlock_types.h:17-30
// Non PREEMPT_RT kernels map spinlock to raw_spinlock */
context_lock_struct(spinlock) {
	union {
		struct raw_spinlock rlock;

#ifdef CONFIG_DEBUG_LOCK_ALLOC
# define LOCK_PADSIZE (offsetof(struct raw_spinlock, dep_map))
		struct {
			u8 __padding[LOCK_PADSIZE];
			struct lockdep_map dep_map;
		};
#endif
	};
};
typedef struct spinlock spinlock_t;
```

```c
// include/linux/spinlock_types_raw.h:41-56
context_lock_struct(raw_spinlock) {
	arch_spinlock_t raw_lock;
#ifdef CONFIG_DEBUG_SPINLOCK
	unsigned int magic, owner_cpu;
	void *owner;
#endif
#ifdef CONFIG_DEBUG_LOCK_ALLOC
	struct lockdep_map dep_map;
#endif
};
typedef struct raw_spinlock raw_spinlock_t;
```

**两层映射关系**：

```
spin_lock(&lock)
  → raw_spin_lock(&lock->rlock)       // spinlock_types.h:339-342
    → _raw_spin_lock(lock)            // spinlock.h:218
      → __raw_spin_lock(lock)         // spinlock_api_smp.h:154-162
        → LOCK_CONTENDED(lock, try, lock)
          → do_raw_spin_lock(lock)    // spinlock.h:184-189
            → arch_spin_lock(&lock->raw_lock)  // qspinlock 或 ticket
```

### 1.2 arch_spinlock_t — qspinlock（32-bit 编码）

```c
// include/asm-generic/qspinlock_types.h:14-44
typedef struct qspinlock {
	union {
		atomic_t val;

		/*
		 * By using the whole 2nd least significant byte for the
		 * pending bit, we can allow better optimization of the lock
		 * acquisition for the pending bit holder.
		 */
#ifdef __LITTLE_ENDIAN
		struct {
			u8	locked;
			u8	pending;
		};
		struct {
			u16	locked_pending;
			u16	tail;
		};
#else
		struct {
			u16	tail;
			u16	locked_pending;
		};
		struct {
			u8	reserved[2];
			u8	pending;
			u8	locked;
		};
#endif
	};
} arch_spinlock_t;
```

**32-bit 锁字位域**（Little-Endian 布局）：

```
Bit:  31--18  17--16  15--9   8      7--0
      ┌───────┬───────┬───────┬───────┬───────┐
      │tail   │tail   │unused │pending│locked │
      │cpu+1  │idx    │       │(1 bit)│(8 bit)│
      │14 bits│2 bits │7 bits │       │       │
      └───────┴───────┴───────┴───────┴───────┘
```

NR_CPUS >= 16K 时 pending 位仅 1 bit，tail cpu 扩展为 21 bits：

```c
// include/asm-generic/qspinlock_types.h:52-93
/*
 * When NR_CPUS < 16K
 *  0- 7: locked byte
 *     8: pending
 *  9-15: not used
 * 16-17: tail index
 * 18-31: tail cpu (+1)
 */
#define	_Q_SET_MASK(type)	(((1U << _Q_ ## type ## _BITS) - 1)\
				      << _Q_ ## type ## _OFFSET)
#define _Q_LOCKED_OFFSET	0
#define _Q_LOCKED_BITS		8
#define _Q_LOCKED_MASK		_Q_SET_MASK(LOCKED)

#define _Q_PENDING_OFFSET	(_Q_LOCKED_OFFSET + _Q_LOCKED_BITS)
#define _Q_PENDING_BITS		1
#define _Q_PENDING_MASK		_Q_SET_MASK(PENDING)

#define _Q_TAIL_IDX_OFFSET	(_Q_PENDING_OFFSET + _Q_PENDING_BITS)
#define _Q_TAIL_IDX_BITS	2
#define _Q_TAIL_IDX_MASK	_Q_SET_MASK(TAIL_IDX)

#define _Q_TAIL_CPU_OFFSET	(_Q_TAIL_IDX_OFFSET + _Q_TAIL_IDX_BITS)
#define _Q_TAIL_CPU_BITS	(32 - _Q_TAIL_CPU_OFFSET)
#define _Q_TAIL_CPU_MASK	_Q_SET_MASK(TAIL_CPU)

#define _Q_TAIL_OFFSET		_Q_TAIL_IDX_OFFSET
#define _Q_TAIL_MASK		(_Q_TAIL_IDX_MASK | _Q_TAIL_CPU_MASK)

#define _Q_LOCKED_VAL		(1U << _Q_LOCKED_OFFSET)
#define _Q_PENDING_VAL		(1U << _Q_PENDING_OFFSET)
```

`_Q_LOCKED_VAL = 0x01`，`_Q_PENDING_VAL = 0x100`。

### 1.3 struct mcs_spinlock — MCS 队列节点

```c
// kernel/locking/mcs_spinlock.h:56-87
static inline
void mcs_spin_lock(struct mcs_spinlock **lock, struct mcs_spinlock *node)
{
	struct mcs_spinlock *prev;

	/* Init node */
	node->locked = 0;
	node->next   = NULL;

	prev = xchg(lock, node);
	if (likely(prev == NULL)) {
		/* Lock acquired, don't need to set node->locked to 1. */
		return;
	}
	WRITE_ONCE(prev->next, node);

	/* Wait until the lock holder passes the lock down. */
	arch_mcs_spin_lock_contended(&node->locked);
}
```

per-CPU 队列节点池：

```c
// kernel/locking/qspinlock.h:34-46
struct qnode {
	struct mcs_spinlock mcs;
#ifdef CONFIG_PARAVIRT_SPINLOCKS
	long reserved[2];
#endif
};
```

每个 CPU 分配 4 个 MCS 节点（`qnodes[0..3]`），应对最多 3 层 NMI 嵌套：

```c
// kernel/locking/qspinlock.c:236-244
	if (unlikely(idx >= _Q_MAX_NODES)) {
		lockevent_inc(lock_no_node);
		while (!queued_spin_trylock(lock))
			cpu_relax();
		goto release;
	}
```

其中 `_Q_MAX_NODES = 4`。

---

## 2. 完整的 spin_lock 调用链

### 2.1 spin_lock() 宏展开

```c
// include/linux/spinlock.h:339-342
static __always_inline void spin_lock(spinlock_t *lock)
	__acquires(lock) __no_context_analysis
{
	raw_spin_lock(&lock->rlock);
}
```

```c
// include/linux/spinlock.h:218
#define raw_spin_lock(lock)	_raw_spin_lock(lock)
```

`_raw_spin_lock` 最终展开为 `__raw_spin_lock`（inline 版本，未启用 `CONFIG_GENERIC_LOCKBREAK`）：

```c
// include/linux/spinlock_api_smp.h:154-162
static inline void __raw_spin_lock(raw_spinlock_t *lock)
	__acquires(lock) __no_context_analysis
{
	preempt_disable();
	spin_acquire(&lock->dep_map, 0, 0, _RET_IP_);
	LOCK_CONTENDED(lock, do_raw_spin_trylock, do_raw_spin_lock);
}
```

**LOCK_CONTENDED** 宏（有 lock_stat 时记录竞争统计）：

```c
// include/linux/lockdep.h:441-451
#ifdef CONFIG_LOCK_STAT
#define LOCK_CONTENDED(_lock, try, lock)			\
do {								\
	if (!try(_lock)) {					\
		lock_contended(&(_lock)->dep_map, _RET_IP_);	\
		lock(_lock);					\
	}							\
	lock_acquired(&(_lock)->dep_map, _RET_IP_);		\
} while (0)
#else
#define LOCK_CONTENDED(_lock, try, lock) \
	lock(_lock)
#endif
```

### 2.2 do_raw_spin_lock — 真正调用 arch_spin_lock

```c
// include/linux/spinlock.h:184-189
static inline void do_raw_spin_lock(raw_spinlock_t *lock) __acquires(lock)
{
	__acquire(lock);
	arch_spin_lock(&lock->raw_lock);
	mmiowb_spin_lock();
}
```

**arch_spin_lock → queued_spin_lock** 映射：

```c
// include/asm-generic/qspinlock.h:144-149
#define arch_spin_is_locked(l)		queued_spin_is_locked(l)
#define arch_spin_is_contended(l)	queued_spin_is_contended(l)
#define arch_spin_value_unlocked(l)	queued_spin_value_unlocked(l)
#define arch_spin_lock(l)		queued_spin_lock(l)
#define arch_spin_trylock(l)		queued_spin_trylock(l)
#define arch_spin_unlock(l)		queued_spin_unlock(l)
```

### 2.3 queued_spin_lock — 快速路径

```c
// include/asm-generic/qspinlock.h:107-115
static __always_inline void queued_spin_lock(struct qspinlock *lock)
{
	int val = 0;

	if (likely(atomic_try_cmpxchg_acquire(&lock->val, &val, _Q_LOCKED_VAL)))
		return;

	queued_spin_lock_slowpath(lock, val);
}
```

**x86-64 汇编（fast path）**：

```asm
; queued_spin_lock 快速路径 — 一条 lock cmpxchg
xor    %eax, %eax        ; val = 0
mov    $1, %edx          ; new = _Q_LOCKED_VAL (0x01)
lock cmpxchg %edx, (%rdi); if (*lock == 0): *lock = 1
jnz    slowpath          ; 竞争 → 慢速路径
ret                      ; ✅ 获取锁！（~10ns 零竞争时）
```

---

## 3. queued_spin_lock_slowpath — 慢速路径

完整的注释状态机：

```c
// kernel/locking/qspinlock.c:130-131
// 状态转移图（来自源码注释）:

/*
 *              fast     :    slow                                  :    unlock
 *                       :                                          :
 * uncontended  (0,0,0) -:--> (0,0,1) ------------------------------:--> (*,*,0)
 *                       :       | ^--------.------.             /  :
 *                       :       v           \      \            |  :
 * pending               :    (0,1,1) +--> (0,1,0)   \           |  :
 *                       :       | ^--'              |           |  :
 *                       :       v                   |           |  :
 * uncontended           :    (n,x,y) +--> (n,0,0) --'           |  :
 *   queue               :       | ^--'                          |  :
 *                       :       v                               |  :
 * contended             :    (*,x,y) +--> (*,0,0) ---> (*,0,1) -'  :
 *   queue               :         ^--'                             :
 */
```

### 3.1 Pending bit 快速抢占

条目：

```c
// kernel/locking/qspinlock.c:140-205
void __lockfunc queued_spin_lock_slowpath(struct qspinlock *lock, u32 val)
{
	struct mcs_spinlock *prev, *next, *node;
	u32 old, tail;
	int idx;

	BUILD_BUG_ON(CONFIG_NR_CPUS >= (1U << _Q_TAIL_CPU_BITS));

	if (pv_enabled())
		goto pv_queue;

	if (virt_spin_lock(lock))
		return;

	/*
	 * Wait for in-progress pending->locked hand-overs with a bounded
	 * number of spins so that we guarantee forward progress.
	 *
	 * 0,1,0 -> 0,0,1
	 */
	if (val == _Q_PENDING_VAL) {
		int cnt = _Q_PENDING_LOOPS;
		val = atomic_cond_read_relaxed(&lock->val,
					       (VAL != _Q_PENDING_VAL) || !cnt--);
	}

	/*
	 * If we observe any contention; queue.
	 */
	if (val & ~_Q_LOCKED_MASK)
		goto queue;

	/*
	 * trylock || pending
	 *
	 * 0,0,* -> 0,1,* -> 0,0,1 pending, trylock
	 */
	val = queued_fetch_set_pending_acquire(lock);

	/*
	 * If we observe contention, there is a concurrent locker.
	 *
	 * Undo and queue.
	 */
	if (unlikely(val & ~_Q_LOCKED_MASK)) {

		/* Undo PENDING if we set it. */
		if (!(val & _Q_PENDING_MASK))
			clear_pending(lock);

		goto queue;
	}

	/*
	 * We're pending, wait for the owner to go away.
	 *
	 * 0,1,1 -> *,1,0
	 */
	if (val & _Q_LOCKED_MASK)
		smp_cond_load_acquire(&lock->locked, !VAL);

	/*
	 * take ownership and clear the pending bit.
	 *
	 * 0,1,0 -> 0,0,1
	 */
	clear_pending_set_locked(lock);
	lockevent_inc(lock_pending);
	return;
```

x86 专用的 `queued_fetch_set_pending_acquire` 使用 `btsl` 单条指令：

```c
// arch/x86/include/asm/qspinlock.h:16-30
#define _Q_PENDING_LOOPS	(1 << 9)

#define queued_fetch_set_pending_acquire queued_fetch_set_pending_acquire
static __always_inline u32 queued_fetch_set_pending_acquire(struct qspinlock *lock)
{
	u32 val;

	val = GEN_BINARY_RMWcc(LOCK_PREFIX "btsl", lock->val.counter, c,
			       "I", _Q_PENDING_OFFSET) * _Q_PENDING_VAL;
	val |= atomic_read(&lock->val) & ~_Q_PENDING_MASK;

	return val;
}
```

`_Q_PENDING_LOOPS = 512`（x86），远大于通用实现的 1。

### 3.2 MCS 队列入队

```c
// kernel/locking/qspinlock.c:207-290
queue:
	lockevent_inc(lock_slowpath);
pv_queue:
	node = this_cpu_ptr(&qnodes[0].mcs);
	idx = node->count++;
	tail = encode_tail(smp_processor_id(), idx);

	trace_contention_begin(lock, LCB_F_SPIN);

	if (unlikely(idx >= _Q_MAX_NODES)) {
		lockevent_inc(lock_no_node);
		while (!queued_spin_trylock(lock))
			cpu_relax();
		goto release;
	}

	node = grab_mcs_node(node, idx);

	lockevent_cond_inc(lock_use_node2 + idx - 1, idx);

	barrier();

	node->locked = 0;
	node->next = NULL;
	pv_init_node(node);

	/* trylock once more after touching cacheline */
	if (queued_spin_trylock(lock))
		goto release;

	smp_wmb();

	/*
	 * Publish the updated tail.
	 * p,*,* -> n,*,*
	 */
	old = xchg_tail(lock, tail);
	next = NULL;

	/*
	 * if there was a previous node; link it and wait.
	 */
	if (old & _Q_TAIL_MASK) {
		prev = decode_tail(old, qnodes);

		/* Link @node into the waitqueue. */
		WRITE_ONCE(prev->next, node);

		pv_wait_node(node, prev);
		arch_mcs_spin_lock_contended(&node->locked);

		next = READ_ONCE(node->next);
		if (next)
			prefetchw(next);
	}
```

### 3.3 成为队首后自旋 + lock handoff

```c
// kernel/locking/qspinlock.c:292-340
	/*
	 * we're at the head of the waitqueue, wait for the owner & pending
	 * to go away.
	 *
	 * *,x,y -> *,0,0
	 */
	if ((val = pv_wait_head_or_lock(lock, node)))
		goto locked;

	val = atomic_cond_read_acquire(&lock->val,
				       !(VAL & _Q_LOCKED_PENDING_MASK));

locked:
	/*
	 * claim the lock:
	 *
	 * n,0,0 -> 0,0,1 : lock, uncontended
	 * *,*,0 -> *,*,1 : lock, contended
	 */
	if ((val & _Q_TAIL_MASK) == tail) {
		if (atomic_try_cmpxchg_relaxed(&lock->val, &val,
					       _Q_LOCKED_VAL))
			goto release; /* No contention */
	}

	/*
	 * Either somebody is queued behind us or _Q_PENDING_VAL got set.
	 */
	set_locked(lock);

	/*
	 * contended path; wait for next if not observed yet, release.
	 */
	if (!next)
		next = smp_cond_load_relaxed(&node->next, (VAL));

	arch_mcs_spin_unlock_contended(&next->locked);
	pv_kick_node(lock, next);

release:
	trace_contention_end(lock, 0);
	__this_cpu_dec(qnodes[0].mcs.count);
}
EXPORT_SYMBOL(queued_spin_lock_slowpath);
```

### 3.4 encode_tail / decode_tail / xchg_tail

```c
// kernel/locking/qspinlock.h:52-76
static inline __pure u32 encode_tail(int cpu, int idx)
{
	u32 tail;

	tail  = (cpu + 1) << _Q_TAIL_CPU_OFFSET;
	tail |= idx << _Q_TAIL_IDX_OFFSET; /* assume < 4 */

	return tail;
}

static inline __pure struct mcs_spinlock *decode_tail(u32 tail,
						      struct qnode __percpu *qnodes)
{
	int cpu = (tail >> _Q_TAIL_CPU_OFFSET) - 1;
	int idx = (tail &  _Q_TAIL_IDX_MASK) >> _Q_TAIL_IDX_OFFSET;

	return per_cpu_ptr(&qnodes[idx].mcs, cpu);
}
```

xchg_tail（8-bit pending 版本 —— 用 `xchg` 指令只交换 tail 部分）：

```c
// kernel/locking/qspinlock.h:105-122
static __always_inline u32 xchg_tail(struct qspinlock *lock, u32 tail)
{
	return (u32)xchg_relaxed(&lock->tail,
				 tail >> _Q_TAIL_OFFSET) << _Q_TAIL_OFFSET;
}
```

### 3.5 clear_pending_set_locked / set_locked

```c
// kernel/locking/qspinlock.h:86-100
static __always_inline void clear_pending(struct qspinlock *lock)
{
	WRITE_ONCE(lock->pending, 0);
}

static __always_inline void clear_pending_set_locked(struct qspinlock *lock)
{
	WRITE_ONCE(lock->locked_pending, _Q_LOCKED_VAL);
}
```

```c
// kernel/locking/qspinlock.h:217-221
static __always_inline void set_locked(struct qspinlock *lock)
{
	WRITE_ONCE(lock->locked, _Q_LOCKED_VAL);
}
```

注意：`clear_pending_set_locked` 一次性写入 `locked_pending`（16 位），原子地清除 pending 并设置 locked，避免中间状态被其他 CPU 观测到。

---

## 4. MCS 队列完整图解

```
初始：lock = 0x00000001（locked=1，CPU A 持有）

CPU B 加入：
  tail = encode_tail(CPU1, node[0])       // 例如 0x00040000
  xchg_tail(lock, tail) → lock = 0x00040101
  prev = decode_tail(old) = CPU A 的节点
  WRITE_ONCE(prev->next, node_B)
  → 队列: [CPU A] ← [CPU B]
  → CPU B 自旋: arch_mcs_spin_lock_contended(&node_B->locked)

CPU C 加入：
  tail = encode_tail(CPU2, node[0])       // 例如 0x00080000
  xchg_tail(lock, tail) → lock = 0x00080101
  prev = decode_tail(old) = node_B (CPU1)
  WRITE_ONCE(prev->next, node_C)
  → 队列: [CPU A] ← [CPU B] ← [CPU C]
  → CPU B 自旋等 locked=0
  → CPU C 自旋等 node_C->locked=1

CPU A 释放锁：
  smp_store_release(&lock->locked, 0)    // lock = 0x00040100
  CPU B 检测到 locked=0 → 获取锁
  → set_locked(lock) → 0x00080001
  → arch_mcs_spin_unlock_contended(&node_C->locked)
  CPU C 检测到 node_C->locked=1 → 获取锁
```

与 ticket spinlock 的关键区别：**每个 CPU 只在本地 cacheline 上自旋**，不会引发全局缓存行 bouncing。

---

## 5. spin_unlock 路径

```c
// include/asm-generic/qspinlock.h:123-129
static __always_inline void queued_spin_unlock(struct qspinlock *lock)
{
	/*
	 * unlock() needs release semantics:
	 */
	smp_store_release(&lock->locked, 0);
}
```

```c
// include/linux/spinlock_api_smp.h:164-168
static inline void __raw_spin_unlock(raw_spinlock_t *lock)
	__releases(lock)
{
	spin_release(&lock->dep_map, _RET_IP_);
	do_raw_spin_unlock(lock);
	preempt_enable();
}
```

```c
// include/linux/spinlock.h:202-207
static inline void do_raw_spin_unlock(raw_spinlock_t *lock) __releases(lock)
{
	mmiowb_spin_unlock();
	arch_spin_unlock(&lock->raw_lock);
	__release(lock);
}
```

**unlock 汇编（x86-64）**：

```asm
; queued_spin_unlock 快速路径
mov    $0, (%rdi)         ; smp_store_release(&lock->locked, 0)
                          ; x86 上 store-release 就是普通 store（x86 强序）
ret                        ; ~2ns
```

无等待者时只是一个普通 store；有 MCS 队列时，被唤醒的下一个 CPU 由 `arch_mcs_spin_unlock_contended` 在 slowpath 的 lock handoff 中执行。

---

## 6. queued_spin_trylock — 非阻塞尝试

```c
// include/asm-generic/qspinlock.h:90-98
static __always_inline int queued_spin_trylock(struct qspinlock *lock)
{
	int val = atomic_read(&lock->val);

	if (unlikely(val))
		return 0;

	return likely(atomic_try_cmpxchg_acquire(&lock->val, &val,
						 _Q_LOCKED_VAL));
}
```

只有当整个 32-bit 锁字为零（空闲）时才能成功。

---

## 7. PV qspinlock — para-virtualized 优化

### 7.1 PV 架构

PV qspinlock 的核心思想：vCPU 不需要忙等待，可以通过 hypercall 让出 CPU。

```c
// kernel/locking/qspinlock_paravirt.h:9-22
/*
 * Implement paravirt qspinlocks; the general idea is to halt the vcpus
 * instead of spinning them.
 *
 * This relies on the architecture to provide two paravirt hypercalls:
 *
 *   pv_wait(u8 *ptr, u8 val) -- suspends the vcpu if *ptr == val
 *   pv_kick(cpu)             -- wakes a suspended vcpu
 */
```

### 7.2 PV 节点结构

```c
// kernel/locking/qspinlock_paravirt.h:86-91
enum vcpu_state {
	VCPU_RUNNING = 0,
	VCPU_HALTED,		/* Used only in pv_wait_node */
	VCPU_HASHED,		/* = pv_hash'ed + VCPU_HALTED */
};

struct pv_node {
	struct mcs_spinlock	mcs;
	int			cpu;
	u8			state;
};
```

### 7.3 Hybrid PV 不公平锁

```c
// kernel/locking/qspinlock_paravirt.h:119-148
#define queued_spin_trylock(l)	pv_hybrid_queued_unfair_trylock(l)
static inline bool pv_hybrid_queued_unfair_trylock(struct qspinlock *lock)
{
	/*
	 * Stay in unfair lock mode as long as queued mode waiters are
	 * present in the MCS wait queue but the pending bit isn't set.
	 */
	for (;;) {
		int val = atomic_read(&lock->val);
		u8 old = 0;

		if (!(val & _Q_LOCKED_PENDING_MASK) &&
		    try_cmpxchg_acquire(&lock->locked, &old, _Q_LOCKED_VAL)) {
			lockevent_inc(pv_lock_stealing);
			return true;
		}
		if (!(val & _Q_TAIL_MASK) || (val & _Q_PENDING_MASK))
			break;

		cpu_relax();
	}

	return false;
}
```

### 7.4 pv_wait_node — vCPU 让出

```c
// kernel/locking/qspinlock_paravirt.h:244-280
static void pv_wait_node(struct mcs_spinlock *node, struct mcs_spinlock *prev)
{
	struct pv_node *pn = (struct pv_node *)node;
	struct pv_node *pp = (struct pv_node *)prev;
	bool wait_early;
	int loop;

	for (;;) {
		for (wait_early = false, loop = SPIN_THRESHOLD; loop; loop--) {
			if (READ_ONCE(node->locked))
				return;
			if (pv_wait_early(pp, loop)) {
				wait_early = true;
				break;
			}
			cpu_relax();
		}

		smp_store_mb(pn->state, VCPU_HALTED);

		if (!READ_ONCE(node->locked)) {
			lockevent_inc(pv_wait_node);
			/*
			 * pv_kick_node() will set _Q_SLOW_VAL and fill
			 * in hash table on its behalf.
			 */
		}
	}
}
```

### 7.5 pv_kick_node — 唤醒后继 vCPU

```c
// kernel/locking/qspinlock_paravirt.h:317-349
static void pv_kick_node(struct qspinlock *lock, struct mcs_spinlock *node)
{
	struct pv_node *pn = (struct pv_node *)node;
	u8 old = VCPU_HALTED;

	smp_mb__before_atomic();
	if (!try_cmpxchg_relaxed(&pn->state, &old, VCPU_HASHED))
		return;

	/*
	 * Put the lock into the hash table and set the _Q_SLOW_VAL.
	 */
	WRITE_ONCE(lock->locked, _Q_SLOW_VAL);
	(void)pv_hash(lock, pn);
}
```

### 7.6 pv_wait_head_or_lock — 队首 vCPU 自旋优化

```c
// kernel/locking/qspinlock_paravirt.h:357-410
static u32
pv_wait_head_or_lock(struct qspinlock *lock, struct mcs_spinlock *node)
{
	struct pv_node *pn = (struct pv_node *)node;
	struct qspinlock **lp = NULL;
	int waitcnt = 0;
	int loop;

	if (READ_ONCE(pn->state) == VCPU_HASHED)
		lp = (struct qspinlock **)1;

	lockevent_inc(lock_slowpath);

	for (;; waitcnt++) {
		WRITE_ONCE(pn->state, VCPU_RUNNING);

		/*
		 * Set the pending bit to disable lock stealing.
		 */
		set_pending(lock);
		for (loop = SPIN_THRESHOLD; loop; loop--) {
			if (trylock_clear_pending(lock))
				goto gotlock;
			cpu_relax();
		}
		clear_pending(lock);

		if (!lp) { /* ONCE */
			lp = pv_hash(lock, pn);
		}
	}
gotlock:
	/* gotlock path ... */
}
```

### 7.7 __pv_queued_spin_unlock

```c
// kernel/locking/qspinlock_paravirt.h:416-427
__visible __lockfunc void __pv_queued_spin_unlock(struct qspinlock *lock)
{
	u8 locked = _Q_LOCKED_VAL;

	/*
	 * We must not unlock if SLOW, because in that case we must first
	 * unhash. Otherwise it would be possible to have multiple @lock
	 * entries.
	 */
	if (try_cmpxchg_release(&lock->locked, &locked, 0))
		return;

	__pv_queued_spin_unlock_slowpath(lock, locked);
}
```

当 `lock->locked == _Q_SLOW_VAL`（值为 0x03）时，表示有 vCPU 在等待唤醒，需要走慢速路径查哈希表唤醒特定 CPU。

---

## 8. Ticket spinlock（x86 传统实现，对比参考）

Linux 的通用 ticket spinlock 实现（用于不支持 qspinlock 的架构，或作为对比）：

```c
// include/asm-generic/ticket_spinlock.h:39-73
static __always_inline void ticket_spin_lock(arch_spinlock_t *lock)
{
	u32 val = atomic_fetch_add(1<<16, &lock->val);
	u16 ticket = val >> 16;

	if (ticket == (u16)val)
		return;

	atomic_cond_read_acquire(&lock->val, ticket == (u16)VAL);
	smp_mb();
}

static __always_inline bool ticket_spin_trylock(arch_spinlock_t *lock)
{
	u32 old = atomic_read(&lock->val);

	if ((old >> 16) != (old & 0xffff))
		return false;

	return atomic_try_cmpxchg(&lock->val, &old, old + (1<<16));
}

static __always_inline void ticket_spin_unlock(arch_spinlock_t *lock)
{
	u16 *ptr = (u16 *)lock + IS_ENABLED(CONFIG_CPU_BIG_ENDIAN);
	u32 val = atomic_read(&lock->val);

	smp_store_release(ptr, (u16)val + 1);
}
```

**Ticket spinlock 原理**：

```
初始: head=ticket=0
CPU A: atomic_fetch_add(1<<16) → head=ticket=0 → 立即获取锁
CPU B: atomic_fetch_add(1<<16) → ticket=1 → 自旋等 head==1
CPU C: atomic_fetch_add(1<<16) → ticket=2 → 自旋等 head==2

释放时: head++ → 下一个 ticket 持有者获取锁
```

**qspinlock vs ticket spinlock** 对比：

| 特性 | Ticket spinlock | qspinlock |
|------|----------------|-----------|
| 公平性 | FIFO 严格公平 | MCS 队列公平 |
| 自旋位置 | 全局 `lock->val` | per-CPU `node->locked` |
| cacheline bouncing | 高（所有等待者踩同一变量） | 低（每个 CPU 本地自旋） |
| 单等待者优化 | 无 | pending bit（~20ns vs ~100ns） |
| 空间占用 | 4 字节 | 4 字节（与 ticket 兼容） |
| PV 支持 | 无 | 完整的 _Q_SLOW_VAL 机制 |
| NUMA 感知 | 无 | CNA（Compact NUMA-aware）扩展 |

---

## 9. irq 变体

### 9.1 raw local_irq_save / restore

```c
// include/linux/irqflags.h:168-225
#define raw_local_irq_disable()		arch_local_irq_disable()
#define raw_local_irq_enable()		arch_local_irq_enable()
#define raw_local_irq_save(flags)			\
	do {						\
		typecheck(unsigned long, flags);	\
		flags = arch_local_irq_save();		\
	} while (0)
#define raw_local_irq_restore(flags)			\
	do {						\
		typecheck(unsigned long, flags);	\
		arch_local_irq_restore(flags);		\
	} while (0)

#define local_irq_save(flags)				\
	do {						\
		raw_local_irq_save(flags);		\
		trace_hardirqs_off();			\
	} while (0)

#define local_irq_restore(flags)			\
	do {						\
		if (raw_irqs_disabled_flags(flags)) {	\
			trace_hardirqs_off();		\
		} else {				\
			trace_hardirqs_on();		\
		}					\
		raw_local_irq_restore(flags);		\
	} while (0)
```

`trace_hardirqs_off/on()` 是 lockdep IRQ 跟踪的回调。

### 9.2 spin_lock_irqsave 完整展开

```c
// include/linux/spinlock.h:242-245
#define raw_spin_lock_irqsave(lock, flags)			\
	do {							\
		typecheck(unsigned long, flags);		\
		flags = _raw_spin_lock_irqsave(lock);		\
	} while (0)
```

`_raw_spin_lock_irqsave` 的 inline 实现：

```c
// include/linux/spinlock_api_smp.h:125-135
static inline unsigned long __raw_spin_lock_irqsave(raw_spinlock_t *lock)
	__acquires(lock) __no_context_analysis
{
	unsigned long flags;

	local_irq_save(flags);
	preempt_disable();
	spin_acquire(&lock->dep_map, 0, 0, _RET_IP_);
	LOCK_CONTENDED(lock, do_raw_spin_trylock, do_raw_spin_lock);
	return flags;
}
```

### 9.3 spin_unlock_irqrestore

```c
// include/linux/spinlock.h:278-283
#define raw_spin_unlock_irq(lock)	_raw_spin_unlock_irq(lock)

#define raw_spin_unlock_irqrestore(lock, flags)		\
	do {							\
		typecheck(unsigned long, flags);		\
		_raw_spin_unlock_irqrestore(lock, flags);	\
	} while (0)
```

```c
// include/linux/spinlock_api_smp.h:172-180
static inline void __raw_spin_unlock_irqrestore(raw_spinlock_t *lock,
						unsigned long flags)
	__releases(lock)
{
	spin_release(&lock->dep_map, _RET_IP_);
	do_raw_spin_unlock(lock);
	local_irq_restore(flags);
	preempt_enable();
}
```

`spin_lock_irqsave/spin_unlock_irqrestore` 是**中断上下文**中使用自旋锁的标准模式：先保存当前中断状态、关中断、获取锁；释放锁后恢复原始中断状态。

### 9.4 spin_lock_irq / spin_lock_bh

```c
// include/linux/spinlock_api_smp.h:137-151
static inline void __raw_spin_lock_irq(raw_spinlock_t *lock)
	__acquires(lock) __no_context_analysis
{
	local_irq_disable();
	preempt_disable();
	spin_acquire(&lock->dep_map, 0, 0, _RET_IP_);
	LOCK_CONTENDED(lock, do_raw_spin_trylock, do_raw_spin_lock);
}

static inline void __raw_spin_lock_bh(raw_spinlock_t *lock)
	__acquires(lock) __no_context_analysis
{
	__local_bh_disable_ip(_RET_IP_, SOFTIRQ_LOCK_OFFSET);
	spin_acquire(&lock->dep_map, 0, 0, _RET_IP_);
	LOCK_CONTENDED(lock, do_raw_spin_trylock, do_raw_spin_lock);
}
```

- `spin_lock_irq`：强制关中断（必须事先知道当前硬中断已开启）
- `spin_lock_bh`：仅关 softirq（下半部），不影响硬中断

---

## 10. Lockdep 集成

### 10.1 spin_acquire / spin_release

```c
// include/linux/lockdep.h:509-515
#define lock_acquire_exclusive(l, s, t, n, i)	\
	lock_acquire(l, s, t, 0, 1, n, i)
#define lock_acquire_shared(l, s, t, n, i)	\
	lock_acquire(l, s, t, 1, 1, n, i)

#define spin_acquire(l, s, t, i)		\
	lock_acquire_exclusive(l, s, t, NULL, i)
#define spin_release(l, i)			lock_release(l, i)
```

### 10.2 无 lockdep 时 NOP

```c
// include/linux/lockdep.h:336-337
# define lock_acquire(l, s, t, r, c, n, i)	do { } while (0)
# define lock_release(l, i)			do { } while (0)
```

### 10.3 完整调用栈中的 lockdep 路径

```
spin_lock(lock)
  → raw_spin_lock(&lock->rlock)
    → __raw_spin_lock(lock)          // spinlock_api_smp.h:154
      → preempt_disable()            // 关抢占
      → spin_acquire(&dep_map, ...)  // ★ lockdep: 记录依赖
        → lock_acquire_exclusive()
          → lock_acquire()           // 检查死锁
      → LOCK_CONTENDED(lock, ...)    // 真正获取锁
        → do_raw_spin_lock()
          → arch_spin_lock()
```

```
spin_unlock(lock)
  → raw_spin_unlock(&lock->rlock)
    → __raw_spin_unlock(lock)        // spinlock_api_smp.h:164
      → spin_release(&dep_map, ...)  // ★ lockdep: 释放记录
        → lock_release()
      → do_raw_spin_unlock()
        → arch_spin_unlock()
      → preempt_enable()             // 开抢占
```

Lockdep 在 `lock_acquire()` 中检查当前进程已持有的锁与要获取的锁之间是否存在循环依赖，若发现死锁风险则触发 `BUG` 并打印锁依赖图。

---

## 11. 性能特征

### 11.1 各路径延迟（x86-64, ~3GHz）

| 路径 | 延迟（典型值） | 说明 |
|------|---------------|------|
| Fast path (cmpxchg) | ~10ns | 一条缓存命中 `lock cmpxchg` |
| Pending bit 自旋 | ~20-100ns | 单等待者，在 locked 字节自旋 |
| MCS 排队（队首） | ~100-300ns | 先入队再等 locked 释放 |
| MCS 排队（非队首） | ~200-500ns | 等前驱的 node->locked 通知 |
| PV wait/kick | ~1-10μs | hypercall 让出/唤醒 vCPU |
| Unlock（无等待者） | ~2ns | smp_store_release，单条 mov |

### 11.2 qspinlock vs ticket 关键区别

**Ticket spinlock 的 thundering herd 问题**：

```
所有 CPU 自旋在同一个 lock->val 上：
  CPU B: while (head != ticket) 读取 lock->val
  CPU C: while (head != ticket) 读取 lock->val
  CPU D: while (head != ticket) 读取 lock->val

释放时：head++ → 所有等待者的缓存行失效 → cacheline bouncing
```

**qspinlock 的 MCS 队列避免 thundering herd**：

```
每个 CPU 在本地 node->locked 上自旋：
  CPU B: while (!node_B->locked)   ← 私有 cacheline，无 bouncing
  CPU C: while (!node_C->locked)   ← 私有 cacheline，无 bouncing
  CPU D: while (!node_D->locked)   ← 私有 cacheline，无 bouncing

释放时：只通知 CPU B → CPU B 知 CPU C → 链式传递
只产生一条 cacheline 的失效 → O(1) coherence traffic
```

### 11.3 缓存（cache）行为

| 操作 | 缓存行命中 | 说明 |
|------|-----------|------|
| Fast path cmpxchg | 大概率 L1 命中 | lock 在 hot cacheline |
| Pending bit 自旋 | L1 命中 | 读自己的 locked 字节 |
| MCS 入队（xchg_tail）| lock->val 可能 L1 miss | 写入全局 tail 字段 |
| MCS 等待前驱 | 本地 node->locked L1 命中 | 私有 per-CPU 数据，无 bouncing |
| MCS lock handoff | 修改后继的 node->locked | 单次 cacheline miss |

### 11.4 NR_CPUS 对 qspinlock 的影响

```
      4K CPUs        16K CPUs       32K CPUs       64K CPUs
      pending=8b     pending=8b     pending=1b     pending=1b
      tail_idx=2b    tail_idx=2b    tail_idx=2b    tail_idx=2b
      tail_cpu=14b   tail_cpu=14b   tail_cpu=21b   tail_cpu=21b
      max CPUs=16K   max CPUs=16K   max CPUs=2M    max CPUs=2M
```

---

## 12. 调试和统计

```bash
# 确认当前系统使用的 spinlock 类型
dmesg | grep -i spinlock

# Lock event 统计（需要 CONFIG_LOCK_EVENT_COUNTS）
perf stat -e spin_lock:spin_lock_acquire -a -- sleep 1
perf stat -e spin_lock:spin_lock_contended -a -- sleep 1

# lock_stat 跟踪
echo 0 > /proc/sys/kernel/lock_stat
# ... 运行负载 ...
echo 1 > /proc/sys/kernel/lock_stat
cat /proc/lock_stat

# 使用 bpftrace 跟踪 qspinlock 慢速路径
bpftrace -e 'kprobe:native_queued_spin_lock_slowpath { @[kstack] = count(); }'
```

---

## 13. 源码文件索引

| 文件 | 关键内容 | 关键行 |
|------|---------|--------|
| `include/linux/spinlock.h` | spin_lock/spin_unlock 宏定义 | L339-342 |
| `include/linux/spinlock_api_smp.h` | __raw_spin_lock 实现 | L154-162 |
| `include/linux/spinlock_types.h` | struct spinlock (两层封装) | L17-30 |
| `include/linux/spinlock_types_raw.h` | struct raw_spinlock | L41-56 |
| `include/linux/lockdep.h` | spin_acquire/spin_release, LOCK_CONTENDED | L441-515 |
| `include/linux/irqflags.h` | local_irq_save/restore | L168-225 |
| `include/asm-generic/qspinlock.h` | queued_spin_lock/unlock/trylock | L107-149 |
| `include/asm-generic/qspinlock_types.h` | struct qspinlock, _Q_* 编码宏 | L14-95 |
| `include/asm-generic/ticket_spinlock.h` | ticket_spin_lock/unlock (对比) | L39-96 |
| `arch/x86/include/asm/qspinlock.h` | x86 专用 btsl 汇编 | L16-30 |
| `kernel/locking/qspinlock.c` | queued_spin_lock_slowpath | L130-352 |
| `kernel/locking/qspinlock.h` | encode_tail, xchg_tail, clear_pending | L52-221 |
| `kernel/locking/qspinlock_paravirt.h` | PV qspinlock 全部逻辑 | L1-427 |
| `kernel/locking/mcs_spinlock.h` | struct mcs_spinlock, mcs_spin_lock | L56-111 |
| `kernel/locking/spinlock.c` | _raw_spin_lock_irqsave (debug 版本) | L156-405 |

---

## 14. 使用建议

| 场景 | 推荐的锁定原语 |
|------|--------------|
| 临界区 < 25 条指令，不长 | `spin_lock` / `spin_unlock` |
| 临界区可能较长 | `mutex_lock`（睡眠等待，不浪费 CPU）|
| 中断上下文中 | `spin_lock_irqsave` / `spin_unlock_irqrestore` |
| 保护 softirq 共享数据 | `spin_lock_bh` / `spin_unlock_bh` |
| 读写比例高 | `rcu_read_lock` / `rcu_read_unlock`（RCU）或 `rwlock_t` |
| 临界区不可原子化 | 必须用信号量或 mutex，绝不能用 spinlock |
| KVM/Xen 虚拟机 | 自动使用 PV qspinlock（`_Q_SLOW_VAL` 路径）|

**spinlock 临界区禁令**（不可调用可能休眠的函数）：

```
spin_lock(&lock);
  kmalloc(32, GFP_KERNEL);        // ❌ 可能休眠
  copy_from_user(&data, ptr, sz); // ❌ 可能缺页
  mutex_lock(&another_lock);      // ❌ 可能休眠
  msleep(1);                      // ❌ 显式休眠
spin_unlock(&lock);
```

---

## 15. 关联文章

- **08-mutex**: 睡眠锁（mutex vs spinlock 适用场景对比）
- **10-rwsem**: 读写锁（自旋 + 睡眠混合）
- **12-rcu**: RCU（无锁读的终极方案）

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-06 | 内核版本：Linux 7.0.8*
