# #33 v2 — Backup / Recovery (备份 + 恢复 + PIT 完整实读)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")

> 接续 #22 v2 Clog + #26 v2 Failover:前面讲了 "日志怎么落盘、主备怎么切"。
> 本文聚焦 **"数据丢了怎么救、历史 snapshot 怎么存、PIT 怎么恢复"** ——OB
> 的备份与恢复子系统。这是 OB 容灾链的最后一环。

---

## 0. 全文导读

OB 备份恢复的三层架构:

```
Data Backup   (全量 + 增量 SSTable 快照)
    ↓
Log Archive   (Clog 持续归档到远程存储)
    ↓
Restore       (从 backup + archive log 重建到任意时间点)
```

本文按"架构 → Data Backup → Log Archive → Restore → PIT → 监控调度 →
故障演练"展开。

---

## 1. Backup 架构

### 1.1 三种备份类型

```cpp
// src/share/backup/ob_backup_type.h:50
enum ObBackupType {
  // 1. 全量备份(基线)
  OB_BACKUP_TYPE_FULL,

  // 2. 增量备份(基于上次全量/增量)
  OB_BACKUP_TYPE_INCREMENTAL,

  // 3. 日志备份(Clog 归档)
  OB_BACKUP_TYPE_LOG_ARCHIVE,
};
```

### 1.2 Backup 元数据

```cpp
// src/share/backup/ob_backup_struct.h:100
struct ObBackupSetDesc {
  // 1. 备份集标识
  int64_t backup_set_id_;           // 全局唯一
  int64_t tenant_id_;                // 所属 tenant
  int64_t incarnation_id_;           // tenant 生命周期 ID

  // 2. 备份类型 + 状态
  ObBackupType type_;
  ObBackupStatus status_;            // PENDING / DOING / DONE / FAILED

  // 3. 时间范围
  int64_t start_time_;               // 备份开始时间
  int64_t end_time_;                 // 备份结束时间

  // 4. 数据范围(tenant 全集 / 或指定 partition)
  int64_t start_log_id_;             // 包含的最小 log id
  int64_t end_log_id_;               // 包含的最大 log id

  // 5. 备份路径
  common::ObString backup_path_;     // OSS / S3 / NFS 路径
};
```

### 1.3 备份架构

```
RootService 协调
    ↓
选一个 OBServer 做 backup coordinator
    ↓
Coordinator 调度每个 OBServer 各自备份自己的 partition
    ↓
各 OBServer 把 partition SSTable 上传到 OSS/S3
    ↓
汇总 → 备份完成
```

---

## 2. Data Backup (数据备份)

### 2.1 全量备份流程

```cpp
// src/storage/backup/ob_full_backup.cpp:80
class ObFullBackupExecutor {
public:
  int execute(const ObBackupSetDesc &desc) {
    // 1. freeze(冻结当前 MemTable,等待 minor freeze 完成)
    memtable_.trigger_global_freeze();
    memtable_.wait_freeze_done();
    // 2. 扫所有 SSTable
    for (auto &tablet : tablets_) {
      backup_tablet(tablet, desc);
    }
    // 3. 上传 OSS/S3
    upload_to_remote(desc);
    // 4. 记录 backup 元数据到 __all_backup_set 表
    record_backup_set(desc);
  }

  int backup_tablet(ObTabletHandle &tablet, const ObBackupSetDesc &desc) {
    // 1. 拿 tablet 的 SSTable 列表
    auto sstables = tablet.get_sstables();
    // 2. 对每个 SSTable:压缩 + 加密 + 上传
    for (auto &sst : sstables) {
      ObString compressed = compress(sst);
      ObString encrypted = encrypt(compressed);
      upload_to_remote(desc.backup_path_, encrypted);
    }
  }
};
```

### 2.2 增量备份

```cpp
// src/storage/backup/ob_inc_backup.cpp:50
class ObIncBackupExecutor {
public:
  // 增量:只备份上次 full/inc 之后变化的数据
  int execute(const ObBackupSetDesc &desc) {
    // 1. 找基线备份
    ObBackupSetDesc *baseline = find_baseline();
    // 2. 拿基线之后的 SSTable
    auto new_sstables = get_sstables_after(baseline->end_log_id_);
    // 3. 只上传新 SSTable
    for (auto &sst : new_sstables) {
      upload_to_remote(sst);
    }
  }
};
```

### 2.3 备份压缩 + 加密

```cpp
// src/storage/backup/ob_backup_compress.cpp:50
// 备份压缩:lz4 / zstd (默认 zstd)
int ObBackupCompress::compress_sstable(const ObSSTable &sst) {
  // 1. 读 SSTable 的 raw data
  std::string raw = read_sstable(sst);
  // 2. zstd 压缩(level 3,平衡压缩率/速度)
  std::string compressed = zstd_compress(raw, 3);
  // 3. 写压缩后数据
  return write_to_remote(compressed);
}

// src/storage/backup/ob_backup_encrypt.cpp:50
// 备份加密:AES-256
int ObBackupEncrypt::encrypt_backup(const std::string &data) {
  // 1. 用 KMS 拿数据密钥
  ObString data_key = kms_.get_data_key(tenant_id_);
  // 2. AES-256 加密
  return aes_encrypt(data, data_key);
}
```

### 2.4 并行备份

```cpp
// src/storage/backup/ob_parallel_backup.cpp:80
// 多线程并行备份(每 OBServer 上 N 个 worker)
class ObParallelBackup {
public:
  void run() {
    // 1. 把 tablet 列表分片给 N 个 worker
    auto shards = shard_tablets(tablets_, n_workers_);
    // 2. 每个 worker 并行备份自己的分片
    parallel_for(shards, [&](auto &shard) {
      backup_shard(shard);
    });
  }
};
```

---

## 3. Log Archive (日志归档)

### 3.1 归档目的

Clog 备份——保证从 data backup 时间点 + archive log 可以恢复到任意 PIT。

### 3.2 归档流程

```cpp
// src/storage/clog/ob_clog_archive.cpp:80
class ObClogArchiver {
public:
  // 1. 周期性(每 5s)上传已完成 Clog 文件
  void archive_loop() {
    while (running_) {
      // 1.1 找已完成的 Clog 文件
      auto finished_files = clog_file_mgr_.get_finished_files();
      // 1.2 上传到 OSS/S3
      for (auto &file : finished_files) {
        upload_clog_to_remote(file);
        // 1.3 标记已归档
        archive_meta_.add(file.last_log_id_);
      }
      sleep(5s);
    }
  }
};
```

### 3.3 归档存储格式

```
/backup_root/
  ├── data/
  │     ├── 1/
  │     │     ├── full_backup_20260802_120000.tar.gz
  │     │     └── inc_backup_20260802_130000.tar.gz
  │     └── 2/
  │           └── ...
  └── log/
        ├── clog_1_20260802_120000_125000.7z
        ├── clog_1_20260802_125000_130000.7z
        └── clog_2_20260802_120000_125000.7z
```

---

## 4. Restore (恢复)

### 4.1 恢复流程

```
1. 准备目标集群(空集群,只装了 OB 软件)
2. 选恢复源:backup_set + archive_log + 目标时间点
3. 恢复 data backup → 写入新集群
4. replay archive log → 追到目标时间点
5. 完成
```

### 4.2 Restore 实现

```cpp
// src/storage/backup/ob_restore_executor.cpp:100
class ObRestoreExecutor {
public:
  int execute(const ObRestoreParam &param) {
    // 1. 从 backup_set 拉 SSTable 写入新集群
    restore_data_backup(param.backup_set_, param.target_tenant_);
    // 2. replay archive log 追到 target_time
    replay_logs_to(param.archive_log_, param.target_time_);
    // 3. 校验数据一致性
    verify_consistency();
  }
};
```

### 4.3 PIT (Point-in-Time Recovery)

```cpp
// src/storage/backup/ob_pit_recovery.cpp:50
class ObPitRecovery {
public:
  int recover_to(const int64_t target_time_us) {
    // 1. 找最近的 data backup(before target_time)
    auto backup = find_backup_before(target_time_us);
    // 2. 算需要的 archive log 范围
    int64_t start_log_id = backup.end_log_id_;
    int64_t end_log_id = find_log_at_time(target_time_us);
    // 3. 恢复 data backup
    restore_data_backup(backup);
    // 4. replay [start_log_id, end_log_id] 的 log
    replay_logs(start_log_id, end_log_id);
    // 5. 完成(数据 = target_time 时的状态)
  }
};
```

### 4.4 PIT 的精度

OB 的 PIT 精度 = **单事务粒度** —— 可以恢复到某个具体事务之前或之后的状
态。

```sql
-- 恢复到 2026-08-02 12:00:00
ALTER TENANT tenant1
  RESTORE UNTIL TIME '2026-08-02 12:00:00'
  USING BACKUP SET 1
  FROM 'oss://backup/';
```

---

## 5. Backup 调度

### 5.1 备份策略

```sql
-- 配置 backup 目的地
ALTER SYSTEM SET backup_dest = 'oss://my-bucket/backup';
ALTER SYSTEM SET backup_backup_uri = 'oss://my-bucket';
ALTER SYSTEM SET backup_log_archive_dest = 'oss://my-bucket/log';

-- 启动 archive log
ALTER TENANT tenant1 ENABLE LOG ARCHIVE;

-- 周期性全量备份(每周日)
ALTER SYSTEM SET backup_data_backup_start_time = '00:00:00';

-- 增量备份间隔(每 6 小时)
ALTER SYSTEM SET inc_backup_interval = '6h';
```

### 5.2 自动调度

```cpp
// src/rootserver/ob_backup_scheduler.cpp:80
// RootService 周期性触发备份
class ObBackupScheduler {
public:
  void schedule_loop() {
    while (running_) {
      // 1. 检查是否到了备份时间
      if (need_full_backup_now()) {
        trigger_full_backup();
      } else if (need_inc_backup_now()) {
        trigger_inc_backup();
      }
      // 2. 等下次检查
      sleep(1min);
    }
  }
};
```

### 5.3 备份保留策略

```sql
-- 保留 30 天
ALTER SYSTEM SET backup_recovery_window = '30d';

-- 自动清理过期 backup
ALTER SYSTEM SET backup_delete_policy = 'EXPIRED';
```

---

## 6. Backup 监控

### 6.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_backup_stat\G

-- 关键字段:
-- backup_set_id_: 当前备份集 ID
-- backup_status_: PENDING / DOING / DONE / FAILED
-- backup_size_bytes_: 备份大小
-- backup_speed_bytes_per_sec_: 备份速度
-- estimated_finish_time_: 预计完成时间
-- error_msg_: 错误信息(如果失败)
```

### 6.2 备份状态查询

```sql
-- 查看所有 backup 集
SELECT * FROM oceanbase.__all_virtual_backup_set
ORDER BY start_time_ DESC
LIMIT 10;

-- 关键字段:
-- type_: FULL / INC / LOG_ARCHIVE
-- status_: 当前状态
-- start_log_id_, end_log_id_: 包含的 log 范围
-- backup_path_: 备份文件位置
```

### 6.3 恢复进度

```sql
SELECT * FROM oceanbase.__all_virtual_restore_progress\G

-- 关键字段:
-- restore_status_: 恢复状态
-- restore_progress_: 0-100%
-- current_log_id_: 正在 replay 的 log id
-- estimated_finish_time_: 预计完成时间
```

---

## 7. 备份恢复故障排查

### 7.1 常见故障

#### 故障 1:备份失败

```
现象:backup_status_ = FAILED
常见原因:
  - OSS/S3 配额满
  - 网络不稳定
  - 权限问题

修法:
  - 检查 backup dest 状态
  - 重新启动备份:ALTER SYSTEM START BACKUP;
```

#### 故障 2:恢复慢

```
现象:restore_speed_bytes_per_sec_ < 50MB/s
原因:
  - OSS/S3 带宽限制
  - 备份压缩比低

修法:
  - 升 OSS 带宽
  - 用本地 NFS 替代 OSS
```

#### 7.2 备份验证

```cpp
// src/storage/backup/ob_backup_verify.cpp:50
// 周期性校验 backup 完整性
class ObBackupVerify {
public:
  void verify(const ObBackupSetDesc &desc) {
    // 1. 下载 backup metadata
    auto meta = download_metadata(desc);
    // 2. 对每个文件:download + 校验 checksum
    for (auto &file : meta.files_) {
      auto data = download(file);
      if (checksum(data) != file.checksum_) {
        report_corruption(file);
      }
    }
  }
};
```

### 7.3 Backup 加密密钥管理

```cpp
// src/share/backup/ob_backup_kms.cpp:80
// 备份加密密钥存到外部 KMS(Key Management Service)
class ObBackupKms {
public:
  // 1. 创建 backup 时,从 KMS 拿数据密钥
  ObString get_data_key(uint64_t tenant_id) {
    return kms_.generate_data_key(tenant_id);
  }
  // 2. 加密
  aes_encrypt(backup_data, data_key);
  // 3. 把 data_key 的加密版本存到 backup metadata
  // (用 KMS 主密钥加密 data_key)
};
```

---

## 8. 容灾策略

### 8.1 三级容灾

| 级别 | 恢复方式 | RPO | RTO |
|------|----------|-----|-----|
| **本地 HA** | 主备切换 | 0 | 10s |
| **同城容灾** | 备机房 + 备集群 | 0 (强同步) / 分钟 (异步) | 分钟 |
| **异地容灾** | 异地 OSS/S3 + backup restore | 分钟-小时 | 小时-天 |

### 8.2 同城容灾

```
机房 A (Primary)              机房 B (Standby)
     │                              │
     │ 实时同步 (强同步) ────────►   │
     │                              │
     │ 机房 A 故障                  │
     ↓                              ↓
机房 B 自动提主                  服务恢复
```

### 8.3 异地容灾

```
机房 A (生产)              异地 (OSS/S3 + 备集群)
     │                              │
     │ backup + archive log ──────► │
     │                              │  按需 restore
     │                              │
     │ 机房 A 灾难性故障            │
     ↓                              ↓
异地备份完整                  异地备集群 restore
                              ↓
                          服务恢复
```

---

## 9. 与 Clog / Failover 的关系(接 #22 + #26)

### 9.1 Backup + Clog 的关系

| 备份类型 | 用途 | 频率 |
|----------|------|------|
| **Data Backup** | 全量数据快照 | 每天 / 每周 |
| **Archive Log** | 增量 log 备份 | 持续 |

恢复时:**Data Backup + Archive Log** = PIT。

### 9.2 Backup + Failover 的关系

```
场景:机房 A 整体故障(主 + 备都丢)
  ↓
异地 backup + archive log 可用
  ↓
异地新建集群 + restore
  ↓
服务恢复(RTO 小时-天,RPO < 备份间隔)
```

### 9.3 Backup + Schema 的关系

```cpp
// src/storage/backup/ob_schema_backup.cpp:80
// 备份时也备份 schema(保证 restore 后 schema 一致)
class ObSchemaBackup {
public:
  void backup_schema(const ObBackupSetDesc &desc) {
    // 1. 拿所有 schema 对象
    auto schemas = schema_service_.get_all_schemas();
    // 2. 序列化 + 压缩 + 加密 + 上传
    serialize_to_remote(schemas, desc);
  }
};
```

---

## 10. 性能与代价

### 10.1 备份性能

| 备份类型 | 速度 | 资源占用 |
|----------|------|----------|
| **全量** | 100-500 MB/s | 高(读 SSTable + 上传) |
| **增量** | 50-200 MB/s | 中 |
| **Archive Log** | 10-50 MB/s | 低 |

### 10.2 对生产的影响

OB 备份走**单独 IO 通道**(不影响业务):

```cpp
// src/storage/backup/ob_backup_io.cpp:50
// 备份 IO 限速(避免影响业务)
class ObBackupIO {
public:
  // 限速 200 MB/s
  int64_t rate_limit_bytes_per_sec_ = 200 * 1024 * 1024;
};
```

### 10.3 存储成本

```
全量 1TB 数据 + 压缩比 5x = 200GB 备份
+ 7 天 archive log @ 50MB/s × 86400s = 4.3TB/天 × 7 = 30TB
= 总 30.2TB / 周

OSS 成本:30TB × $0.023/GB/月 = ~$700/月(海外 OSS)
```

---

## 11. 调优 Checklist

```
□ backup dest 是否配置?(OSS/S3/NFS)
□ archive log 是否启用?
□ 备份策略是否合理?(全量周 + 增量天)
□ 备份保留期?(默认 30 天)
□ 备份是否加密?(生产必开)
□ 备份完整性校验是否周期跑?
□ PIT 恢复演练是否周期做?(季度)
□ RTO / RPO SLA 是否达成?
□ 异地容灾是否就绪?
```

---

## 12. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → **#33 v2 (本文)** 是 OB 
**storage / index / CBO / join / cache / 调优 / 日志 / 事务 / schema / 并行
/ HA / 容灾** 全主线:

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
| **#33 v2 (本文)** | **Backup / Recovery** | **容灾层** | **全量+增量+archive log + PIT + 容灾策略** |

十四篇连起来,读者能完整理解 OB 的"内存 → 锁 → 日志 → 磁盘 → cache →
调优 → 元数据 → 并行 → HA → 容灾"全链路:

- 内存数据:#14/#15/#16
- 事务:#11
- 日志:#22
- 索引:#18
- 执行:#17 + #41 + #24
- IO:#51
- 调优:#29
- 元数据:#21
- HA:#26
- 容灾:#33(本文)

---

## 13. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **RPC / 网络层** — obrpc + 跨 OBServer 通信
- **监控 / 告警** — ASH 深入 + metrics 体系(接 #29)
- **资源调度 / Unit / Tenant** — 多租户隔离
- **集群部署 / 运维** — 集群管理
- **#19-#25 / #27-#32 / #34-#100 系列**（待确认具体编号）

继续哪一篇?

---

## 14. 参考(可执行的源码锚点)

- `src/share/backup/ob_backup_type.h` — 备份类型
- `src/share/backup/ob_backup_struct.h` — 备份元数据
- `src/storage/backup/ob_full_backup.cpp` — 全量备份
- `src/storage/backup/ob_inc_backup.cpp` — 增量备份
- `src/storage/backup/ob_backup_compress.cpp` — 备份压缩
- `src/storage/backup/ob_backup_encrypt.cpp` — 备份加密
- `src/storage/backup/ob_parallel_backup.cpp` — 并行备份
- `src/storage/clog/ob_clog_archive.cpp` — Clog 归档
- `src/storage/backup/ob_restore_executor.cpp` — 恢复执行
- `src/storage/backup/ob_pit_recovery.cpp` — PIT 恢复
- `src/rootserver/ob_backup_scheduler.cpp` — 备份调度
- `src/storage/backup/ob_backup_io.cpp` — 备份 IO 限速
- `src/share/backup/ob_backup_kms.cpp` — KMS 密钥管理
- `src/storage/backup/ob_backup_verify.cpp` — 备份校验

---

#33 v2 完。
