# Linux Kernel USB Core 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/usb/core/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. USB 架构

```
USB 设备
  │
  ├─ Hub（集线器）
  │    └─ 端口 1: 键盘
  │    └─ 端口 2: 鼠标
  │    └─ 端口 3: Webcam
  │
hc (Host Controller):
  - UHCI（USB 1.0，Intel）
  - OHCI（USB 1.0，Compaq/Apple）
  - EHCI（USB 2.0）
  - xHCI（USB 3.0+，Intel）
```

---

## 1. 核心结构

```c
// drivers/usb/core/hcd.h — usb_host_endpoint
struct usb_host_endpoint {
    struct usb_endpoint_descriptor   *desc;   // 端点描述符
    struct usb_ss_ep_comp_descriptor *ss_ep_comp;
    struct usb_host_endpoint         *hcpriv;
    struct usb_device                *dev;
};

// usb_host_interface — 接口（一组端点）
struct usb_host_interface {
    struct usb_interface_descriptor  *altsetting;
    int                             num_altsetting;
    struct usb_interface            *iface;
};

// usb_device — USB 设备
struct usb_device {
    int                 devnum;         // 设备地址（1-127）
    char                devpath[16];     // 路径（"1-2.3"）
    enum usb_device_state state;        // DEFAULT / ADDRESS / CONFIGURED
    struct usb_device   *parent;         // 父 Hub
    struct usb_host_interface *actconfig;  // 当前配置
};
```

---

## 2. USB 传输类型

```
控制传输（Control）：   SETUP → DATA → STATUS（枚举、配置）
批量传输（Bulk）：       大量数据，可靠（U盘）
中断传输（Interrupt）：  小量数据，定期（键盘、鼠标）
等时传输（Isochronous）：实时，无可靠性保证（摄像头、音频）
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/usb/core/hcd.c` | Host Controller Driver |
| `drivers/usb/core/message.c` | USB 消息传递 |
| `drivers/usb/core/urb.c` | URB（USB Request Block）|
