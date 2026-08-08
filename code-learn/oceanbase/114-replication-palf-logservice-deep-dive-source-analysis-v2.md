# 114-replication-palf-logservice-deep-dive — OceanBase Replication (PALF + LogService) 深度源码分析 v2

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/logservice/ob_log_handler.{h,cpp}` + `src/logservice/palf/log_block_header.h` + `src/logservice/palf/log_ack_info.h` + `src/logservice/palf/log_engine.{h,cpp}` + `src/logservice/palf/election/` (algorithm/interface/message/utils) + `src/logservice/ob_log_service.h` + 集成 #108 v2 CLog + #110 v2 Tx）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #114 系列的 v2 deep-dive 版**。PALF (Paxos And Log Framework) 是 OB **核心共识 + 日志存储** 子系统 — 跨 LogService/CLog/Tx/选举全栈。基于 Multi-Paxos 协议 + Log Block 磁盘存储 + per-member Ack tracking + Election ballot + Membership changes,提供 **强一致性 + 高可用** 的 distributed log service。

本文聚焦 **12 个核心问题**：

1. **PALF 拓扑** — `src/logservice/` 803 文件 + `src/logservice/palf/` 核心 + `election/` 子模块
2. **ObILogHandler 接口** — append / seek / get_role / change_replica_num / add_member / remove_member / ...
3. **LogBlockHeader 结构** — magic=0x4942 (InfoBlock) + version + flag + min_lsn/min_scn/max_scn + curr_block_id + palf_id + checksum
4. **LsnTsInfo + LogMemberAckInfo** — per-member Paxos ack tracking
5. **Multi-Paxos 协议** — propose → accept (majority) → learn → committed
6. **Election 机制** — leader election via monotonic ballot (proposal_id)
7. **Replica 同步** — leader append → replicate followers → ack majority
8. **Membership Changes** — add_member / remove_member / replace_member / add_learner / switch_learner_to_acceptor
9. **Log Block 存储** — write/read/GC + block 循环复用 (REUSED_BLOCK_MASK)
10. **Fetch Log** — catchup via fetch_log_engine (replica 落后追平)
11. **Log Cache + Checksum** — hot blocks in memory + per-block checksum
12. **集成 #108 v2 CLog + #110 v2 Tx** — PALF 是 Clog + Tx 的底层 consensus 实现

---

## 1. PALF 拓扑（OB 5.0.2.0 实读）

OB PALF + LogService 跨 `src/logservice/` 主导目录:

```
src/logservice/                                       — LogService + PALF 全栈 (803 files)
├── ob_log_handler.{h,cpp}                            # ★ ObLogHandler (ObILogHandler 实现)
├── ob_log_handler_base.{h,cpp}                       # 基类 (lock + role + proposal_id)
├── ob_log_service.{h,cpp}                            # ★ Log Service RPC 服务
├── ob_log_base_header.{h,cpp}                        # Log base header
├── ob_log_base_type.h                                # Log base type
├── ob_log_flashback_service.{h,cpp}                  # Flashback service (回溯)
├── ob_log_external_storage_*.{h,cpp}                 # 外部存储 (备份/归档)
├── ob_log_monitor.{h,cpp}                            # Log monitor (监控)
├── ob_garbage_collector.{h,cpp}                      # Log GC
├── ob_locality_adapter.{h,cpp}                       # Locality adapter
├── ob_location_adapter.{h,cpp}                       # Location adapter
├── palf/                                             # ★ PALF 核心 (~50 files)
│   ├── palf_handle.{h,cpp}                           # PALF handle (主接口)
│   ├── palf_base_info.{h,cpp}                        # PALF base info (rebuild 用)
│   ├── palf_iterator.{h,cpp}                         # Log iterator
│   ├── election/                                     # ★ Election submodule (~30 files)
│   │   ├── algorithm/                                # Paxos algorithm
│   │   ├── interface/                                # Election interface
│   │   ├── message/                                  # Election message
│   │   └── utils/                                    # Election utils
│   ├── log_block_handler.{h,cpp}                     # ★ Log block read/write
│   ├── log_block_header.{h,cpp}                      # ★ LogBlockHeader struct
│   ├── log_block_mgr.{h,cpp}                         # Log block manager
│   ├── log_block_pool_interface.{h,cpp}              # Block pool interface
│   ├── log_cache.{h,cpp}                             # Log cache (hot blocks)
│   ├── log_checksum.{h,cpp}                          # Per-block checksum
│   ├── log_config_mgr.{h,cpp}                        # Config manager
│   ├── log_engine.{h,cpp}                            # ★ Log engine (主 engine)
│   ├── log_entry.{h,cpp}                             # Log entry (单条 log)
│   ├── log_entry_header.{h,cpp}                      # Log entry header
│   ├── log_group_buffer.{h,cpp}                      # Group buffer
│   ├── log_group_entry.{h,cpp}                       # Group entry (批 log)
│   ├── log_group_entry_header.{h,cpp}                # Group entry header
│   ├── log_io_adapter.{h,cpp}                        # IO adapter
│   ├── log_io_context.{h,cpp}                        # IO context
│   ├── log_io_task.{h,cpp}                           # IO task
│   ├── log_ack_info.h                                # ★ LsnTsInfo + LogMemberAckInfo
│   ├── log_define.{h,cpp}                            # Log defines
│   ├── log_storage.h                                 # Log storage interface
│   ├── log_net_service.h                             # Network service
│   ├── log_meta.h                                    # Log metadata
│   ├── log_shared_queue_thread.{h,cpp}               # Shared queue thread
│   ├── fetch_log_engine.{h,cpp}                      # ★ Fetch log engine (catchup)
│   ├── fixed_sliding_window.h                        # Fixed sliding window
│   └── block_gc_timer_task.{h,cpp}                   # Block GC timer
├── ipalf/                                            # ★ PALF interface (跨语言绑定)
├── logrpc/                                           # Log RPC (ob_log_rpc_proxy)
├── ipalf/                                            # IPalf interface
├── leader_coordinator/                               # Leader coordinator
├── obcdcservice/                                     # CDC service (log to downstream)
├── oblogminer/                                       # Log miner (回溯分析)
├── applyservice/                                     # Apply service (log → apply)
├── archiveservice/                                   # Archive service
├── restoreservice/                                   # Restore service
├── restoretool/                                      # Restore tool
├── replayservice/                                    # Replay service
├── data_dictionary/                                  # Data dictionary
├── common_util/                                      # Common utils
└── ... (~800 files total)
```

**关键设计**:
- **PALF = Paxos + Log Framework** — OB 自研的 Multi-Paxos + Log 存储 framework
- **per-tenant per-zone Log Stream (LS)** — 每个 tenant 每个 zone 有独立 LS, LS 内有 PALF group
- **3 role**: LEADER (接受 append) / FOLLOWER (replicate + ack) / LEARNER (只读 replica)
- **仲裁 replica (Arbitration)** — special replica 不存 log 但参与 ack (低成本 HA)

---

## 2. ObILogHandler 接口（`ob_log_handler.h` 实读）

```cpp
// src/logservice/ob_log_handler.h
class ObILogHandler {
public:
  virtual ~ObILogHandler() {}
  virtual bool is_valid() const = 0;

  // ★ Append log (LEADER only)
  virtual int append(const void *buffer, const int64_t nbytes, const share::SCN &ref_scn,
                     const bool need_nonblock, const bool allow_compress,
                     AppendCb *cb, palf::LSN &lsn, share::SCN &scn) = 0;
  virtual int append_big_log(...) = 0;

  // ★ Role query
  virtual int get_role(common::ObRole &role, int64_t &proposal_id) const = 0;

  // ★ Access mode (APPEND / RAW_WRITE)
  virtual int change_access_mode(const int64_t mode_version, const palf::AccessMode &access_mode,
                                 const share::SCN &ref_scn) = 0;
  virtual int get_access_mode(int64_t &mode_version, palf::AccessMode &access_mode) const = 0;

  // ★ Log read (PalfBufferIterator / PalfGroupBufferIterator)
  virtual int seek(const palf::LSN &lsn, palf::PalfBufferIterator &iter) = 0;
  virtual int seek(const palf::LSN &lsn, palf::PalfGroupBufferIterator &iter) = 0;
  virtual int locate_by_scn_coarsely(const share::SCN &scn, palf::LSN &result_lsn) = 0;
  virtual int locate_by_lsn_coarsely(const palf::LSN &lsn, share::SCN &result_scn) = 0;

  // ★ LSN / SCN query
  virtual int get_begin_lsn(palf::LSN &lsn) const = 0;
  virtual int get_end_lsn(palf::LSN &lsn) const = 0;
  virtual int get_max_lsn(palf::LSN &lsn) const = 0;
  virtual int get_max_scn(share::SCN &scn) const = 0;
  virtual int get_end_scn(share::SCN &scn) const = 0;
  virtual int get_max_decided_scn(share::SCN &scn) = 0;

  // ★ Membership config change
  virtual int set_initial_member_list(const common::ObMemberList &member_list,
                                      const int64_t paxos_replica_num,
                                      const common::GlobalLearnerList &learner_list) = 0;
  virtual int add_member(const common::ObMember &member, const int64_t paxos_replica_num,
                         const palf::LogConfigVersion &config_version, const int64_t timeout_us) = 0;
  virtual int remove_member(const common::ObMember &member, const int64_t paxos_replica_num,
                            const int64_t timeout_us) = 0;
  virtual int replace_member(const common::ObMember &added_member,
                             const common::ObMember &removed_member,
                             const palf::LogConfigVersion &config_version, const int64_t timeout_us) = 0;
  virtual int add_learner(const common::ObMember &added_learner, const int64_t timeout_us) = 0;
  virtual int remove_learner(const common::ObMember &removed_learner, const int64_t timeout_us) = 0;
  virtual int replace_learners(...) = 0;
  virtual int switch_learner_to_acceptor(const common::ObMember &learner, ...) = 0;
  virtual int switch_acceptor_to_learner(const common::ObMember &member, ...) = 0;

  // ★ Sync / Replay control
  virtual int is_in_sync(bool &is_log_sync, bool &is_need_rebuild) const = 0;
  virtual int enable_sync() = 0;
  virtual int disable_sync() = 0;
  virtual bool is_sync_enabled() const = 0;
  virtual int enable_replay(const palf::LSN &initial_lsn, const share::SCN &initial_scn) = 0;
  virtual int disable_replay() = 0;

  // ★ Rebuild (migrate / disaster recovery)
  virtual int advance_base_info(const palf::PalfBaseInfo &palf_base_info, const bool is_rebuild) = 0;
  virtual int register_rebuild_cb(palf::PalfRebuildCb *rebuild_cb) = 0;

  // ★ Online / Offline
  virtual int offline() = 0;
  virtual int online(const palf::LSN &lsn, const share::SCN &scn, const bool is_logonly_replica = false) = 0;
  virtual bool is_offline() const = 0;

  // ★ Arbitration (low-cost HA)
  virtual int add_arbitration_member(const common::ObMember &added_member, const int64_t timeout_us) = 0;
  virtual int remove_arbitration_member(const common::ObMember &removed_member, const int64_t timeout_us) = 0;
  virtual int degrade_acceptor_to_learner(const palf::LogMemberAckInfoList &degrade_servers,
                                          const int64_t timeout_us) = 0;
  virtual int upgrade_learner_to_acceptor(const palf::LogMemberAckInfoList &upgrade_servers,
                                          const int64_t timeout_us) = 0;
};
```

### 2.1 关键 API 分类

| 类别 | API | 用途 |
|------|-----|------|
| **Append** | `append` / `append_big_log` | 提交 log (LEADER only) |
| **Read** | `seek` / `locate_by_scn_coarsely` / `locate_by_lsn_coarsely` | log 流式读 + 按 SCN/LSN 定位 |
| **Role** | `get_role` / `switch_role` | 查询/切换 LEADER/FOLLOWER |
| **LSN/SCN** | `get_begin_lsn` / `get_end_lsn` / `get_max_lsn` / `get_max_scn` | 边界 + 当前位置 |
| **Membership** | `add_member` / `remove_member` / `replace_member` / `add_learner` / `switch_learner_to_acceptor` | 成员变更 |
| **Sync** | `enable_sync` / `disable_sync` / `is_in_sync` | log 同步开关 + 状态查询 |
| **Replay** | `enable_replay` / `disable_replay` | log 重放开关 |
| **Rebuild** | `advance_base_info` / `register_rebuild_cb` | 重建 + 迁移 |
| **Arbitration** | `add_arbitration_member` / `degrade_acceptor_to_learner` | 仲裁 + learner 降级 |

### 2.2 ObLogHandler 私有成员

```cpp
class ObLogHandler : public ObILogHandler, public ObLogHandlerBase {
private:
  common::ObAddr self_;
  ObApplyStatus *apply_status_;
  ObLogApplyService *apply_service_;
  ObLogReplayService *replay_service_;
  ObRoleChangeService *rc_service_;

  // LOCK ORDER INVARIANT: deps_lock_ MUST be acquired BEFORE lock_ (the base
  // class RWLock). Never take lock_ first and then deps_lock_.
  // Reason: config-change RPC callback path holds deps_lock_ first
  // (handle_config_change_cmd_rpc), then re-enters and acquires lock_ deep in
  // the callback chain (PalfHandleImpl::one_stage_config_change_ ->
  // ObReconfigCheckerAdapter -> ObLogHandler::stat). If any other path (e.g.
  // stop()/destroy(), driven by LS replica GC) takes lock_ before deps_lock_,
  // the two form an AB-BA deadlock.
  common::TCRWLock deps_lock_;  // ★ Config change lock (避免 AB-BA deadlock)
  mutable palf::PalfLocationCacheCb *lc_cb_;
  mutable obrpc::ObLogServiceRpcProxy *rpc_proxy_;
  common::ObQSync ls_qsync_;
  ObMiniStat::ObStatItem append_cost_stat_;
  bool is_offline_;
  // ...
};
```

**关键 lock ordering invariant**: `deps_lock_` 必须在 `lock_` 之前获取 — config-change RPC callback 路径 (deps_lock → lock_ 链) vs stop/destroy 路径 (lock_ → deps_lock 链) 构成 AB-BA deadlock 风险,严格 LOCK ORDER INVARIANT 避免死锁。

---

## 3. LogBlockHeader 结构（`log_block_header.h` 实读）

```cpp
// src/logservice/palf/log_block_header.h
struct LogBlockHeader {
public:
  LogBlockHeader();
  ~LogBlockHeader();
  bool is_valid() const;
  void reset();
  int generate(const int64_t palf_id, const block_id_t curr_block_id,
               const LSN &min_lsn, const share::SCN &min_scn);
  void update_lsn_and_scn(const LSN &lsn, const share::SCN &scn);
  void update_palf_id_and_curr_block_id(const int64_t palf_id, const block_id_t curr_block_id);
  void mark_block_can_be_reused(const share::SCN &max_scn);
  block_id_t get_curr_block_id() const;
  const share::SCN &get_min_scn() const;
  LSN get_min_lsn() const;
  const share::SCN get_scn_used_for_iterator() const;
  void calc_checksum();
  bool check_integrity() const;
  NEED_SERIALIZE_AND_DESERIALIZE;
  TO_STRING_KV(K_(magic), K_(version), K_(min_lsn), K_(min_scn), K_(curr_block_id), K_(palf_id));

  static constexpr int16_t MAGIC = 0x4942;  // ★ 0x4942 = "IB" (InfoBlock)
  static constexpr int16_t LOG_INFO_BLOCK_VERSION = 1;
  static constexpr int32_t REUSED_BLOCK_MASK = 1 << 0;

private:
  int64_t calc_checksum_() const;
  bool is_reused_block_() const;

private:
  int16_t magic_;            // ★ Magic number 0x4942 = InfoBlock identifier
  int16_t version_;          // 版本号
  int32_t flag_;             // flags (e.g. REUSED_BLOCK_MASK)
  LSN min_lsn_;              // ★ 当前 block 的最小 LSN
  share::SCN min_scn_;       // ★ 当前 block 的最小 SCN
  share::SCN max_scn_;       // ★ 当前 block 的最大 SCN (用于 reused block)
  block_id_t curr_block_id_; // ★ Logical block ID (单调递增 per PALF instance)
  int64_t palf_id_;          // ★ PALF instance ID (多个 PALF instance 共享 directory)
  int64_t checksum_;         // ★ Per-block checksum (integrity check)
};
```

### 3.1 关键字段

| 字段 | 类型 | 用途 |
|------|------|------|
| **magic** | `int16_t` | 0x4942 = "IB" (InfoBlock identifier, 校验用) |
| **version** | `int16_t` | LOG_INFO_BLOCK_VERSION = 1 |
| **flag** | `int32_t` | REUSED_BLOCK_MASK (block 循环复用 flag) |
| **min_lsn** | `LSN` | 当前 block 的最小 LSN |
| **min_scn** | `share::SCN` | 当前 block 的最小 SCN |
| **max_scn** | `share::SCN` | 当前 block 的最大 SCN (reused block 用) |
| **curr_block_id** | `block_id_t` | Logical block ID (单调递增 per PALF instance) |
| **palf_id** | `int64_t` | PALF instance ID (多个 PALF instance 共享 directory) |
| **checksum** | `int64_t` | Per-block checksum (integrity check) |

### 3.2 Block 循环复用

```cpp
void mark_block_can_be_reused(const share::SCN &max_scn);
```

**关键设计**: 当 block 不再需要 (log 已 GC),block 可被 reuse — 写入新 log 但保留 InfoBlock header (magic/version/flag/min_lsn/min_scn/max_scn/curr_block_id/palf_id/checksum)。`REUSED_BLOCK_MASK = 1 << 0` flag 标记 reused block。`get_scn_used_for_iterator()` 返回 reused block 的 `max_scn_`,正常 block 返回 `min_scn_`。

### 3.3 Multi-PALF 共享 directory

```cpp
// 'curr_block_id_' is the logical block id, and keep it increase monotonically in each
// palf instance, even if switch block when write failed.
//
// NB: to locate logs by LSN, we need keep the pair(physical block name, InfoBlock).
block_id_t curr_block_id_;
int64_t palf_id_;
```

**关键**: 多个 PALF instance (per-tenant per-zone LS) **共享同一 directory** — 用 `palf_id_` 区分不同 instance 的 log blocks。`curr_block_id_` 是 logical block ID,monotonically increasing per PALF instance。

---

## 4. LsnTsInfo + LogMemberAckInfo（`log_ack_info.h` 实读）

```cpp
// src/logservice/palf/log_ack_info.h
struct LsnTsInfo {
  LSN lsn_;
  int64_t last_ack_time_us_;
  int64_t last_advance_time_us_;
  // ...
};

struct LogMemberAckInfo {
  LogMemberAckInfo() : member_(), last_ack_time_us_(OB_INVALID_TIMESTAMP), last_flushed_end_lsn_() {}
  LogMemberAckInfo(const common::ObMember &member, const int64_t last_ack_time_us,
                   const LSN &last_flushed_end_lsn)
    : member_(member), last_ack_time_us_(last_ack_time_us), last_flushed_end_lsn_(last_flushed_end_lsn) {}
  common::ObMember member_;
  // 降级时 double check
  int64_t last_ack_time_us_;
  // 升级时 double check
  LSN last_flushed_end_lsn_;
  // ...
};

typedef common::ObSEArray<LogMemberAckInfo, common::OB_MAX_MEMBER_NUMBER> LogMemberAckInfoList;
```

### 4.1 LsnTsInfo — Per-member LSN tracking

| 字段 | 用途 |
|------|------|
| **lsn_** | 该 member 当前已 ack 的最大 LSN |
| **last_ack_time_us_** | 最后 ack 时间戳 (用于 detect lagging member) |
| **last_advance_time_us_** | 最后 LSN advance 时间戳 (track progress) |

### 4.2 LogMemberAckInfo — Paxos ack tracking

| 字段 | 用途 |
|------|------|
| **member_** | Member info (addr + timestamp) |
| **last_ack_time_us_** | 最后 ack 时间 (degrade 时 double check) |
| **last_flushed_end_lsn_** | 最后 flushed end LSN (upgrade 时 double check) |

### 4.3 双 check 机制

- **Degrade** (acceptor → learner): check `last_ack_time_us_` — 若 member 近期 ack 过 (not lagging),不能降级
- **Upgrade** (learner → acceptor): check `last_flushed_end_lsn_` — 若 LSN 太低 (catchup 未完成),不能升级

---

## 5. Multi-Paxos 协议（OB 5.0.2.0 PALF 实现）

PALF 是 **Multi-Paxos** 实现 — leader-based 共识:

```
Client Append(LogEntry):
  1. Client → Leader: append(entry)
  2. Leader: assign proposal_id (monotonic), prepare
  3. Leader → Followers: prepare_request (proposal_id)
  4. Followers: check proposal_id > last_seen_proposal_id
     - if yes: promise + return last_accepted_proposal_id + last_accepted_value
     - if no: reject
  5. Leader: collect promises (majority)
     - if majority promise: assign proposal_id, accept
     - else: retry with higher proposal_id (election)
  6. Leader → Followers: accept_request (proposal_id, entry)
  7. Followers: accept, persist to log, return ack
  8. Leader: collect acks (majority)
     - if majority ack: committed → broadcast commit
     - else: retry
  9. Leader: return LSN + SCN to Client
```

### 5.1 关键优化

- **Skip prepare when leader stable** — Multi-Paxos 假设 leader 稳定时跳过 prepare phase,直接 accept
- **Batching** — 多个 entry 一起 propose (per LogGroupEntry)
- **Group commit** — 多个 client append 合并一次 fsync

### 5.2 Paxos 角色

- **LEADER**: 接受 append 请求,replicate 到 followers,返回 ack
- **FOLLOWER**: 接受 leader 的 replicate 请求,持久化,返回 ack
- **LEARNER**: 只读 replica,不参与 ack (lower cost)

---

## 6. Election 机制（`src/logservice/palf/election/`）

### 6.1 拓扑

```
src/logservice/palf/election/
├── algorithm/                # Paxos algorithm 实现
├── interface/                # Election interface (abstract)
├── message/                  # Election message (PrepareRequest/PrepareResponse/AcceptRequest/AcceptResponse)
└── utils/                    # Election utils
```

### 6.2 关键设计

- **Ballot-based election** — `proposal_id` (uint64_t) monotonically increasing per epoch
- **prepare phase** — candidate 用 higher proposal_id 请求 vote
- **promise response** — acceptor 返回 last_accepted_proposal_id + value (用于 leader catchup)
- **majority quorum** — N/2 + 1 个 ack 才能 elected

### 6.3 Leader 切换流程

```
1. FOLLOWER detect leader failure (timeout)
2. FOLLOWER → self: become CANDIDATE
3. CANDIDATE → all: PrepareRequest(proposal_id = last + 1)
4. PEERS → CANDIDATE: PrepareResponse(last_accepted_proposal_id, last_accepted_value)
5. CANDIDATE: collect majority promise → become LEADER
6. CANDIDATE → all: AcceptRequest(proposal_id, entry)
7. PEERS → LEADER: AcceptResponse(ack)
8. LEADER: collect majority ack → committed
```

---

## 7. Replica 同步（Leader/Follower/Learner）

### 7.1 Append 流程

```
Client → Leader (ObLogHandler::append):
  1. Leader: assign proposal_id (monotonic)
  2. Leader: 写入本地 log block (write to disk)
  3. Leader → Followers: replicate (RPC batch)
  4. Followers: write to log block + return ack
  5. Leader: collect majority ack
  6. Leader: commit + apply (推 apply service)
  7. Leader: return LSN + SCN to Client
```

### 7.2 关键路径

- **Append path**: Client → ObLogHandler → PalfHandleImpl → LogEngine → LogBlockHandler → disk
- **Replicate path**: Leader → ObLogServiceRpcProxy → Follower ObLogHandler → PalfHandleImpl → LogEngine
- **Apply path**: LogEngine → ObLogApplyService → CLog/Tx/MVCC

### 7.3 同步模式

- **SYNC mode**: majority ack 才返回 (强一致)
- **ASYNC mode**: local write 后立即返回 (高吞吐,弱一致)

---

## 8. Membership Changes（成员变更）

### 8.1 接口分类

| 类别 | API | 用途 |
|------|-----|------|
| **Init** | `set_initial_member_list` | 初始化成员 (LS 创建) |
| **Add/Remove** | `add_member` / `remove_member` | acceptor 增减 |
| **Replace** | `replace_member` / `replace_member_with_learner` | acceptor 替换 |
| **Learner** | `add_learner` / `remove_learner` / `replace_learners` | 只读 replica 增减 |
| **Switch** | `switch_learner_to_acceptor` / `switch_acceptor_to_learner` | learner ↔ acceptor 切换 |
| **Arbitration** | `add_arbitration_member` / `remove_arbitration_member` | 仲裁 replica |
| **Degrade/Upgrade** | `degrade_acceptor_to_learner` / `upgrade_learner_to_acceptor` | 动态降级/升级 |
| **Replica num** | `change_replica_num` | 副本数变更 |
| **Force** | `force_set_as_single_replica` / `force_set_member_list` | 强制变更 (recovery) |

### 8.2 成员变更协议

```
Leader: prepare new member_list (config_change)
Leader → Followers: prepare_meta_req(new_member_list, proposal_id)
Followers: check + promise
Leader: collect majority promise
Leader: 写入 meta (config_version++)
Leader → Followers: change_config_meta_req(new_member_list)
Followers: commit new member_list
Leader: collect majority ack
Leader: config_change 完成,后续 propose 用新 member_list
```

### 8.3 Learner 机制

- **Learner** = 只读 replica,不参与 ack
- **用途**: 异地灾备 (远距离异步复制)
- **同步**: learner 异步 catch up (per `fetch_log_engine`)

---

## 9. Log Block 存储

### 9.1 Block 结构

```
┌─────────────────────────────────┐
│ LogBlockHeader (variable size)  │  ← magic/version/flag/min_lsn/min_scn/max_scn/curr_block_id/palf_id/checksum
├─────────────────────────────────┤
│ LogGroupEntry 1                 │
│  - LogGroupEntryHeader          │  ← proposal_id/log_type/scn/...
│  - LogEntry 1 (data)            │
│  - LogEntry 2 (data)            │
│  - ...                          │
├─────────────────────────────────┤
│ LogGroupEntry 2                 │
├─────────────────────────────────┤
│ ...                             │
└─────────────────────────────────┘
```

### 9.2 Block 写入

```
LogBlockHandler::append_entry(LogGroupEntry):
  1. 检查当前 block 剩余空间 (block_size - used_size)
  2. if 剩余 < entry_size:
     - flush 当前 block → disk
     - allocate 新 block
     - write new LogBlockHeader
  3. write LogGroupEntry 到当前 block
  4. update LogBlockHeader.min_lsn / min_scn
```

### 9.3 Block 读取

```
LogBlockHandler::read_block(block_id, &buf, &len):
  1. 从 disk 读 raw block
  2. parse LogBlockHeader → check magic (0x4942) + checksum
  3. return LogGroupEntry list

LogBlockHandler::iterate(block_id, iter):
  1. read block → header + entries
  2. for each LogGroupEntry: yield (log_type, scn, data)
```

### 9.4 Block GC

```
block_gc_timer_task (periodic):
  1. 计算当前 base_lsn (advance_base_lsn 调用方决定)
  2. for block_id < base_block_id:
     - delete block file (disk)
     - reclaim block pool
  3. update LogBlockHeader.min_lsn / min_scn (推进)
```

---

## 10. Fetch Log（catchup via `fetch_log_engine.{h,cpp}`）

### 10.1 用途

- **Catchup**: 新加入的 follower/learner 落后 leader,fetch 缺失的 log blocks
- **Rebuild**: disaster recovery 时从其他 replica 拉取 log

### 10.2 流程

```
Follower (落后) → Leader: fetch_log_request(start_lsn, end_lsn)
Leader:
  1. 检查权限 (该 follower 是 member / learner)
  2. 从 LogBlockHandler 读取 log blocks (start_lsn → end_lsn)
  3. 压缩 + batch → RPC response
Follower:
  1. 接收 log blocks
  2. 写入本地 LogBlockHandler
  3. 推进 apply point
```

---

## 11. Log Cache + Checksum

### 11.1 Log Cache (`log_cache.{h,cpp}`)

**用途**: hot log blocks in memory (避免频繁 disk read)

**设计**:
- Per-PALF instance LRU cache
- Key: block_id + palf_id
- Value: block buffer (compressed or raw)
- 集成 #107 v2 KV Cache framework (可能)

### 11.2 Log Checksum (`log_checksum.{h,cpp}`)

**用途**: Per-block integrity check

**设计**:
- LogBlockHeader.checksum_ 字段
- `calc_checksum_()` — CRC64 over block content
- `check_integrity()` — read 时 verify checksum → detect corruption

---

## 12. 集成（OB 全栈性能）

### 12.1 与 CLog 集成（per #108 v2）

PALF 是 CLog 的**底层 consensus 实现**:

```
CLog (Redo Log / WAL) (per #108 v2)
  ↓ uses
PALF (Paxos + Log) (#114 v2)
  ↓ uses
LogBlockHandler (disk storage)
```

**对应关系**:
- CLog = redo log 内容 (per-transaction log records)
- PALF = 共识层 (保证 CLog 在多数 replica 一致)
- LogBlockHandler = 物理存储 (CLog 写入的物理介质)

### 12.2 与 Transaction 集成（per #110 v2）

```
Transaction commit (per #110 v2):
  1. Tx coordinator: prepare 2PC (per-partition participants)
  2. Participants: append redo log to local CLog → PALF replicate (majority ack)
  3. Tx coordinator: commit decision → participants apply
  4. Participants: append commit log to CLog → PALF replicate
```

**PALF 在 Tx 中的角色**: 提供 **强一致的 redo log 复制**,保证 commit decision 在多数 replica 持久化。

### 12.3 与 Election 集成（per #26 v1 / pending）

PALF election 是 **leader-based**:
- 每个 LS 有独立 election
- Leader 故障 → FOLLOWER detect → 触发 election
- Election 通过 PALF prepare/accept protocol 完成

---

## 13. 性能特征

| 维度 | 数值 | 备注 |
|------|------|------|
| **Append latency** | ~1-10ms (majority ack, 同 IDC) | per log entry |
| **Append throughput** | ~10-100k entries/sec/LS | per LS (leader 单点) |
| **Replication latency** | ~100μs-1ms (IDC) / ~10-50ms (跨 region) | leader → follower |
| **Election time** | ~1-10s | leader 故障检测 + 投票 |
| **Block GC time** | periodic (background) | 不阻塞 append |

**关键 insight**:
- **Strong consistency** — majority ack 保证 (N/2 + 1 个 replica 确认才返回)
- **High availability** — minority replica 故障不阻塞 (N=5 可容忍 2 故障)
- **Disaster recovery** — arbitration replica + learner 异地灾备

---

## 14. 总结

OB PALF + LogService (5.0.2.0) 是 **Multi-Paxos + Log Block + per-member Ack + Election + Membership changes** 的精妙设计：

- **PALF 拓扑** — `src/logservice/` 803 文件 + `palf/` 核心 + `election/` 子模块
- **ObILogHandler 接口** — append / seek / get_role / change_replica_num / add_member / ... (~30+ virtual methods)
- **LogBlockHeader** — magic=0x4942 (InfoBlock) + version + flag + min_lsn/min_scn/max_scn + curr_block_id + palf_id + checksum
- **LsnTsInfo + LogMemberAckInfo** — per-member Paxos ack tracking + 双 check (degrade/upgrade)
- **Multi-Paxos** — leader-based consensus + skip-prepare 优化 + batching + group commit
- **Election** — ballot-based + prepare/promise + majority quorum
- **Replica 同步** — LEADER/FOLLOWER/LEARNER 三 role + SYNC/ASYNC 模式
- **Membership Changes** — add/remove/replace member + learner + arbitration + degrade/upgrade
- **Log Block 存储** — write/read/GC + block 循环复用 (REUSED_BLOCK_MASK)
- **Fetch Log** — `fetch_log_engine` 提供 catchup + rebuild
- **Log Cache + Checksum** — hot blocks in memory + per-block CRC64

**架构 insight**:
- **PALF = OB 自研 Paxos** — 比传统 Multi-Paxos 更精简,针对 log service 优化
- **per-tenant per-zone LS** — 强隔离 + 高可用
- **3 role 灵活扩展** — LEADER/FOLLOWER/LEARNER 适应不同场景 (主备/异地灾备)
- **Lock ordering invariant** — `deps_lock_` 必须在 `lock_` 之前,避免 config-change RPC + stop/destroy AB-BA deadlock
- **Magic + Checksum 双保险** — magic 0x4942 校验 block 类型 + CRC64 校验内容完整性

**集成路径 (OB 全栈)**:
- Client → Tx (#110 v2) → CLog (#108 v2) → **PALF (#114 v2)** → LogBlockHandler → disk
- Follower sync → **PALF replicate** → majority ack → commit
- Election: FOLLOWER detect failure → CANDIDATE → **PALF prepare** → LEADER
- Membership: Tx trigger add member → **PALF config_change** → new member_list

---

> 📚 **相关 v2 deep-dive**:
> - **#14 v2 MemTable** — MemTable BTree (5.0.2.0 OB ONLY)
> - **#104 v2 MemStore Allocator** — AChunkMgr + ObTenantCtxAllocator (4D 矩阵)
> - **#105 v2 SSTable Encoding** — encoding/ + index_block/ + micro_block_hash_index + SIMD
> - **#106 v2 SSTable Compaction** — ObCompactionDagRanker + ObTabletMergeCtx + progressive merge
> - **#107 v2 KV Cache** — ObKVCache + Hazard Pointer + Pointer Swizzling + Pre-warming
> - **#108 v2 CLog** — WAL + group commit + **PALF (per #114)**
> - **#109 v2 Network** — ob_listener + ob_net_client + batched I/O
> - **#110 v2 Tx** — 2PC + Lock + GTS + **PALF CLog (per #114)**
> - **#111 v2 Schema/DDL** — schema_version + INSTANT/INPLACE + Online DDL
> - **#112 v2 Plan Cache + Adaptive + Runtime Filter** — ObPlanCache + Adaptive Auto DOP + Adaptive Bypass + Runtime Filter P2P
> - **#113 v2 Bloom Filter** — ObBloomFilter + ObBloomFilterCache (KV cache instance) + ObPxBloomFilter SIMD

> 📂 **OB 5.0.2.0 实读路径**:
> - `src/logservice/ob_log_handler.{h,cpp}` — ObLogHandler (ObILogHandler 实现)
> - `src/logservice/ob_log_handler_base.{h,cpp}` — 基类 (lock + role + proposal_id)
> - `src/logservice/palf/log_block_header.h` — LogBlockHeader struct
> - `src/logservice/palf/log_ack_info.h` — LsnTsInfo + LogMemberAckInfo
> - `src/logservice/palf/log_engine.{h,cpp}` — LogEngine (主 engine)
> - `src/logservice/palf/log_block_handler.{h,cpp}` — Block read/write
> - `src/logservice/palf/election/` — Election (algorithm/interface/message/utils)
> - `src/logservice/palf/fetch_log_engine.{h,cpp}` — Catchup engine
> - `src/logservice/palf/log_cache.{h,cpp}` — Log cache (hot blocks)
> - `src/logservice/palf/log_checksum.{h,cpp}` — Per-block checksum