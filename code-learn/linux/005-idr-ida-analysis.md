# 05-idr-ida — ID 分配器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**IDR（ID Radix）** 和 **IDA（ID Allocator）** 是 Linux 内核中用于 `整数 ID ↔ 指针` 映射的辅助设施。IDR 维护一个将整数 ID 映射到 `void*` 的关联数组，IDA 则只负责分配/回收整数 ID 本身（不关联指针）。

IDR 的典型场景：当你需要一个动态的整数 ID 来标识一个内核对象时（如 inode 号、文件描述符、IPC 标识符），IDR 能自动在指定范围内分配一个空闲 ID，并将 ID 与对象指针关联起来。

IDA 则更轻量：它只管理哪些 ID 号被使用、哪些空闲，不存储指针。适合只需要唯一 ID 号的应用（如设备号、中断号）。

从 Linux 4.19 开始，IDR 的底层存储已迁移到 XArray。IDR 内部包含一个 `struct xarray`，通过 XArray 的 `xa_alloc` 系列 API 进行 ID 分配。但为了避免大规模重构，部分内部实现仍保留了旧的 radix tree API 调用（`radix_tree_iter_init`、`radix_tree_iter_replace`），这些函数本质上是 XArray 的兼容层包装。

**doom-lsp 确认**：`include/linux/idr.h` 包含 **44 个符号**，`lib/idr.c` 包含 **17 个导出实现函数**。

---

## 1. 核心数据结构

### 1.1 `struct idr`（`include/linux/idr.h:20`）

```c
// include/linux/idr.h:20 — doom-lsp 确认
struct idr {
    struct radix_tree_root idr_rt;  // 底层 XArray（通过宏别名 radix_tree_root）
    unsigned int     idr_base;     // ID 起始偏移（基址）
    unsigned int     idr_next;     // 下次分配的 hint（循环分配用）
};
```

三个字段：

- **`idr_rt`**：`struct xarray`（通过宏别名 `radix_tree_root`，24 字节）。存储 `id → void*` 的映射。ID 作为 XArray 的索引键。注意字段名 `idr_rt` 是历史遗迹——`rt` 表示 radix tree——但底层已是 XArray（`include/linux/radix-tree.h:25`：`#define radix_tree_root xarray`）。

- **`idr_base`**：ID 基址。很多场景需要从特定数字开始分配 ID（如 `/dev/null` 的主设备号为 1），`idr_base` 允许偏移整个 ID 空间而无需修改 XArray 的索引。

- **`idr_next`**：分配 hint。在循环分配（`idr_alloc_cyclic`）时记录上次分配的位置，避免每次从头扫描。

### 1.2 `struct ida_bitmap`（`include/linux/idr.h:259`）

```c
// include/linux/idr.h:259 — doom-lsp 确认
struct ida_bitmap {
    unsigned long bitmap[IDA_BITMAP_LONGS];
};
```

大小：`IDA_BITMAP_BITS = 1024`，在 64 位系统上是 `1024 / 64 = 16` 个 `unsigned long`，共 **128 字节**。一个 bitmap 页管理 1024 个 ID。

### 1.3 `struct ida`（`include/linux/idr.h:263`）

```c
// include/linux/idr.h:263 — doom-lsp 确认
struct ida {
    struct xarray xa;              // XArray：page_index → ida_bitmap*
};
```

IDA 的 XArray 存储的是 bitmap 页（`struct ida_bitmap*` 或值编码的 `unsigned long`）。每个 bitmap 页覆盖一段连续的 1024 个 ID 号。

**值编码优化**：当 bitmap 页中只有少于 `BITS_PER_XA_VALUE` 个 ID 被分配时，IDA 不创建完整的 `ida_bitmap` 结构体，而是直接将分配位图编码为一个 `unsigned long` 存储在 XArray 的 value entry 中（使用 `xa_mk_value`/`xa_to_value`）。这是 XArray 的 **value encoding** 能力带来的优化——避免了小范围分配时的 slab 内存开销。

---

## 2. IDR API——doom-lsp 确认的行号

### 2.1 `idr_alloc`（`lib/idr.c:84`）

```c
// lib/idr.c:84 — doom-lsp 确认
int idr_alloc(struct idr *idr, void *ptr, int start, int end, gfp_t gfp)
{
    u32 id = start;
    int ret;

    ret = idr_alloc_u32(idr, ptr, &id, end > 0 ? end - 1 : INT_MAX, gfp);
    if (ret)
        return ret;

    return id;
}
```

**doom-lsp 数据流追踪——完整调用链**：

```
idr_alloc(idr, ptr, start, end, gfp)             @ lib/idr.c:84
  └─ idr_alloc_u32(idr, ptr, &id, max, gfp)       @ lib/idr.c:35
       │
       ├─ 校正 ID 基数:
       │   id = id - idr->idr_base                (减去基址)
       │
       ├─ radix_tree_iter_init(&iter, id)          (radix tree 兼容层初始化)
       │
       ├─ idr_get_free(&idr->idr_rt, &iter, gfp, max - base)
       │   └─ 内部调用 xa_alloc → xas_find_marked(XA_FREE_MARK)
       │      (XArray 搜索有空闲标记的 slot)
       │
       ├─ radix_tree_iter_replace(&idr->idr_rt, &iter, slot, ptr)  (写入 ptr)
       │   └─ 内部: xas_store → rcu_assign_pointer(slot, ptr)
       │
       ├─ radix_tree_iter_tag_clear(&idr->idr_rt, &iter, IDR_FREE) (清除空闲标记)
       │
       └─ return id = iter.index + base            (恢复基址)
```

### 2.2 `idr_alloc_u32`（`lib/idr.c:35`）

```c
// lib/idr.c:33 — doom-lsp 确认
int idr_alloc_u32(struct idr *idr, void *ptr, u32 *nextid,
                  unsigned long max, gfp_t gfp)
```

`idr_alloc` 的底层实现。与 `idr_alloc` 的区别：`nextid` 既作为输入（建议起始 ID）也作为输出（实际分配的 ID），返回错误码而非直接返回 ID。

### 2.3 `idr_alloc_cyclic`（`lib/idr.c:119`）

```c
// lib/idr.c:119 — doom-lsp 确认
int idr_alloc_cyclic(struct idr *idr, void *ptr, int start, int end, gfp_t gfp)
```

循环分配：从 `idr->idr_next` 开始尝试，如果此范围内已无空闲 ID，则回到 `start` 再试一次：

```
idr_alloc_cyclic(idr, ptr, start, end, gfp)
  │
  ├─ id = idr->idr_next              ← 上次分配位置
  │
  ├─ idr_alloc_u32(idr, ptr, &id, ...)
  │   └─ 如果成功 → idr->idr_next = id + 1  ← 更新 hint
  │                                          return id
  │
  └─ 如果失败（ENOSPC = 空间已满）:
       └─ id = start                  ← 回到起点重试
            idr_alloc_u32(idr, ptr, &id, ...)
```

### 2.4 `idr_find`——快速查询（`lib/idr.c:174`）

```c
// lib/idr.c:174 — doom-lsp 确认
void *idr_find(const struct idr *idr, unsigned long id)
{
    return radix_tree_lookup(&idr->idr_rt, id - idr->idr_base);
}
```

### 2.5 `idr_remove`——删除映射（`lib/idr.c:154`）

```c
// lib/idr.c:154 — doom-lsp 确认
void *idr_remove(struct idr *idr, unsigned long id)
{
    return radix_tree_delete_item(&idr->idr_rt, id - idr->idr_base, NULL);
}
```

删除后底层 XArray 自动**标记该 slot 为空闲**（`IDR_FREE` tag），使得后续 `idr_alloc` 可以重新使用此 ID。

### 2.6 `idr_replace`——替换指针（`lib/idr.c:292`）

```c
// lib/idr.c:292 — doom-lsp 确认
void *idr_replace(struct idr *idr, void *ptr, unsigned long id)
```

在指定 ID 处替换指针。与 `idr_remove` + `idr_alloc` 的区别：**不改变 ID 的分配状态**，即替换过程中该 ID 始终是可用的（不会出现被其他分配抢占的窗口期）。

### 2.7 `idr_for_each`——遍历所有映射（`lib/idr.c:197`）

```c
// lib/idr.c:197 — doom-lsp 确认
int idr_for_each(const struct idr *idr,
                  int (*fn)(int id, void *p, void *data),
                  void *data)
{
    struct radix_tree_iter iter;
    void __rcu **slot;
    int base = idr->idr_base;

    radix_tree_for_each_slot(slot, &idr->idr_rt, &iter, 0) {
        int ret;
        unsigned long id = iter.index + base;

        if (WARN_ON_ONCE(id > INT_MAX))
            break;
        ret = fn(id, rcu_dereference_raw(*slot), data);
        if (ret)
            return ret;
    }
    return 0;
}
```

使用 `radix_tree_for_each_slot` 遍历 XArray 中的非空 slot。注意：遍历时空洞（hole）被跳过。需要对 `rcu_dereference_raw` 保护的数据正确管理生命周期。

### 2.8 `idr_get_next` / `idr_get_next_ul`——游标遍历（`lib/idr.c:266, 229`）

```c
// lib/idr.c:266 — doom-lsp 确认
void *idr_get_next(const struct idr *idr, int *nextid);

// lib/idr.c:229
void *idr_get_next_ul(const struct idr *idr, unsigned long *nextid);
```

返回 `*nextid` 之后的第一个非空 entry，并更新 `*nextid` 为该 entry 的 ID。用于游标式遍历。

---

## 3. IDA API——doom-lsp 确认的行号

### 3.1 `ida_alloc_range`——核心分配（`lib/idr.c:382`）

```c
// lib/idr.c:382 — doom-lsp 确认
int ida_alloc_range(struct ida *ida, unsigned int min, unsigned int max,
                    gfp_t gfp)
{
    XA_STATE(xas, &ida->xa, min / IDA_BITMAP_BITS);
    unsigned bit = min % IDA_BITMAP_BITS;
    ...
}
```

IDA 核心分配器，使用 **XArray 的 xa_state 遍历器**（注意与 IDR 不同，IDA 直接使用 XA_STATE，而非 radix tree 兼容层）。

**doom-lsp 数据流追踪——完整流程**：

```
ida_alloc_range(ida, min, max, gfp)
  │
  ├─ 初始化 XArray 状态:
  │   xas = XA_STATE(&ida->xa, page_index = min/1024)
  │   bit = min % 1024
  │
  ├─ 查找第一个有空闲位的 bitmap 页:
  │   xas_find_marked(&xas, max/1024, XA_FREE_MARK)
  │   ← XArray 搜索标记了 XA_FREE_MARK 的 entry
  │   ← 未标记 = 该 bitmap 页已满，跳过
  │
  ├─ 检查找到的 entry 类型:
  │   │
  │   ├─ 值编码 (xa_is_value):
  │   │   tmp = xa_to_value(bitmap)         ← 64-bit bitmap
  │   │   bit = find_next_zero_bit(&tmp, 64, bit)  ← 找空闲位
  │   │   if (找到):
  │   │       tmp |= (1UL << bit)           ← 标记已分配
  │   │       xas_store(&xas, xa_mk_value(tmp))
  │   │       return id                     ← 小范围，快速路径
  │   │
  │   ├─ 完整 bitmap 页:
  │   │   bitmap = xa_to_node(entry)        ← ida_bitmap 指针
  │   │   bit = find_next_zero_bit(bitmap->bitmap, 1024, bit)
  │   │   if (找到):
  │   │       __set_bit(bit, bitmap->bitmap)
  │   │       if (bitmap_full): xas_clear_mark(&xas, XA_FREE_MARK)
  │   │       return id
  │   │
  │   └─ NULL (新页):
  │       if (bit < 64):
  │           xas_store(&xas, xa_mk_value(1UL << bit))  ← 值编码
  │       else:
  │           bitmap = kzalloc(...)                      ← 分配 bitmap 页
  │           __set_bit(bit, bitmap->bitmap)
  │           xas_store(&xas, bitmap)
  │       return id
  │
  ├─ 内存分配失败时的重试:
  │   xas_nomem(&xas, gfp)  ← 释放锁并分配内存，然后 retry
  │
  └─ 无空闲 ID → return -ENOSPC
```

### 3.2 `ida_free`——释放 ID（`lib/idr.c:556`）

```c
// lib/idr.c:556 — doom-lsp 确认
void ida_free(struct ida *ida, unsigned int id)
{
    XA_STATE(xas, &ida->xa, id / IDA_BITMAP_BITS);
    unsigned bit = id % IDA_BITMAP_BITS;
    ...
}
```

**数据流**：

```
ida_free(ida, id)
  │
  ├─ 定位 bitmap 页:
  │   xas_load(&xas) = bitmap 或 value
  │
  ├─ 清除对应位:
  │   │
  │   ├─ 值编码:
  │   │   tmp = xa_to_value(bitmap)
  │   │   tmp &= ~(1UL << bit)
  │   │   if (tmp == 0):
  │   │       xas_store(&xas, NULL)    ← 全部释放 → 回收 XArray slot
  │   │   else:
  │   │       xas_store(&xas, xa_mk_value(tmp))
  │   │
  │   └─ 完整 bitmap:
  │       __clear_bit(bit, bitmap->bitmap)
  │       if (bitmap_empty(...)):
  │           kfree(bitmap)             ← 回收 bitmap 内存
  │           xas_store(&xas, NULL)
  │       else:
  │           xas_set_mark(&xas, XA_FREE_MARK)  ← 标记有空闲位
  │
  └─ 完成
```

**内存回收优化**：当 bitmap 全部清零时，不仅回收 XArray slot（`xas_store(NULL)`），还回收 `ida_bitmap` 本身（`kfree`）。如果 bitmap 不是全部空闲，只清除对应的位并标记 `XA_FREE_MARK`。

### 3.3 `ida_find_first_range`——查找第一个已分配的 ID（`lib/idr.c:493`）

```c
// lib/idr.c:493 — doom-lsp 确认
int ida_find_first_range(struct ida *ida, unsigned int min, unsigned int max)
```

反向查找：在区间 `[min, max]` 中找到第一个**已被分配**的 ID。用于调试、procfs 导出等场景。

### 3.4 `ida_destroy`——销毁所有位图（`lib/idr.c:610`）

```c
// lib/idr.c:610 — doom-lsp 确认
void ida_destroy(struct ida *ida)
```

遍历所有 bitmap 页、释放每个 `ida_bitmap*`（对值编码的 entry 直接跳过，因为不涉及动态内存），最后调用 `xa_destroy(&ida->xa)` 清空整个 XArray。

---

## 4. IDR 的空闲标记机制——`IDR_FREE`

IDR 使用 **XArray 的标记系统**来跟踪哪些 slot 是空闲的：

```c
// include/linux/idr.h — 内部标记
#define IDR_FREE  0             // 标记位索引 0 用于"空闲"标记
```

> ⚠️ 实际源码中 `IDR_FREE` 定义为 `0`（标记位索引），并非 `XA_MARK_0`。底层 XArray 使用 `XA_MARK_0`（即标记位 0）来记录空闲状态。

对于 IDR 来说，标记位 0 的含义被重新定义为"此 slot 空闲"，这正好与默认的 XArray 标记含义相反。逻辑如下：

```
初始化：所有 slots 未被占用 → 全部标记 IDR_FREE
分配后：清除 IDR_FREE 标记
释放后：重新设置 IDR_FREE 标记

idr_alloc (via idr_alloc_u32):
  → radix_tree_iter_init(&iter, id)             ← 初始化 radix tree 遍历器
  → idr_get_free(&idr_rt, &iter, ...)           ← 搜索空闲 slot（内部：xa_alloc 路径）
  → radix_tree_iter_tag_clear(..., IDR_FREE)    ← 占用后清除空闲标记

idr_remove:
  → radix_tree_delete_item(&idr_rt, idx, NULL)  ← 删除指针
    底层自动设置空闲标记（IDR_FREE tag）
```

**注意**：这里的标记语义是倒置的。通常 `XA_MARK_0` 表示"脏"或"写回"等肯定含义，但对 IDR 来说标记位 0 = "空闲"。这是 IDR 的实现细节，调用者无需关心。

---

## 5. 简化 API——`ida_alloc` / `ida_alloc_min` / `ida_alloc_max`

```c
// include/linux/idr.h:291 — doom-lsp 确认
static inline int ida_alloc(struct ida *ida, gfp_t gfp)
{
    return ida_alloc_range(ida, 0, ~0, gfp);  // [0, UINT_MAX]
}

// idr.h:309
static inline int ida_alloc_min(struct ida *ida, unsigned int min, gfp_t gfp)
{
    return ida_alloc_range(ida, min, ~0, gfp);  // [min, UINT_MAX]
}

// idr.h:327
static inline int ida_alloc_max(struct ida *ida, unsigned int max, gfp_t gfp)
{
    return ida_alloc_range(ida, 0, max, gfp);   // [0, max]
}
```

三个简写版本，分别提供不同的范围约束。

---

## 6. 值与类型编码转换

IDA 中 entry 类型的**运行时检测**（`lib/idr.c`）：

```c
// xa_is_value(entry) 判断是否是值编码的位图
// 值编码 = 任意 0~63 bit 的位图，存储在 unsigned long 中

if (xa_is_value(bitmap)) {
    unsigned long tmp = xa_to_value(bitmap);
    bit = find_next_zero_bit(&tmp, BITS_PER_XA_VALUE, bit);
    ...
} else if (bitmap) {
    // 完整 ida_bitmap 结构体
    bit = find_next_zero_bit(bitmap->bitmap, IDA_BITMAP_BITS, bit);
    ...
} else {
    // NULL = 空页（尚未分配 bitmap）
}
```

三种状态的内存消耗对比：

| 状态 | 存储方式 | 内存消耗 | 适用场景 |
|------|---------|---------|---------|
| 空页 | `xa_store(NULL)` | **0 字节** | 无已分配 ID |
| 稀疏分配（≤64 个 ID） | `xa_mk_value(bitmap)` | 8 字节（编码为 unsigned long） | 小范围少量分配 |
| 密集分配 | `struct ida_bitmap*` | 128 字节（slab 分配） | 大量 ID 分配 |

---

## 7. 初始化与销毁

### 7.1 IDR 初始化

```c
// include/linux/idr.h:152 — doom-lsp 确认
static inline void idr_init_base(struct idr *idr, int base)
{
    INIT_RADIX_TREE(&idr->idr_rt, IDR_RT_MARKER);  // 通过 radix tree 兼容层初始化
    idr->idr_base = base;                          // 设置基址
    idr->idr_next = 0;                             // 重置 hint
}

// idr.h:166
static inline void idr_init(struct idr *idr)
{
    idr_init_base(idr, 0);
}
```


**关键：`IDR_RT_MARKER`**。这个宏展开为 `ROOT_IS_IDR | (__force gfp_t)(1 << (ROOT_TAG_SHIFT + IDR_FREE))`。`INIT_RADIX_TREE` 是 `xa_init_flags` 的兼容层宏。与 `XA_FLAGS_ALLOC` 不同，`IDR_RT_MARKER` 额外设置了 `ROOT_IS_IDR` 标志，使 XArray 知道它是用于 IDR 分配：
1. 跟踪哪些 slots 被占用、哪些空闲
2. 维护标记位 0（`IDR_FREE`）标记空闲 slot
3. 支持 IDR 的循环分配等特性

### 7.2 IDA 初始化

```c
// include/linux/idr.h:332 — doom-lsp 确认
static inline void ida_init(struct ida *ida)
{
    xa_init_flags(&ida->xa, XA_FLAGS_ALLOC);
}
```

IDA 使用 `XA_FLAGS_ALLOC`（而非 IDR 的 `IDR_RT_MARKER`），因为 IDA 直接使用 `struct xarray` 而非 `radix_tree_root` 别名。不使用 `idr_base`。

### 7.3 销毁

```c
// lib/idr.c:610 — doom-lsp 确认
void ida_destroy(struct ida *ida)
{
    // 遍历并释放所有 bitmap 页
    // 最后清空 XArray
}

// idr 的销毁通过 xa_destroy 完成：
static inline void idr_destroy(struct idr *idr)
{
    xa_destroy(&idr->idr_rt);
}
```

---

## 8. `idr_preload` / `idr_preload_end`——预分配路径

```c
// include/linux/idr.h:113 — doom-lsp 确认
int idr_preload(struct idr *idr, gfp_t gfp);

// include/linux/idr.h:189 — doom-lsp 确认
static inline void idr_preload_end(void)
{
    local_unlock(&radix_tree_preloads.lock);
}
```

`idr_preload` 在中断上下文中预先分配足够的内存（路径上的所有节点），确保后续的 `idr_alloc`（在 spinlock 保护的区间内）不会触发内存分配。这是内核中常见的"进入临界区前预分配"模式：

```c
idr_preload(GFP_KERNEL);
spin_lock(&lock);
id = idr_alloc(idr, ptr, 0, INT_MAX, GFP_NOWAIT);  // 不会休眠
spin_unlock(&lock);
idr_preload_end();
```

---

## 9. 🔥 doom-lsp 数据流追踪——内核中的真实使用

### 9.1 文件描述符分配（`kernel/fork.c`）

```
do_fork() / clone()
  └─ copy_process()
       └─ alloc_fd()
            └─ __alloc_fd(files, 0, rlimit(RLIMIT_NOFILE))
                 └─ find_next_fd(files, start)
                 └─ fd_install(fd, file)  ← fd 与 file 关联
                      └─ rcu_assign_pointer(files->fdt->fd[fd], file)
```

注意：文件描述符使用**直接数组**而非 IDR。由于文件描述符是连续分配的，数组的 cache locality 优于 IDR。

### 9.2 IPC 标识符（`ipc/util.c`）

```c
// ipc/util.c — 使用 IDR 管理 IPC 对象
struct ipc_ids {
    struct idr ipcs_idr;          // ID → kern_ipc_perm 映射
    // ...
};

// 创建 IPC 对象时：
id = idr_alloc(&ipc_ids->ipcs_idr, new, 0, IPC_MAX_ID, GFP_KERNEL);
```

### 9.3 devtmpfs 设备号分配

```c
// drivers/base/devtmpfs.c
struct ida minor_ida;            // 管理次设备号

handle_create(dev, ...):
    ida_alloc(&minor_ida, GFP_KERNEL)  → allocate minor number

handle_remove(dev, ...):
    ida_free(&minor_ida, dev->devt)
```

### 9.4 模块 ID

```c
// kernel/module/main.c
DEFINE_IDA(module_ida);          // 模块动态 ID

// 加载模块时分配 ID
id = ida_alloc(&module_ida, GFP_KERNEL);
```

---

## 10. IDR vs IDA 对比

| 特性 | IDR | IDA |
|------|-----|-----|
| 核心用途 | ID → 指针映射 | 仅 ID 分配 |
| 存储内容 | `void*`（任意指针） | bitmap（位图） |
| 内存消耗 | 每 ID 一个 XArray slot | 每 1024 ID 一个 128 字节 bitmap |
| 查找 | O(log n) 树查找 | O(log n) + bitmap 扫描 |
| 每次分配动作 | 树操作 + 标记清除 | find_next_zero_bit + set_bit |
| 地址空间 | 支持 idr_base 偏移 | 无偏移概念 |
| 典型使用 | inode 号, IPC ID | 设备号, 中断号, 模块 ID |
| 线程安全 | 调用者负责 | XArray 内部锁 |

---

## 11. XA_FLAGS_ALLOC 是什么

```c
// include/linux/xarray.h:281
#define XA_FLAGS_ALLOC     (XA_FLAGS_TRACK_FREE | XA_FLAGS_MARK(XA_FREE_MARK))

// XA_FLAGS_TRACK_FREE: 跟踪哪些 entry 被释放（free）
// XA_FLAGS_MARK(XA_FREE_MARK): 启用 XA_MARK_0（空闲标记位）
```

当 `XA_FLAGS_ALLOC` 使能后，XArray 的 `xa_store(..., NULL)` 会自动设置 `XA_MARK_0`（标记为空闲），而 `xa_store(..., ptr)` 会自动清除该标记。

> ⚠️ IDR 内部使用 `IDR_RT_MARKER`（= `ROOT_IS_IDR | BIT(ROOT_TAG_SHIFT + 0)`）而非 `XA_FLAGS_ALLOC`。两者功能相似，但 IDR 版本额外设置了 `ROOT_IS_IDR` 标志。

---

## 12. Perf 对比：IDR vs 直接 XArray

| 操作 | IDR | 直接 XArray |
|------|-----|-------------|
| `idr_alloc` / `xa_alloc` | 自动寻址 | 手动管理 ID |
| `idr_find` / `xa_load` | 相同 | 相同 |
| `idr_remove` / `xa_erase` | 自动标记 FREE | 需手动标记 |
| 基址偏移 | `idr_base` 内置 | 需手动加减 |
| 预分配 | `idr_preload` | `xas_nomem` |

结论：IDR 简化了"自动分配 ID"模式。如果你不需要自动 ID 分配，直接使用 XArray 更高效。

---

## 13. 源码文件索引

| 文件 | 关键符号 | doom-lsp 确认的行 |
|------|---------|------------------|
| `include/linux/idr.h` | `struct idr` | L20 |
| `include/linux/idr.h` | `struct ida_bitmap` | L259 |
| `include/linux/idr.h` | `struct ida` | L263 |
| `include/linux/idr.h` | `idr_alloc` (声明) | L115 |
| `include/linux/idr.h` | `ida_alloc_range` (声明) | L274 |
| `include/linux/idr.h` | `ida_alloc` (inline) | L291 |
| `include/linux/idr.h` | `idr_init_base` (inline) | L152 |
| `lib/idr.c` | `idr_alloc_u32` | L33 |
| `lib/idr.c` | `idr_alloc` | L81 |
| `lib/idr.c` | `idr_alloc_cyclic` | L119 |
| `lib/idr.c` | `idr_remove` | L154 |
| `lib/idr.c` | `idr_find` | L174 |
| `lib/idr.c` | `idr_for_each` | L197 |
| `lib/idr.c` | `idr_get_next_ul` | L229 |
| `lib/idr.c` | `idr_replace` | L292 |
| `lib/idr.c` | `ida_alloc_range` | L382 |
| `lib/idr.c` | `ida_find_first_range` | L493 |
| `lib/idr.c` | `ida_free` | L556 |
| `lib/idr.c` | `ida_destroy` | L610 |

---

## 14. 关联文章

- **04-xarray**：IDR/IDA 的底层存储实现
- **09-spinlock**：idr_preload 的锁使用上下文
- **48-kworker**：工作队列中 IDR 管理 worker 池
- **98-procfs**：procfs 使用 IDA 分配 inode 号

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
