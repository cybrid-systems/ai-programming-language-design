# Linux Kernel LED / Backlight 子系统 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/leds/` + `drivers/video/backlight/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. LED 子系统

**LED** 子系统统一管理 LED 设备（键盘背光、充电指示灯等）。

---

## 1. 核心结构

```c
// drivers/leds/led-core.c — led_classdev
struct led_classdev {
    const char       *name;           // LED 名字（"red: Charging"）
    enum led_brightness brightness;    // 当前亮度（0-255）
    enum led_brightness max_brightness;
    int (*brightness_set)(struct led_classdev *, enum led_brightness);
    int (*brightness_set_sync)(struct led_classdev *, enum led_brightness);
    struct device   *dev;
};
```

---

## 2. Backlight

```c
// drivers/video/backlight/backlight.c — backlight_device
struct backlight_device {
    struct generic_device gen;
    int                props.brightness;   // 亮度
    int                props.max_brightness;
    struct backlight_ops *ops;
};
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/leds/led-core.c` | LED 核心 |
| `drivers/video/backlight/backlight.c` | Backlight 核心 |
