# 199-pinctrl_gpio — 引脚控制与GPIO深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/pinctrl/` + `drivers/gpio/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**pinctrl** 管理 SoC 的引脚复用（pinmux），**GPIO** 是通用输入输出。两者配合实现外设引脚配置。

---

## 1. pinctrl

```c
// drivers/pinctrl/core.c — pinctrl 子系统
// 将引脚分配给特定功能（UART、SPI、I2C等）

// 引脚状态：
//   pinctrl-names = "default", "sleep"
//   default：正常使用
//   sleep：低功耗模式
```

---

## 2. GPIO

```c
// drivers/gpio/gpiolib.c — GPIO 子系统
// 用户接口：
//   /sys/class/gpio/
//   gpiochipN — GPIO 控制器

// 操作：
//   echo 23 > /sys/class/gpio/export
//   echo out > /sys/class/gpio/gpio23/direction
//   echo 1 > /sys/class/gpio/gpio23/value
```

---

## 3. 西游记类喻

**pinctrl + GPIO** 就像"天庭的引脚分配和开关"——

> pinctrl 像天庭的引脚分配委员会，把引脚分配给各个功能（UART 收讯、I2C 总线等）。GPIO 则像每个引脚上的开关，可以读也可以写。两者配合：先分配（pinctrl），再使用（GPIO）。

---

## 4. 关联文章

- **I2C/SPI**（article 128）：I2C/SPI 驱动使用 pinctrl
- **device model**（相关）：pinctrl 是 platform bus 的一部分