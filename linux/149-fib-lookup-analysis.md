# 149-fib_lookup — 路由查找深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/fib_trie.c` + `include/net/ip_fib.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**fib_lookup**（Forwarding Information Base）是 Linux IP 路由的核心，查找数据包应该从哪个接口发送、发送到哪个下一跳。

---

## 1. 核心数据结构

### 1.1 struct fib_table — 路由表

```c
// include/net/ip_fib.h — fib_table
struct fib_table {
    struct hlist_node     tb5_hlist;    // 接入全局路由表链表
    u32               tb_id;           // 路由表 ID（如 254 = main）
    unsigned char       tb_data[0];       // trie 数据
};
```

### 1.2 struct fib_result — 查找结果

```c
// include/net/ip_fib.h — fib_result
struct fib_result {
    __u8              prefixlen;        // 前缀长度
    __u8              nh_sel;           // 下一跳选择
    __u8              type;              // 类型（LOCAL/UNREACHABLE/BROADCAST等）
    struct fib_nh       *nh;
    struct fib_info      *fi;            // 路由信息
};
```

### 1.3 struct fib_nh — 下一跳

```c
// include/net/ip_fib.h — fib_nh
struct fib_nh {
    struct net_device       *nh_dev;     // 出口设备
    struct fib_nh_exception *nh_exceptions; // 黑洞路由
    int                  nh_parent;     // 父索引

    // 网关
    __be32              nh_gw;          // 下一跳 IP
    __be32              nh_scope;       // 作用范围

    // OIF
    int                  nh_oif;         // 输出接口
};
```

---

## 2. fib_lookup — 路由查找

### 2.1 fib_lookup

```c
// net/ipv4/fib_lookup.c — fib_lookup
int fib_lookup(struct net *net, const struct flowi4 *flp,
               struct fib_result *res, unsigned int flags)
{
    struct fib_table *table;
    int err;

    // 1. 获取路由表（如 main=254, local=255）
    table = fib_get_table(net, flp->flowi4_table_id ?: RT_TABLE_MAIN);
    if (!table)
        return -ENETUNREACH;

    // 2. 调用 trie 查找
    err = fib_table_lookup(table, &flp->flowi4_dst, flp->flowi4_src,
                          res, flags | FIB_LOOKUP_NOREF);

    return err;
}
```

---

## 3. fib_table_lookup — Trie 查找

### 3.1 fib_table_lookup

```c
// net/ipv4/fib_trie.c — fib_table_lookup
int fib_table_lookup(struct fib_table *tb, const struct in_device *idev,
                    const __be32 *key, struct fib_result *res,
                    int flags)
{
    struct trie *t = (struct trie *)tb->tb_data;
    struct key_vector *n, *pn;

    n = rcu_dereference(t->trie);
    pn = NULL;

    // 1. 二叉Trie 查找（最长前缀匹配）
    // 每个 bit 对应一个分支
    // 找到最长匹配的前缀

    while (n) {
        if (fn_key_match(n->key, key, t->datahoff))
            break;

        pn = n;
        n = tnode_get_child(t, n, key_bit(t, key));
    }

    // 2. 回溯找到最长匹配
    if (n)
        fib_result_assign(res, n);
    else if (pn)
        fib_result_assign(res, pn);
    else
        return -ENETUNREACH;

    return 0;
}
```

---

## 4. 路由表类型

```bash
# 查看路由表：
ip route show table all

# 默认表：
#   255 = local（本地路由，自动生成）
#   254 = main（默认主表）
#   253 = default（默认路由）

# 路由表内容示例：
# default via 192.168.1.1 dev eth0
# 192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.100
# 10.0.0.0/8 via 192.168.1.254 dev eth0
```

---

## 5. 黑洞路由（blackhole）

```c
// 黑洞路由：丢弃匹配的数据包
# ip route add blackhole 10.0.0.0/24
// 数据包匹配 10.0.0.0/24 时直接丢弃
// 不发送 ICMP 不可达
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/fib_lookup.c` | `fib_lookup`、`fib_table_lookup` |
| `include/net/ip_fib.h` | `struct fib_table`、`struct fib_result`、`struct fib_nh` |
| `net/ipv4/fib_trie.c` | trie 实现 |

---

## 7. 西游记类比

**fib_lookup** 就像"取经路的问路处"——

> 悟空要从 A 地去 B 地，不知道路，问土地神（fib_lookup）。土地神先查地图（路由表 main），看有没有直接到 B 地的路。如果没有，就找有没有到某个大区域（如 B 所在的城市）的路。如果还是没有，就找有没有到任何地方的路（默认路由）。这就是最长前缀匹配——找最精确的路径。如果找不到任何路径，就回报"这条路不通"（ENETUNREACH）。土地神手上的地图是压缩过的（trie 前缀树），可以快速查找，不用逐行扫描。

---

## 8. 关联文章

- **ip_route_output**（相关）：输出路由
- **neighbour**（article 157）：路由后的 ARP 解析