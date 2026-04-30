# Linux Kernel workqueue 异步工作队列 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/workqueue.h` + `kernel/workqueue.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-28 学习笔记

---

## 0. 什么是 workqueue？

**workqueue** 是内核异步任务执行引擎——把耗时工作从中断上下文安全地推到进程上下文。

**核心问题它解决**：
- 中断处理程序（interrupt context）不能睡眠
- 但某些工作（如分配内存、调用文件系统）需要睡眠
- **解法**：中断handler 把 work 提交到 workqueue，由 worker 线程执行

---

## 1. 核心数据结构

### 1.1 work_struct — 单个工作单元

```c
// include/linux/workqueue.h — work_struct
struct work_struct {
    atomic_long_t data;           // 状态 + 回调指针（低位存储 flag）
    struct list_head entry;      // 挂到 pool 的 worklist
    work_func_t func;             // 执行函数
#ifdef CONFIG_LOCKDEP
    struct lockdep_map lockdep_map;
#endif
};

// work_func_t 类型
typedef void (*work_func_t)(struct work_struct *work);

// data 字段编码：
//   低 WORK_STRUCT_FLAG_BITS 位：状态标志
//   其余位：指向执行函数的指针（或 pool 信息）
#define WORK_STRUCT_PENDING_BIT   0   // 待执行标志
#define WORK_STRUCT_INACTIVE_BIT  1   // 未激活
#define WORK_STRUCT_PWQ_BIT       2   // 关联到 pwq
#define WORK_STRUCT_LINKED_BIT    3   // 与其他 work 链接
```

### 1.2 delayed_work — 延迟工作

```c
// include/linux/workqueue.h — delayed_work
struct delayed_work {
    struct work_struct work;      // 嵌入普通 work
    struct timer_list timer;      // 延迟定时器
    struct workqueue_struct *wq;  // 目标 workqueue
    int cpu;                     // 目标 CPU
};
```

### 1.3 worker_pool — 工作线程池

```c
// kernel/workqueue_internal.h — worker_pool（每个 CPU 每个优先级一个）
struct worker_pool {
    spinlock_t lock;              // 保护 pool
    int cpu;                      // 绑定的 CPU（-1 = unbound）
    int node;                     // NUMA node
    struct list_head worklist;    // 待执行的 work 链表

    // worker 列表
    struct list_head workers;     // 全部 worker
    struct worker *manager;       // 管理 worker（分配新 worker）
    struct worker *rescuer;       // 紧急 worker（OOM 时执行）

    // 状态
    unsigned int flags;
    struct work_attrs *attrs;      // 调度属性
};
```

### 1.4 workqueue_struct — 工作队列

```c
// include/linux/workqueue.h — workqueue_struct
struct workqueue_struct {
    struct list_head pwqs;        // 关联的 worker_pool 链表
    struct list_head list;        // 全局 workqueue 链表

    // 全局标志
    unsigned int flags;
    const char *name;             // 名字（如 "events", "kworker/0:0"）

    // worker 池
    struct worker_pool __percpu *cpu_pwqs;
    struct worker_pool __percpu *cpu_workers;

    // rescue
    struct worker *rescuer;
};
```

---

## 2. 核心 API

### 2.1 静态声明

```c
// include/linux/workqueue.h
#define DECLARE_WORK(_work, _func) \
    struct work_struct _work = __WORK_INITIALIZER(_work, _func)

#define DECLARE_DELAYED_WORK(_work, _func) \
    struct delayed_work _work = __DELAYED_WORK_INITIALIZER(_work, _func, 0)

// 示例
static void my_work_func(struct work_struct *work) { ... }
DECLARE_WORK(my_work, my_work_func);
```

### 2.2 动态初始化

```c
#define INIT_WORK(_work, _func) ...
#define INIT_DELAYED_WORK(_work, _func) ...
```

### 2.3 提交 work

```c
// 快捷方式（使用 system_wq）
bool schedule_work(struct work_struct *work);
bool schedule_delayed_work(struct delayed_work *dwork, unsigned long delay);

// 指定 workqueue
bool queue_work(struct workqueue_struct *wq, struct work_struct *work);
bool queue_work_on(int cpu, struct workqueue_struct *wq, struct work_struct *work);
bool queue_delayed_work(struct workqueue_struct *wq,
                        struct delayed_work *dwork, unsigned long delay);

// 创建自定义 workqueue
struct workqueue_struct *alloc_workqueue(const char *name,
                                          unsigned int flags,
                                          int max_active);
void destroy_workqueue(struct workqueue_struct *wq);
```

### 2.4 等待

```c
void flush_workqueue(struct workqueue_struct *wq);    // 等待所有 work 执行完
bool flush_work(struct work_struct *work);            // 等待单个 work
bool cancel_work_sync(struct work_struct *work);      // 取消 work
```

---

## 3. 执行流程

### 3.1 queue_work 路径

```
queue_work(system_wq, &my_work)
  → __queue_work(cpu, wq, work)
    → 找到目标 worker_pool（按 cpu 和优先级）
    → insert_work(work, pwq)
        → list_add_tail(&work->entry, &pool->worklist)
        → wake_up_locked(pool->wait)
    → 唤醒 idle worker
```

### 3.2 worker_thread 循环

```c
// kernel/workqueue.c — worker_thread
static int worker_thread(void *arg)
{
    struct worker_pool *pool = arg;

worker_loop:
    while (!kthread_should_stop()) {
        // 1. 睡眠直到有 work
        schedule();

        // 2. 取出 work
        work = list_first_entry(&pool->worklist, struct work_struct, entry);
        list_del(&work->entry);

        // 3. 执行
        work->func(work);

        // 4. 如果 worklist 空，再次睡眠
    }
}
```

---

## 4. workqueue 类型

| 类型 | 标志 | 特点 | 典型用途 |
|------|------|------|---------|
| `system_wq` | `WQ_UNBOUND` | unbound，无 CPU 绑定 | 通用异步任务 |
| `system_highpri_wq` | `WQ_HIGHPRI` | 高优先级 | 紧急任务 |
| `system_unbound_wq` | `WQ_UNBOUND` | NUMA 友好 | 大内存分配 |
| `system_bh_wq` | `WQ_BH` | 底部半部 | 软中断后处理 |
| `system_power_efficient_wq` | `WQ_POWER_EFFICIENT` | 节能 | 低功耗场景 |

---

## 5. WQ_UNBOUND — NUMA 友好设计

```
per-cpu workqueue（默认）：
  CPU-0 的 work 只在 CPU-0 执行
  问题：如果 CPU-0 繁忙，work 只能等

unbound workqueue：
  work 可以调度到任意 CPU 的 worker 执行
  更均衡的负载 + 更好的 NUMA locality
```

---

## 6. 真实内核使用案例

### 6.1 驱动 bottom-half

```c
// drivers/scsi/sd.c — SCSI 磁盘
static void sd_read_cap16(struct scsi_disk *sdkp, struct request *rq)
{
    struct work_struct work = sd_read_cap16_done;
    queue_work(system_wq, &work);
}

static void sd_read_cap16_done(struct work_struct *work)
{
    // 处理完成，wake up 等待者
}
```

### 6.2 page writeback

```c
// mm/page-writeback.c
static void wake_flusher_threads(long nr_pages)
{
    // 把 dirty page 写回磁盘
    queue_work(bdi_wq, &wb->dwork);
}
```

---

## 7. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| `work_struct` 嵌入驱动结构体 | 一个 work 对应一个设备上下文 |
| per-cpu worker pool | 减少跨 CPU 调度开销 |
| `delayed_work` 用 timer | 实现精确延迟 |
| `rescue worker` | OOM 时仍能执行 work，避免死锁 |
| `flush_workqueue` | 保证所有 pending work 执行完再销毁 |

---

## 8. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/workqueue.h` | work_struct、API 声明、workqueue_struct |
| `kernel/workqueue.c` | 完整实现（4500+ 行）|
| `kernel/workqueue_internal.h` | worker_pool、worker 定义 |
