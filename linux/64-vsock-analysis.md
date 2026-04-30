# vsock — 虚拟机套接字深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/vmw_vsock/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**vsock** 提供虚拟机与宿主机之间的高效通信，替代了 VirtIO-Serial 和 VMCI：
- **CID（Context ID）**：标识虚拟机（类似 IP 地址）
- **Port**：虚拟机内的端口（类似 TCP 端口）
- `VMADDR_CID_HOST = 2` → 宿主机

---

## 1. 核心数据结构

### 1.1 vsock_sock — vsock socket

```c
// net/vmw_vsock/vmci_transport.c — vsock_sock
struct vsock_sock {
    struct sock              sk;           // 基类（BSD socket）
    struct vsock_transport  *transport;   // 传输层
    unsigned int            cid;          // 虚拟机 CID
    unsigned int            remote_cid;   // 远程 CID
    unsigned int            remote_port;  // 远程端口
    unsigned int            local_port;    // 本地端口

    // 连接状态
    enum { CONNECTING, CONNECTED, DISCONNECTED } state;

    // 缓冲
    struct sk_buff_head     rx_queue;     // 接收队列
    struct sk_buff_head     tx_queue;     // 发送队列
};
```

### 1.2 vsock_transport — 传输层

```c
// net/vmw_vsock/af_vsock.c — vsock_transport
struct vsock_transport {
    int (*init)(struct vsock_sock *vsock, struct vsock_transport *vt);
    void (*destruct)(struct vsock_sock *vsock);

    // 连接
    int (*connect)(struct vsock_sock *vsock);
    int (*accept)(struct vsock_sock *vsock, struct vsock_sock *connected);

    // 数据传输
    ssize_t (*send_pkt)(struct vsock_sock *vsock, struct sk_buff *pkt);
    ssize_t (*recv_pkt)(struct vsock_sock *vsock, struct msghdr *msg, size_t len);

    // 绑定
    int (*bind)(struct vsock_sock *vsock, struct sockaddr_vm *addr);
    int (*listen)(struct vsock_sock *vsock, int backlog);
    int (*get_local_cid)(void);           // 获取本机 CID
};
```

---

## 2. Virtio 传输层

### 2.1 vmci_transport_send_pkt — 发送数据包

```c
// net/vmw_vsock/vmci_transport.c — vmci_transport_send_pkt
static ssize_t vmci_transport_send_pkt(struct vsock_sock *vsk, struct sk_buff *pkb)
{
    struct vmci_transport_pkt_info *pkt;

    // 1. 构建 VirtIO 头
    pkt->hdr.type = VMCI_TRANSPORT_PACKET_TYPE_REQUEST;
    pkt->hdr.src_cid = vsk->cid;
    pkt->hdr.dst_cid = vsk->remote_cid;
    pkt->hdr.src_port = vsk->local_port;
    pkt->hdr.dst_port = vsk->remote_port;

    // 2. 通过 VirtIO VirtQueue 发送
    //    virtqueue_add_buf() → virtqueue_kick()
    vmci_qp_produce_buf(qp, pkt, len);

    return len;
}
```

---

## 3. connect — 连接流程

```c
// net/vmw_vsock/af_vsock.c — vsock_connect
static int vsock_connect(struct socket *sock, struct sockaddr *addr, ...)
{
    struct vsock_sock *vsk = vsock_sk(sock->sk);
    struct sockaddr_vm *vm_addr = (struct sockaddr_vm *)addr;

    // 1. 初始化传输层
    vsk->transport->init(vsk);

    // 2. 设置远程地址
    vsk->remote_cid = vm_addr->svm_cid;
    vsk->remote_port = vm_addr->svm_port;

    // 3. 发送连接请求
    ret = vsk->transport->connect(vsk);

    // 4. 等待连接建立（WAIT状态的 sk_sleep）
    while (vsk->state == CONNECTING)
        schedule();

    return 0;
}
```

---

## 4. sysfs 接口

```
/sys/module/vmw_vsock_vmci/parameters/
├── enable_local_loopback    ← 启用本地回环
└── peer_cid                 ← 对等 CID
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/vmw_vsock/af_vsock.c` | `vsock_sock`、`vsock_transport` |
| `net/vmw_vsock/vmci_transport.c` | `vmci_transport_send_pkt` |
| `include/linux/virtio_vsock.h` | `struct virtio_vsock_pkt` |