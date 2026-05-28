# 18. InnoDB 数据字典（Data Dictionary）— 源码深度分析

> 本文分析 InnoDB 内存数据字典的完整实现，包括数据结构组织、双 hash 表缓存、表对象打开路径、LRU 驱逐机制、DD 表空间集成、崩溃恢复以及并发控制。核心源文件：`dict0mem.h`、`dict0dict.cc`、`dict0dd.cc`、`dict0boot.cc`、`dict0crea.cc`。

---

## 0. 概述

InnoDB 的数据字典（Data Dictionary）是存储于内存中的表/索引元数据缓存。它是 InnoDB 所有 DML 和 DDL 操作的基础——每一条 SQL 语句都需要通过数据字典获得表的 schema 信息（列数、类型、索引结构）。

### MySQL 8.0 之前 vs 之后

```
MySQL 5.7 及以前:
  SYS_TABLES, SYS_INDEXES, SYS_COLUMNS (InnoDB 系统表)
    └── .ibd 文件中不存储完整元数据
    └── FRM 文件存储表定义

MySQL 8.0 及以后:
  mysql.innodb_table_stats / ... (DD 表空间 .opt 文件)
    └── .ibd 文件自描述（SDI - Serialized Dictionary Information）
    └── DD 集中管理所有引擎的元数据
```

InnoDB 内部维护了两套独立的查找结构，用于快速定位 `dict_table_t` 对象：

- **`dict_sys_t::table_hash`**：按表名（`"db/table"` 全限定名）哈希查找
- **`dict_sys_t::table_id_hash`**：按表 ID（`table_id_t`，uint64）哈希查找

### 为什么要两套 hash 表？

SQL 层经常有两种访问模式：

1. `SELECT * FROM t WHERE ...` → SQL 层解析后获得表名 `"mydb/t"` → 需要按名查
2. `执行计划中的索引扫描` → 存储层通过 `table_id` 引用 → 需要按 ID 查

两套路径都能 O(1) 访问 `dict_table_t`，避免高频场景下的线性搜索。

---

## 1. 核心数据结构

### 1.1 全局字典系统 — dict_sys_t

`dict_sys_t` 是整个 InnoDB 字典的"大脑"：

```cpp
// dict0dict.h:1019
struct dict_sys_t {
  /** 保护数据字典的互斥锁 */
  DictSysMutex mutex;

  /** 下一个待分配的行 ID（单调递增，用于隐式 row_id 列） */
  std::atomic<row_id_t> row_id;

  /** hash 表：按表名查找 */
  /** key = 表名字符串的 hash value */
  /** value = dict_table_t 通过 name_hash 节点链接 */
  hash_table_t *table_hash;

  /** hash 表：按表 ID 查找 */
  /** key = table_id_t 的 hash value */
  /** value = dict_table_t 通过 id_hash 节点链接 */
  hash_table_t *table_id_hash;

  /** 字典对象占用的总内存字节数（用于驱逐决策） */
  size_t size;

  /** 硬编码的统计表句柄——这些表永远不驱逐 */
  dict_table_t *table_stats;       /* mysql.innodb_table_stats */
  dict_table_t *index_stats;       /* mysql.innodb_index_stats */
  dict_table_t *ddl_log;           /* 内部 DDL 日志表 */
  dict_table_t *dynamic_metadata;

  /** 可驱逐表对象的 LRU 链表 */
  UT_LIST_BASE_NODE_T(dict_table_t, table_LRU) table_LRU;

  /** 不可驱逐表对象的链表 */
  /** 包括正在 DDL 中的表、系统表、临时表等 */
  UT_LIST_BASE_NODE_T(dict_table_t, table_non_LRU) table_non_LRU;
};
```

全局单例由 `dict_init()` 创建，通过 `dict_sys` 指针访问。

**`struct DictSysMutex` 的特殊之处**：

```cpp
// dict0dict.h 中
struct DictSysMutex : public PolicyMutex<Mutex {
  static constexpr bool has_inline_psi = true;
  static constexpr bool has_i_s = false;
}>
```

它继承了 InnoDB 策略互斥锁，但**没有** Performance Schema 仪表化（`has_i_s = false`）——这是有意为之，因为 `dict_sys.mutex` 是 InnoDB 中最热门的锁之一，PS 的开销在此不可接受。

### 1.2 表描述 — dict_table_t

每个用户表、系统表、临时表都有一个对应的 `dict_table_t` 对象：

```cpp
// dict0mem.h:1925
struct dict_table_t {
  /* ═══════════════ 标识字段 ═══════════════ */
  table_id_t id;               /* 全局唯一表 ID（64 位，从字典头递增） */
  table_name_t name;           /* 全限定名 "db/table" */
  mem_heap_t *heap;            /* 该表关联的内存堆（所有子结构都从此分配） */
  space_id_t space;            /* 聚簇索引所在表空间 ID */
  unsigned flags : DICT_TF_BITS;    /* 行格式/压缩/页面大小等 */
  unsigned flags2 : DICT_TF2_BITS;  /* 临时表/FTS/加密等 */

  /* ═══════════════ 列信息 ═══════════════ */
  unsigned n_cols : 10;        /* 非虚拟列数 */
  unsigned n_v_cols : 10;      /* 虚拟列数（GENERATED ALWAYS AS ... VIRTUAL） */
  unsigned n_t_cols : 10;      /* 总列数（n_cols + n_v_cols） */
  unsigned n_instant_cols : 10;/* Instant ADD COLUMN 之前原始列数 */
  dict_col_t *cols;            /* 列描述数组 */
  const char *col_names;       /* 列名打包字符串（\0 分隔） */

  /* ═══════════════ 索引 ═══════════════ */
  UT_LIST_BASE_NODE_T(dict_index_t, indexes) indexes;  /* 索引链表 */
  dict_index_t *fts_doc_id_index;  /* FTS 文档 ID 索引（如果启用 FTS） */

  /* ═══════════════ 引用与缓存 ═══════════════ */
  hash_node_t name_hash;       /* 在 table_hash 中的链节点 */
  hash_node_t id_hash;         /* 在 table_id_hash 中的链节点 */
  bool can_be_evicted : 1;     /* 是否为可驱逐的缓存对象 */
  bool cached : 1;             /* 是否已加入字典缓存 */
  std::atomic<uint64_t> n_ref_count;  /* 引用计数（打开句柄数 + 活跃事务使用） */

  /* ═══════════════ LRU 链表节点 ═══════════════ */
  UT_LIST_NODE_T(dict_table_t, table_LRU);    /* 在 table_LRU 链表中的节点 */
  std::chrono::steady_clock::time_point
      last_used;                              /* 上次使用时间（用于 LRU 排序） */

  /* ═══════════════ 外键 ═══════════════ */
  dict_foreign_set foreign_set;      /* 被引用的外键关系 */
  dict_foreign_set referenced_set;   /* 引用本表的外键关系 */

  /* ═══════════════ Instant DDL ═══════════════ */
  uint64_t *version_added;          /* 每列的创建版本号 */
  uint64_t *version_dropped;        /* 每列的删除版本号 */
  uint64_t current_version;         /* 当前瞬时版本（每次 Instant DDL 后递增） */
};
```

**`n_ref_count` 的递增场景**：

```
文件打开: dict_table_open_on_id() / dict_table_open_on_name()
    → ib_table->acquire()      // n_ref_count++

事务引用: trx_assign_read_view() 访问表
    → table->acquire()

索引 B-tree 操作: btr_cur_search_to_nth_level()
    → index->table->acquire()  // 防止在 B+Tree 遍历中途表被驱逐

释放:
    dict_table_close() → table->release()  // n_ref_count--
```

### 1.3 索引描述 — dict_index_t

每个索引（聚簇索引、二级索引、全文索引、空间索引）都用一个 `dict_index_t` 描述：

```cpp
// dict0mem.h:1067
struct dict_index_t {
  space_index_t id;            /* 索引 ID（表空间内唯一） */
  mem_heap_t *heap;            /* 索引内存堆 */
  id_name_t name;              /* 索引名 */
  const char *table_name;      /* 所属表名（字符串指针，不重复分配） */
  dict_table_t *table;         /* 回指所属表 */

  unsigned space : 32;         /* 表空间 ID */
  unsigned page : 32;          /* 根页面号（B-tree 根节点） */

  unsigned type : DICT_IT_BITS;   /* 类型位 */
  /* type 可包含: DICT_CLUSTERED | DICT_UNIQUE | DICT_IBUF | */
  /*              DICT_CORRUPT | DICT_SPATIAL | DICT_FTS */

  unsigned n_uniq : 10;        /* 唯一确定记录的最小字段数 */
  unsigned n_user_defined_cols : 10; /* 用户自定义列数 */
  unsigned n_def : 10;         /* 已定义的字段数 */
  unsigned n_fields : 10;      /* 索引中总字段数（含隐藏列） */

  dict_field_t *fields;        /* 字段描述数组，长度 n_fields */

  btr_search_t *search_info;   /* AHI 自适应哈希索引搜索信息 */
  btr_cur_t *cached_cur;       /* 缓存游标（用于快速 re-lookup） */

  /* 链表节点 */
  UT_LIST_NODE_T(dict_index_t, indexes);  /* 在 table->indexes 中的节点 */

  /* 内部 B-tree 锁 */
  rw_lock_t lock;
};
```

**`type` 字段的位组合**：

```
聚簇主键索引:  DICT_CLUSTERED | DICT_UNIQUE
唯一二级索引:   DICT_UNIQUE
普通二级索引:   0
Change Buffer: DICT_CLUSTERED | DICT_IBUF
损坏标记:      DICT_CORRUPT
```

`n_uniq` 是 InnoDB 实现行锁的重要参数：在 `btr_cur_ins_lock_and_rec()` 中，当 `n_uniq` 列的匹配度达到时，定位到特定行（如 `WHERE pk = 42`），加行锁；否则只能加间隙锁或 next-key 锁。

### 1.4 列描述 — dict_col_t 与 dict_field_t

```cpp
// dict0mem.h:485
struct dict_col_t {
  unsigned prtype : 32;   /* 精确类型：MySQL 类型编码 + charset + nullable + signed */
  unsigned mtype : 8;     /* 主数据类型（DATA_INT / DATA_VARCHAR / DATA_CHAR / ...） */
  unsigned len : 16;      /* 长度（字节） */
  unsigned ind : 10;      /* 在表中的列位置（从 0 开始） */
  unsigned ord_part : 1;  /* 该列是否出现在某索引的排序字段中 */
  bool is_visible;
};

// dict0mem.h:891
struct dict_field_t {
  dict_col_t *col;         /* 回指表列 */
  id_name_t name;          /* 字段名（在索引中的别名） */
  unsigned prefix_len : 12; /* 前缀索引长度，如 INDEX(col(10)) */
  unsigned fixed_len : 10;  /* 固定长度（对于定长类型） */
  unsigned is_ascending : 1;/* 0=DESC, 1=ASC */
};
```

`prtype` 的编码格式：

```cpp
/* 数据类型编码示例 */
DATA_VARCHAR   = 6
DATA_CHAR      = 7
DATA_INT       = 8
DATA_BLOB      = 9
DATA_FIXBINARY = 11

/* prtype 中编码的额外信息（通过位或组合） */
DATA_NOT_NULL   = 1 << 15
DATA_UNSIGNED   = 1 << 16
DATA_BINARY_TYPE = 1 << 17
```

当 `ord_part` 被设置时（在 `dict_index_add_to_cache` 中），列的位置就固定不可变了——即使用 `ALTER TABLE ... MODIFY COLUMN` 更改了列定义，原始列顺序也必须保留。

---

## 2. 表对象打开与缓存路径

### 2.1 入口：dd_table_open_on_id()

最常用的打开入口——通过 `table_id` 查找：

```cpp
// dict0dd.cc:701
dict_table_t *dd_table_open_on_id(
    table_id_t table_id, THD *thd,
    MDL_ticket **mdl, bool dict_locked,
    bool check_corruption) {

  dict_table_t *ib_table;

  /* 计算 hash 值 */
  const auto hash_value = ut::hash_uint64(table_id);

  /* ──── 步骤 1：获取字典锁 ──── */
  if (!dict_locked) {
    dict_sys_mutex_enter();
  }

  /* ──── 步骤 2：在 table_id_hash 中查找 ──── */
  HASH_SEARCH(id_hash, dict_sys->table_id_hash, hash_value,
              dict_table_t *, ib_table,
              ut_ad(ib_table->cached),
              ib_table->id == table_id);

  /* ──── 步骤 3：缓存命中 ──── */
  if (ib_table != nullptr) {
    /* 更新 LRU 时间戳 */
    ib_table->last_used = std::chrono::steady_clock::now();
    /* 增加引用计数 */
    ib_table->acquire();
    if (!dict_locked) dict_sys_mutex_exit();
    return ib_table;
  }

  /* ──── 步骤 4：缓存未命中 → 从 DD 表空间加载 ──── */
  ib_table = dd_table_open_on_id_low(thd, mdl, table_id);

  if (ib_table != nullptr && !check_corruption) {
    /* 检查表是否损坏 */
    bool is_corrupt = dict_table_is_corrupted(ib_table);
    if (is_corrupt) {
      dict_table_close(ib_table);
      ib_table = nullptr;
    }
  }

  if (!dict_locked) dict_sys_mutex_exit();
  return ib_table;
}
```

`dd_table_open_on_id_low()` 的加载路径（`dict0dd.cc:623`）：

```
dd_table_open_on_id_low()
  ├── dd_get_table_id_map()      ← 从 DD 获取 table_id → space_id 映射
  ├── fil_space_acquire()         ← 打开表空间文件
  ├── ibd_file_read_sdi()         ← 从 .ibd 文件读取 SDI (Serialized Dictionary Info)
  ├── sdi_deserialize()           ← 反序列化 DD 为 dict_table_t
  ├── dict_table_add_to_cache()   ← 加入内存缓存
  └── ib_table->acquire()         ← 增加引用计数并返回
```

**从 DD 到 InnoDB 表对象的转换**：

MySQL 8.0 的 DD 表空间存储的是 JSON 格式的序列化元数据。当 InnoDB 需要打开一个表时，流程是：

```
DD 表空间中的行 (SDI JSON)
  → 通过 sdi 接口读取
  → 反序列化为 InnoDB 的 dict_table_t 结构
  → 写入 .ibd 文件的 SDI 页（供其他引擎读取）
  → 加入内存字典缓存
```

这种"双写"（DD + SDI）模式确保即使 DD 表空间损坏，`ibd` 文件自带的 SDI 也能恢复表定义。

### 2.2 按表名打开：dd_table_open_on_name()

SQL 层解析后使用表名查找的路径：

```cpp
// dict0dd.cc:580 — 简化
dict_table_t *dd_table_open_on_name(
    THD *thd, MDL_ticket **mdl, const char *table_name) {

  const auto hash_value = ut::hash_string(table_name);

  dict_sys_mutex_enter();

  /* 在 table_hash 中查找 */
  HASH_SEARCH(name_hash, dict_sys->table_hash, hash_value,
              dict_table_t *, ib_table,
              ut_ad(ib_table->cached),
              !strcmp(ib_table->name.m_name, table_name));

  if (ib_table != nullptr) {
    ib_table->acquire();
    dict_sys_mutex_exit();
    return ib_table;
  }

  dict_sys_mutex_exit();

  /* 缓存未命中 → 通过 DD API 获取 table_id */
  table_id_t table_id = dd_get_table_id(table_name);
  return dd_table_open_on_id(table_id, thd, mdl, false, false);
}
```

**按表名查找的典型场景**：

```
SQL: SELECT * FROM mydb.t WHERE a = 1
  └─ parser → table_name = "mydb/t"
  └─ open_tables_for_query()
      └─ dd_table_open_on_name(thd, &mdl, "mydb/t")
          ├─ table_hash 命中 → 直接返回 dict_table_t
          └─ 未命中 → dd_get_table_id → dd_table_open_on_id → 加载
```

### 2.3 表对象的引用管理 — acquire / release

```cpp
// dict0mem.ic — dict_table_t 的获取/释放
void dict_table_t::acquire() {
  ut_a(!can_be_evicted || n_ref_count.load() > 0);
  n_ref_count.fetch_add(1);
}

void dict_table_t::release() {
  ut_a(n_ref_count.load() > 0);
  n_ref_count.fetch_sub(1);
}
```

引用计数的作用：

1. **防止驱逐**：`n_ref_count > 0` 的表不会被 LRU 驱逐
2. **生命周期管理**：文件关闭、事务结束时释放引用
3. **DDL 保护**：引用计数确保在 DDL 执行期间表对象存活

---

## 3. 表对象加入缓存 — dict_table_add_to_cache()

当从 DD 加载一个新表对象后，必须加入缓存：

```cpp
// dict0dict.cc:1175
void dict_table_add_to_cache(dict_table_t *table, bool can_be_evicted) {
  ut_ad(dict_sys_mutex_own());
  table->cached = true;
  table->can_be_evicted = can_be_evicted;

  /* ──── 步骤 1：计算两条 hash 路径 ──── */
  const auto name_hash_value = ut::hash_string(table->name.m_name);
  const auto id_hash_value = ut::hash_uint64(table->id);

  /* ──── 步骤 2：检查冲突 ──── */
  /* 确保没有同名或同 ID 的表已在缓存中 */
  HASH_SEARCH(name_hash, dict_sys->table_hash, name_hash_value,
              dict_table_t *, table2,
              !strcmp(table2->name.m_name, table->name.m_name));
  ut_a(table2 == nullptr);  /* 同名冲突 → 断言失败 */

  HASH_SEARCH(id_hash, dict_sys->table_id_hash, id_hash_value,
              dict_table_t *, table2,
              table2->id == table->id);
  ut_a(table2 == nullptr);

  /* ──── 步骤 3：插入两个 hash 表 ──── */
  HASH_INSERT(dict_table_t, name_hash, dict_sys->table_hash,
              name_hash_value, table);
  HASH_INSERT(dict_table_t, id_hash, dict_sys->table_id_hash,
              id_hash_value, table);

  /* ──── 步骤 4：加入 LRU 或 non-LRU 链表 ──── */
  if (table->can_be_evicted) {
    UT_LIST_ADD_FIRST(dict_sys->table_LRU, table);
  } else {
    UT_LIST_ADD_FIRST(dict_sys->table_non_LRU, table);
  }

  /* ──── 步骤 5：更新内存统计 ──── */
  dict_sys->size += mem_heap_get_size(table->heap)
                    + strlen(table->name.m_name) + 1;

  /* ──── 步骤 6：更新外键关系 ──── */
  /* 如果本表有外键引用其他已缓存的表，建立双向链接 */
  for (auto &fk : table->foreign_set) {
    dict_table_t *ref_table = dict_table_open_on_id(
        fk->referenced_table_id, ...);
    if (ref_table) {
      fk->referenced_table = ref_table;
      ref_table->referenced_set.insert(fk);
    }
  }
}
```

**`can_be_evicted` 的判断逻辑**：

| 表类型 | can_be_evicted | 理由 |
|--------|---------------|------|
| 用户表 | true | 可从 DD 重新加载 |
| 系统表（SYS_*）| false | 始终在内存中 |
| 临时表 | false | 会话内唯一 |
| statistics/DDL log 表 | false | InnoDB 内部频繁使用 |
| `dict_sys->table_stats` | false | 硬编码句柄 |

---

## 4. LRU 驱逐机制

### 4.1 驱逐条件判断

```cpp
// dict0dict.cc:1255
static bool dict_table_can_be_evicted(dict_table_t *table) {
  ut_ad(dict_sys_mutex_own());
  ut_a(table->can_be_evicted);

  /* 检查外键关系 */
  if (!table->foreign_set.empty()) return false;
  if (!table->referenced_set.empty()) return false;

  /* 检查引用计数 */
  if (table->get_ref_count() != 0) return false;

  /* 检查是否在 DDL 中 */
  if (table->quiesce != QUIESCE_NONE) return false;

  return true;
}
```

**驱逐四条件**（必须全部满足）：

1. `can_be_evicted == true` — 该表标记为可驱逐
2. `foreign_set.empty()` 且 `referenced_set.empty()` — 没有未处理的外键关系
3. `n_ref_count == 0` — 没有打开句柄或活跃事务引用
4. `quiesce == QUIESCE_NONE` — 没有正在执行的 DDL

### 4.2 驱逐触发路径

```cpp
// dict0dict.cc:1285
void dict_make_room_in_cache(ulint max_size) {
  /* 步骤 1：检查是否需要驱逐 */
  if (dict_sys->size < max_size) return;  /* 内存足够 → 不驱逐 */

  /* 步骤 2：从 LRU 尾部开始遍历 */
  auto table = UT_LIST_GET_LAST(dict_sys->table_LRU);
  while (table && dict_sys->size > max_size) {

    auto prev_table = UT_LIST_GET_PREV(table_LRU, table);

    if (dict_table_can_be_evicted(table)) {
      /* 步骤 3：驱逐 */
      dict_table_remove_from_cache(table);
    }

    table = prev_table;
  }
}
```

驱逐的典型触发时机：

```
场景 1: 新表加入缓存后
  dict_table_add_to_cache()
    └─ dict_make_room_in_cache(dict_sys_size_limit)
        └─ 从 LRU 尾部驱逐至内存 < 上限

场景 2: DDL 修改大量表
  CREATE TABLE ... SELECT
    └─ 大量表被打开 → dict_make_room_in_cache
```

### 4.3 dict_table_remove_from_cache() — 完整释放

```cpp
// dict0dict.cc:1954
void dict_table_remove_from_cache(dict_table_t *table) {
  /* 从两个 hash 表中删除 */
  HASH_DELETE(dict_table_t, name_hash, dict_sys->table_hash,
              ut::hash_string(table->name.m_name), table);
  HASH_DELETE(dict_table_t, id_hash, dict_sys->table_id_hash,
              ut::hash_uint64(table->id), table);

  /* 从 LRU 链表中删除 */
  if (table->can_be_evicted) {
    UT_LIST_REMOVE(dict_sys->table_LRU, table);
  } else {
    UT_LIST_REMOVE(dict_sys->table_non_LRU, table);
  }

  /* 释放外键反向引用 */
  for (auto &fk : table->foreign_set) {
    if (fk->referenced_table) {
      fk->referenced_table->referenced_set.erase(fk);
    }
  }
  for (auto &fk : table->referenced_set) {
    fk->referenced_table->foreign_set.erase(fk);
  }

  /* 释放所有索引的 AHI */
  for (auto index = UT_LIST_GET_FIRST(table->indexes);
       index != nullptr;
       index = UT_LIST_GET_NEXT(indexes, index)) {
    btr_search_drop_page_hash_index_for_index(index);
  }

  /* 释放内存 */
  dict_sys->size -= mem_heap_get_size(table->heap);
  mem_heap_free(table->heap);  /* 释放包含 table 自身 */
}
```

---

## 5. 索引添加路径

### 5.1 dict_index_add_to_cache()

CREATE INDEX 或表创建时的索引注册：

```cpp
// dict0dict.cc:2303
dberr_t dict_index_add_to_cache(
    dict_table_t *table, dict_index_t *index,
    space_index_t file_index_no, bool strict) {

  ut_ad(dict_sys_mutex_own());

  /* ──── 步骤 1：在 table->indexes 链表中查找插入点 ──── */
  /* 索引链表按 file_index_no 升序排列 */
  if (file_index_no > 0) {
    dict_index_t *prev = nullptr;
    for (auto ind = UT_LIST_GET_FIRST(table->indexes);
         ind != nullptr && ind->id < file_index_no;
         ind = UT_LIST_GET_NEXT(indexes, ind)) {
      prev = ind;
    }
    UT_LIST_INSERT_AFTER(table->indexes, prev, index);
  } else {
    UT_LIST_ADD_LAST(table->indexes, index);
  }

  /* ──── 步骤 2：创建 AHI 搜索信息 ──── */
  index->search_info = btr_search_info_create(index->heap);

  /* ──── 步骤 3：标记列出现在索引中 ──── */
  for (auto i = index->n_fields; i > 0; i--) {
    auto field = dict_index_get_nth_field(index, i - 1);
    field->col->set_ord_part();  /* ord_part = true */
  }

  /* ──── 步骤 4：更新内存统计 ──── */
  dict_sys->size += mem_heap_get_size(index->heap);

  return DB_SUCCESS;
}
```

**索引链表的顺序重要性**：

```
file_index_no = 0   → 聚簇索引（主键）
file_index_no = 1   → 第一个二级索引
file_index_no = 2   → 第二个二级索引
...

当 InnoDB 需要查找特定索引时:
  遍历链表 → 与 file_index_no 比较 → 找到目标
  O(n) 但 n 通常很小 (< 10)

如果有 50 个索引的场景:
  dict_index_find_on_id_low(table, index_id)
  → 线性查找 → 可能成为瓶颈
  → 但实际生产实践中很少见
```

### 5.2 索引查找 — dict_index_find_on_id()

```cpp
// dict0dict.cc — 简化
dict_index_t *dict_index_find_on_id(dict_table_t *table, space_index_t id) {
  for (auto index = UT_LIST_GET_FIRST(table->indexes);
       index != nullptr;
       index = UT_LIST_GET_NEXT(indexes, index)) {
    if (index->id == id) return index;
  }
  return nullptr;
}
```

---

## 6. 启动初始化

### 6.1 dict_boot() — 字典启动

```cpp
// dict0boot.cc:209
dberr_t dict_boot() {
  dict_hdr_t *dict_hdr;
  mtr_t mtr;

  mtr_start(&mtr);

  /* Step 1: 创建 dict_sys 及 hash 表 */
  dict_init();

  /* Step 2: 获取字典头页面（系统表空间 page 7） */
  dict_hdr = dict_hdr_get(&mtr);

  /* Step 3: 恢复 row_id 计数器 */
  /* 从字典头读取上一次写入的 row_id */
  /* 加上 DICT_HDR_ROW_ID_WRITE_MARGIN 安全余量 */
  dict_sys->row_id.store(
      DICT_HDR_ROW_ID_WRITE_MARGIN +
      ut_uint64_align_up(
          mach_read_from_8(dict_hdr + DICT_HDR_ROW_ID),
          DICT_HDR_ROW_ID_WRITE_MARGIN));

  /* Step 4: 恢复最大表 ID */
  dict_sys->max_table_id = mach_read_from_8(
      dict_hdr + DICT_HDR_MAX_TABLE_ID);

  mtr_commit(&mtr);

  /* Step 5: 初始化 Change Buffer（ibuf 有自己的 B-tree 在系统表空间） */
  ibuf_init_at_db_start();

  return DB_SUCCESS;
}
```

**`DICT_HDR_ROW_ID_WRITE_MARGIN` 的安全余量**：

```cpp
/* dict0boot.h */
#define DICT_HDR_ROW_ID_WRITE_MARGIN (256 * 1024)
```

每次系统表空间被刷新时，row_id 被写回字典头。但在崩溃前一段时间分配的 row_id 可能还没被写回。`DICT_HDR_ROW_ID_WRITE_MARGIN = 262144` 的余量确保恢复后分配的 row_id 不会与崩溃前分配的 row_id 冲突。

### 6.2 完整启动链路

```
srv_start()
  ├── dict_init()                      # dict0dict.cc:定义, dict0boot.cc:调用
  │   ├── dict_sys = ut::zalloc_new<dict_sys_t>()
  │   ├── dict_sys->table_hash = hash_create(100)
  │   ├── dict_sys->table_id_hash = hash_create(100)
  │   └── UT_LIST_INIT(dict_sys->table_LRU)
  ├── dict_boot()                      # dict0boot.cc:209
  │   ├── dict_hdr_get()              # 读 page 7
  │   ├── row_id 恢复
  │   └── ibuf_init_at_db_start()
  ├── dict_create()                    # dict0boot.cc:269 (首次启动)
  │   ├── dict_hdr_create()           # 初始化字典头页
  │   ├── dict_boot()
  │   ├── dict_create_idx_col_for_mysql()  # 创建 SYS_* 系统表
  │   └── dict_create_foreign_tree()  # 外键空间
  └── dict_load_sys_tables()          # 加载系统表到缓存的
      └── 从 DD 表空间加载 mysql.* 表
```

### 6.3 分配新 ID — dict_hdr_get_new_id()

```cpp
// dict0boot.cc:71
void dict_hdr_get_new_id(table_id_t *table_id,
                         space_index_t *index_id,
                         space_id_t *space_id,
                         page_size_t *page_size) {

  mtr_t mtr;
  mtr_start(&mtr);

  /* 步骤 1：X-latch 字典头页面 */
  auto dict_hdr = dict_hdr_get(&mtr);

  /* 步骤 2：读取当前最大值 */
  if (table_id) {
    *table_id = mach_read_from_8(
        dict_hdr + DICT_HDR_MAX_TABLE_ID);
  }

  /* 步骤 3：自增并写回（预留 DICT_HDR_RESERVED = 100） */
  auto new_max = *table_id + DICT_HDR_RESERVED;
  mlog_write_uint64(dict_hdr + DICT_HDR_MAX_TABLE_ID,
                    new_max, &mtr);

  if (index_id) {
    *index_id = mach_read_from_4(
        dict_hdr + DICT_HDR_MAX_INDEX_ID);
    new_max = *index_id + DICT_HDR_RESERVED;
    mlog_write_uint64(dict_hdr + DICT_HDR_MAX_INDEX_ID,
                      new_max, &mtr);
  }

  if (space_id) {
    *space_id = mach_read_from_4(
        dict_hdr + DICT_HDR_MAX_SPACE_ID);
    new_max = *space_id + DICT_HDR_RESERVED;
    mlog_write_uint64(dict_hdr + DICT_HDR_MAX_SPACE_ID,
                      new_max, &mtr);
  }

  mtr_commit(&mtr);
}
```

**批量预留设计**：

每次分配不是给"1个新 ID"，而是"100个 ID 的区间"。这样做的好处：

- 第一个 CREATE TABLE 在 redo log 中写一次字典头
- 后续 99 个 CREATE TABLE 完全不需要修改字典头页
- 只有当 100 个 ID 用完时才会再次写入

对于 `DICT_HDR_MAX_INDEX_ID` 同理。这意味着在一个 MTR 写入 100 个预留 ID 前，可以创建 100 个索引而不触发字典头页的 redo log。

---

## 7. Instant ADD/DROP COLUMN 支持

### 7.1 版本号机制

```cpp
// dict0mem.h — dict_table_t 中
uint64_t *version_added;    /* 每列的创建版本号，长度 n_t_cols */
uint64_t *version_dropped;  /* 每列的删除版本号，长度 n_t_cols */
uint64_t current_version;   /* 当前版本号（每次 Instant DDL 后递增） */
```

当执行 `ALTER TABLE t ADD COLUMN c INT, ALGORITHM=INSTANT` 时：

```
1. 新列 c 被追加到 cols 数组末尾
2. n_t_cols 增加
3. version_added[n_cols-1] 写入当前 current_version
4. current_version++
```

### 7.2 瞬时间隙列

当执行 `ALTER TABLE t DROP COLUMN c, ALGORITHM=INSTANT` 时：

```
1. 列 c 在物理上并不被删除（页面记录不变）
2. version_dropped[c_idx] 写入当前 current_version
3. 行记录中的该列变得"隐藏"
4. DML 不读取该列；INSERT 写入占位符
```

**行格式变化**：

```
Instant ADD COLUMN 前:
  记录头 + 固定列 + 可变列

Instant ADD COLUMN 后:
  记录头 + 固定列 + 原始列 + 新增列的默认值

         ↓  新增的列 packed 在行尾
  (新增列可以放在现有记录之后，不修改已有行)
```

```cpp
// dict0mem.h: DICT_TF2_INSTANT_SET
#define DICT_TF2_INSTANT_SET  (1UL << 0)

// dict_table_has_instant_cols()
```

读取时：

```cpp
// row0sel.cc — 读取行记录时
if (dict_table_has_instant_cols(table)) {
  /* 跳过 version_dropped 标记为"已删除"的列 */
  /* 从行尾读取 version_added 标记的"新增但未写入"的列的默认值 */
}
```

---

## 8. 崩溃恢复与数据字典

### 8.1 恢复后的字典重建

崩溃恢复后，InnoDB 需要重新加载数据字典：

```
崩溃恢复流程:
  ├── redo log apply (所有写入重做)
  │   └── 包括字典头页 DICT_HDR_PAGE_NO 的更新
  ├── undo log apply (回滚未提交事务)
  │   └── 包括对表定义的修改
  ├── dict_init() + dict_boot() ← 重建内存结构
  ├── fil_open_single_table_tablespaces() ← 打开所有 .ibd
  └── dict_load_sys_tables() ← 通过 DD 加载系统表
```

**关键问题：**.ibd 文件中的 SDI 与 DD 表空间不一致怎么办？

```
场景: 用户执行了 ALTER TABLE ... INSTANT ADD COLUMN
  → DD 表空间中更新了列定义
  ↓ 但崩溃在这两步之间

恢复方案:
  1. redo log apply 后，DD 状态可能不一致
  2. InnoDB 以最新 redo 写入的 DICT_HDR_PAGE_NO 为准
  3. 系统表也从 DD 表空间一致恢复
  4. 如果 .ibd SDI 落后于 DD → 以 DD 为准
  5. 如果 DD 丢失 → 从 .ibd SDI 恢复

这种设计确保: 只要至少一个来源可用（DD 或 .ibd SDI），表定义就不会丢失。
```

### 8.2 字典头页布局

系统表空间 page 7（`DICT_HDR_PAGE_NO`）的布局：

```
DICT_HDR_ROW_ID        (8 bytes, offset  0): 已分配的最大 row_id
DICT_HDR_MAX_TABLE_ID  (8 bytes, offset  8): 已分配的最大 table_id
DICT_HDR_MAX_INDEX_ID  (8 bytes, offset 16): 已分配的最大 index_id
DICT_HDR_MAX_SPACE_ID  (4 bytes, offset 24): 已分配的最大 space_id
DICT_HDR_MIX_ID_LOW    (4 bytes, offset 28): 混合 ID 低位
DICT_HDR_FSEG_HEADER   (10 bytes, offset 32): 字典文件段头
```

---

## 9. 并发控制

### 9.1 锁层级

```
dict_sys.mutex (DictSysMutex)   ← 保护整个字典结构
  ├── table_hash 的读/写
  ├── table_id_hash 的读/写
  ├── table_LRU 的遍历/修改
  └── table_non_LRU 的遍历/修改
```

`dict_sys.mutex` 是 InnoDB 中最热的锁之一。获取它的路径包括：

- 每个 SQL 语句打开表时（`dd_table_open_on_id`/`on_name`）
- DDL 创建/修改/删除表
- `dict_make_room_in_cache()` 驱逐
- 外键关系维护

**热点问题**：

在高并发场景（1000+ 连接）下，`dict_sys.mutex` 可能成为性能瓶颈。MySQL 8.0 通过以下方式缓解：

1. **缓存热表**：打开过的表被缓存，后续不用重复获取锁
2. **分区 table_hash**：8.0 的 table_hash 使用更多桶，减少冲突概率
3. **非关键路径无锁**：`n_ref_count` 使用 `std::atomic`，增/减不持有 dict mutex

### 9.2 与 MDL 的关系

MySQL Server 层的 MDL（Metadata Lock）与 InnoDB 的 dict mutex 是两个独立的锁层级：

```
SQL 执行:
  1. MDL 获取（Server 层）← 保护跨会话的表定义一致
  2. dict_sys.mutex 获取（InnoDB 层）← 查找/加载 dict_table_t
  3. dict_sys.mutex 释放
  4. MDL 在事务结束时释放（或不释放——取决于是否使用 MDL 事务）

顺序: 先 MDL，后 dict mutex
```

`dd_table_open_on_id()` 的 `MDL_ticket **mdl` 参数即用于与 MDL 的交互。如果 MDL 未获取，InnoDB 在打开表时先获取 MDL 读锁。

---

## 10. 完整调用链总结

### 10.1 表打开路径

```
SQL: SELECT * FROM t
  └─ mysql_execute_command()
      └─ open_tables_for_query()
          └─ dd_table_open_on_name(thd, &mdl, "mydb/t")
              ├─ dict_sys_mutex_enter()
              ├─ HASH_SEARCH(table_hash, ...) ← 缓存查找
              ├─ 命中 → ib_table->acquire() → 返回
              ├─ 未命中 → dict_sys_mutex_exit()
              │   └─ dd_get_table_id("mydb/t")           ← DD API
              │   └─ dd_table_open_on_id(table_id, ...)
              │       ├─ dict_sys_mutex_enter()
              │       ├─ HASH_SEARCH(id_hash, ...)
              │       ├─ 命中 → acquire → 返回
              │       └─ 未命中:
              │           ├─ dict_sys_mutex_exit()
              │           ├─ dd_table_open_on_id_low()
              │           │   ├─ fil_space_acquire()
              │           │   ├─ ibd_file_read_sdi()
              │           │   └─ sdi_deserialize()
              │           ├─ dict_sys_mutex_enter()
              │           ├─ dict_table_add_to_cache()
              │           └─ ib_table->acquire()
              └─ 返回 dict_table_t*
```

### 10.2 DDL 路径

```
CREATE TABLE t (a INT PRIMARY KEY, b INT, KEY(b))
  └─ dict_create_table()                                # dict0crea.cc
      ├─ dict_mem_table_create()                        # 分配 dict_table_t
      ├─ dict_mem_add_col()                             # 添加列
      ├─ dict_mem_index_create()                        # 创建聚簇索引描述
      ├─ dict_index_add_to_cache(table, clustered)      # 加入缓存
      ├─ dict_mem_index_create()                        # 创建二级索引描述
      ├─ dict_index_add_to_cache(table, secondary)      # 加入缓存
      ├─ dict_table_add_to_cache(table, false)          # 不可驱逐
      ├─ btr_create(index)                              # 创建 B-tree 根页
      └─ dict_hdr_get_new_id(&table_id, ...)            # 分配 ID
```

### 10.3 驱逐路径

```
内存压力（新表打开过多）
  └─ dict_table_add_to_cache()
      └─ dict_make_room_in_cache(dict_sys_size_limit)
          └─ while dict_sys->size > max_size && 可遍历
              └─ table = UT_LIST_GET_LAST(table_LRU)
              └─ dict_table_can_be_evicted(table)
                  ├─ can_be_evicted?
                  ├─ foreign_set.empty? && referenced_set.empty?
                  ├─ n_ref_count == 0?
                  └─ quiesce == QUIESCE_NONE?
              └─ dict_table_remove_from_cache(table)
                  ├─ HASH_DELETE from table_hash
                  ├─ HASH_DELETE from table_id_hash
                  ├─ UT_LIST_REMOVE from table_LRU
                  ├─ 释放外键引用
                  ├─ 释放 AHI 条目
                  └─ mem_heap_free(table->heap)
```

---

## 11. 源码索引

| 函数/结构 | 文件 | 行号 | 关键作用 |
|-----------|------|------|---------|
| `dict_sys_t` | `dict0dict.h` | 1019 | 全局字典系统 |
| `dict_table_t` | `dict0mem.h` | 1925 | 表元数据描述 |
| `dict_index_t` | `dict0mem.h` | 1067 | 索引元数据描述 |
| `dict_col_t` | `dict0mem.h` | 485 | 列描述结构体 |
| `dict_field_t` | `dict0mem.h` | 891 | 索引字段描述 |
| `dict_init()` | `dict0dict.cc` | 106 | 创建 dict_sys 及 hash 表 |
| `dict_boot()` | `dict0boot.cc` | 209 | 字典启动初始化 |
| `dict_hdr_get_new_id()` | `dict0boot.cc` | 71 | 分配新 ID（批量预留） |
| `dict_table_add_to_cache()` | `dict0dict.cc` | 1175 | 表加入缓存 |
| `dict_table_can_be_evicted()` | `dict0dict.cc` | 1255 | 驱逐条件判断 |
| `dict_make_room_in_cache()` | `dict0dict.cc` | 1285 | LRU 驱逐入口 |
| `dict_table_remove_from_cache()` | `dict0dict.cc` | 1954 | 从缓存移除表 |
| `dict_index_add_to_cache()` | `dict0dict.cc` | 2303 | 索引加入缓存 |
| `dd_table_open_on_id()` | `dict0dd.cc` | 701 | 按 ID 打开表 |
| `dd_table_open_on_name()` | `dict0dd.cc` | 580 | 按名打开表 |
| `dd_table_open_on_id_low()` | `dict0dd.cc` | 623 | 从 DD 加载表 |
| `dict_table_t::acquire()` | `dict0mem.ic` | 122 | 引用计数递增 |
| `dict_table_t::release()` | `dict0mem.ic` | 128 | 引用计数递减 |
