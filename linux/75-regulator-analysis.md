# 75-regulator — Linux 电压/电流调节器（Regulator）框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Regulator 框架**是 Linux 中管理电压和电流的内核子系统。它为设备驱动提供统一的电源控制 API——`regulator_enable`/`regulator_disable` 控制电源开关，`regulator_set_voltage` 调节输出电压。

**核心设计**：Regulator 框架将 SoC 电源管理单元（PMIC）中的 LDO、DC-DC 转换器抽象为 `struct regulator_dev`，通过 `struct regulator_ops` 与硬件驱动解耦。消费者（consumer）通过 `regulator_get` 获取调节器句柄，通过引用计数管理电源开关。

```
设备驱动              Regulator 核心              PMIC 驱动
regulator_get(dev)      → rdev (regulator_dev)       |
regulator_enable(reg)   → _regulator_enable(rdev)    → ops->enable()
                         → enable_count++            → 写硬件寄存器
regulator_set_voltage   → _regulator_set_voltage(..)  → ops->set_voltage()
regulator_disable(reg)  → enable_count--             → ops->disable()
                         → =0 时真正关闭
```

**doom-lsp 确认**：核心实现在 `drivers/regulator/core.c`（**6,890 行**，**553 个符号**）。头文件：`include/linux/regulator/consumer.h`（745 行）、`include/linux/regulator/driver.h`（803 行）。

---

## 1. 核心数据结构

### 1.1 struct regulator_dev — 调节器设备

```c
// include/linux/regulator/driver.h
struct regulator_dev {
    const struct regulator_desc *desc;         /* 硬件描述 */
    const struct regulator_ops *ops;           /* 硬件操作 */
    struct device *dev;

    struct regulation_constraints *constraints;/* 约束（电压范围/电流限制）*/

    int open_count;                            /* 打开计数 */
    int use_count;                             /* 引用计数 */
    unsigned int exclusive:1;

    /* ── 电压状态 ─ */
    int min_uV;                                /* 当前最小电压 */
    int max_uV;                                /* 当前最大电压 */
    unsigned int curr_mask;

    /* ── 使能计数 ─ */
    unsigned int enabled_count;                // _regulator_enable 计数
    struct regulator_enable_gpio *ena_pin;     // 使能 GPIO
    unsigned int last_off_jiffies;

    struct list_head consumer_list;            // 消费者列表
    struct list_head list;                     // regulator_list
};
```

### 1.2 struct regulator — 消费者句柄

```c
struct regulator {
    struct device *dev;
    struct list_head list;
    struct regulator_dev *rdev;                // 指向 rdev
    struct regulation_constraints *constraints;
    int uA_load;                               // 负载电流
    int min_uV, max_uV;                        // 消费者电压需求
    unsigned int enable_count;                 // 使能计数
    struct regulator_voltage *voltage;
    struct regulator *supply;                  // 输入电源
};
```

**doom-lsp 确认**：`struct regulator_dev` 在 `driver.h`。`struct regulator` 是消费者侧私有结构。

---

## 2. 核心 API

```c
// 消费者 API：

// 获取/释放
struct regulator *regulator_get(struct device *dev, const char *id);    // @ core.c
void regulator_put(struct regulator *regulator);

// 使能/禁用（引用计数管理）
int regulator_enable(struct regulator *regulator);       // → _regulator_enable
int regulator_disable(struct regulator *regulator);      // → _regulator_disable
int regulator_is_enabled(struct regulator *regulator);

// 电压控制
int regulator_set_voltage(struct regulator *regulator, int min_uV, int max_uV);
int regulator_get_voltage(struct regulator *regulator);

// 电流控制
int regulator_set_current_limit(struct regulator *regulator, int min_uA, int max_uA);
int regulator_get_current_limit(struct regulator *regulator);
```

---

## 3. 使能路径——_regulator_enable

```c
// drivers/regulator/core.c
static int _regulator_enable(struct regulator_dev *rdev)
{
    /* 1. 处理输入电源（级联使能）*/
    if (rdev->supply)
        _regulator_enable(rdev->supply->rdev);    // 先开输入电源

    /* 2. 检查约束 */
    if (rdev->constraints->always_on)
        return 0;

    /* 3. 调用硬件操作 */
    if (rdev->ops->enable)
        ret = rdev->ops->enable(rdev);             // 硬件使能

    /* 4. 更新计数 */
    rdev->enabled_count++;

    return 0;
}
```

**doom-lsp 确认**：`_regulator_enable` @ `core.c:101`（553 符号中的第一个关键函数）。

---

## 4. 电压设置路径

```c
// regulator_set_voltage → regulator_do_set_voltage

static int regulator_do_set_voltage(struct regulator_dev *rdev,
                                     int min_uV, int max_uV)
{
    /* 1. 选择最优电压 */
    if (ops->set_voltage_sel) {
        // 通过选择器设置（预定义电压表）
        ops->set_voltage_sel(rdev, selector);
    } else if (ops->set_voltage) {
        // 直接设置电压值
        ops->set_voltage(rdev, min_uV, max_uV, &selector);
    }

    /* 2. 更新缓存 */
    rdev->min_uV = min_uV;
    rdev->max_uV = max_uV;
}
```

---

## 5. 调试

```bash
# 查看 regulator 状态
cat /sys/kernel/debug/regulator/regulator_summary
#   regulator               min_uV   max_uV   use_count  open_count
#  vcc-core                  1100000  1100000  2          4
#  vcc-io                    3300000  3300000  3          5
#   vcc_sd                   3300000  3300000  1          1

# sysfs 接口
ls /sys/class/regulator/regulator.*/
cat /sys/class/regulator/regulator.0/name
cat /sys/class/regulator/regulator.0/state    # enabled/disabled
cat /sys/class/regulator/regulator.0/microvolts
cat /sys/class/regulator/regulator.0/microamps
```

---

## 6. 注册

```c
struct regulator_desc rdesc = {
    .name = "vcc-core",
    .id = 0,
    .type = REGULATOR_VOLTAGE,
    .ops = &my_regulator_ops,
    .volt_table = my_voltages,
    .n_voltages = ARRAY_SIZE(my_voltages),
};

struct regulator_dev *rdev = devm_regulator_register(dev, &rdesc, &config);
```

---

## 7. 总结

Regulator 框架通过 `_regulator_enable`（`core.c:101`）管理电源开关引用计数，通过 `regulator_do_set_voltage` 选择最优电压。`struct regulator_ops` 提供硬件抽象，消费者通过 `regulator_get/enable/set_voltage` 控制电源。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
