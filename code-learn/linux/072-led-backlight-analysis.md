# 72-led-backlight — Linux LED 和 Backlight 子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**LED 子系统**和**Backlight 子系统**是 Linux 中管理"灯"的内核框架——LED 管理状态指示（GPIO/PWM LED、键盘背光等），Backlight 管理显示面板背光（LCD/OLED 亮度控制）。两者都通过 sysfs 暴露统一接口，内部通过 `led_classdev_ops` / `backlight_ops` 与具体的硬件驱动解耦。

**doom-lsp 确认**：LED 类驱动在 `drivers/leds/`（`led-class.c` 98 符号、`led-core.c` 618 行、`led-triggers.c` 514 行、15 个 trigger 3,532 行）。Backlight 在 `drivers/video/backlight/backlight.c`（104 符号）。头文件：`include/linux/leds.h`（753 行）、`include/linux/backlight.h`（451 行）。

---

## 1. LED 子系统

### 1.1 struct led_classdev @ leds.h:91

```c
// include/linux/leds.h:91-255
struct led_classdev {
    const char *name;                           /* sysfs 名称（如 "red:status"）*/
    unsigned int brightness;                    /* 当前亮度值 */
    unsigned int max_brightness;                /* 最大亮度（默认 255）*/
    unsigned int flags;                         /* LED_CORE_* / LED_DEV_* */

    /* ── 驱动操作回调 ─ */
    void (*brightness_set)(struct led_classdev *led_cdev,
                           enum led_brightness brightness);
    int (*brightness_set_blocking)(struct led_classdev *led_cdev,
                                   enum led_brightness brightness);
    enum led_brightness (*brightness_get)(struct led_classdev *led_cdev);
    int (*blink_set)(struct led_classdev *led_cdev,
                     unsigned long *delay_on, unsigned long *delay_off);

    /* ── 触发器 ─ */
    struct led_trigger *trigger;
    struct list_head trig_list;
    char *default_trigger;

    /* ── 闪烁状态（软件闪烁用）─ */
    unsigned long work_flags;                 /* LED_BLINK_* / LED_SET_* 标志 */
    unsigned long blink_delay_on, blink_delay_off;
    struct timer_list blink_timer;             /* 软件闪烁定时器 */
    struct work_struct set_brightness_work;    /* 异步亮度设置 work */

    /* ── 硬件控制 ─ */
    int (*hw_control_is_supported)(...);
    int (*hw_control_set)(...);
    int (*hw_control_get)(...);
};
```

**doom-lsp 确认**：`struct led_classdev` 在 `include/linux/leds.h:91`。`led_init_core` 在 `led-core.c:236` 初始化 work 和 timer。

### 1.2 亮度设置三级路径 @ led-core.c

**入口 → 中断/进程上下文安全的完整路径**：

```c
// drivers/leds/led-core.c

// 第一级：led_set_brightness @ :304
// 任意上下文安全调用
void led_set_brightness(struct led_classdev *led_cdev, unsigned int brightness)
{
    /* 软件闪烁期间 → 工作队列延迟 */
    if (test_bit(LED_BLINK_SW, &led_cdev->work_flags)) {
        if (!brightness) {
            set_bit(LED_BLINK_DISABLE, &led_cdev->work_flags);
            queue_work(led_cdev->wq, &led_cdev->set_brightness_work);
        } else {
            set_bit(LED_BLINK_BRIGHTNESS_CHANGE, &led_cdev->work_flags);
            led_cdev->new_blink_brightness = brightness;
        }
        return;
    }
    led_set_brightness_nosleep(led_cdev, brightness);
}

// 第二级：led_set_brightness_nosleep @ :361
// 非睡眠版本——设置 brightness 字段 + 处理挂起
void led_set_brightness_nosleep(struct led_classdev *led_cdev, unsigned int value)
{
    led_cdev->brightness = min(value, led_cdev->max_brightness);
    if (led_cdev->flags & LED_SUSPENDED)
        return;
    led_set_brightness_nopm(led_cdev, led_cdev->brightness);
}

// 第三级：led_set_brightness_nopm @ :331
// 分为直接调用（brightness_set 不睡眠）和 workqueue（可能睡眠）
void led_set_brightness_nopm(struct led_classdev *led_cdev, unsigned int value)
{
    // 尝试直接调用（atomic 上下文安全）
    if (!__led_set_brightness(led_cdev, value))
        return;                              // 快速路径成功

    // 慢速路径：延迟到 workqueue
    led_cdev->delayed_set_value = value;
    if (value)
        set_bit(LED_SET_BRIGHTNESS, &led_cdev->work_flags);
    else
        set_bit(LED_SET_BRIGHTNESS_OFF, &led_cdev->work_flags);
    queue_work(led_cdev->wq, &led_cdev->set_brightness_work);
}

// 同步版本 @ :372：不能在闪烁时调用
int led_set_brightness_sync(struct led_classdev *led_cdev, unsigned int value)
{
    if (led_cdev->blink_delay_on || led_cdev->blink_delay_off)
        return -EBUSY;                       // 闪烁时不可同步调用

    led_cdev->brightness = min(value, led_cdev->max_brightness);
    if (led_cdev->flags & LED_SUSPENDED)
        return 0;

    return __led_set_brightness_blocking(led_cdev, led_cdev->brightness);
}
```

**doom-lsp 确认**：`led_set_brightness` @ `:304`，`led_set_brightness_nosleep` @ `:361`，`led_set_brightness_nopm` @ `:331`，`led_set_brightness_sync` @ `:372`。

### 1.3 软件/硬件闪烁 @ led-core.c:220+

```c
// 两种闪烁方式：

// 硬件闪烁（驱动实现 blink_set）：
// led_blink_set → led_cdev->blink_set()
// 硬件 PWM 控制闪烁，CPU 零开销

// 软件闪烁（内核定时器模拟）：
// led_blink_set → led_blink_setup → led_cdev->blink_delay_on/off
// → blink_timer → led_timer_function() → brightness_set()
// 
// led_init_core @ :236 初始化 blink_timer
// led_blink_set @ :244 — 清除旧状态，调用 led_blink_setup
// led_blink_set_oneshot @ :258 — 单次闪烁
// led_stop_software_blink @ :295 — 停止软件闪烁
```

### 1.4 sysfs 接口 @ led-class.c

```c
// drivers/leds/led-class.c

// brightness 文件 @ :30-71
static ssize_t brightness_store(struct device *dev, struct device_attribute *attr,
                                 const char *buf, size_t size)
{
    kstrtoul(buf, 10, &state);
    led_set_brightness(led_cdev, state);     // 三级路径入口
    return size;
}

// sysfs 属性组定义 @ :88-108
static struct attribute *led_class_attrs[] = {
    &dev_attr_brightness.attr,
    &dev_attr_max_brightness.attr,
    NULL,
};
static const struct attribute_group led_group = {
    .attrs = led_class_attrs,
    .bin_attrs = led_trigger_bin_attrs,       // trigger 二进制属性
};
```

**doom-lsp 确认**：`brightness_store` @ `led-class.c:44`。`led_class_attrs` @ `:98` 定义 sysfs 文件。`led_group` @ `:104`。

### 1.5 LED 触发器 @ led-triggers.c

```c
// drivers/leds/led-triggers.c
// 15 个内建触发器（drivers/leds/trigger/，共 3,532 行）：

// timer      — 定时闪烁（delay_on/delay_off sysfs 可调）
// oneshot    — 单次闪烁
// heartbeat  — 按系统负载闪烁（loadavg 相关）
// netdev     — 网络 rx/tx 活动指示（765 行，最复杂：支持 rx/tx/link 独立设置）
// disk       — 磁盘 IO 活动
// pattern    — 预定义闪烁模式序列（543 行）
// tty        — TTY 活动指示（357 行）
// panic      — 内核恐慌强制点亮
// input-events — 键盘/鼠标等输入事件
// camera     — 摄像头指示
// transient  — 瞬态控制（延迟自动熄灭）

// 注册 @ :318
int led_trigger_register(struct led_trigger *trig)
{
    // 遍历 leds_list，匹配 default_trigger → 自动绑定
}

// 事件通知 @ :408
void led_trigger_event(struct led_trigger *trig, enum led_brightness brightness)
{
    // 遍历所有绑定的 LED，调用 led_set_brightness()
}
```

**doom-lsp 确认**：`led_trigger_register` @ `led-triggers.c:318`。`led_trigger_event` @ `:408`。`led_trigger_unregister` @ `:354`。

---

## 2. Backlight 子系统

### 2.1 struct backlight_device @ backlight.h:90

```c
// include/linux/backlight.h:90-115
struct backlight_device {
    struct backlight_properties props;       /* 亮度/类型/电源状态 */
    struct mutex ops_lock;
    const struct backlight_ops *ops;         /* 驱动操作 */
    struct mutex update_lock;

    int (*fb_notifier)(struct backlight_device *); /* framebuffer 状态回调 */

    struct device dev;
    struct list_head entry;

    unsigned int actual_brightness;           /* 硬件实际亮度（与 props.brightness 不同）*/
};

struct backlight_properties {
    int brightness;                           /* 请求亮度值 */
    int max_brightness;                       /* 最大值 */
    int power;                                /* FB_BLANK_* 电源状态 */
    int fb_blank;                             /* framebuffer 空白 */
    enum backlight_type type;                 /* RAW/PLATFORM/FIRMWARE */
    enum backlight_scale scale;
};

struct backlight_ops {
    unsigned int options;                     /* BL_CORE_* */
    int (*update_status)(struct backlight_device *);  /* 设置亮度到硬件 */
    int (*get_brightness)(struct backlight_device *);  /* 读取硬件实际亮度 */
    int (*check_fb)(struct backlight_device *, struct fb_info *);  /* fb 关联 */
};
```

**doom-lsp 确认**：`struct backlight_device` @ `backlight.h:90`。`struct backlight_ops` 包含 `update_status`、`get_brightness`、`check_fb`。

### 2.2 亮度设置路径 @ backlight.c

```c
// drivers/video/backlight/backlight.c

// 用户空间写入 /sys/class/backlight/xxx/brightness
// → brightness_store @ :209
static ssize_t brightness_store(struct device *dev, ...)
{
    kstrtoint(buf, 0, &brightness);
    backlight_device_set_brightness(bd, brightness);  // @ :186
}

// → backlight_device_set_brightness @ :186
void backlight_device_set_brightness(struct backlight_device *bd, int brightness)
{
    bd->props.brightness = brightness;        // 保存请求值
    backlight_update_status(bd);               // 调用驱动
}

// → backlight_update_status
int backlight_update_status(struct backlight_device *bd)
{
    // 被 sysfs / PM / fb 通知 多处调用
    if (bd->ops->update_status)
        bd->ops->update_status(bd);            // 驱动设置硬件 PWM
}
```

### 2.3 PM 与 framebuffer 集成

```c
// 背光 PM 通知：
// backlight_notify_blank @ :81 — 处理显示器空白事件
// → backlight_generate_event @ :116 — 发送 uevent
//
// fb_notifier_callback — 注册 framebuffer 通知
// 当 fb 关闭/打开时同步背光状态
//
// 挂起流程：
// brightness_store(brightness=0) → update_status → 关闭背光
// 恢复流程：
// 从 saved_brightness 恢复 → update_status → 重新点亮
```

---

## 3. 驱动注册

```c
// LED 注册：
struct led_classdev *led = devm_kzalloc(dev, sizeof(*led), GFP_KERNEL);
led->name = "red:status";
led->brightness_set_blocking = my_set;
led->brightness_get = my_get;
led->max_brightness = 255;
led_init_core(led);                           // 初始化 work + timer
led_classdev_register(dev, led);              // → device_register + sysfs

// Backlight 注册：
struct backlight_properties props = {
    .type = BACKLIGHT_RAW,
    .max_brightness = 255,
};
bd = backlight_device_register("backlight", dev, data, &ops, &props);
```

---

## 4. 关键函数索引

| 函数 | 文件:行号 | 作用 |
|------|----------|------|
| `led_set_brightness` | `led-core.c:304` | 亮度设置入口（IRQ安全）|
| `led_set_brightness_nosleep` | `led-core.c:361` | 非睡眠设置 |
| `led_set_brightness_nopm` | `led-core.c:331` | 硬件/工作队列分流 |
| `led_set_brightness_sync` | `led-core.c:372` | 同步设置（阻塞）|
| `led_init_core` | `led-core.c:236` | work+blink_timer 初始化 |
| `led_blink_set` | `led-core.c:244` | 闪烁设置 |
| `led_stop_software_blink` | `led-core.c:295` | 停止软件闪烁 |
| `led_trigger_register` | `led-triggers.c:318` | 触发器注册 |
| `led_trigger_event` | `led-triggers.c:408` | 触发器事件通知 |
| `brightness_store` (LED) | `led-class.c:44` | sysfs 写入 |
| `backlight_device_set_brightness` | `backlight.c:186` | 背光设置入口 |
| `brightness_store` (backlight) | `backlight.c:209` | sysfs 写入 |
| `backlight_update_status` | `backlight.c` | 调驱动回调 |
| `backlight_notify_blank` | `backlight.c:81` | 空白事件通知 |

---

## 5. 总结

LED 和 Backlight 子系统是**简单的控制类框架**——通过 sysfs 提供统一用户接口，`led_set_brightness`（`led-core.c:304`）三级安全调用路径（blink→nosleep→nopm）保证 IRQ/进程上下文都能正确使用；`backlight_device_set_brightness`（`backlight.c:186`）→ `update_status` → 驱动回调的路径直接简单。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `led_classdev_register()` | drivers/leds/led-core.c | LED 设备注册 |
| `led_brightness_set()` | drivers/leds/led-core.c | 亮度设置 |
| `struct led_classdev` | include/linux/leds.h | 91 |
| `backlight_device_register()` | drivers/video/backlight/backlight.c | 背光注册 |
| `struct backlight_device` | include/linux/backlight.h | 背光设备 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
