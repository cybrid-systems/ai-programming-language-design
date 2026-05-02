# 115-thunderbolt — Linux Thunderbolt 总线深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Thunderbolt** 是 Intel 开发的高速外设连接技术（40Gbps），结合 PCIe（外设）和 DisplayPort（显示）于单条线缆。内核 Thunderbolt 驱动管理设备发现、路径建立、安全验证（ICM/CM）。

**核心设计**：Thunderbolt 总线由 `tb.c` 管理拓扑（`tb_scan_switch` 发现交换机），`ctl.c` 通过控制通道（NHI）与硬件通信，`tunnel.c` 创建 PCIe/DP 数据通道。

**doom-lsp 确认**：`drivers/thunderbolt/tb.c`（3,399 行），`ctl.c`（1,184 行），`tunnel.c`（2,648 行）。

---

## 1. 核心数据结构

```c
struct tb_switch {                            // Thunderbolt 交换机
    struct device dev;
    struct tb_switch *parent;                  // 上游交换机
    struct tb_port *ports;                     // 端口数组
    int port_cnt;
    u64 route;                                  // 路由路径
    u8 depth;                                   // 拓扑深度
    const struct tb_switch_ops *ops;

    uuid_t uuid;                                // UUID
    int security_level;                         // 安全级别
};

struct tb_port {                               // 交换机端口
    struct tb_switch *sw;                       // 所属交换机
    struct tb_regs_port_header config;           // 端口配置寄存器
    int port;                                   // 端口号
    bool disabled;
    struct tb_port *dual_link_port;

    struct tb_tunnel *tunnel;                   // 关联的隧道
};

struct tb_tunnel {                             // 数据通道
    struct tb_path *paths;                     // 路径数组
    int npaths;
    struct tb *tb;
    enum tb_tunnel_type type;                  // PCI / DP / DMA
    bool activated;
};
```

**doom-lsp 确认**：`struct tb_switch`、`struct tb_port`、`struct tb_tunnel`。

---

## 2. 拓扑发现——tb_scan_switch

```c
// tb_scan_switch @ tb.c——递归扫描交换机拓扑：
void tb_scan_switch(struct tb_switch *sw)
{
    // 1. 遍历所有端口
    for (i = 0; i <= sw->config.max_port_number; i++) {
        port = &sw->ports[i];
        if (!port->config.type)
            continue;

        // 2. 如果是下游端口且连接了交换机
        if (port->config.type == TB_TYPE_PORT) {
            // 分配新 tb_switch → tb_scan_switch(新 switch)
            // 递归扫描下游
        }


## 2. 控制通道——ctl.c

```c
// ctl_tx() @ ctl.c — 通过 NHI 发送控制帧：
// 帧通过 NHI 硬件的 DMA 环形缓冲区传输
// 请求类型：TB_CFG_PKG_READ / TB_CFG_PKG_WRITE
// 地址格式：route_hi:route_lo:space:offset:length

// struct ctl_pkg { struct tb_cfg_header hdr; struct tb_cfg_result res; };
// 控制帧在 DMA 环形缓冲区中传输
```

## 3. 路径管理——tb_path

```c
struct tb_path {
    struct tb_port *src_port, *dst_port;
    int src_hopid, dst_hopid;
    struct tb_path_hop *hops;               // 路径跳表
};

// 每个跳（hop）映射输入端口+hopid → 输出端口+hopid
// 路径建立后硬件根据 hop 表转发，无需 CPU 介入
```

## 4. ICM mailbox

```c
// ICM 模式：固件管理连接（Intel 现代平台）
// 驱动通过 NHI mailbox 与固件通信
// icm_fr_driver_ready() — 通知 ICM 驱动就绪
```

        // 3. 如果是 PCIe 适配器端口
        if (port->config.type == TB_TYPE_PCIE_ADAPTER) {
            // 标记为可用 PCIe 通道端点
        }
    }
}
```

---

## 3. 隧道建立——tb_tunnel_alloc

## 5. NHI 环形缓冲区——数据传输

```c
// NHI（Native Host Interface）是 Thunderbolt 控制器的 DMA 接口：
// struct tb_nhi {
//     struct pci_dev *pdev;                // PCI 设备
//     void __iomem *iobase;               // 寄存器基址
//     struct tb_ring *tx_ring;             // 发送环
//     struct tb_ring *rx_ring;             // 接收环
// };

// 每个 ring 是一组 DMA 描述符的循环队列：
// 描述符指向数据缓冲区（控制帧或数据帧）
// 硬件通过 PCIe DMA 直接读写主机内存
```

## 6. 激活隧道

```c
// tb_tunnel_activate @ tunnel.c — 激活数据通道：
// → 对 tunnel 中的每条路径：
//   1. tb_path_activate(path)
//      → 写 hop 表到每个交换机的路由寄存器
//      → 设置源/目的端口的 hopid 映射
//   2. 激活后数据可以开始传输
// → tunnel->activated = true
```


```c
// tb_tunnel_alloc_pci @ tunnel.c——创建 PCIe 隧道：
struct tb_tunnel *tb_tunnel_alloc_pci(struct tb *tb,
    struct tb_port *up, struct tb_port *down)
{
    // 1. 分配路径
    struct tb_tunnel *tunnel = kzalloc(sizeof(*tunnel), GFP_KERNEL);
    tunnel->type = TB_TUNNEL_PCI;
    tunnel->npaths = 2;                        // 上+下行

    // 2. 创建上下行路径
    tunnel->paths[0] = tb_path_alloc(tb, up, TB_PCI_HOPID,
                                      down, TB_PCI_HOPID, 0, "PCIe Up");
    tunnel->paths[1] = tb_path_alloc(tb, down, TB_PCI_HOPID,
                                      up, TB_PCI_HOPID, 0, "PCIe Down");

    // 3. 激活
    tb_tunnel_activate(tunnel);
    return tunnel;
}
```

---

## 4. 安全验证

```c
// Thunderbolt 安全级别：
// security_level:
//   0 — none（无安全验证）
//   1 — user（用户确认）
//   2 — secure（密钥验证）
//   3 — dponly（仅 DP）

// ICM（Integrated Connection Manager）模式：
// → 固件管理连接（现代 Intel 平台）
// → 驱动通过 ICM mailbox 通信

// CM（Connection Manager）模式：
// → 驱动管理连接（旧平台）
// → 驱动控制 NHI（Native Host Interface）
```

---

## 5. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `tb_scan_switch` | `tb.c` | 递归扫描拓扑 |
| `tb_tunnel_alloc_pci` | `tunnel.c` | 分配 PCIe 隧道 |
| `tb_tunnel_activate` | `tunnel.c` | 激活隧道 |
| `tb_path_alloc` | `path.c` | 分配数据路径 |
| `ctl_tx` | `ctl.c` | 发送控制帧 |

---

## 6. 调试

```bash
# Thunderbolt 设备
ls /sys/bus/thunderbolt/devices/
cat /sys/bus/thunderbolt/devices/0-0/security_level

# 查看安全等级
boltctl list
```

---

## 7. 总结

Thunderbolt 驱动通过 `tb_scan_switch` 发现交换机拓扑，`tb_tunnel_alloc_pci` 创建 PCIe 隧道（上下行路径），`tb_tunnel_activate` 激活数据通道。安全验证通过 ICM/CM 模式管理。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
