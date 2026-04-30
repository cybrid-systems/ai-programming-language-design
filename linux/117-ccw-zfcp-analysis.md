# CCW / zFCP — IBM Z 系列 I/O 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/s390/cio/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

IBM Z 系列（mainframe）使用与 x86 完全不同的 I/O 架构：
- **CCW**（Channel Command Word）：通道命令字
- **CHS**（Channel Subsystem）：通道子系统
- **zFCP**：FCP over zSeries（光纤通道）

---

## 1. CCW 通道命令字

```c
// drivers/s390/cio/ccwdev.h — ccw1
struct ccw1 {
    __u32  cmd_code;     // 命令码（MESSAGE/READ/WRITE/...)
    __u32  cda;          // 数据地址（虚拟/物理）
    __u32  count;        // 传输字节数
    __u32  flags;        // 标志
    //   CCW_FLAG_SLI   = 0x04  // 跳过长度检查
    //   CCW_FLAG_CC     = 0x08  // 连续命令
    //   CCW_FLAG_SUSPEND = 0x10 // 暂停
};

// CCW 链表（Channel Program）
struct ccw1 ccw_chain[] = {
    { .cmd_code = 0x01, .cda = (u32)data, .count = 64, .flags = 0 },
    { .cmd_code = 0x02, .cda = (u32)status, .count = 32, .flags = 0 },
    { .cmd_code = 0x03, .cda = (u32)sense, .count = 24, .flags = 0 },
};
```

---

## 2. I/O 子通道

```c
// drivers/s390/cio/device.h — subchannel
struct subchannel {
    // 标识
    __u16  schid;         // 子通道 ID
    __u8   port;          // 端口号

    // 状态
    enum schib_config config;  // 配置状态

    // I/O 请求
    struct ccw_device *device; // 关联的 CCW 设备
    struct irb         *irb;   // I/O 结果块

    // 通道路径
    struct chp_id      chp_mask; // 通道路径掩码
};
```

---

## 3. zFCP — FCP over IBM Z

```c
// drivers/s390/scsi/zfcp_fc.h — zfcp_fc_wka_port
// zFCP = Fibre Channel Protocol over mainframe channel I/O

struct zfcp_fc_wka_port {
    // WWPN（World Wide Port Name）
    __be64                 wwpn;
    // D_ID（Fabric ID）
    __be32                 d_id;

    // 关联的适配器
    struct zfcp_adapter   *adapter;
};
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/s390/cio/ccwdev.h` | `struct ccw1` |
| `drivers/s390/cio/device.h` | `struct subchannel` |
| `drivers/s390/scsi/zfcp_fc.h` | `struct zfcp_fc_wka_port` |