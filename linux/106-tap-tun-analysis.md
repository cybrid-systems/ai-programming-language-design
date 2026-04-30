# TAP/TUN — 虚拟网络设备深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/tun.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**TAP/TUN** 是虚拟网卡驱动，提供用户空间与内核网络栈的直通通道：
- **TUN**：点对点设备（IP 层），路由模式
- **TAP**：以太网桥设备（MAC 层），桥接模式

---

## 1. 核心数据结构

### 1.1 tun_struct — TUN 设备

```c
// drivers/net/tun.c — tun_struct
struct tun_struct {
    struct net_device       *dev;           // 网络设备
    struct socket           socket;         // 通用 socket（用于发送）
    struct tun_file         *tfile;         // 关联的 TUN 文件

    // 配置
    unsigned int            flags;          // TUN_*/IFF_* 标志
    //   IFF_TAP     = 0x0002   // TAP 模式
    //   IFF_NO_PI   = 0x1000   // 无协议信息头
    //   IFF_ONE_QUEUE = 0x2000 // 单队列模式
    //   IFF_VNET_HDR = 0x4000  // virtio 网络头

    // 过滤
    struct sock_fprog       *filter;        // BPF 程序
    struct ptr_ring          tx_ring;        // 发送环形队列

    // 统计
    atomic64_t              rx_packets;     // 接收包数
    atomic64_t              rx_bytes;       // 接收字节
    atomic64_t              tx_packets;     // 发送包数
    atomic64_t              tx_bytes;       // 发送字节
};
```

### 1.2 tun_page — TUN 页

```c
// drivers/net/tun.c — tun_page
struct tun_page {
    struct page             *page;          // 页
    int                     numa_node;     // NUMA 节点
};
```

---

## 2. 打开设备（tun_open）

```c
// drivers/net/tun.c — tun_open
static int tun_open(struct inode *inode, struct file *file)
{
    struct tun_file *tfile;
    struct tun_struct *tun;

    // 1. 分配 tun_file（per-file 数据）
    tfile = (struct tun_file *)sk_alloc(...);
    if (!tfile)
        return -ENOMEM;

    // 2. 初始化 socket
    init_waitqueue_head(&tfile->wq);
    tfile->socket.ops = &tun_sock_ops;

    // 3. 如果是第一次打开此设备，创建 tun_struct
    tun = __tun_get(tfile);
    if (!tun) {
        tun = alloc_netdev_mqs(sizeof(tfile), "tun%d", NET_NAME_UNKNOWN,
                               tun_setup, 1, 1);
        tun->tfile = tfile;
        tfile->tun = tun;
    }

    file->private_data = tfile;
    return 0;
}
```

---

## 3. 发送流程（tun_netdev_xmit）

```c
// drivers/net/tun.c — tun_netdev_xmit
static netdev_tx_t tun_netdev_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct tun_struct *tun = netdev_priv(dev);
    struct tun_file *tfile = tun->tfile;

    // 1. 增加统计
    dev->stats.tx_packets++;
    dev->stats.tx_bytes += skb->len;

    // 2. 如果 TUN_NO_PI，剥去协议信息头
    if (tun->flags & IFF_NO_PI) {
        // 用户只需要 IP 包，不需要 4 字节 PI 头
    }

    // 3. 如果设置了 XDP，执行 XDP 程序
    if (tun->xdp_prog) {
        struct xdp_buff xdp;
        xdp.data_hard_start = skb->head;
        xdp.data = skb->data;

        if (tun->xdp_prog->bpf_func(skb, &xdp) == XDP_PASS)
            goto send;
        else
            goto drop;
    }

send:
    // 4. 将 skb 放入接收队列
    skb->dev = dev;
    rcu_read_lock();
    skb_queue_tail(&tfile->sk->sk_receive_queue, skb);
    tfile->socket.sk->sk_data_ready(tfile->socket.sk);
    rcu_read_unlock();

    return NETDEV_TX_OK;

drop:
    dev_kfree_skb(skb);
    return NETDEV_TX_OK;
}
```

---

## 4. 用户空间读取（tun_do_read）

```c
// drivers/net/tun.c — tun_do_read
static ssize_t tun_do_read(struct tun_file *tfile, struct iov_iter *to,
                            int noblock, size_t count)
{
    struct tun_struct *tun = rcu_dereference(tfile->tun);
    struct sk_buff *skb;

    // 1. 非阻塞：尝试直接从接收队列获取
    skb = __skb_recv_datagram(&tfile->sk->sk_receive_queue,
                              noblock ? MSG_DONTWAIT : 0, &count, &idx);
    if (skb)
        return skb->len;  // 直接返回 skb 数据

    // 2. 阻塞：等待数据到达
    if (noblock)
        return -EAGAIN;

    // 3. 添加到等待队列
    add_wait_queue(&tfile->wq, wait);
    while (1) {
        if (signal_pending(current))
            break;
        set_current_state(TASK_INTERRUPTIBLE);
        skb = skb_recv_datagram(tfile->sk->sk_receive_queue, ...);
        if (skb)
            break;
        schedule();
    }
}
```

---

## 5. TAP vs TUN 对比

| 特性 | TAP | TUN |
|------|-----|-----|
| 层次 | 数据链路层（MAC） | 网络层（IP） |
| 收到 | 以太网帧 | IP 包 |
| 用途 | 桥接/虚拟机 | 路由/VPN |
| 用户数据 | Ethernet 帧 | IP 包 |
| tap2tap | 需要 bridge | 需要 route |

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/tun.c` | `struct tun_struct`、`tun_open`、`tun_netdev_xmit`、`tun_do_read` |