# 212-vhost_net — vhost-net 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/vhost/net.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**vhost-net** 是内核中的 virtio-net 后端实现，将 virtio 环形缓冲区的数据直接传输到 tun/tap，减少上下文切换。

---

## 1. vhost-net 架构

```
传统 virtio-net：
  用户空间 virtio-net 驱动 ↔ KVM ← → tun/tap

vhost-net：
  内核 vhost-net 模块直接处理 virtio 缓冲
  → 零拷贝、更低延迟
```

---

## 2. vhost_net_work

```c
// drivers/vhost/net.c — vhost_net_open
struct vhost_net {
    struct vhost_dev *dev;
    struct vhost_virtqueue *vqs[MAX_VQS];
    struct socket *sock;  // 连接用户空间的 vsock
};
```

---

## 3. 西游记类喻

**vhost-net** 就像"天庭的快递直达"——

> vhost-net 像在两个城市之间开了直达航线，不需要中途在驿站换货（减少上下文切换）。快递（数据包）直接从发货方到收货方，驿站（用户空间）只负责监督，不用参与实际货物搬运。

---

## 4. 关联文章

- **virtio**（相关）：vhost-net 是 virtio 的后端
- **tap/tun**（相关）：vhost-net 通过 tun/tap 与用户空间交互