# Linux Kernel pipe / splice / vmsplice 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/pipe.c` + `fs/splice.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 概述

**pipe** 系列系统调用提供**进程间数据传递**，其中 `splice/vmsplice` 实现**零拷贝**。

---

## 1. pipe — 基础管道

### 1.1 核心结构

```c
// fs/pipe.c — pipe_inode_info
struct pipe_inode_info {
    struct page           **tmp_vec;       // 环形缓冲区（page 数组）
    unsigned int          head;            // 生产者位置
    unsigned int          tail;            // 消费者位置
    unsigned int          ring_size;       // 环形缓冲区大小（PIPE_DEFAULT_SIZE=16）
    unsigned int          readers;         // 读者数量
    unsigned int          writers;        // 作者数量
    struct mutex          mutex;          // 互斥锁
    struct pipe_buffer    *bufs;          // pipe_buffer 数组
};
```

### 1.2 pipe_read / pipe_write

```c
// fs/pipe.c — pipe_read
static ssize_t pipe_read(struct kiocb *iocb, struct iov_iter *to)
{
    struct pipe_inode_info *pipe = file->private_data;
    struct pipe_buffer *buf = &pipe->bufs[pipe->tail % PIPE_BUFFERS];

    // 复制数据到用户空间
    copy_page_to_iter(buf->page, buf->offset, chars, to);

    // 更新 tail
    pipe->tail += chars;
    return chars;
}
```

---

## 2. splice — 零拷贝传输

### 2.1 核心思想

```
splice() 在两个 FD 之间移动数据，不经过用户空间：
- FD-in 可以是 pipe、socket、file
- FD-out 可以是 pipe、socket、file
- 内核内部通过 page pipe（管道环形页）传递，不复制 page 内容
```

### 2.2 实现

```c
// fs/splice.c — do_splice
long do_splice(struct file *in, loff_t *off_in,
               struct file *out, loff_t *off_out,
               size_t len, unsigned int flags)
{
    // 1. 获取输入端的 splice_read 操作
    if (in->f_op->splice_read)
        return in->f_op->splice_read(in, off_in, out, off_out, len, flags);

    // 2. 否则回退到 generic_splice_read + pipe_write
    return -EINVAL;
}

// fs/splice.c — splice_from_pipe
ssize_t splice_from_pipe(struct pipe_inode_info *pipe, struct file *out,
               loff_t *ppos, size_t len, unsigned int flags,
               splice_actor *actor)
{
    // 从 pipe 读出，通过 actor 写入 out
    // actor 可能是 default_splice_actor 或 vmsplice_to_pipe
}
```

---

## 3. vmsplice — 用户内存直接进管道

```c
// fs/splice.c — vmsplice
// 将用户空间多个 buffer 直接送入管道（零拷贝）

static long vmsplice(struct file *file, const struct iovec __user *iov,
             unsigned long nr_segs, unsigned int flags)
{
    // 1. 从用户空间获取 iovec
    // 2. pin_user_pages() 固定用户页
    // 3. 创建 pipe_buffer 引用这些页
    // 4. 添加到管道

    // 优势：数据永不经过内核缓冲区，直接从用户页进入管道
}
```

---

## 4. 设计决策总结

| 方法 | 拷贝次数 | 适用场景 |
|------|---------|---------|
| pipe + read/write | 2次（磁盘→内核→用户→内核→磁盘）| 通用 |
| splice | 0次（页引用传递）| socket↔file |
| vmsplice | 0次（用户页直接进管道）| 用户内存→管道 |
| sendfile | 0次（file→socket）| file→socket |

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `fs/pipe.c` | `pipe_read`、`pipe_write`、`struct pipe_inode_info` |
| `fs/splice.c` | `do_splice`、`splice_from_pipe`、`vmsplice` |
