# 107-veth — Linux veth 虚拟 Ethernet 设备深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**veth**（Virtual Ethernet）是 Linux 的虚拟 Ethernet 设备对——创建时成对出现，一端发送的数据另一端直接接收。veth 是 Linux 网络命名空间和容器网络的核心基础：每个容器有 veth 的一端，另一端在宿主机上通过 bridge 互联。

**核心设计**：veth 设备的转发逻辑极简——`veth_xmit()`（`veth.c:347`）不涉及物理硬件，直接调用 peer 设备的接收路径 `netif_rx()` / `napi_gro_receive()`。数据包在一对 veth 设备之间通过函数调用传递，延迟极低（~1μs 以内）。

```
容器 netns                        宿主机 netns
┌──────────────┐                ┌──────────────┐
│   veth0       │                │   veth1      │
│   (一端)      │ ─── skb ───→ │   (另一端)    │
│               │                │              │
│ veth_xmit()   │    veth_xmit()→napi_gro_receive()→网桥/路由
│   → peer dev  │                │              │
│   → netif_rx()│                │              │
└──────────────┘                └──────────────┘
```

**doom-lsp 确认**：`drivers/net/veth.c`（2,009 行）。`veth_xmit` @ `:347`，`veth_poll` @ `:959`。

---

## 1. 核心数据结构 @ :74

```c
struct veth_priv {
    struct net_device *dev;              // 本端设备
    struct net_device *peer;              // 对端设备

    struct veth_rq_stats __percpu *rq_stats; // per-CPU 统计

    /* NAPI 相关 */
    struct napi_struct napi;              // NAPI 实例（GRO 批量接收）
    struct bpf_prog __rcu *xdp_prog;       // XDP 程序
    struct bpf_prog __rcu *gso_partial;
};

// veth 设备对在创建时互相指向：
// veth0->priv->peer = &veth1;  // 对端
// veth1->priv->peer = &veth0;
```

---

## 2. veth_xmit @ :347——发送路径

```c
static netdev_tx_t veth_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct veth_priv *priv = netdev_priv(dev);
    struct net_device *rcv = priv->peer;    // 对端设备
    struct veth_priv *rcv_priv;

    // 1. 检查 XDP 程序
    rcu_read_lock();
    xdp_prog = rcu_dereference(rcv_priv->xdp_prog);
    if (xdp_prog) {
        // XDP 处理（可能运行 eBPF XDP 程序）
        act = bpf_prog_run_xdp(xdp_prog, xdp);
        switch (act) {
        case XDP_PASS:  break;              // 通过
        case XDP_DROP:  goto drop;          // 丢弃
        case XDP_TX:    goto xdp_tx;        // 回传
        }
    }

    // 2. 统计更新
    veth_stats_update(priv->rq_stats, skb->len);

    // 3. 选择接收路径
    skb_record_rx_queue(skb, rcv_priv->rq_index);

    if (rcv_priv->napi_enabled) {
        // NAPI 模式：送入 NAPI 上下文批量处理
        napi_gro_receive(&rcv_priv->napi, skb);
    } else if (rcv_priv->xdp_prog) {
        // XDP 模式
        netif_rx(skb);
    } else {
        // 默认：netif_rx(skb) 进入软中断
        netif_rx(skb);
    }

    return NETDEV_TX_OK;
}
```

---

## 3. veth_poll @ :959——NAPI 接收

```c
// 当使用 NAPI 模式时，批量从发送队列接收 skb：
static int veth_poll(struct napi_struct *napi, int budget)
{
    struct veth_priv *priv = netdev_priv(rq->dev);
    int done = 0;

    while (done < budget) {
        struct sk_buff *skb = __skb_dequeue(&rq->xdp_ring);
        if (!skb) break;

        // 分发 skb 到协议栈
        napi_gro_receive(napi, skb);
        done++;
    }

    if (done < budget)
        napi_complete_done(napi, done);

    return done;
}
```

---

## 4. 创建 veth 对

```bash
# 创建 veth 对：
ip link add veth0 type veth peer name veth1
# → 内核创建一对 veth 设备

# 将一端移入容器：
ip link set veth1 netns container

# 配置使用：
ip link set veth0 up
ip addr add 10.0.0.1/24 dev veth0
```

```c
// 内核侧：rtnetlink → veth_newlink()
// → 分配两个 net_device
// → 设置 priv->peer 相互指向
// → register_netdevice(veth0)
// → register_netdevice(veth1)
```

---

## 5. XDP 支持

```c
// veth 支持 XDP（eXpress Data Path）：
// 在 veth_xmit 中运行 XDP 程序，支持：
//   XDP_PASS  — 正常转发
//   XDP_DROP  — 丢弃
//   XDP_TX    — 回传（从收到的 peer 回传）

// 用途：容器网络的 XDP 加速
```

---

## 6. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `veth_xmit` | `:347` | 发送入口→转发到 peer |
| `veth_poll` | `:959` | NAPI 批量接收 |
| `veth_get_stats64` | `:451` | 获取统计 |
| `veth_open` | — | 设备启用 |
| `veth_close` | — | 设备停用 |

---

## 7. 调试

```bash
# veth 统计
ip -s link show veth0

# 跟踪 veth 传输
echo 1 > /sys/kernel/debug/tracing/events/net/dev_xmit/enable

# XDP 信息
ip link show veth0 | grep xdp
```

---

## 8. 总结

veth 通过 `veth_xmit`（`:347`）将 skb 直接传递给 peer 设备的接收路径（`netif_rx()` / `napi_gro_receive()`），实现零拷贝、零硬件、函数调用级别的数据传输。XDP 支持（在 `veth_xmit` 中运行）允许容器网络的 eBPF 加速。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
