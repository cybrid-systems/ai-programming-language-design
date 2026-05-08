# 73-pinctrl-gpio — Linux Pin Control 子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-08 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Pin Control（pinctrl）子系统**是 Linux 内核中管理 **SoC 引脚复用**（pinmux）和 **引脚配置**（pinconf）的核心框架。它解决了嵌入式 SoC 中一个常见问题：芯片引脚需要根据外设功能动态切换（例如：同一个物理引脚既可作为 UART TX，也可作为 GPIO）。

**核心抽象**：

```
引脚（Pin）→ 组（Group）→ 功能（Function）
  ↓              ↓               ↓
物理引脚号     一组引脚         某某外设功能
                （如 SPI0 数据线集）（如 uart0, spi0, i2c1）
```

**三个操作平面**：

| 子系统 | 作用 | 回调 |
|--------|------|------|
| **pinctrl** | 引脚分组、DT 映射解析 | `struct pinctrl_ops` |
| **pinmux** | 引脚功能复用选择 | `struct pinmux_ops` |
| **pinconf** | 引脚电气配置（上拉/下拉/驱动强度） | `struct pinconf_ops` |

**架构位置**：`drivers/pinctrl/core.c`（核心框架）+ `drivers/pinctrl/pinmux.c`（复用层）+ `drivers/pinctrl/pinconf.c`（配置层），每个 SoC 厂商提供自己的底层驱动。

---

## 1. 核心数据结构

### 1.1 struct pinctrl_dev — 引脚控制器设备

```c
// drivers/pinctrl/core.h:52
struct pinctrl_dev {
    struct list_head node;                  /* 全局链表节点 */
    const struct pinctrl_desc *desc;        /* 硬件描述符 */
    struct radix_tree_root pin_desc_tree;   /* 所有引脚的描述树 */
    struct radix_tree_root pin_group_tree;  /* 所有引脚组的树 */
    unsigned int num_groups;
    struct radix_tree_root pin_function_tree; /* 所有功能的树 */
    unsigned int num_functions;
    struct list_head gpio_ranges;            /* GPIO 地址范围链表 */
    struct device *dev;
    struct module *owner;
    void *driver_data;
    struct pinctrl *p;                       /* 当前 pin state */
    struct pinctrl_state *hog_default;
    struct pinctrl_state *hog_sleep;
    struct mutex mutex;
};
```

核心设计：所有引脚、组、功能通过 **radix_tree** 索引，支持 O(log n) 查找。GPIO 范围通过链表挂接，用于 pin↔GPIO 号的相互翻译。

### 1.2 struct pinctrl_desc — 硬件描述符

```c
// include/linux/pinctrl/pinctrl.h:151
struct pinctrl_desc {
    const char *name;
    const struct pinctrl_pin_desc *pins;     /* 引脚定义数组 */
    unsigned int npins;
    const struct pinctrl_ops *pctlops;       /* 核心操作 */
    const struct pinmux_ops *pmxops;         /* 复用操作（可选）*/
    const struct pinconf_ops *confops;       /* 配置操作（可选）*/
    struct module *owner;
    unsigned int num_custom_params;
    const struct pinconf_generic_params *custom_params;
    bool link_consumers;
};
```

**关键设计**：pinctrl 驱动通过填充这个结构体 &rarr; 调用 `pinctrl_register()` 注册到框架。框架不关心底层硬件细节，只通过 ops 接口调用驱动回调。

### 1.3 struct pinctrl_ops — 引脚分组操作

```c
// include/linux/pinctrl/pinctrl.h:109
struct pinctrl_ops {
    int (*get_groups_count)(struct pinctrl_dev *pctldev);
    const char *(*get_group_name)(struct pinctrl_dev *pctldev,
                                  unsigned int selector);
    int (*get_group_pins)(struct pinctrl_dev *pctldev,
                          unsigned int selector,
                          const unsigned int **pins,
                          unsigned int *num_pins);
    void (*pin_dbg_show)(struct pinctrl_dev *pctldev,
                         struct seq_file *s, unsigned int offset);
    int (*dt_node_to_map)(struct pinctrl_dev *pctldev,
                          struct device_node *np_config,
                          struct pinctrl_map **map,
                          unsigned int *num_maps);
    void (*dt_free_map)(struct pinctrl_dev *pctldev,
                        struct pinctrl_map *map,
                        unsigned int num_maps);
};
```

### 1.4 struct pinmux_ops — 引脚复用操作

```c
// include/linux/pinctrl/pinmux.h:69
struct pinmux_ops {
    int (*request)(struct pinctrl_dev *pctldev, unsigned int offset);
    int (*free)(struct pinctrl_dev *pctldev, unsigned int offset);
    int (*get_functions_count)(struct pinctrl_dev *pctldev);
    const char *(*get_function_name)(struct pinctrl_dev *pctldev,
                                     unsigned int selector);
    int (*get_function_groups)(struct pinctrl_dev *pctldev,
                               unsigned int selector,
                               const char * const **groups,
                               unsigned int *num_groups);
    int (*set_mux)(struct pinctrl_dev *pctldev,
                   unsigned int func_selector,
                   unsigned int group_selector);     /* 核心！设置复用 */
    int (*gpio_request_enable)(struct pinctrl_dev *pctldev,
                               struct pinctrl_gpio_range *range,
                               unsigned int offset);
    void (*gpio_disable_free)(struct pinctrl_dev *pctldev,
                              struct pinctrl_gpio_range *range,
                              unsigned int offset);
    int (*gpio_set_direction)(struct pinctrl_dev *pctldev,
                              struct pinctrl_gpio_range *range,
                              unsigned int offset, bool input);
    bool strict;    /* 严格模式：禁止用户空间同时使用同一引脚 */
};
```

**关键点**：`set_mux` 是 pinmux 的核心回调——它告诉 SoC 硬件将 `group_selector` 这组引脚切换到 `func_selector` 所代表的功能。

### 1.5 struct pinconf_ops — 引脚配置操作

```c
// include/linux/pinctrl/pinconf.h:38
struct pinconf_ops {
    bool is_generic;
    int (*pin_config_get)(struct pinctrl_dev *pctldev,
                          unsigned int pin, unsigned long *config);
    int (*pin_config_set)(struct pinctrl_dev *pctldev,
                          unsigned int pin,
                          unsigned long *configs,
                          unsigned int num_configs);
    int (*pin_config_group_get)(struct pinctrl_dev *pctldev,
                                unsigned int selector,
                                unsigned long *config);
    int (*pin_config_group_set)(struct pinctrl_dev *pctldev,
                                unsigned int selector,
                                unsigned long *configs,
                                unsigned int num_configs);
    /* ... debug hooks ... */
};
```

### 1.6 struct pinctrl_gpio_range — GPIO 地址映射

```c
// include/linux/pinctrl/pinctrl.h:79
struct pinctrl_gpio_range {
    struct list_head node;
    const char *name;
    unsigned int id;
    unsigned int base;          /* GPIO 号起始 */
    unsigned int pin_base;      /* 对应的 pin 号起始 */
    unsigned int npins;
    unsigned int const *pins;   /* 显式映射表（可选）*/
    struct gpio_chip *gc;
};
```

**核心作用**：建立 `GPIO 号 → pin 号` 的映射。当 GPIO 子系统请求某个 GPIO 时，pinctrl 通过 `pinctrl_find_gpio_range_from_pin()`（core.c:515）找到对应的 range，进而获取底层 pin 号以配置复用。

---

## 2. 注册流程

### 2.1 pinctrl_register @ core.c:2246

```c
// drivers/pinctrl/core.c:2246
struct pinctrl_dev *pinctrl_register(const struct pinctrl_desc *pctldesc,
                                     struct device *dev, void *driver_data)
{
    pctldev = pinctrl_init_controller(pctldesc, dev, driver_data);
    error = pinctrl_enable(pctldev);
    return pctldev;
}
```

两步走：
1. `pinctrl_init_controller()` → 分配 `struct pinctrl_dev`，注册 pin 描述符到 radix_tree
2. `pinctrl_enable()` → 添加到全局列表 + claim hogs + debugfs 初始化

### 2.2 pinctrl_init_controller — 控制器初始化

```c
// drivers/pinctrl/core.c:188
static int pinctrl_register_one_pin(struct pinctrl_dev *pctldev,
                                    const struct pinctrl_pin_desc *pin)
{
    pindesc = kzalloc_obj(*pindesc);       /* 分配 pin_desc */
    pindesc->pctldev = pctldev;             /* 反向引用 */
    pindesc->name = pin->name ?: kasprintf("PIN%u", pin->number);

    radix_tree_insert(&pctldev->pin_desc_tree,
                      pin->number, pindesc);
}
```

每个 pin 通过 radix tree 索引。`pinctrl_register_pins()`（core.c:256）遍历 `pinctrl_desc.pins[]` 逐个调用 `pinctrl_register_one_pin`。

### 2.3 pinctrl_enable @ core.c:2217

```c
// drivers/pinctrl/core.c:2217
int pinctrl_enable(struct pinctrl_dev *pctldev)
{
    error = pinctrl_claim_hogs(pctldev);    /* 应用 hog 状态 */
    list_add_tail(&pctldev->node, &pinctrldev_list);  /* 挂入全局列表 */
    pinctrl_init_device_debugfs(pctldev);   /* debugfs 入口 */
}
```

### 2.4 pinctrl_claim_hogs @ core.c:2179

将 pinctrl 控制器自身的默认引脚状态（如 sleep 模式的默认引脚配置）应用到硬件。

### 2.5 devm_pinctrl_register @ core.c:2354

```c
// drivers/pinctrl/core.c:2354
struct pinctrl_dev *devm_pinctrl_register(struct device *dev, ...)
{
    pctldev = pinctrl_register(pctldesc, dev, driver_data);
    devm_add_action_or_reset(dev, devm_pinctrl_dev_release, pctldev);
    return pctldev;
}
```

资源管理版本——设备解绑时自动注销。

### 注册流程图

```
pinctrl_register(pctldesc, dev, driver_data)   @ core.c:2246
    │
    ├─▶ pinctrl_init_controller()              @ core.c:188
    │       │
    │       ├─ kzalloc: struct pinctrl_dev
    │       ├─ radix_tree_init: pin_desc_tree
    │       ├─ pinctrl_register_pins()         @ core.c:256
    │       │   └─ for each pin: radix_tree_insert(pin_desc_tree)
    │       └─ pinctrl_init_device_debugfs()
    │
    └─▶ pinctrl_enable()                       @ core.c:2217
            │
            ├─ pinctrl_claim_hogs()            @ core.c:2179
            ├─ list_add_tail(&node, &pinctrldev_list)
            └─ pinctrl_init_device_debugfs()
```

---

## 3. Pinmux——引脚功能复用

### 3.1 验证机制 @ pinmux.c:42

```c
// drivers/pinctrl/pinmux.c:42
static int pinmux_ops_check(const struct pinmux_ops *ops)
{
    if (!ops->get_functions_count ||
        !ops->get_function_name ||
        !ops->get_function_groups ||
        !ops->set_mux) {
        dev_err(..., "pinmux ops lacks necessary functions\n");
        return -EINVAL;
    }
}
```

框架验证驱动至少实现了 4 个核心回调才允许注册。

### 3.2 应用 pinmux——pinctrl_select_state

当设备驱动请求 pin 状态时，框架：

```
pinctrl_select_state()              @ core.c:1300
    │
    ├─ 遍历 state→settings[]
    ├─ for each setting:
    │   ├─ 类型 = PIN_MAP_TYPE_MUX_GROUP:
    │   │   ├─ pinmux_enable_setting()
    │   │   │   ├─ ops->request()          # 预留引脚
    │   │   │   ├─ ops->set_mux(func, grp) # 切换到目标功能
    │   │   │   └─ ops->free()             # 释放旧功能
    │   │   └─ 更新 pctldev→p 指针
    │   │
    │   └─ 类型 = PIN_MAP_TYPE_CONFIGS_GROUP:
    │       └─ pinconf_apply_setting()
    │           └─ ops->pin_config_group_set()
    │
    └─ pinctrl_free_setting() 如果失败
```

### 3.3 GPIO 与 pinmux 的协作

当 GPIO 子系统需要某个引脚时，gpiolib 调用 pinctrl：

```
gpio_request() → gpiod_request()
    ↓
gpiochip_request_own_desc() 或 gpiod_request()
    ↓
gpiod_configure_flags()
    ↓
pinctrl_gpio_request(gpio_chip, offset)
    ↓
pinctrl_find_gpio_range_from_pin()          @ core.c:515
    → 找到 gpio_range
    → 映射 offset → pin 号
    ↓
pmxops->gpio_request_enable(pctldev, range, offset)  @ SoC 驱动
    → 将引脚从当前功能切换到 GPIO 模式
```

---

## 4. Pinconf——引脚配置

Pinconf 管理引脚的电气属性，通过 `pinconf_generic_params[]` 实现通用配置接口。

### 常见的通用参数

| 参数 | 作用 | linux/pinctrl/pinconf-generic.h |
|------|------|------|
| `PIN_CONFIG_BIAS_DISABLE` | 禁用上下拉 |
| `PIN_CONFIG_BIAS_PULL_UP` | 上拉 |
| `PIN_CONFIG_BIAS_PULL_DOWN` | 下拉 |
| `PIN_CONFIG_DRIVE_STRENGTH` | 驱动强度（mA） |
| `PIN_CONFIG_INPUT_ENABLE` | 使能输入 |
| `PIN_CONFIG_SLEW_RATE` | 压摆率 |
| `PIN_CONFIG_MODE_LOW_POWER` | 低功耗模式 |

配置通过 DT 的 `pinctrl-0` 属性定义，解析后经 `pin_config_set` 回调写入 SoC 寄存器。

---

## 5. Device Tree 集成

典型的 pinctrl DT 节点：

```dts
&pinctrl {
    uart0_default: uart0-default {
        pinmux {
            function = "uart0";
            groups = "uart0_tx", "uart0_rx";
        };
        pinconf {
            pins = "GPIO0", "GPIO1";
            bias-pull-up;
            drive-strength = <2>;   /* mA */
        };
    };
};

&uart0 {
    pinctrl-names = "default", "sleep";
    pinctrl-0 = <&uart0_default>;
    pinctrl-1 = <&uart0_sleep>;
};
```

DT 解析流程：

```
pinctrl_dt_to_map()                     → ops->dt_node_to_map()
    ↓
pinctrl_register_map()                   → 创建 setting
    ↓
pinctrl_select_state("default")          → 应用
    │
    ├─ pinmux: set_mux(func, group)     → 硬件复用
    └─ pinconf: pin_config_group_set()  → 写入寄存器
```

---

## 6. GPIO 子系统协作

pinctrl 与 gpiolib 通过 `pinctrl_add_gpio_range()`（core.c:427）建立映射：

```c
// drivers/pinctrl/core.c:427
void pinctrl_add_gpio_range(struct pinctrl_dev *pctldev,
                            struct pinctrl_gpio_range *range)
{
    mutex_lock(&pctldev->mutex);
    list_add_tail(&range->node, &pctldev->gpio_ranges);
    mutex_unlock(&pctldev->mutex);
}
```

gpiolib 中的 pinmux 集成（`gpiolib.c`）：

```
gpiochip_add_data()
    └─ if (gc->can_sleep && gc->request)
            gc->request(gc, offset)                # 驱动自定义
       else
            pinctrl_gpio_request(gc, offset)       # 框架默认
```

`pmxops->strict` 标志控制严格模式——如果为 true，则不允许一个引脚同时被 pinmux 和 GPIO 使用。

---

## 7. 调试接口—debugfs

pinctrl 在 debugfs 下提供三个入口（`core.c:pinctrl_init_debugfs`）：

```
/sys/kernel/debug/pinctrl/
├── pinctrl-devices    → 所有已注册的 pinctrl 设备
├── pinctrl-maps       → 所有 pin 状态映射表
└── pinctrl-handles    → 当前 active 的 pin state 句柄
```

每个 pinctrl 设备的 debugfs 目录：
```
/sys/kernel/debug/pinctrl/<device-name>/
├── pins                  → 所有引脚及当前配置
├── pinmux-pins           → 引脚当前复用功能
├── pinmux-functions      → 所有可用的功能列表
├── pinconf-pins          → 引脚配置
├── pinconf-groups        → 组配置
├── pinmux-selectors      → 当前选择器
└── pinctrl-gpioranges    → GPIO 地址范围
```

---

## 8. 典型 SoC 驱动示例

### 8.1 框架驱动注册模板

```c
static const struct pinctrl_ops foo_pctlops = {
    .get_groups_count = foo_get_groups_count,
    .get_group_name   = foo_get_group_name,
    .get_group_pins   = foo_get_group_pins,
    .dt_node_to_map   = pinconf_generic_dt_node_to_map_pin,
    .dt_free_map      = pinconf_generic_dt_free_map,
};

static const struct pinmux_ops foo_pmxops = {
    .request           = foo_pmx_request,
    .free              = foo_pmx_free,
    .get_functions_count = foo_pmx_get_funcs_count,
    .get_function_name = foo_pmx_get_func_name,
    .get_function_groups = foo_pmx_get_func_groups,
    .set_mux           = foo_pmx_set_mux,        /* 写入硬件寄存器 */
    .gpio_request_enable = foo_gpio_request_enable,
    .gpio_set_direction  = foo_gpio_set_direction,
    .strict            = true,
};

static const struct pinconf_ops foo_confops = {
    .pin_config_group_set = foo_pinconf_group_set,
    .is_generic        = true,
};

static struct pinctrl_desc foo_pinctrl_desc = {
    .name     = "foo-pinctrl",
    .pins     = foo_pins,
    .npins    = ARRAY_SIZE(foo_pins),
    .pctlops  = &foo_pctlops,
    .pmxops   = &foo_pmxops,
    .confops  = &foo_confops,
    .owner    = THIS_MODULE,
};

static int foo_pinctrl_probe(struct platform_device *pdev)
{
    return PTR_ERR_OR_ZERO(
        devm_pinctrl_register_and_init(&pdev->dev, &foo_pinctrl_desc,
                                       pdev, &pctldev));
    /* 注意：注册后还需调用 pinctrl_enable() */
}
```

### 8.2 set_mux 硬件操作模式

底层的 `set_mux` 回调通常做三件事：

```
foo_pmx_set_mux(pctldev, func_selector, group_selector)
    │
    1. func_groups = ops->get_function_groups(func_selector)
       → 获取该功能涉及的所有组
    
    2. for each group:
       group_pins = ops->get_group_pins(group_selector)
       → 获取该组涉及的所有物理引脚
    
    3. for each pin:
       writel(PINMUX_MODE_VAL(func) << pin_offset,
              base_reg + pin_mux_offset[pin])
       → 写入 SoC 引脚复用寄存器
```

不同的 SoC 在第三步的实现差异很大（寄存器布局、MUX 位数、功能编码各不相同），这就是为什么每个 SoC 需要自己的 pinctrl 驱动。

---

## 9. 总结

pinctrl 是 SoC 引脚管理的核心抽象层：

| 概念 | 实现 | 源码位置 |
|------|------|---------|
| **控制器注册** | `pinctrl_register` | `core.c:2246` |
| **引脚管理** | radix_tree 索引，动态命名 | `core.c:206` |
| **复用选择** | `set_mux` 回调 → SoC 寄存器 | `pinmux.c` |
| **配置设置** | `pin_config_set` 回调 | `pinconf.c` |
| **GPIO 集成** | gpio_range 映射 + gpio_request_enable | `core.c:427` |
| **DT 解析** | `dt_node_to_map` → `pinctrl_select_state` | `core.c:1300` |
| **调试** | debugfs 三层 + 每设备目录 | `core.c:pinctrl_init_debugfs` |
| **资源管理** | devm_pinctrl_register 自动注销 | `core.c:2354` |

**系统调用链（以设备 probe 为例）**：

```
platform_driver.probe()
    ↓
of_pinctrl_select_default() / devm_pinctrl_get_select_default()
    ↓
pinctrl_select_state()                  @ core.c:1300
    ├─ pinmux_enable_setting()
    │   └─ pmxops->set_mux(func, grp)   → 硬件复用切换
    └─ pinconf_apply_setting()
        └─ confops->pin_config_group_set() → 寄存器写入
    ↓
设备开始使用目标功能（UART/SPI/I2C...）
```

---

### 源码索引（LSP 验证）

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct pinctrl_dev` | drivers/pinctrl/core.h | 52 |
| `struct pinctrl_desc` | include/linux/pinctrl/pinctrl.h | 151 |
| `struct pinctrl_ops` | include/linux/pinctrl/pinctrl.h | 109 |
| `struct pinmux_ops` | include/linux/pinctrl/pinmux.h | 69 |
| `struct pinconf_ops` | include/linux/pinctrl/pinconf.h | 38 |
| `struct pinctrl_gpio_range` | include/linux/pinctrl/pinctrl.h | 79 |
| `pinctrl_register_one_pin()` | drivers/pinctrl/core.c | 206 |
| `pinctrl_register_pins()` | drivers/pinctrl/core.c | 256 |
| `pinctrl_register()` | drivers/pinctrl/core.c | 2246 |
| `pinctrl_enable()` | drivers/pinctrl/core.c | 2217 |
| `pinctrl_claim_hogs()` | drivers/pinctrl/core.c | 2179 |
| `devm_pinctrl_register()` | drivers/pinctrl/core.c | 2354 |
| `pinctrl_select_state()` | drivers/pinctrl/core.c | ~1300 |
| `pinctrl_add_gpio_range()` | drivers/pinctrl/core.c | 427 |
| `pinctrl_find_gpio_range_from_pin()` | drivers/pinctrl/core.c | 515 |
| `pinctrl_gpio_request()` | drivers/pinctrl/core.c | ~306 |
| `pinmux_ops_check()` | drivers/pinctrl/pinmux.c | ~42 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-08 | 内核版本：Linux 7.0-rc1*
