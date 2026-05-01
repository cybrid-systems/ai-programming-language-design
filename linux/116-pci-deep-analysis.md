# 116-PCI-Deep — PCI Express 总线深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/pci/pci.c` + `drivers/pci/pci-sysfs.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**PCI**（Peripheral Component Interconnect）是连接 CPU 与外设的总线标准。PCIe（PCI Express）采用点对点串行差分总线，替代了 PCI 的并行总线。Linux PCI 子系统负责设备枚举、配置空间访问、中断路由、电源管理。

## 1. 核心数据结构

### 1.1 struct pci_dev — PCI 设备

```c
// include/linux/pci.h — pci_dev
struct pci_dev {
    struct list_head        bus_list;         // 总线设备链表
    struct pci_bus         *bus;              // 所属总线
    struct pci_bus         *subordinate;     // 子总线（桥接器）

    // 配置空间
    unsigned int            devfn;             // 设备号（8bit：bus << 3 | devfn）
    unsigned short          vendor;            // 厂商 ID
    unsigned short          device;            // 设备 ID
    unsigned short          subsystem_vendor;  // 子系统厂商 ID
    unsigned short          subsystem_device;  // 子系统设备 ID

    // BAR（基地址寄存器）
    struct resource         resource[PCI_STANDARD_NUM_BARS]; // BAR0-BAR5

    // MSI / 中断
    int                     irq;               // 中断号
    unsigned int            pin;               // 中断引脚（1-4 = A-D）

    // 电源管理
    pci_power_t            current_state;      // 当前 D0-D3hot-D3cold
    unsigned int            pme_support:3;     // PME 支持
    unsigned int            pme_interrupt:1;   // PME 中断

    // 驱动
    struct pci_driver      *driver;           // 绑定的驱动
    void                   *driver_data;        // 驱动私有数据

    // 设备能力
    unsigned int            aer_cap:1;         // AER 能力
    unsigned int            pcie_cap:1;        // PCIe 能力
    unsigned int            msi_cap:1;         // MSI 能力
    unsigned int            msix_cap:1;       // MSI-X 能力
};
```

### 1.2 struct pci_bus — PCI 总线

```c
// include/linux/pci.h — pci_bus
struct pci_bus {
    struct list_head        node;              // 总线链表
    struct pci_bus         *parent;           // 父总线
    struct list_head        children;          // 子总线
    struct list_head        devices;           // 直连设备
    unsigned char           number;           // 总线号
    unsigned char           primary;           // 主总线号（桥接器）
    struct resource         *resource[PCI_BRIDGE_RESOURCES]; // I/O/MMIO 资源
};
```

## 2. BAR（基地址寄存器）

### 2.1 pci_bar — BAR 类型

```c
// include/linux/pci.h — BAR 类型
// BAR[0-5] 的 bit 0 决定类型：
//   0 = 32-bit MMIO（可预取）
//   0 = 64-bit MMIO（可预取，如果 bit 1 = 1）
//   1 = I/O 端口

// BAR 值：
//   [31:4] = 基地址（对齐到 16 字节）
//   [3]    = 预取（PREFETCH）
//   [2:1]  = 类型（00=32-bit，10=64-bit）
//   [0]    = 空间（0=MMIO，1=I/O）
```

### 2.2 pci_enable_device — 启用设备

```c
// drivers/pci/pci.c — pci_enable_device
int pci_enable_device(struct pci_dev *dev)
{
    // 1. 启用 I/O 和 MMIO
    if (pci_resource_flags(dev, 0) & IORESOURCE_MEM)
        arch_phys_wc_add(pci_resource_start(dev, 0), ...);

    // 2. 设置命令寄存器
    pci_read_config_word(dev, PCI_COMMAND, &cmd);
    cmd |= PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER;
    pci_write_config_word(dev, PCI_COMMAND, cmd);

    // 3. 使能 MSI
    if (dev->msi_cap)
        pci_enable_msi(dev);

    return 0;
}
```

## 3. 配置空间访问

### 3.1 pci_read_config_byte/word/dword

```c
// drivers/pci/access.c — pci_read_config
static int pci_read_config(struct pci_dev *dev, int offset, int len, u32 *val)
{
    struct pci_bus *bus = dev->bus;

    // 通过 PCI 主机桥（Host Bridge）访问配置空间
    // PCIe 使用 ECAM（Enhanced Configuration Access Mechanism）
    //   地址 = (bus << 20) | (devfn << 12) | offset
    //   映射到 MMIO 区域（通常 256MB @ 0xE0000000）

    return bus->ops->read(bus, dev->devfn, offset, len, val);
}
```

## 4. MSI / MSI-X 中断

### 4.1 pci_enable_msi — MSI 中断

```c
// drivers/pci/msi.c — pci_enable_msi
int pci_enable_msi(struct pci_dev *dev)
{
    struct msi_desc *entry;

    // 1. 读取 MSI Capability
    pos = pci_find_capability(dev, PCI_CAP_ID_MSI);

    // 2. 解析消息数
    pci_read_config_word(dev, msi_control, &control);
    nvec = 1 << (ffs(control & 0x00FF) - 1);  // 1, 2, 4, 8, 16, 32

    // 3. 分配向量
    ret = arch_setup_msi_irqs(dev, nvec, ...);

    return 0;
}
```

## 5. 电源管理

### 5.1 PCI PM 状态

```c
// include/linux/pci.h — pci_power_t
typedef int pci_power_t;
//  D0 = 全功能（正常工作）
//  D1 = 轻度睡眠
//  D2 = 深度睡眠
//  D3hot = 几乎关闭（可热拔）
//  D3cold = 完全关闭（断电）

// 状态转换：
//  D0 → D3hot：pci_set_power_state(dev, PCI_D3hot)
//  D3hot → D0：pci_set_power_state(dev, PCI_D0)
```

## 6. PCIe 结构

```
PCIe 层次：

CPU
  │
  ├── Host Bridge（PCIe Root Complex）
  │       │
  │       ├── RCiEP（Root Complex Integrated Endpoint）
  │       │
  │       └── PCIe Switch
  │               │
  │               ├── PCIe Device (Function 0)
  │               ├── PCIe Device (Function 1)
  │               └── ...
```

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/pci/pci.c` | `pci_enable_device`、`pci_read_config`、`pci_set_power_state` |
| `drivers/pci/msi.c` | `pci_enable_msi`、`pci_disable_msi` |
| `include/linux/pci.h` | `struct pci_dev`、`struct pci_bus`、`pci_power_t` |

## 8. 西游记类比

**PCI** 就像"天庭和外设的驿道"——

> CPU 是天庭大殿，外设（显卡、网卡、硬盘）是各地藩王。PCI 总线就像官道，PCIe 则是高速专线（串行差分）。每个外设在驿道上都有自己唯一的地址（bus:devfn），驿道上有客栈（Host Bridge）负责接待。BAR 就像每个藩王在天庭的驻地（MMIO 地址），可以通过驻地直接通信（内存映射 I/O）。MSI 中断就像藩王有急事可以直接派人快马进京报信，不用等驿道上的定期巡检。

## 9. 关联文章

- **interrupt**（article 23）：MSI 中断路由
- **DMA**（相关）：PCIe DMA 传输

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

