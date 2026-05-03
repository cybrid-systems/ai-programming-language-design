# 28-netfilter — Linux 内核 Netfilter 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Netfilter** 是 Linux 内核的数据包过滤和网络地址转换（NAT）框架，是 `iptables/nftables` 的底层实现。它在网络协议栈的关键路径上挂载钩子（hook），允许内核模块检查、修改、丢弃或重定向数据包。

Netfilter 的钩子点分布在 IPv4/IPv6 协议栈的 5 个关键位置：

```
数据包穿越协议栈的路径：

          ┌───── LOCAL_IN ────▶ 本地 socket
          │
IN──▶ PRE_ROUTING ──▶ FORWARD ──▶ POST_ROUTING ──▶ OUT
          │                           ▲
          └───── LOCAL_OUT ───────────┘
```

**doom-lsp 确认**：核心实现在 `net/netfilter/` 目录。`nf_hook_slow` 是 hook 执行的核心函数。`struct nf_hook_ops` 定义挂载规则。

---

## 1. Netfilter Hook 架构

```c
// include/linux/netfilter.h
enum nf_inet_hooks {
    NF_INET_PRE_ROUTING,   // 数据包入站，路由决策前
    NF_INET_LOCAL_IN,      // 数据包入站，目标为本地
    NF_INET_FORWARD,       // 数据包转
    NF_INET_LOCAL_OUT,     // 数据包出站，本地发出
    NF_INET_POST_ROUTING,  // 数据包出站，路由决策后
    NF_INET_NUMHOOKS
};

// 返回值（优先级：最高 NF_DROP，最低 NF_ACCEPT）
#define NF_DROP        0   // 丢弃数据包
#define NF_ACCEPT      1   // 继续处理
#define NF_STOLEN      2   // 数据包被接管（不继续）
#define NF_QUEUE       3   // 排队到用户空间
#define NF_REPEAT      4   // 重新执行此 hook
#define NF_STOP        5   // 停止处理（不再继续）
```

---

## 2. 注册 Hook

```c
// net/netfilter/core.c
int nf_register_net_hook(struct net *net, const struct nf_hook_ops *reg);

// 钩子操作结构
struct nf_hook_ops {
    struct list_head    list;
    nf_hookfn           *hook;       // 处理函数
    struct net_device   *dev;        // 绑定设备（NULL=所有）
    struct list_head    *hook_list;  // 所属链表
    int                 pf;          // 协议族（NFPROTO_IPV4 / NFPROTO_IPV6）
    enum nf_inet_hooks  hooknum;     // PRE_ROUTING / LOCAL_IN ...
    int                 priority;    // 优先级（越小越早执行）
};
```

---

## 3. nftables——现代 Netfilter

nftables 是 iptables 的继任者（Linux 3.13）：

```bash
# iptables 语法（旧）：
iptables -A INPUT -s 10.0.0.0/8 -j DROP

# nftables 语法（新）：
nft add rule ip filter INPUT ip saddr 10.0.0.0/8 drop
```

---

## 4. 源码文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/netfilter.h` | 核心结构体 |
| `net/netfilter/core.c` | 核心框架 |
| `net/netfilter/nf_tables_core.c` | nftables 核心 |

---

## 5. 关联文章

- **63-conntrack**：连接跟踪
- **125-nf-conntrack**：连接跟踪深度分析

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

---

## 3. Hook 执行路径——nf_hook_slow

```c
// net/netfilter/core.c — hook 执行（tree.c:612）
int nf_hook_slow(struct sk_buff *skb, struct nf_hook_state *state,
                  const struct nf_hook_entries *e, unsigned int s)
{
    unsigned int verdict;
    int ret;

    // 遍历 hook entries 数组（非链表！）
    for (; s < e->num_hook_entries; s++) {
        verdict = nf_hook_entry_hookfn(&e->hooks[s], skb, state);
        switch (verdict & NF_VERDICT_MASK) {
        case NF_ACCEPT:
            break;            // 继续下一个 hook
        case NF_DROP:
            kfree_skb_reason(skb, SKB_DROP_REASON_NETFILTER_DROP);
            ret = NF_DROP_GETERR(verdict);
            return ret ? ret : -EPERM;
        case NF_QUEUE:
            ret = nf_queue(skb, state, s, verdict);
            if (ret == 1)
                continue;     // 重新处理
            return ret;
        case NF_STOLEN:
            return NF_DROP_GETERR(verdict);
        }
    }
    return 1;  // NF_ACCEPT — 所有 hook 接受
}
```

### 3.1 内核中 hook 的调用点

```c
// 例：IPv4 接收路径中的 hook
// net/ipv4/ip_input.c — PRE_ROUTING 在 ip_rcv 中
int ip_rcv(struct sk_buff *skb, struct net_device *dev, struct packet_type *pt,
           struct net_device *orig_dev)
{
    // PRE_ROUTING hook 点
    return NF_HOOK(NFPROTO_IPV4, NF_INET_PRE_ROUTING,
                   net, NULL, skb, dev, NULL, ip_rcv_finish);
}

// LOCAL_IN 在 ip_local_deliver 中
int ip_local_deliver(struct sk_buff *skb)
{
    // LOCAL_IN hook 点
    return NF_HOOK(NFPROTO_IPV4, NF_INET_LOCAL_IN,
                   net, NULL, skb, skb->dev, NULL, ip_local_deliver_finish);
}
```

```c
// 例：IPv4 转发路径
// net/ipv4/ip_forward.c
int ip_forward(struct sk_buff *skb)
{
    // FORWARD hook 点
    return NF_HOOK(NFPROTO_IPV4, NF_INET_FORWARD,
                   net, NULL, skb, skb->dev, skb_dst(skb)->dev, ip_forward_finish);
}
```

### 3.2 5 个 hook 点的完整路径

```
      ┌─────────────────────────────────────────────────┐
      │                                                 │
      │   NF_INET_LOCAL_IN ──▶ 本地 socket              │
      │       ▲                                        │
      │       │                                        │
  ────┴─── NF_INET_PRE_ROUTING                          │
       │          │                                     │
       │          └──▶ NF_INET_FORWARD ──▶ NF_INET_POST_ROUTING ──▶ OUT
       │                                     ▲
       │                                     │
       └────────── NF_INET_LOCAL_OUT ────────┘
                        ▲
                        │
                  本地 socket 发送
```

---

## 4. conntrack——连接跟踪

连接跟踪（conntrack）是 Netfilter 的核心组件，跟踪所有网络连接的状态：

```bash
# 查看当前连接跟踪表
$ cat /proc/net/nf_conntrack
ipv4 2 tcp 6 431999 ESTABLISHED src=10.0.0.1 dst=10.0.0.2 sport=12345 dport=80
ipv4 2 udp 17 29 src=10.0.0.1 dst=10.0.0.3 sport=53 dport=34567
```

```c
// net/netfilter/nf_conntrack_core.c
struct nf_conn {
    struct nf_conntrack ct_general;
    struct nf_conntrack_tuple_hash tuplehash[IP_CT_DIR_MAX]; // 原/应答方向
    unsigned long status;       // IPS_CONFIRMED, IPS_SEEN_REPLY 等
    struct timer_list timeout;  // 超时定时器
    struct hlist_node *node;    // 哈希表节点
};
```

conntrack 在 `nf_conntrack_in()` 中处理每个数据包，更新连接状态。它是状态防火墙（如 `iptables -m state`）的基础。

---

## 5. NAT——网络地址转换

NAT 利用 conntrack 修改数据包的源/目标地址：

```bash
# 源 NAT（SNAT）：出站流量修改源地址
iptables -t nat -A POST_ROUTING -s 192.168.1.0/24 -j MASQUERADE

# 目标 NAT（DNAT）：入站流量修改目标地址
iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to 10.0.0.100:8080
```

NAT 在 NF_INET_POST_ROUTING 和 NF_INET_PRE_ROUTING 点上注册 hook。

---

## 6. nftables——现代 Netfilter 框架

nftables 是 iptables 的继任者（Linux 3.13+）：

| 特性 | iptables | nftables |
|------|----------|----------|
| 协议族 | 每个工具一个 | 统一的 nft 命令 |
| 性能 | 每次匹配遍历所有规则 | 使用 set/map 优化 |
| 链类型 | 固定 | 可编程 |
| 原子替换 | 部分 | 支持原子规则集替换 |

```bash
# nftables 示例
nft add table ip filter
nft add chain ip filter input { type filter hook input priority 0\; }
nft add rule ip filter input ip saddr 10.0.0.0/8 drop
nft add rule ip filter input tcp dport 22 accept
```

---

## 7. 源码文件索引

| 文件 | 内容 |
|------|------|
| include/linux/netfilter.h | 核心结构体 |
| net/netfilter/core.c | hook 执行框架 |
| net/netfilter/nf_conntrack_core.c | 连接跟踪 |
| net/netfilter/nf_nat_core.c | NAT |
| net/netfilter/nf_tables_core.c | nftables 运行时 |
| include/uapi/linux/netfilter/nf_tables.h | nftables 用户 API |

---

## 8. 关联文章

- **63-conntrack**：连接跟踪详细
- **125-nf-conntrack**：连接跟踪深度

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 9. Netfilter 的用户空间接口

### 9.1 iptables 与内核通信

iptables 通过 `getsockopt` / `setsockopt`（SOL_IP 层）与内核 Netfilter 通信：

```c
// 用户空间 iptables 工具 → 内核
// 使用 setsockopt(IP_SO_SET_REPLACE / IP_SO_SET_ADD_COUNTERS)
// 传输 struct ipt_replace / ipt_entry / ipt_counters

struct ipt_entry {
    struct ipt_ip ip;            // 匹配条件（源/目标 IP、协议等）
    unsigned int nfcache;
    unsigned short target_offset; // target 偏移
    unsigned short next_offset;   // 下一条规则偏移
    unsigned int comefrom;
    struct xt_counters counters;  // 规则计数器
    unsigned char elems[];        // 匹配和 target
};
```

### 9.2 xtables 匹配器

Netfilter 的匹配器（match）是可扩展的：

```c
// 注册匹配器
struct xt_match xt_conntrack_mt_reg = {
    .name       = "conntrack",
    .family     = NFPROTO_UNSPEC,
    .match      = conntrack_mt,
    .checkentry = conntrack_mt_check,
    .destroy    = conntrack_mt_destroy,
    .matchsize  = sizeof(struct xt_conntrack_mtinfo),
    .me         = THIS_MODULE,
};

// 内置匹配器：
// - conntrack: 连接跟踪状态匹配
// - state: 连接状态（NEW/ESTABLISHED/RELATED）
// - addrtype: 地址类型
// - limit: 速率限制
// - recent: 最近匹配
// - mark: 数据包标记匹配
```

---

## 10. Netfilter 性能

| 操作 | 延迟 | 说明 |
|------|------|------|
| 无规则（empty table）| ~20ns | hook 检查 + 直接返回 NF_ACCEPT |
| 简单 iptables 规则 | ~100-200ns | 匹配 + 跳转 target |
| conntrack（已建立连接）| ~100-300ns | 哈希查找 + 状态更新 |
| conntrack（新连接）| ~1-3μs | 创建新 nf_conn + 插入哈希表 |
| nftables set 查找 | ~50-100ns | 哈希/区间树查找 |
| 大量规则（1000+）| ~1-10μs | 线性遍历所有规则 |

---

## 11. 网络栈中的 Netfilter 插入点

```c
// net/ipv4/ip_input.c — 数据包入站
NF_HOOK(NFPROTO_IPV4, NF_INET_PRE_ROUTING, ...)  // 路由前
NF_HOOK(NFPROTO_IPV4, NF_INET_LOCAL_IN, ...)     // 本地入

// net/ipv4/ip_forward.c — 转发
NF_HOOK(NFPROTO_IPV4, NF_INET_FORWARD, ...)

// net/ipv4/ip_output.c — 数据包出站
NF_HOOK(NFPROTO_IPV4, NF_INET_LOCAL_OUT, ...)    // 本地出
NF_HOOK(NFPROTO_IPV4, NF_INET_POST_ROUTING, ...) // 路由后
```

宏 `NF_HOOK` 展开为：
```c
#define NF_HOOK(pf, hook, net, okfn, ...)   \
    if (nf_hook_slow(skb, &state, ...) != 1) \
        goto out;                            \
    okfn(skb);  // hook 全部返回 NF_ACCEPT 后执行
```

---

## 12. ipset——高效 IP 集合

ipset 是 Netfilter 的扩展，提供高效的集合匹配：

```bash
# 创建 ipset
ipset create blacklist hash:ip

# 添加 IP
ipset add blacklist 10.0.0.1
ipset add blacklist 10.0.0.0/24

# 在 iptables 中引用
iptables -A INPUT -m set --match-set blacklist src -j DROP
```

ipset 使用哈希/区间树实现 O(1) 查找，比 iptables 的逐条匹配快得多。

---

## 13. 调试 Netfilter

```bash
# 查看 conntrack 表
cat /proc/net/nf_conntrack

# 查看 conntrack 统计
cat /proc/sys/net/netfilter/nf_conntrack_count

# iptables 规则列表
iptables -L -n -v    # -v 显示计数器
iptables -L -t nat   # NAT 表

# nftables 规则列表
nft list ruleset

# 查看 hook 注册情况
cat /proc/net/netfilter/nf_log
```

---

## 14. 总结

Netfilter 是 Linux 网络安全的基石。5 个 hook 点覆盖了数据包穿越协议栈的完整路径。conntrack 跟踪连接状态，NAT 修改地址，nftables 提供可编程的规则引擎。所有防火墙、NAT、流量控制工具（iptables/nftables）都构建在此框架之上。


## 15. 排队到用户空间（NF_QUEUE）

```bash
# 将数据包排队到用户空间处理
iptables -A INPUT -j NFQUEUE --queue-num 0

# 用户空间程序接收数据包
# libnetfilter_queue 库
nfq_bind(handle, 0);  // 绑定队列 0
nfq_set_mode(handle, NFQNL_COPY_PACKET, 0xffff);
while (recv()) {
    struct nfq_data *nfad = nfq_get_msg_packet_hdr(msg);
    nfq_get_payload(nfad, &data);  // 获取数据包
    // 修改或检查数据包
    nfq_set_verdict(handle, id, NF_ACCEPT, 0, NULL);  // 放行
}
```

内核中 `NF_QUEUE` 的处理：
```c
// net/netfilter/nf_queue.c
int nf_queue(struct sk_buff *skb, struct nf_hook_state *state, ...)
{
    struct nf_queue_entry *entry = kmalloc(sizeof(*entry), GFP_ATOMIC);
    entry->state = *state;
    entry->skb = skb;
    // 将 entry 发送到用户空间监听程序
    __nf_queue(entry);
    return 0;
}
```

---

## 16. xtables 的 target 和 match 架构

```c
// 标准 target（ACCEPT、DROP、RETURN）
struct xt_target {
    const char *name;
    unsigned int (*target)(struct sk_buff *skb, const struct xt_action_param *);
    int (*checkentry)(const struct xt_tgchk_param *);
    void (*destroy)(const struct xt_tgdtor_param *);
    unsigned int targetsize;
    unsigned int family;  // NFPROTO_IPV4/IPV6/UNSPEC
    struct module *me;
};

// 标准 match
struct xt_match {
    const char *name;
    bool (*match)(const struct sk_buff *skb, struct xt_action_param *);
    int (*checkentry)(const struct xt_mtchk_param *);
    void (*destroy)(const struct xt_mtdtor_param *);
    unsigned int matchsize;
    unsigned int family;
    struct module *me;
};
```

---

## 17. 源 / 目标校验

```bash
# SNAT（POST_ROUTING）：修改源 IP
iptables -t nat -A POST_ROUTING -o eth0 -j SNAT --to 203.0.113.1

# DNAT（PREROUTING）：修改目标 IP
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 80 \
         -j DNAT --to 192.168.1.100:8080

# MASQUERADE（动态 SNAT，用于 PPPoE）
iptables -t nat -A POST_ROUTING -o ppp0 -j MASQUERADE
```

NAT hook 优先级：
```
NF_INET_PRE_ROUTING:   conntrack → DNAT → 路由决策
NF_INET_POST_ROUTING:  路由决策 → SNAT → 出站
NF_INET_LOCAL_OUT:     conntrack → DNAT → 路由 → SNAT
NF_INET_LOCAL_IN:      conntrack → 路由 → 本地
```


## 18. 日志（NF_LOG）

```bash
# 记录所有丢弃的数据包到内核日志
iptables -A INPUT -j LOG --log-prefix "DROP: " --log-level 4
iptables -A INPUT -j DROP

# nftables 日志
nft add rule ip filter input log prefix "DROP: " drop
```

`NF_LOG` 通过 `printk` 将数据包信息写入内核日志，对性能有影响（每个数据包 ~1-5μs）。

---

## 19. 官方文档

- 内核文档: `Documentation/networking/netfilter/`
- nftables wiki: https://wiki.nftables.org/
- libnetfilter_queue: https://netfilter.org/projects/libnetfilter_queue/

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 20. 快速参考

| 命令 | 作用 |
|------|------|
| iptables -L -n -v | 查看规则和计数器 |
| iptables -F | 清空所有规则 |
| iptables -t nat -L | 查看 NAT 规则 |
| iptables-save | 导出规则集 |
| iptables-restore | 导入规则集 |
| nft list ruleset | 查看 nftables 规则 |
| conntrack -L | 查看连接跟踪 |
| conntrack -E | 实时监控连接 |
| ipset list | 查看 ipset 集合 |
