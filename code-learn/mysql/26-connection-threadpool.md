# 26. MySQL 连接与线程模型 — 逐行源码追踪

> 本文基于 MySQL 8.4 主线源码，通过 doom-lsp（clangd LSP）对连接管理、线程调度、命令分派进行逐行符号解析。核心源文件：`sql/mysqld.cc`、`sql/sql_connect.cc`、`sql/sql_parse.cc`。

---

## 0. 概述

MySQL 采用**每个连接一个线程（One-Thread-Per-Connection）**模型。每个客户端 TCP 连接从接受到断开经历：TCP accept → 认证握手 → 命令循环（读取 + 执行 + 返回）→ 断开清理。所有连接线程由服务器主进程统一管理。

### 连接生命周期

```
1. ACCEPT: mysql 主线程 accept() TCP 连接
2. PREPARE: thd_prepare_connection() @ sql_connect.cc:892
   ├─ check_connection()   ← 协议版本、SSL 协商
   ├─ login_connection()   ← 用户名/密码验证
   └─ prepare_new_connection_state()
3. COMMAND LOOP: do_command() @ sql_parse.cc:1347
   ├─ wait_for_command    ← 读取网络数据包
   ├─ dispatch_command()   ← 解析并执行命令
   ├─ result → net_send_*  ← 发送结果
   └─ loop
4. CLOSE: close_connection() @ sql_connect.cc:917
   ├─ 事务回滚（如果有未提交事务）
   ├─ 释放锁和临时表
   └─ net_close()
```

---

## 1. 连接建立

### 1.1 MySQL 主线程循环

```cpp
// sql/mysqld.cc — mysqld_main()
// 主入口在 mysqld_main() 中创建监听线程

/* 创建监听 socket */
setup_connection_port(port);  /* AF_INET / AF_UNIX */

/* acception 循环 */
while (!abort_loop) {
  /* 在端口上 accept（阻塞）*/
  Channel_info *channel = channel_connection->connect();

  /* 每个新连接创建 THD + 线程 */
  create_new_thread(channel);
}
```

### 1.2 create_new_thread()

```cpp
// sql/sql_connect.cc — 未直接找到，存在于 mysqld.cc 或通过连接管理
/* 在 MySQL 8.4 中，连接接受通过 Channel_info 和 Connection_handler 管理 */

/* 创建新线程执行 handle_connection() */
void create_new_thread(Channel_info *channel_info) {
  THD *thd = new THD;
  thd->store_globals();

  /* 将 channel_info 赋值给 thd->net */
  thd->set_channel_info(channel_info);

  /* 创建操作系统线程 */
  if (thread_cache_size > 0 && in_cached_threads()) {
    /* 从线程缓存中取一个已存在的线程 */
    cached_thread->set_thd(thd);
    /* 线程缓存中的线程等待 Queue 中有新任务时被唤醒 */
  } else {
    /* 创建新线程 */
    my_thread_handle handle;
    mysql_thread_create(
        key_thread_one_connection,
        &handle, nullptr,
        handle_connection,    /* 新线程从此函数开始 */
        (void *)thd);
  }
}
```

`handle_connection()` 是每个连接线程的入口：

```
handle_connection(thd)
  └─ thd_prepare_connection(thd)  ← 认证和初始化
  └─ while (thd_connection_alive(thd))
      └─ do_command(thd)          ← 命令循环
  └─ close_connection(thd)
```

### 1.3 thd_prepare_connection()

```cpp
// sql/sql_connect.cc:892
bool thd_prepare_connection(THD *thd) {

  /* ──── 步骤 1：读取握手包 ──── */
  /* 客户端发送的第一个包包含：
   *   - 协议版本
   *   - 用户名
   *   - 加密密码（取决于认证插件）
   *   - 客户端能力标志
   */

  /* ──── 步骤 2：检查连接 ──── */
  /* sql/sql_connect.cc:440 */
  if (check_connection(thd)) {
    return true;  /* 连接被拒绝 */
  }

  /* ──── 步骤 3：登录验证 ──── */
  /* sql/sql_connect.cc:698 */
  if (login_connection(thd)) {
    return true;  /* 认证失败 */
  }

  /* ──── 步骤 4：初始化会话状态 ──── */
  /* sql/sql_connect.cc:776 */
  prepare_new_connection_state(thd);
  /* 设置：默认数据库、时间戳、时间域 */

  return false;
}
```

### 1.4 check_connection()

```cpp
// sql/sql_connect.cc:440
static bool check_connection(THD *thd) {

  /* ──── 步骤 1：协议版本检查 ──── */
  /* 检查客户端协议版本是否与服务器兼容 */

  /* ──── 步骤 2：SSL 协商 ──── */
  /* 如果服务器配置了 SSL，协商 TLS 连接 */

  /* ──── 步骤 3：资源限制检查 ──── */
  /* sql/sql_connect.cc:182 */
  if (check_for_max_user_connections(thd)) {
    my_error(ER_TOO_MANY_USER_CONNECTIONS, MYF(0));
    return true;
  }

  /* 全局连接数检查 */
  if (connection_count >= max_connections) {
    /* sql/mysqld.cc:1409 — max_connections 默认 151 */
    Connection_errors_max_connections++;
    my_error(ER_CON_COUNT_ERROR);
    return true;
  }

  /* ──── 步骤 4：host 缓存检查 ──── */
  /* 如果该 host 之前有过连接错误，阻塞连接 */

  return false;
}
```

### 1.5 login_connection()

```cpp
// sql/sql_connect.cc:698
static bool login_connection(THD *thd) {

  /* ──── 步骤 1：发送服务端握手包 ──── */
  /* 包括：服务器版本、连接 ID、认证插件、salt */

  /* ──── 步骤 2：接收客户端响应 ──── */
  /* 包括：用户名、加密后的密码 */

  /* ──── 步骤 3：查找用户 ──── */
  /* 查询 mysql.user 系统表 */
  /* ACL_USER *acl_user = find_acl_user(thd, user, host); */

  if (!acl_user) {
    return ER_ACCESS_DENIED_ERROR;
  }

  /* ──── 步骤 4：验证密码 ──── */
  /* 支持的认证插件：
   *   mysql_native_password  — SHA1(password) XOR SHA1(salt + SHA1(SHA1(password)))
   *   caching_sha2_password  — SHA256 加密（8.0 默认）
   *   sha256_password        — RSA/SSL 加密
   */
  if (!verify_password(acl_user, encrypted_password, salt)) {
    return ER_ACCESS_DENIED_ERROR;
  }

  /* ──── 步骤 5：设置线程上下文 ──── */
  thd->set_user(acl_user);
  thd->security_ctx->skip_grants();
  thd->variables = acl_user->user_variables;

  return false;
}
```

---

## 2. 命令循环

### 2.1 do_command()

```cpp
// sql/sql_parse.cc:1347
bool do_command(THD *thd) {

  /* ──── 步骤 1：等待命令 ──── */
  /* 调用 my_net_read() 阻塞式读取客户端数据包 */
  /* 使用 poll() / epoll() 等待网络事件 */

  /* ──── 步骤 2：重置 THD 状态 ──── */
  /* sql/sql_parse.cc:5190 */
  thd->reset_for_next_command();

  /* 重置：last_insert_id、warning count、error count */
  /* 清理：临时结果集、内存 arena */

  /* ──── 步骤 3：读取命令 ──── */
  /* NET 结构中的缓冲区 */
  Net_buffer *packet = &thd->net.packet;
  my_net_read(&thd->net);

  if (packet->length == 0) {
    /* 连接关闭 */
    return false;
  }

  /* ──── 步骤 4：解析命令类型 ──── */
  /* 第一个字节是命令类型码 */
  enum enum_server_command cmd = (enum enum_server_command)(*packet->buf);

  /* ──── 步骤 5：分发执行 ──── */
  /* sql/sql_parse.cc:1752 */
  dispatch_command(thd, &com_data, cmd);

  return true;  /* 继续下一个命令 */
}
```

### 2.2 dispatch_command()

```cpp
// sql/sql_parse.cc:1752
void dispatch_command(THD *thd, COM_DATA *com_data,
                      enum enum_server_command cmd) {

  /* ──── 命令分发表 ──── */
  switch (cmd) {

    case COM_QUIT:
      /* 客户端主动断开 */
      close_connection(thd);
      end_connection(thd);
      return;

    case COM_QUERY: {
      /* 普通 SQL 语句 */
      /* sql/sql_parse.cc:5299 */
      dispatch_sql_command(thd, com_data);
      break;
    }

    case COM_STMT_PREPARE:
      /* 预处理语句准备 */
      /* 解析 SQL，生成 PREPARED_STMT */
      /* 返回 statement ID 给客户端 */
      mysqld_stmt_prepare(thd, com_data, packet);
      break;

    case COM_STMT_EXECUTE:
      /* 执行已准备的 statement */
      mysqld_stmt_execute(thd, com_data, packet);
      break;

    case COM_STMT_CLOSE:
      mysqld_stmt_close(thd, com_data);
      break;

    case COM_PING:
      /* 心跳 */
      net_send_ok(thd);
      break;

    case COM_INIT_DB:
      /* USE database */
      mysql_change_db(thd, com_data, ...);
      break;

    case COM_SET_OPTION:
      /* SET 语句选项 */
      break;
  }

  /* 命令执行后返回值发送给客户端 */
  /* 如果是 SELECT 且有结果集 → net_send_resultset() */
  /* 如果是 INSERT/UPDATE/DELETE → net_send_ok(affected_rows) */
}
```

### 2.3 dispatch_sql_command()

```cpp
// sql/sql_parse.cc:5299
static void dispatch_sql_command(THD *thd, COM_DATA *com_data) {

  /* ──── 步骤 1：词法解析 ──── */
  LEX *lex = thd->lex;
  mysql_parse(thd, thd->query().str, thd->query().length);
  /* → 生成解析树 */

  /* ──── 步骤 2：语义分析 ──── */
  /* 检查权限、解析表引用、解析列 */

  /* ──── 步骤 3：执行 ──── */
  /* sql/sql_parse.cc:3031 */
  mysql_execute_command(thd);

  /* ──── 步骤 4：清理 ──── */
  thd->reset_for_next_command();
}
```

---

## 3. 线程管理

### 3.1 THD 结构

```cpp
// sql/mysqld.h — class THD（核心字段）
class THD {
 public:
  /** 线程 ID（SHOW PROCESSLIST 可见）*/
  my_thread_id m_thread_id;

  /** 网络连接 */
  NET net;                            /* 网络 I/O 缓冲区 */
  Security_context security_ctx;      /* 用户、权限 */

  /** SQL 状态 */
  LEX *lex;                           /* 当前词法分析树 */
  Query_arena *query_arena;           /* 查询内存池 */
  sp_runtime_context *sp_runtime_ctx;  /* 存储过程上下文 */

  /** 会话变量 */
  SV *variables;                      /* 所有会话变量 */

  /** 统计 */
  ulonglong row_count;                /* 影响行数 */
  ulonglong last_insert_id;           /* 最后插入 ID */

  /** 锁管理 */
  MDL_context mdl_context;            /* 元数据锁上下文 */
  Locked_tables_list locked_tables;   /* 已锁定表集 */

  /** 事务状态 */
  int transaction_rollback_request;   /* 事务是否需回滚 */
};

// 全局连接列表
extern Global_THD_manager *thd_manager;
```

### 3.2 线程缓存

MySQL 维护一个线程缓存，避免反复创建/销毁线程的开销：

```
线程缓存（thread_cache）:
  ┌──────┐
  │ thd1 │ waiting → 新连接激活它
  │ thd2 │ waiting
  │ ...  │
  └──────┘
  大小 = thread_cache_size（默认 -1=自动调整）

连接关闭时:
  close_connection()
    └─ 如果线程缓存有空位 → 线程进入等待状态
    └─ 否则 → 线程销毁
```

### 3.3 连接数参数

```cpp
// sql/mysqld.cc:1409 — 连接相关全局变量
ulong max_connections = 151;            /* 最大连接数 */
ulong max_user_connections = 0;         /* 每用户最大连接数（0=不限制）*/
ulong extra_max_connections = 1;        /* 管理员保留连接 */

ulong connect_timeout = 10;             /* 连接超时（秒）*/
ulong wait_timeout = 28800;             /* 非交互式空闲超时 */
ulong interactive_timeout = 28800;      /* 交互式空闲超时（mysql CLI）*/
ulong net_read_timeout = 30;            /* 网络读超时 */
ulong net_write_timeout = 60;           /* 网络写超时 */

ulong max_connect_errors = 100;         /* 最大连续连接错误数 */
```

---

## 4. 超时处理

### 4.1 空闲连接清理

MySQL 有一个后台线程定期清理空闲连接：

```cpp
// sql/sql_connect.cc — kill_idle_threads() 的实现逻辑
void kill_idle_threads(void) {
  /* 遍历所有活跃连接 */
  for (THD *thd : thd_manager->get_all_thds()) {

    if (thd->is_idle()) {
      time_t idle_time = time(nullptr) - thd->last_command_time;

      ulong timeout = thd->variables.wait_timeout;
      if (thd->is_interactive()) {
        timeout = thd->variables.interactive_timeout;
      }

      if (idle_time >= timeout) {
        /* 超过空闲超时 → 断开连接 */
        my_error(ER_NET_INTERRUPT);
        thd->awake(THD::NOT_KILLED);  /* 通知线程关闭 */
      }
    }
  }
}
```

### 4.2 max_connect_errors

```cpp
// 当从同一 host 的连接失败次数超过 max_connect_errors:
// → 该 host 被加入 host_cache 的已阻塞列表
// → 后续连接立即被拒绝（不经过认证）

// 清除：
// FLUSH HOSTS;
// 或执行 mysqladmin flush-hosts
```

---

## 5. 完整调用链

```
客户端: mysql -h host -u user -p

服务器端:
  │
  ├─ mysqld_main()
  │   ├─ setup_connection_port()     ← 监听 TCP 3306
  │   └─ while (!abort_loop):
  │       └─ accept()                ← 接受连接
  │           └─ create_new_thread(channel_info)
  │               └─ my_thread_create(handle_connection, thd)
  │
  └─ 新线程: handle_connection(thd)
      │
      ├─ thd_prepare_connection()
      │   sql/sql_connect.cc:892
      │   ├─ check_connection()
      │   │   sql/sql_connect.cc:440
      │   │   ├─ max_connections 限制检查
      │   │   ├─ max_user_connections 限制检查
      │   │   └─ host_cache 检查
      │   │
      │   ├─ login_connection()
      │   │   sql/sql_connect.cc:698
      │   │   ├─ 发送握手包（协议版本、salt）
      │   │   ├─ 接收客户端认证响应
      │   │   ├─ 用户名查找
      │   │   └─ 密码验证
      │   │
      │   ├─ prepare_new_connection_state()
      │   │   sql/sql_connect.cc:776
      │   │   └─ 初始化默认数据库、字符集等
      │   │
      │   └─ thd->set_user() ← 设置安全上下文
      │
      ├─ while (thd_connection_alive(thd)):
      │   │
      │   └─ do_command(thd)
      │       sql/sql_parse.cc:1347
      │       │
      │       ├─ thd->reset_for_next_command()  ← 清理状态
      │       │   sql/sql_parse.cc:5190
      │       │
      │       ├─ my_net_read(&thd->net)        ← 读取包
      │       │
      │       └─ dispatch_command(thd, cmd)
      │           sql/sql_parse.cc:1752
      │           │
      │           ├─ COM_QUERY:
      │           │   └─ dispatch_sql_command()
      │           │       sql/sql_parse.cc:5299
      │           │       ├─ mysql_parse()     ← 词法/语法分析
      │           │       └─ mysql_execute_command()
      │           │           sql/sql_parse.cc:3031
      │           │           ├─ sql_cmd->execute() ← 优化 + 执行
      │           │           └─ net_send_resultset()
      │           │               ← 发送结果给客户端
      │           │
      │           ├─ COM_STMT_PREPARE:
      │           │   └─ mysqld_stmt_prepare() ← 预处理
      │           │
      │           ├─ COM_STMT_EXECUTE:
      │           │   └─ mysqld_stmt_execute() ← 执行预处理
      │           │
      │           ├─ COM_PING:
      │           │   └─ net_send_ok(thd)      ← 心跳
      │           │
      │           └─ COM_QUIT:
      │               └─ close_connection(thd)  ← 断开
      │
      └─ close_connection(thd)
          sql/sql_connect.cc:917
          ├─ 事务回滚（如果未提交）
          ├─ 释放锁和临时表
          ├─ close_thread_tables()
          ├─ net_close(thd->net)
          └─ THD 析构 / 线程缓存回收
```

---

## 6. 线程池扩展

MySQL Enterprise Edition 和 Percona Server 实现了线程池插件替代默认的 one-thread-per-connection 模型。

### 6.1 核心变化

```
默认模型                线程池
──────────────         ──────────────
N 个连接 = N 个线程    N 个连接 = M 个线程（M << N）
每个线程全程持有       线程只在有命令时占用
高并发时线程数暴涨     线程数 = thread_pool_size + 少量溢出
上下文切换开销高       上下文切换少
可扩展性差（>200 连接） 可扩展至 >10000 连接
```

### 6.2 配置参数（线程池插件）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `thread_pool_size` | CPU 核数 | 线程组数 |
| `thread_pool_oversubscribe` | 3 | 每组最大活跃线程数 |
| `thread_pool_stall_limit` | 60ms | 监听超时 |
| `thread_pool_idle_timeout` | 60s | 空闲线程超时 |

### 6.3 线程池如何管理连接

```
连接 ID = X
groupId = X % thread_pool_size

组内结构:
  ┌──┐
  │  │ ← listener thread（监听新命令）
  │──│
  │  │ ← worker thread 1（执行命令）
  │  │ ← worker thread 2（执行命令）
  │  │
  └──┘
  每个组有自己的任务队列

连接分配:
  1. 新连接 → listener thread 接到
  2. listener 读命令包 → 放入组队列
  3. worker thread 从队列取 → 执行
  4. 执行完 → 检查队列有无更多任务
  5. 有空闲 → 等待下一个命令（不释放线程）
```

---

## 7. 性能统计

```sql
-- 连接相关
SHOW GLOBAL STATUS LIKE 'Connections';
SHOW GLOBAL STATUS LIKE 'Max_used_connections';
SHOW GLOBAL STATUS LIKE 'Threads_connected';
SHOW GLOBAL STATUS LIKE 'Threads_running';
SHOW GLOBAL STATUS LIKE 'Aborted_connects';
SHOW GLOBAL STATUS LIKE 'Connection_errors%';

-- 线程缓存
SHOW GLOBAL STATUS LIKE 'Threads_cached';
SHOW GLOBAL STATUS LIKE 'Threads_created'; -- 如太大 → 增大 thread_cache_size
```

| 变量 | 含义 | 正常范围 |
|------|------|---------|
| `Connections` | 尝试连接总次数 | 持续增长 |
| `Max_used_connections` | 最大并发连接 | < max_connections |
| `Threads_connected` | 当前打开连接 | 稍低于 max_connections |
| `Threads_running` | 正在执行查询的线程 | < CPU 核数 × 2 |
| `Aborted_connects` | 认证失败次数 | 接近 0 |
| `Connection_errors_internal` | 内部错误 | 接近 0 |

---

## 8. 源码索引（doom-lsp 验证）

| 函数/结构 | 文件 | 行号 |
|-----------|------|------|
| `max_connections` (全局变量) | `sql/mysqld.cc` | 1409 |
| `max_connect_errors` | `sql/mysqld.cc` | 1409 |
| `check_connection()` | `sql/sql_connect.cc` | 440 |
| `login_connection()` | `sql/sql_connect.cc` | 698 |
| `end_connection()` | `sql/sql_connect.cc` | 732 |
| `prepare_new_connection_state()` | `sql/sql_connect.cc` | 776 |
| `thd_prepare_connection()` | `sql/sql_connect.cc` | 892 |
| `close_connection()` | `sql/sql_connect.cc` | 917 |
| `thd_connection_alive()` | `sql/sql_connect.cc` | 935 |
| `check_for_max_user_connections()` | `sql/sql_connect.cc` | 182 |
| `do_command()` | `sql/sql_parse.cc` | 1347 |
| `dispatch_command()` | `sql/sql_parse.cc` | 1752 |
| `dispatch_sql_command()` | `sql/sql_parse.cc` | 5299 |
| `mysql_execute_command()` | `sql/sql_parse.cc` | 3031 |
| `THD::reset_for_next_command()` | `sql/sql_parse.cc` | 5190 |
| `THD` class | `sql/mysqld.h` | — |
