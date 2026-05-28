# 24. InnoDB 全文索引 (Full-Text Search)

> 本文分析 InnoDB 全文索引的实现，包括 FTS 缓存、文档同步、分词检查、查询处理和后台线程。核心文件：`fts0fts.cc`、`fts0types.h`、`fts0fts.h`。

---

## 1. 概述

InnoDB 全文索引（FTS）基于**倒排索引 (Inverted Index)** 实现。每个 FTS 索引由一组辅助表（`FTS_INDEX_TABLE`、`FTS_DOC_IDS`、`FTS_CONFIG` 等）存储倒排列表。DML 操作先将变更缓存在内存 `fts_cache_t` 中，达到阈值后通过后台线程同步到磁盘。

| 组件 | 定义 | 职责 |
|------|------|------|
| `fts_t` | `fts0fts.h:364` | 表的 FTS 控制结构 |
| `fts_cache_t` | `fts0types.h:147` | FTS 内存缓存（倒排列表缓冲） |
| `fts_node_t` | `fts0types.h:227` | 单个倒排列表节点 |
| `fts_sync_table()` | `fts0fts.cc:4528` | 缓存同步到磁盘 |
| `fts_check_token()` | `fts0fts.cc:4588` | 分词有效性检查 |

---

## 2. 核心数据结构

### 2.1 表级 FTS 控制 `fts_t`

```cpp
// fts0fts.h:364
class fts_t {
  ib_mutex_t bg_threads_mutex;   // 后台线程互斥锁
  ulint bg_threads;              // 后台线程数
  ulint fts_status;              // FTS 运行状态

  ib_wqueue_t *add_wq;           // "Add" 后台线程的工作队列
  fts_cache_t *cache;            // FTS 内存缓存
  ulint doc_col;                 // FTS_DOC_ID 在聚簇索引中的隐藏列位置
  ib_vector_t *indexes;          // FTS 索引向量
};
```

### 2.2 FTS 缓存 `fts_cache_t`

```cpp
// fts0types.h:147
struct fts_cache_t {
  rw_lock_t lock;                 // 保护缓存的锁
  ib_mutex_t optimize_lock;       // OPTIMIZE TABLE 的锁

  ib_vector_t *deleted_doc_ids;   // 已删除文档 ID 数组
  ib_vector_t *indexes;           // FTS 索引缓存（fts_index_cache_t）

  ulint total_size;               // 缓存中倒排列表总大小（触发 SYNC 的阈值）
  uint64_t total_size_before_sync;// 上次 SYNC 时的大小

  fts_sync_t *sync;               // 同步状态结构
  doc_id_t next_doc_id;           // 下一个文档 ID
  doc_id_t synced_doc_id;         // 已同步到 CONFIG 表的 doc_id

  ulint deleted;                  // 上次 OPTIMIZE 后的删除文档数
  ulint added;                    // 上次 OPTIMIZE 后的新增文档数
};
```

### 2.3 倒排列表节点 `fts_node_t`

```cpp
// fts0types.h:227
struct fts_node_t {
  doc_id_t first_doc_id;          // 列表中第一个文档 ID
  doc_id_t last_doc_id;           // 列表中最后一个文档 ID
  byte *ilist;                    // 倒排列表（二进制：文档ID + 词位置）
};
```

---

## 3. FTS 辅助表

每个 FTS 索引对应一组辅助表：

| 表名 | 用途 |
|------|------|
| `FTS_INDEX_TABLE` | 倒排索引表（word → doc_id + position） |
| `FTS_DOC_IDS` | 文档 ID 映射表 |
| `FTS_CONFIG` | 配置信息（next_doc_id 等） |
| `FTS_DELETED` | 已删除文档 ID |
| `FTS_BEING_DELETED` | 正在删除的文档 ID |

---

## 4. 数据处理流程

### 4.1 INSERT 路径

```
INSERT → 聚簇索引写入
  └─ fts_add_doc()              # 将文档加入缓存
      ├─ 隐藏列 FTS_DOC_ID 自增（通过 fts_set_next_doc_id）
      ├─ 分词（parser）
      ├─ 构建倒排列表存入 fts_cache_t
      └─ 如果 total_size > 阈值，触发 SYNC
```

### 4.2 SYNCHRONIZE 路径

```cpp
// fts0fts.cc:4528
dberr_t fts_sync_table(dict_table_t *table, bool unlock_cache,
                       bool wait, bool has_dict) {
  if (table->fts && table->fts->cache &&
      !table->is_corrupted()) {
    return fts_sync(table->fts->cache->sync,
                    unlock_cache, wait, has_dict);
  }
  return DB_SUCCESS;
}
```

SYNC 进程：
1. 锁定缓存
2. 将缓存中的倒排列表合并写入 `FTS_INDEX_TABLE` 辅助表
3. 更新 `FTS_CONFIG` 中的 `synced_doc_id`
4. 释放缓存空间

### 4.3 分词检查

```cpp
// fts0fts.cc:4588
bool fts_check_token(const fts_string_t *token,
                     const ib_rbt_t *stopwords,
                     bool is_ngram, const CHARSET_INFO *cs) {
  if (!is_ngram) {
    // 非 ngram：检查字符数范围和停用词
    if (token->f_n_char < fts_min_token_size ||
        token->f_n_char > fts_max_token_size ||
        (stopwords && rbt_search(stopwords, &parent, token) == 0)) {
      return false;
    }
  }
  // ngram 分词器：检查子词是否包含停用词
  for (ulint ngram_token_size = 1; ngram_token_size <= token->f_n_char;
       ngram_token_size++) {
    // 逐 token 检查停用词
  }
}
```

---

## 5. Synced Doc ID 管理

崩溃恢复时，从 `FTS_CONFIG` 辅助表读取 `synced_doc_id`，回放 redo log 中该值之后的变更。`fts_cache_t` 中的 `next_doc_id` 确保新分配的 ID 不会与已同步的 ID 冲突。

---

## 6. 查询处理

```
MATCH ... AGAINST('...' IN BOOLEAN MODE)
  └─ fts_query()
      ├─ 解析查询表达式（布尔模式 + - * ~ @distance）
      ├─ 在 FTS_INDEX_TABLE 中查找匹配的 word
      ├─ 合并倒排列表（AND/OR/NOT）
      ├─ 计算相关性评分（TF-IDF 方案）
      │    ├─ term frequency (TF)：词在文档中出现次数
      │    ├─ inverse document frequency (IDF)：log(N/df)
      │    └─ score = TF × IDF × normalization
      └─ 返回匹配结果集（fts_result_cache_limit 限制）
```

---

## 7. 后台线程与同步阈值

```cpp
// fts0fts.h:364 — fts_t
ib_wqueue_t *add_wq;    // "Add" 线程的工作队列
```

| 阈值变量 | 默认值 | 说明 |
|----------|--------|------|
| `fts_max_cache_size` | 32MB | 单个表 FTS 缓存最大值 |
| `fts_max_total_cache_size` | -1（无限制） | 所有表 FTS 缓存总大小 |
| `fts_result_cache_limit` | 2000 | FTS 查询返回的最大行数 |

---

## 8. 分词器

| 分词器 | 配置 | 适用场景 |
|--------|------|----------|
| Default | `innodb_ft_min_token_size=3` | 英文等空格分隔语言 |
| ngram | `ngram_token_size=2` | 中日韩无分隔符语言 |

---

## 9. 总结

1. **缓存 + 批量写入**：DML 变更先入 `fts_cache_t`，达到阈值后批量同步到磁盘辅助表。
2. **后台线程异步处理**：`add_wq` 工作队列 + 后台线程隔离 DML 与索引写入。
3. **分词过滤**：`fts_check_token` 过滤停用词和超出长度的 Token。
4. **ngram 分词器**：支持中日韩无分隔符语言的全文索引。
5. **TF-IDF 评分**：`fts_query` 计算相关性，`fts_result_cache_limit` 限制结果行数。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `fts0fts.h` | 364 | `class fts_t` 定义 |
| `fts0types.h` | 147 | `struct fts_cache_t` 定义 |
| `fts0types.h` | 227 | `struct fts_node_t` 定义 |
| `fts0fts.cc` | 4528 | `fts_sync_table()` |
| `fts0fts.cc` | 4588 | `fts_check_token()` |
