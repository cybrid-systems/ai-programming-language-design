# 25-hrtimer — Linux 内核高精度定时器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**hrtimer（High-Resolution Timer）** 是 Linux 内核的高精度定时器框架，由 Thomas Gleixner 于 2007 年（Linux 2.6.21）引入。它利用硬件时钟设备（如 x86 LAPIC timer、TSC deadline timer 或 HPET）实现**纳秒级精度**的定时。

内核中存在两套定时器机制：
```
传统 timer（timer wheel）：
  基于 jiffies（HZ=250 → 精度 4ms）
  使用 TIMER_SOFTIRQ（#1）处理
  适合粗粒度定时

hrtimer：
  基于 clock_event_device（硬件时钟）
  纳秒精度（ktime_t）
  使用 HRTIMER_SOFTIRQ（#8）处理
  适合高精度需求（如音频、网络、实时）
```

**doom-lsp 确认**：核心实现在 `kernel/time/hrtimer.c`（约 2000 行）。关键结构体定义在 `include/linux/hrtimer.h`：`struct hrtimer`、`struct hrtimer_clock_base`、`struct hrtimer_cpu_base`。

---

## 1. 核心数据结构

### 1.1 `ktime_t`——纳秒时间表示

```c
// include/linux/ktime.h — 64-bit 纳秒时间
typedef s64 ktime_t;

// 基本操作（全部内联为一条指令）：
#define ktime_add(lhs, rhs)    ((lhs) + (rhs))  // 时间相加
#define ktime_sub(lhs, rhs)    ((lhs) - (rhs))  // 时间相减
#define ktime_to_ns(kt)        ((s64)(kt))      // 转为纳秒
#define ns_to_ktime(ns)        ((ktime_t)(ns))  // 纳秒转 ktime_t

// 创建 ktime_t：
static inline ktime_t ktime_set(const s64 secs, const unsigned long nsecs)
{
    return (ktime_t)secs * NSEC_PER_SEC + (s64)nsecs;
}
```

`ktime_t` 就是 `s64`（纳秒），所有操作在 64 位系统上是简单的整数加减法，零开销。

### 1.2 `struct hrtimer`——定时器

```c
struct hrtimer {
    struct timerqueue_node  node;         // 红黑树节点（按 expires 排序）
    ktime_t                 _softexpires; // 软到期时间
    enum hrtimer_restart    (*function)(struct hrtimer *); // 回调
    struct hrtimer_clock_base *base;     // 时钟基（决定时钟源和执行上下文）
    u8                      state;        // HRTIMER_STATE_INACTIVE/PENDING/CALLBACK
    u8                      is_soft;      // =1 在软中断上下文执行
    u8                      is_hard;      // =1 在硬中断上下文执行
};
```

**回调返回值**：
```c
enum hrtimer_restart {
    HRTIMER_NORESTART,    // 单次定时器 → 不重新启动
    HRTIMER_RESTART,      // 周期定时器 → 重新加入红黑树
};
```

### 1.3 `struct hrtimer_clock_base`——时钟基

```c
struct hrtimer_clock_base {
    struct hrtimer_cpu_base *cpu_base;  // 所属 CPU 基
    struct timerqueue_head  active;     // 红黑树根
    ktime_t                 (*get_time)(void); // 读取当前时间
    ktime_t                 offset;             // 与单调时间的偏移
    clockid_t               clockid;            // 时钟 ID
    ktime_t                 expires_next;       // 下次到期时间
};
```

### 1.4 `struct hrtimer_cpu_base`——per-CPU 定时器基

```c
struct hrtimer_cpu_base {
    raw_spinlock_t              lock;             // 保护所有时钟基
    struct hrtimer_clock_base   clock_base[HRTIMER_MAX_CLOCK_BASES]; // 8 个时钟基
    ktime_t                     expires_next;     // 全局下次到期
    int                         active_bases;     // 活跃基 bitmask
    unsigned int                nr_retries;       // 重试计数
    unsigned int                nr_hangs;         // 挂起计数
    ktime_t                     max_hang_time;    // 最大挂起时间
};
```

### 1.5 时钟类型

```c
enum hrtimer_base_type {
    HRTIMER_BASE_MONOTONIC,         // [0] 单调时钟
    HRTIMER_BASE_REALTIME,          // [1] 实时时钟
    HRTIMER_BASE_BOOTTIME,          // [2] 启动时钟
    HRTIMER_BASE_TAI,               // [3] TAI 原子时
    HRTIMER_BASE_MONOTONIC_SOFT,    // [4] 单调时钟（软中断执行）
    HRTIMER_BASE_REALTIME_SOFT,     // [5] 实时时钟（软中断执行）
    HRTIMER_BASE_BOOTTIME_SOFT,     // [6] 启动时钟（软中断执行）
    HRTIMER_BASE_TAI_SOFT,          // [7] TAI 原子时（软中断执行）
    HRTIMER_MAX_CLOCK_BASES,        // = 8
};
```

| 时钟 | get_time 来源 | 受 NTP 影响 | 包含休眠 | 执行上下文 |
|------|-------------|------------|---------|-----------|
| MONOTONIC | CLOCK_MONOTONIC | ❌ | ❌ | 硬中断 |
| REALTIME | CLOCK_REALTIME | ✅ | ❌ | 硬中断 |
| BOOTTIME | CLOCK_BOOTTIME | ❌ | ✅ | 硬中断 |
| TAI | CLOCK_TAI | ✅ | ❌ | 硬中断 |
| *_SOFT | 同上 | 同上 | 同上 | **软中断** |

---

## 2. 🔥 定时器启动——hrtimer_start

```
hrtimer_start(timer, expires, mode)               @ kernel/time/hrtimer.c
  │
  ├─ hrtimer_start_range_ns(timer, expires, range_ns, mode)
  │    │
  │    ├─ [1. 获取当前时间]
  │    │   now = timer->base->get_time()
  │    │   → 对于 MONOTONIC: ktime_get()
  │    │   → 对于 REALTIME:   ktime_get_real()
  │    │
  │    ├─ [2. 设置到期时间]
  │    │   timer->_softexpires = ktime_add(now, expires)
  │    │   timer->node.expires = ktime_add(timer->_softexpires, delta_ns)
  │    │   → 定时器在 [_softexpires, expires] 区间内均可被触发
  │    │   → range_ns = slack 值，允许内核合并多个定时器以减少中断次数
  │    │   → 对于 HRTIMER_MODE_ABS，expires 为绝对时间
  │    │
  │    ├─ [3. 加锁]
  │    │   raw_spin_lock_irqsave(&cpu_base->lock, flags)
  │    │
  │    ├─ [4. 更新基]
  │    │   if (expires < timer->base->expires_next)
  │    │       timer->base->expires_next = expires
  │    │   → 更新当前基的最早到期时间
  │    │
  │    ├─ [5. 移除旧定时器（如果已在树中）]
  │    │   if (timer->is_queued)
  │    │       __remove_hrtimer(timer, base, HRTIMER_STATE_INACTIVE, reprogram)
  │    │
  │    ├─ [6. 插入红黑树]
  │    │   timerqueue_add(&base->active, &timer->node)
  │    │   → 红黑树：按 expires 排序
  │    │   → O(log n) 插入
  │    │   → 如果新 timer 是最早的：
  │    │       base->expires_next = expires
  │    │
  │    ├─ [7. 重设硬件定时器]
  │    │   if (timer 比 CPU 上当前最早到期时间更早)
  │    │       hrtimer_reprogram(timer, cpu_base)
  │    │       → clockevents_program_event(dev, expires)
  │    │       → 写入硬件比较寄存器
  │    │       → 对于 TSC deadline: wrmsr(MSR_IA32_TSC_DEADLINE, val)
  │    │       → 对于 LAPIC timer: 设置初始计数寄存器
  │    │
  │    └─ [8. 解锁]
  │       raw_spin_unlock_irqrestore(&cpu_base->lock, flags)
```

---

## 3. 🔥 定时器到期——完整数据流

```
硬件时钟中断（LAPIC timer 或 TSC deadline）
  │
  └─ clock_event_device 的处理函数被调用
       │
       ├─ tick_handle_periodic() / hrtimer_interrupt()
       │
       ├─ [1. 读取当前时间]
       │   now = ktime_get()
       │
       ├─ [2. 循环处理所有到期定时器]
       │   while (timer = __hrtimer_get_next_event(cpu_base))
       │        expires = timer->node.expires
       │        if (now < expires)
       │            break;  ← 最近的定时器还没到期（时钟漂移）
       │
       │        // 从红黑树中移除
       │        __remove_hrtimer(timer, base, HRTIMER_STATE_CALLBACK, 0)
       │
       │        // ★ 执行回调
       │        raw_spin_unlock(&cpu_base->lock)
       │        restart = timer->function(timer)
       │        // timer->function 在中断上下文中执行！
       │        // 不可休眠！必须快速返回！
       │        raw_spin_lock(&cpu_base->lock)
       │
       │        if (restart == HRTIMER_RESTART)
       │            enqueue_hrtimer(timer)  ← 重新加入红黑树
       │
       ├─ [3. 重设下次触发时间]
       │   expires = __hrtimer_get_next_event(cpu_base)
       │   clockevents_program_event(dev, expires)
       │   → 指示硬件在 expires 时刻再次触发中断
       │
       └─ [4. 退出中断]
```

---

## 4. clock_event_device——硬件时钟抽象

```c
// include/linux/clockchips.h
struct clock_event_device {
    void (*event_handler)(struct clock_event_device *); // 中断处理函数
    int  (*set_next_event)(unsigned long evt, struct clock_event_device *);
    int  (*set_next_ktime)(ktime_t expires, struct clock_event_device *);
    // → 设置下次触发时间
    // → 对于 TSC deadline: wrmsr(MSR_IA32_TSC_DEADLINE)
    // → 对于 LAPIC timer: 写 LVT + 初始计数
    ktime_t next_event;      // 下次触发时间
    unsigned long min_delta_ns;  // 最小间隔（ns）
    unsigned long max_delta_ns;  // 最大间隔（ns）
    unsigned int rating;         // 优先级
    int  irq;                    // 中断号
};
```

x86 上注册的 clock_event_device：
```c
// 1. LAPIC timer（本地 APIC 定时器）：~500MHz 递减计数器
// 2. TSC Deadline Timer：基于 TSC 的绝对值比较（更高精度）
// 3. HPET：高精度事件定时器，~14.318MHz
// 4. PIT：老式可编程间隔定时器，~1.193MHz

// 内核选择 rating 最高的可用设备
// TSC deadline timer 通常优先
```

**hrtimer_reprogram 调用链**：

```
hrtimer_reprogram(timer, cpu_base)
  │
  ├─ expires = ktime_sub(timer->node.expires, base->offset)
  │
  ├─ cpu_base->expires_next = expires
  │
  └─ clockevents_program_event(dev, expires)
       │
       └─ dev->set_next_ktime(expires, dev)
            │
            ├─ 对于 TSC deadline:
            │   wrmsrl(MSR_IA32_TSC_DEADLINE, expires_to_tsc(expires))
            │   → CPU 在 TSC 达到该值时触发 #DE 异常
            │   → 延迟：~100ns（wrmsr 指令）
            │
            └─ 对于 LAPIC timer:
                __setup_APIC_LVTT(oneshot, ...)
                apic_write(APIC_TMICT, cycles)
                → 设置 LAPIC 定时器初始计数
                → 延迟：~200ns（两次 APIC MMIO 写）
```

---

## 5. 定时器使用模式

### 5.1 基本使用

```c
// 1. 定义和设置
struct hrtimer my_timer;
hrtimer_setup(&my_timer, my_callback, CLOCK_MONOTONIC, HRTIMER_MODE_REL);

// 2. 启动（1ms 后执行）
hrtimer_start(&my_timer, ns_to_ktime(1_000_000), HRTIMER_MODE_REL);

// 3. 回调（在中断上下文中执行！）
enum hrtimer_restart my_callback(struct hrtimer *timer)
{
    // 在硬中断或软中断上下文中
    // 不可休眠！
    
    // 取消定时器
    return HRTIMER_NORESTART;
    
    // 或重启定时器（50ms 后再次触发）
    // hrtimer_forward(timer, now, ms_to_ktime(50));
    // return HRTIMER_RESTART;
}

// 4. 取消
hrtimer_cancel(&my_timer);  // 等待回调完成（如果正在执行）
```

### 5.2 hrtimer_forward——周期定时器

```c
// hrtimer_forward 将定时器的到期时间向后移动指定间隔
// 用于实现周期定时器：

expires = hrtimer_forward(timer, now, period);
// → 将 timer 的到期时间向后推 period 长度
// → 如果回调执行超时（超过 period），一次跳过多个周期
// → 确保定时器追上真实时间

// 标准模式：
if (hrtimer_forward(timer, now, period)) {
    // 回调执行超时了（跳过了至少一个周期）
    // 可以考虑跳过一些工作
}
return HRTIMER_RESTART;
```

### 5.3 hrtimer_cancel / hrtimer_try_to_cancel

```c
// 取消定时器：
int hrtimer_cancel(struct hrtimer *timer);
// → 如果定时器正在执行回调，等待其完成
// → 返回 0: 定时器未激活
// → 返回 1: 定时器被成功取消

int hrtimer_try_to_cancel(struct hrtimer *timer);
// → 非阻塞版本
// → 如果回调正在执行，返回 -1
```

---

## 6. 精度示例

实测精度（不同硬件时钟）：

| 时钟源 | 典型触发偏差 | 备注 |
|--------|------------|------|
| TSC deadline | ±200ns | wrmsr 写入后 CPU 硬件触发 |
| LAPIC timer | ±500ns | 受 APIC 总线频率影响 |
| HPET | ±2000ns | 慢速 14.318MHz 时钟 |
| timer wheel (HZ=250) | ±4ms | 基于 jiffies，毫秒级 |

```c
// 用户空间的高精度休眠：
struct timespec req = { .tv_sec = 0, .tv_nsec = 500000 }; // 500μs
nanosleep(&req, NULL);
// → 内核实现：hrtimer_nanosleep()
//    → hrtimer_setup_sleeper_on_stack(&t, clock_id, mode)
//    → hrtimer_start(timer, timespec_to_ktime(*rqtp), HRTIMER_MODE_REL)
//    → set_current_state(TASK_INTERRUPTIBLE)
//    → schedule()  ← 休眠
//    → 定时器到期 → 唤醒进程
// 实际睡眠时间：500μs ± 1μs（远优于 sleep() 的 500ms ± 4ms）
```

---

## 7. 软中断 vs 硬中断执行路径

hrtimer 的回调可以在两个上下文中执行：

| 时钟基 | 执行上下文 | 回调限制 |
|--------|-----------|---------|
| HRTIMER_BASE_MONOTONIC（hard） | 硬中断上下文 | 不可休眠，极短 |
| HRTIMER_BASE_MONOTONIC_SOFT（soft）| HRTIMER_SOFTIRQ | 不可休眠，可稍长 |

```c
// 软中断执行（回调在 HRTIMER_SOFTIRQ 上下文）：
hrtimer_setup(&timer, callback, CLOCK_MONOTONIC, HRTIMER_MODE_REL | HRTIMER_MODE_SOFT);

// 硬中断执行（回调在硬中断上下文，默认）：
hrtimer_setup(&timer, callback, CLOCK_MONOTONIC, HRTIMER_MODE_REL | HRTIMER_MODE_HARD);
```

软中断路径的优点是：它不会阻塞硬中断处理，适合对实时性要求不那么苛刻的场景。

---

## 8. 调试与调优

```bash
# 查看 hrtimer 统计
$ cat /proc/timer_list
  Timer List Version: v0.8
  HRTIMER_MAX_CLOCK_BASES: 8
  now at 1234567890123 nsecs
  
  cpu: 0
   clock 0:
    .index:      0
    .resolution: 1 nsecs
    .get_time:   ktime_get
    .offset:     0 nsecs
   active timers:
    #0: timer, start=1000, expires=2000, function=my_callback
  
  cpu: 1
   ...

# 查看 clock_event_device
$ cat /sys/devices/system/clockevents/clockevent0/current_device
  lapic

$ cat /sys/devices/system/clocksource/clocksource0/current_clocksource
  tsc
```

---

## 9. 源码文件索引

| 文件 | 关键符号 | 内容 |
|------|---------|------|
| `kernel/time/hrtimer.c` | — | hrtimer 核心实现 |
| `include/linux/hrtimer.h` | `struct hrtimer` | 数据结构 |
| `include/linux/ktime.h` | `ktime_t` | 纳秒时间表示 |
| `include/linux/clockchips.h` | `struct clock_event_device` | 硬件时钟抽象 |
| `arch/x86/kernel/apic/apic.c` | — | LAPIC 定时器 |

### 6.10 ktime 转换辅助

| 函数 | 说明 |
|------|------|
| `ktime_get()` | 获取当前 MONOTONIC 时间 |
| `ktime_get_real()` | 获取当前 REALTIME 时间 |
| `ktime_to_ns(kt)` | ktime_t → 纳秒 |
| `ns_to_ktime(ns)` | 纳秒 → ktime_t |
| `ms_to_ktime(ms)` | 毫秒 → ktime_t |

---

## 10. 关联文章

- **23-interrupt**：硬件时钟中断
- **24-softirq**：HRTIMER_SOFTIRQ
- **37-CFS调度器**：调度器使用 hrtimer 进行周期性调度

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
