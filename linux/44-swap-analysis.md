# 44-swap — 交换子系统深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**swap** 将不活跃的匿名页换出到磁盘，释放物理内存给活跃进程。Linux 支持交换分区、交换文件和 zram 压缩交换。

---

## 1. 核心流程

```
页面换出（kswapd / direct reclaim）：
  │
  ├─ shrink_list → swap_writepage(page, wbc)
  │    │
  │    ├─ 分配交换槽位
  │    │    └─ get_swap_page(page)
  │    │         └─ 从 swap_info_struct 分配一个 swap entry
  │    │
  │    ├─ 写入交换设备
  │    │    └─ a_ops->swap_writepage(page, wbc)
  │    │         └─ 提交 bio 到块层
  │    │
  │    ├─ 更新页表为 swap entry
  │    │    └─ set_pte_at(mm, addr, pte, swp_entry_to_pte(entry))
  │    │
  │    └─ 释放页（放入 swap cache 或直接释放）

页面换入（缺页）：
  │
  ├─ do_swap_page(vmf)
  │    ├─ 从 PTE 提取 swap entry
  │    ├─ lookup_swap_cache() → 检查 swap cache
  │    ├─ 如果未命中：
  │    │    └─ swap_readpage(page) → 从磁盘读回
  │    ├─ 更新页表为可读/写
  │    └─ 释放 swap 槽位（swap_free）
```

---

## 2. swap entry 编码

```
swap entry（存储在 PTE 中）：
  ┌──────────────────────────────────────┐
  │ bit 0-4:   swap 类型（最多 32 设备）  │
  │ bit 5-63:  交换设备上偏移（槽号）      │
  └──────────────────────────────────────┘

通过 swp_entry(type, offset) 和 swp_type()/swp_offset() 编解码
```

---

*分析工具：doom-lsp（clangd LSP）*
