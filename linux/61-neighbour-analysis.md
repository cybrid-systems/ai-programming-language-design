# 61-neighbour — 邻居协议深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**neighbour** 子系统管理 IPv4 ARP 和 IPv6 NDP 的邻居（IP↔MAC）映射缓存。

---

## 1. 核心流程

```
neigh_lookup(tbl, pkey, dev)     ← 查找邻居
  └─ 哈希表查找 → 返回 neighbour

neigh_resolve_output(skb)        ← 发送前解析 MAC
  └─ 如果 MAC 已知 → 直接发送
  └─ 如果未知 → 发出 ARP 请求 → 等待回复 → 更新缓存

neigh_update(n, lladdr, ...)     ← 接收 ARP 回复后更新缓存
  └─ 更新 MAC 地址
  └─ 发送排队的 skb
```

---

*分析工具：doom-lsp（clangd LSP）*
