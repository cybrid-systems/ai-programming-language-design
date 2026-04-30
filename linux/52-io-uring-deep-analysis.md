# io_uring — 高性能异步 I/O 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`io_uring/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**io_uring** 是 Linux 5.1 引入的高性能异步 I/O 接口，通过共享内存的环形队列实现真正的异步 I/O，被认为是 Linux 最重要的性能改进之一。

---

## 1. 核心数据结构

### 1.1 io_ring_ctx — 环形上下文

```c
// io_uring/io_uring.c — io_ring_ctx
struct io_ring_ctx {
    // 提交队列（Submission Queue）
    struct io_submit_sq      sq;
    struct io_sqe_uring_cmd __user *sq_sqes; // SQ 数组

    // 完成队列（Completion Queue）
    struct io_cq             cq;

    // 注册资源
    struct io_fixed_file      *file_table;   // 注册文件表
    struct io_mapped_buf     *buffer_table;  // 注册缓冲区表

    // SQPOLL 线程
    struct task_struct        *sqo_task;     // SQPOLL 内核线程
    wait_queue_head_t         sq_wait;

    // 配置
    unsigned int              flags;          // IORING_SETUP_* 标志
};
```

### 1.2 io_uring_sqe — 提交队列项

```c
// include/uapi/linux/io_uring.h — io_uring_sqe
struct io_uring_sqe {
    __u8    opcode;         // IORING_OP_*
    __u8    flags;          // SQE 标志（SQE_FL_*）
    __u16   ioprio;         // I/O 优先级
    __s32   fd;             // 文件描述符

    // 数据缓冲区
    __u64   off;            // 偏移（用于文件 I/O）
    __u64   addr;           // 用户缓冲区地址
    __u32   len;            // 缓冲区长度

    // 操作特定数据
    union {
        __u32   rw_flags;   // read/write 标志
        __u32   fsync_flags;
        __u64   off2;
        __u64   addr2;
    };

    union {
        __u32   user_data;  // 关联完成事件
        __u64   user_data64;
    };

    // 缓冲区
    __u16   buf_index;       // 注册缓冲区索引（IORING_OP_READ_FIXED）

    // 辅助数据
    __u64   __pad2[3];     // 填充
};

// 操作码：
#define IORING_OP_NOP           0
#define IORING_OP_READV         1
#define IORING_OP_WRITEV        2
#define IORING_OP_FSYNC         3
#define IORING_OP_READ_FIXED    4
#define IORING_OP_WRITE_FIXED   5
#define IORING_OP_POLL_ADD      6
#define IORING_OP_POLL_REMOVE   7
#define IORING_OP_SYNC_FILE_RANGE 8
#define IORING_OP_SENDMSG       9
#define IORING_OP_RECVMSG       10
#define IORING_OP_TIMEOUT        11
#define IORING_OP_TIMEOUT_REMOVE 12
#define IORING_OP_ACCEPT        13
#define IORING_OP_CONNECT        14
#define IORING_OP_FALLOCATE      15
#define IORING_OP_OPENAT         16
#define IORING_OP_CLOSE          17
#define IORING_OP_FILES_UPDATE   18
#define IORING_OP_STATX         19
#define IORING_OP_READ           20
#define IORING_OP_WRITE         21
#define IORING_OP_SEND          22
#define IORING_OP_RECV          23
#define IORING_OP_OPENAT2        24
#define IORING_OP_EPOLLCtl       25
```

### 1.3 io_uring_cqe — 完成队列项

```c
// include/uapi/linux/io_uring.h — io_uring_cqe
struct io_uring_cqe {
    __u64   user_data;      // SQE 中设置的 user_data
    __s32   res;            // 结果（类似系统调用返回值，负数 = -errno）
    __u32   flags;          // CQE 标志
};
```

---

## 2. 系统调用

### 2.1 io_uring_setup — 创建 ring

```c
// io_uring/io_uring.c — sys_io_uring_setup
SYSCALL_DEFINE2(io_uring_setup, unsigned int, entries, struct io_uring_params __user *, params)
{
    struct io_ring_ctx *ctx;
    struct file *file;
    struct mm_struct *mm = current->mm;

    // 1. 验证 entries
    entries = roundup_pow_of_two(entries);
    if (entries > IORING_MAX_entries)
        return -EINVAL;

    // 2. 分配 io_ring_ctx
    ctx = kmalloc(sizeof(*ctx), GFP_KERNEL);
    if (!ctx)
        return -ENOMEM;

    // 3. 设置 sq/cq 环形缓冲区
    ctx->sqsqes = mmap(NULL, entries * sizeof(struct io_uring_sqe),
                       PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                       params->sq_off.tfiles_array, 0);

    // 4. mmap CQ
    ctx->cqcqes = mmap(NULL, ...);

    // 5. 创建 io_uring 文件
    file = anon_inode_getfile("[io_uring]", &io_uring_fops, ctx, O_RDWR);

    return file->fd;
}
```

### 2.2 io_uring_enter — 提交/等待

```c
// io_uring/io_uring.c — sys_io_uring_enter
SYSCALL_DEFINE6(io_uring_enter, unsigned int, fd, unsigned int, to_submit,
                unsigned int, min_complete, unsigned int, flags,
                const void __user *, argp, size_t, argsz)
{
    struct io_ring_ctx *ctx;
    struct file *file;

    // 1. 获取 ctx
    file = fget(fd);
    ctx = file->private_data;

    // 2. 提交 SQEs
    if (to_submit)
        ret = io_submit_sqes(ctx, to_submit);

    // 3. 等待完成（CQ 有 min_complete 个条目后返回）
    if (flags & IORING_ENTER_GETEVENTS) {
        ret = io_cqring_wait(ctx, min_complete, ...);
    }

    return ret;
}
```

---

## 3. 高级特性

### 3.1 SQPOLL（内核轮询）

```c
// 设置 IORING_SETUP_SQ_POLL 标志：
// 内核在后台创建线程，持续轮询 SQ
// 应用只需填充 SQEs，无需每次调用 io_uring_enter

struct io_uring_params params = {
    .flags = IORING_SETUP_SQ_POLL,
    .sq_thread_idle = 2000,  // 空闲超时（毫秒）
};
```

### 3.2 Registered Files（注册文件）

```c
// io_uring_register(fd, IORING_REGISTER_FILES, fds, nfds);
// 预先注册文件描述符

// 使用注册的文件（避免每次传递 fd）：
sqe->opcode = IORING_OP_READ;
sqe->fd = registered_fd_index;  // 表的索引，而不是真实 fd
sqe->addr = buf;
sqe->len = size;
sqe->flags = IOSQE_FIXED_FILE;
```

### 3.3 Registered Buffers（注册缓冲区）

```c
// 注册用户缓冲区：
struct iovec iov[10];
io_uring_register(fd, IORING_REGISTER_BUFFERS, iov, 10);

// 使用注册缓冲区：
sqe->opcode = IORING_OP_READ_FIXED;
sqe->addr = buffer_id;  // 已注册缓冲区的 ID
sqe->len = buffer_size;
sqe->buf_index = buffer_id;
```

---

## 4. 设计优势

```
epoll：                        io_uring：
while (1) {                   // 应用侧：
  epoll_wait()                 while (have_requests) {
  → 阻塞（syscall）              fill_sqe(read_req)
  处理请求                      fill_sqe(write_req)
  async_op()                   // 内核侧（SQPOLL）：
  wait_completion()             kernel_poll_thread():
  → 阻塞（syscall）               poll_sq()
}                                process_sqe()
                                  async_op()
io_uring（SQPOLL）：              fill_cqe()
// 零 syscall 提交              }
// 只有等待完成时 syscall
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `io_uring/io_uring.c` | `io_ring_ctx`、`sys_io_uring_setup`、`sys_io_uring_enter` |
| `io_uring/rw.c` | `io_read`、`io_write`、`IORING_OP_READ_FIXED` |
| `io_uring/sqpoll.c` | `io_sqpoll_thread`（SQPOLL 内核线程）|
| `include/uapi/linux/io_uring.h` | `io_uring_sqe`、`io_uring_cqe` |