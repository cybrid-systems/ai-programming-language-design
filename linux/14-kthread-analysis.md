# 14-kthread — 内核线程深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**kthread（内核线程）** 是在内核空间运行的线程。与用户空间线程不同，内核线程：
- 没有自己的地址空间（复用 `init_mm`，即上一进程的 mm）
- 只能访问内核地址空间
- 可以被调度、睡眠、被抢占
- 常用于：workqueue worker、kswapd（内存回收）、btrfs-transaction、kblockd

doom-lsp 确认 `kernel/kthread.c` 包含约 270+ 个符号，`include/linux/kthread.h` 定义了外部 API。

---

## 1. 核心数据结构

### 1.1 struct kthread（`kernel/kthread.c` 内部）

```c
struct kthread {
    unsigned long flags;             // KTHREAD_IS_STOPPED 等
    unsigned int cpu;                // 绑定的 CPU（-1 = 无）
    void *data;                      // 用户传入的数据
    struct completion parked;        // park 同步
    struct completion exited;        // 退出同步
};
```

每个内核线程的 `task_struct` 中的 `set_child_tid` 指针指向这个结构。通过 `to_kthread(current)` 宏可以获取。

---

## 2. 创建流程

### 2.1 kthread_create（`kernel/kthread.c`）

```
kthread_create(threadfn, data, "mythread")
  │
  ├─ 创建 kthread_create_info（包含 threadfn + data + completion）
  │
  ├─ kernel_thread(kthread, create, CLONE_FS | CLONE_FILES | ...)
  │    └─ 通过 do_fork() 创建新线程
  │    └─ 新线程从 kthread() 函数开始执行
  │
  ├─ wait_for_completion(&create->done)   ← 等待线程初始化完成
  │
  └─ return create->result               ← 返回 task_struct*
```

### 2.2 kthread_run——创建+立即启动

```c
#define kthread_run(threadfn, data, namefmt, ...)   \
    ({                                              \
        struct task_struct *__k =                   \
            kthread_create(threadfn, data, namefmt);\
        if (!IS_ERR(__k))                           \
            wake_up_process(__k);                   \
        __k;                                        \
    })
```

---

## 3. 线程初始化入口

新线程从 `kthread()` 函数开始执行（`kernel/kthread.c`）：

```
kthread(void *_create)
  │
  ├─ 设置 current->set_child_tid = &self  ← 关联 kthread 结构
  │
  ├─ self->data = data                     ← 保存用户数据指针
  │
  ├─ complete(&create->done)               ← 通知创建者：已启动
  │
  ├─ schedule()                            ← 让出 CPU，等待被 wake_up_process
  │    └─ 此时创建者可以设置亲和性/优先级
  │
  ├─ ret = threadfn(data)                  ← 执行用户提供的线程函数
  │
  └─ do_exit(ret)                          ← 线程函数返回后退出
```

关键设计：`schedule()` 让创建者有机会在 threadfn 运行之前配置线程属性（CPU 亲和性、调度策略等）。

---

## 4. 标准线程循环

典型的正确退出模式：

```c
int my_kthread(void *data)
{
    // 1. 可以接收 kthread_stop 信号
    while (!kthread_should_stop()) {
        // 2. 执行工作
        do_work(data);

        // 3. 等待下次被唤醒
        set_current_state(TASK_INTERRUPTIBLE);
        if (kthread_should_stop()) {
            __set_current_state(TASK_RUNNING);
            break;
        }
        schedule();
    }
    __set_current_state(TASK_RUNNING);
    return 0;
}
```

---

## 5. 停止线程

```
kthread_stop(task)
  │
  ├─ set_bit(KTHREAD_SHOULD_STOP, &kthread->flags)  ← 设置停止标志
  │
  ├─ wake_up_process(task)                           ← 唤醒线程
  │    └─ 线程被唤醒后检查 kthread_should_stop() → 退出循环
  │
  ├─ wait_for_completion(&kthread->exited)           ← 等待线程退出
  │
  └─ return ret                                      ← 返回 threadfn 的返回值
```

**重要**：`kthread_stop()` 是阻塞的——它等待线程真正退出后才返回。因此持有锁的线程不能直接调用 `kthread_stop()` 等待另一个线程，否则可能死锁。

---

## 6. 完整生命周期

```
kthread_run(my_fn, data, "mythread")
  │
  ├── kernel_thread ── kthread() 入口
  │     ├── 初始化 kthread 结构
  │     ├── complete() → 通知创建者
  │     └── schedule() → 等待被唤醒
  │
  ├── (创建者设置亲和性/调度策略)
  │
  ├── wake_up_process(tp)               ← 开始执行 threadfn
  │     └── my_fn(data)
  │          ├── while (!kthread_should_stop()) {
  │          │       // 执行工作
  │          │       schedule_timeout(HZ);
  │          │   }
  │          └── return 0
  │
  └── kthread_stop(tp)
        ├── 设置 KTHREAD_SHOULD_STOP
        ├── wake_up_process(tp)
        │     └── my_fn 检查标志 → 退出循环 → do_exit
        └── wait_for_completion(&exited) → 返回
```

---

## 7. 设计决策总结

| 决策 | 原因 |
|------|------|
| `kthread_create` + `wake_up_process` 分离 | 创建者可在启动前设置属性 |
| `kthread_should_stop()` 轮询模式 | 线程决定何时安全退出 |
| `complete()` 同步 | 可靠等待线程到达某个状态点 |
| 共享 `init_mm` | 不浪费页表，无需用户空间地址 |

---

## 8. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/kthread.h` | `kthread_create` / `kthread_run` | API 宏 |
| `include/linux/kthread.h` | `kthread_should_stop` | 内联 |
| `kernel/kthread.c` | `kthread` | 线程入口 |
| `kernel/kthread.c` | `kthread_create` | 创建逻辑 |
| `kernel/kthread.c` | `kthread_stop` | 停止逻辑 |
| `kernel/kthread.c` | `__kthread_create_on_node` | 实际创建函数 |
| `kernel/kthread.c` | `kthreadd` | kthreadd 守护线程 |

---

## 9. 关联文章

- **workqueue**（article 13）：worker 线程实质上是 kthread
- **completion**（article 11）：kthread_stop 使用 completion 同步

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
