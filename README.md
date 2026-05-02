# AI 编程语言设计实验室

AI 时代的编程语言，应该是**可证明、可进化、可接管一切**的。

## 三层架构

```
codebases/  ← 语义需求层：从工业级开源项目抽取 OS/系统语义原语
   ↓ 自然语言 → DSL 设计需求
docs/racket/ ← 前端/语言层：Racket 语言工厂——CNL、#lang、Rosette 验证
   ↓ IR 宪法契约
docs/cpp26/ ← 后端/性能层：C++26 高性能零开销执行引擎
```

### 🐧 `codebases/` — 语义需求抽取

从 Linux 内核（125 篇分析）、未来 LLVM/Redis/Postgres/RocksDB 等生产级代码库中提炼：

- 数据结构/同步/内存的**核心语义原语**
- 驱动/网络/文件系统的**领域约束模式**
- 安全/审计/虚拟化的**可证明不变量**

→ 输出给前端 DSL 的设计需求

### 🟥 `docs/racket/` — AI 语言前端

用 Racket `#lang` 机制构建**语言工厂**，快速孵化领域 DSL：

- **CNL 约束自然语言** — 自然语言意图 → 可验证约束表达式
- **Rosette 形式验证** — SMT 求解器保证代码的数学正确性
- **Datalog 知识图谱** — 跨 Agent 的语义记忆和意图追溯
- **Places 分布式** — 多进程并行执行
- **电路 DSL** — 首台验证场景：自然语言 → 电路 → 仿真器

### 🟦 `docs/cpp26/` — 高性能后端

C++26 标准特性为验证通过的 IR 提供零开销执行引擎：

- **std::meta 反射** — DSL → C++ 代码注入口
- **Contracts** — 运行时二次验证
- **consteval-only** — 编译期常量的约束规约
- **inplace_vector / std::simd** — 零分配 + 硬件加速

### 📜 `docs/philosophy/` — 全局元设计

定义三层之间的契约和进化路线：

- **双峰塔架构**：Racket 前端（思想纯粹性）+ C++ 后端（代码执行力）
- **IR 宪法**：前后端共享的中间表示规范（最高优先级）
- **自举路径**：从前端自举 → 后端自举的分阶段计划

## 快速开始

```bash
# 1. 理解架构哲学
open docs/philosophy/DESIGN_PHILOSOPHY.md

# 2. 从 Racket 前端开始
open docs/racket/day-01-racket-intro.md

# 3. 紧跟 C++26 后端标准
open docs/cpp26/cpp26-daily-updates-2026-04.md

# 4. 从代码库分析中找需求灵感
open codebases/README.md
```

## 学习路线

1. **架构篇**：`philosophy/` → 理解为什么 Racket + C++/LLVM
2. **前端篇**：`racket/` Day 01-14 → 从宏到 CNL 到生产部署
3. **后端篇**：`cpp26/` → Contracts / std::meta / execution
4. **需求篇**：`codebases/` → Linux 内核 125 篇分析 → 提炼 DSL 需求

## 许可证

MIT License
