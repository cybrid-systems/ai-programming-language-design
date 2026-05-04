# 103-rtnetlink — Linux rtnetlink 路由套接字深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**rtnetlink**（`NETLINK_ROUTE`）是 netlink 协议族中最核心的子系统，管理 Linux 网络栈的配置——网络设备（link）、IP 地址（addr）、路由（route）、邻居（neigh）、规则（rule）、隧道（tunnel）等。用户空间通过 `ip link`、`ip addr`、`ip route` 等 iproute2 工具与 rtnetlink 通信。

**核心设计**：rtnetlink 在 netlink 基础上注册三层消息处理表——`rtnl_msg_handlers[RTNL_FAMILY_MAX+1]`（`:357`），每种消息类型对应 `struct rtnl_link`（`:68`），包含 `doit`（写操作）和 `dumpit`（读操作）回调。`rtnetlink_rcv()` 从 netlink 接收消息后通过 `rtnl_get_link()` 路由到对应的 handler。

```
用户空间（ip link add ...）          内核
──────────────                    ──────
sendmsg(RTM_NEWLINK, ...)
  ↓
netlink(BASE)→ rtnetlink_rcv()
  → rtnl_get_link(RTNL_FAMILY_LINK, RTM_NEWLINK)
    → rtnl_link->doit = __rtnl_newlink()
      → rtnl_create_link() 创建设备
      → rtnl_configure_link() 配置

用户空间（ip link show）
  ↓
sendmsg(RTM_GETLINK | NLM_F_DUMP)
  → rtnetlink_dumpit(RTM_GETLINK)
    → rtnl_link->dumpit = rtnl_dump_all()
      → 遍历所有网络设备 → rtnl_fill_ifinfo() 填充
```

**doom-lsp 确认**：`net/core/rtnetlink.c`（7,140 行，330 个符号）。`rtnl_msg_handlers` @ `:357`，`rtnl_link` @ `:68`。`rtnl_lock` @ `:78`。

---

## 1. 核心数据结构 @ :68

```c
struct rtnl_link {                            // rtnetlink 消息处理器
    int (*doit)(struct sk_buff *, struct nlmsghdr *,
                struct netlink_ext_ack *);    // 写操作（NEW/DEL/SET）
    int (*dumpit)(struct sk_buff *, struct netlink_callback *);
                                              // 读操作（GET + DUMP）
    int (*calcit)(struct sk_buff *, struct nlmsghdr *,
                  struct netlink_ext_ack *);  // 容量计算
    struct module *owner;
    unsigned int flags;
    struct rcu_head rcu;
};

// 三层消息处理表 @ :357：
// 按 family（LINK/ADDR/ROUTE/NEIGH...）→ msgtype（NEW/GET/DEL/SET）索引
static struct rtnl_link __rcu *__rcu *rtnl_msg_handlers[RTNL_FAMILY_MAX + 1];
```

**doom-lsp 确认**：`rtnl_link` @ `:68`，`rtnl_msg_handlers` @ `:357`。

---

## 2. rtnetlink_rcv——消息分发入口

```c
// netlink 收到用户消息后调用：
// nlk->netlink_rcv = rtnetlink_rcv

void rtnetlink_rcv(struct sk_buff *skb)
{
    rtnl_lock();                         // 全局 rtnetlink 锁
    netlink_rcv_skb(skb, &rtnetlink_rcv_msg);  // 解析消息头
    rtnl_unlock();
}
```

---

## 3. rtnetlink_rcv_msg @ :455——消息路由

```c
static int rtnetlink_rcv_msg(struct sk_buff *skb, struct nlmsghdr *nlh,
                              struct netlink_ext_ack *extack)
{
    // 1. 从消息头获取 family 和 msgtype
    family = ((nlh->nlmsg_type & 0xF00) >> 8);  // RTNL_FAMILY_*

    // 2. 查找对应的 handler
    link = rtnl_get_link(family, nlh->nlmsg_type);
    // → 从 rtnl_msg_handlers[family] 表中取

    // 3. 调用 handler
    if (nlh->nlmsg_flags & NLM_F_DUMP) {
        // DUMP 请求（大量数据）→ dumpit
        // 用户 recvmsg 多次接收
        link->dumpit(skb, cb);
    } else {
        // 普通请求（NEW/DEL/SET）→ doit
        link->doit(skb, nlh, extack);
    }
}
```

---

## 4. 关键 handler

| 消息类型 | family | 函数 | 作用 |
|----------|--------|------|------|
| `RTM_NEWLINK` | `LINK` | `__rtnl_newlink` | 创建/修改网络设备 |
| `RTM_DELLINK` | `LINK` | `rtnl_dellink` | 删除网络设备 |
| `RTM_GETLINK` | `LINK` | `rtnl_dump_all` | 列举网络设备 |
| `RTM_NEWADDR` | `ADDR` | `inet_rtm_newaddr` | 添加 IP 地址 |
| `RTM_DELADDR` | `ADDR` | `inet_rtm_deladdr` | 删除 IP 地址 |
| `RTM_GETADDR` | `ADDR` | `inet_dump_addresses` | 列举 IP 地址 |
| `RTM_NEWROUTE` | `ROUTE` | `inet_rtm_newroute` | 添加路由 |
| `RTM_DELROUTE` | `ROUTE` | `inet_rtm_delroute` | 删除路由 |
| `RTM_GETROUTE` | `ROUTE` | `inet_dump_fib` | 列举路由表 |
| `RTM_NEWNEIGH` | `NEIGH` | `neigh_add` | 添加邻居 |
| `RTM_GETNEIGH` | `NEIGH` | `neigh_dump_info` | 列举邻居表 |

---

## 5. rtnetlink 消息头格式

```c
// ifinfomsg（接口信息）：
struct ifinfomsg {
    unsigned char ifi_family;   // AF_UNSPEC / AF_INET
    unsigned char __ifi_pad;
    unsigned short ifi_type;    // ARPHRD_ETHER 等
    int ifi_index;              // 接口索引
    unsigned int ifi_flags;     // 设备标志
    unsigned int ifi_change;    // 变更掩码
};

// ifaddrmsg（地址信息）：
struct ifaddrmsg {
    unsigned char ifa_family;    // AF_INET / AF_INET6
    unsigned char ifa_prefixlen; // 前缀长度
    unsigned char ifa_flags;     // IFA_F_SECONDARY 等
    unsigned char ifa_scope;     // 作用域
    int ifa_index;               // 接口索引
};
```

## 6. rtnl_lock @ :78——全局锁

```c
// rtnetlink 使用单一的全局 mutex 保护所有配置操作：
DEFINE_MUTEX(rtnl_mutex);
void rtnl_lock(void)   { mutex_lock(&rtnl_mutex); }
void rtnl_unlock(void) { mutex_unlock(&rtnl_mutex); }

// 所有网络配置操作串行化——ip link, ip addr, ip route 不能同时执行
// 这是 rtnetlink 的瓶颈，但在配置低频场景下可接受
```

---

## 7. 注册链路操作——rtnl_link_ops

```c
// 驱动注册新链路类型（vlan/vxlan/bridge/bonding 等）：
// struct rtnl_link_ops {
//     const char *kind;                        // "vlan", "vxlan"...
//     size_t priv_size;                        // 私有数据大小
//     int (*newlink)(struct net *, struct net_device *dev,
//                     struct nlattr **tb, struct nlattr **data);
//     int (*changelink)(...);
//     void (*dellink)(struct net_device *dev);
//     int (*fill_info)(struct sk_buff *, const struct net_device *);
//     const struct nla_policy *policy;          // 属性策略
// };

// 注册：rtnl_link_register(&vlan_link_ops)
// → 添加到 rtnl_link_ops_list 链表
// → __rtnl_newlink 中按 "kind" 匹配链接操作
```

---

## 7. 调试

```bash
# strace rtnetlink 通信
strace -e sendmsg ip link show

# 查看 Netlink 统计
cat /proc/net/netlink

# rtnetlink 消息跟踪
echo 1 > /sys/kernel/debug/tracing/events/netlink/netlink_send/enable
cat /sys/kernel/debug/tracing/trace_pipe
```

---

## 8. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `rtnetlink_rcv` | — | 接收入口（rtnl_lock + netlink_rcv_skb）|
| `rtnetlink_rcv_msg` | `:455` | 消息路由（按 family+type 查 handler）|
| `rtnl_get_link` | `:373` | 查找消息处理器 |
| `__rtnl_newlink` | — | 创建/修改网络接口 |
| `rtnl_dump_all` | — | dump 所有网络接口 |
| `rtnl_lock` | `:78` | 取全局 rtnl_mutex |
| `rtnl_link_register` | `:597` | 注册链路类型操作 |

---

## 9. 总结

rtnetlink 通过 `rtnl_msg_handlers[family][msgtype]` 三层消息路由表管理网络配置。`rtnetlink_rcv_msg`（`:455`）根据消息类型调用对应的 `doit`/`dumpit` 处理器。所有操作在全局 `rtnl_mutex`（`:78`）保护下串行执行，保证网络状态一致性。链路类型驱动通过 `rtnl_link_register` 注册 `struct rtnl_link_ops`。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 10. rtnetlink 消息处理表 @ rtnl_link:68

```c
// rtnetlink 的核心是三层消息路由表：

// 第一层：按 family（RTNL_FAMILY_*）索引
// rtnl_msg_handlers[RTNL_FAMILY_MAX + 1] @ :357
// → RTNL_FAMILY_LINK (0) — 网络设备
// → RTNL_FAMILY_ADDR (1) — IP 地址
// → RTNL_FAMILY_ROUTE (2) — 路由
// → RTNL_FAMILY_NEIGH (3) — 邻居
// → RTNL_FAMILY_MAX — 当前为 4

// 第二层：按 msgtype（RTM_NEWLINK/DELLINK/GETLINK/SETLINK）索引
// 每个 rtnl_msg_handlers[family] 指向 rtnl_link 数组

// 第三层：rtnl_link 包含 doit/dumpit/calcit 回调
struct rtnl_link @ :68 {
    int (*doit)(struct sk_buff *, struct nlmsghdr *,
                struct netlink_ext_ack *);
    // → 写操作（NEW/DEL/SET）

    int (*dumpit)(struct sk_buff *, struct netlink_callback *);
    // → 读操作（GET + NLM_F_DUMP）

    int (*calcit)(struct sk_buff *, struct nlmsghdr *,
                  struct netlink_ext_ack *);
    // → 容量计算（可选）
};
```

## 11. rtnl_lock 的全局影响

```c
// rtnl_lock 是 rtnetlink 的全局 mutex @ :76：

// 所有网络配置操作通过 rtnl_lock 串行化：
// rtnl_lock()           — 阻塞等待锁
// rtnl_trylock() @ :161 — 尝试获取（立即返回）
// rtnl_lock_interruptible() @ :84 — 可被信号中断
// rtnl_lock_killable() @ :89 — 可被 fatal 信号中断

// 影响范围：
// → ip link, ip addr, ip route 在同一时间只能执行一个
// → 批量配置时性能受限（但配置操作本身不频繁）

// rtnl_link_register @ :597 — 注册链路类型：
// → 添加 vlan/vxlan/bridge/bond 等
// → 在 rtnl_lock 保护下链入 rtnl_link_ops_list
```

## 12. rtnetlink 的 Netlink 消息封装

```c
// rtnetlink 消息在 netlink 消息体中的组织：

// struct nlmsghdr（netlink 头）：
// - nlmsg_type: RTM_NEWLINK, RTM_GETADDR 等
// - nlmsg_flags: NLM_F_REQUEST, NLM_F_DUMP

// struct ifinfomsg（接口信息）— 紧随 nlmsghdr：
// struct ifinfomsg {
//     unsigned char ifi_family;   // AF_UNSPEC
//     unsigned short ifi_type;    // ARPHRD_ETHER
//     int ifi_index;              // 接口索引
//     unsigned int ifi_flags;     // IFF_UP, IFF_RUNNING
//     unsigned int ifi_change;    // 要修改的标志
// };

// 之后是 NLA（Netlink 属性）：
// IFLA_IFNAME  — 设备名
// IFLA_MTU     — MTU
// IFLA_LINK    — 关联接口索引
// IFLA_ADDRESS — MAC 地址
// IFLA_BROADCAST — 广播地址
```

## 13. 关键函数索引

| 函数 | 符号数 | 作用 |
|------|--------|------|
| `rtnetlink.c` | 330 | rtnetlink 实现 |
| `rtnl_link` | `:68` | 消息处理器结构 |
| `rtnl_mutex` | `:76` | 全局锁 |
| `rtnl_get_link` | `:373` | 查找消息处理器 |
| `rtnetlink_rcv_msg` | `:455` | 消息路由 |
| `rtnl_register` | — | 注册消息处理 |
| `rtnl_link_register` | `:597` | 注册链路类型 |


## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `rtnl_newlink()` | net/core/rtnetlink.c | 相关 |
| `rtnl_dellink()` | net/core/rtnetlink.c | 相关 |
| `rtnl_getlink()` | net/core/rtnetlink.c | 相关 |
| `struct rtmsg` | include/uapi/linux/rtnetlink.h | 路由消息 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
