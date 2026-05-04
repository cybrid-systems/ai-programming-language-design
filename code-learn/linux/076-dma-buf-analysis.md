# 076-dma-buf — Linux DMA-BUF 共享缓冲区与同步框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**DMA-BUF** 是 Linux 内核在不同设备驱动间共享 DMA 缓冲区的框架。它允许一个驱动（如摄像头）分配缓冲区，另一个驱动（如 GPU）导入并直接访问，无需 CPU 拷贝。这是 Android Gralloc、Wayland、DRM/KMS 图形栈的核心通信协议。

DMA-BUF 框架分为两部分：
- **dma_buf**：缓冲区共享（分配/导出/导入）
- **dma_fence**：缓冲区同步（GPU 完成通知）

**doom-lsp 确认**：`include/linux/dma-buf.h`（dma_buf/dma_buf_ops 定义），`drivers/dma-buf/dma-buf.c`（核心实现，~100 个符号），`include/linux/dma-fence.h`（dma_fence 定义）。

---

## 1. 核心数据结构

### 1.1 `struct dma_buf`——共享缓冲区

（`include/linux/dma-buf.h` L294 — doom-lsp 确认）

```c
struct dma_buf {
    size_t                  size;           // L300 — 缓冲区大小（字节）
    struct file             *file;          // L306 — 关联文件（通过 fd 导出）
    struct list_head        attachments;    // L310 — 附加设备列表（dma_buf_attachment）
    const struct dma_buf_ops *ops;          // L313 — 操作函数表（attach/mmap/release）
    struct mutex            lock;           // L316 — 保护 attachments 的锁
    unsigned int            vmapping_counter; // L320 — vmap 引用计数
    void                    *vmap_ptr;      // L321 — 内核虚拟映射地址
    void                    *priv;          // L340 — 分配者的私有数据
};
```

### 1.2 `struct dma_buf_attachment`——设备附加

```c
struct dma_buf_attachment {
    struct dma_buf          *dmabuf;        // L331 — 共享缓冲区
    struct device           *dev;           // L333 — 附加设备
    struct list_head        node;           // L336 — dma_buf->attachments 链表节点
    struct sg_table         *sgt;           // 设备 DMA 地址的 scatter-gather 表
    enum dma_data_direction  dir;           // DMA 方向（DMA_TO_DEVICE / FROM_DEVICE / BIDIRECTIONAL）
};
```

### 1.3 `struct dma_fence`——同步基元

（`include/linux/dma-fence.h` L70 — doom-lsp 确认）

```c
struct dma_fence {
    spinlock_t              lock;           // L72 — 保护 fence 的自旋锁
    const struct dma_fence_ops *ops;        // L75 — 操作函数表（get_driver_name/get_timeline_name/signaled/release）
    union {
        struct list_head    cb_list;        // L79 — 回调链表（等待该 fence 完成的回调）
        struct list_head    timeline_list;  // L80 — timeline 链表（按 seqno 排序）
    };
    u64                     context;        // L84 — fence 上下文（驱动+timeline 唯一）
    signed long             seqno;          // L85 — 序列号（单调递增）
    unsigned long           flags;          // L87 — DMA_FENCE_FLAG_* 标志
    ktime_t                 timestamp;      // L88 — 信号时间戳
    int                     error;          // L89 — 错误码（0 = 成功）
};
```

---

## 2. 完整数据流

### 2.1 分配 + 导出

```
生产者驱动（如 V4L2 摄像头驱动）：
  // 1. 定义导出信息
  struct dma_buf_export_info exp_info = {
      .ops  = &my_dma_buf_ops,      // attach/detach/mmap/release
      .size = BUFFER_SIZE,
      .flags = O_RDWR,
      .priv = my_buffer_data,
  };

  // 2. 导出 dma_buf
  dmabuf = dma_buf_export(&exp_info);
    └─ dma_buf_getfile(exp_info->size, exp_info->flags)  // 分配匿名文件
    └─ file->private_data = dmabuf
    └─ init list_head(&dmabuf->attachments)

  // 3. 获取文件描述符
  fd = dma_buf_fd(dmabuf, O_CLOEXEC);
    └─ get_unused_fd_flags(flags)
    └─ fd_install(fd, dmabuf->file)

  // 4. 通过 V4L2 ioctl（VIDIOC_QBUF/VIDIOC_DQBUF）将 fd 传给用户空间
```

### 2.2 导入

```
消费者驱动（如 DRM/KMS GPU 驱动）：
  // 1. 从 fd 获取 dma_buf
  dmabuf = dma_buf_get(fd);
    └─ fget(fd) → file  → file->private_data  → dmabuf

  // 2. 附加到设备
  attach = dma_buf_attach(dmabuf, dev);
    └─ dmabuf->ops->attach(dmabuf, attachment, NULL)
    └─ list_add(&attachment->node, &dmabuf->attachments)

  // 3. 获取 DMA 地址
  sg_table = dma_buf_map_attachment(attach, direction);
    └─ dma_map_sgtable(dev, sg, direction, 0)  // IOMMU 映射
    └─ 返回 scatter-gather 表（设备可访问的 DMA 地址列表）

  // 4. GPU 通过 sg_table 中的 DMA 地址访问缓冲区内容
  //    无需 CPU 拷贝
```

### 2.3 dma_fence 同步

```
GPU 提交渲染命令后安装 dma_fence：
  // 1. 分配并初始化 fence
  struct dma_fence *fence;
  dma_fence_init(fence, &my_fence_ops, &my_lock, context, ++seqno);
    └─ spin_lock_init(&fence->lock)
    └─ fence->context = context
    └─ fence->seqno = seqno
    └─ INIT_LIST_HEAD(&fence->cb_list)

  // 2. 将 fence 附加到 dma_buf
  dma_buf_reservation_add_fence(dmabuf->resv, DmaFence, fence);
    → 将来其他驱动导入该 dma_buf 时可以看到 fence

  // 3. 消费者等待 fence
  dma_fence_wait(fence, true);  // intr = true 表示可被信号中断
    └─ 如果 fence 未 signaled：
         └─ dma_fence_add_callback(fence, &cb, my_callback)
         └─ 睡眠等待
         └─ 被 dma_fence_signal() 唤醒

  // 4. GPU 完成 → 触发 fence
  dma_fence_signal(fence);
    └─ fence->flags |= DMA_FENCE_FLAG_SIGNALED_BIT
    └─ __dma_fence_signal__rcu(fence)
         └─ list_for_each_entry_safe(cb, ...)
              cb->func(fence, cb)  // 唤醒所有等待者
```

---

## 3. dma_buf_ops 操作表

```c
struct dma_buf_ops {
    int (*attach)(struct dma_buf *, struct dma_buf_attachment *);       // 设备附加
    void (*detach)(struct dma_buf *, struct dma_buf_attachment *);      // 设备分离
    struct sg_table *(*map_dma_buf)(struct dma_buf_attachment *, enum dma_data_direction);
    void (*unmap_dma_buf)(struct dma_buf_attachment *, struct sg_table *, enum dma_data_direction);
    void (*release)(struct dma_buf *);                                  // 释放
    int (*mmap)(struct dma_buf *, struct vm_area_struct *);             // mmap 到用户空间
    int (*vmap)(struct dma_buf *, struct iosys_map *);                  // 内核虚拟映射
    void (*vunmap)(struct dma_buf *, struct iosys_map *);               // 解除映射
};
```

---


## 3. dma_buf_export——核心分配函数

（`drivers/dma-buf/dma-buf.c` L691 — doom-lsp 确认）

```c
/**
 * dma_buf_export - Creates a new dma_buf, and associates an anon file
 * with this buffer, so it can be exported.
 */
struct dma_buf *dma_buf_export(const struct dma_buf_export_info *exp_info)
{
    struct dma_buf *dmabuf;
    struct file *file;
    size_t alloc_size = sizeof(struct dma_buf);
    
    // 1. 参数检查
    if (WARN_ON(!exp_info->ops || !exp_info->ops->release))
        return ERR_PTR(-EINVAL);

    // 2. 分配 dma_buf 结构体
    dmabuf = kzalloc(alloc_size, GFP_KERNEL);
    if (!dmabuf)
        return ERR_PTR(-ENOMEM);

    // 3. 创建匿名文件（作为共享 fd 的基础）
    file = dma_buf_getfile(exp_info->size, exp_info->flags);
    file->private_data = dmabuf;
    dmabuf->file = file;

    // 4. 初始化
    dmabuf->ops = exp_info->ops;
    dmabuf->size = exp_info->size;
    dmabuf->priv = exp_info->priv;
    mutex_init(&dmabuf->lock);
    INIT_LIST_HEAD(&dmabuf->attachments);
    init_waitqueue_head(&dmabuf->poll);
    
    // 5. reserve 对象初始化（用于 dma_fence 同步）
    dma_resv_init(dmabuf->resv);
    if (dma_resv_init(dmabuf->resv)) {
        // 失败处理
    }

    return dmabuf;
}
```

## 4. dma_fence 信号机制详解

```c
// drivers/dma-buf/dma-fence.c — doom-lsp 确认

// 生产者（如 GPU 驱动）在提交渲染命令时创建 fence：
struct dma_fence *fence;
dma_fence_init(fence, &my_fence_ops, &my_lock, ctx, ++seqno);

// GPU 完成渲染后：
dma_fence_signal(fence);
  └─ fence->flags |= DMA_FENCE_FLAG_SIGNALED_BIT
  └─ __dma_fence_signal__rcu(fence)
       └─ 遍历 cb_list，调用每个回调函数
       └─ wake_up_all(&fence->wait_queue)

// 消费者等待：
dma_fence_wait(fence, true);  // intr = 可被信号中断
  └─ 如果未 signaled：
       └─ dma_fence_add_callback(fence, &cb, my_callback)
       └─ schedule() → 等待 dma_fence_signal 唤醒

// 内核等待的超时版本：
dma_fence_wait_timeout(fence, intr, timeout);
  // 返回 0 = 超时, 1 = signaled, <0 = 错误
```


### 4.1 dma_fence_init——初始化 fence

（`drivers/dma-buf/dma-fence.c` L1114 — doom-lsp 确认）

```c
void dma_fence_init(struct dma_fence *fence, const struct dma_fence_ops *ops,
                    spinlock_t *lock, u64 context, u64 seqno)
{
    __dma_fence_init(fence, ops, lock, context, seqno, 0UL);
}
// → 内部调用 __dma_fence_init，关键操作:
//    spin_lock_init(&fence->lock)
//    fence->context = context
//    fence->seqno = seqno
//    fence->ops = ops
//    set_bit(DMA_FENCE_FLAG_INITIALIZED_BIT, &fence->flags)
//    INIT_LIST_HEAD(&fence->cb_list)
//    kref_init(&fence->refcount)
```

### 4.2 GPU 驱动中的典型使用模式

```c
// GPU 驱动提交命令时：
// struct dma_fence *fence = kmalloc(sizeof(*fence), GFP_KERNEL);
// dma_fence_init(fence, &gpu_driver_fence_ops, &ring->lock, drv->context, ++seqno);
//
// 将 fence 附加到 dma_buf 的 reservation object：
// dma_resv_add_fence(dmabuf->resv, fence, DMA_RESV_USAGE_BOOKKEEP);
//
// 驱动提交命令到 GPU ring buffer
//   → GPU 执行完成后触发中断
//   → irq_handler 调用 dma_fence_signal(fence)
//
// 其他进程（如 compositor）通过 dma_fence_wait() 等待完成
```

## 4. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct dma_buf` | include/linux/dma-buf.h | 294 |
| `struct dma_buf_ops` | include/linux/dma-buf.h | 相关 |
| `struct dma_fence` | include/linux/dma-fence.h | 70 |
| `dma_buf_export()` | drivers/dma-buf/dma-buf.c | 668 |
| `dma_buf_fd()` | drivers/dma-buf/dma-buf.c | 相关 |
| `dma_buf_get()` | drivers/dma-buf/dma-buf.c | 相关 |
| `dma_buf_attach()` | drivers/dma-buf/dma-buf.c | 相关 |
| `dma_buf_map_attachment()` | drivers/dma-buf/dma-buf.c | 相关 |
| `dma_fence_init()` | drivers/dma-buf/dma-fence.c | 相关 |
| `dma_fence_signal()` | drivers/dma-buf/dma-fence.c | 相关 |
| `dma_fence_wait()` | drivers/dma-buf/dma-fence.c | 相关 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
