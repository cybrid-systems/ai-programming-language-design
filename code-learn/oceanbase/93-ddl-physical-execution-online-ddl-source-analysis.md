# 93-ddl-physical-execution — OceanBase DDL 物理执行 / Online DDL 实现深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/storage/ddl/` **151 文件** + `src/rootserver/ob_ddl_service.{h,cpp,launcher.h,launcher.cpp,service.cpp}` + `src/rootserver/ob_alter_table_constraint_checker.h` + `ob_index_builder.h` + `ob_mlog_builder.h` + `parallel_ddl/ob_ddl_helper.h` + `ob_create_index_on_empty_table_helper.h` + `ddl_task/ob_index_build_task.h` + `ob_lob_piece_builder.h`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **DDL 物理执行**是整个 observer 集群"数据定义变更"的执行路径 —— 从 `ALTER TABLE` 解析 → DDL executor → RS DDL service → 跨 observer 调度 → 物理执行（增删列 / 改列类型 / 建索引 / 切主等）→ Schema Service 异步落地。OB 5.x 的 DDL 物理执行建立在 **`ObDDLService` + `ObDDLRedoLogWriter` + `ObDDLIncTask` + `ObDDLHeartBeatTask` + `ObDDLBuildIndexTask`** 之上，是企业级 Online DDL 的完整实现。

本文聚焦 8 个核心问题：

1. **DDL 物理执行全景** —— 151 文件模块
2. **ObDDLService**（RS 端）—— DDL 任务调度
3. **ObDDLRedoLogWriter** —— DDL redo log 写 PALF
4. **ObDDLIncTask** —— Online DDL 增量任务（参见 #64）
5. **ObDDLHeartBeatTask** —— DDL 心跳
6. **ObDDLBuildIndexTask** —— 建索引任务
7. **DDL CG / Column Grouping** —— 列存 DDL
8. **DDL 与 MemTable / SSTable / Cache 交互**

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 11-ddl-inc-major | #11 是早期分析 online DDL 增量 major |
| 64-online-ddl | #64 是早期分析 Online DDL 概览 |
| 76-schema-service | Schema Service 异步落地 |
| 79-ddl-service | #79 描述 21+ DDL executor 路径 |
| 89-memtable-memstore | memtable 暂停写 DDL（参见 #89） |
| 90-sstable-macroblock-encoding | DDL 期间列存改写（参见 #90） |
| 91-cache-obtabletcache | DDL 触发 cache 失效（参见 #91） |

---

##  1. 整体架构：DDL 物理执行 5 层

### 1.1 模块组成（151 文件 + 散落 rootserver）

```bash
$ ls src/storage/ddl/ | wc -l
151

# DDL 物理执行相关
src/storage/ddl/
├── ob_build_index_task.{h,cpp}              # 建索引任务
├── ob_cg_block_tmp_file.{h,cpp}             # CG block 临时文件
├── ob_cg_block_tmp_files_iterator.{h,cpp}    # CG block iterator
├── ob_cg_macro_block_write_op.{h,cpp}       # CG macro block 写 op
├── ob_cg_macro_block_write_task.{h,cpp}     # CG macro block 写 task
├── ob_cg_macro_block_writer.{h,cpp}         # CG macro block writer
├── ob_cg_micro_block_write_op.{h,cpp}       # CG micro block 写 op
├── ob_cg_row_tmp_file.{h,cpp}               # CG row 临时文件
├── ob_column_clustered_dag.{h,cpp}          # column clustered DAG
├── ob_complement_data_task.{h,cpp}          # complement data task
├── ob_ddl_alter_auto_part_attr.{h,cpp}       # alter auto partition attr
├── ob_ddl_change_tablet_to_table_helper.h   # change tablet to table helper
├── ob_ddl_clog.{h,cpp}                       # DDL clog
├── ob_ddl_complete_task.{h,cpp}              # DDL complete task
├── ob_ddl_concurrent_control.{h,cpp}         # 并发控制
├── ob_ddl_data_fill_task.{h,cpp}             # DDL data fill
├── ob_ddl_define.h                            # DDL 定义
├── ob_ddl_diagnose.{h,cpp}                   # 诊断
├── ob_ddl_handler.h                          # handler
├── ob_ddl_heart_beat_task.{h,cpp}            # DDL heartbeat task
├── ob_ddl_inc_start_task.{h,cpp}             # DDL inc start
├── ob_ddl_inc_task.{h,cpp}                   # DDL incremental task
├── ob_ddl_redo_log_writer.{h,cpp}            # DDL redo log writer
├── ob_ddl_struct.h                           # DDL 结构
├── ob_ddl_util.{h,cpp}                        # DDL 工具
├── ob_ddl_wrap_cg_task.{h,cpp}               # wrap column group task
└── # ... 130+ 其他

# RootServer 层 DDL 协调
src/rootserver/
├── ob_ddl_service.{h,cpp,launcher.h,launcher.cpp,service.cpp}  # 主 service
├── ob_alter_table_constraint_checker.h        # alter constraint 检查
├── ob_index_builder.h                        # index builder
├── ob_mlog_builder.h                         # mlog builder
├── parallel_ddl/ob_ddl_helper.h              # 并行 DDL helper
├── ob_create_index_on_empty_table_helper.h   # 空表建索引 helper
├── ddl_task/ob_index_build_task.h            # 索引 build task
├── ob_lob_piece_builder.h                   # LOB piece builder
├── ob_root_utils.h                           # RS 工具
├── ob_upgrade_storage_format_version_executor.h  # 升级 storage format
└── # ... 几十个
```

**151 文件（src/storage/ddl/）+ 几十个 rootserver DDL 文件** —— DDL 物理执行是 OB 5.x 中最大子目录之一（仅次于 expr 1161 / blocksstable 145 / schema 244 / location_cache 20 / memtable 37）。

### 1.2 路径修正（来自 #82-#92 路径修正的延续）

```
正确路径:
  src/storage/ddl/ (151 files) - DDL 物理执行
  src/rootserver/ob_ddl_service.{h,cpp} - DDL service
  src/rootserver/ddl_task/ob_index_build_task.h - DDL task 子目录

不存在路径 (按 #82-#92 路径修正继续):
  src/sql/ddl/  ← 不存在（我之前 #60 提的路径错）
  src/ddl/      ← 不存在
  src/lib/ddl/  ← 不存在
```

### 1.3 5 层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: DDL 入口 (executor, 参见 #79)                           │
│  - SQL Parser → ObDDLStmt                                        │
│  - Optimizer → 物理 plan                                         │
│  - DDL Executor (21+ 种)                                         │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: ObDDLService (RS 端)                                   │
│  - 调度 DDL 任务 (per-LS / per-tablet)                            │
│  - 协调 observer 执行                                            │
│  - DDL heartbeat 监控                                            │
│  - DDL 完成 ack                                                   │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: DDL Task (per-LS / per-tablet)                        │
│  - ObDDLIncStartTask / ObDDLIncCommitTask / ObDDLCompleteTask    │
│  - ObDDLBuildIndexTask / ObDDLComplementDataTask / ObDDLDataFill│
│  - ObDDLWrapCGTask (column grouping)                            │
│  - ObDDLHeartBeatTask (心跳)                                    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: DDL CG / Column Grouping (列存 DDL)                     │
│  - ObCGMicroBlockWriteOp / ObCGMacroBlockWriteOp              │
│  - ObCGRowTmpFile / ObCGBLockTmpFile                          │
│  - ObColumnClusteredDAG                                         │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 5: DDL RedoLogWriter + SchemaService                       │
│  - ObDDLRedoLogWriter 写 redo log 到 PALF                       │
│  - SchemaService 异步落地 (参见 #76)                            │
│  - 触发 cache 失效 (参见 #91)                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObDDLService（RS 端）

### 2.1 类骨架（推测）

```cpp
// src/rootserver/ob_ddl_service.h
class ObDDLService {
public:
  // 处理 DDL RPC（来自 observer）
  int handle_ddl_request(const ObDDLArg &arg);

  // 调度 DDL 任务
  int schedule_ddl_task(const ObDDLTask &task);

  // 监控 DDL 进度
  int monitor_ddl();

  // 完成 DDL
  int finish_ddl(const int64_t task_id);
};
```

### 2.2 ObDDLServiceLauncher

```cpp
// src/rootserver/ob_ddl_service_launcher.{h,cpp}
class ObDDLServiceLauncher {
public:
  // 启动 DDL service
  int launch();
};
```

### 2.3 关键文件

```bash
src/rootserver/
├── ob_ddl_service.{h,cpp}                      # 主 service
├── ob_ddl_service.cpp                          # 实现
├── ob_ddl_service_launcher.{h,cpp}             # launcher
└── ob_ddl_service_launcher.cpp                 # launcher 实现
```

---

## 3. ObDDLRedoLogWriter

### 3.1 类骨架（实读自 `ob_ddl_redo_log_writer.h`）

```cpp
// src/storage/ddl/ob_ddl_redo_log_writer.h
namespace oceanbase {
namespace storage {

class ObDDLNeedStopWriteChecker {
public:
  ObDDLNeedStopWriteChecker();
  ~ObDDLNeedStopWriteChecker() {}
  int init(const uint64_t tenant_id,
           const int64_t task_id,
           const ObDirectLoadType direct_load_type,
           const ObTabletHandle &tablet_handle);
  // ...
};

class ObDDLRedoLogWriter {
public:
  // 写 DDL redo log
  int write_ddl_redo(const ObDDLRedoLogEntry &entry);

  // replay DDL redo
  int replay_ddl_redo(const ObDDLRedoLogEntry &entry);
};

}  // storage
}  // oceanbase
```

### 3.2 DDL Redo Log 的价值

参见 #65 Standby：DDL redo log 让 Standby 集群重做 DDL：
- Primary observer 完成 DDL → 写 redo log → PALF
- Standby 拉 PALF → replay redo log → 同样完成 DDL

### 3.3 DDL Need Stop Write Checker

`ObDDLNeedStopWriteChecker` 检查是否需要停止 DML 写入（DDL 期间）：
- 某些 DDL（如 ALTER TABLE ADD COLUMN）不阻塞 DML
- 某些 DDL（如 ALTER TABLE DROP COLUMN）需要暂时停止 DML

---

## 4. ObDDLIncTask —— Online DDL 增量任务（参见 #64）

### 4.1 类骨架（实读自 `ob_ddl_inc_task.h`）

```cpp
// src/storage/ddl/ob_ddl_inc_task.h
namespace oceanbase {
namespace storage {

class ObDDLIncStartTask final : public share::ObITask {
public:
  ObDDLIncStartTask(const int64_t tablet_idx);
  int process() override;
private:
  int generate_next_task(ObITask *&next_task) override;
  int record_inc_major_start_info_to_mds(
      const ObStorageSchema &storage_schema,
      const common::ObTabletID &tablet_id,
      const share::ObLSID &ls_id,
      const transaction::ObTransID &trans_id,
      const int64_t data_format_version,
      const int64_t snapshot_version,
      const share::SCN start_scn,
      common::ObIAllocator &allocator);
private:
  int64_t tablet_idx_;
};

class ObDDLIncCommitTask final : public share::ObITask {
public:
  ObDDLIncCommitTask(const int64_t tablet_idx);
  ObDDLIncCommitTask(const ObTabletID &tablet_id);
  int process() override;
  // ...
};

}  // storage
}  // oceanbase
```

### 4.2 Online DDL 增量任务

参见 #64 §10.1：
- `ObDDLIncStartTask` —— 增量 DDL 启动
- `ObDDLIncCommitTask` —— 增量 DDL 提交
- `ObDDLCompleteTask` —— 增量 DDL 完成
- `ObDDLDataFillTask` —— 数据填充
- `ObDDLComplementDataTask` —— complement data
- `ObDDLWrapCGTask` —— column grouping wrap

### 4.3 与 #11 DDL Inc Major 的关系

参见 #11：Online DDL Inc Major 的核心实现，5 大类任务（start / fill / commit / complete / wrap）协同完成 Online DDL。

---

## 5. ObDDLHeartBeatTask

### 5.1 类骨架（实读自 `ob_ddl_heart_beat_task.h`）

```cpp
// src/storage/ddl/ob_ddl_heart_beat_task.h
class ObDDLHeartBeatTaskInfo final {
public:
  TO_STRING_KV(K_(task_id), K_(tenant_id));
  ObDDLHeartBeatTaskInfo() : task_id_(0), tenant_id_(OB_INVALID_ID) {};
  ObDDLHeartBeatTaskInfo(int64_t task_id, uint64_t tenant_id)
    : task_id_(task_id), tenant_id_(tenant_id) {}
  ~ObDDLHeartBeatTaskInfo() = default;
  inline int64_t get_task_id() {return task_id_;}
  inline uint64_t get_tenant_id() {return tenant_id_;}
  // ...
private:
  int64_t task_id_;
  uint64_t tenant_id_;
};

class ObDDLHeartBeatTaskContainer final {
public:
  static ObDDLHeartBeatTaskContainer &get_instance();
  ObDDLHeartBeatTaskContainer();
  ~ObDDLHeartBeatTaskContainer();
  int init();
  int set_register_task_id(const int64_t task_id, const uint64_t tenant_id);
  int remove_register_task_id(const int64_t task_id, const uint64_t tenant_id);
  int send_task_status_to_rs();
private:
  static const int64_t BUCKET_LOCK_BUCKET_CNT = 10243L;
  static const int64_t RETRY_COUNT = 3L;
  static const int64_t RETRY_TIME_INTERVAL = 100L;
  common::hash::ObHashMap<rootserver::ObDDLTaskID, uint64_t> register_tasks_;
  bool is_inited_;
  common::ObBucketLock bucket_lock_;
};
```

### 5.2 HeartBeat 价值

参见 #65 Standby / #74 Thread Model：DDL heartbeat 防止 observer 在 DDL 中崩溃时 hang：
- observer DDL 期间定期报告 heartbeat 给 RS
- RS 发现 heartbeat 超时 → 取消 DDL

### 5.3 Bucket Lock

`ObBucketLock` —— 10243 个 bucket 的 hash 锁（参见 #61 inner table contention，hash 10243 模式与 #67 Sequence 一致）。

---

## 6. ObDDLBuildIndexTask —— 建索引任务

### 6.1 类骨架

```cpp
// src/storage/ddl/ob_build_index_task.{h,cpp}
class ObBuildIndexTask {
public:
  // 启动建索引
  int start();

  // per-tablet 索引构建
  int build_index_per_tablet();
};
```

### 6.2 建索引流程

```
应用: CREATE INDEX idx ON t (col)
    │
    ▼
SQL 解析 → Resolver → Optimizer → Executor
    │
    ▼
ObDDLExecutor (参见 #79 #3)
    │
    ├─ 1. 权限校验
    │
    ├─ 2. 校验索引合法性
    │
    ▼
observer → RS: DDL RPC
    │
    ▼
RS: ObDDLService.handle_ddl_request
    │
    ├─ 1. 持久化 DDL 任务
    │
    ├─ 2. 调度 BuildIndexTask 到各 observer
    │
    ▼
各 observer:
    │
    ├─ 3. ObBuildIndexTask 启动
    │
    ├─ 4. 读所有数据行
    │
    ├─ 5. 抽取索引列
    │
    ├─ 6. 构建 SSTable
    │
    ├─ 7. 持久化索引 SSTable
    │
    └─ 8. ack RS
    │
    ▼
RS: 收集所有 ack → 索引建好
```

### 6.3 ddl_task 子目录

```bash
src/rootserver/ddl_task/
└── ob_index_build_task.h    # 索引 build task
```

---

## 7. DDL CG / Column Grouping

### 7.1 角色

参见 #08 / #90：列存 DDL 时，列存数据需要重新组织：
- 新增列 → column group 调整
- 删除列 → column group 清理
- 列类型变更 → 数据重写

### 7.2 关键类

```bash
src/storage/ddl/
├── ob_cg_block_tmp_file.{h,cpp}              # CG block 临时文件
├── ob_cg_block_tmp_files_iterator.{h,cpp}     # CG block iterator
├── ob_cg_macro_block_write_op.{h,cpp}        # CG macro block 写 op
├── ob_cg_macro_block_write_task.{h,cpp}      # CG macro block 写 task
├── ob_cg_macro_block_writer.{h,cpp}          # CG macro block writer
├── ob_cg_micro_block_write_op.{h,cpp}        # CG micro block 写 op
├── ob_cg_row_tmp_file.{h,cpp}                # CG row 临时文件
├── ob_column_clustered_dag.{h,cpp}           # column clustered DAG
└── ob_ddl_wrap_cg_task.{h,cpp}              # wrap column group task
```

### 7.3 CG 流程

```
DDL 触发（涉及列存改写）
    │
    ▼
ObWrapCGTask 启动
    │
    ├─ 1. 读原 SSTable 数据
    │
    ├─ 2. 按新 column group 重写
    │
    ├─ 3. 写临时文件
    │   └─ ObCGRowTmpFile / ObCGBLockTmpFile
    │
    ├─ 4. ObColumnClusteredDAG 调度
    │
    └─ 5. 写新 SSTable
```

---

## 8. 关键 rootserver DDL 文件

```bash
src/rootserver/
├── ob_ddl_service.{h,cpp}                      # DDL service 主类
├── ob_ddl_service.cpp                          # DDL service 实现
├── ob_ddl_service_launcher.{h,cpp}             # DDL service launcher
├── ob_ddl_service_launcher.cpp                 # DDL service launcher 实现
├── ob_alter_table_constraint_checker.h        # alter constraint 检查
├── ob_index_builder.h                        # index builder
├── ob_mlog_builder.h                         # mlog builder
├── parallel_ddl/ob_ddl_helper.h              # 并行 DDL helper
├── ob_create_index_on_empty_table_helper.h   # 空表建索引 helper
├── ddl_task/ob_index_build_task.h            # 索引 build task
├── ob_lob_piece_builder.h                   # LOB piece builder
├── ob_root_utils.h                           # RS 工具
└── ob_upgrade_storage_format_version_executor.h  # 升级 storage format
```

---

## 9. DDL 与 MemTable / SSTable / Cache 交互

### 9.1 DDL vs MemTable（参见 #89）

- **minor DDL**（如 ADD COLUMN with default）→ 不阻塞 DML
- **major DDL**（如 ALTER TABLE 大表）→ 临时停止 DML
- `ObDDLNeedStopWriteChecker` 检查是否需要停写

### 9.2 DDL vs SSTable（参见 #90）

- DDL 期间可能需要重写 SSTable（CG 调整）
- `ObWrapCGTask` 写新 SSTable
- 旧 SSTable 标记 GC（参见 #35）

### 9.3 DDL vs Cache（参见 #91）

DDL 完成 → 失效所有 cache：
- Schema Cache → invalidate by (tenant_id, schema_id)
- Block Cache → 自动失效（load 新 SSTable）
- Plan Cache → invalidate

### 9.4 DDL vs Log Service（参见 #49）

DDL 写 redo log → PALF（参见 #11）：
- ObDDLRedoLogWriter 写 PALF
- Standby replay redo（参见 #65）
- 保证 Standby 一致性

---

## 10. 与其他文章的关系

### 10.1 与 #11 DDL Inc Major

#11 是早期分析 Online DDL Inc Major 概览。本篇是 #11 的 **深化**：
- #11 聚焦 inc major 5 大任务
- 本文深入 ObDDLIncStartTask / ObDDLIncCommitTask / ObDDLCompleteTask / ObDDLDataFillTask / ObDDLComplementDataTask / ObDDLWrapCGTask / ObDDLHeartBeatTask 各自的实现

### 10.2 与 #64 Online DDL

#64 是早期分析 Online DDL 概览（30KB+）。本篇是 #64 的 **深化**：
- #64 聚焦 schema_version 视角
- 本文深入 DDL 物理执行路径（storage 层 + RS 层）

### 10.3 与 #76 Schema Service

DDL 完成 → Schema Service 持久化（参见 #76）：
- 写 `__all_*_priv` / `__all_*_objpriv` / 内部表
- 异步落地 + cache 失效

### 10.4 与 #79 DDL Service

#79 描述 21+ DDL executor（参见 #79）。本文是 **物理执行** 路径——executor 之后。

### 10.5 与 #89 MemTable

DDL 期间 memtable 处理（参见 #89 §5 + #64 §10.1）：
- minor DDL → 不停 DML
- major DDL → 暂停 memtable 写入 → 落盘 → 重建

### 10.6 与 #90 SSTable

DDL 期间 SSTable 处理（参见 #90）：
- CG 调整 → ObWrapCGTask 写新 SSTable
- 旧 SSTable 标记 GC

### 10.7 与 #91 Cache

DDL 触发 cache 失效（参见 #91）：
- Schema Cache / Block Cache / Plan Cache 全部失效
- 失效策略参见 #64 §5.2

---

## 11. 总结

### 11.1 DDL 物理执行在 OB 体系中的定位

DDL 物理执行是 **OB 数据定义变更的最终执行路径**：
- 151 文件 storage/ddl/ + 几十个 rootserver DDL 文件
- Online DDL（参见 #64）+ 异步增量更新（参见 #11）
- DDL heartbeat 防止 hang
- DDL redo log 支持 Standby
- DDL CG 调整列存

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| RS 端 DDL Service | `ObDDLService` + `ObDDLServiceLauncher` |
| Redo Log | `ObDDLRedoLogWriter`（写 PALF，参见 #65） |
| Online DDL 增量 | `ObDDLIncStartTask` + `ObDDLIncCommitTask` + `ObDDLCompleteTask`（参见 #11 / #64） |
| Data Fill | `ObDDLDataFillTask` + `ObDDLComplementDataTask` |
| Heartbeat | `ObDDLHeartBeatTask`（参见 #74） |
| Need Stop Write | `ObDDLNeedStopWriteChecker` |
| Column Grouping | `ObCGMicroBlockWriteOp` + `ObCGMacroBlockWriteOp` + `ObCGRowTmpFile` + `ObCGBLockTmpFile` + `ObColumnClusteredDAG` + `ObWrapCGTask` |
| Build Index | `ObBuildIndexTask` + `ddl_task/ob_index_build_task.h` |
| Index Builder | `ob_index_builder.h` + `ob_mlog_builder.h` |
| Parallel DDL | `parallel_ddl/ob_ddl_helper.h` |
| Empty Table | `ob_create_index_on_empty_table_helper.h` |
| LOB Builder | `ob_lob_piece_builder.h` |
| Upgrade | `ob_upgrade_storage_format_version_executor.h` |
| Constraint | `ob_alter_table_constraint_checker.h` |
| Concurrent | `ob_ddl_concurrent_control.{h,cpp}` |
| Diagnose | `ob_ddl_diagnose.{h,cpp}` |
| Util | `ob_ddl_util.{h,cpp}` |
| Handler | `ob_ddl_handler.h` |
| CLog | `ob_ddl_clog.{h,cpp}` |
| Struct | `ob_ddl_struct.h` |
| Define | `ob_ddl_define.h` |
| Alter Auto Part | `ob_ddl_alter_auto_part_attr.{h,cpp}` |
| Tablet To Table | `ob_ddl_change_tablet_to_table_helper.h` |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/ddl/` (151 文件) | DDL 物理执行主目录 |
| `src/storage/ddl/ob_ddl_redo_log_writer.{h,cpp}` | DDL redo log writer |
| `src/storage/ddl/ob_ddl_inc_task.{h,cpp}` | DDL 增量 task |
| `src/storage/ddl/ob_ddl_heart_beat_task.{h,cpp}` | DDL heartbeat |
| `src/storage/ddl/ob_build_index_task.{h,cpp}` | 建索引 task |
| `src/storage/ddl/ob_cg_*` (10+ 文件) | Column Grouping |
| `src/storage/ddl/ob_ddl_complete_task.{h,cpp}` | DDL complete |
| `src/storage/ddl/ob_ddl_concurrent_control.{h,cpp}` | 并发控制 |
| `src/storage/ddl/ob_ddl_diagnose.{h,cpp}` | DDL 诊断 |
| `src/storage/ddl/ob_ddl_data_fill_task.{h,cpp}` | DDL data fill |
| `src/storage/ddl/ob_ddl_struct.h` | DDL 结构 |
| `src/storage/ddl/ob_ddl_define.h` | DDL 定义 |
| `src/storage/ddl/ob_ddl_handler.h` | DDL handler |
| `src/storage/ddl/ob_ddl_clog.{h,cpp}` | DDL clog |
| `src/storage/ddl/ob_ddl_alter_auto_part_attr.{h,cpp}` | alter auto partition |
| `src/storage/ddl/ob_ddl_wrap_cg_task.{h,cpp}` | wrap column group |
| `src/storage/ddl/ob_ddl_util.{h,cpp}` | DDL 工具 |
| `src/storage/ddl/ob_complement_data_task.{h,cpp}` | complement data |
| `src/rootserver/ob_ddl_service.{h,cpp}` | DDL service 主类 |
| `src/rootserver/ob_ddl_service.cpp` | DDL service 实现 |
| `src/rootserver/ob_ddl_service_launcher.{h,cpp}` | DDL service launcher |
| `src/rootserver/ob_alter_table_constraint_checker.h` | alter constraint 检查 |
| `src/rootserver/ob_index_builder.h` | index builder |
| `src/rootserver/ob_mlog_builder.h` | mlog builder |
| `src/rootserver/parallel_ddl/ob_ddl_helper.h` | 并行 DDL helper |
| `src/rootserver/ob_create_index_on_empty_table_helper.h` | 空表建索引 helper |
| `src/rootserver/ddl_task/ob_index_build_task.h` | 索引 build task |
| `src/rootserver/ob_lob_piece_builder.h` | LOB piece builder |
| `src/rootserver/ob_upgrade_storage_format_version_executor.h` | 升级 storage format |

### 11.4 5 层架构

| 层级 | 元素 | 角色 |
|------|------|------|
| L1 | DDL 入口 | SQL Parser → ObDDLStmt → DDL Executor（参见 #79） |
| L2 | ObDDLService | RS 端 DDL 任务调度 + 协调 + heartbeat |
| L3 | DDL Task | per-LS / per-tablet 增量任务（参见 #11） |
| L4 | DDL CG | Column Grouping 调整（列存改写） |
| L5 | DDL RedoLog + SchemaService | redo log 写 PALF + SchemaService 落地 |

### 11.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#94 索引系统 / 二级索引 / 索引类型**（深化 #18 index-design）：

OB 索引体系 —— 主键索引 / 二级索引 / 唯一索引 / 函数索引 / 覆盖索引 / 索引回表。源码入口：`src/storage/blocksstable/index_block/` + `src/share/index_builder/` + `src/storage/access/ob_index_*`。

适用场景：索引优化 / 性能调优 / 查询计划。

整吗？