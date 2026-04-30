# packet mmap — 高性能包捕获深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/packet/af_packet.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**packet mmap** 允许零拷贝地从内核到用户空间传输网络数据包，比 `recv()` 高效得多。

---

## 1. tpacket_req — 环形缓冲区配置

```c
// include/uapi/linux/if_packet.h — tpacket_req
struct tpacket_req {
    unsigned int        tp_block_size;   // 内存块大小（必须页对齐）
    unsigned int        tp_block_nr;     // 块数量
    unsigned int        tp_frame_size;   // 帧大小（必须块对齐）
    unsigned int        tp_frame_nr;      // 帧数量
};
```

---

## 2. ring buffer — 环形缓冲区

```c
// net/packet/af_packet.c — packet_ring
struct packet_ring {
    // 帧描述符
    struct tpacket_hdr **pg_vec;        // 帧指针数组

    // 当前状态
    unsigned long       pg_vec_order;     // 分配阶数
    unsigned long       pg_vec_pages;     // 页数
    unsigned long       pg_vec_len;       // 帧数

    // 头尾指针
    struct pghead       *prb_bhead;      // 生产者头
    struct pghead       *prb_btail;      // 生产者尾
    unsigned long       frame_offset;      // 当前帧偏移
};
```

---

## 3. 发送流程

```c
// net/packet/af_packet.c — packet_sendmsg
static int packet_sendmsg(struct socket *sock, struct msghdr *msg, size_t len)
{
    struct packet_sock *po = pkt_sk(sock->sk);
    struct tpacket_hdr *th;

    // 1. 获取当前发送帧
    th = get_tpck(po);
    if (!th)
        return -ENOMEM;

    // 2. 复制数据
    memcpy_from_msg(TPACKET_DATA(th), msg, len);

    // 3. 标记为就绪
    th->tp_status = TP_STATUS_SEND;

    // 4. 唤醒消费者
    dev_queue_xmit(po->skb);
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/packet/af_packet.c` | `packet_ring`、`packet_sendmsg` |
| `include/uapi/linux/if_packet.h` | `tpacket_req` |