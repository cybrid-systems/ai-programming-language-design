# userfaultfd — 用户空间页面缺失处理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/userfaultfd.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**userfaultfd** 允许用户空间程序处理**自己进程地址空间的 page fault**。用于：
- **虚拟机**：在用户空间实现访存隔离（类似 virt-manager 的 COW）
- **延迟分页**：按需加载大文件（madvise DONTNEED 后再触发）
- **实时迁移**：在线迁移时暂停写时复制

---

## 1. 核心数据结构

### 1.1 userfaultfd_ctx — 文件上下文

```c
// fs/userfaultfd.c — userfaultfd_ctx
struct userfaultfd_ctx {
    // 状态
    unsigned long           features;      // UFFDIO_API 时钟
    unsigned long           released;      // 已释放

    // 内部状态
    struct rw_semaphore     read_lock;     // 读取操作的锁
    atomic_t                ref;           // 引用计数

    // UFFDIO_REGISTER 配置
    unsigned long           flags;         // UFFDIO_REGISTER_MODE_*
    struct range            range;         // 监控的地址范围

    // 内部 fd
    int                     fd;            // 内部 fd
    struct file             *file;         // 关联的 file
};
```

### 1.2 uffd_msg — page fault 消息

```c
// include/uapi/linux/userfaultfd.h — uffd_msg
struct uffd_msg {
    __u8    event;           // UFFD_EVENT_* 类型
    __u8    reserved1;
    __u16   reserved2;
    __u32   msg;
    union {
        struct {
            __u64       flags;       // UFFD_FLAG_*
            __u64       address;    // 触发 fault 的地址
            __u32       pagefault_flags; // 页错误标志
        } pagefault;
        struct {
            __u64       start;
            __u64       end;
        } range;
    };
};
```

### 1.3 ioctl 命令

```c
// include/uapi/linux/userfaultfd.h
// 创建 userfaultfd
int uffd = syscall(__NR_userfaultfd, O_CLOEXEC | O_NONBLOCK);

// 获取特性
ioctl(uffd, UFFDIO_API, &features);

// 注册监控区域
struct uffdio_register reg = {
    .mode = UFFDIO_REGISTER_MODE_MISSING, // 只处理缺失
    .range = { .start = addr, .len = len }
};
ioctl(uffd, UFFDIO_REGISTER, &reg);

// 等待并处理 page fault
struct uffd_msg msg;
read(uffd, &msg, sizeof(msg));  // 阻塞直到 fault

// 解决 page fault（填充页）
struct uffdio_copy copy = {
    .dst = msg.pagefault.address,
    .src = user_buffer,
    .len = PAGE_SIZE
};
ioctl(uffd, UFFDIO_COPY, &copy);
```

---

## 2. 注册 VMA

### 2.1 userfaultfd_register

```c
// fs/userfaultfd.c — userfaultfd_register
static int userfaultfd_register(struct userfaultfd_ctx *ctx,
                                struct uffdio_register *arg)
{
    // 1. 遍历 VMA 范围
    for (vma = find_vma(mm, start); vma && vma->vm_start < end; vma = vma->vm_next) {
        // 2. 不能用于写时复制（需要 VM_MAYWRITE）
        if (!(vma->vm_flags & VM_MAYWRITE))
            return -EINVAL;

        // 3. 设置 VM_UFFD_MISSING 或 VM_UFFD_WP
        if (arg->mode & UFFDIO_REGISTER_MODE_MISSING)
            vma->vm_flags |= VM_UFFD_MISSING;
        if (arg->mode & UFFDIO_REGISTER_MODE_WP)
            vma->vm_flags |= VM_UFFD_WP;

        // 4. 设置 userfaultfd 上下文
        vma->vm_userfaultfd_ctx = ctx;
    }

    return 0;
}
```

---

## 3. 处理 Page Fault

### 3.1 userfaultfd_missing

```c
// mm/userfaultfd.c — userfaultfd_missing
vm_fault_t userfaultfd_missing(struct vm_fault *vmf)
{
    struct vm_area_struct *vma = vmf->vma;
    struct userfaultfd_ctx *ctx = vma->vm_userfaultfd_ctx;
    struct uffd_msg msg = {
        .event = UFFD_EVENT_PAGEFAULT,
        .pagefault = {
            .flags = 0,
            .address = vmf->address,
            .pagefault_flags = 0,
        }
    };

    // 1. 发送消息到 userfaultfd
    if (ctx)
        userfaultfd_dispatch(ctx, &msg);

    // 2. 返回 VM_FAULT_SIGBUS（用户空间尚未填充）
    return VM_FAULT_SIGBUS;
}
```

---

## 4. 事件类型

```c
// include/uapi/linux/userfaultfd.h
enum {
    UFFD_EVENT_PAGEFAULT,     // 缺页异常
    UFFD_EVENT_REMOVE,        // MADV_DONTNEED 移除
    UFFD_EVENT_UNMAP,          // VMA 被 unmap
    UFFD_EVENT_MERGE,          // VMA 被合并
    UFFD_EVENT_WRITEPROTECT,   // 写保护
};
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/userfaultfd.c` | `userfaultfd_register`、`userfaultfd_missing` |
| `mm/userfaultfd.c` | `userfaultfd_dispatch`、`handle_userfault` |
| `include/uapi/linux/userfaultfd.h` | `struct uffd_msg`、`ioctl` |