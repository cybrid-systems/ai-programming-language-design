# Linux Kernel bonding / team 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/bonding/` + `drivers/net/team/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. bonding vs team

| 特性 | bonding | team |
|------|---------|------|
| 驱动 | 传统，单一维护者 | 新驱动，teamd 用户空间 |
| 模式 | 7 种（0-6）| 5 种 |
| 负载均衡 | 部分支持 | 原生支持 |
| 状态 | 活跃备份 / 负载均衡 | 更灵活 |

---

## 1. bonding 模式

```
mode 0 (balance-rr):     轮询发送，冗余但可能乱序
mode 1 (active-backup):   一主一备，自动切换
mode 2 (balance-xor):     哈希 (src_mac ^ dst_mac) % nics
mode 3 (broadcast):        所有 nic 都发相同帧
mode 4 (802.3ad):          LACP 链路聚合
mode 5 (balance-tlb):      发送负载均衡
mode 6 (balance-alb):     接收+发送负载均衡
```

---

## 2. 核心结构

```c
// drivers/net/bonding/bond_main.c — bonding 设备
struct bonding {
    struct net_device       *dev;           // bond 设备（如 bond0）
    struct slave            *active_slave; // 当前活跃从设备
    struct list_head        slave_list;    // 所有从设备
    u32                     params.mode;    // 模式
    struct ad_bond          *ad;           // 802.3ad 聚合器
};
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/net/bonding/bond_main.c` | bonding 核心 |
| `drivers/net/team/team.c` | team 驱动 |
