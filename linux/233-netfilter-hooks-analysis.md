# netfilter Hook 机制深度分析

## 1. 概述

netfilter 是 Linux 内核中实现数据包过滤、网络地址转换（NAT）、连接跟踪等功能的框架。其核心是一套基于"钩子"（hook）的机制：数据包在网络协议栈的关键路径上经过若干检查点，每个检查点会调用已注册的所有 hook 函数，根据其返回值决定数据包的命运。

本文基于 Linux 7.0-rc1 源码，分析核心数据结构 `struct nf_hook_ops`、注册/注销流程、`nf_hook_slow` 遍历逻辑、Ingress/Egress hook、hook num 与优先级体系、verdict 返回值，以及 BPF 扩展与 TC（Traffic Control）集成。

源码文件：
- `/home/dev/code/linux/net/netfilter/core.c` — hook 注册/注销、分配、遍历
- `/home/dev/code/linux/include/linux/netfilter.h` — 核心数据结构定义
- `/home/dev/code/linux/include/uapi/linux/netfilter.h` — 用户空间可见的定义（hook num、verdict）
- `/home/dev/code/linux/include/uapi/linux/netfilter_ipv4.h` — IPv4 优先级枚举
- `/home/dev/code/linux/net/netfilter/nfnetlink_hook.c` — nfnetlink hook 查询接口
- `/home/dev/code/linux/net/netfilter/nf_bpf_link.c` — BPF link 附加方式

## 2. struct nf_hook_ops — Hook 注册结构

### 2.1 数据结构定义

定义于 `include/linux/netfilter.h:91~114`：

```c
enum nf_hook_ops_type {
    NF_HOOK_OP_UNDEFINED,
    NF_HOOK_OP_NF_TABLES,   // nftables 注册的 hook
    NF_HOOK_OP_BPF,          // BPF 程序附加
    NF_HOOK_OP_NFT_FT,       // nftables flowtable
};

struct nf_hook_ops {
    struct list_head    list;       // 用于组成链表（现已不使用，仅作兼容）
    struct rcu_head     rcu;        // RCU 释放回调

    /* 用户填写以下字段 */
    nf_hookfn           *hook;       // 回调函数指针
    struct net_device   *dev;       // 绑定的网络设备（Ingress/Egress hook 使用）
    void                *priv;      // 私有数据，传递给 hook 函数
    u8                  pf;         // 协议族：NFPROTO_IPV4/IPV6/INET/BRIDGE/ARP/NETDEV...
    enum nf_hook_ops_type hook_ops_type:8;  // hook 类型（影响优先级处理）
    unsigned int        hooknum;     // hook 编号（见下节）
    int                 priority;   // 优先级，数值越小越先执行
};
```

其中 `nf_hookfn` 类型定义（第 88~90 行）：

```c
typedef unsigned int nf_hookfn(void *priv,
                              struct sk_buff *skb,
                              const struct nf_hook_state *state);
```

回调函数接收 `priv`（注册时传入的私有数据）、`skb`（数据包）和 `state`（当前 hook 的上下文信息），返回 `unsigned int` verdict。

`nf_hook_state` 定义（第 78~86 行）：

```c
struct nf_hook_state {
    u8              hook;       // 当前执行到的 hook 编号
    u8              pf;         // 协议族
    struct net_device *in;       // 入向设备
    struct net_device *out;     // 出向设备
    struct sock     *sk;         // 相关 socket（可能为 NULL）
    struct net      *net;        // 网络命名空间
    int             (*okfn)(...); // 继续正常处理流程的回调
};
```

### 2.2 关键设计细节

**（1）`list` 和 `rcu` 字段**：旧的 hook 注册使用 `list_head` 链表，现已被 `nf_hook_entries` 数组替代（见下节），但这两个字段保留用于二进制兼容。

**（2）`hook_ops_type` 字段**：用于区分不同子系统注册的 hook。核心逻辑中对 `NF_HOOK_OP_BPF` 类型有特殊处理 — 当两个 BPF hook 优先级相同时，禁止共享同一个优先级槽位（core.c:125），避免 BPF 程序之间的排序歧义。

**（3）`dev` 字段**：对于 `NFPROTO_NETDEV` 协议族（`NF_NETDEV_INGRESS`/`NF_NETDEV_EGRESS`）或 `NFPROTO_INET` + `NF_INET_INGRESS`，`dev` 必须指定具体的网络设备。非 netdev hook 此字段为 NULL。

## 3. Hook 存储结构 — nf_hook_entries

### 3.1 核心数据结构

```c
// include/linux/netfilter.h:114~130
struct nf_hook_entry {
    nf_hookfn      *hook;
    void           *priv;
};

struct nf_hook_entries {
    u16             num_hook_entries;  // 当前注册的 hook 数量
    struct nf_hook_entry hooks[];     // 变长数组
    /* 末尾紧接着：
     *   struct nf_hook_ops **  orig_ops[]  — 指向原始注册结构
     *   struct nf_hook_entries_rcu_head   — RCU 释放头
     */
};
```

### 3.2 存储布局（核心设计）

`nf_hook_entries` 采用变长结构体设计，在 `hooks[]` 数组之后紧接着存储 `orig_ops` 指针数组和 RCU 头。这是一种零空间开销的"尾部数据结构"（tailallocated struct）技巧 — 通过指针运算在 `hooks[n]` 之后访问 `orig_ops`，仅在需要时才访问（hook 注册/注销的慢路径），数据包处理路径（`nf_hook_slow`）不需要访问 `orig_ops`。

核心辅助函数（`include/linux/netfilter.h:133~137`）：

```c
static inline struct nf_hook_ops **
nf_hook_entries_get_hook_ops(const struct nf_hook_entries *e)
{
    unsigned int n = e->num_hook_entries;
    const void *hook_end;
    hook_end = &e->hooks[n];  // 越过 hooks[] 数组
    return (struct nf_hook_ops **)hook_end;  // 得到 orig_ops[] 起始地址
}
```

执行单个 hook 回调的辅助函数（第 156~159 行）：

```c
static inline int
nf_hook_entry_hookfn(const struct nf_hook_entry *entry,
                     struct sk_buff *skb, struct nf_hook_state *state)
{
    return entry->hook(entry->priv, skb, state);
}
```

### 3.3 分配与增长

`allocate_hook_entries_size`（core.c:43~56）计算所需内存：

```c
static struct nf_hook_entries *allocate_hook_entries_size(u16 num)
{
    size_t alloc = sizeof(*e)                  // nf_hook_entries 头
                 + sizeof(struct nf_hook_entry) * num   // hooks[]
                 + sizeof(struct nf_hook_ops *) * num   // orig_ops[]
                 + sizeof(struct nf_hook_entries_rcu_head); // RCU 头
    // ...
}
```

最大允许 1024 个 hook（`MAX_HOOK_COUNT`，core.c:40）。

## 4. Hook 注册 — nf_register_net_hook / __nf_register_net_hook

### 4.1 入口函数（core.c:363~385）

```c
int nf_register_net_hook(struct net *net, const struct nf_hook_ops *reg)
{
    int err;

    if (reg->pf == NFPROTO_INET) {
        // NFPROTO_INET 是一个"协议族聚合"：IPv4 和 IPv6 共用同一套 hook
        if (reg->hooknum == NF_INET_INGRESS) {
            // NF_INET_INGRESS 只在 NFPROTO_INET 下有效
            err = __nf_register_net_hook(net, NFPROTO_INET, reg);
        } else {
            // 其他 hook 同时注册到 IPv4 和 IPv6
            err = __nf_register_net_hook(net, NFPROTO_IPV4, reg);
            if (err < 0) return err;
            err = __nf_register_net_hook(net, NFPROTO_IPV6, reg);
            if (err < 0) {
                __nf_unregister_net_hook(net, NFPROTO_IPV4, reg);
                return err;
            }
        }
    } else {
        err = __nf_register_net_hook(net, reg->pf, reg);
    }
    return 0;
}
```

### 4.2 实际注册逻辑（core.c:321~362）

`__nf_register_net_hook` 的核心步骤：

**Step 1. 协议族和 hook 参数校验**

对 `NFPROTO_NETDEV`，仅接受 `NF_NETDEV_INGRESS` 和 `NF_NETDEV_EGRESS`，且 `dev` 不能为 NULL。对 `NFPROTO_INET + NF_INET_INGRESS`，调用 `nf_ingress_check`（core.c:272~280）验证 `dev` 存在且属于正确的 net namespace。

**Step 2. 获取 hook 链表头**

```c
static struct nf_hook_entries __rcu **
nf_hook_entry_head(struct net *net, int pf, unsigned int hooknum,
                   struct net_device *dev)  // core.c:227~264
{
    switch (pf) {
    case NFPROTO_IPV4:
        return net->nf.hooks_ipv4 + hooknum;
    case NFPROTO_IPV6:
        return net->nf.hooks_ipv6 + hooknum;
    case NFPROTO_ARP:
        return net->nf.hooks_arp + hooknum;
    case NFPROTO_BRIDGE:
        return net->nf.hooks_bridge + hooknum;
    case NFPROTO_INET:
        // 注意：NF_INET_INGRESS 实际存放在设备的 nf_hooks_ingress 中
        if (hooknum == NF_INET_INGRESS)
            return &dev->nf_hooks_ingress;
        break;
    case NFPROTO_NETDEV:
        if (hooknum == NF_NETDEV_INGRESS)
            return &dev->nf_hooks_ingress;
        if (hooknum == NF_NETDEV_EGRESS)
            return &dev->nf_hooks_egress;
        break;
    }
}
```

对于 Ingress hook，无论是 `NFPROTO_INET` 还是 `NFPROTO_NETDEV`，最终的存储位置都是 **设备级别** 的 `dev->nf_hooks_ingress`，而不是 net namespace 中的数组。这是有意的设计 — Ingress hook 与具体设备绑定。

**Step 3. 使用 mutex 保护，调用 `nf_hook_entries_grow`**

`nf_hook_entries_grow`（core.c:96~136）按 **优先级升序** 插入新 hook 到数组中。插入算法：

```c
while (i < old_entries) {
    if (orig_ops[i] == &dummy_ops) {   // 跳过已被注销的占位 hook
        ++i; continue;
    }
    // priority > orig_ops[i]->priority：插到当前元素之前
    if (inserted || reg->priority > orig_ops[i]->priority) {
        new_ops[nhooks] = (void *)orig_ops[i];
        new->hooks[nhooks] = old->hooks[i];
        i++;
    } else {
        // 插入新 hook
        new_ops[nhooks] = (void *)reg;
        new->hooks[nhooks].hook = reg->hook;
        new->hooks[nhooks].priv = reg->priv;
        inserted = true;
    }
    nhooks++;
}
// 如果还没插（优先级最小），插到末尾
if (!inserted) { ... }
```

### 4.4 NFPROTO_INET 的双注册语义

`NFPROTO_INET` 是一个协议族别名，代表"不区分 IPv4/IPv6"。当注册一个非 Ingress 的 hook（如 `NF_INET_PRE_ROUTING`）到 `NFPROTO_INET` 时，实际上同时在 `net->nf.hooks_ipv4[hook]` 和 `net->nf.hooks_ipv6[hook]` 各注册了一份。这样做的好处是 iptables/nftables 等工具无需关心数据包是 IPv4 还是 IPv6，可以统一注册。

## 5. Hook 注销 — nf_unregister_net_hook / __nf_unregister_net_hook

### 5.1 核心原理：惰性删除

Hook 注销**不允许失败**，因此不采用直接移除的方式，而是两步走：

1. **替换为 dummy_ops**：将目标 hook 的 `entry->hook` 替换为 `accept_all`（直接返回 `NF_ACCEPT`），`orig_ops` 指针替换为 `dummy_ops`（core.c:298~309）。
2. **延迟收缩**：调用 `__nf_hook_entries_try_shrink`（core.c:227~253）尝试分配更小的数组，将所有 dummy hook 剔除，原数组通过 RCU 延迟释放。

```c
// core.c:298~309 — 惰性删除的核心
static bool nf_remove_net_hook(struct nf_hook_entries *old,
                                const struct nf_hook_ops *unreg)
{
    struct nf_hook_ops **orig_ops;
    unsigned int i;
    orig_ops = nf_hook_entries_get_hook_ops(old);
    for (i = 0; i < old->num_hook_entries; i++) {
        if (orig_ops[i] != unreg) continue;
        WRITE_ONCE(old->hooks[i].hook, accept_all);  // 替换为 dummy
        WRITE_ONCE(orig_ops[i], (void *)&dummy_ops);
        return true;
    }
    return false;
}
```

为什么这样设计？因为 hook 可能正在 RCU 保护的数据包处理路径中被访问（`nf_hook_slow` 中）。直接 free 会导致 use-after-free。通过 RCU，读取方最多看到旧数组，而新数组不包含正在注销的 hook — 实现了无锁的安全删除。

## 6. Hook 遍历入口 — nf_hook_slow

### 6.1 函数签名与核心循环

```c
// core.c:385~413
int nf_hook_slow(struct sk_buff *skb, struct nf_hook_state *state,
                 const struct nf_hook_entries *e, unsigned int s)
{
    unsigned int verdict;
    int ret;

    for (; s < e->num_hook_entries; s++) {
        verdict = nf_hook_entry_hookfn(&e->hooks[s], skb, state);
        switch (verdict & NF_VERDICT_MASK) {
        case NF_ACCEPT:
            break;  // 继续执行下一个 hook
        case NF_DROP:
            kfree_skb_reason(skb, SKB_DROP_REASON_NETFILTER_DROP);
            ret = NF_DROP_GETERR(verdict);  // 从 verdict 提取错误码
            if (ret == 0) ret = -EPERM;
            return ret;
        case NF_QUEUE:
            ret = nf_queue(skb, state, s, verdict);
            if (ret == 1) continue;  // 1 表示重新入队，继续下一个 hook
            return ret;
        case NF_STOLEN:
            return NF_DROP_GETERR(verdict);  // NF_STOLEN 不再使用
        default:
            WARN_ON_ONCE(1);
            return 0;
        }
    }
    return 1;  // 所有 hook 都返回 ACCEPT，返回 1 表示调用 okfn
}
```

返回值语义：返回 1 表示数据包通过了所有 hook，需要调用 `okfn` 继续协议栈处理；返回负值表示错误/丢弃。

### 6.2 nf_hook — 内联快捷入口

`include/linux/netfilter.h:230~266` 定义了内联函数 `nf_hook`，这是协议栈中调用 hook 的标准方式：

```c
static inline int nf_hook(u_int8_t pf, unsigned int hook, struct net *net,
                          struct sock *sk, struct sk_buff *skb,
                          struct net_device *indev, struct net_device *outdev,
                          int (*okfn)(...))
{
    struct nf_hook_entries *hook_head = NULL;
    int ret = 1;

#ifdef CONFIG_JUMP_LABEL
    // 编译期常量路径：如果没有任何 hook 注册，static_key 直接跳过
    if (__builtin_constant_p(pf) &&
        __builtin_constant_p(hook) &&
        !static_key_false(&nf_hooks_needed[pf][hook]))
        return 1;
#endif

    rcu_read_lock();
    // 从 namespace 或设备获取 hook 数组头
    switch (pf) {
    case NFPROTO_IPV4:
        hook_head = rcu_dereference(net->nf.hooks_ipv4[hook]);
        break;
    case NFPROTO_IPV6:
        hook_head = rcu_dereference(net->nf.hooks_ipv6[hook]);
        break;
    // ...
    }
    if (hook_head) {
        struct nf_hook_state state;
        nf_hook_state_init(&state, hook, pf, indev, outdev, sk, net, okfn);
        ret = nf_hook_slow(skb, &state, hook_head, 0);
    }
    rcu_read_unlock();
    return ret;
}
```

## 7. Ingress Hook — NF_INET_INGRESS / NF_NETDEV_INGRESS

### 7.1 两套 Ingress hook 体系

Linux 实现了**两套** Ingress hook：

| 协议族 | Hook 编号 | 存储位置 | 触发时机 |
|--------|-----------|----------|----------|
| `NFPROTO_INET` | `NF_INET_INGRESS` | `dev->nf_hooks_ingress` | 通用，IPv4/IPv6 统一 |
| `NFPROTO_NETDEV` | `NF_NETDEV_INGRESS` | `dev->nf_hooks_ingress` | 底层，设备驱动层 |

两者的存储位置相同（都是 `dev->nf_hooks_ingress`），但协议族不同。`NFPROTO_INET + NF_INET_INGRESS` 是较新的接口，提供跨协议族的统一 Ingress hook。

### 7.2 netdevice 结构中的 hook 字段

定义于 `include/linux/netdevice.h:2370`：

```c
struct net_device {
    // ...
    struct nf_hook_entries __rcu *nf_hooks_ingress;   // line 2370
#if IS_ENABLED(CONFIG_NETFILTER_EGRESS)
    struct nf_hook_entries __rcu *nf_hooks_egress;    // line 2158
#endif
    // ...
};
```

### 7.3 注册时的分发逻辑（core.c:290~302）

```c
static struct nf_hook_entries __rcu **
nf_hook_entry_head(struct net *net, int pf, unsigned int hooknum,
                   struct net_device *dev)
{
    switch (pf) {
    case NFPROTO_INET:
        if (hooknum == NF_INET_INGRESS)
            return &dev->nf_hooks_ingress;  // 实际放在设备上
        break;
    case NFPROTO_NETDEV:
        if (hooknum == NF_NETDEV_INGRESS)
            return &dev->nf_hooks_ingress;
        if (hooknum == NF_NETDEV_EGRESS)
            return &dev->nf_hooks_egress;
        break;
    }
}
```

注意：对于 `NFPROTO_INET + NF_INET_INGRESS`，`nf_hook_entry_head` 返回的是 `dev->nf_hooks_ingress`，而不是 `net->nf.hooks_ipv4` 等。

### 7.4 Ingress hook 的调用时机

Ingress hook 在 `netif_receive_skb` 或 `netdev_rx_queue` 流程中被调用，是数据包最早可被 netfilter 处理的时机 — **在协议层解析之前**，数据包以 raw SKB 的形式经过。

## 8. Hook Num 与优先级体系

### 8.1 Hook Num 枚举

定义于 `include/uapi/linux/netfilter.h:56~71`：

```c
// IPv4/IPv6 通用 hook（5个）
enum nf_inet_hooks {
    NF_INET_PRE_ROUTING,    // 0: 入方向，最早的 hook（接收后/分用前）
    NF_INET_LOCAL_IN,       // 1: 目的为本机的数据包
    NF_INET_FORWARD,        // 2: 转发数据包
    NF_INET_LOCAL_OUT,      // 3: 本机发出的数据包
    NF_INET_POST_ROUTING,   // 4: 出方向，最后的 hook（发送前）
    NF_INET_NUMHOOKS,       // 5: 总数
    NF_INET_INGRESS = NF_INET_NUMHOOKS,  // 5: Ingress hook（作为扩展）
};

enum nf_dev_hooks {
    NF_NETDEV_INGRESS,  // 0: 设备 Ingress
    NF_NETDEV_EGRESS,   // 1: 设备 Egress
    NF_NETDEV_NUMHOOKS
};
```

### 8.2 优先级体系

IPv4 的优先级定义在 `include/uapi/linux/netfilter_ipv4.h`：

```c
enum nf_ip_hook_priorities {
    NF_IP_PRI_FIRST = INT_MIN,           // 最高
    NF_IP_PRI_RAW_BEFORE_DEFRAG = -450,  // 重组前 RAW
    NF_IP_PRI_CONNTRACK_DEFRAG = -400,   // 连接跟踪-重组
    NF_IP_PRI_RAW = -300,                // RAW
    NF_IP_PRI_SELINUX_FIRST = -225,      // SELinux
    NF_IP_PRI_CONNTRACK = -200,          // 连接跟踪（conntrack）
    NF_IP_PRI_MANGLE = -150,             // Mangle 表
    NF_IP_PRI_NAT_DST = -100,            // DNAT
    NF_IP_PRI_FILTER = 0,                // FILTER 表（默认）
    NF_IP_PRI_SECURITY = 50,             // Security LSM
    NF_IP_PRI_NAT_SRC = 100,             // SNAT
    NF_IP_PRI_SELINUX_LAST = 225,        // SELinux 尾部
    NF_IP_PRI_CONNTRACK_HELPER = 300,    // 连接跟踪辅助
    NF_IP_PRI_CONNTRACK_CONFIRM = INT_MAX, // 连接跟踪确认（最低）
    NF_IP_PRI_LAST = INT_MAX,
};
```

数值越小越先执行。典型顺序：`conntrack(PRIORITY=-200)` → `filter(PRIORITY=0)` → `nat src(PRIORITY=100)` → `conntrack confirm(PRIORITY=INT_MAX)`。

### 8.3 插入时的排序保证

`nf_hook_entries_grow` 的插入过程保证 hook 数组按 `priority` **升序**（小值在前）排列，因此 `nf_hook_slow` 遍历时自然按优先级从高到低执行。

## 9. Verdict 返回值

### 9.1 基本 Verdict（定义于 `include/uapi/linux/netfilter.h:42~50`）

```c
#define NF_DROP      0   // 丢弃数据包
#define NF_ACCEPT    1   // 允许通过，继续下一个 hook
#define NF_STOLEN    2   // 已被"劫持"（已废弃，不应再使用）
#define NF_QUEUE     3   // 交给用户空间处理（via nfnetlink_queue）
#define NF_REPEAT    4   // 重新调用同一个 hook
#define NF_STOP      5   // 已废弃
```

### 9.2 编码机制：Verdict + 额外信息

Verdict 的低 8 位（`NF_VERDICT_MASK = 0xFF`）存储 verdict 类型，高位可编码额外信息：

```c
#define NF_VERDICT_MASK   0x000000ff
#define NF_VERDICT_FLAG_QUEUE_BYPASS  0x00008000
#define NF_VERDICT_QMASK  0xffff0000
#define NF_VERDICT_QBITS   16

// NF_QUEUE: 编码队列编号
#define NF_QUEUE_NR(x)  ((((x) << 16) & NF_VERDICT_QMASK) | NF_QUEUE)

// NF_DROP: 编码错误码（负值）
#define NF_DROP_ERR(x)  (((-x) << 16) | NF_DROP)

// 从 verdict 提取错误码
static inline int NF_DROP_GETERR(int verdict) {
    return -(verdict >> NF_VERDICT_QBITS);
}
```

### 9.3 Verdict 处理语义

在 `nf_hook_slow` 中的处理：

- `NF_ACCEPT`：跳出 `switch`，`for` 循环继续，执行下一个 hook。
- `NF_DROP`：释放 skb，提取错误码（若有），返回负值（传递给调用方）。
- `NF_QUEUE`：调用 `nf_queue()` 将数据包送入用户空间队列；若 `nf_queue()` 返回 1，表示队列绕过（`NF_VERDICT_FLAG_QUEUE_BYPASS`），继续下一个 hook。
- `NF_STOLEN`：直接返回，不释放 skb（已废弃，容易导致资源泄漏）。
- `NF_REPEAT`：历史上表示重新执行当前 hook；但当前实现中**已不再支持此行为**（core.c:407 的 `default` 分支会 WARN），因为 hook 重入非常危险。

## 10. Egress Hook — NF_NETDEV_EGRESS

### 10.1 存储位置

`NF_NETDEV_EGRESS` hook 存储在 `dev->nf_hooks_egress`（`include/linux/netdevice.h:2158`），由 `CONFIG_NETFILTER_EGRESS` 配置选项（默认关闭）控制。

### 10.2 注册限制

由于 `CONFIG_NETFILTER_EGRESS` 默认关闭，大多数内核不支持 egress hook 注册。尝试注册会返回 `-EOPNOTSUPP`（core.c:324~325）。这也是为什么 `NF_NETDEV_EGRESS` 不像 `NF_NETDEV_INGRESS` 那样广泛使用。

### 10.3 与 POST_ROUTING 的区别

`NF_INET_POST_ROUTING` 是在 **协议栈层**（IP 层）注册的 hook，在路由决策之后、发送到设备之前执行。而 `NF_NETDEV_EGRESS` 是在 **设备驱动层**，数据包即将通过网卡发送出去前执行，更接近硬件。`POST_ROUTING` 理论上可以对同一数据包执行多次（通过虚拟设备重发送），而 `EGRESS` 每个数据包只会经过一次。

## 11. BPF 扩展 — bpf_nfnl_hook 与 bpf_nf_link

### 11.1 BPF Netfilter Link 的注册方式

`nf_bpf_link.c` 实现了通过 BPF link 附加 netfilter hook 的机制。核心函数 `bpf_nf_link_attach`（第 155~207 行）：

```c
int bpf_nf_link_attach(const union bpf_attr *attr, struct bpf_prog *prog)
{
    // Step 1: 校验协议族、hooknum、优先级
    err = bpf_nf_check_pf_and_hooks(attr);

    // Step 2: 分配 bpf_nf_link
    link = kzalloc_obj(*link, GFP_USER);
    bpf_link_init(&link->link, BPF_LINK_TYPE_NETFILTER, ...);

    // Step 3: 设置 hook_ops
    link->hook_ops.hook = nf_hook_run_bpf;        // BPF 程序执行入口
    link->hook_ops.hook_ops_type = NF_HOOK_OP_BPF; // 标记为 BPF 类型
    link->hook_ops.priv = prog;                   // 存储 BPF prog

    link->hook_ops.pf = attr->link_create.netfilter.pf;
    link->hook_ops.priority = attr->link_create.netfilter.priority;
    link->hook_ops.hooknum = attr->link_create.netfilter.hooknum;

    // Step 4: 注册 hook
    err = nf_register_net_hook(net, &link->hook_ops);
}
```

### 11.2 BPF 程序执行入口

`nf_hook_run_bpf`（nf_bpf_link.c:16~24）：

```c
static unsigned int nf_hook_run_bpf(void *bpf_prog, struct sk_buff *skb,
                                    const struct nf_hook_state *s)
{
    const struct bpf_prog *prog = bpf_prog;
    struct bpf_nf_ctx ctx = {
        .state = s,
        .skb = skb,
    };
    return bpf_prog_run_pin_on_cpu(prog, &ctx);
}
```

BPF 程序接收 `struct bpf_nf_ctx`（包含 `skb` 和 `nf_hook_state`），可以读取但不能直接修改 skb 数据（`is_valid_access` 只允许 `BPF_READ` 类型访问）。

### 11.3 defrag 钩子联动

当附加 BPF link 时指定了 `BPF_F_NETFILTER_IP_DEFRAG` 标志，内核会自动启用对应的 defrag hook（`nf_defrag_v4_hook` 或 `nf_defrag_v6_hook`），确保 BPF 程序收到重组后的完整数据包。`get_proto_defrag_hook` 函数（nf_bpf_link.c:34~74）通过 `request_module()` 动态加载 `nf_defrag_ipv4` / `nf_defrag_ipv6` 模块。

### 11.4 nfnl_hookDump — 用户空间查询接口

`nfnetlink_hook.c` 提供了通过 netlink 查询当前系统注册的 hook 的接口（`NFNL_SUBSYS_HOOK`）。`nfnl_hook_dump_one`（第 195~262 行）以可读格式输出每个 hook 的函数符号名、模块名、优先级和类型信息。这使得用户空间工具（如 `ss`、`ip` 命令的扩展）可以枚举系统中的 netfilter hook。

## 12. dummy_ops 与 __nf_hook_entries_try_shrink — 注销的安全机制

### 12.1 dummy_ops 的设计

当一个 hook 被注销时，它被替换为 `dummy_ops`（core.c:91~93）：

```c
static const struct nf_hook_ops dummy_ops = {
    .hook = accept_all,
    .priority = INT_MIN,
};
```

`accept_all` 函数（第 84~88）直接返回 `NF_ACCEPT`：

```c
static unsigned int accept_all(void *priv, struct sk_buff *skb,
                               const struct nf_hook_state *state)
{
    return NF_ACCEPT;
}
```

这样设计的原因：如果 hook 正在被 `nf_hook_slow` 遍历过程中注销，直接从数组中移除会导致后续 hook 索引错位，且并发读取可能出现问题。替换为 `accept_all` 后，正在执行该位置的代码仍然可以正常继续，只是相当于跳过了一个"总是 ACCEPT"的 hook。

### 12.2 try_shrink — 延迟收缩

`__nf_hook_entries_try_shrink`（core.c:227~253）统计 dummy hook 数量，若全部已移除则分配新数组（跳过所有 dummy），否则返回 NULL（不做收缩）。通过 RCU 机制，原数组会在宽限期后被 `kvfree` 释放。

## 13. static_key — 编译期优化

```c
#ifdef CONFIG_JUMP_LABEL
struct static_key nf_hooks_needed[NFPROTO_NUMPROTO][NF_MAX_HOOKS];
#endif
```

当某个 `pf/hooknum` 组合没有任何 hook 注册时，对应的 `static_key` 为 false，内联函数 `nf_hook` 中的 `static_key_false()` 检查会直接在编译期跳过整个 hook 调用逻辑，无需进入 `nf_hook_slow` 再判断。这是 Linux 内核中经典的"条件分支消除"优化。

## 14. 整体数据流图

```
数据包进入协议栈
    │
    ▼
nf_hook(pf, hook, ...)  [include/linux/netfilter.h]
    │
    ├─ static_key_false(nf_hooks_needed[pf][hook]) → 跳过，直接返回 1（okfn）
    │
    ▼
rcu_read_lock()
    获取 hook_head = net->nf.hooks_ipv4[hook] 或 dev->nf_hooks_ingress
    │
    ▼
nf_hook_slow(skb, &state, hook_head, 0)
    │
    ├─ for (s = 0; s < num_hook_entries; s++)
    │       verdict = hook_entry[s].hook(hook_entry[s].priv, skb, &state)
    │       switch (verdict & NF_VERDICT_MASK):
    │           NF_ACCEPT  → 继续循环
    │           NF_DROP     → kfree_skb, return -EPERM
    │           NF_QUEUE   → nf_queue(...), maybe continue
    │           NF_STOLEN   → return (deprecated)
    │
    └─ return 1  → 调用 okfn() 继续协议栈处理
```

## 15. 关键要点总结

| 主题 | 关键点 |
|------|--------|
| **存储结构** | `nf_hook_entries` = `hooks[]` + `orig_ops[]`（尾部指针），避免数据包路径额外访问 |
| **注册算法** | `nf_hook_entries_grow` 按 priority 升序插入，支持 dummy hook 惰性删除 |
| **注销算法** | 替换为 `dummy_ops`（accept_all）+ RCU 延迟释放 + `__nf_hook_entries_try_shrink` |
| **Ingress** | `dev->nf_hooks_ingress`，设备级别，可通过 `NFPROTO_INET`（统一）或 `NFPROTO_NETDEV` 访问 |
| **Egress** | `dev->nf_hooks_egress`，默认关闭（`CONFIG_NETFILTER_EGRESS`） |
| **NFPROTO_INET** | 自动同时注册到 IPv4 和 IPv6，简化跨协议族工具 |
| **Verdict 编码** | 低 8 位类型，高位可编码队列号（NF_QUEUE）或错误码（NF_DROP） |
| **BPF 扩展** | `NF_HOOK_OP_BPF` 类型，通过 `bpf_nf_link` 附加，支持 defrag 联动 |
| **static_key** | 零 hook 注册时完全跳过数据包路径，无条件分支开销 |


---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `include/linux/list.h` | 51 | 0 | 51 | 0 |
| `include/linux/sched.h` | 567 | 70 | 134 | 7 |
| `include/linux/mm.h` | 793 | 24 | 527 | 18 |

### 核心数据结构

- **audit_context** `sched.h:58`
- **bio_list** `sched.h:59`
- **blk_plug** `sched.h:60`
- **bpf_local_storage** `sched.h:61`
- **bpf_run_ctx** `sched.h:62`
- **bpf_net_context** `sched.h:63`
- **capture_control** `sched.h:64`
- **cfs_rq** `sched.h:65`
- **fs_struct** `sched.h:66`
- **futex_pi_state** `sched.h:67`
- **io_context** `sched.h:68`
- **io_uring_task** `sched.h:69`
- **mempolicy** `sched.h:70`
- **nameidata** `sched.h:71`
- **nsproxy** `sched.h:72`
- **perf_event_context** `sched.h:73`
- **perf_ctx_data** `sched.h:74`
- **pid_namespace** `sched.h:75`
- **pipe_inode_info** `sched.h:76`
- **rcu_node** `sched.h:77`
- **reclaim_state** `sched.h:78`
- **robust_list_head** `sched.h:79`
- **root_domain** `sched.h:80`
- **rq** `sched.h:81`
- **sched_attr** `sched.h:82`

### 关键函数

- **INIT_LIST_HEAD** `list.h:43`
- **__list_add_valid** `list.h:136`
- **__list_del_entry_valid** `list.h:142`
- **__list_add** `list.h:154`
- **list_add** `list.h:175`
- **list_add_tail** `list.h:189`
- **__list_del** `list.h:201`
- **__list_del_clearprev** `list.h:215`
- **__list_del_entry** `list.h:221`
- **list_del** `list.h:235`
- **list_replace** `list.h:249`
- **list_replace_init** `list.h:265`
- **list_swap** `list.h:277`
- **list_del_init** `list.h:293`
- **list_move** `list.h:304`
- **list_move_tail** `list.h:315`
- **list_bulk_move_tail** `list.h:331`
- **list_is_first** `list.h:350`
- **list_is_last** `list.h:360`
- **list_is_head** `list.h:370`
- **list_empty** `list.h:379`
- **list_del_init_careful** `list.h:395`
- **list_empty_careful** `list.h:415`
- **list_rotate_left** `list.h:425`
- **list_rotate_to_front** `list.h:442`
- **list_is_singular** `list.h:457`
- **__list_cut_position** `list.h:462`
- **list_cut_position** `list.h:488`
- **list_cut_before** `list.h:515`
- **__list_splice** `list.h:531`
- **list_splice** `list.h:550`
- **list_splice_tail** `list.h:562`
- **list_splice_init** `list.h:576`
- **list_splice_tail_init** `list.h:593`
- **list_count_nodes** `list.h:755`

### 全局变量

- **__tracepoint_sched_set_state_tp** `sched.h:350`
- **__tracepoint_sched_set_need_resched_tp** `sched.h:352`
- **def_root_domain** `sched.h:407`
- **sched_domains_mutex** `sched.h:408`
- **cad_pid** `sched.h:1749`
- **init_stack** `sched.h:1964`
- **class_migrate_is_conditional** `sched.h:2519`
- **_totalram_pages** `mm.h:53`
- **high_memory** `mm.h:74`
- **sysctl_legacy_va_layout** `mm.h:86`
- **mmap_rnd_bits_min** `mm.h:92`
- **mmap_rnd_bits_max** `mm.h:93`
- **mmap_rnd_bits** `mm.h:94`
- **sysctl_user_reserve_kbytes** `mm.h:210`
- **sysctl_admin_reserve_kbytes** `mm.h:211`

### 成员/枚举

- **utime** `sched.h:366`
- **stime** `sched.h:367`
- **lock** `sched.h:368`
- **seqcount** `sched.h:386`
- **starttime** `sched.h:387`
- **state** `sched.h:388`
- **cpu** `sched.h:389`
- **utime** `sched.h:390`
- **stime** `sched.h:391`
- **gtime** `sched.h:392`
- **sched_priority** `sched.h:413`
- **pcount** `sched.h:421`
- **run_delay** `sched.h:424`
- **max_run_delay** `sched.h:427`
- **min_run_delay** `sched.h:430`
- **last_arrival** `sched.h:435`
- **last_queued** `sched.h:438`
- **max_run_delay_ts** `sched.h:441`
- **weight** `sched.h:461`
- **inv_weight** `sched.h:462`

