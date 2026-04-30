# Linux Kernel pinctrl / GPIO 子系统 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/pinctrl/` + `drivers/gpio/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. pinctrl 作用

**pinctrl** 管理 SoC **引脚复用**（MUX）和**引脚配置**（上下拉、驱动强度、速率）。

---

## 1. 核心结构

```c
// drivers/pinctrl/core.h — pinctrl_dev
struct pinctrl_dev {
    struct list_head node;
    struct pinctrl_desc   desc;          // 引脚描述符
    struct pinctrl_map    *maps;         // 引脚映射
    struct gpio_chip     *gpio_chip;     // GPIO 控制器
};

// pinctrl_map — 引脚配置映射
struct pinctrl_map {
    const char *dev_name;    // 设备名
    const char *name;        // 配置名（如 "default"、"sleep"）
    enum pinctrl_map_type type;
    ...
};
```

---

## 2. GPIO 操作

```c
// drivers/gpio/gpiolib.c — gpio_chip
struct gpio_chip {
    int (*direction_input)(struct gpio_chip *chip, unsigned offset);
    int (*direction_output)(struct gpio_chip *chip, unsigned offset, int value);
    int (*get)(struct gpio_chip *chip, unsigned offset);
    void (*set)(struct gpio_chip *chip, unsigned offset, int value);
    int base, ngpio;  // GPIO 编号范围 [base, base+ngpio)
};
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/pinctrl/core.c` | pinctrl 核心 |
| `drivers/gpio/gpiolib.c` | GPIO 子系统 |
