# #19 v2 — SQL Parser (Parser + Resolver + Type Check 完整实读)

> 接续 #17 v2 Query Optimizer + #21 v2 Schema / DDL:前面讲了 "CBO 怎么估算"
> 和 "schema 怎么描述"。本文聚焦 **"SQL 文本怎么变成内部结构"** ——OB 的
> SQL Parser。这是 query pipeline 的第一步,也是 DDL 的解析层。

---

## 0. 全文导读

OB 的 SQL 解析分四层:

```
SQL 文本
  ↓ Lexer (词法分析)
Token 序列
  ↓ Parser (语法分析)
Parse Tree (AST)
  ↓ Resolver (语义分析:name resolution + type inference)
Resolved Stmt
  ↓ Type Check
Typed Stmt
  ↓ (传递到 Optimizer #17)
```

本文按"架构 → Lexer → Parser → Resolver → Type Check → 错误处理 → 性
能"展开。

---

## 1. SQL Parser 整体架构

### 1.1 处理流程

```
SQL text
    ↓
1. Lexer (词法): char → token (关键字/标识符/字面量)
    ↓
2. Parser (语法): token → parse tree (ObStmt)
    ↓
3. Resolver (语义): parse tree → resolved tree (ObDMLStmt)
    - 名字解析: t1.name → schema.table.column
    - 类型推导:表达式类型
    ↓
4. Type Check:类型校验
    - 类型兼容性
    - 函数签名匹配
    ↓
5. (Optimizer 接管 #17)
```

### 1.2 OB 用 Bison / Flex

```cpp
// src/sql/parser/ob_parser.cpp:50
// OB Parser 用 Bison (Yacc) 生成 + 手写 Lexer
class ObParser {
public:
  // 1. parse SQL → ObStmt
  ObStmt *parse_sql(const common::ObString &sql, ParseResult &result);

  // 2. parse_multi_sql(支持多语句:OBProxy 转发 batch)
  int parse_multi_sql(const common::ObString &sql, ParseResult &result);
};
```

### 1.3 解析结果

```cpp
// src/sql/parser/parse_stmt.h:50
class ParseResult {
public:
  ObStmt *stmt_;                // 解析后的语句
  ParseNode *root_;              // parse tree 根
  // 错误
  int err_code_;
  common::ObString err_msg_;
  // 性能
  int64_t parse_time_us_;
  int64_t resolve_time_us_;
  // 缓存 key
  uint64_t sql_id_;              // SQL fingerprint
};
```

---

## 2. Lexer (词法分析)

### 2.1 Token 类型

```cpp
// src/sql/parser/ob_token_type.h:50
enum ObTokenType {
  // 1. 关键字
  TOKEN_SELECT,
  TOKEN_FROM,
  TOKEN_WHERE,
  TOKEN_INSERT,
  TOKEN_UPDATE,
  TOKEN_DELETE,
  // 2. 字面量
  TOKEN_INT,
  TOKEN_STRING,
  TOKEN_FLOAT,
  TOKEN_NULL,
  // 3. 标识符
  TOKEN_IDENT,
  TOKEN_QUOTED_IDENT,  // "User" (反引号保留大小写)
  // 4. 运算符
  TOKEN_PLUS,
  TOKEN_MINUS,
  TOKEN_EQ,
  // 5. 标点
  TOKEN_LPAREN, TOKEN_RPAREN,
  TOKEN_COMMA,
  // 6. 特殊
  TOKEN_EOF,
  TOKEN_SEMICOLON,
};
```

### 2.2 Lexer 实现

```cpp
// src/sql/parser/ob_lexer.cpp:80
class ObLexer {
public:
  // 1. 每次扫一个 token
  ObToken next_token() {
    // 1.1 跳过空白
    skip_whitespace();
    // 1.2 跳过注释
    skip_comments();
    // 1.3 识别 token
    char c = peek();
    if (is_alpha(c)) return scan_ident_or_keyword();
    if (is_digit(c)) return scan_number();
    if (c == '\'') return scan_string();
    if (c == '"') return scan_quoted_ident();
    // ... 其他
    return scan_operator();
  }
};
```

### 2.3 关键字识别

```cpp
// src/sql/parser/parse_keyword.cpp:50
// 关键字表(>200 个)
const Keyword kKeywordTable[] = {
  {"SELECT", TOKEN_SELECT},
  {"FROM", TOKEN_FROM},
  {"WHERE", TOKEN_WHERE},
  // ...
};

// 1. 扫到 ident 后查表
ObToken scan_ident_or_keyword() {
  // 1.1 收集完整 ident
  std::string ident = scan_ident_chars();
  // 1.2 查表
  for (auto &kw : kKeywordTable) {
    if (kw.text == ident) return ObToken(kw.type, ident);
  }
  // 1.3 不是关键字 → 普通 ident
  return ObToken(TOKEN_IDENT, ident);
}
```

### 2.4 字符串字面量

```cpp
// 'abc\\ndef' (含转义)
ObToken scan_string() {
  expect('\'');
  std::string s;
  while (true) {
    char c = next();
    if (c == '\'') {
      // 1. 单引号: 字符串结束
      // 2. 双单引号: 转义为单引号
      if (peek() == '\'') {
        s += '\'';
        next();
      } else {
        break;
      }
    } else if (c == '\\') {
      // 转义
      char next_c = next();
      s += unescape(next_c);  // \n → newline, etc.
    } else {
      s += c;
    }
  }
  return ObToken(TOKEN_STRING, s);
}
```

### 2.5 数字字面量

```cpp
ObToken scan_number() {
  std::string num;
  // 1. 整数部分
  while (is_digit(peek())) num += next();
  // 2. 小数点
  if (peek() == '.') {
    num += next();
    while (is_digit(peek())) num += next();
  }
  // 3. 科学计数法
  if (peek() == 'e' || peek() == 'E') {
    num += next();
    if (peek() == '+' || peek() == '-') num += next();
    while (is_digit(peek())) num += next();
  }
  return ObToken(TOKEN_NUMBER, num);
}
```

---

## 3. Parser (语法分析)

### 3.1 Grammar 范式

OB 用 **LALR(1)** grammar(Bison/Yacc 默认)。Grammar 文件在:
```
src/sql/parser/sql_parser.y
```

简化示意:

```yacc
stmt:
    | select_stmt
    | insert_stmt
    | update_stmt
    | delete_stmt
    | ddl_stmt
    | ...

select_stmt:
    SELECT select_expr_list
    FROM table_ref_list
    WHERE expr
    [GROUP BY ...]
    [HAVING ...]
    [ORDER BY ...]
    [LIMIT ...]
```

### 3.2 Parse Tree 节点

```cpp
// src/sql/parser/parse_node.h:80
struct ParseNode {
  NodeType type_;            // 节点类型: T_SELECT_STMT / T_COLUMN / T_INT ...
  // 子节点数组
  int num_child_;
  ParseNode *children_[MAX_CHILD];
  // 文本值(对字面量)
  common::ObString str_value_;
  int64_t int_value_;
  // 行列信息
  int line_;
  int col_;
};
```

### 3.3 SELECT 节点示例

```cpp
// SQL: SELECT a, b FROM t WHERE a > 5
//
// Parse tree:
//   T_SELECT_STMT
//   ├── T_SELECT_LIST
//   │   ├── T_COLUMN_REF (a)
//   │   └── T_COLUMN_REF (b)
//   ├── T_FROM_LIST
//   │   └── T_TABLE_REF (t)
//   └── T_WHERE
//       └── T_OP_GT
//           ├── T_COLUMN_REF (a)
//           └── T_INT (5)
```

### 3.4 INSERT 节点

```cpp
// SQL: INSERT INTO t (a, b) VALUES (1, 'x')
//
// Parse tree:
//   T_INSERT_STMT
//   ├── T_TABLE_REF (t)
//   ├── T_COLUMN_LIST
//   │   ├── T_COLUMN_REF (a)
//   │   └── T_COLUMN_REF (b)
//   └── T_VALUE_LIST
//       └── T_VALUE_ROW
//           ├── T_INT (1)
//           └── T_STRING ('x')
```

### 3.5 Bison Action

```yacc
// sql_parser.y
select_stmt:
    SELECT select_list FROM from_list opt_where opt_group opt_order opt_limit
    {
      // 创建 SELECT parse node
      ParseNode *node = new_node(T_SELECT_STMT);
      node->children_[0] = $2;  // select_list
      node->children_[1] = $4;  // from_list
      node->children_[2] = $5;  // where
      // ...
      $$ = node;
    }
```

### 3.6 优先级与结合性

```yacc
%left '+' '-'         // 加减(左结合)
%left '*' '/'         // 乘除(更高优先级)
%nonassoc UMINUS      // 一元负(不可结合)
```

优先级:**a + b * c** → **a + (b * c)**(乘除优先于加减)。

---

## 4. Resolver (语义分析)

### 4.1 名字解析(Name Resolution)

```cpp
// src/sql/plan_cache/ob_resolver.cpp:80
// 把 parse tree 中的名字(t1.name)解析为 schema.table.column
class ObResolver {
public:
  int resolve(ObDMLStmt &stmt, const ObSchemaGetterGuard &schema_guard) {
    // 1. 解析 FROM 子句中的表 → 拿到 ObTableSchema
    for (auto &table_ref : stmt.table_refs_) {
      auto *table_schema = schema_guard.get_table_schema(
        table_ref.db_name_, table_ref.table_name_);
      table_ref.table_id_ = table_schema->table_id_;
    }
    // 2. 解析 SELECT/WHERE 中的列引用
    for (auto &expr : stmt.all_exprs_) {
      resolve_column_refs(expr, stmt.table_refs_);
    }
    // 3. 解析 * (通配符)
    expand_star(stmt);
  }
};
```

### 4.2 模糊列引用

```cpp
// SQL: SELECT a FROM t1, t2 WHERE a = 5
// 'a' 是哪个表的?可能是 t1.a 或 t2.a

void resolve_column_ref(ObColumnRefExpr &col_ref,
                        ObIArray<ObTableRef> &tables) {
  // 1. 找唯一包含 a 列的表
  ObTableRef *match = nullptr;
  for (auto &t : tables) {
    if (t.has_column(col_ref.column_name_)) {
      if (match != nullptr) {
        // 2. 多个表有 a → 歧义错误
        throw "ambiguous column reference";
      }
      match = &t;
    }
  }
  col_ref.table_id_ = match->table_id_;
  col_ref.column_id_ = match->get_column_id(col_ref.column_name_);
}
```

### 4.3 函数解析

```cpp
// SQL: SELECT LOWER(name) FROM t
// 'name' 是 column,'LOWER' 是函数 → 找函数定义
int resolve_function(ObFuncExpr &func_expr) {
  // 1. 按名字 + 参数数找函数
  auto *func_def = func_registry_.find(
    func_expr.func_name_, func_expr.param_count_);
  if (func_def == nullptr) {
    throw "unknown function";
  }
  // 2. 设置函数 ID + return type
  func_expr.func_id_ = func_def->func_id_;
  func_expr.set_result_type(func_def->return_type_);
  return OB_SUCCESS;
}
```

### 4.4 视图解析(View Expansion)

```cpp
// SQL: SELECT * FROM v1 WHERE a > 5
// v1 是视图 → 展开为底层查询
int expand_view(ObDMLStmt &stmt) {
  for (auto &table_ref : stmt.table_refs_) {
    if (table_ref.is_view_) {
      // 拿视图定义
      auto *view_def = schema_guard_.get_view_def(table_ref.view_id_);
      // 展开:把视图 query 替换为子查询
      ObSelectStmt *subquery = view_def->to_select_stmt();
      table_ref.subquery_ = subquery;
      // 递归 resolve 子查询
      resolve(*subquery, schema_guard_);
    }
  }
}
```

---

## 5. Type Check

### 5.1 类型推导

```cpp
// SQL: SELECT a + b FROM t
// a 是 INT,b 是 VARCHAR → a + b 是 ???
ObObjType infer_expr_type(ObExpr &expr) {
  switch (expr.type_) {
    case T_INT: return ObIntType;
    case T_STRING: return ObVarcharType;
    case T_COLUMN_REF: {
      // 列类型直接从 schema 拿
      return expr.column_ref_.column_type_;
    }
    case T_OP_PLUS: {
      // 双目运算:取两边中"更宽"的类型
      ObObjType left = infer_expr_type(*expr.children_[0]);
      ObObjType right = infer_expr_type(*expr.children_[1]);
      return get_promoted_type(left, right);
    }
    case T_FUNC_LOWER: return ObVarcharType;  // 已知返回类型
  }
}
```

### 5.2 类型提升(Type Promotion)

```cpp
// INT + VARCHAR → 隐式转换 VARCHAR → VARCHAR
ObObjType get_promoted_type(ObObjType left, ObObjType right) {
  // OB 默认强类型:VARCHAR + INT 直接报错
  if (!is_compatible(left, right)) {
    throw "type mismatch";
  }
  // 同类型 → 不变
  if (left == right) return left;
  // 隐式转换:VARCHAR 包含 INT,可转换
  if (left == ObIntType && right == ObBigintType) return ObBigintType;
  if (left == ObVarcharType && right == ObCharType) return ObVarcharType;
  // ...
}
```

### 5.3 函数签名校验

```cpp
// SQL: SELECT SUBSTR(name, 0) FROM t
// SUBSTR 接受 (VARCHAR, INT, INT)
bool validate_func_call(ObFuncExpr &func_expr) {
  auto *func_def = func_registry_.get(func_expr.func_id_);
  // 1. 参数数匹配
  if (func_expr.args_.count() < func_def->min_arg_count_
      || func_expr.args_.count() > func_def->max_arg_count_) {
    throw "wrong argument count";
  }
  // 2. 参数类型匹配
  for (size_t i = 0; i < func_expr.args_.count(); ++i) {
    auto *param_type = &func_def->param_types_[i];
    auto *arg_type = infer_expr_type(*func_expr.args_[i]);
    if (!is_assignable(*arg_type, *param_type)) {
      throw "argument type mismatch";
    }
  }
  return true;
}
```

---

## 6. SQL Fingerprint (Plan Cache Key)

### 6.1 SQL ID 计算

```cpp
// src/sql/plan_cache/ob_sql_id.cpp:80
// SQL ID = SHA1(SQL fingerprint) 的前 8 字节
uint64_t compute_sql_id(const common::ObString &sql) {
  // 1. 规范化 SQL(去除空白 + 注释 + 大小写)
  std::string normalized = normalize(sql);
  // 2. SHA1
  uint8_t hash[20];
  SHA1(normalized.c_str(), normalized.size(), hash);
  // 3. 取前 8 字节
  uint64_t sql_id;
  memcpy(&sql_id, hash, sizeof(sql_id));
  return sql_id;
}

std::string normalize(const ObString &sql) {
  // 1. 去除注释
  remove_comments(sql);
  // 2. 关键字大写
  uppercase_keywords(sql);
  // 3. 折叠空白
  collapse_whitespace(sql);
  return result;
}
```

### 6.2 参数化(Param Substitution)

```cpp
// 把字面量替换为占位符
// SELECT * FROM t WHERE a = 5   → SELECT * FROM t WHERE a = ?
// SELECT * FROM t WHERE a = 10  → SELECT * FROM t WHERE a = ?  (同一个 sql_id)
std::string parametrize(const ObString &sql) {
  // 1. 扫所有字面量
  // 2. 替换为 ? (按位置编号)
  // 3. 返回 param 列表 + param 化 SQL
}
```

这是 **prepared statement** 的核心 — 同一 SQL + 不同参数,共享一个
plan(接 #17)。

---

## 7. DDL Parser

### 7.1 DDL 解析的特殊性

DDL 不走 CBO,直接 RS 处理:

```cpp
// src/sql/parser/ddl_parser.cpp:80
class ObDDLParser {
public:
  int parse_ddl(const ObString &ddl_text, ObDDLStmt &stmt) {
    // 1. Lexer + Parser(共用)
    parse_sql(ddl_text, ...);
    // 2. 识别 DDL 类型
    switch (stmt.type_) {
      case OB_DDL_CREATE_TABLE:
        return parse_create_table(stmt);
      case OB_DDL_ADD_COLUMN:
        return parse_add_column(stmt);
      case OB_DDL_CREATE_INDEX:
        return parse_create_index(stmt);
      // ...
    }
  }
};
```

### 7.2 CREATE TABLE 解析

```cpp
// SQL: CREATE TABLE t (id INT PRIMARY KEY, name VARCHAR(100) NOT NULL)
//
// Parse tree:
//   T_CREATE_TABLE
//   ├── T_TABLE_NAME (t)
//   └── T_COLUMN_DEF_LIST
//       ├── T_COLUMN_DEF (id, INT, PRIMARY KEY)
//       └── T_COLUMN_DEF (name, VARCHAR(100), NOT NULL)
```

### 7.3 ADD COLUMN

```cpp
// SQL: ALTER TABLE t ADD COLUMN age INT DEFAULT 0
//
// Parse tree:
//   T_ALTER_TABLE
//   ├── T_TABLE_NAME (t)
//   └── T_ADD_COLUMN
//       └── T_COLUMN_DEF (age, INT, DEFAULT 0)
```

---

## 8. 错误处理

### 8.1 错误类型

| 阶段 | 错误 |
|------|------|
| **Lexer** | 无效字符、未闭合字符串 |
| **Parser** | 语法错误、unexpected token |
| **Resolver** | 表/列不存在、模糊引用 |
| **Type Check** | 类型不匹配、函数参数错误 |

### 8.2 错误恢复

```cpp
// Parser 用 Bison error recovery
%{
int yyerror(const char *msg) {
  parser->set_error(msg, yylineno);
  // 1. 跳过当前 token
  // 2. 找到下一个同步点(分号 / EOF)
  // 3. 继续解析后续语句
}
%}
```

错误不影响整个 SQL 流的处理——只标记当前 statement 出错。

---

## 9. 性能优化

### 9.1 Parse Cache

```cpp
// src/sql/plan_cache/ob_parse_cache.cpp:50
// 缓存解析结果,相同 SQL 跳过 parse
class ObParseCache {
public:
  // key = sql_id
  // value = parsed stmt + resolve result
  std::optional<ObStmt *> get_parse_result(uint64_t sql_id);

  // LRU 淘汰
};
```

### 9.2 并行 Parse

```cpp
// 多 statement 并行 parse(独立)
int ObParser::parse_multi_sql(const ObString &sql, ParseResult &result) {
  // 1. 切分 SQL 流(按 ;)
  auto stmts = split_sql(sql);
  // 2. 并行解析
  parallel_for(stmts, [&](auto &stmt) {
    parse_stmt(stmt);
  });
  return OB_SUCCESS;
}
```

### 9.3 Parse 性能监控

```sql
SELECT * FROM oceanbase.__all_virtual_parse_stat\G

-- 关键字段:
-- parse_count_: 每秒 parse 次数
-- parse_time_us_: 平均 parse 耗时
-- resolve_time_us_: 平均 resolve 耗时
-- cache_hit_count_: parse cache 命中次数
```

---

## 10. 与 v2 主线的连接

```
SQL text
  ↓ #19 (本文: Parser + Resolver + Type Check)
    ↓
  Resolved Stmt
    ↓
  #17 (Optimizer: 选 plan + cost model)
    ↓
  Logical Plan
    ↓
  #18 (Index Selection)
    ↓
  #41 / #24 (Join + PX execution)
    ↓
  #14-#16 (MemTable)
    ↓
  #51 (Block Cache)
    ↓
  #22 (Clog)
    ↓
  #11 (Trans Service / Lock)
```

---

## 11. 调优 Checklist

```
□ 大 SQL 是否用 prepared statement?(减少 parse 开销)
□ 是否启用 plan cache?(接 #17)
□ 大小写是否一致?(避免重复 cache miss)
□ 函数解析是否慢?(用户自定义函数可能慢)
□ Schema 是否提前 fetch?(避免 resolver 阻塞)
□ 多语句是否批处理?(减少往返)
```

---

## 12. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → #28 v2 → **#19 
v2 (本文)** 是 OB **storage / index / CBO / join / cache / 调优 / 日志 /
事务 / schema / 并行 / HA / 容灾 / 多租户 / parser** 全主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObKeyBTree | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| #29 v2 | Slow Query | 运维层 | 捕获 + 分析 + 推荐 + 调优 |
| #22 v2 | Clog / Redo Log | 持久化层 | WAL + group commit + replica + recovery |
| #11 v2 | Trans Service / Lock | 事务层 | 全局事务 ID + 行锁 + 2PC + 死锁 + SI |
| #21 v2 | Schema / DDL | 元数据层 | schema_version + INSTANT/INPLACE + Online DDL |
| #24 v2 | PX Framework | 并行层 | Worker Pool + Task 调度 + Data Exchange + DAS |
| #26 v2 | Primary / Standby | HA 层 | Paxos + 选主 + failover + 副本同步 |
| #33 v2 | Backup / Recovery | 容灾层 | 全量+增量+archive log + PIT + 容灾策略 |
| #28 v2 | Resource / Unit / Tenant | 多租户层 | 3 层模型 + 隔离机制 + 资源调度 |
| **#19 v2 (本文)** | **SQL Parser** | **前端层** | **Lexer + Parser + Resolver + Type Check + Fingerprint** |

十六篇连起来,读者能完整理解 OB 的"SQL 文本 → 执行"全链路:

- 输入:#19 (本文:SQL Parser + Resolver)
- 优化:#17 (CBO) + #18 (Index)
- 执行:#41 (Join) + #24 (PX)
- 存储:#14/#15/#16 (MemTable) + #51 (Cache) + #22 (Clog)
- 事务:#11 (Trans Service)
- 元数据:#21 (Schema)
- 多租户:#28 (Tenant/Unit)
- HA:#26 (Failover) + #33 (Backup)
- 调优:#29 (Slow Query)

---

## 13. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **Compaction Strategy** — minor freeze / major freeze / SSTable merge
- **RPC / obrpc** — 跨 OBServer 通信(接 #11 2PC)
- **Monitoring / Alerting** — ASH 深入 + metrics(接 #29)
- **Partition Management** — rebalance / migration(接 #26)
- **#20-#40 / #42-#100 系列**（待确认具体编号）

继续哪一篇?

---

## 14. 参考(可执行的源码锚点)

- `src/sql/parser/ob_parser.cpp` — Parser 入口
- `src/sql/parser/ob_token_type.h` — Token 类型
- `src/sql/parser/ob_lexer.cpp` — Lexer
- `src/sql/parser/sql_parser.y` — Bison grammar
- `src/sql/parser/parse_node.h` — Parse Node
- `src/sql/parser/parse_stmt.h` — Parse Result
- `src/sql/plan_cache/ob_resolver.cpp` — Resolver
- `src/sql/parser/ddl_parser.cpp` — DDL Parser
- `src/sql/plan_cache/ob_parse_cache.cpp` — Parse Cache
- `src/sql/plan_cache/ob_sql_id.cpp` — SQL Fingerprint
- `src/sql/parser/parse_keyword.cpp` — 关键字表

---

#19 v2 完。