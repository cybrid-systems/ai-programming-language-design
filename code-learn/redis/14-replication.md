# 14 — Replication：Redis 的主从复制

> Redis 主线源码深度分析系列 · 第十四篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Redis 的复制机制支持一个主节点（master）向多个从节点（replica）同步数据。它经历了三代演进：

| 代 | 协议 | 机制 | Redis 版本 |
|----|------|------|-----------|
| 1 | `SYNC` | 每次全量 RDB | 1.0 |
| 2 | `PSYNC` | 支持部分重同步 + 复制积压缓冲区 | 2.8 |
| 3 | `PSYNC2` | 支持主从切换后仍可部分重同步 | 4.0+ |

本文聚焦 `PSYNC2`（Redis 7.0.15），逐一拆解从连接建立到增量复制的完整数据流。

**doom-lsp 确认**：核心文件

| 文件 | 行数 | doom-lsp 符号数 |
|------|:----:|:-------------:|
| `src/replication.c` | 4092 | 90 |
| `src/server.h` | — | replBacklog / replBufBlock 等 |

---

## 1. 数据结构

### 1.1 复制积压缓冲区（Replication Backlog）

```c
// server.h — replBufBlock 定义
typedef struct replBufBlock {
    int refcount;           // 共享此块的 replica 数
    long long id;           // 唯一递增编号
    long long repl_offset;  // 块起始的复制偏移量
    size_t size, used;
    char buf[];             // 柔性数组，实际数据
} replBufBlock;

// replBacklog 结构
typedef struct replBacklog {
    listNode *ref_repl_buf_node;    // 引用缓冲区块链表中的节点
    int unindexed_count;
    rax *blocks_index;              // 复制块的 rax 索引（按 repl_offset 索引）
    long long histlen;              // 缓冲区中有效历史数据长度
    long long offset;               // 缓冲区中第一个字节的全局偏移量
} replBacklog;
```

**双向链表** `server.repl_buffer_blocks`：每个 `replBufBlock` 包含一段 RESP 协议数据，通过 `refcount` 实现**共享**——多个 replica 和 backlog 可以共同引用同一个块，不需要复制。

```
replBufBlock 链表：
┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
│ refcount=2         │  │ refcount=1         │  │ refcount=3         │
│ repl_offset=1000   │─→│ repl_offset=1200   │─→│ repl_offset=1400   │
│ used=200           │  │ used=200           │  │ used=100           │
│ buf="...SET key..." │  │ buf="...DEL a..."  │  │ buf="...SET ..."   │
└────────────────────┘  └────────────────────┘  └────────────────────┘
       ↕        ↕                                     ↕        ↕
   replica_A  backlog                             replica_B  backlog
```

### 1.2 master 端的复制相关状态

```c
// server.h — 关键字段
long long master_repl_offset;     // 当前已传播的复制偏移量
char replid[CONFIG_RUN_ID_SIZE+1]; // 当前复制 ID（重启后变化）
char replid2[CONFIG_RUN_ID_SIZE+1];// 上一个复制 ID（主从切换时保留）
long long second_replid_offset;    // replid2 有效的最大偏移量
replBacklog *repl_backlog;         // 积压缓冲区指针
int repl_backlog_size;            // 积压缓冲区大小（默认 1MB）
list *slaves;                     // 从节点链表
int slaveseldb;                   // 最后一次发送 SELECT 的 dbid
```

---

## 2. 复制拓扑的主——向从节点传播命令

当 master 执行一条写命令后，`propagate()` 同时做两件事：

```c
// server.c — propagate 的等价逻辑
void propagate(struct redisCommand *cmd, ...) {
    // 路径一：AOF
    if (server.aof_state != AOF_OFF)
        feedAppendOnlyFile(dbid, argv, argc);

    // 路径二：Replication
    replicationFeedSlaves(server.slaves, dbid, argv, argc);
}
```

### 2.1 replicationFeedSlaves——主推 REPL 协议

```c
// replication.c:429 — doom-lsp 确认
void replicationFeedSlaves(list *slaves, int dictid,
                            robj **argv, int argc) {
    // 1. 如果是从节点→不传播（已通过复制流接收数据）
    if (server.masterhost != NULL) return;

    // 2. 没有从节点 + 没有 backlog → 跳过
    if (server.repl_backlog == NULL && listLength(slaves) == 0) return;

    // 3. ★ 先给所有从节点安装写处理句柄
    prepareReplicasToWrite();

    // 4. ★ DB 切换：如果与上次发送的 DB 不同，发送 SELECT
    if (server.slaveseldb != dictid) {
        feedReplicationBufferWithObject(selectcmd);
        server.slaveseldb = dictid;
    }

    // 5. ★ 将命令写为 RESP 协议，追加到复制缓冲区（repl_buffer_blocks）
    //    *3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n
    feedReplicationBuffer("*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n");
}
```

`feedReplicationBuffer`（`replication.c:323`）将 RESP 协议数据追加到 `server.repl_buffer_blocks` 链表尾部，同时更新 `server.master_repl_offset`。

每个从节点通过 `server.repl_buffer_blocks` 链表**共享**数据块。主节点不复制数据给从节点，而是让所有从节点通过 `refcount` 共享指向同一块缓冲区的指针。

### 2.2 从节点如何消费

从节点在 `SLAVE_STATE_ONLINE` 状态下，其 `replstate` 标志表明它已准备好接收增量数据。主节点的 `writeToClient` 在 beforesleep 中被调用（或者通过写事件句柄），将 replica 尚未消费的 `replBufBlock` 数据发送到 socket。

每个 replica 追踪自己的消费进度（`c->reploff`），一旦 replica 落后太多，backlog 中对应的块已经因 `incrementalTrimReplicationBacklog` 被释放，就需要全量重同步。

---

## 3. PSYNC——部分重同步

### 3.1 REPL 握手流程

```
replica                                          master
  │                                                │
  │── REPLCONF listening-port <port> ─────────────►│
  │── REPLCONF capa eof capa psync2 ──────────────►│
  │── PSYNC <replid> <offset> ────────────────────►│
  │                                                │
  │◄── +CONTINUE <replid> \r\n                     │  ← 部分重同步成功
  │◄── <backlog data from offset>                  │
  │                                                │
  或:
  │◄── +FULLRESYNC <replid> <offset> \r\n          │  ← 需要全量同步
  │◄── <RDB data>                                 │
  │◄── +<streaming data after RDB>                 │
  │   ... 增量复制 ...                              │
  │── REPLCONF ACK <offset> ─────────────────────►│  ← 每 1 秒 ACK
```

### 3.2 PSYNC 命令入口——syncCommand

```c
// replication.c:920 — doom-lsp 确认
void syncCommand(client *c) {
    // ... 各种前置检查（failover? slave? pending output?）...

    // ★ 先尝试部分重同步
    if (psync 命令) {
        if (masterTryPartialResynchronization(c, psync_offset) == C_OK) {
            server.stat_sync_partial_ok++;
            return;  // 部分重同步成功！
        }
    }

    // ★ 部分同步失败 → 全量同步
    c->replstate = SLAVE_STATE_WAIT_BGSAVE_START;
    listAddNodeTail(server.slaves, c);

    // 创建/维护 replication backlog
    if (listLength(server.slaves) == 1 && server.repl_backlog == NULL) {
        changeReplicationId();  // 生成新 replid
        createReplicationBacklog();
    }

    // 触发 BGSAVE（已有进行中的则复用）
    startBgsaveForReplication(mincapa, c->slave_req);
}
```

### 3.3 masterTryPartialResynchronization——三种结果

```c
// replication.c:725 — doom-lsp 确认
int masterTryPartialResynchronization(client *c, long long psync_offset) {
    // 1. ★ replid 匹配检查
    //    replica 携带 replid + offset 请求部分重同步
    //    master 检查是否与自己的 replid（或 replid2）匹配

    if (strcasecmp(master_replid, server.replid) &&
        (strcasecmp(master_replid, server.replid2) ||
         psync_offset > server.second_replid_offset))
    {
        goto need_full_resync;  // replid 不匹配 → 全量
    }

    // 2. ★ 偏移量是否在 backlog 范围内
    if (!server.repl_backlog ||
        psync_offset < server.repl_backlog->offset ||
        psync_offset > (server.repl_backlog->offset +
                        server.repl_backlog->histlen))
    {
        goto need_full_resync;  // 偏移量超出 → 全量
    }

    // 3. ★ 部分重同步成功！
    c->replstate = SLAVE_STATE_ONLINE;
    connWrite(c->conn, "+CONTINUE <replid>\r\n");
    addReplyReplicationBacklog(c, psync_offset);  // 发送 backlog 中缺失的部分
    return C_OK;

need_full_resync:
    return C_ERR;  // 触发完整 RDB 同步
}
```

**部分重同步的三个条件**（缺一不可）：

1. **replid 匹配**：replica 使用的 replid 与 master 的 `replid` 或 `replid2`（且偏移量在 `second_replid_offset` 范围内）匹配
2. **偏移量在 backlog 内**：replica 请求的偏移量 ≥ backlog 起始偏移量
3. **偏移量 ≤ master 当前已传播偏移量**：合理的时间范围

### 3.4 replid 与 replid2——主从切换后的 PSYNC2

```c
// replication.c:1645 — doom-lsp 确认
void changeReplicationId(void) {
    // 生成新的 replid（随机 40 字符十六进制）
    getRandomHexChars(server.replid, CONFIG_RUN_ID_SIZE);
    server.replid[CONFIG_RUN_ID_SIZE] = '\0';
}

// replication.c:1664 — doom-lsp 确认
void shiftReplicationId(void) {
    // 当成为从节点时，将旧 replid 保存到 replid2
    memcpy(server.replid2, server.replid, sizeof(server.replid));
    server.second_replid_offset = server.master_repl_offset + 1;
    changeReplicationId();
}
```

**PSYNC2 的核心改进**：当一个 slave 提升为新的 master（通过 `SLAVEOF NO ONE` 或 cluster failover），它保留旧 master 的 replid 到 `replid2`，并生成自己的新 `replid`。这样，原先连接到旧 master 的其他 slave 在切换到新 master 后可以继续使用部分重同步——因为它们的 replid 匹配新 master 的 `replid2`。

```
  主 A (replid=A) 宕机
     ↓
  从 B 提升为新主：replid=B, replid2=A, second_replid_offset=1000
     ↓
  从 C 连接新主 B：PSYNC A 800
  → replid2=B 匹配 A? → 不  → replid2=A? → 是!
    偏移量 800 < second_replid_offset(1000)? → 是!
  → +CONTINUE → 部分同步成功！
```

---

## 4. 全量同步——RDB 传输

当部分重同步不可用时，使用全量同步：

```
syncCommand → startBgsaveForReplication
  ├── disk 模式：BGSAVE → temp RDB 文件 → sendBulkToSlave → 传输完成后删除
  └── socket 模式：fork → 子进程写 RDB 到 socket（通过 pipe）

子进程或 BGSAVE 完成后：
  → updateSlavesWaitingBgsave
    → 将 slave 状态从 WAIT_BGSAVE_END 转为 ONLINE
    → 开始增量复制
```

### 4.1 startBgsaveForReplication

```c
// replication.c:841 — doom-lsp 确认
int startBgsaveForReplication(int mincapa, int req) {
    socket_target = server.repl_diskless_sync && (mincapa & SLAVE_CAPA_EOF);

    if (socket_target) {
        // socket 模式：子进程直接写入 socket
        retval = rdbSaveToSlavesSockets(req, rsi);
    } else {
        // disk 模式：子进程写入临时 RDB 文件
        retval = rdbSaveBackground(req, server.rdb_filename, rsi);
    }

    if (retval == C_OK) {
        // 将所有 WAIT_START 状态的 slave 转为 WAIT_BGSAVE_END
        listRewind(server.slaves, &li);
        while ((ln = listNext(&li))) {
            slave = ln->value;
            if (slave->replstate == SLAVE_STATE_WAIT_BGSAVE_START) {
                slave->replstate = SLAVE_STATE_WAIT_BGSAVE_END;
            }
        }
    }
}
```

### 4.2 sendBulkToSlave——disk 模式的 RDB 发送

```c
// replication.c:1356 — doom-lsp 确认
void sendBulkToSlave(aeEventLoop *el, int fd, void *privdata, int mask) {
    client *slave = privdata;
    // 1. 发送 RDB 的文件描述符
    // 2. 循环 read/write RDB 文件
    // 3. 传输完成后关闭文件，设置 SLAVE_STATE_ONLINE
    // 4. 开始发送 backlog 中的增量数据
}
```

### 4.3 全量同步期间的写缓冲区

全量同步期间（RDB 传输进行中），master 仍在接受写命令。这些增量写命令被追加到 `repl_backlog` 中。当 RDB 传输完成后，master 将 backlog 中从 RDB 生成时刻到当前时刻的数据发给 slave。这样 slave 的最终状态与 master 完全一致。

---

## 5. 从节点视角——连接与同步

### 5.1 连接管理——replicationCron

```c
// replication.c:3565 — doom-lsp 确认
void replicationCron(void) {
    // 1. 连接超时检查
    if (连接中 && 超时) cancelReplicationHandshake();

    // 2. bulk 传输超时检查
    if (传输中 && 超时) cancelReplicationHandshake();

    // 3. 主节点响应超时检查
    if (已连接 && 无交互超时) freeClient(master);

    // 4. 发起连接
    if (server.repl_state == REPL_STATE_CONNECT)
        connectWithMaster();

    // 5. 发送 ACK 给主节点
    if (server.masterhost && server.master && !PRE_PSYNC)
        replicationSendAck();

    // 6. PING 从节点 && 超时断开
    // 7. 刷新 good slaves 计数（用于 WAIT 命令）
}
```

### 5.2 syncWithMaster——握手状态机

```c
// replication.c:2570 — doom-lsp 确认
void syncWithMaster(connection *conn) {
    char tmpfile[256], *err;
    int rcvbuflen;
    int onerror = 0;

    // 根据 server.repl_state 状态机分步执行：
    switch (server.repl_state) {
    case REPL_STATE_CONNECTING:
        // 已建立 TCP 连接
        break;

    case REPL_STATE_RECEIVE_PONG:
        // 发送 PING → 等待 +PONG
        connWrite(conn, "PING\r\n", 6);
        server.repl_state = REPL_STATE_SEND_PONG;
        break;

    case REPL_STATE_SEND_HANDSHAKE:
        // 发送 REPLCONF (端口, IP, capa)
        connWrite(conn, "REPLCONF listening-port ...\r\n");
        break;

    case REPL_STATE_RECEIVE_PSYNC:
        // 发送 PSYNC <replid> <offset>
        connWrite(conn, "PSYNC %s %lld\r\n", replid, offset);
        break;

    case REPL_STATE_RECEIVE_CONTINUE:
        // 收到 +CONTINUE → 部分重同步成功，进入 ONLINE
        slaveTryPartialResynchronization(conn, read_reply);
        break;

    case REPL_STATE_RECEIVE_FULLRESYNC:
        // 收到 +FULLRESYNC → 接收 RDB
        readSyncBulkPayload(conn, read_reply);
        break;
    }
}
```

**完整握手状态机**：

```
REPL_STATE_CONNECT (replicationCron)
  → connectWithMaster
    → REPL_STATE_CONNECTING
    → REPL_STATE_RECEIVE_PONG
    → REPL_STATE_SEND_AUTH (if auth)
    → REPL_STATE_RECEIVE_AUTH
    → REPL_STATE_SEND_PORT
    → REPL_STATE_RECEIVE_PORT
    → REPL_STATE_SEND_CAPA
    → REPL_STATE_RECEIVE_CAPA
    → REPL_STATE_SEND_PSYNC
    → REPL_STATE_RECEIVE_PSYNC
      ├→ +CONTINUE → SLAVE_STATE_ONLINE
      └→ +FULLRESYNC → readSyncBulkPayload → load RDB → ONLINE
```

### 5.3 slaveTryPartialResynchronization

```c
// replication.c:2399 — doom-lsp 确认
int slaveTryPartialResynchronization(connection *conn, ...) {
    // 解析 master 返回的 +CONTINUE <replid> 或 +FULLRESYNC <replid> <offset>

    char *p = buf;
    if (!strncmp(p, "+CONTINUE", 9)) {
        // ★ 部分重同步成功！
        p += 9;
        if (*p == ' ') {
            // 更新 replid
            memcpy(server.replid, p+1, CONFIG_RUN_ID_SIZE);
            server.replid[CONFIG_RUN_ID_SIZE] = '\0';
        }
        server.repl_state = REPL_STATE_CONNECTED;
        return PSYNC_CONTINUE;
    } else if (!strncmp(p, "+FULLRESYNC", 11)) {
        // 全量同步
        memcpy(server.replid, p+1, ...);  // 保存新 replid
        server.master_initial_offset = offset;
        return PSYNC_FULLRESYNC;
    }
}
```

### 5.4 readSyncBulkPayload——读取全量 RDB

```c
// replication.c:1819 — doom-lsp 确认
void readSyncBulkPayload(connection *conn) {
    // 1. 读取 RDB 文件（diskless 则直接加载到内存）
    // 2. 写入临时文件
    // 3. 加载 RDB
    // 4. 设置 repl_state = REPL_STATE_CONNECTED
    // 5. 创建 replication backlog
    // 6. 开始接收增量命令
}
```

---

## 6. WAIT 命令——同步等待

```c
// replication.c:3461 — doom-lsp 确认
void waitCommand(client *c) {
    // WAIT <numreplicas> <timeout>
    // 等待至少 N 个从节点确认收到所有写入

    // 1. 检查已有多少从节点确认
    // 2. 如果不够，将 client 加入等待队列
    // 3. 设置定时器
    // 4. 从节点发 REPLCONF ACK 时 → 计数 → 达到则唤醒

    if (c->flags & CLIENT_MULTI) {
        // 事务中：返回当前已确认数
    } else {
        // 阻塞等待或立即返回
    }
}

void replicationCountAcksByOffset(void) {
    // 遍历 server.slaves，统计 repl_ack_off ≥ master_repl_offset 的从节点数
}

void processClientsWaitingReplicas(void) {
    // 唤醒等待的 WAIT 命令客户端
}
```

**`REPLCONF ACK <offset>`**：从节点每秒向主节点报告自己的复制偏移量。主节点根据 ACK 中的偏移量判断从节点是否已收到最新数据。这是 `WAIT` 命令和 repl-timeout 检测的基础。

---

## 7. 复制积压缓冲区的裁剪

```c
// replication.c:250 — doom-lsp 确认
void incrementalTrimReplicationBacklog(size_t trim_blocks_limit) {
    // 从链表头部开始，释放 refcount=0 的 replBufBlock
    // 保留最近的 repl_backlog_size 字节

    while (server.repl_buffer_blocks && ...) {
        replBufBlock *o = listNodeValue(ln);
        if (o->refcount != 0) break;  // 仍有从节点引用此块

        // 从 blocks_index 中移除
        uint64_t encoded_offset = htonu64(o->repl_offset);
        raxRemove(server.repl_backlog->blocks_index,
                  (unsigned char*)&encoded_offset, sizeof(encoded_offset), NULL);

        // 释放块
        listDelNode(server.repl_buffer_blocks, ln);
    }
}
```

**裁剪原则**：只有 `refcount=0`（没有任何 slave 或 backlog 指向它）的块才能被释放。如果一个慢 slave 还在读取早期的块，那个块就保留。

---

## 8. 与系列前文的联系

```
写命令 → propagate()
  ├── feedAppendOnlyFile()      → AOF 缓冲区   (11)
  └── replicationFeedSlaves()   → repl_buffer_blocks → 共享给所有从节点
        ↓
      feedReplicationBuffer("SET key value")
        ↓
      追加到 replBufBlock 链表尾部
        ↓
      更新 master_repl_offset
        ↓
      beforesleep → writeToClient → 发送到从节点 socket
```

复制机制整合了前 13 篇文章中多个系统：

```
replication.c 涉及的模块：
├── RDB 全量同步      → rdbSaveRio / rdbLoadRio (10)
├── 命令传播          → networking.c writeToClient (09)
├── AOF 混合持久化    → aof.c (11)
├── eventsel    → aeCreateFileEvent (08)
├── dict/expires     → 键空间引擎 (13)
├── rax (blocks_index)→ raxInsert / raxRemove (07)
├── 子进程管理        → redisFork / waitpid
└── 连接管理          → connConnect / connWrite (09)
```

复制是 Redis 中最复杂的功能之一——它横跨持久化、网络、事件循环、键空间管理所有子系统。
