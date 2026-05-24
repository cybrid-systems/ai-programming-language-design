# 19 — Pub/Sub：Redis 的消息发布与订阅

> Redis 主线源码深度分析系列 · 第十九篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Pub/Sub（发布/订阅）是 Redis 中的一个经典消息模式。它和 List/Stream 等数据类型的消息机制不同——Pub/Sub 是**即发即弃**的：消息不持久化，没有 backlog，没有消费者组，订阅者如果不在线就收不到消息。

但正因为简单，Pub/Sub 的实现非常轻量：754 行的 `pubsub.c`，核心是两个 dict + 一个模式匹配引擎。

**三种通道类型**：

| 类型 | 命令 | 范围 | 匹配方式 |
|------|------|------|---------|
| 全局通道 | `SUBSCRIBE` / `PUBLISH` | 整个实例 | 精确匹配 |
| 全局模式 | `PSUBSCRIBE` / `PUBLISH` | 整个实例 | glob 通配符 |
| 分片通道 | `SSUBSCRIBE` / `SPUBLISH` | 单个 slot（Cluster） | 精确匹配 |

**doom-lsp 确认**：核心文件

| 文件 | 行数 | doom-lsp 符号数 |
|------|:----:|:-------------:|
| `src/pubsub.c` | 754 | 50+ |

关键符号链：

```
struct pubsubtype @35         // 通道类型抽象（全局/分片）
pubSubType @75                // 全局通道类型实例
pubSubShardType @88           // 分片通道类型实例

fn pubsubSubscribeChannel @246     // ★ SUBSCRIBE 核心
fn pubsubUnsubscribeChannel @273   // ★ UNSUBSCRIBE 核心
fn pubsubSubscribePattern @343     // ★ PSUBSCRIBE 核心
fn pubsubPublishMessageInternal @468 // ★ PUBLISH 核心
fn pubsubPublishMessage @523       // PUBLISH 分派
fn subscribeCommand @532           // SUBSCRIBE 命令
fn psubscribeCommand @564          // PSUBSCRIBE 命令
fn publishCommand @606             // PUBLISH 命令
fn pubsubCommand @619              // PUBSUB 管理命令
fn spublishCommand @701            // SPUBLISH 命令（分片）
fn ssubscribeCommand @709          // SSUBSCRIBE 命令（分片）
fn pubsubUnsubscribeAllChannels @424 // 清空订阅

// 数据引用：
// client->pubsub_channels (dict)     ← 该 client 订阅的全局通道
// client->pubsubshard_channels (dict) ← 该 client 订阅的分片通道
// client->pubsub_patterns (list)     ← 该 client 订阅的模式
// server.pubsub_channels (dict)      ← 全局通道 → 订阅者列表
// server.pubsub_patterns (dict)      ← 模式 → 订阅者列表
// server.pubsubshard_channels (dict) ← 分片通道 → 订阅者列表
```

---

## 1. 数据结构——双端 dict 索引

Pub/Sub 的核心是两个方向的双向索引：

```
server 端（全局）：
  server.pubsub_channels:   dict<channel → list<client>>
  server.pubsub_patterns:   dict<pattern → list<client>>
  server.pubsubshard_channels: dict<channel → list<client>>

client 端（每个订阅者）：
  c->pubsub_channels:       dict<channel → NULL>
  c->pubsubshard_channels:  dict<channel → NULL>
  c->pubsub_patterns:       list<pattern>
```

**`pubsubtype` 抽象**（`pubsub.c:35`）：

```c
// doom-lsp 确认 @35
typedef struct pubsubtype {
    int shard;                             // 是否为分片模式
    dict *(*clientPubSubChannels)(client*); // 取 client 的通道 dict
    int (*subscriptionCount)(client*);      // 取 client 的订阅数
    dict **serverPubSubChannels;           // server 端通道 dict 的指针
    robj **subscribeMsg;                   // 订阅响应消息模板
    robj **unsubscribeMsg;                 // 退订响应消息模板
    robj **messageBulk;                    // 消息负载模板
} pubsubtype;
```

两个静态实例：

```c
// doom-lsp 确认 @75 / @88
pubsubtype pubSubType = { .shard = 0, .serverPubSubChannels = &server.pubsub_channels, ... };
pubsubtype pubSubShardType = { .shard = 1, .serverPubSubChannels = &server.pubsubshard_channels, ... };
```

PUBLISH 和 SUBSCRIBE 的所有函数都通过 `pubsubtype` 参数统一操作——全局和分片通道共享同一套函数，只是数据源不同。

---

## 2. 订阅——SUBSCRIBE / PSUBSCRIBE / SSUBSCRIBE

### 2.1 SUBSCRIBE——精确匹配通道

```c
// pubsub.c:246 — doom-lsp 确认
int pubsubSubscribeChannel(client *c, robj *channel, pubsubtype type) {
    // 1. 在 client 的通道 dict 中加一条
    if (dictAdd(type.clientPubSubChannels(c), channel, NULL) == DICT_OK) {
        incrRefCount(channel);

        // 2. 在 server 的通道→client 列表中添加
        de = dictFind(*type.serverPubSubChannels, channel);
        if (de == NULL) {
            clients = listCreate();
            dictAdd(*type.serverPubSubChannels, channel, clients);
            incrRefCount(channel);
        } else {
            clients = dictGetVal(de);
        }
        listAddNodeTail(clients, c);
    }

    // 3. 回复订阅确认消息
    addReplyPubsubSubscribed(c, channel, type);
}
```

**数据结构变化**（SUBSCRIBE news）：

```
client->pubsub_channels:        "news" → NULL

server.pubsub_channels:
  "news" → [client_A, client_B ...]
```

### 2.2 PSUBSCRIBE——通配符模式

```c
// pubsub.c:343 — doom-lsp 确认
int pubsubSubscribePattern(client *c, robj *pattern) {
    if (listSearchKey(c->pubsub_patterns, pattern) == NULL) {
        // 1. 加入 client 的模式列表
        listAddNodeTail(c->pubsub_patterns, pattern);
        incrRefCount(pattern);

        // 2. 加入 server 的模式 dict
        de = dictFind(server.pubsub_patterns, pattern);
        if (de == NULL) {
            clients = listCreate();
            dictAdd(server.pubsub_patterns, pattern, clients);
            incrRefCount(pattern);
        } else {
            clients = dictGetVal(de);
        }
        listAddNodeTail(clients, c);
    }
    addReplyPubsubPatSubscribed(c, pattern);
}
```

PSUBSCRIBE 使用 `list` 而非 `dict` 作为 client 的模式存储，因为模式订阅通常较少（一般个位数），`list` 适合小规模精确匹配。

### 2.3 SSUBSCRIBE——分片通道

分片通道绑定到单个 slot。当 Redis Cluster 中 slot 迁移时，`pubsubShardUnsubscribeAllClients` 会自动取消该 slot 的所有订阅——保证消息不会因为 slot 迁移而丢失或重复。

```c
// pubsub.c:311 — doom-lsp 确认
void pubsubShardUnsubscribeAllClients(robj *channel) {
    // Find all clients subscribed to this channel
    de = dictFind(server.pubsubshard_channels, channel);
    clients = dictGetVal(de);

    // Force-unsubscribe every client
    while ((ln = listNext(&li)) != NULL) {
        client *c = listNodeValue(ln);
        dictDelete(c->pubsubshard_channels, channel);
        addReplyPubsubUnsubscribed(c, channel, pubSubShardType);
    }
    // Delete channel from server dict + slot mapping
    dictDelete(server.pubsubshard_channels, channel);
    slotToChannelDel(channel->ptr);
}
```

---

## 3. 发布——PUBLISH / SPUBLISH

### 3.1 pubsubPublishMessageInternal——核心分发

```c
// pubsub.c:468 — doom-lsp 确认
int pubsubPublishMessageInternal(robj *channel, robj *message, pubsubtype type) {
    int receivers = 0;

    // 1. ★ 精确通道匹配
    de = dictFind(*type.serverPubSubChannels, channel);
    if (de) {
        list *list = dictGetVal(de);
        while ((ln = listNext(&li)) != NULL) {
            client *c = ln->value;
            // 回复 push 消息（不改变 client 的正常命令响应）
            addReplyPubsubMessage(c, channel, message, *type.messageBulk);
            receivers++;
        }
    }

    // 2. ★ 模式匹配（仅限全局通道）
    if (type.shard) return receivers;  // 分片通道不支持模式

    di = dictGetIterator(server.pubsub_patterns);
    while ((de = dictNext(di)) != NULL) {
        robj *pattern = dictGetKey(de);
        list *clients = dictGetVal(de);

        // ★ glob 模式匹配
        if (!stringmatchlen(pattern->ptr, sdslen(pattern->ptr),
                            channel->ptr, sdslen(channel->ptr), 0))
            continue;

        while ((ln = listNext(&li)) != NULL) {
            client *c = listNodeValue(ln);
            addReplyPubsubPatMessage(c, pattern, channel, message);
            receivers++;
        }
    }
    dictReleaseIterator(di);
    return receivers;
}
```

**消息传递路径**：

```
PUBLISH news "hello"
  ↓
publishCommand (pubsub.c:606)
  ↓
pubsubPublishMessage(channel, message, 0)
  ↓
pubsubPublishMessageInternal(channel, message, pubSubType)
  ├── dictFind(server.pubsub_channels, "news")
  │   → [client_A] → addReplyPubsubMessage("news", "hello")
  │
  └── dictGetIterator(server.pubsub_patterns)
      → ["news:*"] → stringmatchlen("news:*", "news") ✓
      → [client_B] → addReplyPubsubPatMessage("news:*", "news", "hello")
  ↓
(Cluster 模式) → clusterPropagatePublish ← 传播到其他节点
```

### 3.2 CLIENT_PUSHING——push 消息标志

```c
// pubsub.c:107 — doom-lsp 确认
void addReplyPubsubMessage(client *c, robj *channel, robj *msg, robj *message_bulk) {
    uint64_t old_flags = c->flags;
    c->flags |= CLIENT_PUSHING;   // ★ 标记为 push 消息
    // RESP2: *3\r\n$7\r\nmessage\r\n... → 数组格式
    // RESP3: Push type → 自动识别
    addReply(c, shared.mbulkhdr[3]);
    addReply(c, message_bulk);    // "message" / "smessage"
    addReplyBulk(c, channel);
    if (msg) addReplyBulk(c, msg);
    if (!(old_flags & CLIENT_PUSHING))
        c->flags &= ~CLIENT_PUSHING;
}
```

`CLIENT_PUSHING` 标志确保 Pub/Sub 的异步消息不会与 client 正在等待的命令回复冲突。RESP3 协议中，Push 类型有专门的帧类型。

---

## 4. 退订与清理

### 4.1 UNSUBSCRIBE

```c
// pubsub.c:273 — doom-lsp 确认
int pubsubUnsubscribeChannel(client *c, robj *channel, int notify, pubsubtype type) {
    // 1. 从 client 的通道 dict 中删除
    if (dictDelete(type.clientPubSubChannels(c), channel) == DICT_OK) {
        // 2. 从 server 的通道列表中找到此 client 删除
        de = dictFind(*type.serverPubSubChannels, channel);
        clients = dictGetVal(de);
        ln = listSearchKey(clients, c);
        listDelNode(clients, ln);

        // 3. 如果此通道已无订阅者，删除整个 dict 条目
        if (listLength(clients) == 0)
            dictDelete(*type.serverPubSubChannels, channel);
    }
    // 4. 回复退订确认
    addReplyPubsubUnsubscribed(c, channel, type);
}
```

### 4.2 客户端断开时的自动清理

当 `freeClient` 释放 client 时，自动遍历其 `pubsub_channels`、`pubsubshard_channels` 和 `pubsub_patterns`，从 server 端的数据结构中移除订阅关系。这样即使 client 异常断开，server 也不会残留脏数据。

```c
// networking.c — freeClient → pubsubUnsubscribeAllChannels 等
```

---

## 5. PUBSUB 管理命令

`PUBSUB` 命令提供内部状态查询，实现为 `pubsubCommand`（`pubsub.c:619`）：

| 子命令 | 功能 |
|--------|------|
| `PUBSUB CHANNELS [pattern]` | 列出当前有订阅者的通道 |
| `PUBSUB NUMSUB [channel ...]` | 返回指定通道的订阅者数 |
| `PUBSUB NUMPAT` | 返回模式订阅的数量 |

---

## 6. 消息协议格式

### RESP2 格式

```
SUBSCRIBE foo bar
  *3\r\n$9\r\nsubscribe\r\n$3\r\nfoo\r\n:1\r\n  ← 订阅确认
  *3\r\n$9\r\nsubscribe\r\n$3\r\nbar\r\n:2\r\n

PUBLISH foo hello
  :1\r\n                                    ← 返回接收者数

（接收到的消息）
  *3\r\n$7\r\nmessage\r\n$3\r\nfoo\r\n$5\r\nhello\r\n

（模式匹配的消息）
  *4\r\n$8\r\npmessage\r\n$5\r\nf*\r\n$3\r\nfoo\r\n$5\r\nhello\r\n
```

### RESP3 格式

```
SUBSCRIBE foo
  >7 push type: subscribe, channel: foo, subscription count: 1

PUBLISH foo hello
  → 1

（收到的消息）
  >7 push type: message, channel: foo, data: hello
```

---

## 7. 与系列前文的联系

```
PUBLISH news "hello"
  → pubsubPublishMessageInternal
    → dictFind(server.pubsub_channels, "news")  ← (03: dict)
    → addReplyPubsubMessage
      → addReplyBulk(c, channel)                ← (09: networking)
    → stringmatchlen(...)                        ← glob 匹配

SUBSCRIBE news
  → pubsubSubscribeChannel
    → dictAdd(c->pubsub_channels, "news")       ← (03: dict)
    → dictAdd(server.pubsub_channels, "news")   ← (03: dict)
    → listAddNodeTail(clients, c)               ← list

freeClient
  → pubsubUnsubscribeAllChannels                ← 订阅清理
  → pubsubUnsubscribeAllPatterns

SSUBSCRIBE (分片)
  → slotToChannelAdd / slotToChannelDel      ← (cluster slot 映射)
  → pubsubShardUnsubscribeAllClients          ← slot 迁移时自动清退
```
