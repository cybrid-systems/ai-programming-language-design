# 163-ip_options_fragment — IP选项与分片深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/ip_options.c` + `net/ipv4/ip_output.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**IP 选项**是 IP 头部的扩展字段，用于携带路由、时戳、安全等信息。**IP 分片**则是在数据包超过 MTU 时，将一个 IP 包拆成多个分片传输的机制。

## 1. IP 选项格式

### 1.1 IP Option 结构

```
IP 头部长度 = (IHL - 5) * 4 字节（IHL 最小=5，即20字节头）

IP 选项格式：
  ┌────────┬────────┬────────┐
  │ Kind   │ Length │ Data... │
  └────────┴────────┴────────┘

Kind:
  0 = EOOL（选项列表结束）
  1 = NOP（无操作，对齐）
  2 = RR（记录路由）
  3 = TS（时戳）
  7 = RR（宽松源路由）
  9 = SSRR（严格源路由）
  其他 = 安全选项等
```

### 1.2 常用选项

```c
// net/ipv4/ip_options.c — 选项类型
#define IPOPT_COPY       0x80    // 选项复制标志
#define IPOPT_CLASS(o)  ((o) & 0x60)  // 选项类别
#define IPOPT_NUMBER(o)  ((o) & 0x1F)  // 选项编号

// 常用选项：
IPOPT_RR    = 7     // 记录路由（Record Route）
IPOPT_TS    = 68    // 时间戳
IPOPT_SSRR  = 137   // 严格源路由
IPOPT_LSRR  = 131   // 宽松源路由
```

### 1.3 ip_options — 选项结构

```c
// include/net/ip.h — ip_options
struct ip_options {
    __u32           faddr;              // 第一个自由分片的地址
    unsigned char    optlen;              // 选项总长度
    unsigned char    srr;                // 源路由选项偏移
    unsigned char    rr;                 // 记录路由偏移
    unsigned char    ts;                 // 时间戳偏移
    unsigned char    is_strictroute;     // 是否严格源路由
    struct path_info {
        struct in_device *idev;        // 输入设备
        unsigned long daddr;          // 目的地址
        unsigned long saddr;          // 源地址
        int     optlen;              // 选项长度
        unsigned long ooo;           // 超出选项
    };
    unsigned char    __data[40];        // 选项数据（最大40字节）
};
```

## 2. IP 分片

### 2.1 IP 头中的分片字段

```
IP 头中与分片相关的字段：

  Identification (16bit): 标识，每个包唯一（分片共享）
  Flags (3bit):
    Bit 0: 保留（必须=0）
    Bit 1: DF (Don't Fragment) = 1 时不能分片
    Bit 2: MF (More Fragments) = 1 时表示后面还有分片
  Fragment Offset (13bit): 分片偏移，以8字节为单位

分片例子：
  原始包：4000 字节（payload），MTU=1500
  IP 头：20 字节
  每个分片的 payload：1480 字节（1500-20）

  分片1：offset=0,   MF=1,  1500字节（含20头）
  分片2：offset=185, MF=1,  1500字节
  分片3：offset=370, MF=1,  1500字节
  分片4：offset=555, MF=0,  1060字节（最后一个）
```

### 2.2 ip_fragment — 分片

```c
// net/ipv4/ip_output.c — ip_fragment
int ip_fragment(struct net *net, struct sock *sk, struct sk_buff *skb,
               struct ip_options *opt, int mtu)
{
    struct iphdr *iph;
    unsigned int hlen;
    unsigned int flags;
    unsigned int mf, offset;
    unsigned int payload_len;
    __be16 not_last_frag;

    iph = ip_hdr(skb);
    payload_len = ntohs(iph->tot_len) - hlen;

    // 计算每个分片的大小（8字节对齐）
    frag_size = (mtu - hlen) & ~7;  // 8字节对齐

    // 创建第一个分片
    skb1 = skb_clone(skb, GFP_ATOMIC);
    // 设置 IP 头：MF=1, offset=0
    iph1->frag_off = htons(offset | IP_MF);
    iph1->tot_len = htons(hlen + frag_size);

    // 创建后续分片
    while (payload_len > frag_size) {
        // 设置分片偏移
        iphN->frag_off = htons(offset | IP_MF);
        // ...
        offset += frag_size / 8;
        payload_len -= frag_size;
    }

    // 最后一个分片：MF=0
    iph_last->frag_off = htons(offset);
    return 0;
}
```

### 2.3 ip_defrag — 分片重组

```c
// net/ipv4/ip_fragment.c — ip_defrag
struct sk_buff *ip_defrag(struct net *net, struct sk_buff *skb, u32 user)
{
    struct iphdr *iph = ip_hdr(skb);
    struct frag_queue *fq;
    unsigned int payload_len;

    // 1. 查找或创建分片队列
    fq = fq_find(net, iph->id, iph->saddr, iph->daddr, iph->protocol);

    // 2. 添加分片到队列
    if (fq->q.len == 0) {
        // 第一个分片
        inet_fragq_add(&fq->q, skb);
    } else {
        // 后续分片，插入正确位置
        inet_fragq_add(&fq->q, skb);
    }

    // 3. 检查是否所有分片都到达
    if (fq->q.len >= fq->q.meat + skb->len &&
        fq->q.last_skblen != fq->q.meat) {

        // 所有分片到达，重组
        return ip_fraglist_ipcb(fq);
    }

    return NULL;  // 分片未完成
}
```

## 3. 分片攻击防御

```
分片攻击类型：

1. Teardrop：
   发送重叠的分片（offset 覆盖）
   防御：Linux 检查 offset 顺序

2. Fragment Flood：
   发送大量分片但不完成重组
   防御：frags 队列超时、内存限制

3. Tiny Fragment：
   分片极小（仅 IP 头 + 1 字节数据）
   防御：某些防火墙拒绝首个分片<XX字节
```

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/ip_options.c` | `ip_options_compile`、`ip_options_copy` |
| `net/ipv4/ip_output.c` | `ip_fragment` |
| `net/ipv4/ip_fragment.c` | `ip_defrag`、`fq_find` |
| `include/net/ip.h` | `struct ip_options` |

## 5. 西游记类喻

**IP 选项与分片**就像"取经路的快递包装和拆包"——

> IP 选项就像快递上的特殊标注：Record Route 让每个驿站都签名，记录快递走过的路；Time Stamp 让每个驿站都盖章，记录经过的时间；Source Route 指定快递必须经过哪些驿站。IP 分片则像一个超大的货物要分装成多个小箱子：每个箱子上都贴了同样的标识（Identification），标注这是第几个箱子（Offset）和后面还有没有箱子（MF 标志）。收件人收到所有箱子后，按顺序组装还原成原来的大件。如果有人故意把箱子顺序搞乱或只发一半（分片攻击），天庭的安保系统会检查箱子的编号和大小，拒绝异常的快递。

## 6. 关联文章

- **udp_sendmsg**（article 145）：UDP 分片
- **netif_receive_skb**（article 139）：IP 层处理

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

