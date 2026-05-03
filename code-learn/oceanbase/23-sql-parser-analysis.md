# 23-sql-parser-analysis — SQL Parser & Resolver：从 SQL 文本到解析树

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

本篇文章分析 SQL 引擎的**起点**——Parser（解析器）和 Resolver（语义分析器）。经过前面 22 篇文章对存储引擎、分布式共识、SQL 执行（PX、Plan Cache）的深入分析，现在我们回到 SQL 引擎的最前端，看一条 SQL 文本如何被解析成可被优化器理解的内部表示。

### 定位

```
SQL 文本
  │
  ▼
┌───────────────────────┐
│   ObParser::parse()   │  ← 词法分析 + 语法分析
│                       │     生成 ParseNode 树
│  ┌─────────────────┐  │
│  │  Lexer (flex)   │  │   字符流 → Token 流
│  │  .l 文件        │  │
│  └────────┬────────┘  │
│           │           │
│           ▼           │
│  ┌─────────────────┐  │
│  │ Parser (bison)  │  │   Token 流 → 解析树
│  │  .y 文件        │  │   (ParseNode 树)
│  └─────────────────┘  │
└───────────────────────┘
  │
  ▼
┌───────────────────────┐
│ ObResolver::resolve() │  ← 语义分析
│                       │     验证表名、列名、类型
│  ┌─────────────────┐  │
│  │ ObSelectResolver│  │   SELECT 解析
│  │ ObInsertResolver│  │   INSERT 解析
│  │ ...             │  │   60+ 种 Resolver
│  └─────────────────┘  │
└───────────────────────┘
  │
  ▼
┌───────────────────────┐
│      ObStmt           │  ← 逻辑计划（未优化）
│  (ObSelectStmt /      │
│   ObInsertStmt / ... )│
└───────────────────────┘
  │
  ▼
  Optimizer              ← 前文第 17 篇
```

### 代码位置

| 组件 | 路径 |
|------|------|
| Parser 入口 | `src/sql/parser/ob_parser.h/cpp` |
| SQL Parser 封装 | `src/sql/parser/ob_sql_parser.h/cpp` |
| Lexer (flex) | `src/sql/parser/sql_parser_mysql_mode.l` |
| Parser (bison) | `src/sql/parser/sql_parser_mysql_mode.y` |
| 解析树节点 | `src/sql/parser/parse_node.h/c` |
| Fast Parser | `src/sql/parser/ob_fast_parser.h/cpp` |
| SIMD 加速解析 | `src/sql/parser/ob_parse_simd.cpp` |
| 内存管理 | `src/sql/parser/parse_malloc.h/cpp` |
| 关键字处理 | `src/sql/parser/ob_non_reserved_keywords.h/c` |
| 字符集处理 | `src/sql/parser/ob_parser_charset_utils.h/cpp` |
| Parser 工具 | `src/sql/parser/ob_parser_utils.h` |
| Resolver 入口 | `src/sql/resolver/ob_resolver.h/cpp` |
| Stmt Resolver 基类 | `src/sql/resolver/ob_stmt_resolver.h/cpp` |
| 逻辑计划基类 | `src/sql/resolver/ob_stmt.h` |
| DML Resolver | `src/sql/resolver/dml/` |
| DDL Resolver | `src/sql/resolver/ddl/` |
| DCL Resolver | `src/sql/resolver/dcl/` |
| 表达式解析 | `src/sql/resolver/expr/` |

---

## 1. 整体架构：双路径设计

OceanBase 的 SQL 解析层有一个核心设计决策：**同时维护两条解析路径**——Full Parser（完整解析）和 Fast Parser（快速解析）。

```
SQL 文本
    │
    ├── 首次执行 ──→  Full Parser (flex + bison) ──→ ParseNode 树 ──→ Resolver ──→ Stmt
    │                    │                                                  │
    │                    └── 词法分析/sql_parser_mysql_mode.l               │
    │                    └── 语法分析/sql_parser_mysql_mode.y               │
    │                                                                      │
    └── Plan Cache  ──→  Fast Parser ──→ 参数化 SQL + 参数列表
    命中（软解析）         (ob_fast_parser.h)   ├── no_param_sql
                                                └── param_list
```

**为什么需要两条路径？**

- **Full Parser**：使用 flex/bison 生成，产生完整的 `ParseNode` 树，包含所有语法细节。这是 Resolver 所需的完整表示。
- **Fast Parser**：手写的状态机解析器，不做完整的语法分析。它的工作很简单：将 SQL 中的常量替换为 `?` 占位符（参数化），同时记录常量的值和位置。输出一个参数化后的 SQL 字符串和参数列表，用于在 Plan Cache 中匹配缓存项。

---

## 2. 核心数据结构：ParseNode

`ParseNode` 是整个解析层的**通用节点类型**，定义在 `parse_node.h:125`（`_ParseNode` 结构体）。

```c
typedef struct _ParseNode
{
  ObItemType type_;              // 节点类型（T_SELECT, T_INSERT, T_FUN_MAX 等）
  int32_t num_child_;            // 子节点个数（非终结符）
  int16_t param_num_;            // 该节点原始文本中常量的个数

  union {
    uint32_t flag_;
    struct {                     // 位域标记：18+ 个标记位
      uint32_t is_neg_                    : 1;
      uint32_t is_hidden_const_           : 1;
      uint32_t is_tree_not_param_         : 1;
      uint32_t length_semantics_          : 2; // oracle char/byte 语义
      uint32_t is_val_paramed_item_idx_   : 1;
      uint32_t is_copy_raw_text_          : 1;
      uint32_t is_column_varchar_         : 1;
      uint32_t is_trans_from_minus_       : 1;
      uint32_t is_assigned_from_child_    : 1;
      uint32_t is_num_must_be_pos_        : 1;
      uint32_t is_date_unit_             : 1;
      uint32_t is_literal_bool_          : 1;
      uint32_t is_empty_                 : 1;
      uint32_t is_multiset_              : 1;
      uint32_t is_forbid_anony_parameter_ : 1;
      uint32_t is_input_quoted_          : 1;
      uint32_t is_forbid_parameter_      : 1;
      uint32_t is_default_literal_expression_ : 1;
      uint32_t reserved_;
    };
  };

  // 数值节点：value_ 存整数值，同时 str_value_ 存原始字符串
  union {
    int64_t value_;
    int32_t int32_values_[2];
    int16_t int16_values_[4];
  };
  const char *str_value_;
  int64_t str_len_;
  union {
    int64_t pl_str_off_;   // PL 层字符串偏移
    int64_t sql_str_off_;  // SQL 层字符串偏移
  };

  const char *raw_text_;           // 词法阶段处理后丢失的原始文本
  int64_t text_len_;
  int64_t pos_;                    // 在参数化 SQL 中的偏移

  struct _ParseNode **children_;   // 子节点数组（非终结符）
  ObStmtLoc stmt_loc_;             // 语句位置（行列号）
  union {
    int64_t raw_param_idx_;        // Fast Parser 参数列表中的下标
    int64_t raw_sql_offset_;       // 在原始 SQL 中的字符偏移
  };
} ParseNode;
```

### ParseNode 树示例

对于 `SELECT a, b FROM t WHERE c > 10`，解析树大致为：

```
                  T_SELECT
              /    |      \
         T_SELECT_LIST  T_FROM_LIST  T_WHERE_CLAUSE
           /      \         |             |
      T_PROJECT_STRING  T_PROJECT_STRING  T_REF_COLUMN  T_OP_GT
           |               |              (c)          /    \
      T_IDENT(a)       T_IDENT(b)               T_REF_COLUMN  T_INT
                                                  (c)        (10)
```

### 解析上下文：ParseResult

解析的完整上下文封装在 `ParseResult` 结构体（`parse_node.h:295`）中。这是一个巨大的结构体，包含：

```c
typedef struct {
  void *yyscan_info_;               // flex/bison 的扫描器状态
  const char *input_sql_;           // 原始 SQL 输入
  int input_sql_len_;
  int param_node_num_;              // 参数化后的参数个数
  int token_num_;                   // Token 数量
  void *malloc_pool_;               // 内存分配器（ObIAllocator）
  ObQuestionMarkCtx question_mark_ctx_;  // 问号参数映射
  ObSQLMode sql_mode_;              // SQL 模式
  const struct ObCharsetInfo *charset_info_;
  const struct ObCharsetInfo *charset_info_oracle_db_;
  ParamList *param_nodes_;
  ParamList *tail_param_node_;

  struct {                          // 25+ 个位域标记
    uint32_t has_encount_comment_        : 1;
    uint32_t is_fp_                      : 1;
    uint32_t is_multi_query_             : 1;
    uint32_t is_ignore_hint_             : 1;
    uint32_t is_ignore_token_            : 1;
    uint32_t need_parameterize_          : 1;
    // ...
    uint32_t clickhouse_func_exposed_    : 1;
  };

  ParseNode *result_tree_;          // ← 解析树的根节点（核心输出）
  jmp_buf *jmp_buf_;                // 错误处理的跳转缓冲区
  int extra_errno_;
  char *error_msg_;
  int start_col_, end_col_, line_, yycolumn_, yylineno_;
  char *tmp_literal_;
  char *no_param_sql_;              // Fast Parser 的参数化 SQL
  int no_param_sql_len_;
  PLParseInfo pl_parse_info_;       // PL 解析信息
  ObMinusStatusCtx minus_ctx_;      // 负数转义上下文
  int64_t last_escape_check_pos_;
  int connection_collation_;
  bool mysql_compatible_comment_;
  bool enable_compatible_comment_;
  InsMultiValuesResult *ins_multi_value_res_;
  int json_object_depth_;
} ParseResult;
```

---

## 3. Parser 入口：ObParser 类

`ObParser`（`ob_parser.h:49`）是整个解析过程的入口。它的核心方法是 `parse()`，负责从 SQL 文本到 `ParseResult` 的完整流程。

### ObParser::parse() 方法签名

```cpp
virtual int parse(const common::ObString &stmt,
                  ParseResult &parse_result,
                  ParseMode mode=STD_MODE,
                  const bool is_batched_multi_stmt_split_on = false,
                  const bool no_throw_parser_error = false,
                  const bool is_pl_inner_parse = false,
                  const bool is_dbms_sql = false,
                  const bool is_parser_dynamic_sql = false);
```

### ParseMode 枚举

`parse_node.h:85` 定义了多种解析模式：

```
STD_MODE                          标准模式：完整解析，生成 ParseNode 树
FP_MODE                           Fast Parser：常量参数化，仅保留 hint
MULTI_MODE                        多语句快速解析（分号分隔的多条 SQL）
FP_PARAMERIZE_AND_FILTER_HINT_MODE  参数化 + 过滤 hint
FP_NO_PARAMERIZE_AND_FILTER_HINT_MODE  过滤 hint + 不做参数化
TRIGGER_MODE                      Trigger 内部解析（:xxx 视为标识符）
DYNAMIC_SQL_MODE                  动态 SQL 解析
DBMS_SQL_MODE                     DBMS_SQL 包调用
UDR_SQL_MODE                      UDR（用户定义路由）解析
INS_MULTI_VALUES                  多值 INSERT 优化解析
```

### 解析流程

```
ObParser::parse()
  │
  ├── 1. 多语句拆分（split_multiple_stmt）
  │     按分号拆分，支持 PL 块判断
  │
  ├── 2. 预处理 SQL
  │     处理字符集转换、注释去除
  │
  ├── 3. 选择解析路径
  │     ├── STD_MODE → Full Parser（flex + bison）
  │     └── FP_*     → Fast Parser（手写状态机）
  │
  └── 4. 返回 ParseResult
        ├── result_tree_ ← 解析树根节点（Full Parser）
        ├── no_param_sql_ + param_nodes_ ← 参数化结果（Fast Parser）
        └── error_msg_ ← 错误信息（如果解析失败）
```

### 多语句拆分

`ObParser::split_multiple_stmt()` 负责将包含多条 SQL 的输入按分号切分。这个函数需要区分 PL 块内的分号和语句分隔符的分号：

```cpp
// ob_parser.cpp:62
int split_multiple_stmt(const common::ObString &stmt,
                        common::ObIArray<common::ObString> &queries,
                        ObMPParseStat &parse_fail,
                        bool is_ret_first_stmt=false,
                        bool is_prepare = false);
```

它的辅助函数 `is_pl_stmt()`（`ob_parser.cpp:170`）通过有限状态机扫描 SQL 的起始 token，判断当前语句是否为 PL 语句（CREATE FUNCTION/PROCEDURE/PACKAGE/BEGIN/...），因为 PL 块内部可以有分号。

---

## 4. 词法分析器：flex 生成的 Lexer

词法分析器定义在 `sql_parser_mysql_mode.l`，使用 flex 工具生成 `sql_parser_mysql_mode_lex.h`。

### 基本架构

```lex
%option noyywrap nounput noinput case-insensitive
%option reentrant bison-bridge bison-locations
%option prefix="obsql_mysql_yy"

%x hint in_c_comment sq dq bt adq ...
```

关键点：

- **reentrant**：可重入解析器，支持并发解析
- **bison-bridge**：与 bison 的 `%union` 和 `%locations` 配合
- **prefix="obsql_mysql_yy"**：避免符号冲突（OceanBase 同时有 MySQL 和 Oracle 模式）

### Token 类型定义

Lexer 识别以下类别的 token：

```lex
// 关键字（由 bison 定义，.l 直接匹配）
// 例如：
"SELECT"     { return SELECT; }
"INSERT"     { return INSERT; }
"FROM"       { return FROM; }
"WHERE"      { return WHERE; }

// 常量
int_num      [0-9]+            → T_INT
{quote}...{quote}               → T_VARCHAR
0x[0-9A-F]+                     → T_HEX
b'[01]+'                        → T_BIT

// 标识符（表名、列名）
identifier   ([A-Za-z0-9$_]|{NOTASCII_GB_CHAR})+

// 操作符
'+'          { return '+'; }
'-'          { return '-'; }
'*'          { return '*'; }
'='          { return COMP_EQ; }

// 注释
"/*!..."     → mysql_compatible_comment_ = true
"-- ..."     → 行注释
"# ..."      → 行注释（MySQL 模式）
"/*+ ... */" → hint
```

### 多字节字符支持

Lexer 处理多字节字符集（中文、日文等）：

```lex
NOTASCII [\x80-\xFF]
GB_1 [\x81-\xfe]
GB_2 [\x40-\xfe]
NOTASCII_GB_CHAR ({NOTASCII}|{GB_1}{GB_2}|{GB_1}{GB_3}{GB_1}{GB_3})
```

### 关键字处理

OceanBase 使用 **Trie 树**进行关键字查找，定义在 `ob_non_reserved_keywords.h`：

```c
typedef struct trie_node {
  int32_t idx;
  struct trie_node *next[CHAR_LEN];  // 37 = A-Z + 0-9 + _
} t_node;

extern const NonReservedKeyword *mysql_non_reserved_keyword_lookup(const char *word);
extern const NonReservedKeyword *oracle_non_reserved_keyword_lookup(const char *word);
extern int mysql_sql_reserved_keyword_lookup(const char *word);
```

OceanBase 将关键字分为两类：

1. **保留关键字（Reserved Keywords）**：不能用作标识符（如 SELECT、FROM、WHERE）
2. **非保留关键字（Non-reserved Keywords）**：可以作标识符（如 STATUS、TABLES）

非保留关键字通过 Trie 树做 O(n) 匹配（n 为关键字字符长度），而不是线性扫描所有关键字列表。

---

## 5. 语法分析器：bison 生成的 Parser

语法规则定义在 `sql_parser_mysql_mode.y`。这是一个 **LALR(1) 解析器**，OceanBase 完整实现了 MySQL 语法兼容。

### 解析树构建

bison 的动作代码中调用 `parse_node.h` 中的函数构建 `ParseNode` 树：

```yacc
select_stmt:
    SELECT select_expr_list FROM table_ref_list where_clause
    {
      $$ = new_non_terminal_node(malloc_pool, T_SELECT, 3,
                                  $2, $3, $4, $5);
    }
    ;
```

对应用到的节点创建函数：

```c
// parse_node.h:401 解析节点的工厂函数
ParseNode *new_node(void *malloc_pool, ObItemType type, int num);
ParseNode *new_non_terminal_node(void *malloc_pool, ObItemType node_tag, int num, ...);
ParseNode *new_terminal_node(void *malloc_pool, ObItemType type);
ParseNode *new_list_node(void *malloc_pool, ObItemType node_tag, int capacity, int num, ...);
```

### 错误恢复

OceanBase 使用 bison 的 `yyerror` 函数进行错误恢复，在 `sql_parser_base.c` 中定义：

```c
void obsql_mysql_yyerror(YYLTYPE *yylloc, ParseResult *p, char *s, ...)
{
  // 记录错误信息和位置到 ParseResult
  p->extra_errno_ = OB_PARSER_ERR_SYNTAX;
  // ...
}
```

此外，使用 `jmp_buf` 做 fatal error 的 longjmp 恢复：

```c
// parse_node.h:338
jmp_buf *jmp_buf_;  // handle fatal error
```

### 生成的文件

```
_gen_parser.output    ← bison 的 .output 文件（含状态机表）
_gen_parser.error     ← 可能的冲突报告
```

---

## 6. Fast Parser：手写状态机

Fast Parser 是 OceanBase 的一个关键性能优化。定义在 `ob_fast_parser.h`。

### 架构

```
ObFastParser（静态入口）
  │
  ├── ObFastParserBase（基类，核心状态机）
  │     ├── scan_token()
  │     ├── parameterize()
  │     ├── remove_comments()
  │     └── ...
  │
  ├── ObFastParserMysql（MySQL 模式）
  │     └── process_identifier()
  │     └── process_string()
  │
  └── ObFastParserOracle（Oracle 模式）
        └── process_identifier()
        └── process_string()
```

### 工作原理

Fast Parser 的核心逻辑是一条一条扫描字符，用状态机进行分类：

```cpp
// ob_fast_parser.h 中的核心状态枚举
enum TokenType {
  INVALID_TOKEN,
  NORMAL_TOKEN,  // 需要保留的 token（关键字、标识符、操作符）
  PARAM_TOKEN,   // 需要参数化的 token（常量、字符串、数字）
  IGNORE_TOKEN   // 需要忽略的 token（注释）
};
```

对于每个 token，Fast Parser 判断是否要：
1. **保留**到参数化 SQL（关键字、标识符）
2. **替换为 `?`**（常量、数字、字符串）
3. **丢弃**（注释）

### FPContext

```cpp
struct FPContext {
  bool enable_batched_multi_stmt_;
  bool is_udr_mode_;
  ObCharsets4Parser charsets4parser_;
  ObSQLMode sql_mode_;
  QuestionMarkDefNameCtx *def_name_ctx_;
  bool is_format_;
  bool question_mark_by_order_;
};
```

### 输出

```cpp
static int parse(const common::ObString &stmt,
                 const FPContext &fp_ctx,
                 common::ObIAllocator &allocator,
                 char *&no_param_sql,       // 参数化后的 SQL
                 int64_t &no_param_sql_len,
                 ParamList *&param_list,    // 参数值列表
                 int64_t &param_num,        // 参数个数
                 ObFastParserResult &fp_result,
                 int64_t &values_token_pos);
```

### SIMD 优化

`ob_parse_simd.cpp` 使用 AVX-512 指令集加速 Fast Parser：

```cpp
// 使用 AVX-512 一次性检查 64 个字节是否为十六进制字符
__m512i chars = _mm512_loadu_si512(...);
__mmask64 mask = (_mm512_cmpge_epu8_mask(chars, zero)
                & _mm512_cmple_epu8_mask(chars, nine))
               | (_mm512_cmpge_epu8_mask(chars, a)
                & _mm512_cmple_epu8_mask(chars, f));
```

这种批量处理对于 IO 密集型的 Fast Parser 能显著提升吞吐。

### 何时使用 Fast Parser vs Full Parser

| 场景 | Parser 路径 | 原因 |
|------|-------------|------|
| 首次执行 SQL | Full Parser | 需要完整的 ParseNode 树给 Resolver |
| Plan Cache 查找（软解析） | Fast Parser | 只需要参数化 SQL 做 key 匹配 |
| SQL 审计/日志脱敏 | Fast Parser | 只需要参数化，不需要语法树 |
| obproxy 前端 | Fast Parser | obproxy 只需要计算 SQL ID |
| DDL 语句 | Full Parser | DDL 需要完整语义分析 |
| 多语句批量拆分 | Full 或 Fast | 取决于后续使用场景 |

---

## 7. Resolver：从解析树到逻辑计划

Resolver 是语义分析层，接收 `ParseNode` 树，输出 `ObStmt`（逻辑计划）。

### ObResolver::resolve()

`ob_resolver.cpp` 中的 `resolve()` 方法是 Resolver 的入口。它的核心是一个**巨大的 switch 语句**，根据 `ParseNode` 的 `type_` 分发到对应的 `ObXxxResolver`：

```cpp
int ObResolver::resolve(IsPrepared if_prepared,
                        const ParseNode &parse_tree,
                        ObStmt *&stmt)
{
  // ...
  switch (real_parse_tree->type_) {
    case T_SELECT: {
      REGISTER_SELECT_STMT_RESOLVER(Select);
      break;
    }
    case T_INSERT: {
      REGISTER_STMT_RESOLVER(Insert);
      break;
    }
    case T_CREATE_TABLE: {
      REGISTER_STMT_RESOLVER(CreateTable);
      break;
    }
    // ... 60+ 种语句类型
  }
}
```

### Resolver 层次结构

```
ObResolver（入口）
  │
  ├── ObStmtResolver（基类）
  │     ├── DML 路径
  │     │     ├── ObDMLResolver（DML 公共基类）
  │     │     │     ├── ObSelectResolver（SELECT）
  │     │     │     ├── ObInsertResolver（INSERT）
  │     │     │     ├── ObUpdateResolver（UPDATE）
  │     │     │     ├── ObDeleteResolver（DELETE）
  │     │     │     ├── ObMergeResolver（MERGE）
  │     │     │     └── ObMultiTableInsertResolver
  │     │     │
  │     │     └── ObExprRelationAnalyzer（表达式关系分析）
  │     │
  │     ├── DDL 路径
  │     │     ├── ObCreateTableResolver
  │     │     ├── ObAlterTableResolver
  │     │     ├── ObDropTableResolver
  │     │     ├── ObCreateIndexResolver
  │     │     ├── ObCreateViewResolver
  │     │     └── ...（30+ 种）
  │     │
  │     ├── DCL 路径
  │     │     ├── ObGrantResolver
  │     │     ├── ObRevokeResolver
  │     │     ├── ObCreateUserResolver
  │     │     └── ...
  │     │
  │     ├── TCL 路径
  │     │     ├── ObStartTransResolver
  │     │     └── ObEndTransResolver
  │     │
  │     └── CMD 路径
  │           ├── ObShowResolver
  │           ├── ObVariableSetResolver
  │           ├── ObKillResolver
  │           └── ...
  │
  └── ObRawExprResolver（表达式解析）
        └── ObRawExprResolverImpl
```

### 模板化的 Resolver 调用

OceanBase 使用模板函数简化 Resolver 的实例化和调用：

```cpp
// ob_resolver.cpp
template <typename ResolverType>
int ObResolver::stmt_resolver_func(ObResolverParams &params,
                                   const ParseNode &parse_tree,
                                   ObStmt *&stmt)
{
  int ret = OB_SUCCESS;
  HEAP_VAR(ResolverType, stmt_resolver, params) {
    if (OB_FAIL(stmt_resolver.resolve(parse_tree))) {
      LOG_WARN("execute stmt_resolver failed", K(ret), K(parse_tree.type_));
    }
    stmt = stmt_resolver.get_basic_stmt();
  }
  return ret;
}

// 使用宏简化 switch 分支
#define REGISTER_STMT_RESOLVER(name) \
  do { \
    ret = stmt_resolver_func<Ob##name##Resolver>(params_, *real_parse_tree, stmt); \
  } while (0)
```

`HEAP_VAR` 宏将 Resolver 实例分配到堆上（而不是栈上），避免栈溢出（SELECT 语句解析涉及大量递归）。

### Resolver 的核心工作

以 `ObSelectResolver` 为例，`resolve()` 方法执行：

1. **解析查询选项**：DISTINCT、HIGH_PRIORITY、SQL_CALC_FOUND_ROWS
2. **解析 FROM 子句**：表引用、JOIN、子查询
3. **解析 WHERE 子句**：过滤条件
4. **解析 GROUP BY / HAVING**：分组 + 聚合
5. **解析 SELECT 列表**：投影列、别名、聚合函数
6. **解析 ORDER BY**：排序
7. **解析 LIMIT / OFFSET**：分页
8. **解析 FOR UPDATE**：行锁
9. **语义检查**：列存在性、类型兼容性、聚合嵌套规则

### 表达式解析

`ob_raw_expr_resolver_impl.h` 中的 `ObRawExprResolverImpl` 实现了表达式解析的核心逻辑。它将 `ParseNode` 树中代表表达式的子树转换为 `ObRawExpr` 对象：

```cpp
virtual int resolve(const ParseNode *node,
                    ObRawExpr *&expr,
                    ObIArray<ObQualifiedName> &columns,
                    ObIArray<ObVarInfo> &sys_vars,
                    ObIArray<ObSubQueryInfo> &sub_query_info,
                    ObIArray<ObAggFunRawExpr*> &aggr_exprs,
                    ObIArray<ObWinFunRawExpr*> &win_exprs,
                    ObIArray<ObUDFInfo> &udf_exprs,
                    ObIArray<ObOpRawExpr*> &op_exprs,
                    ObIArray<ObUserVarIdentRawExpr*> &user_var_exprs,
                    ObIArray<ObInListInfo> &inlist_infos,
                    ObIArray<ObMatchFunRawExpr*> &match_exprs);
```

这个接口的参数列表体现了表达式解析的复杂性——需要收集列引用、系统变量、子查询、聚合函数、窗口函数、UDF、操作符、用户变量、IN 列表和全文搜索表达式。

---

## 8. 完整数据流

下面展示一条简单 SQL 的完整解析过程：

```
SQL: SELECT a, b FROM t WHERE c > 10 AND d = 'hello'
```

### 阶段 1：词法分析（Lexer）

Lexer 扫描字符流，生成 Token 流：

```
Token             值         类型
───────────────────────────────────
SELECT            —          T_SELECT
IDENTIFIER        "a"        T_IDENT
','               —          T_COMMA
IDENTIFIER        "b"        T_IDENT
FROM              —          T_FROM
IDENTIFIER        "t"        T_IDENT
WHERE             —          T_WHERE
IDENTIFIER        "c"        T_IDENT
'>'               —          T_OP_GT
INT               10         T_INT
AND               —          T_AND
IDENTIFIER        "d"        T_IDENT
'='               —          T_OP_EQ
STRING            "hello"    T_VARCHAR
```

### 阶段 2：语法分析（Parser）

bison 根据语法规则将 Token 序列构造成 ParseNode 树：

```
      T_SELECT (num_child_=3)
      /         |            \
   T_FIELD_LIST  T_FROM_LIST  T_WHERE
      /     \        |           |
  T_IDENT  T_IDENT  T_IDENT    T_OP_AND
  ("a")    ("b")    ("t")     /        \
                          T_OP_GT     T_OP_EQ
                         /     \      /       \
                     T_IDENT  T_INT T_IDENT  T_VARCHAR
                     ("c")   (10)  ("d")   ("hello")
```

### 阶段 3：语义分析（Resolver）

Resolver 将 ParseNode 树转换为 ObSelectStmt：

```
ObSelectStmt
├── select_items_:  [a, b]
│     ├── ColumnItem (table_id=t, column_id=a)
│     └── ColumnItem (table_id=t, column_id=b)
├── from_items:     [t]
│     └── TableItem (table_id=t, database_name=test, table_name=t)
├── where_expr:
│     └── T_OP_AND
│           ├── T_OP_GT (c > 10)
│           │     ├── ColumnRefRawExpr (c)
│           │     └── ConstRawExpr (10)
│           └── T_OP_EQ (d = 'hello')
│                 ├── ColumnRefRawExpr (d)
│                 └── ConstRawExpr ('hello')
└── query_ctx:
      └── ObQueryCtx (hints, params, ...)
```

此阶段会进行：
- **表名解析**：`t` → `(database_id, table_id)`
- **列名解析**：`a` → `(table_id, column_id)` 
- **类型检查**：`10` 是 INT，`'hello'` 是 VARCHAR，`c > 10` 类型兼容
- **权限检查**：当前用户是否有 `t` 的 SELECT 权限

### 完整流水线

```
SQL 文本
  │
  ▼
[Pre-Parse]                   识别语句类型（SELECT/INSERT/PL/...）
  │
  ▼
[Split Multiple Stmt]         如果有分号，拆分为多条
  │
  ├── Full Parser 路径
  │     │
  │     ├── parse_init()       初始化 ParseResult
  │     ├── sql_parser_mysql_mode.l  → 词法分析
  │     ├── sql_parser_mysql_mode.y  → 语法分析
  │     ├── result_tree_         ← ParseNode 树
  │     └── parse_terminate()   清理
  │
  ├── Fast Parser 路径
  │     │
  │     ├── ObFastParserMysql/Oracle
  │     ├── no_param_sql_        ← 参数化 SQL
  │     └── param_list           ← 参数列表
  │
  ▼
[Resolver]
  │
  ├── ObResolver::resolve()
  │     └── switch(type_) → ObSelectResolver::resolve()
  │           ├── resolve_from_clause()      表名/JOIN 解析
  │           ├── resolve_field_list()       投影列解析
  │           ├── resolve_where_clause()     条件解析
  │           ├── resolve_group_clause()     分组解析
  │           └── resolve_order_clause()     排序解析
  │
  └── ObStmt  ← 逻辑计划
  ```

---

## 9. 内存管理

Parser 的内存分配使用专用的 `parse_malloc` 接口（`parse_malloc.h`）：

```c
void *parse_malloc(const size_t nbyte, void *malloc_pool);
void *parse_realloc(void *ptr, size_t nbyte, void *malloc_pool);
void parse_free(void *ptr);
char *parse_strndup(const char *str, size_t nbyte, void *malloc_pool);
```

`malloc_pool` 实际上是 `ObIAllocator` 的包装。这种设计有几个原因：

1. **纯 C 接口**：ParseNode 定义和操作使用纯 C（`extern "C"`），但 OceanBase 内部的分配器是 C++ 类
2. **批量分配**：解析过程中会大量创建 `ParseNode`，使用专用分配器减少碎片
3. **生命周期管理**：解析树的生命周期从 `parse()` 返回开始，到 `free_result()` 或优化器消费完为止

`parse_malloc` 分配的内存会被清零（memset），这一点在注释中有特别说明。

---

## 10. 设计决策分析

### 10.1 为什么自研 Parser 而不是直接复用 MySQL？

OceanBase 在设计之初就选择了**自研 Parser**，而不是复用 MySQL 的解析器。原因包括：

1. **Oracle 兼容性**：OceanBase 需要同时支持 MySQL 和 Oracle 语法。MySQL 的原生 Parser 无法处理 Oracle 的 PL/SQL、层次查询（CONNECT BY）、MERGE 语句等。
2. **Fast Parser 集成**：自研 Parser 可以内置 Fast Parser，在词法分析阶段就支持参数化输出，这对 Plan Cache 至关重要。
3. **PL 解析**：OceanBase 的 PL 引擎（存储过程、函数、包）需要与 SQL Parser 深度集成，包括变量查找、动态 SQL 参数等。
4. **性能控制**：自研 Parser 可以针对内存分配、错误处理等做精细化控制。

### 10.2 Fast Parser 的设计哲学

Fast Parser 的设计目标不是替代 Full Parser，而是在**不需要完整语法树**的场景下提供极致的性能。关键设计点：

1. **单次扫描**：Fast Parser 只扫描 SQL 一次，不做回溯，时间复杂度 O(n)
2. **不建树**：不分配 `ParseNode`，不构造树结构，只输出字符串和参数列表
3. **SIMD 加速**：通过 AVX-512 批量处理字符分类
4. **双模式**：同时维护 MySQL 和 Oracle 两种模式，共享基类

### 10.3 解析树的内存管理策略

- **批量分配**：`ParseNode` 和字符串通过 `parse_malloc` 从 `ObIAllocator` 分配，分摊分配开销
- **生命周期绑定**：解析树的生命周期绑定到 `ParseResult`，通过 `free_result()` 一次性释放
- **deep_copy**：`deep_copy_parse_node()` 支持深拷贝解析树，用于 Plan Cache 等需要长生命周期的场景

### 10.4 错误恢复策略

- **语法错误**：bison 的 `yyerror` 记录错误位置和信息，继续解析后续语句
- **致命错误**：使用 `jmp_buf` + `longjmp` 在 OOM 等不可恢复错误时快速退出
- **多语句容错**：`split_multiple_stmt` 在解析失败时继续尝试后续语句（通过 `no_throw_parser_error` 标志控制）

### 10.5 MySQL 兼容性：保留 vs 非保留关键字

OceanBase 的关键字处理使用 **Trie 树**实现快速查找。保留关键字不能用作标识符，非保留关键字可以。这种设计在 MySQL 兼容性上非常重要，因为 MySQL 有大量非保留关键字（如 STATUS、VARIABLES、TABLES 等）。

`ob_non_reserved_keywords.h` 中包含两个查找函数：

```c
// MySQL 模式：非保留关键字查找（大小写不敏感）
const NonReservedKeyword *mysql_non_reserved_keyword_lookup(const char *word);

// Oracle 模式：非保留关键字查找
const NonReservedKeyword *oracle_non_reserved_keyword_lookup(const char *word);
```

---

## 11. 源码索引

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `parse_node.h` | `_ParseNode` 结构体 | 125 |
| `parse_node.h` | `ParseResult` 结构体 | 295 |
| `parse_node.h` | `ParseMode` 枚举 | 85 |
| `parse_node.h` | `SelectParserOffset` 枚举 | 39 |
| `parse_node.h` | `new_node()` / `new_non_terminal_node()` | 401-404 |
| `ob_parser.h` | `ObParser` 类定义 | 49 |
| `ob_parser.h` | `ObParser::parse()` | 86 |
| `ob_parser.h` | `ObParser::State` 枚举（多语句拆分） | 115 |
| `ob_parser.cpp` | `ObParser::is_pl_stmt()` | 170 |
| `ob_parser.cpp` | `ObParser::is_explain_stmt()` | 173 |
| `ob_parser.cpp` | `ObParser::split_multiple_stmt()` | 62 |
| `ob_fast_parser.h` | `ObFastParserBase` 类 | — |
| `ob_fast_parser.h` | `ObFastParserMysql` 类 | — |
| `ob_fast_parser.h` | `ObFastParserOracle` 类 | — |
| `ob_fast_parser.h` | `FPContext` 结构体 | — |
| `ob_sql_parser.h` | `ObSQLParser` 类 | — |
| `ob_non_reserved_keywords.h` | `mysql_non_reserved_keyword_lookup()` | — |
| `ob_non_reserved_keywords.h` | `trie_node` 结构体 | — |
| `parse_malloc.h` | `parse_malloc()` | — |
| `ob_parse_simd.cpp` | `get_first_non_hex_char_avx512()`（SIMD） | — |
| `ob_resolver.h` | `ObResolver` 类定义 | — |
| `ob_resolver.h` | `ObResolver::resolve()` | — |
| `ob_resolver.cpp` | 60+ 种 Resolver 注册 switch | — |
| `ob_stmt_resolver.h` | `ObStmtResolver` 基类 | — |
| `ob_stmt.h` | `ObStmt` 基类 | — |
| `ob_select_resolver.h` | `ObSelectResolver` 类 | — |
| `ob_dml_resolver.h` | `ObDMLResolver` 基类 | — |
| `ob_raw_expr_resolver.h` | `ObRawExprResolver` | — |
| `ob_raw_expr_resolver_impl.h` | `ObRawExprResolverImpl` | — |

---

## 12. 总结

Parser 和 Resolver 构成了 OceanBase SQL 引擎的入口。核心设计要点：

- **双路径解析**：Full Parser（flex/bison）提供完整语法树，Fast Parser（手写状态机）提供高效参数化
- **ParseNode 统一节点**：通用的树形节点结构，`type_` 驱动语义分析
- **ParseResult 上下文**：包含解析所需的所有上下文信息
- **60+ 种 Resolver**：每种语句类型对应一个 Resolver，注册在大型 switch 中
- **内存管理**：`parse_malloc` 适配 OceanBase 的 `ObIAllocator` 体系
- **兼容性**：同时支持 MySQL 和 Oracle 模式，使用 Trie 树处理关键字

从 Parser 到 Resolver 再到 Optimizer 的完整链条是理解 OceanBase SQL 引擎的关键。Resolve 完成后，`ObStmt` 逻辑计划将交给优化器进行查询变换、成本评估和计划生成——这就是前面第 17 篇文章的内容。

---

> **下一篇预告**：深入分析 OceanBase 的全文搜索实现。
