# Linux Kernel CAN Bus / SocketCAN 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/can/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. CAN 总线

**CAN（Controller Area Network）** 是汽车/工业控制常用的广播串行协议，SocketCAN 让 CAN 像 socket一样操作。

---

## 1. 核心结构

```c
// net/can/af_can.c — can_frame
struct can_frame {
    canid_t    can_id;        // CAN ID（11-bit 标准 / 29-bit 扩展）
    __u8       len;           // 数据长度（0-8）
    __u8       data[8];       // 数据
    __u8       __pad;          // padding
    __u8       can_dlc;       // 实际 DLC（len 或 8）
};

// can_filter — 接收过滤器
struct can_filter {
    canid_t    can_id;        // CAN ID
    canid_t    can_mask;      // 掩码
};
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `net/can/af_can.c` | CAN socket 核心 |
| `net/can/bcm.c` | Broadcast Manager（周期消息）|
