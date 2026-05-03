# 25 — 内存管理：ObAllocator、MemAttr、内存池体系

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

经过前面 24 篇文章的积累，我们覆盖了 OceanBase 从**存储引擎**（MVCC、Memtable、SSTable、LS-Tree）到 **SQL 层**（优化器、Parser、Plan Cache）再到**分布式系统**（选举、PALF、CLOG、事务）的完整技术栈。

现在，我们将视角转向整个系统最基础的支撑设施——**内存管理**。对于 C++ 编写的高性能数据库来说，内存分配器的设计直接决定了系统的吞吐、延迟、内存碎片和多租户隔离能力。

### 内存管理架构

OceanBase 的内存管理是多层级的，从高到低分为四个层面：

```
        层 1: 模块级分配器        ObArenaAllocator / ObCachedAllocator / ObAllocator
                                      │ 直接由各模块使用
        层 2: 通用分配器接口         ObIAllocator (抽象基类)
                                      │ 委托到具体实现
        层 3: 租户级内存管理         ObMallocAllocator → ObTenantCtxAllocator
                                      │ 按租户 + 上下文隔离
        层 4: 底层页分配器           mmap / ob_malloc / ModulePageAllocator
```

每层解决不同的问题：
- **层 1**：提供特定模式的高效分配（arena 批量释放、对象缓存复用）
- **层 2**：定义统一的 `alloc/free/realloc` 接口，支持 `ObMemAttr` 元数据
- **层 3**：实现租户间内存隔离、限流、统计
- **层 4**：对接操作系统，管理大页分配

### 核心设计演进

OceanBase 的分配器经历了从 V1 到 V2 的演进，两个版本并存：

| 特性 | ObAllocator (V1) | ObAllocator (V2) |
|------|------------------|------------------|
| 文件 | `ob_allocator.h` 第 24 行 | `ob_allocator_v2.h` 第 37 行 |
| 基类 | `ObIAllocator` | `ObIAllocator` |
| 内存跟踪 | 依赖 `ObAllocAlign::Header` 魔法字 | 链表节点 `AllocNode` 跟踪 |
| 并行分配 | 无 | `ObParallelAllocator` 加锁版本 |
| 上下文关联 | `ObMemAttr` 独立传入 | 绑定 `__MemoryContext__` 和 `ObTenantCtxAllocatorGuard` |

### 代码位置

```
deps/oblib/src/lib/allocator/ob_allocator.h           — ObIAllocator 接口, G1/ObWrapperAllocator
deps/oblib/src/lib/allocator/ob_allocator_v2.h        — ObAllocator V2, ObParallelAllocator
deps/oblib/src/lib/allocator/ob_ctx_define.h          — ObCtxAttr, ObCtxAttrCenter
deps/oblib/src/lib/allocator/ob_mod_define.h          — ObCtxIds 枚举, ObModIds 标签定义
deps/oblib/src/lib/allocator/ob_block_alloc_mgr.h     — ObBlockAllocMgr 块分配管理
deps/oblib/src/lib/allocator/ob_cached_allocator.h    — ObCachedAllocator 模板
deps/oblib/src/lib/allocator/page_arena.h             — PageArena, ObArenaAllocator
deps/oblib/src/lib/allocator/ob_concurrent_fifo_allocator.h  — 并发 FIFO 分配器
deps/oblib/src/lib/allocator/ob_delay_free_allocator.h      — 延迟释放分配器
deps/oblib/src/lib/allocator/ob_asan_allocator.h            — ASAN 检测分配器
deps/oblib/src/lib/alloc/alloc_struct.h              — ObMemAttr (第 132 行起)
deps/oblib/src/lib/alloc/ob_malloc_allocator.h       — ObMallocAllocator (全局内存管理器)
```

---

## 1. 核心分配器接口：ObIAllocator

### 1.1 抽象基类

[`ob_allocator.h` 第 63 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_allocator.h:63)定义了 `ObIAllocator`，是所有分配器的抽象基类：

```cpp
class ObIAllocator {
public:
  virtual ~ObIAllocator() {};
  virtual void *alloc(const int64_t size) = 0;
  virtual void* alloc(const int64_t size, const ObMemAttr &attr) = 0;
  virtual void* realloc(const void *ptr, const int64_t size,
                        const ObMemAttr &attr) { return nullptr; }
  virtual void *realloc(void *ptr, const int64_t oldsz,
                        const int64_t newsz) { return nullptr; }
  virtual void free(void *ptr) = 0;
  virtual void set_attr(const ObMemAttr &attr) { UNUSED(attr); }
  virtual int64_t total() const { return 0; }
  virtual int64_t used() const { return 0; }
  virtual void reset() {}
  virtual void reuse() {}
};
```

这个接口的精妙之处在于**双通道设计**：
- `alloc(size)` — 使用预设的 `ObMemAttr`（通过 `set_attr` 设置）
- `alloc(size, attr)` — 每次都指定 `ObMemAttr`

这样既允许了便捷的默认分配，也支持精细化的内存属性控制。

### 1.2 ObWrapperAllocator — 适配器模式

[`ob_allocator.h` 第 123 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_allocator.h:123)提供了 `ObWrapperAllocator`，是个简单的委托封装：

```cpp
class ObWrapperAllocator : public ObIAllocator {
  ObIAllocator *alloc_;
  // 所有方法委托给 alloc_
  virtual void *alloc(const int64_t sz) {
    return NULL == alloc_ ? NULL : alloc_->alloc(sz);
  }
};
```

而 `ObWrapperAllocatorWithAttr`（第 173 行）则在委托基础上附加了 `ObMemAttr` 成员，使得 `alloc(size)` 自动携带预设属性：

```cpp
class ObWrapperAllocatorWithAttr : public ObWrapperAllocator {
  ObMemAttr mem_attr_;
  virtual void *alloc(const int64_t sz) {
    return ObWrapperAllocator::alloc(sz, mem_attr_);
  }
};
```

### 1.3 ObAllocAlign — 对齐分配

[`ob_allocator.h` 第 24 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_allocator.h:24)的 `ObAllocAlign` 提供了对齐分配的支持：

```cpp
struct Header {
  static const uint32_t MAGIC_CODE = 0XAA22CCE1;
  uint32_t magic_code_;
  uint32_t offset_;
};
```

它在分配的内存头部嵌入 `Header`（8 字节），记录原始指针偏移和魔法字用于校验。对齐请求被向上取整到 16 字节边界。释放时通过 magic code 校验完整性后再还原原始指针。

---

## 2. ObAllocator V2 — 新版通用分配器

### 2.1 链表跟踪设计

[`ob_allocator_v2.h` 第 37 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_allocator_v2.h:37)定义了 V2 的 `ObAllocator`：

```cpp
class ObAllocator : public ObIAllocator {
  struct AllocNode {
    AllocNode *prev_;
    AllocNode *next_;
    char data_[0];        // 零长度数组，紧跟在节点后的数据
  };

  __MemoryContext__ *mem_context_;
  ObTenantCtxAllocatorGuard ta_;  // 租户上下文保护
  ObMemAttr attr_;                // 内存属性
  int64_t hold_;                  // 持有的总字节数
  AllocNode head_;                // 链表头（哨兵节点）
  ObjectSet *os_;
};
```

核心思想：**通过双向链表追踪每次分配**。每个分配块前都嵌入 `AllocNode`，所有 `AllocNode` 链接到 `head_` 哨兵节点。`hold_` 累计当前分配总量，`total()` 和 `used()` 都返回 `hold_`——因为这种分配器每次分配都会记录，所以 total == used。

`push/remove/popall` 三个受保护方法操作链表：

| 方法 | 行号 | 行为 |
|------|------|------|
| `push(node, size)` | 第 57 行 | 插入到哨兵头，`hold_ += size` |
| `remove(node, size)` | 第 65 行 | 从链表移除，`hold_ -= size` |
| `popall()` | 第 71 行 | 弹出整个链表（O(1)），`hold_ = 0` |

`popall()` 返回整个链表，由调用方统一释放，这是**批量释放**的基础。

### 2.2 ObParallelAllocator — 并发版本

[`ob_allocator_v2.h` 第 93 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_allocator_v2.h:93)提供了线程安全的变体：

```cpp
class ObParallelAllocator : public ObAllocator {
  ObSimpleLock lock_;
  void push(AllocNode *node, const int64_t size) override;   // 加锁
  void remove(AllocNode *node, const int64_t size) override; // 加锁
  AllocNode *popall() override;                              // 加锁
};
```

`ObSimpleLock` 在非 `ENABLE_SANITY` 模式下使用 `ObLatch`，在调试模式下使用 `ob_latch_v2`。

---

## 3. ObMemAttr — 内存属性体系

### 3.1 ObMemAttr 结构

[`alloc_struct.h` 第 132 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/alloc/alloc_struct.h:132)定义了内存属性的核心结构：

```cpp
struct ObMemAttr {
  uint64_t tenant_id_;    // 租户 ID
  ObLabel label_;         // 模块标签（16 字节标识符）
  uint64_t ctx_id_;       // 上下文 ID
  int32_t numa_id_;       // NUMA 节点
  ObAllocPrio prio_;      // 分配优先级

  union {
    char padding__[4];
    struct {
      uint8_t use_500_ : 1;          // 使用 500 分配路径
      uint8_t expect_500_ : 1;       // 期望 500 路径
      uint8_t ignore_version_ : 1;   // 忽略版本管理
      uint8_t enable_malloc_hang_ : 1; // 启用分配挂起
      uint16_t extra_size_;
    };
  };
};
```

每个字段的意义：

| 字段 | 类型 | 用途 |
|------|------|------|
| `tenant_id_` | uint64_t | 标识属于哪个租户，默认 `OB_SERVER_TENANT_ID` |
| `label_` | ObLabel | 16 字节模块名，帮助定位内存泄漏 |
| `ctx_id_` | uint64_t | 功能上下文 ID（如 MEMSTORE、EXECUTE 等） |
| `numa_id_` | int32_t | NUMA 亲和性绑定 |
| `prio_` | ObAllocPrio | `OB_NORMAL_ALLOC` / `OB_HIGH_ALLOC` |
| `use_500_` | 1 bit | 当分配失败时是否使用 500 保留内存 |
| `expect_500_` | 1 bit | 是否预期使用 500 路径 |

### 3.2 上下文 ID 定义

[`ob_mod_define.h`](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_mod_define.h) 通过 X-macro 定义了完整的上下文 ID 枚举：

```cpp
CTX_ITEM_DEF(DEFAULT_CTX_ID)     // 默认
CTX_ITEM_DEF(MEMSTORE_CTX_ID)    // MemStore
CTX_ITEM_DEF(EXECUTE_CTX_ID)     // SQL 执行
CTX_ITEM_DEF(TRANS_CTX_MGR_ID)   // 事务
CTX_ITEM_DEF(PLAN_CACHE_CTX_ID)  // Plan Cache
CTX_ITEM_DEF(WORK_AREA)           // SQL 工作区
CTX_ITEM_DEF(LIBEASY)             // 网络库
CTX_ITEM_DEF(LOGGER_CTX_ID)      // 日志
CTX_ITEM_DEF(KVSTORE_CACHE_ID)    // KV 缓存
CTX_ITEM_DEF(META_OBJ_CTX_ID)    // 元信息对象
...

#define CTX_ITEM_DEF(name) name,
#include "lib/allocator/ob_mod_define.h"
#undef CTX_ITEM_DEF
// → enum { DEFAULT_CTX_ID, MEMSTORE_CTX_ID, ..., MAX_CTX_ID };
```

这种 X-macro 模式确保枚举定义和字符串表完全同步。

### 3.3 ObCtxAttr — 上下文属性

[`ob_ctx_define.h` 第 23 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_ctx_define.h:23)定义了每个上下文的属性：

```cpp
struct ObCtxAttr {
  bool enable_dirty_list_ = false;      // 启用脏列表
  bool enable_no_log_ = false;          // 不记录日志
  int parallel_ = DEFAULT_CTX_PARALLEL; // 并发度
  bool disable_sync_wash_ = false;      // 禁止同步洗刷
};
```

`ObCtxAttrCenter`（第 33 行）是一个单例（`instance()`），初始化时通过宏为每个上下文设置默认值：

| 上下文 | parallel_ | enable_dirty_list_ | enable_no_log_ |
|--------|-----------|-------------------|----------------|
| DEFAULT_CTX_ID | 32 | false | false |
| LIBEASY | 32 | **true** | false |
| PLAN_CACHE_CTX_ID | 4 | false | false |
| LOGGER_CTX_ID | 4 | **true** | **true** |
| MERGE_RESERVE_CTX_ID | 32 | false | false, **disable_sync_wash_=true** |

### 3.4 模块标签体系

[`ob_mod_define.h`](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_mod_define.h) 通过 `LABEL_ITEM_DEF` 定义了 453+ 个模块标签，每个标签对应一个 16 字节的缩写名：

```cpp
LABEL_ITEM_DEF(OB_MOD_DO_NOT_USE_ME, ModDoNotUseMe)
LABEL_ITEM_DEF(OB_PAGE_ARENA, PageArena)
LABEL_ITEM_DEF(OB_SSTABLE, Sstable)
LABEL_ITEM_DEF(OB_SQL_EXECUTOR, SqlExecutor)
// ...453 个标签
```

`ObLabelItem`（第 204 行）跟踪每个标签的统计：

```cpp
struct ObLabelItem {
  int64_t hold_;        // 当前持有
  int64_t used_;        // 已使用
  int64_t count_;       // 活跃对象数
  int64_t alloc_count_; // 累计分配次数
  int64_t free_count_;  // 累计释放次数
};
```

这些统计通过 `update()` 方法在每次 alloc/free 时更新，从而支持精确到模块级别的内存使用分析。

---

## 4. ObBlockAllocMgr — 块分配管理器

[`ob_block_alloc_mgr.h` 第 23 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_block_alloc_mgr.h:23)提供了按块粒度管理内存分配的组件：

```cpp
class ObBlockAllocMgr {
  int64_t limit_;   // 上限（原子访问）
  int64_t hold_;    // 当前持有（原子访问）

  void* alloc_block(int64_t size, ObMemAttr &attr);
  void free_block(void *ptr, int64_t size);
  bool can_alloc_block(int64_t size) const;
};
```

### 核心逻辑：先垫后查

`alloc_block` 使用了"先原子增加 `hold_`，超限则回滚"的策略：

```cpp
void* alloc_block(int64_t size, ObMemAttr &attr) {
  int64_t used_after_alloc = ATOMIC_AAF(&hold_, size);
  if (used_after_alloc > limit_) {
    ATOMIC_AAF(&hold_, -size);    // 超限，回滚
    // 日志警告
  } else if (NULL == (ret = (void*)ob_malloc(size, attr))) {
    ATOMIC_AAF(&hold_, -size);    // 分配失败，回滚
  }
  return ret;
}
```

这种设计避免了在分配路径上的两次原子操作（先检查再分配需要额外的锁保护），以极小的"超分配回滚"代价换取了分配路径的高效。`limit_` 和 `hold_` 都使用 `ATOMIC_STORE/LOAD/FAA` 保证线程安全。

`default_blk_alloc`（第 24 行）是全局唯一的块分配管理器实例，默认 `limit_ = INT64_MAX`（无限制）。

---

## 5. PageArena 与 ObArenaAllocator — 区域分配器

### 5.1 PageArena 设计

[`page_arena.h` 第 137 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/page_arena.h:137)定义了 `PageArena` —— 这是 OceanBase 最常用的分配器之一，按"页"管理内存：

```cpp
class PageArena {
  Page *cur_page_;    // 当前活跃页
  Page *header_;      // 链表头
  Page *tailer_;      // 链表尾
  int64_t page_size_; // 页大小（默认 ~8KB）
  int64_t pages_;     // 分配的页数
  int64_t used_;      // 用户已使用的字节数
  int64_t total_;     // 总持有字节数
  PageAllocatorT page_allocator_;  // 底层页分配器
};
```

### 5.2 Page 结构

[`page_arena.h` 第 142 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/page_arena.h:142)：

```cpp
struct Page {
  static constexpr uint64_t MAGIC = 0x1234abcddbca4321;
  uint64_t magic_;            // 魔法字，检测内存越界
  Page *next_page_;           // 链表指针
  char *alloc_end_;           // 当前分配位置
  const char *page_end_;      // 页尾
  char buf_[0];               // 零长度数组，页数据的起始
};
```

默认页大小：

```cpp
static const int64_t DEFAULT_PAGE_SIZE     = OB_MALLOC_NORMAL_BLOCK_SIZE - sizeof(Page); // ~8KB
static const int64_t DEFAULT_BIG_PAGE_SIZE = OB_MALLOC_BIG_BLOCK_SIZE;                    // ~2MB
```

### 5.3 分配路径

`_alloc()`（第 536 行）根据请求大小走三条路径：

```
_alloc(sz)
    │
    ├── sz + sizeof(Page) > page_size_
    │    └── alloc_big(sz)       ← 大对象：独立分配一个 2MB 大页
    │
    ├── cur_page_->remain() >= sz
    │    └── cur_page_->alloc()  ← 快速路径：直接 bump allocation
    │
    ├── is_normal_overflow(sz)   ← 超过当前页余量但不超过页大小
    │    └── extend_page() + alloc()
    │
    └── lookup_next_page(sz)    ← 检查下一个空闲页
         └── cur_page_->alloc()
```

关键优化点：

1. **Bump allocation**：当前页有空间时直接增加 `alloc_end_` 指针，O(1) 无锁
2. **页面复用**：`extend_page()` 优先复用已存在的页面（`reuse()`），只有无空闲页时才调用 `alloc_new_page()`
3. **大对象分离**：大于页大小的请求走 `alloc_big()`，分配独立大页并插入链表头部
4. **批量释放**：`reset()` / `free_large_pages()` 释放所有大页，普通页仅 `reuse()`（清空当前分配指针）

### 5.4 ObArenaAllocator

[`page_arena.h` 第 1035 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/page_arena.h:1035)将 `PageArena` 包装为 `ObIAllocator` 兼容的分配器：

```cpp
class ObArenaAllocator : public ObIAllocator {
  PageArena arena_;  // 内部的 PageArena

  virtual void *alloc(const int64_t sz) override { return arena_.alloc(sz); }
  virtual void *alloc(const int64_t sz, const ObMemAttr &attr) override {
    set_attr(attr);   // 先设属性再分配
    return arena_.alloc(sz);
  }
  virtual void free(void *) override {}  // NO-OP! Arena 不释放单个对象
  virtual void clear() { arena_.free(); }
  virtual void reset() { arena_.reuse(); }
};
```

**关键设计决策**：`free()` 是空操作！arena 分配器的核心哲学是"批量释放、永不回收单个对象"。释放整个 arena 通过 `reset()`（保留已分配页面，仅重置分配指针）或 `clear()`（释放所有页面）完成。

此外还有线程安全版本 `ObSafeArenaAllocator`（第 1090 行），在 `alloc/free` 路径上加锁：

```cpp
class ObSafeArenaAllocator : public ObIAllocator {
  PageArena arena_;
  ObSpinLock lock_;
  virtual void *alloc(const int64_t sz) override {
    ObSpinLockGuard guard(lock_);
    return arena_.alloc(sz);
  }
};
```

以及对齐版本 `ObAlignedArenaAllocator`（第 1137 行）。

---

## 6. ObCachedAllocator — 缓存分配器

[`ob_cached_allocator.h` 第 25 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_cached_allocator.h:25)提供了对象级缓存分配器：

```cpp
template <typename T>
class ObCachedAllocator {
  ObSpinLock lock_;                  // 自旋锁保护
  ObPool<> pool_;                    // 对象池（alloc/free raw memory）
  ObArray<T *> cached_objs_;         // 缓存的空闲对象
  int32_t allocated_count_;          // 活跃分配计数
  int32_t cached_count_;             // 缓存中对象计数

  T *alloc();
  void free(T *obj, bool can_reuse = true);
};
```

### 分配路径

```
alloc()
    │
    ├── cached_objs_ 非空
    │    └── pop back → 复用已有对象
    │
    └── cached_objs_ 空
         └── pool_.alloc() → new(p) T() → 构造新对象
```

### 释放路径

```
free(obj, can_reuse)
    │
    ├── can_reuse == true && push_back 成功
    │    └── obj->reset() + 加入缓存
    │
    └── can_reuse == false 或 数组满
         └── obj->~T() + pool_.free(obj)
```

这种设计针对频繁创建/销毁的同一类型小对象优化。例如 SQL 表达式节点、Schema 对象等。

---

## 7. 特殊分配器

### 7.1 ObConcurrentFIFOAllocator（第 16 行）

[`ob_concurrent_fifo_allocator.h`](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_concurrent_fifo_allocator.h) 基于无锁 FIFO 队列实现：

```cpp
class ObConcurrentFIFOAllocator : public ObIAllocator {
  ObLfFIFOAllocator inner_allocator_;  // Lock-free FIFO
  // 支持：init(total_limit, hold_limit, page_size)
  //       set_nway(nway) 设置并发度
};
```

适用于高并发场景，如网络层、RPC 缓冲区分配。

### 7.2 ObDelayFreeAllocator（第 37 行）

[`ob_delay_free_allocator.h`](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_delay_free_allocator.h) 实现延迟释放机制，目的：**减少内存抖动**：

```
work_list (working blocks)     free_list (recycled blocks)
    │                                │
    │ allocate from                  │ blocks moved from work_list
    │ current block                  │ when empty (all obj freed)
    │                                ↓
    └────────────────────→  after expire_duration
                              if cached > MAX_CACHE_MEMORY_SIZE
                              → 真正释放给 OS
```

关键参数：
- `MEM_BLOCK_SIZE = OB_MALLOC_BIG_BLOCK_SIZE`（2MB）
- `MAX_CACHE_MEMORY_SIZE = MEM_BLOCK_SIZE * 32`（最大缓存 64MB）
- `expire_duration_us`：回收块在被完全释放前的最短保留时间

### 7.3 ObASanAllocator

[`ob_asan_allocator.h`](vscode://file/~/code/oceanbase/deps/oblib/src/lib/allocator/ob_asan_allocator.h) 包装 AddressSanitizer 的 `__asan_*` 接口，在调试模式下捕获内存越界和 use-after-free：

- 分配时在对象前后插入 `redzone`（不可访问区域）
- 释放后将内存标记为 `poisoned`
- 仅在 `ENABLE_SANITY` 编译时生效

---

## 8. 分配器对比

| 分配器 | 文件 | 类型 | 线程安全 | 释放方式 | 适用场景 |
|--------|------|------|----------|----------|----------|
| `ObIAllocator` | ob_allocator.h:63 | 抽象接口 | — | — | 多态分配器使用 |
| `ObWrapperAllocator` | ob_allocator.h:123 | 委托封装 | 取决于内部 | 委托 | 适配模式/临时切换 |
| `ObAllocator` V2 | ob_allocator_v2.h:37 | 链表跟踪 | **不**安全 | 批量通过 popall | 单线程短期任务 |
| `ObParallelAllocator` | ob_allocator_v2.h:93 | 链表跟踪+锁 | ✅安全 | 批量通过 popall | 多线程共享分配 |
| `ObArenaAllocator` | page_arena.h:1035 | Arena | **不**安全 | 整区 reset/clear | 高性能临时分配 |
| `ObSafeArenaAllocator` | page_arena.h:1090 | Arena+锁 | ✅安全 | 整区 reset/clear | 线程安全 Arena |
| `ObCachedAllocator<T>` | ob_cached_allocator.h:25 | 对象缓存 | ✅安全 | 缓存或直接释放 | 频繁相同类型对象 |
| `ObBlockAllocMgr` | ob_block_alloc_mgr.h:23 | 块管理 | ✅安全(原子) | 按块释放 | 租户级内存限流 |
| `ObConcurrentFIFOAllocator` | ob_concurrent_fifo_allocator.h | 无锁 FIFO | ✅安全(LF) | FIFO | 高性能并发场景 |
| `ObDelayFreeAllocator` | ob_delay_free_allocator.h:37 | 延迟释放 | 可配 | 延迟批量 | 减少内存碎片 |
| `ObASanAllocator` | ob_asan_allocator.h | ASAN 包装 | 取决于内部 | 正常 | 调试/检测 |

---

## 9. 全局内存管理与统计

### 9.1 ObMallocAllocator — 全局分配器

[`ob_malloc_allocator.h`](vscode://file/~/code/oceanbase/deps/oblib/src/lib/alloc/ob_malloc_allocator.h) 是 OceanBase 内存管理的总控中心：

```cpp
class ObMallocAllocator : public common::ObIAllocator {
  ObTenantCtxAllocatorV2 *allocators_[PRESERVED_TENANT_COUNT]; // 10000 个槽位
  int64_t reserved_;   // 全局保留内存
  int64_t urgent_;     // 紧急分配额度

  ObTenantCtxAllocatorGuard get_tenant_ctx_allocator(uint64_t tenant_id,
                                                     uint64_t ctx_id, int numaid);
  int set_tenant_limit(uint64_t tenant_id, int64_t bytes);
  int64_t get_tenant_limit(uint64_t tenant_id);
  int64_t get_tenant_hold(uint64_t tenant_id);
};
```

全局单例通过 `get_instance()` 获取，每个租户有独立的 `ObTenantCtxAllocatorV2` 实例，按 `tenant_id` 索引，通过 `BucketLock` （32 个分桶）实现细粒度并发控制。

### 9.2 租户内存限流

[`src/share/ob_tenant_mgr.h` 第 51 行](vscode://file/~/code/oceanbase/src/share/ob_tenant_mgr.h:51)提供：

```cpp
int set_tenant_mem_limit(const uint64_t tenant_id, int64_t mem_limit);
virtual int get_tenant_mem_limit(const uint64_t tenant_id, int64_t &mem_limit);
```

内存限流的层次：

```
全局配置 → 租户限流 → 上下文限流 → 分配器限流
    │          │           │            │
  max_memory  mem_limit  ctx_limit   ObBlockAllocMgr::limit_
```

当一个分配请求到来时：
1. `ObMallocAllocator::alloc()` 查找对应 `tenant_id` 的 `ObTenantCtxAllocatorV2`
2. 检查租户级别的 `limit_` 和当前 `hold_`
3. 如果超出，触发 `sync_wash` 回收（如缓存淘汰）
4. 如果回收仍不足，返回 `OB_ALLOCATE_MEMORY_FAILED`

### 9.3 内存统计

`ObMallocAllocator` 提供丰富的统计接口：

```cpp
int64_t get_tenant_hold(tenant_id);        // 租户总持有
int64_t get_tenant_cache_hold(tenant_id);  // 租户缓存持有
int64_t get_tenant_ctx_hold(tid, ctx_id);  // 上下文级别统计
get_tenant_label_usage(tid, label, item);  // 单个标签统计
```

每层都可以精确查询，这对于排查内存泄漏和优化资源分配至关重要。

---

## 10. 设计决策分析

### 10.1 V1 到 V2 的演进

| 维度 | V1（ObIAllocator 直接继承） | V2（ObAllocator + __MemoryContext__） |
|------|---------------------------|--------------------------------------|
| 设计目标 | 简单、轻量 | 更多上下文感知 & 细化统计 |
| 内存归属 | 调用方需显式传递 attr | 通过 `__MemoryContext__` 跟踪 |
| 生命周期 | 独立管理 | 通过 `ObTenantCtxAllocatorGuard` 引用计数 |
| 跟踪粒度 | `ObAllocAlign::Header` 中 magic + offset | 双向链表 `AllocNode` |
| 批量释放 | 无原生支持 | `popall()` 支持 O(1) 批量 |

V2 的核心改进是引入了**内存上下文**的概念——一个 `ObAllocator` 绑定到特定的 `__MemoryContext__`，后者又关联到特定的租户+上下文。这使得"谁分配的内存"可以在分配路径上全程追踪。

### 10.2 租户隔离策略

OceanBase 通过两层机制实现内存隔离：

1. **分配层面**：`ObMallocAllocator` 按 `tenant_id` 分配独立的 `ObTenantCtxAllocatorV2`，分配时检查租户配额
2. **统计层面**：每个 `ObMemAttr` 携带 `tenant_id_`，通过 `ObLabelItem` 精确统计到标签级别

这种"分配隔离 + 事后审计"的组合既保证了硬性限流，又提供了硬件故障排查能力。

### 10.3 内存碎片控制

OceanBase 主要从三个方向控制碎片：

| 方向 | 机制 |
|------|------|
| Arena 分配 | `PageArena` 内的 bump pointer 天然无内部碎片 |
| 大对象分离 | 超过页大小的对象走独立 `alloc_big()`，不与小对象混用 |
| 延迟释放 | `ObDelayFreeAllocator` 避免频繁 alloc/free 导致的碎片积累 |
| 页面复用 | `extend_page()` 优先复用已有页面，避免大量小页申请 |

### 10.4 分配器选择策略

模块开发者根据使用场景选择合适的分配器：

| 场景 | 推荐分配器 | 理由 |
|------|-----------|------|
| SQL 执行中的临时计算 | `ObArenaAllocator` | 大量临时分配 + 一次性释放 |
| Schema 节点 | `ObCachedAllocator<SchemaNode>` | 大量相同对象 + 频繁创建/删除 |
| 线程安全的共享分配 | `ObSafeArenaAllocator` / `ObParallelAllocator` | 需要并发访问 |
| 大内存块（>2MB） | ob_malloc / 直接 ObBlockAllocMgr | 避免经过多级缓存 |
| 高性能批量计算 | `PageArena` (直接) | 零损耗的 bump allocation |

### 10.5 内存超卖处理

OceanBase 支持内存超卖：当分配失败时：

1. 尝试 `use_500_` 路径 — 从预留的 500 内存中分配
2. 触发 `sync_wash` — 异步/同步淘汰缓存（如 KVStore Cache）
3. 如果仍然不足 — 返回 `OB_ALLOCATE_MEMORY_FAILED`，由上层模块决策

`ObBlockAllocMgr`（第 34 行）中的 `can_alloc_block(size)` 可以在分配前预测是否超限：

```cpp
bool can_alloc_block(int64_t size) const {
  return ((limit_ - hold_) > size);
}
```

---

## 11. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `ObIAllocator` | `deps/oblib/src/lib/allocator/ob_allocator.h` | 63 |
| `ObAllocAlign` | `deps/oblib/src/lib/allocator/ob_allocator.h` | 24 |
| `ObWrapperAllocator` | `deps/oblib/src/lib/allocator/ob_allocator.h` | 123 |
| `ObWrapperAllocatorWithAttr` | `deps/oblib/src/lib/allocator/ob_allocator.h` | 173 |
| `ObAllocator` (V2) | `deps/oblib/src/lib/allocator/ob_allocator_v2.h` | 37 |
| `ObAllocator::push` | `deps/oblib/src/lib/allocator/ob_allocator_v2.h` | 57 |
| `ObAllocator::remove` | `deps/oblib/src/lib/allocator/ob_allocator_v2.h` | 65 |
| `ObAllocator::popall` | `deps/oblib/src/lib/allocator/ob_allocator_v2.h` | 71 |
| `ObParallelAllocator` | `deps/oblib/src/lib/allocator/ob_allocator_v2.h` | 93 |
| `ObMemAttr` | `deps/oblib/src/lib/alloc/alloc_struct.h` | 132 |
| `ObCtxAttr` | `deps/oblib/src/lib/allocator/ob_ctx_define.h` | 23 |
| `ObCtxAttrCenter` | `deps/oblib/src/lib/allocator/ob_ctx_define.h` | 33 |
| `ObLabelItem` | `deps/oblib/src/lib/allocator/ob_mod_define.h` | 204 |
| `ObCtxIds` | `deps/oblib/src/lib/allocator/ob_mod_define.h` | 263 |
| `ObBlockAllocMgr` | `deps/oblib/src/lib/allocator/ob_block_alloc_mgr.h` | 26 |
| `ObBlockAllocMgr::alloc_block` | `deps/oblib/src/lib/allocator/ob_block_alloc_mgr.h` | 34 |
| `ObCachedAllocator` | `deps/oblib/src/lib/allocator/ob_cached_allocator.h` | 25 |
| `PageArena` | `deps/oblib/src/lib/allocator/page_arena.h` | 137 |
| `PageArena::_alloc` | `deps/oblib/src/lib/allocator/page_arena.h` | 536 |
| `PageArena::alloc_big` | `deps/oblib/src/lib/allocator/page_arena.h` | 405 |
| `PageArena::extend_page` | `deps/oblib/src/lib/allocator/page_arena.h` | 345 |
| `ObArenaAllocator` | `deps/oblib/src/lib/allocator/page_arena.h` | 1035 |
| `ObSafeArenaAllocator` | `deps/oblib/src/lib/allocator/page_arena.h` | 1090 |
| `ObAlignedArenaAllocator` | `deps/oblib/src/lib/allocator/page_arena.h` | 1137 |
| `ObConcurrentFIFOAllocator` | `deps/oblib/src/lib/allocator/ob_concurrent_fifo_allocator.h` | 16 |
| `ObDelayFreeAllocator` | `deps/oblib/src/lib/allocator/ob_delay_free_allocator.h` | 37 |
| `ObMallocAllocator` | `deps/oblib/src/lib/alloc/ob_malloc_allocator.h` | 69 |
| `ObMallocAllocator::set_tenant_limit` | `deps/oblib/src/lib/alloc/ob_malloc_allocator.h` | 131 |
| `set_tenant_mem_limit` | `src/share/ob_tenant_mgr.h` | 51 |

---

## 12. 总结

OceanBase 的内存管理是一个多层、可插拔的分配器体系：

1. **接口统一**：`ObIAllocator` 定义了无属性/带属性两种分配路径
2. **按需选择**：从 Arena 到 FIFO 到缓存分配器，覆盖几乎所有使用场景
3. **强隔离性**：通过 `ObMemAttr`（tenant_id + label + ctx_id）实现多租户细粒度隔离
4. **可控限流**：`ObBlockAllocMgr` 到 `ObMallocAllocator` 的多级限流保证系统稳定性
5. **高性能**：Arena 的 bump allocation + 页面复用 + 大对象分离，将分配开销降到最低

理解这套内存管理体系，是深入理解 OceanBase 整体架构的关键前提——几乎所有的子系统（SQL 引擎、存储引擎、事务引擎、网络层）都建立在它之上。
