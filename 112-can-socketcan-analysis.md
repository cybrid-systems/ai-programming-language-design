# CAN / SocketCAN — Controller Area Network 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/can/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**CAN**（Controller Area Network）是车载和工业控制领域常用的可靠串行总线协议。**SocketCAN** 在 Linux 中通过标准 Socket 接口提供 CAN 访问。

---

## 1. CAN 帧格式

### 1.1 can_frame — CAN 帧

```c
// include/linux/can.h — can_frame
struct can_frame {
    canid_t             can_id;          // CAN ID + 标志
    __u8                len;              // 数据长度 DLC（0-8）
    __u8                data[8];           // 数据字节
};

// canid_t 编码：
#define CAN_EFF_FLAG    0x80000000U        // 扩展帧（29 位 ID）
#define CAN_RTR_FLAG    0x40000000U        // 远程帧（请求数据）
#define CAN_ERR_FLAG    0x20000000U        // 错误帧

// 标准帧（11 位 ID）：can_id = ID
// 扩展帧（29 位 ID）：can_id = ID | CAN_EFF_FLAG
typedef __u32 canid_t;
```

### 1.2 can_filter — 接收过滤器

```c
// include/linux/can.h — can_filter
struct can_filter {
    canid_t             can_id;          // 要匹配的 ID
    canid_t             can_mask;        // 掩码（0 = 匹配所有）
};

// can_mask = 0xFFF：精确匹配
// can_mask = 0x000：接收所有
```

---

## 2. SocketCAN 核心

### 2.1 can_sock — CAN socket

```c
// net/can/af_can.c — can_sock
struct can_sock {
    struct sock           sk;           // 基类
    struct can_filter    *filter;         // 过滤器数组
    unsigned int         filter_count;    // 过滤器数量
    struct can_bittime   bittime;         // 位时序配置
    struct net_device   *bound_dev_if;   // 绑定的 CAN 设备
    struct list_head     list;            // CAN socket 链表
};
```

### 2.2 can_dev — CAN 设备

```c
// drivers/net/can/dev.c — can_dev
struct can_dev {
    struct net_device       *ndev;          // 网络设备
    struct can_bittime_ops *bittime_ops;   // 位时序操作

    // 发送
    struct can_tx_ring      *tx;            // 发送环形队列
    struct can_frame        *echo_skb;      // 回环echo 缓冲

    // 接收
    struct can_rx_ring      *rx;            // 接收队列

    // 状态
    enum can_state          state;          // 状态（ERROR_ACTIVE/WARNING/PASSIVE/BUS_OFF）

    // 统计
    struct can_stats        stats;          // 统计（tx/rx errors）
    //   stats.tx_packets
    //   stats.tx_errors
    //   stats.rx_packets
    //   stats.rx_errors
    //   stats.bus_error
};
```

---

## 3. 发送流程

```c
// net/can/af_can.c — can_sendmsg
static int can_sendmsg(struct socket *sock, struct msghdr *msg, size_t len)
{
    struct can_sock *sk = can_sk(sock->sk);
    struct can_frame frame;
    struct net_device *dev;

    // 1. 复制帧数据
    if (len < sizeof(struct can_frame))
        return -EINVAL;
    memcpy_from_msg(&frame, msg, sizeof(frame));

    // 2. 获取目标设备
    dev = sk->bound_dev_if;
    if (!dev)
        dev = dev_get_by_index(sock_net(sock), 1); // can0

    // 3. 发送
    dev->netdev_ops->ndo_start_xmit(skb, dev);

    return len;
}
```

---

## 4. SocketCAN 常用命令

```bash
# 加载 CAN 驱动
modprobe can
modprobe mcp251x  # MCP2515 SPI CAN 控制器

# 创建 CAN 接口
ip link add can0 type can bitrate 500000

# 启用
ip link set can0 up

# 发送 CAN 帧
cansend can0 123#DEADBEEF     # 标准帧 ID=0x123 数据=0xDEADBEEF
cansend can0 123##1           # 远程帧

# 接收 CAN 帧
candump can0                   # 监听所有帧
candump can0 can_id 5A0..5FF   # 只显示 ID 范围

# 关闭
ip link set can0 down
```

---

## 5. 位时序（Bit Timing）

```c
// include/linux/can/error.h — can_bittime
struct can_bittime {
    enum can_bittime_const type;
    struct {
        __u32   brp;    // 波特率预分频
        __u16   prop_seg;  // 传播时间段
        __u16   phase_seg1; // 相位段 1
        __u16   phase_seg2; // 相位段 2
        __u16   sjw;    // 同步跳转宽度
    } bittime;
};

// CAN 500kbps 时序示例：
// brp=4, prop_seg=13, phase_seg1=2, phase_seg2=2, sjw=1
// tq = brp / f_osc = 4 / 16MHz = 250ns
// bit time = tq * (prop_seg + phase_seg1 + phase_seg2 + 1) = 5 * 250ns = 1.25us
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/can.h` | `can_frame`、`can_filter`、`canid_t` |
| `net/can/af_can.c` | `can_sock`、`can_sendmsg` |
| `drivers/net/can/dev.c` | `can_dev` |