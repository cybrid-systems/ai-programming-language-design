# 30 — OBServer 启动与生命周期 — 模块初始化与服务注册

> 基于 OceanBase CE 主线源码
> 分析范围：`src/observer/main.cpp` + `src/observer/ob_server.h/cpp` + `src/observer/ob_heartbeat.h` + `src/observer/ob_check_params.h` + `src/observer/ob_startup_accel_task_handler.h`
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

OBServer 是 OceanBase 数据库的**单进程守护程序**。它的启动流程回答了三个问题：

1. **进程怎么活起来？** — 从 `main()` 到所有子系统初始化
2. **各模块按什么顺序启动？**
3. **如何注册到集群？** — 心跳与 RootService 交互

启动流程是一个有严格依赖关系的**分层初始化**过程：

```
  命令行参数解析
       │
       ▼
  信号掩码设置 & 环境初始化
       │
       ▼
  ┌─────────────────────┐
  │  ObServer::init()   │ ← 初始化所有全局模块
  │  (约 300 行 init 链)  │
  └─────────┬───────────┘
            │
            ▼
  ┌─────────────────────┐
  │  ObServer::start()  │ ← 启动所有服务线程
  │  (约 250 行启动链)   │
  └─────────┬───────────┘
            │
            ▼
  ┌─────────────────────┐
  │  ObServer::wait()   │ ← 等待 stop 信号
  │  (主循环阻塞)        │
  └─────────┬───────────┘
            │
            ▼
  ┌─────────────────────┐
  │  ObServer::stop()   │ ← 反向停止所有模块
  │  ObServer::destroy()│ ← 逆序销毁
  └─────────────────────┘
```

---

## 1. main 函数入口

**文件**: `src/observer/main.cpp` — 行 688-708

`main()` 函数异常简洁——职责是准备独立栈空间并跳转到 `inner_main()`：

```cpp
int main(int argc, char *argv[])
{
  int ret = OB_SUCCESS;
  size_t stack_size = 16<<20;  // 16MB 栈
  struct rlimit limit;
  if (0 == getrlimit(RLIMIT_STACK, &limit)) {
    if (RLIM_INFINITY != limit.rlim_cur) {
      stack_size = limit.rlim_cur;
    }
  }
  void *stack_addr = ::mmap(nullptr, stack_size,
      PROT_READ | PROT_WRITE,
      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (MAP_FAILED == stack_addr) {
    ret = OB_ERR_UNEXPECTED;
  } else {
    ret = CALL_WITH_NEW_STACK(inner_main(argc, argv), stack_addr, stack_size);
    if (-1 == ::munmap(stack_addr, stack_size)) {
      ret = OB_ERR_UNEXPECTED;
    }
  }
  return ret;
}
```

设计要点：
- **16MB 独立栈**：通过 `mmap` 分配独立栈空间，避免栈溢出影响主进程
- `CALL_WITH_NEW_STACK` 宏将 `inner_main` 放在新栈上执行
- 所有实质性工作在 `inner_main()` 中完成（行 503-687）

### 1.1 inner_main 函数

`inner_main()`（行 503-687）是实际的启动入口，顺序执行：

```
inner_main():
  1. 设置信号掩码                    (ObSignalHandle::change_signal_mask)
  2. 创建日志/运行/配置目录           (FileDirectoryUtils::create_full_path)
  3. 初始化 SSL 内存分配器            (ObEncryptionUtil::init_ssl_malloc)
  4. 可选 daemon 化                  (start_daemon)
  5. 初始化日志系统                   (OB_LOGGER.set_*)
  6. 打印版本/限制/内存映射信息
  7. mallopt 调优                    (M_ARENA_MAX=1, M_MMAP_MAX=1G)
  8. Worker 线程绑定                 (lib::Worker 线程局部存储)
  9. ObServer::init(opts, log_cfg)   ㊀ 初始化
 10. ObServer::start()               ㊁ 启动
 11. ObServer::wait()                ㊂ 等待退出
 12. ObServer::destroy()             ㊃ 销毁
 13. curl_global_cleanup() / unlink(PID_FILE_NAME)
```

关键代码（行 648-657）：

```cpp
ObServer &observer = ObServer::get_instance();
if (OB_FAIL(observer.init(opts, log_cfg))) {
  LOG_ERROR("observer init fail", KR(ret));
  raise(SIGKILL);
} else if (OB_FAIL(observer.start())) {
  LOG_ERROR("observer start fail", KR(ret));
  raise(SIGKILL);
} else if (OB_FAIL(observer.wait())) {
  LOG_ERROR("observer wait fail", KR(ret));
}
```

任何阶段失败都会 `raise(SIGKILL)` 强制终止进程。

### 1.2 命令行参数

参数解析通过标准的 `getopt_long` 实现（行 240-410），支持的参数：

| 选项 | 长选项 | 含义 |
|------|--------|------|
| `-p` | `--mysql_port` | MySQL 协议端口（1024-65536） |
| `-P` | `--rpc_port` | RPC 通信端口 |
| `-z` | `--zone` | 属于哪个 Zone |
| `-o` | `--optstr` | 额外配置字符串 |
| `-r` | `--rs_list` | RootService 列表 |
| `-c` | `--cluster_id` | 集群 ID |
| `-d` | `--data_dir` | 数据目录 |
| `-i` | `--devname` | 网络设备名 |
| `-I` | `--local_ip` | 本机 IP |
| `-l` | `--log_level` | 日志级别 |
| `-N` | `--nodaemon` | 前台运行 |
| `-n` | `--appname` | 应用名称 |
| `-m` | `--mode` | 启动模式 |
| `-6` | `--ipv6` | 启用 IPv6 |
| `-V` | `--version` | 打印版本 |
| `-C` | `--dump_config_to_json` | 导出配置为 JSON |

---

## 2. ObServer 单例设计

**文件**: `src/observer/ob_server.h` — 行 111-380; `ob_server.cpp` — 行 135-1803

`ObServer` 是典型的**单例模式**：

```cpp
class ObServer {
public:
  static ObServer &get_instance();
  int init(const ObServerOptions &opts, const ObPLogWriterCfg &log_cfg);
  int start();
  int wait();
  void set_stop();
  void destroy();
  // ...
};

inline ObServer &ObServer::get_instance()
{
  static ObServer THE_ONE;    // C++11 静态局部变量 —— 线程安全单例
  return THE_ONE;
}
```

### 2.1 ObServer 的核心成员

ObServer 聚合了 Observer 的全部核心模块（行 111-380）：

| 成员 | 类型 | 用途 |
|------|------|------|
| `gctx_` | `ObGlobalContext &` | 全局上下文（指向所有子系统的指针集合） |
| `self_addr_` | `ObAddr` | 本机地址 |
| `net_frame_` | `ObSrvNetworkFrame` | 网络框架（RPC + MySQL 协议） |
| `multi_tenant_` | `ObMultiTenant` | 多租户管理器 |
| `root_service_` | `ObRootService` | RootService 逻辑 |
| `ob_service_` | `ObService` | OceanBase 通用服务 |
| `schema_service_` | `ObMultiVersionSchemaService &` | Schema 服务 |
| `sql_engine_` | `ObSql` | SQL 引擎 |
| `pl_engine_` | `ObPL` | PL 引擎 |
| `config_` | `ObServerConfig &` | 服务器配置 |
| `startup_accel_handler_` | `ObStartupAccelTaskHandler` | 启动加速处理器 |
| `weak_read_service_` | `ObWeakReadService` | 弱一致读服务 |
| `bl_service_` | `ObBLService &` | 黑名单服务 |
| `server_tracer_` | `ObAliveServerTracer` | 活跃节点追踪 |
| `location_service_` | `ObLocationService` | 位置服务 |
| `start_time_` | `int64_t` | 启动时间戳 |
| `signal_handle_` | `ObSignalHandle *` | 信号处理器 |
| `sig_worker_` | `ObSignalWorker *` | 信号处理线程 |

---

## 3. ObServer::init() — 初始化阶段

**文件**: `src/observer/ob_server.cpp` — 行 237-605

`init()` 是 OceanBase 中最长的初始化链，包含约 **80+ 个初始化步骤**。每个步骤使用 `OB_SUCC(ret) && OB_FAIL(...)` 链式检查，任何一个失败则整个初始化中止。

### 3.1 初始化顺序总览

```
ObServer::init(opts, log_cfg)
├─ 0. 基础设置
│   ├─ init_arches()               ← 初始化架构相关常量
│   └─ scramble_rand_.init()       ← MySQL scramble 随机数
│
├─ 1. 配置与环境检查
│   ├─ init_config()               ← 加载配置（行 2121）
│   │   ├─ ODV_MGR.init()          ← 数据版本管理器
│   │   ├─ config_mgr_.load_config() ← 从文件加载配置
│   │   ├─ init_opts_config()      ← 命令行参数覆盖配置
│   │   ├─ init_local_ip_and_devname()
│   │   ├─ init_self_addr()
│   │   ├─ strict_check_special()  ← 配置合法性检查
│   │   ├─ GMEMCONF.reload_config() ← 内存配置
│   │   └─ init_config_module()    ← 配置订阅模块
│   ├─ check_os_params()           ← 检查 OS 参数（ulimit, vm 等）
│   └─ ObLargePageHelper::set_param()
│
├─ 2. 线程池与定时器基础设施
│   ├─ ObSimpleThreadPoolDynamicMgr::get_instance().init()
│   └─ ObTimerService::get_instance().start()
│
├─ 3. 日志系统（优先初始化）
│   ├─ OB_LOGGER.init(log_cfg)     ← 异步日志初始化
│   ├─ OB_LOG_COMPRESSOR.init()    ← 日志压缩器
│   └─ OB_LOGGER.set_log_compressor()
│
├─ 4. SQL 引擎基础设施
│   ├─ init_tz_info_mgr()          ← 时区信息
│   ├─ ObSqlTaskFactory::get_instance().init()
│   ├─ sql::init_sql_factories()   ← SQL 工厂类
│   ├─ sql::init_sql_executor_singletons()
│   ├─ ObPreProcessSysVars::init_sys_var()
│   └─ ObBasicSessionInfo::init_sys_vars_cache_base_values()
│
├─ 5. 全局上下文 & 版本
│   ├─ init_global_context()       ← gctx_ 指针赋值（行 3095+）
│   └─ init_version()              ← 版本号初始化
│
├─ 6. 存储 & IO & 设备
│   ├─ init_sql_proxy()            ← 内 SQL 连接池
│   ├─ init_io()                   ← IO 管理器
│   └─ init_restore_ctx()          ← 恢复上下文
│
├─ 7. 缓存
│   ├─ init_global_kvcache()       ← KV 全局缓存
│   ├─ init_schema()               ← Schema 缓存
│   └─ init_tx_data_cache() / init_log_kv_cache()
│
├─ 8. 网络
│   ├─ init_network()              ← 网络框架初始化（行 2778）
│   │   ├─ net_frame_.init()       ← ObSrvNetworkFrame
│   │   ├─ 获取 RPC Proxy（srv/storage/rs/executor 等）
│   │   ├─ batch_rpc_.init()       ← 批量 RPC 通道
│   │   └─ rl_mgr_.init()          ← 限流管理器
│   ├─ init_interrupt()            ← 中断机制
│   └─ init_zlib_lite_compressor()
│
├─ 9. 元数据服务
│   ├─ rs_mgr_.init()              ← RsMgr (RootService 管理器)
│   ├─ server_tracer_.init()       ← 活跃节点追踪
│   ├─ init_ob_service()           ← OceanBase 服务
│   ├─ init_root_service()         ← RootService（行 2921）
│   ├─ root_service_monitor_.init()
│   ├─ lst_operator_.init()        ← LS 表操作
│   ├─ tablet_operator_.init()     ← Tablet 表操作
│   └─ location_service_.init()    ← 位置服务
│
├─ 10. 自增列服务
│   ├─ init_autoincrement_service()
│   ├─ init_table_lock_rpc_client()
│   └─ init_tablet_autoincrement_service()
│
├─ 11. 存储引擎
│   ├─ init_storage()              ← 存储引擎（SSTable/Memtable）
│   ├─ init_tx_data_cache()        ← 事务数据缓存
│   └─ ObTmpPageCache::get_instance().init()
│
├─ 12. 时钟 & 一致性
│   ├─ ObClockGenerator::init()
│   ├─ init_ts_mgr()               ← 时间戳管理器
│   ├─ weak_read_service_.init()   ← 弱一致读
│   ├─ bl_service_.init()          ← 黑名单
│   └─ palf::election::GLOBAL_INIT_ELECTION_MODULE()
│
├─ 13. PX 并行执行
│   ├─ ObPxBloomFilterManager::instance().init()
│   ├─ PX_P2P_DH.init()            ← P2P DataHub
│   └─ init_px_target_mgr()
│
├─ 14. 多租户
│   └─ init_multi_tenant()         ← 多租户框架（行 2850）
│
├─ 15. 定时任务
│   ├─ init_ddl_heart_beat_task_container()
│   ├─ init_redef_heart_beat_task()
│   ├─ init_refresh_network_speed_task()
│   ├─ init_refresh_cpu_frequency()
│   ├─ init_refresh_io_calibration()
│   └─ startup_accel_handler_.init()  ← 加速处理器
│
├─ 16. 其他服务
│   ├─ ObOptStatManager::get_instance().init()
│   ├─ ObSysTaskStatMgr::get_instance().set_self_addr()
│   ├─ ObServerAutoSplitScheduler::get_instance().init()
│   ├─ table_service_.init()
│   ├─ ObTimerMonitor / ObBGThreadMonitor
│   ├─ ObActiveSessHistList::get_instance().init()
│   ├─ ObServerBlacklist::get_instance().init()
│   ├─ ObBackupIndexCache / ObBackupMetaCache / ObDictCache
│   ├─ OB_STANDBY_SERVICE.init()
│   └─ wr_service_.init()
```

### 3.2 init_network — 网络框架初始化（行 2778）

```cpp
int ObServer::init_network()
{
  int ret = OB_SUCCESS;
  const char* mysql_unix_path = "unix:run/sql.sock";
  const char* rpc_unix_path = "unix:run/rpc.sock";

  obrpc::ObIRpcExtraPayload::set_extra_payload(ObRpcExtraPayload::extra_payload_instance());

  if (OB_FAIL(net_frame_.init(mysql_unix_path, rpc_unix_path))) {
    // ...
  } else if (OB_FAIL(net_frame_.get_proxy(srv_rpc_proxy_))) {
    // ...
  } else if (OB_FAIL(net_frame_.get_proxy(storage_rpc_proxy_))) {
    // ...
  } else if (OB_FAIL(net_frame_.get_proxy(rs_rpc_proxy_))) {
    // ...
  } else if (OB_FAIL(net_frame_.get_proxy(executor_proxy_))) {
    // ...
  } // ... 还有 6 个 proxy
}
```

`ObSrvNetworkFrame` 封装了 OceanBase 的完整网络堆栈：
- MySQL 协议监听（默认 2881）
- RPC 协议监听（默认 2882）
- 批量 RPC 通道（内部批量通信）
- Unix Domain Socket（本地通信）

初始化时创建所有 RPC Proxy 实例，但**不启动网络监听**——监听在 `start()` 阶段才启动。

### 3.3 init_root_service — RootService 初始化（行 2921）

```cpp
int ObServer::init_root_service()
{
  int ret = OB_SUCCESS;
  if (OB_FAIL(root_service_.init(
                 config_, config_mgr_, srv_rpc_proxy_,
                 rs_rpc_proxy_, self_addr_, sql_proxy_,
                 restore_ctx_, rs_mgr_, &schema_service_, lst_operator_))) {
    LOG_ERROR("init root service failed", K(ret));
  }
  return ret;
}
```

RootService 是集群的**元数据大脑**，在初始化阶段注入所有依赖：
- 配置与配置管理器
- RPC 代理（SrvRpc + CommonRpc）
- SQL Proxy（用于访问系统表）
- Schema 服务
- LS 表操作器

---

## 4. ObServer::start() — 启动阶段

**文件**: `src/observer/ob_server.cpp` — 行 951-1190

`init()` 创建了所有模块实例，`start()` 则**启动所有线程和服务**——把"静态"的实例变成"动态"的运行态。

### 4.1 启动顺序

```
ObServer::start()
├─ 状态转换: gctx_.status_ = SS_STARTING
│
├─ 1. 信号处理
│   ├─ start_sig_worker_and_handle()    ← 信号处理器线程
│   └─ startup_accel_handler_.start()   ← 加速处理器启动
│
├─ 2. 时间戳服务
│   └─ OB_TS_MGR.start()
│
├─ 3. 网络框架
│   └─ net_frame_.start()               ← 开始监听端口！
│
├─ 4. Schema 助手
│   ├─ ObMdsSchemaHelper::get_instance().init()
│   └─ ObTabletReorgInfoTableSchemaHelper::get_instance().init()
│
├─ 5. IO & 存储
│   ├─ ObIOManager::get_instance().start()
│   ├─ OB_STORAGE_OBJECT_MGR.start()    ← 存储对象管理器
│   ├─ OB_EXTERNAL_FILE_DISK_SPACE_MGR.start()
│   └─ SERVER_STORAGE_META_SERVICE.start()
│
├─ 6. 多租户
│   ├─ multi_tenant_.start()            ← 租户线程启动
│   └─ wr_service_.start()
│
├─ 7. 日志存储
│   └─ log_block_mgr_.start()           ← 日志块管理器
│
├─ 8. 隐藏 SYS 租户
│   └─ try_update_hidden_sys()          ← 创建/更新隐藏 SYS 租户
│
├─ 9. 位置服务
│   └─ location_service_.start()
│
├─ 10. 一致性与监控服务
│   ├─ weak_read_service_.start()       ← 弱一致读
│   ├─ bl_service_.start()              ← 黑名单
│   ├─ root_service_monitor_.start()    ← RootService 监控
│   ├─ ob_service_.start()              ← 通用服务
│   └─ locality_manager_.start()
│
├─ 11. 监控 & 诊断
│   ├─ reload_config_()                 ← 配置重载
│   ├─ ObTimerMonitor::get_instance().start()
│   ├─ ObBGThreadMonitor::get_instance().start()
│   ├─ ObActiveSessHistTask::get_instance().start()
│   ├─ ObStorageHADiagService::instance().start()
│   ├─ unix_domain_listener_.start()
│   └─ OB_PX_TARGET_MGR.start()
│
├─ 12. 加速处理器销毁
│   └─ startup_accel_handler_.destroy()  ← 启动加速任务完成
│
├─ 13. 等待就绪
│   ├─ config_mgr_.got_version()        ← 配置版本同步
│   ├─ check_if_multi_tenant_synced()   ← 等待多租户同步（轮询）
│   ├─ check_if_schema_ready()          ← 等待 Schema 就绪（轮询）
│   ├─ check_if_timezone_usable()       ← 等待时区可用（轮询）
│   └─ check_user_tenant_schema / check_log_replay_over (最长 15min 等待)
│
├─ 14. 最终就绪
│   ├─ ObLicenseUtils::start_license_mgr()
│   └─ gctx_.status_ = SS_SERVING       ← 服务状态设为 SERVING
│      gctx_.start_service_time_ = now()
```

### 4.2 关键启动阶段详解

**网络启动** (`net_frame_.start()`)：此时才真正绑定端口开始监听。客户端连接、RPC 请求在此之后才能到达。

**log_block_mgr_.start()**：启动日志块管理器，分配预写日志（clog/ilog）的磁盘空间。

**多租户同步等待**（行 1287-1330）：启动过程中有多个**阻塞轮询**等待点：

```cpp
int ObServer::check_if_multi_tenant_synced()
{
  // 轮询 multi_tenant_.has_synced()，每秒检查一次
  while (OB_SUCC(ret) && !stop_ && !synced) {
    synced = multi_tenant_.has_synced();
    if (!synced) {
      SLEEP(1);
    }
  }
}
```

`check_if_schema_ready()`（行 1365-1386）：等待 SYS 租户的 Full Schema 刷新完成。

`check_log_replay_over()`：等待 clogs 重放完毕，最长 **15 分钟**。

### 4.3 状态机

```
INIT ──init()──▶ SS_INITING ──start()──▶ SS_STARTING ──▶ SS_SERVING
                                                              │
                                                              │ set_stop()
                                                              ▼
                                                          SS_STOPPING
```

---

## 5. 心跳与集群注册

**文件**: `src/observer/ob_heartbeat.h` — 行 39-133

OceanBase 的集群心跳机制通过 `ObHeartBeatProcess` 实现。它向 RootService 周期上报本节点状态，并从响应中获取集群级指令。

```cpp
class ObHeartBeatProcess : public observer::IHeartBeatProcess
{
public:
  int init();
  void stop();
  void wait();
  void destroy();

  virtual int init_lease_request(ObLeaseRequest &lease_request);
  virtual int do_heartbeat_event(const ObLeaseResponse &lease_response);

  int update_lease_info();
  int try_update_infos();

private:
  // 定时任务：更新 Zone 级租约信息
  class ObZoneLeaseInfoUpdateTask : public common::ObTimerTask { ... };
  
  // 定时任务：持久化 Server ID
  class ObServerIdPersistTask : public common::ObTimerTask { ... };
};
```

### 心跳交互流程

```
OBServer                            RootService
    │                                    │
    │──── ObLeaseRequest ───────────────▶│
    │  (服务器信息、租约版本、磁盘/网络)     │
    │                                    │
    │◀── ObLeaseResponse ────────────────│
    │  (lease_info, schema_version,      │
    │   config_version, time_zone_info,   │
    │   server_id, lease_expire_time)     │
    │                                    │
    ├── do_heartbeat_event()
    │   ├── try_update_infos()
    │   │   ├── try_reload_config()      ← 配置热更新
    │   │   ├── try_reload_time_zone_info()
    │   │   └── check_and_update_server_id_()
    │   ├── update_lease_info()           ← 更新租约信息
    │   └── schema_updater_ 异步刷新      ← Schema 增量更新
```

### 心跳中传递的关键信息

**请求端** (`init_lease_request`):
- `lease_request` 中携带本节点的资源状态（磁盘、网络、CPU）
- 最大存储版本号（用于 TDE 主密钥管理）
- 租约信息

**响应端** (`do_heartbeat_event`):
- `lease_response` 携带集群分配的新 lease
- 配置版本号（通知热更新）
- Schema 版本号（触发异步 Schema 刷新）
- 时区版本号
- Server ID 分配（首次注册时）

### 心跳与 Schema 更新的关联

`ObHeartBeatProcess` 中持有一个 `ObServerSchemaUpdater &schema_updater_` 引用。当心跳响应中的 Schema 版本比本地高时，会触发异步 Schema 刷新——这正是前 29 篇文章中多次提到的**心跳驱动 Schema 同步**机制。

---

## 6. 操作系统参数检查

**文件**: `src/observer/ob_check_params.h` — 行 21-65

OceanBase 在启动时会对操作系统环境做一系列检查，确保运行环境符合要求：

```cpp
class CheckAllParams
{
public:
  static int check_all_params(bool strict_check);

private:
  static int check_vm_max_map_count();         // 1. mmap 上限
  static int check_vm_min_free_kbytes();       // 2. 最小空闲内存
  static int check_vm_overcommit_memory();     // 3. 内存超分策略
  static int check_fs_file_max();              // 4. 全局文件句柄上限
  static int check_ulimit_open_files();        // 5. 进程文件句柄上限
  static int check_ulimit_max_user_processes(); // 6. 用户进程数上限
  static int check_ulimit_core_file_size();    // 7. Core dump 大小
  static int check_ulimit_stack_size();        // 8. 栈大小
  static int check_current_clocksource();      // 9. 时钟源
};
```

`strict_check_os_params` 配置控制检查的严格程度。如果开启，资源不足时直接报错退出；否则只打 Warning。

在 `inner_main()` 中还会通过 `print_all_limits()`（行 426-439）打印所有资源限制到日志，方便运维人员排查。

---

## 7. 启动加速任务处理器

**文件**: `src/observer/ob_startup_accel_task_handler.h` 行 31-73

启动加速处理器是 OceanBase 启动性能优化的关键组件：

```cpp
class ObStartupAccelTaskHandler : public lib::TGTaskHandler
{
public:
  int init(ObStartupAccelType accel_type);
  int start();
  void stop();
  void wait();
  void destroy();
  void handle(void *task) override;
  int push_task(ObStartupAccelTask *task);
};

class ObStartupAccelTask {
public:
  virtual int execute() = 0;  // 纯虚函数，具体任务实现
};
```

### 设计目标

启动过程中有许多**可并行执行**的初始化任务：
- Tenant 级别的 Schema 加载
- 存储元数据预加载
- 缓存预热

这些任务如果串行执行会显著延长启动时间。`ObStartupAccelTaskHandler` 提供了一个**线程池+任务队列**的执行框架：

```
启动主线程                  ObStartupAccelTaskHandler
    │                              │
    ├── startup_accel_handler_.init()  ← 创建线程池
    ├── [init 过程中]
    │   push_task(task1) ──────────▶ 线程池1执行
    │   push_task(task2) ──────────▶ 线程池2执行
    │   push_task(task3) ──────────▶ 线程池3执行
    │   ...                          并行执行
    │
    └── startup_accel_handler_.start() ← 开始消费队列
```

支持两种类型（`ObStartupAccelType`）：
- `SERVER_ACCEL = 1`：Server 级别的加速（在 `init()` 的末尾初始化，在 `start()` 中启动）
- `TENANT_ACCEL = 2`：Tenant 级别的加速（在租户创建时使用）

启动加速处理器在 `start()` 的最后阶段调用 `destroy()`（行 1216），因为所有启动加速任务在服务正式就绪前已完成。

---

## 8. 完整启动时序图

```
   main()                       ObServer               Subsystems
    │                              │                      │
    │ mmap(CALL_WITH_NEW_STACK)    │                      │
    │─────────────────────────────▶│                      │
    │                              │                      │
    │ inner_main()                 │                      │
    │ ├─ parse_opts()              │                      │
    │ ├─ change_signal_mask()      │                      │
    │ ├─ create_directories()      │                      │
    │ └─ init_logger()             │                      │
    │                              │                      │
    │ observer.init()              │                      │
    │──────────────────────────────▶                      │
    │                              │ init_config()        │
    │                              │ ├─ ODV_MGR.load     │
    │                              │ ├─ config_mgr.load  │
    │                              │ ├─ init_self_addr   │
    │                              │ └─ init_config_mod  │
    │                              │                      │
    │                              │ check_os_params()   │
    │                              │ ObTimerService.start│
    │                              │ OB_LOGGER.init()     │
    │                              │                      │
    │                              │ init_global_context()│
    │                              │ init_version()       │
    │                              │ init_sql_proxy()    │
    │                              │ init_io()           │
    │                              │ init_global_kvcache │
    │                              │                      │
    │                              │ init_schema()       │
    │                              │ init_network()      │
    │                              │ ├─ net_frame_.init  │──▶ 创建 RPC Proxy
    │                              │ ├─ batch_rpc_.init  │──▶ 批量 RPC
    │                              │ └─ 获取所有 proxy   │
    │                              │                      │
    │                              │ init_root_service() │
    │                              │ init_sql()          │──▶ sql_engine_.init
    │                              │ init_storage()      │──▶ 存储引擎
    │                              │ init_multi_tenant() │──▶ 多租户
    │                              │ init_px_target_mgr  │──▶ PX 目标管理
    │                              │ startup_accel_.init │──▶ 加速处理器
    │                              │                      │
    │                              ◀── return OB_SUCCESS  │
    │                              │                      │
    │ observer.start()             │                      │
    │──────────────────────────────▶                      │
    │                              │ status=SS_STARTING   │
    │                              │ start_sig_worker()   │──▶ 信号线程
    │                              │ startup_accel.start  │──▶ 并行加速任务
    │                              │ OB_TS_MGR.start()    │
    │                              │ net_frame_.start()   │──▶ 端口监听！
    │                              │ multi_tenant_.start()│──▶ 租户线程
    │                              │ log_block_mgr.start  │──▶ 日志存储
    │                              │ try_update_hidden_sys│──▶ 创建 SYS 租户
    │                              │                      │
    │                              │ ╔══════════════════╗  │
    │                              │ ║  轮询等待就绪     ║  │
    │                              │ ║  - 多租户同步     ║  │
    │                              │ ║  - Schema 就绪    ║  │
    │                              │ ║  - 时区可用       ║  │
    │                              │ ║  - 日志重放完成   ║  │
    │                              │ ║  (最长 15 分钟)   ║  │
    │                              │ ╚══════════════════╝  │
    │                              │                      │
    │                              │ status=SS_SERVING    │
    │                              ◀── return OB_SUCCESS  │
    │                              │                      │
    │ observer.wait()              │                      │
    │──────────────────────────────▶                      │
    │                              │                      │
    │    ┌──────────────────┐      │                      │
    │    │  SLEEP(3) 循环   │      │  ObHeartBeatProcess │
    │    │  等待 stop_ 标志  │      │  ──▶ 定期发心跳     │
    │    │  收到 SIGTERM →  │      │  ──▶ Schema 更新    │
    │    │  set_stop()      │      │  ──▶ 配置热更新     │
    │    └──────────────────┘      │                      │
    │                              │                      │
    │  SIGTERM/SIGINT 到达         │                      │
    │──────────────────────────────▶                      │
    │                              │ set_stop()            │
    │                              │ status=SS_STOPPING    │
    │                              │                      │
    │ observer.stop()              │                      │
    │  ── 逆序停止所有子系统 ──     │                      │
    │                              │                      │
    │ observer.destroy()           │                      │
    │  ── 逆序销毁所有子系统 ──     │                      │
    │                              │                      │
    │ curl_global_cleanup()        │                      │
    │ unlink(PID_FILE)             │                      │
    │ exit(0)                      │                      │
```

---

## 9. 与前面 29 篇的关联总图

把前面每篇文章分析过的子系统，放在 OBServer 启动的生命周期来看：

```
                      ObServer::init()
                              │
        ┌─────────────────────┼──────────────────────────┐
        │                     │                          │
        ▼                     ▼                          ▼
  配置加载             Schema 初始化              网络框架初始化
   (第 25 篇)          (第 18 篇)                 (第 9/17 篇)
        │                     │                          │
        ▼                     ▼                          ▼
  内存管理初始化          存储管理                   RootService
   (第 25 篇)     ┌──── (第 7/8/14/15 篇) ────┐    (第 27 篇)
                  │  SSTable   Memtable  KeyBtree │        │
                  │  (8)       (6/14)    (15)     │        ▼
                  │  LS Tree   Clog      PALF     │    Schema 服务
                  │  (7)       (13)       (11)    │    (第 18 篇)
                  └───────────────────────────────┘
                  │             │           │
                  ▼             ▼           ▼
             SQL 引擎        事务系统     日志框架
    ┌──── (第 9/17/23 篇) ── (第 10/16 篇)  (第 11/13 篇)
    │   Parser    Optimizer    PX            │
    │   (23)      (17)        (21)           │
    │   Executor  Plan Cache                │
    │   (9)       (22)                       │
    └───────────────────────────────────────┘
                  │
                  ▼
                 ObServer::start()
                  │
       ┌──────────┼────────────────┐
       ▼          ▼                ▼
  网络监听启动   多租户启动      PX 工作线程
  (第 9篇)      (第 7篇)        (第 21篇)
       │          │                │
       ▼          ▼                ▼
  心跳注册     Schema 同步    自动增量服务
  (第 27篇)    (第 18篇)      (第 24篇)
       │          │
       ▼          ▼
  配置热更新     SQL 诊断服务
  (第 25篇)     (第 29篇)
```

---

## 10. 设计决策

### 10.1 为什么是单体进程？

OceanBase 采用**单进程多线程**架构（类似 PostgreSQL，而非 MySQL 的多进程），原因：

1. **内存池统一管理**：OceanBase 使用全局 `ObMallocAllocator` + `ObTenantMutilAllocatorMgr` 管理所有租户的内存。单进程内所有内存共享一个地址空间，租户间内存隔离通过 `ObTenantMemLimitGetter` 实现。
2. **零拷贝 RPC**：RPC 请求读写直接在共享内存缓冲区中完成，进程间需要序列化/反序列化。
3. **线程级租户隔离**：`ObMultiTenant` 管理租户线程组，每个 CPU 核心可以被分配给特定租户，靠线程池隔离而非进程隔离。

### 10.2 启动顺序的依赖关系

初始化顺序严格遵守**依赖倒置**原则：

```
服务 A 需要服务 B → B 必须在 A 之前初始化

例:
- 日志初始化(最早) → 任何需要打日志的服务
- 配置加载(最早)   → 所有依赖配置的服务
- 网络框架(中期)   → 所有需要 RPC 的服务
- Schema(中期)     → RootService / LocationService
- 存储引擎(中后期) → 事务系统 / SQL 引擎
- 多租户(较晚)     → 依赖之前的全部基础设施
```

任何顺序错误会导致链式调用中的指针为 null 或模块未就绪。

### 10.3 热升级支持

`startup_accel_handler_` 的设计值得一提——它在启动阶段提供并行加速，但在服务正式就绪前自动销毁（行 1216）。这避免了热升级场景下的资源浪费：

1. 旧进程优雅退出 → `ObServer::stop()` + `destroy()`
2. 新进程启动 → 使用 `startup_accel_handler_` 加速启动
3. 新进程就绪 → 销毁加速处理器，释放线程资源

### 10.4 启动失败的处理

`init()` 和 `start()` 中的错误处理采用统一模式：

```cpp
if (OB_FAIL(ret)) {
  LOG_ERROR("[OBSERVER_NOTICE] fail to ...");
  raise(SIGKILL);          // 强制终止
  set_stop();              // 标记停止
  destroy();               // 清理已分配资源
}
```

- 任何初始化步骤失败都会触发 `SIGKILL`，不会尝试恢复
- 在 `start()` 中，失败会调用 `set_stop()` + `wait()` 进行**优雅停机**
- `LOG_DBA_FORCE_PRINT` 确保失败信息即使在高负载下也能写入日志

---

## 11. 源码索引

### 11.1 入口

| 文件 | 关键函数 | 行号 | 说明 |
|------|---------|------|------|
| `src/observer/main.cpp` | `main()` | 688-708 | 进程入口，分配 16MB 栈，调用 `inner_main` |
| `src/observer/main.cpp` | `inner_main()` | 503-687 | 实际启动流程：env → init → start → wait → destroy |
| `src/observer/main.cpp` | `parse_opts()` | 387-410 | 命令行参数解析 |
| `src/observer/main.cpp` | `print_help()` | 63-83 | 参数帮助信息 |
| `src/observer/main.cpp` | `print_version()` | 85-106 | 版本打印 |
| `src/observer/main.cpp` | `check_uid_before_start()` | 441-460 | 检查启动用户与目录所有者是否一致 |
| `src/observer/main.cpp` | `print_all_limits()` | 426-439 | 打印系统资源限制 |
| `src/observer/main.cpp` | `print_all_thread()` | 461-501 | 打印所有线程名（停机诊断用） |

### 11.2 ObServer 类

| 文件 | 关键函数 | 行号 | 说明 |
|------|---------|------|------|
| `src/observer/ob_server.h` | `ObServer` 类定义 | 111-380 | 单例主类，聚合所有核心模块 |
| `src/observer/ob_server.h` | `ObServer::get_instance()` | 382-385 | C++11 线程安全单例 |
| `src/observer/ob_server.cpp` | `ObServer::init()` | 237-605 | 初始化所有模块（约 80+ 步骤） |
| `src/observer/ob_server.cpp` | `ObServer::start()` | 951-1190 | 启动所有服务线程 |
| `src/observer/ob_server.cpp` | `ObServer::wait()` | 1803-2037+ | 等待 stop 信号并执行关机流程 |
| `src/observer/ob_server.cpp` | `ObServer::set_stop()` | 1831-1837 | 设置停止标志，反转状态机 |
| `src/observer/ob_server.cpp` | `ObServer::stop()` | 1841-1997 | 逆序停止所有子系统（~50 步） |
| `src/observer/ob_server.cpp` | `ObServer::destroy()` | 607-893 | 逆序销毁所有子系统 |

### 11.3 初始化子函数

| 文件 | 函数 | 行号 | 说明 |
|------|------|------|------|
| `ob_server.cpp` | `init_config()` | 2121-2169 | 加载配置文件 + OS 参数检查 + 自地址 |
| `ob_server.cpp` | `init_opts_config()` | 2172-2275 | 命令行参数覆盖配置文件 |
| `ob_server.cpp` | `init_global_context()` | 3095-3123 | gctx_ 所有指针赋值 |
| `ob_server.cpp` | `init_network()` | 2778-2849 | 网络框架初始化（创建 Proxy） |
| `ob_server.cpp` | `init_schema()` | 2850-2860 | Schema 服务初始化 |
| `ob_server.cpp` | `init_root_service()` | 2921-2943 | RootService 初始化 |
| `ob_server.cpp` | `init_multi_tenant()` | 2850-2870 | 多租户框架初始化 |
| `ob_server.cpp` | `init_sql()` | 2945-3020 | SQL 引擎初始化 |
| `ob_server.cpp` | `init_storage()` | — | 存储引擎初始化 |
| `ob_server.cpp` | `init_px_target_mgr()` | 3145-3155 | PX 目标管理器 |

### 11.4 启动阶段检查

| 文件 | 函数 | 行号 | 说明 |
|------|------|------|------|
| `ob_server.cpp` | `check_if_multi_tenant_synced()` | 1287-1312 | 等待多租户同步（1s 轮询） |
| `ob_server.cpp` | `check_if_schema_ready()` | 1365-1386 | 等待 Schema 就绪 |
| `ob_server.cpp` | `check_if_timezone_usable()` | 1388-1408 | 等待时区可用 |
| `ob_server.cpp` | `check_user_tenant_schema_refreshed()` | — | 等待用户租户 Schema 刷新（15min 超时） |
| `ob_server.cpp` | `check_log_replay_over()` | — | 等待 CLOG 重放完成（15min 超时） |
| `ob_server.cpp` | `try_update_hidden_sys()` | 1238-1268 | 创建/更新隐藏 SYS 租户 |

### 11.5 心跳 & 集群注册

| 文件 | 关键类/函数 | 行号 | 说明 |
|------|------------|------|------|
| `src/observer/ob_heartbeat.h` | `ObHeartBeatProcess` | 39-133 | 心跳处理核心类 |
| `src/observer/ob_heartbeat.h` | `ObZoneLeaseInfoUpdateTask` | 86-92 | 定时更新租约信息 |
| `src/observer/ob_heartbeat.h` | `ObServerIdPersistTask` | 94-101 | 持久化 Server ID |
| `src/observer/ob_heartbeat.h` | `init_lease_request()` | — | 构造心跳请求 |
| `src/observer/ob_heartbeat.h` | `do_heartbeat_event()` | — | 处理心跳响应 |
| `src/observer/ob_heartbeat.h` | `try_reload_config()` | — | 心跳驱动的配置热更新 |
| `src/observer/ob_heartbeat.h` | `update_lease_info()` | — | 更新租约信息 |

### 11.6 OS 参数检查 & 加速处理器

| 文件 | 关键类/函数 | 行号 | 说明 |
|------|------------|------|------|
| `src/observer/ob_check_params.h` | `CheckAllParams` | 27-65 | OS 参数检查器（9 项检查） |
| `src/observer/ob_check_params.h` | `check_os_params()` | 61 | 启动时调用的统一入口 |
| `src/observer/ob_startup_accel_task_handler.h` | `ObStartupAccelTaskHandler` | 40-73 | 启动加速任务处理器 |
| `src/observer/ob_startup_accel_task_handler.h` | `ObStartupAccelTask` | 31-39 | 启动加速任务基类 |
| `src/observer/ob_startup_accel_task_handler.h` | `ObStartupAccelType` | 40-43 | 加速类型（SERVER/TENANT） |

---

## 12. 终章：全景回顾

30 篇文章至此完成了一次对 OceanBase CE 源码的完整纵向遍历。回顾每一层的核心主题：

```
┌────────────────────────────────────────────────────────┐
│                  业务层                                  │
│  SQL 诊断 (29)  SQL Parser (23)  Optimizer (17)       │
│  PX 并行 (21)   Plan Cache (22)  SQL Executor (9)     │
│  类型系统 (24)   编码引擎 (26)                          │
├────────────────────────────────────────────────────────┤
│                  存储引擎                                │
│  SSTable (8)  Memtable (6/14)  Freezer (6)            │
│  MVCC (1/2/3/4/5)  KeyBtree (15)  Conflict (16)      │
│  DDL 索引 (18)  数据压缩 (26)                          │
├────────────────────────────────────────────────────────┤
│                  分布式共识                              │
│  PALF (11)  Election (12)  CLog (13)  2PC (10)        │
│  LS/Tablet (7)  分区迁移 (19)  备份恢复 (20)           │
├────────────────────────────────────────────────────────┤
│                  集群控制                                │
│  RootServer (27)  GTS (28)  服务注册 (30)              │
│  Schema 同步 (18)  配置管理 (25)                        │
├────────────────────────────────────────────────────────┤
│                  基础设施                                │
│  内存管理 (25)  线程池 (30)  信号处理 (30)              │
│  网络框架 (30)  日志系统 (30)  Observer (30 ← 本文)    │
│  启动 → 初始化 → 服务 → 停止 → 销毁                    │
└────────────────────────────────────────────────────────┘
```

从最底层的 MVCC 行结构到最顶层的 SQL 诊断，从单机 Memtable 到分布式 PALF 共识，从类型系统到 PX 并行执行——**OBServer 启动流程是整个系统的骨架**，把所有这些子系统按照严格的依赖顺序串联起来。理解启动流程 = 理解整个系统的架构图谱。

---

*本文基于 OceanBase CE 主线源码分析，doom-lsp 用于符号解析和结构确认。所有行号以源码对应 commit 为准。*
