# Linux Kernel Neighbour 子系统 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/core/neighbour.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 Neighbour？

**Neighbour 子系统**管理**IP 地址到 MAC 地址**的映射（ARP 表），对应 IPv4 的 ARP 和 IPv6 的 NDP。

---

## 1. 核心数据结构

```c
// include/net/neighbour.h — neighbour
struct neighbour {
    struct neighbour       **next;              // 哈希表冲突链
    struct net_device     *dev;               // 网络设备
    unsigned char        *ha;                // 硬件地址（MAC）
    union {
        __be32          *dst_ip;
        struct in6_addr  *dst_ip6;
    };
    struct hh_cache      *hh;               // 硬件头缓存
    struct neigh_ops     *ops;              // 操作函数表
    unsigned long        nud_state;         // 状态（NUD_xxx）
    atomic_t            refcnt;              // 引用计数
    __u8                key_len;             // key 长度
    void                *primary_key;        // IP 地址
    struct list_head    gc_list;            // GC 链表
};
```

---

## 2. NUD 状态

```
NUD_NONE          — 未知
NUD_INCOMPLETE    — 查询中（正在 ARP/NDP）
NUD_REACHABLE     — 已知可达（最近确认）
NUD_STALE         — 已知但可能过期（需验证）
NUD_DELAY         — STALE 超时，正在验证
NUD_PROBE         — 探测中（重发 ARP/NDP）
NUD_FAILED        — 查询失败
NUD_NOARP         — 无 ARP（无需解析，如 loopback）
NUD_PERMANENT     — 永久条目（如本地路由）
```

---

## 3. ARP 解析流程

```c
// net/core/neighbour.c — neigh_resolve_output
int neigh_resolve_output(struct neighbour *neigh, struct sk_buff *skb)
{
    // 1. 如果状态不可达，触发解析
    if (neigh->nud_state == NUD_STALE) {
        neigh_update(neigh, NULL, NUD_DELAY, ...);
        goto out;
    }

    // 2. 填充以太网头
    neigh->ops->hh_output(skb);

out:
    // 3. 发送 ARP 请求（如果 INCOMPLETE）
    if (neigh->nud_state == NUD_INCOMPLETE)
        neigh_timer_handler();
}
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `net/core/neighbour.c` | 核心实现 |
| `include/net/neighbour.h` | `struct neighbour`、`NUD_*` |
