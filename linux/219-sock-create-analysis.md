# Linux Kernel sock_create 深度分析

## 1. 入口：用户态如何触发 socket 创建

用户进程调用 `socket(AF_INET, SOCK_STREAM, 0)`，最终进入系统调用入口：

```c
// net/socket.c:1818
SYSCALL_DEFINE3(socket, int, family, int, type, int, protocol)
{
    return __sys_socket(family, type, protocol);
}
```

`__sys_socket()` → `__sys_socket_create()` → `sock_create()` → `__sock_create()`，完整调用链如下：

```
SYSCALL_DEFINE3(socket)
  └─> __sys_socket()                        // socket.c:1801
        ├─> __sys_socket_create()            // socket.c:1744
        │     └─> sock_create()             // socket.c:1720
        │           └─> __sock_create()      // socket.c:1593
        │
        └─> sock_map_fd()                   // socket.c:564
              └─> sock_alloc_file()         // socket.c:536
                    └─> alloc_file_pseudo()  // fs/file_table.c
```

### public API：`sock_create`

```c
// net/socket.c:1720
int sock_create(int family, int type, int protocol, struct socket **res)
{
    return __sock_create(current->nsproxy->net_ns, family, type, protocol, res, 0);
}
```

`kern=0` 表示这是一个用户态请求。内核空间版本 `sock_create_kern()` 传入 `kern=1`，两者都最终调用 `__sock_create()`。

---

## 2. `__sock_create`：核心创建逻辑

```c
// net/socket.c:1593
int __sock_create(struct net *net, int family, int type, int protocol,
                  struct socket **res, int kern)
{
    int err;
    struct socket *sock;
    const struct net_proto_family *pf;
```

### 2.1 参数校验

```c
    if (family < 0 || family >= NPROTO)
        return -EAFNOSUPPORT;
    if (type < 0 || type >= SOCK_MAX)
        return -EINVAL;

    // 兼容性处理：SOCK_PACKET 已废弃
    if (family == PF_INET && type == SOCK_PACKET) {
        pr_info_once("%s uses obsolete (PF_INET,SOCK_PACKET)\n",
                     current->comm);
        family = PF_PACKET;
    }
```

### 2.2 LSM 安全检查

```c
    err = security_socket_create(family, type, protocol, kern);
    if (err)
        return err;
```

### 2.3 分配 `struct socket`

```c
    sock = sock_alloc();       // socket.c:692
    if (!sock) {
        net_warn_ratelimited("socket: no more sockets\n");
        return -ENFILE;
    }
    sock->type = type;
```

### 2.4 查找协议族（核心）

```c
#ifdef CONFIG_MODULES
    // 若 net_families[family] 为空，尝试加载 net-pf-<N> 模块
    if (rcu_access_pointer(net_families[family]) == NULL)
        request_module("net-pf-%d", family);
#endif

    rcu_read_lock();
    pf = rcu_dereference(net_families[family]);  // 获取协议族
    err = -EAFNOSUPPORT;
    if (!pf)
        goto out_release;
```

`net_families` 是一个数组，定义在 socket.c:230：

```c
static const struct net_proto_family __rcu *net_families[NPROTO] __read_mostly;
```

对于 `AF_INET`，`pf` 指向 `inet_family_ops`，其在 `net/ipv4/af_inet.c` 中注册：

```c
// net/ipv4/af_inet.c:1157
static const struct net_proto_family inet_family_ops = {
    .family = PF_INET,
    .create = inet_create,
    .owner = THIS_MODULE,
};
```

### 2.5 调用 `pf->create` 进入协议层

```c
    if (!try_module_get(pf->owner))
        goto out_release;
    rcu_read_unlock();

    err = pf->create(net, sock, protocol, kern);  // → inet_create()
```

`pf->create` 是函数指针，指向具体协议族的创建函数。`AF_INET` → `inet_create`，`AF_UNIX` → `unix_create()`。

---

## 3. `struct socket` 和 `struct sock` 的关系

### 3.1 两个核心结构体

**`struct socket`**（include/linux/net.h:138）：

```c
struct socket {
    socket_state     state;      // SS_UNCONNECTED / SS_CONNECTED / ...
    short            type;       // SOCK_STREAM / SOCK_DGRAM / ...
    unsigned long    flags;
    struct file     *file;       // 反向指向打开的文件
    struct sock     *sk;         // 指向底层 struct sock
    const struct proto_ops *ops; // 协议操作集（bind/connect/listen/...）
    struct socket_wq wq;        // 等待队列
};
```

**`struct sock`**（include/net/sock.h）：

```c
struct sock {
    __common_prot_header  // 通用头，嵌入到 struct inet_sock
    // ...
    struct sk_buff_head   sk_receive_queue;   // 接收队列
    struct sk_buff_head   sk_write_queue;      // 发送队列
    struct proto          *sk_prot;            // 指向协议操作（tcp_prot/udp_prot）
    // ...
};
```

### 3.2 关系图

```
用户进程
    │
    ▼
struct file *                ←── fd_install() 安装到进程 fd 表
    │
    ▼
struct socket (struct socket_wq wq)   ←── socket 文件系统 (sockfs) 的 inode 私有数据
    │
    ▼ (socket->sk)
struct sock (sk_prot → tcp_prot)       ←── 更底层的套接字数据结构
    │
    ▼ (struct inet_sock 嵌入 struct sock)
struct inet_sock (inet_num, inet_sport, inet_daddr, ...)
    │
    ▼
struct tcp_sock / udp_sock / raw_sock  ←── 各协议私有扩展
```

### 3.3 关键性质

- **`struct socket` 是 VFS 层**：`socket` 对应一个文件系统中的 inode（属于 sockfs），暴露给用户的是文件描述符。
- **`struct sock` 是协议栈层**：是各协议（TCP/UDP/SCTP）内部的套接字表示，包含排队、内存管理、协议状态机。
- **`socket->ops` 是协议的 BSD socket API**：`inet_stream_ops`、`inet_dgram_ops` 等。
- **`sock->sk_prot` 是协议的更低层操作**：内存分配、哈希表、连接管理等。

两者通过 `socket->sk` 互相引用，初始化由 `sock_init_data()` 完成（socket.c:1625）。

---

## 4. `sock_alloc` → inode 分配流程

### 4.1 `sock_alloc`

```c
// net/socket.c:692
struct socket *sock_alloc(void)
{
    struct inode *inode;
    struct socket *sock;

    inode = new_inode_pseudo(sock_mnt->mnt_sb);  // 从 sockfs super_block 分配 inode
    if (!inode)
        return NULL;

    sock = SOCKET_I(inode);                     // 从 inode 获取 socket 指针

    inode->i_ino = get_next_ino();
    inode->i_mode = S_IFSOCK | S_IRWXUGO;
    inode->i_uid = current_fsuid();
    inode->i_gid = current_fsgid();
    inode->i_op = &sockfs_inode_ops;            // 文件系统 inode 操作

    return sock;
}
```

### 4.2 sockfs inode 分配

`sockfs` 是一个伪文件系统（pseudo-fs），其 super_block 在 socket.c 初始化时挂载：

```c
// net/socket.c:404
static const struct super_operations sockfs_ops = {
    .alloc_inode = sock_alloc_inode,
    .free_inode  = sock_free_inode,
    .evict_inode = sock_evict_inode,
    .statfs      = simple_statfs,
};

// net/socket.c:324
static struct inode *sock_alloc_inode(struct super_block *sb)
{
    struct sockfs_inode *si;
    si = alloc_inode_sb(sb, sock_inode_cachep, GFP_KERNEL);

    si->socket.wq.wait   = { 0 };
    si->socket.wq.fasync_list = NULL;
    si->socket.state = SS_UNCONNECTED;
    si->socket.ops   = NULL;
    si->socket.sk    = NULL;
    si->socket.file  = NULL;

    return &si->vfs_inode;
}
```

**注意**：`sockfs_inode` 是嵌入 `socket_alloc` 的扩展：

```c
// net/socket.c:313
struct sockfs_inode {
    struct simple_xattrs *xattrs;
    struct simple_xattr_limits xattr_limits;
    struct socket_alloc;   // ← 展开为 struct socket_wq + fields
};
```

而 `SOCKET_I()` 是从 VFS inode 找回 socket 的宏：

```c
#define SOCKET_I(inode) (&(container_of(inode, struct sockfs_inode, vfs_inode)->socket))
```

### 4.3 分配流程图

```
sock_alloc()
  │
  ▼ new_inode_pseudo(sock_mnt->mnt_sb)
     │
     ▼ sock_alloc_inode(sb)      ← 从 slab cache "sock_inode_cache" 分配
        │
        ▼ struct sockfs_inode { vfs_inode + socket }
           │
           ▼ SOCKET_I(inode) 取出 struct socket *
              │
              ▼ 初始化 inode 字段（i_ino, i_mode, i_uid, i_op）
                 │
                 ▼ 返回 struct socket *
```

---

## 5. `inet_create` → tcp_prot / udp_prot 绑定

```c
// net/ipv4/af_inet.c:259
static int inet_create(struct net *net, struct socket *sock, int protocol, int kern)
{
    struct sock *sk;
    struct inet_protosw *answer;
    struct inet_sock *inet;
    struct proto *answer_prot;
    unsigned char answer_flags;
    int try_loading_module = 0;
    int err;

    sock->state = SS_UNCONNECTED;

    // 从 inetsw[type] 链表中查找匹配的协议
lookup_protocol:
    err = -ESOCKTNOSUPPORT;
    rcu_read_lock();
    list_for_each_entry_rcu(answer, &inetsw[sock->type], list) {
        // 在 inetsw[SOCK_STREAM] / inetsw[SOCK_DGRAM] / inetsw[SOCK_RAW] 中查找
        if (protocol == answer->protocol || 
            IPPROTO_IP == protocol ||
            IPPROTO_IP == answer->protocol) {
            // ...
            break;
        }
    }
```

### 5.1 inetsw 表

`inetsw` 是按 socket type（`SOCK_STREAM`、`SOCK_DGRAM`、`SOCK_RAW`）索引的链表，初始化时填入：

```c
// net/ipv4/af_inet.c:1164
static struct inet_protosw inetsw_array[] = {
    {
        .type       = SOCK_STREAM,
        .protocol   = IPPROTO_TCP,
        .prot       = &tcp_prot,
        .ops        = &inet_stream_ops,
        .flags      = INET_PROTOSW_PERMANENT | INET_PROTOSW_ICSK,
    },
    {
        .type       = SOCK_DGRAM,
        .protocol   = IPPROTO_UDP,
        .prot       = &udp_prot,
        .ops        = &inet_dgram_ops,
        .flags      = INET_PROTOSW_PERMANENT,
    },
    {
        .type       = SOCK_RAW,
        .protocol   = IPPROTO_IP,
        .prot       = &raw_prot,
        .ops        = &inet_sockraw_ops,
        .flags      = INET_PROTOSW_PERMANENT,
    },
};
```

`inetsw[SOCK_STREAM]` 链表中存放所有流式协议（TCP/SCTP/...），`inetsw[SOCK_DGRAM]` 存放所有数据报协议。

### 5.2 分配 `struct sock`

```c
    sock->ops  = answer->ops;
    answer_prot = answer->prot;
    rcu_read_unlock();

    // 分配 struct sock（由对应 proto 分配，如 tcp_prot.sk_alloc）
    sk = sk_alloc(net, PF_INET, GFP_KERNEL, answer_prot, kern);
    if (!sk)
        goto out;

    inet = inet_sk(sk);
    sock_init_data(sock, sk);   // 将 socket 和 sock 互相绑定

    sk->sk_destruct    = inet_sock_destruct;
    sk->sk_protocol    = protocol;
    sk->sk_backlog_rcv = sk->sk_prot->backlog_rcv;

    // 若协议需要（如 TCP），调用 proto->init()
    if (sk->sk_prot->init) {
        err = sk->sk_prot->init(sk);
        if (err)
            goto out_sk_release;
    }
```

**`sk_alloc`** 是关键：它根据 `answer_prot`（即 `tcp_prot` / `udp_prot` / `raw_prot`）分配对应大小的 `struct sock` 子结构：

```c
// include/net/sock.h
struct sock *sk_alloc(struct net *net, int family, gfp_t priority,
                       struct proto *prot, int kern);
```

TCP 协议下分配 `struct tcp_sock`（包含 `struct inet_sock` + `struct tcp_sock`），UDP 协议下分配 `struct udp_sock`。

### 5.3 绑定关系图

```
inet_create()
  │
  ▼ 在 inetsw[type] 中找到 answer
    │
    ├─ answer->ops    → inet_stream_ops / inet_dgram_ops / inet_sockraw_ops
    │                   设置到 socket->ops
    │
    └─ answer->prot  → tcp_prot / udp_prot / raw_prot / ping_prot / ...
                         设置到 sock->sk_prot
  │
  ▼ sk_alloc(net, PF_INET, ..., answer_prot)
    │
    ├─ tcp_prot → sk_alloc → allocate struct tcp_sock (sizeof ~1200 bytes)
    │               └─> sk->sk_prot = tcp_prot
    │               └─> sk->sk_destruct = inet_sock_destruct
    ├─ udp_prot → sk_alloc → allocate struct udp_sock (sizeof ~600 bytes)
    │               └─> sk->sk_prot = udp_prot
    └─ raw_prot → sk_alloc → allocate struct raw_sock

  ▼ sock_init_data(sock, sk)
      socket->sk = sk
      sk->sk_socket = sock (via反向指针)
```

---

## 6. `sock_map_fd` → `alloc_file` 路径

从 `__sys_socket` 继续：

```c
// net/socket.c:1801
int __sys_socket(int family, int type, int protocol)
{
    struct socket *sock;
    int flags;

    sock = __sys_socket_create(family, type, update_socket_protocol(...));
    if (IS_ERR(sock))
        return PTR_ERR(sock);

    flags = type & ~SOCK_TYPE_MASK;
    if (SOCK_NONBLOCK != O_NONBLOCK && (flags & SOCK_NONBLOCK))
        flags = (flags & ~SOCK_NONBLOCK) | O_NONBLOCK;

    return sock_map_fd(sock, flags & (O_CLOEXEC | O_NONBLOCK));  // → fd
}
```

### 6.1 `sock_map_fd`

```c
// net/socket.c:564
static int sock_map_fd(struct socket *sock, int flags)
{
    struct file *newfile;
    int fd = get_unused_fd_flags(flags);   // 分配空闲 fd
    if (unlikely(fd < 0)) {
        sock_release(sock);
        return fd;
    }

    newfile = sock_alloc_file(sock, flags, NULL);
    if (!IS_ERR(newfile)) {
        fd_install(fd, newfile);           // 将 fd 和 file* 关联
        return fd;
    }

    put_unused_fd(fd);
    return PTR_ERR(newfile);
}
```

### 6.2 `sock_alloc_file`

```c
// net/socket.c:536
struct file *sock_alloc_file(struct socket *sock, int flags, const char *dname)
{
    struct file *file;

    if (!dname)
        dname = sock->sk ? sock->sk->sk_prot_creator->name : "";

    file = alloc_file_pseudo(SOCK_INODE(sock), sock_mnt, dname,
                O_RDWR | (flags & O_NONBLOCK),
                &socket_file_ops);        // VFS file operations
    if (IS_ERR(file)) {
        sock_release(sock);
        return file;
    }

    file->f_mode |= FMODE_NOWAIT;
    sock->file = file;                     // socket 反向指向 file
    file->private_data = sock;             // file 反向指向 socket
    stream_open(SOCK_INODE(sock), file);
    file_set_fsnotify_mode(file, FMODE_NONOTIFY_PERM);

    return file;
}
```

**`alloc_file_pseudo`** 是 VFS 函数，从 sockfs 伪文件系统分配一个 `struct file`：

```c
// fs/file_table.c
struct file *alloc_file_pseudo(struct inode *inode, struct vfsmount *mnt,
                                const char *name, int flags,
                                const struct file_operations *fop)
{
    static const struct file_operations dummy_fops = { };
    struct file *file;

    file = alloc_file(&file->f_path, flags, fops);
    // 设置 f_path.mnt = mnt, f_path.dentry = ...
    // 设置 f_mode = O_RDWR | ...
    return file;
}
```

### 6.3 `socket_file_ops`：读写操作入口

```c
// net/socket.c:157
static const struct file_operations socket_file_ops = {
    .owner      = THIS_MODULE,
    .read_iter  = sock_read_iter,
    .write_iter = sock_write_iter,
    .poll       = sock_poll,
    .unlocked_ioctl = sock_ioctl,
    .mmap       = sock_mmap,
    .release    = sock_close,
    .fasync     = sock_fasync,
    // ...
};
```

每个文件操作（read/write/ioctl）最终通过 `socket->ops` 派发到具体协议实现。

---

## 7. 文件描述符和 socket fd 的关联

### 完整数据流图

```
用户进程
    │
    │ socket(AF_INET, SOCK_STREAM, 0)
    ▼
SYSCALL_DEFINE3(socket)                          // socket.c:1818
    │
    ▼ __sys_socket()                              // socket.c:1801
      │
      ├─> __sys_socket_create()                   // socket.c:1744
      │     └─> sock_create()                     // socket.c:1720
      │           └─> __sock_create()             // socket.c:1593
      │                 │
      │                 ├─ sock_alloc()           // socket.c:692 → inode + socket
      │                 │
      │                 ├─ net_families[PF_INET] → inet_create()
      │                 │     └─ inetsw[SOCK_STREAM] 查找 tcp_prot
      │                 │
      │                 └─ sk_alloc(..., tcp_prot)
      │                       ├─ 分配 struct tcp_sock
      │                       ├─ sock_init_data(socket, sk)
      │                       └─ sk->sk_prot->init(sk)  → tcp_v4_init_sock()
      │
      └─> sock_map_fd()                           // socket.c:564
            │
            ├─ get_unused_fd_flags(flags)        // → fd = 3 (例如)
            │
            ├─ sock_alloc_file()                  // socket.c:536
            │     ├─ alloc_file_pseudo(inode, &socket_file_ops)
            │     ├─ socket->file = file
            │     └─ file->private_data = socket
            │
            └─ fd_install(fd, file)               // 注册到当前进程 fd 表[fd=3]
                  │
                  ▼
进程 fd 表
  fd=3 → struct file { private_data = struct socket }
             └─→ struct socket { sk = struct tcp_sock }
                           └─→ sk->sk_prot = tcp_prot
```

### 关键关联机制

| 关系 | 代码位置 |
|------|---------|
| `socket ↔ inode` | `SOCKET_I(inode)` / `SOCK_INODE(sock)` |
| `socket ↔ file` | `socket->file`（由 `sock_alloc_file` 设置） |
| `file → socket` | `file->private_data = sock` |
| `socket ↔ sock` | `socket->sk = sk`（由 `sock_init_data` 设置） |
| `sock → socket` | `sk->sk_socket`（反向指针） |
| `sock → proto` | `sk->sk_prot = tcp_prot` |
| `fd → file` | `fd_install(fd, newfile)` |

---

## 总结

`sock_create` 的完整流程：

```
用户调用 socket(2)
  → SYSCALL_DEFINE3(socket)
    → __sys_socket()
      → __sys_socket_create() → sock_create() → __sock_create()

__sock_create() 内部：
  1. sock_alloc()           分配 struct socket + VFS inode（sockfs）
  2. net_families[family]  查找协议族（如 PF_INET → inet_family_ops）
  3. pf->create()           调用 inet_create()

inet_create() 内部：
  4. inetsw[type]           查找对应 type 的协议（tcp/udp/raw）
  5. sk_alloc(..., prot)    分配 struct sock（TCP 为 tcp_sock，UDP 为 udp_sock）
  6. sock_init_data()       互相绑定 socket ↔ sock
  7. sk->sk_prot->init()    协议特定初始化（如 tcp_v4_init_sock）

返回 socket 到 __sys_socket()

sock_map_fd() 内部：
  8. get_unused_fd_flags()  分配文件描述符（fd）
  9. sock_alloc_file()      分配 struct file，绑定 file ↔ socket
  10. fd_install()          将 fd 和 file* 写入进程 fd 表

进程持有 fd → file* → socket* → sk*（tcp_sock/udp_sock）→ tcp_prot/udp_prot
```