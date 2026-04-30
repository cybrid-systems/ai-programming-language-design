# Linux Kernel packet_mmap 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/packet/af_packet.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. packet_mmap 概述

**packet_mmap** 让用户空间通过**共享内存（mmap）**直接读取原始套接字数据包，避免 `recvfrom()` 的每次 syscall 开销。

---

## 1. 核心结构

```c
// net/packet/af_packet.c — tpacket_ring_desc
struct tpacket_desc {
    struct tpacket_hdr_v1   *iov;          // mmap 区域的帧描述符
    unsigned int            tp_status;     // 状态（TP_STATUS_*）
    unsigned int            tp_len;        // 数据长度
    unsigned int            tp_snaplen;    // 最大捕获长度
    unsigned short          tp_mac;
    unsigned short          tp_net;
};

// mmap 环形缓冲布局：
// [block 0: tpacket_block_desc]
// [block 1: tpacket_block_desc]
// ...
// 每 block 包含多个 tpacket_rx_desc
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `net/packet/af_packet.c` | `packet_mmap`、`tpacket_rcv` |
