# Linux Kernel WireGuard 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/wireguard/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：Noise 协议、chacha20poly1305、握手、加密通道

---

## 0. WireGuard 概述

**WireGuard** 是现代 VPN 协议，基于 **Noise 协议框架**，代码量仅 ~4000 行，已合并入 Linux 主线。

---

## 1. 核心数据结构

### 1.1 wg_device — WireGuard 设备

```c
// drivers/net/wireguard/device.h — wg_device
struct wg_device {
    struct net              *net;
    struct crypt_queue      *encrypt_queue;   // 加密队列
    struct crypt_queue      *decrypt_queue;   // 解密队列
    struct pubkey_hashtable *pubkey_hashtable; // 公钥 → peer
    struct allowedips_hashtable *allowedips;   // CIDR → peer
    struct list_head        peer_list;        // peer 链表
    struct wg_peer          *self_device.peer; // 自身 peer
    struct noise_handshake  handshake;        // 握手机制
    struct work_struct      handshake_send_work; // 握手延迟工作
    struct pubkey           static_identity.our_secret; // 静态密钥
    struct pubkey           static_identity.our_public; // 静态公钥
    struct mutex            device_update_lock; // 设备锁
    int                     ifindex;
    char                    dev_name[IFNAMSIZ];
};
```

### 1.2 wg_peer — 对等体

```c
// drivers/net/wireguard/peer.h — wg_peer
struct wg_peer {
    struct wg_device            *device;          // 所属设备
    struct prev_queue            tx_queue;         // 发送队列
    struct prev_queue            rx_queue;         // 接收队列
    struct sk_buff_head          staged_packet_queue; // 待加密包
    int                          serial_work_cpu;   // 序列工作 CPU

    bool                         is_dead;
    struct noise_keypairs        keypairs;         // 密钥对
    struct endpoint              endpoint;         // 对方地址

    // 握手状态
    struct handshake handshake {
        struct noise_handshake hs;    // Noise 握手
        __u64                   last_handshake_jiffies; // 上次握手时间
        struct timer_list       handshake_timer;  // 握手超时定时器
        struct list_head        noise_handshake;  // 握手链表
    };

    // 统计
    struct peer_stat {
        u64                     tx_bytes;
        u64                     rx_bytes;
        atomic64_t              last_handshake_time;
    } stat;
};
```

---

## 2. 握手流程

```
1. 发送方创建 initiation（首次连接）：
   → noise_handshake_create_initiation()
   → HH = DH(prologue || local_ephemeral)
   → 发送 initiation

2. 接收方响应 response：
   → noise_handshake_create_response()
   → 发送 response

3. 双方计算 session keys：
   → chacha20poly1305_symmetric_session_keys()
   → 建立加密通道

4. 数据传输：
   → 使用 session keys 加密
   → chacha20poly1305_encrypt()
```

---

## 3. 数据包发送

```c
// drivers/net/wireguard/send.c — wg_packet_encrypt_worker
static void wg_packet_encrypt_worker(struct work_struct *work)
{
    struct crypt_queue *queue = container_of(work, struct crypt_queue, worker->work);
    struct sk_buff *skb;

    while ((skb = ptr_ring_consume(&queue->ring))) {
        struct wg_peer *peer = skb->peer;

        // 1. 获取当前密钥对
        keys = &peer->keypairs;

        // 2. 加密
        chacha20poly1305_encrypt(skb, keys->sending);

        // 3. 发送
        wg_packet_send(peer, skb);
    }
}
```

---

## 4. 参考

| 文件 | 函数 | 行 |
|------|------|-----|
| `drivers/net/wireguard/device.h` | `wg_device` | 设备结构 |
| `drivers/net/wireguard/peer.h` | `wg_peer` | peer 结构 |
| `drivers/net/wireguard/noise.c` | `noise_handshake_create_*` | 握手 |
| `drivers/net/wireguard/send.c` | `wg_packet_encrypt_worker` | 加密发送 |
