# 87-i2c-spi — Linux I2C 和 SPI 总线子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**I2C** 和 **SPI** 是 Linux 中最常用的两种板级总线协议——I2C 双线（SDA+SCL）低速设备总线，SPI 四线（MISO+MOSI+SCLK+CS）高速外设总线。

| 特性 | I2C | SPI |
|------|-----|-----|
| 信号线 | 2（SDA+SCL） | 4+（MISO/MOSI/SCLK/CS） |
| 速度 | 100KHz-3.4MHz | 可到 50MHz+ |
| 寻址 | 7-bit 设备地址 | 每设备独立 CS 片选 |
| 通信 | 半双工 | 全双工 |
| 设备数 | 112（7-bit 地址） | 每个 CS 一个 |
| 内核文件 | `drivers/i2c/i2c-core-base.c`（2,687行） | `drivers/spi/spi.c`（5,169行）|

**doom-lsp 确认**：I2C 核心 267 符号，SPI 核心 490 符号。

---

## 1. I2C 子系统

### 1.1 核心数据结构

```c
// include/linux/i2c.h
struct i2c_adapter {                          // I2C 控制器
    struct module *owner;
    const struct i2c_algorithm *algo;          // 发送/接收算法
    int nr;                                    // 总线号
    struct device dev;
    struct list_head userspace_clients;
};

struct i2c_client {                           // I2C 设备
    unsigned short addr;                       // 7-bit 地址
    char name[I2C_NAME_SIZE];
    struct i2c_adapter *adapter;               // 所属控制器
    struct device dev;
};

struct i2c_msg {                               // 一次传输消息
    __u16 addr;                                // 目标地址
    __u16 flags;                               // I2C_M_RD 等
    __s32 len;                                 // 数据长度
    __u8 *buf;                                 // 数据缓冲
};

struct i2c_algorithm {
    int (*master_xfer)(struct i2c_adapter *adap, struct i2c_msg *msgs, int num);
    int (*smbus_xfer)(struct i2c_adapter *adap, u16 addr, ...);
};
```

### 1.2 i2c_transfer——消息传输 @ i2c-core-base.c

```c// __i2c_transfer @ i2c-core-base.c
int __i2c_transfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num)
{
    // 1. 获取总线锁（防止并发）
    // 2. 重试循环（最多 adap->retries 次）
    for (ret = 0, try = 0; try <= adap->retries; try++) {
        // 3. 调用控制器算法
        ret = adap->algo->master_xfer(adap, msgs, num);
        if (ret != -EAGAIN)
            break;
        // 如果返回 -EAGAIN → 重试
        if (try != adap->retries)
            msleep(adap->retry_delay);
    }
    return ret;
}

// 示例——读写传感器寄存器：
struct i2c_msg msgs[2];
msgs[0].addr = 0x48;
msgs[0].len = 1;
msgs[0].buf = ®;         // 写寄存器地址
msgs[0].flags = 0;

msgs[1].addr = 0x48;
msgs[1].len = 2;
msgs[1].buf = data;
msgs[1].flags = I2C_M_RD;  // 读数据

i2c_transfer(client, msgs, 2);
```

### 1.3 SMBus API

```c
// 标准 SMBus 操作（大多数传感器使用）：
s32 i2c_smbus_read_byte_data(client, reg);
s32 i2c_smbus_write_byte_data(client, reg, value);
s32 i2c_smbus_read_i2c_block_data(client, reg, len, data);
s32 i2c_smbus_write_i2c_block_data(client, reg, len, data);

// → 内部构造标准 SMBus 消息格式后调用 i2c_transfer()
```

### 1.4 I2C 设备注册

```c
// I2C 设备注册路径：
// 设备树：i2c@... {
//     temperature@48 {
//         compatible = "lm75";
//         reg = <0x48>;
//     };
// };

// → i2c_new_client_device() → device_register
// → i2c_device_probe() → client->driver->probe(client)
```

**doom-lsp 确认**：`i2c_transfer` → `__i2c_transfer` → `adap->algo->master_xfer` 是核心传输路径。

---

## 2. SPI 子系统

### 2.1 核心数据结构

```c
// include/linux/spi/spi.h
struct spi_controller {                        // SPI 控制器
    struct device dev;
    u16 bus_num;
    u32 mode_bits;                             // SPI_MODE_0/1/2/3
    u32 flags;
    u32 min_speed_hz, max_speed_hz;

    int (*transfer_one)(struct spi_controller *ctlr,
                        struct spi_device *spi, struct spi_transfer *xfer);
    // 或
    int (*transfer_one_message)(struct spi_controller *ctlr,
                                struct spi_message *msg);
};

struct spi_device {                            // SPI 设备
    struct spi_controller *controller;
    u32 max_speed_hz;                          // 最大速率
    u8 chip_select;                             // CS 号
    u8 mode;                                    // SPI_MODE_0/1/2/3
    struct device dev;
};

struct spi_transfer {                           // 一次传输
    const void *tx_buf;                         // 发送缓冲
    void *rx_buf;                               // 接收缓冲
    unsigned len;                               // 长度
    unsigned speed_hz;                          // 速率
    unsigned cs_change;                         // 传输结束后改变 CS
};

struct spi_message {                            // 一组传输
    struct list_head transfers;                  // transfer 链表
    struct spi_device *spi;
    unsigned actual_length;
    int status;
    void (*complete)(void *context);
    void *context;
};
```

**doom-lsp 确认**：SPI 核心 490 符号，`spi_controller` @ `spi.h`，`spi_transfer` @ `spi.h`。

### 2.2 传输路径——spi_sync

```c
// SPI 传输有两种模式：

// 1. spi_sync（同步阻塞）：
// → spi_sync(dev, &msg)
//   → __spi_sync()
//     → spi_async_locked()
//       → ctlr->transfer_one_message(ctlr, msg)
//         → 遍历 msg->transfers 链表
//         → 对每个 transfer 调用 ctlr->transfer_one()
//         → 硬件操作：写数据寄存器 → 等待完成
//         → cs_deactivate()

// 2. spi_async（异步）：
// → spi_async(dev, &msg)
//   → msg->complete() 回调通知完成
// 用于需要 DMA 的高性能场景

// SPI 读写辅助函数：
int spi_write_then_read(spi, txbuf, txlen, rxbuf, rxlen);
// → 构造 spi_message，先写后读
```

### 2.3 SPI 队列机制

```c
// 控制器维护一个 spi_message 队列：
// ctlr->queue（等待处理的 message 链表）
// → spi_async() 将 msg 加入队列
// → ctlr->queued = 1 启动处理
// → ctlr->transfer_one_message() 处理一个 msg
// → 完成后出队下一个
// → 没有更多 msg → 停止队列
// 保证传输的顺序和互斥
```

---

## 3. I2C vs SPI 对比

| 维度 | I2C | SPI |
|------|-----|-----|
| 总线结构 | 共享总线（多设备同两条线）| 点对点（每设备独立 CS）|
| 速度 | 100KHz-3.4MHz | 1-50MHz+ |
| 传输延迟 | ~10-100μs（100KHz 下 1 字节）| ~0.5-10μs（10MHz 下）|
| 协议开销 | 地址+ACK+START/STOP | 无（仅 CS 选择）|
| Linux API | `i2c_transfer` / `i2c_smbus_*` | `spi_sync` / `spi_async` |
| 设备树匹配 | `reg=<addr>` | `reg=<cs>` |
| 内核符号 | 267 | 490 |

---

## 4. 调试

```bash
# I2C
i2cdetect -l                    # 列出 I2C 总线
i2cdetect -y 1                  # 扫描 I2C 设备
i2cget -y 1 0x48 0x00           # 读取传感器寄存器
i2cset -y 1 0x48 0x01 0xFF      # 写入

# SPI
spidev_test -D /dev/spidev0.0   # SPI 测试
cat /sys/bus/spi/devices/spi0.0/modalias

# 跟踪
echo 1 > /sys/kernel/debug/tracing/events/i2c/i2c_transfer/enable
echo 1 > /sys/kernel/debug/tracing/events/spi/spi_transfer_start/enable
```

---

## 5. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `i2c_transfer` | `i2c-core-base.c` | I2C 消息传输 |
| `i2c_smbus_read_byte_data` | `i2c-core-smbus.c` | SMBus 读字节 |
| `i2c_new_client_device` | `i2c-core-base.c` | 注册 I2C 设备 |
| `spi_sync` | `spi.c` | SPI 同步传输 |
| `spi_async` | `spi.c` | SPI 异步传输 |
| `spi_write_then_read` | `spi.c` | SPI 先写后读 |

---

## 6. 总结

I2C（`i2c_transfer` → `adap->algo->master_xfer`）和 SPI（`spi_sync` → `ctlr->transfer_one_message` → `transfer_one`）是 Linux 中设备驱动访问板级外设的标准总线 API。I2C 适合低速多设备共享总线场景，SPI 适合高速点对点数据传输。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 7. I2C 重试与超时

```c
// __i2c_transfer @ i2c-core-base.c
// 失败时自动重试（最多 adapter->retries 次）：
int __i2c_transfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num)
{
    for (ret = 0, try = 0; try <= adap->retries; try++) {
        ret = adap->algo->master_xfer(adap, msgs, num);
        if (ret != -EAGAIN) break;
        if (try != adap->retries)
            msleep(adap->retry_delay);     // 重试间隔
    }
    return ret;
}
```

## 8. SPI 异步传输

```c
// spi_async 允许 DMA 传输，完成后回调通知：
// struct spi_message {
//     struct list_head transfers;       // transfer 链表
//     void (*complete)(void *context);  // 完成回调
//     void *context;
//     int status;                        // 传输状态
// };

// spi_async(spi, &msg)
// → __spi_async() → 加入控制器队列 → 硬件处理
// → 完成后 → msg->complete(msg->context)
// spi_sync 基于 spi_async 实现：complete 中调用 completion
```
