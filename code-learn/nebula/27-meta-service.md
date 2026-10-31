# 26-meta-service — Meta 服务的处理器模型、心跳与索引 DDL

> 源码：<https://github.com/vesoft-inc/nebula>，tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`
> 范围：`src/meta/MetaServiceHandler.cpp`、`src/meta/processors/`、`src/meta/ActiveHostsMan.cpp`
> 工具：doom-lsp（clangd）定位 `MetaServiceHandler` / `HBProcessor` / `CreateTagIndexProcessor`
> 分析日期：2026-10-31

---

## 0. 概述

Meta 服务是 Nebula 的“集群目录”：space、schema、index、host、heartbeat、用户权限都在这里。它本身也是一个 Raft 复制的 KV store（默认 space 0 / part 0），所有 DDL 都是“读-改-写”事务，通过 `BaseProcessor` 的 `doSyncPut` / `doRemove` 落到 meta 的 KV 引擎。

本文回答：

1. `MetaServiceHandler` 为什么只是一层薄薄的转发。
2. `BaseProcessor` 的锁和 `doSyncPut` 如何保证 DDL 原子性。
3. 心跳如何更新 host 状态，`ListHosts` 如何判断 online/offline。
4. 创建索引时做了哪些校验，索引元数据写到哪些 key。
5. 为什么 meta 的 Raft 和 storage 的 Raft 是两套独立的副本组。

---

## 1. Handler → Processor

`MetaServiceHandler` 的每个 `future_*` 方法基本只有三行：取 processor 单例、调用 `process`、返回 future。例如：

```cpp
// src/meta/MetaServiceHandler.cpp:86
folly::Future<cpp2::ExecResp> MetaServiceHandler::future_createSpace(
    const cpp2::CreateSpaceReq& req) {
  auto* processor = CreateSpaceProcessor::instance(kvstore_);
  return processor->process(req);
}
```

同类入口：

| 请求 | Handler 行 | Processor |
|------|-----------|-----------|
| `createSpace` | 86 | `CreateSpaceProcessor` |
| `createTag` | 167 | `CreateTagProcessor` |
| `createTagIndex` | 220 | `CreateTagIndexProcessor` |
| `listHosts` | 149 | `ListHostsProcessor` |
| `heartBeat` | 316 | `HBProcessor` |

这个模式的好处是：handler 不持有业务状态，processor 可以单独测试；所有写操作都走 `BaseProcessor` 的锁。

---

## 2. BaseProcessor 的锁与写

典型 processor 的 `process` 结构：

```cpp
folly::SharedMutex::ReadHolder rHolder(LockUtils::snapshotLock());
folly::SharedMutex::WriteHolder holder(LockUtils::lock());
...
auto result = doSyncPut(std::move(data));
handleErrorCode(result);
onFinished();
```

- `snapshotLock`：快照/备份时阻止 DDL；
- `lock`：全局写锁，保证同一时刻只有一个 DDL 在改 meta；
- `doSyncPut`：把一组 KV 写进 meta 的 Raft 组，成功后才返回。

读操作（如 `ListHosts`）用 `ReadHolder`，允许多个读并发。

---

## 3. 心跳与 host 状态

`HBProcessor::process`（`src/meta/processors/admin/HBProcessor.cpp:31`）处理 storage/graph 的心跳：

1. 解析 `HostAddr` 和 `HostRole`；
2. storage 角色会检查 `machineRegistered`，未注册的 host 直接拒绝；
3. 校验 cluster id，防止别的集群的节点混进来；
4. 把 `disk_parts` 写入 meta（用于 `SHOW HOSTS` 的磁盘分布）；
5. 更新 `HostInfo`：`lastHBTimeInMilliSec_`、role、git sha、leader part ids。

`ActiveHostsMan` 用“最后心跳时间 + 超时因子”判断存活：

```cpp
int64_t expiredTime =
    FLAGS_heartbeat_interval_secs * FLAGS_expired_time_factor;  // meta/storage/graph
...
if (now - info.lastHBTimeInMilliSec_ >= threshold) {
  iter->next();
  continue;
}
```

（`src/meta/ActiveHostsMan.cpp:99-107`；agent 角色用 `agent_heartbeat_interval_secs`，见 101 行。）

`ListHostsProcessor`（`src/meta/processors/parts/ListHostsProcessor.cpp:53`）在 `allHostsWithStatus` 里按同样的阈值过滤，只有心跳未过期的 host 才会出现在结果里；`ALLOC` 类型还会额外填 leader 和 partition 分布。

---

## 4. 创建索引的校验

`CreateTagIndexProcessor::process`（`src/meta/processors/index/CreateTagIndexProcessor.cpp:13`）是一个很好的 DDL 样本：

1. 检查 space id；
2. 字段去重，重复字段直接 `E_INVALID_PARM`；
3. 列数上限 `maxIndexLimit`（34 行）；
4. 同名索引已存在：`if_not_exists` 决定成功还是 `E_EXISTED`；
5. 检查 tag 是否存在；
6. 在已有索引里找“同 tag + 同字段”的重复索引；
7. 取最新 tag schema，逐字段校验：
   - 字段必须存在；
   - `DURATION` 不能建索引；
   - `FIXED_STRING` 不允许再指定长度；
   - `STRING` 必须指定长度，且不超过 `MAX_INDEX_TYPE_LENGTH`；
   - `GEOGRAPHY` 目前只支持单列索引（约 180 行）；
8. 分配 index id，构造 `IndexItem`；
9. 写两个 key：
   - `MetaKeyUtils::indexIndexKey(space, indexName)` → index id
   - `MetaKeyUtils::indexKey(space, tagIndex)` → 序列化的 `IndexItem`
10. `doSyncPut` 提交。

注意：这个 processor 只写“索引定义”。真正的索引数据构建由后续的索引重建/Job 流程完成，不在这个函数里。

---

## 5. Meta 的 Raft

Meta 的默认 space/part 是 `kDefaultSpaceId/kDefaultPartId`，它也有自己的 `Part` / `RaftPart` / WAL。`ListHostsProcessor::allMetaHostsStatus` 会取这个 part 的 peers（`ListHostsProcessor.cpp:96`），再把 raft 地址转成服务地址。

因此：

- meta 的 DDL 一致性由 meta Raft 保证；
- storage 的数据一致性由每个 partition 的 Raft 保证；
- 两套 Raft 的日志、快照、成员变更互不共享。

---

## 6. 常见误解

1. **“Meta 只是配置中心”**：它还承担 schema 版本、索引定义、host 心跳、权限等状态，是一个 Raft KV store。
2. **“心跳只是保活”**：它还携带 disk parts、leader part ids、cluster id 校验信息。
3. **“创建索引会立刻构建数据”**：这个 processor 只写定义；数据构建是后续流程。
4. **“ListHosts 读的是实时状态”**：它读 meta 里的 `HostInfo`，按最后心跳时间判断，存在心跳间隔带来的延迟。

---

## 7. 验证方式

- 在 `v3.8.0` 上编译 `meta` 目标（GCC 11 + Ninja）。
- 用 doom-lsp 对 `MetaServiceHandler.cpp`、`HBProcessor.cpp`、`CreateTagIndexProcessor.cpp` 做 `doc`，核对 processor 类与入口。
- 行号来自当前 tag；未引用其他分支。

---

## 8. 和本系列的关系

- storage 的 Raft：见 [24-raft-replication](24-raft-replication.md)。
- WAL：见 [25-wal-format-and-recovery](25-wal-format-and-recovery.md)。
- RocksDB：见 [26-rocksdb-storage-engine](26-rocksdb-storage-engine.md)。
