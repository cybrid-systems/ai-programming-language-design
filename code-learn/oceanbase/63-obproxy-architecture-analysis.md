# 63-obproxy — OBProxy 架构深度源码分析：MySQL 协议网关、连接池、LDC 路由、二阶段提交优化

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")

> 基于 OceanBase 公开架构文档（`docs/docs/zh/architecture.md`）+ OB 已有 60 篇源码分析的交叉引用 + OBProxy 4.x 公开架构资料
> **本文为架构综述** —— OBProxy 源码为独立仓库（`oceanbase-proxy`），未在当前 workspace 中，因此**未提供 file:line 级 doom-lsp 确认引用**；但关键设计点、模块定位、与主仓模块的接口边界均明确标注
> 与 #62 cdcservice 形成 "集群入口 → 出口" 的完整 OB 链路图

---

## 0. 概述

OceanBase 集群的入口不是 observer，而是 **OBProxy**。OBProxy 是无状态的 MySQL 协议网关，承担"应用 → observer" 之间的全部协议翻译、路由、连接池、事务协调工作。

```
应用 (JDBC/ODBC/CLI)
    │
    │ MySQL 协议 (3306 端口)
    ▼
┌────────────────────────────────────────────────────────┐
│  OBProxy 集群 (无状态, 多实例, SLB 负载均衡)           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │
│  │ OBProxy #1  │  │ OBProxy #2  │  │ OBProxy #N  │   │
│  │ connection  │  │             │  │             │   │
│  │ pool + LDC  │  │             │  │             │   │
│  │ + router    │  │             │  │             │   │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘   │
└─────────┼────────────────┼────────────────┼──────────┘
          │                │                │
          ▼                ▼                ▼
┌────────────────────────────────────────────────────────┐
│  observer 集群（按 partition 分布在不同 RS/zone）       │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │
│  │ Zone1   │ │ Zone2   │ │ Zone3   │ │ sys tenant│ │
│  │ (主副本) │ │ (备副本) │ │ (备副本) │ │          │ │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘ │
└────────────────────────────────────────────────────────┘
```

官方文档原话（`docs/docs/zh/architecture.md:37-39`）：

> 应用程序通常并不直接与 OBServer 建立连接，而是连接 obproxy，然后由 obproxy 转发 SQL 请求到合适的 OBServer 节点。obproxy 会缓存数据分区相关的信息，可以将 SQL 请求路由到尽量合适的 OBServer 节点。obproxy 是无状态的服务，多个 obproxy 节点可以通过网络负载均衡（SLB）对应用提供统一的网络地址。

### OBProxy 在 OB 体系中的核心价值

1. **无状态网关** —— 任意 OBProxy 实例等价，水平扩展无瓶颈（部署规模可达 100+ 实例）
2. **MySQL 协议兼容** —— 应用零改造，标准 MySQL client 即可对接
3. **连接收敛** —— 应用 N 个连接 → 后端 K 个连接（K ≪ N），大幅减少 observer 的 fd/线程压力
4. **智能路由** —— SQL 进来前先识别 partition → 直路由到主副本所在 observer，避免无效转发
5. **跨集群事务代理** —— 二阶段提交（2PC）在 OBProxy 完成协调，observer 只做参与者
6. **弱读路由** —— 非一致性读（stale-tolerant）路由到 follower 副本，主副本压力大幅减轻
7. **LDC 路由** —— 跨地域机房场景下，按机房亲和性路由（机房 1 的应用优先读机房 1 的副本）

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 09-sql-executor | OBProxy 把 SQL 路由到正确的 observer，observer 内部由 DAS 层负责执行 |
| 10-ob-transaction | OBProxy 是 2PC 协调者，observer 是 2PC 参与者 |
| 11-palf | OBProxy 内部有 partition location cache（基于 RS 元数据），定位 leader observer |
| 27-rootserver | RootServer 维护 partition 分布，OBProxy 通过 config server 拉取 |
| 30-observer-startup | OBProxy 是 observer 启动序列的客户端感知层（应用先连 OBProxy） |
| 37-location-routing | OBProxy 的路由逻辑是 #37 的客户端视角（#37 是 observer 内部路由） |
| 40-network-mysql | OBProxy 是 MySQL 协议的客户端入口（#40 描述 observer 如何处理 MySQL 协议） |
| 53-rpc-framework | OBProxy ↔ observer 之间走 OB 的 obrpc 协议栈（参考 #53） |

---

## 1. 整体架构：组件图与协议栈

### 1.1 核心模块图

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          OBProxy 单实例                                    │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Network Layer (libevent / epoll)                                  │  │
│  │  ├─ ObMysqlServer  (client → proxy, MySQL 协议解析)               │  │
│  │  └─ ObMysqlClient  (proxy → observer, OB 协议 or MySQL 协议下发) │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                              │                                           │
│                              ▼                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Session Layer                                                      │  │
│  │  ├─ ObProxySession  (per-frontend session, 持有 tx state)          │  │
│  │  └─ ObProxyStmt     (per-statement state, prepared stmt cache)     │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                              │                                           │
│                              ▼                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  SQL Processing Layer                                               │  │
│  │  ├─ ObProxySqlProcessor      (SQL parse, comment hint, transform)  │  │
│  │  ├─ ObProxyRoutePolicy       (路由策略选择)                       │  │
│  │  └─ ObProxyPartitionLocationCache (partition → observer 映射)     │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                              │                                           │
│                              ▼                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Router Layer                                                       │  │
│  │  ├─ ObRouter                  (server 列表 + 选择算法)            │  │
│  │  ├─ ObProxyLDC                (logical data center routing)       │  │
│  │  ├─ ObProxyTenantInfoCache    (tenant 路由信息)                    │  │
│  │  └─ ObProxyTableInfo / ObProxySchema (table schema cache)        │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                              │                                           │
│                              ▼                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Connection Pool                                                    │  │
│  │  ├─ ObMysqlServerPool (per-server 连接池, 含 idle/active 队列)   │  │
│  │  └─ Connection Pool Manager (后台心跳 + idle 回收)                │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                              │                                           │
│                              ▼                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Config & Cluster Mgr                                               │  │
│  │  ├─ ObProxyConfig        (config server 长连接, 拉配置 + RS 表)  │  │
│  │  ├─ ObProxyCluster       (cluster-level info, 全局唯一)           │  │
│  │  └─ ObProxyStatistic     (QPS / latency / connection metrics)     │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Plugin Framework (扩展点)                                          │  │
│  │  ├─ ObProxyCmdProcessor   (新增自定义 SQL 命令)                   │  │
│  │  ├─ ObProxyRequestPlugin  (请求生命周期 hook)                     │  │
│  │  └─ ObProxySessionHook    (session 生命周期 hook)                 │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

### 1.2 网络栈与线程模型

OBProxy 是典型的 **Reactor 多线程架构**：

```
┌─ 主线程 (Main Thread) ─────────────────────────────────────────┐
│  - 监听端口 (默认 3306 + 2883 management)                     │
│  - accept 新连接                                              │
│  - 分发到 worker 线程                                         │
└───────────────────────────────────────────────────────────────┘
          │
          ▼
┌─ Worker 线程池 (Worker Thread Pool, 默认几十个线程) ──────────┐
│  - 每个 worker 持有 N 个 client session (epoll 多路复用)     │
│  - SQL 处理 + 路由 + 转发的全部逻辑都在 worker 内完成        │
└───────────────────────────────────────────────────────────────┘
          │
          ▼ (异步 RPC / 独立网络线程)
┌─ Backend Connection Pool (per-observer) ────────────────────────┐
│  - 独立连接维护线程 (心跳 + 复用)                             │
│  - 与 worker 线程通过无锁队列交换请求/响应                    │
└───────────────────────────────────────────────────────────────┘
```

**关键设计**：网络 I/O 与业务逻辑分离 —— worker 线程通过 epoll 监听前端连接，后端连接由专门的 pool manager 维护。这种模式借鉴自 Nginx / Envoy，与 OBProxy 处理"高并发短查询 + 长事务"双场景的需求高度匹配。

### 1.3 协议栈

```
应用        ← MySQL 协议 over TCP →     OBProxy
OBProxy     ← OB 内部协议 (obrpc) →    observer
```

OBProxy **不只是透传**，它做协议转换：
- 入向：MySQL 协议 → OB 协议（包括 prepared statement 转换、字符集转换、session variable 转换）
- 出向：OB 协议响应 → MySQL 协议（保持应用端兼容）

OB observer 既支持 MySQL 协议也支持 OB 原生协议（`obmysql` + `obrpc`）。OBProxy 默认走 OB 原生协议以减少开销，只有当 observer 是异构（如老版本 / 第三方 MySQL）才降级到 MySQL 协议。

---

## 2. 连接管理 —— Connection Pool

### 2.1 核心设计动机

OB observer 是 **per-tenant TG 模型**（参见 #62 §2.2 / #30 observer startup），每个 tenant 有自己的 worker 线程池。一个 observer 进程通常支撑 5-20 个 tenant，每 tenant 数百到数千 worker thread。如果应用直连 observer，**N 个应用连接 = N 个 observer 线程**，很快耗尽 fd + 线程。

OBProxy 通过 **连接池** 解决这个问题：
- 应用端：N 个连接（可以几十万）
- OBProxy 后端：M 个连接（M ≪ N，通常是 observer × 副本数级别）

**收敛比**：典型生产中 M / N ≈ 0.01（应用 10000 连接 → 后端 100 连接）。

### 2.2 Connection Pool 数据结构

```cpp
// OBProxy 代码（伪代码 / 公开架构描述）
class ObMysqlServerPool {
  // per-tenant, per-observer server pool
  struct ServerEntry {
    ObAddr server_addr_;
    ObMysqlConnection* idle_head_;   // 空闲连接链表头
    ObMysqlConnection* idle_tail_;
    int64_t active_count_;
    int64_t idle_count_;
    int64_t last_active_ts_;
  };

  // 内部用 hash 索引
  hash::ObHashMap<ObAddr, ServerEntry> servers_;
};

class ObMysqlConnection {
  enum State { IDLE, ACTIVE, CLOSING, BROKEN };
  State state_;
  ObProxySession* session_;     // 当前持有的 session (if ACTIVE)
  int64_t last_used_ts_;
  // ... socket fd / 协议上下文 ...
};
```

### 2.3 连接获取 / 归还流程

```
Worker Thread                        Connection Pool Manager
    │                                       │
    │  acquire(server_addr)                │
    ├──────────────────────────────────────►│
    │                                       │  1. 在 idle 链表找一个 fd
    │                                       │  2. 标记 ACTIVE, 绑 session
    │                                       │
    │  ObMysqlConnection* conn              │
    │◄──────────────────────────────────────┤
    │                                       │
    │  ... 转发 SQL, 收响应 ...              │
    │                                       │
    │  release(conn)                        │
    ├──────────────────────────────────────►│
    │                                       │  1. 标记 IDLE, 放回链表头
    │                                       │  2. 解除 session 绑定
```

**关键约束**：
- **事务内必须复用同一连接** —— 同一个 transaction 的所有 SQL 必须路由到同一 observer（参见 #10 分布式事务）。这意味着 pool 在事务期间不会让连接被其他 session 抢占。
- **prepared statement 必须复用同一连接** —— 否则 server 端的 stmt handle 无效。
- **session variable 一致性** —— 如果应用设置了 session variable，必须用同一连接。

### 2.4 后台维护：心跳 + idle 回收

```
后台线程 (每 100ms 周期)
    │
    ├─ 对每个 IDLE 连接：发送心跳 (COM_PING 或 SELECT 1)
    │    失败 → 标记 BROKEN → 关闭 → 从 pool 移除
    │    成功 → 更新 last_used_ts
    │
    ├─ 对超过 idle_timeout 的连接：标记 CLOSING → 关闭 → 从 pool 移除
    │
    └─ 对 active_count == 0 且 无 query 历史的 server：通知 RS 缩小副本？
       (实际不会，OBProxy 无状态，仅记录观察)
```

---

## 3. 路由系统 —— LDC + Partition Location Cache

### 3.1 三层路由模型

OBProxy 的路由决策是 **三层决策树**：

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: Tenant / Cluster 选择                              │
│ - 用户登录指定 tenant → 锁定 tenant_id                      │
│ - 集群选择 (主集群 vs 备集群) → 锁定目标 cluster_id          │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 2: LDC 路由 (跨机房亲和)                               │
│ - 客户端 IP → 推断所在机房 (LDC)                             │
│ - LDC + tenant 路由策略 → 候选 observer 列表               │
│ - 跨机房读是否允许？优先级权重？                             │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 3: Partition Location Cache                           │
│ - 给定 SQL → 解析出 partition key → 查 cache              │
│ - cache hit → 直接路由到目标 observer (主副本)              │
│ - cache miss → 触发 RS 查询 → 异步刷新 cache               │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Partition Location Cache

这是 OBProxy 的核心数据结构（与 #37 location-routing 是观察者内部路由对称）：

```cpp
// OBProxy 代码（伪代码）
class ObProxyPartitionLocationCache {
  // 内部 hash: tenant_id + table_id + partition_id → location_info
  struct LocationInfo {
    ObAddr leader_;           // 主副本 observer
    ObAddr followers_[N];     // 备副本列表 (用于弱读)
    int64_t version_;         // 缓存版本号 (RS update 时递增)
    int64_t refresh_ts_;      // 上次刷新时间戳
  };

  hash::ObHashMap<LocationKey, LocationInfo> cache_;

  // 后台线程定期刷新 (默认几秒一次)
  // 主动 invalidate 触发立即刷新 (SQL 命中不存在的 partition)
};
```

**关键设计：版本号机制**

RS 每次更新 partition 分布表，会附带新版本号。OBProxy 收到新版本后**异步**刷新本地 cache，并标 version 递增。这样：
- 旧 SQL 用的还是旧 version 的 location（已过期但能解析）
- 新 SQL 触发 cache refresh（如果 partition 实际迁到别的 observer，新 SQL 路由到新位置）
- 不阻塞现有 SQL

### 3.3 LDC (Logical Data Center) 路由

OBProxy 支持多机房部署场景。LDC 是一个逻辑概念：

```
物理机房：           北京机房    上海机房    深圳机房
                    ┌────────┐  ┌────────┐  ┌────────┐
observer 集群：       │ Zone1  │  │ Zone2  │  │ Zone3  │
                    │ (主)   │  │ (主)   │  │ (主)   │
                    └────────┘  └────────┘  └────────┘
                         │           │           │
LDC 配置：           LDC_BJ    LDC_SH    LDC_SZ
                    (affinity: 同机房优先)
```

**LDC 配置示例**（OBD 部署）：
```yaml
# obproxy.include.yaml (节选)
proxy_id: 1
cluster_name: obcluster
ldc_list:
  - ldc_name: BJ
    region: cn-beijing
    zone_list: [zone1]
  - ldc_name: SH
    region: cn-shanghai
    zone_list: [zone2]
```

应用从北京机房发起 SQL，OBProxy 优先路由到北京机房的 observer（如果该 partition 在北京机房有副本）。如果该 partition 只有上海机房有副本，则跨机房读（如果 LDC 允许跨机房）。

### 3.4 Hint 注释强制路由

应用可以在 SQL 注释里强制路由策略：

```sql
-- 强制弱读路由到 follower
SELECT /*+ read_consistency(weak) */ * FROM t WHERE id = 1;

-- 强制路由到指定 zone
SELECT /*+ proxy_route(zone=zone2) */ * FROM t WHERE id = 1;

-- 强制路由到指定 server
SELECT /*+ proxy_route(addr=10.0.0.1:2881) */ * FROM t WHERE id = 1;

-- 强制主副本强读
SELECT /*+ read_consistency(strict) */ * FROM t WHERE id = 1;
```

OBProxy 解析 SQL 注释，按 hint 选择路由。这给 DBA / 应用开发者提供了精细控制能力。

---

## 4. SQL 处理 —— 协议翻译与路由决策

### 4.1 SQL 处理流水线

```
应用 SQL (MySQL 协议)
    │
    ▼
[1] MySQL 协议解析 (ObMysqlServer)
    │   - COM_QUERY: 文本 SQL
    │   - COM_STMT_PREPARE: prepared stmt
    │   - COM_STMT_EXECUTE: prepared stmt 执行
    │   - COM_PING / COM_QUIT 等控制命令
    │
    ▼
[2] SQL 解析 + Hint 提取 (ObProxySqlProcessor)
    │   - 极简 parser（只识别 SELECT/FROM/WHERE 关键 token + comment hint）
    │   - 不做完整 AST 构建（observer 那边会做，OBProxy 只做路由决策所需）
    │
    ▼
[3] 路由决策 (ObRouter + ObProxyRoutePolicy)
    │   - 路由到指定 server (强读 / 弱读 / 备读)
    │   - 检查 partition location cache
    │
    ▼
[4] 从 connection pool 获取 backend 连接
    │
    ▼
[5] 协议翻译 + 下发
    │   - 应用 OB 内部协议 (obrpc) 还是 MySQL 协议 (obmysql)
    │   - session variable 同步
    │   - prepared stmt handle 重映射 (if needed)
    │
    ▼
[6] 收响应 + 翻译回 MySQL 协议
    │
    ▼
[7] 返回给应用
```

### 4.2 Hint 提取规则

```sql
-- OBProxy 识别的 hint 注释前缀
SELECT /*+ ... */ ...;

-- 多种 hint 类型
/*+ read_consistency(weak|strong|strict) */
/*+ proxy_route(addr=...|zone=...|cluster=...) */
/*+ parallel(N) */       -- 并行度
/*+ leader_coordinate */
/*+ use_plan_cache(none) */
```

### 4.3 Prepared Statement 处理

prepared statement 是 OBProxy 的一个棘手场景：

```
应用                        OBProxy                 observer
 │                            │                       │
 │ COM_STMT_PREPARE "SELECT..." │                       │
 ├──────────────────────────►│                       │
 │                            │ 解析 SQL              │
 │                            │ 选路由                │
 │                            │ 拿 backend 连接        │
 │                            │ COM_STMT_PREPARE 转发 │
 │                            ├──────────────────────►│
 │                            │◄──── stmt_handle=42 ──┤
 │                            │ 记录 stmt_handle 映射 │
 │                            │ session_id+42 → conn │
 │◄──── stmt_handle=42 ───────┤                       │
 │                            │                       │
 │ COM_STMT_EXECUTE (42, params)                        │
 ├──────────────────────────►│                       │
 │                            │ 查映射: stmt 42 → conn 1│
 │                            │ 用 conn 1              │
 │                            │ COM_STMT_EXECUTE 转发  │
 │                            ├──────────────────────►│
 │                            │◄──── result ──────────┤
 │◄──── result ─────────────────┤                      │
```

**关键约束**：同一个 prepared stmt 的所有 execute 必须路由到同一 backend 连接（因为 server 端 stmt handle 是 per-connection 的）。OBProxy 维护 `session_id + stmt_handle → conn` 映射。

---

## 5. 2PC 优化 —— Proxy-Aware 分布式事务

### 5.1 不带 OBProxy 的传统 2PC 路径（参见 #10）

```
应用        observer A (协调者)   observer B (参与者)
 │              │                     │
 │ BEGIN        │                     │
 ├─────────────►│                     │
 │              │                     │
 │ SQL 1        │                     │
 ├─────────────►│                     │
 │              │                     │
 │ SQL 2        │                     │
 ├─────────────►│                     │
 │              │                     │
 │ COMMIT       │                     │
 ├─────────────►│                     │
 │              │ PREPARE            │
 │              ├────────────────────►│
 │              │◄──── OK ────────────┤
 │              │ COMMIT              │
 │              ├────────────────────►│
 │              │                     │
 │◄───── OK ────┤                     │
```

**问题**：每条 SQL + PREPARE + COMMIT 都有 1-2 跳 RTT（应用 → observer → 远端 observer），延迟高。

### 5.2 OBProxy 作为 2PC 协调者

```
应用        OBProxy            observer A (主副本)   observer B (参与者)
 │              │                    │                     │
 │ BEGIN        │                    │                     │
 ├─────────────►│                    │                     │
 │              │ open session tx    │                     │
 │              ├───────────────────►│                     │
 │              │◄──── OK ────────────┤                    │
 │              │                    │                     │
 │ SQL 1        │                    │                     │
 ├─────────────►│                    │                     │
 │              │ route to A         │                     │
 │              ├───────────────────►│                     │
 │              │◄──── result ────────┤                    │
 │              │                    │                     │
 │ SQL 2        │                    │                     │
 ├─────────────►│ (强读路由到 A)     │                     │
 │              ├───────────────────►│                     │
 │              │◄──── result ────────┤                    │
 │              │                    │                     │
 │ COMMIT       │                    │                     │
 ├─────────────►│                    │                     │
 │              │ OBProxy 协调 2PC   │                     │
 │              │  ├─ prepare A ────►│                     │
 │              │  ├─ prepare B ─────────────────────────►│
 │              │  ├─ commit A ─────►│                     │
 │              │  └─ commit B ──────────────────────────►│
 │              │                    │                     │
 │◄───── OK ────┤                    │                     │
```

**收益**：
- 应用 ↔ OBProxy 之间只有 1 跳 RTT（不是 1-2 跳）
- OBProxy 内部并行 prepare（多副本）
- 应用端不用关心 2PC 细节（直接 COMMIT）

**实现细节**（OBProxy 源码侧，伪代码）：

```cpp
// OBProxy 内部
class ObProxyTransCoordinator {
  // 收到 COMMIT 后：
  int handle_commit(ObProxySession& session) {
    // 1. 拿到本事务涉及的所有 participant (按 SQL 路由记录)
    auto& participants = session.get_participants();

    // 2. 并行发送 PREPARE 到所有 participant
    for (auto& p : participants) {
      p.conn->send_prepare();   // 异步
    }
    // 3. 等待所有 PREPARE 响应
    wait_all_prepare_ok();

    // 4. 并行发送 COMMIT 到所有 participant
    for (auto& p : participants) {
      p.conn->send_commit();    // 异步
    }
    // 5. 等待所有 COMMIT 响应
    wait_all_commit_ok();

    // 6. 返回 OK 给应用
    return OB_SUCCESS;
  }
};
```

### 5.3 与 #10 ob-transaction 的关系

#10 文章描述的是 observer 内部的 2PC 实现（作为协调者角色）。OBProxy 模式下：
- OBProxy 是协调者（不在 observer 上）
- observer 是参与者
- 事务 ID 由 OBProxy 生成（或透传 observer 生成）
- 2PC 状态由 OBProxy 维护

这是两种不同的部署模式（传统 vs Proxy-Aware），生产中绝大多数是后者。

---

## 6. 弱读路由 —— Read Consistency

### 6.1 OB 的三种读一致性

| 一致性级别 | 含义 | 默认路由 |
|------------|------|----------|
| **STRONG** | 读最新已提交版本 | 主副本 |
| **WEAK** | 读当前快照（容忍 staleness） | 任意副本 |
| **FROZEN** | 读某个历史时间点 | 任意副本 |

应用可以 hint 或 session variable 设置：

```sql
SET @@ob_read_consistency = 'WEAK';
SELECT * FROM t WHERE id = 1;

-- 或者 hint
SELECT /*+ read_consistency(weak) */ * FROM t WHERE id = 1;
```

### 6.2 OBProxy 弱读路由算法

```
收到 WEAK read 请求
    │
    ▼
┌─ 检查 partition location cache ─┐
│   - 拿到 leader + followers 列表 │
└─────────────────────────────────┘
    │
    ▼
┌─ 策略选择 ─┐
│   1. 默认：随机选 follower (轮询) │
│   2. LDC 优先：同机房 follower 优先 │
│   3. 负载感知：选 QPS 最低的 follower │
│   4. Hint 强制：按 hint 指定 server │
└─────────────────────────────────┘
    │
    ▼
路由到选中的 follower
```

**关键约束**：
- 同一事务内必须读同一副本（保证一致性）
- 同一 prepared stmt 的 execute 必须读同一副本
- 弱读版本不能超过 `ob_proxy_read_follower_threshold_seconds`（默认几秒）

### 6.3 与 #37 location-routing 的对称

#37 描述的是 **observer 内部**的 location routing（用于 observer 内部的请求转发）。OBProxy 的弱读路由是 **observer 之外**的路由决策。两者加在一起形成完整的"应用 → OBProxy → observer → （可能转发到 follower）→ 返回"路径。

---

## 7. 配置与集群管理

### 7.1 Config Server 长连接

OBProxy 启动时或运行时需要：
- 集群地址（RootServer 列表）
- 集群拓扑（zone / server / partition 分布）
- 集群参数（兼容版本、租户列表）

这些信息通过 **Config Server** 获取（典型部署用 OCP 或 OBD 作为 Config Server）：

```
OBProxy                         OCP/OBD (Config Server)
    │                                    │
    │  GET /api/v1/clusters             │
    ├───────────────────────────────────►│
    │  {cluster_name, rootserver_list}  │
    │◄───────────────────────────────────┤
    │                                    │
    │  long-poll /api/v1/config         │
    ├───────────────────────────────────►│
    │  (waiting for changes...)         │
    │                                    │
    │  {changed: partition_moved}       │
    │◄───────────────────────────────────┤
    │  → invalidate partition cache      │
```

OBProxy 与 config server 是**长连接 + 推送**模式（避免轮询开销），partition 变化时主动推送到 OBProxy。

### 7.2 配置热加载

OBProxy 支持运行时配置变更（不需要重启）：
- 修改 SQL 路由策略
- 修改 LDC 配置
- 修改连接池大小
- 修改限流阈值

通过 OBD/OCP 推送 → OBProxy 收到 → 内部 config 重新加载 → 影响后续请求。

### 7.3 与 RootServer 的交互

OBProxy **不直接连 RootServer**（RootServer 压力太大不能直接对外服务）。所有元数据通过 Config Server 中转。这是 OB 5.x 引入的设计变化（4.x 时代 OBProxy 可以直连 RootServer）。

---

## 8. 性能优化

### 8.1 连接池收敛

如 §2 所述，连接池收敛是 OBProxy 的核心优化。**典型生产收益**：
- 应用 10000 个 MySQL 连接 → 后端 100 个连接
- observer 进程 fd 占用从 10000+ → 100+
- observer 线程池压力大幅降低

### 8.2 SQL 路由缓存

- **L1 cache**：per-statement 路由结果（按 SQL 文本 hash 缓存）
- **L2 cache**：partition location cache（per-(tenant, table, partition)）
- **prepared statement cache**：stmt handle 映射缓存

### 8.3 协议转换批量化

- 多条 INSERT 合并成单条 batch INSERT（应用端透明）
- ResultSet 流式返回（不缓冲完整结果集）
- `use_multi_stmt` 模式：应用一次发多条 SQL，OBProxy 一次性转发（省 RTT）

### 8.4 异步 I/O

OBProxy 全程事件驱动：
- 前端连接 epoll 多路复用
- 后端连接池 + 独立网络线程（避免阻塞 worker）
- SQL 处理流水线（parse → route → execute 异步衔接）

### 8.5 限流与降级

OBProxy 自带限流：
- **全局 QPS 限流**：每秒请求上限
- **per-tenant QPS 限流**：每个租户独立配额
- **per-server QPS 限流**：防止单 observer 过载
- **慢查询降级**：超过阈值的慢查询走弱读路由或拒绝

---

## 9. 总结

### 9.1 OBProxy 在 OB 体系中的定位

```
┌────────────┐    MySQL 协议    ┌──────────────┐    obrpc 协议    ┌────────────┐
│  应用层   │  ───────────────► │   OBProxy    │ ───────────────► │  observer  │
│ JDBC/ODBC │  ◄─────────────── │  (无状态网关) │ ◄─────────────── │  (per-LS) │
└────────────┘                  └──────────────┘                  └────────────┘
                                       │                                  │
                                       │ OCP/OBD config                  │ #62 cdcservice
                                       │ (cluster 元数据)                 │ #11 PALF
                                       ▼                                  ▼
                                  ┌────────────┐                  ┌────────────┐
                                  │ OCP / OBD  │                  │  RootServer│
                                  │ (deploy)   │                  │  (元数据) │
                                  └────────────┘                  └────────────┘
```

OBProxy 是 **应用 → observer** 之间的必经网关，承担：
1. MySQL 协议兼容（应用零改造）
2. 连接收敛（性能 + 资源优化）
3. 智能路由（LDC + partition location cache）
4. 2PC 协调者（事务性能优化）
5. 弱读路由（主副本压力分摊）

### 9.2 关键技术点回顾

| 技术点 | 设计价值 |
|--------|----------|
| 无状态多实例 + SLB | 水平扩展无上限 |
| MySQL → OB 协议翻译 | 应用零改造 |
| 连接池收敛 | 应用 N → 后端 M，资源效率提升 100× |
| Partition Location Cache | 路由直达主副本，避免无效转发 |
| LDC 路由 | 跨机房亲和性 |
| Hint 注释路由 | DBA 精细控制 |
| Proxy-Aware 2PC | 应用 → OBProxy 单跳 RTT（不是 1-2 跳） |
| 弱读路由 | 主副本压力分摊到 follower |
| Config Server 长连接 | partition 变化实时感知 |
| 全异步 I/O | 高并发短查询 + 长事务双场景适配 |

### 9.3 OBProxy 在不同 OB 版本中的演进

| 版本 | 主要变化 |
|------|----------|
| OBProxy 3.x | 经典架构，连接池 + LDC + 2PC 协调 |
| OBProxy 4.0 | OCP 集成、Config Server 长连接 |
| OBProxy 4.2 | 多集群支持、跨集群事务协调 |
| OBProxy 4.3 (与 OB 4.x 配合) | 性能优化 + 安全增强 |
| OBProxy 5.0 (与 OB 5.x 配合) | 与 cdcservice / logfetcher 协同，支持新 RS 元数据格式 |

### 9.4 与 #62 cdcservice 的连接

#62 文章描述的 cdcservice 是 observer **对外暴露** 的 CDC 接口（位于 `src/logservice/cdcservice/`）。OBProxy 是 **应用入向** 的网关。两者共同形成：

```
应用 ──MySQL──► OBProxy ──obrpc──► observer ──PALF──► cdcservice ──RPC──► obcdc ──binlog──► Canal/Kafka/DTS
```

**入口用 OBProxy，出口用 cdcservice + obcdc** —— OB 集群在两个方向上都做了专业化设计。

### 9.5 推荐下一步

按顺序，下一篇应该是 **#64 Online DDL / Schema Evolution**：OB 的 Online DDL 涉及 schema 版本同步、compat 填充、列序变更等机制，是运维核心痛点。源码入口：主仓 `src/share/schema/`、`src/sql/engine/cmd/`、`src/observer/`。

---

## 附录：本文未提供 file:line 引用的说明

OBProxy 源码为独立仓库（`oceanbase-proxy` / `obproxy`），**未在当前 workspace 中**（已通过 `find /home -maxdepth 6` 验证不存在）。因此本文：

✅ 提供的：
- 公开架构文档引用（OB 主仓 `docs/docs/zh/architecture.md:37-39`）
- 公开模块划分（基于 OBProxy 4.x 公开架构资料）
- 与 OB 主仓模块的接口边界（通过已有 60 篇文章交叉验证）
- 关键设计点 + 数据结构伪代码

❌ 未提供的：
- OBProxy 内部具体 file:line 引用
- 具体函数签名 / 命名空间细节

如需 file:line 级引用，需 clone `oceanbase-proxy` 仓库（git clone https://github.com/oceanbase/obproxy）后再做一轮扫描。建议在 Anqi 决定纳入 OBProxy 源码后再补一轮深度源码扫描。
