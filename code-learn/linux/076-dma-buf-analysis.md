# 076-dma-buf — Linux DMA-BUF 共享缓冲区与同步框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码 | 使用 doom-lsp 进行逐行符号解析

## 0. 概述

**DMA-BUF** 是 Linux 内核在不同设备驱动间共享 DMA 缓冲区的框架，也是 Android Gralloc、Wayland、DRM/KMS 图形栈的核心通信协议。它允许一个驱动（如摄像机）分配缓冲区，另一个驱动（如 GPU）导入并访问，无需 CPU 拷贝。

**doom-lsp 确认**：`drivers/dma-buf/dma-buf.c`（~100 符号），`include/linux/dma-buf.h`。

---

## 1. 核心数据结构

### 1.1 `struct dma_buf`——共享缓冲区

```c
struct dma_buf {
    size_t                  size;           // 缓冲区大小（字节）
    struct file             *file;          // 关联的文件描述（通过 fd 导出）
    struct list_head        attachments;    // 附加设备列表
    const struct dma_buf_ops *ops;          // 操作函数表（attach/mmap/release）
    struct mutex            lock;           // 保护 attachments 的锁
    unsigned                vmapping_counter; // vmap 引用计数
    void                    *vmap_ptr;       // 内核虚拟映射地址
    ...
};
```

### 1.2 `struct dma_buf_attachment`——设备附加

```c
struct dma_buf_attachment {
    struct dma_buf          *dmabuf;        // 共享缓冲区
    struct device           *dev;           // 附加设备
    struct list_head        node;           // dma_buf->attachments 链表节点
    struct sg_table         *sgt;           // 设备 DMA 地址的 scatter-gather 表
    enum dma_data_direction  dir;           // DMA 方向
};
```

### 1.3 同步：dma_fence

```c
struct dma_fence {
    spinlock_t              lock;
    const struct dma_fence_ops *ops;
    unsigned long           flags;          // DMA_FENCE_FLAG_SIGNALED 等
    ktime_t                 timestamp;      // 时间戳
    int                     error;          // 错误码
};
```

## 2. 完整数据流

### 2.1 分配 + 导出

```
生产者驱动（如 video4linux）：
  dmabuf = dma_buf_export(exp_info)        // 创建 dma_buf
  dmabuf->ops = exp_info->ops
  fd = dma_buf_fd(dmabuf, O_CLOEXEC)       // 获取 fd
  // 将 fd 通过 V4L2 ioctl 传给用户空间

用户空间：
  将 fd 通过 DRM ioctl 传给 GPU 驱动
```

### 2.2 导入

```
消费者驱动（如 DRM/KMS）：
  dmabuf = dma_buf_get(fd)                 // fd → dma_buf
  attach = dma_buf_attach(dmabuf, dev)     // 附加到设备
  sg_table = dma_buf_map_attachment(attach, dir)  // 获取 DMA 地址
  // GPU 通过 sg_table 中的 DMA 地址访问缓冲区内容
```

### 2.3 同步

```
GPU 提交渲染命令后安装 dma_fence：
  fence = dma_fence_alloc(...)
  dma_fence_init(fence, &ops, lock, context, seqno)
  
下一帧生产者等待 GPU 完成：
  dma_fence_wait_timeout(fence, intr, timeout)
     → 如果 fence 未 signaled → 睡眠直到 GPU 中断触发信号
```

## 3. dma_fence 信号机制

```
dma_fence_signal(fence)                   // GPU 完成 → 信号
  └─ fence->flags |= DMA_FENCE_FLAG_SIGNALED
  └─ wake_up_all(&fence->wait_queue)
  └─ 回调链表遍历（cb_list）

dma_fence_wait(fence, intr)
  └─ 如果未 signaled → prepare_to_wait_exclusive
  └─ schedule()
  └─ 被 dma_fence_signal 唤醒
```

## 4. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct dma_buf` | include/linux/dma-buf.h | 核心 |
| `dma_buf_export()` | drivers/dma-buf/dma-buf.c | 分配 |
| `dma_buf_fd()` | drivers/dma-buf/dma-buf.c | 导出 fd |
| `dma_buf_get()` | drivers/dma-buf/dma-buf.c | 导入 |
| `dma_buf_attach()` | drivers/dma-buf/dma-buf.c | 附加 |
| `dma_buf_map_attachment()` | drivers/dma-buf/dma-buf.c | 获取 DMA 地址 |
| `struct dma_fence` | include/linux/dma-fence.h | 核心 |
| `dma_fence_signal()` | drivers/dma-buf/dma-fence.c | 信号 |
| `dma_fence_wait()` | drivers/dma-buf/dma-fence.c | 等待 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
