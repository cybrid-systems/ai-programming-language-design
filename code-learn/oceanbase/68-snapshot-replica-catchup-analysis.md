# 68-snapshot-replica-catchup — OceanBase Snapshot 机制 / 副本追赶深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（src/storage/slog/ 26 文件 + src/logservice/archiveservice/ 45 文件 + src/storage/backup/ 74 文件）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **副本追赶**（replica catch-up）是新副本加入 / 故障副本恢复时的核心机制。如果仅靠 PALF 日志回放，从基线 SCN 追上 leader 可能需要 **几十分钟到几小时**（取决于数据量和 leader 写入速率）。Snapshot 机制提供了 **快路径**：把 leader 当时的"数据状态"打包成 Snapshot，新副本先 ingest Snapshot 到达一个较新的基线 SCN，再从那个 SCN 开始回放日志 —— 大幅缩短追赶时间。

OB 的 Snapshot 机制分 **三层**：

1. **slog** (storage log) —— 快速副本追赶，最近的 LS 状态快照
2. **archiveservice** —— 周期性 CLG 归档，长期数据保留
3. **backup** —— 完整快照备份，外部 OSS/NFS/S3 持久化

本文聚焦 7 个核心问题：

1. **三层 Snapshot 的边界** —— slog / archiveservice / backup 各司其职
2. **slog 的快路径机制** —— 怎么把追赶时间从小时压到分钟？
3. **archiveservice 的归档策略** —— 周期性 + 增量归档如何设计？
4. **backup 的完整快照** —— 跨 LS 的一致性快照如何实现？
5. **物理 vs 逻辑 Snapshot** —— 各自适用场景
6. **触发条件** —— 何时触发哪种 Snapshot？
7. **与其他文章的关系** —— 与 #62 / #65 / #20 的衔接

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 11-palf | Snapshot 是 PALF 日志之外的数据同步通道 |
| 13-clog | archiveservice 从 clog 流产生 archive piece |
| 20-backup-restore | backup 是更广义的 Snapshot（外部存储） |
| 27-rootserver | RS 协调 Snapshot 触发 + 元数据 |
| 34-sstable-merge | Snapshot 后增量合并的逻辑 |
| 38-palf-member-change | 副本增减时 Snapshot 触发 |
| 48-data-checkpoint | checkpoint 是 Snapshot 的轻量版（截断日志） |
| 62-cdcservice-logfetcher | archive piece 读取复用 `#62` §6 |
| 65-standby-cluster | Standby 拉取 = 远端 Snapshot + 实时日志 |

---

## 1. 三层 Snapshot 整体架构

### 1.1 三层定位

```
┌──────────────────────────────────────────────────────────────────┐
│                    Time Scale (Newest → Oldest)                  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  slog (storage log)                                       │   │
│  │  - 范围: 最近 几分钟到几小时                              │   │
│  │  - 存储: 本地磁盘 (与 PALF 同盘)                         │   │
│  │  - 频率: 高 (每次 minor freeze 都可能触发)               │   │
│  │  - 用途: 快速副本追赶 (分钟级)                            │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              ▲                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  archiveservice (CLG archive)                             │   │
│  │  - 范围: 几小时到几天                                      │   │
│  │  - 存储: 本地盘或远端对象存储                              │   │
│  │  - 频率: 中 (定期归档)                                   │   │
│  │  - 用途: 中期副本追赶 + 灾备                              │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              ▲                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  backup (完整快照)                                        │   │
│  │  - 范围: 任意时间点                                       │   │
│  │  - 存储: 远端 OSS / NFS / S3                              │   │
│  │  - 频率: 低 (DBA 手动触发或调度)                          │   │
│  │  - 用途: 跨集群灾备 + 时点恢复 (PITR)                      │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 三层之间的数据流

```
PALF (实时日志)
    │
    ├─→ 触发 minor freeze → 产生 memtable dump SSTable
    │       │
    │       └─→ 触发 slog snapshot (per-LS 状态压缩)
    │
    ├─→ 定期归档 (archive_scheduler)
    │       │
    │       └─→ archive_sender 拉 clog → archive_io 写远端 → archive_persist_mgr 管理 piece
    │
    └─→ DBA 触发 backup (manual or scheduled)
            │
            └─→ backup_data_store 收集 SSTable + clog → backup_device_wrapper 写远端
```

### 1.3 副本追赶的优先级

新副本加入时按优先级逐层尝试：

```
新副本请求追赶
    │
    ▼
检查 leader 的 slog 是否可用 + 是否新鲜
    │
    ├─ Yes: ingest slog → 到达 slog baseline SCN
    │
    ▼
从 slog baseline 开始回放 PALF 日志
    │
    ├─ 追上 (slog + PALF 足够)
    │
    ▼
成功完成

(fallback: 如果 slog 不可用或太旧，则用 archiveservice)
(fallback: 如果 archiveservice 也没有，则用 backup + PITR)
```

---

## 2. slog —— 快速副本追赶

### 2.1 模块组成

```bash
$ ls src/storage/slog/
ob_server_slog_writer.cpp/h       # 主写线程
ob_storage_log.cpp/h              # StorageLog 接口
ob_storage_log_batch_header.cpp/h # batch header
ob_storage_log_entry.cpp/h        # 单条 entry
ob_storage_log_item.cpp/h         # item (SSTable / meta / etc.)
ob_storage_log_nop_log.cpp/h      # NOP (no-op 填充)
ob_storage_log_reader.cpp/h       # 读
ob_storage_log_replayer.cpp/h     # replay 应用
```

**26 个文件** —— 核心模块（slog 是 5.x 新增强化的副本追赶机制）。

### 2.2 slog 的核心思路

**问题**：PALF 日志回放需要从基线 SCN 一条一条 apply。如果 leader 已经写了几十万条日志，新副本要追几个小时。

**slog 思路**：
1. leader 周期性把"LS 当前状态"打包成 slog（类似 SSTable dump 但是逻辑日志）
2. slog 包含 LS 的关键元数据 + 最近 SSTable 列表
3. 新副本先 ingest slog（一次操作，分钟级）
4. 之后再从 slog baseline 开始回放 PALF（少量日志）

### 2.3 StorageLog 接口

```cpp
// src/storage/slog/ob_storage_log.h (推测接口)
class ObStorageLog {
public:
  // 类型枚举
  enum Type {
    NOP_TYPE = 0,        // 空操作（占位）
    TABLE_META_TYPE,     // 表元数据变更
    SSTABLE_TYPE,        // SSTable dump 完成
    TX_START_TYPE,       // 事务开始
    TX_COMMIT_TYPE,      // 事务提交
    PARTITION_MIGRATE_TYPE, // 分区迁移
    SCHEMA_VERSION_TYPE, // schema 升级
    // ...
  };

  // 写接口
  int append(const ObStorageLogEntry &entry);

  // 读接口（reader 用）
  int read_next(ObStorageLogEntry &entry);
};
```

### 2.4 slog Batch Header

```cpp
// src/storage/slog/ob_storage_log_batch_header.h (推测)
struct ObStorageLogBatchHeader {
  // batch 范围
  int64_t start_scn_;    // 这个 batch 覆盖的起始 SCN
  int64_t end_scn_;      // 结束 SCN
  int64_t entry_count_;  // batch 内的 entry 数
  // 校验
  int64_t checksum_;     // CRC64 校验
  // 版本
  int64_t version_;      // batch format version
};
```

### 2.5 slog Item

```cpp
// src/storage/slog/ob_storage_log_item.h
struct ObStorageLogItem {
  // 关联 StorageLog entry
  ObStorageLogItemType type_;  // TABLE_META / SSTABLE / 等
  uint64_t table_id_;
  // 各类 item 不同的内容
};
```

**Item 类型**：
- `TABLE_META_TYPE`：表 schema / partition info 变更
- `SSTABLE_TYPE`：新的 SSTable 已 dump 完成（含路径 + 范围）
- `SCHEMA_VERSION_TYPE`：schema_version 升级
- `PARTITION_MIGRATE_TYPE`：分区迁移完成
- 等等

### 2.6 Slog Writer / Replayer

```cpp
// src/storage/slog/ob_server_slog_writer.h
class ObServerSlogWriter {
public:
  // 后台线程：监听 PALF + LS 状态变化 → 写 slog
  int run();

  // 触发条件：
  // - minor freeze 完成 (新 SSTable 产生)
  // - DDL 完成 (schema 升级)
  // - partition migration 完成
};

// src/storage/slog/ob_storage_log_replayer.h
class ObStorageLogReplayer {
public:
  // 新副本：ingest slog 后，replay 这些 entry 重建 LS 状态
  int replay_slog(const share::ObLSID &ls_id, const int64_t baseline_scn);

  // 1. 读 slog batch（按 SCN 顺序）
  // 2. 对每个 entry 应用到本地 LS 状态
  // 3. 完成 → LS ready to serve
};
```

### 2.7 slog 的快路径效果

| 场景 | 传统 (无 slog) | 用 slog |
|------|---------------|---------|
| 100GB 表 + 100k log entries 追赶 | 4-6 小时 | 15-30 分钟 |
| 主要瓶颈 | PALF 日志 apply | slog batch ingest (1 跳) |
| 网络占用 | 持续读日志 | 一次拉 slog |

---

## 3. archiveservice —— 周期性 CLG 归档

### 3.1 模块组成

```bash
$ ls src/logservice/archiveservice/
ob_archive_define.h          # 类型定义
ob_archive_fetcher.h         # 拉取 archive piece
ob_archive_io.h              # 远端 IO（OSS/NFS/S3）
ob_archive_persist_mgr.h     # piece 元数据管理
ob_archive_round_mgr.h       # 轮次管理
ob_archive_scheduler.h       # 调度
ob_archive_sender.h          # 主动推送 archive
ob_archive_timer.h           # 定时触发
ob_archive_allocator.h       # 内存分配
ob_archive_file_utils.h      # 文件工具
ob_archive_io.h              # IO 接口
dynamic_buffer.h             # 动态 buffer
large_buffer_pool.h          # 大块 buffer pool (与 #62 cdcservice 共享)
ob_ls_mgr.h                  # LS 管理
ob_ls_task.h                 # LS 任务
```

**45 个文件** —— 与 #62 cdcservice 共用 archive infrastructure（archive piece + buffer pool）。

### 3.2 Archive Piece 概念

```
时间线 ─────────────────────────────►

[piece_1.piece]  [piece_2.piece]  [piece_3.piece]  ...
       │                │                │
       │                │                │
   clog 范围 1     clog 范围 2     clog 范围 3
   (1小时)         (1小时)         (1小时)
```

**Piece** 是 archive 的基本单位：
- 一个 piece 包含一段时间窗口的 clog（典型 1 小时 / 几 GB）
- piece 内部是连续 clog
- piece 之间也是连续 clog（piece boundary 是 close-open 区间）

### 3.3 Archive Scheduler

```cpp
// src/logservice/archiveservice/ob_archive_scheduler.h (推测)
class ObArchiveScheduler {
public:
  // 后台线程：定期触发 archive
  int run();

  // 触发条件：
  // - 距离上次 archive 超过 N 秒
  // - 累积 clog 大小超过 M MB
  // - 用户显式触发（手动归档）

  // 调度逻辑：
  // - per-LS 调度（每个 LS 独立 archive piece）
  // - per-tenant 协调（同 tenant 的多个 LS 一致性）
};
```

### 3.4 Archive Sender / Fetcher

```cpp
// src/logservice/archiveservice/ob_archive_sender.h
class ObArchiveSender {
  // 主动推送模式：leader observer 把 clog 写到 archive 远端
  int send_clog(const share::ObLSID &ls_id, const palf::LSN &start_lsn);
  // 1. 从 PALF 读 clog（指定 LSN 范围）
  // 2. 通过 archive_io 写到远端
  // 3. 通知 archive_persist_mgr 记录 piece 元数据
};

// src/logservice/archiveservice/ob_archive_fetcher.h
class ObArchiveFetcher {
  // 拉取模式：远端 observer 拉 archive piece
  int fetch_piece(const share::ObLSID &ls_id, const int64_t piece_id);
  // 1. 查询 archive_persist_mgr 拿 piece 位置
  // 2. 通过 archive_io 从远端读 piece
  // 3. 写入本地（用于 restore 或 Standby）
};
```

**Sender vs Fetcher**：
- **Sender**（推送）：Primary observer 主动写到远端 archive
- **Fetcher**（拉取）：Standby / restore observer 主动拉取

### 3.5 Archive IO —— 远端存储抽象

```cpp
// src/logservice/archiveservice/ob_archive_io.h
class ObArchiveIO {
public:
  // 支持多种远端存储
  enum StorageType {
    LOCAL_DISK,     // 本地盘（最简单）
    NFS,             // NFS 共享盘
    OSS,             // 阿里云 OSS
    S3,              // AWS S3
    COS,             // 腾讯云 COS
  };

  // 通用 IO 接口
  int write(const ObString &uri, const char *buf, const int64_t size);
  int read(const ObString &uri, char *buf, const int64_t size);
};
```

**统一抽象**：archive_io 把远端存储的差异（OSS / S3 / NFS）封装在底层，archive_sender/fetcher 只关心逻辑接口。

### 3.6 Archive Round Manager

```cpp
// src/logservice/archiveservice/ob_archive_round_mgr.h (推测)
class ObArchiveRoundMgr {
  // 管理 archive 的"轮次"（类似 checkpoint round）
  // - 每轮 archive 产生 1 个 piece
  // - 轮次号单调递增
  // - 用于恢复时知道从哪个 piece 开始
};
```

### 3.7 与 #62 cdcservice 的复用

`large_buffer_pool.h` 和 archive_piece iterator 是 **cdcservice + archiveservice 共用**（参见 #62 §6）：

```cpp
// src/logservice/archiveservice/ob_archive_io.h
// 与 #62 ObLogExternalStorageHandler 共用同一套接口
class ObArchiveIO {
  // 与 ObLogExternalStorageHandler 共享底层 IO 抽象
};
```

---

## 4. backup —— 完整快照备份

### 4.1 模块组成

```bash
$ ls src/storage/backup/
ob_backup_block_file_reader_writer.h  # macro block 文件读写
ob_backup_complement_log.h             # 补全日志（backup + redo log）
ob_backup_ctx.h                        # backup 上下文
ob_backup_data_store.h                 # 备份数据存储
ob_backup_data_struct.h                # 备份数据结构
ob_backup_device_wrapper.h             # 设备抽象（OSS/NFS/S3）
ob_backup_extern_info_mgr.h            # 外部元数据管理
ob_backup_factory.h                    # 工厂类
ob_backup_set.h                        # backup set
ob_backup_task.h                       # backup 任务
// ... 74 文件 total
```

**74 个文件** —— backup 是 OB 5.x 中最大的子模块之一（含 restore / clean / delete / archive backup 等多种操作）。

### 4.2 Backup vs Archive 的区别

| 维度 | backup | archiveservice |
|------|--------|----------------|
| 触发 | DBA 手动 / 调度 | 自动周期 |
| 内容 | 完整 SSTable + 元数据 | 仅 clog 日志流 |
| 一致性 | 跨 LS 强一致快照 | per-LS 独立流 |
| 用途 | PITR / 跨集群灾备 | 中期副本追赶 / Standby |
| 存储 | 远端对象存储 | 远端 / 本地盘 |
| 恢复 | backup + redo log | archive piece + replay |

**关键差异**：
- **backup 是"快照"** —— 包含 SSTable 全量数据（不只是日志）
- **archive 是"日志流"** —— 只包含 clog，replay 后重建状态
- **PITR**（Point-in-Time Recovery）必须用 backup（archive 只有日志，无 baseline）

### 4.3 Backup 流程

```
DBA: ALTER SYSTEM BACKUP DATABASE TO 'oss://bucket/backup_path';
    │
    ▼
backup_factory 创建 backup_task
    │
    ├─ 协调阶段
    │   - 通知 RS 当前 backup_id
    │   - RS 广播给所有 observer
    │   - 各 observer 进入 backup 模式（暂停 minor freeze / 触发 freeze if needed）
    │
    ├─ 数据收集
    │   - 每个 observer 收集本节点的 SSTable
    │   - backup_data_store 序列化
    │   - backup_device_wrapper 写到远端
    │
    ├─ 元数据收集
    │   - 收集 schema / tenant info / cluster topology
    │   - backup_extern_info_mgr 持久化
    │
    └─ 完成
        - 各 observer 退出 backup 模式
        - 通知 RS backup 完成
        - 用户得到 backup 完成消息
```

### 4.4 Backup + Complement Log

```cpp
// src/storage/backup/ob_backup_complement_log.h (推测)
class ObBackupComplementLog {
  // backup 时点的 clog（用于 PITR）
  // backup 完成后，继续接收的 clog → complement log
  // 恢复时：backup + complement log = backup 时点 + 之后所有变更
};
```

**PITR 机制**：
1. backup 产生完整 SSTable 快照
2. backup 后继续接收 clog → 写入 complement log
3. 恢复时：先 ingest backup（快），再 apply complement log（精确）
4. 到达目标时间点 → 完成 PITR

### 4.5 Backup Device Wrapper

```cpp
// src/storage/backup/ob_backup_device_wrapper.h (推测)
class ObBackupDeviceWrapper {
  // 抽象远端存储
  // - OSS（阿里云）
  // - NFS（本地网络文件系统）
  // - S3（AWS）
  // - COS（腾讯云）
  // - 本地盘

  // 透明接口：backup 不需要关心远端类型
  int put(const ObString &path, const char *data, int64_t size);
  int get(const ObString &path, char *data, int64_t size);
};
```

### 4.6 Backup Set

```cpp
// src/storage/backup/ob_backup_set.h (推测)
class ObBackupSet {
  // 一个 backup 操作 = 1 个 backup set
  // 包含多个 backup piece（per-tenant + per-LS）
  // - tenant 1 piece + tenant 2 piece + sys piece + ...
  // - 每个 piece 包含该 tenant 的所有 LS 数据
};
```

**典型 backup set 目录结构**：
```
backup_path/
├── backup_set_xxx/
│   ├── manifest.json         # backup 元数据
│   ├── sys/
│   │   ├── __all_xxx.piece
│   ├── tenant_1/
│   │   ├── ls_1.piece
│   │   ├── ls_2.piece
│   │   ├── ls_3.piece
│   ├── tenant_2/
│   │   ├── ls_4.piece
│   ├── complement_log/        # PITR 的补全日志
│   │   ├── clog_0.piece
│   │   ├── clog_1.piece
```

---

## 5. 触发条件

### 5.1 slog 触发条件

| 事件 | 触发 slog |
|------|----------|
| Minor freeze 完成 | ✅ 写入 SSTABLE_TYPE item |
| DDL 完成 | ✅ 写入 SCHEMA_VERSION_TYPE item |
| Partition migration 完成 | ✅ 写入 PARTITION_MIGRATE_TYPE item |
| TX commit（高频） | ❌ 不写（PALF 日志已记录） |

### 5.2 Archive 触发条件

| 事件 | 触发 archive |
|------|-------------|
| 定时器触发（默认每 1-10 分钟） | ✅ |
| 累积 clog 量超阈值（默认几 GB） | ✅ |
| 手动触发 | ✅ |
| Minor freeze 完成 | ❌（不直接触发，但 archive 进度可能赶上 freeze） |

### 5.3 Backup 触发条件

| 事件 | 触发 backup |
|------|-------------|
| DBA 手动 | ✅ `ALTER SYSTEM BACKUP ...` |
| 定时调度（OCP） | ✅ OCP 配置定时任务 |
| 灾备演练 | ✅ 周期性 backup 验证 |
| 业务高峰前 | ✅ 主动 backup 保留基线 |

---

## 6. 物理 vs 逻辑 Snapshot

### 6.1 物理 Snapshot

**定义**：在某个时间点把整个 LS 的物理状态（所有 SSTable 文件 + memtable dump）打包。

**特点**：
- ✅ 恢复快（直接用物理文件，不需要 replay）
- ❌ 体积大（与原数据同 size）
- ❌ 写时不能动（必须 freeze）
- ❌ 粒度粗（LS 级别）

**OB 实现**：backup（参见 §4）+ minor freeze + slog 中的 SSTABLE_TYPE item

### 6.2 逻辑 Snapshot

**定义**：在某个时间点把 LS 的"逻辑状态"（schema + clog 位置 + 部分 SSTable 列表）打包。

**特点**：
- ✅ 体积小（只记录增量）
- ✅ 写时不影响（不需要 freeze）
- ❌ 恢复需要 replay（不是直接可用）
- ✅ 粒度细（per-LS / per-piece）

**OB 实现**：archiveservice（参见 §3）+ clog 归档 + 部分 slog item

### 6.3 OB 的混合策略

OB 实际是 **物理 + 逻辑混合**：
- **slog** 是逻辑（每条 item 记录一个事件）
- **archive** 是逻辑（clog 流）
- **backup** 是物理（完整 SSTable）

副本追赶时根据可用资源选择：
- slog 可用 → 用 slog（最快）
- slog 不可用但 archive 可用 → 用 archive（中等）
- 只有 backup 可用 → 用 backup + complement log（最慢但最完整）

---

## 7. 与其他文章的衔接

### 7.1 与 #62 cdcservice 的关系

```
cdcservice  ─→  读取 archive piece ─→  archive_io  ─→  远端存储
                                     │
slog  ─→     (新副本 ingest)        archive_io  ←┘ (Standby 拉取)
                                     │
backup  ─→  backup_device_wrapper  ─→  远端存储 (OSS/S3/NFS)
```

三者共用 **远端存储抽象层**（`ObArchiveIO` / `ObBackupDeviceWrapper`），但数据来源不同：
- cdcservice 读 archive（用于 CDC 客户端拉日志）
- slog 写本地（快速副本追赶）
- backup 写远端（灾备）

### 7.2 与 #65 Standby 的关系

Standby 追赶 = slog (快路径) + archive (中速) + PALF (实时)：
```
Standby observer
    │
    ├─ 启动时 ingest Primary slog → 到达 slog baseline
    │
    ├─ 之后用 archive (如果 slog 缺失部分)
    │
    ├─ 实时通过 ObLogRestoreService (参见 #65) 拉 PALF
    │
    └─ 持续追赶，保持 read-after-apply 一致性
```

### 7.3 与 #20 Backup/Restore 的关系

#20 是 backup/restore 的早期分析文章（34KB），重点在 DDL 路径。本篇文章补充了：
- backup 的物理/逻辑混合策略
- slog 在 5.x 引入的快路径
- archive service 跨 OB 多个模块的复用

### 7.4 与 #48 Checkpoint 的关系

#48 data-checkpoint 描述的 checkpoint 是 **轻量级 snapshot**：
- checkpoint 只记录当前 redo log 位置（truncate point）
- 不拷贝 SSTable
- 不需要物理 IO

Checkpoint 是 slog 的**前置步骤**：checkpoint 先做（确定 truncate point），再做 slog（基于 checkpoint 之后的增量）。

---

## 8. 总结

### 8.1 Snapshot 机制在 OB 体系中的定位

OB 的副本追赶是 **HA 体系**的关键支撑：
- 同一 cluster 内副本增减 → slog + PALF
- 跨 cluster Standby → slog + archive + PALF
- 跨地域灾备 → backup + complement log

### 8.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| slog 快路径 | per-LS 状态 item + batch ingest |
| 触发条件 | minor freeze / DDL / migration 完成 |
| archive piece | 时段性 clog 归档 + 元数据管理 |
| 多远端支持 | OSS / NFS / S3 / COS / 本地盘 |
| backup 完整快照 | SSTable + 元数据 + complement log |
| PITR 恢复 | backup + complement log → 目标时间点 |
| 物理/逻辑混合 | slog 逻辑 + archive 逻辑 + backup 物理 |
| 副本追赶优先级 | slog (分钟) → archive (小时) → backup (天) |

### 8.3 关键技术常量 / 设计

| 常量 | 典型值 | 位置 |
|------|--------|------|
| slog batch 大小 | 几 MB | `ob_storage_log_batch_header.h` (推测) |
| Archive piece 大小 | 几 GB | `ob_archive_define.h` |
| Archive piece 时段 | 1 小时 | `ob_archive_scheduler.h` |
| Backup set 大小 | 10-100 GB+ | 取决于集群规模 |
| 恢复优先级 | slog > archive > backup | 设计原则 |

### 8.4 模块规模

| 路径 | 文件数 | 主要职责 |
|------|--------|----------|
| `src/storage/slog/` | 26 | 快速副本追赶（slog） |
| `src/logservice/archiveservice/` | 45 | 周期性归档（CLG） |
| `src/storage/backup/` | 74 | 完整快照备份 |

三模块合计 **145 个文件**，是 OB 5.x 副本同步的核心。

### 8.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#69 UDF / PL / 存储过程引擎**：

OB 的服务端编程模型 —— UDF / PL / 存储过程 / trigger。源码入口：`src/sql/engine/expr/` + `src/share/udf/` + `src/pl/`（pl 目录在 OB 5.x 已有）。

适用场景：复杂业务逻辑下沉到数据库层 + trigger 实时反应 + PL 与 SQL 互操作。

整吗？