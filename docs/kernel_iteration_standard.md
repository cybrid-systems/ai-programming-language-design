# Aura 内核迭代标准

**版本**：v2.0
**原则**：测试先行（TDD），FlatAST 唯一规范，`build.py` 统一验证。

---

## 0. 核心纪律

### 提交纪律

1. **每步可测试** — 每次提交必须能通过 `./build.py check`
2. **测试先行** — 代码改动前先写/改测试
3. **增量提交** — 一个功能一个提交，不混改
4. **提交信息包含测试计数** — 如 `Tests: 61/61 CTest + 42/42 benchmark`

### 架构纪律

1. **FlatAST 是唯一 AST** — 不再新增 Expr* 指针树代码。`reconstruct_expr` 只在 `eval_flat` 的 MacroDef 闭包桥接中使用
2. **不建平行管线** — 所有新特性只需要一条实现路径：FlatAST 原生
3. **测试写 Python，不写 C++** — 端到端测试用 `build.py` 的 `IntegCase`，不写新的 `test_*.cpp`
4. **改旧必清** — 改某个旧模块时，顺手删其对应的死代码（如改 TypeChecker 时删 Expr* 旧路径）

### 迭代纪律

1. **小步快跑** — 每个波次不超 1 小时；超时则拆子任务
2. **子代理只干体力活** — 重构/迁移/清理适合子代理；设计决策自己拿
3. **删除前先确认引用** — `grep -rn` 确保没有调用者再删
4. **减法优先于加法** — 新代码不超 200 行/提交（重写除外）

---

## 1. 测试框架

所有测试通过顶层 `build.py` 统一入口：

```bash
./build.py build              # 构建
./build.py test               # 全部 5 套件
./build.py test unit          # C++ 单元测试
./build.py test integ         # 端到端管线测试
./build.py test typecheck     # 类型检查专项
./build.py test bench         # Benchmark 基线
./build.py test smoke         # 快速冒烟
./build.py check              # 构建 + 全部测试
```

### 套件详情

| 套件 | 文件 | 语言 | 数量 | 覆盖 |
|------|------|------|------|------|
| `unit` | `test_ir.cpp` | C++ | 61 | IR 管线/查询引擎/内存池/TypeChecker |
| `integ` | `build.py` (IntegCase) | Python | 29 | eval/IR/typecheck 端到端管线 |
| `typecheck` | `build.py` (TyCase) | Python | 10 | 类型系统专项 |
| `bench` | `benchmark.py` | Python | 42 | 性能基线 + 回归检测 |
| `smoke` | `build.py` (SMOKE) | Python/bash | 5 | 快速冒烟 |

### 添加测试用例

**端到端测试**（推荐）— 在 `build.py` 的 `INTEG_TESTS` 列表里加一行：

```python
IntegCase("my_feature", "(my-expr arg)", "eval", expected="42"),
```

参数：
- `name` — 测试名，`-` 可读即可
- `code` — Aura 表达式
- `pipeline` — `"eval"` | `"ir"` | `"typecheck"` | `"serve"`
- `expected` — stdout 应包含的子串（空字符串 = 不检查）
- `expected_err` — stderr 应包含的错误子串
- `expected_status` — 期望退出码（默认 0）

**Benchmark 测试** — 在 `benchmark.py` 的 `BENCHMARKS` 列表里加：

```python
BenchCase("bench_name", "(+ 1 2)", "eval", expected_val=3),
```

**TypeChecker 专项** — 在 `build.py` 的 `test_typecheck()` 函数里加：

```python
("test_name", "(+ 1 2)", "Int", True),  # (name, code, expected_type, should_pass)
```

---

## 2. 新增语言特性的标准管线

每加一个新特性，必须穿透这条路径：

```
FlatAST → parse_to_flat → lower_to_ir → IRInterpreter → EvalResult
    ↑                         ↓
  [FlatParser]             [PassManager: compute-kind → arity → const-fold]
    ↑                         ↓
  [Lexer]                  [IRInterpreter: closures + cells + coercion]
```

对应的文件层级：

```
Layer  组件              文件                        责任
────  ────────────────  ─────────────────────────  ─────────────────────────
  1   AST 数据结构       src/core/ast_flat.ixx      NodeTag + NodeMeta 表
  2   FlatAST 构造器     src/core/ast_flat.ixx      add_xxx 方法
  3   扁平解析器          src/parser/flat_parser*   parse_xxx 函数
  4   求值器 (树遍历)    src/compiler/frontend*     eval_in 分支 + primitives
  5   IR 降低            src/compiler/lowering*     lower_xxx（FlatAST 版本）
  6   IR 解释器          src/compiler/ir_interp*    执行新指令
  7   类型检查 (可选)    src/compiler/type_checker* synthesize_flat_xxx + check
  8   测试               build.py / benchmark.py    IntegCase + BenchCase

注: ABF 序列化/反序列化、查询引擎、reconstruct_expr 不再需要每个特性单独处理；
    FlatAST 统一了 AST 表示，所有下游自动覆盖。
```

**强制规则**：
- 第 8 层（测试）必须在第 1 层之前写
- 不需要 ABF 序列化——Racket 前端独立维护其 ABF 生成
- 不需要查询引擎适配——通用 `(node-type ...)` 自动覆盖新节点

---

## 3. 模块同步清单

```
特性: ____________  日期: ____________

Tests (先写):
  [ ] IntegCase 已添加到 build.py
  [ ] BenchCase 已添加到 benchmark.py（如适用）
  [ ] `./build.py test integ` 通过

Layer 1: src/core/ast_flat.ixx
  [ ] NodeTag 枚举值（如需要新节点类型）
  [ ] kNodeMeta 表条目
  [ ] add_xxx 构造器

Layer 2: src/parser/flat_parser_impl.cpp
  [ ] 关键字检查（如适用）
  [ ] parse_xxx 函数

Layer 3: src/compiler/frontend_impl.cpp
  [ ] eval_in 分支
  [ ] primitives（如适用）

Layer 4: src/compiler/lowering_flat_impl.cpp
  [ ] lower_flat_expr case
  [ ] collect_free_vars case（如适用）

Layer 5: src/compiler/ir_interpreter_impl.cpp
  [ ] 新指令处理（如需要）

Layer 6: src/compiler/type_checker_impl.cpp (可选)
  [ ] synthesize_flat dispatch
  [ ] 新节点类型处理

Verification:
  [ ] `./build.py check` 全绿
  [ ] 手动验证关键场景
```

---

## 4. 提交模板

```
<类型>: <简短描述>

（可选详细说明，重点写 why 而不是 what）

文件变更:
  src/compiler/xxx.ixx          +12/-5    新增 infer_flat
  tests/xxx.cpp                 +30/-0    添加测试用例

Tests: 61/61 CTest + 42/42 benchmark + 29/29 integ 全绿
```

类型前缀：
- `feat` — 新功能
- `fix` — 修 bug
- `refactor` — 重构（无行为变化）
- `test` — 测试
- `docs` — 文档
- `chore` — 构建/工具链
- `cleanup` — 删除死代码

---

## 5. 架构状态看板

```
特性            FlatAST 解析 求值 IR 类型 测试  整体
────────────────────────────────────────────────
整数            ✅ ✅ ✅ ✅ ✅ ✅ ✅
变量            ✅ ✅ ✅ ✅ ✅ ✅ ✅
lambda          ✅ ✅ ✅ ✅ ✅ ✅ ✅
if              ✅ ✅ ✅ ✅ ✅ ✅ ✅
算术            ✅ ✅ ✅ ✅ ✅ ✅ ✅
布尔            ✅ ✅ ✅ ✅ ✅ ✅ ✅
序对            ✅ ✅ ✅ ✅ ✅ ✅ ✅
begin           ✅ ✅ ✅ ✅ ✅ ✅ ✅
set!            ✅ ✅ ✅ ✅ ✅ ✅ ✅
quote           ✅ ✅ ✅ ✅ ✅ ✅ ✅
cond            ✅ ✅ ✅ ✅ ✅ ✅ ✅
defmacro        ✅ ✅ ✅ ✅ ✅ ✅ ✅
字符串          ✅ ✅ ✅ ✅ ✅ ✅ ✅
letrec          ✅ ✅ ✅ ✅ ✅ ✅ ✅
类型系统 L6     ✅ —  — ✅ ✅ ✅ ✅
渐进类型 L6.6   ✅ —  — ✅ ✅ ✅ ✅
Hot swap(M2.6)  ✅ —  — ✅ ✅ ✅ ✅
────────────────────────────────────────────────
当前测试覆盖:  147 条（unit 61 + integ 29 + typecheck 10 + bench 42 + smoke 5）
```

---

## 6. 相关工作流

### 日常开发

```bash
./build.py build      # 先构建
# ... 改代码 ...
./build.py test       # 跑全部测试
git add && git commit
git push
```

### AI Agent 开发

```bash
# 1. serve 模式 — 代码自动修复循环
printf '(+ x 1)' | ./aura --serve

# 2. 查询 AST
echo '(+ 1 2)' | ./aura --query '(node-type Call)'

# 3. 查询 + 变换
echo '(+ 1 2)' | ./aura --query-and-fix '(node-type LiteralInt)' '(LiteralInt 99)'

# 4. 类型检查
echo '(+ 1 "a")' | ./aura --typecheck

# 5. 热替换（运行时升级函数）
echo '(+ 1 2)' | ./aura --hot-swap      # seed cache
echo '(+ 1 3)' | ./aura --hot-swap      # 替换入口函数

# 6. 基准回归
python3 tests/benchmark.py --check

# 7. 检测代码大小
wc -l src/**/*.ixx src/**/*.cpp | sort -rn | head -20
```

---

## 7. 减法清单（可清理的存量）

```
待清理项                            预估行数  优先级
───────────────────────────────────────────
旧 tree-walker Parser (降低清理)    — ✅ 已删
LoweringPass (Expr* → IR)          — ✅ 已删
TypeChecker Expr* 路径              — ✅ 已删
───────────────────────────────────────────
Racket ABF 前端（lang/private/）    ~500    低（功能完善，但 Aura 不依赖它启动）
旧测试脚本（run_step*）              ~100    低（被 build.py 覆盖）
静态红名单（*_redlines.txt）         ~50    低（未维护）
```

---

> **FlatAST 是唯一规范。build.py 是唯一入口。测试先行，减法优先。**
