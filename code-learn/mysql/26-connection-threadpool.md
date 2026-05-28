# 26. MySQL 连接与线程池（Connection & Thread Pool）— 源码分析

> 本文分析 MySQL 的连接管理、线程模型和线程池实现，包括连接协议、认证握手、线程调度、线程池插件和连接超时处理。核心源文件：`sql/mysqld.cc`、`sql/sql_connect.cc`、`sql/sql_parse.cc`、`sql/conn_handler/`。

---

## 0. 概述

MySQL 采用**每个连接一个线程（One-Thread-Per-Connection）**的模型。每个客户端连接对应一个操作系统线程（或线程池中的一个工作线程），由 MySQL 服务器进程统一管理。

### MySQL 连接模型演进

```
MySQL 5.6 及以前:
  ┌────────────┐     ┌──────────┐     ┌───────┐
  │  Client 1  │────→│  Thread 1 │────→│  SQL   │
  │  Client 2  │────→│  Thread 2 │────→│  Core  │
  │  Client N  │────→│  Thread N │────→│        │
  └────────────┘     └──────────┘     └───────┘
  (每个连接一个线程，简单但资源消耗大)

MySQL 8.0 (Enterprise + Percona):
  ┌────────────┐     ┌──────────┐     ┌───────┐
  │  Client 1  │────→│          │     │       │
  │  Client 2  │────→│  Thread  │────→│  SQL   │
  │  Client N  │────→│   Pool   │     │  Core  │
  └────────────┘     └──────────┘     └───────┘
  (线程池：有限线程数，大量连接共享)
```

---

## 1. 连接管理

### 1.1 连接建立流程

```
客户端: mysql -h host -u user -p

MySQL 服务器:
  └─ mysqld 主循环:
      ├─ poll(port, backlog)           ← 监听 TCP 端口
      ├─ accept()                      ← 接受新连接
      ├─ create_thread_to_handle_connection()
      │   ├─ create_new_thread(thd)    ← 创建线程 / 从池中分配
      │   ├─ thd_prepare_connection()  ← 准备连接上下文
      │   └─ check_user()              ← 认证握手
      └─ do_command()                  ← 主命令循环
```

### 1.2 认证握手

```cpp
// sql/sql_connect.cc
bool check_user(THD *thd, ...) {
  /* 步骤 1: 发送服务器握手包 */
  /* 包括: 服务器版本、连接 ID、认证插件、salt */

  /* 步骤 2: 接收客户端响应 */
  /* 包括: 用户名、加密后的密码、客户端标志 */

  /* 步骤 3: 查找用户 */
  /* 查询 mysql.user 系统表 */
  ACL_USER *acl_user = find_acl_user(thd, user, host, ...);

  /* 步骤 4: 验证密码 */
  if (!acl_user) return ER_ACCESS_DENIED_ERROR;

  /* 支持多种认证插件: */
  /* - mysql_native_password (默认, SHA1 加密) */
  /* - caching_sha2_password (8.0 默认, SHA256 加密) */
  /* - sha256_password */

  /* 步骤 5: 设置线程上下文 */
  thd->set_user(acl_user);
  thd->security_ctx->skip_grants();
  thd->variables = acl_user->user_variables;
}
```

### 1.3 连接参数

```cpp
// sql/mysqld.cc — 连接相关参数

/* 最大连接数 */
uint max_connections = 151;             /* 默认值 */
uint max_user_connections = 0;          /* 默认无限制 */
uint extra_max_connections = 1;         /* 保留一个给管理员 */

/* 超时 */
uint connect_timeout = 10;              /* 连接超时秒数 */
uint wait_timeout = 28800;              /* 空闲连接超时（8小时）*/
uint interactive_timeout = 28800;       /* 交互式会话超时 */

/* 连接拒绝 */
uint max_connect_errors = 100;          /* 最大连接错误数 */
```

---

## 2. 线程模型

### 2.1 主调度线程

```cpp
// sql/mysqld.cc — 主线程循环
void mysqld_main(int argc, char **argv) {
  /* 初始化 */
  mysqld_get_one_option(argc, argv);
  init_server_components();

  /* 创建监听 socket */
  setup_connection_port(port);

  /* 主循环：接受新连接 */
  while (!abort_loop) {
    fd = accept(port);
    if (fd >= 0) {
      /* 每个新连接创建一个线程 */
      create_new_thread(new THD());
    }
  }
}
```

### 2.2 THD（线程描述符）

每个客户端连接对应一个 `THD` 对象：

```cpp
// sql/mysqld.h
class THD {
 public:
  /** 连接信息 */
  uint thread_id;                    /* 线程 ID（SHOW PROCESSLIST 可见）*/
  uint net::vio *net_vio;           /* 网络 I/O 虚拟接口 */
  NET net;                            /* 网络缓冲区 */

  /** 安全上下文 */
  Security_context security_ctx;      /* 用户、权限、SSL */

  /** SQL 执行状态 */
  LEX *lex;                           /* 当前词法分析树 */
  Query_arena *query_arena;           /* 查询执行内存池 */
  sp_runtime_context *sp_ctx;         /* 存储过程上下文 */

  /** 会话变量 */
  SV *variables;                      /* 所有会话变量 */

  /** 统计 */
  ulonglong row_count;                /* 影响行数 */
  ulonglong last_insert_id;           /* 最后插入 ID */

  /** 锁管理 */
  Locked_tables_list locked_tables;   /* 已锁定表 */
  MDL_context mdl_context;            /* 元数据锁上下文 */
};
```

---

## 3. 命令循环 — do_command()

```cpp
// sql/sql_parse.cc
bool do_command(THD *thd) {
  /* ──── 步骤 1：等待命令 ──── */
  /* 检查网络是否有新数据 */
  /* 使用 poll() / epoll() / kqueue() 网络事件驱动 */

  /* ──── 步骤 2：读取命令包 ──── */
  NET *net = &thd->net;
  packet = my_net_read(net);

  /* ──── 步骤 3：解析命令 ──── */
  /* 第一个字节是命令类型 */
  enum enum_server_command cmd = packet[0];

  /* ──── 步骤 4：分发执行 ──── */
  switch (cmd) {
    case COM_QUERY:
      dispatch_command(COM_QUERY, thd, packet + 1, packet_length - 1);
      break;
    case COM_STMT_EXECUTE:
      /* 预处理语句执行 */
      break;
    case COM_PING:
      /* 心跳 */
      net_send_ok(thd);
      break;
    case COM_QUIT:
      /* 断开连接 */
      end_connection(thd);
      close_connection(thd);
      return false;
  }

  return true;  /* 继续下一个命令 */
}
```

---

## 4. 线程池（Thread Pool）

### 4.1 线程池架构（MySQL Enterprise + Percona）

```
线程池插件按 CPU 核数创建线程组:

  thread_pool_size = number_of_CPUs (默认 16)

  每个组:
    ┌───── listener thread ─→ 等待新连接/新命令
    │     ├─ 当连接在组中有命令到达时，唤醒一个 worker thread
    │     └─ worker threads 从队列中取任务执行
    │
    └───── worker threads (0..N)
           ├─ 执行 SQL 命令
           └─ 执行完后回到池中等待下一个命令
```

### 4.2 关键参数

```cpp
/* 线程池插件参数 */
ulong thread_pool_size = 16;              /* 线程组数 */
ulong thread_pool_oversubscribe = 3;      /* 每组最大活动线程数 */
ulong thread_pool_stall_limit = 60;       /* 监听超时(ms) */
```

`thread_pool_oversubscribe = 3` 的作用：避免过多的活跃线程争抢 CPU，但保留额外的线程来处理 I/O 等待。

### 4.3 连接分配

```cpp
// thread_pool.cc — 简化
void *thread_pool_add_connection(THD *thd) {
  /* 使用哈希将连接分配到线程组 */
  /* connection_id % thread_pool_size */

  group_id = thd->thread_id % thread_pool_size;
  add_connection_to_group(group_id, thd);

  /* 唤醒该组的监听线程 */
  wake_listener(group_id);
}
```

---

## 5. 连接超时处理

### 5.1 空闲连接清理

```cpp
// sql/sql_connect.cc
void kill_idle_threads(void) {
  /* 定期遍历所有连接 */
  for (THD *thd : all_connections) {
    if (thd_is_idle(thd)) {
      time_t idle_time = time(NULL) - thd->last_command_time;
      if (idle_time > thd->variables.wait_timeout) {
        /* 超过 idle 超时，断开连接 */
        kill_thread(thd);
      }
    }
  }
}
```

### 5.2 连接错误限制

```cpp
// sql/sql_connect.cc
void create_new_thread(THD *thd) {
  if (connection_errors > max_connect_errors) {
    /* 超过最大连接错误数 → 阻止主机连接 */
    my_error(ER_HOST_NOT_PRIVILEGED, ...);
    close_connection(thd);
    return;
  }
  ...
}
```

---

## 6. 性能统计

```sql
-- 连接相关状态
SHOW GLOBAL STATUS LIKE 'Connections%';       -- 总连接数
SHOW GLOBAL STATUS LIKE 'Threads_%';          -- 线程数
SHOW GLOBAL STATUS LIKE 'Aborted_connects%';  -- 失败连接

-- 连接池相关
SHOW GLOBAL STATUS LIKE 'Threadpool_%';       -- 线程池统计（如果启用）

-- 当前连接（processlist 模拟）
SHOW PROCESSLIST;
```

| 状态变量 | 说明 |
|---------|------|
| `Connections` | 尝试连接的总次数 |
| `Max_used_connections` | 最大并发连接数 |
| `Threads_connected` | 当前打开连接数 |
| `Threads_running` | 正在执行查询的线程数 |
| `Aborted_connects` | 连接失败的次数 |
| `Connection_errors_*` | 各类型连接错误计数 |

---

## 7. 源码索引

| 函数/结构 | 文件 | 关键作用 |
|-----------|------|---------|
| `THD` class | `sql/mysqld.h` | 线程描述符 |
| `do_command()` | `sql/sql_parse.cc` | 命令循环主函数 |
| `dispatch_command()` | `sql/sql_parse.cc` | 命令分派 |
| `check_user()` | `sql/sql_connect.cc` | 认证握手 |
| `kill_idle_threads()` | `sql/sql_connect.cc` | 清理空闲连接 |
| `create_new_thread()` | `sql/sql_connect.cc` | 创建连接线程 |
| `thread_pool_add_connection()` | `sql/conn_handler/` | 线程池添加连接 |
