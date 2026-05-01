# 35-platform-pci-bus — 平台设备/PCI/总线模型深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

Linux 设备模型通过 **platform device** 和 **PCI** 两种主要总线管理硬件设备。platform device 用于不可枚举的设备（SoC 内���），PCI 用于可枚举的外设总线。

---

## 1. 平台设备（Platform Device）

平台设备通过代码直接注册：

```c
struct platform_device {
    const char      *name;          // 设备名（匹配驱动）
    int              id;            // 设备 ID
    struct device    dev;           // 嵌入 struct device
    struct resource *resource;      // IO/中断资源
    unsigned int     num_resources;
};
```

注册流程：
```
platform_device_register(&pdev)
  └─ platform_device_add(pdev)
       ├─ 插入到 platform_bus 类型
       ├─ 注册资源
       └─ device_add(&pdev->dev)
            └─ bus_add_device() → 触发驱动匹配
```

---

*分析工具：doom-lsp（clangd LSP）*
