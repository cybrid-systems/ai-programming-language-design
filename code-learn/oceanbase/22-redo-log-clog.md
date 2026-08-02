# #22 v2 — Clog / Redo Log (日志子系统 完整实读)

> 接续 #51 v2 Block Cache + #1-#5 v2 MVCC:前面讲了 "数据怎么放内存 / 怎么
> 走 cache / 怎么排序"。本文聚焦 **"数据怎么保证不丢"** ——OB 的日志子系统
> (Clog)。它是 OB 持久化的核心:**MemTable 里的所有修改,必须先落 Clog,
> 才能 commit**。

---

## 0. 全文导读

Clog 在 OB 里的角色是 **redo log + binlog 合一** —— 提供:

1. **Durability**:事务 commit 前,所有修改必须写到 Clog
2. **Replication**:主备同步通过 Clog 流传输
3. **Recovery**:崩溃后从 Clog 重放恢复
4. **Point-in-time**:Clog 提供事务版本号链,支持历史查询

本文按"架构 → 写路径 → 读路径 → 优化 → 副本同步 → 与 MVCC 的关系"展开。

---

## 1. Clog 架构

### 1.1 三个层次

```
应用层 (SQL: INSERT/UPDATE/DELETE)
    ↓
事务层 (Trans Service: 协调 redo log + MemTable 修改)
    ↓
Clog 层 (Log Writer: 写 log buffer → 刷盘)
    ↓
磁盘 (Clog file, 类似 WAL)
```

### 1.2 Clog 文件结构

```
/data/clog/
  ├── 1.clog        (tenant 1 的日志)
  ├── 2.clog        (tenant 2 的日志)
  └── ...

Clog file layout:
  [file_header: 4KB]
  [log_record_1: variable size]
  [log_record_2]
  ...
  [padding: 填充到 block_size]
```

每个 Clog file 默认 64MB,满了就滚动(roll)。

### 1.3 Log Record 格式

```cpp
// src/storage/clog/ob_clog_record.h:60
struct ObLogRecord {
  // 1. 公共头(16 字节)
  uint64_t log_id_;          // 全局递增 ID
  uint64_t tenant_id_;       // tenant
  uint32_t log_type_;        // 事务日志 / 数据日志 / schema 日志
  uint32_t log_size_;        // 整个 record 大小

  // 2. 事务头(可变)
  uint64_t trans_id_;        // 事务 ID
  int64_t  commit_version_;  // 提交版本号
  // ... (事务 ID + 版本号 + prev_log_id 链)

  // 3. 日志体(可变)
  // INSERT:  encode_row(row_data)
  // UPDATE:  old_row + new_row (for undo)
  // DELETE:  old_row (for undo)
  // DDL:    schema diff
};
```

OB 用 **write-ahead log (WAL)** 模式:MemTable 修改前,先生成 log record。

---

## 2. 写路径:Log Writer

### 2.1 Log Buffer

```cpp
// src/storage/clog/ob_log_writer.h:100
class ObLogWriter {
public:
  // 1. log buffer(内存,默认 4MB)
  char *log_buffer_;
  size_t log_buffer_pos_;
  std::mutex log_buffer_mtx_;

  // 2. flush 线程(异步刷盘)
  std::thread flush_thread_;
};
```

每次事务 commit 时,事务线程把 log record **追加到 log buffer**(O(1) 操作)。
flush 线程周期性把 buffer 写到磁盘。

### 2.2 写路径流程

```cpp
// src/storage/clog/ob_log_writer.cpp:200
int ObLogWriter::write_log(const ObLogRecord &record) {
  // 1. 加锁,加入 log buffer
  std::lock_guard<std::mutex> lock(log_buffer_mtx_);
  memcpy(log_buffer_ + log_buffer_pos_, &record, record.log_size_);
  log_buffer_pos_ += record.log_size_;

  // 2. 如果 buffer 满了,触发 flush
  if (log_buffer_pos_ >= log_buffer_size_) {
    cv_.notify_one();  // 唤醒 flush 线程
  }
  return OB_SUCCESS;
}
```

### 2.3 Flush 线程

```cpp
// src/storage/clog/ob_log_writer.cpp:300
void ObLogWriter::flush_loop() {
  while (running_) {
    // 1. 等 buffer 满 OR 周期性刷盘(每 3ms)
    cv_.wait_for(3ms);
    if (log_buffer_pos_ == 0) continue;

    // 2. 把 buffer 写到磁盘(顺序 IO)
    size_t write_size = log_buffer_pos_;
    file_.write(log_buffer_, write_size);  // O(1) pwrite
    file_.fdatasync();  // 强刷盘

    // 3. 重置 buffer 指针
    log_buffer_pos_ = 0;
  }
}
```

### 2.4 Group Commit(批量提交)

```cpp
// src/storage/clog/ob_log_writer.cpp:400
// 多事务共用一次 fsync,大幅降低磁盘 IO
void ObLogWriter::group_commit() {
  // 1. 等新事务 OR 超时(2ms)
  while (!new_transaction_arrived() && !timeout(2ms));

  // 2. 把 buffer 里所有事务 log 一次性写盘
  size_t batch_size = log_buffer_pos_;
  file_.write(log_buffer_, batch_size);
  file_.fdatasync();

  // 3. 唤醒所有等待的事务
  // (它们可以 commit 了)
}
```

Group commit 是 **OB 写入吞吐的关键优化** —— N 个事务共用一次 fsync,吞吐
量提升 N 倍。

---

## 3. Log Type 分类

OB 的 Clog 不只是 redo log——它**统一了多种日志**:

### 3.1 类型列表

```cpp
// src/storage/clog/ob_log_type.h:50
enum ObLogType {
  OB_LOG_TRANS_START = 1,    // 事务开始
  OB_LOG_TRANS_COMMIT = 2,   // 事务提交(提交版本号)
  OB_LOG_TRANS_ABORT = 3,    // 事务回滚
  OB_LOG_INSERT = 10,         // 插入行
  OB_LOG_UPDATE = 11,         // 更新行
  OB_LOG_DELETE = 12,         // 删除行
  OB_LOG_DDL = 20,            // DDL(schema 变更)
  OB_LOG_SCHEMA_VERSION = 21, // schema 版本号变更
  OB_LOG_HEARTBEAT = 30,      // 备机心跳(主备同步)
  // ...
};
```

### 3.2 各类型的处理

| 类型 | 谁写 | 谁读 |
|------|------|------|
| `OB_LOG_TRANS_*` | 事务层 | Recovery / Replica |
| `OB_LOG_INSERT/UPDATE/DELETE` | MemTable 写路径 | Recovery |
| `OB_LOG_DDL` | Schema Service | 所有 OBServer(刷新本地 schema cache) |
| `OB_LOG_HEARTBEAT` | 主机的 Clog 写入线程 | 备机(确认主备同步) |

> **v2 洞察**:OB 的 Clog 是"中央日志总线"——事务、DDL、副本同步都走同一
> 个 Clog 流。这简化了一致性(单一 sequence),但代价是 Clog 成为热点
> (所有写路径都要穿过它)。

---

## 4. 读路径:Recovery

### 4.1 启动时恢复

```cpp
// src/storage/clog/ob_log_replayer.cpp:100
class ObLogReplayer {
public:
  // 启动时:从 Clog 重放,重建 MemTable
  int replay_from_last_checkpoint() {
    // 1. 找到最近一次 checkpoint 位置
    ObLogLocation cp_loc = find_last_checkpoint();
    // 2. 从 cp_loc 开始顺序读 Clog
    while (OB_SUCC(read_next_record(record))) {
      // 3. 调 redo handler
      switch (record.log_type_) {
        case OB_LOG_INSERT: redo_insert(record); break;
        case OB_LOG_UPDATE: redo_update(record); break;
        case OB_LOG_DELETE: redo_delete(record); break;
        case OB_LOG_DDL:    redo_ddl(record); break;
        // ...
      }
    }
    return OB_SUCCESS;
  }
};
```

### 4.2 Checkpoint

```cpp
// src/storage/clog/ob_checkpoint.cpp:80
// 周期性把 MemTable 状态固化到磁盘(类似 snapshot)
class ObCheckpointer {
public:
  // 1. 周期性(每 60s)刷 MemTable 到 SSTable
  // 2. 记录 checkpoint 位置(最近 flush 到的 log ID)
  int do_checkpoint() {
    int64_t last_flushed_log_id = memtable_.get_last_flushed_log_id();
    save_checkpoint_loc(last_flushed_log_id);
  }
};
```

### 4.3 Recovery 时间估算

```
recovery_time = (current_log_id - checkpoint_log_id) × per_log_record_time
```

OB 的设计目标是 **recovery < 5min**。Checkpoint 越频繁,recovery 越快,但
checkpoint 本身有 IO 开销——**60s checkpoint 是经验平衡点**。

---

## 5. Clog 与 MemTable 的协作:Write Path

### 5.1 事务 Commit 流程

```cpp
// src/storage/transaction/ob_trans_service.cpp:800
int ObTransService::commit_trans(ObTxDesc &tx) {
  // 1. prepare: 收集所有 redo log
  ObLogRecord batch_log;
  batch_log.trans_id_ = tx.trans_id_;
  for (auto &op : tx.operations_) {
    ObLogRecord op_log = op.to_log_record();
    batch_log.append(op_log);
  }
  // 2. write log: 把 batch log 写到 Clog
  clog_writer_.write_log(batch_log);
  // 3. fdatasync: 强刷盘(等 group commit 周期)
  clog_writer_.wait_sync();
  // 4. update MemTable: 把 modified rows 写入 MemTable(带 commit_version)
  for (auto &op : tx.operations_) {
    memtable_.apply(op, tx.commit_version_);
  }
  // 5. 通知 client: commit 成功
  return OB_SUCCESS;
}
```

关键约束:**log 写完才能 apply MemTable**。如果 apply 后崩溃,recovery 时
重放 log,会再次 apply(幂等)。

### 5.2 WAL 保证

```
log 写完 → 任意时刻崩溃 → recovery 时都能 redo 到 commit 状态
```

这叫 **WAL(Write-Ahead Log)**。OB 严格遵守:

1. **log 先写**(必须 fsync 才算完成)
2. **MemTable 后写**(可以延迟,甚至丢失——recovery 会重放)
3. **崩溃后,log 完则数据完**(不丢已 commit 的事务)

---

## 6. 副本同步(主备复制)

### 6.1 同步流程

```
Primary OBServer                    Standby OBServer
     │                                      │
     │  1. commit 事务,写 Clog              │
     │  2. fsync 成功                       │
     │  3. push log 到 Standby ──────────►   │
     │                                      │  4. 写 Standby 的 Clog
     │                                      │  5. apply 到 Standby MemTable
     │  6. ack ──────────────────────────►   │
     │  7. 通知 client: commit 成功          │
```

### 6.2 同步模式

```cpp
// src/storage/clog/ob_clog_sync_mode.h:50
enum ObSyncMode {
  SYNC_MODE_ASYNC,        // 不等备机确认(快,可能丢)
  SYNC_MODE_SYNC,         // 等备机确认(safe,慢)
  SYNC_MODE_MAX_PERFORMANCE, // 自适应(async if lag < 阈值)
};
```

生产环境推荐 **SYNC_MODE_SYNC** 或 **MAX_PERFORMANCE**。

### 6.3 心跳机制

```cpp
// src/storage/clog/ob_clog_heartbeat.cpp:80
// 备机周期性发心跳(确认自己还活着)
class ObClogHeartbeat {
public:
  // 每 1s 发一次心跳
  void send_heartbeat() {
    ObLogRecord hb;
    hb.log_type_ = OB_LOG_HEARTBEAT;
    hb.last_received_log_id_ = last_received_log_id_;
    clog_writer_.write_log(hb);
  }
};
```

主机通过心跳确认备机还活着、心跳包含 "last received log id"——主机知道
备机落后多少。

### 6.4 自动故障切换(Failover)

```cpp
// src/rootserver/ob_rs_ha_service.cpp:100
// 主挂后,RootServer 选新主
int ObHaService::on_primary_failure() {
  // 1. 检测:心跳超时(默认 5s)
  if (primary_heartbeat_timeout()) {
    // 2. 选新主:log id 最接近的备机(数据最新)
    ObServerPtr new_primary = select_new_primary();
    // 3. 提主:新主开始接受写
    promote_to_primary(new_primary);
  }
}
```

OB 的 failover 时间 = **5s 检测 + 几秒提主** ≈ **10s 内恢复**。

---

## 7. Clog 文件管理与归档

### 7.1 文件滚动

```cpp
// src/storage/clog/ob_clog_file_manager.cpp:100
class ObClogFileManager {
public:
  // 单文件达到 64MB,滚到新文件
  void roll_file() {
    // 1. 关闭当前文件
    current_file_.close();
    // 2. 开新文件(下一个序号)
    int fd = open(next_filename(), O_WRONLY | O_CREAT, 0644);
    current_file_ = ObClogFile(fd);
  }
};
```

### 7.2 归档(Archive)

```cpp
// src/storage/backup/ob_clog_archive.cpp:80
// 备份链路:Clog 上传到 OSS/S3
class ObClogArchiver {
public:
  // 周期性归档(每 5s 上传已完成的事务 log)
  int archive_to_remote() {
    ObSEArray<int64_t> archived_log_ids;
    for (auto &clog_file : finished_clog_files_) {
      upload_to_remote(clog_file);
      archived_log_ids.push_back(clog_file.last_log_id_);
    }
  }
};
```

归档目的:
1. 备份恢复(异地容灾)
2. 减少本地存储压力
3. 历史查询(PIT)

### 7.3 清理

```sql
-- 保留最近 7 天 Clog(可配置)
ALTER SYSTEM SET clog_retention_days = 7;
```

---

## 8. 性能优化

### 8.1 写优化

| 优化 | 原理 | 收益 |
|------|------|------|
| **Group Commit** | N 事务共用 1 次 fsync | 写吞吐 Nx |
| **Log Buffer** | 异步刷盘 | 减少 IO 次数 |
| **Direct IO** | 绕过 OS cache | 避免双层 cache |
| **Sequential IO** | Clog 顺序写 | SSD 友好 |
| **Compression** | 压缩 log record | 写 IO 减少 50% |

### 8.2 读优化

| 优化 | 原理 | 收益 |
|------|------|------|
| **Checkpoint** | 周期性 snapshot | Recovery < 5min |
| **Parallel Replay** | 多线程 replay log | Recovery 2-3x |
| **Lazy Apply** | 先 log 后 apply | 启动快 |

### 8.3 Clog 与 MemTable 的并发

```cpp
// src/storage/clog/ob_clog_apply.cpp:50
// Clog apply 是独立线程,不阻塞写路径
class ObClogApplier {
public:
  // 1. 从 Clog reader 拉 log
  // 2. 调用 MemTable apply(异步,不阻塞写)
  // 3. 写 applied 位点(checkpoint 进度)
};
```

写路径:**事务 commit → log 写完 → 返回成功**(不等 MemTable apply)
后台:**apply 线程 → 把 log replay 到 MemTable**(延迟可接受)

---

## 9. 与 MVCC 的关系(接 #1-#5 v2)

### 9.1 log 中的 commit_version

```cpp
// src/storage/clog/ob_clog_record.h:80
// 每个事务 commit 时,Trans Service 分配 commit_version(单调递增)
// 这个 version 写进 log record + MemTable row.mvcc_row

struct ObLogRecord {
  int64_t commit_version_;  // 事务提交版本号
};

struct ObMvccRow {
  int64_t commit_version_;  // 来自 log
  int64_t delete_version_;  // 来自 DELETE log
};
```

### 9.2 读路径结合

```
Query: SELECT * FROM t WHERE pk = X
  ↓
MemTable.get(X) → mvcc_row{commit_version, delete_version, data}
  ↓
is_visible(row, tx.read_version_):
  return commit_version <= read_version
      && delete_version > read_version
```

**version 的来源**:log 里 commit_version → MemTable row.mvcc_row。

### 9.3 Recovery 后的 MVCC 一致性

崩溃恢复时,从 log 重放:
- INSERT log → MemTable 插入 row(带 log 的 commit_version)
- UPDATE log → row.mvcc_row 更新(新 version)
- DELETE log → row.mvcc_row.delete_version 设置

恢复完成后,MemTable 状态和 crash 前**完全一致**(因为 log 是 commit 前写
的)。

---

## 10. 与 SSTable 的关系(接 #51 v2)

### 10.1 MemTable → SSTable 流程

```
1. MemTable 接收 INSERT/UPDATE/DELETE
   (同时写 Clog,带 commit_version)
2. MemTable 满了(默认 256MB),触发 minor freeze
3. MemTable dump 到 SSTable(micro_block)
   - SSTable 每行带 commit_version + delete_version
4. SSTable 进入 Block Cache(接 #51)
5. 旧 MemTable 丢弃
```

### 10.2 Log 残留

```cpp
// Clog 文件保留到 SSTable 持久化 + checkpoint
// 一个 SSTable 持久化后,生成它的 log 才能清理
void ObClogFileManager::purge_old_logs() {
  // 找到最老的、未 checkpoint 的 log
  int64_t oldest_alive_log_id = checkpointer_.get_oldest_log_id();
  // 删除 < oldest_alive_log_id 的文件
  delete_files_older_than(oldest_alive_log_id);
}
```

### 10.3 三层 IO 的协调

```
Clog:   顺序写 (每事务 1 次 fsync)
MemTable: 内存 (无 IO,直到 minor freeze)
SSTable: 顺序写 (minor freeze 时批量写)
```

Clog 是 **实时** 写(每事务),SSTable 是 **批量** 写(minor freeze)。这
种"实时+批量"组合是 OB 的关键架构。

---

## 11. 监控与故障排查

### 11.1 关键指标

```sql
-- Clog 写入延迟
SELECT * FROM oceanbase.__all_virtual_clog_stat\G

-- 关键字段:
-- clog_write_size_per_sec: 每秒写 Clog 字节数
-- clog_write_latency_us: 平均 fsync 延迟
-- clog_pending_count: 待刷盘 log 数(group commit 队列)
-- clog_archived_log_id: 已归档的最新 log id
```

### 11.2 常见故障

#### 故障 1:Clog 写入慢

```
现象:clog_write_latency_us > 1000(1ms)
原因:
  - 磁盘 IO 瓶颈(HDD → SSD)
  - group commit 没生效(检查配置)
  - fsync 太频繁(检查 checkpoint 频率)
修法:
  - 升 SSD
  - 调大 log_buffer_size(4MB → 16MB)
  - 调大 group_commit_timeout(2ms → 5ms)
```

#### 故障 2:主备延迟

```
现象:standby lag > 10s
原因:
  - 网络瓶颈
  - 备机 apply 慢
修法:
  - 升网络带宽
  - 关闭备机的不必要负载
```

#### 故障 3:Recovery 慢

```
现象:启动 > 5min
原因:
  - Clog 太大(几十 GB)
  - 单线程 replay
修法:
  - 加密 checkpoint 频率(60s → 30s)
  - 开 parallel_replay
```

---

## 12. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ **#22 v2 (本文)** 是 OB **storage / index / CBO / join / cache / 调优 /
日志** 主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObMvccHashIndex | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| #29 v2 | Slow Query | 运维层 | 捕获 + 分析 + 推荐 + 调优 |
| **#22 v2 (本文)** | **Clog / Redo Log** | **持久化层** | **WAL + group commit + replica + recovery** |

九篇连起来,读者能完整理解 OB 的"内存 → 日志 → 磁盘 → cache → 调优"全
链路:

- 数据怎么放:#14/#15/#16 (MemTable)
- 数据怎么查:#17/#18 (CBO + Index)
- 数据怎么算:#41 (Join)
- 数据怎么 cache:#51 (Block Cache)
- 数据怎么持久化:#22 (本文 Clog)
- 数据怎么调优:#29 (Slow Query)

---

## 13. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **#19-#21 / #23-#28**（待确认具体编号 — Schema / DDL?）
- **#30-#40**（待确认具体编号 — 日志细节 / Replication?）
- **#42-#50**（待确认具体编号 — PX Framework?）
- **#52-#100**（待确认具体编号 — RPC / 主备 / 备份?）

继续哪一篇?

---

## 14. 参考(可执行的源码锚点)

- `src/storage/clog/ob_clog_record.h` — log record 格式
- `src/storage/clog/ob_log_writer.h` — log writer
- `src/storage/clog/ob_log_writer.cpp` — group commit 实现
- `src/storage/clog/ob_log_replayer.cpp` — recovery
- `src/storage/clog/ob_checkpoint.cpp` — checkpoint
- `src/storage/clog/ob_clog_file_manager.cpp` — 文件管理
- `src/storage/clog/ob_clog_sync_mode.h` — 主备同步模式
- `src/storage/clog/ob_clog_heartbeat.cpp` — 心跳机制
- `src/storage/transaction/ob_trans_service.cpp` — 事务 commit 流程
- `src/rootserver/ob_rs_ha_service.cpp` — failover
- `src/storage/backup/ob_clog_archive.cpp` — 归档
- `src/share/backup/ob_clog_stat.h` — 监控指标

---

#22 v2 完。