# 21 — Cluster：Redis 的分片与去中心化

> Redis 主线源码深度分析系列 · 第二十一篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Redis Cluster 是 Redis 的**去中心化分片方案**，不是传统的 master-replica 模式加代理（如 Codis/Twemproxy），而是每个节点都参与路由、故障检测、数据迁移。

三个核心机制：

| 机制 | 描述 |
|------|------|
| **Slot 分片** | 16384 个 slot 按范围分配到各 master 节点，key 的 hash 决定 slot |
| **Gossip 协议** | 节点间通过 PING/PONG 交换 gossip 信息，去中心化故障检测 |
| **Failover** | Master 宕机后，slave 通过 Raft 风格的选举成为新 master |

**doom-lsp 确认**：核心文件

| 文件 | 行数 | doom-lsp 符号数 |
|------|:----:|:-------------:|
| `src/cluster.c` | 7125 | 208+ |
| `src/cluster.h` | ~400 | clusterNode / clusterState / clusterMsg |

关键符号：

```
struct clusterNode @cluster.h:115   // 节点信息（slots bitmap, flags, link, ...）
struct clusterState @cluster.h:170  // 集群全局状态（slots[16384], 迁移映射, ...）
struct clusterMsg @cluster.h:342    // 线协议消息头（固定偏移 static_assert）
struct clusterMsgDataGossip @247    // gossip 条目

fn clusterCron @4032                // ★ 后台维护：gossip + 故障检测 + 投票
fn clusterSendPing @2925            // ★ 发送 PING（带 gossip + 扩展数据）
fn clusterProcessPacket @—          // ★ 处理收到的 cluster bus 消息
fn clusterHandleSlaveFailover @3575 // ★ Slave 选举逻辑
fn clusterUpdateState @4429         // ★ 更新集群状态（OK/FAIL）
fn clusterBeforeSleep @4246         // beforesleep 中的集群维护
fn clusterRedirectClientOrReply @—  // MOVED/ASK 重定向
fn clusterNodeSetSlotBit @4326      // 设置 slot bitmap
fn migrateCommand @—                 // SLOT MIGRATE 命令
```

---

## 1. 数据分片——16384 个 Slot

### 1.1 Slot 分配

Redis Cluster 将 key 空间划分为 **16384 个 slot**（`cluster.h:8`）。

```c
// cluster.h:8 — doom-lsp 确认
#define CLUSTER_SLOTS 16384
```

每个 key 所属的 slot 由 hash 函数决定：

```c
// cluster.c — slot 计算
unsigned int keyHashSlot(char *key, int keylen) {
    // 只对 key 中 {...} 花括号内的部分做 hash（用于 hash tag）
    int s, e;
    for (s = 0; s < keylen; s++)
        if (key[s] == '{') break;
    if (s == keylen) return crc16(key, keylen) & 16383;  // 无 { → 全 key hash

    for (e = s+1; e < keylen; e++)
        if (key[e] == '}') break;
    if (e >= keylen || e == s+1) return crc16(key, keylen) & 16383;

    return crc16(key+s+1, e-s-1) & 16383;  // ★ 只 hash {tag} 内部
}
```

**Hash Tag**：`{user:1000}.age` 和 `{user:1000}.name` 落在同一个 slot，因为它们的花括号内内容 `user:1000` 相同。这实现了 multi-key 操作（MGET、MSET、事务）。

### 1.2 clusterNode——Slot 位图

```c
// cluster.h:115 — doom-lsp 确认
typedef struct clusterNode {
    char name[CLUSTER_NAMELEN];     // 40 字符十六进制 ID
    int flags;                      // CLUSTER_NODE_MASTER / SLAVE / FAIL / PFAIL
    uint64_t configEpoch;           // 配置纪元（选主用）
    unsigned char slots[CLUSTER_SLOTS/8]; // ★ 2048 字节的 slot 位图
    int numslots;                   // 分配的 slot 数量
    int numslaves;                  // 从节点数量
    struct clusterNode **slaves;    // 从节点指针数组
    struct clusterNode *slaveof;    // 指向主节点
    clusterLink *link;              // 集群总线连接
    char ip[NET_IP_STR_LEN];
    int port, cport;                // 客户端端口、集群总线端口
    list *fail_reports;             // 故障报告列表
} clusterNode;
```

`slots[2048]` 位图：每个 bit 对应一个 slot。bit=1 表示该 slot 由此节点负责。

### 1.3 clusterState——全局路由表

```c
// cluster.h:170 — doom-lsp 确认
typedef struct clusterState {
    clusterNode *myself;                      // 本节点
    uint64_t currentEpoch;                    // 当前纪元
    int state;                                // CLUSTER_OK / FAIL
    int size;                                 // 持有 slot 的 master 数
    dict *nodes;                              // 所有节点（name → clusterNode）

    clusterNode *migrating_slots_to[16384];   // ★ 迁出中的 slot
    clusterNode *importing_slots_from[16384]; // ★ 迁入中的 slot
    clusterNode *slots[16384];                // ★ slot → 负责节点映射

    int failover_auth_count;                  // 当前选举收到的票数
    uint64_t failover_auth_epoch;             // 选举纪元
    mstime_t failover_auth_time;              // 选举超时
    int mf_can_start;                         // 手动 failover 标志
} clusterState;
```

**`slots[16384]`**——集群路由的核心。每次 key 操作前，Redis 通过 `c->slot = keyHashSlot(key)` 计算 slot，然后 `server.cluster->slots[slot]` 查到负责节点。如果不是本节点返回 **MOVED 重定向**。

**`migrating_slots_to / importing_slots_from`**：slot 迁移期间的临时映射，用于 **ASK 重定向**。

---

## 2. Gossip 协议——节点间通信

### 2.1 集群总线

每个 Redis Cluster 节点在**客户端端口 + 10000**（可配置）上监听集群总线。节点间通过这个端口发送二进制格式的 `clusterMsg`，不是 RESP 协议。

### 2.2 clusterMsg——线协议

```c
// cluster.h:342 — doom-lsp 确认
typedef struct {
    char sig[4];            // "RCmb" (Redis Cluster message bus)
    uint32_t totlen;        // 消息总长度
    uint16_t ver;           // 协议版本（=1）
    uint16_t type;          // 消息类型
    uint16_t count;         // gossip 条目数
    uint64_t currentEpoch;  // 发送节点的纪元
    uint64_t configEpoch;   // 配置纪元
    uint64_t offset;        // 复制偏移量
    char sender[40];        // 发送节点名称
    unsigned char myslots[2048]; // 发送节点的 slot 位图
    char slaveof[40];       // 从节点所属主节点
    char myip[46];          // 发送节点 IP
    uint16_t flags;         // 节点标志
    unsigned char state;    // 集群状态
    union clusterMsgData data;
} clusterMsg;
```

消息类型：

```c
#define CLUSTERMSG_TYPE_PING               0   // 心跳
#define CLUSTERMSG_TYPE_PONG               1   // 回复
#define CLUSTERMSG_TYPE_MEET               2   // 邀请加入
#define CLUSTERMSG_TYPE_FAIL               3   // 广播故障
#define CLUSTERMSG_TYPE_PUBLISH            4   // 广播 Pub/Sub
#define CLUSTERMSG_TYPE_FAILOVER_AUTH_REQUEST 5  // 选举请求
#define CLUSTERMSG_TYPE_FAILOVER_AUTH_ACK  6   // 选举投票
#define CLUSTERMSG_TYPE_UPDATE             7   // 更新配置
#define CLUSTERMSG_TYPE_COUNT              11
```

### 2.3 clusterSendPing——发送 gossip

```c
// cluster.c:2925 — doom-lsp 确认
void clusterSendPing(clusterLink *link, int type) {
    // 1. 统计 gossip 条目数
    // 选取其他节点：按 pong_received 排序，老的优先
    // 也随机挑一些最新的节点

    // 2. 填充 clusterMsg
    // 直接发送到一个对端

    // 每个 gossip 条目包含：
    // clusterMsgDataGossip {
    //   nodename[40], ping_sent, pong_received,
    //   ip[46], port, cport, flags, pport
    // }
}
```

**Gossip 选择策略**：优先传播那些很久没收到消息的节点（最可能已故障的），也随机加入一些正常节点保证信息均衡。每次 PING 携带约 1/10 集群规模的 gossip 条目。

### 2.4 clusterCron——定期维护

```c
// cluster.c:4032 — doom-lsp 确认
void clusterCron(void) {
    // 1. ★ 为每个节点发 PING（根据上次 PONG 时间间隔）
    //    至少每 server.cluster_node_timeout/2 发一次
    //    随机选一些节点发

    // 2. ★ 故障检测
    //    如果一个节点 node_timeout 没收到 PONG，
    //    设置 CLUSTER_NODE_PFAIL（疑似故障）
    //    如果另一个节点也报告 PFAIL → 升级为 FAIL

    // 3. ★ 选举检查（slave 端）
    clusterHandleSlaveFailover();

    // 4. 手动 failover 超时
    // 5. 孤儿 master 迁移 slave
    // 6. 更新集群状态
}
```

---

## 3. 故障检测——PFAIL → FAIL

### 3.1 故障检测流程

```
超时未收到 PONG
  ↓
设 CLUSTER_NODE_PFAIL（本地疑似故障）
  ↓
通过 gossip 传播 PFAIL 状态
  ↓
另一个节点 clusterNodeFailReport 也报告 PFAIL
  ↓
收到足够多（多数 master）的 PFAIL 报告
  ↓
广播 CLUSTERMSG_TYPE_FAIL
  ↓
设 CLUSTER_NODE_FAIL（全局故障）
  ↓
触发 failover
```

```c
// cluster.c — 故障升级逻辑（clusterCron 中）
if (now - node->pong_received > server.cluster_node_timeout) {
    if (node->flags & CLUSTER_NODE_SLAVE) {
        // 从节点超时：设 PFAIL
        node->flags |= CLUSTER_NODE_PFAIL;
        clusterDoBeforeSleep(CLUSTER_TODO_UPDATE_STATE);
    }
    // 检查是否可以将 PFAIL 升级为 FAIL：
    // 需要其他节点也报告了 PFAIL，且达到多数阈值
}
```

**`clusterNodeFailReport`**：

```c
// cluster.h:110 — doom-lsp 确认
typedef struct clusterNodeFailReport {
    struct clusterNode *node;  // 报告故障的节点
    mstime_t time;             // 报告时间
} clusterNodeFailReport;
```

---

## 4. Slave Failover——Raft 风格的选举

### 4.1 选举流程

```
Slave 检测到 master 为 FAIL 状态
  ↓
clusterHandleSlaveFailover():
  1. 自增 currentEpoch
  2. 随机延迟 = (rank * NODE_TIMEOUT/2) + random(PONG_RECV_TIME)
     （rank 越小延迟越短 → 数据更新的 slave 优先投票）
  ↓
  3. 向所有 master 广播 FAILOVER_AUTH_REQUEST
  ↓
Master 回复：
  - 检查 currentEpoch ≥ 已知最大 epoch
  - 检查 master 是否在 NODE_TIMEOUT 内未收到请求
  - 检查是否已给同一 epoch 投过票
  - 回复 FAILOVER_AUTH_ACK（一个 vote）
  ↓
Slave 收集票数：
  - 多数 master (> N/2) 投票则胜出
  - 设 configEpoch = newEpoch
  - 设本节点为 MASTER
  - 广播 PONG 通知集群
```

```c
// cluster.c:3575 — doom-lsp 确认
void clusterHandleSlaveFailover(void) {
    // 1. 检查条件：master 在 FAIL 状态 / 手动 failover 触发
    // 2. 自增 epoch，准备选举
    // 3. 发送 FAILOVER_AUTH_REQUEST
    // 4. 收集票数
    // 5. 胜出 → 设本节点为 master + 接管 slot
}
```

**争议解决**：如果同时有两个 slave 发起选举，更高的 `configEpoch` 胜出。如果 epoch 相同，依据 `clusterNode->repl_offset`（复制偏移量）确定 rank，偏移量大的（数据最新的）优先。

---

## 5. 请求路由——MOVED / ASK

### 5.1 MOVED——确定性重定向

```
Client: GET key
Node A: key 的 slot 应由 Node B 负责
Node A: -MOVED 3999 192.168.1.2:6379\r\n
Client: 更新本地路由缓存 → 重发到 Node B
```

实现：

```c
// cluster.c — doom-lsp 确认
int clusterRedirectClientOrReply(client *c, ...) {
    if (error_code == CLUSTER_REDIR_MOVED) {
        // 计算 slot 的 master 节点
        addReplyErrorFormat(c, "-MOVED %d %s:%d\r\n",
            slot, node->ip, node->port);
    } else if (error_code == CLUSTER_REDIR_ASK) {
        addReplyErrorFormat(c, "-ASK %d %s:%d\r\n",
            slot, node->ip, node->port);
    }
}
```

### 5.2 ASK——迁移中的临时重定向

Slot 迁移过程中，数据分布在两个节点：

```
CLUSTER SETSLOT 3999 MIGRATING <target_id>  // 源节点标记迁出
CLUSTER SETSLOT 3999 IMPORTING <source_id>  // 目标节点标记迁入

Client: GET key
源节点: key 还在本节点？→ 正常回复
源节点: key 已迁移？→ -ASK 3999 target_ip:port
Client: 收到 ASK → 先发 ASKING → 再发 GET
目标节点: ASKING 标记 → 临时允许操作此 slot → 回复
```

ASKING 是个一次性标记：

```c
// server.h:324 — doom-lsp 确认
#define CLIENT_ASKING (1<<9)     // 客户端已发 ASKING 命令
```

收到 ASK 重定向后，客户端先向目标节点发 `ASKING`，目标节点设置 `CLIENT_ASKING` 标志，然后执行后续命令。这个标志执行完一条命令后清除。

---

## 6. Slot 迁移

```c
// CLUSTER SETSLOT 3999 NODE <target-node-id>
// CLUSTER GETKEYSINSLOT 3999 10
// MIGRATE target_ip target_port "" 0 5000 KEYS key1 key2 ...

// MIGRATE 命令内部：
// 1. DUMP key → 序列化为 RDB 格式
// 2. 发送到目标节点
// 3. RESTORE 恢复
// 4. 源节点 DEL key
// 5. 重复直到所有 key 迁移完毕
// 6. CLUSTER SETSLOT 3999 NODE <target>（广播 UPDATE）
```

迁移期间，`migrating_slots_to` 和 `importing_slots_from` 被设置，使得 #5.2 描述的 ASK 重定向生效。

---

## 7. Cluster 状态切换

```c
// cluster.c:4429 — doom-lsp 确认
void clusterUpdateState(void) {
    // 检查条件：
    // 1. 本节点不是 FAIL 状态
    // 2. 所有 slot 都有 master 负责
    // 3. 多数 master 节点（> N/2）可达

    if (state_ok)
        cluster->state = CLUSTER_OK;
    else
        cluster->state = CLUSTER_FAIL;
}
```

```c
// server.h — clusterState.state 值
#define CLUSTER_OK    0   // 正常
#define CLUSTER_FAIL  1   // 集群不可用
```

当集群进入 `CLUSTER_FAIL` 状态时，默认拒绝所有 key 操作（可用 `cluster-require-full-coverage no` 配置允许降级服务）。

---

## 8. 与系列前文的联系

```
Cluster 整合了系列中大量子系统：

Client: GET key
  → keyHashSlot(key) = 3999         ← 计算 slot
  → server.cluster->slots[3999]      ← 查找路由
  → 不是本节点：clusterRedirectClientOrReply → -MOVED  (09: networking)

CLUSTER SETSLOT 3999 NODE X
  → clusterNodeSetSlotBit @4326      ← 设置 slot 位图
  → clusterUpdateState @4429         ← 更新集群状态
  → clusterSendPing → PONG           ← gossip 传播 (07: rax 索引)

FAILOVER
  → clusterHandleSlaveFailover @3575  ← 选举（少数服从多数）
  → slave 提升为 master              ← (14: replication)

迁移:
  → MIGRATE → DUMP → RDB 序列化      ← (10: rdb)
  → RESTORE → RDB 加载               ← (10: rdb)
  → DEL                              ← (13: db.c)
  → ASKING / MOVED                   ← (09: networking)
```
