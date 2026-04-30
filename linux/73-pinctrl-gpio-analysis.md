# pinctrl / GPIO — 引脚控制深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/pinctrl/` + `drivers/gpio/gpiolib.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**pinctrl** 管理 SoC 引脚的多功能复用（GPIO/I2C/SPI/UART 等），**GPIO** 是通用输入输出接口。

---

## 1. 核心数据结构

### 1.1 pinctrl_dev — 引脚控制器

```c
// drivers/pinctrl/pinctrl.h — pinctrl_dev
struct pinctrl_dev {
    // 设备
    struct device           *dev;           // 设备
    const char              *name;           // 名称

    // 描述符
    struct pinctrl_desc      *desc;          // 描述符

    // 引脚信息
    unsigned int            pin_base;        // 引脚基数
    unsigned int            npins;           // 引脚数
    struct pin_desc         *pins;          // 引脚描述符

    // 引脚组
    struct pin_function     *functions;     // 功能（每个引脚可选择的功能）
    struct pin_group        *groups;        // 组（引脚组）
    struct pinctrl_map      *maps;          // 引脚映射

    // 状态
    void                    *driver_data;   // 驱动私有数据
};
```

### 1.2 pin_desc — 引脚描述

```c
// drivers/pinctrl/pinctrl.h — pin_desc
struct pin_desc {
    const char              *name;           // 引脚名（"GPIO0_A4"）
    struct pinctrl_dev      *pctldev;       // 所属控制器

    // 配置
    unsigned long           *config;        // 引脚配置（MUX 设置等）
    void                    *drv_data;      // 驱动私有数据
};
```

### 1.3 gpio_chip — GPIO 控制器

```c
// include/linux/gpio/driver.h — gpio_chip
struct gpio_chip {
    const char              *label;          // 标签（"gpio0"）
    struct device           *parent;         // 父设备
    struct module           *owner;         // 所属模块

    // 范围
    unsigned int            base;           // GPIO 起始编号（-1 = 动态分配）
    unsigned int            ngpio;           // GPIO 数量
    const char              *const *names;   // GPIO 名称数组

    // 操作函数
    int                     (*direction_input)(struct gpio_chip *, unsigned int);
    int                     (*direction_output)(struct gpio_chip *, unsigned int, int);
    int                     (*get)(struct gpio_chip *, unsigned int);
    void                    (*set)(struct gpio_chip *, unsigned int, int);
    int                     (*to_irq)(struct gpio_chip *, unsigned int);

    // 中断
    int                     (*set_debounce)(struct gpio_chip *, unsigned int, unsigned int);
};
```

---

## 2. GPIO 操作流程

### 2.1 gpio_direction_output

```c
// drivers/gpio/gpiolib.c — gpio_direction_output
int gpio_direction_output(struct gpio_desc *desc, int value)
{
    struct gpio_chip *chip = desc->chip;
    unsigned int offset = gpio_chip_offset(desc);

    // 1. 如果有 pinctrl，确保引脚复用为 GPIO
    pinctrl_gpio_request(gpio);

    // 2. 设置方向为输出
    ret = chip->direction_output(chip, offset, value);

    // 3. 设置初始值
    chip->set(chip, offset, value);

    // 4. 解锁
    pinctrl_gpio_free(gpio);
}
```

---

## 3. pinctrl 与 GPIO 的关系

```c
// 引脚复用：
//   Pin X 可以是 GPIO、I2C_SDA、UART_RX 等
//   pinctrl 子系统负责选择功能
//   GPIO 子系统负责通用输入输出

// 示例（设备树）：
//   &pinctrl {
//       i2c0_pins: i2c0-pins {
//           pins = "GPIO0_A4", "GPIO0_A5";  // 引脚名
//           function = "i2c0";               // 选择 i2c0 功能
//       };
//   };

// GPIO 使用前必须：
//   1. pinctrl_select_state(state);  // 设置引脚为 GPIO 模式
//   2. gpio_request(gpio);          // 申请 GPIO
//   3. gpio_direction_output(gpio);  // 设置方向
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/pinctrl/pinctrl.h` | `struct pinctrl_dev`、`struct pin_desc` |
| `drivers/gpio/gpiolib.c` | `gpio_direction_output`、`gpio_chip` |
| `include/linux/gpio/driver.h` | `struct gpio_chip` |