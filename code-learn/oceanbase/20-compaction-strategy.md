# #20 v2 — Compaction Strategy (Minor Freeze / Major Freeze / SSTable Merge 完整实读)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")

> 接续 #14 v2 MemTable Internals + #22 v2 Clog / Redo Log + #51 v2 Block Cache:
> 前面讲了 "MemTable 怎么排、Clog 怎么写、cache 怎么管"。本文聚焦 **"MemTable
> 怎么落盘、旧 SSTable 怎么合并、major freeze 怎么触发"** ——OB 的 compaction
> 策略。这是 storage engine 的核心维护机制。

---

## 0. 全文导读

OB 的 compaction 分三类:

```
Minor Freeze    →  MemTable → SSTable (轻量,持续发生)
Major Freeze    →  全集群 SSTable 合并 + 转列存(重量,周期性)
History Merge   →  历史 SSTable 合并(可选,清理无效数据)
```

本文按"架构 → Minor Freeze → Major Freeze → History Merge → 触发策略 →
IO 控制 → 监控调优"展开。

---

## 1. Compaction 整体架构

### 1.1 Storage Engine 三层

```
MemTable (内存,可写)
    ↓ Minor Freeze
SSTable (磁盘,不可变)
    ↓ History Merge / Major Freeze
优化的 SSTable (合并 + 排序 + 压缩 + 转列存)
```

### 1.2 SSTable 类型

```cpp
// src/storage/blocksstable/ob_sstable_type.h:50
enum ObSSTableType {
  // 1. 正常 MemTable flush 出来的 SSTable
  SST_TYPE_NORMAL,

  // 2. Compaction 合并出来的中间 SSTable
  SST_TYPE_COMPACTED,

  // 3. Major Freeze 输出的列存 SSTable
  SST_TYPE_COLUMNAR,
};
```

### 1.3 Tablet 的 SSTable 列表

```
tablet 1 (某表某分区)
  ├── memtable           (活跃)
  ├── sst_0 (微块,正常)    ← 最新 minor freeze
  ├── sst_1 (微块,正常)
  ├── sst_2 (compact 合并)
  └── ... (历史 SSTable)
```

---

## 2. Minor Freeze(MemTable → SSTable)

### 2.1 触发条件

```cpp
// src/storage/memtable/ob_memtable.cpp:200
class ObMemtable {
public:
  // 检查是否需要 freeze
  bool need_freeze() const {
    // 1. 内存占用超阈值(默认 256MB)
    if (mem_used_ >= freeze_threshold_) return true;
    // 2. 时间超阈值(默认 2 分钟)
    if (elapsed_since_freeze_() >= freeze_time_threshold_) return true;
    // 3. 用户显式触发(ALTER SYSTEM MINOR FREEZE)
    return explicit_freeze_requested_;
  }
};
```

### 2.2 Minor Freeze 流程

```cpp
// src/storage/ob_partition_service.cpp:150
int ObPartitionService::minor_freeze(ObTabletHandle &tablet) {
  // 1. 创建新 MemTable(冻结旧 MemTable)
  auto *old_memtable = tablet.memtable_;
  auto *new_memtable = create_new_memtable();
  tablet.memtable_ = new_memtable;
  // 2. 冻结 old MemTable(不能再写,只读)
  old_memtable->freeze();
  // 3. dump 到 SSTable
  auto *sst = dump_to_sstable(old_memtable);
  // 4. 把 SSTable 加入 tablet
  tablet.add_sstable(sst);
  // 5. 释放 old MemTable 内存
  old_memtable->destroy();
  return OB_SUCCESS;
}
```

### 2.3 Dump to SSTable

```cpp
// src/storage/blocksstable/ob_sstable_writer.cpp:80
int ObSSTableWriter::write_sstable(ObMemtable &memtable) {
  // 1. 扫 MemTable 所有 row(按 PK 排序)
  auto rows = memtable.scan_all();
  std::sort(rows.begin(), rows.end(), cmp_by_pk);  // 排序
  // 2. 分 micro_block(每 block ~64KB,256 行)
  std::vector<ObMicroBlock> blocks;
  for (size_t i = 0; i < rows.size(); i += rows_per_block_) {
    ObMicroBlock block;
    block.serialize(rows[i : i + rows_per_block_]);
    blocks.push_back(block);
  }
  // 3. 写 macro_block 头
  ObMacroBlockHeader header;
  header.compress_type_ = COMPRESS_ZSTD;
  header.encrypt_type_ = ENCRYPT_NONE;
  // 4. 顺序写盘
  file_.write(serialize(header));
  for (auto &block : blocks) {
    file_.write(serialize(block));
  }
  // 5. 写 bloom filter + 索引
  write_bloom_filter(blocks);
  write_block_index(blocks);
  return OB_SUCCESS;
}
```

### 2.4 Minor Freeze 期间读写

- **写**: 走新 MemTable(已冻结的旧 MemTable 不接受新写)
- **读**: 旧 MemTable + 新 SSTable(都需要查)

```cpp
// src/storage/ob_storage_read.cpp:300
ObMvccRow *read_row(table_id, key) {
  // 1. 查当前 MemTable
  if (auto *row = memtable_.get(key)) {
    if (is_visible(row)) return row;
  }
  // 2. 查 SSTable
  for (auto *sst : tablet_.sstables_) {
    if (auto *row = sst->binary_search(key)) {
      if (is_visible(row)) return row;
    }
  }
}
```

### 2.5 Minor Freeze 期间事务

```
冻结时点:
  MemTable A (被冻结) ─┐
  MemTable B (新)      ├─ 二者并存
  冻结时正在 commit 的事务:
    - 写在 A 上(可读,不可写)
    - 写在 B 上(正常)
  → 切换无感知,事务层透明
```

---

## 3. Major Freeze

### 3.1 触发条件

```sql
-- 手动触发
ALTER SYSTEM MAJOR FREEZE;
ALTER TENANT tenant1 MAJOR FREEZE;

-- 自动触发(后台线程)
-- 默认:每天一次(凌晨 2 点)
ALTER SYSTEM SET major_freeze_duty_time = '02:00:00';

-- 强制(忽略上层控制)
ALTER SYSTEM FORCE MAJOR FREEZE;
```

### 3.2 Major Freeze 流程

```
1. 所有 tenant 的所有 tablet 触发 minor freeze
2. 等所有 minor freeze 完成
3. 全集群所有 SSTable merge(去重 + 删除)
4. (可选)转列存
5. 更新 meta_version(集群级 schema 升级)
6. 完成
```

### 3.3 Major Freeze 的全流程

```cpp
// src/storage/ob_storage_rpc.cpp:80
// RootService 协调整个集群的 major freeze
class ObMajorFreezeCoordinator {
public:
  int execute() {
    // 1. 升级 schema_version(冻结)
    schema_service_.bump_to_frozen();
    // 2. 所有 OBServer 触发 minor freeze
    broadcast_to_all_servers(OB_MAJOR_FREEZE_MINOR);
    // 3. 等所有 minor 完成
    wait_all_servers_minor_done();
    // 4. 各 OBServer 合并 SSTable(去重)
    parallel_merge_sstables();
    // 5. (可选)转列存
    if (enable_columnar_) {
      convert_to_columnar();
    }
    // 6. 升级 meta_version
    schema_service_.bump_to_post_frozen();
    // 7. 完成
    return OB_SUCCESS;
  }
};
```

### 3.4 转列存(可选)

```cpp
// src/storage/columnar/ob_columnar_store.cpp:50
// 行存 → 列存转换(OLAP 场景)
int convert_to_columnar(ObSSTable &sst) {
  // 1. 读所有 row
  auto rows = sst.scan_all();
  // 2. 按列重新组织
  for (size_t col = 0; col < schema_.columns_.count(); ++col) {
    ObColumnChunk chunk;
    for (auto &row : rows) {
      chunk.append(row[col]);
    }
    // 3. 列级压缩(每列单独压缩,率高)
    chunk.compress();
    // 4. 写列存
    columnar_file_.write(chunk);
  }
}
```

### 3.5 Major Freeze 的代价

| 操作 | 耗时 | IO |
|------|------|-----|
| Minor freeze ×N | 分钟级 | 几十 GB 写 |
| SSTable merge | 小时级(取决于数据量) | 几百 GB 读 + 写 |
| 转列存 | 小时级 | 1TB+ IO |

生产环境 Major Freeze 通常在低峰期(凌晨)做。

---

## 4. History Merge(历史 SSTable 合并)

### 4.1 目的

合并 tablet 内的多个 SSTable,减少 read amplification(读路径要扫的 SSTable
数量)。

### 4.2 触发条件

```cpp
// src/storage/ob_history_merge.cpp:50
class ObHistoryMerger {
public:
  bool should_merge(ObTabletHandle &tablet) {
    // 1. SSTable 数量超阈值(默认 10)
    if (tablet.sstables_.count() > 10) return true;
    // 2. 旧 SSTable 总大小超阈值
    int64_t old_sst_size = 0;
    for (auto *sst : tablet.sstables_) {
      if (sst->age_ > max_age_) {
        old_sst_size += sst->size_;
      }
    }
    if (old_sst_size > merge_size_threshold_) return true;
    return false;
  }
};
```

### 4.3 History Merge 流程

```
Input: tablet 有 10 个 SSTable (sst_0 ~ sst_9)
Process:
  1. 选待合并 SSTable(老 + 小的优先)
  2. 多路归并(merge sort)→ 输出新 SSTable
  3. 写新 SSTable(append-only)
  4. 原子切换(新 SSTable 可见,旧 SSTable 标记删除)
  5. 后台清理旧 SSTable
```

### 4.4 Merge Sort 实现

```cpp
// src/storage/ob_merge_sort.cpp:80
// 多个有序 SSTable → 一个有序新 SSTable
int ObMergeSort::merge(ObSEArray<ObSSTable *> &inputs, ObSSTableWriter &output) {
  // 1. 创建 min-heap(每个 input 一个 entry)
  std::priority_queue<MergeEntry> heap;
  for (auto *sst : inputs) {
    heap.push({sst->first_row(), sst});
  }
  // 2. 多路归并
  while (!heap.empty()) {
    auto entry = heap.top();
    heap.pop();
    // 写当前最小 row 到 output
    output.write(entry.row);
    // 从同一个 SSTable 取下一个 row
    auto *next_row = entry.sst->next_row();
    if (next_row) {
      heap.push({next_row, entry.sst});
    }
  }
  return OB_SUCCESS;
}
```

### 4.5 与 read amplification 的关系

```
合并前:10 个 SSTable → 读每行要扫 10 次
合并后:1 个 SSTable → 读每行扫 1 次

IO 减少 ~10x
```

History Merge 是 **read 性能优化** 的关键。

---

## 5. Merge 期间的并发控制

### 5.1 不阻塞 DML

```cpp
// src/storage/ob_compaction_executor.cpp:80
// Merge 期间,DML 写新 MemTable 和新 SSTable(如果有)
class ObCompactionExecutor {
public:
  int execute() {
    // 1. 标记待合并 SSTable 为"merge 中"
    sst->set_state(SST_STATE_MERGING);
    // 2. 多路归并 → 新 SSTable
    merge_sst();
    // 3. 等所有活跃事务结束(防止读到旧 SSTable)
    wait_active_trans_done();
    // 4. 原子切换
    tablet_.swap_sstable(old_sst_, new_sst_);
    // 5. 标记旧 SSTable 为"待删除"
    old_sst_->set_state(SST_STATE_DELETED);
    return OB_SUCCESS;
  }
};
```

### 5.2 读路径

读路径会查旧 SSTable(合并中)或新 SSTable(合并完成),两边都对:

```
读路径:
  1. 查 MemTable
  2. 查 SSTable list(可能含 merge 中和 merge 后的)
  3. 找到最新可见版本(按 #1-#5 MVCC 判定)
```

### 5.3 失败回滚

```cpp
// src/storage/ob_compaction_executor.cpp:200
// Merge 失败时,清理临时文件,旧 SSTable 保留
void on_merge_failure() {
  // 1. 删除临时 SSTable
  temp_sst_.remove();
  // 2. 旧 SSTable 状态从 MERGING 回到 NORMAL
  for (auto *sst : inputs_) sst->set_state(SST_STATE_NORMAL);
  // 3. 报错给上层
  report_error();
}
```

---

## 6. IO 控制

### 6.1 限速

```cpp
// src/storage/ob_io_throttle.cpp:50
// Compaction 走独立 IO 通道(限速,不影响业务)
class ObCompactionIOThrottle {
public:
  int64_t rate_limit_bytes_per_sec_;  // 默认 100 MB/s
  std::mutex mtx_;
  // 1. 申请 IO 配额
  bool acquire(int64_t bytes) {
    // 令牌桶
    return token_bucket_.try_consume(bytes);
  }
};
```

### 6.2 IO 优先级

```cpp
// src/storage/ob_io_priority.cpp:50
// 不同 IO 类型的优先级
enum ObIoPriority {
  IO_PRIORITY_HIGH,       // 用户查询(高)
  IO_PRIORITY_NORMAL,     // 写入(中)
  IO_PRIORITY_LOW,        // Compaction(低,不抢业务)
};
```

### 6.3 IO 类型

| IO 类型 | 优先级 | 限速 |
|----------|--------|------|
| 用户读 | 高 | 否 |
| MemTable flush | 中 | 是 |
| Compaction | 低 | 是 |
| Backup | 最低 | 是 |

---

## 7. 监控与调优

### 7.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_compaction_stat\G

-- 关键字段:
-- tablet_id_: tablet
-- compaction_type_: MINOR / HISTORY / MAJOR
-- status_: PENDING / RUNNING / DONE / FAILED
-- merged_sstable_count_: 合并 SSTable 数
-- output_sstable_size_: 输出 SSTable 大小
-- elapsed_time_us_: 耗时
-- io_bytes_: IO 量
```

### 7.2 慢 Compaction 排查

```sql
-- 找运行 > 30min 的 compaction
SELECT tablet_id_, compaction_type_, elapsed_time_us_
FROM oceanbase.__all_virtual_compaction_stat
WHERE status_ = 'RUNNING' AND elapsed_time_us_ > 1800000000
ORDER BY elapsed_time_us_ DESC;
```

### 7.3 调优参数

```sql
-- Minor freeze 阈值
ALTER SYSTEM SET minor_freeze_threshold = '300MB';  -- 默认 256MB

-- Major freeze 时间
ALTER SYSTEM SET major_freeze_duty_time = '04:00:00';

-- Compaction 限速
ALTER SYSTEM SET compaction_rate_limit = '200MB/s';

-- History merge 触发阈值
ALTER SYSTEM SET history_merge_threshold = '15';
```

---

## 8. 与 v2 主线的连接

### 8.1 与 MemTable(接 #14)

```
MemTable 接收 INSERT/UPDATE/DELETE(同时写 Clog,接 #22)
    ↓ 满了 OR 时间到
Minor Freeze → dump 到 SSTable
    ↓ SSTable 累积
History Merge → 减少 SSTable 数量
    ↓ 周期 OR 手动
Major Freeze → 全集群 merge + 转列存(可选)
```

### 8.2 与 Block Cache(接 #51)

```cpp
// Compact 完成后,旧 SSTable 的 block cache 要清理
void ObSSTableCompactor::on_compact_done() {
  // 1. 标记旧 SSTable 为删除
  old_sst_->set_state(SST_STATE_DELETED);
  // 2. 通知 block cache 失效
  for (auto &block : old_sst_->micro_blocks_) {
    block_cache_.invalidate(block.cache_key_);
    bloom_cache_.invalidate(block.cache_key_);
  }
}
```

### 8.3 与 Clog(接 #22)

```cpp
// Compaction 不重写 Clog(Clog 保留)
// 旧 SSTable 是 freeze 时的快照 + Clog replay 共同保证一致性
```

### 8.4 与 Trans Service(接 #11)

```
Compaction 期间:
  - 已 commit 的事务:数据正确(在 MemTable 或 SSTable 中)
  - 未 commit 的事务:不影响(它们在 Clog,不在 SSTable)
  - 长事务:可能跨 minor freeze → 用 start_version 判定可见性
```

---

## 9. Compaction 与 IO 性能

### 9.1 IO 模式

```
Minor Freeze: 顺序写(新 SSTable 文件)
History Merge: 顺序读 + 顺序写(归并输出)
Major Freeze: 顺序读 N 个 SSTable + 顺序写 1 个(或 N 个,取决于策略)
```

全部**顺序 IO**,对 SSD 极友好。

### 9.2 写放大

| 操作 | 写放大 |
|------|--------|
| Minor freeze | 1x(直接 dump) |
| History merge | 1x(全部重写) |
| Major freeze | ~1.5x(列存压缩) |

### 9.3 读放大

```
合并前:10 个 SSTable → 读 1 行 = 扫 10 次 binary search
合并后:1 个 SSTable → 读 1 行 = 1 次 binary search

读减少 ~10x
```

---

## 10. 调优 Checklist

```
□ minor freeze 阈值是否合理?(默认 256MB,可调)
□ major freeze 时间是否避开业务高峰?
□ compaction 限速是否够?(避免抢业务 IO)
□ history merge 阈值是否合理?(默认 10)
□ 监控:minor freeze 频率、major freeze 耗时、compaction 队列长度
□ 失败告警:compaction failed → 自动 retry?
□ 磁盘空间是否充足?(每次 compaction 临时用 2x 数据大小)
□ backup 与 compaction 是否错峰?(避免 IO 抢资源)
```

---

## 11. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → #28 v2 → #19 
v2 → **#20 v2 (本文)** 是 OB **storage / index / CBO / join / cache / 调优
/ 日志 / 事务 / schema / 并行 / HA / 容灾 / 多租户 / parser / compaction** 
全主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObKeyBTree | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| #29 v2 | Slow Query | 运维层 | 捕获 + 分析 + 推荐 + 调优 |
| #22 v2 | Clog / Redo Log | 持久化层 | WAL + group commit + replica + recovery |
| #11 v2 | Trans Service / Lock | 事务层 | 全局事务 ID + 行锁 + 2PC + 死锁 + SI |
| #21 v2 | Schema / DDL | 元数据层 | schema_version + INSTANT/INPLACE + Online DDL |
| #24 v2 | PX Framework | 并行层 | Worker Pool + Task 调度 + Data Exchange + DAS |
| #26 v2 | Primary / Standby | HA 层 | Paxos + 选主 + failover + 副本同步 |
| #33 v2 | Backup / Recovery | 容灾层 | 全量+增量+archive log + PIT + 容灾策略 |
| #28 v2 | Resource / Unit / Tenant | 多租户层 | 3 层模型 + 隔离机制 + 资源调度 |
| #19 v2 | SQL Parser | 前端层 | Lexer + Parser + Resolver + Type Check + Fingerprint |
| **#20 v2 (本文)** | **Compaction Strategy** | **存储维护层** | **Minor Freeze + Major Freeze + History Merge** |

十七篇连起来,读者能完整理解 OB 的"数据写入 → 落盘 → 合并 → 老化"全
链路:

- 写入:#14 (MemTable) + #22 (Clog)
- 落盘:#20 (本文:Minor Freeze)
- 合并:#20 (本文:History Merge + Major Freeze)
- 查询:#17 (Optimizer) + #18 (Index) + #41 (Join)
- 缓存:#51 (Block Cache)
- 事务:#11 (Trans Service)
- 元数据:#21 (Schema)
- 多租户:#28 (Tenant/Unit)
- HA:#26 (Failover) + #33 (Backup)

---

## 12. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **RPC / obrpc** — 跨 OBServer 通信(接 #11 2PC + #26 Paxos)
- **Monitoring / Alerting** — ASH 深入 + metrics(接 #29)
- **Partition Management** — rebalance / migration(接 #26)
- **Storage Engine Internals** — SSTable / macro_block / micro_block 深入(接 #51)
- **#25-#40 / #42-#100 系列**（待确认具体编号）

继续哪一篇?

---

## 13. 参考(可执行的源码锚点)

- `src/storage/memtable/ob_memtable.cpp` — MemTable freeze 触发
- `src/storage/ob_partition_service.cpp` — Minor Freeze
- `src/storage/blocksstable/ob_sstable_writer.cpp` — SSTable 写入
- `src/storage/ob_storage_rpc.cpp` — Major Freeze 协调
- `src/storage/columnar/ob_columnar_store.cpp` — 列存转换
- `src/storage/ob_history_merge.cpp` — History Merge
- `src/storage/ob_merge_sort.cpp` — 多路归并
- `src/storage/ob_compaction_executor.cpp` — 合并执行器
- `src/storage/ob_io_throttle.cpp` — IO 限速
- `src/storage/ob_io_priority.cpp` — IO 优先级
- `src/share/backup/ob_compaction_stat.h` — 监控指标

---

#20 v2 完。
