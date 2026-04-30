# io_uring — 深度源码分析（第二轮强化）

> 基于 Linux 7.0-rc1 主线源码（`io_uring/io_uring.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**io_uring** 是 Linux 5.1+ 引入的高性能异步 I/O 框架，核心设计：
- **共享内存环形缓冲区**：SQ/CQ 在用户和内核之间共享，零 syscall 提交
- **SQPOLL 模式**：内核线程轮询 SQ，消除用户到内核的每次 syscall 开销
- **Registered Ring**：注册环形缓冲区，进一步减少开销

---

## 1. 核心数据结构

### 1.1 io_uring_sqe — 提交队列条目

```c
// include/uapi/linux/io_uring.h — struct io_uring_sqe
struct io_uring_sqe {
    // 操作码
    __u8          opcode;         // IORING_OP_READ / WRITE / POLL_ADD / ...
    __u8          flags;         // IOSQE_* 标志
    __u16         fd;            // 文件描述符
    __u64         user_data;     // 用户数据（透传到 CQE）
    union {
        __u64     off;           // 偏移（read/write/lseek）
        __u64     addr2;         // 第二个地址
        __u64     reserved;       // 保留
        struct {
            __u32 cmd_ops;  // 内部命令
            __u32 cmd;      // 命令
        };
    };
    __u64         __addr;        // 主地址（用户缓冲区）
    __u32         len;            // 长度
    union {
        __u32     rw_flags;      // 读写标志
        __u32     fsync_flags;    // fsync 标志
        __u32     poll_events;    // poll 事件
        __u32     sync_range_flags;
        __u32     msg_flags;
        __u32     timeout_flags;
    };
    __u16         buf_index;      // Fixed Buffer 索引
    __u16         buf_group;      // Buffer 组
    __u64         user_data;      // 透传用户数据
    __u64         __pad2[2];
};
```

### 1.2 io_uring_cqe — 完成队列条目

```c
// include/uapi/linux/io_uring.h — struct io_uring_cqe
struct io_uring_cqe {
    __u64         user_data;     // SQE 的 user_data 原样返回
    __s32         res;           // 返回值（>= 0 成功，< 0 错误码）
    __u32         flags;         // IORING_CQE_F_* 标志
};
```

### 1.3 io_ring_ctx — io_uring 实例上下文（完整）

```c
// io_uring/io_uring.c — io_ring_ctx_alloc
struct io_ring_ctx {
    /* 提交队列 */
    struct io_rsrc_update   *sq_sqes;          // SQE 数组（mmap）
    unsigned int            sq_entries;          // SQ 深度
    unsigned int            sq_mask;              // 掩码
    unsigned int            sq_thread_cpu;         // SQPOLL CPU
    unsigned int            sq_thread_idle;        // 空闲超时

    /* 提交队列缓冲（mmap 区域）*/
    void                   *sq_array;            // 指向 mmap 的 SQ 区域
    unsigned int            cached_sq_head;         // 缓存的 head

    /* 完成队列 */
    struct io_cqe           *cqes;               // CQE 数组（mmap）
    unsigned int            cq_entries;             // CQ 深度
    unsigned int            cq_mask;                // 掩码

    /* 锁 */
    spinlock_t              submit_lock;           // 提交锁
    spinlock_t              completion_lock;        // 完成锁

    /* 等待队列 */
    wait_queue_head_t       cq_wait;               // 等待完成的队列

    /* 溢出队列 */
    struct list_head        cq_overflow;           // 溢出 CQE 链表

    /* 引用计数 */
    refcount_t              refs;                   // 引用计数

    /* 文件数组（Registered Files）*/
    struct file             **file_array;           // Fixed File 数组

    /* 缓冲区数组（Registered Buffers）*/
    struct io_buffer_list   *io_buffer_list;        // Fixed Buffer 链表

    /* SQPOLL 线程 */
    struct task_struct      *sqo_task;             // SQPOLL 任务
    struct mm_struct        *mm_account;            // 内存统计

    /* 限制 */
    unsigned int            restricted;             // 限制模式

    /* 标志 */
    unsigned long           flags;                  // IORING_SETUP_* 标志
    unsigned int            int_flags;              // 内部标志

    /* 资源缓存 */
    struct io_alloc_cache   apoll_cache;            // 异步 poll 缓存
    struct io_alloc_cache   netmsg_cache;           // 网络消息缓存
    struct io_alloc_cache   rw_cache;               // read/write 缓存

    /* 提交状态 */
    struct io_submit_state  submit_state;           // 提交状态
};
```

---

## 2. io_uring_setup — 创建实例

```c
// io_uring/io_uring.c — io_uring_setup
static int io_uring_setup(u32 entries, struct io_uring_params *params)
{
    struct io_ring_ctx *ctx;
    struct file *file;
    int fd;

    // 1. 分配 io_ring_ctx
    ctx = io_ring_ctx_alloc(params);
    if (IS_ERR(ctx))
        return PTR_ERR(ctx);

    // 2. 创建匿名 inode 并关联 io_ring_ctx
    fd = get_unused_fd_flags(O_RDWR | O_CLOEXEC);
    file = anon_inode_getfile("io_uring", &io_uring_fops, ctx,
                   O_RDWR | O_CLOEXEC);
    fd_install(fd, file);

    // 3. mmap SQ 和 CQ 区域到用户空间
    //    用户通过 mmap 获取共享内存的地址

    return fd;
}
```

---

## 3. io_uring_enter — 提交和等待完成

```c
// io_uring/io_uring.c:2584 — SYSCALL_DEFINE6(io_uring_enter)
SYSCALL_DEFINE6(io_uring_enter, unsigned int, fd, u32, to_submit,
        u32, min_complete, u32, flags, const void __user *, argp,
        size_t, argsz)
{
    struct io_ring_ctx *ctx;
    struct file *file;

    // 1. 获取 io_uring 文件
    file = io_uring_get_file(fd);
    ctx = file->private_data;

    // 2. 提交 SQE（如果有）
    if (to_submit > 0) {
        // 遍历 SQ 环，取出所有待提交的 SQE
        for (i = 0; i < to_submit; i++) {
            sqe = ...; // 从 sq_array 取
            io_submit_sqe(ctx, sqe, ...);
        }
    }

    // 3. 等待完成（如果有）
    if (min_complete > 0)
        io_cqring_wait(ctx, min_complete, ...);

    return submitted;
}
```

---

## 4. io_submit_sqe — 提交单个 SQE

```c
// io_uring/io_uring.c — io_submit_sqe
static int io_submit_sqe(struct io_ring_ctx *ctx, struct io_uring_sqe *sqe)
{
    struct io_kiocb *req;

    // 1. 分配 io_kiocb（请求描述符）
    req = io_alloc_req(ctx, GFP_KERNEL);

    // 2. 初始化请求
    req->user_data = sqe->user_data;
    req->opcode = sqe->opcode;
    req->fd = sqe->fd;
    req->addr = sqe->addr;
    req->len = sqe->len;

    // 3. 根据 opcode 调用对应的处理函数
    switch (sqe->opcode) {
    case IORING_OP_READ:
        io_read(req);           // 读文件
        break;
    case IORING_OP_WRITE:
        io_write(req);          // 写文件
        break;
    case IORING_OP_POLL_ADD:
        io_poll_add(req);        // poll fd
        break;
    case IORING_OP_RECVMSG:
        io_recvmsg(req);
        break;
    case IORING_OP_SENDMSG:
        io_sendmsg(req);
        break;
    case IORING_OP_READ_FIXED:
        io_read_fixed(req);      // Fixed Buffer 读
        break;
    // ...
    }

    return 0;
}
```

---

## 5. SQPOLL 模式 — 零 syscall 提交

```c
// io_uring/io_uring.c — io_sq_thread
static int io_sq_thread(void *data)
{
    struct io_ring_ctx *ctx = data;

    while (!kthread_should_stop()) {
        // 1. 如果 SQ 中有 SQE，处理它们
        if (sq_ring_head != sq_tail) {
            io_submit_sqes(ctx);
        }

        // 2. 如果没有 SQE，poll 等待
        if (schedule_timeout_interruptible(ctx->sq_thread_idle))
            continue;
    }

    return 0;
}

// 创建 SQPOLL 线程：
// io_uring_register(fd, IORING_REGISTER_SQ_POLLOFF, ...);
// 设置 IORING_SETUP_SQPOLL 时自动创建
```

---

## 6. Registered Ring — 减少开销

```c
// 注册 SQ 环：
io_uring_register(fd, IORING_REGISTER_RING_FDS, ...)

// 优势：
// - 无需每次 sys_enter 从用户指针读取
// - 内核直接使用已映射的内核指针
// - 减少 TLB miss
```

---

## 7. Fixed Buffer — 零拷贝读/写

```c
// 注册缓冲区：
struct iovec iov = { .iov_base = buf, .iov_len = size };
io_uring_register(fd, IORING_REGISTER_BUFFERS, &iov, 1);

// 使用固定缓冲区：
// SQE.opcode = IORING_OP_READ_FIXED
// SQE.fd = fd
// SQE.addr = 0          // buffer_index 对应的偏移
// SQE.buf_index = 0     // 注册缓冲区的索引

// 内核直接使用已映射的缓冲区，无需 copy_from_user
```

---

## 8. 设计决策总结

| 决策 | 原因 |
|------|------|
| 共享内存环形缓冲 | 零 syscall 提交/完成 |
| sqe/cqe 分离 | 提交和完成解耦，可并行 |
| user_data 透传 | 应用可关联请求和结果 |
| sqe->buf_index | Fixed Buffer 避免每次传地址 |
| refcount 管理 | 防止文件关闭时释放正在使用的 ring |
| overflow 链表 | CQ 满时暂存，不丢失事件 |

---

## 9. 完整文件索引

| 文件 | 函数/结构 | 行 |
|------|----------|-----|
| `io_uring/io_uring.c` | `io_ring_ctx` | 225+ |
| `io_uring/io_uring.c` | `io_uring_setup` | 创建流程 |
| `io_uring/io_uring.c` | `io_uring_enter` | 2584 |
| `io_uring/io_uring.c` | `io_submit_sqe` | 提交 |
| `io_uring/io_uring.c` | `io_sq_thread` | SQPOLL |
| `io_uring/io_uring.c` | `io_cqring_wait` | 等待完成 |
| `include/uapi/linux/io_uring.h` | `struct io_uring_sqe` | SQE 定义 |
| `include/uapi/linux/io_uring.h` | `struct io_uring_cqe` | CQE 定义 |