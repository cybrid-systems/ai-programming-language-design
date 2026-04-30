# 28-netfilter — 包过滤框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netfilter/core.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**netfilter** 是 Linux 的数据包过滤框架，在协议栈的关键 HOOK 点插入处理逻辑，实现防火墙（iptables/nftables）、NAT、连接跟踪等功能。

---

## 1. HOOK 点

```
数据包在协议栈中的 HOOK：

   入站                                    出站
    │                                      ▲
    ▼                                      │
   PREROUTING (路由前)                     │
    │                                      │
   [NF_INET_LOCAL_IN] ──────────────────────┤
    │                                      │
   FORWARD (路由后转发)                     │
    │                                      │
   POSTROUTING (路由后)                    │
    │                                      │
   [NF_INET_LOCAL_OUT] ←───────────────────┘

HOOK 优先级（数字小 = 先执行）：
  NF_IP_PRE_ROUTING  = 0  (PREROUTING)
  NF_IP_LOCAL_IN    = 1  (LOCAL_IN)
  NF_IP_FORWARD     = 2  (FORWARD)
  NF_IP_LOCAL_OUT   = 3  (LOCAL_OUT)
  NF_IP_POST_ROUTING = 4 (POSTROUTING)
```

---

## 2. nf_hook_ops — HOOK 操作

```c
// include/linux/netfilter.h — nf_hook_ops
struct nf_hook_ops {
    nf_hookfn          *hook;      // 处理函数
    void               *priv;      // 私有数据
    u_int8_t           pf;          // 协议族（PF_INET 等）
    unsigned int       hooknum;     // HOOK 点（NF_INET_*）
    int                 priority;   // 优先级（小的先调用）
};
```

---

## 3. nf_hookfn — 处理函数

```c
// include/linux/netfilter.h — nf_hookfn
typedef unsigned int nf_hookfn(void *priv,
                              struct sk_buff *skb,
                              const struct nf_hook_state *state);

enum nf_hook_ops_type {
    NF_HOOK_NOLOG   = 0,
    NF_HOOK_BPF      = 1,
    NF_HOOK_NORMAL   = 2,
    NF_HOOK_DEV_BPF  = 3,
};

// 返回值：
//   NF_DROP     = 丢弃包
//   NF_ACCEPT   = 接受包，继续处理
//   NF_STOLEN   = 吞噬包（HOOK 处理完，不再处理）
//   NF_QUEUE    = 排队到用户空间（nfqueue）
//   NF_REPEAT   = 重新调用本 HOOK
```

---

## 4. nf_hook_slow — 执行 HOOK 链

```c
// net/netfilter/core.c — nf_hook_slow
unsigned int nf_hook_slow(u_int8_t pf, unsigned int hook,
                          struct sk_buff *skb, struct net_device *indev,
                          struct net_device *outdev,
                          const struct net_device *const *hook_list)
{
    struct list_head *head;
    struct nf_hook_entry *hook_entry;
    unsigned int verdict;

    // 遍历 HOOK 链表
    head = &hook_list[hook];
    list_for_each_entry_rcu(hook_entry, head, list) {
        verdict = hook_entry->hook(hook_entry->priv, skb, state);
        if (verdict != NF_ACCEPT)
            return verdict;  // 丢弃或其他
    }

    return NF_ACCEPT;
}
```

---

## 5. iptables 规则表

```
iptables 表链结构：

filter 表（包过滤）：
  INPUT   → NF_INET_LOCAL_IN
  OUTPUT  → NF_INET_LOCAL_OUT
  FORWARD → NF_INET_FORWARD

nat 表（地址转换）：
  PREROUTING  → NF_IP_PRE_ROUTING  (DNAT)
  OUTPUT      → NF_IP_LOCAL_OUT    (LOCAL DNAT)
  POSTROUTING → NF_IP_POST_ROUTING (SNAT)
```

---

## 6. 连接跟踪（conntrack）

```c
// net/netfilter/nf_conntrack_core.c — nf_conntrack_in
// 每个连接在 HOOK 中被跟踪：
//   NEW → ESTABLISHED → RELATED → ...

struct nf_conntrack_tuple {
    union nf_inet_addr src;  // 源地址
    union nf_inet_addr dst;  // 目标地址
    __be16              src_port;  // 源端口
    __be16              dst_port;  // 目标端口
    u8                 protonum;   // TCP/UDP/ICMP
};
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/netfilter.h` | `struct nf_hook_ops`、`nf_hookfn` |
| `net/netfilter/core.c` | `nf_hook_slow` |

---

## 8. 西游记类比

**netfilter** 就像"取经路上的关卡检查站"——

> 数据包经过各个关卡（HOOK 点）时，每个关卡（nf_hook_ops）按优先级顺序检查。iptables 规则就像每个关卡的操作手册（规则表），按顺序从上到下匹配。第一条匹配的规则决定数据包命运（NF_DROP 丢弃，NF_ACCEPT 放行）。如果所有关卡都放行，包就继续旅行（进入协议栈）。

---

## 9. 关联文章

- **conntrack**（网络部分）：连接跟踪增强 netfilter
- **netfilter**（article 63）：nf_conntrack 模块