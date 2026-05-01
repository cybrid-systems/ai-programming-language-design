# 59-device-mapper — 设备映射器深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**Device Mapper** 提供将物理块设备映射到虚拟块设备的框架。LVM2 的逻辑卷、dm-crypt、dm-verity、dm-raid 等都基于此。

---

## 1. 核心架构

```
  虚拟设备（/dev/dm-X）
      │
   ┌──┴──┐
   │  DM │  mapped_device（虚拟块设备）
   └──┬──┘
      │
   ┌──┴──┐
   │target│  dm_target（映射目标）
   └─────┘
      │
   ┌──┴──┐
   │  物理 │  底层块设备（/dev/sda 等）
   └─────┘
```

---

*分析工具：doom-lsp（clangd LSP）*
