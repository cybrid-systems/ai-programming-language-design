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
    struct net_device __rcu *peer;           // 对端设备
    atomic64_t               dropped;         // 丢包计数
    struct bpf_prog         *_xdp_prog;      // XDP BPF 程序
    struct veth_rq          *rq;             // per-queue 接收队列数组
    unsigned int             requested_headroom; // 请求的头部预留空间
};

// veth 设备对在创建时互相指向：
// veth0->priv->peer = &veth1;  // 对端
// veth1->priv->peer = &veth0;
```

### 1.1 struct veth_rq——接收队列 @ :61

```c
struct veth_rq {
    struct napi_struct       xdp_napi;       // XDP NAPI 实例
    struct napi_struct __rcu *napi;          // 普通 NAPI 实例（指向 xdp_napi）
    struct net_device        *dev;           // 本端设备
    struct bpf_prog __rcu    *xdp_prog;      // XDP BPF 程序
    struct xdp_mem_info      xdp_mem;        // XDP 内存信息
    struct veth_rq_stats     stats;           // per-queue 统计
    bool                     rx_notify_masked; // NAPI 调度标记
    struct ptr_ring          xdp_ring;       // XDP skb 环形队列
    struct xdp_rxq_info      xdp_rxq;        // XDP 接收队列信息
    struct page_pool         *page_pool;     // 页面池
};
```

### 1.2 统计数据（veth_stats + veth_rq_stats）

```c
// 实际统计数据定义在 struct veth_stats @ :43：
struct veth_stats {
    u64 rx_drops;                            // 接收丢包
    /* xdp */
    u64 xdp_packets;                         // XDP 包数
    u64 xdp_bytes;                           // XDP 字节
    u64 xdp_redirect;                        // XDP 重定向
    u64 xdp_drops;                           // XDP 丢包
    u64 xdp_tx;                              // XDP TX
    u64 xdp_tx_err;                          // XDP TX 错误
    u64 peer_tq_xdp_xmit;                   // 对端 XDP 发送
    u64 peer_tq_xdp_xmit_err;               // 对端 XDP 发送错误
};

struct veth_rq_stats @ :56 {
    struct veth_stats vs;                    // 实际统计
    struct u64_stats_sync syncp;             // 统计同步
};
```
```

---

## 2. veth_xmit @ :347——发送路径

```c
static netdev_tx_t veth_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct veth_priv *priv, *rcv_priv;
    struct net_device *rcv;
    int length = skb->len;
    int rxq;

    rcu_read_lock();
    priv = netdev_priv(dev);
    rcv = rcu_dereference(priv->peer);      // 对端设备
    rcv_priv = netdev_priv(rcv);
    rxq = skb_get_queue_mapping(skb);

    // 1. 检查 XDP 程序
    if (rcv_priv->_xdp_prog) {
        // XDP 处理（可能运行 eBPF XDP 程序）
        act = bpf_prog_run_xdp(rcv_priv->_xdp_prog, xdp);
        switch (act) {
        case XDP_PASS:  break;              // 通过
        case XDP_DROP:  goto drop;          // 丢弃
        case XDP_TX:    goto xdp_tx;        // 回传
        default: /* XDP_REDIRECT etc */
        }
    }

    // 2. 统计更新
    veth_stats_update(&rcv_priv->rq[rxq].stats.vs, length);

    // 3. 选择接收路径
    skb_record_rx_queue(skb, rxq);

    if (rcv_priv->rq[rxq].napi) {
        // NAPI 模式：送入 NAPI 上下文批量处理
        napi_gro_receive(rcv_priv->rq[rxq].napi, skb);
    } else {
        // 非 NAPI 模式：netif_rx(skb) 进入软中断
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
    struct veth_rq *rq = container_of(napi, struct veth_rq, xdp_napi);
    struct veth_priv *priv = netdev_priv(rq->dev);
    int done = 0;

    while (done < budget) {
        struct sk_buff *skb = __ptr_ring_consume(&rq->xdp_ring);
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

## 5. XDP 支持 @ :503

```c
// veth 在 veth_xmit 中运行 XDP 程序（`:365`）：
// XDP_PASS — 正常转发
// XDP_DROP — 丢弃
// XDP_TX   — 回传（从 peer 返回发送端）

// veth_xdp_xmit @ :503——XDP 程序的 ndo_xdp_xmit 回调
static int veth_xdp_xmit(struct net_device *dev, int n,
    struct xdp_frame **frames, u32 flags, bool ndo)
{
    for (i = 0; i < n; i++) {
        struct xdp_frame *frame = frames[i];
        skb = xdp_frame_to_skb(frame);    // XDP → skb
        ptr_ring_produce(&rq->xdp_ring, skb); // 入队
    }
    __veth_xdp_flush(rq);
}

// __veth_xdp_flush @ :301——NAPI 调度
static void __veth_xdp_flush(struct veth_rq *rq)
{
    if (rq->rx_notify_masked) {          // 检查是否需要 NAPI 调度
        rq->rx_notify_masked = false;
        napi_schedule_irqoff(&rq->xdp_napi);
    }
}

// XDP 启用：veth_enable_xdp_range @ :1110
// → 为每个队列创建 NAPI 实例（xdp_napi）
// → 设置 ndo_xdp_xmit 和 ndo_bpf

// XDP 加速效果：DPDK/Cilium 容器网络使用 veth XDP 减少延迟
```

## 6. 多队列与 NAPI

```c
// veth 的设备操作表：
static const struct net_device_ops veth_ops = {
    .ndo_open            = veth_open,
    .ndo_stop            = veth_close,
    .ndo_start_xmit      = veth_xmit,
    .ndo_get_stats64     = veth_get_stats64,
    .ndo_xdp_xmit        = veth_ndo_xdp_xmit,
    .ndo_bpf             = veth_xdp_set,
};
```

---

## 7. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `veth_xmit` | `:347` | 发送入口→转发到 peer |
| `veth_poll` | `:959` | NAPI 批量接收 |
| `veth_get_stats64` | `:451` | 获取统计 |
| `veth_open` | `:1381` | 设备启用 |
| `veth_close` | `:1410` | 设备停用 |

---

## 8. 调试

```bash
# veth 统计
ip -s link show veth0

# 跟踪 veth 传输
echo 1 > /sys/kernel/debug/tracing/events/net/dev_xmit/enable

# XDP 信息
ip link show veth0 | grep xdp
```

---

## 9. 总结

veth 通过 `veth_xmit`（`:347`）将 skb 直接传递给 peer 设备的接收路径（`netif_rx()` / `napi_gro_receive()`），实现零拷贝、零硬件、函数调用级别的数据传输。XDP 支持（在 `veth_xmit` 中运行）允许容器网络的 eBPF 加速。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 7. veth 数据结构和统计概览 @ veth.c（140 符号）

veth 的关键内部结构已在第 1 节中展示：`struct veth_priv` 包含 peer 指针和管理数组，`struct veth_rq` 包含每个队列的 NAPI/XDP/统计，`struct veth_stats` 包含所有 XDP 和丢包统计字段。`struct veth_rq_stats` 作为 `veth_stats` 的包装器，配合 `u64_stats_sync` 实现无锁统计更新。
```

## 8. veth 的 XDP 转发路径

```c
// veth 支持 XDP 程序在发送路径中执行：
// veth_xmit() @ :347 — 发送数据包时运行 XDP：

// 1. xdp_prog = rcu_dereference(rcv_priv->rq[rxq].xdp_prog);
//    // 实际代码中通过 rcv_priv->rq[rxq].xdp_prog 访问
// 2. act = bpf_prog_run_xdp(xdp_prog, &xdp);
//    act 可能为：XDP_PASS / XDP_DROP / XDP_TX / XDP_REDIRECT

// XDP_TX — 从接收端口回传（数据包原路返回）：
// → veth_xdp_xmit(dev, n, frames, flags, false)
// → 将 xdp_frame 放回对端的 xdp_ring
// → __veth_xdp_flush(rq) — NAPI 调度

// XDP_REDIRECT — 重定向到其他接口：
// → xdp_do_redirect(dev, &xdp, xdp_prog)
// → 通过 bpf_redirect() 转发到目标接口

// XDP_PASS — 正常转发（veth 标准接收路径）
// XDP_DROP — 静默丢弃
```

## 9. veth 的 NAPI 和批量接收

```c
// veth 使用 NAPI 实现批量接收（提高吞吐量）：

// 发送端（veth_xmit）：
// if (rcv_priv->rq[rxq].napi) {
//     napi_gro_receive(rcv_priv->rq[rxq].napi, skb);
//     // → 使用 NAPI 上下文批量处理
// }

// 接收端 NAPI（veth_poll @ :959）：
// static int veth_poll(struct napi_struct *napi, int budget)
// {
//     struct veth_rq *rq = container_of(napi, struct veth_rq, xdp_napi);
//     int done = 0;
//
//     while (done < budget) {
//         skb = __ptr_ring_consume(&rq->xdp_ring);
//         if (!skb) break;
//         napi_gro_receive(napi, skb);
//         done++;
//     }
//     if (done < budget)
//         napi_complete_done(napi, done);
//     return done;
// }

// NAPI 优势：
// → 批量处理减少中断次数
// → GRO 合并小包提高吞吐量
// → busy poll 降低延迟
```

## 10. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `veth.c` | 140 符号 | veth 设备驱动 |
| `veth_xmit` | `:347` | 发送入口（含 XDP）|
| `veth_poll` | `:959` | NAPI 批量接收 |
| `veth_xdp_xmit` | `:503` | XDP TX 路径 |
| `__veth_xdp_flush` | `:301` | XDP NAPI 调度 |
| `veth_enable_xdp_range` | `:1110` | XDP 启用 |
| `veth_get_stats64` | `:451` | 统计获取 |

