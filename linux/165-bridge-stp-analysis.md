# 165-bridge_stp — 网桥与生成树协议深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/bridge/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Bridge（网桥）** 是 Linux 的软件交换机，将多个以太网接口桥接在一起，形成一个虚拟的交换机。**STP（Spanning Tree Protocol）** 防止桥接网络中的环路。

---

## 1. 核心数据结构

### 1.1 struct net_bridge — 网桥

```c
// net/bridge/br_private.h — net_bridge
struct net_bridge {
    // 端口列表
    struct list_head        port_list;          // 所有 bridge port

    // MAC 地址表
    struct Hashtable       *hash;             // MAC 地址哈希表
    unsigned long           ageing_timer;       // MAC 老化定时器

    // 生成树
    struct br_timer        forward_delay_timer; // 前向延迟计时器
    struct br_timer        topology_change_timer;
    u16                   bridge_id;          // 网桥 ID（Priority + MAC）
    u16                   root_path_cost;     // 到根的路径成本
    u8                    topology_change:1;   // 拓扑变化标志

    // STP
    unsigned char          stp_enabled;        // 是否启用 STP
    u8                    root_port;           // 根端口
    u8                    designated_root;     // 指定根
};
```

### 1.2 struct net_bridge_port — 网桥端口

```c
// net/bridge/br_private.h — net_bridge_port
struct net_bridge_port {
    struct net_bridge      *br;               // 所属网桥
    struct net_device      *dev;              // 底层 netdevice

    // 端口 ID
    u8                    port_id;           // 端口 ID
    u8                    designated_root;    // 端口的指定根
    u8                    designated_bridge;  // 端口的指定网桥

    // 成本
    u32                   path_cost;        // 端口路径成本

    // 状态
    u8                    state;             // 端口状态
    //   BR_STATE_DISABLED = 0
    //   BR_STATE_BLOCKING = 1  (STP 阻塞)
    //   BR_STATE_LISTENING = 2  (STP 监听)
    //   BR_STATE_LEARNING = 3  (STP 学习)
    //   BR_STATE_FORWARDING = 4 (正常转发)
    //   BR_STATE_DISCARDING = 5 (STP 丢弃)

    // 标志
    unsigned char          topology_change_ack:1;
    unsigned char          config_pending:1;
};
```

---

## 2. MAC 地址学习

### 2.1 br_fdb_insert — MAC 学习

```c
// net/bridge/br_fdb.c — br_fdb_insert
void br_fdb_insert(struct net_bridge *br, struct net_bridge_port *source,
                   const unsigned char *addr, u16 vid)
{
    struct hlist_head *head = &br->hash[br_mac_hash(addr, vid)];
    struct net_bridge_fdb_entry *fdb;

    // 查找是否已存在
    hlist_for_each_entry(fdb, head, hlist) {
        if (ether_addr_equal(fdb->addr, addr) && fdb->vid == vid)
            return;  // 已存在，更新
    }

    // 新增 MAC 条目
    fdb = kmem_cache_alloc(br_fdb_cache, GFP_ATOMIC);
    fdb->addr = ether_addr_copy(addr);
    fdb->port = source;
    fdb->vid = vid;
    fdb->updated = jiffies;

    hlist_add_head_rcu(&fdb->hlist, head);
}
```

---

## 3. STP（生成树协议）

### 3.1 BPDU（Bridge Protocol Data Unit）

```
STP 报文格式：
  ┌──────────────┬──────────────┐
  │ Protocol ID (2) │ Version (1) │
  ├──────────────┴──────────────┤
  │ Message Type (1) │ Flags (1) │
  ├─────────────────────────────┤
  │ Root ID (8) │                   │
  ├─────────────────────────────┤
  │ Root Path Cost (4) │           │
  ├─────────────────────────────┤
  │ Bridge ID (8) │               │
  ├─────────────────────────────┤
  │ Port ID (2) │                 │
  ├─────────────────────────────┤
  │ Message Age (2) │             │
  │ Max Age (2) │                │
  │ Hello Time (2) │              │
  │ Forward Delay (2) │           │
  └─────────────────────────────────┘
```

### 3.2 br_bpdu_switch — 处理 BPDU

```c
// net/bridge/br_stp.c — br_bpdu_switch
void br_bpdu_switch(struct net_bridge_port *p, struct sk_buff *skb)
{
    struct br_config_bpdu *bpdu;

    // 解析 BPDU
    bpdu = br_stp_parse(skb);

    switch (bpdu->type) {
    case BPDU_TYPE_CONFIG:
        // 配置 BPDU
        br_config_bpdu_fwrd(p, bpdu);
        break;

    case BPDU_TYPE_TCN:
        // 拓扑变更通知
        br_tcn_fwrd(p);
        break;
    }
}
```

### 3.3 端口状态机

```
端口状态转换：

DISABLED（禁用）
    │（启用）
    ▼
BLOCKING（阻塞）←──────────────┐
    │（收到配置 BPDU，显示优于当前）│
    ▼                              │
LISTENING（监听）                  │
    │（等待 forward_delay）        │
    ▼                              │
LEARNING（学习）                    │
    │（等待 forward_delay）        │
    ▼                              │
FORWARDING（转发）──────┐          │
    │（收到更优 BPDU） │          │
    ▼                    │          │
DISCARDING（丢弃）──────┘          │
    │                            │
    └──────────────────────────┘
```

---

## 4. 快速生成树（RSTP/MSTP）

```c
// RSTP（快速生成树）增加了：
// - 提议-同意机制（Proposal-Agreement）
// - 端口角色：根端口、指定端口、备用端口、备份端口
// - 边缘端口（Edge Port）：直接转发，不参与 STP

// MSTP（多生成树）：
// - 多个 VLAN 映射到同一个生成树实例
// - 减少 BPDU 数量
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/bridge/br_private.h` | `struct net_bridge`、`struct net_bridge_port` |
| `net/bridge/br_fdb.c` | `br_fdb_insert`、`br_fdb_update` |
| `net/bridge/br_stp.c` | `br_bpdu_switch`、`br_stp_enable` |

---

## 6. 西游记类喻

**Bridge + STP** 就像"天庭的交通调度站"——

> Bridge 像一个虚拟的交通枢纽，把多条路（以太网接口）连接成一个大的互通网络。每个通过枢纽的车（帧）都会被记录下来（MAC 学习），下次就知道某个地方的车该从哪个口出去。STP 像交通调度算法，防止同时有多条路形成环形导致交通混乱（广播风暴）。如果某个路口坏了，STP 会自动找一条替代路线，保证整个网络还是通的。RSTP 则像升级版的调度系统，能更快地发现替代路线。

---

## 7. 关联文章

- **netdevice**（article 137）：bridge port 也是 netdevice
- **VLAN**（article 109）：bridge + VLAN 实现虚拟局域网隔离