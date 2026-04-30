# NFS — 网络文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/nfs/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**NFS** 是 Unix 最经典的网络文件系统，通过 RPC（portmap/sunrpc）导出目录树到网络客户端。

---

## 1. 核心数据结构

### 1.1 nfs_server — NFS 服务器

```c
// fs/nfs/nfs4file.c — nfs_server（简化）
struct nfs_server {
    struct nfs_fsinfo       *fsinfo;      // 文件系统信息
    struct nfs_fh           *fid_root;    // 根文件句柄
    unsigned int            rsize;        // 读取大小
    unsigned int            wsize;        // 写入大小
    unsigned int            timeo;        // 超时
    unsigned int            retrans;      // 重传次数

    // RPC
    struct rpc_clnt         *client;       // RPC 客户端
    struct rpc_cred         *cred;        // 凭证

    // 状态
    atomic_t                active;       // 引用计数
};
```

### 1.2 nfs_inode — NFS inode

```c
// fs/nfs/inode.c — nfs_inode
struct nfs_inode {
    struct inode            vfs_inode;     // VFS inode 基类
    struct nfs_fh          *fh;          // 文件句柄
    struct nfs_server       *server;      // 所属服务器
    unsigned long           flags;        // NFS_INO_* 标志

    // 缓存
    unsigned long           change_attr;  // 属性版本（用于缓存验证）
    __u64                   fileid;      // 文件 ID
    struct timespec         atime;        // 访问时间（来自服务器）
    struct timespec         mtime;        // 修改时间
    unsigned int            nfs4.flags;    // NFS4 特有

    // 锁
    struct nfs_locker       locker;       // 文件锁
};
```

### 1.3 nfs_fattr — 文件属性

```c
// include/linux/nfs3.h — nfs_fattr
struct nfs_fattr {
    struct nfs_fh           *fh;          // 文件句柄
    __u64                   fileid;       // 文件 ID
    umode_t                 mode;        // 文件模式
    unsigned long           nlink;        // 链接数
    uid_t                   uid;         // UID
    gid_t                   gid;         // GID
    __u64                   size;        // 文件大小
    __u64                   used;        // 磁盘使用
    struct timespec         atime;        // 访问时间
    struct timespec         mtime;        // 修改时间
    struct timespec         ctime;        // 状态改变时间
    __u64                   change_attr;  // 属性版本（NFSv4）
    __u32                   fsid;        // 文件系统 ID
    __u64                   mounted_on_fileid; // 挂载点文件 ID
};
```

---

## 2. read — 读取文件流程

### 2.1 nfs_file_read → nfs_do_sync_read

```c
// fs/nfs/file.c — nfs_file_read
ssize_t nfs_file_read(struct file *filp, char *buf, size_t count, loff_t *pos)
{
    struct nfs_page         *req;
    struct page             **pages;

    // 1. 构建 NFS READ 请求
    req = nfs_create_request(filp->private_data, NULL, offset, count);

    // 2. 调用 NFS_PROC_READ（RPC 调用）
    status = NFS_PROC_READ(server, req, pages);

    // 3. 复制到用户空间
    copy_to_user(buf, page_data, count);

    return status;
}
```

### 2.2 nfs_proc_read — RPC 调用

```c
// fs/nfs/proc.c — nfs_proc_read
static int nfs_proc_read(struct nfs_server *server, struct nfs_page *req, ...)
{
    struct rpc_message msg = {
        .rpc_proc = NFS3PROC_READ,
        .rpc_argp = &arg,
        .rpc_resp = &res,
    };

    // RPC 调用（可能涉及 retrans）
    status = rpc_call_sync(server->client, &msg, 0);

    // 更新 inode 属性缓存
    nfs_update_inode(inode, res.fattr);
}
```

---

## 3. write — 写入文件流程

```c
// fs/nfs/file.c — nfs_file_write
ssize_t nfs_file_write(struct file *filp, const char *buf, size_t count, loff_t *pos)
{
    // 1. 构建 WRITE 请求
    req = nfs_create_request(NFS_I(inode), page, offset, count);

    // 2. 调用 NFS_PROC_WRITE
    status = NFS_PROC_WRITE(server, req, &res);

    // 3. 如果 COMMIT 必要（stable = unstable），稍后调用 COMMIT
    if (res.verifier)
        nfs_commit_write(inode, offset, count);
}
```

---

## 4. mount — 挂载流程

### 4.1 nfs_mount → nfs4_lookup_root

```c
// fs/nfs/super.c — nfs_get_root
static struct dentry *nfs_get_root(struct super_block *sb, const char *path)
{
    // 1. 获取根文件句柄（LOOKUPMOUNT 或 LOOKUP）
    nfs4_lookup_root(server, path, &fh, &fattr);

    // 2. 填充 inode
    root_inode = nfs_fhget(sb, &fh, fattr);

    // 3. 创建 dentry
    return d_make_root(root_inode);
}
```

---

## 5. VFS 钩子实现

```c
// fs/nfs/inode.c — nfs_file_operations
const struct file_operations nfs_file_operations = {
    .llseek     = nfs_file_llseek,
    .read       = nfs_file_read,
    .write      = nfs_file_write,
    .open       = nfs_open,
    .release    = nfs_release,
    .fsync      = nfs_fsync,
};

const struct inode_operations nfs_file_inode_operations = {
    .getattr    = nfs_getattr,
    .permission = nfs_permission,
    .setattr    = nfs_setattr,
};
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/nfs/inode.c` | `nfs_inode`、`nfs_file_operations` |
| `fs/nfs/proc.c` | `nfs_proc_read`、`nfs_proc_write` |
| `fs/nfs/super.c` | `nfs_get_root`、`nfs_mount` |