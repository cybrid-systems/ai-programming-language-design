# Linux Kernel io_uring 深度源码分析（doom-lsp 全面解析）

> 基于 Linux 7.0-rc1 主线源码（`io_uring/io_uring.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：SQ/CQ 环、sqe/cqe、submit/ complete、SQPOLL、Registered Ring、Fixed Buffer

## 0. io_uring 概述

**io_uring** 是 Linux 5.1+ 引入的高性能异步 I/O 框架，核心设计：
- **共享内存**：SQ/CQ 环形缓冲区在用户和内核之间共享，零 syscall 提交
- **SQPOLL 模式**：内核线程轮询 SQ，消除用户到内核的 syscall 开销
- **Registered Ring**：注册环形缓冲区，进一步减少开销

### 与 epoll + read/write 对比

```
传统（epoll + read/write）：
  read() → copy_to_user() → syscall → 返回
  write() → copy_from_user() → syscall → 返回
  每操作 = 至少 1 次 syscall

io_uring：
  SQE 写入共享内存（无 syscall）→ 内核处理 → CQE 写入共享内存
  每操作 = 0 次 syscall（SQPOLL 模式）
```

## 1. 核心数据结构

### 1.1 io_uring_sqe — 提交队列条目

```c
// include/uapi/linux/io_uring.h — struct io_uring_sqe
struct io_uring_sqe {
    // 操作码
    __u8          opcode;         // IORING_OP_READ / WRITE / POLL_ADD ...

    // 标志
    __u8          flags;         // IOSQE_FIXED_FILE / IOSQE_ASYNC ...

    // FD（文件描述符）
    __u16         fd;            // 文件/ socket FD

    // 用户数据（透传到 CQE）
    __u64         user_data;      // 用户自定义， CQE 会返回

    // 操作特定数据
    union {
        __u64     off;           // 偏移（read/write/lseek）
        __u64     addr2;         // 第二个地址（splice）
        __u64     reserved;      // 保留
        struct {
            __u32 cmd_ops;      // 内部命令
            __u32 cmd;          // op 文件命令
        };
    };

    // 主地址（用户缓冲区或 iovec 指针）
    __u64         __addr;         // 用户空间地址

    // 缓冲区长度
    __u32         len;            // 缓冲区长度 / iovec 数量

    // 读/写操作的原命令（来自原始 FD）
    union {
        __u32     rw_flags;      // read/write 标志
        __u32     fsync_flags;   // fsync 标志
        __u32     poll_events;   // poll 事件
        __u32     sync_range_flags;
        __u32     msg_flags;
        __u32     timeout_flags;
    };

    // 用户定义的优先级
    __u64         user_data;

    // 缓冲区索引（Fixed Buffer 模式）
    __u16         buf_index;      // IORING_OP_READ_FIXED 时使用

    // 保留
    __u64         __pad2[2];
};
```

### 1.2 io_uring_cqe — 完成队列条目

```c
// include/uapi/linux/io_uring.h — struct io_uring_cqe
struct io_uring_cqe {
    // 用户数据（来自 SQE 的 user_data）
    __u64         user_data;      // 原样返回

    // 操作结果（>= 0 = 成功，< 0 = 错误码）
    __s32         res;            // 返回值

    // 标志
    __u32         flags;          // IORING_CQE_F_BUFFER / _MORE ...
};
```

### 1.3 io_ring_ctx — io_uring 实例上下文

```c
// io_uring/io_uring.c:225 — io_ring_ctx_alloc
struct io_ring_ctx {
    // 提交队列
    struct io_rsrc_update       *sq_sqes;  // SQE 数组
    unsigned int                sq_entries;  // SQ 深度
    unsigned int                sq_mask;     // 掩码（entries - 1）
    unsigned int                sq_thread_cpu; // SQPOLL CPU
    unsigned int                sq_thread_idle; // 空闲超时

    // 提交队列缓冲（mmap 区域）
    void                       *sq_array;   // 指向 mmap 的 SQ 区域
    unsigned int                cached_sq_head; // 缓存的 head

    // 完成队列
    struct io_cqe             *cqes;       // CQE 数组
    unsigned int                cq_entries;  // CQ 深度
    unsigned int                cq_mask;     // 掩码

    // 锁
    spinlock_t                  submit_lock; // 提交锁
    spinlock_t                  completion_lock; // 完成锁

    // 等待队列
    wait_queue_head_t           cq_wait;    // 等待完成的队列

    // 溢出队列
    struct list_head           cq_overflow; // 溢出 CQE 链表

    // 引用计数
    refcount_t                  refs;       // 引用计数

    // 文件数组（Registered Files）
    struct file               **file_array; // Fixed File 数组

    // 缓冲区数组（Registered Buffers）
    struct io_buffer_list     *io_buffer_list; // Fixed Buffer 链表

    // SQPOLL 线程
    struct task_struct         *sqo_task;   // SQPOLL 任务
    struct mm_struct          *mm_account; // 内存统计

    // 限制
    unsigned int                restricted;  // 限制模式

    // 标志
    unsigned long               flags;      // IORING_SETUP_* 标志
    unsigned int                int_flags;   // 内部标志

    // 资源
    struct io_alloc_cache      apoll_cache; // 异步 poll 缓存
    struct io_alloc_cache      netmsg_cache; // 网络消息缓存
    struct io_alloc_cache      rw_cache;    // read/write 缓存

    // 缓陷
    struct io_submit_state      submit_state; // 提交状态
};
```

## 2. io_uring_setup — 创建 io_uring 实例

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

    // 2. 创建匿名 inode（/dev/null 类似）
    //    并关联 io_ring_ctx
    fd = get_unused_fd_flags(O_RDWR | O_CLOEXEC);
    file = anon_inode_getfile("io_uring", &io_uring_fops, ctx,
                   O_RDWR | O_CLOEXEC);
    fd_install(fd, file);

    // 3. mmap SQ 和 CQ 区域到用户空间
    //    用户通过 mmap 获取共享内存的地址
    //    sq_array = mmap(fd, IORING_OFF_SQ_ARRAY)
    //    cqes = mmap(fd, IORING_OFF_CQES)

    return fd;
}
```

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
    if (min_complete > 0) {
        // 等待直到 CQ 中至少有 min_complete 个 CQE
        io_cqring_wait(ctx, min_complete, ...);
    }

    // 4. 返回已完成的 CQE 数量
    return submitted;
}
```

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
        io_read(req);
        break;
    case IORING_OP_WRITE:
        io_write(req);
        break;
    case IORING_OP_POLL_ADD:
        io_poll_add(req);
        break;
    case IORING_OP_RECVMSG:
        io_recvmsg(req);
        break;
    case IORING_OP_SENDMSG:
        io_sendmsg(req);
        break;
    ...
    }

    return 0;
}
```

## 5. SQPOLL 模式 — 零 syscall 提交

```c
// io_uring/io_uring.c — io_sq_thread
static int io_sq_thread(void *data)
{
    struct io_ring_ctx *ctx = data;

    // 设置为内核线程，不与用户共享
    while (!kthread_should_stop()) {
        // 1. 如果 SQ 中有 SQE，处理它们
        if (sq_ring_head != sq_tail) {
            // 取出 SQE，提交到内核
            io_submit_sqes(ctx);
        }

        // 2. 如果没有 SQE，poll 等待
        if (schedule_timeout_interruptible(ctx->sq_thread_idle))
            continue;
    }

    return 0;
}
```

## 6. Registered Ring — 减少开销

```c
// 注册 SQ 环：
// io_uring_register(fd, IORING_REGISTER_RING_FDS, ...)

// 优势：
// - 无需每次 sys_enter 从用户指针读取
// - 内核直接使用已映射的内核指针
// - 减少 TLB miss
```

## 7. Fixed Buffer — 零拷贝读/写

```c
// 注册缓冲区：
// struct iovec iov = { .iov_base = buf, .iov_len = size };
// io_uring_register(fd, IORING_REGISTER_BUFFERS, &iov, 1);

// 使用固定缓冲区：
// SQE.opcode = IORING_OP_READ_FIXED
// SQE.fd = fd
// SQE.addr = 0          // buffer_index 对应的偏移
// SQE.buf_index = 0     // 注册缓冲区的索引

// 内核直接使用已映射的缓冲区，无需 copy_from_user
```

## 8. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| 共享内存环形缓冲 | 零 syscall 提交/完成 |
| sqe/cqe 分离 | 提交和完成解耦，可并行 |
| user_data 透传 | 应用可关联请求和结果 |
| sqe->buf_index | Fixed Buffer 避免每次传地址 |
| refcount 管理 | 防止文件关闭时释放正在使用的 ring |
| overflow 链表 | CQ 满时暂存，不丢失事件 |

## 9. 参考

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


---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `include/linux/list.h` | 51 | 0 | 51 | 0 |
| `include/linux/sched.h` | 567 | 70 | 134 | 7 |
| `include/linux/mm.h` | 793 | 24 | 527 | 18 |

### 核心数据结构

- **audit_context** `sched.h:58`
- **bio_list** `sched.h:59`
- **blk_plug** `sched.h:60`
- **bpf_local_storage** `sched.h:61`
- **bpf_run_ctx** `sched.h:62`
- **bpf_net_context** `sched.h:63`
- **capture_control** `sched.h:64`
- **cfs_rq** `sched.h:65`
- **fs_struct** `sched.h:66`
- **futex_pi_state** `sched.h:67`
- **io_context** `sched.h:68`
- **io_uring_task** `sched.h:69`
- **mempolicy** `sched.h:70`
- **nameidata** `sched.h:71`
- **nsproxy** `sched.h:72`
- **perf_event_context** `sched.h:73`
- **perf_ctx_data** `sched.h:74`
- **pid_namespace** `sched.h:75`
- **pipe_inode_info** `sched.h:76`
- **rcu_node** `sched.h:77`
- **reclaim_state** `sched.h:78`
- **robust_list_head** `sched.h:79`
- **root_domain** `sched.h:80`
- **rq** `sched.h:81`
- **sched_attr** `sched.h:82`

### 关键函数

- **INIT_LIST_HEAD** `list.h:43`
- **__list_add_valid** `list.h:136`
- **__list_del_entry_valid** `list.h:142`
- **__list_add** `list.h:154`
- **list_add** `list.h:175`
- **list_add_tail** `list.h:189`
- **__list_del** `list.h:201`
- **__list_del_clearprev** `list.h:215`
- **__list_del_entry** `list.h:221`
- **list_del** `list.h:235`
- **list_replace** `list.h:249`
- **list_replace_init** `list.h:265`
- **list_swap** `list.h:277`
- **list_del_init** `list.h:293`
- **list_move** `list.h:304`
- **list_move_tail** `list.h:315`
- **list_bulk_move_tail** `list.h:331`
- **list_is_first** `list.h:350`
- **list_is_last** `list.h:360`
- **list_is_head** `list.h:370`
- **list_empty** `list.h:379`
- **list_del_init_careful** `list.h:395`
- **list_empty_careful** `list.h:415`
- **list_rotate_left** `list.h:425`
- **list_rotate_to_front** `list.h:442`
- **list_is_singular** `list.h:457`
- **__list_cut_position** `list.h:462`
- **list_cut_position** `list.h:488`
- **list_cut_before** `list.h:515`
- **__list_splice** `list.h:531`
- **list_splice** `list.h:550`
- **list_splice_tail** `list.h:562`
- **list_splice_init** `list.h:576`
- **list_splice_tail_init** `list.h:593`
- **list_count_nodes** `list.h:755`

### 全局变量

- **__tracepoint_sched_set_state_tp** `sched.h:350`
- **__tracepoint_sched_set_need_resched_tp** `sched.h:352`
- **def_root_domain** `sched.h:407`
- **sched_domains_mutex** `sched.h:408`
- **cad_pid** `sched.h:1749`
- **init_stack** `sched.h:1964`
- **class_migrate_is_conditional** `sched.h:2519`
- **_totalram_pages** `mm.h:53`
- **high_memory** `mm.h:74`
- **sysctl_legacy_va_layout** `mm.h:86`
- **mmap_rnd_bits_min** `mm.h:92`
- **mmap_rnd_bits_max** `mm.h:93`
- **mmap_rnd_bits** `mm.h:94`
- **sysctl_user_reserve_kbytes** `mm.h:210`
- **sysctl_admin_reserve_kbytes** `mm.h:211`

### 成员/枚举

- **utime** `sched.h:366`
- **stime** `sched.h:367`
- **lock** `sched.h:368`
- **seqcount** `sched.h:386`
- **starttime** `sched.h:387`
- **state** `sched.h:388`
- **cpu** `sched.h:389`
- **utime** `sched.h:390`
- **stime** `sched.h:391`
- **gtime** `sched.h:392`
- **sched_priority** `sched.h:413`
- **pcount** `sched.h:421`
- **run_delay** `sched.h:424`
- **max_run_delay** `sched.h:427`
- **min_run_delay** `sched.h:430`
- **last_arrival** `sched.h:435`
- **last_queued** `sched.h:438`
- **max_run_delay_ts** `sched.h:441`
- **weight** `sched.h:461`
- **inv_weight** `sched.h:462`

