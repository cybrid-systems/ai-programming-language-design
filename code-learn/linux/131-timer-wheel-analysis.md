# Linux 定时器轮（Timer Wheel）深度分析

## 概述

Linux 内核有两种定时器系统：**低分辨率定时器（timer wheel）** 和 **高精度定时器（hrtimer）**。timer wheel 以 jiffies（HZ，通常 100~1000）为粒度，用于超时、重试、延迟等对精度要求不高的场景。它可能是内核中实例化最多的对象——网络连接超时、磁盘 I/O 超时、锁超时等都依赖它。

Linux 的 timer wheel 是经典定时器轮算法的改进实现，核心设计目标：
1. **无级联（no cascading）**：传统定时器轮需要在每次 tick 时向下级联即将到期的定时器，Linux 通过分级底层数组避免了级联
2. **O(1) 的添加和删除**：添加定时器恒定时间，无需遍历链表
3. **批量到期处理**：同一时刻的定时器合并处理，分摊软中断开销

## 核心数据结构

### struct timer_list

（`include/linux/timer_types.h` L8~18）

```c
struct timer_list {
    struct hlist_node   entry;      // 哈希链表节点（挂在 timer_base.vectors[] 的 bucket 中）
    unsigned long       expires;    // 到期时间（jiffies 值）
    void                (*function)(struct timer_list *); // 回调函数
    u32                 flags;      // 标志位（BASEMASK, DEFERRABLE, IRQSAFE, PINNED 等）
#ifdef CONFIG_LOCKDEP
    struct lockdep_map  lockdep_map;
#endif
};
```

`flags` 字段的低位编码了：
- `TIMER_BASEMASK`（0x0000000f）：定时器所属的 base 索引（BASE_LOCAL/BASE_GLOBAL/BASE_DEF）
- `TIMER_DEFERRABLE`（0x00000100）：可延迟定时器（不会阻止 CPU 进入 idle）
- `TIMER_IRQSAFE`（0x00000200）：IRQ 安全的定时器（不需要加 base->lock）
- `TIMER_PINNED`（0x00000400）：固定在当前 CPU 上

### struct timer_base

（`kernel/time/timer.c` L250~268）

```c
struct timer_base {
    raw_spinlock_t      lock;               // 保护 timer_base 的自旋锁
    struct timer_list   *running_timer;     // 当前正在执行的回调的定时器
#ifdef CONFIG_PREEMPT_RT
    spinlock_t          expiry_lock;        // RT 下的过期锁
    atomic_t            timer_waiters;      // 等待定时器完成的线程数
#endif
    unsigned long       clk;                // 当前定时器轮的时钟（jiffies + 1 offset）
    unsigned long       next_expiry;        // 下一个到期时间（jiffies 值）
    unsigned int        cpu;                // 所属 CPU
    bool                next_expiry_recalc; // 是否需要重新计算 next_expiry
    bool                is_idle;            // CPU 是否 idle
    bool                timers_pending;     // 是否有挂起的定时器
    DECLARE_BITMAP(pending_map, WHEEL_SIZE); // 各 bucket 是否非空（快速扫描）
    struct hlist_head   vectors[WHEEL_SIZE]; // 所有 bucket（WHEEL_SIZE = 8×64 = 512）
} ____cacheline_aligned;
```

定时器 base 是 per-CPU 的。根据配置不同，每个 CPU 有 1 或 3 个 base：

```c
static DEFINE_PER_CPU(struct timer_base, timer_bases[NR_BASES]);

#ifdef CONFIG_NO_HZ_COMMON
# define NR_BASES   3
# define BASE_LOCAL 0     // 本地定时器（绑定到当前 CPU）
# define BASE_GLOBAL 1    // 全局定时器（可迁移）
# define BASE_DEF   2     // 可延迟定时器（不阻止 idle）
#else
# define NR_BASES   1     // 所有定时器在一个 base 中
#endif
```

### 定时器轮的层级结构

```
每个 timer_base 有 LVL_DEPTH（8 或 9）级，每级 LVL_SIZE（64）个 bucket。

Level 0: 粒度 = 1/HZ             范围 = 63 tick
Level 1: 粒度 = 8/HZ             范围 = 512 tick (8×64)
Level 2: 粒度 = 64/HZ            范围 = 4K tick
...
Level k: 粒度 = 8^k / HZ         范围 = 64 × 8^k / HZ

以 HZ=1000 为例：
Level  粒度    偏移量    范围
 0     1 ms      0      0-63 ms
 1     8 ms     64      64-511 ms
 2     64 ms   128      512-4095 ms (~4s)
 3     512 ms  192      ~4s-~32s
 4     4 s     256      ~32s-~4m
 5     32 s    320      ~4m-~34m
 6     4 m     384      ~34m-~4h
 7     34 m    448      ~4h-~1d
 8     4 h     512      ~1d-~12d
```

每个 bucket 索引的偏移量计算：

```c
#define LVL_BITS    6               // 每级 64 个 bucket
#define LVL_SIZE    (1UL << LVL_BITS)
#define LVL_MASK    (LVL_SIZE - 1)
#define LVL_OFFS(n) ((n) * LVL_SIZE)     // level n 的偏移量

#define WHEEL_SIZE  (LVL_SIZE * LVL_DEPTH) // 512 或 576
```

## 核心操作

### 添加定时器：__mod_timer()

（`kernel/time/timer.c`，`__mod_timer()` 函数）

```
__mod_timer(timer, expires, flags)
  │
  ├─ 1. 安全检查
  │     if (timer->entry.pprev == NULL)  // 定时器已被 shutdown
  │         return -ENOENT;
  │
  ├─ 2. 确定目标 base 和 CPU
  │     if (flags & TIMER_PINNED) → 固定在当前 CPU 的 BASE_LOCAL
  │     else if (flags & TIMER_DEFERRABLE) → BASE_DEF（可迁移）
  │     else → BASE_GLOBAL（可迁移）
  │    如果定时器需要迁移到其他 CPU → 获取目标 CPU 的 timer_base
  │
  ├─ 3. 从旧 base 移除（如果已在定时器轮中）
  │     if (timer_pending(timer))
  │         detach_timer(timer, clear_pending);
  │
  └─ 4. 添加到目标 base
        internal_add_timer(base, timer)
          │
          └─ calc_wheel_index(expires, base->clk, &bucket_expiry)
               │
               ├─ if (delta < LVL_START(1)) → idx = calc_index(expires, 0)
               ├─ else if (delta < LVL_START(2)) → idx = calc_index(expires, 1)
               ├─ ... （共 LVL_DEPTH 层检查）
               ├─ else if ((long)delta < 0) → 已过期 → 放 level 0 当前槽
               └─ else → delta >= WHEEL_TIMEOUT_CUTOFF → 截断到最大值
               
               最终 idx = LVL_OFFS(level) + bucket_in_level
               
               hlist_add_head(&timer->entry, &base->vectors[idx]);
               __set_bit(idx, base->pending_map);
               timer->flags = (timer->flags & ~TIMER_BASEMASK) | cpu;
```

`calc_wheel_index()` 根据到期时间与当前时钟的差值，决定将定时器放入哪个 level 的哪个 bucket。越远的到期时间放入越高的 level（更大的粒度）。

相反地说：**越低的 level，到期时间越精确**。level 0 的定时器在精确的 tick 处触发；level 8 的定时器宽容度达 ~4 小时。

### 删除定时器：timer_delete()

```c
// kernel/time/timer.c
int timer_delete(struct timer_list *timer)
{
    return __try_to_del_timer_sync(timer);
}
```

有两种方式删除定时器：
- `timer_delete(timer)`：删除并保证没有其他 CPU 正在执行回调
- `timer_delete_sync(timer)`：同步删除，可以睡眠等待（不能在原子上下文中使用）

内部通过 `__try_to_del_timer_sync()` 实现：

```c
static int __try_to_del_timer_sync(struct timer_list *timer)
{
    struct timer_base *base;
    unsigned long flags;
    int ret = -1;

    // 检查定时器是否正在执行
    // 如果正在本 CPU 执行 → 等待执行完成
    // 如果正在其他 CPU 执行 → 返回 -1（caller 需要重试）
    
    base = lock_timer_base(timer, &flags);
    if (base->running_timer != timer) {
        // 从 base 中移除
        detach_timer(timer, true);
        ret = 1;
    }
    raw_spin_unlock_irqrestore(&base->lock, flags);
    return ret;
}
```

`timer_delete_sync()` 在 `__try_to_del_timer_sync` 返回 -1 时会循环等待（用 `cpu_relax()` 或调度到其他进程）。

### 定时器到期执行：TIMER_SOFTIRQ 处理路径

```
timer_interrupt()（硬件中断）
  └─ tick_handle_periodic()
       └─ update_process_times(user_mode)
            └─ run_local_timers()
                 └─ raise_softirq(TIMER_SOFTIRQ)

→ 软中断处理进程
  run_timer_softirq()                               // L2401
    ├─ run_timer_base(BASE_LOCAL)
    ├─ (NOHZ) run_timer_base(BASE_GLOBAL)
    ├─ (NOHZ) run_timer_base(BASE_DEF)
    └─ (NOHZ active) tmigr_handle_remote()

__run_timer_base(base)                               // L2433
  └─ __run_timers(base)                              // L2364~2400
       └─ while (base->clk <= jiffies):
             └─ collect_expired_timers(base, heads)  // 收集到期的 timers
             └─ base->clk++                          // 前进时钟
             └─ expire_timers(base, heads+level)     // 执行回调
                  └─ for each timer in heads[i]:
                       detach_timer(timer, true)
                       timer->function(timer)         // 调用回调
                       base->running_timer = NULL
```

核心的 `collect_expired_timers()` 根据当前的 base->clk 从 level 0 的 bucket 中取出所有到期的定时器。由于没有级联，高 level 的定时器在到达前不会下移——它们只在 `clk` 推进到期范围内时直接从所属 level 的 bucket 取用。

### 无级联是如何实现的

传统定时器轮中，定时器从高 level 逐级下移到低 level，每个 tick 需要检查并迁移。Linux 的改进：

**到期时间直接编码到 bucket 索引中**。对于 level n 的 bucket，其覆盖的时间范围是 `LVL_START(n)` 到 `LVL_START(n+1) - 1`。当 `base->clk` 推进到某个 level 的下一个范围时，该 level 的对应 bucket 中的定时器全部到期，不需要迁移。

```
例如 HZ=1000，定时器 expires=500ms：
  delta = 500 - clk
  落入 level 1（8ms 粒度），bucket = calc_index(expires, 1)
  当 clk 推进到覆盖 500ms 的时刻（clk/8 的特定值），
  这个 bucket 被 collect_expired_timers 取出
  不需要从 level 1 → level 0 的级联
```

## 特殊定时器类型

### 可延迟定时器（DEFERRABLE）

`TIMER_DEFERRABLE` 用于不需要精确到期时间的定时器：

- 不会阻止 CPU 进入 dynticks idle（NOHZ）
- 在 CPU 醒来时统一处理
- 常用于维护性任务（如 slab 缓存定期回收、CPU 统计更新）

### IRQ 安全定时器（IRQSAFE）

`TIMER_IRQSAFE` 在中断上下文中执行：

- 不获取 `base->lock`（使用 `base->lock` 可能自旋导致死锁）
- 用于 lockless 的定时器执行路径
- 主要用于 `timer_shutdown` 相关的强制 shutown 场景

### 已 shutdown 定时器

（`kernel/time/timer.c` 中 `timer_shutdown[_sync]` 相关）

`timer_shutdown()` 和 `timer_shutdown_sync()` 不仅删除定时器，还将其标记为不可重用的（`entry.pprev = NULL`）。这是一个双向的安全设计：
- timer 本身检测 `pprev == NULL` 拒绝重新添加
- 其他代码可以通过 `timer->entry.pprev == NULL` 检测定时器已 shutdown

## NoHZ 与定时器迁移

系统进入 dynticks idle（NOHZ）时，时钟 tick 关闭。此时需要处理：

1. **下个定时器到期时间的广播**：每个 CPU 通过 `__get_next_timer_interrupt()` 计算最近的到期时间
2. **远程唤醒**：如果定时器到期需要在 idle CPU 上处理，另一个 CPU 通过 IPI 唤醒它

```c
// kernel/time/timer.c
u64 timer_base_try_to_set_idle(unsigned long basej, u64 basem, bool *idle)
{
    if (*idle)
        return KTIME_MAX;
    return __get_next_timer_interrupt(basej, basem, idle);
}
```

`trigger_dyntick_cpu()` 在添加定时器时被调用——如果新定时器的到期时间早于目标 CPU 的下个唤醒点，向目标 CPU 发送 IPI 唤醒它处理。

## 定时器 API 总览

| API | 功能 | 上下文 |
|-----|------|--------|
| `timer_setup(timer, callback, flags)` | 初始化定时器 | 任意 |
| `mod_timer(timer, expires)` | 设置新的到期时间 | 任意 |
| `add_timer(timer)` | 添加已初始化的定时器 | 任意 |
| `del_timer(timer)` | 删除定时器 | 任意 |
| `del_timer_sync(timer)` | 同步删除（可睡眠） | 进程上下文 |
| `timer_pending(timer)` | 检查定时器是否在等待 | 任意 |
| `timer_delete(timer)` | 删除（保证不执行） | 任意 |
| `timer_delete_sync(timer)` | 同步删除 | 进程上下文 |
| `timer_shutdown(timer)` | 删除并禁止重加 | 任意 |
| `timer_shutdown_sync(timer)` | 同步 shutdown | 进程上下文 |

## timer wheel vs hrtimer

| 特性 | Timer Wheel | hrtimer |
|------|------------|---------|
| 分辨率 | jiffies（1~10ms） | 纳秒级（ktime） |
| 基础 | 基于 clock tick（jiffies） | 基于硬件时钟（timekeeping） |
| 实现 | 分级 bucket 数组 | 红黑树（按到期时间排序） |
| 触发 | TIMER_SOFTIRQ | HRTIMER_SOFTIRQ |
| 绑定 | per-CPU bucket | per-CPU rb-tree |
| 精确性 | 批量处理，可能延迟 | 尽力精确 |
| 使用场景 | 超时、延迟、重试 | 实时定时、nanosleep、posix-timers |
| 可扩展性 | O(1) add/del | O(log n) 红黑树 |

**为什么保留两套定时器？**

timer wheel 的 O(1) 添加/删除对于大量超时定时器（网络连接跟踪、socket 超时）至关重要。hrtimer 虽然精度高，但每次添加需要红黑树 O(log n) 操作且有缓存失效的开销。对于 *定时器会在到期前被删除* 的常见工作负载（通常 90%+ 的超时定时器被提前取消），timer wheel 更具性价比。

## 关键设计决策

### 1. 64 个 bucket / level

`LVL_SIZE = 64` 的选择是基于实证：64 个 bucket 在各级提供了良好的时间分辨率，同时每个 level 的 bitmap（pending_map）适合 64-bit 字，可以在一次 `find_next_bit` 操作中找到非空 bucket。如果 bucket 数更少（如 32），高 level 的粒度太粗；更多（如 128）则 bitmap 变宽，查找效率下降。

### 2. 8~9 层深度

`LVL_DEPTH` 在 `HZ > 100` 时为 9，否则为 8。这是由 64^9 或 64^8 经过 `LVL_SHIFT` 放大后覆盖的最大时间范围决定：HZ=1000 时约 12 天，HZ=100 时约 12 天。对于超过范围的定时器，被截断到 `WHEEL_TIMEOUT_MAX`。

实际观测中，内核的绝大多数定时器超时时间不超过 5 天（网络连接跟踪的典型超时），这种截断是安全的。

### 3. timer_base 的三 base 架构

NOHZ 系统使用 BASE_LOCAL/BASE_GLOBAL/BASE_DEF 三个 base：

- **BASE_LOCAL**：绑定到当前 CPU 的定时器，访问不需要跨 CPU 锁
- **BASE_GLOBAL**：可能迁移到其他 CPU 的定时器
- **BASE_DEF**：可延迟定时器，不与 tick 约束关联

三 base 的主要优点是减少锁争用和 NOHZ 处理的粒度。

### 4. 无级联的代价

无级联的代价是高 level 定时器的到期时间有误差（最大 `LVL_GRAN(n) - 1`）。例如在 level 6（4m 粒度），定时器可能早到近乎 4 分钟或晚到近乎 4 分钟。对于 4h 或 1d 范围的定时器，这种误差可以接受。但对于毫秒级精度的超时（网络 RTO），timer wheel 的 level 0 提供 `1/HZ` 的精度（HZ=1000 时 1ms）。

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct timer_list` | include/linux/timer_types.h | 8 |
| `struct timer_base` | kernel/time/timer.c | 250 |
| `timer_bases[]` | kernel/time/timer.c | 267 |
| `__mod_timer()` | kernel/time/timer.c | 附近 |
| `internal_add_timer()` | kernel/time/timer.c | 附近 |
| `calc_wheel_index()` | kernel/time/timer.c | ~547 |
| `calc_index()` | kernel/time/timer.c | 524 |
| `collect_expired_timers()` | kernel/time/timer.c | 附近 |
| `expire_timers()` | kernel/time/timer.c | 附近 |
| `__run_timers()` | kernel/time/timer.c | 2344 |
| `run_timer_softirq()` | kernel/time/timer.c | 2401 |
| `__run_timer_base()` | kernel/time/timer.c | 2378 |
| `trigger_dyntick_cpu()` | kernel/time/timer.c | 附近 |
| `timer_delete()` | kernel/time/timer.c | 1404 |
| `timer_delete_sync()` | kernel/time/timer.c | 附近 |
| `__try_to_del_timer_sync()` | kernel/time/timer.c | 1451 |
| `timer_shutdown()` | kernel/time/timer.c | 1425 |
| `timer_base_try_to_set_idle()` | kernel/time/timer.c | ~2350 |
| `timer_clear_idle()` | kernel/time/timer.c | ~2340 |
| `WHEEL_SIZE` | kernel/time/timer.c | 187 |
| `LVL_DEPTH` | kernel/time/timer.c | 174 |
| `LVL_SIZE` | kernel/time/timer.c | 168 |
| `NR_BASES` | kernel/time/timer.c | 194 |
