# USB core — USB 核心子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/usb/core/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**USB core** 提供 USB 主机控制器和设备的公共抽象，支持 HUB、热插拔、传输类型（控制/批量/中断/同步）。

---

## 1. 核心数据结构

### 1.1 usb_device — USB 设备

```c
// drivers/usb/core/message.c — usb_device
struct usb_device {
    // 总线
    struct usb_bus          *bus;           // 所属总线
    struct usb_host_config  *config;        // 配置描述符
    struct usb_host_endpoint *ep0;           // 端点 0

    // 地址
    u8                      devnum;        // 设备地址（1-127）
    u8                      maxchild;      // 下行端口数

    // 描述符
    struct usb_device_descriptor descriptor; // 设备描述符
    struct usb_config_descriptor *actconfig; // 当前配置

    // 状态
    enum {
        USB_STATE_ATTACHED,   // 已连接
        USB_STATE_POWERED,    // 已通电
        USB_STATE_DEFAULT,    // 默认地址
        USB_STATE_ADDRESS,    // 已分配地址
        USB_STATE_CONFIGURED, // 已配置
        USB_STATE_SUSPENDED   // 暂停
    } state;

    // 速度
    enum usb_device_speed    speed;         // LOW/FULL/HIGH/SUPER
};
```

### 1.2 usb_host_endpoint — 端点

```c
// include/linux/usb/ch9.h — usb_host_endpoint
struct usb_host_endpoint {
    struct endpoint_descriptor desc;        // 端点描述符
    struct usb_ss_ep_comp_descriptor *ss_ep_comp; // SuperSpeed 额外描述符

    //urb 列表（正在进行传输）
    struct list_head        urb_list;       // URB 链表
    void                   *hcpriv;        // 主机控制器私有数据
};
```

---

## 2. URB — USB 请求块

```c
// include/linux/usb.h — urb
struct urb {
    // 传输
    struct list_head        anchor_list;    // 链表
    struct usb_device       *dev;          // 目标设备
    unsigned int            pipe;            // 管道（端点+方向）
    int                     status;         // URB 状态

    // 数据
    void                   *transfer_buffer; // 数据缓冲
    u32                     transfer_buffer_length; // 缓冲长度
    u32                     actual_length;  // 实际传输长度

    // 回调
    usb_complete_t          complete;        // 完成回调
    void                   *context;       // 传递给回调的上下文
};
```

---

## 3. 提交 URB

```c
// drivers/usb/core/message.c — usb_submit_urb
int usb_submit_urb(struct urb *urb, gfp_t mem_flags)
{
    struct usb_device *dev = urb->dev;

    // 1. 检查端点
    if (!urb->ep)
        return -EINVAL;

    // 2. 提交到主机控制器
    return urb->ep->hcpriv->submit(urb, mem_flags);
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/usb/core/message.c` | `usb_device` |
| `include/linux/usb.h` | `struct urb` |
| `include/linux/usb/ch9.h` | `usb_host_endpoint` |