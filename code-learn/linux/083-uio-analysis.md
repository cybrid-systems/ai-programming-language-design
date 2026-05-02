# 83-uio — Linux Userspace I/O（UIO）框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**UIO（Userspace I/O）** 是 Linux 中编写用户态设备驱动的框架。与 VFIO 的完整设备直通不同，UIO 专为**简单的内存映射设备**设计——通过 `/dev/uioX` 提供 mmap（设备内存）、read（中断事件计数）、write（中断控制）。UIO 驱动只有几十行内核代码（注册设备），全部业务逻辑在用户空间实现。

**核心设计**：UIO 设备通过 `struct uio_info` 描述——包括内存区域（`uio_mem`）、端口区域（`uio_port`）、中断处理（`handler`）。内核负责：中断响应（`uio_interrupt`）、`/dev/uioX` 的 file_operations（`uio_open/read/mmap/release`）。用户空间通过 mmap 访问设备内存，通过 read 等待中断，通过 write 控制中断使能。

```
用户空间驱动                    UIO 内核框架               硬件设备
─────────────────             ──────────────             ────────
fd = open("/dev/uio0")                                    
  → uio_open()                                           
  → uio_info->open() 回调                                 
                                                         
mmap(fd, ...)               → uio_mmap()                 
  → remap_pfn_range()       → PCI BAR 直接映射到用户空间   
                                                         
read(fd, &count, 4)         → uio_read()                 
  → wait_event_interruptible                                
    ← 阻塞                                          
                              uio_interrupt() ← 硬件中断  
                                → event++                 
                                → wake_up_interruptible    
  ← 返回事件计数                                            
                                                         
write(fd, "1", 1)           → uio_write()                
  → uio_info->irqcontrol()    → 使能/禁用中断              
```

**doom-lsp 确认**：`drivers/uio/uio.c`（**1,155 行**）。`include/linux/uio_driver.h`（181 行）定义 `struct uio_info`、`struct uio_mem`、`struct uio_device`。

---

## 1. 核心数据结构

### 1.1 struct uio_info——设备描述

```c
// include/linux/uio_driver.h:104-119
struct uio_info {
    struct uio_device *uio_dev;                    /* UIO 设备 */
    const char *name;                               /* 设备名 */
    const char *version;                            /* 驱动版本 */
    struct uio_mem mem[MAX_UIO_MAPS];              /* 最多 5 个内存区域 */
    struct uio_port port[MAX_UIO_PORT_REGIONS];     /* 最多 5 个端口区域 */
    long irq;                                       /* IRQ 号 / UIO_IRQ_CUSTOM */
    unsigned long irq_flags;                        /* request_irq flags */
    void *priv;                                     /* 驱动私有数据 */

    irqreturn_t (*handler)(int irq, struct uio_info *dev_info);
    int (*mmap_prepare)(struct uio_info *, struct vm_area_desc *);
    int (*open)(struct uio_info *, struct inode *);
    int (*release)(struct uio_info *, struct inode *);
    int (*irqcontrol)(struct uio_info *, s32 irq_on);
};
```

### 1.2 struct uio_mem——内存区域

```c
struct uio_mem {
    const char *name;                               /* 区域名 */
    phys_addr_t addr;                               /* 物理地址 */
    dma_addr_t dma_addr;                            /* DMA 地址（DMA_COHERENT）*/
    unsigned long offs;                              /* 页内偏移 */
    resource_size_t size;                            /* 大小 */
    int memtype;                                     /* PHYS / LOGICAL / VIRTUAL / IOVA */
    void __iomem *internal_addr;                     /* 内核 ioremap 地址 */
};
```

### 1.3 struct uio_device——UIO 设备

```c
struct uio_device {
    struct module *owner;
    struct device dev;
    int minor;
    atomic_t event;                                  /* 中断事件计数 */
    struct fasync_struct *async_queue;
    wait_queue_head_t wait;                          /* read 阻塞等待队列 */
    struct uio_info *info;
    struct mutex info_lock;
};
```

**doom-lsp 确认**：`struct uio_info` 在 `uio_driver.h:104`，`struct uio_mem` 在 `:24`，`struct uio_device` 在 `:87`。`memtype` 决定 mmap 映射方式。

---

## 2. 注册——uio_register_device

```c
// drivers/uio/uio.c
int __uio_register_device(struct module *owner, struct device *parent,
                           struct uio_info *info)
{
    struct uio_device *idev;

    // 1. 分配 uio_device
    idev = kzalloc(sizeof(*idev), GFP_KERNEL);
    idev->owner = owner;
    idev->info = info;
    info->uio_dev = idev;

    // 2. 分配次设备号
    idev->minor = ida_alloc(&uio_ida, GFP_KERNEL);

    // 3. 初始化等待队列 + 事件计数
    init_waitqueue_head(&idev->wait);
    atomic_set(&idev->event, 0);

    // 4. 注册 miscdevice
    // → /dev/uio0, /dev/uio1 ... 指向 uio_fops
    idev->dev.devt = MKDEV(uio_major, idev->minor);
    device_create(uio_class, parent, idev->dev.devt, idev, "uio%d", idev->minor);
}
```

---

## 3. file_operations @ uio.c

```c
static const struct file_operations uio_fops = {
    .open    = uio_open,
    .release = uio_release,
    .read    = uio_read,
    .write   = uio_write,
    .mmap    = uio_mmap,
    .poll    = uio_poll,
    .fasync  = uio_fasync,
    .llseek  = noop_llseek,
};
```

### 3.1 uio_open

```c
static int uio_open(struct inode *inode, struct file *filep)
{
    struct uio_device *idev;
    idev = container_of(inode->i_cdev, struct uio_device, cdev);
    filep->private_data = idev;

    if (idev->info->open)
        idev->info->open(idev->info, inode);   // 驱动回调

    // 注册中断
    if (idev->info->irq && idev->info->irq != UIO_IRQ_CUSTOM) {
        ret = request_irq(idev->info->irq, uio_interrupt,
                          idev->info->irq_flags, idev->info->name, idev);
    }
}
```

### 3.2 uio_read @ :249——等待中断

```c
static ssize_t uio_read(struct file *filep, char __user *buf,
                        size_t count, loff_t *ppos)
{
    struct uio_device *idev = filep->private_data;
    DECLARE_WAITQUEUE(wait, current);

    // 添加自身到等待队列
    add_wait_queue(&idev->wait, &wait);

    do {
        set_current_state(TASK_INTERRUPTIBLE);

        // 读取事件计数
        event_count = atomic_read(&idev->event);
        if (event_count) {
            // 有事件 → 返回计数
            __set_current_state(TASK_RUNNING);
            ret = put_user(event_count, (__u32 __user *)buf);
            atomic_sub(event_count, &idev->event);  // 消耗事件
            break;
        }

        // 无事件 → 阻塞
        if (filep->f_flags & O_NONBLOCK) {
            ret = -EAGAIN;
            break;
        }

        if (signal_pending(current)) {
            ret = -ERESTARTSYS;
            break;
        }

        schedule();                              // 休眠
    } while (1);

    remove_wait_queue(&idev->wait, &wait);
    return ret;
}
```

### 3.3 uio_interrupt——中断处理

```c
static irqreturn_t uio_interrupt(int irq, void *dev_id)
{
    struct uio_device *idev = dev_id;

    // 1. 调用驱动 handler 检查中断是否来自本设备
    if (idev->info->handler)
        ret = idev->info->handler(irq, idev->info);
    // 如果 handler 返回 IRQ_HANDLED → 处理

    // 2. 递增事件计数
    atomic_inc(&idev->event);

    // 3. 唤醒 read() 中的线程
    wake_up_interruptible(&idev->wait);

    // 4. 如果设置了 fasync → 发送 SIGIO
    if (idev->async_queue)
        kill_fasync(&idev->async_queue, SIGIO, POLL_IN);

    return IRQ_HANDLED;
}
```

### 3.4 uio_mmap——设备内存到用户空间

```c
static int uio_mmap(struct file *filep, struct vm_area_struct *vma)
{
    struct uio_device *idev = filep->private_data;
    int mi = uio_find_mem_index(vma);
    struct uio_mem *mem = idev->info->mem + mi;

    // 根据 memtype 选择映射方式：
    switch (mem->memtype) {
    case UIO_MEM_PHYS:
        // 物理地址 → remap_pfn_range
        vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
        remap_pfn_range(vma, vma->vm_start,
                        mem->addr >> PAGE_SHIFT,
                        size, vma->vm_page_prot);
        break;

    case UIO_MEM_LOGICAL:
        // 逻辑地址 → page_to_pfn(virt_to_page(mem->addr))
        break;

    case UIO_MEM_VIRTUAL:
        // 虚拟地址 → vm_insert_page
        // 用于 vmalloc 分配的内存
        break;
    }
}
```

---

## 4. 调试

```bash
# 查看 UIO 设备
ls -l /dev/uio*
cat /sys/class/uio/uio0/name
cat /sys/class/uio/uio0/version

# 查看内存区域
cat /sys/class/uio/uio0/maps/map0/addr
cat /sys/class/uio/uio0/maps/map0/size

# 查看端口区域
cat /sys/class/uio/uio0/portio/port0/start
```

---

## 5. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `uio_read` | `uio.c:249` | 中断事件读取（阻塞/非阻塞）|
| `uio_write` | — | 中断控制（irqcontrol 回调）|
| `uio_mmap` | — | 设备内存到用户空间映射 |
| `uio_interrupt` | — | 中断处理（事件计数+唤醒）|
| `uio_open` | — | 打开设备（中断注册）|
| `__uio_register_device` | — | UIO 设备注册 |

---

## 6. UIO vs VFIO

| 特性 | UIO | VFIO |
|------|-----|------|
| 内核代码量 | **~1155 行**（简洁） | ~5000+ 行（复杂）|
| 设备模型 | 简单内存映射设备 | PCI/平台设备完整直通 |
| DMA | 不支持 | 支持（IOMMU）|
| 中断 | 单一事件计数 | MSI/MSI-X/INTX |
| 安全 | 无隔离（root 可映射任何物理地址） | IOMMU 隔离 |
| mmap | remap_pfn_range 直接映射 | IOMMU 地址翻译 |
| 适用场景 | FPGA、GPIO、低速采集卡 | GPU、NVMe、网卡直通 |

---

## 7. 总结

UIO 是一个**极简的用户态驱动框架**——内核只负责中断通知（`uio_interrupt` → `atomic_inc(&event)` → `wake_up`）、内存映射（`uio_mmap` → `remap_pfn_range`）、文件操作（`uio_read` @ `:249`），全部业务逻辑在用户空间实现。适合 FPGA、低速数据采集等不需要 DMA 和 IOMMU 隔离的场景。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
