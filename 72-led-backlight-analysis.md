# LED / backlight — 背光与 LED 控制深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/leds/` + `drivers/video/backlight/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**LED** 和 **backlight** 子系统提供统一的亮度和 LED 控制接口。

---

## 1. 核心数据结构

### 1.1 led_classdev — LED 设备

```c
// include/linux/leds.h — led_classdev
struct led_classdev {
    // 名称
    const char              *name;          // /sys/class/leds/<name>
    struct device           *dev;           // 设备
    struct list_head        node;          // 全局 LED 链表

    // 亮度
    unsigned int            brightness;    // 当前亮度（0-MAX）
    unsigned int            max_brightness; // 最大亮度

    // 标志
    enum led_brightness     flags;         // LED_* 标志

    // 延迟
    unsigned long           blink_delay_on;
    unsigned long           blink_delay_off;

    // 触发器
    const char              *trigger;       // 触发器名称（"timer" "nand-disk"）
    struct led_trigger      *trigger;

    // 操作函数
    int                     (*brightness_set)(struct led_classdev *, enum led_brightness);
    int                     (*brightness_set_sync)(struct led_classdev *);
    enum led_brightness     (*brightness_get)(struct led_classdev *);
};
```

### 1.2 led_trigger — 触发器

```c
// include/linux/leds.h — led_trigger
struct led_trigger {
    const char              *name;        // "timer" "nand-disk" "backlight"
    int                     (*activate)(struct led_classdev *);
    int                     (*deactivate)(struct led_classdev *);

    struct list_head        device_list;  // 使用此 trigger 的设备
    struct list_head         list;        // 全局 trigger 链表
};
```

### 1.3 backlight_device — 背光设备

```c
// include/linux/backlight.h — backlight_device
struct backlight_device {
    struct device           dev;           // 设备
    struct backlight_ops    *ops;          // 操作函数

    // 属性
    unsigned int            props.brightness; // 当前亮度
    unsigned int            props.max_brightness; // 最大亮度
    unsigned int            props.power;    // FB_BLANK_* 标志
    unsigned int            props.fb_blank;
    unsigned int            props.update_lock; // 更新锁

    // 统计
    unsigned long           called_fn;     // 更新计数
};
```

---

## 2. sysfs 接口

```
/sys/class/leds/<led>/
├── brightness              ← 当前亮度（读写）
├── max_brightness          ← 最大亮度（只读）
├── trigger                 ← 当前触发器（读写）
├── delay_on                ← blink delay on (ms)
├── delay_off               ← blink delay off (ms)
└── subsystem -> ../../class/leds

/sys/class/backlight/<backlight>/
├── brightness             ← 当前亮度
├── max_brightness         ← 最大亮度
├── actual_brightness      ← 实际亮度
└── power                  ← 电源状态
```

---

## 3. LED 触发器

### 3.1 timer 触发器

```c
// drivers/leds/led-triggers.c — led_timer_activate
static int led_timer_activate(struct led_classdev *led)
{
    // 设置 blink_delay_on/off
    led->blink_delay_on = 500;  // 500ms on
    led->blink_delay_off = 500; // 500ms off

    // 启动定时器
    schedule_delayed_work(&led->blink_work, msecs_to_jiffies(led->blink_delay_on));
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/leds.h` | `struct led_classdev`、`struct led_trigger` |
| `include/linux/backlight.h` | `struct backlight_device` |
| `drivers/leds/led-triggers.c` | `led_timer_activate` |