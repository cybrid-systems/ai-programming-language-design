# 28-netfilter — 网络过滤框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Netfilter** 是 Linux 内核中的包过滤/处理框架，允许内核模块在网络协议栈的关键点注册钩子函数，对经过的网络包进行检查、修改、丢弃或放行。

iptables/nftables 等用户空间工具都基于 Netfilter 框架实现。

---

## 1. 钩子系统

Netfilter 在网络协议栈中定义了 5 个钩子点：

```
              ┌──────────────────────┐
              │      网络层入口        │
              │  (ip_rcv / ip6_rcv)   │
              └──────────┬───────────┘
                         │
              ┌──────────▼───────────┐
         ┌───│ NF_INET_PRE_ROUTING   │──── 路由前（DNAT 等）
         │   └──────────┬───────────┘
         │              │
         │   ┌──────────▼───────────┐
         │   │      路由决策         │
         │   └──────────┬───────────┘
         │              │
    ┌────▼──────┐  ┌────▼──────┐
    │ FORWARD    │  │ LOCAL_IN   │
    │ NF_INET_   │  │ NF_INET_   │
    │ FORWARD    │  │ LOCAL_IN    │
    └────┬──────┘  └────┬──────┘
         │              │
    ┌────▼──────┐       │
    │ LOCAL_OUT │       │
    │ NF_INET_  │       │
    │ POST_     │       │
    │ ROUTING   │       │
    └────┬──────┘       │
         │              │
    ┌────▼──────────────▼──────┐
    │ NF_INET_POST_ROUTING     │── 路由后（SNAT 等）
    └──────────┬───────────┘
               │
               ▼
```

---

## 2. 核心结构

```c
enum nf_inet_hooks {
    NF_INET_PRE_ROUTING,    // 首包处理（DNAT）
    NF_INET_LOCAL_IN,       // 本机目的包
    NF_INET_FORWARD,        // 转发包
    NF_INET_LOCAL_OUT,      // 本机发出的包
    NF_INET_POST_ROUTING,   // 尾包处理（SNAT）
    NF_INET_NUMHOOKS
};
```

每个钩子点对应一个钩子函数链表：

```
struct nf_hook_entries {
    u16                     num_hook_entries;
    struct nf_hook_entry    hooks[];
};
```

---

## 3. 调用流程

```c
// net/netfilter/core.c
int nf_hook_slow(u8 pf, unsigned int hook, struct sk_buff *skb,
                 struct net_device *indev, struct net_device *outdev,
                 int (*okfn)(struct net *, struct sock *, struct sk_buff *))
{
    // 遍历钩子链表，执行每个钩子
    struct nf_hook_entry *entry;
    int verdict;

    list_for_each_entry_rcu(entry, &nf_hooks[pf][hook], list) {
        verdict = entry->hook(hook, skb, indev, outdev, okfn);
        switch (verdict) {
        case NF_ACCEPT:  continue;        // 继续处理
        case NF_DROP:    return -EPERM;   // 丢弃
        case NF_QUEUE:   return -EINVAL;  // 排队到用户空间
        case NF_STOLEN:  return 0;        // 包被接管
        case NF_REPEAT:  goto retry;      // 重新执行钩子
        }
    }
}
```

---

## 4. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `net/netfilter/core.c` | `nf_hook_slow` |
| `net/netfilter/nf_tables_api.c` | nftables 规则管理 |
| `include/linux/netfilter.h` | 钩子定义 |
| `include/uapi/linux/netfilter.h` | 判决值定义 |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
