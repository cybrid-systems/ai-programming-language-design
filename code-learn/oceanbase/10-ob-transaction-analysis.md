# 10-ob-transaction — 分布式两阶段提交与事务管理器

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前 9 篇文章覆盖了 OceanBase 存储引擎的完整软件栈：MVCC Row → Iterator → 写冲突 → Callback → Compact → Freeze → LS Tree → SSTable → SQL DAS。现在是时候回答一个根本问题：**这些分布在多个节点上的数据修改，如何被原子性地提交或回滚？**

答案在 **分布式两阶段提交（2PC）** 和 **事务管理器（Transaction Manager）** 中。

OceanBase 的分布式事务实现与传统 2PC 有显著不同：

1. **用 Paxos 日志替代 prepare log**：传统 2PC 的 PREPARE 阶段需要写 prepare log 确保参与者"承诺"可提交。OceanBase 直接利用 Paxos 共识日志的同步机制，日志一旦通过 Paxos 达成多数派即等价于 prepare 完成。
2. **Cycle 2PC（环形两阶段提交）**：引入层次化的 2PC 结构，在分区迁移过程中仍然可以成功提交事务。每个 LogStream 的参与者形成一个树/环状结构。
3. **ELR（Early Lock Release）**：在 prepare 阶段提前释放行锁，减少锁竞争。
4. **一阶段提交优化**：单参与者事务（单 LogStream）跳过 PREPARE，直接提交。

**核心文件一览**（doom-lsp 确认）：

| 文件 | 行数 | 职责 |
|------|------|------|
| `src/storage/tx/ob_trans_service.h` | ~420 | 事务服务入口，管理生命周期 |
| `src/storage/tx/ob_trans_ctx.h` | ~280 | 事务上下文基类（ObTransCtx） |
| `src/storage/tx/ob_trans_part_ctx.h` | ~1270 | 参与者上下文，核心 2PC 实现 |
| `src/storage/tx/ob_two_phase_committer.h` | ~420 | 2PC 状态机抽象类 |
| `src/storage/tx/ob_one_phase_committer.h` | ~90 | 一阶段提交优化 |
| `src/storage/tx/ob_committer_define.h` | ~140 | 2PC 状态枚举与协议类型 |
| `src/storage/tx/ob_trans_ctx_mgr_v4.h` | ~1000 | 事务上下文管理器 |
| `src/storage/tx/ob_trans_log.h` | ~450 | 事务日志类型定义 |
| `src/storage/tx/ob_tx_elr_handler.h` | ~70 | ELR 提前锁释放 |

---

## 1. 事务服务入口：ObTransService

`ObTransService`（`ob_trans_service.h` L180-417）是 SQL 层与事务层之间的总入口。每个租户拥有一个 `ObTransService` 实例。

```c
// ob_trans_service.h:180-203 - doom-lsp 确认
class ObTransService
{
  // ...
  int start(ObTransService *self);
  int init(const uint64_t tenant_id,
           common::ObAddr self,
           ObTransRpcProxy &rpc_proxy,
           ObLocationAdapter *location_adapter,
           common::ObMySQLProxy &sql_proxy,
           /* ... */);
  int push(const ObTransMsg &msg);
  int handle(const ObTransMsg &msg);
  // ...
};
```

**关键内部组件**（doom-lsp 确认）：

```c
// ob_trans_service.h:349-417
ObITsMgr *ts_mgr_;           // 全局时间戳管理器（GTS 源）
ObTxVersionMgr tx_version_mgr_;  // 事务版本管理器
bool is_running_;             // 运行状态
common::ObAddr self_;         // 本节点地址
uint64_t tenant_id_;          // 租户 ID
ObITransRpc *rpc_;            // RPC 代理
ObITimer *timer_;             // 事务超时定时器
```

### 事务生命周期接口

SQL 层通过以下方法启动、提交和回滚事务：

```c
// ob_trans_service.h 相关方法
int start_trans(ObTxDesc &tx_desc, /* ... */);
int end_1pc_trans(ObTxDesc &trans_desc, /* ... */);  // L328
```

`start_trans` 创建 `ObTxDesc` 事务描述符，分配 `ObTransID`，并选择协调者（Coordinator）。`end_1pc_trans` 提交一阶段事务。对于多参与者的分布式事务，SQL 层会通过 `ObPartTransCtx::commit()` 触发 2PC。

SQL 层发起事务的完整流程：

```
SQL 层
  │
  ├─ ObTransService::start_trans() → 创建 ObTxDesc
  │
  ├─ DAS 层执行 DML → 调用 ObPartTransCtx::start_access()
  │    写 memtable，注册 callback
  │
  └─ ObTransService::end_1pc_trans() 或 ObPartTransCtx::commit()
        → 触发 2PC 或 1PC
```

---

## 2. 事务上下文：ObTransCtx 与 ObPartTransCtx

### 2.1 ObTransCtx — 事务上下文基类

`ObTransCtx`（`ob_trans_ctx.h` L84-280）是所有事务上下文的基类。它继承自 `ObLightHashLink`，支持无锁哈希表的快速查找。

```c
// ob_trans_ctx.h:84 - doom-lsp 确认
class ObTransCtx: public share::ObLightHashLink<ObTransCtx>
{
protected:
  uint64_t tenant_id_;              // 租户 ID
  share::ObLSID ls_id_;             // 归属的 LogStream
  ObTransID trans_id_;              // 事务 ID（全局唯一）
  common::ObAddr addr_;             // 本节点地址
  int64_t trans_expired_time_;      // 事务过期时间
  ObTransService *trans_service_;   // 事务服务引用
  mutable CtxLock lock_;            // 上下文锁
  ObLSTxCtxMgr *ls_tx_ctx_mgr_;    // LS 上下文管理器
  uint32_t session_id_;             // 会话 ID
  MonotonicTs stc_;                 // 单事务计数器
  int64_t part_trans_action_;       // 当前执行的动作
  ObTxCommitCallback commit_cb_;    // 提交回调
  bool for_replay_;                 // 是否为回放创建的上下文
  bool can_elr_;                    // 是否允许提前释放锁
  ObTxELRHandler elr_handler_;      // ELR 处理器
  // ...
};
```

**设计要点**：
- `CtxLock` 是所有事务操作的互斥锁，确保状态转换的原子性
- `ObLightHashLink` 使事务上下文可挂在哈希链表中，支持 `O(1)` 查找
- `for_replay_` 标识是否为日志回放创建的上下文（副本恢复场景）

### 2.2 ObPartTransCtx — 参与者上下文

`ObPartTransCtx`（`ob_trans_part_ctx.h` L155-1270）是 2PC 的核心实现类。它同时继承自 `ObTransCtx` 和 `ObTxCycleTwoPhaseCommitter`：

```c
// ob_trans_part_ctx.h:155-160 - doom-lsp 确认
class ObPartTransCtx : public ObTransCtx,
                       public ObTsCbTask,
                       public ObTxCycleTwoPhaseCommitter
```

**每一个 ObPartTransCtx 同时是一个 2PC 参与者**：作为 `ObTxCycleTwoPhaseCommitter` 的子类，它实现了 `do_prepare()`、`do_commit()`、`do_abort()`、`do_clear()` 等虚拟方法。

**关键成员**（doom-lsp 确认）:

```c
// ob_trans_part_ctx.h 关键成员
ObTxExecInfo exec_info_;            // L168: 事务执行信息，包含 down_state_（持久状态）
ObTxState upstream_state_;          // L1212: 上游（协调者）通知的状态
ObTxMDSCache mds_cache_;            // MDS 缓存
ObTxLogCbGroup reserve_log_cb_group_;  // 预分配的日志回调组
ObTxState upstream_state_;             // 上游推进状态
share::SCN max_2pc_commit_scn_;        // 最大 2PC 提交版本
share::SCN rec_log_ts_;                // 日志时间戳（用于 checkpoint）
share::SCN create_ctx_scn_;            // 上下文创建时间戳
PartCtxSource ctx_source_;             // 上下文来源（正常创建 / 回放 / 迁移）
ObTxLogBigSegmentInfo big_segment_info_; // 大日志段信息
ObPartTransCtx 的状态通过 `downstream_state_`（持久化状态，存储在 `exec_info_.state_`）和 `upstream_state_`（内存中的上游通知状态）共同管理：

```c
// ob_trans_part_ctx.h:957-965 - doom-lsp 确认
virtual ObTxState get_downstream_state() const override
{ return exec_info_.state_; }                          // 持久化状态
virtual int set_downstream_state(const ObTxState state) override
{ set_durable_state_(state); return OB_SUCCESS; }      // 写盘后设置
virtual ObTxState get_upstream_state() const override
{ return upstream_state_; }                            // 内存状态
virtual int set_upstream_state(const ObTxState state) override
{ upstream_state_ = state; return OB_SUCCESS; }
```

### 2.3 事务的三种角色

根据在 2PC 树中的位置，`ObPartTransCtx` 承担不同角色（`ob_committer_define.h` L60-66）：

```c
enum class Ob2PCRole : int8_t
{
  UNKNOWN = -1,
  ROOT = 0,     // 根节点：协调者
  INTERNAL,     // 内部节点：既是下游的协调者又是上游的参与者
  LEAF,          // 叶子节点：纯参与者
};
```

对应的查询方法（`ob_two_phase_committer.h` L275-280）：

```c
bool is_root() const { return Ob2PCRole::ROOT == get_2pc_role(); }
bool is_leaf() const { return Ob2PCRole::LEAF == get_2pc_role(); }
bool is_internal() const { return Ob2PCRole::INTERNAL == get_2pc_role(); }
```

---

## 3. 2PC 状态机：ObTxCycleTwoPhaseCommitter

### 3.1 状态定义

`ObTxState`（`ob_committer_define.h` L68-78）定义了 2PC 的完整状态集合：

```c
enum class ObTxState : uint8_t
{
  UNKNOWN = 0,
  INIT = 10,            // 初始状态
  REDO_COMPLETE = 20,   // Redo 日志完成
  PREPARE = 30,         // Prepare 阶段
  PRE_COMMIT = 40,      // Pre-commit 阶段（优化）
  COMMIT = 50,          // Commit 阶段
  ABORT = 60,           // Abort 阶段
  CLEAR = 70,           // Clear 阶段（清理）
  MAX = 100
};
```

状态之间的推进关系：

```
INIT ──(redo 完成)──→ REDO_COMPLETE ──(prepare)──→ PREPARE
  │                                                  │
  │                                              (pre_commit)
  │                                                  │
  │                                              PRE_COMMIT
  │                                                  │
  │                                            (commit/abort)
  │                                                  │
  │                                            COMMIT / ABORT
  │                                                  │
  │                                              (clear)
  │                                                  │
  │                                              CLEAR
  │                                                  │
  └──────────────────(abort 回滚)───────────────────┘
```

### 3.2 ObTxCycleTwoPhaseCommitter

`ObTxCycleTwoPhaseCommitter`（`ob_two_phase_committer.h` L48-420）是 2PC 核心状态机的抽象类。其设计注释清晰地说明了设计哲学：

> "ObTxCycleTwoPhaseCommitter is the implementation of the Optimized Oceanbase two phase commit that introduces hierarchical cycle structure to commit the txn successfully during the transfer process."
>
> "Also ObTxCycleTwoPhaseCommitter is an abstraction of commitable instance that you can implement."

**状态转换要求原子性**（来自注释 L40-44）：

> 1. All public interface of ObTxCycleTwoPhaseCommitter need be protected by outer exclusive access method.
> 2. All inherited methods should not be exclusively protected again for self invocation.

**核心接口**：

```c
// ob_two_phase_committer.h - doom-lsp 确认

// 触发 2PC
int two_phase_commit();     // L62
int two_phase_abort();      // L68

// 消息处理器（异步、尽力投递）
int handle_2pc_req(const ObTwoPhaseCommitMsgType msg_type);    // L83
int handle_2pc_resp(const ObTwoPhaseCommitMsgType msg_type,
                    const int64_t participant_id);              // L84
int handle_timeout();       // L109: 超时处理
int handle_reboot();        // L110: 重启恢复
int leader_takeover();      // L116: 接管 leader
int leader_revoke();        // L117: 撤销 leader

// 日志回调（异步日志同步完成时的调用）
int apply_log(const ObTwoPhaseCommitLogType log_type);     // L102
int replay_log(const ObTwoPhaseCommitLogType log_type);    // L103

// 具体消息处理（L123-166）
int handle_2pc_prepare_request();
int handle_2pc_prepare_response(const int64_t participant_id);
int handle_2pc_commit_request();
int handle_2pc_abort_request();
int handle_2pc_pre_commit_request();
int handle_2pc_clear_request();
// ... 以及 orphan（孤儿消息）的各种处理
```

**虚方法（由 ObPartTransCtx 实现）**：

```c
// ob_two_phase_committer.h L200-209 - doom-lsp 确认
virtual int do_prepare(bool &no_need_submit_log) = 0;
virtual int do_pre_commit(bool& need_wait) = 0;
virtual int do_commit() = 0;
virtual int do_abort() = 0;
virtual int do_clear() = 0;

virtual int on_prepare() = 0;  // prepare 完成后的回调
virtual int on_commit() = 0;   // commit 完成后的回调
virtual int on_abort() = 0;
virtual int on_clear() = 0;
```

`do_xxx` 方法执行"进入 xxx 阶段的内存操作"（如释放锁、设置版本号），`on_xxx` 方法在 xxx 阶段的日志落盘后触发回调。

### 3.3 日志类型与消息类型

**日志类型**（`ob_committer_define.h` L30-38）：

```c
enum class ObTwoPhaseCommitLogType : uint8_t
{
  OB_LOG_TX_INIT = 0,
  OB_LOG_TX_COMMIT_INFO,   // 提交信息日志
  OB_LOG_TX_PREPARE,       // prepare 日志
  OB_LOG_TX_PRE_COMMIT,    // pre_commit 日志（优化）
  OB_LOG_TX_COMMIT,        // commit 日志
  OB_LOG_TX_ABORT,         // abort 日志
  OB_LOG_TX_CLEAR,         // clear 日志（清理）
  OB_LOG_TX_MAX,
};
```

**消息类型**（`ob_committer_define.h` L42-57）：

```c
enum class ObTwoPhaseCommitMsgType : uint8_t
{
  OB_MSG_TX_UNKNOWN = 0,
  OB_MSG_TX_PREPARE_REQ,     // prepare 请求
  OB_MSG_TX_PREPARE_RESP,    // prepare 响应
  OB_MSG_TX_PRE_COMMIT_REQ,  // pre_commit 请求
  OB_MSG_TX_PRE_COMMIT_RESP, // pre_commit 响应
  OB_MSG_TX_COMMIT_REQ,      // commit 请求
  OB_MSG_TX_COMMIT_RESP,     // commit 响应
  OB_MSG_TX_ABORT_REQ,       // abort 请求
  OB_MSG_TX_ABORT_RESP,      // abort 响应
  OB_MSG_TX_CLEAR_REQ,       // clear 请求
  OB_MSG_TX_CLEAR_RESP,      // clear 响应
  OB_MSG_TX_PREPARE_REDO_REQ,  // prepare + redo 合并请求
  OB_MSG_TX_PREPARE_REDO_RESP, // prepare + redo 合并响应
  OB_MSG_TX_MAX,
};
```

---

## 4. 2PC 完整数据流

### 4.1 跨节点 2PC 时序图

```
SQL 层 (调度者)            Coord (根节点)           Part (叶子/内部节点)
    │                          │                          │
    │───── commit() ──────────→│                          │
    │                          │                          │
    │                       [步骤 1: PREPARE]             │
    │                          │                          │
    │                          │ (用 Paxos 日志代替       │
    │                          │  传统 prepare log)        │
    │                          │                          │
    │                          │──── PREPARE_REQ ────────→│
    │                          │       (RPC)              │
    │                          │                          │
    │                          │    flush mini log         │
    │                          │    (Paxos 同步)           │
    │                          │                          │
    │                          │←── PREPARE_RESP ─────────│
    │                          │                          │
    │                       [步骤 2: PRE_COMMIT]           │
    │                          │                          │
    │                          │── PRE_COMMIT_REQ ───────→│
    │                          │                          │
    │                          │← PRE_COMMIT_RESP ────────│
    │                          │                          │
    │                       [步骤 3: COMMIT]              │
    │                          │                          │
    │   写 commit log (Paxos)  │                          │
    │   设置 trans_version     │                          │
    │                          │                          │
    │                          │──── COMMIT_REQ ─────────→│
    │                          │    (含 trans_version)    │
    │                          │                          │
    │                          │    trans_commit callback │
    │                          │    fill trans_version    │
    │                          │    cleanup               │
    │                          │                          │
    │                          │←── COMMIT_RESP ──────────│
    │                          │                          │
    │                       [步骤 4: CLEAR]               │
    │                          │                          │
    │                          │──── CLEAR_REQ ──────────→│
    │                          │                          │
    │←── 通知调度者 ──────────│←── CLEAR_RESP ───────────│
    │    commit 完成          │                          │
```

### 4.2 各阶段的 ObPartTransCtx 实现

**do_prepare 阶段**（`ob_trans_part_ctx.h`）：

```c
// ob_trans_part_ctx.h - doom-lsp 确认：submit 方法
int submit_log(const ObTwoPhaseCommitLogType &log_type) override;
```

在 `do_prepare()` 中：
1. 调用 `submit_log(OB_LOG_TX_PREPARE)` 提交 Paxos 日志
2. Paxos 日志通过 `apply_prepare_log()` 回调确认落盘
3. `on_prepare()` 被调用，标记状态为 PREPARE
4. 如果有 ELR 能力，在此阶段提前释放行锁

**do_commit 阶段**：

在 `do_commit()` 中（通过 `ObPartTransCtx::tx_end_(true)`）：
1. 调用 `generate_commit_version_()` 从 GTS 获取提交版本号
2. 调用 `submit_commit_log_()` 写 commit 日志到 Paxos
3. 日志落盘后，`on_commit()` 被调用：
   - 设置 `trans_version`，通知 MVCC 行此版本可见
   - 触发事务 callback（`trans_commit`，即 04 篇讨论的 callback 机制）
   - 清理行锁

**do_abort 阶段**：

在 `do_abort()` 中：
1. 调用 `submit_abort_log_()` 写 abort 日志
2. 日志落盘后，`on_abort()` 被调用：
   - 标记事务为已中止
   - 触发事务 callback（`trans_abort`）
   - 释放所有行锁

### 4.3 驱动状态推进

`ObTxCycleTwoPhaseCommitter` 的 `drive_self_2pc_phase()` 方法（L215）负责推进当前节点的 2PC 状态：

> 1. 收到新的请求消息时，参与者进入下一阶段
> 2. 调用 `do_xxx` 执行下一阶段的所有内存操作
> 3. 最后设置 `upstream_state`
> 4. 如果 `upstream_state` 大于 `downstream_state`，重试 submit log

```c
// ob_two_phase_committer.h:215
int drive_self_2pc_phase(ObTxState next_phase);
```

消息的接收与响应的分发通过 `handle_2pc_req` 和 `handle_2pc_resp` 完成，内部根据消息类型分发到具体的 `handle_2pc_xxx_request/response_impl_` 方法（L361-371）。

---

## 5. Cycle 2PC：分区迁移场景的容错

OceanBase 的 2PC 引入了 **Cycle（环形）结构**，这是针对**分区迁移**场景的设计。设计注释（`ob_two_phase_committer.h` L96-104）解释了动机：

```
                +--------------------+
                |       Txn1         |
                |  Participant：[L1] |
                +--------+-----------+
                         |
          +----write-----+
          |
          |
 +--------v---------+           +------------------+
 |  +--+ +--+ +--+  |           |  +--+ +--+       |
 |  |P1| |P2| |P3|  |           |  |P4| |P5|       |
 |  +--+ +--+ +--+  |           |  +--+ +--+       |
 |                  |           |                  |
 |  Log Stream:L1   |           |  Log Stream:L2   |
 +------------------+           +------------------+
                Figure 1: Normal Action

                +--------------------+
                |       Txn1         |
                |  Participant：[L1] |
                +--------------------+

 +------------------+            +------------------+
 |  +--+ +--+       |            |  +--+ +--+ +--+  |
 |  |P1| |P2|       |            |  |P4| |P5| |P3|  |
 |  +--+ +--+       |-transfer-> |  +--+ +--+ +--+  |
 |                  |            |                  |
 |  Log Stream:L1   |            |  Log Stream:L2   |
 +------------------+            +------------------+
                 Figure 2: Transfer Action
```

**问题**：当分区 P3 从 L1 迁移到 L2 时，Txn1 可能不知道这个变化。如果 2PC 日志先于迁移日志落盘，迁移过程需要把 2PC 状态带到目标端；否则需要采用 Cycle 2PC 方式——父节点等待子节点的 2PC 状态响应后再响应父节点。

关键方法：

```c
// ob_two_phase_committer.h:350 - doom-lsp 确认
virtual int merge_intermediate_participants() = 0;
```

此方法合并迁移过程中产生的中间参与者，确保 2PC 树的一致性。

---

## 6. 一阶段提交优化

对于仅涉及一个 LogStream 的单参与者事务，OceanBase 使用 `ObTxOnePhaseCommitter`（`ob_one_phase_committer.h` L30-90）优化为一阶段提交：

```c
// ob_one_phase_committer.h
class ObTxOnePhaseCommitter
{
public:
  int one_phase_commit(ObICommitCallback &cb);
  int apply_log();
  int handle_timeout();
  int handle_reboot();
  int leader_takeover();
  int leader_revoke();

protected:
  virtual int do_commit() = 0;
  virtual int on_commit() = 0;
  virtual int do_abort() = 0;
  virtual int on_abort() = 0;
  virtual int submit_log(const ObTwoPhaseCommitLogType& log_type) = 0;
  // ...
};
```

**一阶段 vs 两阶段**：

| 特性 | 一阶段提交 | 两阶段提交 |
|------|-----------|-----------|
| 参与者数 | 1 个 LogStream | 2+ 个 LogStream |
| Prepare 阶段 | 跳过 | 需要 |
| 日志数量 | 少（无 prepare log） | 多（prepare + commit） |
| 延迟 | 低 | 较高（跨节点 RPC） |
| 协调者 | 无（直接提交到 Paxos） | 需要协调者 |

`ObTransService::end_1pc_trans()`（`ob_trans_service.h` L328）是单参与者事务的提交入口。

---

## 7. 事务上下文管理器：ObTxCtxMgr / ObLSTxCtxMgr

### 7.1 层级结构

`ObTxCtxMgr`（`ob_trans_ctx_mgr_v4.h` L793-998）是全局事务上下文管理器，内部维护了一个 `ls_tx_ctx_mgr_map_`（LS → ObLSTxCtxMgr 的映射）：

```
ObTxCtxMgr (全局)
  │
  ├── ObLSTxCtxMgr (LS1)
  │     └── hash map: tx_id → ObPartTransCtx*
  │
  ├── ObLSTxCtxMgr (LS2)
  │     └── hash map: tx_id → ObPartTransCtx*
  │
  └── ...
```

### 7.2 ObLSTxCtxMgr

`ObLSTxCtxMgr`（`ob_trans_ctx_mgr_v4.h` L165-760）管理单个 LogStream 上所有活跃的事务上下文。

**关键方法**（doom-lsp 确认）：

```c
// ob_trans_ctx_mgr_v4.h:242
int create_tx_ctx(ObTxCreateArg &arg, ObTransCtx *&tx_ctx);

// L253
int get_tx_ctx(const ObTransID &tx_id, ObTransCtx *&tx_ctx);

// L268
int revert_tx_ctx(ObTransCtx *tx_ctx);

// L277
int del_tx_ctx(ObTransCtx *tx_ctx);

// L301
int kill_all_tx();

// L305
int block_tx();

// L508
int switch_to_follower_gracefully();

// L500
int switch_to_leader();
```

**主要内部结构**（doom-lsp 确认）：

```c
// ob_trans_ctx_mgr_v4.h:662-721
ObLSTxCtxMap *ls_tx_ctx_map_;          // tx_id 到 ObPartTransCtx* 的哈希表
ObTxTable *tx_table_;                   // 事务表（持久化的事务状态快照）
ObLSTxLogWriter *ls_log_writer_;         // LS 日志写入器
ObLSTxLogAdapter *tx_log_adapter_;      // 日志适配器
SpinRWLock rwlock_;                     // 读写锁
int64_t total_tx_ctx_count_;            // 事务上下文总数
int64_t active_tx_count_;               // 活跃事务数
share::SCN aggre_rec_scn_;             // 聚合的 rec log scn（用于 checkpoint）
bool is_leader_serving_;                // 是否 leader 提供服务
MonotonicTs leader_takeover_ts_;        // leader 接管时间戳
```

**事务发现流程**：

```
获取 tx_ctx：
  ObTxCtxMgr::get_tx_ctx(tx_id)
    → ObTxCtxMgr::get_ls_tx_ctx_mgr(ls_id)
      → ObLSTxCtxMgr::get_tx_ctx(tx_id)
        → hash map lookup → inc ref → return ObTransCtx*

回放场景：
  ObLSTxCtxMgr::replay_start_working_log()  // L518
    → replay 过程中创建 ObPartTransCtx，通过 create_tx_ctx 注册
```

### 7.3 Leader 切换

`ObLSTxCtxMgr` 的 leader 切换方法处理事务的弹性和恢复：

```c
// ob_trans_ctx_mgr_v4.h:500 - doom-lsp 确认
int switch_to_leader();    // 切换为 leader：接管未完成的事务

// ob_trans_ctx_mgr_v4.h:508
int switch_to_follower_gracefully();  // 切换为 follower

// ob_trans_ctx_mgr_v4.h:513
int resume_leader();       // 恢复 leader 服务
```

`switch_to_leader()` 中会遍历 `tx_table_`（持久化事务表）中所有未决事务，创建对应的 `ObPartTransCtx` 并通过 `ObTxCycleTwoPhaseCommitter::leader_takeover()` 驱动它们到最终状态。

---

## 8. ELR（Early Lock Release）在 2PC 中的体现

ELR 的核心思想是：**在 prepare 阶段结束后即可提前释放行锁，无需等待 commit 日志落盘**。

### 8.1 ObTxELRHandler

```c
// ob_tx_elr_handler.h:28-70 - doom-lsp 确认
enum TxELRState
{
  ELR_INIT = 0,         // 初始状态
  ELR_PREPARING = 1,    // 日志已提交给 clog，准备阶段
  ELR_PREPARED = 2      // GTS 已推过 global trans version，完全准备
};

class ObTxELRHandler
{
public:
  int check_and_early_lock_release(bool row_updated, ObPartTransCtx *ctx);
  void set_elr_prepared() { ATOMIC_STORE(&elr_prepared_state_, TxELRState::ELR_PREPARED); }
  bool is_elr_prepared() const { return TxELRState::ELR_PREPARED == ATOMIC_LOAD(&elr_prepared_state_); }
  // ...
private:
  TxELRState elr_prepared_state_;
  memtable::ObMemtableCtx *mt_ctx_;
};
```

### 8.2 ELR 在 2PC 流中的位置

```
传统 2PC 锁持有时间：
  PREPARE ──────────────┼───────────────────── COMMIT ── CLEAR
                       ↑ 锁持有
                       ↑ 锁释放

OceanBase ELR：
  PREPARE ── ELR 释放锁 ────┼───────────────── COMMIT ── CLEAR
            ↑ 锁释放         ↑ 日志仍在 Paxos 同步中
```

在 `ObPartTransCtx::do_prepare()` 中的逻辑：
1. 写入 prepare 日志到 Paxos
2. 如果 `can_elr_` 为 true，调用 `elr_handler_.check_and_early_lock_release()` 提前释放行锁
3. 等待 commit log 落盘后，设置 `trans_version`
4. 最终清理（CLEAR）

`ObTransCtx` 中的 `can_elr_` 标志（`ob_trans_ctx.h`，doom-lsp 确认）控制是否启用 ELR。`ObLSTxCtxMgr` 中的 `is_stopped_` 和 `is_normal_blocked_` 状态影响 ELR 决策。

ELR 的风险存在于事务最终可能 abort 的场景——释放的行锁已被其他事务获取并提交。OceanBase 通过确保 ELR 只用于 prepare 后最终 commit 概率极高的事务来控制这一风险。

---

## 9. 事务日志：ObTransLog

`ObTransLog`（`ob_trans_log.h` L35-80）是所有事务日志的基类：

```c
// ob_trans_log.h:35-55 - doom-lsp 确认
class ObTransLog
{
  OB_UNIS_VERSION(1);
protected:
  int64_t log_type_;              // 日志类型（OB_LOG_UNKNOWN 等）
  ObTransID trans_id_;            // 事务 ID
  uint64_t cluster_id_;           // 集群 ID
  uint64_t cluster_version_;      // 集群版本
};
```

事务日志的具体类型包括：
- `ObTxRedoLog` — Redo 日志，记录数据修改
- `ObTxCommitInfoLog` — 提交信息日志
- `ObTxPrepareLog` — Prepare 日志
- `ObTxCommitLog` — Commit 日志（含 `commit_version`）
- `ObTxAbortLog` — Abort 日志
- `ObTxClearLog` — Clear 日志

这些日志最终通过 `ObLSTxLogAdapter` 写入底层的 Paxos 日志引擎（palf）。日志回调（`ObTxLogCb`）在 Paxos 确认多数派后触发 `apply_log()` / `replay_log()`。

---

## 10. 与前面 9 篇文章的关联矩阵

| 文章 | 关联点 |
|------|--------|
| **01-mvcc-row** | `trans_version_` 的赋值发生在 2PC commit 阶段。`ObPartTransCtx::on_commit()` 中设置 `commit_version`，MVCC 行据此判断可见性。事务版本通过 `update_publish_version_()` 传播到 MVCC 行。 |
| **02-mvcc-iterator** | Iterator 读数据时，需要检查 `ObMvccTransNode` 的 `trans_version_` 是否 ≤ `snapshot_version`——这个 `trans_version_` 由 2PC 提交阶段设置。 |
| **03-write-conflict** | 写写冲突检测在 `start_access()` 中发生。如果行锁已被其他未提交事务持有，根据隔离级别等待或报错。ELR 释放行锁后，等待事务可以获取锁。 |
| **04-callback** | `trans_commit` / `trans_abort` 回调是 2PC 结果的分发机制。`ObPartTransCtx::on_commit()` 中通过 `ObTxCommitCallback` 通知所有注册的回调。`ObPartTransCtx` 中的 `commit_cb_` 直接继承自 `ObTransCtx`。 |
| **05-compact** | 事务提交后，旧版本（已比 `snapshot_version` 老）可以被 compact 掉。`ObPartTransCtx::on_commit()` 通知 compact 线程清理。 |
| **06-freezer** | Freeze 前需要等待所有未提交事务的日志落盘。`ObLSTxCtxMgr::get_ls_min_uncommit_tx_prepare_version()` 获取最小的未提交 prepare 版本，freezer 等待到该版本的处理完成。 |
| **07-ls-logstream** | 每个 LogStream 拥有自己的 `ObLSTxCtxMgr`。2PC 消息通过 LogStream 的 RPC 机制路由。Paxos 日志引擎（palf）提供 2PC 日志的持久化保证。 |
| **08-ob-sstable** | SSTable 中存储的行数据包含 `trans_version`，由 2PC commit 阶段决定。SSTable 的 `read` 操作需检查事务版本可见性。 |
| **09-sql-executor** | DAS 层的 DML 任务通过 `ObPartTransCtx::start_access()` 执行，写操作完成后注册 callback。SQL 层的 `commit` 语句最终调用 2PC。 |

**关键连接点图**：

```
SQL COMMIT ──→ ObTransService ──→ ObPartTransCtx::commit()
                                        │
                                        ▼
                                  ObTxCycleTwoPhaseCommitter
                                        │
                                        ├── do_prepare()
                                        │     └── submit_log(OB_LOG_TX_PREPARE)
                                        │           → Paxos 同步
                                        │           → release row lock (ELR)
                                        │
                                        ├── on_prepare()
                                        │     └── callback 通知
                                        │
                                        ├── do_commit()
                                        │     └── generate_commit_version_()
                                        │         submit_log(OB_LOG_TX_COMMIT)
                                        │           → Paxos 同步
                                        │
                                        ├── on_commit()
                                        │     ├── 设置 trans_version_ (→ 01 mvcc-row)
                                        │     ├── trans_commit callback (→ 04 callback)
                                        │     └── 通知 compact (→ 05 compact)
                                        │
                                        └── do_clear()
                                              └── cleanup
```

---

## 11. 设计决策分析

### 11.1 为什么用 Paxos 日志替代 prepare log？

传统 2PC 中，prepare 阶段要求参与者写 prepare log 以确保"我承诺可以提交，不要问我第二次"。OceanBase 的设计省去了显式的 prepare log，理由如下：

1. **Paxos 日志本身就是承诺**：每一轮 Paxos 写入包含日志内容和多数派确认。一旦多数派确认，日志就是"prepare 完成"。
2. **减少一轮写入**：传统 2PC：prepare log → ack → commit log。OceanBase：Paxos commit log（prepare 通过 Paxos 隐式完成）。
3. **故障恢复由 Paxos 保证**：如果协调者崩溃，新 leader 通过 Paxos re-reading 日志即可知道事务状态，无需额外协调。

### 11.2 Cycle 2PC 的设计动机

在分区迁移频繁的分布式环境中，传统的树形 2PC 存在"参与者集可能变化"的问题。Cycle 2PC 的环形结构提供了：

1. **迁移容错**：partition 迁移时，2PC 状态可以跟随迁移
2. **中间节点合并**：`merge_intermediate_participants()` 确保迁移过程中新增的参与者被纳入
3. **避免死锁**：`is_real_upstream()` 防止环形迁移导致的死锁

### 11.3 ELR 的风险与收益

**收益**：
- 降低行锁持有时间，提高并发度
- 减少锁等待和死锁概率

**风险**：
- 如果 prepare 后事务最终 abort，已释放的行锁可能已被其他事务修改
- 写偏序异常（write skew）的可能性增加

**缓解措施**：
- ELR 只适用于 prepare 阶段成功（日志已同步）后
- `ObTxELRHandler::check_and_early_lock_release()` 中有复杂的检查逻辑
- 租户级别可配置：`can_tenant_elr_`（`ob_trans_service.h` L195）

### 11.4 一阶段 vs 两阶段

| 场景 | 选择的提交协议 | 原因 |
|------|---------------|------|
| 单分区 INSERT/UPDATE | 一阶段提交 | 无需跨节点协调，跳过 PREPARE |
| 跨分区分布式事务 | 两阶段提交 | 需要原子性保证 |
| XA 事务 | 两阶段提交 + XA 协议 | 兼容外部事务管理器 |
| 复制表（Dup Table） | 特殊 2PC 处理 | 需要多个副本同步 |

---

## 12. 源码索引

| 符号 | 位置（doom-lsp 确认） | 行号 |
|------|----------------------|------|
| `ObTransService` | `ob_trans_service.h` | 180 |
| `ObTransCtx` | `ob_trans_ctx.h` | 84 |
| `ObPartTransCtx` | `ob_trans_part_ctx.h` | 155 |
| `ObTxCycleTwoPhaseCommitter` | `ob_two_phase_committer.h` | 48 |
| `ObTxOnePhaseCommitter` | `ob_one_phase_committer.h` | 30 |
| `ObTxState` enum | `ob_committer_define.h` | 68 |
| `ObTwoPhaseCommitLogType` | `ob_committer_define.h` | 30 |
| `ObTwoPhaseCommitMsgType` | `ob_committer_define.h` | 42 |
| `Ob2PCRole` | `ob_committer_define.h` | 60 |
| `ObTxELRHandler` | `ob_tx_elr_handler.h` | 39 |
| `TxELRState` | `ob_tx_elr_handler.h` | 28 |
| `ObLSTxCtxMgr` | `ob_trans_ctx_mgr_v4.h` | 165 |
| `ObTxCtxMgr` | `ob_trans_ctx_mgr_v4.h` | 793 |
| `ObTransLog` | `ob_trans_log.h` | 35 |
| `downstream_state_` (via exec_info_.state_) | `ob_trans_part_ctx.h` | 957 |
| `upstream_state_` | `ob_trans_part_ctx.h` | 1212 |
| `do_prepare()` | `ob_trans_part_ctx.h` | (override, ~997) |
| `do_commit()` | `ob_trans_part_ctx.h` | (override) |
| `submit_log()` | `ob_trans_part_ctx.h` | 457 |
| `generate_commit_version_()` | `ob_trans_part_ctx.h` | 720 |

---

## 13. 总结

第 10 篇文章作为整个系列的第 10 篇也是最后一篇，将前面 9 篇的核心机制汇聚到分布式事务的原子性保证中：

**分布式 2PC** 是 OceanBase 跨节点数据一致性的基础协议。通过 `ObTxCycleTwoPhaseCommitter` 状态机，OceanBase 实现了支持分区迁移的 Cycle 2PC，用 Paxos 日志替代了传统 prepare log，并引入了 ELR 优化以减少行锁争用。

**事务管理器**（`ObTxCtxMgr` / `ObLSTxCtxMgr`）为每个 LogStream 维护活跃事务上下文哈希表，支持 O(1) 的事务查找、leader 切换、回放恢复等能力。

从 01 的 MVCC 行结构到 10 的 2PC 事务管理器，这 10 篇文章完整呈现了 OceanBase 存储引擎从数据表示、并发控制、物理存储到分布式事务的全链路。核心设计哲学一脉相承：

- **嵌入式数据结构**（MVCC 链表、LS Tree）
- **无锁 + CAS 原子操作**（TransNodeFlag、CtxLock）
- **异步回调驱动**（log callback、2PC callback）
- **Paxos 嵌入所有组件**（日志、事务、副本同步）
