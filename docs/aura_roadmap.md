# Aura — Ghuloum 增量构建路线图

**方法**：《An Incremental Approach to Compiler Construction》（Ghuloum, ICFP 2006）
**原则**：每一步增加一个最小功能，系统始终可运行、可测试。每步新增代码不超过约 20 行核心逻辑。
**结构**：共 4 Phase × 3 层 = 37 步。每步一个**可验证红线**。

---

## 总览

```
Phase 0: Racket #lang 原型 ───────────────────────────────── (Steps 01-08) ✅
Phase 1a: C++26 最小求值器   ──────────────────────────────── (Steps 09-16) ← NOW
Phase 1b: 编译管线 + IR      ──────────────────────────────── (Steps 17-24)
Phase 1c: 查询引擎            ──────────────────────────────── (Steps 25-30)
Phase 2:  反射与热更新        ──────────────────────────────── (Steps 31-34)
Phase 3:  宏系统               ──────────────────────────────── (Steps 35-36)
Phase 4:  生产化               ──────────────────────────────── (Steps 37+)
```

---

## Phase 0：Racket #lang 原型 (已完成)

遵循 Ghuloum Step 1-6 精神，用 Racket 实现最小 Lisp 核心。

| Step | 特性 | 红线验证 | 状态 |
|------|------|----------|------|
| 01 | 整数字面量 | `(eval 42)` → `42` | ✅ |
| 02 | 变量引用 (lexical) | `(eval 'x '{x 10})` → `10` | ✅ |
| 03 | lambda + 函数应用 | `(eval '((lambda (x) x) 1))` → `1` | ✅ |
| 04 | if 条件 | `(eval '(if #t 1 2))` → `1` | ✅ |
| 05 | let (sugar) + letrec | `(eval '(let ((x 5)) x))` → `5` | ✅ |
| 06 | quote + 基本数据 | `(eval '(quote (a b)))` → `(a b)` | ✅ |
| 07 | define (Hyperstatic) | `(eval '(define x 5) env)` → env has x→5 | ✅ |
| 08 | REPL 循环 | `racket -l aura` → 可交互 | ✅ |

**关键约束验证**：`(letrec ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))) (fact 5))` → `120`

---

## Phase 1a：C++26 最小求值器 (Steps 09-16)

**目标**：C++26 Compiler Service 能运行 Phase 0 完整语义。
**策略**：不装管线，直接用 C++ tree-walking interpreter 跑起来，**后续再分层降级到 IR**。

### Step 09 — 编译器骨架 + 整数求值

```
新增：CMakeLists.txt, src/main.cpp, empty CompilerService
      src/core/arena.ixx (ASTArena 骨架)
      src/core/ast.ixx (Expr 节点定义, ParsedPhase)
      #lang aura → ABF 序列化 → C++ 反序列化 → 求值
```

**红线验证**：
```bash
echo '(print 42)' | racket -l aura --abf | ./aura --eval
# 输出: 42
```

**依赖**：`docs/aura_architecture.md §3.1-3.2` + `docs/aura_serialization.md §4`

### Step 10 — 变量引用与环境

```
新增：SymbolTable 类
      Env 结构 (vector<Binding>)
      Variable 节点求值: env.lookup(name)
```

**红线验证**：
```
输入: (let ((x 10)) x)
输出: 10
```

**参考**：Ghuloum Step 2

### Step 11 — 算术原语

```
新增：算术节点类型 + 内置函数表
      支持: + - * / = < >
```

**红线验证**：
```
输入: (+ 1 (* 2 3))
输出: 7
```

**参考**：Ghuloum Step 3

### Step 12 — 条件分支

```
新增：If 节点求值
```

**红线验证**：
```
输入: (if (> 3 2) 1 0)
输出: 1
```

**参考**：Ghuloum Step 4

### Step 13 — 闭包 + 函数应用

```
新增：Closure 结构 (code + env)
      Call 节点求值: 创建闭包 → 扩展环境 → 求值 body
```

**红线验证**：
```
输入: ((lambda (x) (* x 2)) 5)
输出: 10
```

**参考**：Ghuloum Step 5-6

### Step 14 — let / letrec 展开

```
新增：let → lambda apply 的宏展开 (Racket 端)
      letrec → 循环引用环境 (C++ 端)
```

**红线验证**：
```
输入: (letrec ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))) (fact 5))
输出: 120
```

**参考**：Ghuloum Step 5

### Step 15 — Hyperstatic define + 模块

```
新增：define 绑定 → 全局环境 (不可覆盖)
      模块级状态持久化
```

**红线验证**：
```
输入: (define x 5) → (eval 'x) → 5
      尝试 (define x 6) → error: cannot redefine
```

**参考**：LiSP Ch2

### Step 16 — C++26 REPL + 完整语言

```
新增：交互式 REPL 循环
      read-eval-print 一体化
```

**红线验证**：
```bash
$ ./aura
aura> (define fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))
aura> (fact 5)
120
aura>
```

**里程碑**：C++26 Compiler Service 可以用解释模式跑通 Phase 0 全语义。

---

## Phase 1b：编译管线 + AuraIR (Steps 17-24)

**目标**：从 tree-walking 解释器进化为 AST → AuraIR → 优化的编译管线。

### Step 17 — AuraIR 定义 + 基本降级

```
新增：src/compiler/ir.ixx — IR 指令定义
      Lowering Pass — Expr → IR
      验证降级后的 IR 语义等价
```

**红线验证**：
```
输入: (+ 1 2)
IR:  Const 1, Const 2, Add, Return
执行 IR → 3
```

### Step 18 — AuraIR 解释器

```
新增：IRInterpreter — 执行降级后的 IR 指令
      用 IR 解释器替换 tree-walker（保留 tree-walker 作为 fallback）
```

**红线验证**：
```
所有 Step 09-16 的测试用例通过 IR 解释器仍然正确
```

### Step 19 — 闭包变换 (Closure Conversion)

```
新增：闭包分析 Pass
      识别自由变量 → 生成 Closure 结构
      将 Lambda 节点变换为 flat closure 表示
```

**红线验证**：
```
输入: (let ((x 1)) (lambda (y) (+ x y)))
闭包: {code=... free=(x=1)}
应用: (let ((f (let ((x 1)) (lambda (y) (+ x y))))) (f 2))
输出: 3
```

**参考**：Ghuloum Step 7

### Step 20 — compute-kind + arity 检查

```
新增：compute-kind Pass — 分类 value/function/macro
      arity 检查 Pass — 静态检测参数数量错误
```

**红线验证**：
```
输入: ((lambda (x y) x) 1)  → error: wrong number of arguments
```

### Step 21 — 常量折叠 + DCE

```
新增：ConstantFolding Pass — 编译期计算常量表达式
      DeadCodeElimination Pass — 移除不可达代码
```

**红线验证**：
```
降级前: (+ 1 2) → 3 条 IR 指令
降级后: (+ 1 2) → 1 条 IR 指令 (Const 3)
```

### Step 22 — 源位置追踪

```
新增：每个 AST 节点携带 SourceLocation
      降级到 IR 时传递源位置
      LocatedPhase 扩展数据
```

**红线验证**：
```
输入: 源文件 line 15 col 3 的 (+ 1 2)
IR 指令: Add, source=(15,3,"main.aura")
```

**参考**：`docs/aura_serialization.md §3` (Trees that Grow LocatedPhase)

### Step 23 — 增量编译框架

```
新增：版本化编译单元 (每个 define/expression 一个版本)
      变更检测 — 只重新编译变化的部分
      编译缓存 — 避免重复工作
```

**红线验证**：
```
编译 module: 1000 lines, time = T
修改 1 行 -> 增量编译 time = T/100
```

### Step 24 — 诊断引擎 + 静态错误报告

```
新增：DiagnosticEngine — 结构化错误报告
      未绑定变量检测
      类型不匹配初步检测
```

**红线验证**：
```
输入: (define x (+ y 1))  (y 未定义)
输出: error: test.aura:1:14: undefined variable 'y'
```

**里程碑**：Compiler Service 具备增量编译管线 + 静态诊断。

---

## Phase 1c：查询引擎 (Steps 25-30)

**目标**：AuraQueryEngine 可接受查询计划，在 AST/IR 索引上执行。

### Step 25 — AST 倒排索引 (Kind + Name)

```
新增：ASTIndex — 按 NodeKind 和 Symbol Name 的倒排索引
      构建索引：遍历 AST 填充 hash tables
```

**红线验证**：
```
索引: (Call → [42, 57]), (Define → [3, 15])
查询: (query (node-type Call))  → [42, 57]
```

**参考**：`docs/aura_query.md §5.4`

### Step 26 — 源位置 + Def-Use 索引

```
新增：SourceIndex — file:line → NodeID 映射
      DefUseChain — 定义→使用 链追踪
```

**红线验证**：
```
查询: (query (location (line 42)))
查询: (query (= (use-count :node) 0)) → 未使用定义
```

### Step 27 — AuraQuery eDSL 解析器 (Racket 端)

```
新增：query / query-and-fix 宏 (Racket lang/private/query.rkt)
      宏展开为内部查询计划 (S 表达式)
      ABF 序列化查询计划
```

**红线验证**：
```
输入: (query (node-type Call) (has-error? #t))
展开: (query-plan (filter (node-kind :eq 'Call)) (filter (has-error :eq #t)))
```

**参考**：`docs/aura_query.md §5.2`

### Step 28 — 查询执行引擎 (C++26 端)

```
新增：QueryPlanner — 查询计划 → 可执行计划树
      QueryExecutor — 在索引上执行计划树
      支持 filter/project/join 原语
```

**红线验证**：
```
Racket → ABF查询计划 → C++26 → 执行 → 结果节点ID列表
```

### Step 29 — 变换引擎 + 补丁生成

```
新增：PatchGenerator — 查询结果 → 增量补丁
      变换原语: replace-with, wrap-with, insert-before/after
      补丁格式: ABF Delta
```

**红线验证**：
```
(query-and-fix (node-type Call) (has-error? #t) (fix ...))
→ 生成 ABF Delta → 应用补丁 → 热更新
```

### Step 30 — Hot Swap 引擎原型

```
新增：HotSwapEngine — 函数级替换
      变异点追踪 (哪些函数依赖变更的函数)
      替换策略: 下次调用时替换
```

**红线验证**：
```
运行中的程序：替换函数定义 → 下次调用使用新版本
回滚：替换回旧版本 → 恢复原行为
```

**里程碑**：AI 修复闭环 — `query → fix → incremental compile → hot swap`

---

## Phase 2：反射 (Steps 31-34)

**目标**：AI Agent 可运行时自我修改。

### Step 31 — export + eval/b

```
新增：export — 将环境序列化为可传输对象
      eval/b — 在指定环境中求值
```

**红线验证**：
```
(define env (export)) → (eval/b '(+ 1 2) env) → 3
```

**参考**：LiSP Ch8

### Step 32 — flambda (FEXPR)

```
新增：flambda — 未求值参数 + 当前环境
      自定义求值策略
```

**红线验证**：
```
(define my-if (flambda (cond then else)
                 (if (eval/b cond env)
                     (eval/b then env)
                     (eval/b else env))))
(my-if #t 1 2) → 1
```

### Step 33 — reflective-lambda

```
新增：reflective-lambda — 可访问自身求值环境的 lambda
      安全的运行时反射
```

**红线验证**：
```
Agent 输出代码 → eval/b 加载 → 运行 → 动态修改行为
```

### Step 34 — C++26 反射运行时 + 跨语言互操作

```
新增：C++26 端 export/eval/b 实现
      Racket ↔ C++26 环境序列化/反序列化
      flambda 在 C++26 运行时中的对应实现
```

**红线验证**：
```
Racket 端 export env → ABF序列化 → C++26 eval/b → 结果返回 Racket
```

**里程碑**：AI Agent 能运行时加载、修改、执行代码。自修改闭环打通。

---

## Phase 3：宏系统 (Steps 35-36)

**目标**：语言学会生长语法。

### Step 35 — 卫生宏系统

```
新增：syntax-rules 风格的卫生宏
      expander Pass — 编译期宏展开
      macro 环境与普通环境分离
```

**红线验证**：
```
(define-syntax-rule (twice x) (* 2 x))
(twice 5) → 10
```

**参考**：LiSP Ch9, Racket syntax-parse 文档

### Step 36 — with-aliases + 持久 AST + Code Walking

```
新增：with-aliases 逃生舱 — 受控标识符捕获
      持久 AST — 从解析到运行时全程保留
      Code Walking — 宏可遍历任意深度 AST
```

**红线验证**：
```
;; Agent 定义 DSL 并立即使用
(define-syntax-rule (my-dsl expr)
  (with-aliases (begin) expr))
(my-dsl (print "hello"))
```

**参考**：`docs/aura_query.md §4.3` 宏抽象示例

**里程碑**：Agent 能动态生成 DSL → 展开 → 使用。

---

## Phase 4：生产化 (Steps 37+)

**目标**：从原型走向可替代旧生态的生产级系统。

| Step | 特性 | 红线验证 |
|------|------|----------|
| 37 | LLVM IR 后端 | `AuraIR → LLVM IR → native code` |
| 38 | AOT 编译路径 | `clang++ -ffreestanding → 独立二进制` |
| 39 | Sound Gradual Typing | `(define (add x y) (+ x y))` 等价于 `(add : Int Int -> Int)` |
| 40 | 安全沙箱 | `(with-sandbox (lambda () (unsafe ...))) → error: permission denied` |
| 41 | 包管理器 | `(import "http://pkg/foo.aura")` |
| 42 | 自举 (Bootstrap) | `Aura 编译器用 Aura 自己编译` |
| 43+ | 分布 Agent 运行时 | 多 Agent 共享 Compiler Service |

---

## 增量构建红线汇总

```
Step 09: ./aura --eval '(+ 1 2)'                    → 3
Step 13: ./aura --eval '((lambda (x) (* x 2)) 5)'    → 10
Step 14: ./aura --eval '(letrec ((fact ...)) (fact 5))' → 120
Step 16: ./aura 交互式 REPL                            → 可用
Step 22: ./aura --eval '(undefined-var)'              → error: line 1:14
Step 23: 1000行, 改1行, 增量编译 time < 10ms          → 通过
Step 28: (query (node-type Call))                     → [42, 57]
Step 30: 热替换函数 → 下次调用用新版本                   → 通过
Step 32: flambda 自定义求值策略                         → 通过
Step 35: 宏展开 (twice 5) → 10                         → 通过
Step 42: Aura 编译自身                                  → 通过
```

---

## 时间线（按 Ghuloum 节奏）

```
Phase 0: 已完成

Phase 1a (Step 09-16): 第 1-3 周    ← 当前起点
  Week 1:  Step 09-10  环境 + 整数/变量
  Week 2:  Step 11-13  算术 + 条件 + 闭包
  Week 3:  Step 14-16  letrec + define + REPL

Phase 1b (Step 17-24): 第 4-7 周
  Week 4:  Step 17-18  AuraIR 定义 + 解释器
  Week 5:  Step 19-20  闭包变换 + 静态检查
  Week 6:  Step 21-22  优化 + 源位置
  Week 7:  Step 23-24  增量编译 + 诊断

Phase 1c (Step 25-30): 第 8-10 周
  Week 8:  Step 25-26  索引构建
  Week 9:  Step 27-28  AuraQuery 解析 + 执行
  Week 10: Step 29-30  补丁生成 + 热更新

Phase 2   (Step 31-34): 第 11-13 周
Phase 3   (Step 35-36): 第 14-16 周
Phase 4   (Step 37-43): 第 17-24 周
```

每步之间留 1 天缓冲。完成一个 Step 的标志：**红线验证通过，测试覆盖 > 90%。**

---

## 与设计文档的对应

| Roadmap 阶段 | 对应设计文档 |
|-------------|-------------|
| Phase 0 Racket 原型 | `docs/aura_architecture.md §3.1` |
| Phase 1a C++26 求值器 | `docs/aura_architecture.md §3.3` + `docs/aura_modules.md` |
| Phase 1b 编译管线 | `docs/aura_architecture.md §3.4` (AuraIR) |
| Phase 1c 查询引擎 | `docs/aura_query.md §5` + `docs/aura_architecture.md §3.5` |
| Phase 2 反射 | `docs/aura_architecture.md §2` (反射决策) |
| Phase 3 宏系统 | `docs/aura_architecture.md §3.1` (Racket 宏) |
| Phase 4 生产化 | `docs/aura_architecture.md §3.6-3.7` (Service + Runtime) |
| 序列化 (贯穿所有阶段) | `docs/aura_serialization.md` |
| 模块结构 | `docs/aura_modules.md` |

---

> **"向前走，门会自己打开。"**
> 每一步都是可运行的。没有大跃进，没有不可测试的阶段。
