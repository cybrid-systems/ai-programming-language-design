# Linux Kernel xarray 可扩展基数树 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/xarray.h` + `lib/xarray.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-17 学习笔记

---

## 0. 什么是 xarray？——radix_tree 的现代化替代

**老 radix_tree 的问题**：
- 锁粒度粗（整棵树一把锁）
- 不支持标记位图（mark）
- 无法批量操作
- 内存碎片化

**xarray 的核心改进**：
- **细粒度锁**（可 RCU 降级）
- **3 个标记位**（XA_MARK_0/1/2，如 dirty/locked/writeback）
- **批量操作**（xa_erase_range 等）
- **RCU 读侧零锁**遍历
- **小索引优化**（xa_head 直接存 entry）

**全内核使用量**（Linux 7.0 源码）：
```
grep -rn "xa_load\|xa_store\|xa_erase\|DEFINE_XARRAY" --include="*.c" | wc -l  →  1426 处
```

---

## 1. 核心数据结构

### 1.1 `struct xarray` — 树根

```c
// include/linux/xarray.h:300
/*
 * 如果所有条目都是 NULL → xa_head = NULL
 * 如果只有 index 0 非 NULL → xa_head = 该 entry（直接存储，不建节点！）
 * 其他情况 → xa_head 指向 xa_node
 */
struct xarray {
    spinlock_t  xa_lock;              // 保护 xa_head
    gfp_t       xa_flags;             // XA_FLAGS_xxx 配置
    void       *xa_head;              // 指向 xa_node 或直接 entry（小索引优化）
};

// 初始化
#define XARRAY_INIT(name, flags) {                    \
    .xa_lock = __SPIN_LOCK_UNLOCKED(name.xa_lock),   \
    .xa_flags = (flags),                             \
    .xa_head = NULL }
```

### 1.2 `struct xa_node` — 内部节点

```c
// include/linux/xarray.h:1168
struct xa_node {
    unsigned char    shift;       // 每个槽位覆盖的索引位数（决定树的深度）
    unsigned char    offset;      // 本节点在父节点的哪个槽位
    unsigned char    count;       // 本节点 slots 中的非 NULL 条目数
    unsigned char    nr_values;   // 值条目数量

    struct xa_node __rcu  *parent;   // 父节点（NULL 表示根节点）
    struct xarray         *array;      // 本节点所属的 xarray

    union {
        struct list_head private_list; // 树用户私有链表
        struct rcu_head   rcu_head;    // RCU 释放用
    };

    void __rcu *slots[XA_CHUNK_SIZE];  // 槽位数组（64/4096 个槽）
    union {
        unsigned long tags[XA_MAX_MARKS][XA_MARK_LONGS];   // 标记位图
        unsigned long marks[XA_MAX_MARKS][XA_MARK_LONGS];  // 同上（别名）
    };
};
```

### 1.3 常量定义

```c
// include/linux/xarray.h:1153
#define XA_CHUNK_SHIFT  (IS_ENABLED(CONFIG_BASE_SMALL) ? 4 : 6)
// 普通配置：XA_CHUNK_SHIFT = 6 → 每节点 2^6 = 64 个槽位
// 小配置：XA_CHUNK_SHIFT = 4 → 每节点 2^4 = 16 个槽位

#define XA_CHUNK_SIZE   (1UL << XA_CHUNK_SHIFT)   // 64 或 16
#define XA_MAX_MARKS    3                          // 最多 3 个标记位

// 树的最大深度计算（64 位索引）：
// 索引 = 64 bit，每层覆盖 6 bit → 最多 64/6 ≈ 11 层
```

### 1.4 `struct xa_state` — 操作游标

```c
// include/linux/xarray.h:1351
struct xa_state {
    struct xarray     *xa;
    unsigned long      xa_index;   // 当前操作的索引
    unsigned char      xa_shift;   // 当前节点 shift 值
    unsigned char      xa_sibs;    // 多索引条目时 sibling 数量
    unsigned char      xa_offset;  // 当前在节点槽中的偏移
    struct xa_node    *xa_node;   // 当前节点（NULL 表示在根）
    struct xa_node    *xa_alloc;  // 预分配的节点
    xa_update_node_t  xa_update;  // 节点更新回调
    struct list_lru   *xa_lru;    // LRU 链表
};

// XA_STATE - 声明操作状态
#define XA_STATE(name, array, index) \
    struct xa_state name = __XA_STATE(array, index, 0, 0)
```

---

## 2. 内部条目编码（Entry Tagging）

xarray 用指针的**低位**存储额外信息（类似 rb_tree 的 `__rb_parent_color` 技巧）：

```c
// include/linux/xarray.h:149-180
// 低 2 位 = 0 → 普通指针（用户数据）
// 低 2 位 = 1 → NULL（空闲槽）
// 低 2 位 = 2 → 内部条目（node/sibling/retry/zero/error）
// 低 2 位 = 3 → （未用）

#define IS_ENABLED(CONFIG_XARRAY_MULTI) ...

// 创建内部条目（值 v 左移 2 位，置最低 2 位为 10）
static inline void *xa_mk_internal(unsigned long v)
{
    return (void *)((v << 2) | 2);
}

// 提取内部条目的值
static inline unsigned long xa_to_internal(const void *entry)
{
    return (unsigned long)entry >> 2;
}

// 判断是否是内部条目
static inline bool xa_is_internal(const void *entry)
{
    return ((unsigned long)entry & 3) == 2;
}
```

**内部条目类型**：

| 值 | 用途 | 说明 |
|----|------|------|
| 0 ~ 255 | sibling 条目 | 多索引条目时指向实际节点所在槽 |
| 256 | retry 条目 | 操作需重试 |
| 257 | zero 条目 | 表示存储过零值（与 NULL 不同）|
| > 4096 | xa_node 指针 | 节点条目 |
| < 0 | errno | 错误码（负数）|

```c
// 判断是否是 xa_node（低 2 位为 2 且值 > 4096）
static inline bool xa_is_node(const void *entry)
{
    return xa_is_internal(entry) && (unsigned long)entry > 4096;
}

// sibling 条目
static inline void *xa_mk_sibling(unsigned int offset)
{
    return xa_mk_internal(offset);  // offset << 2 | 2
}

static inline unsigned long xa_to_sibling(const void *entry)
{
    return xa_to_internal(entry);
}
```

---

## 3. 小索引优化（XA_CHUNK_SIZE 以内）

```
索引 0 ~ 511（XA_CHUNK_SIZE = 64，6 位）时的特殊处理：

xa_head 直接存储 entry，不分配 xa_node！

  index = 0         → xa_head = entry
  index = 1~63      → 需要 xa_node（shift = 6）
  index > 63        → 需要多层 xa_node

为什么这样设计？
  内核中大量使用 index = 0（如单页缓存）
  省去一次指针解引用 + 一次节点分配
```

---

## 4. 树结构图

```
三层 xarray（索引最多 18 位 = 3 × 6 bit）：

xa_head ──→ xa_node(shift=12) ──→ xa_node(shift=6) ──→ xa_node(shift=0)
  root                    middle                    leaf
  offset=?                offset=?                  offset=0~63
  slots[64]               slots[64]                 slots[64] = entries

索引分解示例（index = 0x12345）：
  高 6 bit (0x12)  → root 节点的槽号
  中 6 bit (0x34)  → middle 节点的槽号
  低 6 bit (0x45)  → leaf 节点的槽号（最终存储 entry）

xa_node.shift 含义：
  shift = 12 → 本节点每个槽覆盖 2^12 = 4096 个索引
  shift = 6  → 本节点每个槽覆盖 2^6 = 64 个索引
  shift = 0  → 叶子节点，每个槽对应 1 个索引
```

---

## 5. 核心操作

### 5.1 简单 API（推荐）

```c
// include/linux/xarray.h — 公开接口

// 初始化
void xa_init(struct xarray *xa);
void xa_init_flags(struct xarray *xa, unsigned int flags);

// 存储（gfp 指定节点分配方式）
int xa_store(struct xarray *xa, unsigned long index, void *entry, gfp_t gfp);

// 加载（RCU 安全）
void *xa_load(struct xarray *xa, unsigned long index);

// 删除
void *xa_erase(struct xarray *xa, unsigned long index);

// 范围删除
void xa_erase_range(struct xarray *, unsigned long first, unsigned long last);

// 清空
void xa_destroy(struct xarray *xa);

// 判断是否为空
bool xa_empty(struct xarray *xa);
```

### 5.2 高级 API（`xas_*` 系列）

```c
// 高级操作需要声明 xa_state 游标
XA_STATE(xas, xa, index);

// 加载
void *xas_load(struct xa_state *xas);

// 存储
void *xas_store(struct xa_state *xas, void *entry);

// 查找下一个非空槽
void *xas_find(struct xa_state *xas, unsigned long max);

// 标记操作
bool xas_get_mark(const struct xa_state *, xa_mark_t);
void xas_set_mark(const struct xa_state *, xa_mark_t);
void xas_clear_mark(const struct xa_state *, xa_mark_t);
```

### 5.3 `xas_for_each` — O(n) 遍历宏

```c
// include/linux/xarray.h:1817
#define xas_for_each(xas, entry, max) \
    for (entry = xas_find(xas, max); entry; \
         entry = xas_next_entry(xas, max))
```

**关键性质**：
- `xas_for_each` = **O(n)**（线性遍历）
- `xa_for_each` = O(n·log n)（每次调用 `xa_find` 是 O(log n)）

### 5.4 标记（Mark）系统

```c
// include/linux/xarray.h:255
#define XA_MARK_0     ((__force xa_mark_t)0U)  // 通常 = XA_FREE_MARK
#define XA_MARK_1     ((__force xa_mark_t)1U)
#define XA_MARK_2     ((__force xa_mark_t)2U)
#define XA_PRESENT     ((__force xa_mark_t)8U)  // 槽中有值

// 常用预定义
#define XA_FREE_MARK  XA_MARK_0  // 空闲追踪
```

**标记位图**：每个 xa_node 有 3 个 `unsigned long[]` 数组（XA_MARK_LONGS = XA_CHUNK_SIZE/64 = 1），所以每个 mark 只有 1 个 bit。

---

## 6. 存储算法（`xas_store`）核心流程

```c
// lib/xarray.c:783
void *xas_store(struct xa_state *xas, void *entry)
{
    struct xa_node *node;
    void __rcu **slot = &xas->xa->xa_head;  // 从根开始
    unsigned int offset, max;
    int count = 0;
    int values = 0;

    // 1. 如果 index 在小索引范围，直接存 xa_head
    if (xas->xa_index < XA_CHUNK_SIZE) {
        // 直接存储到 xa_head
    }

    // 2. 逐层下沉（xas_descend）
    //    每次判断 xa_is_sibling 跳过 sibling 条目
    //    必要时分配新的 xa_node

    // 3. 在叶子节点的 slot 中存储 entry

    // 4. 如果 slot 中出现空槽 → 更新 count
    //    如果 count = 0 → 触发节点释放（xas_delete_node）

    // 5. 返回旧 entry
}
```

---

## 7. vs radix_tree / rbtree

| 特性 | radix_tree | **xarray** | rbtree |
|------|-----------|------------|--------|
| 索引范围 | 最多 32 bit | **64 bit** | 任意 key |
| 遍历复杂度 | O(n·log n) | **O(n)（xas_for_each）** | O(n) |
| 标记支持 | 无 | **3 个 mark 位** | 无 |
| 锁粒度 | 粗粒度 | **细粒度 + RCU** | 粗粒度 |
| 小索引优化 | 无 | **xa_head 直接存** | N/A |
| 批量操作 | 无 | **xa_erase_range** | 无 |
| 节点分配 | 每次插入分配 | **按需分配** | 每次插入分配 |
| 典型场景 | 旧 page cache | **page cache、idr、内存管理** | CFS 调度、vma |

---

## 8. 真实内核使用案例

### 8.1 页面缓存（`mm/filemap.c`）

```c
// include/linux/fs.h:475
struct address_space {
    struct xarray     i_pages;     // 页缓存 xarray
    // ...
};

// 使用示例（mm/filemap.c:132）
XA_STATE(xas, &mapping->i_pages, folio->index);

// 存储 folio 到指定 index
xas_store(&xas, folio);

// 加载
struct folio *folio = xas_load(&xas);

// 遍历所有缓存页
xa_lock_irq(&mapping->i_pages);
xa_for_each(&mapping->i_pages, index, folio) {
    // 处理每个 folio
}
xa_unlock_irq(&mapping->i_pages);
```

### 8.2 IDR（整数 ID 映射）

```c
// include/linux/idr.h — idr 底层仍用 radix_tree（但 wrapper 逐渐迁移）
struct idr {
    struct radix_tree_root idr_rt;
    unsigned int           idr_base;
    unsigned int           idr_next;
};

// idr 常用接口（逐渐迁移到 xarray）
int idr_alloc(struct idr *, void *, int start, int end, gfp_t);
void *idr_find(const struct idr *, unsigned long id);
void idr_remove(struct idr *, unsigned long id);
```

---

## 9. 算法复杂度分析

| 操作 | 时间复杂度 | 说明 |
|------|----------|------|
| `xa_init` | O(1) | 只需清零 |
| `xa_load` | O(log n) | 树高，每层 O(1) |
| `xa_store` | O(log n) | 查找 + 可能分配节点 |
| `xa_erase` | O(log n) | 查找 + 可能释放节点 |
| `xas_for_each` | **O(n)** | 线性遍历，无重复查找 |
| `xa_erase_range` | O(log n + n) | 批量删除优化 |
| 小索引（< 64） | **O(1)** | xa_head 直接操作 |

---

## 10. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| 低 2 位 tagging | 用指针的未使用位存储元信息，零额外开销 |
| xa_head 直接存储（小索引） | 节省指针解引用 + 节点分配，适用于缓存场景 |
| xa_state 游标 | 避免每次操作重新从根遍历，支持断点续操作 |
| 多层 64 槽节点 | 平衡节点大小与树深度（64^11 > 2^64） |
| 3 个 mark 位 | 满足大多数标记需求（dirty/locked/writeback） |
| xas_for_each O(n) | 内部节点缓存当前路径，无需每次重新查找 |

---

## 11. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/xarray.h` | 公开 API、结构体定义、宏 |
| `include/linux/xarray.h:1168` | `struct xa_node` 完整定义 |
| `include/linux/xarray.h:1351` | `struct xa_state` 定义 |
| `include/linux/xarray.h:1817` | `xas_for_each` 宏 |
| `lib/xarray.c` | `xas_store`、`xas_load`、`xas_descend` 实现 |
| `include/linux/fs.h:475` | `address_space.i_pages` 使用 |
| `mm/filemap.c:132` | folio 页面缓存操作示例 |

---

## 附录：doom-lsp 分析记录

```
include/linux/xarray.h — 155 symbols：
  xa_mk_value, xa_to_value, xa_is_value @ 58
  xa_tag_pointer, xa_untag_pointer @ 101
  struct xa_limit @ 243
  struct xarray @ 300
  xa_load @ 355, xa_store @ 356, xa_erase @ 357
  xa_get_mark, xa_set_mark, xa_clear_mark @ 360
  xa_find, xa_find_after @ 363
  xa_destroy @ 369
  struct xa_node @ 1168
  XA_STATE @ 1384

lib/xarray.c — 210 symbols：
  xas_load @ 237, xas_store @ 783
  xas_descend @ 204 (节点下沉算法)
  xas_create @ 647
  xas_delete_node @ 489
  xa_mark_set, xa_mark_clear @ 68
  xas_for_each @ (inline via xas_find + xas_next_entry)
```
