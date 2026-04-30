# 142-sock_create — Socket创建深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/socket.c` + `net/ipv4/af_inet.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**sock_create** 是 Linux socket API 的核心入口，创建 socket 套接字，返回文件描述符给用户空间。涉及 socket 文件系统（sockfs）和具体协议族的初始化。

---

## 1. 核心数据结构

### 1.1 struct socket — 通用 socket

```c
// include/linux/net.h — socket
struct socket {
    // 状态
    socket_state          state;           // SS_* 状态
    //   SS_FREE        = 未分配
    //   SS_UNCONNECTED = 未连接
    //   SS_CONNECTING  = 连接中
    //   SS_CONNECTED   = 已连接
    //   SS_DISCONNECTING = 断开中

    // 类型
    short               type;             // SOCK_STREAM/DGRAM/RAW等
    unsigned long       flags;             // SOCK_* 标志

    // 文件和sock
    struct file         *file;            // 关联的文件
    struct sock         *sk;              // 协议sock（inet_sock等）

    // 操作
    const struct proto_ops *ops;         // 协议族操作（inet_stream_ops等）
};
```

### 1.2 struct proto_ops — 协议族操作

```c
// include/linux/net.h — proto_ops
struct proto_ops {
    int                   family;              // 协议族（PF_INET等）

    // 绑定/监听/连接
    int                   (*bind)(struct socket *sock, struct sockaddr *addr, int addrlen);
    int                   (*listen)(struct socket *sock, int backlog);
    int                   (*connect)(struct socket *sock, struct sockaddr *addr, int addrlen);

    // 发送/接收
    int                   (*sendmsg)(struct socket *sock, struct msghdr *msg, size_t size);
    int                   (*recvmsg)(struct socket *sock, struct msghdr *msg, size_t size);

    // 文件操作
    int                   (*socketpair)(struct socket *, struct socket *);
    int                   (*accept)(struct socket *sock, struct socket *newsock, int flags);
    int                   (*getname)(struct socket *sock, struct sockaddr *addr, int peer);
    int                   (*ioctl)(struct socket *sock, unsigned int cmd, unsigned long arg);
    int                   (*poll)(struct file *file, struct socket *sock, struct poll_table_struct *wait);
    int                   (*release)(struct socket *sock);
};
```

### 1.3 struct sock — 协议sock

```c
// include/net/sock.h — sock
struct sock {
    // 通用
    __u32               sk_hash;           // 哈希（用于快速查找）
    __u16               sk_type;           // SOCK_STREAM等
    __u16               sk_protocol;       // IPPROTO_*（TCP/UDP等）

    // 状态
    unsigned long       sk_flags;           // SK_* 标志
    unsigned char        sk_shutdown;        // SHUTDOWN_* 掩码
    socket_lock_t       sk_lock;            // 锁
    atomic_t             sk_drops;            // 丢弃计数

    // 缓冲区
    struct sk_buff_head sk_receive_queue;   // 接收队列
    struct sk_buff_head sk_write_queue;     // 发送队列
    struct sk_buff_head sk_async_queue;     // 异步队列

    // 内存
    int                 sk_rcvbuf;            // 接收缓冲大小
    int                 sk_sndbuf;            // 发送缓冲大小
    int                 sk_rcvlowat;          // 接收低水位
    int                 sk_rcvtimeo;          // 接收超时
    struct socket       *sk_socket;          // 反向指针

    // 协议特定（IPv4）
    struct inet_sock    {
        struct sock       sk;
        __be32           inet_saddr;         // 源 IP
        __be16           inet_sport;         // 源端口
        __be32           inet_daddr;         // 目的 IP
        __be16           inet_dport;         // 目的端口
    };
};
```

---

## 2. sys_socket — 系统调用入口

### 2.1 __sys_socket

```c
// net/socket.c — __sys_socket
int __sys_socket(int family, int type, int protocol)
{
    struct socket *sock;
    int fd, err;

    // 1. 创建 socket
    err = sock_create(family, type, protocol, &sock);
    if (err < 0)
        return err;

    // 2. 分配 fd
    fd = get_unused_fd_flags(O_RDWR);
    if (fd < 0) {
        sock_release(sock);
        return fd;
    }

    // 3. 关联 fd → socket
    fd_install(fd, sock->file);

    return fd;
}
```

---

## 3. sock_create — socket 创建

### 3.1 sock_create

```c
// net/socket.c — sock_create
int sock_create(int family, int type, int protocol, struct socket **res)
{
    return __sock_create(current->nsproxy->net_ns, family, type, protocol, res, 0);
}

int __sock_create(struct net *net, int family, int type, int protocol,
                 struct socket **res, int kern)
{
    struct socket *sock;
    const struct net_proto_family *pf;

    // 1. 分配 socket
    sock = sock_alloc();
    if (!sock)
        return -ENOMEM;

    // 2. 设置类型
    sock->type = type;

    // 3. 获取协议族（如 PF_INET）
    pf = rcu_dereference(net_families[family]);
    if (!pf) {
        err = -EAFNOSUPPORT;
        goto out;
    }

    // 4. 创建特定协议的 sock
    err = pf->create(net, sock, protocol, kern);
    if (err < 0)
        goto out;

    *res = sock;
    return 0;

out:
    sock_release(sock);
    return err;
}
```

---

## 4. sock_alloc — 分配 socket

### 4.1 sock_alloc

```c
// net/socket.c — sock_alloc
struct socket *sock_alloc(void)
{
    struct inode *inode;
    struct socket *sock;

    // 1. 创建匿名 inode（属于 sockfs）
    inode = new_inode(sock_mnt->mnt_sb);

    // 2. 获取 socket
    sock = SOCKET_I(inode);

    // 3. 初始化
    inode->i_ino = get_next_ino();
    sock->state = SS_FREE;
    sock->flags = SOCK_NOSPACE;

    // 4. 加入全局链表
    list_add(&sock->list, &net->socks);

    return sock;
}
```

---

## 5. PF_INET — IPv4 socket 创建

### 5.1 inet_create

```c
// net/ipv4/af_inet.c — inet_create
static int inet_create(struct net *net, struct socket *sock, int protocol, int kern)
{
    struct sock *sk;
    struct inet_protosw *answer;
    int try_loading_module = 2;

lookup:
    // 1. 查找匹配的 proto (TCP/UDP/RAW)
    answer =搜寻与 protocol 匹配的 inet_protosw
    for (p = inet_protosw_base; p <= inet_protosw_last; p++) {
        if ((p->protocol == protocol) &&
            (sock->type == p->type))
            break;
    }

    // 2. 创建 inet_sock
    sk = sk_alloc(net, PF_INET, GFP_KERNEL, answer->prot, kern);
    if (!sk)
        goto out;

    // 3. 初始化 inet_sock
    inet_sock_set_state(sk, TCP_CLOSE);

    // 4. 设置 proto
    sk->sk_prot = answer->prot;
    sk->sk_prot_creator = answer->prot;

    // 5. 设置 socket → sock 关联
    sock_init_data(sock, sk);

    // 6. 调用协议初始化
    if (sk->sk_prot->init)
        err = sk->sk_prot->init(sk);

    return 0;
}
```

---

## 6. Socket 类型

```c
// include/linux/net.h — socket type
#define SOCK_STREAM     1  // 面向连接（TCP）
#define SOCK_DGRAM      2  // 无连接（UDP）
#define SOCK_RAW        3  // 原始套接字
#define SOCK_RDM         4  // 可靠数据报
#define SOCK_SEQPACKET  5  // 序列包
#define SOCK_DCCP       6  // DCCP
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/socket.c` | `__sys_socket`、`sock_create`、`__sock_create`、`sock_alloc` |
| `net/ipv4/af_inet.c` | `inet_create` |
| `include/linux/net.h` | `struct socket`、`struct proto_ops` |
| `include/net/sock.h` | `struct sock`、`struct inet_sock` |

---

## 8. 西游记类比

**sock_create** 就像"建立通信驿站"——

> 在天庭（用户空间）和各藩王（网络）之间建立通信，要先创建一个通信据点（socket）。socket_create 先在据点挂上牌子（分配 inode），然后找合适的通信方式（TCP/UDP 协议），最后把据点和通信线路（sock）连接起来。不同的通信方式有不同的协议族操作（proto_ops）——TCP 要先握手（connect），UDP 直接送信（sendmsg）。socket 和 sock 的关系就像"据点"和"内部通信室"，socket 对外（文件描述符），sock 对内（协议栈）。

---

## 9. 关联文章

- **inet_stream_connect**（article 143）：TCP 连接建立
- **tcp_sendmsg**（article 144）：TCP 发送
- **udp_sendmsg**（article 145）：UDP 发送
- **inet_release**（article 146）：socket 关闭