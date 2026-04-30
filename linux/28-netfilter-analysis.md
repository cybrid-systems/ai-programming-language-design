# netfilter — 包过滤框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netfilter/core.c` + `net/ipv4/netfilter/iptable_filter.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**netfilter** 是 Linux 内核的**数据包过滤框架**，通过 HOOK 点在协议栈各处截获数据包进行过滤/NAT/记录。

---

## 1. HOOK 点（Netfilter Hooks）

### 1.1 IPv4 HOOK 点

```
prerouting  ───► FORWARD ───► postrouting
     │                          ▲
     ▼                          │
  INPUT                       OUTPUT
     │                          ▲
     ▼                          │
 LOCAL PROCESS                 │
```

| HOOK | 位置 | 用途 |
|------|------|------|
| NF_INET_PRE_ROUTING | 收到包最早位置 | DNAT、raw 表 |
| NF_INET_LOCAL_IN | 转发给本地进程 | INPUT 过滤 |
| NF_INET_FORWARD | 转发到其他主机 | FORWARD 过滤 |
| NF_INET_LOCAL_OUT | 本地发出包 | OUTPUT 过滤、SNAT |
| NF_INET_POST_ROUTING | 发出前最后位置 | SNAT、mangle |

### 1.2 HOOK 注册

```c
// include/linux/netfilter.h — nf_hook_ops
struct nf_hook_ops {
    struct list_head        list;            // 链表
    nf_hookfn              *hook;            // 回调函数
    pf_type                pf;               // 协议族（PF_INET 等）
    unsigned int           hooknum;           // HOOK 点编号
    int                    priority;         // 优先级（越小越先）
};
```

---

## 2. 核心数据结构

### 2.1 nf_hook_entry — HOOK 条目

```c
// net/netfilter/core.c — nf_hook_entry
struct nf_hook_entry {
    nf_hookfn          *hook;        // 过滤函数
    void              *priv;        // 私有数据
};

struct nf_hook_info {
    struct nf_hook_entry *hooks[NF_MAX_HOOKS]; // 每协议族每点一个
};
```

### 2.2 net — 网络命名空间

```c
// include/net/net_namespace.h — net
struct net {
    // netfilter 规则
    struct netns nf  *nf;          // netfilter 命名空间
    // ...
};
```

---

## 3. 数据包处理流程

### 3.1 nf_hook_slow — 遍历 HOOK 链

```c
// net/netfilter/core.c — nf_hook_slow
static unsigned int nf_hook_slow(struct net *net, struct sk_buff *skb,
                 const struct nf_hook_state *state)
{
    struct nf_hook_entries *hooks;
    unsigned int verdict;
    struct nf_hook_entry *hook;
    void *priv;

    // 获取 HOOK 链
    hooks = rcu_dereference(net->nf.hooks[state->pf][state->hooknum]);
    if (!hooks)
        return NF_ACCEPT;

    // 遍历每个 HOOK
    for (i = 0; i < hooks->num; i++) {
        verdict = hooks->hooks[i].hook(hooks->hooks[i].priv, skb, state);
        if (verdict != NF_ACCEPT)
            return verdict;
    }

    return NF_ACCEPT;
}
```

### 3.2 返回值

```c
// include/uapi/linux/netfilter.h
enum nf_inet_hooks {
    NF_HOOK_REJECT = -1,           // 拒绝
    NF_HOOK_DROP = -2,             // 丢弃
    NF_HOOK_BPF = -3,             // BPF 决定
    NF_HOOK_NF_DEV_1 = -5,         // 厂商自定义
    NF_ACCEPT = 1,                 // 接受
    NF_DROP = 1,                   // 丢弃
    NF_QUEUE = 2,                   // 放入队列（nft queues）
};
```

---

## 4. iptables 表链结构

```
raw ─────► mangle ─────► nat ─────► filter
 (钩子)    (修改)     (地址)    (过滤)
   │
   ▼
PREROUTING / OUTPUT
```

### 4.1 ipt_table — 表

```c
// net/ipv4/netfilter/iptable_filter.c — ipt_table
static struct xt_table filter_table = {
    .name       = "filter",
    .valid_hooks = FILTER_VALID_HOOKS,
    .hook       = filter_hook,           // HOOK 函数
    .owner      = THIS_MODULE,
    .me         = "iptable_filter",
};
```

### 4.2 filter_hook — filter 表处理

```c
static unsigned int filter_hook(void *priv, struct sk_buff *skb,
                   const struct nf_hook_state *state)
{
    // INPUT/FORWARD/OUTPUT 三个点的分发
    switch (state->hook) {
    case NF_INET_LOCAL_IN:
        return ipt_do_table(skb, state->hook, &info->chains[0]);
    case NF_INET_FORWARD:
        return ipt_do_table(skb, state->hook, &info->chains[1]);
    case NF_INET_LOCAL_OUT:
        return ipt_do_table(skb, state->hook, &info->chains[2]);
    }
    return NF_ACCEPT;
}
```

---

## 5. nftables — 替代 iptables

**nftables**（Linux 3.13+）是新一代包过滤框架：
- 更简单的语法
- 内核 JIT 编译规则
- 原生支持 set/map
- 替代 iptables/ip6tables/ebtables

```c
// 用户空间规则：
table inet filter {
    chain input {
        tcp dport 22 accept
        ip saddr 192.168.1.0/24 drop
    }
}
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/netfilter.h` | `struct nf_hook_ops`、`NF_HOOK_*` |
| `net/netfilter/core.c` | `nf_hook_slow`、`nf_register_net_hook` |
| `net/ipv4/netfilter/iptable_filter.c` | `filter_hook`、`ipt_do_table` |