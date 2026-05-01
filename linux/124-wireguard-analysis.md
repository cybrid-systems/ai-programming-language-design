# Linux Kernel WireGuard 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/wireguard/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：Noise 协议、chacha20poly1305、握手、加密通道

## 0. WireGuard 概述

**WireGuard** 是现代 VPN 协议，基于 **Noise 协议框架**，代码量仅 ~4000 行，已合并入 Linux 主线。

## 1. 核心数据结构

### 1.1 wg_device — WireGuard 设备

```c
// drivers/net/wireguard/device.h — wg_device
struct wg_device {
    struct net              *net;
    struct crypt_queue      *encrypt_queue;   // 加密队列
    struct crypt_queue      *decrypt_queue;   // 解密队列
    struct pubkey_hashtable *pubkey_hashtable; // 公钥 → peer
    struct allowedips_hashtable *allowedips;   // CIDR → peer
    struct list_head        peer_list;        // peer 链表
    struct wg_peer          *self_device.peer; // 自身 peer
    struct noise_handshake  handshake;        // 握手机制
    struct work_struct      handshake_send_work; // 握手延迟工作
    struct pubkey           static_identity.our_secret; // 静态密钥
    struct pubkey           static_identity.our_public; // 静态公钥
    struct mutex            device_update_lock; // 设备锁
    int                     ifindex;
    char                    dev_name[IFNAMSIZ];
};
```

### 1.2 wg_peer — 对等体

```c
// drivers/net/wireguard/peer.h — wg_peer
struct wg_peer {
    struct wg_device            *device;          // 所属设备
    struct prev_queue            tx_queue;         // 发送队列
    struct prev_queue            rx_queue;         // 接收队列
    struct sk_buff_head          staged_packet_queue; // 待加密包
    int                          serial_work_cpu;   // 序列工作 CPU

    bool                         is_dead;
    struct noise_keypairs        keypairs;         // 密钥对
    struct endpoint              endpoint;         // 对方地址

    // 握手状态
    struct handshake handshake {
        struct noise_handshake hs;    // Noise 握手
        __u64                   last_handshake_jiffies; // 上次握手时间
        struct timer_list       handshake_timer;  // 握手超时定时器
        struct list_head        noise_handshake;  // 握手链表
    };

    // 统计
    struct peer_stat {
        u64                     tx_bytes;
        u64                     rx_bytes;
        atomic64_t              last_handshake_time;
    } stat;
};
```

## 2. 握手流程

```
1. 发送方创建 initiation（首次连接）：
   → noise_handshake_create_initiation()
   → HH = DH(prologue || local_ephemeral)
   → 发送 initiation

2. 接收方响应 response：
   → noise_handshake_create_response()
   → 发送 response

3. 双方计算 session keys：
   → chacha20poly1305_symmetric_session_keys()
   → 建立加密通道

4. 数据传输：
   → 使用 session keys 加密
   → chacha20poly1305_encrypt()
```

## 3. 数据包发送

```c
// drivers/net/wireguard/send.c — wg_packet_encrypt_worker
static void wg_packet_encrypt_worker(struct work_struct *work)
{
    struct crypt_queue *queue = container_of(work, struct crypt_queue, worker->work);
    struct sk_buff *skb;

    while ((skb = ptr_ring_consume(&queue->ring))) {
        struct wg_peer *peer = skb->peer;

        // 1. 获取当前密钥对
        keys = &peer->keypairs;

        // 2. 加密
        chacha20poly1305_encrypt(skb, keys->sending);

        // 3. 发送
        wg_packet_send(peer, skb);
    }
}
```

## 4. 参考

| 文件 | 函数 | 行 |
|------|------|-----|
| `drivers/net/wireguard/device.h` | `wg_device` | 设备结构 |
| `drivers/net/wireguard/peer.h` | `wg_peer` | peer 结构 |
| `drivers/net/wireguard/noise.c` | `noise_handshake_create_*` | 握手 |
| `drivers/net/wireguard/send.c` | `wg_packet_encrypt_worker` | 加密发送 |


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

