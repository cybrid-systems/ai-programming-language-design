# Linux Kernel Thunderbolt 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/thunderbolt/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. Thunderbolt 概述

**Thunderbolt** 是 Intel 的高速外设互联协议（PCIe + DisplayPort 隧道），支持：
- 40 Gbps 带宽（Thunderbolt 3）
- PCIe 直通（外接 GPU、NVMe SSD）
- DisplayPort 显示输出
- Daisy-chain（菊花链）

---

## 1. 核心结构

```c
// drivers/thunderbolt/domain.h — tb_domaint
struct tb_domaint {
    struct tb_nhi           *nhi;          // 主机控制器
    struct tb_port          *port;         // 端口
    int                     is_unplugged;  // 是否拔出
    struct work_struct      work;          // 事件处理
    spinlock_t              lock;
};
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `drivers/thunderbolt/ctl.c` | 协议控制层 |
| `drivers/thunderbolt/nhi.c` | 主机控制器接口 |
