# 20. InnoDB 内存管理 (Memory Heap)

> 本文分析 InnoDB 内存堆（Memory Heap）的实现，包括内存块结构、分配/释放/回收路径、类型系统（动态堆 vs 缓冲池堆），以及调试机制。核心文件：`mem0mem.h`、`mem0mem.ic`。

---

## 1. 概述

InnoDB 没有直接使用 `malloc`/`free` 管理所有内部内存，而是实现了一套 **Memory Heap** 系统。每个内存堆由一组链表连接的 `mem_block_t` 组成，支持两种底层分配方式：

| 类型 | 常量 | 说明 |
|------|------|------|
| `MEM_HEAP_DYNAMIC` | 0 | 从 C heap（malloc）分配 |
| `MEM_HEAP_BUFFER` | 1 | 从 InnoDB Buffer Pool 分配（≥ 8000 bytes 的大块） |
| `MEM_HEAP_BTR_SEARCH` | 2 | 可选标志，允许分配失败时返回 NULL（用于 AHI） |

主要文件：`mem0mem.h` 定义结构体和内联函数，`mem0mem.ic` 实现具体的分配释放逻辑。

---

## 2. 核心数据结构

### 2.1 内存块 `mem_block_info_t`

```cpp
// mem0mem.h:302
struct mem_block_info_t {
  /** 魔数，用于调试校验 */
  uint64_t magic_n;

  /** 链表的 next/prev 指针 */
  UT_LIST_NODE_T(mem_block_t) list;

  /** 首块中存放链表基节点，其余块的该字段未定义 */
  UT_LIST_BASE_NODE_T_EXTERN(mem_block_t, list) base;

  /** 该块的物理长度（字节） */
  ulint len;

  /** 所有块的总物理长度，仅在基节点中有效 */
  ulint total_size;

  /** 堆类型：MEM_HEAP_DYNAMIC / MEM_HEAP_BUFFER (| MEM_HEAP_BTR_SEARCH) */
  ulint type;

  /** 用户数据区域的第一个空闲偏移量 */
  ulint free;

  /** 创建该块时 free 的值（用于 free_top 回退） */
  ulint start;

  /** 如果是 MEM_HEAP_BTR_SEARCH 类型且为堆根块，
  指向一个原子指针，可存放预分配的 buffer block */
  std::atomic<buf_block_t *> *free_block_ptr;

  /** 如果从缓冲池分配，此处为 buf_block_t 句柄；否则为 NULL */
  buf_block_t *buf_block;
};

typedef mem_block_info_t mem_block_t;
typedef mem_block_t mem_heap_t;
```

**关键常量**：

```cpp
// mem0mem.h
constexpr uint64_t MEM_BLOCK_MAGIC_N = 0x445566778899AABB;       // 有效块
constexpr uint64_t MEM_FREED_BLOCK_MAGIC_N = 0xBBAA998877665544; // 已释放块
constexpr uint32_t MEM_BLOCK_START_SIZE = 64;                     // 默认首块大小
constexpr uint32_t MEM_BLOCK_STANDARD_SIZE = 8000;                // 默认后续块大小
constexpr int MEM_NO_MANS_LAND = 16;       // 调试模式下的红区（前后各 16 字节）
```

---

## 3. 分配路径：`mem_heap_alloc`

```cpp
// mem0mem.ic:143
static inline void *mem_heap_alloc(mem_heap_t *heap, ulint n) {
  mem_block_t *block;
  byte *buf;

  ut_d(mem_block_validate(heap));

  /* Step 1: 获取最后一个块 */
  block = UT_LIST_GET_LAST(heap->base);                   // line 150

  /* Step 2: 检查剩余空间是否足够 */
  if (mem_block_get_len(block) <
      mem_block_get_free(block) + MEM_SPACE_NEEDED(n)) {  // line 153
    /* 空间不够，添加新块 */
    block = mem_heap_add_block(heap, n);                  // line 155
    if (block == nullptr) {
      return nullptr;
    }
  }

  /* Step 3: 分配空间 */
  free = mem_block_get_free(block);                       // line 162
  buf = (byte *)block + free + MEM_NO_MANS_LAND;          // line 164

  /* Step 4: 更新空闲偏移量 */
  mem_block_set_free(block, free + MEM_SPACE_NEEDED(n));  // line 166

  /* Step 5: 调试模式下填充红区 */
#ifdef UNIV_DEBUG
  memset(buf - MEM_NO_MANS_LAND, MEM_NO_MANS_LAND_BEFORE_BYTE, MEM_NO_MANS_LAND);
  memset(buf + n, MEM_NO_MANS_LAND_AFTER_BYTE, MEM_SPACE_NEEDED(n) - n - MEM_NO_MANS_LAND);
#endif

  return buf;  // 返回用户数据的起始地址
}
```

`MEM_SPACE_NEEDED` 将请求大小 N 对齐到 `UNIV_MEM_ALIGNMENT`（通常 8 字节）并加上红区：

```cpp
static inline uint64_t MEM_SPACE_NEEDED(uint64_t N) {
  return ut_calc_align(N + 2 * MEM_NO_MANS_LAND, UNIV_MEM_ALIGNMENT);
}
```

---

## 4. 创建与销毁

### 4.1 `mem_heap_create`

```cpp
// mem0mem.ic:423
static inline mem_heap_t *mem_heap_create(ulint size,
    IF_DEBUG(const char *file_name, ulint line, )
    ulint type) {
  mem_block_t *block;

  /* Step 1: 创建首块（size=0 时使用 MEM_BLOCK_START_SIZE=64） */
  if (size == 0) size = MEM_BLOCK_START_SIZE;
  block = mem_heap_create_block(nullptr, size,              // line 432
                                IF_DEBUG(file_name, line, ) type);

  /* Step 2: 设置 type */
  mem_block_set_type(block, type);

  return block;
}
```

### 4.2 `mem_heap_create_block`

```cpp
// mem0mem.ic:44
mem_block_t *mem_heap_create_block(mem_heap_t *heap, ulint n,
    IF_DEBUG(const char *file_name, ulint line, )
    ulint type) {
  mem_block_t *block;
  ulint block_size;

  /* 计算块大小：header + 对齐后的用户空间 */
  block_size = MEM_BLOCK_HEADER_SIZE + MEM_SPACE_NEEDED(n);
  if (block_size < MEM_BLOCK_STANDARD_SIZE && heap == nullptr) {
    block_size = MEM_BLOCK_STANDARD_SIZE;  // 首块至少为 8000 字节
  }

  if (type & MEM_HEAP_BUFFER) {
    // 从 Buffer Pool 分配
    block = (mem_block_t *)buf_block_alloc(nullptr)->frame;
  } else {
    // 从 C heap 分配
    block = (mem_block_t *)ut::malloc_withkey(... block_size);
  }

  /* 初始化块字段 */
  block->magic_n = MEM_BLOCK_MAGIC_N;
  block->len = block_size;
  block->free = MEM_BLOCK_HEADER_SIZE;
  block->start = MEM_BLOCK_HEADER_SIZE;

  // 如果是首块，初始化链表基节点
  if (heap == nullptr) {
    UT_LIST_INIT(block->base, &mem_block_t::list);
    UT_LIST_ADD_LAST(block->base, block);
    block->total_size = block_size;
  } else {
    // 追加到已有堆
    UT_LIST_ADD_LAST(heap->base, block);
  }

  return block;
}
```

### 4.3 `mem_heap_free`

```cpp
// mem0mem.ic:450
static inline void mem_heap_free(mem_heap_t *heap) {
  ut_d(mem_heap_validate(heap));

  /* Step 1: 遍历并释放所有块 */
  mem_block_t *block = UT_LIST_GET_FIRST(heap->base);
  while (block != nullptr) {
    mem_block_t *prev_block = block;
    block = UT_LIST_GET_NEXT(list, block);

    mem_heap_block_free(heap, prev_block);   // 释放单个块
  }

  ut_ad(heap->magic_n == MEM_FREED_BLOCK_MAGIC_N);
}
```

---

## 5. 回收路径：`mem_heap_empty` 与 `mem_heap_free_top`

### 5.1 `mem_heap_empty` — 清空但不释放

```cpp
// mem0mem.ic:279
static inline void mem_heap_empty(mem_heap_t *heap) {
  /* Step 1: 保留首块，释放所有后续块 */
  mem_block_t *block = UT_LIST_GET_LAST(heap->base);
  while (block != UT_LIST_GET_FIRST(heap->base)) {
    mem_block_t *prev_block =
        UT_LIST_GET_PREV(list, block);
    mem_heap_block_free(heap, block);
    block = prev_block;
  }

  /* Step 2: 重置首块的 free 指针 */
  mem_block_set_free(UT_LIST_GET_FIRST(heap->base),
                     mem_block_get_start(UT_LIST_GET_FIRST(heap->base)));
}
```

### 5.2 `mem_heap_free_top` — 回退最近分配

```cpp
// mem0mem.ic
static inline void mem_heap_free_top(mem_heap_t *heap, ulint n) {
  mem_block_t *block = UT_LIST_GET_LAST(heap->base);
  ulint free = mem_block_get_free(block);

  // 回退 free 指针
  mem_block_set_free(block, free - MEM_SPACE_NEEDED(n));
}
```

---

## 6. 添加新块：`mem_heap_add_block`

```cpp
// mem0mem.ic
mem_block_t *mem_heap_add_block(mem_heap_t *heap, ulint n) {
  /* Step 1: 根据上次分配大小决定新块大小 */
  auto block = UT_LIST_GET_LAST(heap->base);
  auto new_size = 2 * block->len;

  /* Step 2: 最小和最大限制 */
  if (new_size < MEM_BLOCK_STANDARD_SIZE) {
    new_size = MEM_BLOCK_STANDARD_SIZE;
  }
  // 限制在 MEM_MAX_ALLOC_IN_BUF 以内

  /* Step 3: 创建新块 */
  auto new_block = mem_heap_create_block(heap, new_size,
                                         IF_DEBUG(...) block->type);

  /* Step 4: 更新总大小（首块的 total_size） */
  auto first = UT_LIST_GET_FIRST(heap->base);
  first->total_size += mem_block_get_len(new_block);

  return new_block;
}
```

**倍增策略**：每次不足时新块大小翻倍，兼顾小分配效率和大分配空间利用率。

---

## 7. 内存堆类型使用场景

| 堆类型 | 用途 | 例子 |
|--------|------|------|
| `MEM_HEAP_DYNAMIC` | 小分配（CREATE TABLE 临时数据） | `dict_table_t::heap` |
| `MEM_HEAP_BUFFER` | 大块分配 | `ibuf0ibuf.cc` 中的 Change Buffer 堆 |
| `MEM_HEAP_FOR_BTR_SEARCH` | AHI 哈希表 | AHI 的 `hash_table->heap` |

```cpp
// mem0mem.h
constexpr uint32_t MEM_HEAP_FOR_BTR_SEARCH =
    MEM_HEAP_BTR_SEARCH | MEM_HEAP_BUFFER;
constexpr uint32_t MEM_HEAP_FOR_PAGE_HASH = MEM_HEAP_DYNAMIC;
constexpr uint32_t MEM_HEAP_FOR_RECV_SYS = MEM_HEAP_BUFFER;
```

---

## 8. 调试机制

### 8.1 魔数验证

```cpp
static inline void mem_block_validate(const mem_block_t *block) {
  ut_ad(block != nullptr);
  if (block->magic_n != MEM_BLOCK_MAGIC_N) {
    ib::fatal error(UT_LOCATION_HERE);
    error << "Memory block is invalid (should be "
          << MEM_BLOCK_MAGIC_N << ", but it is " << block->magic_n;
  }
}
```

### 8.2 红区（No Man's Land）

调试模式下，每个分配对象前后各有 16 字节的红区：

- **前红区**：填充 `0xCE`，检测缓冲区上溢（写到了 header 前）
- **后红区**：填充 `0xDF`，检测缓冲区下溢（写超过了分配大小）

```cpp
const byte MEM_NO_MANS_LAND_BEFORE_BYTE = 0xCE;
const byte MEM_NO_MANS_LAND_AFTER_BYTE = 0xDF;
```

### 8.3 查看堆大小

```cpp
static inline size_t mem_heap_get_size(mem_heap_t *heap) {
  ut_ad(heap);
  ut_d(mem_block_validate(heap));
  return heap->base.total_size;
}
```

---

## 9. 与 STL 集成

`mem_heap_allocator<T>`（`mem0mem.h:340`）是 C++ STL 风格的包装器，使得 `std::vector`、`std::string` 等容器可以使用 InnoDB 内存堆：

```cpp
// mem0mem.h:340
template <typename T>
class mem_heap_allocator {
 public:
  pointer allocate(size_type n, const_pointer hint = nullptr) {
    return reinterpret_cast<pointer>(
        mem_heap_alloc(m_heap, n * sizeof(T)));
  }
  void deallocate(pointer, size_type) {}  // 不释放单个元素
};
```

---

## 10. 总结

InnoDB Memory Heap 的设计哲学：

1. **块链分配 (Block Chain)**：避免大量小对象 malloc 碎片的元数据开销；内存以 `mem_block_t` 链表组织，一次分配一整块。
2. **双模式支持**：小对象用常规 `malloc`，大对象走 Buffer Pool 以避免 BP 空间碎片。
3. **O(1) 分配**：`mem_heap_alloc` 检查最后一个块的 free 指针即可完成分配，不遍历链表。
4. **栈式释放**：`mem_heap_free_top` 在 AHI 等场景实现 "Stack allocator" 风格的高效回收。
5. **调试友好**：魔数 + 前后红区 + `mem_heap_validate` 提供运行时内存完整性检查。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `mem0mem.h` | 52 | `typedef mem_block_info_t mem_heap_t` |
| `mem0mem.h` | 302 | `struct mem_block_info_t` 定义 |
| `mem0mem.h` | 340 | `class mem_heap_allocator<T>` |
| `mem0mem.ic` | 44 | `mem_heap_create_block()` |
| `mem0mem.ic` | 143 | `mem_heap_alloc()` |
| `mem0mem.ic` | 279 | `mem_heap_empty()` |
| `mem0mem.ic` | 423 | `mem_heap_create()` |
| `mem0mem.ic` | 450 | `mem_heap_free()` |
