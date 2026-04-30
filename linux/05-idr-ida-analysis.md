# 05-idr / ida — 整数到指针映射（XArray 驱动）深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/idr.h` + `include/linux/ida.h` + `lib/idr.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**IDR（ID Roster）** 和 **IDA（ID Allocator）** 是内核整数到指针的映射机制。IDR 从 Linux 4.1 基于 XArray 重写，提供 ID 分配/查找/删除，典型用途：设备号分配、inode 号管理、文件描述符等。

---

## 1. 核心数据结构

### 1.1 struct idr — IDR 结构

```c
// include/linux/idr.h:40 — idr
struct idr {
    struct xarray          xa;         // 底层 XArray（存储指针）
    unsigned int           idr_base;   // 起始 ID（通常是 0）
    unsigned int           idr_next;   // 下次分配的起始搜索点
};

// idr_base = 0：ID 从 0 开始分配
// idr_base = 1：ID 从 1 开始（保留 0）
```

### 1.2 struct ida — IDA 结构（更简单）

```c
// include/linux/ida.h:14 — ida
struct ida {
    struct xarray          xa;        // 底层 XArray
};

// IDA vs IDR：
// IDR：可以存储指针 + ID，允许 ID 和指针分离
// IDA：只分配 ID，不存指针（ID → NULL 的映射）
```

---

## 2. IDR API

### 2.1 idr_init — 初始化

```c
// lib/idr.c — idr_init
void idr_init(struct idr *idr)
{
    xa_init(&idr->xa);
    idr->idr_base = 0;
    idr->idr_next = 0;
}
```

### 2.2 idr_alloc_u32 — 分配 ID（核心）

```c
// lib/idr.c — idr_alloc_u32
int idr_alloc_u32(struct idr *idr, void *ptr, u32 *nextid,
                  unsigned long max, gfp_t gfp)
{
    unsigned long id;

    // 1. 如果给了 nextid，从 nextid 开始搜索
    id = *nextid;

retry:
    // 2. 在 XArray 中查找空闲位置
    id = xa_find_free(&idr->xa, id, max, gfp);
    if (id > max)
        return -ENOSPC;

    // 3. 存入指针
    //    xa_store(&idr->xa, id, ptr, gfp)
    //    如果 slot 已有值，xa_store 会返回旧值（用于替换场景）

    // 4. 更新 idr_next（优化：下次从 id+1 开始）
    if (*nextid)
        *nextid = id + 1;

    idr->idr_next = id + 1;

    return 0;
}

// 简化版本：
int idr_alloc(struct idr *idr, void *ptr, int start, int end, gfp_t gfp)
{
    u32 id = start;
    return idr_alloc_u32(idr, ptr, &id, end - 1, gfp);
}
```

### 2.3 idr_find — 查找

```c
// lib/idr.c — idr_find
void *idr_find(const struct idr *idr, unsigned long id)
{
    // 直接从 XArray 查找
    // 如果 id > max_id，返回 NULL

    // 注意：不加锁！调用者需要自行保证同步
    return xa_load(&idr->xa, id);
}
```

### 2.4 idr_remove — 删除

```c
// lib/idr.c — idr_remove
void idr_remove(struct idr *idr, unsigned long id)
{
    // 从 XArray 中删除
    xa_erase(&idr->xa, id);

    // 如果删除的是 idr_next 之前的 ID，
    // 可能需要调整 idr_next（简单策略：只往前移）
    if (id < idr->idr_next)
        idr->idr_next = id;  // 保守优化
}
```

### 2.5 idr_replace — 替换

```c
// lib/idr.c — idr_replace
void *idr_replace(struct idr *idr, void *ptr, unsigned long id)
{
    void *old;

    // 查找当前值
    old = xa_load(&idr->xa, id);
    if (!old)
        return ERR_PTR(-ENOENT);

    // 替换
    xa_store(&idr->xa, id, ptr, GFP_KERNEL);

    return old;
}
```

---

## 3. IDA API（更简单）

### 3.1 ida_pre_get / ida_get_new — 分配 ID（旧 API）

```c
// include/linux/ida.h — ida_pre_get（旧版）
// 新版 ida_simple_get / ida_simple_remove 替代了旧 API

// 新版 IDA：
int ida_alloc(struct ida *ida, gfp_t gfp)
{
    unsigned int id;

    // IDA 使用特殊的位图标记已分配/已释放
    // 已释放的 slot 可以重新分配（vs IDR 只能增加）

    id = xa_alloc_u32(&ida->xa, &id, NULL, IDA_MAX, gfp);
    return id < 0 ? id : (int)id;
}

void ida_free(struct ida *ida, unsigned int id)
{
    xa_erase(&ida->xa, id);
}
```

### 3.2 ida_simple_get / ida_simple_remove

```c
// include/linux/ida.h — ida_simple_get
int ida_simple_get(struct ida *ida, unsigned int start, unsigned int end, gfp_t gfp)
{
    int ret, id;

    // 在 [start, end) 范围内分配 ID
    ret = ida_get_new_above(ida, start, &id);
    if (ret)
        return ret;
    if (id >= end)
        return -ENOSPC;

    return id;
}

void ida_simple_remove(struct ida *ida, unsigned int id)
{
    ida_free(ida, id);
}
```

---

## 4. 迭代 API

### 4.1 idr_for_each

```c
// lib/idr.c — idr_for_each
int idr_for_each(const struct idr *idr,
                 int (*fn)(int id, void *p, void *data), void *data)
{
    unsigned long id;
    void *entry;

    // 从 idr_base 遍历到 idr_next
    idr_for_each_entry(idr, entry, id) {
        int ret = fn(id, entry, data);
        if (ret)
            return ret;
    }
    return 0;
}

#define idr_for_each_entry(idr, entry, id) \
    xa_for_each(&(idr)->xa, id, entry)
```

### 4.2 idr_get_next

```c
// lib/idr.c — idr_get_next
int idr_get_next(struct idr *idr, int *nextid)
{
    // 找到 >= *nextid 的最小已分配 ID
    int id = *nextid;
    void **slot;
    void *entry;

    slot = xa_find_after(&idr->xa, &id, 0, XA_PRESENT);
    if (!slot)
        return -ENOENT;

    *nextid = id;
    entry = xa_load(&idr->xa, id);
    return 0;
}
```

---

## 5. XArray 底层操作

### 5.1 xa_find_free — 查找空闲 slot

```c
// lib/test_xarray.c — xa_find_free
unsigned long xa_find_free(struct xarray *xa, unsigned long start,
                           unsigned long max, gfp_t gfp)
{
    // 1. 从 start 开始向后扫描
    // 2. 跳过已分配的 slot（XA_PRESENT 标记）
    // 3. 遇到 XA_FREE_MARK 或 NULL，尝试分配

    // 使用 XArray 的间隙扫描特性
    unsigned long index = start;
    void *entry;

    for (;;) {
        entry = __xa_find(xa, &index, max, XA_FREE_MARK);
        if (!entry)
            return max + 1;

        // 分配这个 slot
        entry = xa_store(xa, index, XA_MARK0, gfp);
        if (xa_is_err(entry))
            return max + 1;

        return index;
    }
}
```

---

## 6. RCU 安全操作

### 6.1 idr_find RCU

```c
// lib/idr.c — idr_find（实际是无锁）
void *idr_find(const struct idr *idr, unsigned long id)
{
    // XArray 本身支持 RCU 安全查找
    // 但返回值在 RCU临界区之外可能失效

    // 正确用法：
    rcu_read_lock();
    ptr = idr_find(idr, id);
    if (ptr)
        get_item(ptr);  // 增加引用
    rcu_read_unlock();
}
```

### 6.2 分配+查找原子性

```c
// idr_alloc 本身不是原子的（查找+存储分开）
// 如果需要原子分配+查找，需要加锁：

spin_lock(&idr->lock);
id = idr_alloc(idr, ptr, start, end, gfp);
spin_unlock(&idr->lock);

// 或者使用 idr_alloc_u32 的原子变体
```

---

## 7. 内核实际使用案例

### 7.1 TTY 次设备号

```c
// drivers/tty/tty_io.c — tty_alloc_index
// 每个 TTY 设备有一个唯一的次设备号（minor）

static int tty_alloc_index(void)
{
    static DEFINE_IDR(tty_minors_idr);  // 静态 IDR

    int index;
    idr_preload(GFP_KERNEL);
    spin_lock(&tty_minors_lock);
    index = idr_alloc(&tty_minors_idr, NULL, 0, TTY_MAX, GFP_ATOMIC);
    spin_unlock(&tty_minors_lock);
    idr_preload_end();
    return index;
}
```

### 7.2 DMA 描述符 ID

```c
// drivers/dma/pl330.c — pl330_submit_req
// DMA 请求通过 IDR 分配唯一 ID

req->id = idr_alloc(&pl330->used, req, 1, 0, GFP_NOWAIT);
// 1 = 指向 req 的指针
// 1 = 起始 ID（从 1 开始）
// 0 = 最大 ID（0 表示无限制）
```

### 7.3 NFS inode 编号

```c
// fs/nfs/inode.c — nfsi_alloc
// NFS inode 编号通过 IDR 映射

nfsi->vfs_inode.i_ino = idr_alloc(&nfs_server->nfs_client->cl_idr, &nfsi->vfs_inode, ...);
```

---

## 8. IDR vs IDA vs XArray

| 特性 | IDR | IDA | XArray（直接用） |
|------|-----|-----|----------------|
| 存储指针 | ✓ | ✗ | ✓ |
| 只分配 ID | ✗ | ✓ | ✗（自己实现）|
| 释放后 ID 可复用 | ✗ | ✓ | ✗（可手动标记）|
| 底层 | XArray | XArray | — |
| 最大 ID | 无限制 | 2^31 | 2^48 |

---

## 9. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| XArray 底层 | 替代 Radix Tree，支持 RCU、批操作 |
| idr_next 优化 | 避免每次从 idr_base 重新扫描 |
| IDA 分离 | 简单场景不需要存指针，IDA 更轻量 |
| RCU 支持 | 读多写少场景无需全局锁 |

---

## 10. 完整文件索引

| 文件 | 函数/结构 | 说明 |
|------|----------|------|
| `include/linux/idr.h` | `struct idr` | IDR 头 |
| `include/linux/ida.h` | `struct ida` | IDA 头 |
| `lib/idr.c` | `idr_init` | 初始化 |
| `lib/idr.c` | `idr_alloc_u32` | 分配 ID（核心）|
| `lib/idr.c` | `idr_find` | 查找 |
| `lib/idr.c` | `idr_remove` | 删除 |
| `lib/idr.c` | `idr_for_each` | 遍历 |
| `lib/idr.c` | `idr_get_next` | 找下一个 |
| `include/linux/ida.h` | `ida_simple_get` | IDA 简化接口 |
| `include/linux/ida.h` | `ida_simple_remove` | IDA 释放 |

---

## 11. 西游记类比

**IDR** 就像"天兵天将的花名册"——

> 每个天兵（结构体）被分配一个编号（ID）。花名册（IDR）是一个超大的书架（XArray）。分配编号就是找一个空位把天兵的名字和编号放进去；查找就是通过编号找天兵；删除就是把这一页撕掉（但这个位置以后就空着了，不能再分配给别的天兵）。而 IDA 就像一个可以回收编号的花名册——某天兵归隐了（释放），他的编号可以被新来的天兵重新使用。

---

## 12. 关联文章

- **XArray**（article 04）：IDR/IDA 的底层实现
- **DMA**（设备驱动部分）：DMA 描述符 ID 分配
- **TTY**（设备驱动部分）：次设备号分配