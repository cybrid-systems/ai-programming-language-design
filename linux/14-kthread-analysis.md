# kthread — 内核线程深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/kthread.h` + `kernel/kthread.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**kthread** 是内核线程，用于执行后台任务。与普通进程不同，kthread 只在内核空间运行。

---

## 1. 核心 API

### 1.1 kthread_run — 创建并启动

```c
// include/linux/kthread.h
#define kthread_run(threadfn, data, namefmt, ...) \
    ({                              \
        struct task_struct *k;        \
        k = kthread_create(threadfn, data, namefmt, ##__VA_ARGS__); \
        if (!IS_ERR(k))              \
            wake_up_process(k);      \
        k;                          \
    })
```

### 1.2 kthread_create — 创建（不启动）

```c
// kernel/kthread.c — kthread_create
struct task_struct *kthread_create(int (*threadfn)(void *data), void *data,
                    const char namefmt[], ...)
{
    struct kthread *ktask;

    // 1. 分配 kthread 描述符
    ktask = kzalloc(sizeof(struct kthread), GFP_KERNEL);

    // 2. 初始化 kthread
    ktask->task = kzalloc(sizeof(struct task_struct), GFP_KERNEL);

    // 3. 设置线程函数
    ktask->task->start_kernel_thread = kthread_trampoline;
    ktask->task->arg = ktask;

    return ktask->task;
}
```

### 1.3 kthread_should_stop — 检查是否应该停止

```c
// kernel/kthread.c
bool kthread_should_stop(void)
{
    return test_bit(KTHREAD_SHOULD_STOP, &kthread->flags);
}
```

### 1.4 kthread_stop — 请求停止并等待

```c
// kernel/kthread.c — kthread_stop
int kthread_stop(struct task_struct *k)
{
    set_bit(KTHREAD_SHOULD_STOP, &kthread->flags);
    wake_up_process(k);
    wait_for_completion(&kthread->exited);
    return k->exit_code;
}
```

---

## 2. 完整文件索引

| 文件 | 函数 |
|------|------|
| `include/linux/kthread.h` | `kthread_run`、`kthread_should_stop` |
| `kernel/kthread.c` | `kthread_create`、`kthread_stop`、`kthread_trampoline` |
