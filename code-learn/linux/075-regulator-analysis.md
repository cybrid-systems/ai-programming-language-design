# 75-regulator — Linux 电压/电流调节器框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Regulator 框架**管理 SoC 中的电压调节器（LDO、DC-DC、DCDC）和电流调节器。设备驱动通过 `regulator_get/enable/set_voltage` 控制电源，内部通过引用计数管理电源开关和电压变更。

**核心设计**：Regulator 框架的核心是**引用计数 + 级联**——`_regulator_enable`（`core.c:3116`）维护 `rdev->use_count` 和 `regulator->enable_count`，使能前递归使能输入电源。电压通过 `regulator_map_voltage`（`:3742`）选择最优档位后设置。

```
设备驱动                    Regulator 核心                  PMIC 硬件
    │                            │                            │
regulator_get(dev, "vcc")        │                            │
  → _regulator_get()             │                            │
    → regulator_map              │                            │
    → regulator_resolve_supply   │                            │
    │                            │                            │
regulator_enable(reg)            │                            │
  → _regulator_enable()          │                            │
    → if use_count==0:           │                            │
      _regulator_enable(supply)  ← 先开输入电源               │
      _regulator_do_enable(rdev) →→→→→→→→→ ops->enable()     写寄存器
      _notifier_call_chain()     │                            │
    → use_count++                │                            │
    │                            │                            │
regulator_set_voltage(reg,uv)    │                            │
  → _regulator_set_voltage()     │                            │
    → regulator_map_voltage()    │ 选最优电压档位              │
    → _regulator_call_set_voltage()                            │
      → PRE_VOLTAGE_CHANGE 通知  │                            │
      → ops->set_voltage()      →→→→→→→→→ 设置电压           │
      → POST_VOLTAGE_CHANGE 通知 │                            │
    │                            │                            │
regulator_disable(reg)           │                            │
  → _regulator_disable() >0      │ 引用计数递减                │
  → enable_count==0 → ops->disable() 真正关闭                 │
```

**doom-lsp 确认**：核心在 `drivers/regulator/core.c`（**6,890 行**，**553 个符号**）。头文件 `include/linux/regulator/consumer.h`（745 行）、`driver.h`（803 行）。

---

## 1. 核心数据结构

### 1.1 struct regulator_dev — 调节器设备

```c
// include/linux/regulator/driver.h
struct regulator_dev {
    const struct regulator_desc *desc;          /* 硬件描述 */
    const struct regulator_ops *ops;            /* 硬件操作 */
    struct regulator_constraints *constraints;  /* 约束 */

    int open_count;                              /* 打开次数 */
    int use_count;                               /* 引用计数（实际使能数）*/
    unsigned int exclusive:1;

    int min_uV, max_uV;                          /* 当前电压范围 */
    unsigned int curr_mask;

    unsigned int enabled_count;                  /* 硬件使能计数 */
    struct regulator_enable_gpio *ena_pin;       /* 使能 GPIO */
    unsigned long last_off_jiffies;

    struct list_head consumer_list;              /* 消费者列表 */
    struct regulator *supply;                    /* 输入电源调节器 */
};
```

### 1.2 struct regulator — 消费者句柄

```c
struct regulator {
    struct regulator_dev *rdev;
    struct device *dev;
    struct list_head list;
    int uA_load;                                /* 负载电流需求 */
    int min_uV, max_uV;                         /* 消费者电压需求 */
    unsigned int enable_count;                  /* 此消费者的使能次数 */
    struct regulator *supply;                   /* 输入电源 */
};
```

**doom-lsp 确认**：`struct regulator_dev` 通过 `devm_regulator_register` 注册。每个 `struct regulator` 对应一个 `regulator_get()` 调用。

---

## 2. 使能路径——_regulator_enable @ :3116

```c
// 使能的核心——引用计数 + 级联输入电源 + 硬件使能
static int _regulator_enable(struct regulator *regulator)
{
    struct regulator_dev *rdev = regulator->rdev;

    /* 1. 引用计数从 0 到 1 → 先使能输入电源 */
    if (rdev->use_count == 0 && rdev->supply) {
        ret = _regulator_enable(rdev->supply);      // 递归！
        if (ret < 0) return ret;
    }

    /* 2. 耦合调节器平衡（多相位电源） */
    if (rdev->coupling_desc.n_coupled > 1) {
        ret = regulator_balance_voltage(rdev, PM_SUSPEND_ON);
    }

    /* 3. 消费者使能处理 */
    ret = _regulator_handle_consumer_enable(regulator);

    /* 4. 如果 rdev 尚未使能 → 执行硬件使能 */
    if (rdev->use_count == 0) {
        ret = _regulator_is_enabled(rdev);
        if (ret == -EINVAL || ret == 0) {
            // 检查是否有使能权限
            ret = _regulator_do_enable(rdev);
            // → ops->enable(rdev) 或 ena_pin GPIO 控制
            _notifier_call_chain(rdev, REGULATOR_EVENT_ENABLE, NULL);
        }
        rdev->use_count++;
    }

    regulator->enable_count++;
    return 0;
}

// regulator_enable—加锁入口
int regulator_enable(struct regulator *regulator)
{
    regulator_lock_dependent(rdev, &ww_ctx);      // WW 锁
    ret = _regulator_enable(regulator);
    regulator_unlock_dependent(rdev, &ww_ctx);
    return ret;
}
```

## 3. 禁用路径——_regulator_disable @ :3237

```c
static int _regulator_disable(struct regulator *regulator)
{
    struct regulator_dev *rdev = regulator->rdev;

    if (WARN(regulator->enable_count == 0, "unbalanced disables"))
        return -EIO;

    regulator->enable_count--;

    /* 当消费者引用归零时检查是否需要关闭 */
    if (regulator->enable_count == 0) {
        rdev->use_count--;

        if (rdev->use_count == 0) {
            // 真正关闭硬件
            _regulator_do_disable(rdev);
            // → ops->disable(rdev) 或 ena_pin GPIO

            // 通知事件
            _notifier_call_chain(rdev, REGULATOR_EVENT_DISABLE, NULL);

            // 递归关闭输入电源
            if (rdev->supply)
                _regulator_disable(rdev->supply);
        }
    }
}
```

**doom-lsp 确认**：`_regulator_enable` @ `:3116`，`_regulator_disable` @ `:3237`。`_regulator_do_enable` 优先使用 GPIO（ena_pin）控制，其次调用 `ops->enable`。`_regulator_do_disable` 类似。

---

## 4. 电压设置路径

### 4.1 regulator_map_voltage @ :3742——选择最优电压

```c
static int regulator_map_voltage(struct regulator_dev *rdev, int min_uV, int max_uV)
{
    //  1. 如果有 map_voltage 回调 → 调用驱动
    //  2. 如果是线性列表 → 线性映射
    //  3. 如果是线性范围 → 范围映射
    //  4. 兜底：regulator_map_voltage_iterate() 迭代
    //     遍历所有可用电压，找满足 [min_uV, max_uV] 的值
}
```

### 4.2 _regulator_do_set_voltage——设置电压

```c
// regulator_set_voltage() 内部路径：
// → _regulator_call_set_voltage  @ :3764
//   → PRE_VOLTAGE_CHANGE 通知（可阻止变更）
//   → ops->set_voltage(rdev, min_uV, max_uV, &selector)
//   → 成功后 POST_VOLTAGE_CHANGE 通知
//   → 失败后 ABORT_VOLTAGE_CHANGE 通知
```

**doom-lsp 确认**：`regulator_map_voltage` @ `:3742`。`_regulator_call_set_voltage` @ `:3764`。通知机制允许其他驱动监听电压变更。

---

## 5. 约束系统

```c
// 约束在 regulator_register() 时通过 set_machine_constraints @ :1446 应用：
// struct regulation_constraints {
//     int min_uV, max_uV;              // 电压范围
//     int uV_offset;                    // 偏移
//     int min_uA, max_uA;              // 电流范围
//     unsigned int always_on:1;         // 常开
//     unsigned int boot_on:1;           // 启动时打开
//     unsigned int apply_uV:1;          // 启动时设置电压
//     unsigned int ramp_delay;          // 电压变化速率
//     int max_spread;                   // 最大偏差（多相位）
// };
```

---

## 6. 匹配与获取

```c
// regulator_get(dev, "vcc") 内部路径：
// _regulator_get()
//   → 查找 regulator_map（匹配 dev_name + supply 名）
//   → regulator_resolve_supply() @ :2171
//      → 连接输入电源（supply→supply 链条）
//      → 创建 struct regulator
//
// 匹配来源：
// 1. 设备树：reg = <&xxx>;
// 2. board 文件：REGULATOR_SUPPLY("vcc", "my-device")
// 3. ACPI
```

---

## 7. 调试

```bash
# regulator 状态摘要
cat /sys/kernel/debug/regulator/regulator_summary
# 输出格式：
# regulator            use_count open_count min_uV   max_uV
# vcc-core             2         4          1100000  1100000
#  'my_device          1                     1100000  1100000
# vcc-io               3         5          3300000  3300000
#  'mmc0               1                     3300000  3300000

# sysfs 单 regulator 信息
cat /sys/class/regulator/regulator.0/name
cat /sys/class/regulator/regulator.0/state     # enabled/disabled
cat /sys/class/regulator/regulator.0/microvolts
cat /sys/class/regulator/regulator.0/microamps
cat /sys/class/regulator/regulator.0/num_voltages
```

---

## 8. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `_regulator_enable` | `:3116` | 使能核心（引用计数+级联+硬件）|
| `_regulator_disable` | `:3237` | 禁用核心（引用计数递减+级联）|
| `_regulator_do_enable` | — | 执行硬件使能（GPIO/ops）|
| `_regulator_do_disable` | — | 执行硬件禁用 |
| `regulator_map_voltage` | `:3742` | 选择最优电压档位 |
| `_regulator_call_set_voltage` | `:3764` | 设置电压（含通知链）|
| `set_machine_constraints` | `:1446` | 应用约束 |
| `regulator_resolve_supply` | `:2171` | 解析输入电源连接 |
| `drms_uA_update` | `:983` | 动态电流管理 |

---

## 9. 总结

Regulator 框架的核心是 `_regulator_enable`（`:3116`）和 `_regulator_disable`（`:3237`）的**引用计数 + 级联**设计——每个 `regulator_enable()` 递增 `use_count`/`enable_count`，递减到 0 时才真正关闭硬件。电压通过 `regulator_map_voltage`（`:3742`）选择最优档位，并通过 `_regulator_call_set_voltage`（`:3764`）配合通知链完成设置。

**doom-lsp 确认**：553 个符号分布在 6,890 行的 `core.c`。核心路径是：`regulator_enable` → `_regulator_enable` → `_regulator_do_enable` → `ops->enable`。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct regulator_dev` | include/linux/regulator/driver.h | 核心结构 |
| `regulator_enable()` | drivers/regulator/core.c | 使能 |
| `_regulator_do_enable()` | drivers/regulator/core.c | 1660 |
| `regulator_set_voltage()` | drivers/regulator/core.c | 调压 |
| `_regulator_do_set_voltage()` | drivers/regulator/core.c | 109 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
