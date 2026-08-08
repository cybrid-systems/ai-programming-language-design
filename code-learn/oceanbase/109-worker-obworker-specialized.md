# 109-worker-obworker — OceanBase Worker (1/2): ObWorker 体系 + 各专用 Worker

> 基于 OceanBase 主线源码 (commit `f2e437ea62` 之后)
> 源码锚点: `src/observer/omt/ob_worker_processor.{h,cpp}` + `src/observer/omt/ob_th_worker.{h,cpp}` + `src/observer/omt/ob_multi_level_queue.{h,cpp}` + `src/sql/engine/px/ob_px_worker.{h,cpp}` + `src/rootserver/ob_disaster_recovery_worker.{h,cpp}` + `src/storage/tx/ob_tx_loop_worker.{h,cpp}` + `src/storage/tx/ob_ts_worker.{h,cpp}` + `src/storage/tx/ob_xa_trans_heartbeat_worker.{h,cpp}` + `src/storage/direct_load/ob_direct_load_mem_worker.{h,cpp}` + `src/logservice/archiveservice/ob_archive_worker.{h,cpp}` + `src/logservice/logfetcher/ob_ls_worker.{h,cpp}` + `src/logservice/palf/log_io_worker.{h,cpp,wrapper.{h,cpp}}` + `src/logservice/restoreservice/ob_remote_fetch_log_worker.{h,cpp}` + `src/logservice/logfetcher/ob_log_fetcher_bg_worker.{h,cpp}` + `src/pl/sys_package/ob_dbms_scheduler.{h,cpp}` + `src/rootserver/freeze/ob_major_merge_scheduler.{h,cpp}` + `src/rootserver/backup/ob_backup_*_scheduler.{h,cpp}` + `src/rootserver/restore/ob_*_scheduler.{h,cpp}` + `src/rootserver/ddl_task/ob_*_scheduler.{h,cpp}` + `src/rootserver/tenant_snapshot/ob_tenant_snapshot_scheduler.{h,cpp}` + `src/rootserver/compaction_ttl/ob_tenant_compaction_ttl_scheduler.{h,cpp}` + `src/logservice/replayservice/ob_replay_handler.{h,cpp}`
> 使用 doom-lsp (clangd LSP) 做符号解析与数据流追踪
> 接续 #107 libeasy + #108 easy_io/obrpc — 本篇拆 OB Worker 体系, 后续接 #110 ThreadPool 模型

---

## 0. 全文导读

OB 是分布式数据库, 内置**数十种 Worker** 处理不同业务 (SQL / 事务 / 压缩 / 备份 / 日志 / 重放 / 调度 / GC / 心跳 / 统计 等)。每个 Worker 都是独立线程 / 线程池, 互不干扰。本篇拆 OB Worker 体系:

| 子主题 | 内容 |
|--------|------|
| **Worker Processor (dispatch)** | `ObWorkerProcessor` + `ObThWorker` (tenant-thread 模型) + `ObMultiLevelQueue` |
| **PX Worker (并行 SQL 执行)** | `ObPxRpcWorker` / `ObPxCoroWorker` / `ObPxThreadWorker` (3 种容器) |
| **RootServer Worker** | `ObRsWorker` / `ObRpWorker` / `ObDisasterRecoveryWorker` / 各种 Scheduler |
| **TX / GC Worker** | `ObTxLoopWorker` / `ObTsWorker` / `ObXaTransHeartbeatWorker` / `ObXaInnerTableGcWorker` |
| **Log / Replay Worker** | `ObArchiveWorker` / `ObLsWorker` / `ObLogIoWorker` / `ObRemoteFetchLogWorker` / `ObLogFetcherBgWorker` / `ObReplayHandler` |
| **Storage Worker** | `ObDirectLoadMemWorker` |
| **DBMS / 统计 Worker** | `ObDbmsScheduler` |

### OB Worker 分类 (按业务)

| 类别 | 数量 | 典型 |
|------|------|------|
| SQL 执行 | 3 种 PX | `ObPxRpcWorker` / `ObPxCoroWorker` / `ObPxThreadWorker` |
| RootServer | 20+ | `ObMajorMergeScheduler` / `ObDdlScheduler` / `ObBackup*Scheduler` / `ObRsWorker` |
| TX / 事务 | 4 | `ObTxLoopWorker` / `ObTsWorker` / `ObXaTransHeartbeatWorker` / `ObXaInnerTableGcWorker` |
| Log / 重放 | 5 | `ObLogIoWorker` / `ObArchiveWorker` / `ObLsWorker` / `ObLogFetcherBgWorker` / `ObReplayHandler` |
| Direct Load | 1 | `ObDirectLoadMemWorker` |
| DBMS | 1 | `ObDbmsScheduler` |
| **总计** | **~40 个 Worker 类** | |

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| #24 PX Framework | #24 是概览, 本篇深入 Worker 实现细节 |
| #103 atomic | `ObThreadPool::thread_count_` / `ObOccamThreadPool::produce_seq_` 等是 Counter 模式 |
| #107 libeasy | libeasy 的 `easy_thread_pool_t` 是 Worker pool 的一种实现 |
| #108 easy_io/obrpc | obrpc handler 调度走 ObWorkerProcessor (见 §2.1) |

---

## 1. 背景 / 概念

### 1.1 为什么 OB 需要这么多 Worker

| 业务 | 原因 |
|------|------|
| 隔离 | 压缩 / 重放 / 备份不应阻塞 SQL 请求 |
| 优先级 | 不同业务优先级不同 (DDL > DML > 后台) |
| 资源限制 | 不同业务资源限制不同 (e.g. 压缩只能用 50% CPU) |
| 故障隔离 | 一个 Worker 卡死不应拖垮整个 observer |
| 可观测 | 每个 Worker 独立指标, 便于定位瓶颈 |

### 1.2 Worker 抽象 — `ObWorker` / `Runnable`

OB 没有统一的 `ObWorker` 基类, 而是采用**约定**模式:

```cpp
class ObRunnable {
public:
  virtual ~ObRunnable() = default;
  virtual void run1() = 0;        // 线程入口 (pthread fn)
  virtual int64_t get_id() const = 0;
};
```

不同 Worker 用不同方式实现:

| 实现 | 用法 | 示例 |
|------|------|------|
| 继承 `ObRunnable` | 显式 run1() | `ObOccamThread` (ob_occam_thread_pool.h) |
| 传入 `function<void()>` | 闭包 | `ObOccamThread::init_and_start([func])` |
| 继承 `share::ObThreadPool` | 复用 pool 框架 | `ObOccamThread` 内部 |
| 自身就是 pool | `ObPxWorker` 的 3 种实现 | `ObPxRpcWorker` / `ObPxCoroWorker` / `ObPxThreadWorker` |

### 1.3 Worker 调度模型 — 同步 vs 异步 vs 协程

| 模型 | Worker 类型 | 调度方式 |
|------|------------|---------|
| **同步 pthread** | 老派 Worker (e.g. `ObDbmsScheduler`) | 1 request / 1 thread |
| **异步 pool** | `ObOccamThreadPool` / `ObThreadPool` | 多 request / N thread, 队列分发 |
| **协程 pool** | `ObOccamThreadPool` (C++20 coroutine) | 多 request / N thread, 协程切换 |
| **RPC-driven** | `ObPxRpcWorker` | RPC 框架即 Worker (复用 RPC 线程) |
| **Coro-driven** | `ObPxCoroWorker` | C++20 协程 (新) |
| **Thread-driven** | `ObPxThreadWorker` | 独立 pthread (旧) |

---

## 2. 实现细节 — Worker Processor (dispatch)

### 2.1 `ObWorkerProcessor` — RPC Request → Worker 分发

[`src/observer/omt/ob_worker_processor.h`](src/observer/omt/ob_worker_processor.h):

```cpp
class ObWorkerProcessor {
public:
  ObWorkerProcessor(rpc::frame::ObReqTranslator &xlator,
                    const common::ObAddr &myaddr);

  // 线程生命周期回调 (thread_local)
  virtual void th_created();       // 线程创建时调 (set tenant ctx / trace)
  virtual void th_destroy();       // 线程销毁时调

  // 处理 RPC request
  virtual int process(rpc::ObRequest &req);

private:
  int process_one(rpc::ObRequest &req);
  // ...
private:
  rpc::frame::ObReqTranslator &translator_;
  const common::ObAddr &myaddr_;
};
```

**`ObWorkerProcessor::process`** — 分发 RPC:

```cpp
// src/observer/omt/ob_worker_processor.cpp: process()
int ObWorkerProcessor::process(rpc::ObRequest &req) {
  // 1. 解析 request, 找对应 handler (见 #108)
  rpc::frame::ObReqTranslator::handle h = translator_.get_handler(req.get_pcode());
  if (h == NULL) return OB_ERR_UNEXPECTED;

  // 2. 调 handler (可能在当前 IO 线程, 也可能 dispatch 到 worker pool)
  h->callback_(req);

  // 3. 写回 response
  // ...
  return OB_SUCCESS;
}
```

**`th_created()` / `th_destroy()`** — thread_local 初始化:

```cpp
void ObWorkerProcessor::th_created() {
  // 1. 设置 tenant context (thread_local)
  // (让 MTL_*() 系列宏能拿到当前 tenant)
  share::ObThreadPool::set_run_wrapper(MTL_CTX());
  // 2. 设置 thread name (e.g. "ob_worker_5")
  lib::set_thread_name(...);
  // 3. trace context (继承自 RPC req)
  // ...
}
```

### 2.2 `ObThWorker` — Tenant-Thread Worker

[`src/observer/omt/ob_th_worker.{h,cpp}`](src/observer/omt/ob_th_worker.h):

```cpp
class ObThWorker : public share::ObThreadPool {
public:
  int init(int64_t thread_count);
  int start();
  void stop();
  void wait();
  void destroy();

  // 提交 task (push 到队列)
  int push(ObLink *task, int32_t level, int32_t prio);
  int try_pop(ObLink *&task, int32_t level, int64_t timeout_us);

private:
  // 多级队列 (不同优先级)
  ObMultiLevelQueue queues_;
};
```

**关键设计**:

- 继承 `ObThreadPool` (传统 pthread 池, 见 #110)
- `ObMultiLevelQueue` 是多级反馈队列 (priority + level)
- `push` 提交任务, 队列满则按策略丢弃或阻塞

### 2.3 `ObMultiLevelQueue` — 多级反馈队列

[`src/observer/omt/ob_multi_level_queue.h`](src/observer/omt/ob_multi_level_queue.h):

```cpp
#define MULTI_LEVEL_QUEUE_SIZE (10)
#define MULTI_LEVEL_THRESHOLD (2)
#define GROUP_MULTI_LEVEL_THRESHOLD (1)

class ObMultiLevelQueue {
public:
  void set_limit(const int64_t limit);
  int push(rpc::ObRequest &req, const int32_t level, const int32_t prio);
  int pop(common::ObLink *&task, const int32_t level, const int64_t timeout_us);
  int try_pop(common::ObLink *&task, const int32_t level);
  int64_t get_size(const int32_t level) const;
  int64_t get_total_size() const;

private:
  common::ObPriorityQueue<1> queue_[MULTI_LEVEL_QUEUE_SIZE];  // 10 个 level
};
```

**多级反馈算法**:

```
        ┌─────────────────┐
        │ level 0 (最高) │ ← DDL / 高优先级
        └─────────────────┘
              ↓ (积压超过 threshold)
        ┌─────────────────┐
        │ level 1         │ ← 高优 DML
        └─────────────────┘
              ↓
        ┌─────────────────┐
        │ level 2         │
        └─────────────────┘
              ↓
        ...
        ┌─────────────────┐
        │ level 9 (最低) │ ← 后台任务
        └─────────────────┘
```

- 每级有独立 queue (内部是 `ObPriorityQueue<1>` = priority queue)
- 高优先级 task 在低 level; 积压后**自动降级** (从 level 0 → level 1)
- worker pop 时**优先高 level** (公平 + 优先级)

### 2.4 `ObTenantTaskQueue` — Tenant 隔离队列

```cpp
// src/observer/omt/ob_tenant_task_queue.h
class ObTenantTaskQueue {
public:
  int push(uint64_t tenant_id, ObLink *task, int32_t prio);
  int pop(uint64_t tenant_id, ObLink *&task, int64_t timeout_us);
};
```

**关键设计**:

- **每个租户独立队列** (防止某个租户压垮整个系统)
- 跨租户**公平调度** (round-robin)
- 租户资源耗尽 → 直接拒绝 (类似 503)

---

## 3. 实现细节 — PX Worker (并行 SQL 执行)

### 3.1 PX Worker 三种实现

[`src/sql/engine/px/ob_px_worker.h`](src/sql/engine/px/ob_px_worker.h):

```cpp
class ObPxWorkerRunnable {
public:
  virtual int run(ObPxRpcInitTaskArgs &arg) = 0;
};

// 用 RPC 工作线程作为 PX Worker
class ObPxRpcWorker : public ObPxWorkerRunnable {
public:
  ObPxRpcWorker(const observer::ObGlobalContext &gctx,
                obrpc::ObPxRpcProxy &rpc_proxy,
                common::ObIAllocator &alloc);
  virtual ~ObPxRpcWorker();
  int run(ObPxRpcInitTaskArgs &arg);
private:
  const observer::ObGlobalContext &gctx_;
  obrpc::ObPxRpcProxy &rpc_proxy_;
  common::ObIAllocator &alloc_;
  ObPxRpcInitTaskResponse resp_;
};

// 用 C++20 协程作为 PX Worker
class ObPxCoroWorker : public ObPxWorkerRunnable {
public:
  ObPxCoroWorker(const observer::ObGlobalContext &gctx,
                 common::ObIAllocator &alloc);
  virtual ~ObPxCoroWorker() = default;
  int run(ObPxRpcInitTaskArgs &arg);
  int exit();
private:
  const observer::ObGlobalContext &gctx_;
  common::ObIAllocator &alloc_;
  sql::ObDesExecContext exec_ctx_;
  sql::ObPhysicalPlan phy_plan_;
  ObPxRpcInitTaskArgs task_arg_;
  ObPxTaskProcess task_proc_;
  uint64_t task_co_id_;
};

// 用独立 pthread 作为 PX Worker
class ObPxThreadWorker : public ObPxWorkerRunnable {
public:
  ObPxThreadWorker(const observer::ObGlobalContext &gctx);
  virtual ~ObPxThreadWorker();
  int run(ObPxRpcInitTaskArgs &arg);
private:
  // ...
};
```

**三种对比**:

| 实现 | 线程模型 | 调度方式 | 适用场景 |
|------|---------|---------|---------|
| **ObPxRpcWorker** | 复用 RPC worker thread | RPC 驱动 | 默认 / 多数情况 |
| **ObPxCoroWorker** | C++20 coroutine | 协程切换 | 高并发 / 4.x 新推 |
| **ObPxThreadWorker** | 独立 pthread | 一请求一线程 | 调试 / 低并发 |

**ObPxRpcWorker** — RPC 驱动 (默认):

```cpp
int ObPxRpcWorker::run(ObPxRpcInitTaskArgs &arg) {
  // 1. 反序列化 arg
  resp_.reset();
  // 2. 调用 PX task 执行
  task_proc_.process(arg, resp_);
  // 3. RPC response 自动由 RPC 框架写回
  // (当前线程就是 RPC handler 线程, 直接用 resp_)
  return OB_SUCCESS;
}
```

**ObPxCoroWorker** — 协程:

```cpp
int ObPxCoroWorker::run(ObPxRpcInitTaskArgs &arg) {
  // 1. 协程初始化
  task_co_id_ = co_self();
  // 2. 深拷贝 arg (因为协程 yield 后 arg 会被释放)
  deep_copy_assign(arg, task_arg_);
  // 3. 在协程中执行 task
  return task_proc_.process(task_arg_, resp_);
}
```

**关键设计**: PX Worker **不是常驻线程**, 而是**任务来了就 run**, run 完就释放 (RPC thread / 协程 / pthread 都是借的)。

### 3.2 `ObPxWorkerStat` — PX Worker 监控

```cpp
// src/sql/engine/px/ob_px_worker_stat.h
class ObPxWorkerStat {
public:
  // 原子计数器 (跟 #103 Counter 连接)
  easy_atomic_t running_task_cnt_;
  easy_atomic_t finished_task_cnt_;
  easy_atomic_t failed_task_cnt_;
  easy_atomic_t timeout_task_cnt_;

  int64_t get_running() const { return ATOMIC_LOAD(&running_task_cnt_); }
  // ...
};
```

监控表 `__all_virtual_px_worker_stat` 暴露这些统计 (用于排查 PX 并发瓶颈)。

---

## 4. 实现细节 — RootServer Worker

### 4.1 `ObDisasterRecoveryWorker` — 容灾恢复 Worker

[`src/rootserver/ob_disaster_recovery_worker.{h,cpp}`](src/rootserver/ob_disaster_recovery_worker.h):

```cpp
class ObDisasterRecoveryWorker : public share::ObThreadPool {
public:
  int init(int64_t thread_count = 1);  // 默认 1 线程
  int start();
  void run1();  // 线程入口
private:
  // 定时任务: 检查副本, 触发恢复
  void do_disaster_recovery_check();
};
```

**职责**:

- 检查所有副本状态 (F / L / R)
- 副本缺失 → 触发补副本
- 副本错误 → 触发切主 (跟 #26 选主 / failover 连接)
- 定期跑 (e.g. 每 5s)

### 4.2 各种 RootServer Scheduler

[`src/rootserver/{freeze,backup,restore,ddl_task,tenant_snapshot,compaction_ttl}/`](src/rootserver):

| Scheduler | 文件 | 职责 |
|-----------|------|------|
| `ObMajorMergeScheduler` | `freeze/ob_major_merge_scheduler.{h,cpp}` | 触发每日合并 (Major Freeze) |
| `ObBackupDataScheduler` | `backup/ob_backup_data_scheduler.{h,cpp}` | 全量备份调度 |
| `ObBackupTaskScheduler` | `backup/ob_backup_task_scheduler.{h,cpp}` | 备份子任务调度 |
| `ObBackupValidateScheduler` | `backup/ob_backup_validate_scheduler.{h,cpp}` | 备份校验 |
| `ObBackupCleanScheduler` | `backup/ob_backup_clean_scheduler.{h,cpp}` | 备份清理 |
| `ObArchiveSchedulerService` | `backup/ob_archive_scheduler_service.{h,cpp}` | 归档调度 (clog → OSS) |
| `ObTenantArchiveScheduler` | `backup/ob_tenant_archive_scheduler.{h,cpp}` | 租户级归档 |
| `ObRestoreScheduler` | `restore/ob_restore_scheduler.{h,cpp}` | 恢复调度 |
| `ObCloneScheduler` | `restore/ob_clone_scheduler.{h,cpp}` | 克隆调度 |
| `ObImportTableJobScheduler` | `restore/ob_import_table_job_scheduler.{h,cpp}` | 导入表调度 |
| `ObRecoverTableJobScheduler` | `restore/ob_recover_table_job_scheduler.{h,cpp}` | recover table 调度 |
| `ObDdlScheduler` | `ddl_task/ob_ddl_scheduler.{h,cpp}` | DDL 调度 |
| `ObDdlTabletScheduler` | `ddl_task/ob_ddl_tablet_scheduler.{h,cpp}` | DDL tablet 级调度 |
| `ObTenantSnapshotScheduler` | `tenant_snapshot/ob_tenant_snapshot_scheduler.{h,cpp}` | 租户快照 |
| `ObTenantCompactionTtlScheduler` | `compaction_ttl/ob_tenant_compaction_ttl_scheduler.{h,cpp}` | TTL 触发合并 |

**共同模式**:

```cpp
class ObXxxScheduler : public share::ObThreadPool {
public:
  int init(int64_t thread_count = 1);
  int start();
  void run1();  // 线程入口
private:
  // 1. 定时跑
  void do_schedule();
  // 2. 调度任务 (push 到具体 worker)
  int schedule_task(...);
};
```

### 4.3 `ObDbmsScheduler` — DBMS_JOBS 调度

[`src/pl/sys_package/ob_dbms_scheduler.{h,cpp}`](src/pl/sys_package/ob_dbms_scheduler.h):

```cpp
class ObDbmsScheduler {
public:
  // 注册 job
  int create_job(...);
  // 提交 job (按 schedule)
  int submit_job(uint64_t job_id, const ObString &action);
private:
  // job queue + thread pool
  share::ObThreadPool thread_pool_;
  // job 信息 (从系统表加载)
  // ...
};
```

**对应系统表**:

- `__all_virtual_dbms_scheduler_jobs`
- `__all_virtual_dbms_scheduler_running_job`

**用法**:

```sql
CALL DBMS_SCHEDULER.CREATE_JOB(
  job_name => 'my_job',
  job_type => 'PLSQL_BLOCK',
  job_action => 'BEGIN ... END;',
  repeat_interval => 'FREQ=DAILY;BYHOUR=2',
  enabled => TRUE
);
```

### 4.4 `ObMajorMergeScheduler` — Major Freeze 调度 (关键)

[`src/rootserver/freeze/ob_major_merge_scheduler.{h,cpp}`](src/rootserver/freeze/ob_major_merge_scheduler.h):

```cpp
class ObMajorMergeScheduler {
public:
  // 触发全局 major freeze
  int trigger_global_major_freeze();
  // 触发租户 major freeze
  int trigger_tenant_major_freeze(uint64_t tenant_id);
  // 调度循环
  void schedule_loop();
};
```

**调度流程**:

```
1. 定时器触发 (e.g. 每天 02:00)
2. trigger_global_major_freeze()
   → 检查所有租户是否空闲 (无长事务)
   → 是 → 发命令给所有 observer, freeze memtable
3. observer 收到命令
   → freeze memtable → 触发合并 (ObMergeWorker)
4. 合并完成 → 通知 RS
5. RS 继续下一批租户
```

---

## 5. 实现细节 — TX / GC Worker

### 5.1 `ObTxLoopWorker` — 事务循环 Worker

[`src/storage/tx/ob_tx_loop_worker.{h,cpp}`](src/storage/tx/ob_tx_loop_worker.h):

```cpp
class ObTxLoopWorker : public share::ObThreadPool {
public:
  int init(int64_t thread_count);
  int start();
  void run1();
private:
  // 主循环: 处理 tx timeout / GC 等
  void tx_loop_main();
  // tx 超时检查
  void check_tx_timeout();
  // tx GC (回收已结束的 tx ctx)
  void gc_tx_ctx();
};
```

**职责**:

- 定期检查事务超时 (e.g. 100s 内未 commit 则 rollback)
- 回收已结束的 transaction context (防止内存泄漏)
- 跟 #11 事务管理连接

### 5.2 `ObTsWorker` — Timestamp Service Worker

[`src/storage/tx/ob_ts_worker.{h,cpp}`](src/storage/tx/ob_ts_worker.h):

```cpp
class ObTsWorker {
public:
  int init(int64_t thread_count = 1);
  int start();
  void run1();
private:
  // GTS (Global Timestamp Service) 拉取
  void pull_gts();
  // 本地 ts 推进 (跟 #103 ObClockGenerator 连接)
  void advance_local_ts();
};
```

**职责**:

- 从 GTS (基于 HLC, 见 #38) 拉取 ts
- 推进本地 `cur_ts_` (防止 ts 倒流)
- 跟 #103 ClockGenerator 模式连接 (BCAS 推进 cur_ts_)

### 5.3 `ObXaTransHeartbeatWorker` — XA 事务心跳

[`src/storage/tx/ob_xa_trans_heartbeat_worker.{h,cpp}`](src/storage/tx/ob_xa_trans_heartbeat_worker.h):

```cpp
class ObXaTransHeartbeatWorker : public share::ObThreadPool {
public:
  int init(int64_t thread_count = 1);
  void run1();
private:
  // 检查所有 XA 事务, 给 coordinator 发心跳
  void heartbeat_xa_trans();
};
```

### 5.4 `ObXaInnerTableGcWorker` — XA 内部表 GC

[`src/storage/tx/ob_xa_inner_table_gc_worker.{h,cpp}`](src/storage/tx/ob_xa_inner_table_gc_worker.h):

```cpp
class ObXaInnerTableGcWorker : public share::ObThreadPool {
public:
  void run1();
private:
  // GC 过期 XA 事务记录 (从内部表删除)
  void gc_xa_records();
};
```

---

## 6. 实现细节 — Log / Replay Worker

### 6.1 `ObLogIoWorker` — Palf IO Worker (关键)

[`src/logservice/palf/log_io_worker.{h,cpp}`](src/logservice/palf/log_io_worker.h):

```cpp
class ObLogIoWorker {
public:
  // 异步 append log (提交到 worker, 不阻塞 caller)
  int append(ObLogEntry &entry, AppendCb cb);
  // worker 主循环
  void run1();
private:
  // 批量 append (攒批优化)
  int batched_append();
  // 写盘 (write + fdatasync)
  int write_to_disk();
};
```

**关键设计**:

- **攒批** (batch) — 把多个小 append 合成一次 write
- **异步 callback** — caller 不阻塞
- 跟 #22 clog / Redo Log 连接

### 6.2 `ObLogIoWorkerWrapper` — Palf IO Worker 包装

[`src/logservice/palf/log_io_worker_wrapper.{h,cpp}`](src/logservice/palf/log_io_worker_wrapper.h):

```cpp
class ObLogIoWorkerWrapper {
public:
  int init(int64_t palf_count, int64_t worker_per_palf);
  // 获取特定 palf 的 worker
  ObLogIoWorker *get_worker(int palf_idx);
  // 提交任务
  int submit(int palf_idx, ObLogEntry &entry, AppendCb cb);
};
```

**为什么需要 wrapper**:

- OB 有多个 palf 实例 (每个 LS 一个)
- 每个 palf 一个 worker 集合
- wrapper 统一管理 + 路由

### 6.3 `ObArchiveWorker` — 归档 Worker

[`src/logservice/archiveservice/ob_archive_worker.{h,cpp}`](src/logservice/archiveservice/ob_archive_worker.h):

```cpp
class ObArchiveWorker : public share::ObThreadPool {
public:
  void run1();
private:
  // 拉 clog, 上传到 OSS / NFS
  void do_archive();
};
```

### 6.4 `ObLsWorker` (logfetcher) — 日志拉取 Worker

[`src/logservice/logfetcher/ob_ls_worker.{h,cpp}`](src/logservice/logfetcher/ob_ls_worker.h):

```cpp
class ObLsWorker {
public:
  int init(uint64_t ls_id, const ObLogFetcherCtx *ctx);
  void run1();
private:
  // 拉取上游日志 (从 primary / standby)
  void fetch_log();
  // 解析 clog entry
  void parse_log_entry();
  // 推给下游 (replay)
  void push_log_to_replay();
};
```

**职责**:

- 拉取上游日志 (从 leader 或 standby)
- 解析 clog entry
- 推给 replay worker (见 6.7)
- 跟 #33 Backup/Recovery + #26 Failover 连接

### 6.5 `ObRemoteFetchLogWorker` — 远程日志拉取 Worker

[`src/logservice/restoreservice/ob_remote_fetch_log_worker.{h,cpp}`](src/logservice/restoreservice/ob_remote_fetch_log_worker.h):

```cpp
class ObRemoteFetchLogWorker : public share::ObThreadPool {
public:
  void run1();
private:
  // 从远程拉取日志 (恢复场景)
  void fetch_log_from_remote();
};
```

**用法**: 恢复 / 重建副本时, 从远程 (OSS / 其他 observer) 拉日志。

### 6.6 `ObLogFetcherBgWorker` — 日志拉取后台 Worker

[`src/logservice/logfetcher/ob_log_fetcher_bg_worker.{h,cpp}`](src/logservice/logfetcher/ob_log_fetcher_bg_worker.h):

```cpp
class ObLogFetcherBgWorker : public share::ObThreadPool {
public:
  void run1();
private:
  // 后台调度: 心跳 / 限流 / 状态汇报
  void bg_main();
};
```

### 6.7 `ObReplayHandler` — Replay Handler (Worker)

[`src/logservice/replayservice/ob_replay_handler.{h,cpp}`](src/logservice/replayservice/ob_replay_handler.h):

```cpp
class ObReplayHandler : public share::ObThreadPool {
public:
  void run1();
private:
  // replay clog entry (应用到 memtable)
  void replay_log_entry(ObLogEntry &entry);
};
```

**关键设计**:

- replay 是单线程 (per-LS), 保证顺序
- 跟 #22 clog 连接 (clog entry → memtable mutation)

---

## 7. 实现细节 — Storage / Other Worker

### 7.1 `ObDirectLoadMemWorker` — Direct Load 内存 Worker

[`src/storage/direct_load/ob_direct_load_mem_worker.{h,cpp}`](src/storage/direct_load/ob_direct_load_mem_worker.h):

```cpp
class ObDirectLoadMemWorker {
public:
  // 接收 direct load 数据 (e.g. load data infile)
  int append(const ObDirectLoadDatumRow &row);
  // flush 到磁盘
  int flush();
};
```

**direct load 场景**: `LOAD DATA` / 旁路导入 (绕过 SQL)

### 7.2 `ObReplayStatus` — Replay 状态机

[`src/logservice/replayservice/ob_replay_status.{h,cpp}`](src/logservice/replayservice/ob_replay_status.h):

```cpp
class ObReplayStatus {
public:
  // 状态 (跟 #104 BCAS 状态机连接)
  enum State { INIT, REPLAYING, SYNC, CATCHUP };
  bool cas_state(State expected, State new_state);
};
```

---

## 8. 实现细节 — Worker 生命周期 / 异常处理

### 8.1 Worker 启动流程

```cpp
// 典型 Worker 启动 (e.g. ObMajorMergeScheduler)
int ObMajorMergeScheduler::init() {
  // 1. 创建线程池
  // (默认 1 个线程, 见 §4.2)
  thread_pool_.init(1);
  thread_pool_.start();
  return OB_SUCCESS;
}

void ObMajorMergeScheduler::start() {
  // 启动定时器 (e.g. 每 60s 跑一次 schedule_loop)
  timer_.start(60 * 1000 * 1000, [this]() { this->schedule_loop(); });
}
```

### 8.2 Worker 主循环模板

```cpp
void ObXxxWorker::run1() {
  lib::set_thread_name("ObXxxWorker");

  while (!ATOMIC_LOAD(&stop_)) {
    // 1. 等待任务 (阻塞)
    task_t *t = nullptr;
    queue_.pop(t, /* timeout_us */ 1000 * 1000);  // 1s 超时

    if (t != nullptr) {
      // 2. 处理任务
      int ret = process_task(*t);
      if (OB_FAIL(ret)) {
        LOG_WARN("process task failed", K(ret));
        // 3. 异常处理 (不退出, 继续处理下一个)
        ATOMIC_INC(&error_count_);
      }
    }
  }

  // 退出清理
  cleanup();
}
```

### 8.3 Worker 优雅退出

```cpp
void ObXxxWorker::stop() {
  ATOMIC_STORE(&stop_, true);
  // 唤醒正在 wait 的线程
  queue_.broadcast();
}

void ObXxxWorker::wait() {
  thread_pool_.wait();
  // 所有线程已 join
}
```

### 8.4 Worker 异常处理 / failover

| 异常类型 | 处理 |
|---------|------|
| 单个 task 失败 | log + 跳过, 不退出 Worker |
| Worker 线程崩溃 | 全局监控 `__all_virtual_worker_stat` 发现并报警 |
| Worker 整体 hang | watchdog 监控 + 强制重启 observer |
| task 积压 | 监控队列长度, 超过阈值告警 |

---

## 9. 性能

### 9.1 Worker 启动 / 停止延迟

| Worker | 启动延迟 | 停止延迟 |
|--------|---------|---------|
| `ObPxRpcWorker` | < 1 ms (复用 RPC 线程) | < 1 ms |
| `ObPxCoroWorker` | ~5 ms (协程创建) | < 1 ms |
| `ObPxThreadWorker` | ~50 ms (pthread 创建) | ~50 ms (pthread join) |
| `ObMajorMergeScheduler` | ~50 ms | ~50 ms |
| `ObLogIoWorker` | ~50 ms | ~50 ms |

### 9.2 Worker 内存占用

| Worker | 内存 |
|--------|------|
| `ObPxRpcWorker` | ~0 (复用 RPC 线程) |
| `ObPxCoroWorker` | ~4 KB (协程栈) |
| `ObPxThreadWorker` | ~8 MB (pthread 栈) |
| `ObLogIoWorker` | ~10 MB (批 buffer) |
| `ObArchiveWorker` | ~50 MB (大块读) |

### 9.3 Worker 数量建议

| 场景 | Worker 数量 |
|------|------------|
| RootServer scheduler | 每种 1 个线程 (共 ~20) |
| PX Worker | 跟 RPC 线程数一致 |
| LogIoWorker | 每个 palf 1-2 个 (palfs 数 = LS 数) |
| DirectLoad | 跟并发 load 数一致 |

---

## 10. v2 连接

| 文章 | 关联点 |
|------|--------|
| #24 PX Framework | #24 是概览, 本篇深入 Worker 实现 |
| #103 atomic | `running_task_cnt_` / `error_count_` 等是 Counter 模式 |
| #104 atomic Flag | `ObReplayStatus::state_` 是 BCAS 状态机 |
| #107 libeasy | libeasy 的 `easy_thread_pool_t` 是 Worker pool 的简化版 |
| #108 easy_io/obrpc | obrpc handler 调度走 `ObWorkerProcessor` |
| #110 (Worker 下篇) | Worker pool 模型 (ObThreadPool / ObOccamThreadPool) |

---

## 11. 调优 Checklist

### 11.1 Worker 线程数

```bash
# PX Worker (跟 RPC 线程数对齐)
px_worker_count = rpc_worker_count = min(NCPU * 2, 32)

# RootServer Scheduler (默认 1 个线程)
major_merge_scheduler_threads = 1
backup_scheduler_threads = 1
ddl_scheduler_threads = 1

# LogIoWorker (每个 palf 1-2 个)
log_io_workers_per_palf = 2

# TX Worker
tx_loop_worker_threads = 2
ts_worker_threads = 1
```

### 11.2 Worker 队列大小

```bash
# multi_level_queue limit
multi_level_queue_limit = 10000   # 每级 10000, 共 10 级
```

### 11.3 Worker 超时

```bash
# task 处理超时报警
worker_task_timeout_ms = 30000  # 30s

# Worker 整体 hang 报警 (通过 watchdog)
worker_hang_timeout_ms = 60000  # 60s
```

---

## 12. 故障 case

### 12.1 PX Worker hang

**症状**: PX 并行 SQL 卡住, 不返回

**原因**:

- PX Worker 借用的 RPC 线程卡死
- 协程 (ObPxCoroWorker) 死锁
- task 内部等待 (e.g. 等另一 RPC 响应)

**排查**:

```sql
-- 看 PX Worker 状态
SELECT * FROM oceanbase.__all_virtual_px_worker_stat
WHERE svr_ip = '<ip>' AND svr_port = <port>;

-- 看正在跑的 PX task
SELECT * FROM oceanbase.__all_virtual_session
WHERE type = 'PX_WORKER';
```

**解决**:

- 调小 `worker_task_timeout_ms` (强制超时)
- 排查 task 卡死原因 (gdb stack)
- 切回 `ObPxRpcWorker` (更稳定)

### 12.2 RootServer Scheduler 卡死

**症状**: Major Freeze / 备份 / DDL 不执行

**原因**:

- Scheduler 线程死锁
- 调度任务执行时间过长 (e.g. 大表 DDL)
- RS 整体 hang

**排查**:

```bash
# 看 RS 线程
gdb -p <rs_pid> -ex "thread apply all bt" -batch
```

**解决**:

- 重启 RS (observer)
- 调大 `rs_worker_thread_count`
- 排查具体 scheduler (gdb attach)

### 12.3 LogIoWorker 积压

**症状**: clog 写入慢, 影响事务性能

**原因**:

- disk IO 慢 (高 iowait)
- Worker 线程数不够
- 单个 palf 写入过于频繁

**排查**:

```bash
# 看 LogIoWorker 队列
SELECT * FROM oceanbase.__all_virtual_log_io_stat;
# queue_size > 1000 → 积压
```

**解决**:

- 调大 `log_io_workers_per_palf`
- 检查 disk (iostat -x)
- 减少 clog 写入频率 (大事务拆分)

### 12.4 Replay Worker 落后

**症状**: Standby 副本落后主副本很久

**原因**:

- Replay Worker 单线程, 性能瓶颈
- 网络拉取慢 (从主副本拉 clog 慢)
- 主副本写入压力大

**排查**:

```bash
# 看 replay 落后程度
SELECT * FROM oceanbase.__all_virtual_log_replay_status;
# replay_lsn - upstream_lsn → 落后量
```

**解决**:

- 调大 replay 资源 (CPU)
- 检查网络 (跟主副本之间的 RTT)
- 主副本减少大事务 (拆分小事务)

---

## 13. 源码锚点 (grep)

```bash
# ObWorkerProcessor
grep -n "ObWorkerProcessor::process\|th_created\|th_destroy" \
  src/observer/omt/ob_worker_processor.{h,cpp}

# ObThWorker + ObMultiLevelQueue
grep -n "ObThWorker::push\|ObMultiLevelQueue\|MULTI_LEVEL_QUEUE_SIZE" \
  src/observer/omt/ob_th_worker.{h,cpp} \
  src/observer/omt/ob_multi_level_queue.h

# PX Worker 三种实现
grep -n "ObPxRpcWorker\|ObPxCoroWorker\|ObPxThreadWorker\|ObPxWorkerRunnable" \
  src/sql/engine/px/ob_px_worker.h

# RootServer Scheduler
grep -rn "ObMajorMergeScheduler\|ObBackup.*Scheduler\|ObDdlScheduler\|ObRestoreScheduler" \
  src/rootserver/

# TX Worker
grep -n "ObTxLoopWorker\|ObTsWorker\|ObXaTransHeartbeatWorker" \
  src/storage/tx/

# Log / Replay Worker
grep -n "ObLogIoWorker\|ObArchiveWorker\|ObLsWorker\|ObReplayHandler" \
  src/logservice/

# Direct Load Worker
grep -n "ObDirectLoadMemWorker" \
  src/storage/direct_load/

# DBMS Scheduler
grep -n "ObDbmsScheduler\|DBMS_SCHEDULER" \
  src/pl/sys_package/
```

---

## 14. Cross-cutting

| 主题 | 关联点 |
|------|--------|
| atomic | `running_task_cnt_` / `error_count_` 是 #103 Counter;`ObReplayStatus::state_` 是 #104 BCAS |
| 内存 | Worker 的 `ObLink *task` 用 #25 内存管理 |
| 线程 | Worker pool 跟 #110 `ObThreadPool` / `ObOccamThreadPool` 深度连接 |
| RPC | obrpc handler 调度走 `ObWorkerProcessor` (见 #108) |
| 网络 | Worker 内部 RPC 调用走 obrpc (见 #108) |
| 调度 | Scheduler (e.g. `ObMajorMergeScheduler`) 跟 #20 Compaction + #21 DDL 连接 |
| 容灾 | `ObDisasterRecoveryWorker` 跟 #26 Failover 连接 |
| 监控 | `__all_virtual_*_stat` 视图给每个 Worker 暴露监控点 |

---

## 15. 总结

OB 内部有 **~40 个 Worker 类**, 按业务分:

- **PX Worker** (3 种) — 并行 SQL 执行, 容器可选 (RPC 线程 / 协程 / pthread)
- **RootServer Scheduler** (~20 种) — Major Freeze / Backup / DDL / Restore / Clone 等
- **TX Worker** (4 种) — 事务超时 / GTS / XA 心跳 / XA GC
- **Log / Replay Worker** (5 种) — Palf IO / 归档 / 日志拉取 / Replay
- **Storage Worker** — Direct Load 内存
- **DBMS Scheduler** — DBMS_JOBS 调度

**关键设计**:

- **Worker 抽象不统一**, 采用约定模式 (`run1()` + `start()` + `stop()`)
- **每个 Worker 独立线程池**, 隔离性 + 可观测性
- **PX Worker 借用 RPC 线程 / 协程**, 不额外创建线程
- **Scheduler 是 1-thread pool**, 不重, 周期性调度
- **状态机用 BCAS** (`ObReplayStatus` 跟 #104 连接)

**OB 4.x 演进**:

- `ObPxCoroWorker` (C++20 coroutine) 替代 `ObPxThreadWorker`
- Worker 池化 (从独立 pthread 改 `ObOccamThreadPool`)
- 协程支持越来越多业务

---

## 16. 后续可扩展方向

1. **`ObOccamThreadPool` vs `ObThreadPool` 详细对比** — 见 #110
2. **PX Worker 三种实现完整 benchmark** — RPC vs Coro vs Thread 在 OB 真实负载下的性能
3. **Scheduler 通用框架** — 能否提取 `ObSchedulerBase` 统一 20+ 种 Scheduler?
4. **Worker 监控体系** — `__all_virtual_*_stat` 完整剖析 + 自定义告警规则
5. **Worker failover** — 某个 Worker 挂了如何自动恢复? (目前是手动重启 observer)
6. **C++20 coroutine 在 OB 的演进** — 哪些路径切到协程? 收益多大?
7. **多租户 Worker 隔离** — `ObTenantTaskQueue` 完整剖析 + 资源公平调度
8. **`ObReplayHandler` replay 流程** — clog → memtable mutation 的完整链路