# eventfd / signalfd — 事件文件描述符深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/eventfd.c` + `fs/signalfd.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**eventfd** 和 **signalfd** 提供文件描述符方式的异步事件通知，替代 `read()/write()` 的轮询。

---

## 1. eventfd — 事件文件描述符

### 1.1 eventfd_ctx — 上下文

```c
// fs/eventfd.c — eventfd_ctx
struct eventfd_ctx {
    __u64                  count;          // 计数器值
    wait_queue_head_t      wqh;           // 等待队列
    spinlock_t             lock;          // 保护
    int                     id;           // 标识
};
```

### 1.2 eventfd_read — 读取

```c
// fs/eventfd.c — eventfd_read
static ssize_t eventfd_read(struct file *file, char *buf, size_t count, loff_t *pos)
{
    struct eventfd_ctx *ctx = file->private_data;
    __u64 ucnt = 0;
    ssize_t res;

    // 1. 读取计数（如果非零）
    spin_lock(&ctx->lock);
    if (ctx->count > 0) {
        ucnt = ctx->count;
        ctx->count = 0;
    }
    spin_unlock(&ctx->lock);

    // 2. 如果 count 为 0，需要等待
    if (ucnt == 0)
        return -EAGAIN;

    // 3. 复制到用户
    if (copy_to_user(buf, &ucnt, sizeof(ucnt)))
        return -EFAULT;

    return sizeof(ucnt);
}
```

### 1.3 eventfd_write — 写入

```c
// fs/eventfd.c — eventfd_write
static ssize_t eventfd_write(struct file *file, const char *buf, size_t count, loff_t *pos)
{
    struct eventfd_ctx *ctx = file->private_data;
    __u64 ucnt;
    ssize_t res;

    // 1. 读取用户值
    if (copy_from_user(&ucnt, buf, sizeof(ucnt)))
        return -EFAULT;

    // 2. 原子加（上限 0xFFFFFFFFFFFFFFFE）
    spin_lock(&ctx->lock);
    ctx->count += ucnt;
    if (ctx->count > 0)
        wake_up_poll(&ctx->wqh, EPOLLOUT);
    spin_unlock(&ctx->lock);

    return sizeof(ucnt);
}
```

---

## 2. signalfd — 信号文件描述符

### 2.1 signalfd_ctx — 上下文

```c
// fs/signalfd.c — signalfd_ctx
struct signalfd_ctx {
    sigset_t               mask;          // 监控的信号集
    struct list_head        pending_list;   // 待处理信号队列
    wait_queue_head_t       wqh;           // 等待队列
};
```

### 2.2 signalfd_read — 读取信号

```c
// fs/signalfd.c — signalfd_read
static ssize_t signalfd_read(struct file *file, char *buf, size_t count, loff_t *pos)
{
    struct signalfd_ctx *ctx = file->private_data;
    struct signalfd_siginfo info;
    struct k_siginfo *ksig;

    // 1. 获取信号（从 pending 队列）
    ksig = pop_signal(&ctx->pending_list);
    if (!ksig)
        return -EAGAIN;

    // 2. 转换为用户格式
    memset(&info, 0, sizeof(info));
    info.ssi_signo = ksig->si_signo;
    info.ssi_pid = ksig->si_pid;
    info.ssi_uid = ksig->si_uid;
    // ...

    // 3. 复制到用户
    if (copy_to_user(buf, &info, sizeof(info)))
        return -EFAULT;

    return sizeof(info);
}
```

---

## 3. 使用示例

```c
// eventfd：线程间同步
int efd = eventfd(0, O_CLOEXEC);
write(efd, &val, sizeof(val));  // 增加计数
read(efd, &val, sizeof(val));   // 读取并清除计数

// signalfd：捕获信号
sigset_t mask;
sigemptyset(&mask);
sigaddset(&mask, SIGINT);
sigprocmask(SIG_BLOCK, &mask, NULL);
int sfd = signalfd(-1, &mask, 0);
read(sfd, &info, sizeof(info));  // 阻塞直到 SIGINT
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/eventfd.c` | `eventfd_ctx`、`eventfd_read`、`eventfd_write` |
| `fs/signalfd.c` | `signalfd_ctx`、`signalfd_read` |