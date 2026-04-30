# 158-slab_allocator — SLUB分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/slub.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**SLUB（Second Generation Allocator）** 是 Linux 2.6.22 引入的 slab 分配器，是内核对象分配的核心。SLUB 通过 per-CPU 快速路径、伙伴系统页面分配和着色技术，实现高效的内存分配。

---

## 1. 核心数据结构

### 1.1 struct kmem_cache — SLUB 缓存

```c
// mm/slub.c — kmem_cache
struct kmem_cache {
    // 对象属性
    unsigned int            object_size;      // 对象大小
    unsigned int            size;             // 实际占用（对齐后）
    unsigned int            align;            // 对齐要求

    // 阶（每个 slab 包含 2^order 个页面）
    struct kmem_cache_order_objects  oo;    // 对象数和阶
    struct kmem_cache_order_objects  max;     // 最大阶
    struct kmem_cache_order_objects  min;    // 最小阶

    // 对象名称
    const char              *name;           // 缓存名称（如 "task_struct"）

    // per-CPU 快速路径
    struct kmem_cache_cpu __percpu *cpu_slab; // per-CPU 指针

    // NUMA 支持
    struct kmem_cache_node *node[MAX_NUMNODES]; // 每节点一个

    // 特殊对象
    struct {
        void (*ctor)(void *);                // 构造函数
        void (*dtor)(void *);                // 析构函数
    };

    // 标志
    unsigned long           flags;             // SLAB_* 标志
    unsigned long           min_partial;        // 最少 partial slab 数
    int                     refcount;           // 引用计数
    void                    (*deact_to_node)(struct kmem_cache *, void *);
};
```

### 1.2 struct kmem_cache_cpu — per-CPU slab

```c
// mm/slub.c — kmem_cache_cpu
struct kmem_cache_cpu {
    // 当前 slab
    struct slab_sheaf    *slab;              // 当前 slab
    void                **freelist;          // 空闲对象链表（下一对象地址）

    // per-CPU 快速路径状态
    unsigned long          tid;                // 事务 ID（用于同步）
    unsigned int          frozen:1;           // 是否被冻结（用于 NUMA）
};
```

### 1.3 struct slab_sheaf — 实际 slab

```c
// mm/slub.c — slab_sheaf
struct slab_sheaf {
    struct {
        struct slab_sheaf *main;   // 主 slab（不会 NULL）
        struct slab_sheaf *spare;  // 备用或已满 slab
        struct slab_sheaf *rcu_free; // RCU 延迟释放
    };

    // 对象
    void                *s_mem;              // slab 内第一个对象的地址
    unsigned int        inuse;                // 已使用对象数
    unsigned int        objects;               // 总对象数

    // freepointer（空闲链表）
    freeptr_t           freeptr;              // 指向第一个空闲对象

    // 页
    struct page         *page;               // 伙伴系统分配的页
    unsigned int        order;                 // 阶（2^order 页面）
};
```

---

## 2. 快速路径分配（slab_alloc_node）

### 2.1 slab_alloc_node

```c
// mm/slub.c — slab_alloc_node
void *slab_alloc_node(struct kmem_cache *s, struct page *page,
                      gfp_t gfpflags, int node)
{
    void **freelist;
    unsigned long tid;

    // 1. per-CPU 快速路径
    struct kmem_cache_cpu *c = this_cpu_ptr(s->cpu_slab);

    freelist = c->freelist;
    if (freelist) {
        // 快速路径：有空闲对象
        object = freelist;

        // 更新 freelist 指向下一个对象
        c->freelist = get_freepointer(s, object);

        // 设置构造函数
        if (object && s->ctor)
            s->ctor(object);

        return object;
    }

    // 2. 慢速路径：从 partial 或新 slab 分配
    return __slab_alloc(s, gfpflags, node, c);
}
```

---

## 3. 慢速路径（__slab_alloc）

### 3.1 __slab_alloc

```c
// mm/slub.c — __slab_alloc
static void *__slab_alloc(struct kmem_cache *s, gfp_t gfpflags,
                          int node, struct kmem_cache_cpu *c)
{
    // 1. 尝试从 node 的 partial 列表获取
    struct kmem_cache_node *n = get_node(s, node);
    struct slab_sheaf *slab = c->slab;

    if (slab && !c->frozen) {
        // 当前 slab 还在用，尝试解冻
        goto redo;
    }

    // 2. 从 partial 列表取 slab
    slab = n->partial;
    if (slab) {
        n->partial = slab->next;
        goto load_slab;
    }

    // 3. 分配新 slab
    slab = new_slab_objects(s, gfpflags, node, &c);
    if (!slab)
        goto error;

load_slab:
    c->slab = slab;
    c->freelist = slab->s_mem;

redo:
    // 4. 取对象
    object = c->freelist;
    c->freelist = get_freepointer(s, object);
    return object;

error:
    return NULL;
}
```

---

## 4. 分配新 slab（new_slab_objects）

### 4.1 new_slab_objects

```c
// mm/slub.c — new_slab_objects
static struct slab_sheaf *new_slab_objects(struct kmem_cache *s,
                                            gfp_t gfpflags, int node,
                                            struct kmem_cache_cpu **pc)
{
    struct kmem_cache_order_objects oo = s->oo;
    struct slab_sheaf *slab;

    // 1. 分配页面（伙伴系统）
    struct page *page = alloc_pages_node(node, gfpflags, oo_order(oo));
    if (!page) {
        // 分配失败，尝试减小阶
        oo = s->min;
        page = alloc_pages_node(node, gfpflags, oo_order(oo));
    }

    // 2. 初始化 slab
    slab = page->slab_sheaf;
    slab->page = page;
    slab->objects = oo_objects(oo);
    slab->inuse = 0;

    // 3. 初始化 freelist（空闲链表）
    init_freelist(slab, s);

    return slab;
}
```

---

## 5. 释放（__slab_free）

### 5.1 __slab_free

```c
// mm/slub.c — __slab_free
void __slab_free(struct kmem_cache *s, struct slab_sheaf *slab,
                void **freelist, void *object)
{
    // 1. 如果是当前 CPU 的 slab，直接加入 freelist（快速路径）
    struct kmem_cache_cpu *c = this_cpu_ptr(s->cpu_slab);
    if (c->slab == slab) {
        set_freepointer(s, object, c->freelist);
        c->freelist = object;
        return;
    }

    // 2. 慢速路径：放入 partial 列表
    struct kmem_cache_node *n = get_node(s, page_to_nid(slab->page));
    freelist = (void **)((char *)slab + sizeof(struct slab_sheaf));
    init_freelist(slab, s);
    slab->next = n->partial;
    n->partial = slab;
}
```

---

## 6. 对象大小 vs 实际大小

```
kmem_cache 对象布局：

object_size = 100 字节（用户请求）
size        = 128 字节（实际分配，对齐到 8 字节）

一个页面（4KB）包含：
  4096 / 128 = 32 个对象

如果 object_size = 100：
  size = 128
  objects = 32

freelist 存储在每个对象的第一个指针大小的空间内
```

---

## 7. SLUB vs SLAB vs SLOB

| 特性 | SLUB | SLAB | SLOB |
|------|------|------|------|
| per-CPU 快速路径 | ✓ | ✗ | ✗ |
| NUMA 友好 | ✓ | ✓ | ✗ |
| 内存开销 | 低 | 高 | 极低 |
| 复杂度 | 中 | 高 | 低 |
| 嵌入式友好 | 一般 | 一般 | ✓ |

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/slub.c` | `slab_alloc_node`、`__slab_alloc`、`new_slab_objects`、`__slab_free` |
| `mm/slub.c` | `struct kmem_cache`、`struct kmem_cache_cpu`、`struct slab_sheaf` |

---

## 9. 西游记类比

**SLUB** 就像"天庭的对象制造工厂"——

> SLUB 是一个自动化工厂，每个工位（kmem_cache）专门生产一种对象（task_struct、inode 等）。每个工位有一个小仓库（slab_sheaf），里面有很多半成品（空闲对象），妖怪（CPU）直接从小仓库拿货，不用每次都去总仓库（伙伴系统）申请材料（页面）。小仓库空了（slab 满了），再去总仓库领一批材料开一个新的小仓库。freelist 就像货架上的标签——每个空的货架位置都贴了下一个空位置的标签，方便快速找到下一个可用位置。这就是为什么 SLUB 分配这么快——大部分情况下，妖怪（CPU）只需要在自己的小仓库（per-CPU slab）的货架上取货，完全不用锁。

---

## 10. 关联文章

- **page_allocator**（article 17）：SLUB 从伙伴系统分配页面
- **per-CPU**（article 157）：SLUB 使用 per-CPU 快速路径