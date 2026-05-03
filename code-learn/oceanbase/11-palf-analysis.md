# 11 — PALF — OceanBase 的 Paxos-Structured Log Framework

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前 10 篇文章覆盖了 OceanBase 存储引擎的完整软件栈：MVCC Row → Iterator → 写冲突 → Callback → Compact → Freeze → LS Tree → SSTable → SQL DAS → 分布式 2PC。现在是时候进入整个系统的**分布式共识核心**——PALF。

**PALF** = **P**axos-**A**ppend-**L**og **F**ramework，Paxos 追加日志框架。它是 OceanBase 自研的基于 Paxos 的一致性日志复制框架，位于 `src/logservice/palf/` 目录下（132 个源文件）。PALF 是所有数据复制的基石，位于事务层和存储层之间——LS Tree 的变更通过 PALF 复制到多数派，2PC 的提交日志通过 PALF 完成共识。

### PALF 在 OceanBase 架构中的位置

```
┌─────────────────────────────────────────────────────────┐
│                    SQL Layer                             │
├─────────────────────────────────────────────────────────┤
│                    Transaction Layer (2PC)               │
│  文章 10: 2PC 的 prepare log 通过 PALF 完成多数派复制    │
├───────────┬─────────────────────────────────────────────┤
│           │   PALF — Paxos-Structured Log Framework     │
│  ObLS     │   ┌─────────────────────────────────────┐   │
│  (LS-07)  │   │  LogEngine                          │   │
│           │   │  ├─PalfHandleImpl (Paxos 状态机)    │   │
│           │   │  ├─LogConfigMgr (成员管理)          │   │
│           │   │  ├─LogSlidingWindow (日志滑动窗口)   │   │
│           │   │  ├─LogBlockMgr (日志块存储)          │   │
│           │   │  ├─LogCache (日志缓存)               │   │
│           │   │  ├─LogReconfirm (Leader 确认)        │   │
│           │   │  └─Election (选主模块)               │   │
│           │   └─────────────────────────────────────┘   │
├───────────┴─────────────────────────────────────────────┤
│                    Storage Layer                         │
│  宏块管理、编码压缩、异步 I/O                              │
└─────────────────────────────────────────────────────────┘
```

### 为什么自研 PALF？

| 场景需求 | PALF 的设计选择 | 对比 Raft/etcd |
|---------|----------------|----------------|
| **批量日志** | LogGroupEntry 批量写入 | Raft 通常单条追加 |
| **高吞吐** | 异步 I/O、批量化、无锁队列 | etcd 的 bbolt 单线程写 |
| **成员变更** | 支持 Joint Consensus、仲裁成员 | Raft 单节点变更 |
| **Arbitration** | 仲裁副本不存数据 | etcd 无此概念 |
| **Learner** | 支持多级 Learner 树形同步 | Raft 仅有单层 Follower |
| **Standby** | 备库独立日志流复制 | etcd 无此需求 |

---

## 1. 整体架构

### PALF 组件全景

```
PalfHandle (public API)          ← IPalfHandle 接口
    │
PalfHandleImpl (Paxos 状态机)    ← 核心 Paxos 逻辑
    │
    ├── LogSlidingWindow         ← 日志滑动窗口（Paxos 多数派跟踪）
    ├── LogConfigMgr             ← 成员列表管理
    ├── LogModeMgr               ← 访问模式管理（读写/只读）
    ├── LogStateMgr              ← 角色状态机（Leader/Follower）
    ├── LogReconfirm             ← Leader 上任确认流程
    ├── LogEngine                ← 日志存储引擎
    │   ├── LogBlockMgr          ← 日志块存储
    │   ├── LogCache             ← 日志缓存（KV Cache）
    │   └── LogIOWorker          ← 异步 I/O 工作者
    ├── Election                 ← 选主模块
    └── FetchLogEngine           ← 日志拉取引擎
```

**核心文件一览**（doom-lsp 确认）：

| 文件 | 行数 | 职责 |
|------|------|------|
| `palf_handle_impl.h` | ~1370 | Paxos 状态机核心实现 |
| `log_engine.h` | ~560 | 日志引擎，PALF 的存储和网络入口 |
| `log_config_mgr.h` | ~810 | 配置管理（成员列表、副本数） |
| `log_block_mgr.h` | ~145 | 日志块物理存储管理 |
| `log_sliding_window.h` | ~630 | 日志滑动窗口，Paxos 多数派跟踪 |
| `log_entry.h` | ~55 | 单条日志条目定义 |
| `log_group_entry.h` | ~95 | 日志组条目（批量写入） |
| `log_group_entry_header.h` | ~170 | 日志组头部元数据 |
| `log_state_mgr.h` | ~225 | 角色状态机 |
| `log_reconfirm.h` | ~190 | Leader 上任确认流程 |
| `log_io_worker.h` | ~180 | IO 工作线程管理 |
| `log_io_task.h` | ~330 | IO 任务类型定义 |
| `log_cache.h` | ~340 | 日志缓存子系统 |
| `fetch_log_engine.h` | ~150 | 日志拉取引擎 |
| `log_io_adapter.h` | ~100 | IO 适配层（对接文件系统） |
| `log_block_header.h` | ~95 | 日志块头部定义 |
| `log_learner.h` | ~60 | Learner 角色定义 |
| `election/` | 目录 | 选主子模块 |

---

## 2. 核心数据结构

### 2.1 LogEngine（`log_engine.h` @ L90）

`LogEngine` 是 PALF 的存储层引擎，负责日志的持久化和网络通信。它不直接包含 Paxos 逻辑，而是为 `PalfHandleImpl` 提供存储和网络基础设施。

```cpp
// log_engine.h:90-114 - doom-lsp 确认
class LogEngine
{
  friend class PalfHandleImpl; // PalfHandleImpl 需要访问 net_service
public:
  LogEngine();
  virtual ~LogEngine();

  // 核心初始化：绑定额外的 epoch 来保证跨生命周期安全
  int init(const int64_t palf_id,
           const char *base_dir,
           const LogMeta &log_meta,
           common::ObILogAllocator *alloc_mgr,
           ILogBlockPool *log_block_pool,
           LogCache *log_cache,
           LogRpc *log_rpc,
           LogIOWorker *log_io_worker,
           LogSharedQueueTh *log_shared_queue_th,
           LogPlugins *plugins,
           const int64_t palf_epoch,
           const int64_t log_storage_block_size,
           const int64_t log_meta_storage_block_size,
           LogIOAdapter *io_adapter);
};
```

**关键成员变量**（`log_engine.h` @ L540-556）：

| 成员 | 类型 | 用途 |
|------|------|------|
| `log_meta_` | 日志元数据 | 持久化元信息（LSN 范围、SCN 范围） |
| `log_meta_storage_` | 元数据存储 | 元数据的持久化 |
| `log_storage_` | 日志存储 | 日志数据的读写，内部包含 LogBlockMgr |
| `log_net_service_` | LogNetService | 网络通信服务（RPC 收发） |
| `log_io_worker_` | LogIOWorker | 异步 IO 工作线程 |
| `min_block_id_` | block_id_t | 最小的日志块 ID，用于 GC |
| `base_lsn_for_block_gc_` | LSN | 块 GC 的基础 LSN |

**核心操作**：

- **`append_log()`**（@L170）— 写入日志到本地存储
- **`read_log()`**（@L172）— 从本地存储读取日志
- **`submit_push_log_req()`**（@L217）— 发送 AppendEntries RPC 到远程节点
- **`submit_fetch_log_req()`**（@L368）— 从远程节点拉取日志
- **`truncate()`**（@L177）— 截断指定 LSN 之前的日志
- **`delete_block()`**（@L181）— 删除一个日志块

### 2.2 LogConfigMgr（`log_config_mgr.h`）

`LogConfigMgr` 管理 PALF 组的成员配置。它跟踪 Paxos 成员列表、Learner 列表、仲裁成员（Arbitration Member）以及配置版本。

**成员变更类型**（`log_config_mgr.h` @ L48-71）：

```cpp
enum LogConfigChangeType {
  INVALID_LOG_CONFIG_CHANGE_TYPE = 0,
  CHANGE_REPLICA_NUM,       // 变更副本数
  ADD_MEMBER,               // 添加成员
  ADD_ARB_MEMBER,           // 添加仲裁成员
  REMOVE_MEMBER,            // 移除成员
  REMOVE_ARB_MEMBER,        // 移除仲裁成员
  ADD_LEARNER,              // 添加 Learner
  REMOVE_LEARNER,           // 移除 Learner
  SWITCH_LEARNER_TO_ACCEPTOR,    // Learner 升级为 Acceptor
  SWITCH_ACCEPTOR_TO_LEARNER,    // Acceptor 降级为 Learner
  DEGRADE_ACCEPTOR_TO_LEARNER,   // Acceptor 降级（保留日志）
  UPGRADE_LEARNER_TO_ACCEPTOR,   // Learner 升级（从备份）
  // ... 更多类型
};
```

成员变更通过 Paxos 日志同步——新的配置通过一条特殊的 `LogConfigMeta` 日志在 Paxos 组内达成多数派后生效。这确保了成员变更的一致性（类似 Raft 的 Joint Consensus）。

### 2.3 LogBlockMgr（`log_block_mgr.h`）

`LogBlockMgr` 管理日志文件的物理存储。日志文件被组织为固定大小的块（block），每个块对应磁盘上的一个文件。

```cpp
// log_block_mgr.h - doom-lsp 确认
class LogBlockMgr {
public:
  int init(const char *log_dir, const block_id_t block_id,
           const int64_t align_size, const int64_t align_buf_size,
           int64_t log_block_size, ILogBlockPool *log_block_pool,
           LogIOAdapter *io_adapter);

  int pwrite(const block_id_t block_id, const offset_t offset,
             const char *buf, const int64_t buf_len);
  int writev(const block_id_t block_id, const offset_t offset,
             const LogWriteBuf &write_buf);
  int truncate(const block_id_t block_id, const offset_t offset);
  int delete_block(block_id_t block_id);
  int switch_next_block(const block_id_t next_block_id);
};
```

每个块包含一个 `LogBlockHeader`（`log_block_header.h`），记录块的元信息：

```cpp
struct LogBlockHeader {
  int16_t magic_;          // 0x4942 = "IB" (InfoBlock)
  int16_t version_;        // 版本号
  int32_t flag_;           // 标志位（包含 reused 标记）
  LSN min_lsn_;            // 块内最小 LSN
  share::SCN min_scn_;     // 块内最小 SCN
  share::SCN max_scn_;     // 块内最大 SCN（重用时记录）
  block_id_t curr_block_id_; // 逻辑块 ID
  int64_t palf_id_;        // 所属 PALF ID
  int64_t checksum_;       // 校验和
};
```

块的 **重用时**（reused block），`max_scn_` 记录了复用前的最大 SCN，用于迭代器的边界判断。

### 2.4 LogEntry 与 LogGroupEntry

**LogEntry**（`log_entry.h` @ L27）是最小的日志单元：

```cpp
class LogEntry {
  LogEntryHeader header_;  // 头部（magic、log_size、scn、data_checksum）
  const char *buf_;        // 数据指针
};
```

**LogEntryHeader**（`log_entry_header.h`）包含：
- `MAGIC`：标识魔数 `'LH'`（LOG ENTRY HEADER）
- `log_size_`：日志数据长度
- `scn_`：日志的 SCN
- `data_checksum_`：数据校验和
- `flag_`：标志位（包含 padding 标记）

**LogGroupEntry**（`log_group_entry.h` @ L28）是批量写入单元——**这是 PALF 性能的关键**：

```cpp
class LogGroupEntry {
  LogGroupEntryHeader header_;  // 组头部
  const char *buf_;             // 数据指针（包含多个 LogEntry）
};
```

**LogGroupEntryHeader**（`log_group_entry_header.h`）包含：
- `group_size_`：组大小（包含头部和数据）
- `accumulated_checksum_`：累积校验和（用于一致性检查）
- `max_scn_`：组内最大 SCN
- `log_id_`：日志 ID（用于滑动窗口）
- `proposal_id_`：提案 ID（Paxos 共识使用）
- `committed_end_lsn_`：提交截止 LSN（提交进度跟踪）

**关键设计**：多个 `LogEntry` 被批量化到一个 `LogGroupEntry` 中一次性写入和复制，大幅减少了 I/O 次数和网络 RPC 数量。

### 2.5 LogCache（`log_cache.h`）

`LogCache` 是日志的 KV 缓存层，用于加速最近写入日志的读取。它包装了 OceanBase 的 `ObKVCache`：

```cpp
class LogHotCache {
  int64_t palf_id_;
  IPalfHandleImpl *palf_handle_impl_;
  // 统计信息
  mutable int64_t read_size_;
  mutable int64_t hit_count_;
  mutable int64_t read_count_;
};
```

缓存行大小为 `CACHE_LINE_SIZE = 64KB`，最后一行 `LAST_CACHE_LINE_SIZE = 60KB`。

`LogCacheUtils` 提供了跨 PALF 实例的全局 KV 缓存访问，通过 `OB_LOG_KV_CACHE` 单例管理。

---

## 3. Paoxs 协议实现

PALF 的 Paxos 实现主要在 `PalfHandleImpl`（`palf_handle_impl.h`）中，以下是其核心组件。

### 3.1 PalfHandleImpl（`palf_handle_impl.h` @ L276+）

`PalfHandleImpl` 是 PALF 的 Paxos 状态机实现。它在初始化时绑定以下组件：

- `LogSlidingWindow` — 滑动窗口，跟踪日志的多数派确认
- `LogStateMgr` — 角色状态机
- `LogConfigMgr` — 配置管理
- `LogModeMgr` — 访问模式
- `LogReconfirm` — Leader 确认
- `LogEngine` — 日志引擎
- `Election` — 选主
- `FetchLogEngine` — 日志拉取

**关键方法**：

```cpp
class IPalfHandleImpl {
  // 提交日志到 Paxos 组（上层调用入口）
  virtual int submit_log(const PalfAppendOptions &opts,
                         const char *buf, const int64_t buf_len,
                         const share::SCN &ref_scn,
                         LSN &lsn, share::SCN &scn) = 0;

  // 提交组日志（备库 Leader 处理从主库收到的日志）
  virtual int submit_group_log(const PalfAppendOptions &opts,
                               const LSN &lsn,
                               const char *buf, const int64_t buf_len) = 0;

  // 获取当前角色
  virtual int get_role(common::ObRole &role,
                       int64_t &proposal_id,
                       bool &is_pending_state) const = 0;

  // 切主
  virtual int change_leader_to(const common::ObAddr &dest_addr) = 0;
};
```

### 3.2 LogSlidingWindow（`log_sliding_window.h` @ L203）

`LogSlidingWindow` 是 PALF 实现 Paxos 多数派跟踪的核心数据结构。它使用一个固定大小的滑动窗口来跟踪每个日志的确认状态：

```cpp
class LogSlidingWindow : public ISlidingCallBack {
  // 提交本地日志
  virtual int submit_log(const char *buf, const int64_t buf_len,
                         const share::SCN &ref_scn, LSN &lsn, share::SCN &scn);
  // 接收远程日志
  virtual int receive_log(const common::ObAddr &src_server,
                          const PushLogType push_log_type, ...);
  // 确认日志（收到 ACK 后调用）
  virtual int ack_log(const common::ObAddr &src_server, const LSN &end_lsn);
  // 获取多数派匹配的 LSN
  virtual int get_majority_match_lsn(LSN &majority_match_lsn);
  // 提交回调（窗口滑动时调用）
  virtual int sliding_cb(const int64_t sn, const FixedSlidingWindowSlot *data);
};
```

**工作流程**：
1. `submit_log()` 分配 LSN，写入滑动窗口
2. 日志写入本地磁盘后，发起 AppendEntries RPC
3. Follower 回复 ACK 时调用 `ack_log()`
4. 当某个 LSN 获得多数派 ACK，滑动窗口向前推进
5. `sliding_cb()` 触发提交回调，通知上层

### 3.3 LogStateMgr（`log_state_mgr.h`）

`LogStateMgr` 管理 PALF 副本的角色状态转换：

```cpp
class LogStateMgr {
  // 角色
  common::ObRole role_;       // LEADER / FOLLOWER
  // 状态
  int16_t state_;             // 更多粒度状态
  common::ObAddr leader_;     // 当前 Leader
  int64_t leader_epoch_;      // Leader 任期
  int64_t proposal_id_;       // 当前提案 ID
  bool is_leader_active_;     // Leader 活跃标记
  bool is_in_sync_;           // 是否在同步中
};
```

**状态检查方法**：
- `can_receive_log()` — 能否接收日志
- `can_receive_log_ack()` — 能否处理日志确认
- `can_slide_sw()` — 能否滑动窗口
- `is_leader_active()` — Leader 是否活跃
- `is_follower_pending()` — Follower 是否等待中

### 3.4 LogReconfirm（`log_reconfirm.h` @ L47）

新 Leader 上任后，需要通过 `LogReconfirm` 流程确认自己拥有最新日志。这是 Paxos 的 **Prepare 阶段**：

```
LogReconfirm 状态机:
  INITED → WAITING_LOG_FLUSHED → FETCH_MAX_LOG_LSN
  → RECONFIRM_MODE_META → RECONFIRM_FETCH_LOG
  → RECONFIRMING → START_WORKING → FINISHED
```

**流程**：
1. **WAITING_LOG_FLUSHED** — 等待所有本地日志刷盘完成
2. **FETCH_MAX_LOG_LSN** — 广播 Prepare 请求，收集多数派的 committed_end_lsn
3. **RECONFIRM_MODE_META** — 确认访问模式
4. **RECONFIRM_FETCH_LOG** — 从最新节点拉取缺失日志
5. **RECONFIRMING** — 等待拉取完成
6. **START_WORKING** — 写入一条 START_WORKING 日志标记上任
7. **FINISHED** — 完成确认，正式开始服务

### 3.5 Election（`election/` 目录）

选主模块在 `src/logservice/palf/election/` 中，包含以下目录：

```
election/
├── algorithm/    — 选举算法实现
├── interface/    — 选举接口定义
├── message/      — 选举消息定义
└── utils/        — 工具函数
```

Election 组件与 PalfHandleImpl 集成：选主结果通过回调通知 LogStateMgr，后者触发角色切换。

---

## 4. 日志生命周期

### 完整数据流

```
Client (事务层/2PC)
    │
    ▼ submit_log()
PalfHandleImpl (Leader)
    │
    ├─▶ 1. 分配 LSN，写入 LogSlidingWindow
    │
    ├─▶ 2. LogEngine.append_log()
    │        │
    │        ├─▶ LogGroupBuffer 批量打包为 LogGroupEntry
    │        │
    │        ├─▶ submit_flush_log_task()
    │        │        │
    │        │        ├─▶ LogIOFlushLogTask
    │        │        │        │
    │        │        │        └─▶ LogIOWorker.run1()
    │        │        │                │
    │        │        │                └─▶ LogBlockMgr.pwrite()
    │        │        │                        │
    │        │        │                        └─▶ LogIOAdapter.pwrite()
    │        │        │                                │
    │        │        │                                └─▶ 磁盘（page cache）
    │        │        │
    │        │        └─▶ after_flush_log()
    │        │
    │        └─▶ LogEngine.submit_push_log_req()
    │
    │ ◀─────────────────────────────────────────────┐
    │                                                 │
    ├─▶ 3. 并行 RPC 到全部 Follower                  │
    │        │                                        │
    │        └─▶ PushLogRequest                       │
    │                │                                │
    │                ▼                                │
    │           Follower                              │
    │                │                                │
    │                ├─▶ receive_log()                │
    │                ├─▶ after_flush_log()            │
    │                └─▶ submit_push_log_resp()       │
    │                        │ (ACK)                  │
    │                        └───▶ Leader             │
    │                              │                  │
    │                              ▼                  │
    │                         ack_log()               │
    │                              │                  │
    │                              ▼                  │
    │                     LogSlidingWindow            │
    │                     (检查多数派)                 │
    │                              │                  │
    │                              ▼                  │
    ├─▶ 4. [多数派达成] sliding_cb()                 │
    │        │                                        │
    │        └─▶ committed_end_lsn 推进               │
    │             │                                   │
    │             └─▶ LogGroupEntryHeader             │
    │                 中的 committed_end_lsn           │
    │                     随下一个日志发送             │
    │                                                 │
    ├─▶ 5. 通知上层                                   │
    │     (log_submitted callback / on_success)       │
    │                                                 │
    ▼                                                 │
已提交 (Committed)     ───────────────────────────────┘
```

### 阶段详解

#### 阶段 1：Propose（提交日志）

```cpp
// PalfHandleImpl.submit_log()
// 1. 检查当前是 Leader 且状态正确
// 2. 分配 LSN（单调递增）
// 3. 打包成 LogGroupEntry
// 4. 写入 LogSlidingWindow
// 5. 调用 LogEngine.append_log() 落地
```

#### 阶段 2：Append（本地写入）

```cpp
// LogEngine.append_log() → LogBlockMgr.pwrite()
// 写入 LogGroupEntry 到当前块文件
// LogGroupEntryHeader 包含：
//   - proposal_id: Paxos 提案 ID
//   - committed_end_lsn: 当前已提交的 LSN
//   - accumulated_checksum: 累积校验和
```

#### 阶段 3：Replicate（远程复制）

```cpp
// LogEngine.submit_push_log_req() 发送到所有 Follower
// 支持批量 RPC (need_batch_rpc = true)
// LogSlidingWindow 跟踪每个 ACK
```

#### 阶段 4：Commit（提交通知）

当 `LogSlidingWindow` 检测到某个 LSN 获得多数派 ACK，推进 `committed_end_lsn` 并触发回调。通知事务层和回调链（参考文章 04 — Callback）。

### Follower 日志接收流程

```
LogEngine.submit_push_log_resp()
    │
    ▼
PalfHandleImpl.receive_log()
    │
    ├─▶ 检查 proposal_id 是否匹配
    ├─▶ 检查 prev_lsn 和 prev_log_proposal_id 一致性
    ├─▶ 写入本地 LogBlockMgr
    ├─▶ 回复 ACK (submit_push_log_resp)
    └─▶ 在 after_flush_log 中触发滑动窗口
```

---

## 5. IO 子系统

### 5.1 LogIOWorker（`log_io_worker.h`）

`LogIOWorker` 是 PALF 的异步 IO 线程池，继承自 `ObThreadPool`：

```cpp
class LogIOWorker : public share::ObThreadPool {
  // 单线程（MAX_THREAD_NUM = 1）
  void run1() override final;
  // 提交 IO 任务
  int submit_io_task(LogIOTask *io_task);
};
```

支持 **批量化**：`BatchLogIOFlushLogTaskMgr` 将多个 `LogIOFlushLogTask` 合并为一次批量写入。

### 5.2 LogIOTask（`log_io_task.h`）

IO 任务的类型体系：

```cpp
enum class LogIOTaskType {
  FLUSH_LOG_TYPE = 1,           // 刷日志
  FLUSH_META_TYPE = 2,          // 刷元数据
  TRUNCATE_PREFIX_TYPE = 3,     // 截断前缀块
  TRUNCATE_LOG_TYPE = 4,        // 截断日志
  FLASHBACK_LOG_TYPE = 5,       // 闪回
  PURGE_THROTTLING_TYPE = 6,    // 节流清理
};

class LogIOTask {
  int do_task(int tg_id, IPalfEnvImpl *palf_env_impl);       // 执行
  int after_consume(IPalfEnvImpl *palf_env_impl);           // 后处理
  int64_t get_io_size();                                     // IO 大小
  bool need_purge_throttling();                              // 是否需要节流
};
```

每个任务类型继承 `LogIOTask`，实现各自的 `do_task_()` 和 `after_consume_()`。

### 5.3 LogIOAdapter（`log_io_adapter.h`）

`LogIOAdapter` 是文件系统操作的抽象层，包装了 `ObLocalDevice`：

```cpp
class LogIOAdapter {
  int open(const char *block_path, int flags, mode_t mode, ObIOFd &io_fd);
  int pwrite(const ObIOFd &io_fd, const char *buf,
             const int64_t count, const int64_t offset, int64_t &write_size);
  int pread(const ObIOFd &io_fd, const int64_t count,
            const int64_t offset, char *buf, int64_t &out_read_size);
  int truncate(const ObIOFd &fd, const int64_t offset);
};
```

`LogIODeviceWrapper` 是设备管理器的单例包装，管理底层的 `ObLocalDevice`。

### 5.4 日志写回压（Writing Throttle）

`LogWritingThrottle` 机制防止日志写入过快导致磁盘满或 IO 积压。`LogIOPurgeThrottlingTask` 在清理（purge）后调整节流参数，需要节流的任务（如 `FLUSH_META_TYPE`）通过 `need_purge_throttling_()` 标记。

---

## 6. Learner 与日志同步

### 6.1 LogLearner（`log_learner.h`）

`LogLearner` 是 Learner 节点的表示，用于同步日志但不参与投票：

```cpp
class LogLearner {
  common::ObAddr server_;           // Learner 地址
  common::ObRegion region_;         // 区域信息
  int64_t register_time_us_;        // 注册时间戳（用于超时判断）
  int64_t keepalive_ts_;            // 上次保活时间
};
```

`LogLearnerList` 和 `LogCandidateList` 分别是 Learner 列表和候选列表的类型定义。

### 6.2 FetchLogEngine（`fetch_log_engine.h`）

`FetchLogEngine` 负责从远程节点拉取日志。它维护一个线程池和任务缓存：

```cpp
class FetchLogEngine : public lib::TGTaskHandler {
  int tg_id_;
  ObSEArray<FetchLogTask, DEFAULT_CACHED_FETCH_TASK_NUM> fetch_task_cache_;
  share::SCN replayable_point_;
};
```

`FetchLogTask` 封装了一次日志拉取的参数：

```cpp
class FetchLogTask {
  common::ObAddr server_;      // 目标 server
  FetchLogType fetch_type_;    // 拉取类型（Follower / LeaderReconfirm）
  int64_t proposal_id_;        // 提案 ID
  LSN prev_lsn_;               // 前一条日志的 LSN
  LSN start_lsn_;              // 起始拉取 LSN
  int64_t log_size_;           // 拉取大小
  int64_t log_count_;          // 拉取数量
};
```

### 6.3 多层 Learner 树

OceanBase 的 Learner 机制支持树形同步（parent-child 结构）。Leader 可以直接为 Learner 分配数据源（parent），减少 Leader 的复制负担：

- **`submit_register_parent_req()`** — Learner 向 Leader 注册 parent
- **`submit_retire_parent_req()`** — Learner 解除 parent 关系
- **`submit_learner_keepalive_req()`** — 保活检测

---

## 7. 与前面文章的关联

### 文章 07（LS Tree）

PALF 是 LS Tree 的复制引擎。ObLS 通过 `PalfHandle` 提交日志，日志中包含了 SSTable 的变更。当 PALF 确认日志已提交（多数派达成），ObLS 才将对应的数据变更应用到 LS Tree。

### 文章 10（2PC）

2PC 的 commit log 通过 PALF 复制到多数派：

```
事务层 2PC:
  ┌─────────┐   prepare   ┌──────────┐
  │ Coordinator │ ───────→│ Participant │
  └─────────┘             └────┬─────┘
                               │
                     PALF.submit_log()
                               │
                     ┌─────────▼─────────┐
                     │   Paxos 多数派达成  │
                     └───────────────────┘
                               │
                     on_success() 回调
```

PALF 的 `on_success()` 调用等价于传统 2PC 的 prepare log 完成——在 OceanBase 中，**Paxos 日志替代了 prepare log**。

### 文章 04（Callback）

PALF 的提交回调 `log_submitted callback` 在文章 04 中介绍。当 `LogSlidingWindow::sliding_cb()` 检测到日志被提交，会触发回调链：

```
LogSlidingWindow.sliding_cb()
    → PalfFSCbWrapper.on_submit_log()
    → Transaction Callback (on_success)
    → MVCC Callback (可见性更新)
```

---

## 8. 设计决策

### 8.1 为什么自研 PALF？

| 需求 | Raft 标准实现 | PALF |
|------|---------------|------|
| 批量日志写入 | 单条追加 | LogGroupEntry 批量 |
| 仲裁副本 | 无 | 支持 Arbitration Member |
| 异步 IO | 同步 fsync | LogIOWorker 异步队列 |
| 多层复制 | 无 | Learner 树形复制 |
| WAL 与 page cache 协同 | 通常 O_DIRECT | 利用 page cache |
| 闪回 | 无 | Flashback 支持 |

### 8.2 LogGroupEntry 批量写入的设计意图

将多个 `LogEntry` 打包成一个 `LogGroupEntry` 写入，核心收益：

1. **减少 I/O 次数**：一次 `pwrite()` 写入多个日志，而非逐个写入
2. **减少 RPC 数量**：一次 AppendEntries RPC 携带批量子日志
3. **批量化校验**：`accumulated_checksum_` 一次性验证整组数据一致性
4. **空间效率**：LogGroupEntryHeader 只写一次，多个 LogEntryHeader 紧凑排列

### 8.3 日志块预写（WAL）与 page cache 的协同

PALF 默认利用操作系统 page cache，而非使用 `O_DIRECT`：

- **写入**：`LogBlockMgr.pwrite()` → page cache → 内核异步刷盘
- **读取**：`LogBlockMgr.pread()` → 大概率命中 page cache → 零拷贝读取
- **一致性**：写入后依赖 `fsync`/`fdatasync` 保证持久化

这种设计的优势：写放大低（不需要 double buffer），冷读命中率高（OS 管理缓存）。缺点是 IO 延迟不可预期（page cache 回写时机不确定），但 PALF 通过 `LogIOWorker` 的异步控制和节流机制缓解了这个问题。

### 8.4 Arbitration 仲裁副本

OceanBase 的仲裁副本（Arbitration Member）是 PALF 独有的设计：

> 仲裁副本只参与 Paxos 投票，不存储任何日志数据。

当集群中只有两个全功能副本时，仲裁副本提供第三个投票权，确保 Paxos 多数派（2/3）正常工作。这极大降低了跨 AZ 部署的副本成本。

实现上，`LogConfigMgr` 中专门管理 `ADD_ARB_MEMBER` / `REMOVE_ARB_MEMBER` 操作，`PalfHandleImpl` 提供 `add_arb_member()` 和 `remove_arb_member()` 接口（由 `#ifdef OB_BUILD_ARBITRATION` 保护）。

### 8.5 Leader 切换的 Reconform 流程

Leader 切换后，新 Leader 必须经历 `LogReconfirm`（文章 3.4 节）确认自己拥有所有已提交日志。与标准 Paxos 的 Prepare 阶段相比，PALF 增加了：

1. **WAITING_LOG_FLUSHED** — 保证本地未刷盘的日志都已持久化
2. **RECONFIRM_MODE_META** — 确认访问模式一致（如只读模式）
3. **START_WORKING** — 写一条确认日志，标记正式上任

这确保了在网络分区、Leader 切换等复杂场景下的一致性。

---

## 9. 源码索引

### 主要接口

| 文件 | 类/结构 | 行号 | 用途 |
|------|---------|------|------|
| `palf_handle.h` | `PalfHandle` | L62 | 公共 API 封装，继承 IPalfHandle |
| `palf_handle_impl.h` | `IPalfHandleImpl` | L276 | Paxos 状态机抽象接口 |
| `palf_handle_impl.h` | `PalfStat` | L29 | PALF 状态快照结构 |
| `palf_handle_impl.h` | `PalfDiagnoseInfo` | L71 | 诊断信息 |
| `palf_handle_impl.h` | `FetchLogStat` | L98 | 日志拉取统计 |
| `palf_handle_impl.h` | `BatchFetchParams` | L112 | 批量拉取参数 |

### 核心组件

| 文件 | 类 | 行号 | 用途 |
|------|-----|------|------|
| `log_engine.h` | `LogEngine` | L90 | 日志引擎（存储+网络） |
| `log_config_mgr.h` | `LogConfigChangeType` | L48 | 成员变更类型枚举 |
| `log_config_mgr.h` | `LogConfigMgr` | ~L342 | 成员配置管理 |
| `log_block_mgr.h` | `LogBlockMgr` | L32 | 日志块管理 |
| `log_block_header.h` | `LogBlockHeader` | L16 | 日志块头部 |
| `log_sliding_window.h` | `LogSlidingWindow` | L203 | 滑动窗口（多数派跟踪） |
| `log_state_mgr.h` | `LogStateMgr` | L47 | 角色状态机 |
| `log_reconfirm.h` | `LogReconfirm` | L47 | Leader 确认流程 |
| `log_mode_mgr.h` | `LogModeMgr` | — | 访问模式管理 |
| `fetch_log_engine.h` | `FetchLogEngine` | L63 | 日志拉取引擎 |
| `log_learner.h` | `LogLearner` | L28 | Learner 角色定义 |
| `log_cache.h` | `LogHotCache` | L44 | 日志热缓存 |
| `log_cache.h` | `LogCacheUtils` | L86 | 全局缓存工具 |

### IO 子系统

| 文件 | 类 | 行号 | 用途 |
|------|-----|------|------|
| `log_io_worker.h` | `LogIOWorker` | L56 | IO 工作线程 |
| `log_io_worker.h` | `LogIOWorkerConfig` | L28 | IO Worker 配置 |
| `log_io_task.h` | `LogIOTask` | L53 | IO 任务基类 |
| `log_io_task.h` | `LogIOFlushLogTask` | L118 | 刷日志任务 |
| `log_io_task.h` | `LogIOTruncateLogTask` | L147 | 截断日志任务 |
| `log_io_task.h` | `LogIOFlushMetaTask` | L167 | 刷元数据任务 |
| `log_io_task.h` | `LogIOTruncatePrefixBlocksTask` | L195 | 截断前缀块任务 |
| `log_io_task.h` | `BatchLogIOFlushLogTask` | L222 | 批量刷日志任务 |
| `log_io_task.h` | `LogIOFlashbackTask` | L264 | 闪回任务 |
| `log_io_task.h` | `LogIOPurgeThrottlingTask` | L287 | 节流清理任务 |
| `log_io_task.h` | `LogIOTaskType` | L21 | IO 任务类型枚举 |
| `log_io_adapter.h` | `LogIOAdapter` | L42 | IO 适配层 |
| `log_io_adapter.h` | `LogIODeviceWrapper` | L26 | 设备管理器包装 |

### 日志数据结构

| 文件 | 类/结构 | 行号 | 用途 |
|------|---------|------|------|
| `log_entry.h` | `LogEntry` | L27 | 日志条目 |
| `log_entry_header.h` | `LogEntryHeader` | L14 | 日志条目头部 |
| `log_group_entry.h` | `LogGroupEntry` | L28 | 日志组条目 |
| `log_group_entry_header.h` | `LogGroupEntryHeader` | L16 | 日志组头部 |
| `log_define.h` | — | — | 常量定义（PALF_BLOCK_SIZE 等） |
| `lsn.h` | `LSN` | — | 日志序列号类型 |

---

## 10. 总结

PALF 是 OceanBase 分布式共识的基石。它以 Paxos 为核心，构建了一个高性能、高可用的日志复制框架：

- **性能**：通过 `LogGroupEntry` 批量写入、`LogIOWorker` 异步 IO、`BatchLogIOFlushLogTask` 批量处理、`LogHotCache` 热缓存，实现高吞吐日志写入
- **一致性**：`LogSlidingWindow` 追踪多数派确认、`LogReconfirm` 确保 Leader 切换安全、累积校验和保证数据完整性
- **灵活性**：`LogConfigMgr` 支持丰富的成员变更类型、`LogLearner` 树形同步、Arbitration 仲裁副本、多访问模式
- **可管理性**：写回压控制、块 GC、闪回支持、`PalfStat` 和 `PalfDiagnoseInfo` 诊断信息

理解 PALF 是理解 OceanBase 分布式事务、高可用架构和数据复制策略的关键。下一篇文章将深入 Election 选主模块和 Standby 备库架构。

---

*文件计数：`src/logservice/palf/` 下 132 个文件 | 代码分析工具：doom-lsp (clangd)*
