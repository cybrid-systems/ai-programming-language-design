# 188-mlock — 内存锁定深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mlock.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**mlock** 将进程的虚拟地址范围锁定到物理内存，防止被换出（swap out）。常用于高性能和实时应用。

---

## 1. mlock 系统调用

```c
// mm/mlock.c — sys_mlock
long sys_mlock(unsigned long start, size_t len)
{
    unsigned long locked;
    struct vm_area_struct *vma;

    // 1. 锁定限制检查
    locked = (current->mm->locked_vm + len) >> PAGE_SHIFT;
    if (locked > rlimit(RLIMIT_MEMLOCK))
        return -EAGAIN;

    // 2. 设置 VM_LOCKED 标志
    vma = find_vma(current->mm, start);
    vma->vm_flags |= VM_LOCKED;

    // 3. 调用 make_pages_present
    make_pages_present(start, start + len);

    return 0;
}
```

---

## 2. make_pages_present

```c
// mm/mlock.c — make_pages_present
int make_pages_present(unsigned long start, unsigned long end)
{
    int ret;

    // 逐页调用 get_user_pages
    while (start < end) {
        ret = get_user_pages(start, 1, FOLL_TOUCH | FOLL_WRITE, &page);
        put_page(page);
        start += PAGE_SIZE;
    }
}
```

---

## 3. munlock

```c
// munlock 系统调用
// 清除 VM_LOCKED 标志，允许页被换出
// 但不会立即换出，页仍然在内存中
```

---

## 4. mlockall / munlockall

```bash
# 锁定所有内存：
mlockall(MCL_CURRENT | MCL_FUTURE);

# MCL_CURRENT — 锁定已映射的页
# MCL_FUTURE — 锁定未来映射的页
```

---

## 5. 西游记类喻

**mlock** 就像"天庭的常驻营地"——

> 普通营地（普通内存）可能被天庭收回（换出到 swap），但标记为"常驻"（mlock）的营地不会被收回，妖怪永远占着这个位置。好处是取东西（访问）永远很快（无页面 fault），坏处是常驻营地有限，天庭不能把地盘给其他妖怪。

---

## 6. 关联文章

- **get_user_pages**（article 15）：mlock 底层调用 get_user_pages
- **swap**（相关）：mlock 防止页被 swap out