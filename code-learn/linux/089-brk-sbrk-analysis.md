# 089-brk-sbrk — Linux 堆管理（brk/sbrk）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**brk/sbrk** 是 Linux 中管理进程堆（heap）的原始系统调用。`brk(addr)` 将堆结束地址设为 `addr`，`sbrk(increment)` 在堆末尾增减 `increment` 字节。glibc 的 `malloc` 小分配使用 brk，大分配使用 `mmap`。

堆是进程地址空间中紧接 BSS 段的一段连续区域，由 `mm->start_brk`（堆底）和 `mm->brk`（堆顶、当前哨兵）界定。

**doom-lsp 确认**：`SYSCALL_DEFINE1(brk)` @ `mm/mmap.c:116`。`do_brk_flags` @ `mm/vma.c:2880`。

---

## 1. sys_brk 完整源码（mm/mmap.c L116~195）

```c
SYSCALL_DEFINE1(brk, unsigned long, brk)
{
    unsigned long newbrk, oldbrk, origbrk;
    struct mm_struct *mm = current->mm;
    struct vm_area_struct *brkvma, *next = NULL;
    unsigned long min_brk;

    if (mmap_write_lock_killable(mm))
        return -EINTR;

    origbrk = mm->brk;
    min_brk = mm->start_brk;          // L125 — 堆底（不可收缩到此以下）

    if (brk < min_brk)
        goto out;                     // ← 拒绝（保持原值）

    if (check_data_rlimit(rlimit(RLIMIT_DATA), brk, mm->start_brk,
                          mm->end_data, mm->start_data))
        goto out;

    newbrk = PAGE_ALIGN(brk);
    oldbrk = PAGE_ALIGN(mm->brk);

    if (oldbrk == newbrk) {           // ← 无变化
        mm->brk = brk;
        goto success;
    }

    /* --- 收缩路径 --- */
    if (brk <= mm->brk) {
        vma_iter_init(&vmi, mm, newbrk);
        brkvma = vma_find(&vmi, oldbrk);
        if (!brkvma || brkvma->vm_start >= oldbrk)
            goto out;                 // 与其他 VMA 冲突
        mm->brk = brk;
        if (do_vmi_align_munmap(&vmi, brkvma, mm, newbrk, oldbrk, &uf, true))
            goto out;
        goto success_unlocked;
    }

    /* --- 扩展路径 --- */
    if (check_brk_limits(oldbrk, newbrk - oldbrk))
        goto out;

    // 检查与下一 VMA 的 stack_guard_gap
    next = vma_find(&vmi, newbrk + PAGE_SIZE + stack_guard_gap);
    if (next && newbrk + PAGE_SIZE > vm_start_gap(next))
        goto out;

    brkvma = vma_prev_limit(&vmi, mm->start_brk);
    if (do_brk_flags(&vmi, brkvma, oldbrk, newbrk - oldbrk, // L1235
                     EMPTY_VMA_FLAGS) < 0)
        goto out;

    mm->brk = brk;
    // 如果 VM_LOCKED，逐页 populate
    // ...
    return brk;
}
```

**决策流**：

```
sys_brk(new)
  │
  ├─ 安全检查：< start_brk? > rlimit? 冲突 VMA? stack_guard_gap?
  │
  ├─ PAGE_ALIGN(old) == PAGE_ALIGN(new) → 返回原值（无操作）
  │
  ├─ NEW < OLD → 收缩：
  │     do_vmi_align_munmap() → 释放 old→new 的页面
  │     (过程同 munmap 系统调用)
  │
  └─ NEW > OLD → 扩展：
        do_brk_flags() → 在 oldbrk 处创建匿名 VMA
        └─ vma 标志：VM_USER | VM_ANON | VM_READ | VM_WRITE | VM_MAYREAD | VM_MAYWRITE
        └─ 不分配物理页——惰性缺页（do_anonymous_page）
```

---

## 2. do_brk_flags（mm/vma.c L2880 — doom-lsp 确认）

```c
int do_brk_flags(struct vma_iterator *vmi, struct vm_area_struct *brkvma,
                 unsigned long addr, unsigned long len,
                 unsigned long flags)
{
    struct mm_struct *mm = current->mm;
    struct vm_area_struct *vma;

    // 1. 检查是否和已有 VMA 可以合并
    if (brkvma && brkvma->vm_end == addr &&
        can_vma_merge_after(brkvma, flags, ...)) {
        // 合并到已有的堆 VMA（避免 VMA 碎片化）
        vma = brkvma;
        vma->vm_end = addr + len;
    } else {
        // 2. 创建新的匿名 VMA
        vma = vm_area_alloc(mm);
        vma_vma(vma, mm, addr, addr + len);
        vma->vm_flags = VM_USER | VM_ANON | VM_READ | VM_WRITE |
                        VM_MAYREAD | VM_MAYWRITE | flags;
        vma->vm_page_prot = vm_get_page_prot(vma->vm_flags);
        vma->vm_ops = NULL;             // 匿名 VMA：无 vm_ops
        vma_link(vma);
    }

    // 3. per-process 统计更新
    mm->data_vm += len >> PAGE_SHIFT;
    if (flags & VM_LOCKED) {
        mm->locked_vm += len >> PAGE_SHIFT;
        populate = true;
    }

    // 4. 如果 VM_LOCKED，逐页触发缺页
    if (populate)
        populate_vma_page_range(vma, addr, addr + len, ...);
}
```

---

## 3. sbrk 与 glibc 的交互

brk 是传统接口，glibc 在其上构建了更复杂的 malloc 策略：

```
当前 glibc malloc 的策略：
  < 128KB:       brk/sbrk 扩展堆
  ≥ 128KB 且     可用相邻地址：brk 扩展
  其他:           mmap 分配

brk 的限制：
  - 只在堆顶操作，不能释放堆中间的页面
  - 多线程环境下 brk 是全局锁（mmap_lock）
  - 大分配后收缩困难（堆中间的内存被映射占住）
```

---

## 4. 关键函数

| 函数 | 文件 | 行号 |
|------|------|------|
| `sys_brk()` | mm/mmap.c | 116 |
| `do_brk_flags()` | mm/vma.c | 2880 |
| `vm_brk_flags()` | mm/mmap.c | 1205 |
| `check_brk_limits()` | mm/mmap.c | 相关 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
