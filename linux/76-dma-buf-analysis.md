# 76-DMA-Buf — 跨设备缓冲区共享深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/dma-buf/dma-buf.c` + `include/linux/dma-buf.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**DMA-Buf** 是 Linux 内核用于跨设备共享缓冲区的框架。GPU、摄像头、编码器等硬件需要共享大量数据，DMA-Buf 通过统一的文件描述符接口，让不同驱动创建的缓冲区可以安全地传递给彼此。

---

## 1. 核心数据结构

### 1.1 struct dma_buf — DMA 缓冲区

```c
// include/linux/dma-buf.h — dma_buf
struct dma_buf {
    // 文件接口
    struct file             *file;             // 匿名inode文件（fd 用于用户空间共享）
    struct dentry           *exp_name_entry;   // debugfs 入口

    // 缓冲区信息
    size_t                  size;               // 缓冲区大小（字节）
    unsigned long           flags;              // DMA_BUF_* 标志
    void                   *priv;               // 导出器私有数据

    // 操作函数表
    const struct dma_buf_ops *ops;            // 导出器实现

    // 名称（用于调试）
    spinlock_t              name_lock;
    char                    *name;

    // 全局链表（用于 debug）
    struct list_head        list_node;          // 接入 dmabuf_list

    // reservation object（用于同步）
    struct dma_resv         *resv;              // 围栏同步
};
```

### 1.2 struct dma_buf_attachment — 设备附着

```c
// include/linux/dma-buf.h — dma_buf_attachment
struct dma_buf_attachment {
    struct dma_buf         *dmabuf;           // 指向 dma_buf
    struct device         *dev;              // 附着设备

    // scatter-gather 表
    struct sg_table        *sgt;              // 映射后的 SG 表
    enum dma_data_direction dir;              // DMA 方向（TO_DEVICE / FROM_DEVICE）

    // 导出器私有
    void                   *priv;             // 导出器私有数据

    // 链表
    struct list_head        node;              // 接入 dmabuf->attachments
};
```

### 1.3 struct dma_buf_ops — 操作函数表

```c
// include/linux/dma-buf.h — dma_buf_ops
struct dma_buf_ops {
    // 附着/分离
    int   (*attach)(struct dma_buf *, struct dma_buf_attachment *);
    void  (*detach)(struct dma_buf *, struct dma_buf_attachment *);

    //  pinning（固定内存）
    int   (*pin)(struct dma_buf_attachment *);
    void  (*unpin)(struct dma_buf_attachment *);

    // 映射（CPU 访问）
    void *(*vmap)(struct dma_buf *);
    void  (*vunmap)(struct dma_buf *, void *vaddr);

    // DMA 映射（设备访问）
    struct sg_table *(*map_dma_buf)(struct dma_buf_attachment *,
                                     enum dma_data_direction);
    void  (*unmap_dma_buf)(struct dma_buf_attachment *,
                           struct sg_table *,
                           enum dma_data_direction);

    // 释放
    void  (*release)(struct dma_buf *);

    // mmap（用户空间映射）
    int   (*mmap)(struct dma_buf_attachment *, struct vm_area_struct *);
};
```

---

## 2. 创建 DMA-Buf

### 2.1 dma_buf_export — 导出缓冲区

```c
// drivers/dma-buf/dma-buf.c — dma_buf_export
struct dma_buf *dma_buf_export(const struct dma_buf_export_info *exp_info)
{
    struct dma_buf *dmabuf;
    struct file *file;

    // 1. 分配 dma_buf
    dmabuf = kzalloc(sizeof(*dmabuf), GFP_KERNEL);

    // 2. 创建匿名 inode（用于 fd）
    file = anon_inode_getfile("dmabuf", &dma_buf_fops, dmabuf, O_RDWR);

    dmabuf->file = file;
    dmabuf->size = exp_info->size;
    dmabuf->ops = exp_info->ops;
    dmabuf->priv = exp_info->priv;

    // 3. 初始化 reservation（围栏）
    dmabuf->resv = dma_resv_alloc();
    if (!dmabuf->resv)
        goto err;

    // 4. 加入全局链表
    __dma_buf_list_add(dmabuf);

    return dmabuf;

err:
    fput(file);
    kfree(dmabuf);
    return ERR_PTR(-ENOMEM);
}
```

---

## 3. 跨设备共享流程

```
场景：GPU 渲染后，摄像头 ISP 处理图像

1. GPU 驱动创建 DMA-Buf：
   dmabuf = dma_buf_export(&exp_info);
   fd = dma_buf_fd(dmabuf);  // 获得 fd

2. GPU 填充数据：
   attach → pin → map_dma_buf → DMA 传输

3. 通过 IPC（binder/Unix fd）把 fd 传给 ISP 驱动：
   recv_fd(fd);

4. ISP 驱动接入：
   dmabuf = dma_buf_get(fd);
   attach → pin → map_dma_buf → ISP 读取

5. 同步（dma_resv）：
   GPU 渲染完成 → dma_resv_lock() → set_fence() → unlock
   ISP 等围栏 → dma_resv_wait() → 读数据

6. 双方释放：
   unmap_dma_buf → unpin → detach → dma_buf_put()
```

---

## 4. DMA 映射

### 4.1 dma_buf_map_attachment — 映射缓冲区

```c
// drivers/dma-buf/dma-buf.c — dma_buf_map_attachment
struct sg_table *dma_buf_map_attachment(struct dma_buf_attachment *attach,
                                        enum dma_data_direction dir)
{
    struct sg_table *sgt;

    // 调用导出器的 map_dma_buf
    sgt = attach->dmabuf->ops->map_dma_buf(attach, dir);
    if (!sgt)
        return ERR_PTR(-ENOMEM);

    attach->sgt = sgt;
    attach->dir = dir;

    return sgt;
}
```

---

## 5. Reservation Object（同步围栏）

### 5.1 dma_resv — 围栏同步

```c
// include/linux/dma-resv.h
struct dma_resv {
    struct ww_acquire_ctx  *ctx;    // 指向 ww 锁上下文
    struct dma_fence       *fence[2]; // [0]=shared, [1]=exclusive
};

// 用于跨设备同步：
//   GPU 完成渲染 → set exclusive fence
//   ISP 等待该 fence → 然后读取数据
```

---

## 6. debugfs 接口

```bash
# 查看所有 DMA-Buf：
ls /sys/kernel/debug/dma_buf/

# 每 dmabuf 有：
#   attached_devices   — 附着的设备
#   size              — 缓冲区大小
#   name              — 名称
#   fences            — reservation 围栏
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/dma-buf/dma-buf.c` | `dma_buf_export`、`dma_buf_map_attachment`、`__dma_buf_list_add` |
| `include/linux/dma-buf.h` | `struct dma_buf`、`struct dma_buf_attachment`、`struct dma_buf_ops` |

---

## 8. 西游记类比

**DMA-Buf** 就像"取经队伍的物资交换中心"——

> 悟空（GPU）从龙宫借来一块宝石（DMA-Buf），需要在天庭（ISP 处理器）和花果山（显示器）之间传递。以前每个部门都有自己的物资系统，借宝石要来回折腾。DMA-Buf 建立了统一的物资交换标准：宝石先在交换中心登记（dma_buf_export），获得一个交换凭证（fd）。每个部门在凭证上签字确认收到（attach），交换中心会记录谁借了（sg_table 映射）。如果宝石还在被占用（dma_resv fence），其他部门只能等着。这就是 GPU 和摄像头之间共享图像数据的方式——不用复制，直接共享同一块物理内存。

---

## 9. 关联文章

- **PCI**（article 116）：DMA 硬件基础
- **VFIO**（article 77/132）：用户空间设备访问