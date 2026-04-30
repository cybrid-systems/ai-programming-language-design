# Linux Kernel SLUB Allocator 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/slub.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 SLUB？

**SLUB**（SLAB Unqueued Allocator）是 Linux 2.6.22+ 的**内核内存分配器**，替代了旧的 SLAB。它的目标是减少锁竞争，提高多核性能。

**vs SLAB**：
- SLAB：每个 CPU 维护自己的缓存，但有全局锁
- SLUB：去掉了全局锁，每个 CPU 有独立的 per-CPU freelist

---

## 1. 核心结构

```c
// mm/slub.c — struct kmem_cache
struct kmem_cache {
    // 对象大小和对齐
    unsigned int            object_size;     // 对象大小
    unsigned int            size;           // 含 metadata 的大小
    unsigned int            align;          // 对齐要求

    // per-CPU 缓存（关键！）
    struct array_cache __percpu *cpu_cache;  // per-CPU 对象指针数组

    // 节点（NUMA 支持）
    struct kmem_cache_node  *node[MAX_NUMNODES];

    // 着色（cache color）
    unsigned long           min_partial;
    unsigned long           partial;        // 空闲 slab 链表长度
    int                     cpu_partial;   // 每 CPU partial 长度

    // 对象管理
    void                    (*ctor)(void *);
    void                    (*dtor)(void *);

    const char             *name;           // 缓存名（如 "buffer_head"）
    struct list_head        list;           // 全局缓存链表
};

// per-CPU 缓存（array_cache）
struct array_cache {
    unsigned int avail;      // 可用对象数
    unsigned int limit;     // 最大对象数
    void            *entry[]; // 对象指针数组（柔性数组成员）
};
```

---

## 2. kmalloc — 小块分配

```c
// mm/slub.c — kmalloc
void *kmalloc(size_t size, gfp_t flags)
{
    struct kmem_cache *s = kmalloc_slab(size, flags);
    return kmem_cache_alloc(s, flags);
}

// kmalloc_slab：根据大小选择合适的 kmem_cache
//   <= 192B: kmalloc-192
//   <= 256B: kmalloc-256
//   <= 512B: kmalloc-512
//   ...
```

---

## 3. kmem_cache_alloc — 从缓存分配对象

```c
// mm/slub.c — kmem_cache_alloc
void *kmem_cache_alloc(struct kmem_cache *s, gfp_t gfpflags)
{
    void *object;

    // 1. per-CPU 快速路径
    struct array_cache *ac = this_cpu_ptr(s->cpu_cache);
    if (ac->avail > 0) {
        // 从 per-CPU freelist 取对象
        object = ac->entry[--ac->avail];
        return object;
    }

    // 2. per-CPU 缓存为空：从节点获取
    object = slab_alloc_node(s, gfpflags, NUMA_NO_NODE, _RET_IP_);
    return object;
}
```

---

## 4. slab_alloc_node — 慢路径分配

```c
// mm/slub.c — slab_alloc_node
static void *slab_alloc_node(struct kmem_cache *s,
                gfp_t gfpflags, int node, unsigned long addr)
{
    struct kmem_cache_node *n;
    struct page *page;

    // 1. 从 per-CPU 获取
    ac = get_cpu_ptr(s->cpu_cache);
    if (ac->avail > 0) {
        object = ac->entry[--ac->avail];
        goto out;
    }

    // 2. per-CPU 缓存空，尝试 refill
    ac = cpu_cache_get(s);  // 重新填充 per-CPU 缓存
    if (ac->avail > 0) {
        object = ac->entry[--ac->avail];
        goto out;
    }

    // 3. 从 node 的 partial 链表获取
    n = get_node(s, node);
    page = get_partial_node(s, n);
    if (page) {
        object = page->freelist;
        page->freelist = object[1];  // 前进 freelist
        // 放入 per-CPU 缓存...
        goto out;
    }

    // 4. 分配新 slab
    page = allocate_slab(s, gfpflags);
    // 放入 per-CPU 缓存...

out:
    put_cpu_ptr(s->cpu_cache);
    return object;
}
```

---

## 5. 完整状态机

```
kmalloc(100)
  ↓
kmalloc_slab(100) → 选择 kmalloc-128
  ↓
kmem_cache_alloc(kmalloc-128)
  ↓
┌─────────────────────────────────────┐
│ per-CPU cache (ac->entry[])        │
│   avail > 0?                       │
│     → 直接返回 entry[--avail]       │ ← 快速路径，零锁
│   avail == 0?                      │
│     → get_partial_node()            │ ← 从 partial 链表补货
│     → allocate_slab()               │ ← 分配新 slab
└─────────────────────────────────────┘
```

---

## 6. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| per-CPU array_cache | 分配/释放零锁，极高并发性能 |
| per-CPU partial | 减少跨 CPU 分配时的缓存失效 |
| NUMA node 分离 | 每个 NUMA 节点有自己的 slab，减少远端内存访问 |
| kmalloc 分级 | 不同大小用不同 cache，避免内部碎片 |
| SLUB vs SLAB | SLAB 有全局锁（NODE_LOCK），SLUB 完全 per-CPU |

---

## 7. 参考

| 文件 | 内容 |
|------|------|
| `mm/slub.c` | `kmem_cache_alloc`、`slab_alloc_node`、`kmalloc` |
| `mm/slub_def.h` | `struct kmem_cache`、`struct array_cache` |
| `mm/slab_common.c` | `kmalloc_slab`、`kmalloc_caches` |
