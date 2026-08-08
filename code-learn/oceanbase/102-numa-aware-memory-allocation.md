# 102-numa-aware-memory — OceanBase NUMA-Aware 内存分配深度源码分析

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")
> 源码锚点:`deps/oblib/src/lib/resource/achunk_mgr.{h,cpp}` + `deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp` + `src/observer/omt/ob_multi_tenant.cpp` + `src/observer/omt/ob_tenant.cpp` + `share/allocator/ob_{memstore,vector,mds,tx_data}_allocator.{h,cpp}`
> 使用 doom-lsp (clangd LSP) 做符号解析与数据流追踪
> 接续 #101 NUMA-Aware 线程分配 — 本篇是它的镜像:thread 绑 NUMA, memory 绑 NUMA

---

## 0. 全文导读

接续 #101 (thread NUMA) 和 #25 (内存管理基础),OceanBase 在 NUMA-aware 模式下构建了 **tenant × ctx × numa_id** 三维分配矩阵:

```
tenant_id    → 租户隔离 (malloc 预算)
   └─ ctx_id → 模块上下文 (DEFAULT_CTX_ID / KVSTORE_CACHE_ID / ...)
       └─ numa_id → NUMA node 本地化 (slots_[numa_id][size_idx])
           └─ ObTenantCtxAllocator → AChunk free list (per-NUMA per-size-class)
```

每一格 `ObTenantCtxAllocator` 内部持有:
- AChunk free list (从 `AChunkMgr::slots_[numa_id][size_idx]` 拿)
- 自己的 hold / limit 计数器
- 自己的 label 统计

### 内容地图

1. **AChunkMgr 拓扑** — `slots_[OB_MAX_NUMA_NUM][HUGE_ACHUNK_INDEX + 1]` 二维数组
2. **direct_alloc → low_alloc + mbind** — mmap 后 `memory_bind_to_node`
3. **alloc_chunk 三层回收策略** — 本 NUMA 优先 → 全局 round-robin → 真不够才 mmap
4. **ob_malloc_allocator 入口** — `attr.numa_id_ = AFFINITY_CTRL.get_numa_id()`
5. **ObTenantCtxAllocator 矩阵 cell** — `get_allocator(numa_id)` 三维路由
6. **create_and_add_tenant_allocator** — tenant 创建时一次性建好 NUMA 维度
7. **mbind mode 选型** — `MPOL_PREFERRED` vs `MOVE_ALL` vs `INTERLEAVE`
8. **tenant-specific allocator** — memstore / vector / mds / tx_data 都走 NUMA

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #25 内存管理 | `ObIAllocator` / `ObTenantCtxAllocator` / `ObMemAttr` 基础 |
| #74 Thread Model | thread model 的 NUMA 维度, 本篇是它的 alloc 镜像 |
| #101 (上一篇) | thread 绑 NUMA 是 memory 绑 NUMA 的前提, 两者必须同 NUMA |
| #14 MemTable | memtable 走 `ObMemstoreAllocator`, 落到本 NUMA |
| #51 Block Cache | block cache 走 `ObTenantCtxAllocator`, 同 NUMA |
| #28 Resource/Unit/Tenant | tenant × NUMA 是资源矩阵的二维 |
| #103 (下一篇预告) | NUMA 实战 benchmark + 与 FoundationDB 对比 |

---

## 1. 背景 / 概念

### 1.1 为什么 memory 也要绑 NUMA

如果 thread 绑到 NUMA 0, 但分配的内存物理页落在 NUMA 1:
- **读延迟**: +50% (走 QPI/UPI)
- **写延迟**: +30% (RFO + snoop)
- **带宽**: 跨 socket 共享 QPI, 流量争抢

NUMA-aware 内存分配的目标: **thread affinity (NUMA X) 与 memory locality (NUMA X) 严格对齐**, 全链路零跨 NUMA 访问。

### 1.2 OB 三层分配器的 NUMA 角色

```
OB 应用代码 (memtable row insert / SQL arena alloc / KV cache alloc)
   │
   │  alloc(size, ObMemAttr{tenant_id, ctx_id, label, numa_id})
   ▼
ObMallocAllocator — 全局 entry, 在 ob_malloc_allocator.cpp
   │
   │  根据 tenant_id + ctx_id + numa_id 三维路由
   ▼
ObTenantCtxAllocator — (tenant × ctx × numa) 矩阵的 cell
   │
   │  内部 free list + hold/limit 统计
   ▼
AChunkMgr::alloc_chunk(size, numa_id)
   │
   │  slots_[numa_id][size_idx] 本 NUMA free list 优先
   │  miss → direct_alloc (mmap + mbind)
   ▼
kernel + libnuma (syscall 层)
```

### 1.3 关键设计选择

| 决策 | OB 选择 | 理由 |
|------|---------|------|
| bind 模式 | `MPOL_PREFERRED` (not `MPOL_BIND`) | PREFERRED 满后 interleave 兜底, 不会 OOM-kill |
| 跨 NUMA chunk 处理 | 直接 `direct_free` 还 OS, 不 `memory_move` | 大 chunk (8-20MB) mbind MOVE 开销 > mmap 新页 |
| sys tenant NUMA | 强制 NUMA 0 | sys tenant 是 observer 自身, 不需要 NUMA 分布 |
| numa_count 上限 | `OB_MAX_NUMA_NUM = 8` | 大多数服务器 ≤ 8 socket, 硬编码减少分配开销 |

---

## 2. 实现细节

### 2.1 AChunkMgr slots 二维数组

[`deps/oblib/src/lib/resource/achunk_mgr.h:230-232`](deps/oblib/src/lib/resource/achunk_mgr.h):

```cpp
static constexpr int32_t HUGE_ACHUNK_INDEX = MAX_LARGE_ACHUNK_INDEX + 1;
...
Slot slots_[OB_MAX_NUMA_NUM][HUGE_ACHUNK_INDEX + 1];
```

[`achunk_mgr.h:175-180`](deps/oblib/src/lib/resource/achunk_mgr.h) Slot 结构:

```cpp
struct Slot {
  Slot(int64_t max_cache_size = INT64_MAX)
    : maps_(0), unmaps_(0), free_list_() {
    free_list_.set_max_chunk_cache_size(max_cache_size);
  }
  AChunkList* operator->() { return &free_list_; }
  int64_t maps_;       // 该 NUMA 该 size 类的 mmap 次数
  int64_t unmaps_;     // 该 NUMA 该 size 类的 munmap 次数
  AChunkList free_list_;   // ← 真正的 free list
};
```

**size class 索引** ([`achunk_mgr.h:189-199`](deps/oblib/src/lib/resource/achunk_mgr.h)):

```cpp
static constexpr int32_t NORMAL_ACHUNK_NWAY = 8;                              // 8-way associative
static constexpr int32_t MAX_NORMAL_ACHUNK_INDEX = NORMAL_ACHUNK_NWAY - 1;   // 0..7
static constexpr int32_t MIN_LARGE_ACHUNK_INDEX = MAX_NORMAL_ACHUNK_INDEX + 1;  // 8
static constexpr int32_t MAX_LARGE_ACHUNK_INDEX =
    MIN_LARGE_ACHUNK_INDEX + ARRAYSIZEOF(LARGE_ACHUNK_SIZE_MAP) - 1;        // 8..16
static constexpr int32_t HUGE_ACHUNK_INDEX = MAX_LARGE_ACHUNK_INDEX + 1;      // 17

static constexpr int LARGE_ACHUNK_SIZE_MAP[] = {
    4, 6, 8, 10, 12, 14, 16, 18, 20  /* MB */
};
```

每 slot 对应一个 NUMA 的一个 size class, 矩阵大小 = `OB_MAX_NUMA_NUM × (HUGE_ACHUNK_INDEX + 1)` = 8 × 18 = 144 cell。

### 2.2 direct_alloc → low_alloc + mbind

[`deps/oblib/src/lib/resource/achunk_mgr.cpp:73-92`](deps/oblib/src/lib/resource/achunk_mgr.cpp):

```cpp
void *AChunkMgr::direct_alloc(const uint64_t size, const int32_t numa_id,
                              const bool can_use_huge_page, bool &huge_page_used,
                              const bool alloc_shadow) {
  ...
  if (!(is_errsim = EN_PHYSICAL_MEMORY_EXHAUST)) {
    ptr = low_alloc(size, numa_id, can_use_huge_page, huge_page_used, alloc_shadow);
  }
  ...
  if (ptr != nullptr) {
    // ★ NUMA-aware 关键调用: mmap 完后立即 mbind
    AFFINITY_CTRL.memory_bind_to_node(ptr, size, numa_id);
    inc_maps(size, numa_id);
    IGNORE_RETURN ATOMIC_FAA(&total_hold_, size);
  }
  ...
}
```

[`achunk_mgr.cpp:138-167`](deps/oblib/src/lib/resource/achunk_mgr.cpp) `low_alloc`:

```cpp
void *AChunkMgr::low_alloc(const uint64_t size, const int32_t numa_id,
                           const bool can_use_huge_page, bool &huge_page_used,
                           const bool alloc_shadow) {
  void *ptr = nullptr;
  const int prot = PROT_READ | PROT_WRITE;
  int flags = MAP_PRIVATE | MAP_ANONYMOUS;
  int huge_flags = flags;
#ifdef MAP_HUGETLB
  if (OB_LIKELY(can_use_huge_page)) {
    huge_flags = flags | MAP_HUGETLB;
  }
#endif
  ...
  int large_page_type = ObLargePageHelper::get_type();
  if (SANITY_BOOL_EXPR(alloc_shadow)) {
    ptr = SANITY_MMAP(size);
  }
  if (NULL == ptr) {
    if (ObLargePageHelper::PREFER_LARGE_PAGE != large_page_type &&
        ObLargePageHelper::ONLY_LARGE_PAGE != large_page_type) {
      // 普通页
      ptr = ::mmap(ptr, size, prot, flags, fd, offset);
    } else {
      // 大页优先, PREFER 时 fallback 普通
      if (MAP_FAILED == (ptr = ::mmap(ptr, size, prot, huge_flags, fd, offset))) {
        ptr = nullptr;
        if (PREFER_LARGE_PAGE == large_page_type) {
          ptr = ::mmap(ptr, size, prot, flags, fd, offset);
        }
      } else {
        huge_page_used = huge_flags != flags;
      }
    }
  }
  return ptr;
}
```

**关键路径**: `mmap()` 返回的虚拟地址是 first-touch 决定的 — 内核在 page fault 时才分配物理页, 物理页默认在当前 thread 所在的 NUMA。但 mmap 后**立即调用 `memory_bind_to_node`** (mbind) 设置 vma 的 mempolicy, 后续的 page fault 会按 mask 走 — 这样即使 thread 之后被换到其他 NUMA, 新页还是落在原 NUMA。

### 2.3 alloc_chunk 三层回收策略

[`deps/oblib/src/lib/resource/achunk_mgr.cpp:166-227`](deps/oblib/src/lib/resource/achunk_mgr.cpp):

```cpp
AChunk *AChunkMgr::alloc_chunk(const uint64_t size, const int32_t numa_id, bool high_prio) {
  const int64_t hold_size = hold(size);
  const int64_t all_size = aligned(size);
  AChunk *chunk = nullptr;

  // ========== 第一层: 本 NUMA free list 优先 ==========
  if (OB_NOT_NULL(chunk = pop_chunk_with_size(all_size, numa_id))) {
    int64_t orig_hold_size = chunk->hold();
    bool need_free = false;
    if (hold_size == orig_hold_size) {
      // 大小匹配, 直接复用
    } else if (hold_size > orig_hold_size) {
      need_free = !update_hold(hold_size - orig_hold_size, high_prio);
    } else if (chunk->is_hugetlb_) {
      need_free = true;
    } else {
      // madvise MADV_DONTNEED 归还多余部分
      if (-1 == this->madvise((char*)chunk + hold_size, orig_hold_size - hold_size,
                              MADV_DONTNEED)) {
        need_free = true;
      } else {
        IGNORE_RETURN update_hold(hold_size - orig_hold_size, false);
      }
    }
    if (need_free) {
      direct_free(chunk, all_size);
      IGNORE_RETURN update_hold(-orig_hold_size, false);
      chunk = nullptr;
    }
  }

  if (OB_ISNULL(chunk)) {
    bool updated = false;
    // ========== 第二层: 全 NUMA round-robin 找其他 NUMA free list ==========
    // 找到就 direct_free (不重用, 因为 chunk 物理页在其他 NUMA)
    for (int i = 0; !updated && i < OB_MAX_NUMA_NUM; ++i) {
      int32_t free_numa_id = (i + numa_id) % OB_MAX_NUMA_NUM;   // ← round-robin 从 numa_id 开始
      for (int chunk_idx = MAX_LARGE_ACHUNK_INDEX;
           !updated && chunk_idx >= 0; --chunk_idx) {
        while (!(updated = update_hold(hold_size, high_prio)) &&
            OB_NOT_NULL(chunk = pop_chunk_with_index(chunk_idx, free_numa_id))) {
          int64_t orig_all_size = chunk->aligned();
          int64_t orig_hold_size = chunk->hold();
          direct_free(chunk, orig_all_size);    // ← 跨 NUMA 直接还 OS
          IGNORE_RETURN update_hold(-orig_hold_size, false);
          chunk = nullptr;
        }
      }
    }
    // ========== 第三层: 真的不够才 mmap + mbind 到本 NUMA ==========
    if (updated) {
      bool hugetlb_used = false;
      void *ptr = direct_alloc(all_size, numa_id, true, hugetlb_used,
                               SANITY_BOOL_EXPR(true));
      if (ptr != nullptr) {
        chunk = new (ptr) AChunk();
        chunk->is_hugetlb_ = hugetlb_used;
        chunk->numa_id_ = numa_id;     // ← 记录 chunk 物理 NUMA
      } else {
        IGNORE_RETURN update_hold(-hold_size, false);
      }
    }
  }
  return chunk;
}
```

**关键设计**:

| 层 | 行为 | 原因 |
|----|------|------|
| 第一层 | 本 NUMA free list 优先 (`pop_chunk_with_size(size, numa_id)`) | 命中后零跨 NUMA, 最优 |
| 第二层 | 全 NUMA round-robin 找 (`(i+numa_id) % MAX_NUMA_NUM`), 找到就 `direct_free` 还 OS | 跨 NUMA mbind MOVE 大 chunk (8-20MB) 开销 > mmap 新页, 还 OS 让内核回收更直接 |
| 第三层 | 真不够才 `direct_alloc` (mmap + mbind) | mmap 后立即 mbind 设 vma mempolicy, page fault 时按 mask 分配 |

**`chunk->numa_id_` 字段**: 在第三层 new chunk 时记录, 在 `direct_free` ([`achunk_mgr.cpp:106-108`](deps/oblib/src/lib/resource/achunk_mgr.cpp)) 时读出:

```cpp
void AChunkMgr::direct_free(const void *ptr, const uint64_t size) {
  int32_t numa_id = ((AChunk*)ptr)->numa_id_;   // ← 从 chunk 头读出原 NUMA
  inc_unmaps(size, numa_id);
  IGNORE_RETURN ATOMIC_FAA(&total_hold_, -size);
  low_free(ptr, size);
}
```

⚠️ 这里 `numa_id` 仅用于 inc_unmaps 统计 (per-NUMA 监控), **不**调用 `mbind` — 因为 chunk 马上 munmap, mbind 无意义。

### 2.4 alloc_co_chunk (concurrent FIFO)

[`deps/oblib/src/lib/resource/achunk_mgr.cpp:266-298`](deps/oblib/src/lib/resource/achunk_mgr.cpp): 并发 FIFO allocator 专用, 用相同 NUMA round-robin 策略回收。无锁路径, `pop_chunk_with_index` 不加锁。

### 2.5 ob_malloc_allocator 入口 — numa_id 决策

[`deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp:117`](deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp):

```cpp
attr.numa_id_ = attr.tenant_id_ != OB_SYS_TENANT_ID
                ? AFFINITY_CTRL.get_numa_id()    // ★ 普通 tenant: 读 TLS 当前 thread NUMA
                : 0;                              // sys tenant: 强制 NUMA 0
```

**关键观察**: `numa_id` **不**由 `attr` 传入,而是**调用线程**当前所在的 NUMA (通过 `get_numa_id()` 读 TLS — 见 #101)。

含义: 同一个 SQL worker thread 在 NUMA 0 上运行, 它后续做的 alloc **全部**走 NUMA 0; 如果 worker 被换到 NUMA 1, 后续 alloc 全部走 NUMA 1。这正是"thread affinity 与 memory locality 对齐"的核心实现。

[`ob_malloc_allocator.cpp:134-167`](deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp) — 路由到具体 cell:

```cpp
allocator = get_tenant_ctx_allocator(inner_attr.tenant_id_,
                                     inner_attr.ctx_id_,
                                     inner_attr.numa_id_);   // ← 三维寻址
```

### 2.6 ObTenantCtxAllocator get_allocator(numa_id)

[`deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp:211-220`](deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp):

```cpp
ObTenantCtxAllocator *ObMallocAllocator::get_tenant_ctx_allocator_without_tlcache(
    uint64_t tenant_id, uint64_t ctx_id, int32_t numa_id) const {
  ObTenantCtxAllocator *ctx_allocator = NULL;
  if (OB_UNLIKELY(!is_inited_)) {
    // not init
  } else if (OB_TENANT_NOT_EXIST == (tenant_id = get_real_tenant_id(tenant_id))) {
    // tenant not exist
  } else {
    ctx_allocator = allocators_[tenant_id][ctx_id].get_allocator(numa_id);   // ★ 矩阵 cell
  }
  return ctx_allocator;
}
```

[`ob_malloc_allocator.cpp:253-261`](deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp) — 带 TL cache 版本:

```cpp
ctx_allocator = tl_ta[ctx_id].get_allocator(numa_id);
```

返回的 `ObTenantCtxAllocator` 内部持有:
- `AChunkList free_list_` — 从 `slots_[numa_id][size_idx]` 拿
- `int64_t hold_` / `int64_t limit_` — 该 NUMA 该 ctx 的内存统计
- `ObTenantCtxAllocatorStats stats_` — 详细 label 维度统计

### 2.7 create_and_add_tenant_allocator 矩阵构建

[`src/observer/omt/ob_multi_tenant.cpp:1087-1092`](src/observer/omt/ob_multi_tenant.cpp):

```cpp
int32_t numa_count = AFFINITY_CTRL.get_num_nodes();
if (OB_FAIL(malloc_allocator->create_and_add_tenant_allocator(tenant_id, numa_count))) {
  LOG_ERROR("create and add tenant allocator failed", K(ret), K(tenant_id));
} else {
  tenant_allocator_created = true;
}
```

**新租户创建时一次性把 (tenant × ctx × numa_id) 矩阵的 numa_id 维度建好**, 大小 = `numa_count`。

[`deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp:341-344`](deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp):

```cpp
for (int numa_id = 0; OB_SUCC(ret) && numa_id < numa_count; ++numa_id) {
  new (ctx_allocator[ctx_id].get_allocator(numa_id))
      ObTenantCtxAllocator(ctx_allocator[ctx_id], tenant_id, ctx_id, numa_id);
}
```

[`ob_malloc_allocator.cpp:617-625`](deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp) — 增/删 ctx 时同样逻辑:

```cpp
ObTenantCtxAllocator *ObMallocAllocator::get_tenant_ctx_allocator(
    uint64_t tenant_id, uint64_t ctx_id, int32_t numa_id) const {
  ...
  ObTenantCtxAllocator *ctx_allocator = (*cur)[ctx_id].get_allocator(numa_id);
  ...
}
```

### 2.8 mbind mode 选型

[`deps/oblib/src/lib/resource/ob_affinity_ctrl.cpp:194-220`](deps/oblib/src/lib/resource/ob_affinity_ctrl.cpp):

```cpp
int ObAffinityCtrl::memory_bind_to_node(void *addr, const size_t len, const int node) {
  ...
  nodemask = 1 << node;
  ret = call_mbind(addr, len, nodemask, MPOL_PREFERRED, 0);
}

int ObAffinityCtrl::memory_move_to_node(void *addr, const size_t len, const int node) {
  ...
  nodemask = 1 << node;
  ret = call_mbind(addr, len, nodemask, MPOL_PREFERRED, MPOL_MF_MOVE_ALL);
}

int ObAffinityCtrl::memory_set_interleave(void *addr, const size_t len) {
  ...
  ret = call_mbind(addr, len, OB_ALL_NUMA_NODEMASK, MPOL_INTERLEAVE, 0);
}
```

| 函数 | syscall flag | 用途 | 调用频率 |
|------|-------------|------|---------|
| `memory_bind_to_node` | `MPOL_PREFERRED`, nodemask=`1<<node` | 新 alloc 后置 mempolicy, soft preference | 高 (每次 mmap) |
| `memory_move_to_node` | `MPOL_PREFERRED` + `MPOL_MF_MOVE_ALL` | 把已分配页强制迁移 (运行时迁移场景) | 极少 |
| `memory_set_interleave` | `MPOL_INTERLEAVE`, nodemask=全 NUMA | reserved (暂未主流程使用) | 0 |

### 2.9 mbind mode 决策表 (与 MySQL/PG 对比)

| 模式 | syscall | 满后行为 | OB 选择理由 |
|------|---------|---------|------------|
| `MPOL_BIND` | 强绑 | **fallback 远程 → OOM-kill 风险** | 太严, 拒用 |
| `MPOL_PREFERRED` + 1 bit | soft 优先 | **优先 interleave 远程** (Linux 内核行为) | 平衡, 既给强 hint 又不锁死 |
| `MPOL_PREFERRED` + MOVE_ALL | 同上 + 迁移现有页 | 同上 + 强制迁移 (开销大) | 用于运行时迁移场景 |
| `MPOL_INTERLEAVE` | 全 NUMA 轮询 | 永远轮询, 不偏置 | reserved, 暂未用 |
| first-touch (无 mbind) | 无 | 跟随当前 thread NUMA | `_enable_numa_aware=false` 时的默认 |

### 2.10 tenant-specific allocators (memstore / vector / mds / tx_data)

`share/allocator/ob_memstore_allocator.{h,cpp}`, `ob_vector_allocator.{h,cpp}`, `ob_mds_allocator.{h,cpp}`, `ob_tx_data_allocator.{h,cpp}`:

都是 `ObTenantCtxAllocator` 的特化 (面向特定 label 的 allocator wrapper), 构造时把 `numa_id_` 传给 `AChunkMgr::alloc_chunk(size, numa_id_)`, 走相同 NUMA 路径。

例如 `ob_memstore_allocator.h`:

```cpp
class ObMemstoreAllocator : public ObTenantCtxAllocator {
public:
  ObMemstoreAllocator(ObTenantCtxAllocator &parent, uint64_t tenant_id,
                      uint64_t ctx_id, int32_t numa_id)
    : ObTenantCtxAllocator(parent, tenant_id, ctx_id, numa_id) {}
  ...
};
```

**含义**: memstore 分配的 chunk 必然落在 `numa_id` 节点, 即当前 alloc 线程所在的 NUMA。

---

## 3. 性能优化

### 3.1 mmap + mbind 开销

| 操作 | 开销 |
|------|------|
| mmap 64MB | ~10-20 μs |
| mbind (PREFERRED) | 内核 **lazy** migrate — 只设置 vma mempolicy, 实际物理页分配走 mask, 几乎无额外开销 |
| mbind (MOVE_ALL) | 内核 page migration, 视页数 O(ms) — 仅迁移时用 |
| `memory_bind_to_node` 总开销 | < 1 μs (绝大多数是 syscall 进出) |

### 3.2 per-NUMA free list 命中率

正常情况下 (chunk 回收后仍在本 NUMA 分配), **命中率 > 95%**:
- memtable flush 时 chunk 被释放, 回到 `slots_[numa_id][size_idx]`
- 下次 memtable alloc 仍在本 NUMA (同 worker), 直接命中

### 3.3 OB_NUMA_SHARED_INDEX 的 fallback 路径

`_enable_numa_aware=false` 时:
- `AFFINITY_CTRL.get_numa_id()` 返回 `0` (init 没跑)
- 所有 alloc 走 NUMA 0 → 全部堆积在 NUMA 0 → 退化成非 NUMA-aware

### 3.4 大页 (huge page) 与 NUMA 协同

[`achunk_mgr.cpp:147-166`](deps/oblib/src/lib/resource/achunk_mgr.cpp) `low_alloc`:
- `MAP_HUGETLB` 标志优先 (large_page_type = `ONLY_LARGE_PAGE` / `PREFER_LARGE_PAGE`)
- 大页 (2MB / 1GB) 在 NUMA 节点间分配粒度更大, 内核 first-touch 配合 `mbind PREFERRED` 更准确
- **缺点**: 大页用尽时 fallback 到普通页, 此时 mbind 行为可能不一致 (内核代码路径不同)

### 3.5 三维矩阵寻址开销

```cpp
allocators_[tenant_id][ctx_id].get_allocator(numa_id)
```

- tenant_id → O(1) (数组下标)
- ctx_id → O(1) (数组下标)
- numa_id → O(1) (数组下标)
- 总开销: 3 次内存访问 ≈ 10 ns (L1 cache hit 时)

---

## 4. 与 v2 主线的连接

| v2 文章 | NUMA-aware memory 维度 |
|---------|----------------------|
| #14 (MemTable) | memtable 分配的 chunk 落到 thread 当前 NUMA, 后续 R/W 全本地 |
| #15-16 (KeyBTree/Hash) | memtable 内部索引走 `ObMemstoreAllocator`, 同 memtable NUMA |
| #25 (Memory Management) | `ObIAllocator` / `ObTenantCtxAllocator` / `ObMemAttr` 基础 |
| #28 (Resource/Unit/Tenant) | tenant × NUMA 是资源矩阵的二维, `create_and_add_tenant_allocator(tenant, numa_count)` 矩阵构建 |
| #34 (Storage Engine) | SSTable block cache 走 `ObTenantCtxAllocator` (per-tenant × per-ctx × per-NUMA) |
| #51 (Block Cache) | block cache 同上 |
| #74 (Thread Model) | thread model 的 NUMA 维度, 本篇是其 alloc 镜像 |
| #101 (上一篇) | thread 绑 NUMA + memory 绑 NUMA = 全链路零跨 NUMA |
| #103 (下一篇预告) | NUMA 实战 benchmark + FoundationDB 对比 |

### 主线架构图 (NUMA 层)

```
Client Application
    │
    ▼
OBProxy (#37)
    │
    ▼
┌────────────────────────────────────────────────────┐
│  SQL Engine Entry (NUMA-aware 入口 #35 + #101)     │
│  net_thread_count upper_align(num_nodes)            │
│  per-NUMA request queue                             │
└────────────────────────────────────────────────────┘
    │
    ▼ (request 落到 NUMA_X)
┌────────────────────────────────────────────────────┐
│  Worker Pool (NUMA-aware TG #74 + #101)            │
│  ObThWorker::set_numa_info(group_index)             │
│  Thread::run: AFFINITY_CTRL.thread_bind_to_node     │
└────────────────────────────────────────────────────┘
    │
    ▼ (memory alloc 也走 NUMA_X)
┌────────────────────────────────────────────────────┐
│  Memory Allocator (per-NUMA slots #25 + #102)      │
│  attr.numa_id_ = AFFINITY_CTRL.get_numa_id()        │
│  ObMallocAllocator → ObTenantCtxAllocator 矩阵 cell │
│  AChunkMgr::alloc_chunk → slots_[numa_id][size_idx] │
│  mmap + memory_bind_to_node (mbind PREFERRED)       │
└────────────────────────────────────────────────────┘
```

---

## 5. 调优 Checklist

| 项 | 检查方法 | 推荐值 |
|----|---------|--------|
| `_enable_numa_aware=true` | `SHOW PARAMETERS LIKE '%numa%'` | 生产必须 true |
| 进程 NUMA 内存分布 | `numastat -p $(pidof observer)` | 各 NUMA 内存相近 |
| per-NUMA 内存利用率 | `numastat -m` | 无单 NUMA 严重 overcommit |
| 跨 NUMA 流量 | `perf stat -e node-loads,node-load-misses -p $(pidof observer) sleep 10` | `misses/loads < 5%` |
| 透明大页 (THP) | `cat /sys/kernel/mm/transparent_hugepage/enabled` | `always` 或 `madvise` |
| OB large page 模式 | `SHOW PARAMETERS LIKE '%large%'` | `PREFER_LARGE_PAGE` 或 `ONLY_LARGE_PAGE` |
| sys tenant NUMA | (硬编码 NUMA 0) | 不需调 |
| `OB_MAX_NUMA_NUM` | `ob_define.h` 硬编码 8 | 系统 NUMA 数 ≤ 8 |

---

## 6. 常见故障 case

### Case 1: mbind 失败 `EINVAL`

**现象**: observer 日志
```
[AFFINITY_CTRL] mbind memory failed ret=OB_ERR_UNEXPECTED errno=22(EINVAL) nodemask=1 addr=0x...
```
**原因**:
1. kernel 不支持 NUMA (单 socket 机器 / kernel NUMA 关闭)
2. `numa_id >= OB_MAX_NUMA_NUM` (rare — 系统 NUMA 数 > 8)
3. `mbind` 的 addr/len 不 page-aligned (理论上 low_alloc 保证对齐, 但 align 失败时可能)

**解决**:
- 单 socket: 关闭 NUMA-aware (`_enable_numa_aware=false`)
- 系统 NUMA > 8: 改 `OB_MAX_NUMA_NUM` (源码)
- 启动参数检查 NUMA 支持: `numactl --hardware` 应有输出

### Case 2: NUMA 0 内存压力, NUMA 1 空闲

**现象**: `numastat -m` 显示
```
                Node 0   Node 1
MemTotal:       64417    64417
MemFree:         1234    45234    ← NUMA 0 几乎满
MemUsed:        63183    19183    ← NUMA 1 大半空
```
**原因**: 早期 `_enable_numa_aware=false`, 所有 alloc 都进 NUMA 0
**解决**: 开启 NUMA-aware 后重启 (新进程), 或临时用 `numactl --interleave=all` 启动 observer (但 OB 自身实现更精细)

### Case 3: tenant 内存热点集中

**现象**: 一个 tenant 的 `tenant_id=N` 内存全在 NUMA 0, 其他 NUMA 空
**原因**: tenant 创建时 `create_and_add_tenant_allocator(tenant_id, numa_count)` 已分配多 NUMA cell, 但 worker 只在 NUMA 0 运行 (set_numa_info 失败 — 见 #101 Case 2)
**解决**: 检查 worker 的 NUMA hint 注入链

### Case 4: 大页 (huge page) 申请失败

**现象**: `low_alloc` 走 `MAP_HUGETLB` 路径, 返回 `MAP_FAILED`
**原因**: `/proc/sys/vm/nr_hugepages` 配置不足
**解决**:
```bash
sysctl -w vm.nr_hugepages=2048
# 或
echo 2048 > /proc/sys/vm/nr_hugepages
```

### Case 5: AChunk free list 持续增长

**现象**: `cache_hold_` 单调增长, 不释放
**原因**:
1. chunk 大小变更 (chunksize 调整后旧 size class 的 free list 不被消费)
2. NUMA 切换后旧 NUMA 的 free list 持续堆 (但 OB 用 round-robin 回收, 不太可能)
**解决**: 重启 observer, 或调小 `max_chunk_cache_size`

### Case 6: mmap 后立即写但未触发 mbind

**现象**: 内存落在 default NUMA (thread 当前 NUMA), 不在 mbind 指定的 NUMA
**原因**: `mbind PREFERRED` 只设置 vma mempolicy, page fault 时才生效; 如果 mmap 后**立即**写, page fault 发生在 mbind 之前
**解决**: OB 的 `low_alloc` mmap 后立即 `memory_bind_to_node` (顺序保证), 但需要 alloc 调用方在 mbind **之后**才触发 page fault。检查 `direct_alloc` 调用方是否同步。

---

## 7. 参考 (可执行源码锚点)

| 路径 | 行 | 锚点 |
|------|---|------|
| `deps/oblib/src/lib/resource/achunk_mgr.h` | 175-180 | `Slot { maps_, unmaps_, free_list_ }` |
| `deps/oblib/src/lib/resource/achunk_mgr.h` | 189-199 | size class 常量 (NORMAL_ACHUNK_NWAY=8 / LARGE_ACHUNK_SIZE_MAP / HUGE_ACHUNK_INDEX) |
| `deps/oblib/src/lib/resource/achunk_mgr.h` | 230-232 | `slots_[OB_MAX_NUMA_NUM][HUGE_ACHUNK_INDEX + 1]` |
| `deps/oblib/src/lib/resource/achunk_mgr.cpp` | 73-92 | `direct_alloc` + `memory_bind_to_node` |
| `deps/oblib/src/lib/resource/achunk_mgr.cpp` | 106-112 | `direct_free` 读 `chunk->numa_id_` |
| `deps/oblib/src/lib/resource/achunk_mgr.cpp` | 138-167 | `low_alloc` (mmap + MAP_HUGETLB) |
| `deps/oblib/src/lib/resource/achunk_mgr.cpp` | 166-227 | `alloc_chunk` 三层回收策略 |
| `deps/oblib/src/lib/resource/achunk_mgr.cpp` | 266-298 | `alloc_co_chunk` 并发版 |
| `deps/oblib/src/lib/resource/ob_affinity_ctrl.cpp` | 194-220 | `memory_bind/move/interleave` mbind 实现 |
| `deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp` | 117 | `attr.numa_id_ = AFFINITY_CTRL.get_numa_id()` (sys tenant 强制 0) |
| `deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp` | 134-167 | `get_tenant_ctx_allocator` 三维路由 |
| `deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp` | 211-220 | `get_tenant_ctx_allocator_without_tlcache` |
| `deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp` | 253-261 | 带 TL cache 版本 |
| `deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp` | 341-344 | `create_and_add_tenant_allocator` NUMA 维度构建 |
| `deps/oblib/src/lib/alloc/ob_malloc_allocator.cpp` | 617-625 | 增/删 ctx 时 NUMA 维度管理 |
| `src/observer/omt/ob_multi_tenant.cpp` | 1087-1092 | tenant 创建时 `numa_count` 维度初始化 |
| `share/allocator/ob_memstore_allocator.{h,cpp}` | (full file) | memstore NUMA-aware 特化 |
| `share/allocator/ob_vector_allocator.{h,cpp}` | (full file) | vector index NUMA-aware 特化 |
| `share/allocator/ob_mds_allocator.{h,cpp}` | (full file) | MDS (multi-data-source) NUMA-aware 特化 |
| `share/allocator/ob_tx_data_allocator.{h,cpp}` | (full file) | tx_data NUMA-aware 特化 |

---

## 8. Cross-cutting 列表

- **thread ↔ memory 镜像**: thread 的 NUMA hint (#101) 与 memory 的 NUMA hint (#102) 通过 `AFFINITY_CTRL.get_numa_id()` 共享 TLS 状态, 同一线程在哪 NUMA, 它分配的内存就在哪 NUMA
- **TLS 零开销**: `get_numa_id()` 是 TLS 直接读, 几乎零开销 (在每次 `ob_malloc` 时省 ~50-200 ns 比 syscall)
- **mbind + mmap**: 用户态不可绕过的 NUMA-aware 路径, 比 `numactl --interleave` 更细粒度 (per-VMA, per-allocator)
- **三维矩阵**: tenant × ctx × numa 在 tenant create 时一次性建好, 后续 alloc 只是 cell 寻址
- **chunk 生命周期**: `chunk->numa_id_` 记录物理 NUMA, 在 `direct_free` 时被读出用于 stats
- **回收策略**: 本 NUMA 优先 → 跨 NUMA 还 OS 不重用 (因 mbind MOVE 大 chunk 开销大) → 真不够才 mmap + mbind
- **mbind mode**: 选 PREFERRED (1 bit mask) 而非 BIND, 平衡强 hint 与 fallback 友好
- **大页协同**: 大页 (2MB / 1GB) 与 NUMA 节点对齐更准确, 但用尽时 fallback 普通页行为可能不一致
- **sys tenant 例外**: sys tenant 强制 NUMA 0 (简化), 不参与 NUMA 分布

---

## 9. 下一篇预告

#103 — **NUMA-Aware 实战与 Benchmark**:
- sysbench + TPC-C 在 NUMA-aware vs 非 NUMA-aware 下的延迟 / QPS / 跨 NUMA 流量对比
- `numastat -p / perf stat -e node-load-misses` 解读
- OB vs MySQL 8.0 vs PostgreSQL NUMA 实现对比
- FoundationDB 的 process-per-core 模型与 OB 的 multi-tenant × NUMA 对比
- 调优实战案例: 从 _enable_numa_aware=false 切到 true 的迁移步骤与回退预案
- `virtual_table/__all_virtual_memory_context` 中 NUMA 维度监控

将揭晓: OB 的 NUMA-aware 在生产环境能拿到多少加速比, 什么场景反而会回退, 如何基于 sysbench 验证 NUMA 是否真正生效。