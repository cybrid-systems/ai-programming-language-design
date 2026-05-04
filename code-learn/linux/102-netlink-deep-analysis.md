# 102-netlink-deep — Linux netlink 套接字深度源码分析

## 0. 概述

**netlink** 是内核与用户空间的通信 socket 协议（AF_NETLINK），专为网络配置设计（NETLINK_ROUTE），也被用于审计（NETLINK_AUDIT）、SELinux（NETLINK_SELINUX）等。特点：支持多播、双向通信、异步消息。

---

## 1. 核心结构

```c
struct netlink_sock {
    struct sock             sk;             // 基础 socket 结构
    u32                     groups;         // 多播组掩码
    u32                     ngroups;        // 多播组数
    struct netlink_table    *table;         // netlink 协议表（路由/审计/...）
    void                    (*netlink_rcv)(struct sk_buff *skb); // 接收回调
    struct mutex            cb_mutex;       // 回调互斥锁
    struct rhash_head       node;           // rhashtable 节点（端口号查找）
};
```

## 2. 消息格式

```
┌─────────────────────────────┐
│ struct nlmsghdr             │ 16 字节
│  ├─ nlmsg_len               │ 总长度
│  ├─ nlmsg_type              │ 消息类型（RTM_NEWLINK/RTM_DELLINK...）
│  ├─ nlmsg_flags             │ NLM_F_REQUEST/NLM_F_ACK/NLM_F_DUMP...
│  └─ nlmsg_seq               │ 序列号
├─────────────────────────────┤
│ 负载（struct rtattr 数组）   │
│  ├─ struct rtattr           │ 12 字节
│  │  ├─ rta_len              │
│  │  ├─ rta_type             │ IFLA_ADDRESS/IFLA_MTU...
│  │  └─ rta_data             │
│  └─ ...                     │
└─────────────────────────────┘
```

## 3. 数据流（ip link add 为例）

```
用户空间（iproute2）：
  rtnetlink.c → rtnl_talk(&req, ...)
    └─ sendmsg(netlink_fd, &msg, 0)
         └─ [NETLINK_ROUTE]

内核：
  netlink_rcv_skb(skb)
    └─ rtnetlink_rcv(skb)
         └─ rtnl_handle_message(skb, nlh)
              └─ RTM_NEWLINK → rtnl_newlink()
                   └─ __rtnl_newlink()
                        └─ dev_change_flags() 或 dev_set_mtu() 或...

  回复：
    netlink_unicast(kern_skb, portid, MSG_DONTWAIT)
```

## 4. 源码索引

| 符号 | 文件 |
|------|------|
| `struct netlink_sock` | net/netlink/af_netlink.c |
| `netlink_rcv_skb()` | net/netlink/af_netlink.c |
| `rtnetlink_rcv()` | net/core/rtnetlink.c |
| `rtnl_newlink()` | net/core/rtnetlink.c |
| `rtnl_handle_message()` | net/core/rtnetlink.c |
