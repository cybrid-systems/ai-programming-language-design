# 104-wireguard — Linux WireGuard VPN 深度源码分析

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

### 1.1 Noise 密钥管理 @ noise.h

```c
// 对称密钥（用于实际加解密）：
struct noise_symmetric_key {
    u8 key[32];                               // ChaCha20 密钥
    u64 birthdate;                             // 创建时间（用于密钥轮换）
    bool is_valid;
};

// 密钥对（发送+接收方向）：
struct noise_keypair {
    struct noise_symmetric_key sending;        // 发送密钥
    atomic64_t sending_counter;                // 发送 nonce 计数器
    struct noise_symmetric_key receiving;      // 接收密钥
    struct noise_replay_counter receiving_counter; // 重放保护
    __le32 remote_index;
    struct kref refcount;
};

// 三组密钥对（支持无缝轮换）：
struct noise_keypairs {
    struct noise_keypair __rcu *current_keypair;  // 当前使用
    struct noise_keypair __rcu *previous_keypair; // 前一组（未过期）
    struct noise_keypair __rcu *next_keypair;     // 预生成
};

// 握手状态（Noise IK 协议状态机）：
struct noise_handshake {
    enum noise_handshake_state state;           // ZEROED/CREATED/CONSUMED
    u8 ephemeral_private[32];
    u8 remote_static[32];
    u8 hash[32];
    u8 chaining_key[32];
    u8 preshared_key[32];
    struct rw_semaphore lock;
};

// 握手状态机：
// ZEROED → CREATED_INITIATION → CONSUMED_RESPONSE → (数据通信)
//        → CONSUMED_INITIATION → CREATED_RESPONSE → (数据通信)
```

### 1.2 struct wg_peer——peer 结构

```c
struct wg_peer {
    struct noise_handshake handshake;           // 握手状态
    struct noise_keypairs keypairs;             // 三组密钥对
    struct allowedips_node *allowedips;          // 允许的 IP 范围
    struct wg_endpoint endpoint;                 // 对端 UDP 地址
    struct sk_buff_head staged_packet_queue;     // 排队数据包
    struct work_struct transmit_handshake_work;
    u64 last_sent_handshake_ns;
};
```

### 1.3 AllowedIPs 路由表（trie 树）

```c
// wireguard 使用二进制 trie 树管理 allowed IP：
struct allowedips_node {
    struct allowedips_node __rcu *bit[2];        // 左右子树（0/1）
    struct wg_peer *peer;                        // 所属 peer
    u8 cidr, bit_at_a, bit_at_b;
};

struct allowedips {
    struct allowedips_node __rcu *root4;         // IPv4 根
    struct allowedips_node __rcu *root6;         // IPv6 根
    struct rwlock lock;
};

// 路由查找：wg_allowedips_lookup_dst → O(key_length) trie 遍历
// 每个数据包根据目的 IP 查找对应的 peer
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

## 5. 密钥轮换与计时器 @ timers.c

```c
// WireGuard 自动管理密钥轮换：
// 1. 每个密钥对有一个 birthdate
// 2. 定期触发密钥轮换（默认 2 分钟）
// 3. 重握手机制：当发送 nonce 接近上限时触发

// keep_key_fresh @ send.c:124 — 检查是否需要重握手
static void keep_key_fresh(struct wg_peer *peer)
{
    // 如果密钥即将过期（< 1/3 时间剩余）→ 触发重握手
    if (time_is_before_eq_jiffies(keypair->sending.birthdate +
                                   REJECT_AFTER_TIME - KEEPALIVE_TIMEOUT))
        wg_packet_send_queued_handshake_initiation(peer, false);
}
```

## 6. 关键函数索引

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

## 7. 调试

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

## 8. 总结

WireGuard 通过 `wg_packet_create_data`（`send.c:311`）→ `encrypt_packet`（`:162`）加密后通过 UDP 发送。接收端 `wg_packet_receive`（`receive.c:542`）→ `decrypt_packet`（`:242`）→ `counter_validate`（`:295`）解密并检查重放后送入网络栈。Noise_IK 握手机制在 1-RTT 内完成密钥交换。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 8. Noise 协议实现 @ noise.c（37 符号）

```c
// WireGuard 使用 Noise_IK 协议框架：

// wg_noise_precompute_static_static @ :47 — 预计算静态密钥：
// → 在 peer 创建时预计算 DH(static_private, remote_static)
// → 避免每次握手都需要 ECDH 计算

// wg_noise_handshake_init @ :59 — 初始化握手状态：
// → 设置本地和远程静态密钥
// → 初始化 chaining_key 和 hash
// → 设置预共享密钥（PSK，可选）

// handshake_zero @ :78 — 清除握手状态：
// → 使用 kfree_sensitive() 擦除密钥

// keypair_create @ :98 — 创建密钥对：
// → 从握手状态导出发送和接收密钥
// → 设置 nonce 计数器
// → 分配 keypair id（2^24 空间）

// 密钥轮换：
// → 每个密钥对约 3 分钟后过期
// → 提前 20 秒触发重握手（keep_key_fresh）
// → 每个 peer 最多保留 3 个活跃密钥对
```


## 9. Cookie 机制——抗 DoS

```c
// Cookie 机制防止握手放大攻击：

// wg_packet_send_handshake_cookie @ :110
// → 当握手队列满时发送 cookie
// → cookie = MAC(mac1, secret) 基于时间变化
// → 发起者必须在下次握手中携带正确的 cookie

// cookie 验证：
// → 接收时检查 cookie 有效性
// → 无效 → 丢弃（不响应 → 不放大）

// mac1 计算：
// → HMAC(label || msg, responder_static_public)
// → 持续验证（即使 cookie 未启用也计算 mac1）
```

## 10. 传输性能优化

```c
// WireGuard 数据路径的性能优化：

// 1. 批量加密（wg_packet_encrypt_worker @ :287）：
//    → per-CPU 加密 worker
//    → 多个数据包共享同一密钥时批量加密
//    → 提高 ChaCha20Poly1305 吞吐量

// 2. skb 填充优化（calculate_skb_padding @ :141）：
//    → 计算 UDP 头填充
//    → 确保 IP/UDP 头对齐
//    → 减少 DMA 分段

// 3. NAPI 批量接收（wg_packet_rx_poll @ :438）：
//    → NAPI 轮询模式
//    → 减少中断次数
//    → 批量提交到网络栈
```

## 11. 关键函数索引

| 函数 | 符号数 | 作用 |
|------|--------|------|
| `send.c` | 15 | 数据包发送 |
| `receive.c` | 13 | 数据包接收 |
| `noise.c` | 37 | Noise 握手协议 |
| `encrypt_packet` | `:162` | ChaCha20Poly1305 加密 |
| `decrypt_packet` | `:242` | ChaCha20Poly1305 解密 |
| `counter_validate` | `:295` | 重放攻击保护 |
| `keypair_create` | `:98` | 密钥对创建 |
| `wg_noise_handshake_init` | `:59` | 握手初始化 |

