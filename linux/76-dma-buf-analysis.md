# 76-dma-buf — Linux DMA-BUF 共享缓冲区框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**dma-buf** 是 Linux 内核中**跨驱动、跨设备共享 DMA 缓冲区**的框架。它允许一个设备驱动（如 GPU、V4L2 摄像头、DRM 显示控制器）导出其 DMA 缓冲区，另一个设备驱动导入并使用，实现零拷贝数据传输。

**核心设计**：dma-buf 通过 `struct dma_buf` 表示一个共享的物理内存缓冲区。导出者（exporter）调用 `dma_buf_export()` 创建 dma_buf，获取 fd 传递给用户空间；用户空间将 fd 传递给导入者（importer），导入者调用 `dma_buf_get()` 获取 `struct dma_buf` 并通过 `dma_buf_attach()` 映射。

```
导出者（GPU）                      dma-buf 核心                导入者（显示控制器）
    │                                  │                            │
dma_buf_export(exp_info)               │                            │
  → alloc dma_buf                     │                            │
  → anon_inode_getfd(dmabuf fd)       │                            │
    ↓                                  │                            │
用户空间传递 fd ──────────────────→    │                            │
                                      │                            │
                            dma_buf_get(fd) ────────────────→      │
                              → get_file(fd)                       │
                              → dma_buf = file->private_data       │
                              │                            dma_buf_attach(dmabuf, dev)
                              │                              → 导出者回调 attach()
                              │                              → 返回 dma_buf_attachment
                              │                            dma_buf_map_attachment(attach)
                              │                              → 导出者回调 map_dma_buf()
                              │                              → 返回 sg_table（DMA 地址）
                              │                            ← 驱动使用 sg_table 做 DMA
```

**doom-lsp 确认**：核心在 `drivers/dma-buf/dma-buf.c`（**1,848 行**，**138 个符号**）。同步原语 `dma-fence.c`（1,208 行）和 `dma-resv.c`（819 行）。

---

## 1. 核心数据结构

### 1.1 struct dma_buf — DMA 缓冲区

```c
// include/linux/dma-buf.h
struct dma_buf {
    size_t size;                             /* 缓冲区大小 */
    const struct dma_buf_ops *ops;           /* 导出者操作 */
    struct file *file;                        /* anon_inode file */
    struct list_head attachments;             /* 附着列表 */
    struct dma_resv *resv;                    /* 预留对象（fence 同步）*/

    void *priv;                              /* 导出者私有数据 */

    const char *name;
    spinlock_t name_lock;
    struct module *owner;
};
```

### 1.2 struct dma_buf_attachment — 附着

```c
struct dma_buf_attachment {
    struct dma_buf *dmabuf;                  /* 关联的 dmabuf */
    struct device *dev;                       /* 导入者设备 */
    const struct dma_buf_attach_ops *ops;
    struct list_head node;                    /* dmabuf->attachments 节点 */

    bool peer2peer;                           /* 设备间直接 DMA 支持 */
    bool dma_map;                             /* DMA 映射状态 */
};
```

### 1.3 struct dma_buf_ops — 导出者操作

```c
struct dma_buf_ops {
    int (*attach)(struct dma_buf *, struct dma_buf_attachment *);
    void (*detach)(struct dma_buf *, struct dma_buf_attachment *);
    struct sg_table *(*map_dma_buf)(struct dma_buf_attachment *,
                                     enum dma_data_direction);
    void (*unmap_dma_buf)(struct dma_buf_attachment *,
                          struct sg_table *, enum dma_data_direction);
    int (*mmap)(struct dma_buf *, struct vm_area_struct *);
    int (*vmap)(struct dma_buf *, struct iosys_map *);
    void (*vunmap)(struct dma_buf *, struct iosys_map *);
};
```

---

## 2. 核心流程

### 2.1 dma_buf_export @ :708——导出

```c
struct dma_buf *dma_buf_export(const struct dma_buf_export_info *exp_info)
{
    /* 1. 分配 dma_buf */
    dmabuf = kzalloc(sizeof(*dmabuf), GFP_KERNEL);
    dmabuf->priv = exp_info->priv;
    dmabuf->ops = exp_info->ops;
    dmabuf->size = exp_info->size;
    dmabuf->owner = exp_info->owner;

    /* 2. 初始化预留对象（fence 同步）*/
    dmabuf->resv = exp_info->resv ?: &dmabuf->resv_shared;

    /* 3. 创建 anon_inode file */
    file = dma_buf_getfile(dmabuf, exp_info->flags);
    dmabuf->file = file;

    /* 4. 添加到全局列表 */
    __dma_buf_list_add(dmabuf);

    return dmabuf;
}
```

### 2.2 dma_buf_attach——附着

```c
struct dma_buf_attachment *dma_buf_attach(struct dma_buf *dmabuf,
                                           struct device *dev)
{
    /* 1. 分配 attachment */
    attach = kzalloc(sizeof(*attach), GFP_KERNEL);
    attach->dev = dev;
    attach->dmabuf = dmabuf;

    /* 2. 调用导出者回调 */
    if (dmabuf->ops->attach)
        dmabuf->ops->attach(dmabuf, attach);

    /* 3. 加入附着列表 */
    list_add(&attach->node, &dmabuf->attachments);
}
```

### 2.3 dma_buf_map_attachment——获取 DMA 地址

```c
struct sg_table *dma_buf_map_attachment(struct dma_buf_attachment *attach,
                                         enum dma_data_direction direction)
{
    /* 调用导出者回调 → 返回 sg_table */
    sg_table = dmabuf->ops->map_dma_buf(attach, direction);

    if (!attach->peer2peer)
        dma_map_sgtable(dev, sg_table, direction, 0);  // DMA 映射

    return sg_table;
}
```

---

## 3. 同步——dma-fence @ dma-fence.c

```c
// dma-fence 是 GPU/显示器等异步操作的完成通知原语
// 类似于"异步操作完成信号"——一个 fence 在硬件操作完成时 signaled

struct dma_fence {
    spinlock_t *lock;
    const struct dma_fence_ops *ops;
    struct list_head cb_list;              // 回调列表
    u64 seqno;                              // 序列号
    unsigned long flags;                    // DMA_FENCE_FLAG_*
    unsigned long error;
    struct rcu_head rcu;
};

// dma_resv — 管理多个 fence（读 fence + 写 fence）
struct dma_resv {
    struct dma_resv_list *fence;           // 独占写 fence
    struct dma_fence *fence_excl;          // 已废弃
    struct dma_fence __rcu *fence_excl_rcu;
    struct dma_resv_list *fence;
    seqcount_ww_mutex_t seq;
};
```

---

## 4. fd 传递

```c
// 导出者：
int dmabuf_fd = dma_buf_fd(dmabuf, O_CLOEXEC);
// 写入 socket / 通过 binder 传递给另一个进程

// 导入者（另一个进程）：
struct dma_buf *dmabuf = dma_buf_get(dmabuf_fd);
// 使用 dmabuf
dma_buf_put(dmabuf);    // 减少引用
close(dmabuf_fd);
```

---

## 5. 总结

dma-buf 通过 `dma_buf_export`（`:708`）创建共享缓冲区，通过 fd 传递到另一个进程或驱动。`dma_buf_attach` / `dma_buf_map_attachment` 将缓冲区映射到导入者的 DMA 地址空间。`dma_fence` 和 `dma_resv` 提供异步操作同步。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
