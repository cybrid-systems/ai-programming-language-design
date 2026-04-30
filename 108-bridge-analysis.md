# Linux Kernel Bridge (网桥) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/bridge/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 网桥概述

**bridge** 是 Linux 的二层交换机实现，将多个网络接口（ eth0、veth0、tap0）加入同一个广播域，所有接口收到广播帧，仅目标 MAC 的帧从对应接口发出。

---

## 1. 核心结构

```c
// net/bridge/br_private.h — net_bridge
struct net_bridge {
    struct list_head           port_list;      // 所有网桥端口
    struct net_device          *dev;            // 网桥自身设备
    struct br_fdb_entry        *hash[BR_HASH_SIZE];  // MAC 地址表
    spinlock_t                 hash_lock;
    struct timer_list           forward_delay_timer;
    struct timer_list           hello_timer;
    struct timer_list           age_timer;
    struct bridge_mst_state    *mst;           // MSTP（多生成树）
};

// net/bridge/br_private.h — net_bridge_port
struct net_bridge_port {
    struct net_bridge           *br;            // 所属网桥
    struct net_device           *dev;           // 底层设备
    unsigned long               flags;          // BR_STATE_* 状态
    int                         path_cost;      // 路径成本
    u8                          designated_root; // 生成树根桥
    struct fdb_entry            *fdb_entries;   // 端口 MAC 表
    struct rcu_head             rcu;
};
```

---

## 2. MAC 学习流程

```
收到帧 → 检查 src MAC →
  if 不在 hash[MAC]: 
      添加 (MAC, port) 到 hash
  else:
      更新 age_timer（超时删除）

转发决策：
  if dst MAC 是广播/多播:
      洪泛所有端口（除接收端口）
  elif dst MAC 在 hash:
      只从对应端口发出
  else:
      洪泛所有端口（未知单播）
```

---

## 3. STP (生成树协议)

```c
// 网桥ID = (priority << 48) | MAC
// 选举根桥：ID 最小的成为根桥
// 每个非根桥选举一个根端口（到根桥cost最小）
// 每个段选举一个指定端口（发送最佳 BPDU）
// 阻塞非指定端口
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `net/bridge/br_forward.c` | 转发逻辑 |
| `net/bridge/br_stp.c` | STP 生成树 |
| `net/bridge/br_fdb.c` | MAC 地址学习 |
| `net/bridge/br_private.h` | `struct net_bridge`、`struct net_bridge_port` |
