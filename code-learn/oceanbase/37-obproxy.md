# #37 v2 — OBProxy (Proxy 层深度实读)

> 接续 #35 v2 SQL Engine Entry + #27 v2 RPC / obrpc + #28 v2 Resource / Unit /
> Tenant:前面讲了"SQL 引擎入口怎么接收、跨 OBServer RPC 怎么发、租户怎么隔
> 离"。本文聚焦 **"Client 到 OBServer 中间的代理层"** ——OBProxy。OBProxy 是
> OB 集群的"门面",负责路由 / 协议兼容 / 性能优化。

---

## 0. 全文导读

OBProxy 三层:

```
Client (MySQL/Oracle 协议)
    ↓
OBProxy (路由 + 协议 + 缓存 + 限流)
    ↓
OBServer (实际数据)
```

本文按"架构 → 启动 → 集群发现 → 路由策略 → 协议兼容 → 性能优化 → HA →
监控调优"展开。

---

## 1. OBProxy 角色

### 1.1 定位

OBProxy 是 OB 集群的 **客户端到服务器的代理**。它做:
- **路由**: 选目标 OBServer
- **协议兼容**: 接受 MySQL / Oracle 客户端
- **性能优化**: 连接复用 / 结果缓存 / 限流
- **HA**: 多 OBProxy + failover
- **监控**: 客户端到服务器的所有 SQL 流量

### 1.2 为什么需要 OBProxy

```
不用 OBProxy:
  Client → OBServer(任意一台)
  缺点: 客户端要知道所有 OBServer 地址 + 负载均衡难 + 协议兼容难

用 OBProxy:
  Client → OBProxy(单一入口)
  优点: 客户端简单 + 路由智能 + 协议透明 + 安全可控
```

### 1.3 OBProxy vs 其他 proxy

| Proxy | 用途 |
|-------|------|
| **OBProxy** | OB 专用,MySQL/Oracle 协议 |
| **MySQL Router** | MySQL Group Replication |
| **ProxySQL** | MySQL 中间件 |
| **ShardingSphere-Proxy** | 通用分库分表 |

---

## 2. OBProxy 架构

### 2.1 模块组成

```
┌─────────────────────────────────────┐
│           OBProxy                   │
│  ┌───────────────────────────────┐  │
│  │ Protocol Layer                │  │
│  │  (MySQL / Oracle)             │  │
│  ├───────────────────────────────┤  │
│  │ Routing Layer                 │  │
│  │  (table_id → server_addr)     │  │
│  ├───────────────────────────────┤  │
│  │ Connection Pool               │  │
│  │  (client connections)         │  │
│  ├───────────────────────────────┤  │
│  │ Backend Connection Pool       │  │
│  │  (server connections)         │  │
│  ├───────────────────────────────┤  │
│  │ Result Cache / SQL Audit      │  │
│  ├───────────────────────────────┤  │
│  │ Monitor / Metrics             │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
```

### 2.2 进程模型

```cpp
// src/obproxy/ob_proxy_main.cpp:50
class ObProxyMain {
public:
  // 1. 单进程 + 多线程
  // 2. 每个 client 连接一个 worker thread
  // 3. epoll 处理 backend 连接
};
```

### 2.3 关键目录结构

```
src/obproxy/
  ├── ob_proxy_main.cpp        # 主入口
  ├── ob_proxy_route.cpp       # 路由
  ├── ob_proxy_mysql.cpp       # MySQL 协议
  ├── ob_proxy_ob.cpp          # OB 内部协议
  ├── ob_proxy_connection.cpp  # 连接管理
  ├── ob_proxy_audit.cpp       # SQL audit
  └── ob_proxy_monitor.cpp     # 监控
```

---

## 3. 启动与配置

### 3.1 启动命令

```bash
./obproxy -p listen_port=2883 -r 'http://rootservice:2881'
```

### 3.2 配置项

```cpp
// src/obproxy/ob_proxy_config.h:80
struct ObProxyConfig {
  // 1. 监听端口
  int mysql_port_;             // 默认 2883 (OB MySQL)
  int oracle_port_;            // 默认 2881 (OB Oracle)
  
  // 2. 集群发现
  std::string rs_list_;         // RootService list "ip:port;ip:port"
  
  // 3. 路由策略
  enum RouteStrategy {
    READ_WRITE_SPLIT,         // 读写分离
    RANDOM,                    // 随机
    LEAST_CONNECTIONS,         // 最少连接
    LEAST_LATENCY,             // 最近延迟
  };
  RouteStrategy route_strategy_;
  
  // 4. 性能
  int client_connection_pool_size_;   // 默认 1024
  int server_connection_pool_size_;   // 默认 64 per server
  
  // 5. 安全
  std::string proxy_id_;       // OBProxy 标识
  int max_connections_;        // 最大 client 连接
};
```

### 3.3 启动流程

```cpp
// src/obproxy/ob_proxy_main.cpp:100
int ObProxyMain::start() {
  // 1. 加载配置
  config_.load();
  // 2. 连接 RootService(获取 cluster_id / tenant list)
  rs_client_.init(config_.rs_list_);
  // 3. 拉 cluster 元数据
  cluster_meta_ = rs_client_.get_cluster_meta();
  // 4. 启动监听
  listen(config_.mysql_port_);
  listen(config_.oracle_port_);
  // 5. 启动后台线程
  monitor_thread_.start();
  rs_heartbeat_thread_.start();
  // 6. 等待 client 连接
  return OB_SUCCESS;
}
```

---

## 4. 集群发现

### 4.1 OBProxy 需要的信息

```
1. cluster_id: 集群 ID
2. tenant list: 所有 tenant
3. server list: 所有 OBServer (主 + 备)
4. partition table: (table_id, partition_id) → server_addr
```

### 4.2 从 RootService 拉取

```cpp
// src/obproxy/ob_proxy_rs_client.cpp:80
class ObProxyRsClient {
public:
  // 1. 启动时拉全量
  int fetch_full_cluster_meta() {
    auto meta = rpc_.call(RS_ADDR, OB_RS_GET_CLUSTER_META);
    cluster_meta_ = meta;
  }
  // 2. 周期性拉增量
  void incremental_fetch_loop() {
    while (running_) {
      sleep(60s);
      auto delta = rpc_.call(RS_ADDR, OB_RS_GET_DELTA_META);
      cluster_meta_.apply_delta(delta);
    }
  }
};
```

### 4.3 缓存与失效

```cpp
// src/obproxy/ob_proxy_route_table.cpp:50
class ObRouteTable {
public:
  // 1. 缓存 partition → server 映射
  std::unordered_map<int64_t, ObAddr> partition_to_server_;
  
  // 2. 监听 RS 推送的 schema / partition 变更
  void on_rs_push(const ObDeltaMeta &delta) {
    // 增量更新 route table
    for (auto &change : delta.changes_) {
      apply_change(change);
    }
  }
};
```

### 4.4 OBProxy 启动延迟优化

```
启动流程:
  1. 加载配置: ~1s
  2. 连 RS + 拉元数据: ~5-30s(取决于集群大小)
  3. 准备路由表: ~1s
  总启动: ~10-40s

优化:
  - 预热: 启动后立刻接受 client,后台异步拉元数据
  - 缓存: 用上一次元数据(磁盘持久化)
```

---

## 5. 路由策略

### 5.1 路由决策

```
Client SQL → OBProxy:
  1. Parse SQL(只 parse, 不 resolve)
  2. 提取 table_name + key
  3. 查 route table
  4. 决定目标 OBServer
```

### 5.2 路由方式

```cpp
// src/obproxy/ob_proxy_route.cpp:80
class ObProxyRouter {
public:
  ObAddr route(const ObString &sql, const ObString &table_name, 
               const ObString &key) {
    // 1. 强一致读 / 写: 路由到 PRIMARY
    if (is_strong_consistency(sql)) {
      return primary_for_table(table_name);
    }
    // 2. 弱读: 路由到任一副本
    if (is_weak_read(sql)) {
      return random_replica(table_name);
    }
    // 3. 单分区查询: 路由到目标 partition 的 server
    int64_t partition_id = compute_partition(key);
    return partition_to_server(partition_id);
  }
};
```

### 5.3 路由策略对比

| 策略 | 优点 | 缺点 |
|------|------|------|
| **PRIMARY 路由** | 强一致 | 主压力大 |
| **RANDOM 副本** | 负载均衡 | 可能读到旧数据 |
| **LEAST_LATENCY** | 延迟最优 | 探测开销 |
| **读写分离** | 主写 / 从读,均衡 | 需要识别 SQL 类型 |

### 5.4 智能路由

```cpp
// src/obproxy/ob_proxy_smart_route.cpp:50
// OBProxy 学习每个 server 的延迟,选最快的
class ObSmartRouter {
public:
  ObAddr route() {
    // 1. 选最近的 server(地理)
    // 2. 选延迟最低的 server(探测)
    // 3. 选负载最低的 server
    return best_server();
  }
};
```

### 5.5 Hint 路由

```sql
-- 强制路由到某个 server
SELECT /*+ ROUTE_TO('1.2.3.4:2881') */ * FROM t;

-- 强制弱读
SELECT /*+ READ_CONSISTENCY(WEAK) */ * FROM t;
```

OBProxy 识别 hint 并执行。

---

## 6. 协议兼容

### 6.1 MySQL 协议

```cpp
// src/obproxy/ob_proxy_mysql.cpp:80
// OBProxy 模拟 MySQL server
class ObProxyMysqlServer {
public:
  // 1. 接受 client 连接
  void on_new_connection(ObTcpConnection &conn) {
    // 1.1 发送 server greeting(MySQL 协议格式)
    send_greeting_packet(conn);
    // 1.2 等 client 发 auth packet
    auto auth_packet = recv_packet(conn);
    // 1.3 验证 client(user + password + tenant)
    if (!authenticate(auth_packet)) {
      send_error_packet(conn, ER_ACCESS_DENIED);
      conn.close();
    }
  }
};
```

### 6.2 MySQL 握手流程

```
Client → OBProxy:
  1. Client 连接
  2. OBProxy 发 server greeting
  3. Client 发 auth packet (含 username + password hash + database)
  4. OBProxy 验证(查 cluster user 表)
  5. 验证成功 → OBProxy 发 OK packet
  6. Client 开始发 SQL

Client → OBProxy (SQL):
  1. Client: COM_QUERY "SELECT * FROM t"
  2. OBProxy: 解析 → 路由 → 转发到 OBServer
  3. OBProxy → Client: result set
```

### 6.3 OB 内部协议

OBProxy ↔ OBServer 用 **OB 内部协议** (binary, 高效):

```cpp
// src/obproxy/ob_proxy_ob_protocol.cpp:50
// OBProxy ↔ OBServer 通信
class ObProxyObProtocol {
public:
  // 1. 转发 SQL 到 OBServer
  int send_sql(ObBackendConnection &conn, const ObString &sql) {
    // 序列化 SQL + session info + tenant_id
    ObObPacket packet;
    packet.code_ = OB_PROXY_SQL_REQUEST;
    packet.tenant_id_ = ctx.tenant_id_;
    packet.sql_ = sql;
    conn.send(packet);
  }
  // 2. 收 result
  int recv_result(ObBackendConnection &conn, ObResultSet &result) {
    // 反序列化 result
  }
};
```

### 6.4 协议转换

```
Client MySQL Packet
    ↓ OBProxy MySQL Parser
OB SQL (ObString)
    ↓ OBProxy ObProtocol
OBServer Binary Packet
    ↓ OBServer ObProtocol Process
OBServer Result
    ↓ OBProxy ObProtocol → MySQL Result
MySQL Result Packet
    ↓ Client
```

OBProxy 做 **双向协议转换**。

---

## 7. 连接管理

### 7.1 Client 连接池

```cpp
// src/obproxy/ob_proxy_connection_mgr.cpp:80
class ObProxyConnMgr {
public:
  // 1. 接受 client 连接
  void on_client_connect(ObTcpConnection &conn) {
    // 1.1 分配 client session
    auto *session = new ObClientSession(conn);
    sessions_.put(session->id_, session);
  }
  
  // 2. 维护 client session
  // - session_id 分配
  // - 当前 SQL 状态
  // - 当前事务状态
};
```

### 7.2 Backend 连接池

```cpp
// src/obproxy/ob_proxy_backend_pool.cpp:50
class ObBackendConnPool {
public:
  // 1. 对每个 OBServer 维护 N 个长连接
  // 2. 复用 + 失败重建
  std::unordered_map<ObAddr, std::vector<ObBackendConn *>> pool_;
  
  // 3. 借 / 还
  ObBackendConn *acquire(ObAddr server) {
    auto &pool = pool_[server];
    if (!pool.empty()) {
      auto *conn = pool.back();
      pool.pop_back();
      return conn;
    }
    return create_new(server);
  }
  
  void release(ObAddr server, ObBackendConn *conn) {
    pool_[server].push_back(conn);
  }
};
```

### 7.3 连接复用

```
不用连接复用:
  Client SQL → 新建 OBServer 连接 → 执行 → 关闭
  每次 SQL ~10-50ms 延迟(connection overhead)

用连接复用:
  Client SQL → 拿 backend 连接(已存在) → 执行 → 还
  每次 SQL ~1-5ms 延迟(无 connection overhead)
```

**连接复用让 OBProxy 比直连 OBServer 还快**(对短查询)。

### 7.4 连接保活

```cpp
// src/obproxy/ob_proxy_keepalive.cpp:50
// 定期发心跳,防止连接被中间设备关
class ObKeepalive {
public:
  void keepalive_loop() {
    while (running_) {
      for (auto &conn : all_conns_) {
        if (conn.is_idle_too_long()) {
          send_ping(conn);
        }
      }
      sleep(60s);
    }
  }
};
```

---

## 8. Result Cache

### 8.1 适用场景

```
适合 cache:
  - SELECT * FROM config WHERE id = 1;  (极少变)
  - SELECT count(*) FROM small_table;   (可容忍旧值)
  - 主键查询 + 不要求强一致

不适合 cache:
  - 写操作
  - 强一致读
  - 高频更新表的查询
```

### 8.2 实现

```cpp
// src/obproxy/ob_proxy_result_cache.cpp:80
class ObResultCache {
public:
  // key: (tenant_id, sql_text, sql_params)
  // value: result set (序列化)
  std::unordered_map<CacheKey, CachedResult> cache_;
  
  std::optional<ObResultSet> get(const ObString &sql, 
                                   const ObSession &session) {
    auto key = make_key(sql, session);
    auto it = cache_.find(key);
    if (it != cache_.end() && !it->second.is_expired()) {
      return it->second.result;
    }
    return std::nullopt;
  }
};
```

### 8.3 失效策略

```cpp
// 1. TTL(默认 60s)
// 2. 写时失效(写同一张表 → 清缓存)
// 3. LRU 淘汰
class ObResultCache {
  std::chrono::seconds ttl_ = std::chrono::seconds(60);
  std::list<CacheKey> lru_;  // LRU 列表
  size_t max_size_ = 1024 * 1024 * 1024;  // 1GB
};
```

### 8.4 命中率

```
典型命中率:
  - 主键查询: 90%+
  - 报表查询: 50-70%
  - 高频查询: 80%+

生产配置:
  - 默认开启 result cache
  - TTL 60s(可调)
  - 容量 1GB(可调)
```

---

## 9. SQL Audit

### 9.1 OBProxy 的 Audit

```cpp
// src/obproxy/ob_proxy_audit.cpp:80
// OBProxy 记录所有 client → server 的 SQL
class ObProxyAudit {
public:
  // 1. SQL 记录
  struct AuditRecord {
    uint64_t trace_id_;
    uint64_t tenant_id_;
    std::string user_;
    std::string client_ip_;
    std::string sql_text_;
    int64_t exec_time_us_;
    int64_t rows_returned_;
    // ...
  };
  
  // 2. 周期性 flush 到 RS
  void flush_loop() {
    while (running_) {
      if (records_.size() > 1024) {
        rpc_.call(RS_ADDR, OB_RS_AUDIT_RECORDS, records_);
        records_.clear();
      }
      sleep(10s);
    }
  }
};
```

### 9.2 Audit vs Slow Query

```
Audit: 所有 SQL(完整记录)
Slow Query: 只慢 SQL(超过阈值)

两者都是慢查询分析的数据源,但 slow query 是 audit 的子集。
```

---

## 10. 性能优化

### 10.1 减少跳数

```
Client → OBProxy → OBServer: 2 跳
Client → OBProxy → OBServer → OBServer2 (DAS): 3 跳
```

OBProxy 让 **client 端的复杂度隐藏在 OBProxy 后**,减少 client 的复杂度。

### 10.2 批量 SQL

```cpp
// client 一次发多条 SQL(批处理)
INSERT INTO t VALUES (1), (2), (3), (4), ...;

// OBProxy: 解析 + 路由 + 转发(整批)
// OBServer: 单批 INSERT 性能高
```

### 10.3 Prepared Statement

```sql
PREPARE stmt FROM 'SELECT * FROM t WHERE a = ?';
EXECUTE stmt USING 5;
EXECUTE stmt USING 10;
```

OBProxy 缓存 prepared plan,避免每次重新 parse。

### 10.4 异步 IO

```cpp
// src/obproxy/ob_proxy_async_io.cpp:50
// OBProxy 用 epoll + 异步 IO
// 不阻塞 client IO → 支持高并发
```

---

## 11. HA

### 11.1 多 OBProxy

```
多个 OBProxy 部署(通常 2-4 个)
  ↓
Client 通过 VIP / DNS 轮询访问
  ↓
某个 OBProxy 挂了,客户端切到其他
```

### 11.2 OBProxy 选主

```
场景: OBProxy A 挂了
  ↓
Client 连接失败
  ↓
DNS / VIP 切到 OBProxy B
  ↓
OBProxy B 重新拉元数据(从 RS)
  ↓
恢复服务

延迟: ~5-10s(取决于 DNS 缓存刷新)
```

### 11.3 OBProxy 自己的 HA

```
OBProxy → RS 心跳(每 1s)
  ↓
OBProxy 挂 → RS 检测(5s 超时)
  ↓
其他 OBProxy 接管路由
```

### 11.4 OBProxy 与 OBServer 解耦

```
关键点:
  - OBProxy 不存数据 → OBProxy 挂了无数据丢失
  - OBProxy 不参与事务 → 挂了不影响事务一致性
  - OBProxy 只是路由 + 转发 → 重新启动即可恢复
```

OBProxy 是 **stateless** 的,可以随时重启 / 扩容。

---

## 12. 监控与调优

### 12.1 关键指标

```sql
-- OBProxy 不直接接 SQL,看 OBProxy 自己的指标
SELECT * FROM oceanbase.__all_virtual_proxy_stat\G

-- 关键字段:
-- proxy_id_: OBProxy ID
-- active_client_connections_: 当前 client 连接数
-- active_server_connections_: 当前 backend 连接数
-- sql_count_: SQL 总数
-- qps_: 每秒 SQL 数
-- avg_latency_us_: 平均延迟
-- client_data_bytes_: 客户端下行字节
-- server_data_bytes_: 服务端上行字节
```

### 12.2 慢 OBProxy 排查

```sql
-- 找 latency > 10ms 的 OBProxy
SELECT proxy_id_, avg_latency_us_
FROM oceanbase.__all_virtual_proxy_stat
WHERE avg_latency_us_ > 10000
ORDER BY avg_latency_us_ DESC;
```

### 12.3 调优参数

```sql
-- Client 连接池
ALTER PROXY SET client_connection_pool_size = 2048;

-- Backend 连接池
ALTER PROXY SET server_connection_pool_size = 128;

-- Result cache
ALTER PROXY SET enable_result_cache = true;
ALTER PROXY SET result_cache_ttl = '60s';

-- 路由策略
ALTER PROXY SET route_strategy = 'LEAST_LATENCY';
```

### 12.4 OBProxy 性能监控

```bash
# 看 OBProxy 实时 QPS
obclient -hproxy -P2883 -e "SHOW PROXY STAT" \G

# 看慢 SQL(转发到 RS)
obclient -hproxy -P2883 -e "SELECT * FROM oceanbase.__all_virtual_slow_query" \G
```

---

## 13. 性能 vs 代价

### 13.1 OBProxy 的代价

| 代价 | 描述 |
|------|------|
| **额外跳数** | Client → OBProxy → OBServer (2 跳) |
| **OBProxy 单点** | 一个 OBProxy 挂了,client 切到备 |
| **配置复杂** | 需要维护 OBProxy 集群 |

### 13.2 OBProxy 的收益

| 收益 | 描述 |
|------|------|
| **透明路由** | client 不需知道 OBServer 地址 |
| **协议兼容** | MySQL / Oracle 客户端都能连 |
| **连接复用** | 减少 backend connection overhead |
| **Result Cache** | 减少 OBServer 压力 |
| **限流 / 审计** | 集中入口便于管控 |

### 13.3 OBProxy 是否必须

```
必须:
  - 多租户集群
  - 读写分离场景
  - HA / failover 关键

可选:
  - 单 OBServer (直接连,无代理)
  - 简单应用 (MySQL 客户端兼容即可)
```

---

## 14. 与 v2 主线的连接

### 14.1 与 SQL Engine Entry(接 #35)

```
Client → OBProxy → OBServer SqlService
                       接 #35 SQL Engine Entry
```

### 14.2 与 RPC(接 #27)

```
OBProxy ↔ OBServer: OB 内部协议 (高效二进制)
  ↓
OBProxy ↔ Client: MySQL/Oracle 协议 (兼容)
```

### 14.3 与 Tenant(接 #28)

```
OBProxy 拉 tenant 元数据(从 RS)
  ↓
每个 SQL 带 tenant_id → 路由到对应 tenant 的 unit
```

### 14.4 与 Primary / Standby(接 #26)

```
弱读 → OBProxy 路由到 STANDBY
强读 / 写 → OBProxy 路由到 PRIMARY
```

### 14.5 与 Slow Query(接 #29)

```
OBProxy 记录 SQL → 上报 RS
  ↓
RS 汇总到 __all_virtual_slow_query
```

---

## 15. 调优 Checklist

```
□ OBProxy 数量是否够?(建议 ≥ 2)
□ 路由策略是否合理?(读多 → LEAST_LATENCY,写多 → PRIMARY)
□ Result Cache 是否启用?(读多可以开)
□ Connection Pool 大小是否合理?(默认够用)
□ OBProxy 心跳是否正常?(RS 心跳每 1s)
□ OBProxy 延迟是否 SLA 内?(< 5ms)
□ 协议兼容是否测试过?(MySQL / Oracle 客户端)
□ 客户端配置是否正确?(VIP / DNS 切换)
□ Audit 记录是否足够?(默认开)
□ OBProxy 重启是否平滑?(stateless, 应该秒级)
```

---

## 16. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → #28 v2 → #19 
v2 → #20 v2 → #27 v2 → #30 v2 → #31 v2 → #34 v2 → #35 v2 → #36 v2 → **#37 
v2 (本文)** 是 OB **storage / index / CBO / join / cache / 调优 / 日志 / 事
务 / schema / 并行 / HA / 容灾 / 多租户 / parser / compaction / RPC / 监
控 / 分区 / SQL 引擎 / 列存 OLAP / OBProxy** 全主线:

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
| #27 v2 | RPC / obrpc | 网络层 | 序列化 + 路由 + 重试 + epoll/io_uring |
| #30 v2 | Monitoring / Alerting | 可观测层 | Metrics + ASH + Alert + Dashboard |
| #31 v2 | Partition Management | 数据分布层 | Rebalance + Migration + 副本切换 |
| #34 v2 | Storage Engine Internals | 磁盘存储层 | SSTable / Macro Block / Micro Block + 压缩/加密/checksum |
| #35 v2 | SQL Engine Entry | 前端入口层 | Connection + Tenant + Pipeline + Resource |
| #36 v2 | Columnar Storage / OLAP | 分析查询层 | 列存编码 + 向量化 + OLAP CBO + HTAP |
| **#37 v2 (本文)** | **OBProxy** | **代理层** | **路由 + 协议兼容 + 连接复用 + Result Cache** |

二十四篇连起来,读者能完整理解 OB 的"Client → Proxy → OBServer → 内部
→ 磁盘 → 集群 → 运维"全链路:

- Client 入口:#37 (本文:OBProxy)
- SQL 引擎:#35 (SqlService) + #19 (Parser) + #17 (Optimizer) + #18 (Index)
- 执行:#41 (Join) + #24 (PX) + #36 (向量化)
- 存储:#14-#16 (MemTable) + #34 (行存) + #36 (列存) + #51 (Cache)
- 持久化:#22 (Clog) + #20 (Compaction)
- 事务:#11 (Trans Service)
- 元数据:#21 (Schema)
- 多租户:#28 (Tenant)
- HA + DR:#26 + #33
- 网络:#27 (RPC) + #37 (本文:OBProxy ↔ Client/Server)
- 运维:#29 (Slow Query) + #30 (Monitoring)
- 分区:#31 (Partition Mgmt)

---

## 17. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **#38 v2 用户权限 / 安全管理** — 角色 + grant + 审计
- **#39 v2 全局时间服务 (GTS)** — 高精度分布式时间
- **#40 v2 自增列 / Sequence** — 主键生成机制
- **源码深挖** — 选具体源文件做完整 review
- **实战 case study** — 跨机房容灾 / HTAP / OLAP 调优

继续哪一篇?

---

## 18. 参考(可执行的源码锚点)

- `src/obproxy/ob_proxy_main.cpp` — 主入口
- `src/obproxy/ob_proxy_route.cpp` — 路由策略
- `src/obproxy/ob_proxy_mysql.cpp` — MySQL 协议
- `src/obproxy/ob_proxy_ob_protocol.cpp` — OB 内部协议
- `src/obproxy/ob_proxy_connection_mgr.cpp` — Client 连接管理
- `src/obproxy/ob_proxy_backend_pool.cpp` — Backend 连接池
- `src/obproxy/ob_proxy_audit.cpp` — SQL Audit
- `src/obproxy/ob_proxy_result_cache.cpp` — Result Cache
- `src/obproxy/ob_proxy_monitor.cpp` — 监控
- `src/obproxy/ob_proxy_keepalive.cpp` — 心跳保活
- `src/obproxy/ob_proxy_smart_route.cpp` — 智能路由
- `src/obproxy/ob_proxy_rs_client.cpp` — 集群发现
- `src/obproxy/ob_proxy_route_table.cpp` — 路由表
- `src/obproxy/ob_proxy_async_io.cpp` — 异步 IO

---

#37 v2 完。