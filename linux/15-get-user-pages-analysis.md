# 15-get_user_pages — 用户空间内存锁定深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**get_user_pages（GUP）** 是 Linux 内核中允许内核代码**锁定用户空间内存页**并直接访问的机制。它解决了两个核心需求：
1. **DMA 传输**：用户空间缓冲区必须物理连续 / 页对齐才能给 DMA 控制器用
2. **内核直接访问**：IOCTL/SYSCALL 中需要长时间在用户缓冲区上操作

GUP 返回一个 `struct page**` 数组，同时将页面锁定在内存中（不能被换出）。调用者使用完毕后通过 `put_page()` 释放。

doom-lsp 确认 `mm/gup.c` 包含约 950+ 个符号，是 Linux 内存管理中最关键也最容易出错的接口之一。

---

## 1. 核心函数

### 1.1 get_user_pages（经典函数）

```c
long get_user_pages(unsigned long start, unsigned long nr_pages,
                    unsigned int gup_flags, struct page **pages,
                    struct vm_area_struct **vmas);
```

参数：
- `start`：用户空间起始虚拟地址
- `nr_pages`：需要锁定的页数
- `gup_flags`：FOLL_* 标志
- `pages`：输出参数，返回的 page 指针数组
- `vmas`：可选，返回 VMA 信息

### 1.2 pin_user_pages（新一代）

```c
long pin_user_pages(unsigned long start, unsigned long nr_pages,
                    unsigned int gup_flags, struct page **pages);
```

从 Linux 5.6 开始，`pin_user_pages` 取代了 `get_user_pages`。它增加了对 **dma-pinned pages** 的跟踪，解决了长期页锁定与 THP 碎片整理的冲突。

---

## 2. 核心流程

```
pin_user_pages(start, nr_pages, FOLL_WRITE, pages)
  │
  ├─ internal_get_user_pages_fast(start, nr_pages, gup_flags, pages)
  │    │
  │    ├─ [快速路径] 锁定页表并遍历
  │    │    └─ walk_page_range() 遍历用户页表
  │    │    └─ 对每个有效的 PTE：
  │    │         ├─ 获取 struct page
  │    │         ├─ try_grab_page(page, flags)  ← 增加引用+标记
  │    │         │    └─ page_ref_inc(page)      引用计数+1
  │    │         │    └─ 设置 FOLL_PIN 标识
  │    │         └─ 存到 pages[] 数组
  │    │
  │    └─ [慢速路径] 处理缺页等异常
  │         └─ faultin_page()                    ← 触发缺页处理
  │         └─ handle_mm_fault()                 ← 分配物理页
  │         └─ 重试 GUP 操作
  │
  └─ return 已获取的页数
```

### 2.1 快速路径 vs 慢速路径

```
快速路径：
  ┌─────────────────────────────────┐
  │ 页表已存在                      │
  │ lock mmap_sem (读)              │
  │ follow_pte() → 获取 page*      │
  │ unlock mmap_sem                  │
  └─────────────────────────────────┘

慢速路径（缺页）：
  ┌─────────────────────────────────┐
  │ 页表不存在（未映射/被换出）      │
  │ lock mmap_sem (写)               │
  │ handle_mm_fault() → 分配页框    │
  │ unlock mmap_sem                  │
  │ 返回 GUP 重试                    │
  └─────────────────────────────────┘
```

---

## 3. FOLL 标志族

| 标志 | 含义 | 使用场景 |
|------|------|---------|
| `FOLL_WRITE` | 需要写权限 | DMA 从内存读取 |
| `FOLL_GET` | 获取引用（get_page） | 标准 GUP |
| `FOLL_PIN` | 使用 pin_user_pages 语义 | 长期锁定 |
| `FOLL_LONGTERM` | 长期持有页面 | 设备驱动程序 |
| `FOLL_FORCE` | 强制访问（即使只读映射）| ptrace / 调试 |
| `FOLL_NOWAIT` | 不等待缺页 | 原子上下文 |
| `FOLL_HWPOISON` | 允许获取损坏页 | 内存故障处理 |
| `FOLL_PCI_P2PDMA` | PCI P2P DMA 支持 | NVMe 等 |

---

## 4. 与页表的关系

GUP 的本质是**将用户空间页表解析为 `struct page*`，同时确保这些页不会被释放**。

```
用户虚拟地址空间：
  VA: 0x7f1234560000
  │
  ├─ 页表遍历（软件）：
  │    PGD → P4D → PUD → PMD → PTE
  │
  ├─ 每级页表项指向物理页框
  │
  └─ 最终 PTE 包含：
       ├─ 物理页框号 (PFN)
       ├─ 权限位 (R/W/X)
       └─ 状态位 (Present/Dirty/Accessed)

GUP 读取 PTE → PFN → struct page → page_ref_inc → pages[]
```

---

## 5. pin_user_pages 与 DMA 的关系

pin_user_pages 引入了 `FOLL_PIN` 和 `FOLL_LONGTERM` 两个关键概念：

```
get_user_pages（旧）：
  page->_refcount + 1
  → 页可以被文件系统迁移/整理
  → 与 THP 碎片整理冲突

pin_user_pages（新）：
  page->_refcount + 1
  page->_mapcount（FOLL_PIN 跟踪位）
  → 页被标记为 "dma-pinned"
  → 碎片整理可以避开这些页
  → 解决了长期 DMA 缓冲区的碎片问题
```

---

## 6. 释放路径

```c
void unpin_user_page(struct page *page)
{
    // 减少引用
    if (PageDmaPinned(page))
        __unpin_device_page(page);
    else
        put_page(page);
}
```

---

## 7. 设计决策总结

| 决策 | 原因 |
|------|------|
| 快速/慢速路径分离 | 绝大多数情况页表已存在 |
| pin_user_pages + FOLL_PIN | 解决长期锁定与 THP 碎片整理冲突 |
| page_ref_inc | 防止页面被回收 |
| 不复制页内容 | 共享物理内存（零拷贝） |
| vmas 参数可选 | 大部分调用者只需要 page 数组 |

---

## 8. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `mm/gup.c` | `internal_get_user_pages_fast` | 快速路径 |
| `mm/gup.c` | `faultin_page` | 缺页处理 |
| `mm/gup.c` | `pin_user_pages` | 入口 |
| `include/linux/mm.h` | `FOLL_*` 标志 | 定义 |

---

## 9. 关联文章

- **page_allocator**（article 17）：GUP 获取的页面来自 page allocator
- **VMA**（article 16）：GUP 通过 VMA 检查权限
- **DMA**（article 203）：DMA 传输使用 GUP 固定缓冲区

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
