# Linux Kernel CCW / zFCP / mainframe I/O 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/s390/cio/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. mainframe I/O 概述

IBM Z 系列（mainframe）使用与 x86 完全不同的 I/O 架构：
- **Channel Subsystem (CSS)**：管理所有 I/O 设备
- **CCW (Channel Command Word)**：在主机构架上运行的 I/O 命令
- **CHPID (Channel Path ID)**：物理通道路径

---

## 1. CCW — Channel Command Word

```c
// drivers/s390/cio/ccwreq.h — ccw1
struct ccw1 {
    __u32  cmd_code;    // 命令码（READ / WRITE / SENSE 等）
    __u32  cda;         // 数据地址（绝对物理地址）
    __u32  count;       // 传输字节数
    __u8   flags;       // 标志（CCW_FLAG_SLI 等）
};
```

---

## 2. zFCP — SCSI over Fibre Channel on zSeries

```c
// drivers/s390/scsi/zfcp_erp.c — zfcp 结构
struct zfcp_port {
    struct fc_rport       *rport;     // Fibre Channel 远程端口
    u64                 wwpn;        // World Wide Port Name
    u64                 fcp_lun;     // FCP LUN
    u32                 d_id;        // Destination ID
};

struct zfcp_adapter {
    struct ccw_device   *ccw_device; // 底层 CCW 设备
    struct fc_host      *fc_host;    // FC 主机适配器
    struct zfcp_port    *port_list;  // 远程端口列表
};
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/s390/cio/device.c` | CCW 设备驱动 |
| `drivers/s390/scsi/zfcp_erp.c` | zFCP 错误恢复 |
| `drivers/s390/cio/css.c` | Channel Subsystem |
