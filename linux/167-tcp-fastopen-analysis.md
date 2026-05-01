# 167-tcp_fastopen — TCP快速打开深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/tcp_fastopen.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**TCP Fast Open（TFO）** 允许在三次握手的第一个 SYN 包中携带数据，减少连接建立的 RTT（Round-Trip Time）。适用于 HTTP 等短连接场景，首次连接需要 1 RTT，后续连接 0 RTT。

## 1. Fast Open 原理

```
传统 TCP（无 TFO）：
  Client ──── SYN (seq=x) ──────────────▶ Server
  Client ◀─── SYN+ACK (seq=y, ack=x+1) ─── Server   ← 等待 1 RTT
  Client ──── ACK (data) ────────────────▶ Server   ← 第二个 RTT

TCP Fast Open（有 TFO）：
  Client ──── SYN + DATA ───────────────▶ Server   ← 第一个 RTT 携带数据！
  Client ◀─── SYN+ACK + ACK ──────────── Server
  Client ──── ACK ───────────────────────▶ Server
  → 立即开始数据传输，节省 1 RTT
```

## 2. Fast Open Cookie

### 2.1 TFO Cookie 生成

```c
// net/ipv4/tcp_fastopen.c — fastopen_init
static void fastopen_init(void)
{
    // TFO Cookie = AES_128(secret_key, client_IP, timestamp)
    // 包含客户端 IP 和有效期

    // 服务器首次收到无 cookie 的 SYN
    // 生成 cookie 并通过 SYN+ACK 返回给客户端
}
```

### 2.2 fastopen_cookie_gen

```c
// net/ipv4/tcp_fastopen.c — fastopen_cookie_gen
static __u32 fastopen_cookie_gen(struct sock *sk,
                              struct request_sock *req)
{
    // Cookie = AES_128(key, client_ip, timestamp, server_port)
    // 只保留 4 字节，安全性靠 AES 的加密强度

    return cookie;
}
```

## 3. TFO 连接建立

### 3.1 tcp_v4_send_synack — 发送 SYN+ACK + Cookie

```c
// net/ipv4/tcp_fastopen.c — tcp_v4_send_synack
static int tcp_v4_send_synack(...)
{
    // 首次 SYN（无 cookie）：生成 cookie
    if (!req->tfo_cookie) {
        cookie = fastopen_cookie_gen(sk, req);
        // 放入 SYN+ACK 的 TFO option
    }
}
```

### 3.2 tcp_v4_syn_recv_sock — 收到 SYN+ACK 后

```c
// net/ipv4/tcp_fastopen.c — tcp_v4_syn_recv_sock
// 客户端收到 SYN+ACK 后，验证 cookie 并缓存
// 下次连接时，直接在 SYN 中携带数据和 cookie
```

## 4. TFO 数据发送

### 4.1 sendmsg + TFO

```c
// net/ipv4/tcp.c — tcp_sendmsg_fastopen
int tcp_sendmsg_fastopen(struct sock *sk, struct msghdr *msg, int *size)
{
    // 在 socket 上标记 TFO
    if (sk->sk_state == TCP_CLOSE) {
        // 使用 TFO 发送数据
        return tcp_v4_connect_fastopen(sk, msg, *size);
    }
}
```

## 5. sysctl 参数

```bash
# 启用 TFO（服务器）：
echo 1 > /proc/sys/net/ipv4/tcp_fastopen

# 位掩码：
# 0 = 关闭
# 1 = 客户端启用
# 2 = 服务器启用
# 3 = 两者启用

# TFO blacklist：
# /proc/sys/net/ipv4/tcp_fastopen_blackhole_timeout_set
# 设置为 1 可防止 TFO 黑洞攻击

# TFO 最大 cookie 有效期：
# /proc/sys/net/ipv4/tcp_fastopen_key
```

## 6. 限制与安全

```
TFO 限制：
  1. 首个 SYN 的数据大小限制（通常 < MSS）
  2. SYN 数据不能被重传
  3. cookie 有有效期（通常 14 天）

TFO 安全问题：
  1. TFO 黑洞攻击：
     防火墙丢弃带数据的 SYN
     解决方案：tcp_fastopen_blackhole_timeout_set
  2. Cookie 预测攻击：
     使用强密钥，定期轮换
```

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/tcp_fastopen.c` | `fastopen_cookie_gen`、`tcp_sendmsg_fastopen`、`tcp_v4_send_synack` |

## 8. 西游记类喻

**TCP Fast Open** 就像"取经的预授权快递"——

> 传统方式是：先派人去打招呼（1 RTT SYN），对方确认后再寄快递（第二个 RTT DATA）。TFO 像提前和对方建立信任关系，约定一个暗号（Cookie）。下次再送快递时，人和货一起出发（SYN+DATA），对方看到暗号就直接收货，不用再确认。这就是为什么 HTTP/2 和 HTTP/3 的连接时间大幅缩短——提前建立了信任，快递到了直接收。

## 9. 关联文章

- **inet_stream_connect**（article 143）：TCP 连接建立
- **tcp_syn_cookie**（article 156）：TFO 的 cookie 机制借鉴了 SYN Cookie

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

