# 24. InnoDB 全文索引（Full-Text Search）— 源码分析

> 本文分析 InnoDB 全文索引的实现，包括 FTS 索引表结构、文档缓存、同步机制、分词（tokenization）、查询处理（natural language / boolean mode）和后台优化线程。核心源文件：`fts0fts.cc`、`fts0types.h`、`fts0fts.h`、`fts0tokenize.cc`。

---

## 0. 概述

InnoDB 的全文索引（FTS）是基于**倒排索引（Inverted Index）**的实现。不同于 MyISAM 的全文索引是在 SQL 层实现的，InnoDB FTS 是在**InnoDB 存储引擎层**实现的，与事务引擎紧密集成。

### FTS 的核心组件

```
FTS 辅助表（在表空间中创建）:
  ├── FTS_00000000000000xx_INDEX_N.ibd  (N=1..N: 分词索引表)
  ├── FTS_00000000000000xx_DELETED       (已删除文档的 DOC_ID)
  ├── FTS_00000000000000xx_DELETED_CACHE (已删除的缓存)
  ├── FTS_00000000000000xx_BEING_DELETED (正在删除中的)
  └── FTS_00000000000000xx_CONFIG        (配置表)

内存组件:
  ├── fts_cache_t (文档和分词缓存)
  ├── fts_doc_t (文档结构)
  └── fts_tokenizer_t (分词器接口)
```

### FTS 限制
- 仅支持 **InnoDB 表**，必须有一个 `DOC_ID` 列（可自动添加）
- 不支持分区表上的 FTS
- 不支持外键约束
- `FTS_DOC_ID` 列必须是 `BIGINT UNSIGNED NOT NULL UNIQUE`

---

## 1. 核心数据结构

### 1.1 FTS 辅助表结构

```sql
-- FTS 索引表结构（每行对应一个分词出现）
CREATE TABLE FTS_00000000000000xx_INDEX_1 (
  DOC_ID BIGINT UNSIGNED NOT NULL,    -- 文档 ID
  POSITION BIGINT UNSIGNED NOT NULL,   -- 分词在文档中的字符位置
  WORD VARCHAR(255) NOT NULL           -- 分词文本
);
-- 每个 FTS 索引由 6 个这样的分表组成（INDEX_1 到 INDEX_6）
```

6 个分表的原因：**并行优化**。DML 对 FTS 索引的修改被分散到不同的分表，减少锁争用。后台线程定期将 6 个分表合并为一个主索引。

### 1.2 FTS 缓存 — fts_cache_t

```cpp
// fts0types.h
struct fts_cache_t {
  /** 文档 ID 缓存（DOC_ID → 文档内容）*/
  hash_table_t *doc;   /* key=DOC_ID, value=fts_doc_t */

  /** 分词缓存（WORD → DOC_ID 列表）*/
  hash_table_t *word;  /* key=word_string, value=fts_word_t */

  /** 同步（flush）时的状态 */
  fts_sync_t *sync;

  /** 优化状态 */
  ulint optimize_state;

  /** 缓存大小控制 */
  ulint total_size;
  ulint max_size;
};
```

缓存减少了对 FTS 索引表的频繁写入：INSERT 操作先记录在缓存中，积累到一定阈值后才刷入索引表。

### 1.3 FTS 文档 — fts_doc_t

```cpp
// fts0types.h
struct fts_doc_t {
  doc_id_t doc_id;      /* 文档 ID */
  byte *text;           /* 文档文本（原始） */
  ulint text_len;       /* 文本长度 */

  /* 分词后的结果 */
  fts_tokenizer_word_t *tokens;  /* 分词数组 */
  ulint n_tokens;       /* 分词数量 */

  /* 同步状态 */
  ulint flush_state;
};
```

---

## 2. 分词（Tokenization）

### 2.1 分词器接口

```cpp
// fts0tokenize.cc
struct fts_tokenizer_word_t {
  const char *text;         /* 分词文本 */
  ulint text_len;           /* 分词长度 */
  ulint position;           /* 在文档中的字符位置 */
};

/* 默认分词器：基于字符集，按空格和标点分割 */
void fts_tokenize(fts_doc_t *doc, const CHARSET_INFO *cs) {
  /* 根据指定的字符集，逐字符扫描 */
  /* 遇到空格/标点 → 完成一个分词 */
  /* 对于 CJK: 使用 n-gram 分割（默认 2-gram）*/

  for (i = 0; i < doc->text_len; ) {
    /* 跳过空白 */
    if (my_isspace(cs, doc->text[i])) { i++; continue; }

    /* 找到分词起点 */
    start = i;
    while (!my_isspace(cs, doc->text[i]) && i < doc->text_len) {
      i++;
    }
    /* 保存分词 */
    tokens[n_tokens].text = start;
    tokens[n_tokens].text_len = i - start;
    tokens[n_tokens].position = start;
    n_tokens++;
  }
}
```

### 2.2 内置分词器

MySQL 内置三种分词器：

| 分词器 | 配置 | 适用场景 |
|--------|------|---------|
| `innodb_ft_min_token_size` (3) | 最小分词长度 | 英文 |
| `innodb_ft_max_token_size` (84) | 最大分词长度 | 英文 |
| `ngram_token_size` (2) | n-gram 大小 | CJK（中日韩） |

**ngram 分词示例**（token_size=2）：

```
输入: "数据库MySQL"
输出: "数据", "据库", "库M", "My", "yS", "SQ", "QL"
```

### 2.3 停用词

```cpp
// fts0fts.cc
const char **fts_default_stopword_table = {
  "a", "about", "an", "are", "as", "at", "be", "by",
  "com", "for", "from", "how", "in", "is", "it", "of",
  "on", "or", "that", "the", "this", "to", "was", "what",
  "when", "where", "who", "will", "with", "the", NULL
};

bool fts_is_stopword(const char *word, ulint len) {
  /* 检查分词是否在停用词表中 */
  for (const char **sw = fts_default_stopword_table; *sw; sw++) {
    if (strlen(*sw) == len && memcmp(*sw, word, len) == 0) {
      return true;
    }
  }
  return false;
}
```

---

## 3. 文档插入与同步

### 3.1 INSERT 时的 FTS 路径

```
INSERT INTO t (text) VALUES ('hello world')

  └─ row_ins_step()
      └─ row_ins_index_entry()           ← 插入聚簇索引
          └─ 聚簇索引写入成功
      └─ fts_insert()                    ← FTS 后处理
          ├─ fts_get_doc_id()            ← 获取/生成 DOC_ID
          ├─ fts_fetch_doc_from_rec()    ← 从记录中提取文档文本
          ├─ fts_tokenize_doc()          ← 分词
          ├─ fts_cache_doc()             ← 缓存文档到 fts_cache_t
          │   ├─ fts_cache_store_doc()   ← DOC_ID → doc 缓存
          │   └─ fts_cache_store_word()  ← WORD → positions 缓存
          └─ 如果缓存满了:
              └─ fts_sync()              ← 刷入 FTS 索引表
```

### 3.2 fts_sync() — 缓存刷入索引表

```cpp
// fts0fts.cc
dberr_t fts_sync(fts_table_t *fts_table) {
  fts_cache_t *cache = fts_table->cache;

  /* ──── 步骤 1：创建同步事务 ──── */
  trx_t *trx = trx_allocate_for_background();
  trx->op_info = "flushing FTS cache";

  /* ──── 步骤 2：对每个分词，更新索引表 ──── */
  for (word in cache->word) {
    for (doc_id in word->doc_ids) {
      /* 写入 INDEX_N 表 */
      /* row_ins_clust_index_entry(index_table, word, doc_id, pos) */
    }
  }

  /* ──── 步骤 3：清空缓存 ──── */
  mem_heap_empty(cache->heap);

  /* ──── 步骤 4：提交事务 ──── */
  trx_commit(trx);
  return DB_SUCCESS;
}
```

同步触发条件：

```
1. fts_cache_t::total_size >= fts_cache_t::max_size
   （max_size = innodb_ft_cache_size，默认 8MB）
2. 每次 DML 事务提交后，检查缓存使用率
3. 如果超过 80% → 触发同步
```

---

## 4. 查询处理

### 4.1 Natural Language Mode

```sql
SELECT * FROM t WHERE MATCH(text) AGAINST('hello' IN NATURAL LANGUAGE MODE)
```

```cpp
// fts0fts.cc — Natural Language 查询
dberr_t fts_query(fts_table_t *fts_table, fts_result_t *result,
                  const char *query, uint mode) {

  /* ──── 步骤 1：分词查询 ──── */
  fts_tokenize_query(query, &tokens);

  /* ──── 步骤 2：查找每个分词在索引表中的出现 ──── */
  for (token : tokens) {
    /* 打开 FTS INDEX 表 */
    /* btr_pcur_open(index_table, WORD=token, ...) */
    /* 收集所有匹配的 DOC_ID */
    while (匹配的行) {
      doc_ids.push_back(rec->DOC_ID);
      /* 计算相关性得分：tf (term frequency) */
      tf = count of this word in the document;
    }
  }

  /* ──── 步骤 3：计算相关性评分 ──── */
  for (doc_id : all_matched) {
    score = 0;
    for (word : query_words) {
      if (doc_id has word) {
        /* TF-IDF: tf * log(total_docs / df) */
        score += word_tf[doc_id] * log(N / word_df);
      }
    }
    result->add(doc_id, score);
  }

  /* ──── 步骤 4：按评分排序 ──── */
  sort(result->entries, by score DESC);

  return DB_SUCCESS;
}
```

### 4.2 Boolean Mode

```sql
SELECT * FROM t WHERE MATCH(text) AGAINST('+hello -world' IN BOOLEAN MODE)
```

操作符：

| 操作符 | 含义 | 示例 |
|--------|------|------|
| + | 必须包含 | `+apple` |
| - | 必须排除 | `-banana` |
| (无) | 可选，增加权重 | `apple` |
| ~ | 取消权重 | `~orange` |
| * | 通配符 | `app*` → apple, application |

Boolean Mode 的评分逻辑不同于 Natural Language：不计算 TF-IDF，而是基于操作符的组合得出布尔匹配结果。

### 4.3 通配符查询

```cpp
// fts0fts.cc — 通配符查询
/* 'app*' → 在 FTS 索引表中查找所有以 'app' 开头的分词 */
/* FTS 索引表按 WORD 排序 → 范围扫描 [app, apq) */
pcur = btr_pcur_open(index, WORD >= 'app', PAGE_CUR_GE);
while (rec->word < 'apq') {
  doc_ids.push_back(rec->DOC_ID);
}
```

---

## 5. 文档删除与优化

### 5.1 DELETE 处理

当从 FTS 表中删除行时，InnoDB 不会立即从索引表中删除分词记录，而是记录被删除的 DOC_ID：

```sql
DELETE FROM t WHERE id = 1
  └─ row_del_step()
      └─ 聚簇索引删除正常执行
      └─ fts_delete()
          └─ 将 DOC_ID 写入 FTS_DELETED 辅助表
          └─ 更新 FTS_DELETED_CACHE 缓存
```

延迟删除的设计理由：索引表中的分词分布在 6 个分表和一个主表中，立即删除需要在所有表中搜索，开销巨大。后台 `OPTIMIZE TABLE` 会在合并索引时一并清理已删除的分词。

### 5.2 OPTIMIZE TABLE 与 FTS 优化

```sql
OPTIMIZE TABLE t;
```

触发 FTS 索引重建：

```cpp
// fts0fts.cc — 优化
dberr_t fts_optimize(fts_table_t *fts_table) {
  /* ──── 步骤 1：合并 6 个 INDEX 分表到主索引 ──── */
  for (i = 1; i <= 6; i++) {
    fts_merge_index(fts_table, i);
  }

  /* ──── 步骤 2：清理已删除的 DOC_ID ──── */
  for (word in 主索引) {
    for (doc_id in word->doc_ids) {
      if (doc_id in FTS_DELETED) {
        /* 从索引中删除该分词对该文档的引用 */
        btr_cur_del(...);
      }
    }
  }

  /* ──── 步骤 3：清空 DELETED 表 ──── */
  TRUNCATE FTS_DELETED;
  return DB_SUCCESS;
}
```

### 5.3 后台 FTS 优化线程

InnoDB 的后台线程（`fts_optimize_thread()`）定期检查是否有 FTS 表需要优化，无需等待用户执行 `OPTIMIZE TABLE`：

```cpp
// fts0fts.cc
void fts_optimize_thread() {
  while (true) {
    Wait(fts_optimize_interval);  /* innodb_ft_num_word_optimize 控制 */
    for (每个有 FTS 索引的表) {
      if (FTS_DELETED 表中有记录) {
        fts_optimize(table);  /* 增量优化 */
      }
    }
  }
}
```

---

## 6. 源码索引

| 函数/结构 | 文件 | 关键作用 |
|-----------|------|---------|
| `fts_cache_t` | `fts0types.h` | FTS 缓存管理 |
| `fts_doc_t` | `fts0types.h` | 文档结构 |
| `fts_tokenizer_word_t` | `fts0tokenize.cc` | 分词条目 |
| `fts_tokenize()` | `fts0tokenize.cc` | 文本分词 |
| `fts_is_stopword()` | `fts0fts.cc` | 停用词检查 |
| `fts_insert()` | `fts0fts.cc` | INSERT 的 FTS 后处理 |
| `fts_sync()` | `fts0fts.cc` | 缓存刷入索引表 |
| `fts_query()` | `fts0fts.cc` | FTS 查询 |
| `fts_optimize()` | `fts0fts.cc` | FTS 索引优化 |
| `fts_optimize_thread()` | `fts0fts.cc` | 后台优化线程 |
| `fts_delete()` | `fts0fts.cc` | DELETE 处理 |
