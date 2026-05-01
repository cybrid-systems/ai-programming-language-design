# 39-mlock — Linux 内核内存锁定深度源码分析

> 基于 Linux 7.0-rc1 主线源码

---

## 0. 概述

**mlock（内存锁定）** 将进程的虚拟页面锁定在物理内存中，防止被换出（swap）。关键应用：实时系统（避免缺页延迟）、加密应用（防止密钥被换出）。

---

## 1. API

```c
#include <sys/mman.h>
int mlock(const void *addr, size_t len);       // 锁定区间
int munlock(const void *addr, size_t len);     // 解锁
int mlockall(int flags);                       // 锁定全部
int munlockall(void);                          // 解锁全部

// flags: MCL_CURRENT（锁定当前）, MCL_FUTURE（锁定未来页）
```

---

## 2. 内核实现

```
mlock(addr, len)
  └─ do_mlock(start, len, VM_LOCKED)
       ├─ 遍历 VMA，设置 VM_LOCKED 标志
       └─ __mm_populate(start, len, 0)
            └─ populate_vma_page_range(vma, start, end, NULL)
                 → 对区间内所有页面调用 get_user_pages
                 → 强制缺页 → 页面进入物理内存
                 → 页面被标记为 unevictable（不可回收）
```

---

## 3. RLIMIT_MEMLOCK

RLIMIT_MEMLOCK 限制非 root 进程可锁定的内存总量：

```bash
ulimit -l 65536   # 限制 64MB
```

---

## 4. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/mlock.c | mlock 核心 |
| include/linux/mman.h | 标志定义 |

---

## 5. 关联文章

- **188-mlock**: mlock 深度分析

---

*分析工具：doom-lsp*
