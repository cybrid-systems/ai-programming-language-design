# 13-workqueue — Linux 内核工作队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**workqueue（工作队列）** 是 Linux 内核中最常用的异步执行机制。它允许内核代码将工作（work）提交到队列中，由内核线程在**进程上下文**中异步执行。与 softirq/tasklet 等中断下半部机制相比，workqueue 的最大优势是工作函数可以休眠——因为它运行在进程上下文。

Workqueue 经历了三次架构演进：

1. **传统 workqueue**（2.6.x）—— 每个 workqueue 一个专用内核线程（keventd），多 workqueue 导致大量线程
2. **CMWQ（Concurrency Managed Workqueue）**（3.x）—— 引入 worker_pool 和线程池化的概念，由 Tejun Heo 设计
3. **BH workqueue**（7.0-rc1）—— 新增 `BH` 模式，替代 tasklet/softirq，提供可休眠的下半部执行环境

当前 kernel 7.0-rc1 中的 workqueue 包含两种执行上下文：
- **普通 workqueue**（`WQ_UNBOUND` 或 per-CPU）：工作在线程上下文（可休眠）
- **BH workqueue**（`WQ_BH`）：工作在 softirq 上下文（不可休眠，但比普通线程更轻量）

**doom-lsp 确认**：`include/linux/workqueue.h` 包含 **159 个符号**（含 data/color 编码常量），`kernel/workqueue.c` 包含 **649 个符号**（整个内核最复杂的子系统之一）。

---

## 1. 核心数据结构

### 1.1 `struct work_struct`——工作单元

```c
// include/linux/workqueue.h
struct work_struct {
    atomic_long_t data;              // 编码池指针 + 标志位 + 颜色
    struct list_head entry;          // 链入 worker_pool 的工作链表
    work_func_t func;                // 工作函数（实际执行体）
};
```

**`data` 字段的位编码**（`workqueue.h:26-72`）：

```c
// 工作位的编码（低 10 位）：
#define WORK_STRUCT_PENDING_BIT     0   // bit 0: 工作是否待处理
#define WORK_STRUCT_INACTIVE_BIT    1   // bit 1: 工作是否非活跃
#define WORK_STRUCT_PWQ_BIT         2   // bit 2: data 指向 pwq 而非 pool
#define WORK_STRUCT_LINKED_BIT      3   // bit 3: 工作是否链式跟随
#define WORK_STRUCT_COLOR_SHIFT     4   // bit 4+: 颜色位（flush 跟踪）
#define WORK_STRUCT_COLOR_BITS      4   // 最多 16 种颜色

// 池指针的高位：
#define WORK_OFFQ_POOL_SHIFT        16  // bit 16+: worker_pool id
#define WORK_OFFQ_BH_BIT            14  // bit 14: BH 模式标记
```

**data 字段布局**（64-bit）：

```
data (atomic_long_t):
┌──────────────────────────┬──────────┬──────────┬──────┬───────┐
│    pool_id (高 48 位)      │ BH bit   │ 颜色(4b) │ LINK │ PWQ │ INACTIVE│PENDING │
│                           │ bit 14   │ bits 4-7 │ bit3 │ bit2│ bit1   │ bit0  │
└──────────────────────────┴──────────┴──────────┴──────┴───────┴────────┴──────┘
```

### 1.2 `struct worker_pool`——线程池

```c
// kernel/workqueue.c — 每个 CPU 有 2 个 worker_pool
struct worker_pool {
    spinlock_t          lock;           // 保护池操作
    struct list_head    worklist;       // 待处理的工作链表
    int                 nr_workers;     // 工人线程数量
    int                 nr_idle;        // 空闲工人数量
    struct list_head    idle_list;      // 空闲工人链表
    struct timer_list   idle_timer;     // 空闲超时定时器
    struct idr          worker_idr;     // 工人 ID 管理
    struct workqueue_attrs *attrs;      // 池属性
    atomic_t            nr_running;     // 运行中工人计数
    struct worker       *manager;       // 管理者（创建/销毁工人）
    // ...
};
```

### 1.3 `struct worker`——工人线程

```c
struct worker {
    struct list_head    entry;          // 链入 idle_list 或 busy_hash
    struct list_head    scheduled;      // 已调度的工作链表
    struct task_struct  *task;          // 工人内核线程
    struct worker_pool  *pool;          // 所属池
    struct list_head    node;           // 链入 pool 的 worker 链表
    unsigned long       last_active;    // 最后活跃时间
    unsigned int        flags;          // WORKER_DIE/IDLE/PREP 等
    int                 id;             // 工人 ID
};
```

### 1.4 `struct workqueue_struct`——工作队列

```c
struct workqueue_struct {
    struct list_head    pwqs;           // 所有 pwq 链表
    struct list_head    list;           // 全局 workqueue 链表
    struct workqueue_attrs *attrs;      // 队列属性
    struct pool_workqueue *cpu_pwq;     // per-CPU pwq（普通模式）
    unsigned int        flags;          // WQ_UNBOUND, WQ_BH 等
    const char          *name;          // 队列名称
};
```

---

## 2. 架构模型

### 2.1 传统 per-CPU workqueue

```
每个 CPU 有两个 worker_pool：
  CPU 0: pool[0] (普通优先级) + pool[1] (高优先级)
  CPU 1: pool[0] (普通优先级) + pool[1] (高优先级)
  ...

workqueue → pwq (pool_workqueue) → worker_pool → workers (kworker/x:y)
                                                  → worklist (待处理工作)
```

**数据流**：

```
schedule_work(work)
  └─__queue_work(work, cpu=current)
       └─ 选择 pool: cpu_pool[current_cpu][priority]
            └─ pwq = wq->cpu_pwq[cpu]
                 └─ spin_lock(&pool->lock)
                      ├─ insert_work(pwq, work, &pool->worklist, 0)
                      │   └─ list_add_tail(&work->entry, head)
                      │   └─ set_bit(WORK_STRUCT_PENDING_BIT)
                      │
                      └─ wake_up_worker(pool)
                           └─ 如果池中有空闲工人 → 唤醒
                           └─ 如果池中无空闲工人且未达上限 → create_worker()
```

### 2.2 BH workqueue——替代 tasklet

Linux 7.0-rc1 引入了 `WQ_BH` 模式：

```c
// 创建 BH workqueue
struct workqueue_struct *wq = alloc_workqueue("my_bh_wq", WQ_BH, 0);

// 提交 BH 工作
local_bh_disable();
queue_work(wq, work);     // 在 softirq 上下文中执行
local_bh_enable();
```

BH workqueue 的特性：
- 工作在 softirq 上下文（`TASK_RUNNING` 状态）
- 不可休眠（与 tasklet 相同限制）
- 不需要 kworker 线程（无上下文切换开销）
- 替代传统的 tasklet 机制

---

## 3. 工作提交 API

| API | 行为 | 行号 |
|-----|------|------|
| `schedule_work(w)` | 提交到当前 CPU 默认 wq | — |
| `schedule_work_on(cpu, w)` | 提交到指定 CPU | — |
| `queue_work(wq, w)` | 提交到指定 wq（当前 CPU） | — |
| `queue_work_on(cpu, wq, w)` | 提交到指定 CPU 的指定 wq | — |
| `queue_delayed_work(wq, dwork, delay)` | 延迟提交 | — |
| `mod_delayed_work(wq, dwork, delay)` | 修改延迟时间 | — |

---

## 4. 工作执行——doom-lsp 数据流

```
kworker/x:y（工人线程主循环）
  │
  └─ worker_thread(worker)             @ kernel/workqueue.c
       │
       ├─ 循环：
       │   │
       │   ├─ 从 pool->worklist 取一个 work
       │   │   work = list_first_entry(&pool->worklist)
       │   │   list_del_init(&work->entry)
       │   │   clear_bit(WORK_STRUCT_PENDING_BIT)
       │   │
       │   ├─ 设置 WORKER_CPU_INTENSIVE 或 WORKER_UNBOUND
       │   │
       │   ├─ call_work_func(entry, work)
       │   │   └─ work->func(work)    ← 执行工作函数！
       │   │         用户提供的函数在这里运行
       │   │         可以安全地调用 schedule()、kmalloc(GFP_KERNEL) 等
       │   │
       │   ├─ 完成的处理：
       │   │   ├─ 如果 work 有 LINKED 位 → 跟踪链式工作
       │   │   └─ 通知 flush 等待者（颜色匹配）
       │   │
       │   └─ 检查是否需要更多工人、空闲超时等
       │
       └─ WORKER_DIE 或 pool 析构 → 退出
```

---

## 5. flush 机制——颜色计数

flush 是 workqueue 的核心能力——等待所有已提交的工作完成。实现基于**颜色计数**：

```
每个 work 在提交时分配一个颜色（0-15）：
  WORK_STRUCT_COLOR_BITS = 4 → 16 种颜色
  颜色循环使用

flush_workqueue(wq):
  └─ 记录当前颜色 → 等待该颜色之前的所有 work 完成
  
每个 worker_pool 维护：
  - nr_active (各颜色活跃计数)
  - 当所有 work 完成后 → 通知 flush 等待者
```

**颜色循环**：
```
work 提交 → 颜色+1 → 最多 16 种颜色 → 绕回
flush 等待 → 等待"当前颜色之前的颜色"全部完成
→ 保证 flush 时已提交的工作全部完成后才返回
```

---

## 6. 冻结（freeze）与暂停

Workqueue 支持暂停执行：

```c
// include/linux/workqueue.h
#define WORK_OFFQ_DISABLE_SHIFT  63  // 暂停标记
#define WORK_OFFQ_DISABLE_BITS   1
```

当系统进入休眠或暂停状态时，workqueue 可以被冻结——暂停所有的 worker 线程：

```
workqueue_freeze()
  └─ 遍历所有 pool → 设置 POOL_FROZEN
  └─ 等待所有工人完成当前工作
  └─ 冻结完成 → 系统可安全休眠

workqueue_thaw()
  └─ 清除所有 pool 的 POOL_FROZEN
  └─ 唤醒所有 worker 继续执行
```

---

## 7. rescuer 线程——紧急救援

当 workqueue 被创建时，如果设置了 `WQ_MEM_RECLAIM` 标志，系统会为此 workqueue 创建一个 **rescuer 线程**。当内存压力导致无法创建新 worker 时，rescuer 线程负责执行累积的工作：

```
条件：
  ┌─ pool->nr_workers 达到上限
  ├─ 内存回收路径中无法分配新的 kworker
  └─ pool->worklist 中有待处理工作

触发：
  → mayday 定时器触发
  → 唤醒 rescuer 线程
  → rescuer 接管执行 pool->worklist 中的工作
  → 处理完一批后检查是否需要继续
```

常量（`kernel/workqueue.c`）：
```c
#define MAYDAY_INITIAL_TIMEOUT  10  // 初始 mayday 超时 (HZ)
#define MAYDAY_INTERVAL         100 // 后续 mayday 间隔 (HZ/10)
#define RESCUER_BATCH           16  // rescuer 每次处理的工作数
```

---

## 8. 属性与 unbound workqueue

Unbound workqueue 不绑定到特定 CPU：

```c
// include/linux/workqueue.h — 属性
struct workqueue_attrs {
    int             nice;            // 优先级（nice 值）
    cpumask_var_t   cpumask;         // 允许的 CPU 掩码
    bool            no_numa;         // 禁用 NUMA 亲和性
};
```

```
alloc_workqueue("my_wq", WQ_UNBOUND | WQ_SYSFS, 0);
  → 不受 CPU 绑定限制
  → 可在任何 CPU 上执行
  → 通过 sysfs 暴露属性（可热调整 cpu mask 等）
```

---

## 9. 源码文件索引

| 文件 | 内容 | 符号数 |
|------|------|--------|
| `include/linux/workqueue.h` | 结构体 + API | **159 个** |
| `kernel/workqueue.c` | 完整实现 | **649 个** |
| `kernel/workqueue_internal.h` | 内部结构 | — |

---

## 10. 关联文章

- **24-softirq**：传统中断下半部与 workqueue 的关系
- **48-kworker**：kworker 线程的调度和管理
- **27-cgroup**：workqueue 与 cgroup 的集成

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
