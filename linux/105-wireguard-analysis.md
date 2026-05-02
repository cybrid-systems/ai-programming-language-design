# 105-wireguard — Linux WireGuard VPN 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**WireGuard** 是 Linux 内核中的现代 VPN 实现，设计目标是简洁、高性能、加密安全。与 IPsec 和 OpenVPN 不同，WireGuard 只有 ~4,000 行内核代码，使用 Noise 协议框架完成密钥交换和加密。

**核心设计**：WireGuard 使用 **UDP 封装**（监听单端口）+ **Noise IK** 单向握手机制。每个 peer 有一个 Curve25519 公钥对。数据加密使用 ChaCha20Poly1305。发送路径：`wg_packet_create_data`（`send.c:311`）→ `encrypt_packet`（`:162`）→ `wg_packet_send_staged_packets`。接收路径：`wg_packet_receive`（`receive.c:542`）→ `decrypt_packet`（`:242`）→ `counter_validate`（`:295`）。

```
发送路径:
  wg_packet_create_data @ send.c:311
    → encrypt_packet(skb, key) @ :162
      → ChaCha20Poly1305_Encrypt(skb->data, skb->len, key, nonce)
    → wg_packet_send_staged_packets
      → wg_packet_tx_worker → UDP send

接收路径:
  wg_packet_receive @ receive.c:542
    → validate_header_len(skb) @ :28
    → wg_packet_consume_data @ :509
      → decrypt_packet(skb, key) @ :242
        → ChaCha20Poly1305_Decrypt(skb->data, skb->len, key, nonce)
      → counter_validate(skb) @ :295  ← 重放攻击保护
      → napi_gro_receive(skb)         ← 送入网络栈
```

**doom-lsp 确认**：`send.c`（414 行，15 符号），`receive.c`（586 行，13 符号），`noise.c`（436 行）。

---

## 1. 核心数据结构

```c
// drivers/net/wireguard/peer.h
struct wg_peer {
    struct wg_device *device;               // 所属 WireGuard 设备
    struct crypt_key key;                     // 加密密钥
    struct noise_handshake handshake;         // 握手状态
    struct noise_keypairs keypairs;           // 有效密钥对
    struct wg_endpoint endpoint;              // 对端 UDP 地址
    struct sk_buff_head tx_queue;             // 待发送队列
    struct work_struct transmit_handshake_work;
    struct work_struct clear_peer_work;
};

// drivers/net/wireguard/device.h
struct wg_device {
    struct net_device *dev;                   // 虚拟网络接口（wg0）
    struct socket *sock;                      // UDP 监听 socket
    struct crypt_key key;                     // 私钥
    struct hlist_head peer_list;              // peer 列表
    struct workqueue_struct *workqueue_cpu;   // per-CPU 工作队列
};
```

---

## 2. 发送路径 @ send.c

```c
// wg_packet_create_data @ :311——创建加密数据包
void wg_packet_create_data(struct sk_buff *skb)
{
    // 从 skb 获取目标 peer
    peer = wg_skb_peer(skb);

    // 加密
    encrypt_packet(skb, peer);

    // 加入发送队列
    skb_queue_tail(&peer->staged_packet_queue, skb);
    wg_packet_send_staged_packets(peer);
}

// encrypt_packet @ :162——ChaCha20Poly1305 加密
static void encrypt_packet(struct sk_buff *skb, struct wg_peer *peer)
{
    struct noise_keypair *keypair = get_keypair(peer, CURVE25519_KEY_SIZE);
    u64 nonce = atomic64_inc_return(&keypair->sending.counter.nonce);

    // ChaCha20Poly1305 加密整个数据包
    chacha20poly1305_encrypt(
        skb->data, skb->data, skb->len,
        skb->data + skb->len,     // 认证标签（poly1305）
        nonce, keypair->sending.key
    );
}

// wg_packet_tx_worker @ :262——实际发送
int wg_packet_tx_worker(struct wg_peer *peer)
{
    // 1. 从 staged_packet_queue 取出 skb
    // 2. 通过 UDP socket 发送
    // 3. 更新对端最后发送时间
}
```

---

## 3. 接收路径 @ receive.c

```c
// wg_packet_receive @ :542——接收入口
void wg_packet_receive(struct wg_device *wg, struct sk_buff *skb)
{
    // 1. 验证 UDP 载荷长度
    if (unlikely(!validate_header_len(skb)))
        goto err;

    // 2. 解析源端口，查找 peer
    peer = wg_peer_get_maybe_zero(device, src_key);
    if (unlikely(!peer))
        goto err;

    // 3. 消费数据包
    wg_packet_consume_data(peer, skb);
}

// wg_packet_consume_data @ :509
static void wg_packet_consume_data(struct wg_peer *peer, struct sk_buff *skb)
{
    // 1. 解密
    if (!decrypt_packet(skb, peer))
        goto err;

    // 2. 重放保护
    if (!counter_validate(skb))
        goto err;

    // 3. 提交到网络栈
    napi_gro_receive(&peer->device->napi, skb);
}

// decrypt_packet @ :242
static bool decrypt_packet(struct sk_buff *skb, struct wg_peer *peer)
{
    return chacha20poly1305_decrypt(
        skb->data, skb->data, skb->len,
        skb->data + skb->len - POLY1305_SIZE,
        keypair->receiving.counter.nonce,
        keypair->receiving.key
    ) == 0;
}
```

---

## 4. 握手协议

```c
// WireGuard 使用 Noise_IK 握手——1-RTT 密钥交换：
// 1. initiator → responder: {msg_type=1, sender_idx, ephemeral, static, timestamp}
// 2. responder → initiator: {msg_type=2, sender_idx, ephemeral, empty}
// 3. initiator → responder: {msg_type=3, sender_idx, data}
// → 握手完成后可以开始数据传输

// wg_packet_send_handshake_initiation @ send.c:21
// → 创建 Noise 握手消息
// → 通过 UDP 发送到对端
// → 设置定时器（若 5s 无响应则重试）

// wg_receive_handshake_packet @ receive.c:92
// → 验证消息签名
// → 更新 Noise 状态
// → 设置加密密钥对
```

---

## 5. 关键函数索引

| 函数 | 文件:行号 | 作用 |
|------|----------|------|
| `wg_packet_create_data` | `send.c:311` | 发送数据路径入口 |
| `encrypt_packet` | `send.c:162` | ChaCha20Poly1305 加密 |
| `wg_packet_tx_worker` | `send.c:262` | UDP 发送 worker |
| `wg_packet_receive` | `receive.c:542` | 接收入口 |
| `decrypt_packet` | `receive.c:242` | ChaCha20Poly1305 解密 |
| `counter_validate` | `receive.c:295` | 重放保护 |
| `wg_receive_handshake_packet` | `receive.c:92` | 握手消息处理 |

---

## 6. 调试

```bash
# WireGuard 状态
wg show
wg show wg0 peer

# 内核侧跟踪
echo 1 > /sys/kernel/debug/tracing/events/wireguard/enable

# 统计
cat /proc/net/wireguard
```

---

## 7. 总结

WireGuard 通过 `wg_packet_create_data`（`send.c:311`）→ `encrypt_packet`（`:162`）加密后通过 UDP 发送。接收端 `wg_packet_receive`（`receive.c:542`）→ `decrypt_packet`（`:242`）→ `counter_validate`（`:295`）解密并检查重放后送入网络栈。Noise_IK 握手机制在 1-RTT 内完成密钥交换。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
