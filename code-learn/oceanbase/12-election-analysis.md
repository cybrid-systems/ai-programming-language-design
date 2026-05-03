# 12 — Election — OceanBase 的选主与故障切换

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

上一篇文章（11 — PALF）介绍了 OceanBase 基于 Paxos 的一致性日志复制框架。Election 是 PALF 的核心子模块，位于 `src/logservice/palf/election/` 下，实现了**基于 Paxos 的领导者选举算法**。

在分布式系统中，一个日志复制组（Paxos Group）需要选出一个 Leader 来负责日志的复制和提交。Election 模块正是完成这一职责——它在成员间达成共识，选出一个副本作为 Leader，监控其健康状态，在 Leader 故障时触发新的选举。

### Election 在 PALF 中的位置

```
PalfHandleImpl (Paxos 状态机)
    │
    ├── LogSlidingWindow     ← 日志滑动窗口（多数派跟踪）
    ├── LogConfigMgr          ← 成员列表管理
    ├── LogStateMgr           ← 角色状态机
    ├── LogReconfirm          ← Leader 上任确认
    ├── LogEngine             ← 日志存储引擎
    │
    └── Election              ← 选主模块（本文）
         ├── ElectionImpl     ← 选举核心实现
         ├── ElectionProposer ← 提议者（Candidate/Leader 侧）
         ├── ElectionAcceptor ← 接受者（Voter 侧）
         ├── ElectionPriority ← 优先级策略
         └── ElectionMsgSender← 消息收发（由外部注入）
```

**核心文件一览**（doom-lsp 确认）：

| 文件 | 行数 | 职责 |
|------|------|------|
| `algorithm/election_proposer.h` | ~247 | 提议者：发起选举、续约、切主 |
| `algorithm/election_acceptor.h` | ~57 | 接受者：投票决策、Lease 管理 |
| `algorithm/election_impl.h` | ~323 | Election 核心实现：消息路由、优先级比较 |
| `interface/election.h` | ~107 | Election 接口定义、角色变更原因枚举 |
| `interface/election_priority.h` | ~50 | 优先级策略接口 |
| `interface/election_msg_handler.h` | ~36 | 消息收发接口 |
| `message/election_message.h` | ~478 | 选举消息类型体系 |
| `utils/election_common_define.h` | — | 常量定义、时间窗口计算、LogPhase 枚举 |
| `utils/election_utils.h` | — | Lease、MemberListWithStates、消息计数器 |

### 与 Raft 选举的对比

| 特性 | OceanBase Election | Raft |
|------|-------------------|------|
| **任期** | `ballot_number`（单调递增整数） | `term` |
| **消息类型** | Prepare / Accept（两阶段） | RequestVote / AppendEntries |
| **选主决策** | 优先级驱动 + majority | 日志新旧 + majority |
| **心跳** | Lease 续约（时间窗口） | AppendEntries（定期） |
| **主动切主** | `change_leader_to` | 不支持 |
| **优先级降级** | 支持临时降级优先级 | 不支持 |

---

## 1. 整体架构

### 1.1 Election 模块组件全景

```
Election (interface)
    ↑
ElectionImpl (核心实现，继承自 Election)
    ├── ElectionProposer     ← 发起 Prepare/Propose 请求
    ├── ElectionAcceptor     ← 处理 Prepare/Propose 请求
    ├── ElectionPriority     ← 优先级比较（策略模式）
    └── EventRecorder        ← 事件记录
        ↑
    ElectionMsgSender        ← 消息收发（外部注入接口）
```

### 1.2 角色状态机

Election 的 Proposer 维护一个角色状态机，在 `election_proposer.h` 的 `role_` 字段（@L192）中跟踪：

```
                    Start
                      │
                      ▼
  ┌────────────────────────────────┐
  │          FOLLOWER              │
  │   ─ 接收 Leader 的 Lease 续约  │
  │   ─ 选举超时 → 发起 Prepare    │
  │   ─ 收到更高 ballo/Leader 消息 │
  └──────────┬─────────────────┬───┘
             │                 ▲
   选举超时   │    Lease 恢复   │
   拿到多数派 │    /Lease 有效  │
      prepare │                 │
     成功     │                 │
             ▼                 │
  ┌────────────────────────────────┐
  │          CANDIDATE             │
  │   ─ Prepare 请求投票           │
  │   ─ 收到多数派 prepare_ok      │
  │   ─ 进入 LEADER 阶段           │
  └──────────┬─────────────────────┘
             │
   多数派同意│
    → Propose│
             ▼
  ┌────────────────────────────────┐     ┌──────────────────┐
  │          LEADER                │ ←── │  LeaderTakeover  │
  │   ─ 定期续约（Propose）         │     │  Lease 有效时    │
  │   ─ 检测 Lease 过期 → Revoke   │     │  直接接管         │
  │   ─ 收到更高 ballot → Follower │     └──────────────────┘
  └────────────────────────────────┘
```

角色变更通过 `role_change_cb_` 回调通知上层（`election_impl.h` @L306）。回调类型定义在 `RoleChangeReason` 枚举（`election.h` @L37-43）：

```cpp
enum class RoleChangeReason
{
  DevoteToBeLeader = 1,        // 无主选举：Follower → Leader
  ChangeLeaderToBeLeader = 2,  // 切主：新主 Follower → Leader
  LeaseExpiredToRevoke = 3,    // Lease 超时：Leader → Follower
  ChangeLeaderToRevoke = 4,    // 切主：旧主 Leader → Follower
  StopToRevoke = 5,            // 停止选举：Leader → Follower
};
```

---

## 2. 核心数据结构

### 2.1 ElectionImpl（`election_impl.h` @ L58-323）

`ElectionImpl` 是选举模块的主类，它组合了 Proposer 和 Acceptor 两个核心对象：

```cpp
// election_impl.h:58-307 - doom-lsp 确认
class ElectionImpl : public Election
{
  // ... 友元和继承关系

  // 核心能力
  int init_and_start(...);         // 初始化并启动
  int get_role(ObRole &role,       // 获取当前角色 + epoch
               int64_t &epoch);
  int get_current_leader_likely(   // 获取当前 leader（likely 语义）
      ObAddr &addr, int64_t &cur_leader_epoch);
  int set_priority(ElectionPriority *priority);  // 设置优先级策略
  int handle_message(...) 5个重载  // 处理 5 种选举消息

private:
  ElectionProposer proposer_;      // Proposer（提议者）
  ElectionAcceptor acceptor_;      // Acceptor（接受者）
  ElectionPriority *priority_;     // 优先级策略（可插拔）
  ElectionMsgSender *msg_handler_; // 消息收发器
  uint64_t inner_priority_seed_;   // 协议内选举优先级种子
};
```

**关键字段**：

| 字段（election_impl.h） | 行号 | 类型 | 说明 |
|------------------------|------|------|------|
| `proposer_` | @L300 | `ElectionProposer` | 提议者 |
| `acceptor_` | @L301 | `ElectionAcceptor` | 接受者 |
| `priority_` | @L302 | `ElectionPriority *` | 优先级策略 |
| `msg_handler_` | @L303 | `ElectionMsgSender *` | 消息收发器 |
| `inner_priority_seed_` | @L307 | `uint64_t` | 协议优先级种子 |
| `timer_` | @L320 | `ObOccamTimer *` | 定时器 |
| `temporarily_downgrade_priority_info_` | @L308 | `struct` | 临时降级优先级信息 |

### 2.2 ElectionProposer（`election_proposer.h` @ L50-247）

`ElectionProposer` 对应 Paxos 算法中的 **Proposer**，是主动发起选举的一方。

```cpp
// election_proposer.h:50-247 - doom-lsp 确认
class ElectionProposer
{
public:
  int init(const int64_t restart_counter);
  int set_member_list(const MemberList &new_member_list);
  int change_leader_to(const ObAddr &dest_addr);
  int start();
  void stop();
  bool check_leader(int64_t *epoch = nullptr) const;  // 检查本机是否为 leader

  // 选举核心流程
  void prepare(const common::ObRole role);           // 发起 Prepare（请求投票）
  void on_prepare_request(...);                       // 被动收到 Prepare 请求（"一呼百应"）
  void on_prepare_response(...);                      // 处理 Prepare 响应
  void propose();                                     // 发起 Propose（确认当选）
  void on_accept_response(...);                       // 处理 Accept 响应
  void inner_change_leader_to(const common::ObAddr &dst);  // 执行切主

private:
  common::ObRole role_;               // 当前角色（FOLLOWER/LEADER）
  int64_t ballot_number_;             // 当前感知的最大选举轮次
  MemberListWithStates memberlist_with_states_;  // 成员列表及状态
  int64_t prepare_success_ballot_;    // 被多数派 Prepare 成功的轮次
  int64_t last_leader_epoch_;         // 上次成功上任的轮次
  LeaderLeaseAndEpoch leader_lease_and_epoch_;   // Leader 租约
  int64_t restart_counter_;           // 日志流重启计数器（过滤旧消息）
  // ... 更多字段
};
```

#### LeaderLeaseAndEpoch（`election_proposer.h` @ L133-192）

这是一个精巧的数据结构，使用 **Sequence Lock** 实现 `lease` 和 `epoch` 的原子读取：

```cpp
// election_proposer.h:134-192 - doom-lsp 确认
struct LeaderLeaseAndEpoch {
  void set_lease_and_epoch_if_lease_expired_or_just_set_lease(
      const int64_t lease, const int64_t epoch) {
    ++seq_;                // 写前递增 seq（奇数表示写入中）
    MEM_BARRIER();
    old_lease = lease_;
    if (get_monotonic_ts() < old_lease) {  // Lease 未过期
      lease_ = lease;                       // 只更新 lease
      if (get_monotonic_ts() >= old_lease) { // Double-check
        epoch_ = epoch;                     // Lease 刚好过期，一起更新
      }
    } else {                                 // Lease 已过期
      lease_ = lease;
      epoch_ = epoch;                        // 同时更新
    }
    MEM_BARRIER();
    ++seq_;                // 写后递增 seq（偶数表示写入完成）
  }

  void get(int64_t &lease, int64_t &epoch) const {
    do {
      seq = seq_;          // 读取 seq
      MEM_BARRIER();
      if ((seq & 1) != 0) {  // 不在写入中才读取
        lease = lease_;
        epoch = epoch_;
      }
      MEM_BARRIER();
    } while (seq != seq_ || (seq & 1) == 0);  // 确保读取一致
  }
};
```

**为什么需要 Sequence Lock？** `epoch` 是外部调用者（如 PALF 的 LogStateMgr）用来识别 Leader 切换的标识。如果 Lease 中断后又恢复，epoch 必须更新——否则 ABA 问题可能导致错误的 Leader 身份判断。Sequence Lock 允许在没有原子指令开销的情况下安全读取这两个关联变量。

### 2.3 ElectionAcceptor（`election_acceptor.h` @ L38-57）

`ElectionAcceptor` 对应 Paxos 算法中的 **Acceptor**，是响应选举请求的一方。

```cpp
// election_acceptor.h:38-57 - doom-lsp 确认
class ElectionAcceptor
{
public:
  void on_prepare_request(const ElectionPrepareRequestMsg &prepare_req);  // 处理 Prepare
  void on_accept_request(const ElectionAcceptRequestMsg &accept_req,      // 处理 Accept
                         int64_t *us_to_expired);

private:
  int64_t ballot_number_;                    // 当前轮次
  int64_t ballot_of_time_window_;            // 已 Prepare 成功的轮次（时间窗口内）
  Lease lease_;                               // 租约（owner + 截止时间）
  ElectionPrepareRequestMsg highest_priority_prepare_req_;  // 缓存的最高优先级 Prepare
  bool is_time_window_opened_;               // 时间窗口打开状态
};
```

#### Lease（`election_utils.h`）

Acceptor 端的 Lease 记录了当前 lease 的 owner（哪个 Proposer 获得了 lease）、lease 截止时间和 ballot number：

```cpp
// election_utils.h - Lease 类
class Lease {
  common::ObAddr owner_;         // Lease 持有者
  int64_t lease_end_ts_;         // 截止时间戳
  int64_t ballot_number_;        // 对应的 ballot number
  RWLock lock_;
};
```

关键操作：
- `is_expired()` — 检查 lease 是否过期
- `get_owner_and_ballot(addr, ballot)` — 获取 lease 的 owner 信息
- `update_from(accept_req)` — 根据 Accept 请求更新 lease

### 2.4 MemberListWithStates（`election_utils.h`）

`MemberListWithStates` 记录了每个成员在选举过程中的状态：

- `prepare_ok_` — 每个成员是否已经 Prepare 成功
- `accept_ok_promise_not_vote_before_local_ts_` — Accept 响应的时间戳
- `follower_renew_lease_success_membership_version_` — Follower 成功续约的成员版本

核心方法：
- `record_prepare_ok(prepare_res)` — 记录某个成员的 Prepare 成功
- `record_accept_ok(accept_res)` — 记录某个成员的 Accept 成功
- `is_synced_with_majority()` — 检查当前成员版本是否已同步到多数派
- `get_majority_promised_not_vote_ts(ts)` — 获取多数派承诺不投票的时间戳

---

## 3. 选举消息系统

选举模块使用 5 种消息类型，定义在 `election_message.h` 中：

```
ElectionMsgType:
  PREPARE_REQUEST  = 0   ← Prepare 请求（投票请求）
  PREPARE_RESPONSE = 1   ← Prepare 响应（投票回复）
  ACCEPT_REQUEST   = 2   ← Accept 请求（当选确认）
  ACCEPT_RESPONSE  = 3   ← Accept 响应（确认 ACK）
  CHANGE_LEADER    = 4   ← 切主消息
```

### 3.1 消息继承体系

```cpp
// election_message.h - 消息类层次结构
ElectionMsgBase                        ← 基类：sender, receiver, ballot_number, msg_type
  ├── ElectionPrepareRequestMsgMiddle  ← 中间类：role, priority_buffer, inner_priority_seed
  │     └── ElectionPrepareRequestMsg  ← 最终类：序列化实现
  ├── ElectionPrepareResponseMsgMiddle ← 中间类：accepted, lease
  │     └── ElectionPrepareResponseMsg ← 最终类
  ├── ElectionAcceptRequestMsgMiddle   ← 中间类：lease_start_ts, lease_interval
  │     └── ElectionAcceptRequestMsg   ← 最终类
  ├── ElectionAcceptResponseMsgMiddle  ← 中间类：accepted, lease, priority_buffer
  │     └── ElectionAcceptResponseMsg  ← 最终类
  └── ElectionChangeLeaderMsgMiddle    ← 中间类：switch_source_leader_ballot
        └── ElectionChangeLeaderMsg    ← 最终类
```

**中间类（Middle）** 是版本兼容性设计：不同版本的 OceanBase 使用不同的消息结构，通过序列化字段兼容。例如：

```cpp
// election_message.h:167-171
class ElectionPrepareRequestMsg :
    public ElectionPrepareRequestMsgMiddle {
  // 最终类，继承中间类的所有字段
};
```

### 3.2 ElectionMsgBase（`election_message.h` @ L96-128）

```cpp
// election_message.h:96-128 - doom-lsp 确认
class ElectionMsgBase {
  int64_t id_;                          // 日志流 ID
  common::ObAddr sender_;               // 发送方地址
  common::ObAddr receiver_;             // 接收方地址
  int64_t restart_counter_;             // 重启计数器
  int64_t ballot_number_;               // 选举轮次（ballot）
  LsBiggestMinClusterVersionEverSeen    // 最大 min_cluster_version
      biggest_min_cluster_version_ever_seen_;
  ElectionMsgType msg_type_;            // 消息类型
  ElectionMsgDebugTs debug_ts_;         // 调试时间戳
};
```

### 3.3 关键消息字段

**ElectionPrepareRequestMsg** — 带优先级信息的投票请求：
- `role_` — 发送方当前角色
- `priority_buffer_` — 序列化的优先级数据
- `inner_priority_seed_` — 协议内优先级种子
- `membership_version_` — 成员配置版本

**ElectionAcceptRequestMsg** — 当选确认：
- `lease_start_ts_on_proposer_` — Proposer 上的 Lease 起始时间
- `lease_interval_` — Lease 续约间隔

**ElectionAcceptResponseMsg** — 当选确认的回复：
- `accepted_` — 是否接受
- `priority_buffer_` — 接受方的优先级信息
- `responsed_membership_version_` — 响应的成员版本

---

## 4. 选举数据流

### 4.1 完整选举时序

```
  Candidate (Proposer)            Acceptors (Voters)          Leader
         │                              │                     │(previous)
         │  1. 选举超时                   │                     │
         │  last_do_prepare_ts           │                     │
         │  + 随机延迟                    │                     │
         │                              │                     │
         │  2. Prepare Request ────────→ │                     │
         │    (ballot_number+1,          │                     │
         │     priority_buffer)          │                     │
         │                              │                     │
         │                              │  3. 投票决策         │
         │                              │  ─ ballot 校验      │
         │                              │  ─ 优先级比较        │
         │                              │  ─ 是否在时间窗口内  │
         │                              │                     │
         │  ←─────────────────── Prepare OK                   │
         │    (给出 lease 信息,          │                     │
         │     承诺不投票给更低优先级)   │                     │
         │                              │                     │
         │  4. 收集多数派 Prepare OK                         │
         │  prepare_success_ballot_      │                     │
         │  = ballot_number_            │                     │
         │                              │                     │
         │  5. Accept Request ───────── │                     │
         │    (确认当选)                 │                     │
         │                              │                     │
         │  ←─────────────────── Accept OK                    │
         │                              │                     │
         │  6. 收集多数派 Accept OK                           │
         │  lease_ 生效                 │                     │
         │  epoch = ballot_number       │                     │
         │                              │                     │
         │  7. [角色变更] Follower → Leader                  │
         │     callback: role_change_cb_│                     │
         │     (DevoteToBeLeader)       │                     │
         │                              │                     │
         │  8. 定期续约 (Propose)        │                     │
         │  CALCULATE_RENEW_LEASE_INTERVAL()                  │
         │                              │                     │
```

### 4.2 "一呼百应"（被动 Prepare）

当 Proposer 收到其他 Proposer 发来的 Prepare 请求时，即使自己不是选举的发起者，也会**被动执行 Prepare 并发出自己的 Prepare 请求**：

```cpp
// election_proposer.cpp - on_prepare_request
void ElectionProposer::on_prepare_request(
    const ElectionPrepareRequestMsg &prepare_req,
    bool *need_register_devote_task) {
  // 1. ballot 比较：如果收到更高的 ballot，则推高自己的 ballot_number
  if (prepare_req.get_ballot_number() > ballot_number_) {
    advance_ballot_number_and_reset_related_states_(
        prepare_req.get_ballot_number(), "receive higher ballot");
  }

  // 2. 将自己的 Prepare 请求也发送出去（"百应"）
  prepare(ObRole::FOLLOWER);

  // 3. 同步所有 Proposer 的定时任务
  *need_register_devote_task = true;
}
```

这个设计的目的是**减少选举耗时**：一旦有一个 Proposer 发起 Prepare，其他 Proposer 也会同时跟进，快速将 ballot number 推到更高的水平，避免多次选举周期。

### 4.3 优先级比较（`election_impl.h` @ L160+）

优先级比较是选主的关键决策点。`ElectionImpl::is_rhs_message_higher_()` 实现了完整的优先级比较链：

```
优先比较成员版本 (membership_version)
        ↓
  比较内优先级种子 (inner_priority_seed, 协议级)
        ↓
  比较优先级数据 (priority_buffer，具体策略决定)
        ↓
  IP地址比较（当所有其他条件相同时，地址小者获胜）
```

选择优先级更高的副本作为 Leader 的逻辑：

```
比较链（election_impl.h:160+ - doom-lsp 确认）:
  membership_version >  → 成员版本高者优先
  inner_priority_seed > → 种子值大者优先
  priority_buffer >     → 优先级数据（可插拔策略）
    PriorityV0: port_number (测试用)
    PriorityV1: observer_stopped > server_stopped > zone_stopped
              > fatal_failures > is_primary_region > serious_failures
              > SCN (数据新旧) > in_blacklist > manual_leader > zone_priority
  IP-PORT 比较          → 以上都相等时，地址小者优先
```

**PriorityV1 的详细比较顺序**（`election_priority_impl.h` @ L121+）：

| 比较项 | 说明 | 优先级影响 |
|--------|------|-----------|
| `is_observer_stopped_` | 进程是否被停止 | ❌ 停服 → 最低优先级 |
| `is_server_stopped_` | 服务器是否被停止 | ❌ 停服 → 低优先级 |
| `is_zone_stopped_` | Zone 是否被停止 | ❌ 停服 → 低优先级 |
| `fatal_failures_` | 致命故障（跳过 RCS 直接切主） | ❌ 有故障 → 低优先级 |
| `is_primary_region_` | 是否在主区域 | ✅ 主区域 → 高优先级 |
| `serious_failures_` | 严重故障（减少连接数） | ❌ 有故障 → 低优先级 |
| `SCN` | 日志进度 | ✅ SCN 越高 → 越可能当选 |
| `is_in_blacklist_` | 是否在黑名单 | ❌ 黑名单 → 低优先级 |
| `is_manual_leader_` | 是否手动指定 leader | ✅ 手动指定 → 最高优先级 |
| `zone_priority_` | Zone 级别优先级 | ✅ 值越小 → 优先级越高 |

### 4.4 Acceptor 投票决策

Acceptor 在收到 Prepare 请求后的决策逻辑（`election_acceptor.cpp` — `on_prepare_request`）：

```
收到 Prepare Request
        │
  1. 检查 balloot number
        │
   ┌────┴────┐
   │ 小于     │  ≥ 当前 ballot_number
   │ 当前     │
   │ballot    │
   └─────────┘
        │            │
        ▼            ▼
  返回拒绝     2. 比较优先级
  (告知当前        │
   ballot)    ┌────┴────────────┐
             │ 新消息优先级更高 │  当前优先级更高
             └─────────────────┘
                     │            │
                     ▼            ▼
             3. 进入决策          保留投票给当前最高
             打开时间窗口         优先级（除非时间窗口关闭）
                   │
             4. 记录最高优先级 Prepare
                打开时间窗口
                CALCULATE_TIME_WINDOW_SPAN_TS()
                   │
             5. 时间窗口关闭后投票
                给记录的最高优先级
```

**时间窗口**（Time Window）是选举的关键设计：Acceptor 在收到一个优先级更高的 Prepare 请求后，不会立即投票，而是打开一个时间窗口，在此期间收集所有收到的 Prepare 请求，等时间窗口关闭后再投票给其中优先级最高的一个。

时间窗口的长度为 `CALCULATE_TIME_WINDOW_SPAN_TS() = 2 * MAX_TST`，默认 2 秒。

### 4.5 切主流程（Change Leader）

OceanBase 支持**主动切主**，通过 `ElectionProposer::change_leader_to(dest_addr)` 实现。这在运维场景中用于负载均衡和故障转移。

```
当前 Leader                    目标 Follower                其他 Follower
    │                              │                          │
    │  1. change_leader_to(dst)    │                          │
    │  ├─ 检查 dest_addr 在成员列表 │                          │
    │  ├─ 检查自己是 Leader        │                          │
    │  └─ inner_change_leader_to() │                          │
    │                              │                          │
    │  2. 发送 ChangeLeaderMsg ───→│                          │
    │    (switch_source_leader_    │                          │
    │     ballot + addr)           │                          │
    │                              │                          │
    │                              │  3. 目标检查 ballot      │
    │                              │  4. 发起 quick prepare   │
    │                              │  (prepare_success_ballot)│
    │                              │                          │
    │  5. Leader → Follower        │  6. Follower → Leader    │
    │  回调: ChangeLeaderToRevoke  │  回调: ChangeLeaderToBeLeader
    │                              │                          │
    │                              │  7. 广播 accept(续约)    │
    │                              │                          │
    ▼                              ▼                          ▼
  Follower                       Leader                   Follower
```

切主消息 `ElectionChangeLeaderMsg` 包含旧主的 ballot 和地址，目标 Follower 根据这些信息快速推进选举周期。

### 4.6 Lease 续约

Leader 当选后，定期执行续约操作（Propose），续约周期为 `CALCULATE_RENEW_LEASE_INTERVAL() = 500ms`：

```
Leader 续约流程:
  1. 定时任务触发 (register_renew_lease_task_)
  2. 检查 Lease 是否过期 → 过期则执行 leader_revoke_if_lease_expired_
  3. 检查 prepare_success_ballot_ == ballot_number_ → 否则先做 Leader Prepare
  4. 执行 propose()
     4.1 广播 Accept Request (携带 lease_start_ts_on_proposer)
     4.2 收集 Accept Response
     4.3 更新 lease_ (续约成功)
     4.4 更新 leader_lease_and_epoch_ (Sequence Lock 保护)
  5. 重新调度下一次续约
```

Lease 的默认持续时间：`CALCULATE_LEASE_INTERVAL() = 4 * MAX_TST`，默认 4 秒。

触发无主选举的阈值：`CALCULATE_TRIGGER_ELECT_WATER_MARK() = 1s` — 当 Lease 剩余时间低于 1 秒时触发选举。

---

## 5. 与 PALF 的集成

### 5.1 Election 在 PalfHandleImpl 中的生命周期

```cpp
// palf_handle_impl.h - Election 与 PalfHandleImpl 的集成
class PalfHandleImpl : public IPalfHandleImpl {
  Election *election_;   // ← 选举模块指针
  // ...
};
```

`PalfHandleImpl` 在初始化时创建并启动 `ElectionImpl`：

```
PalfHandleImpl::init()
    │
    ├─→ new ElectionImpl()
    ├─→ ElectionImpl::init_and_start(id, timer, msg_handler, addr, ...)
    │       │
    │       ├─→ Proposer::init(restart_counter)
    │       ├─→ register_renew_lease_task_()  ← 注册续约定时任务
    │       └─→ reschedule_or_register_prepare_task_after_(...) ← 注册选举定时任务
    │
    └─→ ElectionImpl::set_memberlist(member_list)
            │
            └─→ Proposer::set_member_list(...)
```

### 5.2 角色切换回调

选举模块的角色变更通过两回调通知 PALF：

```cpp
// election_impl.h:305-306 - doom-lsp 确认
ObFunction<int(const int64_t, const ObAddr &)> prepare_change_leader_cb_;  // 切主回调
ObFunction<void(ElectionImpl *, ObRole, ObRole, RoleChangeReason)> role_change_cb_;  // 角色变更回调
```

`role_change_cb_` 在以下场景被调用：

| 场景 | 旧角色 | 新角色 | Reason |
|------|--------|--------|--------|
| 无主选举成功 | FOLLOWER | LEADER | DevoteToBeLeader |
| 切主成功（新主） | FOLLOWER | LEADER | ChangeLeaderToBeLeader |
| Lease 到期 | LEADER | FOLLOWER | LeaseExpiredToRevoke |
| 切主成功（旧主） | LEADER | FOLLOWER | ChangeLeaderToRevoke |
| 停止选举 | LEADER | FOLLOWER | StopToRevoke |

### 5.3 Leader 上任确认（LogReconfirm）

Election 选出 Leader 后，PALF 通过 `LogReconfirm` 流程确认新 Leader 拥有最新日志。这不是 Election 模块的职责，而是 PALF 的后续步骤。

```
Election          PalfHandleImpl          LogReconfirm
  │                     │                     │
  │  role_change_cb_    │                     │
  │ (FOLLOWER→LEADER)   │                     │
  │────────────────────→│                     │
  │                     │                     │
  │                     │  1. 收到回调后      │
  │                     │   设置状态为 LEADER  │
  │                     │                     │
  │                     │  2. 触发             │
  │                     │   LogReconfirm 流程  │
  │                     │────────────────────→│
  │                     │                     │
  │                     │                     │ 3. WAITING_LOG_FLUSHED
  │                     │                     │ 4. FETCH_MAX_LOG_LSN
  │                     │                     │ 5. RECONFIRM_MODE_META
  │                     │                     │ 6. RECONFIRM_FETCH_LOG
  │                     │                     │ 7. RECONFIRMING
  │                     │                     │ 8. START_WORKING (写日志)
  │                     │                     │ 9. FINISHED
  │                     │                     │
  │                     │  ←──── 上任完成 ───│
  │                     │ 正式开始服务         │
```

---

## 6. 设计决策

### 6.1 两阶段选举 vs Raft 的一阶段选举

OceanBase 的 Election 使用 **Prepare + Accept** 两阶段协议，而 Raft 使用 **RequestVote** 单阶段协议。

**为什么选择两阶段？**
- **优先级机制**：Prepare 阶段传递优先级信息，Acceptor 比较优先级，两阶段确保"优先级最高 + 日志最新"的副本当选
- **Lease 管理**：Accept 阶段建立 Lease，Proposer 知道自己的 lease 何时生效
- **安全切换**：Prepare 阶段承诺不投票给更低优先级的 Candidate，防止分票

### 6.2 优先级驱动 vs Raft 的日志新旧驱动

**Raft**：投票给日志最新的 Candidate（LastLogIndex + LastLogTerm）。

**OceanBase Election**：优先级决定谁更可能当选，优先级由多个维度决定（Zone 优先级、主区域、数据进度、手动指定等）。

This design allows operational flexibility:
- **主区域优先**：确保 Leader 在主区域，减少跨 Zone 延迟
- **手动指定**：运维时可以指定某个节点为 Leader
- **故障降级**：有 fatal/serious failure 的节点优先级自动降低

### 6.3 时间窗口（Time Window）

Acceptor 不立即投票给收到的第一个 Prepare 请求，而是打开一个**时间窗口**（`CALCULATE_TIME_WINDOW_SPAN_TS() = 2s`），在这段时间内收集所有 Prepare 请求，窗口关闭后投票给优先级最高的一个。

**目的**：防止分票。如果没有时间窗口，多个 Candidate 同时发起选举可能导致票数分散，需要多轮选举才能选出 Leader。

### 6.4 Leader Lease 与 Epoch

`LeaderLeaseAndEpoch` 使用 Sequence Lock 实现无锁读取的关键优化：

```cpp
// election_proposer.h - Sequence Lock 实现细粒度并发控制
struct LeaderLeaseAndEpoch {
  int64_t lease_;    // Lease 截止时间戳
  int64_t epoch_;    // 当选时的 ballot number（用于识别 Leader 切换）
  mutable int64_t seq_;  // Sequence Lock 的序列号
};
```

**为什么需要 Epoch？** 外部代码（如 PALF 的事务提交）需要知道当前的 Leader 是否稳定。如果 Lease 短暂中断后又恢复，epoch 不变——外部代码认为这是同一任期的延续。只有在 Lease 真正过期后重新当选时，epoch 才会变化。

### 6.5 单副本优化

在单副本部署下（`OB_ENABLE_STANDALONE_LAUNCH`），Election 模块直接返回自己是永久 Leader：

```cpp
// election_impl.h:55-63 - doom-lsp 确认
#ifdef OB_ENABLE_STANDALONE_LAUNCH
  role = common::ObRole::LEADER;
  epoch = 1;
#else
  // 正常选举逻辑
#endif
```

### 6.6 临时降级优先级

`ElectionImpl::TemporarilyDowngradePriorityInfo`（`election_impl.h` @L308-316）允许在特定场景下临时降低本节点的选举优先级：

```cpp
struct TemporarilyDowngradePriorityInfo {
  int64_t downgrade_expire_ts_;  // 降级过期时间
  int64_t interval_;             // 持续时间
  const char *reason_;           // 原因
};
```

例如，当节点正在重建数据时，通过 `SEED_IN_REBUILD_PHASE_BIT` 降低协议内优先级种子，使其在选举中不会被选为 Leader。

### 6.7 网络分区下的安全性

OceanBase Election 通过以下机制确保网络分区下的安全性：

1. **Lease 机制**：Leader 必须定期续约（Propose），断连的 Follower 无法续约 → Lease 过期 → 触发新选举
2. **时间窗口**：确保 Acceptor 不会在短时间内频繁改变投票
3. **ballot number**：单调递增，断连后重新连接的节点可以通过比较 ballot number 识别过期消息
4. **restart counter**：从持久化元数据中恢复，过滤宕机前的旧消息

---

## 7. 源码索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `algorithm/election_proposer.h` | @L50-247 | `ElectionProposer` 类定义 |
| `algorithm/election_proposer.h` | @L134-192 | `LeaderLeaseAndEpoch` 结构体（Sequence Lock） |
| `algorithm/election_proposer.h` | @L79 | `check_leader()` — Leader 身份检查 |
| `algorithm/election_proposer.h` | @L96 | `prepare()` — 发起选举 |
| `algorithm/election_proposer.h` | @L98 | `on_prepare_request()` — 被动 Prepare |
| `algorithm/election_proposer.h` | @L103 | `propose()` — 发起 Propose |
| `algorithm/election_proposer.h` | @L106 | `inner_change_leader_to()` — 切主 |
| `algorithm/election_proposer.h` | @L227-247 | `HighestPriorityMsgCache` — 缓存最高优先级消息 |
| `algorithm/election_proposer.cpp` | — | ResponseChecker 的 `check_ballot_and_restart_counter_valid_and_accepted()` |
| `algorithm/election_acceptor.h` | @L38-57 | `ElectionAcceptor` 类定义 |
| `algorithm/election_acceptor.h` | @L41 | `on_prepare_request()` — 接受者投票决策 |
| `algorithm/election_acceptor.h` | @L42 | `on_accept_request()` — 接受者确认当选 |
| `algorithm/election_acceptor.cpp` | — | `RequestChecker::check_ballot_valid()` — 投票校验 |
| `algorithm/election_impl.h` | @L58-323 | `ElectionImpl` 类定义 |
| `algorithm/election_impl.h` | @L60 | `init_and_start()` — 初始化入口 |
| `algorithm/election_impl.h` | @L80-103 | `get_role()` / `get_current_leader_likely()` |
| `algorithm/election_impl.h` | @L160-276 | `is_rhs_message_higher_()` — 优先级比较 |
| `interface/election.h` | @L37-43 | `RoleChangeReason` 枚举 |
| `interface/election.h` | @L57-88 | `Election` 接口定义 |
| `interface/election.h` | @L91-92 | `get_monotonic_ts()` — 单调时钟 |
| `interface/election_priority.h` | @L29-50 | `ElectionPriority` 接口定义 |
| `interface/election_msg_handler.h` | @L14-32 | `ElectionMsgSender` 接口定义 |
| `message/election_message.h` | @L96-128 | `ElectionMsgBase` — 消息基类 |
| `message/election_message.h` | @L167-171 | `ElectionPrepareRequestMsg` |
| `message/election_message.h` | @L222-226 | `ElectionPrepareResponseMsg` |
| `message/election_message.h` | @L278-282 | `ElectionAcceptRequestMsg` |
| `message/election_message.h` | @L403-407 | `ElectionAcceptResponseMsg` |
| `message/election_message.h` | @L456-460 | `ElectionChangeLeaderMsg` |
| `utils/election_common_define.h` | — | 常量与超时计算 |
| `utils/election_utils.h` | — | `Lease`、`MemberListWithStates`、`ElectionMsgCounter` |
| `utils/election_member_list.h` | @L27-47 | `MemberList` 类 |
| **Leader Coordinator** | | |
| `leader_coordinator/election_priority_impl/election_priority_impl.h` | — | `PriorityV0` / `PriorityV1` — 优先级策略实现 |

---

## 8. 核心代码阅读路径

要深入理解 Election，推荐以下阅读顺序：

1. **先读接口**：`interface/election.h` → 理解 Election 的外部契约
2. **再读消息**：`message/election_message.h` → 理解 5 种消息类型
3. **核心算法**：`algorithm/election_proposer.h` + `.cpp` → Proposer 的完整选举逻辑
4. **投票逻辑**：`algorithm/election_acceptor.h` + `.cpp` → Acceptor 的投票决策
5. **集成实现**：`algorithm/election_impl.h` + `.cpp` → 消息路由、优先级比较
6. **优先级策略**：`leader_coordinator/election_priority_impl/election_priority_impl.h` → PriorityV1

---

## 参考资料

- OceanBase 源码：`src/logservice/palf/election/`
- 文章 11：PALF — Paxos-Structured Log Framework
- Paxos Made Simple (Lamport)
- Raft 论文：In Search of an Understandable Consensus Algorithm
