# Thunderbolt — 高速外设总线深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/thunderbolt/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Thunderbolt** 是 Intel/Apple 开发的点对点高速互连协议（40Gbps/80Gbps），支持 PCIe 数据传输和 DisplayPort 视频输出。

---

## 1. 协议概述

```
Thunderbolt 版本：
- Thunderbolt 1: 10 Gbps (2 通道 PCIe + DisplayPort)
- Thunderbolt 2: 20 Gbps (聚合通道)
- Thunderbolt 3: 40 Gbps (USB-C 接口，PCIe 3.0 x4 + DP 1.3)
- Thunderbolt 4: 40 Gbps (完整 PCIe x4，支持双屏幕）

特点：
- USB-C 接口
- 同时传输 PCIe 数据 + DP 视频
- 菊花链连接（最多 6 台设备）
- 兼容 USB Power Delivery
```

---

## 2. 核心数据结构

### 2.1 tb_switch — Thunderbolt 交换器

```c
// drivers/thunderbolt/tb.h — tb_switch
struct tb_switch {
    struct device           dev;           // 设备

    // 拓扑
    struct tb_port         *ports;         // 端口数组
    unsigned int           port_count;     // 端口数量
    u8                      depth;         // 拓扑深度

    // 路由
    u64                    route;          // 64 位路由路径
    // route 示例：0x1a3b0000 表示通过端口 0x1a、0x3b 到达

    // USB4
    u8                      cap_plug_events; // 即插即用事件能力
    u8                      cap_tmu;        // 时间管理单元能力

    // NVM（Non-Volatile Memory）
    struct tb_nvm           *nvm;           // NVM 存储
};
```

### 2.2 tb_port — Thunderbolt 端口

```c
// drivers/thunderbolt/tb.h — tb_port
struct tb_port {
    struct tb_switch        *sw;            // 所属 switch
    unsigned int            port;            // 端口号（本地）
    enum tb_port_type      type;           // 端口类型
    //   TB_TYPE_PORT         = 0  // 普通 Thunderbol t端口
    //   TB_TYPE_PCIE_UP      = 1  // PCIe 上行
    //   TB_TYPE_PCIE_DOWN    = 2  // PCIe 下行
    //   TB_TYPE_DP_HDMI      = 3  // DisplayPort
    //   TB_TYPE_USB4         = 4  // USB4 端口

    struct tb_port         *remote;         // 对端端口（菊花链）

    // 状态
    bool                    enabled;         // 是否启用
    struct tb_retimer      *retimer;        // retimer 芯片（信号增强）
};
```

---

## 3. USB4 集成

```c
// Thunderbolt 3/4 底层使用 USB4 架构：

// USB4 规范：
// - USB4 基于 PCIe 和 USB 3.2
// - 使用 USB-C 接口
// - 支持 DisplayPort 隧道
// - 支持 PCIe 隧道
// - 通过 USB Power Delivery 协商

// tb_switch 对应 USB4 规范中的 USB4 适配器：
struct usb4_switch {
    struct tb_switch       tb;             // 基类（Thunderbolt 交换器）

    // USB4 能力
    u8                      negotiated_version; // 协商的 USB4 版本
    u32                     link_speed;     // 链路速度（10/20/40 Gbps）
    u32                     link_width;     // 链路宽度（x1/x2/x4）
};
```

---

## 4. 菊花链（Daisy Chain）

```
菊花链拓扑：

主机 → 设备1 → 设备2 → 设备3
        ↓         ↓
       显示器    存储

路由路径编码：
- 设备1 route = 0x01（通过端口 1 到达）
- 设备2 route = 0x0102（通过端口 1 → 2 到达）
- 设备3 route = 0x010203（通过端口 1 → 2 → 3 到达）
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/thunderbolt/tb.h` | `struct tb_switch`、`struct tb_port` |
| `drivers/thunderbolt/retimer.c` | Thunderbolt retimer 驱动 |
| `drivers/thunderbolt/switch.c` | switch 配置和枚举 |