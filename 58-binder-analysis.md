# Linux Kernel Binder 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/android/binder.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 Binder？

**Binder** 是 Android 的**进程间通信（IPC）机制**，替代了 Linux 传统的 System V IPC（msgqueue、shm、sem）。Binder 基于**驱动**实现，通过 `/dev/binder` 设备提供：

- **共享内存**的高效传输
- **对象引用**的跨进程传递（类似 IPC handle）
- **UID/PID** 验证（安全性）

---

## 1. 核心数据结构

### 1.1 binder_proc — 进程上下文

```c
// drivers/android/binder.c — binder_proc
struct binder_proc {
    struct hlist_node proc_node;         // 接入全局 proc 链表
    int                 pid;              // 进程 PID
    struct vm_struct    *mapped_area;     // 映射的 VM 地址
    struct rb_root      nodes;           // 此进程管理的 binder_node
    struct list_head    todo;            // 待处理工作（receive 队列）
    struct list_head    delivered_txn;   // 已递送的事务
    struct list_head    async_todo;       // 异步事务队列
    struct mutex        inner_lock;
    struct mutex        outer_lock;
    struct list_head    binder_ref_death;  // 死亡通知
};
```

### 1.2 binder_node — Binder 对象

```c
// drivers/android/binder.c — binder_node
struct binder_node {
    int                 debug_id;
    struct binder_proc   *proc;           // 所属进程
    struct rb_node      rb_node;         // 接入 proc->nodes 红黑树
    struct list_head    refs;            // 此节点的引用列表
    atomic_t            ref;              // strong 引用计数
    void                *user_data;      // 指向 Java 层 IBinder
    uintptr_t           ptr;             // 跨进程句柄（cookie）
    uintptr_t           cookie;          // 附加数据
    unsigned long      flags;
};
```

### 1.3 binder_transaction — 事务

```c
// drivers/android/binder.c — binder_transaction
struct binder_transaction {
    int                     debug_id;
    struct binder_proc       *from;           // 发送方进程
    struct binder_proc       *to;            // 接收方进程
    struct binder_node       *target_node;   // 目标 binder_node
    int                     to_proc;         // 目标进程 PID
    int                     to_thread;       // 目标线程 PID
    struct list_head        work_type;       // 工作类型
    struct list_head        todo;            // 目标线程的 todo 链表
    struct list_head        reply_item;      // 回复链表
    void                    *buffer;         // 共享内存缓冲区
    size_t                  buffer_size;
    unsigned long           data_size;
    unsigned long           offsets_size;
};
```

---

## 2. Binder 通信流程

```
进程 A（Client）                              进程 B（Service）
     │                                              │
     │  BC_TRANSACTION                               │
     │  ─────────────────────────────────────────► │
     │  { replyBinder = handle_123 }              │
     │                                             │
     │                          ① 查找 handle_123 对应的 binder_node
     │                          ② 从 proc_B.todo 取 work
     │                          ③ 复制共享内存数据到进程 B
     │                                             │
     │                          BR_TRANSACTION_COMPLETE
     │  ◄───────────────────────────────────────── │
     │                                             │
     │                          处理服务逻辑           │
     │                          BR_REPLY              │
     │  ◄───────────────────────────────────────── │
     │  { result = xxx }                         │
```

---

## 3. 共享内存（Binder Buffer）

```c
// binder_mmap — 建立共享内存
static int binder_mmap(struct file *filp, struct vm_area_struct *vma)
{
    struct binder_proc *proc = filp->private_data;

    // 1. 分配binder_buffer
    //    物理页来自一个预先分配的 pool
    proc->buffer = vma->vm_start;

    // 2. 映射到用户空间
    //    vma->vm_ops = &binder_vm_ops;
    //    用户空间通过 /dev/binder mmap 获取共享缓冲区

    return 0;
}
```

---

## 4. BC_TRANSACTION — 发送事务

```c
// drivers/android/binder.c — binder_ioctl
static long binder_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    switch (cmd) {
    case BINDER_WRITE_READ:
        // 发送事务或接收回复
        if (copy_from_user(&bwr, (void __user *)arg, sizeof(bwr)))
            return -EFAULT;

        // 处理写缓冲区（BC_xxx 命令）
        if (bwr.write_size > 0)
            ret = binder_thread_write(proc, thread, bwr.read_buffer,
                        bwr.write_size, bwr.write_consumed);

        // 处理读缓冲区（BR_xxx 回复）
        if (bwr.read_size > 0)
            ret = binder_thread_read(proc, thread, bwr.read_buffer,
                        bwr.read_size, bwr.read_consumed, ...);
        break;
    }
}
```

---

## 5. flat_binder_object — 跨进程引用

```c
// include/uapi/linux/binder.h — flat_binder_object
struct flat_binder_object {
    __u32           type;           // BINDER_TYPE_BINDER / HANDLE / WEAK_*
    __u32           flags;
    __u64           handle;         // 跨进程句柄
    __u64           cookie;         // 附加数据
};

// type 字段：
//   BINDER_TYPE_BINDER：传递 strong 引用
//   BINDER_TYPE_WEAK_BINDER：传递 weak 引用
//   BINDER_TYPE_HANDLE：传递 handle（代理引用）
//   BINDER_TYPE_FD：传递文件描述符
```

---

## 6. 死亡通知（Death Notification）

```c
// 注册死亡通知
// BC_REQUEST_DEATH_NOTIFICATION
// 当 target process 退出时：
//   → binder_node 被释放
//   → BC_CLEAR_DEATH_NOTIFICATION 触发
//   → 发送 BR_DEAD_BINDER 给注册者
```

---

## 7. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| 共享内存 mmap | 避免数据复制，零拷贝 |
| handle 作为跨进程引用 | 隔离进程，handle 可被撤销 |
| flat_binder_object 编码 | 统一的 IPC 数据序列化格式 |
| todo 链表 per thread | 多线程 service 可以并行处理 |
| death notification | 及时发现对方进程退出 |

---

## 8. 参考

| 文件 | 内容 |
|------|------|
| `drivers/android/binder.c` | 核心实现 |
| `drivers/android/binderfs.c` | binderfs 文件系统 |
| `include/uapi/linux/binder.h` | `flat_binder_object`、`BINDER_*` 常量 |
