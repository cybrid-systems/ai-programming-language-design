# 65-standby-cluster — OceanBase Active-Standby 集群架构深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（src/share/ob_cluster_role.h + src/share/ob_tenant_switchover_status.h + src/logservice/restoreservice/ + src/observer/ + src/rootserver/）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OceanBase 4.x / 5.x 强化的 **Active-Standby 集群架构**是 OB 体系内**除 PALF 多副本之外**的另一条 HA 主线。区别于传统"主备库 + binlog 回放"模式（MySQL / PostgreSQL 主流），OB 把 Standby 设计为 **独立的 OB 集群**，通过 `ObLogRestoreService` 持续从 Primary 拉取日志并应用到本地存储，实现：

1. **物理级数据保护** —— Standby 是完整的 OB 集群（不是只读副本）
2. **强一致性读** —— Standby 写入的日志可读（read-after-apply）
3. **快速 switchover** —— 计划内切换，主备角色对调
4. **可量化的保护级别** —— 类似 Oracle Data Guard 的 MAXIMUM_PROTECTION / MAXIMUM_AVAILABILITY / MAXIMUM_PERFORMANCE 三档
5. **flashback 回滚** —— 切换失败可回退到原状态

本文聚焦 7 个核心问题：

1. **Standby 集群是什么角色？** —— `ObClusterRole::STANDBY_CLUSTER`
2. **如何量化保护级别？** —— `ObProtectionMode` / `ObProtectionLevel`
3. **Standby 如何拿到 Primary 的日志？** —— `ObLogRestoreService` 持续拉取
4. **Switchover 状态机怎么走？** —— `ObTenantSwitchoverStatus` 9 状态
5. **Switchover / Failover 流程差异？** —— planned vs unplanned
6. **Flashback 机制怎么回滚？** —— PREPARE_FLASHBACK_xxx 状态路径
7. **Standby 读一致性如何保证？** —— read-after-apply + log replay 同步

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 11-palf | Standby 通过 PALF 接收日志（写入本地 PALF） |
| 13-clog | Primary 的 clog 流被 Standby 的 ObLogRestoreService 消费 |
| 27-rootserver | RS 是 switchover 协调者（per-tenant 角色切换） |
| 30-observer-startup | observer 启动时识别 cluster role 并初始化对应服务 |
| 38-palf-member-change | Standby 是 PALF 的 learn 角色（接收日志但不投票） |
| 49-log-service | ObLogRestoreService 是 LogService 下游的第二个大消费者 |
| 62-cdcservice-logfetcher | restoreservice 是 cdcservice 之外的 archive 复用者 |
| 64-online-ddl | DDL 在 Standby 上的 replay 流程（与 Primary 同步） |

---

## 1. Cluster Role + Protection Mode 基础

### 1.1 ObClusterRole —— 集群角色

```cpp
// src/share/ob_cluster_role.h
enum ObClusterRole
{
  INVALID_CLUSTER_ROLE = 0,
  PRIMARY_CLUSTER = 1,
  STANDBY_CLUSTER = 2,
};

enum ObClusterStatus
{
  INVALID_CLUSTER_STATUS = 0,
  CLUSTER_VALID = 1,
  CLUSTER_DISABLED,
  REGISTERED,
  CLUSTER_DISABLED_WITH_READONLY,
  MAX_CLUSTER_STATUS,
};
```

**关键设计**：
- 一个 OB 进程（observer）有 **cluster role**（PRIMARY / STANDBY）
- cluster role 是 **per-cluster** 配置（不是 per-tenant）
- 同一 cluster 内可能有 **不同 tenant 处于不同 switchover 状态**（见 §5）

### 1.2 ObProtectionMode —— 保护模式

```cpp
// src/share/ob_cluster_role.h
enum ObProtectionMode
{
  INVALID_PROTECTION_MODE = 0,
  MAXIMUM_PERFORMANCE_MODE = 1,    // MP - 异步传输，Standby 可能落后
  MAXIMUM_AVAILABILITY_MODE = 2,   // MA - 同步传输，但允许短暂异步
  MAXIMUM_PROTECTION_MODE = 3,    // MPT - 完全同步，必须双写成功
  PROTECTION_MODE_MAX
};

enum ObProtectionLevel
{
  INVALID_PROTECTION_LEVEL = 0,
  MAXIMUM_PERFORMANCE_LEVEL = 1,
  MAXIMUM_AVAILABILITY_LEVEL = 2,
  MAXIMUM_PROTECTION_LEVEL = 3,
  RESYNCHRONIZATION_LEVEL = 4,        // Standby 重新同步中
  MPF_TO_MPT_LEVEL = 5,              // MP → MPT 中间态
  MPF_TO_MA_MPT_LEVEL = 6,           // MA 中间态
  PROTECTION_LEVEL_MAX
};
```

**三种保护模式**（与 Oracle Data Guard 对齐）：

| 模式 | 行为 | RPO（数据丢失窗口） | 性能影响 |
|------|------|-------------------|----------|
| **MAXIMUM_PERFORMANCE** | 异步传输日志 | 可能丢失 Standby 未收到的数据 | 几乎无影响 |
| **MAXIMUM_AVAILABILITY** | 同步传输但允许短暂异步 | 通常 0，可能丢失 | 小 |
| **MAXIMUM_PROTECTION** | 强同步，必须 Standby 确认 | 0 | 较大（等待 Standby ack） |

### 1.3 同步判断逻辑

```cpp
// src/share/ob_cluster_role.h
// Check primary protectioni level whether need sync-transport clog to standby
// ex. MA, MPT, and other middle level
bool need_sync_to_standby_level(const ObProtectionLevel level);

// Check standby protection level whether only receive sync-transported clog
// ex. MA, MPT, RESYNC
bool is_sync_level_on_standby(const ObProtectionLevel standby_level);

// Whether in steady state.
// Only steady state can change protection mode, switchover and so on.
bool is_steady_protection_level(const ObProtectionLevel level);

// The protection mode which need SYNC mode standby
// MPT or MA mode
bool has_sync_standby_mode(const ObProtectionMode mode);

//Check if the protection level is the MAXIMUM PROTECTION or MAXIMUM AVAILABILITY protection level
bool mpt_or_ma_protection_level(const ObProtectionLevel level);

// Updating mode and level is not atomic, to check whether mode and level can match
bool is_cluster_protection_mode_level_match(const ObProtectionMode mode, const ObProtectionLevel level);
```

**关键设计**：
- `need_sync_to_standby_level`：判断 Primary 当前是否需要同步传输（MA / MPT / 中间态）
- `is_sync_level_on_standby`：判断 Standby 当前是否只接受同步传输（MA / MPT / RESYNC）
- `is_steady_protection_level`：只有稳态才能切换保护模式 / switchover
- `has_sync_standby_mode`：判断该模式是否需要 Standby（MPT / MA 需要，MP 不需要）
- `mpt_or_ma_protection_level`：判断 MPT 或 MA 级别
- `is_cluster_protection_mode_level_match`：mode + level 一致性校验（mode 和 level 不同时更新）

**实务对应**：
- **MA mode + NORMAL level**：正常运行（最大可用）
- **MA mode + RESYNC level**：Standby 落后正在重追
- **MP mode + MPT level**：不允许（mode 是 MP 但 level 是 MPT）—— `is_cluster_protection_mode_level_match` 返回 false

---

## 2. 整体架构：Primary + Standby 双集群拓扑

### 2.1 部署形态

```
┌─────────────────────────────────────────────────────────────┐
│                  Primary Cluster                            │
│                                                             │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐       │
│  │ observer #1 │    │ observer #2 │    │ observer #3 │       │
│  │  (PRIMARY) │    │  (PRIMARY) │    │  (PRIMARY) │       │
│  └─────┬──────┘    └─────┬──────┘    └─────┬──────┘       │
│        │                 │                  │              │
│        ▼                 ▼                  ▼              │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐       │
│  │   RS #1    │    │   RS #2    │    │   RS #3    │       │
│  └────────────┘    └────────────┘    └────────────┘       │
│                                                             │
│  - 接受应用读写                                              │
│  - 日志写入 PALF                                             │
│  - 根据 protection mode 同步/异步推到 Standby                │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          │ ObLogRestoreService
                          │ (同步 or 异步, 按 protection level)
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                  Standby Cluster                            │
│                                                             │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐       │
│  │ observer #4 │    │ observer #5 │    │ observer #6 │       │
│  │  (STANDBY) │    │  (STANDBY) │    │  (STANDBY) │       │
│  └─────┬──────┘    └─────┬──────┘    └─────┬──────┘       │
│        │                 │                  │              │
│        ▼                 ▼                  ▼              │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐       │
│  │   RS #4    │    │   RS #5    │    │   RS #6    │       │
│  │ (只读, 通常 │    │            │    │            │       │
│  │  standby    │    │            │    │            │       │
│  │  模式下)    │    │            │    │            │       │
│  └────────────┘    └────────────┘    └────────────┘       │
│                                                             │
│  - 只接受应用读（默认）                                       │
│  - ObLogRestoreService 持续拉取 Primary 日志                  │
│  - 写入本地 PALF（但允许落后）                                │
│  - 切换后成为 Primary（角色反转）                            │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Standby 的特殊性

Standby 集群与 Primary 集群的差异：

| 维度 | Primary | Standby |
|------|---------|---------|
| 集群角色 | PRIMARY_CLUSTER | STANDBY_CLUSTER |
| 应用读写 | 读写 | **只读**（默认） |
| 日志来源 | 本地应用产生 | **从 Primary 拉取** |
| 日志去向 | 本地 PALF + 推到 Standby | 本地 PALF（被动接收） |
| RS 功能 | 完整（管理 partition / DDL / 切主） | 只读 + 协调切换 |
| PALF 角色 | Leader / Follower | Learner（只接收，不投票） |
| 切换 | 无 | 可被切换为新 Primary |

**关键约束**：Standby 不能直接产生新数据，只能 replay Primary 的日志。这避免了双写冲突。

### 2.3 集群间通信

```
Primary observer ───RPC───► Standby observer (ObLogRestoreService)
    │                            │
    │ clog stream                │ 拉取 clog + redo log
    │ + tenant info              │ + 应用 schema 变更
    │ + partition map            │ + 同步 partition 分布
```

Standby 的 `ObLogRestoreService` 主动拉取 Primary 的日志。Standby 的 RS 主动拉取 Primary 的 RS 元数据（partition map / 集群拓扑）。

---

## 3. ObLogRestoreService —— Standby 的"心跳"

### 3.1 类骨架

```cpp
// src/logservice/restoreservice/ob_log_restore_service.h
// Work in physical restore and physical standby,
// provide the ability to fetch log from remote cluster and backups
class ObLogRestoreService : public share::ObThreadPool
{
  static const int64_t SCHEDULE_INTERVAL = 1000 * 1000L;   // 1s
  static const int64_t UPDATE_RESTORE_UPPER_LIMIT_INTERVAL = 100 * 1000L;  // 100ms
  static const int64_t PRIMARY_THREAD_RUN_INTERVAL = 1000 * 1000L;   // 1s
  static const int64_t STANDBY_THREAD_RUN_INTERVAL = 10 * 1000L;  // 10ms
  static const int64_t SCHEDULE_FETCH_LOG_INTERVAL = 1 * STANDBY_THREAD_RUN_INTERVAL; // 10ms
  static const int64_t UPDATE_UPSTREAM_INTERVAL = 10 * STANDBY_THREAD_RUN_INTERVAL; // 100ms
  static const int64_t COMMON_EVENT_SCHEDULE_INTERVAL = 10 * STANDBY_THREAD_RUN_INTERVAL; // 100ms

public:
  ObLogRestoreService();
  ~ObLogRestoreService();

public:
  ObLogResSvrRpc *get_log_restore_proxy() { return &proxy_; }

public:
  int init(rpc::frame::ObReqTransport *transport,
           ObLSService *ls_svr,
           ObLogService *log_service);
  void destroy();
  int start();
  int restart();
  void stop();
  void wait();
  void signal();
  ObLogRestoreAllocator *get_log_restore_allocator() { return &allocator_;}

private:
  void run1();
  void do_thread_task_();
  int update_upstream_(share::ObLogRestoreSourceItem &source, bool &source_exist);
  void schedule_fetch_log_(share::ObLogRestoreSourceItem &source);
  void schedule_resource_(const share::ObLogRestoreSourceType &source_type);
  void clean_resource_();
  void report_error_();
  void update_restore_upper_limit_();
  void set_compressor_type_();
  void refresh_error_context_();
  void reset_restore_source_();
  bool reach_time_interval_(const int64_t current_ts, const int64_t time_interval, int64_t &time_us);

private:
  bool inited_;
  ObLSService *ls_svr_;
  ObLogResSvrRpc proxy_;                              // 接收 RPC（作为 server 端）
  ObRemoteLocationAdaptor location_adaptor_;          // 上游位置感知
  ObLogRestoreArchiveDriver archive_driver_;          // 归档驱动
  ObLogRestoreNetDriver net_driver_;                  // 网络驱动（实时同步）
  ObRemoteFetchLogImpl fetch_log_impl_;               // fetch 实现
  ObRemoteFetchWorker fetch_log_worker_;              // fetch worker
  ObRemoteLogWriter writer_;                          // 写入本地 PALF
  ObRemoteErrorReporter error_reporter_;              // 错误上报
  ObLogRestoreSourceItem restore_source_;             // 上游来源
  int64_t query_restore_source_ts_;
  int64_t schedule_fetch_log_ts_;
  int64_t common_event_schedule_ts_;
  ObLogRestoreAllocator allocator_;                   // restore 专用内存池
  ObLogRestoreScheduler scheduler_;                   // 调度器
  common::ObCond cond_;
  common::ObSpinLock lock_;
  rpc::frame::ObReqTransport *init_transport_;
  ObLSService *init_ls_svr_;
  ObLogService *init_log_service_;
};
```

### 3.2 设计动机与角色

`ObLogRestoreService` 是 Standby observer 进程内的 **持续拉取线程池**：

- **PRIMARY_THREAD_RUN_INTERVAL = 1s**：作为 Primary 模式下的循环间隔（虽然 Standby 是反向的，但代码复用）
- **STANDBY_THREAD_RUN_INTERVAL = 10ms**：作为 Standby 模式下的循环间隔（更频繁拉取）
- **SCHEDULE_FETCH_LOG_INTERVAL = 10ms**：调度 fetch log 任务
- **UPDATE_UPSTREAM_INTERVAL = 100ms**：周期更新上游信息（Primary 列表变化时感知）

Standby 的拉取频率比 Primary 的 loop 高 100 倍（10ms vs 1s），是因为 Standby 需要尽快追上 Primary 的日志进度。

### 3.3 核心组件协作

```
┌─ ObRemoteLocationAdaptor ─┐
│ 追踪 Primary RS / observer 列表 │
└─────────┬──────────────────┘
          │ 上游位置
          ▼
┌─ ObLogRestoreSourceItem ─┐
│ 当前 restore 来源 (archive / net) │
└─────────┬──────────────────┘
          │
          ▼
┌─ 选择驱动 ─┐
│  - archive: ObLogRestoreArchiveDriver │
│  - net: ObLogRestoreNetDriver          │
└─────────┬──────────────────────────────┘
          │
          ▼
┌─ ObRemoteFetchLogImpl / ObRemoteFetchWorker ─┐
│ 实际拉取 (RPC 调用 + 异步任务)              │
└─────────┬──────────────────────────────────────┘
          │ 拉到的日志
          ▼
┌─ ObRemoteLogWriter ─┐
│ 写入本地 PALF (replay) │
└────────────────────────┘
          │
          ▼
   本地 observer 的存储层（memtable + SSTable）
```

### 3.4 与 #62 cdcservice 的关系

`ObLogRestoreService` 与 `ObCdcService` 都是 LogService 下游消费者，但定位不同：

| 维度 | ObCdcService | ObLogRestoreService |
|------|--------------|---------------------|
| 角色 | CDC 服务端（暴露给外部 CDC 客户端） | Standby 拉取（observer 内部） |
| 输入 | PALF（本地）+ archive | 远端 Primary + archive |
| 输出 | binlog row event (给 Canal / DTS) | 本地 PALF（喂本地存储） |
| 协议 | obrpc fetch_log | obrpc 远端 fetch + 本地 replay |
| 触发 | 客户端 RPC 请求 | 持续 background thread |

**共享部分**：两者都依赖 `ObLogExternalStorageHandler`（见 #62 §1.1）做 archive piece 读取，所以 archive 路径逻辑只实现一次。

---

## 4. Archive driver vs Net driver —— 冷启动 vs 热复制

### 4.1 双源设计

```cpp
// src/logservice/restoreservice/ob_log_restore_service.h
private:
  ObLogRestoreArchiveDriver archive_driver_;          // 归档驱动
  ObLogRestoreNetDriver net_driver_;                  // 网络驱动
```

**两种数据源**：
- **archive**：从 Primary 的归档目录（OSS / NFS / S3 等）拉历史日志 —— 用于 Standby 冷启动追上 Primary
- **net**：从 Primary 的 observer 实时拉取（RPC）—— 用于 Standby 热复制持续追赶

### 4.2 拉取策略

Standby 启动后行为：

```
T0: Standby 启动
    │
    ├─ 知道 Primary 的最大 LSN = X
    │  知道 Standby 当前的 LSN = 0 (全新)
    │
    ▼
T0+1s: 发现差距太大 (X - 0 > threshold)
    │
    ▼
T0+2s: 切到 archive 模式
    │  从 Primary 归档目录拉历史日志
    │
    ▼
T1: Standby 追上 (Standby LSN ≈ X - small_gap)
    │
    ▼
T1+1s: 切到 net 模式
       从 Primary observer RPC 实时拉
       │
       ▼
T1+: 持续 net 模式（直到切换 / 故障）
```

### 4.3 ObLogRestoreArchiveDriver（archive driver）

```cpp
// src/logservice/restoreservice/ob_log_restore_archive_driver.h (key methods)
class ObLogRestoreArchiveDriver : public ObLogRestoreDriverBase
{
public:
  // 从 archive piece 读取日志
  int read_log_from_archive(const share::ObLSID &ls_id,
                            const palf::LSN &start_lsn,
                            palf::LogGroupEntry &entry,
                            int64_t &read_size);

  // 列出可用的 archive piece
  int list_pieces(const share::ObLSID &ls_id,
                  common::ObIArray<share::ObArchivePiece> &pieces);
};
```

`ob_log_archive_piece_mgr.cpp` (2344 行) 是核心实现，管理 archive piece 的元数据 + 实际读取。

### 4.4 ObLogRestoreNetDriver（net driver）

```cpp
// src/logservice/restoreservice/ob_log_restore_net_driver.h (key methods)
class ObLogRestoreNetDriver : public ObLogRestoreDriverBase
{
public:
  // 通过 RPC 从 Primary observer 拉取
  int fetch_log_from_net(const share::ObLSID &ls_id,
                          const palf::LSN &start_lsn,
                          palf::LogGroupEntry &entry,
                          int64_t &read_size);

  // 处理 Primary 切换 / 故障
  int handle_upstream_change();
};
```

`ob_log_restore_net_driver.cpp` (696 行) 处理 RPC 调用 + 重试 + 上游切换。

### 4.5 切换决策：archive → net

`ObLogRestoreService::do_thread_task_` 中根据 **剩余差距** 决定切换：

```cpp
// (伪代码 / 架构描述)
if (source_type == ARCHIVE) {
  // archive 拉到 Standby LSN = X
  if (primary_max_lsn - standby_lsn < threshold) {
    // 切换到 net 模式
    source_type = NET;
    reset_restore_source_();
  }
}
```

---

## 5. ObTenantSwitchoverStatus —— 9 状态机

### 5.1 完整 9 状态

```cpp
// src/share/ob_tenant_switchover_status.h
enum Status
{
  INVALID_STATUS = 0,
  NORMAL_STATUS = 1,                                  // 正常运行
  SWITCHING_TO_PRIMARY_STATUS = 2,                    // 正在切换到 Primary
  PREPARE_FLASHBACK_FOR_FAILOVER_TO_PRIMARY_STATUS = 3, // 准备 flashback 用于 failover→primary
  FLASHBACK_STATUS = 4,                               // 正在 flashback
  PREPARE_SWITCHING_TO_STANDBY_STATUS = 5,            // 准备切换到 Standby
  SWITCHING_TO_STANDBY_STATUS = 6,                    // 正在切换到 Standby
  PREPARE_FLASHBACK_FOR_SWITCH_TO_PRIMARY_STATUS = 7, // 准备 flashback 用于 switchover→primary
  FLASHBACK_AND_STAY_STANDBY_STATUS = 8,              // flashback 后保持 Standby
  PREPARE_FLASHBACK_FOR_LOSSLESS_FAILOVER_TO_PRIMARY_STATUS = 9, // 准备 losseless failover
  MAX_STATUS = 10
};
```

### 5.2 状态机图

```
                        ┌──────────────────────────────┐
                        │                              │
   NORMAL (Primary)    │   NORMAL (Standby)            │
   ALTER SYSTEM         │   ALTER SYSTEM               │
   SWITCHOVER           │   SWITCHOVER                  │
        │               │        │                     │
        ▼               │        ▼                     │
   PREPARE_SWITCHING_   │   PREPARE_SWITCHING_         │
   TO_STANDBY           │   TO_PRIMARY                 │
        │               │        │                     │
        ▼               │        ▼                     │
   SWITCHING_TO_        │   SWITCHING_TO_              │
   STANDBY              │   PRIMARY                    │
        │               │        │                     │
        ├─ success ─────┼──►     │                     │
        │               │        │                     │
        │  failure      │        │  failure             │
        │               │        │                     │
        ▼               │        ▼                     │
   PREPARE_FLASHBACK_   │   PREPARE_FLASHBACK_FOR_     │
   FOR_SWITCH_TO_       │   FAILOVER_TO_PRIMARY        │
   PRIMARY              │                               │
        │               │        │                     │
        ▼               │        ▼                     │
   FLASHBACK_           │   FLASHBACK                  │
   AND_STAY_STANDBY     │        │                     │
        │               │        │                     │
        └───────────────┴────────┘                     │
                                                       │
   故障恢复路径:                                        │
   PREPARE_FLASHBACK_FOR_LOSSLESS_FAILOVER_            │
   TO_PRIMARY (Standby 失败时)                          │
                                                       │
                        └──────────────────────────────┘
```

### 5.3 关键状态转换语义

| 转换 | 触发 | 行为 |
|------|------|------|
| NORMAL → PREPARE_SWITCHING_TO_STANDBY | ALTER SYSTEM SWITCHOVER（Primary 端） | 通知所有租户准备切换 |
| PREPARE_SWITCHING_TO_STANDBY → SWITCHING_TO_STANDBY | RS 协调完成 | 停写 → replay drain → 角色对调 |
| SWITCHING_TO_STANDBY → NORMAL (Standby) | 切换成功 | Standby 接管应用读写 |
| 任何中间态 → PREPARE_FLASHBACK_FOR_SWITCH_TO_PRIMARY | 切换失败 | 准备回滚到原 Primary 状态 |
| → FLASHBACK | flashback 准备完成 | 把 Standby 状态回滚到切换前 |
| → FLASHBACK_AND_STAY_STANDBY | flashback 完成 | 仍然保持 Standby 角色 |

### 5.4 状态判断辅助函数

```cpp
// src/share/ob_tenant_switchover_status.h
#define IS_TENANT_STATUS(TENANT_STATUS, STATUS) \
  bool is_##STATUS##_status() const { return TENANT_STATUS == value_; };

IS_TENANT_STATUS(NORMAL_STATUS, normal)
IS_TENANT_STATUS(SWITCHING_TO_PRIMARY_STATUS, switching_to_primary)
IS_TENANT_STATUS(PREPARE_FLASHBACK_FOR_FAILOVER_TO_PRIMARY_STATUS, prepare_flashback_for_failover_to_primary)
IS_TENANT_STATUS(FLASHBACK_STATUS, flashback)
IS_TENANT_STATUS(PREPARE_SWITCHING_TO_STANDBY_STATUS, prepare_switching_to_standby)
IS_TENANT_STATUS(SWITCHING_TO_STANDBY_STATUS, switching_to_standby)
IS_TENANT_STATUS(PREPARE_FLASHBACK_FOR_SWITCH_TO_PRIMARY_STATUS, prepare_flashback_for_switch_to_primary)
IS_TENANT_STATUS(FLASHBACK_AND_STAY_STANDBY_STATUS, flashback_and_stay_standby)
#undef IS_TENANT_STATUS

bool is_general_flashback_status() const {
  return is_flashback_status() ||  is_flashback_and_stay_standby_status();
}
```

**设计模式**：用宏生成 `is_X_status()` 谓词函数，避免重复代码。`is_general_flashback_status()` 组合两个 flashback 状态用于上层判断"是否处于 flashback 中"。

---

## 6. Switchover 流程（planned）

### 6.1 触发

```sql
ALTER SYSTEM SWITCHOVER TO STANDBY TENANT = tenant_name;
```

或等价 RPC：`ObAdminSwitchoverTenantArg`（在 `ob_service.h` 等 RPC 入口）。

### 6.2 Switchover 步骤

```
Phase 1: 校验 (PREPARE)
    │
    ├─ Primary RS: 校验当前是否稳态（is_steady_protection_level）
    ├─ Primary RS: 通知所有租户准备切换
    │   └─ 状态: NORMAL → PREPARE_SWITCHING_TO_STANDBY
    │
    ▼
Phase 2: 停写 (SWITCHING)
    │
    ├─ Primary RS: stop_partition_write(switchover_timestamp)
    │   → 所有 observer 收到 RPC（src/observer/ob_service.h:137）
    │   → 阻止新事务开始
    │
    ├─ Primary observer: 等所有进行中事务完成 / abort
    │
    ├─ Primary observer: replay drain（让 Standby 追上到 switchover_timestamp）
    │
    ▼
Phase 3: 角色对调
    │
    ├─ Standby RS: 接管 Primary 角色（角色反转）
    ├─ Standby observer: 解除只读约束
    ├─ Primary RS: 进入 Standby 角色
    │
    ▼
Phase 4: 验证
    │
    ├─ check_partition_log(switchover_timestamp)
    │   → 验证 Standby 收到了所有到 switchover_timestamp 的日志
    │
    └─ 状态: PREPARE_SWITCHING_TO_STANDBY → SWITCHING_TO_STANDBY → NORMAL (Standby)
```

### 6.3 关键 RPC

```cpp
// src/observer/ob_service.h:137-138
int stop_partition_write(const obrpc::Int64 &switchover_timestamp, obrpc::Int64 &result);
int check_partition_log(const obrpc::Int64 &switchover_timestamp, obrpc::Int64 &result);
```

**`stop_partition_write`**：
- Primary RS 调用每个 observer 的这个 RPC
- observer 收到后拒绝新事务（返回特定错误码）
- 等待进行中事务完成
- 返回 OK（已停写）

**`check_partition_log`**：
- Primary RS 在角色对调前调用
- 验证 Standby 已经收到了所有 `switchover_timestamp` 之前的日志
- 如果 Standby 落后超过容忍窗口 → 报错，回滚到 PREPARE_FLASHBACK_FOR_SWITCH_TO_PRIMARY

### 6.4 为什么需要 drain

Standby 拉取 Primary 日志有天然延迟（可能几十毫秒到几秒）。Switchover 时如果直接切换，可能丢失最后几秒的日志。所以：
1. Primary 停写后，等 Standby 拉到 `switchover_timestamp`
2. 确认日志已应用
3. 才切换角色

---

## 7. Failover 流程（unplanned）

### 7.1 触发场景

- Primary 集群整体不可用（机房故障 / 网络分区）
- 管理员手动触发 failover

### 7.2 与 Switchover 的差异

| 维度 | Switchover | Failover |
|------|-----------|----------|
| 触发 | ALTER SYSTEM（计划内） | Primary 不可用（计划外） |
| 数据丢失 | 0（drain 完整） | 可能丢失（Standby 落后部分） |
| 流程 | 5 步（PREPARE → SWITCHING → NORMAL） | 3 步（直接 NORMAL） |
| 角色 | Primary 主动让出 | Standby 主动接管 |
| flashback | 失败时 | 通常失败（Primary 已不可用） |

### 7.3 Failover 步骤

```
Phase 1: 检测 Primary 不可用
    │
    ├─ Standby 持续探测 Primary（心跳 + RPC）
    ├─ 超时 → 标记 Primary 失联
    │
    ▼
Phase 2: 评估数据差距
    │
    ├─ 检查 Standby LSN vs Primary 最后已知 LSN
    ├─ 差距 < threshold → 可 failover
    ├─ 差距 > threshold → 拒绝（数据丢失过多）
    │
    ▼
Phase 3: 角色接管
    │
    ├─ Standby 升级为新 Primary
    ├─ 状态: PREPARE_FLASHBACK_FOR_FAILOVER_TO_PRIMARY → FLASHBACK → NORMAL (Primary)
    │
    └─ (可选) 老 Primary 恢复后 → 作为新 Standby 加入
```

### 7.4 Lossless Failover

```cpp
// src/share/ob_tenant_switchover_status.h
PREPARE_FLASHBACK_FOR_LOSSLESS_FAILOVER_TO_PRIMARY_STATUS = 9
```

这是 OB 5.x 引入的 **无损 Failover** 模式：
- 当 Primary 故障时，Standby 知道所有未应用的日志（可能来自 archive）
- 接管前先 apply 所有 archive 中的剩余日志
- 达到 RPO=0（不丢数据）
- 但延迟较长（取决于 archive 应用速度）

---

## 8. Flashback 机制 —— 回滚到切换前

### 8.1 何时触发 flashback

```
SWITCHING_TO_STANDBY (Primary → Standby)
    │
    ├─ 切换过程发现错误（drain 超时 / check 失败 / 网络异常）
    │
    ▼
PREPARE_FLASHBACK_FOR_SWITCH_TO_PRIMARY
    │
    ▼
FLASHBACK
    │
    ▼
FLASHBACK_AND_STAY_STANDBY
```

### 8.2 Flashback 实现原理

Flashback 利用 OB 的 **闪回查询能力**（参见 #05-mvcc-compact / `ob_ls_recovery_stat_handler.h`）：

1. **记录切换前的快照**：在 PREPARE 阶段记录 SCN（snapshot timestamp）
2. **失败时回滚**：把 Standby 的数据回滚到该 SCN
3. **保持 Standby 角色**：不再尝试切换，回到 Standby 状态继续接收 Primary 日志

```cpp
// (伪代码 / 架构描述)
int flashback_to_timestamp(const ObLSID &ls_id, int64_t target_scn) {
  // 1. 停止 ObLogRestoreService 的 apply 线程
  // 2. 对每个 LS 调用 flashback_to_scn(target_scn)
  //    - 利用 MVCC 的 snapshot 能力回滚到 target_scn
  //    - 旧版本链路保留，新写入丢弃
  // 3. 重启 ObLogRestoreService，继续从 Primary 拉取
  // 4. 状态机切换到 FLASHBACK_AND_STAY_STANDBY
}
```

---

## 9. 读一致性：Standby 上的 Read-After-Apply

### 9.1 Standby 的读约束

```
时间线:
  t0: Primary 提交事务 T1，LSN = 1000
  t0+10ms: Standby 拉到 T1 的日志
  t0+20ms: Standby 完成 T1 apply 到 memtable
  t0+30ms: Standby 应用发 SELECT 看到 T1 的写入
```

**约束**：Standby 上的读看到的版本，**取决于 apply 进度**，不是 Primary 上的提交时间。这是 Standby 模式的根本约束。

### 9.2 SCN 推进机制

Standby 维护自己的 SCN（提交序号）：
- Primary SCN: 1000 (提交时)
- Standby SCN: 990 (落后 10 个 SCN)

Standby 的事务可见性判断用 **Standby SCN**：
- 事务 `read_snapshot_scn = 990` → 看不到 T1（需要 ≥ 1000）
- 事务 `read_snapshot_scn = 1000` → 看到 T1

### 9.3 与弱读的关系

Standby 上的读不是"弱读"，而是"落后读"：
- 弱读：基于当前快照（容忍 staleness），读 follower
- Standby 读：基于 Standby apply 进度，读 Standby 的本地副本

两者本质不同。Standby 模式用于 HA 场景，弱读用于读写分离场景。

---

## 10. 与 #62 cdcservice 的对比

| 维度 | cdcservice | restoreservice (standby) |
|------|-----------|-------------------------|
| 角色 | 服务端（对外） | 客户端（对内） |
| 接收方 | 外部 CDC 客户端 (Canal/DTS) | 本地 observer 存储层 |
| 输出格式 | binlog row event (兼容 MySQL) | PALF LogGroupEntry (本地 replay) |
| 数据流向 | PALF → binlog → 外部 | 远端 Primary → PALF → memtable |
| 延迟容忍 | 高（秒级） | 低（要求尽量实时） |
| 协议 | obrpc streaming fetch | obrpc + 本地 replay |
| archive 复用 | 通过 `ObLogExternalStorageHandler` | 通过 `ObLogRestoreArchiveDriver` |

两者在 archive 读取层共享 `ObArchivePieceMgr`（参见 #62 §6 restoreservice 介绍）。

---

## 11. 总结

### 11.1 Standby 集群在 OB 体系中的定位

```
应用读/写 ──► Primary Cluster (OB)
                  │
                  │ 1. 日志同步（按 protection mode）
                  │ 2. 元数据同步（partition map / cluster topology）
                  │
                  ▼
              Standby Cluster (OB)
                  │
                  ▼
            ALTER SYSTEM SWITCHOVER / FAILOVER
                  │
                  ▼
            角色对调（原 Standby → Primary）
```

Standby 是 **OB 体系内独立的第二条 HA 主线**，区别于 PALF 多副本（同集群内）：
- **PALF 多副本**：同集群内，Leader/Follower 同步，故障切换秒级
- **Standby 集群**：跨集群，Primary → Standby 异步/同步，切换分钟级

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Cluster role | `ObClusterRole::PRIMARY_CLUSTER / STANDBY_CLUSTER` |
| Protection mode | `MAXIMUM_PERFORMANCE / AVAILABILITY / PROTECTION` 三档 + 7 级 |
| 日志拉取 | `ObLogRestoreService` 持续 background thread |
| 双源切换 | archive driver (冷启动) → net driver (热复制) |
| 9 状态机 | `ObTenantSwitchoverStatus` |
| Switchover 流程 | PREPARE → SWITCHING → NORMAL（5 步） |
| Failover 流程 | 直接接管（Primary 已不可用） |
| Flashback | flashback 失败回滚到 PREPARE_FLASHBACK_xxx |
| 读一致性 | read-after-apply（Standby SCN） |

### 11.3 关键技术常量引用

| 常量 | 值 | 位置 |
|------|---|------|
| `STANDBY_THREAD_RUN_INTERVAL` | 10ms | `ob_log_restore_service.h` |
| `PRIMARY_THREAD_RUN_INTERVAL` | 1s | `ob_log_restore_service.h` |
| `SCHEDULE_FETCH_LOG_INTERVAL` | 10ms | `ob_log_restore_service.h` |
| `UPDATE_UPSTREAM_INTERVAL` | 100ms | `ob_log_restore_service.h` |
| `RESYNCHRONIZATION_LEVEL` | 4 | `ob_cluster_role.h` |
| `MAXIMUM_PROTECTION_LEVEL` | 3 | `ob_cluster_role.h` |

### 11.4 推荐下一步

按之前梳理的顺序，下一篇应该是 **#66 Direct Load (Load Data 高吞吐)**：

OB 的 Direct Load 绕过 SQL parser，直接走"协议层 → SSTable writer" 的批量导入路径，单集群吞吐可达 MB/s 级。源码入口：`src/sql/engine/load_data/` + `src/storage/direct_load/`（OB 4.x 新增）。

这是大数据导入场景的核心，对应 ELT 数据管道、批量初始化、跨集群数据迁移等场景。

整吗？