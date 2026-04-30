# Linux Kernel eventfd / signalfd 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/eventfd.c` + `fs/signalfd.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 概述

**eventfd** 和 **signalfd** 是 Linux 特有的**文件描述符化**机制——把内核事件和信号转换为 `read()/write()` 可操作的 FD。

---

## 1. eventfd — 事件通知 FD

### 1.1 创建

```c
// fs/eventfd.c — eventfd_fops
// 用户空间：
int efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
```

### 1.2 核心结构

```c
// include/linux/eventfd.h — eventfd_ctx
struct eventfd_ctx {
    __u64    count;          // 计数器值（64-bit）
    wait_queue_head_t wqh;   // 等待队列
    spinlock_t lock;
};
```

### 1.3 读写

```c
// fs/eventfd.c — eventfd_write
static ssize_t eventfd_write(struct file *file, const char __user *buf,
                  size_t count, loff_t *ppos)
{
    __u64 u64;

    copy_from_user(&u64, buf, sizeof(u64));

    spin_lock(&ctx->lock);
    ctx->count += u64;                    // 增加计数器
    if (ctx->count > 0)
        wake_up_poll(&ctx->wqh, EPOLLOUT);  // 唤醒等待者
    spin_unlock(&ctx->lock);
}

// fs/eventfd.c — eventfd_read
static ssize_t eventfd_read(struct file *file, char __user *buf,
                size_t count, loff_t *ppos)
{
    __u64 u64 = ctx->count;

    copy_to_user(buf, &u64, sizeof(u64)); // 返回计数器值
    ctx->count = 0;                        // 读取后清零
}
```

### 1.4 应用场景

```c
// 用户空间事件通知（替代 pipe）
// 线程 A 写：
write(efd, &(uint64_t){1}, sizeof(uint64_t));

// 线程 B 读（配合 epoll）：
epoll_wait(epfd, ...);  // efd 触发 EPOLLIN
read(efd, &val, sizeof(val));
```

---

## 2. signalfd — 信号 FD

### 2.1 创建

```c
// fs/signalfd.c — signalfd_fd
// 用户空间：
sigset_t mask;
sigemptyset(&mask);
sigaddset(&mask, SIGINT);
sigaddset(&mask, SIGTERM);
int sfd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
```

### 2.2 核心结构

```c
// fs/signalfd.c — signalfd_ctx
struct signalfd_ctx {
    sigset_t        mask;           // 订阅的信号集
    struct list_head    pending_list;  // 待处理的信号
    spinlock_t        pending_lock;
};
```

### 2.3 读取信号

```c
// fs/signalfd.c — signalfd_read
static ssize_t signalfd_read(struct file *file, char __user *buf,
                 size_t count, loff_t *ppos)
{
    struct signalfd_siginfo siginfo;

    spin_lock(&ctx->pending_lock);
    siginfo = list_first_entry(&ctx->pending_list,
                   struct signalfd_siginfo, list);
    list_del(&siginfo.list);
    spin_unlock(&ctx->pending_lock);

    copy_to_user(buf, &siginfo, sizeof(siginfo));
}
```

---

## 3. 对比

| 特性 | eventfd | signalfd |
|------|---------|----------|
| 用途 | 通用事件通知 | 信号事件 |
| 读取值 | 计数器值（64-bit）| `signalfd_siginfo` 结构 |
| 触发方式 | `write()` 增加计数 | 内核发送信号 |
| 等待方式 | `epoll()` | `epoll()` |
| 典型场景 | 线程池任务完成通知 | 替代 `sigwaitinfo()` |

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `fs/eventfd.c` | `eventfd_write`、`eventfd_read`、`eventfd_poll` |
| `fs/signalfd.c` | `signalfd_read`、`signalfd_poll` |
| `include/uapi/linux/eventfd.h` | `struct eventfd_siginfo` |
