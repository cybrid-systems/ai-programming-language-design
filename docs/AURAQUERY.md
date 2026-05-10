# AuraQuery — Aura 原生 eDSL

**版本**：v1.0
**定位**：本文档定义 AuraQuery——嵌入 Aura 语言的 AST 查询与变换 DSL。AI Agent 使用 Aura 自己的语法来表达对代码结构的查询、分析和自动修复。

---

## 1. 设计哲学

### 为什么是 eDSL，不是独立语言？

让 AI 用另一套语法写查询（JSON、SQL 风格字符串、YAML）等于在 Aura 和查询引擎之间加了一层翻译器——每次查询都要解析、验证、翻译成内部表示。而 eDSL 意味着：

- **零学习成本**：AI 会的 Aura 语法，就是查询语法
- **Homoiconic**：查询本身就是 AST，AI 可以动态生成和修改查询
- **宏扩展**：查询操作符可以用宏定义，产生领域专用的高级抽象
- **类型安全**：查询参与 Aura 的类型检查
- **与代码统一**：查询和业务代码使用同一套工具链、同一套求值模型

### 关键设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 语法基础 | Aura S 表达式 | 跟语言本身一致，AI 不需要切换语境 |
| 查询与变换 | 统一的 `query` / `query-and-fix` | 查询→分析→修复是 AI 的标准工作流 |
| 索引引擎 | Lucene 风格倒排索引 + Aura eDSL | AI 最友好，支持精准子树级增量 |
| 宏支持 | 用户可定义 `find-all-errors` 等高级抽象 | 语言自然生长，AI 可不断扩展查询能力 |
| 通信 | 查询展开为内部计划 → ABF 传输 | Racket 端展开，C++26 端执行 |

---

## 2. AuraQuery 语法

### 2.1 基本查询

最简单的查询：查找满足条件的节点。

```lisp
;; 查找所有类型错误的 Call 节点
(query
  (node-type Call)
  (has-error? #t))

;; 指定查找范围
(query
  (node-type Call)
  (callee "add")
  (argument-type 0 Integer)
  (location (line-range 10 50)))
```

每个条件子句用 `()` 包裹，多个子句间是 **AND** 关系。

### 2.2 条件子句

| 子句 | 作用 | 示例 |
|------|------|------|
| `(node-type <kind>)` | 按节点类型过滤 | `(node-type Lambda)` |
| `(has-error? <bool>)` | 是否有编译错误 | `(has-error? #t)` |
| `(callee <name>)` | 函数调用名匹配 | `(callee "add")` |
| `(argument-type <n> <type>)` | 第 n 个参数的类型 | `(argument-type 0 Integer)` |
| `(return-type <type>)` | 返回类型匹配 | `(return-type Int)` |
| `(location <spec>)` | 按源位置过滤 | `(location (file "main.aura"))` |
| `(name <pattern>)` | 按名称模式匹配 | `(name "add*")` |
| `(free-vars <vars>)` | 自由变量匹配 | `(free-vars 'x)` |
| `(use-count <op> <n>)` | 按使用次数过滤 | `(use-count :> 0)` |
| `(depth <op> <n>)` | 按 AST 深度过滤 | `(depth :<= 5)` |

### 2.3 位置范围

```lisp
;; 文件
(location (file "src/main.aura"))

;; 行范围
(location (line-range 10 50))

;; 精确位置
(location (line 15 :column 3))

;; 组合
(location (file "main.aura") (line-range 10 50))
```

### 2.4 逻辑组合

```lisp
;; AND（默认）
(query (node-type Call) (has-error? #t))

;; OR（显式）
(query (or (node-type Call) (node-type IfExpr)))

;; NOT
(query (not (node-type LiteralInt)))
```

### 2.5 复杂语义查询

```lisp
;; 查找所有未使用的函数定义
(query
  (node-type Define)
  (= (use-count :node) 0))

;; 查找所有递归调用
(query
  (node-type Lambda)
  (exists (child (node-type Call)
                 (= (callee :parent) :context))))

;; 查找所有公共 API 中的不安全函数
(query
  (node-type Define)
  (attr "public" #t)
  (attr "unsafe" #t))
```

---

## 3. 变换与修复

### 3.1 `query-and-fix`

查询 + 自动修复，一步完成：

```lisp
;; 修复所有类型错误的调用
(query-and-fix
  (node-type Call)
  (has-error? #t)
  (fix (replace-argument 1 (cast (argument 1) Integer))))

;; 给函数调用添加日志
(query-and-fix
  (node-type Call)
  (not (callee "log"))
  (fix (wrap-with 'with-logging)))
```

### 3.2 `query-and-transform`

更通用的变换操作：

```lisp
;; 替换所有 x + 0 为 x
(query-and-transform
  (node-type Call)
  (= (callee "+"))
  (= (argument-count) 2)
  (any (is-literal 0))
  (transform (replace-with (first-argument))))
```

### 3.3 变换原语

| 变换 | 作用 | 示例 |
|------|------|------|
| `(replace-with <expr>)` | 替换整个节点 | `(replace-with '(lambda (x) (* x x)))` |
| `(replace-argument <n> <expr>)` | 替换第 n 个参数 | `(replace-argument 1 (cast (arg 1) Int))` |
| `(wrap-with <fn>)` | 用函数调用包裹 | `(wrap-with 'with-logging)` |
| `(insert-before <node>` | 在节点前插入 | `(insert-before '(check-invariants))` |
| `(insert-after <node>)` | 在节点后插入 | `(insert-after '(cleanup))` |
| `(delete-node)` | 删除节点 | `(delete-node)` |
| `(hoist-to-let <name>)` | 提升为 let 绑定 | `(hoist-to-let 'temp)` |

### 3.4 查询变量绑定

在查询中使用 `:name` 语法绑定匹配到的节点，后续变换可引用：

```lisp
(query-and-transform
  (node-type Lambda)
  (= (lambda-param-count) 1)
  (bind :single-param-lambda)
  (transform
    (replace-with
      (let () (:single-param-lambda)))))  ;; 引用绑定结果
```

---

## 4. AI Agent 交互模式

### 4.1 自动修复流程

```lisp
;; AI 生成的完整修复代码
(define (auto-fix-type-errors)
  (query-and-fix
    (node-type Call)
    (has-error? #t)
    (fix (replace-with-correct-cast))))
```

AI 只需写上面这几行，系统自动完成：

1. 展开查询 → 编译为内部查询计划
2. ABF 序列化 → 传输到 Compiler Service
3. AuraQueryEngine 执行查询 → 定位目标节点
4. 应用变换 → 生成增量补丁
5. 增量编译 → 热更新运行时

### 4.2 动态生成查询

利用 Aura 的 homoiconicity，AI 可以动态构造查询：

```lisp
;; AI 根据上下文动态生成查询条件
(let ((target-type (infer-error-type)))
  `(query-and-fix
     (node-type Call)
     (has-error? #t)
     (fix (replace-with-correct-cast :to ,target-type))))
```

### 4.3 宏抽象

用户/AI 可以定义高级查询抽象，形成领域特定的检查工具：

```lisp
;; 定义宏：查找所有空函数体
(define-syntax-rule (find-empty-functions)
  (query
    (node-type Lambda)
    (= (body-size) 0)))

;; 定义宏：查找所有潜在无限递归
(define-syntax-rule (find-potential-infinite-loops)
  (query
    (node-type Lambda)
    (exists (child (node-type Call)
                   (= (callee :parent) :context)))
    (not (exists (child (node-type If))))))

;; 直接使用
(find-empty-functions)
```

---

## 5. 内部架构

### 5.1 查询处理流水线

```
AI 写的 AuraQuery          Racket 端                    C++26 端
┌─────────────┐    ┌──────────────────────┐    ┌────────────────────┐
│ (query       │    │                      │    │                    │
│  (node-type  │──→ │ 1. macro-expand      │──→ │ 4. deserialize     │
│   Call)      │    │ 2. validate types    │    │ 5. build query plan│
│  (has-error? │    │ 3. serialize as ABF  │    │ 6. execute on index│
│   #t))       │    │                      │    │ 7. apply transform │
└─────────────┘    └──────────────────────┘    └────────────────────┘
```

### 5.2 宏展开过程

Racket 端的宏将 `query` 展开为内部查询计划：

```racket
;; (query (node-type Call) (has-error? #t))
;; 展开为：
(abf-serialize
  (query-plan
    (filter (node-kind :eq 'Call))
    (filter (has-error :eq #t))
    (project (node-id source-location))))
```

展开后的查询计划是一个 S 表达式，可 ABF 序列化后传输到 C++26 Compiler Service。

### 5.3 与 ARCHITECTURE.md 的对应

| ARCHITECTURE.md 模块 | AuraQuery 上下文 |
|----------------------|-----------------|
| 3.5 AuraQueryEngine | 查询执行引擎（索引构建、查询执行） |
| 3.5 Index Layer | AST / IR / Def-Use / Source 四种倒排索引 |
| 3.5 Query Layer | AuraQuery Parser + Executor + Pattern Matcher |
| 3.5 Mutation Layer | Patch Generator + Hot Swap Scheduler |
| 3.6 Compiler as a Service | `apply_patch` / `ai_query` 接口 |
| 3.7 Triple Runtime | 热更新引擎接收变换结果 |

### 5.4 索引结构（概览）

AuraQueryEngine 维护四种倒排索引：

```
AST Index
├── NodeKind → [node_id, ...]          (按类型)
├── Name → [node_id, ...]              (按名称/符号)
├── SourceLocation → [node_id, ...]    (按源位置)
└── ErrorFlag → [node_id, ...]        (按错误标记)

IR Index
├── Opcode → [block_id, ...]           (按IR指令类型)
├── FunctionName → [block_id, ...]     (按函数名)
└── Optimized → [block_id, ...]       (按优化状态)

Def-Use Index
├── Def → [use_id, ...]               (定义→使用链)
└── Use → [def_id, ...]               (使用→定义链)
```

---

## 6. AuraQuery eDSL 与 Compiler Service 接口

Compiler Service 暴露的查询相关接口：

| 接口 | 参数 | 返回 |
|------|------|------|
| `query(expr)` | AuraQuery S 表达式 | 匹配的节点 ID 列表 |
| `query(query_plan)` | 已展开的查询计划 | 匹配的节点 ID 列表 |
| `apply_patch(patch)` | ASTPatch (ABF) | 补丁应用结果 |
| `ai_query(expr)` | AuraQuery S 表达式（AI 友好版） | 查询+变换结果 |
| `query_source_line(line, file)` | 行号 + 文件名 | 该行的节点列表 |

---

## 7. 设计优势总结

| 优势 | 说明 |
|------|------|
| **零语义 gap** | 查询用 Aura 语法写，AI 不需要在不同语言间切换 |
| **宏可扩展** | 用户可以定义自己的查询抽象，语言自然生长 |
| **类型安全** | 查询参与 Aura 类型检查，错误提前捕获 |
| **增量友好** | 查询结果可精确到子树级，增量编译只处理变更部分 |
| **自然语言到查询** | AI 可以从自然语言需求直接生成 AuraQuery 代码 |

---

## 8. 实现路径

| 步骤 | 内容 | 位置 |
|------|------|------|
| 1 | 定义 `query` / `query-and-fix` 宏语法 | Racket `lang/private/macro.rkt` |
| 2 | 宏展开为查询计划 S 表达式 | Racket `lang/private/query.rkt` |
| 3 | 查询计划 ABF 序列化 | Racket `lang/private/abf.rkt` |
| 4 | C++26 AST/IR 倒排索引构建 | `aura/query/query_engine.ixx` |
| 5 | C++26 查询计划解析与执行 | `aura/query/planner.ixx` + `executor.ixx` |
| 6 | 变换生成与热更新调度 | `aura/query/planner.ixx` |
| 7 | Compiler Service 集成 | `aura/compiler/compiler_service.ixx` |

---

> **"查询就是代码，代码就是数据。"**
> AuraQuery 是 Aura homoiconicity 的自然延伸——如果代码是数据，那么查询代码的操作也应该是代码的一部分。
>
> 相关文档：[ARCHITECTURE.md](./ARCHITECTURE.md) | [SERIALIZATION.md](./SERIALIZATION.md) | [DESIGN_PHILOSOPHY.md](./philosophy/DESIGN_PHILOSOPHY.md)
