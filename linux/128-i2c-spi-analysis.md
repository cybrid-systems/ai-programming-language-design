# 128-I2C-SPI — 串行总线深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/i2c/i2c-dev.c` + `drivers/spi/spi.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**I2C**（Inter-Integrated Circuit，双线串行总线）和 **SPI**（Serial Peripheral Interface，四线全双工总线）是嵌入式系统最常用的外设通信协议。Linux 提供统一的设备模型接口。

## 1. I2C 核心

### 1.1 struct i2c_adapter — I2C 适配器

```c
// include/linux/i2c.h — i2c_adapter
struct i2c_adapter {
    struct module           *owner;
    unsigned int           class;           // 支持的 I2C 类别
    const struct i2c_algorithm *algo;   // 总线算法（主机侧）
    void                   *algo_data;     // 算法私有数据

    // 设备层级
    struct rt_mutex        bus_lock;       // 总线锁
    struct i2c_bus_recovery_info *bus_recovery_info; // 总线恢复
    int                     nr;             // 适配器编号（/dev/i2c-N）
    char                   name[48];       // 适配器名
};
```

### 1.2 struct i2c_algorithm — I2C 算法

```c
// include/linux/i2c.h — i2c_algorithm
struct i2c_algorithm {
    int  (*master_xfer)(struct i2c_adapter *adap, struct i2c_msg *msgs,
                        int num);          // 发送 I2C 消息
    int  (*smbus_xfer)(struct i2c_adapter *adap, u16 addr,
                       unsigned short flags, char read_write,
                       u8 command, int size, union i2c_smbus_data *data);
};
```

### 1.3 struct i2c_msg — I2C 消息

```c
// include/linux/i2c.h — i2c_msg
struct i2c_msg {
    __u16 addr;          // 从设备地址（7bit 或 10bit）
    __u16 flags;        // I2C_M_* 标志
    __u16 len;          // 数据长度
    __u8  buf[0];       // 数据缓冲区
};

// flags：
//   I2C_M_TEN        = 10-bit 地址
//   I2C_M_RD         = 读操作
//   I2C_M_STOP       = 发送 STOP 位
//   I2C_M_NOSTART    = 无 START 位（repeated start）
```

## 2. I2C 用户空间接口

### 2.1 i2c-dev — /dev/i2c-N

```c
// drivers/i2c/i2c-dev.c — i2c_dev
struct i2c_dev {
    struct list_head        list;             // 全局 i2c_dev 链表
    struct i2c_adapter     *adap;            // 所属适配器
    struct device           dev;              // device
    struct cdev             cdev;             // 字符设备
};

// 用户空间：
//   open("/dev/i2c-0") → i2c_dev_get_by_minor()
//   ioctl(I2C_SLAVE, addr) → 设置从设备地址
//   write()/read() → i2c_master_send/recv()
//   ioctl(I2C_RDWR, *msgs) → 复合消息（repeated start）
```

### 2.2 I2C_RDWR — 复合消息

```c
// drivers/i2c/i2c-dev.c — i2cdev_ioctl_rdwr
static long i2cdev_ioctl_rdwr(struct file *filp, unsigned int cmd,
                               unsigned long arg)
{
    struct i2c_rdwr_ioctl_data __user *data = (void __user *)arg;
    struct i2c_msg msgs[I2C_RDWR_IOCTL_MAX_MSGS];
    int nmsgs;

    copy_from_user(&nmsgs, &data->nmsgs, sizeof(nmsgs));

    // 解析 msgs
    for (i = 0; i < nmsgs; i++) {
        copy_from_user(&msgs[i], &data->msgs[i], sizeof(struct i2c_msg));
    }

    // 发送（一次 START + 多个 msg + STOP）
    ret = i2c_transfer(adap, msgs, nmsgs);
}
```

## 3. SPI 核心

### 3.1 struct spi_device — SPI 设备

```c
// include/linux/spi/spi.h — spi_device
struct spi_device {
    struct device           dev;              // 设备模型
    struct spi_controller  *controller;     // SPI 主机控制器
    struct spi_board_info  *board_info;     // 板级信息

    // SPI 配置
    u32                    max_speed_hz;     // 最大时钟（Hz）
    u8                     chip_select;       // 片选编号
    u8                     bits_per_word;     // 每字位数（通常 8）
    u16                    mode;               // SPI 模式（CPHA/CPOL）

    // 数据
    void                  *controller_state;
    void                  *platform_data;     // 板级私有数据
};
```

### 3.2 struct spi_master — SPI 主机

```c
// include/linux/spi/spi.h — spi_master
struct spi_master {
    const struct spi_controller_ops *ops;  // 操作函数表

    // 队列
    struct workqueue_struct   *wq;       // SPI 消息队列
    spinlock_t                 queue_lock;
    struct list_head           queue;     // 待处理消息队列

    // 片选
    bool                      cached_chipselect[0]; // 片选缓存
    int                       num_chipselect;
};
```

### 3.3 spi_transfer — SPI 传输

```c
// include/linux/spi/spi.h — spi_transfer
struct spi_transfer {
    const void      *tx_buf;            // 发送缓冲区（NULL = 忽略）
    void            *rx_buf;            // 接收缓冲区（NULL = 忽略）
    unsigned int    len;                // 传输字节数

    unsigned int    speed_hz;           // 覆盖设备时钟
    u16             bits_per_word;      // 覆盖每字位数
    u16             delay_usecs;       // 传输后延迟
    bool            cs_change:1;       // 片选保持（不要取消）
};
```

## 4. I2C vs SPI 对比

| 特性 | I2C | SPI |
|------|-----|-----|
| 线数 | 2（SDA + SCL）| 4+（MOSI/MISO/SCLK/CS）|
| 速度 | up to 5MHz | up to 100MHz |
| 寻址 | 从设备地址（7/10 bit）| 片选（Chip Select）|
| 传输模式 | 半双工 | 全双工 |
| 多主机 | ✓ | ✗ |
| 从设备 | 需要地址 | 需要片选 |
| 复杂度 | 高（协议复杂）| 低（协议简单）|

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/i2c/i2c-dev.c` | `i2c_dev`、`i2cdev_ioctl_rdwr` |
| `include/linux/i2c.h` | `struct i2c_adapter`、`struct i2c_msg`、`struct i2c_algorithm` |
| `drivers/spi/spi.c` | `spi_sync`、`spi_async`、`spi_setup` |
| `include/linux/spi/spi.h` | `struct spi_device`、`struct spi_master`、`struct spi_transfer` |

## 6. 西游记类比

**I2C/SPI** 就像"取经路上的两种说话方式"——

> I2C 像对讲机（两线），所有人都在同一频道（SDA 数据线 + SCL 时钟线），但说话前要先报名字（地址）。SPI 像专线电话（四线以上），每个人有自己专属的线路（MOSI/MISO），通话时还要拉专线（片选拉低）。I2C 速度慢但省线，可以多主机；SPI 速度快但需要更多线。两种方式的内核代码都抽象成统一的设备模型（i2c_adapter / spi_master），每个具体的芯片（EEPROM、传感器、Flash）都对应一个 client（i2c_client / spi_device）。

## 7. 关联文章

- **device model**（相关）：I2C/SPI 是 platform bus 的子集
- **driver model**（相关）：i2c_driver / spi_driver 注册

---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `include/linux/list.h` | 51 | 0 | 51 | 0 |
| `include/linux/sched.h` | 567 | 70 | 134 | 7 |
| `include/linux/mm.h` | 793 | 24 | 527 | 18 |

### 核心数据结构

- **audit_context** `sched.h:58`
- **bio_list** `sched.h:59`
- **blk_plug** `sched.h:60`
- **bpf_local_storage** `sched.h:61`
- **bpf_run_ctx** `sched.h:62`
- **bpf_net_context** `sched.h:63`
- **capture_control** `sched.h:64`
- **cfs_rq** `sched.h:65`
- **fs_struct** `sched.h:66`
- **futex_pi_state** `sched.h:67`
- **io_context** `sched.h:68`
- **io_uring_task** `sched.h:69`
- **mempolicy** `sched.h:70`
- **nameidata** `sched.h:71`
- **nsproxy** `sched.h:72`
- **perf_event_context** `sched.h:73`
- **perf_ctx_data** `sched.h:74`
- **pid_namespace** `sched.h:75`
- **pipe_inode_info** `sched.h:76`
- **rcu_node** `sched.h:77`
- **reclaim_state** `sched.h:78`
- **robust_list_head** `sched.h:79`
- **root_domain** `sched.h:80`
- **rq** `sched.h:81`
- **sched_attr** `sched.h:82`

### 关键函数

- **INIT_LIST_HEAD** `list.h:43`
- **__list_add_valid** `list.h:136`
- **__list_del_entry_valid** `list.h:142`
- **__list_add** `list.h:154`
- **list_add** `list.h:175`
- **list_add_tail** `list.h:189`
- **__list_del** `list.h:201`
- **__list_del_clearprev** `list.h:215`
- **__list_del_entry** `list.h:221`
- **list_del** `list.h:235`
- **list_replace** `list.h:249`
- **list_replace_init** `list.h:265`
- **list_swap** `list.h:277`
- **list_del_init** `list.h:293`
- **list_move** `list.h:304`
- **list_move_tail** `list.h:315`
- **list_bulk_move_tail** `list.h:331`
- **list_is_first** `list.h:350`
- **list_is_last** `list.h:360`
- **list_is_head** `list.h:370`
- **list_empty** `list.h:379`
- **list_del_init_careful** `list.h:395`
- **list_empty_careful** `list.h:415`
- **list_rotate_left** `list.h:425`
- **list_rotate_to_front** `list.h:442`
- **list_is_singular** `list.h:457`
- **__list_cut_position** `list.h:462`
- **list_cut_position** `list.h:488`
- **list_cut_before** `list.h:515`
- **__list_splice** `list.h:531`
- **list_splice** `list.h:550`
- **list_splice_tail** `list.h:562`
- **list_splice_init** `list.h:576`
- **list_splice_tail_init** `list.h:593`
- **list_count_nodes** `list.h:755`

### 全局变量

- **__tracepoint_sched_set_state_tp** `sched.h:350`
- **__tracepoint_sched_set_need_resched_tp** `sched.h:352`
- **def_root_domain** `sched.h:407`
- **sched_domains_mutex** `sched.h:408`
- **cad_pid** `sched.h:1749`
- **init_stack** `sched.h:1964`
- **class_migrate_is_conditional** `sched.h:2519`
- **_totalram_pages** `mm.h:53`
- **high_memory** `mm.h:74`
- **sysctl_legacy_va_layout** `mm.h:86`
- **mmap_rnd_bits_min** `mm.h:92`
- **mmap_rnd_bits_max** `mm.h:93`
- **mmap_rnd_bits** `mm.h:94`
- **sysctl_user_reserve_kbytes** `mm.h:210`
- **sysctl_admin_reserve_kbytes** `mm.h:211`

### 成员/枚举

- **utime** `sched.h:366`
- **stime** `sched.h:367`
- **lock** `sched.h:368`
- **seqcount** `sched.h:386`
- **starttime** `sched.h:387`
- **state** `sched.h:388`
- **cpu** `sched.h:389`
- **utime** `sched.h:390`
- **stime** `sched.h:391`
- **gtime** `sched.h:392`
- **sched_priority** `sched.h:413`
- **pcount** `sched.h:421`
- **run_delay** `sched.h:424`
- **max_run_delay** `sched.h:427`
- **min_run_delay** `sched.h:430`
- **last_arrival** `sched.h:435`
- **last_queued** `sched.h:438`
- **max_run_delay_ts** `sched.h:441`
- **weight** `sched.h:461`
- **inv_weight** `sched.h:462`

