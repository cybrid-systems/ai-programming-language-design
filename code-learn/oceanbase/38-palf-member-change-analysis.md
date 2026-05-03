# 38 — PALF 成员变更 — 日志流配置变更与 Learner 同步

> 基于 OceanBase CE 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前两篇文章分别分析了 PALF 的基础架构（文章 11）和选举模块（文章 12）。现在我们来分析 PALF 中最复杂的主题——**成员变更**（Member Change）。

在分布式共识系统中，成员变更是指 Paxos 日志复制组的成员列表发生变化——添加或移除副本、修改副本数、Learner 的升降级。成员变更的难点在于：

1. **安全性**：变更期间不能出现两个同时认为自己是 Leader 的副本（脑裂）
2. **正确性**：多数派在新旧配置之间必须保持重叠
3. **可用性**：变更期间系统应能继续提供服务

OceanBase 的成员变更由 `LogConfigMgr` 管理，位于 `src/logservice/palf/log_config_mgr.h`。它支持丰富的变更类型，使用一种简化的状态机机制（INIT → CHANGING → INIT），通过 Paxos 日志提交新配置。

### 成员变更在 PALF 中的位置

```
PalfHandleImpl (Paxos 状态机)
    │
    ├── LogSlidingWindow     ← 日志滑动窗口（多数派跟踪）
    ├── LogConfigMgr          ← 成员列表管理（本文）
    │   ├── LogConfigChangeType  ← 变更类型枚举
    │   ├── LogConfigChangeArgs ← 变更参数
    │   ├── LogConfigMgr::change_config_  ← 变更状态机
    │   ├── 子/父关系管理      ← Learner 注册与保活
    │   └── LogReconfigBarrier ← 配置变更屏障
    ├── LogStateMgr           ← 角色状态机
    ├── LogReconfirm          ← Leader 上任确认
    ├── FetchLogEngine        ← 日志拉取引擎（Learner 追赶）
    ├── LogEngine             ← 日志存储引擎
    └── Election              ← 选主模块
```

### 核心文件一览（doom-lsp 确认）

| 文件 | 行数 | 职责 |
|------|------|------|
| `log_config_mgr.h` | ~820 | LogConfigMgr 类、变更类型枚举、参数结构体 |
| `log_config_mgr.cpp` | ~3444 | 成员变更核心实现，约 2500 行逻辑 |
| `log_learner.h` | ~63 | LogLearner 数据结构 |
| `fetch_log_engine.h` | ~120 | FetchLogEngine 任务队列 |
| `fetch_log_engine.cpp` | ~365 | 日志拉取任务管理 |
| `log_simple_member_list.h` | ~70 | 轻量成员列表和 ACK 列表 |
| `palf_handle_impl.cpp` | ~4870 | 顶层协调，消息分发 |

---

## 1. 成员变更类型体系

### 1.1 LogConfigChangeType 枚举

变更类型定义在 `log_config_mgr.h` @ L53-75，共 20 种变更类型：

```cpp
enum LogConfigChangeType {
  INVALID_LOG_CONFIG_CHANGE_TYPE = 0,
  CHANGE_REPLICA_NUM,                    // 修改副本数
  ADD_MEMBER,                            // 添加 Paxos 成员
  ADD_ARB_MEMBER,                        // 添加仲裁成员
  REMOVE_MEMBER,                         // 移除 Paxos 成员
  REMOVE_ARB_MEMBER,                     // 移除仲裁成员
  ADD_MEMBER_AND_NUM,                    // 添加成员 + 修改副本数
  REMOVE_MEMBER_AND_NUM,                 // 移除成员 + 修改副本数
  ADD_LEARNER,                           // 添加 Learner
  REMOVE_LEARNER,                        // 移除 Learner
  SWITCH_LEARNER_TO_ACCEPTOR,            // Learner → Acceptor
  SWITCH_ACCEPTOR_TO_LEARNER,            // Acceptor → Learner
  DEGRADE_ACCEPTOR_TO_LEARNER,           // Acceptor 降级为 Learner（保留日志）
  UPGRADE_LEARNER_TO_ACCEPTOR,           // Learner 升级为 Acceptor（从降级恢复）
  STARTWORKING,                          // 新 Leader 开始工作
  FORCE_SINGLE_MEMBER,                   // 强制单副本
  TRY_LOCK_CONFIG_CHANGE,                // 尝试锁定配置变更
  UNLOCK_CONFIG_CHANGE,                  // 解锁配置变更
  REPLACE_LEARNERS,                      // 批量替换 Learner
  SWITCH_LEARNER_TO_ACCEPTOR_AND_NUM,    // Learner → Acceptor + 修改副本数
  FORCE_SET_MEMBER_LIST,                 // 强制设置成员列表
};
```

### 1.2 类型分类辅助函数

`log_config_mgr.h` @ L121-214 定义了一系列 inline 辅助函数，用于判断变更类型的语义分类：

| 辅助函数 | 语义 | 包含的变更类型 |
|---------|------|-------------|
| `is_add_log_sync_member_list()` | 增加日志同步成员 | ADD_MEMBER, ADD_MEMBER_AND_NUM, SWITCH_LEARNER_TO_ACCEPTOR, UPGRADE_LEARNER_TO_ACCEPTOR, SWITCH_LEARNER_TO_ACCEPTOR_AND_NUM |
| `is_remove_log_sync_member_list()` | 移除日志同步成员 | REMOVE_MEMBER, REMOVE_MEMBER_AND_NUM, SWITCH_ACCEPTOR_TO_LEARNER, DEGRADE_ACCEPTOR_TO_LEARNER |
| `is_add_member_list()` | 增加成员（含仲裁） | is_add_log_sync_member_list 的集合 + ADD_ARB_MEMBER |
| `is_remove_member_list()` | 移除成员（含仲裁） | is_remove_log_sync_member_list 的集合 + REMOVE_ARB_MEMBER |
| `is_arb_member_change_type()` | 仲裁成员变更 | ADD_ARB_MEMBER, REMOVE_ARB_MEMBER |
| `is_add_learner_list()` | 增加 Learner | ADD_LEARNER, SWITCH_ACCEPTOR_TO_LEARNER, DEGRADE_ACCEPTOR_TO_LEARNER, REPLACE_LEARNERS |
| `is_remove_learner_list()` | 移除 Learner | REMOVE_LEARNER, SWITCH_LEARNER_TO_ACCEPTOR, UPGRADE_LEARNER_TO_ACCEPTOR, SWITCH_LEARNER_TO_ACCEPTOR_AND_NUM, REPLACE_LEARNERS |
| `is_upgrade_or_degrade()` | 升降级操作 | UPGRADE_LEARNER_TO_ACCEPTOR, DEGRADE_ACCEPTOR_TO_LEARNER |
| `is_paxos_member_list_change()` | 是否修改 Paxos 成员列表 | ADD/REMOVE_MEMBER, ADD/REMOVE_MEMBER_AND_NUM, SWITCH_LEARNER_TO_ACCEPTOR, SWITCH_ACCEPTOR_TO_LEARNER, CHANGE_REPLICA_NUM, SWITCH_LEARNER_TO_ACCEPTOR_AND_NUM |
| `is_may_change_replica_num()` | 可能改变副本数 | is_add/remove_member_list + CHANGE_REPLICA_NUM + FORCE_SINGLE_MEMBER + FORCE_SET_MEMBER_LIST |
| `is_must_not_change_replica_num()` | 不改变副本数 | ADD/REMOVE_LEARNER, REPLACE_LEARNERS, TRY/UNLOCK_CONFIG_CHANGE |
| `need_exec_on_leader_()` | 是否必须在 Leader 执行 | 除 FORCE_SINGLE_MEMBER 和 FORCE_SET_MEMBER_LIST 外的所有类型 |

> **设计意图**：这个分类体系确保每个变更类型都能被正确路由到对应的处理逻辑。`is_use_replica_num_args()`（@L167）控制哪些类型使用 `new_replica_num_` 参数，`is_use_added_list()` / `is_use_removed_list()`（@L209-214）仅在 `REPLACE_LEARNERS` 类型为 true。

### 1.3 LogConfigChangeArgs — 变更参数

`LogConfigChangeArgs`（`log_config_mgr.h` @ L219-305）封装了成员变更所需的所有参数：

```cpp
struct LogConfigChangeArgs {
  common::ObMember server_;              // 目标节点
  common::ObMemberList curr_member_list_;// 当前成员列表
  int64_t curr_replica_num_;             // 当前副本数
  int64_t new_replica_num_;              // 新副本数
  LogConfigVersion config_version_;      // 配置版本
  share::SCN ref_scn_;                   // 参考 SCN
  int64_t lock_owner_;                   // 锁持有者
  int64_t lock_type_;                    // 锁类型
  LogConfigChangeType type_;             // 变更类型
  common::ObMemberList added_list_;      // 新增成员列表（REPLACE_LEARNERS）
  common::ObMemberList removed_list_;    // 移除成员列表（REPLACE_LEARNERS）
  common::ObMemberList new_member_list_; // 新成员列表（FORCE_SET_MEMBER_LIST）
};
```

该结构体提供多个构造函数（@L236-276），分别适配不同的变更场景：
- 单节点变更：`ADD_MEMBER` / `REMOVE_MEMBER` 等使用 `(server, replica_num, config_version, type)`
- 批量副本变更：`CHANGE_REPLICA_NUM` 使用 `(member_list, curr_replica_num, new_replica_num, type)`
- 锁操作：`TRY_LOCK_CONFIG_CHANGE` 使用 `(lock_owner, lock_type, type)`
- 批量 Learner 替换：`REPLACE_LEARNERS` 使用 `(added_list, removed_list, type)`
- 强制设置：`FORCE_SET_MEMBER_LIST` 使用 `(new_member_list, new_replica_num, type)`

---

## 2. LogConfigMgr — 配置管理器

### 2.1 核心状态机

`LogConfigMgr`（`log_config_mgr.h` @ L342）的成员变更是一个简单的两状态状态机：

```
        ┌──────────────────────────────────┐
        │          INIT (state_ = 0)        │
        │  ┌─────────────────────────┐      │
        │  │ append_config_meta_()   │      │
        │  │  → 校验参数             │      │
        │  │  → 生成新配置           │      │
        │  │  → 更新 Election 元数据 │      │
        │  │  → 更新 Barrier        │      │
        │  │  → 写本地配置          │      │
        │  └──────────┬──────────────┘      │
        │             │ 成功                │
        │             ▼                     │
        │          CHANGING (state_ = 1)     │
        │  ┌─────────────────────────┐      │
        │  │ 提交配置日志到 Paxos    │      │
        │  │ 等待多数派确认 (ACK)    │      │
        │  │ 超时重发                │      │
        │  └──────────┬──────────────┘      │
        │             │ 多数派达成           │
        │             ▼                     │
        │          INIT (回到初始状态)       │
        └──────────────────────────────────┘
```

状态机实现在 `change_config_()` 方法（`log_config_mgr.cpp` @ L843-996）：

```cpp
int LogConfigMgr::change_config_(const LogConfigChangeArgs &args,
                                 const int64_t proposal_id,
                                 const int64_t election_epoch,
                                 LogConfigVersion &config_version)
{
  // 前置检查
  if (need_exec_on_leader_(args.type_)
      && false == is_leader_for_config_change_(...)) {
    ret = OB_NOT_MASTER;
  } else if (false == mode_mgr_->can_do_paxos_accept()) {
    ret = OB_ERR_UNEXPECTED;
  } else if (OB_FAIL(check_config_version_matches_state_(...))) {
    // ...
  } else {
    const int64_t curr_proposal_id = state_mgr_->get_proposal_id();
    switch(state_) {
      case INIT:
        // 1. 生成新配置 (append_config_meta_)
        // 2. 重置 ACK 列表
        // 3. 设置重发信息
        // 4. 状态 → CHANGING
        // 5. 返回 OB_EAGAIN 触发外部重试循环
        break;
      case CHANGING:
        if (is_reach_majority_()) {
          // 多数派达成 → 执行最终化 → 状态 → INIT
          (void) after_config_log_majority_(...);
          state_ = INIT;
          ret = OB_SUCCESS;
        } else if (need_resend_config_log_()) {
          // 超时重发配置日志
          ret = OB_EAGAIN; // 继续等待
        }
        break;
    }
  }
  return ret;
}
```

### 2.2 Leader 校验

`is_leader_for_config_change_()`（`log_config_mgr.cpp` @ L924-997）做三重检查：

1. **PALF 角色检查**：根据变更类型判断 Leader 是否处于激活（active）或确认（reconfirm）状态
   - `DEGRADE_ACCEPTOR_TO_LEARNER`：允许在 reconfirm 状态执行
   - `STARTWORKING`：仅在 reconfirm 状态执行
   - 其他所有类型：必须 leader_active
2. **Proposal ID 检查**：确保 `proposal_id` 未被切换
3. **Election 检查**：确保 `election_epoch` 未被切换，且 election 角色为 LEADER

### 2.3 参数校验

`check_config_change_args_by_type_()`（`log_config_mgr.cpp` @ L1108-1458）对每种变更类型进行精细校验，包括：

- **幂等性检查**：如果变更已经完成（如成员已经存在于成员列表），返回 `is_already_finished = true`
- **非法状态检查**：
  - `ADD_MEMBER`：如果目标已经是 Learner 或仲裁成员，拒绝
  - `REMOVE_MEMBER`：如果目标不在成员列表中但已是降级 Learner，允许
  - `UPGRADE_LEARNER_TO_ACCEPTOR`：只能升级 `degraded_learner`（降级 Learner），不能升级普通 Learner
- **副本数一致性检查**：`SWITCH_LEARNER_TO_ACCEPTOR_AND_NUM` 检查 new_replica_num 一致性

> **幂等重入设计**（@L1140）：对于 `ADD_MEMBER`，如果目标已经在 `log_sync_memberlist` 且 `new_replica_num == curr_replica_num`，则认为变更已完成。这保证了 RootServer 或 DDL 重试时的安全性。

### 2.4 新配置生成

`generate_new_config_info_()`（`log_config_mgr.cpp` @ L1688-1860）从当前配置 `log_ms_meta_.curr_` 克隆并修改：

```cpp
int LogConfigMgr::generate_new_config_info_(...)
{
  new_config_info = log_ms_meta_.curr_;
  new_config_info.config_.config_version_.inc_update_version(proposal_id);
  // ... 根据变更类型修改成员列表和副本数 ...
}
```

关键操作：
- 递增 `config_version_`，使用 `proposal_id` 保证全局唯一性
- 根据 `is_may_change_replica_num()` 调整 `log_sync_replica_num_`
- 处理降级 Learner 的特殊副本数计算（`is_remove_degraded_learner`）

### 2.5 ACK 与多数派判定

`LogSimpleMemberList`（`log_simple_member_list.h:15`）和 `ms_ack_list_` 跟踪哪些节点确认了配置日志：

```cpp
// log_config_mgr.cpp @ L1023
bool LogConfigMgr::is_reach_majority_() const
{
  int64_t curr_replica_num = alive_paxos_replica_num_;
  return (ms_ack_list_.get_count() > (curr_replica_num / 2));
}
```

在 `CHANGING` 状态下，Leader 等待 `alive_paxos_replica_num_ / 2 + 1` 个 ACK 后，调用 `after_config_log_majority_()` 完成配置提交。

### 2.6 配置日志重发

```cpp
// log_config_mgr.cpp @ L1039
bool LogConfigMgr::need_resend_config_log_() const
{
  const int64_t RESEND_INTERVAL_US =
      (state_mgr_->is_changing_config_with_arb()) ?
        PALF_RESEND_CONFIG_LOG_FOR_ARB_INTERVAL_US :
        PALF_RESEND_CONFIG_LOG_INTERVAL_US;
  // ...
}
```

Leader 在 `CHANGING` 状态中定期重发配置日志，直到多数派确认。重发间隔根据是否包含仲裁成员动态调整。

`set_resend_log_info_()`（@L1665）构建重发列表 `resend_log_list_`，包含所有需要收到配置日志的节点（包括 Paxos 成员和 Learner），确保配置日志最终传播到所有副本。

---

## 3. LogLearner — Learner 角色

### 3.1 数据结构

`LogLearner`（`log_learner.h` @ L30-56）是一个轻量级的数据结构：

```cpp
class LogLearner {
  OB_UNIS_VERSION(1);
public:
  // ...
  common::ObAddr server_;            // Learner 的网络地址
  common::ObRegion region_;          // Region 信息
  int64_t register_time_us_;         // 注册时间戳
  int64_t keepalive_ts_;             // 最近一次保活时间戳
};
```

辅助类型：
- `LogLearnerList`（@L62）：Learner 列表，固定最大数量 `OB_MAX_CHILD_MEMBER_NUMBER`
- `LogCandidateList`（@L63）：候选列表，用于注册时返回给 Learner 的候选 Parent 列表

### 3.2 Learner 的生命周期

```
    ┌─────────────────────────────────────────────────────────┐
    │                  Learner 生命周期                         │
    │                                                         │
    │  1. 注册 (Register)                                       │
    │     Learner → Parent: "请做我的父节点"                      │
    │     Parent → Learner: 注册成功 或 返回候选列表              │
    │                                                         │
    │  2. 保活 (Keepalive)                                      │
    │     Learner → Parent: "我还在线，进度是 X"                 │
    │     Parent → Learner: "知道了，继续同步"                   │
    │                                                         │
    │  3. 日志同步                                              │
    │     Learner 通过 FetchLogEngine 拉取日志                   │
    │                                                         │
    │  4. 下线 (Retire)                                         │
    │     Parent → Learner: "你被移除了"                         │
    │     或 Learner 超时 → Parent 主动移除                      │
    └─────────────────────────────────────────────────────────┘
```

### 3.3 Parent-Child 关系模型

OceanBase 的 Learner 同步使用一种**树形结构**，而不是普通的星型拓扑：

- **Parent**：Leader 或已经同步完成的其他 Learner
- **Child**：正在追赶日志的新 Learner

这种设计的好处：
1. **减轻 Leader 负担**：Leader 不需要直接给所有 Learner 推送日志
2. **分摊带宽**：已经同步的 Learner 可以充当其他 Learner 的数据源
3. **跨区域优化**：同区域的 Learner 可以在本地同步，减少跨区域流量

`LogConfigMgr` 维护两套 Parent-Child 关系：
- **Child 端**：`parent_`（@L790）、`register_time_us_`（@L788）、`parent_keepalive_time_us_`（@L792）
- **Parent 端**：`children_`（@L800）、`log_sync_children_`（@L803）

### 3.4 RegisterParentReason 与 Retire 原因枚举

`RegisterParentReason`（@L624-630）定义 Learner 注册 Parent 的原因：
- `FIRST_REGISTER`：首次注册
- `PARENT_NOT_ALIVE`：原 Parent 失活
- `SELF_REGION_CHANGED`：自身 Region 变更
- `RETIRED_BY_PARENT`：被 Parent 下线

`RetireParentReason`（@L648-653）定义 Learner 主动退役 Parent 的原因：
- `IS_FULL_MEMBER`：已变成完整成员（升级为 Acceptor）
- `SELF_REGION_CHANGED`：自身 Region 变更
- `PARENT_CHILD_LOOP`：形成循环

`RetireChildReason`（@L670-678）定义 Parent 移除 Child 的原因：
- `CHILDREN_LIST_FULL`：子节点列表已满
- `CHILD_NOT_IN_LEARNER_LIST`：子节点不在 Learner 列表中
- `CHILD_NOT_ALIVE`：子节点超时
- `DIFFERENT_REGION_WITH_PARENT`：子节点与 Parent 不同 Region
- `DUPLICATE_REGION_IN_LEADER`：同 Region 重复的 Learner
- `PARENT_DISABLE_SYNC`：Parent 禁用同步

### 3.5 Learner 健康检查

Parent 端通过 `check_children_health()` 定期检查所有 Child 的健康状态。Child 端通过 `check_parent_health()` 监控 Parent 的活跃性。如果 Parent 超时未响应，Child 会尝试重新注册。

`handle_learner_keepalive_req()` 处理来自 Child 的保活请求，`check_children_health()` 移除超时、不同 Region、重复 Region 的子节点。

`generate_candidate_list_()`（@L714-716）在注册时生成候选 Parent 列表，优先级为：同 Region 的 Paxos 成员 → 同 Region 的其他 Learner。

---

## 4. FetchLogEngine — 日志拉取引擎

### 4.1 FetchLogTask

`FetchLogTask`（`fetch_log_engine.h` @ L24-80）封装一次日志拉取请求：

```cpp
class FetchLogTask {
  int64_t timestamp_us_;      // 时间戳
  int64_t id_;                // 日志流 ID
  common::ObAddr server_;     // 目标节点
  FetchLogType fetch_type_;   // 拉取类型（Follower / Learner 等）
  int64_t proposal_id_;       // Proposal ID
  LSN prev_lsn_;              // 前一个 LSN
  LSN start_lsn_;             // 起始 LSN
  int64_t log_size_;          // 期望拉取大小
  int64_t log_count_;         // 期望拉取条数
  int64_t accepted_mode_pid_; // 已接受 Mode Proposal ID
};
```

### 4.2 FetchLogEngine

`FetchLogEngine`（`fetch_log_engine.h` @ L82-118）是一个线程池任务处理器：

```cpp
class FetchLogEngine : public lib::TGTaskHandler {
  // 常量
  static const int64_t FETCH_LOG_THREAD_COUNT = 1;
  static const int64_t MINI_MODE_FETCH_LOG_THREAD_COUNT = 1;
  static const int64_t FETCH_LOG_TASK_MAX_COUNT_PER_LS = 64;

  int submit_fetch_log_task(FetchLogTask *fetch_log_task);
  void handle(void *task);  // 处理拉取任务
  FetchLogTask *alloc_fetch_log_task();
  void free_fetch_log_task(FetchLogTask *task);

  // 任务缓存（避免重复提交）
  ObSEArray<FetchLogTask, 8> fetch_task_cache_;
};
```

核心流程：
1. `submit_fetch_log_task()` 提交拉取任务到线程池
2. `handle()` 方法处理任务：向目标节点请求缺失的日志
3. 使用 `fetch_task_cache_` 缓存任务，避免对同一节点重复提交相同的拉取请求（`try_remove_task_from_cache_()` 去重）
4. 每个日志流最多缓存 64 个拉取任务

### 4.3 Learner 日志追赶流程

当新 Learner 加入时，完整的日志追赶流程：

```
Leader                          Learner                      FetchLogEngine
  │                                │                              │
  │  ── ADD_LEARNER ──────────→   │                              │
  │                                │                              │
  │  ←── register_parent ───────  │                              │
  │                                │                              │
  │  ── register_parent_resp ──→  │                              │
  │     (候选 Parent 列表)        │                              │
  │                                │                              │
  │                               │ ── submit_fetch_log_task ──→  │
  │                               │    (start_lsn = 0 或当前位置) │
  │                               │                              │
  │                               │ ←── handle() ───────────────  │
  │                               │    向 Parent/Leader 拉取日志  │
  │  ── push_log (Paxos 日志) ──→  │                              │
  │                                │                              │
  │  (重复拉取-同步直到进度匹配)   │                              │
  │                                │                              │
  │  ── SWITCH_LEARNER_TO_ACCEPTOR─→                              │
  │     (升级为 Follower)         │                              │
```

---

## 5. 成员变更完整流程

### 5.1 添加副本（ADD_MEMBER）

以添加一个完整副本为例，展示最完整的成员变更流程：

```
                    添加副本时序

RootServer             Leader               新节点                 其他 Follower
    │                    │                     │                       │
    │  ── ADD_MEMBER ──→ │                     │                       │
    │                    │                     │                       │
    │                    │ ←change_config()─→ │                       │
    │                    │  ├ check_args       │                       │
    │                    │  ├ generate_new_config                       │
    │                    │  ├ update_election_meta                     │
    │                    │  ├ renew_barrier                             │
    │                    │  ├ append_config_info                       │
    │                    │  └ state → CHANGING                         │
    │                    │                     │                       │
    │                    │  ── config_log ────→│ (新节点尚在 Learner    │
    │                    │                     │  列表时可能收不到)     │
    │                    │  ── config_log ──────→──→                 │
    │                    │                     │                       │
    │                    │ ← ack_config_log ← │ ← ack_config_log ←  │
    │                    │                     │                       │
    │                    │ 多数派达成 (is_reach_majority_())            │
    │                    │ after_config_log_majority_()               │
    │                    │ state → INIT                               │
    │                    │                     │                       │
    │  结果返回 RootServer                     │                       │
    │                    │                     │                       │
    │  新节点启动 Learner 同步                    │                       │
    │                    │ ← register_parent  │                       │
    │                    │                     │                       │
    │                    │  ── FetchLog ────→  │   (全量日志拉取)       │
    │                    │                     │                       │
    │                    │  ── PushLog ─────→  │   (增量日志推送)       │
    │                    │                     │                       │
    │                    │ ← keepalive ──────  │                       │
    │                    │                     │                       │
    │                    │  日志追赶完成                               │
    │                    │                     │                       │
    │  ─ SWITCH_LEARNER_TO_ACCEPTOR ──→        │                       │
    │                    │ 变更 Learner 为 Acceptor                    │
    │                    │                     │                       │
    │                    │ 新节点正式成为 Follower                      │
```

### 5.2 remove Member 流程

```
RootServer             Leader             被移除副本
    │                    │                     │
    │  ─ REMOVE_MEMBER → │                     │
    │                    │ 校验参数             │
    │                    │ 生成新配置           │
    │                    │ 更新 Election 元数据 │
    │                    │ 提交配置日志到 Paxos  │
    │                    │                     │
    │                    │ ← ack_config_log ←  │ (可能超时)
    │                    │                     │
    │                    │ 等待多数派确认       │
    │                    │                     │
    │                    │ 配置生效             │
    │                    │ 从 log_sync_memberlist_ 移除          │
    │                    │ 从 alive_paxos_memberlist_ 移除       │
    │                    │ 更新 Election 成员列表                │
    │ ← 结果返回        │                     │
```

### 5.3 Learner 升降级

`UPGRADE_LEARNER_TO_ACCEPTOR` 和 `DEGRADE_ACCEPTOR_TO_LEARNER` 用于节点故障恢复场景：

```
故障降级场景：

正常状态:       A(Leader) ↔ B(Follower) ↔ C(Follower)  (3副本)

C 故障:         A(Leader) ↔ B(Follower)   C(Down)
                        ↓
                DEGRADE_ACCEPTOR_TO_LEARNER(C)
                        ↓
                A(Leader) ↔ B(Follower)   C(Degraded Learner)
                        ↓
              副本数仍为 3，C 作为降级 Learner 保留日志

C 恢复:          A(Leader) ↔ B(Follower)   C(Degraded Learner)
                        ↓
                UPGRADE_LEARNER_TO_ACCEPTOR(C)
                        ↓
                A(Leader) ↔ B(Follower) ↔ C(Follower)  (恢复正常)
```

> **区别**（`log_config_mgr.cpp` @ L1263-1275）：
> - `UPGRADE_LEARNER_TO_ACCEPTOR`：只能升级 `degraded_learnerlist_` 中的节点
> - `SWITCH_LEARNER_TO_ACCEPTOR`：升级普通 Learner（新节点）

### 5.4 Force 操作

`FORCE_SINGLE_MEMBER` 和 `FORCE_SET_MEMBER_LIST` 是特殊的强制操作：

```cpp
// log_config_mgr.h @ L70, L75
FORCE_SINGLE_MEMBER,     // 强制单副本（所有非 Leader 降级）
FORCE_SET_MEMBER_LIST,   // 强制设置成员列表（兼容多节点变更）
```

**特性**：
- 不需要在 Leader 执行（`need_exec_on_leader_()` return false）
- 用于极端恢复场景，如多数派节点永久故障
- `FORCE_SET_MEMBER_LIST` 接受完整的新成员列表 `new_member_list_`，以及 `added_list_` 和 `removed_list_` 用于更新 match_lsn 映射

`force_set_member_list()`（`log_config_mgr.cpp` @ L2574）的完整流程：
1. 从 `args.new_member_list_` 设置新成员列表
2. 从 `args.removed_list_` 计算被移除的成员
3. 更新 Election 元数据
4. 调用 `sw_->config_change_update_match_lsn_map()` 更新 match_lsn 映射

---

## 6. 配置日志的 Paxos 复制

### 6.1 配置日志提交

`submit_config_log_()`（`log_config_mgr.cpp` @ L2012）将新的配置元数据 `LogConfigMeta` 作为一条普通的 Paxos 日志提交：

```cpp
int LogConfigMgr::submit_config_log_(const ObMemberList &paxos_member_list,
                                     const int64_t proposal_id,
                                     const int64_t prev_log_proposal_id,
                                     const LSN &prev_lsn,
                                     const int64_t prev_mode_pid,
                                     const LogConfigMeta &config_meta);
```

关键点：
- 配置日志通过 Paxos 的 AppendEntries 机制同步到所有 Follower
- 只有配置日志在多数派达成后，新配置才正式生效
- `prev_log_proposal_id_` 和 `prev_lsn_` 作为 Barrier 确保日志连续性

### 6.2 after_config_log_majority_ — 多数派达成后处理

```cpp
// log_config_mgr.cpp @ L621 (declaration)
int LogConfigMgr::after_config_log_majority_(const int64_t proposal_id,
                                             const LogConfigVersion &config_version);
```

一旦配置日志在多数派上确认，Leader 执行：
1. 将新配置应用到 `log_ms_meta_.curr_`
2. 更新 Election 成员列表
3. 更新 `persistent_config_version_`
4. 重置重发信息
5. 如果包含 Learner 升级，设置 `will_upgrade_` 标记

### 6.3 Receiver 端处理

当 Follower 收到配置日志时（`receive_config_log()` @ L460），进行前向校验：
- `can_receive_config_log()`（@L475）：校验 Leader 身份和配置版本
- `after_flush_config_log()`（@L476）：将配置落盘后，更新本地配置元数据
- `ack_config_log()`（@L482）：回复 ACK 给 Leader，用于多数派计数

---

## 7. LogReconfigBarrier — 配置变更屏障

`LogReconfigBarrier`（`log_config_mgr.h` @ L308-340）确保配置变更发生在安全的日志位置：

```cpp
struct LogReconfigBarrier {
  int64_t prev_log_proposal_id_;   // 前一个日志 proposal ID
  LSN prev_lsn_;                   // 前一个 LSN
  LSN prev_end_lsn_;               // 前一个结束 LSN
  int64_t prev_mode_pid_;          // 前一个 Mode proposal ID
};
```

Barrier 的三重作用：
1. **日志顺序保证**：新的配置日志必须在前一个配置日志之后（`check_barrier_condition_()` @ L1978）
2. **并发控制**：防止多个配置变更同时进行（`reconfig_barrier_` vs `checking_barrier_`）
3. **安全边界**：`MAX_WAIT_BARRIER_TIME_US_FOR_RECONFIGURATION` = 2s，`MAX_WAIT_BARRIER_TIME_US_FOR_STABLE_LOG` = 1s

`renew_config_change_barrier_()`（@L1011）从当前 `LogSlidingWindow` 的滑动窗口信息中更新 Barrier：

```cpp
int LogConfigMgr::renew_config_change_barrier_()
{
  // 从 sliding_window 获取当前日志位置
  // 赋值给 checking_barrier_ 和 reconfig_barrier_
}
```

---

## 8. 设计决策

### 8.1 为什么用 Learner 而不是直接添加 Follower？

**核心原因：日志追赶期间不参与投票**

| 方案 | 优点 | 缺点 |
|------|------|------|
| 直接添加 Follower | 流程简单 | 空节点直接进入 Paxos 组可能破坏多数派 |
| 先 Learner 后升级 | 安全：Learner 不投票，追赶完成再升 Follower | 流程较长，需要额外同步步骤 |

OceanBase 的选择：
1. 新节点以 `ADD_LEARNER` 加入
2. 通过 `FetchLogEngine` 全量拉取日志
3. 日志追赶完成后，通过 `SWITCH_LEARNER_TO_ACCEPTOR` 升级为 Follower
4. 此时新节点才参与 Paxos 投票

这实际上是 Paxos 中的 **先 Join 后 Catch-up** 模式，避免了空节点参与投票导致的可用性降低。

### 8.2 成员变更的安全保证

OceanBase 的成员变更在单步（single-step）模式下提供以下安全保证：

1. **多数派重叠**：每次变更只增删一个节点，新旧配置的多数派必然有重叠
2. **配置日志原子性**：新配置通过 Paxos 日志提交，日志本身保证全序
3. **Barrier 保护**：`LogReconfigBarrier` 确保配置变更不会在日志空洞上发生
4. **状态机保护**：`ConfigChangeState` 的 INIT ↔ CHANGING 转换保证同一时间只有一个变更进行
5. **Leader 确定性**：`is_leader_for_config_change_()` 的三重检查确保只有真正的 Leader 才能执行变更

### 8.3 单步变更 vs 联合共识

| 特性 | OceanBase 单步变更 | Raft Joint Consensus |
|------|-------------------|---------------------|
| 复杂度 | 低（两状态机） | 高（C_old → C_old_new → C_new） |
| 变更多节点 | 串行（一次一个） | 并行（一次多个） |
| 安全性 | 多数派重叠保证 | 两阶段保证 |
| 效率 | 较低（LL 变更次数） | 较高（一次完成） |

OceanBase 选择单步变更的原因：
- CP 场景下，每次变更一个节点足够
- 实现简单，状态机只有 INIT/CHANGING 两种状态
- `FORCE_SET_MEMBER_LIST` 为需要批量变更的场景提供逃生口

### 8.4 Arbitratioin Member（仲裁成员）的处理

仲裁成员（`ADD_ARB_MEMBER` / `REMOVE_ARB_MEMBER`）是 OceanBase 的特色设计：

```
2F1A (2 Full Members + 1 Arbiter)
  A (Leader) ↔ B (Follower)   C (Arbiter)
                              ↑
                 仲裁成员只参与选举投票，
                 不存储数据、不同步日志
```

在成员变更中，仲裁成员的处理：
- 加入 Paxos 成员列表但不加入 `log_sync_memberlist`（`log_config_mgr.cpp` @ L1720）
- 多数派计算包含仲裁成员（`alive_paxos_replica_num_`）
- 配置日志重发间隔在包含仲裁成员时适配（`PALF_RESEND_CONFIG_LOG_FOR_ARB_INTERVAL_US`）
- 仲裁成员无需 `renew_config_change_barrier_`（`append_config_meta_()` @ L1614）

### 8.5 强制变更的风险

`FORCE_SINGLE_MEMBER` 和 `FORCE_SET_MEMBER_LIST` 用于灾难恢复：

**使用场景**：Paxos 组多数派永久故障，无法通过正常成员变更修复

**风险**：
1. **脑裂风险**：旧 Leader 可能仍然存活，认为自己是合法的 Leader
2. **数据不一致**：强制变更可能丢弃已提交的日志
3. **配置冲突**：强制变更后的节点可能重新加入旧配置，导致配置混乱

**安全措施**：
- 仅允许管理员手动触发
- 强制操作后需要进行全量日志同步
- 旧节点重新加入时需要重新学习当前配置

---

## 9. 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 11 — PALF | `LogConfigMgr` 是 PALF 的子模块；成员变更通过 PALF 日志提交 |
| 12 — Election | 成员变更后需要更新 Election 元数据（`update_election_meta_()` @ L563-564）|
| 19 — Partition Migration | 迁移涉及 PALF 副本迁移，必然触发成员变更 |
| 27 — RootServer | RootServer 作为调度者发起 PALF 成员变更协调 |

### 成员变更触发链

```
RootServer / DDL             → 触发成员变更
     ↓
ObLS (LogStream)              → PalfHandleImpl::change_config()
     ↓
LogConfigMgr::change_config() → 校验、生成新配置、提交配置日志
     ↓
Paxos 多数派确认               → 配置生效
     ↓
Election 成员列表更新          → 新成员可参与选主
```

---

## 10. 源码索引

### 10.1 核心类索引（doom-lsp 确认）

| 符号 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `LogConfigChangeType` | `log_config_mgr.h` | L53 | 变更类型枚举（20 种） |
| `LogConfigChangeArgs` | `log_config_mgr.h` | L219 | 变更参数结构体 |
| `LogReconfigBarrier` | `log_config_mgr.h` | L308 | 配置变更屏障 |
| `LogConfigMgr` | `log_config_mgr.h` | L342 | 配置管理器 |
| `ConfigChangeState` | `log_config_mgr.h` | L537 | 变更状态机（INIT/CHANGING） |
| `LogLearner` | `log_learner.h` | L30 | Learner 数据结构 |
| `LogLearnerList` | `log_learner.h` | L62 | Learner 列表 |
| `LogCandidateList` | `log_learner.h` | L63 | 候选 Parent 列表 |
| `FetchLogTask` | `fetch_log_engine.h` | L24 | 日志拉取任务 |
| `FetchLogEngine` | `fetch_log_engine.h` | L82 | 日志拉取引擎 |
| `LogSimpleMemberList` | `log_simple_member_list.h` | L15 | 轻量成员列表 |
| `LogAckList` | `log_simple_member_list.h` | L55 | ACK 列表 |

### 10.2 核心方法索引（doom-lsp 确认）

| 方法 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `LogConfigMgr::init()` | `log_config_mgr.cpp` | L87 | 初始化 |
| `LogConfigMgr::change_config()` | `log_config_mgr.cpp` | L815 | 成员变更入口 |
| `LogConfigMgr::change_config_()` | `log_config_mgr.cpp` | L843 | 变更状态机 |
| `LogConfigMgr::append_config_meta_()` | `log_config_mgr.cpp` | L1564 | 生成并应用新配置 |
| `LogConfigMgr::generate_new_config_info_()` | `log_config_mgr.cpp` | L1688 | 新配置生成 |
| `LogConfigMgr::append_config_info_()` | `log_config_mgr.cpp` | L1647 | 写入本地配置信息 |
| `LogConfigMgr::submit_config_log_()` | `log_config_mgr.cpp` | L2012 | 提交配置日志到 Paxos |
| `LogConfigMgr::check_config_change_args_by_type_()` | `log_config_mgr.cpp` | L1108 | 按类型校验参数 |
| `LogConfigMgr::is_leader_for_config_change_()` | `log_config_mgr.cpp` | L924 | Leader 三重校验 |
| `LogConfigMgr::is_reach_majority_()` | `log_config_mgr.cpp` | L1023 | 多数派判定 |
| `LogConfigMgr::force_set_member_list()` | `log_config_mgr.cpp` | L2574 | 强制设置成员列表 |
| `LogConfigMgr::renew_config_change_barrier_()` | `log_config_mgr.cpp` | L1011 | 更新变更屏障 |
| `LogConfigMgr::after_config_log_majority_()` | `log_config_mgr.cpp` | L621 | 多数派达成后处理 |
| `LogConfigMgr::register_parent()` | `palf_handle_impl.cpp` | L4206 | Learner 注册 |
| `PalfHandleImpl::handle_register_parent_req()` | `palf_handle_impl.cpp` | L1573 | 处理注册请求 |
| `FetchLogEngine::submit_fetch_log_task()` | `fetch_log_engine.cpp` | L121 | 提交日志拉取任务 |
| `FetchLogEngine::handle()` | `fetch_log_engine.cpp` | L165 | 处理拉取任务 |

### 10.3 辅助函数索引

| 符号 | 文件 | 行号 | 说明 |
|------|------|------|------|
| `is_add_log_sync_member_list()` | `log_config_mgr.h` | L121 | 增加日志同步成员？ |
| `is_remove_log_sync_member_list()` | `log_config_mgr.h` | L128 | 移除日志同步成员？ |
| `is_add_member_list()` | `log_config_mgr.h` | L134 | 增加成员列表？ |
| `is_remove_member_list()` | `log_config_mgr.h` | L139 | 移除成员列表？ |
| `is_paxos_member_list_change()` | `log_config_mgr.h` | L191 | Paxos 成员列表变化？|
| `is_upgrade_or_degrade()` | `log_config_mgr.h` | L162 | 升降级操作？ |
| `is_may_change_replica_num()` | `log_config_mgr.h` | L180 | 可能改变副本数？ |
| `is_must_not_change_replica_num()` | `log_config_mgr.h` | L185 | 不改变副本数？ |
| `need_exec_on_leader_()` | `log_config_mgr.h` | L175 | 需在 Leader 执行？ |
| `need_check_config_version()` | `log_config_mgr.h` | L113 | 需要检查配置版本？ |

---

## 11. 总结

PALF 成员变更是一个设计精巧、工程化完善的分布式一致性协议实现：

1. **丰富的变更类型**：20 种变更类型覆盖了添加/移除成员、Learner 管理、仲裁成员、强制恢复等所有场景
2. **安全的状态机**：INIT → CHANGING → INIT 的两状态机保证了一次只有一个变更在进行
3. **Learner 机制**：新节点以 Learner 身份加入，追赶日志后再升级为 Follower，保证了 Paxos 组的安全性
4. **Barrier 保护**：`LogReconfigBarrier` 确保配置变更的日志位置语义正确
5. **仲裁成员支持**：`2F1A` 架构在不增加数据副本数的情况下优化选举可用性
6. **强制操作逃生口**：`FORCE_SINGLE_MEMBER` 和 `FORCE_SET_MEMBER_LIST` 为极端故障场景提供恢复手段

成员变更是 OceanBase 分布式核心中最复杂的部分之一，它与 Election、PALF 复制、Partition Migration 等多个子系统深度交互，共同保证了 OceanBase 在节点变更场景下的数据一致性和可用性。
