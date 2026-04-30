# Linux Kernel tcp_conntrack / NAT 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netfilter/nf_conntrack_netlink.c` + `net/netfilter/nat/core.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 conntrack？

**conntrack（Connection Tracking）** 是 netfilter 的**连接跟踪**模块，维护所有 TCP/UDP/ICMP 会话状态，用于：
- **NAT**（网络地址转换）
- **状态防火墙**（ESTABLISHED 放行）
- **端口转发**
- **conntrack 调试**（/proc/net/stat/nf_conntrack）

---

## 1. 核心数据结构

```c
// include/net/netfilter/nf_conntrack.h — nf_conn
struct nf_conn {
    struct nf_conntrack_tuple_hash   *tuple_hash;

    /* 元组（双向）*/
    struct {
        struct nf_conntrack_tuple tuplehash[IP_CT_DIR_MAX];
        // tuplehash[IP_CT_DIR_ORIGINAL] — 发起方
        // tuplehash[IP_CT_DIR_REPLY]   — 响应方
    };

    struct nf_conn_help           *help;      // NAT helper
    struct nf_conntrack_l4proto  *master;
    unsigned long               status;     // 状态（BIT）
    u32                         timeout;

    /* 协议相关 */
    union {
        struct nf_conntrack_tcp  *tcp;
        struct nf_conntrack_udp  *udp;
    };
};

// nf_conntrack_tuple — 连接元组
struct nf_conntrack_tuple {
    struct {
        __be32          src_ip;
        __be32          dst_ip;
        union nf_conntrack_l4proto src.l4data;
        union nf_conntrack_l4proto dst.l4data;
    } src, dst;
    u8   protonum;  // IPPROTO_TCP / UDP / ICMP
};
```

---

## 2. TCP 状态机

```
TCP 连接跟踪状态：

NONE                → 新连接（未建立）
SYN_SENT           → 发送 SYN
SYN_RECV           → 收到 SYN+ACK
ESTABLISHED         → 3 次握手完成
FIN_WAIT           → 收到 FIN
CLOSE_WAIT         → 本地关闭，远程可能还有数据
LAST_ACK           → 最后 ACK
TIME_WAIT          → 等待 2MSL
CLOSED             → 完全关闭
```

---

## 3. NAT（网络地址转换）

```c
// net/netfilter/nat/core.c — nf_nat_alloc_struct
struct nf_nat_range {
    __u32              min_addr;         // 转换后起始 IP
    __u32              max_addr;         // 转换后结束 IP
    __be16             min_proto;        // 转换后起始端口
    __be16             max_proto;
    u32               flags;
};

// NAT 类型：
//   SNAT（Source NAT）：修改源地址（内网→外网）
//   DNAT（Dest NAT）：修改目标地址（外网→内网）
//   FULLCONENAT：同时修改源和目标（透明代理）
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `net/netfilter/nf_conntrack_core.c` | conntrack 核心 |
| `net/netfilter/nf_conntrack_netlink.c` | 用户空间接口 |
| `net/netfilter/nat/core.c` | NAT 核心 |
| `include/net/netfilter/nf_conntrack.h` | `struct nf_conn` |
