# 117-ccw-zfcp — Linux CCW 和 zFCP 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**CCW（Channel Command Word）** 是 IBM s390 架构的 I/O 子系统，驱动通过 CCW 程序与设备通信。**zFCP** 是 s390 上的 FCP（光纤通道协议）驱动，将 SCSI 命令封装为 CCW 程序发送到 FCP 适配器。

**核心设计**：CCW 程序是 `struct ccw1` 数组，每个 CCW 指定命令码、数据地址、标志。`ccw_device_start` 提交 CCW 程序到通道子系统，硬件独立执行 I/O 操作，完成时产生中断。

**doom-lsp 确认**：`drivers/s390/cio/device.c`（1,933 行）。

---

## 1. 核心数据结构

```c
// include/linux/ccwdev.h
struct ccw_device {
    struct ccw_device_private *private;          // 私有数据
    struct ccw_dev_id id;                        // 设备 ID
    int online;
    struct ccw_driver *driver;                  // 绑定的驱动
    struct device dev;
};

struct ccw1 {                                   // 通道命令字
    __u8 cmd_code;                               // 命令码
    __u8 flags;                                  // CCW_FLAG_*
    __u16 count;                                 // 数据长度
    __u32 cda;                                   // 数据地址（31-bit）
};

struct ccw_io_region {                          // I/O 区域
    struct ccw1 cw[ZFCP_MAX_CHANNELS];           // CCW 程序
    struct fsf_qtcb q;                           // FCP 传输控制块
};
```

---

## 2. CCW 程序提交

```c
// ccw_device_start(dev, cw, intparm, lpm, key, flags)
// → 将 CCW 程序首地址写入通道子系统
// → 通道子系统独立执行
// → 每个 CCW 执行完后根据 flags 决定：
//   CCW_FLAG_CC — 链式（继续下一条）
//   CCW_FLAG_SLI — 抑制错误
//   CCW_FLAG_SKP — 跳过
// → 最后一条 CCW 执行完毕 → 中断
```

---

## 3. zFCP I/O 路径

```c
// zFCP 驱动将 SCSI 命令转换为 CCW 程序：
// 1. 构造 FCP_CMND IU（Information Unit）

## 2. CCW 标志和链

```c
// CCW 标志定义：
#define CCW_FLAG_DC         0x80  // 链式数据
#define CCW_FLAG_CC          0x40  // 命令链（执行后继续下一条）
#define CCW_FLAG_SLI         0x20  // 抑制长度错误
#define CCW_FLAG_SKP         0x10  // 跳过
#define CCW_FLAG_PCI         0x08  // 程序控制中断
#define CCW_FLAG_IDA         0x04  // 间接数据寻址

// 示例：读写 FCP 的 CCW 程序
// cw[0] = { cmd=READ_ID, flags=CCW_FLAG_CC, count=32 }
// cw[1] = { cmd=WRITE, flags=CCW_FLAG_CC, ... }  // 写命令
// cw[2] = { cmd=READ, flags=0, ... }              // 读响应
```

## 3. fsf_qtcb——FCP 传输控制块

```c
// zFCP 使用 fsf_qtcb 描述 FCP 请求：
struct fsf_qtcb {
    struct fsf_qtcb_prefix prefix;      // 前缀
    union {
        struct fsf_qtcb_bottom_port port;// 端口
        struct fsf_qtcb_bottom_io iocb;  // I/O 命令
    } bottom;
};
// qtcb 包含 FCP CMND IU 和目标 LUN/WWPN 等
```

## 4. 中断处理——ccw_device_irq

```c
// CCW 程序执行完成 → I/O 中断 → ccw_device_irq()
// → 检查中断响应码
// → zfcp_fsf_req_complete() — 完成 FCP 请求
// → 唤醒等待的 SCSI 层
// → 错误处理（链路恢复、重试）
```

## 5. 设备发现

```c
// s390 通道子系统（CSS）发现 CCW 设备：
// 1. css_driver 扫描通道子系统
// 2. 为每个设备创建 ccw_device
// 3. ccw_device_probe() → zfcp_ccw_probe()
// 4. ccw_device_set_online() → 启用设备
```

// 2. 填充 fsf_qtcb（传输控制块）
// 3. 组织 ccw1 数组：
//   ccw[0] = CCW_CMD_READ_ID
//   ccw[1] = CCW_CMD_READ — 读 FCP 响应
//   ccw[2] = CCW_CMD_WRITE — 写 FCP 命令
// 4. ccw_device_start() 提交
// 5. 完成中断 → zfcp_fsf_req_complete()
```

---

## 4. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `ccw_device_start` | `device.c` | 提交 CCW 程序 |
| `ccw_device_probe` | `device.c` | CCW 设备探测 |
| `zfcp_fsf_req_send` | `zfcp_fsf.c` | 发送 FCP 请求 |
| `zfcp_fsf_req_complete` | `zfcp_fsf.c` | 请求完成处理 |

---

## 5. 调试

```bash
# s390 设备
cat /proc/cio_devices
lscss
lszfcp

# zFCP
cat /sys/bus/ccw/drivers/zfcp/0.0.XXXX/hostX/fc_stats
```

---

## 6. 总结

CCW 通过 `ccw_device_start` 提交 CCW 程序到通道子系统，硬件独立执行 I/O。zFCP 驱动将 SCSI 命令封装为 CCW 程序，通过 FCP 适配器完成 FC 协议通信。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 6. zFCP 适配器结构

```c
// drivers/s390/scsi/zfcp_def.h
struct zfcp_adapter {
    struct ccw_device *ccw_device;              // CCW 设备
    struct zfcp_fsf_req **req_list;             // FSF 请求表（按 req_id 索引）
    u32 req_no;                                  // 下一个请求序号

    struct fc_host_statistics *fc_stats;
    struct Scsi_Host *scsi_host;                 // SCSI 主机
    struct zfcp_adapter_mempool pool;             // 内存池
    spinlock_t req_list_lock;
};

struct zfcp_fsf_req {                            // FSF 请求
    struct list_head list;
    struct zfcp_adapter *adapter;

    struct ccw1 ccw;                             // CCW 命令
    struct fsf_qtcb *qtcb;                       // 传输控制块
    dma_addr_t qtcb_dma;                          // qtcb DMA 地址

    void (*handler)(struct zfcp_fsf_req *);      // 完成回调
    unsigned long status;                         // 状态标志
    u32 req_id;                                   // 请求 ID
};
```

## 7. FSF 请求生命周期

```c
// zfcp_fsf_fcp_cmnd() — 发送 SCSI 命令：
// 1. zfcp_fsf_req_create(adapter, FSF_QTCB_FCP_CMND, ...)
//    → 分配 fsf_req + qtcb（DMA 一致内存）
//    → 初始化 fsf_qtcb_bottom_io（LUN、WWPN、cdb）
// 2. 构造 CCW 程序（READ/WRITE）：
//    ccw[0] = { cmd=WRITE, flags=CC, cda=qtcb_dma }
//    ccw[1] = { cmd=READ,  flags=CC, ... }
// 3. ccw_device_start(adapter->ccw_device, &ccw[0], ...)
// 4. 完成时：
//    → ccw_device_irq() → zfcp_fsf_req_complete()
//    → fsf_req->handler() → 通知 SCSI 层
```

## 8. SCSI 命令提交

```c
// zfcp_scsi_queuecommand @ zfcp_scsi.c：
// → SCSI 中层调用此函数下发 SCSI 命令
// → zfcp_fsf_fcp_cmnd() — 构造 FCP_CMND IU
// → 通过 CCW 程序发送到 FCP 适配器
// → 适配器执行 FC 协议（发起到存储阵列的传输）
```

