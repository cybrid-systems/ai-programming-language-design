# 09 — Networking：从连接建立到命令响应的全路径

> Redis 主线源码深度分析系列 · 第九篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前几篇拆解了 Redis 的数据结构（robj → sds → dict → listpack → skiplist → intset → rax）和事件驱动引擎（AE）。但数据结构和事件循环之间有一层关键的**网络层**——它负责把原始字节从 socket 解析成命令参数，再把执行结果序列化成 RESP 协议发回客户端。

整个请求→响应周期在 `networking.c`（4473 行）中实现：

```
TCP 连接 → accept   ← AE 事件循环触发
  ↓
创建 client           ← 分配内存、初始化状态
  ↓
readQueryFromClient   ← socket → querybuf（sds）
  ↓
processInputBuffer    ← 协议解析
  ├── processInlineBuffer     ← 简单文本协议
  └── processMultibulkBuffer  ← RESP 协议
  ↓
processCommand        ← server.c，命令分派
  ↓
addReply              ← 响应写入 output buffer
  ↓
handleClientsWithPendingWrites  ← beforesleep 中刷出
  └── writeToClient             ← output buffer → socket
```

**doom-lsp 确认**：核心文件

| 文件 | 行数 | 职责 |
|------|:----:|------|
| `src/networking.c` | 4473 | 网络层全实现 |
| `src/server.h:888-920` | — | clientReplyBlock / replBufBlock |
| `src/server.h:1094` | — | client 结构体 |
| `src/server.c` | ~7264 | accept 初始化 + processCommand |
| `src/anet.c` | — | TCP 套接字底层封装 |

---

## 1. 连接建立——从 TCP 到 client

### 1.1 acceptTcpHandler——AE 事件驱动的 accept

```c
// networking.c:1359 — doom-lsp 确认
void acceptTcpHandler(aeEventLoop *el, int fd, void *privdata, int mask) {
    int cport, cfd, max = MAX_ACCEPTS_PER_CALL;
    char cip[NET_IP_STR_LEN];
    UNUSED(el);
    UNUSED(mask);
    UNUSED(privdata);

    while (max--) {
        cfd = anetTcpAccept(server.neterr, fd, cip, sizeof(cip), &cport);
        if (cfd == ANET_ERR) {
            if (errno != EWOULDBLOCK)
                serverLog(LL_WARNING,
                    "Accepting client connection: %s", server.neterr);
            return;
        }
        serverLog(LL_VERBOSE,"Accepted %s:%d", cip, cport);
        acceptCommonHandler(connCreateAcceptedSocket(cfd, NULL), 0, cip);
    }
}
```

`MAX_ACCEPTS_PER_CALL = 1000`：防止大量 accept 消费者 CPU。超出限制的剩余连接下次事件循环处理。

### 1.2 acceptCommonHandler → createClient

```c
// networking.c:1359 → server.h:2475
// acceptCommonHandler 对连接做前置检查（如 maxclients 限制），然后调用：
client *createClient(connection *conn) {
    client *c = zmalloc(sizeof(client));         // ~400+ 字节的 client 结构体

    if (conn) {
        connEnableTcpNoDelay(conn);              // 禁用 Nagle 算法
        if (server.tcpkeepalive)
            connKeepAlive(conn, server.tcpkeepalive);
        connSetReadHandler(conn, readQueryFromClient);  // ★ 注册读事件处理器
        connSetPrivateData(conn, c);                     // 连接关联 client
    }

    c->buf = zmalloc_usable(PROTO_REPLY_CHUNK_BYTES, &c->buf_usable_size);
    // PROTO_REPLY_CHUNK_BYTES = 16*1024，响应静态缓冲区

    c->querybuf = sdsempty();                    // 请求缓冲区（sds）
    c->argc = 0, c->argv = NULL;                  // 待解析的命令参数
    c->reqtype = 0, c->multibulklen = 0;          // 解析状态
    c->reply = listCreate();                      // 响应链表
    c->reply_bytes = 0;
    c->sentlen = 0;
    c->flags = 0;
    c->resp = 2;                                  // 默认 RESP2

    if (conn) linkClient(c);                      // 加入 server.clients 链表
    return c;
}
```

**createClient 的关键工作**：
1. **分配 client 结构体** + 静态响应缓冲区（16KB）
2. **注册读事件**：`connSetReadHandler(conn, readQueryFromClient)`
3. **初始化所有协议解析状态**到初始值
4. **linkClient**：加入 `server.clients` 链表和 `server.clients_index`（rax）中

---

## 2. 读——readQueryFromClient

```c
// networking.c:2619 — doom-lsp 确认
void readQueryFromClient(connection *conn) {
    client *c = connGetPrivateData(conn);

    // 1. 如果 I/O 线程启用，推迟读取
    if (postponeClientRead(c)) return;

    // 2. 计算本次读取大小
    readlen = PROTO_IOBUF_LEN;                    // 16KB 默认读取量

    // 大参数优化：对大 bulk arg 只读必要的长度，避免 buffercopy
    if (c->reqtype == PROTO_REQ_MULTIBULK && c->multibulklen &&
        c->bulklen != -1 && c->bulklen >= PROTO_MBULK_BIG_ARG)
    {
        remaining = (c->bulklen+2) - (sdslen(c->querybuf)-c->qb_pos);
        if (remaining > 0) readlen = remaining;
    }

    // 3. 分配 querybuf 空间
    if (big_arg || sdsalloc(c->querybuf) < PROTO_IOBUF_LEN)
        c->querybuf = sdsMakeRoomForNonGreedy(c->querybuf, readlen);
    else
        c->querybuf = sdsMakeRoomFor(c->querybuf, readlen);

    // 4. 从 socket 读取数据到 querybuf
    nread = connRead(c->conn, c->querybuf + qblen, readlen);

    // 5. TCP 断开处理
    if (nread == 0) { freeClientAsync(c); return; }

    sdsIncrLen(c->querybuf, nread);
    c->lastinteraction = server.unixtime;

    // 6. querybuf 容量检查（client_max_querybuf_len 默认 1GB）
    if (sdslen(c->querybuf) > server.client_max_querybuf_len) {
        freeClientAsync(c);
        return;
    }

    // 7. 解析 + 执行
    if (processInputBuffer(c) == C_ERR) c = NULL;
}
```

**大参数优化**（`PROTO_MBULK_BIG_ARG` = 32KB）：当 parser 已经知道 `$<big_len>` 时，`readQueryFromClient` 只读取所需的字节数，而不是默认的 16KB。这样 querybuf 不会因为大 bulk 而浪费预分配空间。

---

## 3. 协议解析——processInputBuffer

### 3.1 总体流程

```c
// networking.c:2523 — doom-lsp 确认
int processInputBuffer(client *c) {
    while (c->qb_pos < sdslen(c->querybuf)) {
        // 前置退出检查：
        if (c->flags & CLIENT_BLOCKED) break;
        if (c->flags & CLIENT_PENDING_COMMAND) break;
        if (c->flags & (CLIENT_CLOSE_AFTER_REPLY|CLIENT_CLOSE_ASAP)) break;

        // 自动检测协议类型
        if (!c->reqtype) {
            if (c->querybuf[c->qb_pos] == '*')      // RESP 协议
                c->reqtype = PROTO_REQ_MULTIBULK;
            else                                     // 内联协议
                c->reqtype = PROTO_REQ_INLINE;
        }

        // 协议解析
        if (c->reqtype == PROTO_REQ_INLINE)
            processInlineBuffer(c);
        else
            processMultibulkBuffer(c);

        if (c->argc == 0) { resetClient(c); continue; }

        // 执行命令
        if (processCommandAndResetClient(c) == C_ERR)
            return C_ERR;
    }

    // 清理已处理的 querybuf 数据
    if (c->qb_pos)
        sdsrange(c->querybuf, c->qb_pos, -1);
    c->qb_pos = 0;
}
```

**querybuf 的 sdsrange 裁剪**：每次处理完一批命令后，将 `c->qb_pos` 之前的数据从 sds 中裁剪掉。对于 pipeline（多个命令一次性到达），while 循环会逐个解析执行，直到 querybuf 耗尽。

### 3.2 processMultibulkBuffer——RESP 协议解析

RESP 命令格式：`*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n`

```c
// networking.c:2264 — doom-lsp 确认
int processMultibulkBuffer(client *c) {
    char *newline = NULL;
    long long ll;

    if (c->multibulklen == 0) {
        // ★ 读取 *<N> 命令参数个数
        newline = strchr(c->querybuf+c->qb_pos, '\r');
        // 解析：*3\r\n → multibulklen = 3

        ok = string2ll(c->querybuf+c->qb_pos+1, newline-(c->querybuf+c->qb_pos+1), &ll);
        c->multibulklen = ll;

        c->qb_pos += (newline-c->querybuf-c->qb_pos)+2;  // 跳过 \r\n
    }

    // ★ 逐个读取参数
    while (c->multibulklen) {
        if (c->bulklen == -1) {
            // 读取 $<len> 行
            newline = strchr(c->querybuf+c->qb_pos, '\r');
            ok = string2ll(c->querybuf+c->qb_pos+1, ..., &ll);
            c->bulklen = ll;
            c->qb_pos += ...;  // 跳过 $<len>\r\n
        }

        // 等待整条数据到达
        if (sdslen(c->querybuf)-c->qb_pos < (size_t)c->bulklen+2)
            break;  // 数据未到齐，返回等待更多数据

        // ★ 零拷贝优化：直接引用 querybuf 中的字符串
        if (c->bulklen > PROTO_MBULK_BIG_ARG) {
            // 大 bulk：直接引用指针，不拷贝
            c->argv[c->argc] = createObject(OBJ_STRING,
                sdsnewlen(c->querybuf+c->qb_pos, c->bulklen));
        } else {
            // 小 bulk：先创建 sds，再转为 robj
            c->argv[c->argc] = createStringObject(
                c->querybuf+c->qb_pos, c->bulklen);
        }
        c->argc++;
        c->bulklen = -1;
        c->multibulklen--;
        c->qb_pos += len+2;  // 跳过数据 + \r\n
    }

    return c->multibulklen == 0 ? C_OK : C_ERR;
}
```

**关键优化**：零拷贝大参数。对于大于 `PROTO_MBULK_BIG_ARG`（32KB）的 bulk 参数，直接在 querybuf 中引用来创建 sds，不会额外拷贝数据（`sdsnewlen` 会分配新内存，但后续的 `createObject` 包装直接引用它；querybuf 本身的内容在 `sdsrange` 裁剪时释放）。

**状态机的三个变量**：
- `c->multibulklen`：剩余待读取的参数数
- `c->bulklen`：当前参数的字节长度（-1 表示正在读 `$<len>`）
- `c->qb_pos`：querybuf 中的已处理位置

### 3.3 processInlineBuffer——内联协议

```c
// networking.c:2146 — doom-lsp 确认
int processInlineBuffer(client *c) {
    // 查找 \n
    newline = strchr(c->querybuf+c->qb_pos, '\n');
    // 处理 \r\n 和 \n 两种换行

    // 按空格分割
    aux = sdsnewlen(c->querybuf+c->qb_pos, querylen);
    argv = sdssplitargs(aux, &argc);

    // 创建 robj 数组
    for (j = 0; j < argc; j++) {
        c->argv[c->argc] = createObject(OBJ_STRING, argv[j]);
        c->argv_len_sum += sdslen(argv[j]);
    }
}
```

用于 `TELNET` 风格的交互或简单的 `PING`、`QUIT`。Redis 官网建议生产环境使用 RESP 协议。

---

## 4. 写——addReply → writeToClient

### 4.1 输出缓冲区的两层架构

```c
// server.h:888-892 — doom-lsp 确认
typedef struct clientReplyBlock {
    size_t size, used;
    char buf[];              // 柔性数组，至少 16KB
} clientReplyBlock;
```

Redis 的输出缓冲有两层：

```
client->buf               （静态 16KB 缓冲区，快速路径）
  └── 满了 → client->reply （链表，每个节点是 clientReplyBlock）
```

### 4.2 addReply——写入响应

```c
// networking.c:407 — doom-lsp 确认
void addReply(client *c, robj *obj) {
    if (prepareClientToWrite(c) != C_OK) return;

    // ★ 先尝试写入静态缓冲区
    if (_addReplyToBuffer(c, obj->ptr, sdslen(obj->ptr)) > 0) {
        // 全部写入静态缓冲区 → 完成
    } else {
        // 静态缓冲区满了 → 写入 reply 链表
        _addReplyProtoToList(c, obj->ptr, sdslen(obj->ptr));
    }
}
```

**prepareClientToWrite**（`networking.c:284`）：检查 client 是否需要发送响应（fake client? master? CLIENT REPLY OFF?），如果需要，调用 `putClientInPendingWriteQueue` 把 client 加入 `server.clients_pending_write` 链表。

### 4.3 handleClientsWithPendingWrites——beforesleep 中刷出

```c
// networking.c:2041 — doom-lsp 确认
int handleClientsWithPendingWrites(void) {
    listRewind(server.clients_pending_write, &li);
    while ((ln = listNext(&li))) {
        client *c = listNodeValue(ln);

        // ★ 尝试同步写（非阻塞 write）
        if (writeToClient(c, 0) == C_ERR) continue;

        // ★ 如果还没写完，安装写事件处理器
        if (clientHasPendingReplies(c)) {
            installClientWriteHandler(c);
        }
    }
}
```

这个函数在 `beforesleep` 中调用。设计目标：**尽量在进入 epoll_wait 之前就把响应发出去**，避免一次 epoll 事件注册的系统调用。

- 如果一次 write 就发完了 → 不需要注册写事件
- 如果写不完（socket buffer 满） → `installClientWriteHandler` 注册写事件

### 4.4 writeToClient——实际写入

```c
// networking.c:1957 — doom-lsp 确认
int writeToClient(client *c, int handler_installed) {
    totwritten = 0;
    while (clientHasPendingReplies(c)) {
        ret = _writeToClient(c, &nwritten);
        totwritten += nwritten;

        // 单次事件循环写出量限制
        if (totwritten > NET_MAX_WRITES_PER_EVENT &&
            (server.maxmemory == 0 ||
             zmalloc_used_memory() < server.maxmemory) &&
            !(c->flags & CLIENT_SLAVE)) break;
    }

    // 如果所有数据已写完，删除写事件处理器
    if (!clientHasPendingReplies(c)) {
        if (handler_installed)
            connSetWriteHandler(c->conn, NULL);
    }
}
```

`NET_MAX_WRITES_PER_EVENT = 1024 * 64`（64KB）。单次事件循环最大写出 64KB，防止一个 fast client 占满事件循环。

**写优先级**：
1. 先写 `client->buf`（静态缓冲区）
2. 再写 `client->reply` 链表中的 `clientReplyBlock` 节点
3. 写入使用 `writev`（如果有的话）或 `write`

### 4.5 安装写事件——installClientWriteHandler

```c
// networking.c:219 — doom-lsp 确认
void installClientWriteHandler(client *c) {
    int ae_barrier = 0;
    // AOF fsync=always 时设置写屏障
    if (server.aof_state == AOF_ON &&
        server.aof_fsync == AOF_FSYNC_ALWAYS)
    {
        ae_barrier = 1;
    }
    connSetWriteHandlerWithBarrier(c->conn, sendReplyToClient, ae_barrier);
}
```

当 `AOF_FSYNC_ALWAYS` 时设置 `AE_BARRIER`，确保 `beforesleep` 中先 fsync AOF 再回复客户端。

---

## 5. 完整请求→响应周期

### 5.1 无 I/O 线程路径

```
事件循环     │  beforesleep     │  epoll_wait     │  事件处理
─────────────┼──────────────────┼─────────────────┼─────────────────
  beforeSleep │ handlePending     │                 │  
              │ writes → 发旧响应  │                 │
              │ AOF flush         │                 │
─────────────┼──────────────────┼─────────────────┼─────────────────
  epoll_wait │                  │ 阻塞等待          │
             │                  │ client 发来命令   │
             │                  │ socket 可读       │
─────────────┼──────────────────┼─────────────────┼─────────────────
  事件处理    │                  │                  │ readQueryFromClient
             │                  │                  │   → read() 读 socket
             │                  │                  │   → processInputBuffer
             │                  │                  │     → processMultibulkBuffer
             │                  │                  │     → processCommand
             │                  │                  │       → SET key value
             │                  │                  │     → addReply("+OK\r\n")
             │                  │                  │         → putClientInPendingWriteQueue
```

第一次 `beforesleep` 处理 pending writes：尝试 `writeToClient` 发 OK。如果一次写完，事件循环不开写事件。如果写不完，`installClientWriteHandler` 注册 `EPOLLOUT`。

### 5.2 I/O 线程路径

```
beforesleep → handleClientsWithPendingReadsUsingThreads()
  │ I/O 线程并行读取多个 client 的 socket 数据到 querybuf
  │ 主线程继续执行其他工作

beforesleep → handleClientsWithPendingWrites()
  │ I/O 线程并行写入多个 client 的 output buffer
  │ 主线程继续执行其他工作

事件处理 → 主线程串行解析 + 执行命令
```

I/O 线程只是分担网络数据的**读入**和**写出**，命令解析和执行的瓶颈仍然在单线程上。

---

## 6. client 生命周期

```
acceptTcpHandler → acceptCommonHandler → createClient
  → connSetReadHandler(readQueryFromClient)
  → linkClient → server.clients 链表 + server.clients_index rax
  ↓
readQueryFromClient (循环)
  ↓
close: freeClientAsync(client)
  → CLIENT_CLOSE_ASAP 标志
  → 下次 beforesleep: freeClientsInAsyncFreeQueue
    → unlinkClient → 从 server.clients 链表中移除
    → connClose → 关闭 socket
    → zfree → 释放内存
```

**freeClientAsync 为什么是异步的**：不能在事件处理中直接 free client（可能在调用栈中引用 `c`）。设置 `CLIENT_CLOSE_ASAP` 标志，在 `beforesleep` 的安全位置调用 `freeClientsInAsyncFreeQueue` 统一释放。

---

## 7. 分析一览

### 7.1 关键常量

| 常量 | 值 | 位置 |
|------|:---:|------|
| `PROTO_IOBUF_LEN` | 16KB | server.h |
| `PROTO_REPLY_CHUNK_BYTES` | 16KB | server.h |
| `PROTO_MBULK_BIG_ARG` | 32KB | server.h |
| `PROTO_INLINE_MAX_SIZE` | 64KB | server.h |
| `NET_MAX_WRITES_PER_EVENT` | 64KB | networking.c 顶部 |
| `MAX_ACCEPTS_PER_CALL` | 1000 | networking.c |
| `client_max_querybuf_len` | 1GB | config.c |

### 7.2 网络层与系列前文的关系

```
CLIENT: "SET mykey HelloWorld\r\n"
  ↓
readQueryFromClient           ← AE 可读事件（第八篇）
  → sds querybuf 累积         ← sds（第二篇）
  ↓
processMultibulkBuffer         ← RESP 协议解析
  → createStringObject(...)    ← robj（第一篇）
  ↓
processCommand(server.c)
  → dictFind(commands, "SET") ← dict（第三篇）
  → setCommand(t_string.c)
    → createStringObject("HelloWorld")
      → sdsnewlen("HelloWorld", 10)  ← sds（第二篇）
  ↓
addReply("+OK\r\n")            ← 写入 client->buf / client->reply
  ↓
beforesleep → handleClientsWithPendingWrites
  → writeToClient → connWrite   ← socket 写出
```

从 socket 读到 socket 写回，全部 9 篇文章覆盖的组件在一条路径上完整串联。
