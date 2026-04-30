# slab allocator — 内存对象分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/slab.c` + `mm/slab_common.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**slab allocator** 是内核的**对象分配器**，解决 Buddy 系统分配小对象（< PAGE_SIZE）的内部碎片问题：
- **slab**：一个或多个物理页，划分为等大小对象
- **着色（coloring）**：错开 CPU 缓存行，减少伪共享
- **对象缓存（kmem_cache）**：每种对象类型独立缓存

---

## 1. 核心数据结构

### 1.1 kmem_cache — 对象缓存

```c
// include/linux/slab.h — kmem_cache
struct kmem_cache {
    // 对象信息
    const char           *name;            // 缓存名（如 "task_struct"）
    size_t               object_size;      // 对象大小
    size_t               size;              // 对齐后大小（含 padding）
    size_t               align;            // 对齐要求

    // 伙伴系统接口
    struct kmem_cache_order_objects oo;   // order * objects
    struct kmem_cache_order_objects max;   // 最大阶
    struct kmem_cache_order_objects min;   // 最小阶

    // 对象布局
    void                 (*ctor)(void *);   // 构造函数
    void                 (*dtor)(void *);   // 析构函数

    // CPU 本地缓存
    struct kmem_cache_cpu __percpu *cpu_slab; // per-CPU 空闲链表

    // 空闲链表
    struct list_head       list;           // 全局 slab 链表

    // 着色
    unsigned int           colour;          // 颜色数
    unsigned int           colour_off;     // 颜色偏移
    unsigned int           dflags;         // 动态标志

    /* 调试 */
    unsigned long          flags;          // SLAB_* 标志
    int                    refcount;       // 引用计数
    void                   (*shutdown)(struct kmem_cache *);
};
```

### 1.2 kmem_cache_cpu — per-CPU 本地缓存

```c
// mm/slab.c — kmem_cache_cpu
struct kmem_cache_cpu {
    // 本地 slab（当前 CPU 最快的分配路径）
    struct slab            *slab;          // 当前 slab
    void                   **freelist;    // 空闲对象链表头
    unsigned int            tid;           // 事务 ID（防止竞争）

    // Per-CPU 空闲对象数组（无锁快速分配）
    void                   **free_disabled;
    int                    freeptr_depth;
};
```

### 1.3 slab — 内存块

```c
// mm/slab.c — slab
struct slab {
    struct list_head        list;          // 接入 kmem_cache->list
    struct page            *page;          // 伙伴分配的页
    unsigned int            inuse;          // 已使用对象数
    unsigned int            objects;        // 总对象数
    unsigned long           colouroff;      // 颜色偏移
    void                   *freelist;      // 空闲链表（SLAB_STORE_USER 时）
    unsigned int            free;          // 第一个空闲对象偏移
};
```

---

## 2. 分配算法（slab_alloc）

```c
// mm/slab.c — slab_alloc
void *slab_alloc(struct kmem_cache *cachep, gfp_t flags)
{
    struct kmem_cache_cpu *c = this_cpu_ptr(cachep->cpu_slab);
    void **freelist;
    struct slab *slabp;
    unsigned long tid;

get_cpu_ptr:
    tid = c->tid;
    barrier();

    freelist = c->freelist;
    if (!freelist)
        goto load_slab;

    // 从 per-CPU 空闲链表快速分配（无锁）
    freelist = c->freelist;
    c->freelist = *(void **)freelist;

    return freelist;

load_slab:
    // per-CPU 缓存为空，从本地 slab 取
    slabp = c->slab;
    if (!slabp)
        goto new_slab;

    if (slabp->inuse < slabp->objects) {
        // 本地 slab 还有空闲对象
        c->freelist = (void *)slabp + slabp->free;
        c->tid = next_tid(c->tid);
        return c->freelist;
    }

new_slab:
    // 分配新 slab（kmem_cache_grow）
    slabp = kmem_cache_grow(cachep, flags);
    c->slab = slabp;
    c->freelist = (void *)slabp + slabp->free;

    return c->freelist;
}
```

---

## 3. kmem_cache_grow — 分配新 slab

```c
// mm/slab.c — kmem_cache_grow
static struct slab *kmem_cache_grow(struct kmem_cache *cachep, gfp_t flags)
{
    // 1. 从伙伴系统分配页
    struct page *page = alloc_pages(flags, cachep->oo.order);

    // 2. 初始化 slab
    struct slab *slabp = page_to_slab(page);
    slabp->objects = cachep->oo.objects;
    slabp->inuse = 0;
    slabp->colouroff = 0;

    // 3. 构建空闲链表
    void **freelist = &slabp[1];
    for (i = 0; i < slabp->objects; i++)
        freelist[i] = freelist[i + 1];

    slabp->free = 0;
    slabp->list = cachep->list;

    // 4. 添加到缓存链表
    list_add(&slabp->list, &cachep->list);

    return slabp;
}
```

---

## 4. 着色（Coloring）

```c
// mm/slab.c — cache_estimate
void cache_estimate(struct kmem_cache *cachep, size_t size, ...)
{
    // 计算颜色数（让每个对象的起始地址错开 cache line）
    unsigned int colour_max = flushicache_pages(cachep);
    unsigned int colour = colour_max;

    // 颜色偏移 = colour * colour_off
    // 第一个对象的起始 = slab 开始 + colour_off * colour
    // 下一个对象的起始 = 前一个 + size + colour_off
    // 这样不同对象的起始地址错开，减少伪共享
}
```

---

## 5. 销毁（kmem_cache_free）

```c
// mm/slab.c — slab_free
void slab_free(struct kmem_cache *cachep, struct slab *slabp, void *objp)
{
    struct kmem_cache_cpu *c = this_cpu_ptr(cachep->cpu_slab);

    // 放回 per-CPU 空闲链表
    *(void **)objp = c->freelist;
    c->freelist = objp;

    slabp->inuse--;
}
```

---

## 6. SLAB 调试

```c
// mm/slab.c — SLAB_STORE_USER
#define SLAB_STORE_USER     (1 << 0)  // 记录释放者
#define SLAB_RED_ZONE       (1 << 1)  // 红区（溢出检测）
#define SLAB_POISON         (1 << 2)  // 毒值（use-after-free 检测）

// 开启后：
// - 每对象前/后填充红区
// - 分配时写入毒值，释放时检查是否被覆盖
// - 记录 alloc/free 的 call stack
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/slab.h` | `struct kmem_cache` |
| `mm/slab.c` | `slab_alloc`、`kmem_cache_grow`、`slab_free` |
| `mm/slab_common.c` | `kmem_cache_create`、`kmem_cache_destroy` |