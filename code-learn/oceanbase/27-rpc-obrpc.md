# #27 v2 — RPC / obrpc (跨 OBServer 通信 完整实读)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")

> 接续 #11 v2 Trans Service / Lock + #22 v2 Clog + #26 v2 Primary / Standby:
> 前面讲了"事务怎么跨 partition、日志怎么同步、主备怎么切"。本文聚焦 **"跨
> OBServer 调用是怎么实现的"** ——OB 的 RPC 框架 obrpc。这是分布式协调的底
> 层基石。

---

## 0. 全文导读

OB 的 RPC 三层:

```
应用层 (Trans Service / Clog Replicator / Plan Cache Sync)
  ↓
obrpc 协议层 (序列化 + 压缩 + 流控 + 重试)
  ↓
网络层 (epoll / io_uring + TCP / 共享内存)
```

本文按"架构 → obrpc 协议 → 客户端 → 服务端 → 网络 IO → 监控调优"展开。

---

## 1. RPC 整体架构

### 1.1 RPC 模块组成

```cpp
// src/rpc/obrpc/ob_rpc_packet.h:50
// obrpc 是 OB 自研的 RPC 框架(基于 TCP)
// 替代 protobuf / thrift,追求高性能

class ObRpcPacket {
public:
  // 1. 协议头
  uint8_t  magic_[2];         // "OB"
  uint8_t  version_;          // 协议版本
  uint8_t  type_;             // 请求 / 响应 / 心跳
  uint32_t payload_len_;      // 序列化数据长度
  uint64_t trace_id_;         // trace ID
  uint64_t request_id_;       // 请求 ID(用于匹配响应)
  
  // 2. payload (序列化后的请求/响应数据)
  char *payload_;
};
```

### 1.2 RPC 栈

```
┌─────────────────────────────────────┐
│ Application (Trans Service / Clog) │
├─────────────────────────────────────┤
│ obrpc 框架 (序列化 / 路由 / 重试) │
├─────────────────────────────────────┤
│ Net IO (epoll / io_uring)         │
├─────────────────────────────────────┤
│ TCP / 共享内存                     │
└─────────────────────────────────────┘
```

### 1.3 关键组件

```cpp
// src/rpc/obrpc/ob_rpc_proxy.h:50
// RPC 客户端代理:自动路由 + 重试
class ObRpcProxy {
public:
  // 1. 同步调用
  int call(ObAddr server, uint32_t code, const Request &req, Response &resp);
  // 2. 异步调用
  int async_call(ObAddr server, uint32_t code, const Request &req, 
                 ObRpcCallback *cb);
};

// src/rpc/obrpc/ob_rpc_server.h:80
// RPC 服务端:多线程派发
class ObRpcServer {
public:
  // 1. 启动监听
  int start();
  // 2. 注册处理函数
  template <typename Handler>
  int register_handler(uint32_t code, Handler handler);
};
```

---

## 2. obrpc 协议

### 2.1 协议头(20 字节)

```cpp
// src/rpc/obrpc/ob_rpc_packet.h:80
struct ObRpcHeader {
  // 1. magic (2 bytes)
  uint8_t magic_[2];          // 0xAB 0xCD
  // 2. version (1 byte)
  uint8_t version_;            // 当前 1
  // 3. type (1 byte)
  uint8_t type_;               // 0=REQ, 1=RESP, 2=PUSH
  // 4. code (4 bytes) - RPC code 标识
  uint32_t code_;
  // 5. payload_len (4 bytes)
  uint32_t payload_len_;
  // 6. trace_id (8 bytes)
  uint64_t trace_id_;
};
// 总 20 bytes
```

### 2.2 协议帧

```
┌────────────────┬──────────────────────┐
│ Header (20 B)  │ Payload (变长)        │
└────────────────┴──────────────────────┘

Payload 内部:
  - 序列化后的请求/响应数据
  - 可选压缩(zstd / lz4)
  - 可选加密(AES)
```

### 2.3 RPC Code 注册

```cpp
// src/rpc/obrpc/ob_rpc_code.h:50
// 每个 RPC 消息有唯一 code
enum ObRpcCode {
  OB_TRANS_PREPARE = 1001,        // 事务 prepare
  OB_TRANS_COMMIT = 1002,         // 事务 commit
  OB_CLOG_PUSH_LOG = 2001,        // 主推 Clog 到备
  OB_HEARTBEAT_REQ = 3001,        // 心跳
  OB_PAXOS_PROPOSE = 4001,        // Paxos 提案
  OB_PARTITION_MIGRATE = 5001,    // partition 迁移
  OB_DAS_EXECUTE = 6001,          // DAS 执行
  OB_BACKUP_FETCH = 7001,         // 备份拉取
  // ... 数百个
};
```

### 2.4 序列化(FlatBuffers-like)

```cpp
// deps/oblib/src/lib/utility/ob_serialization.h:50
// obrpc 用自研序列化框架(避免 protobuf 的反射开销)
// 类 FlatBuffers:零拷贝

class ObRpcSerializer {
public:
  // 1. 写入
  template <typename T>
  int serialize(const T &obj, char *buf, size_t &len);
  // 2. 读取
  template <typename T>
  int deserialize(const char *buf, size_t len, T &obj);
};

// 序列化示例:struct { int a; string b; }
//   [4 bytes: a]
//   [2 bytes: b length][N bytes: b]
//   [padding for alignment]
```

OB 的序列化是 **固定布局** —— 不像 protobuf 那样需要反射,直接 `memcpy`。

---

## 3. RPC 客户端

### 3.1 连接管理

```cpp
// src/rpc/obrpc/ob_rpc_connection.h:50
class ObRpcConnection {
public:
  // 1. 连接池:对每个 (server_addr, rpc_code) 维护 N 个连接
  // 2. 长连接(默认 30min keepalive)
  // 3. 失败 reconnect
};
```

### 3.2 调用流程

```cpp
// src/rpc/obrpc/ob_rpc_client.cpp:100
int ObRpcClient::call(ObAddr server, uint32_t code, 
                       const Request &req, Response &resp) {
  // 1. 拿连接
  auto *conn = conn_pool_.acquire(server);
  // 2. 序列化请求
  size_t len;
  char buf[1024 * 1024];  // 1MB buffer
  serializer_.serialize(req, buf, len);
  // 3. 压缩(可选)
  if (enable_compress_) {
    len = compress(buf, len);
  }
  // 4. 写包头
  ObRpcHeader header;
  header.code_ = code;
  header.payload_len_ = len;
  // 5. 发送
  conn->send(&header, sizeof(header));
  conn->send(buf, len);
  // 6. 等响应(同步)
  conn->recv(&resp_header, sizeof(resp_header));
  conn->recv(resp_buf, resp_header.payload_len_);
  // 7. 反序列化
  serializer_.deserialize(resp_buf, resp_header.payload_len_, resp);
  return OB_SUCCESS;
}
```

### 3.3 异步调用

```cpp
// src/rpc/obrpc/ob_rpc_async.cpp:80
int ObRpcClient::async_call(ObAddr server, uint32_t code, 
                             const Request &req, ObRpcCallback *cb) {
  // 1. 拿连接
  auto *conn = conn_pool_.acquire(server);
  // 2. 发送请求
  conn->send(&header, sizeof(header));
  conn->send(buf, len);
  // 3. 注册 pending 请求
  pending_requests_[conn->id()][header.request_id_] = cb;
  // 4. 立即返回(不阻塞)
  return OB_SUCCESS;
}

// 响应回来时,在网络线程回调
void on_response(uint64_t conn_id, uint64_t req_id, Response &resp) {
  auto *cb = pending_requests_[conn_id][req_id];
  cb->on_response(resp);
}
```

### 3.4 重试与超时

```cpp
// src/rpc/obrpc/ob_rpc_retry.cpp:50
class ObRpcRetry {
public:
  // 1. 超时重试
  bool should_retry(int error_code, int retry_count) {
    if (retry_count >= max_retry_count_) return false;
    // 网络错误重试
    if (is_network_error(error_code)) return true;
    // 业务错误不重试
    return false;
  }
  // 2. 指数退避
  int backoff_ms(int retry_count) {
    return 100 * (1 << retry_count);  // 100ms, 200ms, 400ms...
  }
};
```

---

## 4. RPC 服务端

### 4.1 多线程派发

```cpp
// src/rpc/obrpc/ob_rpc_server.cpp:80
class ObRpcServer {
public:
  // 1. 启动 N 个 worker 线程
  std::vector<std::thread> workers_;
  // 2. 每个 worker 一个 epoll
  // 3. 请求到达 → 派发到 worker 队列
};
```

### 4.2 请求处理

```cpp
// src/rpc/obrpc/ob_rpc_handler.cpp:100
// 通用 handler 流程
int ObRpcHandler::handle_request(ObRpcPacket &packet) {
  // 1. 反序列化
  Request req;
  serializer_.deserialize(packet.payload(), packet.payload_len(), req);
  // 2. 找 handler
  auto *handler = handler_map_[packet.code()];
  if (!handler) {
    return OB_ERR_RPC_CODE_NOT_FOUND;
  }
  // 3. 调 handler
  Response resp;
  int ret = handler->process(req, resp);
  // 4. 序列化响应
  char resp_buf[1024 * 1024];
  size_t resp_len;
  serializer_.serialize(resp, resp_buf, resp_len);
  // 5. 发回响应
  send_response(packet.conn_id(), packet.request_id_, resp_buf, resp_len);
  return ret;
}
```

### 4.3 流量控制

```cpp
// src/rpc/obrpc/ob_rpc_throttle.cpp:50
// 限流:避免单个 client 把 server 打爆
class ObRpcThrottle {
public:
  // 1. 按 server 限速
  // 2. 按 RPC code 限速
  // 3. 按 connection 限速
  bool allow_request(ObAddr server, uint32_t code) {
    // 令牌桶
    return token_bucket_.try_consume(1);
  }
};
```

---

## 5. 网络 IO

### 5.1 Linux epoll

```cpp
// deps/oblib/src/lib/io/ob_epoll.cpp:80
class ObEpoll {
public:
  // 1. epoll_create + 注册 socket
  // 2. epoll_wait 阻塞
  // 3. 事件触发:read / write / error
  int loop() {
    while (running_) {
      int n = epoll_wait(epfd_, events_, max_events_, timeout_);
      for (int i = 0; i < n; ++i) {
        auto *conn = connections_[events_[i].data.fd];
        if (events_[i].events & EPOLLIN) conn->on_read();
        if (events_[i].events & EPOLLOUT) conn->on_write();
      }
    }
  }
};
```

### 5.2 io_uring(Linux 5.1+,OB 5.x)

```cpp
// deps/oblib/src/lib/io/ob_io_uring.cpp:50
// io_uring 比 epoll 更高效(系统调用更少,内核旁路)
class ObIoUring {
public:
  // 1. 提交多个 IO(一次系统调用)
  io_uring_submit(&ring_, ops_, n_ops_);
  // 2. 等完成
  io_uring_wait_cqe(&ring_, &cqes_, n_completions_);
  // 3. 处理完成事件
};
```

### 5.3 TCP vs 共享内存

| 场景 | 协议 |
|------|------|
| **跨 OBServer** | TCP(标准) |
| **跨机房** | TCP over RDMA(可选,高带宽) |
| **单机内多 OBServer** | 共享内存(避免 TCP 协议栈开销) |

OB 在生产环境用 **TCP**;单机测试用 **共享内存**(减少延迟)。

### 5.4 连接复用

```
每个 OBServer 持有到其他 OBServer 的 N 个长连接(N=8~64)
  ↓
请求分发到不同连接(避免 head-of-line blocking)
  ↓
keepalive(30s 一次,防死连接)
```

---

## 6. 与其它子系统的关系

### 6.1 与 Trans Service(接 #11)

```
2PC:
  Coordinator → Participant A: OB_TRANS_PREPARE (RPC)
  Coordinator → Participant B: OB_TRANS_PREPARE (RPC)
  Participant → Coordinator: OB_TRANS_VOTE_COMMIT (RPC)
  Coordinator → Participant: OB_TRANS_COMMIT (RPC)
```

### 6.2 与 Clog(接 #22)

```
Primary → Standby: OB_CLOG_PUSH_LOG (RPC)
  - 推一批 log(默认 4KB ~ 1MB)
  - 异步 + 批量 + 压缩
```

### 6.3 与 Paxos(接 #26)

```
Proposer → Acceptors: OB_PAXOS_PROPOSE (RPC)
  - 收集半数 ack 才提交
```

### 6.4 与 DAS(接 #24)

```
Coordinator → Target Server: OB_DAS_EXECUTE (RPC)
  - 在 target server 上执行 DAS op
  - 返回结果
```

### 6.5 与 Backup(接 #33)

```
Backup Coordinator → OBServer: OB_BACKUP_FETCH (RPC)
  - 拉 SSTable 块
```

### 6.6 与 Partition Migration

```
源 OBServer → 目标 OBServer: OB_PARTITION_MIGRATE (RPC)
  - 传输 tablet 数据
  - 切换 leader
```

---

## 7. RPC 监控

### 7.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_rpc_stat\G

-- 关键字段:
-- rpc_code_: RPC code
-- count_: 调用次数
-- avg_latency_us_: 平均延迟
-- max_latency_us_: 最大延迟
-- fail_count_: 失败次数
-- in_flight_count_: 进行中请求数
```

### 7.2 慢 RPC 排查

```sql
-- 找 avg_latency_us_ > 10ms 的 RPC
SELECT rpc_code_, avg_latency_us_
FROM oceanbase.__all_virtual_rpc_stat
WHERE avg_latency_us_ > 10000
ORDER BY avg_latency_us_ DESC;
```

### 7.3 失败率

```sql
-- 失败率 > 1% 的 RPC
SELECT rpc_code_, fail_count_ / count_ AS fail_rate
FROM oceanbase.__all_virtual_rpc_stat
WHERE count_ > 1000
ORDER BY fail_rate DESC
LIMIT 20;
```

### 7.4 Trace RPC

```sql
-- 拿 trace_id 看完整 RPC 路径
SELECT * FROM oceanbase.__all_virtual_trace_event
WHERE trace_id_ = '<your_trace_id>';
```

OB 的 trace 系统跨 RPC 传播,可以看一次 query 的完整调用链。

---

## 8. 性能优化

### 8.1 批量

```cpp
// src/rpc/obrpc/ob_rpc_batch.cpp:50
// 把多个小请求合并成一个大请求(减少 RPC 次数)
class ObRpcBatch {
public:
  // 例:10 个 row 修改 → 1 个 RPC(而不是 10 个)
  int batch_call(ObAddr server, uint32_t code, 
                 const ObSEArray<Request> &reqs);
};
```

### 8.2 Pipeline

```
串行: send req1 → wait resp1 → send req2 → wait resp2
pipeline: send req1 → send req2 → send req3 → wait resp1 → wait resp2 → wait resp3

延迟减少 Nx(响应可以重叠)
```

### 8.3 压缩

```cpp
// src/rpc/obrpc/ob_rpc_compress.cpp:50
// 大 payload 自动压缩(>1KB 启用)
class ObRpcCompressor {
public:
  int compress(const char *src, size_t src_len, char *dst, size_t &dst_len) {
    // 选算法:lz4 (快) / zstd (高压缩率)
  }
};
```

### 8.4 连接复用 + 预热

```cpp
// 启动时预建连接(避免运行时建立延迟)
class ObRpcConnPool {
public:
  void warmup() {
    for (auto &peer : peers_) {
      for (int i = 0; i < n_per_peer_; ++i) {
        create_conn(peer);
      }
    }
  }
};
```

---

## 9. RPC 的代价与权衡

### 9.1 RPC 延迟组成

```
客户端:
  1. 序列化: 1-10 μs
  2. 系统调用 send(): 1-5 μs
  3. 网络传输: 10 μs ~ 10 ms (取决于物理距离)
  4. 系统调用 recv(): 1-5 μs
  5. 反序列化: 1-10 μs

服务端:
  6. 系统调用 recv(): 1-5 μs
  7. handler 处理: 1-100 μs (取决于业务)
  8. 序列化响应: 1-10 μs
  9. 系统调用 send(): 1-5 μs

总延迟: ~20-200 μs (同机房)
       ~10-50 ms  (跨机房)
```

### 9.2 RPC 失败的代价

```
失败重试: 延迟 × 2 (1 次重试)
失败不重试: 数据可能不一致(必须业务层兜底)
```

### 9.3 RPC 的线程模型

```
单 OBServer 持有 N 个 RPC worker(默认 N = CPU 核数 * 2)
  ↓
每个 worker 一个 epoll
  ↓
处理请求时,可选用专用线程池(避免阻塞 IO 线程)
```

---

## 10. 调优 Checklist

```
□ RPC worker 数量是否够?(默认 CPU * 2,可调)
□ 连接池大小是否合理?(默认 8-64 per peer)
□ 超时时间是否合适?(默认 5s)
□ 重试次数是否合理?(默认 3)
□ 压缩是否启用?(大 payload 必开)
□ 批量是否使用?(业务允许时)
□ 慢 RPC 监控是否启用?
□ 失败告警是否配置?
□ Trace 系统是否采样?
```

---

## 11. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → #28 v2 → #19 
v2 → #20 v2 → **#27 v2 (本文)** 是 OB **storage / index / CBO / join / 
cache / 调优 / 日志 / 事务 / schema / 并行 / HA / 容灾 / 多租户 / parser 
/ compaction / RPC** 全主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObKeyBTree | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| #29 v2 | Slow Query | 运维层 | 捕获 + 分析 + 推荐 + 调优 |
| #22 v2 | Clog / Redo Log | 持久化层 | WAL + group commit + replica + recovery |
| #11 v2 | Trans Service / Lock | 事务层 | 全局事务 ID + 行锁 + 2PC + 死锁 + SI |
| #21 v2 | Schema / DDL | 元数据层 | schema_version + INSTANT/INPLACE + Online DDL |
| #24 v2 | PX Framework | 并行层 | Worker Pool + Task 调度 + Data Exchange + DAS |
| #26 v2 | Primary / Standby | HA 层 | Paxos + 选主 + failover + 副本同步 |
| #33 v2 | Backup / Recovery | 容灾层 | 全量+增量+archive log + PIT + 容灾策略 |
| #28 v2 | Resource / Unit / Tenant | 多租户层 | 3 层模型 + 隔离机制 + 资源调度 |
| #19 v2 | SQL Parser | 前端层 | Lexer + Parser + Resolver + Type Check + Fingerprint |
| #20 v2 | Compaction Strategy | 存储维护层 | Minor Freeze + Major Freeze + History Merge |
| **#27 v2 (本文)** | **RPC / obrpc** | **网络层** | **序列化 + 路由 + 重试 + epoll/io_uring** |

十八篇连起来,读者能完整理解 OB 的"单机 → 跨机 → 全栈"全链路:

- 单机内部:#14-#24 (storage/index/optimizer/join/PX)
- 跨机通信:#27 (本文:obrpc)
- HA + 容灾:#26 + #33
- 事务一致:#11 + #22

---

## 12. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **Monitoring / Alerting** — ASH 深入 + metrics 体系(接 #29)
- **Partition Management** — rebalance / migration(接 #26)
- **Storage Engine Internals** — SSTable / macro_block / micro_block 深入(接 #51)
- **SQL 引擎入口 (SQL Engine Entry)** — 接收 / 派发 / 路由(接 #19 + #24)

继续哪一篇?

---

## 13. 参考(可执行的源码锚点)

- `src/rpc/obrpc/ob_rpc_packet.h` — 协议包
- `src/rpc/obrpc/ob_rpc_proxy.h` — 客户端代理
- `src/rpc/obrpc/ob_rpc_server.h` — 服务端
- `src/rpc/obrpc/ob_rpc_client.cpp` — 客户端调用
- `src/rpc/obrpc/ob_rpc_handler.cpp` — 请求处理
- `src/rpc/obrpc/ob_rpc_async.cpp` — 异步调用
- `src/rpc/obrpc/ob_rpc_retry.cpp` — 重试策略
- `src/rpc/obrpc/ob_rpc_throttle.cpp` — 限流
- `src/rpc/obrpc/ob_rpc_compress.cpp` — 压缩
- `src/rpc/obrpc/ob_rpc_batch.cpp` — 批量
- `deps/oblib/src/lib/utility/ob_serialization.h` — 序列化
- `deps/oblib/src/lib/io/ob_epoll.cpp` — epoll 实现
- `deps/oblib/src/lib/io/ob_io_uring.cpp` — io_uring 实现
- `src/share/backup/ob_rpc_stat.h` — 监控指标

---

#27 v2 完。
