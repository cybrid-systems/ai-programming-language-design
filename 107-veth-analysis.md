# veth — 虚拟以太网设备对深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/veth.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**veth**（Virtual Ethernet）是成对出现的虚拟网络设备（veth0 ↔ veth1），数据从一端发出直接到另一端。用于连接网络命名空间、容器网络。

---

## 1. 核心数据结构

```c
// drivers/net/veth.c — veth_priv
struct veth_priv {
    struct net_device __rcu   *peer;         // 对端设备（通过 RCU 保护）
    atomic64_t                 drop_count;    // 丢弃计数
    atomic64_t                 stop_count;    // 停止计数
    struct bpf_prog          *xdp_prog;     // XDP 程序
};
```

---

## 2. 转发流程（核心）

```c
// drivers/net/veth.c — veth_xmit
static netdev_tx_t veth_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct veth_priv *priv = netdev_priv(dev);
    struct net_device *peer;
    struct sk_buff *skb_out;
    int delta;

    // 1. 获取对端（RCU 解引用）
    peer = rcu_dereference(priv->peer);
    if (unlikely(!peer)) {
        // 对端不存在，丢弃
        atomic64_inc(&priv->drop_count);
        goto drop;
    }

    // 2. 检查是否超出 MTU
    if (unlikely(skb->len > peer->mtu)) {
        atomic64_inc(&priv->drop_count);
        goto drop;
    }

    // 3. 如果是命名空间间转发，更新数据包元数据
    skb_out = skb;

    // 4. 如果需要，修正 skb 的 mac header
    if (dev->needed_headroom > peer->needed_headroom) {
        // 重新分配 skb 以增加 headroom
        skb_out = skb_realloc_headroom(skb, peer->needed_headroom);
        if (!skb_out)
            goto drop;
        consume_skb(skb);
    }

    // 5. 设置目标设备
    skb_out->dev = peer;
    skb_out->queue_mapping = 0;

    // 6. 转发到对端（不经过真实物理网络）
    //    netif_receive_skb 发送到 peer 的协议栈
    netif_receive_skb(skb_out);

    return NETDEV_TX_OK;

drop:
    dev_kfree_skb(skb);
    return NETDEV_TX_OK;
}
```

---

## 3. 创建 veth 对

### 3.1 ip link 命令

```bash
# 创建 veth 对
ip link add veth0 type veth peer name veth1

# 设置 IP
ip addr add 10.0.0.1/24 dev veth0
ip addr add 10.0.0.2/24 dev veth1

# 启用
ip link set veth0 up
ip link set veth1 up

# 把 veth1 移到另一个网络命名空间
ip link set veth1 netns ns1
```

### 3.2 内核 netlink 创建

```c
// drivers/net/veth.c — veth_newlink
static int veth_newlink(struct net *net, struct net_device *dev,
                        struct nlattr **tb, struct nlattr **data, ...)
{
    // 1. 创建两个 net_device
    struct net_device *peer;

    peer = alloc_netdev(sizeof(struct veth_priv), peer_name, NET_NAME_UNKNOWN,
                       veth_setup, priv);

    // 2. 设置配对
    rcu_assign_pointer(priv->peer, peer);
    rcu_assign_pointer(veth_priv(peer)->peer, dev);

    // 3. 注册设备
    register_netdevice(dev);
    register_netdevice(peer);

    return 0;
}
```

---

## 4. XDP 支持

```c
// drivers/net/veth.c — veth_prep_buf_for_xdp
// veth 支持 XDP（eXpress Data Path）：
// 在接收路径的最早阶段（skb 分配前）执行 BPF 程序

static struct sk_buff *veth_prep_buf_for_xdp(struct veth_priv *priv,
                                               struct sk_buff *skb)
{
    // 如果设置了 XDP 程序，在网卡驱动层处理
    // 而不是等到协议栈
    if (priv->xdp_prog)
        return __veth_xdp(priv, skb);
    return skb;
}
```

---

## 5. 在容器网络中的使用

```
宿主机 namespace:
  eth0 ← → veth0 ← → veth1 (在容器 ns 内)
                          eth0 (容器内)

容器进程看到：
  eth0: 10.0.0.2/24

从容器发出的数据包：
  eth0 → veth1 → veth0 → eth0 → 物理网络
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/veth.c` | `struct veth_priv`、`veth_xmit`、`veth_newlink` |
| `drivers/net/veth.c` | `veth_setup`（设备初始化）|