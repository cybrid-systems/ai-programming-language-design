# Linux Kernel rtnetlink 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/core/rtnetlink.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. rtnetlink 概述

**rtnetlink**（`NETLINK_ROUTE`）是 netlink 的路由子系统，用于配置：
- 网络接口（IP 地址、MAC 地址、状态）
- 路由表
- 邻居表（ARP）
- 网规则（ip rule）

---

## 1. 消息类型

```c
// include/uapi/linux/rtnetlink.h — RTM_*
RTM_NEWLINK        // 创建/设置网络接口
RTM_DELLINK        // 删除网络接口
RTM_GETLINK        // 获取网络接口信息
RTM_NEWADDR        // 添加/设置 IP 地址
RTM_DELADDR        // 删除 IP 地址
RTM_NEWROUTE       // 添加/设置路由
RTM_DELROUTE       // 删除路由
RTM_NEWNEIGH       // 添加/设置 ARP 条目
RTM_DELNEIGH       // 删除 ARP 条目
```

---

## 2. 核心结构

```c
// net/core/rtnetlink.c — ifinfmsg
struct ifinfomsg {
    unsigned char   ifi_family;   // AF_UNSPEC
    unsigned short  ifi_type;     // ARPHRD_ETHER（以太网）
    int             ifi_index;    // 接口索引
    unsigned int    ifi_flags;    // IFF_UP / IFF_RUNNING 等
    unsigned int    ifi_change;   // 变更掩码
};

// net/core/rtnetlink.c — ifaddrmsg
struct ifaddrmsg {
    unsigned char   ifa_family;   // AF_INET / AF_INET6
    unsigned char   ifa_prefixlen; // 前缀长度
    unsigned char   ifa_flags;
    unsigned char   ifa_scope;    // 地址作用域
    int             ifa_index;    // 接口索引
};
```

---

## 3. ifla_map — 接口属性

```c
// ifla_map：嵌套属性，包含：
// - IFLA_IFNAME：接口名（"eth0"）
// - IFLA_ADDRESS：MAC 地址
// - IFLA_BROADCAST：广播地址
// - IFLA_MTU：MTU
// - IFLA_STATS：统计信息
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `net/core/rtnetlink.c` | `rtnetlink_rcv_msg`、`do_setlink`、`do_getlink` |
| `include/uapi/linux/rtnetlink.h` | RTM_* 消息类型 |
