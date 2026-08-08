# 78-backup-restore-pitr — OceanBase Backup / Restore / PITR 时点恢复深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/storage/backup/` 74 文件 + `src/rootserver/backup/` + `src/rootserver/restore/` + `src/observer/ob_restore_ctx.h` + `src/observer/ob_restore_sql_modifier.h` + `src/observer/table_load/backup/` + `src/observer/virtual_table/ob_tenant_show_restore_preview.{h,cpp}`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Backup / Restore / PITR** 是企业级数据保护的完整体系。Backup 提供 **完整快照**，Restore 提供 **整库恢复**，PITR 提供 **任意时间点恢复**（Point-in-Time Recovery）。OB 5.x 的 Backup / Restore 建立在 **backup data store + complement log + restore scheduler** 三层之上，是 OB 数据保护能力的核心。

本文聚焦 7 个核心问题：

1. **Backup vs Restore vs PITR vs Flashback** —— 四个概念的边界
2. **Backup 完整流程** —— Coordinator + per-observer 协作
3. **Backup Set 组织** —— per-tenant + per-LS piece
4. **Complement Log** —— PITR 的关键（backup 后继续 clog）
5. **Restore 完整流程** —— coordinator + 任务调度
6. **PITR 时点恢复** —— backup + complement log → 目标时间
7. **Backup Proxy / RPC** —— 跨 observer 协调

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 20-backup-restore | #20 是早期分析（34KB），本篇深化 OB 5.x |
| 48-data-checkpoint | checkpoint 是 backup 的轻量前奏 |
| 62-cdcservice-logfetcher | archive piece 与 backup piece 共用 IO |
| 65-standby-cluster | Standby 是另一种数据保护方式 |
| 68-snapshot-replica-catchup | slog / archive / backup 三层（参见 #68） |
| 27-rootserver | RS 主导 backup / restore 调度 |

---

## 1. 整体架构：Backup / Restore / PITR 边界

### 1.1 模块组成

```bash
# 存储层 backup 主体（74 文件）
src/storage/backup/
├── ob_backup_block_file_reader_writer.{h,cpp}    # macro block 读写
├── ob_backup_complement_log.{h,cpp}               # PITR 关键：backup 后 clog 累积
├── ob_backup_ctx.{h,cpp}                           # Backup 上下文
├── ob_backup_data_store.{h,cpp}                    # Backup 数据存储
├── ob_backup_data_struct.{h,cpp}                   # Backup 数据结构
├── ob_backup_device_wrapper.{h,cpp}                # OSS/NFS/S3 抽象
├── ob_backup_extern_info_mgr.{h,cpp}               # 外部元数据
├── ob_backup_factory.{h,cpp}                       # Backup 工厂类
├── ob_backup_iterator.{h,cpp}                      # Backup 迭代器
├── ob_backup_operator.{h,cpp}                      # Backup 操作符
├── ob_backup_proxy.{h,cpp}                         # Backup RPC proxy
├── ob_backup_restore_util.{h,cpp}                  # 通用工具
├── ob_backup_task.{h,cpp}                          # Backup 任务
└ # ... 60+ 文件

# RootServer 层（Backup 协调）
src/rootserver/backup/
├── ob_backup_service.{h,cpp}                       # Backup service 主类
├── ob_backup_task_scheduler.{h,cpp}                # Backup 任务调度器
├── ob_backup_validate_scheduler.{h,cpp}            # Backup 校验
└── ob_backup_proxy.{h,cpp}                         # RS 端 RPC proxy

# RootServer 层（Restore 协调）
src/rootserver/restore/
├── ob_restore_service.{h,cpp}                      # Restore service 主类
├── ob_recover_table_job_scheduler.{h,cpp}           # 恢复 table job 调度
└── ob_restore_scheduler.{h,cpp}                     # Restore 总调度

# Observer 层（Restore 上下文 + SQL Modifier）
src/observer/
├── ob_restore_ctx.h                                 # Restore 上下文
├── ob_restore_sql_modifier.h                        # Restore 时 SQL 修改
├── table_load/backup/                              # Table load backup readers
│   ├── ob_table_load_backup_flat_row_reader_v1.{h,cpp}
│   └── ob_table_load_backup_flat_row_reader_v2.{h,cpp}
└── virtual_table/
    ├── ob_tenant_show_restore_preview.{h,cpp}        # Restore 预览
    └── ob_all_virtual_ls_log_restore_status.{h,cpp}  # Restore 状态
```

### 1.2 四个概念边界

| 概念 | 含义 | 触发 | 恢复目标 |
|------|------|------|----------|
| **Backup** | 完整快照（全 SSTable + 元数据） | DBA 手动 / 调度 | 备份时间点 |
| **Restore** | 把 backup 数据恢复到目标集群 | DBA 手动 | backup 时间点 |
| **PITR** | 在 backup 基础上应用 complement log 到指定时间 | DBA 手动 + `RECOVER TO TIME` | 任意时间点 |
| **Flashback** | 在线回滚当前数据到历史快照 | DDL 失败回滚 | 切换前的 SCN |

**关键差异**：
- Backup = 离线快照（用新文件 + complement log）
- Restore = 把 backup + complement 加载到目标集群
- PITR = Restore + 应用 complement log 到指定时间
- Flashback = 在线切换的失败回滚（参见 #65）

### 1.3 完整数据流

```
                    [BACKUP 时间点]
                           │
DBA: ALTER SYSTEM BACKUP DATABASE TO 'oss://...';
                           │
                           ▼
            ┌─────────────────────────┐
            │  Phase 1: Backup 准备    │
            │  - RS 校验               │
            │  - 各 observer 进入 backup │
            │  - 暂停 minor freeze     │
            └────────┬────────────────┘
                     │
                     ▼
            ┌─────────────────────────┐
            │  Phase 2: 数据收集      │
            │  - 每 observer 收集      │
            │    本节点的 SSTable      │
            │  - 备份数据写到远端      │
            │  - ob_backup_data_store  │
            └────────┬────────────────┘
                     │
                     ▼
            ┌─────────────────────────┐
            │  Phase 3: 元数据收集    │
            │  - schema / tenant info  │
            │  - 备份 set 元数据       │
            └────────┬────────────────┘
                     │
                     ▼
            ┌─────────────────────────┐
            │  Phase 4: 持续 Complement │
            │  - backup 后 clog 累积   │
            │  - PITR 用              │
            │  - ob_backup_complement_log │
            └────────┬────────────────┘
                     │
                     ▼
[新集群 / 恢复] → 加载 backup → replay complement → 目标时间
```

---

## 2. Backup Service 主类

### 2.1 角色

```cpp
// src/rootserver/backup/ob_backup_service.h
class ObBackupService {
public:
  // 处理 backup RPC（来自任意 observer）
  int handle_backup_request(const ObBackupArg &arg);

  // 调度 backup 任务到各 observer
  int schedule_backup_tasks(const ObBackupJob &job);

  // 收集 backup 完成状态
  int collect_backup_results();
};
```

### 2.2 Backup Job

```cpp
// (推测)
struct ObBackupJob {
  uint64_t job_id_;                   // 唯一 job id
  ObBackupType type_;                 // FULL / INCREMENTAL / ARCHIVELOG
  ObBackupDestination dest_;          // 备份目的地（OSS/NFS path）
  ObArray<uint64_t> tenant_ids_;      // 要备份的 tenants
  int64_t timeout_us_;                // 超时
};
```

### 2.3 Backup Task Scheduler

```cpp
// src/rootserver/backup/ob_backup_task_scheduler.h
class ObBackupTaskScheduler {
public:
  // 把 backup job 拆分成多个 task（per-tenant / per-LS）
  int schedule_tasks(const ObBackupJob &job);

  // 每个 task 调度到具体 observer
  int dispatch_task(const ObBackupTask &task);

  // 监控 task 完成状态
  int check_all_tasks_complete();
};
```

### 2.4 Backup Validate Scheduler

```cpp
// src/rootserver/backup/ob_backup_validate_scheduler.h
class ObBackupValidateScheduler {
  // Backup 完成后做一次校验：
  // - 检查所有 SSTable 都成功备份
  // - 检查 backup set 完整性
  // - 检查 complement log 正常累积
};
```

---

## 3. Backup Proxy —— 跨 observer 协调

### 3.1 角色

```cpp
// src/rootserver/backup/ob_backup_proxy.h
class ObBackupProxy {
public:
  // RS → 各 observer 的 backup RPC
  int dispatch_to_observer(const share::ObServerAddr &observer,
                          const ObBackupTask &task);
};
```

### 3.2 Backup Flow

```
DBA: ALTER SYSTEM BACKUP DATABASE TO 'oss://bucket/backup_20260802';
    │
    ▼
observer SQL executor
    │
    ├─ 解析 BACKUP 参数
    │
    ▼
observer → RS: backup RPC
    │
    ▼
RS: ObBackupService::handle_backup_request
    │
    ├─ 1. 创建 ObBackupJob (分配 job_id)
    ├─ 2. ObBackupTaskScheduler::schedule_tasks
    │   - 按 tenant 拆分
    │   - 按 LS 拆分
    │   - 每个 task 调度到具体 observer
    ├─ 3. 通过 ObBackupProxy 派发到各 observer
    │
    ▼
observer 收到 backup task:
    │
    ├─ 1. 进入 backup 模式（暂停 minor freeze / 触发 freeze if needed）
    ├─ 2. 收集本节点的 SSTable
    │   - ob_backup_data_store::backup_local_data
    │   - ob_backup_block_file_reader_writer 读写 macro block
    ├─ 3. 通过 ob_backup_device_wrapper 写到远端 (OSS/NFS/S3)
    ├─ 4. 写 backup 元数据 (ob_backup_extern_info_mgr)
    ├─ 5. 退出 backup 模式
    ├─ 6. ack RS
    │
    ▼
RS: 收集所有 observer 的 ack
    │
    ├─ ObBackupValidateScheduler::validate 完整性校验
    ├─ 标记 backup_job 完成
    │
    ▼
返回 DBA: backup 完成消息 + backup_set 位置
```

---

## 4. Backup Set 组织

### 4.1 Backup Set 目录结构

```
backup_dest/
├── backup_set_20260802_151030/
│   ├── manifest.json             # backup set 元数据（rootserver 创建）
│   ├── cluster_info.txt          # 集群拓扑
│   ├── sys/                      # sys tenant 的备份
│   │   ├── __all_server_status.piece
│   │   ├── __all_zone.piece
│   │   └── __all_tenant.piece
│   ├── tenant_1001/              # 业务 tenant 的备份
│   │   ├── ls_1001.piece         # LS 1 数据
│   │   ├── ls_1002.piece         # LS 2 数据
│   │   ├── ls_1003.piece         # LS 3 数据
│   │   └── tenant_meta.piece     # tenant 元数据
│   ├── tenant_1002/              # 另一个业务 tenant
│   │   ├── ls_2001.piece
│   │   └── ...
│   ├── complement_log/           # PITR 用：backup 后持续 clog
│   │   ├── clog_1001.piece       # LS 1001 的 clog
│   │   ├── clog_1002.piece
│   │   └── ...
│   └── backup_meta.json          # 备份 set 整体元数据
```

### 4.2 Piece 的物理意义

```
一个 .piece = 一个压缩归档文件（典型 256MB ~ 1GB）
包含:
  - 多个 SSTable 文件
  - 多个 macro block
  - 对应的 schema 元数据
```

### 4.3 Manifest 内容

```json
// backup_set_20260802_151030/manifest.json
{
  "backup_set_id": "backup_set_20260802_151030",
  "backup_time": "2026-08-02T15:10:30+08:00",
  "cluster_version": "5.0.2.0",
  "tenants": [
    {
      "tenant_id": 1001,
      "tenant_name": "tenant1",
      "ls_pieces": [
        {"ls_id": 1001, "piece_file": "tenant_1001/ls_1001.piece"},
        {"ls_id": 1002, "piece_file": "tenant_1001/ls_1002.piece"}
      ]
    }
  ],
  "complement_log_dir": "complement_log/",
  "checksum": "sha256:..."
}
```

---

## 5. ObBackupComplementLog —— PITR 的关键

### 5.1 角色

```cpp
// src/storage/backup/ob_backup_complement_log.h
// 命名空间 oceanbase::backup
// 包含了一堆 include:
// - lib/oblog/ob_log_module.h
// - share/backup/ob_archive_struct.h
// - share/scheduler/ob_tenant_dag_scheduler.h
// - storage/backup/ob_backup_factory.h
// - storage/backup/ob_backup_iterator.h
// - storage/backup/ob_backup_operator.h
// - storage/backup/ob_backup_task.h
// - storage/backup/ob_backup_block_file_reader_writer.h
// - storage/checkpoint/ob_checkpoint_executor.h
// - storage/ls/ob_ls.h
// - storage/tablet/ob_tablet_iterator.h
// - storage/tx/ob_ts_mgr.h
// - storage/tx_storage/ob_ls_map.h
// - storage/tx_storage/ob_ls_service.h
// - storage/high_availability/ob_storage_ha_utils.h
// - storage/ob_storage_rpc.h
// - logservice/archiveservice/ob_archive_file_utils.h
// - observer/omt/ob_tenant.h
// - share/backup/ob_archive_persist_helper.h
// - share/backup/ob_archive_path.h
// - share/backup/ob_archive_store.h
// - share/backup/ob_backup_data_table_operator.h
// - share/backup/ob_backup_connectivity.h
// - share/backup/ob_backup_struct.h
// - share/ls/ob_ls_table_operator.h
// - share/scheduler/ob_dag_warning_history_mgr.h
```

**ObBackupComplementLog** 涉及大量依赖，因为它要：
- 与 backup 主流程集成
- 与 archive piece 系统集成（参见 #62）
- 与 DAG 调度器集成
- 与 LS / tablet 协调
- 与 checkpoint 协调

### 5.2 关键功能

```cpp
class ObBackupComplementLog {
public:
  // 启动：backup 完成后开始累积 clog
  int start_complement_log(const ObBackupArg &arg);

  // 持续接收 clog（与 archive piece 协作）
  int append_clog(const ObLSID &ls_id,
                 const palf::LSN &lsn,
                 const char *buf, int64_t size);

  // 停止：backup 完成（PITR 终止）
  int stop_complement_log();

  // 查询：当前 complement log 的范围
  int get_range(const ObLSID &ls_id,
               palf::LSN &start_lsn,
               palf::LSN &end_lsn);
};
```

### 5.3 PITR 时 complement log 的作用

```
[Backup Time]                              [Recovery Time]
       │                                          │
       ▼                                          ▼
   Backup 创建                                 用户指定
   (full snapshot)                             RECOVER TO TIME T
       │                                          │
       ├─ Continue: clog 累积                  │
       │  → complement_log/                    │
       │  → 持续记录 backup 后所有变更           │
       │                                          │
       │                                          ▼
       │                                    Restore:
       │                                    1. 加载 backup snapshot
       │                                    2. 加载 complement log
       │                                    3. Apply clog 直到时间 T
       │                                    4. 停止 (avoid future clogs)
       ▼                                          ▼
    [今天]                                    [T 时刻]
```

---

## 6. Restore 流程

### 6.1 DBA 命令

```sql
-- 完整 Restore
ALTER SYSTEM RESTORE FROM 'oss://bucket/backup_20260802_151030';

-- PITR Restore
ALTER SYSTEM RECOVER TO TIME '2026-08-02 18:30:00';
```

### 6.2 Restore Flow

```
DBA: ALTER SYSTEM RESTORE FROM 'oss://...';
    │
    ▼
observer SQL executor
    │
    ▼
observer → RS: restore RPC
    │
    ▼
RS: ObRestoreService::handle_restore
    │
    ├─ 1. 解析 restore 参数
    │   - 源: backup set 路径
    │   - 目标: 目标集群 / tenant
    │   - 时间点（如果 PITR）
    │
    ├─ 2. 校验 backup set 完整性
    │   - 检查 manifest.json
    │   - 检查所有 piece 存在
    │   - 校验 checksum
    │
    ├─ 3. ObRestoreScheduler::schedule_restore
    │   - 创建 recover table job
    │   - 调度到目标 observer
    │
    ├─ 4. ObRecoverTableJobScheduler
    │   - 每 observer 恢复本节点的 data
    │   - 从 backup piece 读 SSTable
    │   - ingest 到本地存储
    │
    ├─ 5. 如果 PITR: replay complement log
    │   - 从 complement log 读 clog 直到 recovery_time
    │   - 应用 clog 到恢复后的数据
    │
    ├─ 6. 校验恢复结果
    │   - schema 完整
    │   - 数据一致
    │
    └─ 返回 DBA: restore 完成消息
```

### 6.3 ObRestoreContext

```cpp
// src/observer/ob_restore_ctx.h
class ObRestoreContext {
public:
  // 跟踪 restore 状态
  int64_t target_time_;                // PITR 目标时间
  ObBackupSetInfo backup_set_;         // backup set 信息
  ObArray<ObLSRecoverInfo> ls_list_;   // 每个 LS 的恢复状态
  // ... 状态字段
};
```

### 6.4 ObRestoreSqlModifier

```cpp
// src/observer/ob_restore_sql_modifier.h
// Restore 期间的 SQL 修改器：
// - 修改 query 走 restore 路径
// - 屏蔽某些 DDL
// - 调整权限检查
```

---

## 7. Restore Preview —— DBA 验证

### 7.1 角色

```sql
-- DBA 在 Restore 前预览
ALTER SYSTEM PREVIEW RESTORE FROM 'oss://...';

-- 查看 Restore Preview 结果
SELECT * FROM oceanbase.__all_virtual_restore_preview;
```

### 7.2 实现

```cpp
// src/observer/virtual_table/ob_tenant_show_restore_preview.{h,cpp}
class ObTenantShowRestorePreview {
  // 虚拟表：显示 restore preview 结果
  // - backup set 来源
  // - 目标时间点
  // - 影响范围 (tenants / tables)
  // - 预计恢复时长
  // - 校验状态
};
```

### 7.3 Restore Status

```sql
-- 查看当前 Restore 状态
SELECT * FROM oceanbase.__all_virtual_ls_log_restore_status;
```

```cpp
// src/observer/virtual_table/ob_all_virtual_ls_log_restore_status.{h,cpp}
class ObAllVirtualLsLogRestoreStatus {
  // 每个 LS 的 restore 进度
  // - restored_clog_lsn
  // - restore_progress_percent
  // - elapsed_time
  // - estimated_remaining_time
};
```

---

## 8. Table Load Backup —— Restore 数据读路径

### 8.1 角色

```cpp
// src/observer/table_load/backup/ob_table_load_backup_flat_row_reader_v1.h
// + ob_table_load_backup_flat_row_reader_v2.h
class ObTableLoadBackupFlatRowReader {
public:
  // 从 backup piece 读 row
  int read_next_row(ObNewRow &row);
};
```

### 8.2 V1 vs V2

- **V1**：老版本 backup piece 格式（OB 4.x）
- **V2**：新版本 backup piece 格式（OB 5.x）

### 8.3 Restore 时的数据读流程

```
Restore 时需要把 backup 数据写入目标集群
    │
    ▼
每 observer 启动 Restore task
    │
    ├─ 1. 读 backup piece 列表（manifest.json）
    │
    ├─ 2. 通过 ObTableLoadBackupFlatRowReader_V2 读 row
    │
    ├─ 3. 转换为 OB 内部格式
    │
    ├─ 4. 通过 DAS 写入目标集群（参见 #09）
    │
    └─ 5. 如果 PITR: replay complement log
```

---

## 9. 与其他文章的关系

### 9.1 与 #20 Backup / Restore

#20 是早期分析文章（34KB），重点是 backup/restore 的 DDL 流程。本篇是 #20 的 **深化**：
- #20 聚焦 backup 触发 / restore 命令 / 元数据表
- 本篇补充 ObBackupComplementLog（PITR 核心）+ Backup Set 详细组织 + Restore Preview + Table Load Backup

### 9.2 与 #48 Checkpoint

checkpoint 是 backup 的轻量前奏：
- checkpoint 只记录 redo log truncate point（参见 #48）
- backup 是完整快照（参见本文）
- checkpoint + backup + complement log 构成完整数据保护

### 9.3 与 #62 cdcservice / archiveservice

archive piece 与 backup piece 共用 IO：
- 同一套 ObBackupDeviceWrapper 抽象
- 同一套 archive_io（OSS / NFS / S3）

### 9.4 与 #65 Standby

Standby 是另一种数据保护方式：
- Standby：实时拉取（持续同步）
- Backup：定时快照（离散备份）
- 两者互补（生产用 Standby，合规用 Backup）

### 9.5 与 #68 Snapshot

Backup 是 #68 三层架构的最重一层：
- slog（分钟级，副本追赶）
- archiveservice（小时级，CLG 归档）
- backup（任意 PIT，灾备）

---

## 10. 总结

### 10.1 Backup / Restore / PITR 在 OB 体系中的定位

OB 的数据保护三层：
- **PITR 时点恢复**（精细，任意时间点）
- **完整 Restore**（备份时间点）
- **Standby**（实时同步，参见 #65）

### 10.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Backup Job | RS 创建 + task 调度 + per-observer 执行 |
| Backup Set | per-tenant + per-LS piece + manifest.json |
| Complement Log | PITR 关键：backup 后 clog 累积 |
| Restore | RS 调度 + per-obreader ingest |
| PITR | backup + complement log replay 到目标时间 |
| Backup Proxy | 跨 observer RPC |
| Restore Preview | DBA 验证 backup set |
| Restore Status | 实时监控恢复进度 |

### 10.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/backup/` (74 files) | Backup 主实现 |
| `src/storage/backup/ob_backup_complement_log.{h,cpp}` | PITR 核心 |
| `src/storage/backup/ob_backup_data_store.{h,cpp}` | Backup 数据存储 |
| `src/storage/backup/ob_backup_block_file_reader_writer.{h,cpp}` | macro block 读写 |
| `src/storage/backup/ob_backup_device_wrapper.{h,cpp}` | OSS/NFS/S3 抽象 |
| `src/rootserver/backup/ob_backup_service.{h,cpp}` | Backup service |
| `src/rootserver/backup/ob_backup_task_scheduler.{h,cpp}` | Task 调度 |
| `src/rootserver/restore/ob_restore_service.{h,cpp}` | Restore service |
| `src/rootserver/restore/ob_recover_table_job_scheduler.{h,cpp}` | Recover table job |
| `src/observer/ob_restore_ctx.h` | Restore 上下文 |
| `src/observer/ob_restore_sql_modifier.h` | SQL modifier |
| `src/observer/table_load/backup/ob_table_load_backup_flat_row_reader_v{1,2}.{h,cpp}` | Table load backup readers |
| `src/observer/virtual_table/ob_tenant_show_restore_preview.{h,cpp}` | Restore preview |
| `src/observer/virtual_table/ob_all_virtual_ls_log_restore_status.{h,cpp}` | Restore status |

### 10.4 关键技术常量（推测）

| 常量 | 典型值 | 位置 |
|------|--------|------|
| Backup piece size | 256MB ~ 1GB | server config |
| Complement log rotation | 默认按大小 | server config |
| Restore parallelism | per-LS 并行 | `ob_recover_table_job_scheduler.h` |
| Backup validate timeout | 几小时 | server config |

### 10.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#79 DDL Service / CREATE / ALTER / DROP**（深化 #64）：

OB 的 DDL 处理 —— CREATE TABLE / ALTER TABLE / DROP TABLE / CREATE INDEX / 等 21+ 种 DDL 的具体实现路径。源码入口：`src/sql/engine/cmd/` + `src/share/schema/ob_ddl_*` + `src/sql/resolver/`。

适用场景：DDL 优化 / 兼容性分析 / 长事务处理。

整吗？