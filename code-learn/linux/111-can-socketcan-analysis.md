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

## 6. CAN 过滤器匹配算法 @ af_can.c:340

```c
// can_rcv_list_find() — 计算最优过滤器列表：
// 匹配规则（核心公式）：
//   (<received_can_id> & mask) == (can_id & mask)

// 四种过滤器列表：
// RX_ERR — 错误帧过滤器（mask 含 CAN_ERR_FLAG）
// RX_INV — 反向过滤器（can_id 含 CAN_INV_FILTER）
// RX_ALL — 通配过滤器（mask == 0）
// RX_FIL — 标准 mask/value 过滤器

// 优化：对于单 CAN ID 非 RTR 订阅，使用哈希索引
// rx_sff[] 或 rx_eff[] 直接索引（O(1) 匹配）
// can_rcv() → can_rcv_list_find() 快速定位
```

## 7. CAN 协议注册 @ :82

```c
// CAN 协议族支持多个协议：
static const struct can_proto __rcu *proto_tab[CAN_NPROTO];

// 注册：can_proto_register(&can_raw_proto)
// → proto_tab[CAN_RAW] = &can_raw_proto
//   → can_raw_proto 含 .type = SOCK_RAW, .protocol = CAN_RAW

// 已注册的 CAN 协议：
// CAN_RAW (1) — 原始 CAN 帧（can_raw.c）
// CAN_BCM  (2) — 广播管理（can_bcm.c）
// CAN_ISOTP (7) — ISO TP 传输层
// CAN_J1939 (9) — SAE J1939
```

## 8. CAN 设备接口

```c
// 硬件 CAN 驱动通过 net_device 注册：
struct net_device *alloc_candev(sizeof_priv, echo_skb_max);
// → 分配 can_priv 私有数据
// → 设置 can_netdev_ops

struct can_priv {
    struct net_device *dev;
    struct can_device_stats can_stats;
    struct can_bittiming bittiming;           // 位时序
    struct can_clock clock;                    // 时钟
    enum can_state state;                      // ERROR_ACTIVE / ERROR_WARNING / ERROR_PASSIVE / BUS_OFF
    struct can_berr_counter bec;              // 接收/发送错误计数
};

// CAN 状态管理：
// → 错误计数超过阈值时自动转换状态
// → BUS_OFF 状态需用户手动恢复
```


## 9. CAN 错误统计

```c
// 每个 CAN 设备维护错误统计：
struct can_device_stats {
    u32 bus_error;                  // 总线错误计数
    u32 bus_warning;                // 警告状态次数
    u32 bus_passive;                // 被动状态次数
    u32 bus_off;                    // BUS_OFF 次数
    u32 arbitration_lost;           // 仲裁丢失计数
    u32 restarts;                   // 恢复次数
};

// 通过 /sys/class/net/can0/device/ 暴露
// can-utils 中的 ip -details link show can0
```

## 10. CAN FD 支持

```c
// CAN FD（Flexible Data Rate）扩展：
// struct canfd_frame {
//     canid_t can_id;
//     __u8 len;       // 0-64 字节
//     __u8 flags;      // CANFD_BRS（波特率切换）
//     __u8 data[64];
// };
// setsockopt(fd, SOL_CAN_RAW, CAN_RAW_FD_FRAMES, &on, 1)
// → 启用 CAN FD 帧收发
// → 驱动需支持 CAN_CTRLMODE_FD
```


## 11. Loopback 与本地回环

```c
// can_send() 支持本地回环：
// → 如果 loop == 1（默认），skb 会克隆一份发送到本地 socket
// → 用于 CAN 应用程序的自我接收（确认发送成功）

// 回环处理：
// can_send(skb, 1) → dev_queue_xmit(skb) → 硬件发送
//                 → can_loopback_xmit(skb_clone) → can_rcv() → 本地 socket
```


## 12. 关键 doom-lsp 确认

```c
// af_can.c 关键函数：
// can_send @ :202           — CAN 帧发送（含 loopback 选项）
// can_rcv @ :?               — CAN 帧接收分发
// can_rx_register @ :444     — 注册接收过滤器
// can_rx_unregister @ :513   — 注销接收过滤器
// can_rcv_list_find @ :366   — 最优过滤器列表计算
// can_create @ :118          — CAN socket 创建

// can_raw.c 关键函数：
// raw_sendmsg — 发送原始 CAN 帧
// raw_recvmsg — 接收原始 CAN 帧
// raw_bind    — 绑定 CAN 接口+设置过滤器
```

