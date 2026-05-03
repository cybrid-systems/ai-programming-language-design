# 27 — RootServer 架构 — 元数据管理与集群协调

> 基于 OceanBase CE 主线源码
> 分析入口：`src/rootserver/` — 200+ 文件，数十万行代码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

RootServer 是 OceanBase 分布式集群的**管控核心**。如果把 Observer 存储节点比作分布式数据库的"手脚"，RootServer 就是"大脑"——它不参与用户数据的存储和查询，但负责集群内一切元数据的集中管理和全局调度决策。

### RootServer 在集群中的角色

```
┌────────────────────────────────────────────────────────────────┐
│                     RootServer (控制面)                         │
│                                                                │
│  ┌─────────────────────────────────────────────────────┐       │
│  │  ObRootService (主入口)                               │       │
│  │  ├── 元数据管理 → 内部表、Schema、Locality             │       │
│  │  ├── 资源管理 → ObUnitManager (Unit/Pool)            │       │
│  │  ├── 分区调度 → ObRootBalancer + ObServerBalancer    │       │
│  │  ├── Freeze管理 → ObMajorFreezeService               │       │
│  │  ├── 服务器管理 → ObServerManager (心跳/上下线)       │       │
│  │  ├── DDL调度 → ObDDLService / ObTenantDDLService     │       │
│  │  └── Zone管理 → ObZoneManager                        │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                │
└──────────────────────────┬─────────────────────────────────────┘
                           │ RPC 接口
                           ▼
┌────────────────────────────────────────────────────────────────┐
│                    Observer 节点 (数据面)                       │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐         │
│  │ server_1 │ │ server_2 │ │ server_3 │ │ server_N │ ...     │
│  │ Unit A   │ │ Unit B   │ │ Unit C   │ │ Unit D   │         │
│  │ LS-1     │ │ LS-2     │ │ LS-1     │ │ LS-3     │         │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘         │
└────────────────────────────────────────────────────────────────┘
```

> **关键事实**：RootServer 不是独立二进制文件，而是一个**角色的概念**。在 4.x 架构中，RootService 运行在 _sys 租户内，任何一台配置了 RS 角色的 Observer 都可以成为 RootServer。

### 核心源码组织结构

```
src/rootserver/
├── ob_root_service.h/cpp        ← RootService 主入口
├── ob_unit_manager.h/cpp        ← Unit(资源单元)管理
├── ob_unit_placement_strategy.h ← Unit 放置策略(点积贪心)
├── ob_server_manager.h/cpp      ← 服务器管理(心跳/上下线)
├── ob_zone_manager.h/cpp        ← Zone 管理
├── ob_root_balancer.h/cpp       ← 负载均衡器(主线程)
├── ob_server_balancer.h/cpp     ← 服务器级均衡(Unit迁移)
├── ob_ddl_service.h/cpp         ← DDL 服务
├── ob_tenant_ddl_service.h/cpp  ← 租户级 DDL 服务
├── ob_freeze_info_manager.h     ← Freeze 信息管理(已移至share/)
├── freeze/                      ← Freeze 模块(叶子目录)
│   ├── ob_major_freeze_service.h/cpp    ← Major Freeze 服务
│   ├── ob_tenant_major_freeze.h/cpp     ← 租户级 Major Freeze
│   ├── ob_major_merge_scheduler.h/cpp   ← Major Merge 调度器
│   ├── ob_daily_major_freeze_launcher.h ← 每日 Freeze 启动器
│   ├── ob_zone_merge_manager.h/cpp      ← Zone 级 Merge 管理
│   └── ob_major_merge_info_manager.h    ← Merge 进度信息管理
├── balance/                     ← 均衡组信息
│   ├── ob_balance_group_info.h/cpp
│   ├── ob_ls_balance_group_info.h/cpp
│   └── ob_tenant_ls_balance_group_info.h/cpp
├── ddl_task/                    ← DDL 任务队列
├── backup/                      ← 备份恢复
└── restore/                     ← 恢复调度
```

---

## 1. ObRootService — RootServer 主入口

### 1.1 类概述

`ObRootService`（`ob_root_service.h:72`）是整个 RootServer 的**门面类**。它聚合了所有子管理器、RPC 代理、任务队列，并向 Observer 和其他组件提供统一的 RPC 入口。

```cpp
// ob_root_service.h:72
class ObRootService
{
public:
  ObRootService();
  virtual ~ObRootService();

  int init(common::ObServerConfig &config, common::ObConfigManager &config_mgr,
           obrpc::ObSrvRpcProxy &rpc_proxy, obrpc::ObCommonRpcProxy &common_proxy,
           common::ObAddr &self, common::ObMySQLProxy &sql_proxy,
           observer::ObRestoreCtx &restore_ctx,
           share::ObRsMgr &rs_mgr, share::schema::ObMultiVersionSchemaService *schema_mgr_,
           share::ObLSTableOperator &lst_operator_);

  virtual int start_service();
  virtual int stop_service();
  virtual bool in_service() const;
  // ...
};
```

`init()` 接入了配置、SQL 代理、Schema 服务、LS 表操作器等基础设施，并从中初始化全部子管理器。

### 1.2 内部子管理器一览

```cpp
// ob_root_service.h 成员变量 (line ~1023-1095)
private:
  // --- 状态 ---
  ObRsStatus rs_status_;                    // RS 生命周期状态
  int64_t fail_count_;                      // 启动失败计数
  bool inited_;
  bool debug_;

  // --- 基础设施 ---
  common::ObServerConfig *config_;
  common::ObConfigManager *config_mgr_;
  obrpc::ObSrvRpcProxy rpc_proxy_;
  obrpc::ObCommonRpcProxy common_proxy_;
  common::ObMySQLProxy sql_proxy_;
  share::ObRsMgr *rs_mgr_;

  // --- 核心子管理器 ---
  ObServerManager server_manager_;          // 服务器管理（心跳/上下线）
  ObZoneManager zone_manager_;              // Zone 管理
  ObUnitManager unit_manager_;              // Unit/Pool 管理
  ObRootBalancer root_balancer_;            // 负载均衡
  ObDDLService ddl_service_;                // DDL 处理
  ObTenantDDLService tenant_ddl_service_;   // 租户 DDL
  ObRootMinorFreeze root_minor_freeze_;     // Minor Freeze

  // --- 检查器/任务 ---
  ObEmptyServerChecker empty_server_checker_;
  ObLostReplicaChecker lost_replica_checker_;
  ObHeartbeatChecker hb_checker_;
  ObAllServerChecker server_checker_;

  // --- 任务队列 ---
  common::ObWorkQueue task_queue_;          // 异步任务主队列
  ObRestartTask restart_task_;
  ObRefreshServerTask refresh_server_task_;
  ObInspector inspector_task_;
};
```

### 1.3 生命周期管理

`ObRootService` 的**状态机**通过 `ObRsStatus`（`ob_root_service.h:63`）管理：

```
INIT ──→ start_service()
           ├── load_all_sys_package()
           ├── init_sys_admin_ctx()
           ├── start_timer_tasks()  ← 启动定时任务
           ├── request_heartbeats() ← 请求所有server心跳
           └── 状态 → FULL_SERVICE
               ↓
           run() → 常驻运行
               ↓
           stop_service() → STOPPING
```

`ObRsStatus` 内部维护了一个自旋锁保护的 `ObRootServiceStatus` 枚举：

- `INIT` — 初始化
- `STARTING` — 启动中
- `FULL_SERVICE` — 正常运行
- `STOPPING` — 停止中

### 1.4 任务系统

`ObRootService` 内部定义了大量内嵌任务类（约 20+），全部继承自 `common::ObAsyncTask` 或 `common::ObAsyncTimerTask`，并通过统一的 `task_queue_` 执行：

| 任务类 | 用途 |
|--------|------|
| `ObStartStopServerTask` | 启停服务器 |
| `ObOfflineServerTask` | 将服务器下线 |
| `ObRefreshServerTask` | 周期性刷新服务器状态（1秒间隔） |
| `ObRestartTask` | RS 重启逻辑 |
| `ObReloadUnitManagerTask` | 重载 Unit 信息 |
| `ObSelfCheckTask` | 自检 |
| `ObPurgeRecyclebinTask` | 清理回收站 |
| `ObUpdateAllServerConfigTask` | 广播配置变更（10分钟间隔） |
| `ObMinorFreezeTask` | 触发 Minor Freeze |

### 1.5 RPC 接口矩阵

`ObRootService` 公开了成百个 RPC handler 方法。按功能域分组：

- **DDL**（约 50+）：`create_table`/`drop_table`/`alter_table`/`create_index`/`create_tenant`...
- **服务器**：`add_server`/`delete_server`/`start_server`/`stop_server`
- **Zone**：`add_zone`/`delete_zone`/`start_zone`/`stop_zone`/`alter_zone`
- **管理命令**：`admin_migrate_replica`/`admin_merge`/`admin_drop_replica`/`admin_switch_replica_role`
- **资源**：`create_resource_unit`/`alter_resource_unit`/`create_resource_pool`
- **Freeze**：`root_minor_freeze`/`merge_finish`
- **备份恢复**：`physical_restore_tenant`/`handle_backup_database`

---

## 2. ObUnitManager — 资源管理与隔离

### 2.1 三层资源模型

OceanBase 的**资源管理采用三层抽象**：

```
Resource Unit (unit_config)      ← 描述"多大" (CPU/内存/磁盘)
       ↓
Resource Pool (pool)             ← 描述"在哪" (关联 Unit + Zone)
       ↓
Unit (unit)                      ← 实际分配实例
       ↓
Tenant                           ← 每个租户 = 一组 Unit
```

- **Unit Config**（`ObUnitConfig`）：定义资源规格，如 `unit_config_name = 'S1', cpu = 2, memory_size = '8G'`
- **Resource Pool**（`ObResourcePool`）：关联一个 Unit Config + 一组 Zone，生成若干 Unit
- **Unit**（`ObUnit`）：实际驻留在某台 Server 上的资源切片

### 2.2 ObUnitManager 主类

```cpp
// ob_unit_manager.h:51
class ObUnitManager
{
public:
  ObUnitManager(ObServerManager &server_mgr, ObZoneManager &zone_mgr);

  int init(common::ObMySQLProxy &proxy,
           common::ObServerConfig &server_config,
           obrpc::ObSrvRpcProxy &srv_rpc_proxy,
           share::schema::ObMultiVersionSchemaService &schema_service,
           ObRootBalancer &root_balance,
           ObRootService &root_service);

  virtual int load();     // 从内部表加载 Unit 信息到内存

  // Unit Config 操作
  virtual int create_unit_config(const share::ObUnitConfig &unit_config, ...);
  virtual int drop_unit_config(const share::ObUnitConfigName &name, ...);
  virtual int alter_unit_config(const share::ObUnitConfig &unit_config);

  // Resource Pool 操作
  virtual int create_resource_pool(share::ObResourcePool &pool, ...);
  virtual int alter_resource_pool(...);
  virtual int drop_resource_pool(...);
  virtual int split_resource_pool(...);
  virtual int merge_resource_pool(...);

  // 内部数据结构
  typedef common::hash::ObHashMap<uint64_t, share::ObResourcePool *> IdPoolMap;
  typedef common::hash::ObHashMap<uint64_t, common::ObArray<share::ObResourcePool *> *> TenantPoolsMap;
};
```

### 2.3 ObUnitLoad — 资源需求描述

```cpp
// ob_unit_manager.h:101
struct ObUnitLoad: public ObIServerResourceDemand
{
  share::ObUnit *unit_;               // 实际 Unit
  share::ObUnitConfig *unit_config_;   // 规格配置
  share::ObResourcePool *pool_;        // 所属资源池

  virtual double get_demand(ObResourceType resource_type) const override;
  // RES_CPU / RES_MEM / RES_LOG_DISK / RES_DATA_DISK
};
```

### 2.4 资源类型枚举

```cpp
// ob_root_utils.h:66
enum ObResourceType
{
  RES_CPU = 0,
  RES_MEM = 1,
  RES_LOG_DISK = 2,
  RES_DATA_DISK = 3,
  RES_MAX
};
```

### 2.5 Unit 放置策略 — 点积贪心

`ObUnitPlacementStrategy`（`ob_unit_placement_strategy.h`）定义了 Unit 放置算法。从 V1.4 开始，默认使用**点积贪心向量均衡**（Dot-Product Greedy Vector Balancing）：

```cpp
// ob_unit_placement_strategy.h:63
// New strategy of V1.4
// Dot-Product Greedy Vector Balancing
class ObUnitPlacementDPStrategy: public ObUnitPlacementStrategy
{
public:
  // 选择 max dot-product 的 server
  virtual int choose_server(common::ObArray<ObServerResource> &servers,
                            const share::ObUnitResource &demands_resource,
                            const char *module,
                            common::ObAddr &server) override;
};
```

**算法思想**：将每个 server 的多维资源（CPU/Mem/Disk）建模为向量。新 Unit 需要一定的资源量，选择与其"最匹配"（点积最大）的 server，实现全局负载均衡。

---

## 3. 元数据管理 — 内部表体系

RootServer 的元数据全部存储在 **内部表中**（`__all_*` 表）。这些表是 OceanBase 自身元数据持久化的基石。

### 3.1 核心内部表

| 表名 | 用途 | 操作类 |
|------|------|--------|
| `__all_server` | 集群服务器列表 | `share::ObServerTableOperator` |
| `__all_zone` | Zone 信息 | `ObZoneManager` |
| `__all_unit_config` | Unit Config 规格 | `ObUnitManager` |
| `__all_resource_pool` | 资源池 | `ObUnitManager` |
| `__all_unit` | Unit 实际分配 | `ObUnitManager` |
| `__all_tenant` | 租户信息 | `ObTenantDDLService` |
| `__all_freeze_info` | Freeze 快照信息 | `share::ObFreezeInfoManager` |
| `__all_ls` | 日志流信息 | `share::ObLSTableOperator` |
| `__all_ls_replica` | LS 副本分布 | `share::ObLSTableOperator` |
| `__all_virtual_table` | 系统表元数据 | `share::schema` |

### 3.2 Schema 版本管理

`ObRootService` 通过 `schema_service_`（`ObMultiVersionSchemaService`）管理 Schema 版本。核心机制：

```
DDL 操作
  ↓
ObRootService::create_table() 等
  ↓
ddl_service_.create_table()   ← 持久化 Schema 到内部表
  ↓
schema_service_.refresh()     ← 推进 Schema 版本
  ↓
广播 Schema 到所有 Observer
```

### 3.3 驱动表机制（Core Meta Table）

RootServer 会维护一个 `core_meta_table_version_`（`ob_root_service.h:1085`），用于增量推送元数据变更。Observer 通过心跳获取最新版本号，按需拉取变更。

```
Observer 心跳 → RootServer
  ↓
renew_lease() 中检查 core_meta_table_version_
  ↓
如果版本落后 → 触发广播
  ↓
Observer 拉取增量元数据
```

---

## 4. ObRootBalancer — 负载均衡

### 4.1 主平衡线程

```cpp
// ob_root_balancer.h:53
class ObRootBalancer : public ObRsReentrantThread, public share::ObCheckStopProvider
{
public:
  virtual void run3() override;
  virtual int do_balance();     // 主入口，永不退出
  virtual int all_balance();    // 对所有租户执行平衡

  void stop();
  void wakeup();

  int64_t get_schedule_interval() const;

private:
  ObServerBalancer server_balancer_;     // 服务器级别均衡
  ObRootServiceUtilChecker rootservice_util_checker_;
};
```

`ObRootBalancer` 继承自 `ObRsReentrantThread`，是一个常驻后台的**可重入线程**。`wakeup()` 机制使其在被触发时立即执行一轮平衡，否则按 `get_schedule_interval()` 定期执行。

### 4.2 ObServerBalancer — Unit 迁移调度

```cpp
// ob_server_balancer.h:28
class ObServerBalancer
{
public:
  int balance_servers();    // 主入口
  int build_active_servers_resource_info();  // 收集服务器资源现状
  int tenant_group_balance();

private:
  // 服务器状态变化时的分发策略
  int distribute_for_server_status_change();

  // 按租户粒度分发 Unit
  int distribute_by_tenant(const uint64_t tenant_id,
                           const common::ObArray<share::ObResourcePool *> &pools);

  // 按 Zone 粒度分发
  int distribute_zone_unit(const ObUnitManager::ZoneUnit &zone_unit);

  // 为活跃/永久离线/删除的服务器重新分布
  int distribute_for_active(...);
  int distribute_for_permanent_offline_or_delete(...);
};
```

### 4.3 平衡算法的核心逻辑

```
balance_servers()
├── build_active_servers_resource_info()
│   ├── 遍历所有 alive server
│   │   ├── 读取各 Server 上 Unit 的当前资源使用
│   │   └── 计算每个 Server 的总 capacity 和 assigned
│   └── 生成矩阵：Servers × Resources × Units
│
├── distribute_for_server_status_change()
│   ├── 处理新增 Server → 均衡分布
│   ├── 处理永久离线 → 回收 Unit → 重新分配到其他存活 Server
│   └── 处理迁移阻塞 → 等待
│
├── distribute_by_tenant(tenant_id, pools)
│   ├── 对该租户的所有 Unit
│   │   ├── 计算各 Server 的资源利用率
│   │   └── 从高负载 Server 迁移 Unit 到低负载 Server
│   └── distribute_zone_unit()
│       └── Zone 内均衡（Zone 间不迁移）
│
└── tenant_group_balance()
    └── 跨租户组调度（如读负载隔离）
```

### 4.4 平衡触发器

RootServer 在以下事件发生时唤醒均衡器：

1. **服务器上线/下线** — `ObStatusChangeCallback::wakeup_balancer()`
2. **Unit 变更** — 创建/修改/删除 Unit
3. **Zone 变更** — Zone 启动/停止
4. **定时** — 周期性检查

```cpp
// ob_root_service.h:98
// ObStatusChangeCallback 中相关方法：
virtual int wakeup_balancer() override;
virtual int on_start_server(const common::ObAddr &server) override  // → 触发均衡
virtual int on_stop_server(const common::ObAddr &server) override;
virtual int on_offline_server(const common::ObAddr &server) override;
```

---

## 5. 集群成员管理 — 心跳与上下线

### 5.1 心跳处理

`ObServerManager`（`ob_server_manager.h`）负责处理 Observer 的心跳：

```cpp
// Client(Observer) → Server(RootServer)
// 通过 RPC 定期发送 ObLeaseRequest

int receive_hb(const share::ObLeaseRequest &lease_request,
               uint64_t &server_id,
               bool &to_alive);
```

Heartbeat 的处理流程：

```
Observer 每一秒发送心跳
  ↓
ObServerManager::receive_hb()
  ├── 记录上次心跳时间
  ├── 检查 lease 是否续约
  ├── 更新 server 状态 (alive/dead)
  ├── 检查 core_meta_table_version → 是否需要同步
  └── 返回 ObLeaseResponse（含 RS 列表、配置等）
```

### 5.2 服务器生命周期

```
add_server()
  → server 加入集群，状态为 INACTIVE
  ↓
receive_hb() (第一次合法心跳)
  → server 标记为 ALIVE
  ↓
start_server()
  → server 可被分配 Unit
  ↓
stop_server()
  → server 不再接受新 Unit，已有 Unit 迁出
  ↓
delete_server()
  → 所有 Unit 迁完后，server 从集群移除
  → offline 回调触发 ObOfflineServerTask
```

**重要注释**（`ob_server_manager.h:22`）：
```
// server manager is deprecated, please do not use it!!! USE SVR_TRACER INSTEAD!!!
```

作者特别强调 `ObServerManager` 已被弃用，新代码应该使用 `share::ObIServerTrace` 接口（`share/ob_iserver_trace.h`）。OceanBase 在演进过程中将服务器追踪抽象到 share 层，便于跨模块集成。

### 5.3 服务器状态枚举

```cpp
// share/ob_server_status.h
enum ObServerStatus
{
  OB_SERVER_STATUS_INVALID,   // 无效
  OB_SERVER_STATUS_ACTIVE,    // 运行中
  OB_SERVER_STATUS_INACTIVE,  // 未激活
  OB_SERVER_STATUS_DELETING,  // 正在删除
  OB_SERVER_STATUS_DELETED,   // 已删除
};
```

### 5.4 心跳超时与服务

RootServer 运行 `ObCheckServerTask` 定时检查心跳超时：

```
每个 Observer 1s 一次心跳
  ↓
若 10s（可配置）无心跳
  → 标记为 LEASE_EXPIRED
  → 触发 ObStatusChangeCallback::on_offline_server()
  → ObServerBalancer 开始 Unit 迁出
```

---

## 6. Freeze 管理

Freeze 是 OceanBase 存储引擎的核心运维操作——将内存中的增量数据（MemTable）转化为持久化的 SSTable。RootServer 负责全局协调。

### 6.1 架构设计

```
┌─────────────────────────────────────────────────────┐
│                 ObMajorFreezeService                  │
│  (per 租户，运行在 RootServer 所在 Observer 上)      │
│                                                     │
│  租户 p: ObPrimaryMajorFreezeService  ← 主角色      │
│  租户 r: ObRestoreMajorFreezeService ← 恢复角色     │
│                                                     │
│  委托给:                                           │
│  └── ObTenantMajorFreeze                            │
│       ├── ObMajorMergeInfoManager  (Merge 进度)     │
│       ├── ObMajorMergeInfoDetector (Freeze 检测)    │
│       ├── ObMajorMergeScheduler    (Merge 调度)     │
│       └── ObDailyMajorFreezeLauncher (每日触发)     │
└─────────────────────────────────────────────────────┘
```

### 6.2 ObMajorFreezeService

```cpp
// freeze/ob_major_freeze_service.h:33
class ObMajorFreezeService : public logservice::ObIReplaySubHandler,
                             public logservice::ObICheckpointSubHandler,
                             public logservice::ObIRoleChangeSubHandler
{
public:
  int init(const uint64_t tenant_id);
  int launch_major_freeze(const ObMajorFreezeReason freeze_reason);
  int launch_window_compaction(const ObWindowCompactionParam &param);
  int finish_window_compaction();
  int suspend_merge();
  int resume_merge();
  int clear_merge_error();

  // 角色切换回调
  void switch_to_follower_forcedly();
  int switch_to_leader();
  int switch_to_follower_gracefully();

private:
  ObTenantMajorFreeze *tenant_major_freeze_;  // 真实的 Freeze 逻辑委托
};
```

`ObMajorFreezeService` 实现了三个日志回调接口：
- `ObIReplaySubHandler` — 日志回放
- `ObICheckpointSubHandler` — 检查点
- `ObIRoleChangeSubHandler` — 角色切换

### 6.3 服务类型

```cpp
// freeze/ob_major_freeze_service.h:23
enum ObMajorFreezeServiceType : uint8_t {
  SERVICE_TYPE_INVALID = 0,
  SERVICE_TYPE_PRIMARY = 1,   // 主集群
  SERVICE_TYPE_RESTORE = 2,   // 恢复/备集群
  SERVICE_TYPE_MAX = 3
};
```

对应两个子类：
- `ObPrimaryMajorFreezeService` — 主集群使用，通过 `mtl_init()` 创建
- `ObRestoreMajorFreezeService` — 恢复/备集群使用

### 6.4 ObTenantMajorFreeze

```cpp
// freeze/ob_tenant_major_freeze.h:28
class ObTenantMajorFreeze
{
public:
  int init(const bool is_primary_service,
           common::ObMySQLProxy &sql_proxy,
           common::ObServerConfig &config,
           share::schema::ObMultiVersionSchemaService &schema_service,
           share::ObIServerTrace &server_trace);

  int launch_major_freeze(const ObMajorFreezeReason freeze_reason);
  int launch_window_compaction(const ObWindowCompactionParam &param);
  int suspend_merge();
  int resume_merge();

private:
  int check_before_freeze(bool is_window_compaction);
  int check_freeze_info_and_merge_mode(bool is_window_compaction);
  int set_freeze_info(const ObMajorFreezeReason freeze_reason);
  int try_schedule_minor_before_major_(const bool is_window_compaction);
};
```

### 6.5 Freeze 调度流程

```
launch_major_freeze(freeze_reason)
├── check_before_freeze()
│   ├── check_tenant_status()           ← 租户是否活跃
│   └── check_freeze_info_and_merge_mode() ← 检查上次 Freeze 是否完成
│
├── try_schedule_minor_before_major_()  ← 先触发一次 Minor Freeze
│
├── set_freeze_info(freeze_reason)      ← 写入 __all_freeze_info
│   └── 生成全局 Freeze SCN
│
└── merge_scheduler_.schedule()         ← 通知各 Observer 启动 Merge
    ├── zone → server → LS
    └── 每个 LS 上的 Observer 将 MemTable 冻结，开始 Compaction
```

### 6.6 Freeze 信息管理

```cpp
// share/ob_freeze_info_manager.h:42
class ObFreezeInfoList
{
  // 本地缓存的 Freeze 状态（按 freeze_scn 升序）
  common::ObSEArray<share::ObFreezeInfo, 32> frozen_statuses_;
  // 本地缓存的 snapshot_gc_scn
  share::SCN latest_snapshot_gc_scn_;

  int get_latest_frozen_scn(share::SCN &frozen_scn) const;
  int get_latest_freeze_info(share::ObFreezeInfo &freeze_info) const;
  int get_freeze_info(const share::SCN &frozen_scn, ...) const;
};
```

`ObFreezeInfoManager`（tenant 级别）管理 Freeze 信息和 Snapshot GC SCN。内部表 `__all_freeze_info` 保留最近 32 条记录。

### 6.7 Major Freeze 触发原因

```cpp
enum ObMajorFreezeReason {
  MAJOR_FREEZE_REASON_DAILY,          // 定时每日 Freeze
  MAJOR_FREEZE_REASON_MANUAL,         // 手动触发
  MAJOR_FREEZE_REASON_FORCE,          // 强制 Freeze
  MAJOR_FREEZE_REASON_TRIGGER,        // MemStore 超过阈值触发
  // ...
};
```

---

## 7. Zone 管理

### 7.1 ObZoneManager

`ObZoneManager`（`ob_zone_manager.h`）是 OceanBase 中 Zone 级别元数据的管理者。Zone 是对服务器进行逻辑分组的基本单元，用于实现故障域隔离。

```cpp
// ob_zone_manager.h:46
class ObZoneManagerBase : public share::ObIZoneTrace
{
public:
  int add_zone(const common::ObZone &zone, const common::ObRegion &region,
               const common::ObIDC &idc, const common::ObZoneType &zone_type);
  int delete_zone(const common::ObZone &zone);
  int start_zone(const common::ObZone &zone);
  int stop_zone(const common::ObZone &zone);
  int alter_zone(const obrpc::ObAdminZoneArg &arg);

  int get_zone_count(int64_t &zone_count) const;
  int get_zone(const common::ObZone &zone, share::ObZoneInfo &info) const;
  int get_active_zone(share::ObZoneInfo &info) const;
};
```

每个 Zone 关联：
- `region` — 地理区域（如 `Hangzhou`、`Beijing`）
- `idc` — 数据中心标识
- `zone_type` — Zone 类型（普通、只读日志等）
- `status` — 状态（ACTIVE/INACTIVE）

---

## 8. RootServer 集群架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         OceanBase 集群                             │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    RootServer 节点                            │  │
│  │                    (运行在 _sys 租户)                         │  │
│  │                                                              │  │
│  │  ┌──────────────────────────────────────────────────────┐   │  │
│  │  │  ObRootService                                       │   │  │
│  │  │                                                      │   │  │
│  │  │  用户请求 ──→ RPC Handler ──→ 对应处理函数           │   │  │
│  │  │               ↑                                      │   │  │
│  │  │        ┌──────┴──────────────────────┐               │   │  │
│  │  │        │  ObUnitManager              │               │   │  │
│  │  │        │  ObZoneManager              │               │   │  │
│  │  │        │  ObServerManager            │  ← 心跳 ← ── │   │  │
│  │  │        │  ObRootBalancer             │               │   │  │
│  │  │        │  ObDDLService               │               │   │  │
│  │  │        │  ObMajorFreezeService       │  ← Freeze ←  │   │  │
│  │  │        │  ObLSTableOperator          │               │   │  │
│  │  │        └──────────────┬──────────────┘               │   │  │
│  │  │                       │ 内部表读写                    │   │  │
│  │  │                       ▼                              │   │  │
│  │  │              __all_* 内部表                           │   │  │
│  │  └──────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                     │
│              ┌───────────┬───────────┬───────────┐                 │
│              │           │           │           │                 │
│              ▼           ▼           ▼           ▼                 │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Observer 数据节点集群                                       │  │
│  │                                                              │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐        │  │
│  │  │ svr:1   │  │ svr:2   │  │ svr:3   │  │ svr:4   │        │  │
│  │  │ Zone:z1 │  │ Zone:z1 │  │ Zone:z2 │  │ Zone:z2 │        │  │
│  │  │ Unit:A  │  │ Unit:B  │  │ Unit:C  │  │ Unit:D  │        │  │
│  │  │ LS-1: L │  │ LS-1: F │  │ LS-2: L │  │ LS-2: F │        │  │
│  │  │ LS-3: F │  │          │  │          │  │          │        │  │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘        │  │
│  │                                                              │  │
│  │  每个 Observer:                                              │  │
│  │  - 接收来自 RootServer 的 RPC (DDL / Freeze /迁移)          │  │
│  │  - 每秒发送心跳到 RootServer                                 │  │
│  │  - 执行本地 Merge / Minor Freeze                             │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 9. 设计决策分析

### 9.1 单点 vs 分布式 RootServer

OceanBase 的选择是 **主备式的单点**：

- **一个主 RS**：处理所有写操作（DDL、Freeze 调度、均衡决策）
- **多个备 RS**：接收元数据同步，随时准备接管
- **切换**：基于 Paxos 协议，通过 `ob_admin switch_rs_role` 触发

这个选择的核心原因：**元数据操作的 ACID 需求**。如果元数据操作（如 Schema 变更、Unit 分配）也走分布式共识，复杂度将大大增加，性能也会下降。RootServer 采用"集中控制 + 热备"模式，在简单性和可用性之间取得了平衡。

### 9.2 为什么元数据存储在内部表而非文件系统

OceanBase 将全部元数据存储在 `__all_*` 内部表中，共享 SQL 引擎基础设施。这样做的好处：

1. **CRUD 标准化** — 直接复用 SQL 层的解析、执行、事务能力
2. **高可用** — 内部表数据走 Paxos 同步，RS 故障恢复时元数据不丢失
3. **可查询性** — 用户可以直接查询 `__all_*` 视图获取集群状态
4. **增量同步** — 通过 Schema 版本号实现增量推送，Observer 按需拉取

### 9.3 Unit 调度策略的演进

| 时期 | 策略 | 特点 |
|------|------|------|
| V1.0 | 简单轮询 | 按 Zone 内 server 数量平均分配 |
| V1.4 | 点积贪心 | 考虑多维资源（CPU/Mem/Disk）的向量匹配 |
| V2.x | 加权均衡 | 引入租户级别权重，支持优先级 |
| V4.x | LS 级别均衡 | 从 Unit 粒度细化到 LS 粒度，更精细的控制 |

### 9.4 Freeze 调度的时机选择

RootServer 不直接执行 Compaction——它只负责 **调度**。这种设计的好处是：

```
RootServer 决定 "什么时候" Freeze
Observer 决定 "怎么" Freeze
```

具体做法：
1. RootServer 写入 `__all_freeze_info` 设置冻结版本号
2. 各 Observer 通过心跳感知版本变化
3. Observer 在本地执行 Compaction，完成后汇报
4. RootServer 收集所有 LS 的 Merge 进度，等待全部完成

### 9.5 均衡粒度：从 Unit 到 LS

在 4.x 架构中，OceanBase 引入了日志流（LS，Log Stream）模型。均衡器的工作粒度也从 Unit 级别的服务器间迁移，细化到 LS 级别的分区迁移：

```
平衡粒度演进：
  Partition (V2.x) ──→ Unit       (V3.x) ──→ LS (V4.x)
                       ↑                     ↑
                   整机级别的迁移       LS级别的迁移，更精细
```

Connection to 文章 19（分区迁移）：
- RootServer 使用 `ObServerBalancer::distribute_by_tenant()` 生成迁移计划
- 计划中每个迁移操作对应一个 LS 的副本迁移
- `ob_admin_migrate_replica` 等管理命令最终下发到 Observer 执行

---

## 10. 关键源码索引

| 文件 | 核心类/概念 | 行号 |
|------|-------------|------|
| `ob_root_service.h` | `ObRootService` | 72 |
| `ob_root_service.h` | `ObRsStatus` (RS 状态机) | 63 |
| `ob_root_service.h` | `ObStatusChangeCallback` | 93 |
| `ob_root_service.h` | `ObRefreshServerTask` | 87 |
| `ob_root_service.h` | 成员变量 (子管理器聚合) | 1023-1095 |
| `ob_unit_manager.h` | `ObUnitManager` | 51 |
| `ob_unit_manager.h` | `ObUnitLoad` (资源需求) | 101 |
| `ob_unit_manager.h` | `ObUnitNumCountMap` | 119 |
| `ob_unit_placement_strategy.h` | `ObUnitPlacementDPStrategy` (点积贪心) | 63 |
| `ob_root_utils.h` | `ObResourceType` (枚举) | 66 |
| `ob_root_utils.h` | `ObIServerResource` (资源抽象接口) | 73 |
| `ob_root_utils.h` | `majority(n)` 模板函数 | 55 |
| `ob_root_balancer.h` | `ObRootBalancer` (平衡主线程) | 53 |
| `ob_server_balancer.h` | `ObServerBalancer` (Unit 迁移) | 28 |
| `ob_server_manager.h` | `ObServerManager` (心跳/上下线) | 60 |
| `ob_server_manager.h` | `ObIStatusChangeCallback` | 28 |
| `ob_zone_manager.h` | `ObZoneManagerBase` | 46 |
| `freeze/ob_major_freeze_service.h` | `ObMajorFreezeService` | 33 |
| `freeze/ob_major_freeze_service.h` | `ObMajorFreezeServiceType` (枚举) | 23 |
| `freeze/ob_tenant_major_freeze.h` | `ObTenantMajorFreeze` | 28 |
| `freeze/ob_daily_major_freeze_launcher.h` | 每日 Freeze 启动 | — |
| `share/ob_freeze_info_manager.h` | `ObFreezeInfoList` | 42 |
| `share/ob_server_status.h` | Server 状态枚举 | — |
| `balance/ob_balance_group_info.h` | 均衡组信息 | — |
| `balance/ob_ls_balance_group_info.h` | LS 级均衡组 | — |

---

## 11. 总结

RootServer 是 OceanBase 集群的"大脑"——它不存储用户数据，但控制一切：

- **元数据集中化** — 全部 `__all_*` 内部表，统一、高可用
- **资源三层模型** — Unit Config → Resource Pool → Unit，灵活隔离
- **负载均衡** — 点积贪心算法，Server/Balancer 双重调度
- **Freeze 协调** — 只调度不执行，观察者模式
- **主备式高可用** — 单点写 + 热备 + Paxos 切换

下一篇文章将深入 RootServer 的 DDL 调度引擎，分析异步 DDL 任务的执行流程。
