# Aura — 三轨并行增量构建路线图

**方法**：《An Incremental Approach to Compiler Construction》（Ghuloum, ICFP 2006）
**原则**：每一步增加一个最小功能，系统始终可运行、可测试。
**三轨并行**：架构 / 语言 / 基建 三个轨道同时推进，每个里程碑产生一个可用的垂直切片。

---

## 三轨定义

| 轨道 | 范围 | 产出物 | 核心文档 |
|------|------|--------|----------|
| **🏗 架构 (Arch)** | Compiler Service、ABF 协议、IPC、模块系统、三层运行时 | 系统骨架与通信管道 | `aura_architecture.md`、`aura_serialization.md`、`aura_modules.md` |
| **🗣 语言 (Lang)** | Lisp 核心、编译管线、AuraIR、宏、反射、类型系统 | 语言本身 | `aura_architecture.md §3`、`aura_query.md` |
| **🔧 基建 (Infra)** | 构建系统、CI、测试框架、基准、包管理、自举 | 开发者工具链 | `aura_modules.md` |

---

## 总览

```
                      M0         M1         M2          M3         M4         M5
 Seed               C++ Eval    Pipeline   Query       Growth     Ship
───────────────────────────────────────────────────────────────────────────→
🏗 Arch   ────[0]───[1a]───[1b]───[2a]───[2b]───[3a]───[3b]───[4a]───[4b]───
🗣 Lang   ────[0]───[1a]───[1b]───[2a]───[2b]───[3a]───[3b]───[4a]───[4b]───
🔧 Infra  ────[0]───[1a]───[1b]───[2a]───[2b]───[3a]───[3b]───[4a]───[4b]───
          ↑                                            ↑              ↑
    当前起点                                   AI 修复闭环        自举成功
```

每个里程碑 === 三条轨道各完成一个 Step。**不"先搭架构再写语言"**，而是每次 Sprint 三条线同时产出可验证结果。

---

## 里程碑 0：种子 (已完成)

### 🏗 Arch-0 — Racket #lang 骨架

| Step | 新增 | 红线 |
|------|------|------|
| A0.1 | `#lang aura` reader + expander 基本结构 | `racket -l aura` 启动不崩溃 |
| A0.2 | `lang/private/core.rkt` 最小求值器 | 可运行 `42` → `42` |
| A0.3 | 基本 REPL 循环 | 交互式 read-eval-print |

### 🗣 Lang-0 — 最小 Lisp 核心

| Step | 新增 | 红线 |
|------|------|------|
| L0.1 | 整数字面量 | `(eval 42)` → `42` |
| L0.2 | 变量引用 (lexical scoping) | `(eval 'x '{x 10})` → `10` |
| L0.3 | lambda + 函数应用 | `(eval '((lambda (x) x) 1))` → `1` |
| L0.4 | if 条件 | `(eval '(if #t 1 2))` → `1` |
| L0.5 | let (lambda sugar) + letrec | `(eval '(let ((x 5)) x))` → `5` |
| L0.6 | quote + 基本数据 | `(eval '(quote (a b)))` → `(a b)` |
| L0.7 | Hyperstatic define | `(eval '(define x 5) env)` → env 绑定 x=5 |
| L0.8 | REPL 集成 | `racket -l aura` 可交互 |

### 🔧 Infra-0 — 项目脚手架

| Step | 新增 | 红线 |
|------|------|------|
| I0.1 | Git 仓库 + MIT/Apache 2.0 许可证 | `git init` + `LICENSE` |
| I0.2 | Racket 包结构 (`info.rkt`, `raco test`) | `raco test` 通过 |
| I0.3 | 设计文档骨架 (DESIGN + ROADMAP) | `docs/` 目录完整 |

**里程碑红线**：`(letrec ((fact (lambda (n) ...))) (fact 5))` → `120` ✅

---

## 里程碑 1：C++ 求值器 (当前)

**时间**：6-8 周（含 Step 细分项）
**目标**：C++26 Compiler Service 以解释模式运行 Phase 0 完整语义。
**并行策略**：C++ 端先以文本 S 表达式 bootstrap（绕过 ABF），Racket 端重建源码后打通 ABF 通道。

### 🏗 Arch-1 — Compiler Service 骨架

```
A1.1: CMake 构建系统 + 模块骨架
├── CMakeLists.txt (C++26 modules support)
├── src/core/arena.ixx              — ASTArena 内存池 (monotonic bump)
├── src/core/ast.ixx                — Expr 节点定义 (ParsedPhase)
├── src/core/diagnostics.ixx        — DiagnosticEngine 骨架
├── src/core/source_location.ixx    — SourceManager 骨架
├── src/core/core.ixx               — 聚合导出
└── src/main.cpp                    — 空壳入口
红线: cmake -B build && cmake --build build → 成功
```

```
A1.2: Compiler Service 进程框架
├── src/compiler/compiler_service.ixx — 进程主循环
│   ├── accept_input()  — stdin / UDS / 共享内存
│   ├── compile()       — 编译入口
│   └── evaluate()      — 求值入口
├── src/parser/lexer.ixx + lexer_impl.cpp — S 表达式词法分析器
│   └── read S-exp from text (bootstrap 路径)
├── src/parser/parser.ixx + parser_impl.cpp — S 表达式解析器
│   └── text → Expr<ParsedPhase>
红线: echo '(+ 1 2)' | ./aura → 解析不崩溃
```

```
A1.3: ABF v2 序列化器 (Racket 端)
├── lang/private/abf-serialize.rkt
│   ├── serialize-expr → ABF bytes
│   └── serialize-delta → ABF Delta bytes
红线: (serialize-expr '(+ 1 2)) → 可验证二进制
```

```
A1.4: ABF v2 反序列化器 (C++26 端)
├── src/binary/deserializer.ixx
│   └── ABF bytes → Expr<ParsedPhase>
红线: Racket 产 ABF → C++ 反序列化 → 结构等价
```

```
A1.5: 共享内存传输层
├── src/runtime/ipc.ixx
│   ├── SharedMemoryChannel — mmap-backed 传输
│   └── UdsChannel — Unix Domain Socket (fallback)
红线: Racket → mmap 写 ABF → C++ 读 ABF → 求值 → 结果返回
```

### 🗣 Lang-1 — C++26 Tree-Walking 解释器

```
L1.1: 整数字面量求值
├── src/compiler/frontend.ixx — 最简求值器
│   └── eval(MakeLit(42)) → IntegerValue(42)
红线: echo 42 | ./aura --eval → 42

L1.2: 变量引用 + 环境
├── src/compiler/env.ixx
│   └── Env: vector<Binding>, lookup, extend
红线: echo x | ./aura --env 'x=10' → 10

L1.3: 算术原语 (+ - * / = < >)
├── src/compiler/primitives.ixx — 内置函数表
红线: echo '(+ 1 (* 2 3))' | ./aura --eval → 7

L1.4: if 条件
├── 条件分支求值
红线: echo '(if (> 3 2) 1 0)' | ./aura --eval → 1

L1.5: 闭包 + 函数应用
├── Closure 结构 (code ptr + captured env)
├── Call 节点求值
红线: echo '((lambda (x) (* x 2)) 5)' | ./aura --eval → 10

L1.6: let + letrec
├── let → lambda apply 展开
├── letrec → 循环引用环境 (先绑定 placeholder 再填值)
红线: echo '(letrec ((fact ...)) (fact 5))' | ./aura --eval → 120

L1.7: Hyperstatic define + 模块状态
├── GlobalEnv (不可覆盖)
├── 序列化/反序列化环境
红线: (define x 5) → (eval 'x) → 5; (define x 6) → error

L1.8: C++ REPL 循环
├── read-eval-print 一体化
红线: ./aura 交互式 → 可运行所有 Phase 0 程序
```

### 🔧 Infra-1 — 构建 + 测试

```
I1.1: CTest 基础测试框架
├── tests/ 目录结构
│   ├── unit/       — 单步测试 (每个 Step 的红线)
│   ├── integration/— 跨组件测试 (Racket→ABF→C++→结果)
│   └── regress/    — 回归测试 (所有历史 Step 的红线)
红线: ctest --test-dir build → 所有已完成的 Step 测试通过

I1.2: 混合构建 (Racket + C++)
├── CMake ExternalProject 或 Makefile wrapper
│   ├── raco setup 自动运行
│   └── C++ 端构建自动拉取 Racket
红线: make && make test → 全部通过

I1.3: CI 管线骨架
├── .github/workflows/ci.yml
│   ├── ubuntu-latest + Racket 9.1
│   ├── cmake -B build
│   └── ctest --test-dir build
红线: PR → CI 自动运行所有测试

I1.4: 性能基准框架
├── benchmarks/
│   ├── bench-eval.cpp — 求值吞吐量
│   └── bench-abf.cpp  — ABF 序列化/反序列化吞吐量
红线: ./benchmark --benchmark_format=csv → 可记录

I1.5: 回归测试自动化
├── regress.py — 扫描所有 Step，验证红线
│   ├── step-09/test.bat → 编译并运行
│   └── step-10/test.bat → ...
红线: python regress.py → ALL 37 STEPS PASSING
```

**里程碑 1 红线**：`./aura` REPL 中 factorial(10) == 3628800，CTest 全部通过。

---

## 里程碑 2：编译管线 + IR

**时间**：8-10 周
**目标**：从 tree-walking 解释器进化为 AST → AuraIR → Pass Chain 的编译管线。
**核心架构决策**：这步做完后，语言求值路径变成 `text → parse → lower → optimize → execute`，为增量编译和查询引擎打下基础。

### 🏗 Arch-2 — AuraIR + Pass Infrastructure

```
A2.1: AuraIR 指令集定义
├── src/compiler/ir.ixx
│   ├── IROpcode 枚举 (Const, Arg, Local, Add, Sub, ..., Branch, Call, MakeClosure, Return)
│   ├── IRInstruction 结构 (opcode + operands + source_pos)
│   └── BasicBlock 结构 (id, instructions, predecessors, successors)
红线: IR 指令定义编译通过，可构造 IR 片段

A2.2: Lowering Pass — 将 Expr 降级为 IR
├── LowerExprToIR(Expr<ParsedPhase>) → IRFunction
│   ├── LiteralInt → Const
│   ├── Variable → Local/Arg lookup
│   ├── Call → instructions + Call
│   ├── Lambda → MakeClosure
│   ├── If → Branch
│   └── Let/Letrec → 展开后的 IR
红线: (+ 1 2) → Const(1), Const(2), Add, Return

A2.3: Pass Manager
├── src/compiler/pass_manager.ixx
│   ├── Pass 基类 (run(IRModule) → IRModule)
│   ├── 增量标记 (哪些 Function 需要重新 pass)
│   └── Pass 排序与依赖
红线: 空 Pass Chain 通过 → IR 不变

A2.4: 增量编译核心
├── src/compiler/incr.ixx
│   ├── CompilationUnit — 每个 define/expression 一个单元
│   ├── VersionStamp — 每次编译递增
│   ├── DependencyGraph — 单元间依赖 (A calls B)
│   └── DirtyPropagation — A 变 → 依赖 A 的全部标记 dirty
红线: (define a 1) → (define b (+ a 2)) → 改 a → 只有 b 标记 dirty

A2.5: 编译缓存
├── src/compiler/cache.ixx
│   ├── IRCache — version → cached IR
│   ├── SerializedCache — 磁盘缓存 (ABF 格式)
│   └── CacheHit/Miss 统计
红线: 第二次编译同一程序 → cache hit → 零重复工作
```

### 🗣 Lang-2 — 编译 Passes

```
L2.1: AuraIR 解释器
├── src/runtime/interpreter.ixx
│   ├── execute(IRFunction, Env) → Value
│   └── 替换 tree-walker 为 IR 解释器 (保留 fallback)
红线: 所有 L1.x 测试用例通过 IR 解释器仍正确

L2.2: 闭包变换 (Closure Conversion)
├── 4 个子步:
│   2.2a: 自由变量分析 — 遍历 AST，收集每个 lambda 的自由变量
│   2.2b: 环境扁平化 — 嵌套 env → flat vector + offset 访问
│   2.2c: 闭包分配 — 在 lambda 创建点生成 MakeClosure IR
│   2.2d: 引用更新 — 所有变量访问改为 env[n] 偏移量
红线: (let ((x 1)) (lambda (y) (+ x y))) → 闭包含 {x=1}

L2.3: compute-kind 分析
├── 分类每个表达式: value / function / macro
├── 用于: 调用约定选择、宏展开时机
红线: (define x 5) → kind=value; (define f (lambda (x) x)) → kind=function

L2.4: Arity 检查
├── 静态检测函数调用的参数数量
├── 报告: wrong number of arguments: expected 2, got 3
红线: ((lambda (x y) x) 1) → 编译期错误

L2.5: 常量折叠
├── ConstantFoldingPass: (+ 2 3) → 5 (编译期)
├── 传播到使用站点: (let ((x (+ 2 3))) (* x 2)) → (* 5 2)
红线: 折叠后 IR 指令数减少

L2.6: 死代码消除 (DCE)
├── DeadCodeEliminationPass: 移除不可达的基本块和无用的 let 绑定
红线: (let ((x 1)) 2) → 降级后没有 x 相关 IR

L2.7: 源位置追踪 (贯穿式)
├── LocatedPhase Extension — 每个节点携带 file:line:col
├── 降级到 IR 时传递源位置
├── 错误报告: test.aura:15:3: undefined variable 'y'
红线: (define x (+ y 1)) → error: test.aura:1:14

L2.8: 静态错误报告 + 诊断
├── UnboundVariablePass — 编译期检测未绑定变量
├── 结构化 Diagnostic: severity + message + source_range
红线: 所有编译期错误带精确源位置
```

### 🔧 Infra-2 — CI + 基准

```
I2.1: CI 扩展: 多平台构建
├── ubuntu-latest, macos-latest (Arm), ubuntu-24.04-arm
├── Racket 9.1 + C++26 enabled toolchain
├── 测试矩阵: Debug / Release / ASan / UBSan
红线: PR 合并前所有平台通过

I2.2: 性能基准 CI
├── benchmarks/ 扩展:
│   ├── bench-eval-throughput    — 求值吞吐量 (ops/sec)
│   ├── bench-compile-latency    — 编译延迟 (ms per function)
│   ├── bench-incr-speedup       — 增量 vs 全量编译加速比
│   └── bench-abf               — ABF 序列化/反序列化带宽
├── 基准结果存入 bench-results/ (版本化)
红线: PR 不降低基准性能 (或人工审查)

I2.3: 文档生成管线
├── 根据 Step 定义自动生成"当前能力"文档
├── 红线列表自动导出为可读文档
红线: git push → 文档自动更新

I2.4: 增量编译压力测试
├── 生成 1000 函数、10000 行代码
├── 全量编译计时
├── 修改 1 行 → 增量编译计时
├── 验证加速比 >= 50x
红线: 1000 函数全量 < 5s, 增量 < 100ms
```

**里程碑 2 红线**：`(define x (+ y 1))` → 编译期 `error: line 1:14`；1000 行全量 < 5s，1 行增量 < 100ms。

---

## 里程碑 3：查询引擎 + AI 修复闭环

**时间**：8-10 周
**目标**：AI 能通过 AuraQuery 查询 AST、生成补丁、触发增量编译、热更新运行时代码。
**这是 Aura 区别于传统编译器的核心差异化能力。**

### 🏗 Arch-3 — AuraQueryEngine

```
A3.1: 倒排索引核心
├── src/query/index.ixx
│   ├── KindIndex:  NodeKind → vector<NodeID>
│   ├── NameIndex:  Symbol → vector<NodeID>
│   ├── SourceIndex: SourceLocation → vector<NodeID>
│   └── ErrorIndex: error_flag → vector<NodeID>
红线: (node-type Call) 查询 → 返回所有 Call 节点 ID

A3.2: Def-Use 链索引
├── DefUseIndex: Def → vector<Use>, Use → vector<Def>
│   ├── 构建: 遍历 AST 收集定义和使用
│   └── 增量更新: 仅重建变更部分
红线: (query (= (use-count :node) 0)) → 未使用定义

A3.3: 查询计划执行引擎
├── src/query/executor.ixx
│   ├── 接受 QueryPlan 树 (filter/project/join)
│   └── 在索引上执行
红线: Racket 宏展开的查询计划 → C++26 执行 → 结果一致

A3.4: 补丁生成器
├── src/query/patch.ixx
│   ├── PatchGenerator: 查询结果 → ABF Delta 补丁
│   ├── 变换原语: replace-with, wrap-with, insert-before/after
│   └── 补丁验证: 应用后 AST 语义等价
红线: (query-and-fix ...) → ABF Delta → 应用后 AST 正确

A3.5: Compiler Service 集成查询接口
├── src/compiler/compiler_service.ixx 扩展
│   ├── query(AuraQuery) → QueryResult
│   ├── apply_patch(ASTPatch) → CompileResult
│   └── ai_query(sexpr) → QueryResult (AI 友好版)
红线: 所有 Compiler Service API 端到端测试通过
```

### 🗣 Lang-3 — AuraQuery eDSL + 热更新

```
L3.1: AuraQuery 宏 (Racket 端)
├── lang/private/query.rkt
│   ├── (query ...) — 纯查询
│   ├── (query-and-fix ...) — 查询 + 自动修复
│   ├── (query-and-transform ...) — 通用变换
│   └── 宏展开为内部查询计划 S 表达式
红线: (query (node-type Call) (has-error? #t)) → 展开为 query-plan

L3.2: AuraQuery 宏扩展
├── (define-syntax-rule (find-empty-functions) (query ...))
├── (define-syntax-rule (find-potential-infinite-loops) (query ...))
红线: 用户可定义自己的查询 DSL

L3.3: Hot Swap 引擎 (解释器模式)
├── src/runtime/hotswap.ixx
│   ├── FunctionRegistry — 所有可替换函数的注册表
│   ├── SwapPoint — 函数级替换点 (函数指针间接调用)
│   ├── AtomicSwap — 替换后确保旧版本无 inflight 调用
│   └── Rollback — 替换失败时恢复旧版本
红线: 运行中 hot_swap "fact" → 下次调用 (fact 5) 用新版本

L3.4: Hot Swap 追踪
├── SwapDependencyTracker — 函数 A 调用 B → B 替换后 A 也需更新
├── CoherentSwapSet — 一批函数一起替换，保证一致性
红线: 替换 B → 所有调用 B 的函数自动重编译

L3.5: Aura 源文件格式 + 模块导入
├── .aura 文件读取
├── (import "module.aura") — 加载并编译另一个文件
├── 模块作用域隔离
红线: (import "math.aura") → (math/sqrt 9) → 3
```

### 🔧 Infra-3 — 查询测试 + 集成

```
I3.1: AuraQuery 测试套件
├── tests/query/
│   ├── test-basic.rkt     — 基本查询
│   ├── test-transform.rkt — 变换/修复
│   ├── test-fixpoint.rkt  — 多次修复不退化
│   └── test-hotswap.rkt   — 热更新正确性
红线: 所有查询测试通过

I3.2: AI 交互模拟器
├── tools/ai-sim.py — 模拟 Agent 执行 query→fix→compile→swap 闭环
├── 输入: 自然语言描述的修复任务
├── 输出: 修复后的程序 + 执行结果
红线: "修复 factorial 的参数检查" → 自动完成

I3.3: 端到端集成测试
├── tests/integration/
│   ├── e2e-basic.aura     — 基础程序运行
│   ├── e2e-query.aura     — 查询 + 修复
│   ├── e2e-hotswap.aura   — 热更新
│   └── e2e-module.aura    — 多模块
红线: 每个 e2e 测试在 CI 中运行
```

**里程碑 3 红线**：`query → fix → incremental compile → hot swap` 闭环可演示。模拟 Agent 自动修复一个 bug。

---

## 里程碑 4：反射 + 宏

**时间**：8-10 周
**目标**：AI Agent 可运行时自我修改（反射），语言可生长新语法（宏）。

### 🏗 Arch-4 — 反射运行时

```
A4.1: 环境序列化 (Env → ABF)
├── src/runtime/env.ixx
│   ├── export — 当前环境 → 可传输的数据结构
│   ├── import — 恢复环境
│   └── 跨语言: Racket env ↔ C++ env
红线: Racket export env → ABF → C++ import → eval/b 一致

A4.2: C++26 eval/b + enrich
├── eval/b(expr, env) — 在指定环境中求值
├── enrich(env, bindings) — 扩展环境
红线: (eval/b '(+ 1 2) (export)) → 3

A4.3: flambda 运行时支持
├── flambda 参数: (expr, env) → 控制求值
├── 运行时: 传递未求值的参数 AST + 当前环境
红线: flambda 实现自定义求值策略

A4.4: 安全沙箱
├── reflective-lambda — 安全受限的反射
├── 权限系统: 哪些绑定可读/可写/可调用
红线: sandbox 内无法访问 unsafe 操作
```

### 🗣 Lang-4 — 宏 + 自举

```
L4.1: 卫生宏系统 (Racket 端)
├── lang/private/macro.rkt
│   ├── syntax-rules 风格模式匹配
│   ├── hygiene — 自动重命名避免捕获
│   └── expander Pass — 编译期宏展开
红线: (define-syntax-rule (twice x) (* 2 x)) → (twice 5) → 10

L4.2: with-aliases 逃生舱
├── 受控标识符捕获 — DSL 友好
红线: DSL 宏生成绑定 → 可被用户代码引用

L4.3: 持久 AST
├── 从解析到运行时全程保留 AST
├── 序列化: ABF 格式保存完整元数据
├── 反序列化: 恢复完整 AST 结构
红线: 编译 → 序列化 → 反序列化 → AST 结构等价

L4.4: Code Walking
├── macro 可遍历任意深度的 AST 子树
├── 支持: 查找、变换、统计
红线: (walk-ast '(lambda (x) (+ x 1)) '(+ ...)) → 找到所有加法

L4.5: 宏 → 查询引擎集成
├── 宏定义在 AuraQuery 索引中可见
├── 可查询宏的展开历史和用途
红线: (query (node-type Macro) (name "twice")) → 展开结果

L4.6: Sound Gradual Typing (可选)
├── (define (add : Int -> Int) (x : Int) (y : Int) (+ x y))
├── 未标注类型 → 动态检查
├── 已标注类型 → 静态验证
红线: 类型错误在编译期捕获，未标注代码在运行时检查
```

### 🔧 Infra-4 — 文档 + 示例

```
I4.1: 自托管文档系统
├── docs/ 自动化生成
├── 每个宏/内置函数的文档字符串
红线: (help define) → 显示文档

I4.2: 示例代码库
├── examples/
│   ├── hello.aura           — Hello World
│   ├── factorial.aura       — 阶乘
│   ├── query-fix-demo.aura  — AI 修复演示
│   ├── self-modify.aura     — 反射自修改
│   └── dsl-demo.aura        — 宏 DSL 演示
红线: 每个 demo 可运行

I4.3: 性能回归告警
├── CI 自动比较基准结果
├── 性能退化 > 10% → 告警
红线: 基准结果版本化，退化自动检测
```

**里程碑 4 红线**：Agent 写出宏 → 展开 → 使用；Agent eval/b 自修改行为。

---

## 里程碑 5：生产化

**时间**：12-16 周
**目标**：从原型走向可替代旧生态的生产级系统。

### 🏗 Arch-5 — LLVM + AOT + 分布式

```
A5.1: AuraIR → LLVM IR 后端
├── src/compiler/codegen.ixx
│   ├── IRFunction → llvm::Function
│   └── LLVM ORC JIT 集成
红线: (fact 10) → LLVM IR → JIT → 3628800

A5.2: AOT 编译路径
├── src/compiler/aot.ixx
│   ├── IR → C++26 源码生成
│   └── clang++ -ffreestanding → 独立二进制
红线: aura build program.aura → ./program 运行

A5.3: 分布式 Compiler Service
├── gRPC 接口扩展
├── 多 Agent 共享编译缓存
├── 模块注册表 (中央仓库)
红线: Agent A compile → Agent B import → 缓存命中

A5.4: 包管理器
├── aura pkg install <name>
├── aura pkg publish <dir>
红线: 安装包 → import → 使用
```

### 🗣 Lang-5 — 自举

```
L5.1: Aura 编译器用 Aura 写
├── 将 C++26 Compiler Service 的逻辑翻译为 Aura
├── src/ → *.aura 文件
红线: Aura 编译器编译自己

L5.2: 自举验证
├── 用 Aura 编译器编译 Aura 编译器
├── 结果与 C++26 版本行为一致
红线: 自举一次后，不再需要 C++26 版本

L5.3: 性能对标
├── Aura 自举版本 vs Racket 原型
├── 性能目标: 自举版本 >= Racket 版本 2x
红线: 基准测试对比通过
```

### 🔧 Infra-5 — 生态

```
I5.1: LSP 服务器
├── aura lsp — 基于 AuraQueryEngine 的语言服务器
├── 代码补全、跳转定义、查找引用、诊断
红线: VS Code 中编辑 .aura 文件

I5.2: 调试器
├── aura debug program.aura
├── 断点、单步、变量查看
红线: 可调试 factorial

I5.3: 包注册表
├── registry.aura-lang.org
├── 包搜索、版本管理、依赖解析
红线: aura pkg search "json" → 结果
```

**里程碑 5 红线**：`Aura 编译器编译 Aura 编译器` → 自举成功。

---

## 时间线（并行三轨）

```
里程碑   │ 时间      │ 架构 Step  │ 语言 Step  │ 基建 Step
─────────┼───────────┼───────────┼───────────┼───────────
M0 种子   │ 已完成     │ A0.1-0.3   │ L0.1-0.8   │ I0.1-0.3
M1 C++求值│ 第 1-8 周  │ A1.1-1.5   │ L1.1-1.8   │ I1.1-1.5
M2 管线   │ 第 9-18 周 │ A2.1-2.5   │ L2.1-2.8   │ I2.1-2.4
M3 查询   │ 第 19-28周│ A3.1-3.5   │ L3.1-3.5   │ I3.1-3.3
M4 反射   │ 第 29-38周│ A4.1-4.4   │ L4.1-4.6   │ I4.1-4.3
M5 生产   │ 第 39-54周│ A5.1-5.4   │ L5.1-5.3   │ I5.1-5.3
```

总工期：约 54 周（持续演进，非固定截止日期）。

每个里程碑的跨度 = 三个轨道中最慢的那个完成的时间。**允许架构比语言快**（建好骨架等语言填内容），但不允许基建拖后腿。

---

## 关键风险与缓解

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| Racket #lang 源码丢失需重建 | 高 | M1 延迟 1-2 周 | C++ 端先用文本 bootstrap, 并行重建 Racket |
| ABF 跨语言调试困难 | 中 | A1.3-1.4 延迟 | 先以 JSON 作为中间交换格式验证语义, 再切 ABF |
| 增量编译性能不达标 | 中 | M2 延迟 | 允许 T/20 (非 T/100) 作为过渡目标 |
| 热更新导致状态不一致 | 中 | M3 延迟 | 解释器模式先做, JIT 模式后做 |
| P2996 std::meta 编译器支持不足 | 高 | A2 序列化 | fallback: 手动写序列化代码, 反射做 optional |
| AuraQuery 表达力不足 (对 LLM 生成) | 中 | M3 延迟 | 先支持 80% 用例, 不足的通过宏扩展 |

---

## 增量构建红线汇总

```
M0  Step 08: (letrec ((fact ...)) (fact 5)) → 120
M1  Step 16: ./aura REPL 可交互                    → 通过
M2  Step 24: 未绑定变量编译期错误 + 精确源位置       → error: line 1:14
M2  Step 23: 1000行, 改1行, 增量 < 100ms            → 通过
M3  Step 28: (query (node-type Call)) → [42, 57]    → 通过
M3  Step 30: 热替换函数 → 下次调用用新版本            → 通过
M4  Step 32: flambda 自定义求值策略                   → 通过
M4  Step 35: (twice 5) → 10 (宏展开)                → 通过
M4  Step 36: 持久 AST 序列化 → 反序列化 → 等价     → 通过
M5  Step 42: Aura 编译自身                           → 自举成功
Step 43: vs Racket 原型 2x 性能                      → 通过
```

---

> **"不着力。向前走，门会自己打开。"**
> 每一步可运行，每个里程碑可用。三轨并行，从种子长成它能长成的样子。
