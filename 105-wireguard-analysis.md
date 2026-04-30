# Linux Kernel WireGuard 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/wireguard/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. WireGuard 概述

**WireGuard** 是现代 VPN 协议，基于 **Noise 协议框架**，密码学安全、代码简洁（~4000 行），已合并入主线内核。

---

## 1. 核心数据结构

```c
// drivers/net/wireguard/device.h — wg_device
struct wg_device {
    char              name[IFNAMSIZ];
    struct net       *net;
    struct pubkey_hashtable   *peer_hashtable;  // 公钥→peer 哈希表
    struct allowedips_hashtable *allowedips;    // CIDR→peer 路由表
    struct list_head    peer_list;              // peer 链表
    struct noise_initiation  handshake;         // 握手机制
    struct work_struct  clear_handshake_work;
    struct sk_buff_head  handshake_queue;      // 握手包队列
};

// drivers/net/wireguard/peer.h — wg_peer
struct wg_peer {
    struct list_head        talk_list;          // peer 链表
    struct pubkey           *public_key;        // 对方公钥
    struct wg_device        *device;             // 所属设备
    struct endpoint         endpoint;           // 对方地址（IP:port）
    struct crypto           *tx_ids;            // 发送加密状态
    struct crypto           *rx_ids;             // 接收加密状态
    struct noise_handshake  handshake;          // 握手状态
};
```

---

## 2. 数据包加密流程

```
发送：
  1. 查找allowedips → 目标peer
  2. 检查handshake是否有效
  3. 如果需要，排队握手包
  4. 使用 chacha20poly1305 加密数据
  5. 发送加密包

接收：
  1. 解密包头 → session keys
  2. chacha20poly1305 解密
  3. 通过 wg0 接口递送
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/net/wireguard/device.c` | WireGuard 设备 |
| `drivers/net/wireguard/peer.c` | peer 管理 |
| `drivers/net/wireguard/noise.c` | Noise 握手 |
| `drivers/net/wireguard/send.c` | 数据包加密发送 |
