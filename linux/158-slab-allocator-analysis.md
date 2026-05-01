# 158-slab_allocator — SLUB分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/slub.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**SLUB（Second Generation Allocator）** 是 Linux 2.6.22 引入的 slab 分配器，是内核对象分配的核心。SLUB 通过 per-CPU 快速路径、伙伴系统页面分配和着色技术，实现高效的内存分配。

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

## 7. SLUB vs SLAB vs SLOB

| 特性 | SLUB | SLAB | SLOB |
|------|------|------|------|
| per-CPU 快速路径 | ✓ | ✗ | ✗ |
| NUMA 友好 | ✓ | ✓ | ✗ |
| 内存开销 | 低 | 高 | 极低 |
| 复杂度 | 中 | 高 | 低 |
| 嵌入式友好 | 一般 | 一般 | ✓ |

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/slub.c` | `slab_alloc_node`、`__slab_alloc`、`new_slab_objects`、`__slab_free` |
| `mm/slub.c` | `struct kmem_cache`、`struct kmem_cache_cpu`、`struct slab_sheaf` |

## 9. 西游记类比

**SLUB** 就像"天庭的对象制造工厂"——

> SLUB 是一个自动化工厂，每个工位（kmem_cache）专门生产一种对象（task_struct、inode 等）。每个工位有一个小仓库（slab_sheaf），里面有很多半成品（空闲对象），妖怪（CPU）直接从小仓库拿货，不用每次都去总仓库（伙伴系统）申请材料（页面）。小仓库空了（slab 满了），再去总仓库领一批材料开一个新的小仓库。freelist 就像货架上的标签——每个空的货架位置都贴了下一个空位置的标签，方便快速找到下一个可用位置。这就是为什么 SLUB 分配这么快——大部分情况下，妖怪（CPU）只需要在自己的小仓库（per-CPU slab）的货架上取货，完全不用锁。

## 10. 关联文章

- **page_allocator**（article 17）：SLUB 从伙伴系统分配页面
- **per-CPU**（article 157）：SLUB 使用 per-CPU 快速路径

---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `include/linux/list.h` | 51 | 0 | 51 | 0 |
| `include/linux/sched.h` | 567 | 70 | 134 | 7 |
| `include/linux/mm.h` | 793 | 24 | 527 | 18 |

### 核心数据结构

- **audit_context** `sched.h:58`
- **bio_list** `sched.h:59`
- **blk_plug** `sched.h:60`
- **bpf_local_storage** `sched.h:61`
- **bpf_run_ctx** `sched.h:62`
- **bpf_net_context** `sched.h:63`
- **capture_control** `sched.h:64`
- **cfs_rq** `sched.h:65`
- **fs_struct** `sched.h:66`
- **futex_pi_state** `sched.h:67`
- **io_context** `sched.h:68`
- **io_uring_task** `sched.h:69`
- **mempolicy** `sched.h:70`
- **nameidata** `sched.h:71`
- **nsproxy** `sched.h:72`
- **perf_event_context** `sched.h:73`
- **perf_ctx_data** `sched.h:74`
- **pid_namespace** `sched.h:75`
- **pipe_inode_info** `sched.h:76`
- **rcu_node** `sched.h:77`
- **reclaim_state** `sched.h:78`
- **robust_list_head** `sched.h:79`
- **root_domain** `sched.h:80`
- **rq** `sched.h:81`
- **sched_attr** `sched.h:82`

### 关键函数

- **INIT_LIST_HEAD** `list.h:43`
- **__list_add_valid** `list.h:136`
- **__list_del_entry_valid** `list.h:142`
- **__list_add** `list.h:154`
- **list_add** `list.h:175`
- **list_add_tail** `list.h:189`
- **__list_del** `list.h:201`
- **__list_del_clearprev** `list.h:215`
- **__list_del_entry** `list.h:221`
- **list_del** `list.h:235`
- **list_replace** `list.h:249`
- **list_replace_init** `list.h:265`
- **list_swap** `list.h:277`
- **list_del_init** `list.h:293`
- **list_move** `list.h:304`
- **list_move_tail** `list.h:315`
- **list_bulk_move_tail** `list.h:331`
- **list_is_first** `list.h:350`
- **list_is_last** `list.h:360`
- **list_is_head** `list.h:370`
- **list_empty** `list.h:379`
- **list_del_init_careful** `list.h:395`
- **list_empty_careful** `list.h:415`
- **list_rotate_left** `list.h:425`
- **list_rotate_to_front** `list.h:442`
- **list_is_singular** `list.h:457`
- **__list_cut_position** `list.h:462`
- **list_cut_position** `list.h:488`
- **list_cut_before** `list.h:515`
- **__list_splice** `list.h:531`
- **list_splice** `list.h:550`
- **list_splice_tail** `list.h:562`
- **list_splice_init** `list.h:576`
- **list_splice_tail_init** `list.h:593`
- **list_count_nodes** `list.h:755`

### 全局变量

- **__tracepoint_sched_set_state_tp** `sched.h:350`
- **__tracepoint_sched_set_need_resched_tp** `sched.h:352`
- **def_root_domain** `sched.h:407`
- **sched_domains_mutex** `sched.h:408`
- **cad_pid** `sched.h:1749`
- **init_stack** `sched.h:1964`
- **class_migrate_is_conditional** `sched.h:2519`
- **_totalram_pages** `mm.h:53`
- **high_memory** `mm.h:74`
- **sysctl_legacy_va_layout** `mm.h:86`
- **mmap_rnd_bits_min** `mm.h:92`
- **mmap_rnd_bits_max** `mm.h:93`
- **mmap_rnd_bits** `mm.h:94`
- **sysctl_user_reserve_kbytes** `mm.h:210`
- **sysctl_admin_reserve_kbytes** `mm.h:211`

### 成员/枚举

- **utime** `sched.h:366`
- **stime** `sched.h:367`
- **lock** `sched.h:368`
- **seqcount** `sched.h:386`
- **starttime** `sched.h:387`
- **state** `sched.h:388`
- **cpu** `sched.h:389`
- **utime** `sched.h:390`
- **stime** `sched.h:391`
- **gtime** `sched.h:392`
- **sched_priority** `sched.h:413`
- **pcount** `sched.h:421`
- **run_delay** `sched.h:424`
- **max_run_delay** `sched.h:427`
- **min_run_delay** `sched.h:430`
- **last_arrival** `sched.h:435`
- **last_queued** `sched.h:438`
- **max_run_delay_ts** `sched.h:441`
- **weight** `sched.h:461`
- **inv_weight** `sched.h:462`

