# Linux Kernel mlock / munlock 内存锁定深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mlock.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 mlock？

**`mlock()`** 将进程的部分或全部虚拟地址空间**锁定到物理 RAM**，被锁定的页**不会被 swap out**，确保访问时不会触发 page fault。

**典型用途**：
- 数据库：锁住数据页，保证实时访问
- 实时系统：避免页面换入换出导致的延迟不确定
- 加密：防止敏感数据写入 swap

---

## 1. 核心 API

```c
// 用户空间
int mlock(const void *addr, size_t len);
int munlock(const void *addr, size_t len);
int mlock2(const void *addr, size_t len, int flags);

// 内核内部
int do_mlock(struct mm_struct *mm, unsigned long start, size_t len, bool unlock);
int do_mlockpages(struct vm_area_struct *vma, unsigned long start, unsigned long end, int lock);
```

---

## 2. mlock 流程

```c
// mm/mlock.c — do_mlock
int do_mlock(struct mm_struct *mm, unsigned long start, size_t len, bool unlock)
{
    // 1. 查找覆盖此地址范围的 VMA
    struct vm_area_struct *vma = find_vma_links(mm, start, start + len);

    // 2. split VMA 如果范围在 VMA 中间
    if (start != vma->vm_start || end != vma->vm_end)
        vma = split_vma(mm, vma, start, end);

    // 3. 设置 VM_LOCKED 标志
    if (!unlock) {
        vma->vm_flags |= VM_LOCKED;
        // 4. 将已映射的页锁定到内存
        apply_mlock(vma, start, end - start);
    } else {
        vma->vm_flags &= ~VM_LOCKED;
        // 4. 解锁，唤醒休眠的 kswapd
        apply_mlock(vma, start, end - start);
    }
}

// mm/mlock.c — apply_mlock
static int apply_mlock(struct vm_area_struct *vma, unsigned long start, unsigned long end)
{
    if (vma->vm_flags & VM_LOCKED) {
        // 将此 VMA 内的所有页锁定
        // 调用 make_pages_present() → get_user_pages() → mlock_page()
        mlock_page(vma, start, end);
    } else {
        // 解锁
        munlock_page(vma, start, end);
    }
}

// mm/mlock.c — mlock_page
static int mlock_page(struct vm_area_struct *vma, unsigned long address)
{
    struct page *page;
    int ret;

    // 1. 获取页
    ret = get_user_pages_fast(address & PAGE_MASK, 1, FOLL_POPULATE, &page);
    if (ret < 0) return ret;

    // 2. 锁定页（增加页的引用，不允许换出）
    ret = mlock_page_ext(page, true);  // 内部调用 folio_lock()

    // 3. 更新 LRU 统计
    lru_cache_add_inactive_or_unevictable(page);

    put_page(page);
    return 0;
}
```

---

## 3. munlock 流程

```c
// mm/mlock.c — munlock_page
static int munlock_page(struct vm_area_struct *vma, unsigned long address)
{
    struct page *page;

    // 1. 获取页（如果不在内存，skip）
    if (!get_user_pages_fast(address & PAGE_MASK, 1, FOLL_FAST_ONLY, &page))
        return 0;

    // 2. 解锁页
    mlock_page_ext(page, false);  // 清除锁标志

    // 3. 如果 LRU 上有 unevictable 标记，移回 LRU
    if (page_evictable(page))
        putback_lru_page(page);

    put_page(page);
    return 0;
}
```

---

## 4. 内存锁定与 swap 的关系

```
普通页（unlocked）：
  - LRU ACTIVE / INACTIVE 链表
  - 内存压力时可以被回收（写入 swap）

锁定的页（locked）：
  - LRU Unevictable 链表（PG_UNEVICTABLE 标志）
  - 不会被 kswapd 回收
  - 内存压力时不能换出

kswapd 回收时：
  → 检查 page_evictable()
  → 如果 PG_UNEVICTABLE，跳过
```

---

## 5. mlockall / munlockall

```c
// 锁定进程整个地址空间
int mlockall(int flags);
// MCL_CURRENT：锁定当前已映射的页
// MCL_FUTURE：锁定未来映射的页
// MCL_ONFAULT：只锁定未来发生 page fault 的页

// 内部实现
do_mlockall(int flags)
  → for each vma in mm->mmap
      if (flags & MCL_CURRENT)
          apply_mlock(vma, vma->vm_start, vma->vm_end)
      if (flags & MCL_FUTURE)
          vma->vm_flags |= VM_LOCKED;  // 未来自动锁定
```

---

## 6. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| PG_UNEVICTABLE 标志 | 与 LRU 淘汰机制整合，锁定的页进入特殊链表 |
| `mlockall(MCL_FUTURE)` | 新映射自动锁定，适合数据库等长期内存需求 |
| `MLOCK_ONFAULT` | 按需锁定，只锁定实际访问到的页 |
| 配合 VMA 标志 | VM_LOCKED 避免后续 mmap 的页被换出 |

---

## 7. 参考

| 文件 | 内容 |
|------|------|
| `mm/mlock.c` | `do_mlock`、`mlock_page`、`munlock_page`、`apply_mlock` |
| `include/linux/mm.h` | `VM_LOCKED` 标志定义 |
| `mm/internal.h` | `page_evictable`、`putback_lru_page` |
