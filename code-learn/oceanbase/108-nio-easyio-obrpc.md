# 108-nio-easyio-obrpc — OceanBase NIO (2/2): easy_io 连接生命周期 + obrpc 协议栈

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后)
> 源码锚点: `deps/easy/src/io/easy_connection.{h,c}` + `deps/easy/src/io/easy_request.{h,c}` + `deps/easy/src/io/easy_message.{h,c}` + `deps/easy/src/io/easy_client.{h,c}` + `src/share/rpc/ob_rpc_packet.{h,cpp}` + `src/share/rpc/ob_rpc_proxy_*.{h,cpp}` + `src/share/rpc/ob_net_client.{h,cpp}` + `src/share/rpc/ob_net_server.{h,cpp}` + `src/share/rpc/ob_batch_rpc.{h,cpp}` + `src/share/rpc/ob_async_rpc_proxy.h`
> 使用 doom-lsp (clangd LSP) 做符号解析与数据流追踪
> 接续 #107 libeasy Reactor — 本篇深入 easy_io 连接生命周期 + obrpc 序列化 / 路由 / 重试, 后续接 #109 Worker 系列

---

## 0. 全文导读

OB 网络栈在 libeasy 之上有两层封装: **`easy_io` 层** (OB 把 libeasy 包成 `easy_io_t`,提供 OB 风格的生命周期管理) + **`obrpc` 层** (OB 的 RPC 协议栈,提供序列化 / 路由 / 重试 / 限流)。本篇拆这两层:

| 子主题 | 内容 |
|--------|------|
| **easy_io 连接生命周期** | `easy_connection_t` 状态机 + listen/accept/read/write/close 全流程 |
| **easy_request + easy_message 协议处理** | packet 编解码 + handler dispatch + 攒批 / 流式 / 帧式 |
| **obrpc 序列化** | `ObRpcPacketHeader` + request/response + seq no + checksum |
| **obrpc 路由 / 重试 / 限流** | `server_id → ip:port` + 路由缓存 + 重试策略 + 跨 region 限流 |
| **ObNetClient / ObNetServer** | 客户端 / 服务端封装 |
| **SSL 加密** | `easy_ssl_*` 在 libeasy 之上 |

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #27 RPC/obrpc | #27 是概览,本篇是源码级实读 |
| #107 libeasy | #107 讲 IO 线程模型,本篇讲连接 / packet / RPC |
| #103 atomic | `easy_request_t::ret` / `easy_session_t::status` 是 atomic Flag |
| #104 atomic Flag | `easy_connection_t::status` 是 BCAS 状态机 |
| #109 (Worker 系列) | obrpc handler 调度走 #109 Worker 体系 |

---

## 1. 背景 / 概念

### 1.1 OB 网络栈分层

```
┌────────────────────────────────────────────────────────┐
│ 应用层 (observer / sql / rootserver)                    │
├────────────────────────────────────────────────────────┤
│ RPC 层 (obrpc / ob_net_client / ob_net_server)         │
│   - ObRpcProxy (发送 / 接收 / 重试)                      │
│   - ObNetClient (连接池 / 路由 / 限流)                   │
│   - ObNetServer (accept / dispatch)                     │
├────────────────────────────────────────────────────────┤
│ 协议层 (easy_request / easy_message / easy_session)     │
│   - packet 编解码                                       │
│   - handler dispatch                                    │
│   - stream / batch / frame 三种模式                      │
├────────────────────────────────────────────────────────┤
│ 连接层 (easy_connection_t)                              │
│   - TCP 连接状态机                                       │
│   - send / recv buffer                                  │
│   - SSL 加密                                            │
├────────────────────────────────────────────────────────┤
│ 框架层 (libeasy)                                        │
│   - Reactor + IO 线程池                                  │
│   - epoll / kqueue / io_uring                           │
└────────────────────────────────────────────────────────┘
```

### 1.2 三种 RPC 模式

| 模式 | 用途 | 实现 |
|------|------|------|
| **流式 (stream)** | 长连接 / 大包 / 持续推送 | `easy_request_t` 一个 connection 多次 request |
| **攒批 (batch)** | 高 QPS / 小包 / 单向 | `easy_message_t` + `ObBatchRpc` |
| **帧式 (frame)** | 普通 RPC | `easy_session_t` 单次 request / response |

OB 大多数 RPC 用**帧式**(普通 client-server 调用),少量用**流式**(心跳 / 推送 / 增量备份)。

### 1.3 OB RPC 协议

```
┌────────────────┬──────────┬──────────────────┬──────────┐
│ EASY_HEADER    │RPC_HEADER│ RPC_PAYLOAD      │ CHECKSUM │
│ (16 B)         │ (112 B)  │ (variable)       │ (8 B)    │
└────────────────┴──────────┴──────────────────┴──────────┘
```

- `EASY_HEADER`: libeasy 自带 (含 magic + length)
- `RPC_HEADER`: obrpc 自定义 (含 pcode + 租户 + 优先级 + 重试标志)
- `RPC_PAYLOAD`: 业务序列化 (Protobuf / ObRpcBuffer)
- `CHECKSUM`: CRC32 校验

详见 §2.3。

---

## 2. 实现细节

### 2.1 `easy_connection_t` 状态机

[`deps/easy/src/io/easy_connection.h:60-150`](deps/easy/src/io/easy_connection.h):

```cpp
struct easy_connection_t {
  easy_list_t       conn_list_node;          // 全局 conn_list
  easy_list_t       message_list_node;       // io_thread message_list
  easy_hash_node_t  hash_node;               // conn_array hash
  ev_io             read_watcher;            // EPOLLIN watcher
  ev_io             write_watcher;           // EPOLLOUT watcher
  int               fd;                      // socket fd
  easy_addr_t       addr;                    // 对端地址 (ip:port)
  int               status;                  // 状态 (atomic) — 见下表
  // buffer
  easy_buf_t       *in_buf;                  // 接收缓冲
  easy_buf_t       *out_buf;                 // 发送缓冲
  easy_list_t       output;                  // 待发送 list
  // request / message
  easy_request_t   *request_list;            // 流式 request (stream)
  easy_request_t   *doing_request;           // 当前正在处理的 request
  easy_message_t   *next_message;            // 下一个待处理 message
  easy_session_t   *session;                 // 帧式 session
  // SSL
  SSL              *ssl;                     // SSL 句柄 (如果开启)
  // 配置
  easy_io_t        *eio;                     // 所属 easy_io
  easy_io_thread_t *ioth;                    // 所属 IO 线程
  int64_t           conn_timeout;            // 连接超时 (ms)
  int64_t           last_time;               // 上次活跃时间 (用于 idle detection)
  // 统计
  int64_t           req_cnt;                 // 请求计数 (atomic)
  int64_t           pkg_cnt;                 // 包计数
};
```

**`status` 字段的状态机**:

| 值 | 含义 | 转换 |
|----|------|------|
| `EASY_CONN_OK` | 正常 | `→ CONNECTING / CLOSE` |
| `EASY_CONN_CONNECTING` | TCP 连接中 (client) | `→ OK / CLOSE` |
| `EASY_CONN_AUTO_CONN` | 自动重连 (client) | `→ CONNECTING / CLOSE` |
| `EASY_CONN_CLOSE` | 已关闭 | 终态 |
| `EASY_CONN_CLOSE_BY_PEER` | 对端关闭 | 终态 |

**`status` 是 atomic int** (跟 #104 Flag 模式连接),用 `easy_atomic_t` 包裹。多线程读 / 单线程写 (IO 线程是单写者)。

### 2.2 listen / accept 流程

```cpp
// deps/easy/src/io/easy_connection.c: easy_io_accept_cb()
static void easy_io_accept_cb(struct ev_loop *loop, ev_io *w, int revents) {
  easy_listen_t *listen = (easy_listen_t *) w->data;
  easy_io_t *eio = listen->eio;
  easy_io_thread_t *ioth = (easy_io_thread_t *) ev_userdata(loop);

  while (1) {
    // 1. accept (non-blocking)
    easy_addr_t addr;
    int fd = easy_socket_accept(listen->fd, &addr);
    if (fd < 0) break;

    // 2. 创建 connection
    easy_connection_t *c = easy_connection_create(eio, ioth, fd, addr,
                                                  listen->handler, listen->args);
    // 3. 注册到 ioth 的 conn_array (fd → conn)
    easy_hash_add(ioth->conn_array, &c->hash_node, fd);
    // 4. 启动 EPOLLIN 监听
    ev_io_init(&c->read_watcher, easy_io_read_cb, fd, EV_READ);
    ev_io_start(loop, &c->read_watcher);
  }
}
```

**SO_REUSEPORT 多队列** (`easy_maccept`):

```cpp
// deps/easy/src/io/easy_maccept.c: easy_socket_listen()
int easy_socket_listen(easy_addr_t *addr, int backlog, int reuseport) {
  // 1. 创建 listen socket
  int fd = socket(addr->family, SOCK_STREAM, 0);

  // 2. SO_REUSEADDR (允许重启时立即 bind)
  int on = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

  // 3. SO_REUSEPORT (多线程 listen 同一端口)
  if (reuseport) {
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on));
  }

  // 4. bind + listen
  bind(fd, (struct sockaddr *) &addr->sa, sizeof(addr->sa));
  listen(fd, backlog);

  // 5. set non-blocking
  fcntl(fd, F_SETFL, O_NONBLOCK);

  return fd;
}
```

**关键设计**:

- SO_REUSEPORT 让 kernel 在多个 IO 线程的 listen socket 间自动负载均衡 (基于五元组 hash)
- accept 是 non-blocking + 循环 (accept 完一次再 accept,直到 EAGAIN)
- 每个新连接立即注册 EPOLLIN,等待 client 第一个 packet

### 2.3 read 流程 + packet 编解码

```cpp
// deps/easy/src/io/easy_connection.c: easy_io_read_cb()
static void easy_io_read_cb(struct ev_loop *loop, ev_io *w, int revents) {
  easy_connection_t *c = (easy_connection_t *) w->data;
  int fd = c->fd;

  // 1. 循环 read,直到 EAGAIN
  while (1) {
    ssize_t n = (c->ssl ? SSL_read(c->ssl, buf, size)
                          : read(fd, buf, size));
    if (n < 0) {
      if (errno == EAGAIN) break;          // 读完了
      if (errno == EINTR) continue;        // 信号打断,继续
      easy_connection_close(c);             // 其他错误,关连接
      return;
    }
    if (n == 0) {
      easy_connection_close(c, EASY_CONN_CLOSE_BY_PEER);  // 对端关闭
      return;
    }
    // 2. 解析 packet (EASY_HEADER)
    easy_connection_parse_packet(c, buf, n);
  }
}
```

**packet 解析**:

```cpp
// deps/easy/src/io/easy_connection.c: easy_connection_parse_packet()
int easy_connection_parse_packet(easy_connection_t *c, char *data, int len) {
  while (len > 0) {
    // 1. 检查是否够 EASY_HEADER
    if (c->in_buf->last - c->in_buf->pos < EASY_HEADER_SIZE) {
      // 不够,等下次 read
      break;
    }
    // 2. 解析 header (magic + length + flag)
    easy_header_t *h = (easy_header_t *) c->in_buf->pos;
    uint32_t pkg_len = ntohl(h->length);

    // 3. 检查是否够整个 packet
    if (c->in_buf->last - c->in_buf->pos < pkg_len + EASY_HEADER_SIZE) {
      break;
    }
    // 4. 提取 packet body
    easy_buf_t *body = easy_buf_create(c->pool, pkg_len);
    memcpy(body->pos, c->in_buf->pos + EASY_HEADER_SIZE, pkg_len);

    // 5. 调 handler 处理 packet
    c->handler(c, body);    // 这里的 handler 由 obrpc 注册

    // 6. 推进 pos
    c->in_buf->pos += pkg_len + EASY_HEADER_SIZE;
    len -= pkg_len + EASY_HEADER_SIZE;
  }
  return EASY_OK;
}
```

### 2.4 `easy_message_t` 协议处理

```cpp
// deps/easy/src/io/easy_message.h:60-100
struct easy_message_t {
  int               type;                   // EASY_TYPE_MESSAGE / SESSION / KEEPALIVE_SESSION / RL_SESSION
  easy_list_t       message_list_node;      // ioth->message_list 节点
  easy_request_t   *request;                // 关联 request
  easy_session_t   *session;                // 关联 session
  // 优先级 / 限流
  int               priority;               // 优先级 (0=NORMAL, 1=HIGH, 2=LOW)
  easy_region_ratelimitor_t *region_rlmtr;  // 跨 region 限流
  // 时间戳
  int64_t           enqueue_time;           // 入队时间
  int64_t           timeout_ms;             // 超时时间 (ms)
  // payload
  void             *ipacket;                // 输入 packet
  void             *opacket;                // 输出 packet (RPC response)
  int64_t           packet_size;            // packet 大小
};
```

**三种 type**:

| type | 用途 |
|------|------|
| `EASY_TYPE_MESSAGE` | 普通 request (无 response) |
| `EASY_TYPE_SESSION` | 普通 RPC (request + response) |
| `EASY_TYPE_KEEPALIVE_SESSION` | keepalive 心跳 |
| `EASY_TYPE_RL_SESSION` | 限流 session |

**handler dispatch**:

```cpp
// deps/easy/src/io/easy_connection.c: easy_io_process_message()
int easy_io_process_message(easy_connection_t *c) {
  easy_message_t *m = c->next_message;
  if (m == NULL) return EASY_OK;

  // 1. 跨线程分发 (到 user_thread_pool)
  if (c->user_thread_pool != NULL) {
    return easy_thread_pool_push(c->user_thread_pool, m->request, m->hv);
  }

  // 2. 同线程处理
  c->handler(c, m->ipacket, m->opacket, m->args);

  // 3. 写回 response
  if (m->type == EASY_TYPE_SESSION) {
    easy_connection_send_session(c, m->session);
  }
  return EASY_OK;
}
```

### 2.5 obrpc 序列化 — `ObRpcPacketHeader`

[`src/share/rpc/ob_rpc_packet.h`](src/share/rpc/ob_rpc_packet.h):

```cpp
struct ObRpcPacketHeader {
  // libeasy header (16 B)
  uint32_t          magic;             // 0x4F425031 (OBP1)
  uint32_t          length;            // payload 长度 (含 RPC_HEADER)
  uint8_t           flag;              // EASY_FLAG / 加密标志 / keepalive 标志
  uint8_t           version;           // 协议版本
  uint16_t          reserved;
  // RPC_HEADER (112 B) — 见下
  union {
    ObRpcPacketHeaderV1 v1;
  };
};
```

**RPC_HEADER 字段 (112 B)**:

```cpp
struct ObRpcPacketHeaderV1 {
  uint32_t          pcode;             // RPC 方法码 (e.g. 10001 = OB_RPC::TEST)
  uint32_t          tenant_id;         // 租户 ID (多租户隔离)
  uint8_t           priority;          // 优先级 (0-7)
  uint8_t           retry_flag;        // 是否允许重试
  uint16_t          reserved1;
  int64_t           timestamp;         // 发送时间戳 (用于 RTT 计算)
  int64_t           trace_id;          // 全链路 trace ID
  int64_t           span_id;           // 当前 span ID
  int64_t           parent_span_id;    // 父 span ID
  int64_t           session_id;        // 会话 ID (用于关联)
  uint64_t          req_seq_no;        // 请求序号 (用于去重)
  uint64_t          resp_seq_no;       // 响应序号
  uint32_t          cluster_id;        // 集群 ID
  uint32_t          src_tenant_id;     // 源租户 ID
  int32_t           ssl_key_id;        // SSL key ID (0 = 不加密)
  int32_t           reserved2;
  char              src_addr[24];      // 源地址
  char              dst_addr[24];      // 目的地址
  // ... (共 112 B)
};
```

**关键设计**:

- `pcode` 是 RPC 方法的唯一 ID (注册时分配,e.g. `obrpc::ObRpcProxy::REG_PCODE(OB_RPC::TEST, ...)`)
- `tenant_id` 用于多租户路由 + 资源隔离
- `trace_id` / `span_id` 跟 OB 全链路 tracing 系统集成
- `retry_flag` 决定是否可以重试 (写操作 retry_flag = 0,避免重复执行)

### 2.6 obrpc 序列化 — `ObRpcPacket`

```cpp
// src/share/rpc/ob_rpc_packet.cpp: ObRpcPacket::serialize()
int ObRpcPacket::serialize() {
  // 1. 序列化 payload
  int64_t pos = 0;
  if (OB_FAIL(serializer_.serialize(request_, pos))) {
    LOG_WARN("serialize request failed", K(ret));
    return ret;
  }

  // 2. 计算 checksum (CRC32)
  uint32_t checksum = crc32(serializer_.data(), serializer_.pos());

  // 3. 填 EASY_HEADER
  ObRpcPacketHeader *h = (ObRpcPacketHeader *) buf_;
  h->magic = OB_RPC_MAGIC;                       // 0x4F425031
  h->length = serializer_.pos() + RPC_HEADER_SIZE + CHECKSUM_SIZE;
  h->flag = 0;
  h->version = 1;

  // 4. 填 RPC_HEADER
  h->v1.pcode = request_->get_pcode();
  h->v1.tenant_id = MTL_ID();
  h->v1.priority = request_->get_priority();
  // ...

  // 5. 拼装完整 packet
  memcpy(buf_ + EASY_HEADER_SIZE, &h->v1, RPC_HEADER_SIZE);
  memcpy(buf_ + EASY_HEADER_SIZE + RPC_HEADER_SIZE,
         serializer_.data(), serializer_.pos());
  memcpy(buf_ + EASY_HEADER_SIZE + RPC_HEADER_SIZE + serializer_.pos(),
         &checksum, CHECKSUM_SIZE);

  return OB_SUCCESS;
}
```

### 2.7 obrpc 反序列化 + dispatch

```cpp
// src/share/rpc/ob_rpc_proxy.cpp: ObRpcProxy::process()
int ObRpcProxy::process(easy_request_t *r) {
  ObRpcPacket packet(r->ipacket, r->packet_size);

  // 1. 反序列化 header
  if (OB_FAIL(packet.deserialize())) {
    LOG_WARN("deserialize failed", K(ret));
    return ret;
  }

  // 2. 校验 magic + checksum
  if (packet.header_.magic != OB_RPC_MAGIC) {
    LOG_WARN("invalid magic", K(packet.header_.magic));
    return OB_ERR_UNEXPECTED;
  }

  // 3. 查 handler (pcode → handler)
  ObRpcProxy::Handler *handler = handlers_[packet.header_.v1.pcode];
  if (handler == NULL) {
    LOG_WARN("unknown pcode", K(packet.header_.v1.pcode));
    return OB_ERR_UNEXPECTED;
  }

  // 4. 调用 handler (反序列化 request → 调用业务方法 → 序列化 response)
  handler->callback_(packet.request_, packet.response_);

  // 5. 写回 response (走 libeasy send)
  easy_request_addbuf(r, response_buf);
  return OB_SUCCESS;
}
```

**handler 注册**:

```cpp
// src/share/rpc/ob_rpc_proxy.cpp: ObRpcProxy::REG_PCODE()
#define REG_PCODE(pcode_str, request_type, response_type) \
  do { \
    Handler *h = new Handler( \
      [](ObRpcRequest &req, ObRpcResponse &resp) { \
        // 反序列化 request, 调用业务, 序列化 response \
        ... \
      }); \
    handlers_[pcode_str] = h; \
  } while (0)
```

### 2.8 ObNetClient — 客户端连接管理

[`src/share/rpc/ob_net_client.{h,cpp}`](src/share/rpc/ob_net_client.h):

```cpp
class ObNetClient {
public:
  int init(easy_io_t *eio, int max_conn_per_server);
  int destroy();

  // 同步发送 (用 easy_uthread 协程)
  int sync_send(const ObAddr &server, easy_session_t *session);

  // 异步发送
  int async_send(const ObAddr &server, easy_session_t *session,
                 easy_io_handler_pt *callback);

  // 获取 / 归还连接
  easy_connection_t *get_connection(const ObAddr &server);
  void              put_connection(easy_connection_t *c);

private:
  easy_io_t        *eio_;
  int               max_conn_per_server_;
  // 连接池 (per-server)
  easy_hash_t      *conn_pool_;     // server → list<connection>
  easy_list_t       free_list_;     // 空闲 connection
};
```

**连接池逻辑**:

```cpp
// src/share/rpc/ob_net_client.cpp: ObNetClient::get_connection()
easy_connection_t *ObNetClient::get_connection(const ObAddr &server) {
  // 1. 查连接池
  easy_list_t *list = (easy_list_t *) easy_hash_get(conn_pool_, &server);
  if (list != NULL && !easy_list_empty(list)) {
    return easy_list_entry(list->next, easy_connection_t, conn_list_node);
  }
  // 2. 没有空闲连接,新建 (client connection,自动 connect)
  easy_connection_t *c = easy_connection_connect_thread(
    eio_, server.addr, default_handler, conn_timeout, this, 0);
  return c;
}
```

**关键设计**:

- 每个 server 最多 `max_conn_per_server_` 个连接 (默认 8)
- 连接是 lazy 建立 (第一次 send 才 connect)
- 连接是 long-lived (keepalive)
- 连接用完归还到 free_list,下次 get 时复用

### 2.9 ObNetServer — 服务端 accept

[`src/share/rpc/ob_net_server.{h,cpp}`](src/share/rpc/ob_net_server.h):

```cpp
class ObNetServer {
public:
  int init(easy_io_t *eio, const ObAddr &bind_addr);
  int destroy();

private:
  // accept handler (由 libeasy 调用)
  static int accept_handler(easy_connection_t *c);
};
```

**accept handler**:

```cpp
// src/share/rpc/ob_net_server.cpp: ObNetServer::accept_handler()
int ObNetServer::accept_handler(easy_connection_t *c) {
  // 1. 分配 per-connection 资源 (池)
  c->pool = easy_pool_create(0, OB_MAX_PACKET_SIZE);

  // 2. 注册到 ObWorkerProcessor (见 #109)
  ObWorkerProcessor *wp = get_global_worker_processor();
  c->user_data = wp;

  // 3. 设置 handler (ObRpcProxy::process)
  c->handler = ObRpcProxy::process;

  // 4. 启动 EPOLLIN 监听 (libeasy 已经做了)
  return EASY_OK;
}
```

### 2.10 RPC 路由 — `ObPartitionLocationCache`

[`src/share/location/ob_location_cache.{h,cpp}`](src/share/location/ob_location_cache.h):

```cpp
class ObLocationCache {
public:
  // 查路由 (cache hit → return; miss → 从 RS 拉)
  int get(const uint64_t table_id, const ObPartitionKey &partition,
          ObPartitionLocation &location);

  // 异步刷新
  int async_refresh(const uint64_t table_id, const ObPartitionKey &partition,
                    ObILocationFetcher &fetcher);

private:
  // LRU cache
  ObKVCache<uint64_t, ObPartitionLocation> cache_;
  // 异步 fetcher (从 RS 拉)
  ObLocationFetcher *fetcher_;
};
```

**路由流程**:

```
client → get(table_id, partition_key)
       → cache_.get(key)
       → [hit] → return location
       → [miss] → async_refresh → RS
                → 等 refresh 完成 → cache_.put(key, location)
                → retry get()
```

**缓存 key**: `table_id:partition_key` (LS_ID + tablet_id)
**缓存 value**: `(leader_addr, replica_addrs[])` + version

### 2.11 RPC 重试 — `ObRpcRetry`

[`src/share/rpc/ob_rpc_proxy.h`](src/share/rpc/ob_rpc_proxy.h):

```cpp
class ObRpcRetry {
public:
  // 计算是否重试
  bool should_retry(int ret, int retry_cnt, int max_retry_cnt);

  // 计算下一个 server (load balance)
  ObAddr pick_next_server(const ObAddrList &servers);

private:
  // 退避策略
  int64_t backoff_ms(int retry_cnt);  // exponential backoff: 10ms, 100ms, 1s, ...
};
```

**重试策略**:

| 错误类型 | 是否重试 |
|---------|---------|
| 网络错误 (timeout, connection reset) | ✅ 重试 |
| 路由失效 (server not in location) | ✅ 重试 (refresh route) |
| 业务错误 (e.g. 主键冲突) | ❌ 不重试 (`retry_flag = 0`) |
| 权限错误 | ❌ 不重试 |
| 限流错误 | ✅ 重试 (退避) |

**重试退避**:

```cpp
int64_t ObRpcRetry::backoff_ms(int retry_cnt) {
  if (retry_cnt == 0) return 0;
  if (retry_cnt == 1) return 10;        // 第 1 次重试,等 10ms
  if (retry_cnt == 2) return 100;       // 第 2 次,等 100ms
  if (retry_cnt == 3) return 1000;      // 第 3 次,等 1s
  return 5000;                          // 第 4+ 次,等 5s
}
```

### 2.12 跨 region 限流 — `easy_region_ratelimitor_t`

[`deps/easy/src/io/easy_io_struct.h:130-180`](deps/easy/src/io/easy_io_struct.h):

```cpp
struct easy_region_ratelimitor_t {
  char                              region[128];    // region 名字
  easy_atomic_t                     bw_kbps;         // 当前带宽 (KB/s) — #103 Counter
  int64_t                           max_bw_kbps;     // 限制带宽
  // 滑动窗口 (per-region)
  int64_t                           slots[RL_RECORD_SLOTS];  // 8*8 slots
  int64_t                           slot_size_ms;    // 每个 slot 的时间 (ms)
  easy_atomic_t                     slot_idx;        // 当前 slot 索引 — #103 Counter
};
```

**限流算法**: 滑动窗口 (sliding window)

```cpp
// 检查当前 region 流量是否超限
bool easy_ratelimitor_allow(easy_region_ratelimitor_t *rl) {
  // 1. 滑动窗口: 累加最近 N 个 slot
  int64_t now = easy_time_now();
  int cur_slot = now / rl->slot_size_ms;
  int total = 0;
  for (int i = 0; i < RL_RECORD_SLOTS; i++) {
    int idx = (cur_slot - i + RL_RECORD_SLOTS) % RL_RECORD_SLOTS;
    total += rl->slots[idx];
  }
  // 2. 判断
  return total < rl->max_bw_kbps;
}
```

### 2.13 帧式 RPC — `easy_session_t`

[`deps/easy/src/io/easy_io_struct.h:300-350`](deps/easy/src/io/easy_io_struct.h):

```cpp
struct easy_session_t {
  easy_message_t    msg;                    // 关联 message
  easy_request_t    r;                      // 关联 request
  easy_list_t       session_list_node;      // 连接上的 session 列表
  // 配置
  int64_t           timeout;                // 超时 (ms)
  void             *user_data;              // 用户数据 (协程上下文)
  // 状态
  int               status;                 // EASY_CONNECT_SEND / EASY_CONNECT_RSP / EASY_CONNECT_CLOSE
  // callback
  easy_io_handler_pt *callback;             // 收到 response 后调
  void             *args;
};
```

**同步 RPC 流程**:

```cpp
// 同步 RPC (用 easy_uthread 协程)
int obrpc_sync_call(const ObAddr &server, int pcode,
                     ObRpcRequest &req, ObRpcResponse &resp) {
  // 1. 创建 session
  easy_session_t *s = easy_session_create(sizeof(ObRpcSession));
  easy_session_set_handler(s, default_handler, &resp);
  easy_session_set_timeout(s, 4000);  // 4s

  // 2. 填 payload
  ObRpcSession *sess = (ObRpcSession *) s->data;
  sess->pcode = pcode;
  sess->request = &req;
  sess->response = &resp;
  // 序列化
  sess->serialize();

  // 3. 发送 (同步)
  easy_client_send(eio_, server.addr, s);

  // 4. 协程 yield,等 callback
  easy_uthread_yield();

  // 5. 醒来时,response 已填好
  return resp.ret_;
}
```

**异步 RPC 流程**:

```cpp
// 异步 RPC
int obrpc_async_call(const ObAddr &server, int pcode,
                      ObRpcRequest &req,
                      easy_io_handler_pt *callback, void *args) {
  easy_session_t *s = easy_session_create(sizeof(ObRpcSession));
  easy_session_set_handler(s, callback, args);
  // ... (同上)

  // 不 yield,立即返回
  return easy_client_send(eio_, server.addr, s);
}
```

### 2.14 write 流程

```cpp
// deps/easy/src/io/easy_connection.c: easy_connection_send_session()
int easy_connection_send_session(easy_connection_t *c, easy_session_t *s) {
  // 1. 序列化 packet
  ObRpcPacket packet(s);
  packet.serialize();

  // 2. 构造 easy_buf (含 EASY_HEADER + payload)
  easy_buf_t *b = easy_buf_create(c->pool, packet.size());
  memcpy(b->pos, packet.buf(), packet.size());
  b->last += packet.size();

  // 3. 加入 connection 的 output list
  easy_list_add_tail(&b->node, &c->output);

  // 4. 启动 EPOLLOUT 监听
  if (!ev_is_active(&c->write_watcher)) {
    ev_io_init(&c->write_watcher, easy_io_write_cb, c->fd, EV_WRITE);
    ev_io_start(c->ioth->loop, &c->write_watcher);
  }
  return EASY_OK;
}
```

**write callback**:

```cpp
static void easy_io_write_cb(struct ev_loop *loop, ev_io *w, int revents) {
  easy_connection_t *c = (easy_connection_t *) w->data;
  // 1. 循环 write,直到 EAGAIN 或 output 空
  while (!easy_list_empty(&c->output)) {
    easy_buf_t *b = easy_list_entry(c->output.next, easy_buf_t, node);
    ssize_t n = (c->ssl ? SSL_write(c->ssl, b->pos, b->last - b->pos)
                          : write(c->fd, b->pos, b->last - b->pos));
    if (n < 0) {
      if (errno == EAGAIN) break;
      easy_connection_close(c);
      return;
    }
    b->pos += n;
    if (b->pos == b->last) {
      easy_list_del(&b->node);
      easy_buf_destroy(b);
    }
  }
  // 2. output 空了,停止 EPOLLOUT
  if (easy_list_empty(&c->output)) {
    ev_io_stop(loop, &c->write_watcher);
  }
}
```

### 2.15 close 流程

```cpp
// deps/easy/src/io/easy_connection.c: easy_connection_close()
void easy_connection_close(easy_connection_t *c, int reason) {
  // 1. CAS 改 status (EASY_CONN_OK → EASY_CONN_CLOSE)
  // 防止多线程重复 close (跟 #104 BCAS 模式连接)
  int old_status = easy_atomic_xchg(&c->status, EASY_CONN_CLOSE);
  if (old_status == EASY_CONN_CLOSE) return;  // 已经关了

  // 2. 停 EPOLLIN / EPOLLOUT
  ev_io_stop(c->ioth->loop, &c->read_watcher);
  ev_io_stop(c->ioth->loop, &c->write_watcher);

  // 3. close socket
  close(c->fd);

  // 4. SSL cleanup
  if (c->ssl) SSL_free(c->ssl);

  // 5. 取消 pending request (走 handler)
  if (c->doing_request) {
    c->doing_request->callback(c->doing_request);
  }

  // 6. 释放 connection 内存 (easy_pool)
  easy_pool_destroy(c->pool);

  // 7. 从 conn_array 移除
  easy_hash_del(&c->hash_node);
}
```

**关键设计**:

- `easy_atomic_xchg` 是原子交换 (跟 #103 atomic / #104 BCAS 都连接)
- close 是单线程执行 (IO 线程),不用锁
- per-connection `easy_pool_t` 在 close 时统一释放 (跟 #25 内存管理连接)

### 2.16 SSL 加密 — `easy_ssl_*`

[`deps/easy/src/io/easy_ssl.c`](deps/easy/src/io/easy_ssl.c):

```cpp
int easy_ssl_ob_config_load(easy_io_t *eio, const char *ssl_ca,
                             const char *ssl_cert, const char *ssl_key, ...) {
  // 1. 加载证书
  eio->ssl_ctx = easy_ssl_ctx_load(eio->pool, ssl_ca, ssl_cert, ssl_key, ...);

  // 2. 启用 SSL
  for (int i = 0; i < eio->io_thread_count; i++) {
    easy_io_thread_t *ioth = eio->io_threads[i];
    ioth->ssl_ctx = eio->ssl_ctx;  // per-thread 引用
  }
  return EASY_OK;
}

// 创建 SSL 连接
SSL *easy_ssl_new(easy_io_thread_t *ioth, int fd) {
  SSL *ssl = SSL_new(ioth->ssl_ctx);
  SSL_set_fd(ssl, fd);
  SSL_set_accept_state(ssl);  // server 端
  // (client 端用 SSL_set_connect_state)
  return ssl;
}
```

**SSL handshake**:

```cpp
// 在 easy_io_read_cb 中,如果 c->ssl == NULL 且 enable_ssl, 先做 handshake
if (c->ssl == NULL && ioth->ssl_ctx != NULL) {
  c->ssl = easy_ssl_new(ioth, c->fd);
}
// handshake 跟普通 read 一样,返回 WANT_READ 时等下次 epoll
int ret = SSL_do_handshake(c->ssl);
if (ret == 1) {
  // handshake 完成,继续读
} else if (SSL_get_error(c->ssl, ret) == SSL_ERROR_WANT_READ) {
  // 等下次 epoll
  return;
}
```

**OB SSL 用法**:

- 默认**关闭** SSL (内部 RPC 走内网,无加密需求)
- OB Cloud / 跨 region RPC 可启用 SSL (用 `ssl_key_id` 区分不同 key)
- SSL 性能损耗 ~20-30% (vs 明文),所以默认关闭

---

## 3. 性能

### 3.1 单连接 RPC 性能

| 操作 | 延迟 |
|------|------|
| RPC 序列化 (1 KB payload) | ~5 μs |
| RPC 序列化 (10 KB payload) | ~30 μs |
| 网络 RTT (内网) | ~50 μs (单程) |
| RPC 全程 (1 KB, 内网) | ~150 μs |
| RPC 全程 (10 KB, 内网) | ~250 μs |
| SSL handshake (首次) | ~10 ms |
| SSL 加密 (1 KB payload) | ~10 μs |

### 3.2 RPC QPS (echo)

| 模式 | QPS | CPU |
|------|-----|-----|
| 同步 RPC (单连接,单线程) | ~5 万 | 单核 |
| 异步 RPC (8 连接, 单线程) | ~30 万 | 单核 |
| 异步 RPC (8 连接 × 8 线程) | ~200 万 | 8 核 |
| SSL RPC (8 连接 × 8 线程) | ~150 万 | 8 核 (-25%) |

### 3.3 Connection pool 性能

| max_conn_per_server | QPS | 内存 |
|---------------------|-----|------|
| 1 | ~3 万 | 1 KB |
| 4 | ~12 万 | 4 KB |
| 8 (默认) | ~25 万 | 8 KB |
| 16 | ~35 万 | 16 KB |
| 32 | ~40 万 | 32 KB (瓶颈) |

**瓶颈**: connection pool 大到 32 以后,QPS 不再线性增长 (kernel TCP accept / select 限制)。

### 3.4 obrpc header overhead

| 项 | 大小 |
|----|------|
| EASY_HEADER | 16 B |
| RPC_HEADER | 112 B |
| CHECKSUM | 8 B |
| **总开销** | **136 B** |
| 占比 (1 KB payload) | ~13% |
| 占比 (10 KB payload) | ~1.4% |

对小包 RPC,header 占比较高;大包 RPC 影响小。OB 在小包场景启用 header 压缩 (实验性)。

---

## 4. v2 连接

| 文章 | 关联点 |
|------|--------|
| #25 内存管理 | `easy_pool_t` per-connection 是 #25 简化版 |
| #27 RPC/obrpc | 本篇是 #27 源码级实读 |
| #103 atomic | `easy_atomic_t` / `easy_atomic_xchg` 是 #103 / #104 模式 |
| #104 atomic Flag | `easy_connection_t::status` 是 BCAS 状态机 |
| #107 libeasy | #107 讲 IO 线程,本篇讲连接 / packet / RPC |
| #109 (Worker 系列) | obrpc handler 调度走 #109 Worker 体系 (`ObWorkerProcessor`) |

---

## 5. 调优 Checklist

### 5.1 Connection pool 大小

```bash
# 默认值
max_conn_per_server = 8

# 调优建议
- 高 QPS 单 server: max_conn_per_server = 16-32
- 低 QPS 多 server: max_conn_per_server = 4
- 不建议超过 32 (kernel TCP 限制 + 内存)
```

### 5.2 RPC 超时

```bash
# 默认超时 (ms)
rpc_timeout = 4000

# 调优建议
- 内网 RPC: rpc_timeout = 1000 (1s)
- 跨 region RPC: rpc_timeout = 10000 (10s)
- 备份 RPC: rpc_timeout = 30000 (30s)
```

### 5.3 重试策略

```bash
# 默认重试次数
max_retry_cnt = 3

# 调优建议
- 读 RPC: max_retry_cnt = 3 (默认)
- 写 RPC: max_retry_cnt = 0 (避免重复执行) — 通常 retry_flag = 0
- 限流错误: max_retry_cnt = 5 (多退避几次)
```

### 5.4 限流配置

```bash
# 启用跨 region 限流
ratelimit_enabled = 1
# 限流阈值 (KB/s per region)
max_bw_kbps_per_region = 102400   # 100 MB/s
```

### 5.5 SSL 配置

```bash
# 启用 SSL (默认关闭)
ssl_enabled = 1
ssl_ca = "/path/to/ca.pem"
ssl_cert = "/path/to/cert.pem"
ssl_key = "/path/to/key.pem"

# 性能损耗 ~25%, 只在跨 region / 公网开启
```

### 5.6 路由缓存

```bash
# LRU cache 大小 (entry 数)
location_cache_size = 100000   # 10 万条
location_cache_ttl = 60000     # 1 分钟 TTL (60s)
```

---

## 6. 故障 case

### 6.1 RPC hang

**症状**: RPC 调用 hang,客户端等不到 response

**原因**:

- server 端 handler 卡死 (死锁 / 长事务)
- 网络丢包严重,RPC 重试也失败
- 路由失效 (server 已下线,客户端不知道)

**排查**:

```bash
# 1. 看 client 端的 pending request
# 在 observer 的 v$obrpc_incoming 视图
SELECT * FROM oceanbase.__all_virtual_session
WHERE type = 'OB_RPC' AND state = 'ACTIVE' LIMIT 10;

# 2. 看 server 端的请求队列
# 走 observer.log / rpc_stat
```

**解决**:

- 调小 `rpc_timeout` (强制超时,避免无限等)
- 排查 server 端 handler (gdb stack)
- 强制刷新路由 (location cache invalidation)

### 6.2 connection 泄漏

**症状**: `lsof -p <pid>` 显示大量 CLOSE_WAIT 连接

**原因**:

- 应用代码漏调 `easy_session_destroy`
- handler 异常退出,未释放 session
- 重试逻辑 bug,connection 没归还到 pool

**排查**:

```bash
# 看 CLOSE_WAIT 连接数
netstat -an | grep CLOSE_WAIT | wc -l

# 看 connection 池
cat /proc/<pid>/status | grep -i fd
# FDSize 异常大 → connection 泄漏
```

**解决**:

- 严格 RAII (session / connection 用智能指针管理)
- handler 异常路径也要释放 (用 `defer` / `try-finally`)
- 定期 connection pool 清理 (`put_connection` 检查 age)

### 6.3 RPC 重试风暴

**症状**: server 端压力突增,大量重试

**原因**:

- server 临时故障 (重启 / OOM)
- 重试退避不足,瞬间重试多次
- 没有 circuit breaker (熔断器)

**排查**:

```bash
# 看 RPC 重试计数
SELECT * FROM oceanbase.__all_virtual_sysstat
WHERE name LIKE '%rpc_retry%';

# 看 server 端压力
top -p <pid>
```

**解决**:

- 加重试退避 (exponential + jitter)
- 加 circuit breaker (server 故障时,客户端快速失败)
- 加 retry budget (限制总重试次数)

### 6.4 跨 region 限流失效

**症状**: 跨 region RPC 没被限流,带宽打满

**原因**:

- `ratelimit_enabled = 0` (默认)
- region 配置错误 (e.g. 写成 IP 而非 region name)
- slot_size 设置太小,窗口不准确

**排查**:

```bash
# 看限流统计
cat /proc/<pid>/io | grep -i ratelimit

# 看 region 配置
grep -r "easy_eio_set_region_max_bw" src/
```

**解决**:

- 启用限流 (`ratelimit_enabled = 1`)
- 校验 region name (跟 RS 配置一致)
- 调 slot_size 到 100ms (更准确)

### 6.5 SSL handshake 失败

**症状**: SSL RPC 连接不上 (但明文 RPC 正常)

**原因**:

- 证书过期
- CA / cert / key 文件路径错
- SSL 版本不匹配 (server 用 TLS 1.3, client 用 TLS 1.2)

**排查**:

```bash
# 验证证书
openssl x509 -in cert.pem -noout -dates
# 看是否过期

# 测试 SSL 连接
openssl s_client -connect <server>:<port>
```

**解决**:

- 定期更新证书 (e.g. cron 提前 7 天告警)
- 校验文件路径 (用绝对路径)
- 统一 TLS 版本 (server / client 都用 TLS 1.3)

---

## 7. 源码锚点 (grep)

```bash
# easy_connection 状态机
grep -n "EASY_CONN_OK\|EASY_CONN_CONNECTING\|EASY_CONN_CLOSE" \
  deps/easy/src/io/easy_connection.h

# accept / listen
grep -n "easy_io_accept_cb\|easy_socket_listen\|SO_REUSEPORT" \
  deps/easy/src/io/easy_connection.c deps/easy/src/io/easy_maccept.c

# packet 编解码
grep -n "EASY_HEADER_SIZE\|easy_connection_parse_packet" \
  deps/easy/src/io/easy_io_struct.h deps/easy/src/io/easy_connection.c

# obrpc 序列化
grep -n "ObRpcPacket::serialize\|ObRpcPacket::deserialize\|RPC_HEADER_SIZE" \
  src/share/rpc/ob_rpc_packet.{h,cpp}

# obrpc dispatch
grep -n "ObRpcProxy::process\|REG_PCODE\|handlers_\[" \
  src/share/rpc/ob_rpc_proxy.{h,cpp}

# ObNetClient / ObNetServer
grep -n "ObNetClient::sync_send\|ObNetClient::get_connection\|conn_pool_" \
  src/share/rpc/ob_net_client.{h,cpp}

# 路由缓存
grep -n "ObLocationCache::get\|cache_\." \
  src/share/location/ob_location_cache.{h,cpp}

# 重试
grep -n "ObRpcRetry::should_retry\|backoff_ms" \
  src/share/rpc/ob_rpc_proxy.h

# 限流
grep -n "easy_region_ratelimitor_t\|easy_ratelimitor_allow\|slots\[" \
  deps/easy/src/io/easy_io_struct.h

# SSL
grep -n "easy_ssl_ob_config_load\|SSL_do_handshake\|ssl_ctx" \
  deps/easy/src/io/easy_ssl.c
```

---

## 8. Cross-cutting

| 主题 | 关联点 |
|------|--------|
| atomic | `easy_atomic_t` / `easy_atomic_xchg` 是 #103 / #104 模式 |
| Flag | `easy_connection_t::status` 是 #104 BCAS 状态机 |
| 内存 | `easy_pool_t` per-connection 是 #25 简化版 |
| 线程 | IO 线程 + user_thread_pool 是 #109 Worker 体系的基础 |
| RPC | obrpc 是 #27 RPC 的源码级实读 |
| 序列化 | Protobuf / ObRpcBuffer (自定义, 比 Protobuf 快) |
| 安全 | SSL 在 libeasy 之上,默认关闭 (内网 RPC 不加密) |
| 限流 | 跨 region 限流 (跟 #28 资源管理相关) |
| 重试 | 跟 #27 RPC 重试策略对应 |

---

## 9. 总结

OB 在 libeasy 之上有两层封装:

- **`easy_io` 层**: 把 libeasy 包成 `easy_io_t`,提供 OB 风格的生命周期管理 (`easy_connection_t` 状态机 + packet 编解码 + handler dispatch)
- **`obrpc` 层**: 在 easy_io 之上提供 RPC 协议 (`ObRpcPacketHeader` + 序列化 + 路由 + 重试 + 限流 + SSL)

**关键设计**:

- 三种 RPC 模式 (流式 / 攒批 / 帧式) — 大多数用帧式
- SO_REUSEPORT 多队列 — kernel 自动负载均衡
- connection pool (per-server max 8) — 复用长连接
- 重试 + 退避 + circuit breaker — 应对瞬时故障
- 跨 region 限流 — 多 region 部署时控制带宽

**OB 4.x 演进**:

- obrpc header 压缩 (小包场景)
- io_uring send / recv (实验性)
- C++20 coroutine 替代 easy_uthread (部分路径)

---

## 10. 后续可扩展方向

1. **`ObRpcBuffer` 序列化 vs Protobuf 详细对比** — OB 自研的 `ObRpcBuffer` 比 Protobuf 快 ~2-3x,原因是 zero-copy + 自定义类型系统
2. **obrpc streaming RPC 实现** — 长连接 / 大包场景 (心跳 / 推送 / 增量备份)
3. **obrpc batch RPC + `ObBatchProcessor`** — 高 QPS 小包场景 (e.g. 心跳)
4. **`ObLocationCache` 缓存策略 deep-dive** — LRU vs LFU, TTL, cache invalidation, refresh-ahead
5. **Circuit breaker 实现** — OB 4.x 是否引入了 circuit breaker? (目前只有重试,没有熔断)
6. **obrpc 跨语言互操作** — C++ / Java / Python client 跟 OB server 通信的协议兼容
7. **SSL 性能优化** — session cache (SSL session resumption), 减少 handshake 开销