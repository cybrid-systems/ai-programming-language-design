# Linux Kernel idr / ida 整数 ID 映射器 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/idr.h` + `lib/idr.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-18 学习笔记

---

## 0. 什么是 idr / ida？

**idr（ID to pointer）**：整数 ID → 指针的映射，需要通过 ID 找到对应的结构体。

**ida（ID Allocator）**：纯整数 ID 分配器，只分配唯一整数，不存指针，内存极省。

| 特性 | idr | ida |
|------|-----|-----|
| 存储内容 | ID → 指针 | 只记录已分配 ID（位图） |
| 内存占用 | 较高（存指针） | **极低（1 bit/ID）** |
| 典型场景 | pid→task_struct、fd→file | minor 号、端口号 |
| 底层 | radix_tree（Linux 7.0） | **xarray** |

**注意**：Linux 7.0 源码中 `idr` 仍使用 `radix_tree`，但 `ida` 已完全基于 `xarray` 实现。

---

## 1. 核心数据结构

### 1.1 `struct idr`

```c
// include/linux/idr.h:20
struct idr {
    struct radix_tree_root  idr_rt;   // 底层 radix_tree
    unsigned int           idr_base;  // ID 起始值（通常为 0）
    unsigned int           idr_next;  // 下一个待分配 ID（用于 idr_alloc_cyclic）
};

#define DEFINE_IDR(name) struct idr name = {               \
    .idr_rt = RADIX_TREE_INIT(name.idr_rt, IDR_RT_MARKER), \
    .idr_base = 0,                                         \
    .idr_next = 0,                                         \
}
```

### 1.2 `struct ida`

```c
// include/linux/idr.h:255-265
#define IDA_CHUNK_SIZE   128     // 每个 bitmap chunk 128 字节
#define IDA_BITMAP_LONGS (IDA_CHUNK_SIZE / sizeof(long))  // 16 个 long（64位 = 1024 bits）
#define IDA_BITMAP_BITS  (IDA_BITMAP_LONGS * sizeof(long) * 8)  // 1024 bits

struct ida_bitmap {
    unsigned long bitmap[IDA_BITMAP_LONGS];  // 1024 bits
};

struct ida {
    struct xarray xa;  // 底层基于 xarray
};

// 每个 bitmap 占 128 字节，记录 1024 个 ID 的分配状态
// 未分配 bit = 0，已分配 bit = 1
```

### 1.3 位图工作原理（ida）

```
IDA 分配原理（每个 bitmap = 1024 bits = 128 bytes）：

bitmap[0] = 0b0000000000000000000000000000000000000000000000000000000000000001
             ↑ bit 0 已分配（ID = 0）

bitmap[0] = 0b0000000000000000000000000000000000000000000000000000000000000011
             ↑ bit 0 和 bit 1 已分配（ID = 0, 1）

xa_array:
  index = 0       → NULL（bitmap = NULL）
  index = 1       → NULL
  index = 2       → ida_bitmap{bitmap = 0b...00100}（ID=2 已分配）
  index = 1024    → 新的 ida_bitmap

分配 ID = 扫描 bitmap 找第一个 0 bit
释放 ID = 将对应 bit 置 0
```

---

## 2. idr API 详解

### 2.1 `idr_alloc` — 分配 ID 并存入指针

```c
// lib/idr.c:81
int idr_alloc(struct idr *idr, void *ptr, int start, int end, gfp_t gfp)
{
    u32 id = start;
    int ret;

    if (WARN_ON_ONCE(start < 0))
        return -EINVAL;

    // 核心：调用 radix_tree_insert
    ret = idr_alloc_u32(idr, ptr, &id, end > 0 ? end - 1 : INT_MAX, gfp);
    if (ret < 0)
        return ret;
    return id;
}
```

### 2.2 `idr_find` — 通过 ID 查找指针

```c
// lib/idr.c:174
void *idr_find(const struct idr *idr, int id)
{
    return radix_tree_lookup(&idr->idr_rt, id - idr->idr_base);
}
```

### 2.3 `idr_remove` — 删除 ID

```c
// lib/idr.c:154
void idr_remove(struct idr *idr, int id)
{
    radix_tree_delete(&idr->idr_rt, id - idr->idr_base);
}
```

### 2.4 `idr_for_each` — 遍历所有已分配 ID

```c
// lib/idr.c:197
#define idr_for_each(idr, function, data) \
    radix_tree_for_each(function, data, &(idr)->idr_rt)
```

---

## 3. ida API 详解

### 3.1 `ida_alloc` — 分配新 ID

```c
// include/linux/idr.h:291 — 声明
int ida_alloc(struct ida *ida, gfp_t gfp);
int ida_alloc_min(struct ida *ida, unsigned int min, gfp_t gfp);
int ida_alloc_range(struct ida *ida, unsigned int min, unsigned int max, gfp_t gfp);

// lib/idr.c:382 — 实现（核心）
int ida_alloc_range(struct ida *ida, unsigned int min, unsigned int max, gfp_t gfp)
{
    unsigned long id;
    void *ent;
    int err;

    // 扫描 xarray 中已分配的 bitmap，找第一个空闲 bit
    // 1. 扫描 leaf bitmap
    // 2. 如果 leaf 满了（bitmap 所有 bit = 1），分配新的 bitmap node
    // 3. xa_store(bitmap, index) 存储
}
```

### 3.2 `ida_free` — 释放 ID

```c
// lib/idr.c — 释放时清除对应 bit，如果 bitmap 全空则释放 node
```

---

## 4. idr vs ida vs xarray vs radix_tree

| 特性 | radix_tree | **idr** | **ida** | xarray |
|------|-----------|---------|---------|---------|
| 底层 | radix_tree | radix_tree | **xarray** | xarray |
| 索引范围 | 32-bit | 32-bit | 32-bit | **64-bit** |
| 存指针 | ✅ | ✅ | ❌ | ✅ |
| 纯 ID 分配 | ❌ | ❌ | **✅（1bit/ID）** | ❌ |
| mark 支持 | 0/1 tag | 无 | 无 | **3 个 mark** |
| 典型场景 | 旧 page cache | pid、fd | minor、端口 | page cache |

---

## 5. 真实内核使用案例

### 5.1 进程 PID（`kernel/pid.c`）

```c
// 实际 pid 用法可能通过 idr_find
struct pid *find_get_pid(int pid);
struct task_struct *find_task_by_vpid(pid_t nr);
```

### 5.2 文件描述符（`fs/file.c`）

```c
// 每个进程有 files_struct，其中 fd 表用 idr 管理
struct files_struct {
    struct idr          fd_idr;     // ID → file* 映射
    struct file        *fd_array[]; // 预分配的小 fd 数组
};
```

### 5.3 设备驱动 minor 号

```c
// 驱动注册时分配设备号
int alloc_chrdev_region(dev_t *dev, unsigned baseminor, unsigned count, const char *name);
// 内部通过 idr 管理已分配的设备号
```

---

## 6. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| ida 用位图而非指针 | 每个 ID 只占 1 bit（1024 IDs = 128 bytes），vs idr 每 ID 8 bytes |
| ida 基于 xarray | 按需分配 bitmap node，内存随 ID 数量增长 |
| idr 用 radix_tree | Linux 7.0 仍保留旧实现（迁移中） |
| idr_base 支持 | 让 IDR 可以从非 0 起始（如从 1 开始分配） |

---

## 7. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/idr.h` | idr/ida 结构体定义、API 声明 |
| `lib/idr.c` | idr/ida 完整实现（radix_tree / xarray 操作） |
| `include/linux/radix-tree.h` | radix_tree 底层 |
| `fs/file.c` | fd idr 使用示例 |
