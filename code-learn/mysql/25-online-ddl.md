# 25. InnoDB 在线 DDL（Online DDL）— 源码分析

> 本文分析 InnoDB 在线 DDL 的实现机制，包括 COPY / INPLACE / INSTANT 三种算法、row_log 增量日志捕获、索引构建（sort + build）、元数据更新与并发控制。核心源文件：`ha_innodb.cc`、`ddl/ddl0merge.cc`、`ddl/ddl0log.cc`、`ddl/ddl0crea.cc`。

---

## 0. 概述

MySQL 8.0 的在线 DDL（Online DDL）允许在不阻塞 DML 的情况下修改表结构。InnoDB 实现了三种 DDL 算法，各有不同的锁级别和适用场景：

| 算法 | 锁级别 | 元数据复制 | 行数据复制 |
|------|--------|-----------|-----------|
| INSTANT | 无锁 | 不复制 | 不复制 |
| INPLACE | 无锁或 S 锁 | 不复制 | 可能复制 |
| COPY | X 锁 | 复制 | 复制 |

### 算法选择流程

```
ALTER TABLE t ADD INDEX ...

  └─ ha_innobase::check_if_supported_inplace_alter()
      ├─ 检查当前算法是否支持此 DDL
      ├─ 检查表锁级别
      └─ 返回支持的算法级别

  └─ ha_innobase::inplace_alter_table()
      ├─ ddl_start()             ← 准备阶段
      ├─ ddl_log_open()          ← 打开 DDL 日志
      ├─ ddl_merge()             ← 执行阶段（含 row_log）
      ├─ ddl_commit()            ← 提交 DDL
      └─ ddl_log_close()         ← 关闭 DDL 日志
```

---

## 1. DDL 算法详解

### 1.1 INSTANT — 即时算法

仅修改元数据，不修改数据文件：

```
ALTER TABLE t ADD COLUMN c INT, ALGORITHM=INSTANT
  →
  ✓ 表定义元数据更新（dict_table_t 中添加列信息）
  ✓ n_instant_cols++, current_version++
  ✓ 已有行的新列填充默认值（读取时计算）
  ✓ 无需重建表、无需复制数据、无需 row_log
  ✓ 不阻塞任何 DML

支持的 DDL:
  - ADD COLUMN（追加到列尾，不修改已有列默认值）
  - DROP COLUMN（逻辑删除列，在行格式中标记隐藏）
  - ADD INDEX（非聚簇索引—INPLACE 实现，非 INSTANT）
  - SET DEFAULT / DROP DEFAULT
```

**限制**：
- 只能追加列（不能插入中间）
- 不能修改列类型、删除索引等
- 每张表最多 64 次 INSTANT ADD COLUMN（受列数限制）

### 1.2 INPLACE — 原地算法

不需要复制整张表，但可能需要重建索引和修改数据页：

```
ALTER TABLE t ADD INDEX idx_a (a), ALGORITHM=INPLACE
  →
  ✓ 不需要重建主表
  ✓ 创建新的二级索引 B-Tree
  ✓ DML 通过 row_log 记录增量
  ✓ 最终合并 row_log 到新索引
  ✓ 不阻塞 SELECT 和 DML（最低要求）

支持的 DDL:
  - ADD INDEX / DROP INDEX
  - ADD FULLTEXT INDEX
  - ADD SPATIAL INDEX
  - RENAME INDEX
  - DROP COLUMN（需重建表时的 fallback）
  - MODIFY COLUMN（部分类型变更，如 VARCHAR 扩容）
  - ALTER INDEX VISIBLE/INVISIBLE
```

### 1.3 COPY — 拷贝算法

最笨重的方案——创建临时表，逐行复制数据，然后重命名：

```
ALTER TABLE t DROP PRIMARY KEY, ADD PRIMARY KEY (b), ALGORITHM=COPY
  →
  1. CREATE TABLE t_new (LIKE t)  — 新表结构
  2. 逐行 SELECT FROM t → INSERT INTO t_new
  3. RENAME TABLE t TO t_old, t_new TO t
  4. DROP TABLE t_old
  ✓ 阻塞所有并发操作（X 锁）
  ✓ 用于不支持 INPLACE 的 DDL
```

---

## 2. row_log — 增量日志捕获

INPLACE DDL 的核心机制：在索引/表重建期间，所有 DML 操作被记录到 `row_log`，重建完成后"回放"到新结构上。

### 2.1 row_log 结构

```cpp
// ddl/ddl0log.h
struct row_log_t {
  /** row_log 操作的缓冲 */
  byte *block;
  /** 当前写入位置 */
  ulint length;
  /** 缓冲总大小 */
  ulint size;

  /** 日志条目队列 */
  row_log_buf_t *buf;
  /** 队列头/尾 */
  row_log_buf_t *first, *last;

  /** 是否已关闭（不再记录新修改）*/
  bool closed;
  /** 记录的操作类型 */
  enum { INSERT, UPDATE, DELETE } type;
};
```

### 2.2 row_log 记录格式

```
每条 row_log 条目:
  ┌────────────────────────────┐
  │ OP_TYPE (1B)               │  ← INSERT=1 / UPDATE=2 / DELETE=3
  │ N_REC (2B)                 │  ← 操作涉及行数（批量操作适用）
  │ REC_SIZE (2B)              │  ← 记录长度
  │ OLD_ROW (可变)              │  ← 更新/删除前的旧行数据
  │ NEW_ROW (可变)              │  ← 插入/更新后的新行数据
  └────────────────────────────┘
```

### 2.3 关键路径

```cpp
// ddl/ddl0log.cc
void row_log_apply(row_log_t *log, dict_index_t *new_index,
                    que_thr_t *thr) {

  /* 逐条回放 row_log 中的操作 */
  for (entry : log->entries) {
    switch (entry->type) {
      case ROW_OP_INSERT:
        /* 在新索引上插入行 */
        btr_cur_ins_lock_and_rec(new_index, entry->new_row, ...);
        break;

      case ROW_OP_UPDATE:
        /* 在新索引上更新行 */
        btr_cur_upd_lock_and_rec(new_index, entry->old_row,
                                  entry->new_row, ...);
        break;

      case ROW_OP_DELETE:
        /* 在新索引上删除行 */
        btr_cur_del_lock_and_rec(new_index, entry->old_row, ...);
        break;
    }
  }
}
```

---

## 3. 索引构建（INPLACE）

### 3.1 ddl_merge() — 索引合并构建

```cpp
// ddl/ddl0merge.cc
void ddl_merge(dict_table_t *table, dict_index_t **new_indexes) {

  /* ──── 阶段 1：排序构建新索引 ──── */
  for (index : new_indexes) {
    /* 扫描原表聚簇索引，按新索引键排序 */
    /* 使用 filesort 或 priority queue */

    /* 批量插入新索引 B-Tree */
    /* 使用 btr_bulk_insert 快速批量建树 */
    btr_bulk_insert(index, sorted_rows);
  }

  /* ──── 阶段 2：应用 row_log（增量回放）──── */
  /* 在阶段 1 扫描过程中产生的 DML 修改都记录在 row_log 中 */
  /* 现在回放这些修改到新索引上 */
  row_log_apply(row_log, new_indexes, ...);
  /* 如果回放期间又有新修改 → 重复 row_log_apply */
  // 最多重复 row_log_apply 直到 row_log 为空

  /* ──── 阶段 3：元数据切换 ──── */
  /* 新索引替换旧索引的引用 */
  dict_index_add_to_cache(table, new_index);
}
```

### 3.2 并发控制

```cpp
// ha_innodb.cc — inplace_alter_table()
dberr_t ha_innobase::inplace_alter_table(...) {
  /* ──── 阶段 1：准备（获取 X 锁）──── */
  if (need_exclusive_lock) {
    /* 短时间 X 锁：禁止 DML，准备 row_log */
    row_log_open(...);
  }

  /* ──── 阶段 2：构建（允许 DML）──── */
  /* 释放 X 锁，升级为 S 锁（或完全无锁）*/
  /* DML 操作通过 row_log 记录 */

  /* ──── 阶段 3：元数据切换（再次 X 锁）──── */
  if (need_exclusive_lock) {
    /* 短时间 X 锁：锁定 DML */
    /* 应用最后一次 row_log */
    row_log_apply(row_log, new_index, ...);
    /* 更新数据字典 */
    dd_table_change(...);
  }
}
```

**锁需求矩阵**：

| DDL 操作 | 阶段 1 | 阶段 2 | 阶段 3 |
|----------|--------|--------|--------|
| ADD INDEX | X | 无锁 | X |
| DROP INDEX | X | 无锁 | X |
| ADD COLUMN (INSTANT) | 无锁 | — | 无锁 |
| ADD COLUMN (INPLACE) | X | X | X |
| MODIFY COLUMN | X | S | X |
| DROP COLUMN (INPLACE) | X | X | X |

---

## 4. DDL 日志与崩溃恢复

DDL 操作涉及大量元数据修改。InnoDB 使用 DDL 日志（mysql.innodb_ddl_log 表）来确保 DDL 的原子性：

```cpp
// ddl/ddl0log.cc
void ddl_log_open(trx_t *trx) {
  /* 在 mysql.innodb_ddl_log 表中创建一条日志 */
  /* 记录 DDL 的类型、表 ID、新/旧索引 ID */
}

void ddl_log_commit(trx_t *trx) {
  /* DDL 成功 → 删除 DDL 日志条目 */
}

void ddl_log_rollback(trx_t *trx) {
  /* DDL 失败 → 从 DDL 日志恢复 */
  /* 例如: 删除已创建的新索引 */
}
```

恢复过程：

```
崩溃 → 重启
  ├─ redo log apply
  ├─ 检查 mysql.innodb_ddl_log
  │   ├─ 如果发现未完成的 DDL 日志
  │   │   ├─ 已完成但未提交 → 提交（apply 剩余 row_log）
  │   │   └─ 未完成 → 回滚（删除临时索引/表）
  │   └─ 清理所有 DDL 日志
  └─ 正常启动
```

---

## 5. COPY 算法的执行路径

```cpp
// ha_innodb.cc — COPY 算法
dberr_t ha_innobase::create_like_table(...) {
  /* 创建新表（包含新结构）*/
  dict_create_table(...);
  /* 打开新表 */
  dd_table_open_on_id(new_table_id, ...);
}

dberr_t ha_innobase::alter_copy(...) {
  /*
   * 此路径在 SQL 层实现：
   * 1. CREATE TABLE t_new LIKE t
   * 2. INSERT INTO t_new SELECT * FROM t
   * 3. RENAME TABLE t TO t_old, t_new TO t
   * 4. DROP TABLE t_old
   */
  /* Innodb 层只负责在适当的时候持有 X 锁 */
}

// 锁行为：
// 步骤 1: 获取 MDL 排他锁（禁止所有并发）
// 步骤 2: 逐行复制（其他连接等待）
// 步骤 3: 原子重命名（瞬间完成）
// 步骤 4: 释放锁
```

---

## 6. 总结

### 算法选择优先级

```
INSTANT > INPLACE > COPY

对于支持的 DDL 操作:
  1. 尝试 INSTANT（最快，无锁）
  2. 不满足条件 → 尝试 INPLACE（可能无阻塞）
  3. 不满足条件 → fallback 到 COPY（完全阻塞）
```

### 监控

```sql
-- 查看当前 DDL 进度
SHOW PROCESSLIST;

-- 查看 row_log 使用量
SHOW STATUS LIKE 'Innodb_row_lock_current_waits';
SHOW STATUS LIKE 'Innodb_ddl_%';
```

### 源码索引

| 函数/结构 | 文件 | 关键作用 |
|-----------|------|---------|
| `ha_innobase::inplace_alter_table()` | `ha_innodb.cc` | INPLACE DDL 主入口 |
| `ha_innobase::check_if_supported_inplace_alter()` | `ha_innodb.cc` | 检查算法支持 |
| `row_log_t` | `ddl/ddl0log.h` | row_log 结构 |
| `row_log_open()` | `ddl/ddl0log.cc` | 打开增量日志 |
| `row_log_apply()` | `ddl/ddl0log.cc` | 回放增量日志 |
| `ddl_merge()` | `ddl/ddl0merge.cc` | 索引合并构建 |
| `ddl_log_open()` | `ddl/ddl0log.cc` | DDL 日志记录 |
| `ddl_log_commit()` | `ddl/ddl0log.cc` | DDL 日志提交 |
| `ddl_log_rollback()` | `ddl/ddl0log.cc` | DDL 日志回滚 |
