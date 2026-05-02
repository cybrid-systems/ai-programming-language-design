# 89-brk-sbrk — Linux 堆管理（brk/sbrk）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**brk** 和 **sbrk** 是 Linux 中管理进程堆（heap）的系统调用——`brk(addr)` 将堆结束地址设为 `addr`（扩展或收缩堆），`sbrk(increment)` 在堆末尾增加 `increment` 字节。`malloc` 底层使用 `brk`（小分配）或 `mmap`（大分配）获取内存。

**核心设计**：堆是进程地址空间中紧接 BSS 段的一段连续区域，`mm->brk` 指向堆结束地址（初始 = `mm->start_brk`）。`brk` 扩展堆时在 `oldbrk` 处创建一个新的匿名 VMA，收缩时释放 `newbrk` 到 `oldbrk` 之间的页面。

```
进程地址空间布局：
  ┌─────────────────────┐  high
  │ 栈 (stack)          │  ← stack pointer
  ├─────────────────────┤
  │  ▼ (向下生长)        │
  │  (空洞)              │
  │  ▲ (向上生长)        │
  ├─────────────────────┤
  │ 堆 (heap)            │  ← mm->brk (当前堆顶)
  │                     │  ← mm->start_brk (堆底/初始值)
  ├─────────────────────┤
  │ BSS (未初始化数据)   │
  ├─────────────────────┤
  │ 数据段 (data)        │
  ├─────────────────────┤
  │ 代码段 (text)        │  ← 固定从 0x400000 开始
  └─────────────────────┘  low

brk(扩展):                    brk(收缩):
  oldbrk→newbrk 创建 VMA       newbrk→oldbrk 释放 VMA
  do_brk_flags()              do_vmi_align_munmap()
```

**doom-lsp 确认**：`SYSCALL_DEFINE1(brk)` @ `mm/mmap.c:116`。`do_brk_flags` @ `:1205`。`vm_brk_flags` @ `mm/mmap.c:1205`。

---

## 1. mm->brk——堆边界

```c
// include/linux/mm_types.h
struct mm_struct {
    unsigned long start_brk;      // 堆起始地址（固定，mapped by exec）
    unsigned long brk;            // 堆结束地址（通过 brk 系统调用调整）
    unsigned long start_data;     // 数据段起始
    unsigned long end_data;       // 数据段结束
};

// start_brk 在 exec 时设置：
// load_elf_binary() → setup_new_exec() → arch_pick_mmap_layout()
// → mm->start_brk = mm->brk = randomize_stack_top(STACK_TOP)
//    (ASLR: CONFIG_COMPAT_BRK 可禁用随机化)
```

## 2. brk 系统调用 @ :116

```c
SYSCALL_DEFINE1(brk, unsigned long, brk)
{
    // 1. 最低堆地址检查（不能低于默认堆底）
    min_brk = mm->start_brk;
#ifdef CONFIG_COMPAT_BRK
    if (!current->brk_randomized)
        min_brk = mm->end_data;
#endif
    if (brk < min_brk)
        goto out;

    // 2. RLIMIT_DATA 检查
    if (check_data_rlimit(rlimit(RLIMIT_DATA), brk, ...))
        goto out;

    // 3. 收缩或扩展
    newbrk = PAGE_ALIGN(brk);
    oldbrk = PAGE_ALIGN(mm->brk);

    if (brk <= mm->brk) {                     // 收缩
        mm->brk = brk;
        do_vmi_align_munmap(&vmi, ..., newbrk, oldbrk, ...);
        // → unmap_region() → zap_page_range() 清除页表
        goto success_unlocked;
    }

    check_brk_limits(oldbrk, newbrk - oldbrk);
    do_brk_flags(&vmi, brkvma, oldbrk, newbrk - oldbrk, EMPTY_VMA_FLAGS);
    mm->brk = brk;
    return mm->brk;
}
```

---

## 2. do_brk_flags @ :1205——堆扩展

```c
int do_brk_flags(struct vma_iterator *vmi, struct vm_area_struct *brkvma,
                 unsigned long addr, unsigned long len, unsigned long flags)
{
    struct mm_struct *mm = current->mm;
    struct vm_area_struct *vma = NULL;

    // 1. 尝试与前面的 VMA 合并
    if (brkvma && brkvma->vm_end == addr && ...) {
        // 最后一个 VMA 刚好在 oldbrk 处结束 → 扩展它
        vma = brkvma;
        vma->vm_end = addr + len;           // 扩展
    } else {
        // 2. 创建新的匿名 VMA
        vma = vm_area_alloc(mm);
        vma->vm_start = addr;
        vma->vm_end = addr + len;
        vma->vm_flags = VM_READ | VM_WRITE | VM_MAYREAD | VM_MAYWRITE;
        vma->vm_page_prot = PAGE_SHARED;    // 读写权限
        vma_link(mm, vma, ...);
    }

    mm->total_vm += len >> PAGE_SHIFT;      // 更新统计
    return 0;
}
```

**doom-lsp 确认**：`do_brk_flags` @ `:1205`。堆扩展本质上是在堆顶添加一个匿名读/写 VMA，不占用物理页——直到访问时才通过 `do_anonymous_page` 分配。

---

## 3. 堆收缩——do_vmi_align_munmap

```c
// brk 收缩时调用 do_vmi_align_munmap() 释放页面：
// → 通过 find_vma() 定位待删除的 VMA
// → split_vma() 分割（如果收缩范围在 VMA 中间）
// → detach_vmas_to_be_unmapped() 从红黑树移除
// → unmap_region() 清除页表
//   → zap_page_range() → 释放物理页
// → remove_vma_list() → 释放 VMA 结构体
// → mm->total_vm 减少
```

---

## 4. 懒页分配

```c
// brk 扩展堆后，堆区域不立即分配物理页面：
// 1. brk(sbrk) → do_brk_flags() 只创建 VMA
// 2. 进程首次访问堆内存 → 缺页
// 3. handle_mm_fault → __handle_mm_fault → do_anonymous_page()
// 4. → alloc_zeroed_user_highpage() 分配零页
// 5. → set_pte_at() 建立页表映射

// 这就是"懒分配"（on-demand paging）：
// 程序 malloc(1GB) → 立即返回（只扩展了 brk）
// 访问页面时 → 才真正分配物理内存
// 未访问的页面不占用物理 RAM
```

---

## 5. brk vs mmap 分配策略

| 特性 | brk | mmap |
|------|-----|------|
| 申请方式 | 调整堆边界（线性） | 创建新 VMA（可能不连续）|
| 释放方式 | 调整堆边界 | munmap |
| 碎片 | 少（线性分配） | 多（VMA 断片）|
| 大块分配 | 不适合（brk 必须连续） | 适合 |
| 多线程 | 不安全（堆共享） | 安全 |
| malloc 策略 | 小分配（<128KB） | 大分配（>128KB）|

---

## 6. 调试

```bash
# 查看进程的堆范围
cat /proc/<pid>/maps | grep heap
# 7f1234000000-7f1236000000 rw-p 00000000 00:00 0          [heap]

# strace 跟踪 brk
strace -e brk ls

# 查看系统的 brk 随机化
cat /proc/sys/kernel/randomize_va_space
```

---

## 7. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `SYSCALL_DEFINE1(brk)` | `:116` | brk 系统调用 |
| `do_brk_flags` | `:1205` | 堆扩展（VMA 创建/合并）|
| `vm_brk_flags` | `:1205` | 通用堆扩展 API |
| `check_brk_limits` | — | 堆限制检查 |
| `do_vmi_align_munmap` | — | 堆收缩（VMA 移除+页释放）|

---

## 8. 总结

`brk`（@ `mm/mmap.c:116`）扩展堆时调用 `do_brk_flags`（`:1205`）创建/合并匿名 VMA，收缩时调用 `do_vmi_align_munmap` 释放页面。物理内存采用懒分配——缺页时才通过 `do_anonymous_page` 分配零页。

### brk 系统调用完整路径 @ mmap.c:116

```c
SYSCALL_DEFINE1(brk, unsigned long, brk)
{
    // 1. 不能低于 start_brk
    if (brk < min_brk) goto out;

    // 2. RLIMIT_DATA 检查
    if (check_data_rlimit(RLIMIT_DATA, brk, mm->start_brk, ...))
        goto out;

    newbrk = PAGE_ALIGN(brk);
    oldbrk = PAGE_ALIGN(mm->brk);

    // 3. 收缩
    if (brk <= mm->brk) {
        mm->brk = brk;
        do_vmi_align_munmap(&vmi, ..., newbrk, oldbrk, ...);
        goto success_unlocked;
    }

    // 4. 扩展（check_brk_limits → do_brk_flags）
    check_brk_limits(oldbrk, newbrk - oldbrk);
    do_brk_flags(&vmi, brkvma, oldbrk, newbrk - oldbrk, EMPTY_VMA_FLAGS);
    mm->brk = brk;
    return mm->brk;
}
```

### do_brk_flags @ :1205——扩展实现

```c
int do_brk_flags(..., unsigned long addr, unsigned long len, ...)
{
    // 优先合并到前一个 VMA
    if (brkvma && brkvma->vm_end == addr && can_vma_merge_after(...)) {
        brkvma->vm_end = addr + len;        // 合并
    } else {
        vma = vm_area_alloc(mm);            // 新 VMA
        vma->vm_start = addr;
        vma->vm_end = addr + len;
        vma->vm_flags = VM_READ|VM_WRITE|VM_MAYREAD|VM_MAYWRITE;
        vma->vm_page_prot = PAGE_SHARED;
        vma_link(mm, vma, prev, rb_link, rb_parent);
    }
    mm->total_vm += len >> PAGE_SHIFT;
}
```

### 懒分配——缺页时分配物理页

```c
// brk 只修改 VMA 边界，不分配物理页
// 进程首次访问 → 缺页 → do_anonymous_page()
// → alloc_zeroed_user_highpage() 从伙伴系统分配零页
// → set_pte_at() 建立页表映射
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
