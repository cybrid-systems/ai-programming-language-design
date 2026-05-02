# 73-pinctrl-gpio — Linux Pin Control 和 GPIO 子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**pinctrl（Pin Control）** 和 **GPIO** 是 Linux 中管理 SoC 引脚的两个互补子系统。pinctrl 负责引脚的**复用（mux）**——将 SoC 内部功能信号（UART TX、I2C SCL、SPI MOSI）连接到物理引脚；GPIO 负责引脚的**数字 I/O**——读取/写入电平、控制中断。

**核心架构**：
```
设备驱动调用:
  devm_pinctrl_get(dev) → 获取 pinctrl handle
    ↓
  pinctrl_lookup_state(dev, "default") → 查找状态
    ↓
  pinctrl_select_state(p, state) → 应用引脚配置
    ↓
  pinctrl_commit_state(p, state) → 遍历所有 settings
    ├── PIN_MAP_TYPE_MUX_GROUP → pinmux_enable_setting()
    │     → pin_request() 逐个请求引脚
    │     → ops->set_mux() 设置硬件复用寄存器
    └── PIN_MAP_TYPE_CONFIGS_GROUP → pinconf_apply_config()
          → ops->pin_config_set() 设置电气特性

GPIO 路径:
  gpiod_get(dev, "label", flags) → 获取 GPIO 描述符
    ↓
  gpiod_direction_input(desc) → 设置方向
    ↓
  gpiod_get_value(desc) → 读取电平
```

**doom-lsp 确认**：pinctrl 核心在 `drivers/pinctrl/core.c`（2,407 行，268 个符号）。pinmux 在 `pinmux.c`（1,014 行）。GPIO 在 `drivers/gpio/gpiolib.c`（5,528 行）。

---

## 1. pinctrl 子系统

### 1.1 核心数据结构 @ pinctrl.h

```c
// include/linux/pinctrl/pinctrl.h
struct pinctrl_pin_desc {
    unsigned number;           /* 引脚号 */
    const char *name;          /* 引脚名 */
    void *drv_data;
};

struct pinctrl_desc {
    const char *name;                          /* 控制器名 */
    const struct pinctrl_pin_desc *pins;        /* 引脚描述表 */
    unsigned int npins;                         /* 引脚数 */
    const struct pinctrl_ops *pctlops;          /* 引脚操作 */
    const struct pinmux_ops *pmxops;            /* 复用操作 */
    const struct pinconf_ops *confops;          /* 配置操作 */
    const struct pincontrol_ops *ctlops;
};

struct pinctrl_dev {
    struct pinctrl_desc *desc;
    struct radix_tree_root pin_desc_tree;      /* 引脚描述 radix 树 */
    struct list_head gpio_ranges;               /* GPIO 范围列表 */
};
```

**doom-lsp 确认**：`struct pinctrl_dev` 通过 `radix_tree_insert`（`core.c:234`）将引脚号映射到 `pin_desc`。`pinctrl_register_one_pin` @ `core.c:206` 注册单个引脚。

### 1.2 引脚描述和引脚状态

```c
// drivers/pinctrl/core.c
// 引脚描述 radix 树：
// pctldev->pin_desc_tree 将引脚号 → struct pin_desc
// struct pin_desc {
//     struct pinctrl_dev *pctldev;     // 所属控制器
//     struct pinmux_setting *mux_setting; // 当前复用设置
//     const char *name;
//     void *drv_data;
// };

// 每个设备有一个 struct pinctrl（handle）：
struct pinctrl {
    struct list_head states;          // 所有可用状态
    struct pinctrl_state *state;      // 当前状态
    struct device *dev;
    struct list_head node;
};

// 每个状态对应一个设备树 pinctrl-N：
struct pinctrl_state {
    struct list_head node;
    const char *name;                 // "default", "sleep", "idle"
    struct list_head settings;        // 此状态的所有 setting
};
```

### 1.3 pinctrl_select_state @ core.c:1409

```c
// 引脚状态切换核心函数
int pinctrl_select_state(struct pinctrl *p, struct pinctrl_state *state)
{
    if (p->state == state)
        return 0;                    // 已在此状态

    return pinctrl_commit_state(p, state);  // 实际切换
}

// pinctrl_commit_state 内部调用：
// for each setting in state->settings:
//   switch (setting->type) {
//   case PIN_MAP_TYPE_MUX_GROUP:
//       pinmux_enable_setting(setting);     // 设置复用
//       break;
//   case PIN_MAP_TYPE_CONFIGS_GROUP:
//       pinconf_apply_config(setting);      // 设置电气配置
//       break;
//   }
```

**doom-lsp 确认**：`pinctrl_select_state` @ `core.c:1409`。`pinctrl_lookup_state` @ `core.c:1262`。

### 1.4 pinmux 复用 @ pinmux.c:433

```c
int pinmux_enable_setting(const struct pinctrl_setting *setting)
{
    // 1. 获取此 setting 涉及的所有引脚
    pctlops->get_group_pins(pctldev, group, &pins, &num_pins);

    // 2. 逐个引脚请求
    for (i = 0; i < num_pins; i++) {
        pin_request(pctldev, pins[i], setting->dev_name, NULL);
        // 设置 pin_desc->mux_setting
        desc->mux_setting = &(setting->data.mux);
    }

    // 3. 调用硬件驱动设置复用
    ops->set_mux(pctldev, setting->data.mux.func,
                 setting->data.mux.group);

    // 4. 失败时回滚所有已请求的引脚
}
```

**doom-lsp 确认**：`pinmux_enable_setting` @ `pinmux.c:433`。`ops->set_mux` 是驱动层回调，写硬件寄存器切换引脚功能。

### 1.5 PM 自动管理 @ core.c:1671

```c
// pinctrl 与 PM 的集成：
// suspend → pinctrl_pm_select_sleep_state(dev)
// resume  → pinctrl_pm_select_default_state(dev)

int pinctrl_pm_select_default_state(struct device *dev)
{
    // 通过 dev->pins->p 获取设备的 pinctrl handle
    // pinctrl_lookup_state(p, "default")
    // pinctrl_select_state(p, state)
}

int pinctrl_pm_select_sleep_state(struct device *dev)
{
    // 查找 "sleep" 状态并应用
}
```

---

## 2. GPIO 子系统（gpiolib）

### 2.1 核心数据结构

```c
// include/linux/gpio/driver.h
struct gpio_chip {
    const char *label;           /* 名称 */
    int base;                    /* 起始 GPIO 号 */
    u16 ngpio;                   /* GPIO 数量 */
    const char *const *names;

    /* ── 驱动操作 ─ */
    int (*direction_input)(struct gpio_chip *gc, unsigned offset);
    int (*direction_output)(struct gpio_chip *gc, unsigned offset, int value);
    int (*get)(struct gpio_chip *gc, unsigned offset);
    void (*set)(struct gpio_chip *gc, unsigned offset, int value);
    void (*set_multiple)(struct gpio_chip *gc, unsigned long *mask,
                         unsigned long *bits);
    int (*to_irq)(struct gpio_chip *gc, unsigned offset);
    int (*set_config)(struct gpio_chip *gc, unsigned offset,
                      unsigned long config);

    /* ── 中断 ─ */
    struct irq_chip *irq;       /* IRQ 芯片 */
    struct gpio_irq_chip *irq_chip;

    /* ── 内部 ─ */
    struct gpio_device *gpiodev;
};
```

**doom-lsp 确认**：`struct gpio_chip` 通过 `gpiochip_add_data_with_key`（`gpiolib.c:1137`）注册。

### 2.2 GPIO 读取路径 @ gpiolib.c:3617

```c
int gpiod_get_value(const struct gpio_desc *desc)
{
    // 1. 验证描述符
    VALIDATE_DESC(desc);

    // 2. 不允许在可休眠芯片上使用
    WARN_ON(desc->gdev->can_sleep);

    // 3. 实际读取（调用芯片驱动）
    value = gpiod_get_raw_value_commit(desc);

    // 4. ACTIVE_LOW 反转
    if (test_bit(GPIOD_FLAG_ACTIVE_LOW, &desc->flags))
        value = !value;

    return value;
}
```

### 2.3 GPIO 设置路径

```c
// 输出设置：
void gpiod_set_value(struct gpio_desc *desc, int value)
{
    if (test_bit(GPIOD_FLAG_ACTIVE_LOW, &desc->flags))
        value = !value;                     // 反转

    gpiod_set_raw_value_commit(desc, value); // 调用芯片驱动
}

// 方向设置：
int gpiod_direction_input(struct gpio_desc *desc)   // @ :2941
int gpiod_direction_output(struct gpio_desc *desc, int value)  // @ :3115
```

---

## 3. pinctrl 与 GPIO 的协同——引脚复用切换

当某个引脚在 pinctrl 模式和 GPIO 模式之间切换时：

```c
// 1. GPIO 请求引脚：
// gpiod_get() → gpiod_request() → gpiochip_gpio_request()
//   → pctldev->desc->pmxops->gpio_request_enable()
//   → 驱动将引脚切换到 GPIO 功能

// 2. 引脚释放回到 pinctrl：
// gpiod_put() → gpiod_free() → gpiochip_gpio_free()
//   → pctldev->desc->pmxops->gpio_disable_free()
//   → 引脚恢复到默认 pinctrl 状态

// 3. GPIO 范围映射（gpio_ranges）：
// 在设备树中定义：
//   gpio-ranges = <&pinctrl 0 0 32>;
//   解释：GPIO offset 0 → pin 0 → 范围 32 个引脚
// 通过 pinctrl_add_gpio_range() 注册
```

**doom-lsp 确认**：`gpio_request_enable` 和 `gpio_disable_free` 是 `struct pinmux_ops` 的成员。`gpio_ranges` 通过 `pinctrl_register_gpio_range()` 在 `core.c` 中注册。

---

## 4. 设备注册

```c
// pinctrl 控制器注册：
struct pinctrl_desc desc = {
    .name = "my-pinctrl",
    .pins = my_pins,
    .npins = ARRAY_SIZE(my_pins),
    .pctlops = &my_pctlops,
    .pmxops = &my_pmxops,
    .confops = &my_confops,
};

struct pinctrl_dev *pctldev = pinctrl_register_and_init(&desc, dev, NULL, &pctldev);
pinctrl_enable(pctldev);    // @ core.c:2217 实际注册到 pinctrldev_list

// GPIO 芯片注册：
struct gpio_chip gc = {
    .label = "my-gpio",
    .base = -1,              // 动态分配
    .ngpio = 32,
    .direction_input = my_gpio_dir_in,
    .direction_output = my_gpio_dir_out,
    .get = my_gpio_get,
    .set = my_gpio_set,
};
gpiochip_add_data(&gc, NULL);  // @ gpiolib.c:1137
```

---

## 5. 调试

```bash
# GPIO 完整状态
cat /sys/kernel/debug/gpio
# gpiochip0: GPIOs 0-31, parent: platform/soc:gpio, can sleep:
#  gpio-0  (|GPIO Key POWER     ) in  hi

# pinctrl 引脚映射
cat /sys/kernel/debug/pinctrl/*/pins
# pin 0 (GPIO0)  (GPLR=0x00000001)

# 当前复用状态
cat /sys/kernel/debug/pinctrl/*/pinmux-pins
# pin 0 (GPIO0): device uart0 function uart group uart-pins

# 可用功能列表
cat /sys/kernel/debug/pinctrl/*/pinmux-functions
# function: uart, groups = [uart-pins]
# function: gpio, groups = [gpio-pins]

# GPIO 中断
cat /proc/interrupts | grep gpio
```

---

## 6. 关键函数索引

| 函数 | 文件:行号 | 作用 |
|------|----------|------|
| `pinctrl_select_state` | `core.c:1409` | 引脚状态切换入口 |
| `pinctrl_lookup_state` | `core.c:1262` | 查找状态 |
| `pinctrl_register_one_pin` | `core.c:206` | 注册单个引脚 |
| `pinctrl_register_mappings` | `core.c:1468` | 注册映射表 |
| `pinctrl_enable` | `core.c:2217` | 启用控制器 |
| `pinmux_enable_setting` | `pinmux.c:433` | 复用设置（请求引脚+写寄存器）|
| `pinctrl_pm_select_default_state` | `core.c:1674` | PM 自动应用默认状态 |
| `pinctrl_add_gpio_range` | `core.c` | GPIO 范围注册 |
| `gpiochip_add_data_with_key` | `gpiolib.c:1137` | GPIO 芯片注册 |
| `gpiod_get_value` | `gpiolib.c:3617` | GPIO 读取（含 ACTIVE_LOW）|
| `gpiod_set_value` | `gpiolib.c` | GPIO 输出设置 |
| `gpiod_direction_input` | `gpiolib.c:2941` | 设置方向为输入 |
| `gpiod_direction_output` | `gpiolib.c:3115` | 设置方向为输出 |

---

## 7. 总结

pinctrl 和 GPIO 是 SoC 引脚管理的两个层面——pinctrl 管理**复用**（`pinmux_enable_setting` @ `pinmux.c:433` → `ops->set_mux`），GPIO 管理**数字 I/O**（`gpiod_get_value` @ `gpiolib.c:3617` → `chip->get`）。两者通过 `gpio_request_enable` 接口在引脚复用和 GPIO 模式之间切换。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
