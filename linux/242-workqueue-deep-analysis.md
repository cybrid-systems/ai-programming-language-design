# Linux Kernel workqueue 机制深度分析

> Kernel Source: Linux 7.0-rc1 (`workqueue.c` 8439 行，`workqueue.h` 910 行)
> 分析工具: doom-lsp (clangd LSP)

---

## 一、概述

workqueue 是 Linux kernel 中最核心的异步执行机制。它的设计目标很简单：**在进程上下文（process context）中以共享 worker pool 的方式执行任意异步任务**。

与 tasklet、softirq 等机制不同，workqueue 的核心特征是：

- **执行上下文是进程上下文**：可以 sleep，可以调度，可以访问用户空间（通过 copy_from_user 等）
- **共享 worker pool**：多个 work item 复用同一组内核线程（kworker），而非每个 work item 独占线程
- **可绑定/可解绑**：per-CPU 绑定（`WQ_PERCPU`）或完全解绑（`WQ_UNBOUND`）
- **支持延迟执行**：`delayed_work` 基于 timer 实现
- **支持 BH（bottom-half）模式**：`WQ_BH` 标志使 work 在软中断（softirq）上下文执行

---

## 二、核心数据结构

### 2.1 `struct work_struct`

```c
// workqueue.h
struct work_struct {
    atomic_long_t data;          // 编码了 flags 和 pool 信息
    struct list_head entry;      // 链入 pool->worklist 或 pwq->inactive_works
    work_func_t func;            // 回调函数
#ifdef CONFIG_LOCKDEP
    struct lockdep_map lockdep_map;
#endif
};
```

`work_struct->data` 的 bit 布局（32/64 位系统略有不同）是理解 workqueue 所有操作的关键：

```
[ pool ID ] [ disable depth ] [ OFFQ flags ] [ STRUCT flags ]
   高位                                              低位
```

- **STRUCT flags**（低几位）：`WORK_STRUCT_PENDING_BIT`、`WORK_STRUCT_PWQ_BIT`、`WORK_STRUCT_INACTIVE_BIT` 等
- **OFFQ flags**：当 work PENDING 但不在队列时使用（如正在执行），包含 BH 标志
- **POOL_ID**（最高位附近）：标识 work 当前所在的 worker_pool

### 2.2 `struct delayed_work`

```c
struct delayed_work {
    struct work_struct work;
    struct timer_list   timer;  // Linux timer 实现
    struct workqueue_struct *wq;
    int                 cpu;
};
```

`delayed_work` 不过是 `work_struct` + `timer_list` 的组合包装。timer 到期后回调 `delayed_work_timer_fn()`，该函数调用 `__queue_delayed_work()` 将 work 推入 workqueue。

### 2.3 `struct worker_pool`

```c
struct worker_pool {
    raw_spinlock_t      lock;          // 保护本 pool 的所有状态
    int                 cpu;           // 绑定 CPU，-1 表示 unbound
    int                 id;            // 全局唯一 ID
    unsigned int        flags;          // POOL_BH | POOL_DISASSOCIATED | POOL_MANAGER_ACTIVE | ...
    int                 nr_running;    // 当前正在执行的 work 数
    int                 nr_workers;     // 总 worker 数
    int                 nr_idle;        // 空闲 worker 数
    struct list_head    worklist;       // 待执行的 work 队列（真正在跑的）
    struct list_head    idle_list;      // 空闲 worker 链表
    struct timer_list   idle_timer;     // 空闲 worker 超时删除定时器
    struct timer_list   mayday_timer;   // SOS 定时器，worker 创建失败时触发
    DECLARE_HASHTABLE(busy_hash, 6);   // 正在执行的 worker（以 work 为 key）
    struct worker      *manager;        // 当前担任 manager 角色的 worker
    struct list_head    workers;        // 所有属于本 pool 的 worker
    struct workqueue_attrs *attrs;      // CPU affinity、nice 值等属性
};
```

每个**标准 per-CPU pool** 在系统中有 2 个（`NR_STD_WORKER_POOLS=2`）：normal 和 highpri，分别由 `cpu_worker_pools[cpu][0]` 和 `cpu_worker_pools[cpu][1]` 维护。

### 2.4 `struct pool_workqueue`（pwq）

pwq 是 **workqueue 和 worker_pool 之间的多路复用层**：

```c
struct pool_workqueue {
    struct worker_pool *pool;           // 指向实际执行 work 的 pool
    struct workqueue_struct *wq;         // 指向拥有本 pwq 的 workqueue
    int                 work_color;     // 当前 work 颜色（color 环）
    int                 flush_color;    // 当前 flush 颜色
    int                 refcnt;         // 引用计数
    int                 nr_in_flight[WORK_NR_COLORS];  // 各颜色中正在飞行中的 work 数
    int                 nr_active;      // 当前激活（可执行）的 work 数
    struct list_head    inactive_works;  // 等待激活的 work 链表（max_active 限制）
};
```

关键洞察：**一个 workqueue 可以有多个 pwq**——per-CPU workqueue 每个 CPU 一个 pwq；unbound workqueue 通过 `unbound_pool_hash` 动态分配多个 pool。

### 2.5 `struct workqueue_struct`

```c
struct workqueue_struct {
    struct list_head        pwqs;           // 所有 pwq 的链表
    struct list_head        list;           // 链入全局 workqueues 链表
    struct pool_workqueue __percpu *cpu_pwq; // per-CPU pwq 数组
    struct pool_workqueue  *dfl_pwq;        // unbound wq 的默认 pwq
    unsigned int            flags;
    int                     saved_max_active;  // 恢复时用的 max_active
    struct mutex            mutex;           // 保护 workqueue 属性
    struct worker          *rescuer;         // 紧急情况下的 rescue worker
    struct list_head        maydays;         // 正在呼救的 pwq 链表
    ...
};
```

---

## 三、工作线程创建串联

### 3.1 `create_workqueue("events")` 背后发生了什么？

当我们调用 `create_workqueue("events")` 时，实际上调用的是 `alloc_workqueue_noprof()` → `__alloc_workqueue()`。

```c
// workqueue.c line ~5910
struct workqueue_struct *
alloc_workqueue_noprof(const char *fmt, unsigned int flags, int max_active, ...)
{
    va_list args;
    va_start(args, max_active);
    wq = __alloc_workqueue(fmt, flags, max_active, args);
    va_end(args);
    wq_init_lockdep(wq);
    return wq;
}
```

`__alloc_workqueue` 做了以下事情：

1. **分配 `workqueue_struct`**，初始化 mutex、idr 等
2. **调用 `alloc_and_link_pwqs()`**：为每个 CPU 创建 `pool_workqueue`
3. **对于 per-CPU wq**（`WQ_PERCPU`）：
   - 每个 CPU 的 pwq 指向该 CPU 的 `cpu_worker_pools[highpri]`
   - **不创建新的 pool**，直接复用系统中预分配好的 per-CPU worker pools
4. **对于 unbound wq**（`WQ_UNBOUND`）：
   - 调用 `apply_workqueue_attrs_locked()` 在 `unbound_pool_hash` 中查找/创建匹配的 pool
   - unbound pool 按 `(nice, cpumask, affinity_scope)` 元组哈希定位

### 3.2 worker 何时被创建？

**系统初始化阶段**（`workqueue_init()`，line ~8092）才是真正创建 kworker 线程的地方：

```c
void __init workqueue_init(void)
{
    // 1. BH pseudo-workers（每个 CPU 两个）
    for_each_possible_cpu(cpu)
        for_each_bh_worker_pool(pool, cpu)
            BUG_ON(!create_worker(pool));  // 创建 BH worker

    // 2. per-CPU standard workers（每个 online CPU 两个 pool 各一个）
    for_each_online_cpu(cpu) {
        for_each_cpu_worker_pool(pool, cpu) {
            pool->flags &= ~POOL_DISASSOCIATED;  // 关联到 CPU
            BUG_ON(!create_worker(pool));
        }
    }

    // 3. unbound workers（所有在 unbound_pool_hash 中的 pool）
    hash_for_each(unbound_pool_hash, bkt, pool, hash_node)
        BUG_ON(!create_worker(pool));
}
```

注意：**系统初始化时只为每个 per-CPU pool 创建第一个 worker**（`nr_workers=1, nr_idle=1`），后续 worker 是按需动态创建的。

### 3.3 `create_worker` 完整流程

```c
// workqueue.c line 2816
static struct worker *create_worker(struct worker_pool *pool)
{
    // 1. 分配 worker ID
    id = ida_alloc(&pool->worker_ida, GFP_KERNEL);

    // 2. 分配 worker 结构体
    worker = alloc_worker(pool->node);

    // 3. 创建 kthread（如果不是 BH pool）
    worker->task = kthread_create_on_node(worker_thread, worker,
                                          pool->node, "%s", id_buf);
    set_user_nice(worker->task, pool->attrs->nice);

    // 4. 绑定 CPU affinity
    if (pool->flags & POOL_DISASSOCIATED)
        worker->flags |= WORKER_UNBOUND;   // unbound: 不绑定特定 CPU
    else
        kthread_set_per_cpu(worker->task, pool->cpu);  // per-CPU: 绑定

    // 5. 附加到 pool
    worker_attach_to_pool(worker, pool);

    // 6. 放入 idle 列表，等待调度
    raw_spin_lock_irq(&pool->lock);
    worker->pool->nr_workers++;
    worker_enter_idle(worker);
    wake_up_process(worker->task);  // 唤醒新 worker 使其进入睡眠等待 work
    raw_spin_unlock_irq(&pool->lock);
}
```

### 3.4 worker_pool 的 CPU affinity 是怎么建立的？

per-CPU pool 的 `cpu` 字段在 `init_cpu_worker_pool()` 中设置（line ~8005）：

```c
static void __init init_cpu_worker_pool(struct worker_pool *pool, int cpu, int nice)
{
    init_worker_pool(pool);
    pool->cpu = cpu;           // 设置绑定 CPU
    pool->node = cpu_to_node(cpu);
    pool->attrs->nice = nice;
    cpumask_copy(pool->attrs->cpumask, cpumask_of(cpu));  // 只能在本 CPU 运行
}
```

当 pool 的 `cpu >= 0` 且 `!(pool->flags & POOL_DISASSOCIATED)` 时，worker 通过 `kthread_set_per_cpu()` 绑定到特定 CPU，worker task 的 `task_struct::cpu` 被固定。

**为什么 `system_wq` 是 per-CPU 却不绑定 CPU？**

`system_wq` 定义为 `alloc_workqueue("events", WQ_PERCPU, 0)`，这意味着：
- workqueue 的 **pwq 是 per-CPU 的**（每个 CPU 一个 pwq）
- 但 worker 是 per-CPU pool 中的线程，**已经绑定到各自的 CPU**
- `WQ_PERCPU` 只是说 pwq 按 CPU 区分，不等于"worker 不绑定 CPU"

### 3.5 unbound pool 的 CPU affinity

unbound pool 创建时（`apply_wqattrs_prepare()`）：
- `pool->cpu = -1`（解绑）
- `pool->flags |= POOL_DISASSOCIATED`
- worker 通过 `worker_attach_to_pool()` 设置 `WORKER_UNBOUND` 标志

`pool_allowed_cpus()` 对于 `pool->cpu < 0 && pool->attrs->affn_strict` 返回 `__pod_cpumask`（NUMA pod 级别亲和性），否则返回 `cpumask`（整个 cpumask）。

---

## 四、queue_work 路径串联

### 4.1 `queue_work(system_wq, work)` 完整调用链

```
queue_work(wq, work)
  └─ queue_work_on(WORK_CPU_UNBOUND, wq, work)
        └─ queue_work_on(cpu=WORK_CPU_UNBOUND, ...)
              ├─ test_and_set_bit(WORK_STRUCT_PENDING_BIT)  ← 防止重复入队
              ├─ clear_pending_if_disabled()                 ← 如果 work 被 disable 则跳过
              └─ __queue_work(cpu, wq, work)                  ← 核心入队逻辑
```

### 4.2 `__queue_work` 详解

```c
// workqueue.c line 2275
static void __queue_work(int cpu, struct workqueue_struct *wq, struct work_struct *work)
{
    // Step 1: 选择目标 pwq
    if (cpu == WORK_CPU_UNBOUND) {
        if (wq->flags & WQ_UNBOUND)
            cpu = wq_select_unbound_cpu(smp_processor_id());  // unbound wq: RR 选择 CPU
        else
            cpu = smp_processor_id();  // per-CPU wq: 用当前 CPU
    }
    pwq = rcu_dereference(*per_cpu_ptr(wq->cpu_pwq, cpu));
    pool = pwq->pool;

    // Step 2: 处理 re-entrancy（work 正在其他 pool 执行）
    last_pool = get_work_pool(work);
    if (last_pool && last_pool != pool && !(wq->flags & __WQ_ORDERED)) {
        // 如果 work 正在 last_pool 执行，将其重新入队到当前 pwq 以保证非重入
        raw_spin_lock(&last_pool->lock);
        worker = find_worker_executing_work(last_pool, work);
        if (worker && worker->current_pwq->wq == wq) {
            pwq = worker->current_pwq;   // 重定向到正在执行的 pwq
            pool = pwq->pool;
        }
        raw_spin_unlock(&last_pool->lock);
    }

    raw_spin_lock(&pool->lock);  // ← 获取 pool lock

    // Step 3: pwq 引用检查（unbound pool 可能已被释放）
    if (unlikely(!pwq->refcnt)) {
        raw_spin_unlock(&pool->lock);
        cpu_relax();   // 等待 pwq 重新分配
        goto retry;
    }

    // Step 4: 决定插入位置
    if (list_empty(&pwq->inactive_works) && pwq_tryinc_nr_active(pwq, false)) {
        // 有空闲槽位 → 直接插入 pool->worklist
        insert_work(pwq, work, &pool->worklist, work_flags);
        kick_pool(pool);   // 唤醒空闲 worker
    } else {
        // max_active 已满 → 插入 pwq->inactive_works 等待
        work_flags |= WORK_STRUCT_INACTIVE;
        insert_work(pwq, work, &pwq->inactive_works, work_flags);
    }

    raw_spin_unlock(&pool->lock);
}
```

### 4.3 `insert_work` — 将 work 插入链表

```c
// workqueue.c line 2220
static void insert_work(struct pool_workqueue *pwq, struct work_struct *work,
                       struct list_head *head, unsigned int extra_flags)
{
    debug_work_activate(work);
    kasan_record_aux_stack(work);

    set_work_pwq(work, pwq, extra_flags);  // 设置 work->data 的 pwq 指针和 flags
    list_add_tail(&work->entry, head);    // 链入目标链表
    get_pwq(pwq);                        // pwq 引用计数 +1
}
```

**关键**：`set_work_pwq()` 将 `WORK_STRUCT_PWQ_BIT` 置位，并将 pwq 指针编码进 `work->data`。

### 4.4 `kick_pool` — 唤醒空闲 worker

```c
// workqueue.c line 1267
static bool kick_pool(struct worker_pool *pool)
{
    struct worker *worker = first_idle_worker(pool);  // 找第一个 idle worker
    if (!need_more_worker(pool) || !worker)
        return false;
    wake_up_process(worker->task);   // 唤醒 worker 线程
}
```

### 4.5 为什么要用 `spin_lock_bh`？

`spin_lock_bh` 在中断处理的下半部（bottom-half）使用。在 workqueue 中：

1. **`pool->lock` 是 `raw_spinlock_t`**（不允许 sleep）
2. **`local_irq_save()` 在 `__queue_work` 开始处保护**：禁止本地中断，防止在临界区内被定时器或其他中断处理程序打断
3. **BH 上下文**：`WQ_BH` 类型的 workqueue 在软中断上下文执行，但 pool 锁仍然使用 `raw_spin_lock_irq` / `raw_spin_unlock_irq`

真正的 bh 保护体现在调用路径上：`queue_work_on` 调用 `local_irq_save()` 禁止中断，而 `process_one_work` 在软中断中执行时，其调用路径已经处于中断上下文中。

---

## 五、worker 认领逻辑串联

### 5.1 worker 线程主循环

```c
// workqueue.c line 3411
static int worker_thread(void *__worker)
{
    struct worker *worker = __worker;
    struct worker_pool *pool = worker->pool;

    set_pf_worker(true);  // 告诉调度器这是 workqueue worker
woke_up:
    raw_spin_lock_irq(&pool->lock);

    // 检查是否应该退出
    if (unlikely(worker->flags & WORKER_DIE)) {
        raw_spin_unlock_irq(&pool->lock);
        set_pf_worker(false);
        return 0;
    }

    worker_leave_idle(worker);   // 标记为非 idle，nr_idle--
recheck:
    if (!need_more_worker(pool))  // worklist 为空 → 睡眠
        goto sleep;

    // 需要管理worker pool（创建/销毁多余 worker）
    if (!may_start_working(pool) && manage_workers(worker))
        goto recheck;

    worker_clr_flags(worker, WORKER_PREP | WORKER_REBOUND);

    // 认领并执行 work
    do {
        work = list_first_entry(&pool->worklist, struct work_struct, entry);
        if (assign_work(work, worker, NULL))
            process_scheduled_works(worker);  // 执行链表上的所有 scheduled work
    } while (keep_working(pool));             // worklist 非空且 nr_running <= 1

    worker_set_flags(worker, WORKER_PREP);   // 重新标记为 PREP 状态
sleep:
    worker_enter_idle(worker);               // 进入空闲列表
    __set_current_state(TASK_IDLE);
    raw_spin_unlock_irq(&pool->lock);
    schedule();                              // 主动让出 CPU
    goto woke_up;
}
```

### 5.2 worker 状态机

```
                    ┌─────────────────────────────────────────────────────┐
                    │                  worker 创建                          │
                    │  create_worker() → worker_enter_idle()               │
                    └─────────────────────┬───────────────────────────────┘
                                          │ nr_idle++, 进入 idle_list
                                          ▼
                                   ┌──────────────┐
                                   │   IDLE      │  ← idle_list 链表
                                   └──────┬───────┘
                                          │ wake_up_process()
                                          │ (kick_pool 或 schedule 唤醒)
                                          ▼
                                   ┌──────────────┐
                  ┌────────────────│ PREP         │  正在准备，nr_idle--
                  │                └──────┬───────┘
                  │                       │ need_more_worker() && may_start_working()
                  │                       ▼
                  │                ┌──────────────┐
                  │                │  RUNNING    │  nr_running++, 执行 work
                  │                └──────┬───────┘
                  │                       │ work 执行完毕
                  │                       ▼
                  │              keep_working() ? ──yes──┐
                  │                       │ no           │
                  │                       ▼              │
                  │              WORKER_PREP             │
                  │                       │              │
                  │                       └───back───────┘
                  │
                  │  (pool 有太多 idle workers) idle_cull_fn() 超时触发
                  │  或 worker_detach_from_pool() 被调用
                  ▼
            ┌──────────────┐
            │     DIE      │  worker 从 workers 链表移除，kthread 退出
            └──────────────┘
```

### 5.3 核心判断函数

| 函数 | 条件 | 用途 |
|------|------|------|
| `need_more_worker(pool)` | `!list_empty(&pool->worklist) && !pool->nr_running` | 是否有 work 需要 worker |
| `may_start_working(pool)` | `pool->nr_idle > 0` | 是否有可用 idle worker |
| `keep_working(pool)` | `!list_empty(&pool->worklist) && pool->nr_running <= 1` | 当前 worker 是否应继续执行 |
| `need_to_create_worker(pool)` | `need_more_worker(pool) && !may_start_working(pool)` | 是否需要创建新 worker |
| `too_many_workers(pool)` | `nr_idle > 2 && (nr_idle-2) * 4 >= nr_busy` | 是否有过多 idle worker |

### 5.4 `manage_workers` — manager 线程的职责

**任意一个 worker 在执行 work 之前都可能担任 manager 角色**，但同一时刻每个 pool 只能有一个 manager。Manager 角色的获取是原子的（`POOL_MANAGER_ACTIVE` flag）：

```c
// workqueue.c line 3168
static bool manage_workers(struct worker *worker)
{
    struct worker_pool *pool = worker->pool;
    if (pool->flags & POOL_MANAGER_ACTIVE)
        return false;   // 已有 manager，直接返回

    pool->flags |= POOL_MANAGER_ACTIVE;
    pool->manager = worker;

    maybe_create_worker(pool);   // ← 创建新 worker

    pool->manager = NULL;
    pool->flags &= ~POOL_MANAGER_ACTIVE;
    rcuwait_wake_up(&manager_wait);
    return true;
}
```

### 5.5 `maybe_create_worker` — 按需创建 worker

```c
// workqueue.c line 3090
static void maybe_create_worker(struct worker_pool *pool)
{
restart:
    raw_spin_unlock_irq(&pool->lock);  // 先释放锁（create_worker 可能阻塞）

    mod_timer(&pool->mayday_timer, jiffies + MAYDAY_INITIAL_TIMEOUT);  // 10ms 后可能发 SOS

    while (true) {
        if (create_worker(pool) || !need_to_create_worker(pool))
            break;   // 成功创建或不再需要则退出循环
        schedule_timeout_interruptible(CREATE_COOLDOWN);  // HZ 后重试
        if (!need_to_create_worker(pool))
            break;
    }

    timer_delete_sync(&pool->mayday_timer);  // 删除 SOS 定时器
    raw_spin_lock_irq(&pool->lock);

    // 再次检查（创建期间可能有新 work 入队）
    if (need_to_create_worker(pool))
        goto restart;  // 继续循环
}
```

**关键洞察**：manager 在释放 pool->lock 后创建新 worker，这期间其他 worker 可能抢走新创建的 worker。这个竞争通过 `goto restart` 重试处理。

### 5.6 work 认领完整流程图

```
worker 被唤醒 (wake_up_process)
    │
    ▼
worker_leave_idle()       nr_idle--, 从 idle_list 移除
    │
    ▼
need_more_worker(pool)? ──no──▶ worker_enter_idle() → schedule() → 睡眠
    │yes
    ▼
may_start_working(pool)? ──no──▶ manage_workers(worker)
    │yes                           ├─ POOL_MANAGER_ACTIVE 已置位？ → return false
    │                               └─ 未置位 → 置位 → maybe_create_worker()
    │                                        ├─ create_worker() → 分配 kthread
    │                                        └─ 可能触发 mayday_timer (10ms SOS)
    ▼
assign_work(work, worker, NULL)  从 pool->worklist 取出 work
    │
    ▼
process_scheduled_works(worker)  执行 worker->scheduled 链表上的所有 work
    │
    ▼
keep_working(pool)? ──yes──▶ 继续从 pool->worklist 取 work 执行
    │no
    ▼
worker_set_flags(worker, WORKER_PREP)
    │
    ▼
worker_enter_idle()  nr_idle++, 进入 idle_list
    │
    ▼
schedule()  睡眠，等待下次 wake_up_process
```

---

## 六、destroy_workqueue 串联

### 6.1 `destroy_workqueue` 完整流程

```c
// workqueue.c line 6011
void destroy_workqueue(struct workqueue_struct *wq)
{
    // Step 1: 从 sysfs 移除
    workqueue_sysfs_unregister(wq);

    // Step 2: 标记正在销毁
    mutex_lock(&wq->mutex);
    wq->flags |= __WQ_DESTROYING;
    mutex_unlock(&wq->mutex);

    // Step 3: 排空所有 work（关键步骤）
    drain_workqueue(wq);           // 等待所有 pwq 的 work 执行完毕

    // Step 4: 停止 rescuer
    if (wq->rescuer) {
        kthread_stop(wq->rescuer->task);   // 强制终止 rescuer 线程
        kfree(wq->rescuer);
        wq->rescuer = NULL;
    }

    // Step 5: 释放所有 pwq
    mutex_lock(&wq_pool_mutex);
    for_each_pwq(pwq, wq) {
        raw_spin_lock_irq(&pwq->pool->lock);
        WARN_ON(pwq_busy(pwq));   // 断言没有 pending work
        raw_spin_unlock_irq(&pwq->pool->lock);
    }
    list_del_rcu(&wq->list);      // 从全局链表移除
    mutex_unlock(&wq_pool_mutex);

    // Step 6: 释放 cpu_pwq 和 dfl_pwq 引用
    rcu_read_lock();
    for_each_possible_cpu(cpu) {
        put_pwq_unlocked(unbound_pwq(wq, cpu));
        RCU_INIT_POINTER(*unbound_pwq_slot(wq, cpu), NULL);
    }
    put_pwq_unlocked(unbound_pwq(wq, -1));
    RCU_INIT_POINTER(*unbound_pwq_slot(wq, -1), NULL);
    rcu_read_unlock();
    // 最后 put_pwq 时触发自动销毁（refcnt 归零）
}
```

### 6.2 `drain_workqueue` — 等待 pending work 执行完毕

```c
// workqueue.c line ~4208
void drain_workqueue(struct workqueue_struct *wq)
{
    unsigned int drain_cnt = 0;

    mutex_lock(&wq->mutex);
    wq->flags |= __WQ_DRAINING;   // 阻止新 work 入队（__queue_work 会 WARN）

    for (;;) {
        bool emptied = true;
        for_each_pwq(pwq, wq) {
            emptied &= pwq_tryinc_nr_active(pwq, true);  // 激活 inactive work
            if (!pwq_is_empty(pwq))
                emptied = false;
        }
        if (emptied)
            break;
        drain_cnt++;
        mutex_unlock(&wq->mutex);
        if (drain_cnt > INT_MAX / HZ)   // 超时保护
            break;
        schedule_timeoutInterruptible(HZ/10);
        mutex_lock(&wq->mutex);
    }

    mutex_unlock(&wq->mutex);

    // 等待所有 work 完成（spin，直到 worklist 彻底清空）
    while (wq_has_sleeper(&wq->first_flusher->done) || ...)
        schedule();
}
```

**关键**：`drain_workqueue` 设置 `__WQ_DRAINING` 标志后：
1. **阻止新 work 入队**（`__queue_work` 会 WARN 并返回）
2. **激活所有 inactive work**（`pwq_tryinc_nr_active`）
3. **spin 等待所有 work 完成**

### 6.3 `cancel_delayed_work_sync` 同步等待原理

```c
// workqueue.c line 4546
bool cancel_delayed_work_sync(struct delayed_work *dwork)
{
    // Step 1: 尝试从 timer 队列取消
    del_timer_sync(&dwork->timer);   // 同步等待 timer 回调完成（如果正在执行）

    // Step 2: 尝试 grab pending 状态
    __cancel_work(&dwork->work, WORK_CANCEL_DELAYED);
        ├─ work_grab_pending(work, ...)  ← 原子地清除 PENDING 位
        └─ set_work_pool_and_clear_pending(work, ...)

    // Step 3: 如果 work 正在执行，等待其完成
    __flush_work(&dwork->work, true);  // 通过插入 barrier work 同步等待
}
```

`del_timer_sync()` 的关键保证：**如果 timer 回调正在执行（在另一个 CPU 的软中断中），会等待其完成才返回**。这确保 delayed work 的回调函数不会在 `cancel_delayed_work_sync()` 返回后继续运行。

`__flush_work()` 通过插入 `wq_barrier` 实现同步等待：

```c
// workqueue.c line 4308
static bool __flush_work(struct work_struct *work, bool from_cancel)
{
    wq_barrier barr;
    if (!start_flush_work(work, &barr, from_cancel))
        return false;   // work 已经不在队列中

    // 如果 work 在 BH wq 上执行，busy-wait（因为在 IRQ 上下文不能 sleep）
    if (from_cancel && (data & WORK_OFFQ_BH))
        while (wait_on_bit(&work->data, ...))
            cpu_relax();
    else
        wait_for_completion(&barr.done);  // sleep 等待

    return true;
}
```

---

## 七、WQ_UNBOUND 和 ordered 语义

### 7.1 unbound work 是怎么调度到 CPU 的？

当 `queue_work` 调用 `__queue_work(cpu=WORK_CPU_UNBOUND, wq=unbound_wq, work)` 时：

```c
// Step 1: CPU 选择
if (req_cpu == WORK_CPU_UNBOUND) {
    if (wq->flags & WQ_UNBOUND)
        cpu = wq_select_unbound_cpu(raw_smp_processor_id());  // RR 选择
    else
        cpu = raw_smp_processor_id();  // per-CPU wq
}

// Step 2: 获取该 CPU 对应的 pwq
pwq = rcu_dereference(*per_cpu_ptr(wq->cpu_pwq, cpu));
pool = pwq->pool;  // unbound pool
```

**关键**：`wq_select_unbound_cpu()` 对 unbound wq 执行 round-robin CPU 选择：

```c
// workqueue.c line 2255
static int wq_select_unbound_cpu(int cpu)
{
    if (!wq_debug_force_rr_cpu &&
        cpumask_test_cpu(cpu, wq_unbound_cpumask))
        return cpu;  // 优先用当前 CPU（如果在 wq_unbound_cpumask 中）

    // 否则 round-robin
    new_cpu = __this_cpu_read(wq_rr_cpu_last);
    new_cpu = cpumask_next_and_wrap(new_cpu, wq_unbound_cpumask, ...);
    __this_cpu_write(wq_rr_cpu_last, new_cpu);
    return new_cpu;
}
```

unbound wq 的 **pwq 是 per-CPU 的**（`wq->cpu_pwq` 是 `percpu` 数组），但执行 work 的 **worker 线程是 unbound 的**（`WORKER_UNBOUND` 标志，`kthread_set_per_cpu(task, -1)`），worker 可以在任意允许的 CPU 上运行。

### 7.2 `system_unbound_wq` vs `system_highpri_wq` 的区别

```c
// workqueue.c line ~8075
system_unbound_wq = alloc_workqueue("events_unbound",
                                      WQ_UNBOUND, WQ_MAX_ACTIVE);  // unbound, max_active=2048
system_highpri_wq = alloc_workqueue("events_highpri",
                                      WQ_HIGHPRI | WQ_PERCPU, 0);  // per-CPU, highpri
```

| 属性 | `system_unbound_wq` | `system_highpri_wq` |
|------|---------------------|----------------------|
| 绑定方式 | `WQ_UNBOUND` | `WQ_PERCPU` |
| max_active | `WQ_MAX_ACTIVE`(2048) | 0（默认 1024） |
| 使用的 pool | `unbound_pool_hash` 动态 pool | `cpu_worker_pools[cpu][1]`（highpri） |
| nice 值 | 默认（0） | `HIGHPRI_NICE_LEVEL = MIN_NICE`(-20) |
| CPU亲和性 | `wq_unbound_cpumask` | 绑定到特定 CPU |

`system_highpri_wq` 的 worker 有 **更高优先级**（nice=-20），调度器会优先执行它们。

### 7.3 ordered work 保证了什么？

```c
WQ_ORDERED  // 保证 FIFO 顺序，同一时间最多 1 个 work 执行
```

ordered wq 的实现：

1. **只创建一个 pwq**（`ordered_wq_attrs`），所有 CPU 共享
2. **`max_active = 1`**：`pwq->nr_active` 最多为 1
3. 超过 1 个 work 入队时，多余的进入 `pwq->inactive_works` 等待
4. `__WQ_ORDERED` 标志阻止了"从旧 pool 偷 work 到新 pwq"的优化（line 2333: `last_pool != pool && !(wq->flags & __WQ_ORDERED)`）

---

## 八、pwq 和 rescuer

### 8.1 pool_workqueue 的 max_active 限制

```c
// __queue_work 中的逻辑
if (list_empty(&pwq->inactive_works) && pwq_tryinc_nr_active(pwq, false)) {
    // nr_active < max_active → 直接入 pool->worklist 执行
    insert_work(pwq, work, &pool->worklist, work_flags);
} else {
    // nr_active 已达上限 → 入 pwq->inactive_works 等待
    insert_work(pwq, work, &pwq->inactive_works, work_flags | WORK_STRUCT_INACTIVE);
}
```

当 work 执行完毕，`pwq_dec_nr_active()` 会检查 `pwq->inactive_works` 并可能唤醒一个等待中的 work：

```c
pwq_dec_nr_active()
    └─ if (pwq_activate_first_inactive(pwq))
           kick_pool(pool);   // 唤醒 worker 处理
```

### 8.2 rescuer 线程触发时机

**rescuer 是专门处理内存紧张场景的线程**，只有带 `WQ_MEM_RECLAIM` 标志的 workqueue 才会分配 rescuer（line ~5683）：

```c
static int init_rescuer(struct workqueue_struct *wq)
{
    if (!(wq->flags & WQ_MEM_RECLAIM))
        return 0;   // 只有 WQ_MEM_RECLAIM wq 才有 rescuer

    rescuer = alloc_worker(NUMA_NO_NODE);
    rescuer->task = kthread_create(rescuer_thread, rescuer, "%s", id_buf);
    kthread_bind_mask(rescuer->task, wq_unbound_cpumask);
    wake_up_process(rescuer->task);
}
```

**触发场景**：当 `maybe_create_worker` 中的 `create_worker` **分配失败**时：

1. `pool->mayday_timer`（10ms 后）到期
2. `pool_mayday_timeout()` 调用 `send_mayday()` 将相关 pwq 加入 `wq->maydays`
3. `wake_up_process(wq->rescuer->task)` 唤醒 rescuer
4. rescuer 执行 `assign_rescuer_work()` **直接运行 work**（不走正常的 worker pool）

**高内存压力下 delayed work 被 skip 的原因**：

`delayed_work` 的 timer 基于 `add_timer_on()` 或 `add_timer_global()`。在内存紧张时：
- 如果 timer 分配或调度失败，`add_timer()` 返回非零（失败）
- 此时 `__queue_delayed_work` 中 timer 可能未能正确注册，导致 work 永远不会被执行
- 内存压力也可能导致 `__queue_work` 分配失败（`pwq` 引用计数更新等需要 GFP_KERNEL 分配）

---

## 九、work 和 delayed_work 的区别

### 9.1 `delayed_work` 的 timer 实现

```c
// workqueue.c line 2522
void delayed_work_timer_fn(struct timer_list *t)
{
    struct delayed_work *dwork = from_timer(dwork, t, timer);
    __queue_delayed_work(dwork->cpu, dwork->wq, dwork, 0);
        └─ __queue_work(cpu, wq, &dwork->work)  // delay=0，直接入队
}

// __queue_delayed_work
if (!delay) {
    __queue_work(cpu, wq, &dwork->work);  // 立即入队
    return;
}
dwork->wq = wq;
dwork->cpu = cpu;
timer->expires = jiffies + delay;
add_timer_on(timer, cpu);  // 或 add_timer_global()
```

**流程图**：

```
queue_delayed_work_on()
    │
    ├─ delay == 0 ?
    │     yes → __queue_work() 直接入队，立即执行
    │     no
    │         ▼
    │    dwork->wq = wq, dwork->cpu = cpu
    │    timer->expires = jiffies + delay
    │    add_timer_on(timer, cpu)  ← timer 开始计时
    │
    ▼
timer 到期 (jiffies + delay)
    │
    ▼
delayed_work_timer_fn()
    │
    ▼
__queue_delayed_work(delay=0)  ← 将 work 立即推入 workqueue
    │
    ▼
__queue_work() → insert_work() → kick_pool()
    │
    ▼
worker 执行 work->func()
```

### 9.2 `INIT_DELAYED_WORK` vs `DECLARE_DELAYED_WORK`

```c
#define __DELAYED_WORK_INITIALIZER(n, f, tflags) {           \
    .work = __WORK_INITIALIZER((n).work, (f)),              \
    .timer = __TIMER_INITIALIZER(delayed_work_timer_fn,     \
                 (tflags) | TIMER_IRQSAFE),                 \
}
```

timer 的 `TIMER_IRQSAFE` 标志确保 timer 回调在中断上下文安全执行。`TIMER_DEFERRABLE`（`DECLARE_DEFERRABLE_WORK`）的 timer 不会阻止系统挂起。

---

## 十、总结：完整流程总览

### 10.1 work 生命周期状态机

```
  分配 work_struct
        │
        ▼
  INIT_WORK() / DECLARE_WORK()
        │
        ▼
  queue_work(wq, work)              work_struct 数据布局：
        │                            [ pool_id | disable | OFFQ | flags ]
  test_and_set_bit(PENDING) ← 原子设置，防止重复入队
        │
        ▼
  __queue_work()
        │
        ├─ [max_active 未达限] ─→ insert_work(pwq, work, pool->worklist)
        │                              │
        │                         kick_pool(pool) → wake_up_process(idle_worker)
        │
        └─ [max_active 已满] ─→ insert_work(pwq, work, pwq->inactive_works)
                                   (WORK_STRUCT_INACTIVE 标志)

        ▼
  worker 执行
        │
        ▼
  process_one_work()
        │
        ├─ 找到执行本 work 的 worker（busy_hash）
        ├─ 记录 current_pwq
        ├─ 清除 PENDING 位（set_work_pool_and_clear_pending）
        ├─ 执行 work->func()
        └─ work 完成后 pwq_dec_nr_active() → 可能激活 inactive work

        ▼
  work 执行完毕（可能在任意 CPU 上）
```

### 10.2 并发管理的关键设计

1. **lock 层级**：`pool->lock`（核心）→ `wq->mutex`（workqueue 属性）→ `wq_pool_mutex`（全局 pool 管理）
2. **nr_running 计数器**：记录 pool 上正在运行的 worker 数，用于并发管理
3. **idle_list**：空闲 worker 链表，`kick_pool` 优先从头部取 worker（最新空闲的）
4. **busy_hash**：正在执行的 worker，以 work_struct 地址为 key，用于 work 迁移和 flush
5. **manager 角色**：避免多个 worker 同时执行 `maybe_create_worker`（通过 `POOL_MANAGER_ACTIVE`）
6. **mayday 机制**：worker 创建失败时触发 SOS，rescuer 接管紧急 work 执行
