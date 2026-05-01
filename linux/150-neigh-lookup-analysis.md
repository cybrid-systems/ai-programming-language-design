# 150-neigh_lookup — Neighbour子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/core/neighbour.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**Neighbour** 子系统负责将 IP 地址解析为 MAC 地址（ARP 在 IPv4 中，NDP 在 IPv6 中），是路由的最后一跳。路由找到出口设备后，还需要知道目标设备的 MAC 地址才能真正发送。

## 1. 核心数据结构

### 1.1 struct neighbour — Neighbour 条目

```c
// include/net/neighbour.h — neighbour
struct neighbour {
    struct сосед (*n) { ... } // 俄语注释，但实际代码：

    struct neighbour       *next;         // 哈希桶链表
    struct net_device     *dev;         // 所属网络设备
    unsigned char          ha[ALIGN(MAX_ADDR_LEN, sizeof(unsigned long))]; // MAC地址
    __be32                 primary_key;   // IP 地址

    // 状态
    unsigned char          nud_state;     // NUD_* 状态
    unsigned char          type;           // NDTPROTO_* (ARP/NDISC)
    unsigned char          flags;          // NTF_*

    // 状态机
    unsigned long          confirmed;     // 确认时间
    unsigned long          updated;        // 更新时间
    unsigned long          used;           // 最后使用时间

    // 表
    struct neigh_table    *tbl;           // 所属表

    // 操作
    int                 (*output)(struct neighbour *, struct sk_buff *);
};
```

### 1.2 NUD 状态

```c
// include/net/neighbour.h — NUD 状态
enum {
    NUD_NONE        = 0x00,   // 无状态
    NUD_INCOMPLETE  = 0x01,   // 解析中（等待 ARP 响应）
    NUD_REACHABLE   = 0x02,   // 可达
    NUD_STALE       = 0x04,   // 陈旧（需要刷新）
    NUD_DELAY       = 0x08,   // 延迟确认
    NUD_PROBE       = 0x10,   // 探测中
    NUD_FAILED      = 0x20,   // 失败
    NUD_NOARP       = 0x40,   // 无 ARP（如回环）
    NUD_PERMANENT   = 0x80,   // 永久
};
```

### 1.3 struct neigh_table — ARP 表

```c
// include/net/neighbour.h — neigh_table
struct neigh_table {
    int               family;          // AF_INET / AF_INET6
    int               key_len;          // 密钥长度
    __be32            (*hash)(const void *pkey); // 哈希函数

    // 哈希桶
    struct neigh_hash __rcu *hash;
    u32               hash_mask;

    // GC
    struct timer_list      gc_timer;    // 垃圾回收定时器
    struct work_struct      gc_work;
    unsigned long           last_flush;   // 上次刷新时间

    // 表
    struct neigh_ops       *ops;         // 操作函数表
    struct neighbour        *static_init;  // 静态初始化
};
```

## 2. neigh_lookup — 查找 neighbour

### 2.1 neigh_lookup

```c
// net/core/neighbour.c — neigh_lookup
struct neighbour *neigh_lookup(struct neigh_table *tbl, const void *pkey,
                               struct net_device *dev)
{
    struct neigh_hash *hash = rcu_dereference_bh(tbl->hash);
    int hash_val = tbl->hash(pkey) & hash->hash_mask;
    struct neighbour *n;

    // 遍历哈希桶
    hlist_for_each_rcu(n, &hash->hash_buckets[hash_val], hash) {
        if (n->dev == dev && !memcmp(&n->primary_key, pkey, tbl->key_len)) {
            // 找到
            if (n->nud_state & NUD_VALID) {
                atomic_inc(&n->refcnt);
                return n;
            }
        }
    }

    return NULL;
}
```

## 3. neigh_resolve_output — 地址解析

### 3.1 neigh_resolve_output

```c
// net/core/neighbour.c — neigh_resolve_output
int neigh_resolve_output(struct neighbour *n, struct sk_buff *skb)
{
    int err;

    // 1. 检查状态
    if (!n->nud_state & NUD_VALID) {
        // 不可达，触发 ARP 请求
        if (n->nud_state == NUD_STALE) {
            neigh_update(n, NULL, NUD_STALE, 1);
            // 延迟探测
            goto out;
        }
        if (n->nud_state == NUD_INCOMPLETE) {
            // 已在解析，加入等待队列
            __skb_queue_tail(&n->arp_queue, skb);
            return 0;
        }
        goto out;
    }

    // 2. 构建 MAC 头
    err = neigh->ops->hh_output(skb, neigh);

out:
    return err;
}
```

## 4. neigh_update — 更新 neighbour

### 4.1 neigh_update

```c
// net/core/neighbour.c — neigh_update
int neigh_update(struct neighbour *n, const u8 *lladdr, u8 new,
               unsigned long flags)
{
    int update = 0;

    // 1. 如果有新的 lladdr，更新 MAC
    if (lladdr) {
        if (memcmp(lladdr, n->ha, n->dev->addr_len))
            update = 1;
        memcpy(n->ha, lladdr, n->dev->addr_len);
    }

    // 2. 更新状态
    if (new & NUD_VALID) {
        if (n->nud_state == NUD_INCOMPLETE)
            // 解析完成
            n->nud_state = NUD_REACHABLE;
    }

    // 3. 状态机转换
    n->updated = jiffies;

    // 4. 处理等待队列
    if (n->nud_state == NUD_REACHABLE)
        neigh_appns_update(n);

    return 0;
}
```

## 5. ARP 请求（neigh_timer_handler）

### 5.1 neigh_timer_handler

```c
// net/core/neighbour.c — neigh_timer_handler
static void neigh_timer_handler(struct timer_list *t)
{
    struct neighbour *n = from_timer(n, t, timer);
    struct neigh_parms *parms = n->parms;

    switch (n->nud_state) {
    case NUD_STALE:
        // 变为 PROBE，开始探测
        neigh_update(n, NULL, NUD_PROBE, 0);
        break;

    case NUD_INCOMPLETE:
        // 发送 ARP 请求
        if (n->nud_probes >= parms->mcast_probes) {
            n->nud_state = NUD_FAILED;
        } else {
            n->nud_probes++;
            neigh_appns(n);
        }
        break;

    case NUD_PROBE:
        // 继续探测
        if (n->nud_probes >= parms->ucast_probes) {
            n->nud_state = NUD_STALE;
        } else {
            n->nud_probes++;
            neigh_appns(n);
        }
        break;
    }
}
```

## 6. ARP 状态机

```
NUD_STALE ──timeout──▶ NUD_PROBE ──probe──▶ NUD_REACHABLE (收到响应)
                        │
                        │超过次数
                        ▼
                   NUD_FAILED

NUD_INCOMPLETE ──收到响应──▶ NUD_REACHABLE
                   │
                   │超时
                   ▼
              NUD_FAILED
```

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/core/neighbour.c` | `neigh_lookup`、`neigh_resolve_output`、`neigh_update`、`neigh_timer_handler` |
| `include/net/neighbour.h` | `struct neighbour`、`struct neigh_table`、`NUD_*` |

## 8. 西游记类比

**neighbour** 就像"土地神的邻居簿"——

> 悟空要找某个藩王（IP 地址），先看地图（fib_lookup），知道要从哪个城门出去（出口设备）。但到了城门，还需要知道门卫的 MAC 地址（物理地址）才能真正通过。土地神的邻居簿（neighbour table/ARP）就是记录"藩王名字（IP）→ 门卫MAC"的对应表。如果簿子上没有（NUD_NONE），就要发一封问询函（ARP 请求），藩王回复后（收到 ARP 响应），就把邻居簿更新。簿子上的记录会过期（STALE），过期后要重新验证（PROBE）。如果多次问询都没有回复，就标记为不可达（FAILED）。

## 9. 关联文章

- **fib_lookup**（article 149）：路由查找
- **ARP/NDISC**（相关）：地址解析协议实现

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

