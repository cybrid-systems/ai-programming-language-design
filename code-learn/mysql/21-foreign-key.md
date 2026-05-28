# 21. InnoDB 外键与约束（Foreign Key & Constraints）— 源码深度分析

> 本文分析 InnoDB 外键约束的完整实现，包括内存表示、缓存注册、DML 中的约束检查逻辑、级联操作（CASCADE / SET NULL / RESTRICT）、锁策略与死锁预防。核心源文件：`dict0mem.h`、`dict0dict.cc`、`row0ins.cc`、`row0upd.cc`、`row0del.cc`。

---

## 0. 概述

InnoDB 在**内核层**实现外键约束——这意味着约束检查发生在 InnoDB 的 `row_ins`/`row_upd`/`row_del` 函数中，而不是 MySQL Server 的 handler 层。这种设计的优势：

1. **事务一致性**：约束检查与行操作在同一个 MTR 中完成，保证原子性
2. **MVCC 感知**：外键检查能看到当前事务的版本视图，不会因快照不一致而产生误判
3. **死锁检测**：InnoDB 的死锁检测器可以正确处理外键约束引发的额外锁等待

### 外键的层次

```
MySQL Server 层:
  SHOW CREATE TABLE t → FOREIGN KEY (a) REFERENCES t2(b)

  ↓ DDL 创建时

InnoDB 层:
  dict_foreign_t {referenced_table, foreign_cols, referenced_cols, type, ...}

  └── 注册到 dict_table_t::foreign_set
  └── 注册到 dict_table_t::referenced_set

  ↓ DML 执行时

约束检查:
  INSERT:  检查外键列的值在引用的表中是否存在
  UPDATE:  检查新旧值是否违反约束
  DELETE:  检查是否仍有行引用被删的值
           → 触发 CASCADE / SET NULL / RESTRICT / NO ACTION
```

---

## 1. 核心数据结构

### 1.1 dict_foreign_t — 外键约束描述

```cpp
// dict0mem.h:1673
struct dict_foreign_t {
  /** 外键约束名（如 "fk_table_a"） */
  const char *name;

  /** 约束 ID（在表空间内唯一） */
  unsigned id : 32;

  /** 外键类型标志 */
  unsigned type : 8;
  /* 位定义: */
  /* 0x01 = DICT_FOREIGN_ON_UPDATE_CASCADE */
  /* 0x02 = DICT_FOREIGN_ON_UPDATE_SET_NULL */
  /* 0x04 = DICT_FOREIGN_ON_DELETE_CASCADE */
  /* 0x08 = DICT_FOREIGN_ON_DELETE_SET_NULL */
  /* 0x10 = DICT_FOREIGN_ON_DELETE_NO_ACTION */
  /* 0x20 = DICT_FOREIGN_ON_UPDATE_NO_ACTION */

  /** 引用表名（全限定 "db/table"） */
  table_name_t *referenced_table_name;

  /** 引用表对象（运行时打开并缓存） */
  dict_table_t *referenced_table;

  /** 引用表的索引（用于查找匹配行） */
  dict_index_t *referenced_index;

  /** 外键列数 */
  unsigned n_fields : 12;

  /** 外键列在本表中的列号数组 */
  unsigned *foreign_col_ids;

  /** 引用表中外键对应的列号数组 */
  unsigned *referenced_col_ids;

  /** 用于内存堆管理的句柄 */
  mem_heap_t *heap;
};
```

**`type` 标志位组合**：

```cpp
// dict0mem.h
#define DICT_FOREIGN_ON_UPDATE_CASCADE       (1 << 0)  /* 1 */
#define DICT_FOREIGN_ON_UPDATE_SET_NULL      (1 << 1)  /* 2 */
#define DICT_FOREIGN_ON_DELETE_CASCADE       (1 << 2)  /* 4 */
#define DICT_FOREIGN_ON_DELETE_SET_NULL      (1 << 3)  /* 8 */
#define DICT_FOREIGN_ON_DELETE_NO_ACTION     (1 << 4)  /* 16 */
#define DICT_FOREIGN_ON_UPDATE_NO_ACTION     (1 << 5)  /* 32 */
```

RESTRICT 是默认行为，没有对应的标志位——即 `type == 0`。

### 1.2 外键集合容器

```cpp
// dict0mem.h:1763
/* 外键集合：按 referenced_table_name 排序 */
struct dict_foreign_set {
  /* 使用排序后的 vector 存储，允许二分查找 */
  using Set = std::vector<dict_foreign_t *>;

  Set m_set;

  void insert(dict_foreign_t *fk);
  void erase(dict_foreign_t *fk);
};

/* 在 dict_table_t 中 */
struct dict_table_t {
  dict_foreign_set foreign_set;      /* 本表定义的外键（本表引用其他表） */
  dict_foreign_set referenced_set;   /* 被其他表引用的外键（其他表引用本表） */
};
```

**`foreign_set` vs `referenced_set`**：

```
表 A (外键表):               表 B (引用表):
  FOREIGN KEY (a_id)            (被引用)
    REFERENCES B(id)
                  │                    │
  foreign_set: [fk_A_B]     referenced_set: [fk_A_B]
                  │                    │
                  └── 与 B 的 referenced_set 双向关联
```

两种集合的用途：

| 集合 | 检查场景 |
|------|---------|
| `foreign_set` | 修改本表时检查引用的行是否存在 |
| `referenced_set` | 修改被引用的表时检查是否有外键依赖 |
| `foreign_set` | 级联操作时找到需要级联的目标 |
| `referenced_set` | DELETE/UPDATE 时找到需要 ROW (共享/排他) 锁的表 |

---

## 2. 外键注册到缓存

### 2.1 dict_foreign_add_to_cache()

```cpp
// dict0dict.cc:3423
void dict_foreign_add_to_cache(
    dict_foreign_t *foreign, const char **col_names,
    const char **ref_col_names, bool check_charsets) {

  /* ──── 步骤 1：计算列偏移 ──── */
  /* 将外键列列名转换为 dict_col_t * 引用 */
  dict_foreign_find_cols(foreign, col_names, ref_col_names, check_charsets);

  /* ──── 步骤 2：查找引用索引 ──── */
  /* 外键需要有索引来高效地查找引用的行 */
  /* 如果没有合适的索引，创建 ALTER TABLE 时会报错 */
  foreign->referenced_index = dict_foreign_find_index(
      foreign->referenced_table,      /* 引用表 */
      foreign->referenced_col_ids,    /* 引用列 */
      foreign->n_fields,              /* 列数 */
      foreign,                        /* 外键 */
      true,                           /* check_charsets */
      false,                          /* check_null */
      NULL);                          /* found */

  /* ──── 步骤 3：双向链接 ──── */
  /* 本表的 foreign_set */
  foreign->referenced_table->acquire();  /* 增加引用计数 */
  hash_table_t *hash = foreign->referenced_table->referenced_set;
  hash_table->insert(foreign->name, foreign);

  /* 引用表的 referenced_set */
  hash_table_t *hash = foreign->table->foreign_set;
  hash_table->insert(foreign->name, foreign);

  /* ──── 步骤 4：建立反向索引（如有必要）──── */
  dict_foreign_build_reverse_check(foreign);
}
```

**索引查找 (`dict_foreign_find_index`) 的优先级**：

```
1. 查找与引用列完全匹配的 PRIMARY KEY
2. 查找与引用列完全匹配的 UNIQUE 索引
3. 查找与引用列完全匹配的普通索引
4. 如果都没有 → 报错 "can't create foreign key constraint"

外键要求引用表必须有索引（主键或唯一键优先）
这样外键检查时可以走索引快速定位行
```

### 2.2 外键缓存路径

```
CREATE TABLE child (a INT, b INT, FOREIGN KEY (a) REFERENCES parent(id))
  └─ dict_create_table() → 创建 child 的 dict_table_t
      └─ dict_mem_foreign_create() → 分配 dict_foreign_t
      └─ 设置 columns / ref_columns
      └─ dict_foreign_add_to_cache(foreign)
          ├─ dict_foreign_find_cols() ← 建立列映射
          ├─ dict_foreign_find_index() ← 查找 parent 上的索引
          ├─ child->foreign_set.insert(foreign) ← 存入
          └─ parent->referenced_set.insert(foreign) ← 存入引用方
```

---

## 3. 约束检查路径

### 3.1 INSERT 检查 — row_ins_check_foreign_constraint()

当向有外键的表插入一行时，必须检查引用的值在父表中存在：

```cpp
// row0ins.cc:1416
dberr_t row_ins_check_foreign_constraint(
    dict_foreign_t *foreign,      /* 要检查的外键 */
    que_thr_t *thr,               /* 当前查询线程 */
    bool new_inserted) {           /* 是否为新插入的行 */

  dict_index_t *index = foreign->referenced_index;
  dtuple_t *tuple;
  mem_heap_t *heap;

  /* ──── 步骤 1：构建搜索元组 ──── */
  /* 从插入行的外键列值构建一个元组，用于在父表索引中查找 */
  heap = mem_heap_create(256, UT_LOCATION_HERE);
  tuple = dict_foreign_build_search_tuple(foreign, thr, heap);

  if (tuple == NULL) {
    /* 外键列中有 NULL → 允许（SQL 标准允许 NULL 不检查） */
    goto exit_func;
  }

  /* ──── 步骤 2：在父表索引上查找行 ──── */
  btr_pcur_t pcur;
  bool found;

  found = btr_pcur_open_with_no_init(
      index,                        /* 父表索引 */
      tuple,                        /* 搜索元组 */
      PAGE_CUR_GE,                  /* ≥ 模式 */
      BTR_SEARCH_LEAF,              /* 搜索级别 */
      &pcur,                        /* 游标 */
      thr->get_mtr());              /* MTR */

  /* ──── 步骤 3：检查结果 ──── */
  if (!found) {
    /* 父表中没有匹配行 → 约束违反 */
    thr->get_trx()->error_state = DB_FOREIGN_CONSTRAINT;
    dberr_t err = DB_FOREIGN_CONSTRAINT;
    goto exit_func;
  }

  /* ──── 步骤 4：获取（或尝试获取）锁 ──── */
  /* 定位到匹配行后，需要加锁防止它被并发删除 */
  rec_t *rec = btr_pcur_get_rec(&pcur);
  lock_rec_insert_check_and_lock(rec, thr);  /* NEXT-KEY LOCK */

  exit_func:
    btr_pcur_close(&pcur);
    mem_heap_free(heap);
    return err;
}
```

**NULL 值处理**：

SQL 标准规定：如果外键列中有任何 NULL，则跳过检查。InnoDB 的处理在 `dict_foreign_build_search_tuple` 中：

```cpp
// row0ins.cc — 构建搜索元组时
dtuple_t *dict_foreign_build_search_tuple(
    dict_foreign_t *foreign, que_thr_t *thr, mem_heap_t *heap) {

  for (i = 0; i < foreign->n_fields; i++) {
    col_id = foreign->foreign_col_ids[i];
    dfield = thr->row->seg[col_id];

    if (dfield_is_null(dfield)) {
      /* 任何一列为 NULL → 跳过整个检查 */
      return nullptr;
    }

    dtuple_set_nth_field(tuple, i, dfield);
  }
  return tuple;
}
```

### 3.2 UPDATE 检查 — row_upd_check_references_constraints()

当更新被引用表的主键/唯一键时，需要检查是否仍被外键引用：

```cpp
// row0upd.cc:176
dberr_t row_upd_check_references_constraints(
    dict_table_t *table,     /* 被引用的表（parent） */
    const dtuple_t *old_row, /* 更新前的旧行 */
    const dtuple_t *new_row, /* 更新后的新行 */
    que_thr_t *thr) {

  for (auto &foreign : table->referenced_set) {
    /* ──── 步骤 1：检查被更新的列是否在外键中 ──── */
    bool key_changed = false;
    for (i = 0; i < foreign->n_fields; i++) {
      col_id = foreign->referenced_col_ids[i];
      if (cmp_dtuple_rec(old_row, col_id, new_row, col_id) != 0) {
        key_changed = true;
        break;
      }
    }

    if (!key_changed) continue;  /* 外键列没变 → 不需要检查 */

    /* ──── 步骤 2：检查旧值是否仍有子行引用 ──── */
    old_tuple = dict_foreign_build_search_tuple_from_ref(
        foreign, old_row, heap);
    // 在子表上查找是否有引用旧值的行
    found = btr_pcur_open(子表索引, old_tuple, ...);
    if (found) {
      /* ──── 步骤 3：根据外键 type 执行级联 ──── */
      switch (foreign->type) {
        case DICT_FOREIGN_ON_UPDATE_CASCADE:
          row_upd_cascade_update(foreign, old_row, new_row, thr);
          break;
        case DICT_FOREIGN_ON_UPDATE_SET_NULL:
          row_upd_cascade_set_null(foreign, old_row, thr);
          break;
        case DICT_FOREIGN_ON_UPDATE_NO_ACTION:
          /* 延迟检查（事务提交时检查）*/
          break;
        default: /* RESTRICT */
          thr->get_trx()->error_state = DB_FOREIGN_CONSTRAINT;
          return DB_FOREIGN_CONSTRAINT;
      }
    }
  }

  return DB_SUCCESS;
}
```

**完整 UPDATE 路径**：

```
UPDATE parent SET id = 100 WHERE id = 1

  └─ row_upd_check_references_constraints()
      ├─ 遍历 parent->referenced_set
      ├─ 外键列 (id) 确实被修改
      ├─ 在 child 表上查找引用 old_id=1 的行
      ├─ 找到 → 检查 foreign->type
      │   ├─ CASCADE:   递归把 child 的 a 也从 1 更新为 100
      │   ├─ SET NULL:  把 child 的 a 设为 NULL
      │   ├─ NO ACTION: 记录延迟检查（提交时报错 if still referenced）
      │   └─ RESTRICT:  报错 FB_FOREIGN_CONSTRAINT
      └─ 没找到 → 允许 UPDATE
```

### 3.3 DELETE 检查 — row_del_check_references_constraints()

当从被引用表中删除一行时：

```cpp
// row0del.cc — 简化
dberr_t row_del_check_references_constraints(
    dict_table_t *table, dict_index_t *index,
    const dtuple_t *row, que_thr_t *thr) {

  for (auto &foreign : table->referenced_set) {
    auto tpl = dict_foreign_build_search_tuple_from_ref(foreign, row, heap);
    bool found = btr_pcur_open(sub_table_index, tpl, ...);

    if (!found) continue;

    switch (foreign->type) {
      case DICT_FOREIGN_ON_DELETE_CASCADE:
        row_del_cascade_delete(foreign, row, thr);
        break;
      case DICT_FOREIGN_ON_DELETE_SET_NULL:
        row_upd_cascade_set_null(foreign, row, thr);
        break;
      case DICT_FOREIGN_ON_DELETE_NO_ACTION:
        /* 延迟检查 */
        break;
      default: /* RESTRICT */
        return DB_FOREIGN_CONSTRAINT;
    }
  }

  return DB_SUCCESS;
}
```

---

## 4. 级联操作

### 4.1 CASCADE — 递归级联

```cpp
// row0upd.cc — CASCADE UPDATE（简化）
static void row_upd_cascade_update(
    dict_foreign_t *foreign,
    const dtuple_t *old_row, const dtuple_t *new_row,
    que_thr_t *thr) {

  /* 1. 在子表的索引上定位所有引用旧值的行 */
  auto sub_index = dict_table_get_first_index(foreign->table);
  auto tpl = build_search_tuple(foreign, old_row, heap);
  btr_pcur_open(sub_index, tpl, PAGE_CUR_GE, ...);

  while (匹配的行) {
    /* 2. 构建 UPDATE 操作：将外键列从旧值改为新值 */
    dtuple_t *upd_row = row_copy(rec, heap);
    for (i = 0; i < foreign->n_fields; i++) {
      col_id = foreign->foreign_col_ids[i];
      /* 用新行对应列的引用列值替换 */
      dfield_set_val(upd_row, col_id, new_row->fields[referenced_col_ids[i]]);
    }

    /* 3. 递归执行 UPDATE（可能会再次触发外键检查）*/
    row_upd(upd_row, thr);  /* ← 递归！子表的子表也会被更新 */

    /* 4. 移动到下一条 */
    btr_pcur_move_to_next(...);
  }
}
```

**CASCADE 可能导致的递归链**：

```
Table A → FK(a_ref) REFERENCES B(b)
Table B → FK(b_ref) REFERENCES C(c)

UPDATE C SET c = 10 WHERE c = 5
  └─ CASCADE → UPDATE B SET b_ref = 10 WHERE b_ref = 5
      └─ CASCADE → UPDATE A SET a_ref = 10 WHERE a_ref = 5

总更新行数 = C 的 1 行 + B 的所有引用行 + A 的所有引用行
```

### 4.2 SET NULL

```cpp
// row0upd.cc — SET NULL（简化）
static void row_upd_cascade_set_null(
    dict_foreign_t *foreign,
    const dtuple_t *row, que_thr_t *thr) {

  /* 在子表的索引上定位所有引用旧值的行 */
  /* 将外键列设为 NULL */
  for (i = 0; i < foreign->n_fields; i++) {
    col_id = foreign->foreign_col_ids[i];
    dfield_set_null(upd_row, col_id);
  }

  row_upd(upd_row, thr);  /* 递归 */
}
```

### 4.3 级联深度限制

InnoDB 限制了级联的最大嵌套深度（`dict_foreign_max_cascade_level = 15`），防止无限递归：

```cpp
// row0upd.cc
void row_upd_cascade(...) {
  if (thr->get_trx()->cascade_level >= dict_foreign_max_cascade_level) {
    thr->get_trx()->error_state = DB_FOREIGN_CASCADE_TOO_DEEP;
    return;
  }
  thr->get_trx()->cascade_level++;

  /* 执行级联... */

  thr->get_trx()->cascade_level--;
}
```

超过 15 层深度时返回 `DB_FOREIGN_CASCADE_TOO_DEEP` 错误，SQL 层转换为错误信息。

---

## 5. 锁策略与死锁

### 5.1 外键检查时的锁模型

```
INSERT INTO child VALUES (1, ...) WHERE FK(a) REFERENCES parent(id)
  └─ 在 child 上插入 → 正常行锁
  └─ 查 parent(id=1) → 在 parent 上: LOCK_S | LOCK_REC_NOT_GAP
      （共享锁，不锁间隙——因为只查等值匹配）

DELETE FROM parent WHERE id = 1
  └─ 在 parent 上 → 正常行锁
  └─ 查 child 是否有引用行
      └─ 没有 → 允许删除，释放
      └─ 有 → RESTRICT: LOCK_S | LOCK_REC_NOT_GAP 在 child 引用行上
            → CASCADE: LOCK_X | LOCK_ORDINARY 准备删除

UPDATE parent SET id = 100 WHERE id = 1
  └─ 在 parent 上 → X 锁 (new id 和 old id 要锁)
  └─ 查 child 引用 → 同 DELETE 逻辑
```

### 5.2 死锁场景

```
事务 A: INSERT INTO child VALUES (1, ...)   事务 B: DELETE FROM parent WHERE id = 1
  ├─ 锁 child 插入行 (X)                      ├─ 锁 parent 行 (X)
  ├─ lock parent.id=1 (S)                      ├─ lock child 引用行 (S)
  └─ 等待...                                        └─ 等待 child X 锁升级（因为 CASCADE）
                                                    → 等待 child X

      ┌─ A 持有 child X, 等待 parent S
      └─ B 持有 parent X, 等待 child X
      → 死锁！

    死锁检测器:
      InnoDB 的 lock_deadlock_find() 遍历事务锁等待图
      → 找到 A ↔ B 闭环
      → 选择事务 B（或 A，取决于回滚成本）回滚
```

### 5.3 死锁预防建议

1. **外键列建索引**：没有索引的列做外键检查时，查找需要全表扫描，大幅增加死锁概率
2. **同方向访问**：所有事务按相同的表顺序访问（先 parent 后 child），避免交叉锁
3. **限制级联深度**：避免长链级联操作
4. **减少外键的引用表数量**：一张表的外键引用越少，锁竞争越低

---

## 6. 外键索引强制

当创建外键时，InnoDB 会**自动为外键列创建索引**（如果不存在）：

```cpp
// dict0crea.cc — 简化
dberr_t dict_create_foreign_constraint(...) {
  /* 检查本表外键列是否有索引 */
  auto idx = dict_table_get_first_index(table);
  bool found = false;
  for (auto i = idx; i != nullptr; i = UT_LIST_GET_NEXT(indexes, i)) {
    if (索引的字段与外键列匹配) {
      found = true;
      break;
    }
  }

  if (!found) {
    /* 自动创建索引 */
    auto new_idx = dict_mem_index_create("...");
    new_idx->type = DICT_UNIQUE;  /* 如果未指定，作为普通索引创建 */
    dict_index_add_to_cache(table, new_idx, ...);
  }
}
```

**为什么要强制索引？**

没有索引的外键检查需要全表扫描子表来查找引用行——这在百万行级别时性能灾难。索引确保外键检查始终是 O(log n) 的 B-Tree 搜索。

---

## 7. 性能考量

### 7.1 外键的性能开销

| 操作 | 无外键 | 有外键 |
|------|--------|--------|
| INSERT child | 1 次 B-Tree 写 | + 1 次父表索引查找 + S 锁 |
| DELETE parent | 1 次 B-Tree 删除 | + N 次子表索引查找 + 可能的级联 |
| UPDATE parent FK col | 1 次 B-Tree 更新 | + N 次子表索引查找 + 级联（CASCADE 或 RESTRICT） |

**生产建议**：

- **高并发 OLTP**：避免外键约束，应用层处理引用完整性
- **低并发 / 数据一致性要求高**：使用外键，接受 10-30% 的性能开销
- **CASCADE 链**：确保链不长（< 3 层），否则级联操作可能长时间锁表

### 7.2 外键与复制

在 MySQL 复制环境中，外键可能导致**主从不一致**。例如：

```
主库:
  INSERT INTO child VALUES (1) → 检查 parent.id=1 (存在) → 成功
  然后: DELETE FROM parent WHERE id = 1

从库:
  先执行: DELETE FROM parent WHERE id = 1 (成功)
  然后: INSERT INTO child VALUES (1) → parent 已没 id=1 → 约束违反！→ 复制中断
```

解决方案：`SET FOREIGN_KEY_CHECKS = 0` 在从库复制线程中临时关闭检查（InnoDB 的复制线程默认会处理这个）。

---

## 8. 源码索引

| 函数/结构 | 文件 | 行号 | 关键作用 |
|-----------|------|------|---------|
| `dict_foreign_t` struct | `dict0mem.h` | 1673 | 外键约束描述 |
| `dict_foreign_set` | `dict0mem.h` | 1763 | 外键集合容器 |
| `DICT_FOREIGN_ON_*` 标志 | `dict0mem.h` | — | 外键类型位定义 |
| `dict_foreign_add_to_cache()` | `dict0dict.cc` | 3423 | 外键注册到缓存 |
| `dict_foreign_find_index()` | `dict0dict.cc` | 3337 | 查找引用索引 |
| `dict_foreign_find_cols()` | `dict0dict.cc` | 3255 | 建立列映射 |
| `dict_foreign_build_search_tuple()` | `row0ins.cc` | 1286 | 构建搜索元组 |
| `row_ins_check_foreign_constraint()` | `row0ins.cc` | 1416 | INSERT 外键检查 |
| `row_upd_check_references_constraints()` | `row0upd.cc` | 176 | UPDATE/DELETE 外键检查 |
| `row_upd_cascade_update()` | `row0upd.cc` | 254 | CASCADE 级联更新 |
| `row_upd_cascade_set_null()` | `row0upd.cc` | 320 | SET NULL 级联更新 |
| `row_del_cascade_delete()` | `row0del.cc` | — | CASCADE 级联删除 |
