# 25. InnoDB Online DDL — 逐行源码追踪

> 本文基于 MySQL 8.4 主线源码，通过 doom-lsp（clangd LSP）对 InnoDB Online DDL 进行逐行符号解析与数据流追踪。核心源文件：`storage/innobase/handler/handler0alter.cc`、`storage/innobase/row/row0log.cc`、`storage/innobase/log/log0ddl.cc`、`storage/innobase/ddl/ddl0merge.cc`。

---

## 0. 概述

MySQL 8.0 的 Online DDL 允许在不阻塞 DML 的情况下修改表结构。InnoDB 实现了三种 DDL 算法，各有不同的锁级别和适用场景。

### 算法对比

| 算法 | 元数据锁 | 数据复制 | 支持类型 |
|------|---------|---------|---------|
| **INSTANT** | 无锁 | 不复制 | INSTANT_ADD_COLUMN, DROP_DEFAULT, SET_DEFAULT, RENAME_COLUMN |
| **INPLACE** | 共享锁（允许并发 DML）| 仅索引/表重建 | ADD INDEX, DROP INDEX, ADD COLUMN, MODIFY COLUMN... |
| **COPY** | 排他锁 | 全表复制 | 不支持 INPLACE 的 DDL 回退 |

### 算法选择流程

```cpp
// handler0alter.cc:964 — check_if_supported_inplace_alter()
// 在 SQL 层准备 ALTER TABLE 时调用
// 决定是否支持 INPLACE 算法
//
// 返回值：HA_ALTER_INPLACE_NO_LOCK_AFTER_PREPARE（允许并发 DML）
//        HA_ALTER_INPLACE_SHARED_AFTER_PREPARE（只允许读）
//        HA_ALTER_INPLACE_NO_LOCK_LOCKED_AFTER_PREPARE（不允许并发）
//        HA_ALTER_ERROR（不持之道 → 回退到 COPY）

enum_alter_inplace_result ha_innobase::check_if_supported_inplace_alter(
    TABLE *altered_table, Alter_inplace_info *ha_alter_info) {

  /* 对每个 ALTER 操作类型判断 INPLACE 支持 */
  for (each operation in ha_alter_info) {
    switch (operation->type) {
      case Alter_inplace_info::ALTER_ADD_COLUMN:
        if (innobase_support_instant(...)) {     /* :827 */
          return HA_ALTER_INPLACE_NO_LOCK_AFTER_PREPARE;
        }
        /* fall through 到 INPLACE 重建 */
        return HA_ALTER_INPLACE_SHARED_AFTER_PREPARE;

      case Alter_inplace_info::ALTER_ADD_INDEX:
        return HA_ALTER_INPLACE_NO_LOCK_AFTER_PREPARE;

      case Alter_inplace_info::ALTER_DROP_COLUMN:
      case Alter_inplace_info::ALTER_CHANGE_COLUMN:
        if (innobase_need_rebuild(...)) {         /* :928 */
          return HA_ALTER_INPLACE_SHARED_AFTER_PREPARE;
        }
        return HA_ALTER_ERROR;  /* 回退到 COPY */
    }
  }
}
```

---

## 1. INSTANT 算法

### 1.1 innobase_support_instant()

```cpp
// handler0alter.cc:827
static bool innobase_support_instant(
    Alter_inplace_info::HA_ALTER_FLAGS alter_flag) {

  /* INSTANT 支持的 ALTER 操作 */
  static const HA_ALTER_FLAGS instant_flags =
      Alter_inplace_info::ALTER_ADD_COLUMN |
      Alter_inplace_info::ALTER_DROP_COLUMN |
      Alter_inplace_info::ALTER_CHANGE_COLUMN |
      Alter_inplace_info::ALTER_RENAME_COLUMN |
      Alter_inplace_info::ALTER_SET_DEFAULT |
      Alter_inplace_info::ALTER_DROP_DEFAULT;

  /* INSTANT 支持的列类型变更 */
  static const HA_ALTER_FLAGS instant_col_flags =
      Alter_inplace_info::ALTER_COLUMN_NULLABLE |
      Alter_inplace_info::ALTER_COLUMN_NOT_NULLABLE;

  return (alter_flag & instant_flags) == alter_flag ||
         (alter_flag & instant_col_flags) == alter_flag;
}
```

### 1.2 INSTANT ADD COLUMN 的实现

INSTANT ADD COLUMN 的本质是**只修改元数据，不修改已有行记录**：

```
INSTANT ADD COLUMN c INT

执行前:
  行格式: [a][b]
  元数据: n_cols=2, n_instant_cols=0

执行后:
  行格式: [a][b]      ← 已有行不变！
  新插入行: [a][b][c=default]
  元数据: n_cols=3, n_instant_cols=2
          每行读取时检测：
            如果行记录列数 < n_instant_cols → 取默认值
```

### 1.3 commit_inplace_alter_table 中的 INSTANT 提交

```cpp
// handler0alter.cc:1392 — dd_commit_inplace_alter_table()
// handler0alter.cc:1411 — dd_commit_inplace_update_instant_meta()

// INSTANT 提交路径：
// 1. 更新 dict_table_t 的 n_instant_cols 字段
// 2. 写入 version_added/version_dropped 数组
// 3. 写入 redo log（DDL_LOG）
// 4. 更新 DD 表空间
```

---

## 2. INPLACE 算法 — 主流程

### 2.1 完整调用链

```cpp
// handler0alter.cc:1564
bool ha_innobase::inplace_alter_table(
    TABLE *altered_table, Alter_inplace_info *ha_alter_info) {

  return inplace_alter_table_impl(altered_table, ha_alter_info);
}
```

```cpp
// handler0alter.cc:6136 — INPLACE 主实现
bool ha_innobase::inplace_alter_table_impl(
    TABLE *altered_table, Alter_inplace_info *ha_alter_info) {

  ha_innobase_inplace_ctx *ctx = get_ha_innobase_inplace_ctx(ha_alter_info);

  /* ──── 阶段 1：添加索引（非重建场景）──── */
  if (ha_alter_info->handler_truncate_log_or_drop_indexes) {
    /* 简单 DDL：DROP INDEX / RENAME INDEX / SET DEFAULT */
    /* 不用 row_log，直接修改数据字典 */
    return false;
  }

  /* ──── 阶段 2：启动 row_log（重建场景）──── */
  /* 在 INPLACE 表/索引重建期间，所有 DML 操作都需要记录到 row_log */
  /* 后续在 row_log_apply() 中回放 */

  if (ctx->online && ctx->need_rebuild()) {
    /* row0log.h:200 声明 */
    /* row0log.cc 实现 */
    row_log_apply(thr, index, ...);
  }

  /* ──── 阶段 3：创建新索引 / 重建表 ──── */
  if (ctx->need_rebuild()) {
    /* 表重建：
     * 1. 创建新表（新格式）
     * 2. 并行扫描旧表
     * 3. 逐行插入新表
     * 4. row_log_apply 回放增量
     * 5. 数据字典切换 */
  } else {
    /* 仅索引添加：
     * 1. 创建新索引 B-Tree
     * 2. row_log_apply 回放增量
     * 3. 数据字典注册新索引 */
  }

  return false;
}
```

### 2.2 check_if_supported_inplace_alter — 支持判定

```cpp
// handler0alter.cc:964
enum_alter_inplace_result ha_innobase::check_if_supported_inplace_alter(
    TABLE *altered_table, Alter_inplace_info *ha_alter_info) {

  /* 检查：
   * - 行格式变更？(COMPRESSED → DYNAMIC 需要重建)
   * - 键长度变更？(VARCHAR(255) → VARCHAR(500) 在 768 字节内可 INPLACE)
   * - 列类型变更？(INT → BIGINT 可 INPLACE, VARCHAR → INT 不可以)
   * - 表空间变更？(file-per-table → 系统表空间需要 COPY)
   * - 字符集变更？(utf8 → utf8mb4 需要重建)
   */

  if (/* 不需要重建且是 ADD INDEX/DROP INDEX 等 */) {
    return HA_ALTER_INPLACE_NO_LOCK_AFTER_PREPARE;
  }

  if (/* 需要重建表 */) {
    return HA_ALTER_INPLACE_SHARED_AFTER_PREPARE;
  }

  /* 不支持 INPLACE → SQL 层回退到 COPY */
  return HA_ALTER_ERROR;
}
```

### 2.3 innobase_need_rebuild()

```cpp
// handler0alter.cc:928
static bool innobase_need_rebuild(Alter_inplace_info *ha_alter_info) {

  /* 配置变更：ROW_FORMAT, TABLESPACE, KEY_BLOCK_SIZE 等 */
  if (ha_alter_info->alter_info->requested_algorithm !=
      Alter_info::ALTER_TABLE_ALGORITHM_INPLACE) {
    return true;  /* 用户指定了 COPY 算法 */
  }

  if (ha_alter_info->handler_flags &
      Alter_inplace_info::ADD_PK_INDEX) {
    return true;  /* 添加主键总是需要重建 */
  }

  if (ha_alter_info->handler_flags &
      Alter_inplace_info::DROP_PK_INDEX) {
    return true;  /* 删除主键总是需要重建 */
  }

  if (ha_alter_info->handler_flags &
      Alter_inplace_info::ALTER_COLUMN_ORDER) {
    return true;  /* 修改列顺序需要重建 */
  }

  return false;  /* 其他操作可以 INPLACE 不重建 */
}
```

---

## 3. row_log — 增量日志

### 3.1 row_log_t 结构

```cpp
// row0log.cc:185
struct row_log_t {
  /** 行日志文件描述符 */
  pfs_os_file_t fd;

  /** 日志缓冲区 */
  byte *buf;
  /** 缓冲区大小 */
  ulint buf_size;
  /** 当前写入指针 */
  byte *buf_ptr;
  /** 刷入磁盘的指针 */
  byte *buf_flush;

  /** 日志条目数 */
  ulint n_entries;
  /** 日志文件路径 */
  char *file_name;

  /** 事务信息 */
  const trx_t *trx;

  /** 被修改的索引 */
  dict_index_t *index;

  /** 日志状态 */
  bool closed;     /* 重建完成后关闭日志 */
  bool corrupted;  /* 日志损坏标记 */
};
```

### 3.2 row_log 条目格式

```
每条 row_log 条目记录一个 DML 操作：

┌────────────┬───────┬──────────┬──────────┬──────────┐
│ OP_TYPE(1B)│ n_col │ old_row  │ new_row  │ ...      │
└────────────┴───────┴──────────┴──────────┴──────────┘

OP_TYPE:
  1 = ROW_OP_INSERT (只有 new_row)
  2 = ROW_OP_UPDATE (old_row + new_row)
  3 = ROW_OP_DELETE (只有 old_row)
  4 = ROW_OP_BLOB

old_row / new_row:
  每个字段编码为 (length(4B) + data)
  NULL 字段编码为 length=0xFFFFFFFF
```

### 3.3 row_log_apply() — 增量回放

```cpp
// row0log.h:200 — 声明
// row0log.cc — 实现
dberr_t row_log_apply(const trx_t *trx, dict_index_t *index,
                       row_log_t *log) {

  /* ──── 步骤 1：遍历日志条目 ──── */
  while (log->buf_ptr < log->buf + log->buf_size) {

    /* 读取操作类型 */
    byte op_type = *(log->buf_ptr++);

    switch (op_type) {

      case ROW_OP_INSERT: {
        /* 从 new_row 构建插入行 */
        dtuple_t *row = row_log_read_row(log);
        /* 在新索引/表上插入该行 */
        err = row_ins_clust_index_entry_low(
            ROW_OP_INSERT, index, row, ...);
        break;
      }

      case ROW_OP_DELETE: {
        dtuple_t *row = row_log_read_row(log);
        /* 在新索引上删除该行 */
        err = row_del(index, row, ...);
        break;
      }

      case ROW_OP_UPDATE: {
        dtuple_t *old_row = row_log_read_row(log);
        dtuple_t *new_row = row_log_read_row(log);
        /* 在新索引上应用更新 */
        err = row_upd(index, old_row, new_row, ...);
        break;
      }

      case ROW_OP_BLOB: {
        /* BLOB 特殊处理 */
        break;
      }
    }

    if (err != DB_SUCCESS) {
      return err;
    }
  }

  return DB_SUCCESS;
}
```

### 3.4 row_log 生命周期

```
INPLACE DDL 开始:
  1. row_log_open() — 创建日志文件/缓冲区
  2. 在 DML 路径中添加钩子: 每次 INSERT/UPDATE/DELETE
     都调用 row_log_table_insert/update/delete()
     (row0log.h:108, 121, 153)

  3. 表/索引重建完成（没有并发写入）
     → 短时间 X 锁

  4. row_log_apply() — 回放所有增量日志

  5. 如果回放时又有新 DML → 再次 row_log_apply()

  6. 循环直到 row_log 中没有新操作

  7. row_log_free() — 关闭并释放日志
```

---

## 4. DDL 日志（log0ddl）— 崩溃安全

DDL 操作涉及多个步骤（创建新表 → 复制数据 → 重命名 → 删除旧表），如果中间崩溃，需要恢复一致性。InnoDB 使用 DDL 日志表（`mysql.innodb_ddl_log`）确保 DDL 的原子性。

### 4.1 DDL 日志操作类型

```cpp
// log0ddl.h — DDL 日志操作
enum ddl_log_operation {
  DDL_LOG_OP_DROP_INDEX,        /* 删除索引 */
  DDL_LOG_OP_DROP_TABLE,        /* 删除表 */
  DDL_LOG_OP_RENAME_TABLE,      /* 表重命名 */
  DDL_LOG_OP_FREE_TABLESPACE,   /* 释放表空间 */
  DDL_LOG_OP_DELETE_TABLESPACE, /* 删除表空间文件 */
  DDL_LOG_OP_CREATE_INDEX,      /* 创建索引（回滚时删除） */
};
```

### 4.2 DDL 日志写入

```cpp
// log0ddl.cc — DDL 日志写入
void ddl_log_open(trx_t *trx) {
  /* 在 mysql.innodb_ddl_log 表中创建一条 DDL 日志记录 */
  /* 记录 DDL 操作的类型和涉及的 表/索引 ID */
}

void ddl_log_commit(trx_t *trx) {
  /* DDL 成功 → 删除 DDL 日志表中的对应条目 */
}

void ddl_log_rollback(trx_t *trx) {
  /* DDL 失败 → 从 DDL 日志恢复操作 */
  /* 例如: 已经创建了新索引但 DDL 失败 → 删除新索引 */
}
```

### 4.3 崩溃恢复中的 DDL 日志

```
崩溃后重启:
  └─ recv_recovery_from_checkpoint_start()
      ├─ redo log apply
      │   ├─ 包括 row_log 的 redo 记录
      │   └─ 包括 DDL 日志的 redo 记录
      ├─ 检查 mysql.innodb_ddl_log 表
      │   ├─ 未完成的 CREATE INDEX → 删除已创建的索引
      │   ├─ 未完成的 DROP TABLE → 继续删除
      │   └─ 未完成的 RENAME → 恢复重命名
      └─ 清理所有 DDL 日志条目
```

---

## 5. commit_inplace_alter_table — 提交阶段

```cpp
// handler0alter.cc:1600
bool ha_innobase::commit_inplace_alter_table(
    TABLE *altered_table, Alter_inplace_info *ha_alter_info,
    bool commit) {

  if (commit) {
    return commit_inplace_alter_table_impl(
        altered_table, ha_alter_info, commit);
  }

  /* 回滚:
   * 1. 删除新创建的索引/表
   * 2. 释放 row_log
   * 3. 清理内存 */
  rollback_inplace_alter_table(ha_alter_info);
  return false;
}
```

```cpp
// handler0alter.cc:7427 — 提交实现
bool ha_innobase::commit_inplace_alter_table_impl(
    TABLE *altered_table, Alter_inplace_info *ha_alter_info,
    bool commit) {

  ha_innobase_inplace_ctx *ctx = get_ha_innobase_inplace_ctx(ha_alter_info);

  /* ──── 路径 1: 不需要重建（ADD INDEX / DROP INDEX）──── */
  if (!ctx->need_rebuild()) {
    /* commit_cache_norebuild() @ handler0alter.cc:7198 */
    /* 1. 将新创建的索引添加到数据字典 */
    /* 2. 标记旧索引为已删除 */
    /* 3. 更新 dict_table_t::indexes 链表 */
    return commit_cache_norebuild(ctx, ha_alter_info);
  }

  /* ──── 路径 2: 需要重建表 ──── */
  /* commit_cache_rebuild() @ handler0alter.cc:7076 */
  /* 1. row_log_apply() — 回放最后的增量 */
  /* 2. 新表重命名为旧表名 */
  /* 3. 更新数据字典 */
  /* 4. 释放旧表空间 */
  return commit_cache_rebuild(ctx, ha_alter_info);
}
```

---

## 6. 并行扫描（Parallel Scan）

MySQL 8.0.17+ 引入了并行扫描来加速 DDL 的数据复制：

```cpp
// handler0alter.cc:1466
// handler0alter.cc:1535

/* 并行扫描将表数据分成 N 个范围，每个范围由一个独立线程处理 */
/* N 由 innodb_parallel_read_threads 控制（默认 4）*/

dberr_t ha_innobase::parallel_scan_init(
    ha_innobase_inplace_ctx *ctx) {
  /* 初始化并行扫描上下文 */
  /* 分配 N 个工作线程 */
  /* 将聚簇索引按行 ID 范围切分 */
}

dberr_t ha_innobase::parallel_scan(
    ha_innobase_inplace_ctx *ctx, dberr_t(*callback)(...)) {
  /* 每个线程独立扫描自己的 page 范围 */
  /* 对每行调用 callback（插入新表/索引）*/
}
```

---

## 7. 锁模型分析

### 7.1 不同阶段的锁级别

```
时间线：

PREPARE 阶段:
  │
  ├─ check_if_supported_inplace_alter() ← 无锁
  ├─ prepare_inplace_alter_table()      ← MDL X + dict mutex
  │   ├─ 创建新索引/新表结构
  │   └─ 打开 row_log
  │
  ↓
INPLACE 执行阶段:
  │
  ├─ 持有 MDL S（共享元数据锁）
  │   ├─ 允许并发 DML（SELECT/INSERT/UPDATE/DELETE）
  │   ├─ DML 通过 row_log 记录
  │   └─ 阻塞 DDL（其他 ALTER TABLE）
  │
  ↓
COMMIT 阶段（短时间）:
  │
  ├─ 升级到 MDL X（排他元数据锁）
  │   ├─ 阻塞所有并发操作
  │   ├─ row_log_apply() 最后增量
  │   ├─ 数据字典切换
  │   └─ row_log_free()
  │
  ↓
完成:
  ├─ 释放 MDL
  └─ 正常 DML 恢复
```

### 7.2 锁类型对比

| DDL 操作 | PREPARE | INPLACE | COMMIT |
|----------|---------|---------|--------|
| ADD INDEX | MDL X | MDL S | MDL X |
| ADD INDEX (UNIQUE) | MDL X | MDL S + S 锁表 | MDL X |
| DROP INDEX | MDL X | MDL S | MDL X |
| ADD COLUMN (INPLACE) | MDL X | MDL S | MDL X |
| DROP COLUMN (INPLACE) | MDL X | MDL S | MDL X |
| MODIFY COLUMN | MDL X | MDL S | MDL X |
| DROP PRIMARY KEY | MDL X | MDL X | MDL X |
| RENAME TABLE | MDL X | — | MDL X |
| RENAME INDEX | MDL X | — | MDL X |

---

## 8. ADD INDEX 的构建路径

### 8.1 索引构建流程

```
ALTER TABLE t ADD INDEX idx_a (a), ALGORITHM=INPLACE

  1. prepare_inplace_alter_table()
     ├─ 创建 dict_index_t 描述新索引
     ├─ 申请 space_id 和 page_no（根页）
     └─ row_log_open()

  2. inplace_alter_table()
     ├─ 阶段 1: 扫描聚簇索引
     │   └─ btr_cur_search_to_nth_level() 遍历所有行
     │       └─ 对每行：提取 a 列值
     ├─ 阶段 2: 排序（filesort 或 priority queue）
     │   └─ 按 (a, pk) 排序新索引键
     ├─ 阶段 3: 批量插入新索引 B-Tree
     │   └─ btr_bulk_insert(index, sorted_rows)
     └─ 阶段 4: row_log_apply()

  3. commit_inplace_alter_table()
     ├─ 再次 row_log_apply()
     ├─ dict_index_add_to_cache(table, new_index)
     └─ row_log_free()
```

### 8.2 btr_bulk_insert() — 批量建树

批量建树比逐行插入快得多——它直接构建页面而无需维护 B-Tree 的不变量：

```
btr_bulk_insert(sorted_rows):
  1. 从排序结果中逐行读取
  2. 如果当前页未满 → 追加写入
  3. 如果当前页已满 → 写入下一页（不分裂）
  4. 构建非叶子层（直接链接页面）
  5. 创建根节点

对比逐行插入:
  逐行: O(n log n) 分裂 + 重新平衡
  批量: O(n) 顺序写入 + 一次页面链接
```

---

## 9. 完整调用链总结

### 9.1 ALTER TABLE ... ADD INDEX（INPLACE）

```
SQL: ALTER TABLE t ADD INDEX idx_a (a), ALGORITHM=INPLACE

  │
  └─ Sql_cmd_alter_table::execute()
      │
      ├─ check_if_supported_inplace_alter()
      │   handler0alter.cc:964
      │   ← HA_ALTER_INPLACE_NO_LOCK_AFTER_PREPARE
      │
      ├─ prepare_inplace_alter_table()
      │   handler0alter.cc:1440
      │   └─ prepare_inplace_alter_table_impl()
      │       handler0alter.cc:5440
      │       ├─ dict_mem_index_create()
      │       ├─ dict_index_add_to_cache()
      │       ├─ row_log_open()
      │       └─ ddl_log_open()
      │
      ├─ inplace_alter_table()
      │   handler0alter.cc:1564
      │   └─ inplace_alter_table_impl()
      │       handler0alter.cc:6136
      │       ├─ 扫描聚簇索引，排序
      │       ├─ btr_bulk_insert(new_index, sorted_rows)
      │       │   ← 新索引创建完成
      │       └─ row_log_apply(trx, new_index, log)
      │           ← 回放 DDL 期间的增量
      │           ← 如果仍有新增量，重复 row_log_apply
      │
      ├─ commit_inplace_alter_table(commit=true)
      │   handler0alter.cc:1600
      │   └─ commit_inplace_alter_table_impl()
      │       handler0alter.cc:7427
      │       │
      │       ├─ commit_cache_norebuild()
      │       │   handler0alter.cc:7198
      │       │   ├─ 最后 row_log_apply()
      │       │   ├─ dict_index_add_to_cache(table, index)
      │       │   ├─ ddl_log_commit()
      │       │   ├─ row_log_free()
      │       │   └─ dict_sys_mutex_exit()
      │       │
      │       └─ ddl_log_commit()
      │           log0ddl.cc
      │
      └─ 释放 MDL 锁
```

### 9.2 ALTER TABLE ... ADD COLUMN（INSTANT）

```
SQL: ALTER TABLE t ADD COLUMN c INT, ALGORITHM=INSTANT

  │
  └─ check_if_supported_inplace_alter()
      handler0alter.cc:964
      └─ innobase_support_instant(ALTER_ADD_COLUMN)
          handler0alter.cc:827 → true

  └─ prepare_inplace_alter_table()
      handler0alter.cc:1440
      ├─ 更新 dict_table_t 中的 n_instant_cols
      └─ 设置 version_added/version_dropped

  └─ inplace_alter_table()     ← 什么都不做（只有元数据变更）
      handler0alter.cc:1564
      返回 false（不重建，没有 row_log 需要回放）

  └─ commit_inplace_alter_table()
      handler0alter.cc:1600
      └─ dd_commit_inplace_update_instant_meta()
          handler0alter.cc:4205
          ├─ 写入 n_instant_cols 到 DD
          ├─ ddl_log_commit()
          └─ dict_sys_mutex_enter()
              └─ 更新内存中的 dict_table_t
```

### 9.3 COPY 算法回退

```
SQL: ALTER TABLE t DROP PRIMARY KEY, ADD PRIMARY KEY (b)

  └─ check_if_supported_inplace_alter()
      handler0alter.cc:964
      → HA_ALTER_ERROR

  └─ SQL 层回退到 COPY:
      1. CREATE TABLE t_new (LIKE t, 新结构)
      2. INSERT INTO t_new SELECT * FROM t   ← X 锁
      3. RENAME TABLE t TO t_old, t_new TO t ← X 锁
      4. DROP TABLE t_old                     ← X 锁
```

---

## 10. 源码索引（doom-lsp 验证）

| 函数/结构 | 文件 | 行号 |
|-----------|------|------|
| `ha_innobase_inplace_ctx` struct | `handler0alter.cc` | 181 |
| `need_rebuild()` | `handler0alter.cc` | 310 |
| `innobase_support_instant()` | `handler0alter.cc` | 827 |
| `innobase_need_rebuild()` | `handler0alter.cc` | 928 |
| `ha_innobase::check_if_supported_inplace_alter()` | `handler0alter.cc` | 964 |
| `dd_prepare_inplace_alter_table()` | `handler0alter.cc` | 1381 |
| `dd_commit_inplace_alter_table()` | `handler0alter.cc` | 1392 |
| `dd_commit_inplace_update_instant_meta()` | `handler0alter.cc` | 1411 |
| `ha_innobase::prepare_inplace_alter_table()` | `handler0alter.cc` | 1440 |
| `ha_innobase::parallel_scan_init()` | `handler0alter.cc` | 1466 |
| `ha_innobase::parallel_scan()` | `handler0alter.cc` | 1535 |
| `ha_innobase::parallel_scan_end()` | `handler0alter.cc` | 1558 |
| `ha_innobase::inplace_alter_table()` | `handler0alter.cc` | 1564 |
| `ha_innobase::commit_inplace_alter_table()` | `handler0alter.cc` | 1600 |
| `ha_innobase::prepare_inplace_alter_table_impl()` | `handler0alter.cc` | 5440 |
| `ha_innobase::inplace_alter_table_impl()` | `handler0alter.cc` | 6136 |
| `innobase_online_rebuild_log_free()` | `handler0alter.cc` | 6382 |
| `rollback_inplace_alter_table()` | `handler0alter.cc` | 6435 |
| `commit_try_rebuild()` | `handler0alter.cc` | 6926 |
| `commit_cache_rebuild()` | `handler0alter.cc` | 7076 |
| `commit_try_norebuild()` | `handler0alter.cc` | 7140 |
| `commit_cache_norebuild()` | `handler0alter.cc` | 7198 |
| `ha_innobase::commit_inplace_alter_table_impl()` | `handler0alter.cc` | 7427 |
| `row_log_t` struct | `row0log.cc` | 185 |
| `row_log_table_delete()` | `row0log.h` | 108 |
| `row_log_table_update()` | `row0log.h` | 121 |
| `row_log_table_insert()` | `row0log.h` | 153 |
| `row_log_table_apply()` | `row0log.h` | 180 |
| `row_log_apply()` | `row0log.h` | 200 |
