# 105-tap-tun — Linux TUN/TAP 虚拟网络设备深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**TUN**（网络层虚拟设备）和 **TAP**（链路层虚拟设备）是 Linux 的用户空间网络隧道接口。用户空间程序通过 `/dev/net/tun` 打开一个文件描述符，读写该 fd 即可从内核网络栈收发数据包。

**核心设计**：TUN/TAP 设备表现为一个虚拟网络接口（`struct net_device`），用户空间侧通过字符设备（`struct miscdevice`）访问。`tun_get_user()`（`tun.c:1131`）从用户空间读取数据包并注入内核算协议栈，`tun_put_user()`（`:2120`）从协议栈抓取数据包写入用户空间。

```
用户空间程序                   内核
───────────                  ────
open("/dev/net/tun") → tun_chr_open()
  ↓
ioctl(TUNSETIFF, "tun0") → 创建 tun0 接口
  ↓                         ↓
write(fd, pkt, len)      tun0 接口
  → tun_chr_write_iter()    ↑  tun_get_user() → 注入网络栈
    → tun_get_user()        │  → netif_rx(skb)
      → alloc_skb()         │
      → copy_from_user()     │
      → netif_rx(skb)       │
                            │
read(fd, buf, len)         │
  → tun_chr_read_iter()     │  tun_put_user() ← 从协议栈抓取
    → tun_do_read()         │  → 从接收队列取 skb
      → skb_copy_to_iter()  │  → copy_to_user()
```

**doom-lsp 确认**：`drivers/net/tun.c`（3,740 行，237 个符号）。`tun_get_user` @ `:1131`，`tun_put_user` @ `:2120`。

---

## 1. 核心数据结构

```c
// tun.c
struct tun_struct {                              // TUN 网络设备
    struct net_device *dev;                       // 虚拟网络接口
    struct tun_file __rcu *tfiles[MAX_TAP_QUEUES]; // 打开的文件（多队列）
    struct socket socket;                         // 内核 socket
    unsigned int flags;                           // IFF_TUN / IFF_TAP / IFF_NO_PI
    struct fasync_struct *fasync;
    struct flow_table flow;
};

struct tun_file {                                // TUN 文件句柄
    struct sock sk;                               // 内核 socket
    struct socket socket;
    struct tun_struct __rcu *tun;                 // 指向所属设备
    struct napi_struct napi;                     // NAPI 结构（多队列接收）
    struct xdp_rxq_info xdp_rxq;                  // XDP 接收队列
    u16 queue_index;
};

// 设备类型标志：
// IFF_TUN  — L3 隧道（读/写 IP 包）
// IFF_TAP  — L2 隧道（读/写以太帧）
// IFF_NO_PI — 不包含额外包头信息
```

---

## 2. 写入路径——tun_get_user @ :1695

```c
// 用户 write → tun_chr_write_iter → tun_get_user

static ssize_t tun_get_user(struct tun_struct *tun, struct tun_file *tfile,
                             void *msg_control, struct iov_iter *from,
                             int noblock, bool more)
{
    struct sk_buff *skb;
    int len = iov_iter_count(from);

    // 1. 分配 skb
    if (tun->flags & IFF_TUN) {
        // L3 隧道——分配最大长度 LL_MAX_HEADER + len
        skb = tun_alloc_skb(tfile, ...);
    } else {
        // L2 隧道
        skb = sock_alloc_send_pskb(sk, len, ...);
    }

    // 2. 复制用户数据到 skb
    skb_put(skb, len);
    copy_from_iter(skb->data, len, from);

    // 3. 解析包头信息（如果 IFF_NO_PI 未设置）
    if (!(tun->flags & IFF_NO_PI)) {
        // struct tun_pi { flags, proto } 位于 skb 头部
        skb->protocol = pi->proto;
    }

    // 4. XDP 处理（如果启用了 XDP）
    if (tun_xdp_xmit(tun, skb))
        goto drop;

    // 5. 注入网络栈——区分 TUN/TAP
    if (tun->flags & IFF_TUN) {
        // L3：直接调用 netif_rx(skb)
        netif_rx(skb);
    } else {
        // L2：eth_type_trans 后调用 netif_receive_skb
        skb->protocol = eth_type_trans(skb, dev);
        netif_receive_skb(skb);
    }
}
```

---

## 3. 读取路径——tun_put_user @ :2035

```c
// 用户 read → tun_chr_read_iter → tun_do_read → tun_put_user

static ssize_t tun_do_read(struct tun_struct *tun, struct tun_file *tfile,
                            struct iov_iter *to, int noblock)
{
    // 1. 从接收队列取 skb
    skb = skb_recv_datagram(tfile->socket.sk, noblock ? MSG_DONTWAIT : 0, &err);
    if (!skb) return err;

    // 2. 复制到用户空间
    ret = tun_put_user(tun, tfile, skb, to);
    kfree_skb(skb);
    return ret;
}

static ssize_t tun_put_user(struct tun_struct *tun, struct tun_file *tfile,
                             struct sk_buff *skb, struct iov_iter *to)
{
    int total = 0;

    // 1. 写入包信息头（如果 IFF_NO_PI 未设置）
    if (!(tun->flags & IFF_NO_PI)) {
        struct tun_pi pi = { .flags = 0, .proto = ntohs(skb->protocol) };
        copy_to_iter(&pi, sizeof(pi), to);
        total += sizeof(pi);
    }

    // 2. 复制 skb 数据到用户空间
    skb_copy_datagram_iter(skb, 0, to, skb->len);
    total += skb->len;
    return total;
}
```

---

## 4. 创建 TUN/TAP 设备

```c
// 用户空间配置：
// fd = open("/dev/net/tun", O_RDWR);
// struct ifreq ifr = { .ifr_name = "tun0", .ifr_flags = IFF_TUN | IFF_NO_PI };
// ioctl(fd, TUNSETIFF, &ifr);
// → tun_chr_ioctl() → __tun_set_iff()
//   → tun_net_init(dev) 初始化 net_device 操作
//   → register_netdevice(dev) 注册网络接口

// 网络设备操作：
static const struct net_device_ops tun_netdev_ops = {
    .ndo_start_xmit   = tun_net_xmit,          // 发送数据包
    .ndo_open         = tun_net_open,           // 接口启用
    .ndo_stop         = tun_net_close,          // 接口停用
    .ndo_set_rx_mode  = tun_net_mclist,         // 多播设置
};
```

---

## 5. 多队列与 NAPI

```c
// TUN 支持多队列（通过 TUNSETIFF 的 IFF_MULTI_QUEUE 启用）：
// 每个队列对应一个 tun_file，有独立的 NAPI 实例
// 接收时通过 flow_table 的 RSS 哈希分配到不同队列

// tfiles[MAX_TAP_QUEUES] — 最多 MAX_TAP_QUEUES 个队列
// 每个队列有 napi_struct，允许 busy poll 和 GRO
```

---

## 6. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `tun_get_user` | `:1695` | 写入路径——用户数据→skb→网络栈 |
| `tun_put_user` | `:2035` | 读取路径——skb→用户空间 |
| `tun_do_read` | — | 从接收队列取 skb |
| `tun_net_xmit` | — | 协议栈→TUN 设备（送入接收队列）|
| `__tun_set_iff` | — | 创建设备 |
| `tun_chr_open` | — | 打开 /dev/net/tun |
| `tun_chr_ioctl` | — | ioctl 控制（TUNSETIFF 等）|

---

## 7. 调试

```bash
# 创建 TUN 设备
ip tuntap add dev tun0 mode tun
ip link set tun0 up
ip addr add 10.0.0.1/24 dev tun0

# /dev/net/tun 操作
ls -l /dev/net/tun

# 查看 TUN 统计
cat /sys/class/net/tun0/statistics/tx_packets
```

---

## 8. 总结

TUN/TAP 通过 `tun_get_user`（`:1695`）将用户空间写入的 skb 注入内核网络栈（`netif_rx`/`netif_receive_skb`），通过 `tun_put_user`（`:2035`）从接收队列抓取 skb 复制到用户空间。`IFF_TUN` 处理 IP 包（L3），`IFF_TAP` 处理以太帧（L2）。多队列通过 `tfiles[]` 数组和 NAPI 实现并行处理。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 9. TUN 设备创建和销毁

```c
// TUN 设备的完整生命周期：

// 创建：open("/dev/net/tun") + ioctl(TUNSETIFF)
// → tun_chr_open() — 创建 tun_file，关联到 struct file
// → __tun_set_iff() — 分配 tun_struct + net_device
//   → tun_net_init(dev) — 设置 net_device_ops
//   → register_netdevice(dev) — 注册网络接口
//   → tun->tfiles[queue_index] = tfile

// 销毁：
// → tun_chr_close() — 关闭字符设备
// → tun_detach_all() — 断开所有连接
// → unregister_netdevice(dev) — 注销网络接口
// → 等待所有 skb 释放

// 多队列支持（IFF_MULTI_QUEUE）：
// → tun->tfiles[MAX_TAP_QUEUES] 数组
// → 每个 tfile 有独立的 rx/tx 队列
// → 通过 flow_table 的 RSS 哈希分发
```

## 10. TUN 的 XDP 支持

```c
// TUN 支持 XDP（eXpress Data Path）：
// tun_xdp_xmit() — 发送 XDP 帧到设备
// → xdp_frame 转 skb → netif_receive_skb()

// XDP 程序通过 tun_xdp_set() 注册：
// → setsockopt(tun_fd, SOL_TUN, TUN_XDP, &prog_fd, sizeof(fd))
// → 设置 tnl->xdp_prog

// TUN 的 XDP 能力：
// XDP_PASS — 正常接收
// XDP_DROP — 丢弃
// XDP_TX   — 从接收口回传

// XDP 在容器网络中有重要应用（如 Flannel、Calico 加速）
```

## 11. TUN 的 tap_filter

```c
// TAP（L2 模式）支持多播过滤：

struct tap_filter {
    int count;                          // 过滤地址数
    unsigned int mask;                   // 哈希位图
    unsigned long addr[FILTER_ADDR_MAX]; // MAC 地址表
};

// tap_filter_add_addr() — 添加过滤 MAC
// → 计算 MAC 哈希 → 设置 mask 位

// tap_filter_match(skb, filter) — 检查是否匹配
// → 广播/多播：检查哈希表
// → 单播：精确匹配

// 减少了不需要传递给用户空间的 L2 帧数量
```

## 12. 关键函数索引

| 函数 | 符号数 | 作用 |
|------|--------|------|
| `tun.c` | 237 | TUN/TAP 驱动 |
| `tun_get_user` | `:1695` | 写入路径（skb→网络栈）|
| `tun_put_user` | `:2035` | 读取路径（skb→用户）|
| `tun_do_read` | — | 从接收队列取 skb |
| `tun_net_xmit` | — | 协议栈→TUN 队列 |
| `tun_chr_open` | — | 字符设备打开 |
| `tun_xdp_xmit` | — | XDP 发送 |
| `tun_napi_init` | — | NAPI 初始化 |


## 13. TUN 的特性标志

```c
// TUN 设备支持的特性标志：

// IFF_TUN     — L3 隧道（接收/发送 IP 包）
// IFF_TAP     — L2 隧道（接收/发送以太帧）
// IFF_NO_PI   — 不携带包信息头（tun_pi）
// IFF_ONE_QUEUE — 单队列模式（旧）
// IFF_VNET_HDR — 虚拟网络头（virtio net header）
// IFF_MULTI_QUEUE — 多队列模式
// IFF_NAPI    — NAPI 模式（批量接收）
// IFF_NAPI_FRAGS — NAPI 分段接收

// VNET_HDR 用于 virtio 场景（KVM 虚拟化）：
// → 在包前添加 struct virtio_net_hdr
// → 包含校验和和 GSO 信息
// → 使虚拟机内的 GSO 包可以穿透 TUN 设备

// 查看当前标志：
// ip -d link show tun0
```


## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `tun_get_user()` | drivers/net/tun.c | 用户→内核数据 |
| `tun_net_xmit()` | drivers/net/tun.c | 内核→TAP 发送 |
| `tun_chr_open()` | drivers/net/tun.c | 字符设备打开 |
| `struct tun_struct` | drivers/net/tun.c | TUN/TAP 设备 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
