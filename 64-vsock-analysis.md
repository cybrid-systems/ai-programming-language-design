# Linux Kernel vsock (VM Socket) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/vmw_vsock/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 vsock？

**vsock（VM Socket）** 是虚拟机与宿主机之间的高速通信机制（VMCI→virtio-vsock），绕过网络栈，直接通过 hypervisor 传输数据。

---

## 1. 核心数据结构

```c
// net/vmw_vsock/af_vsock.c — vsock_sock
struct vsock_sock {
    struct sock           sk;               // 继承 sock
    struct vsock_connect  connect;          // 连接信息
    struct vsock_packet   *last_pkt;      // 最后收到的包
    u32                cid;              // Context ID（VM 标识）
    u32                buffer_min_size;
    u32                buffer_max_size;
};

// CID 特殊值：
//   VMADDR_CID_HYPERVISOR = 0   — hypervisor
//   VMADDR_CID_RESERVED = 1     — 保留
//   VMADDR_CID_HOST = 2         — 宿主机
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `net/vmw_vsock/af_vsock.c` | vsock socket 实现 |
| `include/linux/virtio_vsock.h` | virtio-vsock 头 |
