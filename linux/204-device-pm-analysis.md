# 204-device_pm — 设备电源管理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/base/power/*.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Device PM** 包括 Runtime PM（运行时电源管理）和 System PM（系统睡眠：suspend/hibernate）。

---

## 1. Runtime PM

```c
// 设备运行时电源管理：
pm_runtime_get(dev);    // 增加引用计数
pm_runtime_put(dev);    // 减少引用计数
pm_runtime_suspend(dev); // 设备空闲时休眠
pm_runtime_resume(dev);  // 唤醒
```

---

## 2. System PM

```
系统睡眠状态：
  S0 — 工作
  S1 — 浅睡
  S3 — 挂起到 RAM（hibernation）
  S4 — 挂起到磁盘（suspend to disk）
  S5 — 软关机
```

---

## 3. 西游记类喻

**Device PM** 就像"天庭的节能模式"——

> Runtime PM 像每个神仙（设备）自己决定要不要休息。系统 PM 像天庭统一休息——全体同时进入低功耗状态，但保留 RAM 里的记忆（suspend to RAM）。

---

## 4. 关联文章

- **ACPI**（article 197）：ACPI 定义 S0-S5 状态
- **runtime PM**（相关）：设备级节能