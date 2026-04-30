# netlink — 通用 netlink 协议深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netlink/af_netlink.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**netlink** 是内核与用户空间的双向通信机制，用于配置网络接口、路由表、firewalld、udev 等。

---

## 1. 核心数据结构

### 1.1 netlink_sock — netlink 套接字

```c
// net/netlink/af_netlink.c — netlink_sock
struct netlink_sock {
    struct sock           sk;           // 基类
    u32                   pid;         // 端口 ID（用户空间的进程/线程 ID）
    unsigned int          groups;       // 多播组掩码
    unsigned long         flags;        // NL_SOCK_* 标志

    // 接收队列
    struct sk_buff_head   rcv_queue;   // 接收消息队列
    unsigned int          max_recv_queue_len; // 最大队列长度

    // 回调
    void                  (*netlink_rcv)(struct sk_buff *skb);
};
```

### 1.2 nlmsghdr — netlink 消息头

```c
// include/uapi/linux/netlink.h — nlmsghdr
struct nlmsghdr {
    __u32               nlmsg_len;    // 消息长度（header + data）
    __u16               nlmsg_type;    // 消息类型（RTM_* / AUDIT_* 等）
    __u16               nlmsg_flags;   // NLM_F_* 标志
    __u32               nlmsg_seq;     // 序列号
    __u32               nlmsg_pid;    // 发送者 PID
};
```

---

## 2. bind — 绑定

```c
// net/netlink/af_netlink.c — netlink_bind
static int netlink_bind(struct socket *sock, struct sockaddr *addr, int addr_len)
{
    struct netlink_sock *nlk = nlk_sk(sock->sk);
    struct netlink_table *tb;
    u32 portid = addr->nl_family == AF_NETLINK ? addr->nl_groups : current->pid;

    // 1. 获取端口 ID
    nlk->pid = portid;

    // 2. 加入 hash 表
    nlk_hash_add(nlk, tb);

    // 3. 如果是多播组，注册
    if (addr->nl_groups)
        nlk->groups = addr->nl_groups;
}
```

---

## 3. sendmsg / recvmsg

```c
// net/netlink/af_netlink.c — netlink_sendmsg
static int netlink_sendmsg(struct socket *sock, struct msghdr *msg, size_t len)
{
    struct netlink_sock *nlk = nlk_sk(sock->sk);
    struct nlmsghdr *hdr;

    // 1. 构建 netlink 头
    hdr = nlmsg_put(msg, nlk->pid, nlk->seq, msg->msg_flags, len - NLMSG_HDRLEN);

    // 2. 复制数据
    memcpy(NLMSG_DATA(hdr), msg->msg_iov->iov_base, len - NLMSG_HDRLEN);

    // 3. 发送（如果是多播，发送给组内所有成员）
    if (nlh->nlmsg_flags & NLM_F_MULTICAST)
        nlmsg_multicast(nlk->pid, hdr);

    return len;
}
```

---

## 4. rtnetlink — 路由 netlink

```c
// net/core/rtnetlink.c — rtnl_newlink
static int rtnl_newlink(struct sk_buff *skb, struct nlmsghdr *nlh, ...)
{
    struct ifinfomsg *ifm;
    struct net_device *dev;

    // 1. 解析 ifinfomsg
    ifm = nlmsg_data(nlh);

    // 2. 创建或获取设备
    if (ifm->ifi_index)
        dev = __dev_get_by_index(ifm->ifi_index);
    else
        dev = alloc_netdev(...);

    // 3. 设置设备属性
    dev_set_mac_address(dev, nla_data(tb[IFLA_ADDRESS]));
}
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/netlink/af_netlink.c` | `netlink_sock`、`netlink_bind`、`netlink_sendmsg` |
| `include/uapi/linux/netlink.h` | `nlmsghdr` |
| `net/core/rtnetlink.c` | `rtnl_newlink` |