# 79-eventfd-signalfd — Linux eventfd 和 signalfd 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**eventfd** 和 **signalfd** 将内核事件转化为**文件描述符**——eventfd 提供计数器信号（`eventfd_signal` 递增计数，`read` 消费），signalfd 将进程信号转为 fd 读取。

**doom-lsp 确认**：eventfd @ `fs/eventfd.c`（423 行，59 符号），signalfd @ `fs/signalfd.c`（351 行，25 符号）。

---

## 1. eventfd

### 1.1 struct eventfd_ctx @ :30

```c
struct eventfd_ctx {
    struct kref kref;                       /* 引用计数 */
    wait_queue_head_t wqh;                  /* 等待队列头 */
    __u64 count;                             /* 计数器值 */
    unsigned int flags;                      /* EFD_SEMAPHORE / EFD_NONBLOCK */
    int id;                                  /* IDA 分配的 ID */
};
```

**`count` 语义**：
- `write(fd, &n)` → `count += n`（最大 `ULLONG_MAX`）
- `read(fd)` → 非信号量模式：返回 `count` 并置 0；信号量模式：返回 1 并 `count -= 1`

---

### 1.2 do_eventfd @ :379——fd 创建

```c
static int do_eventfd(unsigned int count, int flags)
{
    struct eventfd_ctx *ctx __free(kfree) = NULL;

    ctx = kmalloc(sizeof(*ctx), GFP_KERNEL);
    kref_init(&ctx->kref);                      // 引用计数初始 = 1
    init_waitqueue_head(&ctx->wqh);
    ctx->count = count;                          // 初始计数值
    ctx->flags = flags;                          // EFD_SEMAPHORE / EFD_NONBLOCK

    // anon_inode 创建文件
    // → eventfd_fops 挂接 read/write/poll/release
    FD_PREPARE(fdf, flags,
        anon_inode_getfile_fmode("[eventfd]", &eventfd_fops,
                                  ctx, flags, FMODE_NOWAIT));

    ctx->id = ida_alloc(&eventfd_ida, GFP_KERNEL);  // 全局 ID
    retain_and_null_ptr(ctx);
    return fd_publish(fdf);                     // → fd_install
}
```

**doom-lsp 确认**：`do_eventfd` @ `:379`。`SYSCALL_DEFINE2(eventfd2)` @ `:414`。`FMODE_NOWAIT` 标记支持 IOCB_NOWAIT。

---

### 1.3 eventfd_signal_mask @ :56——内核信号（关键）

```c
void eventfd_signal_mask(struct eventfd_ctx *ctx, __poll_t mask)
{
    unsigned long flags;

    // ❗ 递归防护——防止 waitqueue 回调中的无限递归
    if (WARN_ON_ONCE(current->in_eventfd))
        return;

    spin_lock_irqsave(&ctx->wqh.lock, flags);
    current->in_eventfd = 1;

    if (ctx->count < ULLONG_MAX)
        ctx->count++;

    if (waitqueue_active(&ctx->wqh))
        wake_up_locked_poll(&ctx->wqh, EPOLLIN | mask);

    current->in_eventfd = 0;
    spin_unlock_irqrestore(&ctx->wqh.lock, flags);
}
```

**设计决策**：`in_eventfd` 防止 `wake_up_locked_poll` 回调中再次调用 `eventfd_signal` 导致栈溢出。例如 epoll 的 `ep_poll_callback` 可能最终调用 `eventfd_signal`。

**doom-lsp 确认**：`eventfd_signal_mask` @ `:56`。`current->in_eventfd` 在 `include/linux/sched.h` 中声明。

---

### 1.4 eventfd_read @ :214——用户读取

```c
static ssize_t eventfd_read(struct kiocb *iocb, struct iov_iter *to)
{
    spin_lock_irq(&ctx->wqh.lock);

    if (!ctx->count) {                       // 无数据
        if (file->f_flags & O_NONBLOCK) {    // 非阻塞
            spin_unlock_irq(&ctx->wqh.lock);
            return -EAGAIN;
        }
        // 阻塞等待
        wait_event_interruptible_locked_irq(ctx->wqh, ctx->count);
        // → 释放锁 → 调度 → 唤醒后重新获取锁
    }

    eventfd_ctx_do_read(ctx, &ucnt);          // 读取值
    // 读完成后唤醒写端（让 write 不再阻塞）
    current->in_eventfd = 1;
    if (waitqueue_active(&ctx->wqh))
        wake_up_locked_poll(&ctx->wqh, EPOLLOUT);
    current->in_eventfd = 0;
    spin_unlock_irq(&ctx->wqh.lock);

    copy_to_iter(&ucnt, sizeof(ucnt), to);
    return sizeof(ucnt);
}
```

### 1.5 eventfd_write @ :247——用户写入

```c
static ssize_t eventfd_write(struct file *file, const char __user *buf, size_t count,
                             loff_t *ppos)
{
    spin_lock_irq(&ctx->wqh.lock);

    // 检查是否会溢出
    res = -EAGAIN;
    if (ULLONG_MAX - ctx->count > ucnt)
        res = sizeof(ucnt);
    else if (!(file->f_flags & O_NONBLOCK)) {
        // 阻塞直到有空间
        res = wait_event_interruptible_locked_irq(ctx->wqh,
                    ULLONG_MAX - ctx->count > ucnt);
        if (!res) res = sizeof(ucnt);
    }

    if (res > 0) {
        ctx->count += ucnt;                  // 递增计数
        current->in_eventfd = 1;
        if (waitqueue_active(&ctx->wqh))
            wake_up_locked_poll(&ctx->wqh, EPOLLIN);  // 通知读端
        current->in_eventfd = 0;
    }
    spin_unlock_irq(&ctx->wqh.lock);
    return res;
}
```

---

### 1.6 eventfd_poll @ :118——poll 与内存序

```c
static __poll_t eventfd_poll(struct file *file, poll_table *wait)
{
    poll_wait(file, &ctx->wqh, wait);      // 加入等待队列

    /*
     * count 的读取放在 poll_wait 之后。poll_wait 内部持有 wqh.lock
     * （通过 add_wait_queue），这个 spin_lock 提供 acquire 屏障。
     * 保证了我们不会在 add_wait_queue 之前读到旧的 count 值——
     * 否则可能出现：poll 返回 0（没数据）→ 在 poll_wait 之前
     * 写入方 signal → 但 waitqueue_active 为 false → 不唤醒
     * → 永久丢失唤醒事件。
     *
     * poll_wait 的 lock 保证：count 的读取不早于 add_wait_queue。
     */
    count = READ_ONCE(ctx->count);

    if (count > 0)        events |= EPOLLIN;
    if (count == ULLONG_MAX) events |= EPOLLERR;
    if (ULLONG_MAX - 1 > count) events |= EPOLLOUT;
    return events;
}
```

**doom-lsp 确认**：`eventfd_poll` @ `:118`。注释详细解释了 poll 的内存序正确性——`poll_wait` 的 `spin_lock` 提供 acquire 语义，保证 count 读取在 add_wait_queue 之后可见。

---

### 1.7 eventfd_ctx_remove_wait_queue @ :198——KVM/VFIO 专用 API

```c
// KVM 和 VFIO 使用此 API 自定义等待——直接操作 waitqueue
// 而不是通过标准的 read/poll 路径：
//
// 1. 自行 add_wait_queue 到 ctx->wqh
// 2. 等待事件（自己的调度机制）
// 3. 调用此 API 移除自身并读取 count

int eventfd_ctx_remove_wait_queue(struct eventfd_ctx *ctx, wait_queue_entry_t *wait,
                                  __u64 *cnt)
{
    spin_lock_irqsave(&ctx->wqh.lock, flags);
    eventfd_ctx_do_read(ctx, cnt);                 // 读取值
    __remove_wait_queue(&ctx->wqh, wait);           // 移除自身
    if (*cnt != 0 && waitqueue_active(&ctx->wqh))
        wake_up_locked_poll(&ctx->wqh, EPOLLOUT);   // 唤醒其他等待者
    spin_unlock_irqrestore(&ctx->wqh.lock, flags);

    return *cnt != 0 ? 0 : -EAGAIN;
}
```

**doom-lsp 确认**：`eventfd_ctx_remove_wait_queue` @ `:198`。`eventfd_ctx_do_read` @ `:176`。

---

## 2. signalfd

### 2.1 struct signalfd_ctx @ :41

```c
struct signalfd_ctx {
    sigset_t sigmask;                        // 感兴趣的信号集合
};
```

### 2.2 do_signalfd4 @ :251——创建

```c
static int do_signalfd4(int fd, sigset_t *mask, int flags)
{
    struct signalfd_ctx *ctx;

    // 如果 fd != -1 → 替换已存在的 signalfd
    if (fd != -1) {
        struct file *file = fget(fd);
        ctx = file->private_data;
        ctx->sigmask = *mask;               // 更新信号掩码
        fput(file);
        return fd;
    }

    // 创建新 signalfd
    ctx = kmalloc(sizeof(*ctx), GFP_KERNEL);
    ctx->sigmask = *mask;                    // 设置要捕获的信号

    fd = anon_inode_getfd("[signalfd]", &signalfd_fops, ctx, flags);
    // → eventfd_cleanup 在 release 时 kfree(ctx)
}
```

### 2.3 signalfd_dequeue @ :154——信号读取（核心）

```c
// 用户 read(signalfd_fd, buf, size) → signalfd_read_iter
// → signalfd_dequeue() 从 pending 队列取信号

static ssize_t signalfd_dequeue(struct signalfd_ctx *ctx,
                                kernel_siginfo_t *info, int nonblock)
{
    // 1. 尝试非阻塞出队
    spin_lock_irq(&current->sighand->siglock);
    ret = dequeue_signal(&ctx->sigmask, info, &type);
    // dequeue_signal 从 current->pending 或 current->signal->shared_pending
    // 取信号，更新 signal_struct 的计数值

    if (ret != 0) {                          // 有可读信号
        spin_unlock_irq(&current->sighand->siglock);
        return ret;
    }
    if (nonblock) {                          // EFD_NONBLOCK
        spin_unlock_irq(&current->sighand->siglock);
        return -EAGAIN;
    }

    // 2. 阻塞等待
    add_wait_queue(&current->sighand->signalfd_wqh, &wait);
    for (;;) {
        set_current_state(TASK_INTERRUPTIBLE);
        ret = dequeue_signal(&ctx->sigmask, info, &type);
        if (ret != 0) break;                 // 收到信号
        if (signal_pending(current)) {       // 其他信号
            ret = -ERESTARTSYS;
            break;
        }
        spin_unlock_irq(&current->sighand->siglock);
        schedule();
        spin_lock_irq(&current->sighand->siglock);
    }
    spin_unlock_irq(&current->sighand->siglock);
    remove_wait_queue(&current->sighand->signalfd_wqh, &wait);
    __set_current_state(TASK_RUNNING);
    return ret;
}
```

**doom-lsp 确认**：`signalfd_dequeue` @ `:154`。底层 `dequeue_signal` 在 `kernel/signal.c` 中——从 `struct task_struct` 的 `pending` 信号链表取出第一个匹配的信号。

---

## 3. 内核集成

eventfd 被广泛用于内核→用户异步通知：

| 子系统 | 用法 |
|--------|------|
| **KVM** | 客户机 IO 完成 → `eventfd_signal` → QEMU epoll 返回 |
| **VFIO** | 设备中断 → `eventfd_signal` → 用户空间中断处理 |
| **io_uring** | 完成事件 → `eventfd_signal` → 用户 epoll 通知 |
| **AIO** | aio 完成 → `eventfd_signal` → epoll 通知 |

---

## 4. 关键函数索引

| 函数 | 文件:行号 | 作用 |
|------|----------|------|
| `do_eventfd` | `eventfd.c:379` | fd 创建（kmalloc + anon_inode + ida）|
| `eventfd_signal_mask` | `eventfd.c:56` | 内核侧信号（in_eventfd 递归防护）|
| `eventfd_read` | `eventfd.c:214` | 用户读取（阻塞/非阻塞）|
| `eventfd_write` | `eventfd.c:247` | 用户写入（溢出检测）|
| `eventfd_poll` | `eventfd.c:118` | poll（内存序屏障分析）|
| `eventfd_ctx_remove_wait_queue` | `eventfd.c:198` | KVM/VFIO 专用 API |
| `do_signalfd4` | `signalfd.c:251` | signalfd 创建 |
| `signalfd_dequeue` | `signalfd.c:154` | 信号出队（阻塞/非阻塞）|

---

## 5. 总结

eventfd（`eventfd_signal_mask` @ `:56` + `eventfd_read` @ `:214` + `eventfd_write` @ `:247`）将**计数器通知**转换为 fd，通过 `in_eventfd` 递归防护（`:60`）和 `poll_wait` 屏障分析（`:118`）保证正确性。signalfd（`signalfd_dequeue` @ `:154`）将**信号传递**转换为 fd，底层通过 `dequeue_signal`（`kernel/signal.c`）从 pending 队列取信号。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
