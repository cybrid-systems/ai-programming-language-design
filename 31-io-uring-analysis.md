# Linux Kernel io_uring 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`io_uring/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 io_uring？

**io_uring**（Linux 5.1）是 Linux 最新的**异步 I/O 框架**，相比 epoll + O_NONBLOCK，提供了真正的零拷贝、批量提交、Kernel-Bypass 能力。

**核心优势**：
- **提交/完成队列**（SQ/CQ）共享内存，应用和内核共享数据，零 syscall
- **批量化**提交多个 I/O 请求
- **内核轮询模式**：无需系统调用，应用直接提交 I/O

---

## 1. 核心结构

```c
// io_uring/io_uring.c — io_ring_ctx
struct io_ring_ctx {
    // 提交队列
    struct io_rings          *rings;         // 共享内存区域
    struct io_sq_entry       *sq_sqes;      // SQ 条目数组

    // 完成队列
    struct io_uring_cqe      *cq_cqes;       // CQ 条目数组

    // 文件描述符
    struct file              *file;

    // 注册的缓冲区
    struct io_buffer_list    *cq_buf_list;

    // 注册的文件
    struct xarray             file_xa;        // 注册的文件 fd
};

// io_uring_cqe — 完成队列条目
struct io_uring_cqe {
    __u64 user_data;      // 提交时设置，用于匹配请求
    __s32 res;            // 系统调用返回值（read 返回字节数等）
    __u32 flags;
};

// io_uring_sqe — 提交队列条目
struct io_uring_sqe {
    __u8  opcode;         // IORING_OP_READ / WRITE / OPENAT / ...
    __u8  flags;
    __u16  ioprio;
    __s32  fd;
    __u64  off;           // 文件偏移
    __u64  addr;          // 用户缓冲地址
    __u32  len;           // 缓冲长度
    union { __u32 rw_flags; ... };
    __u64  user_data;     // 用于匹配 CQ 条目
};
```

---

## 2. 提交 I/O：io_uring_enter

```c
// io_uring/io_uring.c — io_uring_enter
SYSCALL_DEFINE6(io_uring_enter, unsigned int, fd,
        unsigned int, to_submit, unsigned int, min_complete,
        unsigned int, flags, sigset_t __user *, sig, size_t)
{
    struct io_ring_ctx *ctx;
    struct file *file;

    // 1. 获取 io_ring_ctx
    ctx = io_uring_get_ctx_fd(fd);

    // 2. 提交 SQ 中的请求
    if (to_submit)
        io_submit_sqes(ctx, to_submit);

    // 3. 如果需要等待完成，阻塞直到 min_complete 个 CQ 条目
    if (min_complete)
        io_wait_cqes(ctx, min_complete);

    // 4. 返回已完成的条目数
    return io_uring_get_cqe(ctx, NULL, min_complete, NULL);
}
```

---

## 3. 轮询模式（Kernel-Bypass）

```c
// 用户空间代码示例（零 syscall）
// 1. mmap 映射 SQ 和 CQ 共享内存
// 2. 直接写入 SQE
// 3. 调用 io_uring_enter(2) 只用于提交（flags = IORING_ENTER_SQ_WAIT）

// 或者完全零 syscall：
// 1. 设置 IORING_SETUP_SQPOLL
// 2. 内核线程轮询 SQ
// 3. 应用只需写入 SQ，然后读取 CQ
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `io_uring/io_uring.c` | `io_ring_ctx`、`io_uring_enter`、`io_submit_sqes` |
| `io_uring/rw.c` | `io_read`、`io_write` |
| `include/uapi/linux/io_uring.h` | `struct io_uring_sqe`、`io_uring_opcode` |
