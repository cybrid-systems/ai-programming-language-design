# 18-copy_page_range — 页表复制深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**copy_page_range** 是 `fork()` 的核心内存操作：复制父进程的页表到子进程，但物理页框通过**写时复制（COW）** 延迟复制。

---

## 1. 核心流程

```
copy_page_range(dst_mm, src_mm, vma)
  │
  ├─ 遍历 src_mm 中 VMA 覆盖的所有页表项
  │
  ├─ 对每个 PTE：
  │    ├─ 匿名页：
  │    │    ├─ 复制 PTE 到子进程页表
  │    │    ├─ 父进程 PTE 标记为只读（pte_wrprotect）
  │    │    ├─ page->_mapcount++
  │    │    └─ 设置 pte_mkold（清除 Accessed 位）
  │    │
  │    ├─ 文件映射页：
  │    │    ├─ page cache 引用 +1
  │    │    └─ 如果 MAP_PRIVATE → 同样写保护
  │    │
  │    └─ 交换页：
  │         └─ 增加交换引用计数
```

---

## 2. COW 触发

子进程或父进程对共享页写入时：

```
do_wp_page(vmf)
  │
  ├─ 检查 page_mapcount(old_page)
  │    ├─ == 1：只有本进程使用 → 直接设为可写
  │    └─ > 1：多人引用
  │         ├─ alloc_page() → 分配新页
  │         ├─ copy_user_highpage() → 复制内容
  │         ├─ 修改 PTE 指向新页（可写）
  │         └─ old_page 引用 -1
```

---

## 3. 设计决策

| 决策 | 原因 |
|------|------|
| COW 延迟复制 | fork 后立即写大量页是少数情况 |
| 引用==1 优化 | 若仅自己引用，免复制 |
| pte_wrprotect | 所有 PTE 写保护标记 |

---

*分析工具：doom-lsp（clangd LSP）*
