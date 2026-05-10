# Aura Racket 前端分析

通过 doom-lsp (racket-langserver) 对 Aura 的 Racket 前端进行静态分析。

---

## 项目概述

Aura 的 Racket 前端提供 `#lang aura` 语言支持、Phase 0 Lisp 核心求值器、ABF 序列化器。

| 文件 | 职责 | 符号数 |
|------|------|--------|
| `lang/private/core.rkt` | Phase 0 Lisp 核心求值器 | ~335 |
| `lang/private/abf.rkt` | ABF v2 二进制序列化 | ~250 |
| `lang/expander.rkt` | `#lang aura` 模块展开器 | ~30 |

---

## core.rkt — Phase 0 Lisp 核心

**关键导出**：

```racket
(provide eval-expr make-env extend-env lookup-env)
```

### 环境系统

```racket
(define (make-env) ...)         ;; 初始环境：26 个内置原语
(define (extend-env env n v) ...)  ;; 扩展 env alist
(define (lookup-env env n) ...)    ;; 自动解引用 cell
(define (raw-lookup env n) ...)    ;; 不解引用的查找
```

**内置原语**（26 个）：`+ - * / = < > <= >= eq? equal? not cons car cdr null? pair? display displayln number? symbol? string? boolean?`

### 求值器

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
       [(if) ...]                  ;; 条件
       [(lambda) ...]              ;; 闭包创建
       [(let) ...]                 ;; let → eval-bindings
       [(letrec) ...]              ;; letrec → mutable cells
       [(define) ...]              ;; define
       [else ...])]                ;; 函数调用
    [else (error ...)]))
```

**实现模式**：函数式求值器，环境为 alist。letrec 使用 `cell` struct 实现自引用闭包。

### cell struct（letrec 的关键）

```racket
(struct cell (value) #:mutable)
```

letrec 流程：
1. 创建 `cell-env`，每个 letrec 名字绑定到一个 `(cell 0)`
2. 在 `cell-env` 中求值各表达式（闭包捕获含 cell 的环境）
3. `set-cell-value!` 填充 cell 为真实值
4. 自动解引用：`lookup-env` 遇到 cell 返回 `(cell-value v)`

---

## abf.rkt — ABF v2 序列化器

**关键导出**：

```racket
(provide serialize-expr serialize-delta ABF-MAGIC tag-for-expr)
```

### ABF v2 二进制格式

```
[Magic: "ABF2"] [Version: varint] [PhaseID: varint]
[Node: Tag(varint) | ExtID(varint) | ExtLen(varint) | ExtPayload(0) | CorePayload(...)]
```

### Tag 映射

| Tag | 节点 | 序列化 |
|-----|------|--------|
| 0x01 | LiteralInt | 8 bytes big-endian int64 |
| 0x02 | Variable | varint(len) + utf8 name |
| 0x03 | Call | function node + args nodes |
| 0x04 | If | cond + then + else nodes |
| 0x05 | Lambda | varint(param_count) + [name]* + body node |
| 0x06 | Let | varint(binding_count) + [name + val]* + body node |

### 编码函数

```racket
(define (encode-varint n) ...)     ;; 7-bit groups, MSB continuation
(define (tag-for-expr expr) ...)   ;; 表达式 → Tag
(define (write-node buf expr) ...) ;; 递归写节点
```

---

## expander.rkt — `#lang aura` 展开器

```racket
(define-syntax-rule (#%module-begin expr)
  (#%plain-module-begin
    (displayln (eval-expr 'expr (make-env)))))
```

提供 `#%module-begin`、`#%datum`、`#%top`、`#%app` 四个绑定，满足 Racket 的 `#lang` 协议。每个 `#lang aura` 文件是一个 S 表达式，编译时求值并打印结果。

---

## 架构数据流

```
#lang aura source
    │
    ▼
reader.rkt (S expression reading + module wrapping)
    │
    ▼
expander.rkt (#%module-begin → eval-expr)
    │
    ▼
core.rkt (tree-walking evaluator)
    │
    ▼
ABF (binary serialization) → C++ Compiler Service
```

---

## racket-langserver 兼容性说明

| 功能 | 支持 | 备注 |
|------|------|------|
| `documentSymbol` | ✅ 335+ symbols | 完整的文件符号表 |
| `workspace/symbol` | ⚠️ 需预热 | 守护进程模式可用 |
| `textDocument/definition` | ⚠️ 有限 | racket-langserver 实现 |
| `didOpen/didClose` | ✅ | 文件打开/关闭通知 |

每个查询约需 4-8 秒（含 racket-langserver 初始化），守护进程模式下后续查询 <1 秒。
