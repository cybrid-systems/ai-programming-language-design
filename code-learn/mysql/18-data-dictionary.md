# 18. InnoDB 数据字典 (Data Dictionary)

> 本文分析 InnoDB 内存数据字典的实现，包括数据结构的组织（`dict_table_t`、`dict_index_t`、`dict_sys_t`）、表的打开与缓存加载流程、LRU 驱逐机制、以及启动时的字典初始化。核心文件：`dict0mem.h`、`dict0dict.cc`、`dict0dd.cc`、`dict0boot.cc`。

---

## 1. 概述

InnoDB 的数据字典（Data Dictionary）是存储在内存中的表/索引元数据缓存。在 MySQL 8.0 之前，元数据存储在 `SYS_TABLES`、`SYS_INDEXES` 等系统表中；8.0 起迁移到 Data Dictionary（DD）表空间中。InnoDB 内部维护了两套查找结构：

- **`dict_sys_t::table_hash`**：按表名哈希查找
- **`dict_sys_t::table_id_hash`**：按表 ID 哈希查找

| 核心结构 | 定义位置 | 职责 |
|----------|----------|------|
| `dict_sys_t` | `dict0dict.h:1019` | 全局字典系统，含两个 hash 表和 LRU 链表 |
| `dict_table_t` | `dict0mem.h:1925` | 表元数据描述 |
| `dict_index_t` | `dict0mem.h:1067` | 索引元数据描述 |
| `dict_col_t` | `dict0mem.h:485` | 列描述（类型、长度、位置） |
| `dict_field_t` | `dict0mem.h:891` | 索引中的字段描述 |

---

## 2. 核心数据结构

### 2.1 全局字典系统 `dict_sys_t`

```cpp
// dict0dict.h:1019
struct dict_sys_t {
  /** 保护数据字典的互斥锁 */
  DictSysMutex mutex;

  /** 下一个待分配的行 ID（单调递增） */
  std::atomic<row_id_t> row_id;

  /** 基于表名的哈希表 */
  hash_table_t *table_hash;

  /** 基于表 ID 的哈希表 */
  hash_table_t *table_id_hash;

  /** 字典对象占用的总内存字节数 */
  size_t size;

  /** 永久打开的 InnoDB 统计表句柄 */
  dict_table_t *table_stats;
  dict_table_t *index_stats;
  dict_table_t *ddl_log;
  dict_table_t *dynamic_metadata;

  /** 可驱逐表的 LRU 链表 */
  UT_LIST_BASE_NODE_T(dict_table_t, table_LRU) table_LRU;

  /** 不可驱逐表的链表（DDL/CREATE 中的表） */
  UT_LIST_BASE_NODE_T(dict_table_t, table_non_LRU) table_non_LRU;
};
```

全局单例：`dict_sys` 在 `dict_init()` 中初始化。

### 2.2 表描述 `dict_table_t`

```cpp
// dict0mem.h:1925
struct dict_table_t {
  /*================== 标识字段 ==================*/
  table_id_t id;               // 全局唯一表 ID
  table_name_t name;           // 全限定表名 "db/table"
  mem_heap_t *heap;            // 该表关联的内存堆
  space_id_t space;            // 聚簇索引所在的表空间 ID
  unsigned flags : DICT_TF_BITS;    // 行格式、压缩、DATA DIRECTORY 等
  unsigned flags2 : DICT_TF2_BITS;  // 临时表、FTS、加密等

  /*================== 列信息 ==================*/
  unsigned n_cols : 10;        // 非虚拟列数
  unsigned n_v_cols : 10;      // 虚拟列数
  unsigned n_t_cols : 10;      // 总列数（含虚拟列）
  unsigned n_instant_cols : 10;// 即时 ADD COLUMN 前的原始列数
  dict_col_t *cols;            // 列描述数组
  const char *col_names;       // 列名打包字符串

  /*================== 索引 ==================*/
  UT_LIST_BASE_NODE_T(dict_index_t, indexes) indexes;  // 索引链表
  dict_index_t *fts_doc_id_index;  // FTS 文档 ID 索引

  /*================== 引用计数 ==================*/
  hash_node_t name_hash;       // 在 table_hash 中的链节点
  hash_node_t id_hash;         // 在 table_id_hash 中的链节点
  bool can_be_evicted : 1;     // 是否可从缓存驱逐
  bool cached : 1;             // 是否已加入字典缓存
  std::atomic<uint64_t> n_ref_count;  // 引用计数

  // ... 外键、分区、统计等更多字段 ...
};
```

### 2.3 索引描述 `dict_index_t`

```cpp
// dict0mem.h:1067
struct dict_index_t {
  space_index_t id;            // 索引 ID
  mem_heap_t *heap;            // 索引内存堆
  id_name_t name;              // 索引名
  const char *table_name;      // 所属表名
  dict_table_t *table;         // 回指所属表

  unsigned space : 32;         // 表空间 ID
  unsigned page : 32;          // 根页面号

  unsigned type : DICT_IT_BITS;    // 索引类型（聚簇/唯一/IBUF/损坏）
  unsigned n_uniq : 10;        // 唯一确定一条记录的最小前缀字段数
  unsigned n_user_defined_cols : 10; // 用户定义的列数
  unsigned n_def : 10;         // 已定义的字段数
  unsigned n_fields : 10;      // 索引中的字段总数

  dict_field_t *fields;        // 字段描述数组
  btr_search_t *search_info;   // AHI 搜索信息
  UT_LIST_BASE_NODE_T(dict_index_t, indexes) indexes;  // 表索引链表的节点
};
```

### 2.4 列描述 `dict_col_t` 与 `dict_field_t`

```cpp
// dict0mem.h:485
struct dict_col_t {
  unsigned prtype : 32;   // 精确类型：MySQL 数据类型 + charset + 可空/有符号等
  unsigned mtype : 8;     // 主数据类型（INT/VARCHAR/...）
  unsigned len : 16;      // 长度（字节）
  unsigned ind : 10;      // 表列位置（从 0 开始）
  unsigned ord_part : 1;  // 是否出现在索引排序字段中
  bool is_visible;        // 列是否可见
};

// dict0mem.h:891
struct dict_field_t {
  dict_col_t *col;         // 指向表列
  id_name_t name;          // 字段名
  unsigned prefix_len : 12; // 前缀索引长度（如 INDEX(col(10))）
  unsigned fixed_len : 10;  // 固定长度（< DICT_ANTELOPE_MAX_INDEX_COL_LEN）
  unsigned is_ascending : 1;// 0=DESC, 1=ASC
};
```

---

## 3. 调用链：表对象打开与缓存

### 3.1 入口：`dd_table_open_on_id`

```cpp
// dict0dd.cc:701
dict_table_t *dd_table_open_on_id(table_id_t table_id, THD *thd,
                                  MDL_ticket **mdl, bool dict_locked,
                                  bool check_corruption) {
  dict_table_t *ib_table;
  const auto hash_value = ut::hash_uint64(table_id);

  /* Step 1: 获取字典互斥锁 */
  if (!dict_locked) dict_sys_mutex_enter();       // line 709

  /* Step 2: 在 table_id_hash 中查找 */
  HASH_SEARCH(id_hash, dict_sys->table_id_hash, hash_value,
              dict_table_t *, ib_table,              // line 713
              ut_ad(ib_table->cached),
              ib_table->id == table_id);

  /* Step 3: 缓存命中 — 增加引用计数 */
  if (ib_table != nullptr) {
    ib_table->acquire();                           // line 745
    dict_sys_mutex_exit();
    return ib_table;
  }

  /* Step 4: 缓存未命中 — 从 DD 表空间加载 */
  ib_table = dd_table_open_on_id_low(thd, mdl, table_id);  // line 763
  // ...
}
```

### 3.2 加入缓存：`dict_table_add_to_cache`

```cpp
// dict0dict.cc:1175
void dict_table_add_to_cache(dict_table_t *table, bool can_be_evicted) {
  ut_ad(dict_sys_mutex_own());
  table->cached = true;

  /* Step 1: 计算两条 hash 路径 */
  const auto name_hash_value = ut::hash_string(table->name.m_name);
  const auto index_id_hash_value = ut::hash_uint64(table->id);

  /* Step 2: 断言不存在同名/同 ID 的表 */
  HASH_SEARCH(name_hash, dict_sys->table_hash, name_hash_value,
              dict_table_t *, table2,
              !strcmp(table2->name.m_name, table->name.m_name));
  ut_a(table2 == nullptr);

  /* Step 3: 插入到两个 hash 表中 */
  HASH_INSERT(dict_table_t, name_hash, dict_sys->table_hash,
              name_hash_value, table);              // line 1226
  HASH_INSERT(dict_table_t, id_hash, dict_sys->table_id_hash,
              index_id_hash_value, table);          // line 1230

  /* Step 4: 加入 LRU 或 non-LRU 链表 */
  if (table->can_be_evicted) {
    UT_LIST_ADD_FIRST(dict_sys->table_LRU, table);  // line 1235
  } else {
    UT_LIST_ADD_FIRST(dict_sys->table_non_LRU, table); // line 1237
  }

  /* Step 5: 更新内存统计 */
  dict_sys->size += mem_heap_get_size(table->heap)
                    + strlen(table->name.m_name) + 1; // line 1241
}
```

### 3.3 缓存驱逐路径

```cpp
// dict0dict.cc:1255
static bool dict_table_can_be_evicted(dict_table_t *table) {
  ut_ad(dict_sys_mutex_own());
  ut_a(table->can_be_evicted);
  ut_a(table->foreign_set.empty());
  ut_a(table->referenced_set.empty());

  if (table->get_ref_count() == 0) {
    // 引用计数为 0 且未被 DDL 锁定 → 可以驱逐
    return true;
  }
  return false;
}
```

驱逐机制（`dict0dict.cc` 中 `dict_make_room_in_cache`）：当内存超过 `dict_sys->size` 阈值时，从 `table_LRU` 尾部遍历 `dict_table_can_be_evicted`，符合条件的表调用 `dict_table_remove_from_cache` 释放。

---

## 4. 索引添加与缓存

### 4.1 `dict_index_add_to_cache`

```cpp
// dict0dict.cc:2303
dberr_t dict_index_add_to_cache(dict_table_t *table, dict_index_t *index,
                                space_index_t file_index_no, bool strict) {
  ut_ad(dict_sys_mutex_own());

  /* Step 1: 在 table->indexes 链表中查找位置（保持顺序） */
  if (file_index_no > 0) {
    // 按 file_index_no 查找插入点
    dict_index_t *prev = nullptr;
    for (auto ind = UT_LIST_GET_FIRST(table->indexes);
         ind != nullptr && ind->id < file_index_no;
         ind = UT_LIST_GET_NEXT(indexes, ind)) {
      prev = ind;
    }
    // 插入到 prev 之后
    UT_LIST_INSERT_AFTER(table->indexes, prev, index);
  } else {
    UT_LIST_ADD_LAST(table->indexes, index);  // line 2376
  }

  /* Step 2: 创建 AHI 搜索信息 */
  index->search_info = btr_search_info_create(index->heap);  // line 2388

  /* Step 3: 更新列索引标记 */
  for (auto i = index->n_fields; i > 0; i--) {
    auto field = dict_index_get_nth_field(index, i - 1);
    field->col->set_ord_part();  // 标记该列出现在索引排序字段中
  }

  dict_sys->size += mem_heap_get_size(index->heap);
  return DB_SUCCESS;
}
```

---

## 5. 启动流程

### 5.1 `dict_boot()` — 字典启动

```cpp
// dict0boot.cc:209
dberr_t dict_boot() {
  dict_hdr_t *dict_hdr;
  mtr_t mtr;

  mtr_start(&mtr);

  /* Step 1: 创建 hash 表等基础设施 */
  dict_init();

  /* Step 2: 获取字典头页面 */
  dict_hdr = dict_hdr_get(&mtr);            // dict0boot.cc:216

  /* Step 3: 恢复 row_id 计数器（崩溃恢复安全余量）*/
  dict_sys->row_id.store(
      DICT_HDR_ROW_ID_WRITE_MARGIN +
      ut_uint64_align_up(
          mach_read_from_8(dict_hdr + DICT_HDR_ROW_ID),
          DICT_HDR_ROW_ID_WRITE_MARGIN));   // dict0boot.cc:238-241

  mtr_commit(&mtr);

  /* Step 4: 初始化 Change Buffer */
  ibuf_init_at_db_start();                  // dict0boot.cc:248
  return DB_SUCCESS;
}
```

### 5.2 完整启动链路

```
srv_start()
 └─ dict_boot()                    # dict0boot.cc:209
     ├─ dict_init()                # 创建 dict_sys、hash 表、LRU 链表
     ├─ dict_hdr_get()             # 读取 DICT_HDR_PAGE_NO 页面
     ├─ row_id 恢复
     └─ ibuf_init_at_db_start()
 └─ dict_create()                  # dict0boot.cc:269（创建模式）
     ├─ dict_hdr_create()
     └─ dict_boot()
```

### 5.3 `dict_hdr_get_new_id` — 分配新 ID

```cpp
// dict0boot.cc:71
void dict_hdr_get_new_id(table_id_t *table_id, space_index_t *index_id,
                         space_id_t *space_id, ...) {
  mtr_t mtr;
  mtr_start(&mtr);

  /* Step 1: X-latch 字典头页面 */
  auto dict_hdr = dict_hdr_get(&mtr);     // dict0boot.cc:83

  /* Step 2: 读取当前最大 ID */
  if (table_id) {
    *table_id = mach_read_from_8(
        dict_hdr + DICT_HDR_MAX_TABLE_ID);  // dict0boot.cc:90
  }

  /* Step 3: 自增并写回 */
  auto new_max_table_id = *table_id + DICT_HDR_RESERVED;
  mlog_write_uint64(dict_hdr + DICT_HDR_MAX_TABLE_ID,
                    new_max_table_id, &mtr);  // dict0boot.cc:96

  mtr_commit(&mtr);
}
```

`DICT_HDR_RESERVED`（默认 100）预分配方式减少了每次 CREATE TABLE 时对字典头的写入开销。

---

## 6. LRU 驱逐详细路径

```
table 引用计数降为 0
 └─ dict_table_close()         # 文件关闭
     └─ table->release()
         └─ n_ref_count--
 └─ dict_make_room_in_cache()  # 内存压力时触发
     └─ 遍历 table_LRU
         └─ dict_table_can_be_evicted()   # dict0dict.cc:1255
             ├─ foreign_set.empty()
             ├─ referenced_set.empty()
             └─ n_ref_count == 0
         └─ dict_table_remove_from_cache(table)  # dict0dict.cc:1954
             ├─ HASH_DELETE from table_hash
             ├─ HASH_DELETE from table_id_hash
             ├─ UT_LIST_REMOVE from table_LRU
             └─ ut_free(table)
```

---

## 7. 总结

InnoDB 数据字典是一个**双 hash 表 + LRU 链表的缓存系统**，核心设计要点：

1. **双路径查找**：通过 `table_hash`（按名）和 `table_id_hash`（按 ID）均可 O(1) 找到 `dict_table_t` 对象。
2. **引用计数 + LRU 驱逐**：`n_ref_count` 决定表对象是否可被驱逐；`table_LRU` 链表在内存压力下回收最近最少使用的表。
3. **预分配 ID**：`DICT_HDR_RESERVED` 批量预留 ID 空间，减少对 `DICT_HDR_PAGE_NO` 页面的写入频率。
4. **与 Data Dictionary 集成**：MySQL 8.0 起，物理元数据存于 DD 表空间，InnoDB 的 `dd_table_open_on_id_low` 负责从 DD 中反序列化为 `dict_table_t`。
5. **Instant ADD COLUMN 支持**：`n_instant_cols`、`version_added`/`version_dropped` 等字段支持在线加列而不重建表。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `dict0dict.h` | 1019 | `struct dict_sys_t` 定义 |
| `dict0mem.h` | 485 | `struct dict_col_t` 定义 |
| `dict0mem.h` | 891 | `struct dict_field_t` 定义 |
| `dict0mem.h` | 1067 | `struct dict_index_t` 定义 |
| `dict0mem.h` | 1925 | `struct dict_table_t` 定义 |
| `dict0dict.cc` | 1175 | `dict_table_add_to_cache()` |
| `dict0dict.cc` | 1255 | `dict_table_can_be_evicted()` |
| `dict0dict.cc` | 1954 | `dict_table_remove_from_cache()` |
| `dict0dict.cc` | 2303 | `dict_index_add_to_cache()` |
| `dict0dd.cc` | 701 | `dd_table_open_on_id()` |
| `dict0boot.cc` | 71 | `dict_hdr_get_new_id()` |
| `dict0boot.cc` | 209 | `dict_boot()` |
