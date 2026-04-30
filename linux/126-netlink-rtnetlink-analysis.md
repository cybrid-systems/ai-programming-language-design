# Linux Kernel Netlink / rtnetlink 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netlink/af_netlink.c` + `net/core/rtnetlink.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：nlmsghdr、netlink 族、多播、rtnetlink、ifinfmsg

---

## 0. netlink 概述

**netlink** 是内核与用户空间的双向通信机制，比 ioctl 更灵活：
- 异步消息（内核主动推送）
- 多播（一对多）
- 同步请求/响应

---

## 1. netlink 协议族

```c
// include/uapi/linux/netlink.h — netlink families
NETLINK_ROUTE         = 0   // 路由（rtnetlink）
NETLINK_UNUSED        = 1   // 保留
NETLINK_USERSOCK     = 2   // 用户空间套接字
NETLINK_FIREWALL     = 3   // 防火墙（旧）
NETLINK_SOCK_DIAG    = 4   // 套接字诊断
NETLINK_NFLOG        = 5   // netfilter 日志
NETLINK_XFRM         = 6   // IPsec
NETLINK_SELINUX      = 7   // SELinux
NETLINK_ISCSI        = 8   // iSCSI
NETLINK_AUDIT        = 12  // 审计
NETLINK_NETFILTER    = 12  // conntrack
NETLINK_KOBJECT_UEVENT = 15 // uevent
NETLINK_RDMA         = 20  // RDMA
NETLINK_CRYPTO       = 21  // 加密
```

---

## 2. 核心数据结构

### 2.1 nlmsghdr — netlink 消息头

```c
// include/uapi/linux/netlink.h — nlmsghdr
struct nlmsghdr {
    // 消息总长度（含 header 和 payload）
    __u32         nlmsg_len;    // [行 12]

    // 消息类型
    // NLMSG_NOOP:      空消息
    // NLMSG_ERROR:     错误响应
    // NLMSG_DONE:      多消息结束
    // NLMSG_OVERRUN:   数据溢出
    __u16         nlmsg_type;   // [行 13]

    // 标志
    // NLM_F_REQUEST:   请求
    // NLM_F_MULTI:    多消息
    // NLM_F_ACK:      请求 ACK
    // NLM_F_ROOT:     返回整个表
    // NLM_F_MATCH:    返回所有匹配
    __u16         nlmsg_flags;  // [行 14]

    // 序列号（用于匹配请求和响应）
    __u32         nlmsg_seq;     // [行 15]

    // 发送者 PID（0 = 内核）
    __u32         nlmsg_pid;     // [行 16]
};
```

### 2.2 rtgenmsg — 通用路由消息

```c
// include/uapi/linux/rtnetlink.h — rtgenmsg
struct rtgenmsg {
    __u8           rtgen_family;  // AF_UNSPEC / AF_INET / AF_INET6
};
```

### 2.3 ifinfmsg — 接口消息

```c
// include/uapi/linux/rtnetlink.h — ifinfmsg
struct ifinfomsg {
    // 地址族（AF_UNSPEC）
    unsigned char   ifi_family;     // [行 260]

    // 填充
    unsigned char  __ifi_pad;

    // 接口类型（ARPHRD_ETHER 等）
    unsigned short  ifi_type;       // [行 262]

    // 接口索引
    int             ifi_index;      // [行 263]

    // 接口标志（IFF_UP / IFF_RUNNING 等）
    unsigned int    ifi_flags;      // [行 264]

    // 变更掩码
    unsigned int    ifi_change;      // [行 265]
};
```

### 2.4 ifaddrmsg — 地址消息

```c
// include/uapi/linux/rtnetlink.h — ifaddrmsg
struct ifaddrmsg {
    // 地址族
    unsigned char   ifa_family;     // AF_INET / AF_INET6

    // 前缀长度（如 24 表示 /24）
    unsigned char   ifa_prefixlen;  // [行 278]

    // 地址标志（IFA_F_SECONDARY 等）
    unsigned char   ifa_flags;

    // 地址作用域（IFA_F_SECONDARY 等）
    unsigned char   ifa_scope;      // [行 280]

    // 接口索引
    int             ifa_index;      // [行 281]
};
```

---

## 3. netlink 消息处理流程

```c
// net/netlink/af_netlink.c — netlink_recvmsg
static int netlink_recvmsg(struct socket *sock, struct msghdr *msg, size_t len, int flags)
{
    struct sock *sk = sock->sk;
    struct sk_buff *skb;

    // 1. 从接收队列取出一个 skb
    skb = skb_recv_datagram(sk, flags, &err);

    // 2. 复制到用户空间
    err = skb_copy_datagram_msg(skb, 0, msg, len);

    // 3. 释放 skb
    datagram_release(skb);

    return len;
}
```

---

## 4. rtnetlink 消息处理

```c
// net/core/rtnetlink.c — rtnetlink_rcv_msg
static int rtnetlink_rcv_msg(struct sk_buff *skb, struct nlmsghdr *nlh,
                struct netlink_ext_ack *extack)
{
    struct net *net = sock_net(NETLINK_CB(skb).sk);

    rtnl_lock();

    switch (nlh->nlmsg_type) {
    case RTM_NEWLINK:
        // 创建/修改网络接口
        rtnl_link(net, nlh, extack);
        break;
    case RTM_DELLINK:
        // 删除网络接口
        rtnl_unlink(net, nlh, extack);
        break;
    case RTM_GETLINK:
        // 获取接口信息
        rtnl_dump_ifinfo(net, skb, nlh, extack);
        break;
    case RTM_NEWADDR:
        // 添加/修改 IP 地址
        rtnl_newaddr(net, nlh, extack);
        break;
    case RTM_DELADDR:
        // 删除 IP 地址
        rtnl_deladdr(net, nlh, extack);
        break;
    case RTM_GETADDR:
        // 获取地址信息
        rtnl_dump_ifaddr(net, skb, nlh, extack);
        break;
    }

    rtnl_unlock();
}
```

---

## 5. 接口属性（ifla_map）

```c
// ifla_map：嵌套属性
// IFLA_IFNAME:    接口名（"eth0"）
// IFLA_ADDRESS:   MAC 地址
// IFLA_BROADCAST: 广播地址
// IFLA_MTU:       MTU
// IFLA_TXQLEN:    发送队列长度
// IFLA_STATS:     统计信息
```

---

## 6. 参考

| 文件 | 函数 | 行 |
|------|------|-----|
| `include/uapi/linux/netlink.h` | `struct nlmsghdr` | 8+ |
| `include/uapi/linux/rtnetlink.h` | `ifinfmsg`, `ifaddrmsg` | 260+ |
| `net/netlink/af_netlink.c` | `netlink_recvmsg` | 接收 |
| `net/netlink/af_netlink.c` | `netlink_sendmsg` | 发送 |
| `net/core/rtnetlink.c` | `rtnetlink_rcv_msg` | rtnetlink 入口 |
