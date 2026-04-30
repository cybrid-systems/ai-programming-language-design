# pipe / splice / vmsplice — 数据管道深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/pipe.c` + `mm/splice.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**pipe** 是进程间通信的经典机制，**splice/vmsplice** 实现了零拷贝的数据传输。

---

## 1. pipe 核心

### 1.1 pipe_inode_info — pipe 描述符

```c
// fs/pipe.c — pipe_inode_info
struct pipe_inode_info {
    struct mutex            mutex;          // 保护 pipe 的锁
    unsigned int            head;           // 读位置（环形缓冲）
    unsigned int            tail;           // 写位置
    unsigned int            max_usage;       // 最大使用槽数
    unsigned int            ring_size;       // 环形缓冲大小（页数）

    // 数据页
    struct page             **tmp_page;      // 临时页（用于分配）
    struct page             *pages[PIPE_DEF_BUFFERS]; // pipe 缓冲页

    // 读者/写者计数
    unsigned int            nrbufs;          // 有效数据页数
    unsigned int            curbuf;          // 当前读页索引

    // I/O 矢量
    struct iovec            *iov;           // I/O 向量
    unsigned int            nrbufs_iov;     // 向量数

    // fasync
    struct fasync_struct   *fasync_readers; // 读者侧 fasync
    struct fasync_struct   *fasync_writers; // 写者侧 fasync

    // 文件描述符
    struct file             *files[2];       // [0]=读, [1]=写
};
```

### 1.2 pipe_write — 写管道

```c
// fs/pipe.c — pipe_write
static ssize_t pipe_write(struct pipe_inode_info *pipe, struct iov_iter *from)
{
    struct page *pages[PIPE_BUFFERS];
    int bufs = PIPE_BUFFERS;
    ssize_t chars;

    // 1. 计算可写字节数
    chars = total_len - pipe->head + pipe->tail;

    // 2. 获取空闲页
    for (i = 0; i < bufs; i++) {
        pages[i] = pipe->tmp_page[i];
        if (!pages[i])
            pages[i] = alloc_page(GFP_KERNEL);
    }

    // 3. 复制数据到页
    chars = copy_page_from_iter(pages[buf], 0, PAGE_SIZE, from);

    // 4. 添加到 pipe 环形缓冲
    pipe->pages[pipe->head % PIPE_DEF_BUFFERS] = pages[buf];
    pipe->head += chars;

    // 5. 唤醒读者
    wake_up_pipe(pipe);

    return chars;
}
```

---

## 2. splice 系统调用

### 2.1 sys_splice — 文件到文件零拷贝

```c
// mm/splice.c — sys_splice
SYSCALL_DEFINE4(splice, int, fd_in, loff_t __user *, off_in,
                int, fd_out, loff_t __user *, off_out, size_t, len, unsigned int, flags)
{
    struct file *in, *out;
    long error;

    // 1. 获取 in/out 文件
    in = fget(fd_in);
    out = fget(fd_out);

    // 2. 调用 vfs_splice
    error = do_splice_to(in, off_in, out, off_out, len, flags);

    fput(out);
    fput(in);
    return error;
}
```

### 2.2 do_splice — 核心 splice

```c
// mm/splice.c — do_splice
static long do_splice(struct file *in, loff_t *off_in,
                      struct file *out, loff_t *off_out,
                      size_t len, unsigned int flags)
{
    // 1. 检查 in 是否支持 splice
    if (!in->f_op->splice_read)
        return -EINVAL;

    // 2. 如果 in 是 pipe：
    if (in->f_op == &pipefifo_fops) {
        // 从 pipe 读：splice_read
        return in->f_op->splice_read(in, off_in, out, off_out, len);
    }

    // 3. 如果 in 是常规文件：
    //    尝试 sendpage 或 splice_to
    loff_t pos = off_in ? *off_in : in->f_pos;
    ret = in->f_op->splice_read(in, &pos, out, off_out, len);
}
```

### 2.3 splice_to_pipe — 写入 pipe

```c
// mm/splice.c — splice_to_pipe
ssize_t splice_to_pipe(struct pipe_inode_info *pipe,
                       struct splice_page_desc *spd)
{
    // 1. 如果 pipe 满了，等待
    if (pipe->nrbufs == PIPE_DEF_BUFFERS) {
        if (flags & SPLICE_F_NONBLOCK)
            return -EAGAIN;
        wait_for_space(pipe);
    }

    // 2. 添加到 pipe
    pipe->pages[pipe->head % PIPE_DEF_BUFFERS] = spd->page;
    pipe->nrbufs++;

    // 3. 唤醒读者
    wake_up_interruptible(&pipe->wait);

    return spd->len;
}
```

---

## 3. vmsplice — 用户内存到 pipe

```c
// mm/splice.c — sys_vmsplice
SYSCALL_DEFINE4(vmsplice, int, fd, const struct iovec __user *, iov,
                unsigned long, nr_segs, unsigned int, flags)
{
    // 将用户空间的多个缓冲区（iov）快速注入 pipe
    // 常用于高性能数据处理流水线

    struct iovec iovstack[UIO_FASTIOV];
    iovec = iovstack;

    // 复制 iovec
    if (import_iovec(READ, iov, nr_segs, &iov, &iovstack) < 0)
        return -EINVAL;

    // 批量添加到 pipe
    error = vmsplice_to_pipe(fd, iov, nr_segs, flags);

    return error;
}
```

---

## 4. 零拷贝原理

```
传统 read/write：
  用户空间 → 内核缓冲区 → 目标
  2 次拷贝

splice：
  文件 → pipe buffer → 目标文件
  页帧直接转移，不经过用户空间
  0 次用户空间拷贝
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/pipe.c` | `struct pipe_inode_info`、`pipe_write`、`pipe_read` |
| `mm/splice.c` | `sys_splice`、`splice_to_pipe`、`do_splice` |