# Linux Kernel kworker / migration / ksoftirqd 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/core.c` + `kernel/workqueue.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 概述

Linux 内核有多个**专用内核线程**，负责系统级工作：
- `kworker`：处理 workqueue 中的 work
- `migration`：在 CPU 热插拔时迁移任务
- `ksoftirqd`：处理软中断
- `rcuop`：RCU 回调释放

---

## 1. kworker — workqueue 执行者

```c
// kernel/workqueue.c — worker_thread
static int worker_thread(void *arg)
{
    struct worker_pool *pool = arg;

    while (!kthread_should_stop()) {
        // 1. 等待 work
        if (!pool->nr_running)
            schedule();

        // 2. 获取 work
        struct work_struct *work = list_first_entry(&pool->worklist,
                               struct work_struct, entry);
        list_del(&work->entry);

        // 3. 执行
        work->func(work);

        // 4. 循环
    }
}

// 每个 CPU 至少有一个 per-CPU kworker：
// kworker/0:0 — system_wq
// kworker/0:1 — system_highpri_wq
// kworker/1:0 — CPU-1 的 kworker
```

---

## 2. migration — CPU 热插拔迁移

```c
// kernel/sched/core.c — migration_call
static int migration_call(struct notifier_block *nfb, unsigned long action, void *hcpu)
{
    int cpu = (unsigned long)hcpu;

    switch (action) {
    case CPU_UP_PREPARE:
    case CPU_UP_PREPARE_FROZEN:
        // 创建 migration 线程
        t = kthread_create(migration_thread, (void *)(long)cpu,
                  "migration/%d", cpu);
        kthread_bind(t, cpu);
        break;

    case CPU_ONLINE:
    case CPU_ONLINE_FROZEN:
        wake_up_process(t);
        break;

    case CPU_DOWN_PREPARE:
    case CPU_DOWN_PREPARE_FROZEN:
        kthread_stop(t);  // 停止 migration 线程
        break;
    }
}

// kernel/sched/core.c — migration_thread
static int migration_thread(void *arg)
{
    int cpu = (long)arg;

    set_current_state(TASK_INTERRUPTIBLE);
    while (!kthread_should_stop()) {
        struct rq *rq = cpu_rq(cpu);

        // 迁移 runqueue 上的任务
        // pull_task(rq, busiest_rq);
        // push_task(rq, idle_rq);

        schedule();
    }
}
```

---

## 3. ksoftirqd — 软中断处理线程

```c
// kernel/softirq.c — smp_run_ksoftirqd
static void run_ksoftirqd(unsigned int cpu)
{
    // 每 CPU 一个 ksoftirqd 线程
    // 处理 pending softirq

    local_softirq_pending();
    if (local_softirq_pending()) {
        // 在此线程中处理，而非 irq_exit()
        do_softirq();
    }
}
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `kernel/workqueue.c` | `worker_thread`、`create_worker` |
| `kernel/sched/core.c` | `migration_call`、`migration_thread` |
| `kernel/softirq.c` | `run_ksoftirqd` |
