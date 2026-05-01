# 39-mlock — 内存锁定深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**mlock** 将指定虚拟地址区间的物理页锁定在内存中，阻止被换出（swap）。用于对延迟敏感的应用（如实时程序、密码学操作）。

---

## 1. 核心操作

```
mlock(addr, len)
  │
  └─ do_mlock(start, len, VM_LOCKED)
       ├─ 遍历 VMA，设置 VM_LOCKED 标志
       │
       ├─ 对每个 VMA：
       │    └─ __mlock_vma_pages_range(vma, start, end)
       │         ├─ 遍历页表
       │         ├─ 对每个 PTE：
       │         │    ├─ 如果页已存在 → get_page() + mark as unevictable
       │         │    └─ 如果缺页 → handle_mm_fault() → 分配物理页
       │         └─ 标记为不可换出（unevictable）
       │
       └─ 更新 rss 统计

munlock(addr, len)
  └─ 清除 VM_LOCKED 标志
       └─ 如果页面不再被其他 VMA 锁定 → 放回可换出列表
```

---

*分析工具：doom-lsp（clangd LSP）*
