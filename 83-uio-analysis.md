# Linux Kernel UIO (User I/O) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/uio/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. UIO 是什么？

**UIO（Userspace I/O）** 允许将硬件中断处理和设备寄存器访问放到**用户空间**，内核只做最少的绑定（地址空间映射、中断转发）。

---

## 1. 核心结构

```c
// drivers/uio/uio.c — uio_device
struct uio_device {
    struct kref         refcount;
    int                 minor;              // 次设备号
    struct cdev         *cdev;             // 字符设备
    struct device       *dev;              // class device
    struct uio_mem       mem[MAX_UIO_MAPS];  // 内存映射区
    int                 irq;                // 中断号
    unsigned long       irq_flags;          // 中断标志
    struct fasync_struct *async_queue;     // 异步队列
};

// drivers/uio/uio.c — uio_listener
struct uio_listener {
    struct uio_device   *dev;
    ssize_t             event_count;        // 事件计数
    struct fasync_struct *async_queue;
};
```

---

## 2. 内存映射

```c
// 用户空间 mmap：
// /dev/uio0 对应一段物理地址（设备寄存器）
// 用户通过 mmap() 直接访问设备寄存器，无需内核驱动介入

static int uio_mmap(struct vm_area_struct *vma)
{
    struct uio_device *dev = filp->private_data;

    // 将物理地址映射到用户空间
    // vma->vm_pgoff * PAGE_SIZE = 物理地址（mem[index].addr）
    remap_pfn_range(vma, vma->vm_start, vma->vm_pgoff,
            vma->vm_end - vma->vm_start, pgprot);
}
```

---

## 3. 中断处理

```c
// 用户空间通过 poll/select/epoll 等待中断：
int fd = open("/dev/uio0", O_RDWR);
struct pollfd pfd = { .fd = fd, .events = POLLIN };
poll(&pfd, 1, -1);  // 阻塞直到中断触发

// 内核中断处理：
irqreturn_t uio_interrupt(int irq, void *dev_id)
{
    // 1. 读取/清除中断状态
    // 2. 唤醒用户空间
    kill_fasync(&dev->async_queue, SIGIO, POLL_IN);
    return IRQ_HANDLED;
}
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `drivers/uio/uio.c` | `uio_mmap`、`uio_interrupt` |
| `drivers/uio/uio_pdrv.c` | platform 驱动 UIO 绑定 |
