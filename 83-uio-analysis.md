# UIO — 用户空间 I/O 驱动深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/uio/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**UIO** 允许用户空间驱动访问硬件中断和内存，无需编写内核驱动。

---

## 1. 核心数据结构

```c
// drivers/uio/uio.c — uio_device
struct uio_device {
    struct device           *dev;         // 设备
    int                     minor;         // 次设备号
    struct class            *class;        // 类
    struct uio_info        *info;         // UIO 信息
};

// drivers/uio/uio.c — uio_info
struct uio_info {
    const char              *name;         // 设备名
    struct uio_mem          mem[4];       // 映射的内存区域
    struct uio_port         port[4];      // 端口区域
    irqreturn_t (*handler)(int irq, struct uio_info *dev);
    long                    *irq;           // IRQ 编号
    unsigned long           irq_flags;   // 触发方式
    const char              *version;     // 版本
    struct device           *parent;      // 父设备
};
```

---

## 2. 用户空间 API

```c
// 1. 打开 UIO 设备
int fd = open("/dev/uio0", O_RDWR);

// 2. 获取 IRQ 信息
read(fd, &irq_count, sizeof(irq_count));

// 3. 映射内存
mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);

// 4. 等待并处理中断
while (1) {
    read(fd, &event, sizeof(event));  // 阻塞直到中断
    // 处理中断
}
```

---

## 3. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/uio/uio.c` | `uio_device`、`uio_info` |