# 168-udp_unicast_loyal — UDP广播多播深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/udp.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**UDP 多播/广播** 允许一个 sender 同时向多个 receiver 发送数据，是 IPTV、组播路由、局域网发现等场景的核心。

---

## 1. UDP 多播地址

```
IPv4 多播地址（224.0.0.0 - 239.255.255.255）：

224.0.0.0/24（链路本地）：
  224.0.0.1   = 所有主机（all hosts）
  224.0.0.2   = 所有路由器
  224.0.0.251 = mDNS（本地发现）
  224.0.0.252 = LLMNR

SSM（特定源多播）：
  232.0.0.0/8 = SSM 范围
```

---

## 2. 多播路由

### 2.1 ip_mroute — 多播路由

```c
// net/ipv4/ipmr.c — 多播路由缓存
// IGMP（Internet Group Management Protocol）：
//   主机加入多播组：发送 IGMP report
//   主机离开多播组：发送 IGMP leave
//   路由器定期发送 IGMP query

// 多播路由：
//   (S, G) = (源IP, 多播组)
//   创建多播路由表，指定转发路径
```

---

## 3. UDP broadcast

### 3.1 广播地址

```
局域网广播：
  子网广播：192.168.1.255（子网最后地址）
  直接广播：192.168.1.255（由路由器转发）

255.255.255.255（受限广播）：
  不会被路由器转发
  只在同一广播域内
```

### 3.2 UDP 广播发送

```c
// udp_sendmsg 中处理广播：
if (msg->msg_flags & MSG_CONFIRM) {
    // 广播确认
}
if (sin->sin_addr == htonl(INADDR_ANY)) {
    // 使用 broadcast 地址
}
```

---

## 4. IGMP（Internet Group Management Protocol）

```
IGMPv3 报文：

Host → Router：
  Membership Report (join)
  Leave Group (leave)

Router → Host：
  General Query（定期，全 224.0.0.1）
  Group-Specific Query

三层交换机/路由器维护 IGMP 表：
  每个接口 + 多播组 → 成员列表
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/udp.c` | `udp_sendmsg`（多播/广播处理）|
| `net/ipv4/igmp.c` | `igmp_rcv`、`igmp_send` |
| `net/ipv4/ipmr.c` | `ip_mroute`、`mrtsock` |

---

## 6. 西游记类喻

**UDP 多播/广播** 就像"天庭的通稿"——

> 多播像一个通知同时发给多个部门（224.0.0.1 = 所有主机），不用每个部门单独跑一趟。IGMP 就像每个部门收到通知后，向路由器报告"我在这里，我属于这个多播组"，让路由器知道哪些部门的房间需要转发通知。广播则是天庭贴告示（255.255.255.255），所有人都能看到，但只有同一个院子的人能收到。

---

## 7. 关联文章

- **udp_sendmsg**（article 145）：UDP 发送基础
- **netdevice**（article 137）：多播通过 netdevice 发送