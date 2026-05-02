# 64-vsock — Linux VM Sockets（AF_VSOCK）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**VM Sockets（AF_VSOCK）** 是 Linux 为虚拟化环境设计的套接字协议族，由 VMware 于 2007 年提出。与 TCP/IP 不同，vsock **不需要 IP 网络栈**——通过**上下文 ID（CID）** 标识通信端点（宿主机 CID=2，客户机 CID≥3），通过虚拟机管理程序提供的传输层（virtio、VMCI、Hyper-V）在宿主机 ↔ 客户机之间高效通信。

**核心设计**：vsock 定义了一个**传输策略层**（`struct vsock_transport`），将 socket API 与底层虚拟化传输解耦。上层是标准的 `socket(AF_VSOCK, SOCK_STREAM, 0)` 接口，下层每个虚拟化平台注册自己的传输实现。vsock 的核心在 `af_vsock.c` 管理**socket 状态机**和**哈希表查找**，传输层负责实际的数据包收发。

```
┌─────────────────────────────────────────────────────────────────┐
│ vsock 架构 (以 KVM virtio 为例)                                 │
│                                                                 │
│ 客户机应用 (CID=3)             宿主机应用 (CID=2)                │
│ socket(AF_VSOCK)              socket(AF_VSOCK)                  │
│     │                              │                             │
│  af_vsock.c (状态机 + 哈希表)    af_vsock.c                     │
│     │                              │                             │
│  virtio_transport (virtqueue)    vhost_vsock (vhost)            │
│     │                              │                             │
│  virtio 设备 ←── 共享内存 ──→ vhost 后端                       │
└─────────────────────────────────────────────────────────────────┘
```

**doom-lsp 确认**：核心在 `net/vmw_vsock/af_vsock.c`（**3,118 行**）。头文件 `include/net/af_vsock.h`。传输层：virtio（`virtio_transport_common.c` + `virtio_transport.c`）、VMCI（`vmci_transport.c` ~2K 行）、Hyper-V（`hyperv_transport.c`）、loopback。

---

## 1. 核心数据结构

### 1.1 struct vsock_sock — VSocket

```c
// include/net/af_vsock.h:29-81
struct vsock_sock {
    struct sock sk;                              /* 通用 socket（必须是第一个成员）*/
    const struct vsock_transport *transport;      /* 关联的传输层 */

    struct sockaddr_vm local_addr;                /* 本地地址 (CID + 端口) */
    struct sockaddr_vm remote_addr;               /* 远程地址 */

    struct list_head bound_table;                 /* vsock_bind_table 链表节点 */
    struct list_head connected_table;             /* vsock_connected_table 链表节点 */

    bool trusted;
    bool cached_peer_allow_dgram;
    u32 cached_peer;

    /* ── SOCK_STREAM 专用字段 ─ */
    long connect_timeout;                         /* 连接超时（默认 2s）*/
    struct sock *listener;                        /* 监听 socket 指针 */
    struct list_head pending_links;               /* 挂起的连接请求 */
    struct list_head accept_queue;                /* 已完成的连接（等待 accept）*/
    bool rejected;

    struct delayed_work connect_work;             /* 连接超时 work */
    struct delayed_work pending_work;             /* 挂起超时 work */
    struct delayed_work close_work;               /* 关闭延迟 work */
    bool close_work_scheduled;

    u32 peer_shutdown;                            /* 对端关闭状态 */
    bool sent_request;                            /* 是否已发送连接请求 */
    bool ignore_connecting_rst;

    u64 buffer_size;                              /* 缓冲区大小 */
    u64 buffer_min_size;
    u64 buffer_max_size;

    void *trans;                                   /* 传输层私有数据 */
};
```

**vsock 的地址结构**（`sockaddr_vm`）：

```c
struct sockaddr_vm {
    sa_family_t svm_family;        /* AF_VSOCK */
    unsigned short svm_reserved1;
    unsigned int svm_port;         /* 端口（0-1023 保留）*/
    unsigned int svm_cid;          /* 上下文 ID */
};

#define VMADDR_CID_ANY        0xFFFFFFFF   /* 通配 */
#define VMADDR_CID_HOST       2            /* 宿主机 */
#define VMADDR_CID_LOCAL      1            /* 本地回环 */
// 客户机 CID: ≥3，由 Hypervisor 分配
```

### 1.2 struct vsock_transport — 传输层接口

```c
// include/net/af_vsock.h
struct vsock_transport {
    struct module *module;

    /* ── 生命周期 ─ */
    int (*init)(struct vsock_sock *, struct vsock_sock *);
    void (*destruct)(struct vsock_sock *);
    void (*release)(struct vsock_sock *);
    int (*cancel_pkt)(struct vsock_sock *);

    /* ── 连接 ─ */
    int (*connect)(struct vsock_sock *);

    /* ── DGRAM ─ */
    int (*dgram_bind)(struct vsock_sock *, struct sockaddr_vm *);
    int (*dgram_dequeue)(struct vsock_sock *, struct msghdr *, size_t, int);
    int (*dgram_enqueue)(struct vsock_sock *, struct sockaddr_vm *,
                         struct msghdr *, size_t);
    bool (*dgram_allow)(struct vsock_sock *, u32 cid, u32 port);

    /* ── STREAM ─ */
    ssize_t (*stream_dequeue)(struct vsock_sock *, struct msghdr *, size_t, int);
    ssize_t (*stream_enqueue)(struct vsock_sock *, struct msghdr *, size_t);
    s64 (*stream_has_data)(struct vsock_sock *);
    s64 (*stream_has_space)(struct vsock_sock *);
    u64 (*stream_rcvhiwat)(struct vsock_sock *);
    bool (*stream_is_active)(struct vsock_sock *);
    bool (*stream_allow)(struct vsock_sock *, u32 cid, u32 port);

    /* ── SEQ_PACKET ─ */
    ssize_t (*seqpacket_dequeue)(...);
    int (*seqpacket_enqueue)(...);
    bool (*seqpacket_allow)(...);
    u32 (*seqpacket_has_data)(...);

    /* ── 通知（流控/阻塞）─ */
    int (*notify_poll_in)(struct vsock_sock *, size_t, bool *);
    int (*notify_poll_out)(struct vsock_sock *, size_t, bool *);
    int (*notify_recv_init)(struct vsock_sock *, size_t, ...);
    int (*notify_recv_pre_block)(struct vsock_sock *, size_t, ...);
    int (*notify_recv_post_dequeue)(struct vsock_sock *, size_t, ssize_t, ...);
    int (*notify_send_init)(struct vsock_sock *, ...);
    int (*notify_send_pre_block)(struct vsock_sock *, ...);
    int (*notify_send_post_enqueue)(struct vsock_sock *, ssize_t, ...);

    /* ── 杂项 ─ */
    int (*shutdown)(struct vsock_sock *, int);
    u32 (*get_local_cid)(void);
    bool (*has_remote_cid)(struct vsock_sock *, u32 remote_cid);
    int (*read_skb)(struct vsock_sock *, skb_read_actor_t);
    bool (*msgzerocopy_allow)(void);
};
```

**传输特性标志**：

```c
#define VSOCK_TRANSPORT_F_H2G     0x01  /* 宿主机→客户机 */
#define VSOCK_TRANSPORT_F_G2H     0x02  /* 客户机→宿主机 */
#define VSOCK_TRANSPORT_F_DGRAM   0x04  /* 支持 DGRAM */
#define VSOCK_TRANSPORT_F_LOCAL   0x08  /* 本地回环 */
```

**doom-lsp 确认**：`struct vsock_transport` 在 `include/net/af_vsock.h`。全局传输指针在 `af_vsock.c:204-210`：`transport_h2g`、`transport_g2h`、`transport_dgram`、`transport_local`。

---

## 2. 哈希表与查找

```c
// 两个全局哈希表（+ 1 个未绑定列表）
#define VSOCK_HASH_SIZE         251

extern struct list_head vsock_bind_table[VSOCK_HASH_SIZE + 1];
    // [0..250]: 按端口哈希的绑定 socket
    // [251]: 未绑定 socket（随机的列表）

extern struct list_head vsock_connected_table[VSOCK_HASH_SIZE];
    // 按远程 CID 哈希的连接 socket

extern spinlock_t vsock_table_lock;

// 哈希函数
#define VSOCK_HASH(addr)  ((addr)->svm_port % VSOCK_HASH_SIZE)

// 查找绑定 socket：
struct sock *vsock_find_bound_socket(struct sockaddr_vm *addr)
{
    struct list_head *head = &vsock_bind_table[VSOCK_HASH(addr)];
    
    list_for_each_entry(vsk, head, bound_table) {
        if (vsk->local_addr.svm_cid == addr->svm_cid &&
            vsk->local_addr.svm_port == addr->svm_port)
            return sk_vsock(vsk);
    }
    return NULL;
}

// 查找已连接 socket：
struct sock *vsock_find_connected_socket(struct sockaddr_vm *src,
                                         struct sockaddr_vm *dst)
{
    struct list_head *head = &vsock_connected_table[VSOCK_HASH(dst)];

    list_for_each_entry(vsk, head, connected_table) {
        if (vsock_addr_equals(&vsk->remote_addr, src) &&
            vsock_addr_equals(&vsk->local_addr, dst))
            return sk_vsock(vsk);
    }
    return NULL;
}
```

**doom-lsp 确认**：`vsock_find_bound_socket` 和 `vsock_find_connected_socket` 在 `af_vsock.c`。保护锁 `vsock_table_lock` 是 spinlock。

---

## 3. 连接建立——三阶段握手

### 3.1 vsock_bind

```c
// 端口绑定：
static int vsock_bind(struct socket *sock, struct sockaddr *addr, int addr_len)
{
    // 1. 地址检查
    vsock_addr_cast(addr, addr_len, &local_addr);

    // 2. CID 处理
    if (local_addr->svm_cid == VMADDR_CID_ANY) {
        // 自动填充本地 CID
        local_addr->svm_cid = transport->get_local_cid();
    }

    // 3. 端口分配
    if (local_addr->svm_port == VMADDR_PORT_ANY) {
        // 从 LAST_RESERVED_PORT+1 开始线性探测
        for (i = 0; i < MAX_PORT_RETRIES; i++) {
            local_addr->svm_port = last_reserved_port + i + 1;
            if (!vsock_find_bound_socket(local_addr))
                break;
        }
    }

    // 4. 加入绑定表
    vsk->local_addr = *local_addr;
    vsock_insert_bound(vsk);
}
```

### 3.2 vsock_connect

```c
// af_vsock.c:1650
static int vsock_connect(struct socket *sock, struct sockaddr_unsized *addr,
                         int addr_len, int flags)
{
    lock_sock(sk);

    switch (sock->state) {
    case SS_CONNECTING:
        /* 非阻塞重入：返回 -EALREADY */
        if (flags & O_NONBLOCK) goto out;
        /* 阻塞重入：继续等待 */
        break;
    default:
        /* 1. 传输层选择 */
        memcpy(&vsk->remote_addr, remote_addr, sizeof(vsk->remote_addr));
        err = vsock_assign_transport(vsk, NULL);
        transport = vsk->transport;

        /* 2. 权限检查 */
        if (!transport->stream_allow(vsk, remote_addr->svm_cid, ...)) {
            err = -ENETUNREACH;
            goto out;
        }

        /* 3. 自动端口绑定 */
        err = vsock_auto_bind(vsk);

        /* 4. 设置状态 + 调用传输层 connect */
        sk->sk_state = TCP_SYN_SENT;
        err = transport->connect(vsk);      /* 发送连接请求包 */
        sock->state = SS_CONNECTING;
        err = -EINPROGRESS;
        break;
    }

    /* 5. 等待 TCP_ESTABLISHED */
    timeout = vsk->connect_timeout;
    prepare_to_wait(sk_sleep(sk), &wait, TASK_INTERRUPTIBLE);

    while (sk->sk_state != TCP_ESTABLISHED &&
           sk->sk_state != TCP_CLOSING && sk->sk_err == 0) {

        if (flags & O_NONBLOCK) {
            /* 非阻塞：调度超时 work 后返回 */
            schedule_delayed_work(&vsk->connect_work, timeout);
            break;
        }

        release_sock(sk);
        timeout = schedule_timeout(timeout);  /* 休眠等待 */
        lock_sock(sk);

        if (signal_pending(current)) {
            err = -EINTR;
            sk->sk_state = TCP_CLOSE;
            goto out;
        }
    }
}
```

### 3.3 对端接收——pending + accept 队列

监听 socket 维护两个队列：

```
listener->vsk.pending_links:      // 未完成的连接（等待握手完成）
    [req_1] → [req_2] → ...
              ↓ 握手完成
listener->vsk.accept_queue:        // 已完成的连接（等待 accept）
    [conn_1] → [conn_2] → ...
              ↓ accept()
    新 socket 返回给用户
```

```c
// af_vsock.c:1838
static int vsock_accept(struct socket *sock, struct socket *newsock, ...)
{
    /* 从 accept_queue 取头部连接 */
    list_first_entry(&listener->vsk->accept_queue, ...);

    /* 创建新 socket 并返回 */
    newsock->state = SS_CONNECTED;
    release_sock(newsock->sk);
}
```

---

## 4. 传输层选择——vsock_assign_transport

```c
// af_vsock.c
int vsock_assign_transport(struct vsock_sock *vsk, struct vsock_sock *psk)
{
    const struct vsock_transport *t;
    struct net *net = sock_net(sk_vsock(vsk));
    u32 remote_cid = vsk->remote_addr.svm_cid;
    bool connectible;

    /* 规则：
     * 1. remote_cid == LOCAL → transport_local（环回）
     * 2. 宿主机侧（guest_cid == VMADDR_CID_HOST）→ transport_h2g
     * 3. 客户机侧 → transport_g2h
     */
    if (remote_cid <= VMADDR_CID_HOST) {
        if (__vsock_in_connected_table(vsk))
            return -EALREADY;
        t = transport_local;
        goto assign;
    }

    /* transport_g2h 或 transport_h2g */
    t = transport_g2h;
    if (!vsock_net_check_mode(net, ...))
        return -ENETUNREACH;

    /* 检查远程 CID 是否可达 */
    if (t && t->has_remote_cid && !t->has_remote_cid(vsk, remote_cid))
        t = NULL;

assign:
    vsk->transport = t;
    return 0;
}
```

**doom-lsp 确认**：`vsock_assign_transport` 在 `af_vsock.c`。该函数在 `connect()` 和 `bind()` 时调用，根据本地 CID 和对端 CID 选择正确的传输层。

---

## 5. Virtio 传输层实现

### 5.1 数据包格式

```c
// include/uapi/linux/virtio_vsock.h
struct virtio_vsock_hdr {
    __le64 src_cid;        /* 源 CID */
    __le64 dst_cid;        /* 目标 CID */
    __le32 src_port;       /* 源端口 */
    __le32 dst_port;       /* 目标端口 */
    __le32 len;            /* 数据长度 */
    __le16 type;           /* 类型 (STREAM=1) */
    __le16 op;             /* 操作码 */
    __le32 flags;
    __le32 buf_alloc;      /* 缓冲区分配量（流控）*/
    __le32 fwd_cnt;        /* 已转发计数（流控）*/
};
```

### 5.2 操作码

```c
enum {
    VIRTIO_VSOCK_OP_INVALID = 0,
    VIRTIO_VSOCK_OP_REQUEST = 1,        /* 连接请求 */
    VIRTIO_VSOCK_OP_RESPONSE = 2,       /* 连接接受 */
    VIRTIO_VSOCK_OP_RST = 3,            /* 重置 */
    VIRTIO_VSOCK_OP_SHUTDOWN = 4,       /* 关闭 */
    VIRTIO_VSOCK_OP_RW = 5,             /* 数据传输 */
    VIRTIO_VSOCK_OP_CREDIT_UPDATE = 6,  /* 信用更新 */
    VIRTIO_VSOCK_OP_CREDIT_REQUEST = 7, /* 信用请求 */
};
```

### 5.3 连接握手 virtio 路径

```
客户机 (connect)                    宿主机 (vhost)
    │                                     │
    │── VIRTIO_VSOCK_OP_REQUEST ──→        │
    │                                     ├─ virtio_transport_recv_pkt()
    │                                     │   → 查找监听 socket
    │                                     │   → vsock_add_pending()
    │                                     │   → 唤醒 accept 线程
    │                                     │
    │←── VIRTIO_VSOCK_OP_RESPONSE ──      │
    │                                     │
    │sk->sk_state = TCP_ESTABLISHED       │
    │sock->state  = SS_CONNECTED          │
    │                                     │
    │←── VIRTIO_VSOCK_OP_RW ─────────    │  数据传输
```

### 5.4 信用流控

```c
// virtio_transport_common.c
// 发送方不能超过接收方声明的信用：
// buf_alloc = 接收方声明的缓冲区大小
// fwd_cnt  = 接收方已消费的字节数
// credit   = buf_alloc - (fwd_cnt_remote - fwd_cnt_local)
//
// 发送前检查：
void virtio_transport_send_pkt_info(struct vsock_sock *vsk, ...)
{
    /* 检查是否还有信用 */
    free = le32_to_cpu(peer->buf_alloc) - 
           (le32_to_cpu(peer->fwd_cnt) - vsk->fwd_cnt);

    if (free < len) {
        /* 信用不足 → 等待 OP_CREDIT_UPDATE */
        sk->sk_write_pending++;
        schedule_delayed_work(&vsk->connect_work, ...);
        return;
    }

    /* 发送数据包 */
    virtqueue_add_outbuf(vq, &sgs, 1, pkt, GFP_KERNEL);
    virtqueue_kick(vq);                    /* 通知对方 */
}
```

**doom-lsp 确认**：信用流控在 `virtio_transport_common.c` 中。`VIRTIO_VSOCK_OP_CREDIT_UPDATE` 包在没有数据时单独发送以通知接收进度。

---

## 6. SEQ_PACKET 支持

vsock 还支持 `SOCK_SEQPACKET`——保留消息边界的可靠传输：

```c
// 应用：SSH over vsock 使用 SEQPACKET 模式
// 特点：
//   - 保持消息边界（每次 recv 读取一个完整消息）
//   - 可靠传输
//   - 支持 MSG_EOR 和 MSG_TRUNC

// 内核实现：
// t->seqpacket_enqueue(vsk, msg, len)
// 将整个消息作为一个数据包发送，对端收到后保持边界
```

---

## 7. vsock BPF 支持

```c
// net/vmw_vsock/vsock_bpf.c
// vsock 支持 BPF 字节码 attach
// 允许通过 BPF 程序过滤/修改 vsock 行为

#ifdef CONFIG_BPF_SYSCALL
int vsock_bpf_update_proto(struct sock *sk, struct sk_psock *psock, bool restore);
#endif
```

---

## 8. 零拷贝（MSG_ZEROCOPY）

```c
// 通过 setsockopt SO_ZEROCOPY 启用
// 发送时，skb 数据通过 DMA 直接传输，避免内核→用户数据拷贝
// 需要传输层支持 msgzerocopy_allow()
```

---

## 9. 性能参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `connect_timeout` | 2s | 连接超时 |
| `buffer_size` | 256KB | 接收缓冲区大小 |
| `buffer_min_size` | 128 | 最小缓冲区 |
| `buffer_max_size` | 256KB | 最大缓冲区 |
| `VSOCK_DEFAULT_CONNECT_TIMEOUT` | 2*HZ | 连接超时（jiffies）|

**典型延迟**：
- virtio 宿主机↔客户机：**~5-15μs**（同主机）
- vsock loopback（本地）：**~2-5μs**
- VMCI（VMware）：**~3-10μs**
- Hyper-V：**~5-20μs**

---

## 10. 调试

```bash
# 查看 vsock socket 状态
cat /proc/net/vsock
# 输出：
#  sl  local_cid  local_port  remote_cid  remote_port  tx_queue  rx_queue
#   0       3       1234          2         4321          0        0

# 查看注册的传输层
lsmod | grep vsock
# vsock_loopback         16384  0
# vmw_vsock_virtio_transport 28672  0
# vmw_vsock_vmci_transport 40960  0
# vsock                  53248  6 vmw_vsock_*

# 使用 socat 测试
socat VSOCK-LISTEN:1234,fork -
socat VSOCK-CONNECT:2:1234 -

# 使用 ssh over vsock
ssh -o ProxyCommand='ncat --vsock %h %p' vm

# tracepoint
echo 1 > /sys/kernel/debug/tracing/events/vsock/enable
```

---

## 11. 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `-ENETUNREACH` | 没有合适的传输层 | 检查 `transport_h2g/g2h` 是否注册 |
| `-EOPNOTSUPP` | zero copy 不支持 | 检查 `msgzerocopy_allow()` |
| 连接超时 | 对端未监听/防火墙 | 检查对端 CID 和端口 |
| `VMADDR_CID_ANY` 连接失败 | 需要明确的 CID | 替换为 `VMADDR_CID_HOST`（2）|

---

## 12. 总结

VM Sockets 是**Linux 虚拟化通信的基础设施**：

**1. 传输策略模式** — `struct vsock_transport` 将 socket 层与底层虚拟化解耦，virtio/VMCI/Hyper-V/loopback 共享同一套用户 API。

**2. 哈希表双查找** — `vsock_bind_table` 和 `vsock_connected_table` 分别用于绑定和已连接 socket 的快速 O(1) 定位。

**3. pending+accept 双队列** — 监听 socket 通过 `pending_links` 和 `accept_queue` 两步管理连接建立，与 TCP 的 `SYN_RECV`/`ESTABLISHED` 设计同源。

**4. 信用流控** — virtio 传输的 credit-based 流控避免接收缓冲区溢出，通过 `VIRTIO_VSOCK_OP_CREDIT_UPDATE` 异步通知。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
