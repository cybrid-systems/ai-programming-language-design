# 40 — 网络服务与 MySQL 协议 — 连接管理、协议处理、请求分发

> 基于 OceanBase CE 主线源码
> 分析范围：`src/observer/mysql/`（94 个文件）
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与代码结构分析

---

## 0. 概述

**最终篇。回到起点。**

前 39 篇文章从磁盘的 macro block、sstable 开始，逐层向上：memtable、transaction、clog、paxos 选举、SQL 引擎、查询优化器、表达式计算、DML 执行路径、并行执行、计划缓存、诊断框架、RootService、GTS、存储合并、并发控制、位置路由、租户架构……一路走到第 30 篇的 OBServer 启动流程。

现在，我们站在 **网络层**——用户进入 OceanBase 的入口。

每一个 SELECT、每一个 INSERT、每一个事务的开始和结束，都始于一个 **MySQL 协议包**。OBServer 如何接受 TCP 连接？如何完成 MySQL 握手和认证？如何将收到的字节流分派给相应的处理逻辑？

这就是第 40 篇的主题：**网络服务与 MySQL 协议**。

```
                  MySQL Client
                       │
                (MySQL Protocol over TCP)
                       │
                       ▼
  ┌───────────────────────────────────────────────────┐
  │               OBServer 网络框架                      │
  │                                                     │
  │  ┌──────────────┐    ┌──────────────────────────┐   │
  │  │  libeasy     │───▶│  ObSqlSockHandler         │   │
  │  │  (event-driven│   │  (MySQL socket processor)  │   │
  │  │   I/O)       │   └───────────┬──────────────┘   │
  │  └──────────────┘               │                  │
  │                                 ▼                  │
  │  ┌──────────────────────────────────────────┐      │
  │  │  ObSMHandler (MySQL handler)              │      │
  │  │  - on_connect()    → 握手包发送            │      │
  │  │  - on_disconnect() → 连接断开通知         │      │
  │  │  - on_close()      → 会话清理             │      │
  │  └───────────┬──────────────────────────────┘      │
  │              │                                     │
  │              ▼                                     │
  │  ┌──────────────────────────────────────────┐      │
  │  │  ObSrvMySQLXlator::translate()            │      │
  │  │  (协议命令 → 处理器分派)                   │      │
  │  └───────┬────────┬────────┬──────┬─────────┘      │
  │          │        │        │      │                │
  │          ▼        ▼        ▼      ▼                │
  │    ObMPConnect  ObMPQuery  ObMPStmt  ...            │
  │                                               │
  │              (丢入租户线程池执行)                    │
  └───────────────────────────────────────────────────┘
```

### 核心分析路径

本文将分析以下关键组件：

| 组件 | 文件 | 职责 |
|------|------|------|
| `ObSMHandler` | `obsm_handler.h/cpp` | 连接生命周期（on_connect/on_disconnect/on_close） |
| `ObSMConnectionCallback` | `obsm_conn_callback.h/cpp` | 连接回调（初始化握手、销毁、断开通知） |
| `ObSrvMySQLXlator` | `ob_srv_xlator.cpp` | MySQL 命令 → 处理器分派（核心路由） |
| `ObMPBase` | `obmp_base.h/cpp` | 所有 MySQL 处理器的基类 |
| `ObMPConnect` | `obmp_connect.h/cpp` | 握手 + 认证 |
| `ObMPQuery` | `obmp_query.h/cpp` | SQL 查询执行入口 |
| `ObMPStmtPrepare` | `obmp_stmt_prepare.h/cpp` | PREPARE 协议处理 |
| `ObMPStmtExecute` | `obmp_stmt_execute.h/cpp` | EXECUTE 协议处理 |
| `ObMySQLResultSet` | `ob_mysql_result_set.h/cpp` | 结果集编码与发送 |
| `ObMySQLRequestManager` | `ob_mysql_request_manager.h/cpp` | 请求生命周期与审计 |

---

## 1. 总体架构

### 1.1 分层设计

OBServer 的 MySQL 协议处理分为三层：

```
┌──────────────────────────────────────────────────────┐
│  协议处理层 (Protocol Handlers)                        │
│  ObMPConnect, ObMPQuery, ObMPStmtPreare...           │
│  职责: 解析MySQL协议包, 调用SQL引擎                    │
├──────────────────────────────────────────────────────┤
│  分派层 (Dispatcher)                                  │
│  ObSrvMySQLXlator::translate()                       │
│  职责: 根据命令类型创建对应的处理器                     │
├──────────────────────────────────────────────────────┤
│  传输层 (Transport Layer)                              │
│  ObSMHandler + ObSMConnectionCallback + libeasy       │
│  职责: TCP连接管理, 握手, 字节流传输                   │
└──────────────────────────────────────────────────────┘
```

**传输层**基于 libeasy 的事件驱动框架。当 libeasy 收到新的 TCP 连接时，触发 `on_connect` 回调；当连接关闭时，触发 `on_close` 回调。MySQL 协议包到达后，通过 `ObSrvMySQLXlator` 分派到具体的处理器。

### 1.2 命令到处理器的映射

`ObSrvMySQLXlator::translate()`（`src/observer/ob_srv_xlator.cpp`，第 169 行）是 MySQL 命令分派的核心入口：

```cpp
int ObSrvMySQLXlator::translate(rpc::ObRequest &req, ObReqProcessor *&processor)
```

分派逻辑：
- **连接阶段**（`is_in_connected_phase()`）：使用 `ObMPConnect` 处理器 → 握手处理
- **正常查询阶段**，根据 `pkt.get_cmd()` 选择：
  - `COM_QUERY` → `ObMPQuery`（第 186 行）
  - `COM_STMT_PREPARE` → `ObMPStmtPrepare`（第 244 行）
  - `COM_STMT_EXECUTE` → `ObMPStmtExecute`（第 245 行）
  - `COM_STMT_CLOSE` → `ObMPStmtClose`（第 262 行，栈上分配避免 OOM 时的错误回复）
  - `COM_PING` → `ObMPPing`
  - `COM_QUIT` → `ObMPQuit`
  - `COM_INIT_DB` → `ObMPInitDB`
  - `COM_STMT_FETCH` → `ObMPStmtFetch`
  - `COM_STMT_RESET` → `ObMPStmtReset`
  - `COM_FIELD_LIST` → `ObMPQuery`（标记为 field list 模式）
  - 其他 → `ObMPDefault`（返回不支持错误）

处理器创建后，OBServer 通过租户线程池执行 `processor->run()`，将请求交给对应租户的工作线程处理。

---

## 2. 连接管理

### 2.1 连接生命周期

一个 MySQL 连接的完整生命周期：

```
TCP Connect (libeasy accept)
  │
  ▼
ObSMHandler::on_connect()
  ├─ 创建 sessid (全局唯一)
  ├─ 创建 ObSMConnection 对象
  ├─ 构建 Handshake 包（含 scramble）
  └─ 发送 Handshake 包
  │
  ▼
ObMPConnect::process()
  ├─ 解析 Client 的 HandshakeResponse
  ├─ 验证身份 (caching_sha2_password 或 mysql_native_password)
  ├─ 确定租户 (extract_tenant_id)
  ├─ 创建 SQLSessionInfo
  └─ 返回 OK 包 → 连接就绪
  │
  ▼
ObMPQuery / ObMPStmtPrepare / ObMPStmtExecute ... (正常请求)
  │
  ▼
TCP Disconnect (libeasy close)
  │
  ▼
ObSMHandler::on_close()
  └─ ObSMConnectionCallback::destroy()
      ├─ 释放 Session
      ├─ 解锁租户
      ├─ 清理诊断信息
      └─ 调用 conn.~ObSMConnection()
```

### 2.2 ObSMConnection 结构

`ObSMConnection` 定义在 `deps/oblib/src/rpc/obmysql/obsm_struct.h`，是每个 MySQL 连接的核心数据结构：

```cpp
struct ObSMConnection {
  uint32_t sessid_;              // OBServer 端会话 ID
  uint64_t proxy_sessid_;        // ODP(Proxy) 侧会话 ID
  uint64_t tenant_id_;           // 绑定的租户 ID
  void *tenant_;                 // 租户对象指针 (ObTenant)
  char scramble_buf_[SCRAMBLE_BUF_LEN]; // 握手 scramble
  bool is_proxy_;                // 是否通过 ODP 连接
  bool is_java_client_;          // 是否 Java 客户端
  bool is_sess_alloc_;           // 是否已分配 session
  bool is_sess_free_;            // session 是否已释放
  bool is_tenant_locked_;        // 租户是否已锁定
  bool is_need_clear_sessid_;    // 是否需要清理 sessid
  // ... 更多字段
};
```

每个 TCP 连接对应一个 `ObSMConnection` 实例，通过 `c->user_data` 指针与 libeasy connection 绑定。

### 2.3 握手流程

OBServer 的 MySQL 握手在 `ObSMConnectionCallback::init()`（`obsm_conn_callback.cpp`，第 108 行）中完成：

```
Server → Client: Handshake Packet (Protocol Version 10)
  ├─ 协议版本 (0x0a = MySQL 4.1+)
  ├─ 服务器版本字符串 (e.g., "5.7.25-OceanBase")
  ├─ 会话 ID (sessid, 4 bytes)
  ├─ Scramble (8 + 12 bytes, 认证挑战)
  ├─ 服务器能力标志
  └─ 认证插件名 (caching_sha2_password / mysql_native_password)

Client → Server: Handshake Response (41 bytes 包头 + 负载)
  ├─ 客户端能力标志
  ├─ 最大包大小
  ├─ 字符集
  ├─ 用户名@租户名
  ├─ 加密密码
  └─ 数据库名（可选）

Server → Client: OK Packet / Error Packet / Auth Switch Request
```

**scramble 生成**（`obsm_handler.cpp`，第 46 行）：OBServer 使用 `ObMysqlRandom` 生成 20 字节的随机字符串，每个连接独立。线程本地缓存了 `thread_scramble_rand`，首次使用时用全局种子初始化。

### 2.4 断开处理

断开处理分两个阶段：

1. **`on_disconnect()`**（`obsm_handler.cpp`，第 128 行）— 连接被 libeasy 标记为断开时调用。将对应的 `SQLSessionInfo` 标记为 `SESSION_KILLED`，使正在执行的查询能感知到连接断开。

2. **`on_close()`**（`obsm_handler.cpp`，第 169 行）— 实际清理。调用 `ObSMConnectionCallback::destroy()`，执行：
   - 释放 session（通过 `ObDisconnectTask` 异步推入租户队列）
   - 解锁租户（`sm_conn_unlock_tenant()`）
   - 清理诊断信息和 scramble
   - 最终调用 `conn.~ObSMConnection()` 释放连接对象

### 2.5 会话与租户绑定

当认证成功后，OBServer 创建 `ObSQLSessionInfo` 并将其与连接绑定。该 session 包含了：

- 用户认证信息
- 租户 ID（从用户名中提取，如 `root@sys` → tenant_id=1）
- 当前数据库
- 系统变量
- 字符集设置
- 事务上下文

用户名的租户提取由 `extract_tenant_id()` 完成（`obmp_connect.h`，第 24 行）：
- MySQL 模式：`user@tenant` 格式
- Oracle 模式：`user` 默认绑定到租户

---

## 3. ObMPBase — 所有 MySQL 处理器的基类

**文件**: `src/observer/mysql/obmp_base.h`（第 63 行定义）

`ObMPBase` 是所有 MySQL 协议处理类的基类，提供了共享功能：

```cpp
class ObMPBase {
protected:
  ObGlobalContext &gctx_;           // 全局上下文
  packet_sender_type *packet_sender_; // 包发送器
  int64_t process_timestamp_;       // 处理时间戳
  uint64_t proxy_version_;          // ODP 版本号

  // 生命周期
  virtual void cleanup();
  virtual int before_process();
  virtual int after_process();

  // 会话管理
  int create_session(sql::ObSQLSessionInfo *&session);
  int free_session(sql::ObFreeSessionCtx &ctx);
  int get_session(sql::ObSQLSessionInfo *&session);
  void revert_session(sql::ObSQLSessionInfo *session);

  // 包收发
  int read_packet();
  int release_packet();
  int send_ok_packet();
  int send_error_packet(int err, const char *msg);
  int send_eof_packet();
  int send_switch_packet(const ObString &plugin_name, const char *scramble);
  int response_packet(const char *buf, int64_t len);

  // 认证辅助
  int handle_auth_switch_if_needed(ObSMConnection &conn);
  int handle_caching_sha2_authentication_if_need(ObSMConnection &conn);
  int try_caching_sha2_fast_auth(ObSMConnection &conn, ...);
  int perform_caching_sha2_full_auth(ObSMConnection &conn, ...);

  // Schema 刷新
  int check_and_refresh_schema(const uint64_t tenant_id);
};
```

`obmp_base.cpp`（第 50 行起）实现了具体的逻辑。关键方法：

- **`before_process()`**（第 86 行）：在每个请求处理前调用。设置 packet sender、加载系统变量、刷新代理和客户端变量、初始化处理变量。
- **`after_process()`**（第 115 行）：请求处理后调用。记录 FLT trace、统计信息。
- **`create_session()`**（第 263 行）：创建 `SQLSessionInfo`，从 `ObSMConnection` 复制连接信息。

认证相关的辅助方法非常丰富——`ObMPBase` 实现了完整的 `caching_sha2_password` 认证流程：
- 快速认证路径（`try_caching_sha2_fast_auth`, 第 1022 行）
- 完整认证路径（`perform_caching_sha2_full_auth`, 第 1096 行）
- SSL 路径（`perform_ssl_full_auth`, 第 1136 行）
- RSA 路径（`perform_rsa_full_auth`, 第 1193 行）

---

## 4. ObMPQuery — 查询处理主入口

**文件**: `src/observer/mysql/obmp_query.h/cpp`（.cpp 文件 1892 行）

`ObMPQuery` 是 OBServer 最核心的处理器之一——处理 `COM_QUERY` 命令，将 SQL 文本送入 SQL 引擎并返回结果。

### 4.1 处理流程

`process()`（`obmp_query.h`，第 60 行）的实现（`obmp_query.cpp`，第 45 行）：

```
ObMPQuery::process()
  │
  ├─ 并发控制: 检查 max_concurrent_query_count (行 63)
  │
  ├─ 权限检查: 连接是否已认证 (is_in_authed_phase)
  │
  ├─ 限流检查: check_rate_limiter / check_qtime_throttle
  │
  ├─ get_session(sess): 获取 SQLSessionInfo
  │
  ├─ do_process() → do_process_trans_ctrl()
  │   ├─ check_is_trans_ctrl_cmd() → 事务控制命令直接处理
  │   └─ process_single_stmt() → 普通查询
  │       ├─ 解析: deserialize() 提取 SQL 文本
  │       ├─ 分发: ObSyncPlanDriver / ObAsyncPlanDriver
  │       │    ├─ SQL 引擎 (Parser → Resolver → Optimizer)
  │       │    ├─ 执行器 (Executor)
  │       │    └─ DAS (数据访问层)
  │       └─ response_result() → 编码结果发送给客户端
  │
  ├─ do_after_process(): 记录统计信息、审计日志
  │
  └─ cleanup(): 释放临时资源
```

### 4.2 关键特性

**多语句优化**（`try_batched_multi_stmt_optimization`, 第 134 行）：OceanBase 支持批量多语句执行优化，在同一个请求中打包多个 SQL 语句，减少网络往返。

**查询重试**（`ob_query_retry_ctrl.h`）：OBServer 支持查询级别重试——当遇到分布式事务冲突或分区位置变化时，自动重试查询。

**执行驱动**：`process_single_stmt()` 选择不同的执行驱动：
- `ObSyncPlanDriver` — 同步执行（简单查询）
- `ObAsyncPlanDriver` — 异步执行（大查询或分布式查询）
- `ObSyncCmdDriver` / `ObAsyncCmdDriver` — 命令执行

### 4.3 性能跟踪

`ObMPQuery` 维护了多个时间戳用于性能诊断：
- `get_single_process_timestamp()` — 单次处理开始时间
- `get_exec_start_timestamp()` — 执行开始时间
- `get_exec_end_timestamp()` — 执行结束时间
- `get_send_timestamp()` — 结果发送时间

这些时间戳配合 `ObMySQLRequestManager` 实现 SQL 审计。

---

## 5. 预处理语句

OceanBase 支持完整的 MySQL Prepared Statement 协议。PREPARE → EXECUTE 的数据流：

```
Client → Server: COM_STMT_PREPARE
  ┌───────────────────────────────────────────┐
  │  ObMPStmtPrepare::process()               │
  │  ├─ deserialize() → 提取 SQL 文本         │
  │  ├─ process_prepare_stmt()                │
  │  │   ├─ 解析 SQL → 获取参数数量           │
  │  │   └─ 生成 Prepared Statement ID        │
  │  └─ send_prepare_packet()                 │
  │      ├─ OK 包 (statement_id, num_params,  │
  │      │        num_columns, num_warnings)   │
  │      ├─ 列信息包 (每个 result column)      │
  │      └─ 参数信息包 (每个 placeholder)      │
  └───────────────────────────────────────────┘

Client → Server: COM_STMT_EXECUTE
  ┌───────────────────────────────────────────┐
  │  ObMPStmtExecute::process()               │
  │  ├─ deserialize()                          │
  │  │   ├─ statement_id → 查找 PS handle     │
  │  │   ├─ cursor_type (普通/scrollable)     │
  │  │   └─ 参数值 (parse_request_param_value) │
  │  ├─ process_execute_stmt()                │
  │  │   ├─ 参数绑定到 SQL 变量               │
  │  │   └─ SQL 引擎执行                      │
  │  ├─ execute_response() → 发送结果集        │
  └───────────────────────────────────────────┘
```

### 5.1 ObMPStmtPrepare

**文件**: `src/observer/mysql/obmp_stmt_prepare.h`（第 29 行定义）

核心方法：
- `process()`（第 47 行）— 入口
- `process_prepare_stmt()`（第 54 行）— 准备语句执行
- `send_prepare_packet()`（第 66 行）— 发送 PREPARE 响应包
- `send_column_packet()`（第 67 行）— 发送列信息
- `send_param_packet()`（第 68 行）— 发送参数信息

### 5.2 ObMPStmtExecute

**文件**: `src/observer/mysql/obmp_stmt_execute.h`（第 96 行定义）

`ObMPStmtExecute` 是最复杂的处理器之一，包含了丰富的参数解析逻辑和 array binding 支持。

**参数解析**：
- `parse_request_param_value()`（第 227 行）— 参数入口
- `parse_param_value()`（第 326 行）— 单参数解析
- `parse_basic_param_value()`（第 112 行）— 基本类型（INT, DOUBLE, STRING 等）
- `parse_integer_value()`（第 130 行）— 整数类型
- `parse_mysql_timestamp_value()`（第 125 行）— MySQL 时间戳
- `parse_oracle_timestamp_value()`（第 137 行）— Oracle 时间戳
- `parse_complex_param_value()`（第 338 行）— 复杂类型（UDT, 数组等）

**Array Binding**：
- `init_for_arraybinding()`（第 151 行）— 初始化
- `construct_execute_param_for_arraybinding()`（第 271 行）
- `check_param_value_for_arraybinding()`（第 276 行）
- `response_result_for_arraybinding()`（第 282 行）

Array Binding 支持批量参数的批量执行，大幅减少了 Prepare-Execute 的网络往返次数。

**PS Cursor 支持**：
- `ps_cursor_open()`（第 256 行）
- `ps_cursor_store_data()`（第 264 行）
- Cursor 类型：`ObNormalType`, `ObExecutePsCursorType`, `ObPrexecutePsCursorType`

---

## 6. 结果集编码

**文件**: `src/observer/mysql/ob_mysql_result_set.h/cpp`

`ObMySQLResultSet`（第 36 行）继承自 `ObResultSet`（SQL 引擎的结果集），提供了 MySQL 协议特有的序列化能力。

### 6.1 关键方法

```cpp
class ObMySQLResultSet : public ObResultSet {
  // 遍历结果集的列
  int next_field(ObMySQLField &obmf);       // 下一个列信息
  int next_param(ObMySQLField &obmf);       // 下一个参数信息

  // 遍历结果集的行
  int next_row(const ObNewRow *&obmr);      // 下一行

  // 多结果集支持
  bool has_more_result() const;
  void set_has_more_result(bool has_more);

  // 类型转换 (MySQL / Oracle 兼容)
  static int to_mysql_field(const ObField &field, ObMySQLField &mfield);
  static int to_oracle_field(const ObField &field, ObMySQLField &mfield);
  static int to_new_result_field(const ObField &field, ObMySQLField &mfield);

  // 精度/标度切换 (PS 模式)
  static void switch_ps(ObPrecision &pre, ObScale &scale, EMySQLFieldType type);
};
```

### 6.2 结果编码流程

```
SQL 引擎执行完成 → ObResultSet 包含结果
  │
  ▼
ObMySQLResultSet 包装 ObResultSet
  │
  ├─ 发送列数 (column count packet)
  │
  ├─ for each field:
  │   ├─ to_mysql_field() / to_oracle_field() 转换类型
  │   └─ send_column_packet() 发送列定义
  │
  ├─ for each row:
  │   ├─ next_row() 获取行
  │   └─ encode + send_row_packet() 发送行数据
  │
  ├─ send_eof_packet() 结束标记
  │
  └─ if has_more_result:
      └─ 继续下一个结果集
```

---

## 7. ObMySQLRequestManager — 请求审计与生命周期

**文件**: `src/observer/mysql/ob_mysql_request_manager.h/cpp`

`ObMySQLRequestManager` 是每个租户独立的请求审计管理器。它维护了一个定长环形缓冲区，记录最近执行的 SQL 请求信息，用于 SQL 审计和慢查询诊断。

### 7.1 核心设计

```cpp
class ObMySQLRequestManager {
  // 审计记录
  struct ObMySQLRequestRecord {
    ObConcurrentFIFOAllocator allocator_;
    ObDLinkBase<ObMySQLRequestRecord> data_;  // 双向链表节点
    // ... 包含请求参数、耗时、状态等信息
  };

  // 环形队列
  common::ObFixedDLList<ObMySQLRequestRecord> queue_;

  // 配置常量
  static const int64_t MAX_QUEUE_SIZE = 102400;        // 最大队列长度
  static const int64_t MINI_MODE_MAX_QUEUE_SIZE = 20000; // mini 模式
  static const int64_t BATCH_RELEASE_SIZE = 5000;       // 批量释放大小
};
```

### 7.2 关键方法

| 方法 | 行号 | 职责 |
|------|------|------|
| `init()` | 第 99 行 | 初始化分配器和队列 |
| `record_request()` | 第 114 行 | 记录一个请求到审计队列 |
| `get()` | 第 125 行 | 获取指定索引的审计记录 |
| `revert()` | 第 134 行 | 归还审计记录引用 |
| `release_old()` | 第 144 行 | 淘汰过期记录（超越 mem_limit） |
| `release_record()` | 第 153 行 | 释放单条记录 |

### 7.3 生命周期与 MTL

`ObMySQLRequestManager` 是 MTL（Multi-Tenant Layer）对象，每个租户拥有独立的实例：

```cpp
// mtl 生命周期方法
int mtl_new(ObMySQLRequestManager *&manager);
int mtl_init(ObMySQLRequestManager *&manager);
void mtl_destroy(ObMySQLRequestManager *&manager);
```

这使得每个租户的 SQL 审计空间天然隔离——租户 A 的审计记录不会影响租户 B。

### 7.4 内存控制

`ObMySQLRequestManager` 使用 `ObConcurrentFIFOAllocator` 作为内存分配器，支持 `mem_limit_` 限制。当超出限制时，`release_old()` 批量淘汰最旧的记录（`BATCH_RELEASE_SIZE` = 5000 条）。

配置梯度：
- 高速淘汰触发：`HIGH_LEVEL_EVICT_PERCENTAGE`（内存水位 ≥ 该值）
- 低速淘汰触发：`LOW_LEVEL_EVICT_PERCENTAGE`
- 回收周期：`EVICT_INTERVAL` + `CONSTRUCT_EVICT_INTERVAL`

---

## 8. 完整请求流

```
┌───────────────────────────────────────────────────────────────┐
│                       MySQL Client                             │
│  mysql -h host -P port -u user@tenant -p                      │
└────────────────────────┬──────────────────────────────────────┘
                         │ TCP Connect (端口 2881)
                         ▼
┌───────────────────────────────────────────────────────────────┐
│  libeasy event loop (I/O 线程)                                 │
│  accept → 创建 easy_connection_t                               │
│  → 调用 ObSMHandler::on_connect() (obsm_handler.cpp:69)       │
│    ├─ 分配 ObSMConnection + 生成 sessid                        │
│    ├─ 生成 scramble (20 字节随机数)                             │
│    ├─ 构建 OMPKHandshake 包                                    │
│    └─ send_handshake() → 发送到客户端                          │
└──────────┬────────────────────────────────────────────────────┘
           │ Handshake Packet (Server → Client)
           ▼
┌───────────────────────────────────────────────────────────────┐
│  客户端回复 HandshakeResponse                                  │
│  → libeasy recv                                               │
│  → ObSrvMySQLXlator::translate() (ob_srv_xlator.cpp:169)      │
│    ├─ is_in_connected_phase() == true                          │
│    └─ get_mp_connect_processor() → ObMPConnect                │
└──────────┬────────────────────────────────────────────────────┘
           │
           ▼
┌───────────────────────────────────────────────────────────────┐
│  ObMPConnect::process() (obmp_connect.h)                       │
│  ├─ deserialize() → 解析 HandshakeResponse                    │
│  ├─ extract_user_tenant() → 提取 用户/租户                    │
│  ├─ verify_identify() → 验证密码 (caching_sha2_password)      │
│  ├─ 兼容性处理:                                                │
│  │  ├─ SSL 路径                                                │
│  │  └─ Auth Switch (老客户端)                                 │
│  ├─ create_session() → 创建 SQLSessionInfo                     │
│  ├─ 初始化连接 (init_connect_process)                          │
│  └─ send_ok_packet()                                          │
└──────────┬────────────────────────────────────────────────────┘
           │ OK Packet (Server → Client)
           ▼
┌───────────────────────────────────────────────────────────────┐
│  Client: SELECT * FROM t WHERE id = 1                         │
│  → COM_QUERY packet                                           │
│  → ObSrvMySQLXlator::translate()                              │
│    └─ pkt.get_cmd() == COM_QUERY                              │
│       → new ObMPQuery(gctx_) (ob_srv_xlator.cpp:186)          │
└──────────┬────────────────────────────────────────────────────┘
           │
           ▼
┌───────────────────────────────────────────────────────────────┐
│  ObMPQuery::process() (obmp_query.cpp:45)                      │
│  ├─ 并发/限流检查                                              │
│  ├─ get_session() → 获取 SQLSessionInfo                        │
│  ├─ do_process() → process_single_stmt()                      │
│  │   ├─ deserialize() → 提取 SQL 文本                         │
│  │   ├─ SQL Engine:                                           │
│  │   │   ├─ Parser (obmp_query → SQL 文本 → AST)              │
│  │   │   ├─ Resolver → 语义解析                              │
│  │   │   ├─ Optimizer → 生成执行计划                          │
│  │   │   └─ Executor → 执行                                   │
│  │   │       └─ DAS → 存储层访问                              │
│  │   └─ response_result() → MySQL 协议编码 → 发送            │
│  └─ do_after_process() → 审计记录                             │
└──────────┬────────────────────────────────────────────────────┘
           │ ResultSet (Server → Client)
           ▼
┌───────────────────────────────────────────────────────────────┐
│  Client 发送下一个请求 / 断开连接                              │
│  → TCP close                                                  │
│  → ObSMHandler::on_disconnect() + on_close()                  │
│  → ObSMConnectionCallback::destroy()                          │
│    ├─ 释放 SQLSessionInfo (异步推送)                           │
│    ├─ 解锁租户                                                │
│    ├─ 清理诊断信息                                             │
│    └─ ~ObSMConnection()                                       │
└───────────────────────────────────────────────────────────────┘
```

---

## 9. 设计决策

### 9.1 MySQL 协议兼容的复杂度

OceanBase 选择完全兼容 MySQL 协议而非自建协议。这带来了巨大的兼容性优势——现有的 MySQL 客户端、驱动、ORM 框架（JDBC、PHP PDO、Python MySQL Connector 等）无需修改即可连接 OceanBase。

代价是协议处理的复杂度：
- **4 种认证方式**：`mysql_native_password`, `caching_sha2_password`, `sha256_password`, 以及 Oracle 模式下的特殊处理
- **Auth Switch 支持**：当客户端和服务器的认证插件不匹配时，通过 AuthSwitch 协议协商
- **版本兼容**：需要处理 MySQL 5.5/5.6/5.7/8.0 不同协议版本的差异

### 9.2 认证机制

默认认证插件是 `caching_sha2_password`（MySQL 8.0 默认）。OBServer 在握手包的 `auth_plugin_name` 字段中告知客户端。支持三种认证路径：

```
客户端连接
  │
  ▼
ObMPBase::handle_caching_sha2_authentication_if_need()
  │
  ├─ 快速路径 (Fast Auth Path):
  │   ObMPBase::try_caching_sha2_fast_auth()
  │   └─ 客户端已缓存密码 → 直接验证 scramble
  │
  ├─ SSL 路径 (SSL Auth Path):
  │   ObMPBase::perform_ssl_full_auth()
  │   └─ SSL 已建立 → 明文传输密码
  │
  └─ RSA 路径 (Full Auth Path):
      ObMPBase::perform_rsa_full_auth()
      ├─ 发送 RSA 公钥
      ├─ 客户端用公钥加密密码
      └─ 服务端解密验证
```

### 9.3 连接池管理

OBServer 自身不实现连接池（那是 ODP/OceanBase Database Proxy 的职责），但连接管理设计考虑了 proxy 场景：

- `is_proxy_` 标志：区分直连和通过 ODP 的连接
- `proxy_version_`：记录 ODP 版本号，用于版本兼容性判断（如 `COM_FIELD_LIST` 命令需要 >= 1.7.6）
- `proxy_sessid_`：ODP 侧的会话 ID，用于端到端链路追踪

### 9.4 协议压缩

OBServer 支持三种 C/S 协议类型：

- **普通协议**（`OB_CS_PROTOCOL`）— 明文 MySQL 协议
- **压缩协议**（`OB_CS_PROTOCOL_COMPRESSED`）— 使用 zlib 压缩
- **Proto20 协议**（`OB_CS_PROTOCOL_PROTO_20`）— 自定义高效二进制协议

通过 `obsm_handler.h` 的 `get_cs_protocol_type()` 和对应的 context getter 方法管理。

### 9.5 Prepare Statement 缓存

OceanBase 的 Prepared Statement 是**连接级别**的——每个 MySQL 连接独立维护自己的 PS 缓存。`ObMPStmtPrepare` 生成的 `statement_id` 在该连接内唯一。

这避免了分布式缓存的一致性问题，但代价是不同的连接无法共享已准备好的语句（ODP Proxy 层具备跨连接 PS 缓存的能力）。

---

## 10. 与前面文章的关联

第 40 篇是入口，它与前面各篇形成了完整的调用链：

```
第 40 篇: 网络服务与 MySQL 协议 ← 你在读这里
  │
  ├─→ 第 30 篇: OBServer 启动与生命周期
  │   启动时初始化网络服务（ObServer::init() 中注册 ObSrvXlator）
  │
  ├─→ 第 23 篇: SQL Parser 分析
  │   ObMPQuery → deserialize() → SQL 文本 → Parser → AST
  │
  ├─→ 第 32 篇: 表达式引擎
  │   SQL 引擎的执行阶段使用表达式引擎计算
  │
  ├─→ 第 31 篇: DML 路径
  │   INSERT/UPDATE/DELETE 的完整执行路径
  │
  ├─→ 第 09 篇: DAS (数据访问层)
  │   SQL 引擎通过 DAS 访问存储引擎
  │
  ├─→ 第 39 篇: 租户架构
  │   每个 MySQL 连接绑定到指定租户，请求由租户线程池执行
  │
  └─→ 第 01-08 篇: 存储引擎 (MVCC, MemTable, SSTable, ...)
       查询最终到达存储层，读取数据
```

从网络入口到底层存储，40 篇文章覆盖了 OceanBase 的每一层。

---

## 11. 系列总结：40 篇回顾

**系列目录**（按分析顺序）：

| 编号 | 主题 | 核心模块 |
|------|------|----------|
| 01 | MVCC 行分析 | `ObMvccRow`, `ObTransRow` |
| 02 | MVCC 迭代器 | `ObMvccIterator`, scan 接口 |
| 03 | MVCC 写冲突 | 事务冲突检测与处理 |
| 04 | MVCC 回调 | 提交/回滚的回调链 |
| 05 | MVCC Compact | 行版本合并与垃圾回收 |
| 06 | MemTable Freezer | 活跃 MemTable → 冻结 → 转储 |
| 07 | LSS / LogStream | 日志流架构与副本管理 |
| 08 | SSTable | 静态只读存储格式 |
| 09 | SQL 执行器 | DAS, 分布式执行框架 |
| 10 | 事务引擎 | `ObTransService`, 2PC 提交 |
| 11 | PALF 日志库 | 追加日志、持久化、复制 |
| 12 | 选举算法 | Paxos 选举、Leader 切换 |
| 13 | CLog 日志 | 事务提交日志、Clog 缓冲区 |
| 14 | MemTable 内部 | BTree、行锁、多版本 |
| 15 | KeyBTree | 自适应 B+Tree 索引结构 |
| 16 | 行冲突处理器 | 分布式事务冲突处理 |
| 17 | 查询优化器 | 代价估算、Join 重排 |
| 18 | 索引设计 | 局部/全局索引、索引维护 |
| 19 | 分区迁移 | 数据均衡、分区复制 |
| 20 | 备份恢复 | 全量/增量备份、恢复流程 |
| 21 | 并行执行 (PX) | DFO、数据重分布 |
| 22 | Plan Cache | 执行计划缓存与失效 |
| 23 | SQL Parser | 词法/语法分析、AST 生成 |
| 24 | 类型系统 | 数据类型定义、转换、计算 |
| 25 | 内存管理 | 内存池、OOM 处理、优先级 |
| 26 | 编码引擎 | 列式编码、压缩 |
| 27 | RootService | 元数据管理、DDL 协调 |
| 28 | GTS 时间模型 | 全局时间戳、快照读 |
| 29 | SQL 诊断 | 慢查询、trace、性能视图 |
| 30 | OBServer 启动 | 初始化顺序、模块注册 |
| 31 | DML 路径 | INSERT/UPDATE/DELETE 完整流程 |
| 32 | 表达式引擎 | 表达式树、求值、向量化 |
| 33 | 子查询与 CTE | Subquery 去关联、递归 CTE |
| 34 | SSTable Merge | 合并策略、major/minor |
| 35 | Macro Block | 宏块生命周期、IO 路径 |
| 36 | 并发控制 | 锁管理器、隔离级别 |
| 37 | 位置路由 | Location Cache、分区路由 |
| 38 | PALF 成员变更 | 增删节点、配置变更 |
| 39 | 租户架构 | 多租户、资源隔离、线程池 |
| **40** | **网络与 MySQL 协议** | **连接、认证、协议分派** |

### 技术深度

系列覆盖了 OceanBase 的**完整数据路径**：

```
网络层 ──→ SQL 层 ──→ 优化器 ──→ 执行器 ──→ 事务层 ──→ 存储层 ──→ 持久化
   │          │          │          │          │          │          │
   │          │          │          │          │          │          │
  第40篇     第23篇     第17篇     第09篇     第10篇     第01篇     第11篇
              第32篇     第18篇     第31篇     第36篇     第06篇     第13篇
              第33篇     第22篇     第21篇                第08篇     第38篇
                                                          第14篇
                                                          第15篇
                                                          第34篇
                                                          第35篇
```

以及**支撑系统**：

| 类别 | 文章 |
|------|------|
| **可用性** | 第 12 篇 选举、第 19 篇 分区迁移、第 38 篇 成员变更 |
| **可管理性** | 第 27 篇 RootService、第 28 篇 GTS |
| **性能** | 第 21 篇 PX、第 22 篇 Plan Cache、第 25 篇 内存管理、第 26 篇 编码 |
| **诊断** | 第 29 篇 SQL 诊断、第 40 篇 请求审计 |
| **多租户** | 第 39 篇 租户架构 |
| **启动** | 第 30 篇 启动流程 |

40 篇文章，从磁盘上的 macro block，到内存中的 MemTable，从 Paxos 选举到 SQL 解析，从并发控制到多租户隔离，从单机事务到分布式执行——**覆盖了一个工业级分布式数据库的全栈架构**。

---

## 12. 源码索引

| 文件 | 路径 | 行数 | 核心内容 |
|------|------|------|----------|
| `obsm_handler.h` | `src/observer/mysql/` | 59 | `ObSMHandler` — 连接生命周期 |
| `obsm_handler.cpp` | `src/observer/mysql/` | 466 | on_connect, on_disconnect, on_close 实现 |
| `obsm_conn_callback.h` | `src/observer/mysql/` | 31 | `ObSMConnectionCallback` — 连接回调接口 |
| `obsm_conn_callback.cpp` | `src/observer/mysql/` | 258 | init/destroy/on_disconnect 实现 |
| `obmp_base.h` | `src/observer/mysql/` | 362 | `ObMPBase` — 所有处理器基类 |
| `obmp_base.cpp` | `src/observer/mysql/` | 1395 | 认证、会话、包收发实现 |
| `obmp_connect.h` | `src/observer/mysql/` | 200+ | `ObMPConnect` — 连接与认证 |
| `obmp_connect.cpp` | `src/observer/mysql/` | 1800+ | 身份验证、租户提取 |
| `obmp_query.h` | `src/observer/mysql/` | 164 | `ObMPQuery` — 查询处理 |
| `obmp_query.cpp` | `src/observer/mysql/` | 1892 | SQL 执行入口、多语句优化 |
| `obmp_stmt_prepare.h` | `src/observer/mysql/` | 77 | `ObMPStmtPrepare` — PREPARE |
| `obmp_stmt_execute.h` | `src/observer/mysql/` | 404 | `ObMPStmtExecute` — EXECUTE + Array Binding |
| `ob_mysql_result_set.h` | `src/observer/mysql/` | 70 | `ObMySQLResultSet` — 结果集编码 |
| `ob_mysql_request_manager.h` | `src/observer/mysql/` | 207 | `ObMySQLRequestManager` — 请求审计 |
| `ob_srv_xlator.cpp` | `src/observer/` | 511 | 命令 → 处理器分派（核心路由） |
| `obsm_struct.h` | `deps/oblib/src/rpc/obmysql/` | — | `ObSMConnection` 结构定义 |
| `ob_mysql_packet.h` | `deps/oblib/src/rpc/obmysql/` | — | MySQL 协议包定义和命令枚举 |

> **分析工具**：本文使用 doom-lsp（clangd LSP 的轻量封装）对以上每个文件进行了符号解析和结构分析。所有行号均已通过 doom-lsp 验证。
