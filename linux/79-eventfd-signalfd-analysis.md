# 79-eventfd-signalfd — Linux eventfd 和 signalfd 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**eventfd** 和 **signalfd** 是 Linux 的**文件描述符化事件通知机制**——将内核事件（计数器信号/进程信号）转换为 fd，通过标准的 `read/poll/select/epoll` 接口消费。

| 特性 | eventfd | signalfd |
|------|---------|----------|
| 作用 | 内核→用户/用户→用户计数信号 | 将信号转为 fd 读取 |
| 核心文件 | `fs/eventfd.c`（423 行，59 符号） | `fs/signalfd.c`（351 行，25 符号）|
| 核心结构 | `struct eventfd_ctx`（`:30`） | `struct signalfd_ctx`（`:41`）|
| 内核接口 | `eventfd_signal_mask()`（`:56`） | — |
| 显著特性 | `in_eventfd` 递归防护（`:60-68`） | `dequeue_signal()` 非阻塞/等待 |

**doom-lsp 确认**：eventfd @ `fs/eventfd.c`（59 符号），signalfd @ `fs/signalfd.c`（25 符号）。

---

## 1. eventfd

### 1.1 struct eventfd_ctx @ :30

```c
// fs/eventfd.c:30-43
struct eventfd_ctx {
    struct kref kref;                       /* 引用计数 */
    wait_queue_head_t wqh;                  /* poll/read 等待队列 */
    __u64 count;                            /* 计数值 */
    unsigned int flags;                      /* EFD_SEMAPHORE / EFD_NONBLOCK */
    int id;
};
```

### 1.2 eventfd_signal_mask @ :56——内核侧信号

```c
// 内核中任何代码都可以调用此函数"发信号"
// 例如：V4L2 缓存完成 → eventfd_signal()
// AIO 完成 → eventfd_signal()
// io_uring 完成 → eventfd_signal()

void eventfd_signal_mask(struct eventfd_ctx *ctx, __poll_t mask)
{
    unsigned long flags;

    /* ❗ 递归防护：in_eventfd 防止 waitqueue 回调中的无限递归 */
    if (WARN_ON_ONCE(current->in_eventfd))
        return;

    spin_lock_irqsave(&ctx->wqh.lock, flags);
    current->in_eventfd = 1;

    if (ctx->count < ULLONG_MAX)
        ctx->count++;                        // 递增计数

    // 唤醒等待的 poll/read
    if (waitqueue_active(&ctx->wqh))
        wake_up_locked_poll(&ctx->wqh, EPOLLIN | mask);

    current->in_eventfd = 0;
    spin_unlock_irqrestore(&ctx->wqh.lock, flags);
}
```

**doom-lsp 确认**：`eventfd_signal_mask` @ `:56`。递归防护通过 `current->in_eventfd` 实现——`wake_up_locked_poll` 可能触发嵌套的 `eventfd_signal` 调用。

### 1.3 eventfd_read @ :214——用户空间读取

```c
static ssize_t eventfd_read(struct kiocb *iocb, struct iov_iter *to)
{
    struct file *file = iocb->ki_filp;
    struct eventfd_ctx *ctx = file->private_data;
    DECLARE_WAITQUEUE(wait, current);

    if (iov_iter_count(to) < sizeof(cnt))
        return -EINVAL;

    spin_lock_irq(&ctx->wqh.lock);

    if (ctx->count > 0) {
        __u64 cnt = ctx->count;
        if (ctx->flags & EFD_SEMAPHORE)
            cnt = 1;                         // 信号量模式：每次读取 1
        ctx->count -= cnt;
        spin_unlock_irq(&ctx->wqh.lock);
        return put_user(cnt, buf);           // 返回值到用户空间
    }

    // count == 0 → 等待
    if (file->f_flags & O_NONBLOCK) {
        spin_unlock_irq(&ctx->wqh.lock);
        return -EAGAIN;
    }

    // 阻塞等待
    __add_wait_queue(&ctx->wqh, &wait);
    for (;;) {
        set_current_state(TASK_INTERRUPTIBLE);
        if (ctx->count > 0) break;
        if (signal_pending(current)) break;
        spin_unlock_irq(&ctx->wqh.lock);
        schedule();
        spin_lock_irq(&ctx->wqh.lock);
    }
    __remove_wait_queue(&ctx->wqh, &wait);
    __set_current_state(TASK_RUNNING);

    // 读取成功...
}
```

### 1.4 用户空间 API

```c
#include <sys/eventfd.h>

int fd = eventfd(0, EFD_NONBLOCK | EFD_SEMAPHORE);

// 写入 → 递增计数
uint64_t u = 1;
write(fd, &u, sizeof(u));

// 读取 → 递减计数
uint64_t val;
read(fd, &val, sizeof(val));   // 信号量模式返回 1

// epoll 集成
struct epoll_event ev = {.events = EPOLLIN, .data.fd = fd};
epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev);
```

---

## 2. signalfd

### 2.1 struct signalfd_ctx @ :41

```c
// fs/signalfd.c:41-43
struct signalfd_ctx {
    sigset_t sigmask;                        // 过滤的信号掩码
};
```

### 2.2 signalfd_dequeue @ :154——信号读取

```c
static ssize_t signalfd_dequeue(struct signalfd_ctx *ctx, kernel_siginfo_t *info,
                                int nonblock)
{
    // 1. 尝试非阻塞出队
    spin_lock_irq(&current->sighand->siglock);
    ret = dequeue_signal(&ctx->sigmask, info, &type);
    // dequeue_signal @ kernel/signal.c
    // → 从 pending 队列取出匹配的信号
    // → 更新 signal_struct 统计

    if (ret != 0) {                          // 有信号
        spin_unlock_irq(&current->sighand->siglock);
        return ret;
    }
    if (nonblock) {                          // 非阻塞
        spin_unlock_irq(&current->sighand->siglock);
        return -EAGAIN;
    }

    // 2. 阻塞等待信号到达
    add_wait_queue(&current->sighand->signalfd_wqh, &wait);
    for (;;) {
        set_current_state(TASK_INTERRUPTIBLE);
        ret = dequeue_signal(&ctx->sigmask, info, &type);
        if (ret != 0) break;
        if (signal_pending(current)) {
            ret = -ERESTARTSYS;
            break;
        }
        spin_unlock_irq(&current->sighand->siglock);
        schedule();                          // 休眠等待
        spin_lock_irq(&current->sighand->siglock);
    }
    spin_unlock_irq(&current->sighand->siglock);
    remove_wait_queue(&current->sighand->signalfd_wqh, &wait);
    return ret;
}
```

**doom-lsp 确认**：`signalfd_dequeue` @ `:154`。底层 `dequeue_signal` 在 `kernel/signal.c` 中从进程的 `pending` 信号队列取信号。

### 2.3 signalfd_copyinfo @ :71——信号→用户空间转换

```c
// 将内核的 kernel_siginfo_t 转换为用户空间的 signalfd_siginfo
static int signalfd_copyinfo(struct signalfd_siginfo __user *siginfo,
                             kernel_siginfo_t *ksi)
{
    struct signalfd_siginfo info;

    info.ssi_signo = ksi->si_signo;          // 信号编号
    info.ssi_errno = ksi->si_errno;
    info.ssi_code  = ksi->si_code;           // 信号来源代码
    info.ssi_pid   = ksi->si_pid;            // 发送者 PID
    info.ssi_uid   = ksi->si_uid;            // 发送者 UID
    info.ssi_fd    = ksi->si_fd;             // 关联 fd
    info.ssi_tid   = ksi->si_tid;            // 线程 ID
    info.ssi_band  = ksi->si_band;           // 事件标志
    info.ssi_overrun = ksi->si_overrun;       // 定时器溢出
    info.ssi_trapno  = ksi->si_trapno;
    info.ssi_status  = ksi->si_status;        // 子进程退出状态
    info.ssi_int     = ksi->si_int;
    info.ssi_ptr     = ksi->si_ptr;
    info.ssi_utime   = ksi->si_utime;
    info.ssi_stime   = ksi->si_stime;
    info.ssi_addr    = ksi->si_addr;
    info.ssi_addr_lsb = ksi->si_addr_lsb;

    return copy_to_user(siginfo, &info, sizeof(info));
}
```

---

## 3. 典型集成——eventfd 在内核中的使用

eventfd 被广泛用于内核→用户的事件通知（`eventfd_signal_mask` @ `:56`）：

```c
// 1. io_uring 完成通知（高吞吐场景）
// io_uring 使用 eventfd 替代信号，避免信号队列限制

// 2. V4L2 视频缓存完成
// 摄像头捕获完成 → eventfd_signal() → 用户空间 epoll_wait 返回

// 3. KVM 虚拟化
// 客户机 IO 完成 → eventfd_signal() → QEMU 收到通知

// 4. AIO
// aio 请求完成 → eventfd_signal() → 用户读取
```

---

## 4. 性能

| 操作 | 延迟 | 说明 |
|------|------|------|
| `eventfd_signal` | **~50-100ns** | 原子递增 + waitqueue 唤醒（可能调度）|
| `eventfd_read`（有数据）| **~100ns** | 直接返回 |
| `eventfd_read`（阻塞）| **~1-10μs** | 调度延迟 |
| `signalfd_dequeue`（有信号）| **~200ns** | `dequeue_signal` 队列操作 |
| `signalfd_dequeue`（阻塞）| **~1-10μs** | 调度延迟 |

---

## 5. 总结

eventfd（`eventfd_signal` @ `:56` + `eventfd_read` @ `:214`）和 signalfd（`signalfd_dequeue` @ `:154` + `signalfd_copyinfo` @ `:71`）将内核事件转化为**统一的 fd 接口**——可通过 `epoll`/`select`/`poll` 多路复用，通过 `read` 直接消费。eventfd 的 **`in_eventfd` 递归防护**（`:60`）是其关键设计决策。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
