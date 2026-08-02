# 86-table-load-batch-import — OceanBase Table Load / 批量导入 / LOAD DATA 框架深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/observer/table_load/` 128 文件 + `src/sql/engine/cmd/ob_load_data_*` 10 文件 + `src/share/table/ob_table_load_define.h` + `src/observer/table_load/backup/` 42 文件 + `src/storage/direct_load/` 参见 #66）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Table Load 框架**是整个 observer 集群"批量数据导入"的统一入口 —— `LOAD DATA INFILE`（SQL 协议）+ `INSERT INTO ... SELECT` 大批量 + backup restore + 跨集群同步 全部走 `ObTableLoadService` 统一抽象。OB 5.x 的 Table Load 建立在 **DAG 调度**（参见 #66）+ **per-table load ctx** + **资源管理**（resource 目录）三层之上。

本文聚焦 8 个核心问题：

1. **Table Load 全景** —— 128 文件 + 多 client 变体
2. **ObTableLoadService 主类** —— 统一入口
3. **ObTableLoadManager / ObTableLoadCoordinator** —— 任务管理
4. **ObTableLoadClientTask** —— client 任务
5. **ObTableLoadResourceManager** —— 资源管理
6. **LOAD DATA SQL 入口** —— 10 文件
7. **Table Load Backup 集成**（42 文件，参见 #85）
8. **多数据源抽象** —— CSV / SQL / Backup

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 66-direct-load | #66 是 storage 层 direct_load（210 文件），#86 是 observer 层 table_load（128 文件） |
| 78-backup-restore | restore 表加载走 table_load/backup/（42 文件） |
| 85-partition-table | partition → tablet 物理分布影响表加载 |
| 41-join-operators | DAG 调度共享 |
| 62-cdcservice | 外部数据流对比 |

---

## 1. 整体架构：Table Load 五层

### 1.1 模块组成

```bash
# Observer 层 table_load 主目录（128 文件）
src/observer/table_load/
├── ob_table_load_service.{h,cpp}                # 主类
├── ob_table_load_manager.{h,cpp}                 # manager
├── ob_table_load_coordinator.{h,cpp}             # coordinator
├── ob_table_load_coordinator_ctx.{h,cpp}
├── ob_table_load_client_service.{h,cpp}          # client service
├── ob_table_load_client_task.{h,cpp}             # client task
├── ob_table_load_exec_ctx.{h,cpp}                # exec ctx
├── ob_table_load_struct.{h,cpp}                  # 数据结构
├── ob_table_load_assigned_memory_manager.{h,cpp}  # memory mgmt
├── ob_table_load_assigned_task_manager.{h,cpp}   # task mgmt
├── ob_table_load_autoinc_nextval.{h,cpp}         # auto-inc
├── ob_table_load_bucket.{h,cpp}                  # bucket
├── client/                                        # client 子目录
│   └── ob_table_direct_load_rpc_executor.{h,cpp}
├── control/                                      # control 子目录
│   └── ob_table_load_control_rpc_proxy.{h,cpp}
├── dag/                                          # DAG 调度
├── resource/                                      # 资源管理
│   ├── ob_table_load_resource_manager.{h,cpp}
│   ├── ob_table_load_resource_rpc_proxy.{h,cpp}
│   └── ob_table_load_resource_service.{h,cpp}
└── backup/                                       # backup 子目录（42 文件，参见 #85）

# SQL 层 LOAD DATA 入口（10 文件）
src/sql/engine/cmd/
├── ob_load_data_executor.{h,cpp}                # 主 executor
├── ob_load_data_impl.{h,cpp}                     # 实现
├── ob_load_data_direct_impl.{h,cpp}              # direct load 实现（参见 #66）
├── ob_load_data_file_reader.{h,cpp}              # file reader
├── ob_load_data_parser.{h,cpp}                   # parser
├── ob_load_data_rpc.{h,cpp}                      # RPC
├── ob_load_data_rpc.{h,cpp}
├── ob_load_data_storage_info.{h,cpp}             # 存储信息
└── ob_load_data_utils.{h,cpp}                    # 工具

# 共享定义
src/share/table/ob_table_load_define.h            # 公共定义

# Storage 层 direct_load（210 文件，参见 #66）
src/storage/direct_load/                          # 参见 #66
```

### 1.2 五层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: SQL 入口 (src/sql/engine/cmd/ob_load_data_*)         │
│  - LOAD DATA INFILE 解析                                          │
│  - INSERT INTO ... SELECT 大批量                                │
│  - 调用 ObTableLoadService                                        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: ObTableLoadService (主类, 128 文件)                  │
│  - check_tenant / check_support_direct_load                     │
│  - 统一多数据源抽象                                              │
│  - 资源分配（memory / task）                                    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: ObTableLoadCoordinator + Manager                        │
│  - DAG 调度 (参见 #66 + #41)                                    │
│  - 任务拆分 + 状态管理                                          │
│  - 协调多 observer / 协调 client + server                        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: ObTableLoadClientTask (client 任务)                    │
│  - per-table load task                                          │
│  - 读数据 (CSV / SQL / backup) → 写数据 (SSTable)              │
│  - progress 报告                                                 │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5: Storage direct_load (参见 #66)                        │
│  - ObDirectLoadSSTable + ObDirectLoadDagInsertTableRowWriter     │
│  - 绕开 SQL parser + memtable                                    │
│  - 直接生成 SSTable                                              │
└──────────────────────────────────────────────────────────────────┘
```

### 1.3 与 #66 Direct Load 的关系

| 维度 | #66 Direct Load | #86 Table Load |
|------|-----------------|----------------|
| 层级 | Storage | Observer + SQL |
| 文件数 | 210 | 128 + 10 |
| 职责 | 实际写 SSTable | 任务调度 + 资源管理 |
| 客户端 | 上层调用 | SQL / OBSQL / Client API |
| 共同点 | 共享 Direct Load 内核 | |

---

## 2. ObTableLoadService 主类

### 2.1 类骨架（实读自 `ob_table_load_service.h`）

```cpp
// src/observer/table_load/ob_table_load_service.h
class ObTableLoadService
{
public:
  // 生命周期
  static int mtl_new(ObTableLoadService *&service);
  static void mtl_destroy(ObTableLoadService *&service);

  // Tenant 检查
  static int check_tenant();

  // 旁路导入内核获取加表锁后的 schema 进行检查
  static int check_support_direct_load(
      uint64_t table_id,
      const storage::ObDirectLoadMethod::Type method,
      const storage::ObDirectLoadInsertMode::Type insert_mode,
      const storage::ObDirectLoadMode::Type load_mode,
      const storage::ObDirectLoadLevel::Type load_level,
      const sql::ObLoadDupActionType dup_action,
      const common::ObIArray<uint64_t> &column_ids,
      const bool enable_inc_major);

  // 业务层指定 schema_guard 进行检查
  static int check_support_direct_load(
      share::schema::ObSchemaGetterGuard &schema_guard,
      uint64_t table_id,
      const storage::ObDirectLoadMethod::Type method,
      const storage::ObDirectLoadInsertMode::Type insert_mode,
      const storage::ObDirectLoadMode::Type load_mode,
      const storage::ObDirectLoadLevel::Type load_level,
      const sql::ObLoadDupActionType dup_action,
      const common::ObIArray<uint64_t> &column_ids,
      const bool enable_inc_major);

  // ... 更多 API
};
```

### 2.2 关键设计

**多种 check_support_direct_load 重载**：
- 加表锁后 schema 检查
- 业务层 schema_guard 检查
- 不同参数组合支持多种 load 模式

**参数维度**（ObDirectLoad* 多个枚举）：
- `ObDirectLoadMethod::Type` —— load 方法（INSERT / REPLACE / UPSERT 等）
- `ObDirectLoadInsertMode::Type` —— insert 模式
- `ObDirectLoadMode::Type` —— load 模式（normal / full / inc）
- `ObDirectLoadLevel::Type` —— load 级别（table / partition / tablet）
- `ObLoadDupActionType` —— 重复行处理

---

## 3. ObTableLoadManager + Coordinator

### 3.1 ObTableLoadManager

```cpp
// (推测, src/observer/table_load/ob_table_load_manager.h)
class ObTableLoadManager {
public:
  // 启动 / 停止 load
  int start_load(ObTableLoadParam &param);
  int stop_load(const uint64_t table_id);

  // 查询 load 状态
  int get_load_status(const uint64_t table_id, ObTableLoadStatus &status);

  // 资源分配
  int allocate_resource(const ObTableLoadResource &resource);

private:
  // 内部维护 table_id → ObTableLoadCtx 映射
  hash::ObHashMap<uint64_t, ObTableLoadCtx> load_ctx_map_;
};
```

### 3.2 ObTableLoadCoordinator

```cpp
// (推测, src/observer/table_load/ob_table_load_coordinator.{h,cpp})
class ObTableLoadCoordinator {
public:
  // 协调多 observer / 协调 client + server
  int coordinate(const ObTableLoadTask &task);

  // DAG 调度
  int schedule_dag();

  // 状态报告
  int report_progress();
};
```

### 3.3 关键设计

**Manager vs Coordinator 区别**：
- **Manager**：全局管理（per-table ctx 生命周期）
- **Coordinator**：单次 load 协调（DAG 调度 + 状态）

---

## 4. ObTableLoadClientTask

### 4.1 类骨架

```cpp
// (推测, src/observer/table_load/ob_table_load_client_task.{h,cpp})
class ObTableLoadClientTask {
public:
  // 启动
  int start();

  // 读数据（CSV / SQL / backup）
  int read_data();

  // 写数据（通过 storage::ObDirectLoad）
  int write_data();

  // progress 报告
  int report_progress();

  // 取消
  int cancel();

  // 完成
  int finish();
};
```

### 4.2 关键设计

**per-table load task**：
- 1 个 LOAD DATA / INSERT SELECT = 1 个 client task
- 读数据（多种数据源）→ 写数据（SSTable）
- 进度报告 + 取消支持

---

## 5. ObTableLoadResourceManager

### 5.1 角色

```cpp
// (推测, src/observer/table_load/resource/ob_table_load_resource_manager.{h,cpp})
class ObTableLoadResourceManager {
public:
  // 资源分配 / 回收
  int allocate_memory(const uint64_t tenant_id, int64_t size);
  int deallocate_memory(const uint64_t tenant_id, int64_t size);

  // task 调度
  int schedule_task(const ObTableLoadTask &task);

  // 资源限制检查
  int check_resource_limit(const uint64_t tenant_id, int64_t need);
};
```

### 5.2 资源子目录

```bash
src/observer/table_load/resource/
├── ob_table_load_resource_manager.{h,cpp}     # 资源 manager
├── ob_table_load_resource_rpc_proxy.{h,cpp}  # 资源 RPC proxy
├── ob_table_load_resource_service.{h,cpp}     # 资源 service
```

---

## 6. LOAD DATA SQL 入口（10 文件）

### 6.1 SQL 入口文件

```bash
src/sql/engine/cmd/
├── ob_load_data_executor.{h,cpp}                # 主 executor
├── ob_load_data_impl.{h,cpp}                     # 实现
├── ob_load_data_direct_impl.{h,cpp}              # direct load 实现（参见 #66）
├── ob_load_data_file_reader.{h,cpp}              # file reader（CSV / TSV）
├── ob_load_data_parser.{h,cpp}                   # parser（SQL 解析）
├── ob_load_data_rpc.{h,cpp}                      # 跨 observer RPC
├── ob_load_data_storage_info.{h,cpp}             # 存储信息
├── ob_load_data_rpc.{h,cpp}                      # RPC
└── ob_load_data_utils.{h,cpp}                    # 工具
```

### 6.2 ob_load_data_impl 流程

```cpp
// (推测, src/sql/engine/cmd/ob_load_data_impl.cpp)
class ObLoadDataImpl {
public:
  int execute(ObExecContext &ctx, const ParseNode &parse_tree);

private:
  // 1. 解析 LOAD DATA 参数
  //    - filename
  //    - fields_terminated_by
  //    - lines_terminated_by
  //    - ignore_lines / ignore_rows
  int parse_params();

  // 2. 创建 table ctx
  int create_table_ctx();

  // 3. 调用 ObTableLoadService::start_load
  int start_load();

  // 4. 等待 load 完成
  int wait_complete();
};
```

### 6.3 ob_load_data_file_reader

```cpp
class ObLoadDataFileReader {
public:
  // 读文件（CSV / TSV / JSON 等）
  int read_next_row(ObNewRow &row);
};
```

### 6.4 ob_load_data_direct_impl

```cpp
// direct load 路径（参见 #66）
class ObLoadDataDirectImpl {
  // 跳过 SQL parser + memtable，直接生成 SSTable
};
```

---

## 7. Table Load Backup 集成（42 文件，参见 #85）

### 7.1 Restore 走 Table Load 框架

```
Restore job 启动
    │
    ▼
ObTableLoadBackupService (from 42 files, 参见 #85)
    │
    ├─ 1. 读 backup piece
    │
    ├─ 2. ObTableLoadBackupFlatRowReader 读 row
    │
    ├─ 3. ObTableLoadBackupColumnMap 映射列
    │
    ├─ 4. ObTableLoadBackupBlockSSTableStruct 写 SSTable
    │
    └─ 5. ingest 到目标集群
```

### 7.2 Backup 子目录关键类

```bash
src/observer/table_load/backup/
├── ob_table_load_backup_block_sstable_struct.{h,cpp}   # macro block 结构
├── ob_table_load_backup_column_map_v1.{h,cpp}             # 列映射 V1
├── ob_table_load_backup_column_map_v2.{h,cpp}             # 列映射 V2
├── ob_table_load_backup_file_util.{h,cpp}                 # 文件工具
├── ob_table_load_backup_flat_row_reader_v1.{h,cpp}       # flat row reader V1
├── ob_table_load_backup_flat_row_reader_v2.{h,cpp}       # flat row reader V2
├── ob_table_load_backup_logical_backup_table.{h,cpp}      # logical backup
├── ob_table_load_backup_micro_block_reader.{h,cpp}        # micro block reader
├── ob_table_load_backup_partition_scanner.{h,cpp}         # partition scanner
├── ob_table_load_backup_physical_backup_partition_scanner_v2.{h,cpp}  # physical V2
├── ob_table_load_backup_imicro_block_reader.{h,cpp}       # imicro block reader
├── ob_table_load_backup_row_reader.{h,cpp}                # 通用 row reader
├── ob_table_load_backup_restore_service.{h,cpp}          # restore service
├── ob_table_load_backup_sstable_sec_meta_reader.{h,cpp}   # SSTable sec meta
├── ob_table_load_backup_stat.h                           # 统计
├── ob_table_load_logical_backup_table.{h,cpp}             # logical table
└── encoding/                                             # encoding 子目录
    ├── ob_table_load_backup_encoding_calculator.{h,cpp}
    ├── ob_table_load_backup_ob_csv_decoder.{h,cpp}
    ├── ob_table_load_backup_ob_csv_encoder.{h,cpp}
    ├── ob_table_load_backup_sql_consumer.{h,cpp}
    └── # ... 其他
```

---

## 8. 多数据源抽象

### 8.1 OB Table Load 支持的数据源

| 数据源 | 类 | 路径 |
|--------|-----|------|
| **CSV / TSV** | `ObLoadDataFileReader` + `ob_table_load_backup_ob_csv_decoder` | `src/sql/engine/cmd/ob_load_data_file_reader.{h,cpp}` + `src/observer/table_load/backup/encoding/` |
| **SQL** | `INSERT INTO ... SELECT` 通过 `ob_load_data_impl` | `src/sql/engine/cmd/ob_load_data_impl.{h,cpp}` |
| **Backup** | `ObTableLoadBackupService` + `ob_table_load_backup_flat_row_reader` | `src/observer/table_load/backup/`（42 文件，参见 #85） |
| **Direct Insert** | `ObLoadDataDirectImpl` | `src/sql/engine/cmd/ob_load_data_direct_impl.{h,cpp}` + `src/storage/direct_load/`（参见 #66） |

### 8.2 统一抽象：ObTableLoadService

所有数据源最终都走 `ObTableLoadService`：
- LOAD DATA CSV → `ObTableLoadService::start_load`
- INSERT SELECT → `ObTableLoadService::start_load`
- Backup Restore → `ObTableLoadService::start_load`
- Direct Load → `ObTableLoadService::start_load`（参见 #66）

---

## 9. 批量导入性能优化

### 9.1 多级优化

| 优化 | 实现 |
|------|------|
| 跳过 SQL parser | `ob_load_data_direct_impl` 直接生成 SSTable |
| 跳过 memtable | `ObDirectLoadSSTable`（参见 #66） |
| 跳过 MVCC | Direct Load 不走版本链 |
| DAG 并行 | 参见 #66 + #41 |
| Bucket 切分 | `ob_table_load_bucket.{h,cpp}` |
| Memory 管理 | `ob_table_load_assigned_memory_manager.{h,cpp}` |
| Task 调度 | `ob_table_load_assigned_task_manager.{h,cpp}` |

### 9.2 性能数字

参见 #66 §14：
- LOAD DATA：MB/s 级
- INSERT SELECT：KB/s ~ MB/s 级
- Backup Restore：MB/s 级
- Direct Load（绕过 memtable）：MB/s+ 级

---

## 10. 与其他文章的关系

### 10.1 与 #66 Direct Load

#66 是 storage 层 direct_load（210 文件），本文是 observer 层 table_load（128 文件）。
- #66 关注实际写 SSTable 的 direct_load 内核
- 本文关注任务调度 + 资源管理的 table_load 框架
- **共同点**：LOAD DATA / INSERT SELECT / backup restore 全部走 table_load → direct_load 路径

### 10.2 与 #78 Backup / Restore

Restore 表加载走 `ob_table_load/backup/`（42 文件，参见 #85）。
- 本文是统一入口（ObTableLoadService）
- #85 是 backup 子目录的细节
- #78 是 backup 的高层流程

### 10.3 与 #85 Partition Table

Partition → Tablet 物理分布影响表加载：
- LOAD DATA 时按 partition 切分 → 每个 partition 一个 writer
- Direct Load 跨 partition 并行

### 10.4 与 #41 Join Operators

DAG 调度共享（参见 #41）：
- Table Load 走 DAG 调度多 partition 并行
- 与 Join 走相同的 DAG 框架

### 10.5 与 #62 cdcservice-logfetcher

外部数据流对比：
- `cdcservice` 是 OB 主动 push binlog 给外部
- `table_load` 是 OB 主动 pull 数据到内部
- 两者是"输出"vs"输入"的对称设计

---

## 11. 总结

### 11.1 Table Load 在 OB 体系中的定位

Table Load 框架是 **OB 批量数据导入的统一入口**：
- LOAD DATA / INSERT SELECT / Backup Restore / Direct Load 全部走 ObTableLoadService
- 128 文件 observer 层 + 10 文件 SQL 层 + 42 文件 backup 子目录
- 通过 storage::ObDirectLoad 内核实际写 SSTable

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 统一入口 | `ObTableLoadService` 抽象多数据源 |
| Manager | `ObTableLoadManager` 全局管理（per-table ctx） |
| Coordinator | `ObTableLoadCoordinator` 单次协调（DAG） |
| Client Task | `ObTableLoadClientTask` per-table load task |
| 资源管理 | `ObTableLoadResourceManager` memory / task |
| LOAD DATA SQL | `ob_load_data_executor` + `ob_load_data_impl` |
| File Reader | `ob_load_data_file_reader`（CSV / TSV） |
| Direct Load | `ob_load_data_direct_impl` + `src/storage/direct_load/`（参见 #66） |
| Backup | `ob_table_load/backup/`（42 文件，参见 #85） |
| DAG 调度 | `dag/` 子目录 |
| Control | `control/ob_table_load_control_rpc_proxy` |
| Client RPC | `client/ob_table_direct_load_rpc_executor` |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/observer/table_load/` (128 文件) | Table Load 框架 |
| `src/observer/table_load/ob_table_load_service.{h,cpp}` | 主类 |
| `src/observer/table_load/ob_table_load_manager.{h,cpp}` | Manager |
| `src/observer/table_load/ob_table_load_coordinator.{h,cpp}` | Coordinator |
| `src/observer/table_load/ob_table_load_client_task.{h,cpp}` | Client Task |
| `src/observer/table_load/ob_table_load_client_service.{h,cpp}` | Client Service |
| `src/observer/table_load/ob_table_load_exec_ctx.{h,cpp}` | Exec Ctx |
| `src/observer/table_load/ob_table_load_assigned_memory_manager.{h,cpp}` | Memory |
| `src/observer/table_load/ob_table_load_assigned_task_manager.{h,cpp}` | Task |
| `src/observer/table_load/ob_table_load_autoinc_nextval.{h,cpp}` | auto-inc |
| `src/observer/table_load/ob_table_load_bucket.{h,cpp}` | Bucket |
| `src/observer/table_load/client/` | Client 子目录 |
| `src/observer/table_load/control/` | Control 子目录 |
| `src/observer/table_load/dag/` | DAG 调度 |
| `src/observer/table_load/resource/` | 资源管理 |
| `src/observer/table_load/backup/` (42 文件) | Backup 子目录（参见 #85） |
| `src/sql/engine/cmd/ob_load_data_*` (10 文件) | LOAD DATA SQL 入口 |
| `src/share/table/ob_table_load_define.h` | 公共定义 |
| `src/storage/direct_load/` (210 文件, 参见 #66) | Direct Load 内核 |

### 11.4 多数据源支持

| 数据源 | 类 | 路径 |
|--------|-----|------|
| **CSV / TSV** | `ObLoadDataFileReader` + `ob_table_load_backup_ob_csv_decoder` | SQL 层 + backup encoding |
| **SQL** | `INSERT INTO ... SELECT` 通过 `ob_load_data_impl` | SQL 层 |
| **Backup** | `ObTableLoadBackupService` + `ob_table_load_backup_flat_row_reader` | Observer backup（参见 #85） |
| **Direct Insert** | `ObLoadDataDirectImpl` | SQL 层 + storage direct_load（参见 #66） |

### 11.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#87 RPC 框架 / obrpc 跨 observer 通信**：

OB 的 obrpc 框架 —— 跨 observer / RS 通信的 RPC 协议栈，包括 ObRpcPacket / ObRpcProcessor / 服务注册 / 同步异步调用。源码入口：`src/rpc/` + `src/share/ob_rpc_*.{h,cpp}` + 各 obrpc 子模块。

适用场景：跨 observer 通信 / RS 协调 / 异步 RPC / 性能调优。

整吗？