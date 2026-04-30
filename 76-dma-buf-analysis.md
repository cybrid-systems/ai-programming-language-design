# dma-buf — 缓冲区共享深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/dma-buf/dma-buf.c` + `include/linux/dma-buf.h`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**dma-buf** 允许不同驱动/CPU 共享同一块内存，用于 GPU、摄像头、编码器等场景的零拷贝数据交换。

---

## 1. 核心数据结构

### 1.1 dma_buf — 共享缓冲区

```c
// include/linux/dma-buf.h — dma_buf
struct dma_buf {
    // 长度
    size_t                  size;         // 缓冲区大小

    // 文件描述符（用于跨进程传递）
    struct file             *file;        // 匿名文件

    // 操作函数表
    const struct dma_buf_ops *ops;       // 操作函数

    // 缓冲区
    void                    *vaddr;      // 虚拟地址
    struct dma_resv          *resv;      // 同步和 fence

    // 导出器
    struct device           *dev;        // 关联设备
    const char               *name;       // 名称（调试）

    // 引用计数
    struct kref             kref;         // 引用计数
    struct reservation_object *resv;     // reservation/fence
};
```

### 1.2 dma_buf_ops — 操作函数表

```c
// include/linux/dma-buf.h — dma_buf_ops
struct dma_buf_ops {
    int                     (*attach)(struct dma_buf *, struct device *,
                                       struct dma_buf_attachment *);
    void                    (*detach)(struct dma_buf *, struct dma_buf_attachment *);

    struct sg_table *       (*map)(struct dma_buf_attachment *, enum dma_data_direction);
    void                    (*unmap)(struct dma_buf_attachment *, struct sg_table *);

    void *                  (*mmap)(struct dma_buf *, struct vm_area_struct *);
    int                     (*vmap)(struct dma_buf *, void **);
    void                    (*vunmap)(struct dma_buf *, void *);
};
```

---

## 2. 共享流程

```c
// 1. 导出设备分配缓冲区
struct dma_buf *export_dev_alloc(struct device *dev, size_t size)
{
    return dma_buf_export(dev, &exp_info, O_CLOEXEC, size);
}

// 2. 共享给其他设备
int share_fd(int fd)
{
    // 通过 fd 传递（SCM 或 binder IPC）
    // fd 传递给另一个进程
}

// 3. 接收方 attach 并 map
struct dma_buf_attachment *attach = dma_buf_attach(buf, dev);
struct sg_table *sgt = dma_buf_map_attachment(attach, DMA_TO_DEVICE);
```

---

## 3. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/dma-buf/dma-buf.c` | `dma_buf_export`、`dma_buf_attach` |
| `include/linux/dma-buf.h` | `struct dma_buf`、`struct dma_buf_ops` |