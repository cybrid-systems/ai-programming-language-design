# 185-init_task — 初始化进程深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`init/init_task.c` + `kernel/sched/core.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**init_task**（PID 0，swapper）是 Linux 启动的第一个进程，是所有其他进程的祖先，运行在 manual CPU 上。

---

## 1. init_task 结构

```c
// init/init_task.c
struct task_struct init_task = {
    .state = 0,                      // 运行状态
    .stack = init_stack,             // 内核栈
    .usage = REFCOUNT_INIT(2),
    .flags = PF_KTHREAD,            // 是内核线程
    .prio = MAX_PRIO-20,          // 最高优先级
    .static_prio = MAX_PRIO-20,
    .normal_prio = MAX_PRIO-20,
    .policy = SCHED_FIFO,
    .cpus_ptr = &init_task.cpus_mask,
    .cpu = 0,
    .tasks = LIST_HEAD_INIT(init_task.tasks),
    .se = {
        .load = { .weight = scale_load(NICE_0_LOAD) },
        .vruntime = 0,
    },
    .mm = NULL,                     // 没有用户空间
    .active_mm = &init_mm,
};
```

---

## 2. idle 进程

```c
// 每个 CPU 都有一个 idle 进程（PID 0 的副本）
// cpu_startup_entry → cpu_idle_loop
// 在没有其他任务运行时，调度 idle 进程
```

---

## 3. 西游记类喻

**init_task** 就像"开天辟地的那位神仙"——

> init_task 是天地初开时第一个出现的神仙（PID 0），所有其他神仙（进程）都是这位神仙的后代。它没有自己的营房（mm = NULL），只在天庭大厅（kernel space）活动。这位神仙永远在，除非天庭空了（没有其他进程运行）。这就是为什么 PID 0 是所有进程的祖先。

---

## 4. 关联文章

- **scheduler**（相关）：init_task 是调度器的起点
- **cgroup**（article 135）：init_task 是 root cgroup 的成员