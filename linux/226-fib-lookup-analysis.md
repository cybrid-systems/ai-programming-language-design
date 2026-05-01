# fib_lookup — Linux 内核路由查找分析

> 基于 Linux 7.0-rc1 (commit `fib_lookup` 分支相关文件)
> 内核源码：`/home/dev/code/linux`

---

## 1. fib_lookup 入口

### 1.1 单表模式 vs 多表模式

Linux IPv4 路由查找入口是 `fib_lookup()`，但它有两套实现，取决于内核编译选项 `CONFIG_IP_MULTIPLE_TABLES`：

**单表模式**（默认，`CONFIG_IP_MULTIPLE_TABLES=n`），见 `ip_fib.h:326`：

```c
// include/net/ip_fib.h:320-327
static inline int fib_lookup(struct net *net, const struct flowi4 *flp,
                             struct fib_result *res, unsigned int flags)
{
    struct fib_table *tb;
    int err = -ENETUNREACH;

    rcu_read_lock();

    tb = fib_get_table(net, RT_TABLE_MAIN);
    if (tb)
        err = fib_table_lookup(tb, flp, res, flags | FIB_LOOKUP_NOREF);

    if (err == -EAGAIN)
        err = -ENETUNREACH;

    rcu_read_unlock();

    return err;
}
```

直接查 `RT_TABLE_MAIN`，不做规则匹配，开销最小。

**多表模式**（`CONFIG_IP_MULTIPLE_TABLES=y`），同上文件 `ip_fib.h:380`：

```c
static inline int fib_lookup(struct net *net, struct flowi4 *flp,
                             struct fib_result *res, unsigned int flags)
{
    // ...
    if (net->ipv4.fib_has_custom_rules)
        return __fib_lookup(net, flp, res, flags);

    // 否则 fallback 到 main + default 两张表
}
```

`fib_has_custom_rules` 检查是否配置了自定义路由策略规则。

### 1.2 规则分发：__fib_lookup

当有自定义规则时，`__fib_lookup`（`fib_rules.c:84`）通过 `fib_rules_lookup()` 遍历规则链：

```c
// net/ipv4/fib_rules.c:84-109
int __fib_lookup(struct net *net, struct flowi4 *flp,
                 struct fib_result *res, unsigned int flags)
{
    struct fib_lookup_arg arg = {
        .result = res,
        .flags = flags,
    };

    l3mdev_update_flow(net, flowi4_to_flowi(flp));

    err = fib_rules_lookup(net->ipv4.rules_ops, flowi4_to_flowi(flp), 0, &arg);
    // ...
}
```

`fib4_rule_action`（`fib_rules.c:113`）根据规则的 `FR_ACT_TO_TBL` 动作获取对应 `fib_table`，然后调用 `fib_table_lookup()`。

### 1.3 flp 参数：flowi4

`flowi4` 是查找的关键字，定义在 `include/net/flow.h`：

```c
struct flowi4 {
    __be32  daddr;           // 目标地址 ← 核心查找键
    __be32  saddr;           // 源地址
    __be32  fl4_dst;
    __be32  fl4_src;
    __u32   flowi4_iif;     // 入接口
    __u32   flowi4_oif;      // 出接口（ECMP 时用）
    __u32   flowi4_mark;
    dscp_t  flowi4_dscp;
    __u8    flowi4_scope;
    __u8    flowi4_proto;
    // multipath hash 相关
    __u32   flowi4_multipath_hash;
    // ...
};
```

---

## 2. fib_table_lookup 详解

核心查找函数在 `fib_trie.c:1467`，声明在 `ip_fib.h:310`：

```c
// net/ipv4/fib_trie.c:1467
int fib_table_lookup(struct fib_table *tb, const struct flowi4 *flp,
                     struct fib_result *res, int fib_flags)
```

### 2.1 Step 1：Trie 向下遍历

```c
// fib_trie.c:1481-1511
const t_key key = ntohl(flp->daddr);   // 将 IP 转成整数
struct key_vector *n, *pn;
unsigned long index;

pn = t->kv;
n = get_child_rcu(pn, 0);

// 沿 trie 向下走到最长前缀匹配节点
for (;;) {
    index = get_cindex(key, n);

    if (index >= (1ul << n->bits))   // 位不匹配，跳出
        break;

    if (IS_LEAF(n))                  // 命中叶子
        goto found;

    if (n->slen > n->pos) {          // 记录回溯位置
        pn = n;
        cindex = index;
    }

    n = get_child_rcu(n, index);
    if (unlikely(!n))
        goto backtrack;
}
```

### 2.2 Step 2：回溯找最长前缀匹配

```c
// fib_trie.c:1513-1560 (简化)
for (;;) {
    if (unlikely(prefix_mismatch(key, n)) || (n->slen == n->pos))
        goto backtrack;      // 不匹配就向上回溯

    if (unlikely(IS_LEAF(n)))
        break;               // 找到叶子

    // 从当前节点继续向下遍历
    while ((n = rcu_dereference(*cptr)) == NULL) {
backtrack:
        while (!cindex) {
            pn = node_parent_rcu(pn);
            cindex = get_index(pkey, pn);
        }
        cindex &= cindex - 1;   // 剥离最低位
        cptr = &pn->tnode[cindex];
    }
}
```

`prefix_mismatch`（`fib_trie.c:1235`）通过 XOR 和前缀掩码检测位冲突：
```c
static inline t_key prefix_mismatch(t_key key, struct key_vector *n)
{
    t_key prefix = n->key;
    return (key ^ prefix) & (prefix | -prefix);
}
```

### 2.3 Step 3：叶子节点匹配

```c
// fib_trie.c:1562-1604
found:
    index = key ^ n->key;

    hlist_for_each_entry_rcu(fa, &n->leaf, fa_list) {
        struct fib_info *fi = fa->fa_info;

        if (index >= (1ul << fa->fa_slen))
            continue;                       // 长度不匹配
        if (fa->fa_dscp && !fib_dscp_masked_match(fa->fa_dscp, flp))
            continue;                       // DSCP 不匹配
        if (READ_ONCE(fi->fib_dead))
            continue;                       // 已被删除的路由
        if (fa->fa_info->fib_scope < flp->flowi4_scope)
            continue;                       // scope 太具体

        // 命中！填充结果
        res->prefix      = htonl(n->key);
        res->prefixlen   = KEYLENGTH - fa->fa_slen;
        res->nh_sel      = nhsel;
        res->nhc         = nhc;
        res->type        = fa->fa_type;
        res->scope       = fi->fib_scope;
        res->fi          = fi;
        res->table       = tb;
        return 0;
    }
```

---

## 3. Trie 结构（LC-trie）

### 3.1 整体架构

Linux 使用 **LC-trie**（Level-Compressed Trie），论文来自：
> "IP-address lookup using LC-tries", S. Nilsson & G. Karlsson, IEEE JSAC, 1999

它是压缩后的二叉 trie，核心特性：
- **路径压缩**（Path Compression）：跳过只有一条路径的中间节点
- **节点分裂**（Inflate/Halve）：根据子节点密度动态调整分支因子

### 3.2 节点结构

```c
// net/ipv4/fib_trie.c:116-129
struct key_vector {
    t_key      key;       // 节点前缀（有效位由 pos+bits 确定）
    unsigned char pos;    // 下一个可用比特位置（从高位算）
    unsigned char bits;   // 子节点索引用多少比特（即 2^bits 个子节点）
    unsigned char slen;   // 该节点子树中所有前缀的最大长度
    union {
        struct hlist_head leaf;      // pos|bits==0 时：叶子
        struct key_vector __rcu *tnode[];  // 否则：内部节点数组
    };
};
```

- **Trie Root**：`pos == KEYLENGTH (32)`，`IS_TRIE(n) = (n->pos >= KEYLENGTH)`
- **内部节点**：bits > 0，`tnode[0..(1<<bits)-1]` 指向子节点
- **叶子节点**：`bits == 0`，`leaf.hlist` 挂着所有 `fib_alias`

```c
// fib_trie.c:131-137
struct tnode {
    struct rcu_head rcu;
    t_key empty_children;
    t_key full_children;
    struct key_vector __rcu *parent;
    struct key_vector kv[1];   // 嵌入 key_vector，可变长
};
```

### 3.3 Trie 结构图示

```
                         [Trie Root]
                         pos=32,bits=5
                        tnode[0..31]
                           |
                 10.0.0.0/8 ——→ [TNODE]
                              pos=8, bits=3
                             tnode[0..7]
                    /           |         \
             10.1.0.0/16   10.2.0.0/16  10.3.0.0/16
              (LEAF)        (LEAF)       (TNODE)
                                     pos=16, bits=2
                                      tnode[0..3]
                                     /         \
                             10.3.1.0/24    10.3.2.0/24
                               (LEAF)        (LEAF)

Leaf (key=0x0A010000, slen=16):
  hlist: fib_alias{fa_slen=16, fi=..., type=RTN_UNICAST}
```

### 3.4 动态调整：inflate / halve / collapse

```c
// fib_trie.c:607-645
// inflate: 分裂满节点，扩展 2^bits → 2^(bits+1)
static struct key_vector *inflate(struct trie *t, struct key_vector *oldtnode)

// fib_trie.c:654-693
// halve: 合并稀疏节点，2^bits → 2^(bits-1)
static struct key_vector *halve(struct trie *t, struct key_vector *oldtnode)

// fib_trie.c:696-708
// collapse: 单子节点上浮（去路径压缩）
static struct key_vector *collapse(struct trie *t, struct key_vector *oldtnode)
```

阈值（`fib_trie.c:598-606`）：
```c
static const int halve_threshold      = 25;   // 空节点 >25% 则合并
static const int inflate_threshold    = 50;   // 非空节点 >50% 则分裂
static const int halve_threshold_root = 15;   // 根节点更保守
static const int inflate_threshold_root= 30;
```

---

## 4. 最长前缀匹配（Longest Prefix Match, LPM）

### 4.1 算法核心

LPM 在 trie 中的实现分三步：

```
查找 IP: 10.3.2.5 (二进制: 00001010 00000011 00000010 00000101)

Step 1: 从根向下，跳过已知相同的比特位
        按 cindex (key ^ node->key) >> node->pos 选子节点
        若 index >= 1<<bits，说明跳过位不一致 → 停止

Step 2: 若在内部节点停下，回溯：
        记录 pn（上一个"有意义"的父节点）和 cindex
        逐层向上，尝试同级其他分支

Step 3: 在叶子节点，逐一检查 fib_alias：
        index = key ^ leaf.key
        验证 index < 1<<fa_slen（即 IP 在该前缀范围内）
```

### 4.2 前缀比较的关键

每个 `fib_alias` 的长度不是直接存的，而是用 `fa_slen`（`slen = KEYLENGTH - prefixlen`）：

```c
// ip_fib.h:290
struct fib_alias {
    struct hlist_node fa_list;
    struct fib_info *fa_info;
    dscp_t    fa_dscp;
    u8        fa_type;
    u8        fa_state;
    u8        fa_slen;     // = 32 - prefixlen，挂载时计算
    // ...
};
```

```c
// fib_trie.c:1566
if (index >= (1ul << fa->fa_slen))
    continue;   // 掩码外（比前缀更长的 IP），继续找更短的

res->prefixlen = KEYLENGTH - fa->fa_slen;
```

---

## 5. fib_result 结构

### 5.1 完整定义

```c
// include/net/ip_fib.h:260-274
struct fib_result {
    __be32          prefix;       // 匹配的前缀（网络字节序）
    unsigned char   prefixlen;     // 前缀长度
    unsigned char   nh_sel;        // 选中的 nexthop 下标
    unsigned char   type;          // 路由类型：RTN_UNICAST/LOCAL/BROADCAST/...
    unsigned char   scope;         // 路由 scope：RT_SCOPE_UNIVERSE/LINK/HOST
    u32             tclassid;      // 流量类别（用于 policy routing）
    dscp_t          dscp;          // DSCP 值
    struct fib_nh_common *nhc;      // ← nexthop 信息核心指针
    struct fib_info *fi;           // 指向完整的 fib_info
    struct fib_table *table;        // 来自哪张 fib_table
    struct hlist_head *fa_head;    // 叶子节点的 alias 链表
};
```

### 5.2 fib_info 和 fib_nh_common

```c
// include/net/ip_fib.h:187-207
struct fib_info {
    struct hlist_node  fib_hash;
    struct hlist_node  fib_lhash;
    struct list_head   nh_list;
    struct net        *fib_net;
    refcount_t        fib_treeref;
    refcount_t        fib_clntref;
    unsigned char      fib_dead;
    unsigned char      fib_protocol;   // 路由协议
    unsigned char      fib_scope;     // 路由 scope
    unsigned char      fib_type;
    __be32             fib_prefsrc;   // 优先使用的源地址
    u32                fib_tb_id;     // 所属 table ID
    u32                fib_priority;  // 路由优先级（metric）
    int                fib_nhs;       // nexthop 数量
    bool               fib_nh_is_v6;
    struct nexthop    *nh;            // nexthop 对象（单独管理）
    struct fib_nh      fib_nh[];      // 内联 nexthop 数组
};
```

```c
// include/net/ip_fib.h:165-186
struct fib_nh_common {
    struct net_device *nhc_dev;
    int               nhc_oif;
    unsigned char     nhc_scope;
    u8                nhc_family;
    u8                nhc_gw_family;
    unsigned char     nhc_flags;
    struct lwtunnel_state *nhc_lwtstate;
    union {
        __be32        ipv4;
        struct in6_addr ipv6;
    } nhc_gw;
    int               nhc_weight;
    atomic_t          nhc_upper_bound;
    struct rtable __rcu * __percpu *nhc_pcpu_rth_output;
    struct rtable __rcu *nhc_rth_input;
    struct fnhe_hash_bucket __rcu *nhc_exceptions;
};
```

**helper 宏**（`ip_fib.h:288-290`）：
```c
#define FIB_RES_NHC(res)   ((res).nhc)
#define FIB_RES_DEV(res)   (FIB_RES_NHC(res)->nhc_dev)
#define FIB_RES_OIF(res)   (FIB_RES_NHC(res)->nhc_oif)
```

### 5.3 fib_nh vs fib_nh_common

`fib_nh` 是 `fib_nh_common` 的 IPv4 特化包装（`ip_fib.h:208-227`）：

```c
struct fib_nh {
    struct fib_nh_common  nh_common;
    struct hlist_node      nh_hash;
    struct fib_info       *nh_parent;
#ifdef CONFIG_IP_ROUTE_CLASSID
    __u32                 nh_tclassid;
#endif
    __be32                nh_saddr;
    int                   nh_saddr_genid;
    // ... 以及一堆 #define 宏展开 nh_common 字段
};
```

---

## 6. 路由缓存、Rules 与 rp_filter

### 6.1 查找标志位

```c
// include/net/fib_rules.h:60-61
#define FIB_LOOKUP_NOREF           1   // 不增加 fib_info 引用计数
#define FIB_LOOKUP_IGNORE_LINKSTATE 2  // 忽略链路状态（如 DOWN 的接口）
```

### 6.2 rp_filter 源地址校验

`fib_validate_source`（`fib_frontend.c:436`）实现 `rp_filter`（Reverse Path Filtering）：

```c
int fib_validate_source(struct sk_buff *skb, __be32 src, __be32 dst,
                        dscp_t dscp, int oif, struct net_device *dev,
                        struct in_device *idev, u32 *itag)
{
    // 分三种模式：
    // 0 = 关闭，不检查
    // 1 = 严格模式，要求入接口必须匹配路由出接口
    // 2 = 宽松模式，只要能找到到源地址的路由即可
    int r = secpath_exists(skb) ? 0 : IN_DEV_RPFILTER(idev);
    // ...
    if (!r && !fib_num_tclassid_users(net) && ...)
        goto ok;                          // 快速路径：跳过检查

    return __fib_validate_source(skb, src, dst, dscp, oif, dev, r, idev, itag);
}
```

`__fib_validate_source`（`fib_frontend.c:345`）执行实际检查：
1. 用 `fl4.daddr = src` 做反向路由查找（源地址当目标地址）
2. 如果找到的路由的出接口与实际入接口不同 → 失败
3. 如果类型不是 `RTN_UNICAST`（如 `RTN_LOCAL`）→ 特殊处理

### 6.3 fib_rules 策略路由

`fib4_rule_action`（`fib_rules.c:113`）的匹配流程：

```c
INDIRECT_CALLABLE_SCOPE int fib4_rule_action(struct fib_rule *rule,
                        struct flowi *flp, int flags,
                        struct fib_lookup_arg *arg)
{
    switch (rule->action) {
    case FR_ACT_TO_TBL:        // 查指定表
        tb_id = fib_rule_get_table(rule, arg);
        tbl = fib_get_table(rule->fr_net, tb_id);
        err = fib_table_lookup(tbl, &flp->u.ip4, res, arg->flags);
        break;
    case FR_ACT_UNREACHABLE:   // 不可达
        return -ENETUNREACH;
    case FR_ACT_PROHIBIT:       // 禁止
        return -EACCES;
    case FR_ACT_BLACKHOLE:      // 黑洞
        return -EINVAL;
    }
}
```

规则可以基于 `oif`、`iif`、源地址 `saddr`、fwmark 等匹配，这是 **基于 MARK 的路由策略** 的基础。

### 6.4 路由缓存历史

Linux 2.6 之前的路由缓存（`rtable`/`rt_hash`）在 modern 内核中已被移除。当前完全依赖 `fib_table_lookup` 实时查找。`fnhe_hash_bucket`（`ip_fib.h:145`）用于缓存每个 nexthop 的 PMTU 和网关信息。

---

## 7. 多路径路由（ECMP）

### 7.1 fib_select_path — 主选择函数

```c
// net/ipv4/fib_semantics.c:2208
void fib_select_path(struct net *net, struct fib_result *res,
                     struct flowi4 *fl4, const struct sk_buff *skb)
{
    if (fl4->flowi4_oif)
        goto check_saddr;          // 指定了出接口，不再做 ECMP

#ifdef CONFIG_IP_ROUTE_MULTIPATH
    if (fib_info_num_path(res->fi) > 1) {
        int h = fib_multipath_hash(net, fl4, skb, NULL);
        fib_select_multipath(res, h, fl4);   // ECMP 选择
    }
    else
#endif
    if (!res->prefixlen && res->table->tb_num_default > 1)
        fib_select_default(fl4, res);         // 默认路由多路径

check_saddr:
    if (!fl4->saddr) {
        // 自动选择合适的源地址
        fl4->saddr = fib_result_prefsrc(net, res);
    }
}
```

### 7.2 fib_select_multipath — ECMP 哈希选择

```c
// net/ipv4/fib_semantics.c:2164
void fib_select_multipath(struct fib_result *res, int hash,
                          const struct flowi4 *fl4)
{
    struct fib_info *fi = res->fi;
    int score = -1;
    __be32 saddr = fl4 ? fl4->saddr : 0;

    change_nexthops(fi) {
        int nh_upper_bound = atomic_read(&nexthop_nh->fib_nh_upper_bound);

        // 过滤不可用 nexthop
        if (nh_upper_bound == -1 ||
            (use_neigh && !fib_good_nh(nexthop_nh)))
            continue;

        // 评分机制：
        if (saddr && nexthop_nh->nh_saddr == saddr)  nh_score += 2; // 源地址匹配
        if (hash <= nh_upper_bound)                  nh_score += 1; // 哈希在权重范围内

        if (score < nh_score) {
            res->nh_sel = nhsel;
            res->nhc = &nexthop_nh->nh_common;
        }
    } endfor_nexthops(fi);
}
```

### 7.3 fib_multipath_hash — 哈希策略

```c
// net/ipv4/route.c:2066
int fib_multipath_hash(const struct net *net, const struct flowi4 *fl4,
                       const struct sk_buff *skb, struct flow_keys *flkeys)
{
    switch (net->ipv4.sysctl_fib_multipath_hash_policy) {
    case 0: // 纯 L3：src + dst IP
        mhash = fib_multipath_hash_from_keys(net, &hash_keys);
        break;
    case 1: // L3 + L4：src/dst IP + src/dst port + proto
        mhash = fib_multipath_hash_from_keys(net, &hash_keys);
        break;
    case 2: // 使用 skb 已有的 5-tuple hash（skb->l4_hash）
        return skb_get_hash_raw(skb) >> 1;
    }
    return mhash;
}
```

`sysctl_fib_multipath_hash_fields` 可进一步精细控制哈希字段（`ip_fib.h:370-393`）：
```c
#define FIB_MULTIPATH_HASH_FIELD_SRC_IP    BIT(0)
#define FIB_MULTIPATH_HASH_FIELD_DST_IP    BIT(1)
#define FIB_MULTIPATH_HASH_FIELD_IP_PROTO  BIT(2)
#define FIB_MULTIPATH_HASH_FIELD_SRC_PORT  BIT(4)
#define FIB_MULTIPATH_HASH_FIELD_DST_PORT  BIT(5)
// 等等
```

---

## 8. 基于 MARK 的路由策略

### 8.1 fwmark 流程

1. **打 mark**：用户空间通过 `iptables -t mangle -A PREROUTING -j MARK --set-mark 10`
2. **规则匹配**：在 `fib_rules` 中配置基于 fwmark 的规则：
   ```bash
   ip rule add fwmark 10 table 100
   ```
3. **查找时**：`flowi4.flowi4_mark = skb->mark`，传入 `fib_lookup()`

### 8.2 mark 影响 flowi4

`fib_compute_spec_dst`（`fib_frontend.c:272`）构建 flowi4 时：
```c
struct flowi4 fl4 = {
    .flowi4_iif    = LOOPBACK_IFINDEX,
    .flowi4_l3mdev = l3mdev_master_ifindex_rcu(dev),
    .daddr         = ip_hdr(skb)->saddr,
    .flowi4_mark   = vmark ? skb->mark : 0,   // ← mark 传入
    // ...
};
```

### 8.3 l3mdev（VRF）与 mark

`l3mdev_update_flow()`（`fib_rules.c:86`）在规则查找前修正 flowi4 的 `oif`/`iif`，使 VRF 场景下 mark + l3mdev 可以实现复杂的路由隔离策略。

### 8.4 rp_filter 与 mark 交互

`__fib_validate_source` 中的 `fl4.flowi4_mark` 会影响反向路径查找，但 rp_filter 检查的是路由本身，不是 mark 值。自定义规则中可以用 `fwmark` 匹配来改变路由行为。

---

## 9. 关键代码路径总结

```
skb 接收
  │
  ▼
ip_route_input_slow()
  │  (route.c)
  ├─►fib_lookup(net, &fl4, &res, 0)
  │    │
  │    ├─ 单表模式：直接 fib_table_lookup(RT_TABLE_MAIN)
  │    │
  │    └─ 多表模式：fib_rules_lookup()
  │         │
  │         ├─ fib4_rule_action() → fib_table_lookup(table)
  │         │   │
  │         │   └─ fib_table_lookup()   ← LPM in LC-trie
  │         │       │
  │         │       ├─ Step1: 沿 trie 向下（前缀压缩路径）
  │         │       ├─ Step2: 回溯找最长匹配
  │         │       └─ Step3: 遍历叶子 fib_alias 链
  │         │
  │         └─ fib4_rule_suppress() ← prefixlen/ifgroup 过滤
  │
  ├─►fib_validate_source()    ← rp_filter
  │    └─ fib_lookup(net, &fl4_reverse, &res, FIB_LOOKUP_IGNORE_LINKSTATE)
  │
  └─►fib_select_path(net, &res, &fl4, skb)
       │
       ├─ fib_multipath_hash()    ← ECMP 哈希
       │    └─ policy 0/1/2（纯 L3 / L3+L4 / skb hash）
       │
       ├─ fib_select_multipath() ← 多路径选择
       │    └─ fib_select_default()（默认路由多路径）
       │
       └─ fib_result_prefsrc()    ← 自动选择源地址
```

---

## 10. 关键数据结构一览

| 结构 | 文件 | 用途 |
|------|------|------|
| `fib_table` | `ip_fib.h:300` | 路由表描述符，含 `tb_id` 和 `tb_data`（trie） |
| `fib_result` | `ip_fib.h:260` | 查找结果：前缀、类型、nexthop、fib_info |
| `fib_info` | `ip_fib.h:187` | 路由信息：protocol/priority/nhs/nexthops |
| `fib_nh_common` | `ip_fib.h:165` | nexthop 公共部分（设备、网关、权重、flags） |
| `fib_nh` | `ip_fib.h:208` | IPv4 专用 nexthop（包装 fib_nh_common） |
| `fib_alias` | `fib_lookup.h:17` | 前缀+类型+DSCP+fib_info 的叶子条目 |
| `key_vector` | `fib_trie.c:116` | trie 节点：前缀/位置/比特/子节点数组或叶子链表 |
| `tnode` | `fib_trie.c:131` | 内部节点，含 empty/full_children 计数 |
| `flowi4` | `flow.h` | 查找关键字：daddr/saddr/mark/oif/dscp/proto |

---

## 11. 参考

- `net/ipv4/fib_frontend.c` — 表初始化、地址类型、源校验、ioctl
- `net/ipv4/fib_trie.c` — LC-trie 实现、查找、插入、删除、重平衡
- `net/ipv4/fib_semantics.c` — fib_info 管理、ECMP 选择、路由信息
- `net/ipv4/fib_rules.c` — 策略路由规则分发
- `net/ipv4/route.c` — multipath 哈希、选路入口 `ip_route_input_slow`
- `include/net/ip_fib.h` — 核心数据结构定义
- `include/net/fib_rules.h` — `FIB_LOOKUP_NOREF` 等标志位
- `include/net/flow.h` — `flowi4` 定义
- `net/ipv4/fib_lookup.h` — `fib_alias` 定义
