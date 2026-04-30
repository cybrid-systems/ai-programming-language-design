# Linux Kernel Netlink (深入) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netlink/af_netlink.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. netlink 概述

**netlink** 是内核与用户空间的双向通信机制，比 `ioctl` 更灵活，支持：
- 异步消息（内核主动推送）
- 多播（一对多）
- 同步请求/响应

---

## 1. 协议族

```c
// include/uapi/linux/netlink.h — netlink families
NETLINK_ROUTE         = 0  // 路由（rtnetlink）
NETLINK_AUDIT         = 12 // 审计
NETLINK_NETFILTER     = 12 // conntrack
NETLINK_KOBJECT_UEVENT = 15 // uevent
NETLINK_RDMA          = 20 // RDMA
```

---

## 2. 核心结构

```c
// net/netlink/af_netlink.c — nlmsghdr
struct nlmsghdr {
    __u32         nlmsg_len;     // 消息总长度（含 header）
    __u16         nlmsg_type;    // 消息类型（NLMSG_*）
    __u16         nlmsg_flags;   // 标志
    __u32         nlmsg_seq;     // 序列号
    __u32         nlmsg_pid;     // 发送者 PID
};

// net/netlink/af_netlink.c — sock
struct sock {
    struct socket         *sk_socket;    // 底层 socket
    struct nlmsghdr       *rcv_buf;      // 接收缓冲
    struct {
        spinlock_t        lock;
        struct sk_buff    *skb_head;
        struct sk_buff    *skb_tail;
    } sk_receive_queue;                  // 接收队列
    void                  (*netlink_rcv)(struct sk_buff *skb);
    int                   (*netlink_send)(struct sock *ssk, struct sk_buff *skb);
};
```

---

## 3. 用户空间使用

```c
// 创建 netlink 套接字
int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);

// 绑定（指定 pid 和 multicast groups）
struct sockaddr_nl addr = {
    .nl_family = AF_NETLINK,
    .nl_pid = getpid(),           // 通常 0 表示自动分配
    .nl_groups = RTMGRP_LINK | RTMGRP_IPV4_ROUTE,
};
bind(fd, (struct sockaddr *)&addr, sizeof(addr));

// 接收消息
recvmsg(fd, &msg, 0);
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `net/netlink/af_netlink.c` | `netlink_send`、`netlink_rcv` |
| `include/uapi/linux/netlink.h` | `struct nlmsghdr` |
