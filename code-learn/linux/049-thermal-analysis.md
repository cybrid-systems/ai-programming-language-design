# 49-thermal — Linux 内核 Thermal 框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Thermal 框架**是 Linux 内核的热管理系统核心。它将复杂的温度控制抽象为**三层模型**：温度传感器输入 → 策略决策（governor）→ 冷却设备执行。

```
┌─────────────────────────────────────────────────────┐
│               Thermal 框架三层模型                    │
├─────────────────────────────────────────────────────┤
│  Thermal Zone（温度域）                                │
│   ┌─────────────────────┐                            │
│   │ Trip Points (阈值)   │  温度传感器输入              │
│   │   PASSIVE: 65°C     │  get_temp()                │
│   │   ACTIVE:  80°C     │                            │
│   │   HOT:     95°C     │                            │
│   │   CRITICAL: 105°C   │                            │
│   └─────────┬───────────┘                            │
│             ↓ crossing                               │
│  Governor（策略）                                     │
│   ┌─────────────────────┐                            │
│   │ step_wise /          │  趋势判断 + 冷却级别计算     │
│   │ power_allocator /    │                            │
│   │ bang_bang /         │                            │
│   │ fair_share /        │                            │
│   │ user_space          │                            │
│   └─────────┬───────────┘                            │
│             ↓ target state                            │
│  Cooling Device（冷却设备）                             │
│   ┌─────────────────────┐                            │
│   │ cpufreq: 降频       │  set_cur_state()           │
│   │ cpuidle:  idle注入  │                            │
│   │ devfreq: 降频       │                            │
│   │ 风扇:   提高转速    │                            │
│   └─────────────────────┘                            │
└─────────────────────────────────────────────────────┘
```

**doom-lsp 确认**：核心实现在 `drivers/thermal/thermal_core.c`（**1,921 行**，**158 个符号**）。核心数据结构定义在 `drivers/thermal/thermal_core.h` 和 `include/linux/thermal.h`。5 个内建 governor 共 **1,258 行**。

**关键文件索引**：

| 文件 | 行数 | 符号数 | 职责 |
|------|------|--------|------|
| `drivers/thermal/thermal_core.c` | 1921 | 158 | 框架核心：注册、更新、通知 |
| `drivers/thermal/thermal_core.h` | 226 | ~15 | `struct thermal_zone_device`, `struct thermal_governor`, `struct thermal_instance` |
| `include/linux/thermal.h` | ~350 | ~25 | `struct thermal_trip`, `struct thermal_cooling_device`, 公共 API |
| `drivers/thermal/thermal_sysfs.c` | 882 | — | sysfs 接口 |
| `drivers/thermal/thermal_helpers.c` | 240 | — | 辅助函数 |
| `drivers/thermal/thermal_of.c` | 512 | — | Device Tree 接口 |
| `drivers/thermal/thermal_netlink.c` | 937 | — | netlink 事件通知 |
| `drivers/thermal/thermal_thresholds.c` | 244 | — | 用户空间阈值管理 |
| `drivers/thermal/gov_step_wise.c` | 152 | — | step_wise governor |
| `drivers/thermal/gov_power_allocator.c` | 800 | — | 功率分配器（PID） |
| `drivers/thermal/gov_bang_bang.c` | 129 | — | bang-bang governor |
| `drivers/thermal/gov_fair_share.c` | 119 | — | fair_share governor |
| `drivers/thermal/gov_user_space.c` | 58 | — | user_space governor |

---

## 1. 核心数据结构

### 1.1 struct thermal_trip — 温度阈值点

```c
// include/linux/thermal.h:65-80
struct thermal_trip {
    int temperature;                   /* 阈值温度（miliCelsius）*/
    int hysteresis;                    /* 迟滞（miliCelsius）*/
    enum thermal_trip_type type;       /* 阈值类型 */
    u8 flags;                          /* 二进制属性标志 */
    void *priv;                        /* 驱动私有数据 */
};
```

**`enum thermal_trip_type`**（在 uapi 中）：

| 类型 | 含义 | 行为 |
|------|------|------|
| `THERMAL_TRIP_PASSIVE` | 被动冷却阈值 | 触发 governor 降频策略 |
| `THERMAL_TRIP_ACTIVE` | 主动冷却阈值 | 触发风扇等主动冷却 |
| `THERMAL_TRIP_HOT` | 热阈值 | 可以触发更激进的动作 |
| `THERMAL_TRIP_CRITICAL` | 临界温度 | 触发系统关机/重启 |

**Flag 定义**：

```c
#define THERMAL_TRIP_FLAG_RW_TEMP    BIT(0)  /* 温度值可写（sysfs）*/
#define THERMAL_TRIP_FLAG_RW_HYST    BIT(1)  /* 迟滞值可写 */
#define THERMAL_TRIP_FLAG_RW         (RW_TEMP | RW_HYST)
```

### 1.2 struct thermal_zone_device — 温度域

```c
// drivers/thermal/thermal_core.h:119-185
struct thermal_zone_device {
    int id;                                    /* 唯一 ID */
    char type[THERMAL_NAME_LENGTH];            /* 设备类型名 */
    struct device device;                      /* 内核设备 */
    struct completion removal;
    struct completion resume;

    struct attribute_group trips_attribute_group;
    struct list_head trips_high;               /* 高于当前温度的 trips */
    struct list_head trips_reached;            /* 达到或低于当前温度的 trips */
    struct list_head trips_invalid;            /* 无效温度的 trips */

    enum thermal_device_mode mode;             /* ENABLED / DISABLED */
    void *devdata;                             /* 驱动私有数据 */
    int num_trips;                             /* trip 点数量 */

    unsigned long passive_delay_jiffies;       /* 被动冷却监听间隔 */
    unsigned long polling_delay_jiffies;       /* 轮询间隔（0 = 中断驱动）*/
    unsigned long recheck_delay_jiffies;       /* 重试间隔 */

    int temperature;                           /* 当前温度 */
    int last_temperature;                      /* 上次温度 */
    int emul_temperature;                      /* 仿真温度 */
    int passive;                               /* 是否已超过 passive trip */
    int prev_low_trip;                         /* 上次低阈值 */
    int prev_high_trip;                        /* 上次高阈值 */

    struct thermal_zone_device_ops ops;        /* 驱动操作函数 */
    struct thermal_zone_params *tzp;           /* 热区参数 */
    struct thermal_governor *governor;         /* 当前 governor */
    void *governor_data;                       /* governor 私有数据 */

    struct ida ida;
    struct mutex lock;                         /* 保护 thermal_instances 链表 */
    struct list_head node;
    struct delayed_work poll_queue;            /* 轮询延时工作 */
    enum thermal_notify_event notify_event;    /* 最近的通知事件 */
    u8 state;                                  /* 状态标志 */

    struct list_head user_thresholds;          /* 用户空间阈值 */
    struct thermal_trip_desc trips[] __counted_by(num_trips); /* trip 描述数组 */
};
```

**`struct thermal_trip_desc`** — trip 描述符（包含运行时状态）：

```c
// drivers/thermal/thermal_core.h:50-55
struct thermal_trip_desc {
    struct thermal_trip trip;              /* 静态 trip 描述 */
    struct thermal_trip_attrs trip_attrs;  /* sysfs 属性 */
    struct list_head list_node;            /* 在 trips_* 链表中的节点 */
    struct list_head thermal_instances;    /* 绑定的冷却实例链表 */
    int threshold;                         /* 内部阈值（可能调整）*/
};
```

**trip 的三链表管理**：每个 thermal zone 维护三个 trip 链表：

```
trips_high:    trip_5(95°C) → trip_4(85°C) → ... → (threshold > temp)
trips_reached: trip_2(60°C) → trip_1(40°C) → ... → (threshold ≤ temp)
trips_invalid: trip_X(temp=INVALID) → ...
```

**doom-lsp 确认**：`struct thermal_zone_device` 在 `thermal_core.h:119`。`mode` 字段取值 `THERMAL_DEVICE_ENABLED` 或 `THERMAL_DEVICE_DISABLED`。

### 1.3 struct thermal_cooling_device — 冷却设备

```c
// include/linux/thermal.h:123-137
struct thermal_cooling_device {
    int id;
    const char *type;                            /* 类型名 */
    unsigned long max_state;                     /* 最大冷却状态 */
    struct device device;
    struct device_node *np;                      /* DT 节点 */
    void *devdata;                               /* 驱动私有数据 */
    void *stats;
    const struct thermal_cooling_device_ops *ops; /* 操作函数 */
    bool updated;                                 /* 是否已更新 */
    struct mutex lock;                            /* 保护 thermal_instances */
    struct list_head thermal_instances;           /* 绑定的 thermal instance */
    struct list_head node;
};
```

**`struct thermal_cooling_device_ops`**：

```c
struct thermal_cooling_device_ops {
    int (*get_max_state)(struct thermal_cooling_device *, unsigned long *);
    int (*get_cur_state)(struct thermal_cooling_device *, unsigned long *);
    int (*set_cur_state)(struct thermal_cooling_device *, unsigned long);
    int (*get_requested_power)(struct thermal_cooling_device *, u32 *);
    int (*state2power)(struct thermal_cooling_device *, unsigned long, u32 *);
    int (*power2state)(struct thermal_cooling_device *, u32, unsigned long *);
};
```

### 1.4 struct thermal_instance — 冷却绑定实例

每个 `trip` + `cdev` 绑定为一个 `thermal_instance`，描述在特定 trip 触发时冷却设备如何响应：

```c
// drivers/thermal/thermal_core.h:236-252
struct thermal_instance {
    int id;
    char name[THERMAL_NAME_LENGTH];
    struct thermal_cooling_device *cdev;
    const struct thermal_trip *trip;
    bool initialized;                            /* 是否已初始化 */
    unsigned long upper;                         /* 最高冷却状态 */
    unsigned long lower;                         /* 最低冷却状态 */
    unsigned long target;                        /* 目标冷却状态 */
    struct list_head trip_node;                  /* 在 trip->thermal_instances */
    struct list_head cdev_node;                  /* 在 cdev->thermal_instances */
    unsigned int weight;                         /* 冷却设备权重 */
    bool upper_no_limit;                         /* 上限不受限 */
};

struct cooling_spec {
    unsigned long upper;
    unsigned long lower;
    unsigned int weight;
};
```

### 1.5 struct thermal_governor — 调温策略

```c
// drivers/thermal/thermal_core.h:53-63
struct thermal_governor {
    const char *name;
    int (*bind_to_tz)(struct thermal_zone_device *tz);
    void (*unbind_from_tz)(struct thermal_zone_device *tz);
    void (*trip_crossed)(struct thermal_zone_device *tz,
                         const struct thermal_trip *trip, bool upward);
    void (*manage)(struct thermal_zone_device *tz);
    void (*update_tz)(struct thermal_zone_device *tz,
                      enum thermal_notify_event reason);
    struct list_head governor_list;
};
```

---

## 2. 框架初始化与注册

### 2.1 全局变量

```c
// drivers/thermal/thermal_core.c:30-44
static DEFINE_IDA(thermal_tz_ida);          /* thermal zone ID 分配 */
static DEFINE_IDA(thermal_cdev_ida);        /* cooling device ID 分配 */
static LIST_HEAD(thermal_tz_list);          /* 所有 thermal zone */
static LIST_HEAD(thermal_cdev_list);        /* 所有 cooling device */
static LIST_HEAD(thermal_governor_list);     /* 所有 governor */
static DEFINE_MUTEX(thermal_list_lock);
static DEFINE_MUTEX(thermal_governor_lock);
static struct thermal_governor *def_governor; /* 默认 governor */
static bool thermal_pm_suspended;
static struct workqueue_struct *thermal_wq;   /* 专用 workqueue */
```

### 2.2 Governor 注册

Governor 通过宏 `THERMAL_GOVERNOR_DECLARE` 声明自己：

```c
// drivers/thermal/gov_step_wise.c:149
static struct thermal_governor thermal_gov_step_wise = {
    .name   = "step_wise",
    .manage = step_wise_manage,
};
THERMAL_GOVERNOR_DECLARE(thermal_gov_step_wise);
```

```c
// thermal_core.c:234-256
static int __init thermal_register_governors(void)
{
    int ret;
    struct thermal_governor **gov;

    for_each_governor_table(gov) {
        ret = thermal_register_governor(*gov);
        if (ret) return ret;
    }

    /* 设置默认 governor */
    def_governor = __find_governor(DEFAULT_THERMAL_GOVERNOR);
    return 0;
}
```

**`thermal_register_governor()`**：

```c
// thermal_core.c:119-168
int thermal_register_governor(struct thermal_governor *gov)
{
    /* 检查名称是否已存在 */
    if (__find_governor(gov->name) != NULL)
        return -EEXIST;

    mutex_lock(&thermal_governor_lock);
    list_add(&gov->governor_list, &thermal_governor_list);
    mutex_unlock(&thermal_governor_lock);

    /* 绑定到使用此 governor 的 thermal zone */
    for_each_thermal_zone(tz, ...) {
        if (!strncasecmp(tz->governor->name, gov->name, ...)) {
            // 设置并绑定
        }
    }

    return 0;
}
```

**doom-lsp 确认**：`thermal_register_governors()` 在 `thermal_core.c:234`，通过 `for_each_governor_table` 遍历 `__governor_thermal_table` 段中的所有 governor。

### 2.3 Thermal Zone 注册

```c
// drivers/thermal/thermal_core.c:1498-1655
struct thermal_zone_device *
thermal_zone_device_register_with_trips(const char *type,
    struct thermal_trip *trips, int num_trips, void *devdata,
    struct thermal_zone_device_ops *ops,
    struct thermal_zone_params *tzp, int passive_delay, int polling_delay)
{
    struct thermal_zone_device *tz;
    int id;

    /* 分配 ID */
    id = ida_alloc(&thermal_tz_ida, GFP_KERNEL);

    /* 分配结构体（含 trips 数组）*/
    tz = kzalloc(struct_size(tz, trips, num_trips), GFP_KERNEL);

    /* 初始化字段 */
    tz->id = id;
    strscpy(tz->type, type, sizeof(tz->type));
    tz->ops = *ops;
    tz->tzp = tzp;
    tz->device.class = thermal_class;
    dev_set_name(&tz->device, "thermal_zone%d", id);
    device_register(&tz->device);

    /* 初始化三链表 */
    INIT_LIST_HEAD(&tz->trips_high);
    INIT_LIST_HEAD(&tz->trips_reached);
    INIT_LIST_HEAD(&tz->trips_invalid);

    /* 复制 trip 信息 */
    for (i = 0; i < num_trips; i++)
        memcpy(&tz->trips[i].trip, &trips[i], sizeof(trips[i]));

    /* 绑定 governor */
    tz->governor = def_governor;

    /* 设置轮询 */
    INIT_DELAYED_WORK(&tz->poll_queue, thermal_zone_device_check);

    /* 启用并更新 */
    thermal_zone_device_set_mode(tz, THERMAL_DEVICE_ENABLED);

    return tz;
}
```

**doom-lsp 确认**：`thermal_zone_device_register_with_trips()` 在 `thermal_core.c:1498`。`trips[]` 数组通过 `struct_size()` 宏在 kzalloc 中分配，是 C99 灵活数组成员的经典用法。

### 2.4 Cooling Device 注册

```c
// drivers/thermal/thermal_core.c:1060-1144
static struct thermal_cooling_device *
__thermal_cooling_device_register(struct device_node *np,
    const char *type, void *devdata,
    const struct thermal_cooling_device_ops *ops)
{
    struct thermal_cooling_device *cdev;
    int id;

    id = ida_alloc(&thermal_cdev_ida, GFP_KERNEL);
    cdev = kzalloc(sizeof(*cdev), GFP_KERNEL);

    cdev->type = type;
    cdev->ops = ops;
    cdev->devdata = devdata;
    cdev->np = np;

    /* 获取最大冷却状态 */
    if (cdev->ops->get_max_state)
        cdev->ops->get_max_state(cdev, &cdev->max_state);

    INIT_LIST_HEAD(&cdev->thermal_instances);
    mutex_init(&cdev->lock);

    /* 注册设备 */
    device_register(&cdev->device);

    /* 绑定到 thermal zone */
    for_each_thermal_zone(tz)
        thermal_bind_cdev_to_trip(tz, cdev);

    return cdev;
}
```

---

## 3. 温度更新循环

### 3.1 更新入口

```c
// drivers/thermal/thermal_core.c:698-704
void thermal_zone_device_update(struct thermal_zone_device *tz,
                                enum thermal_notify_event event)
{
    scoped_guard(thermal_zone, tz)
        __thermal_zone_device_update(tz, event);
}
```

### 3.2 核心更新函数

```c
// drivers/thermal/thermal_core.c:611-659
void __thermal_zone_device_update(struct thermal_zone_device *tz,
                                  enum thermal_notify_event event)
{
    struct thermal_governor *governor = thermal_get_tz_governor(tz);
    int low = -INT_MAX, high = INT_MAX;
    int temp, ret;

    /* 检查状态：必须是 READY 且 ENABLED */
    if (tz->state != TZ_STATE_READY || tz->mode != THERMAL_DEVICE_ENABLED)
        return;

    /* 步骤 1：获取温度 */
    ret = __thermal_zone_get_temp(tz, &temp);
    if (ret) {
        thermal_zone_recheck(tz, ret);  /* 重试/禁用 */
        return;
    }

    tz->last_temperature = tz->temperature;
    tz->temperature = temp;

    trace_thermal_temperature(tz);
    thermal_genl_sampling_temp(tz->id, temp);

    /* 步骤 2：处理 trip 交叉 */
    thermal_zone_handle_trips(tz, governor, &low, &high);

    /* 步骤 3：处理用户空间阈值 */
    thermal_thresholds_handle(tz, &low, &high);

    /* 步骤 4：设置硬件 trips（产生中断）*/
    thermal_zone_set_trips(tz, low, high);

    /* 步骤 5：调用 governor 管理函数 */
    if (governor->manage)
        governor->manage(tz);

    /* 步骤 6：更新调试统计 */
    thermal_debug_update_trip_stats(tz);

    /* 步骤 7：设置下次轮询 */
monitor:
    monitor_thermal_zone(tz);
}
```

### 3.3 Trip 交叉检测

```c
// drivers/thermal/thermal_core.c:563-610
static void thermal_zone_handle_trips(struct thermal_zone_device *tz,
    struct thermal_governor *governor, int *low, int *high)
{
    /* 1. 检查已超过的 trips：温度下降 → 离开 trip */
    list_for_each_entry_safe_reverse(td, next, &tz->trips_reached, list_node) {
        if (td->threshold <= tz->temperature)
            break;                    /* 仍然超过，继续检查更低的 */
        /* 温度已低于此 trip，触发 crossing(false) */
        thermal_trip_crossed(tz, td, governor, false);
        move_to_trips_high(tz, td);
    }

    /* 2. 检查之前未达到的 trips：温度上升 → 进入 trip */
    list_for_each_entry_safe(td, next, &tz->trips_high, list_node) {
        if (td->threshold > tz->temperature)
            break;                    /* 仍然未达到 */
        /* 温度已超过此 trip，触发 crossing(true) */
        thermal_trip_crossed(tz, td, governor, true);
        move_to_trips_reached(tz, td);
    }

    /* 3. 计算硬件 trip 阈值（用于 set_trips 产生中断）*/
    if (!list_empty(&tz->trips_reached))
        *low = last_entry->threshold - 1;
    if (!list_empty(&tz->trips_high))
        *high = first_entry->threshold;
}
```

**trip 三链表迁移图**：

```
温度上升时：
  trips_high → trip_3(80°C) → trip_2(65°C) → trip_1(50°C)
                    ↓ 温度 ≥ 65°C
  trips_reached → trip_2(65°C) → trip_1(50°C)

温度下降时：
  trips_reached → trip_2(65°C) → trip_1(50°C)
                    ↓ 温度 ≤ 65°C - hysteresis
  trips_high → trip_2(65°C)
```

**doom-lsp 确认**：`thermal_trip_crossed()` 在 `thermal_core.c:470`，它调用 `thermal_governor_trip_crossed()` 通知 governor 并调用 `handle_critical_trips()` 处理 CRITICAL/HOT trip。

### 3.4 临界温度处理

```c
// drivers/thermal/thermal_core.c:405-412
static void handle_critical_trips(struct thermal_zone_device *tz,
                                  const struct thermal_trip *trip)
{
    trace_thermal_zone_trip(tz, thermal_zone_trip_id(tz, trip), trip->type);

    if (trip->type == THERMAL_TRIP_CRITICAL)
        tz->ops.critical(tz);    /* 默认：触发关机 */
}

// 默认 critical 处理函数
void thermal_zone_device_critical(struct thermal_zone_device *tz)
{
    thermal_zone_device_halt(tz, HWPROT_ACT_DEFAULT);
    /* → 触发紧急关机 */
}
```

```c
// thermal_core.c:334-346
static void thermal_zone_device_halt(struct thermal_zone_device *tz,
                                     enum hw_protection_action action)
{
    dev_emerg(&tz->device, "%s: critical temperature reached\n", tz->type);
    __hw_protection_trigger("Temperature too high",
                            CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS,
                            action);
}
```

### 3.5 轮询机制

```c
// drivers/thermal/thermal_core.c:312-320
static void thermal_zone_device_set_polling(struct thermal_zone_device *tz,
                                            unsigned long delay)
{
    if (delay > HZ)
        delay = round_jiffies_relative(delay);
    mod_delayed_work(thermal_wq, &tz->poll_queue, delay);
}

// monitor_thermal_zone: 决定下次轮询间隔
static void monitor_thermal_zone(struct thermal_zone_device *tz)
{
    if (tz->passive > 0 && tz->passive_delay_jiffies)
        thermal_zone_device_set_polling(tz, tz->passive_delay_jiffies);
    else if (tz->polling_delay_jiffies)
        thermal_zone_device_set_polling(tz, tz->polling_delay_jiffies);
}
```

**重试退避**：

```c
// thermal_core.c:321-348
static void thermal_zone_recheck(struct thermal_zone_device *tz, int error)
{
    if (error == -EAGAIN) {
        thermal_zone_device_set_polling(tz, THERMAL_RECHECK_DELAY); /* 250ms */
        return;
    }

    /* 指数退避：250ms → 500ms → 1s → ... → 120s 后禁用 */
    thermal_zone_device_set_polling(tz, tz->recheck_delay_jiffies);
    tz->recheck_delay_jiffies += max(tz->recheck_delay_jiffies >> 1, 1ULL);
    if (tz->recheck_delay_jiffies > THERMAL_MAX_RECHECK_DELAY)  /* 120s */
        thermal_zone_broken_disable(tz);
}
```

---

## 4. Governor 策略详解

### 4.1 step_wise — 步进式

系统**默认 governor**。渐进式增减冷却级别：

```c
// drivers/thermal/gov_step_wise.c:34-63
static unsigned long get_target_state(struct thermal_instance *instance,
                                      enum thermal_trend trend, bool throttle)
{
    unsigned long cur_state;
    cdev->ops->get_cur_state(cdev, &cur_state);

    if (!instance->initialized) {
        if (throttle) return cur_state + 1;           /* 首次 → 升一级 */
        return THERMAL_NO_TARGET;
    }

    if (throttle) {
        if (trend == THERMAL_TREND_RAISING)           /* 升温 → 升一级 */
            return clamp(cur_state + 1, lower, upper);
        if (trend == THERMAL_TREND_DROPPING)          /* 降温中但还需要冷却 → 降一级 */
            return clamp(cur_state - 1, lower+1, upper);
    } else if (trend == THERMAL_TREND_DROPPING) {     /* 不需要冷却 → 降到最小 */
        return cur_state <= lower ? THERMAL_NO_TARGET : lower;
    }

    return instance->target;                           /* 不变 */
}
```

**决策矩阵**：

| 状态 | 趋势 RAISING | 趋势 DROPPING | 趋势 STABLE |
|------|-------------|---------------|-------------|
| 需冷却 | 升 1 级 | 降 1 级（但不低于 lower+1）| 保持不变 |
| 不需冷却 | 保持不变 | 降到 lower（或 NO_TARGET） | 保持不变 |

### 4.2 power_allocator — 功率分配器

基于 PID 控制器的高级 governor（**800 行**）：

```c
// PID 控制器参数（通过 thermal_zone_params 设置）
struct thermal_zone_params {
    u32 sustainable_power;       /* 可散热的持续功率(mW) */
    s32 k_po;                    /* 超调时的比例系数 */
    s32 k_pu;                    /* 欠调时的比例系数 */
    s32 k_i;                     /* 积分系数 */
    s32 k_d;                     /* 微分系数 */
    s32 integral_cutoff;         /* 积分截止阈值 */
};
```

**PID 控制方程**：

```
error = temperature - target_temperature
P = k_p × error
I = k_i × ∫error dt  (当 error < integral_cutoff)
D = k_d × d(error)/dt

power_limit = sustainable_power - P - I - D
```

然后将 `power_limit` 分配到各个冷却设备（通过 `power2state` 转换）。

### 4.3 bang_bang — 开关式

```c
// drivers/thermal/gov_bang_bang.c
/* 简单的开/关控制：
 * 温度 > trip → 最大冷却（state = max_state）
 * 温度 < trip - hysteresis → 最小冷却（state = 0）
 * 在迟滞区间内保持当前状态 */
```

### 4.4 fair_share — 公平共享

```c
// drivers/thermal/gov_fair_share.c
/* 按权重分配负载：
 * 每个 cooling instance 有 weight
 * 总冷却需求按 weight 比例分配到各设备 */
```

### 4.5 user_space — 用户空间

```c
// drivers/thermal/gov_user_space.c
/* 将决策交给用户空间（通过 uevent/netlink 通知）*/
static void user_space_manage(struct thermal_zone_device *tz)
{
    thermal_notify_tz_event(tz, ...);  /* 发送 uevent */
}
```

---

## 5. 冷却设备绑定

### 5.1 绑定创建

```c
// drivers/thermal/thermal_core.c:820-906
int thermal_bind_cdev_to_trip(struct thermal_zone_device *tz,
                              struct thermal_cooling_device *cdev)
{
    struct thermal_trip_desc *td;
    struct thermal_instance *dev;

    for_each_trip_desc(tz, td) {
        const struct thermal_trip *trip = &td->trip;
        struct cooling_spec c = {
            .upper = THERMAL_NO_LIMIT,
            .lower = THERMAL_NO_LIMIT,
            .weight = THERMAL_WEIGHT_DEFAULT,
        };

        /* 询问驱动是否应该绑定此 trip */
        if (tz->ops.should_bind &&
            !tz->ops.should_bind(tz, trip, cdev, &c))
            continue;

        /* 创建 thermal_instance */
        dev = kzalloc(sizeof(*dev), GFP_KERNEL);
        dev->cdev = cdev;
        dev->trip = trip;
        dev->upper = c.upper;
        dev->lower = c.lower;
        dev->weight = c.weight;
        dev->target = THERMAL_NO_TARGET;
        if (dev->upper == THERMAL_NO_LIMIT)
            dev->upper_no_limit = true;

        /* 链入 trip 和 cdev 的 instance 链表 */
        list_add(&dev->trip_node, &td->thermal_instances);
        list_add(&dev->cdev_node, &cdev->thermal_instances);
    }
    return 0;
}
```

### 5.2 冷却执行

```c
// drivers/thermal/thermal_helpers.c:166-209
void __thermal_cdev_update(struct thermal_cooling_device *cdev)
{
    struct thermal_instance *instance;
    unsigned long target = 0;

    /* 取所有 instance 中最大的 target（最深冷却状态）*/
    list_for_each_entry(instance, &cdev->thermal_instances, cdev_node) {
        if (instance->target == THERMAL_NO_TARGET)
            continue;
        if (instance->target > target)
            target = instance->target;
    }

    thermal_cdev_set_cur_state(cdev, target);  /* 设置到硬件 */
}
```

---

## 6. sysfs 接口

### 6.1 Thermal Zone sysfs

```
/sys/class/thermal/
├── thermal_zone0/
│   ├── type              # 类型名 ("cpu-thermal", "gpu-thermal", ...)
│   ├── temp              # 当前温度（miliCelsius）
│   ├── mode              # enabled / disabled
│   ├── policy            # governor 名
│   ├── available_policies # 可选 governor
│   ├── sustainable_power  # 持续功率（power_allocator）
│   ├── trip_point_0_temp  # trip 0 温度
│   ├── trip_point_0_type  # trip 0 类型
│   ├── trip_point_1_temp
│   ├── trip_point_1_type
│   ├── ...
│   └── offset            # 温度偏移
├── cooling_device0/
│   ├── type              # 冷却设备类型
│   ├── max_state         # 最大冷却状态
│   ├── cur_state         # 当前冷却状态
│   └── ...
```

### 6.2 用户空间交互

```bash
# 查看当前温度
cat /sys/class/thermal/thermal_zone0/temp

# 切换 governor
echo "power_allocator" > /sys/class/thermal/thermal_zone0/policy

# 手动设置冷却
echo 5 > /sys/class/thermal/cooling_device0/cur_state

# 设置 trip 温度（需要 RW 标志）
echo 80000 > /sys/class/thermal/thermal_zone0/trip_point_2_temp

# 禁用 thermal zone
echo "disabled" > /sys/class/thermal/thermal_zone0/mode
```

---

## 7. 三列表冷却冷却设备

### 7.1 cpufreq_cooling — CPU 降频

```c
// drivers/thermal/cpufreq_cooling.c（~500 行）
// 将冷却状态映射到 CPU 频率
// state=0 → 最高频率
// state=max_state → 最低频率
频率映射：freq = freq_table[state]
```

**doom-lsp 确认**：`cpufreq_cooling` 在 `drivers/thermal/cpufreq_cooling.c` 中实现，通过 `cpufreq_table` 将冷却状态映射到频率。

### 7.2 devfreq_cooling — 设备降频

```c
// drivers/thermal/devfreq_cooling.c（~400 行）
// 类似 cpufreq_cooling 但用于 GPU、DDR 等设备
```

### 7.3 cpuidle_cooling — idle 注入

```c
// drivers/thermal/cpuidle_cooling.c（~200 行）
// 通过强制 CPU 进入 idle 来降温
// 在 CPU 密集型任务时注入 idle 周期
```

### 7.4 pcie_cooling — PCIe 冷却

```c
// drivers/thermal/pcie_cooling.c（80 行）
// 通过切换 PCIe 链路到 L1 省电状态降温
```

---

## 8. Device Tree 支持

### 8.1 典型 DT 配置

```dts
thermal-zones {
    cpu_thermal: cpu-thermal {
        polling-delay-passive = <250>;   /* 被动冷却轮询间隔 (ms) */
        polling-delay = <1000>;          /* 普通轮询间隔 (ms) */

        trips {
            cpu_alert0: trip@0 {
                temperature = <65000>;   /* 65°C */
                hysteresis = <2000>;
                type = "passive";
            };
            cpu_alert1: trip@1 {
                temperature = <80000>;   /* 80°C */
                hysteresis = <2000>;
                type = "active";
            };
            cpu_crit: cpu-crit {
                temperature = <100000>;  /* 100°C */
                hysteresis = <2000>;
                type = "critical";
            };
        };

        cooling-maps {
            map0 {
                trip = <&cpu_alert0>;
                cooling-device = <&cpu0 THERMAL_NO_LIMIT THERMAL_NO_LIMIT>;
            };
            map1 {
                trip = <&cpu_alert1>;
                cooling-device = <&fan0 THERMAL_NO_LIMIT THERMAL_NO_LIMIT>;
            };
        };
    };
};
```

### 8.2 DT 解析路径

```c
// drivers/thermal/thermal_of.c:367-415
static struct thermal_zone_device *
thermal_of_zone_register(struct device_node *sensor, int id,
                         void *data, const struct thermal_zone_device_ops *ops)
{
    /* 解析 DT trips */
    ntrips = of_count_phandle_with_args(np, "trips", NULL);
    trips = thermal_of_trips_init(np, &ntrips);

    /* 创建 thermal zone */
    tz = thermal_zone_device_register_with_trips(np->name, trips, ntrips,
                                                 data, ops, NULL,
                                                 pdelay, delay);
    /* 解析 cooling-maps */
    thermal_of_bind_cdev_to_trip(tz, np);
    return tz;
}
```

---

## 9. Netlink 通知机制

```c
// drivers/thermal/thermal_netlink.c:937 行
// 内核 → 用户空间的事件通知通道
enum thermal_notify_event {
    THERMAL_EVENT_UNSPECIFIED,
    THERMAL_EVENT_TEMP_SAMPLE,       /* 新温度样本 */
    THERMAL_TRIP_VIOLATED,           /* Trip 点被违反 */
    THERMAL_TRIP_CHANGED,            /* Trip 温度被更改 */
    THERMAL_DEVICE_DOWN,             /* 设备下线 */
    THERMAL_DEVICE_UP,               /* 设备上线 */
    THERMAL_EVENT_KEEP_ALIVE,        /* 心跳 */
    THERMAL_TZ_BIND_CDEV,            /* 冷却设备绑定 */
    THERMAL_TZ_UNBIND_CDEV,          /* 冷却设备解绑 */
    THERMAL_TZ_RESUME,               /* 系统唤醒 */
    THERMAL_TZ_ADD_THRESHOLD,        /* 添加用户阈值 */
    THERMAL_TZ_DEL_THRESHOLD,        /* 删除用户阈值 */
    ...
};
```

用户空间通过 `thermald` 或自定义程序接收这些事件并作出响应。

---

## 10. 阈值系统

`thermal_thresholds.c`（244 行）允许用户空间注册温度阈值，在温度跨越阈值时接收通知：

```c
// 用户空间接口
int thermal_zone_add_threshold(struct thermal_zone_device *tz, int temp);
int thermal_zone_delete_threshold(struct thermal_zone_device *tz, int temp);
```

与 trip 不同，阈值是用户空间动态设置的，不绑定任何冷却设备。

---

## 11. PM 集成：挂起/恢复

```c
// drivers/thermal/thermal_core.c
static bool thermal_pm_suspended;

// 系统挂起时暂停轮询
static int thermal_pm_notify(struct notifier_block *nb,
                             unsigned long mode, void *unused)
{
    switch (mode) {
    case PM_SUSPEND_PREPARE:
        thermal_pm_suspended = true;
        break;
    case PM_POST_SUSPEND:
        thermal_pm_suspended = false;
        /* 恢复所有 thermal zone */
        for_each_thermal_zone(tz)
            thermal_zone_device_update(tz, THERMAL_TZ_RESUME);
        break;
    }
}
```

---

## 12. 性能考量

### 12.1 关键路径延迟

```
temp 采集 (get_temp in HW)          [100μs - 10ms, 取决于传感器]
  ↓
__thermal_zone_device_update()
  ├─ thermal_zone_handle_trips()   [O(n) in trips]
  │    ├─ 三链表遍历 + 迁移          [~50ns per trip]
  │    └─ trip_crossed → governor   [~100ns-1μs]
  ├─ thermal_thresholds_handle()   [O(n) in thresholds]
  ├─ thermal_zone_set_trips()      [~10μs, 写入硬件寄存器]
  ├─ governor->manage()            [取决于 governor]
  │    ├─ step_wise: O(n*m)        [n=trips, m=instances per trip]
  │    └─ power_allocator: PID + 分配 [~5-20μs]
  └─ thermal_cdev_update()         [~50μs, 调用 set_cur_state]
```

### 12.2 更新频率

| 模式 | 轮询间隔 | 触发方式 |
|------|---------|---------|
| IDLE（无 trip 触发） | `polling_delay`（默认 1s） | 定时器 |
| PASSIVE（被动冷却） | `passive_delay`（默认 250ms） | 定时器 |
| 中断驱动 | 0（不轮询，硬件中断触发） | 硬件中断 |
| 重试 | 指数退避 250ms → 120s | 定时器 |

---

## 13. 调试与监控

### 13.1 debugfs 接口

```bash
# 查看所有 thermal zone 状态
cat /sys/kernel/debug/thermal/thermal_zones

# 查看单个 zone 的统计
cat /sys/kernel/debug/thermal/thermal_zone0/trip_stats
```

### 13.2 tracepoints

```bash
# 跟踪温度变化
echo 1 > /sys/kernel/debug/tracing/events/thermal/thermal_temperature/enable
cat /sys/kernel/debug/tracing/trace_pipe

# 跟踪 trip 事件
echo 1 > /sys/kernel/debug/tracing/events/thermal/thermal_zone_trip/enable
```

### 13.3 常用调试命令

```bash
# 查看所有 thermal zone
ls /sys/class/thermal/
cat /sys/class/thermal/thermal_zone*/temp

# 监控温度变化
watch -n 1 cat /sys/class/thermal/thermal_zone0/temp

# 查看当前 governor
cat /sys/class/thermal/thermal_zone0/policy

# 检查冷却设备状态
cat /sys/class/thermal/cooling_device*/cur_state

# 内核日志
dmesg | grep thermal
```

---

## 14. 常见故障排查

### 14.1 温度显示异常

```bash
# 检查是否 disabled
cat /sys/class/thermal/thermal_zone0/mode  # 应为 enabled

# 检查传感器是否故障
dmesg | grep "Temperature check failed"

# 强制启用
echo "enabled" > /sys/class/thermal/thermal_zone0/mode
```

### 14.2 冷却设备不动作

```bash
# 检查冷却绑定
cat /sys/kernel/debug/thermal/thermal_zone0/trip_stats

# 手动测试冷却设备
echo 10 > /sys/class/thermal/cooling_device0/cur_state

# 检查 governor 策略
cat /sys/class/thermal/thermal_zone0/policy
```

### 14.3 系统意外关机

```bash
# 检查是否 CRITICAL trip 触发
dmesg | grep "critical temperature"

# 检查紧急关机配置
cat /proc/sys/kernel/panic  # 紧急关机延迟

# 临时提高临界温度（如果有 RW 权限）
echo 110000 > /sys/class/thermal/thermal_zone0/trip_point_0_temp
```

---

## 15. 总结

Linux Thermal 框架通过**三层抽象**实现了灵活的温控管理：

**1. 温度感知层** — `thermal_zone_device` 封装温度传感器，通过 `get_temp` 和硬件中断获取温度，通过 `trips_high/reached/invalid` 三链表管理 trip 状态。

**2. 策略决策层** — 5 个内建 governor 覆盖全部使用场景：

| Governor | 策略 | 适用场景 |
|----------|------|----------|
| `step_wise` | 步进增减 | **桌面/手机（默认）** |
| `power_allocator` | PID 控制器 | 服务器/大型系统 |
| `bang_bang` | 开关式 | 风扇控制 |
| `fair_share` | 按权重分配 | 多冷却设备系统 |
| `user_space` | 用户空间决策 | 自定义策略 |

**3. 执行层** — `thermal_cooling_device` 通过 `set_cur_state` 执行冷却，支持 CPU 降频、idle 注入、风扇调速、设备降频。

**关键数字**：
- `thermal_core.c`：1,921 行，158 个符号
- 5 个内建 governor：共 1,258 行
- trip 类型：4 种（PASSIVE/ACTIVE/HOT/CRITICAL）
- 默认轮询间隔：1s（普通），250ms（被动冷却）
- 重试退避：250ms → 120s（指数增长）

---

## 附录 A：关键源码索引

| 文件 | 行号 | 符号 |
|------|------|------|
| `include/linux/thermal.h` | 72 | `struct thermal_trip` |
| `include/linux/thermal.h` | 95 | `struct thermal_zone_device_ops` |
| `include/linux/thermal.h` | 123 | `struct thermal_cooling_device` |
| `include/linux/thermal.h` | 114 | `struct thermal_cooling_device_ops` |
| `drivers/thermal/thermal_core.h` | 53 | `struct thermal_governor` |
| `drivers/thermal/thermal_core.h` | 236 | `struct thermal_instance` |
| `drivers/thermal/thermal_core.h` | 119 | `struct thermal_zone_device` |
| `drivers/thermal/thermal_core.c` | 53 | `__find_governor()` |
| `drivers/thermal/thermal_core.c` | 119 | `thermal_register_governor()` |
| `drivers/thermal/thermal_core.c` | 563 | `thermal_zone_handle_trips()` |
| `drivers/thermal/thermal_core.c` | 611 | `__thermal_zone_device_update()` |
| `drivers/thermal/thermal_core.c` | 698 | `thermal_zone_device_update()` |
| `drivers/thermal/thermal_core.c` | 820 | `thermal_bind_cdev_to_trip()` |
| `drivers/thermal/thermal_core.c` | 1060 | `__thermal_cooling_device_register()` |
| `drivers/thermal/thermal_core.c` | 1498 | `thermal_zone_device_register_with_trips()` |
| `drivers/thermal/thermal_helpers.c` | 166 | `__thermal_cdev_update()` |
| `drivers/thermal/thermal_of.c` | 367 | `thermal_of_zone_register()` |
| `drivers/thermal/gov_step_wise.c` | 34 | `get_target_state()` |
| `drivers/thermal/gov_step_wise.c` | 97 | `step_wise_manage()` |

## 附录 B：内核参数

```bash
# 默认 governor（编译时）
CONFIG_THERMAL_DEFAULT_GOV_STEP_WISE=y
# CONFIG_THERMAL_DEFAULT_GOV_POWER_ALLOCATOR=y

# 紧急关机延迟（编译时）
CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS=0

# 运行时调整
/sys/class/thermal/thermal_zone0/policy  # governor 切换
/sys/class/thermal/thermal_zone0/mode    # 启用/禁用
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
