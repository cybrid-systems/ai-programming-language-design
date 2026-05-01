# SLUB 分配器算法深度分析

> 内核源码: Linux 7.0-rc1 (`mm/slub.c` + `mm/slab.h`)
> 分析工具: doom-lsp (clangd LSP)

## 一、SLUB 架构总览

SLUB 是 Linux 主流 slab 分配器，其核心设计目标：**用 O(1) 快速路径减少锁竞争，用 lockless freelist 和 per-CPU sheaves 实现高吞吐。**

现代内核 (7.0-rc1) 不再使用旧的 `kmem_cache_cpu` 结构，而是引入 **`slub_percpu_sheaves`** 作为 CPU 本地缓存层：

```
kmem_cache_alloc()
└── slab_alloc_node()
    ├── kfence_alloc()          ← KFENCE 快速路径 (跳过)
    ├── alloc_from_pcs()        ← CPU sheaves 快速路径 (lockless, O(1))
    │   └── this_cpu_ptr(s->cpu_sheaves)->main->objects[--size]
    └── __slab_alloc_node()     ← 慢速路径 ___slab_alloc()
        ├── get_from_partial()     ← 从 node partial 链表取 slab
        ├── new_slab()             ← 分配新 slab 页
        └── shuffle_freelist()     ← 随机化 freelist (熵)
```

## 二、SLUB 布局串联：核心数据结构

### 2.1 `struct slab` (mm/slab.h:74)

```c
struct slab {
    memdesc_flags_t flags;
    struct kmem_cache *slab_cache;  // 本 slab 所属的 kmem_cache
    union {
        struct {
            struct list_head slab_list;  // 链接到 partial/full 链表
            struct freelist_counters;    // ABA 安全计数器 (cmpxchg double)
        };
        struct rcu_head rcu_head;       // RCU 释放时复用
    };
    unsigned int __page_type;
    atomic_t __page_refcount;
#ifdef CONFIG_SLAB_OBJ_EXT
    unsigned long obj_exts;
#endif
};
```

`struct slab` 直接嵌入 `struct page` 所在的 folio 头部的相同位置（`SLAB_MATCH` 静态检查）。所以一个物理页既是 `struct page` 又是 `struct slab`，通过 `page_slab()` / `slab_folio()` 互相转换。

### 2.2 `struct slab_sheaf` (mm/slub.c:404)

```c
struct slab_sheaf {
    union {
        struct rcu_head rcu_head;     // RCU 延迟释放
        struct list_head barn_list;  // 链接到 node_barn 的 full/empty 链表
        struct {                     // 预填充的 sheaf (已分配 objects)
            unsigned int capacity;
            bool pfmemalloc;
        };
    };
    struct kmem_cache *cache;
    unsigned int size;           // 当前空闲对象数 (在 main 中)
    int node;                    // 仅 rcu_sheaf 使用，记录 NUMA 节点
    void *objects[];            // 柔性数组：存放对象指针
};
```

`slab_sheaf` 是 **CPU 本地分配的小型对象缓存**，一个 sheaf 最多存放 `capacity` 个对象指针，按 `size` 递减管理（pop from tail）。`objects[]` 数组本身不存储对象数据，只存 **已分配对象的指针**。

### 2.3 `struct slub_percpu_sheaves` (mm/slub.c:420)

```c
struct slub_percpu_sheaves {
    local_trylock_t lock;       // 本地自旋锁 (per-CPU, 非抢占区可trylock)
    struct slab_sheaf *main;    // 主 sheaf，永不为 NULL (unlocked 时)
    struct slab_sheaf *spare;   // 空闲或满，可作为 main 的替换
    struct slab_sheaf *rcu_free;// kfree_rcu() 批量延迟释放
};
```

每个 CPU 维护自己的 `slub_percpu_sheaves`，无任何全局竞争。分配时从 `main` 的尾部 pop，释放时 push 到 `main` 或 `rcu_free`。

### 2.4 `struct kmem_cache_node` (mm/slub.c:430)

```c
struct kmem_cache_node {
    spinlock_t list_lock;
    unsigned long nr_partial;
    struct list_head partial;    // 部分空闲 slab 链表
#ifdef CONFIG_SLUB_DEBUG
    atomic_long_t nr_slabs;
    atomic_long_t total_objects;
    struct list_head full;       // 调试模式下全满 slab 链表
#endif
};
```

每个 NUMA node 每个 kmem_cache 有一个 `kmem_cache_node`，通过 `per_node[node].node` 访问。

### 2.5 `struct node_barn` (mm/slub.c:396)

```c
struct node_barn {
    spinlock_t lock;
    struct list_head sheaves_full;
    struct list_head sheaves_empty;
    unsigned int nr_full;
    unsigned int nr_empty;
};
```

`node_barn` 是介于 **per-CPU sheaves** 和 **kmem_cache_node partial 链表** 之间的中间层。当 CPU sheaf 耗尽时，从 `node_barn` 批量补充；当 CPU sheaf 满了，卸载到 `node_barn`。`barn_shrink()` 归还 slab 到 `kmem_cache_node`。

### 数据结构关系图

```
CPU (per-core)
  ┌─────────────────────────────────────────────┐
  │ struct slub_percpu_sheaves (s->cpu_sheaves) │
  │   main: slab_sheaf  (含 void *objects[])    │  ← O(1) 分配/释放
  │   spare: slab_sheaf (full or empty)         │
  │   rcu_free: slab_sheaf (kfree_rcu batching) │
  └─────────────────────────────────────────────┘
          ↕ 从 node_barn 补充 (barn_replace_empty_sheaf)
  ┌─────────────────────────────────────────────┐
  │ struct node_barn (per kmem_cache per node)  │
  │   sheaves_full / sheaves_empty 链表          │
  └─────────────────────────────────────────────┘
          ↕ 耗尽时从 partial 链表取 slab
  ┌─────────────────────────────────────────────┐
  │ struct kmem_cache_node (per kmem_cache per node)
  │   partial 链表 (struct slab.slab_list)       │  ← 共享，需要锁
  │   full 链表 (debug only)                     │
  └─────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────┐
  │ struct slab (嵌入 struct page 头部)          │
  │   freelist_counters (cmpxchg double ABA)     │
  │   objects: 实际对象所在的内存                 │
  └─────────────────────────────────────────────┘
```

## 三、快速路径 `kmem_cache_alloc`

### 3.1 CPU 本地缓存命中：O(1) 分配

```
kmem_cache_alloc_noprof(s, gfp)
  → slab_alloc_node(s, NULL, gfp, NUMA_NO_NODE, _RET_IP_, s->object_size)
      → alloc_from_pcs(s, gfp, node)           // CPU sheaves 快速路径
```

`alloc_from_pcs()` (slub.c:4704)：

```c
void *alloc_from_pcs(struct kmem_cache *s, gfp_t gfp, int node)
{
    struct slub_percpu_sheaves *pcs;
    pcs = this_cpu_ptr(s->cpu_sheaves);

    // 1. trylock - 不阻塞，不等待
    if (!local_trylock(&s->cpu_sheaves->lock))
        return NULL;                          // 加锁失败 → 慢速路径

    // 2. main sheaf 空 → 尝试从 spare 替换
    if (unlikely(pcs->main->size == 0)) {
        pcs = __pcs_replace_empty_main(s, pcs, gfp);
        if (unlikely(!pcs))
            return NULL;
    }

    // 3. O(1) 取对象：objects[--size] 是最后一个元素
    object = pcs->main->objects[pcs->main->size - 1];
    pcs->main->size--;

    local_unlock(&s->cpu_sheaves->lock);
    stat(s, ALLOC_FASTPATH);
    return object;
}
```

**关键**：`main->size--` 后再取 `objects[size]` —— 所以 `size` 是已用计数，`objects[0..size-1]` 是空闲对象，pop 从尾部进行。

### 3.2 CPU 本地缓存未命中 → node_barn 补充

`alloc_from_pcs_bulk()` (slub.c:4783) 处理批量分配和 sheaf 补充：

```c
next_batch:
    // trylock 失败 → 立即返回已分配数量
    if (!local_trylock(&s->cpu_sheaves->lock))
        return allocated;

    if (pcs->main->size == 0) {
        // main 空：优先用 spare 替换
        if (pcs->spare && pcs->spare->size > 0) {
            swap(pcs->main, pcs->spare);      // O(1) 交换
            goto do_alloc;
        }

        // 从 node_barn 获取 full sheaf
        barn = get_barn(s);                   // 获取本 node 的 node_barn
        full = barn_replace_empty_sheaf(barn, pcs->main, allow_spin);
        if (full) {
            stat(s, BARN_GET);
            pcs->main = full;
            goto do_alloc;
        }

        stat(s, BARN_GET_FAIL);
        local_unlock(&s->cpu_sheaves->lock);
        return allocated;                     // 慢速路径 fallback
    }
```

`barn_replace_empty_sheaf()` 从 `node_barn.sheaves_full` 取一个 full sheaf 替换 CPU 的 empty main sheaf。

### 3.3 完全未命中 → `___slab_alloc()` 慢速路径

当 `alloc_from_pcs()` 返回 NULL 或 debug enabled / SLUB_TINY 时候，进入 `___slab_alloc()` (slub.c:4405)：

```c
// 1. 优先从目标 node 的 partial 链表取
object = get_from_partial(s, node, &pc);
if (object)
    goto success;

// 2. 分配新 slab
slab = new_slab(s, pc.flags, node);

// 3. 调试/SLUB_TINY 模式：逐个对象分配
if (IS_ENABLED(CONFIG_SLUB_TINY) || kmem_cache_debug(s)) {
    object = alloc_single_from_new_slab(s, slab, orig_size, gfpflags);
} else {
    // 普通模式：一次性从新 slab 填充 sheaf
    alloc_from_new_slab(s, slab, &object, 1, allow_spin);
    return object;
}
```

`get_from_partial()` (slub.c:3915) 查找顺序：

```c
static void *get_from_partial(struct kmem_cache *s, int node, struct partial_context *pc)
{
    int searchnode = node == NUMA_NO_NODE ? numa_mem_id() : node;

    // 优先目标 node
    object = get_from_partial_node(s, get_node(s, searchnode), pc);
    if (object || (node != NUMA_NO_NODE && (pc->flags & __GFP_THISNODE)))
        return object;

    // 目标 node 没有 → 搜索其他 node 的 partial
    return get_from_any_partial(s, pc);
}
```

### 完整分配路径 ASCII 图

```
kmem_cache_alloc()
│
├─ [快速路径] alloc_from_pcs()           CPU sheaves
│   │
│   ├─ local_trylock() ✓ → 继续           (无竞争, O(1))
│   │   │
│   │   ├─ pcs->main->size > 0?
│   │   │   YES → object = pcs->main->objects[--size]  ← 返回, O(1) ✓
│   │   │   NO  → __pcs_replace_empty_main()
│   │   │         ├─ spare 有对象? → swap(main, spare) → 再取
│   │   │         └─ 从 node_barn 取 full sheaf
│   │   │             ├─ barn_replace_empty_sheaf() → 成功 ✓
│   │   │             └─ 失败 → 返回 NULL (进入慢速路径)
│   │   │
│   │   └─ local_unlock() → stat(ALLOC_FASTPATH)
│   │
│   └─ local_trylock() ✗ → 返回 NULL      (锁被占, 直接进慢速)
│
└─ [慢速路径] __slab_alloc_node() → ___slab_alloc()
    │
    ├─ get_from_partial(node)             kmem_cache_node.partial
    │   ├─ get_from_partial_node(target_node)   ← 优先目标 node
    │   │   └─ 从 node 的 partial 链表 pop 一个 object
    │   └─ get_from_any_partial()              ← 目标没有则跨 node 搜索
    │
    ├─ new_slab() → allocate_slab()       页分配器
    │   └─ shuffle_freelist()             ← 随机化 freelist head
    │
    ├─ alloc_from_new_slab()              把 slab 对象填充到 sheaf
    │   └─ pcs->main = new full sheaf
    │
    └─ [debug] set_track()                 记录 alloc 堆栈
        └─ 返回 object ✓
```

## 四、Freelist 随机化：分配器熵

### 4.1 为什么随机化 freelist head？

**防止 exploit**：攻击者如果知道某个 cache 的对象布局，就能构造 use-after-free 和 heap grooming 等攻击。传统的 slab 分配器的 freelist 严格按照分配顺序排列（head → tail），攻击者通过观察分配序列可以预测下一个对象地址。**随机化 freelist head 后，每次分配从不可预测的位置取对象，破坏攻击者的预测能力。**

### 4.2 实现：预计算随机序列 + `shuffle_freelist()`

**初始化** (slub.c:3320)：

```c
static void __init init_freelist_randomization(void)
{
    list_for_each_entry(s, &slab_caches, list)
        init_cache_random_seq(s);
}
```

每个 `kmem_cache` 在创建时通过 `init_cache_random_seq()` 生成一个 `random_seq[]` 数组，长度为 `oo_objects(s->oo)`（slab 最大对象数），存放在 `s->random_seq`。

**shuffle_freelist()** (slub.c:3356) 在 `new_slab()` 分配新 slab 后调用：

```c
static bool shuffle_freelist(struct kmem_cache *s, struct slab *slab,
			     bool allow_spin)
{
    // slab->objects < 2 → 不需要 shuffle
    // !s->random_seq → 编译时没启用 freelist 随机化

    freelist_count = oo_objects(s->oo);
    if (allow_spin)
        pos = get_random_u32_below(freelist_count);  // 安全随机
    else
        pos = prandom_u32_state(state) % freelist_count;  // per-CPU state

    start = fixup_red_left(s, slab_address(slab));
    cur = next_freelist_entry(s, &pos, start, page_limit, freelist_count);
    slab->freelist = cur;                    // 随机 head

    for (idx = 1; idx < slab->objects; idx++) {
        next = next_freelist_entry(...);
        set_freepointer(s, cur, next);
        cur = next;
    }
    set_freepointer(s, cur, NULL);
}
```

`next_freelist_entry()` 使用预计算的 `s->random_seq[pos]` 作为索引，取 Slab 内第 idx 个对象作为 freelist 的下一个元素。这实际上是**将预随机化的单链表替换原本按顺序排列的 freelist**。

### 4.3 `stack_depot` 关系

`stack_depot` (mm/slab.h 引用 `<linux/stackdepot.h>`) 用于 **`SLAB_STORE_USER` 模式下记录分配/释放堆栈**：

- `set_track_prepare()` → `stack_trace_save()` → `stack_depot_save()` 将堆栈保存到 depot
- `slub_debug` 开启 `SLAB_STORE_USER` 时，每个对象尾部追加 `struct track { unsigned long addr; depot_stack_handle_t handle; }`
- `stack_depot` 是**全局堆栈去重存储**（类似 flyweight 模式），相同堆栈只存一份，handle 跨 slab 复用

**与 freelist 随机的关系**：`stack_depot` 用于调试/溯源，不直接参与随机化。随机化由 `s->random_seq` 独立完成，两者正交。

### 4.4 `CONFIG_SLAB_FREELIST_HARDENED`

额外的安全层：对 freelist 指针做 **XOR 混淆**（slub.c:504）：

```c
static inline freeptr_t freelist_ptr_encode(const struct kmem_cache *s,
					    void *ptr, unsigned long ptr_addr)
{
#ifdef CONFIG_SLAB_FREELIST_HARDENED
    encoded = (unsigned long)ptr ^ s->random ^ swab(ptr_addr);
    // 读取时反向 XOR 解密
#endif
}
```

即使攻击者获得了 freelist 指针，也要知道 `s->random` 和地址才能解密出真实对象指针。

## 五、`slub_debug` 实现：红区、Poison 与 alloc_track

### 5.1 Debug 标志体系

```c
// slub.c:979
static slab_flags_t slub_debug = DEBUG_DEFAULT_FLAGS;

// slub.c:273
#define DEBUG_DEFAULT_FLAGS (SLAB_POISON | SLAB_STORE_USER)

// slub.c:288
#define DEBUG_METADATA_FLAGS (SLAB_RED_ZONE | SLAB_POISON | SLAB_STORE_USER)
```

可用 flags：`SLAB_RED_ZONE`（对象两侧红区）、`SLAB_POISON`（毒值填充）、`SLAB_STORE_USER`（跟踪 alloc/free）、`SLAB_CONSISTENCY_CHECKS`（一致性检测）。

### 5.2 红区 (Red Zone) 检测越界

`SLAB_RED_ZONE` 在每个对象两侧插入保护区域，写入 `SLUB_RED_ACTIVE` (0xcc)：

```
[RedZone][Object][RedZone][Padding][Object][RedZone]...
 ↑ 4-byte    ↑ obj      ↑ 4-byte
```

`check_bytes_and_report()` (slub.c:1297) 验证红区：

```c
static bool check_bytes_and_report(..., u8 *addr, char *expected,
				   u8 *v, unsigned int bytes)
{
    // 遍历 expected[] 与 v[] 比较
    // 不匹配 → print_trailer() → dump 对象内容和红区
}
```

`slub_debug_orig_size()` 区分原始对象大小和含红区/调试元数据的扩展大小。

### 5.3 Poison（毒值填充）

`SLAB_POISON` 模式下：

- **分配时**：`init_object()` 调用 `setup_object()` → `do_dtor()` 之后对对象内容填充 `POISON_FREE` (0x6b) 或 `POISON_END` (0xba)
- **释放时**：`free_slab()` 中对整个 slab 调用 `slab_pad_check()` 和 `check_object()`，验证 `SLUB_RED_INACTIVE` (0xc5)

```c
// slub.c:1274
memset_no_sanitize_memory(p, POISON_FREE, poison_size - 1);
memset_no_sanitize_memory(p + poison_size - 1, POISON_END, 1);
memset_no_sanitize_memory(p + poison_size, val, s->inuse - poison_size);
```

### 5.4 alloc_track — 分配堆栈跟踪

`SLAB_STORE_USER` 下每个对象尾部附加 `struct track`：

```c
// slub.c:1031
static noinline depot_stack_handle_t set_track_prepare(gfp_t gfp_flags)
{
    unsigned long entries[TRACK_ADDRS_COUNT];
    unsigned int nr_entries;
    nr_entries = stack_trace_save(entries, ARRAY_SIZE(entries), 3);
    return stack_depot_save(entries, nr_entries, gfp_flags);
}

static __always_inline void set_track(struct kmem_cache *s, void *object,
    enum track_item alloc, unsigned long addr, gfp_t gfp_flags)
{
    struct track *p = object + get_info_end(s) + alloc;
    depot_stack_handle_t handle = set_track_prepare(gfp_flags);
    set_track_update(s, object, alloc, addr, handle);
}
```

在 `___slab_alloc()` 成功路径调用 `set_track()` 记录分配点，调试时可追溯对象来源。

## 六、Shrink 路径：与 vmscan 配合

### 6.1 `kmem_cache_shrink()` 入口

```c
// slub.c:8254
int __kmem_cache_shrink(struct kmem_cache *s)
{
    return __kmem_cache_do_shrink(s);
}

static int __kmem_cache_do_shrink(struct kmem_cache *s)
{
    // 遍历所有 node
    for_each_kmem_cache_node(s, node, n) {
        // 1. 刷新所有 CPU sheaves（防止分配中途的缓存残留）
        flush_all(s);

        // 2. 缩小 node_barn（barn_shrink）
        barn_shrink(s, n->barn);

        // 3. 扫描 partial 链表，空 slab 释放
        // ...
    }
    return 0;
}
```

### 6.2 `barn_shrink()` — 归还 sheaf 到 partial

```c
// slub.c:3236
static void barn_shrink(struct kmem_cache *s, struct node_barn *barn)
{
    // spin_lock(barn->lock)
    // 将 sheaves_full / sheaves_empty 中的 slab 逐个：
    //   - 如果 sheaf 还有空闲对象 → 尝试合并到 partial
    //   - 如果 sheaf 已完全为空 → 释放 slab 页
}
```

### 6.3 与 vmscan 的配合

SLUB 本身不直接参与 memory reclaim，但 `list_lru` 机制允许 slab 对象在内存压力时被 LRU 驱逐。当 `SLAB_STORE_USER` 开启且 `CONFIG_MEMCG` 时，`memcg_slab_post_alloc_hook()` 将 slab 对象接入 memcg LRU。

`objects per slab` 动态调整发生在 `allocate_slab()` → `oo_order()` 根据对象大小和页阶计算，若对象很大（超过 `PAGE_SIZE`）会降为单页 slab。

## 七、NUMA 亲和性

### 7.1 分配节点选择顺序

```
kmem_cache_alloc_node(s, gfp, node)
  → slab_alloc_node(..., node, ...)
      → alloc_from_pcs()
          → node != NUMA_NO_NODE && node != numa_mem_id()
              → stat(ALLOC_NODE_MISMATCH) → 返回 NULL
              → ___slab_alloc() 慢速路径
```

在 `alloc_from_pcs()` 中，如果请求特定 node 但 percpu sheaf 中的对象来自不同 node，验证失败返回 NULL，强制走慢速路径并通过 `get_from_partial_node()` 补充。

### 7.2 `get_from_partial()` 的节点策略

```c
// slub.c:3915
object = get_from_partial_node(s, get_node(s, searchnode), pc);
// searchnode = (node == NUMA_NO_NODE) ? numa_mem_id() : node

if (object || (node != NUMA_NO_NODE && (pc->flags & __GFP_THISNODE)))
    return object;

// 没有则从任意 node 的 partial 获取
return get_from_any_partial(s, pc);
```

即：默认情况下从**本地内存节点**分配；指定了 `__GFP_THISNODE` 则绝不离跨节点；其他情况允许 fallback 到其他节点的 partial。

### 7.3 mempolicy 集成

`alloc_from_pcs()` 和 `__slab_alloc_node()` 都会检查 `strict_numa` 分支 (CONFIG_NUMA)：

```c
if (static_branch_unlikely(&strict_numa) && node == NUMA_NO_NODE) {
    struct mempolicy *mpol = current->mempolicy;
    if (mpol) {
        if (mpol->mode != MPOL_BIND || !node_isset(numa_mem_id(), mpol->nodes))
            node = mempolicy_slab_node();  // 从 mempolicy 获取目标 node
    }
}
```

### 7.4 NUMA 分配代价取舍

| 场景 | 行为 | 代价 |
|------|------|------|
| 跨 node 分配 | 触发 `ALLOC_NODE_MISMATCH`，分配延迟高 | 访问远程 node 延迟（~100ns vs 本地 ~50ns） |
| 本地分配 | `numa_mem_id()` → 从本地 node 分配 | 最小延迟 |
| `__GFP_THISNODE` | 绝不离本 node，partial 没有直接失败 | 适合延迟敏感、绑核场景 |
| `MPOL_BIND` | 遵守 cgroup mempolicy 绑定 | 可控但可能造成远端访问 |

`memcpy` 代价与 NUMA 配置密切相关：跨 node 内存复制需要 QPI/UPI 互联，延迟比本地内存复制高 2-4 倍。对于大对象 `kmalloc`（通常 > 128B），NUMA 局部性影响更显著。

## 八、Per-CPU Freelist 竞争分析

### 8.1 竞争来源

每个 CPU 有独立的 `slub_percpu_sheaves`，分配和释放路径**完全无锁**（`local_trylock` 只防止同 CPU 的中断嵌套，不防止多 CPU 并发）：

```
CPU0: alloc_from_pcs()     CPU1: free_slab()
  │                            │
  ├─ local_trylock() ✓         ├─ local_trylock() ✓ (不同 CPU)
  ├─ pcs->main->size--         ├─ push to rcu_free
  └─ return object             └─ done
```

**不同 CPU 永远不会竞争同一个 sheaf**，因为每个 CPU 的 `cpu_sheaves` 是独立的 per-CPU 变量（`DEFINE_PER_CPU`）。

真正的竞争场景在于 **`kmem_cache_node.partial` 链表**（跨 CPU 共享）：
- 当 CPU 的 sheaf 空了，从 `node_barn` 取 sheaf，而 `node_barn` 的 `sheaves_full` 链表需要 `barn->lock`
- `get_from_partial()` 需要 `get_node(s, node)->list_lock`

### 8.2 `local_trylock` 机制

```c
struct local_trylock {
    local_t lock;
};
// local_trylock 实际上是 per-CPU 的 local_t
// trylock 语义：本地 CPU 可重入，中断上下文安全
// 不同 CPU 的 local_t 地址不同，所以天然无竞争
```

### 8.3 性能保持的关键

1. **O(1) 无锁分配**：大部分分配（无 debug、无 TINY）在 `alloc_from_pcs()` 中 2 次 `local_trylock/unlock` + 1 次内存读 → 通常 < 20ns
2. **spare sheaf 机制**：避免每次都去 node_barn 补充，批量 refill 成本均摊
3. **batch 分配**：`alloc_from_pcs_bulk()` 一次取多个对象，减少 lock 次数
4. **无全局竞争**：快速路径完全不访问任何共享数据结构（`partial` 链表、`kmem_cache_node`），只有慢速路径才需要

### 8.4 竞争热点的避免

当多个 CPU 同时耗尽本地 sheaf，进入 `barn_replace_empty_sheaf()` 时竞争 `node_barn->lock`。但 `barn_shrink()` 在 shrink 时会批量归还 sheaf 到 partial，降低竞争压力。

## 九、完整对象生命周期图

```
分配 (kmem_cache_alloc)
│
├─ alloc_from_pcs()              [快速路径, CPU 本地, O(1)]
│   ├─ local_trylock ✓
│   ├─ pcs->main->size > 0?
│   │   YES → object = pcs->main->objects[--size]
│   │   NO  → __pcs_replace_empty_main()
│   │         ├─ spare 有对象 → swap → 取
│   │         └─ barn_replace_empty_sheaf() → node_barn 补充
│   └─ local_unlock
│
└─ (失败时) __slab_alloc_node()   [慢速路径]
    │
    ├─ mempolicy 处理 (strict_numa)
    │
    ├─ ___slab_alloc()
    │   ├─ get_from_partial()
    │   │   ├─ get_from_partial_node(target_node)
    │   │   └─ get_from_any_partial() (fallback)
    │   ├─ new_slab()
    │   │   ├─ allocate_slab() → 页分配器
    │   │   └─ shuffle_freelist() → 随机化 freelist head
    │   ├─ (debug) set_track() → stack_depot 保存分配堆栈
    │   └─ alloc_from_new_slab()
    │
    └─ slab_post_alloc_hook()

释放 (kmem_cache_free)
│
├─ (RCU 路径) kfree_rcu() → rcu_free sheaf
│   └─ delayed_free() 在 rcu_callback 中处理
│
└─ 普通释放 → 推送到 CPU sheaf 的 main 或 rcu_free
    ├─ local_trylock ✓
    ├─ push object
    ├─ 如果 main 满了 → barn_put_full_sheaf() 卸载到 node_barn
    └─ local_unlock

 Shrink (kmem_cache_shrink)
 │
 ├─ flush_all() → 刷新所有 CPU sheaves
 ├─ barn_shrink() → 归还 node_barn sheaves
 └─ scan partial lists → 释放空 slab
```

## 十、关键源码索引

| 主题 | 函数 / 符号 | 文件位置 |
|------|------------|---------|
| CPU sheaves 分配 | `alloc_from_pcs()` | slub.c:4704 |
| 批量分配 | `alloc_from_pcs_bulk()` | slub.c:4783 |
| sheaf 替换 | `__pcs_replace_empty_main()` | slub.c:4591 |
| 慢速分配 | `___slab_alloc()` | slub.c:4405 |
| partial 取对象 | `get_from_partial()` | slub.c:3915 |
| new slab 分配 | `new_slab()` | slub.c:3518 |
| freelist 随机化 | `shuffle_freelist()` | slub.c:3356 |
| random_seq 初始化 | `init_cache_random_seq()` | slub.c:3320 |
| 红区检测 | `check_bytes_and_report()` | slub.c:1297 |
| poison 填充 | `init_object()` → `setup_object()` | slub.c:876 |
| 分配堆栈跟踪 | `set_track()` | slub.c:1064 |
| stack_depot 保存 | `set_track_prepare()` | slub.c:1031 |
| shrink 入口 | `__kmem_cache_do_shrink()` | slub.c:8184 |
| barn 收缩 | `barn_shrink()` | slub.c:3236 |
| freelist 指针编码 | `freelist_ptr_encode()` | slub.c:504 |
| node_barn 定义 | `struct node_barn` | slub.c:396 |
| slab_sheaf 定义 | `struct slab_sheaf` | slub.c:404 |
| percpu sheaves | `struct slub_percpu_sheaves` | slub.c:420 |
| kmem_cache_node | `struct kmem_cache_node` | slub.c:430 |
| slab 结构 | `struct slab` | slab.h:74 |

## 总结

SLUB 的设计哲学是**最大程度减少全局竞争**：CPU 本地 sheaves 实现 lockless O(1) 分配，node_barn 作为跨 CPU 的批量缓冲层，kmem_cache_node.partial 作为最后兜底的全局链表。Freelist 随机化通过预计算的 `random_seq[]` 在 slab 分配时对 freelist head 进行不可预测的初始化，配合 `SLAB_FREELIST_HARDENED` 的指针 XOR 混淆，构建纵深防御。Debug 体系（红区、Poison、alloc_track）利用 `stack_depot` 做全局堆栈去重存储，开销可控。

---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `mm/slub.c` | 660 | 16 | 356 | 105 |

### 核心数据结构

- **partial_context** `slub.c:217`
- **partial_bulk_context** `slub.c:223`
- **track** `slub.c:309`
- **node_barn** `slub.c:396`
- **slab_sheaf** `slub.c:404`
- **(anonymous union)** `slub.c:405`
- **(anonymous struct)** `slub.c:409`
- **slub_percpu_sheaves** `slub.c:420`
- **kmem_cache_node** `slub.c:430`
- **slub_flush_work** `slub.c:486`
- **defer_free** `slub.c:6168`
- **detached_freelist** `slub.c:6955`
- **location** `slub.c:8731`
- **loc_track** `slub.c:8745`
- **slab_attribute** `slub.c:8981`
- **saved_alias** `slub.c:9622`

### 关键函数

- **kmem_cache_debug** `slub.c:230`
- **fixup_red_left** `slub.c:235`
- **sysfs_slab_add** `slub.c:322`
- **debugfs_slab_add** `slub.c:328`
- **stat** `slub.c:374`
- **stat_add** `slub.c:385`
- **get_node** `slub.c:441`
- **get_barn_node** `slub.c:446`
- **get_barn** `slub.c:454`
- **freelist_ptr_encode** `slub.c:504`
- **freelist_ptr_decode** `slub.c:517`
- **get_freepointer** `slub.c:530`
- **set_freepointer** `slub.c:541`
- **freeptr_outside_object** `slub.c:556`
- **get_info_end** `slub.c:565`
- **order_objects** `slub.c:579`
- **oo_make** `slub.c:584`
- **oo_order** `slub.c:594`
- **oo_objects** `slub.c:599`
- **slab_test_pfmemalloc** `slub.c:608`
- **slab_set_pfmemalloc** `slub.c:613`
- **__slab_clear_pfmemalloc** `slub.c:618`
- **slab_lock** `slub.c:626`
- **slab_unlock** `slub.c:631`
- **__update_freelist_fast** `slub.c:636`
- **__update_freelist_slow** `slub.c:649`
- **__slab_update_freelist** `slub.c:675`
- **slab_update_freelist** `slub.c:701`
- **set_orig_size** `slub.c:734`
- **get_orig_size** `slub.c:748`
- **need_slab_obj_exts** `slub.c:777`
- **obj_exts_size_in_slab** `slub.c:791`
- **obj_exts_offset_in_slab** `slub.c:796`
- **obj_exts_fit_within_slab_leftover** `slub.c:806`
- **obj_exts_in_slab** `slub.c:815`

### 全局变量

- **slub_debug_enabled** `slub.c:208`
- **strict_numa** `slub.c:213`
- **slab_nodes** `slub.c:473`
- **slab_barn_nodes** `slub.c:479`
- **flushwq** `slub.c:484`
- **flush_lock** `slub.c:492`
- **slub_flush** `slub.c:493`
- **object_map** `slub.c:909`
- **object_map_lock** `slub.c:910`
- **slub_debug** `slub.c:981`
- **slub_debug_string** `slub.c:984`
- **disable_higher_order_debug** `slub.c:985`
- **param_ops_slab_debug** `slub.c:1927`
- **__param_str_slab_debug** `slub.c:1931`
- **__param_slab_debug** `slub.c:1931`

### 成员/枚举

- **flags** `slub.c:218`
- **orig_size** `slub.c:219`
- **flags** `slub.c:224`
- **min_objects** `slub.c:225`
- **max_objects** `slub.c:226`
- **slabs** `slub.c:227`
- **addr** `slub.c:310`
- **handle** `slub.c:312`
- **cpu** `slub.c:314`
- **pid** `slub.c:315`
- **when** `slub.c:316`
- **lock** `slub.c:397`
- **sheaves_full** `slub.c:398`
- **sheaves_empty** `slub.c:399`
- **nr_full** `slub.c:400`
- **nr_empty** `slub.c:401`
- **callback_head** `slub.c:406`
- **barn_list** `slub.c:407`
- **capacity** `slub.c:410`
- **pfmemalloc** `slub.c:411`

