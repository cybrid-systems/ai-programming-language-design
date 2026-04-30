# I2C / SPI — 串行总线深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/i2c/i2c-core.c` + `drivers/spi/spi.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**I2C**（Inter-Integrated Circuit）和 **SPI**（Serial Peripheral Interface）是两种常用的串行通信总线，用于连接传感器、EEPROM、显示器等外设。

---

## 1. I2C 核心

### 1.1 i2c_adapter — I2C 适配器

```c
// drivers/i2c/i2c-core.c — i2c_adapter
struct i2c_adapter {
    struct kref           ref;             // 引用计数
    const char           *name;            // 适配器名
    struct i2c_algorithm *algo;           // 算法
    struct rt_mutex       bus_lock;      // 总线锁

    // 设备树
    struct device_node   *dev_node;       // 设备节点
    int                   nr;             // 总线编号
};
```

### 1.2 i2c_msg — I2C 消息

```c
// include/uapi/linux/i2c.h — i2c_msg
struct i2c_msg {
    __u16 addr;          // 从设备地址
    __u16 flags;         // I2C_M_* 标志
    #define I2C_M_RD    0x0001           // 读
    __u16 len;            // 数据长度
    __u8 *buf;           // 数据缓冲
};
```

---

## 2. SPI 核心

### 2.1 spi_device — SPI 设备

```c
// drivers/spi/spi.c — spi_device
struct spi_device {
    struct device           dev;           // 设备
    struct spi_master       *master;        // 主机控制器
    u32                     max_speed_hz;  // 最大时钟
    u8                      chip_select;   // 片选
    u8                      mode;          // SPI_MODE_*
    u8                      bits_per_word; // 每字位数
};
```

### 2.2 spi_transfer — SPI 传输

```c
// drivers/spi/spi.c — spi_transfer
struct spi_transfer {
    const void *tx_buf;     // 发送缓冲
    void       *rx_buf;    // 接收缓冲
    unsigned int len;       // 长度

    unsigned int speed_hz;  // 速度覆盖
};
```

---

## 3. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/i2c/i2c-core.c` | `i2c_adapter`、`i2c_msg` |
| `drivers/spi/spi.c` | `spi_device`、`spi_transfer` |