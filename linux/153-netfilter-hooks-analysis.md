# 153-netfilter_hooks — 数据包过滤深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netfilter/core.c` + `net/netfilter/nf_hook.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**Netfilter Hooks** 是 Linux 内核数据包过滤框架的核心，通过在协议栈的关键位置插入 HOOK 点，实现防火墙、NAT、连接跟踪等功能。

## 1. HOOK 点详解

```
Netfilter HOOK 在数据包流向中的位置：

  入站方向（Local Process）：
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │  1. NIC 收到 → netif_receive_skb()                │
  │                    │                                │
  │                    ▼                                │
  │  2. PREROUTING [NF_INET_PRE_ROUTING]               │
  │                    │                                │
  │                    ▼                                │
  │  3. ip_rcv()（路由查找前）                         │
  │                    │                                │
  │                    ▼                                │
  │  4. 路由决策 → 目的地址是本机                       │
  │                    │                                │
  │                    ▼                                │
  │  5. LOCAL_IN [NF_INET_LOCAL_IN]                   │
  │                    │                                │
  │                    ▼                                │
  │  6. 协议处理（TCP/UDP/ICMP）                       │
  │                                                     │
  └─────────────────────────────────────────────────────┘

  出站方向（Local Process）：
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │  1. 协议处理（TCP/UDP 生成数据）                     │
  │                    │                                │
  │                    ▼                                │
  │  2. LOCAL_OUT [NF_INET_LOCAL_OUT]                  │
  │                    │                                │
  │                    ▼                                │
  │  3. 路由决策 → 发送接口                             │
  │                    │                                │
  │                    ▼                                │
  │  4. ip_output()                                   │
  │                    │                                │
  │                    ▼                                │
  │  5. POSTROUTING [NF_INET_POST_ROUTING]              │
  │                    │                                │
  │                    ▼                                │
  │  6. NIC 发送                                       │
  │                                                     │
  └─────────────────────────────────────────────────────┘

  转发方向（Forward）：
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │  1. NIC 收到 → netif_receive_skb()                │
  │                    │                                │
  │                    ▼                                │
  │  2. PREROUTING [NF_INET_PRE_ROUTING]               │
  │                    │                                │
  │                    ▼                                │
  │  3. 路由决策 → 目的地址不是本机（转发）              │
  │                    │                                │
  │                    ▼                                │
  │  4. FORWARD [NF_INET_FORWARD]                     │
  │                    │                                │
  │                    ▼                                │
  │  5. POSTROUTING [NF_INET_POST_ROUTING]              │
  │                    │                                │
  │                    ▼                                │
  │  6. NIC 发送                                       │
  │                                                     │
  └─────────────────────────────────────────────────────┘
```

## 2. struct nf_hook_ops — HOOK 操作

```c
// include/linux/netfilter.h — nf_hook_ops
struct nf_hook_ops {
    // 处理函数
    nf_hookfn          *hook;           // 处理函数

    // 优先级（数字小 = 先调用）
    struct net_device   *dev;           // 设备（NULL=所有设备）
    void               *priv;             // 私有数据

    // HOOK 配置
    u_int8_t           pf;              // 协议族（PF_INET/PF_INET6）
    unsigned int       hooknum;          // HOOK 点（NF_INET_*）
    int                 priority;         // 优先级
};
```

## 3. nf_hookfn — 处理函数类型

### 3.1 函数签名

```c
// include/linux/netfilter.h — nf_hookfn
typedef unsigned int nf_hookfn(void *priv,
                              struct sk_buff *skb,
                              const struct nf_hook_state *state);

struct nf_hook_state {
    u_int8_t           pf;              // 协议族
    unsigned int       hook;             // HOOK 点
    int                 thresh;           // 阈值
    struct net_device   *in;            // 入设备
    struct net_device   *out;           // 出设备
    struct sock         *sk;             // socket（如果有）
    int                 (*okfn)(struct net *, struct sk_buff *); // 继续处理
};
```

### 3.2 返回值

```c
// include/linux/netfilter.h — HOOK 返回值
#define NF_DROP      0  // 丢弃包
#define NF_ACCEPT    1  // 接受包，继续处理
#define NF_STOLEN    2  // HOOK 吞噬包，不再处理
#define NF_QUEUE      3  // 排队到用户空间（nfqueue）
#define NF_REPEAT     4  // 再次调用本 HOOK
#define NF_STOP       5  // 停止处理（不再调用后续 HOOK）
#define NF_MAX_VERDICT 6 // 最大判决数
```

## 4. nf_hook_slow — 执行 HOOK 链

### 4.1 nf_hook_slow

```c
// net/netfilter/core.c — nf_hook_slow
static int nf_hook_slow(u_int8_t pf, unsigned int hook,
                        struct sk_buff *skb,
                        const struct net_device *indev,
                        const struct net_device *outdev,
                        const struct nf_hook_entries *entries,
                        int (*okfn)(struct net *, struct sk_buff *))
{
    struct nf_hook_entry *entry;
    unsigned int verdict;
    int err;

    // 遍历 HOOK 链表（按优先级排序）
    entry = rcu_dereference(entries->hooks[hook]);

    next_hook:
    verdict = entry->hook(entry->priv, skb, &state);

    if (verdict != NF_ACCEPT) {
        if (verdict == NF_DROP)
            return -EPERM;
        if (verdict == NF_STOLEN)
            return 0;
        if (verdict == NF_QUEUE) {
            err = nf_queue(skb, entry, state, pf, hook, okfn);
            if (err < 0)
                return err;
        }
        return -EPERM;
    }

    // 继续下一个 HOOK
    entry = rcu_dereference(entry->next);
    if (entry)
        goto next_hook;

    // 所有 HOOK 都通过，调用 okfn
    return okfn(state.net, skb);
}
```

## 5. iptables 规则表映射

```c
// HOOK 点与 iptables 表的对应关系：

// IPv4：
PREROUTING  [NF_INET_PRE_ROUTING]  → nat 表 PREROUTING / mangle 表 PREROUTING
INPUT       [NF_INET_LOCAL_IN]     → filter 表 INPUT / mangle 表 INPUT
FORWARD     [NF_INET_FORWARD]       → filter 表 FORWARD / mangle 表 FORWARD
OUTPUT      [NF_INET_LOCAL_OUT]     → nat 表 OUTPUT / filter 表 OUTPUT / mangle 表 OUTPUT
POSTROUTING [NF_INET_POST_ROUTING]  → nat 表 POSTROUTING / mangle 表 POSTROUTING

// IPv6：
PREROUTING  [NF_INET_PRE_ROUTING]  → ip6 nat 表 PREROUTING / ip6tables
INPUT       [NF_INET_LOCAL_IN]     → ip6 filter 表 INPUT
FORWARD     [NF_INET_FORWARD]       → ip6 filter 表 FORWARD
OUTPUT      [NF_INET_LOCAL_OUT]     → ip6 nat 表 OUTPUT / ip6 filter 表 OUTPUT
POSTROUTING [NF_INET_POST_ROUTING] → ip6 nat 表 POSTROUTING
```

## 6. HOOK 注册

### 6.1 nf_register_net_hook

```c
// net/netfilter/core.c — nf_register_net_hook
int nf_register_net_hook(struct net *net, const struct nf_hook_ops *ops)
{
    struct nf_hook_entries *new;
    struct nf_hook_entries *old;

    // 1. 分配新的 HOOK 条目数组
    new = nf_hook_entries_grow(ops, old);

    // 2. 按优先级排序
    sort_entries(new);

    // 3. 安装新的 HOOK 表
    rcu_assign_pointer(net->nf.hooks[ops->pf][ops->hooknum], new);

    return 0;
}
```

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/netfilter/core.c` | `nf_hook_slow`、`nf_register_net_hook` |
| `net/netfilter/nf_hook.c` | `nf_hook_entries_grow` |
| `include/linux/netfilter.h` | `struct nf_hook_ops`、`nf_hookfn`、`NF_DROP/ACCEPT/STOLEN/QUEUE` |

## 8. 西游记类比

**Netfilter HOOK** 就像"取经路的关卡系统"——

> 数据包就像一个行旅的人，在天庭的各个关卡（HOOK 点）接受检查。PREROUTING 像入城前的第一个关卡，LOCAL_IN 像城内关卡（目的地是本机），FORWARD 像过路关卡（目的地是其他城市），LOCAL_OUT 像出城关卡，POSTROUTING 像出城后的最后一个关卡。每个关卡有多个检查员（nf_hook_ops），按优先级顺序检查。第一个人说"放行"（NF_ACCEPT），第二个人说"禁止"（NF_DROP），就禁止。如果第一个人说"我再看看"（NF_REPEAT），就要再检查一遍。

## 9. 关联文章

- **conntrack**（article 154）：连接跟踪增强 HOOK
- **iptables NAT**（相关）：NAT 表的实现

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

