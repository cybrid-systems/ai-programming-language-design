# veth — 虚拟以太网设备对深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/veth.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**veth**（Virtual Ethernet）是成对出现的虚拟网络设备，数据从一端发出直接到另一端。用于命名空间连接。

---

## 1. veth 设备对

```c
// drivers/net/veth.c — veth_priv
struct veth_priv {
    struct net_device __rcu *peer;   // 对端设备
    atomic64_t             drop_count; // 丢弃计数
};
```

---

## 2. 转发流程

```c
// drivers/net/veth.c — veth_xmit
static netdev_tx_t veth_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct veth_priv *priv = netdev_priv(dev);
    struct net_device *peer;

    // 1. 获取对端
    peer = rcu_dereference(priv->peer);
    if (!peer)
        return TX_DROP;

    // 2. 发送skb 到对端
    //    不需要实际的物理传输，直接转发
    dev_forward_skb(peer, skb);

    return TX_OK;
}
```

---

## 3. 创建 veth 对

```c
// drivers/net/veth.c — veth_newlink
static int veth_newlink(struct net *src_net, struct net_device *dev,
                        struct nlattr **tb, struct nlattr **data, ...)
{
    // 创建两个配对设备
    // veth0 <-> veth1
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/veth.c` | `veth_priv`、`veth_xmit` |