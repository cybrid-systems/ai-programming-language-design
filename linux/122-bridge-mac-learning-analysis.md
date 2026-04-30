# Linux Kernel Bridge / MAC Learning 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/bridge/br_forward.c` + `net/bridge/br_fdb.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：MAC 学习、洪泛、生成树、fdb_entry、br_fdb_find

---

## 1. 核心数据结构

### 1.1 net_bridge_fdb_entry — MAC 表条目

```c
// net/bridge/br_fdb.c — net_bridge_fdb_entry
struct net_bridge_fdb_entry {
    // 哈希节点（接入 fdb_hash_tbl）
    struct rhash_head          rhnode;              // 行 26

    // 哈希 key（MAC 地址 + VLAN ID）
    struct {
        unsigned char         addr[ETH_ALEN];  // MAC 地址
        __u16                 vlan_id;         // VLAN ID
        unsigned char         is_local:1;     // 本地 MAC
        unsigned char         is_static:1;    // 静态 MAC
    } key;

    // 所属网桥
    struct net_bridge          *br;                  // 行 37

    // 所属端口
    struct net_bridge_port     *addr;               // 行 40

    // 引用计数
    kref_t                    kref;                // 行 43

    // 老化定时器
    struct timer_list          timer;              // 行 46

    // 哈希信息
    struct rcu_head           rcu;                // 行 49
};
```

---

## 2. MAC 学习流程

```c
// net/bridge/br_fdb.c — br_fdb_find
static struct net_bridge_fdb_entry *br_fdb_find(struct net_bridge *br,
                          const unsigned char *addr, __u16 vlan_id)
{
    // 1. 计算 MAC + VLAN 的哈希
    // 2. 在 fdb_hash_tbl（rhashtable）中查找
    return rhashtable_lookup_fast(&br->fdb_hash_tbl, &key, br_fdb_rht_params);
}

// 收到帧时学习：
void br_fdb_update(struct net_bridge *br, struct net_bridge_port *source,
               const unsigned char *addr, __u16 vlan_id, int added_by_user)
{
    // 1. 查找是否已存在
    fdb = br_fdb_find(br, addr, vlan_id);

    if (fdb) {
        // 2. 已存在：更新端口和老化时间
        fdb->addr = source;
        fdb->updated = jiffies;
    } else {
        // 3. 不存在：添加新条目
        br_fdb_add_entry(br, source, addr, vlan_id, is_static);
    }
}
```

---

## 3. 转发决策

```c
// net/bridge/br_forward.c — br_flood_deliver
static void br_flood_deliver(struct net_bridge *br, struct sk_buff *skb, bool unicast)
{
    struct net_bridge_port *p;

    // 洪泛到所有端口（除接收端口）
    list_for_each_entry_rcu(p, &br->port_list, list) {
        if (br_should_deliver(p, skb))
            __br_deliver(p, skb);
    }
}

// 转发决策：
void br_handle_frame(struct net_bridge_port *p, struct sk_buff *skb)
{
    // 1. 解析目的 MAC
    dest = eth_hdr(skb)->h_dest;

    // 2. 如果是广播/多播：洪泛
    if (is_multicast(dest)) {
        br_flood_deliver(br, skb, false);
        return;
    }

    // 3. 查找 MAC 表
    fdb = br_fdb_find(br, dest, skb->vlan_tci);

    if (fdb) {
        // 4. 已知单播：仅从对应端口发出
        __br_deliver(fdb->addr, skb);
    } else {
        // 5. 未知单播：洪泛
        br_flood_deliver(br, skb, true);
    }
}
```

---

## 4. 参考

| 文件 | 函数 | 行 |
|------|------|-----|
| `net/bridge/br_fdb.c` | `br_fdb_find` | 220 |
| `net/bridge/br_fdb.c` | `br_fdb_update` | 学习入口 |
| `net/bridge/br_forward.c` | `br_flood_deliver` | 洪泛 |
| `net/bridge/br_forward.c` | `br_handle_frame` | 帧处理入口 |
