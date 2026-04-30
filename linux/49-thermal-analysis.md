# thermal / cooling — 散热管理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/thermal/thermal_core.c` + `include/linux/thermal.h`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Thermal** 管理 CPU/SoC 温度，防止过热。核心概念：
- **thermal zone**：温度传感器（描述温度状态）
- **cooling device**：散热设备（CPUfreq/风扇/背光）
- **trip point**：触发阈值（超过温度后触发降温）

---

## 1. 核心数据结构

### 1.1 thermal_zone_device — 热区

```c
// drivers/thermal/thermal_core.h — thermal_zone_device
struct thermal_zone_device {
    const char              *type;         // "cpu-thermal" 等
    struct device           *device;       // sysfs 设备
    int                     id;            // 编号

    // 温度状态
    int                     temperature;    // 当前温度（毫摄氏度）
    enum thermal_trend       trend;        // 趋势（上升/下降/稳定）
    struct thermal_zone_device_ops *ops;   // 操作函数表

    // 阈值
    struct thermal_trip_desc trips[THERMAL_MAX_TRIPS]; // 阈值数组
    int                     num_trips;      // 阈值数量

    // 绑定
    struct thermal_binding_desc *binding;   // 绑定关系

    // 冷却设备
    struct cooling_device   *cdevs[THERMAL_MAX_COOLING_DEVICES]; // 冷却设备列表
    int                     num_cdevs;       // 冷却设备数量

    // Governor
    struct thermal_governor *governor;     // 热管理策略
    void                    *governor_data; // Governor 特定数据
};
```

### 1.2 thermal_trip_desc — 阈值描述

```c
// drivers/thermal/thermal_core.h — thermal_trip_desc
struct thermal_trip_desc {
    struct thermal_trip      trip;         // 阈值点
    int                     threshold;     // 阈值温度
    enum trip_type           type;         // 阈值类型
    struct thermal_instance  *instances;    // 绑定实例
};
```

### 1.3 cooling_device — 冷却设备

```c
// include/linux/thermal.h — cooling_device
struct cooling_device {
    struct device           *device;       // sysfs 设备
    int                     id;            // 编号
    enum thermal_cdev_type   type;        // 类型（CPUFREQ/FRNP/FAN）
    unsigned long           max_state;     // 最大状态
    unsigned long           cur_state;     // 当前状态
    struct thermal_cooling_device_ops *ops; // 操作函数表
};
```

---

## 2. 温度更新流程

### 2.1 thermal_zone_temp_update

```c
// drivers/thermal/thermal_core.c — thermal_zone_temp_update
static void thermal_zone_temp_update(struct thermal_zone_device *tz, bool delay)
{
    int temp, delta, count = 0;

    // 1. 读取温度
    temp = thermal_zone_get_temp(tz);

    // 2. 计算趋势
    delta = temp - tz->last_temperature;
    tz->trend = (delta > 0) ? THERMAL_TREND_RAISING : THERMAL_TREND_DROPPING;

    // 3. 检查每个 trip 点
    for (i = 0; i < tz->num_trips; i++) {
        struct thermal_trip_desc *trip = &tz->trips[i];

        if (temp > trip->threshold) {
            // 超过阈值，触发 cooling
            thermal_zone_cdev_update(tz, i);
        }
    }

    tz->last_temperature = temp;

    // 4. 如果温度上升太快，触发紧急措施
    if (delta > THERMAL_EMERGENCY_THRESHOLD)
        thermal_emergency_power_off(tz);
}
```

### 2.2 thermal_zone_cdev_update — 调用冷却设备

```c
// drivers/thermal/thermal_core.c — thermal_zone_cdev_update
static void thermal_zone_cdev_update(struct thermal_zone_device *tz, int trip_index)
{
    struct thermal_cooling_device *cdev;
    unsigned long state;
    int ret;

    // 遍历所有绑定的 cooling device
    for (i = 0; i < tz->num_cdevs; i++) {
        cdev = tz->cdevs[i];

        // 从 governor 获取目标状态
        ret = tz->governor->bind_cdev(cdev, trip_index, &state);
        if (ret < 0)
            continue;

        // 调用 cooling device 的 set_cur_state
        if (cdev->ops && cdev->ops->set_cur_state)
            cdev->ops->set_cur_state(cdev->dev, state);
    }
}
```

---

## 3. Governor

```c
// drivers/thermal/thermal_core.c — thermal_governor
struct thermal_governor {
    const char              *name;         // "step_wise" "fair_share" "power_allocator"
    int                     (*bind_cdev)(struct cooling_device *, int, unsigned long *);
    int                     (*unbind_cdev)(struct cooling_device *);
    int                     (*update_tz)(struct thermal_zone_device *, int);
    struct list_head        list;          // 链表
};
```

### 3.1 step_wise governor

```c
// drivers/thermal/step_wise.c — step_wise_bind_cdev
static int step_wise_bind_cdev(struct thermal_cooling_device *cdev,
                              int trip, unsigned long *state)
{
    struct thermal_zone_device *tz = cdev->tz;
    enum thermal_trend trend = tz->trend;

    // 趋势上升 → 提高冷却状态
    // 趋势下降 → 降低冷却状态
    if (trend == THERMAL_TREND_RAISING)
        *state = min(*state + 1, cdev->max_state);
    else if (trend == THERMAL_TREND_DROPPING)
        *state = max(*state - 1, 0);

    return 0;
}
```

---

## 4. sysfs 接口

```
/sys/class/thermal/
├── thermal_zone0/
│   ├── temp               ← 当前温度（毫摄氏度）
│   ├── trip_point_0_temp  ← 第一个阈值温度
│   ├── trip_point_0_type ← 主动 / 被动 / 紧急
│   └── policy             ← governor（step_wise / power_allocator）
├── cooling_device0/
│   ├── type               ← 设备类型
│   └── cur_state          ← 当前冷却状态（0=最大，max=最小）
└── zone0_trip_point0_binding
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/thermal/thermal_core.c` | `thermal_zone_temp_update`、`thermal_zone_cdev_update` |
| `include/linux/thermal.h` | `struct cooling_device`、`struct thermal_governor` |
| `drivers/thermal/step_wise.c` | step_wise governor |