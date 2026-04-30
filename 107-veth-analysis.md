# Linux Kernel veth (虚拟以太网对) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/veth.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. veth 概述

**veth** 是成对出现的虚拟以太网设备，一端发送的数据直接到达另一端，常用于：
- 连接两个 network namespace
- 连接容器到主机网桥

---

## 1. 核心结构

```c
// drivers/net/veth.c — veth_priv
struct veth_priv {
    struct net      *remote_net;   // 对方 netns
    struct net_device *peer;       // 配对设备
    struct napi_struct *napi;     // NAPI 轮询
    atomic_t         dropped;       // 丢弃计数
    struct list_head  delayed;     // 延迟队列
    struct bpf_prog *xdp_prog;    // XDP 程序
};
```

---

## 2. 数据包流程

```
veth0 (namespace A)                        veth1 (namespace B)
    │                                              │
    │ transmit:                                    │
    │   dev_hard_start_xmit()                     │
    │   → xmit path:                               │
    │     skb->dev = peer (veth1)                 │
    │     netif_rx(skb)  ← 直接进入 peer 的接收队列 │
    │                                              │
    │                                     receive: │
    │                                     netif_rx(skb) →
    │                                     eth_type_trans(skb, peer) →
    │                                     peer->netdev_ops->ndo_rx()
```

---

## 3. 创建

```c
// ip link add veth0 type veth peer name veth1
// → veth_newlink() → alloc_netdev(sizeof(priv), "veth%d", NET_NAME_UNKNOWN, veth_setup)
// → register_netdevice(veth0)
// → register_netdevice(veth1)
// → priv->peer = peer; peer->priv = veth0
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `drivers/net/veth.c` | `veth_xmit`、`veth_newlink` |
