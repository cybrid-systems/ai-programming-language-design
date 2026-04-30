# 153-netfilter_hooks — 数据包过滤深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netfilter/core.c` + `net/netfilter/nf_hook.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Netfilter Hooks** 是 Linux 内核数据包过滤框架的核心，通过在协议栈的关键位置插入 HOOK 点，实现防火墙、NAT、连接跟踪等功能。

---

## 1. HOOK 点详解

```
Netfilter HOOK 在数据包流向中的位置：

  入站方向（Local Process）：
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │  1. NIC 收到 → netif_receive_skb()                │
  │                    │                                │
  │                    ▼                                │
  │  2. PREROUTING [NF_INET_PRE_ROUTING]               │
  │                    │                                │
  │                    ▼                                │
  │  3. ip_rcv()（路由查找前）                         │
  │                    │                                │
  │                    ▼                                │
  │  4. 路由决策 → 目的地址是本机                       │
  │                    │                                │
  │                    ▼                                │
  │  5. LOCAL_IN [NF_INET_LOCAL_IN]                   │
  │                    │                                │
  │                    ▼                                │
  │  6. 协议处理（TCP/UDP/ICMP）                       │
  │                                                     │
  └─────────────────────────────────────────────────────┘

  出站方向（Local Process）：
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │  1. 协议处理（TCP/UDP 生成数据）                     │
  │                    │                                │
  │                    ▼                                │
  │  2. LOCAL_OUT [NF_INET_LOCAL_OUT]                  │
  │                    │                                │
  │                    ▼                                │
  │  3. 路由决策 → 发送接口                             │
  │                    │                                │
  │                    ▼                                │
  │  4. ip_output()                                   │
  │                    │                                │
  │                    ▼                                │
  │  5. POSTROUTING [NF_INET_POST_ROUTING]              │
  │                    │                                │
  │                    ▼                                │
  │  6. NIC 发送                                       │
  │                                                     │
  └─────────────────────────────────────────────────────┘

  转发方向（Forward）：
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │  1. NIC 收到 → netif_receive_skb()                │
  │                    │                                │
  │                    ▼                                │
  │  2. PREROUTING [NF_INET_PRE_ROUTING]               │
  │                    │                                │
  │                    ▼                                │
  │  3. 路由决策 → 目的地址不是本机（转发）              │
  │                    │                                │
  │                    ▼                                │
  │  4. FORWARD [NF_INET_FORWARD]                     │
  │                    │                                │
  │                    ▼                                │
  │  5. POSTROUTING [NF_INET_POST_ROUTING]              │
  │                    │                                │
  │                    ▼                                │
  │  6. NIC 发送                                       │
  │                                                     │
  └─────────────────────────────────────────────────────┘
```

---

## 2. struct nf_hook_ops — HOOK 操作

```c
// include/linux/netfilter.h — nf_hook_ops
struct nf_hook_ops {
    // 处理函数
    nf_hookfn          *hook;           // 处理函数

    // 优先级（数字小 = 先调用）
    struct net_device   *dev;           // 设备（NULL=所有设备）
    void               *priv;             // 私有数据

    // HOOK 配置
    u_int8_t           pf;              // 协议族（PF_INET/PF_INET6）
    unsigned int       hooknum;          // HOOK 点（NF_INET_*）
    int                 priority;         // 优先级
};
```

---

## 3. nf_hookfn — 处理函数类型

### 3.1 函数签名

```c
// include/linux/netfilter.h — nf_hookfn
typedef unsigned int nf_hookfn(void *priv,
                              struct sk_buff *skb,
                              const struct nf_hook_state *state);

struct nf_hook_state {
    u_int8_t           pf;              // 协议族
    unsigned int       hook;             // HOOK 点
    int                 thresh;           // 阈值
    struct net_device   *in;            // 入设备
    struct net_device   *out;           // 出设备
    struct sock         *sk;             // socket（如果有）
    int                 (*okfn)(struct net *, struct sk_buff *); // 继续处理
};
```

### 3.2 返回值

```c
// include/linux/netfilter.h — HOOK 返回值
#define NF_DROP      0  // 丢弃包
#define NF_ACCEPT    1  // 接受包，继续处理
#define NF_STOLEN    2  // HOOK 吞噬包，不再处理
#define NF_QUEUE      3  // 排队到用户空间（nfqueue）
#define NF_REPEAT     4  // 再次调用本 HOOK
#define NF_STOP       5  // 停止处理（不再调用后续 HOOK）
#define NF_MAX_VERDICT 6 // 最大判决数
```

---

## 4. nf_hook_slow — 执行 HOOK 链

### 4.1 nf_hook_slow

```c
// net/netfilter/core.c — nf_hook_slow
static int nf_hook_slow(u_int8_t pf, unsigned int hook,
                        struct sk_buff *skb,
                        const struct net_device *indev,
                        const struct net_device *outdev,
                        const struct nf_hook_entries *entries,
                        int (*okfn)(struct net *, struct sk_buff *))
{
    struct nf_hook_entry *entry;
    unsigned int verdict;
    int err;

    // 遍历 HOOK 链表（按优先级排序）
    entry = rcu_dereference(entries->hooks[hook]);

    next_hook:
    verdict = entry->hook(entry->priv, skb, &state);

    if (verdict != NF_ACCEPT) {
        if (verdict == NF_DROP)
            return -EPERM;
        if (verdict == NF_STOLEN)
            return 0;
        if (verdict == NF_QUEUE) {
            err = nf_queue(skb, entry, state, pf, hook, okfn);
            if (err < 0)
                return err;
        }
        return -EPERM;
    }

    // 继续下一个 HOOK
    entry = rcu_dereference(entry->next);
    if (entry)
        goto next_hook;

    // 所有 HOOK 都通过，调用 okfn
    return okfn(state.net, skb);
}
```

---

## 5. iptables 规则表映射

```c
// HOOK 点与 iptables 表的对应关系：

// IPv4：
PREROUTING  [NF_INET_PRE_ROUTING]  → nat 表 PREROUTING / mangle 表 PREROUTING
INPUT       [NF_INET_LOCAL_IN]     → filter 表 INPUT / mangle 表 INPUT
FORWARD     [NF_INET_FORWARD]       → filter 表 FORWARD / mangle 表 FORWARD
OUTPUT      [NF_INET_LOCAL_OUT]     → nat 表 OUTPUT / filter 表 OUTPUT / mangle 表 OUTPUT
POSTROUTING [NF_INET_POST_ROUTING]  → nat 表 POSTROUTING / mangle 表 POSTROUTING

// IPv6：
PREROUTING  [NF_INET_PRE_ROUTING]  → ip6 nat 表 PREROUTING / ip6tables
INPUT       [NF_INET_LOCAL_IN]     → ip6 filter 表 INPUT
FORWARD     [NF_INET_FORWARD]       → ip6 filter 表 FORWARD
OUTPUT      [NF_INET_LOCAL_OUT]     → ip6 nat 表 OUTPUT / ip6 filter 表 OUTPUT
POSTROUTING [NF_INET_POST_ROUTING] → ip6 nat 表 POSTROUTING
```

---

## 6. HOOK 注册

### 6.1 nf_register_net_hook

```c
// net/netfilter/core.c — nf_register_net_hook
int nf_register_net_hook(struct net *net, const struct nf_hook_ops *ops)
{
    struct nf_hook_entries *new;
    struct nf_hook_entries *old;

    // 1. 分配新的 HOOK 条目数组
    new = nf_hook_entries_grow(ops, old);

    // 2. 按优先级排序
    sort_entries(new);

    // 3. 安装新的 HOOK 表
    rcu_assign_pointer(net->nf.hooks[ops->pf][ops->hooknum], new);

    return 0;
}
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/netfilter/core.c` | `nf_hook_slow`、`nf_register_net_hook` |
| `net/netfilter/nf_hook.c` | `nf_hook_entries_grow` |
| `include/linux/netfilter.h` | `struct nf_hook_ops`、`nf_hookfn`、`NF_DROP/ACCEPT/STOLEN/QUEUE` |

---

## 8. 西游记类比

**Netfilter HOOK** 就像"取经路的关卡系统"——

> 数据包就像一个行旅的人，在天庭的各个关卡（HOOK 点）接受检查。PREROUTING 像入城前的第一个关卡，LOCAL_IN 像城内关卡（目的地是本机），FORWARD 像过路关卡（目的地是其他城市），LOCAL_OUT 像出城关卡，POSTROUTING 像出城后的最后一个关卡。每个关卡有多个检查员（nf_hook_ops），按优先级顺序检查。第一个人说"放行"（NF_ACCEPT），第二个人说"禁止"（NF_DROP），就禁止。如果第一个人说"我再看看"（NF_REPEAT），就要再检查一遍。

---

## 9. 关联文章

- **conntrack**（article 154）：连接跟踪增强 HOOK
- **iptables NAT**（相关）：NAT 表的实现