# #2 v2 — Aura Build System (build.py + 9 Gates + CMake + Sanitizer + PGO)

> 接续 #1 v2 Agent Orchestration：上一篇讲了 aura 的运行时核心抽象（Agent）。
> 本文聚焦 aura **构建系统**——`build.py` + 9 个 gate + CMake + Sanitizer + PGO
> + SBOM + Security + Coverage + Fuzz。这是 aura 的 "policy as code" 子系统，
> 与 OB 的 build/test/CI 架构风格一致但更激进（policy 通过 **gates** 强制，
> 不只是通过 build flags）。

---

## 0. 全文导读

Aura 的构建系统是一等公民：

```
build.py (Python 主入口,统一所有子命令)
    ├── gates (9 个静态/动态检查,任何 commit 必须通过)
    ├── cmake (CMake + Makefile/Ninja)
    ├── sanitizer (asan/ubsan/tsan 三种插桩)
    ├── pgo (Profile-Guided Optimization: instrument + train + merge + optimize)
    ├── sbom (CycloneDX 物料清单)
    ├── security (依赖/文件系统漏洞扫描)
    ├── coverage (LLVM source-based coverage)
    ├── fuzz (orchestrator 注册的 fuzzers)
    └── production-concurrency (canary + chaos soak,Nightly gate)
```

本文按"架构 → gates → cmake → sanitizer → pgo → 测试矩阵 → sbom/security →
coverage/fuzz → production-concurrency → 调优"展开。

---

## 1. build.py 整体架构

### 1.1 主入口

```python
#!/usr/bin/env python3
# ~/code/aura/build.py

"""
Aura — 统一构建/测试入口

Usage:
  ./build.py [--sanitizer=asan|ubsan|tsan] build    # CMake 构建 (sanitizer-插桩)
  ./build.py [--sanitizer=asan|ubsan|tsan] test [suite]  # 运行测试
  ./build.py check            # gate + ci(与 CI 相同)
  ./build.py gate             # docs + lint + format + fixtures + surface + binding + registry + dead-heap + aot-stamp + inventory
  ./build.py gate --fix       # 同上,但 auto-regen docs/registry/inventory + lint/format --fix (#1572/#1957)
  ./build.py gate --scripts-only  # 跳过 clang-format(脚本-only,无 C++ 编译)
  ...
"""
```

`build.py` 是 **统一入口**——任何构建/测试/检查操作都从这里开始。这避免
了"cmake 怎么调 / 测哪些套件 / 怎么跑 gate"的混乱。

### 1.2 9 Gates 全景

```python
# ./build.py gate 执行 9 个 gate (按顺序):
# 1. docs              # 从源码生成 docs/generated/*.md
# 2. lint              # Ruff lint + format check (Python)
# 3. format            # clang-format 全树校验 (与 CI gate 相同)
# 4. fixtures          # tests/fixtures/*.json schema 校验
# 5. surface           # primitive surface (新增/删除的原语有据可查)
# 6. binding           # (推测: binding 校验,待确认)
# 7. registry          # docs/generated/test-registry.json 新鲜度 (#1572)
# 8. dead-heap         # dead string_heap_ push audit --strict (#1668)
# 9. aot-stamp         # AOT mangle (0,0) env/linear stamp fence (#2091/#2168)
# 10. inventory        # legacy test inventory (#1957)
```

**关键 insight**: "gate" = 一组 **强制通过** 的检查。CI 上任何 commit 必须
通过所有 gate。这与 OB 的"测试必须全过"思路一致,但 aura 更激进——
gate 包含 **policy check**(如 surface、inventory),不只是功能正确性。

### 1.3 `gate --fix` 模式

```bash
./build.py gate --fix
```

`--fix` 自动修复可修复项:
- docs/auto-regen
- registry/auto-regen
- inventory/auto-regen
- lint/format --fix

**关键 insight**: gate 可自动修复 = "tool 知道什么是对的"。这减少人为
错误,但也意味着 lint rules 必须严格(否则 auto-fix 会破坏代码)。

---

## 2. CMake 集成

### 2.1 cmake/ 模块化

```
cmake/
├── AuraCoverage.cmake            # LLVM source-based coverage
├── AuraIssueBundles.cmake        # Issue #226 unified test_issue_* runner
├── AuraModules.cmake             # C++20 modules 编译选项
├── AuraTest.cmake                # test/CMake 集成
├── aura_module_launcher.sh       # module 启动脚本
└── issue_tests_need_full_llvm.txt # 需要 full LLVM 的 issue tests
```

每个 `.cmake` 文件是一个 **领域模块**——CMake 标准做法。优点:
- 单文件可读(< 200 行)
- 可单独测试
- 可单独替换

### 2.2 AuraModules.cmake (C++20 modules)

```cmake
# C++20 modules 需要特殊编译选项
# clang: -std=c++20 -fmodules
# CMake: CMAKE_CXX_MODULES + target_sources(MODULES ...)
```

aura 使用大量 `.ixx` (module interface units),所以需要专门的 modules
支持。详见 #5 v2 Aura Compiler。

### 2.3 AuraTest.cmake (test runner 集成)

```cmake
# 添加 test target
add_test(NAME ${test_name} COMMAND ${CMAKE_BINARY_DIR}/aura_test_runner
         ${test_arg})

# 注册到 CTest
# docs/generated/test-registry.json 由 CTest 输出生成
```

`AuraTest.cmake` 与 `scripts/python/test_*.py` 配合,生成 test-registry.json
供 gate #7 (registry) 校验。

---

## 3. Sanitizer (asan / ubsan / tsan)

### 3.1 三种 sanitizer

```bash
./build.py --sanitizer=asan build   # AddressSanitizer(内存越界/UAF/泄漏)
./build.py --sanitizer=ubsan build  # UndefinedBehaviorSanitizer(整数溢出/null deref)
./build.py --sanitizer=tsan build   # ThreadSanitizer(data race/deadlock)
```

### 3.2 用途

```
asan:  Memory safety (aura 的 hot path,运行时检测)
       性能损耗 ~2x,开发/PR 阶段开启
       
ubsan: Undefined behavior (整数/类型/Pointer)
       性能损耗 ~10%,release 也开(可选)
       
tsan:  Concurrency (race condition / lock ordering)
       性能损耗 ~5-15x,仅在并发 bug 排查时开
```

### 3.3 何时开什么

| 场景 | sanitizer |
|------|-----------|
| 日常开发 | asan (catch memory bugs early) |
| Release build | ubsan (low overhead) |
| Concurrency bug | tsan (find race) |
| CI / nightly | all 3 (矩阵测试) |

### 3.4 CI 中的 sanitizer 矩阵

```yaml
# .github/workflows/ci.yml (推断)
matrix:
  sanitizer: [none, asan, ubsan, tsan]
  exclude:
    - sanitizer: none
      branch: main  # main 必须有 sanitizer
```

aura 的 CI 跑 4 种配置 × N 个测试 = 数百次 build。

---

## 4. PGO (Profile-Guided Optimization)

### 4.1 4 阶段

```bash
./build.py pgo instrument  # 插桩编译
./build.py pgo train       # 跑 workload 收集 profile
./build.py pgo merge       # 合并多个 profile
./build.py pgo optimize    # 用 profile 做优化编译
./build.py pgo all         # 全流程
```

### 4.2 PGO 加速原理

```
Instrument build:    代码 + 计数器(profile 收集)
Train:               跑真实 workload,profile 文件
Merge:               合并多个 profile 文件
Optimize build:      用 profile 指导编译器:
                      - 分支预测:更准的分支 hint
                      - 内联决策:hot path 函数内联
                      - 代码布局:hot code 紧密排列
```

### 4.3 加速幅度

```
PGO 典型加速: 5-15% (对 hot path 函数)
对 Branchy code (Lisp 解释器/编译器): 10-20%
对 Linear code (媒体编解码): 1-5%
```

aura 是 Lisp 解释器 + 编译器,branch-heavy,PGO 收益较大。

### 4.4 PGO + Sanitizer 冲突

PGO 与 sanitizer 不能同时开(都会插桩)。CI 矩阵需要:
- Release: PGO + ubsan
- Debug: asan + ubsan
- Concurrency: tsan (without PGO)

---

## 5. Test Matrix (8 个 suite)

### 5.1 Suite 列表

```bash
./build.py test unit        # C++ 单元测试 (61 cases)
./build.py test integ       # 端到端管线测试 (.aura)
./build.py test typecheck   # 类型检查测试
./build.py test bench       # Benchmark 基线 + 回归检测
./build.py test smoke       # 快速冒烟测试
./build.py test all         # 全部测试 (默认)
./build.py test core        # 核心管线 (unit + integ + typecheck + smoke + bash + suite)
./build.py test safety      # 安全回归 (gradual + regression + p0)
./build.py test issues      # Issue #226 — unified test_issue_* runner
./build.py test issues-fast # 同上,强制 fast 档
./build.py test check       # 构建 + core + safety + issues (CI 默认)
```

### 5.2 Suite 设计哲学

```
unit       快速 C++ 单元测试 (< 1 min)
           CI 默认每次 PR 都跑

integ      端到端 Aura 脚本测试 (中速, 几 min)
           真实 .aura 文件跑通

typecheck  类型检查专项 (中速)
           测 OCaml-style type inference + denseness

bench      Benchmark + 回归检测 (中速,几 min)
           SLO gate:超过基线 X% → hard fail

smoke      快速冒烟 (秒级)
           dev loop 反馈用

all        全部测试 (CI nightly)
core       核心管线 (CI PR 默认)
safety     安全回归 (CI nightly + release 前)
issues     Issue #226 unified runner (按 issue 跑测试)
issues-fast同上,fast 档(只跑 git 改动 + bundle 子集)
check      gate + ci 全套(CI default)
```

**关键 insight**: aura 的测试 suite **不是按模块** 划分(unit/integration),
而是按 **用途** 划分(单元/集成/类型/性能/冒烟/安全/Issue)。这与 OB 类似
(单元/集成/回归/性能/冒烟),但加了"安全回归"和"Issue runner"——后者是
因为 aura 的 issue 很多,需要专门的 runner(#226 unified)。

### 5.3 Issue Runner (#226)

```bash
./build.py test issues  # 跑所有 test_issue_*.cpp
./build.py test issues-fast  # 强制 fast 档 (只跑改动 + bundle)
```

**关键 insight**: aura 用 issue 编号追踪 bug fix 测试,与 R17 等的
R-series 类似。"改一个 issue + 加 test_issue_N.cpp" 是 aura 的核心开发
节奏。

---

## 6. Gate Details (深入 9 个)

### 6.1 docs gate

```bash
./build.py docs                # 生成 docs/generated/*.md
./build.py docs --check        # 校验生成文档未过期 (CI)
```

从源码扫描注释 + 符号,生成参考文档。`--check` 校验文档与源码一致
(no drift)。

### 6.2 lint gate (Ruff)

```bash
./build.py lint                # Ruff lint + format check (Python)
./build.py lint --fix          # 自动修复
```

只针对 Python 代码。Ruff 是 Rust 写的快速 linter (替代 flake8 + isort +
pyupgrade 等)。

### 6.3 format gate (clang-format)

```bash
./build.py format              # clang-format 全树校验 (与 CI gate 相同)
./build.py format --fix        # clang-format -i 自动修复 src/ + tests/
```

**关键 insight**: `format --fix` 与 `gate --fix` 解耦——可以只 fix 格式不
跑 gate。

### 6.4 fixtures gate

```bash
./build.py fixtures --check    # 校验 tests/fixtures/*.json schema
```

test fixture 是测试输入(schema 校验)。改 fixture 触发重新校验。

### 6.5 surface gate (primitive surface)

```bash
./build.py surface             # 校验 primitive 增删有据
```

**关键 insight**: aura 的 primitive 是稳定的 API surface。增删 primitive 必须
有 commit message / issue 引用,否则 gate fail。这避免"无意中删 API"。

### 6.6 registry gate (#1572)

```bash
./build.py test-registry       # 校验 docs/generated/test-registry.json 新鲜度
./build.py test-registry --fix  # 重新生成 test-registry.json
```

test-registry 是测试的元数据。改了测试代码必须 regen,否则 CI fail。

### 6.7 dead-heap gate (#1668)

```bash
./build.py dead-heap-push      # dead string_heap_ push audit --strict
```

检测"无人引用"的 `string_heap_` push(死代码)。

### 6.8 aot-stamp gate (#2091/#2168)

```bash
./build.py aot-env-linear-stamp  # AOT mangle (0,0) env/linear stamp fence
```

校验 AOT (Ahead-Of-Time) 编译时的 mangle stamp 一致性(env + linear types
的 mangle 不能冲突)。

### 6.9 inventory gate (#1957)

```bash
./build.py legacy-test-inventory  # legacy test inventory freshness
./build.py legacy-test-inventory --fix  # regen
```

legacy test 是历史的 R-series / 早期 issue test,需要定期刷新。

---

## 7. SBOM + Security

### 7.1 SBOM (CycloneDX)

```bash
./build.py sbom [--version=V]   # CycloneDX SBOM 生成 (#675)
```

SBOM = Software Bill of Materials,软件物料清单。供应链安全审计用。

### 7.2 Security Scan

```bash
./build.py security            # 依赖/文件系统漏洞扫描 (#675)
```

扫描依赖 + 文件系统的已知 CVE。

### 7.3 Repro Build (#675)

```bash
./build.py repro [--verify]    # 可复现 Release 构建
```

"Reproducible build" = 同一源码在任何机器上编译出 byte-identical 二进制。
供应链可信。

---

## 8. Coverage (LLVM Source-Based)

### 8.1 Coverage Report

```bash
./build.py coverage --html     # LLVM source-based coverage report (#1933)
./build.py coverage --check-tools  # verify llvm-cov tooling only
```

### 8.2 原理

```
1. instrument build: clang -fprofile-instr-generate
2. 跑测试,生成 .profraw 文件
3. llvm-profdata merge → .profdata
4. llvm-cov report → HTML / text report
```

### 8.3 覆盖率 vs 行覆盖

```
Line coverage:    每行执行次数
Branch coverage:  每分支 (if/else) 是否都执行
Region coverage:  每个 region 是否进入
```

LLVM coverage 同时给出三者。

---

## 9. Fuzz Testing (#1935)

### 9.1 Fuzzer 列表

```bash
./build.py fuzz --list         # 列出注册的 fuzzers
./build.py fuzz --all --quick  # 跑 fuzz orchestrator
```

### 9.2 fuzz orchestrator

```
管理多个 fuzzer(每个 fuzzer 独立 corpus + seed)
- 启动 N 个 fuzzer 并行
- 收集 crash / coverage 数据
- 定期 merge corpus
- 报告进度
```

### 9.3 aura 的 fuzz 重点

aura 是 Lisp 解释器,fuzz 重点:
- Parser(随机字节 → parse 不 panic)
- Evaluator(随机 AST → evaluate 不 crash)
- Compiler(随机 .aura 脚本 → AOT 不 segfault)

---

## 10. Production Concurrency Gate (#2380/#2513)

### 10.1 设计

```bash
./build.py production-concurrency  # canary + full chaos soak
./build.py production-concurrency-coverage  # static AC contract rows
```

**环境变量**(Soak 模式):
```bash
AURA_CHAOS_SOAK=1                    # 开启 chaos soak
AURA_CHAOS_FIBERS=256..1000          # fiber 数量
AURA_CHAOS_DURATION_S=300+           # 持续时间
```

### 10.2 chaos 测试内容

```
- 大量 fiber 并发跑 task
- mailbox BP 触发
- panic + recover
- GC 压力
- mutation safety 检查
- fiber steal hard-fail 校验
```

### 10.3 short PR chaos gate (#2554)

```bash
AURA_CHAOS_PR_GATE=1 ./build.py gate
```

**关键 insight**: gate 默认会跑一次**短时 chaos**(几秒),验证 PR 不
破坏核心 mutation / fiber 安全。这是 "stat gate 不能发现的并发 bug 在
PR 阶段就被发现" 的尝试。

---

## 11. 调优 Checklist

```
□ Sanitizer 选对了?
  - 开发: asan
  - Release: ubsan (低开销)
  - Concurrency bug: tsan

□ PGO 开了?
  - Release build 强烈建议 PGO (5-15% 加速)
  - 定期 retrain profile (代码改了,profile 失效)

□ Test suite 选对了?
  - dev: smoke (秒级反馈)
  - PR: check (gate + ci 全套)
  - Release: all (含 safety + issues)

□ Gate 都过了?
  - 任何 --strict 模式必须 hard fail
  - CI 上 gate 不通过 = 拒绝 merge

□ SBOM + Security?
  - Release 前必跑 security 扫描
  - SBOM 提交到 artifact store

□ Coverage 趋势?
  - 新代码必须覆盖
  - PR 降低覆盖率 = 拒绝

□ Chaos soak?
  - Release 前必跑 (夜间)
  - 任何 fiber/mailbox bug 都会被 soak 发现

□ Repro build?
  - 关键 release 用 repro build (供应链可信)
```

---

## 12. v2 subseries 收官回顾（aura v2 #2）

接续 #1 v2 Agent Orchestration,本文聚焦 build 系统。

```
aura v2 deep-dive 系列 (本篇为 #2):

#1 v2  Agent Orchestration (orch.ixx + agent_spawn.h + AgentScope) ✅
#2 v2  Build System (build.py + 9 gates + CMake + Sanitizer + PGO)  ← 本文
#3 v2  Parser (S-expression + Racket 兼容)
#4 v2  Runtime (runtime.c + JIT 桥接)
#5 v2  Compiler (C++26 modules + AOT/JIT)
#6 v2  Fiber System (concurrency + GC hooks)
#7 v2  Type System (type_dep freshness + denseness)
#8 v2  Module System (multi-define + require)
#9 v2  JIT / AOT (aura_jit + hot-update + aot_mangle)
#10 v2 Self-Modification (代码自己进化的核心机制)
```

---

## 13. 下一篇预告

按 aura 主题自然顺序:

- **#3 v2 Parser** — S-expression 词法 + 语法分析(简洁但基础)
- **#4 v2 Runtime** — runtime.c + JIT 桥接(交叉 C/C++ 边界)
- **#5 v2 Compiler** — 182 文件 + C++26 modules(核心深入)
- **#6 v2 Fiber System** — 并发 + GC hooks(配合 #1 orchestration)

下一篇选哪个?

---

## 14. 参考(可执行的源码锚点)

- `~/code/aura/build.py` — Python 主入口,统一所有子命令
- `~/code/aura/CMakeLists.txt` — 顶层 CMake(235KB,详细)
- `~/code/aura/CMakePresets.json` — CMake presets
- `~/code/aura/cmake/AuraCoverage.cmake` — LLVM coverage 集成
- `~/code/aura/cmake/AuraIssueBundles.cmake` — Issue #226 unified runner
- `~/code/aura/cmake/AuraModules.cmake` — C++20 modules 编译
- `~/code/aura/cmake/AuraTest.cmake` — test/CMake 集成
- `~/code/aura/tests/python/_aura_harness.py` — test harness(B/G/N/R/Y 颜色)
- `~/code/aura/tests/bench/benchmark_cases.py` — benchmark 加载
- `~/code/aura/tests/integ/integ_cases.py` — integ 加载
- `~/code/aura/tests/issue_tier.py` — issue tier 分类
- `~/code/aura/scripts/check_orch_mvp_scope.py` — MVP scope linter(已深入)
- `~/code/aura/scripts/check_fiber_mutate_safety.py` — fiber mutation linter
- `~/code/aura/.githooks/` — Git hooks (commit 时跑 gate)
- `~/code/aura/.github/workflows/` — GitHub Actions CI 矩阵

---

#2 v2 (aura) 完。