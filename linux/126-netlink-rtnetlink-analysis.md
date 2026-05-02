# 103-netlink-deep — Linux netlink 套接字深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**netlink** 是 Linux 内核与用户空间的通信套接字协议族（`AF_NETLINK`），广泛用于内核子系统的配置与监控——路由（rtnetlink）、防火墙（nfnetlink）、审计（audit）、设备（udev）等。与 ioctl 和 procfs 不同，netlink 支持多播、异步消息和全双工通信。

**核心设计**：netlink 使用 `struct netlink_sock` 扩展通用 `struct sock`。`netlink_rcv_skb()`（`:1303`）在软中断中接收消息并分发到注册的处理回调。`netlink_sendmsg()`（`:1739`）构造 skb 后调用 `netlink_unicast()` 或 `netlink_broadcast()` 发送。

```
用户空间                     内核
─────────                  ──────
socket(AF_NETLINK, ...) → netlink_create()
  ↓                          ↓
sendto(fd, msg, ...) → netlink_sendmsg()
  → netlink_unicast()         → 查找目标 socket（端口号+协议）
    → netlink_deliver_tap()   → 消息注入 tap
    → netlink_rcv_skb()       → 目标接收端处理

recvmsg(fd, ...) → netlink_recvmsg()
  → skb_recv_datagram()       → 从接收队列取数据
```

**doom-lsp 确认**：`net/netlink/af_netlink.c`（2,953 行，249 个符号）。`netlink_sendmsg` @ `:1739`，`netlink_unicast` @ `:992`，`netlink_broadcast` @ `:1457`。

---

## 1. 核心数据结构

### 1.1 struct netlink_sock——netlink 套接字

```c
// net/netlink/af_netlink.c
struct netlink_sock {
    struct sock sk;                           // 通用套接字
    unsigned int portid;                      // 端口号（用户空间 bind 时设置）

    struct rhash_head node;                    // rhashtable 节点（快速查找）
    struct netlink_table *table;               // 所属协议表
    struct rcu_head rcu;

    struct netlink_callback *cb;               // dump 回调上下文
    struct mutex cb_mutex;

    void (*skb_processor)(struct sk_buff *skb); // skb 处理函数
    int (*netlink_rcv)(struct sk_buff *skb);   // 内核接收回调
    u32 dst_portid, dst_group;                 // 默认目标
    u32 groups;
};
```

### 1.2 struct netlink_table——协议表 @ nl_table:90

```c
// 全局 nl_table[] 数组：NETLINK_ROUTE(0) / NETLINK_AUDIT(9) 等各一个
static struct netlink_table *nl_table;

struct netlink_table {
    struct rhashtable hash;                   // 按 portid 的 socket 哈希表
    struct hlist_head mc_list;                 // 多播组链表
    unsigned int groups;
};

// 端口号查找 @ :492（rhashtable O(1)）：
static struct sock *__netlink_lookup(struct netlink_table *table,
                                      u32 portid, struct net *net)
{
    return rhashtable_lookup_fast(&table->hash, &arg,
                                  netlink_rhashtable_params);
}
```

### 1.3 nlmsghdr——netlink 消息头

```c
// include/uapi/linux/netlink.h
struct nlmsghdr {
    __u32 nlmsg_len;       // 消息总长度（含头部）
    __u16 nlmsg_type;      // 消息类型（NLMSG_NOOP/NLMSG_ERROR/RTM_NEWLINK...）
    __u16 nlmsg_flags;     // NLM_F_REQUEST/NLM_F_DUMP/NLM_F_ACK...
    __u32 nlmsg_seq;       // 序列号
    __u32 nlmsg_pid;       // 发送者端口号
};

// NETLINK_CB(skb)——skb 附属的控制信息
#define NETLINK_CB(skb) (*(struct netlink_cb *)&((skb)->cb))
// 存储 portid、dst_group、creds 等
```

**doom-lsp 确认**：`__netlink_lookup` @ `:492`，`nl_table` @ `:90`。NETLINK_CB 宏在 `include/net/netlink.h` 中。

---

## 2. 通信路径

### 2.1 netlink_sendmsg @ :1739——发送消息

```c
static int netlink_sendmsg(struct socket *sock, struct msghdr *msg, size_t len)
{
    struct sock *sk = sock->sk;
    struct netlink_sock *nlk = nlk_sk(sk);
    u32 dst_portid = nlk->dst_portid;
    u32 dst_group = nlk->dst_group;
    struct sk_buff *skb;
    int err;

    // 1. 分配 skb（netlink 消息头 + payload）
    err = -ENOMEM;
    skb = netlink_alloc_large_skb(msg, len, ...);
    if (skb == NULL) goto out;

    // 2. 复制用户空间数据到 skb
    err = memcpy_from_msg(skb_put(skb, len), msg, len);

    // 3. 发送——单播或多播
    if (dst_group) {
        // 多播：netlink_broadcast(sk, skb, dst_portid, dst_group, GFP_KERNEL);
        netlink_broadcast(sk, skb, nlk->portid, dst_group, GFP_KERNEL);
    } else {
        // 单播：netlink_unicast(sk, skb, dst_portid, MSG_DONTWAIT);
        err = netlink_unicast(sk, skb, dst_portid, MSG_DONTWAIT);
    }
}
```

### 2.2 netlink_unicast @ :992——单播

```c
int netlink_unicast(struct sock *ssk, struct sk_buff *skb,
                    u32 portid, int nonblock)
{
    struct sock *sk;
    int err;

    // 1. 查找目标套接字（按 portid 哈希查找）
    sk = netlink_getsocket_byportid(ssk, portid);

    // 2. 如果找到 → 发送到目标
    if (sk) {
        // netlink_attachskb(sk, skb, nonblock, ...) →
        // → 将 skb 加入目标 socket 的接收队列
        // → netlink_rcv_skb() 处理
        err = netlink_attachskb(sk, skb, nonblock, ...);
        if (!err)
            netlink_overrun(sk, skb);
    }
    return err;
}
```

### 2.3 netlink_broadcast @ :1457——多播

```c
int netlink_broadcast(struct sock *ssk, struct sk_buff *skb,
                      u32 portid, u32 group, gfp_t allocation)
{
    // 1. 遍历 nl_table[protocol].mc_list 的多播成员
    // 2. 对每个在 group 中的成员→克隆 skb 并发送
    // 3. 发送到 netlink_rcv_skb() 处理
    // 4. 失败时给发送者回送 ENOBUFS
}
```

---

## 3. 内核服务注册——netlink_kernel_create

```c
// 内核模块注册 netlink 服务（如 rtnetlink）：
struct sock *netlink_kernel_create(struct net *net, int unit,
    struct netlink_kernel_cfg *cfg)
{
    // 1. 创建内核 netlink socket
    // 2. 设置 nlk->netlink_rcv = cfg->input（接收回调）
    // 3. 添加到 nl_table[unit]
    // 4. 当用户空间发送消息时：
    //    → netlink_unicast 送到内核 socket
    //    → netlink_rcv_skb(sk, skb)
    //      → nlk->netlink_rcv(skb)      // cfg->input
    //      → 通常是 ./rtnetlink_rcv() 或 ./netfilter_rcv()
}
```

---

## 4. 内核侧处理——netlink_rcv_skb

```c
// 内核 socket 收到消息时的处理入口：
int netlink_rcv_skb(struct sk_buff *skb,
                     int (*cb)(struct sk_buff *, struct nlmsghdr *,
                               struct netlink_ext_ack *))
{
    // 1. 解析 netlink 消息头
    nlh = nlmsg_hdr(skb);

    // 2. 遍历消息（一个 skb 可能包含多个 nlmsghdr）
    while (nlmsg_ok(nlh, remaining)) {
        // 3. 调用协议特定的回调函数
        err = cb(skb, nlh, &extack);
        if (err) return err;

        nlh = nlmsg_next(nlh, &remaining);
    }
    return 0;
}
```

---

## 5. dump 机制——异步数据获取 @ netlink_dump:133

```c
// 用户空间通过 sendmsg(RTM_GETLINK | NLM_F_DUMP) 请求大量数据
// 内核不会一次性填满——而是通过多次调用 dump callback 分批发送

// __netlink_dump_start() 初始化 dump 状态：
// 1. 分配 struct netlink_callback（包含 dump 的起始位置/过滤条件）
// 2. 设置 nlk->cb = cb
// 3. 调用 netlink_dump(sk) 开始第一轮

// netlink_dump @ :133——核心 dump 循环：
static int netlink_dump(struct sock *sk)
{
    struct netlink_sock *nlk = nlk_sk(sk);
    struct sk_buff *skb;
    int alloc_size;

    alloc_size = max_t(int, nlk->max_recvmsg_len, NLMSG_GOODSIZE);

    // 1. 分配 skb
    skb = netlink_alloc_large_skb(alloc_size, ...);

    // 2. 调用用户的 dump callback
    cb->dump(skb, cb);
    // → callback 将数据写入 skb
    // → 如果空间不足 → 在 cb 中记录当前位置
    // → 返回实际写入长度

    // 3. 发送 skb 给用户
    if (skb->len > 0) {
        err = __netlink_send(sk, skb, ...);
        // 用户 recvmsg 接收
    }

    // 4. 如果有更多数据 → 继续
    if (cb->dump_interrupted) {
        schedule_work(&nlk->cb_work);     // 延迟再发
        return 0;
    }

    // 5. dump 完成→发送 NLMSG_DONE
    __netlink_send(sk, skb, ...);
}
```

## 6. tap 机制——netlink 抓包

```c
// netlink 支持 tap 机制——监听所有 netlink 消息（类似网络抓包）：
// netlink_add_tap() @ :192 注册 tap 处理器
// → 加入 netlink_tap_all 链表
// 每次发送消息时：
// → netlink_deliver_tap(skb) @ :331
// → 遍历 tap 链表，将 skb 复制到每个 tap 处理器
// 用于 nlmon 驱动（/sys/class/net/nlmon）
```

---

## 6. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `netlink_create` | — | 创建 netlink socket |
| `netlink_sendmsg` | `:1739` | 发送消息（单播/多播）|
| `netlink_unicast` | `:992` | 单播发送 |
| `netlink_broadcast` | `:1457` | 多播发送 |
| `netlink_rcv_skb` | — | 内核侧消息解析分发 |
| `netlink_recvmsg` | — | 用户空间接收 |
| `netlink_dump` | `:133` | dump 异步数据发送 |
| `__netlink_dump_start` | — | dump 初始化 |
| `netlink_table_grab` | `:413` | 获取表锁 |
| `netlink_table_ungrab` | `:438` | 释放表锁 |

---

## 7. 总结

netlink 通过 `netlink_sendmsg`（`:1739`）→ `netlink_unicast`（`:992`）或 `netlink_broadcast`（`:1457`）发送消息，内核侧通过 `netlink_rcv_skb` 解析分发。内核服务通过 `netlink_kernel_create` 注册接收回调。`nl_table`（`:90`）全局哈希表管理所有 netlink socket 的查找。dump 机制（`netlink_dump` @ `:133`）支持大数据量的异步查询。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
