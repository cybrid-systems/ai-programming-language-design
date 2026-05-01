# neigh_lookup — Neighbour 子系统分析

## 1. 概述

Neighbour 子系统是 Linux 网络栈中维护 **IP 地址 → MAC 地址** 映射的核心组件，典型场景是 ARP（IPv4）和 NDP（IPv6）的地址解析。它通过一个 hash 表存储 `struct neighbour` 条目，并借助 NUD（Neighbour Unreachability Detection）状态机实现自动探测和 GC 清理。

源码关键文件：
- `/home/dev/code/linux/include/net/neighbour.h` — 核心数据结构定义
- `/home/dev/code/linux/net/core/neighbour.c` — 实现（3968 行）
- `/home/dev/code/linux/net/ipv4/arp.c` — ARP 协议实现
- `/home/dev/code/linux/include/uapi/linux/neighbour.h` — NUD 状态常量（用户空间可见）

---

## 2. 核心数据结构

### 2.1 `struct neighbour`（neighbour.h:130~155）

```c
struct neighbour {
    struct hlist_node    hash;          // 挂入主 hash 表的节点
    struct hlist_node   dev_list;      // 挂入 device 链表的节点
    struct neigh_table *tbl;           // 所属 neighbour table
    struct neigh_parms  *parms;         // 可调参数（超时、探测次数等）

    unsigned long       confirmed;     // 最近确认可达的时间戳（jiffies）
    unsigned long       updated;        // 最近一次更新的时间戳

    rwlock_t            lock;           // 保护 neighbour 条目本身
    refcount_t          refcnt;         // 引用计数

    unsigned int        arp_queue_len_bytes;
    struct sk_buff_head arp_queue;      // 待发送的排队报文（未解析时）

    struct timer_list   timer;          // 定时探测 timer

    unsigned long       used;           // 最近一次被使用的时间
    atomic_t            probes;         // 已发出探测计数

    u8                  nud_state;     // ★ NUD 状态
    u8                  type;           // 地址类型（MULTICAST/UNICAST/...）
    u8                  dead;          // 条目已标记删除
    u8                  protocol;      // 协议（AF_INET/AF_INET6）
    u32                 flags;         // NTF_* 标志

    seqlock_t           ha_lock;
    unsigned char       ha[ALIGN(MAX_ADDR_LEN, sizeof(unsigned long))] __aligned(8);
    struct hh_cache     hh;             // 硬件 header 缓存（用于快速封装）

    int                 (*output)(struct neighbour *, struct sk_buff *);
    const struct neigh_ops *ops;        // 操作函数集（solicit/error_report/output）

    struct list_head    gc_list;        // 串起 GC 待清理链表
    struct list_head    managed_list;   // 串起 managed 链表
    struct rcu_head     rcu;

    struct net_device  *dev;
    netdevice_tracker   dev_tracker;
    u8                  primary_key[];  // ★ 协议地址（变长，flexible array）
};
```

关键字段说明：

| 字段 | 用途 |
|------|------|
| `nud_state` | NUD 状态机状态，决定条目是否可用、如何探测 |
| `primary_key[]` | 协议地址，IPv4 为 4 字节，IPv6 为 16 字节，flexible array 放在结构体末尾 |
| `hh` | `struct hh_cache`，缓存 L2 header 模板，避免每次发包都重新 ARP 解析 |
| `arp_queue` | 地址尚不可用时，排队的 IP 报文；解析完成后逐个发送 |
| `confirmed` | 收到肯定性确认（ARP reply）后更新的时间戳，驱动 REACHABLE 超时 |
| `probes` | 已发出 unicast ARP probe 的次数，达到上限后进入 FAILED |

### 2.2 `struct neigh_table`（neighbour.h:193~237）

每个协议族维护一个 `neigh_table`（如 `arp_tbl`），管理一条 hash 桶链和一个 proxy hash 表：

```c
struct neigh_table {
    int              family;         // AF_INET / AF_INET6
    unsigned int     entry_size;     // neighbour 结构体大小（含 private data）
    unsigned int     key_len;        // primary_key 长度（IPv4=4, IPv6=16）
    __be16           protocol;       // ETH_P_IP / ETH_P_IPV6

    __u32            (*hash)(...);   // hash 函数
    bool             (*key_eq)(...); // key 比较函数
    int              (*constructor)(struct neighbour *);  // 协议构造器（如 arp_constructor）

    int              (*pconstructor)(struct pneigh_entry *);
    void             (*pdestructor)(struct pneigh_entry *);
    void             (*proxy_redo)(struct sk_buff *); // proxy ARP 回调

    char            *id;             // "arp_cache" / "nd_cache"

    struct neigh_parms parms;        // 默认参数
    struct list_head  parms_list;

    int               gc_interval;   // GC 周期（30s for arp_tbl）
    int               gc_thresh1, gc_thresh2, gc_thresh3; // GC 阈值
    unsigned long     last_flush;

    struct delayed_work gc_work;     // 周期 GC workqueue
    struct delayed_work managed_work;

    atomic_t          entries;       // 总条目数
    atomic_t          gc_entries;    // 参与 GC 的条目数
    struct list_head  gc_list;       // 待 GC 的 neighbour 链表

    struct neigh_hash_table __rcu *nht;  // ★ 主 hash 表（RCU 保护）
    struct mutex      phash_lock;
    struct pneigh_entry __rcu **phash_buckets; // ★ proxy hash 表
};
```

---

## 3. NUD 状态机

NUD（Neighbour Unreachability Detection）定义在 `include/uapi/linux/neighbour.h:63~73`：

```c
#define NUD_INCOMPLETE  0x01   // 正在解析中（已发出 ARP request）
#define NUD_REACHABLE   0x02   // 最近收到过可达确认（jiffies 在 reachable_time 内）
#define NUD_STALE       0x04   // 超时了但还能用，触发延迟探测
#define NUD_DELAY       0x08   // STALE 后等待 DELAY_PROBE_TIME 再发探测
#define NUD_PROBE       0x10   // 正在主动探测（已发 ARP request，等待 reply）
#define NUD_FAILED      0x20   // 解析彻底失败，报文丢弃
#define NUD_NOARP       0x40   // 不需要 ARP 解析（如 point-to-point）
#define NUD_PERMANENT   0x80   // 永久有效，GC 永不删除
#define NUD_NONE        0x00   // 初始状态
```

复合标志（neighbour.h:38~40）：

```c
#define NUD_IN_TIMER   (NUD_INCOMPLETE | NUD_REACHABLE | NUD_DELAY | NUD_PROBE)
#define NUD_VALID     (NUD_PERMANENT | NUD_NOARP | NUD_REACHABLE | NUD_PROBE | NUD_STALE | NUD_DELAY)
#define NUD_CONNECTED (NUD_PERMANENT | NUD_NOARP | NUD_REACHABLE)
```

### 3.1 状态转换图

```
                    ┌────────────────────────────────────────────────────┐
                    │            定时器到期 (neigh_timer_handler)         │
                    └─────────── NEIGH_VAR(reachable_time) ─────────────┘
 创建/查询时          │
 NUD_NONE ──► NUD_INCOMPLETE ──► (收到 ARP Reply) ──► NUD_REACHABLE
   ▲                  │                                      │
   │                  │ 超时+used超时                         │ confirmed+
   │                  ▼                                      │ reachable_time
   │               NUD_PROBE ──► (probes >= max) ──► NUD_FAILED
   │                  │                                      │
   │                  │ probes不足                            │ 超时
   │                  └──────────────────────────────────────┘
   │                                                            ▼
   │                                                       NUD_STALE ◄──┐
   │                  ▲                                           │       │
   │                  │ 收到 ARP Reply                           │ 定时器 │
   │                  │（ARP主动更新）                          │ 到期   │
   │                  └───────────────────────────────────────────┘       │
   │                                                              NUD_DELAY
   │                                                                    │
   │                                          定时器到期 ──► NUD_PROBE ──┘
   │                                                                    │
   └──────────────────── neigh_update(new=NUD_NONE/NUD_FAILED) ──────────┘
```

### 3.2 状态迁移语义

| 起点状态 | 事件 | 目标状态 | 行为 |
|---------|------|---------|------|
| NUD_NONE | `__neigh_event_send` | NUD_INCOMPLETE | 启动 ARP 解析，入队报文，启动 timer |
| NUD_INCOMPLETE | 收到 ARP Reply | NUD_REACHABLE | 安装 MAC 地址，发送排队报文 |
| NUD_INCOMPLETE | probes 超限 | NUD_FAILED | 丢弃 arp_queue 报文，invalidate |
| NUD_REACHABLE | reachable_time 超时 | NUD_STALE | 更新 used，进入 STALE |
| NUD_STALE | DELAY_PROBE_TIME 到期 | NUD_DELAY | 等待一段时间再探测 |
| NUD_DELAY | 等待超时 | NUD_PROBE | 发出 ARP probe |
| NUD_PROBE | 收到 Reply | NUD_REACHABLE | 重置 confirmed |
| NUD_PROBE | probes 超限 | NUD_FAILED | 标记 invalid，丢弃报文 |

---

## 4. 查找流程：`neigh_lookup` → `__neigh_lookup_noref`

### 4.1 `neigh_lookup`（neighbour.c:625~641）

```c
struct neighbour *neigh_lookup(struct neigh_table *tbl, const void *pkey,
                              struct net_device *dev)
{
    struct neighbour *n;

    NEIGH_CACHE_STAT_INC(tbl, lookups);

    rcu_read_lock();
    n = __neigh_lookup_noref(tbl, pkey, dev);   // 不加引用计数的查找
    if (n) {
        if (!refcount_inc_not_zero(&n->refcnt)) // 增加引用计数，失败则放弃
            n = NULL;
        NEIGH_CACHE_STAT_INC(tbl, hits);
    }

    rcu_read_unlock();
    return n;
}
```

**关键点**：查找在 RCU 读锁下进行；使用 `refcount_inc_not_zero` 安全地增加引用计数，如果此时条目正在被删除（refcnt 已到 0）则放弃返回 NULL。

### 4.2 `__neigh_lookup_noref`（neighbour.h:299~313，内联函数）

```c
static inline struct neighbour *__neigh_lookup_noref(struct neigh_table *tbl,
                                                     const void *pkey,
                                                     struct net_device *dev)
{
    return ___neigh_lookup_noref(tbl, tbl->key_eq, tbl->hash, pkey, dev);
}

static inline struct neighbour *___neigh_lookup_noref(
    struct neigh_table *tbl,
    bool (*key_eq)(const struct neighbour *n, const void *pkey),
    __u32 (*hash)(const void *pkey, const struct net_device *dev, __u32 *hash_rnd),
    const void *pkey,
    struct net_device *dev)
{
    struct neigh_hash_table *nht = rcu_dereference(tbl->nht);
    struct neighbour *n;
    u32 hash_val;

    hash_val = hash(pkey, dev, nht->hash_rnd) >> (32 - nht->hash_shift);
    neigh_for_each_in_bucket_rcu(n, &nht->hash_heads[hash_val])
        if (n->dev == dev && key_eq(n, pkey))
            return n;

    return NULL;
}
```

**关键点**：
1. `hash_shift` 表示桶数为 `2^hash_shift`，`hash_val` 高位取 hash_shift 位作为桶索引
2. `neigh_for_each_in_bucket_rcu` 是 `hlist_for_each_entry_rcu` 宏，RCU 遍历链表
3. 在一个桶内遍历直到 `dev == dev && key_eq(n, pkey)` 匹配
4. 不取引用计数 —— 调用方自行 `neigh_hold` / `neigh_release`

---

## 5. 创建流程：`neigh_create` → `___neigh_create`

### 5.1 `__neigh_create`（neighbour.c:738~745）

```c
struct neighbour *__neigh_create(struct neigh_table *tbl, const void *pkey,
                                 struct net_device *dev, bool want_ref)
{
    bool exempt_from_gc = !!(dev->flags & IFF_LOOPBACK);
    return ___neigh_create(tbl, pkey, dev, 0, exempt_from_gc, want_ref);
}
```

`___neigh_create`（neighbour.c:646~736）是核心：

```
1. neigh_alloc()            分配 neighbour + private data 空间
2. memcpy(n->primary_key, pkey, key_len)    填入协议地址
3. netdev_hold(dev, &n->dev_tracker)        持有 device 引用
4. tbl->constructor(n)      调用协议构造器（arp_constructor 填 ha）
5. dev->netdev_ops->ndo_neigh_construct()   设备专用初始化
6. n->parms->neigh_setup()  可选自定义初始化
7. confirmed = jiffies - (BASE_REACHABLE_TIME << 1)  设为"很久以前"
8. 检查 entries 是否超阈值，如是则 neigh_hash_grow()
9. 遍历目标桶，检查是否已有重复条目
   → 有则返回现有条目（want_ref 时 hold 一份）
10. 挂入 gc_list / managed_list（若非 exempt_from_gc）
11. hlist_add_head_rcu(&n->hash, &bucket)   插入主 hash 表
12. hlist_add_head_rcu(&n->dev_list, ...)  插入 device 链表
```

**关键点**：
- **duplicate detection**：在持有 `tbl->lock` 期间遍历目标桶，若发现 key 已存在，直接返回现有条目（不加新的）。这是 `neigh_lookup + create` 竞态的安全处理方式（"lookup-create then check" pattern）。
- `exempt_from_gc`：loopback 设备创建的条目不参与 GC。
- `want_ref`：调用方是否需要引用计数。

### 5.2 `neigh_alloc`（neighbour.c:496~534）

```c
static struct neighbour *neigh_alloc(struct neigh_table *tbl,
                                      struct net_device *dev,
                                      u32 flags, bool exempt_from_gc)
{
    struct neighbour *n;
    n = kzalloc(tbl->entry_size, GFP_ATOMIC);  // 含 private data
    timer_setup(&n->timer, neigh_timer_handler, 0);
    skb_queue_head_init(&n->arp_queue);
    refcount_set(&n->refcnt, 1);       // 初始 refcnt=1，分配者负责释放
    ...
}
```

---

## 6. Proxy Neighbour：`pneigh_lookup` 与 `pneigh_create`

Proxy ARP 场景下，不通过主 hash 表存储，而是用 `phash_buckets`：

### 6.1 `pneigh_lookup`（neighbour.c:757~776）

```c
struct pneigh_entry *pneigh_lookup(struct neigh_table *tbl,
                                   struct net *net, const void *pkey,
                                   struct net_device *dev)
{
    struct pneigh_entry *n;
    unsigned int key_len;
    u32 hash_val;

    key_len = tbl->key_len;
    hash_val = pneigh_hash(pkey, key_len);
    n = rcu_dereference_check(tbl->phash_buckets[hash_val],
                              lockdep_is_held(&tbl->phash_lock));

    while (n) {
        if (!memcmp(n->key, pkey, key_len) &&
            net_eq(pneigh_net(n), net) &&
            (n->dev == dev || !n->dev))
            return n;
        n = rcu_dereference_check(n->next, ...);
    }
    return NULL;
}
```

**与主 hash 表的区别**：
- 用 `tbl->phash_lock`（mutex）而非 RCU
- 支持 `dev == NULL` 的通配匹配（"任何设备都代理"）
- `pneigh_entry` 比 `neighbour` 轻量得多，不做状态机

### 6.2 `pneigh_create`（neighbour.c:782~836）

```c
int pneigh_create(struct neigh_table *tbl, struct net *net,
                  const void *pkey, struct net_device *dev,
                  u32 flags, u8 protocol, bool permanent)
{
    // mutex_lock(&tbl->phash_lock)
    // pneigh_lookup() 如存在直接返回
    // kzalloc(sizeof(*n) + key_len) 分配
    // 写入 key / net / dev / flags / protocol / permanent
    // 插入 phash_buckets[hash_val] 链表头
    // mutex_unlock
}
```

---

## 7. 定时器与 GC：`neigh_timer_handler`

### 7.1 `neigh_timer_handler`（neighbour.c:1103~1197）

定时器到期时根据当前 NUD 状态决定行为：

```
当前 NUD_REACHABLE：
  ├─ now <= confirmed + reachable_time  → 还在有效期，继续保持 REACHABLE
  ├─ now <= used + DELAY_PROBE_TIME      → 转为 NUD_DELAY（等待探测）
  └─ 否则                               → 转为 NUD_STALE，通知用户空间

当前 NUD_DELAY：
  ├─ now <= confirmed + DELAY_PROBE_TIME → 转为 NUD_REACHABLE（收到过确认）
  └─ 否则                               → 转为 NUD_PROBE，开始主动探测

当前 NUD_PROBE / NUD_INCOMPLETE：
  → 定时重设 next = max(RETRANS_TIME, HZ/100)
  → 启动探测 (neigh_probe)

 probes >= max_probes：
  ├─ NUD_PROBE + NTF_EXT_VALIDATED → NUD_STALE（扩展学习条目不轻易失败）
  └─ 其他                            → NUD_FAILED + neigh_invalidate
```

**关键设计**：
- `reachable_time` 是随机化的（`neigh_rand_reach_time`），避免多节点同时超时
- 每个 timer 操作都调用 `neigh_hold` / `neigh_release` 防止在 timer 执行期间条目被释放
- `NUD_IN_TIMER` 标志（`NUD_INCOMPLETE|REACHABLE|DELAY|PROBE`）标识条目正持有 timer

### 7.2 周期 GC：`neigh_periodic_work`（neighbour.c:976~1025）

```
neigh_table_init() 时启动：
  schedule_delayed_work(&tbl->gc_work, tbl->gc_interval)  // 30s for arp_tbl

每次触发：
  1. entries < gc_thresh1 → 直接返回（条目少，不GC）
  2. 遍历所有 hash 桶：
     - NUD_PERMANENT | NUD_IN_TIMER | NTF_EXT_LEARNED → 跳过（保护永久/活跃条目）
     - refcnt == 1 + (NUD_FAILED | NUD_NOARP | multicast | stale) → 可删除
     - 删除：hlist_del_rcu() + neigh_release()
  3. 删除超过 gc_thresh2 时停止（避免单次删除太多）
```

### 7.3 强制 GC：`neigh_forced_gc`（neighbour.c:253~296）

当 entries 超过 `gc_thresh3` 时，调用 `neigh_forced_gc()`，强制清理直到 entries 回落到 `gc_thresh2` 以下。条件比周期 GC 更严格：`refcnt == 1` 且条目"足够旧"（updated 超过 5s）。

---

## 8. 状态更新：`neigh_update` → `__neigh_update`

### 8.1 `neigh_update`（neighbour.c:1374 入口）

```c
static int __neigh_update(struct neighbour *neigh, const u8 *lladdr,
                          u8 new, u32 flags, u32 nlmsg_pid,
                          struct netlink_ext_ack *extack)
```

核心流程（简化）：

```
1. 写锁 neigh->lock
2. dead → 拒绝更新（NEIGH_UPDATE_F_ADMIN 除外）
3. old 是 NUD_NOARP/NUD_PERMANENT → 拒绝非 admin 更新
4. 更新 flags（NTF_MANAGED / NTF_EXT_LEARNED 等）
5. flags 含 USE/MANAGED → 清除 PERMANENT，直接写 nud_state 返回

6. new 无 NUD_VALID 标志（如 NUD_NONE）：
   - del_timer()
   - 若 old 是 NUD_CONNECTED → neigh_suspect()（推测不可达）
   - 写 nud_state = new
   - old & INCOMPLETE|PROBE 且 new & FAILED → neigh_invalidate()
   - 返回

7. lladdr 处理（三路）：
   - dev->addr_len == 0 → 无需地址（device 自行处理）
   - lladdr != NULL → 使用传入地址，但若 old NUD_VALID 且地址相同则用旧地址
   - lladdr == NULL 但 old 无 NUD_VALID → 报错返回

8. new & NUD_CONNECTED → 更新 confirmed = jiffies（收到过确认）

9. old NUD_VALID + lladdr 变化 + 无 OVERRIDE 标志 → 拒绝更新（地址冲突）

10. nud_state / ha / HH cache 更新：
    - del_timer()
    - new & NUD_PROBE → atomic_set(probes, 0)
    - new & NUD_IN_TIMER → add_timer(REACHABLE? reachable_time : 0)
    - WRITE_ONCE(nud_state, new)
    - memcpy(ha, lladdr, dev->addr_len)
    - neigh_update_hhs() → 更新 hh_cache 中的 header 模板
    - 更新 confirmed（若 lladdr 变化且非 NUD_CONNECTED）
```

### 8.2 `__neigh_update` 中的 HH cache 更新（neighbour.c:1293~1312）

```c
static void neigh_update_hhs(struct neighbour *neigh)
{
    if (neigh->dev->header_ops->cache_update)
        neigh->dev->header_ops->cache_update(&neigh->hh, neigh->dev, neigh->ha);
}
```

每次 MAC 地址更新后，调用 device 的 `header_ops->cache_update` 更新 L2 header 模板缓存。这样后续发往同一邻接点的报文可以直接用 `hh_cache` 构造 Ethernet header，不经过 ARP 解析。

---

## 9. ARP 输入处理：`arp_process`

### 9.1 `arp_process`（arp.c:702~955）

```
1. 检查 device 是否支持 ARP（dev->flags & IFF_NOARP）
2. 验证 arp->ar_hrd / arp->ar_pro / arp->ar_op
3. 提取 sha（sender MAC）、sip（sender IP）、tha（target MAC）、tip（target IP）
4. 丢弃 multicast/broadcast/loopback tip
5. 丢弃 gratuitous ARP（sip == tip 且 DROP_GRATUITOUS_ARP 配置）
6. 若 sip == 0（ARP 检测地址冲突）：发 ARP reply 后丢弃
7. 若是指向本机的 ARP Request（RTN_LOCAL）：
   - 发 ARP Reply（arp_send_dst）
   - 用 sha/sip 创建/更新 neighbour 条目
8. 若路由查找到本地（RTN_LOCAL + arp_ignore 通过）：
   - 调用 neigh_event_ns() → neigh_lookup/crearte → __neigh_event_send
9. 若是代理 ARP 场景（pneigh_lookup 命中）：
   - pneigh_enqueue() 将 ARP reply 排入 proxy_queue 供后续发送
10. 其他情况：更新 neighbour 条目状态（__neigh_lookup with !confirm）
```

### 9.2 `arp_tbl` 全局 ARP 表（arp.c:152~185）

```c
struct neigh_table arp_tbl = {
    .family       = AF_INET,
    .key_len      = 4,
    .protocol     = cpu_to_be16(ETH_P_IP),
    .hash         = arp_hash,
    .key_eq       = arp_key_eq,
    .constructor  = arp_constructor,
    .proxy_redo   = parp_redo,
    .is_multicast = arp_is_multicast,
    .id           = "arp_cache",
    .parms = {
        .reachable_time    = 30 * HZ,
        .gc_interval       = 30 * HZ,
        .gc_thresh1        = 128,
        .gc_thresh2        = 512,
        .gc_thresh3        = 1024,
        // ...
    },
};
```

---

## 10. 总结：关键设计要点

1. **三层 hash**：主 hash 表（`nht`）+ proxy hash 表（`phash_buckets`）+ device 链表（`dev_list`），分别覆盖不同查询路径。
2. **RCU 保护查找**：主 hash 表遍历在 RCU 读锁下进行，写操作通过 `tbl->lock` + `hlist_add/del_rcu` 完成。
3. **引用计数安全**：`refcount_t` 防止 timer 或其他路径在持有引用时被释放；`refcount_inc_not_zero` 避免对已死条目的操作。
4. **灵活的状态机**：NUD 状态覆盖了从"未知"到"永久"的完整生命周期，STALE/REACHABLE 机制避免不必要的 ARP 流量。
5. **延迟队列**：NUD_INCOMPLETE 期间 IP 报文入 `arp_queue`，解析完成后逐个发送（`neigh_update_process_arp_queue`）。
6. **HH cache 加速**：每次 MAC 地址确认后更新 `hh_cache`，使能直接发送的报文绕过 ARP 解析。
7. **GC 分层阈值**：`gc_thresh1/2/3` 三档，thresh1 以下不 GC，thresh3 以上触发强制 GC，兼顾内存压力和网络性能。
