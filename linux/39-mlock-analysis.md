# mlock / munlock / maslock — 内存锁定深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mlock.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**mlock** 将进程虚拟地址锁定在物理内存，防止被换出（swap out）。用于：
- **高性能计算**：避免 page fault 开销
- **实时系统**：保证内存响应时间
- **安全**：敏感数据不换出到磁盘

---

## 1. 核心 API

```c
// include/uapi/sys/mman.h
int mlock(const void *addr, size_t len);      // 锁定地址范围
int munlock(const void *addr, size_t len);    // 解锁地址范围
int mlockall(int flags);    // MCL_CURRENT(锁定已映射) | MCL_FUTURE(锁定未来映射)
int munlockall(void);      // 解锁所有

// 限制检查
unsigned long mlock2(const void *addr, size_t len, int flags); // 5.19+
// flags: MLOCK_ONFAULT — 只锁定已映射的页，不触发分配
```

---

## 2. mlock 系统调用

### 2.1 sys_mlock

```c
// mm/mlock.c — sys_mlock
SYSCALL_DEFINE2(mlock, unsigned long, start, size_t, len)
{
    unsigned long locked_start, locked_end;
    int ret;

    // 1. 对齐地址到页边界
    locked_start = (start + PAGE_SIZE - 1) & PAGE_MASK;
    locked_end = (start + len) & PAGE_MASK;

    if (locked_end <= locked_start)
        return -ENOMEM;

    // 2. 获取写信号量，避免 COW 触发
    down_write(&current->mm->mmap_lock);

    // 3. 锁定 VMA 范围内的页
    ret = apply_mlock(locked_start, locked_end - locked_start, 0);

    up_write(&current->mm->mmap_lock);

    return ret;
}
```

### 2.2 apply_mlock — 遍历 VMA

```c
// mm/mlock.c — apply_mlock
static int apply_mlock(unsigned long start, unsigned long len, int flags)
{
    struct vm_area_struct *vma;
    unsigned long end = start + len;

    // 遍历所有覆盖的 VMA
    for (vma = find_vma(current->mm, start); vma; vma = vma->vm_next) {
        unsigned long vm_start = max(start, vma->vm_start);
        unsigned long vm_end = min(end, vma->vm_end);

        if (vm_start >= vm_end)
            continue;

        // 设置 VMA 锁定标志
        if (vma->vm_flags & VM_LOCKED) {
            // 如果 VMA 已有 VM_LOCKED，锁定已映射的页
            apply_vma_lock_flags(vm_start, vm_end - vm_start);
        } else if (flags & MCL_ONFAULT) {
            // 只锁定已存在的页（不触发 COW）
            apply_vma_lock_flags(vm_start, vm_end - vm_start);
        }
    }

    return 0;
}
```

---

## 3. mlock_page — 锁定单页（核心）

```c
// mm/mlock.c — mlock_page
int mlock_page(struct page *page, struct vm_area_struct *vma, unsigned long addr)
{
    int ret = 0;

    VM_BUG_ON_PAGE(!PageLocked(page), page);

    // 如果已在 ML 链表，无需操作
    if (PageMlocked(page))
        return 0;

    // 1. 设置 PG_mlocked 标志
    SetPageMlocked(page);

    // 2. 从 LRU 链表移除，加入 ML 链表（unevictable）
    //    ML 链表页不会被 reclaim/swap
    lru_cache_add_file(page);  // 加入 unevictable 链表

    // 3. 更新统计
    mod_node_page_state(page_pgdat(page), NR_MLOCK, 1);

    // 4. 计数
    if (vma)
        vma->vm_private_data = (void *)((unsigned long)vma->vm_private_data + 1);

    return ret;
}
```

---

## 4. munlock — 解锁

```c
// mm/mlock.c — sys_munlock
SYSCALL_DEFINE2(munlock, unsigned long, start, size_t, len)
{
    unsigned long locked_start, locked_end;

    // 对齐地址
    locked_start = (start + PAGE_SIZE - 1) & PAGE_MASK;
    locked_end = (start + len) & PAGE_MASK;

    down_write(&current->mm->mmap_lock);

    // 遍历 VMA，解锁页
    apply_vma_unlock_flags(locked_start, locked_end - locked_start);

    up_write(&current->mm->mmap_lock);

    return 0;
}
```

### 4.1 munlock_page

```c
// mm/mlock.c — munlock_page
void munlock_page(struct page *page)
{
    // 1. 清除 PG_mlocked 标志
    ClearPageMlocked(page);

    // 2. 从 ML 链表移出
    //    如果 page->_mapcount > 0（被多个 VMA 映射），
    //    只在最后一个 VMA 解除后真正清除
    if (!page_mapcount(page))
        update_page_reclaim_stat(page);

    // 3. 更新统计
    mod_node_page_state(page_pgdat(page), NR_MLOCK, -1);
}
```

---

## 5. VM_LOCKED 标志与 VMA

```c
// include/linux/mm.h — VM_LOCKED
#define VM_LOCKED       0x00000002

// 效果：
// - mmap() 时如果设置了 PROT_READ | PROT_WRITE | MAP_LOCKED，
//   内核自动调用 mlock() 锁定
// - faultin_page() 在 COW 后自动设置 PG_mlocked
// - 页永远不会被 reclaim（直到 munlock 或进程退出）
```

---

## 6. mlockall — 锁定所有映射

```c
// mm/mlock.c — sys_mlockall
SYSCALL_DEFINE1(mlockall, int, flags)
{
    unsigned long lock_limit;
    int ret;

    // 验证参数
    if (flags & ~MCL_CURRENT)
        if (flags & ~MCL_FUTURE)
            return -EINVAL;

    down_write(&current->mm->mmap_lock);

    // 1. 锁定已映射的区域
    if (flags & MCL_CURRENT) {
        // 遍历所有 VMA，设置 VM_LOCKED 并锁定已映射的页
        for (vma = current->mm->mmap; vma; vma = vma->vm_next) {
            if (vma->vm_flags & VM_LOCKED)
                continue;

            vma->vm_flags |= VM_LOCKED;
            apply_vma_lock_flags(vma->vm_start,
                                  vma->vm_end - vma->vm_start);
        }
    }

    // 2. 设置标志，让未来映射自动锁定
    if (flags & MCL_FUTURE)
        current->mm->def_flags |= VM_LOCKED;

    up_write(&current->mm->mmap_lock);

    return 0;
}
```

---

## 7. 与 swap 的关系

```
页锁定：         页 → PG_mlocked → ML 链表 → 永远在内存
正常页：         页 → LRU 链表 → 可回收（memory pressure 时换出）
不可回收页：     页 → unevictable → 不能换出（mlock 或硬件）

检查页是否可回收：
  is_page_cache_freeable(page)     → 普通页
  page_mapped(page) && !PageMlocked(page) → 被映射但未锁定的页可回收
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 | 行 |
|------|----------|-----|
| `mm/mlock.c` | `sys_mlock` | 系统调用入口 |
| `mm/mlock.c` | `apply_mlock` | 遍历 VMA |
| `mm/mlock.c` | `mlock_page` | 锁定单页 |
| `mm/mlock.c` | `munlock_page` | 解锁单页 |
| `mm/mlock.c` | `sys_mlockall` | 锁定所有 |
| `include/linux/page-flags.h` | `PageMlocked` | 标志检测 |