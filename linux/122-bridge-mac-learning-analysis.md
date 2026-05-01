# Linux Kernel Bridge / MAC Learning 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/bridge/br_forward.c` + `net/bridge/br_fdb.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：MAC 学习、洪泛、生成树、fdb_entry、br_fdb_find

## 1. 核心数据结构

### 1.1 net_bridge_fdb_entry — MAC 表条目

```c
// net/bridge/br_fdb.c — net_bridge_fdb_entry
struct net_bridge_fdb_entry {
    // 哈希节点（接入 fdb_hash_tbl）
    struct rhash_head          rhnode;              // 行 26

    // 哈希 key（MAC 地址 + VLAN ID）
    struct {
        unsigned char         addr[ETH_ALEN];  // MAC 地址
        __u16                 vlan_id;         // VLAN ID
        unsigned char         is_local:1;     // 本地 MAC
        unsigned char         is_static:1;    // 静态 MAC
    } key;

    // 所属网桥
    struct net_bridge          *br;                  // 行 37

    // 所属端口
    struct net_bridge_port     *addr;               // 行 40

    // 引用计数
    kref_t                    kref;                // 行 43

    // 老化定时器
    struct timer_list          timer;              // 行 46

    // 哈希信息
    struct rcu_head           rcu;                // 行 49
};
```

## 2. MAC 学习流程

```c
// net/bridge/br_fdb.c — br_fdb_find
static struct net_bridge_fdb_entry *br_fdb_find(struct net_bridge *br,
                          const unsigned char *addr, __u16 vlan_id)
{
    // 1. 计算 MAC + VLAN 的哈希
    // 2. 在 fdb_hash_tbl（rhashtable）中查找
    return rhashtable_lookup_fast(&br->fdb_hash_tbl, &key, br_fdb_rht_params);
}

// 收到帧时学习：
void br_fdb_update(struct net_bridge *br, struct net_bridge_port *source,
               const unsigned char *addr, __u16 vlan_id, int added_by_user)
{
    // 1. 查找是否已存在
    fdb = br_fdb_find(br, addr, vlan_id);

    if (fdb) {
        // 2. 已存在：更新端口和老化时间
        fdb->addr = source;
        fdb->updated = jiffies;
    } else {
        // 3. 不存在：添加新条目
        br_fdb_add_entry(br, source, addr, vlan_id, is_static);
    }
}
```

## 3. 转发决策

```c
// net/bridge/br_forward.c — br_flood_deliver
static void br_flood_deliver(struct net_bridge *br, struct sk_buff *skb, bool unicast)
{
    struct net_bridge_port *p;

    // 洪泛到所有端口（除接收端口）
    list_for_each_entry_rcu(p, &br->port_list, list) {
        if (br_should_deliver(p, skb))
            __br_deliver(p, skb);
    }
}

// 转发决策：
void br_handle_frame(struct net_bridge_port *p, struct sk_buff *skb)
{
    // 1. 解析目的 MAC
    dest = eth_hdr(skb)->h_dest;

    // 2. 如果是广播/多播：洪泛
    if (is_multicast(dest)) {
        br_flood_deliver(br, skb, false);
        return;
    }

    // 3. 查找 MAC 表
    fdb = br_fdb_find(br, dest, skb->vlan_tci);

    if (fdb) {
        // 4. 已知单播：仅从对应端口发出
        __br_deliver(fdb->addr, skb);
    } else {
        // 5. 未知单播：洪泛
        br_flood_deliver(br, skb, true);
    }
}
```

## 4. 参考

| 文件 | 函数 | 行 |
|------|------|-----|
| `net/bridge/br_fdb.c` | `br_fdb_find` | 220 |
| `net/bridge/br_fdb.c` | `br_fdb_update` | 学习入口 |
| `net/bridge/br_forward.c` | `br_flood_deliver` | 洪泛 |
| `net/bridge/br_forward.c` | `br_handle_frame` | 帧处理入口 |


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

