# 09-sql-executor — SQL 执行器与存储层的交互（DAS 层）

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

前 8 篇文章覆盖了 MVCC 层（行结构、Iterator、写冲突、回调）、memtable、compaction、SSTable、LS Tree。现在是时候回答一个关键问题：**SQL 执行器如何实际访问存储层的数据？**

OceanBase 的答案是 **DAS（Data Access Service）架构**——一个介于 SQL 执行器和存储引擎之间的中间层。SQL 算子不直接调用存储引擎 API，而是通过 DAS 创建"任务"（Task），由 DAS 负责任务的路由、执行、结果收集和错误处理。

```
SQL Operator（TableScan / Insert / Update / Delete）
    │
    ▼
DAS Task（ObDASScanTask / ObDASInsertTask / ...）
    │
    ├─→ DAS Location Router → 定位 Tablet / LS
    │
    ▼
Storage Layer（ObTableScanIterator / ObMvccIterator / ObMemtable）
```

**DAS 的设计动机**：

1. **解耦 SQL 执行器与存储引擎**：SQL 层只需要创建 DAS 任务，不关心数据在本地还是远端
2. **支持跨节点访问**：DAS 任务可以被序列化后 RPC 发送到远端节点执行
3. **统一错误处理与重试**：DAS 层封装了位置路由刷新、RPC 重试、分区迁移等复杂逻辑
4. **并行执行的基础**：DAS 任务可以分发给多个 worker 并行执行，为 PX（并行执行）提供基础

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 01-mvcc-row | DAS DML 操作最终调用 `mvcc_write` 写入版本节点 |
| 02-mvcc-iterator | DAS Scan 内部创建 `ObTableScanIterator`，即 MVCC Iterator 的封装 |
| 03-write-conflict | DML 服务中的冲突检测，连接 MVCC 的写写冲突机制 |
| 04-callback | DAS DML 任务中回调注册，在事务提交时触发 |
| 07-ls-logstream | DAS 位置路由定位到 LS，DAS 任务在对应 LS 上执行 |
| 08-ob-sstable | Scan 操作最终读取 SSTable + Memtable 中的行数据 |

---

## 1. 整体架构：SQL → DAS → Storage

### 1.1 三层架构

```
┌──────────────────────────────────────────────────────────┐
│                     SQL 执行器层                           │
│                                                          │
│  ObTableScanOp    ObTableInsertOp   ObTableUpdateOp       │
│       │                │                │                 │
│    DAS Scan        DAS Insert       DAS Update            │
│    (prepare_das_task → create_one_das_task)               │
└──────────────────────┬───────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────┐
│                   DAS 数据访问服务层                        │
│                                                          │
│  ObDataAccessService                                      │
│    ├─ execute_das_task() → 本地 / RPC 执行                │
│    ├─ do_local_das_task()  → 直接调用存储引擎              │
│    └─ do_async_remote_das_task() → RPC 发送到远端节点      │
│                                                          │
│  位置路由层：                                              │
│    ObDASLocationRouter                                     │
│    └─ 给定 TabletID → 定位 ObDASTabletLoc (LS + Server)  │
└──────────────────────┬───────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────┐
│                   存储引擎层                                │
│                                                          │
│  ObTableScanIterator    ObMvccIterator                    │
│  ObMemtable::scan       ObSSTable::scan                   │
│  mvcc_write / mvcc_read  (连接 01-08 文章)                 │
└──────────────────────────────────────────────────────────┘
```

### 1.2 数据流：完整的 SQL 扫描请求

```
用户 SQL: SELECT * FROM t1 WHERE id = 5
    │
    ▼
SQL 优化器生成执行计划，其中包含 ObTableScanOp
    │
    ▼
ObTableScanOp::inner_open()
    ├─ init_table_scan_rtdef()    → 初始化运行时定义
    ├─ init_das_scan_rtdef()      → 初始化 DAS Scan 运行时定义
    ├─ prepare_scan_range()       → 提取扫描范围（query range）
    │
    ▼
ObTableScanOp::prepare_all_das_tasks()
    ├─ create_one_das_task()      → 为每个 Tablet 创建一个 DAS Scan Task
    │   └─ ObDASScanOp: 继承 ObIDASTaskOp
    │       └─ 设置 scan_ctdef_ / scan_rtdef_ / tablet_loc_
    │
    ▼
ObDataAccessService::execute_das_task()
    ├─ ObDASLocationRouter 定位 Tablet
    ├─ 本地：do_local_das_task()
    └─ 远端：do_async_remote_das_task()
        │
        ▼
ObDASScanOp::open_op()
    ├─ init_scan_param()          → 填充 ObTableScanParam
    ├─ get_tsc_service().table_scan() → 真正调用存储引擎
    │   └─ 返回 ObNewRowIterator
    └─ create_das_iter_tree() → 包装为 DAS Iter
        │
        ▼
ObTableScanOp::inner_get_next_row()
    └─ get_next_row_with_das()   → 从 DAS Iter 获取行数据
```

---

## 2. 核心数据结构

### 2.1 ObTableScanOp——SQL 层的表扫描算子

**文件**：`src/sql/engine/table/ob_table_scan_op.h` @ L544

```cpp
// ob_table_scan_op.h:544-869 - doom-lsp 确认
class ObTableScanOp : public ObOperator
{
  // ...
  int inner_open() override;           // 打开算子，创建 DAS 任务（L556）
  int inner_get_next_row() override;   // 逐行输出结果（L559）
  int inner_get_next_batch(const int64_t max_row_cnt) override; // 批量输出（L560）
  int inner_close() override;          // 关闭算子（L561）

protected:
  int prepare_das_task();              // 准备 DAS 任务（L694）
  int create_one_das_task(ObDASTabletLoc *tablet_loc); // 为一个 Tablet 创建 DAS Scan（L698）
  int do_table_scan();                 // 执行表扫描（L702）
  int get_next_row_with_das();         // 通过 DAS 获取下一行（L703）

private:
  DASOpResultIter scan_result_;        // DAS 结果迭代器（L818）
  ObTableScanRtDef tsc_rtdef_;         // 运行时定义（scan + lookup）（L819）
  ObDASIter *output_;                  // 输出迭代器（L849）
  ObDASMergeIter *scan_iter_;          // Scan 迭代器（L860）
};
```

**关键方法**：

- **`inner_open()`**（`ob_table_scan_op.cpp`）：调用 `prepare_all_das_tasks()`，遍历所有 Tablet 位置，为每个位置调用 `create_one_das_task()`
- **`create_one_das_task()`**：创建 `ObDASScanOp` 实例，填充其 `scan_ctdef_`（编译时定义）和 `scan_rtdef_`（运行时定义），调用 `ObDataAccessService::execute_das_task()`
- **`get_next_row_with_das()`**：循环调用 `scan_result_.get_next_row()`，从 DAS 迭代器中逐行获取结果

**ObTableScanOp 的层次结构**：

```
ObTableScanOp
  ├── my_spec_ → ObTableScanSpec（编译时信息）
  │     └── tsc_ctdef_ → ObTableScanCtDef（L155）
  │           ├── scan_ctdef_  → ObDASScanCtDef（主表扫）
  │           ├── lookup_ctdef_ → ObDASScanCtDef（索引回表）
  │           └── attach_spec_  → 附加信息
  │
  └── tsc_rtdef_ → ObTableScanRtDef（运行时信息）（L259）
        └── scan_rtdef_ → ObDASScanRtDef（L283）
              ├── key_ranges_ → 查询范围
              ├── scan_flag_  → 扫描标志
              └── p_pd_expr_op_ → 下推表达式算子
```

**CTDef vs RtDef 的设计模式**：OceanBase 将算子定义分为编译时（CTDef，Compile-Time Definition）和运行时（RtDef，Run-Time Definition）两部分。CTDef 在计划生成时确定，包含表结构、列 ID、表达式等不变信息；RtDef 在每次执行时重新初始化，包含查询范围、事务快照等执行上下文。

### 2.2 ObDataAccessService——DAS 核心服务

**文件**：`src/sql/das/ob_data_access_service.h` @ L28

```cpp
// ob_data_access_service.h:28-92 - doom-lsp 确认
class ObDataAccessService
{
public:
  int execute_das_task(ObDASRef &das_ref,
      ObDasAggregatedTask &task_ops, bool async = true);
  int end_das_task(ObDASRef &das_ref, ObIDASTaskOp &task_op);
  int rescan_das_task(ObDASRef &das_ref, ObDASScanOp &scan_op);
  int retry_das_task(ObDASRef &das_ref, ObIDASTaskOp &task_op);

private:
  int execute_dist_das_task(ObDASRef &das_ref,
      ObDasAggregatedTask &task_ops, bool async = true);
  int do_local_das_task(ObIArray<ObIDASTaskOp*> &task_list);
  int do_async_remote_das_task(ObDASRef &das_ref,
                               ObDasAggregatedTask &aggregated_tasks,
                               ObDASTaskArg &task_arg,
                               int32_t group_id);
  int refresh_task_location_info(ObDASRef &das_ref, ObIDASTaskOp &task_op);

private:
  obrpc::ObDASRpcProxy das_rpc_proxy_;  // RPC 代理
  ObDASTaskResultMgr task_result_mgr_;   // 任务结果管理器
};
```

**`execute_das_task()` 的决策流程**（doom-lsp 数据流推理）：

```
execute_das_task()
  ├─ 遍历 task_ops 中的每个 ObIDASTaskOp
  │
  ├─ 按 tablet_loc_.server_ 分组到 ObDasAggregatedTask
  │     ├─ 同一节点的任务聚合到一个聚合任务
  │     └─ 不同节点各自独立
  │
  ├─ 对每个聚合任务：
  │     ├─ 本地节点 → do_local_das_task()
  │     │     └─ 直接调用 task_op->open_op()
  │     │
  │     └─ 远端节点 → do_async_remote_das_task()
  │           ├─ 序列化 DAS 任务参数到 ObDASTaskArg
  │           ├─ 通过 RPC 调用远端节点的 ObDASRpcProxy
  │           └─ 异步等待结果
  │
  └─ 错误处理：
        ├─ 如果 RPC 失败 → refresh_task_location_info() 重试
        └─ 如果位置信息过期 → 重新路由
```

### 2.3 ObIDASTaskOp——DAS 任务基类

**文件**：`src/sql/das/ob_das_task.h` @ L150

```cpp
// ob_das_task.h:150-300 - doom-lsp 确认
class ObIDASTaskOp
{
public:
  virtual int open_op() = 0;      // 执行 DAS Task Op 逻辑
  virtual int release_op() = 0;   // 释放资源
  virtual const ObDASBaseCtDef *get_ctdef() const { return nullptr; }
  virtual ObDASBaseRtDef *get_rtdef() { return nullptr; }

  int set_tablet_id(const common::ObTabletID &tablet_id);
  int set_ls_id(const share::ObLSID &ls_id);
  int set_tablet_loc(const ObDASTabletLoc *tablet_loc);

protected:
  ObDASOpType op_type_;            // DAS_OP_TABLE_SCAN / INSERT / UPDATE / DELETE / LOCK
  const ObDASTabletLoc *tablet_loc_;  // Tablet 位置信息
  transaction::ObTxDesc *trans_desc_;  // 事务描述符
  transaction::ObTxReadSnapshot *snapshot_;  // MVCC 快照
};
```

### 2.4 DAS 任务类型——ObDASOpType

**文件**：`src/sql/das/ob_das_define.h` @ L73

```cpp
// ob_das_define.h:73-112 - doom-lsp 确认
enum ObDASOpType
{
  DAS_OP_INVALID = 0,
  DAS_OP_TABLE_SCAN,          // 扫描
  DAS_OP_TABLE_INSERT,        // 插入
  DAS_OP_TABLE_UPDATE,        // 更新
  DAS_OP_TABLE_DELETE,        // 删除
  DAS_OP_TABLE_LOCK,          // 锁定
  DAS_OP_TABLE_BATCH_SCAN,    // 批量扫描
  DAS_OP_TABLE_LOOKUP,        // 索引回表
  DAS_OP_IR_SCAN,             // 全文检索扫描
  DAS_OP_VEC_SCAN,            // 向量搜索扫描
  DAS_OP_INDEX_MERGE,         // 索引合并
  // ... 更多
  DAS_OP_MAX
};
```

每种任务类型对应一个具体的 TaskOp 类：

| 任务类型 | 类名 | 文件 |
|---------|------|------|
| `DAS_OP_TABLE_SCAN` | `ObDASScanOp` | `ob_das_scan_op.h` |
| `DAS_OP_TABLE_INSERT` | `ObDASInsertOp` | `ob_das_insert_op.h` |
| `DAS_OP_TABLE_UPDATE` | `ObDASUpdateOp` | `ob_das_update_op.h` |
| `DAS_OP_TABLE_DELETE` | `ObDASDeleteOp` | `ob_das_delete_op.h` |
| `DAS_OP_TABLE_LOCK` | `ObDASLockOp` | `ob_das_lock_op.h` |

---

## 3. DAS Scan 操作深度分析

### 3.1 ObDASScanOp——DAS 扫描算子

**文件**：`src/sql/das/ob_das_scan_op.h` @ L404

```cpp
// ob_das_scan_op.h:404-536 - doom-lsp 确认
class ObDASScanOp : public ObIDASTaskOp
{
public:
  virtual int open_op() override;    // 执行扫描
  virtual int release_op() override; // 释放资源

  int init_scan_param();             // 填充 ObTableScanParam
  int rescan();                      // 重新扫描

protected:
  common::ObITabletScan &get_tsc_service();  // 获取存储层扫描服务
  common::ObNewRowIterator *get_output_result_iter() { return result_; }
  int create_iter_tree_and_init_tablet_ids(const ObDASIterTreeType &tree_type,
                                         ObDASIter *&result);

protected:
  storage::ObTableScanParam scan_param_; // 扫描参数（key_ranges, scan_flag 等）
  const ObDASScanCtDef *scan_ctdef_;     // 编译时定义
  ObDASScanRtDef *scan_rtdef_;           // 运行时定义
  common::ObNewRowIterator *result_;     // 实际是 ObDASIter
};
```

**`open_op()` 的执行流程**（doom-lsp 推理）：

```
ObDASScanOp::open_op()
  │
  ├─ init_scan_param()
  │   ├─ 从 scan_ctdef_ 填充 table_param, access_column_ids
  │   ├─ 从 scan_rtdef_ 填充 key_ranges, scan_flag, snapshot
  │   └─ 生成 ObTableScanParam
  │
  ├─ get_tsc_service().table_scan(scan_param_, result_)
  │   └─ 调用存储层的 TableScan 服务
  │       ├─ 本地 TableScan 返回 ObNewRowIterator
  │       └─ 内部串联 SSTable + Memtable + MVCC Iterator
  │
  └─ create_iter_tree_and_init_tablet_ids(...)
      ├─ 将原生 Iterator 包装为 DAS Iter 树
      ├─ 应用下推的 filter/aggregation
      └─ 设置相关的 Tablet ID
```

### 3.2 ObDASScanCtDef——扫描的编译时定义

```cpp
// ob_das_scan_op.h:70~ - doom-lsp 确认
struct ObDASScanCtDef : ObDASBaseCtDef
{
  ObDASBaseCtDef(DAS_OP_TABLE_SCAN),
  // 表标识
  common::ObTableID ref_table_id_;
  int64_t schema_version_;
  share::schema::ObTableParam table_param_;

  // 列访问
  UIntFixedArray access_column_ids_;   // 实际访问的列 ID
  sql::ExprFixedArray result_output_;  // 结果表达式（存储层填充值的）

  // 下推表达式
  ObPushdownExprSpec pd_expr_spec_;    // 下推的 filter、计算列表达式
  // 聚合下推
  UIntFixedArray aggregate_column_ids_; // 聚合列 ID
  UIntFixedArray group_by_column_ids_;  // 分组列 ID

  // 扫描范围
  ObQueryRange pre_query_range_;       // 查询范围
  bool is_get_;                        // 是否等值查询（单行 get）

  // Top-N 下推
  ObDASPushDownTopN push_down_topn_;   // 排序和 limit 下推
};
```

### 3.3 ObDASScanRtDef——扫描的运行时定义

```cpp
// ob_das_scan_op.h:300~ - doom-lsp 确认
struct ObDASScanRtDef : ObDASBaseRtDef
{
  ObPushdownOperator *p_pd_expr_op_;     // 下推表达式算子
  ObQueryFlag scan_flag_;                // 扫描标志（strong/weak read 等）
  common::ObSEArray<common::ObNewRange, 1> key_ranges_; // 查询范围
  int64_t timeout_ts_;                   // 超时时间戳
  int64_t tx_lock_timeout_;              // 事务锁超时

  bool need_scn_;                        // 是否需要 SCN 列（MVCC 可见性检查）
  bool force_refresh_lc_;                // 是否强制刷新位置缓存
  share::SCN fb_snapshot_;               // Flashback 快照版本

  ObTSCMonitorInfo *tsc_monitor_info_;   // 扫描监控信息
  ObDASScanTaskType task_type_;          // 任务类型（SCAN / LOCAL_LOOKUP / GLOBAL_LOOKUP）
};
```

### 3.4 DAS Scan 结果——ObDASScanResult

```cpp
// ob_das_scan_op.h:538~ - doom-lsp 确认
class ObDASScanResult : public ObIDASTaskResult, public common::ObNewRowIterator
{
  ObChunkDatumStore datum_store_;    // 行数据存储（列存格式）
  ObTempRowStore vec_row_store_;    // 向量行存储
  int64_t io_read_bytes_;           // IO 读取字节数
  int64_t ssstore_read_bytes_;      // SSD 读取字节数
  int64_t base_read_row_cnt_;       // 基础数据读取行数
  int64_t delta_read_row_cnt_;      // 增量数据（memtable）读取行数
};
```

**注意**：`ObDASScanResult` 统计了 `base_read_row_cnt_`（SSTable 中读取的行数）和 `delta_read_row_cnt_`（memtable 中读取的行数），这对理解 LSM-Tree 的读放大非常有价值。

---

## 4. DAS Insert / Update / Delete 操作

### 4.1 ObDASInsertOp——DAS 插入操作

**文件**：`src/sql/das/ob_das_insert_op.h`

```cpp
// ob_das_insert_op.h - doom-lsp 确认
class ObDASInsertOp : public ObIDASTaskOp
{
  virtual int open_op() override;
  virtual int release_op() override;

  int write_row(const ExprFixedArray &row,       // 写入一行
                ObEvalCtx &eval_ctx,
                ObChunkDatumStore::StoredRow *&stored_row);

private:
  int insert_rows();                              // 批量插入
  int insert_row_with_fetch();                    // 插入并返回冲突行

  const ObDASInsCtDef *ins_ctdef_;               // 插入的编译时定义
  ObDASInsRtDef *ins_rtdef_;                     // 插入的运行时定义
  ObDASWriteBuffer insert_buffer_;               // 写入缓冲区
};
```

**数据流**：

```
ObTableInsertOp
  │
  ├─ 通过 DML 服务创建 DAS Insert Task
  │
  ▼
ObDASInsertOp::write_row()
  ├─ 将行数据缓存到 insert_buffer_
  │
  ├─ open_op() → insert_rows()
  │     ├─ 从 insert_buffer_ 中读取缓存的行
  │     ├─ 构造 ObDMLBaseParam
  │     ├─ 调用 ObAccessService::insert_row()
  │     │     └─ 最终调用 mvcc_write()（连接 01-mvcc-row）
  │     └─ 如果冲突 → ObDASConflictIterator 返回冲突行
  │
  └─ 如果没有冲突，DAS Result 返回 affected_rows_
```

### 4.2 ObDASUpdateOp——DAS 更新操作

**文件**：`src/sql/das/ob_das_update_op.h`

```cpp
// ob_das_update_op.h - doom-lsp 确认
class ObDASUpdateOp : public ObIDASTaskOp
{
  virtual int open_op() override;
  int write_row(const ExprFixedArray &row,
                ObEvalCtx &eval_ctx,
                ObChunkDatumStore::StoredRow *&stored_row);

private:
  const ObDASUpdCtDef *upd_ctdef_;    // 更新的编译时定义
  ObDASUpdRtDef *upd_rtdef_;          // 更新的运行时定义
  ObDASWriteBuffer write_buffer_;     // 写入缓冲区
};
```

### 4.3 ObDASDeleteOp——DAS 删除操作

**文件**：`src/sql/das/ob_das_delete_op.h`

```cpp
// ob_das_delete_op.h - doom-lsp 确认
class ObDASDeleteOp : public ObIDASTaskOp
{
  virtual int open_op() override;
  int write_row(const ExprFixedArray &row,
                ObEvalCtx &eval_ctx,
                ObChunkDatumStore::StoredRow *&stored_row);

private:
  const ObDASDelCtDef *del_ctdef_;
  ObDASDelRtDef *del_rtdef_;
  ObDASWriteBuffer write_buffer_;
};
```

### 4.4 写操作的统一模式

所有 DAS DML 操作遵循相同的模式：

```
DAS DML Op (Insert / Update / Delete)
  │
  ├─ 上层 SQL 算子调用 write_row()
  │     ├─ 将行数据存入 ObDASWriteBuffer（内存缓冲区）
  │     └─ 当缓冲区满或显式 flush 时触发批量写入
  │
  ├─ open_op() → 批量写入存储引擎
  │     ├─ 读取缓冲区中的数据
  │     ├─ 构造 ObDMLBaseParam（含事务上下文、冲突检查参数）
  │     ├─ 调用 ObAccessService::insert_row() / update_row() / delete_row()
  │     └─ 最终调用存储层的 mvcc_write()（连接 01-mvcc-row）
  │
  └─ 结果 → ObIDASTaskResult（affected_rows / conflict info）
```

**写缓冲区（ObDASWriteBuffer）**：`src/sql/das/ob_das_dml_ctx_define.h` @ L279。写操作不会立即发送到存储引擎，而是先缓存在缓冲区中。这有几个好处：

1. **批量提交**：多个写操作可以一次网络 RPC 发送到远端节点
2. **内存限制**：当缓冲区超过内存限制时，触发 flush，避免 OOM
3. **事务语义**：所有写操作在一个事务上下文中，提交时才真正持久化

### 4.5 与 MVCC 层的连接

DAS DML 操作的最终路径：

```
DAS Insert / Update / Delete
    │
    ▼
ObAccessService::insert_row()  (or update/delete)
    │
    ├─ 初始化 ObStoreCtx（含 mvcc_acc_ctx_）
    ├─ 创建 ObMvccTransNode（连接 01: ob_mvcc_row.h L71）
    │
    ├─ ObMvccRow::mvcc_write()（连接 01: ob_mvcc_row.cpp L1048）
    │     ├─ 行锁检查（ObRowLatch）
    │     ├─ mvcc_write_() 插入版本节点到链表中
    │     └─ mvcc_sanity_check_() 写冲突检测（连接 03: write-conflict）
    │
    ├─ 注册事务回调（ObITransCallback）
    │     └─ 连接 04: callback 机制
    │
    └─ 事务提交时：
          ├─ Paxos 日志落盘
          ├─ trans_commit() 设置 F_COMMITTED
          └─ MVCC 版本持久化
```

---

## 5. 位置路由——DAS 任务到 Tablet/LS 的映射

**文件**：`src/sql/das/ob_das_location_router.h`

### 5.1 ObDASTabletLoc——Tablet 位置

```cpp
// ob_das_define.h:186-237 - doom-lsp 确认
struct ObDASTabletLoc
{
  common::ObTabletID tablet_id_;              // Tablet ID
  share::ObLSID ls_id_;                       // 所在的 LS ID
  common::ObAddr server_;                     // 所在服务器地址
  const ObDASTableLocMeta *loc_meta_;          // 位置元数据
  ObDASTabletLoc *next_;                       // 链表（同分区冲突链）
  // flags:
  bool in_retry_;                              // 是否重试中
  // 分区信息
  int64_t partition_id_;
  int64_t first_level_part_id_;
};
```

**关键字段**：
- `tablet_id_`：数据分片的唯一标识（对应一个分区的一个副本）
- `ls_id_`：日志流 ID，同 LS 中的数据共享一个日志同步域
- `server_`：该副本所在节点的地址，DAS 据此决定本地/远程执行
- `loc_meta_`：指向 `ObDASTableLocMeta`，包含表级别的位置信息

### 5.2 路由决策

```
ObDASCtx::location_router_
    │
    ├─ 输入：Tablet ID
    │
    ├─ ObDASLocationRouter.locate()
    │     ├─ 查本地缓存（ObDASTableLocCache）
    │     ├─ 缓存未命中 → 从 ObLocationService 获取
    │     └─ 返回 ObDASTabletLoc（包含 LS ID 和 Server Addr）
    │
    └─ 位置刷新：
          ├─ 如果 DAS 任务执行失败（RPC 超时、节点宕机）
          └─ refresh_task_location_info() → 清除缓存 → 重新路由
```

### 5.3 与 LS Tree 的关联（连接 07-ls-logstream）

位置路由的核心是将 Tablet 定位到 LS（LogStream），因为 OceanBase 的数据存储和同步是以 LS 为单位的。同一个 LS 上的所有 Tablet 共享：

- **Paxos 同步组**：所有写操作需要在 LS 内的多数派副本上同步日志
- **Memtable 共享**：同一 LS 内的 Memtable 冻结和转储是批量进行的
- **DAS 任务分组**：同一 LS 上的多个 DAS 任务可以聚合执行

```cpp
// ob_das_define.h:186-237 - 关键字段 LS ID
struct ObDASTabletLoc {
  share::ObLSID ls_id_;    // LS ID — 连接 07-ls-logstream
  common::ObAddr server_;  // 服务器地址 — RPC 目标
  // ...
};
```

---

## 6. DML 服务——写操作的 SQL 层封装

**文件**：`src/sql/engine/dml/ob_dml_service.h`

`ObDMLService` 是 SQL 层写操作的辅助类，提供了一系列静态方法。不直接包含 MVCC 写操作，但提供了写操作 SQL 层的语义检查和准备工作。

```cpp
// ob_dml_service.h - doom-lsp 确认 核心方法：
class ObDMLService
{
public:
  static int process_insert_row(const ObInsCtDef &ins_ctdef,
                                ObInsRtDef &ins_rtdef,
                                ObTableModifyOp &dml_op,
                                bool &is_check_cst_violated_ignored);

  static int check_rowkey_whether_distinct(const ObExprPtrIArray &row,
                                           DistinctType distinct_algo,
                                           // ...
                                           bool &is_dist);

  static int check_row_whether_changed(const ObUpdCtDef &upd_ctdef,
                                       ObUpdRtDef &upd_rtdef,
                                       ObEvalCtx &eval_ctx);

  static int check_lob_column_changed(ObEvalCtx &eval_ctx,
              const ObExpr& old_expr, ObDatum& old_datum,
              const ObExpr& new_expr, ObDatum& new_datum,
              int64_t& result);

  static int check_cascaded_reference(const ObExpr *expr,
                                      const ObExprPtrIArray &row);
};
```

**DML Service 的角色**：

1. **行数据校验**：`process_insert_row` → 检查列类型、NULL 约束、几何类型
2. **唯一性检查**：`check_rowkey_whether_distinct` → 确保 rowkey 唯一
3. **变化检测**：`check_row_whether_changed` → UPDATE 时检查列值是否真正变化
4. **级联检查**：`check_cascaded_reference` → 外键级联引用检查
5. **触发器处理**：`process_before_stmt_trigger` / `process_after_stmt_trigger`

**冲突检测连接**（连接 03-write-conflict）：当 DAS Insert/Update/Delete 执行到存储层时，`mvcc_write_()` 的 Case 6（ob_mvcc_row.cpp L808）检测到写写冲突——同一行的头节点被其他事务锁定，会返回 `OB_TRY_LOCK_ROW_CONFLICT`。这个错误码通过 DAS 任务结果传递回 SQL 层，触发锁等待或重试。

---

## 7. Pushdown 策略——计算下推到存储层

DAS 的一个重要设计是**谓词下推（Predicate Pushdown）**和**计算下推**。不是所有数据都拉到 SQL 层再过滤，而是尽可能在存储层处理。

### 7.1 可下推的计算类型

```
SQL 层计算            →    存储层下推
──────────────────────────────────
Filter (WHERE)        →    ObPushdownFilter / ObDASSortedFilterIter
Projection (SELECT columns) → access_column_ids_ 指定读取的列
Aggregation (GROUP BY) →    ObDASAggregationIter 聚合下推
Top-N (ORDER BY LIMIT) →    ObDASPushDownTopN 排序 + Limit 下推
Fulltext search       →    ObDASIRScan 全文检索
Vector search         →    ObDASVecScan 向量索引扫描
Index merge           →    ObDASIndexMergeIter 多索引合并
```

### 7.2 Pushdown 的实现

```cpp
// ob_das_scan_op.h:70 - ObDASScanCtDef 中的下推表达式
struct ObDASScanCtDef : ObDASBaseCtDef
{
  ObPushdownExprSpec pd_expr_spec_;    // 下推的 filter 和计算列表达式
  UIntFixedArray aggregate_column_ids_; // 聚合下推
  ObDASPushDownTopN push_down_topn_;    // Top-N 下推
};

// ob_das_scan_op.h:300 - ObDASScanRtDef 中的下推算子
struct ObDASScanRtDef : ObDASBaseRtDef
{
  ObPushdownOperator *p_pd_expr_op_;   // 下推的表达式算子
};
```

**下推执行流程**：

```
SQL 执行器
    │  WHERE a > 10 AND b = 'hello'
    ▼
ObDASScanCtDef::pd_expr_spec_
    ├─ pushdown_filters_ → [a > 10, b = 'hello']
    └─ calc_exprs_       → [计算列表达式]
    │
    ▼
存储层（create_das_iter_tree）
    └─ ObDASSortedFilterIter（排序过滤迭代器）
         └─ 在读取数据时同时应用 filter
```

**下推的好处**：
- **减少数据传输**：存储层提前过滤，SQL 层只收到满足条件的行
- **减少 SQL 层计算**：聚合、排序等下推到存储层，利用存储层的批量处理能力
- **向量化执行**：存储层可以进行向量化批量处理，提高 CPU 缓存利用率

---

## 8. DAS 与 PX（并行执行）的关系

DAS 是 PX 并行执行的基础架构。

### 8.1 DAS 任务的并行执行

```cpp
// ob_data_access_service.h:67 - doom-lsp 确认
int parallel_execute_das_task(common::ObIArray<ObIDASTaskOp *> &task_list);
int parallel_submit_das_task(ObDASRef &das_ref, ObDasAggregatedTask &agg_task);
int push_parallel_task(ObDASRef &das_ref, ObDasAggregatedTask &agg_task, int32_t group_id);
```

### 8.2 DAS 并行架构

```
PX Scheduler
    │
    ├─ 将 SQL 执行计划分片给多个 PX Worker
    │
    ├─ 每个 PX Worker 有自己的一组 DAS Task
    │     ├─ PX Worker 1: DAS Task [Tablet_1, Tablet_2, Tablet_3]
    │     ├─ PX Worker 2: DAS Task [Tablet_4, Tablet_5, Tablet_6]
    │     └─ PX Worker 3: DAS Task [Tablet_7, Tablet_8, Tablet_9]
    │
    └─ 每个 PX Worker 内：
          ObDataAccessService::execute_das_task()
              ├─ 本地任务 → 直接执行
              └─ 远程任务 → RPC 到远端节点
```

### 8.3 并行控制

```cpp
// ob_das_ref.h - doom-lsp 确认
struct DASParallelContext
{
  ObDasParallelType parallel_type_;    // SERIALIZATION / STREAMING / BLOCKING
  int64_t submitted_task_count_;       // 已提交任务数
  int64_t das_dop_;                    // DAS 并行度
};

struct DASRefCountContext
{
  int32_t max_das_task_concurrency_;   // 最大并发任务数
  int32_t das_task_concurrency_limit_; // 当前并发限制
  int acquire_task_execution_resource(int64_t timeout_ts); // 获取执行资源
};
```

---

## 9. DAS 任务的序列化与 RPC 执行

DAS 任务支持序列化后发送到远端节点执行，这是 OceanBase 分布式执行的核心能力。

### 9.1 ObDASRemoteInfo——远程执行上下文

```cpp
// ob_das_task.h:100 - doom-lsp 确认
struct ObDASRemoteInfo
{
  ObExecContext *exec_ctx_;                    // 执行上下文
  const ObExprFrameInfo *frame_info_;          // 表达式框架信息
  transaction::ObTxDesc *trans_desc_;          // 事务描述符
  transaction::ObTxReadSnapshot snapshot_;     // MVCC 快照
  common::ObSEArray<const ObDASBaseCtDef*, 2> ctdefs_;  // 编译时定义列表
  common::ObSEArray<ObDASBaseRtDef*, 2> rtdefs_;        // 运行时定义列表
  // flags:
  bool has_expr_;                              // 是否有表达式
  bool need_calc_expr_;                        // 是否需要计算表达式
  bool need_tx_;                               // 是否需要事务上下文
};
```

### 9.2 RPC 调用链

```
本地节点（控制器）                    远端节点（执行器）
    │                                      │
    ├─ ObDataAccessService::                │
    │   do_async_remote_das_task()          │
    │     │                                 │
    │     ├─ 序列化 DAS 任务到 ObDASTaskArg │
    │     │   (ctdefs + rtdefs + snapshot   │
    │     │    + trans_desc + key_ranges)   │
    │     │                                 │
    │     ├─ das_rpc_proxy_.execute()       │
    │     │   ───────────────────────────→  │
    │     │                RPC              │
    │     │                                 ├─ ObDASBaseAccessP 接收
    │     │                                 ├─ 反序列化任务参数
    │     │                                 ├─ ObDataAccessService::
    │     │                                 │   do_local_das_task()
    │     │                                 ├─ task_op->open_op()
    │     │                                 └─ 返回 ObDASTaskResp
    │     │   ←──────────────────────────  │
    │     │          RPC Result             │
    │     │                                 │
    │     ├─ 处理返回结果                    │
    │     └─ 如果有更多数据，继续请求         │
    │                                      │
    └─ 错误处理：                           │
          ├─ RPC 超时 → 重试                │
          └─ 位置变更 → refresh_location    │
```

### 9.3 反序列化 swizzling

```cpp
// ob_das_task.h ~ - doom-lsp 确认
virtual int swizzling_remote_task(ObDASRemoteInfo *remote_info);
```

当 DAS 任务被反序列化到远端节点时，需要"swizzle"（重新绑定）指针引用——CTDef 和 RtDef 中的表达式指针需要指向远端节点内存中的对应地址。这是 DAS 远程执行的关键技术细节。

---

## 10. DAS 迭代器树

DAS Scan 的结果不是简单的行迭代器，而是一个**迭代器树（Iter Tree）**，可以组合多种迭代器实现复杂的数据处理逻辑。

### 10.1 迭代器树类型

```cpp
// 从 ob_das_scan_op.h 推理的迭代器树类型
enum ObDASIterTreeType {
  DAS_ITER_TREE_SIMPLE,              // 简单扫描迭代器
  DAS_ITER_TREE_MERGE,               // 多范围合并迭代器
  DAS_ITER_TREE_LOOKUP,              // 索引回表迭代器
  DAS_ITER_TREE_GROUP_FOLD,          // 分组折叠迭代器（用于 NLJ Group Rescan）
  DAS_ITER_TREE_SORTED_FILTER,       // 排序过滤迭代器
  DAS_ITER_TREE_AGGREGATE,           // 聚合迭代器
  DAS_ITER_TREE_INDEX_MERGE,         // 索引合并迭代器
};
```

### 10.2 迭代器树示例

```
简单扫描（无下推）：
  ObTableScanIterator（原生）
      │
      ▼
  ObDASIter（包装）

带 Filter 下推的扫描：
  ObTableScanIterator（原生）
      │
      ▼
  ObDASSortedFilterIter（应用下推 filter）

索引回表扫描：
  ObLocalIndexLookupOp
      ├─ ObTableScanIterator（索引表扫描，获取 rowkey）
      └─ ObTableScanIterator（主表回表，获取完整行）

多 Tablet 扫描：
  ObDASMergeIter（合并多个 Tablet 的结果）
      ├─ ObDASIter（Tablet 1）
      ├─ ObDASIter（Tablet 2）
      └─ ObDASIter（Tablet 3）
```

---

## 11. 设计决策分析

### 11.1 为什么需要 DAS 中间层？

**不直接调用存储引擎 API 的原因**：

1. **位置透明性**：SQL 算子不感知数据位置，DAS 层负责路由到正确的节点
2. **统一错误处理**：存储层错误（分区迁移、节点宕机）由 DAS 层统一重试
3. **远程执行透明**：本地和远程使用完全相同的 TaskOp 接口，差异只在 `do_local_das_task` vs `do_async_remote_das_task`
4. **并行执行框架**：DAS 任务可以分组、排序、并行提交
5. **资源隔离**：DAS 层可以控制并发度（`das_concurrency_limit_`），避免存储层过载

### 11.2 CTDef vs RtDef 的设计模式

**为什么分为编译时和运行时两部分？**

- **CTDef（Compile-Time Definition）**：在计划生成时确定，跨执行可重用。包含列 ID、表达式定义、下推条件等
- **RtDef（Run-Time Definition）**：每次执行时重新初始化。包含查询范围、事务快照、扫描标志等

这个分离的好处：
- 减少序列化开销：远程执行时只需发送变化的 RtDef
- 缓存友好：CTDef 可以缓存复用
- 表达式共享：CTDef 中的表达式可以在多个执行中共享

### 11.3 Pushdown 策略

**什么可以下推，什么不能？**

| 可下推 | 不可下推 |
|--------|---------|
| 列过滤（projection） | 用户自定义函数（UDF） |
| 简单的 filter 条件 | 子查询表达式 |
| 聚合操作（COUNT/SUM/AVG） | 窗口函数 |
| Top-N 排序 + Limit | 多表关联 |
| 索引合并 | 复杂类型转换 |

**下推判断逻辑**（doom-lsp 确认 `ob_das_scan_op.h`）：
```cpp
virtual bool has_expr() const override { return true; }
virtual bool has_pdfilter_or_calc_expr() const override {
  return (!pd_expr_spec_.pushdown_filters_.empty() ||
          !pd_expr_spec_.calc_exprs_.empty());
}
virtual bool has_pl_udf() const override {
  // PL UDF 不能下推，需要在 SQL 层执行
  for (...) {
    has_pl_udf = (calc_expr->type_ == T_FUN_UDF);
  }
}
```

### 11.4 DAS 与 PX 的协作

DAS 的并行执行是 PX 的基础，但两者有不同的关注点：

| 维度 | DAS | PX |
|------|-----|----|
| 粒度 | 单个 DAS 任务（对应一个 Tablet） | 执行计划的分片 |
| 并行方式 | 多 Tablet 并发扫描 | 多线程并行执行 |
| 数据分发 | 任务级别的分发 | DTL（Data Transport Layer） |
| 执行者个数 | `DASRefCountContext` 控制 | `DASParallelContext` 控制 |

### 11.5 与 Iterator 设计的关系（连接 02-mvcc-iterator）

DAS Scan 内部创建的 `ObTableScanIterator` 是文章 02 中 `ObMvccIterator` 的上层封装：

```
ObDASScanOp
  └─ scan_param_ → ObTableScanParam
      └─ 传递给 get_tsc_service().table_scan()
          └─ 返回 ObNewRowIterator（实际是 ObTableScanIterator）
              └─ 内部创建 ObMvccIterator
                  ├─ iter_read() → 遍历 MVCC 版本链
                  └─ snapshot_version 判定可见性
```

DAS 层本身不涉及 MVCC 可见性判断，而是将 `scan_param_` 中的 `snapshot_version` 传递给存储层，由 `ObMvccIterator` 完成可见性判断。DAS 的角色是**桥梁**——确保正确的快照版本和扫描范围传递到存储层。

---

## 12. 源码文件索引

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/sql/engine/table/ob_table_scan_op.h` | `class ObTableScanOp` | 544 |
| `src/sql/engine/table/ob_table_scan_op.h` | `struct ObTableScanCtDef` | 155 |
| `src/sql/engine/table/ob_table_scan_op.h` | `struct ObTableScanRtDef` | 259 |
| `src/sql/engine/table/ob_table_scan_op.h` | `struct ObTableScanSpec` | 337 |
| `src/sql/engine/table/ob_table_scan_op.h` | `prepare_das_task()` | 694 |
| `src/sql/engine/table/ob_table_scan_op.h` | `create_one_das_task()` | 698 |
| `src/sql/engine/table/ob_table_scan_op.h` | `do_table_scan()` | 702 |
| `src/sql/engine/table/ob_table_scan_op.h` | `get_next_row_with_das()` | 703 |
| `src/sql/das/ob_data_access_service.h` | `class ObDataAccessService` | 38 |
| `src/sql/das/ob_data_access_service.h` | `execute_das_task()` | 50 |
| `src/sql/das/ob_data_access_service.h` | `do_local_das_task()` | 77 |
| `src/sql/das/ob_data_access_service.h` | `do_async_remote_das_task()` | 78 |
| `src/sql/das/ob_das_define.h` | `enum ObDASOpType` | 73 |
| `src/sql/das/ob_das_define.h` | `struct ObDASTabletLoc` | 186 |
| `src/sql/das/ob_das_define.h` | `struct ObDASTableLocMeta` | 119 |
| `src/sql/das/ob_das_define.h` | `struct ObDASTableLoc` | 281 |
| `src/sql/das/ob_das_define.h` | `struct ObDASBaseCtDef` | 371 |
| `src/sql/das/ob_das_define.h` | `struct ObDASBaseRtDef` | 397 |
| `src/sql/das/ob_das_task.h` | `class ObIDASTaskOp` | 144 |
| `src/sql/das/ob_das_task.h` | `struct ObDASRemoteInfo` | 100 |
| `src/sql/das/ob_das_task.h` | `struct ObDASGTSOptInfo` | 66 |
| `src/sql/das/ob_das_scan_op.h` | `class ObDASScanOp` | 400 |
| `src/sql/das/ob_das_scan_op.h` | `struct ObDASScanCtDef` | 70 |
| `src/sql/das/ob_das_scan_op.h` | `struct ObDASScanRtDef` | 300 |
| `src/sql/das/ob_das_scan_op.h` | `class ObDASScanResult` | 538 |
| `src/sql/das/ob_das_scan_op.h` | `class ObLocalIndexLookupOp` | 600 |
| `src/sql/das/ob_das_insert_op.h` | `class ObDASInsertOp` | 55 |
| `src/sql/das/ob_das_update_op.h` | `class ObDASUpdateOp` | 25 |
| `src/sql/das/ob_das_delete_op.h` | `class ObDASDeleteOp` | 25 |
| `src/sql/das/ob_das_location_router.h` | `class ObDASLocationRouter` | (路由方法) |
| `src/sql/das/ob_das_ref.h` | `struct ObDasAggregatedTask` | 95 |
| `src/sql/das/ob_das_ref.h` | `struct DASParallelContext` | 45 |
| `src/sql/das/ob_das_ref.h` | `struct DASRefCountContext` | 75 |
| `src/sql/das/ob_das_context.h` | `class ObDASCtx` | 70 |
| `src/sql/engine/dml/ob_dml_service.h` | `class ObDMLService` | 33 |
| `src/sql/das/ob_das_dml_ctx_define.h` | `class ObDASWriteBuffer` | 279 |
| `src/sql/das/ob_das_dml_ctx_define.h` | `struct ObDASDMLBaseCtDef` | 45 |

---

## 13. 总结

### DAS 架构的核心设计

```
SQL 算子层                  DAS 任务层                  存储引擎层
┌────────────┐          ┌────────────────┐          ┌──────────────┐
│ ObTableScanOp│ ───────→ │ ObDASScanOp     │ ───────→ │TableScanService│
│ ObTableInsertOp│ ─────→ │ ObDASInsertOp   │ ───────→ │ mvcc_write()  │
│ ObTableUpdateOp│ ─────→ │ ObDASUpdateOp   │ ───────→ │ mvcc_write()  │
│ ObTableDeleteOp│ ─────→ │ ObDASDeleteOp   │ ───────→ │ mvcc_write()  │
└────────────┘          └────────────────┘          └──────────────┘
                              │
                         ┌────┴────┐
                         │ 位置路由 │
                         │  RPC 通信│
                         │ 错误重试 │
                         └─────────┘
```

### 与前 8 篇文章的连接

| 文章 | DAS 的连接点 |
|------|-------------|
| 01-mvcc-row | DAS DML 任务的 `open_op()` → `ObAccessService::xxx_row()` → `mvcc_write()` |
| 02-mvcc-iterator | DAS Scan 的 `open_op()` → `get_tsc_service().table_scan()` → `ObMvccIterator` |
| 03-write-conflict | DAS Insert/Update 中的冲突检测 → `mvcc_write_()` 的 Case 6 |
| 04-callback | DAS DML 任务中的回调注册 → `ObITransCallback` |
| 05-compact | DAS Scan 读取的数据可能来自 compact 后的 SSTable |
| 06-memtable-freezer | DAS DML 写入 memtable，冻结后成为 SSTable |
| 07-ls-logstream | DAS Location Router 定位到 LS → 在该 LS 上执行 |
| 08-ob-sstable | DAS Scan 最终从 SSTable + Memtable 读取 |

### 关键洞察

1. **DAS 是 OceanBase 分布式数据库架构的精髓**——它将 SQL 执行与存储访问解耦，使得 SQL 层可以专注于查询优化与执行，存储层专注于数据组织和 MVCC。

2. **CTDef/RtDef 分离是性能的关键**——编译时定义跨计划缓存共享，减少了序列化开销和内存占用。

3. **写缓冲区（ObDASWriteBuffer）是批量的基础**——DAS DML 操作批量写入，减少了事务锁竞争和 RPC 次数。

4. **DAS 的迭代器树是执行计划的微型体现**——DAS Scan 内部可以组合 filter、aggregation、top-n 等多种下推，形成一个小型的"存储层执行计划"。

5. **DAS 与 PX 的关系是"铁轨与火车"**——DAS 提供并行执行的基础架构（多 Tablet 并发扫描、RPC 通信），PX 在此基础上构建了完整的并行执行框架。

### 下篇预告

- **10-ob-query-range**：查询范围提取与索引选择
- **11-ob-distributed-execution**：分布式执行引擎与 PX
- **12-ob-transaction**：分布式两阶段提交与事务管理器

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 代码仓库：OceanBase CE*
