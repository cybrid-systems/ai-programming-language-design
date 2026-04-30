# Thunderbolt — 高速外设总线深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/thunderbolt/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Thunderbolt** 是 Intel/Apple 开发的高速点对点协议（40Gbps），支持 PCIe 和 DisplayPort 数据隧道。

---

## 1. 核心数据结构

```c
// drivers/thunderbolt/tb.h — tb_switch
struct tb_switch {
    struct device           dev;           // 设备
    struct tb_port         *ports;        // 端口数组
    unsigned int           port_count;     // 端口数

    // 路由
    u64                    route;         // 路由路径
    u8                     depth;         // 拓扑深度

    // USB4
    u8                      cap_plug_events; // 即插即用事件能力
};
```

---

## 2. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/thunderbolt/tb.h` | `tb_switch` |