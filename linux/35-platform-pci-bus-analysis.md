# Linux Kernel Platform Bus 与 PCI Bus 驱动模型深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/base/` + `drivers/pci/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 驱动模型概述

Linux 的设备驱动模型（Driver Model）通过 **bus** → **device** → **driver** 的层次结构统一管理所有设备：

```
bus
 ├── platform bus   → platform_device / platform_driver
 ├── PCI bus       → pci_dev / pci_driver
 ├── USB bus       → usb_device / usb_driver
 ├── I2C bus       → i2c_client / i2c_driver
 └── SPI bus       → spi_device / spi_driver
```

---

## 1. platform_bus — 平台设备

### 1.1 platform_device

```c
// include/linux/platform_device.h — platform_device
struct platform_device {
    const char          *name;           // 设备名（匹配 driver）
    int                 id;              // 设备 ID（-1 = 自动）
    struct device        dev;            // 通用设备结构
    u32                 num_resources;   // 资源数量
    struct resource     *resource;        // I/O 端口、内存、中断

    const struct platform_device_id *id_entry;  // ID 表
};
```

### 1.2 platform_driver

```c
// include/linux/platform_device.h — platform_driver
struct platform_driver {
    int (*probe)(struct platform_device *);   // 匹配时调用
    int (*remove)(struct platform_device *);   // 移除时调用
    void (*shutdown)(struct platform_device *); // 关机时
    int (*suspend)(struct platform_device *, pm_message_t);
    int (*resume)(struct platform_device *);   // 唤醒时

    struct device_driver driver;                // 通用驱动结构
    const struct platform_device_id *id_table;  // 支持的设备 ID 表
};
```

### 1.3 注册流程

```c
// 1. 定义 platform_driver
static struct platform_driver my_driver = {
    .probe = my_probe,
    .remove = my_remove,
    .driver = { .name = "my-device" },
};

// 2. 注册
module_platform_driver(my_driver);

// 内核内部：
// platform_bus_type → platform_match() → driver->probe()
```

---

## 2. PCI Bus

### 2.1 pci_dev

```c
// include/linux/pci.h — pci_dev
struct pci_dev {
    struct list_head      bus_list;       // 接入 PCI 总线
    struct pci_bus        *bus;           // 所属总线
    struct pci_bus        *subordinate;    // 下级总线

    u16                  vendor;           // 厂商 ID
    u16                  device;           // 设备 ID
    u8                   revision;         // 修订号

    struct device        dev;             // 通用设备

    /* BAR（Base Address Register）*/
    struct resource     resource[DEVICE_COUNT_RESOURCE];

    /* 中断 */
    u8                  irq;              // 中断号
    int                 pin;               // 中断引脚

    /* 配置空间 */
    unsigned int        cfg_size;         // 配置空间大小
};
```

### 2.2 pci_driver

```c
// include/linux/pci.h — pci_driver
struct pci_driver {
    const char          *name;
    const struct pci_device_id *id_table;  // 支持的设备 ID 表

    int (*probe)(struct pci_dev *, const struct pci_device_id *);
    void (*remove)(struct pci_dev *);
    int (*suspend)(struct pci_dev *, pm_message_t);
    int (*resume)(struct pci_dev *);
    int (*shutdown)(struct pci_dev *);

    struct device_driver driver;
};
```

### 2.3 PCI 枚举流程

```
系统启动 → PCI BIOS/ACPI 枚举 → pci_scan_bus()
  → 为每个设备分配 pci_dev
  → 读取配置空间 BAR
  → 注册 pci_driver
  → 调用 driver->probe(pci_dev)
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/base/platform.c` | `platform_bus_type`、`platform_match`、`platform_probe` |
| `include/linux/platform_device.h` | `struct platform_device`、`platform_driver` |
| `drivers/pci/pci-driver.c` | `pci_register_driver`、`pci_match_device` |
| `include/linux/pci.h` | `struct pci_dev`、`struct pci_driver` |
