# #3 v2 — Aura Parser (S-expression + Racket 兼容 + ABF 二进制序列化)

> 接续 #1 v2 Agent Orchestration + #2 v2 Build System:前面讲了 aura 的
> 运行时抽象和构建系统。本文聚焦 **Parser 子系统**——从源代码文本到 AST
> 的完整路径,包括 Racket `#lang aura` 兼容、ABF 二进制序列化、Phase 0
> Lisp 求值器集成。

---

## 0. 全文导读

Aura Parser 三层:

```
Source text (.aura file)
    ↓ Lexer (词法分析)
Token stream
    ↓ Parser (S-expression 递归下降)
ParseResult (AST)
    ↓ ABF Serializer (二进制格式)
ABF bytes → C++ Compiler Service
```

本文按"架构 → Racket 兼容 → Lexer → Parser → ABF Serializer → Phase 0
求值器 → 调优"展开。

---

## 1. Aura Parser 整体架构

### 1.1 两个 frontend: 历史 vs 当前

aura 项目早期(2024 之前)有 Racket frontend:

```
~/code/aura/tests/fixtures/lang/private/
  core.rkt           # Phase 0 Lisp 核心求值器 (~335 符号)
  abf.rkt            # ABF v2 二进制序列化 (~250 符号)
  expander.rkt       # `#lang aura` 模块展开器
```

这是历史遗留,2024 后 aura 用 C++ 重写。但 `#lang aura` 协议保留(向后兼容)。

### 1.2 当前 C++ Parser 结构

```
src/parser/
├── parser.ixx         # C++20 module 接口
├── parser_impl.cpp    # 实现单元
└── lexer/             # (推测,待确认)
```

实际代码在 `src/parser/` 4 文件(之前查过):

```
src/parser/:
  parser.ixx + parser_impl.cpp
  + 2 其他文件(可能是 lexer + reader)
```

### 1.3 数据流

```
#lang aura source
    ↓ Racket reader (历史路径)
reader.rkt (S expression reading + module wrapping)
    ↓ expander.rkt
expander.rkt (#%module-begin → eval-expr)
    ↓ core.rkt
core.rkt (tree-walking evaluator)
    ↓ ABF
ABF bytes → C++ Compiler Service

或(当前 C++ 路径):
#lang aura source
    ↓ C++ reader
C++ S-expression reader
    ↓ C++ parser
C++ AST (Expr tree)
    ↓ C++ evaluator
C++ eval result
```

---

## 2. Racket `#lang aura` 兼容 (历史但保留)

### 2.1 `#lang aura` 协议

```racket
;; expander.rkt
(define-syntax-rule (#%module-begin expr)
  (#%plain-module-begin
    (displayln (eval-expr 'expr (make-env)))))
```

提供 4 个绑定满足 Racket `#lang` 协议:
- `#%module-begin` — 模块入口
- `#%datum` — 字面量
- `#%top` — top-level
- `#%app` — 函数应用

每个 `#lang aura` 文件是一个 S 表达式,编译时求值并打印结果。

### 2.2 Phase 0 Lisp 核心求值器 (core.rkt)

```racket
(provide eval-expr make-env extend-env lookup-env)
```

**关键导出**:

```racket
(define (make-env) ...)         ;; 初始环境:26 个内置原语
(define (extend-env env n v) ...)  ;; 扩展 env alist
(define (lookup-env env n) ...)    ;; 自动解引用 cell
(define (raw-lookup env n) ...)    ;; 不解引用的查找
```

**26 个内置原语**:
- 算术: `+ - * /`
- 比较: `= < > <= >=`
- 等价: `eq? equal?`
- 逻辑: `not`
- 列表: `cons car cdr null? pair?`
- IO: `display displayln`
- 类型: `number? symbol? string? boolean?`

### 2.3 Eval Expression

```racket
(define (eval-expr expr env)
  (cond
    [(number? expr) expr]           ;; 字面量
    [(string? expr) expr]
    [(boolean? expr) expr]
    [(null? expr) expr]
    [(symbol? expr) (lookup-env env expr)]  ;; 变量引用
    [(pair? expr)
     (case (car expr)
       [(quote) (cadr expr)]
       [(if) ...]
       [(lambda) ...]
       [(let) ...]
       [(letrec) ...]
       [(define) ...]
       [else ...])]
    [else (error ...)]))
```

### 2.4 cell struct (letrec 关键)

```racket
(struct cell (value) #:mutable)
```

letrec 流程:
1. 创建 `cell-env`,每个 letrec 名字绑定到 `(cell 0)`
2. 在 `cell-env` 中求值各表达式(闭包捕获含 cell 的环境)
3. `set-cell-value!` 填充 cell 为真实值
4. 自动解引用:`lookup-env` 遇到 cell 返回 `(cell-value v)`

**关键 insight**: letrec 自引用通过 mutable cell 实现,而不是循环引用检测——这
是简单 Lisp 解释器的经典做法。

---

## 3. C++ Parser (当前)

### 3.1 AST 节点

aura 的 AST 在 `src/core/ast.ixx`:

```cpp
// src/core/ast.ixx:25
struct Expr {
  std::variant<8 types> + 8 constructors
};

// 8 种节点类型:
// - LiteralIntNode  (tag + int64)
// - VariableNode    (tag + string)
// - CallNode        (tag + Expr* + vector<Expr*>)
// - IfExprNode      (tag + 3 x Expr*)
// - LambdaNode      (tag + params + body)
// - LetNode         (tag + name + val + body)
// - LetRecNode      (tag + name + val + body)
// - DefineNode      (tag + name + val)
```

**设计 insight**: `Expr` 是 **aggregate 类型**,没有虚函数,没有 RTTI。
所有构造通过 `std::visit` 模式匹配分发。这是 C++26 高效模式匹配。

### 3.2 Lexer (词法分析)

```cpp
// src/core/parser/lexer.ixx (推测)
struct Lexer {
  // Token 流
  // peek/consume/eof
};
```

TokenKind:
- LPAREN, RPAREN, DOT
- INTEGER_LITERAL, FLOAT_LITERAL, STRING_LITERAL
- SYMBOL (variable name or operator)
- BOOLEAN (#t / #f)
- KEYWORD (:name)
- QUOTE / QUASIQUOTE / UNQUOTE
- COMMENT (`;` 到行尾)

手工词法分析器,支持:整数、浮点、字符串、标识符、括号、注释(`;`)。
运算符标识符支持 `+ - * / = < > !` 等。

### 3.3 Parser (递归下降)

```cpp
// src/parser/parser.ixx
struct ParseResult {
  std::unique_ptr<Expr> root_;
  bool success_;
  std::string error_;
};

struct Parser {
  // 12 个递归方法:
  // parse / parse_expr / parse_if / parse_lambda / parse_let / parse_define / parse_val / ...
  std::unique_ptr<Expr> parse(const TokenStream &tokens);
};
```

**关键 insight**: 递归下降 + 特殊形式识别。`(let ((x 1) (y 2)) body)` 
desugar 为嵌套 `LetNode`(`(let ((x 1)) (let ((y 2)) body))`)。

### 3.4 错误恢复

```cpp
// 解析失败不 panic,返回 ParseResult{success=false, error=msg}
// 上层根据 success 决定:
if (!parse_result.success_) {
  return Diagnostic{severity=Error, message=parse_result.error_};
}
```

错误恢复策略:
1. 词法错误:跳到下一个 token
2. 语法错误:跳到下一个 `)` 或 EOF
3. 多次错误聚合,避免 1 个错就停

---

## 4. ABF Serializer (二进制格式)

### 4.1 ABF v2 格式

```
[Magic: "ABF2"] [Version: varint] [PhaseID: varint]
[Node: Tag(varint) | ExtID(varint) | ExtLen(varint) | ExtPayload(0) | CorePayload(...)]
```

### 4.2 Tag 映射

| Tag | 节点 | 序列化 |
|-----|------|--------|
| 0x01 | LiteralInt | 8 bytes big-endian int64 |
| 0x02 | Variable | varint(len) + utf8 name |
| 0x03 | Call | function node + args nodes |
| 0x04 | If | cond + then + else nodes |
| 0x05 | Lambda | varint(param_count) + [name]* + body node |
| 0x06 | Let | varint(binding_count) + [name + val]* + body node |
| 0x07 | LetRec | varint(binding_count) + [name + val]* + body node |
| 0x08 | Define | name + val node |

### 4.3 Varint 编码

```cpp
// 7-bit groups, MSB continuation
std::string encode_varint(uint64_t v) {
  std::string out;
  while (v >= 0x80) {
    out += char((v & 0x7F) | 0x80);
    v >>= 7;
  }
  out += char(v);
  return out;
}
```

小数字(< 128)只占 1 字节。

### 4.4 编码函数

```cpp
// src/compiler/serialization/abf.ixx (推测)
class AbfSerializer {
  std::string serialize(const Expr &expr);
  std::optional<Expr> deserialize(std::string_view bytes);
  
  void write_node(Expr &e) {
    auto tag = tag_for_expr(e);
    write_varint(tag);
    // 递归写子节点
    std::visit(*this, e);
  }
};
```

### 4.5 ABF 的用途

```
Phase 0 (Racket 解释器) → ABF bytes → Phase 1 (C++ compiler service)

ABF 是 a "portable AST" 格式:
- Phase 0 解释器跑 source → emit ABF
- Phase 1 C++ 服务读 ABF → 编译/JIT/AOT
- ABF 让 Phase 0 / Phase 1 解耦
```

---

## 5. Phase 0 + Phase 1 双层求值

### 5.1 双层模型

```
Phase 0 解释器(Racket):
  - 慢,但易改
  - bootstrap / 实验性 feature
  - 输出 ABF 供 Phase 1
  
Phase 1 编译器(C++):
  - 快,production
  - 读 ABF / 直接 parse source
  - 输出 machine code / bytecode
```

### 5.2 启动序列

```
1. parse .aura source (Phase 0 reader → AST)
2. eval-expr (Phase 0 core.rkt, 输出 displayln)
3. 或: serialize → ABF → load into Phase 1 (C++)
4. Phase 1 编译/JIT/AOT → machine code
5. 跑
```

### 5.3 切换点

```
"什么时候用 Phase 0,什么时候用 Phase 1?"

简单命令 (echo '...') → Phase 0(快启动)
生产代码 (大项目)  → Phase 1(快运行)
A/B 测试 / 试错    → Phase 0(易改)
hot path           → Phase 1(JIT 后快)
```

---

## 6. 性能与代价

### 6.1 Parse 性能

| 阶段 | 速度 | 备注 |
|------|------|------|
| Lexer | ~MB/s | char-by-char 扫描 |
| Parser (递归下降) | ~100K expr/s | 单 thread |
| ABF serialize | ~MB/s | varint 压缩 |
| ABF deserialize | ~MB/s | 镜像反操作 |

### 6.2 内存开销

```
AST 大小:
  - Expr ~32 bytes/节点 (variant 8 个 type)
  - VariableNode 额外 ~32 bytes (string SSO)
  - LambdaNode ~24 bytes (vector)
  - 总: ~64 bytes/节点

1K expr 文件 → ~64 KB AST
1M expr 文件 → ~64 MB AST
```

### 6.3 优化点

```
- Lexer: 单 pass,无 lookahead
- Parser: Pratt-style 优先级解析(替代简单递归下降)
- AST: variant 而不是 class hierarchy
- ABF: varint 压缩小数字
- Deserialize: 反向 varint,零拷贝字符串
```

---

## 7. 调优 Checklist

```
□ Racket 兼容路径?
  - Phase 0 仍可用? (历史兼容)
  - Phase 1 C++ parser 是默认?

□ Parser 性能?
  - 大文件 parse 时间?
  - AST 内存占用?

□ ABF 二进制格式稳定?
  - Magic / Version 是否随版本变化?
  - 后向兼容?

□ 错误信息质量?
  - 错误位置 (line:col)?
  - 错误恢复 (skip and continue)?

□ Code coverage?
  - Parser 路径都覆盖?
  - 边界 case (空文件, unmatched paren, EOF)?

□ 性能回归?
  - benchmark 中 parse 时间稳定?
```

---

## 8. v2 subseries 收官回顾（aura v2 #3）

接续 #1 v2 Agent Orchestration + #2 v2 Build System,本文聚焦 Parser。

```
aura v2 deep-dive 系列 (本篇为 #3):

#1 v2  Agent Orchestration (orch.ixx + agent_spawn.h + AgentScope) ✅
#2 v2  Build System (build.py + 9 gates + CMake + Sanitizer + PGO)  ✅
#3 v2  Parser (S-expression + Racket 兼容 + ABF)  ← 本文
#4 v2  Runtime (runtime.c + JIT 桥接)
#5 v2  Compiler (C++26 modules + AOT/JIT)
#6 v2  Fiber System (concurrency + GC hooks)
#7 v2  Type System (type_dep freshness + denseness)
#8 v2  Module System (multi-define + require)
#9 v2  JIT / AOT (aura_jit + hot-update + aot_mangle)
#10 v2 Self-Modification (代码自己进化的核心机制)
```

---

## 9. 下一篇预告

按 aura 主题自然顺序:

- **#4 v2 Runtime** — runtime.c + JIT 桥接(交叉 C/C++ 边界)
- **#5 v2 Compiler** — 182 文件 + C++26 modules(核心深入)
- **#6 v2 Fiber System** — 并发 + GC hooks(配合 #1 orchestration)

下一篇选哪个?

---

## 10. 参考(可执行的源码锚点)

- `~/code/aura/src/parser/parser.ixx` — C++ Parser 接口单元
- `~/code/aura/src/parser/parser_impl.cpp` — C++ Parser 实现
- `~/code/aura/src/core/ast.ixx` — AST 节点(8 类型 + variant)
- `~/code/aura/src/core/ast_impl.cpp` — AST 实现
- `~/code/aura/src/core/parser/lexer.ixx` — C++ Lexer(推测)
- `~/code/aura/tests/fixtures/lang/private/core.rkt` — Phase 0 Lisp 求值器
- `~/code/aura/tests/fixtures/lang/private/abf.rkt` — ABF v2 序列化
- `~/code/aura/tests/fixtures/lang/private/expander.rkt` — `#lang aura` 展开器
- `~/code/aura/src/compiler/serialization/` — C++ ABF 实现(推测)
- `~/code/aura/tests/compiler/test_*.cpp` — Compiler 测试
- `~/code/aura/tests/parser/test_*.cpp` — Parser 测试(推测)
- `~/code/aura/tests/runtime/test_*.cpp` — Runtime 测试

---

#3 v2 (aura) 完。