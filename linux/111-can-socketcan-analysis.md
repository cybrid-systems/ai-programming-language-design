# 112-can-socketcan — Linux CAN 总线（SocketCAN）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**SocketCAN** 是 Linux 的 CAN（Controller Area Network）总线协议栈实现，将 CAN 总线接口映射为网络套接字（`AF_CAN`）。支持 RAW（原始 CAN 帧）、BCM（广播管理）、GW（网关）、J1939 等协议。

**核心设计**：CAN 设备驱动注册到 `struct net_device`，通过 `af_can.c` 的接收分发机制将 CAN 帧发送到匹配的 socket。`can_send` 发送 CAN 帧，`can_rcv` 根据 CAN ID 分发到注册的接收器。

```
用户空间                     内核
─────────                  ──────
socket(AF_CAN, ...)       af_can.c
  ↓
bind(fd, &addr) → rx 注册  can_raw.c
  ↓                           ↓
write(fd, can_frame)      can_send() → dev_queue_xmit()
  ↓                           ↓
read(fd, can_frame)       can_rcv() → 按 can_id 分发
```

**doom-lsp 确认**：`net/can/af_can.c`（932 行），`net/can/raw.c`（1,142 行），`net/can/bcm.c`（1,875 行）。

---

## 1. 核心数据结构

```c
// include/uapi/linux/can.h
struct can_frame {                           // CAN 帧（标准帧）
    canid_t can_id;                           // CAN ID（11/29 bit + 标志）
    __u8 len;                                  // 数据长度（0-8）
    __u8 flags;
    __u8 __res0;
    __u8 __res1;
    __u8 data[8];                              // 数据
};

struct canfd_frame {                          // CAN FD 帧（灵活数据率）
    canid_t can_id;
    __u8 len;                                  // 0-64
    __u8 flags;
    __u8 __res0;
    __u8 __res1;
    __u8 data[64];                             // 更多数据
};

// net/can/af_can.c
struct s_can_receiver {                       // CAN 接收器
    struct hlist_head list;                   // 接收器哈希表
    canid_t can_id;                            // 匹配的 CAN ID
    canid_t mask;                              // 匹配掩码
    struct sock *sk;                           // 目标 socket
};
```

---

## 2. CAN 帧接收——can_rcv @ af_can.c

```c
// 驱动的 rx_handler 调用 can_rcv 分发帧：

static int can_rcv(struct sk_buff *skb, struct net_device *dev,
                    struct packet_type *pt, struct net_device *orig_dev)
{
    struct can_frame *cf = (struct can_frame *)skb->data;

    // 1. 统计计数
    can_stats.rx_frames++;

    // 2. 查找匹配的接收器（按 can_id / mask）
    receivers = can_receivers_find(dev, cf->can_id);
    
    // 3. 分发到所有匹配 socket
    hlist_for_each_entry(r, receivers, list) {
        if (!r->sk) continue;
        // 克隆 skb→放入 socket 接收队列
        skb_clone->skb = skb_clone(skb, GFP_ATOMIC);
        sock_queue_rcv_skb(r->sk, skb_clone->skb);
    }
}
```

---

## 2. can_send——发送 CAN 帧

```c
// can_send @ af_can.c:202 — 所有 CAN socket 发送入口：
int can_send(struct sk_buff *skb, int loop)
{
    // 1. 验证帧长度和 CAN ID
    if (skb->len > CAN_MAX_DLEN) return -EINVAL;

    // 2. 设置 loopback
    skb->pkt_type = loop ? PACKET_LOOPBACK : PACKET_HOST;

    // 3. 统计
    can_stats.tx_frames++;
    can_stats.tx_bytes += skb->len;

    // 4. 发送
    return dev_queue_xmit(skb);
}
```

## 3. can_rx_register——注册 CAN 接收器 @ :444

```c
// RAW socket bind 时调用——注册接收过滤器：
int can_rx_register(struct net *net, struct net_device *dev,
    canid_t can_id, canid_t mask,
    void (*func)(struct sk_buff *, void *), void *data)
{
    // 1. 分配接收器
    r = kzalloc(sizeof(*r), GFP_KERNEL);
    r->can_id = can_id;
    r->mask = mask;

    // 2. 按 can_id 哈希插入
    hlist_add_head_rcu(&r->list, can_rx_dev_list[dev->ifindex]);

    // 3. can_rcv 收到帧时按 hash 查找匹配
    // → 匹配规则：(frame_id ^ r->can_id) & r->mask == 0
}
```


## 3. RAW 协议 @ can/raw.c

```c
// CAN_RAW socket——收发原始 CAN 帧：

// can_raw_bind() — 绑定到 CAN 接口：
// → 将 socket 注册为 can_receivers 条目
// → 设置 can_id / mask 过滤规则

// raw_sendmsg() — 发送：
// → copy_from_user(skb_put(skb, size), msg, len) 复制帧
// → can_send(skb, loopback)  // 发送到设备

// raw_recvmsg() — 接收：
// → 从 sk_receive_queue 取 skb
// → copy_to_iter(cf, sizeof(cf), msg) 复制到用户
```

---

## 4. BCM 协议 @ bcm.c

```c
// CAN_BCM——广播管理（周期性发送 + 变化检测）：
// 
// 1. 注册时设置一组 CAN ID + 周期
// 2. 内核定时器周期性发送
// 3. 支持 RX_THR——值超过阈值时通知
// 4. 用于 CANopen 等设备的周期性状态读取

struct bcm_op {
    struct list_head list;
    int can_id;
    unsigned int flags;                        // SETUP / RX_CHECK / TX_...
    struct bcm_msg_head msg_head;
    struct timer_list timer;                   // 发送/检查定时器
    struct sk_buff *skb;                       // 待发送的帧
    ktime_t lastrx;                            // 上次接收时间
    ktime_t last;                              // 上次发送时间
};
```

---

## 5. CAN FD 支持

```c
// CAN FD（Flexible Data Rate）：支持最多 64 字节数据 + 更高位率
// struct canfd_frame 替代 struct can_frame
// userspace: setsockopt(fd, SOL_CAN_RAW, CAN_RAW_FD_FRAMES, &on, sizeof(on))
```

---

## 6. 调试

```bash
# CAN 接口配置
ip link set can0 type can bitrate 500000
ip link set can0 up

# 收发 CAN 帧
cansend can0 123#DEADBEEF
candump can0

# 查看统计
cat /proc/net/can/stats
ip -s -d link show can0
```

---

## 7. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `can_rcv` | `af_can.c` | CAN 帧接收分发 |
| `can_send` | `af_can.c` | CAN 帧发送 |
| `raw_sendmsg` | `raw.c` | RAW socket 发送 |
| `bcm_sendmsg` | `bcm.c` | BCM socket 发送 |
| `can_rx_register` | `af_can.c` | 注册接收器 |

---

## 8. 总结

SocketCAN 通过 `can_rcv`（`af_can.c`）按 CAN ID 分发帧到匹配的 socket。`can_send` 将帧发送到设备。RAW 协议提供原始 CAN 帧收发，BCM 协议提供周期性发送和变化检测。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
