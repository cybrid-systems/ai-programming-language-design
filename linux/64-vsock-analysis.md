# 64-vsock — Linux VM Sockets（vsock）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**VM Sockets（AF_VSOCK）** 是 Linux 为虚拟化环境设计的套接字协议族。与 TCP/IP 不同，vsock 不依赖 IP 网络层——它通过**上下文 ID（CID）** 标识宿主机（CID=2）和客户机（CID=3+），通过虚拟机管理程序提供的传输层（virtio、VMCI、Hyper-V）直接在宿主机和客户机之间通信。

**核心设计**：vsock 定义了一个传输抽象层（`struct vsock_transport`），每个虚拟化平台（VMware VMCI、KVM virtio、Hyper-V、loopback）提供自己的实现。上层的 socket API 对所有传输层一致。

```
客户机应用                          宿主机应用
socket(AF_VSOCK, SOCK_STREAM, 0)   socket(AF_VSOCK, SOCK_STREAM, 0)
    ↓                                    ↓
vsock 协议层 (af_vsock.c)
    ↓                                    ↓
传输层接口 (struct vsock_transport)
    ├─ virtio_transport (KVM)      ←→  vhost_vsock (宿主机端)
    ├─ vmci_transport  (VMware)
    ├─ hyperv_transport (Hyper-V)
    └─ vsock_loopback (本地测试)
```

**doom-lsp 确认**：核心在 `net/vmw_vsock/af_vsock.c`（**3,118 行**）。头文件 `include/net/af_vsock.h`。传输层实现包括 virtio（`net/vmw_vsock/virtio_transport.c`）、VMCI（`vmci_transport.c`）、Hyper-V（`hyperv_transport.c`）、loopback（`vsock_loopback.c`）。

---

## 1. 核心数据结构

### 1.1 struct vsock_sock — VSocket 套接字

```c
// include/net/af_vsock.h:29-81
struct vsock_sock {
    struct sock sk;                              /* 通用 socket（必须是第一个成员）*/
    const struct vsock_transport *transport;      /* 传输层 */

    struct sockaddr_vm local_addr;                /* 本地地址 (CID + 端口) */
    struct sockaddr_vm remote_addr;               /* 远程地址 */

    struct list_head bound_table;                 /* 绑定表 */
    struct list_head connected_table;             /* 连接表 */

    bool trusted;
    bool cached_peer_allow_dgram;
    u32 cached_peer;

    /* SOCK_STREAM only */
    long connect_timeout;                         /* 连接超时（默认 2s）*/
    struct sock *listener;                        /* 监听 socket */
    struct list_head pending_links;               /* 挂起列表 */
    struct list_head accept_queue;                /* accept 队列 */
    bool rejected;

    struct delayed_work connect_work;
    struct delayed_work pending_work;
    struct delayed_work close_work;

    u64 buffer_size;                              /* 缓冲区大小 */
    u64 buffer_min_size;
    u64 buffer_max_size;

    void *trans;                                   /* 传输私有数据 */
};
```

### 1.2 struct vsock_transport — 传输层接口

```c
// include/net/af_vsock.h
struct vsock_transport {
    /* ── 生命周期 ─ */
    int (*init)(struct vsock_sock *, struct vsock_sock *);
    void (*destruct)(struct vsock_sock *);
    void (*release)(struct vsock_sock *);

    /* ── 连接 ─ */
    int (*connect)(struct vsock_sock *);
    int (*dgram_bind)(struct vsock_sock *, struct sockaddr_vm *);
    int (*dgram_enqueue)(struct vsock_sock *, struct vsock_sock *,
                         struct sk_buff *);
    int (*dgram_dequeue)(struct vsock_sock *, struct sk_buff *, size_t, int);

    /* ── 流传输 ─ */
    int (*stream_enqueue)(struct vsock_sock *, struct sk_buff *);
    int (*stream_dequeue)(struct vsock_sock *, struct sk_buff *, size_t, int);
    int (*stream_has_data)(struct vsock_sock *);
    int (*stream_has_space)(struct vsock_sock *);
    s64 (*stream_rcvhiwat)(struct vsock_sock *);
    bool (*stream_is_active)(struct vsock_sock *);
    bool (*stream_allow)(u32 cid, u32 port);

    /* ── 通知 ─ */
    int (*notify_poll_in)(struct vsock_sock *, size_t, bool *);
    int (*notify_poll_out)(struct vsock_sock *, size_t, bool *);
    int (*notify_recv_init)(struct vsock_sock *, size_t, ...);
    int (*notify_recv_pre_block)(struct vsock_sock *, size_t, ...);
    int (*notify_recv_post_dequeue)(struct vsock_sock *, size_t, ...);
    int (*notify_send_init)(struct vsock_sock *, ...);
    int (*notify_send_pre_block)(struct vsock_sock *, ...);
    int (*notify_send_post_enqueue)(struct vsock_sock *, ...);

    /* ── 缓冲区管理 ─ */
    int (*set_buffer_size)(struct vsock_sock *, u64);
    int (*set_min_buffer_size)(struct vsock_sock *, u64);
    int (*set_max_buffer_size)(struct vsock_sock *, u64);
    u64 (*get_buffer_size)(struct vsock_sock *);
    u64 (*get_min_buffer_size)(struct vsock_sock *);
    u64 (*get_max_buffer_size)(struct vsock_sock *);
};
```

**doom-lsp 确认**：`struct vsock_transport` 是 vsock 的**策略模式**实现。`transport_h2g`（host→guest）、`transport_g2h`（guest→host）、`transport_dgram`、`transport_local` 四个全局指针。

---

## 2. 地址与 CID 管理

```c
// 地址结构
struct sockaddr_vm {
    sa_family_t svm_family;        /* AF_VSOCK */
    unsigned short svm_reserved1;
    unsigned int svm_port;         /* 端口号 */
    unsigned int svm_cid;          /* 上下文 ID */
};

// 预定义的 CID：
#define VMADDR_CID_ANY        0xFFFFFFFF  /* 通配 */
#define VMADDR_CID_HOST       2           /* 宿主机 */
#define VMADDR_CID_LOCAL      1           /* 本地回环 */
// 客户机 CID: 3 以上（通常由 hypervisor 分配）
```

---

## 3. API 路径

```c
// 绑定：
int vsock_bind(struct socket *sock, struct sockaddr *addr, int addr_len)
{
    /* 检查 CID：如果是 VMADDR_CID_ANY → 自动分配 */
    if (addr->svm_cid == VMADDR_CID_ANY)
        addr->svm_cid = transport->get_local_cid();

    /* 端口分配 */
    vsock_insert_bound(vsk);
}

// 连接：
int vsock_connect(struct socket *sock, struct sockaddr *addr, ...)
{
    /* 自动绑定（如果未绑定）*/
    vsock_auto_bind(vsk);

    /* 调用传输层的 connect */
    transport->connect(vsk);

    /* 等待对端确认 */
    wait_for_connection(vsk, timeout);
}

// 监听：
int vsock_listen(struct socket *sock, int backlog)
{
    vsock_update_backlog(vsk, backlog);
}

// 接受：
int vsock_accept(struct socket *sock, struct socket *newsock, ...)
{
    /* 从 listener->accept_queue 取出连接 */
    list_move(listener->accept_queue, &newsock->vsk->pending_links);
}
```

---

## 4. Virtio 传输实现

```c
// net/vmw_vsock/virtio_transport_common.c
// 客户机侧 virtio 驱动
// vhost_vsock.ko 是宿主机侧的实现

// 发送：
static int virtio_transport_send_pkt(struct virtio_vsock_pkt *pkt)
{
    /* 通过 virtqueue 将包放入共享缓冲区 */
    virtqueue_add_outbuf(vq, &sgs, 1, pkt, GFP_KERNEL);
    virtqueue_kick(vq);           /* 通知 host */
}

// 接收：
static void virtio_transport_recv_pkt(struct virtio_vsock *vsock,
                                      struct virtio_vsock_pkt *pkt)
{
    /* 根据操作类型分发 */
    switch (le16_to_cpu(pkt->hdr.op)) {
    case VIRTIO_VSOCK_OP_REQUEST:
        /* 连接请求 → 通知监听线程 */
        virtio_transport_handle_connect(vsock, pkt);
        break;
    case VIRTIO_VSOCK_OP_RW:
        /* 数据包 → 入队到 socket 接收缓冲 */
        virtio_transport_recv_enqueue(vsock, pkt);
        break;
    case VIRTIO_VSOCK_OP_CREDIT_UPDATE:
        /* 信用更新（流控）*/
        break;
    case VIRTIO_VSOCK_OP_SHUTDOWN:
        /* 关闭 */
        break;
    }
}
```

---

## 5. 流控

Virtio vsock 使用**信用（credit）流控**——发送方跟踪接收方的缓冲区空间：

```
发送方：                       接收方：
  知道接收方 buffer_size      → 更新 credit
  跟踪 peer_fwd_cnt          ← OP_CREDIT_UPDATE
  不发送超过 credit 的数据
```

---

## 6. 调试

```bash
# 查看 vsock 信息
cat /proc/net/vsock

# 测试 vsock loopback
socat VSOCK-LISTEN:1234,fork -
socat VSOCK-CONNECT:1:1234 -

# 使用 ss 查看
ss -l --vsock
```

---

## 7. 总结

VM Sockets 为虚拟化提供了一个**高效的、无 IP 网络栈的**主机-客户机通信通道。关键在于 `struct vsock_transport` 策略模式，使 virtio/VMCI/Hyper-V 等传输可以通过同一套 API 接入。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
