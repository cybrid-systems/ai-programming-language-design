# 20. InnoDB 内存堆（Memory Heap）— 源码深度分析

> 本文分析 InnoDB 内存堆（Memory Heap）的完整实现，包括块链结构、分配释放路径、双模式（动态堆 vs 缓冲池堆）、扩容策略、调试机制和最佳实践。核心源文件：`mem0mem.h`、`mem0mem.ic`。

---

## 0. 概述

InnoDB 没有直接使用 `malloc`/`free` 管理所有内部内存，而是实现了一套**内存堆（Memory Heap）**系统。每个内存堆由一组链表连接的 `mem_block_t` 组成，提供高效的"块内分配 + 块级回收"机制。

### 为什么需要 Memory Heap？

```
为什么不直接 malloc/free？
─────────────────────────────────────────────
问题 1: 大量小对象分配
  dict_table_t 创建时需要分配 col、field、index 等数十个小对象
  每个对象单独 malloc → 大量元数据开销 + 碎片化

问题 2: 生命周期管理
  表打开→关闭→打开→同一个 dict_table_t 对象反复创建释放
  mem_heap_empty 可以快速重用堆，避免系统调用

问题 3: 调试
  InnoDB 有严格的调试模式（UNIV_DEBUG）
  红区检测可以在内存越界时立即发现
  malloc/free 没有标准化的边界检查

问题 4: 缓冲池集成
  大块分配走 Buffer Pool 而不是 malloc
  减少对 OS 分配器的压力
```

### 内存堆的基本概念

```
mem_heap_t (即 mem_block_info_t *，指向首块)
  ├── 块 0（首块，包含链表基节点）
  │   ├── header
  │   ├── [FREE SPACE] ◄── free 指针
  │   └── 已分配区域
  ├── 块 1（后续块，倍增大小）
  │   ├── header
  │   ├── [FREE SPACE]
  │   └── 已分配区域
  └── 块 N（最后一个块，free 向下增长）

分配策略:
  1. 检查最后一个块的剩余空间
  2. 足够 → 移动 free 指针，O(1) 返回
  3. 不够 → 添加新块（大小翻倍）
```

---

## 1. 核心数据结构

### 1.1 内存块 — mem_block_info_t

```cpp
// mem0mem.h:302
struct mem_block_info_t {
  /** 魔数：V = valid (0x445566778899AABB)
            F = freed (0xBBAA998877665544) */
  uint64_t magic_n;

  /** 链表节点（连接同一 heap 中的所有块） */
  UT_LIST_NODE_T(mem_block_t) list;

  /** 基节点：仅在首块中有效 */
  /** 其他块的该字段未定义（不初始化） */
  UT_LIST_BASE_NODE_T_EXTERN(mem_block_t, list) base;

  /** 该块的物理总长度（字节） */
  ulint len;

  /** 所有块的总长度，仅在首块中有效 */
  ulint total_size;

  /** 堆类型标志位 */
  ulint type;

  /** 下一个可用分配位置的偏移量（从块起始计算） */
  ulint free;

  /** 创建该块时 free 的初始偏移量 */
  /** 用于 mem_heap_empty 重置时回退到初始位置 */
  ulint start;

  /** 预分配块指针（仅 MEM_HEAP_BTR_SEARCH 类型） */
  std::atomic<buf_block_t *> *free_block_ptr;

  /** Buffer Pool 块句柄（如果 MEM_HEAP_BUFFER） */
  buf_block_t *buf_block;
};
```

**魔数的调试价值**：

```cpp
#define MEM_BLOCK_MAGIC_N 0x445566778899AABB  /* 正常块 */
#define MEM_FREED_BLOCK_MAGIC_N 0xBBAA998877665544  /* 已释放块 */
```

在 `mem_heap_free()` 的末尾，魔数被改写为 `MEM_FREED_BLOCK_MAGIC_N`。任何后续访问该堆的代码都会在 `mem_block_validate()` 中触发断言失败，立即发现 use-after-free。

**内存布局（一个块）**：

```
偏移量 0:   mem_block_info_t 头部
偏移量 56:  [前红区] 16 字节 (调试模式下)
偏移量 72:  用户数据区域
            ...
偏移量 free: [后红区] 16 字节 (调试模式下)
偏移量 len:  块结束
```

### 1.2 关键常量

```cpp
// mem0mem.h
constexpr uint64_t MEM_BLOCK_MAGIC_N = 0x445566778899AABB;
constexpr uint64_t MEM_FREED_BLOCK_MAGIC_N = 0xBBAA998877665544;

/* 首块默认大小 */
constexpr uint32_t MEM_BLOCK_START_SIZE = 64;

/* 后续块的标准大小 */
constexpr uint32_t MEM_BLOCK_STANDARD_SIZE = 8000;

/* 调试红区大小（前后各 16 字节） */
constexpr int MEM_NO_MANS_LAND = 16;

/* 红区填充字节 */
const byte MEM_NO_MANS_LAND_BEFORE_BYTE = 0xCE;
const byte MEM_NO_MANS_LAND_AFTER_BYTE = 0xDF;

/* 对齐要求 */
constexpr int UNIV_MEM_ALIGNMENT = 8;
```

### 1.3 堆类型标志

```cpp
// mem0mem.h
#define MEM_HEAP_DYNAMIC     0  /* 从 C heap (malloc) 分配 */
#define MEM_HEAP_BUFFER      1  /* 从 Buffer Pool 分配 */
#define MEM_HEAP_BTR_SEARCH  2  /* 额外标志：允许分配失败时返回 NULL */

/* 常用组合 */
#define MEM_HEAP_FOR_BTR_SEARCH  (MEM_HEAP_BTR_SEARCH | MEM_HEAP_BUFFER)
#define MEM_HEAP_FOR_PAGE_HASH   MEM_HEAP_DYNAMIC
#define MEM_HEAP_FOR_RECV_SYS    MEM_HEAP_BUFFER
```

`MEM_HEAP_BTR_SEARCH` 标志的特殊性：AHI（自适应哈希索引）的构建路径可能在进行中，此时如果 Buffer Pool 内存不足，应该返回 NULL 而不是阻塞等待。这个标志允许 `mem_heap_add_block` 在分配失败时返回 NULL，上层调用者（AHI 构建函数）检测后跳过构建。

---

## 2. 堆创建路径

### 2.1 mem_heap_create()

```cpp
// mem0mem.ic:423
static inline mem_heap_t *mem_heap_create(
    ulint size,
    IF_DEBUG(const char *file_name, ulint line, )
    ulint type) {

  mem_block_t *block;

  /* 步骤 1：确定首块大小 */
  if (size == 0) {
    size = MEM_BLOCK_START_SIZE;  /* 默认 64 字节 */
  }

  /* 步骤 2：创建首块 */
  block = mem_heap_create_block(
      nullptr,  /* nullptr = 这是首块 */
      size,
      IF_DEBUG(file_name, line, )
      type);

  /* 步骤 3：设置类型 */
  mem_block_set_type(block, type);

  return block;  /* 返回首块地址作为 heap 句柄 */
}
```

### 2.2 mem_heap_create_block() — 底层块分配

```cpp
// mem0mem.ic:44
mem_block_t *mem_heap_create_block(
    mem_heap_t *heap,  /* nullptr = 首块，非 nullptr = 追加 */
    ulint n,
    IF_DEBUG(const char *file_name, ulint line, )
    ulint type) {

  mem_block_t *block;
  ulint block_size;

  /* ──── 步骤 1：计算块大小 ──── */
  block_size = MEM_BLOCK_HEADER_SIZE + MEM_SPACE_NEEDED(n);

  /* 首块最小大小：MEM_BLOCK_STANDARD_SIZE (8000) */
  if (block_size < MEM_BLOCK_STANDARD_SIZE && heap == nullptr) {
    block_size = MEM_BLOCK_STANDARD_SIZE;
  }

  /* ──── 步骤 2：按类型分配底层内存 ──── */

  if (type & MEM_HEAP_BUFFER) {
    /* 从 Buffer Pool 分配（大块走 BP 避免 malloc 碎片） */
    buf_block_t *buf_block = buf_block_alloc(nullptr);

    if (buf_block == nullptr) {
      /* 缓冲池分配失败 */
      if (type & MEM_HEAP_BTR_SEARCH) {
        return nullptr;  /* AHI 构建允许失败 */
      }
      /* 其他类型不可能失败 */
      ut_error;
    }

    block = (mem_block_t *)buf_block->frame;   /* 使用 BP 页帧 */
    block->buf_block = buf_block;               /* 保存 BP 块句柄 */
  } else {
    /* 从 C heap (malloc) 分配 */
    block = (mem_block_t *)ut::malloc_withkey(
        UT_NEW_THIS_FILE_PSI_KEY, block_size);
    block->buf_block = nullptr;
  }

  /* ──── 步骤 3：初始化块元数据 ──── */
  block->magic_n = MEM_BLOCK_MAGIC_N;
  block->len = block_size;
  block->free = MEM_BLOCK_HEADER_SIZE;    /* free 指向头部之后 */
  block->start = MEM_BLOCK_HEADER_SIZE;   /* 初始位置 */
  block->type = type;

  /* ──── 步骤 4：链接到堆 ──── */
  if (heap == nullptr) {
    /* 这是首块 → 初始化基节点并加入自身 */
    UT_LIST_INIT(block->base, &mem_block_t::list);
    UT_LIST_ADD_LAST(block->base, block);
    block->total_size = block_size;
  } else {
    /* 追加到已有堆 */
    UT_LIST_ADD_LAST(heap->base, block);
    heap->base.total_size += block_size;
  }

  return block;
}
```

**Buffer Pool 分配 vs malloc 分配的选择**：

```
分配大小 | 分配源         | 理由
─────────|────────────────|─────────────────────
< 8000   | malloc         | 快，无需 BP 管理
≥ 8000   | BP (16KB 页)  | 减少 BP 碎片，统一页面管理
```

`mem_heap_create_block()` 调用 `buf_block_alloc()` 从 Buffer Pool 分配一个完整的 16KB 块，然后只使用其中的一部分作为 `mem_block_t`。这意味着 BP 页面有 8KB 以上是"浪费"的——但这是有意为之，因为 BP 管理的是完整页，没法从中间切一部分出来。

---

## 3. 分配路径 — mem_heap_alloc()

```cpp
// mem0mem.ic:143
static inline void *mem_heap_alloc(mem_heap_t *heap, ulint n) {

  mem_block_t *block;
  byte *buf;

  /* 验证魔数（调试模式）*/
  ut_d(mem_block_validate(heap));

  /* ──── 步骤 1：获取最后一个块 ──── */
  block = UT_LIST_GET_LAST(heap->base);

  /* ──── 步骤 2：检查剩余空间是否足够 ──── */
  /* MEM_SPACE_NEEDED 包括对齐 + 红区 */
  if (mem_block_get_len(block) <
      mem_block_get_free(block) + MEM_SPACE_NEEDED(n)) {

    /* 空间不足 → 添加新块 */
    block = mem_heap_add_block(heap, n);
    if (block == nullptr) {
      return nullptr;
    }
  }

  /* ──── 步骤 3：从新空闲位置分配 ──── */
  ulint free = mem_block_get_free(block);
  buf = (byte *)block + free + MEM_NO_MANS_LAND;  /* 跳过前红区 */

  /* ──── 步骤 4：更新 free 指针 ──── */
  mem_block_set_free(block, free + MEM_SPACE_NEEDED(n));

  /* ──── 步骤 5：填充红区（调试模式）──── */
#ifdef UNIV_DEBUG
  memset(buf - MEM_NO_MANS_LAND,
         MEM_NO_MANS_LAND_BEFORE_BYTE, MEM_NO_MANS_LAND);
  memset(buf + n,
         MEM_NO_MANS_LAND_AFTER_BYTE,
         MEM_SPACE_NEEDED(n) - n - MEM_NO_MANS_LAND);
#endif

  return buf;
}
```

**分配的时间复杂度**：

```
通常情况: O(1)
  1. 读最后一个块的 free 指针
  2. 比较 len - free 和请求大小
  3. 足够 → 移动 free → 返回

需要扩容时: O(1) 摊还（链表追加）
  1. mem_heap_add_block → O(1) 或 O(n) malloc
  2. 但很少触发，因为块大小翻倍

最坏情况: O(n)
  连续分配大量小对象且每次都需要新块
  但翻倍策略保证摊还 O(1)
```

---

## 4. 扩容路径 — mem_heap_add_block()

当最后一个块的剩余空间不足时，调用此函数添加新块：

```cpp
// mem0mem.ic
mem_block_t *mem_heap_add_block(mem_heap_t *heap, ulint n) {

  auto block = UT_LIST_GET_LAST(heap->base);

  /* ──── 步骤 1：计算新块大小（翻倍策略）──── */
  auto new_size = 2 * block->len;        /* 翻倍 */

  /* ──── 步骤 2：大小约束 ──── */
  if (new_size < MEM_BLOCK_STANDARD_SIZE) {
    /* 最小 8000 字节（标准块大小）*/
    new_size = MEM_BLOCK_STANDARD_SIZE;
  }

  /* 最大约束：不能超过 MEM_MAX_ALLOC_IN_BUF（在 Buffer Pool 模式下）*/
  /* 这是硬上限，防止单个分配撑爆 BP */
  /* 通常 = 2MB（128 个 16KB 页）*/

  if (new_size > MEM_MAX_ALLOC_IN_BUF && block->len < MEM_MAX_ALLOC_IN_BUF) {
    new_size = MEM_MAX_ALLOC_IN_BUF;
  }

  /* ──── 步骤 3：创建新块并追加 ──── */
  auto new_block = mem_heap_create_block(
      heap,        /* 不为 nullptr → 追加 */
      new_size,
      IF_DEBUG(...)
      block->type);

  if (new_block == nullptr) {
    /* 如果 MEM_HEAP_BTR_SEARCH → 返回 nullptr */
    return nullptr;
  }

  /* ──── 步骤 4：更新首块的总大小 ──── */
  /* （首块的 total_size 跟踪整个堆的大小）*/
  auto first = UT_LIST_GET_FIRST(heap->base);
  first->total_size += mem_block_get_len(new_block);

  return new_block;
}
```

**翻倍策略的增长曲线**：

```
首次: MEM_BLOCK_STANDARD_SIZE = 8000
第 1 次扩容: 16000
第 2 次扩容: 32000
第 3 次扩容: 64000
...
直到 MEM_MAX_ALLOC_IN_BUF（通常 2MB）

对于小分配（如 dict_table_t 的 heap）:
  首块 8000 字节足够容纳数十个列/索引对象
  很少需要扩容

对于大分配（如 AHI 的内存堆）:
  会从 8000 翻倍到 2MB 很快成熟
  但此后维持在 2MB 不会再增长
```

---

## 5. 释放路径

### 5.1 mem_heap_free() — 完全释放

```cpp
// mem0mem.ic:450
static inline void mem_heap_free(mem_heap_t *heap) {

  ut_d(mem_heap_validate(heap));

  /* ──── 步骤 1：遍历并释放所有块 ──── */
  mem_block_t *block = UT_LIST_GET_FIRST(heap->base);

  while (block != nullptr) {
    mem_block_t *next_block = UT_LIST_GET_NEXT(list, block);

    mem_heap_block_free(heap, block);

    block = next_block;
  }

  /* 调试：魔数已被 mem_heap_block_free 改为 MEM_FREED_BLOCK_MAGIC_N */
  ut_ad(heap == nullptr ||
        heap->magic_n == MEM_FREED_BLOCK_MAGIC_N);
}
```

### 5.2 mem_heap_block_free() — 单块释放

```cpp
// mem0mem.ic — 简化
static void mem_heap_block_free(mem_heap_t *heap, mem_block_t *block) {

  /* 验证块有效 */
  ut_ad(block->magic_n == MEM_BLOCK_MAGIC_N);

  /* 标记为已释放 */
  block->magic_n = MEM_FREED_BLOCK_MAGIC_N;

  if (block->buf_block != nullptr) {
    /* 从 BP 释放 */
    buf_block_free(block->buf_block);
  } else {
    /* 从 C heap 释放 */
    ut::free(block);
  }
}
```

释放后，如果 `heap` 本身是首块的地址，此时 `heap` 指向的内存已经释放，访问其魔数会导致段错误——但 `ut_ad` 在非调试模式下被移除，所以不会崩溃。调试模式下 `mem_heap_free` 的最后一行检查 `heap->magic_n` 在堆完全释放前的状态。

### 5.3 mem_heap_empty() — 清空但保留

```cpp
// mem0mem.ic:279
static inline void mem_heap_empty(mem_heap_t *heap) {

  /* ──── 步骤 1：保留首块，释放所有后续块 ──── */
  mem_block_t *block;

  block = UT_LIST_GET_LAST(heap->base);
  while (block != UT_LIST_GET_FIRST(heap->base)) {
    mem_block_t *prev_block = UT_LIST_GET_PREV(list, block);

    mem_heap_block_free(heap, block);

    block = prev_block;
  }

  /* ──── 步骤 2：重置首块的 free 指针到初始位置 ──── */
  mem_block_set_free(
      UT_LIST_GET_FIRST(heap->base),
      mem_block_get_start(UT_LIST_GET_FIRST(heap->base)));

  /* ──── 步骤 3：重置总计大小 ──── */
  auto first = UT_LIST_GET_FIRST(heap->base);
  first->total_size = first->len;
}
```

**`empty` vs `free` 的选择**：

```
场景                 | 调用         | 优点
─────────────────────|──────────────|─────────────────
表关闭 → 可能重新打开 | empty        | 保留首块内存，下次打开更快
DDL 结束 → 不再需要  | free         | 完全归还内存
AHI 全局禁用         | empty(所有堆) │ 完全清空哈希表
表结构变更           | empty        | 表定义改变，重新分配
```

### 5.4 mem_heap_free_top() — 回退最近分配

```cpp
// mem0mem.ic
static inline void mem_heap_free_top(mem_heap_t *heap, ulint n) {

  mem_block_t *block = UT_LIST_GET_LAST(heap->base);
  ulint free = mem_block_get_free(block);

  /* 回退 free 指针 */
  mem_block_set_free(block, free - MEM_SPACE_NEEDED(n));

  /* 注意：没有重置已分配区域的内容 */
  /* 没有 memcpy/memset — 这只是一个指针操作 */
}
```

**仅当调用者确切知道释放的字节数时才能使用**。如果调用者先后分配了两个对象然后试图释放第一个——`free_top` 会让第二个对象的"free 区域"被覆盖，因为第二个对象的分配已经在更靠后的偏移量上了。这类似于 C 的栈指针回退（`rsp` POP 操作）。

---

## 6. 典型使用场景

### 6.1 dict_table_t::heap

每个 `dict_table_t` 对象都有自己的 `mem_heap_t`：

```cpp
dict_table_t *dict_mem_table_create(...) {
  auto heap = mem_heap_create(0, UT_LOCATION_HERE, MEM_HEAP_DYNAMIC);
  auto table = (dict_table_t *)mem_heap_alloc(heap, sizeof(dict_table_t));
  table->heap = heap;
  table->cols = (dict_col_t *)mem_heap_alloc(heap, n_cols * sizeof(dict_col_t));
  ...
  return table;
}

void dict_table_remove_from_cache(dict_table_t *table) {
  ...
  /* 释放整个堆 → 所有子对象一起释放 */
  mem_heap_free(table->heap);  /* table 本身也在这个 heap 中 */
}
```

使用 heap 的好处：

```
malloc 方式:
  dict_table_t → malloc(192)
  dict_col_t[10] → malloc(10 * 4)
  dict_index_t[3] → malloc(3 * 240)
  dict_field_t[6] → malloc(6 * 16)
  → 5 次 malloc 调用 + 5 次 free

heap 方式:
  mem_heap_create() → 1 次 malloc (8000 bytes 首块)
  所有子对象从同一块中分配 → 0 次额外 malloc
  mem_heap_free() → 1 次 free
  → 1 次调用
```

### 6.2 AHI 哈希表堆

```cpp
// btr0sea.h — AHI 分区
struct search_part_t {
  hash_table_t *hash_table;  // 包含 heap
};

hash_table_t *hash_create(ulint n_cells) {
  auto table = (hash_table_t *)mem_heap_alloc(
      heap, sizeof(hash_table_t));
  table->heap = mem_heap_create(
      0, UT_LOCATION_HERE, MEM_HEAP_FOR_BTR_SEARCH);
  table->cells = (hash_cell_t *)mem_heap_alloc(
      table->heap, n_cells * sizeof(hash_cell_t));
  ...
}
```

AHI 使用 `MEM_HEAP_FOR_BTR_SEARCH = MEM_HEAP_BUFFER | MEM_HEAP_BTR_SEARCH`：
- 大块从 Buffer Pool 分配
- 如果 BP 不足，允许返回 NULL（不阻塞 AHI 构建）

### 6.3 通用数据结构

```cpp
// dict0mem.h — dict_mem_*_create 系列函数
dict_index_t *dict_mem_index_create(...) {
  auto heap = mem_heap_create(0, UT_LOCATION_HERE, MEM_HEAP_DYNAMIC);
  auto index = (dict_index_t *)mem_heap_alloc(heap, sizeof(dict_index_t));
  index->heap = heap;
  index->fields = (dict_field_t *)mem_heap_alloc(heap, ...);
  return index;
}

dict_foreign_t *dict_mem_foreign_create(void) {
  return (dict_foreign_t *)mem_heap_alloc(
      mem_heap_create(0, UT_LOCATION_HERE, MEM_HEAP_DYNAMIC),
      sizeof(dict_foreign_t));
}
```

---

## 7. 与 C++ STL 的集成 — mem_heap_allocator<T>

`mem0mem.h:340` 定义了一个 C++ STL 兼容的分配器，使得 `std::vector` 等可以使用 InnoDB 的 heap：

```cpp
template <typename T>
class mem_heap_allocator {
 public:
  using value_type = T;

  explicit mem_heap_allocator(mem_heap_t *heap) : m_heap(heap) {}

  pointer allocate(size_type n, const_pointer hint = nullptr) {
    return reinterpret_cast<pointer>(
        mem_heap_alloc(m_heap, n * sizeof(T)));
  }

  void deallocate(pointer p, size_type n) {
    /* mem_heap 不支持单元素释放 — 由 heap 所有者统一 free */
    /* 这只在 mem_heap_free_top 或 mem_heap_free 时有效 */
  }

  template <typename U>
  bool operator==(const mem_heap_allocator<U> &other) const {
    return m_heap == other.heap();
  }

 private:
  mem_heap_t *m_heap;
};

/* 使用示例：InnoDB 内部使用 std::vector 管理列数组 */
using col_vec_t = std::vector<dict_col_t,
                               mem_heap_allocator<dict_col_t>>;
```

**为什么 deallocate 是空操作？**

InnoDB 的 heap 是"块级回收"的，不支持单对象释放。`deallocate` 不释放任何内存，只是 STL 接口要求的空实现。这意味着：

- 临时 `vector` 的销毁不会立即归还内存
- 只有 `mem_heap_free` 或 `mem_heap_empty` 才会真正释放
- 如果大量使用临时变量，谨慎选择 heap 的生命周期

---

## 8. 调试机制

### 8.1 魔数验证链

```cpp
// 每次操作前的验证（调试模式）
static inline void mem_block_validate(const mem_block_t *block) {
  ut_ad(block != nullptr);
  if (block->magic_n != MEM_BLOCK_MAGIC_N) {
    ib::fatal error(UT_LOCATION_HERE)
        << "Memory block is corrupted. Expected "
        << MEM_BLOCK_MAGIC_N << " but got " << block->magic_n;
  }
}

static inline void mem_heap_validate(mem_heap_t *heap) {
  mem_block_validate(heap);

  /* 遍历所有块，验证每个块的魔数 */
  for (auto block = UT_LIST_GET_FIRST(heap->base);
       block != nullptr;
       block = UT_LIST_GET_NEXT(list, block)) {
    mem_block_validate(block);

    /* 验证 free 指针范围 */
    ut_a(mem_block_get_free(block) <= mem_block_get_len(block));
  }
}
```

### 8.2 红区检测

```cpp
// 验证红区完整性
static void mem_heap_check_red_zones(mem_heap_t *heap) {
  mem_block_t *block;

  for (block = UT_LIST_GET_FIRST(heap->base);
       block != nullptr;
       block = UT_LIST_GET_NEXT(list, block)) {

    /* 检查当前已分配区域的红区 */
    ulint free = mem_block_get_free(block);
    ulint start = mem_block_get_start(block);

    for (ulint i = 0; i < free - start; i++) {
      byte *addr = (byte *)block + start + i;
      // 检查前红区
      if ((byte)i < MEM_NO_MANS_LAND &&
          *addr != MEM_NO_MANS_LAND_BEFORE_BYTE) {
        ib::error() << "Buffer overflow detected!";
      }
    }

    /* 检查后红区 */
    byte *after_gap = (byte *)block + free - MEM_NO_MANS_LAND;
    for (ulint i = 0; i < MEM_NO_MANS_LAND; i++) {
      if (after_gap[i] != MEM_NO_MANS_LAND_AFTER_BYTE) {
        ib::error() << "Buffer underflow detected!";
      }
    }
  }
}
```

红区检测的价值：

```
问题: dict_table_t 的 heap 中分配了 n_cols 个 dict_col_t
       某个代码写入了 cols[n_cols]（多一个）

         ← 前红区 → ← cols[0] → ← cols[1] → ... ← 后红区 →
         0xCE 0xCE    data       data         0xDF 0xDF

如果写多了 → 覆盖后红区为 0xDF → mem_heap_check_red_zones 检测到
                立即断言失败 → 找到 bug

如果写少了 → 前红区被覆盖 → 同理
```

### 8.3 调试辅助函数

```cpp
// 查看堆信息
static inline size_t mem_heap_get_size(mem_heap_t *heap) {
  ut_ad(heap);
  ut_d(mem_block_validate(heap));
  return heap->base.total_size;
}

// 查看堆中的已分配字节
static inline ulint mem_heap_get_used(mem_heap_t *heap) {
  ulint total = 0;
  for (auto block = UT_LIST_GET_FIRST(heap->base);
       block != nullptr;
       block = UT_LIST_GET_NEXT(list, block)) {
    total += mem_block_get_free(block) - mem_block_get_start(block);
  }
  return total;
}

// 低内存通知
static inline void mem_heap_warn_low_memory(mem_heap_t *heap) {
  if (heap->base.total_size > (1024 * 1024)) {  /* > 1MB */
    ib::warn() << "Large memory heap: " << heap->base.total_size;
  }
}
```

---

## 9. 性能特征总结

| 操作 | 时间复杂度 | 说明 |
|------|-----------|------|
| `mem_heap_create` | O(1) malloc | 一次底层内存分配 |
| `mem_heap_alloc`（有空间） | O(1) | 仅移动 free 指针 |
| `mem_heap_alloc`（需扩容） | O(n) malloc | 翻倍大小，摊还 O(1) |
| `mem_heap_free_top` | O(1) | 回退指针 |
| `mem_heap_empty` | O(n) 块释放 | 保留首块，释放其余 |
| `mem_heap_free` | O(n) 块释放 | n = 块数（通常 1-5） |

**空间效率**：

- 头部开销：`MEM_BLOCK_HEADER_SIZE` ≈ 56 字节（对齐后）
- 每块内部碎片：最多 `UNIV_MEM_ALIGNMENT - 1` = 7 字节
- 红区开销（调试）：每分配 32 字节（16+16）不算少，但仅在 `UNIV_DEBUG` 下
- 首块浪费：最小 8000 字节，如果只用了几十个字节，浪费很大——但多数场景（如 `dict_table_t` 的 heap）会用完大部分空间

---

## 10. 源码索引

| 函数/结构 | 文件 | 行号 | 关键作用 |
|-----------|------|------|---------|
| `MEM_BLOCK_MAGIC_N` | `mem0mem.h` | — | 0x445566778899AABB |
| `mem_block_info_t` struct | `mem0mem.h` | 302 | 内存块定义 |
| `mem_heap_allocator<T>` | `mem0mem.h` | 340 | STL 兼容分配器 |
| `MEM_HEAP_DYNAMIC/BUFFER/BTR_SEARCH` | `mem0mem.h` | — | 堆类型标志 |
| `mem_heap_create_block()` | `mem0mem.ic` | 44 | 底层块分配 |
| `mem_heap_alloc()` | `mem0mem.ic` | 143 | 堆内分配 |
| `mem_heap_add_block()` | `mem0mem.ic` | — | 块扩容 |
| `mem_heap_empty()` | `mem0mem.ic` | 279 | 清空堆保留首块 |
| `mem_heap_free_top()` | `mem0mem.ic` | — | 回退最近分配 |
| `mem_heap_create()` | `mem0mem.ic` | 423 | 创建堆 |
| `mem_heap_free()` | `mem0mem.ic` | 450 | 释放整个堆 |
| `mem_heap_block_free()` | `mem0mem.ic` | — | 释放单块 |
| `mem_heap_get_size()` | `mem0mem.ic` | — | 总大小 |
| `mem_heap_get_used()` | `mem0mem.ic` | — | 已使用大小 |
