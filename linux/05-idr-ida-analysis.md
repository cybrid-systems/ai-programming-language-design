# 05-idr-ida — ID 分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**IDR（ID Radix）** 和 **IDA（ID Allocator）** 是 Linux 内核中用于 `整数 ID ↔ 指针` 映射的辅助设施。IDR 维护一个将整数 ID 映射到 `void*` 的关联数组，IDA 则只负责分配/回收整数 ID 本身（不关联指针）。

从 Linux 4.19 开始，IDR 的底层实现已经迁移到 XArray。但 IDR 和 IDA 作为便利的"整数 ID 管理器"接口，仍然被广泛使用。

doom-lsp 确认 `include/linux/idr.h` 定义了约 96 个符号（其中暴露的 API 约 20 个），实现位于 `lib/idr.c`。

---

## 1. 核心数据结构

### 1.1 struct idr（`include/linux/idr.h:35`）

```c
struct idr {
    struct xarray  idr_xa;   // 底层用 XArray 存储
    unsigned int   idr_next; // 下��分配的 hint（IDA 保持）
};
```

IDR 本质上就是 XArray 的封装。`idr_xa` 存储 `id → void*` 映射，`idr_next` 记录上次分配的位置，用于 hint 优化。

### 1.2 struct ida（`include/linux/idr.h:48`）

```c
struct ida {
    struct xarray  xa;       // 底层存储：bitmap 页
};
```

IDA 的 XArray 存储的是 **bitmap 页**（`struct ida_bitmap`），每页包含一个 1024 位的 bitmap，用于跟踪哪些 ID 已被分配。

---

## 2. IDR API

### 2.1 idr_alloc（`lib/idr.c`）

```c
int idr_alloc(struct idr *idr, void *ptr, int start, int end, gfp_t gfp);
```

分配一个 `[start, end)` 范围内的 ID，将其映射到 `ptr`。返回分配的 ID，或负数错误码。

内部流程（doom-lsp 追踪）：

```
idr_alloc(idr, ptr, start, end, gfp)
  └─ idr_alloc_u32(idr, &id, ptr, IDR_MAX, gfp)
       ├─ idr_get_free(&idr->idr_xa, &id, IDR_MAX, gfp)
       │    └─ xa_alloc(&idr->idr_xa, &id, ...)
       │         └─ XArray 内部在树中查找空闲槽
       │
       └─ if (id > end) return -ENOSPC  ← 超过范围
       └─ return id
```

### 2.2 idr_find（`include/linux/idr.h:128`）

```c
void *idr_find(struct idr *idr, unsigned long id)
{
    return xa_load(&idr->idr_xa, id);
}
```

本质上就是 `xa_load`——通过 XArray 从树中查找 ID 对应的指针。

### 2.3 idr_remove

```c
void *idr_remove(struct idr *idr, unsigned long id)
{
    return xa_erase(&idr->idr_xa, id);  // XArray 擦除操作
}
```

删除映射，返回被移除的指针。

---

## 3. IDA API

### 3.1 ida_alloc_range（`lib/idr.c`）

IDA 不关联数据指针，只管理 ID 号：

```c
int ida_alloc_range(struct ida *ida, unsigned int min, unsigned int max, gfp_t gfp);
```

内部使用 bitmap 管理空闲 ID，XArray 存储 these bitmap 页：

```
ida_alloc_range(ida, min, max, gfp)
  │
  ├─ ida_get_new_above(ida, min, &id)
  │    │
  │    ├─ 从 bitmap 页中查找首个 0 位（空闲）
  │    │    └─ 每页 1024 位（128 字节）
  │    │    └─ 通过 XArray 索引定位 bitmap 页
  │    │
  │    ├─ 如果当前页已满 → 加载/创建下一页
  │    │
  │    └─ set_bit() 标记已分配
  │
  └─ if (id > max) return -ENOSPC
  └─ return id
```

### 3.2 ida_free

```c
void ida_free(struct ida *ida, unsigned int id);
```

将指定 ID 在 bitmap 中的位清零。如果 bitmap 页变为全零，会从 XArray 中释放该页（回收内存）。

---

## 4. IDR vs IDA

| 特性 | IDR | IDA |
|------|-----|-----|
| 用途 | ID → 指针映射 | 仅 ID 分配 |
| 底层 | XArray（直接存指针） | XArray（存 bitmap 页）|
| 内存分配 | 每个 ID 占用一个 XArray slot | 每 1024 个 ID 占用 128 字节 bitmap |
| 查找 | O(log n) | O(log n)（但限于 bitmap 扫描） |
| 典型场景 | inode 号、文件描述符 | 设备号、中断号 |

---

## 5. 内核中使用案例

### 5.1 inode 编号

doom-lsp 确认 `fs/inode.c` 使用 IDR 管理 inode 编号：

```c
// fs/inode.c
struct inode *new_inode(struct super_block *sb)
{
    // 分配新的 inode 编号
    inode->i_ino = get_next_ino();  // 或通过 IDR
    // ...
}
```

### 5.2 设备号分配

`drivers/base/devtmpfs.c` 使用 IDA 管理设备号：

```
ida_alloc(minor_ida, GFP_KERNEL)  → 分配次设备号
ida_free(minor_ida, minor)        → 释放次设备号
```

### 5.3 文件描述符

`kernel/fork.c` 的 `get_unused_fd_flags`：
```c
// 分配 fd 号（范围限制）
// 底层使用 ida_simple_get
```

---

## 6. 数据类型流

```
IDR: id → ptr 映射

idr_alloc(idr, ptr, start, end)
  └─ xa_alloc(&idr->idr_xa, &id, ptr, ...)
       └─ XArray: [id] = ptr

idr_find(idr, id)
  └─ xa_load(&idr->idr_xa, id) → ptr

idr_remove(idr, id)
  └─ xa_erase(&idr->idr_xa, id) → old_ptr


IDA: id 号管理

ida_alloc_range(ida, min, max)
  └─ XArray: [page_idx] → bitmap_page
       └─ bitmap_page.bitmap[bit_pos] = 1

ida_free(ida, id)
  └─ XArray: [page_idx] → bitmap_page
       └─ bitmap_page.bitmap[bit_pos] = 0
       └─ if (全零) xa_erase(&ida->xa, page_idx)
```

---

## 7. 设计决策总结

| 决策 | 原因 |
|------|------|
| 底层基于 XArray | 复用成熟的路基数树实现 |
| IDA bitmap 分页 | 稀疏 ID 空间下节省内存 |
| idr_next hint | 分配时避免从头扫描 |
| xa_alloc 原子化 | 自动处理并发 ID 分配 |

---

## 8. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/idr.h` | `struct idr` | 35 |
| `include/linux/idr.h` | `struct ida` | 48 |
| `include/linux/idr.h` | `idr_find` | 128 |
| `lib/idr.c` | `idr_alloc` / `idr_remove` | 核心实现 |
| `lib/idr.c` | `ida_alloc_range` | 核心实现 |

---

## 9. 关联文章

- **xarray**（article 04）：IDR 的底层实现
- **page cache**（article 20）：inode 到 page 的索引类似 IDR 模式

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
