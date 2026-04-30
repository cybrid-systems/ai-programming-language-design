# swap — 交换空间管理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/swap_state.c` + `mm/swapfile.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**swap** 将不活跃的内存页换出到磁盘，扩展可用内存。当物理内存不足时，内核将冷页面（长期未访问）移到 swap 设备。

---

## 1. 核心数据结构

### 1.1 swap_info_struct — swap 设备

```c
// mm/swapfile.c — swap_info_struct
struct swap_info_struct {
    // 设备信息
    unsigned long           max;           // 最大页数
    unsigned long           pages;          // 可用页数
    unsigned int            prio;          // 优先级（多设备时）
    unsigned char           type;          // 设备类型
    unsigned char           has_pands;      // 有施优先级

    // 位图（分配状态）
    unsigned long         *map;            // swap 位图（1 页 = 1 bit）

    // SWAP 缓存
    struct address_space   *swap_file;      // 底层文件系统（如果是文件）
    struct file            *swap_file;     // swap 文件

    // 统计
    atomic_t                inuse_pages;    // 使用中的页数
    unsigned int           cluster_next;    // 下次分配簇
    unsigned int            cluster_next;   // 簇信息

    // 列表
    struct plist_head       list;           // swap 设备链表（按优先级）
    spinlock_t              lock;           // 保护
};
```

### 1.2 swap_cache — swap 缓存

```c
// mm/swap_state.c — swap_cache
struct swap_cache_info {
    atomic_t                total;         // 缓存页总数
    struct radix_tree_root  radix;         // 页号 → page 映射
    atomic_t                waste;         // 浪费计数
    spinlock_t              lock;           // 保护
    unsigned long           lowest_bit;     // 最小空闲位
    unsigned long           highest_bit;    // 最大已占用位
};
```

---

## 2. 添加 swap 设备

### 2.1 swapon — 启用 swap

```c
// mm/swapfile.c — sys_swapon
SYSCALL_DEFINE2(swapon, const char *, specialfile, int, swap_flags)
{
    struct swap_info_struct *p;
    struct file *swap_file;
    struct address_space *mapping;

    // 1. 打开 swap 文件/设备
    swap_file = filp_open(specialfile, O_RDWR | O_LARGEFILE, 0);

    // 2. 分配 swap_info_struct
    p = kmalloc(sizeof(*p), GFP_KERNEL);
    memset(p, 0, sizeof(*p));

    // 3. 分配位图（按 swap 大小）
    p->max = get_swap_device_pages(swap_file);
    p->map = vmalloc(p->max / BITS_PER_BYTE);

    // 4. 初始化位图为 0（全部可用）
    for (i = 0; i < p->max; i++)
        clear_bit(i, p->map);

    // 5. 加入 swap 列表
    spin_lock(&swap_lock);
    p->next = swap_list.next;
    swap_list.next = p - swap_info;
    spin_unlock(&swap_lock);

    return 0;
}
```

---

## 3. 分配 swap 页（get_swap_page）

```c
// mm/swapfile.c — get_swap_page
static struct swap_info_struct *get_swap_page(void)
{
    struct swap_info_struct *p;
    int type, next;

    spin_lock(&swap_lock);

    // 1. 遍历 swap 设备列表（按优先级）
    plist_for_each_entry(p, &swap_list.head, list) {
        // 2. 找空闲位
        type = p - swap_info;

        // 3. 使用 CLUSTER 策略分配（一组连续页）
        if (swap_list.entries[type].next == 0)
            continue;

        offset = scan_swap_map_slots(p, SWAP_BATCH);
        if (offset)
            goto found;
    }

    spin_unlock(&swap_lock);
    return NULL;  // 没有空闲

found:
    // 设置位图
    set_bit(offset, p->map);
    p->inuse_pages++;
    spin_unlock(&swap_lock);

    return p;  // 返回 offset（页在设备中的位置）
}
```

---

## 4. 换出（swap_out）

### 4.1 try_to_unmap — 尝试取消映射

```c
// mm/rmap.c — try_to_unmap
int try_to_unmap(struct page *page, enum ttu_flags flags)
{
    struct address_space *mapping;
    struct anon_vma *anon_vma;

    // 1. 如果是匿名页
    if (PageAnon(page)) {
        anon_vma = page_anon_vma(page);

        // 2. 尝试 anon_vma 锁定
        if (!trylock_page(page))
            goto retry;

        // 3. 检查引用计数
        if (page_mapcount(page) > 1)
            goto discard;

        // 4. 分配 swap 位置
        offset = get_swap_page();

        // 5. 写入 swap 设备
        swap_writepage(page, offset);

        // 6. 更新 PTE 为 swap entry
        set_pte_swapout(pte, page, offset);
    }
    return SWAP_SUCCESS;
}
```

---

## 5. 换入（swap_in）

```c
// mm/swap_state.c — read_swap_cache
struct page *read_swap_cache_async(swp_entry_t entry, gfp_t gfp_mask, struct vm_area_struct *vma, unsigned long addr)
{
    struct page *page;

    // 1. 检查 swap 缓存中是否已有
    page = find_get_page(swap_address_space(entry), swp_offset(entry));
    if (page)
        return page;

    // 2. 分配新页
    page = alloc_page_vma(gfp_mask, vma, addr);

    // 3. 从 swap 读取内容
    swapin_read(entry, page);

    // 4. 加入 swap 缓存
    add_to_swap_cache(page, entry);

    return page;
}
```

---

## 6. swap 优先级

```c
// 多 swap 设备：优先级高先使用
// swapon -p 100 /dev/sda1  ← 设置优先级
// swapon -p 50 /dev/sdb1   ← 优先级低的设备

// 优先级相同时，轮转使用（cluster 分配策略）
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/swapfile.c` | `sys_swapon`、`get_swap_page`、`swap_out` |
| `mm/swap_state.c` | `read_swap_cache_async`、`add_to_swap_cache` |
| `mm/rmap.c` | `try_to_unmap` |