# Linux Kernel Softirq 与 Tasklet 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/softirq.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 Softirq？

**Softirq** 是 Linux 的**可延迟中断处理**机制，在中断处理函数（下半部）执行：
- **硬件中断处理函数**执行后，检查并执行 pending softirq
- 允许多个 softirq 并发执行（不同 CPU）
- 用于高频率、要求快速响应的延迟工作

**常见 softirq 类型**：
```
HI_SOFTIRQ     — 高优先级 tasklet
TIMER_SOFTIRQ  — 定时器
NET_TX_SOFTIRQ — 发送网络包
NET_RX_SOFTIRQ — 接收网络包
BLOCK_SOFTIRQ  — 块设备完成
IRQ_POLL_SOFTIRQ — IRQ 轮询
TASKLET_SOFTIRQ — 普通 tasklet
SCHED_SOFTIRQ  — 调度相关
HRTIMER_SOFTIRQ — 高精度定时器
```

---

## 1. softirq 核心数据结构

```c
// kernel/softirq.c — softirq 向量表
static struct softirq_action {
    void    (*action)(struct softirq_action *);
} softirq_vec[NR_SOFTIRQS];

// per-CPU pending 位图
DEFINE_PER_CPU(__u32, local_softirq_pending);

// softirq 标志
enum {
    HI_SOFTIRQ    = 0,
    TIMER_SOFTIRQ = 1,
    NET_TX_SOFTIRQ = 2,
    NET_RX_SOFTIRQ = 3,
    BLOCK_SOFTIRQ = 4,
    IRQ_POLL_SOFTIRQ = 5,
    TASKLET_SOFTIRQ = 6,
    SCHED_SOFTIRQ = 7,
    HRTIMER_SOFTIRQ = 8,
    RCU_SOFTIRQ = 9,
    NR_SOFTIRQS = 10
};
```

---

## 2. raise_softirq — 触发 softirq

```c
// kernel/softirq.c — raise_softirq
void raise_softirq(unsigned int nr)
{
    // 设置 pending 位
    set_bit(nr, &local_softirq_pending(smp_processor_id()));

    // 如果在中断上下文且不在线程化 irq 中，触发软中断
    if (!in_hardirq())
        irq_enter();
        do_softirq();
        irq_exit();
}
```

---

## 3. do_softirq — 执行 softirq

```c
// kernel/softirq.c — do_softirq
asmlinkage __visible void do_softirq(void)
{
    __u32 pending;
    unsigned long flags;

    if (in_interrupt())  // 已经在硬中断中，跳过
        return;

    pending = local_softirq_pending();

    // 遍历所有 pending softirq
    while (pending) {
        struct softirq_action *h;

        // 清除 pending 位
        __local_softirq_pending_reset(pending);

        // 执行 softirq action
        h = softirq_vec + action_nr;
        h->action(h);

        pending = local_softirq_pending();
    }
}
```

---

## 4. tasklet — 基于 softirq 的线程化延迟

```c
// kernel/softirq.c — tasklet
struct tasklet_struct {
    struct tasklet_struct *next;
    unsigned long state;          // TASKLET_STATE_SCHED / TASKLET_STATE_RUN
    atomic_t count;               // 引用计数，0 表示启用
    void (*func)(unsigned long); // 回调函数
    unsigned long data;           // 参数
};

// tasklet_schedule — 调度 tasklet
void tasklet_schedule(struct tasklet_struct *t)
{
    if (!atomic_read(&t->count)) {  // 检查是否启用
        if (!test_and_set_bit(TASKLET_STATE_SCHED, &t->state))
            raise_softirq(TASKLET_SOFTIRQ);  // 触发 TASKLET_SOFTIRQ
    }
}

// TASKLET_SOFTIRQ 处理函数
static void tasklet_action(struct softirq_action *a)
{
    // 遍历 per-CPU tasklet_vec，顺序执行每个 tasklet
}
```

---

## 5. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| per-CPU pending 位图 | 无锁检查（local_softirq_pending），减少竞争 |
| softirq 在 irq_exit 中检查 | 硬件中断处理完后立即执行，低延迟 |
| tasklet 基于 softirq | 简化驱动开发，不需要注册 softirq handler |
| atomic_t count 控制 tasklet | 禁用/启用 tasklet 的标准方式 |

---

## 6. 参考

| 文件 | 内容 |
|------|------|
| `kernel/softirq.c` | `raise_softirq`、`do_softirq`、`tasklet_schedule`、`tasklet_action` |
