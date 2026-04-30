# 207-workqueue — 工作队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/workqueue.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**workqueue** 是内核的延迟执行机制，将工作（函数）排队由工作线程执行。

---

## 1. 核心结构

```c
// kernel/workqueue.c — work_struct
struct work_struct {
    atomic_long_t data;           // 回调函数数据
    struct list_head entry;       // 链表
    work_func_t func;             // 回调函数
};

// workqueue_struct — 队列
struct worker_pool {
    struct cpu_workqueue_struct *cwq;  // per-CPU
    struct list_head worklist;          // 待处理工作
    struct worker *worker;              // 工作线程
};
```

---

## 2. 队列类型

```c
// 系统工作队列（全局）：
system_wq    — 系统队列
system_long_wq — 长任务队列
system_unbound_wq — unbound 队列（不绑定 CPU）
system_freezable_wq — 可冻结队列

// 创建专用队列：
alloc_workqueue(name, flags, max_active)
```

---

## 3. schedule_work

```c
// kernel/workqueue.c — schedule_work
bool schedule_work(struct work_struct *work)
{
    return queue_work(system_wq, work);
}
```

---

## 4. 西游记类喻

**workqueue** 就像"天庭的任务分配中心"——

> workqueue 像任务分配中心，妖怪（驱动/子系统）把任务（work_struct）交给分配中心，分配中心再指派给工作线程执行。好处是不阻塞调用者——把任务一交，就回去继续做自己的事，工作线程会在合适的时候执行任务。

---

## 5. 关联文章

- **kthread**（article 14）：workqueue 底层用 kthread
- **softirq**（article 24）：workqueue 是 softirq 之外的延迟机制