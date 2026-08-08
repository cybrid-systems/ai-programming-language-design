# 62-cdcservice-logfetcher — OceanBase 5.x CDC 服务端 / PALF Subscriber / 归档冷启动 三模块深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（与 01-60 篇文章使用的 OB 4.x 不同：5.x 把 liboblog 拆成了 `cdcservice` / `logfetcher` / `restoreservice` 三个独立模块）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OceanBase 兼容 MySQL binlog 协议的下游生态（Canal / DTS / Kafka / 各种数据中台）依赖于 CDC（Change Data Capture）服务层。4.x 时代这套机制统一封装在 `src/logservice/liboblog/` 目录中，由一个超大的 `ObLogFetcher` 同时承担 PALF subscriber + 行级 event 重组 + binlog 序列化 + RPC 服务端四种角色。**5.x 进行了清晰的责任拆分**：

| 模块 | 路径 | 角色 | 谁用 |
|------|------|------|------|
| `cdcservice` | `src/logservice/cdcservice/` | **服务端** —— 接收 CDC 客户端（Canal/DTS/OMS）的 fetch_log RPC | 生产 observer |
| `logfetcher` | `src/logservice/logfetcher/` | **客户端 / PALF subscriber** —— observer 主动拉取远端 cluster 日志（restore / Standby 模式） | restore_service, standby 备库 |
| `restoreservice` | `src/logservice/restoreservice/` | **归档冷启动** —— 从 archive 拉历史日志补齐到 PALF LSN | restore_service |

这三个模块共同承担了原来 `liboblog` 的全部职责，但角色清晰不耦合：
- `cdcservice` 处理"我生产、我发出去"
- `logfetcher` 处理"我消费、别人生产"（cluster 间）
- `restoreservice` 提供"归档备胎"——当 PALF 已 truncate 后的冷启动数据源

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 11-palf | `cdcservice` 通过 `PalfHandleGuard` 直接读 PALF，是 PALF 的最重消费者之一 |
| 13-clog | `cdcservice` 的下游协议是 clog（commit log），物理路径上是 PALF → clog → CDC binlog |
| 27-rootserver | 归档目的地的元信息（archive_dest）由 RS 维护，`cdcservice` 周期 refresh |
| 30-observer-startup | `ObCdcService` 是 observer 启动时按 tenant 创建的子服务 |
| 49-log-service | `cdcservice` 是 Log Service 下游的两大消费者之一（另一个是 restore） |
| 53-rpc-framework | `cdcservice` 走 `obrpc` 协议栈；`logfetcher` 也走 `obrpc` |

---

## 1. 整体架构：三模块边界与协作

### 1.1 三模块的数据流

```
┌──────────────────────────────────────────────────────────────────┐
│                    Downstream CDC Clients                        │
│         Canal / DTS / Kafka / OMS / 自研数据中台                 │
└─────────────────────┬────────────────────────────────────────────┘
                      │  ObCdcLSFetchLogReq (streaming RPC)
                      ▼
┌──────────────────────────────────────────────────────────────────┐
│              src/logservice/cdcservice/  ←──── OB Server 进程   │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────┐  │
│  │  ObCdcService   │→ │  ObCdcFetcher    │→ │  PalfHandleG.. │  │
│  │ (per-tenant TG) │  │  (PALF reader)   │  │  (online PALF) │  │
│  └────────┬────────┘  └──────────────────┘  └────────────────┘  │
│           │              │                       ▲               │
│           │              ▼                       │               │
│           │       ┌──────────────────┐           │               │
│           │       │ ObLogExternalStorage│ ←────┐ │               │
│           │       │ Handler (archive) │      │ │               │
│           │       └──────────────────┘      │ │               │
│           │                                  │ │               │
│           ▼                                  │ │               │
│  ┌──────────────────────┐                    │ │               │
│  │  ClientLSCtxMap      │  30min expire     │ │               │
│  │  (client,ls) state  │                    │ │               │
│  └──────────────────────┘                    │ │               │
└──────────────────────────────────────────────┼─┼───────────────┘
                                               │ │
                              ┌────────────────┘ │
                              ▼                  │
            ┌─────────────────────────────────────┴────────────┐
            │  ObLogStartLSNLocator (locate start LSN by ts)   │
            │  LargeBufferPool (archive buffer pool)            │
            └────────────────────────────────────────────────────┘
                                  ▲
                                  │ locate / fetch
                                  │
┌─────────────────────────────────┴────────────────────────────────┐
│        src/logservice/restoreservice/  ←──── restore_service     │
│  ObLogRestoreArchiveDriver / ObLogArchivePieceMgr                  │
│  ObRemoteLogGroupEntryIterator                                      │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│        src/logservice/logfetcher/  ←──── observer 作为 client     │
│   ┌─────────────────────┐    ┌──────────────────────┐             │
│   │  ObLogFetcher       │ →  │  FetchStreamContainer │            │
│   │ (PALF subscriber)   │    │ (per-remote-server)  │            │
│   └─────────────────────┘    └──────────────────────┘             │
│   add_ls/recycle_ls/remove_ls   dispatch to ObLSWorker             │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 关键设计原则

1. **责任单方向**：`cdcservice` 不直接调 `logfetcher`，`logfetcher` 也不依赖 `cdcservice`。`restoreservice` 是 `cdcservice` 的 archive 数据源（通过 `ObLogExternalStorageHandler`）。
2. **进程内 vs 进程间**：`cdcservice` 是当前 observer 进程内的服务（per-tenant TG）；`logfetcher` 既可以本进程用（restore / standby），也可以独立 obcdc 进程部署（这是 OB CDC Service 独立部署模式）。
3. **流式 RPC 一致性**：所有 fetch 都走 `obrpc` 的流式 RPC，避免大包问题。

---

## 2. ObCdcService — 服务端 CDC 入口

### 2.1 类骨架

```cpp
// src/logservice/cdcservice/ob_cdc_service.h
class ObCdcService: public lib::TGRunnable
{
public:
  ObCdcService();
  ~ObCdcService();
  int init(const uint64_t tenant_id, ObLSService *ls_service);

public:
  void run1() override;   // lib::TGRunnable 入口：后台循环
  int start();
  void stop();
  void wait();
  void destroy();

public:
  // ─── RPC 入口：CDC 客户端 → 服务端 ───
  int req_start_lsn_by_ts_ns(
      const obrpc::ObCdcReqStartLSNByTsReq &req_msg,
      obrpc::ObCdcReqStartLSNByTsResp &resp);

  int fetch_log(
      const obrpc::ObCdcLSFetchLogReq &req,
      obrpc::ObCdcLSFetchLogResp &resp,
      const int64_t send_ts, const int64_t recv_ts);

  int fetch_missing_log(
      const obrpc::ObCdcLSFetchMissLogReq &req,
      obrpc::ObCdcLSFetchLogResp &resp,
      const int64_t send_ts, const int64_t recv_ts);

  int fetch_raw_log(
      const obrpc::ObCdcFetchRawLogReq &req,
      obrpc::ObCdcFetchRawLogResp &resp,
      const int64_t send_ts, const int64_t recv_ts);

  int get_archive_dest_snapshot(const ObLSID &ls_id, ObBackupDest &archive_dest);

  int get_or_create_client_ls_ctx(
      const obrpc::ObCdcRpcId &client_id,
      const uint64_t client_tenant_id,
      const ObLSID &ls_id,
      const int8_t flag,
      const int64_t client_progress,
      const obrpc::ObCdcFetchLogProtocolType proto_type,
      const obrpc::ObCdcClientType client_type,
      ClientLSCtx *&ctx);

  int revert_client_ls_ctx(ClientLSCtx *ctx);
  int init_archive_source_if_needed(const ObLSID &ls_id, ClientLSCtx &ctx);

private:
  // 后台 loop 任务（无锁保护，必须只在 run1 中调用）
  bool is_archive_dest_changed_(const ObArchiveDestInfo &info);
  int  update_archive_dest_for_ctx_();
  int  get_archive_dest_path_snapshot_(ObBackupPathString &archive_dest_str);
  int  recycle_expired_ctx_(const int64_t cur_ts);
  int  resize_log_ext_handler_();
  int  snapshot_traffic_info_();
  // ─── 客户端类型识别（CDC vs Standby） ───
  template <class RpcRequest>
  obrpc::ObCdcClientType get_client_type_from_req_(const RpcRequest &req);

private:
  bool is_inited_;
  volatile bool stop_flag_ CACHE_ALIGNED;
  uint64_t tenant_id_;

  ObCdcStartLsnLocator locator_;          // ts → start_lsn 定位
  ObCdcFetcher fetcher_;                  // PALF reader

  int tg_id_;
  int64_t dest_info_version_;
  ObArchiveDestInfo dest_info_;
  SpinRWLock dest_info_lock_;             // RS 元数据版本读写锁
  ClientLSCtxMap ls_ctx_map_;             // client × LS 状态表
  archive::LargeBufferPool large_buffer_pool_;
  logservice::ObLogExternalStorageHandler log_ext_handler_;
};
```

### 2.2 per-tenant TG（Thread Group）模式

`ObCdcService` 继承 `lib::TGRunnable`，意味着 **每个 tenant 拥有一个独立的 CDC service 实例**（创建在 observer 启动流程的 module init 阶段）。这一点和 SQL / Trans 服务一致 —— 都是 per-tenant 隔离。

`create_tenant_tg_` / `start_tenant_tg_` / `wait_tenant_tg_` / `stop_tenant_tg_` / `destroy_tenant_tg_` 这一套生命周期方法包裹在 `_` 后缀的私有 helper 里，meta tenant 是不需要 TG 的（注释里明确写明 `wrapping the macro with methods below to filter meta tenant`）。

### 2.3 后台 loop（`run1`）的核心职责

`run1` 是一个 while 循环，主要驱动以下 6 个后台任务：

| 任务 | 方法 | 周期 / 触发 | 目的 |
|------|------|-------------|------|
| 1 | `query_tenant_archive_info_` | 周期 | 从 RS 拉取本租户的 archive dest |
| 2 | `update_archive_dest_for_ctx_` | dest 变化时 | 通知所有 ctx 切换 archive source |
| 3 | `recycle_expired_ctx_` | 周期 | 清理 30 分钟未访问的 ClientLSCtx |
| 4 | `resize_log_ext_handler_` | 周期 | 调整 archive buffer pool 大小 |
| 5 | `snapshot_traffic_info_` | 周期 | 上报 CDC 流量到监控 |
| 6 | RPC 处理 | 每条 RPC 都直接调相应方法 | 业务请求处理 |

这些任务 **都跑在 ObCdcService 自己的 TG 线程上**，而不是独立的 worker pool —— 这是 OB 5.x 与 4.x 的一个区别（4.x liboblog 有独立的 worker 线程池）。

### 2.4 ClientLS 状态机的过期策略

```cpp
// ob_cdc_service.h
class RecycleCtxFunctor {
public:
  static const int64_t CTX_EXPIRE_INTERVAL = 30L * 60 * 1000 * 1000;  // 30 min
public:
  RecycleCtxFunctor(int64_t ts): cur_ts_(ts) {}
  bool operator()(const ClientLSKey &key, ClientLSCtx *value) {
    UNUSED(key);
    bool bret = false;
    if (OB_ISNULL(value) || cur_ts_ - value->get_touch_ts() >= CTX_EXPIRE_INTERVAL) {
      bret = true;
    }
    return bret;
  }
private:
  int64_t cur_ts_;
};
```

30 分钟无访问 → 自动 recycle。这是为了避免 CDC 客户端断开后留下无主 ctx 长期占内存。对应 v1/v2 archive 客户端有独立的过期统计（`ExpiredArchiveClientLSFunctor`，10 分钟过期）。

### 2.5 客户端类型识别 —— CDC vs Standby

`get_client_type_from_req_` 是一个有趣的判断：

```cpp
template <class RpcRequest>
obrpc::ObCdcClientType get_client_type_from_req_(const RpcRequest &req) {
  obrpc::ObCdcClientType client_type = req.get_client_type();
  if (obrpc::ObCdcClientType::CLIENT_TYPE_UNKNOWN == client_type) {
    client_type = OB_INVALID_TENANT_ID == req.get_tenant_id()
        ? obrpc::ObCdcClientType::CLIENT_TYPE_CDC
        : obrpc::ObCdcClientType::CLIENT_TYPE_STANDBY;
  }
  return client_type;
}
```

- 显式声明 client type → 直接用
- 否则 → 看 tenant_id：无效 tenant_id 视为 CDC 客户端（外部 Canal 等）；有效 tenant_id 视为 Standby 客户端（OB observer 内部 restore_service 拉日志）

这个区分很重要 —— CDC 客户端通常不需要 archive 模式（直接读 PALF 即可），但 Standby 客户端经常会请求 archive 模式（因为要从很早的 timestamp 开始）。

---

## 3. ObCdcFetcher — PALF 直接读取器

### 3.1 类骨架

```cpp
// src/logservice/cdcservice/ob_cdc_fetcher.h
class ObCdcFetcher
{
  static const int64_t RPC_QIT_RESERVED_TIME = 5 * 1000 * 1000; // 5 second
public:
  int init(const uint64_t tenant_id,
      ObLSService *ls_service,
      ObCdcService *host,
      archive::LargeBufferPool *buffer_pool,
      logservice::ObLogExternalStorageHandler *log_ext_handler);
  void destroy();

public:
  // 主入口：顺序 fetch（CDC 客户端常规用法）
  int fetch_log(const obrpc::ObCdcLSFetchLogReq &req,
      obrpc::ObCdcLSFetchLogResp &resp,
      ClientLSCtx &ctx,
      ObCdcFetchLogTimeStats &fetch_log_time_stat);

  // 缺失日志重传：random read（针对网络丢包补偿）
  int fetch_missing_log(const obrpc::ObCdcLSFetchMissLogReq &req,
      obrpc::ObCdcLSFetchLogResp &resp);

  // 原始日志：返回 LogGroupEntry 字节流（不解析成行）
  int fetch_raw_log(const obrpc::ObCdcFetchRawLogReq &req,
      obrpc::ObCdcFetchRawLogResp &resp,
      ClientLSCtx &ctx);

private:
  int init_palf_handle_guard_(const ObLSID &ls_id, palf::PalfHandleGuard &palf_handle_guard);
  int do_fetch_log_(const obrpc::ObCdcLSFetchLogReq &req,
      FetchRunTime &fetch_runtime,
      obrpc::ObCdcLSFetchLogResp &resp,
      ClientLSCtx &ctx, ObCdcFetchLogTimeStats &fetch_time_stat);
  int set_fetch_mode_before_fetch_log_(const ObLSID &ls_id,
      const LSN &start_lsn, const bool test_switch_fetch_mode,
      bool &ls_exist_in_palf, palf::PalfHandleGuard &palf_guard,
      ClientLSCtx &ctx);
  int ls_fetch_log_(const ObLSID &ls_id, const int64_t end_tstamp,
      const int8_t fetch_flag, obrpc::ObCdcLSFetchLogResp &resp,
      FetchRunTime &frt, bool &reach_upper_limit, bool &reach_max_lsn,
      int64_t &scan_round_count, int64_t &fetched_log_count,
      ClientLSCtx &ctx, ObCdcFetchLogTimeStats &fetch_time_stat);
  int get_replayable_point_scn_(const ObLSID &ls_id, SCN &replayable_point_scn);
};
```

### 3.2 `RPC_QIT_RESERVED_TIME = 5s` —— 超时预留

这个常量是性能/正确性的关键：

```cpp
static const int64_t RPC_QIT_RESERVED_TIME = 5 * 1000 * 1000; // 5 second
```

含义：fetch_log 发现剩余时间 < 5s 就立即退出（Quit In Time），不再发起新一次 PALF 读，避免 RPC handler 自身超时被框架踢掉。这是典型的"RPC 内预留 buffer"模式 —— OB 大量 RPC handler 都有类似的 `RESERVED_TIME` 常量。

### 3.3 三种 fetch 模式

| 方法 | 用途 | 路径 |
|------|------|------|
| `fetch_log` | **顺序读**：CDC 客户端每 N 秒拉一次增量 | PALF forward iter → LogEntry → 序列化 |
| `fetch_missing_log` | **随机读**：客户端发现包序号不连续时补单条 | PALF `seek(LSN)` → 单条 LogEntry |
| `fetch_raw_log` | **原字节流**：返回 LogGroupEntry 整块（不下沉到行） | PALF raw iter |

`fetch_log` 是 99% 的生产路径（`DoFetchLogTimeStats` 统计全部时间）。`fetch_missing_log` 在网络不稳定时偶发。`fetch_raw_log` 主要给 restore / 调试用。

### 3.4 双源切换：`set_fetch_mode_before_fetch_log_`

```cpp
int set_fetch_mode_before_fetch_log_(const ObLSID &ls_id,
    const LSN &start_lsn,
    const bool test_switch_fetch_mode,
    bool &ls_exist_in_palf,
    palf::PalfHandleGuard &palf_guard,
    ClientLSCtx &ctx);
```

这个方法是 `cdcservice` 的关键设计点。逻辑：

1. **先尝试 PALF**：通过 `PalfHandleGuard` 检查 LS 在本 observer 上是否存在 + start_lsn 是否还在 PALF 范围内
2. **如果 PALF 不可用**（LS 已迁走 / start_lsn 太老被 truncate）：切换到 `ObLogExternalStorageHandler` 走 archive 模式
3. **test_switch_fetch_mode**：每次都测试一下要不要切（避免卡在 archive 模式太久）

ctx 字段会记录当前 fetch_mode（online / archive），下次 fetch 自动沿用。

---

## 4. ClientLSCtx — 客户端-LS 状态机

### 4.1 ClientLSKey 四元组

```cpp
// src/logservice/cdcservice/ob_cdc_struct.h
class ClientLSKey
{
public:
  ClientLSKey():
      client_addr_(),
      client_pid_(0),
      tenant_id_(OB_INVALID_TENANT_ID),
      ls_id_(share::ObLSID::INVALID_LS_ID) { }
  ClientLSKey(const common::ObAddr &client_addr,
              const uint64_t client_pid,
              const uint64_t tenant_id,
              const share::ObLSID &ls_id);
  // ...
  uint64_t hash() const;
  bool operator==(const ClientLSKey &that) const;
};
```

四元组唯一标识一个 CDC 客户端连接：
- `client_addr`：客户端 IP:port（用于 RPC 路由 + 区分多客户端）
- `client_pid`：客户端进程 ID（同一 IP 多客户端区分）
- `tenant_id`：本客户端要拉的 tenant
- `ls_id`：具体 log stream

### 4.2 ClientLSCtx 携带的状态

`ClientLSCtx` 是真正的状态机（具体定义在 ob_cdc_struct.h，未全文列出 —— 字段很多），关键字段：

| 字段 | 含义 |
|------|------|
| `client_progress_` | 客户端 ack 的最后 LSN |
| `touch_ts_` | 最后访问时间（用于 30 分钟过期） |
| `source_` | 当前 fetch source（PalfHandleGuard 或 ObRemoteLogParent） |
| `archive_dest_` | 当前 archive 路径快照 |
| `proto_type_` | 协议类型（V1 / V2 streaming） |
| `client_type_` | CDC / Standby / Archive |

设计哲学：每个客户端-LS 对都有自己的状态 —— **ctx 是 CDC 服务的核心可恢复状态**。如果 observer crash 重启，所有 ctx 丢失，客户端必须重新 `req_start_lsn_by_ts_ns` 重新建立 ctx（通过 client_progress 告诉服务端上次消费到哪）。

### 4.3 UpdateCtxFunctor —— 批量 archive dest 切换

```cpp
class UpdateCtxFunctor {
public:
  UpdateCtxFunctor():
      is_inited_(false),
      dest_(),
      dest_ver_(0) { }
  int init(const ObBackupPathString &dest_str, const int64_t version);
  bool operator()(const ClientLSKey &key, ClientLSCtx *value);
private:
  bool is_inited_;
  ObBackupDest dest_;
  int64_t dest_ver_;
};
```

当 RS 通知 archive dest 变了，`ObCdcService::run1` 调用这个 functor 遍历 `ls_ctx_map_`，把所有 ctx 的 archive source 切到新路径。这是热切换 —— 不需要客户端重连。

---

## 5. logfetcher — PALF Subscriber 客户端

### 5.1 IObLogFetcher 接口

`logfetcher` 模块在 `cdcservice` 不参与的另一个使用场景 —— **observer 作为 PALF 的远端 subscriber**：

```cpp
// src/logservice/logfetcher/ob_log_fetcher.h
class IObLogFetcher
{
public:
  virtual ~IObLogFetcher() {}
  virtual int start() = 0;
  virtual void stop() = 0;
  virtual void pause() = 0;            // 暂停所有 LS 的拉取
  virtual void resume() = 0;           // 恢复
  virtual bool is_paused() = 0;
  virtual void mark_stop_flag() = 0;

  virtual void configure(const ObLogFetcherConfig &cfg) = 0;
  virtual int64_t get_cluster_id() const = 0;
  virtual uint64_t get_source_tenant_id() const = 0;

  virtual int update_preferred_upstream_log_region(const common::ObRegion &region) = 0;
  virtual int get_preferred_upstream_log_region(common::ObRegion &region) = 0;

  virtual int add_ls(const share::ObLSID &ls_id,
                     const ObLogFetcherStartParameters &start_parameters) = 0;
  virtual int recycle_ls(const share::ObLSID &ls_id) = 0;  // 标记删除（异步）
  virtual int remove_ls(const share::ObLSID &ls_id) = 0;   // 同步等待资源回收
  virtual int get_all_ls(ObIArray<share::ObLSID> &ls_ids) = 0;

  virtual int update_fetching_log_upper_limit(const share::SCN &upper_limit_scn) = 0;
  virtual int update_compressor_type(const common::ObCompressorType &compressor_type) = 0;
};
```

关键方法解读：

- `add_ls / recycle_ls / remove_ls` 三部曲：新增 LS → 标记待删除（异步） → 同步等待资源回收。`recycle_ls` 与 `remove_ls` 分离是为了避免删除风暴（recycle 是入队，remove 是 sync drain）。
- `pause / resume`：全局暂停 —— restore_service 在做大事务时可能需要暂停拉取避免 OOM。
- `update_fetching_log_upper_limit`：动态设置 fetch SCN 上限（apply 阶段落后时回拉）。
- `update_preferred_upstream_log_region`：跨地域拉取偏好（机房选择）。

### 5.2 ObLogFetcher 的内部组件

`ObLogFetcher` 类持有以下关键子系统：

```cpp
class ObLogFetcher {
  // ...
  ObLogLSFetchMgr ls_fetch_mgr_;             // per-LS fetch 状态
  ObFsContainerMgr fs_container_mgr_;         // per-server fetch stream
  ObLogRpc *rpc_;                             // 上游 RPC 客户端
  PartProgressController progress_controller_; // 进度控制器
  ObLogStartLSNLocator start_lsn_locator_;     // ts → start_lsn 定位
  ObLogFetcherIdlePool idle_pool_;            // 闲置 fetch stream 池
  ObLogFetcherDeadPool dead_pool_;            // 死亡/异常 fetch stream 池
  ObLSWorker stream_worker_;                  // stream master 工作线程
  // ObLogRouteService（logrouteservice 路径）
};
```

### 5.3 FetchStreamContainer —— 远端 server 维度的 stream

```cpp
// src/logservice/logfetcher/ob_log_fetch_stream_container.h
class FetchStreamContainer
{
public:
  static const int64_t MAX_FS_COUNT = 1;     // 每个 container 最多 1 个 stream

  void reset(const FetchStreamType stype,
      const uint64_t self_tenant_id,
      IObLogRpc &rpc,
      IFetchStreamPool &fs_pool,
      IObLSWorker &stream_worker,
      LogFileDataBufferPool &log_file_pool,
      FetchLogRpcResultPool &rpc_result_pool,
      PartProgressController &progress_controller,
      ILogFetcherHandler &log_handler);

  int dispatch(LSFetchCtx &task, const common::ObAddr &request_svr);

private:
  FetchStreamType stype_;
  obrpc::ObCdcFetchLogProtocolType proto_type_;
  uint64_t self_tenant_id_;
  IObLogRpc *rpc_;
  IFetchStreamPool *fs_pool_;
  IObLSWorker *stream_worker_;
  FetchLogRpcResultPool *rpc_result_pool_;
  LogFileDataBufferPool *log_file_pool_;
  PartProgressController *progress_controller_;
  ILogFetcherHandler *log_handler_;
};
```

**关键设计：`MAX_FS_COUNT = 1`** —— 每个远端 server 一个 fetch stream 容器最多只有 1 个 fetch stream 在跑。这是为了避免对单 server 的并发拉取把对方打爆（CDC 服务端会有 stream 复用 + 优先级调度）。

`FetchStreamContainerMgr`（`ObFsContainerMgr`）按 `ObAddr` 索引容器，所有容器共享 `IFetchStreamPool` 池化的 fetch stream 对象。

### 5.4 三池（idle / dead / active）模式

`ObLogFetcherIdlePool` / `ObLogFetcherDeadPool` 把 fetch stream 的生命周期拆成三段：

```
active → (异常 / 终止) → dead pool (待清理 / 错误统计)
active → (空闲超时) → idle pool (复用对象)
idle pool → (新任务) → active
```

这是 OB 经典的对象池模式 —— 配合 `ObLogFetcherBgWorker` 后台线程定期清 dead pool + 缩 idle pool。

---

## 6. restoreservice — 归档冷启动

### 6.1 角色

`restoreservice` 是 OB 5.x 引入的独立模块，专门处理"observer 需要从 archive 拉历史日志"的场景：
- 新建一个 LS 的副本（冷启动）
- Standby 备库首次接入主库
- 归档回放（备份验证 / 时点恢复）

`restoreservice` 与 `cdcservice` 共享 archive 数据源（`ObLogArchivePieceMgr`），但走的是 **不同协议** —— restore 走 obrpc 拉 archive piece 内容，cdcservice 走 PALF 实时日志。

### 6.2 关键类

```cpp
// src/logservice/restoreservice/
class ObLogArchivePieceMgr;       // archive piece 元数据 + 文件句柄
class ObLogRestoreArchiveDriver;  // 驱动器：从 archive 拉日志
class ObLogRestoreAllocator;      // restore 专用的 buffer 分配器
class ObRemoteLogGroupEntryIterator;  // 远端日志 iterator 接口
class ObFetchLogTask;             // 单个 fetch 任务
// ... 47 个文件
```

### 6.3 与 cdcservice 的衔接

`ObCdcService::init_archive_source_if_needed` 是衔接点：

```cpp
int ObCdcService::init_archive_source_if_needed(const ObLSID &ls_id, ClientLSCtx &ctx) {
  // ...
  // 1. 检查 ctx 是否已有 archive source
  // 2. 如果没有，从 ObLogArchivePieceMgr 拿 archive dest
  // 3. 通过 ObRemoteSourceGuard 创建 ObRemoteLogParent
  // 4. 关联到 ctx 上（ctx 可以切换 online ↔ archive）
}
```

关键点是：`restoreservice` 提供了 archive iterator 的通用接口（`ObRemoteLogGroupEntryIterator`），`cdcservice` 在 archive 模式下复用同一套 iterator —— **archive piece 加载 + 远端日志读取逻辑只实现一次，两模块共享**。

---

## 7. RPC 协议层 — ObCdcRpcProxy / ObCdcRpcProcessor

### 7.1 协议族

```cpp
// src/logservice/cdcservice/ob_cdc_req.h
class ObCdcReqStartLSNByTsReq {
  static const int64_t ITEM_CNT_LMT = 10000;  // Around 400kb for cur version
  struct LocateParam {
    ObLSID ls_id_;
    int64_t start_ts_ns_;
  };
  LocateParamArray params_;     // 一次最多 10000 个 LS
  ObCdcRpcId client_id_;
  int8_t flag_;
};

class ObCdcLSFetchLogReq { /* 单 LS fetch log 请求 */ };
class ObCdcLSFetchMissLogReq { /* 单 LS 缺失日志重传 */ };
class ObCdcFetchRawLogReq { /* 单 LS 原始日志（不下沉到行） */ };
```

`ITEM_CNT_LMT = 10000` ≈ 400KB —— 单 RPC 上限。生产中很少一次拉 10000 个 LS（典型 Canal 配置是几十到几百）。

### 7.2 错误码语义（locate start LSN 时）

`LocateResult` 返回的错误码有明确语义：

| 错误码 | 含义 |
|--------|------|
| `OB_SUCCESS` | locate 完成，返回 start_lsn |
| `OB_ENTRY_NOT_EXIST` | 该 LS 在本 observer 上无日志（可能被迁走） |
| `OB_ERR_OUT_OF_LOWER_BOUND` | ts_ns 太老，PALF 已经 truncate，需要走 archive |
| `OB_LS_NOT_EXIST` | 拿不到 PalfHandleGuard（LS 已删除 / 正在迁移） |
| `OB_EXT_HANDLE_UNFINISH` | locate 异步未完成（client 重试） |

特别注意 `OB_ERR_OUT_OF_LOWER_BOUND` —— 这是 cdcservice 切到 archive 模式的关键信号。

### 7.3 流式 vs 非流式

5.x 默认走 streaming RPC（`ObCdcFetchLogProtocolType::STREAMING`）。客户端可以选 V1（单 RPC 大包）或 V2（streaming）。streaming 模式由 `FetchStreamContainer` 主导 —— 服务端持续 send，客户端持续 recv 直到自己 ack 足够多。

---

## 8. 与下游生态对接

### 8.1 MySQL binlog 兼容

CDC 的最终消费者通常期望 MySQL binlog 协议（如 Canal 拉 binlog 解析 row event）。5.x 的兼容做法：

1. **cdcservice 不直接产 MySQL binlog** —— 它产的是 OB 内部的 clog 协议（LogGroupEntry + LogEntry）
2. **MySQL binlog 协议适配在客户端**：
   - OB 官方 CDC Service（独立进程，obcdc）订阅 cdcservice 的流，**转换成 MySQL binlog row event 写到本地文件 / 推到 Kafka**
   - 第三方组件（Canal / DTS / Flink CDC 等）通过 obcdc 提供的 binlog 端口对接

这意味着 OB 的 CDC 链路是 **双跳**：

```
OB PALF → cdcservice (RPC) → obcdc (transform) → binlog/Kafka → Canal/DTS/Flink
```

`obcdc` 单独成进程（`obcdc` 子项目）—— 这是 OB 5.x 与 4.x 的另一个大区别（4.x liboblog 把转换逻辑内置在 observer 进程里）。

### 8.2 OMS / DTS 对接

OMS（OceanBase Migration Service）和 DTS（Data Transmission Service）是阿里云官方的数据迁移/同步工具。它们都通过上述链路订阅 CDC。

---

## 9. 性能与限流

### 9.1 RPC 内预留 5s —— `RPC_QIT_RESERVED_TIME`

见 §3.2。fetch_log 内部循环每轮检查剩余时间。

### 9.2 LargeBufferPool —— archive 大块内存池

```cpp
archive::LargeBufferPool large_buffer_pool_;  // ObCdcService 成员
```

archive piece 通常是 64MB ~ 256MB 的大文件读取，需要专门的 buffer pool 而不是默认的 malloc。`LargeBufferPool` 来自 `src/logservice/archiveservice/large_buffer_pool.h`，提供大块定长 buffer 复用。

### 9.3 进度控制 —— `PartProgressController`

`PartProgressController` 是 `logfetcher` 的限流核心：
- 维护每个 partition 的 fetch progress
- 进度落后时降低 fetch 频率
- 进度领先时放开 fetch 频率（自适应 fetch）

### 9.4 多副本一致性

CDC 服务在多副本 observer 上 **每个副本独立服务**（不像传统主备）。客户端通过 RS / configserver 拿到当前 leader，由 leader 服务端提供 CDC 数据。这与 PALF 的 leader-leader 模型一致。

---

## 10. 总结

### 10.1 5.x 三模块拆分的设计价值

| 维度 | 4.x liboblog | 5.x 三模块 |
|------|---------------|------------|
| 代码规模 | 单模块 ~3000 行混合逻辑 | 拆成 23/71/47 三个清晰子模块 |
| 责任边界 | 一个 `ObLogFetcher` 啥都干 | cdcservice (server) / logfetcher (client) / restoreservice (archive) |
| 部署模式 | 仅嵌入 observer 进程 | cdcservice 嵌入 + obcdc 独立进程 |
| archive 路径 | 内置 liboblog | 共享 `ObLogArchivePieceMgr` |
| 可维护性 | 大块耦合 | 每个模块独立迭代 |

### 10.2 关键技术点回顾

1. **per-tenant TG 隔离** —— `ObCdcService` 继承 `lib::TGRunnable`，每个 tenant 一个实例
2. **ClientLSCtxMap** —— 30 分钟过期回收，避免内存泄漏
3. **双源切换** —— online PALF ↔ archive 透明切换（OB_ERR_OUT_OF_LOWER_BOUND 触发）
4. **RPC 5s 预留** —— 避免 handler 超时被踢
5. **FetchStreamContainer MAX_FS_COUNT=1** —— 限流远端单 server
6. **三池 idle/dead/active** —— 经典 OB 对象池模式
7. **双跳 CDC 链路** —— cdcservice + obcdc 拆分部署
8. **archive 协议共享** —— restoreservice 提供 iterator，cdcservice 复用

### 10.3 后续可挖点

- **`obcdc` 独立进程** —— binlog 转换、限流、checkpoint 持久化（独立源码仓，未在 OB 主仓内）
- **`restoreservice` 详细机制** —— archive piece 加载、LSN 映射、restore state machine
- **Standby 备库 CDC 路径** —— `CLIENT_TYPE_STANDBY` 的差异化处理
- **大包流控策略** —— fetch_log 的 batch size / memory pool 调优

### 10.4 推荐下一步

按之前梳理的顺序，下一篇应该是 **63-obproxy-architecture**：OBProxy 是 OB 集群入口，承担连接池、LDC 路由、二阶段提交优化、弱读路由等关键功能 —— 生产部署必备组件，与 cdcservice 在集群入口/出口两端形成完整图景。