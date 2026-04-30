# I2C / SPI — 串行外设总线深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/i2c/i2c-core.c` + `drivers/spi/spi.c`）
> 工具： doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**I2C**（Inter-Integrated Circuit，两线总线）和 **SPI**（Serial Peripheral Interface，四线总线）是嵌入式系统最常用的外设通信协议。

| 特性 | I2C | SPI |
|------|-----|-----|
| 线数 | 2（SDA + SCL）| 4+（MOSI/MISO/SCK/SS）|
| 速度 | up to 5 Mbps（Fast Mode+）| up to 100+ Mbps |
| 从设备寻址 | 地址（7/10 位）| 片选线 |
| 双工 | 半双工 | 全双工 |
| 协议复杂度 | 高（_start/_stop/ACK）| 低（移位）|

---

## 1. I2C 总线

### 1.1 i2c_adapter — I2C 适配器（主机控制器）

```c
// drivers/i2c/i2c-core.c — i2c_adapter
struct i2c_adapter {
    struct module           *owner;
    const char              *name;          // 适配器名（"i2c-0"）
    unsigned int            algo_type;      // 算法类型

    // 核心算法
    const struct i2c_algorithm *algo;       // I2C 通信算法
    void                   *algo_data;      // 算法私有数据

    // 总线编号
    int                     bus_num;         // 总线号（i2c-0、i2c-1）
    int                     nr;              // 别名

    // 锁
    struct rt_mutex         bus_lock;       // 总线锁
    struct rt_mutex         smbus_lock;     // SMBus 锁

    // 设备树
    struct device_node      *dev_node;      // 设备节点
    struct device           dev;             // 设备
};
```

### 1.2 i2c_algorithm — I2C 通信算法

```c
// drivers/i2c/i2c-core.c — i2c_algorithm
struct i2c_algorithm {
    // 主发送（master_xfer）
    int (*master_xfer)(struct i2c_adapter *adap, struct i2c_msg *msgs, int num);
    int (*master_xfer_atomic)(struct i2c_adapter *adap, struct i2c_msg *msgs, int num);

    // SMBus 协议（兼容 I2C）
    int (*smbus_xfer)(struct i2c_adapter *adap, u16 addr,
                      unsigned short flags, char read_write,
                      u8 command, int size, union i2c_smbus_data *data);

    // 能力
    u32 (*functionality)(struct i2c_adapter *adap);
};
```

### 1.3 i2c_msg — I2C 消息

```c
// include/uapi/linux/i2c.h — i2c_msg
struct i2c_msg {
    __u16 addr;          // 从设备地址（7 位或 10 位）
    __u16 flags;         // 标志
    #define I2C_M_RD             0x0001  // 读（vs 写）
    #define I2C_M_TEN             0x0010  // 10 位地址
    #define I2C_M_STOP           0x8000  // 发送 STOP
    #define I2C_M_NOSTART         0x4000  // 无 START

    __u16 len;           // 数据长度（字节）
    __u8  *buf;          // 数据缓冲区
};
```

### 1.4 I2C 传输流程

```c
// drivers/i2c/i2c-core.c — i2c_transfer
int i2c_transfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num)
{
    int ret;

    // 1. 验证适配器支持
    if (adap->algo->master_xfer == NULL)
        return -EOPNOTSUPP;

    // 2. 加锁
    rt_mutex_lock(&adap->bus_lock);

    // 3. 调用算法
    ret = adap->algo->master_xfer(adap, msgs, num);

    // 4. 解锁
    rt_mutex_unlock(&adap->bus_lock);

    return ret;
}

// 内部流程（主机侧）：
// START → addr+RW → ACK → data → ACK → ... → STOP
```

---

## 2. SPI 总线

### 2.1 spi_master — SPI 主机控制器

```c
// drivers/spi/spi.c — spi_master
struct spi_master {
    struct device           dev;             // 设备

    // 总线编号
    int                     bus_num;         // 总线号

    // 片选
    unsigned int            num_chipselect;  // 可用片选数

    // 模式
    u16                     mode;            // SPI_MODE_*
    //   SPI_MODE_0 = 0   // CPOL=0, CPHA=0
    //   SPI_MODE_1 = 1   // CPOL=0, CPHA=1
    //   SPI_MODE_2 = 2   // CPOL=1, CPHA=0
    //   SPI_MODE_3 = 3   // CPOL=1, CPHA=1
    //   SPI_CS_HIGH      // 片选高电平
    //   SPI_LSB_FIRST    // 低位在前
    //   SPI_3WIRE        // 三线模式
    //   SPI_NO_CS        // 无片选

    // 速度
    u32                     max_speed_hz;    // 最大时钟（Hz）
    u32                     min_speed_hz;    // 最小时钟

    // 字宽
    u8                      bits_per_word;  // 每字位数（8/16/32）

    // 传输函数
    int (*transfer)(struct spi_device *spi, struct spi_message *mesg);
    int (*transfer_one)(struct spi_master *master, struct spi_device *spi,
                        struct spi_transfer *xfer);

    // DMA
    bool                    can_dma;         // 支持 DMA
};
```

### 2.2 spi_device — SPI 设备

```c
// drivers/spi/spi.c — spi_device
struct spi_device {
    struct device           dev;             // 设备
    struct spi_master       *master;         // 主机控制器
    u32                     max_speed_hz;    // 最大时钟
    u8                      chip_select;     // 片选号
    u8                      bits_per_word;   // 每字位数
    u16                     mode;            // 模式（SPI_MODE_*）

    // 板级信息
    const char              *modalias;       // 驱动名
    int                     irq;             // 中断号
    struct spi_board_info   *controller_data; // 板级数据
};
```

### 2.3 spi_transfer — SPI 传输

```c
// drivers/spi/spi.c — spi_transfer
struct spi_transfer {
    // 数据
    const void              *tx_buf;          // 发送缓冲（NULL = 发送 0xFF）
    void                    *rx_buf;          // 接收缓冲（NULL = 丢弃）
    unsigned int            len;              // 长度（字节）

    // 参数覆盖
    unsigned int            speed_hz;          // 速度覆盖
    u16                     bits_per_word;    // 字宽覆盖
    bool                    cs_change:1;      // 片选变化标志
    bool                    tx_nbits:3;       // 发送位数（1/2/4）
    bool                    rx_nbits:3;       // 接收位数（1/2/4）

    // 链表
    struct list_head        transfer_list;     // 接入 message
};
```

### 2.4 spi_message — SPI 消息

```c
// drivers/spi/spi.c — spi_message
struct spi_message {
    struct list_head        transfers;         // transfer 链表
    unsigned int           num_transfers;      // transfer 数量

    // 状态
    int                     status;            // 结果（0 = 成功）
    struct spi_transfer    *state;            // 内部状态

    // 完成回调
    void                    (*complete)(void *context);
    void                    *context;
};
```

---

## 3. I2C/SPI 设备驱动模型

### 3.1 I2C 设备注册

```c
// drivers/i2c/i2c-core.c — i2c_new_client_device
struct i2c_client *i2c_new_client_device(struct i2c_adapter *adap,
                                          struct i2c_board_info const *info)
{
    // 1. 分配 client
    struct i2c_client *client;
    client = kzalloc(sizeof(*client), GFP_KERNEL);

    // 2. 初始化
    client->adapter = adap;
    client->addr = info->addr;           // I2C 地址
    client->flags = info->flags;
    strlcpy(client->name, info->type, sizeof(client->name));

    // 3. 绑定驱动
    device_register(&client->dev);

    return client;
}
```

### 3.2 SPI 设备注册

```c
// drivers/spi/spi.c — spi_new_device
struct spi_device *spi_new_device(struct spi_master *master,
                                   struct spi_board_info *chip)
{
    struct spi_device *spi;

    // 1. 分配 device
    spi = spi_alloc_device(master);

    // 2. 初始化
    spi->chip_select = chip->chip_select;
    spi->max_speed_hz = chip->max_speed_hz;
    spi->mode = chip->mode;
    spi->bits_per_word = chip->bits_per_word;

    // 3. 注册
    device_register(&spi->dev);

    return spi;
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/i2c/i2c-core.c` | `i2c_adapter`、`i2c_algorithm`、`i2c_msg`、`i2c_transfer` |
| `drivers/spi/spi.c` | `spi_master`、`spi_device`、`spi_transfer`、`spi_message` |
| `include/uapi/linux/i2c.h` | `i2c_msg` 结构体定义 |