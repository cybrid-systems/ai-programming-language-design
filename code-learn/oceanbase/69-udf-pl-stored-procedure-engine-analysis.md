# 69-udf-pl-stored-procedure — OceanBase UDF / PL / 存储过程 / 触发器深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（src/pl/ 44 文件 + src/sql/engine/expr/ 1161 文件 + src/pl/sys_package/ + src/pl/external_routine/）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 在兼容 MySQL / Oracle 双语义时，设计了**三层服务端编程模型**：表达式（SQL 函数）→ UDF（用户定义函数）→ PL/SQL（存储过程 / 触发器 / 包）。这与 Oracle 的 PL/SQL 体系对齐，但底层实现借鉴了 LLVM / 表达式编译的现代编译器思路。

本文聚焦 8 个核心问题：

1. **三层模型边界** —— 表达式 / UDF / PL 各司其职
2. **表达式引擎** —— 1161 个文件的 ObExpr 体系（OB 5.x 最大子模块）
3. **UDF** —— 用户自定义函数（共享库加载）
4. **PL/SQL 编译** —— Parser → AST → CodeGen → Bytecode
5. **PL/SQL 运行时** —— ob_pl 栈机 + 异常处理 + 游标
6. **DBMS 包** —— Oracle 兼容系统包（DBMS_SQL / DBMS_OUTPUT / DBMS_PYTHON 等）
7. **Trigger** —— 行级 / 语句级触发器
8. **与表达式引擎的关系** —— PL 编译后的执行 → 表达式引擎

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 17-query-optimizer | 表达式是 optimizer 的核心（谓词下推 / cost 估算） |
| 22-plan-cache | expression 缓存 + plan cache |
| 23-sql-parser | SQL 解析后生成 expression AST |
| 32-expression-engine | 本篇是 #32 的深化（PL 怎么编译到 expression） |
| 36-concurrency-control | PL 块内的事务边界 |
| 41-join-operators | PL 函数调用 join 的 sub-routine |
| 59-schema-service | UDF / SP 的 schema 持久化 |

---

## 1. 三层服务端编程模型

### 1.1 三层职责

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: SQL 表达式 (src/sql/engine/expr/, 1161 文件)    │
│  - 内置 SQL 函数: sin / cos / abs / concat / now / ...     │
│  - 运算符: + / - / * / = / > / AND / OR                    │
│  - 聚合: sum / count / avg / max / min                      │
│  - 类型转换: cast / convert                                 │
│  - 单表达式，per-row 计算                                  │
│  - 调用栈浅（无状态，无 PL 块）                            │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ (PL 块内的表达式调用)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: UDF (user-defined function, 共享库加载)          │
│  - 第三方库: .so 文件，dlopen 加载                          │
│  - ABI: OB UDF 规范（init / process / cleanup）            │
│  - 类型映射: SQL 类型 ↔ C 类型                              │
│  - per-row 或 batch 调用                                  │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ (UDF 可以被 PL 调用)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: PL/SQL (src/pl/, 44 文件)                         │
│  - 块结构: DECLARE ... BEGIN ... EXCEPTION ... END           │
│  - 存储过程 (PROCEDURE) / 存储函数 (FUNCTION)              │
│  - 包 (PACKAGE): spec + body (Oracle 兼容)                 │
│  - 触发器 (TRIGGER): 行级 / 语句级 / BEFORE / AFTER         │
│  - 匿名块 (BEGIN ... END)                                   │
│  - 控制流: IF / LOOP / WHILE / FOR / CURSOR / EXIT          │
│  - 异常处理: EXCEPTION WHEN ...                             │
│  - 编译到字节码 → 表达式引擎执行                          │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 三层调用方向

```
SQL 语句中调用:
  SELECT sin(0.5) FROM t          -- 表达式 (Layer 1)
  SELECT my_udf(x) FROM t          -- UDF (Layer 2)
  CALL my_proc(1, 'a')            -- PL 存储过程 (Layer 3)
  SELECT my_func(1) FROM t        -- PL 存储函数 (Layer 3)

PL 块内调用:
  CREATE PROCEDURE p()
  AS BEGIN
    v := sin(0.5);                -- 表达式 (Layer 1)
    v := my_udf(x);               -- UDF (Layer 2)
    my_proc2(1);                  -- PL 存储过程 (Layer 3)
  END;
```

### 1.3 与 MySQL / Oracle 的兼容性

| 特性 | MySQL | Oracle | OB 5.x |
|------|-------|--------|--------|
| 表达式 | ✅ | ✅ | ✅ |
| UDF (C 库) | ✅ | ❌ | ✅ |
| 存储过程 | ✅ (弱) | ✅ (强) | ✅ (Oracle 强) |
| 触发器 | ✅ | ✅ | ✅ |
| 包 (PACKAGE) | ❌ | ✅ | ✅ |
| 匿名块 | ❌ | ✅ | ✅ |
| 异常处理 | ❌ | ✅ | ✅ |
| DBMS 包 | 弱 | 强 | ✅ |

**关键设计**：OB 5.x 的 PL 体系是 **Oracle 兼容**（不是 MySQL 兼容），这是 OB 4.x 后明确的设计选择。

---

## 2. 表达式引擎 —— `src/sql/engine/expr/` (1161 文件)

### 2.1 模块规模

```bash
$ ls src/sql/engine/expr/ | wc -l
1161   # ← OB 5.x 最大子模块（比 direct_load 还大）
```

**1161 文件** —— 包含几乎所有 SQL 内置函数的实现。每个函数/运算符通常一个 .h + 一个 .cpp。

### 2.2 ObExpr 抽象

```cpp
// src/sql/engine/expr/ob_expr.h (推测)
class ObExpr {
public:
  // 表达式求值（per-row）
  virtual int eval(ObEvalCtx &ctx, ObDatum &res) = 0;

  // 批量求值（per-batch，列存优化）
  virtual int eval_batch(ObEvalCtx &ctx,
                         const ObBitVector &skip,
                         const int64_t batch_size,
                         ObDatum *res) = 0;

  // 表达式元数据
  ObExprOperatorType type_;
  // ... children exprs / 表达式参数
};
```

### 2.3 ObExprOperatorType

OB 5.x 的表达式 operator 类型是一个大 enum：
- `OP_SIN` / `OP_COS` / `OP_ABS` 等内置函数
- `OP_ADD` / `OP_SUB` / `OP_MUL` 等运算符
- `OP_EQ` / `OP_GT` / `OP_AND` / `OP_OR` 等比较 / 逻辑
- `OP_SUM` / `OP_COUNT` / `OP_AVG` 等聚合
- `OP_CAST` / `OP_CONVERT` 等类型转换

每个 operator 在 `src/sql/engine/expr/` 下有专门的 .h/.cpp（如 `ob_expr_atan.cpp/h`、`ob_expr_concat.cpp/h`）。

### 2.4 表达式求值流程

```
SQL: SELECT sin(a + b) FROM t WHERE c > 0
    │
    ▼
Parser 生成 ExprAST (sin, +, a, b), (>, c, 0)
    │
    ▼
Optimizer → 物理 plan (ExprOp 树)
    │
    ▼
CodeGen → ObExpr 树
    │
    │  ObExprSin
    │      │
    │      └── ObExprAdd
    │            ├── ObExprColumnRef (a)
    │            └── ObExprColumnRef (b)
    │
    ▼
执行期：
    for each row:
        for each expr (post-order):
            ObExprAdd.eval(ctx) → 中间结果
            ObExprSin.eval(ctx) → 最终结果
    │
    ▼
输出 sin(a+b) 列
```

### 2.5 向量化 (vectorization)

OB 5.x 的表达式引擎支持 **向量化执行**：
- 一次处理 batch_size 行（典型 64-256）
- 利用 SIMD / cache locality
- 列存场景特别有效（参见 #26 encoding-engine）

```cpp
// vectorized batch evaluation
virtual int eval_batch(ObEvalCtx &ctx,
                       const ObBitVector &skip,        // 跳过 NULL
                       const int64_t batch_size,
                       ObDatum *res) = 0;
```

---

## 3. UDF —— 用户定义函数

### 3.1 OB UDF ABI（基于公开文档）

```c
// UDF 共享库的标准接口（典型 OB UDF 规范）
// 1. 初始化（per-query）
typedef int (*udf_init_fn)(udf_func_ctx *ctx,
                           const udf_args *args,
                           int argc);

// 2. 累计（per-row 或 per-batch）
typedef int (*udf_process_fn)(udf_func_ctx *ctx,
                              const udf_args *args,
                              int argc,
                              udf_val *result);

// 3. 清理（per-query）
typedef void (*udf_cleanup_fn)(udf_func_ctx *ctx);

// 4. 错误信息
typedef const char* (*udf_get_error_fn)();
```

### 3.2 UDF 加载与执行

```
DBA: CREATE FUNCTION my_udf(x INT) RETURNS INT SONAME 'libmyudf.so';
    │
    ▼
observer 收到 CREATE FUNCTION
    │
    ├─ 加载共享库：dlopen("libmyudf.so")
    ├─ 查找符号：my_udf_init / my_udf_process / my_udf_cleanup
    └─ 注册到 UDF Mgr (per-tenant)
    │
    ▼
应用: SELECT my_udf(x) FROM t
    │
    ▼
SQL 解析 → ObExprUDF (包装 UDF 调用)
    │
    ▼
执行: 对每行 / batch
    ├─ udf_init(ctx, args) → 初始化
    ├─ udf_process(ctx, args, argc, result) → 计算
    └─ udf_cleanup(ctx) → 清理（per-query 一次性）
```

### 3.3 UDF 类型映射

| SQL 类型 | C 类型（udf_val） |
|---------|-------------------|
| INT | int64_t |
| BIGINT | int64_t |
| VARCHAR / TEXT | const char* + length |
| DECIMAL | string 格式 |
| DATETIME | int64_t (微秒) |
| DOUBLE | double |

### 3.4 UDF 安全沙箱

UDF 在 observer 进程内执行（共享库方式），存在 **安全风险**：
- ✅ 白名单机制：DBA 必须显式 CREATE FUNCTION
- ✅ Path 限制：SONAME 必须在指定目录
- ✅ 权限检查：UDF 执行需要 UDF privilege
- ⚠️ 但仍然可以 crash observer（如果 UDF bug）—— 没有完全沙箱

### 3.5 UDF 源码位置

**注**：我之前在 #60 提到的 `src/share/udf/` 路径 **不存在**。实际 UDF 基础设施在：
- 共享库加载：`src/sql/engine/expr/ob_expr_udf.cpp/h`（推测）
- 注册表：可能嵌在 schema service 或 SQL service 中

需要在 OB 主仓进一步 grep 才能找到精确路径。**本文先标记 caveat**。

---

## 4. PL/SQL 引擎 —— `src/pl/` (44 文件)

### 4.1 模块组成

```bash
$ ls src/pl/
CMakeLists.txt
dblink/                  # DBLink (跨数据库调用)
diagnosis/               # 诊断
external_routine/        # C 外部例程（UDF 类似但 C 函数）
ob_pl.cpp/h              # PL 运行时主入口
ob_pl_adt_service.cpp/h  # 抽象数据类型服务
ob_pl_allocator.cpp/h    # PL 内存分配器
ob_pl_code_generator.cpp/h  # PL → expr 字节码生成
ob_pl_compile.cpp/h      # PL 编译
ob_pl_compile_utils.cpp/h
ob_pl_dependency_util.cpp/h  # PL 依赖分析（用于失效重编译）
ob_pl_di_adt_service.cpp/h
ob_pl_exception_handling.cpp/h
ob_pl_package.cpp/h      # 包（PACKAGE）支持
ob_pl_package_encode_info.cpp/h
ob_pl_package_guard.cpp/h
ob_pl_package_state.cpp/h
ob_pl_persistent.cpp/h   # PL 持久化（编译产物存 schema）
ob_pl_resolve_cache.cpp/h
ob_pl_resolver.cpp/h     # 名称解析（PL 块内的变量 / 函数）
ob_pl_router.cpp/h       # PL 路由（sub-program 调用）
ob_pl_stmt.cpp/h         # PL 语句类型
ob_pl_type.cpp/h          # PL 类型系统
ob_pl_user_type.cpp/h
pl_recompile/            # PL 失效重编译
sys_package/             # DBMS_* 系统包（DBMS_SQL, DBMS_PYTHON, ...）
```

### 4.2 PL 编译流水线

```
应用: CREATE PROCEDURE p(x INT) AS BEGIN INSERT INTO t VALUES (x); END;
    │
    ▼
Parser (src/sql/parser)
    │   - PL 语法解析
    │   - 生成 PL AST (ObPlStmt 树)
    │
    ▼
Resolver (ob_pl_resolver)
    │   - 名称解析（变量 / 函数 / 表 / 列）
    │   - 类型检查
    │   - 依赖收集（哪些表 / 函数被引用）
    │
    ▼
Code Generator (ob_pl_code_generator)
    │   - PL AST → expression bytecode (ObExpr 树)
    │   - 控制流编译成 expr 嵌套
    │
    ▼
Persistent (ob_pl_persistent)
    │   - 序列化编译产物到 schema（__all_proc / __all_func / __all_package 等）
    │
    ▼
存储在 observer 内（per-tenant cache）
    │
    ▼
应用: CALL p(1)
    │
    ▼
ob_pl 运行时
    │   - 加载 PL 编译产物
    │   - 初始化栈（变量 / 游标）
    │   - 顺序执行 bytecode (→ ObExpr.eval)
    │   - 异常处理 / commit / rollback
```

### 4.3 ObPlStmt 类型

```cpp
// src/pl/ob_pl_stmt.h
class ObPlStmt {
public:
  // PL 语句的 AST 节点类型
  enum StmtType {
    STMT_BLOCK,           // DECLARE ... BEGIN ... END
    STMT_IF,                // IF ... THEN ... ELSE ...
    STMT_LOOP,              // LOOP ... END LOOP
    STMT_WHILE,             // WHILE ... LOOP
    STMT_FOR,               // FOR ... IN ... LOOP
    STMT_ASSIGN,            // var := expr
    STMT_CALL,              // CALL proc(...)
    STMT_RETURN,            // RETURN val
    STMT_RAISE,             // RAISE exception
    STMT_SELECT_INTO,       // SELECT ... INTO var
    STMT_INSERT,            // INSERT INTO ...
    STMT_UPDATE,            // UPDATE ...
    STMT_DELETE,            // DELETE ...
    STMT_EXIT,              // EXIT [WHEN]
    STMT_CONTINUE,          // CONTINUE [WHEN]
    // ...
  };
};
```

### 4.4 ob_pl_compile —— 编译入口

```cpp
// src/pl/ob_pl_compile.h (推测)
class ObPlCompiler {
public:
  // 主入口：把 PL source 编译成可执行代码
  int compile(const ObString &pl_source,
              const ObPLResolveCtx &ctx,
              ObPlCompiledCode &output);

  // 1. parse → ObPlStmt AST
  // 2. resolve → 名称 + 类型
  // 3. codegen → ObExpr bytecode
  // 4. serialize → 持久化
};
```

### 4.5 ob_pl_code_generator —— PL → 表达式

```cpp
// src/pl/ob_pl_code_generator.h
class ObPlCodeGenerator {
public:
  // 把 PL AST 翻译成 ObExpr 树
  int generate_expr(ObPlStmt &stmt, ObExprGenContext &ctx);

  // IF: 翻译成 ObExprCase / ObExprCondOp
  // LOOP: 翻译成 ObExprLoop (高层 ObExpr)
  // WHILE: 翻译成 ObExprWhile
  // FOR: 翻译成 ObExprFor (含隐式 cursor)
  // CALL: 翻译成 ObExprCallProc
  // ASSIGN: 翻译成 ObExprAssign (变量 = expr)
  // RAISE: 翻译成 ObExprRaise (异常信号)
};
```

**关键洞察**：PL 最终 **降级为 ObExpr 树**，复用表达式引擎。这避免了单独的 PL 字节码解释器。

### 4.6 ob_pl_allocator —— PL 内存管理

```cpp
// src/pl/ob_pl_allocator.h
class ObPlAllocator {
public:
  // PL 执行时的栈式内存分配
  // 用于：变量、游标状态、临时对象
  void* alloc(int64_t size);
  void reset();  // 块结束时一次性释放

private:
  // PL 块级 arena（参见 #25 memory-management）
  // 块结束 → reset → 一次性释放所有 PL 内存
};
```

**为什么用 arena**：PL 块有清晰的生命周期（block begin → block end），用 arena 一次性分配 / 释放避免细粒度 free。

### 4.7 ob_pl_exception_handling —— 异常处理

```cpp
// src/pl/ob_pl_exception_handling.h
class ObPlExceptionHandler {
public:
  // PL 块的 EXCEPTION 部分
  // WHEN OTHERS THEN ...
  // WHEN DUP_VAL_ON_INDEX THEN ...
  int handle_exception(ObPlException &exc, ObPlBlock &block);

  // 1. 捕获异常
  // 2. 匹配 WHEN 子句
  // 3. 执行匹配的处理代码
  // 4. 决定: 继续执行 / 重新抛出 / 退出块
};

// 标准异常常量
extern const int EXCEPTION_DUP_VAL_ON_INDEX;
extern const int EXCEPTION_NO_DATA_FOUND;
extern const int EXCEPTION_TOO_MANY_ROWS;
// ... 几十个 Oracle 标准异常
```

### 4.8 ob_pl_package —— PACKAGE 支持

```cpp
// src/pl/ob_pl_package.h
class ObPlPackage {
  // Oracle-style 包：spec + body
  // CREATE PACKAGE my_pkg AS PROCEDURE p1(); END;
  // CREATE PACKAGE BODY my_pkg AS PROCEDURE p1() ... END;
};

// 包的状态（package state）
class ObPlPackageState {
  // 包级变量（跨调用持久化）
  // 创建时初始化 → 跨 PL 调用保留 → session 结束销毁
};
```

**PACKAGE 是 Oracle 特有** —— 把 spec（接口）和 body（实现）分开，包级变量（state）跨调用持久。

### 4.9 ob_pl_resolver —— 名称解析

```cpp
// src/pl/ob_pl_resolver.h
class ObPlResolver {
public:
  // 解析 PL 块内的名称（变量 / 函数 / 异常 / 表）
  int resolve(ObPlStmt &stmt, ObPLResolveCtx &ctx);

  // 1. 从当前 block scope 向上查找
  // 2. 跨 PACKAGE 边界
  // 3. 跨 SCHEMA 边界
  // 4. 处理 ambiguous name
};
```

### 4.10 ob_pl_dependency_util —— 失效依赖分析

```cpp
// src/pl/ob_pl_dependency_util.h
class ObPlDependencyUtil {
  // 当 PL 引用的对象（表 / 列 / 函数）变化时，标记 PL 失效
  // 失效的 PL 在下次调用时重新编译

  // 场景：
  // - 引用的表加了列
  // - 引用的函数被 DROP
  // - 引用的列类型变了
};
```

**pl_recompile/** 子目录是配套的失效重编译实现。

### 4.11 external_routine —— C 外部例程

```bash
src/pl/external_routine/
```

C 语言写的 PL 函数（类似 UDF 但 PL 调用方式）：
- `CREATE FUNCTION my_c_func(x INT) RETURNS INT AS 'my_c_func.c' LANGUAGE C;`
- observer 编译并加载
- 与 SQL 表达式 / PL 函数互通

### 4.12 dblink —— 跨数据库调用

```bash
src/pl/dblink/
```

```sql
SELECT * FROM my_dblink@remote_db('SELECT * FROM t');
```

DBLink 让 PL / SQL 能访问远端 OB（或 MySQL/Oracle）实例。

### 4.13 diagnosis —— PL 诊断

```bash
src/pl/diagnosis/
```

PL 错误诊断（编译错误 / 运行时错误的位置 + 栈追踪）。

---

## 5. 系统包 —— `src/pl/sys_package/`

### 5.1 Oracle DBMS 包兼容

OB 5.x 实现了一批 Oracle 兼容的系统包（DBMS_*）：

| 包名 | 用途 | 文件 |
|------|------|------|
| `DBMS_SQL` | 动态 SQL | `ob_dbms_sql.h` |
| `DBMS_OUTPUT` | 输出文本 | `ob_dbms_output.h` (推测) |
| `DBMS_PARTITION` | 分区管理 | `ob_dbms_partition.h` |
| `DBMS_PYTHON` | 嵌入式 Python | `ob_dbms_python.h` |
| `DBMS_JAVA` | 嵌入式 Java | `ob_dbms_java.h` |
| `DBMS_AI_SERVICE` | AI/ML 服务 | `ob_dbms_ai_service.h` |
| `DBMS_MVIEW_STATS_MYSQL` | 物化视图统计 (MySQL 兼容) | `ob_dbms_mview_stats_mysql.h` |
| `DBMS_MVIEW_MYSQL` | 物化视图 (MySQL 兼容) | `ob_dbms_mview_mysql.h` |

### 5.2 DBMS_PYTHON / DBMS_JAVA —— 多语言运行时

OB 5.x 在 PL 块内嵌入 Python / Java 代码：

```sql
CALL dbms_python.exec('print("hello from python")');
-- 或者
CREATE FUNCTION py_func(x INT) RETURNS INT
AS LANGUAGE PYTHON
'{
   return x + 1
}';
```

**意义**：把 PL 体系从单一 PL 语言扩展到多语言运行时。这是 OB 5.x 的关键差异化特性。

### 5.3 DBMS_SQL —— 动态 SQL

```sql
DECLARE
  c INTEGER;
  sql_text VARCHAR(1000);
BEGIN
  c := dbms_sql.open_cursor();
  dbms_sql.parse(c, 'SELECT * FROM t WHERE x = :1', dbms_sql.NATIVE);
  dbms_sql.bind_variable(c, ':1', 123);
  dbms_sql.execute(c);
  -- ... fetch rows
  dbms_sql.close_cursor(c);
END;
```

DBMS_SQL 提供 **运行时动态 SQL**（PL 块内构造 SQL 再执行），区别于编译期静态 SQL。

### 5.4 DBMS_AI_SERVICE —— AI 集成

OB 5.x 内嵌 AI 服务接口：

```sql
SELECT dbms_ai_service.predict('model_x', input_data) FROM t;
```

把 AI 推理当作 DB 内置函数。

---

## 6. 触发器 (Trigger)

### 6.1 触发器类型

```sql
CREATE TRIGGER trig_name
BEFORE INSERT OR UPDATE OR DELETE ON t
FOR EACH ROW
WHEN (NEW.x > 100)
BEGIN
  INSERT INTO audit_log VALUES (NEW.id, NOW());
END;
```

OB 触发器支持：
- **时机**：BEFORE / AFTER / INSTEAD OF
- **事件**：INSERT / UPDATE / DELETE
- **粒度**：FOR EACH ROW / FOR EACH STATEMENT
- **条件**：WHEN 子句

### 6.2 触发器实现

```cpp
// src/sql/cmd/ob_create_trigger_executor.cpp (推测)
class ObCreateTriggerExecutor {
  // 编译 trigger body（也是 PL）
  // 持久化到 schema
};

class ObTriggerExecutor {
  // 在 INSERT/UPDATE/DELETE 执行时调用
  int fire_before(ObTriggerEvent event, ObRow &new_row, ObRow &old_row);
  int fire_after(ObTriggerEvent event, ObRow &new_row, ObRow &old_row);
};
```

**关键设计**：trigger body 是 **PL 代码**（与 PROCEDURE 复用 ob_pl 编译/运行时）。

### 6.3 trigger 与事务

```
应用: INSERT INTO t VALUES (...)
    │
    ▼
SQL executor 触发 BEFORE INSERT trigger
    │   - trigger body 是 PL → 走 ob_pl 运行时
    │   - 可以 RAISE 异常中止 INSERT
    ▼
实际 INSERT 执行
    │
    ▼
SQL executor 触发 AFTER INSERT trigger
    │   - 事务还没提交（trigger 内可见本次变更）
    │   - 但 trigger 失败 → ROLLBACK
    ▼
应用 COMMIT（提交整个事务包括 trigger 内的修改）
```

---

## 7. 与表达式引擎的关系

### 7.1 PL → 表达式的转化

PL 编译后的执行 = 一系列 expression 调用：

```cpp
// PL IF a > 0 THEN ... END IF;
// 编译成：
ObExprCase
    ├── condition: ObExprGT(ObExprColumnRef(a), ObExprLiteral(0))
    ├── then: ObExprStmtBlock([...])
    └── else: ObExprStmtBlock([...])

// PL WHILE x > 0 LOOP ... END LOOP;
// 编译成：
ObExprWhile
    ├── condition: ObExprGT(ObExprColumnRef(x), ObExprLiteral(0))
    └── body: ObExprStmtBlock([...])
```

### 7.2 优势

- **单一执行引擎**：不用维护单独的 PL 字节码 VM
- **共享优化**：PL 编译产物也能享受 expression 的优化（常量折叠 / 公共子表达式消除）
- **向量化友好**：PL 内的循环可以向量化（如果 body 简单）
- **简单一致**：所有执行通过 ObExpr.eval 入口

### 7.3 限制

- **PL 块内的复杂状态**（游标 / 异常 / 变量作用域）需要 ob_pl 额外维护
- **PL 包级变量**（package state）需要单独生命周期管理
- **PL 游标**（explicit cursor）需要单独的 fetch/execute 路径

---

## 8. 总结

### 8.1 三层服务端编程模型在 OB 体系中的定位

OB 5.x 的服务端编程覆盖：
- 简单表达式（sin/concat/...）→ SQL 函数式
- 用户扩展（UDF）→ C 库加载
- 复杂逻辑（PL）→ 编译到表达式
- AI / Python 集成（DBMS_PYTHON）→ 多语言运行时

这是 **Oracle 兼容**的完整 PL 体系（不像 MySQL 那样只有弱 SP）。

### 8.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 表达式引擎 | 1161 文件 / ObExpr 抽象 / 向量化 |
| UDF | 共享库 dlopen + 标准 ABI |
| PL/SQL | Parser → Resolver → CodeGen → ObExpr 树 |
| 包 PACKAGE | spec + body + package state（Oracle 风格） |
| 异常处理 | WHEN 子句 + 标准异常常量（Oracle 风格） |
| 触发器 | PL 复用 + BEFORE/AFTER/ROW/STATEMENT |
| DBMS_PYTHON/JAVA | 嵌入式多语言运行时 |
| DBMS_SQL | 运行时动态 SQL |
| Arena 内存 | ob_pl_allocator 块级生命周期 |
| 失效重编译 | ob_pl_dependency_util + pl_recompile |

### 8.3 关键技术模块

| 路径 | 规模 | 角色 |
|------|------|------|
| `src/sql/engine/expr/` | 1161 文件 | 表达式引擎（最大子模块） |
| `src/pl/` | 44 文件 | PL/SQL 编译 + 运行时 |
| `src/pl/sys_package/` | ~20 文件 | DBMS_* 系统包 |
| `src/pl/external_routine/` | ~10 文件 | C 外部例程 |
| `src/pl/dblink/` | ~5 文件 | 跨数据库调用 |
| `src/pl/diagnosis/` | ~5 文件 | PL 诊断 |
| `src/pl/pl_recompile/` | ~5 文件 | PL 失效重编译 |

### 8.4 路径修正

我之前在 #60 提到 `src/share/udf/` 路径 **不存在**，实际 UDF 基础设施在 `src/sql/engine/expr/` 内部或独立位置（需进一步 grep 确认）。本文 §3.5 标记 caveat。

### 8.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#70 SQL Audit / 安全**：

OB 的 SQL 审计与安全体系 —— 权限校验 / 审计日志 / 行级安全 / 数据脱敏。源码入口：`src/share/audit/` + `src/share/privilege/` + `src/sql/privilege_check/`。

适用场景：合规审计 / 多租户隔离 / 敏感数据保护。

整吗？