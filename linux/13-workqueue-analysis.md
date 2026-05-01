# 13-workqueue — 工作队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**工作队列（workqueue）** 是 Linux 内核中"在进程上下文异步执行工作"的标准机制。它允许将延迟处理（中断下半部、周期性任务、IO 完成）交给一组内核线程执行。

与 tasklet/softirq 不同，workqueue 运行在进程上下文——可以睡眠、持有 mutex、执行文件系统操作。

CMWQ（Concurrency Managed WorkQueue，Linux 3.11 引入）是 workqueue 的重大重构。核心创新：**不再为每个 workqueue 创建独立线程池，所有 workqueue 共享全局 per-CPU 线程池，自动管理并发度。**

doom-lsp 确认 `kernel/workqueue.c` 包含约 800+ 个符号，是内核中最复杂的子系统之一。

---

## 1. 核心数据结构

### 1.1 struct work_struct——工作项

```c
struct work_struct {
    atomic_long_t data;          // 低 bits = 标志，高 bits = worker pool ID
    struct list_head entry;      // 在 worklist 中的链表节点
    work_func_t func;            // 工作函数
};
```

`data` 字段的位编码（doom-lsp 确认 `include/linux/workqueue.h` 中的定义）：

```
  bit 0:     WORK_STRUCT_PENDING_BIT —— 工作等待处理
  bit 1:     WORK_STRUCT_BUSY_BIT    —— 正在执行
  bit 2-6:   WORK_STRUCT_COLOR_SHIFT —— 颜色位（flush 跟踪）
  bit 7+:    WORK_STRUCT_PWQ_SHIFT   —— 所属 pool_workqueue ID
```

### 1.2 struct worker_pool——线程池

```c
struct worker_pool {
    spinlock_t          lock;         // 保护池数据
    struct list_head    worklist;     // 待处理工作链表
    int                 nr_workers;   // 工作线程总数
    int                 nr_idle;      // 空闲线程数
    struct list_head    idle_list;    // 空闲线程链表
    struct timer_list   idle_timer;   // 空闲超时销毁
    struct workqueue_attrs *attrs;    // nice + cpumask
    ...
};
```

### 1.3 struct worker——工作线程

```c
struct worker {
    struct list_head    entry;         // 在 idle_list 或 busy_list 中
    struct work_struct  *current_work; // 正在执行的工作
    struct list_head    scheduled;     // 已调度的工作链表
    struct task_struct  *task;         // 对应的内核线程
    struct worker_pool  *pool;         // 所属池
    ...
};
```

---

## 2. CMWQ 架构

```
CMWQ 的层次结构：

全局 worker_pool（per CPU）：
  CPU 0: [pool: normal nice=0] [pool: highpri nice=-20]
  CPU 1: [pool: normal nice=0] [pool: highpri nice=-20]
  ...

Unbound worker_pool（不绑定 CPU）：
  [pool: normal] [pool: highpri] ...

workqueue 只记录"应该把工作提交到哪个 pool"：
  system_wq         → 映射到 per-CPU normal pool
  system_highpri_wq → 映射到 per-CPU highpri pool
  system_unbound_wq → 映射到 unbound pool
```

关键：**N 个 workqueue 共享 M 个 worker_pool（M << N）**，而不是每个 workqueue 有自己的线程。

---

## 3. 工作提交路径

```
queue_work(wq, work)                     ← API 入口
  │
  └─ queue_work_on(WORK_CPU_UNBOUND, wq, work)
       │
       └─ __queue_work(cpu, wq, work)     ← workqueue.c 核心
            │
            ├─ 选择目标 worker_pool
            │    └─ wq 根据 workqueue_attrs 映射到 pool
            │
            ├─ spin_lock(&pool->lock)
            │
            ├─ 检查 work 是否已经在 pending 状态
            │    └─ test_bit(WORK_STRUCT_PENDING, &work->data)
            │    └─ 如果是 → 跳过（防止重复提交）
            │
            ├─ 设置 WORK_STRUCT_PENDING 位
            ├─ work->entry 加入 pool->worklist 尾部
            │
            ├─ 如果有空闲 worker
            │    └─ wake_up_worker(pool)  ← 唤醒来处理
            │
            └─ spin_unlock(&pool->lock)
```

doom-lsp 确认 `__queue_work` 是该流程的核心函数（`workqueue.c` 中定义）。

---

## 4. 工作执行路径

```
worker_thread(worker)                    ← kworker 线程主循环
  │
  ├─ 循环：
  │    │
  │    ├─ 检查 kthread_should_stop() → 退出
  │    │
  │    ├─ 从 pool->worklist 取一个 work
  │    │    └─ 如果 worklist 为空 → 加入 idle_list
  │    │
  │    ├─ set_work_current(worker, work)  ← 标记正在执行
  │    │
  │    ├─ work->func(work)                ← 调用工作函数
  │    │
  │    ├─ clear_work_data(work)           ← 清除 WORK_STRUCT_PENDING/BUSY
  │    │
  │    └─ 检查是否需要创建更多 worker
  │         └─ maybe_create_worker(pool)
  │
  └─ 空闲超时（idle_timer）
       └─ destroy_worker(worker)          ← 销毁空闲线程
```

doom-lsp 确认 `process_one_work` 是工作执行的核心函数。

---

## 5. flush 机制

```
flush_work(work)                         ← 等待特定 work 完成
  │
  └─ start_flush_work(work, &barr)
       ├─ 检查 work 是否已完成
       ├─ 如果还在 pending 或正在执行
       │    └─ 插入 barrier 到同一 pool
       │         └─ barrier 是一个特殊的 work
       │              完成后通过 completion 通知等待者
       │
       └─ wait_for_completion(&barr.done)

flush_workqueue(wq)                      ← 等待 wq 中所有 work 完成
  └─ 使用颜色位跟踪：
       ├─ 增加 flush color
       ├─ 等待该颜色的所有 work 完成
       └─ wq->flush_color 与 work->data 颜色位匹配
```

---

## 6. delayed_work——延迟执行

```c
struct delayed_work {
    struct work_struct work;     // 实际的工作项
    struct timer_list timer;     // 延迟定时器
};
```

`schedule_delayed_work(&dwork, delay)`：
1. 启动定时器（timer）
2. 定时器到期后 → 将 dwork 提交到 worklist
3. work 在 worker 中正常执行

---

## 7. 数据流全景

```
schedule_work(&work)
  │
  └─ __queue_work(cpu, system_wq, &work)
       ├─ 选择正常优先级 pool
       ├─ 加入 pool->worklist
       └─ wake_up_worker(pool)
            │
            ├─ worker_thread()
            │    └─ process_one_work(worker, work)
            │         └─ work->func(work)        ← 用户的工作
            │
            └─ 完成后唤醒 flush 等待者

flush_work(&work)
  └─ 等待直到 work 不再 BUSY
```

---

## 8. 设计决策总结

| 决策 | 原因 |
|------|------|
| CMWQ 共享线程池 | 减少线程数量，降低上下文切换 |
| WORK_STRUCT_PENDING 标志 | 防止同一 work 被同时提交多次 |
| 颜色位 flush | 精确跟踪哪些工作已在新 flush 前完成 |
| idle_timer 自动销毁 | 资源回收，空闲线程不占 CPU |
| rescuer 线程 | 防止内存回收时 workqueue 死锁 |

---

## 9. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/workqueue.h` | `struct work_struct` | 定义 |
| `include/linux/workqueue.h` | `queue_work` / `schedule_work` | API |
| `kernel/workqueue.c` | `__queue_work` | 提交核心 |
| `kernel/workqueue.c` | `process_one_work` | 执行核心 |
| `kernel/workqueue.c` | `worker_thread` | 线程主循环 |
| `kernel/workqueue.c` | `flush_work` | flush 逻辑 |

---

## 10. 关联文章

- **kthread**（article 14）：worker 在底层是内核线程
- **softirq**（article 24）：workqueue 与 softirq 的对比
- **interrupt**（article 23）：中断下半部的两种实现方式

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
