# 155-iptables_nat — NAT深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/ipv4/netfilter/nat*.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**NAT（Network Address Translation）** 通过 netfilter 的 nat 表实现，将私有 IP 地址转换为公网 IP。Linux 支持 SNAT（源地址转换）、DNAT（目的地址转换）、FULLNAT（双向转换）。

---

## 1. NAT 类型

```
SNAT（Source NAT）：
  修改数据包的源 IP/端口
  例：内网 192.168.1.100:5000 → 公网 1.2.3.4:10000
  用于：内网共享公网 IP

DNAT（Destination NAT）：
  修改数据包的目的 IP/端口
  例：公网 1.2.3.4:80 → 内网 192.168.1.100:80
  用于：端口映射、服务暴露

MASQUERADE：
  动态 SNAT，自动选择出口 IP
  例：自动使用 eth0 的 IP 作为源 IP

FULLNAT：
  同时修改源和目的 IP（特殊场景）
```

---

## 2. NAT 表与链

```
iptables nat 表的 HOOK 点：

PREROUTING  [NF_INET_PRE_ROUTING]  → DNAT（端口映射）
OUTPUT      [NF_INET_LOCAL_OUT]     → 本地进程的 DNAT
POSTROUTING [NF_INET_POST_ROUTING]  → SNAT / MASQUERADE
```

---

## 3. NAT 核心结构

### 3.1 struct nf_nat_tuple — NAT 元组

```c
// include/net/netfilter/nf_nat.h — nf_nat_tuple
struct nf_nat_tuple {
    struct nf_conntrack_tuple  src;     // 源（可能被修改）
    struct nf_conntrack_tuple  dst;     // 目的（可能被修改）
};
```

### 3.2 struct nf_nat_mapping — NAT 映射

```c
// net/ipv4/netfilter/nf_nat_core.c — nf_nat_mapping
struct nf_nat_mapping {
    struct nf_conntrack_tuple  original;   // 原始 tuple
    struct nf_conntrack_tuple  reply;     // 回复 tuple（自动计算）

    // NAT 地址/端口
    union nf_inet_addr         addr;     // 转换后的 IP
    __be16                     port;     // 转换后的端口（0 = 自动分配）

    // 状态
    unsigned long              expires;    // 过期时间
    struct rcu_head            rcu_head;
};
```

### 3.3 struct nf_conn_nat — NAT 扩展

```c
// include/net/netfilter/nf_nat.h — nf_conn_nat
struct nf_conn_nat {
    struct nf_nat_info         info;     // NAT 信息

    // IP 分配（用于 by-source NAT）
    struct nf_nat_range2       *range;    // 地址范围

    // NAT 钩子
    int                       (*manip_hook)(struct sk_buff *skb,
                                          struct nf_conn *ct,
                                          enum nf_nat_manip_type maniptype,
                                          unsigned int hooknum);
};
```

---

## 4. SNAT（Source NAT）

### 4.1 ipt_snat_target — SNAT target

```c
// net/ipv4/netfilter/nf_nat_rule.c — ipt_snat_target
int ipt_snat_target(struct sk_buff *skb, const struct xt_action_param *par)
{
    struct nf_conn *ct = nf_ct_get(skb, &ctinfo);
    struct nf_nat_range2 range;

    // 设置 SNAT 范围
    range.min = xt_tginfo->min_addr;
    range.max = xt_tginfo->max_addr;
    range.min_proto = xt_tginfo->min;
    range.max_proto = xt_tginfo->max;

    // 执行 NAT
    return nf_nat_setup_info(ct, &range, NF_NAT_MANIP_SRC);
}
```

### 4.2 nf_nat_setup_info — NAT 设置

```c
// net/ipv4/netfilter/nf_nat_core.c — nf_nat_setup_info
int nf_nat_setup_info(struct nf_conn *ct,
                     const struct nf_nat_range2 *range,
                     enum nf_nat_manip_type manip_type)
{
    struct nf_conn_nat *nat;

    // 1. 分配 NAT 结构
    nat = nf_ct_ext_add(ct, NF_CT_EXT_NAT, GFP_KERNEL);

    // 2. 分配 NAT tuple（根据范围）
    nf_nat_setup_tuple(ct, manip_type, range, &nat->tpl);

    // 3. 设置 conntrack 状态
    if (manip_type == NF_NAT_MANIP_SRC)
        ct->status |= IPS_SRC_NAT;
    else
        ct->status |= IPS_DST_NAT;

    return 0;
}
```

---

## 5. DNAT（Destination NAT）

### 5.1 ipt_dnat_target — DNAT target

```c
// net/ipv4/netfilter/nf_nat_rule.c — ipt_dnat_target
int ipt_dnat_target(struct sk_buff *skb, const struct xt_action_param *par)
{
    struct nf_conn *ct = nf_ct_get(skb, &ctinfo);
    struct nf_nat_range2 range;

    // 设置 DNAT 范围
    range.min = xt_tginfo->min_addr;
    range.max = xt_tginfo->max_addr;
    range.min_proto = xt_tginfo->min;
    range.max_proto = xt_tginfo->max;

    // 执行 DNAT
    return nf_nat_setup_info(ct, &range, NF_NAT_MANIP_DST);
}
```

---

## 6. MASQUERADE（动态 SNAT）

### 6.1 ipt_masquerade_target

```c
// net/ipv4/netfilter/nf_nat_rule.c — ipt_masquerade_target
int ipt_masquerade_target(struct sk_buff *skb,
                          const struct xt_action_param *par)
{
    // MASQUERADE = 自动选择出口 IP 的 SNAT
    // 使用 skb->dev 的 IP 作为源 IP
    struct nf_nat_range2 range;

    range.flags |= NF_NAT_RANGE_MAP_IPS;
    range.min_addr = range.max_addr = xt_outdev->ip_addr;

    // 自动分配端口
    return nf_nat_setup_info(ct, &range, NF_NAT_MANIP_SRC);
}
```

---

## 7. NAT 与 conntrack 的关系

```
NAT 与 conntrack 紧密集成：

当设置 NAT 时，conntrack 同时更新两个方向：

  原始方向 tuple（A → B）：
    A:src_ip = 192.168.1.100:5000
    B:dst_ip = 1.2.3.4:80

  回复方向 tuple 自动生成为（A ← B）：
    A:src_ip = 1.2.3.4:80      （A 的 IP 变成了公网 IP）
    B:dst_ip = 192.168.1.100:5000 （B 的 IP 还原为内网 IP）

conntrack 确保回复数据包能正确被"反 NAT"
```

---

## 8. 使用示例

```bash
# SNAT（内网共享 IP）：
iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -j SNAT --to-source 1.2.3.4

# MASQUERADE（动态 IP）：
iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -j MASQUERADE

# DNAT（端口映射）：
iptables -t nat -A PREROUTING -d 1.2.3.4:80 -j DNAT --to-destination 192.168.1.100:8080

# 查看 NAT 表：
iptables -t nat -L -n -v
```

---

## 9. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `net/ipv4/netfilter/nf_nat_rule.c` | `ipt_snat_target`、`ipt_dnat_target`、`ipt_masquerade_target` |
| `net/ipv4/netfilter/nf_nat_core.c` | `nf_nat_setup_info` |
| `include/net/netfilter/nf_nat.h` | `struct nf_nat_tuple`、`struct nf_conn_nat` |

---

## 10. 西游记类比

**iptables NAT** 就像"天庭的户籍转换处"——

> 内网的妖怪（192.168.1.x）要上天庭（公网），户籍转换处（NAT）负责把他们的内网身份证（私有 IP）换成天庭的公共身份证（公网 IP）。SNAT 就是把"北京市朝阳区XX号"改成"天庭登记号1"；DNAT 就是把"天庭登记号1"改成"北京市朝阳区XX号"。MASQUERADE 像自动分配户口的窗口——不固定用哪个天庭号，根据当天值班表来分配。户籍转换处还有一本大账本（conntrack），记录了每次转换的对应关系，确保从天庭回的信能被正确送回到原来的妖怪那里。

---

## 11. 关联文章

- **conntrack**（article 154）：NAT 依赖连接跟踪
- **netfilter hooks**（article 153）：NAT 在 POSTROUTING/PREROUTING HOOK 执行