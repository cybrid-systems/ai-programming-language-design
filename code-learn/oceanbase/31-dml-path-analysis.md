# 31-dml-path — DML 执行路径：INSERT/UPDATE/DELETE 的完整路径

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

前 30 篇文章覆盖了 OceanBase 从存储引擎（MVCC、Memtable、SSTable）到 SQL 执行引擎（DAS 层、优化器、PX 并行执行）的完整技术栈。第 09 篇介绍了 SQL 执行器与存储层之间的 DAS 桥梁，现在我们来回答一个关键问题：**一条 INSERT/UPDATE/DELETE SQL 是如何从 SQL 执行层一路走到存储引擎的？**

本文聚焦于 **DML 的串行（非 PX）执行路径**，覆盖五种 DML 操作：

- **INSERT** — 插入新行
- **UPDATE** — 更新已有行
- **DELETE** — 删除已有行
- **REPLACE** — 不存在则插入，存在则先删后插
- **INSERT_UP（INSERT ON DUPLICATE KEY UPDATE）** — 存在则更新，不存在则插入

完整调用路径：

```
SQL: INSERT INTO t VALUES (1, 'a')
  │
  ├→ ObTableInsertOp::inner_open()
  │   │
  │   ├→ open_table_for_each()
  │   │   ├→ ObDMLService::init_ins_rtdef()   — 初始化运行时上下文
  │   │   └→ process_before_stmt_trigger()    — 语句级 BEFORE 触发器
  │   │
  │   └→ (子算子返回行后逐行调用 write_row_to_das_buffer)
  │       │
  │       └→ insert_row_to_das()               — 核心逐行处理
  │           │
  │           ├→ ObDMLService::process_insert_row()  — 校验 + 触发器
  │           │   ├→ check_column_type()       — 列类型检查
  │           │   ├→ TriggerHandle (BEFORE ROW) — 行级 BEFORE 触发器
  │           │   ├→ check_column_null()       — NOT NULL 检查
  │           │   └→ check_filter_row()        — CHECK 约束过滤
  │           │
  │           ├→ calc_tablet_loc()             — 分区路由计算
  │           │
  │           └→ ObDMLService::insert_row()    — 写入 DAS 缓冲
  │               │
  │               └→ write_row_to_das_op<DAS_OP_TABLE_INSERT>()
  │                   │
  │                   ├→ find / create ObDASInsertOp
  │                   ├→ dml_op->write_row()   — 写入 DAS WriteBuffer
  │                   └→ (DAS 任务在 flush 时执行到存储层)
  │
  └→ close_table_for_each()                    — 提交 DAS 任务
      ├→ (DAS 任务执行：ObDASInsertOp::open_op())
      │   │
      │   ├→ ObDASIndexDMLAdaptor::write_tablet()
      │   │   ├→ get_write_store_ctx_guard()   — 获取存储上下文
      │   │   ├→ init_dml_param()              — 初始化写入参数
      │   │   ├→ write_rows()                  — 写入主表
      │   │   └→ write_rows()                  — 写入本地索引
      │   │
      │   └→ ObTableScan 检查存在
      │       └→ ObMvccRow::mvcc_write()       — MVCC 写入（文章 01）
      │
      └→ process_after_stmt_trigger()          — 语句级 AFTER 触发器
```

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 01-mvcc-row | DAS DML 操作最终调用 `mvcc_write` 写入版本节点 |
| 03-write-conflict | MVCC 层的写写冲突检测，在存储层写入时触发 |
| 04-callback | 事务回调注册，在事务提交/回滚时执行 |
| 09-sql-executor | DAS 层架构，DML 算子的底层执行服务 |
| 21-px-execution | DML 在 PX 并行执行下的特殊处理（本文聚焦串行） |

---

## 1. 核心数据结构

DML 执行路径涉及三层数据结构：**SQL 算子层 → DML Service 层 → DAS 层**。

### 1.1 层级关系总览

```
ObTableInsertOp  (SQL 算子层)
  ├── ObInsertSpec   (编译时上下文，CT_DEF)
  │    └── ObInsCtDef → ObDASInsCtDef  (DAS 编译时定义)
  │
  └── ObInsertRtDef  (运行时上下文，RT_DEF)
       └── ObDASInsRtDef  (DAS 运行时定义)

ObDMLService  (DML 服务层，静态方法集合)
  ├── process_insert_row()     — 校验与触发器
  ├── insert_row()             — 委托给 DAS
  ├── write_row_to_das_op()    — 模板：写入 DAS 缓冲
  └── ...

ObDASInsertOp  (DAS 操作层)
  ├── open_op()                — 执行 DAS 任务
  ├── write_row()              — 向 WriteBuffer 写入行
  └── insert_rows()            — 批量写入存储引擎
```

### 1.2 CT_DEF 与 RT_DEF 模式

OceanBase 的 DML 算子遵循经典的 **CT_DEF / RT_DEF 分离模式**：

- **CT_DEF（Compile-Time Definition）**：在优化器生成执行计划时创建，包含表达式信息、列定义、索引信息等**编译时确定的元数据**
- **RT_DEF（Run-Time Definition）**：在算子 `open()` 时初始化，包含 DAS 引用、写缓冲、受影响行计数等**运行时状态**

| 操作 | CT_DEF | RT_DEF | DAS CT_DEF | DAS RT_DEF |
|------|--------|--------|------------|------------|
| INSERT | `ObInsCtDef` | `ObInsRtDef` | `ObDASInsCtDef` | `ObDASInsRtDef` |
| UPDATE | `ObUpdCtDef` | `ObUpdRtDef` | `ObDASUpdCtDef` | `ObDASUpdRtDef` |
| DELETE | `ObDelCtDef` | `ObDelRtDef` | `ObDASDelCtDef` | `ObDASDelRtDef` |

### 1.3 2D 数组：从单一表到多表、全局索引

每个 DML Spec 使用**二维数组**（2D Array）组织 CT_DEF：

```cpp
// 第一维：多表 update（如 UPDATE t1, t2 SET ...)
// 第二维：全局索引
typedef common::ObArrayWrap<ObInsCtDef*> InsCtDefArray;     // 第二维
typedef common::ObArrayWrap<InsCtDefArray> InsCtDef2DArray;  // 第一维

// 例如：INSERT INTO t1 VALUES (1, 'a')
// t1 有一个全局二级索引 gkey(b)
// ins_ctdefs_[0][0] = 主表 InsCtDef
// ins_ctdefs_[0][1] = 全局索引 gkey 的 InsCtDef
```

源码位置：`ob_table_insert_op.h:27-28`，`ob_table_update_op.h`，`ob_table_delete_op.h`

### 1.4 ObTableModifyOp：所有 DML 算子的基类

`ObTableModifyOp`（`ob_table_modify_op.h`）是所有 DML 算子的公共基类，提供：

- **`dml_rtctx_`**（`ObDMLRtCtx`）— DML 运行时上下文，持有 `ObDASRef` 引用
- **`dml_modify_rows_`** — 行级 AFTER 触发器处理时需要的修改行列表
- **`write_row_to_das_buffer()`** — 每次子算子返回一行时调用
- **`write_rows_post_proc()`** — 所有行处理完后调用

```cpp
// ob_table_modify_op.h ~line 136
class ObTableModifyOp: public ObOperator
{
  // ...
  ObDMLRtCtx dml_rtctx_;
  ObIArray<ObDMLModifyRowNode> dml_modify_rows_;
  bool is_error_logging_;
  // ...
  virtual int write_row_to_das_buffer() = 0;  // 子类实现
  virtual int write_rows_post_proc(int last_errno) = 0; // 子类实现
};
```

---

## 2. INSERT 完整路径

### 2.1 开始：inner_open()

`ObTableInsertOp::inner_open()`（`ob_table_insert_op.cpp:136`）：

```cpp
int ObTableInsertOp::inner_open()
{
  int ret = OB_SUCCESS;
  NG_TRACE(insert_open);
  // 1. 调用基类 ObTableModifyOp::inner_open()，打开子算子
  if (OB_FAIL(ObTableModifyOp::inner_open())) {
    LOG_WARN("inner open ObTableModifyOp failed", K(ret));
  } else if (OB_UNLIKELY(MY_SPEC.ins_ctdefs_.empty())) {
    ret = OB_ERR_UNEXPECTED;
  } else if (OB_UNLIKELY(iter_end_)) {
    // 没有数据需要插入（如 WHERE 条件永远为 false）
    // do nothing
  } else if (OB_FAIL(inner_open_with_das())) {
    LOG_WARN("inner open with das failed", K(ret));
  }
  return ret;
}
```

### 2.2 open_table_for_each() — 初始化运行时上下文

`inner_open_with_das()` 调用 `open_table_for_each()` (`ob_table_insert_op.cpp:72`)，该函数负责：

```cpp
int ObTableInsertOp::open_table_for_each()
{
  // 1. 为每个表和索引初始化 InsRtDef
  for (int64_t i = 0; ...) {
    for (int64_t j = 0; ...) {
      ObDMLService::init_ins_rtdef(dml_rtctx_, ins_rtdef, ins_ctdef,
                                    trigger_clear_exprs_, fk_checkers_);
    }
    // 2. 执行语句级 BEFORE 触发器
    ObDMLService::process_before_stmt_trigger(...);
    // 3. 标记表位置为"写入中"
    primary_ins_rtdef.das_rtdef_.table_loc_->is_writing_ = true;
  }
}
```

关键点：`init_ins_rtdef` 负责初始化 DAS 运行时定义（`ObDASInsRtDef`），包括表位置、写缓冲等。

### 2.3 逐行处理：insert_row_to_das()

当子算子返回每一行时，`ObTableModifyOp` 的 `get_next_row()` 会调用 `write_row_to_das_buffer()`，最终落到 `insert_row_to_das()` (`ob_table_insert_op.cpp:103`)：

```cpp
int ObTableInsertOp::insert_row_to_das()
{
  // 1. （可选）创建匿名 savepoint（用于 error logging）
  if (is_error_logging_) {
    ObSqlTransControl::create_anonymous_savepoint(ctx_, savepoint_no);
  }

  for (int64_t i = 0; ...) { // 遍历多表
    for (int64_t j = 0; ...) { // 遍历全局索引
      // 2. 处理插入行（校验、触发器、约束检查）
      ObDMLService::process_insert_row(ins_ctdef, ins_rtdef, *this, is_skipped);

      // 3. （可选）计算分区位置
      calc_tablet_loc(ins_ctdef, ins_rtdef, tablet_loc);

      // 4. 写入 DAS
      ObDMLService::insert_row(ins_ctdef, ins_rtdef, tablet_loc,
                                dml_rtctx_, modify_row.new_row_);
    }
  }
}
```

### 2.4 process_insert_row() — 校验与预处理

`ObDMLService::process_insert_row()` (`ob_dml_service.cpp:729`) 执行以下步骤：

```
process_insert_row()
  │
  ├─→ check_column_type()         — 列类型匹配检查（含 Geometry 检查）
  │
  ├─→ check_nested_sql_legality() — 嵌套 SQL 合法性检查
  │
  ├─→ TriggerHandle::init_param_new_row()
  │   └─→ 初始化触发器新行参数
  │
  ├─→ TriggerHandle::do_handle_before_row()
  │   └─→ 执行行级 BEFORE 触发器
  │
  ├─→ （如果是 INSTEAD OF 触发器，跳过后续检查）
  │
  ├─→ check_row_null()            — NOT NULL 约束检查
  │   └─→ 如为非严格模式 + is_ignore，自动填充零值
  │
  └─→ check_filter_row()          — CHECK 约束检查
```

关键设计：**错误捕获** — 如果某步失败，会调用 `check_error_ret_by_row()` 判断是否需要忽略该行错误（如 INSERT IGNORE 模式下）。

### 2.5 insert_row() → write_row_to_das_op() — 委托到 DAS

`ObDMLService::insert_row()` 检查 tablet 有效性后，委托给模板函数 `write_row_to_das_op<DAS_OP_TABLE_INSERT>()` (`ob_dml_service.cpp:2311`)：

```cpp
template <int N>
int ObDMLService::write_row_to_das_op(...)
{
  // 1. 查找或创建 DAS DML Op
  OpType *dml_op = nullptr;
  if (!dml_rtctx.das_ref_.has_das_op(tablet_loc, dml_op)) {
    dml_rtctx.das_ref_.prepare_das_task(tablet_loc, dml_op);
    dml_op->init_task_info(extend_size);
    dml_op->set_das_ctdef(static_cast<const CtDefType*>(&ctdef));
    dml_op->set_das_rtdef(static_cast<RtDefType*>(&rtdef));
  }

  // 2. 将行写入 DAS DML Op 的 WriteBuffer
  dml_op->write_row(row, eval_ctx, stored_row);

  // 3. （可选）并行提交
  if (reach_agg_mem_limit) {
    parallel_submit_das_task(...)
  }
}
```

这一步是 **DML 执行的核心抽象**：SQL 层不直接调用存储引擎，而是将所有修改累积到 `ObDASWriteBuffer` 中。当所有行处理完毕（`inner_close()` 时），DAS 任务才会被 flush 到存储引擎。

### 2.6 ObDASInsertOp::open_op() — 最终写入存储

在 DAS 任务执行阶段，`ObDASInsertOp::open_op()` 被调用。它通过 `ObDASIndexDMLAdaptor::write_tablet()` (`ob_dml_service.h`) 将缓冲区的行写入存储引擎：

```cpp
// ObDASIndexDMLAdaptor::write_tablet()
int write_tablet(DMLIterator &iter, int64_t &affected_rows)
{
  // 1. 初始化写标识
  ObDMLService::init_dml_write_flag(*ctdef_, *rtdef_, write_flag, is_do_gts_opt_);

  // 2. 获取存储上下文（含事务、快照信息）
  as->get_write_store_ctx_guard(ls_id_, timeout, *tx_desc_, *snapshot_,
                                 write_branch_id_, write_flag, store_ctx_guard);

  // 3. 初始化 DML 参数
  ObDMLService::init_dml_param(*ctdef_, *rtdef_, *snapshot_, ...)

  // 4. 写入主表
  write_rows(ls_id_, tablet_id_, *ctdef_, *rtdef_, iter, affected_rows);

  // 5. 写入本地索引
  for (int64_t i = 0; ...) {
    write_rows(ls_id_, related_tablet_id, *related_ctdef, ...);
    ObDMLService::check_local_index_affected_rows(...);
  }
}
```

最终，存储引擎的写入操作通过 `ObMvccRow::mvcc_write()`（文章 01）完成 MVCC 版本链的插入。

---

## 3. DELETE 路径

### 3.1 与 INSERT 的对比

DELETE 的执行路径与 INSERT 高度相似，区别在于：

1. **不需要分区计算**（删除已有行，位置已确定）
2. **不需要 NOT NULL / CHECK 约束检查**（删除不涉及数据校验）
3. **需要 rowkey 唯一性检查**（避免重复删除）
4. **不需要 INSERT 类型的列检查**

### 3.2 inner_open() 与 open_table_for_each()

`ObTableDeleteOp::inner_open()` (`ob_table_delete_op.cpp:81`) 流程：

```
ObTableDeleteOp::inner_open()
  └─→ inner_open_with_das()
       └─→ open_table_for_each()
            ├─→ 分配 DelRtDef 二维数组
            ├─→ ObDMLService::init_del_rtdef()
            └─→ process_before_stmt_trigger(DE_DELETING)
```

### 3.3 process_delete_row() — 跳过判定

`ObDMLService::process_delete_row()` (`ob_dml_service.cpp:1160`)：

```cpp
int ObDMLService::process_delete_row(...)
{
  if (del_ctdef.is_primary_index_) {
    // 1. rowkey 为 NULL 的跳过（如外键 CASCADE 的场景）
    if (need_check_filter_null_) {
      check_rowkey_is_null(old_row_, rowkey_cnt, eval_ctx, is_null);
      if (is_null) is_skipped = true;
    }

    // 2. DISTINCT 去重检查（防止重复删除同一行）
    if (del_rtdef.se_rowkey_dist_ctx_ != nullptr) {
      check_rowkey_whether_distinct(...);
      if (!is_distinct) is_skipped = true;
    }

    // 3. BEFORE ROW 触发器
    TriggerHandle::do_handle_before_row(...);
    if (has_instead_of_trg) is_skipped = true;
  }
}
```

### 3.4 delete_row_to_das()

`ObTableDeleteOp::delete_row_to_das()` (`ob_table_delete_op.cpp:149`)：

```
delete_row_to_das()
  ├─→ process_delete_row()       — 跳过判定 + BEFORE 触发器
  ├─→ calc_tablet_loc()          — 计算分区位置
  └─→ ObDMLService::delete_row() — 写入 DAS Delete 缓冲
       └─→ write_row_to_das_op<DAS_OP_TABLE_DELETE>()
```

### 3.5 ObDASDeleteOp — 存储删执行

`ObDASDeleteOp::open_op()` 执行实际的删除操作，调用存储引擎的删除接口，最终通过 MVCC 层标记行版本为删除状态。

---

## 4. UPDATE 路径

### 4.1 UPDATE 的核心挑战

UPDATE 在语义上是 DELETE + INSERT 的组合，但 OceanBase 做了优化区分：

| 场景 | 处理方式 | 原因 |
|------|---------|------|
| 行值未变化 | **仅加锁**（Lock） | 无需修改 |
| 行值变化，rowkey 不变 | **原地 UPDATE** | 最优化路径 |
| rowkey 变化（跨分区） | **DELETE + INSERT** | 对象必须移动到新分区 |
| Row Movement 禁用 | **报错** `OB_ERR_UPD_CAUSE_PART_CHANGE` | 不允许跨分区移动 |

### 4.2 process_update_row() — 行级处理

`ObDMLService::process_update_row()` (`ob_dml_service.cpp:1234`)：

```cpp
int ObDMLService::process_update_row(...)
{
  if (upd_ctdef.is_primary_index_) {
    // 1. rowkey 为 NULL 的跳过
    if (need_check_filter_null_) { check_rowkey_is_null(...); }

    // 2. heap table 隐藏主键复制
    if (is_table_without_pk_ || is_table_with_clustering_key_) {
      copy_heap_table_hidden_pk(eval_ctx, upd_ctdef);
    }

    // 3. DISTINCT 去重检查
    check_rowkey_whether_distinct(...);

    // 4. 列类型检查 + 嵌套 SQL 合法性
    check_column_type(...);
    check_nested_sql_legality(...);

    // 5. BEFORE ROW 触发器
    TriggerHandle::do_handle_before_row(...);
    if (has_instead_of_trg) is_skipped = true;

    // 6. NOT NULL 检查（对新值的赋值列）
    check_row_null(new_row_, ...);

    // 7. 检查行是否实际变化
    check_row_whether_changed(upd_ctdef, upd_rtdef, eval_ctx);

    // 8. CHECK 约束过滤
    check_filter_row(...);
  } else {
    // 全局索引：只需检查行是否变化
    check_row_whether_changed(...);
  }
}
```

### 4.3 核心：check_row_whether_changed()

`ObDMLService::check_row_whether_changed()` 比较新旧行的每列值，如果所有更新列的新旧值都相同，则设置 `upd_rtdef.is_row_changed_ = false`，后续只需加锁，无需实际修改。

### 4.4 update_row() — 三种路径

`ObDMLService::update_row()` (`ob_dml_service.cpp:1529`) 根据 `is_row_changed_` 和是否跨分区做决策：

```
if (!upd_rtdef.is_row_changed_)
  → 仅加锁 (write_row_to_das_op<DAS_OP_TABLE_LOCK>)
  └─→ 通过 ObDASLockOp 获取行锁

else if (跨分区 && 行移动启用)
  → split_upd_to_del_and_ins()
  ├─→ write_row_to_das_op<DAS_OP_TABLE_DELETE>  — 删除旧行
  └─→ write_row_to_das_op<DAS_OP_TABLE_INSERT>   — 插入新行

else
  → 原地 UPDATE
  └─→ write_row_to_das_op<DAS_OP_TABLE_UPDATE>
```

关键设计：**跨分区 UPDATE 的原子性** — `split_upd_to_del_and_ins()` 先标记 `DAS_BLOCKING_PARALLEL`，确保所有 DELETE 完成后才执行 INSERT，保证跨分区数据一致性。

### 4.5 ObTableUpdateOp 的特殊结构

与 INSERT/DELETE 不同，UPDATE 的运行时上下文（`ObUpdRtDef`）包含三种 DAS 子操作：

```cpp
struct ObUpdRtDef {
  ObDASUpdRtDef dupd_rtdef_;     // DAS UPDATE（原地更新用）
  ObDASInsRtDef *dins_rtdef_;    // DAS INSERT（跨分区时用）
  ObDASDelRtDef *ddel_rtdef_;    // DAS DELETE（跨分区时用）
  ObDASLockRtDef *dlock_rtdef_;  // DAS LOCK（行未变化时用）
  // ...
};
```

三种子操作在编译时预分配 CT_DEF（`ObUpdCtDef` 中的 `dupd_ctdef_`、`dins_ctdef_`、`ddel_ctdef_`、`dlock_ctdef_`），运行时根据实际场景按需激活。

---

## 5. REPLACE 与 INSERT_UP

### 5.1 REPLACE（ObTableReplaceOp）

REPLACE 的语义是：如果新行与已有行的主键/唯一键冲突，**先删除冲突行，再插入新行**。

执行路径：
1. `ObTableReplaceOp::inner_open()` → 通过 `ObConflictChecker` 构建冲突检测 Map
2. 通过回表扫描（`do_lookup_and_build_base_map`）找出冲突行
3. 逐行检查冲突：
   - 无冲突 → 直接 INSERT
   - 有冲突 → 先 DELETE 再 INSERT（在 DAS 缓冲中排队）

### 5.2 INSERT_UP（ObTableInsertUpOp）

INSERT ... ON DUPLICATE KEY UPDATE 的语义是：发生主键/唯一键冲突时，**执行 UPDATE**而不是删除。

执行路径：
1. 先尝试 INSERT
2. INSERT 失败（`OB_ERR_PRIMARY_KEY_DUPLICATE`）时：
   - 回滚到匿名 savepoint
   - 转为 UPDATE 操作
   - 通过 `ObDASConflictIterator` 获取冲突行数据
3. 使用冲突行数据作为 UPDATE 的 old row

### 5.3 ObConflictChecker — 冲突检测引擎

`ObConflictChecker`（`ob_conflict_checker.h`）是 REPLACE 和 INSERT_UP 的核心：

```
ObConflictChecker 工作原理：
  │
  ├─→ init_conflict_checker()     — 初始化检查器
  ├─→ create_conflict_map()       — 创建哈希表用于主键检测
  │
  ├─→ 逐行扫描子算子行：
  │   ├─→ check_duplicate_rowkey() — 在哈希表中查主键冲突
  │   ├─→ insert_new_row()         — 无冲突，将行加入哈希表
  │   └─→ delete_old_row()         — 有冲突，从哈希表删除旧行
  │
  └─→ do_lookup_and_build_base_map() — 回表获取冲突行完整数据
```

关键数据结构：`ObConflictRowMap` — 以 `ObRowkey` 为键、`ObConflictValue` 为值的哈希表，用于 O(1) 主键冲突检测。

---

## 6. 冲突检测与约束检查

### 6.1 三层冲突检测体系

INSERT/UPDATE/DELETE 的冲突和约束检查分为**三层**：

| 层次 | 位置 | 检测内容 | 对应文章 |
|------|------|---------|---------|
| SQL 层 | `ObConflictChecker` | 主键/唯一键冲突（REPLACE/INSERT_UP） | 本文 |
| DML Service 层 | `ObDMLService` | NOT NULL、列类型、CHECK 约束、表循环 | 本文 |
| 存储层 | MVCC | 写写冲突（同时写入同一行） | 文章 03 |

### 6.2 SQL 层 vs 存储层冲突的区别

| 特性 | SQL 层（ObConflictChecker） | 存储层（MVCC Write Conflict） |
|------|---------------------------|------------------------------|
| 检测时机 | 写入 DAS 缓冲前 | 写入存储引擎时 |
| 检测范围 | 同事务内已插入行 | 全局并发事务 |
| 触发场景 | REPLACE、INSERT_UP 的重复主键 | 所有 DML 的并发写写冲突 |
| 检测方式 | Rowkey 哈希表 | MVCC 版本链 + 事务锁 |
| 处理方式 | 替换 / 更新 | 等待 / 回滚 |

### 6.3 约束检查列表

**INSERT 检查**（按执行顺序）：
1. 列类型匹配（`check_column_type`）
2. 嵌套 SQL 合法性（防止修改正在访问的表）
3. BEFORE ROW 触发器
4. NOT NULL 约束（`check_row_null`）— 非严格模式下自动补零值
5. CHECK 约束（`check_filter_row`）

**UPDATE 额外检查**：
1. rowkey 是否为 NULL（`check_rowkey_is_null`）
2. 行去重（`check_rowkey_whether_distinct`）
3. 赋值列类型匹配
4. BEFORE ROW 触发器
5. NOT NULL 约束
6. 行值变化检测（`check_row_whether_changed`）— 关键性能优化
7. 表循环检测（外键级联更新时）

**DELETE 检查**：
1. rowkey 是否为 NULL
2. 行去重
3. BEFORE ROW 触发器

---

## 7. 设计决策

### 7.1 为什么 DML 需要 DAS 中间层？

DAS（Data Access Service）层作为 SQL 算子与存储引擎之间的桥梁，解决了多个关键问题：

1. **批量写入优化** — DAS WriteBuffer 累积多行后一次性提交，减少存储引擎的调用次数
2. **位置路由** — `calc_tablet_loc()` 按 partition key 路由到正确的 Tablet，支持分布式写入
3. **本地索引维护** — DAS Op 自动为每个 Tablet 维护本地索引写入，保证主表与索引的一致性
4. **错误处理** — 统一的 savepoint 回滚和 error logging 机制
5. **并行执行支持** — DAS 任务可以并行提交到多个 Tablet（为 PX 并行 DML 提供基础）

### 7.2 UPDATE = DELETE + INSERT 的条件

OceanBase **不会**在所有 UPDATE 场景中拆分为 DELETE + INSERT。只有当以下任一条件满足时才拆分：

1. **主键被修改**（`is_update_pk_`）
2. **分区键被修改且表有聚簇键**（`is_update_partition_key_ && is_table_with_clustering_key_`）
3. **实际跨分区**（`old_tablet_loc != new_tablet_loc`），且 `row_movement` 启用

否则，UPDATE 使用 **原地更新路径**（`DAS_OP_TABLE_UPDATE`），只修改发生变化的列。

### 7.3 Read-Modify-Write 模式

UPDATE 和 DELETE 本质上遵循 **Read-Modify-Write**（R-M-W）模式：

```
UPDATE t SET b = 2 WHERE a = 1;
  │
  ├─→ 读取：TableScan 子算子扫描出 a=1 的行（借助 DAS Scan，文章 09）
  ├─→ 修改：ObTableUpdateOp 将新值 b=2 与旧值合并为 full_row
  └─→ 写入：ObDMLService::update_row() 写入 DAS Update 缓冲
```

这也是为什么 UPDATE 的 SQL 执行计划中，**子算子必须是一个 TableScan**（实际是 DAS Scan），因为需要先读取旧行的所有列值。

### 7.4 INSERT 的分区路由

INSERT 的分区路由稍显特殊：它需要**先计算 partition key，再定位 Tablet**，因为新行还没有确定的位置。

```cpp
// ob_table_insert_op.cpp:89
int ObTableInsertOp::calc_tablet_loc(...)
{
  if (MY_SPEC.use_dist_das_) {
    // 通过表达式计算 partition_id
    ObExprCalcPartitionBase::calc_part_and_tablet_id(
        calc_part_id_expr, eval_ctx_, partition_id, tablet_id);
    // 扩展为完整的 TabletLoc 信息
    DAS_CTX(ctx_).extended_tablet_loc(table_loc, tablet_id, tablet_loc);
  } else {
    // 单分区表：直接使用预计算的位置
    tablet_loc = MY_INPUT.get_tablet_loc();
  }
}
```

DELETE 和 UPDATE 也类似，但 UPDATE 需要计算**新旧两个分区位置**（`calc_tablet_loc` 返回 `old_tablet_loc` 和 `new_tablet_loc`）。

### 7.5 行级安全与受影响的行动态追踪

OceanBase DML 框架通过 `dml_modify_rows_` 数组追踪每一行修改，用于 AFTER ROW 触发器和外键级联操作。`ObDMLModifyRowNode` 保存：

- 修改前旧行（`old_row_`）
- 修改后新行（`new_row_`）
- 完整行（`full_row_`，UPDATE 专用）
- CT_DEF 和 RT_DEF 指针
- DML 事件类型（INSERTING / UPDATING / DELETING）

```cpp
// ob_dml_ctx_define.h
struct ObDMLModifyRowNode {
  ObTableModifyOp *op_;
  const ObDMLBaseCtDef *ctdef_;
  ObDMLBaseRtDef *rtdef_;
  ObDmlEventType dml_event_;
  ObChunkDatumStore::StoredRow *old_row_;
  ObChunkDatumStore::StoredRow *new_row_;
  ObChunkDatumStore::StoredRow *full_row_;
};
```

所有修改行在 DAS 写入完成后，触发 `handle_after_processing_single_row()` 处理 AFTER ROW 触发器和外键级联。

### 7.6 2D 数组设计的意义

DML Spec 的 CT_DEF 使用 2D 数组：

- **第一维** — 多表 DML（如 `UPDATE t1, t2 SET ...`）
- **第二维** — 全局索引（主表 + 全局二级索引）

为什么不是扁平的一维数组？因为**多表 DML 的每个表都需要维护独立的全局索引列表**。例如：

```sql
-- 多表 UPDATE
UPDATE t1, t2 SET t1.b = 1, t2.b = 2 WHERE t1.a = t2.a;
-- t1 的 CT_DEF：upd_ctdefs_[0] = [主表, 全局索引A]
-- t2 的 CT_DEF：upd_ctdefs_[1] = [主表, 全局索引B]
```

### 7.7 错误处理与 savepoint

DML 的**行级错误处理**（如 INSERT IGNORE）通过匿名 savepoint 实现：

```
insert_row_to_das()
  │
  ├─→ create_anonymous_savepoint()     — 在事务中创建 savepoint
  ├─→ process_insert_row()             — 尝试写入
  │
  └─→ 如果出错：
      ├─→ catch_violate_error()
      │   └─→ 回滚到 savepoint         — 撤销该行的部分写入
      │
      └─→ （可选）写入 Error Log 表     — 记录错误信息，继续处理下一行
```

这种设计确保了一行失败不影响其他行，并且错误日志表可以记录所有被忽略的错误。

---

## 8. 源码索引

### DML 算子层

| 文件 | 核心类/函数 | 行号 |
|------|-----------|------|
| `src/sql/engine/dml/ob_table_modify_op.h` | `ObTableModifyOp`（基类） | ~136 |
| `src/sql/engine/dml/ob_table_insert_op.h` | `ObTableInsertOp` | 66 |
| `src/sql/engine/dml/ob_table_insert_op.cpp` | `inner_open()` | 136 |
| | `open_table_for_each()` | 72 |
| | `insert_row_to_das()` | 103 |
| | `calc_tablet_loc()` | 89 |
| | `write_rows_post_proc()` | 159 |
| | `check_insert_affected_row()` | 183 |
| `src/sql/engine/dml/ob_table_update_op.h` | `ObTableUpdateOp` | 77 |
| `src/sql/engine/dml/ob_table_update_op.cpp` | `inner_open()` | 180 |
| | `open_table_for_each()` | 214 |
| | `update_row_to_das()` | 267 |
| | `calc_tablet_loc()` | 245 |
| `src/sql/engine/dml/ob_table_delete_op.h` | `ObTableDeleteOp` | 64 |
| `src/sql/engine/dml/ob_table_delete_op.cpp` | `inner_open()` | 81 |
| | `open_table_for_each()` | 106 |
| | `delete_row_to_das()` | 149 |
| `src/sql/engine/dml/ob_table_insert_up_op.h` | `ObTableInsertUpOp` | INSERT_UP |
| `src/sql/engine/dml/ob_table_replace_op.h` | `ObTableReplaceOp` | REPLACE |

### DML Service 层

| 文件 | 核心函数 | 行号 |
|------|---------|------|
| `src/sql/engine/dml/ob_dml_service.h` | `ObDMLService`（全部静态方法） | 55 |
| `src/sql/engine/dml/ob_dml_service.cpp` | `process_insert_row()` | 729 |
| | `process_delete_row()` | 1160 |
| | `process_update_row()` | 1234 |
| | `insert_row()` | 1356 / 1380 |
| | `delete_row()` | 1410 |
| | `update_row()` | 1529 |
| | `split_upd_to_del_and_ins()` | 1486 |
| | `write_row_to_das_op()`（模板） | 2311 |
| | `check_row_null()` | 输入输出 |
| | `check_row_whether_changed()` | 输入输出 |
| | `check_filter_row()` | 输入输出 |
| | `add_related_index_info()` | 2411 |

### DAS DML 操作层

| 文件 | 核心类 | 行号 |
|------|-------|------|
| `src/sql/das/ob_das_insert_op.h` | `ObDASInsertOp` | 64 |
| `src/sql/das/ob_das_insert_op.h` | `ObDASConflictIterator` | 23 |
| `src/sql/das/ob_das_update_op.h` | `ObDASUpdateOp` | 23 |
| `src/sql/das/ob_das_delete_op.h` | `ObDASDeleteOp` | 23 |
| `src/sql/das/ob_das_lock_op.h` | `ObDASLockOp` | — |
| `src/sql/das/ob_das_dml_ctx_define.h` | `ObDASInsCtDef`, `ObDASInsRtDef` 等 | — |

### 冲突检测层

| 文件 | 核心类 | 行号 |
|------|-------|------|
| `src/sql/engine/dml/ob_conflict_checker.h` | `ObConflictChecker` | 139 |
| | `ObConflictRowMap` | 70 |
| | `ObConflictCheckerCtdef` | 88 |
| | `check_duplicate_rowkey()` | 声明 |
| | `do_lookup_and_build_base_map()` | 声明 |

### DML 上下文定义

| 文件 | 核心结构 | 行号 |
|------|---------|------|
| `src/sql/engine/dml/ob_dml_ctx_define.h` | `ObErrLogCtDef` | 25 |
| | `ObTriggerArg` | 151 |
| | `ObTrigDMLCtDef` | 273 |
| | `ObForeignKeyCheckerCtdef` | 381 |

### ObDASIndexDMLAdaptor（DAS 到存储的桥接）

| 文件 | 核心函数 | 行号 |
|------|---------|------|
| `src/sql/engine/dml/ob_dml_service.h` | `ObDASIndexDMLAdaptor::write_tablet()` | 420~506 |
| | `write_tablet_with_ignore()` | 507~620 |
| | `init_dml_write_flag()` | 声明 |
| | `init_dml_param()` | 声明 |

---

## 9. 总结

本文追踪了 INSERT / UPDATE / DELETE / REPLACE / INSERT_UP 五类 DML 操作的完整执行路径，从 SQL 执行层的 `ObTableInsertOp::inner_open()` 一直到 DAS 层通过 `ObDASIndexDMLAdaptor::write_tablet()` 写入存储引擎。

核心发现：

1. **三层架构** — SQL 算子（ObTableInsertOp）→ DML Service（ObDMLService）→ DAS Op（ObDASInsertOp），层层委托，职责清晰
2. **缓冲写入** — DAS WriteBuffer 累积写入再一次性 Flush，减少存储引擎调用
3. **UPDATE 的三条路径** — 行未变化 → 仅加锁；原地修改 → DAS UPDATE；跨分区 → DELETE + INSERT
4. **冲突检测的层次分离** — SQL 层检测显式约束（主键/唯一键冲突），存储层检测隐式冲突（MVCC 写写冲突）
5. **CT_DEF / RT_DEF 模式** — 编译时元数据与运行时状态分离，高效且易于序列化
