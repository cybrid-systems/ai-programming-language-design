# 20 — 备份恢复与数据归档：OceanBase 的数据保护机制

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前 19 篇文章覆盖了整个 OceanBase 引擎栈——从 MVCC、Memtable、SSTable、LS Tree 到分布式共识（PALF、Election、Clog），再到查询优化、索引设计和分区迁移。现在来到系列的最后一篇：**备份恢复与数据归档（Backup, Restore & Data Archiving）**。

在分布式数据库中，数据保护是最底线的保障：硬件故障、人为误操作、甚至整个集群不可用时，必须能通过备份恢复数据。OceanBase 的备份恢复系统从 v4.x 开始做了全面重构，将存储、归档、备份、恢复分离为独立的子系统。

本章分析的代码分布于三个主要目录：

| 目录 | 职责 |
|------|------|
| `src/storage/backup/` (58 个文件) | 备份数据读写、索引构建、补日志、校验 |
| `src/logservice/archiveservice/` (22 个文件) | 日志归档流水线（获取→排序→发送→持久化） |
| `src/storage/high_availability/ob_ls_restore.h/cpp` | 从备份恢复 LS |

### 备份系统在整个架构中的位置

```
用户 ──► SQL 层 ──► 事务层 ──► Memtable ──► Freeze ──► SSTable
                                                            │
                                    RootServer 调度          │
                                        │                   ▼
                                    ObBackupHandler ──► Backup DAG
                                        │                   │
                                        ▼                   ▼
                                ┌──────────────────────────────────┐
                                │        备份子系统                │
                                │  ObBackupDataStore (元数据存储)  │
                                │  ObBackupIndexStore  (索引存储)  │
                                │  ObBackupCtx          (上下文)   │
                                │  ObBackupTask         (任务)     │
                                └──────────────┬───────────────────┘
                                               │
                                               ▼
                                ┌──────────────────────────────────┐
                                │    远端存储抽象层                 │
                                │  NFS / OSS / OBS / S3           │
                                │  ObIODevice / ObBackupDevice    │
                                │  BandwidthThrottle (流量控制)    │
                                └──────────────────────────────────┘

恢复路径：
    远端存储 ──► ObLSRestoreDagNet ──► 下载 SSTable ──►
    LS Rebuild ──► Tablet Builder ──► 正常服务

日志归档(并发)：
    PALF ──► ObArchiveService ──► ObArchiveFetcher ──►
    ObArchiveSequencer ──► ObArchiveSender ──► 远端存储
```

---

## 1. 备份系统的整体架构

### 1.1 数据备份 vs 日志归档

OceanBase 将"数据保护"拆为两条独立的并行路径：

1. **数据备份（Data Backup）**：将 SSTable（macro/micro block）拷贝到远端存储，产生"备份集"（Backup Set）。数据备份分为全量（FULL）和增量（INC）两种类型，且按粒度分为 SYS/MINOR/MAJOR 三等。

2. **日志归档（Log Archive）**：将 PALF 日志持续流式发送到远端存储，支持任意时间点恢复（PITR）。日志归档以"Piece"为单位，一个归档轮次可能包含多个 Piece。

这种"数据 + 日志"的双通道策略，使得恢复时可以：选一个基础备份集 + 回放时间点之前的归档日志 → 恢复到任意时间点。

### 1.2 备份阶段（ObLSBackupStage）

`ob_backup_data_struct.h` 定义了备份的五个阶段：

```cpp
// 文件: src/storage/backup/ob_backup_data_struct.h
enum ObLSBackupStage {
  LOG_STREAM_BACKUP_SYS = 0,             // 系统表元数据
  LOG_STREAM_BACKUP_MINOR = 1,           // Minor/Mini SSTable
  LOG_STREAM_BACKUP_MAJOR = 2,           // Major SSTable
  LOG_STREAM_BACKUP_INDEX_REBUILD = 3,   // 索引重建
  LOG_STREAM_BACKUP_COMPLEMENT_LOG = 4,  // 补日志
  LOG_STREAM_BACKUP_MAX,
};
```

这五个阶段构成了一条完整的数据备份流水线。每个 LS（LogStream）依次经历这些阶段，每个阶段生成对应的索引文件。

### 1.3 备份数据类型（ObBackupDataType）

`src/share/backup/ob_backup_struct.h` 第 1264-1302 行定义了备份数据的四种类型：

```cpp
// 文件: src/share/backup/ob_backup_struct.h:1264
struct ObBackupDataType final {
  enum BackupDataType {
    BACKUP_SYS = 0,     // LS 内部系统表，成功粒度 = LS 级别
    BACKUP_MINOR = 1,   // Mini/Minor/DDL/MDS SSTable，成功粒度 = Tablet 级别
    BACKUP_MAJOR = 2,   // Major SSTable，成功粒度 = macro block 级别
    BACKUP_USER = 3,
    MAX,
  };
  // ...
};
```

不同数据类型的成功粒度不同——SYS 是 LS 级别成功/失败，MINOR 是 Tablet 级别，MAJOR 则是 Macro Block 级别。这种粒度设计允许在 MAJOR 备份做部分重试，减少整体恢复代价。

### 1.4 备份集描述（ObBackupSetDesc）

```cpp
// 文件: src/share/backup/ob_backup_struct.h:652
struct ObBackupSetDesc {
  int64_t backup_set_id_;              // 备份集 ID
  ObBackupType backup_type_;           // FULL 或 INC
  share::SCN min_restore_scn_;         // 最小恢复 SCN
  int64_t total_bytes_;                // 总字节数
};
```

备份集分为全量（FULL）和增量（INC），增量备份只包含自上次全量备份以来变更的 macro block。备份集 ID 自增，用于恢复时选择正确的基准点。

---

## 2. 核心数据结构

### 2.1 ObBackupHandler —— 备份调度入口

**文件**: `src/storage/backup/ob_backup_handler.h` (51 行) / `ob_backup_handler.cpp` (329 行)

`ObBackupHandler` 是一个纯静态类，提供五个核心调度方法：

```cpp
// 文件: src/storage/backup/ob_backup_handler.h:22-46
class ObBackupHandler {
public:
  // 调度元数据备份 DAG（LS 内系统表）
  static int schedule_backup_meta_dag(
      const ObBackupJobDesc &job_desc,
      const share::ObBackupDest &backup_dest, ...);

  // 调度数据备份 DAG（MINOR / MAJOR SSTable）
  static int schedule_backup_data_dag(...);

  // 调度租户级索引 DAG（合并各 LS 的索引）
  static int schedule_build_tenant_level_index_dag(...);

  // 调度补日志 DAG（保证增量备份的时点一致性）
  static int schedule_backup_complement_log_dag(...);

  // 调度 Tablet Meta 融合 DAG
  static int schedule_backup_fuse_tablet_meta_dag(...);
};
```

在 `ob_backup_handler.cpp` 的实现中，每个方法执行以下步骤：

1. **参数校验**：检查 job_desc、backup_dest、tenant_id 和 ls_id 的合法性
2. **租户切换**：通过 `MAKE_TENANT_SWITCH_SCOPE_GUARD` 切换到目标租户上下文
3. **获取存储 ID**：调用 `ObBackupStorageInfoOperator::get_dest_id` 从内部表获取目标存储配置
4. **创建 DAG**：通过 `dag_scheduler->create_and_add_dag_net<T>()` 创建对应类型的 DAG Net

所有方法都复用 `ObLSBackupDagNetInitParam` 作为参数载体（`ob_backup_task.h:36-60`），该参数包含 job_desc、backup_dest、tenant_id、backup_set_desc、ls_id、turn_id、retry_id 等信息，以及补日志专用的 start_scn/end_scn。

### 2.2 ObBackupDataStore —— 备份元数据存储

**文件**: `src/storage/backup/ob_backup_data_store.h` (654 行) / `cpp` (2416 行)

`ObBackupDataStore` 负责备份元数据（非数据块本身）的读写。它继承 `share::ObBackupStore`，是所有备份元数据的家目录。

核心元数据结构：

| 结构体 | 用途 |
|--------|------|
| `ObBackupDataLSAttrDesc` | LS 属性列表（如 Zone、Region、角色） |
| `ObBackupDataLSIdListDesc` | LS ID 列表 |
| `ObBackupDataTabletToLSDesc` | Tablet → LS 映射 |
| `ObExternTenantLocalityInfoDesc` | 租户拓扑信息（Locality、Primary Zone、资源池） |
| `ObExternBackupSetInfoDesc` | 备份集信息（时间、大小、校验） |
| `ObBackupLSMetaInfosDesc` | LS 元数据包（包含 DataDict、LS 配置等） |

典型的数据结构示例——LS 属性描述：

```cpp
// 文件: src/storage/backup/ob_backup_data_store.h:36-55
struct ObBackupDataLSAttrDesc final : public ObExternBackupDataDesc {
  static const uint8_t FILE_VERSION = 1;
  OB_UNIS_VERSION(1);
  share::SCN backup_scn_;
  ObSArray<share::ObLSAttr> ls_attr_array_;
  // ...
};
```

所有描述结构体都通过 `OB_UNIS_VERSION` 宏实现序列化/反序列化，保证了跨版本的兼容性。

`ObBackupDataStore` 的 API 设计（`ob_backup_data_store.h:505-578`）：

```
┌─ 写入接口 ───────────────────────────────────┐
│ write_ls_attr()                               │
│ write_ls_id_list()                            │
│ write_ls_meta_infos()                         │
│ write_tablet_to_ls_info()                     │
│ write_tenant_locality_info()                  │
│ write_backup_set_info()                       │
│ write_backup_set_placeholder()                │
│ write_tenant_param_info()                     │
│ write_tenant_diagnose_info()                  │
└───────────────────────────────────────────────┘
┌─ 读取接口 ───────────────────────────────────┐
│ read_ls_attr_info()                           │
│ read_ls_id_list()                             │
│ read_ls_meta_infos()                          │
│ read_tablet_to_ls_info()                      │
│ read_tablet_list()                            │
│ read_deleted_tablet_info()                    │
│ read_tenant_locality_info()                   │
│ read_backup_set_info()                        │
│ read_base_tablet_list()                       │
└───────────────────────────────────────────────┘
```

### 2.3 ObBackupIndexStore —— 备份索引系统

**文件**: `src/storage/backup/ob_backup_index_store.h`

备份索引系统将备份数据的宏观组织信息写入远端存储，支持在恢复时快速定位数据块。核心类层次：

```
ObIBackupIndexStore                   ← 抽象基类
├── ObBackupMetaIndexStore            ← 元数据索引存储
│   └── ObRestoreMetaIndexStore       ← 恢复专用（带缓存优化）
├── ObBackupMacroBlockIndexStore      ← Macro Block 索引存储
└── ObBackupOrderedMacroBlockIndexStore ← 有序 Macro Block 索引存储

ObIBackupIndexStoreWrapper            ← 索引包装器
├── ObBackupMetaIndexStoreWrapperV1
└── ObBackupMetaIndexStoreWrapperV2   ← v2 版本优化
```

索引文件是多层级结构（`ObBackupMultiLevelIndexHeader`），支持 2MB 的压缩块大小（`OB_BACKUP_READ_BLOCK_SIZE = 2 << 20`）。索引本身使用 ZSTD 压缩（`OB_DEFAULT_BACKUP_INDEX_COMPRESSOR_TYPE = ZSTD_1_3_8_COMPRESSOR`）。

### 2.4 ObLSBackupCtx —— 备份上下文

**文件**: `src/storage/backup/ob_backup_ctx.h` (364 行)

`ObBackupDataCtx` 是备份期间的文件写上下文，管理备份数据文件的打开/写入/关闭：

```cpp
// 文件: src/storage/backup/ob_backup_ctx.h
struct ObBackupDataCtx {
  int open(...);          // 打开备份数据文件
  int write_macro_block_data(...);   // 写入 macro block
  int write_meta_data(...);         // 写入元数据
  int write_other_block(...);       // 写入其他块
  int close();            // 关闭并写入 trailer + checksum
};
```

关键设计：备份数据文件有固定大小限制（`backup_data_file_size` 配置项），超限时自动切文件。每个文件包含 header → macro block data → meta index → macro block index → trailer，trailer 中包含 `data_accumulate_checksum_` 用于完整性验证。

### 2.5 ObBackupCostant —— 系统常量

`ob_backup_data_struct.h` 中定义了一系列关键常量：

```cpp
static const int64_t OB_DEFAULT_BACKUP_CONCURRENCY = 2;     // 默认并行度
static const int64_t OB_MAX_BACKUP_CONCURRENCY = 128;        // 最大并行度
static const int64_t OB_MAX_BACKUP_MEM_BUF_LEN = 8 * 1024 * 1024;  // 8MB 缓冲区
static const int64_t OB_MAX_BACKUP_FILE_SIZE = 4 * 1024 * 1024;    // 4MB 文件大小上限
static const int64_t OB_BACKUP_INDEX_BLOCK_SIZE = 16 * 1024;       // 16KB 索引块
static const int64_t OB_BACKUP_READ_BLOCK_SIZE = 2 << 20;          // 2MB 读取块
static const int64_t OB_DEFAULT_BACKUP_BATCH_COUNT = 1024;         // 批量数量
```

这些常量体现了备份子系统的资源管理策略：默认 2 并发（低资源占用），最大 128 并发（利用空闲带宽），2MB 读取块大小兼顾 IO 效率与内存消耗。

---

## 3. 日志归档子系统

日志归档位于 `src/logservice/archiveservice/`，共 22 个头文件，约 3206 行代码。

### 3.1 ObArchiveService —— 租户级归档服务

**文件**: `src/logservice/archiveservice/ob_archive_service.h`

`ObArchiveService` 继承 `ObThreadPool`，是每个租户一个的归档守护线程，管理完整的归档流水线：

```cpp
// 文件: src/logservice/archiveservice/ob_archive_service.h
class ObArchiveService : public share::ObThreadPool {
public:
  int init(ObLogService *log_service, ObLSService *ls_svr, uint64_t tenant_id);
  int get_ls_archive_progress(const ObLSID &id, LSN &lsn,
      share::SCN &scn, bool &force_wait, bool &ignore);
  int check_tenant_in_archive(bool &in_archive);
  // ...
};
```

### 3.2 归档流水线

```
ObArchiveService (线程池)
    │
    ├── ObArchiveScheduler (调度器，决定哪些 LS 需要归档)
    │
    ├── ObArchiveFetcher (日志获取器)
    │    └── 从 PALF 拉取日志块
    │
    ├── ObArchiveSequencer (日志排序器)
    │    └── 保证日志按 LSN 顺序排列
    │
    ├── ObArchiveSender (日志发送器)
    │    └── 将日志写入远端存储
    │
    ├── ObArchivePersistMgr (持久化管理器)
    │    └── 管理 Piece 文件的生命周期
    │
    └── ObArchiveRoundMgr (轮次管理器)
         └── 管理归档轮次（Round/Piece 切换）
```

关键设计点：

- **Piece 生命周期**：Piece 状态机为 `ACTIVE → FREEZING → FROZEN → INACTIVE`（`ObBackupPieceStatus`，定义在 `src/share/backup/ob_backup_struct.h:933-942`）。当一个 Piece 达到大小或时间阈值时，RS 触发冻结流程。
- **归档进度查询**：`get_ls_archive_progress()` 提供 LSN 和 SCN 两个维度的归档进度，供迁移/GC/复制模块参考。`force_wait` 标志表示调用模块需要严格等待归档完成。
- **日志缓存池**：通过 `large_buffer_pool.h` 和 `dynamic_buffer.h` 提供大块内存池，减少频繁的 malloc/free。

### 3.3 归档与备份的交互

备份补日志阶段（`ObBackupComplementLogDagNet`）需要读取归档文件来获取增量备份期间产生的日志：

```cpp
// 文件: src/storage/backup/ob_backup_complement_log.h
struct ObBackupPieceFile {
  int64_t dest_id_;        // 目标存储 ID
  int64_t round_id_;       // 归档轮次 ID
  int64_t piece_id_;       // Piece ID
  share::ObLSID ls_id_;    // LS ID
  int64_t file_id_;        // 文件 ID
  share::SCN start_scn_;   // 起始 SCN
  share::SCN checkpoint_scn_; // 检查点 SCN
  ObBackupPathString path_;  // 文件路径
};
```

`ObBackupComplementLogDagNet` 遍历指定 SCN 范围内的归档 Piece 文件，解析其中属于目标 LS 的日志，写入备份集。这是实现"可恢复至任意时间点"的关键环节。

---

## 4. 备份数据流

### 4.1 完整备份流程

```
RootServer 决策备份
    │
    ▼
┌─────────────────────────────────────────────────┐
│ ObBackupHandler::schedule_backup_meta_dag()     │
│  → ObLSBackupMetaDagNet                         │
│     ├─ 遍历 LS 内所有 Tablet                     │
│     ├─ 读取 ObTabletMeta (元数据)                │
│     ├─ 写入 ObBackupDataStore (元数据文件)       │
│     └─ 构建 Meta 索引 (ObBackupMetaIndexStore)   │
├─────────────────────────────────────────────────┤
│ ObBackupHandler::schedule_backup_data_dag()     │
│  → ObLSBackupDataDagNet                         │
│     ├─ ObLSBackupStage::MINOR                   │
│     │   ├─ 扫描所有 Minor SSTable               │
│     │   ├─ 读取 macro block 数据                │
│     │   ├─ 上传到远端存储                        │
│     │   └─ 构建 macro block 索引                │
│     ├─ ObLSBackupStage::MAJOR                   │
│     │   ├─ 扫描 Major SSTable                   │
│     │   ├─ 按 macro block 粒度上传               │
│     │   └─ 增量模式复用已上传的 block            │
│     └─ 写入 trailer + checksum                  │
├─────────────────────────────────────────────────┤
│ ObBackupHandler::schedule_build_tenant_level_   │
│   index_dag()                                    │
│  → ObBackupBuildTenantIndexDagNet               │
│     ├─ 合并各 LS 的索引                          │
│     ├─ 构建租户级索引树                          │
│     └─ 写入 TENANT_LEVEL 索引文件                │
├─────────────────────────────────────────────────┤
│ ObBackupHandler::schedule_backup_complement_    │
│   log_dag()                                      │
│  → ObBackupComplementLogDagNet                  │
│     ├─ 读取归档 Piece (ObArchiveStore)           │
│     ├─ 过滤目标 LS 的日志                        │
│     └─ 写入补日志文件                            │
└─────────────────────────────────────────────────┘
    │
    ▼
远端存储 (NFS/OSS)
├── backet_set_1/
│   ├── ls_1/
│   │   ├── meta/              ← 元数据文件
│   │   ├── major_data/        ← Major 数据
│   │   ├── minor_data/        ← Minor 数据
│   │   └── index/             ← 索引文件
│   ├── ls_2/
│   └── tenant_info/           ← 租户级信息
└── backet_set_2/
```

### 4.2 Macro Block 备份细节

备份数据文件（`ObBackupDataFileTrailer`）的结构：

```
┌─────────────────────────────────────┐
│ Backup File Header (magic=0x0F0F)   │
├─────────────────────────────────────┤
│ Macro Block Data Records            │
│  ┌───────────────────────────────┐  │
│  │ Block[0]: macro_block_data    │  │
│  │ Block[1]: macro_block_data    │  │
│  │ ...                           │  │
│  └───────────────────────────────┘  │
├─────────────────────────────────────┤
│ Meta Data Records                   │
│  ┌───────────────────────────────┐  │
│  │ Meta[0]: tablet/sstable meta │  │
│  │ ...                           │  │
│  └───────────────────────────────┘  │
├─────────────────────────────────────┤
│ Macro Block Index List              │
│  (指向每个 block 在文件中的位置)    │
├─────────────────────────────────────┤
│ Meta Index List                     │
│  (指向每个 meta 记录在文件中的位置)  │
├─────────────────────────────────────┤
│ Trailer                             │
│  ├─ macro_block_count_              │
│  ├─ meta_count_                     │
│  ├─ data_accumulate_checksum_       │
│  └─ trailer_checksum_               │
└─────────────────────────────────────┘
```

### 4.3 备份补日志（Complement Log）

补日志是增量备份的关键机制。当进行增量备份时，数据文件本身只包含自上次备份以来冻结的 SSTable 变更，但备份的"时点"需要包含增量窗口内的日志变更。

`ObBackupComplementLogDagNet` 的工作流程：

```
1. 从 ObBackupComplementLogCtx 获取 compl_start_scn_ 和 compl_end_scn_
2. 查询 ObBackupPieceOp 获取该 SCN 范围内所有归档 Piece 文件列表
3. 对每个 LS 创建 ObBackupLSLogDag
4. ObBackupLSLogDag 内的 ObBackupLSLogTask 负责：
   a. 打开归档 Piece 文件
   b. 过滤属于目标 LS 的日志
   c. 计算日志统计（用于全量备份）或实际写入（用于增量备份）
5. 写入补日志文件到备份集
```

### 4.4 增量备份的重用策略

增量备份的核心优化是"已上传的 macro block 不再上传"。`ObBackupTabletSSTableIndexBuilderMgr` 维护了一个 `local_reuse_map_`（`ob_backup_index_block_builder_mgr.h`）：

```cpp
// 文件: src/storage/backup/ob_backup_index_block_builder_mgr.h
class ObBackupTabletSSTableIndexBuilderMgr final {
  // ...
  common::hash::ObHashMap<blocksstable::ObLogicMacroBlockId,
      ObBackupMacroBlockIndex> local_reuse_map_;
  int insert_place_holder_macro_index(const ObLogicMacroBlockId &logic_id);
  int update_logic_id_to_macro_index(const ObLogicMacroBlockId &logic_id,
      const ObBackupMacroBlockIndex &index);
  int check_place_holder_macro_index_exist(const ObLogicMacroBlockId &logic_id, bool &exist);
  // ...
};
```

当增量备份检测到 macro block 的逻辑 ID 已存在于之前的备份集中时（通过检查备份索引），就会在索引中插入一个"占位符"而不是重新上传实际的 block 数据，极大地节省了网络和存储开销。

---

## 5. 恢复机制

### 5.1 ObLSRestoreDagNet —— LS 恢复 DAG 网络

**文件**: `src/storage/high_availability/ob_ls_restore.h`

恢复系统重用 HA（High Availability）子系统的 DAG 框架。`ObLSRestoreDagNet` 的结构：

```cpp
// 文件: src/storage/high_availability/ob_ls_restore.h:80-112
class ObLSRestoreDagNet: public share::ObIDagNet {
  // ...
  ObLSRestoreCtx *ctx_;                // 恢复上下文
  ObBackupMetaIndexStoreWrapper meta_index_store_;     // 元数据索引
  ObBackupMetaIndexStoreWrapper second_meta_index_store_;
  ObBackupIndexKVCache *kv_cache_;     // 索引缓存
  ObInOutBandwidthThrottle *bandwidth_throttle_;       // 带宽控制
  obrpc::ObStorageRpcProxy *svr_rpc_proxy_;            // RPC 代理
  storage::ObStorageRpc *storage_rpc_;
};
```

恢复上下文 `ObLSRestoreCtx` 包含：

```cpp
// 文件: src/storage/high_availability/ob_ls_restore.h:32-63
struct ObLSRestoreCtx : public ObIHADagNetCtx {
  ObLSRestoreArg arg_;
  int64_t start_ts_;
  int64_t finish_ts_;
  share::ObTaskId task_id_;
  ObStorageHASrcInfo src_;
  ObLSMetaPackage src_ls_meta_package_;
  ObArray<ObLogicTabletID> sys_tablet_id_array_;
  ObArray<ObLogicTabletID> data_tablet_id_array_;
  ObStorageHATableInfoMgr ha_table_info_mgr_;
  ObHATabletGroupMgr tablet_group_mgr_;
  bool need_check_seq_;
  int64_t ls_rebuild_seq_;
};
```

### 5.2 恢复流水线

```
ObLSRestoreDagNet::start_running()
    │
    ▼
ObInitialLSRestoreDag
    │
    ├─ ObInitialLSRestoreTask
    │    ├─ 解析恢复参数 (ObLSRestoreArg)
    │    ├─ 从远端存储读取 LS Meta Package
    │    ├─ 读取 Tablet → LS 映射
    │    └─ 生成子 DAG
    │
    ▼
ObStartLSRestoreDag
    │
    ├─ ObStartLSRestoreTask
    │    ├─ 在目标节点创建 LS
    │    ├─ 设置 LS Meta（LS ID、角色、成员列表）
    │    └─ 创建空 LS 实例
    │
    ▼
ObTabletGroupRestoreDag (并行)
    │
    ├─ ObTabletGroupRestoreTask (按 Tablet Group 粒度)
    │    ├─ 从远端存储下载 Macro Block
    │    ├─ 构建 SSTable (ObSSTableBuilder)
    │    ├─ 检查 Checksum
    │    └─ 写入本地 SSTable
    │
    ▼
ObLSCompleteMigrationDag
    │
    ├─ 更新 Layer 信息
    ├─ 恢复 Tablet 元数据
    └─ 切换 LS 状态为可用
```

### 5.3 索引缓存加速（ObBackupIndexKVCache）

恢复过程中，远端存储的索引文件会被缓存到本地 KV Cache 中：

```cpp
// 文件: src/storage/backup/ob_backup_index_cache.h
// 在 ObIBackupIndexStore::fetch_block_() 中：
int fetch_block_(..., ObKVCacheHandle &handle, ...) {
  // 1. 尝试从缓存获取
  // 2. 缓存未命中 → do_on_cache_miss_() → 从远端读取
  // 3. put_block_to_cache_() → 写入缓存供后续使用
}
```

缓存 key 由 `ObBackupIndexCacheKey` 标识，包含备份文件类型、偏移量和长度，可以精确命中已读取的索引块。

---

## 6. 备份验证机制

### 6.1 ObBackupValidateDagNet

**文件**: `src/storage/backup/ob_backup_validate_dag_scheduler.h` (196 行)

验证 DAG 网络由多个子 DAG 组成，按阶段执行：

```
ObBackupValidateDagNet
    │
    ├─ ObBackupValidatePrepareDag     ← 准备阶段：解析参数，初始化
    ├─ ObBackupValidateBasicDag       ← 基础校验：路径可读性、文件头有效性
    ├─ ObBackupValidateBackupSetPhysicalDag  ← 数据校验：Checksum 验证
    ├─ ObBackupValidateArchivePiecePhysicalDag ← 归档校验：Piece 完整性
    └─ ObBackupValidateFinishDag      ← 完成阶段：汇总结果，报告状态
```

验证内容包括：

- **文件头校验**：检查每个备份文件的 magic 号和版本号
- **Trailer Checksum 校验**：验证 `data_accumulate_checksum_` 和 `trailer_checksum_` 的正确性
- **索引完整性校验**：验证 Macro Block 索引与 Meta 索引是否完整且指向有效数据
- **归档 Piece 校验**：检查归档 Piece 文件的连续性和完整性（无空洞）

---

## 7. 文件布局与备份路径

### 7.1 备份路径结构

`share/backup/ob_backup_path.h` 定义了备份路径的生成规则：

```
{backup_dest}/backup_set_{backup_set_id}/
    ├── tenant_backup_set_infos
    ├── tenant_locality_info
    ├── ls_{ls_id}/
    │   ├── ls_attr_info
    │   ├── ls_meta_info
    │   ├── tablet_to_ls_info
    │   ├── data/
    │   │   ├── sys_data_{turn_id}/
    │   │   ├── minor_data_{turn_id}/
    │   │   └── major_data_{turn_id}/
    │   ├── meta_index/
    │   └── macro_block_index/
    └── ...
```

归档路径结构：

```
{archive_dest}/piece_{piece_id}/
    ├── piece_file_{file_id}
    ├── piece_file_{file_id + 1}
    └── ...
```

### 7.2 远端存储抽象

备份支持多种远端存储后端：

- **NFS**：基础的网络文件系统，通过 POSIX IO 接口访问
- **OSS**：阿里云对象存储，通过 `ObIODevice` 抽象层访问
- **OBS**：华为云对象存储
- **S3**：AWS S3 兼容存储

`ObBackupDeviceWrapper`（`ob_backup_device_wrapper.h`）封装了不同存储后端的差异，`ObInOutBandwidthThrottle` 提供统一的网络带宽控制，避免备份 IO 对在线业务的影响。

---

## 8. 与前面文章的关联

本章涉及的概念和代码与系列前面文章的深度关联：

| 前文 | 关联点 |
|------|--------|
| 文章 06 — Freezer | 冻结后的 SSTable 是备份的数据源，全量备份的数据来自 Major Freeze |
| 文章 07 — LS Tree | 备份是 LS 级别的操作，每个 LS 独立执行备份 DAG |
| 文章 08 — SSTable | 备份传输的是 SSTable 的 macro block 和 meta 数据 |
| 文章 09 — DAS | 备份读取复用 DAS（Direct Access Store）路径获取 block 数据 |
| 文章 10 — 2PC | 2PC 保证备份时的写一致性，使得备份 SCN 后的数据可用 |
| 文章 11 — PALF | 日志归档读取 PALF 的日志数据；备份补日志阶段与 PALF 交互 |
| 文章 12 — Election | LS 角色变化会影响备份的 leader 调度 |
| 文章 19 — Migration | 恢复与迁移共享 HA 子系统的 DAG 框架和 Tablet Builder |

完整依赖链：

```
Freezer (06) → SSTable (08) → LS Tree (07)
    ↓
Backup Read Path (DAS 09)
    ↓
远端存储 (NFS/OSS)
    ↑
日志归档 (PALF 11) ← 2PC (10) 保证一致性
    ↓
恢复 (HA DAG, 类似 Migration 19)
    ↓
Tablet Builder → SSTable Loader → 正常服务
```

---

## 9. 设计决策

### 9.1 全量 vs 增量备份

**决策**：支持 FULL 和 INC 两种备份类型，增量备份通过检查 Macro Block 的 `ObLogicMacroBlockId` 判断是否已上传。

**权衡**：增量备份大幅减少网络传输和存储成本，但增加了恢复时的依赖链（必须依次恢复 FULL → INC1 → INC2 → ... → 归档日志）。OceanBase 选择让备份集管理（`ObBackupCleanMgr`）自动处理过期策略，用户只需指定备份保留天数。

### 9.2 远端存储接口抽象

**决策**：通过 `ObIODevice` 和 `ObBackupDeviceWrapper` 双层抽象屏蔽存储后端差异。

**实现细节**：`ObIODevice` 提供基础的 `pread/pwrite` 接口，`ObBackupDeviceWrapper` 之上封装了备份专用的读/写逻辑（`ObBackupBlockFileReaderWriter`）。这种分层允许在不修改备份核心逻辑的情况下支持新存储后端。

### 9.3 备份一致性

**决策**：使用 SCN（Stale Clocks 的单调递增时间戳）作为备份的时点快照标记。

- 全量备份：在 `backup_scn_` 时刻的数据快照 + 补日志到 `end_scn_`
- 增量备份：以基线的 `last_backup_scn_` 为起点，只包含此后的变更
- 补日志：读取归档 Piece 中 `[start_scn_, end_scn_]` 范围内的日志

**效果**：恢复时可通过"备份集 SCN + 归档日志 SCN"精确还原到任意时间点。

### 9.4 备份对线上性能的影响

**决策**：通过多重机制控制备份对线上负载的影响。

- **并发限制**：`OB_DEFAULT_BACKUP_CONCURRENCY = 2`，`OB_MAX_BACKUP_CONCURRENCY = 128`
- **带宽控制**：`ObInOutBandwidthThrottle` 在全局限速器内调节备份 IO
- **DAG 调度优先级**：备份 DAG 被标记为 `is_ha_dag()`（高可用），但与在线事务 DAG 共享资源池
- **IO 设备优先级**：备份 IO 通过独立的 `ObIODevice` 实例发送，可配置 QoS

### 9.5 恢复的优先级和并行度

**决策**：恢复按 Tablet Group 粒度并行，每个组内部串行。

- 通过 `ObHATabletGroupMgr` 将 Tablet 分配到不同组，同一组的 Tablet 按依赖顺序恢复
- 不同组的恢复并行执行，利用多核和网络带宽
- 恢复支持断点续传（通过 `ObStorageHAPrepareStatus` + `ObStorageHAReuseTabletOp`）

### 9.6 数据备份 vs 日志归档的分离

**决策**：v4.x 将备份和归档彻底分离为独立的子系统。

**理由**：
- 数据备份体积大但频率低（通常每天一次），日志归档体积小但持续产生
- 归档需要低延迟（秒级），备份可以容忍分钟级延迟
- 归档只写（append-only），备份需要读+写
- 两种数据存放位置可以不同（备份在 OSS、归档在 NFS）

---

## 10. 源码索引

### 备份核心

| 文件 | 行数 | 用途 |
|------|------|------|
| `src/storage/backup/ob_backup_handler.h` | 51 | 备份调度入口（静态 API） |
| `src/storage/backup/ob_backup_handler.cpp` | 329 | 调度实现，创建各类 DAG Net |
| `src/storage/backup/ob_backup_data_store.h` | 654 | 备份元数据存储结构定义 |
| `src/storage/backup/ob_backup_data_store.cpp` | 2416 | 序列化/反序列化实现 |
| `src/storage/backup/ob_backup_data_struct.h` | 872 | 核心数据结构、枚举、常量 |
| `src/storage/backup/ob_backup_task.h` | 665 | DAG 任务定义 |
| `src/storage/backup/ob_backup_ctx.h` | 364 | 备份上下文（文件写入器） |
| `src/storage/backup/ob_backup_index_store.h` | 340+ | 备份索引存储 |
| `src/storage/backup/ob_backup_index_block_builder_mgr.h` | 240+ | 索引块构建管理器 |
| `src/storage/backup/ob_backup_index_cache.h` | - | 备份索引 KV Cache |
| `src/storage/backup/ob_backup_index_merger.h` | - | 索引合并器 |
| `src/storage/backup/ob_backup_complement_log.h` | 397 | 补日志 DAG 和上下文 |
| `src/storage/backup/ob_backup_validate_dag_scheduler.h` | 196 | 备份验证 DAG 调度器 |
| `src/storage/backup/ob_backup_validate_base.h` | - | 验证基础类 |
| `src/storage/backup/ob_backup_validate_tasks.h` | - | 验证任务定义 |
| `src/storage/backup/ob_backup_device_wrapper.h` | - | 存储设备封装 |
| `src/storage/backup/ob_backup_block_file_reader_writer.h` | - | 块文件读写器 |
| `src/storage/backup/ob_backup_iterator.h` | - | Tablet 迭代器 |
| `src/storage/backup/ob_backup_fuse_tablet_dag.h` | - | Tablet 元数据融合 DAG |
| `src/storage/backup/ob_ls_backup_clean_mgr.h` | - | 备份清理管理器 |

### 归档核心

| 文件 | 用途 |
|------|------|
| `src/logservice/archiveservice/ob_archive_service.h` | 归档服务主入口 |
| `src/logservice/archiveservice/ob_archive_scheduler.h` | 归档调度器 |
| `src/logservice/archiveservice/ob_archive_fetcher.h` | 日志获取器 |
| `src/logservice/archiveservice/ob_archive_sequencer.h` | 日志排序器 |
| `src/logservice/archiveservice/ob_archive_sender.h` | 日志发送器 |
| `src/logservice/archiveservice/ob_archive_persist_mgr.h` | 持久化管理器 |
| `src/logservice/archiveservice/ob_archive_round_mgr.h` | 轮次管理器 |
| `src/logservice/archiveservice/ob_archive_allocator.h` | 归档专用分配器 |
| `src/logservice/archiveservice/ob_ls_task.h` | LS 级别归档任务 |
| `src/logservice/archiveservice/ob_ls_mgr.h` | LS 归档管理器 |
| `src/logservice/archiveservice/ob_archive_file_utils.h` | 归档文件工具 |
| `src/logservice/archiveservice/ob_archive_io.h` | 归档 IO 抽象 |

### 恢复核心

| 文件 | 行数 | 用途 |
|------|------|------|
| `src/storage/high_availability/ob_ls_restore.h` | 240+ | LS 恢复 DAG 和上下文 |
| `src/storage/high_availability/ob_storage_restore_struct.h` | - | 恢复参数结构 |
| `src/storage/high_availability/ob_physical_copy_task.h` | - | 物理拷贝任务 |
| `src/storage/high_availability/ob_tablet_group_restore.h` | - | Tablet Group 级别恢复 |
| `src/storage/high_availability/ob_storage_ha_dag.h` | - | HA DAG 基类 |
| `src/storage/high_availability/ob_storage_ha_tablet_builder.h` | - | Tablet 构建器 |

### 共享层

| 文件 | 用途 |
|------|------|
| `src/share/backup/ob_backup_struct.h` | 备份核心结构（ObBackupDest, ObBackupSetDesc, ObBackupDataType） |
| `src/share/backup/ob_backup_path.h` | 备份路径生成 |
| `src/share/backup/ob_backup_data_table_operator.h` | 备份进度持久化 |
| `src/share/backup/ob_backup_connectivity.h` | 存储连通性检测 |
| `src/share/backup/ob_archive_struct.h` | 归档结构 |
| `src/share/backup/ob_archive_store.h` | 归档元数据存储 |
| `src/share/backup/ob_archive_path.h` | 归档路径生成 |
| `src/share/backup/ob_archive_piece.h` | Piece 管理 |
| `src/share/backup/ob_backup_config.h` | 备份配置项 |

---

## 11. 总结

OceanBase 的备份恢复系统经过 v4.x 的重构，形成了清晰的三层架构：

1. **数据备份层**（`storage/backup/`）：负责按 LS/Tablet 粒度将 SSTable 数据拷贝到远端存储，支持全量和增量策略，通过补日志保证时点一致性。

2. **日志归档层**（`logservice/archiveservice/`）：持续从 PALF 拉取日志并写入远端存储，支持 Piece 切换和任意时间点恢复。

3. **恢复层**（`storage/high_availability/`）：复用 HA 子系统的 DAG 框架，从远端存储下载备份数据和归档日志，重建 LS 和 Tablet。

这篇是系列的第 20 篇，也是最后一篇。整个系列覆盖了 OceanBase 引擎的核心——从底层的 B-Tree 存储结构、MVCC 并发控制，到 Memtable 和 SSTable 的数据组织，再到内存冻结、Compaction、LS Tree 的分层架构，以及分布式共识（PALF、Election、Clog）和查询优化器、索引设计，最终到分区迁移和备份恢复。至此，我们完成了对 OceanBase 存储引擎从微观到宏观的全面源码级解读。
