# 190-KSM — 内核同页合并深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/ksm.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**KSM（Kernel Samepage Merging）** 扫描合并相同内容的内存页，减少内存占用。常用于虚拟机环境。

---

## 1. KSM 工作原理

```
KSM 扫描：
  1. 初始化时，将所有候选页加入 rb_tree（按内容哈希）
  2. 扫描时，比较页内容
  3. 如果两个页内容相同，合并（COW）

合并后：
  - 物理页只保留一个
  - 多个进程的虚拟地址映射到同一物理页
  - COW 保护：写入时复制，生成新的私有副本
```

---

## 2. KSM daemon

```bash
# 启用 KSM：
echo 1 > /sys/kernel/mm/ksm/run

# 查看统计：
cat /sys/kernel/mm/ksm/full_scans
cat /sys/kernel/mm/ksm/pages_sharing  # 共享出的页数
cat /sys/kernel/mm/ksm/pages_shared   # 被共享的页数
```

---

## 3. 西游记类喻

**KSM** 就像"天庭的重复典籍合并"——

> 如果 100 个妖怪都有同一本经书（相同内容），KSM 就像天庭的抄写官，只保留一本原版，其余都标注"同第 X 号"。这样大大节省了纸张（物理内存）。如果某个妖怪想在自己的经书上做笔记（写入），抄写官就给他一本新的副本（COW）。

---

## 4. 关联文章

- **THP**（article 189）：THP 和 KSM 都减少页表开销