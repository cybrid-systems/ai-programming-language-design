# 14-kthread — 内核线程深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**kthread（内核线程）** 是 Linux 内核中在内核空间运行的线程。与用户空间线程不同，内核线程：
- 没有独立的地址空间（使用父进程的 mm）
- 只运行在内核空间
- 可以访问内核数据结构
- 可以被调度、睡眠、被抢占

内核线程广泛用于：workqueue worker、内存回收（kswapd）、文件系统（btrfs-transaction）、block layer（kblockd）等场景。

doom-lsp 确认 `kernel/kthread.c` 包含约 270+ 个符号，`include/linux/kthread.h` 提供了简洁的 API。

---

## 1. 核心数据结构

### 1.1 struct kthread_create_info

```c
struct kthread_create_info {
    int (*threadfn)(void *data);   // 线程函数
    void *data;                    // 线程函数的参数
    struct completion done;        // 创建完成的同步
    struct task_struct *result;    // 创建后的 task_struct
    ...
};
```

在 `kthread_create()` 和 `kthread_run()` 内部使用，用于在创建工作线程时传递参数。

### 1.2 struct kthread

```c
struct kthread {
    unsigned long flags;           // KTHREAD_IS_STOPPED 等标志
    unsigned int cpu;              // 绑定的 CPU
    void *data;                    // 线程函数的数据
    struct completion parked;      // park 同步
    struct completion exited;      // 退出同步
};
```

每个内核线程的 task_struct 中的 `set_child_tid` 指针指向这个结构。

---

## 2. 创建内核线程

### 2.1 kthread_create

```c
// kernel/kthread.c
struct task_struct *kthread_create(int (*threadfn)(void *data),
                                    void *data, const char *namefmt, ...)
```

内部流程：

```
kthread_create(threadfn, data, "mythread")
  │
  ├─ 创建 kthread_create_info 结构
  ├─ 初始化 completion（等待线程函数开始执行）
  │
  ├─ 调用 kernel_thread(kthread, create, CLONE_FS | CLONE_FILES | ...)
  │    └─ 在 fork() 时，新线程不复制 mm（共享 init_mm）
  │    └─ 新线程立即在 kthread() 入口函数启动
  │
  ├─ wait_for_completion(&create->done)   ← 等待线程启动
  │
  └─ return create->result               ← 返回 task_struct*
```

### 2.2 kthread_run（创建 + 立即唤醒）

```c
#define kthread_run(threadfn, data, namefmt, ...)       \
    ({                                                  \
        struct task_struct *__k =                       \
            kthread_create(threadfn, data, namefmt);    \
        if (!IS_ERR(__k))                               \
            wake_up_process(__k);                       \
        __k;                                            \
    })
```

---

## 3. 线程函数入口

新创建的线程从 `kthread()` 函数开始执行：

```c
// kernel/kthread.c
static int kthread(void *_create)
{
    struct kthread_create_info *create = _create;
    struct kthread *self;
    int (*threadfn)(void *data);
    void *data;

    // 1. 完成创建阶段
    self->flags = 0;
    self->data = data;
    current->set_child_tid = &self;       // 关联 kthread 结构
    complete(&create->done);              // 通知创建者"我已启动"

    // 2. 进入线程函数
    schedule();                           // 等待被 wake_up_process

    // 3. 运行用户提供的 threadfn
    ret = threadfn(data);

    // 4. 线程退出
    do_exit(ret);
}
```

---

## 4. 线程控制

### 4.1 kthread_should_stop

```c
bool kthread_should_stop(void)
{
    return test_bit(KTHREAD_SHOULD_STOP, &to_kthread(current)->flags);
}
```

内核线程的典型循环模式：

```c
int my_kthread(void *data)
{
    while (!kthread_should_stop()) {
        // 执行工作
        set_current_state(TASK_INTERRUPTIBLE);
        schedule();
    }
    return 0;
}
```

### 4.2 kthread_stop

```c
int kthread_stop(struct task_struct *k)
{
    // 设置 KTHREAD_SHOULD_STOP 标志
    set_bit(KTHREAD_SHOULD_STOP, &kthread->flags);

    // 唤醒线程（如果它正在睡眠）
    wake_up_process(k);

    // 等待线程退出
    wait_for_completion(&kthread->exited);

    return kthread->result;
}
```

---

## 5. 完整数据流

```
创建线程：
  ┌─────────────────────────────────────┐
  │ tp = kthread_run(my_fn, data, "my")│
  │   ├─ kernel_thread(kthread, ...)    │
  │   ├─ kthread() 执行                 │
  │   │   └─ complete(&create->done)    │←── 创建者收到完成信号
  │   ├─ tp = create->result            │
  │   └─ wake_up_process(tp)            │←── 唤醒新线程
  └─────────────────────────────────────┘

线程函数：
  int my_fn(void *data)
  {
      while (!kthread_should_stop()) {   ← 检查停止标志
          // ... 执行工作 ...
          schedule_timeout(HZ);           ← 周期执行
      }
      return 0;
  }

停止线程：
  kthread_stop(tp)
    └─ set_bit(KTHREAD_SHOULD_STOP)
    └─ wake_up_process(tp)              ← 唤醒线程
    └─ wait_for_completion(&exit)        ← 等待线程退出
```

---

## 6. 设计决策总结

| 决策 | 原因 |
|------|------|
| kthread_create + wake_up_process 分离 | 调用者可以在启动前设置亲和性/优先级 |
| kthread_should_stop 轮询模式 | 线程决定何时安全退出 |
| set_child_tid 关联 | 快速查找 kthread 元数据 |
| completion 同步 | 可靠等待线程到达特定状态 |
| 共享 init_mm | 不浪费页表，内核线程不需要用户空间 |

---

## 7. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/kthread.h` | `kthread_create` / `kthread_run` | API |
| `include/linux/kthread.h` | `kthread_should_stop` | 内联 |
| `kernel/kthread.c` | `kthread` | 线程入口 |
| `kernel/kthread.c` | `kthread_stop` | 停止逻辑 |

---

## 8. 关联文章

- **workqueue**（article 13）：worker 线程本质上是 kthread
- **completion**（article 11）：kthread 使用 completion 进行同步

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
