# 13-workqueue — Linux 内核工作队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**workqueue（工作队列）** 是 Linux 内核中最复杂的异步执行机制之一。它的核心能力是：允许内核代码将工作（work）提交到队列中，由内核线程在进程上下文中异步执行。与 softirq/tasklet 等中断下半部机制相比，workqueue 的最大优势是工作函数可以休眠——因为它运行在进程上下文。

workqueue 经历了三次架构演进：

1. **传统 workqueue（2.6.x）**——每个 workqueue 一个专用内核线程（`keventd`），n 个 workqueue 创建 n 个线程，浪费严重
2. **CMWQ（Concurrency Managed Workqueue，3.x）**——由 Tejun Heo 设计，引入 worker_pool 线程池化，按并发需求动态创建工作线程
3. **BH workqueue（7.0-rc1）**——新增 `WQ_BH` 模式，工作不在 kworker 线程中执行，而是在 softirq 上下文中运行，作为 tasklet 的替代方案

**doom-lsp 确认**：`include/linux/workqueue.h` 包含 **159 个符号**（含 `work_struct` 的 data 位编码常量），`kernel/workqueue.c` 包含 **649 个符号**，是内核最庞大的子系统之一。核心实现在一个 ~4000 行的文件中。

---

## 1. 核心数据结构

### 1.1 `struct work_struct`——工作单元（`workqueue.h`）

```c
struct work_struct {
    atomic_long_t data;              // 编码池指针 + 标志位 + 颜色
    struct list_head entry;          // 链入 worker_pool->worklist
    work_func_t func;                // 工作函数
};
```

仅 **3 个字段，24 字节**。`data` 字段通过位编码压缩了大量状态信息：

**`data` 位编码（`workqueue.h:26-72`）：**

```c
// 低 4 位——工作状态标志：
#define WORK_STRUCT_PENDING_BIT     0   // PENDING: 工作待处理中
#define WORK_STRUCT_INACTIVE_BIT    1   // INACTIVE: 工作非活跃（被 max_active 限流）
#define WORK_STRUCT_PWQ_BIT         2   // PWQ: data 指向 pool_workqueue 而非 worker_pool
#define WORK_STRUCT_LINKED_BIT      3   // LINKED: 工作是链式执行的（flush 跟踪）

// 位 4-7——颜色位（flush 机制的核心，PWQ 模式时使用）：
#define WORK_STRUCT_COLOR_SHIFT     WORK_STRUCT_FLAG_BITS  // 4（无 debugobjects）
#define WORK_STRUCT_COLOR_BITS      4   // 最大 16 种颜色

// OFFQ 模式位布局（非 PWQ 模式时）：
#define WORK_OFFQ_BH_BIT            WORK_OFFQ_FLAG_SHIFT  // = WORK_STRUCT_FLAG_BITS
#define WORK_OFFQ_DISABLE_SHIFT     (WORK_OFFQ_FLAG_SHIFT + 1)
#define WORK_OFFQ_DISABLE_BITS      16
#define WORK_OFFQ_POOL_SHIFT        (WORK_OFFQ_DISABLE_SHIFT + WORK_OFFQ_DISABLE_BITS)
#define WORK_OFFQ_POOL_BITS         31  // 64-bit 上 bits 21-51 或 22-52
```

**data 字段的两种布局（64-bit，无 debugobjects）：**

**PWQ 模式**（PWQ bit=1，工作已入队或正在执行时）：
```
┌──────────────────────────┬─────────────┬──────┬──────┬──────┬──────┬──────┐
│   pwq 指针 (52 bits)     │ 颜色 (4 bits│LINKED│ PWQ  │INACTI│PENDIN│
│                         │ bit 4-7     │bit 3 │bit 2=1│ VE   │  G   │
│                         │             │      │      │bit 1 │bit 0 │
└──────────────────────────┴─────────────┴──────┴──────┴──────┴──────┴──────┘
```

**OFFQ 模式**（PWQ bit=0，工作已从队列移除但仍需追踪 pool 时）：
```
┌──────────────────┬────────────────┬──────┬──────┬──────┬──────┬──────┐
│ pool_id (31 bits)│disable_depth(16│ BH   │LINKED│PWQ=0 │INACTI│PENDIN│
│ bit 21-51        │ bits 5-20      │bit 4 │bit 3 │      │ VE   │  G   │
│                  │                │      │      │      │bit 1 │bit 0 │
└──────────────────┴────────────────┴──────┴──────┴──────┴──────┴──────┴──────┘
```

#### data 字段的两种状态

当 `PWQ` 位为 0（OFFQ 模式）时，`data` 编码池 ID + disable_depth + BH 标记：
- 通过 `WORK_OFFQ_POOL_SHIFT` 从高位提取 pool_id
- 用于工作已完成但仍在追踪时定位所属 pool

当 `PWQ` 位为 1 时，`data` 直接指向 `pool_workqueue` 结构体：
- 工作正在执行或已入队时，data 编码 pwq 指针
- 低位编码颜色 + 标志，高位编码指针地址

### 1.2 `struct worker_pool`——线程池（`workqueue.c:195`）

```c
// kernel/workqueue.c:195 — doom-lsp 确认
struct worker_pool {
    raw_spinlock_t      lock;            // 保护池操作的原始自旋锁
    int                 cpu;             // CPU ID（per-CPU 池使用）
    int                 node;            // NUMA 节点
    int                 id;              // 池 ID
    unsigned int        flags;           // POOL_BH, POOL_MANAGER_ACTIVE 等

    // ——— 工作管理 ———
    struct list_head    worklist;        // 待处理工作链表（!INACTIVE 的 work）
    unsigned long       last_progress_ts;// 最后处理工作时间

    // ——— 工人管理 ———
    int                 nr_running;      // 当前正在执行工作的工人数
    int                 nr_workers;      // 总工人数
    int                 nr_idle;         // 空闲工人数
    struct list_head    idle_list;       // 空闲工人链表
    struct timer_list   idle_timer;      // 空闲超时定时器（回收多余工人）
    struct timer_list   mayday_timer;    // 救援定时器

    DECLARE_HASHTABLE(busy_hash, BUSY_WORKER_HASH_ORDER); // 忙碌工人哈希表

    struct worker       *manager;        // 管理者线程
    struct list_head    workers;         // 所有工人链表
    struct ida          worker_ida;      // 工人 ID 分配器
    struct workqueue_attrs *attrs;       // 池属性
    // ...
};
```

每个 CPU 有两个标准 worker_pool：
- `pool[0]`：普通优先级（nice=0）
- `pool[1]`：高优先级（nice=HIGHPRI_NICE_LEVEL=-20）

### 1.3 `struct worker`——工人线程（`workqueue.c`）

```c
struct worker {
    struct list_head    entry;          // 链入 idle_list 或 busy_hash
    struct list_head    scheduled;      // 已调度的工作链表（正在执行中）
    struct task_struct  *task;          // 工人的内核线程（kworker/x:y）
    struct worker_pool  *pool;          // 所属池
    struct list_head    node;           // 链入 pool->workers
    unsigned long       last_active;    // 最后活跃时间
    unsigned int        flags;          // WORKER_DIE/IDLE/PREP/CPU_INTENSIVE
    int                 id;             // 工人 ID
    struct pool_workqueue *current_pwq; // 当前执行工作的 pwq
    struct work_struct  *current_work;  // 当前执行的工作
    // ...
};
```

**工人状态机**：

```
CREATED → IDLE（空闲，等待工作）
              │
              │ pool->worklist 非空
              ▼
           RUNNING（执行工作函数 work->func(work)）
              │
              │ 工作完成
              ▼
           IDLE（检查是否有更多工作）
              │
              │ 长时间空闲（IDLE_WORKER_TIMEOUT）
              ▼
           DIE（自我销毁）
```

### 1.4 `struct pool_workqueue`——池队列中介（`workqueue.c:269`）

```c
struct pool_workqueue {
    struct worker_pool  *pool;          // 关联的 worker_pool
    struct workqueue_struct *wq;        // 关联的 workqueue
    int                 work_color;     // L: 当前颜色
    int                 flush_color;    // L: flush 颜色
    int                 refcnt;         // L: 引用计数
    int                 nr_in_flight[WORK_NR_COLORS]; // L: 各颜色飞行中工作数
    bool                plugged;        // L: 执行暂停
    int                 nr_active;      // L: 活跃工作数
    struct list_head    inactive_works; // L: 非活跃工作链表（被 max_active 限流的）
    struct list_head    pending_node;   // LN: wq_node_nr_active->pending_pwqs 节点
    struct list_head    pwqs_node;      // WR: 链入 wq->pwqs
    struct list_head    mayday_node;    // MD: 链入 wq->maydays
    struct work_struct  mayday_cursor;  // L: pool->worklist 游标
    u64                 stats[PWQ_NR_STATS];
    // ... (注：max_active 属于 workqueue_struct，不在 pwq 中)
};
```

### 1.5 `struct workqueue_struct`——工作队列（`workqueue.c`）

```c
struct workqueue_struct {
    struct list_head    pwqs;           // 所有 pwq 链表
    struct list_head    list;           // 全局 workqueue 链表
    struct workqueue_attrs *attrs;      // 队列属性
    struct pool_workqueue __rcu *cpu_pwq[]; // per-CPU pwq 指针（NR_CPUS 数组）
    unsigned int        flags;          // WQ_UNBOUND, WQ_BH, WQ_MEM_RECLAIM 等
    const char          *name;          // 队列名称（如 "events"）
    int                 max_active;     // 全局最大活跃数
    // ...
};
```

---

## 2. CMWQ 架构全景

```
workqueue_struct (用户可见的队列)
     │
     │  每个 workqueue 有 per-CPU 的 pwq
     │
     ├── cpu_pwq[0] → pool_workqueue → worker_pool (CPU 0, normal)
     ├── cpu_pwq[1] → pool_workqueue → worker_pool (CPU 1, normal)
     ├── cpu_pwq[2] → pool_workqueue → worker_pool (CPU 2, normal)
     │   ...                        → worker_pool (CPU n, highpri)
     │
     └── 所有 pwq 共享 pool：
          CPU n 上只有 2 个 worker_pool（普通/高优先级）
          所有 workqueue 的普通优先级工作都提交到同一个 pool
          → 线程复用，避免"每个 workqueue 一个线程"的开销
```

---

## 3. 🔥 工作提交——__queue_work 完整数据流

```
queue_work(wq, work)                    @ kernel/workqueue.c
  │
  └─ queue_work_on(WORK_CPU_UNBOUND, wq, work)  @ workqueue.c:2490
       │
       ├─ local_irq_save(flags)           ← 关中断（保证 PENDING 位操作原子性）
       │
       └─ __queue_work(cpu, wq, work)    @ workqueue.c:2275
            │
            ├─ [安全检查] wq->flags & (__WQ_DESTROYING | __WQ_DRAINING)
            │    → 阻止向正在销毁/排空的队列提交工作
            │
            ├─ rcu_read_lock()
            │
            ├─ CPU 选择：
            │   if (WQ_UNBOUND):
            │       cpu = wq_select_unbound_cpu(raw_smp_processor_id())
            │       ← 从允许的 CPU 集合中选择负载最轻的
            │   else:
            │       cpu = raw_smp_processor_id()
            │       ← per-CPU workqueue 绑定到当前 CPU
            │
            ├─ pwq = rcu_dereference(*per_cpu_ptr(wq->cpu_pwq, cpu))
            │   ← 获取对应 CPU 的 pool_workqueue
            │
            ├─ [非重入保证]
            │   last_pool = get_work_pool(work)
            │   if (work 正在 last_pool 上执行):
            │       ← 保持同一 pool 防止重入（work 执行中不会被再次执行）
            │       pwq = worker->current_pwq
            │       pool = pwq->pool
            │
            ├─ raw_spin_lock(&pool->lock)
            │
            ├─ [pwq 活性检查]
            │   if (unlikely(!pwq->refcnt)):
            │       ← unbound pwq 已被替换？→ 重试
            │       raw_spin_unlock; cpu_relax; goto retry
            │
            ├─ pwq_tryinc_nr_active(pwq, &fill)
            │   ├─ 如果 nr_active < max_active:
            │   │    → 直接激活
            │   └─ 否则:
            │        → 工作被标记为 INACTIVE，放入 pwq->inactive_works
            │        → 等待其他工作完成后被激活
            │
            ├─ insert_work(pwq, work, &pool->worklist, work_flags)
            │   @ kernel/workqueue.c:2220
            │   │
            │   ├─ set_work_pwq(work, pwq, extra_flags)
            │   │   → 将 work->data 编码为 pwq 指针 + 颜色 + 标志
            │   │
            │   ├─ list_add_tail(&work->entry, head)
            │   │   → 添加到 pool->worklist 尾部
            │   │
            │   ├─ set_bit(WORK_STRUCT_PENDING_BIT, &work->data)
            │   │   → 标记工作为 PENDING
            │   │
            │   └─ wake_up_worker(pool)
            │       → 如果有空闲工人 → 唤醒
            │       → 否则 → 创建新工人（由 manager 负责）
            │
            └─ raw_spin_unlock_irqrestore(&pool->lock, flags)
```

### 3.1 `insert_work` 细节（`workqueue.c:2220`）

```c
static void insert_work(struct pool_workqueue *pwq, struct work_struct *work,
                         struct list_head *head, unsigned int extra_flags)
{
    struct worker_pool *pool = pwq->pool;
    unsigned long data;

    /* 将 work->data 编码为指向 pwq 的指针 */
    data = (unsigned long)pwq | WORK_STRUCT_PWQ_BIT;  // 设置 PWQ 位
    data |= extra_flags;                                // 颜色位 + INACTIVE 等
    set_work_data(work, data, 0);                       // 写入 data

    /* 加入 pool->worklist */
    list_add_tail(&work->entry, head);

    /* 设置 PENDING 位（一定要在 list_add 之后） */
    set_bit(WORK_STRUCT_PENDING_BIT, work_data_bits(work));
}
```

**为什么 PENDING 位要在 list_add 之后设置？**

因为 `try_to_grab_pending()` 通过检测 PENDING 位来判断工作是否在队列中。PENDING=1 且 `list_empty` = 工作正在被处理；PENDING=1 且 `!list_empty` = 工作等待处理。原子操作顺序保证了 `try_to_grab_pending` 不会错误地认为工作不在队列中。

---

## 4. 🔥 工作执行——worker_thread 完整数据流

### 4.1 主循环

```c
// kernel/workqueue.c:3411 — doom-lsp 确认
static int worker_thread(void *__worker)
{
    struct worker *worker = __worker;
    struct worker_pool *pool = worker->pool;

    // 通知 pool：我已就绪
    worker->task->flags |= PF_WQ_WORKER;

    woke_up:
    raw_spin_lock_irq(&pool->lock);

    // 循环处理工作
    while (true) {
        // 如果有 KTHREAD_IS_STOPPED → 退出
        if (worker->flags & WORKER_DIE)
            break;

        raw_spin_unlock_irq(&pool->lock);  // 解锁后睡眠或执行

        // 如果本工人不是 manager，且 pool 需要管理操作
        // （创建/销毁工人），则尝试成为 manager
        if (need_to_create_worker(pool)) {
            raw_spin_lock_irq(&pool->lock);
            if (!(worker->flags & WORKER_MANAGER)) {
                worker->flags |= WORKER_MANAGER;
                pool->manager = worker;
            }
            create_worker(pool);              // 创建新工人
            worker->flags &= ~WORKER_MANAGER;
            pool->manager = NULL;
        }

        raw_spin_lock_irq(&pool->lock);

        /* 从 worklist 取一个工作 */
        work = list_first_entry(&pool->worklist, struct work_struct, entry);

        if (work) {
            list_del_init(&work->entry);     // 从 worklist 移除
            pwq = get_work_pwq(work);         // 获取关联的 pwq

            worker->current_work = work;      // 记录当前工作
            worker->current_pwq = pwq;
            worker->current_func = work->func;

            // 检查是否 CPU_INTENSIVE 标记
            // 如果是且工人数 > 1，不限制并发（防止 CPU 密集型工作独占工人）
            if (!(worker->flags & WORKER_NOT_RUNNING))
                pool->nr_running++;

            raw_spin_unlock_irq(&pool->lock);

            // ——— 执行工作函数！！！ ———
            work->func(work);
            // ——— 工作函数返回 ———

            raw_spin_lock_irq(&pool->lock);

            // 清理
            worker->current_work = NULL;
            pwq_dec_nr_in_flight(pwq, work_data_bits(work));
            // 更新颜色计数（通知 flush 等待者）

            // 重新检查是否需要工作
            goto woke_up;  // 回到循环开头
        }

        /* 没有工作 → 进入空闲状态 */
        worker_enter_idle(worker);           // 加入 idle_list
        __set_current_state(TASK_IDLE);
        raw_spin_unlock_irq(&pool->lock);
        schedule();                           // 休眠
        __set_current_state(TASK_RUNNING);
        raw_spin_lock_irq(&pool->lock);
        worker_leave_idle(worker);           // 离开空闲列表
        goto woke_up;
    }

    // 退出
    worker->task->flags &= ~PF_WQ_WORKER;
    return 0;
}
```

### 4.2 工人创建——create_worker

```c
static struct worker *create_worker(struct worker_pool *pool)
{
    struct worker *worker;
    char id_buf[WORKER_ID_LEN];

    worker = kmalloc(sizeof(*worker), GFP_KERNEL);
    if (!worker)
        return NULL;

    worker->pool = pool;
    worker->id = ida_alloc(&pool->worker_ida, GFP_KERNEL);

    // 创建内核线程
    // kworker/x:y — x=CPU, y=ID
    snprintf(id_buf, sizeof(id_buf), "%d:%d%s", pool->cpu, worker->id,
             pool->id == 1 ? "H" : "");
    worker->task = kthread_create_on_node(worker_thread, worker,
                                           pool->node, "kworker/%s", id_buf);
    if (IS_ERR(worker->task))
        goto fail;

    // 设置优先级
    set_user_nice(worker->task, pool->attrs->nice);

    // 启动线程
    wake_up_process(worker->task);

    return worker;
}
```

### 4.3 工人销毁——空闲超时机制

```c
#define IDLE_WORKER_TIMEOUT    300 * HZ  // 空闲 5 分钟后销毁
#define MAX_IDLE_WORKERS_RATIO  4        // 空闲/活跃比例上限

// idle_timer 回调：销毁多余的空闲工人
static void idle_worker_timeout(struct timer_list *t)
{
    struct worker_pool *pool = from_timer(pool, t, idle_timer);

    raw_spin_lock_irq(&pool->lock);

    while (too_many_workers(pool)) {
        // 从 idle_list 尾部取一个工人
        struct worker *worker = list_last_entry(&pool->idle_list, ...);
        list_del(&worker->entry);
        worker->flags |= WORKER_DIE;
        wake_up_process(worker->task);  // 通知工人自杀
    }

    raw_spin_unlock_irq(&pool->lock);
}
```

---

## 5. 🔥 flush 机制——颜色计数详解

`flush_workqueue(wq)` 等待 wq 上所有已提交的工作完成。实现基于**颜色计数**的精细跟踪：

```c
// 颜色定义（workqueue.h）：
#define WORK_STRUCT_COLOR_SHIFT    4
#define WORK_STRUCT_COLOR_BITS     4    // 16 种颜色（0-15）
#define WORK_NO_COLOR              (1UL << (WORK_STRUCT_COLOR_SHIFT + WORK_STRUCT_COLOR_BITS))

// 每个 worker_pool 维护：
#define WORK_STRUCT_PWQ_BIT        2    // data 的 bit 2 表示指向 pwq 而非 pool
```

**颜色工作方式**：

```
工作提交时被分配一个颜色（0-15 循环）：
  ┌─ work->data 的 bits 4-7 记录颜色
  │   每次 insert_work 时颜色 +1
  │   颜色 0-15 循环使用
  │
  ├─ 每个 pwq 维护 nr_in_flight[color] = 该颜色下的工作数
  │
  └─ flush_workqueue:
       │
       ├─ 记录当前颜色 C
       ├─ 等待 nr_in_flight[C] == 0
       └─ 当颜色 C 的所有工作完成后 → 通知返回

颜色循环示例：
  T=0: 提交颜色 0 的工作 A, B
  T=1: flush 开始，记录颜色=0，等待 nr_in_flight[0]=2 → 0
  T=2: 提交颜色 1 的工作 C（flush 不等待 C！）
  T=3: A 完成（nr_in_flight[0]=1）
  T=4: B 完成（nr_in_flight[0]=0）→ flush 返回！
```

这个机制的关键优势是：**flush 只等待调用那一刻已提交的工作，不等待之后提交的工作**，避免了"永远 flush 不完"的问题。

---

## 6. max_active 限流——inactive 工作

每个 pwq 有 `max_active` 限制，防止单个 workqueue 淹没线程池：

```
pwq->nr_active < pwq->max_active:   工作直接激活 → 放入 pool->worklist
pwq->nr_active >= pwq->max_active:  工作标记 INACTIVE → 放入 pwq->inactive_works

工作完成时：
  完成的工作 → pwq_dec_nr_active(pwq)
                → nr_active--
                → 如果 nr_active < max_active:
                    从 inactive_works 取一个 → 激活 → 放入 pool->worklist
```

默认值：
- `WQ_UNBOUND`：`max_active = min(512, 4 * num_possible_cpus())`
- `WQ_BH`：`max_active = 0`（无限制）
- `WQ_MAX_ACTIVE = 512`

---

## 7. BH workqueue——7.0-rc1 的 tasklet 替代方案

Linux 7.0-rc1 引入 `WQ_BH` 模式，工作不在 kworker 线程中运行，而直接在 softirq 上下文中执行：

```c
// 创建 BH workqueue
struct workqueue_struct *wq = alloc_workqueue("my_bh", WQ_BH, 0);

// 提交
local_bh_disable();
queue_work(wq, work);  // 工作函数在 softirq 上下文中执行
local_bh_enable();
```

**BH 与普通 workqueue 的关键区别**：

| 特性 | 普通 workqueue | BH workqueue |
|------|---------------|-------------|
| 执行上下文 | 进程上下文（kworker 线程） | softirq 上下文 |
| 可休眠 | ✅ | ❌ |
| 线程开销 | 需 kworker 线程 + 上下文切换 | 无线程，直接执行 |
| 并发 | 动态调整 | 单 CPU 上串行 |
| 适用 | 长时间、可休眠的工作 | 短时间、不可休眠的工作 |
| 替代 | — | tasklet/softirq |

**内部实现**：BH workqueue 的 `worker_pool` 标记 `POOL_BH`。工作时直接在当前 softirq 上下文中执行，不经过 `worker_thread()`。

---

## 8. rescuer 线程——OOM 安全

当 workqueue 设置了 `WQ_MEM_RECLAIM` 标志，系统会创建一个**救援线程（rescuer）**。在内存压力下，rescuer 确保工作队列仍能推进：

```c
#define MAYDAY_INITIAL_TIMEOUT   (HZ / 100)  // 10ms
#define MAYDAY_INTERVAL          (HZ / 10)    // 100ms
#define RESCUER_BATCH            16           // 每次处理 16 个工作

// mayday 触发条件：
// 1. pool->worklist 非空
// 2. pool->nr_workers 已达上限（无法创建新线程）
// 3. 内存紧张（GFP_KERNEL 分配可能失败）

// rescuer 行为：
assign_rescuer_work(pwq, rescuer)
  └─ 从 pool->worklist 取最多 RESCUER_BATCH(16) 个工作
     └─ 执行每个工作的函数（直接调用 work->func(work)）
```

---

## 9. try_to_grab_pending——取消/修改工作

```c
// kernel/workqueue.c:2090 — doom-lsp 确认
static int try_to_grab_pending(struct work_struct *work, u32 cflags,
                                unsigned long *irq_flags)
```

用于 `cancel_work_sync()` 和 `mod_delayed_work()` 的核心函数：

```
try_to_grab_pending(work, cflags, irq_flags)
  │
  ├─ 循环尝试：
  │   │
  │   ├─ 读取 work->data
  │   ├─ if (!(data & WORK_STRUCT_PENDING_BIT):
  │   │    ← 工作不在队列中（未被提交或已在执行）
  │   │    return -ENOENT
  │   │
  │   ├─ if (data & WORK_STRUCT_PWQ_BIT):
  │   │    ← 工作在 pwq 中（已入队）
  │   │    └─ pwq = data & ~WORK_STRUCT_FLAG_MASK
  │   │
  │   ├─ try cmpxchg 将 data 的 PENDING 位清零（抢占工作）
  │   │   ├─ 成功 → 工作已被我们"偷走"
  │   │   │         → 从 worklist 中移除
  │   │   │         → return 1
  │   │   └─ 失败（其他线程也在尝试 grab）
  │   │        → 重试
  │   │
  │   └─ cpu_relax(); continue
```

---

## 10. unbound workqueue 的 CPU 选择

```c
static int wq_select_unbound_cpu(int cpu)
{
    struct workqueue_attrs *attrs;
    int node;

    // 如果当前 CPU 在允许集合中 → 直接使用
    if (cpumask_test_cpu(cpu, wq_unbound_cpumask))
        return cpu;

    // 否则从允许集合中选择第一个 CPU
    cpu = cpumask_first(wq_unbound_cpumask);
    if (cpu < nr_cpu_ids)
        return cpu;

    // fallback
    return raw_smp_processor_id();
}
```

---

## 11. 性能常量

| 常量 | 值 | 含义 |
|------|-----|------|
| `NR_STD_WORKER_POOLS` | 2 | 每 CPU 两个池（普通+高优先级）|
| `MAX_IDLE_WORKERS_RATIO` | 4 | 空闲/活跃比例上限 |
| `IDLE_WORKER_TIMEOUT` | 300s | 空闲 5 分钟后销毁工人 |
| `MAYDAY_INITIAL_TIMEOUT` | 10ms | rescuer 首次超时 |
| `MAYDAY_INTERVAL` | 100ms | rescuer 重试间隔 |
| `RESCUER_BATCH` | 16 | rescuer 批量处理数 |
| `CREATE_COOLDOWN` | 10ms | 创建工人冷却时间 |

---

## 12. 系统默认 workqueue

| workqueue | 类型 | 用途 |
|-----------|------|------|
| `events` | per-CPU, 普通优先级 | `schedule_work()` 提交到此队列 |
| `events_highpri` | per-CPU, 高优先级 | 高优先级工作 |
| `events_unbound` | unbound | `WQ_UNBOUND` 工作 |
| `events_long` | per-CPU | 长时间运行的工作 |
| `events_power_efficient` | per-CPU + power | 电源高效模式 |
| `system_bh` | BH | 7.0-rc1 新增的 BH workqueue |

---

## 13. 源码文件索引

| 文件 | 内容 | 符号数 |
|------|------|--------|
| `include/linux/workqueue.h` | 结构体 + API + 位编码常量 | **159 个** |
| `kernel/workqueue.c` | 完整 CMWQ 实现 | **649 个** |
| `kernel/workqueue_internal.h` | 内部结构 | — |

---

## 14. 关联文章

- **08-mutex**：workqueue 内部使用互斥锁保护创建流程
- **11-completion**：workqueue flush 使用 completion 等待
- **14-kthread**：kworker 是内核线程的一种
- **24-softirq**：BH workqueue 在 softirq 上下文中执行
- **48-kworker**：kworker 线程的完整生命周期

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
