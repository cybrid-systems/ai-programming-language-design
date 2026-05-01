# 36-slab — SLUB 分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**SLUB** 是 Linux 内核当前默认的 slab 分配器，管理小对象的分配释放。它从 buddy 系统获取物理页，切分成固定大小的对象缓存。

doom-lsp 确认 `mm/slub.c` 包含约 660+ 个符号。

---

## 1. 核心结构

### 1.1 struct kmem_cache

```c
struct kmem_cache {
    struct kmem_cache_cpu __percpu *cpu_slab;  // Per-CPU 空闲列表
    unsigned long              min_partial;     // 最小 partial slab 数
    int                        size;            // 对象大小
    int                        object_size;     // 原始对象大小
    unsigned int               offset;          // 空闲指针在对象中的偏移
    struct kmem_cache_order_objects oo;         // slab 大小配置
    gfp_t                      allocflags;
    const char                *name;
    ...
};
```

### 1.2 三层分配路径

```
kmem_cache_alloc(cache, GFP_KERNEL)
  │
  ├─ [L1] Per-CPU 空闲对象（无锁）
  │    └─ cpu_slab->freelist → 取对象
  │    └─ 无对象 → 从本地 partial slab 搬移
  │
  ├─ [L2] 全局 partial slab（需锁）
  │    └─ kmem_cache_node->partial → 取 slab
  │
  └─ [L3] 从 buddy 分配新 slab
       └─ alloc_slab_page(gfp, order, node)
            └─ 切分成对象 → 加入 freelist
```

---

## 2. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `mm/slub.c` | kmem_cache_alloc / slub_free 等 |
| `include/linux/slub_def.h` | struct kmem_cache |

---

*分析工具：doom-lsp（clangd LSP）*
