# 13 — Clog 日志子系统 — 从 PALF 到存储的回放路径

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前文（11 — PALF）介绍了 OceanBase 基于 Paxos 的一致性日志复制框架（`PalfHandleImpl`），前文（12 — Election）介绍了其中的选主机制。但 Paxos 只负责"日志被多数派提交"，并不关心日志的**内容含义**——日志如何从 PALF 的 commit 点高效地应用到存储引擎的 Memtable 和 Tablet，这正是 **Clog 子系统**的职责。

在 OceanBase 的架构中，不存在一个名为"Clog"的独立模块或目录。Clog（Commit Log）泛指**一切通过 PALF 提交后被应用到存储层的日志**。Clog 子系统是 **LogService 层与 Storage 层之间的桥接**，包含了以下关键组件：

| 组件 | 层级 | 职责 |
|------|------|------|
| `ObReplayHandler` | LogService | 按 `ObLogBaseType` 分发日志到各子处理器 |
| `ObLogReplayService` | LogService | 从 PALF 读取日志并派发到 replay handler |
| `ObLSStorageClogHandler` | Storage | LogStream 的存储层日志回放入口 |
| `ObLSTxService::replay()` | Storage | 事务日志回放入口，转发到 ObTxReplayExecutor |
| `ObTxReplayExecutor` | Transaction | 事务日志反序列化与 Memtable 回放 |
| `ObRedoLogGenerator` | Memtable | 写路径上的 Redo Log 生成 |
| `ObLogApplyService` | LogService | PALF 提交回调的分发（AppendCb → callback） |
| `ObLogFetcher` | LogService | 多副本间日志的 catch-up 拉取 |

### Clog 在整个 OceanBase 架构中的位置

```
SQL Layer → Transaction Layer (2PC) → PALF → │Clog子系统│ → Storage Layer
                                               │           │
                                               │ 写入路径： │
                                               │  RedoLogGenerator → PALF propose
                                               │           │
                                               │ 回放路径： │
                                               │  PALF commit → ObLogReplayService
                                               │    → ObReplayHandler → ObLSStorageClogHandler
                                               │    → ObLSTxService → ObTxReplayExecutor
                                               │    → Memtable replay
                                               │           │
                                               │ 回调路径： │
                                               │  PALF commit → AppendCb → ObLogApplyService
                                               │    → MVCC Callback → 事务 Commit
```

回放路径是 **Clog 子系统最核心的逻辑**。当节点宕机恢复、或者 Follower 追赶 Leader 时，PALF 中已经提交的日志需要被重新应用到存储引擎，使 Memtable 恢复宕机前的事务状态。

---

## 1. 日志类型体系

### 1.1 日志基础类型：`ObLogBaseType`

`ob_log_base_type.h`（@L30-L70）定义了一级日志类型枚举，共超过 60 种。每种日志类型对应一个独立的 replay 子处理器。

关键类型：

| 枚举值 | 值 | 用途 | 注册到的 Handler |
|--------|---|------|-----------------|
| `TRANS_SERVICE_LOG_BASE_TYPE` | 1 | 事务日志（Redo, Commit, Abort 等） | ObLSTxService |
| `TABLET_OP_LOG_BASE_TYPE` | 2 | Tablet 操作日志（创建、删除等） | Tablet 相关 |
| `MEDIUM_COMPACTION_LOG_BASE_TYPE` | 18 | 合并范围日志 | ObMediumCompactionClogHandler |
| `MAJOR_FREEZE_LOG_BASE_TYPE` | 10 | 全局冻结日志 | 冻结相关 |
| `DDL_LOG_BASE_TYPE` | 5 | DDL 操作日志 | DDL 相关 |
| `KEEP_ALIVE_LOG_BASE_TYPE` | 6 | 保活日志 | 心跳相关 |

每个 LogStream 的 ObLS 对象维护着这些日志类型的 handler 注册表。

### 1.2 事务日志类型：`ObTxLogType`

`ob_tx_log.h`（@L79-L94）定义了事务层内部的日志类型：

```cpp
// ob_tx_log.h:79-94 - doom-lsp 确认
enum class ObTxLogType : int64_t
{
  UNKNOWN = 0,
  TX_REDO_LOG = 0x1,           // Redo（数据修改）
  TX_ROLLBACK_TO_LOG = 0x2,     // Rollback to savepoint
  TX_MULTI_DATA_SOURCE_LOG = 0x4, // 多数据源
  TX_DIRECT_LOAD_INC_LOG = 0x8,
  TX_BIG_SEGMENT_LOG = 0x40,    // 大字段
  TX_PREPARE_LOG = 0x80,        // 2PC Prepare
  TX_COMMIT_LOG = 0x100,        // 2PC Commit
  TX_ABORT_LOG = 0x200,         // 2PC Abort
  TX_CLEAR_LOG = 0x400,         // 事务清除
  // logstream-level log
  TX_START_WORKING_LOG = 0x100000,  // LogStream 启动工作日志
  // ...
};
```

其中 `TX_REDO_LOG`（0x1）是数据正文——它携带了用户修改的行数据。`TX_PREPARE_LOG`、`TX_COMMIT_LOG`、`TX_ABORT_LOG` 是 2PC 协议的控制日志。`TX_START_WORKING_LOG` 是 LogStream 级别的标记日志，表示一个 LogStream 开始正常服务。

### 1.3 日志基础头部：`ObLogBaseHeader`

`ob_log_base_header.h`（@L42-L72）定义了每条 PALF 日志的第一段元数据：

```cpp
// ob_log_base_header.h:42-72 - doom-lsp 确认
class ObLogBaseHeader {
  // ...
  ObLogBaseType get_log_type() const;     // 日志基础类型
  bool need_pre_replay_barrier() const;   // 回放前是否需要 barrier
  bool need_post_replay_barrier() const;  // 回放后是否需要 barrier
  int64_t get_replay_hint() const;         // 回放提示
  // ...
};
```

`replay_barrier` 机制很重要：某些日志在回放时需要保证前序日志都已回放完成（`pre_barrier`），某些日志在回放后需要等待后续依赖（`post_barrier`）。这保证了日志回放的因果序。

---

## 2. 核心数据结构

### 2.1 `ObReplayHandler` — 日志回放分发器

`ob_replay_handler.h` 定义了回放分发中心：

```cpp
// ob_replay_handler.h - doom-lsp 确认
class ObReplayHandler
{
public:
  int register_handler(const ObLogBaseType &type,
                       ObIReplaySubHandler *handler);
  void unregister_handler(const ObLogBaseType &type);
  int replay(const ObLogBaseType &type,
             const void *buffer, const int64_t nbytes,
             const palf::LSN &lsn, const share::SCN &scn);
private:
  ObIReplaySubHandler *handlers_[ObLogBaseType::MAX_LOG_BASE_TYPE];
  common::RWLock lock_;
};
```

内部维护一个静态数组 `handlers_[MAX_LOG_BASE_TYPE]`，通过 `ObLogBaseType` 作为索引直接定位到对应的 `ObIReplaySubHandler`。`register_handler` / `unregister_handler` 在 LogStream 初始化/销毁时被调用。`ObLS` 中持有此对象：

```cpp
// ob_ls.h:1130 - doom-lsp 确认
logservice::ObReplayHandler replay_handler_;
```

并在初始化时通过宏 `REGISTER_TO_LOGSERVICE`（`ob_log_base_type.h`）注册：

```cpp
// ob_log_base_type.h - 注册宏
#define REGISTER_TO_LOGSERVICE(type, subhandler)                  \
  if (OB_SUCC(ret)) {                                             \
    if (OB_FAIL(replay_handler_.register_handler(type, subhandler))) { \
      LOG_WARN("replay_handler_ register failed", ...);           \
    } else if (OB_FAIL(role_change_handler_.register_handler(...))) { \
      // ...                                                      \
    }                                                             \
  }
```

### 2.2 `ObLSStorageClogHandler` — LogStream 的存储层回放入口

`ob_ls_storage_clog_handler.h`（@L22-L97）定义了三个类，形成多态层级：

```cpp
// ob_ls_storage_clog_handler.h:22-97 - doom-lsp 确认
// 基类 - 实现了 replay() 的反序列化逻辑
class ObLSStorageClogHandler : public ObIReplaySubHandler,
                                public ObIRoleChangeSubHandler,
                                public ObICheckpointSubHandler
{
public:
  // replay 入口：反序列化 ObLogBaseHeader，再调用纯虚函数
  int replay(const void *buffer, const int64_t nbytes,
             const palf::LSN &lsn, const share::SCN &scn) override final;
  // ...
protected:
  virtual int inner_replay(
      const ObLogBaseHeader &base_header, const share::SCN &scn,
      const char *buffer, const int64_t buffer_size, int64_t &pos) = 0;
  ObLS *ls_;
};

// 保留快照日志回放
class ObLSResvSnapClogHandler : public ObLSStorageClogHandler
{
protected:
  virtual int inner_replay(...) override final;
};

// 合并范围日志回放
class ObMediumCompactionClogHandler : public ObLSStorageClogHandler
{
protected:
  virtual int inner_replay(...) override final;
};
```

`replay()` 方法（L35-41，实现在 `ob_ls_storage_clog_handler.cpp`）完成三步工作：

1. **反序列化** `ObLogBaseHeader`（从中提取 `log_type`）
2. 将剩余 buffer 交给 `inner_replay()` 处理
3. 子类根据 `base_header.get_log_type()` 做具体校验和派发

`ObLSResvSnapClogHandler` 在 `inner_replay()` 中调用 `ls_->replay_reserved_snapshot_log()`。`ObMediumCompactionClogHandler` 则反序列化 `tablet_id` 后，通过 `ls_->replay_get_tablet()` 获取对应 Tablet，再调用 `handle.get_obj()->replay_medium_compaction_clog()`。

### 2.3 `ObTxReplayExecutor` — 事务回放执行器

`ob_tx_replay_executor.h`（@L49-L174）是事务回放的核心实现：

```cpp
// ob_tx_replay_executor.h - doom-lsp 确认
class ObTxReplayExecutor
{
public:
  // 静态方法入口
  static int execute(storage::ObLS *ls,
                     ObLSTxService *ls_tx_srv,
                     const char *buf, const int64_t size,
                     const int skip_pos,
                     const palf::LSN &lsn,
                     const share::SCN &log_timestamp,
                     const logservice::ObLogBaseHeader &base_header,
                     const share::ObLSID &ls_id);

private:
  int do_replay_(const char *buf, const int64_t size, const int skip_pos);
  int prepare_replay_(...);
  int try_get_tx_ctx_();
  int iter_next_log_for_replay_(ObTxLogHeader &header);

  // 各日志类型的回放方法
  int replay_redo_();               // TX_REDO_LOG
  int replay_tx_log_(...);          // 其他事务控制日志
  int replay_rollback_to_();        // TX_ROLLBACK_TO_LOG
  int replay_prepare_();            // TX_PREPARE_LOG
  int replay_commit_();             // TX_COMMIT_LOG
  int replay_abort_();              // TX_ABORT_LOG
  int replay_clear_();              // TX_CLEAR_LOG
  int replay_start_working_();      // TX_START_WORKING_LOG

  int replay_redo_in_memtable_(...);   // 将 redo 数据写入 memtable
  int replay_one_row_in_memtable_(...);// 回放单行数据到 memtable

  ReplayTxCtx *ctx_;    // 事务上下文（实际是 ObPartTransCtx）
  ObLS *ls_;
  ObLSTxService *ls_tx_srv_;
  ObTxLogBlock log_block_;
  memtable::ObMemtableCtx *mt_ctx_;  // Memtable 上下文
  // ...
};
```

### 2.4 `ObRedoLogGenerator` — Redo 日志生成器

`ob_redo_log_generator.h`（@L169-L218）位于 Memtable 层，是写路径的核心：

```cpp
// ob_redo_log_generator.h:169-218 - doom-lsp 确认
class ObRedoLogGenerator
{
public:
  int fill_redo_log(ObTxFillRedoCtx &ctx);        // 从 MVCC callback 填充 redo log
  int log_submitted(const ObCallbackScopeArray &callbacks,
                    const share::SCN &scn);        // 日志已提交
  int sync_log_succ(const ObCallbackScopeArray &callbacks,
                    const share::SCN &scn);        // 日志同步成功
  void sync_log_fail(const ObCallbackScopeArray &callbacks,
                     const share::SCN &scn);       // 日志同步失败

private:
  ObTransCallbackMgr *callback_mgr_;  // MVCC callback 管理器
  ObMemtableCtx *mem_ctx_;           // Memtable 上下文
  int64_t redo_filled_cnt_;          // 已填充计数
  int64_t redo_sync_succ_cnt_;       // 同步成功计数
  int64_t redo_sync_fail_cnt_;       // 同步失败计数
};
```

其辅助结构 `ObTxFillRedoCtx`（@L78-L148）描述了填充 redo log 的完整上下文：

| 字段 | 类型 | 用途 |
|------|------|------|
| `tx_id_` | ObTransID | 事务 ID |
| `write_seq_no_` | ObTxSEQ | 写序列号，决定选择哪个 callback list |
| `list_` | ObTxCallbackList* | 当前填充的 callback list |
| `freeze_clock_` | uint32_t | 冻结时钟，跳过已冻结的 memtable |
| `callback_scope_` | ObCallbackScope* | 当前填充的 callback 范围 |
| `buf_/buf_len_/buf_pos_` | char*/int64_t | 序列化 buffer |

---

## 3. 数据流分析

### 3.1 写入路径：事务 → RedoLog → PALF

```
SQL Execute → DAS Insert → mvcc_write → ObMemtableCtx::set_callback_list
    → ObRedoLogGenerator::fill_redo_log() → 序列化 mutator 到 buffer
    → ObTxLSLogWriter::submit_log() → PALF::append()
    → PALF 通过 Paxos 多数派复制 → commit
    → AppendCb 回调 → ObLogApplyService → MVCC Callback
```

写入路径的详细步骤：

1. **SQL 层执行** DML 语句，通过 DAS（分布式访问服务）将写入请求路由到对应 Tablet
2. **Memtable 写入**：`ObMemtable::mvcc_write()` 创建 MVCC trans node，关联 callback
3. **Callback 注册**：每个 trans node 对应一个 `ObITransCallback`，注册到 `ObTransCallbackMgr`
4. **Fill Redo Log**：`ObRedoLogGenerator::fill_redo_log()`（`ob_redo_log_generator.h` L191）遍历 callback list，序列化 mutator 数据
5. **PALF propose**：通过 `ObTxLSLogWriter` 调用 `PALF::append()` 将日志提交到 Paxos 复制组
6. **日志提交回调**：PALF 日志在多数派确认后，触发 `AppendCb`，回调到 `ObLogApplyService`（`applyservice/ob_log_apply_service.h` L40 `ObLogApplyService`），最终释放 MVCC callback，事务进入 committed 状态

### 3.2 回放路径：PALF commit → Storage

```
PALF commit → (Follower 端 / 节点恢复)
    → ObLogReplayService::submit_task()
    → ObReplayHandler::replay(type, buffer, lsn, scn)
    → handler = handlers_[type]

类型 = TRANS_SERVICE_LOG_BASE_TYPE:
    → ObLSTxService::replay()
    → ObTxReplayExecutor::execute()
    → do_replay_()
      → prepare_replay_()  — 解析 ObTxLogBlock
      → try_get_tx_ctx_()  — 获取/创建事务上下文
      → 循环 iter_next_log_for_replay_()
        → 根据 ObTxLogType 分发:

          TX_REDO_LOG:
            → before_replay_redo_()
            → replay_redo_()
              → replay_redo_in_memtable_()
                → 反序列化 ObMemtableMutatorIterator
                → 逐行 replay_one_row_in_memtable_()
                  → replay_get_tablet()
                  → ObMemtable::set_data() / insert_row()
                  → MVCC trans node 插入

          TX_PREPARE_LOG:
            → replay_prepare_() — 设置事务为 prepared 状态

          TX_COMMIT_LOG:
            → replay_commit_() — 提交事务，更新 GTS

          TX_ABORT_LOG:
            → replay_abort_() — 回滚所有修改

          TX_START_WORKING_LOG:
            → replay_start_working_() — 标记 LogStream 正常启动

      → finish_replay_()

类型 = MEDIUM_COMPACTION_LOG_BASE_TYPE:
    → ObMediumCompactionClogHandler::inner_replay()
      → 反序列化 tablet_id
      → ls_->replay_get_tablet()
      → tablet->replay_medium_compaction_clog()

类型 = TABLET_OP_LOG_BASE_TYPE:
    → 对应 TabletHandler 处理创建/删除等操作
```

### 3.3 回放的核心逻辑流程

`do_replay_()`（`ob_tx_replay_executor.cpp`）的实现揭示了"逐条日志迭代回放"的精髓：

```
prepare_replay_()    ← 解析 ObTxLogBlock（按 LSN 读取 buffer）
    │
    ▼
[while loop]
try_get_tx_ctx_()    ← 根据事务 ID 获取/创建 ObPartTransCtx
    │
    ▼
iter_next_log_for_replay_()
    ← 从 log_block_ 中读取下一条 ObTxLogHeader
    │
    ▼ 根据 log_type 分发:
    │
    ├── TX_REDO_LOG → before_replay_redo_() → replay_redo_()
    │     → can_replay() 检查
    │     → replay_redo_in_memtable_()  ← 核心：将数据写入 Memtable
    │        └── replay_one_row_in_memtable_()  ← 逐行
    │              → ls_->replay_get_tablet()
    │              → ObStoreCtx 初始化
    │              → ObMemtable::set_data() / insert_row()
    │                    ↓
    │              └── MutatorType::MUTATOR_ROW → 写入行数据
    │                  MutatorType::MUTATOR_LOCK → 写入行锁
    │
    ├── TX_PREPARE_LOG → replay_prepare_()
    ├── TX_COMMIT_LOG  → replay_commit_()
    ├── TX_ABORT_LOG   → replay_abort_()
    ├── TX_ROLLBACK_TO_LOG → replay_rollback_to_()
    └── TX_START_WORKING_LOG → replay_start_working_()
```

### 3.4 单行回放的细节

`replay_one_row_in_memtable_()`（`ob_tx_replay_executor.cpp`）执行以下步骤：

1. **获取 Tablet**：`ls_->replay_get_tablet(tablet_id, log_ts_ns, ...)` — 如果 Tablet 已 GC 则跳过（`OB_OBSOLETE_CLOG_NEED_SKIP`）
2. **状态检查**：`replay_check_restore_status()` — 如果 Tablet 处于恢复中，判断是否需要跳过
3. **初始化写入上下文**：`ObStoreCtx` 设置 `ls_id_`、`tablet_id_`，MVCC 上下文初始化为 replay 模式
4. **分发 MutatorType**：
   - `MUTATOR_ROW` → 调用 `ObITable::set_data()` 将数据写入 Memtable 的 trans node
   - `MUTATOR_LOCK` → 调用 `ObITable::replay_lock_row()` 写入行锁
5. **MVCC trans node** 插入时，自动建立了数据行的**前镜像**和**后镜像**，用于回放中断后的幂等性

### 3.5 回调路径：AppendCb → ObLogApplyService

当 PALF 在多数派上提交一条日志后，通过 `AppendCb` 通知存储层：

```
PALF commit → AppendCb.enqueue()
    → ObApplyStatus::push_append_cb()
    → try_submit_cb_queues()     ← 将 callback 提交到工作队列
    → try_handle_cb_queue()      ← 逐个处理 callback
    → callback 内部释放 MVCC trans node
    → 事务提交完成，客户端感知到提交
```

`ObLogApplyService`（`applyservice/ob_log_apply_service.h`）的核心接口：

| 方法 | 用途 |
|------|------|
| `add_ls()` | 注册一个 LogStream 的 ApplyStatus |
| `remove_ls()` | 移除 LogStream |
| `push_task()` | 提交 AppendCb callback |
| `switch_to_leader()` | 主备切换时初始化 ApplyStatus（设置 end_lsn） |
| `switch_to_follower()` | 降级时清理状态 |
| `get_max_applied_scn()` | 获取最大连续提交的 SCN |

### 3.6 日志重试

回放路径中有两个关键的重试场景：

1. **Tablet 未就绪**：`replay_one_row_in_memtable_()` 中调用 `replay_get_tablet()` 返回 `OB_EAGAIN` 时，上层会将 retcode 改写为 `OB_EAGAIN`，使 `ObLogReplayService` 稍后重试
2. **Tablet 已 GC**：返回 `OB_OBSOLETE_CLOG_NEED_SKIP`，跳过这条日志（`force_no_need_replay_checksum`）

`rewrite_replay_retry_code_()`（`ob_tx_replay_executor.cpp`）负责将内部重试码统一为 `OB_EAGAIN`。

---

## 4. 日志 Apply 服务与日志获取

### 4.1 ObLogApplyService

位于 `src/logservice/applyservice/`，只有 2 个文件：

| 文件 | 行数 | 职责 |
|------|------|------|
| `ob_log_apply_service.h` | ~400 | Apply 服务定义，包含 ObApplyStatus（每个 LS 的 apply 状态） |
| `ob_log_apply_service.cpp` | 实现 | handle_cb_queue_、handle_submit_task_、LS 管理 |

核心工作流：

```
AppendCb → ObApplyStatus::push_append_cb()
    → try_submit_cb_queues() → 将 callback 放入 ObApplyServiceQueueTask
    → try_handle_cb_queue()  → 执行 callback
    → callback 回调 ObMemtableCtx::log_submitted() / sync_log_succ()
```

`ObApplyStatus`（L155-275）是每个 LogStream 的 Apply 状态管理器：

| 字段 | 用途 |
|------|------|
| `palf_committed_end_lsn_` | PALF 已提交的最大 LSN |
| `palf_committed_end_scn_` | PALF 已提交的最大 SCN |
| `last_check_scn_` | 上次检查的 SCN |
| `max_applied_cb_scn_` | 最大连续回调的 SCN |
| `cb_queues_[2]` | 回调双队列（交替使用） |

### 4.2 ObLogFetcher（日志获取）

位于 `src/logservice/logfetcher/`（超过 60 个文件），是 Follower 端日志追赶的核心：

| 文件 | 职责 |
|------|------|
| `ob_log_fetcher.h/cpp` | Fetcher 主控，管理所有 LS 的 fetch 状态 |
| `ob_log_ls_fetch_ctx.h/cpp` | 单个 LS 的 fetch 上下文 |
| `ob_log_ls_fetch_stream.h/cpp` | 单条 fetch 流 |
| `ob_log_fetch_log_rpc.h/cpp` | FetchLog RPC 实现 |
| `ob_log_fetch_stream_container.h/cpp` | 流容器管理 |
| `ob_ls_worker.h/cpp` | LS 级别的工作线程 |

`ObLogFetcher`（`ob_log_fetcher.h` L179-348）对每个 LS 管理以下状态：

- **fetch 起始位置**：从 Leader 的什么位置开始拉取
- **进度追踪**：当前已 fetch 到哪个 LSN/SCN
- **重试策略**：拉取失败后的退避和重试
- **流管理**：multiplexing 多个 fetch 流并行拉取

日志获取的典型场景：

1. **Follower 启动**：从 PALF 元数据获取最后的 committed LSN，调用 `ObLogFetcher::add_ls()` 启动 catch-up
2. **常态追赶**：通过 FetchLog RPC 从 Leader 拉取日志，写入本地 PALF 存储
3. **写入完成回调**：本地 PALF 数据就绪后，触发 `ObLogReplayService` 进行回放
4. **进度检测**：`ObLogFetcher::check_progress()` 定期检测 catch-up 进度

---

## 5. 与 PALF 和 Transaction 的连接

### 5.1 PALF → Clog 的连接

```
PALF 日志提交 → 两种分支

分支 A：回调 (Callback)
  PALF commit → AppendCb (ob_append_callback.h)
    → ObLogApplyService::handle()
      → callback 执行
      → 事务层感知提交

分支 B：回放 (Replay)
  ObLogReplayService::submit_task() → 工作者线程
    → ObReplayHandler::replay(type, buffer, lsn, scn)
      → handlers_[type]->replay()
```

回放服务是异步的——`ObLogReplayService` 维护一个任务队列，工作者线程从队列中取出任务，调用 `ObReplayHandler::replay()` 执行回放。

### 5.2 Transaction → Clog 的连接

```
回放时，事务上下文（ObPartTransCtx）的生命周期：

ObTxReplayExecutor::try_get_tx_ctx_()：
  → 从 MGR 中查找 ObPartTransCtx（按 tx_id）
  → 如果不存在且日志类型合法：
    → 创建新的 ObPartTransCtx
    → 设置 first_created_ctx_ = true
    → 进入 "replaying" 状态
  → 如果存在：
    → 复用已有 ctx
    → 可能处于 prepared/committed 等不同状态

不同日志类型到达时，ctx 的响应：
  - TX_REDO_LOG: 需要 ctx 处于 active 状态
  - TX_PREPARE_LOG: 设置 ctx 为 prepared
  - TX_COMMIT_LOG: 提交 ctx，释放资源
  - TX_ABORT_LOG: 回滚 ctx，清空修改
```

### 5.3 与 MVCC Callback 的连接

Article 04（Callback）介绍了 MVCC callback 机制。Clog 子系统通过 callback 将事务执行的"完成通知"从 PALF 提交点传回到事务层：

```
写路径 (Leader):
  ObMemtableCtx::set_callback_list()
    → 注册 ITxCallback（关联 trans node）
  ObRedoLogGenerator::fill_redo_log()
    → 序列化 callback 信息到 redo log buffer
  PALF::append()
    → 日志多数派后：AppendCb
  ObRedoLogGenerator::sync_log_succ()
    → callback 执行 → trans node 标记为 committed
    → 行锁释放，事务提交

回放路径 (Follower / 恢复):
  ObTxReplayExecutor::replay_redo_in_memtable_()
    → ObMemtable::set_data()
      → 插入 MVCC trans node
      → 设置 callback 为 "replay" 模式
    → callback 立即标记为 committed
    → 事务在 replay 结束后进入 committed 状态
```

---

## 6. 完整的日志路径总览

### 写入路径（Leader 端）

```
┌──────────────────────────────────────────────────────────┐
│ SQL Layer                                                │
│  DML: INSERT/UPDATE/DELETE                               │
└──────────────────────┬───────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────┐
│ DAS (Distributed Access Service)                         │
│  路由到目标 Tablet 所在的 LogStream                      │
└──────────────────────┬───────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────┐
│ Memtable Layer                                           │
│  ObMemtable::mvcc_write()                                │
│    → ObMemtableCtx::set_callback_list()                  │
│    → 创建 MVCC trans node + ITxCallback                  │
│  ObRedoLogGenerator::fill_redo_log(ObTxFillRedoCtx)      │
│    → 遍历 callback list                                  │
│    → 序列化 ObMutator (行修改数据) 到 buffer              │
└──────────────────────┬───────────────────────────────────┘
                       │  序列化的 redo log buffer
                       ▼
┌──────────────────────────────────────────────────────────┐
│ Transaction Layer                                        │
│  ObTxLSLogWriter::submit_log()                           │
│    → ObITxLogAdapter::append(tx_log)                     │
└──────────────────────┬───────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────┐
│ PALF (Paxos Append Log Framework)                        │
│  PalfHandleImpl::append() → LogGroupEntry                │
│    → LogEngine::append_log()                             │
│    → LogSlidingWindow 跟踪多数派                          │
│    → [Leader] 向 Followers 发送 AppendEntries RPC        │
│    → [Follower] FetchLogEngine 从 Leader 拉取             │
│    → LogGroupEntry 在多数派达成 → Committed              │
└─────┬─────────────────────────────┬──────────────────────┘
      │                             │
      ▼                             ▼
┌─────────────┐          ┌────────────────────────┐
│ AppendCb    │          │ ObLogReplayService     │
│ (回调路径)   │          │ (回放路径：Follower 端)│
│             │          │                        │
│ ObApplySvc  │          │ ObReplayHandler        │
│  → callback │          │  → handlers_[type]     │
│  → MVCC     │          │  → replay()            │
│  → 事务提交  │          │  → Storage 回放        │
└─────────────┘          └────────────────────────┘
```

### 回放路径（Follower 端 / 节点恢复）

```
PALF 存储
  │
  ▼
ObLogReplayService::submit_task()
  │ 提交回放任务到工作线程
  ▼
ObReplayHandler::replay(type, buffer, lsn, scn)
  │
  ├── type = TRANS_SERVICE_LOG_BASE_TYPE (1)
  │   ▼
  │ ObLSTxService::replay()
  │   ▼
  │ ObTxReplayExecutor::execute()
  │   ▼
  │ ObTxReplayExecutor::do_replay_()
  │   ├── prepare_replay_() ← 反序列化 ObTxLogBlock
  │   ├── try_get_tx_ctx_() ← 获取/创建 事务上下文
  │   ├── [循环] iter_next_log_for_replay_()
  │   │     ├── TX_REDO_LOG → replay_redo_in_memtable_()
  │   │     │     └── replay_one_row_in_memtable_()
  │   │     │           ├── ls_->replay_get_tablet()
  │   │     │           ├── ObITable::set_data() (MUTATOR_ROW)
  │   │     │           └── ObITable::replay_lock_row() (MUTATOR_LOCK)
  │   │     ├── TX_PREPARE_LOG → replay_prepare_()
  │   │     ├── TX_COMMIT_LOG  → replay_commit_()
  │   │     ├── TX_ABORT_LOG   → replay_abort_()
  │   │     ├── TX_CLEAR_LOG   → replay_clear_()
  │   │     └── TX_START_WORKING_LOG → replay_start_working_()
  │   └── finish_replay_()
  │
  ├── type = MEDIUM_COMPACTION_LOG_BASE_TYPE (18)
  │   ▼
  │ ObMediumCompactionClogHandler::inner_replay()
  │   ├── 反序列化 tablet_id
  │   └── tablet->replay_medium_compaction_clog()
  │
  ├── type = TABLET_OP_LOG_BASE_TYPE (2)
  │   ▼
  │ Tablet 操作回放（创建/删除 Tablet）
  │
  └── type = RESERVED_SNAPSHOT_LOG_BASE_TYPE (17)
      ▼
    ObLSResvSnapClogHandler::inner_replay()
      └── ls_->replay_reserved_snapshot_log()
```

---

## 7. 设计决策

### 7.1 日志格式：幂等性设计

回放必须是幂等的——一条日志在任何情况下多次回放都产生相同结果。

OceanBase 的设计策略：

1. **MVCC trans node 的 checksum**：每个 trans node 携带数据的 checksum，回放时校验，如果数据一致则跳过
2. **Tablet SCN 水位线**：Tablet 记录已回放到的最大 SCN，小于该水位线的日志自动跳过
3. **事务状态幂等**：`ObPartTransCtx` 维护事务状态机（active/prepared/committed/aborted），重复的回放消息会被状态过滤
4. **回放完成回调**：`finish_replay_()` 更新 `max_replay_commit_version`，确保 GTS 正确推进

### 7.2 并行回放与串行回放

OceanBase 的日志回放同时支持串行和并行模式：

**串行回放（默认）**：
- `replay_queue_ == 0` → `is_tx_log_replay_queue() == true`
- 每条日志按 PALF 的提交顺序逐个回放
- 保证严格的日志顺序

**并行回放**：
- 某些日志类型（如 `MULTI_DATA_SOURCE_LOG`）可以并行回放
- 通过 `multi_source_data_scheduler` 分配到不同队列
- 需要 barrier 机制保证因果序（`pre_replay_barrier` / `post_replay_barrier`）
- undo 日志（`ROLLBACK_TO_LOG`）必须串行

**Barrier 机制**（`ob_log_base_header.h` L56-57）：
```cpp
bool need_pre_replay_barrier() const;   // 需要等待所有前序日志回放完成
bool need_post_replay_barrier() const;  // 需要等待当前日志完成后再继续
```

### 7.3 回放时的 MVCC 处理

回放时，MVCC 并非像正常写入那样创建新旧版本，而是直接通过 `init_replay` 模式插入 trans node：

```cpp
// ob_tx_replay_executor.cpp
storeCtx.mvcc_acc_ctx_.init_replay(
    *ctx_,           // ObPartTransCtx
    *mt_ctx_,        // ObMemtableCtx
    ctx_->get_trans_id()
);
```

`init_replay` 模式的特点：
- 不检查写冲突（因为回放不可能产生冲突——日志已经通过 Paxos 达成共识）
- 不触发 callback（回放完成后统一 callback）
- 不检查冻结状态（Memtable 可能已经冻结，但回放仍然要写入）
- 写入的 trans node 在 replay 阶段后统一加入到 read snapshot

### 7.4 日志的 Checkpoint 与 GC

Clog 的 GC 通过 checkpoint 机制完成：

1. **PALF 侧的 GC**：`LogBlockMgr::truncate()` / `delete_block()` 删除已不再需要的日志块
2. **SCN 水位线**：`ObICheckpointSubHandler::get_rec_scn()` 返回各 handler 的恢复 SCN，取最小值作为 PALF 可以 GC 的水位
3. **Tablet 冻结**：冻结后的 Memtable 的 redo log 不再需要回放（数据已持久化到 SSTable），可以安全 GC
4. **回放进度**：`ObLogReplayService` 追踪每个 LS 的回放进度，已回放完成的日志可以被删除

---

## 8. 源码索引

### 回放分发

| 文件 | 关键类/函数 | 行号 |
|------|------------|------|
| `src/logservice/ob_log_base_type.h` | `ObIReplaySubHandler` 接口 | L110-116 |
| `src/logservice/ob_log_base_type.h` | `ObLogBaseType` 枚举 (~60 种类型) | L30-70 |
| `src/logservice/ob_log_base_type.h` | `REGISTER_TO_LOGSERVICE` 注册宏 | L120-130 |
| `src/logservice/ob_log_base_header.h` | `ObLogBaseHeader` 日志头部 | L42-72 |
| `src/logservice/replayservice/ob_replay_handler.h` | `ObReplayHandler` 分发器 | 全文 (~60行) |
| `src/logservice/replayservice/ob_log_replay_service.h` | `ObLogReplayService` 回放调度 | L155-390 |

### 存储层 Clog Handler

| 文件 | 关键类/函数 | 行号 |
|------|------------|------|
| `src/storage/ls/ob_ls_storage_clog_handler.h` | `ObLSStorageClogHandler` | L22-81 |
| `src/storage/ls/ob_ls_storage_clog_handler.h` | `ObLSResvSnapClogHandler` | L83-92 |
| `src/storage/ls/ob_ls_storage_clog_handler.h` | `ObMediumCompactionClogHandler` | L94-97 |
| `src/storage/ls/ob_ls_storage_clog_handler.cpp` | `replay()` 反序列化 + 分发 | L34-60 |
| `src/storage/ls/ob_ls_storage_clog_handler.cpp` | `inner_replay()` 子类实现 | L62-130 |
| `src/storage/ls/ob_ls.h` | `replay_handler_` 成员 | L1130 |

### 事务回放执行器

| 文件 | 关键类/函数 | 行号 |
|------|------------|------|
| `src/storage/tx/ob_tx_replay_executor.h` | `ObTxReplayExecutor` 定义 | L49-174 |
| `src/storage/tx/ob_tx_replay_executor.h` | `execute()` 静态入口 | L109 |
| `src/storage/tx/ob_tx_replay_executor.h` | `do_replay_()` 主流程 | L111 |
| `src/storage/tx/ob_tx_replay_executor.h` | `replay_redo_in_memtable_()` | L133 |
| `src/storage/tx/ob_tx_replay_executor.h` | `replay_one_row_in_memtable_()` | L134 |
| `src/storage/tx/ob_tx_replay_executor.cpp` | `do_replay_()` 实现 | 主循环 |
| `src/storage/tx/ob_tx_replay_executor.cpp` | `replay_tx_log_()` 事务控制日志分发 | |
| `src/storage/tx/ob_tx_replay_executor.cpp` | `replay_one_row_in_memtable_()` 单行回放 | |
| `src/storage/tx/ob_tx_log.h` | `ObTxLogType` 事务日志类型 | L79-94 |
| `src/storage/ls/ob_ls_tx_service.cpp` | `replay()` 入口 | L504-525 |

### Redo Log 生成

| 文件 | 关键类/函数 | 行号 |
|------|------------|------|
| `src/storage/memtable/ob_redo_log_generator.h` | `ObRedoLogGenerator` | L169-218 |
| `src/storage/memtable/ob_redo_log_generator.h` | `fill_redo_log()` | L191 |
| `src/storage/memtable/ob_redo_log_generator.h` | `log_submitted()` | L192 |
| `src/storage/memtable/ob_redo_log_generator.h` | `sync_log_succ()` | L193 |
| `src/storage/memtable/ob_redo_log_generator.h` | `ObTxFillRedoCtx` 填充上下文 | L78-148 |
| `src/storage/memtable/ob_redo_log_generator.h` | `ObCallbackScope` callback 范围 | L27-43 |

### Apply 服务与 Fetch

| 文件 | 关键类/函数 | 行号 |
|------|------------|------|
| `src/logservice/applyservice/ob_log_apply_service.h` | `ObLogApplyService` | L310-390 |
| `src/logservice/applyservice/ob_log_apply_service.h` | `ObApplyStatus` (每 LS 状态) | L155-275 |
| `src/logservice/applyservice/ob_log_apply_service.h` | `push_append_cb()` | L169 |
| `src/logservice/applyservice/ob_log_apply_service.h` | `try_submit_cb_queues()` | L170 |
| `src/logservice/applyservice/ob_log_apply_service.h` | `try_handle_cb_queue()` | L171 |
| `src/logservice/ob_append_callback.h` | `AppendCb` PALF 回调 | 全文 |
| `src/logservice/logfetcher/ob_log_fetcher.h` | `ObLogFetcher` | L179-348 |
| `src/logservice/logfetcher/ob_log_fetcher.h` | `IObLogFetcher` 接口 | L51-174 |

---

## 9. 与前面文章的关联

| 文章 | 关联内容 |
|------|---------|
| 04 — Callback | MVCC callback 结构与 Clog callback 的绑定关系 |
| 07 — LS/LogStream | LS 初始化时通过 REGISTER_TO_LOGSERVICE 注册 replay handler |
| 08 — SSTable | 冻结后的 Tablet 不再需要回放 redo log |
| 10 — Transaction | 2PC 的 prepare/commit/abort 日志通过 Clog 回放恢复事务状态 |
| 11 — PALF | Clog 是 PALF 日志的使用者；AppendCb 是从 PALF 到 Clog 的桥梁 |
| 12 — Election | 切主后 Follower 通过 FetchLogEngine 拉取缺失日志，再通过 Clog 回放 |

---

## 10. 小结

OceanBase 的 Clog 子系统虽然没有独立的目录结构，但它定义了**日志从 Paxos 共识协议到存储引擎应用的完整路径**。核心设计要点：

1. **多级分发**：`ObLogBaseType` → `ObReplayHandler` → `ObIReplaySubHandler` → `inner_replay()`，每层负责解包不同粒度的元数据
2. **幂等回放**：通过 MVCC trans node 的 checksum、Tablet SCN 水位线、事务状态机三重保障
3. **事务状态恢复**：`ObTxReplayExecutor` 按日志类型（Redo/Prepare/Commit/Abort）逐步重建事务状态机
4. **写入回放对称**：`ObRedoLogGenerator` 负责写路径的序列化，`ObTxReplayExecutor` 负责读路径的反序列化，两者共享 `ObMemtableMutatorIterator` 格式
5. **分离的回调和回放**：PALF 提交后产生两条分支——`AppendCb → ObLogApplyService`（Leader 的事务提交回调）和 `ObLogReplayService → ObReplayHandler`（Follower/恢复的事务状态重建）
