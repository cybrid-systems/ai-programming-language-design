# 79-eventfd-signalfd — Linux eventfd / signalfd 机制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-08 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

eventfd 和 signalfd 是 Linux 特有的文件描述符机制，将传统的事件通知和信号传递 **文件化**——通过 read/write/poll/select/epoll 等标准 IO 接口操作。

| 机制 | 用途 | 核心文件 |
|------|------|---------|
| **eventfd** | 用户态/内核态事件计数通知 | `fs/eventfd.c`（~420 行）|
| **signalfd** | 将信号转为文件描述符可读事件 | `fs/signalfd.c` |

**核心优势**：统一 IO 事件处理模型——epoll 同时管理网络 fd、timerfd、eventfd、signalfd，无需单独的信号处理逻辑。

---

## 1. eventfd

### 1.1 struct eventfd_ctx @ eventfd.c:30

```c
// fs/eventfd.c:30
struct eventfd_ctx {
    struct kref kref;
    wait_queue_head_t wqh;     /* 等待队列（读写阻塞 + poll）*/
    __u64 count;                /* 计数器值 */
    unsigned int flags;         /* EFD_SEMAPHORE, EFD_NONBLOCK, EFD_CLOEXEC */
    int id;                     /* IDA 分配的唯一 ID */
};
```

**核心设计**：eventfd 就是一个 `__u64` 计数器 + 一个等待队列。write 增加计数 + 唤醒，read 消耗计数。

### 1.2 eventfd_write @ eventfd.c:247——写入增加计数

```c
// fs/eventfd.c:247
static ssize_t eventfd_write(struct file *file, const char __user *buf,
                              size_t count, loff_t *ppos)
{
    struct eventfd_ctx *ctx = file->private_data;
    __u64 ucnt;

    copy_from_user(&ucnt, buf, sizeof(ucnt));
    if (ucnt == ULLONG_MAX) return -EINVAL;

    spin_lock_irq(&ctx->wqh.lock);

    /* 非阻塞且溢出→EAGAIN；否则等待可写 */
    if (ULLONG_MAX - ctx->count > ucnt)
        res = sizeof(ucnt);                    /* 正常：可以累加 */
    else if (!(file->f_flags & O_NONBLOCK)) {
        res = wait_event_interruptible_locked_irq(ctx->wqh,
              ULLONG_MAX - ctx->count > ucnt); /* 阻塞直到可写 */
    } else
        res = -EAGAIN;

    if (res > 0) {
        ctx->count += ucnt;

        /* 关键：设置 in_eventfd 防止递归信号 */
        current->in_eventfd = 1;
        if (waitqueue_active(&ctx->wqh))
            wake_up_locked_poll(&ctx->wqh, EPOLLIN);
        current->in_eventfd = 0;
    }
    spin_unlock_irq(&ctx->wqh.lock);
    return res;
}
```

**关键设计细节**：
- `current->in_eventfd` 防止 eventfd 操作中处理信号导致递归
- `wake_up_locked_poll` 在持有锁时唤醒，配合 epoll 的精确唤醒
- 计数器溢出（达到 ULLONG_MAX）会被阻塞直到有人读走一部分

### 1.3 eventfd_read @ eventfd.c:214——读取消耗计数

```c
// fs/eventfd.c:214
static ssize_t eventfd_read(struct kiocb *iocb, struct iov_iter *to)
{
    struct file *file = iocb->ki_filp;
    struct eventfd_ctx *ctx = file->private_data;
    __u64 cnt;

    spin_lock_irq(&ctx->wqh.lock);

    /* 计数为零且非阻塞→EAGAIN；否则等待 */
    if (ctx->count > 0) {
        cnt = ctx->count;

        if (ctx->flags & EFD_SEMAPHORE) {
            /* 信号量模式：每次读 1 */
            cnt = 1;
            ctx->count -= 1;
        } else {
            /* 普通模式：读完清零 */
            ctx->count = 0;
        }
    } else if (!(file->f_flags & O_NONBLOCK)) {
        /* 阻塞等待有数据 */
    } else
        return -EAGAIN;

    if (cnt > 0) {
        if (waitqueue_active(&ctx->wqh))
            wake_up_locked_poll(&ctx->wqh, EPOLLOUT);
    }
    spin_unlock_irq(&ctx->wqh.lock);
    return cnt;
}
```

**EFD_SEMAPHORE vs 普通模式**：
- 普通模式：read 返回当前 count 并清零（"一次读走所有"）
- 信号量模式：每次 read 只减 1（"一次取一个令牌"）

### 1.4 eventfd_poll @ eventfd.c:118

```c
static __poll_t eventfd_poll(struct file *file, poll_table *wait)
{
    struct eventfd_ctx *ctx = file->private_data;
    u64 count;

    poll_wait(file, &ctx->wqh, wait);
    count = READ_ONCE(ctx->count);

    if (count > 0)
        events |= EPOLLIN;
    if (count == ULLONG_MAX)
        events |= EPOLLERR;
    if (ULLONG_MAX - 1 > count)
        events |= EPOLLOUT;
    return events;
}
```

**关键 memory ordering 保证**（由 poll_wait 中的 spin_lock 提供 acquire barrier）：
- `READ_ONCE(ctx->count)` 在 `poll_wait()` 之后执行
- 保证不会丢失 write 侧的 wakeup（详细注释在 eventfd.c:118-168）

### 1.5 内核态接口——eventfd_signal

```c
// 内核其他模块调用
__u64 eventfd_signal(struct eventfd_ctx *ctx, __u64 n)
{
    spin_lock_irqsave(&ctx->wqh.lock, flags);
    ctx->count += n;
    if (waitqueue_active(&ctx->wqh))
        wake_up_locked_poll(&ctx->wqh, EPOLLIN);
    spin_unlock_irqrestore(&ctx->wqh.lock, flags);
    return n;
}
```

用于内核→用户态的事件通知（如 vhost、KVM、io_uring）。

### 1.6 创建和生命周期

```c
// fs/eventfd.c:414
SYSCALL_DEFINE2(eventfd2, unsigned int, count, int, flags)
{
    struct eventfd_ctx *ctx;
    int fd;

    ctx = kmalloc(sizeof(*ctx), GFP_KERNEL);
    kref_init(&ctx->kref);
    init_waitqueue_head(&ctx->wqh);
    ctx->count = count;
    ctx->flags = flags;
    ctx->id = ida_alloc(&eventfd_ida, GFP_KERNEL);

    fd = anon_inode_getfd("[eventfd]", &eventfd_fops, ctx,
                          O_RDWR | (flags & EFD_SHARED_FCNTL_FLAGS));
    return fd;
}
```

**关键**：使用 `anon_inode_getfd()` 创建匿名 inode，不需要真实文件系统支持。生命周期通过 `kref`（内核引用计数）+ `file->private_data` 管理。

### 1.7 fops 表 @ eventfd.c:302

```c
static const struct file_operations eventfd_fops = {
    .show_fdinfo = eventfd_show_fdinfo,
    .release     = eventfd_release,
    .poll        = eventfd_poll,
    .read_iter   = eventfd_read,
    .write       = eventfd_write,
    .llseek      = noop_llseek,
};
```

---

## 2. signalfd

signalfd 将 Unix 信号转换为文件描述符。当信号递送到进程时，signalfd 变得可读，用户态通过 read() 获取 `struct signalfd_siginfo`。

### 2.1 核心状态

```c
// fs/signalfd.c
struct signalfd_ctx {
    sigset_t sigmask;     /* 此 fd 关注的信号集合 */
};
```

每个 signalfd 关联一个信号掩码。队列在 `struct task_struct->sigpending` 中统一管理——signalfd 只是信号的**观察者**，不是独立的队列。

### 2.2 信号递送路径

```
信号到达
    ↓
__send_signal()
    ↓
sigaddset(&pending->signal, sig)   /* 设置 pending 位 */
    ↓
complete_signal()
    ↓
signal_wake_up()
    ↓
wake_up_state(tsk, TASK_INTERRUPTIBLE)
    ↓
系统调用返回时 check signal → 唤醒 signalfd 的 waitqueue
    ↓
signalfd_poll() 返回 EPOLLIN
    ↓
read(fd, &siginfo, sizeof(siginfo)) → 获取信号信息
```

### 2.3 关键特性

- **信号不会被消耗**：signalfd 读取信号后，信号仍然在 task 的 pending 集中
- **择优使用**：如果设置了 signalfd，且信号在 signalfd 的 mask 中，信号不会走传统 handler
- **与 epoll 集成**：signalfd 可加入 epoll，用统一的事件循环处理 IO + 信号

---

## 3. 实际应用模式

### 3.1 eventfd as 事件计数器（epoll 事件循环）

```c
/* 线程 A：事件生产者 */
uint64_t val = 1;
write(efd, &val, sizeof(val));   /* 通知事件循环有数据 */

/* 线程 B：epoll 事件循环 */
epoll_wait(epfd, events, maxevents, -1);
/* eventfd 可读 → 处理 */
read(efd, &val, sizeof(val));
/* 继续处理实际 IO */
```

### 3.2 eventfd as semaphore（线程间令牌传递）

```c
/* EFD_SEMAPHORE 模式：每个 read 消耗一个令牌 */
int efd = eventfd(0, EFD_SEMAPHORE);

/* 生产者：释放 N 个令牌 */
val = 10; write(efd, &val, sizeof(val));

/* 消费者：逐个获取令牌 */
read(efd, &val, sizeof(val));  /* val == 1 */
```

### 3.3 signalfd + epoll（统一事件模型）

```c
sigset_t mask;
sigemptyset(&mask);
sigaddset(&mask, SIGINT);
sigaddset(&mask, SIGTERM);
sigprocmask(SIG_BLOCK, &mask, NULL);  /* 拦截信号 */

int sfd = signalfd(-1, &mask, SFD_NONBLOCK);

/* 将 signalfd 加入 epoll */
struct epoll_event ev = {.events = EPOLLIN, .data = {.fd = sfd}};
epoll_ctl(epfd, EPOLL_CTL_ADD, sfd, &ev);

/* 统一事件循环 */
while (1) {
    int n = epoll_wait(epfd, events, MAX_EVENTS, -1);
    for (i = 0; i < n; i++) {
        if (events[i].data.fd == sfd) {
            struct signalfd_siginfo fdsi;
            read(sfd, &fdsi, sizeof(fdsi));
            if (fdsi.ssi_signo == SIGINT) break;
        }
        /* 处理其他 fd */
    }
}
```

---

## 4. 总结

| 特性 | eventfd | signalfd |
|------|---------|----------|
| **核心结构** | `struct eventfd_ctx` | `struct signalfd_ctx` |
| **数据** | `__u64 count` | `struct signalfd_siginfo` |
| **IO 操作** | write+=, read-= | read 获取信号信息 |
| **阻塞语义** | 读空阻塞 / 写满阻塞 | 无信号时阻塞 |
| **epoll 集成** | 可（EPOLLIN/OUT/ERR） | 可（EPOLLIN）|
| **内核消费者** | eventfd_signal() 接口 | 不直接 |
| **通知方向** | 双向（用户↔内核） | 单向（内核→用户）|
| **典型用途** | io_uring 完成通知、线程间事件 | 信号驱动的 epoll 事件循环 |

---

### 源码索引（LSP 验证）

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct eventfd_ctx` | fs/eventfd.c | 30 |
| `eventfd_write()` | fs/eventfd.c | 247 |
| `eventfd_read()` | fs/eventfd.c | 214 |
| `eventfd_poll()` | fs/eventfd.c | 118 |
| `eventfd_ctx_fdget()` | fs/eventfd.c | 348 |
| `eventfd_ctx_fileget()` | fs/eventfd.c | 366 |
| `SYSCALL_DEFINE2(eventfd2)` | fs/eventfd.c | 414 |
| `eventfd_fops` | fs/eventfd.c | 302 |
| `eventfd_release()` | fs/eventfd.c | 109 |
| `eventfd_signal()` | kernel/events/core.c | — |
| `struct signalfd_ctx` | fs/signalfd.c | — |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-08 | 内核版本：Linux 7.0-rc1*
