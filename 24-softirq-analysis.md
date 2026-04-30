# softirq / tasklet — 软中断深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/softirq.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**软中断（softirq）** 是中断处理的**下半部**，在中断上下文中执行，用于处理紧急的延迟工作。

---

## 1. softirq 向量

### 1.1 软中断类型

```c
// include/linux/interrupt.h
enum {
    HI_SOFTIRQ = 0,      // 高优先级 tasklet（键盘、鼠标）
    TIMER_SOFTIRQ,      // 定时器下半部
    NET_TX_SOFTIRQ,     // 发送网络包
    NET_RX_SOFTIRQ,     // 接收网络包
    BLOCK_SOFTIRQ,      // 块设备完成
    IRQ_POLL_SOFTIRQ,    // IRQ poll
    TASKLET_SOFTIRQ,    // 普通 tasklet
    SCHED_SOFTIRQ,      // 调度器（负载均衡）
    HRTIMER_SOFTIRQ,    // 高精度定时器
    RCU_SOFTIRQ,        // RCU 回调
    NR_SOFTIRQS
};
```

---

## 2. 核心数据结构

### 2.1 softirq_data — per-CPU 软中断状态

```c
// kernel/softirq.c — softirq_vec
struct softirq_data {
    unsigned int            __softirqpending; // 待处理的软中断掩码
    unsigned int            hardirq_preempt_count; // 硬中断嵌套计数
    unsigned int            __nmi_count;   // NMI 计数
};

DEFINE_PER_CPU(struct softirq_data, softirq_data);
```

### 2.2 softirq_vec — 软中断向量

```c
// kernel/softirq.c
static struct softirq_action softirq_vec[NR_SOFTIRQS];

struct softirq_action {
    void        (*action)(struct softirq_action *);
};
```

---

## 3. raise_softirq — 触发软中断

```c
// kernel/softirq.c — raise_softirq
void raise_softirq(unsigned int nr)
{
    if (nr == NR_SOFTIRQS)
        return;

    local_softirq_pending_set(1u << nr);
    // 在中断上下文中会自动引发软中断
    // 在进程上下文中触发软中断线程 ksoftirqd
}
```

---

## 4. do_softirq — 执行软中断

```c
// kernel/softirq.c — do_softirq
asmlinkage void do_softirq(void)
{
    unsigned int pending = local_softirq_pending();

    if (pending) {
        struct softirq_action *h = softirq_vec;

        local_softirq_pending_set(0);

        do {
            if (pending & 1)
                h->action(h);
            h++;
            pending >>= 1;
        } while (pending);
    }
}
```

---

## 5. tasklet — 基于软中断的机制

```c
// kernel/softirq.c — tasklet
struct tasklet_struct {
    struct tasklet_struct   *next;       // 链表
    unsigned long           state;         // TASKLET_STATE_* 状态
    atomic_t                count;        // 引用计数（0 = 启用）
    void                  (*func)(unsigned long);
    unsigned long           data;         // 参数
};
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/softirq.c` | `do_softirq`、`raise_softirq`、`tasklet_schedule` |
| `include/linux/interrupt.h` | `enum softirq_nr` |
