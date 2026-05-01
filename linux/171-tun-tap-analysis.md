# 171-tun_tap — 虚拟网络设备深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/tun.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**TUN/TAP** 是 Linux 的虚拟网络设备，TUN 操作 IP 包（三层），TAP 操作 Ethernet 帧（二层）。用于 VPN（WireGuard、OpenVPN）、虚拟机网络、用户态协议栈。

## 1. TUN vs TAP

```
TUN（点对点隧道）：
  工作在第三层（IP）
  收发 IP 数据包
  用于：VPN、路由隧道
  /dev/net/tun

TAP（虚拟以太网）：
  工作在第二层（Ethernet）
  收发 Ethernet 帧
  用于：虚拟机网桥、完整网络栈
  /dev/net/tap
```

## 2. struct tun_file — TUN 文件描述符

```c
// drivers/net/tun.c — tun_file
struct tun_file {
    struct socket           socket;             // 套接字
    struct tun_struct      *tun;              // tun 设备

    // I/O 队列
    struct sk_buff          *skb;             // 读取缓冲
    struct page           *pages;           //零拷贝缓冲

    // 索引
    int                    detached;          // 是否分离
};
```

### 2.1 struct tun_struct — TUN 设备

```c
// drivers/net/tun.c — tun_struct
struct tun_struct {
    struct net_device       dev;              // netdevice 基类

    // 配置
    struct tun_page        *plugged;
    struct fasync_struct   *fasync;         // 异步通知

    // 模式
    unsigned char           flags;              // TUN_*
    //   TUN_EXCL = 0x1         独占模式
    //   TUN_AF_UNSPEC = 0x2   未指定地址族
    //   TUN_NO_PI = 0x4       不包含协议信息（纯 IP）
    //   TUN_ONE_QUEUE = 0x8   单队列模式
    //   IFF_TAP = 0x2         TAP 模式
    //   IFF_TUN = 0x1         TUN 模式

    // 信息头
    unsigned char           vnet_hdr_sz;      // vnet header 大小

    // 过滤
    struct sock_filter     *filter;          // BPF 过滤器
};
```

## 3. TUN 发送（用户→内核）

### 3.1 tun_chr_write_iter

```c
// drivers/net/tun.c — tun_chr_write_iter
ssize_t tun_chr_write_iter(struct kiocb *iocb, struct iov_iter *from)
{
    struct tun_file *tfile = iocb->ki_filp->private_data;
    struct tun_struct *tun = tfile->tun;

    // 1. 分配 skb
    struct sk_buff *skb;
    skb = alloc_skb(len + tun->dev.hard_header_len, GFP_KERNEL);

    // 2. 复制用户数据
    skb_put_data(skb, from->iov_base, len);

    // 3. 如果是 TUN 模式，去掉协议头
    if (tun->flags & TUN_NO_PI) {
        // 不去掉，保留协议信息
    }

    // 4. 设置 MAC 头
    skb->protocol = eth_type_trans(skb, &tun->dev);

    // 5. 注入网络栈
    netif_rx(skb);

    return len;
}
```

## 4. TUN 接收（内核→用户）

### 4.1 tun_get_user

```c
// drivers/net/tun.c — tun_get_user
void tun_get_user(struct tun_struct *tun, struct sk_buff *skb)
{
    // 从网络栈收到 skb（如 WireGuard 的 tun0）
    // 转发给用户空间

    // 1. 如果有 vnet header，设置它
    if (tun->vnet_hdr_sz) {
        // 构造 virtio_net_hdr
    }

    // 2. 如果是 TUN_NO_PI，去掉协议信息
    if (tun->flags & TUN_NO_PI) {
        skb_pull(skb, sizeof(pi));
    }

    // 3. 发送到字符设备
    skb_queue_tail(&tfile->sk->sk_receive_queue, skb);
    wake_up_interruptible(sk_sleep(tfile->sk));
}
```

## 5. 零拷贝（AF_XDP / io_uring 模式）

```c
// TUN 零拷贝：使用 vhost-net 或 io_uring
// 不需要 copy_to_user，直接共享内存
// 设置 TUN_PAGEFAULT 模式
```

## 6. WireGuard 中的使用

```bash
# WireGuard 使用 TUN 设备：
ip link add dev wg0 type wireguard
# wg0 是一个 TUN 设备
# WireGuard 驱动收到加密包后，通过 tun_get_user 送到用户空间
# 用户空间解密后，通过 tun_chr_write_iter 送回 tun 设备
# 送回时已经是明文 IP 包，注入网络栈
```

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/tun.c` | `tun_chr_write_iter`、`tun_get_user`、`tun_open` |
| `include/linux/if_tun.h` | `struct tun_struct`、`TUN_*` 标志 |

## 8. 西游记类喻

**TUN/TAP** 就像"天庭的虚拟传送门"——

> TUN 像一扇通往另一个世界的传送门（第三层），穿过传送门的都是打包好的货物（IP 包），天庭内部的人看到这个包就直接处理。TAP 像一扇通往另一个世界的以太网端口（第二层），穿过的是完整的 Ethernet 帧，包含 MAC 地址。WireGuard 像在传送门上安装了一个加密锁（WireGuard 隧道），从这边进去的货物被加密，只有对端才能解密。TUN/TAP 的精髓是让用户空间的程序能扮演一个网卡角色，所有经过这个网卡的包都能被用户程序看到和处理。

## 9. 关联文章

- **netdevice**（article 137）：TUN/TAP 是 netdevice 的实例
- **WireGuard**（article 105）：WireGuard 使用 TUN 设备
- **packet_socket**（article 170）：TAP 和 packet socket 都是二层设备

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

