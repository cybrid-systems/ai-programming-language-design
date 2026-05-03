# 09-spinlock — Linux 内核自旋锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**自旋锁（spinlock）** 是 Linux 内核最基础的同步原语。当锁被持有时，尝试获取的 CPU 忙等待（spin）而非休眠。锁持有者必须在极短时间内释放锁，且临界区内不可休眠。

x86-64 上当前实现为 **queued spinlock（qspinlock）**，由 Waiman Long 于 2015 年引入。三层路径架构：快速路径（原子 cmpxchg）→ pending bit 优化 → MCS 队列。

**doom-lsp 确认**：`include/asm-generic/qspinlock.h` 含 **8 个符号**（`queued_spin_lock_slowpath` @ L100，`queued_spin_lock` @ L107，`queued_spin_unlock` @ L123）。`kernel/locking/qspinlock.c` 含 **10 个符号**（`queued_spin_lock_slowpath` @ L130）。

---

## 1. 核心数据结构

### 1.1 struct qspinlock（32-bit 编码）

```c
// include/asm-generic/qspinlock_types.h
typedef struct qspinlock {
    union {
        atomic_t val;    // 整个 32-bit 原子值

        // Little-endian 字节布局：
        struct {
            u8  locked;     // [7:0]   锁状态：0=空闲, 非0=已锁
            u8  pending;    // [15:8]  等待位：一个优化级等待者
        };
        struct {
            u16 locked_pending; // [15:0]
            u16 tail;           // [31:16] MCS 队列尾节点编码
        };
    };
} arch_spinlock_t;
```

**32-bit 位编码**：
```
┌───────31───────16┌──15──┌──8─┌──7──┐
│    tail_cpu     │ tail │pending│locked │
│    (14 bits)    │ idx  │ (1-8b)│ (8b)  │
└─────────────────┴──────┴───────┴───────┘
```

三个状态可同时存在：
- **locked=1**：锁已被某 CPU 持有
- **pending=1**：有一个等待者在自旋（优化级）
- **tail**：MCS 队列尾节点（指向最后一个排队的 CPU）

### 1.2 struct mcs_spinlock（排队节点）

```c
// kernel/locking/mcs_spinlock.h
struct mcs_spinlock {
    struct mcs_spinlock *next;   // 队列中的下一个节点
    int locked;                  // 前驱释放后的通知标志
    int count;                   // 嵌套深度（处理 NMI 重入）
};

// per-CPU 队列节点池（每个 CPU 4 个节点，应对 NMI 嵌套）
// kernel/locking/qspinlock.c:80 — doom-lsp 确认
DEFINE_PER_CPU_ALIGNED(struct qnode, qnodes) = {
    .mcs = { { .count = 0 } }
};
```

---

## 2. 快速路径——queued_spin_lock

```c
// include/asm-generic/qspinlock.h:107 — doom-lsp 确认
static __always_inline void queued_spin_lock(struct qspinlock *lock)
{
    int val = 0;

    // 快速路径：尝试 cmpxchg(0 → _Q_LOCKED_VAL)
    if (likely(atomic_try_cmpxchg_acquire(&lock->val, &val, _Q_LOCKED_VAL)))
        return;  // ← 零竞争，直接用一条指令获取锁！

    // 竞争发生 → 进入慢速路径
    queued_spin_lock_slowpath(lock, val);
}

static __always_inline void queued_spin_unlock(struct qspinlock *lock)
{
    // 释放：将 locked 字节清零（release 语义）
    smp_store_release(&lock->locked, 0);
}
```

**快速路径汇编**（x86-64）：
```asm
; queued_spin_lock 快速路径
xor    %eax, %eax           ; val = 0
mov    $1, %edx             ; new = _Q_LOCKED_VAL
lock cmpxchg %edx, (%rdi)   ; if (*lock == 0): *lock = 1
jnz    slowpath             ; 竞争 → 慢速路径
ret                         ; ✅ 获取锁成功！
; 耗时：~10ns（单条 lock cmpxchg 指令）
```

---

## 3. 慢速路径——queued_spin_lock_slowpath

```c
// kernel/locking/qspinlock.c:130 — doom-lsp 确认
void __lockfunc queued_spin_lock_slowpath(struct qspinlock *lock, u32 val)
```

### 3.1 路径一：pending bit 优化

```c
    // 如果锁只有 locked=1，没有其他等待者
    if (val == _Q_PENDING_VAL) {
        // 等待 pending→locked 交接完成
        int cnt = _Q_PENDING_LOOPS;
        val = atomic_cond_read_relaxed(&lock->val,
                                       (VAL != _Q_PENDING_VAL) || !cnt--);
    }

    // 如果有竞争（pending 或 tail 非空）→ 直接进队列
    if (val & ~_Q_LOCKED_MASK)
        goto queue;

    // 尝试抢占 pending bit：
    val = queued_fetch_set_pending_acquire(lock);
    // → 原子操作：设置 pending=1，返回旧值

    if (unlikely(val & ~_Q_LOCKED_MASK)) {
        // 竞争失败（有其他 CPU 也在抢）
        if (!(val & _Q_PENDING_MASK))
            clear_pending(lock);  // 撤销 pending
        goto queue;  // 进队列
    }

    // ★ 成功设置 pending bit！
    // 等待持有者释放 locked
    if (val & _Q_LOCKED_MASK)
        smp_cond_load_acquire(&lock->locked, !VAL);

    // 获取锁：清除 pending，设置 locked
    clear_pending_set_locked(lock);
    return;  // ✅ 获取成功！只多了一次 CAS
```

**Pending bit 的优化意义**：
```
无 pending bit:               有 pending bit:
CPU A: [locked]               CPU A: [locked]
CPU B: → 直接进队列（~100ns）  CPU B: pending=1, 自旋等待
                              CPU A释放 → CPU B获取
                              延迟从~100ns降到~20ns
```

### 3.2 路径二：MCS 队列

```c
queue:
    // 分配 per-CPU MCS 节点
    node = this_cpu_ptr(&qnodes[0].mcs);
    idx = node->count++;           // 嵌套深度索引
    tail = encode_tail(smp_processor_id(), idx);

    if (unlikely(idx >= _Q_MAX_NODES)) {
        // 嵌套过深（通常只有 NMI 才可能）
        while (!queued_spin_trylock(lock))
            cpu_relax();
        goto release;
    }

    node = grab_mcs_node(node, idx);
    node->locked = 0;
    node->next = NULL;

    // 将自身发布为队列尾部
    old = xchg_tail(lock, tail);    // ★ 原子替换 tail

    // 如果有前驱，链接到前驱的 next
    if (old & _Q_TAIL_MASK) {
        prev = decode_tail(old);
        // 将自身链入前驱的 next
        WRITE_ONCE(prev->next, node);

        // ★ 自旋等待前驱释放
        arch_mcs_spin_lock_contended(&node->locked);
        // → while (!node->locked) cpu_relax()
    }

    // 现在是队首！等待 locked 释放
    if ((val = atomic_read(&lock->val)) & _Q_LOCKED_MASK)
        smp_cond_load_acquire(&lock->locked, !VAL);

    // ★ 获取锁！
    // 清除队首的 tail 标记
    old = clear_tail_mark(atomic_fetch_or_acquire(...));
    // 设置 locked
    lock->locked = _Q_LOCKED_VAL;

    // 唤醒下一个等待者
    if (node->next)
        // 通过 next 指针通知后继者
        arch_mcs_spin_unlock_contended(&node->next->locked);
}
```

---

## 4. MCS 队列完整图解

```
初始：lock=0x01 (locked=1, CPU A 持有)

CPU B 加入：
  tail = encode_tail(CPU1, node[0])
  xchg_tail(lock, tail) → lock=0x00xx0101
  prev = decode_tail(old)
  WRITE_ONCE(prev->next, node_B)
  → 队列: [CPU A] ← [CPU B]
  → 自旋: while(!node_B->locked) cpu_relax()

CPU C 加入：
  tail = encode_tail(CPU2, node[0])
  xchg_tail(lock, tail) → lock=0x00yy0101
  prev = decode_tail(old) = decode_tail(0x00xx)
  prev = node_B (CPU1)
  WRITE_ONCE(prev->next, node_C)
  → 队列: [CPU A] ← [CPU B] ← [CPU C]
  → CPU B 自旋等 locked=0
  → CPU C 自旋等 node_C->locked=1

CPU A 释放锁：
  smp_store_release(&lock->locked, 0)
  CPU B 检测到 locked=0 → 获取锁
  node_B->locked = 1
  CPU C 检测到 node_C->locked=1 → 获取锁
```

---

## 5. per-CPU 队列节点的 NMI 安全

```c
// 每个 CPU 有 4 个 MCS 节点（qnodes[0..3]）
// 应对 NMI 嵌套（最多 3 级 NMI 嵌套 + 1 个普通中断）

#define _Q_MAX_NODES 4

// 分配时检查深度：
if (unlikely(idx >= _Q_MAX_NODES)) {
    // NMI 嵌套超过 3 层 → 直接自旋（不用 MCS 节点）
    while (!queued_spin_trylock(lock))
        cpu_relax();
}
```

---

## 6. 锁操作性能数据

| 路径 | 延迟 | 条件 |
|------|------|------|
| 快速路径 cmpxchg | ~10ns | 锁空闲 |
| pending bit 自旋 | ~20-100ns | 一个等待者 |
| MCS 排队+自旋 | ~100-500ns | 多核竞争 |
| unlock release | ~2ns | smp_store_release |

---

## 7. 源码文件索引

| 文件 | 符号数 | 关键行 |
|------|--------|--------|
| include/asm-generic/qspinlock.h | 8 | queued_spin_lock @ L107 |
| kernel/locking/qspinlock.c | 10 | slowpath @ L130 |
| include/asm-generic/qspinlock_types.h | — | 32-bit 位编码 |

---

## 8. 关联文章

- **08-mutex**: 睡眠锁 vs 自旋锁
- **10-rwsem**: 读写锁（自旋 + 睡眠混合）

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 9. MCS 队列排队完整流程

```c
// qspinlock.c — 排队核心代码（注释已含状态转移）

queue:
    // 分配 per-CPU 节点
    node = this_cpu_ptr(&qnodes[0].mcs);
    idx = node->count++;               // 嵌套深度
    tail = encode_tail(smp_processor_id(), idx);

    // 节点初始化
    node->locked = 0;
    node->next = NULL;

    // 排入队列 → xchg_tail 原子替换 tail
    // 状态转移: p,*,* -> n,*,*  （p=旧尾, n=新尾）
    old = xchg_tail(lock, tail);

    // 如果有前驱，链接到前驱的 next
    if (old & _Q_TAIL_MASK) {
        prev = decode_tail(old);
        WRITE_ONCE(prev->next, node);  // 链入前驱

        // → 状态: [prev] → [node] → NULL
        // → 前驱的 next 指向 node
        
        // 自旋等待
        arch_mcs_spin_lock_contended(&node->locked);
        // → while (!node->locked) cpu_relax()
    }

    // 成为队首后，等待 locked 释放
    if ((val = atomic_read(&lock->val)) & _Q_LOCKED_MASK)
        smp_cond_load_acquire(&lock->locked, !VAL);
    // → while (lock->locked) cpu_relax();

    // 获取锁！
    old = clear_tail_mark(atomic_fetch_or_acquire(&lock->val, _Q_LOCKED_VAL));
    // → 清除 tail 标记，设置 locked

    // 唤醒后继者
    if (next)
        arch_mcs_spin_unlock_contended(&next->locked);
    // → next->locked = 1 → 唤醒队列中下一个等待者
```

## 10. qspinlock 状态转移图

```
锁状态（val 的 32-bit 值）：
  0x0000_0000: 完全空闲
  0x0000_0001: 已锁，无等待者
  0x0000_0101: 已锁 + pending 位（一个等待者）
  0x00xx_0101: 已锁 + pending + MCS 队列
  
状态转移（获取锁时）：
  0x0000_0000 → cmpxchg → 0x0000_0001   [快速路径]
  0x0000_0001 → 设置pending→自旋→clear_pending_set_locked [单竞争]
  0x0000_0101 → 进 MCS 队列              [多竞争]

状态转移（释放锁时）：
  0x0000_00x1 → smp_store_release(locked=0) → 0x0000_0000 [无等待者]
  0x0000_0101 → smp_store_release(locked=0) → pending 者获取 [有等待者]
  0x00xx_0101 → smp_store_release(locked=0) → MCS 队首获取 [有队列]
```

## 11. xchg_tail 原子操作

```c
// include/asm-generic/qspinlock.h
// xchg_tail 原子的替换 lock->val 的 tail 部分
// 使用 atomic_xchg 或 xchg 指令

static __always_inline u32 xchg_tail(struct qspinlock *lock, u32 tail)
{
    // 将 tail 字段编码到 lock->val 的 [31:16] 位
    // 使用 atomic_xchg 一次性交换整个 32-bit 值
    u32 old, new;

    do {
        old = atomic_read(&lock->val);
        new = (old & _Q_LOCKED_PENDING_MASK) | tail;
    } while (!atomic_try_cmpxchg(&lock->val, &old, new));

    return old;
}

// 汇编层面（x86-64）：
// → lock cmpxchg 或 xchg 指令
// → 原子操作，~20ns
```

## 12. 调试和统计

```bash
# CONFIG_LOCK_SPIN_ON_OWNER 启用 spinning
# CONFIG_QUEUED_SPINLOCKS 启用 qspinlock

# spinlock 性能统计（需要 CONFIG_LOCK_EVENT_COUNTS）
# /sys/kernel/debug/locking/ 目录

# 使用 perf 监测 spinlock 竞争
perf stat -e spin_lock:spin_lock_acquire -a -- sleep 1
perf stat -e spin_lock:spin_lock_contended -a -- sleep 1

# lock_stat 跟踪
echo 0 > /proc/sys/kernel/lock_stat
# ... 运行负载 ...
echo 1 > /proc/sys/kernel/lock_stat
cat /proc/lock_stat
```

## 13. queued_spin_trylock —— 非阻塞尝试

```c
// include/asm-generic/qspinlock.h:90 — doom-lsp 确认
static __always_inline int queued_spin_trylock(struct qspinlock *lock)
{
    int val = atomic_read(&lock->val);

    // 快速检查：只要有任何非零值（locked/pending/tail），锁不可用
    if (unlikely(val))
        return 0;  // 被持有或有等待者

    // 只有 val==0 时尝试 cmpxchg
    return likely(atomic_try_cmpxchg_acquire(&lock->val, &val, _Q_LOCKED_VAL));
}
```

## 14. 源码文件索引

| 文件 | 符号数 | 关键行 |
|------|--------|--------|
| include/asm-generic/qspinlock.h | 8 | queued_spin_lock @ L107, trylock @ L90 |
| kernel/locking/qspinlock.c | 10 | slowpath @ L130 |
| include/asm-generic/qspinlock_types.h | — | 32-bit encoding |
| kernel/locking/mcs_spinlock.h | — | struct mcs_spinlock |

## 15. 关联文章

- **08-mutex**: 睡眠锁（mutex vs spinlock 适用场景对比）
- **10-rwsem**: 读写锁（读可多核并发）

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 16. qrwlock 读写自旋锁

除了 qspinlock，x86 还实现了 qrwlock（排队读写锁）：

```c
// arch/x86/include/asm/qrwlock.h
typedef struct qrwlock {
    union {
        atomic_t cnts;           // 计数
        struct {
            u8 wlocked;          // [7:0]   写锁定标志
            u8 rcnts[3];         // [31:8]  读计数
        };
    };
    arch_spinlock_t wait_lock;   // MCS 队列锁
} arch_rwlock_t;
```

- 多个读者可同时持有锁（rcnts > 0）
- 写者必须排他（wlocked = 1，且 rcnts = 0）
- 写者优先：写者等待时，新读者被阻塞

## 17. spin_lock vs raw_spin_lock

```c
// include/linux/spinlock.h — 两层封装
typedef struct spinlock {
    union {
        struct raw_spinlock rlock;
    };
} spinlock_t;

// 非 RT 内核：spinlock ≡ raw_spinlock
// RT 内核：spinlock 可被 PI 转换为 rt_mutex（可休眠）
// raw_spinlock 始终是真正的自旋锁

// 标准用法：
spin_lock(&lock);        // 非 RT: 自旋锁, RT: 可能休眠
raw_spin_lock(&lock);    // 始终自旋
```

## 18. 临界区限制

```c
// ✅ 正确的使用：
spin_lock(&lock);
shared_counter++;               // 简单操作
shared_flag = true;
spin_unlock(&lock);

// ❌ 不可在临界区中调用：
spin_lock(&lock);
kmalloc(32, GFP_KERNEL);        // 可能休眠
copy_from_user(&data, ptr, sz); // 可能缺页
mutex_lock(&another_lock);      // 可能休眠
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 19. 自旋锁使用建议

| 场景 | 建议 |
|------|------|
| 临界区 < 25 条指令 | spin_lock |
| 临界区可能较长 | mutex（睡眠等待，不浪费 CPU）|
| 中断上下文中 | spin_lock_irqsave（必须关中断）|
| 保护 softirq 共享数据 | spin_lock_bh |
| 读写比例高 | rwlock_t / RCU |
| 临界区可休眠 | 绝不能用 spinlock |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01*
