# 209-nf_conntrack_netlink — 连接跟踪netlink接口深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/netfilter/nf_conntrack_netlink.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**conntrack netlink** 是用户空间访问连接跟踪状态的接口，iptables/libnetfilter_conntrack 使用它查询/修改连接状态。

---

## 1. conntrack netlink 消息

```bash
# conntrack 命令使用 netlink 访问：
conntrack -L                    # 列出连接
conntrack -I -p tcp --sport 80  # 插入规则
conntrack -D -p tcp             # 删除规则

# conntrack 是 libnetfilter_conntrack 的前端
```

---

## 2. nfct 对象

```c
// libnetfilter_conntrack API：
nfct_handle *ct = nfct_open(NFNL_SUBSYS_CTNETLINK, 0);
nfct_callback_register(cb, handler);
nfct_query(ct, NFCTQ_DUMP, &data);
```

---

## 3. 西游记类喻

**conntrack netlink** 就像"天庭的户籍网络处"——

> conntrack netlink 像户籍处的专线网络（Netlink 协议），让地方官员（iptables/conntrack 工具）可以通过网络专线查看和修改户籍信息（连接跟踪状态）。比起直接翻册子（/proc），netlink 更快、更结构化。

---

## 4. 关联文章

- **conntrack**（article 154）：连接跟踪基础
- **netlink**（article 103）：netlink 基础