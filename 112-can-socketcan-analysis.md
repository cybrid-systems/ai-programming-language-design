# CAN / SocketCAN — Controller Area Network 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/can/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**CAN**（Controller Area Network）是一种可靠的车载网络标准，SocketCAN 在 Linux 中通过 Socket 接口提供 CAN 访问。

---

## 1. 核心数据结构

### 1.1 can_frame — CAN 帧

```c
// include/linux/can.h — can_frame
struct can_frame {
    canid_t             can_id;          // CAN ID + flags
    __u8                len;              // 数据长度（0-8）
    __u8                data[8];           // 数据
};
#define CAN_EFF_FLAG    0x80000000U        // 扩展帧
#define CAN_RTR_FLAG    0x40000000U        // 远程帧
#define CAN_ERR_FLAG    0x20000000U        // 错误帧
```

### 1.2 can_sock — CAN socket

```c
// net/can/af_can.c — can_sock
struct can_sock {
    struct sock           sk;           // 基类
    struct can_bittime   bittime;         // 位时序配置
    struct can_filter    *filter;         // 过滤器
    unsigned int        ifindex;         // CAN 接口索引
};
```

---

## 2. 发送接收

```c
// net/can/af_can.c — can_sendmsg
static int can_sendmsg(struct socket *sock, struct msghdr *msg, size_t size)
{
    struct can_sock *sk = can_sk(sock->sk);
    struct can_frame frame;

    // 1. 复制帧数据
    memcpy_from_msg(&frame, msg, size);

    // 2. 发送到 CAN 设备
    dev_queue_xmit(to_can_dev(sk));

    return size;
}
```

---

## 3. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/can.h` | `can_frame` |
| `net/can/af_can.c` | `can_sock`、`can_sendmsg` |