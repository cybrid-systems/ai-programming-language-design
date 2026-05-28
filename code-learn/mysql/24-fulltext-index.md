# 24. InnoDB 全文索引（Full-Text Search）— 逐行源码追踪

> 本文基于 MySQL 8.4 主线源码，通过 doom-lsp（clangd LSP）对 InnoDB 全文索引进行逐行符号解析与数据流追踪。核心源文件：`storage/innobase/fts/fts0fts.cc`、`storage/innobase/fts/fts0opt.cc`、`storage/innobase/include/fts0types.h`、`storage/innobase/include/fts0fts.h`。

---

## 0. 概述

InnoDB 的全文索引（FTS）是基于**倒排索引（Inverted Index）**的实现，在 **InnoDB 存储引擎层**实现，与事务引擎紧密集成。FTS 不依赖 MyISAM 的 SQL 层实现。

### FTS 的核心架构

```
用户表 (t)
  └── FTS 辅助表（引擎内部自动创建）
      ├── FTS_xxxxxx_INDEX_N        ← N=1..6 分词索引表（6 分片）
      ├── FTS_xxxxxx_DELETED        ← 已删除文档的 DOC_ID
      ├── FTS_xxxxxx_DELETED_CACHE  ← 已删除文档缓存
      ├── FTS_xxxxxx_BEING_DELETED  ← 正在删除中的
      └── FTS_xxxxxx_CONFIG         ← 配置表

FTS 内存组件:
  ├── fts_cache_t（文档 + 分词缓存）@ fts0types.h
  └── fts_optimize_t（后台优化线程状态）@ fts0opt.cc:162

后台线程:
  ├── fts_optimize_thread() @ fts0opt.cc:2872 — 定期合并 + 清理
  └── fts_sync() @ fts0fts.cc:4420 — 刷缓存到辅助表
```

### 索引表格式（6 分片）

```sql
-- 每个 FTS 索引维护 6 个分片表（INDEX_1 ~ INDEX_6）
CREATE TABLE FTS_<table_id>_INDEX_1 (
  DOC_ID BIGINT UNSIGNED NOT NULL,
  POSITION BIGINT UNSIGNED NOT NULL,
  WORD VARCHAR(255) NOT NULL
);
-- 每个分片在合并时最终汇入主索引
```

6 个分片的设计理由：减少 DML 写入 FTS 索引时的锁争用。每个 INSERT 写入 6 个分片中的一个（按 `WORD` 哈希），后台优化线程合并为一个主索引。

---

## 1. 核心数据结构

### 1.1 fts_cache_t — FTS 内存缓存

```cpp
// fts0types.h — fts_cache_t 定义
struct fts_cache_t {
  /** 两个读写锁（保护缓存的并发访问）*/
  rw_lock_t lock;           /* @ fts0fts.cc:544 — 通用锁 */
  rw_lock_t init_lock;      /* @ fts0fts.cc:546 — 初始化锁 */

  /** 文档 ID → 分词条目 */
  ib_rbt_t *words;          /* 红黑树 key=WORD, value=doc_id+pos 列表 */

  /** 同步（flush）时的状态 */
  fts_sync_t *sync;         /* @ fts0fts.cc:563 创建 */

  /** 缓存大小控制 */
  ulint total_size;         /* 当前缓存总大小 */
  ulint max_size;           /* innodb_ft_cache_size，默认 8MB */
};
```

`fts_cache_create()` 构造函数：

```cpp
// fts0fts.cc:532
fts_cache_t *fts_cache_create(dict_table_t *table) {

  fts_cache_t *cache;
  mem_heap_t *heap = mem_heap_create(512, UT_LOCATION_HERE);

  cache = static_cast<fts_cache_t *>(
      mem_heap_zalloc(heap, sizeof(*cache)));           /* :540 */

  rw_lock_create(fts_cache_rw_lock_key,
                 &cache->lock, LATCH_ID_FTS_CACHE);      /* :544 */
  rw_lock_create(fts_cache_init_rw_lock_key,
                 &cache->init_lock, LATCH_ID_FTS_CACHE); /* :546 */

  /* 为每个 FTS 索引创建子缓存 */
  for (idx = 0; idx < table->fts->indexes; idx++) {
    fts_add_index(cache, table, idx, heap);               /* :585 */
  }

  cache->sync = static_cast<fts_sync_t *>(
      mem_heap_zalloc(heap, sizeof(fts_sync_t)));         /* :563 */

  fts_cache_init(cache);                                   /* :572 */
  return cache;
}
```

### 1.2 fts_sync_t — 同步状态

```cpp
// fts0types.h — fts_sync_t
struct fts_sync_t {
  /** 同步状态 */
  ulint state;
  /** 最大文档 ID */
  doc_id_t max_doc_id;
  /** 已同步的文档 ID */
  doc_id_t sync_doc_id;
  /** 当前正在同步的文档数 */
  ulint n_docs;
};
```

### 1.3 fts_optimize_t — 优化线程状态

```cpp
// fts0opt.cc:162
struct fts_optimize_t {
  trx_t *trx;                    /* 优化事务句柄 */
  mem_heap_t *self_heap;         /* 自管理内存堆 */
  const char *name_prefix;       /* FTS 表名前缀 */
  dict_table_t *fts_index_table; /* 当前处理的索引表 */
  dict_table_t *fts_common_table;/* FTS 公共表 */
  dict_table_t *table;           /* 用户表 */
  dict_index_t *index;           /* FTS 索引 */

  /** 要删除的 DOC_ID 列表 */
  doc_id_t *to_delete;
  ulint del_pos;

  bool done;                     /* 优化是否完成 */
  fts_zip_t *zip;                /* zlib 压缩状态 */
  fts_optimize_graph_t *graph;   /* 分片合并图 */
  ulint n_completed;             /* 完成的分片数 */
};
```

### 1.4 辅助表命名约定

```cpp
// fts0fts.cc:139-145
#define FTS_SUFFIX_BEING_DELETED       "_BEING_DELETED"
#define FTS_SUFFIX_BEING_DELETED_CACHE "_BEING_DELETED_CACHE"
#define FTS_SUFFIX_CONFIG             "_CONFIG"
#define FTS_SUFFIX_DELETED            "_DELETED"
#define FTS_SUFFIX_DELETED_CACHE      "_DELETED_CACHE"

/* 辅助表名模式: FTS_<8位hex table_id>_<SUFFIX> */
static const char *fts_common_tables[] = {
  "_DELETED",
  "_DELETED_CACHE",
  "_BEING_DELETED",
  "_BEING_DELETED_CACHE",
  "_CONFIG",
  nullptr,
};
```

---

## 2. INSERT — FTS 索引构建路径

### 2.1 完整调用链

```
INSERT INTO t (text) VALUES ('hello world')

  └─ row_ins_step()                   ← 正常行插入
  └─ row_ins_clust_index_entry()      ← 写入聚簇索引
  └─ fts_trx_add_op()                 ← 记录 FTS 操作（延迟处理）
      │  fts0fts.cc:2674
      │
      └─ 事务提交时:
          └─ fts_commit()             ← 真正的 FTS 写入发生在这里
              │  fts0fts.cc:3290
              │
              ├─ fts_get_next_doc_id()     ← 分配新 DOC_ID
              │  fts0fts.cc:2801
              │
              ├─ fts_fetch_doc_from_rec()  ← 从记录提取文档文本
              │  fts0fts.cc:3425
              │
              ├─ fts_tokenize_document()   ← 分词
              │  fts0fts.cc:4855
              │
              └─ fts_add_doc_by_id()       ← 缓存分词结果
                  fts0fts.cc:3618
                  └─ fts_cache_add_doc()   ← 写入内存缓存
                      fts0fts.cc:1176
```

### 2.2 fts_trx_add_op() — 延迟记录 FTS 操作

```cpp
// fts0fts.cc:2674
void fts_trx_add_op(fts_trx_table_t *ftt,
                    fts_trx_table_t::op_type op,
                    byte *data, ulint len,
                    doc_id_t doc_id, ulint offsets) {

  fts_trx_t *ftt_trx = ftt->trx;

  /* 在事务内记录 FTS 操作（未提交时不做分词，只保存原始行数据）*/
  /* 这保证了 FTS 操作的事务性：回滚时丢弃该条目 */

  fts_trx_table_op_t *fts_op =
      static_cast<fts_trx_table_op_t *>(
          mem_heap_alloc(ftt_trx->heap, sizeof(*fts_op)));

  fts_op->type = op;       /* FTS_OP_INSERT / FTS_OP_DELETE / FTS_OP_MODIFY */
  fts_op->doc_id = doc_id;
  fts_op->data = data;
  fts_op->len = len;
  fts_op->offsets = offsets;

  /* 追加到事务的 FTS 操作链表尾部 */
  UT_LIST_ADD_LAST(ftt_trx->trx_table_list, fts_op);
}
```

### 2.3 fts_commit() — 事务提交时实际处理

```cpp
// fts0fts.cc:3290
void fts_commit(trx_t *trx) {

  /* 对事务中每个有 FTS 操作的表 */
  for (ftt = trx->fts_trx->tables; ftt; ftt = ftt->next) {

    switch (ftt->op) {
      case FTS_OP_INSERT:
        /* 分配 DOC_ID、分词、缓存 */
        fts_add(ftt);
        break;
      case FTS_OP_DELETE:
        /* 记录到 DELETED 辅助表 */
        fts_delete(ftt);
        break;
      case FTS_OP_MODIFY:
        /* DELETE + INSERT */
        fts_modify(ftt);
        break;
    }
  }

  /* 检查缓存是否需要 sync（刷入磁盘）*/
  if (fts_need_sync) {
    fts_sync_table(table);  /* fts0fts.cc:4528 */
  }
}
```

### 2.4 fts_add() — 单条 INSERT 处理

```cpp
// fts0fts.cc:3065
static void fts_add(fts_trx_table_t *ftt) {

  /* ──── 步骤 1：分配 DOC_ID ──── */
  /* 从 FTS_CONFIG 表读取当前最大 ID 并自增 */
  /* fts0fts.cc:2801 */
  doc_id_t doc_id = fts_get_next_doc_id(ftt->table);

  /* ──── 步骤 2：从行记录提取文档文本 ──── */
  /* 使用 fts_fetch_doc_from_rec() 从聚簇索引行中
   * 提取所有 FTS 列的文本内容，拼接为一个文档 */
  /* fts0fts.cc:3425 */
  fts_doc_t doc;
  fts_fetch_doc_from_rec(ftt->table, ftt->row, &doc);

  /* ──── 步骤 3：分词 ──── */
  /* fts0fts.cc:4855 */
  fts_tokenize_document(&doc, &result);

  /* ──── 步骤 4：添加到缓存 ──── */
  /* fts0fts.cc:3618 */
  fts_add_doc_by_id(ftt, doc_id, &result);
}
```

### 2.5 分词路径

```cpp
// fts0fts.cc:4855
static void fts_tokenize_document(
    fts_doc_t *doc, fts_doc_t *result_doc) {

  /* 根据配置选择分词器 */
  if (fts_use_external_plugins) {
    /* fts0fts.cc:4828 — fts_tokenize_by_parser() */
    /* 使用自定义分词器插件 */
  } else {
    /* 默认：fts_tokenize_document_internal() */
    /* fts0fts.cc:4761 */
    fts_tokenize_document_internal(doc, result_doc);
  }
}
```

**内部分词器核心逻辑**：

```cpp
// fts0fts.cc:4761 — 简化
static void fts_tokenize_document_internal(
    fts_doc_t *doc, fts_doc_t *result_doc) {

  const CHARSET_INFO *cs = fts_get_charset(doc->table);  /* :270 */
  fts_tokenize_param_t param;                             /* :179 */

  param.result_doc = result_doc;
  param.add_pos = 0;

  /* 逐字符扫描文档文本 */
  const char *end = doc->text + doc->text_len;
  const char *ptr = doc->text;

  while (ptr < end) {
    /* ── 跳过空白字符 ── */
    int mblen = my_isspace(cs, ptr) ? 1 : 0;
    if (mblen) { ptr++; continue; }

    /* ── 找到分词起点 ── */
    const char *start = ptr;
    int char_len;
    while (ptr < end && !my_isspace(cs, ptr)) {
      char_len = my_mbcharlen(cs, (ulint)(uchar)*ptr);
      ptr += (char_len > 0) ? char_len : 1;
    }

    /* ── 提取分词并写入 result_doc ── */
    fts_add_token(result_doc, start, ptr - start);   /* :4639 */
  }
}
```

**停用词过滤**：

```cpp
// fts0fts.cc:4552
static bool fts_check_token(const byte *token, ulint len) {

  /* 最小/最大分词长度检查 */
  /* innodb_ft_min_token_size 默认 3 */
  /* innodb_ft_max_token_size 默认 84 */
  if (len < fts_min_token_size || len > fts_max_token_size) {
    return false;
  }

  /* 停用词检查 */
  /* fts0fts.cc:300 — 从 FTS_CONFIG 或默认加载 */
  return !fts_is_stopword(token, len, doc_table);

  return true;
}
```

### 2.6 fts_cache_add_doc() — 缓存写入

```cpp
// fts0fts.cc:1176
static void fts_cache_add_doc(
    fts_cache_t *cache, dict_index_t *index,
    doc_id_t doc_id, fts_doc_t *result_doc) {

  /* ──── 步骤 1：获取或创建分词的缓存节点 ──── */
  /* 红黑树查找 WORD → fts_cache_word_t */
  ib_rbt_t *words = fts_get_index_cache(cache, index);  /* :972 */

  for (ulint i = 0; i < result_doc->tokens; i++) {
    fts_tokenizer_word_t *token = result_doc->tokens[i];

    /* ──── 步骤 2：在红黑树中查找 WORD ──── */
    rbt_value_t value;
    rbt_search(words, &value, token);

    if (found) {
      word = (fts_cache_word_t *)value;
    } else {
      /* 创建新缓存条目 */
      word = fts_cache_word_create(words, token);
    }

    /* ──── 步骤 3：添加文档 ID + 位置到该分词 ──── */
    /* fts0fts.cc:1065 */
    fts_cache_node_add_positions(
        word, doc_id, result_doc->add_pos + i);
  }

  /* ──── 步骤 4：更新缓存大小 ──── */
  cache->total_size += result_doc->text_len;
  /* 如果超过 max_size，触发 fts_sync() */
  if (cache->total_size >= cache->max_size) {
    fts_need_sync = true;
  }
}
```

---

## 3. DELETE 路径

```cpp
// fts0fts.cc:3085
static void fts_delete(fts_trx_table_t *ftt) {

  /* ──── 步骤 1：获取被删除行的 DOC_ID ──── */
  doc_id_t doc_id = fts_get_doc_id_from_row(ftt->table, ftt->row);
  /* fts0fts.cc:5231 */

  /* ──── 步骤 2：写入 DELETED 辅助表 ──── */
  /* DELETE 不立即修改 INDEX 表（避免昂贵的线性扫描）
   * 而是将 DOC_ID 写入 DELETED/DELETED_CACHE 表
   * 后台 optimize 线程在合并时清理 */
  fts_delete_doc_id_by_row(ftt, doc_id);
}
```

**延迟删除的设计理由**：

FTS 索引表的结构是 `(WORD, DOC_ID, POSITION)`，要删除某个 DOC_ID 的所有分词，需要扫描全表——因为分词分布在不同的行中。延迟删除避免了这个 O(n) 操作：

```
DELETE FROM t WHERE id = 1

立即执行:
  ✓ 从聚簇索引删除行（正常 DML）
  ✓ 将 DOC_ID 写入 FTS_DELETED 表（轻量操作）
  ✗ 不从 FTS_INDEX 表中删除分词记录

后台合并时:
  fts_optimize() 扫描 FTS_DELETED 表
  → 读取索引表的所有分词
  → 过滤掉 DELETED 中的 DOC_ID
  → 将剩余分词写回新索引表
  → 清空 DELETED 表
```

---

## 4. 缓存同步 — fts_sync()

当缓存达到 `innodb_ft_cache_size`（默认 8MB）或事务提交时，触发缓存刷入辅助表。

```cpp
// fts0fts.cc:4420
static dberr_t fts_sync(fts_sync_t *sync, bool unlock_cache, bool wait) {

  trx_t *trx = sync->trx;

  /* ──── 阶段 1：开始同步 ──── */
  /* fts0fts.cc:4232 — fts_sync_begin() */
  /* 锁定缓存 → 标记同步状态 */
  sync->state = FTS_SYNC_RUNNING;

  /* ──── 阶段 2：遍历每个 FTS 索引的子缓存 ──── */
  for (i = 0; i < table->fts->indexes; i++) {
    /* fts0fts.cc:4254 — fts_sync_index() */
    fts_index_cache_t *index_cache = fts_find_index_cache(cache, index);

    /* ──── 阶段 3：写入分词到 INDEX_N 辅助表 ──── */
    /* fts0fts.cc:4121 — fts_sync_write_words() */
    /* 遍历缓存中所有分词 → 插入辅助表行 (WORD, DOC_ID, POSITION) */

    for (word in index_cache->words) {
      for (doc_id in word->doc_ids) {
        /* 使用 btr_cur_ins_lock_and_rec() 插入辅助表 */
        fts_write_node(index_table, word, doc_id, position);
        /* fts0fts.cc:4004 */
      }
    }
  }

  /* ──── 阶段 4：更新 DELETED_CACHE 表 ──── */
  /* fts0fts.cc:4066 — fts_sync_add_deleted_cache() */

  /* ──── 阶段 5：提交同步 ──── */
  /* fts0fts.cc:4314 — fts_sync_commit() */
  fts_update_sync_doc_id();   /* :2967 更新最大已同步 DOC_ID */
  fts_cache_clear(cache);     /* :925 清空缓存 */
}
```

---

## 5. 查询路径 — MATCH...AGAINST

### 5.1 Natural Language Mode

```sql
SELECT * FROM t
WHERE MATCH(text) AGAINST('hello world' IN NATURAL LANGUAGE MODE)
```

SQL 层将 `MATCH...AGAINST` 转换为 `fts_query()` 调用，InnoDB 执行以下步骤：

```
fts_query(table, result, query_string, mode)
  │
  ├─ 步骤 1：分词查询字符串
  │   fts_tokenize_document(query, &tokens)
  │
  ├─ 步骤 2：对每个分词，查找辅助表
  │   for (token in tokens) {
  │     fts_find_index_cache(cache, token)  ← 先查缓存
  │     if not found:
  │       btr_pcur_open(index_table, WORD=token, PAGE_CUR_GE)
  │       → 收集所有 (DOC_ID, POSITION)
  │   }
  │
  ├─ 步骤 3：合并结果集（所有分词的 DOC_ID 集合）
  │   doc_ids = intersect(all_tokens_docs)
  │
  ├─ 步骤 4：计算相关性（TF-IDF）
  │   for (doc_id in doc_ids) {
  │     score = Σ(token_tf * log(total_docs / token_df))
  │   }
  │
  └─ 步骤 5：按得分降序返回
```

### 5.2 Boolean Mode

```sql
SELECT * FROM t
WHERE MATCH(text) AGAINST('+hello -world' IN BOOLEAN MODE)
```

布尔模式的操作符：

| 操作符 | 示例 | 含义 |
|--------|------|------|
| `+` | `+hello` | 文档必须包含 hello |
| `-` | `-world` | 文档必须不包含 world |
| 无 | `hello` | 可选，增加相关性得分 |
| `~` | `~hello` | 降低出现 hello 的文档的得分 |
| `*` | `hel*` | 通配符（匹配 hello, help, helmet...） |

布尔模式不计算 TF-IDF，只按操作符逻辑过滤。

### 5.3 Query Expansion

```sql
SELECT * FROM t
WHERE MATCH(text) AGAINST('hello' WITH QUERY EXPANSION)
```

两阶段查询：

```
阶段 1 — 普通搜索:
  MATCH(text) AGAINST('hello') → 找到相关文档

阶段 2 — 扩展搜索:
  MATCH(text) AGAINST('hello +found_term1 +found_term2')
  → 基于第一阶段找到的文档中出现的其他有意义的词
  → 扩展原始查询
```

```cpp
// fts0fts.cc:3346
void fts_query_expansion_fetch_doc(
    fts_doc_t *result, ...) {
  /* 读取排名靠前的文档 */
  /* 提取其中出现频率高的新词 */
  /* 将新词加入原查询再搜索一次 */
}
```

---

## 6. 后台优化线程

### 6.1 fts_optimize_thread() — 主循环

```cpp
// fts0opt.cc:2872
void fts_optimize_thread() {

  /* ──── 步骤 1：初始化 ──── */
  fts_optimize_init();                    /* :3007 */

  while (!fts_opt_start_shutdown) {

    /* ──── 步骤 2：检查优化队列 ──── */
    /* 遍历所有有 FTS 索引的表 */
    for (slot in optimize_slots) {

      switch (slot->state) {

        case FTS_STATE_LOADED:
          /* 新加入的表 → 开始优化 */
          fts_optimize_start_table(slot);   /* :2622 */
          break;

        case FTS_STATE_RUNNING:
          /* 正在优化中 → 继续处理 */
          fts_optimize_index(slot);          /* :1857 */
          break;

        case FTS_STATE_DONE:
          /* 优化完成 */
          break;
      }
    }

    /* ──── 步骤 3：检查是否需要 sync ──── */
    if (fts_is_sync_needed(slot)) {
      fts_optimize_sync_table(slot);       /* :2855 */
    }

    /* ──── 步骤 4：等待 FTS_QUEUE_WAIT 秒 ──── */
    os_event_wait(fts_optimize_wq, FTS_QUEUE_WAIT);
  }

  fts_optimize_shutdown();  /* :3024 */
}
```

### 6.2 fts_optimize_index() — 分片合并

```cpp
// fts0opt.cc:1857
static dberr_t fts_optimize_index(fts_optimize_t *ftso) {

  /* ──── 步骤 1：读取索引表的分词数据 ──── */
  /* fts0opt.cc:804 — fts_index_fetch_words() */
  /* 遍历 INDEX_1..INDEX_6 表，读取所有分词 */
  /* 使用红黑树按 WORD 合并 */

  /* ──── 步骤 2：过滤已删除的 DOC_ID ──── */
  /* fts0opt.cc:954 — fts_fetch_doc_ids() */
  /* 从 FTS_DELETED 表读取被删除的 DOC_ID */
  /* 从合并的索引中移除匹配条目 */

  /* ──── 步骤 3：压缩 ──── */
  /* fts0opt.cc:1506 — fts_optimize_compact() */
  /* = zlib 压缩合并后的分词位置列表 */

  /* ──── 步骤 4：写回主索引 ──── */
  /* fts0opt.cc:1414 — fts_optimize_write_word() */
  /* 将压缩后的数据写入优化后的主索引表 */

  /* ──── 步骤 5：清理 ──── */
  /* 更新 CONFIG 表 */
  /* 清空 DELETED 表 */
}
```

### 6.3 fts_optimize_table() — OPTIMIZE TABLE 触发

```cpp
// fts0opt.cc:2391
void fts_optimize_table(dict_table_t *table) {

  /* 用户执行 OPTIMIZE TABLE t 时触发 */

  /* 1. 强制 sync：将缓存刷入辅助表 */
  fts_sync_table(table);  /* fts0fts.cc:4528 */

  /* 2. 加载 DELETED 快照 */
  fts_optimize_create_deleted_doc_id_snapshot(table);
  /* fts0opt.cc:2089 */

  /* 3. 对每个 FTS 索引执行合并 */
  for (each index in table->fts->indexes) {
    fts_optimize_index(ftso);       /* fts0opt.cc:1857 */
  }

  /* 4. 清理快照 */
  fts_optimize_purge_snapshot(ftso);  /* fts0opt.cc:2291 */
}
```

---

## 7. DOC_ID 管理

### 7.1 DOC_ID 分配

```cpp
// fts0fts.cc:2801
doc_id_t fts_get_next_doc_id(dict_table_t *table) {

  fts_t *fts = table->fts;
  doc_id_t doc_id;

  mutex_enter(&fts->doc_id_mutex);

  if (fts->next_doc_id == 0) {
    /* 首次调用：从配置表读取 */
    fts_init_doc_id(table);   /* fts0fts.cc:4965 */
  }

  doc_id = fts->next_doc_id;
  fts->next_doc_id++;          /* 自增 */

  mutex_exit(&fts->doc_id_mutex);

  return doc_id;
}
```

### 7.2 文档 ID 的存储

每个有 FTS 索引的表必须有 `FTS_DOC_ID` 列（可自动隐藏添加）：

```sql
CREATE TABLE t (
  id INT PRIMARY KEY,
  text TEXT,
  FTS_DOC_ID BIGINT UNSIGNED NOT NULL AUTO_INCREMENT UNIQUE
) ENGINE=InnoDB;
```

自动生成的 `FTS_DOC_ID` 列是 `syst_hidden` 的（不可见），但存储引擎内部使用。

---

## 8. FTS 限制

| 限制 | 原因 |
|------|------|
| 仅 InnoDB 表 | FTS 实现在 InnoDB 层 |
| 必须有 DOC_ID | 倒排索引需要 |
| 不支持分区表 | FTS 辅助表不能分区 |
| 不支持外键 | FTS 表结构包含引擎内部表 |
| 不支持 SPATIAL/FULLTEXT 混合 | 索引类型冲突 |
| 不支持 `DML` 在 `FTS_DOC_ID` 列上直接修改 | 内部一致性 |
| 不支持 `ON DELETE CASCADE` 的表上有 FTS | 级联删除无法追踪 |
| `innodb_ft_min_token_size` 默认 3 | 英文；CJK 用 ngram |

### CJK（中日韩）支持

对于中文、日文、韩文，MySQL 使用 ngram 分词器：

```sql
-- 创建 ngram 分词表的索引
CREATE TABLE t_cn (text TEXT)
  ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4;

ALTER TABLE t_cn ADD FULLTEXT INDEX ftx (text)
  WITH PARSER ngram;   /* 使用 ngram 插件 */

-- ngram_token_size 默认 2
-- 输入: "数据库MySQL"
-- 输出: "数据", "据库", "库M", "My", "yS", "SQ", "QL"
```

---

## 9. 配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `innodb_ft_cache_size` | 8MB | 每个表的 FTS 缓存大小 |
| `innodb_ft_total_cache_size` | 640MB | 所有表 FTS 缓存总大小 |
| `innodb_ft_min_token_size` | 3 | 最小分词长度（英文） |
| `innodb_ft_max_token_size` | 84 | 最大分词长度（英文） |
| `innodb_ft_num_word_optimize` | 2000 | 每次优化处理的分词数 |
| `innodb_ft_result_cache_limit` | 2000000000 | FTS 查询结果缓存限制 |
| `innodb_ft_enable_stopword` | ON | 启用停用词 |
| `innodb_ft_server_stopword_table` | — | 自定义停用词表 |
| `ngram_token_size` | 2 | ngram 分词大小（CJK） |

### 监控

```sql
-- 查看 FTS 辅助表状态
SELECT * FROM information_schema.INNODB_FTS_INDEX_TABLE;
SELECT * FROM information_schema.INNODB_FTS_INDEX_CACHE;
SELECT * FROM information_schema.INNODB_FTS_CONFIG;
SELECT * FROM information_schema.INNODB_FTS_DELETED;
SELECT * FROM information_schema.INNODB_FTS_BEING_DELETED;

-- FTS 状态变量
SHOW STATUS LIKE 'Innodb_fts%';
```

---

## 10. 完整调用链总结

```
INSERT t VALUES ('hello world')

  ┌─ row_ins_step()
  │   └─ fts_trx_add_op(FTS_OP_INSERT, row_data)
  │       fts0fts.cc:2674
  │
  └─ 事务提交: fts_commit(trx)
      fts0fts.cc:3290
      │
      ├─ fts_add(ftt)
      │   fts0fts.cc:3065
      │   ├─ fts_get_next_doc_id(table)         ← :2801
      │   ├─ fts_fetch_doc_from_rec(table, rec) ← :3425
      │   │   └─ 提取 FTS 列的文本内容
      │   ├─ fts_tokenize_document(doc, result)  ← :4855
      │   │   ├─ fts_tokenize_by_parser()        ← :4828 (插件)
      │   │   └─ fts_tokenize_document_internal() ← :4761 (默认)
      │   │       ├─ fts_check_token(token)      ← :4552
      │   │       └─ fts_add_token(token)        ← :4639
      │   └─ fts_add_doc_by_id(ftt, doc_id)      ← :3618
      │       └─ fts_cache_add_doc(cache, doc_id, tokens) ← :1176
      │
      └─ [如果缓存满了] fts_sync_table(table)
          fts0fts.cc:4528
          ├─ fts_sync(sync)                     ← :4420
          │   ├─ fts_sync_begin()               ← :4232
          │   ├─ fts_sync_index(index)          ← :4254
          │   │   └─ fts_sync_write_words()     ← :4121
          │   │       └─ fts_write_node()       ← :4004
          │   ├─ fts_sync_add_deleted_cache()   ← :4066
          │   └─ fts_sync_commit()              ← :4314
          └─ fts_cache_clear(cache)             ← :925

OPTIMIZE TABLE t

  └─ fts_optimize_table(table)
      fts0opt.cc:2391
      ├─ fts_sync_table(table)
      ├─ fts_optimize_create_deleted_doc_id_snapshot() ← :2089
      ├─ fts_optimize_indexes(ftso)            ← :2229
      │   └─ fts_optimize_index(ftso)          ← :1857
      │       ├─ fts_index_fetch_words(ftso)   ← :804
      │       ├─ fts_fetch_doc_ids(ftso)        ← :954
      │       ├─ fts_optimize_compact(ftso)     ← :1506
      │       └─ fts_optimize_write_word(ftso)  ← :1414
      └─ fts_optimize_purge_snapshot(ftso)      ← :2291

MATCH(text) AGAINST('hello' IN NATURAL LANGUAGE MODE)

  └─ fts_query(query, mode)
      ├─ 分词查询字符串
      ├─ fts_find_index_cache(cache, token)    ← :5292
      │   └─ fts_cache_find_word(cache, word)  ← :5304
      ├─ 查找辅助表 (DBL 层)
      ├─ 合并 DOC_ID 集合
      ├─ 计算 TF-IDF 得分
      └─ 按得分排序
```

---

## 11. 源码索引（doom-lsp 验证）

| 函数/结构 | 文件 | 行号 |
|-----------|------|------|
| `fts_cache_t` | `fts0types.h` 定义 | — |
| `fts_sync_t` | `fts0types.h` 定义 | — |
| `fts_optimize_t` struct | `fts0opt.cc` | 162 |
| `fts_tokenize_param_t` struct | `fts0fts.cc` | 179 |
| `fts_cache_destroy()` | `fts0fts.cc` | 244 |
| `fts_get_charset()` | `fts0fts.cc` | 270 |
| `fts_load_default_stopword()` | `fts0fts.cc` | 300 |
| `fts_cache_init()` | `fts0fts.cc` | 503 |
| `fts_cache_create()` | `fts0fts.cc` | 532 |
| `fts_add_index()` | `fts0fts.cc` | 585 |
| `fts_cache_index_cache_create()` | `fts0fts.cc` | 830 |
| `fts_cache_add_doc()` | `fts0fts.cc` | 1176 |
| `fts_cache_node_add_positions()` | `fts0fts.cc` | 1065 |
| `fts_cache_clear()` | `fts0fts.cc` | 925 |
| `fts_get_next_doc_id()` | `fts0fts.cc` | 2801 |
| `fts_add()` | `fts0fts.cc` | 3065 |
| `fts_delete()` | `fts0fts.cc` | 3085 |
| `fts_modify()` | `fts0fts.cc` | 3174 |
| `fts_commit()` | `fts0fts.cc` | 3290 |
| `fts_fetch_doc_from_rec()` | `fts0fts.cc` | 3425 |
| `fts_add_doc_by_id()` | `fts0fts.cc` | 3618 |
| `fts_write_node()` | `fts0fts.cc` | 4004 |
| `fts_sync_add_deleted_cache()` | `fts0fts.cc` | 4066 |
| `fts_sync_write_words()` | `fts0fts.cc` | 4121 |
| `fts_sync_begin()` | `fts0fts.cc` | 4232 |
| `fts_sync_index()` | `fts0fts.cc` | 4254 |
| `fts_sync_commit()` | `fts0fts.cc` | 4314 |
| `fts_sync()` | `fts0fts.cc` | 4420 |
| `fts_sync_table()` | `fts0fts.cc` | 4528 |
| `fts_check_token()` | `fts0fts.cc` | 4552 |
| `fts_add_token()` | `fts0fts.cc` | 4639 |
| `fts_process_token()` | `fts0fts.cc` | 4705 |
| `fts_tokenize_document_internal()` | `fts0fts.cc` | 4761 |
| `fts_tokenize_by_parser()` | `fts0fts.cc` | 4828 |
| `fts_tokenize_document()` | `fts0fts.cc` | 4855 |
| `fts_init_doc_id()` | `fts0fts.cc` | 4965 |
| `fts_get_doc_id_from_row()` | `fts0fts.cc` | 5231 |
| `fts_find_index_cache()` | `fts0fts.cc` | 5292 |
| `fts_cache_find_word()` | `fts0fts.cc` | 5304 |
| `fts_create()` | `fts0fts.cc` | 5505 |
| `fts_free()` | `fts0fts.cc` | 5520 |
| `fts_trx_add_op()` | `fts0fts.cc` | 2674 |
| `fts_trx_table_add_op()` | `fts0fts.cc` | 2626 |
| `fts_optimize_thread()` | `fts0opt.cc` | 2872 |
| `fts_optimize_init()` | `fts0opt.cc` | 3007 |
| `fts_optimize_shutdown()` | `fts0opt.cc` | 3024 |
| `fts_optimize_table()` | `fts0opt.cc` | 2391 |
| `fts_optimize_index()` | `fts0opt.cc` | 1857 |
| `fts_optimize_compact()` | `fts0opt.cc` | 1506 |
| `fts_optimize_write_word()` | `fts0opt.cc` | 1414 |
| `fts_index_fetch_words()` | `fts0opt.cc` | 804 |
| `fts_fetch_doc_ids()` | `fts0opt.cc` | 954 |
| `fts_optimize_purge_snapshot()` | `fts0opt.cc` | 2291 |
| `fts_optimize_create_deleted_doc_id_snapshot()` | `fts0opt.cc` | 2089 |
| `fts_optimize_add_table()` | `fts0opt.cc` | 2496 |
| `fts_optimize_remove_table()` | `fts0opt.cc` | 2541 |
