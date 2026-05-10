# Aura C++26 模块分析

通过 doom-lsp (clangd) 对 Aura 编译器核心进行静态分析。

---

## 项目概述

Aura 的 C++ 后端使用 C++26 模块（`.ixx`）实现，分为三层：

| 层 | 模块 | 职责 | 符号数 |
|----|------|------|--------|
| Core | `aura.core.arena` | ASTArena  bump allocator | 9 |
| Core | `aura.core.ast` | 8 种节点类型 + Expr 变体 | 62 |
| Parser | `aura.parser.lexer` | S 表达式词法分析 | 31 |
| Parser | `aura.parser.parser` | 递归下降解析器 | 21 |
| Compiler | `aura.compiler.frontend` | 求值器 + 环境 + 闭包 | 45 |

总计：**168 个符号**（仅接口单元，实现单元因 C++20 模块限制不可见）

---

## 核心层 (core/)

### arena.ixx — ASTArena 内存池

```
9 symbols:
  struct ASTArena       @ 6    main allocator
  #f ASTArena           @ 8    constructor
  #f create             @ 9    template alloc + construct
  #f reset              @ 16   bulk deallocation
  #f used               @ 17   diagnostic
  field buffer_         @ 19   std::vector<std::byte>
  field pos_            @ 20   bump pointer
```

单文件，零依赖。单调 bump 分配器，`create<T>()` 分配 + placement new。

### ast.ixx — Expr AST 节点

```
62 symbols:
  struct Expr           @ 6    forward decl
  struct SourceLocation @ 8    file:line:col
  struct ParsedPhase    @ 9    Phase descriptor (Trees that Grow)
  #f NodeTag            @ 11   8 tags
  struct LiteralIntNode @ 16   tag + int64
  struct VariableNode   @ 17   tag + string
  struct CallNode       @ 18   tag + Expr* + vector<Expr*>
  struct IfExprNode     @ 19   tag + 3 x Expr*
  struct LambdaNode     @ 20   tag + params + body
  struct LetNode        @ 21   tag + name + val + body
  struct LetRecNode     @ 22   tag + name + val + body
  struct DefineNode     @ 23   tag + name + val
  struct Expr           @ 25   variant<8 types> + 8 constructors
```

核心数据结构。8 种节点类型通过 `std::variant` 实现 tagged union。每个节点有 per-node-type 的扩展槽（Trees that Grow 模式）。

**关键设计**：`Expr` 是聚合类型（aggregate），没有虚函数，没有 RTTI。所有构造通过 `std::visit` 模式匹配分发。

---

## 解析层 (parser/)

### lexer.ixx — S 表达式词法分析

```
31 symbols:
  #f TokenKind          @ 6    6 种 token
  struct Token          @ 7    kind + text + line:col
  struct Lexer          @ 9    peek/consume/eof
```

手工词法分析器，支持：整数、标识符、括号、注释（`;`）。运算符标识符支持 `+ - * / = < > !` 等。

### parser.ixx — 递归下降解析器

```
21 symbols:
  struct ParseResult    @ 8    root + success + error
  struct Parser         @ 10   12 个递归方法
  #f parse              @ 13   entry point
  #f parse_expr         @ 15   main dispatch
  #f parse_if / parse_lambda / parse_let / parse_define  @ 16
  #f parse_val          @ 17   value in let binding
```

递归下降 + 特殊形式识别。`(let ((x 1) (y 2)) body)` desugar 为嵌套 `LetNode`。

---

## 编译层 (compiler/)

### frontend.ixx — 求值器

```
45 symbols:
  struct Primitives     @ 9    9 个内置运算符
  struct Env            @ 17   带 parent 链的 lexical scope
  var CLOSURE_SENTINEL  @ 35   闭包 ID 哨兵 (0x1000000)
  var CELL_SENTINEL     @ 36   可变 cell 哨兵 (0x2000000)
  struct Closure        @ 38   params + body + captured env
  struct EvalResult     @ 39   success + int_value + error
  struct Evaluator      @ 41   top env + primitives + closure table
  #f eval_in            @ 46   8 种节点分发
  #f apply_closure      @ 50   closure application
  #f copy_env           @ 51   arena-backed env capture
```

树遍历求值器。核心是 `eval_in` 使用 `std::visit` 对 8 种节点进行模式匹配。闭包通过 `CLOSURE_SENTINEL + id` 编码为 int64 传递。letrec 通过 `CELL_SENTINEL + idx` 实现可变 cell 自引用。

---

## 架构数据流

```
source text
    │
    ▼
Lexer (tokenize)
    │
    ▼
Parser (recursive descent)
    │
    ▼
Arena (memory pool)
    │
    ▼
Expr (variant-based AST)
    │
    ▼
Evaluator (tree-walking interpreter)
    │
    ▼
EvalResult (int64 or error)
```

---

## clangd 兼容性说明

clangd 对 C++20 模块的支持有限：

| 文件类型 | clangd 索引 | 原因 |
|---------|------------|------|
| `.ixx` 接口单元 | ✅ 168 个符号 | clangd 支持模块接口 |
| `_impl.cpp` 实现单元 | ❌ 不可见 | clangd 不支持模块实现单元 |
| `import` 语句 | ❌ 不解析 | clangd 不处理跨模块引用 |

这意味着 `frontend_impl.cpp`（eval_in、apply_closure 等核心逻辑）对静态分析工具不可见。
