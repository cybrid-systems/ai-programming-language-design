# 168-udp_unicast_loyal — UDP广播多播深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/udp.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**UDP 多播/广播** 允许一个 sender 同时向多个 receiver 发送数据，是 IPTV、组播路由、局域网发现等场景的核心。

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

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/udp.c` | `udp_sendmsg`（多播/广播处理）|
| `net/ipv4/igmp.c` | `igmp_rcv`、`igmp_send` |
| `net/ipv4/ipmr.c` | `ip_mroute`、`mrtsock` |

## 6. 西游记类喻

**UDP 多播/广播** 就像"天庭的通稿"——

> 多播像一个通知同时发给多个部门（224.0.0.1 = 所有主机），不用每个部门单独跑一趟。IGMP 就像每个部门收到通知后，向路由器报告"我在这里，我属于这个多播组"，让路由器知道哪些部门的房间需要转发通知。广播则是天庭贴告示（255.255.255.255），所有人都能看到，但只有同一个院子的人能收到。

## 7. 关联文章

- **udp_sendmsg**（article 145）：UDP 发送基础
- **netdevice**（article 137）：多播通过 netdevice 发送

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

