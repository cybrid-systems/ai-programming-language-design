# RCU 同步机制深度分析

> 内核源码: Linux 7.0-rc1 (commit 未标注)
> 源码路径: `/home/dev/code/linux/kernel/rcu/` + `/home/dev/code/linux/include/linux/rcupdate.h`
> 关键词: Read-Copy-Update, grace period, call_rcu, synchronize_rcu, srcu, tree RCU

---

## 1. RCU 核心概念

### 1.1 什么是 RCU？为什么读端不需要锁？

RCU (Read-Copy-Update) 是一种特殊的同步机制，**读端完全不需要加锁**。这是通过以下事实实现的：

- **读者**只是读取共享数据，不需要修改
- **写者**在修改数据之前，先复制一份副本，在副本上做修改，然后在一个合适的时机（所有读者都离开临界区后）才用新数据替换旧数据

```
struct foo {
    int data;
    struct rcu_head rcu;    // 嵌入在要被 RCU 释放的结构体中
};

// 读端——不需要任何锁
rcu_read_lock();               // 可选，仅用于 lockdep 标注
struct foo *p = rcu_dereference(gbl_foo);
... use p->data ...
rcu_read_unlock();

// 写端
struct foo *new = kmalloc(...);
new->data = new_value;
rcu_assign_pointer(gbl_foo, new);   // 原子地替换指针
synchronize_rcu();                  // 等待所有读者完成
kfree(old);                         // 安全释放旧对象
```

RCU 读端不需要锁的**关键**在于：

1. `rcu_dereference()` 提供了**LoadAcquire** 语义，确保看到新指针指向的完整初始化
2. `rcu_assign_pointer()` 提供了 **StoreRelease** 语义，确保所有初始化写入在指针发布之前完成
3. 写端的 `synchronize_rcu()` 阻塞，直到所有**已存在的**读端临界区全部退出
4. **新的**读端临界区会看到新数据（因为指针已经更新）

### 1.2 Grace Period 是什么？

**Grace Period（宽限期）**是 RCU 的核心概念——它是写者等待所有旧读者完成的时间窗口。

```
CPU0: rcu_read_lock() ──────────────临界区A (老数据)─────离开
CPU1:         rcu_read_lock() ──临界区B (老数据)──────离开
CPU2:                                     rcu_read_lock() ─临界区C(新数据)─离开
                                                        ↑这就是 grace period
```

**Grace Period 必须满足的条件：**
- 所有在 **synchronize_rcu() 调用之前**开始的读端临界区，都**必须已经结束**
- 在 grace period 期间**新开始**的读端临界区，可以继续使用旧数据或新数据（取决于实现）

### 1.3 为什么要等待 Grace Period 结束才能释放数据？

考虑以下场景：

```
旧数据对象 O（正被某个老读者 CPU0 持有）
新数据对象 N

CPU0: rcu_read_lock()          // 进入了临界区，持有对 O 的引用
CPU1: rcu_assign_pointer(P, N)  // 发布新指针
CPU1: kfree(O)                  // 如果现在就释放 O，CPU0 将发生 use-after-free！
CPU0: ... O->field ...          // 访问已释放的内存
CPU0: rcu_read_unlock()         // 离开临界区
```

`synchronize_rcu()` 保证：**在它返回之前，所有在调用之前开始的读端临界区都已经结束**，因此此时释放旧对象是安全的。

---

## 2. `rcu_head` 和 `call_rcu` 路径

### 2.1 `rcu_head` 结构体

Linux 内核通过 `types.h` 将 `rcu_head` 定义为 `callback_head` 的别名：

```c
// include/linux/types.h
struct callback_head {
    struct callback_head *next;
    void (*func)(struct callback_head *head);
};
#define rcu_head callback_head

// include/linux/rcupdate.h
typedef void (*rcu_callback_t)(struct rcu_head *head);
```

它只包含两个字段：**next 指针**（用于组成链表）和 **func 回调函数**。`rcu_head` 通常**嵌入**在被 RCU 管理的结构体中：

```c
struct foo {
    int data;
    struct rcu_head rcu;   // 放在结构体末尾，kfree_rcu() 才能工作
};
```

### 2.2 `call_rcu()` 完整路径

```
call_rcu(head, func)
  └── __call_rcu_common(head, func, enable_rcu_lazy)
        ├── head->func = func
        ├── rdp = this_cpu_ptr(&rcu_data)        // 获取当前 CPU 的 rcu_data
        ├── check_cb_ovld(rdp)                    // 检查回调是否过载
        │
        ├── if (rcu_rdp_is_offloaded(rdp))
        │     call_rcu_nocb(rdp, head, func, ...) // NOCB 路径，跳到 percpu kthread
        │     └── 将 head 加入 rdp->nocb_bypass 或 nocb_cb_wq
        │
        └── call_rcu_core(rdp, head, func, flags)
              ├── rcu_segcblist_enqueue(&rdp->cblist, head)  // 加入分段回调队列
              ├── // 回调被放入 cblist，等待对应 grace period 后执行
              └── if (need to wake GP kthread)
                    rcu_gp_kthread_wake()
```

**关键数据结构——`rcu_segcblist`（分段回调链表）：**

```c
// kernel/rcu/rcu_segcblist.h
struct rcu_segcblist {
    struct rcu_head *head;
    struct rcu_head *tails[RCU_CBL_NSEGS];  // 每段尾部指针
    int flags;
    // 各段意义（RCU_DONE_TAIL=0 是已完成 GP 可执行的）：
    // [0] RCU_DONE_TAIL     - 已完成等待，可以立即执行
    // [1] RCU_WAIT_TAIL     - 正在等待某个 GP 完成
    // [2] RCU_NEXT_READY_TAIL - 下一个 GP 来临时移动到这里
    // [3] RCU_NEXT_TAIL     - 尚未被任何 GP 认领
};
```

### 2.3 Batch 机制：多个 `call_rcu` 如何聚合？

RCU 不为每次 `call_rcu()` 单独启动一个 grace period。**多个回调在同一个 grace period 中被批量处理**：

```
CPU0: call_rcu(cb_A) → 放入 local CPU 的 cblist [RCU_NEXT_TAIL]
CPU1: call_rcu(cb_B) → 放入 local CPU 的 cblist [RCU_NEXT_TAIL]
CPU2: call_rcu(cb_C) → 放入 local CPU 的 cblist [RCU_NEXT_TAIL]
                         ↓
              当 GP kthread 开始一个新的 grace period
              会调用 rcu_advance_cbs() 把 RCU_NEXT_TAIL 段的 cb
              移动到 RCU_WAIT_TAIL，表示它们在等待这个 GP
                         ↓
              GP 完成后，回调从 RCU_DONE_TAIL 被摘下执行
```

RCU 设计者故意**不在每次 `call_rcu()` 时立即唤醒 GP kthread**（除非积压严重），以避免频繁创建 GP 产生的性能开销。批量处理显著提高了写端的效率。

---

## 3. Grace Period 检测：三阶段

RCU grace period 由专用的 **`rcu_gp_kthread`** 内核线程驱动，分为三个阶段：

```
rcu_gp_kthread 循环:
  ┌─────────────────────────────────────────────────────────┐
  │ RCU_GP_WAIT_GPS  ──→ 等待 RCU_GP_FLAG_INIT              │
  └────────┬───────────────────────────────────────────────┘
           ↓
  ┌────────────────────┐
  │   rcu_gp_init()    │  ←── GP_FLAG_INIT 被设置时进入
  │   (初始化新 GP)    │
  └────────┬───────────┘
           ↓
  ┌────────────────────────┐
  │  rcu_gp_fqs_loop()     │  ←── 强制 quiescent state
  │  (fqs = force-quiescent-state)
  └────────┬───────────────┘
           ↓
  ┌────────────────────┐
  │   rcu_gp_cleanup() │  ←── GP 结束，通知所有等待者
  │   (清理 GP 状态)   │
  └────────┬───────────┘
           ↓
       (返回等待下一轮)
```

### 3.1 `rcu_gp_init()` — 阶段一：初始化

```c
// tree.c:1804
static noinline_for_stack bool rcu_gp_init(void)
{
    // 1. 增加 gp_seq（grace period 序列号），这是一个原子递增的计数器
    //    每次新的 GP 开始时递增（<< RCU_SEQ_CTR_SHIFT）
    rcu_seq_start(&rcu_state.gp_seq);

    // 2. 处理 CPU hotplug：扫描所有 leaf rcu_node
    //    更新 qsmaskinit = qsmaskinitnext（反映当前在线 CPU）
    rcu_for_each_leaf_node(rnp) {
        rnp->qsmask = rnp->qsmaskinit;  // 每个在线 CPU 的 bit 置 1
        rnp->rcu_gp_init_mask = ...;    // 记录 offline CPU
    }

    // 3. 为所有被 blocked tasks 持有自旋锁的读者设置等待队列
    //    （仅 PREEMPT_RCU）
    rcu_preempt_check_blocked_tasks(rnp);
}
```

**qsmask** 是这个算法的核心！它是一个位掩码，每一位代表一个需要报告 quiescent state 的实体（CPU 或子节点）。GP 初始时，所有在线 CPU 的对应位都是 1（表示"还需要等待"）。

### 3.2 `rcu_gp_fqs_loop()` — 阶段二：推进与强制

在 PREEMPT_RCU 中，读者可以在任意睡眠点（schedule()）阻塞。此时读者持有 **preempt-disable** 区域或 **interrupt-disabled** 区域，仍然算作活跃读者。

```
fqs_loop:
  ┌────────────────────────────────────────┐
  │ rcu_gp_advance()                       │  ← 推进 GP 状态
  │   遍历 rcu_node 树，检查 qsmask      │
  │   如果某个子节点的 qsmask=0           │
  │   （所有 CPU 都已报告 quiescent state）│
  │   → 将父节点的对应位清除              │
  └────────┬───────────────────────────────┘
           ↓
  ┌────────────────────────────────────────┐
  │ rcu_try_advance_fqs()                 │  ← 实际推进
  │   如果 root rcu_node 的 qsmask=0      │
  │   → 所有 CPU 都 quiescent，GP 可结束 │
  │   否则                                   │
  │   如果 jiffies >= jiffies_force_qs    │
  │   → on_each_cpu(force_quiescent_state) │
  │     强制所有 CPU 报告 quiescent state  │
  └────────┬───────────────────────────────┘
           ↓
      (睡眠等待，或继续循环)
```

**quiescent state（静止状态）**对于普通 RCU 意味着：
- 进程上下文：调用了 `schedule()`（即不在 RCU 读端临界区）
- 处于 `rcu_read_lock()`/`rcu_read_unlock()` 之间（仅 PREEMPT_RCU）
- CPU 处于 idle 状态
- 持有一个 preempt-disable 区域（作为 RCU 读端）

### 3.3 `rcu_gp_cleanup()` — 阶段三：清理

```c
// tree.c:2150
static noinline void rcu_gp_cleanup(void)
{
    // 1. 遍历所有 rcu_node，将 gp_seq 更新到新值
    //    这样其他 CPU 看到新的 gp_seq 就知道这个 GP 已结束
    rcu_for_each_node_breadth_first(rnp) {
        rnp->gp_seq = new_gp_seq;  // 广播到所有节点
    }

    // 2. 更新 root，标记 GP 结束
    rcu_seq_end(&rcu_state.gp_seq);
    WRITE_ONCE(rcu_state.gp_state, RCU_GP_IDLE);

    // 3. 检查是否需要新的 GP
    //    如果有新的 call_rcu 到来，设置 RCU_GP_FLAG_INIT
    if (needgp)
        WRITE_ONCE(rcu_state.gp_flags, RCU_GP_FLAG_INIT);

    // 4. 唤醒所有等待 synchronize_rcu() 的进程
    rcu_sr_normal_gp_cleanup();   // 唤醒 rcu_synchronize 队列
}
```

### 3.4 NO_HZ_FULL 模式：没有 tick 时如何报告 Quiescent State？

在 NO_HZ_FULL（全 tickless）模式下，一个 CPU 可能长时间运行而没有调度中断。RCU 不能等下一次 `schedule()` 来检测它进入了 quiescent state。

Linux 6.x 引入的解决方案：**context_tracking** 机制**持续监控 CPU 当前是否在 userspace/kernel 边界**。

```c
// NO_HZ_FULL 下，RCU 通过以下方式检测 idle/quiescent：
// 1. kernel/rcu/tree.c: rcu_exp_handler() (用于 expedited GP)
//    如果目标 CPU 在 idle（rcu_is_cpu_rrupt_from_idle()）
//    → 直接报告 quiescent state（idle 状态天然就是 quiescent）
//
// 2. 如果 CPU 不是 idle 但也不在 RCU 读端临界区
//    tick_dep_set_cpu(cpu, TICK_DEP_BIT_RCU_EXP)
//    强制在下一次 tick 中断时报告 QS
//
// 3. rcu_read_unlock() 中（CONFIG_RCU_STRICT_GRACE_PERIOD）：
//    如果当前 CPU 长时间持有 RCU 读锁且有 pending expedited GP
//    会触发 resched 强制调度以报告 QS
```

关键洞察：**idle CPU 天然就是 quiescent**（没有持有任何 RCU 读锁），所以 NO_HZ_FULL 只需要确保 non-idle CPU 在持有读锁时不阻塞 GP 进展。`context_tracking_cpu_acquire()` 和 `context_tracking_cpu_release()` 记录 CPU 当前是否在 RCU 等价区域内。

---

## 4. `synchronize_rcu()` vs `synchronize_rcu_expedited()`

### 4.1 普通 `synchronize_rcu()`

```c
// tree.c:3349
void synchronize_rcu(void)
{
    // 如果在 RCU 读端临界区中调用 → 死锁检测
    RCU_LOCKDEP_WARN(lock_is_held(&rcu_lock_map) ||
                     lock_is_held(&rcu_bh_lock_map) ||
                     lock_is_held(&rcu_sched_lock_map),
                     "Illegal synchronize_rcu() in RCU read-side critical section");

    if (rcu_blocking_is_gp())   // 早期启动阶段，单 CPU
        return;                  // → 直接跳过（无需等待）

    // 路径 A: 如果已有 poll API 用户在等待，当前同步可以 piggyback
    if (start_poll_synchronize_rcu())
        return;  // 让它们完成后再通知

    // 路径 B: 正常路径
    // 等待 rcu_synchronize 结构体被 rcu_gp_cleanup() 唤醒
    wait_rcu_gp(call_rcu_hurry);
}
```

普通 `synchronize_rcu()` 的代价是：**需要等待整个 GP 完成**，而 GP 的长度是不确定的（可能几十毫秒甚至更长）。

### 4.2 Expedited GP：`synchronize_rcu_expedited()`

```c
// tree_exp.h + tree_exp.c
void synchronize_rcu_expedited(void)
{
    // 1. 快照当前的 expedited_sequence 号
    s = rcu_exp_gp_seq_snap();

    // 2. funnel lock：尝试获取 exp_mutex
    //    如果已有人持有，说明其他人在做 expedited GP，直接等待
    if (exp_funnel_lock(s))
        return;  // 有人替我们做了

    // 3. 启动新的 expedited GP
    rcu_exp_sel_wait_wake(s);
}

// 核心：向所有在线非 idle CPU 发送 IPI（处理器间中断）
// tree_exp.h: __sync_rcu_exp_select_node_cpus()
static void __sync_rcu_exp_select_node_cpus(struct rcu_exp_work *rewp)
{
    rnp->expmaskinitnext;  // 所有曾经在线的 CPU

    for_each_leaf_node_cpu_mask(rnp, cpu, rnp->expmask) {
        if (cpu == raw_smp_processor_id())
            continue;   // 跳过自己
        if (!(rnp->qsmaskinitnext & mask))
            continue;  // CPU 已下线

        // 检查 CPU 是否处于 idle 或 userspace（NORMAL 模式下等价于 quiescent）
        snap = ct_rcu_watching_cpu_acquire(cpu);
        if (rcu_watching_snap_in_eqs(snap)) {
            // CPU 在 idle 或 userspace → 已到达 quiescent state
            mask_ofl_test |= mask;
            continue;
        }

        // 否则：发送 IPI 让 CPU 报告
        smp_call_function_single(cpu, rcu_exp_handler, NULL, 0);
    }
}

// IPI 处理函数
// tree_exp.h: rcu_exp_handler()
static void rcu_exp_handler(void *unused)
{
    if (!rcu_preempt_depth()) {
        // 不在 RCU 读端临界区 → 立即报告 QS
        rcu_report_exp_rdp(rdp);
    } else {
        // 在 RCU 读端临界区 → 设置标志，rcu_read_unlock() 会报告
        rdp->cpu_no_qs.b.exp = true;
        current->rcu_read_unlock_special.b.exp_hint = true;
    }
}
```

**Expedited GP 的核心优势：**通过 IPI 主动向所有 CPU 发送请求，比被动等待 `schedule()` 快得多——通常可以在几百微秒内完成，而不是几十毫秒。但代价是 IPI 会干扰所有 CPU 的当前执行，对实时负载不友好。

---

## 5. `rcu_bh` 和 `rcu_sched`

### 5.1 为什么需要多种 RCU？

Linux 内核在不同历史时期发展出了三种 RCU 变体：

| 变体 | 读者原语 | 等价读端临界区 |
|------|---------|--------------|
| `rcu`（普通 RCU） | `rcu_read_lock()` / `rcu_read_unlock()` | preempt_disable + BH disable |
| `rcu_bh`（bh = bottom half） | `rcu_read_lock_bh()` / `rcu_read_unlock_bh()` | `local_bh_disable()` 区域 |
| `rcu_sched`（调度器 RCU） | `rcu_read_lock_sched()` / `rcu_read_unlock_sched()` | `preempt_disable()` 区域 |

### 5.2 `rcu_bh`：软中断上下文的 RCU

```c
// include/linux/rcupdate.h
static inline void rcu_read_lock_bh(void)
{
    local_bh_disable();         // 禁用软中断
    __acquire_shared(RCU);
    rcu_lock_acquire(&rcu_bh_lock_map);
}

// include/linux/rcupdate.h
static inline void rcu_read_unlock_bh(void)
{
    rcu_lock_release(&rcu_bh_lock_map);
    __release_shared(RCU);
    local_bh_enable();          // 重新启用软中断
}
```

**`rcu_bh` 的意义：**在 v5.0+ 内核中，`synchronize_rcu()` **同时等待** `rcu_read_lock()` **和** `local_bh_disable()` 区域。这意味着 BH 禁用区域也被视为 RCU 读端临界区。

在 v5.0 之前，`rcu_read_lock()` 和 `rcu_read_lock_bh()` 是**完全独立的**，写者需要分别调用 `synchronize_rcu()` 和 `synchronize_rcu_bh()`。

### 5.3 `rcu_sched`：进程调度的 RCU

```c
static inline void rcu_read_lock_sched(void)
{
    preempt_disable();           // 禁用抢占
    __acquire_shared(RCU);
    rcu_lock_acquire(&rcu_sched_lock_map);
}
```

**`rcu_sched` 的意义：**在 v5.0+ 内核中，`synchronize_rcu()` **同时等待** `rcu_read_lock_sched()` 区域，即所有 `preempt_disable()` 区域也被视为读端临界区。

`rcu_read_lock()` 和 `rcu_read_lock_sched()` 在 v5.0+ 代码中是等价的——都通过 `__rcu_read_lock()` 实现。

---

## 6. SRCU（Sleepable RCU）

### 6.1 SRCU 与普通 RCU 的本质区别

**普通 RCU 的读端不能睡眠**——`rcu_read_lock()` 只是 `preempt_disable()`，完全不支持睡眠。

**SRCU 的读端可以睡眠！** 这对于文件系统、驱动等需要可能在临界区内睡眠的场景至关重要。

```c
// 使用 SRCU
DEFINE_SRCU(my_srcu);

void reader(void)
{
    int idx;
    idx = srcu_read_lock(&my_srcu);  // 返回一个索引（0 或 1）
    ... 读共享数据 ...
    srcu_read_unlock(&my_srcu, idx); // 可以睡眠
}
```

### 6.2 SRCU 的数据结构

```c
// include/linux/srcutree.h
struct srcu_struct {
    struct srcu_usage *srcu_sup;
    struct srcu_node **srcu_hier;
    struct srcu_data **sda;          // per-CPU srcu_data 指针
    int srcu_size_state;
    spinlock_t __private lock;       // 内部锁
    struct mutex cb_mutex;           // 保护回调相关
};

// srcu_usage: 记录当前 grace period 状态
// srcu_node:  分层树的节点（类似 tree RCU 的 rcu_node）
// srcu_data: per-CPU 计数器
struct srcu_data {
    atomic_long_t srcu_ctrs[2];     // 奇偶两组计数器
    // srcu_ctrs[0] = 锁计数（读端 +1），srcu_ctrs[1] = 释放计数（读端 +1）
    // 实际只使用 srcu_locks 和 srcu_unlocks 子字段
    unsigned long srcu_unlock_check;
    struct delayed_work work;       // 延迟回调工作
    struct srcu_struct *ssp;
    int cpu;
};
```

### 6.3 `srcu_read_lock()` 和 `srcu_read_unlock()` 的机制

```c
// kernel/rcu/srcutree.c
int __srcu_read_lock(struct srcu_struct *ssp)
{
    int idx;
    struct srcu_data *sdp = raw_cpu_ptr(ssp->sda);

    idx = rcu_seq_ctr(ssp->srcu_sup->srcu_gp_seq) & 0x1;  // 当前 GP 对应奇偶组
    this_cpu_inc(sdp->srcu_ctrs[idx].srcu_locks.counter);  // 当前 GP 对应计数器 +1
    smp_mb__after_atomic();  // B：确保临界区代码在锁增加之后
    return idx;
}

void __srcu_read_unlock(struct srcu_struct *ssp, int idx)
{
    smp_mb();   // C：确保临界区代码在释放之前执行完
    this_cpu_inc(sdp->srcu_ctrs[idx].srcu_unlocks.counter);
}
```

关键洞察：**每 CPU 独立计数**，不需要全局锁。读端临界区结束时，增加对应奇偶组的 `unlocks` 字段。

### 6.4 `synchronize_srcu()` 的 completion 机制

```c
// kernel/rcu/srcutree.c
void synchronize_srcu(struct srcu_struct *ssp)
{
    // 1. 获取当前 GP 序列号的奇偶性
    idx = rcu_seq_ctr(READ_ONCE(ssp->srcu_sup->srcu_gp_seq)) & 0x1;  // 使用当前 GP 的奇偶
    new_idx = !idx;   // 下一轮 GP 的奇偶

    // 2. 等待所有读者从当前奇偶组退出
    //    等待 srcu_locks[idx] == srcu_unlocks[idx]
    for (;;) {
        locks = srcu_readers_lock_idx(ssp, idx, false, 0);
        unlocks = srcu_readers_unlock_idx(ssp, idx, &rdm);

        if (locks == unlocks)
            break;   // 没有读者持有这个奇偶组

        schedule_timeout_idle(srcu_get_delay(ssp));  // 睡眠等待
        // srcu_get_delay() 在有 expedited GP pending 时返回 0
    }

    // 3. 此时所有旧读者都已退出，可以安全地继续
    // 4. 开始新的 GP（递增序列号）
    srcu_gp_start(ssp);
    // srcu_gp_end() 会：增加 srcu_gp_seq + 调用 srcu_schedule_cbs_snp()
    //               将属于旧 GP 的回调排队
}
```

**核心原理：**只要旧读者在退出时会增加 `srcu_unlocks[idx]`，而写者循环检查 `srcu_locks[idx] == srcu_unlocks[idx]`，就能确认所有旧读者都已离开。这比普通 RCU 简单（不需要等待 schedule），但需要**每 CPU 计数器**来避免锁竞争。

**`srcu_gp_started`**（或等价的 `srcu_gp_seq` 状态）用于追踪当前 srcu_struct 是否处于活跃的 GP 等待中。`srcu_get_delay()` 在有其他 expedited GP pending 时返回 0（不睡眠），以加快进度。

---

## 7. Tree RCU 分层架构

### 7.1 `rcu_node` 和 `rcu_data` 的关系

```
用户调用 synchronize_rcu()
         │
         ↓
   设置 RCU_GP_FLAG_INIT
         │
         ↓
   rcu_gp_kthread 唤醒
         │
         ├──────────────────────┐
         ↓                      ↓
  rcu_gp_init()         rcu_gp_fqs_loop()
         │                      │
         └──────────────────────┘
                    │
                    ↓
              rcu_gp_cleanup()
                    │
                    ├──────────────────────────────┐
                    ↓                              ↓
             更新 rcu_state.gp_seq            遍历 rcu_node 树
                    │
                    └──────────────────────────────┘
                               │
                               ↓
                    唤醒所有等待的 synchronize_rcu()
```

### 7.2 分层结构

```c
// tree.h: struct rcu_state
struct rcu_state {
    struct rcu_node node[NUM_RCU_NODES];  // 所有节点的扁平数组
    struct rcu_node *level[RCU_NUM_LVLS + 1];  // 每层起始索引
    int ncpus;
    int n_online_cpus;
    unsigned long gp_seq;           // 全局 GP 序列号
    struct task_struct *gp_kthread;  // GP 专用线程
};

// tree.h: struct rcu_node
struct rcu_node {
    raw_spinlock_t __private lock;
    unsigned long gp_seq;           // 本节点的 GP 序列号
    unsigned long qsmask;            // 还需要报告 QS 的子节点/CPU 位图
    unsigned long qsmaskinit;        // 本次 GP 初始化的 qsmask
    unsigned long qsmaskinitnext;    // 下次 GP 的初始 mask（CPU 在线状态）
    unsigned long expmask;           // expedited GP 位图
    int grplo;                       // 本节点覆盖的最低 CPU 号
    int grphi;                       // 本节点覆盖的最高 CPU 号
    int level;                       // 在树中的层级（0 = root）
    struct rcu_node *parent;        // 父节点指针
    struct list_head blkd_tasks;     // 被阻塞的任务链表（PREEMPT_RCU）
};

// tree.h: struct rcu_data
struct rcu_data {
    unsigned long gp_seq;            // 本 CPU 看到的 GP 序列号
    struct rcu_segcblist cblist;    // 本 CPU 的回调链表
    struct rcu_node *mynode;        // 本 CPU 对应的 leaf rcu_node
    unsigned long grpmask;           // 本 CPU 在 mynode->qsmask 中的位
    bool core_needs_qs;              // 本 CPU 是否需要报告 QS
    int watching_snap;               // dynticks 快照
    // ...
};
```

### 7.3 为什么需要分层？

**问题：**如果有 256 个 CPU，每次 GP 更新全局 `qsmask` 需要 `O(ncpus)` 的锁竞争。

**解决方案：**使用 **hierarchical bitmap**（分层位图），将 `qsmask` 检查分散到各节点：

```
Level 0 (root):     [0-255 CPUs] 位图（1 位表示该子节点还有未完成的）
Level 1 (node 0):    [0-63 CPUs]  位图
Level 1 (node 1):    [64-127 CPUs]
Level 1 (node 2):    [128-191 CPUs]
Level 1 (node 3):    [192-255 CPUs]
Level 2 (leaf):      [每个 CPU]   位图

每个 CPU 报告 QS 时，只需要向上回溯到 root：
    leaf rcu_node: qsmask &= ~cpu_bit      // 清除本 CPU 位
    parent:       如果子节点的 qsmask 变 0 → 清除子节点对应位
    root:         如果 qsmask 变 0 → GP 完成
```

**效果：**单个 CPU 报告 QS 的复杂度从 `O(ncpus)` 降到 `O(log ncpus)`，且锁竞争分布在不同节点上。

---

## 8. Grace Period 完整状态机图（ASCII）

```
                           ┌─────────────────────────────────────┐
                           │                                     │
                           │  ┌──────────────────────────────┐   │
                           │  │      RCU_GP_IDLE             │   │
                           │  │  GP kthread 睡眠于 gp_wq     │   │
                           │  └──────────┬───────────────────┘   │
                           │             │ RCU_GP_FLAG_INIT 设置   │
                           │             │ (call_rcu / synchronize)│
                           │             ↓                        │
                           │  ┌──────────────────────────────┐   │
    ┌──────────────────────┼──│    RCU_GP_WAIT_GPS           │   │
    │                      │  │  GP kthread 等待 GP 开始      │   │
    │                      │  └──────────┬───────────────────┘   │
    │                      │             │ rcu_gp_init() 返回 true│
    │                      │             ↓                        │
    │  ┌───────────────────│──────────────────────────────┐     │
    │  │                   │  ┌──────────────────────────┐ │     │
    │  │                   │  │     RCU_GP_INIT          │ │     │
    │  │                   │  │  • rcu_seq_start()       │ │     │
    │  │                   │  │  • 扫描 CPU hotplug 状态  │ │     │
    │  │                   │  │  • 初始化 qsmaskinit     │ │     │
    │  │                   │  │  • blocked_tasks 入队     │ │     │
    │  │                   │  └──────────┬───────────────┘ │     │
    │  │                   │             │                  │     │
    │  │                   └─────────────┼──────────────────┘     │
    │  │                                 ↓                       │
    │  │            ┌────────────────────────────────────┐      │
    │  │            │        RCU_GP_DONE_GPS              │      │
    │  │            │  • gp_seq 已开始递增                 │      │
    │  │            │  • 进入 FQS 循环                     │      │
    │  │            └──────────┬───────────────────────────┘      │
    │  │                      │                                  │
    │  │    ┌─────────────────┴────────────────────┐            │
    │  │    ↓                                       ↓            │
    │  │    │                                       │            │
    │  │    │  ┌────────────────────────────────────┴──────┐     │
    │  │    │  │  ┌───────────────────────────────────┐   │     │
    │  │    │  │  │        RCU_GP_WAIT_FQS            │   │     │
    │  │    │  │  │  • kthread 睡眠于 jiffies        │   │     │
    │  │    │  │  │  • 等待定时触发或 qsmask 清零    │   │     │
    │  │    │  │  └───┬─────────────────────────────┘   │     │
    │  │    │  │      │ 定时到期 或 qsmask==0         │     │
    │  │    │  │      ↓                               │     │
    │  │    │  │  ┌───────────────────────────────────┐ │     │
    │  │    │  │  │        RCU_GP_DOING_FQS          │ │     │
    │  │    │  │  │  • on_each_cpu() 强制 QS        │ │     │
    │  │    │  │  │  • 遍历 rcu_node 推进 qsmask    │ │     │
    │  │    │  │  └───┬─────────────────────────────┘ │     │
    │  │    │  │      │ qsmask 全 0？                  │     │
    │  │    │  └──────┼───────────────────────────────┘     │
    │  │    │         │ 是                                 │
    │  │    │         ↓                                    │
    │  │    │  ┌────────────────────────────────────────┐   │
    │  │    └───│         RCU_GP_CLEANUP                │   │
    │  │       │  • rcu_seq_end(gp_seq)                 │   │
    │  │       │  • 广播 gp_seq 到所有 rcu_node        │   │
    │  │       │  • gp_state = RCU_GP_IDLE              │   │
    │  │       │  • 唤醒所有等待的 synchronize_rcu()   │   │
    │  │       │  • 检查 needgp → 设置 GP_FLAG_INIT    │   │
    │  │       └──────────────────┬───────────────────┘   │
    │  │                          │                       │
    │  │    (GP 完成，重新进入)   └───────────────────────┘
    │  │
    │  └─────────────────────────────
    │
    └────────────────────────────────────
    
    Expedited GP 路径（synchronize_rcu_expedited）:
    
    调用 synchronize_rcu_expedited()
         │
         ├─→ exp_funnel_lock()  尝试获取 exp_mutex
         │      如果失败 → 等待其他人的 expedited GP 完成
         │
         └─→ rcu_exp_sel_wait_wake()
                  │
                  ├─→ sync_exp_reset_tree()
                  │      设置所有 rcu_node 的 expmask = expmaskinit
                  │      blocked tasks 加入 exp_tasks
                  │
                  ├─→ 遍历每个 leaf rcu_node
                  │      对于每个需要等待的 CPU：
                  │      如果 CPU 在 idle → 直接清除 expmask
                  │      否则 → smp_call_function_single()
                  │              向目标 CPU 发送 IPI
                  │
                  └─→ rcu_exp_wait_wake()
                         swait_event() 等待 root->expmask==0
                         rcu_exp_gp_seq_end()
                         唤醒所有 exp_wq 等待者
                         
    CPU 收到 IPI（rcu_exp_handler）:
         │
         ├─如果不在 RCU 读端临界区 → rcu_report_exp_rdp() 立即报告
         └─如果在 RCU 读端临界区 → 设置 cpu_no_qs.b.exp=true
                                    下次 rcu_read_unlock() 报告
```

---

## 9. 总结

| 方面 | 普通 RCU | Expedited RCU | SRCU |
|------|---------|--------------|------|
| 读端锁代价 | `preempt_disable()` | 同左 | 可能睡眠 |
| GP 等待方式 | 被动等调度 | IPI 强制 | 轮询每 CPU 计数器 |
| 典型延迟 | 几十毫秒 | 几百微秒 | 可变 |
| 适用场景 | 通用同步 | 低延迟需求 | 文件系统、驱动 |
| 写端代价 | 启动 GP（或 batch） | 广播 IPI | 轮询读端退出 |

核心设计原则：**读者不需要任何同步操作**（no read-side overhead），代价全部由写端承担。这使得 RCU 成为读多写少场景下性能最优的同步机制。