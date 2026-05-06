# 09-mysql-sql-layer — MySQL SQL 层：解析、优化、执行

> 基于 **MySQL 8.4 Innovation** 主线源码 (`~/code/mysql/sql/`)
> 全部代码块来自实际源码，附带 `file.cc:line` 行号标注
> 分析日期：2026-05-06

---

## 0. 概述

SQL 层是 MySQL 中连接**用户查询**与**存储引擎**的中间桥梁。它位于网络协议层之下、存储引擎 API 之上，承担三大职责：

1. **解析** — 将 SQL 文本转化为抽象语法树（Parse Tree）
2. **优化** — 从多种执行路径中选择代价最低的计划
3. **执行** — 按计划逐行扫描、连接、过滤、聚合

一条 SQL 的完整生命周期：

```
Client → do_command() → dispatch_command()
         → dispatch_sql_command()
           → parse_sql()       [词法分析 + 语法分析]
           → mysql_execute_command()
             → Sql_cmd::execute()
               → JOIN::optimize() [优化]
               → JOIN::exec()     [执行]
                 → handler::ha_*() [存储引擎接口]
```

### 0.1 SQL 层 vs 存储引擎层

| 层次 | 职责 | 关键文件 |
|------|------|----------|
| SQL 层 | 解析、权限检查、优化、执行计划、结果集处理 | `sql/*.cc` |
| 存储引擎层 | 数据页管理、索引遍历、事务、锁、恢复 | `storage/innobase/` |

SQL 层通过 `handler` 类与 `handlerton` 注册机制调用存储引擎，并不直接操作数据页。

### 0.2 THD — 贯穿所有阶段的上下文

`THD`（Thread Handle）是 SQL 层的**线程级会话对象**。从连接建立到断开，所有语句的执行状态、诊断信息、内存分配都在 THD 中。

---

## 1. 核心数据结构

### 1.1 THD — 每线程的会话上下文

整个 SQL 层的"大管家"。每个客户端连接对应一个 `THD` 实例，它既是 `Query_arena`（提供内存分配），又是 `Open_tables_state`（管理打开的表）。

```c
// sql/sql_class.h:953
class THD : public MDL_context_owner,
            public Query_arena,
            public Open_tables_state {
 public:
  Thd_mem_cnt m_mem_cnt;    // 受控内存统计 (首个成员)

 private:
  // 预防意外调用
  bool is_stmt_prepare() const = delete;

 public:
  MDL_context mdl_context;   // 元数据锁上下文

  // 标记列使用类型：读集/写集
  enum enum_mark_columns mark_used_columns;

  std::unique_ptr<LEX> main_lex;  // 非预处理语句的词法分析结果
  LEX *lex;                        // 当前解析树描述符

  dd::cache::Dictionary_client *dd_client() const;

 private:
  LEX_CSTRING m_query_string;  // 原始查询字符串
  String m_normalized_query;

 public:
  // 内存管理继承自 Query_arena
  MEM_ROOT main_mem_root;      // (sql_class.h:4499)
  MEM_ROOT *mem_root;          // 当前语句级内存分配器

  // 打开的表状态
  Table_ref *table_open;       // 当前语句涉及的表

  // 查询执行状态
  void *ha_data[2];            // 存储引擎关联数据 (通过 handlerton slot 索引)

  // 语句计时
  ulonglong start_time;        // 语句开始时间
};
```

THD 的 `mem_root` 提供**生命周期内存分配**——解析/优化/执行阶段分配的对象在语句结束时统一释放，无需逐对象 free。

```c
// sql/sql_class.h:426
void *alloc(size_t size) { return mem_root->Alloc(size); }
```

### 1.2 handlerton — 存储引擎注册接口

每个存储引擎通过一个 `handlerton` 向 SQL 层注册自己的回调函数。`handlerton` 是一个巨大的函数指针表。

```c
// sql/handler.h:113 (forward declaration)
struct handlerton;

// sql/handler.h:2856
struct handlerton {
  SHOW_COMP_OPTION state;        // 引擎可用性标记
  enum legacy_db_type db_type;   // 引擎编号
  uint slot;                      // THD::ha_data[] 中的索引

  // —— 事务回调 ——
  close_connection_t close_connection;
  kill_connection_t kill_connection;
  savepoint_set_t savepoint_set;
  savepoint_rollback_t savepoint_rollback;
  savepoint_release_t savepoint_release;
  commit_t commit;               // 提交事务
  rollback_t rollback;           // 回滚事务
  prepare_t prepare;             // XA 两阶段提交之 prepare

  // —— DDL 回调 ——
  create_t create;               // 建表
  drop_database_t drop_database;
  panic_t panic;                 // 紧急关机
  start_consistent_snapshot_t start_consistent_snapshot;
  flush_logs_t flush_logs;

  // —— 数据字典 ——
  dict_init_t dict_init;
  dict_recover_t dict_recover;

  // —— 统计信息 ——
  get_table_statistics_t get_table_statistics;
  get_column_statistics_t get_column_statistics;
  get_index_column_cardinality_t get_index_column_cardinality;

  // —— 备份/克隆 ——
  Clone_interface_t clone_interface;

  // —— 查询下推 ——
  prepare_secondary_engine_t prepare_secondary_engine;
  optimize_secondary_engine_t optimize_secondary_engine;

  uint32 flags{0};                // 全局 handler 标志
  uint32 license;                 // 引擎许可类型
  void *data;                     // 引擎私有数据
};
```

InnoDB 引擎在 `ha_innodb_init()` 中填充此结构并注册：

```c
// storage/innobase/handler/ha_innodb.cc:5401
static int ha_innodb_init(void *p) {
  handlerton *innobase_hton = (handlerton *)p;
  innobase_hton->state = SHOW_OPTION_YES;
  innobase_hton->db_type = DB_TYPE_INNODB;
  innobase_hton->slot = slot;
  innobase_hton->commit = innobase_commit;
  innobase_hton->rollback = innobase_rollback;
  innobase_hton->prepare = innobase_prepare;
  innobase_hton->create = innobase_create;
  // ... 更多回调赋值
}
```

### 1.3 JOIN — 查询执行计划

`JOIN` 类是整个查询优化和执行的**核心数据结构**，代表了一个 `SELECT` 语句的完整执行计划。

```c
// sql/sql_select.h:310 (forward declaration)
class JOIN;

// sql/sql_select.h:101 (POSITION 结构——连接顺序中的一个位置)
struct POSITION {
  double rows_fetched;       // 每次读取的行数
  double read_cost;          // 读取成本
  float filter_effect;       // 条件下推过滤效果 (0..1)
  double prefix_rowcount;    // 前缀行数
  double prefix_cost;        // 前缀成本
  JOIN_TAB *table;           // 该位置对应的表
  Key_use *key;              // 使用的索引 (ref access)
  table_map ref_depend_map;  // ref 依赖的表位图
  uint sj_strategy;          // 半连接策略
  uint n_sj_tables;          // 半连接涉及的表数
};
```

`JOIN` 类的关键成员包括：

- `join->positions[]` — 优化过程中的中间连接顺序
- `join->best_positions[]` — 当前最优连接顺序
- `join->best_read` — 最优计划的预估成本
- `join->best_ref` — 表的引用排序

### 1.4 Item — 表达式树基类

SQL 表达式（WHERE 子句、SELECT 列表、函数调用）都以 `Item` 类的派生对象表示，组织成**表达式树**。

```c
// sql/item.h:928
class Item : public Parse_tree_node {
 public:
  enum Type {
    INVALID_ITEM,
    FIELD_ITEM,          // 列引用
    FUNC_ITEM,           // 函数调用
    SUM_FUNC_ITEM,       // 聚合函数 / 窗口函数
    STRING_ITEM,         // 字符串字面量
    INT_ITEM,            // 整数常量
    DECIMAL_ITEM,        // 十进制常量
    REAL_ITEM,           // 浮点常量
    NULL_ITEM,           // NULL 值
    COND_ITEM,           // AND/OR 条件
    REF_ITEM,            // 间接引用
    SUBQUERY_ITEM,       // 子查询
    ROW_ITEM,            // 行构造器
    CACHE_ITEM,          // 内部缓存
    PARAM_ITEM,          // 预处理语句参数
    // ... 更多类型
  };

  enum cond_result { COND_UNDEF, COND_OK, COND_TRUE, COND_FALSE };

  // 所有 Item 分配在 MEM_ROOT 上
  static void *operator new(size_t size) noexcept {
    return (*THR_MALLOC)->Alloc(size);
  }

 protected:
  String str_value;              // 字符串结果缓冲区
  DTCollation collation;         // 字符集与排序规则

  // 字段：列引用使用
  Field *field;                  // （仅 FIELD_ITEM 有效）
  table_map used_tables_map;     // 引用表的位图
  table_map not_null_tables;     // 非空约束表的位图

  // **多态估值方法**：
  virtual bool fix_fields(THD *thd, Item **ref);    // 类型推导 & 表绑定
  virtual enum Item_result result_type() const;       // 结果类型

  // 运行时取值
  virtual double val_real();                          // 取浮点值
  virtual longlong val_int();                         // 取整数值
  virtual String *val_str(String *);                  // 取字符串值
  virtual bool val_bool();                            // 取布尔值
  virtual bool is_null();                             // 判空

  // 条件优化
  virtual Item *propagate_equal_fields(THD *thd,
                                        const Context &ctx,
                                        const Equal_set *);
  virtual Item *compile(Item_analyzer analyzer,
                        uchar **arg_p,
                        Item_transformer transformer,
                        uchar *arg_t);
};
```

`Item` 体系有超过 200 个派生类。例如 `Item_field` 代表表列，`Item_func_add` 代表加法操作，`Item_cond_and` 代表 AND 条件。

### 1.5 MEM_ROOT — 生命周期内存分配

MEM_ROOT 是 MySQL SQL 层的"垃圾回收"机制。所有解析树节点、优化器结构都分配在 `MEM_ROOT` 上，语句结束时一次性释放。

```c
// sql/sql_class.h:361
MEM_ROOT *mem_root;  // 指向当前 MEM_ROOT

// sql/sql_class.h:426-443
void *alloc(size_t size) { return mem_root->Alloc(size); }
void *calloc(size_t size) {
  if ((ptr = mem_root->Alloc(size))) memset(ptr, 0, size);
}
char *mem_strdup(const char *str) { return strdup_root(mem_root, str); }
char *mem_strndup(const char *str, size_t size) {
  return strmake_root(mem_root, str, size);
}

// sql/sql_class.h:4499
MEM_ROOT main_mem_root;
```

THD 继承自 `Query_arena`（`sql/sql_class.h:397`），有两种状态：

- `STMT_INITIALIZED` — 分配在语句级 MEM_ROOT 上，语句结束后释放
- `STMT_PREPARED` — 分配在长期 MEM_ROOT 上，跨语句保持（Prepare 语句）

---

## 2. SQL 解析

### 2.1 do_command — 命令读取入口

每个客户端连接的主循环在 `do_command()` 中读取网络包并分发：

```c
// sql/sql_parse.cc:1347
bool do_command(THD *thd) {
  enum enum_server_command command = COM_SLEEP;
  COM_DATA com_data;

  // 读取网络包，阻塞等待
  thd->m_server_idle = true;
  rc = thd->get_protocol()->get_command(&com_data, &command);
  thd->m_server_idle = false;

  // 分发到对应的命令处理器
  return_value = dispatch_command(thd, &com_data, command);
  // ...
}
```

### 2.2 dispatch_command — 命令分发

对所有 MySQL 协议命令（COM_QUERY, COM_STMT_PREPARE, COM_QUIT 等）进行分发。

```c
// sql/sql_parse.cc:1752
bool dispatch_command(THD *thd, const COM_DATA *com_data,
                      enum enum_server_command command) {
  // 重置 kill 标记
  if (thd->killed == THD::KILL_QUERY) thd->killed = THD::NOT_KILLED;

  thd->set_command(command);
  thd->set_time();
  thd->set_query_id(next_query_id());

  switch (command) {
    case COM_QUIT: // ...
    case COM_QUERY:
      // 对于 SQL 查询文本，调用 dispatch_sql_command()
      dispatch_sql_command(thd, &parser_state);
      break;
    case COM_STMT_PREPARE: // ...
    // ...
  }
}
```

### 2.3 dispatch_sql_command — SQL 解析 + 执行调度

```c
// sql/sql_parse.cc:5299
void dispatch_sql_command(THD *thd, Parser_state *parser_state,
                          bool is_retry) {
  mysql_reset_thd_for_next_command(thd);
  lex_start(thd);
  thd->m_parser_state = parser_state;

  // === 1. 解析 ===
  bool err = parse_sql(thd, parser_state, nullptr);
  if (!err) err = invoke_post_parse_rewrite_plugins(thd, false);

  if (!err) {
    // === 2. 重写 SQL（密码脱敏等）===
    mysql_rewrite_query(thd);

    // === 3. 执行 ===
    int error = mysql_execute_command(thd, true);
  }
}
```

### 2.4 词法分析 — sql_lex.cc

MySQL 的词法分析器将 SQL 文本切分成 token 流。核心是 `MYSQLlex()` 函数（Bison 调用），而实际的 token 处理在 `sql_lex.cc` 中。

```c
// sql/sql_lex.cc:988
static LEX_STRING get_token(Lex_input_stream *lip, uint skip, uint length) {
  LEX_STRING tmp;
  lip->yyUnget();  // ptr now points after last token char
  tmp.length = lip->yytoklen = length;
  tmp.str = lip->m_thd->strmake(lip->get_tok_start() + skip, tmp.length);
  lip->m_cpp_text_start = lip->get_cpp_tok_start() + skip;
  lip->m_cpp_text_end = lip->m_cpp_text_start + tmp.length;
  return tmp;
}
```

词法分析器的状态机位于 `Lex_input_stream` 中（`sql/sql_lex.h`）：

```c
// sql/sql_lex.h:3710 (注释)
/// of the lexer: MYSQLlex(). However, some complex ("hintable") tokens break
```

`Lex_input_stream` 维护当前解析位置、token 长度、字符集信息等。关键字匹配使用**完美哈希**（`Lex_hash`）：

```c
// sql/sql_lex.cc:979
bool is_lex_native_function(const LEX_STRING *name) {
  return Lex_hash::sql_keywords_and_funcs.get_hash_symbol(
             name->str, (uint)name->length) != nullptr;
}
```

### 2.5 语法分析 — sql_yacc.yy

Bison 语法规则将 token 流转换为解析树节点（Parse Tree Node）。`sql_yacc.yy` 是 MySQL 最大的源文件（~19K 行）。

```c
// sql/sql_yacc.yy:1 (文件头)
/* sql_yacc.yy */
/**
  @defgroup Parser Parser
  @{
*/

%{
// Bison 的 prologue: 包含所有必要的头文件
#include "sql/item.h"
#include "sql/item_func.h"
#include "sql/item_cmpfunc.h"
#include "sql/handler.h"
// ...
%}
```

SELECT 语句的语法规则：

```c
// sql/sql_yacc.yy:9942
select_stmt:
          query_expression
          {
            $$ = NEW_PTN PT_select_stmt(@$, $1);
          }
        | query_expression locking_clause_list
          {
            $$ = NEW_PTN PT_select_stmt(@$, NEW_PTN PT_locking(@$, $1, $2),
                                        nullptr, true);
          }
        | select_stmt_with_into
        ;

query_expression:
          query_expression_body
        // ...
        ;

// sql/sql_yacc.yy:10123
query_specification:
          SELECT
          // ...
          {
            // 构造 SELECT_LEX (解析后存入 Lex)
            LEX *lex = YYTHD->lex;
            // ...
          }
        ;
```

解析完成后，结果存入 `THD->lex`（`LEX` 结构），其中包含 `SELECT_LEX`、`TABLE_LIST`、Item 表达式树等：

```
    MYSQLparse()
         │
         ▼
    Lex (THD->lex)
         │
         ├── query_block → SELECT_LEX
         │     ├── leaf_tables → Table_ref 链表
         │     ├── item_list → SELECT 列 (Item* 链表)
         │     ├── where_cond → WHERE 条件 (Item* 树)
         │     ├── group_list → GROUP BY (ORDER 链表)
         │     └── order_list → ORDER BY
         │
         └── query_expression → Query_expression
```

### 2.6 mysql_execute_command — 命令执行入口

解析完成后，`mysql_execute_command()` 根据 `sql_command` 类型分发到对应的执行器：

```c
// sql/sql_parse.cc:3018
int mysql_execute_command(THD *thd, bool first_level) {
  LEX *const lex = thd->lex;
  Query_block *const query_block = lex->query_block;

  // 权限检查、上下文设置...

  // 根据 SQL 命令类型分发
  switch (lex->sql_command) {
    case SQLCOM_SELECT:
    {
      Sql_cmd_select *cmd = static_cast<Sql_cmd_select *>(lex->m_sql_cmd);
      // prepare → optimize → execute
      res = cmd->execute(thd);  // 其中调用 JOIN::optimize() + JOIN::exec()
      break;
    }
    case SQLCOM_INSERT:
    case SQLCOM_UPDATE:
    case SQLCOM_DELETE:
      // ...
  }
}
```

---

## 3. 查询优化（Optimizer）

优化器的目标是：给定一个查询，生成**执行成本最低**的执行计划。

### 3.1 JOIN::optimize() — 优化主入口

```c
// sql/sql_optimizer.cc:344
bool JOIN::optimize(bool finalize_access_paths) {
  DBUG_TRACE;

  // 防止 EXPLAIN 时的双重优化
  if (optimized) return false;

  THD_STAGE_INFO(thd, stage_optimizing);

  count_field_types(query_block, &tmp_table_param, *fields, false, false);

  // === 常量折叠与条件优化 ===
  if (where_cond || query_block->outer_join) {
    if (optimize_cond(thd, &where_cond, &cond_equal,
                      &query_block->m_table_nest,
                      &query_block->cond_value)) {
      return true;
    }
    // 如果 WHERE 恒为假
    if (query_block->cond_value == Item::COND_FALSE) {
      zero_result_cause = "Impossible WHERE";
      set_root_access_path(create_access_paths_for_zero_rows());
      goto setup_subq_exit;
    }
  }

  // === 分区裁剪 ===
  if (query_block->partitioned_table_count && prune_table_partitions()) {
    return true;
  }

  // === 常量聚合优化：COUNT(*)/MIN()/MAX() 直接求值 ===
  if (tables_list && implicit_grouping &&
      !(query_block->active_options() & OPTION_NO_CONST_TABLES)) {
    optimize_aggregated_query(thd, query_block, *fields, where_cond,
                              &outcome);
  }

  // === 为子查询创建临时表 ===
  // (设置临时表的分组/排序参数)

  // === 计算扫描方法可能性 (best_access_path) ===
  // 对每个表评估：全表扫描 vs 索引扫描 vs ref access

  // === 连接顺序搜索 (greedy_search) ===
  // ...

  // === 生成最终的 AccessPath 树 ===
  create_access_paths();

  set_optimized();
  return false;
}
```

### 3.2 表访问路径选择

`JOIN::optimize()` 中会调用 `Optimize_table_order` 来为每张表选择最佳访问路径。

```c
// sql/sql_planner.cc:2330
bool Optimize_table_order::greedy_search(table_map remaining_tables) {
  // 贪心算法搜索连接顺序
  do {
    join->best_read = DBL_MAX;
    if (best_extension_by_limited_search(
            remaining_tables, idx, search_depth))
      return true;

    // 将最优表加入计划
    best_idx = join->best_positions[idx].table->idx();
    remaining_tables ^= best_idx;
    idx++;

  } while (remaining_tables != 0);
  return false;
}
```

完整的执行流程（`sql/sql_planner.cc:2264` 注释）：

```
procedure greedy_search
input: remaining_tables
output: pplan;
{
  pplan = <>;
  do {
    (t, a) = best_extension(pplan, remaining_tables);
    pplan = concat(pplan, (t, a));
    remaining_tables = remaining_tables - t;
  } while (remaining_tables != {})
  return pplan;
}
```

### 3.3 索引选择 — find_best_ref()

对于每个表，评估所有可用索引的 ref access 成本：

```c
// sql/sql_planner.cc:208
Key_use *Optimize_table_order::find_best_ref(
    const JOIN_TAB *tab, const table_map remaining_tables,
    const uint idx, const double prefix_rowcount,
    bool *found_condition, table_map *ref_depend_map,
    uint *used_key_parts) {

  // 遍历该表的所有可用 Key_use
  for (Key_use *keyuse = tab->keyuse();
       keyuse->table_ref == tab->table_ref;) {

    // 检查每个 keypart 的可用性
    // 条件：
    //   1) 不能包含外部半连接/物化子查询的表
    //   2) 依赖的表必须在当前前缀中
    //   3) 不能有两个 ref_or_null keypart
    if ((excluded_tables & keyuse->used_tables) ||
        (remaining_tables & keyuse->used_tables)) {
      ++keyuse; continue;
    }

    // 计算 ref access 的成本和扇出
    // cur_read_cost = cost_ref_for_one_value * prefix_rowcount
    // cur_fanout = 估计行数 / 每个键值的匹配行数

    // 保存最优结果
    if (cur_read_cost < best_ref_cost) {
      best_ref = start_key;
      best_ref_cost = cur_read_cost;
    }
  }
  return best_ref;
}
```

### 3.4 排序优化 — get_index_for_order()

当 `ORDER BY` 子句可以完全由索引满足时，MySQL 避免文件排序（filesort）。

```c
// sql/sql_select.cc:5450
uint get_index_for_order(ORDER_with_src *order, TABLE *table,
                         ha_rows limit, bool need_ordered_result,
                         bool no_const_tables) {
  // 检查 ORDER BY 的列是否能被某个索引覆盖
  // 需要满足：
  //   - 排序方向一致
  //   - 索引前缀与 ORDER BY 列匹配
  //   - 没有无法满足的间隙

  for (uint idx = 0; idx < table->s->keys; idx++) {
    // 检查第 idx 个索引
    if (!(table->key_info[idx].flags & (HA_ORDER_NULLS_LAST))) continue;

    ORDER *order_ptr = order;
    uint key_part = 0;

    // 验证 ORDER BY 的每一列是否匹配索引的对应 keypart
    for (; order_ptr;
         order_ptr = order_ptr->next, key_part++) {
      if (!table->key_info[idx].key_part[key_part].field->eq(
              order_ptr->item->field_for_order_by())) {
        break;  // 不匹配
      }
    }

    if (order_ptr == nullptr) {
      return idx;  // 找到完全匹配的索引
    }
  }
  return MAX_KEY;  // 没有找到，回退到 filesort
}
```

### 3.5 子查询优化

MySQL 支持多种子查询优化策略，包括：

1. **IN → EXISTS 转换** — 将 `IN (subquery)` 转换为 `EXISTS (subquery)`
2. **物化（Materialization）** — 将子查询结果缓存到临时表
3. **半连接（Semi-join）** — 将 `IN` 子查询展开为半连接

```c
// sql/sql_optimizer.cc:192 (常量聚合优化)
static bool optimize_aggregated_query(
    THD *thd, Query_block *query_block,
    const mem_root_deque<Item *> &fields,
    Item *where_cond,
    aggregate_evaluated *outcome) {

  switch (*outcome) {
    case AGGR_REGULAR:
      // 正常优化，不特殊处理
      break;
    case AGGR_DELAYED:
      // 存储引擎支持 HA_COUNT_ROWS_INSTANT
      select_count = true;
      break;
    case AGGR_COMPLETE:
      // 所有 SELECT 表达式已完全求值，跳过表扫描
      zero_result_cause = "Select tables optimized away";
      tables_list = nullptr;
      best_rowcount = 1;
      break;
    case AGGR_EMPTY:
      // 检测到结果表为空
      zero_result_cause = "No matching min/max row";
      set_root_access_path(create_access_paths_for_zero_rows());
      break;
  }
}
```

---

## 4. 查询执行（Executor）

### 4.1 执行入口

优化完成后，执行器按 `AccessPath` 树逐层执行。执行入口在 `sql_executor.cc` 和 `sql_select.cc` 中。

`JOIN::exec()` 调用 `evaluate_join_record()` 来逐行计算连接结果。实际上执行是通过迭代 `AccessPath` 树来完成的：

```c
// sql/sql_executor.cc:3126
void JOIN::create_access_paths() {
  // 从优化结果生成 AccessPath 树
  // 每个表的访问路径（全表扫描/索引扫描/ref access）
  // 组合成嵌套循环连接或哈希连接

  AccessPath *root = nullptr;

  for (uint i = 0; i < tables; i++) {
    JOIN_TAB *tab = join_tab + i;
    AccessPath *path = nullptr;

    if (tab->range_scan()) {
      path = CreateRangeScanAccessPath(thd, tab);
    } else if (tab->ref()) {
      path = CreateRefAccessAccessPath(thd, tab);
    } else {
      path = CreateTableScanAccessPath(thd, tab);
    }

    // 将路径挂载到嵌套循环
    root = CreateNestedLoopAccessPath(thd, prev_tab, path);
  }

  set_root_access_path(root);
}
```

### 4.2 嵌套循环连接（Nested Loop Join）

MySQL 最基础的连接算法是嵌套循环连接。对于两个表 `t1 JOIN t2`：

```
for each row in t1:
    for each row in t2 (matching t1):
        output row
```

在内核中表现为 `sub_select()` / `join_read_next()` / `join_read_record()` 的循环调用链：

```c
// sql/sql_executor.cc:3678
int join_read_const_table(JOIN_TAB *tab, POSITION *pos) {
  // 读取常量表（const table）的单行数据
  // 从 handler 中读取
  TABLE *table = tab->table();

  if (tab->ref()) {
    // 使用索引查找
    int error = table->file->ha_index_read_map(
        table->record[0],
        tab->ref()->key_buff,
        make_keypart_map(tab->ref()->key_parts),
        HA_READ_KEY_EXACT);
    return error;
  }

  // 使用全表扫描只读一行
  int error = table->file->ha_rnd_next(table->record[0]);
  return error;
}
```

### 4.3 快速路径：单表索引扫描

当查询只涉及单表且 `WHERE` 条件匹配索引时，MySQL 直接使用索引进行扫描：

```c
// sql/sql_executor.cc:3809
int read_const(TABLE *table, Index_lookup *ref) {
  // 使用常数键值在索引中查找
  int error = table->file->ha_index_read_map(
      table->record[0],
      ref->key_buff,
      make_keypart_map(ref->key_parts),
      HA_READ_KEY_EXACT);
  return error;
}
```

对于 `WHERE id = 5` 这样的简单查找，优化器会选择 `ref` access——直接使用索引的 B+ 树定位到所需行。

### 4.4 回表流程（二级索引 → 聚簇索引）

当使用二级索引且需要 SELECT 的列不在索引中时，InnoDB 需要**回表**：

```
二级索引行 (idx_age)
  │
  ├── [age=25, pk=1001]  ──→  聚簇索引行 (pk=1001)
  ├── [age=25, pk=2005]  ──→  聚簇索引行 (pk=2005)
  └── [age=25, pk=3002]  ──→  聚簇索引行 (pk=3002)
```

在 `ha_index_read_map` 返回行后，如果 handler 发现需要更多列，会在底层自动回表：

```c
// sql/handler.cc:3383
int handler::ha_index_read_map(uchar *buf, const uchar *key,
                               key_part_map keypart_map,
                               enum ha_rkey_function find_flag) {
  // 将 MySQL 级别的键转换为存储引擎的内部格式
  // InnoDB 实现中：row_sel_convert_mysql_key_to_innobase()

  // 调用存储引擎的 index_read 方法
  MYSQL_TABLE_IO_WAIT(PSI_TABLE_FETCH_ROW, active_index, result, {
    result = index_read_map(buf, key, keypart_map, find_flag);
  });

  // 更新生成的字段（generated columns）
  if (!result && m_update_generated_read_fields) {
    result = update_generated_read_fields(buf, table, active_index);
  }

  return result;
}
```

### 4.5 全表扫描

当没有可用索引时，MySQL 选择全表扫描：

```c
// sql/handler.cc:3104
int handler::ha_rnd_next(uchar *buf) {
  MYSQL_TABLE_IO_WAIT(PSI_TABLE_FETCH_ROW, MAX_KEY, result,
                      { result = rnd_next(buf); });
  return result;
}
```

`rnd_next()` 在 InnoDB 中对应扫描聚簇索引 B+ 树的叶子节点链表。

---

## 5. 存储引擎交互

### 5.1 handler::ha_open() — 打开表

SQL 层执行 `handler::ha_open()` 来打开存储引擎中的表：

```c
// sql/handler.cc:2918
int handler::ha_open(TABLE *table_arg, const char *name, int mode,
                     int test_if_locked, const dd::Table *table_def) {
  table = table_arg;

  // 调用存储引擎的 open() 方法
  if ((error = open(name, mode, test_if_locked, table_def))) {
    // 读重试...
  }

  if (!error) {
    // 分配 ref 缓冲区
    if (!ref &&
        !(ref = (uchar *)mem_root->Alloc(ALIGN_SIZE(ref_length) * 2))) {
      ha_close();
      error = HA_ERR_OUT_OF_MEM;
    } else
      dup_ref = ref + ALIGN_SIZE(ref_length);

    cached_table_flags = table_flags();
  }
  return error;
}
```

### 5.2 handler::ha_index_read() — 索引读取

```c
// sql/handler.cc:3383
int handler::ha_index_read_map(uchar *buf, const uchar *key,
                               key_part_map keypart_map,
                               enum ha_rkey_function find_flag) {
  // 调用存储引擎的 index_read_map 实现
  MYSQL_TABLE_IO_WAIT(PSI_TABLE_FETCH_ROW, active_index, result, {
    result = index_read_map(buf, key, keypart_map, find_flag);
  });
  return result;
}
```

### 5.3 handler::ha_rnd_next() — 全表扫描

```c
// sql/handler.cc:3104
int handler::ha_rnd_next(uchar *buf) {
  MYSQL_TABLE_IO_WAIT(PSI_TABLE_FETCH_ROW, MAX_KEY, result,
                      { result = rnd_next(buf); });
  table->set_row_status_from_handler(result);
  return result;
}
```

### 5.4 InnoDB 的 handler 实现

InnoDB 通过 `ha_innobase` 类实现 `handler` 的虚方法：

```c
// storage/innobase/handler/ha_innodb.cc:10461
int ha_innobase::index_read(
    uchar *buf,            // 行缓冲区
    const uchar *key_ptr,  // MySQL 格式的搜索键
    uint key_len,          // 键长度
    enum ha_rkey_function find_flag)  // 搜索模式（HA_READ_KEY_EXACT 等）
{
  dict_index_t *index = m_prebuilt->index;

  // 索引可用性检查
  if (index == nullptr || index->is_corrupted()) {
    return HA_ERR_CRASHED;
  }

  // 如果搜索键不为空，转换为 InnoDB 格式
  if (key_ptr != nullptr) {
    row_sel_convert_mysql_key_to_innobase(
        m_prebuilt->search_tuple,
        m_prebuilt->srch_key_val1,
        m_prebuilt->srch_key_val_len,
        index, key_ptr, key_len);
  } else {
    // 定位到索引的第一个或最后一个条目
    dtuple_set_n_fields(m_prebuilt->search_tuple, 0);
  }

  // 调用 B+ 树搜索
  // row_search_mvcc() 在 B+ 树上二分查找并返回结果行
  err = row_search_mvcc(buf, PAGE_CUR_GE, ...);

  return err;
}
```

InnoDB 的 `rnd_next()` 实现：

```c
// storage/innobase/handler/ha_innodb.cc:10892
  // ha_innobase::rnd_next()
  // 全表扫描：遍历聚簇索引的叶子节点
  error = row_search_mvcc(buf, PAGE_CUR_GEC, ...);
```

关键转换：MySQL SQL 层使用 `handler::ha_index_read_map()` 接口，InnoDB 内部通过 `row_sel_convert_mysql_key_to_innobase()` 将 MySQL 格式的键值转换为 InnoDB 内部 `dtuple_t` 格式，然后调用 `row_search_mvcc()` 在 B+ 树上进行 MVCC 可见性检查。

---

## 6. 关键函数索引

| 函数 | 文件 | 行号 | 作用 |
|------|------|------|------|
| `do_command()` | `sql/sql_parse.cc` | 1347 | 读取客户端命令 |
| `dispatch_command()` | `sql/sql_parse.cc` | 1752 | 命令分发 |
| `dispatch_sql_command()` | `sql/sql_parse.cc` | 5299 | SQL 解析 + 执行调度 |
| `parse_sql()` | `sql/sql_parse.cc` | — | SQL 文本解析入口 |
| `MYSQLlex()` | `sql/sql_lex.cc` | — | 词法分析 (Bison yylex) |
| `get_token()` | `sql/sql_lex.cc` | 988 | 复制 token 文本 |
| `is_lex_native_function()` | `sql/sql_lex.cc` | 979 | 关键字/函数完美哈希匹配 |
| `mysql_execute_command()` | `sql/sql_parse.cc` | 3018 | 命令执行主入口 |
| `JOIN::optimize()` | `sql/sql_optimizer.cc` | 344 | 查询优化主入口 |
| `JOIN::exec()` | `sql/sql_executor.cc` | — | 查询执行（通过 AccessPath 迭代） |
| `JOIN::create_access_paths()` | `sql/sql_executor.cc` | 3126 | 生成 AccessPath 执行树 |
| `JOIN::optimize_distinct()` | `sql/sql_executor.cc` | 409 | DISTINCT 优化 |
| `optimize_cond()` | `sql/sql_optimizer.cc` | — | 条件优化（常量折叠/消除） |
| `optimize_aggregated_query()` | `sql/sql_optimizer.cc` | 192 | 聚合查询优化（COUNT/MIN/MAX） |
| `prune_table_partitions()` | `sql/sql_optimizer.cc` | — | 分区裁剪 |
| `greedy_search()` | `sql/sql_planner.cc` | 2330 | 贪心搜索连接顺序 |
| `find_best_ref()` | `sql/sql_planner.cc` | 208 | 评估 ref access 成本 |
| `get_index_for_order()` | `sql/sql_select.cc` | 5450 | 为 ORDER BY 选择索引 |
| `join_read_const_table()` | `sql/sql_executor.cc` | 3678 | 读取常量表 |
| `read_const()` | `sql/sql_executor.cc` | 3809 | 单行索引查找 |
| `handler::ha_open()` | `sql/handler.cc` | 2918 | 打开存储引擎表 |
| `handler::ha_close()` | `sql/handler.cc` | 2988 | 关闭存储引擎表 |
| `handler::ha_rnd_next()` | `sql/handler.cc` | 3104 | 全表扫描（无序） |
| `handler::ha_index_read_map()` | `sql/handler.cc` | 3383 | 索引读取（MySQL 层 wrapper） |
| `ha_innobase::index_read()` | `storage/innobase/handler/ha_innodb.cc` | 10461 | InnoDB 索引读取实现 |
| `row_sel_convert_mysql_key_to_innobase()` | `storage/innobase/row/row0mysql.cc` | — | MySQL 键 → InnoDB dtuple 转换 |
| `row_search_mvcc()` | `storage/innobase/row/row0sel.cc` | — | B+ 树 MVCC 搜索 |
| `handlerton` struct | `sql/handler.h` | 2856 | 存储引擎注册接口 |
| `THD` class | `sql/sql_class.h` | 953 | 线程会话上下文 |
| `Item` class | `sql/item.h` | 928 | 表达式树基类 |
| `POSITION` struct | `sql/sql_select.h` | 101 | 连接位置信息 |
| `MEM_ROOT` | `sql/sql_class.h` | 4499 | 生命周期内存分配器 |

---

## 7. 总结

MySQL SQL 层的架构设计体现了**清晰的关注分离**：

1. **解析阶段**将文本转化为结构化数据（Parse Tree），通过 `LEX` / `SELECT_LEX` / `Item` 表达
2. **优化阶段**基于代价模型选择最佳执行计划，核心是 `find_best_ref()` + `greedy_search()` +
   `optimize_cond()`
3. **执行阶段**将计划转化为对 `handler` 接口的迭代调用，支持嵌套循环连接、哈希连接、索引扫描等多种方式
4. **存储引擎接口**通过 `handlerton` 函数指针表和 `handler` 虚方法实现完全的多态

整个 SQL 层的生命周期内存管理依赖 `MEM_ROOT`，解析/优化/执行过程中分配的临时对象在语句结束后一次性释放，避免了逐对象释放的复杂度和性能开销。

与 InnoDB 层的分界是清晰的：SQL 层不关心数据是以何种方式组织在磁盘上的，InnoDB 层也不关心 SELECT/UPDATE/DELETE 等 SQL 语义——两者通过 `handler` 接口协作。
