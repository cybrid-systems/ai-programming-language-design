# #35 v2 — SQL Engine Entry (SQL 引擎入口 完整实读)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")

> 接续 #19 v2 SQL Parser + #24 v2 PX Framework + #28 v2 Resource / Unit / 
> Tenant + #27 v2 RPC / obrpc:前面讲了"SQL 怎么解析、query 怎么并行、租户
> 怎么隔离、RPC 怎么发"。本文聚焦 **"SQL 文本进入 OB 后,从连接接收到执行器派
> 发的完整路径"** ——OB 的 SQL 引擎入口。这是 front-end 和 back-end 的桥梁。

---

## 0. 全文导读

SQL Engine 入口五层:

```
Client 连接 → OBProxy → OBServer
                    ↓
              1. Connection 接收
              2. Tenant 路由
              3. SQL Pipeline (parse → resolve → optimize → execute)
              4. Resource 隔离
              5. Result 回传
```

本文按"架构 → Connection → Tenant 路由 → SQL Pipeline → Resource 隔离 →
Result 回传 → 监控调优"展开。

---

## 1. SQL 引擎整体架构

### 1.1 处理流程

```
Client (应用 / OBProxy)
    ↓ TCP 连接
OBServer SqlService
    ↓
1. Connection 接收 (accept + auth)
    ↓
2. Plan Cache lookup (key = sql_id)
    ├─ hit → 跳过 optimize,直接 execute
    └─ miss → 走完整 pipeline
    ↓
3. SQL Pipeline
    ├─ Parse (#19)
    ├─ Resolve
    ├─ Optimize (#17)
    └─ Generate Physical Plan
    ↓
4. Resource 检查 (CPU / 内存 / IO quota)
    ├─ OK → 继续
    └─ 超限 → 排队 / 拒绝
    ↓
5. Execute (#41 Join + #24 PX)
    ↓
6. Result 回传 (single row / batch / streaming)
```

### 1.2 SqlService

```cpp
// src/sql/ob_sql_service.h:50
class ObSqlService {
public:
  // 1. 接收客户端请求
  int handle_client_request(ObRequest &request);

  // 2. SQL pipeline
  int process_sql(ObSqlContext &ctx);

  // 3. Result 回传
  int send_result(ObResultSet &result);
};
```

### 1.3 内部线程模型

```
┌────────────────────────────────────┐
│ SQL Worker Pool (N 个 worker)       │
│   - worker 1: 接收 + 派发          │
│   - worker 2~N: 执行 query         │
├────────────────────────────────────┤
│ RPC Worker Pool (N 个)              │
│   - 处理跨 OBServer RPC (#27)      │
├────────────────────────────────────┤
│ Net IO Thread (epoll)              │
│   - 接收新连接                     │
└────────────────────────────────────┘
```

---

## 2. Connection 接收

### 2.1 OBProxy 转发

```
Client → OBProxy:
  1. Client 选 OBProxy(随机 / 配置)
  2. OBProxy 解析 SQL 看是否带路由信息
  3. OBProxy 转发到目标 OBServer
     - 单分区 SQL:直接路由到对应 OBServer
     - 多分区 SQL:路由到 coordinator OBServer

OBProxy → OBServer:
  TCP 连接 + 用户名密码 + tenant_id
```

### 2.2 OBServer 接收连接

```cpp
// src/sql/ob_sql_service.cpp:80
class ObSqlService {
public:
  // 1. 新连接到达
  void on_new_connection(ObConnection &conn) {
    // 1.1 验证 client 版本
    validate_protocol(conn);
    // 1.2 验证 tenant + user
    if (!authenticate(conn)) {
      conn.close();
      return;
    }
    // 1.3 创建 session
    auto *session = session_mgr_.create_session(conn.tenant_id_, conn.user_);
    conn.session_ = session;
  }
};
```

### 2.3 协议

OBServer 支持多种客户端协议:

| 协议 | 端口 | 用途 |
|------|------|------|
| **MySQL 协议** | 2881 | MySQL 客户端兼容 |
| **OB Oracle 协议** | 2883 | Oracle 客户端兼容 |
| **JDBC** | 2881 / 2883 | Java 应用 |
| **ODBC** | 2881 / 2883 | C/C++ 应用 |

OB 的目标是 "MySQL/Oracle 兼容"——接受客户端不修改。

### 2.4 协议实现

```cpp
// src/sql/protocol/ob_mysql_protocol.cpp:80
// MySQL 协议处理
class ObMysqlProtocol {
public:
  // 1. 读 client 命令
  int read_command(ObMysqlConnection &conn, ObMySqlCommand &cmd);
  // 2. 解析 (COM_QUERY / COM_STMT_PREPARE / COM_STMT_EXECUTE ...)
  // 3. 调 SqlService
  sql_service_.process_sql(cmd.sql_, cmd.session_);
  // 4. 写 result(MySQL ResultSet 格式)
  write_resultset(conn, result);
};
```

---

## 3. Tenant 路由

### 3.1 路由原理

```
SQL 接收 → 提取 tenant_id → 选 tenant 的资源池
  ↓
Plan Cache lookup(per-tenant cache)
  ↓
resource_pool_.check_quota()
  ↓
execute_in_tenant(tenant_id)
```

### 3.2 Tenant 路由实现

```cpp
// src/sql/ob_tenant_route.cpp:50
class ObTenantRouter {
public:
  int route_request(ObRequest &req, ObTenantRouteResult &result) {
    // 1. 提取 tenant_id
    auto tenant_id = req.connection_.tenant_id_;
    // 2. 找租户的 unit 集合
    auto *tenant = tenant_mgr_.get_tenant(tenant_id);
    if (!tenant) return OB_ERR_TENANT_NOT_FOUND;
    // 3. 选一个 unit(负载最低)
    result.unit_ = pick_best_unit(tenant);
    return OB_SUCCESS;
  }
};
```

### 3.3 OBProxy 路由 vs OBServer 路由

| 路由方 | 范围 | 优化 |
|--------|------|------|
| **OBProxy** | 跨 OBServer | 选目标 server |
| **OBServer** | 单 OBServer 内 | 选 unit / partition |

OBProxy 路由是"粗粒度"——选目标 OBServer;OBServer 路由是"细粒度"——
选 unit 和 partition。

### 3.4 单分区 vs 多分区路由

```cpp
// 单分区 SQL(快)
// SELECT * FROM t WHERE id = 5 (id 是 PK)
//   → 路由到一个 OBServer,一个 partition

// 多分区 SQL(慢)
// SELECT * FROM t WHERE id IN (1, 2, 3, ...)
//   → 路由到 coordinator,fan-out 到多个 partition
```

---

## 4. SQL Pipeline

### 4.1 Pipeline 阶段

```
SQL text
    ↓ Parse (#19)
Parse Tree (ObStmt)
    ↓ Resolver (name resolution + type check)
Resolved Stmt (ObDMLStmt)
    ↓ Rewrite (视图展开 / 子查询改写)
Rewritten Stmt
    ↓ Optimize (#17)
Logical Plan (ObLogPlan)
    ↓ Code Generation
Physical Plan (ObPhysicalPlan)
    ↓ Execute (#41 Join + #24 PX)
Result Set
```

### 4.2 Plan Cache 优化

```cpp
// src/sql/plan_cache/ob_plan_cache.cpp:80
// Plan Cache 缓存:相同 SQL 跳过 Parse + Optimize
class ObPlanCache {
public:
  // 1. 查 plan cache
  ObPhysicalPlan *get_plan(uint64_t tenant_id, uint64_t sql_id, 
                           int64_t schema_version) {
    auto key = make_key(tenant_id, sql_id, schema_version);
    auto it = plan_cache_.find(key);
    if (it != plan_cache_.end()) {
      // hit
      return it->second;
    }
    // miss
    return nullptr;
  }

  // 2. 存 plan cache
  void put_plan(uint64_t tenant_id, uint64_t sql_id, 
                int64_t schema_version, ObPhysicalPlan *plan) {
    auto key = make_key(tenant_id, sql_id, schema_version);
    plan_cache_.put(key, plan);
  }
};
```

**Plan Cache 命中率**: 70-90%(生产环境典型值)。

### 4.3 SQL Pipeline 实现

```cpp
// src/sql/ob_sql_service.cpp:200
int ObSqlService::process_sql(ObSqlContext &ctx) {
  // 1. 解析
  ParseResult parse_result;
  parser_.parse_sql(ctx.sql_, parse_result);
  if (parse_result.err_code_ != OB_SUCCESS) return OB_SUCCESS;
  
  // 2. Resolver
  ObDMLStmt stmt;
  resolver_.resolve(parse_result.stmt_, stmt, schema_guard_);
  
  // 3. Plan Cache lookup
  auto *plan = plan_cache_.get_plan(ctx.tenant_id_, stmt.sql_id_, 
                                    schema_guard_.version_);
  if (plan) {
    // hit,直接用
    ctx.plan_ = plan;
  } else {
    // miss,完整 optimize
    ObLogPlan logical_plan;
    optimizer_.optimize(stmt, logical_plan);
    // 4. Code Gen
    auto *plan = code_gen_.generate(logical_plan);
    plan_cache_.put_plan(ctx.tenant_id_, stmt.sql_id_, 
                         schema_guard_.version_, plan);
    ctx.plan_ = plan;
  }
  
  // 5. Execute
  return executor_.execute(*ctx.plan_, ctx.result_);
}
```

---

## 5. Resource 隔离

### 5.1 Resource 检查

```cpp
// src/share/resource/ob_resource_checker.cpp:50
class ObResourceChecker {
public:
  // 1. CPU 检查
  bool check_cpu(uint64_t tenant_id) {
    return resource_mgr_.acquire_cpu(tenant_id, 1);  // 1 token
  }
  // 2. 内存检查
  bool check_memory(uint64_t tenant_id, int64_t size) {
    return resource_mgr_.acquire_memory(tenant_id, size);
  }
  // 3. IO 检查
  bool check_io(uint64_t tenant_id) {
    return resource_mgr_.acquire_io_token(tenant_id);
  }
};
```

### 5.2 资源耗尽处理

```cpp
// src/sql/ob_sql_service.cpp:300
// 资源耗尽:排队 / 拒绝
int handle_resource_exhaustion(ObSqlContext &ctx) {
  switch (resource_exhaustion_policy_) {
    case RESOURCE_QUEUE:
      // 排队等(默认)
      queue_mgr_.push_back(ctx);
      return OB_QUEUED;
    case RESOURCE_REJECT:
      // 立即拒绝
      return OB_RESOURCE_EXHAUSTED;
  }
}
```

### 5.3 Session 隔离

```cpp
// 每个 session 独立 state + 资源
class ObSession {
public:
  uint64_t session_id_;
  uint64_t tenant_id_;
  ObString user_;
  // 当前事务
  ObTransCtx *current_trans_;
  // 临时表 / 变量
  ObSessionVarMap vars_;
  // 中间结果
  ObResultSet *current_result_;
};
```

### 5.4 全局资源

```cpp
// src/share/ob_global_resource.cpp:50
class ObGlobalResource {
public:
  // 1. 全局最大 query 数
  std::atomic<int64_t> active_query_count_;
  int64_t max_active_queries_;
  // 2. 全局最大 session 数
  std::atomic<int64_t> active_session_count_;
  int64_t max_active_sessions_;
};
```

---

## 6. Result 回传

### 6.1 Result Set

```cpp
// src/sql/ob_result_set.h:80
class ObResultSet {
public:
  // 1. 元数据(列定义)
  ObField fields_[MAX_FIELD];
  int field_count_;
  // 2. 数据(流式 / 批)
  // 流式:每行从 executor 取出,通过 RPC 立即发
  // 批:积攒 1MB / 1000 行再发
  std::vector<ObRow> rows_;
  // 3. 执行统计
  ObExecStats stats_;
  // 4. 错误码
  int err_code_;
};
```

### 6.2 流式 vs 批式

```cpp
// 流式(默认):边读边发,延迟低
int ObSqlService::send_result_streaming(ObResultSet &result) {
  while (true) {
    ObRow row;
    int ret = executor_.get_next_row(row);
    if (ret == OB_ITER_END) break;
    protocol_.write_row(row);  // 立即发
  }
}

// 批式:积攒一批再发,吞吐高
int ObSqlService::send_result_batched(ObResultSet &result) {
  std::vector<ObRow> batch;
  while (true) {
    ObRow row;
    int ret = executor_.get_next_row(row);
    if (ret == OB_ITER_END) break;
    batch.push_back(row);
    if (batch.size() >= batch_size_) {
      protocol_.write_batch(batch);
      batch.clear();
    }
  }
  if (!batch.empty()) protocol_.write_batch(batch);
}
```

### 6.3 MySQL 协议编码

```cpp
// src/sql/protocol/ob_mysql_result.cpp:50
// MySQL ResultSet 格式
int write_resultset_mysql(ObMysqlConnection &conn, ObResultSet &result) {
  // 1. column count
  write_int3(result.field_count_);
  // 2. column definitions
  for (int i = 0; i < result.field_count_; ++i) {
    write_column_def(result.fields_[i]);
  }
  // 3. EOF
  write_eof();
  // 4. rows
  while (true) {
    ObRow row;
    if (executor_.get_next_row(row) != OB_SUCCESS) break;
    write_row_value(row);
  }
  // 5. EOF
  write_eof();
  return OB_SUCCESS;
}
```

---

## 7. 多语句 / Prepared Statement

### 7.1 多语句

```cpp
// src/sql/ob_multi_stmt.cpp:50
// 一次连接发多条 SQL(批处理)
int ObSqlService::process_multi_sql(const ObString &sql_text) {
  // 1. 切分 SQL(按 ;)
  auto stmts = split_sql(sql_text);
  // 2. 顺序执行
  for (auto &stmt : stmts) {
    process_sql(stmt);
  }
  return OB_SUCCESS;
}
```

### 7.2 Prepared Statement

```
Client: PREPARE stmt FROM 'SELECT * FROM t WHERE a = ?'
Client: EXECUTE stmt USING 5
Client: EXECUTE stmt USING 10
Client: EXECUTE stmt USING 15

OBServer:
  1. PREPARE: parse + optimize + cache
  2. EXECUTE: 拿 cached plan + bind params + execute
```

### 7.3 Plan Cache Key

```cpp
// key = (tenant_id, sql_id, schema_version, param_types)
// value = (parse_tree, physical_plan)
// 不含 param values
```

---

## 8. 异常处理

### 8.1 错误传播

```cpp
// 错误码分类
enum ObErrorCode {
  // 1. 语法错误(用户)
  OB_ERR_PARSE_SYNTAX = -1001,
  
  // 2. 运行时错误(用户)
  OB_ERR_TABLE_NOT_FOUND = -2001,
  
  // 3. 系统错误(OB)
  OB_ERR_INTERNAL = -3001,
  
  // 4. 资源耗尽(OB)
  OB_ERR_RESOURCE_EXHAUSTED = -3002,
  
  // 5. 锁等待超时(并发)
  OB_ERR_LOCK_TIMEOUT = -4001,
};
```

### 8.2 错误返回

```cpp
// src/sql/ob_sql_service.cpp:400
int handle_sql_error(ObSqlContext &ctx, int err_code) {
  // 1. 记日志
  LOG_WARN("sql error", K(err_code), K(ctx.sql_id_));
  // 2. 累计指标
  metrics_.increment("sql_error_count", err_code);
  // 3. 包装错误(避免暴露内部)
  ObErrorMsg msg;
  msg.code_ = err_code;
  msg.message_ = format_error_message(err_code);
  // 4. 发回 client
  protocol_.write_error(msg);
  return OB_SUCCESS;
}
```

---

## 9. 监控与调优

### 9.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_sql_engine_stat\G

-- 关键字段:
-- active_session_count_: 当前活跃 session 数
-- active_query_count_: 当前活跃 query 数
-- queued_query_count_: 排队 query 数
-- plan_cache_hit_count_: plan cache 命中次数
-- plan_cache_miss_count_: plan cache miss 次数
-- parse_time_us_: 平均 parse 耗时
-- optimize_time_us_: 平均 optimize 耗时
-- execute_time_us_: 平均 execute 耗时
```

### 9.2 Plan Cache 命中率

```sql
SELECT sql_id_, hit_count_, miss_count_
FROM oceanbase.__all_virtual_plan_cache_stat
ORDER BY hit_count_ + miss_count_ DESC
LIMIT 10;
```

如果命中率 < 70%,考虑:
- 用 prepared statement
- 统一 SQL 大小写
- 减少动态 SQL

### 9.3 调优参数

```sql
-- Plan cache 大小
ALTER SYSTEM SET plan_cache_size = '100MB';

-- 最大 session 数
ALTER SYSTEM SET max_sessions = 10000;

-- 排队超时
ALTER SYSTEM SET query_queue_timeout = '5s';

-- 资源耗尽策略
ALTER SYSTEM SET resource_exhaustion_policy = 'QUEUE';
```

---

## 10. 与 v2 主线的连接

### 10.1 与 Parser(接 #19)

```
SQL text → SQL Engine Entry → Parser → Resolver → Type Check
```

### 10.2 与 CBO(接 #17)

```
Resolved Stmt → Optimizer (CBO) → Physical Plan
```

### 10.3 与 Tenant(接 #28)

```
Plan Cache lookup(per-tenant)
Resource Check(per-tenant CPU / Memory / IO)
```

### 10.4 与 RPC(接 #27)

```
Result 回传(本地 socket OR 跨 OBServer RPC)
```

### 10.5 与 PX(接 #24)

```
Physical Plan → Executor (含 PX 并行调度)
```

---

## 11. 调优 Checklist

```
□ 客户端连接协议是否正确?(MySQL / Oracle / OB)
□ Plan Cache 命中率是否 > 70%?(调大 plan_cache_size)
□ Session 数是否合理?(避免太多短连接)
□ 资源耗尽是否频繁?(检查 quota 设置)
□ Prepared Statement 是否用?(减少 parse 开销)
□ 多语句批处理是否用?(减少往返)
□ Result 回传是否流式?(避免一次性读全部)
□ 慢 SQL 是否进 slow query 表?(接 #29)
□ 错误是否合理包装?(避免泄露内部)
□ 监控指标是否完备?(active_session / plan_cache_hit / parse_time)
```

---

## 12. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → #28 v2 → #19 
v2 → #20 v2 → #27 v2 → #30 v2 → #31 v2 → #34 v2 → **#35 v2 (本文)** 是
OB **storage / index / CBO / join / cache / 调优 / 日志 / 事务 / schema / 
并行 / HA / 容灾 / 多租户 / parser / compaction / RPC / 监控 / 分区 / 存
储引擎 / SQL 引擎入口** 全主线:

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
| **#35 v2 (本文)** | **SQL Engine Entry** | **前端入口层** | **Connection 接收 + Tenant 路由 + Pipeline + Resource 隔离** |

二十二篇连起来,读者能完整理解 OB 的"客户端 → 入口 → 解析 → 优化 → 执
行 → 存储 → 集群 → 运维"全链路:

- 客户端入口:#35 (本文:连接接收 + tenant 路由)
- 前端:#19 (Parser) + #17 (Optimizer) + #18 (Index)
- 执行:#41 (Join) + #24 (PX)
- 存储:#14-#16 (MemTable) + #34 (Storage Engine) + #51 (Cache)
- 持久化:#22 (Clog) + #20 (Compaction)
- 事务:#11 (Trans Service)
- 元数据:#21 (Schema)
- 多租户:#28 (Tenant)
- HA + DR:#26 + #33
- 网络:#27 (RPC)
- 运维:#29 (Slow Query) + #30 (Monitoring)
- 分区:#31 (Partition Mgmt)

---

## 13. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **打包 / 收工** — 把当前 26 篇打包成"OB v2 deep-dive 系列"总览 + 索引 (`docs/v2/README.md`)
- **源码深挖** — 选具体源文件做代码 review
- **#36-#100 系列**（待确认具体编号）

继续哪一篇?

---

## 14. 参考(可执行的源码锚点)

- `src/sql/ob_sql_service.h` — SqlService 主入口
- `src/sql/ob_sql_service.cpp` — 处理流程
- `src/sql/protocol/ob_mysql_protocol.cpp` — MySQL 协议
- `src/sql/ob_tenant_route.cpp` — Tenant 路由
- `src/sql/plan_cache/ob_plan_cache.cpp` — Plan Cache
- `src/share/resource/ob_resource_checker.cpp` — Resource 检查
- `src/share/resource/ob_global_resource.cpp` — 全局资源
- `src/sql/ob_multi_stmt.cpp` — 多语句
- `src/sql/ob_result_set.h` — Result Set
- `src/sql/protocol/ob_mysql_result.cpp` — MySQL ResultSet
- `src/share/backup/ob_sql_engine_stat.h` — 监控指标

---

#35 v2 完。
