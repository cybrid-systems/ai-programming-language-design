# 73-pinctrl-gpio — Linux Pin Control 和 GPIO 子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**pinctrl（Pin Control）** 和 **GPIO** 是 Linux 中管理 SoC 引脚的两个互补子系统。pinctrl 负责引脚的**复用（mux）**——将 SoC 的内部信号（UART、I2C、SPI、GPIO）连接到物理引脚；GPIO 负责引脚的**数字 I/O**——读取/写入高低电平和控制中断。

**核心设计**：pinctrl 维护引脚的状态机（`default`/`sleep`/`idle`/`active`），设备驱动通过 `pinctrl_pm_select_default_state()` 请求引脚配置。GPIO 通过 `gpiolib` 提供 `gpiod_get_value`/`gpiod_set_value` 接口，底层通过 GPIO 芯片驱动（`struct gpio_chip`）访问硬件。

```
SoC 引脚映射：
  ┌─── PIN MUX (pinctrl) ───┐
  │ pin 0: GPIO0             │  选择引脚功能
  │ pin 1: UART_TXD          │  → pinctrl_select_state()
  │ pin 2: I2C_SCL           │
  │ pin 3: SPI_MOSI          │
  └──────────────────────────┘

  ┌─── GPIO (gpiolib) ───────┐
  │ gpio_chip A: 0-31        │  数字 I/O + 中断
  │ gpio_chip B: 32-63       │  → gpiod_get/set_value()
  └──────────────────────────┘
```

**doom-lsp 确认**：pinctrl 核心在 `drivers/pinctrl/core.c`（**2,407 行**，**268 个符号**）。pinmux 在 `pinmux.c`（1,014 行）。GPIO 核心在 `drivers/gpio/gpiolib.c`（5,528 行）。头文件：`include/linux/pinctrl/pinctrl.h`（254 行）、`include/linux/gpio/consumer.h`（738 行）。

---

## 1. pinctrl 子系统

### 1.1 核心数据结构

```c
// include/linux/pinctrl/pinctrl.h
struct pinctrl_pin_desc {
    unsigned number;                    /* 引脚号 */
    const char *name;                   /* 引脚名 */
    void *drv_data;
};

struct pinctrl_desc {
    const char *name;                    /* 控制器名 */
    const struct pinctrl_pin_desc *pins; /* 引脚描述表 */
    unsigned int npins;                  /* 引脚数 */
    const struct pinctrl_ops *pctlops;   /* 引脚控制操作 */
    const struct pinmux_ops *pmxops;    /* 引脚复用操作 */
    const struct pinconf_ops *confops;  /* 引脚配置操作 */
};

struct pinctrl_dev {                     /* pinctrl 控制器实例 */
    struct pinctrl_desc *desc;           /* 控制器描述 */
    struct list_head node;               /* pinctrldev_list 节点 */
    struct device *dev;
    struct radix_tree_root pin_desc_tree; /* 引脚描述 radix 树 */
    struct list_head gpio_ranges;         /* GPIO 范围列表 */
    struct list_head dt_maps;
};
```

**doom-lsp 确认**：`struct pinctrl_dev` 和 `struct pinctrl_desc` 在 `include/linux/pinctrl/pinctrl.h`。`pinctrl_register` 在 `core.c` 中注册控制器到 `pinctrldev_list`。

### 1.2 引脚复用（pinmux）

```c
// include/linux/pinctrl/pinmux.h
struct pinmux_ops {
    int (*request)(struct pinctrl_dev *pctldev, unsigned selector);
    int (*set_mux)(struct pinctrl_dev *pctldev, unsigned selector,
                   unsigned group);
    int (*gpio_request_enable)(struct pinctrl_dev *pctldev,
                               struct pinctrl_gpio_range *range,
                               unsigned offset);
    int (*gpio_disable_free)(...);
};

// 复用过程：将功能信号（如 UART TX）映射到物理引脚
// 1. 设备驱动调用 devm_pinctrl_get() 获取 pinctrl handle
// 2. pinctrl_select_state() 选择状态（default/sleep/active）
// 3. → pinmux_ops->set_mux() 设置硬件寄存器
```

### 1.3 引脚状态映射

```c
// 设备树中的 pinctrl 状态：
// pinctrl-0 = <&uart0_default>;
// pinctrl-1 = <&uart0_sleep>;
// pinctrl-names = "default", "sleep";

// 内核自动管理：
// probe 时 → pinctrl_select_state("default")
// suspend → pinctrl_select_state("sleep")
// resume  → pinctrl_select_state("default")
//
// 通过 pinctrl_pm_select_*() 系列函数：
//   pinctrl_pm_select_default_state(dev)
//   pinctrl_pm_select_sleep_state(dev)
//   pinctrl_pm_select_idle_state(dev)
```

---

## 2. GPIO 子系统（gpiolib）

### 2.1 核心数据结构

```c
// include/linux/gpio/driver.h
struct gpio_chip {
    const char *label;                          /* 名称 */
    struct device *parent;
    struct module *owner;

    int base;                                   /* 起始 GPIO 号 */
    u16 ngpio;                                  /* GPIO 数 */
    const char *const *names;

    /* ── 操作函数 ─ */
    int (*direction_input)(struct gpio_chip *gc, unsigned offset);
    int (*direction_output)(struct gpio_chip *gc, unsigned offset, int value);
    int (*get)(struct gpio_chip *gc, unsigned offset);
    void (*set)(struct gpio_chip *gc, unsigned offset, int value);
    int (*get_multiple)(struct gpio_chip *gc, unsigned long *mask,
                        unsigned long *bits);
    void (*set_multiple)(struct gpio_chip *gc, unsigned long *mask,
                         unsigned long *bits);
    int (*set_config)(struct gpio_chip *gc, unsigned offset,
                      unsigned long config);
    int (*to_irq)(struct gpio_chip *gc, unsigned offset);

    /* ── 中断 ─ */
    struct irq_chip *irq;                       /* IRQ 芯片 */
    unsigned int irq_base;
    irq_flow_handler_t irq_handler;
    unsigned int irq_default_type;
    struct gpio_irq_chip *irq_chip;

    /* ── 内部 ─ */
    struct gpio_device *gpiodev;
    int id;
    unsigned long flags;
};
```

### 2.2 GPIO 操作

```c
// 消费 API（include/linux/gpio/consumer.h）：
// 推荐使用 GPIO 描述符 API（gpiod_*）：

int gpiod_get_value(const struct gpio_desc *desc);
void gpiod_set_value(struct gpio_desc *desc, int value);
int gpiod_direction_input(struct gpio_desc *desc);
int gpiod_direction_output(struct gpio_desc *desc, int value);

// GPIO 号 API（旧式，不推荐）：
int gpio_request(unsigned gpio, const char *label);
int gpio_direction_input(unsigned gpio);
int gpio_set_value(unsigned gpio, int value);
```

### 2.3 GPIO 中断

```c
// GPIO 作为中断源：
// struct gpio_chip 中的 struct irq_chip *irq
// 注册为 irq_domain
// gpiod_to_irq(desc) → 返回 IRQ 号
// gpio 中断受 /proc/interrupts 监控
```

---

## 3. pinctrl 与 GPIO 的交互

SoC 引脚通常可以在 pinctrl 和 GPIO 模式间切换：

```c
// GPIO 复用为 GPIO 模式时通过 pinctrl：
// gpio_request()
//   → gpiochip_gpio_request()
//     → pinmux_ops->gpio_request_enable()
//       → pinctrl 芯片将引脚切换到 GPIO 功能

// ACPI/DT 中的 pinctrl + GPIO 映射：
// drivers/pinctrl/pinctrl*.c 注册 gpio_ranges
// gpio_ranges 告知 gpiolib 哪些引脚可以通过 pinctrl 控制
```

---

## 4. 调试

```bash
# 查看 GPIO 状态
cat /sys/kernel/debug/gpio

# 查看 pinctrl 状态
cat /sys/kernel/debug/pinctrl/*/pins
cat /sys/kernel/debug/pinctrl/*/pinmux-pins
cat /sys/kernel/debug/pinctrl/*/pinmux-functions

# gpio 操作
gpioinfo
gpioget <chip> <offset>
gpioset <chip> <offset>=1

# 设备树 pinctrl 状态
cat /sys/kernel/debug/devices/xxx/pinctrl
```

---

## 5. 总结

pinctrl 管理引脚复用（`pinctrl_select_state`），GPIO 管理数字 I/O（`gpiod_get/set_value`）。两者通过 `gpio_request_enable` / `gpio_disable_free` 接口协同工作——GPIO 请求引脚时，pinctrl 将引脚切换到 GPIO 模式。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
