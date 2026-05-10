# Aura — 端到端 MVP 路线图

**核心目标**：在最短时间内跑通 **Racket #lang → ABF 序列化 → C++ 求值 → 结果返回** 的完整闭环。

**方法**：《An Incremental Approach to Compiler Construction》（Ghuloum, ICFP 2006）
**原则**：每一步增加一个最小功能，系统始终可运行、可测试。
**三轨并行**：架构 / 语言 / 基建 三个轨道同时推进，每个里程碑产生可用的垂直切片。

---

## 三轨定义

| 轨道 | 范围 | 产出物 | 核心文档 |
|------|------|--------|----------|
| **🏗 架构 (Arch)** | Compiler Service、ABF 协议、IPC、模块系统 | 系统骨架与通信管道 | `aura_architecture.md`、`aura_serialization.md`、`aura_modules.md` |
| **🗣 语言 (Lang)** | 从最小核心到完整 Lisp 语义 | 语言本身 | `aura_architecture.md §3`、`aura_query.md` |
| **🔧 基建 (Infra)** | CMake 预设、CTest、CI | 开发者工具链 | `aura_modules.md` |

---

## MVP 总览

```
                  Sprint A           Sprint B           Sprint C
                 Racket + ABF       C++ 完整语言       E2E 闭合
                  Week 1-2           Week 2-5           Week 5-6
                 ┌──────────┐     ┌──────────┐      ┌──────────┐
🏗 Arch           │ A0 + A1.3│     │ A1.4     │      │ A1.5     │
                 │ #lang重建 │     │ ABF反序列│      │ 共享内存 │
                 │ ABF序列化│     │          │      │          │
                 └──────────┘     └──────────┘      └──────────┘
                 ┌──────────┐     ┌──────────┐      ┌──────────┐
🗣 Lang           │ L0.1-L0.8│     │ L1.3-L1.8│      │ MVP演示  │
                 │ Racket   │     │ 算术/条件│      │ 完整流程 │
                 │ 全语义   │     │ 闭包/define│    │          │
                 └──────────┘     └──────────┘      └──────────┘
                 ┌──────────┐     ┌──────────┐      ┌──────────┐
🔧 Infra          │ CMake预设 │     │ CTest扩展 │     │ 回归管线 │
                 │ Clang导入│     │ 基准框架 │      │ CI自动  │
                 └──────────┘     └──────────┘      └──────────┘
                          ↑                     ↑
                   当前已完成
Sprint B: C++ 完整语言 ✅                  MVP 红线
                   Step 09-10                 racket -l aura
                   (C++ 文本输入)         → ABF → ./aura → 42
```

**MVP 红线**：

```bash
$ echo '(let ((x 10)) x)' | racket -l aura --abf | ./aura --abf
10
```

---

## Sprint A: 重建 Racket #lang + ABF 序列化 (第 1-2 周)

**并行策略**：Racket 前端和 C++ 后端独立推进，通过文本 S 表达式和 JSON 作为临时桥梁。

### 🏗 Arch-A — Racket #lang + ABF 通道

| Step | 新增 | 红线 |
|------|------|------|
| **A0.1** | `#lang aura` reader + 项目骨架 | `racket -l aura` 无报错 |
| **A0.2** | `lang/private/core.rkt` — Racket 中写的最小 Lisp 求值器 | `(eval 42)` → `42` |
| **A0.3** | REPL 循环 | 可交互输入 |
| **A1.3** | ABF 序列化器 (Racket 端) — AST → ABF 二进制 | `(abf-serialize '(+ 1 2))` → bytes |

**展开**：A0.1-A0.3 实际上就是重建 Ghuloum Step 01-08（之前 subagent 写过一次，有编译产物为证），按 `docs/aura_architecture.md §3.1` 的结构恢复。A1.3 输出与 `docs/aura_serialization.md §4` 定义的 ABF v2 格式对齐。

### 🗣 Lang-A — Racket 全语义

| Step | 新增 | 红线 |
|------|------|------|
| L0.1 | 整数字面量 | `(eval 42)` → `42` |
| L0.2 | 变量引用 | `(eval 'x '{x 10})` → `10` |
| L0.3 | lambda + 函数应用 | `(eval '((lambda (x) x) 1))` → `1` |
| L0.4 | if 条件 | `(eval '(if #t 1 2))` → `1` |
| L0.5 | let + letrec | `(eval '(let ((x 5)) x))` → `5` |
| L0.6 | quote + 基本数据 | `(eval '(quote (a b)))` → `(a b)` |
| L0.7 | Hyperstatic define | `(eval '(define x 5) env)` |
| L0.8 | REPL | `racket -l aura` 可交互 |

**红线**：`(letrec ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))) (fact 5))` → `120`

### 🔧 Infra-A — 构建基础

| Step | 新增 | 红线 |
|------|------|------|
| I0.1 | Racket 包结构 (`info.rkt`, `raco test`) | `raco test` 通过 |
| I0.2 | C++ 端 CMake 预设 (Clang + libc++) | `cmake --preset debug` → 成功 |
| I0.3 | CTest 基础测试 (当前 8 个测试) | `ctest --test-dir build` → 8/8 |

---

## Sprint B: C++ 完整语言 (第 2-5 周)

与 Sprint A 并行推进。当前已完成
Sprint B: C++ 完整语言 ✅ L1.1 (整数) + L1.2 (变量/let)。

### 🏗 Arch-B — ABF 反序列化

| Step | 新增 | 红线 |
|------|------|------|
| **A1.4** | C++26 ABF v2 反序列化器 | Racket 输出的 ABF bytes → C++ Expr 结构等价 |

**完整实现见** `docs/aura_serialization.md §4.4`。可以先用 JSON 作为临时交换格式（Racket 输出 JSON + Python 验证），再切 ABF，避免跨语言调试卡住。

### 🗣 Lang-B — 从整数到完整 Lisp

| Step | 新增 | 红线 |
|------|------|------|
| L1.1 | 整数字面量 | `echo 42 \| ./aura` → `42` | ✅ 已完成 |
| L1.2 | 变量 + let 绑定 | `(let ((x 10) (y 20)) x)` → `10` | ✅ 已完成 |
| **L1.3** | 算术原语 (`+ - * / = < >`) | `(+ 1 (* 2 3))` → `7` | ✅ |
| **L1.4** | 条件分支 (`if`) | `(if (> 3 2) 1 0)` → `1` | ✅ |
| **L1.5** | 闭包 + 函数应用 | `((lambda (x) (* x 2)) 5)` → `10` | ✅ |
| **L1.6** | letrec (递归绑定) | `(letrec ((fact ...)) (fact 5))` → `120` | ✅ |
| **L1.7** | Hyperstatic define + 模块 | `(define x 5)` → 全局环境 | ✅ |
| **L1.8** | C++ REPL | `./aura` 交互式 | ✅ |

### 🔧 Infra-B — 测试 + 基准

| Step | 新增 | 红线 |
|------|------|------|
| I1.2 | CTest 扩展到 ~20 个测试 | 每个 Step 对应 2-3 个测试 |
| I1.3 | 基准框架 (求值吞吐量) | `./benchmark` → CSV 可记录 |
| I1.4 | 回归测试自动化 | `python regress.py` → ALL PASS |

---

## Sprint C: E2E 闭合 + ABF 联调 (第 5-6 周)

### 🏗 Arch-C — 传输层

| Step | 新增 | 红线 |
|------|------|------|
| **A1.5** | 共享内存 / UDS 传输 | Racket → ABF → mmap → C++ → 求值结果 |

先用 `system` / `popen` 走管道最简单，后续再上共享内存。

### 🗣 Lang-C — MVP 演示

演示场景：Racket 中编写的 Aura 程序 → ABF 二进制传输 → C++ 执行 → 结果返回。

```bash
# 最终 MVP 演示
$ cat demo.aura
(let ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1)))))))
  (fact 10))

$ racket -l aura demo.aura --abf | ./aura --abf
3628800
```

### 🔧 Infra-C — CI 自动化

| Step | 新增 | 红线 |
|------|------|------|
| I1.5 | GitHub Actions CI | PR → 自动构建 + `ctest` |

---

## 后续里程碑

MVP 闭合之后的完整计划与原有 `aura_roadmap.md` 的 M1-M5 一致：

| 里程碑 | 内容 | 时间 |
|--------|------|------|
| M1 | C++ IR 管线 (AuraIR + 增量编译 + 静态检查) | Sprint C 后 4-6 周 |
| M2 | AuraQuery 引擎 (倒排索引 + eDSL + 热更新) | M1 后 6-8 周 |
| M3 | 反射 + 宏 (eval/b + flambda + 卫生宏) | M2 后 6-8 周 |
| M4 | 生产化 (LLVM + AOT + 自举) | M3 后 12 周 |

详细步骤见下方 **里程碑 1-5** (M1: C++ 求值器 → M2: IR 管线 → M3: 查询引擎 → M4: 反射 → M5: 生产化)。

---

## 增量构建红线汇总

```
Sprint A: (letrec ... (fact 5)) → 120                    # Racket 端
Sprint B: ./aura REPL 可交互                              # C++ 端
Sprint C: racket → ABF → ./aura → 3628800                # E2E
M1: 未绑定变量编译期错误 + 精确源位置                       # error: line 1:14
M1: 1000行, 改1行, 增量 < 100ms                            # 增量编译
M2: (query (node-type Call)) → [42, 57]                   # 查询引擎
M2: 热替换函数 → 下次调用用新版本                            # 热更新
M3: flambda 自定义求值策略                                  # 反射
M3: (twice 5) → 10 (宏展开)                               # 宏
M4: Aura 编译自身                                          # 自举
```

---

> **"向前走，门会自己打开。"**
> 每一步可运行，每个 Sprint 可演示。先通 MVP，再长成它能长成的样子。
