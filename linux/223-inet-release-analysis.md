# inet_release — socket 关闭流程分析

## 1. inet_release 入口（sock_release → inet_release）

用户程序调用 `close(fd)` 关闭一个 socket 时，VFS 层最终调用到 `sock_close()`（`net/socket.c:1512`）：

```c
static int sock_close(struct inode *inode, struct file *filp)
{
    __sock_release(SOCKET_I(inode), inode);
    return 0;
}
```

`__sock_release()`（`net/socket.c:713`）取出 socket 的 `proto_ops`，调用其 `release` 回调：

```c
static void __sock_release(struct socket *sock, struct inode *inode)
{
    const struct proto_ops *ops = READ_ONCE(sock->ops);

    if (ops) {
        struct module *owner = ops->owner;

        if (inode)
            inode_lock(inode);
        ops->release(sock);        // ← 关键：调用 inet_release
        sock->sk = NULL;
        if (inode)
            inode_unlock(inode);
        sock->ops = NULL;
        module_put(owner);
    }
    // ...
    if (!sock->file) {
        iput(SOCK_INODE(sock));    // 无文件则释放 inode
        return;
    }
    WRITE_ONCE(sock->file, NULL);
}
```

对于 IPv4 stream socket（`SOCK_STREAM`），`ops` 为 `inet_stream_ops`（`net/ipv4/af_inet.c:1065`），其 `release` 字段指向 `inet_release`：

```c
const struct proto_ops inet_stream_ops = {
    .family         = PF_INET,
    .owner          = THIS_MODULE,
    .release        = inet_release,     // ← 回调入口
    // ...
};
```

`inet_release` 本身定义在 `net/ipv4/af_inet.c:418`：

```c
int inet_release(struct socket *sock)
{
    struct sock *sk = sock->sk;

    if (sk) {
        long timeout;

        if (!sk->sk_kern_sock)
            BPF_CGROUP_RUN_PROG_INET_SOCK_RELEASE(sk);

        /* Applications forget to leave groups before exiting */
        ip_mc_drop_socket(sk);

        timeout = 0;
        if (sock_flag(sk, SOCK_LINGER) &&
            !(current->flags & PF_EXITING))
            timeout = sk->sk_lingertime;
        sk->sk_prot->close(sk, timeout);   // ← 调用具体协议的 close
        sock->sk = NULL;
    }
    return 0;
}
EXPORT_SYMBOL(inet_release);
```

**核心路径**：用户 `close(fd)` → `sock_close()` → `__sock_release()` → `inet_release()` → `sk->sk_prot->close()`。

## 2. inet_release → tcp_close / udp_release / raw_release

`inet_release` 中调用 `sk->sk_prot->close()`，即具体协议的 close 函数。

| 协议 | `.close` 实现 | 文件位置 |
|------|--------------|---------|
| TCP | `tcp_close` | `net/ipv4/tcp.c:3313` |
| UDP | `udp_lib_close` | `net/ipv4/udp.c:3105` |
| RAW | `raw_close` | `net/ipv4/raw.c:684` |

### TCP — `tcp_close`

```c
void tcp_close(struct sock *sk, long timeout)
{
    lock_sock(sk);
    __tcp_close(sk, timeout);
    release_sock(sk);
    if (!sk->sk_net_refcnt)
        inet_csk_clear_xmit_timers_sync(sk);
    sock_put(sk);          // ← 引用计数减一，sk 可能被释放
}
EXPORT_SYMBOL(tcp_close);
```

### UDP — `udp_lib_close`

UDP 使用 `udp_lib_close`（通过 `inet_dgram_ops` 注册）。UDP 是无连接协议，`close` 不经历 TCP 那样的 FIN 挥手流程，直接调用 `sk_common_release()`（`net/core/sock.c:3993`）：

```c
void sk_common_release(struct sock *sk)
{
    if (sk->sk_prot->destroy)
        sk->sk_prot->destroy(sk);

    sk->sk_prot->unhash(sk);      // 从 hash 表解绑
    sock_orphan(sk);              // 标记 SOCK_DEAD，断开与进程的关联
    xfrm_sk_free_policy(sk);
    sock_put(sk);                 // 引用计数减一
}
```

### RAW — `raw_close`

```c
static void raw_close(struct sock *sk, long timeout)
{
    ip_ra_control(sk, 0, NULL);   // 撤销 IP_RECVERR 等 raw socket 选项
    sk_common_release(sk);
}
```

## 3. tcp_close 流程（tcp_disconnect, tp->dead = 1）

`tcp_close()` 调用 `__tcp_close()`（`net/ipv4/tcp.c:3141`），核心流程如下：

### 3.1 LISTEN 状态特殊处理

```c
void __tcp_close(struct sock *sk, long timeout)
{
    if (sk->sk_state == TCP_LISTEN) {
        tcp_set_state(sk, TCP_CLOSE);
        inet_csk_listen_stop(sk);   // 清理 listen socket 的 pending req
        goto adjudge_to_death;
    }
```

`inet_csk_listen_stop()`（`net/ipv4/inet_connection_sock.c:1453`）遍历 `icsk_accept_queue`，对每个未 accept 的 `request_sock` 调用 `inet_child_forget()` 并 `sock_put(child)`。

### 3.2 读取并丢弃 receive queue

```c
while ((skb = skb_peek(&sk->sk_receive_queue)) != NULL) {
    u32 end_seq = TCP_SKB_CB(skb)->end_seq;
    if (TCP_SKB_CB(skb)->tcp_flags & TCPHDR_FIN)
        end_seq--;
    if (after(end_seq, tcp_sk(sk)->copied_seq))
        data_was_unread = true;
    tcp_eat_recv_skb(sk, skb);
}
```

如果接收缓冲区有未读数据（含本端发出的 FIN），`data_was_unread = true`。

### 3.3 状态机转换与 RST 发送

```c
if (data_was_unread) {
    // 有未读数据 → 发 RST 终止连接
    NET_INC_STATS(sock_net(sk), LINUX_MIB_TCPABORTONCLOSE);
    tcp_set_state(sk, TCP_CLOSE);
    tcp_send_active_reset(sk, ...);
} else if (tcp_close_state(sk)) {
    // 正常流程 → 发送 FIN
    tcp_send_fin(sk);
}
```

`tcp_close_state()`（`net/ipv4/tcp.c:3059`）根据当前状态查表得到下一状态，并判断是否需要发 FIN：

```c
static const unsigned char new_state[16] = {
    [TCP_ESTABLISHED]    = TCP_FIN_WAIT1,
    [TCP_SYN_RECV]       = TCP_FIN_WAIT1,
    [TCP_CLOSE_WAIT]     = TCP_LAST_ACK,
    // ...
    [TCP_CLOSE]          = TCP_CLOSE,
};

static int tcp_close_state(struct sock *sk)
{
    int next = (int)new_state[sk->sk_state];
    int ns = next & TCP_STATE_MASK;
    tcp_set_state(sk, ns);
    return next & TCP_ACTION_FIN;
}
```

### 3.4 adjudge_to_death — 死亡判定

```c
adjudge_to_death:
    state = sk->sk_state;
    sock_hold(sk);            // 增加一次引用，防止 sk 在本函数内被释放
    sock_orphan(sk);          // 设置 SOCK_DEAD，清空 sk->sk_wq

    local_bh_disable();
    bh_lock_sock(sk);
    __release_sock(sk);       // 清空 backlog

    tcp_orphan_count_inc();

    if (state != TCP_CLOSE && sk->sk_state == TCP_CLOSE)
        goto out;

    if (sk->sk_state == TCP_FIN_WAIT2) {
        // linger2 处理 ...
        if (tmo > TCP_TIMEWAIT_LEN)
            tcp_reset_keepalive_timer(...);
        else
            tcp_time_wait(sk, TCP_FIN_WAIT2, tmo); // 进入 TIME_WAIT
        goto out;
    }

    if (sk->sk_state != TCP_CLOSE) {
        if (tcp_check_oom(sk, 0)) {
            tcp_send_active_reset(sk, ...); // 内存不足，强制 RST
        }
    }

    if (sk->sk_state == TCP_CLOSE) {
        // 清理 fastopen req
        inet_csk_destroy_sock(sk);   // 直接销毁
    }

out:
    bh_unlock_sock(sk);
    local_bh_enable();
    // 注意：这里没有 sock_put！引用计数由调用者 tcp_close() 的 sock_put 释放
}
```

## 4. close 状态机的 TIME_WAIT 处理

TIME_WAIT 是 TCP 关闭流程中最特殊的环节。当 `tcp_time_wait()` 被调用时，Linux 不会直接创建 `timewait_sock`，而是可能创建一个 "short-lived" 的 `inet_timewait_sock`：

```c
void tcp_time_wait(struct sock *sk, const int state, const int tmo)
{
    struct inet_timewait_sock *tw;

    tw = inet_twsk_alloc(sk, state);    // 分配 timewait sock
    if (tw) {
        // 设置定时器，tmo 超时后被回收
        inet_twsk_schedule(tw, tmo);
        inet_twsk_put(tw);
        return;
    }
    // 分配失败则走快速回收路径...
}
```

`TCP_TIMEWAIT_LEN` 定义在 `include/net/tcp.h:142`：

```c
#define TCP_TIMEWAIT_LEN (60*HZ)  /* 60 秒 */
```

`tcp_fin_time()`（`include/net/tcp.h:1877`）计算 FIN_WAIT2 进入 TIME_WAIT 前的超时：

```c
static inline int tcp_fin_time(const struct sock *sk)
{
    int fin_timeout = tcp_sk(sk)->linger2 ? :
        READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_fin_timeout);
    const int rto = inet_csk(sk)->icsk_rto;

    if (fin_timeout < (rto << 2) - (rto >> 1))
        fin_timeout = (rto << 2) - (rto >> 1);
    return fin_timeout;
}
```

如果 `linger2 < 0`，Linux 直接发 RST 终止连接（`tcp.c:3262`）：

```c
if (READ_ONCE(tp->linger2) < 0) {
    tcp_set_state(sk, TCP_CLOSE);
    tcp_send_active_reset(sk, GFP_ATOMIC, SK_RST_REASON_TCP_ABORT_ON_LINGER);
}
```

## 5. sock_put → sk_free 释放路径

`sock_put()`（`include/net/sock.h:2007`）是 socket 引用计数的最后一步：

```c
static inline void sock_put(struct sock *sk)
{
    if (refcount_dec_and_test(&sk->sk_refcnt))
        sk_free(sk);
}
```

`sk_free()`（`net/core/sock.c:2428`）：

```c
void sk_free(struct sock *sk)
{
    if (refcount_dec_and_test(&sk->sk_wmem_alloc))
        __sk_free(sk);
}
```

注意 `sk_free()` 有两道关卡：
1. **引用计数** `sk_refcnt` → `sock_put()` → `sk_free()` → `__sk_free()`
2. **发送缓冲** `sk_wmem_alloc` → 如果有 skb 还在传输途中，延迟释放

`__sk_free()`（`net/core/sock.c:2417`）释放核心内存：

```c
static void __sk_free(struct sock *sk)
{
    if (likely(sk->sk_net_refcnt))
        sock_inuse_add(sock_net(sk), -1);

    if (unlikely(sk->sk_net_refcnt && sock_diag_has_destroy_listeners(sk)))
        sock_diag_broadcast_destroy(sk);
    else
        sk_destruct(sk);         // 调用注册的 destructor
}
```

`sock_orphan()`（`include/net/sock.h:2126`）在释放前被调用，将 socket 标记为 dead，断开与 `struct socket` 的双向关联：

```c
static inline void sock_orphan(struct sock *sk)
{
    write_lock_bh(&sk->sk_callback_lock);
    sock_set_flag(sk, SOCK_DEAD);
    sk_set_socket(sk, NULL);    // sk → socket 置空
    sk->sk_wq  = NULL;
    write_unlock_bh(&sk->sk_callback_lock);
}
```

## 6. 文件描述符 vs socket 生命周期

**socket 是独立于文件描述符存在的内核对象。** 这一设计导致很多常见误解。

### 6.1 创建流程

```
socket() → sock_create() → pf->create()
                         → sock->ops = inet_stream_ops
                         → sock_alloc() 分配 struct socket + struct inode
                         → sock_map_fd() 分配 fd，fd 与 socket 关联
```

`sock_map_fd()` 将 `struct socket*` 绑定到 `struct file*`，通过 `fd_install()` 将 fd 暴露给用户进程。

### 6.2 close 后的 socket 存活

```
用户 close(fd)
  → sock_close(inode)
    → __sock_release()
      → inet_release()
        → tcp_close()
          → __tcp_close()
            → sock_orphan(sk)      // socket 脱离进程
            → inet_csk_destroy_sock(sk) 或
            → tcp_time_wait(sk)    // socket 继续以 TIME_WAIT 存在
          → sock_put(sk)          // 引用计数 -1
```

如果 `tcp_time_wait()` 被调用，`struct sock` 转化为 `struct inet_timewait_sock`，socket 以另一种形态继续存活最多 60 秒（`TCP_TIMEWAIT_LEN`）。此时 **fd 已被关闭，但 socket 还未完全释放**。

### 6.3 dup / fork 的影响

- `fork()`：子进程继承 fd，继承 `struct file*` 引用，但 socket 的 `struct sock` 引用计数已由父进程持有。**子进程 close 不会导致 socket 被释放**，因为父进程仍持有引用。
- `dup()`：两个 fd 指向同一个 `struct file*`，同样共享 socket 引用计数。

### 6.4 SO_LINGER 的影响

`inet_release()` 中（`af_inet.c:430`）：

```c
timeout = 0;
if (sock_flag(sk, SOCK_LINGER) &&
    !(current->flags & PF_EXITING))
    timeout = sk->sk_lingertime;
sk->sk_prot->close(sk, timeout);
```

- **默认**（无 linger）：`timeout = 0`，close 立即返回，关闭行为异步完成。
- **linger 开启**：阻塞直到数据发送完毕或超时。这正是 FTP 在大数据传输后 `close` 可能 hang 的原因。

## 7. shutdown vs close 区别

这是两个经常被混淆的系统调用。

### 7.1 close — 销毁文件描述符

```c
SYSCALL_DEFINE1(close, int, fd)
```

- **关闭 fd**，释放 `struct file*` 引用
- 若 fd 是最后一个引用，触发 `sock_close()` → `__sock_release()` → `inet_release()`
- socket 随后进入上文描述的关闭流程
- **调用一次 `sock_put()`**，最终可能释放 `struct sock`

### 7.2 shutdown — 切断连接方向

```c
SYSCALL_DEFINE2(shutdown, int, fd, int, how)
// how: SHUT_RD(0), SHUT_WR(1), SHUT_RDWR(2)
```

`shutdown()` **不关闭 fd，不释放 socket**，只修改连接的某个方向：

```c
int __sys_shutdown_sock(struct socket *sock, int how)
{
    int err;
    err = security_socket_shutdown(sock, how);
    if (!err)
        err = READ_ONCE(sock->ops)->shutdown(sock, how);
    return err;
}
```

`inet_shutdown()`（`net/ipv4/af_inet.c:901`）：

```c
int inet_shutdown(struct socket *sock, int how)
{
    struct sock *sk = sock->sk;
    // ...
    lock_sock(sk);
    // ...
    switch (sk->sk_state) {
    case TCP_CLOSE:
        err = -ENOTCONN;
        fallthrough;
    default:
        WRITE_ONCE(sk->sk_shutdown, sk->sk_shutdown | how);
        if (sk->sk_prot->shutdown)
            sk->sk_prot->shutdown(sk, how);  // 调用 tcp_shutdown()
        break;
    case TCP_LISTEN:
        if (!(how & RCV_SHUTDOWN))
            break;
        // ...
    case TCP_SYN_SENT:
        err = sk->sk_prot->disconnect(sk, O_NONBLOCK);
        // ...
    }
    release_sock(sk);
    return err;
}
```

`tcp_shutdown()`（`net/ipv4/tcp.c`）只发 FIN，不释放 socket：

```c
void tcp_shutdown(struct sock *sk, int how)
{
    if (!(how & SEND_SHUTDOWN))
        return;
    if ((1 << sk->sk_state) &
        (TCPF_ESTABLISHED | TCPF_SYN_SENT | TCPF_CLOSE_WAIT)) {
        if (tcp_close_state(sk))
            tcp_send_fin(sk);
    }
}
```

### 7.3 关键区别总结

| | `close()` | `shutdown()` |
|---|---|---|
| **操作对象** | fd + socket（引用） | socket 连接方向 |
| **释放 socket** | ✅ 是（最终） | ❌ 否 |
| **发 FIN** | ✅ 是（TCP） | ✅ 是（若 SHUT_WR） |
| **阻塞 linger** | ✅ 可能 | ❌ 否 |
| **多次调用** | 首次后 socket 已释放，后续调用无意义 | 可以多次调用（SHUT_RD/WR/RDWR 组合） |
| **对端影响** | 走完整个关闭流程 | 只切断本端发送/接收 |

### 7.4 典型使用场景

- **shutdown(SHUT_WR)**：半关闭写端，常用于告诉对端"我不再发送数据但仍想接收响应"（如 HTTP response 后的场景）。
- **close()**：完全关闭连接，所有引用计数归零后 socket 被释放。

## 总结流程图

```
用户 close(fd)
  └→ sock_close()                          [socket.c:1512]
       └→ __sock_release()                 [socket.c:713]
            └→ inet_release()               [af_inet.c:418]
                 └→ sk->sk_prot->close()   [tcp/udp/raw]
                      └→ tcp_close()        [tcp.c:3313]
                           ├→ lock_sock()
                           ├→ __tcp_close() [tcp.c:3141]
                           │    ├→ 读取/丢弃 receive queue
                           │    ├→ tcp_close_state()  状态机
                           │    ├→ tcp_send_fin() / tcp_send_active_reset()
                           │    └→ adjudge_to_death:
                           │         ├→ sock_hold()
                           │         ├→ sock_orphan()     设置 SOCK_DEAD
                           │         ├→ tcp_time_wait()  → TIME_WAIT sock
                           │         └→ inet_csk_destroy_sock()
                           │              └→ sock_put()
                           │                   └→ sk_free()
                           │                        └→ __sk_free() → sk_destruct()
                           └→ sock_put()         [tcp.c:3319]
                                └→ sk_free()
```


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

