# 25-rocksdb-storage-engine — RocksEngine 与 Part 的 apply 路径

> 源码：<https://github.com/vesoft-inc/nebula>，tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`
> 范围：`src/kvstore/RocksEngine.{h,cpp}`、`src/kvstore/Part.cpp`、`src/kvstore/NebulaStore.cpp`
> 工具：doom-lsp（clangd）定位 `RocksEngine` / `RocksWriteBatch` 符号
> 分析日期：2026-10-31

---

## 0. 概述

`RocksEngine` 是 Nebula 对 RocksDB 的薄封装：一个 space 一个 RocksDB 实例，多个 partition 共享同一个 DB，靠 key 前缀区分（`PartitionID` 编码在 key 里，见第 06–08 篇）。`Part` 负责 Raft，`RocksEngine` 负责真正的 KV 读写。

本文回答：

1. 一个 space 的 RocksDB 目录长什么样，打开时设置了什么。
2. `Part::commitLogs` 如何把 Raft 日志翻译成 `WriteBatch`。
3. 读路径 `get / range / prefix` 的差异。
4. compaction、checkpoint、backup 这些运维接口在哪。
5. 为什么“关掉 RocksDB WAL”在 Nebula 里是安全的。

---

## 1. 目录与打开

构造函数（`src/kvstore/RocksEngine.cpp:33`）：

```cpp
dataPath_ = folly::stringPrintf("%s/nebula/%d", dataPath.c_str(), spaceId);
...
auto path = folly::stringPrintf("%s/data", dataPath_.c_str());
...
rocksdb::Status status = initRocksdbOptions(options, spaceId, vIdLen);
...
options.compaction_filter_factory = cfFactory;   // TTL / 过期数据
...
status = rocksdb::DB::Open(options, path, &db);
```

要点：

- 数据目录是 `<data_path>/nebula/<spaceId>/data`；
- `vIdLen` 参与 key 前缀长度计算（`extractorLen_ = sizeof(PartitionID) + vIdLen`，见 106 行附近）；
- 支持 `readonly` 模式打开（备份/校验）；
- 非默认 space 会写入 `dataVersionKey`，用于数据版本校验；
- `compaction_filter_factory` 由外部注入，TTL 清理挂在这里。

---

## 2. 写路径：从 Raft 日志到 WriteBatch

`Part::commitLogs`（`src/kvstore/Part.cpp:215`）先创建一个 batch：

```cpp
auto batch = engine_->startBatchWrite();
```

然后按日志类型分发：

| 日志类型 | 操作 |
|----------|------|
| `OP_PUT` | `batch->put(key, value)` |
| `OP_MULTI_PUT` | 成对 `put` |
| `OP_REMOVE` | `batch->remove(key)` |
| `OP_MULTI_REMOVE` | 逐个 `remove` |
| `OP_REMOVE_RANGE` | `batch->removeRange(start, end)` |
| `OP_BATCH_WRITE` | 展开成多条 put/remove |

最后：

```cpp
auto code = engine_->commitBatchWrite(
    std::move(batch), FLAGS_rocksdb_disable_wal, FLAGS_rocksdb_wal_sync, wait);
```

`RocksEngine::commitBatchWrite`（`RocksEngine.cpp:124`）：

```cpp
options.disableWAL = disableWAL;
options.sync = sync;
options.no_slowdown = !wait;
status = db_->Write(options, b->data());
if (!wait && status.IsIncomplete()) return E_WRITE_STALLED;
```

三个参数的含义：

- `disableWAL`：关掉 RocksDB 自己的 WAL。Nebula 的 Raft WAL 已经提供恢复能力，所以可以关（`--rocksdb_disable_wal`，默认 false）；
- `sync`：是否 `fsync` RocksDB WAL/数据；
- `no_slowdown = !wait`：`wait=false` 时，写入队列满直接返回 `E_WRITE_STALLED`，由 Raft 稍后重试，避免 follower 卡死。

---

## 3. 读路径

`RocksEngine` 提供四类读：

| API | 位置 | 用途 |
|-----|------|------|
| `get` | `RocksEngine.cpp:143` | 单 key，支持 snapshot |
| `multiGet` | 约 160 行 | 批量 key |
| `range` | 186 行 | `[start, end)` 范围扫描 |
| `prefix` | 206 行 | 固定前缀扫描 |
| `rangeWithPrefix` | 257 行 | 前缀 + 范围 |
| `scan` | 277 行 | 全库扫描 |

`get` 使用 `memory::MemoryCheckOffGuard` 关闭内存检查，避免读路径被 watermark 误触发（143 行）。`range` 会把 `iterate_upper_bound` 传给 RocksDB，减少无效迭代。

---

## 4. compaction、checkpoint 与 backup

- `compact()`（`RocksEngine.cpp:527`）：调用 `db_->CompactRange`，可配置 `change_level/target_level`；
- `flush()`（540 行）：刷 memtable；
- `backup()`（551 行）：启动时/定期备份；
- `createCheckpoint(path)`（609 行）：RocksDB checkpoint，用于快照/备份；
- `openBackupEngine(spaceId)`（566 行）：打开备份引擎，配合 `createCheckpoint` 使用。

这些接口主要给 storage 的 admin job 和 snapshot 使用，不在普通读写路径上。

---

## 5. 与 Part 的关系

- `Part` 持有 `KVEngine* engine_`（`Part.h:351`），默认就是 `RocksEngine`；
- 一个 space 一个 engine，多个 `Part` 共享；
- `Part::commitLogs` 只负责“日志 → batch”，不关心 key 的语义；
- key 的编码（点、边、索引）在第 06–08 篇，不在这一层。

这也是为什么“换存储引擎”在代码上可行：`KVEngine` 是抽象接口，`RocksEngine` 只是实现之一。

---

## 6. 常见误解

1. **“一个 partition 一个 RocksDB”**：不是。一个 space 一个 DB，partition 靠 key 前缀隔离。
2. **“关掉 RocksDB WAL 会丢数据”**：在 Nebula 的链路里不会，因为 Raft WAL 才是恢复源；但前提是 Raft WAL 没有一起关。
3. **“commit 就是 fsync”**：不一定。`sync` 由 `FLAGS_rocksdb_wal_sync` 决定，默认值要看配置，不要假设每次写都落盘。

---

## 7. 验证方式

- 在 `v3.8.0` 上编译 `rocksdb` / `kvstore` 目标（GCC 11 + Ninja）。
- 用 doom-lsp 对 `RocksEngine.h` 做 `doc`，确认 `RocksEngine`、`RocksWriteBatch`、`commitBatchWrite` 的签名。
- 行号来自当前 tag；未引用其他分支。

---

## 8. 和本系列的关系

- Raft 日志如何产生：见 [24-raft-replication](24-raft-replication.md)。
- WAL 文件格式：见 [25-wal-format-and-recovery](25-wal-format-and-recovery.md)。
- key 编码：见 [06-key-encoding](06-key-encoding.md)、[07-row-encoding](07-row-encoding.md)、[08-index-key-encoding](08-index-key-encoding.md)。
