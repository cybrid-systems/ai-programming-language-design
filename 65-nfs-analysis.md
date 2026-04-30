# Linux Kernel NFS / sunrpc 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/nfs/` + `net/sunrpc/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 NFS？

**NFS（Network File System）** 是基于 RPC 的**网络文件系统**，让远程主机像本地磁盘一样访问文件。

---

## 1. sunrpc — RPC 框架

```c
// net/sunrpc/xprt.c — rpc_wait_bit
struct rpc_task {
    unsigned long           tk_flags;
    int                     tk_status;        // 返回码
    struct rpc_xprt        *tk_xprt;        // 传输
    struct rpc_message     *tk_msg;          // RPC 消息
    struct work_struct     tk_work;
};

// RPC 调用流程：
// rpc_call() → clnt_call() → xprt_transmit() → udp_sendmsg() / tcp_sendmsg()
```

---

## 2. NFS 文件操作

```c
// fs/nfs/file.c — nfs_file_operations
static const struct file_operations nfs_file_operations = {
    .read = nfs_file_read,
    .write = nfs_file_write,
    .open = nfs_file_open,
    .fsync = nfs_file_fsync,
    .lock = nfs_lock,
};

// nfs_write_verifier — 写操作重试保护
// NFS v3/v4 使用 open_owner + seqid 防重试
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `fs/nfs/nfs4proc.c` | NFS v4 操作（READ、WRITE、OPEN、COMMIT）|
| `net/sunrpc/xprt.c` | RPC 传输层 |
| `fs/nfs/inode.c` | NFS inode 操作 |
