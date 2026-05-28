# 26. MySQL 连接与线程池 (Connection & Thread Pool)

> 本文分析 MySQL 的连接管理与线程模型，包括监听/接受线程、连接分发、Per-Thread 模型和 Thread Pool 扩展。核心文件：`sql/conn_handler/`、`sql/mysqld.cc`、`sql/sql_parse.cc`。

---

## 1. 概述

MySQL 传统上使用**一个线程处理一个连接**（one-thread-per-connection）模型。连接管理由 `Connection_handler_manager` 统一调度，通过 `Channel_info` 抽象支持多种传输协议。MySQL Enterprise 提供 Thread Pool 插件作为替代。

| 实现 | 类 | 说明 |
|------|----|------|
| Per-Thread | `Per_thread_connection_handler` | 每个连接创建一个新 pthread（默认） |
| Thread Pool | Plugin `connection_control.so` | 复用少量工作线程处理多个连接 |
| Socket | `Channel_info_socket` | TCP/IP / Unix Socket 传输 |
| Named Pipe | `Channel_info_named_pipe` | Windows Named Pipe |
| Shared Memory | `Channel_info_shared_mem` | Windows Shared Memory |

---

## 2. 连接接受与分发

### 2.1 mysqld_main 主循环

```cpp
// mysqld.cc — 主循环
mysqld_main() {
  // Step 1: 初始化网络监听
  mysql_socket_listen(listen_socket, bind_address, port);

  // Step 2: 主循环：接受连接，创建 Channel_info
  while (!abort_loop) {
    Channel_info *channel_info = Channel_info_socket::create(...);
    Connection_handler_manager::process_new_connection(channel_info);
  }

  // Step 3: 关闭监听
  mysql_socket_close(listen_socket);
}
```

### 2.2 连接分发 `process_new_connection`

```cpp
// connection_handler_manager.cc
bool Connection_handler_manager::process_new_connection(
    Channel_info *channel_info) {
  switch (connection_handler_type) {
    case CONN_HANDLER_PER_THREAD:
      Per_thread_connection_handler::add_connection(channel_info);
      break;
    case CONN_HANDLER_POOL:
      One_thread_connection_handler::add_connection(channel_info);
      break;
  }
}
```

### 2.3 Per-Thread 线程创建

```cpp
// connection_handler_impl.cc
void Per_thread_connection_handler::add_connection(
    Channel_info *channel_info) {
  pthread_t thread_id;
  mysql_thread_create(key_thread_one_connection,
                      &thread_id, &connection_attrib,
                      handle_one_connection,     // 线程入口
                      (void *)channel_info);
  ++thread_count;
}
```

---

## 3. 命令循环

`handle_one_connection` 作为线程入口，调用 `do_command()` 进入命令循环：

```cpp
// sql_parse.cc
bool do_command(THD *thd) {
  for (;;) {
    /* Step 1: 读取客户端命令包 */
    if (thd->get_protocol()->get_command(&com_data))
      break;  // 连接断开

    /* Step 2: 分发执行命令 */
    dispatch_command(thd, com_data);

    /* Step 3: 重置会话状态 */
    thd->update_charset();
    thd->clear_error();
  }
  // 连接结束，清理资源
}
```

`dispatch_command` 根据命令类型调用对应处理：

```
dispatch_command()
 ├─ COM_QUERY → mysql_parse() → mysql_execute_command()
 ├─ COM_STMT_EXECUTE → Prepared Statement 执行
 ├─ COM_PING → 回包
 ├─ COM_QUIT → 退出循环
 └─ COM_INIT_DB → 切换当前数据库
```

---

## 4. Channel_info 抽象

```cpp
// channel_info.h:47
class Channel_info {
 public:
  virtual THD *create_thd() = 0;           // 创建 THD 对象
  virtual void send_server_handshake() = 0; // 发送握手包
  Vio *m_vio;                              // 虚拟 I/O 层
};
```

子类：

```cpp
class Channel_info_socket : public Channel_info {
  st_mysql_socket m_socket;   // TCP/IP 套接字
};

class Channel_info_named_pipe : public Channel_info {
  HANDLE m_pipe;              // Windows 管道句柄
};

class Channel_info_shared_mem : public Channel_info {
  // Windows 共享内存通信
};
```

---

## 5. 线程池模型

MySQL Enterprise Thread Pool 替换 `Per_thread_connection_handler`：

- **Listener 线程**：接受新连接并分配给 Worker 线程
- **Worker 线程组**：每组 N 个 worker，共享一个连接队列
- **组内复用**：一个 worker 处理多个连接的 SQL 请求，减少上下文切换

```cpp
// connection_handler.h:39 — 基类
class Connection_handler {
  virtual bool add_connection(Channel_info *channel_info) = 0;
};
```

---

## 6. 连接监控

```sql
SHOW PROCESSLIST;
SHOW STATUS LIKE 'Threads_%';
```

| 状态变量 | 说明 |
|----------|------|
| `Threads_connected` | 当前打开的连接数 |
| `Threads_running` | 正在执行查询的线程数 |
| `Threads_created` | 自启动以来创建的线程总数 |
| `Connection_errors_accept` | 接受连接失败次数 |

---

## 7. 总结

1. **1:1 线程模型**：每个连接一个独立线程，实现简单但高并发时开销大。
2. **Channel_info 抽象**：支持 TCP/IP、Unix Socket、Named Pipe、Shared Memory 多种传输。
3. **do_command 循环**：在每个连接线程中循环处理 SQL 直到连接断开。
4. **线程池扩展**：Plugin 接口允许替换为线程池实现（MySQL Enterprise）。
5. **Vio 层**：统一的虚拟 I/O 抽象，屏蔽底层网络差异。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `channel_info.h` | 47 | `class Channel_info` |
| `connection_handler.h` | 39 | `class Connection_handler` 基类 |
| `connection_handler_impl.cc` | — | `Per_thread_connection_handler::add_connection()` |
| `connection_handler_manager.cc` | — | `process_new_connection()` |
| `sql_parse.cc` | — | `do_command()` 命令循环 |
| `mysqld.cc` | 2433 | Per-thread handler 引用 |
