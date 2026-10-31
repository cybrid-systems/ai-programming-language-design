# 24-wal-format-and-recovery — FileBasedWal 的文件格式、写放大与恢复

> 源码：<https://github.com/vesoft-inc/nebula>，tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`
> 范围：`src/kvstore/wal/`、`src/kvstore/Part.cpp`
> 工具：doom-lsp（clangd）符号定位 + 直接阅读
> 分析日期：2026-10-31

---

## 0. 概述

NebulaGraph 没有把 Raft 日志交给 RocksDB 的 WAL，而是自己实现了一套按 partition 分目录的 `FileBasedWal`。这样做的好处是：

- Raft 日志的 `LogID/TermID` 与 RocksDB 的 MVCC 序列号解耦；
- 可以在不改 RocksDB 配置的情况下做日志截断、回滚、快照；
- 每个 partition 的 WAL 文件可以独立清理。

代价是：**同一笔写会落两次盘**——先写 Raft WAL，提交后再写 RocksDB（RocksDB 自己的 WAL 也可以独立配置（`--rocksdb_disable_wal`，默认 false））。本文只讨论第一套。

---

## 1. 目录与文件命名

`FileBasedWal` 构造时扫描 `<wal_root>/<space>/<part>/\*.wal`（`src/kvstore/wal/FileBasedWal.cpp:85`）。文件名格式是：

```
<该文件第一条日志的 LogID>.wal
```

例如 `1.wal`、`10001.wal`。构造流程（`FileBasedWal.cpp:40-78`）：

1. 如果目录不存在就 `makeDir`；
2. `scanAllWalFiles` 按文件名排序，记录每个文件的 size / mtime；
3. 取第一个文件的 `firstId` 作为 `firstLogId_`；
4. 取最后一个文件的 `lastId/lastTerm` 作为 `lastLogId_/lastLogTerm_`；
5. 以 `O_WRONLY | O_APPEND` 打开最后一个文件。

字段定义在 `FileBasedWal.h:266-268`。

---

## 2. 单条日志的字节布局

`appendLogInternal`（`FileBasedWal.cpp:442`）把一条日志编码成：

```
┌──────────┬──────────┬─────────┬──────────┬──────────────┬─────────┐
│ LogID    │ TermID   │ len     │ ClusterID│ msg          │ len     │
│ (LogID)  │ (TermID) │ (int32) │(ClusterID)│ (len bytes) │ (int32) │
└──────────┴──────────┴─────────┴──────────┴──────────────┴─────────┘
```

代码就是连续的 `append`：

```cpp
strBuf.append(reinterpret_cast<char*>(&id), sizeof(LogID));
strBuf.append(reinterpret_cast<char*>(&term), sizeof(TermID));
int32_t len = msg.size();
strBuf.append(reinterpret_cast<char*>(&len), sizeof(int32_t));
strBuf.append(reinterpret_cast<char*>(&cluster), sizeof(ClusterID));
strBuf.append(reinterpret_cast<const char*>(msg.data()), msg.size());
strBuf.append(reinterpret_cast<char*>(&len), sizeof(int32_t));
```

头尾各放一次 `len`，是为了在崩溃恢复时校验“这条消息是否完整”。`scanLastWal`（`FileBasedWal.cpp:371`）逐条读取：

- 读 `id`，必须等于期望的 `curLogId`；
- 读 `term`；
- 读头部 `len`，再按 `pos + sizeof(LogID) + sizeof(TermID) + sizeof(int32_t) + sizeof(ClusterID) + len` 读尾部 `len`；
- `head != foot` 就停止；
- 如果 `pos` 小于文件实际大小，说明尾部有半条日志，直接 `ftruncate` 到 `pos`（`FileBasedWal.cpp:425-435`）。

这就是“非正常关机后 WAL 仍可打开”的关键：**宁可截断最后一条，也不把半条日志当成有效数据**。

---

## 3. 写入路径

`appendLogInternal` 的顺序很重要：

1. **连续性检查**：`lastLogId_ != 0 && firstLogId_ != 0 && id != lastLogId_ + 1` 直接失败（446 行）。Raft 不允许日志空洞。
2. **preProcessor**：在真正写盘前做一次预处理（例如统计/限流），返回 false 就不写。
3. **滚动文件**：如果当前文件大小 + 本条大小超过 `policy_.fileSize`，`closeCurrFile` 后 `prepareNewFile(id)`（约 477 行）。
4. **write**：一次 `write` 写入整条记录；短写直接 `LOG(FATAL)`。
5. **fsync**：只有 `policy_.sync` 为真才 `fsync`（491 行）。这是吞吐与持久性的开关。
6. **更新内存状态**：`lastLogId_`、`lastLogTerm_`、`firstLogId_`、`currInfo_->size()`。
7. **写入 logBuffer**：`logBuffer_->push(id, term, cluster, msg)`，供 follower 或本机未落盘的读取使用。

`appendLogs`（515 行）只是对迭代器逐条调用 `appendLogInternal`，并在入口检查 `DiskManager::hasEnoughSpace`。磁盘不足时返回 false，不会写出半截。

---

## 4. 读：logBuffer 与文件迭代器

`iterator(firstLogId, lastLogId)`（`FileBasedWal.cpp:530`）先尝试 `logBuffer_->iterator`。只有在内存缓冲区里找不到时，才退回到 `WalFileIterator` 读文件。

这个设计的意义：

- Leader 刚 append、还没 flush 的日志，可以直接从内存缓冲区复制给 Follower；
- Follower 收到的日志先写文件，再进缓冲区，所以本地 commit 也能读到；
- 读取顺序不需要和文件系统缓存打交道。

---

## 5. 截断、回滚与清理

| 操作 | 函数 | 行为 |
|------|------|------|
| 回滚到某条日志 | `rollbackToLog`（569 行） | 只允许 `[firstLogId_-1, lastLogId_]`，删除之后的文件/记录 |
| 全部重置 | `reset`（622 行） | 清空 `walFiles_`，`firstLogId_ = lastLogId_ = 0` |
| 清理已提交日志 | `cleanWAL`（640/676 行） | 删除 `commitLogId` 之前的文件，保留边界文件 |
| 改链到新目录 | `linkCurrentWAL`（538 行） | 快照/备份场景下把当前 WAL 链接到新路径 |

`rollbackToLog` 的边界检查在 570 行；`cleanWAL` 会保留包含 `commitLogId` 的那个文件，避免把还需要回放的日志删掉。

---

## 6. 恢复：WAL 与 RocksDB 的提交位点

启动时，`Part` 会从 WAL 恢复 `lastLogId_`，再读 RocksDB 里的 `commitLogId`（`Part::lastCommittedLogId`，`Part.cpp:52`）。两者之间可能有差距：

- WAL 里有、RocksDB 里没提交的日志 → 需要重新 apply；
- WAL 已被 clean、RocksDB 已提交 → 直接从 RocksDB 的位点继续。

`Part::commitLogs` 在同一个 `WriteBatch` 里做两件事：

```cpp
// src/kvstore/Part.cpp:350
auto code = putCommitMsg(batch.get(), lastId, lastTerm);
...
auto code = engine_->commitBatchWrite(
    std::move(batch), FLAGS_rocksdb_disable_wal, FLAGS_rocksdb_wal_sync, wait);
```

把 `committedLogId/committedLogTerm` 和数据放进同一个 batch，保证不会出现“数据写了但位点没写”或反过来。这个位点就是恢复时的锚。

---

## 7. 写放大与调优

一次写入的持久化链条：

```
graphd → storaged
  → Raft WAL（FileBasedWal，policy.sync 控制 fsync）
  → 多数派确认
  → Part::commitLogs → RocksDB WriteBatch（RocksDB 自己的 WAL 可选）
```

因此：

- `--raft_wal_sync` / `policy.sync` 打开时，每次 append 都 fsync，延迟高但掉电安全；
- RocksDB 的 `FLAGS_rocksdb_disable_wal` 可以关掉第二层 WAL，依赖 Raft WAL 做恢复；
- WAL 文件按 `policy_.fileSize` 滚动，`cleanWAL` 按 commit 位点删除，长期运行不会无限增长。

---

## 8. 常见误解

1. **“WAL 文件坏了就只能重建副本”**：不一定。`scanLastWal` 会截断尾部半条记录；只有头部校验失败或 id 不连续才需要更多处理。
2. **“WAL 里的日志都能读”**：不能。只有 `committedLogId_` 之前的日志才能 apply；之后的日志要等 Leader 确认。
3. **“RocksDB WAL 一定开着”**：不一定。Nebula 用 Raft WAL 做主要恢复来源，RocksDB WAL 可以通过 flag 关闭。

---

## 9. 验证方式

- 在 `v3.8.0` 上编译 `kvstore` 目标（GCC 11 + Ninja）。
- 用 doom-lsp 对 `FileBasedWal.h` 做 `doc`，确认 `FileBasedWal`、`WalFileInfo`、`AtomicLogBuffer` 的符号位置。
- 所有行号来自当前 tag 源码；文件格式按 `appendLogInternal` 与 `scanLastWal` 的读写顺序对照得出。

---

## 10. 和本系列的关系

- Raft 如何使用 WAL：见 [24-raft-replication](24-raft-replication.md)。
- 提交后如何写 RocksDB：见 [26-rocksdb-storage-engine](26-rocksdb-storage-engine.md)。
