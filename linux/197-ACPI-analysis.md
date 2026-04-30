# 197-ACPI — ACPI固件接口深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/acpi/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**ACPI（Advanced Configuration and Power Interface）** 是 x86 的固件接口，提供 S0-S5 电源状态、DSDT 表解析、热管理等。

---

## 1. ACPI 表

```
ACPI 表：
  RSDP — Root System Description Pointer（表指针入口）
  RSDT/XSDT — Root System Description Table
  DSDT — Differentiated System Description Table（系统基本定义）
  SSDT — Secondary System Description Table（附加定义）
  MADT — Multiple APIC Description Table（APIC 配置）
  HPET — High Precision Event Timer
  MCFG — PCI Express Memory Mapped Config
```

---

## 2. ACPICA

```c
// drivers/acpi/acpica/ — ACPICA 子系统
// 解析 AML（ACPI Machine Language）代码

// DSDT 表中的对象：
Method(_STA) // 设备状态
Method(_INI) // 初始化
Method(_CRS) // 当前资源
Name(_HID, "PNP0000") // 硬件 ID
```

---

## 3. 西游记类喻

**ACPI** 就像"天庭的建筑规划图"——

> ACPI 像天庭的建筑规划图，告诉内核哪里有什么设施（设备）、每个设施怎么开关（电源管理）、有没有紧急通道（SCI 中断）。内核通过读这张图来管理整个天庭的电力和设备。

---

## 4. 关联文章

- **S3/S5**（相关）：ACPI 电源状态