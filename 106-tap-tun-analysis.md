# TAP/TUN — 虚拟网络设备深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/tun.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**TAP/TUN** 是虚拟网卡驱动：
- **TUN**：点对点设备（IP 层）
- **TAP**：以太网桥设备（MAC 层）

---

## 1. 核心数据结构

```c
// drivers/net/tun.c — tun_struct
struct tun_struct {
    struct net_device       *dev;           // 网络设备
    struct file             *file;          // 关联的文件
    struct socket           socket;         // socket
    struct ptr_ring          tx_ring;        // 发送队列
    unsigned int            flags;          // TUN_*

    // 过滤
    struct sock_fprog        filter;        // BPF 程序
    struct net               *net;           // 网络命名空间
};
```

---

## 2. tap_open — 打开设备

```c
// drivers/net/tun.c — tun_open
static int tun_open(struct inode *inode, struct file *file)
{
    struct tun_struct *tun;

    // 1. 分配 tun_struct
    tun = (struct tun_struct *)sk_alloc(...);

    // 2. 分配网络设备
    dev = alloc_netdev(sizeof(tun), "tun%d", NET_NAME_UNKNOWN, tun_setup);

    tun->dev = dev;
    tun->socket.file = file;
    file->private_data = tun;

    return 0;
}
```

---

## 3. 发送流程

```c
// drivers/net/tun.c — tun_sendmsg
static int tun_sendmsg(struct socket *sock, struct msghdr *m, size_t total)
{
    struct tun_struct *tun = container_of(sock, struct tun_struct, socket);
    struct sk_buff *skb;

    // 1. 分配 skb
    skb = sock_alloc_send_skb(...);

    // 2. 复制数据
    skb_put_data(skb, m->msg_iov->iov_base, total);

    // 3. 发送到网络栈
    netif_receive_skb(skb);

    return total;
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/tun.c` | `tun_struct`、`tun_open`、`tun_sendmsg` |