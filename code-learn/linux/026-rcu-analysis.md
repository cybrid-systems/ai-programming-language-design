# 26-rcu — Linux 内核 RCU 深度源码分析

> 基于 Linux 7.0.8 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**RCU（Read-Copy-Update）** 是 Linux 内核中一种无锁的并发同步机制，由 Paul E. McKenney 于 2002 年引入。它允许读者（reader）在不加锁、不使用原子操作、不触发缓存行 bouncing 的情况下读取共享数据，而写者（writer）通过创建新副本替换旧数据、延迟回收旧数据来保证并发安全。

RCU 的核心理念：

```
读者路径（极快——无锁、无原子操作、无内存屏障）：
  rcu_read_lock();        // → __rcu_read_lock() → preempt_disable() [非PREEMPT]
  ptr = rcu_dereference(gbl_ptr);
  data = ptr->data;
  rcu_read_unlock();      // → __rcu_read_unlock() → preempt_enable()

写者路径（需要宽限期等待）：
  new_ptr = kmalloc(...);
  *new_ptr = *old_ptr;
  rcu_assign_pointer(gbl_ptr, new_ptr);  // smp_store_release()
  synchronize_rcu();                      // 阻塞等待所有读者退出
  kfree(old_ptr);
```

### Grace Period 状态机总览

```
                    ┌──────────────┐
                    │  RCU_GP_IDLE │ (0) 初始状态
                    └──────┬───────┘
                           │ gp_flags & RCU_GP_FLAG_INIT 被设置
                           ▼
                    ┌──────────────┐
              ┌────►│RCU_GP_WAIT_GPS│ (1) 等待 GP 启动请求
              │     └──────┬───────┘
              │            │ rcu_gp_init() 成功
              │            ▼
              │     ┌──────────────┐
              │     │ RCU_GP_ONOFF │ (3) CPU 热插拔处理
              │     └──────┬───────┘
              │            ▼
              │     ┌──────────────┐
              │     │ RCU_GP_INIT  │ (4) 初始化 qsmask
              │     └──────┬───────┘
              │            ▼
              │     ┌──────────────┐
              │     │RCU_GP_WAIT_FQS│ (5) 等待 FQS 时机
              │     └──────┬───────┘
              │            │
              │            ▼
              │     ┌──────────────┐
              │     │RCU_GP_DOING_FQS(6) 强制 QS 扫描
              │     └──────┬───────┘
              │            │ qsmask == 0
              │            ▼
              │     ┌──────────────┐
              │     │ RCU_GP_CLEANUP│ (7) GP 结束清理
              │     └──────┬───────┘
              │            │
              │     ┌──────────────┐
              │     │ RCU_GP_CLEANED│ (8) 清理完成
              │     └──────┬───────┘
              │            │
              └────────────┘ 回到 RCU_GP_IDLE
```

---

## 1. RCU 的核心概念

### 1.1 宽限期（Grace Period）

宽限期是 RCU 中最核心的概念。它保证了"所有在宽限期开始前已经开始的 RCU 读临界区都已经完成"：

```
时间轴：
  CPU 0:  [[RCU读临界区]]
  CPU 1:  [[RCU读临界区]]
  CPU 2:                          synchronize_rcu() 返回
  ───────────────┼─────────────────┼──────────────►
                 开始宽限期         宽限期结束（所有读者退出）
```

写者在 `synchronize_rcu()` 返回后，才能安全地释放旧数据。

### 1.2 静止状态（Quiescent State，QS）

静止状态是 RCU 检测"读者已完成"的手段。一个 CPU 的静止状态意味着该 CPU 上当前**没有正在执行的 RCU 读临界区**。

静止状态的类型：
- 用户态执行（user mode）—— 不在内核中，不会持有 rcu_read_lock
- idle 循环 —— CPU 空闲，无读者
- 上下文切换 —— 进程调度，读者必然已退出
- 在 PREEMPT_RCU 下，显式的 rcu_read_unlock()

### 1.3 grace period 的检测

每个 CPU 的 tick（定时器中断）中通过调度时钟中断检查是否需要报告 QS。实际路径：

```
update_process_times()
  → rcu_sched_clock_irq(user)
    → rcu_flavor_sched_clock_irq(user)
      → 如果 user==true → 标记 QS → rcu_report_qs_rdp()
```

---

## 2. 数据结构

### 2.1 struct rcu_head —— 回调节点

```c
// include/linux/types.h:254
struct callback_head {
    struct callback_head *next;            /* 链表指针 */
    void (*func)(struct callback_head *head); /* 回调函数 */
} __attribute__((aligned(sizeof(void *))));
#define rcu_head callback_head
```

`rcu_head` 嵌入在需要被 RCU 延迟释放的结构体中，通过 `call_rcu()` 入队，在宽限期结束后调用 `func`。

### 2.2 struct rcu_node —— 树节点

```c
// kernel/rcu/tree.h:41
struct rcu_node {
    raw_spinlock_t __private lock;       /* 保护本节点的自旋锁 */
    unsigned long gp_seq;                /* 本节点跟踪的 GP 序列号 */
    unsigned long gp_seq_needed;         /* 未来需要的 GP 序列号 */
    unsigned long completedqs;           /* 本节点所有 QS 已完成 */
    unsigned long qsmask;                /* 哪些子节点/CPU 尚未报告 QS */
    unsigned long qsmaskinit;            /* 本 GP 初始 qsmask */
    unsigned long qsmaskinitnext;        /* 下个 GP 的 qsmask 初始值 */
    unsigned long grpmask;               /* 向父节点报告的掩码（仅一位）*/
    int  grplo;                          /* 本节点覆盖的最小 CPU 号 */
    int  grphi;                          /* 本节点覆盖的最大 CPU 号 */
    u8   grpnum;                         /* 本节点在父节点中的组号 */
    u8   level;                          /* 层级（0=根） */
    struct rcu_node *parent;             /* 父节点指针 */
    struct list_head blkd_tasks;         /* 阻塞当前 GP 的任务链表 */
    struct list_head *gp_tasks;          /* 阻塞当前 GP 的第一个任务 */
    /* ... 更多字段用于 boost、expedited 等 */
} ____cacheline_internodealigned_in_smp;
```

每个 `rcu_node` 代表树形拓扑中的一个节点，覆盖一组连续的 CPU。叶子节点直接对应单个 CPU（由 `rcu_data` 管理）。`qsmask` 中的位表示哪些子节点（或 CPU）还没有报告 QS。

### 2.3 struct rcu_data —— 每 CPU 数据

```c
// kernel/rcu/tree.h:189
struct rcu_data {
    /* 1) quiescent-state and grace-period handling */
    unsigned long gp_seq;                /* 跟踪 rcu_state.gp_seq */
    unsigned long gp_seq_needed;         /* 跟踪未来 GP 请求 */
    union rcu_noqs cpu_no_qs;            /* 此 CPU 尚未报告 QS */
    bool core_needs_qs;                  /* 此 CPU 需要报告 QS */
    bool beenonline;                     /* CPU 曾上线 */
    struct rcu_node *mynode;             /* 此 CPU 所属的叶子节点 */
    unsigned long grpmask;               /* 向叶子节点报告的掩码 */
    unsigned long ticks_this_gp;         /* 本 GP 中的 tick 数 */
    struct irq_work defer_qs_iw;         /* 延迟 QS 报告 */
    int defer_qs_pending;

    /* 2) batch handling */
    struct rcu_segcblist cblist;         /* 分段回调链表 */
    long qlen_last_fqs_check;
    unsigned long n_cbs_invoked;         /* 已执行的回调数 */
    unsigned long n_force_qs_snap;
    long blimit;                         /* 批处理上限 */

    /* 3) dynticks interface */
    int  watching_snap;
    bool rcu_need_heavy_qs;
    bool rcu_urgent_qs;
    /* ... 更多字段 */
    int cpu;
};
```

### 2.4 struct rcu_state —— 全局状态

```c
// kernel/rcu/tree.h:351
struct rcu_state {
    struct rcu_node node[NUM_RCU_NODES]; /* 树节点数组 */
    struct rcu_node *level[RCU_NUM_LVLS + 1]; /* 各层级索引 */
    unsigned long gp_seq;                /* GP 序列号 */
    struct task_struct *gp_kthread;      /* GP kthread */
    struct swait_queue_head gp_wq;       /* GP kthread 等待队列 */
    short gp_flags;                      /* GP 命令（INIT/FQS/OVLD）*/
    short gp_state;                      /* GP 状态机状态 */
    unsigned long jiffies_force_qs;      /* FQS 触发时间 */
    unsigned long n_force_qs;            /* FQS 调用次数 */
    unsigned long gp_start;              /* GP 开始时间 */
    unsigned long gp_activity;           /* GP kthread 活动时间 */
    /* synchronize_rcu() 相关 */
    struct llist_head srs_next;          /* synchronize_rcu 请求链表 */
    struct llist_node *srs_wait_tail;    /* 等待中的同步请求 */
    struct llist_node *srs_done_tail;    /* 已完成请求 */
    /* ... */
};
```

### 2.5 struct rcu_segcblist —— 分段回调链表

```c
// include/linux/rcu_segcblist.h:190
struct rcu_segcblist {
    struct rcu_head *head;                   /* 链表头 */
    struct rcu_head **tails[RCU_CBLIST_NSEGS]; /* 各段尾部指针（4段） */
    unsigned long gp_seq[RCU_CBLIST_NSEGS];  /* 各段关联的 GP 序号 */
    long len;                                /* 总长度 */
    long seglen[RCU_CBLIST_NSEGS];           /* 各段长度 */
    u8 flags;                                /* 状态标志 */
};
```

4 个段的含义（`include/linux/rcu_segcblist.h:36`）：

```c
// include/linux/rcu_segcblist.h:60
#define RCU_DONE_TAIL       0   /* GP 已完成，等待调用 */
#define RCU_WAIT_TAIL       1   /* 等待当前 GP 完成 */
#define RCU_NEXT_READY_TAIL 2   /* 下一个 GP 可以处理 */
#define RCU_NEXT_TAIL       3   /* 最新的回调（GP 未分配） */
#define RCU_CBLIST_NSEGS    4
```

```
链表示意：
 head → [DONE] → [WAIT] → [NEXT_READY] → [NEXT] → NULL
        ↑                ↑                ↑          ↑
        tails[0]         tails[1]         tails[2]   tails[3]
```

---

## 3. Tree RCU 的树形拓扑

```
小型系统（4 CPU）：
      根节点（level 0）
        /        \
    叶子节点    叶子节点
    (CPU 0-1)  (CPU 2-3)

大型系统（4096 CPU）：
        根节点（level 0）
        /        \
      节点        节点
     /    \      /    \
  叶子  叶子   叶子   叶子
  CPU   CPU    CPU    CPU
  0-7   8-15  16-23  24-31
```

**树形结构的优势**：宽限期检测从叶子到根传播，避免集中扫描所有 CPU。每个节点只需等待其子节点的 qsmask 全部清零。

```
QS 报告传播路径：
  CPU0 报告 QS → rcu_report_qs_rdp()
    → rcu_report_qs_rnp(mask, rnp_leaf, ...)
      → 清除 rnp_leaf->qsmask 中 CPU0 的位
      → 如果 rnp_leaf->qsmask == 0
        → 上报父节点 rcu_report_qs_rnp(mask, rnp_parent, ...)
          → 父节点清除对应位
          → 如果父节点 qsmask == 0
            → ... 直到根节点
              → rcu_report_qs_rsp() → GP 结束！
```

---

## 4. 读者侧源码

### 4.1 rcu_read_lock —— 非 PREEMPT 版本

当内核未配置 `CONFIG_PREEMPT_RCU` 时，`__rcu_read_lock()` 极其简单：

```c
// include/linux/rcupdate.h:101
static inline void __rcu_read_lock(void)
{
    preempt_disable();
}
```

### 4.2 rcu_read_lock —— PREEMPT_RCU 版本

```c
// kernel/rcu/tree_plugin.h:412
void __rcu_read_lock(void)
{
    rcu_preempt_read_enter();
    if (IS_ENABLED(CONFIG_PROVE_LOCKING))
        WARN_ON_ONCE(rcu_preempt_depth() > RCU_NEST_PMAX);
    if (IS_ENABLED(CONFIG_RCU_STRICT_GRACE_PERIOD) &&
        rcu_state.gp_kthread)
        WRITE_ONCE(current->rcu_read_unlock_special.b.need_qs, true);
    barrier();  /* critical section after entry code. */
}
EXPORT_SYMBOL_GPL(__rcu_read_lock);
```

`rcu_preempt_read_enter()` 递增 `current->rcu_read_lock_nesting`，标记当前任务进入了 RCU 读临界区。

### 4.3 rcu_read_lock() 包装宏

```c
// include/linux/rcupdate.h:833
static __always_inline void rcu_read_lock(void)
    __acquires_shared(RCU)
{
    __rcu_read_lock();
    __acquire_shared(RCU);
    rcu_lock_acquire(&rcu_lock_map);
    RCU_LOCKDEP_WARN(!rcu_is_watching(),
             "rcu_read_lock() used illegally while idle");
}
```

### 4.4 rcu_read_unlock —— 非 PREEMPT 版本

```c
// include/linux/rcupdate.h:106
static inline void __rcu_read_unlock(void)
{
    if (IS_ENABLED(CONFIG_RCU_STRICT_GRACE_PERIOD))
        rcu_read_unlock_strict();
    preempt_enable();
}
```

### 4.5 rcu_read_unlock —— PREEMPT_RCU 版本

```c
// kernel/rcu/tree_plugin.h:430
void __rcu_read_unlock(void)
{
    struct task_struct *t = current;

    barrier();  // critical section before exit code.
    if (rcu_preempt_read_exit() == 0) {
        barrier();  // critical-section exit before .s check.
        if (unlikely(READ_ONCE(t->rcu_read_unlock_special.s)))
            rcu_read_unlock_special(t);
    }
    if (IS_ENABLED(CONFIG_PROVE_LOCKING)) {
        int rrln = rcu_preempt_depth();
        WARN_ON_ONCE(rrln < 0 || rrln > RCU_NEST_PMAX);
    }
}
EXPORT_SYMBOL_GPL(__rcu_read_unlock);
```

`rcu_preempt_read_exit()` 递减 `rcu_read_lock_nesting`。当计数归零且 `rcu_read_unlock_special` 非零时（例如读者在临界区内被调度出去），调用 `rcu_read_unlock_special()` 处理抢占恢复。

### 4.6 rcu_read_unlock() 包装宏

```c
// include/linux/rcupdate.h:869
static inline void rcu_read_unlock(void)
    __releases_shared(RCU)
{
    RCU_LOCKDEP_WARN(!rcu_is_watching(),
             "rcu_read_unlock() used illegally while idle");
    rcu_lock_release(&rcu_lock_map);
    __release_shared(RCU);
    __rcu_read_unlock();
}
```

### 4.7 rcu_dereference

```c
// include/linux/rcupdate.h:740
#define rcu_dereference(p) rcu_dereference_check(p, 0)
```

展开后相当于 `READ_ONCE(p)` 加上屏障，保证编译器不重排，且读取操作不被撕裂。

---

## 5. synchronize_rcu 完整源码

`include/linux/rcupdate.h:51` 声明：

```c
void synchronize_rcu(void);
```

`kernel/rcu/tree.c:3349` 实现：

```c
void synchronize_rcu(void)
{
    unsigned long flags;
    struct rcu_node *rnp;

    RCU_LOCKDEP_WARN(lock_is_held(&rcu_bh_lock_map) ||
             lock_is_held(&rcu_lock_map) ||
             lock_is_held(&rcu_sched_lock_map),
             "Illegal synchronize_rcu() in RCU read-side critical section");
    if (!rcu_blocking_is_gp()) {
        if (rcu_gp_is_expedited())
            synchronize_rcu_expedited();
        else
            synchronize_rcu_normal();
        return;
    }
    // 早期启动阶段（SMP 不可用），宽限期是空洞的
    local_irq_save(flags);
    WARN_ON_ONCE(num_online_cpus() > 1);
    rcu_state.gp_seq += (1 << RCU_SEQ_CTR_SHIFT);
    for (rnp = this_cpu_ptr(&rcu_data)->mynode; rnp; rnp = rnp->parent)
        rnp->gp_seq_needed = rnp->gp_seq = rcu_state.gp_seq;
    local_irq_restore(flags);
}
EXPORT_SYMBOL_GPL(synchronize_rcu);
```

主要走 `synchronize_rcu_normal()` 路径（`kernel/rcu/tree.c:3277`）：

```c
static void synchronize_rcu_normal(void)
{
    struct rcu_synchronize rs;

    trace_rcu_sr_normal(rcu_state.name, &rs.head, TPS("request"));

    if (READ_ONCE(rcu_normal_wake_from_gp) < 1) {
        wait_rcu_gp(call_rcu_hurry);
        goto trace_complete_out;
    }

    init_rcu_head_on_stack(&rs.head);
    init_completion(&rs.completion);

    if (IS_ENABLED(CONFIG_PROVE_RCU))
        get_state_synchronize_rcu_full(&rs.oldstate);

    rcu_sr_normal_add_req(&rs);

    /* 触发 GP */
    (void) start_poll_synchronize_rcu();

    /* 阻塞等待 GP 完成 */
    wait_for_completion(&rs.completion);
    destroy_rcu_head_on_stack(&rs.head);

trace_complete_out:
    trace_rcu_sr_normal(rcu_state.name, &rs.head, TPS("complete"));
}
```

**数据流**：
1. 分配 `rcu_synchronize` 结构体（包含 completion）
2. 通过 `rcu_sr_normal_add_req()` 将请求加入 `rcu_state.srs_next` llist
3. 调用 `start_poll_synchronize_rcu()` 发起 GP 请求
4. 调用 `wait_for_completion()` 阻塞等待
5. GP kthread 完成后，通过 `rcu_sr_normal_gp_cleanup()` 遍历已完成的请求，调用 `complete()` 唤醒等待者

---

## 6. call_rcu 完整源码

`kernel/rcu/tree.c:3249`：

```c
void call_rcu(struct rcu_head *head, rcu_callback_t func)
{
    __call_rcu_common(head, func, enable_rcu_lazy);
}
EXPORT_SYMBOL_GPL(call_rcu);
```

`__call_rcu_common()`（`kernel/rcu/tree.c:3155`）：

```c
static void
__call_rcu_common(struct rcu_head *head, rcu_callback_t func, bool lazy_in)
{
    static atomic_t doublefrees;
    unsigned long flags;
    bool lazy;
    struct rcu_data *rdp;

    WARN_ON_ONCE((unsigned long)head & (sizeof(void *) - 1));
    if (WARN_ON_ONCE(!func))
        return;

    if (debug_rcu_head_queue(head)) {
        /* 重复 call_rcu 检测 */
        if (atomic_inc_return(&doublefrees) < 4) {
            pr_err("%s(): Double-freed CB %p->%pS()!!!  ",
                   __func__, head, head->func);
            mem_dump_obj(head);
        }
        WRITE_ONCE(head->func, rcu_leak_callback);
        return;
    }
    head->func = func;
    head->next = NULL;
    kasan_record_aux_stack(head);

    local_irq_save(flags);
    rdp = this_cpu_ptr(&rcu_data);

    lazy = lazy_in && !rcu_async_should_hurry();

    if (unlikely(!rcu_segcblist_is_enabled(&rdp->cblist))) {
        WARN_ON_ONCE(rcu_scheduler_active != RCU_SCHEDULER_INACTIVE);
        if (rcu_segcblist_empty(&rdp->cblist))
            rcu_segcblist_init(&rdp->cblist);
    }

    check_cb_ovld(rdp);

    if (unlikely(rcu_rdp_is_offloaded(rdp)))
        call_rcu_nocb(rdp, head, func, flags, lazy);
    else
        call_rcu_core(rdp, head, func, flags);
    local_irq_restore(flags);
}
```

### 6.1 call_rcu_core —— 核心入队逻辑

`kernel/rcu/tree.c:3009`：

```c
static void call_rcu_core(struct rcu_data *rdp, struct rcu_head *head,
              rcu_callback_t func, unsigned long flags)
{
    rcutree_enqueue(rdp, head, func);
    // 如果在扩展 QS 中，强制重新评估 RCU 空闲状态
    if (!rcu_is_watching())
        invoke_rcu_core();

    if (irqs_disabled_flags(flags) || cpu_is_offline(smp_processor_id()))
        return;

    // 回调堆积过多时，触发 FQS 或启动新 GP
    if (unlikely(rcu_segcblist_n_cbs(&rdp->cblist) >
             rdp->qlen_last_fqs_check + qhimark)) {
        note_gp_changes(rdp);

        if (!rcu_gp_in_progress()) {
            rcu_accelerate_cbs_unlocked(rdp->mynode, rdp);
        } else {
            rdp->blimit = DEFAULT_MAX_RCU_BLIMIT;
            if (READ_ONCE(rcu_state.n_force_qs) == rdp->n_force_qs_snap &&
                rcu_segcblist_first_pend_cb(&rdp->cblist) != head)
                rcu_force_quiescent_state();
            rdp->n_force_qs_snap = READ_ONCE(rcu_state.n_force_qs);
            rdp->qlen_last_fqs_check = rcu_segcblist_n_cbs(&rdp->cblist);
        }
    }
}
```

回调入队到 `rdp->cblist`（分段链表）后，`call_rcu_core()` 会触发 RCU 软中断（`raise_softirq(RCU_SOFTIRQ)`），最终回调在 `rcu_do_batch()` 中执行。

---

## 7. rcu_do_batch —— 回调执行

`kernel/rcu/tree.c:2540`：

```c
static void rcu_do_batch(struct rcu_data *rdp)
{
    long bl;
    long count = 0;
    int div;
    unsigned long flags;
    unsigned long jlimit;
    struct rcu_cblist rcl = RCU_CBLIST_INITIALIZER(rcl);
    struct rcu_head *rhp;
    long tlimit = 0;

    // 如果无可执行回调，直接返回
    if (!rcu_segcblist_ready_cbs(&rdp->cblist)) {
        trace_rcu_batch_start(rcu_state.name,
                  rcu_segcblist_n_cbs(&rdp->cblist), 0);
        trace_rcu_batch_end(rcu_state.name, 0,
                !rcu_segcblist_empty(&rdp->cblist),
                need_resched(), is_idle_task(current),
                rcu_is_callbacks_kthread(rdp));
        return;
    }

    rcu_nocb_lock_irqsave(rdp, flags);
    pending = rcu_segcblist_get_seglen(&rdp->cblist, RCU_DONE_TAIL);
    div = READ_ONCE(rcu_divisor);
    div = div < 0 ? 7 : div > sizeof(long) * 8 - 2 ?
          sizeof(long) * 8 - 2 : div;
    bl = max(rdp->blimit, pending >> div);

    // 时间限制检测
    if ((in_serving_softirq() ||
         rdp->rcu_cpu_kthread_status == RCU_KTHREAD_RUNNING) &&
        (IS_ENABLED(CONFIG_RCU_DOUBLE_CHECK_CB_TIME) ||
         unlikely(bl > 100))) {
        const long npj = NSEC_PER_SEC / HZ;
        long rrn = READ_ONCE(rcu_resched_ns);
        rrn = rrn < NSEC_PER_MSEC ? NSEC_PER_MSEC :
              rrn > NSEC_PER_SEC ? NSEC_PER_SEC : rrn;
        tlimit = local_clock() + rrn;
        jlimit = jiffies + (rrn + npj + 1) / npj;
        jlimit_check = true;
    }

    // 将 DONE 段的回调提取到临时链表
    rcu_segcblist_extract_done_cbs(&rdp->cblist, &rcl);
    rcu_nocb_unlock_irqrestore(rdp, flags);

    // 逐个执行回调
    tick_dep_set_task(current, TICK_DEP_BIT_RCU);
    rhp = rcu_cblist_dequeue(&rcl);

    for (; rhp; rhp = rcu_cblist_dequeue(&rcl)) {
        rcu_callback_t f;
        count++;
        debug_rcu_head_unqueue(rhp);

        rcu_lock_acquire(&rcu_callback_map);
        trace_rcu_invoke_callback(rcu_state.name, rhp);

        f = rhp->func;
        WRITE_ONCE(rhp->func, (rcu_callback_t)0L);
        f(rhp);  // ★ 实际执行回调！

        rcu_lock_release(&rcu_callback_map);

        // 批处理上限和 CPU 时间片控制
        if (in_serving_softirq()) {
            if (count >= bl && (need_resched() || !is_idle_task(current)))
                break;
            /* 时间限制检查 */
        }
    }
    /* 剩余回调重新入队或唤醒 */
}
```

---

## 8. GP kthread 状态机 —— rcu_gp_kthread

`kernel/rcu/tree.c:2271`：

```c
static int __noreturn rcu_gp_kthread(void *unused)
{
    rcu_bind_gp_kthread();
    for (;;) {

        /* [Phase 1] 等待并启动 GP */
        for (;;) {
            trace_rcu_grace_period(rcu_state.name, rcu_state.gp_seq,
                           TPS("reqwait"));
            WRITE_ONCE(rcu_state.gp_state, RCU_GP_WAIT_GPS);
            swait_event_idle_exclusive(rcu_state.gp_wq,
                     READ_ONCE(rcu_state.gp_flags) &
                     RCU_GP_FLAG_INIT);
            rcu_gp_torture_wait();
            WRITE_ONCE(rcu_state.gp_state, RCU_GP_DONE_GPS);
            if (rcu_gp_init())
                break;
            cond_resched_tasks_rcu_qs();
            WRITE_ONCE(rcu_state.gp_activity, jiffies);
            WARN_ON(signal_pending(current));
            trace_rcu_grace_period(rcu_state.name, rcu_state.gp_seq,
                           TPS("reqwaitsig"));
        }

        /* [Phase 2] FQS 循环 —— 等待所有 CPU 报告 QS */
        rcu_gp_fqs_loop();

        /* [Phase 3] GP 结束清理 */
        WRITE_ONCE(rcu_state.gp_state, RCU_GP_CLEANUP);
        rcu_gp_cleanup();
        WRITE_ONCE(rcu_state.gp_state, RCU_GP_CLEANED);
    }
}
```

### 8.1 rcu_gp_init —— GP 初始化

`kernel/rcu/tree.c:1804`：

```c
static noinline_for_stack bool rcu_gp_init(void)
{
    unsigned long flags;
    unsigned long oldmask;
    unsigned long mask;
    struct rcu_data *rdp;
    struct rcu_node *rnp = rcu_get_root();
    bool start_new_poll;
    unsigned long old_gp_seq;

    WRITE_ONCE(rcu_state.gp_activity, jiffies);
    raw_spin_lock_irq_rcu_node(rnp);
    if (!rcu_state.gp_flags) {
        raw_spin_unlock_irq_rcu_node(rnp);
        return false;  // 无 GP 请求
    }
    WRITE_ONCE(rcu_state.gp_flags, 0);  // 清除所有标志：新 GP

    if (WARN_ON_ONCE(rcu_gp_in_progress())) {
        raw_spin_unlock_irq_rcu_node(rnp);
        return false;  // GP 已经在进行中
    }

    /* 初始化同步请求段 */
    start_new_poll = rcu_sr_normal_gp_init();
    old_gp_seq = rcu_state.gp_seq;
    rcu_seq_start(&rcu_state.gp_seq);  // GP 序列号 +1

    trace_rcu_grace_period(rcu_state.name, rcu_state.gp_seq, TPS("start"));
    rcu_poll_gp_seq_start(&rcu_state.gp_seq_polled_snap);
    raw_spin_unlock_irq_rcu_node(rnp);

    /* 处理 CPU 热插拔 */
    WRITE_ONCE(rcu_state.gp_state, RCU_GP_ONOFF);
    rcu_for_each_leaf_node(rnp) {
        local_irq_disable();
        arch_spin_lock(&rcu_state.ofl_lock);
        raw_spin_lock_rcu_node(rnp);
        if (rnp->qsmaskinit == rnp->qsmaskinitnext &&
            !rnp->wait_blkd_tasks) {
            raw_spin_unlock_rcu_node(rnp);
            arch_spin_unlock(&rcu_state.ofl_lock);
            local_irq_enable();
            continue;
        }
        oldmask = rnp->qsmaskinit;
        rnp->qsmaskinit = rnp->qsmaskinitnext;

        if (!oldmask != !rnp->qsmaskinit) {
            if (!oldmask)
                rcu_init_new_rnp(rnp);
            else if (rcu_preempt_has_tasks(rnp))
                rnp->wait_blkd_tasks = true;
            else
                rcu_cleanup_dead_rnp(rnp);
        }
        /* 处理 wait_blkd_tasks */
        raw_spin_unlock_rcu_node(rnp);
        arch_spin_unlock(&rcu_state.ofl_lock);
        local_irq_enable();
    }

    /* 初始化 qsmask */
    WRITE_ONCE(rcu_state.gp_state, RCU_GP_INIT);
    rcu_for_each_node_breadth_first(rnp) {
        raw_spin_lock_irqsave_rcu_node(rnp, flags);
        rdp = this_cpu_ptr(&rcu_data);
        rcu_preempt_check_blocked_tasks(rnp);
        rnp->qsmask = rnp->qsmaskinit;
        WRITE_ONCE(rnp->gp_seq, rcu_state.gp_seq);
        if (rnp == rdp->mynode)
            (void)__note_gp_changes(rnp, rdp);
        rcu_preempt_boost_start_gp(rnp);
        trace_rcu_grace_period_init(rcu_state.name, rnp->gp_seq,
                    rnp->level, rnp->grplo,
                    rnp->grphi, rnp->qsmask);
        /* 处理已离线 CPU 的 QS */
        mask = rnp->qsmask & ~rnp->qsmaskinitnext;
        rnp->rcu_gp_init_mask = mask;
        if ((mask || rnp->wait_blkd_tasks) && rcu_is_leaf_node(rnp))
            rcu_report_qs_rnp(mask, rnp, rnp->gp_seq, flags);
        else
            raw_spin_unlock_irq_rcu_node(rnp);
        cond_resched_tasks_rcu_qs();
        WRITE_ONCE(rcu_state.gp_activity, jiffies);
    }

    /* GP kthread 自身立即报告 QS */
    preempt_disable();
    rcu_qs();
    rcu_report_qs_rdp(this_cpu_ptr(&rcu_data));
    preempt_enable();

    return true;
}
```

### 8.2 rcu_gp_fqs_loop —— FQS 循环

`kernel/rcu/tree.c:2064`：

```c
static noinline_for_stack void rcu_gp_fqs_loop(void)
{
    bool first_gp_fqs = true;
    int gf = 0;
    unsigned long j;
    int ret;
    struct rcu_node *rnp = rcu_get_root();

    j = READ_ONCE(jiffies_till_first_fqs);
    if (rcu_state.cbovld)
        gf = RCU_GP_FLAG_OVLD;
    ret = 0;
    for (;;) {
        if (rcu_state.cbovld) {
            j = (j + 2) / 3;  // 回调过载时缩短间隔
            if (j <= 0)
                j = 1;
        }
        if (!ret || time_before(jiffies + j, rcu_state.jiffies_force_qs)) {
            WRITE_ONCE(rcu_state.jiffies_force_qs, jiffies + j);
        }
        trace_rcu_grace_period(rcu_state.name, rcu_state.gp_seq,
                       TPS("fqswait"));
        WRITE_ONCE(rcu_state.gp_state, RCU_GP_WAIT_FQS);
        (void)swait_event_idle_timeout_exclusive(rcu_state.gp_wq,
                 rcu_gp_fqs_check_wake(&gf), j);
        WRITE_ONCE(rcu_state.gp_state, RCU_GP_DOING_FQS);

        // 检查是否所有 CPU 都报告了 QS
        if (!READ_ONCE(rnp->qsmask) &&
            !rcu_preempt_blocked_readers_cgp(rnp))
            break;

        // 执行 FQS 扫描
        if (!time_after(rcu_state.jiffies_force_qs, jiffies) ||
            (gf & (RCU_GP_FLAG_FQS | RCU_GP_FLAG_OVLD))) {
            trace_rcu_grace_period(rcu_state.name, rcu_state.gp_seq,
                           TPS("fqsstart"));
            rcu_gp_fqs(first_gp_fqs);
            gf = 0;
            if (first_gp_fqs) {
                first_gp_fqs = false;
                gf = rcu_state.cbovld ? RCU_GP_FLAG_OVLD : 0;
            }
            trace_rcu_grace_period(rcu_state.name, rcu_state.gp_seq,
                           TPS("fqsend"));
            ret = 0;
            j = READ_ONCE(jiffies_till_next_fqs);
        } else {
            cond_resched_tasks_rcu_qs();
            WRITE_ONCE(rcu_state.gp_activity, jiffies);
            WARN_ON(signal_pending(current));
            ret = 1;
            j = jiffies;
        }
    }
}
```

### 8.3 rcu_gp_fqs —— 强制 QS

`kernel/rcu/tree.c:2028`：

```c
static void rcu_gp_fqs(bool first_time)
{
    int nr_fqs = READ_ONCE(rcu_state.nr_fqs_jiffies_stall);
    struct rcu_node *rnp = rcu_get_root();

    WRITE_ONCE(rcu_state.gp_activity, jiffies);
    WRITE_ONCE(rcu_state.n_force_qs, rcu_state.n_force_qs + 1);

    WARN_ON_ONCE(nr_fqs > 3);
    if (nr_fqs) {
        if (nr_fqs == 1) {
            WRITE_ONCE(rcu_state.jiffies_stall,
                   jiffies + rcu_jiffies_till_stall_check());
        }
        WRITE_ONCE(rcu_state.nr_fqs_jiffies_stall, --nr_fqs);
    }

    if (first_time) {
        /* 首次：采集 dyntick-idle 快照 */
        force_qs_rnp(rcu_watching_snap_save);
    } else {
        /* 后续：检查 dyntick-idle 和离线 CPU */
        force_qs_rnp(rcu_watching_snap_recheck);
    }

    if (READ_ONCE(rcu_state.gp_flags) & RCU_GP_FLAG_FQS) {
        raw_spin_lock_irq_rcu_node(rnp);
        WRITE_ONCE(rcu_state.gp_flags,
               rcu_state.gp_flags & ~RCU_GP_FLAG_FQS);
        raw_spin_unlock_irq_rcu_node(rnp);
    }
}
```

### 8.4 rcu_gp_cleanup —— GP 结束清理

`kernel/rcu/tree.c:1703`：

```c
static void rcu_sr_normal_gp_cleanup(void)
{
    struct llist_node *wait_tail, *next = NULL, *rcu = NULL;
    int done = 0;

    wait_tail = rcu_state.srs_wait_tail;
    if (wait_tail == NULL)
        return;

    rcu_state.srs_wait_tail = NULL;

    /* 遍历已完成等待段的 synchronize_rcu() 请求 */
    llist_for_each_safe(rcu, next, wait_tail->next) {
        if (rcu_sr_is_wait_head(rcu))
            break;

        rcu_sr_normal_complete(rcu);  // complete() 唤醒等待者！
        wait_tail->next = next;

        if (++done == SR_MAX_USERS_WAKE_FROM_GP)
            break;
    }

    /* 如果还有未处理完的请求，调度 cleanup_work */
    if (wait_tail->next) {
        atomic_inc(&rcu_state.srs_cleanups_pending);
        if (!queue_work(sync_wq, &rcu_state.srs_cleanup_work))
            atomic_dec(&rcu_state.srs_cleanups_pending);
    }
}
```

---

## 9. QS 报告路径

### 9.1 rcu_report_qs_rnp —— 树内传播

`kernel/rcu/tree.c:2339`：

```c
static void rcu_report_qs_rnp(unsigned long mask, struct rcu_node *rnp,
                  unsigned long gps, unsigned long flags)
    __releases(rnp->lock)
{
    unsigned long oldmask = 0;
    struct rcu_node *rnp_c;

    raw_lockdep_assert_held_rcu_node(rnp);

    /* 沿树向上传播 */
    for (;;) {
        if ((!(rnp->qsmask & mask) && mask) || rnp->gp_seq != gps) {
            /* 位已清除或 GP 已结束 */
            raw_spin_unlock_irqrestore_rcu_node(rnp, flags);
            return;
        }
        WRITE_ONCE(rnp->qsmask, rnp->qsmask & ~mask);
        trace_rcu_quiescent_state_report(rcu_state.name, rnp->gp_seq,
                         mask, rnp->qsmask, rnp->level, ...);

        if (rnp->qsmask != 0 ||
            rcu_preempt_blocked_readers_cgp(rnp)) {
            /* 还有位未清除，停留在此层级 */
            raw_spin_unlock_irqrestore_rcu_node(rnp, flags);
            return;
        }

        rnp->completedqs = rnp->gp_seq;
        mask = rnp->grpmask;
        if (rnp->parent == NULL) {
            /* 到达根节点 —— GP 可结束 */
            break;
        }
        raw_spin_unlock_irqrestore_rcu_node(rnp, flags);
        rnp_c = rnp;
        rnp = rnp->parent;
        raw_spin_lock_irqsave_rcu_node(rnp, flags);
        oldmask = READ_ONCE(rnp_c->qsmask);
    }

    /* 最后 CPU 报告 QS —— GP 结束 */
    rcu_report_qs_rsp(flags);  // 释放 rnp->lock
}
```

### 9.2 rcu_report_qs_rdp —— 每 CPU 入口

`kernel/rcu/tree.c:2443`：

```c
static void
rcu_report_qs_rdp(struct rcu_data *rdp)
{
    unsigned long flags;
    unsigned long mask;
    struct rcu_node *rnp;

    WARN_ON_ONCE(rdp->cpu != smp_processor_id());
    rnp = rdp->mynode;
    raw_spin_lock_irqsave_rcu_node(rnp, flags);
    if (rdp->cpu_no_qs.b.norm || rdp->gp_seq != rnp->gp_seq ||
        rdp->gpwrap) {
        /* GP 已结束或需要新 QS */
        rdp->cpu_no_qs.b.norm = true;
        raw_spin_unlock_irqrestore_rcu_node(rnp, flags);
        return;
    }
    mask = rdp->grpmask;
    rdp->core_needs_qs = false;
    if ((rnp->qsmask & mask) == 0) {
        raw_spin_unlock_irqrestore_rcu_node(rnp, flags);
    } else {
        if (!rcu_rdp_is_offloaded(rdp)) {
            WARN_ON_ONCE(rcu_accelerate_cbs(rnp, rdp));
        }
        rcu_disable_urgency_upon_qs(rdp);
        rcu_report_qs_rnp(mask, rnp, rnp->gp_seq, flags);
        /* ^^^ released rnp->lock */
    }
}
```

---

## 10. 完整的 synchronize_rcu 数据流

```
synchronize_rcu()
  │
  ├─ synchronize_rcu_normal()                     [tree.c:3277]
  │   │
  │   ├─ init_rcu_head_on_stack(&rs.head)        分配栈上的 rcu_synchronize
  │   ├─ init_completion(&rs.completion)          初始化 completion
  │   ├─ rcu_sr_normal_add_req(&rs)              加入 srs_next llist
  │   │   └─ llist_add(&rs->head, &rcu_state.srs_next)
  │   │
  │   ├─ start_poll_synchronize_rcu()             触发 GP 请求
  │   │   └─ rcu_state.gp_flags |= RCU_GP_FLAG_INIT
  │   │   └─ rcu_gp_kthread_wake()               唤醒 GP kthread
  │   │       └─ swait_event_idle_exclusive(gp_wq, ...)
  │   │
  │   ├─ wait_for_completion(&rs.completion)     阻塞等待
  │   │
  │   └─ [GP 结束后被唤醒，返回]
  │
  │   ┌─ GP kthread (rcu_gp_kthread)              [tree.c:2271]
  │   │   │
  │   │   ├─ [Phase 1] 启动 GP
  │   │   │   └─ rcu_gp_init()                    [tree.c:1804]
  │   │   │       ├─ 设置 gp_seq += 2
  │   │   │       ├─ rcu_sr_normal_gp_init()     插入等待段分隔符
  │   │   │       ├─ 处理 CPU 热插拔
  │   │   │       ├─ 初始化所有 rcu_node->qsmask
  │   │   │       └─ GP kthread 自身报告 QS
  │   │   │
  │   │   ├─ [Phase 2] FQS 循环
  │   │   │   └─ rcu_gp_fqs_loop()                [tree.c:2064]
  │   │   │       ├─ 定时超时等待
  │   │   │       └─ rcu_gp_fqs()                 [tree.c:2028]
  │   │   │           ├─ force_qs_rnp() (首次：采集快照)
  │   │   │           └─ force_qs_rnp() (后续：重检)
  │   │   │
  │   │   ├─ [所有 CPU 报告 QS] → 根节点 qsmask==0
  │   │   │
  │   │   └─ [Phase 3] GP 结束
  │   │       └─ rcu_gp_cleanup()
  │   │           └─ rcu_sr_normal_gp_cleanup()   [tree.c:1703]
  │   │               ├─ 遍历 srs_wait_tail 链表
  │   │               ├─ rcu_sr_normal_complete() 逐个调用 complete()
  │   │               │   └─ complete(&rs->completion) → 唤醒 synchronize_rcu()
  │   │               └─ [剩余请求] → queue_work(srs_cleanup_work)
  │   │
  │   ▼
  synchronize_rcu() 返回 → 可安全释放旧指针！
```

### QS 报告路径（CPU tick 触发）

```
CPU 进入 user/idle 或上下文切换
  │
  ├─ rcu_sched_clock_irq(user)
  │   └─ rcu_flavor_sched_clock_irq(user)
  │       └─ 如果 user==true：
  │           ├─ rcu_qs()                         标记本地 QS
  │           └─ rcu_report_qs_rdp(rdp)           [tree.c:2443]
  │               ├─ 检查 gp_seq 是否匹配
  │               ├─ 清除 rdp->core_needs_qs
  │               ├─ 清除叶子节点 qsmask 中本 CPU 的位
  │               └─ rcu_report_qs_rnp(mask, rnp) [tree.c:2339]
  │                   │
  │                   └─ [向父节点递归传播]
  │                       ├─ 当前节点 qsmask 全部清除？
  │                       │   ├─ 否 → 返回（等待其他子节点）
  │                       │   └─ 是 → 向父节点报告
  │                       └─ 到达根节点且 qsmask==0？
  │                           └─ rcu_report_qs_rsp()
  │                               → GP 结束！
  │                               → 唤醒 rcu_gp_kthread() 进入清理阶段
```

---

## 11. RCU 变体

| 变体 | 读者限制 | 宽限期含义 | 使用场景 |
|------|---------|-----------|---------|
| Classic RCU | 不可抢占/休眠 | 所有 CPU 的 QS | 通用 |
| PREEMPT RCU | 可被抢占（仍不可休眠） | 所有在线 CPU 的 QS | PREEMPT 内核 |
| SRCU | **可休眠！** | 所有 CPU + 显式 srcu_read_unlock | 可休眠读路径 |
| Tasks RCU | 内核线程/任务 | 所有任务上下文切换 | trampoline 卸载 |
| Tiny RCU | UP 系统 | 简化实现 | 嵌入式 |

### 11.1 SRCU（Sleepable RCU）

SRCU 读者可以休眠，使用一组 per-CPU 计数器：

```c
// SRCU 读者路径：
idx = srcu_read_lock(&ss);    // 递增 per-CPU 计数器
ptr = rcu_dereference(gbl_ptr);
data = ptr->data;
// ... 可以在临界区内休眠！
srcu_read_unlock(&ss, idx);   // 递减 per-CPU 计数器

// SRCU 写者路径：
synchronize_srcu(&ss);        // 等待所有 SRCU 读者完成
```

SRCU 通过在每个 CPU 上维护两个计数器（`srcu_data`）来实现可休眠的读临界区。宽限期检测需要扫描所有 CPU 的两个计数器。

### 11.2 Tasks RCU

Tasks RCU 用于跟踪内核线程/任务的运行状态，主要用于函数跳转（ftrace 的 `ftrace_modify_all_code`）。它等待所有任务经历一次上下文切换，确保没有任务正在执行被追踪的代码。

---

## 12. RCU 的软中断处理

```c
// kernel/rcu/tree.c:2869 — RCU_SOFTIRQ 的处理函数
static void rcu_core_si(void)
{
    struct rcu_data *rdp = this_cpu_ptr(&rcu_data);

    if (IS_ENABLED(CONFIG_RCU_NOCB_CPU) && rcu_rdp_is_offloaded(rdp))
        return;  // NOCB 模式由专用 kthread 处理
    rcu_do_batch(rdp);  // 执行已完成 GP 的回调
}

// tree.c:4887 — RCU_SOFTIRQ 注册
open_softirq(RCU_SOFTIRQ, rcu_core_si);
```

---

## 13. RCU 链表操作

```c
// include/linux/rculist.h — RCU 安全的链表操作

// RCU 遍历（读者）：
rcu_read_lock();
list_for_each_entry_rcu(pos, &head, member) {
    // pos 可能正在被写者替换
    // 但能保证要么看到旧值，要么看到新值
}
rcu_read_unlock();

// RCU 替换（写者）：
new = kmalloc(sizeof(*new), GFP_KERNEL);
*new = *old;
new->data = val;
list_replace_rcu(&old->list, &new->list);  // 原子替换
synchronize_rcu();                          // 等待读者退出
kfree(old);                                 // 安全释放
```

---

## 14. 性能对比

| 操作 | 延迟 | 说明 |
|------|------|------|
| `rcu_read_lock` (非 PREEMPT) | ~1ns | `preempt_disable()` 或 `barrier()` |
| `rcu_read_lock` (PREEMPT) | ~10ns | `preempt_disable` + 跟踪 |
| `rcu_dereference` | ~5ns | `READ_ONCE` + 编译器屏障 |
| `synchronize_rcu` | ~10-100μs | 等待所有 CPU 的 QS |
| `call_rcu` | ~100ns | 链表操作 + `raise_softirq` |
| SRCU read_lock | ~20ns | per-CPU 计数器操作 |
| 自旋锁读 | ~20ns + 竞争成本 | CAS (`xchg`) |

---

## 15. RCU 与 tickless idle

```c
// kernel/rcu/tree.c / tree_plugin.h
// 当 CPU 进入 idle 不再产生 tick 时：
// → rcu_dynticks 计数器递增，标记 CPU 处于 EQS
// → 在 EQS 中，RCU 认为该 CPU 持续处于 QS 状态
// → 退出 idle 时递减计数器，恢复 tick 检测
```

在 FQS 循环中，`rcu_gp_fqs()` 通过 `force_qs_rnp(rcu_watching_snap_save)` 采集 dyntick-idle 快照；后续调用 `force_qs_rnp(rcu_watching_snap_recheck)` 检查快照是否有变化，推断 CPU 是否离开 idle。

---

## 16. RCU 的 CPU 热插拔

```c
// kernel/rcu/tree.c — CPU 热插拔处理

int rcutree_prepare_cpu(unsigned int cpu)
{
    struct rcu_data *rdp = per_cpu_ptr(&rcu_data, cpu);
    rdp->gp_seq = rcu_state.gp_seq;
    rdp->cpu_no_qs.b.norm = true;
    rdp->core_needs_qs = true;
    return 0;
}

int rcutree_dead_cpu(unsigned int cpu)
{
    // CPU 下线时迁移其回调到其他 CPU
    rcu_boost_kthread_setaffinity(rdp->mynode, -1);
    return 0;
}
```

`rcu_gp_init()` 中的 RCU_GP_ONOFF 阶段处理离线 CPU 的 qsmask 调整，确保离线 CPU 不被宽限期等待。

---

## 17. RCU 的调试和跟踪

```bash
# 查看 RCU 状态
cat /proc/rcu/rcu_pending  # 每 CPU 的 RCU 统计
cat /proc/rcu/rcu_sched    # RCU 状态摘要

# 使用 tracepoint 跟踪 RCU
echo 1 > /sys/kernel/debug/tracing/events/rcu/enable
cat /sys/kernel/debug/tracing/trace

# CONFIG_RCU_TRACE 使能后：
# /sys/kernel/debug/rcu/ 目录包含详细统计
```

---

## 18. gp_state 状态值汇总

```c
// kernel/rcu/tree.h:442
#define RCU_GP_IDLE       0   /* 初始状态，无 GP 在进行 */
#define RCU_GP_WAIT_GPS   1   /* 等待 GP 启动条件就绪 */
#define RCU_GP_DONE_GPS   2   /* GP 启动条件就绪 */
#define RCU_GP_ONOFF      3   /* CPU 热插拔处理中 */
#define RCU_GP_INIT       4   /* qsmask 初始化中 */
#define RCU_GP_WAIT_FQS   5   /* 等待 FQS 触发时机 */
#define RCU_GP_DOING_FQS  6   /* 正在执行 FQS 扫描 */
#define RCU_GP_CLEANUP    7   /* GP 清理中 */
#define RCU_GP_CLEANED    8   /* GP 清理完成 */
```

```c
// kernel/rcu/tree.h:438
#define RCU_GP_FLAG_INIT 0x1  /* 需要 GP 初始化 */
#define RCU_GP_FLAG_FQS  0x2  /* 需要 FQS 强制 QS */
#define RCU_GP_FLAG_OVLD 0x4  /* 回调过载 */
```

---

## 19. RCU 阅读建议

| 概念 | 难度 | 建议阅读 |
|------|------|---------|
| `rcu_read_lock`/`rcu_dereference` | 简单 | `include/linux/rcupdate.h` |
| `synchronize_rcu` | 中等 | `kernel/rcu/tree.c:3349` |
| Tree RCU 整体框架 | 困难 | `kernel/rcu/tree.c` — `rcu_gp_kthread()` 开始 |
| Grace Period 初始化 | 困难 | `kernel/rcu/tree.c:1804` — `rcu_gp_init()` |
| QS 报告传播 | 中等 | `kernel/rcu/tree.c:2339` — `rcu_report_qs_rnp()` |
| `call_rcu` + 回调执行 | 中等 | `kernel/rcu/tree.c:3249` + `rcu_do_batch()` |
| SRCU | 中等 | `kernel/rcu/srcu.c` |
| Tasks RCU | 中等 | `kernel/rcu/tasks.h` |
| RCU 链表 | 中等 | `include/linux/rculist.h` |
| 分段回调链表 | 中等 | `include/linux/rcu_segcblist.h` |

---

## 20. 总结

RCU 是 Linux 内核中性能最高的读者-写者同步机制。读者路径仅需两条指令（`rcu_read_lock`/`unlock` = `preempt_disable`/`enable` + `barrier`），完全无原子操作和缓存行 bouncing。写者通过创建副本 + 原子指针替换（`rcu_assign_pointer` = `smp_store_release`）+ 延迟回收（宽限期）来保证一致性。

**RCU 的核心三者**：
1. **读者路径**：极快，无锁，无原子操作
2. **宽限期机制**：由 `rcu_gp_kthread` 状态机驱动，分 GP 初始化 → FQS 循环 → GP 清理 三个阶段
3. **回调执行**：`call_rcu` 入队 → GP 完成 → `rcu_do_batch` 执行

**宽限期的本质**：`synchronize_rcu()` 等待的不是"时间"，而是"所有在宽限期开始前已进入 RCU 读临界区的读者已经退出"这一事实。这是通过等待所有 CPU 报告 QS（QUIESCENT STATE）来保证的。

Tree RCU 通过 `rcu_node` 树形结构将 QS 检测从 O(n) 优化为 O(log n)，使 RCU 能够扩展到数千个 CPU 的大型系统。

---

## 源码文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/types.h:254` | `struct rcu_head` 定义 |
| `include/linux/rcupdate.h:51` | `call_rcu()` 声明 |
| `include/linux/rcupdate.h:82-83` | `__rcu_read_lock/unlock` 声明 |
| `include/linux/rcupdate.h:101` | `__rcu_read_lock` (非PREEMPT) |
| `include/linux/rcupdate.h:833` | `rcu_read_lock()` 包装 |
| `include/linux/rcupdate.h:869` | `rcu_read_unlock()` 包装 |
| `include/linux/rcu_segcblist.h:34` | 分段链表段定义说明 |
| `include/linux/rcu_segcblist.h:190` | `struct rcu_segcblist` |
| `kernel/rcu/tree.h:41` | `struct rcu_node` |
| `kernel/rcu/tree.h:189` | `struct rcu_data` |
| `kernel/rcu/tree.h:351` | `struct rcu_state` |
| `kernel/rcu/tree.h:438` | `gp_flags` 定义 |
| `kernel/rcu/tree.h:442` | `gp_state` 定义 |
| `kernel/rcu/tree.c:1703` | `rcu_sr_normal_gp_cleanup()` |
| `kernel/rcu/tree.c:1804` | `rcu_gp_init()` |
| `kernel/rcu/tree.c:2028` | `rcu_gp_fqs()` |
| `kernel/rcu/tree.c:2064` | `rcu_gp_fqs_loop()` |
| `kernel/rcu/tree.c:2271` | `rcu_gp_kthread()` |
| `kernel/rcu/tree.c:2339` | `rcu_report_qs_rnp()` |
| `kernel/rcu/tree.c:2443` | `rcu_report_qs_rdp()` |
| `kernel/rcu/tree.c:2540` | `rcu_do_batch()` |
| `kernel/rcu/tree.c:3009` | `call_rcu_core()` |
| `kernel/rcu/tree.c:3155` | `__call_rcu_common()` |
| `kernel/rcu/tree.c:3249` | `call_rcu()` |
| `kernel/rcu/tree.c:3277` | `synchronize_rcu_normal()` |
| `kernel/rcu/tree.c:3349` | `synchronize_rcu()` |
| `kernel/rcu/tree_plugin.h:412` | `__rcu_read_lock()` (PREEMPT) |
| `kernel/rcu/tree_plugin.h:430` | `__rcu_read_unlock()` (PREEMPT) |

---

*分析工具：doom-lsp（clangd LSP 19.x）| 分析日期：2026-05-06 | 内核版本：Linux 7.0.8 | 源码路径：`/home/dev/code/linux`*
