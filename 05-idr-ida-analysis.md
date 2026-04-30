# IDR / IDA — 内核整数到指针映射深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/idr.h` + `include/linux/ida.h` + `lib/idr.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**IDR（ID Roster）** 和 **IDA（ID Allocator）** 是内核的整数到指针映射机制，用于分配唯一的 ID（设备号、inode 号、文件描述符等）。IDR 从 Linux 4.1 起基于 XArray 重写，IDA 同样使用 XArray。

---

## 1. 核心数据结构

### 1.1 idr 结构

```c
// include/linux/idr.h — idr
struct idr {
    struct xarray    xa;          // XArray 存储
    unsigned int     id_base;     // 起始 ID（通常是 0）
    unsigned int     curr;        // 当前最大 ID（，下次分配的起始搜索点）
};
```

### 1.2 IDA 结构

```c
// include/linux/ida.h — ida
struct ida {
    struct xarray    xa;          // XArray 存储（ID → slot）
};
```

---

## 2. IDR API

### 2.1 idr_alloc — 分配 ID

```c
// lib/idr.c — idr_alloc_u32
int idr_alloc_u32(struct idr *idr, void *ptr, u32 *nextid,
                  unsigned long max, gfp_t gfp)
{
    // 1. 从 nextid 开始搜索
    unsigned int id = *nextid;

    // 2. 在 XArray 中查找第一个空闲位置
    //    xa_find_after(&idr->xa, &id, max, XA_PRESENT)
    //    如果 busy，继续找下一个

    // 3. 存储指针
    void *old = xa_store(&idr->xa, id, ptr, gfp);

    // 4. 如果 id >= idr->curr，更新 curr
    if (id >= idr->curr)
        idr->curr = id + 1;

    *nextid = id + 1;  // 返回下一个起始搜索点
    return 0;
}

// 简化版本：
int idr_alloc(struct idr *idr, void *ptr, int start, int end, gfp_t gfp)
{
    u32 id = start;
    return idr_alloc_u32(idr, ptr, &id, end - 1, gfp);
}
```

### 2.2 idr_find — 查找

```c
// lib/idr.c — idr_find
void *idr_find(const struct idr *idr, unsigned long id)
{
    // 直接从 XArray 查询
    return xa_load(&idr->xa, id);
}
```

### 2.3 idr_remove — 删除

```c
// lib/idr.c — idr_remove_u32
void idr_remove_u32(struct idr *idr, unsigned long id)
{
    // 从 XArray 中删除
    xa_erase(&idr->xa, id);

    // 如果 id < idr->curr，可能需要调整 curr（优化搜索起点）
    if (id < idr->curr)
        idr->curr = id;  // 保守策略：下次从更早位置搜索
}
```

---

## 3. IDA API

### 3.1 ida_alloc / ida_free

```c
// include/linux/ida.h — ida_alloc
int ida_alloc(struct ida *ida, gfp_t gfp)
{
    int id;

    // 1. 尝试分配
    //    XArray 使用特殊的标记表示"已删除"（IDA_FREE_MARK）
    //    所以可以区分"从未使用"和"已释放"

    id = xa_alloc_u32(&ida->xa, &id, ptr, XA_FLAGS_ALLOC, gfp);

    return id;
}

// 释放：
void ida_free(struct ida *ida, unsigned int id)
{
    // 标记为已释放
    xa_set_mark(&ida->xa, id, IDA_FREE_MARK);
    xa_erase(&ida->xa, id);
}
```

### 3.2 ida_simple_get — 范围分配

```c
// include/linux/ida.h — ida_simple_get
int ida_simple_get(struct ida *ida, unsigned int start, unsigned int end, gfp_t gfp)
{
    // 简化版本，自动处理 idr->nextid
    u32 id = start;
    int ret = idr_alloc_u32(&ida->idr, NULL, &id, end - 1, gfp);
    return ret ?: id;
}
```

---

## 4. 内核实际使用案例

### 4.1 TTY 次设备号

```c
// drivers/tty/tty_io.c — alloc_tty_struct
// 每个 TTY 设备有一个唯一的次设备号
dev_t tty_devnum(struct tty_struct *tty)
{
    return MKDEV(tty->driver->major, tty->index); // index = IDR 分配的 ID
}

// tty->index 是通过 idr_alloc() 分配的
static int tty_alloc_index(struct tty_driver *driver)
{
    int index = 0;
    idr_alloc_u32(&driver->ttys, NULL, &index, driver->type, GFP_KERNEL);
    return index;
}
```

### 4.2 NFS inode 编号

```c
// fs/nfs/inode.c — nfsi_alloc
// NFS inode 编号通过 IDR 映射到 nfs_inode 结构
nfsi->vfs_inode.i_ino = idr_alloc(&nfs_sb->s->s_idr, &nfsi->vfs_inode, ...);
```

### 4.3 DMA 描述符 ID

```c
// drivers/dma/pl330.c — pl330_submit_req
// DMA 请求通过 IDR 分配唯一 ID
req->id = idr_alloc(&pl330->used, req, 0, 0, GFP_NOWAIT);
```

---

## 5. XArray 底层

```
IDR 的存储（Linux 4.1+）：
  idr.xa 是一个多级 XArray
  层级：shift = 36 → 18 → 0（三层）

  查找 ID=0x12345：
    level 0: xa_node[ID >> 36] → 中层节点
    level 1: xa_node[(ID >> 18) & 0x7FFFF] → 叶子节点
    level 2: xa_value[ID & 0x3FFFF] → 存储的指针
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/idr.h` | `struct idr`、`idr_alloc`、`idr_find`、`idr_remove` |
| `include/linux/ida.h` | `struct ida`、`ida_alloc`、`ida_free` |
| `lib/idr.c` | `idr_alloc_u32`、`idr_remove_u32` |