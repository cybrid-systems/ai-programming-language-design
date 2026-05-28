# 25. InnoDB 在线 DDL (Online DDL)

> 本文分析 InnoDB 在线 DDL 的实现机制，包括 COPY/INPLACE/INSTANT 三种算法、row_log 日志捕获、索引构建与元数据转换。核心文件：`ha_innodb.cc`、`ddl/ddl0merge.cc`、`ddl/ddl0log.cc`。

---

## 1. 概述

InnoDB 支持三种 DDL 算法，根据操作类型和执行参数自动选择：

| 算法 | 说明 | 锁行为 | 支持版本 |
|------|------|--------|----------|
| **INSTANT** | 仅修改元数据 | 读锁 | MySQL 8.0.12+ |
| **INPLACE** | 原地重建表 | 写锁（短时）/ 读锁（构建期） | MySQL 5.6+ |
| **COPY** | 创建临时表逐行复制 | 排他锁 | 全版本 |

---

## 2. 三阶段协议

DDL 分为三个逻辑阶段，每个阶段决定使用的算法和需要获取的锁级别：

```
PREPARE → EXECUTE → COMMIT
```

| 阶段 | 入口函数 | 📂 行号 |
|------|----------|---------|
| PREPARE | `prepare_inplace_alter_table()` | `ha_innodb.cc` |
| EXECUTE | 后台构建线程 + 前台处理 | `ddl/ddl0merge.cc` |
| COMMIT | `commit_inplace_alter_table()` | `ha_innodb.cc` |

### 2.1 PREPARE 阶段

- 分析用户请求的操作类型（ADD INDEX、DROP COLUMN、MODIFY 等）
- 选择算法：INSTANT / INPLACE / COPY
- 分配 row_log 缓冲区（INPLACE 需要）
- 在数据字典中创建新的索引对象，标记为 `ONLINE_INDEX_CREATION`

### 2.2 EXECUTE 阶段

- 对于 INPLACE：降级为共享 MDL 锁，允许并发 DML
- 后台扫描聚簇索引，为新索引构建 B+Tree
- 同时通过 row_log 记录并发的 INSERT/UPDATE/DELETE

### 2.3 COMMIT 阶段

- 加排他 MDL 锁，阻止新 DML
- 回放 row_log 中剩余的变更
- 原子性切换索引（新索引替换旧索引）
- 删除旧索引对象

---

## 3. INPLACE 索引构建与 row_log 机制

### 3.1 构建流程

```
CREATE INDEX idx ON t (col) ALGORITHM=INPLACE

  ├─ PREPARE: 加排他 MDL
  │   ├─ 字典中创建 dict_index_t（ONLINE_INDEX_CREATION 状态）
  │   ├─ 初始化 row_log 链表的头和尾
  │   └─ 降级为共享 MDL
  │
  ├─ EXECUTE: 扫描聚簇索引
  │   ├─ 逐行读取聚簇索引记录
  │   ├─ 为新索引构建 entry → 插入到新 B+Tree
  │   └─ DML 并发时通过 row_log 记录变更
  │
  ├─ 回放 row_log:
  │   ├─ row_log_apply() 处理构建期间的增量变更
  │   └─ 重复回放直到无增量
  │
  └─ COMMIT:
      ├─ 加排他 MDL
      ├─ 回放最后的 row_log
      ├─ 标记 ONLINE_INDEX_COMPLETE
      └─ 删除旧索引
```

### 3.2 row_log 结构

```cpp
// ddl/ddl0merge.cc — row_log 相关
// 每个处于在线构建中的索引用链表存储 DML 变更
// 每个变更条目包含：操作类型（INSERT/UPDATE/DELETE）+ 原始索引元组
// 构建结束后遍历链表，回放所有变更
```

关键函数：

| 函数 | 文件 | 说明 |
|------|------|------|
| `row_log_online_op()` | `ddl/ddl0log.cc` | 记录 DML 操作到 row_log |
| `row_log_apply()` | `ddl/ddl0merge.cc` | 回放 row_log 中的变更 |

---

## 4. INSTANT ADD/DROP COLUMN

INSTANT 算法只修改数据字典元数据，不涉及表数据重组：

```cpp
// dict0mem.h:1925 — dict_table_t 相关字段
unsigned n_instant_cols : 10;   // 第一次 INSTANT ADD 前的列数

// dict0mem.h:485 — dict_col_t 新增字段
row_version_t version_added;    // 该列被添加的行版本号
row_version_t version_dropped;  // 该列被删除的行版本号
```

- 新增列的值存储在行记录的默认值数组中（物理行末尾）
- 最多支持 64 次 INSTANT ADD/DROP COLUMN
- 超出限制后自动回退到 INPLACE 重建

---

## 5. 索引状态机

```cpp
// dict0mem.h:1067 — dict_index_t 的在线状态
enum online_status_t {
  ONLINE_INDEX_CREATION,        // 正在构建中
  ONLINE_INDEX_COMPLETE,        // 构建完成
  ONLINE_INDEX_ABORTED,         // 构建失败中止
  ONLINE_INDEX_ABORTED_DROPPED, // 中止后标记删除
};
```

DML 操作通过 `dict_index_is_online_ddl()` 判断索引状态，仅在 `ONLINE_INDEX_COMPLETE` 时写入新索引。

---

## 6. DDL 与 MVCC 兼容

在线 DDL 构建新索引时，隐藏列 `DB_TRX_ID` 被复制到新索引记录中。并发事务的可见性判断仍通过旧索引的 `ReadView` 完成，不会产生不一致。

---

## 7. 总结

1. **三阶段协议**（PREPARE/EXECUTE/COMMIT）确保 DDL 与 DML 的安全并发。
2. **row_log 日志**：构建期间的增量变更记录在链表中，构建完成后回放。
3. **索引状态机**：`ONLINE_INDEX_CREATION → COMPLETE / ABORTED` 管理生命周期。
4. **INSTANT 加速**：仅改元数据，不重建表，适合快速加列。
5. **INSTANT 限制**：最多 64 次，超出需回退 INPLACE。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `ha_innodb.cc` | 6552 | `prepare_inplace_alter_table()` 注释引用 |
| `ddl/ddl0merge.cc` | 463 | `Merge_file_sort::sort()` 索引构建排序 |
| `ddl/ddl0log.cc` | — | `row_log_online_op()` / `row_log_apply()` |
| `dict0mem.h` | 1925 | `n_instant_cols` 等 INSTANT 字段 |
