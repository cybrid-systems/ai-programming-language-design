# bonding / team — 链路聚合深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/net/bonding/bond_main.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**bonding/team** 将多个物理网卡聚合成一个逻辑接口，实现冗余或带宽聚合。

---

## 1. bond 模式

```c
// 模式 0: balance-rr（轮询）
// 模式 1: active-backup（主备）
// 模式 2: balance-xor（异或）
// 模式 3: broadcast（广播）
// 模式 4: 802.3ad（LACP）
// 模式 5: balance-tlb（自适应负载）
// 模式 6: balance-alb（自适应负载均衡）
```

---

## 2. 核心数据结构

```c
// drivers/net/bonding/bond_main.c — bond_dev
struct bonding {
    struct net_device       *dev;           // 主设备
    struct list_head        slave_list;       // 从设备链表
    struct net_device       *active_slave;   // 当前活跃从设备
    u32                     curr_active_slave; // 活跃从设备索引

    // 模式
    int                     mode;            // 模式（0-6）
    int                     arp_interval;    // ARP 探测间隔
    int                     miimon;          // MII 监控间隔

    // 负载均衡
    struct bond_up_slave   *rr_slave;        // 轮询从设备
};
```

---

## 3. 主备切换

```c
// drivers/net/bonding/bond_main.c — bond_select_active_slave
static void bond_select_active_slave(struct bonding *bond)
{
    struct list_head *tmp;
    struct slave *best;

    // 1. 查找可用从设备
    list_for_each(tmp, &bond->slave_list) {
        slave = list_entry(tmp, struct slave, list);
        if (slave->link == BOND_LINK_UP &&
            slave->state == BOND_STATE_ACTIVE)
            best = slave;
    }

    // 2. 切换到新活跃从设备
    bond->active_slave = best;
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/net/bonding/bond_main.c` | `struct bonding`、`bond_select_active_slave` |