# wireguard — 安全 VPN 隧道深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/wireguard/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**WireGuard** 是现代轻量级 VPN 隧道协议，使用 Curve25519（椭圆曲线DH）、ChaCha20-Poly1305（加密）和 BLAKE2s（哈希）。

---

## 1. 核心数据结构

### 1.1 wg_device — WireGuard 设备

```c
// drivers/net/wireguard/device.h — wg_device
struct wg_device {
    struct net_device       *dev;           // 网络设备
    struct pubkey_bucket     *peer_hashtable; // 哈希表
    struct crypt_queue      *device_queue;   // 加密队列

    // 密钥
    struct noise_symmetric_key __percpu *keypair; // 当前密钥对
    __u32                   keypair_counter;    // 密钥轮换计数器

    // 接口
    struct list_head        peer_list;         // peer 链表
    struct mutex            device_update_lock;  // 更新锁
};
```

### 1.2 wg_peer — 对等节点

```c
// drivers/net/wireguard/peer.h — wg_peer
struct wg_peer {
    struct list_head        peer_list;        // 接入设备列表

    // 密钥
    struct pubkey           *public_key;        // 对方公钥
    struct noise_handshake *handshake;         // 握手机制

    // 隧道
    struct endpoint         endpoint;          // 对方地址
    struct allowedip        *allowedips_head;   // 允许的 IP 范围

    // 计数器
    atomic64_t              rx_bytes;           // 接收字节
    atomic64_t              tx_bytes;           // 发送字节
    atomic64_t              last_handshake;     // 上次握手时间
};
```

---

## 2. 握手流程

```c
// drivers/net/wireguard/noise.c — noise_handshake_process
int noise_handshake_process(struct wg_peer *peer, struct sk_buff *skb)
{
    // 1. 接收对方的消息（包含临时公钥）
    // 2. 执行 Curve25519 ECDH
    // 3. 派生共享密钥
    // 4. 验证 cookie
    // 5. 建立加密隧道
}
```

---

## 3. 数据包加密

```c
// drivers/net/wireguard/send.c — wg_packet_encrypt
int wg_packet_encrypt(struct sk_buff *skb, struct wg_peer *peer)
{
    // 1. 获取当前密钥对
    struct crypt_queue *q = &peer->tx_queue;

    // 2. ChaCha20-Poly1305 加密
    chacha20_poly1305_encrypt(skb->data, peer->keypair->sending);

    // 3. 添加 WireGuard 头（计数器、对方接收）
    wg_append_header(skb, peer->keypair->sending.counter);
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/wireguard/device.h` | `wg_device` |
| `drivers/net/wireguard/peer.h` | `wg_peer` |
| `drivers/net/wireguard/noise.c` | `noise_handshake_process` |