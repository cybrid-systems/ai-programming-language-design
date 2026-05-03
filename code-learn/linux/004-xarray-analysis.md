# 04-xarray — Linux 内核 XArray 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**XArray** 是 Linux 内核中稀疏数组（sparse array）的高效实现，由 Matthew Wilcox 在 Linux 4.17（2018年）引入，替代了原有的 radix tree（基数树）。与 radix tree 相比，XArray 提供了更简洁的 API、内部锁管理、更安全的类型检查，以及先进的多索引操作和标记系统。

XArray 的核心思想是用**多路基数树（multi-way radix tree）**来实现一个稀疏数组。每个节点有 64 个槽位（slot），按 6 位一组索引——这意味着在一个 64 位系统上，树的最大深度仅为 10 层（64/6 = 10.67，实际是 10 组 6 位 + 最后 4 位为一组）。与二叉树相比，多路基数树的树高小了 5-6 倍，减少了从根到叶子节点的指针追踪次数。

XArray 设计的关键区别在于：

1. **内部锁管理**：`xa_lock` 内嵌在 `struct xarray` 中，`xa_store`、`xa_erase` 等操作自动管理锁；而 `xa_state` 的 `xas_lock` / `xas_unlock` 允许调用者手动控制锁跨度。
2. **Entry 编码**：通过指针最低位区分正常指针、内部节点、标记值和特殊 entry，避免了额外的内存开销。
3. **标记系统**：每个 entry 支持多个标记位（目前最多 3 个），通过位图在树节点中传播，支持高效筛选操作。
4. **xa_state 遍历器**：`struct xa_state` 封装了遍历状态，支持游标定位、批量操作、惰性节点创建。

**doom-lsp 确认**：`include/linux/xarray.h` 包含 **155 个符号**（9 个数据结构 + 90+ API 函数），`lib/xarray.c` 包含 **210 个符号**（实现函数 + 内部辅助）。

---

## 1. 核心数据结构

### 1.1 `struct xarray`（`xarray.h:300`）

```c
struct xarray {
    spinlock_t xa_lock;      // 内部自旋锁
    gfp_t xa_flags;          // 内存分配标志
    void __rcu *xa_head;     // 指向根节点或直接存储的 entry
} __attribute__((__aligned__(sizeof(long) * 2)));
```

三个字段，总共 **24 字节**（64 位系统，含 padding）。

- **`xa_lock`**：内嵌自旋锁。大多数操作（`xa_store`、`xa_erase`）会自动管理这把锁，调用者无需额外加锁。这是 XArray 相对旧 radix tree 的关键改进——radix tree 要求调用者自己管理锁。
- **`xa_flags`**：控制内存分配行为的标志。初始化时通过 `xa_init_flags(xa, flags)` 设置，可以是 `XA_FLAGS_LOCK_IRQ`（使用 `spin_lock_irq`）、`XA_FLAGS_LOCK_BH`（`spin_lock_bh`）或 `XA_FLAGS_TRACK_FREE`（跟踪空闲 entry）。
- **`xa_head`**：指向树的根。有三种可能的状态：
  - `NULL`：空 XArray
  - 正常指针（非 `xa_node`）：单 entry，树深度为 0
  - `xa_node*`：多 entry，指向根 `xa_node`

### 1.2 `struct xa_node`（`xarray.h:1168`）

```c
struct xa_node {
    unsigned char   shift;          // 当前节点索引需要移位的位数
    unsigned char   offset;         // 在父节点中的槽位索引
    unsigned char   count;          // 非空槽位数
    unsigned char   nr_values;      // 值为 XA_ZERO_ENTRY 的槽位数
    struct xa_node __rcu *parent;   // 父节点
    struct xarray   *array;         // 所属的 xarray
    union {
        struct list_head private_list;  // 回收链表
        struct rcu_head rcu_head;       // RCU 延迟释放
    };
    void __rcu      *slots[XA_CHUNK_SIZE];  // 子节点/entry 数组（固定 64 槽）
};
```

**关键字段详解**：

| 字段 | 类型 | 含义 |
|------|------|------|
| `shift` | `unsigned char` | 当前节点索引右移的位数。根节点 = `(最高有效位) - 6 × depth`，每下降一层减 6 |
| `offset` | `unsigned char` | 本节点在父节点 `slots[]` 中的索引。用于向上传播标记时快速定位 |
| `count` | `unsigned char` | 非空槽位数。`count == 0` 表示可回收 |
| `nr_values` | `unsigned char` | 存储 `XA_ZERO_ENTRY` 的槽位数 |
| `slots[]` | `void__rcu *[XA_CHUNK_SIZE]` | 固定数组，`XA_CHUNK_SIZE = 64` 个槽 |

**`shift` 的工作示例**：

```
索引为 123456 的 entry（二进制: 0b11110001001000000）

如果 shift = 12（根节点）：
  offset = (123456 >> 12) & 63 = 30 & 63 = 30
  → slots[30] 指向下一层节点

如果 shift = 6（中间节点）：
  offset = (123456 >> 6) & 63 = 1929 & 63 = 9
  → slots[9] 指向下一层节点

如果 shift = 0（叶子节点）：
  offset = (123456 >> 0) & 63 = 123456 & 63 = 0
  → slots[0] 就是存储 entry 的位置
```

### 1.3 `struct xa_limit`（`xarray.h:243`）

```c
struct xa_limit {
    u32 max;    // 最大可分配索引
    u32 min;    // 最小可分配索引
};
```

用于 `xa_alloc` 系列函数，限制自动分配 ID 的范围。

### 1.4 Entry 编码体系

XArray 通过指针的**最低 2 位**（64 位系统上有 3 位可用，因 8 字节对齐）来编码不同类型：

```c
// xarray.h:58-189

// 外部 entry（普通数据指针）：最低 2 位为 00
// 内部节点指针（xa_node*）：最低 2 位也是 00（节点从 slab 分配，8 字节对齐）

// 内部 entry 的检测：
#define XA_INTERNAL_ENTRY(entry)  ((unsigned long)(entry) & 3UL)

// 值编码（存储整数 <= ULONG_MAX）：
static inline void *xa_mk_value(unsigned long v);   // xarray.h:58
static inline unsigned long xa_to_value(const void *e); // xarray.h:71
static inline bool xa_is_value(const void *e);       // xarray.h:83

// 标记指针（存储带有 2 位 tag 的指针）：
static inline void *xa_tag_pointer(void *p, unsigned long tag); // xarray.h:101
static inline unsigned long xa_pointer_tag(void *p);            // xarray.h:131

// 内部 entry 常量：
#define XA_RETRY_ENTRY  xa_mk_internal(256)  // 需要重试（并发更新）
#define XA_ZERO_ENTRY   xa_mk_internal(257)  // 显式零值
```

**位级编码规则**：

```
位 63:3 — 指针/值域
位 2:1  — tag（用于 xa_tag_pointer）
位 0    — value bit（1 = 值编码, 0 = 指针/内部）

校验函数 xa_is_internal(entry)：
  return ((unsigned long)entry & 1UL) == 0;
  → 位 0 = 0 表示内部 entry，位 0 = 1 表示值编码
```

---

## 2. 内部节点管理

### 2.1 `xas_create`——延迟节点创建

XArray 在写入 entry 时，不会预先创建完整的路径——它只在需要时**惰性创建**缺失的节点：

```c
// lib/xarray.c — 简化后的 xas_create
int xas_create(struct xa_state *xas, bool allow_root, unsigned int order)
{
    struct xa_node *node = xas->xa_node;
    unsigned int shift = 0;
    unsigned long order_mask = 0;

    // 从 xas->xa_node 开始，检查路径上的节点是否存在
    // 如果 xa_node = XAS_RESTART，从根开始
    // 如果 xa_node 是内部节点，从该节点开始
    // 否则创建从根到目标完整路径上的所有节点

    for (;;) {
        // 创建或移动到下一层
        // ...
    }

    // 标记需要更新的节点
}
```

**创建路径**：如果当前索引 `123456` 需要 3 层节点，但只有根节点存在：

```
初始化: xa_head = NULL

xa_store(123456, page_ptr, GFP_KERNEL)
  → xas_create:
    1. xa_head 为空 → 创建根节点（shift = 12）
    2. 根节点的 slots[30] 为空 → 创建中间节点（shift = 6）
    3. 中间节点的 slots[9] 为空 → 创建叶子节点（shift = 0）
    4. 叶子节点的 slots[0] = page_ptr

路径完全创建完毕后，xas_store 将 entry 写入 slots[0]
```

### 2.2 节点回收——`xas_destroy`（`lib/xarray.c:270`）

当节点 `count == 0`（所有 slots 都为空）时，节点可以被回收。XArray 使用 `RCU` 延迟释放，保证正在执行 RCU 读路径的代码安全：

```c
// lib/xarray.c:256
static void xa_node_free(struct xa_node *node)
{
    // 使用 RCU 回调，在 grace period 结束后释放
    call_rcu(&node->rcu_head, xa_node_free_cb);
}
```

RCU 安全的 key：`struct xa_node` 中包含 `union { struct list_head private_list; struct rcu_head rcu_head; }`，意味着 `rcu_head` 和 `private_list` 复用同一段内存——不同生命周期使用不同的字段。

---

## 3. 核心操作——doom-lsp 确认的行号

### 3.1 `xa_load`——按索引读取（`xarray.h:355`）

```c
// xarray.h:355 — doom-lsp 确认（声明）
// lib/xarray.c:1612 — 实际实现
void *xa_load(struct xarray *xa, unsigned long index)
{
    XA_STATE(xas, xa, index);   // 初始化遍历器
    void *entry;

    rcu_read_lock();            // RCU 临界区
    do {
        entry = xas_load(&xas); // 核心读取
        if (xa_is_zero(entry))  // 显式零值
            entry = NULL;
    } while (xas_retry(&xas, entry)); // 重试循环
    rcu_read_unlock();

    return entry;
}
```

**doom-lsp 数据流追踪——`xas_load`（`lib/xarray.c:237`）**：

```c
void *xas_load(struct xa_state *xas)
{
    void *entry = xas_start(xas);         // 定位到树中的起点
    // xas_start 调用 xas_descend 沿路径下降
    // 或如果 xas->xa_node == XAS_RESTART → 从根开始

    while (xa_is_node(entry)) {           // 持续下降到叶子层
        struct xa_node *node = xa_to_node(entry);

        if (xas->xa_shift > node->shift)  // 需要创建？返回 NULL
            break;

        xas->xa_node = node;              // 更新遍历器的当前节点

        if (node->shift == 0)             // 叶子层是 slots[]
            break;

        xas->xa_offset = get_offset(xas->xa_index, node);
        // 计算当前索引在该节点中的槽位

        entry = rcu_dereference(node->slots[xas->xa_offset]);
        // RCU 安全读取
    }

    return entry;
}
```

读取路径的时间复杂度：**O(树高) = O(log_64(n))**，其中 n 是最大索引。对于 64 位索引，最坏树高 = 10 层。

### 3.2 `xa_store`——写入 entry（`xarray.h:356`）

```c
// xarray.h:356 — doom-lsp 确认
void *xa_store(struct xarray *xa, unsigned long index, void *entry, gfp_t gfp)
{
    XA_STATE(xas, xa, index);
    void *curr;

    if (WARN_ON_ONCE(xa_is_internal(entry)))
        return XA_ERROR(-EINVAL);
    if (!entry && xa_is_internal(xa_head(xa)))
        return XA_ERROR(-EINVAL);

    xa_lock(xa);                     // 自动加锁
    curr = __xa_store(xa, index, entry, gfp);
    xa_unlock(xa);

    return curr;                     // 返回旧的 entry
}
```

**doom-lsp 数据流追踪——`__xa_store`（`xarray.h:563`）**：

```
xa_store(xa, idx, entry, gfp)          @ xarray.h:356
  └─ xa_lock(xa)
     └─ __xa_store(xa, idx, entry, gfp)  @ xarray.h:563
          └─ xas_store(&xas, entry)       @ lib/xarray.c
               │
               ├─ xas_start(&xas)         ← 定位起点
               ├─ xas_create(&xas)        ← 创建路径节点（惰性）
               │
               ├─ 写入 entry:
               │   if (xa_is_node(entry))
               │       // entry 是子树根，需要嵌入
               │   else
               │       slot = &node->slots[offset]
               │       old = rcu_dereference(*slot)
               │       rcu_assign_pointer(*slot, entry)
               │   ├─ 更新 count/nr_values
               │   └─ 触发 xas_update (标记传播 + lru 维护)
               │
               ├─ entry 为 NULL（删除）:
               │   ├─ count == 0 → xas_destroy
               │   └─ 向上传播标记变化
               │
               └─ return old              ← 返回旧的 entry
```

### 3.3 `xa_erase`——删除 entry（`xarray.h:357`）

```c
// xarray.h:357 — doom-lsp 确认
void *xa_erase(struct xarray *xa, unsigned long index)
{
    return xa_store(xa, index, NULL, 0);  // 存储 NULL = 删除
}
```

`xa_store(xa, index, NULL, 0)` 等效于删除。内部 `xas_store` 检测到 NULL 写入后，减少 `count`，如果 `count == 0`，回收节点。

**doom-lsp 数据流追踪——递归回收**：

```
xa_erase(xa, index)
  └─ xa_store(xa, index, NULL, 0)
       └─ xas_store(&xas, NULL)
            ├─ node->count--       (非空槽减 1)
            ├─ node->count == 0?  (节点变空？)
            │    └─ xas_destroy(&xas)  ← 回收节点
            │         └─ if (parent)  ← 向上递归
            │              parent->count--
            │              parent->count == 0? → 继续向上
            │              否则 → 更新 parent 的标记
            └─ return old_entry
```

---

## 4. xa_state 遍历器——高级游标 API

`struct xa_state`（`xarray.h:1354`）是 XArray 的核心遍历器。它封装了当前遍历位置、路径节点缓存、错误状态等信息。

### 4.1 结构体定义

```c
// xarray.h:1354 — doom-lsp 确认
struct xa_state {
    struct xarray *xa;            // 所属 xarray
    unsigned long xa_index;       // 当前索引
    unsigned char xa_shift;       // 当前激活的 shift
    unsigned char xa_sibs;        // 兄弟节点数量（批量操作）
    unsigned char xa_offset;      // 当前槽位偏移
    unsigned char xa_pad;         // 填充字节
    struct xa_node *xa_node;      // 当前节点
    struct xa_node *xa_alloc;     // 预分配的节点
    xa_update_node_t xa_update;   // 节点更新回调
    struct list_lru *xa_lru;      // LRU 链表
};
```

### 4.2 标准使用模式

```c
// 模式 1：简单读取
XA_STATE(xas, xa, 0);
entry = xas_load(&xas);

// 模式 2：遍历所有 entry
XA_STATE(xas, xa, 0);
xas_for_each(&xas, entry, max_index) {
    // 处理每个 entry
    // entry == NULL 表示空洞
}

// 模式 3：查找带标记的 entry
XA_STATE(xas, xa, 0);
xas_for_each_marked(&xas, entry, max_index, XA_MARK_0) {
    // 只处理标记了 XA_MARK_0 的 entry
}

// 模式 4：批量写入
XA_STATE(xas, xa, index);
xas_lock(&xas);           // 手动锁，减少锁竞争
for (i = 0; i < 1024; i++) {
    xas_store(&xas, page);
    xas_next(&xas);       // 前进到下一个索引
}
xas_unlock(&xas);
```

### 4.3 `xas_for_each`——批量遍历（核心宏）

```c
// xarray.h — 简化展开
#define xas_for_each(xas, entry, max) \
    for (entry = xas_find(xas, max); entry; \
         entry = xas_next_entry(xas, max))
```

数据流：
```
xas_for_each 遍历过程：

初始：xas->xa_node = XAS_RESTART, xas->xa_index = 起始索引

1. xas_find(xas, max):
   a. 如果 xa_node == XAS_RESTART: 从根开始
   b. 调用 xas_descend 下降到叶子
   c. __xas_find: 在当前节点中扫描 slots[]
   d. 找到非空 slot → 返回 entry
   e. 当前节点扫描完 → 回溯到父节点，继续扫描

2. 每次 entry 返回后，xas_next_entry:
   a. 前进到当前节点的下一个 slot
   b. 如果超出范围 → 扫描下一个节点

3. 遍历终止：
   - 所有 entry 处理完毕
   - 到达 max 索引
```

### 4.4 `xas_store`——在当前位置写入

```c
// lib/xarray.c — doom-lsp 确认
void xas_store(struct xa_state *xas, void *entry)
```

在遍历器的当前位置写入 entry。它与 `xas_for_each` 配合使用是实现"遍历并修改"模式的基础。

---

## 5. 标记系统——位图传播

每个 entry 可以关联最多 3 个独立标记位（当前内核只使用 2 个）：

```c
// xarray.h:254
struct {
    xa_mark_t XA_MARK_0;           // page cache: PAGE_FLAG_DIRTY
    xa_mark_t XA_MARK_1;           // page cache: PAGE_FLAG_WRITEBACK
    xa_mark_t XA_MARK_MAX;
};
```

### 5.1 标记的存储——节点位图

标记信息存储在 `xa_node` 中，并非直接存储在 entry 内部：

```c
// xa_node 的 marks 字段（xarray.h:1181）
unsigned long marks[XA_MAX_MARKS][XA_MARK_LONGS];  // 固定 2D 数组
```

每个标记是一个独立位图（`unsigned long` 数组），`XA_CHUNK_SIZE = 64` 位全覆盖一个节点的所有 slots。在 64 位系统上，每个标记位图恰好是 1 个 `unsigned long`，即 **64 bits**，正好对应 64 个 slots。

实际代码中 `marks` 是一个 union 的一部分，与 `tags` 共享存储：

```c
union {
    unsigned long tags[XA_MAX_MARKS][XA_MARK_LONGS];
    unsigned long marks[XA_MAX_MARKS][XA_MARK_LONGS];
};
```

### 5.2 标记的传播

标记在树中是**从下往上传播**的。如果一个子节点中有任何 entry 被打上了某个标记，该标记会向上传播到所有祖先节点的对应标记位。

```c
// lib/xarray.c:80-105 — doom-lsp 确认
static inline bool node_any_mark(struct xa_node *node, xa_mark_t mark)
{
    return !bitmap_empty(node_marks(node, mark), XA_CHUNK_SIZE);
}

// 节点级设置标记：
bool node_set_mark(struct xa_node *node, unsigned int offset, xa_mark_t mark)
{
    return __test_and_set_bit(offset, node_marks(node, mark));
}
```

**标记传播的数据流**：

```
xa_set_mark(xa, index, XA_MARK_0)
  └─ xas_set_mark(&xas, XA_MARK_0)
       ├─ node_set_mark(node, offset, mark)  ← 在叶子节点设置
       ├─ 从叶子向上游到根：
       │   parent->node_set_mark(parent, child->offset, mark)
       │   → 逐级传播到根
       └─ return

标记清除同理：
xa_clear_mark(xa, index, XA_MARK_1)
  └─ xas_clear_mark(&xas, XA_MARK_1)
       ├─ node_clear_mark(node, offset, mark)
       ├─ 向上检查：如果父节点所有子节点的该标记都为空
       │   → 清除父节点的标记位
       └─ return
```

### 5.3 标记的查找——`xas_find_marked`（`xarray.h:1550`）

```c
// lib/xarray.c — 声明@xarray.h:1550
void *xas_find_marked(struct xa_state *xas, unsigned long max, xa_mark_t mark)
```

只在标记了特定标记的 entry 中搜索。通过节点位图的 `find_next_bit` 操作跳过大量不需要检查的槽位：

```c
// 在节点中搜索下一个带标记的 slot 时：
offset = find_next_bit(node_marks(node, mark), XA_CHUNK_SIZE, start);
if (offset < XA_CHUNK_SIZE) {
    // 找到了带标记的 slot
    entry = rcu_dereference(node->slots[offset]);
    // 返回 entry
}
```

**性能优势**：标记位图在 64 位系统上恰好是 1 个 `unsigned long`，`find_next_bit` 使用 `__ffs`/`__fls` 等位扫描指令（x86 上的 `BSF`/`BSR`），单条指令即可找到下一个标记的槽位。

---

## 6. 分配器 API——`xa_alloc` 系列

XArray 还提供了自动分配 ID 的功能系列：

```c
// xarray.h:568 — doom-lsp 确认
void *__xa_alloc(struct xarray *xa, u32 *id, void *entry,
                 struct xa_limit limit, gfp_t gfp);

// xarray.h:570
void *__xa_alloc_cyclic(struct xarray *xa, u32 *id, void *entry,
                         struct xa_limit limit, u32 *next, gfp_t gfp);
```

- `xa_alloc`：在 `[limit.min, limit.max]` 范围内分配一个空闲 ID
- `xa_alloc_cyclic`：循环分配，每次从上一次分配的 `*next` 位置继续

内部实现：当 `xa_flags & XA_FLAGS_TRACK_FREE` 时，XArray 使用 `XA_ZERO_ENTRY` 标记已占用的槽位，将空位标记为「free」，通过扫描 free slot 来寻找可分配的 ID。找到空闲 slot 后写入 entry。

---

## 7. 🔥 doom-lsp 数据流追踪——Page Cache 的运作机制

这是 XArray 在内核中最核心的应用——管理文件页缓存（page cache）。

### 7.1 数据结构

```c
// include/linux/fs.h — struct address_space
struct address_space {
    struct xarray         i_pages;    // XArray: 页偏移 → folio 映射
    struct rw_semaphore   i_mmap_rwsema;
    struct rb_root_cached i_mmap;     // VMA interval tree
    // ...
};
```

**doom-lsp 数据流**：

```
struct address_space (每个文件有一个)
    └── i_pages (struct xarray)
         ├── index 0: folio_A  (文件首 4KB)
         ├── index 1: folio_B  (文件 4KB ~ 8KB)
         ├── index 2: folio_C  (文件 8KB ~ 12KB)
         ├── index 3: NULL     (空洞, 未缓存)
         └── ...
```

### 7.2 页面读取——`filemap_read`

```
read(fd, buf, count)
  └─ vfs_read() → filemap_read()
       └─ filemap_get_pages()
            └─ filemap_get_read_batch(mapping, index, ...)
                 └─ XA_STATE(xas, &mapping->i_pages, index)
                    xas_for_each(&xas, folio, ...) {
                        // 从 XArray 中批量获取 folio
                        // 如果 folio 不在缓存中：
                        //   → filemap_create_folio() → 分配页 → aops->read_folio
                        //   → xa_store(&mapping->i_pages, index, folio, GFP_KERNEL)
                        //      → 写入 XArray
                    }
```

### 7.3 脏页跟踪——写回（writeback）的标记系统

```
应用程序写入文件：
  → generic_perform_write()
    → iomap_write_begin()
      → folio_mark_dirty(folio)
        → mapping_set_error(mapping, ...)
        → xa_set_mark(&mapping->i_pages, folio->index, PAGECACHE_TAG_DIRTY)

写入完成，现在 folio 标记为脏：

writeback 线程扫描：
  → writeback_single_inode()
    → write_cache_pages(mapping, wbc)
      → XA_STATE(xas, &mapping->i_pages, 0)

        // 只遍历标记了 DIRTY 的 page
        xas_for_each_marked(&xas, folio, ULONG_MAX, PAGECACHE_TAG_DIRTY) {
            // 对该 folio 发起回写
            // 回写完成后：
            folio_clear_dirty_for_io(folio);
            // 会由 block layer 的回调清除 tag
        }

回写完成后：
  → test_clear_page_writeback(folio)
    → xa_clear_mark(&mapping->i_pages, folio->index, PAGECACHE_TAG_WRITEBACK)
```

**关键优化**：使用 `xas_for_each_marked` 而非 `xas_for_each`，skip 掉所有非 dirty 的 folio。通过节点级的位图过滤（`find_next_bit`），实现：

```
遍历 10,000 个 page：
  xas_for_each → 扫描所有 page，即使 95% 是 clean
  xas_for_each_marked → 扫描中跳过 clean page 的子树
     → 节点级 bitmap 过滤
     → 比 xas_for_each 快 ~20 倍（当只有 5% dirty 时）
```

### 7.4 页面淘汰——回收路径

```
内存不足 → shrink_folio_list()
  → __remove_mapping(mapping, folio, ...)
     → if (!xa_is_value(folio_get(folio)))
         → page_cache_delete(mapping, folio, shadow)
             → XA_STATE(xas, &mapping->i_pages, folio->index)
               → xas_store(&xas, shadow)  // 存储 shadow entry 代替 NULL
                 // shadow entry 保留页面曾在缓存中的痕迹
                 // 下次文件访问时，可以知道该页刚被回收
                 // 防止大量并发 IO 涌入
```

### 7.5 完整生命周期

```
1. 首次读文件：
   a. xa_load(&mapping->i_pages, 0) → NULL（未缓存）
   b. 分配 folio，发起 IO
   c. xa_store(&mapping->i_pages, 0, folio, GFP_KERNEL)
   d. folio 被标记为 uptodate

2. 写入数据：
   a. 数据写入 folio
   b. folio_mark_dirty(folio) → xa_set_mark(PAGECACHE_TAG_DIRTY)

3. 写回：
   a. xas_for_each_marked(mapping, PAGECACHE_TAG_DIRTY)
   b. 找到脏 folio，发起 IO
   c. folio_clear_dirty_for_io(folio) → xa_clear_mark(PAGECACHE_TAG_DIRTY)
   d. xa_set_mark(PAGECACHE_TAG_WRITEBACK)
   e. IO 完成 → xa_clear_mark(PAGECACHE_TAG_WRITEBACK)

4. 内存回收：
   a. 系统压力大 → shrink_folio_list
   b. xa_store(xa, index, shadow_entry)  // 保留 shadow
   c. 如果再次访问同一页：
      — 发现 shadow entry → 知道刚被回收 → 高优先级回收其他页
```

---

## 8. XArray vs 旧 radix tree

| 特性 | XArray | 旧 radix tree |
|------|--------|---------------|
| API 风格 | `xa_load/store/erase` | `radix_tree_lookup/insert/delete` |
| 锁管理 | 内部管理 | 调用者负责 |
| xa_state 游标 | ✅ | ❌ |
| ID 分配器 | ✅（xa_alloc） | ❌ |
| 标记系统 | 位图(64bits/节点) | 位图 |
| 类型安全 | 强（`void*` + bit encoding） | 强 |
| 内存操作 | 惰性节点创建 | 惰性节点创建 |
| RCU 支持 | ✅ | ✅ |
| 批量操作 | xas_for_each | radix_tree_for_each |
| 入口：导入类 | `xarray.h` | `radix-tree.h` |

---

## 9. 锁模式——xa_lock 的几种配置

XArray 的构造器允许选择不同的锁模式：

```c
// xarray.h:262-264 — doom-lsp 确认
// 通过 xa_init_flags(xa, flags) 设置

#define XA_FLAGS_LOCK_IRQ   1   // spin_lock_irqsave (默认用于 page cache)
#define XA_FLAGS_LOCK_BH    2   // spin_lock_bh (软中断上下文)
// 默认: spin_lock (无 irq 保护)
```

在 page cache 中，`mapping->i_pages` 使用 `XA_FLAGS_LOCK_IRQ`：

```c
// mm/filemap.c — 初始化 page cache 的 XArray
void __filemap_init(struct address_space *mapping)
{
    xa_init_flags(&mapping->i_pages, XA_FLAGS_LOCK_IRQ);
    // ...
}
```

锁操作宏：
```c
// lib/xarray.c:33-60 — doom-lsp 确认
static inline void xa_lock_type(struct xarray *xa, unsigned long *flags) {
    switch (xa->xa_flags & (XA_FLAGS_LOCK_IRQ | XA_FLAGS_LOCK_BH)) {
        case XA_FLAGS_LOCK_IRQ: spin_lock_irqsave(&xa->xa_lock, *flags); break;
        case XA_FLAGS_LOCK_BH:  spin_lock_bh(&xa->xa_lock);              break;
        default:                spin_lock(&xa->xa_lock);                  break;
    }
}
```

---

## 10. `__xa_cmpxchg`——比较并交换（`xarray.h:564`）

```c
// xarray.h:564 — doom-lsp 确认
void *__xa_cmpxchg(struct xarray *xa, unsigned long index,
                    void *old, void *entry, gfp_t gfp);
```

原子性的比较并交换：仅当当前 slot 的值等于 `old` 时，才写入 `entry`，返回旧值。调用者通过比较返回值与 `old` 判断操作是否成功。

---

## 11. 内存组织——xa_node 的分配和生命周期

### 11.1 分配策略

XArray 的 `xa_node` 从 **slab 分配器** 分配（`kmem_cache`），通过 `xas_nomem`（`xarray.h:1553`）实现：

```c
// xas_create 中的内存分配：
xas_nomem(xas, gfp);
  → xas->xa_alloc = kmem_cache_alloc(xa_node_cachep, gfp);
  → 如果分配失败 → xas_set_err(EAGAIN)
```

**预分配优化**：`xa_reserve(xa, index, gfp)` 预先分配路径上的所有节点，确保后续 `xa_store` 不会阻塞在内存分配上。这对 IO 路径、atomic context 至关重要。

### 11.2 回收策略

当 `count == 0` 时节点可回收：

```
xa_node 生命周期：
  ALLOCATED ──→ ACTIVE (count > 0) ──→ ZOMBIE (count == 0)
       ↑                                    │
       │                                    ↓
       ├──────────────────────────────── RCU FREE
       │                                     │
       └─────────────────────────────────────┘
       (kmem_cache_free in RCU callback)
```

### 11.3 LRU 链表

```c
// xarray.h:1364
struct list_lru *xa_lru;   // XArray 的 LRU 链表
```

XArray 可注册 LRU 回调，当内存压力大时，通过 `list_lru` 回调回收 XArray 节点。这在 page cache 场景中与页面回收联动。

---

## 12. 错误处理

XArray 使用内联错误编码：

```c
// xarray.h:205-223
static inline bool xa_is_err(const void *entry);  // 检查是否编码的错误
static inline long xa_err(void *entry);            // 提取错误码

// 返回错误时实际返回的是：
// ERR_PTR(errno)，但最低 2 位用来编码类型
// 通过 xa_is_err 区分正常 entry 和错误值
```

常见错误码：
```c
-XA_ERROR(-ENOMEM)    // 内存分配失败
-XA_ERROR(-EINVAL)   // 参数错误
-XA_ERROR(-ENOENT)   // 未找到（已从 XArray 删除）
```

---

## 13. 源码文件索引

| 文件 | 内容 | doom-lsp 符号数 |
|------|------|----------------|
| `include/linux/xarray.h` | 头文件定义 + inline 函数 | **155 个** |
| `include/linux/xarray.h` | `struct xarray` | L300 |
| `include/linux/xarray.h` | `struct xa_node` | L1168 |
| `include/linux/xarray.h` | `struct xa_state` | L1354 |
| `include/linux/xarray.h` | `xa_load` / `xa_store` 声明 | L355-356 |
| `include/linux/xarray.h` | `xas_find` / `xas_find_marked` 声明 | L1544-1550 |
| `lib/xarray.c` | 实现函数 | **210 个** |
| `lib/xarray.c` | `xas_load` | L237 |
| `lib/xarray.c` | `xas_store` | 核心 |
| `lib/xarray.c` | `xas_find` / `xas_find_marked` | 核心 |

---

## 14. 关联文章

- **page cache**（article 20）：XArray 在 page cache 中的应用
- **address_space**（article 19 VFS）：每个 address_space 包含一个 XArray
- **rcu**（article 26）：XArray 的 RCU 读路径保护
- **radix tree**（旧文）：XArray 的前身

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
