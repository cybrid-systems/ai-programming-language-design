# Linux Kernel netfilter 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netfilter/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 netfilter？

**netfilter** 是 Linux 内核的**包过滤框架**，支持在网络协议栈的关键 HOOK 点检查、修改、丢弃数据包。iptables/nftables 都是基于 netfilter。

---

## 1. HOOK 点

```
Ingress  (PREROUTING)  → 路由决策  →  FORWARD  │ FORWARD  → POSTROUTING
                              │                      │
                        (INPUT)                    (OUTPUT)
                              │                      │
                         本机接收                  本机发送
```

---

## 2. nf_hook — 注册 HOOK

```c
// include/linux/netfilter.h — nf_hook_fn
typedef unsigned int nf_hookfn(void *priv,
                  struct sk_buff *skb,
                  const struct nf_hook_state *state);

struct nf_hook_ops {
    nf_hookfn          *hook;         // 回调函数
    struct net_device   *dev;         // 设备（NULL = 所有）
    pf                  pf;           // PF_INET / PF_INET6
    unsigned int        hooknum;      // HOOK 点
    int                 priority;    // 优先级（小的先执行）
};

// 注册 HOOK
int nf_register_net_hook(struct net *net, const struct nf_hook_ops *ops);
int nf_unregister_net_hook(struct net *net, const struct nf_hook_ops *ops);
```

---

## 3. iptables 表链

```
filter 表：
  INPUT   → NF_INET_LOCAL_IN   → 本机接收
  OUTPUT  → NF_INET_LOCAL_OUT  → 本机发送
  FORWARD → NF_INET_FORWARD    → 转发

nat 表：
  PREROUTING  → NF_INET_PRE_ROUTING   → 路由前（DNAT）
  POSTROUTING → NF_INET_POST_ROUTING  → 路由后（SNAT）
  OUTPUT      → NF_INET_LOCAL_OUT     → 本机输出（DNAT）
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/netfilter.h` | `struct nf_hook_ops`、`nf_hookfn` |
| `net/netfilter/core.c` | `nf_hook_slow`、`nf_register_net_hook` |
