# IDR / IDA — 内核整数到指针映射深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/idr.h` + `lib/idr.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**IDR（ID Roster）** 和 **IDA（ID Allocator）** 是内核的**整数到指针映射**机制，用于分配唯一的 ID（如设备号、inode 号）。IDR 已基于 XArray 重新实现。

---

## 1. 核心数据结构

### 1.1 idr 结构

```c
// include/linux/idr.h — idr
struct idr {
    struct xarray    xa;          // XArray 存储
    unsigned int     id_base;     // 起始 ID
    unsigned int     curr;        // 当前最大 ID
};
```

### 1.2 IDA 结构

```c
// include/linux/ida.h — ida
struct ida {
    struct xarray    xa;
};
```

---

## 2. IDR API

### 2.1 idr_alloc — 分配 ID

```c
// include/linux/idr.h
int idr_alloc(struct idr *, void *ptr, int start, int end, gfp_t);
// start: 起始 ID（含）
// end: 结束 ID（不含）
```

### 2.2 idr_find — 查找

```c
void *idr_find(const struct idr *, unsigned long id);
```

### 2.3 idr_remove — 删除

```c
void idr_remove(struct idr *, unsigned long id);
```

---

## 3. 内部算法

### 3.1 IDR 分配（基于 XArray）

```
idr_alloc(idr, ptr, start=0, end=100)
    ↓
xa_store(&idr->xa, id, ptr, gfp)
    ↓
自动在 [start, end) 范围内查找空闲 ID
```

### 3.2 IDA 分配（bitmap）

```
ida_alloc(ida, gfp)
    ↓
xa_alloc() → 自动分配空闲 ID
    ↓
使用 XArray 内部 bitmap 追踪已用/空闲
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/idr.h` | IDR API |
| `include/linux/ida.h` | IDA API |
| `lib/idr.c` | IDR 实现 |
