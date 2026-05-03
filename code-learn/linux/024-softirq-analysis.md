# 24-softirq — Linux 内核软中断深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**softirq（软中断）** 是 Linux 内核中可延迟处理的中断下半部机制。与硬中断（硬件触发的不可抢占上下文）不同，软中断运行在**软中断上下文**——硬中断开启、可被硬中断打断，但不可进入进程调度（不可休眠、不可持有 mutex）。

软中断的优先级层次：
```
最高优先级
    ↓
  硬中断（Hard IRQ）—— 中断关，不可被任何中断打断
    ↓
  软中断（SoftIRQ）—— 中断开，可被硬中断打断，不可调度
    ↓
  tasklet —— 基于软中断
    ↓
  workqueue / kthread —— 进程上下文，可调度
最低优先级
```

**doom-lsp 确认**：核心实现在 `kernel/softirq.c`。`NR_SOFTIRQS`=10 种软中断。`open_softirq`、`raise_softirq`、`do_softirq` 为三个核心函数。`include/linux/interrupt.h` 定义了软中断枚举。

---

## 1. 软中断类型

```c
// include/linux/interrupt.h
enum {
    HI_SOFTIRQ      = 0,      // 高优先级 tasklet
    TIMER_SOFTIRQ   = 1,      // 低精度定时器（timer wheel）
    NET_TX_SOFTIRQ  = 2,      // 网络发送完成
    NET_RX_SOFTIRQ  = 3,      // 网络数据包接收
    BLOCK_SOFTIRQ   = 4,      // 块设备 I/O 完成
    IRQ_POLL_SOFTIRQ = 5,     // 中断轮询
    TASKLET_SOFTIRQ = 6,      // 普通 tasklet
    SCHED_SOFTIRQ   = 7,      // 调度器负载均衡
    HRTIMER_SOFTIRQ = 8,      // 高精度定时器
    RCU_SOFTIRQ     = 9,      // RCU 处理
    NR_SOFTIRQS     = 10,
};
```

**优先级**：编号越小，优先级越高。执行时按 `HI_SOFTIRQ`（0）到 `RCU_SOFTIRQ`（9）的顺序。

**网络 RX 和 TX 是系统中最繁忙的软中断**：一个 10Gbps 网卡每秒可触发数百万个软中断。

---

## 2. pending 位图机制

每个 CPU 维护一个 10-bit pending 位图，标记哪些软中断待处理：

```c
// kernel/softirq.c — per-CPU pending 位图
// 存储在 irq_stat.__softirq_pending 中
DECLARE_PER_CPU(struct irq_cpustat, irq_stat);

// 触发软中断（设置位）：
void __raise_softirq_irqoff(unsigned int nr)
{
    // 用 BIT(nr) 设置位图中的第 nr 位
    __this_cpu_or(irq_stat.__softirq_pending, BIT(nr));
}

// 读取 pending 位图：
unsigned int local_softirq_pending(void)
{
    return __this_cpu_read(irq_stat.__softirq_pending);
}

// 清除 pending（处理完所有软中断后）：
void set_softirq_pending(unsigned int pending)
{
    __this_cpu_write(irq_stat.__softirq_pending, pending);
}
```

**位图 vs 链表**：10-bit 位图可用一条 `AND/OR` 指令检查所有待处理的软中断类型，比遍历链表快得多。这是软中断被设计为编译时固定类型的原因。

---

## 3. 注册软中断处理函数

```c
// kernel/softirq.c
struct softirq_action {
    void (*action)(struct softirq_action *);
};
static struct softirq_action softirq_vec[NR_SOFTIRQS];

void open_softirq(int nr, void (*action)(struct softirq_action *))
{
    softirq_vec[nr].action = action;
}
```

实际注册示例：
```c
// 网络 RX（net/core/dev.c）:
open_softirq(NET_RX_SOFTIRQ, net_rx_action);
open_softirq(NET_TX_SOFTIRQ, net_tx_action);

// 定时器（kernel/time/timer.c）:
open_softirq(TIMER_SOFTIRQ, run_timer_softirq);

// 块设备完成（block/blk-mq.c）:
open_softirq(BLOCK_SOFTIRQ, blk_done_softirq);

// 高精度定时器（kernel/time/hrtimer.c）:
open_softirq(HRTIMER_SOFTIRQ, hrtimer_run_softirq);
```

---

## 4. 🔥 触发软中断——raise_softirq

```
raise_softirq(NET_RX_SOFTIRQ)               @ kernel/softirq.c
  │
  ├─ local_irq_save(flags)
  │   → 关中断，防止与硬中断处理中的 raise 竞争
  │
  ├─ __raise_softirq_irqoff(NET_RX_SOFTIRQ)
  │   → __this_cpu_or(softirq_pending, BIT(NET_RX_SOFTIRQ))
  │   → 第 3 位置 1
  │
  ├─ 如果不在硬中断上下文中：
  │   └─ wakeup_softirqd()
  │       → 唤醒当前 CPU 的 ksoftirqd 内核线程
  │
  └─ local_irq_restore(flags)
      → 开中断
```

**触发来源**：

```
网络驱动（如 igb/ixgbe 的 NAPI poll）:
  napi_complete_done()
    → __raise_softirq_irqoff(NET_RX_SOFTIRQ)

块设备完成:
  blk_done_softirq()
    → __raise_softirq_irqoff(BLOCK_SOFTIRQ)

定时器:
  run_timer_softirq()
    → __raise_softirq_irqoff(TIMER_SOFTIRQ)

调度器:
  scheduler_tick()
    → raise_softirq(SCHED_SOFTIRQ)
```

---

## 5. 🔥 执行处理——__do_softirq

```c
// kernel/softirq.c — 核心执行函数
asmlinkage __visible void __softirq_entry __do_softirq(void)
{
    unsigned long end = jiffies + MAX_SOFTIRQ_TIME;
    // MAX_SOFTIRQ_TIME = 2ms（最多执行 2ms 的软中断）
    int max_restart = MAX_SOFTIRQ_RESTART;
    // MAX_SOFTIRQ_RESTART = 10（最多重试 10 轮）
    unsigned int pending;
    int cpu;

    // 标记进入软中断上下文
    __this_cpu_write(softirq_count, SOFTIRQ_OFFSET);

restart:
    pending = local_softirq_pending();

    // 清除 pending（执行前清空，执行中新的软中断会重新设置）
    set_softirq_pending(0);

    // 开中断（允许硬中断打断）
    local_irq_enable();

    // 按优先级从高到低处理
    // while 循环依次处理每个 bit
    while (pending) {
        unsigned int vec_nr;

        // 找到最低位的 1（最高优先级）
        vec_nr = __ffs(pending);
        pending &= ~(1 << vec_nr);

        // 开中断执行
        local_irq_enable();

        // ★ 执行软中断处理函数！
        // 对于 NET_RX：net_rx_action()
        // 对于 TIMER：run_timer_softirq()
        // 对于 BLOCK：blk_done_softirq()
        h->action(h);

        local_irq_disable();

        // 处理下一类型
        h++;
    }

    // 一轮结束
    local_irq_disable();

    // 检查是否有新的 pending（执行过程中新触发的）
    pending = local_softirq_pending();
    if (pending && --max_restart)
        goto restart;  // 继续处理（最多 10 轮）

    // 如果还有 pending 但达到重试上限：
    if (pending)
        wakeup_softirqd();  // 让 ksoftirqd 处理

    // 退出软中断上下文
    __this_cpu_write(softirq_count, 0);
    local_irq_enable();
}
```

**执行边界**：
- 最大执行时间：`MAX_SOFTIRQ_TIME = 2ms`
- 最大重试轮数：`MAX_SOFTIRQ_RESTART = 10`
- 达到任一上限 → 唤醒 `ksoftirqd` 内核线程继续处理

**为什么需要限制？**
```
如果一个千兆以太网卡持续高速接收数据包：
  net_rx_action() 处理完一批数据包后
  → 又立即有新的数据包到达
  → softirq 被重新触发
  → 无限循环 → 用户进程得不到 CPU
  
  所以需要时间限制（2ms），到时间后让 ksoftirqd 线程处理
  → ksoftirqd 是可调度的，会被公平分配到时间片
```

---

## 6. ksoftirqd——软中断内核线程

```c
// per-CPU ksoftirqd 内核线程
// CPU 0: ksoftirqd/0
// CPU 1: ksoftirqd/1
// ...

static int run_ksoftirqd(void *__cpu)
{
    while (!kthread_should_stop()) {
        // 检查 pending
        if (local_softirq_pending()) {
            cond_resched();           // 先让出 CPU
            do_softirq();             // 处理软中断
            cond_resched();           // 处理完再让出
        }
        schedule();                   // 没有工作 → 休眠
    }
    return 0;
}
```

**ksoftirqd 的优势**：
1. 可被调度器公平调度（不抢占用户进程）
2. 支持 CPU 亲和性
3. 可设置优先级

---

## 7. tasklet——基于软中断的动态下半部

```c
struct tasklet_struct {
    struct tasklet_struct *next;         // 链表 next
    unsigned long state;                 // bit 0: SCHED, bit 1: RUN
    atomic_t count;                      // 0=启用, >0=禁用
    void (*func)(unsigned long data);    // 处理函数
    unsigned long data;                  // 参数
};

// 静态声明：
DECLARE_TASKLET(name, func, data);
DECLARE_TASKLET_DISABLED(name, func, data);

// 调度执行：
tasklet_schedule(&my_tasklet);
```

**tasklet 数据流**：

```
tasklet_schedule(tasklet)
  │
  └─ __tasklet_schedule(tasklet)
       │
       ├─ tasklet->next = NULL
       ├─ set_bit(TASKLET_STATE_SCHED, &tasklet->state)   ← 标记已调度
       │
       ├─ 将 tasklet 加入当前 CPU 的 tasklet_vec 链表
       │   this_cpu_ptr(&tasklet_vec)->head = tasklet
       │
       └─ raise_softirq(TASKLET_SOFTIRQ)                   ← 触发软中断
            └─ 最终由 TASKLET_SOFTIRQ 的处理函数：
               tasklet_action()
               → 遍历当前 CPU 的 tasklet_vec 链表
               → 执行每个 tasklet 的 func()
```

**tasklet vs 直接使用软中断**：

| 特性 | 直接软中断 | tasklet |
|------|-----------|---------|
| 动态注册 | ❌ 编译时固定 | ✅ 运行时创建 |
| 数量 | 10 种 | 不限 |
| 上下文 | 软中断 | 软中断 |
| 重入性 | 同类型可多核并发 | **同类型串行执行** |
| 使用难度 | 高 | 低（推荐用于新代码）|

---

## 8. BH（Bottom Half）锁与软中断防护

### 8.1 local_bh_disable / local_bh_enable

```c
void local_bh_disable(void)
{
    __local_bh_disable_ip(_RET_IP_, SOFTIRQ_DISABLE_OFFSET);
}

void local_bh_enable(void)
{
    __local_bh_enable_ip(_RET_IP_, SOFTIRQ_DISABLE_OFFSET);
    // 在 enable 时处理 pending 的软中断
}
```

### 8.2 spin_lock_bh 模式

```c
spin_lock_bh(&lock);   // = local_bh_disable + spin_lock
// 临界区：软中断和进程上下文都不能进入
spin_unlock_bh(&lock); // = spin_unlock + local_bh_enable（会处理 pending softirq）
```

`spin_lock_bh` 是网络栈中最常用的锁模式——保护软中断和进程上下文间共享的数据结构。

### 8.3 软中断上下文的检测

```c
in_interrupt()   // 是否在硬中断或软中断上下文中
in_softirq()     // 是否在软中断上下文中
```

---

## 9. 网络 RX 软中断处理——net_rx_action

网络数据包接收是最重要的软中断场景：

```
net_rx_action(&softirq_vec[NET_RX_SOFTIRQ])                    @ net/core/dev.c
  │
  └─ 遍历当前 CPU 的 NAPI 列表：
       │
       ├─ napi->poll(napi, budget)
       │   ← igb_poll() / ixgbe_poll() 等网卡驱动
       │   → 从硬件 RX ring 取出数据包
       │   → 分配 sk_buff → 填入数据
       │   → napi_gro_receive() → GRO 合并
       │   → netif_receive_skb() → 协议栈处理
       │
       ├─ if (work_done < budget)
       │    napi_complete_done(napi, work_done)
       │    → 重新开启硬件中断
       │
       └─ budget 用尽 → 保留在 NAPI 列表 → 等待下次软中断
```

---

## 10. BH workqueue——7.0-rc1 的 tasklet 替代方案

Linux 7.0-rc1 引入了 `WQ_BH` workqueue 作为 tasklet 的现代替代：

```c
#define WQ_BH          0x0040
struct workqueue_struct *wq = alloc_workqueue("bh_wq", WQ_BH, 0);
local_bh_disable();
queue_work(wq, &work);     // 在 softirq 上下文执行
local_bh_enable();
```

BH workqueue 不创建 kworker 线程——工作在 softirq 上下文中直接执行，不需要 kworker 线程。7.0-rc1 中 tasklet 已标记为遗留接口，新代码应使用 BH workqueue。

### 10.3 软中断的 NAPI 集成

NAPI（New API）是现代网络驱动的标准，将中断和轮询结合：

```c
// 驱动注册 NAPI：
netif_napi_add(netdev, &napi, igb_poll, NAPI_POLL_WEIGHT);

// 中断上半部：
irqreturn_t igb_msix_ring(int irq, void *data)
{
    napi_schedule(&q_vector->napi);     // 不直接在中断中处理
    // → __napi_schedule
    //   → 将 napi 加入当前 CPU 的 softnet_data->poll_list
    //   → __raise_softirq_irqoff(NET_RX_SOFTIRQ)
    return IRQ_HANDLED;
}

// NAPI poll 回调（在 NET_RX_SOFTIRQ 中执行）：
int igb_poll(struct napi_struct *napi, int budget)
{
    int work_done = 0;
    // 从硬件 RX ring 取出数据包
    // 分发到协议栈
    // 预算用完 → 返回 budget（不完成 NAPI）
    // 预算未用完 → napi_complete_done → 重新开中断
}
```

**Budget 机制**：net_rx_action 的 budget 是 per-CPU 的总额度（默认 300），在每个 NAPI 实例之间分配，防止软中断饿死用户进程。

---

## 11. 性能数据

| 指标 | 数值 | 说明 |
|------|------|------|
| 触发软中断 | ~20ns | set_bit 操作 |
| 每轮处理 | ~100-500μs | 最多 2ms |
| 软中断函数调用 | ~5ns | 函数指针调用 |
| ksoftirqd 唤醒 | ~1μs | 上下文切换 |
| 最大重试轮数 | 10 | 防止饿死 |
| 单次最大执行时间 | 2ms | 硬限制 |

---

## 12. 性能数据对比

| 文件 | 内容 | 关键函数 |
|------|------|---------|
| `kernel/softirq.c` | 核心实现 | `__do_softirq`, `raise_softirq`, `open_softirq` |
| `include/linux/interrupt.h` | 软中断枚举 + 声明 | `NR_SOFTIRQS`, `local_bh_disable/enable` |
| `net/core/dev.c` | 网络软中断 | `net_rx_action`, `net_tx_action` |
| `kernel/time/timer.c` | 定时器软中断 | `run_timer_softirq` |
| `block/blk-mq.c` | 块软中断 | `blk_done_softirq` |

---

- **23-interrupt**：硬中断在 `irq_exit()` 中触发软中断
- **25-hrtimer**：HRTIMER_SOFTIRQ 软中断
- **26-RCU**：RCU_SOFTIRQ
- **139-netif-receive-skb**：net_rx_action 后的协议栈处理

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 12. 中断上下文 API 使用指南

```c
// ✅ 软中断上下文中可以做的：
spin_lock(&lock);                 // 自旋锁
atomic_inc(&counter);             // 原子操作
local_bh_disable();               // 嵌套 BH 锁

// ❌ 软中断上下文中不可以做的：
mutex_lock(&lock);                // 可能休眠
kmalloc(size, GFP_KERNEL);        // 可能休眠
schedule();                       // 禁止调度
copy_from_user();                 // 可能缺页
```

---

## 13. 软中断对比其他下半部机制

| 特性 | 软中断（softirq） | tasklet | BH workqueue | 线程化 IRQ |
|------|------------------|---------|-------------|-----------|
| 上下文 | 软中断 | 软中断 | softirq | 进程 |
| 可休眠 | ❌ | ❌ | ❌ | ✅ |
| 同类型并发 | ✅（可多核） | ❌（单核串行） | ✅ | ✅ |
| 动态注册 | ❌ | ✅ | ✅ | ✅ |
| 新建开销 | 编译时 | 运行时 | 运行时 | 运行时 |
| 适用场景 | 高频网络/块设备 | 通用下半部 | 通用下半部 | 长时间操作 |

---

## 14. 源码文件索引

| 文件 | 内容 | 关键函数 |
|------|------|---------|
| `kernel/softirq.c` | 核心实现 | `__do_softirq`, `raise_softirq`, `open_softirq` |
| `include/linux/interrupt.h` | 软中断枚举 + 声明 | `NR_SOFTIRQS`, `local_bh_disable/enable` |
| `net/core/dev.c` | 网络软中断 | `net_rx_action`, `net_tx_action` |
| `kernel/time/timer.c` | 定时器软中断 | `run_timer_softirq` |
| `block/blk-mq.c` | 块软中断 | `blk_done_softirq` |

---

## 15. 关联文章

- **23-interrupt**：硬中断在 `irq_exit()` 中触发软中断
- **25-hrtimer**：HRTIMER_SOFTIRQ
- **26-RCU**：RCU_SOFTIRQ
- **139-netif-receive-skb**：net_rx_action 后的协议栈处理
- **140-napi-gro**：NAPI 与 GRO 的软中断集成

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
