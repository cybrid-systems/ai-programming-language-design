# Linux Kernel TAP / TUN 虚拟网络设备 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/tun.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. TUN vs TAP

| 类型 | 说明 |
|------|------|
| **TUN** | 模拟网络层设备，处理 IP 数据包（三层）|
| **TAP** | 模拟以太网设备，处理以太网帧（二层）|

VPN 软件（如 WireGuard、OpenVPN）用 TUN；虚拟机网桥（如 QEMU）用 TAP。

---

## 1. 核心结构

```c
// drivers/net/tun.c — tun_file
struct tun_file {
    struct socket         socket;           // 暴露给用户空间的 socket
    struct tun_struct    *tun;             // tun 设备
    struct sk_buff       *skb;             // 堆积的数据包
    struct list_head      list;             // 全局链表
    unsigned int           flags;           // TUN/TAP flags
    int                    vnet_hdr_sz;    // virtio_net_hdr 大小
};

// drivers/net/tun.c — tun_struct
struct tun_struct {
    struct net_device      dev;             // 网络设备
    struct tun_file       **tfiles;        // 关联的 tun_file 数组
    unsigned int           numqueues;       // 队列数
    struct ptr_ring       *tx_array;       // 发送环
    unsigned long          flags;           // IFF_TUN / IFF_TAP
    char                   ifname[IFNAMSIZ];
};
```

---

## 2. 数据包流程

```c
// 用户空间读取（read()）：
//   → tun_chr_aio_read() → 从 tun->tx_array 取 skb
//   → copy_to_user() → 用户空间收到 IP 包（tun）或以太网帧（tap）

// 用户空间写入（write()）：
//   → tun_chr_aio_write()
//   → netif_rx(skb) → 进入协议栈
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/net/tun.c` | `tun_chr_aio_read`、`tun_chr_aio_write`、`tun_net_open` |
