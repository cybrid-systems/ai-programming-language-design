# 114-usb-core — Linux USB 核心子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**USB 核心子系统**管理 USB 总线的设备枚举、配置、数据传输。层次结构：`usb_device`（设备）→ `usb_interface`（接口）→ `usb_driver`（驱动）。控制传输（`usb_control_msg`）用于配置，批量传输（`usb_bulk_msg`）用于数据，中断传输用于实时数据。

**核心设计**：USB 核心通过 `hub.c` 的 `hub_events()` 检测设备插拔并枚举。`usb_new_device()` 分配 `usb_device`，`usb_enumerate_device()` 读取描述符。驱动通过 `usb_register()` 注册并匹配 `usb_device_id`。

**doom-lsp 确认**：`drivers/usb/core/usb.c`（1,294 行），`hub.c`（6,567 行），`message.c`（2,521 行）。

---

## 1. 核心数据结构

```c
// include/linux/usb.h
struct usb_device {                            // USB 设备
    int devnum;                                // 设备地址
    enum usb_device_state state;               // ATTACHED/POWERED/DEFAULT/ADDRESS/CONFIGURED
    enum usb_device_speed speed;               // LOW/FULL/HIGH/SUPER/SUPER_PLUS
    struct usb_device *parent;                 // 父集线器
    struct usb_bus *bus;                       // 所属总线
    struct usb_host_endpoint ep0;              // 端点 0（控制传输）

    struct usb_device_descriptor descriptor;   // 设备描述符
    struct usb_host_config *config;            // 当前配置
    struct usb_host_config *rawdescr_config;

    unsigned short product;                    // idProduct
    unsigned short vendor;                     // idVendor
};

struct usb_interface {                         // USB 接口
    struct usb_host_interface *cur_altsetting;  // 当前设置
    unsigned num_altsetting;                    // 可选设置数
    struct usb_device *dev;                    // 所属设备
    struct device dev;
};

struct urb {                                   // USB 请求块
    struct usb_device *dev;                    // 目标设备
    unsigned int pipe;                          // 端点管道
    unsigned int transfer_flags;               // URB_*
    void *transfer_buffer;                     // 数据缓冲
    dma_addr_t transfer_dma;                   // DMA 地址
    int transfer_buffer_length;
    int actual_length;
    int status;
    usb_complete_t complete;                   // 完成回调
    void *context;
};
```

---

## 2. 设备枚举

```c
// hub_events() @ hub.c — 检测端口状态变化：
// → USB_PORT_STAT_CONNECTION → hub_port_connect_change()
//   → usb_alloc_dev() — 分配 usb_device
//   → usb_new_device()
//     → usb_enumerate_device() — 读取描述符
//       → usb_get_descriptor(DEVICE, 0, 0, &desc, 18) — 设备描述符
//       → usb_get_configuration(udev) — 配置描述符
//       → usb_parse_configuration() — 解析
//     → usb_choose_configuration() — 选择配置
//     → usb_set_configuration(udev, config) — 设置配置
//     → device_add(&udev->dev) — 注册设备

// 设备移除：
// → hub_port_connect_change() 检测断开
// → usb_disconnect() — 卸载设备+通知驱动
```

---

## 3. URB 传输

```c
// URB（USB Request Block）——USB 数据传输的基本单位：

// usb_fill_control_urb(urb, dev, pipe, setup_pkt, buf, len, callback)
// → 填充控制传输 URB

// usb_fill_bulk_urb(urb, dev, pipe, buf, len, callback)
// → 填充批量传输 URB

// usb_submit_urb(urb, GFP_KERNEL) — 提交 URB：

## 4. HCD 接口——主机控制器驱动

```c
// USB 主机控制器驱动实现 struct hc_driver：
struct hc_driver {
    int (*urb_enqueue)(struct usb_hcd *hcd, struct urb *urb, gfp_t mem_flags);
    int (*urb_dequeue)(struct usb_hcd *hcd, struct urb *urb, int status);
    void (*endpoint_disable)(struct usb_hcd *hcd, struct usb_host_endpoint *ep);
    int (*hub_status_data)(struct usb_hcd *hcd, char *buf);
    int (*hub_control)(struct usb_hcd *hcd, u16 typeReq, u16 wValue, ...);
};

// usb_submit_urb → urb_enqueue → HCD 硬件处理
// → xHCI/EHCI/OHCI/UHCI 各架构实现不同
```

## 5. 管道编码

```c
// USB 管道（pipe）编码端点类型和方向：
// unsigned int pipe = usb_sndbulkpipe(dev, ep)  — 批量 OUT
// unsigned int pipe = usb_rcvbulkpipe(dev, ep)  — 批量 IN
// unsigned int pipe = usb_sndctrlpipe(dev, 0)   — 控制 OUT
// unsigned int pipe = usb_rcvintpipe(dev, ep)   — 中断 IN

// pipe 编码格式：高位=设备地址 | 端点号 | 方向 | 类型
// 见 include/linux/usb.h 中的 __create_pipe 宏
```

## 6. USB DMA

```c
// USB 支持 DMA 传输（减少 CPU 拷贝）：
// urb->transfer_flags |= URB_NO_TRANSFER_DMA_MAP
// urb->transfer_dma = dma_map_single(dev, buf, len, dir)

// 控制传输的 DMA：
// usb_control_msg(dev, pipe, request, ...)
// → 内部构造 URB → usb_submit_urb → HCD 处理
```

// → 检查设备状态
// → 调用 HCD（主机控制器驱动）的 urb_enqueue
// → 硬件执行传输
// → 完成时调用 callback

// usb_kill_urb(urb) — 取消 URB（同步等待）
```

---

## 4. 驱动操作

```c
// 驱动注册：
static struct usb_driver my_driver = {
    .name = "my_usb",
    .probe = my_probe,
    .disconnect = my_disconnect,
    .id_table = my_id_table,                // usb_device_id 匹配表
};
usb_register(&my_driver);

// id_table 匹配规则：
struct usb_device_id my_id_table[] = {
    { USB_DEVICE(0x1234, 0x5678) },        // VID=0x1234, PID=0x5678
    { USB_DEVICE_INFO(0xFF, 0, 0) },       // 接口类=0xFF
    {},
};

// probe 路径：
// → usb_probe_interface(dev, id)
// → my_usb_probe(interface, id)
```

---

## 5. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `usb_alloc_dev` | `usb.c` | 分配 USB 设备 |
| `usb_new_device` | `usb.c` | 初始化+注册设备 |
| `usb_enumerate_device` | `usb.c` | 读取设备描述符 |
| `hub_events` | `hub.c` | 集线器事件循环 |
| `usb_submit_urb` | `urb.c` | 提交 URB 传输 |
| `usb_control_msg` | `message.c` | 同步控制传输 |
| `usb_bulk_msg` | `message.c` | 同步批量传输 |
| `usb_register` | `driver.c` | 驱动注册 |

---

## 6. 调试

```bash
# USB 拓扑
lsusb -t
lsusb -v

# URB 跟踪
echo 1 > /sys/kernel/debug/tracing/events/usb/enable

# 内核日志
dmesg | grep usb
```

---

## 7. 总结

USB 核心通过 `hub_events` 检测设备插拔，`usb_new_device` 枚举并配置设备。URB（`usb_submit_urb`）是数据传输的基本单位。驱动通过 `usb_register` 注册，`usb_device_id` 匹配设备。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
