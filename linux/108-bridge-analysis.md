# bridge — 网桥设备深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/bridge/br_device.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**bridge**（网桥）是二层交换机设备，连接多个网段，通过 MAC 学习进行转发。

---

## 1. 核心数据结构

### 1.1 net_bridge — 网桥

```c
// net/bridge/br_private.h — net_bridge
struct net_bridge {
    // 设备
    struct net_device       *dev;           // 网桥设备
    struct net               *net;           // 网络命名空间

    // 端口
    struct list_head        port_list;        // 端口链表
    unsigned int            ports_count;       // 端口数

    // MAC 表
    struct br_fdb_hash      fdb_hash;         // MAC 地址哈希表
    unsigned long           bridge_ageing_time; // MAC 条目老化时间

    // STP（生成树协议）
    int                     stp_enabled;      // 是否启用 STP
    unsigned char           bridge_id;        // 桥 ID
    unsigned char           root_id;          // 根桥 ID
};
```

### 1.2 net_bridge_port — 网桥端口

```c
// net/bridge/br_private.h — net_bridge_port
struct net_bridge_port {
    struct net_bridge       *br;              // 所属网桥
    struct net_device       *dev;             // 底层设备
    unsigned int            port_no;           // 端口号

    // 状态
    unsigned char           state;            // PORT_STATE_*
    //   PORT_STATE_DISABLED   = 0
    //   PORT_STATE_BLOCKING    = 1
    //   PORT_STATE_LEARNING    = 2
    //   PORT_STATE_FORWARDING  = 3

    // MAC 学习
    unsigned long           designated_age;

    // STP
    unsigned char           path_cost;         // 路径成本
    unsigned char           priority;         // 优先级
};
```

---

## 2. MAC 学习

### 2.1 br_fdb_insert — 学习 MAC

```c
// net/bridge/br_fdb.c — br_fdb_insert
void br_fdb_insert(struct net_bridge *br, struct net_bridge_port *port,
                  const unsigned char *addr, unsigned int vid)
{
    struct hlist_node *p;

    // 1. 查找或创建 MAC 条目
    struct net_bridge_fdb_entry *fdb = br_fdb_find(br, addr, vid);

    if (fdb) {
        // 2. 更新已有条目
        fdb->port = port;
        fdb->updated = jiffies;
    } else {
        // 3. 新增条目
        br_fdb_add(br, port, addr, vid);
    }
}
```

---

## 3. 转发流程

```c
// net/bridge/br_forward.c — br_handle_frame
int br_handle_frame(struct sk_buff *skb)
{
    struct net_bridge_port *p = br_port_get(skb->dev);
    unsigned char *dest = eth_hdr(skb)->h_dest;

    // 1. 如果是混杂模式，直接转发
    if (p->state == PORT_STATE_FORWARDING) {
        if (is_multicast_ether_addr(dest)) {
            // 组播：泛洪到所有端口（除了源）
            br_flood_forward(skb, p);
        } else {
            // 单播：查找 MAC 表
            struct net_bridge_fdb_entry *fdb = br_fdb_find(br, dest, 0);

            if (fdb && fdb->port != p) {
                // 直接转发到目标端口
                br_forward(fdb->port, skb);
            } else {
                // 未知：泛洪
                br_flood_forward(skb, p);
            }
        }
    }
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/bridge/br_private.h` | `net_bridge`、`net_bridge_port` |
| `net/bridge/br_fdb.c` | `br_fdb_insert`、`br_fdb_find` |
| `net/bridge/br_forward.c` | `br_handle_frame` |