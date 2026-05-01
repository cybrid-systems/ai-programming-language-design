# Linux 定时器子系统深度分析：hrtimer / timerfd / nohz

> 内核版本：Linux 7.0-rc1 (commit 验证于 /home/dev/code/linux)
> 源码分析基于：kernel/time/hrtimer.c, fs/timerfd.c, include/linux/hrtimer.h, kernel/time/tick-sched.c

## 1. hrtimer 的红黑树存储结构

### 1.1 per-CPU clock_base 数组

每个 CPU 维护一个 `struct hrtimer_cpu_base`（per-CPU 变量 `hrtimer_bases`），其中包含 8 个 `struct hrtimer_clock_base`：

```c
DEFINE_PER_CPU(struct hrtimer_cpu_base, hrtimer_bases) =
{
    .lock = __RAW_SPIN_LOCK_UNLOCKED(hrtimer_bases.lock),
    .clock_base = {
        [HRTIMER_BASE_MONOTONIC]       = { .clockid = CLOCK_MONOTONIC },
        [HRTIMER_BASE_REALTIME]       = { .clockid = CLOCK_REALTIME },
        [HRTIMER_BASE_BOOTTIME]       = { .clockid = CLOCK_BOOTTIME },
        [HRTIMER_BASE_TAI]            = { .clockid = CLOCK_TAI },
        [HRTIMER_BASE_MONOTONIC_SOFT] = { .clockid = CLOCK_MONOTONIC },
        [HRTIMER_BASE_REALTIME_SOFT]  = { .clockid = CLOCK_REALTIME },
        [HRTIMER_BASE_BOOTTIME_SOFT]  = { .clockid = CLOCK_BOOTTIME },
        [HRTIMER_BASE_TAI_SOFT]       = { .clockid = CLOCK_TAI },
    },
    .csd = CSD_INIT(retrigger_next_event, NULL)
};
```

**为什么要分 HARD 和 SOFT？** HARD timer 在硬中断上下文执行回调，SOFT timer 在软中断（`HRTIMER_SOFTIRQ`）执行。在 PREEMPT_RT 内核上，大量 SOFT timer 能有效降低实时延迟，因为软中断允许被更高优先级任务抢占。

### 1.2 timerqueue 红黑树

每个 `hrtimer_clock_base` 的 `active` 字段是 `struct timerqueue_linked_head`，底层实现是**红黑树**（依赖 `linux/rbtree.h` 和 `linux/timerqueue.h`）：

```c
struct hrtimer_clock_base {
    struct hrtimer_cpu_base     *cpu_base;
    const unsigned int          index;
    const clockid_t             clockid;
    seqcount_raw_spinlock_t     seq;
    ktime_t                     expires_next;   // 本 base 的下一个到期时间
    struct hrtimer              *running;      // 当前正在执行的 timer
    struct timerqueue_linked_head active;      // 红黑树根节点
    ktime_t                     offset;        // 到 MONOTONIC 的偏移
};
```

**为什么不选择链表或堆？**

| 数据结构 | 插入 | 查询最近 | 退订 |
|---------|------|---------|------|
| 链表 | O(1) | O(n) | O(n) 或 O(1) if 已知节点 |
| 堆（优先级队列） | O(log n) | O(1)（min-heap）| O(n) |
| **红黑树** | **O(log n)** | **O(1)（最左节点）** | **O(log n）** |

Linux 选择红黑树的核心原因：**`__hrtimer_run_queues` 每次中断需要 O(1) 找到最近过期的 timer**，同时需要 O(log n) 插入和删除。红黑树在两者之间取得平衡。相比堆，红黑树的优势是**可以直接定位最左节点**（即最小到期时间），不需要额外的 Decrease-Key 操作。

### 1.3 timerqueue_node 与 rb_node 的关系

```c
struct timerqueue_node {
    struct rb_node node;
    ktime_t expires;
};

struct timerqueue_linked_head {
    struct rb_root_cached rb_root;  // 包含最左节点缓存
    ...
};
```

`struct hrtimer` 嵌入 `struct timerqueue_node`（通过 `hrtimer->node`），timerqueue 将 `rb_node` 作为链表节点使用。

### 1.4 __hrtimer_hanging_atom（延迟溢出问题）

在老版本内核中曾使用 `__hrtimer_hanging_atom` 来描述"一个 timer 在中断中被发现已过期，但因处理耗时导致下一个中断仍在过期时间之后"的问题。Linux 7.0-rc1 使用 **CONFIG_HRTIMER_REARM_DEFERRED** 机制解决：

```c
// hrtimer.c:2063
void hrtimer_interrupt_rearm(struct hrtimer_cpu_base *cpu_base, ktime_t expires_next)
{
    /* 缓存下次到期时间，避免在中断上下文重新计算 */
    cpu_base->deferred_expires_next = expires_next;
    set_thread_flag(TIF_HRTIMER_REARM);  // 延迟到用户空间重新设置
}
```

`TIF_HRTIMER_REARM` 是一个线程标志，在下一次用户空间调度时才会重新编程硬件定时器。这种设计**避免了频繁的硬件重编程开销**（在 VM 环境中尤其昂贵），代价是可能错过一个精确的到期时刻（懒性重排，lazy rear。

## 2. nohz_mode 和 tick_sched

### 2.1 struct tick_sched

```c
struct tick_sched {
    struct hrtimer    sched_timer;   // 替代普通 tick 的 hrtimer
    unsigned long     last_jiffies;
    u64               timer_expires_base;
    u64               timer_expires;  // 预期到期时间（tick 停止时）
    ktime_t           idle_entrytime; // CPU 进入 idle 的时间
    ...
};
```

`sched_timer` 是 `tick_sched` 的核心——它是一个 hrtimer，用来在 nohz 模式下替代传统的 jiffies tick。

### 2.2 tick_nohz_get_sleep_len 路径

```
用户: tick_nohz_get_sleep_length(&delta_next)
  -> tick_nohz_next_event(ts, cpu)        // tick-sched.c:935
       -> get_next_timer_interrupt()      // 查找下一个 timer wheel 事件
       -> hrtimer_next_event_without(&ts->sched_timer)  // 排除 sched_timer 本身
       -> 返回 max(硬件下一个事件, hrtimer下一个事件)
```

```c
ktime_t tick_nohz_get_sleep_length(ktime_t *delta_next)
{
    struct tick_sched *ts = this_cpu_ptr(&tick_cpu_sched);
    ktime_t now = ts->idle_entrytime;
    struct clock_event_device *dev = __this_cpu_read(tick_cpu_device.evtdev);

    *delta_next = ktime_sub(dev->next_event, now);
    if (!can_stop_idle_tick(cpu, ts))
        return *delta_next;

    next_event = tick_nohz_next_event(ts, cpu);
    next_event = min_t(u64, next_event,
               hrtimer_next_event_without(&ts->sched_timer));

    return ktime_sub(next_event, now);
}
```

**核心逻辑**：sleep_len = min(next_timer_event, next_hrtimer) - idle_entry_time。它保证了即使在 NO_HZ_FULL 模式下，也不会漏掉任何 timer 事件。

### 2.3 nohz_idle_balance 和 housekeeping CPUs

```c
// sched/fair.c:12956
static bool nohz_idle_balance(struct rq *this_rq, enum cpu_idle_type idle)
{
    unsigned int flags = this_rq->nohz_idle_balance;
    this_rq->nohz_idle_balance = 0;
    _nohz_idle_balance(this_rq, flags);
}

static inline struct hrtimer_cpu_base *get_target_base(...) {
    if (!hrtimer_base_is_online(base)) {
        int cpu = cpumask_any_and(cpu_online_mask, housekeeping_cpumask(HK_TYPE_TIMER));
        return &per_cpu(hrtimer_bases, cpu);
    }
    if (static_branch_likely(&timers_migration_enabled) && !pinned)
        return &per_cpu(hrtimer_bases, get_nohz_timer_target());
    return base;
}
```

当一个 CPU 离线或进入长时间 idle，其 hrtimer 需要迁移到 `housekeeping_cpumask(HK_TYPE_TIMER)` 中的某个 CPU。`nohz_idle_balance` 在 idle 退出时将 flags 清零并触发实际的迁移操作。

## 3. hrtimer_interrupt 完整调用链

### 3.1 ASCII 调用图

```
硬件定时器中断 (LOC)
    |
    v
hrtimer_interrupt(dev)                 [hrtimer.c:2083]
    |
    +-- hrtimer_update_base(cpu_base)   // 更新时间基准（更新各 clock offset）
    |
    +-- cpu_base->expires_next = KTIME_MAX  // 防止远程 CPU 在运行期间入队
    |
    +-- [if softirq 需要触发]
    |       raise_timer_softirq(HRTIMER_SOFTIRQ)
    |           |
    |           v
    |       hrtimer_run_softirq()       [hrtimer.c:2001]
    |           |
    |           v
    |       __hrtimer_run_queues(, HRTIMER_ACTIVE_SOFT)
    |
    +-- __hrtimer_run_queues(, HRTIMER_ACTIVE_HARD)   [hrtimer.c:1968]
    |       for_each_active_base(base, cpu_base, active):
    |           basenow = ktime_add(now, base->offset)
    |           while (timer = clock_base_next_timer(base)) {
    |               if (basenow < hrtimer_get_softexpires(timer)) break;
    |               __run_hrtimer(cpu_base, base, timer, basenow, flags);
    |           }
    |
    +-- hrtimer_update_next_event(cpu_base)  // 找到下一个到期 timer
    |       __hrtimer_get_next_event(cpu_base, HRTIMER_ACTIVE_HARD)
    |       __hrtimer_get_next_event(cpu_base, HRTIMER_ACTIVE_SOFT)
    |
    +-- hrtimer_interrupt_rearm(cpu_base, expires_next)  [hrtimer.c:2063]
            |
            +-- (CONFIG_HRTIMER_REARM_DEFERRED)
            |       cpu_base->deferred_expires_next = expires_next
            |       set_thread_flag(TIF_HRTIMER_REARM)  // 用户空间延迟重排
            +-- (!CONFIG_HRTIMER_REARM_DEFERRED)
                    hrtimer_rearm(cpu_base, expires_next, false)
                        -> hrtimer_rearm_event(expires_next, false)
                            -> 写硬件寄存器
```

### 3.2 clock_base_next_timer（找到即将到期的 timer）

```c
static __always_inline struct hrtimer *
clock_base_next_timer(struct hrtimer_clock_base *base)
{
    struct timerqueue_linked_node *node;

    if (!timerqueue_linked_head_has_active(&base->active))
        return NULL;

    node = timerqueue_linked_first(&base->active);
    return hrtimer_from_timerqueue_node(node);
}
```

这里利用了 timerqueue 的特性：**最左节点就是最小到期时间**。rb_tree 最左节点的查询是 O(1)，因为 `rb_root_cached` 缓存了最左节点。

### 3.3 skip_hrtimer 和 reprogram 的关系

`hrtimer_interrupt_rearm` 中的 `TIF_HRTIMER_REARM` 机制实现了一种"skip"优化：硬件 timer 被设置为下一次到期时间，但如果在用户空间重评诂时发现 timer 已经被取消或迁移，则可以跳过不必要的硬件重编程。相比每次都强制重编程，这种方式在 VM 环境中可节省大量 VM-Exit 开销。

## 4. timerfd 完整串联

### 4.1 timerfd_create 调用链

```
SYSCALL timerfd_create(clockid, flags)   [timerfd.c:394]
    |
    +-- 检查 clockid 必须是以下之一：
    |       CLOCK_MONOTONIC / CLOCK_REALTIME /
    |       CLOCK_REALTIME_ALARM / CLOCK_BOOTTIME / CLOCK_BOOTTIME_ALARM
    |
    +-- 检查 ALARM 类型需要 CAP_WAKE_ALARM
    |
    +-- anon_inode_getfd()  // 获取匿名 inode fd
    |
    +-- ctx = kzalloc(sizeof(*ctx), GFP_KERNEL)
    |       ctx->clockid = clockid     // ★ 记录 clockid
    |       ctx->wqh = __wait_queue_head  // 等待队列
    |
    +-- if (clockid == CLOCK_REALTIME_ALARM || CLOCK_BOOTTIME_ALARM)
    |       alarm_init(&ctx->t.alarm, alarm_type, timerfd_alarmproc)
    |       // 使用 alarmtimer子系统，而非 hrtimer
    |   else
    |       hrtimer_setup(&ctx->t.tmr, timerfd_tmrproc,
    |                      clockid, HRTIMER_MODE_ABS)
            // clockid 直接传入 hrtimer_setup，决定使用哪个 clock_base
```

### 4.2 timerfd_setup 和 hrtimer 绑定

```c
static int timerfd_setup(struct timerfd_ctx *ctx, int flags,
                         const struct itimerspec64 *ktmr)
{
    clockid = ctx->clockid;  // 继承自 timerfd_create
    htmode = (flags & TFD_TIMER_ABSTIME) ?
        HRTIMER_MODE_ABS : HRTIMER_MODE_REL;

    if (isalarm(ctx)) {
        alarm_init(&ctx->t.alarm, alarm_type, timerfd_alarmproc);
    } else {
        hrtimer_setup(&ctx->t.tmr, timerfd_tmrproc, clockid, htmode);
        // ★ clockid 决定 timer 插入哪个 clock_base
        // ★ CLOCK_MONOTONIC → HRTIMER_BASE_MONOTONIC
        // ★ CLOCK_REALTIME → HRTIMER_BASE_REALTIME
        hrtimer_set_expires(&ctx->t.tmr, texp);
    }

    if (texp != 0) {
        if (isalarm(ctx))
            alarm_start(...);
        else
            hrtimer_start(&ctx->t.tmr, texp, htmode);
    }
}
```

### 4.3 timerfd_tmrproc 触发路径

```
hrtimer到期 → hrtimer_interrupt → __hrtimer_run_queues
    → __run_hrtimer → timerfd_tmrproc(ctx->t.tmr)
        → timerfd_triggered(ctx)
            → ctx->expired = 1
            → ctx->ticks++
            → wake_up_locked_poll(&ctx->wqh, EPOLLIN)
                → 唤醒 poll()/read() 的进程
```

### 4.4 timerfd 和 posix_timer 的关系

timerfd 是 Linux 特有的文件描述符 fd 接口，而 POSIX timer (`timer_create`) 是 POSIX 标准接口。两者共享底层的 `hrtimer` 或 `alarm` 机制：

```
posix_timer_create() → 使用 clock_gettime() 的 clockid
    → 创建 struct k_itimer
    → 内部使用 hrtimer 或 alarm

timerfd_create() → 直接操作 hrtimer/alarm
    → 通过 fd 提供 poll/read 接口
```

核心共享代码路径：
- `hrtimer_setup()` / `hrtimer_start()`
- `alarm_init()` / `alarm_start()`
- `timerfd_clock_was_set()` —— 时钟设置时同时通知所有 timerfd

## 5. timers 子系统和 clock_gettime 关系

### 5.1 clock_was_set_delayed 的作用

当系统时间被 `clock_settime()` 修改时，`CLOCK_REALTIME` 和 `CLOCK_TAI` 的 offset 会发生变化：

```c
void clock_was_set(unsigned int bases)   [hrtimer.c:966]
{
    cpumask_var_t mask;

    if (!hrtimer_highres_enabled() && !tick_nohz_is_active())
        goto out_timerfd;

    for_each_online_cpu(cpu) {
        if (update_needs_ipi(cpu_base, bases))
            cpumask_set_cpu(cpu, mask);
    }
    smp_call_function_many(mask, retrigger_next_event, NULL, 1);

out_timerfd:
    timerfd_clock_was_set();  // 唤醒所有 CLOCK_REALTIME 的 timerfd
}
```

`clock_was_set_delayed()` 将实际工作延迟到 workqueue 中执行，避免在时钟设置的关键路径上阻塞：

```c
void clock_was_set_delayed(void)
{
    schedule_work(&hrtimer_work);  // work: clock_was_set_work → clock_was_set(CLOCK_SET_WALL)
}
```

### 5.2 CLOCK_MONOTONIC / REALTIME 的 offset 机制

```
hrtimer_update_base(cpu_base)
    -> ktime_get_update_offsets_now(&base->clock_was_set_seq, offs_real, ...)
    -> base->clock_base[REALTIME].offset = 实际墙上时钟 - MONOTONIC
       (仅当 clock_was_set_seq 发生变化时更新)
```

因此 `CLOCK_REALTIME` timer 的 `expires` 是绝对墙上时间，而 `hrtimer_interrupt` 在比较时会用 `basenow = now + base->offset` 来补偿。

### 5.3 posix_get_monitor_times（查询 timer 信息）

在 `hrtimer.c` 中有 `clock_gettime` 相关的 `__hrtimer_get_remaining` 路径，但 `posix_get_monitor_times` 主要用于 POSIX timer fdinfo 接口中展示每个 timer's 到期时间，不是内核直接暴露的系统调用。

## 6. 定时器 和 workqueue 的本质区别

### 6.1 时间精度对比

| 维度 | hrtimer | tasklet | workqueue |
|------|---------|---------|-----------|
| 时间基准 | 纳秒（ktime_t） | 软中断批处理 | jiffies |
| 调度精度 | 硬件决定（CLOCK_EVT） | 软中断批次 | 取决于 queue 优先级 |
| 最小精度 | 几乎等于硬件精度 | 受软中断 latency 影响 | 1 jiffy（通常 1ms 或 4ms） |
| 上下文 | 硬中断或软中断 | 软中断 | 进程上下文 |

### 6.2 hrtimer vs tasklet

```
hrtimer: 硬中断（TIF_HRTIMER_REARM）或软中断直接触发
         callback 执行时间 = 中断到达时间 + 处理延迟
         在 hrtimer_interrupt 中 __run_hrtimer 同步执行

tasklet: 在软中断入口 `tasklet_action` 中串行执行
         延迟取决于当前软中断队列长度
         无法保证精确时间，只能保证顺序
```

**tasklet 的本质**：一个在软中断上下文中串行执行的回调链表。与 hrtimer 的根本区别是 hrtimer 有独立的硬件到期时间，而 tasklet 依赖软中断触发。

### 6.3 hrtimer vs workqueue

```
hrtimer:  原子上下文（hardirq/softirq），不能 sleeping
          用于驱动层、网络协议栈定时事件
          精度：微秒/纳秒级

workqueue: 进程上下文，可以 sleep、schedule、获取信号
           用于延后工作（如 driver shutdown、内存回收）
           精度：jiffies 级，最小延迟 ~1ms（取决于 HZ）
```

## 7. 迁移和亲和性：CPU idle 时 hrtimer 的迁移

### 7.1 migration_base 的角色

```c
static struct hrtimer_cpu_base migration_cpu_base = {
    .clock_base = {
        [0] = {
            .cpu_base = &migration_cpu_base,  // 自引用
            .seq = SEQCNT_RAW_SPINLOCK_ZERO(...),
        },
    },
};
#define migration_base migration_cpu_base.clock_base[0]
```

`migration_base` 是一个特殊的"临时停放站"。当 timer 需要从一个 CPU 迁移到另一个时：

```c
// switch_hrtimer_base() 中
WRITE_ONCE(timer->base, &migration_base);  // 临时设为 migration_base
raw_spin_unlock(&old_base->lock);
raw_spin_lock(&new_base->cpu_base->lock);  // 获取新 CPU 的锁
WRITE_ONCE(timer->base, new_base);         // 完成迁移
```

`migration_base` 的 `cpu_base` 指向自己，解决了"在持有旧锁时无法引用新 base"的跨 CPU 同步问题。

### 7.2 switch_hrtimer_base 的迁移决策

```c
static inline struct hrtimer_clock_base *
switch_hrtimer_base(struct hrtimer *timer, struct hrtimer_clock_base *base, bool pinned)
{
    new_cpu_base = get_target_base(this_cpu_base, pinned);
    new_base = &new_cpu_base->clock_base[basenum];

    if (base != new_base) {
        if (unlikely(hrtimer_callback_running(timer)))
            return base;  // callback 正在运行，不迁移
        // ... 使用 migration_base 中转 ...
    }
}
```

### 7.3 hrtimer_cpu_dying 中的批量迁移

```c
int hrtimers_cpu_dying(unsigned int dying_cpu)
{
    ncpu = cpumask_any_and(cpu_active_mask, housekeeping_cpumask(HK_TYPE_TIMER));
    old_base = this_cpu_ptr(&hrtimer_bases);
    new_base = &per_cpu(hrtimer_bases, ncpu);

    raw_spin_lock(&old_base->lock);
    raw_spin_lock_nested(&new_base->lock, SINGLE_DEPTH_NESTING);

    for (int i = 0; i < HRTIMER_MAX_CLOCK_BASES; i++)
        migrate_hrtimer_list(&old_base->clock_base[i], &new_base->clock_base[i]);

    smp_call_function_single(ncpu, retrigger_next_event, NULL, 0);  // 通知新 CPU 重编程

    raw_spin_unlock(&new_base->lock);
    raw_spin_unlock(&old_base->lock);
}
```

### 7.4 nohz_idle_balance 触发时机

```
CPU 进入 idle
    -> schedule()
        -> idle_balance()
            -> nohz_idle_balance(rq, idle)
                -> _nohz_idle_balance(rq, flags)
                    -> migrate_hrtimers / retrigger_next_event
                        -> smp_call_function_many(...) // 通知其他 CPU
```

在 NO_HZ_FULL 模式下，只有 housekeeping CPU 处理 tick，不承担任务的 CPU 可以长期处于 idle 且不被打断。`timers_migration_enabled` key 控制是否开启 timer 迁移功能。

## 附录：关键数据结构一览

```
hrtimer_cpu_base (per-CPU)
  ├── lock: raw_spinlock_t
  ├── clock_base[8]: hrtimer_clock_base
  │     ├── active: timerqueue_linked_head (红黑树根)
  │     ├── expires_next: ktime_t
  │     ├── running: struct hrtimer* (当前执行中)
  │     ├── offset: ktime_t (相对 MONOTONIC 的偏移)
  │     └── clockid: CLOCK_MONOTONIC/REALTIME/...
  ├── expires_next: ktime_t (hard+soft 综合)
  ├── next_timer: struct hrtimer* (最近过期的 timer 指针)
  ├── softirq_expires_next: ktime_t
  └── softirq_next_timer: struct hrtimer*

hrtimer (嵌入 timerqueue_node)
  ├── node: timerqueue_linked_node (含 rb_node)
  ├── _softexpires: ktime_t (软到期时间)
  ├── function: enum hrtimer_restart (*)(struct hrtimer *)
  └── base: struct hrtimer_clock_base* (指向所属 base)

tick_sched (per-CPU)
  ├── sched_timer: struct hrtimer (替代普通 tick)
  ├── idle_entrytime: ktime_t
  ├── timer_expires: u64
  └── last_jiffies: unsigned long

timerfd_ctx
  ├── t.tmr: struct hrtimer  (或 t.alarm: struct alarm)
  ├── clockid: int
  ├── ticks: u64
  ├── expired: short
  └── wqh: wait_queue_head_t
```

## 总结

Linux 定时器子系统是一个分层的精密系统：

1. **硬件层**：`clock_event_device` 驱动提供精确的硬件定时器中断
2. **hrtimer 层**：per-CPU 红黑树存储，按 clockid 分类，支持 nanosecond 精度
3. **deferred rearm**：通过 TIF_HRTIMER_REARM 避免频繁 VM-Exit，降低 VM 开销
4. **timerfd 层**：将 hrtimer/alarm 封装为 fd 接口，支持 poll/read，统一了 Linux timer 抽象
5. **nohz 层**：tick_sched + housekeeping CPU design，使得非关键 CPU 可以真正 idle
6. **migration 层**：migration_base + nohz_idle_balance 确保在 CPU hotplug 时 timer 不丢失

---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `kernel/time/hrtimer.c` | 156 | 0 | 113 | 23 |

### 关键函数

- **retrigger_next_event** `hrtimer.c:91`
- **__hrtimer_cb_get_time** `hrtimer.c:92`
- **hrtimer_base_is_online** `hrtimer.c:122`
- **hrtimer_hres_workfn** `hrtimer.c:133`
- **hrtimer_schedule_hres_work** `hrtimer.c:140`
- **lock_hrtimer_base** `hrtimer.c:183`
- **hrtimer_suitable_target** `hrtimer.c:215`
- **get_target_base** `hrtimer.c:242`
- **switch_hrtimer_base** `hrtimer.c:269`
- **ktime_add_safe** `hrtimer.c:363`
- **ktime_add_safe** `hrtimer.c:377`
- **debug_hrtimer_init** `hrtimer.c:506`
- **debug_hrtimer_init_on_stack** `hrtimer.c:507`
- **debug_hrtimer_activate** `hrtimer.c:508`
- **debug_hrtimer_deactivate** `hrtimer.c:509`
- **debug_hrtimer_assert_init** `hrtimer.c:510`
- **debug_setup** `hrtimer.c:513`
- **debug_setup_on_stack** `hrtimer.c:519`
- **debug_activate** `hrtimer.c:526`
- **hrtimer_bases_next_event_without** `hrtimer.c:544`
- **clock_base_next_timer** `hrtimer.c:579`
- **hrtimer_bases_first** `hrtimer.c:587`
- **__hrtimer_get_next_event** `hrtimer.c:622`
- **hrtimer_update_next_event** `hrtimer.c:646`
- **hrtimer_update_base** `hrtimer.c:677`
- **hrtimer_hres_active** `hrtimer.c:698`
- **hrtimer_rearm_event** `hrtimer.c:704`
- **__hrtimer_reprogram** `hrtimer.c:710`
- **hrtimer_force_reprogram** `hrtimer.c:739`
- **setup_hrtimer_hres** `hrtimer.c:758`
- **hrtimer_is_hres_enabled** `hrtimer.c:765`
- **hrtimer_switch_to_hres** `hrtimer.c:771`
- **retrigger_next_event** `hrtimer.c:808`
- **hrtimer_reprogram** `hrtimer.c:844`
- **update_needs_ipi** `hrtimer.c:902`

### 全局变量

- **hrtimer_bases** `hrtimer.c:106`
- **hrtimer_highres_enabled_key** `hrtimer.c:131`
- **hrtimer_hres_work** `hrtimer.c:138`
- **migration_cpu_base** `hrtimer.c:159`
- **__UNIQUE_ID_addressable_ktime_add_safe_4** `hrtimer.c:377`
- **hrtimer_hres_enabled** `hrtimer.c:753`
- **hrtimer_resolution** `hrtimer.c:754`
- **hrtimer_resolution** `hrtimer.c:755`
- **__UNIQUE_ID_addressable_hrtimer_resolution_11** `hrtimer.c:755`
- **__setup_str_setup_hrtimer_hres** `hrtimer.c:762`
- **__setup_setup_hrtimer_hres** `hrtimer.c:762`
- **hrtimer_work** `hrtimer.c:1012`
- **__UNIQUE_ID_addressable_hrtimer_forward_18** `hrtimer.c:1094`
- **__UNIQUE_ID_addressable_hrtimer_start_range_ns_22** `hrtimer.c:1496`
- **__UNIQUE_ID_addressable_hrtimer_try_to_cancel_23** `hrtimer.c:1537`

