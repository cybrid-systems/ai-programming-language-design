# rtnetlink — 路由 netlink 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/core/rtnetlink.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**rtnetlink** 允许配置网络接口、IP 地址、路由表、ARP 表等，通过 netlink 协议。

---

## 1. 核心数据结构

### 1.1 rtgenmsg — 路由通用消息

```c
// include/uapi/linux/rtnetlink.h — rtgenmsg
struct rtgenmsg {
    unsigned char           rtm_family;   // 地址族（AF_INET/AF_INET6）
    unsigned char           rtm_dst_len;   // 目标前缀长度
    unsigned char           rtm_src_len;   // 源前缀长度
    unsigned char           rtm_tos;       // TOS
    unsigned char           rtm_table;     // 路由表
    unsigned char           rtm_protocol; // 协议（RTPROT_*）
    unsigned char           rtm_scope;     // 作用域
    unsigned char           rtm_type;     // 类型
    unsigned int            rtm_flags;    // RTNH_F_* 标志
};
```

### 1.2 rtattr — 路由属性

```c
// include/uapi/linux/rtnetlink.h — rtattr
struct rtattr {
    unsigned short         rta_len;       // 属性长度
    unsigned short         rta_type;      // 属性类型（IFLA_*/RTA_*）
    // 数据紧随其后
};
```

---

## 2. 接口配置

### 2.1 rtnl_newlink — 创建/设置接口

```c
// net/core/rtnetlink.c — rtnl_newlink
static int rtnl_newlink(struct sk_buff *skb, struct nlmsghdr *nlh, ...)
{
    struct ifinfomsg *ifm = nlmsg_data(nlh);
    struct net_device *dev;
    struct nlattr *tb[__IFLA_MAX];
    unsigned int change = ifm->ifi_change;

    // 1. 解析属性
    nlmsg_parse(nlh, sizeof(*ifm), tb, __IFLA_MAX, ifla_policy);

    // 2. 获取或创建设备
    if (ifm->ifi_index)
        dev = __dev_get_by_index(ifm->ifi_index);
    else if (tb[IFLA_IFNAME])
        dev = rtnl_create_link(tb[IFLA_IFNAME], ...);

    // 3. 设置属性
    if (tb[IFLA_ADDRESS])
        dev_set_mac_address(dev, rta_data(tb[IFLA_ADDRESS]));

    if (tb[IFLA_MTU])
        dev_set_mtu(dev, nla_get_u32(tb[IFLA_MTU]));

    // 4. 通知
    notifier_call_chain(NETDEV_PRE_TYPE_CHANGE, dev);
    dev->rtnl_link_state = RTNL_LINK_INITIALIZED;
}
```

---

## 3. 地址配置

### 3.1 rtnl_newaddr — 添加/删除 IP 地址

```c
// net/core/rtnetlink.c — rtnl_newaddr
static int rtnl_newaddr(struct sk_buff *skb, struct nlmsghdr *nlh, ...)
{
    struct ifaddrmsg *ifa = nlmsg_data(nlh);
    struct ifaddrmsg **ifa_info;

    // 1. 解析 ifa（索引/前缀长度）
    unsigned int index = ifa->ifa_index;
    unsigned int prefix_len = ifa->ifa_prefixlen;

    // 2. 查找设备
    struct net_device *dev = __dev_get_by_index(index);

    // 3. 添加地址
    inet_rtm_newaddr(ifa, dev);

    return 0;
}
```

---

## 4. 路由表配置

```c
// net/ipv4/fib_frontend.c — fib_dump
static int fib_dump(struct sk_buff *skb, struct netlink_callback *cb)
{
    // 遍历路由表，填充到 skb
    // 通过 nlmsg_put 添加每条路由
}
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/core/rtnetlink.c` | `rtnl_newlink`、`rtnl_newaddr`、`rtnl_deladdr` |
| `include/uapi/linux/rtnetlink.h` | `rtgenmsg`、`rtattr` |