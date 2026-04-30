# UIO — 用户空间 I/O 驱动深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/uio/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**UIO**（Userspace I/O）允许编写内核驱动的最小部分（中断处理），而将设备访问逻辑放在用户空间。

---

## 1. 核心数据结构

### 1.1 uio_port — 端口

```c
// drivers/uio/uio.c — uio_port
struct uio_port {
    const char             *name;          // 端口名
    unsigned long           start;         // 起始地址
    int                     size;          // 大小
    void __iomem           *map;           // 映射的 I/O 内存
};
```

### 1.2 uio_mem — 内存区域

```c
// drivers/uio/uio.c — uio_mem
struct uio_mem {
    const char             *name;          // 区域名
    unsigned long           addr;         // 用户可见的地址
    unsigned long           size;         // 大小
    void __iomem           *internal_addr; // 内核内部地址
    int                     memtype;      // 类型（UIO_MEM_*
    struct page             **pages;      // 页数组
};
```

---

## 2. uio_device — UIO 设备

```c
// drivers/uio/uio.c — uio_device
struct uio_device {
    struct device           dev;           // 设备
    int                     minor;         // 次设备号
    struct cdev             cdev;          // 字符设备

    // 内存区域
    int                     memtype;        // 类型
    int                     num_ports;     // 端口数
    struct uio_mem          *ports;         // 端口数组

    // 中断
    wait_queue_head_t       wait;          // 中断等待队列
    int                     event;         // 中断事件计数

    // 文件
    struct fasync_struct   *async_queue;   // 异步通知
};
```

---

## 3. 中断处理

### 3.1 uio_interrupt — 中断处理

```c
// drivers/uio/uio.c — uio_interrupt
static irqreturn_t uio_interrupt(int irq, void *dev_id)
{
    struct uio_device *idev = dev_id;

    // 1. 检查是否是有效中断
    irqreturn_t ret = IRQ_NONE;

    // 2. 获取用户空间的处理函数
    //    用户程序通过 mmap 访问设备内存
    //    用户程序 read() 阻塞，直到中断发生

    // 3. 唤醒用户空间
    ret = IRQ_HANDLED;
    wake_up(&idev->wait);

    return ret;
}
```

### 3.2 用户空间使用

```c
// 用户空间驱动示例：
int fd = open("/dev/uio0", O_RDWR);

// 读取中断（阻塞直到中断）
read(fd, &intr_count, sizeof(intr_count));

// 访问设备内存
void *mapped = mmap(0, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
volatile uint32_t *regs = mapped;

// 读取寄存器
uint32_t status = regs[0];

// 清除中断
regs[1] = 0x01;
```

---

## 4. mmap — 内存映射

```c
// drivers/uio/uio.c — uio_mmap
static int uio_mmap(struct file *filp, struct vm_area_struct *vma)
{
    struct uio_device *idev = filp->private_data;
    struct uio_mem *mem;
    int mi = vma->vm_pgoff;

    // 查找对应的内存区域
    mem = &idev->ports[mi];

    // 映射到用户空间
    vma->vm_ops = &uio_vm_ops;
    vma->vm_flags |= VM_IO;

    return remap_pfn_range(vma, vma->vm_start,
                           mem->addr >> PAGE_SHIFT,
                           vma->vm_end - vma->vm_start,
                           vma->vm_page_prot);
}
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/uio/uio.c` | `struct uio_device`、`uio_interrupt`、`uio_mmap` |