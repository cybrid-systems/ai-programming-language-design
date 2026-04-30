# 24-softirq — 软中断深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/softirq.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**softirq** 是 Linux 中断处理的"底半部"（bottom half）：硬件中断处理程序执行完后，触发软中断在更安全的环境（开中断）执行延迟处理。

---

## 1. 软中断类型

```c
// include/linux/interrupt.h — softirq 类型
enum {
    HI_SOFTIRQ = 0,      // 高优先级任务（tasklet）
    TIMER_SOFTIRQ,       // 定时器
    NET_TX_SOFTIRQ,      // 网络发送
    NET_RX_SOFTIRQ,      // 网络接收
    BLOCK_SOFTIRQ,       // 块设备
    IRQ_POLL_SOFTIRQ,    // IRQ poll
    TASKLET_SOFTIRQ,     // tasklet（小任务）
    SCHED_SOFTIRQ,      // 调度
    HRTIMER_SOFTIRQ,     // 高精度定时器
    NMI_SOFTIRQ,
};
```

---

## 2. softirq_vec — 软中断向量表

```c
// kernel/softirq.c — softirq_vec
struct softirq_action {
    void            (*action)(struct softirq_action *);
};

static struct softirq_action softirq_vec[NR_SOFTIRQS];

// 注册软中断：
open_softirq(TIMER_SOFTIRQ, run_timer_softirq);
```

---

## 3. raise_softirq — 触发软中断

### 3.1 raise_softirq

```c
// kernel/softirq.c — raise_softirq
void raise_softirq(unsigned int nr)
{
    // 1. 在当前 CPU 的 softirq_pending 标记位置位
    or_softirq_pending(1UL << nr);

    // 2. 如果在中断上下文，标记需要处理
    //    如果在进程上下文，触发软中断处理
    if (!in_interrupt())
        wakeup_softirqd();
}
```

---

## 4. do_softirq — 处理软中断

### 4.1 do_softirq

```c
// kernel/softirq.c — do_softirq
asmlinkage void do_softirq(void)
{
    __u32 pending;

    // 1. 获取当前 CPU 的 pending 位图
    pending = local_softirq_pending();

    if (pending) {
        // 2. 打开本地中断（允许嵌套）
        local_irq_enable();

        // 3. 处理 pending 的软中断
        do_softirq_part(pending);

        // 4. 关闭本地中断
        local_irq_disable();
    }
}
```

### 4.2 __do_softirq

```c
// kernel/softirq.c — __do_softirq
asmlinkage void __do_softirq(void)
{
    struct softirq_action *h;
    __u32 max_restart = MAX_SOFTIRQ_RESTART;
    unsigned long old_flags = current->flags;

    // 每个软中断最多处理 MAX_SOFTIRQ_RESTART=10 次
    for (;;) {
        set_softirq_pending(0);

        // 打开本地中断（允许硬件中断打断）
        local_irq_enable();

        // 执行所有 pending 的软中断处理函数
        h = softirq_vec;
        pending &= softirq_pending();
        while (pending) {
            unsigned int vec = __ffs(pending);
            pending &= ~(1UL << vec);
            h += vec;
            h->action(h);  // 调用处理函数
            h = softirq_vec;
        }

        local_irq_disable();  // 关闭中断

        pending = local_softirq_pending();
        if (!pending)
            break;

        if (--max_restart)
            break;
    }
}
```

---

## 5. tasklet — 任务let

### 5.1 tasklet_struct

```c
// include/linux/interrupt.h — tasklet_struct
struct tasklet_struct {
    struct list_head        list;           // 链表
    unsigned long           state;           // TASKLET_STATE_* 状态
    atomic_t               count;          // 引用计数（0=启用）
    void                  (*func)(unsigned long); // 处理函数
    unsigned long          data;            // 参数
};
```

### 5.2 tasklet_schedule

```c
// include/linux/interrupt.h — tasklet_schedule
static inline void tasklet_schedule(struct tasklet_struct *t)
{
    if (!test_and_set_bit(TASKLET_STATE_SCHED, &t->state))
        raise_softirq(TASKLET_SOFTIRQ);
}
```

---

## 6. 内存布局图

```
中断处理时序：

硬件中断（IRQ）→ 硬件处理函数 → raise_softirq()
                                    ↓
                          标记 softirq_pending 位
                                    ↓
                          do_softirq() 在以下时机执行：
                            1. IRQ 处理完成后（irq_exit）
                            2. ksoftirqd 内核线程
                            3. 显式调用
                                    ↓
                          __do_softirq() 遍历 pending 位图
                                    ↓
                          执行各软中断处理函数：
                            NET_TX_SOFTIRQ → 网络发送
                            TIMER_SOFTIRQ → 定时器
                            TASKLET_SOFTIRQ → tasklet
```

---

## 7. 与硬件中断的区别

| 特性 | 硬件中断 | 软中断 |
|------|----------|--------|
| 上下文 | 中断上下文（禁中断）| 软中断上下文 |
| 并发 | 不允许嵌套 | 可被硬件中断打断 |
| 速度 | 越快越好 | 可稍慢 |
| 睡眠 | 禁止 | 禁止 |

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/interrupt.h` | `enum softirq_type`、`struct tasklet_struct` |
| `kernel/softirq.c` | `raise_softirq`、`__do_softirq`、`do_softirq` |

---

## 9. 西游记类比

**softirq** 就像"取经路上的紧急任务委托"——

> 悟空（CPU）在巡逻时（进程上下文），有紧急军情（硬件中断）来了，他必须立即处理。但有些事很耗时（处理网络包），不适合在紧急状态下做。于是悟空把任务委托（raise_softirq）给天兵天将（ksoftirqd 线程）。天兵处理完任务后，会通知悟空（wakeup_softirqd）。这样做的好处是：紧急状态（中断上下文）越快越好，耗时任务交给专门的信使（软中断线程）处理，两者互不耽误。

---

## 10. 关联文章

- **interrupt**（article 23）：软中断由硬件中断触发
- **hrtimer**（article 25）：高精度定时器使用 HRTIMER_SOFTIRQ