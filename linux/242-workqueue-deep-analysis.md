# workqueue 机制深度分析

> 基于 Linux 7.0-rc1 (kernel/workqueue.c, include/linux/workqueue.h)

---

## 概述

workqueue 是 Linux 内核最核心的异步工作执行机制。其设计哲学是**将"要执行的工作"（work_struct）和"谁来执行"（worker）解耦**：调用者只管提交 work，内核保证在某个上下文中执行它。理解 workqueue 的关键，是掌握三条链的交织：

- **work → pwq → worker_pool** 的映射链
- **worker_pool → idle 链表 / busy_hash → worker_thread** 的认领链
- **manager 线程 → maybe_create_worker → 新 worker** 的创建链

---

## 一、工作线程创建串联

### 1.1 从 `alloc_workqueue` 到 worker pool 的建立

```
alloc_workqueue("events", WQ_PERCPU, 0)
  └── __alloc_workqueue()
        ├── alloc_workqueue_attrs_noprof()      [仅 WQ_UNBOUND]
        ├── alloc_and_link_pwqs(wq)             [关键]
        ├── wq_adjust_max_active(wq)
        └── init_rescuer(wq)                   [仅 WQ_MEM_RECLAIM]
```

**对于 WQ_PERCPU（system_wq）**，每个 CPU 拥有固定的两个 `worker_pool`：

```c
// kernel/workqueue.c:504
static DEFINE_PER_CPU_SHARED_ALIGNED(struct worker_pool [NR_STD_WORKER_POOLS],
                                     cpu_worker_pools);
// NR_STD_WORKER_POOLS = 2：index 0 = 普通优先级，index 1 = 高优先级
```

`alloc_and_link_pwqs` 为每个 CPU 创建一个 `pool_workqueue`，指向 `cpu_worker_pools[cpu][highpri]`：

```
wq->cpu_pwq (per-CPU pointer array)
  ├── cpu[0] ──→ pwq ──→ worker_pool(cpu=0, highpri=0)  ← worker 在此 pool 上被创建
  ├── cpu[1] ──→ pwq ──→ worker_pool(cpu=1, highpri=0)
  └── ...
```

**对于 WQ_UNBOUND（system_unbound_wq）**，pool 不是 per-CPU 的，而是动态分配的：

```c
// 通过 unbound_pool_hash 按属性 hash 到共享 pool
static DEFINE_HASHTABLE(unbound_pool_hash, UNBOUND_POOL_HASH_ORDER);
// hash key = apply_wqattrs() 生成的 attrs 哈希
```

unbound pool 的 CPU affinity 通过 `workqueue_attrs->cpumask` 设置，所有共享同一 attrs 的 wq 共享同一个 pool。这意味着 **WQ_UNBOUND 的所有 work 可以被调度到任何 allowed CPU** 执行。

### 1.2 worker 的创建时机——懒创建（lazy）

**worker 不是在 wq 创建时创建的，而是在第一次有 work 排队时按需创建的。**

完整路径：

```
queue_work(system_wq, work)
  └── __queue_work()
        └── insert_work(pwq, work, &pool->worklist, flags)
              └── kick_pool(pool)
                    └── wake_up_process(idle_worker->task)   ← 如果有 idle worker

                // 如果没有 idle worker？
                // worker_thread() 在 recheck 时：
                if (!need_more_worker(pool))
                  goto sleep;
                if (!may_start_working(pool))   // nr_idle == 0
                  manage_workers(worker);       // 触发 maybe_create_worker
```

为什么 system_wq 不绑定特定 CPU？因为它是 WQ_PERCPU：
- 每个 CPU 有自己的 `cpu_worker_pools`，worker_pool->cpu = 该 CPU 编号
- worker 通过 `kthread_set_per_cpu(worker->task, pool->cpu)` 绑定到特定 CPU
- 但 work 本身是"per-CPU pwq"的，work 会在创建它的 CPU 上执行

### 1.3 worker 创建的完整过程

```c
maybe_create_worker(pool)           // 被 manager_thread 调用
  ├── raw_spin_unlock_irq(&pool->lock)
  ├── mod_timer(&pool->mayday_timer, jiffies + MAYDAY_INITIAL_TIMEOUT) // 10ms 应急 timer
  └── while (create_worker(pool) || !need_to_create_worker(pool))
        schedule_timeout_interruptible(CREATE_COOLDOWN);  // HZ = 1s

create_worker(pool)
  ├── alloc_worker(node)           // 分配 struct worker
  ├── INIT_LIST_HEAD(&worker->scheduled)
  ├── worker->flags = WORKER_PREP
  └── kthread_create_on_node(worker_thread, worker, ...)  // 创建但不唤醒
        └── worker_attach_to_pool(pool)  // 绑定到 pool
```

新 worker 创建后**不会立即唤醒**，而是在下次 `kick_pool` 时被唤醒。worker 最初处于 `WORKER_PREP` 状态，在 `worker_thread` 的 `do { ... } while (keep_working(pool))` 循环中才正式开始处理 work。

---

## 二、queue_work 路径串联

### 2.1 完整调用链

```
queue_work(system_wq, work)
  ├── local_irq_save(irq_flags)                    // 关中断，防止竞争
  ├── test_and_set_bit(WORK_STRUCT_PENDING_BIT)    // 原子置 PENDING，防止重入
  ├── clear_pending_if_disabled(work)              // 如果 work 被 disable 则清除
  └── __queue_work(cpu, wq, work)
        ├── rcu_read_lock()
        │
        ├── [CPU 选择]
        │   if (cpu == WORK_CPU_UNBOUND) {
        │     if (WQ_UNBOUND) cpu = wq_select_unbound_cpu()
        │     else            cpu = raw_smp_processor_id()
        │   }
        │
        ├── pwq = rcu_dereference(*per_cpu_ptr(wq->cpu_pwq, cpu))
        ├── pool = pwq->pool
        │
        ├── [处理 work 正在其他 pool 执行的情况]
        │   last_pool = get_work_pool(work)
        │   if (last_pool && last_pool != pool && !WQ_ORDERED) {
        │     // 检查是否真的在执行
        │     worker = find_worker_executing_work(last_pool, work)
        │     if (worker && worker->current_pwq->wq == wq)
        │       pwq = worker->current_pwq, pool = pwq->pool  // 沿用原 pool
        │   }
        │
        ├── raw_spin_lock(&pool->lock)             // 关键：持锁后操作 worklist
        │
        ├── [max_active 限流]
        │   if (list_empty(&pwq->inactive_works) && pwq_tryinc_nr_active())
        │     insert_work(pwq, work, &pool->worklist, flags)  // 直接入 worklist
        │     kick_pool(pool)                         // 唤醒 worker
        │   else
        │     insert_work(pwq, work, &pwq->inactive_works, flags) // 入 inactive 队列
        │
        ├── raw_spin_unlock(&pool->lock)
        └── rcu_read_unlock()
```

### 2.2 为什么用 `spin_lock_bh`（实际是 `raw_spin_lock_irq`）？

这里用的是 `raw_spin_lock(&pool->lock)` + `local_irq_save`/`local_irq_restore`，不是 `spin_lock_bh`。但概念上等价：**保护 worklist 的操作在硬中断下半部（下半部 = softirq/hrtimer/BH）下是安全的。**

关键原因：
1. `pool->worklist` 被两个上下文访问：`__queue_work`（进程上下文）和 `worker_thread`（也是进程上下文），但 worker 执行 work 时可能会被 preempt，preempt 过程中 scheduler 也可能访问 worklist
2. 更重要的是：**定时器（timer）也在操作 worklist** —— `delayed_work_timer_fn` 会调用 `__queue_work`，而 timer 在 BH 上下文运行
3. BH 上下文的 timer callback 和进程上下文的 `__queue_work` 之间通过 `pool->lock` 互斥

所以 `raw_spin_lock_irq` = 关中断（阻止 timer）+ 加锁（保护 worklist）。

### 2.3 `wq_select_unbound_cpu` — unbound work 的 CPU 选择

```c
static int wq_select_unbound_cpu(int cpu)
{
    if (likely(!wq_debug_force_rr_cpu) &&
        cpumask_test_cpu(cpu, wq_unbound_cpumask))
        return cpu;                              // 本地 CPU 优先

    // 否则 round-robin 轮询选择，避免扰动敏感任务
    new_cpu = __this_cpu_read(wq_rr_cpu_last);
    new_cpu = cpumask_next_and_wrap(new_cpu, wq_unbound_cpumask, ...);
    __this_cpu_write(wq_rr_cpu_last, new_cpu);
    return new_cpu;
}
```

**unbound work 不是固定在某个 CPU 上执行，而是每次入队时动态选择目标 CPU。** 选中的 CPU 决定了用哪个 `pool_workqueue`，进而决定用哪个 `worker_pool`。

---

## 三、worker 认领逻辑串联

### 3.1 worker 的状态机

```
                      ┌─────────────────────────────────────────┐
                      │           worker 创建完成                │
                      │         flags = WORKER_PREP             │
                      │         位于 pool->workers 链表         │
                      └──────────────┬──────────────────────────┘
                                     │
                                     ▼
                      ┌─────────────────────────────────────────┐
                      │  worker_thread():                       │
                      │  worker_leave_idle()                    │
                      │  worker_clr_flags(WORKER_PREP)           │
                      │  worker_set_flags(0)                    │
                      │  nr_running++                           │
                      └──────────────┬──────────────────────────┘
                                     │
                    ┌────────────────▼───────────────────────────┐
                    │     WORKER RUNNING (处理 work)               │
                    │  do {                                       │
                    │    work = list_first_entry(&pool->worklist)│
                    │    assign_work(work, worker, &scheduled)    │
                    │    process_scheduled_works(worker)         │
                    │  } while (keep_working(pool))             │
                    │                                             │
                    │  keep_working:                             │
                    │    !list_empty(&worklist) && nr_running<=1 │
                    └────────────────┬──────────────────────────┘
                                     │
                      ┌──────────────▼──────────────────────────┐
                      │  worker_enter_idle()                     │
                      │  flags |= WORKER_IDLE                   │
                      │  nr_idle++, nr_running--                │
                      │  加入 pool->idle_list                   │
                      │  set_current_state(TASK_IDLE)           │
                      │  schedule()  ──→ 休眠等待被 kick         │
                      └─────────────────────────────────────────┘
                                     ▲
                                     │ wake_up_process()
                                     │
                      ┌──────────────┴──────────────────────────┐
                      │         重新检查 worklist                │
                      │    if (need_more_worker(pool))           │
                      │      worker_leave_idle() → 处理 work     │
                      │    else                                  │
                      │      继续 sleep                          │
                      └─────────────────────────────────────────┘
```

**`keep_working` 的语义**：当一个 worker 处理完一个 work 后，如果 worklist 还有 work 且 `nr_running <= 1`（即只有自己一个 running worker），它会继续处理而不是睡眠。这保证了在 work 积压时有足够的并发消化它们。

### 3.2 manager 线程的唤醒时机

manager 不是独立的内核线程，而是**由 idle worker 临时充当**：

```c
// worker_thread 中
recheck:
if (!need_more_worker(pool))   // worklist 非空 && nr_running == 0
    goto sleep;
if (!may_start_working(pool) && manage_workers(worker))  // 没有 idle worker
    goto recheck;
```

`may_start_working(pool)` 检查 `pool->nr_idle > 0`。如果所有 worker 都在忙（无 idle），**当前 worker（即将变成 manager）承担起创建新 worker 的责任**：

```c
static bool manage_workers(struct worker *worker)
{
    pool->flags |= POOL_MANAGER_ACTIVE;   // 互斥：同一 pool 同时只能有一个 manager
    pool->manager = worker;
    maybe_create_worker(pool);             // 循环创建直到满足需要
    pool->manager = NULL;
    pool->flags &= ~POOL_MANAGER_ACTIVE;
    return true;
}
```

manager 持锁期间**可能睡眠**（`schedule_timeout`），但锁会被释放和重新获取：

```c
maybe_create_worker(pool)
  __releases(&pool->lock)   // 解锁让 worker 能继续处理 worklist
  __acquires(&pool->lock)
{
    raw_spin_unlock_irq(&pool->lock);
    mod_timer(&pool->mayday_timer, ...);  // 启动应急 timer
    while (create_worker(pool) || !need_to_create_worker(pool))
        schedule_timeout_interruptible(CREATE_COOLDOWN);  // 睡眠 1s
    timer_delete_sync(&pool->mayday_timer);
    raw_spin_lock_irq(&pool->lock);
    if (need_to_create_worker(pool))
        goto restart;   // 锁期间又被耗尽了，重试
}
```

### 3.3 worker 怎么知道取哪个 work？

**不需要"知道"**。每个 worker 都属于一个 `worker_pool`，这个 pool 有自己的 `worklist`。所有 worker 共享同一个 `worklist`，通过 `list_first_entry` **竞争性取 work**：

```c
// worker_thread 中
do {
    struct work_struct *work =
        list_first_entry(&pool->worklist, struct work_struct, entry);
    if (assign_work(work, worker, NULL))
        process_scheduled_works(worker);
} while (keep_working(pool));
```

`assign_work` 将 work 从 pool->worklist 移到 worker->scheduled：

```c
// assign_work 实现（隐含逻辑）
list_del_init(&work->entry);           // 从 pool->worklist 移除
worker->current_work = work;           // 记录当前 work
worker->current_func = work->func;     // 记录要执行的函数
list_add_tail(&work->entry, &worker->scheduled);  // 加入 worker 私有链表
```

这保证了**同一个 work 不会被两个 worker 同时处理**（hash_add busy_hash 也用于追踪正在执行的 work）。

---

## 四、destroy_workqueue 串联

### 4.1 pending work 的命运

**destroy_workqueue 会等所有 pending work 执行完再销毁**，通过 drain 机制：

```
destroy_workqueue(wq)
  ├── workqueue_sysfs_unregister(wq)
  ├── wq->flags |= __WQ_DESTROYING         // 新 queue_work 直接 WARN 并拒绝
  ├── drain_workqueue(wq)                  // 等待所有 pwq 清空
  │     ├── wq->nr_drainers++
  │     ├── wq->flags |= __WQ_DRAINING    // queue_work 变慢但不拒绝
  │     └── __flush_workqueue(wq)          // 为每个 pwq 插入 wq_barrier 等待完成
  │           └── wait for all works to complete...
  ├── kthread_stop(wq->rescuer->task)     // 杀死 rescuer 线程
  ├── list_del_rcu(&wq->list)             // 从全局 workqueues 链表移除
  └── put_pwq_unlocked() for all pwqs     // RCU 保护下释放
```

**pending work 不会被丢弃，而是被 flush 掉**。`__flush_workqueue` 通过插入 barrier work 来等待所有正在执行的 work 完成后才返回。

### 4.2 `cancel_delayed_work_sync` 是怎么同步等待的？

```
cancel_delayed_work_sync(dwork)
  └── __cancel_work_sync(&dwork->work, WORK_CANCEL_DELAYED)
        ├── work = &dwork->work
        ├── if (timer_pending(&dwork->timer))
        │     del_timer_sync(&dwork->timer)  // 先删除 timer
        └── __flush_work(work, from_cancel=true)
              ├── find_worker_executing_work(pool, work)
              │     // 如果 work 正在某个 worker 中执行
              ├── if (worker)
              │     // 等该 worker 完成（通过 flush_barrier）
              └── flush_workqueue(wq)
                    // 等待所有引用计数归零
```

**关键**：`del_timer_sync` 确保即使 timer 已经 fires、`__queue_work` 已经开始执行也能被取消。但如果 work 已经通过 `insert_work` 进入了 `pool->worklist`，cancel 只能等待该 work 被某个 worker 处理。

### 4.3 `cancel_work_sync` vs `cancel_delayed_work_sync`

| 函数 | 能取消 timer 吗 | 能取消已触发但未执行的 work 吗 | 能等待正在执行的 work 吗 |
|------|---------------|------------------------------|------------------------|
| `cancel_work_sync` | 否（无 timer） | 否（work 直接在 worklist 或已执行） | 能（等待 worker 完成） |
| `cancel_delayed_work_sync` | 能（删除 timer） | **不能**：如果 timer 已 fires、work 已入 `__queue_work` 路径，del_timer_sync 删除 timer 后 work 已被入队，只能 flush | 能 |

---

## 五、WQ_UNBOUND 和 ordered 语义

### 5.1 WQ_UNBOUND 的调度机制

```
queue_work(system_unbound_wq, work)   // WQ_UNBOUND
  └── __queue_work(WORK_CPU_UNBOUND, wq, work)
        ├── cpu = wq_select_unbound_cpu(raw_smp_processor_id())
        │   // 从 wq_unbound_cpumask 选一个 CPU（round-robin）
        ├── pwq = rcu_dereference(*per_cpu_ptr(wq->cpu_pwq, cpu))
        │   // 注意：unbound wq 也有 per_cpu_ptr，但 pwq 指向同一个 unbound pool
        └── pool = pwq->pool   // unbound pool，无特定 CPU 绑定
```

**WQ_UNBOUND 的 work 被调度到哪个 CPU？** 由 `wq_select_unbound_cpu` 动态决定，每次入队可能不同。所有 unbound pool 共享同一个 `wq_unbound_cpumask` cpumask，work 可以在 mask 内任意 CPU 执行。

unbound pool 的 worker 通过 `worker_attach_to_pool` 设置 `WORKER_UNBOUND` flag：

```c
if (pool->flags & POOL_DISASSOCIATED) {
    worker->flags |= WORKER_UNBOUND;
} else {
    kthread_set_per_cpu(worker->task, pool->cpu);  // 绑定到 pool->cpu
}
```

`POOL_DISASSOCIATED` 在 CPU hotplug 时设置，所以 unbound worker 不会绑定到特定 CPU。

### 5.2 system_unbound_wq vs system_highpri_wq

```c
system_highpri_wq = alloc_workqueue("events_highpri",
    WQ_HIGHPRI | WQ_PERCPU, 0);         // WQ_PERCPU! 不是 WQ_UNBOUND
system_unbound_wq = alloc_workqueue("events_unbound",
    WQ_UNBOUND, WQ_MAX_ACTIVE);         // WQ_UNBOUND, max_active=256
```

**system_highpri_wq 是 per-CPU 的高优先级 wq**，每个 CPU 都有独立的 pool，work 在提交到的 CPU 上执行。

**system_unbound_wq 是真正的 unbound**，所有 CPU 共享 worker，可以达到很高的并发度（`WQ_MAX_ACTIVE = 256`）。

### 5.3 ordered work 的保证

```c
// 关键标志：__WQ_ORDERED
// 设置条件：alloc_workqueue 时传入 WQ_ORDERED 或代码中自动设置

if (wq->flags & __WQ_ORDERED) {
    // 只创建一个 pwq，所有 work 都入这个 pwq
    ret = apply_workqueue_attrs_locked(wq, ordered_wq_attrs[highpri]);
    // 只有一个 dfl_pwq，work 顺序严格串行
}
```

**ordered 语义保证**：

1. **全局顺序**：所有 work 按入队顺序执行，不可能有其他 work "插队"
2. **通过单一 pwq**：WQ_UNBOUND + ordered 时，所有 work 都路由到同一个 pool_workqueue，而这个 pwq 指向的 pool 只有一个执行 worker
3. **非重入保证**：如果一个 work 正在执行，同一个 wq 的新 work 不能开始执行

实现机制在 `__queue_work` 中：
```c
if (last_pool && last_pool != pool && !(wq->flags & __WQ_ORDERED)) {
    // 非 ordered 时，检查 work 是否在其他 pool 执行
    // 如果是，沿用那个 pwq 保证非重入
}
```

---

## 六、pwq 和 rescuer

### 6.1 pool_workqueue 的核心作用

pwq 是 **wq 和 worker_pool 之间的多路复用层**：

```
workqueue_struct
  ├── pwqs 链表 ──→ pool_workqueue[]
  │                    ├── pool_workqueue->pool ──→ worker_pool
  │                    │                          (持有 worklist, idle_list, busy_hash)
  │                    ├── nr_in_flight[colors]    (统计)
  │                    ├── inactive_works          (max_active 限流时的等待队列)
  │                    └── mayday_node             (rescuer 求助链表)
  │
  └── cpu_pwq (per-CPU) ──→ pwq (WQ_PERCPU)
       unbound_pwq(wq, cpu)  ──→ pwq (WQ_UNBOUND，所有 CPU 共享)
```

### 6.2 rescuer 线程的触发

**rescuer 是什么时候被触发的？** 三个条件同时满足：

1. wq 创建时带 `WQ_MEM_RECLAIM` 标志
2. `init_rescuer(wq)` 为该 wq 创建了一个共享的 rescuer 线程
3. 当 pool 的 worker 不足且分配新 worker 失败（内存压力）时

```c
// pool_mayday_timeout — mayday_timer 到期后触发
static void pool_mayday_timeout(struct timer_list *t)
{
    pool = timer_container_of(pool, t, mayday_timer);
    // 遍历 pool->worklist，将属于 WQ_MEM_RECLAIM wq 的 work 转移给 rescuer
    // 方式：将 pwq 加入 wq->maydays 链表，唤醒 rescuer 线程
    wake_up_process(wq->rescuer->task);
}
```

**mayday_timer 的触发时间**：`MAYDAY_INITIAL_TIMEOUT = HZ/100`（10ms），之后每 `MAYDAY_INTERVAL = HZ/10`（100ms）重试。

```
rescuer_thread()
  ├── while (!list_empty(&wq->maydays))
  │     pwq = list_first_entry(&wq->maydays, ...)
  │     assign_rescuer_work(pwq, rescuer)
  │     // 从 pool->worklist 抢 work 分配给 rescuer
  └── schedule_timeout_interruptible(RESCUER_BATCH=16)  // 批量处理后休息
```

**rescuer 的特殊性**：
- 共享：一个 rescuer 可以处理该 wq 在不同 pool 上的 work
- 优先级低：`RESCUER_NICE_LEVEL = MIN_NICE`（最低优先级）
- 不会在 pool 上创建新 worker，只是"帮助处理"积压的 work

### 6.3 高内存压力下 delayed work 的命运

在高内存压力下，`delayed_work` 的 timer 执行可能受影响：

```c
// __queue_delayed_work 中
timer->expires = jiffies + delay;
if (housekeeping_enabled(HK_TYPE_TIMER))
    add_timer_on(timer, cpu);    // 调度到特定 CPU
else if (cpu == WORK_CPU_UNBOUND)
    add_timer_global(timer);     // 全局 timer
else
    add_timer_on(timer, cpu);
```

**内存压力影响**：
1. **timer 分配延迟**：timer_list 本身在 `INIT_DELAYED_WORK` 时已经静态分配，但 timer wheel 的执行依赖 softirq，在内存紧缺时 softirq 可能被延迟
2. **work 分配延迟**：如果 work_struct 本身是从 slab 分配器来的（不是静态定义），GFP_KERNEL 分配在内存压力下可能阻塞，导致 `queue_work` 本身变慢
3. **`delayed_work_timer_fn` 的行为**：如果内存压力导致 CPU 忙于回收内存，`add_timer_on` 可能延迟触发，**delay 参数只是"期望的最小延迟"，不是保证的**

---

## 七、work 和 delayed_work 的区别

### 7.1 数据结构的区别

```c
struct work_struct {
    atomic_t data;          // 存储 PENDING bit + pwq 指针
    struct list_head entry; // 链接到 pool->worklist
    work_func_t func;       // 要执行的函数
#ifdef CONFIG_LOCKDEP
    struct lockdep_map lockdep_map;
#endif
};

struct delayed_work {
    struct work_struct work;
    struct timer_list timer;      // <-- 多出来的 timer
    struct workqueue_struct *wq;  // 目标 wq
    int cpu;                       // 目标 CPU
};
```

### 7.2 delayed_work 的 timer 实现

```
queue_delayed_work(wq, dwork, delay)
  └── __queue_delayed_work(cpu, wq, dwork, delay)
        ├── if (!delay)
        │     __queue_work(cpu, wq, &dwork->work)  // 立即执行
        └── dwork->wq = wq
             dwork->cpu = cpu
             timer->expires = jiffies + delay
             add_timer_on(timer, cpu)  // 或 add_timer_global
                      │
                      ▼ [timer 到期]
        delayed_work_timer_fn(timer)
          └── __queue_work(dwork->cpu, dwork->wq, &dwork->work)
                      │
                      ▼ [普通 work 的 queue_work 路径]
                insert_work(pwq, &dwork->work, &pool->worklist, flags)
                kick_pool(pool)
```

### 7.3 cancel 的能力边界

```
cancel_work_sync(work)
  ├── work 未在队列：test_and_set_bit 失败，直接返回 false（work 不在队列）
  ├── work 在 pool->worklist：__flush_work 等待
  └── work 正在 worker 执行：等待该 worker 完成

cancel_delayed_work(dwork)
  ├── timer 未 fire：del_timer_sync(&dwork->timer)，清除 PENDING
  └── timer 已 fire（work 已入 __queue_work）：work 已进入 pool->worklist
        // 此时 cancel_work_sync 能等待，但 cancel_delayed_work 本身不能取消
        cancel_delayed_work 返回 false（表示 "dwork->work 已入队"）

cancel_delayed_work_sync(dwork)
  ├── timer 未 fire：del_timer_sync + __flush_work（work 不在队列，只清理 timer）
  └── timer 已 fire：del_timer 尝试删除（可能已执行完），然后 __flush_work 等待
```

---

## 八、完整流程图

### 图1：work 提交流程（queue_work 到 worker 认领）

```
  用户代码
    │
    ▼
queue_work(wq, work)
    │ 关本地中断
    │ test_and_set_bit(PENDING) ── 若已置，说明已在队列，直接返回
    ▼
__queue_work(cpu, wq, work)
    │
    ├─[CPU 选择]
    │   WQ_UNBOUND  → wq_select_unbound_cpu() → 选一个 allowed CPU
    │   WQ_PERCPU   → raw_smp_processor_id()  → 当前 CPU
    │
    ▼
pwq = get_pwq(wq, cpu)
pool = pwq->pool
    │
    ▼
raw_spin_lock(&pool->lock)
    │
    ├─[max_active 限流]
    │   if (nr_active < max_active) {
    │       insert_work(pwq, work, &pool->worklist, ...)
    │       kick_pool(pool)      ← 唤醒 idle worker 或触发 manager
    │   } else {
    │       insert_work(pwq, work, &pwq->inactive_works, ...)
    │   }
    │
    ▼
raw_spin_unlock(&pool->lock)
    │
    ▼
kick_pool(pool)
    │
    ├─ 有 idle worker？
    │     wake_up_process(idle_worker->task)
    │         worker 被唤醒 → worker_thread()
    │
    └─ 无 idle worker？
          worker_thread() 在 recheck 时：
            if (!may_start_working(pool))
                manage_workers(current_worker)
                    maybe_create_worker(pool)
                        create_worker(pool)  ← 新 worker 创建（懒创建）
```

### 图2：worker 工作认领流程

```
worker_thread()
    │
    ├─ set_pf_worker(true)         "我是 wq worker"
    ├─ worker_leave_idle()         nr_idle--, 移出 idle_list
    │
recheck:
    ├─ need_more_worker(pool)?     worklist 非空 && nr_running==0?
    │     └─ false → goto sleep
    │
    ├─ may_start_working(pool)?    nr_idle > 0?
    │     └─ false → manage_workers(worker)
    │                 └─ maybe_create_worker(pool)
    │                     └─ 循环 create_worker + sleep 直到够用
    │
do {
    │   work = list_first_entry(&pool->worklist, ...)
    │       └─ 竞争取 work：第二个到的 worker 取下一个
    │
    │   assign_work(work, worker, &scheduled)
    │       └─ list_del_init(&work->entry)
    │          worker->current_work = work
    │          list_add_tail(&work->entry, &worker->scheduled)
    │
    │   process_scheduled_works(worker)
    │       └─ list_for_each_entry_safe(work, n, &scheduled, entry)
    │              process_one_work(worker, work)
    │
} while (keep_working(pool))
    └─ keep_working: worklist 非空 && nr_running <= 1
         └─ true → 继续处理（防止频繁唤醒/睡眠）
         └─ false → 退出循环

sleep:
    worker_enter_idle()
    set_current_state(TASK_IDLE)
    schedule()                      ← 主动让出 CPU
         │
         ▼ [被 kick_pool 唤醒]
woke_up:
```

### 图3：pool/worker 生命周期状态图

```
                    ┌──────────────────┐
                    │   create_worker   │
                    │  alloc_worker()   │
                    │  kthread_create  │
                    │   初始: PREP      │
                    └────────┬─────────┘
                             │
                             ▼
                    ┌──────────────────┐
                    │ worker_thread()  │
                    │   PREP → RUNNING │
                    │   nr_running++   │
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
    │ 处理 work 中  │  │ keep_working │  │  work 全部   │
    │ nr_running>1 │  │   返回 true   │  │   处理完毕   │
    └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
           │                  │                  │
           └──────────────────┼──────────────────┘
                              ▼
                     ┌──────────────────┐
                     │ worker_enter_idle│
                     │  flags |= IDLE   │
                     │  nr_idle++       │
                     │  加入 idle_list  │
                     └────────┬─────────┘
                              │
                              ▼
              ┌──────────────────────────────┐
              │       idle 等待              │
              │   schedule() → 睡眠         │
              └──────────────┬───────────────┘
                             │
                 kick_pool() │ wake_up_process()
                             │
                             ▼
                    ┌──────────────────┐
                    │ worker_leave_idle │
                    │  flags &= ~IDLE  │
                    │  nr_idle--        │
         └────────┬─────────┘
                             │
                             ▼
                    ┌──────────────────┐
                    │  回到 RUNNING    │
                    │   继续处理 work  │
                    └──────────────────┘
```

### 图4：destroy_workqueue 流程

```
destroy_workqueue(wq)
    │
    ├─ __WQ_DESTROYING 标志
    │     └─ 新 queue_work 直接 WARN + 拒绝
    │
    ├─ drain_workqueue(wq)
    │     ├─ __WQ_DRAINING 标志
    │     ├─ __flush_workqueue(wq)
    │     │     └─ 为每个 pwq 插入 flush_work，等待所有 work 完成
    │     └─ 重试直到所有 pwq empty
    │
    ├─ kthread_stop(rescuer)     ← 仅 WQ_MEM_RECLAIM
    │     └─ rescuer 排空 maydays 列表后退出
    │
    ├─ list_del_rcu(&wq->list)   ← 从全局 workqueues 链表移除
    │
    └─ put_pwq_unlocked()        ← 每 CPU 一个 pwq
          └─ refcnt 到 0 时调用 pwq_release_workfn()
                └─ 调度到 kthread_worker 由 pwq_release_worker 执行
                      └─ schedule_work(&pwq->release_work)
                            └─ 延迟释放 unbound pwq
```

---

## 关键设计要点总结

1. **workqueue 的核心抽象**：work 不知道谁来执行，worker 不知道有哪些 work 排队——两者通过 `pool->worklist` 解耦

2. **懒创建的 worker 池**：worker 按需创建（`need_to_create_worker`），避免预创建造成的资源浪费；空闲 5 分钟后被 cull（`IDLE_WORKER_TIMEOUT = 300*HZ`）

3. **PENDING bit 的双重作用**：既防止同一 work 被多次入队（`test_and_set_bit`），也是其他 worker 尝试偷取 work 时的同步信号（busy-loop 等待 PENDING 被清除）

4. **max_active 限流**：`nr_active` 计数器控制活跃 work 数量；超过上限的 work 进入 `pwq->inactive_works` 等待队列

5. **rescuer 是内存回收的逃生口**：当内存紧张、`create_worker` 分配失败时，mayday_timer 触发 rescuer 来处理积压的 work，保证 forward progress

6. **BH workqueue 的特殊处理**：`WQ_BH` 使用 `POOL_BH` 标志，worker 不参与调度（`set_pf_worker` + `PF_WQ_WORKER`），通过 `kick_bh_pool` + irq_work 在 BH 上下文直接执行 work

7. **WQ_UNBOUND 的亲和性**：`wq_unbound_cpumask` 控制哪些 CPU 可用于 unbound work；每次入队时通过 round-robin 分散到不同 CPU，减少单一 CPU 的负担