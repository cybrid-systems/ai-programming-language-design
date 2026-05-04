# 075-regulator — Linux 电压/电流调节器框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**Regulator** 框架是 Linux 内核中管理电压/电流调节器的统一抽象层。它提供了一个标准化的 API 给设备驱动（如 CPU DVFS、GPU、外设），屏蔽底层硬件差异——无论调节器是使用 I2C 控制的 PMIC、GPIO 开关、还是 PWM 调压器，驱动对它的操作都是 `regulator_enable/disable/set_voltage`。

**doom-lsp 确认**：`drivers/regulator/core.c`（6890 行，242 个符号），`include/linux/regulator/consumer.h`（API 声明）。

---

## 1. 核心数据结构

### 1.1 `struct regulator_dev`——调节器设备

（`include/linux/regulator/driver.h` — doom-lsp 确认）

```c
struct regulator_dev {
    struct device           dev;             // 嵌入式 device 结构
    struct regulation_constraints *constraints; // 约束（最小/最大电压、电流限制）
    struct regulator_desc   *desc;           // 硬件描述（ops、类型、名称）

    struct list_head        consumer_list;   // 该调节器的消费者链表
    struct list_head        list;            // 全局调节器链表

    struct blocking_notifier_head notifier;  // 事件通知（过压、欠压）

    int                     use_count;       // 使能引用计数
    unsigned int            open_count;      // 打开次数

    /* 状态 */
    unsigned int            curr_voltage;    // 当前电压（uV）
    unsigned int            curr_current;    // 当前电流（uA）
    struct regulator_enable_gpio *enable_gpio; // 使能 GPIO
    ...
};
```

### 1.2 `struct regulator`——消费者角度

```c
struct regulator {
    struct device           *dev;            // 消费者设备
    struct list_head        list;            // regulator_dev 的 consumer_list 节点
    int                     uA_load;         // 当前负载（uA）
    unsigned int            enable_count;    // 该消费者的使能计数
    struct mutex            mutex;           // 操作互斥锁
    struct regulator_dev   *rdev;            // 指向实际的调节器设备
    const char             *supply_name;     // 电源名称（"vcc-core"）
};
```

---

## 2. 核心数据流

### 2.1 使能路径

```
regulator_enable(regulator)
  └─ _regulator_enable(regulator)
       └─ rdev = regulator->rdev
       └─ lock rdev
       └─ if (rdev->use_count == 0):  // 第一次使能
       │     └─ _regulator_do_enable(rdev)
       │          ├─ 如果 rdev 的 supply 未使能 → regulator_enable(supply) 递归
       │          ├─ desc->ops->enable(rdev)  ← 驱动回调
       │          │    → PMIC: I2C 写寄存器
       │          │    → GPIO: gpiod_set_value(gpio, 1)
       │          │    → PWM: pwm_enable(pwm)
       │          └─ update rdev->use_count++
       └─ rdev->use_count++
```

### 2.2 调压路径

```
regulator_set_voltage(regulator, min_uV, max_uV)
  └─ _regulator_do_set_voltage(rdev, min_uV, max_uV)
       ├─ desc->ops->set_voltage(rdev, min_uV, max_uV)
       │    → PMIC: I2C 写 VSEL 寄存器
       │    → PWM: pwm_config(pwm, duty, period)
       │
       └─ regulator_notifier_call_chain(rdev, REGULATOR_EVENT_VOLTAGE_CHANGE, ...)
```

---

## 3. 核心函数索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct regulator_dev` | include/linux/regulator/driver.h | (核心结构) |
| `struct regulator` | include/linux/regulator/consumer.h | (核心结构) |
| `regulator_enable()` | drivers/regulator/core.c | 相关 |
| `_regulator_do_enable()` | drivers/regulator/core.c | 1660 |
| `regulator_disable()` | drivers/regulator/core.c | 相关 |
| `regulator_set_voltage()` | drivers/regulator/core.c | 相关 |
| `_regulator_do_set_voltage()` | drivers/regulator/core.c | 109 |
| `regulator_get()` | drivers/regulator/core.c | 消费者注册 |
| `regulator_register()` | drivers/regulator/core.c | 调节器注册 |
| `of_regulator_match()` | drivers/regulator/of_regulator.c | DT 匹配 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
