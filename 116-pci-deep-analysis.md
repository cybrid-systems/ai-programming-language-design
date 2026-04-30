# Linux Kernel PCI (深入) / MSI / BAR 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/pci/` + `arch/x86/kernel/apic/apic.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. PCI 配置空间

每个 PCI 设备有 256 字节配置空间，前 16 字节是**设备 ID**：

```
偏移 0x00: Vendor ID（厂商 ID）
偏移 0x02: Device ID（设备 ID）
偏移 0x04: Command（命令寄存器）
偏移 0x06: Status（状态寄存器）
偏移 0x08: Revision ID
偏移 0x09: Class Code（类码，如 0x010802 = NVMe SSD）
偏移 0x0C: Header Type（0 = 普通设备，1 = PCI-to-PCI 桥）
```

---

## 1. BAR (Base Address Register)

```c
// BAR 告诉操作系统设备需要多少 MMIO 地址空间
// BAR[0]: 通常映射到 PCIe BAR 0（内存映射 I/O）
// BAR[1]: 通常映射到 PCIe BAR 1
// BAR[2]: 可能映射到 ROM

// 用户空间查看：
// lspci -v → Memory at fbd00000 (32-bit, non-prefetchable) [size=1M]

// 操作系统分配：
// pci_enable_device() → 检查 BAR → ioremap() 映射到虚拟地址
// 驱动访问：readl(bar0_va + 0x04) → 读寄存器
```

---

## 2. MSI (Message Signaled Interrupt)

**MSI** 替代传统边沿中断，通过**写内存地址**触发中断，避免共享 INTA 线：

```c
// MSI Capability 结构：
//   Message Address: 目标地址（通常是 LAPIC 地址）
//   Message Data: 中断向量 + 触发模式

// MSI-X: 支持更多向量（2048 个），比 MSI（32 个）更灵活
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/pci/pci.c` | `pci_enable_device`、`pci_read_config`、`pci_write_config` |
| `drivers/pci/msi.c` | MSI/MSI-X 中断 |
| `drivers/pci/host/msi.c` | 特定平台的 MSI |
