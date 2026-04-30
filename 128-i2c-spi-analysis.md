# Linux Kernel I2C / SPI 总线 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/i2c/` + `drivers/spi/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：i2c_adapter、i2c_msg、spi_master、spi_device、bitbang

---

## 1. I2C 核心数据结构

### 1.1 i2c_adapter — I2C 总线适配器

```c
// drivers/i2c/i2c-core.h — i2c_adapter
struct i2c_adapter {
    struct module               *owner;           // 所属模块
    const char                  *name;             // 适配器名（如 "SMBus I801 adapter"）
    unsigned int                class;              // 支持的 I2C 类

    // 通信算法（SMBus / I2C）
    const struct i2c_algorithm *algo;              // 行 72

    // 总线锁
    struct rt_mutex             bus_lock;          // 行 74

    // 标志
    int                         nr;                 // 总线编号
    u32                        功能;               // I2C_FUNC_* 标志
};
```

### 1.2 i2c_algorithm — I2C 通信算法

```c
// drivers/i2c/i2c-core.h — i2c_algorithm
struct i2c_algorithm {
    // 主机发送/接收（SMBus）
    int (*master_xfer)(struct i2c_adapter *adap, struct i2c_msg *msgs, int num);
    int (*master_xfer_atomic)(...);

    // SMBus 传输
    int (*smbus_xfer)(struct i2c_adapter *adap, u16 addr,
              unsigned short flags, char read_write, u8 command,
              int size, union i2c_smbus_data *data);

    // 功能
    u32 (*functionality)(struct i2c_adapter *adap);
};
```

### 1.3 i2c_msg — I2C 消息

```c
// include/uapi/linux/i2c.h — i2c_msg
struct i2c_msg {
    __u16 addr;     // 从设备地址（7-bit 或 10-bit）
    __u16 flags;    // 标志
    #define I2C_M_RD        0x0001   // 读（否则写）
    #define I2C_M_TEN       0x0010   // 10-bit 地址
    #define I2C_M_STOP      0x8000   // 发送 STOP

    __u16 len;      // 数据长度（字节）
    __u8  *buf;     // 数据缓冲区
};
```

---

## 2. I2C 传输流程

```c
// drivers/i2c/i2c-core.c — i2c_transfer
int i2c_transfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num)
{
    int ret;

    // 1. 调用 adapter 的 master_xfer
    if (adap->algo->master_xfer) {
        // 遍历所有消息
        for (ret = 0; ret < num; ret++) {
            ret = adap->algo->master_xfer(adap, &msgs[ret], 1);
            if (ret < 0)
                return ret;
        }
        return num;
    }
    return -ENODEV;
}
```

---

## 3. SPI 核心数据结构

### 3.1 spi_master — SPI 主机控制器

```c
// drivers/spi/spi.c — spi_master
struct spi_master {
    // 总线编号
    int                   bus_num;        // 行 340

    // 片选数量
    int                   num_chipselect; // 行 343

    // 最高时钟频率
    u32                   max_speed_hz;   // 行 346

    // 每字位数（通常 8）
    u8                   bits_per_word;   // 行 349

    // 标志
    u16                  mode;            // 行 352

    // 传输函数
    int (*transfer_one)(struct spi_controller *ctlr, struct spi_device *spi,
                struct spi_transfer *transfer);

    // DMA 支持
    bool                  can_dma;

    // 片选管理
    void (*set_cs)(struct spi_device *spi, bool enable);
};
```

### 3.2 spi_device — SPI 设备

```c
// drivers/spi/spi.c — spi_device
struct spi_device {
    struct spi_master   *master;            // 主机控制器
    u32                 max_speed_hz;       // 最大时钟频率
    u8                  chip_select;         // 片选号
    u8                  bits_per_word;       // 每字位数
    u16                 mode;               // SPI_MODE_*（相位、极性）
    int                 irq;                // 中断号
    void               *controller_state;    // 控制器私有状态
    void               *controller_data;    // 设备特定数据
    const char          *modalias;           // 驱动名
};
```

### 3.3 spi_transfer — 单次传输

```c
// drivers/spi/spi.c — spi_transfer
struct spi_transfer {
    const void *tx_buf;          // 发送缓冲区
    void       *rx_buf;          // 接收缓冲区
    int        len;             // 长度

    dma_addr_t tx_dma;           // DMA 地址
    dma_addr_t rx_dma;

    // 时钟频率（可覆盖 device 设置）
    u32         speed_hz;

    // 片选延迟
    u16         cs_change_delay;
    u16         delay_usecs;

    // 下一个传输（链表）
    struct list_head transfer_list;
};
```

---

## 4. SPI 传输流程

```c
// drivers/spi/spi.c — spi_sync
int spi_sync(struct spi_device *spi, struct spi_message *message)
{
    // 1. 初始化消息
    spi_message_init(message);

    // 2. 添加传输
    spi_message_add_tail(transfer, message);

    // 3. 同步传输
    return spi_sync_transfer(spi, message);
}

// drivers/spi/spi.c — spi_sync_transfer
static int spi_sync_transfer(struct spi_device *spi, struct spi_message *message)
{
    // 调用 master->transfer_one()
    return master->transfer_one(master, spi, transfer);
}
```

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `drivers/i2c/i2c-core.c` | I2C 适配器核心 |
| `include/uapi/linux/i2c.h` | `struct i2c_msg` |
| `drivers/spi/spi.c` | SPI 核心 |
| `include/linux/spi/spi.h` | `struct spi_master`、`struct spi_device` |
