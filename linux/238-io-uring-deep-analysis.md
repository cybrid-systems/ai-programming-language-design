# io_uring 异步 I/O 机制深度分析

> 内核源码：Linux 7.0-rc1（commit 7a1699fe6c）
> 基于 `/home/dev/code/linux` 和 `/home/dev/code/ai-programming-language-design`

## 1. 概述

io_uring 是 Linux 5.1 引入的异步 I/O 接口，被设计为 epoll 的下一代替代方案。与 epoll 仅封装事件通知不同，io_uring 从根本上重新设计了 I/O 数据路径：**通过共享内存的环形队列（Ring Buffer）在用户态与内核态之间零拷贝传递 I/O 操作请求与结果**。

### 核心设计目标

- **零拷贝**：SQE（Submission Queue Entry）和 CQE（Completion Queue Entry）通过 mmap 共享内存，用户态直接填充 SQE，内核直接写入 CQE，无需系统调用数据拷贝
- **批量提交**：一次 `io_uring_enter()` 可提交多个 SQE 并等待多个 CQE，大幅降低 syscall 开销
- **统一接口**：文件 I/O、网络 I/O、计时器、同步原语全部通过 SQE 表达

## 2. SQ/CQ 环形缓冲区

### 2.1 内存布局（io_uring_setup → mmap）

```
用户进程虚拟地址空间
┌─────────────────────────────────────────┐
│  fd = io_uring_setup(entries, &params)  │
└──────────────┬──────────────────────────┘
               │  anon_inode_getfile()
               ▼
  ┌────────────────────────────────────┐
  │  struct file (anon_inode)          │
  │  file->private_data = ctx         │
  └──────────┬───────────────────────┘
              │  mmap(fd, ...)
              ▼
  ┌─────────────────────────────────────┐
  │  IORING_OFF_SQ_RING (0x0)           │  ← CQ ring 头信息 (struct io_uring head/tail, mask, entries, flags...)
  │  size = cq_off.user_addr - 0x0      │
  ├─────────────────────────────────────┤
  │  IORING_OFF_CQ_RING (0x8000000)     │  ← CQEs (struct io_uring_cqe[])
  │  size = ...                          │
  ├─────────────────────────────────────┤
  │  IORING_OFF_SQES (0x10000000)       │  ← SQE 数组 (struct io_uring_sqe[])
  │  size = sq_entries * 64             │
  └─────────────────────────────────────┘
```

关键偏移量（uapi/linux/io_uring.h）：
```c
#define IORING_OFF_SQ_RING       0ULL       // SQ ring head/tail/mask/entries/flags
#define IORING_OFF_CQ_RING       0x8000000ULL // CQ ring head/tail/mask/entries + CQEs[]
#define IORING_OFF_SQES          0x10000000ULL // struct io_uring_sqe[]
```

### 2.2 struct io_uring_sqe（64 字节）

```c
// include/uapi/linux/io_uring.h
struct io_uring_sqe {
    __u8    opcode;         //  0: IORING_OP_READ, IORING_OP_WRITE, ...
    __u8    flags;         //  1: IOSQE_FIXED_FILE, IOSQE_IO_DRAIN, IOSQE_IO_LINK, ...
    __u16   ioprio;        //  2: I/O priority
    __s32   fd;             //  4: 文件描述符（或固定文件表索引）
    union {
        __u64 off;         //  8: 文件偏移 或 addr2
        __u64 addr2;
    };
    union {
        __u64 addr;        // 16: 用户缓冲区地址（或 iovecs 指针）
        __u64 splice_off_in;
    };
    __u32   len;            // 24: 缓冲区长度或 iovec 数量
    union {                // 28: 操作特定标志
        __u32  rw_flags;   //   read/write flags (RWF_*)
        __u32  fsync_flags;
        __u16  poll_events;
        ...
    };
    __u64   user_data;     // 32: 用户自定义数据，会原样拷贝到 CQE
    union {                // 40: buf_index (固定缓冲区索引) 或 buf_group
        __u16 buf_index;
        __u16 buf_group;
    };
    __u16   personality;   // 42: 凭证（credentials）索引
    union {                // 44: splice_fd_in / file_index / optlen
        __s32  splice_fd_in;
        __u32  file_index;
    };
    union {                // 48: addr3 或 attr_ptr
        struct { __u64 addr3; __u64 __pad2[1]; };
        __u64  attr_ptr;
        __u64  attr_type_mask;
        __u8   cmd[0];     // SQE128 模式下的命令数据
    };
};
// 总计 64 字节（标准 SQE），128 字节（SQE128 模式）
```

### 2.3 struct io_uring_cqe（16 字节，标准模式）

```c
struct io_uring_cqe {
    __u64   user_data;     //  0: SQE 的 user_data 副本
    __s32   res;           //  8: 操作结果（read 返回字节数，负数为 -errno）
    __u32   flags;         // 12: IORING_CQE_F_BUFFER | upper16=buf_id, IORING_CQE_F_MORE, ...
    __u64   big_cqe[];     // 16+: CQE32 模式下额外 16 字节
};
// 总计 16 字节（标准），32 字节（CQE32 模式）
```

### 2.4 struct io_rings（共享内存头）

```c
// include/linux/io_uring_types.h
struct io_rings {
    struct io_uring   sq;         // offset 0:   head(u32) + tail(u32) — 内核写 head，用户写 tail
    struct io_uring   cq;         // offset 8:   head(u32) + tail(u32) — 内核写 tail，用户读 head
    u32   sq_ring_mask;           // offset 16:  sq_entries - 1（常数）
    u32   cq_ring_mask;           // offset 20:  cq_entries - 1（常数）
    u32   sq_ring_entries;        // offset 24:  SQ 容量（常数）
    u32   cq_ring_entries;        // offset 28:  CQ 容量（常数）
    u32   sq_dropped;             // offset 32:  无效 SQE 被丢弃数（内核写）
    atomic_t sq_flags;            // offset 36:  IORING_SQ_NEED_WAKEUP | IORING_SQ_CQ_OVERFLOW | IORING_SQ_TASKRUN
    u32   cq_flags;               // offset 40:  IORING_CQ_EVENTFD_DISABLED（用户写）
    u32   cq_overflow;            // offset 44:  CQ 溢出计数（内核写）
    struct io_uring_cqe cqes[];  // offset 48:  CQE 数组（cache-line aligned）
};
```

### 2.5 SQ Array（间接索引）

当 `IORING_SETUP_NO_SQARRAY` **未设置**时（默认），SQ 的索引数组（`sq_array`）**不在 io_rings 里**，而是存储在独立的 mmap 区域：

```
SQ Ring mmap 区域布局（IORING_OFF_SQES）：
┌──────────────────────────────────────────────────────┐
│  struct io_uring_sqe  sq_sqes[sq_entries]           │  ← 64B * sq_entries
│  (用户直接填充 SQE 内容)                              │
│  ── 紧接在 SQE 数组之后 ──                            │
│  u32 sq_array[sq_entries]   （由用户写入 SQE 索引）   │
└──────────────────────────────────────────────────────┘
         ↑                                          ↑
    用户写 sq_array[i] = sqe_index              用户读

用户态提交流程：
1. 填充 sq_sqes[sqe_index]
2. 写入 sq_array[sq_array_tail & mask] = sqe_index
3. 更新 sq.tail（volatile write + store_fence）
```

**注意**：内核**不修改** sq_array 和 sq_sqes，这是 io_uring "zero syscall data copy" 的关键——数据在 mmap 之前已经由用户态填充完毕，`io_uring_enter()` 只是通知内核"有新 SQE 请处理"。

## 3. Submission 路径

### 3.1 完整数据流图（ASCII）

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              用户态进程                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐  │
│  │ struct io_uring_sqe *sqes = mmap(IORING_OFF_SQES);                       │  │
│  │ struct io_rings *rings  = mmap(IORING_OFF_SQ_RING);                      │  │
│  │                                                                         │  │
│  │ // 1. 填充 SQE（零拷贝，无需 syscall）                                   │  │
│  │ sqes[sqe_idx].opcode  = IORING_OP_READ;                                 │  │
│  │ sqes[sqe_idx].fd      = fd;              // 或 IOSQE_FIXED_FILE + buf_idx│  │
│  │ sqes[sqe_idx].addr    = (u64)buf;                                        │  │
│  │ sqes[sqe_idx].len     = buflen;                                          │  │
│  │ sqes[sqe_idx].off     = file_offset;                                    │  │
│  │ sqes[sqe_idx].user_data = (u64)ctx;     // 关联上下文                    │  │
│  │ sqes[sqe_idx].flags   = IOSQE_FIXED_FILE | IOSQE_ASYNC;                 │  │
│  │                                                                         │  │
│  │ // 2. 写入 sq_array（间接索引）                                         │  │
│  │ rings->sq.array[sq_tail & mask] = sqe_idx;                              │  │
│  │                                                                         │  │
│  │ // 3. 更新 sq.tail（发布）                                               │  │
│  │ smp_store_release(&rings->sq.tail, sq_tail + 1);                        │  │
│  │                                                                         │  │
│  │ // 4. 调用 io_uring_enter()                                             │  │
│  │ syscall(SYS_io_uring_enter, fd, 1, 1,                                   │  │
│  │         IORING_ENTER_GETEVENTS, NULL, 0);                               │  │
│  └─────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────┬───────────────────────────────────────────────┘
                                 │  sys_io_uring_enter()
                                 ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                              内核态                                            │
│                                                                              │
│  SYSCALL io_uring_enter(fd, to_submit=1, min_complete=1, flags, argp, argsz) │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │ file = io_uring_ctx_get_file(fd);       // 获取 anon_inode file       │   │
│  │ ctx  = file->private_data;              // struct io_ring_ctx*        │   │
│  │                                                                   ↓   │
│  │ if (ctx->flags & IORING_SETUP_SQPOLL) {                         │     │   │
│  │     wake_up(&ctx->sq_data->wait);     // 唤醒 SQ poll 线程          │     │   │
│  │ } else {                                                          │     │   │
│  │     mutex_lock(&ctx->uring_lock);                                 │     │   │
│  │     ret = io_submit_sqes(ctx, to_submit);    ←──────────────────────┘  │
│  │     mutex_unlock(&ctx->uring_lock);                                │     │
│  │ }                                                                  │     │
│  │                                                                   │     │
│  │ if (flags & IORING_ENTER_GETEVENTS)                               │     │
│  │     ret = io_cqring_wait(ctx, min_complete, ...);   // 等待 CQE   │     │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                 │                                              │
│                                 ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  io_submit_sqes(ctx, nr)   [在 uring_lock 保护下]                     │   │
│  │                                                                    │   │
│  │  do {                                                              │   │
│  │      sqe = io_get_sqe(ctx);   // 从 sq_array[sq_head++] 读取索引     │   │
│  │      req = io_alloc_req(ctx);  // 从 per-cpu req cache 分配          │   │
│  │      io_submit_sqe(ctx, req, sqe, &left);  // 初始化 io_kiocb         │   │
│  │                                                                    │   │
│  │      // → io_queue_sqe(req) 或 io_queue_iowq(req)                   │   │
│  │  } while (--left);                                                  │   │
│  │                                                                    │   │
│  │  io_commit_sqring(ctx);  // 更新 ctx->cached_sq_head 同步             │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  io_queue_sqe(req)     // 尝试同步执行（inline）                       │   │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │   │
│  │  │ ret = io_issue_sqe(req, IO_URING_F_NONBLOCK |                   │ │   │
│  │  │                       IO_URING_F_COMPLETE_DEFER);               │ │   │
│  │  │                                                                 │ │   │
│  │  │ if (ret)    // 返回值非 0 → 需 async 处理                       │ │   │
│  │  │     io_queue_async(req, issue_flags, ret);   // → io-wq         │ │   │
│  │  │ else                                                       │ │   │
│  │  │     io_req_complete_defer(req);       // CQE 直接入 ring        │ │   │
│  │  └─────────────────────────────────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  io_queue_iowq(req)  // 派发到 io-wq 线程池异步执行                   │   │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │   │
│  │  │ io_prep_async_work(req);   // 设置 async context                │ │   │
│  │  │ io_wq_enqueue(ctx->tctx->io_wq, &req->work);  // 入 io-wq 队列   │ │   │
│  │  └─────────────────────────────────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  I/O 完成路径：io_req_task_complete(req)  (via task_work)            │   │
│  │                                                                    │   │
│  │  io_kiocb 完成后：                                                 │   │
│  │      req->io_task_work.func = io_req_task_complete;                 │   │
│  │      io_req_task_work_add(req);    // → tctx->task_list (llist)      │   │
│  │                                     → task_work_add() 注入信号      │   │
│  │                                                                    │   │
│  │  下次用户态 syscall 返回时（schedule() 之后）：                      │   │
│  │      → TIF_NOTIFY_SIGNAL → io_run_task_work()                       │   │
│  │          → io_handle_tw_list() 遍历 llist，执行回调                  │   │
│  │          → io_fill_cqe()   写入 rings->cqes[tail++]                 │   │
│  │          → wake_up(&ctx->cq_wait)  唤醒 io_cqring_wait()            │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  用户态读取 CQE（io_cqring_wait / poll / eventfd）                   │   │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │   │
│  │  │ while (smp_load_acquire(&rings->cq.head) == cq_tail) {         │ │   │
│  │  │     // CQ 为空，等待...                                          │ │   │
│  │  │     poll_wait(fd, &ctx->cq_wait, ...);  // 或 eventfd 通知)       │ │   │
│  │  │ }                                                                │ │   │
│  │  │ cqe = &rings->cqes[cq_head & cq_ring_mask];                      │ │   │
│  │  │ process(cqe->user_data, cqe->res, cqe->flags);                   │ │   │
│  │  │ smp_store_release(&rings->cq.head, cq_head + 1);                 │ │   │
│  │  └─────────────────────────────────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 sys_enter_write / copy_from_user 数据流

io_uring 的关键设计决策是**最大化减少数据复制**。`io_uring_enter()` 系统调用本身几乎是纯通知机制：

1. **SQE 已经在 mmap 之前由用户态直接写入**——零 copy_from_user
2. `io_uring_enter(to_submit=N)` 只传递一个整数 N，告知内核"SQ 中有 N 个新 SQE"
3. 内核读取 `sq_array`（已经在用户地址空间，通过 `get_user()` 快速访问）

```c
// io_uring.c - io_submit_sqes()
entries = __io_sqring_entries(ctx);  // 读取 sq.tail（用户已更新）
entries = min(nr, entries);

do {
    const struct io_uring_sqe *sqe;
    struct io_kiocb *req;
    
    if (!io_get_sqe(ctx, &sqe))    // 从 sq_array[sq_head] 读索引
        break;
    // sqe 现在指向用户 mmap 区域的 struct io_uring_sqe
    // 内核通过 get_user() 复制关键字段（非整个 SQE）
    io_submit_sqe(ctx, req, sqe, &left);
} while (--left);
```

### 3.3 SQ 指针 advance 同步

| 模式 | SQ Head | SQ Tail | 同步机制 |
|------|---------|---------|----------|
| **用户态轮询** | 用户读（内核写） | 用户写 | smp_store_release(tail) + smp_load_acquire(head) |
| **SQPOLL** | 内核读 | 用户写 | 内核线程 spin-wait tail 变化 |
| **IORING_SETUP_COOP_TASKRUN** | 内核读 | 用户写 | 内核通过 task_work 通知用户，无需 IPI |

```c
// 用户态轮询模式：SQ head 由内核在 io_submit_sqes 后更新
// io_commit_sqring() 更新 ctx->cached_sq_head
static inline void io_commit_sqring(struct io_ring_ctx *ctx)
{
    struct io_rings *rings = ctx->rings;
    // 内核更新 sq.head，用户重新映射到自己的虚拟地址空间
    WRITE_ONCE(rings->sq.head, ctx->cached_sq_head);
}
```

## 4. task_work 机制

### 4.1 为什么需要 task_work？

Linux 的异步 I/O 请求（如 `io_uring` 提交到 io-wq 的任务）最终需要在**原始进程上下文**中完成并写入 CQE。问题在于：

- io-wq worker 线程是内核线程，不在用户进程上下文
- 内核不能直接在任何上下文中调用 `copy_to_user()` 或操作用户态内存
- 需要一种机制将"完成工作"注入回发起进程

**task_work 就是这个机制**：将回调函数注入到当前任务的退出路径（syscall/exception 返回用户态之前）中执行。

### 4.2 task_work 注入流程

```c
// 内核 I/O 完成时（io-wq worker 或 软中断）
void io_req_task_complete(struct io_tw_req tw_req, io_tw_token_t tw)
{
    io_req_complete_defer(tw_req.req);   // 写入 CQE，设置 TASK_NR_CQEW
}

// io_req_task_work_add(req) 关键路径：
void io_req_task_work_add(struct io_kiocb *req)
{
    struct io_uring_task *tctx = req->tctx;
    
    // 1. 加入 per-task llist（原子操作）
    if (!llist_add(&req->io_task_work.node, &tctx->task_list))
        return;  // 已有 task_work  pending
    
    // 2. 通知进程（多种方式，取决于 setup 标志）
    if (ctx->flags & IORING_SETUP_TASKRUN_FLAG)
        atomic_or(IORING_SQ_TASKRUN, &ctx->rings->sq_flags);
    
    if (ctx->flags & IORING_SETUP_SQPOLL)
        __set_notify_signal(tctx->task);   // 向 SQPOLL 线程发信号
    else
        task_work_add(tctx->task, &tctx->task_work, ctx->notify_method);
        // notify_method = TWA_SIGNAL（默认）或 TWA_SIGNAL_NO_IPI
}
```

### 4.3 schedule() 与唤醒

task_work 的执行时机是**用户态返回前**，不是通过直接的 `schedule()` 调用：

```
用户进程                              内核
────────                              ──────
io_uring_enter()  ──→  sys_io_uring_enter()
                         │ io_submit_sqes() → 派发 io-wq
                         │ (返回 -EIOWQ 或 io_cqring_wait)
                         ▼
                   进程进入睡眠（sleeping on ctx->cq_wait）
                   ┌──────────────────────────────────────┐
                   │  schedule() 调度走，CPU 执行其他任务    │
                   └──────────────────────────────────────┘
                         ▲
                         │ I/O 完成 → io_req_task_complete()
                         │   → task_work_add() 注入回调
                         │   → wake_up(ctx->cq_wait)
                         │
                   ┌──────────────────────────────────────┐
                   │  wake_up() 唤醒进程                   │
                   │  进程被调度回来，退出 syscall 返回用户 │
                   │  → do_task_work() 执行注入的回调     │
                   │      → io_fill_cqe() 写入 ring      │
                   │      → poll_wait / eventfd 通知      │
                   └──────────────────────────────────────┘
```

**关键点**：task_work 的执行是在**进程调度回来后**、返回用户态之前，此时进程回到了发起 syscalls 的原始上下文，所以可以安全操作用户态内存。schedule() 发生在 `io_cqring_wait()` 中的 `wait_event_interruptible()` 内部。

### 4.4 task_work 执行入口

```c
// sched/task_work.c
void io_run_task_work(void)
{
    struct io_ring_ctx *ctx;
    struct io_tw_state ts = {};
    struct llist_node *node;
    
    node = llist_del_all(&ctx->work_llist);
    if (node)
        node = io_handle_tw_list(node, &count, max);
    
    // io_handle_tw_list() 遍历 llist，对每个 req 调用：
    // INDIRECT_CALL_2(req->io_task_work.func,
    //                 io_poll_task_func, io_req_rw_complete,
    //                 tw_req, ts);
}

// 内核每次从 syscall/exception/interrupt 返回用户态前：
// TIF_NOTIFY_SIGNAL 会被检查 → do_signal() → task_work_run() → io_run_task_work()
```

## 5. Multi-shot 和 LINK 语义

### 5.1 Multi-shot（IOSQE_CQE_SKIP_SUCCESS）

Multi-shot SQE 允许**一个 SQE 生成多个 CQE**：

```c
// sqe->flags:
IOSQE_CQE_SKIP_SUCCESS   // 成功时不post CQE

// 典型用途：IORING_OP_READ_MULTISHOT, IORING_OP_POLL_ADD_MULTI
// 每次条件满足（数据到达、事件触发）就 post 一个 CQE
// 最后一个 CQE 不带 IORING_CQE_F_MORE 标志表示结束
```

```c
// cqe->flags:
IORING_CQE_F_MORE         // 还有更多 CQE 会从同一个 SQE 生成
```

### 5.2 LINK 链（IOSQE_IO_LINK / IOSQE_IO_HARDLINK）

```
用户提交 4 个 SQE：
┌──────────────────────────────────────────┐
│ SQE[0]: opcode=read,  flags=IOSQE_IO_LINK │───┐
│ SQE[1]: opcode=write, flags=IOSQE_IO_LINK │───┼── LINK 链
│ SQE[2]: opcode=fsync, flags=IOSQE_IO_LINK │───┤
│ SQE[3]: opcode=nop,   flags=0             │←──┘ (终止LINK)
└──────────────────────────────────────────┘

LINK 语义：
- 同一条链上的 SQE 按顺序执行（串行化）
- 链中任一 SQE 失败：IOSQE_IO_LINK 模式下后续 SQE 被取消
                   IOSQE_IO_HARDLINK 模式下继续执行（更顽强）
- IORING_OP_LINK_TIMEOUT 独立超时控制
- IOSQE_IO_DRAIN：排空标志，前面的 SQE 全部完成才开始执行
```

```c
// io_uring.c
#define IO_REQ_LINK_FLAGS  (REQ_F_LINK | REQ_F_HARDLINK)

static void io_linked_timeout(struct io_kiocb *req)
{
    req->flags |= REQ_F_LINK_TIMEOUT;
    io_req_task_work_add(req);  // 插入 timeout 到 timeout_list
}

static void io_queue_sqe(struct io_kiocb *req, unsigned int extra_flags)
{
    ret = io_issue_sqe(req, issue_flags);
    if (unlikely(ret))
        io_queue_async(req, issue_flags, ret);
    // LINK 的串行化通过 uring_lock + defer_list 实现
}

// io_init_drain() 处理 DRAIN：
// ctx->submit_state.link.head 被设置为 LINK 链头
// 每个后续 req 被标记 REQ_F_IO_DRAIN | REQ_F_FORCE_ASYNC
// → io_drain_req() 将整个链放入 ctx->defer_list 延迟执行
```

### 5.3 Linked Ring（IORING_FEAT_LINKED_FILE）

`IORING_FEAT_LINKED_FILE` 特性允许某些 SQE（splice/tee/send_zc）跨越不同 ring 的文件描述符，但仍保持串行化语义。

## 6. Fixed File Table

### 6.1 为什么需要固定文件表？

每次普通 SQE 提交时，`io_file_get_normal()` 需要执行：

```c
// io_uring.c
req->file = io_file_get_normal(req, req->cqe.fd);
// → fdinstall() 查找 → get_file() → fget(fd)
// O(pathname lookup) 对网络 fd 也需要加锁
```

固定文件表通过 `io_uring_register(IORING_REGISTER_FILES, ...)` 预先注册 fd，后续提交只需 O(1) 数组查找。

### 6.2 内存布局

```c
// io_ring_ctx 中：
struct {
    struct io_file_table    file_table;   // 固定文件表
    struct io_rsrc_data     buf_table;     // 固定缓冲区表
};

// include/linux/io_uring_types.h
struct io_file_table {
    struct io_rsrc_data data;      // nodes[] xarray
    unsigned long *bitmap;         // 已分配 slot 位图
    unsigned int  alloc_hint;     // 分配提示（加速空闲查找）
};

// 注册时：
io_uring_register(fd, IORING_REGISTER_FILES, fds[], nr)
//  → 将用户 fd[] 通过 fdinstall() 复制到 file_table.nodes[]
//  → 设置 bitmap 位

// 使用时（SQE 设置 IOSQE_FIXED_FILE）：
sqe->fd = file_index;   // 不再是普通 fd，而是文件表索引
req->file = io_file_get_fixed(req, file_index, issue_flags);
// → nodes[file_index] 直接取出 struct file*，O(1)
```

### 6.3 限制

```c
// include/uapi/linux/io_uring.h
// 注册数量限制：通过 io_uring_register() 参数控制
// 实际限制取决于 ctx->file_table 大小和内存限制
#define IORING_REGISTER_FILES_SKIP  (-2)  // 跳过某个索引
```

固定文件表大小由 `io_uring_params.sq_entries` 和注册的文件数量共同决定，受 `RLIMIT_NOFILE` 和内核配置限制。

## 7. SQPOLL 模式

### 7.1 io_sqpoll_create — 内核线程的 spin-wait

```c
// sqpoll.c
int io_sq_offload_create(struct io_ring_ctx *ctx, struct io_uring_params *p)
{
    if (ctx->flags & IORING_SETUP_SQPOLL) {
        sqd = kzalloc_obj(*sqd);
        sqd->sq_thread_idle = p->sq_thread_idle;
        sqd->sq_cpu = p->sq_thread_cpu;  // IORING_SETUP_SQ_AFF
        
        // 绑定 CPU（可选）
        if (sqd->sq_cpu != -1)
            set_cpus_allowed_ptr(current, mask);
        
        // 创建内核线程，spin-wait SQ tail
        tsk = create_io_thread(io_sq_thread, sqd, NUMA_NO_NODE);
        sqd->thread = tsk;
        wake_up_process(tsk);
    }
}

// io_sq_thread() 主体：
static int io_sq_thread(void *data)
{
    struct io_sq_data *sqd = data;
    
    while (!kthread_should_stop()) {
        // spin-wait 新 SQE
        if (sq_ring_needs_waits(ctx, sqd)) {
            set_current_state(TASK_INTERRUPTIBLE);
            if (sqd->sq_thread_idle) {
                schedule_timeout(sqd->sq_thread_idle);  // 空闲后进入深度睡眠
                // 深度睡眠唤醒条件：sq.tail 变化 或 收到信号
            }
        } else {
            // 处理 SQE
            io_submit_sqes(ctx, ...);
        }
    }
}
```

### 7.2 何时进入深度睡眠？

```
SQPOLL 内核线程状态机：
                                    
  spin-wait sq.tail
        │
        ▼
  sq.tail 变化？───yes──→ 处理 SQE → spin-wait
        │
        no
        │
        ▼
  sq_thread_idle 超时？───yes──→ schedule_timeout(idle)
                                      │
                                      ▼
                               进入深度睡眠（TASK_INTERRUPTIBLE）
                                      │
          sq.tail 变化 or wake_up ────┘
                  │
                  ▼
            TASK_RUNNING
            (schedule 唤醒)
```

### 7.3 CPU vs 延迟的 Trade-off

| 配置 | CPU 占用 | 延迟 | 适用场景 |
|------|----------|------|----------|
| 无 SQPOLL（默认） | 0（只在 submit/wait 时占用） | 取决于调度延迟 | 低频 I/O，超出 io_uring_enter 的 syscall 成本不可接受 |
| SQPOLL + 短 idle | 中等 | 极低（µs 级） | 高频交易、低延迟网络 |
| SQPOLL + 长 idle | 低（在 idle 期间） | 稍高（取决于 idle 时长） | 中等频率 I/O，需要零 syscall 提交 |
| SQPOLL + 绑定特定 CPU | 取决于 spin 占比 | 低 | 核心数充裕，追求最低延迟 |

## 8. 和 epoll 的本质区别

### 8.1 概念对比

| 维度 | epoll | io_uring |
|------|-------|----------|
| **封装层级** | 事件通知（OAL） | 数据通路（full I/O path） |
| **零拷贝** | 否（每次 read/write 仍有数据拷贝） | 是（SQE/CQE 通过 mmap 零 syscall 数据传递） |
| **轮询方式** | epoll_wait() 阻塞等待 | 轮询 CQ head（CQE 就绪检查）或等待 eventfd |
| **系统调用** | 每事件至少 2 次：epoll_wait + read/write | 批量提交后可只 1 次 io_uring_enter |
| **支持的操作** | 仅文件描述符事件 | 读/写/发送/接收/超时/同步/文件操作全部统一 |
| **完成语义** | 只通知"可读/可写" | 包含实际结果（字节数/error） |
| **固定文件** | 不支持 | 支持（避免每次 fd lookup） |
| **多线程提交** | 需加锁 | 支持（多线程同时 submit） |

### 8.2 本质区别

**epoll 是观察者，io_uring 是执行者。**

- epoll 只能告诉你"socket X 可读了"，真正的数据读写仍需 `read()` / `write()` 系统调用
- io_uring 可以让你提交一个"读请求"，内核完成读操作后直接返回字节数据

### 8.3 何时选 io_uring

```
选 io_uring 的场景：
  ✓ 高吞吐量 I/O（网络服务器、数据库存储引擎）
  ✓ 需要批量 I/O（一次提交/等待多个操作）
  ✓ 超低延迟（通过 SQPOLL 消除 syscall 开销）
  ✓ 统一接口（文件 I/O + 网络 I/O + 计时器）
  ✓ 需要固定文件表优化

选 epoll 的场景：
  ✓ 只需要事件通知，不需要异步 I/O 数据传输
  ✓ 遗留代码库，迁移成本高
  ✓ 超简单场景（仅监听几个 fd）
```

## 9. 缓存和内存管理

### 9.1 user_data 指针传递

`user_data` 是 SQE 到 CQE 之间传递用户上下文的核心字段：

```c
// 用户态
sqes[i].user_data = (uint64_t)my_context_ptr;  // 64-bit 指针

// 内核原样拷贝到 CQE
cqe->user_data = sqe->user_data;  // 在 io_fill_cqe() 中
```

### 9.2 32-bit vs 64-bit 场景

在 32-bit 用户态环境下，`user_data` 是 32-bit 值，无法直接存储指针。典型解决方案：

```c
// 32-bit 模式：用索引代替指针
sqes[i].user_data = (uint64_t)ctx_index;  // 小整数

// 用户态维护一个数组：
// user_data = array_index * 8 + base_address
// 实际指针 = base + (user_data * 8)
```

`addr`/`addr2`/`addr3` 字段同样受此限制：

```c
// 64-bit 用户态：直接存储指针
sqes[i].addr = (uint64_t)user_buffer_ptr;

// 32-bit 用户态：必须使用固定缓冲区（buf_index）
// 通过 io_uring_register(IORING_REGISTER_BUFFERS, ...) 注册固定缓冲区
// sqes[i].buf_index = buffer_id;
// 内核通过 buf_table 查找实际物理页，避免指针语义问题
```

### 9.3 固定缓冲区和 Ring Buffer

```c
// 注册固定缓冲区（用户→内核）
io_uring_register(fd, IORING_REGISTER_BUFFERS, iovecs[], nr);
// 内核将用户页 pin住（get_user_pages），存入 io_rsrc_data

// 使用时（SQE 设置 IOSQE_BUFFER_SELECT）：
sqes[i].buf_group = bgid;
sqes[i].len = count;   // 请求的字节数
// 内核从对应 buffer group 选择一个 buffer
// CQE 的 buf_index 标识用了哪个 buffer
```

## 10. 关键数据结构汇总

```
┌─────────────────────────────────────────────────────────────────┐
│                    进程虚拟地址空间（mmap 区域）                    │
│                                                                  │
│  fd = io_uring_setup(entries=1024, &params);                    │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  SQ Ring (IORING_OFF_SQ_RING)                               │  │
│  │  struct io_rings {                                          │  │
│  │      sq.head, sq.tail        // 内核写 head, 用户写 tail     │  │
│  │      cq.head, cq.tail        // 内核写 tail, 用户读 head     │  │
│  │      sq_ring_mask, cq_ring_mask                            │  │
│  │      sq/cq_ring_entries                                     │  │
│  │      sq_dropped, sq_flags (atomic)                          │  │
│  │      cq_flags, cq_overflow                                  │  │
│  │  } + struct io_uring_cqe cqes[N]   (cache-line aligned)     │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  SQEs (IORING_OFF_SQES)                                     │  │
│  │  struct io_uring_sqe sq_sqes[1024];   // 64B each          │  │
│  │  u32 sq_array[1024];                  // SQE 索引数组        │  │
│  └────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
          ▲ mmap                               ▲ mmap
          │                                     │
┌─────────┴─────────────────────────────────────┴──────────────────┐
│                      内核地址空间                                    │
│                                                                  │
│  struct io_ring_ctx {                                            │
│      struct io_rings       *rings;        // 指向 mmap 区域        │
│      u32                   *sq_array;     // 指向 mmap 区域        │
│      struct io_uring_sqe   *sq_sqes;     // 指向 mmap 区域        │
│                                                                  │
│      struct io_sq_data     *sq_data;     // SQPOLL 线程数据       │
│      struct io_file_table   file_table;  // 固定文件表            │
│      struct io_rsrc_data    buf_table;   // 固定缓冲区表          │
│                                                                  │
│      struct llist_head      work_llist;   // task_work 链表头     │
│      struct io_wq          *io_wq;        // 异步工作队列          │
│  };                                                              │
│                                                                  │
│  struct io_kiocb {                    // 每个 SQE 对应一个        │
│      struct file     *file;           // 目标文件                 │
│      u8              opcode;           // 操作码                   │
│      io_req_flags_t  flags;           // REQ_F_* 标志             │
│      struct io_ring_ctx *ctx;         // ring context             │
│      struct io_task_work io_task_work; // task_work 注入节点       │
│      struct io_kiocb   *link;          // LINK 链下一个           │
│      union { ... };                   // 操作特定数据             │
│  };                                                            │
│                                                                  │
│  struct io_sq_data {               // SQPOLL 模式               │
│      struct task_struct *thread;    // 内核线程                  │
│      struct wait_queue_head wait;   // 等待队列                  │
│      unsigned sq_thread_idle;       // 空闲超时                  │
│  };                                                            │
└──────────────────────────────────────────────────────────────────┘
```

## 11. 总结

io_uring 通过三个核心机制实现了高性能异步 I/O：

1. **共享内存环形队列**：mmap 区域绕过内核边界，消除 SQE/CQE 的数据拷贝
2. **task_work 回调注入**：将完成处理安全地迁移回用户进程上下文
3. **io-wq 线程池**：在内核线程中执行真正耗时的 I/O 操作，保持用户进程响应性

这三个机制配合 `io_uring_enter()` 的批量提交/等待语义，使得 io_uring 在高吞吐量场景下 syscall 次数降低 **O(N)** → **O(1)**，这是它相比 epoll 最根本的性能优势。

---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `io_uring/io_uring.c` | 145 | 1 | 129 | 8 |

### 核心数据结构

- **io_tctx_exit** `io_uring.c:2282`

### 关键函数

- **io_queue_sqe** `io_uring.c:121`
- **__io_req_caches_free** `io_uring.c:122`
- **io_poison_cached_req** `io_uring.c:153`
- **io_poison_req** `io_uring.c:163`
- **req_fail_link_node** `io_uring.c:173`
- **io_req_add_to_cache** `io_uring.c:179`
- **io_ring_ctx_ref_free** `io_uring.c:186`
- **io_alloc_hash_table** `io_uring.c:193`
- **io_free_alloc_caches** `io_uring.c:215`
- **io_ring_ctx_alloc** `io_uring.c:225`
- **io_clean_op** `io_uring.c:309`
- **io_req_track_inflight** `io_uring.c:336`
- **__io_prep_linked_timeout** `io_uring.c:344`
- **io_prep_async_work** `io_uring.c:358`
- **io_prep_async_link** `io_uring.c:390`
- **io_queue_iowq** `io_uring.c:407`
- **io_req_queue_iowq_tw** `io_uring.c:435`
- **io_req_queue_iowq** `io_uring.c:440`
- **io_linked_nr** `io_uring.c:446`
- **io_queue_deferred** `io_uring.c:456`
- **__io_commit_cqring_flush** `io_uring.c:479`
- **__io_cq_lock** `io_uring.c:489`
- **io_cq_lock** `io_uring.c:495`
- **__io_cq_unlock_post** `io_uring.c:501`
- **io_cq_unlock_post** `io_uring.c:514`
- **__io_cqring_overflow_flush** `io_uring.c:523`
- **io_cqring_overflow_kill** `io_uring.c:580`
- **io_cqring_do_overflow_flush** `io_uring.c:586`
- **io_cqring_overflow_flush_locked** `io_uring.c:593`
- **io_put_task** `io_uring.c:599`
- **io_task_refs_refill** `io_uring.c:613`
- **io_uring_drop_tctx_refs** `io_uring.c:622`
- **io_cqring_add_overflow** `io_uring.c:634`
- **io_alloc_ocqe** `io_uring.c:660`
- **io_fill_nop_cqe** `io_uring.c:693`

### 全局变量

- **io_key_has_sqarray** `io_uring.c:124`
- **req_cachep** `io_uring.c:126`
- **iou_wq** `io_uring.c:127`
- **sysctl_io_uring_disabled** `io_uring.c:129`
- **sysctl_io_uring_group** `io_uring.c:130`
- **kernel_io_uring_disabled_table** `io_uring.c:133`
- **io_uring_fops** `io_uring.c:2697`
- **__UNIQUE_ID_addressable_io_uring_init_172** `io_uring.c:3259`

### 成员/枚举

- **task_work** `io_uring.c:2283`
- **completion** `io_uring.c:2284`
- **ctx** `io_uring.c:2285`

