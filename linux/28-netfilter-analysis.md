# 28-netfilter — 网络过滤框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**Netfilter** 是 Linux 的包过滤/修改框架。内核网络协议栈的关键点注册钩子函数，iptables/nftables 等工具基于此实现。

---

## 1. 五个钩子点

```
PRE_ROUTING → [路由决策] → FORWARD → POST_ROUTING
                  │                    │
                  └── LOCAL_IN      LOCAL_OUT
```

| 钩子点 | 触发时机 | 典型用途 |
|--------|---------|---------|
| NF_INET_PRE_ROUTING | 路由前 | DNAT |
| NF_INET_LOCAL_IN | 本地目的 | INPUT 规则 |
| NF_INET_FORWARD | 转发 | FORWARD 规则 |
| NF_INET_LOCAL_OUT | 本地发出 | OUTPUT 规则 |
| NF_INET_POST_ROUTING | 路由后 | SNAT |

---

## 2. 判决值

```
NF_DROP（0）   → 丢弃
NF_ACCEPT（1） → 继续
NF_STOLEN（2） → 包被接管
NF_QUEUE（3）  → 排队到用户空间
NF_REPEAT（4） → 重新执行
```

---

*分析工具：doom-lsp（clangd LSP）*
