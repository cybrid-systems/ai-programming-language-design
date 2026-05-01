# 13-workqueue — 工作队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**工作队列（workqueue）** 是 Linux 内核中"在进程上下文异步执行工作"的标准机制。它允许内核代码将需要延迟处理的任务（如中断下半部、周期性任务、IO 完成回调）交给一组内核线程去执行。

与 tasklet/softirq 不同，workqueue 运行在进程上下文，可以睡眠、持有 mutex、执行文件系统操作等。

doom-lsp 确认 `kernel/workqueue.c` 包含约 800+ 个符号，是内核中较复杂的子系统之一。

---

## 1. 核心数据结构

### 1.1 struct worker_pool

```c
struct worker_pool {
    spinlock_t          lock;         // 保护池的数据
    struct list_head    worklist;     // 待处理的工作链表
    int                 nr_workers;   // 工作线程数
    int                 nr_idle;      // 空闲线程数
    struct list_head    idle_list;    // 空闲线程链表
    struct timer_list   idle_timer;   // 空闲超时
    struct workqueue_attrs *attrs;    // 池属性（nice、cpumask）
    ...
};
```

每个 worker_pool 是**一组相同属性的工作线程**。属性包括 CPU 亲和性和优先级。

### 1.2 struct worker

```c
struct worker {
    union {
        struct list_head entry;       // 在 idle_list 或 busy_list 中
    };
    struct work_struct  *current_work; // 正在执行的工作
    struct list_head    scheduled;     // 已调度的工作链表
    struct task_struct  *task;         // 对应的内核线程
    struct worker_pool  *pool;         // 所属的池
    ...
};
```

每个 worker 就是一个具体的内核线程，从池中获取工作执行。

### 1.3 struct work_struct

```c
struct work_struct {
    atomic_long_t data;     // 低 bits = 标志，高 bits = 所属池
    struct list_head entry; // 在 worklist 中的节点
    work_func_t func;       // 工作函数
};
```

`data` 的编码：
- bit 0: WORK_STRUCT_PENDING（工作待处理）
- bit 1: WORK_STRUCT_BUSY（正在执行）
- bit 2-7: 颜色位（用于 flush 检测）
- bit 8+: worker_pool ID 或 worker 指针

---

## 2. 工作流

### 2.1 提交工作（queue_work）

```
queue_work(wq, work)
  │
  └─ queue_work_on(WORK_CPU_UNBOUND, wq, work)
       │
       ├─ 选择目标 worker_pool
       │    └─ 绑定 wq → 对应的 per-CPU pool
       │
       ├─ __queue_work(cpu, wq, work)
       │    │
       │    ├─ spin_lock(&pool->lock)
       │    │
       │    ├─ 如果 work 已经 pending → 跳过
       │    │    └─ (WORK_STRUCT_PENDING 标志已设置)
       │    │
       │    ├─ 设置 WORK_STRUCT_PENDING
       │    ├─ list_add_tail(&work->entry, &pool->worklist)
       │    │
       │    ├─ 如有空闲 worker → 唤醒它
       │    │    └─ wake_up_worker(pool)
       │    │
       │    └─ spin_unlock(&pool->lock)
```

### 2.2 工作线程执行（worker_thread）

```
worker_thread(worker)
  │
  ├─ 循环：
  │    ├─ 检查 kthread_should_stop() → 退出
  │    │
  │    ├─ 从 pool->worklist 取出一个 work
  │    │    └─ 如果 worklist 为空 → 进入 idle_list
  │    │
  │    ├─ set_worker_current(worker, work)  标记正在执行
  │    │
  │    ├─ work->func(work)                  执行工作函数
  │    │
  │    ├─ clear_work_data(work)             清除标志
  │    │
  │    └─ 可能的后续处理：
  │         └─ 检查是否需要创建更多 worker
  │         └─ 检查是否该销毁空闲 worker
```

---

## 3. CMWQ（Concurrency Managed Workqueue）

CMWQ 是 Linux 3.11 引入的重大重构。核心思想：**自动管理工作线程数量，避免创建过多线程。**

传统 workqueue 的缺陷：
- 每个 workqueue 都有自己的线程池
- 大量 workqueue → 大量线程 → 大量上下文切换

CMWQ 的解决：
```
全局 worker_pool（per-CPU）：
  CPU 0: [highpri pool] [normal pool]
  CPU 1: [highpri pool] [normal pool]
  ...

workqueue（"用户"视角）：
  system_wq → 映射到 per-CPU normal pools
  system_highpri_wq → 映射到 per-CPU highpri pools

每个 workqueue 不再拥有自己的线程——所有 workqueue 共享全局 worker_pool
```

通过 `alloc_workqueue()` 创建的自定义 workqueue 可以指定：
- `WQ_UNBOUND`：不受 CPU 绑定限制
- `WQ_HIGHPRI`：高优先级执行
- `WQ_CPU_INTENSIVE`：CPU 密集型（避免影响并发管理）
- `max_active`：最大并发执行数

---

## 4. Flush 机制

```
flush_workqueue(wq)
  │
  └─ 等待 wq 中所有已提交的工作完成
       ├─ 增加 flush color
       ├─ 等待该颜色对应的所有工作完成
       └─ 通过 completion 同步

flush_work(work)
  └─ 等待特定 work 完成
       └─ 如果 work 已经完成 → 立即返回
       └─ 否则 → 通过 completion 等待
```

---

## 5. 数据类型流

```
提交：
  schedule_work(&my_work)
    → queue_work(system_wq, &my_work)
       → __queue_work(cpu, wq, &my_work)
          → pool->worklist 尾部添加
          → 唤醒空闲 worker

执行：
  worker_thread
    → process_one_work(worker, work)
       → work->func(work)           ← 您的处理函数
       → 如果 work 是 delayed_work
            → 先等 timer 超时再执行

flush：
  flush_work(&my_work)
    → 等待 work 的完成标记
```

---

## 6. 设计决策总结

| 决策 | 原因 |
|------|------|
| CMWQ 共享线程池 | 减少线程数量，降低上下文切换 |
| worker_pool 按属性分类 | 优先级/CPU 亲和性隔离 |
| WORK_STRUCT_PENDING 标志 | 防止同一 work 同时被多次提交 |
| 颜色位 flush | 精确跟踪哪些工作已完成 |
| idle_timer | 自动销毁空闲线程，回收资源 |

---

## 7. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/workqueue.h` | `struct work_struct` | 定义 |
| `include/linux/workqueue.h` | `queue_work` / `schedule_work` | 内联 |
| `kernel/workqueue.c` | `__queue_work` | 核心提交逻辑 |
| `kernel/workqueue.c` | `process_one_work` | 工作执行 |
| `kernel/workqueue.c` | `worker_thread` | 线程循环 |
| `kernel/workqueue.c` | `alloc_workqueue` | wq 创建 |

---

## 8. 关联文章

- **kthread**（article 14）：worker 在底层是 kthread
- **中断**（article 23）：workqueue 是中断下半部的一种实现
- **softirq/tasklet**（article 24）：与 workqueue 对比的另一种下半部机制

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
