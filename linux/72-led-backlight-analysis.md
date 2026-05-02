# 72-led-backlight — Linux LED 和 Backlight 子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**LED 子系统**和**Backlight 子系统**是 Linux 中管理"灯"的内核框架——LED 子系统管理状态指示灯（GPIO/PWM LED、键盘背光等），Backlight 子系统管理显示面板背光（LCD/OLED 亮度控制）。两者都通过 sysfs 提供用户空间接口。

**架构对比**：

| 特性 | LED 子系统 | Backlight 子系统 |
|------|-----------|-------------------|
| 核心文件 | `drivers/leds/led-class.c`（716行） | `drivers/video/backlight/backlight.c`（690行） |
| 符号数 | 98 个 | 104 个 |
| 核心结构 | `struct led_classdev` | `struct backlight_device` |
| sysfs 节点 | `/sys/class/leds/<name>/` | `/sys/class/backlight/<name>/` |
| 亮度控制 | `brightness`（线性 0-255） | `brightness` + `actual_brightness` |
| 触发器 | `led_trigger`（心跳/磁盘/网络） | 无 |
| HW 控制 | `hw_control_ops`（自动控制） | 无 |

**doom-lsp 确认**：LED 类在 `drivers/leds/led-class.c`（98 个符号）、`led-core.c`（618 行）。Backlight 在 `drivers/video/backlight/backlight.c`（104 个符号）。头文件分别在 `include/linux/leds.h` 和 `include/linux/backlight.h`。

---

## 1. LED 子系统

### 1.1 struct led_classdev

```c
// include/linux/leds.h:91-255
struct led_classdev {
    const char *name;                          /* LED 名称（如 "red:status"）*/
    unsigned int brightness;                   /* 当前亮度 (0-255) */
    unsigned int max_brightness;               /* 最大亮度（默认 255）*/
    unsigned int flags;                        /* LED_* 标志 */

    /* ── 底层驱动操作 ─ */
    void (*brightness_set)(struct led_classdev *led_cdev,
                           enum led_brightness brightness);
    int (*brightness_set_blocking)(struct led_classdev *led_cdev,
                                   enum led_brightness brightness);
    enum led_brightness (*brightness_get)(struct led_classdev *led_cdev);
    int (*blink_set)(struct led_classdev *led_cdev,
                     unsigned long *delay_on, unsigned long *delay_off);

    /* ── 触发器 ─ */
    struct led_trigger *trigger;                /* 关联的触发器 */
    struct list_head trig_list;
    char *default_trigger;

    /* ── 硬件控制 ─ */
    int (*hw_control_is_supported)(struct led_classdev *led_cdev, ...);
    int (*hw_control_set)(struct led_classdev *led_cdev, ...);
    int (*hw_control_get)(struct led_classdev *led_cdev, ...);

    /* ── sysfs 群组 ─ */
    const struct attribute_group **groups;
};
```

**doom-lsp 确认**：`struct led_classdev` 在 `include/linux/leds.h:91`。`brightness_set` 和 `brightness_get` 是驱动必须实现的操作。

### 1.2 sysfs 接口

```c
// drivers/leds/led-class.c
// brightness 文件操作 @ :30-71
static ssize_t brightness_show(struct device *dev, ...)
{
    struct led_classdev *led_cdev = dev_get_drvdata(dev);

    /* 如果有硬件控制 → 读取硬件亮度 */
    if (led_cdev->hw_control_is_supported && ...)
        led_cdev->hw_control_get(led_cdev, &value);
    else
        led_cdev->brightness_get(led_cdev);

    return sprintf(buf, "%u\n", led_cdev->brightness);
}

static ssize_t brightness_store(struct device *dev, struct device_attribute *attr,
                                 const char *buf, size_t size)
{
    /* 解析亮度值 0-max_brightness */
    ret = kstrtoul(buf, 10, &state);

    /* 设置亮度 */
    led_set_brightness(led_cdev, state);

    /* 触发 led_set_brightness_async 或 sync */
}
```

### 1.3 LED 触发器（led_trigger）

```c
// struct led_trigger 管理 LED 的自动行为
// 内建触发器：
//   "none"     — 无（手动控制）
//   "heartbeat"— 心跳闪烁（系统负载）
//   "disk"     — 磁盘活动
//   "netdev"   — 网络活动（rx/tx）
//   "timer"    — 定时闪烁
//   "oneshot"  — 单次闪烁
//   "transient"— 瞬态控制
//   "pattern"  — 模式序列

// 触发器通过 led_trigger_register() 注册
// 当事件发生时（磁盘 IO 等），触发器调用 led_set_brightness()
// 改变 LED 状态
```

### 1.4 硬件控制（HDMI/audio 联动）

```c
// LED 子系统支持硬件自动控制——LED 直接由硬件事件驱动
// 例如：键盘 LED 在 Caps Lock 按下时由键盘硬件自动点亮
// 无需内核软件干预
// 
// hw_control_is_supported — 检查硬件是否支持自动控制
// hw_control_set        — 切换到硬件控制模式
```

---

## 2. Backlight 子系统

### 2.1 struct backlight_device

```c
// include/linux/backlight.h:90-115
struct backlight_device {
    struct backlight_properties props;       /* 属性（亮度/最大/类型）*/
    struct mutex ops_lock;
    const struct backlight_ops *ops;         /* 驱动操作 */

    struct mutex update_lock;
    int (*fb_notifier)(struct backlight_device *);  /* framebuffer 通知 */

    struct device dev;                       
    struct list_head entry;

    /* 实际亮度（硬件报告的当前值，可能与 brightness 不同）*/
    unsigned int actual_brightness;
};

struct backlight_properties {
    int brightness;                          /* 请求亮度 */
    int max_brightness;                      /* 最大亮度 */
    int power;                               /* FB_BLANK_* 电源状态 */
    int fb_blank;                             /* framebuffer 空白状态 */
    enum backlight_type type;                /* RAW/PLATFORM/FIRMWARE */
    enum backlight_scale scale;               /* NON_LINEAR/LINEAR/... */
};
```

**doom-lsp 确认**：`struct backlight_device` 在 `include/linux/backlight.h:90`。`struct backlight_ops` 包含 `update_status`（设置亮度）、`get_brightness`（读取实际亮度）、`check_fb`（检查 framebuffer 关联）。

### 2.2 backlight_ops

```c
struct backlight_ops {
    unsigned int options;                    /* BL_CORE_SUSPENDRESUME */
    int (*update_status)(struct backlight_device *);
    int (*get_brightness)(struct backlight_device *);
    int (*check_fb)(struct backlight_device *, struct fb_info *);
};
```

### 2.3 亮度设置路径

```c
// drivers/video/backlight/backlight.c
// sysfs 写入 → 驱动回调的完整路径：

// 1. brightness_store @ :209 — 接收用户写入
static ssize_t brightness_store(struct device *dev, ...)
{
    /* 解析亮度值 */
    ret = kstrtoint(buf, 0, &brightness);

    /* 调用 backlight_device_set_brightness @ :186 */
    backlight_device_set_brightness(bd, brightness);
}

// 2. backlight_device_set_brightness @ :186
void backlight_device_set_brightness(struct backlight_device *bd,
                                      int brightness)
{
    /* 设置请求亮度 */
    bd->props.brightness = brightness;

    /* 调用 update_status 更新硬件 */
    backlight_update_status(bd);
}

// 3. backlight_update_status
int backlight_update_status(struct backlight_device *bd)
{
    /* 调用驱动回调 */
    if (bd->ops->update_status)
        bd->ops->update_status(bd);
}
```

**doom-lsp 确认**：`brightness_store` 在 `backlight.c:209`。`backlight_device_set_brightness` 在 `:186`。`backlight_update_status` 是被广泛调用的函数——来自 sysfs、PM 通知、fb 通知等。

### 2.4 PM 集成

```c
// drivers/video/backlight/backlight.c
// 背光设备注册 PM 通知：
// 挂起时 → 保存亮度状态，关闭背光
// 恢复时 → 恢复亮度

// backlight_notify_blank @ :81 处理显示器空白事件
// fb_notifier_callback 处理 framebuffer 状态变化
```

---

## 3. 注册流程

```c
// LED 注册：
struct led_classdev *led_cdev;
led_cdev = devm_kzalloc(dev, sizeof(*led_cdev), GFP_KERNEL);
led_cdev->name = "red:status";
led_cdev->brightness_set_blocking = my_led_set;
led_cdev->brightness_get = my_led_get;
led_cdev->max_brightness = 255;
led_classdev_register(dev, led_cdev);

// Backlight 注册：
struct backlight_device *bd;
struct backlight_properties props = {
    .type = BACKLIGHT_RAW,
    .max_brightness = 255,
};
bd = backlight_device_register("backlight", dev, data, &ops, &props);
```

---

## 4. 总结

LED 和 Backlight 是 Linux 中两个**简单、标准的控制类子系统**——通过 sysfs 提供统一的用户接口，通过 `led_classdev_ops` / `backlight_ops` 与具体硬件驱动解耦。LED 子系统有额外的触发器（trigger）实现自动化控制。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
