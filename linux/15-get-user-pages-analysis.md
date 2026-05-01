# 15-get_user_pages — 用户空间内存锁��深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**get_user_pages（GUP）** 是内核锁定用户空间内存页并直接访问的机制。它解决两个需求：
1. **DMA 传输**：用户空间缓冲区必须有物理地址才能在 DMA 中使用
2. **内核直接访问**：IOCTL/SYSCALL 中需长时间操作用户缓冲区（如 RDMA、GPU）

GUP 的核心操作：锁定用户页 → 返回 `struct page**` → 内核/DMA 直接使用 → 完成后释放。

doom-lsp 确认 `mm/gup.c` 包含约 950+ 个符号，是内存管理中最要紧的接口之一。

---

## 1. 核心 API

### 1.1 get_user_pages vs pin_user_pages

```c
// 传统版本
long get_user_pages(unsigned long start, unsigned long nr_pages,
                    unsigned int gup_flags, struct page **pages,
                    struct vm_area_struct **vmas);

// 新版本（Linux 5.6+，推荐）
long pin_user_pages(unsigned long start, unsigned long nr_pages,
                    unsigned int gup_flags, struct page **pages);
```

`pin_user_pages` 解决了长期 DMA 缓冲区与透明大页碎片整理的冲突问题，通过 `FOLL_PIN` 标记页面的"已钉选"状态。

---

## 2. 核心操作流程

```
pin_user_pages(start, nr_pages, FOLL_WRITE, pages)
  │
  ├─ internal_get_user_pages_fast(start, nr_pages, gup_flags, pages)
  │    │
  │    ├─ [快速路径] gup_fast_permitted()
  │    │    └─ 锁定 RCU，遍历页表
  │    │    └─ follow_page_mask(vma, addr, flags) → page*
  │    │    └─ 如果页表项有效 → try_grab_page(page, flags)
  │    │         └─ page_ref_inc(page)
  │    │         └─ 设置 FOLL_PIN 标识（区分 get_page vs pin）
  │    │
  │    ├─ [慢速路径] __get_user_pages()
  │    │    └─ lock mmap_lock（读锁）
  │    │    └─ find_vma(mm, start)
  │    │    └─ follow_page_mask() → 如果缺页：
  │    │         └─ handle_mm_fault(vma, addr, flags) → 分配物理页
  │    │         └─ 重新 follow 获取 page
  │    │    └─ unlock mmap_lock
  │    │
  │    └─ return 已获取的页数
```

---

## 3. FOLL 标志

| 标志 | 含义 | 使用场景 |
|------|------|---------|
| `FOLL_WRITE` | 需要写权限 | DMA 读内存（设备写入）|
| `FOLL_GET` | 获取引用（get_page）| 标准 GUP |
| `FOLL_PIN` | 使用 pin_user_pages 语义 | 长期锁定 |
| `FOLL_LONGTERM` | 长期持有页面 | 设备驱动程序 |
| `FOLL_FORCE` | 强制访问 | ptrace / 调试 |
| `FOLL_NOWAIT` | 不等待缺页 | 原子上下文 |
| `FOLL_HWPOISON` | 允许获取损坏页 | 内存故障处理 |

---

## 4. 与 page allocator 的关系

```
GUP 本质：
  用户空间 VA → 页表遍历 → PFN（物理页框号）
  → struct page* → page_ref_inc（防止释放）

内核/DMA 使用：
  直接读写 page->virtual（或 page_to_phys 给 DMA）

完成后释放：
  unpin_user_page(page)     ← 减少引用计数
  → 如果引用降为 0 → 放回 buddy 系统
```

---

## 5. 设计决策总结

| 决策 | 原因 |
|------|------|
| 快速/慢速路径分离 | 大多数情况页表已存在（快速路径）|
| pin_user_pages + FOLL_PIN | 解决长期锁定与 THP 碎片冲突 |
| page_ref_inc | 防止页面被回收 |
| 不复制页内容 | 共享物理内存（零拷贝）|

---

## 6. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `mm/gup.c` | `pin_user_pages` / `get_user_pages` / `__get_user_pages` |
| `include/linux/mm.h` | `FOLL_*` 标志定义 |

---

## 7. 关联文章

- **page_allocator**（article 17）：GUP 获得的物理页来自 buddy 系统
- **VMA**（article 16）：GUP 通过 VMA 检查权限

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
