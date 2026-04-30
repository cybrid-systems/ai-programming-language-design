# Linux Kernel I2C / SPI 总线 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/i2c/` + `drivers/spi/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 1. I2C — 两线串行总线

```c
// drivers/i2c/i2c-core.c — i2c_adapter
struct i2c_adapter {
    const struct i2c_algorithm *algo;   // 通信算法
    int                      nr;        // 总线编号
    struct rt_mutex          bus_lock;  // 总线锁
};

// i2c_algorithm — I2C 通信协议
struct i2c_algorithm {
    int (*master_xfer)(struct i2c_adapter *adap, struct i2c_msg *msgs, int num);
    int (*smbus_xfer)(...);
};

// i2c_msg — I2C 消息
struct i2c_msg {
    __u16 addr;     // 从设备地址
    __u16 flags;    // I2C_M_RD（读）
    __u16 len;      // 数据长度
    __u8  *buf;     // 数据缓冲区
};
```

---

## 2. SPI — 四线串行总线

```c
// drivers/spi/spi.c — spi_master
struct spi_master {
    int                   bus_num;         // 总线编号
    const struct spi_master_transfer *transfer; // 传输函数
    int                   num_chipselect;   // 片选数量
    // 支持 DMA
    bool                  can_dma;
};

// spi_device — SPI 设备
struct spi_device {
    struct spi_master  *master;            // SPI 主机
    u32                max_speed_hz;       // 最大时钟频率
    u8                 chip_select;         // 片选
    u8                 bits_per_word;       // 每字位数（8/16）
};
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/i2c/i2c-core.c` | I2C 适配器/驱动核心 |
| `drivers/spi/spi.c` | SPI 主机/设备核心 |
