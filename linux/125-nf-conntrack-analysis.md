# Linux Kernel nf_conntrack / NAT 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netfilter/nf_conntrack_core.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：tuple、conntrack、NAT、状态机、哈希表

## 0. conntrack 概述

**nf_conntrack** 是 netfilter 的连接跟踪模块，维护所有 TCP/UDP/ICMP 会话状态，是 NAT 和状态防火墙的基础。

## 1. 核心数据结构

### 1.1 nf_conntrack_tuple — 连接元组

```c
// include/net/netfilter/nf_conntrack_tuple.h — nf_conntrack_tuple
struct nf_conntrack_tuple {
    // 源（original direction）
    union nf_inet_addr {
        __be32          all[4];        // IPv4: all[0] = saddr
        struct in6_addr all[4];       // IPv6
    } src;

    // 目标（reply direction 会交换 src 和 dst）
    union nf_inet_addr dst;

    // 协议信息
    struct {
        __be16          l3num;        // AF_INET / AF_INET6
        __u8            protonum;     // IPPROTO_TCP / UDP / ICMP
        union nf_conntrack_l4proto {
            struct nf_conntrack_l4proto *protocol; // 协议特定信息
        } u;
    } dst;
};
```

### 1.2 nf_conn — 连接

```c
// include/net/netfilter/nf_conntrack.h:74 — struct nf_conn
struct nf_conn {
    // 通用元数据
    struct nf_conntrack          ct_general;

    // 哈希表节点（两个方向）
    // tuplehash[IP_CT_DIR_ORIGINAL] = 发起方元组
    // tuplehash[IP_CT_DIR_REPLY]   = 响应方元组
    struct nf_conntrack_tuple_hash  tuplehash[IP_CT_DIR_MAX];

    // 状态
    // IPS_EXPECTED:      预期连接（如 FTP 数据通道）
    // IPS_SEEN_REPLY:    见过响应
    // IPS_ASSURED:       确认连接（不会在压力下被删除）
    // IPS_SRC_NAT:       源 NAT
    // IPS_DST_NAT:       目标 NAT
    unsigned long                 status;

    // 命名空间
    possible_net_t                ct_net;

    // 协议相关
    union {
        struct nf_ct_ext *extension; // 扩展
        struct nf_conntrack_tcp *tcp; // TCP 状态
        struct nf_conntrack_udp *udp; // UDP 状态
    };

    // NAT 穿越信息
    struct {
        struct nf_conntrack_tuple  manipulable; // NAT 可操作的元组
    } nat;

    // 辅助数据（helper, nat, timeout, etc.）
    union {
        void                      *data;
    };
};
```

### 1.3 nf_conntrack_tuple_hash — 哈希表键

```c
struct nf_conntrack_tuple_hash {
    // 元组（作为 key）
    struct nf_conntrack_tuple      tuple;

    // 哈希链表节点（接入 nf_conntrack_hash）
    struct hlist_nulls_node        hnnode;

    // 计数器
    atomic_t                      ufc_entry_usage;
};
```

## 2. 哈希表结构

```c
// net/netfilter/nf_conntrack_core.c — 全局哈希表
struct hlist_nulls_head *nf_conntrack_hash __read_mostly;  // 行 63

// 每个 bucket 是一个 nulls 头，支持 resize
// 哈希大小：nf_conntrack_htable_size（默认 16384）
// 最大连接数：nf_conntrack_max（默认 65536）
```

## 3. conntrack 查找

```c
// net/netfilter/nf_conntrack_core.c — nf_conntrack_find_get
static struct nf_conntrack_tuple_hash *
nf_conntrack_find_get(const struct net *net, u32 zone,
              const struct nf_conntrack_tuple *tuple)
{
    struct nf_conntrack_tuple_hash *h;
    unsigned int hash;

    // 1. 计算元组哈希
    hash = nf_conntrack_hash(tuple);

    // 2. 在哈希桶中查找
    hlist_nulls_for_each_entry_rcu(h, &nf_conntrack_hash[hash], hnnode) {
        if (nf_ct_tuple_cmp(&h->tuple, tuple, zone) == 0) {
            // 找到：增加引用计数
            refcount_inc(&nf_ct_hlist_nfct(h)->ct_general.use);
            return h;
        }
    }

    return NULL;
}
```

## 4. NAT（网络地址转换）

```c
// include/net/netfilter/nf_nat.h — nf_nat_range
struct nf_nat_range {
    // 转换后 IP 范围
    union nf_inet_addr       min_addr;
    union nf_inet_addr       max_addr;

    // 转换后端口范围（16-bit）
    __be16                   min_proto;
    __be16                   max_proto;

    // 标志
    unsigned int             flags;
    #define NF_NAT_RANGE_MAP_IPS    1
    #define NF_NAT_RANGE_PROTO_SPECIFIED 2
    #define NF_NAT_RANGE_PROTO_RANDOM   4
};
```

## 5. TCP 状态机

```
TCP conntrack 状态（内核维护）：

NONE                     → 新连接
SYN_SENT                → 发送了 SYN
SYN_RECV                → 收到 SYN+ACK
ESTABLISHED             → 3 次握手完成
FIN_WAIT                → 收到 FIN
CLOSE_WAIT              → 本地关闭
LAST_ACK                → 最后 ACK
TIME_WAIT               → 等待 2MSL
CLOSED                  → 完全关闭
```

## 6. 参考

| 文件 | 函数 | 行 |
|------|------|-----|
| `include/net/netfilter/nf_conntrack.h` | `struct nf_conn` | 74 |
| `include/net/netfilter/nf_conntrack_tuple.h` | `struct nf_conntrack_tuple` | tuple |
| `net/netfilter/nf_conntrack_core.c` | `nf_conntrack_find_get` | 查找 |
| `net/netfilter/nf_conntrack_core.c` | `nf_conntrack_hash` | 哈希计算 |
| `net/netfilter/nf_conntrack_tcp.c` | TCP 状态机 | |


---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `include/linux/list.h` | 51 | 0 | 51 | 0 |
| `include/linux/sched.h` | 567 | 70 | 134 | 7 |
| `include/linux/mm.h` | 793 | 24 | 527 | 18 |

### 核心数据结构

- **audit_context** `sched.h:58`
- **bio_list** `sched.h:59`
- **blk_plug** `sched.h:60`
- **bpf_local_storage** `sched.h:61`
- **bpf_run_ctx** `sched.h:62`
- **bpf_net_context** `sched.h:63`
- **capture_control** `sched.h:64`
- **cfs_rq** `sched.h:65`
- **fs_struct** `sched.h:66`
- **futex_pi_state** `sched.h:67`
- **io_context** `sched.h:68`
- **io_uring_task** `sched.h:69`
- **mempolicy** `sched.h:70`
- **nameidata** `sched.h:71`
- **nsproxy** `sched.h:72`
- **perf_event_context** `sched.h:73`
- **perf_ctx_data** `sched.h:74`
- **pid_namespace** `sched.h:75`
- **pipe_inode_info** `sched.h:76`
- **rcu_node** `sched.h:77`
- **reclaim_state** `sched.h:78`
- **robust_list_head** `sched.h:79`
- **root_domain** `sched.h:80`
- **rq** `sched.h:81`
- **sched_attr** `sched.h:82`

### 关键函数

- **INIT_LIST_HEAD** `list.h:43`
- **__list_add_valid** `list.h:136`
- **__list_del_entry_valid** `list.h:142`
- **__list_add** `list.h:154`
- **list_add** `list.h:175`
- **list_add_tail** `list.h:189`
- **__list_del** `list.h:201`
- **__list_del_clearprev** `list.h:215`
- **__list_del_entry** `list.h:221`
- **list_del** `list.h:235`
- **list_replace** `list.h:249`
- **list_replace_init** `list.h:265`
- **list_swap** `list.h:277`
- **list_del_init** `list.h:293`
- **list_move** `list.h:304`
- **list_move_tail** `list.h:315`
- **list_bulk_move_tail** `list.h:331`
- **list_is_first** `list.h:350`
- **list_is_last** `list.h:360`
- **list_is_head** `list.h:370`
- **list_empty** `list.h:379`
- **list_del_init_careful** `list.h:395`
- **list_empty_careful** `list.h:415`
- **list_rotate_left** `list.h:425`
- **list_rotate_to_front** `list.h:442`
- **list_is_singular** `list.h:457`
- **__list_cut_position** `list.h:462`
- **list_cut_position** `list.h:488`
- **list_cut_before** `list.h:515`
- **__list_splice** `list.h:531`
- **list_splice** `list.h:550`
- **list_splice_tail** `list.h:562`
- **list_splice_init** `list.h:576`
- **list_splice_tail_init** `list.h:593`
- **list_count_nodes** `list.h:755`

### 全局变量

- **__tracepoint_sched_set_state_tp** `sched.h:350`
- **__tracepoint_sched_set_need_resched_tp** `sched.h:352`
- **def_root_domain** `sched.h:407`
- **sched_domains_mutex** `sched.h:408`
- **cad_pid** `sched.h:1749`
- **init_stack** `sched.h:1964`
- **class_migrate_is_conditional** `sched.h:2519`
- **_totalram_pages** `mm.h:53`
- **high_memory** `mm.h:74`
- **sysctl_legacy_va_layout** `mm.h:86`
- **mmap_rnd_bits_min** `mm.h:92`
- **mmap_rnd_bits_max** `mm.h:93`
- **mmap_rnd_bits** `mm.h:94`
- **sysctl_user_reserve_kbytes** `mm.h:210`
- **sysctl_admin_reserve_kbytes** `mm.h:211`

### 成员/枚举

- **utime** `sched.h:366`
- **stime** `sched.h:367`
- **lock** `sched.h:368`
- **seqcount** `sched.h:386`
- **starttime** `sched.h:387`
- **state** `sched.h:388`
- **cpu** `sched.h:389`
- **utime** `sched.h:390`
- **stime** `sched.h:391`
- **gtime** `sched.h:392`
- **sched_priority** `sched.h:413`
- **pcount** `sched.h:421`
- **run_delay** `sched.h:424`
- **max_run_delay** `sched.h:427`
- **min_run_delay** `sched.h:430`
- **last_arrival** `sched.h:435`
- **last_queued** `sched.h:438`
- **max_run_delay_ts** `sched.h:441`
- **weight** `sched.h:461`
- **inv_weight** `sched.h:462`

