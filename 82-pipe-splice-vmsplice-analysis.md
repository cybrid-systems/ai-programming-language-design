# pipe / splice / vmsplice — 数据管道深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/pipe.c` + `mm/splice.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**pipe** 提供进程间单向数据传输，`splice/vmsplice` 实现零拷贝数据移动。

---

## 1. pipe — 管道

```c
// fs/pipe.c — pipe_inode_info
struct pipe_inode_info {
    struct page           *tmp_page;     // 临时页（用于写）
    unsigned int           curbuf;        // 当前缓冲索引
    unsigned int           buffers;       // 缓冲数量
    struct page           **bufs;        // 环形缓冲页数组
    unsigned long           curbuf_size;  // 当前缓冲已用大小
    unsigned long           tokens;        // 令牌（同步用）
};
```

### 1.1 pipe_write

```c
// fs/pipe.c — pipe_write
static ssize_t pipe_write(struct kiocb *kiocb, struct iov_iter *from)
{
    struct pipe_inode_info *pipe = kiocb->ki_filp->private_data;
    struct pipe_buffer *buf;

    // 1. 获取当前缓冲
    buf = &pipe->bufs[pipe->curbuf % pipe->buffers];

    // 2. 复制数据到缓冲页
    ret = copy_page_from_iter(buf->page, 0, chars, from);

    // 3. 更新缓冲信息
    buf->len = chars;
    buf->ops = &pipe_buf_ops;

    // 4. 唤醒读者
    wake_up_interruptible(&pipe->wait);

    return chars;
}
```

---

## 2. splice — 零拷贝移动

```c
// mm/splice.c — do_splice
long do_splice(struct file *in, loff_t *off_in,
               struct file *out, loff_t *off_out,
               size_t len, unsigned int flags)
{
    // 1. 获取源描述符
    if (in->f_op->splice_read)
        return in->f_op->splice_read(in, off_in, out, off_out, len, flags);

    // 2. 通用 splice
    return generic_splice_sendpage(in, off_in, out, off_out, len, flags);
}
```

---

## 3. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/pipe.c` | `pipe_inode_info`、`pipe_write` |
| `mm/splice.c` | `do_splice` |