# 22-sk_buff — 网络缓冲区深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**sk_buff（socket buffer）** 贯穿整个网络协议栈——从网卡驱动到 socket 层，每个网络包都封装在一个 sk_buff 中。

---

## 1. 缓冲区布局

```
head             data              tail              end
  │                │                 │                │
  ├───────┬────────┼─────────────────┼────────────────┤
  │headroom│ L2头   │ L3/IP 头       │  payload        │
  │ (预留) │ (MAC)  │                │                 │
  └───────┴────────┴─────────────────┴────────────────┘
```

skb_push：data 前移（添加头部）
skb_put： tail 后移（增加数据）
skb_pull：data 后移（剥离头部）
skb_reserve：data+tail 前移（预留 headroom）

---

## 2. 分配与释放

```c
struct sk_buff *alloc_skb(unsigned int size, gfp_t priority);

// 克隆：共享数据缓冲区（引用计数+1），复制 sk_buff 结构
struct sk_buff *skb_clone(struct sk_buff *skb, gfp_t priority);

// 复制：完整深拷贝
struct sk_buff *skb_copy(const struct sk_buff *skb, gfp_t priority);
```

---

*分析工具：doom-lsp（clangd LSP）*
