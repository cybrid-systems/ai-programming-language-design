# VLAN 与 VXLAN 隧道机制深度分析

**关键词**: VLAN, VXLAN, FDB, VNI, UDP 隧道, 802.1Q, 数据平面, 控制平面

**内核源码**: Linux 7.0-rc1 (`/home/dev/code/linux`)

---

## 一、802.1Q VLAN 数据流完整路径

### 1.1 核心数据结构与 skb->vlan_tci

VLAN tag 信息存储在 `sk_buff` 的两个字段中（`include/linux/skbuff.h:1052-1053`）：

```c
__be16  vlan_proto;   // 0x8100 (Ethernet) 或其他 VLAN 协议
__u16   vlan_tci;     // VLAN Tag Control Information: {VID(12bit), CFI(1bit), Priority(3bit)}
```

这两个字段是**硬件加速路径**的关键：当设备驱动收到一个已带 VLAN tag 的数据包时，直接将 tag 信息写入 `skb->vlan_proto` / `skb->vlan_tci`，无需修改数据区域——这就是"hardware accelerated"（`__vlan_hwaccel_put_tag`）的含义。

### 1.2 从 eth0 接收到打上 VLAN tag 出去的完整路径

```
[物理 NIC 硬件]
      ↓ (硬中断/DMA，skb 携带 vlan_tci 来自 hardware descriptor)
[netif_receive_skb / __netif_receive_skb_core]
      ↓ 检查 skb->vlan_tci 是否有效 (pskb_vlan_try_manage_partial())
      ↓ 如果有效，__vlan_hwaccel_put_tag 已在驱动的 ndo_start_xmit 中完成
      ↓ 注册 softnet_data 后端队列
[eth0 的 ndo_start_xmit]
      ↓ (数据包打 VLAN tag 后进入 eth0.100 的 netdev)
[vlan_dev_hard_start_xmit()]  // net/8021q/vlan_dev.c:100
      ↓
  ┌─────────────────────────────────────────────────────┐
  │ // 关键代码：vlan_dev.c:100-135                    │
  │ struct vlan_dev_priv *vlan = vlan_dev_priv(dev);  │
  │ struct vlan_ethhdr *veth = (struct vlan_ethhdr *)(skb->data);
  │                                                  │
  │ // REORDER_HDR 或 非本 VLAN 协议的包，打新的 tag    │
  │ if (vlan->flags & VLAN_FLAG_REORDER_HDR ||        │
  │     veth->h_vlan_proto != vlan->vlan_proto) {     │
  │     u16 vlan_tci;                                 │
  │     vlan_tci = vlan->vlan_id;                     │
  │     vlan_tci |= vlan_dev_get_egress_qos_mask(...);│
  │     __vlan_hwaccel_put_tag(skb, vlan->vlan_proto, │
  │                            vlan_tci);              │
  │ }                                                 │
  │                                                  │
  │ // 交给下层真实设备                                │
  │ skb->dev = vlan->real_dev;                        │
  │ dev_queue_xmit(skb);                              │
  └─────────────────────────────────────────────────────┘
      ↓ 到达真实物理设备（如 eth0）
[eth0 驱动发送]
```

**三个关键的 tag 插入函数**（`include/linux/if_vlan.h`）：

| 函数 | 路径 | 行为 |
|------|------|------|
| `vlan_insert_tag()` | 分配新 skb，插入完整 VLAN header | 返回新 skb，修改数据区 |
| `__vlan_insert_tag()` | 直接插入字节，不分配 skb | 原地修改，数据长度+4B |
| `__vlan_hwaccel_put_tag()` | 不修改数据，**只写 skb->vlan_tci** | 硬件加速，零拷贝 |

**vlan_insert_tag（用于发送方向，在需要真正插入 tag 到数据时）**的实现路径：

```
vlan_insert_tag()
  → vlan_insert_inner_tag()
    → __vlan_insert_inner_tag(skb, vlan_proto, vlan_tci, ETH_HLEN)
         → 在 MAC 头后面（ETH_HLEN 位置）插入 4 字节 VLAN tag
         → 写入 h_vlan_TCI (TCI = VID + PCP + CFI)
         → 设置 skb->protocol = vlan_proto (0x8100)
```

**__vlan_hwaccel_put_tag（用于软硬件协作的加速路径）**的实现（`if_vlan.h:537-550`）：

```c
static inline void __vlan_hwaccel_put_tag(struct sk_buff *skb,
                                           __be16 vlan_proto, u16 vlan_tci)
{
    skb->vlan_proto = vlan_proto;  // 存储协议类型
    skb->vlan_tci = vlan_tci;     // 存储 VID+PCP+CFI
}
```

调用链（`vlan_dev_hard_start_xmit`）：
- 条件：`veth->h_vlan_proto != vlan->vlan_proto` 时才需要在数据中插入 tag
- `__vlan_hwaccel_put_tag`：对于硬件可以自己加 tag 的情况，只写 metadata
- `vlan_insert_tag_set_proto`：主动插入并更新 `skb->protocol`

### 1.3 VLAN 数据流 ASCII 图

```
                          VLAN Tag 写入路径
                          ================

  上层发送 (不含 tag 的原始 Ethernet 帧)
       |
       v
  +--------+     __vlan_hwaccel_put_tag()      +----------+
  | vlan100 | → skb->vlan_proto = 0x8100   → | real_dev | → 硬件自动插入 VLAN header
  | netdev |   skb->vlan_tci = VID(100)       +----------+
  +--------+

  或者（REORDER_HDR 模式）：
       |
       v
  +--------+     __vlan_insert_tag()           +----------+
  | vlan100 | → skb 内部数据复制               | real_dev |
  | netdev  |   插入 4 字节 {TPID, TCI}        +----------+
  +--------+   skb->protocol = 0x8100
```

---

## 二、VXLAN 封装逻辑完整路径

### 2.1 VXLAN 与 VLAN 的本质区别

VLAN 是**单播域隔离**机制（基于 IEEE 802.1Q，在 L2 层打 tag），而 VXLAN 是**L2 over UDP**隧道协议（RFC 7348），将整个 Ethernet 帧封装进 UDP，在 L3 网络上构建虚拟 L2 网络。

### 2.2 VXLAN 协议头结构

```c
// include/net/vxlan.h

struct vxlanhdr {
    __be32 vx_flags;    // Bit 27 = VXLAN_HF_VNI (必须置 1)
    __be32 vx_vni;      // 低 24 位为 VNI (低 8 位为 reserved)
};

// VXLAN_HLEN = sizeof(udphdr) + sizeof(vxlanhdr) = 8 + 8 = 16 bytes
#define VXLAN_HLEN (sizeof(struct udphdr) + sizeof(struct vxlanhdr))
```

**VNI (VXLAN Network Identifier)**：
- 24 位标识符（与 VLAN VID 数量相同），支持 16M 个虚拟网络
- 在 `vx_vni` 中存储：低 24 位为 VNI，高 8 位为 Reserved

```c
static inline __be32 vxlan_vni(__be32 vni_field) {
    return (__force __be32)((__force u32)(vni_field & VXLAN_VNI_MASK) << 8);
    // VXLAN_VNI_MASK = cpu_to_be32(0xFFFFFF00)
    // 提取 vni_field 的低 24 位，再左移 8 位（移到 bit 8-31，即高 24 位）
    // 形成"标准化"的 VNI 表示
}
```

### 2.3 VXLAN 端口

```c
// vxlan_core.c:49
static unsigned short vxlan_port __read_mostly = 8472;  // Linux 默认（非 IANA 标准）
module_param_named(udp_port, vxlan_port, ushort, 0444);

// include/net/vxlan.h
#define IANA_VXLAN_UDP_PORT     4789  // IANA 分配的标准端口
#define IANA_VXLAN_GPE_UDP_PORT 4790  // GPE (Generic Protocol Extension)
```

### 2.4 从原始以太帧到 VXLAN 封装的完整路径

**发送路径 (`vxlan_xmit`) — drivers/net/vxlan/vxlan_core.c:2722**：

```
[应用层 / bridge 转发]
      ↓
[vxlan_xmit(skb, dev)]  // vxlan_core.c:2722
      │
      ├─ 检查 VXLAN_F_COLLECT_METADATA (元数据路径)
      ├─ 处理 ARP 代理 (VXLAN_F_PROXY)
      ├─ 处理 MDB 多播 (VXLAN_F_MDB)
      │
      ↓
  +------------------+
  | 查 FDB 表        |  vxlan_find_mac_tx(vxlan, eth->h_dest, vni)
  | vxlan_fdb (MAC,  |  vxlan_core.c:395 / 2791
  |   VNI) -> rdst   |
  +------------------+
      │
      ├─ 没查到 → FDB miss → 发给全零 MAC 条目 (all_zeros_mac) 的远端
      │             (即分布式 ARP/ND miss 处理)
      │
      ↓
  vxlan_xmit_one(skb, dev, vni, rdst, did_rsc)
  vxlan_core.c:2341
      │
      ├─ 1) 检查是否为本地绕过 (encap_bypass_if_local) → vxlan_encap_bypass
      │
      ├─ 2) 通过 UDP tunnel 查路由: udp_tunnel_dst_lookup()
      │         获取: 路由、src_port、dst_port
      │         src_port = udp_flow_src_port()  (基于 skb hash 在 [port_min, port_max] 范围选择)
      │         dst_port = rdst->remote_port ? : vxlan->cfg.dst_port
      │
      ├─ 3) 构建 VXLAN 头 (vxlan_build_skb):
      │         __skb_push(skb, sizeof(*vxh));  // 留出 VXLAN 头空间
      │         vxh->vx_flags = VXLAN_HF_VNI;  // 必须置 1 表示有 VNI
      │         vxh->vx_vni   = vxlan_vni_field(vni);  // 填入 VNI
      │
      ├─ 4) 外层 IP + UDP 头由 udp_tunnel_xmit_skb() 完成
      │         路径: udp_tunnel_xmit_skb() → udp_sendmsg() → ip_push_pending_frames()
      │
      └─ Outer Header 格式:
         +--------+--------+--------+--------+
         |  Outer IP Header (20B IPv4)         |
         +--------+--------+--------+--------+
         |  UDP (src_port=hash, dst_port=4789) |
         +--------+--------+--------+--------+
         |  VXLAN Header (8B: flags+VNI)       |
         +--------+--------+--------+--------+
         |  Inner Ethernet Frame (原始帧)       |
         +--------+--------+--------+--------+
```

**详细代码路径（`vxlan_build_skb` — vxlan_core.c:2185）**：

```c
static int vxlan_build_skb(struct sk_buff *skb, struct dst_entry *dst,
                           int iphdr_len, __be32 vni,
                           struct vxlan_metadata *md, u32 vxflags,
                           bool udp_sum)
{
    // 计算最小 headroom（留出空间）
    min_headroom = LL_RESERVED_SPACE(dst->dev) + dst->header_len
                    + VXLAN_HLEN + iphdr_len;  // VXLAN_HLEN = 16B
    err = skb_cow_head(skb, min_headroom);       // 扩展 headroom

    // 处理 offloads (GSO, checksum)
    err = iptunnel_handle_offloads(skb, type);  // SKB_GSO_UDP_TUNNEL

    // 写入 VXLAN 头
    vxh = __skb_push(skb, sizeof(*vxh));
    vxh->vx_flags  = VXLAN_HF_VNI;           // BIT(27) = VNI 标志
    vxh->vx_vni    = vxlan_vni_field(vni);   // VNI 在 bit[31:8]

    // GBP / GPE 扩展
    if (vxflags & VXLAN_F_GBP)
        vxlan_build_gbp_hdr(vxh, md);
    if (vxflags & VXLAN_F_GPE)
        vxlan_build_gpe_hdr(vxh, skb->protocol);

    // 设置内部协议
    udp_tunnel_set_inner_protocol(skb, double_encap, inner_protocol);
    return 0;
}
```

### 2.5 VXLAN Headroom 和 Fragmentation 处理

```c
// vxlan_core.c:2208
min_headroom = LL_RESERVED_SPACE(dst->dev) + dst->header_len
               + VXLAN_HLEN + iphdr_len;
err = skb_cow_head(skb, min_headroom);  // 扩展 headroom，如果不够则重新分配

// PMTU 检查 (vxlan_core.c:2521)
err = skb_tunnel_check_pmtu(skb, ndst, vxlan_headroom(flags & VXLAN_F_GPE), ...);
if (err < 0) {
    goto tx_error;
} else if (err) {
    // PMTU 超过限制，触发本地回送（encap bypass）
    // 即外层目的地址 = 本地，回环给本地 vxlan 设备
    vxlan_encap_bypass(skb, vxlan, vxlan, vni, false);
    dst_release(ndst);
    goto out_unlock;
}

// DF flag 处理
if (vxlan->cfg.df == VXLAN_DF_SET)
    df = htons(IP_DF);
else if (vxlan->cfg.df == VXLAN_DF_INHERIT) {
    // 继承 inner IP 的 DF 设置
    if (eth->h_proto == ETH_P_IPV6 ||
        (ntohs(eth->h_proto) == ETH_P_IP && old_iph->frag_off & htons(IP_DF)))
        df = htons(IP_DF);
}
```

---

## 三、VNI 到 MAC 的映射 — FDB（Forwarding Database）

### 3.1 FDB 核心数据结构

```c
// vxlan_private.h

struct vxlan_fdb_key {
    u8       eth_addr[ETH_ALEN];  // MAC 地址
    __be32   vni;                  // VNI
};

struct vxlan_fdb {
    struct rhash_head    rhnode;         // 哈希表节点 (key = fdb_key)
    struct rcu_head     rcu;
    unsigned long        updated;        // 上次更新时间 (jiffies)
    unsigned long        used;
    struct list_head     remotes;        // 远端目的地链表 (vxlan_rdst)
    struct vxlan_fdb_key key;            // {MAC, VNI} 元组
    u16                 state;          // NUD_* 状态 (NUD_REACHABLE 等)
    u16                 flags;          // NTF_* 标志
    struct list_head     nh_list;
    struct hlist_node    fdb_node;       // 接入 fdb_list 的节点
    struct nexthop     __rcu *nh;       // Nexthop 对象（替代 rdst 列表）
    struct vxlan_dev  __rcu *vdev;
};

struct vxlan_rdst {         // 单个远端目的地
    union vxlan_addr  remote_ip;        // 远端 IP 地址
    __be16            remote_port;      // 远端 UDP 端口
    u8                offloaded:1;
    __be32            remote_vni;       // 远端 VNI（可与本地不同）
    u32               remote_ifindex;   // 远端出口 interface
    struct net_device *remote_dev;
    struct list_head   list;            // 链接到 f->remotes
    struct rcu_head    rcu;
    struct dst_cache   dst_cache;       // 缓存 dst lookup 结果
};
```

### 3.2 FDB 哈希表

```c
// vxlan_core.c:66
static const struct rhashtable_params vxlan_fdb_rht_params = {
    .head_offset = offsetof(struct vxlan_fdb, rhnode),
    .key_offset  = offsetof(struct vxlan_fdb, key),
    .key_len     = sizeof(struct vxlan_fdb_key),  // ETH_ALEN(6) + 4 = 10 bytes
    .automatic_shrinking = true,
};
```

一个 FDB 条目 = (MAC, VNI) → 多个 `vxlan_rdst`（支持多路径负载均衡）。

### 3.3 FDB 查找过程

```c
// vxlan_core.c:379
static struct vxlan_fdb *vxlan_find_mac_rcu(struct vxlan_dev *vxlan,
                                              const u8 *mac, __be32 vni)
{
    struct vxlan_fdb_key key;
    key.eth_addr = mac;
    key.vni = vni ?: vxlan->default_dst.remote_vni;  // 无 VNI 时用默认

    return rhashtable_lookup_fast(&vxlan->fdb_hash_tbl, &key,
                                  vxlan_fdb_rht_params);
}

// vxlan_core.c:395 (发送侧，带缓存)
static struct vxlan_fdb *vxlan_find_mac_tx(struct vxlan_dev *vxlan,
                                             const u8 *mac, __be32 vni)
{
    struct vxlan_fdb *f;
    f = vxlan_find_mac_rcu(vxlan, mac, vni);
    // ... RSC 短路处理 ...
    return f;
}
```

### 3.4 FDB 学习过程（vxlan_snoop）

```c
// vxlan_core.c:1421
static enum skb_drop_reason vxlan_snoop(struct net_device *dev,
                    union vxlan_addr *src_ip, const u8 *src_mac,
                    u32 src_ifindex, __be32 vni)
{
    struct vxlan_dev *vxlan = netdev_priv(dev);
    struct vxlan_fdb *f;

    f = vxlan_find_mac_rcu(vxlan, src_mac, vni);
    if (likely(f)) {
        // 条目存在：检查 IP/ifindex 是否变化（位置迁移）
        struct vxlan_rdst *rdst = first_remote_rcu(f);
        if (vxlan_addr_equal(&rdst->remote_ip, src_ip) &&
            rdst->remote_ifindex == ifindex)
            return SKB_NOT_DROPPED_YET;  // 无变化

        // 位置变化，更新 remote_ip 并通知
        rdst->remote_ip = *src_ip;
        vxlan_fdb_notify(vxlan, f, rdst, RTM_NEWNEIGH, true, NULL);
    } else {
        // 新条目：添加学习到的 (MAC, IP, VNI)
        spin_lock(&vxlan->hash_lock);
        if (netif_running(dev))
            vxlan_fdb_update(vxlan, src_mac, src_ip,
                             NUD_REACHABLE, NLM_F_EXCL | NLM_F_CREATE,
                             vxlan->cfg.dst_port, vni,
                             vxlan->default_dst.remote_vni,
                             ifindex, NTF_SELF, 0, true, NULL);
        spin_unlock(&vxlan->hash_lock);
    }
}
```

### 3.5 FDB 生命周期管理

```
vxlan_fdb_update()   // 添加或更新条目 (vxlan_core.c:1102)
     ├─ vxlan_find_mac() → 找已有条目
     │     ├─ 找到 → vxlan_fdb_update_existing()
     │     └─ 未找到 → vxlan_fdb_update_create()
     │              → vxlan_fdb_create() → rhashtable_insert_fast()
     │
     └─ vxlan_fdb_notify() → 发送 netlink 通知 (RTM_NEWNEIGH)

vxlan_fdb_destroy()   // 删除过期条目 (vxlan_core.c:925)
     → rhashtable_remove_fast()
     → call_rcu(&f->rcu, vxlan_fdb_free)
     → __vxlan_fdb_free()  (延迟释放，RCU callback)

vxlan_cleanup()       // 定时垃圾回收 (vxlan_core.c:2834)
     → age_timer 每 FDB_AGE_INTERVAL (10s) 触发
     → 检查 fdb 条目: updated + age_interval < jiffies → 销毁
```

### 3.6 FDB 到远端路径的映射图

```
                          VNI→MAC→远端路径
                          ==================

  内部帧 (MAC=AA, VNI=100)
       │
       v
  vxlan_fdb 查找: key={MAC=AA, VNI=100}
       │
       ├─ 命中静态条目: state=NUD_PERMANENT → 使用 rdst 列表
       │                    [ remote_ip=10.0.0.5, remote_port=4789 ]
       │
       ├─ 命中学习条目: state=NUD_REACHABLE → 更新 updated 时间
       │                    [ remote_ip=10.0.0.5 ]
       │
       ├─ 命中 NTF_ROUTER 条目 → 可能是分布式路由下一跳
       │     支持 VXLAN_F_RSC (Route Shortening Circuit)
       │
       └─ Miss: vxlan_fdb_miss → 发给全零 MAC 条目 (all_zeros_mac)
               用于向外部控制器学习

  查到 rdst 后:
       └─ vxlan_xmit_one(skb, dev, vni, rdst)
            → udp_tunnel_dst_lookup()    获取路由
            → src_port = udp_flow_src_port()  [port_min, port_max] hash
            → dst_port = rdst->remote_port ?: 4789
            → vxlan_build_skb()          写入 VXLAN header
            → udp_tunnel_xmit_skb()      完成外层 UDP 发送
```

---

## 四、UDP 封装细节

### 4.1 为什么用 UDP 而不是 TCP

| 维度 | UDP | TCP |
|------|-----|-----|
| **端口复用** | 同一 IP 可服务多个 VNI，多个 VXLAN 共享 4789 | 需要多个连接 |
| **封装开销** | 8B (UDP) | 20B (TCP) + 可能是 SYN/SYN-ACK |
| **校验和** | UDP 可设为 0 (VXLAN_F_UDP_ZERO_CSUM_TX) | 必须校验 |
| **逐包负载均衡** | ECMP 哈希可基于 src/dst port | ECMP 只能基于 src/dst IP |
| **丢包重传** | 由上层处理（隧道外层 IP 层已经处理） | 隧道外层已有 TCP，内层无需再处理 |
| **MTU** | 相比 TCP 少 12B 开销 | 需要更多字节 |

### 4.2 外层 UDP 目的端口选择

```c
// vxlan_core.c:2393 (vxlan_xmit_one)
dst_port = rdst->remote_port ? rdst->remote_port : vxlan->cfg.dst_port;
// cfg.dst_port 默认为 8472，IANA 标准为 4789
```

### 4.3 src_port 散列（ECMP 负载均衡）

```c
// vxlan_core.c:2463
src_port = udp_flow_src_port(dev_net(dev), skb,
                              vxlan->cfg.port_min,
                              vxlan->cfg.port_max, true);
// port_min/port_max 默认 [0, 0] → 自动使用 IANA 端口范围或默认
// 第三个参数 true = ephemeral，随机选择
```

### 4.4 GSO (Generic Segmentation Offload) 与 VXLAN

```c
// vxlan_core.c:2188
int type = udp_sum ? SKB_GSO_UDP_TUNNEL_CSUM : SKB_GSO_UDP_TUNNEL;
// ... VXLAN_F_REMCSUM_TX 时:
type |= SKB_GSO_TUNNEL_REMCSUM;  // Remote Checksum Offload

// iptunnel_handle_offloads() 注册 GSO 类型
// 这样 skb 可以直接走 GSO，网卡完成分片
```

### 4.5 Headroom 计算

```c
// vxlan_core.c:2207
min_headroom = LL_RESERVED_SPACE(dst->dev)   // 物理网卡的 link-layer 头部空间
             + dst->header_len                // 外层路由的 header_len
             + VXLAN_HLEN                     // 16B: UDP(8) + VXLAN(8)
             + iphdr_len;                     // 20B IPv4 或 40B IPv6

err = skb_cow_head(skb, min_headroom);       // 确保 headroom 足够
```

---

## 五、VXLAN 与 Bridge 的交互

### 5.1 VXLAN 作为 Bridge 端口

VXLAN 设备 (`vxlan0`) 可以作为 Bridge 的成员端口，方式有两种：

**方式 1：通过 `brport` 方式（传统）**

```
eth0 (物理)
   |
bridge0 (br0)
   |
   +-- vxlan0 (VXLAN device, VNI=100)
   +-- veth0  (连接容器)
```

**方式 2：通过 FDB 分布式学习（Overlay）**

```
VM1 (vxlan0, VNI=100) ←VXLAN隧道→ VM2 (vxlan0, VNI=100)
      |                           |
      +-- 各自的 FDB 表 --+
           (MAC+VNI → IP)
```

当 `vxlan0` 作为 `bridge0` 成员时，bridge 的数据面转发流程：
1. `br_input()` 收到包 → 检查 MAC → 查 bridge fdb
2. 如果目标是同一 VNI 的远端 MAC，通过 `vxlan_fdb` 查远端隧道地址
3. 调用 `vxlan_xmit()` 将帧封装进 UDP 发往远端 VTEP

### 5.2 VXLAN FDB 学习与 Bridge 的 ARP/ND 代理

```c
// vxlan_core.c:1802 (vxlan_rcv → vxlan_set_mac → vxlan_snoop)
// VXLAN 学习到新的 (MAC, IP, VNI) 后:
// → vxlan_fdb_update() 添加 FDB 条目
// → vxlan_fdb_notify() 发送 netlink (RTM_NEWNEIGH)
// → switchdev 通知 bridge 更新 fdb

// 在 bridge 端:
static int br_switchdev_event(...)
{
    // 处理 vxlan_fdb 的 switchdev 事件
    // 同步到 bridge 的 fdb
}
```

### 5.3 VXLAN 代理 ARP/ND (VXLAN_F_PROXY)

```c
// vxlan_core.c:1776
if (vxlan->cfg.flags & VXLAN_F_PROXY) {
    eth = eth_hdr(skb);
    if (ntohs(eth->h_proto) == ETH_P_ARP)
        return arp_reduce(dev, skb, vni);    // 处理 ARP 请求
#if IS_ENABLED(CONFIG_IPV6)
    else if (... == ETH_P_IPV6 && ...)
        return neigh_reduce(dev, skb, vni);  // 处理 ND solicitation
#endif
}

// arp_reduce() — vxlan_core.c:1835
// 对于 ARP 请求，在 VNI 域内查找 ARP 表（neigh 表）
// 如果目标 IP 命中本地隧道邻居，构造 ARP reply
// 否则发送给全零 MAC 的远端（控制器学习）
```

### 5.4 VXLAN MDB (Multicast Database)

```c
// vxlan_mdb.c — VXLAN 自己的多播组管理
struct vxlan_mdb_entry {
    union vxlan_addr src;
    union vxlan_addr dst;  // 组播地址
};

struct vxlan_mdb_entry_key { src, dst };

// vxlan_mdb_entry_skb_get() — 从包的组播 MAC 查 MDB
// vxlan_mdb_xmit() — 通过多播组隧道发送
```

### 5.5 VXLAN 与 bridge VLAN 过滤的交互

```
bridge br0
  ├── eth0 (access port, PVID=100)
  ├── vxlan0 (VXLAN, VNI=100)
  │
  └── Bridge VLAN filtering: enabled

当 br_vlan 过滤开启时，bridge 的数据流：
  eth0 收帧 → 打 VLAN tag (100) → bridge 处理
           → 查 br_fdb → 发现目标 MAC
             在同一 VLAN 内但属于 vxlan0
           → vxlan_xmit() 封装 VXLAN，VNI=100
             通过隧道发往远端 VTEP
```

---

## 六、内核参数与配置接口

### 6.1 UDP 端口注册

```c
// vxlan_core.c:3603
static struct socket *vxlan_socket_create(struct net *net, bool ipv6,
                                           __be16 port, u32 flags, int l3mdev_index)
{
    // 创建 UDP socket，绑定 port
    sock = udp_tunnel6_socket_create(net, ...);  // IPv6
    // 或
    sock = udp_tunnel_socket_create(net, ...);   // IPv4

    // 注册 UDP 端口
    udp_tunnel_notify_add_rx_port(sock,
        (vs->flags & VXLAN_F_GPE) ?
            UDP_TUNNEL_TYPE_VXLAN_GPE :
            UDP_TUNNEL_TYPE_VXLAN);
    // → 让内核知道这个 socket 接收 VXLAN 流量

    // 设置 encap_rcv 回调
    tunnel_cfg.encap_rcv = vxlan_rcv;  // 数据包入口
    tunnel_cfg.encap_err_lookup = vxlan_err_lookup;  // ICMP 错误处理
    setup_udp_tunnel_sock(net, sock, &tunnel_cfg);
}
```

### 6.2 `vxlan_group` 和 `vxlan_port` 的 iproute2 配置

```bash
# 创建 vxlan0，VNI=100，组播组 239.0.0.100，远端 10.0.0.5
ip link add vxlan0 type vxlan \
    id 100 \
    group 239.0.0.100 \
    dstport 4789 \
    dev eth0

# 或指定远端单播
ip link add vxlan0 type vxlan \
    id 100 \
    remote 10.0.0.5 \
    dstport 4789 \
    dev eth0

# 查看端口
cat /proc/net/udp
cat /proc/net/udp6
```

### 6.3 内核参数对应关系

| 用户空间配置 | 内核变量 | 代码位置 |
|------------|---------|---------|
| `dstport` | `vxlan->cfg.dst_port` | `vxlan_core.c:3868` |
| `group` (多播) | `vxlan->default_dst.remote_ip` (多播地址) | |
| `remote` (单播) | `vxlan->default_dst.remote_ip` | |
| `id` (VNI) | `vxlan->cfg.vni` / `default_dst.remote_vni` | `vxlan_core.c:3856` |
| `vxlan_port` (模块参数) | `vxlan_port` (默认 8472) | `vxlan_core.c:49` |
| `age_interval` | `vxlan->cfg.age_interval` | 定时清理 FDB |
| `learn` (FDB 学习) | `VXLAN_F_LEARN` (0x01) | `vxlan_core.c:1430` |

### 6.4 VNI 到设备的映射 — `vs_head` 和 `vni_head`

```c
// vxlan_private.h

// 按 UDP 端口哈希的 socket 列表（每个 netns）
static inline struct hlist_head *vs_head(struct net *net, __be16 port)
{
    struct vxlan_net *vn = net_generic(net, vxlan_net_id);
    return &vn->sock_list[hash_32(ntohs(port), PORT_HASH_BITS)];
    // PORT_HASH_BITS = 8, PORT_HASH_SIZE = 256
}

// 按 VNI 哈希的 vxlan_dev 列表（每个 vxlan_sock）
static inline struct hlist_head *vni_head(struct vxlan_sock *vs, __be32 vni)
{
    return &vs->vni_list[hash_32((__force u32)vni, VNI_HASH_BITS)];
    // VNI_HASH_BITS = 10, VNI_HASH_SIZE = 1024
}
```

**端口查找流程**：

```
收到 UDP 包 (dst_port=4789)
  → __udp4_lib_rcv() / __udp6_lib_rcv()
  → 查 sock_list[hash(4789)]
  → 找到 vs (vxlan_sock)
  → 查 vs->vni_list[hash(vni)]
  → 找到 vxlan_dev (或 vxlan_vni_node if VNIFILTER)
  → 调用 encap_rcv = vxlan_rcv
```

---

## 七、VXLAN 数据平面完整 ASCII 图

```
                    VXLAN 发送 (TX) 完整路径
                    ====================

  原始 Ethernet 帧
  [DMAC][SMAC][EtherType=0x0800][IP][TCP][Data]
       |
       v
  bridge 或 路由子系统
       |
       | 查找 skb_tunnel_info (metadata path)
       | 或查找 bridge fdb → vxlan_fdb
       v
  +----------------+
  | vxlan_xmit()  |  ← ndo_start_xmit 入口
  +----------------+
       |
       | 查 FDB: vxlan_find_mac_tx(dst_mac, vni)
       |   → 命中 NTF_ROUTER + VXLAN_F_RSC → route_shortcircuit
       |   → 命中普通条目 → rdst (远端 IP+port)
       |   → 全零 mac (flood) → 所有 rdst
       |
       v
  +---------------------+
  | vxlan_xmit_one()    |  核心封装逻辑
  +---------------------+
       |
       ├─ encap_bypass_if_local() → 本地 vxlan 设备直接回环
       │
       ├─ UDP tunnel 路由查找:
       │   udp_tunnel_dst_lookup(skb, dev, net, ifindex,
       │                          &saddr, pkey, src_port, dst_port, ...)
       │
       ├─ PMTU 检查
       │
       ├─ 构建 VXLAN 头:
       │   vxlan_build_skb():
       │     skb_cow_head() 确保 headroom
       │     iptunnel_handle_offloads() 处理 GSO
       │     vxh = __skb_push(skb, 8)  // VXLAN 头 8 字节
       │     vxh->vx_flags = VXLAN_HF_VNI
       │     vxh->vx_vni   = vxlan_vni_field(vni)
       │
       └─ 发送:
           udp_tunnel_xmit_skb(rt, sock->sk, skb,
                               saddr, dst_ip, tos, ttl, df,
                               src_port, dst_port, ...)
           ↓
  Outer Header 结构:
  +-------------------------------+
  | Outer Ethernet Header (MAC)   |  ← 从路由 dst 得出
  +-------------------------------+
  | Outer IP Header (20B IPv4)    |  ← saddr → dst_ip
  +-------------------------------+
  | Outer UDP Header (8B)         |  ← src_port(hash), dst_port(4789)
  +-------------------------------+
  | VXLAN Header (8B)            |  ← flags=0x08000000(VNI), vni
  +-------------------------------+
  | Inner Ethernet Frame         |  ← 原始 L2 帧，SMAC/DMAC/IP
  +-------------------------------+
       |
       v
  物理网卡发送 (GSO 分段或硬件卸载)


                    VXLAN 接收 (RX) 完整路径
                    ====================

  物理网卡 (DMA)
       |
       v
  UDP 收包处理:
  __udp4_lib_rcv() / __udp6_lib_rcv()
       |
       | 查 /proc/net/udp[6] 的 port 哈希表
       | → 找到 vs (vxlan_sock)
       |
       v
  tunnel_cfg.encap_rcv(vs, skb) = vxlan_rcv()
  +-------------------------+
  | vxlan_rcv()             |  ← vxlan_core.c:1643
  +-------------------------+
       |
       ├─ pskb_may_pull(skb, VXLAN_HLEN=16)  确保头在
       ├─ vh = vxlan_hdr(skb)  读取 VXLAN 头
       ├─ 检查 VXLAN_HF_VNI 标志 (bit 27)
       ├─ vni = vxlan_vni(vh->vx_vni)  提取 VNI
       │
       ├─ vxlan_vs_find_vni(vs, ifindex, vni)
       │    → vs->vni_list[hash(vni)]  找到 vxlan_dev
       │
       ├─ __iptunnel_pull_header()  剥掉外层 UDP+VXLAN 头
       │    → skb->protocol = ETH_P_TEB (透明以太网)
       │
       ├─ VXLAN_F_COLLECT_METADATA: 建立 metadata_dst
       │    → udp_tun_rx_dst() 填充 tunnel_info
       │
       ├─ vxlan_set_mac():
       │    → 检查 LEARN 标志
       │    → vxlan_snoop(skb->dev, saddr, src_mac, ifindex, vni)
       │         → vxlan_fdb_update() 学习 (MAC, IP, VNI) 到 FDB
       │
       └─ gro_cells_receive() 传递给 GRO 处理或直接入栈
            → netif_rx(skb)  到 vxlan netdev
                 |
                 v
  VXLAN 设备 netdev 上收到剥掉外层的原始 Ethernet 帧
  [DMAC][SMAC][EtherType][Payload]
       |
       v
  bridge 或 上层协议栈处理
  (若 vxlan0 是 bridge 成员，bridge 处理转发)
```

---

## 八、VXLAN 与 VLAN 的关键对比

| 维度 | VLAN (802.1Q) | VXLAN |
|------|--------------|-------|
| **封装方式** | 在原帧后插入 4 字节 VLAN tag | 整个 L2 帧封装进 UDP/IP |
| **隔离域** | 4096 个 (VID) | 16M 个 (VNI) |
| **L2 跨越范围** | 受限于物理网络 (STP) | 跨越 L3 网络（IP 路由可达即可） |
| **头部开销** | +4 字节 | +50 字节 (Outer IP+UDP+VXLAN) |
| **隧道端点** | 二层交换机 | VTEP (可以是软件 or 硬件) |
| **MAC 学习** | 本地交换芯片 / bridge fdb | FDB (VXLAN 自己的分布式表) |
| **组播支持** | 通过 VLAN 内 STP | 通过 VXLAN 组播或控制器 |
| **硬件卸载** | NIC 识别 VLAN tag | NIC 识别 UDP 隧道 (TUNNEL_OFFLOAD) |
| **配置方式** | `ip link add link eth0 type vlan id 100` | `ip link add vxlan0 type vxlan id 100` |

---

## 九、关键源码文件清单

| 文件 | 作用 | 行数 |
|------|------|------|
| `net/8021q/vlan_dev.c` | VLAN netdev 发送/接收，ndo_start_xmit | 1087 |
| `net/8021q/vlan_core.c` | VLAN tag 操作，vlan 协议处理 | 560 |
| `include/linux/if_vlan.h` | VLAN tag 插入/提取 inline 函数 | ~600 |
| `drivers/net/vxlan/vxlan_core.c` | VXLAN 主实现：xmit/rcv/FDB/封装 | 5023 |
| `drivers/net/vxlan/vxlan_private.h` | VXLAN 私有数据结构：fdb_key, vxlan_fdb, vxlan_rdst | ~200 |
| `drivers/net/vxlan/vxlan_mdb.c` | VXLAN 多播数据库 | ~400 |
| `include/net/vxlan.h` | VXLAN 协议头定义，VNI 宏，配置结构 | 607 |

---

## 十、总结

**VLAN** 的本质是**标签交换**：在 L2 帧中插入 4 字节 tag，通过 `vlan_tci` 字段实现软硬件协同，不需要改变帧的内容就能让交换芯片识别虚拟网络。其核心路径是 `vlan_dev_hard_start_xmit` → `__vlan_hwaccel_put_tag` → `dev_queue_xmit`。

**VXLAN** 的本质是**UDP 隧道**：将完整 L2 帧作为 UDP payload 封装，通过 VNI（24bit）扩展了网络标识空间，通过 FDB 实现分布式 MAC 地址学习。关键创新在于：
1. **FDB 哈希表**：`{MAC, VNI}` → `rcu protected {remote_ip, port}`，支持多路径
2. **VNI 映射**：`vs_head` (按 UDP port) → `vni_head` (按 VNI) → `vxlan_dev`，两层哈希查找
3. **分布式学习**：`vxlan_snoop` 在收包时自动学习 `(MAC, IP, VNI)` → FDB 条目，支持位置迁移通知
4. **本地绕过**：`encap_bypass_if_local` 在目的为本地时跳过外层封装直接递送
5. **UDP 封装选择**：用 UDP 而非 TCP 的核心原因是**ECMP 散列**（基于 src/dst port）和**更小开销**（8B vs 20B+）