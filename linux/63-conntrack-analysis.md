# 63-conntrack — 连接跟踪深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**conntrack（Connection Tracking）** 跟踪所有网络连接的状态，是 iptables NAT/mangle/state 模块和 nftables conntrack 表达式的基础。

---

## 1. 核心路径

```
nf_conntrack_in(skb, hook, ...)
  │
  ├─ resolve_normal_ct()           ← 查找/创建 conntrack 条目
  │    └─ 哈希表查找（tuple 哈希）
  │    └─ 如果未找到 → 创建新条目
  │
  └─ nf_conntrack_confirm(skb)     ← 确认连接
       └─ 将 unconfirmed 条目移入主哈希表
```

---

*分析工具：doom-lsp（clangd LSP）*
