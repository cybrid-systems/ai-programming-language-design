# 23-raft-replication — RaftPart 状态机、选举与日志提交

> 源码：<https://github.com/vesoft-inc/nebula>，tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`（2024-05-17）
> 范围：`src/kvstore/raftex/`、`src/kvstore/Part.cpp`、`src/kvstore/Part.h`
> 工具：doom-lsp（clangd）解析 `RaftPart` / `Part` 符号，逐段对照源码
> 分析日期：2026-10-31

---

## 0. 概述

NebulaGraph 的每个 partition 是一个独立的 Raft 副本组。`Part` 直接继承 `raftex::RaftPart`（`src/kvstore/Part.h:25`），所以“Part 的日志”就是“Raft 的日志”：写请求先变成一条 `OP_*` 日志，复制到多数派后才 apply 到 RocksDB。

本文回答五个问题：

1. `RaftPart` 到底维护哪些状态，term / votedFor / commitLogId 分别干什么。
2. 选举为什么先 PreVote，再正式投票，超时后谁变成 Candidate。
3. Leader 如何把日志复制到 Follower，什么时候算“已提交”。
4. Follower 收到 `AppendLogRequest` 后如何做日志匹配、截断和提交。
5. 快照、成员变更与 `commitInThisTerm_` 这些容易被忽略的约束。

---

## 1. 一条写请求的落点

存储层处理器最终调用 `Part` 的写接口，例如 `Part::put` / `Part::multiPut` / `Part::remove`，这些接口都走 `appendAsync`：

```cpp
// src/kvstore/Part.cpp:72
appendAsync(FLAGS_cluster_id, std::move(log))
```

`RaftPart::appendLogAsync`（`src/kvstore/raftex/RaftPart.cpp:786`）负责：

- 检查当前角色和 WAL 缓冲区是否已满；
- 给日志分配 `LogID`，写入本地 WAL；
- 触发 `replicateLogs`，把日志发给 peers；
- 返回一个 `folly::Future`，在多数派确认后完成。

真正的 apply 发生在 `Part::commitLogs`（`src/kvstore/Part.cpp:215`）：

```cpp
auto batch = engine_->startBatchWrite();
...
case OP_PUT: {
  auto pieces = decodeMultiValues(log);
  auto code = batch->put(pieces[0], pieces[1]);
  ...
}
...
auto code = engine_->commitBatchWrite(
    std::move(batch), FLAGS_rocksdb_disable_wal, FLAGS_rocksdb_wal_sync, wait);
```

也就是说，Raft 日志和 RocksDB 写入是两套持久化：WAL 保存“还没确认的日志”，RocksDB 保存“已经提交并 apply 的状态”。`putCommitMsg` 会把 `committedLogId/committedLogTerm` 作为一条特殊 key 写进同一个 batch，保证“数据 + 提交位点”原子落盘（`src/kvstore/Part.cpp:350`）。

---

## 2. RaftPart 的状态

`RaftPart` 定义在 `src/kvstore/raftex/RaftPart.h:69`。核心字段在 815–862 行：

| 字段 | 含义 |
|------|------|
| `role_` | `LEADER` / `FOLLOWER` / `CANDIDATE` / `LEARNER` |
| `leader_` | 当前 Leader 地址；自己是 Leader 时等于 `addr_` |
| `votedAddr_` / `votedTerm_` | 本 term 把票投给了谁，防止同 term 重复投票 |
| `term_` | 当前任期 |
| `lastLogId_` / `lastLogTerm_` | Leader 视角：已复制到多数派的最大日志；Follower 视角：本地 WAL 的最大日志 |
| `committedLogId_` / `committedLogTerm_` | 已 apply 到状态机的最大日志 |
| `wal_` | `FileBasedWal`，见第 24 篇 |
| `snapshot_` | `SnapshotManager`，负责落后太多的副本 |
| `commitInThisTerm_` | 本 term 是否提交过日志；新 Leader 必须提交一条本 term 日志后才能服务 |
| `isBlindFollower_` | 启动时不知道 Leader，允许立即发起选举 |

两个容易混淆的点：

- `lastLogId_` 在 Leader 和 Follower 上语义不同（源码注释在 829–832 行写得很清楚）。Leader 上它是“多数派已确认”，Follower 上它只是“本地收到的最后一条”。
- `committedLogId_` 才是“可以读”的边界。Follower 即使 WAL 里有日志，只要没被 Leader 告知 commit，就不能 apply。

---

## 3. 选举：PreVote + 正式投票

### 3.1 什么时候开始选举

`needToStartElection`（`RaftPart.cpp:1143`）只看两个条件：

```cpp
if (status_ == Status::RUNNING && role_ == Role::FOLLOWER &&
    (lastMsgRecvDur_.elapsedInMSec() >= FLAGS_raft_heartbeat_interval_secs * 1000 ||
     isBlindFollower_)) {
  role_ = Role::CANDIDATE;
  leader_ = HostAddr("", 0);
}
```

也就是“心跳超时”或“刚启动还是盲从者”。超时时间来自 `--raft_heartbeat_interval_secs`，不是硬编码。

### 3.2 PreVote 的意义

`prepareElectionRequest`（`RaftPart.cpp:1157`）在 PreVote 时用 `term_ + 1` 去询问，但不增加本地 term，也不投票给自己：

```cpp
if (isPreVote) {
  req.term_ref() = term_ + 1;
} else {
  req.term_ref() = ++term_;
  votedAddr_ = addr_;
  votedTerm_ = term_;
}
req.last_log_id_ref() = lastLogId_;
req.last_log_term_ref() = lastLogTerm_;
```

PreVote 的作用是避免“网络分区里刚恢复的节点用更高 term 打断健康 Leader”。只有 PreVote 拿到多数派，才进入正式投票并自增 term。

### 3.3 计票

`processElectionResponses`（`RaftPart.cpp:1218`）做三件事：

1. 如果响应里出现更高 term，立即降级为 Follower 并清空 `leader_`；
2. 统计成功票数，`numSucceeded >= quorum_` 才算赢；
3. 正式选举赢后设置 `role_ = LEADER`、`leader_ = addr_`、`isBlindFollower_ = false`；PreVote 赢只记录日志，不改角色。

`quorum_` 在 `updateQuorum`（`RaftPart.cpp:617`）里按 `hosts_.size() / 2 + 1` 计算，成员变更后会重算。

---

## 4. Leader 的复制与提交

Leader 的路径是：

```
appendLogAsync
  → appendLogsInternal        // 本地 WAL
  → replicateLogs             // 并发发给 peers
  → processAppendLogResponses // 统计多数派
  → commitLogs                // apply 到 RocksDB
```

关键函数与位置：

| 阶段 | 函数 | 位置 |
|------|------|------|
| 入队 / 分配 LogID | `appendLogAsync` | RaftPart.cpp:786 |
| 写本地 WAL | `appendLogsInternal` | RaftPart.cpp:874 |
| 发送 | `replicateLogs` | RaftPart.cpp:918 |
| 收响应 | `processAppendLogResponses` | RaftPart.cpp:1002 |
| 提交 | `commitLogs` | RaftPart.cpp:1078 / Part.cpp:215 |

`appendLogsInternal` 在写 WAL 前会检查 `wal_->appendLogs(iter)` 的返回值（`RaftPart.cpp:895`）。WAL 写失败不会“假装成功”，而是让 future 以错误完成。

`processAppendLogResponses` 里有两个判定：

- 任一响应 term 更高 → 自己退位（1028 行附近）；
- 成功数达到 `quorum_` → 更新 `committedLogId_` 并调用 `commitLogs`（1078 行）。

注意 `commitLogs` 的第三个参数：Leader 需要持锁时传 `needLock=true`；Follower 在已持 `raftLock_` 的 `processAppendLogRequest` 里传 `false`，避免死锁（`RaftPart.h:492-499` 的注释）。

---

## 5. Follower 收到 AppendLogRequest

`processAppendLogRequest`（`RaftPart.cpp:1610`）是 follower 侧最复杂的函数：

1. 先 `verifyLeader`，检查 term 和 leader 地址；
2. 用 `lastMatchedLogId` 表示“Leader 与本地日志已经匹配到的位置”；
3. 处理三种不一致：
   - 请求的 `last_log_id_sent < committedLogId_`：返回 `E_RAFT_LOG_GAP`，让 Leader 从 committed 之后重发；
   - 本地 WAL 没有该日志（刚收过快照）：按 committed 位置判断；
   - 本地该位置 term 不同：返回 `E_RAFT_LOG_GAP`，Leader 会回退；
4. 匹配后 `wal_->appendLogs(logIter)`（1769 行），更新 `lastLogId_`；
5. 可提交位置是 `min(lastMatchedLogId, req.committed_log_id)`，再调用 `commitLogs`（1797 行）。

一个细节：Follower 的 `commitLogs` 传 `wait=false`（注释在 1793–1796 行）。原因是 follower 不要求“收到即 apply”，下一次 AppendLog 或它自己当选 Leader 时会继续推进。

---

## 6. 心跳、快照与成员变更

- 心跳：`needToSendHeartbeat`（1138 行）只在自己是 Leader 时返回 true；`sendHeartbeat`（2041 行）周期性发送，Follower 的 `processHeartbeatRequest`（1895 行）会重置 `lastMsgRecvDur_`，从而阻止选举。
- 快照：`processSendSnapshotRequest`（1954 行）处理 Leader 发来的快照块；`needToCleanupSnapshot`（1438 行）按 `FLAGS_raft_snapshot_timeout`（默认 300 秒）清理残留。
- 成员变更：`addPeer`（643 行）、`removePeer`（672 行）、`addLearner`（523 行）。Learner 只复制日志、不参与投票；`updateQuorum` 只统计非 learner 的 `hosts_`。
- `commitInThisTerm_`：新 Leader 不能直接读旧数据，必须先提交一条本 term 的日志。这是 Raft 的“Leader 完整性”约束在代码里的体现。

---

## 7. 常见误解

1. **“写了 WAL 就算成功”**：不对。WAL 只是本地持久化；必须等到 `processAppendLogResponses` 里多数派确认，`committedLogId_` 才推进。
2. **“Follower 收到日志就能读”**：不对。Follower 只 apply 到 `min(lastMatchedLogId, leader.committed)`，见 1790–1800 行。
3. **“PreVote 会自增 term”**：不会。PreVote 用 `term_ + 1` 询问，正式投票才 `++term_`。
4. **“Part 是纯存储对象”**：`Part` 继承 `RaftPart`，本身就是副本组；RocksDB 只是它的状态机。

---

## 8. 验证方式

- 在 `v3.8.0` 浅克隆上编译（GCC 11 + Ninja，见仓库构建记录），确认 `raft` 相关目标通过编译。
- 用 doom-lsp 对 `src/kvstore/raftex/RaftPart.h` 做 `doc`，得到 `RaftPart`、`Host`、`AppendLogsIterator` 等符号位置，再逐段阅读 `RaftPart.cpp`。
- 本文所有行号均来自该 tag 的当前文件；没有引用 master 或 release-3.8 的行为。

---

## 9. 和本系列的关系

- WAL 的文件格式与恢复：见 [25-wal-format-and-recovery](25-wal-format-and-recovery.md)。
- RocksDB 如何承接 apply：见 [26-rocksdb-storage-engine](26-rocksdb-storage-engine.md)。
- Meta 服务如何管理副本与心跳：见 [27-meta-service](27-meta-service.md)。
