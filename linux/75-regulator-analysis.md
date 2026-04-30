# regulator — 电源管理IC深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/regulator/core.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**regulator** 控制电压/电流输出，为 CPU、GPU、WiFi 等提供稳定电源。

---

## 1. 核心数据结构

### 1.1 regulator — 稳压器

```c
// drivers/regulator/internal.h — regulator
struct regulator {
    // 设备
    struct device           dev;           // 设备
    struct regulator_dev    *rdev;         // 稳压器设备

    // 供应者
    struct regulator_dev    *supply;       // 供电者（上级稳压器）

    // 状态
    const char              *name;         // 名称
    int                     enable_count;  // 使能计数
    unsigned int            bypass_count; // 旁路计数

    // 配置
    struct regulator_state   state;        // 当前状态
    struct regulator_config  config;       // 配置

    // 模式
    unsigned int            opmode;       // 工作模式（FAST/NORMAL/IDLE/STANDBY）
};
```

### 1.2 regulator_dev — 稳压器设备

```c
// drivers/regulator/core.c — regulator_dev
struct regulator_dev {
    const struct regulator_desc *desc;     // 描述符
    struct regulator_dev        *supply;   // 上级稳压器

    // 操作函数
    const struct regulator_ops  *ops;      // 操作函数

    // 配置
    unsigned int            n_voltages;   // 电压等级数
    unsigned long           *volt_table;   // 电压表
    unsigned long           min_uV;        // 最小电压
    unsigned long           max_uV;        // 最大电压

    // 约束
    struct regulation_constraints *constraints; // 约束
};
```

### 1.3 regulator_ops — 操作函数表

```c
// include/linux/regulator/driver.h — regulator_ops
struct regulator_ops {
    // 电压/电流控制
    int                     (*enable)(struct regulator_dev *);
    int                     (*disable)(struct regulator_dev *);
    int                     (*is_enabled)(struct regulator_dev *);

    int                     (*set_voltage)(struct regulator_dev *, int, int, unsigned *);
    int                     (*get_voltage)(struct regulator_dev *);
    int                     (*set_current_limit)(struct regulator_dev *, int, int);

    // 模式
    int                     (*set_mode)(struct regulator_dev *, unsigned int);
    unsigned int            (*get_mode)(struct regulator_dev *);

    // 省电模式
    int                     (*set_load)(struct regulator_dev *, int);
};
```

---

## 2. 电压设置

### 2.1 regulator_set_voltage

```c
// drivers/regulator/core.c — regulator_set_voltage
int regulator_set_voltage(struct regulator *regulator, int min_uV, int max_uV)
{
    struct regulator_dev *rdev = regulator->rdev;

    // 1. 检查约束
    if (rdev->constraints && min_uV < rdev->constraints->min_uV)
        min_uV = rdev->constraints->min_uV;
    if (rdev->constraints && max_uV > rdev->constraints->max_uV)
        max_uV = rdev->constraints->max_uV;

    // 2. 设置电压
    return rdev->ops->set_voltage(rdev, min_uV, max_uV, NULL);
}
```

---

## 3. sysfs 接口

```
/sys/class/regulator/
├── regulator.0/
│   ├── state               ← on/off/bypass
│   ├── status              ← ACTIVE/UNACTIVE
│   ├── microvolts          ← 当前电压（μV）
│   ├── microvolts_requested ← 请求的电压
│   └── suspend_state        ← 暂停状态
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/regulator/core.c` | `struct regulator_dev`、`regulator_set_voltage` |
| `include/linux/regulator/driver.h` | `struct regulator_ops` |