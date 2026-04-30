# Linux Kernel kthread 内核持久线程 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/kthread.h` + `kernel/kthread.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-29 学习笔记

---

## 0. 什么是 kthread？

**kthread** 是内核持久线程的创建与管理机制——所有 workqueue worker、kworker、后台守护进程的底层实现。

**核心价值**：
- 比起手动 `kernel_thread()` 更安全（自动处理 SIGKILL、PF_KTHREAD 标志）
- 提供统一的 `kthread_should_stop()` 优雅退出机制
- 支持 CPU 绑定、NUMA 节点绑定、park/unpark 暂停

---

## 1. 核心数据结构

### 1.1 内核内部 kthread 结构

```c
// kernel/kthread.c:56 — 内核内部 kthread
struct kthread {
    unsigned long flags;         // KTHREAD_SHOULD_STOP / KTHREAD_IS_PER_CPU / KTHREAD_PARKED
    unsigned int cpu;           // 绑定 CPU（-1 = unbound）
    unsigned int node;          // NUMA 节点
    int started;                // 是否已启动
    int result;                 // threadfn 的返回值
    int (*threadfn)(void *);   // 线程主函数
    void *data;                 // 传递给 threadfn 的数据
    struct completion parked;   // park/unpark 同步
    struct completion exited;   // 线程退出通知
    void *blkcg_css;           // blkcg cgroup
    char *full_name;            // 完整名字
};

// flags 位定义（kernel/kthread.c:78）
enum kthread_flags {
    KTHREAD_SHOULD_STOP = 0,   // kthread_stop() 已调用
    KTHREAD_IS_PER_CPU,         // per-CPU 线程
    KTHREAD_SHOULD_PARK,        // 应当暂停
    KTHREAD_PARKED,             // 已暂停
    KTHREAD_PER_CPU_SENTINEL
};
```

### 1.2 kthread_create_info（创建信息）

```c
// kernel/kthread.c:41 — 创建信息（跨进程传递）
struct kthread_create_info {
    char *full_name;             // 线程名
    int (*threadfn)(void *data); // 入口函数
    void *data;                 // 参数
    int node;                   // NUMA 节点
    struct task_struct *result;  // 创建结果（返回给调用者）
    struct completion *done;    // 创建完成通知
    struct list_head list;      // 挂到 kthread_create_list
};
```

---

## 2. 核心 API

### 2.1 创建

```c
// include/linux/kthread.h

// 最常用：创建并立即启动
#define kthread_run(threadfn, data, namefmt, ...) \
({  struct task_struct *__k = \
        kthread_create(threadfn, data, namefmt, ##__VA_ARGS__); \
    if (!IS_ERR(__k)) \
        wake_up_process(__k); \
    __k; \
})

// 创建（不启动）
struct task_struct *kthread_create_on_node(
    int (*threadfn)(void *data),
    void *data,
    int node,                  // NUMA_NO_NODE = 当前节点
    const char namefmt[], ...
);

// 创建并绑定到指定 CPU
struct task_struct *kthread_create_on_cpu(
    int (*threadfn)(void *data),
    void *data,
    unsigned int cpu,
    const char *namefmt
);
```

### 2.2 控制

```c
// 绑定 CPU（必须在启动前调用）
void kthread_bind(struct task_struct *k, unsigned int cpu);
void kthread_bind_mask(struct task_struct *k, const struct cpumask *mask);

// 暂停/恢复（比 stop 更轻量）
int kthread_park(struct task_struct *k);
void kthread_unpark(struct task_struct *k);

// 优雅停止
int kthread_stop(struct task_struct *k);
```

### 2.3 线程内部判断

```c
// 线程内部调用——检查是否被要求停止
bool kthread_should_stop(void);       // kthread_stop() 已调用
bool kthread_should_park(void);       // kthread_park() 已调用
bool kthread_should_stop_or_park(void); // 两者任一
bool kthread_freezable_should_stop(void); // 支持 freeze 的版本
```

---

## 3. 生命周期详解

### 3.1 创建流程（kthreadd）

```
用户调用 kthread_create()
  → 创建 kthread_create_info，插入 kthread_create_list
  → 唤醒 kthreadd_task（PID=2）
  → kthreadd() 从 list 取 info
  → kernel_thread(kthread, info) → 创建新 task
  → 新线程执行 kthread() 入口
  → 调用 threadfn(data)
  → 如果需要：complete(done) 通知创建者
  → 线程继续运行，直到 kthread_should_stop()

kthreadd_task 是所有 kthread 的祖先（PID=2）
```

### 3.2 线程入口（kthread）

```c
// kernel/kthread.c — kthread 入口
static int kthread(void *_create)
{
    struct kthread_create_info *create = _create;
    struct kthread self;
    current->worker_private = &self;    // 关联 kthread 结构

    // 调用用户 threadfn
    result = create->threadfn(create->data);

    // 退出
    kthread_exit(result);
}

// kthread_exit 实现
void kthread_complete_and_exit(struct completion *comp, long code)
{
    if (comp)
        complete(comp);                 // 通知等待者
    do_exit(code);                     // 真正退出
}
```

### 3.3 停止流程（kthread_stop）

```c
// kernel/kthread.c:747 — kthread_stop 实现
int kthread_stop(struct task_struct *k)
{
    struct kthread *kthread = to_kthread(k);

    set_bit(KTHREAD_SHOULD_STOP, &kthread->flags);  // 设置停止标志
    wake_up_process(k);                              // 唤醒线程

    wait_for_completion(&kthread->exited);          // 等待线程退出
    put_task_struct(k);

    return kthread->result;   // 返回 threadfn 的返回值
}
```

**停止状态机**：
```
kthread_stop()
  → set_bit(SHOULD_STOP)    // 设置停止标志
  → wake_up_process(k)      // 唤醒线程
  → wait_for_completion()    // 等待 exited 完成

线程侧:
  kthread_should_stop() 返回 true
  → return from threadfn()
  → kthread_exit()
  → complete(&exited)         // 唤醒 kthread_stop 中的等待
```

---

## 4. park / unpark 机制

```c
// 暂停：kthread_park()
kthread_park(k)
  → set_bit(KTHREAD_SHOULD_PARK)    // 设置暂停标志
  → wake_up_process(k)              // 唤醒
  → wait_for_completion(&kthread->parked)  // 等待线程进入暂停

// 线程内部：
kthread_should_park() 返回 true
  → kthread_parkme()                // 暂停
  → schedule() 睡眠，直到 unpark

// 恢复：kthread_unpark()
kthread_unpark(k)
  → clear_bit(KTHREAD_SHOULD_PARK)
  → wake_up_process(k)             // 唤醒继续执行
```

---

## 5. 与 workqueue 的关系

```
workqueue 的 worker_thread 都是 kthread：
  alloc_workqueue()
    → for each cpu: create_worker(pool)
      → kthread_run(worker_thread, pool, "kworker/%d:%d", cpu, idx)
        → worker_thread() 循环处理 worklist
```

---

## 6. 真实内核使用案例

### 6.1 kworker（每个 CPU 的工作线程）

```c
// kernel/workqueue.c — kworker 由 kthreadd 创建
struct worker *create_worker(struct worker_pool *pool)
{
    struct worker *worker;
    worker = kthread_run(worker_thread, pool, "kworker/%s:%d", ...);
}
```

### 6.2 migration 线程（负载均衡）

```c
// kernel/sched/core.c — per-CPU migration 线程
migration_call()
  → kthread_create(migration_thread, cpu, "migration/%d", cpu)
  → kthread_bind(task, cpu)
  → wake_up_process(task)
```

---

## 7. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| `kthreadd_task` 作为所有 kthread 祖先 | 保证清洁环境、统一调度策略 |
| `completion exited` 同步退出 | `kthread_stop` 必须等待 threadfn 返回 |
| `KTHREAD_SHOULD_STOP` 位标志 | 不需要锁，线程自行检查 |
| `park/unpark` 分离 | 支持 CPU hotplug 时线程迁移 |
| `to_kthread(current)` | 从 task_struct 反查 kthread 结构 |

---

## 8. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/kthread.h` | 公开 API、kthread 结构声明 |
| `kernel/kthread.c` | 完整实现（kthreadd、kthread_stop、kthread_exit）|
| `kernel/workqueue.c` | kworker 由 kthread 创建 |
| `kernel/sched/core.c` | migration 线程 |
