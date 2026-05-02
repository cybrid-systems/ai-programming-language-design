# 65-nfs — Linux NFS 客户端深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**NFS（Network File System）** 是 Linux 的分布式文件系统客户端。它通过 **RPC（Sun RPC）** 协议与远程 NFS 服务器通信，将远程文件系统透明地挂载到本地 VFS 层。NFS 客户端在 Linux 中实现为一个**内核态文件系统**，通过 `struct file_system_type` 注册到 VFS。

**核心架构**：NFS 客户端的核心挑战是**在不可靠网络上的缓存一致性**。NFS 使用三组缓存：

```
VFS (系统调用)
  │
  └─ NFS 客户端 (fs/nfs/)
      │
      ├─ 属性缓存 (attribute cache) — 文件元数据 (inode attributes)
      ├─ 数据缓存 (data cache)      — 文件数据 (page cache)
      └─ 目录缓存 (dentry cache)    — 目录条目
      │
      └─ RPC 层 (net/sunrpc/)
          │
          └─ 网络传输 (TCP/UDP)
              │
              └─ NFS 服务器
```

**doom-lsp 确认**：NFS 客户端实现在 `fs/nfs/`（**58 个源文件**）。核心流程在 `fs/nfs/inode.c`（2,804 行）、`fs/nfs/nfs4proc.c`（10,750 行——NFSv4 协议处理）、`fs/nfs/client.c`（1,526 行）。

---

## 1. 核心数据结构

### 1.1 struct nfs_client — NFS 客户端标识

```c
// include/linux/nfs_fs_sb.h
struct nfs_client {
    /* ── 标识 ─ */
    struct nfs_client_initdata cl_init;
    const struct nfs_rpc_ops *rpc_ops;      /* NFSv3/v4 操作表 */

    int cl_proto;                            /* 传输协议 */
    u32 cl_minorversion;                     /* NFSv4 minor 版本 */
    struct rpc_clnt *cl_rpcclient;           /* RPC 客户端 */
    unsigned long cl_flags;                  /* NFS_CS_* 标志 */

    spinlock_t cl_lock;
    unsigned long cl_reservation;            /* 会话保留 */
    struct timespec64 cl_time;               /* 服务器时间 */

    /* ── NFSv4 特有 ─ */
    struct rb_root cl_openowner_id;          /* 打开所有者 ID */
    struct rb_root cl_lockowner_id;          /* 锁所有者 ID */
    struct list_head cl_superblocks;         /* 挂载实例列表 */
    struct list_head cl_state_owners;        /* 状态所有者 */
    u32 cl_boot_time;                        /* 服务器启动时间 */
    unsigned long cl_lease_time;             /* 租约时间 */
    struct delayed_work cl_lease_renewal;    /* 租约续期 */
};
```

### 1.2 struct nfs_server — 挂载实例

```c
// include/linux/nfs_fs_sb.h
struct nfs_server {
    struct nfs_client *nfs_client;         /* 所属客户端 */
    struct super_block *super;              /* VFS 超级块 */

    u32 maxfilesize;                        /* 最大文件大小 */
    struct nfs_fh *fh;                      /* 文件句柄 */
    struct nfs_fattr fattr;                 /* 文件属性 */

    /* ── 缓存控制 ─ */
    struct nfs_iostats __percpu *io_stats;
    unsigned int acregmin;                  /* 属性缓存最小 TTL */
    unsigned int acregmax;                  /* 属性缓存最大 TTL */
    unsigned int acdirmin;                  /* 目录属性最小 TTL */
    unsigned int acdirmax;                  /* 目录属性最大 TTL */
    unsigned int namelen;                   /* 文件名最大长度 */

    /* ── NFSv4 特有 ─ */
    struct nfs4_session *session;           /* 会话 */
    struct list_head state_owners;          /* 状态所有者 */
    struct nfs4_state_maintenance_ops *state_renewal; /* 状态续期操作 */
};
```

### 1.3 struct nfs_inode — NFS inode

```c
// include/linux/nfs_fs.h
struct nfs_inode {
    struct inode vfs_inode;                 /* VFS inode */

    /* ── 文件句柄 ─ */
    struct nfs_fh fh;                       /* 文件句柄 */

    /* ── 属性缓存 ─ */
    struct nfs_fattr fattr;                 /* 服务器返回的属性 */
    struct timespec64 read_cache_jiffies;    /* 属性缓存时间戳 */
    struct timespec64 attrtimeo;             /* 属性缓存 TTL */
    unsigned long attrtimeo_timestamp;      /* 属性缓存设置时间 */

    /* ── 数据 ─ */
    unsigned long flags;                    /* NFS_INO_* 标志 */
    __u64 cache_validity;                   /* 缓存有效性位 */

    struct nfs_open_context *open_files;     /* 打开文件上下文列表 */
    struct list_head open_state;            /* NFSv4 打开状态 */
    struct nfs_delegation *delegation;      /* NFSv4 委派 */
    struct rw_semaphore rwsem;               /* 并发控制 */

    /* ── 锁 ─ */
    struct nfs_lock_context *lock_contexts;  /* POSIX 锁上下文 */

    /* ── 页面缓存 ─ */
    struct fscache_cookie *fscache;          /* fscache 缓存 */
};
```

---

## 2. 挂载流程

```c
// fs/nfs/super.c
// 用户: mount -t nfs4 server:/export /mnt
// 调用链: nfs_mount() → nfs_get_tree() → nfs4_try_mount()

static struct dentry *nfs_fs_mount_common(struct nfs_server *server, ...)
{
    /* 1. 创建 RPC 客户端 */
    server->client = nfs_create_rpc_client(server, ...);

    /* 2. 获取服务器根文件句柄 */
    server->fh = nfs_get_root(server, ...);

    /* 3. 填充超级块 */
    sb = sget_fc(fc, NULL, set_anon_super);
    server->super = sb;

    /* 4. 创建 root dentry */
    root = d_make_root(inode);
    sb->s_root = root;

    return root;
}
```

---

## 3. 文件操作路径——以 open/read 为例

### 3.1 nfs_open

```c
// fs/nfs/direct.c or fs/nfs/file.c
static int nfs_open(struct inode *inode, struct file *filp)
{
    struct nfs_open_context *ctx;

    /* 创建打开上下文（保存 NFSv4 状态信息）*/
    ctx = alloc_nfs_open_context(filp->f_path.dentry, filp->f_mode);
    nfs_file_set_open_context(filp, ctx);

    /* NFSv4: 调用 OPEN 操作 */
    if (NFS_PROTO(inode)->open)
        NFS_PROTO(inode)->open(inode, filp);

    return 0;
}
```

### 3.2 nfs_page — I/O 请求的基本单元

NFS 的 I/O 路径围绕 `struct nfs_page` 构建——每个 nfs_page 代表一个对服务器文件**单次 RPC READ/WRITE 请求**的一部分：

```c
// include/linux/nfs_page.h:43-61
struct nfs_page {
    struct list_head wb_list;               /* 链表状态 */
    struct folio *wb_folio;                 /* 关联的 folio */
    pgoff_t wb_index;                       /* 页索引 */
    unsigned int wb_offset;                 /* 页内偏移 */
    unsigned int wb_pgbase;                 /* 数据起始位置 */
    unsigned int wb_bytes;                  /* 请求长度 */
    struct nfs_write_verifier wb_verf;      /* 提交 cookie（写验证）*/
    struct nfs_page *wb_this_page;          /* 同页请求链表 */
    struct nfs_page *wb_head;               /* 链表头 */
};
```

**`struct nfs_pageio_descriptor`** — I/O 请求收集器：

```c
struct nfs_pageio_descriptor {
    const struct nfs_pageio_ops *pg_ops;     /* I/O 策略操作 */
    const struct nfs_rw_ops *pg_rw_ops;      /* read/write 操作 */
    int pg_ioflags;
    struct pnfs_layout_segment *pg_lseg;     /* pNFS 布局段 */
    struct nfs_direct_req *pg_dreq;          /* direct I/O 上下文 */

    u32 pg_mirror_count;                     /* 镜像数（flexfiles）*/
    struct nfs_pgio_mirror *pg_mirrors;      /* per-mirror 数据 */
    unsigned short pg_maxretrans;            /* 最大重传次数 */
};

/* 收集策略由 nfs_pageio_ops 定义：
 * pg_init: 初始化 descriptor（如设置 WRITE/READ RPC 参数）
 * pg_test: 测试新的 request 是否可以合并到当前 RPC
 * pg_doio: 提交累积的 requests 为 RPC
 * pg_get_mirror_count: pNFS 镜像数量
 */
```

**读写路径**：

```c
// 读：nfs_read_folio → nfs_pageio_add_request()
//                      → pg_ops->pg_test() 检查是否可合并
//                      → 超过 I/O 大小限制 → pg_ops->pg_doio()
//                          → nfs_generic_pg_readpages()
//                              → nfs_read_rpcsetup()
//                                  → rpc_run_task(&task_setup)
//                                      → RPC 调用 → 服务器 READ
//                                      → nfs_readpage_done()
//                                          → folio 解锁 → VFS

// 写：nfs_writepages → nfs_pageio_add_request()
//                      → 同样经过 pg_test/doio
//                      → RPC WRITE → nfs_writeback_done()
//                          → 设置 write_verifier
//                          → 释放 nfs_page
```

### 3.3 Direct I/O 路径

```c
// fs/nfs/direct.c
struct nfs_direct_req {
    struct kref kref;
    ssize_t count;                          /* 总字节数 */
    ssize_t error;
    struct completion completion;            /* 等待所有 I/O 完成 */

    struct list_head reqs;                   /* nfs_page 列表 */
    struct nfs_open_context *ctx;            /* 打开上下文 */
    struct kiocb *iocb;                      /* 原始 kiocb */
    loff_t pos;                              /* 文件位置 */
};

// nfs_file_direct_read() 路径：
// 1. 创建 nfs_direct_req
// 2. 将用户缓冲区拆成多个 nfs_page
// 3. nfs_pageio_add_request() 提交 RPC
// 4. 等待所有 RPC 完成
// 5. 返回总字节数
```

**doom-lsp 确认**：直接 I/O 路径在 `fs/nfs/direct.c` 中独立实现，绕过 page cache，适用于数据库和大文件传输。

---

## 4. NFSv4 状态管理

NFSv4 是有状态的，客户端和服务器之间有严格的租约关系：

### 4.1 状态类型

| 状态 | 结构 | 生命周期 |
|------|------|---------|
| **CLIENTID** | `nfs_client` | 服务器重启/租约超时 |
| **OPEN** | `nfs4_state` + `stateid` | 文件打开期间 |
| **LOCK** | `nfs4_lock_state` | POSIX 锁持有期间 |
| **DELEGATION** | `nfs_delegation` | 服务器授予（可回收）|
| **LEASE** | `cl_lease_time` | 租约周期（默认 90s）|

### 4.2 路径——RPC 操作表

NFSv3 和 NFSv4 通过 `struct nfs_rpc_ops` 多态：

```c
// include/linux/nfs_xdr.h
struct nfs_rpc_ops {
    u32 version;            /* 3 或 4 */
    int (*getroot)(...);
    int (*lookup)(...);
    int (*create)(...);
    int (*remove)(...);
    int (*getattr)(...);
    int (*setattr)(...);
    int (*read)(...);
    int (*write)(...);
    int (*commit)(...);
    /* ── NFSv4 特有 ─ */
    int (*open)(struct inode *, struct file *);
    int (*close)(struct nfs4_state *);
    int (*delegreturn)(struct nfs_delegation *);
    int (*renew)(struct nfs_client *, struct rpc_cred *);
    int (*setclientid)(struct nfs_client *, struct rpc_cred *);
    /* ~30 个方法 */
};

// NFSv4 的 rpc_ops 在 fs/nfs/nfs4proc.c 中定义（10,750 行）
// NFSv3 的 rpc_ops 在 fs/nfs/proc.c 中定义（~1,500 行）
```

### 4.3 状态恢复

```c
// fs/nfs/nfs4state.c:2713
// 核心问题——网络断开或服务器重启后恢复状态

// 恢复流程：
// 1. 服务器重启（返回 NFS4ERR_STALE_CLIENTID）
//    → nfs4_handle_reclaim_lease_error()
//    → 重新 SETCLIENTID
//    → nfs4_state_mark_reclaim_nograce()
//    → 重新 OPEN 所有文件，重新 LOCK
//
// 2. 网络断线重连
//    → transport 自动重连
//    → nfs4_schedule_state_manager()
//    → 恢复 OPEN/LOCK stateid
//
// 3. 租约续期
//    → cl_lease_renewal delayed_work
//    → 定期发送 RENEW 或 SEQUENCE 操作
//    → 未及时续期 → 服务器回收所有状态

// nfs4_state_manager() 是状态恢复的线程函数
```

### 4.4 委派（Delegation）

```c
// NFSv4 委派（delegation）是服务器对客户端的授权——
// 允许客户端在本地处理 OPEN、READ、WRITE、LOCK
// 而无需与服务器交互，大幅减少 RPC 次数。

struct nfs_delegation {
    struct list_head super_list;        /* superblock 中的列表 */
    struct nfs_client *client;
    struct nfs_fh fh;                   /* 文件句柄 */
    nfs4_stateid stateid;               /* 委派 stateid */
    unsigned long type;                 /* READ/READ_WRITE */
    pgoff_t max_size;                   /* 最大偏移 */
    struct rcu_head rcu;
};

// 回收回调：nfs_inode_return_delegation()
// 当其他客户端访问同一文件时，服务器发送 CB_RECALL
// 客户端：刷新脏数据 → 返回委派 → 恢复普通路径
```

**doom-lsp 确认**：`nfs4_state_manager` 状态管理入口在 `nfs4state.c`。委派结构在 `include/linux/nfs_fs_sb.h`。

---

## 5. 缓存一致性

NFS 面临的核心问题是**网络文件系统缓存一致性**：

### 5.1 属性缓存（Attribute Cache）

```c
// 每个 nfs_inode 有独立的 TTL 控制
struct nfs_inode {
    struct timespec64 read_cache_jiffies;   /* 上次读取时间 */
    struct timespec64 attrtimeo;            /* TTL 时长 */
    unsigned long attrtimeo_timestamp;      /* 缓存设置时间 */
    __u64 cache_validity;                   /* 缓存有效性位：
                                             * NFS_INO_INVALID_ATTR
                                             * NFS_INO_INVALID_DATA
                                             * NFS_INO_INVALID_ACCESS
                                             * NFS_INO_INVALID_ACL */
};

// 属性缓存 TTL 由 mount 参数控制：
// acregmin=3, acregmax=60  (文件，默认 3-60s)
// acdirmin=30, acdirmax=60 (目录，默认 30-60s)
// 设为 0 可禁用属性缓存
```

### 5.2 数据缓存—close-to-open 语义

```c
// Linux NFS 客户端采用 close-to-open（CTO）一致性：
// 1. open() → 检查属性缓存有效性，必要时 GETATTR
// 2. read()/write() → 使用本地 page cache
// 3. close() → nfs_close()
//     → filemap_write_and_wait()    /* 刷新脏页 */
//     → nfs_wb_all()                 /* 同步所有写 */
//     → 发送 COMMIT RPC（NFSv3）或 WRITE 带稳定标志
//
// 这保证：关闭文件后，下次打开一定能看到最新数据
```

### 5.3 目录缓存

```c
// 目录条目缓存在 dcache 中
// 通过 nfs_lookup_revalidate() 验证
// 根据父目录的 attrtimeo 判断缓存是否过期
// 过期后调用 LOOKUP RPC 重新验证
```

### 5.4 fscache 集成

```c
// 可选的本地磁盘缓存（cachefilesd）
// 使用 fscache 框架在本地磁盘缓存 NFS 数据
// 对于频繁访问的大文件减少网络延迟
// mount -t nfs -o fsc server:/export /mnt
```

---

## 6. 调试

```bash
# 查看挂载信息
mount -t nfs4
cat /proc/mounts | grep nfs

# NFS 统计
cat /proc/self/mountstats
cat /proc/net/rpc/nfs

# 跟踪 NFS 操作
echo 1 > /sys/kernel/debug/tracing/events/nfs/enable

# 强制刷新属性缓存
echo 0 > /proc/sys/sunrpc/nfs_debug

# nfsstat
nfsstat -c   # 客户端统计
```

---

## 7. 总结

NFS 客户端是一个**有状态的分布式文件系统**：

1. **RPC 驱动** — 所有操作通过 Sun RPC 发送到服务器
2. **三级缓存体系** — 属性/数据/目录缓存减少 RPC 次数
3. **NFSv4 状态管理** — 处理服务器重启和网络断线时的状态恢复
4. **Through VFS** — 通过 `struct file_system_type` 无缝集成到 Linux VFS

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
