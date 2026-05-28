# 21. InnoDB 外键与约束 (Foreign Key & Constraints)

> 本文分析 InnoDB 外键约束的内存表示、缓存注册、以及 DML 操作中的约束检查与级联路径。核心文件：`dict0mem.h`（`dict_foreign_t`）、`dict0dict.cc`（`dict_foreign_add_to_cache`）、`row0ins.cc`（插入检查）、`row0upd.cc`（更新/级联检查）。

---

## 1. 概述

InnoDB 外键约束在内核层实现，不同于 MySQL Server 层的元数据约束。内存中每个外键由一个 `dict_foreign_t` 结构描述，通过 `foreign_set` 和 `referenced_set` 两个容器组织在表对象中。约束检查在 `row_ins_check_foreign_constraint` 中统一处理，支持 `ON DELETE CASCADE`、`ON DELETE SET NULL` 等级联操作。

| 组件 | 位置 | 职责 |
|------|------|------|
| `dict_foreign_t` | `dict0mem.h:1673` | 外键约束描述 |
| `dict_foreign_set` | `dict0mem.h:1763` | 排序的外键集合 |
| `dict_foreign_add_to_cache()` | `dict0dict.cc:3423` | 将外键注册到表缓存 |
| `row_ins_check_foreign_constraint()` | `row0ins.cc:1416` | 插入/更新/删除时的约束检查 |
| `row_upd_check_references_constraints()` | `row0upd.cc:176` | 检查引用表是否违反约束 |

---

## 2. 核心数据结构

### 2.1 外键约束 `dict_foreign_t`

```cpp
// dict0mem.h:1673
struct dict_foreign_t {
  mem_heap_t *heap;                    // 该对象的内存堆
  char *id;                            // 约束标识（如 "db/table_fk_1"）

  unsigned n_fields : 10;              // 约束字段数
  unsigned type : 6;                   // 0（普通）| ON_DELETE_CASCADE |
                                       // ON_DELETE_SET_NULL

  char *foreign_table_name;            // 子表（引用表）名
  char *foreign_table_name_lookup;     // 用于 dict 查找的子表名
  dict_table_t *foreign_table;         // 子表对象指针
  const char **foreign_col_names;      // 子表列名

  char *referenced_table_name;         // 父表（被引用表）名
  char *referenced_table_name_lookup;  // 用于 dict 查找的父表名
  dict_table_t *referenced_table;      // 父表对象指针
  const char **referenced_col_names;   // 父表列名

  dict_index_t *foreign_index;         // 子表上的外键索引
  dict_index_t *referenced_index;      // 父表上的被引用索引
};
```

### 2.2 外键集合

```cpp
// dict0mem.h:1763
// 按 dict_foreign_compare（id 字典序）排序的集合
typedef std::set<dict_foreign_t *, dict_foreign_compare,
                 ut::allocator<dict_foreign_t *>>
    dict_foreign_set;
```

每个 `dict_table_t` 包含两个集合：

```cpp
// dict_table_t（简化）
dict_foreign_set foreign_set;       // 本表作为子表的外键约束
dict_foreign_set referenced_set;    // 本表作为父表被引用的约束
```

---

## 3. 缓存注册：`dict_foreign_add_to_cache`

```cpp
// dict0dict.cc:3423
dberr_t dict_foreign_add_to_cache(dict_foreign_t *foreign,
                                  const char **col_names,
                                  bool check_charsets,
                                  bool can_free_fk,
                                  dict_err_ignore_t ignore_err) {
  ut_ad(dict_sys_mutex_own());

  /* Step 1: 在缓存中查找子表和父表 */
  for_table = dict_table_check_if_in_cache_low(
      foreign->foreign_table_name_lookup);              // line 3436
  ref_table = dict_table_check_if_in_cache_low(
      foreign->referenced_table_name_lookup);           // line 3438

  /* Step 2: 检查重复约束 */
  for_in_cache = dict_foreign_find(for_table ? for_table : ref_table, foreign);
  if (for_in_cache && for_in_cache != foreign) {
    dict_foreign_free(foreign);  // 已存在相同约束，释放传入对象
  }

  /* Step 3: 设置父表引用 */
  if (ref_table && !for_in_cache->referenced_table) {
    index = dict_foreign_find_index(
        ref_table, nullptr, for_in_cache->referenced_col_names,
        for_in_cache->n_fields,
        for_in_cache->foreign_index, check_charsets, false); // line 3495

    if (index == nullptr && !(ignore_err & DICT_ERR_IGNORE_FK_NOKEY)) {
      return DB_CANNOT_ADD_CONSTRAINT;  // 缺少匹配索引
    }

    for_in_cache->referenced_table = ref_table;
    for_in_cache->referenced_index = index;

    /* Step 4: 加入父表的 referenced_set */
    ref_table->referenced_set.insert(for_in_cache);       // line 3517
  }

  // ... 类似地加入子表的 foreign_set ...
}
```

---

## 4. 插入时的约束检查

### 4.1 调用链

```
row_ins_clust_index_entry()           # row0ins.cc:3119
 └─ row_ins_check_foreign_constraints()  # row0ins.cc:1803
     └─ for each foreign in table->foreign_set:
         └─ row_ins_check_foreign_constraint(true, foreign, table, entry, thr)
```

### 4.2 `row_ins_check_foreign_constraint`

```cpp
// row0ins.cc:1416
dberr_t row_ins_check_foreign_constraint(
    bool check_ref,          // true=检查父表是否存在；false=检查子表是否脏数据
    dict_foreign_t *foreign,
    dict_table_t *table,
    dtuple_t *entry,
    que_thr_t *thr) {

  /* Step 1: 快速否决 */
  if (trx->check_foreigns == false) goto exit_func;   // line 1429
  for (ulint i = 0; i < foreign->n_fields; i++) {
    if (dfield_is_null(dtuple_get_nth_field(entry, i)))
      goto exit_func;  // SQL NULL 跳过检查      // line 1437
  }

  /* Step 2: 打开父表（如尚未在缓存中）*/
  if (check_ref) {
    check_table = foreign->referenced_table;
    check_index = foreign->referenced_index;

    if (check_table == nullptr) {
      // 延迟加载父表
      check_table = dd_table_open_on_name(thd, &mdl,
                   foreign->referenced_table_name_lookup, ...); // line 1462
    }
  } else {
    // 检查子表是否存在匹配记录（ON DELETE CASCADE 时）
    check_table = foreign->foreign_table;
    check_index = foreign->foreign_index;
  }

  /* Step 3: 构建索引搜索元组 */
  entry_on_match = dtuple_create(heap, ...);
  for (i = 0; i < foreign->n_fields; i++) {
    // 复制字段值
  }

  /* Step 4: 在目标索引中搜索匹配记录 */
  err = row_search_index_entry(check_index, check_table, entry_on_match,
                               is_prebuilt, &mode, &pcur, &mtr); // line 1634

  /* Step 5: 判断结果 */
  if (check_ref) {
    // 插入时：父表必须存在匹配行
    if (err == DB_RECORD_NOT_FOUND) {
      err = DB_FOREIGN_CONSTRAINT_VIOLATION;  // 外键约束违反
    }
  } else {
    // 更新/删除父表时：子表不能有引用行
    if (err == DB_SUCCESS) {
      // 子表存在引用行 → 根据 type 决定级联或报错
      if (foreign->type == DICT_FOREIGN_ON_DELETE_CASCADE) {
        // 级联删除子表行
      } else if (foreign->type == DICT_FOREIGN_ON_DELETE_SET_NULL) {
        // 置空子表行的外键列
      } else {
        err = DB_FOREIGN_CONSTRAINT_VIOLATION;
      }
    }
  }
}
```

---

## 5. 更新/删除时的约束检查

### 5.1 调用链

```
row_upd_step()                          # row0upd.cc
 └─ row_upd_clust_index_entry_pixel()   # 更新聚簇索引
     └─ row_upd_check_references_constraints()  # row0upd.cc:176
         └─ for each foreign in table->referenced_set:
             └─ row_ins_check_foreign_constraint(false, foreign, table, entry, thr)
```

### 5.2 `row_upd_check_references_constraints`

```cpp
// row0upd.cc:176
static dberr_t row_upd_check_references_constraints(
    upd_node_t *node, btr_pcur_t *pcur,
    dict_table_t *table, dict_index_t *index,
    ulint *offsets, que_thr_t *thr, mtr_t *mtr) {

  if (table->referenced_set.empty()) return DB_SUCCESS;  // line 183

  /* Step 1: 将记录转换为索引元组 */
  entry = row_rec_to_index_entry(rec, index, offsets, heap);  // line 192

  /* Step 2: 遍历所有引用本表的外键约束 */
  for (auto it = table->referenced_set.begin();
       it != table->referenced_set.end(); ++it) {
    foreign = *it;

    /* Step 3: 仅当更新的字段涉及外键前缀时才检查 */
    if (foreign->referenced_index == index &&
        (node->is_delete ||
         row_upd_changes_first_fields_binary(entry, index,
               node->update, foreign->n_fields))) {           // line 218

      /* Step 4: 增加子表的外键检查计数 */
      foreign_table->n_foreign_key_checks_running.fetch_add(1); // line 243

      /* Step 5: 执行约束检查 */
      err = row_ins_check_foreign_constraint(false, foreign,
                                             table, entry, thr); // line 252

      foreign_table->n_foreign_key_checks_running.fetch_sub(1);
    }
  }
}
```

关键优化：`row_upd_changes_first_fields_binary` 检查更新是否涉及外键前缀字段。如果修改的列不涉及任何外键关系，则跳过检查。

---

## 6. 级联操作

外键类型（`dict_foreign_t::type`）控制级联行为：

```cpp
// dict0dict.h 中的常量
constexpr uint32_t DICT_FOREIGN_ON_DELETE_CASCADE = 1;
constexpr uint32_t DICT_FOREIGN_ON_DELETE_SET_NULL = 2;
```

级联操作的执行在 `row0ins.cc` 的约束检查中同步触发：

```
row_ins_check_foreign_constraint(false, ...)
  ├─ foreign->type == DICT_FOREIGN_ON_DELETE_CASCADE
  │   └─ row_ins_cascade_delete() -> 递归删除子表行
  ├─ foreign->type == DICT_FOREIGN_ON_DELETE_SET_NULL
  │   └─ row_ins_cascade_set_null() -> 置空子表外键列
  └─ 普通外键
      └─ return DB_FOREIGN_CONSTRAINT_VIOLATION
```

注意：级联操作中 `n_foreign_key_checks_running` 计数用于保护外键约束对象不被 DDL 释放。

---

## 7. 外键与 DDL

### 7.1 CREATE TABLE 时的外键加载

```
dict_create_table_step()
 └─ dict_load_foreigns()         # 从系统表或 DD 中加载外键
     └─ for each foreign:
         └─ dict_foreign_add_to_cache()
             ├─ dict_foreign_find_index() → 定位匹配索引
             └─ 插入 foreign_set / referenced_set
```

### 7.2 外键错误报告

```cpp
// dict0dict.cc:3499 示例
if (index == nullptr) {
  dict_foreign_error_report(ef, for_in_cache,
      "there is no index in referenced table"
      " which would contain\n"
      "the columns as the first columns,"
      " or the data types in the\n"
      "referenced table do not match"
      " the ones in table.");
  return DB_CANNOT_ADD_CONSTRAINT;
}
```

---

## 8. 性能考虑

1. **外键列不能为 NULL**：`dfield_is_null` 检查（`row0ins.cc:1437`）使 SQL NULL 值跳过约束检查，这在 Oracle 兼容语义中是故意的。
2. **字段变更检测**：`row_upd_changes_first_fields_binary` 在更新时避免不必要的约束检查。
3. **贪婪锁策略**：插入时在父表搜索匹配记录持有 GAP lock，防止幻读导致的外键违反。
4. **`check_foreigns` 开关**：`trx->check_foreigns` 允许会话层临时禁用外键检查（如 `SET foreign_key_checks=0`）。
5. **引用计数保护**：`n_foreign_key_checks_running` 防止级联操作期间表被 DDL 删除。

---

## 9. 总结

InnoDB 外键实现的核心设计：

1. **双集合组织**：每个 `dict_table_t` 用 `foreign_set`（子表方向）和 `referenced_set`（父表方向）分别记录外键关系。
2. **统一检查入口**：`row_ins_check_foreign_constraint` 同时处理 INSERT/UPDATE/DELETE 三种操作的正反向检查。
3. **延迟打开**：父表不在缓存中时，`dd_table_open_on_name` 按需加载。
4. **级联同步执行**：在约束检查的回调路径同线程执行 CASCADE/SET NULL。
5. **兼容 SQL NULL**：外键列值为 NULL 时不检查，与 Oracle 行为一致。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `dict0mem.h` | 1673 | `struct dict_foreign_t` 定义 |
| `dict0mem.h` | 1763 | `dict_foreign_set` 类型定义（`std::set`） |
| `dict0dict.cc` | 3423 | `dict_foreign_add_to_cache()` |
| `row0ins.cc` | 1416 | `row_ins_check_foreign_constraint()` |
| `row0ins.cc` | 1803 | `row_ins_check_foreign_constraints()` |
| `row0upd.cc` | 176 | `row_upd_check_references_constraints()` |
| `row0ins.cc` | 3119 | `row_ins_clust_index_entry()` |
