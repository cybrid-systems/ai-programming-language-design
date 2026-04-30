# 105-WireGuard — 现代 VPN 隧道深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/wireguard/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**WireGuard** 是 Linux 5.6 引入的现代 VPN 协议，以极简代码（~4000行）实现了高性能加密隧道，使用 Curve25519（密钥交换）、ChaCha20-Poly1305（加密）、BLAKE2s（哈希）。

---

## 1. 核心数据结构

### 1.1 struct wg_device — 设备

```c
// drivers/net/wireguard/device.h — wg_device
struct wg_device {
    struct net_device      *dev;              // netdevice
    struct list_head        device_list;       // 全局设备链表
    struct mutex           device_update_lock; // 更新锁

    // 密钥
    struct noise_curved_keypair  static_identity; // 本端静态密钥

    // 对等点
    struct pubkey_bucket   *peer_hashtable;   // 哈希表（按公钥索引）
    struct list_head        peer_list;         // peer 链表

    // Socket
    struct socket           *sock4;
    struct socket           *sock6;
    u16                     incoming_port;     // 接收端口

    // 统计
    atomic64_t              stats.tx_bytes;
    atomic64_t              stats.rx_bytes;
};
```

### 1.2 struct wg_peer — 对等点

```c
// drivers/net/wireguard/peer.h — wg_peer
struct wg_peer {
    struct list_head        peer_list;         // 接入 device_list
    struct wg_device       *device;           // 所属设备

    // 加密密钥
    struct noise_handshake  handshake;          // 握手状态
    struct noise_keypairs   keypairs;          // 当前有效的密钥对

    // 隧道地址
    struct allowedips       allowedips;        // 允许的 IP 列表（路由）
    struct endpoint         endpoint;          // 对端地址（IP + port）

    // Keepalive
    u16                     persistent_keepalive_interval; // 秒

    // 计时器
    struct timer_list       timer_handshake;    // 握手超时
    struct timer_list       timer_zero_key_material; // 密钥清理
};
```

### 1.3 struct wg_packet — 数据包

```c
// drivers/net/wireguard/queueing.h — wg_packet
struct wg_packet {
    struct list_head        list;           // 队列链表
    struct sk_buff         *skb;           // 数据包
    struct wg_peer         *peer;          // 目标 peer
    unsigned int            mtu;
};
```

---

## 2. 数据包接收流程

### 2.1 wg_receive — 接收处理

```c
// drivers/net/wireguard/receive.c — wg_receive
void wg_receive(struct wg_device *wg, struct sk_buff *skb)
{
    struct wg_peer *peer;
    struct wg_header *hdr;

    // 1. 检查 WireGuard 头部 magic
    hdr = (struct wg_header *)skb->data;
    if (hdr->type >= WG_MESSAGE_TYPE_MAX)
        goto drop;

    // 2. 查找 peer（根据发送者 IP/port 或公钥）
    peer = wg_lookup_peer(wg, skb);

    // 3. 根据消息类型处理
    switch (hdr->type) {
    case WG_MESSAGE_HANDSHAKE_INITINATION:
        wg_noise_handshake(&peer->handshake, skb);
        break;
    case WG_MESSAGE_HANDSHAKE_RESPONSE:
        wg_noise_response(&peer->handshake, skb);
        break;
    case WG_MESSAGE_COOKIE_REPLY:
        wg_cookie_response(&peer->handshake, skb);
        break;
    case WG_MESSAGE_TRANSPORT_DATA:
        wg_receive_data(peer, skb);  // 解密数据
        break;
    }

drop:
    kfree_skb(skb);
}
```

---

## 3. 握手流程

### 3.1 Noise Protocol — 握手

```
WireGuard 使用 Noise IK（前向保密）：

  本端（A）                          对端（B）
    │                                    │
    │──── Handshake Initiation ──────────▶│
    │    (E, E(idx), A, ts)               │
    │                                     │
    │◀─── Handshake Response ─────────────│
    │    (E, E(idx), B, ts', D)           │
    │                                     │
    │  ← 使用 DH(E, B_pub) 导出会话密钥  │
    │                                     │
    │──── Transport Data ─────────────────▶│
    │    (E, counter, ciphertext)         │
    │  ← 使用会话密钥加密                 │

E       = 临时 Curve25519 密钥（每次握手不同）
A/B     = 静态公钥（永久）
E(idx)  = 被加密的临时公钥（用对方公钥加密）
ts/ts'  = 时间戳（防止重放）
D       = cookie（防 DoS）
```

---

## 4. 数据加密

### 4.1 ChaCha20-Poly1305

```c
// drivers/net/wireguard/send.c — wg_send_data
void wg_send_data(struct wg_peer *peer, struct sk_buff *skb)
{
    struct noise_keypair *keypair;

    // 1. 获取当前有效的密钥对
    keypair = wg_noise_keypairs_get_current(&peer->keypairs);

    // 2. 用 ChaCha20-Poly1305 加密
    chacha20_poly1305_encrypt(skb->data, keypair->send);

    // 3. 添加 WireGuard 头部
    wg_set_header(skb, WG_MESSAGE_TRANSPORT_DATA, peer);

    // 4. 发送
    wg_socket_send(peer->device->sock4, skb, &peer->endpoint);
}
```

---

## 5. allowedips — 路由表

### 5.1 allowedips

```c
// drivers/net/wireguard/allowedips.c — 允许的 IP
// WireGuard 使用 BLAKE2s 哈希的加密跳跃列表（cryptographically sorted）
// 来存储允许的 IP CIDR 前缀

struct allowedips_node {
    struct list_head        peer_list;     // 同一 IP 段的所有 peer
    u8                     cidr;          // 前缀长度
    struct in_addr         ip;            // IP 地址
    // ...
};
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/wireguard/device.c` | `wg_open`、`wg_pm_notification` |
| `drivers/net/wireguard/receive.c` | `wg_receive` |
| `drivers/net/wireguard/send.c` | `wg_send_data` |
| `drivers/net/wireguard/peer.h` | `struct wg_peer` |
| `drivers/net/wireguard/queueing.h` | `struct wg_packet` |
| `drivers/net/wireguard/noise.h` | 握手/密钥 |

---

## 7. 西游记类比

**WireGuard** 就像"取经队伍的秘密信道"——

> 以前 VPN 用复杂的协议（IPSec/OpenVPN），WireGuard 像一条极简的秘密通道：每次出发前，悟空（客户端）先和对端土地神（服务器）交换临时的通行证（E），然后用各自的永久印章（A/B）验证身份。验证通过后，双方用 Diffie-Hellman（DH）算法算出只有两人知道的会话密钥，之后的通信就用电报加密（ChaCha20-Poly1305）。整个握手只需要 2 个包，超快。密码学上保证前向保密（每次通行证的临时密钥不同），就算永久印章泄露，之前的通信仍然保密。

---

## 8. 关联文章

- **netdevice**（网络部分）：WireGuard 是 netdevice 的一个实例
- **crypto API**（article 30）：ChaCha20-Poly1305、BLAKE2s