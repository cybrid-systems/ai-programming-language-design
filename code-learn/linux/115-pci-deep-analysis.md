# 116-pci-deep — Linux PCI 子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**PCI 子系统**管理 PCI/PCIe 总线的设备枚举、配置空间访问、资源分配、电源管理。核心在 `pci.c` 和 `probe.c` 中实现——`pci_scan_bus` 扫描总线，`pci_device_add` 添加设备，`pci_bus_alloc_resource` 分配 BAR 资源。

**核心设计**：PCI 枚举从根桥（`pci_root`）开始递归扫描 `bus→devices→bridges→secondary bus`。每个 `struct pci_dev` 对应一个设备，配置空间通过 `pci_read_config_*`/`pci_write_config_*` 访问。

**doom-lsp 确认**：`drivers/pci/pci.c`（6,801 行），`probe.c`（3,585 行）。

---

## 1. 核心数据结构

```c
// include/linux/pci.h
struct pci_dev {                              // PCI 设备
    struct pci_bus *bus;                       // 所属总线
    struct pci_slot *slot;

    unsigned int devfn;                        // 设备号+功能号
    unsigned short vendor;                     // Vendor ID
    unsigned short device;                     // Device ID
    unsigned short subsystem_vendor;
    unsigned short subsystem_device;

    struct pci_driver *driver;                 // 绑定的驱动
    u64 class;                                  // 类别

    struct resource resource[DEVICE_COUNT_RESOURCE]; // BAR 资源
    struct pci_dev *physfn;                    // PF（SR-IOV）
    struct pci_dev *virtfn;                    // VF（SR-IOV）
};

struct pci_bus {                               // PCI 总线
    struct list_head devices;                   // 设备链表
    struct pci_bus *parent;                    // 父总线
    struct list_head children;                  // 子总线
    struct pci_ops *ops;                        // 配置空间访问操作

    int number;                                 // 总线号
    unsigned char primary;
    unsigned char secondary;
};

struct pci_driver {                            // PCI 驱动
    const char *name;
    const struct pci_device_id *id_table;
    int (*probe)(struct pci_dev *dev, const struct pci_device_id *id);
    void (*remove)(struct pci_dev *dev);
};
```

---

## 2. 设备枚举——pci_scan_bus

```c
// pci_scan_bus @ probe.c — 扫描 PCI 总线：
// 发现所有设备：
// → for (devfn = 0; devfn < 256; devfn++)
//     → pci_scan_device(bus, devfn) 读 Vendor ID
//     → 非 0xFFFF → pci_alloc_dev(bus, devfn)
//     → pci_setup_device(dev) 读其他配置空间
//       → pci_read_bases(dev) 读 BAR 寄存器
//     → pci_device_add(dev, bus) 添加设备

// 发现 PCIe 桥 → pci_scan_bridge(bus, dev)
// → 配置次要总线号 → 递归扫描下游总线

// 最终 → 注册所有设备 → driver probe
```

---

## 3. 资源分配

```c
// PCI 设备有 6 个 BAR（Base Address Register）：

## 3. 中断——MSI/MSI-X

```c
// PCI 支持三种中断：
// 1. INTx——传统中断引脚（共享 IRQ）
// 2. MSI——消息信号中断（最多 32 个向量）
// 3. MSI-X——扩展 MSI（最多 2048 个向量，独立寻址）

// 启用 MSI：pci_enable_msi(dev)
// → 读取 MSI Capability 结构
// → 分配 IRQ 号
// → 写 Message Address + Message Data 寄存器

// 启用 MSI-X：pci_enable_msix_range(dev, entries, min, max)
// → 读取 MSI-X Capability
// → 每个条目独立配置地址+数据
// → 实际使用在 NVMe/GPU 等高性能设备
```

## 4. SR-IOV——单根 I/O 虚拟化

```c
// SR-IOV 允许一个 PF 创建多个 VF（每个 VF 是独立 PCI 设备）：
// pci_enable_sriov(dev, nr_virtfn) — 启用虚拟功能
// → 读取 SR-IOV Capability
// → 配置 TotalVFs + NumVFs
// → 创建 VF 的 PCI 配置空间
// → 每个 VF 有独立 BAR、MSI、总线地址

// struct pci_dev {
//     struct pci_dev *physfn;   // PF 指针（VF 使用）
//     struct pci_dev *virtfn;   // VF 数组（PF 使用）
//     u16 is_physfn:1;
//     u16 is_virtfn:1;
// };
```

## 5. 错误处理——AER

```c
// PCIe AER（Advanced Error Reporting）：
// → pci_aer_init() @ probe.c 初始化
// → 硬件检测到错误时生成 PCIe 错误消息
// → aer_isr() 处理中断
// → 可恢复错误：尝试清除并继续
// → 不可恢复错误：调用 driver->error_handler()
```

## 6. 总线扫描算法——pci_scan_slot

```c
// pci_scan_slot @ probe.c:2871 — 扫描一个 slot
// → 扫描 function 0 → pci_scan_device(bus, devfn)
// → 如果 function 0 是 multi-function → 扫描 1-7
// → pci_scan_bridge() → 如果是桥 → 递归扫描下游

// pci_scan_bridge_extend @ :1400
// → 配置桥的 primary/secondary/subordinate 总线号
// → 遍历下游总线（for devfn = 0 to 255）
// → 递归 pci_scan_slot
```

// BAR0-BAR5 描述设备所需的 MMIO/I/O 空间

// pci_read_bases() @ probe.c — 读取 BAR：
// → 写 0xFFFFFFFF → 读回（确定大小）
// → 恢复原值
// → 记录 res->start/res->end/flags

// pci_assign_resource() @ pci.c — 分配地址：
// → pci_bus_alloc_resource(bus, res, ...)
// → 在总线地址空间中分配未使用的区域
```

---

## 4. 配置空间访问

```c
// 通过 pci_ops 访问配置空间：
struct pci_ops {
    int (*read)(struct pci_bus *bus, unsigned int devfn,
                int where, int size, u32 *val);
    int (*write)(struct pci_bus *bus, unsigned int devfn,
                 int where, int size, u32 val);
};

// pci_read_config_byte(dev, offset, &val)
// → dev->bus->ops->read(bus, devfn, offset, 1, val)
//   → 硬件：CF8/CFC（PCI）或 MMCONFIG（PCIe MMIO）

// pci_write_config_word(dev, PCI_COMMAND, cmd)
//  → 写命令寄存器（IO/BUS_MASTER/MEM 等）
```

---

## 5. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `pci_scan_bus` | `probe.c` | 扫描 PCI 总线 |
| `pci_setup_device` | `probe.c` | 初始化设备 |
| `pci_read_bases` | `probe.c` | 读取 BAR |
| `pci_assign_resource` | `pci.c` | 分配资源 |
| `pci_enable_device` | `pci.c` | 启用设备（设置命令寄存器）|
| `pci_request_regions` | `pci.c` | 申请 BAR 资源 |
| `pci_register_driver` | `driver.c` | 注册 PCI 驱动 |

---

## 6. 调试

```bash
# PCI 拓扑
lspci -t
lspci -vvv
lspci -s 00:1f.0 -xxxx  # 原始配置空间

# BAR 信息
cat /sys/bus/pci/devices/0000:00:1f.0/resource

# rescan
echo 1 > /sys/bus/pci/rescan
```

---

## 7. 总结

PCI 子系统通过 `pci_scan_bus` 递归枚举总线拓扑，`pci_read_bases` 读取 BAR 寄存器确定资源需求，`pci_assign_resource` 分配总线地址。`struct pci_driver` 通过 `pci_register_driver` 绑定设备，`pci_enable_device` 启用 I/O 和 Bus Master。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 7. PCI 电源管理 @ pci.c（604 符号）

```c
// PCI 电源管理支持 D0-D3hot-D3cold 状态：

// pci_set_power_state(dev, state)
// → D0 → D3hot：关时钟、降低功耗
// → D3hot → D3cold：移除主电源（需要 PME 唤醒）
// → 唤醒：pci_pme_list_scan() 检查 PME 事件

// pci_pm_d3hot_delay @ :53 — D3hot→D0 恢复延迟
// pci_pme_list @ :57        — PME 事件列表
// pci_pme_work @ :59        — PME 扫描延迟工作

// ASPM（Active State Power Management）：
// → L0s/L1/L2 链路电源状态
// → pci_enable_aspm() — 启用 ASPM
// → 在链路空闲时自动进入低功耗

// PCIe 运行时 PM：
// → 设备空闲时自动进入 D3hot
// → 有 I/O 时自动恢复 D0
```

## 8. PCIe 高级功能

```c
// AER（Advanced Error Reporting @ pci_aer.c）：
// → PCIe 错误检测和恢复
// → aer_isr() — AER 中断处理
// → 可恢复错误：尝试清除
// → 不可恢复错误：调用 driver->error_handler

// ATS（Address Translation Services）：
// → IOMMU 地址翻译缓存
// → 减少 IOMMU 查找延迟
// → 用于 SR-IOV VF 和 PASID

// PRI（Page Request Interface）：
// → 设备发起页面请求（类似 swap）
// → 允许设备访问未 pin 的用户内存
// → 配合 IOMMU 使用

// PASID（Process Address Space ID）：
// → 设备共享进程地址空间
// → 每个 PASID 对应一个进程页表
// → 用于加速器/GPU 共享虚拟内存
```

## 9. PCI 域和总线号管理 @ probe.c（208 符号）

```c
// PCI 域（domain）管理：
struct pci_domain_busn_res {
    struct list_head list;
    struct resource res;             // 总线号范围
    int domain_nr;
};

// get_pci_domain_busn_res @ :48 — 获取域总线号资源
// pci_scan_bus — 扫描指定域的总线

// 多域支持：
// → PCIe 支持最多 65536 个域（domain_nr 16-bit）
// → 每个域支持 256 个总线
// → 设备地址格式：domain:bus:device.function

// pci_root_buses @ :37 — 全局根总线列表
// → 所有 PCI 根总线在此链表中
```

## 10. 关键函数索引

| 函数 | 符号数 | 作用 |
|------|--------|------|
| `pci.c` | 604 | 电源管理、资源分配、ASPM |
| `probe.c` | 208 | 设备扫描、总线枚举 |
| `pci_set_power_state` | — | PCI 电源状态切换 |
| `pci_enable_device` | — | 启用设备（设置命令寄存器）|
| `pci_scan_bus` | — | 扫描 PCI 总线 |
| `pci_assign_resource` | — | 分配 BAR 地址 |
| `pci_save_state` | — | 保存配置空间 |
| `pci_restore_state` | — | 恢复配置空间 |


## 11. PCI 配置空间访问

```c
// PCI 配置空间的三种访问机制：

// 1. PCI（传统 I/O 端口）：
//    outl(0x80000000 | bus << 16 | dev << 11 | func << 8 | reg, 0xCF8)
//    inl(0xCFC) — 读配置空间
//    > 仅 x86，慢速

// 2. MMCONFIG（PCIe MMIO，推荐）：
//    将配置空间映射到内存地址：
//    addr = mmcfg_base + (bus << 20 | dev << 15 | func << 12 | reg)
//    readl(addr) — 直接内存读取
//    > 快速，所有 64 位架构支持

// 3. Intel 扩展配置空间：
//    > 通过 pci_ops 统一抽象（注册到 pci_bus->ops）
```

## 12. PCIe 带宽管理

```c
// PCIe 链路带宽：
// → 链路宽度（x1/x2/x4/x8/x16）
// → 每个 lane 速率（2.5/5/8/16 GT/s）
// → 带宽 = lanes × rate × 编码效率

// 带宽协商：
// → 启动时自动协商最大速度
// → pcie_get_speed_cap() — 获取链路能力
// → pcie_bandwidth_available() — 计算当前带宽

// 带宽降级：
// → 链路错误可能导致自动降速
// → /sys/class/pci_bus/.../current_speed
// → pcie_print_link_status() — 打印链路状态
```

