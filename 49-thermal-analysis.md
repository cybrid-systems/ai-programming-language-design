# Linux Kernel Thermal Management 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/thermal/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 Thermal？

Linux thermal 子系统管理 CPU/设备温度，通过**cooling devices**（风扇、降频）防止过热。

---

## 1. 核心结构

```c
// drivers/thermal/thermal_core.h — thermal_zone_device
struct thermal_zone_device {
    const char               *type;          // "cpu-thermal" 等
    int                     passive_delay;
    int                     polling_delay;   // 轮询间隔
    struct thermal_zone_device_ops *ops;   // 操作函数表
    struct thermal_governor  *governor;    // 温度调节器
    struct thermal_zone_params *tzp;
    int                     trips;          // 温度阈值数量
    struct thermal_trip_desc *trip_desc;   // 每次 trip
    int                     temperature;    // 当前温度
    struct device           device;

    struct thermal_zone_device *next;       // 全局链表
};

// thermal_zone_device_ops — 驱动操作
struct thermal_zone_device_ops {
    int (*get_temp)(struct thermal_zone_device *, int *temp);
    int (*get_trip_type)(struct thermal_zone_device *, int, enum thermal_trip_type *);
    int (*set_trip_temp)(struct thermal_zone_device *, int, int temp);
};
```

---

## 2. cooling_device

```c
// drivers/thermal/thermal_core.h — thermal_cooling_device
struct thermal_cooling_device {
    const char               *type;          // "cpufreq" 等
    unsigned long             max_state;     // 最大状态
    unsigned long             cur_state;     // 当前状态
    struct thermal_cooling_device_ops *ops; // 操作
    void                     *devdata;
};

// cooling_device_ops
struct thermal_cooling_device_ops {
    int (*get_max_state)(struct thermal_cooling_device *, unsigned long *);
    int (*get_cur_state)(struct thermal_cooling_device *, unsigned long *);
    int (*set_cur_state)(struct thermal_cooling_device *, unsigned long);
};
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/thermal/thermal_core.c` | `thermal_zone_device_register`、`thermal_zone_device_update` |
| `drivers/thermal/thermal_core.h` | `struct thermal_zone_device`、`struct thermal_cooling_device` |
| `drivers/thermal/cpufreq_cooling.c` | CPUfreq cooling device 实现 |
