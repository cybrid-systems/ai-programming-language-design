# AI 编程语言设计实验室

AI 时代的编程语言，应该是**可证明、可进化、可接管一切**的。

## 目录总览

```
code-learn/        代码库语义分析——从工业级开源项目抽取设计需求
docs/
├── racket/        AI 语言前端——Racket DSL 工厂（CNL + 验证 + 知识图谱）
├── cpp26/         高性能后端——C++26 代码生成与标准跟踪
└── philosophy/    元设计——架构哲学、路线图、自举策略
```

## 每个目录做什么

### 🐧 `code-learn/linux/`

**从代码中学设计**。深度分析生产级代码库，提炼 OS / 系统 / 基础设施语义原语。

目前覆盖 **Linux 内核 7.0-rc1**，128 篇源码分析：
- 数据结构、同步原语、内存管理
- 设备驱动、网络协议栈、文件系统
- 安全审计、虚拟化、调度器

后续计划：LLVM、Redis、Postgres、RocksDB。

→ 输出给前端 DSL 的**设计需求**。

### 🟥 `docs/racket/`

**AI 语言前端**，用 Racket `#lang` 机制构建语言工厂，快速孵化领域 DSL：

- **CNL 约束自然语言** — 自然语言意图 → 可验证约束
- **Rosette 形式验证** — SMT 求解器保证数学正确性
- **Datalog 知识图谱** — 跨 Agent 语义记忆
- **电路 DSL** — 首台验证场景

学习路径：Day 01-14，从 Racket 基础到生产部署。

### 🟦 `docs/cpp26/`

**高性能后端**，C++26 标准特性为前端 IR 提供零开销执行引擎：

- `std::meta` 反射 — DSL → C++ 代码注入
- Contracts — 运行时二次验证
- `consteval-only` — 编译期常量规约
- `inplace_vector` / `std::simd` — 零分配 + 硬件加速

### 📜 `docs/philosophy/`

**全局元设计**，定义三层之间的契约和进化路线：

- 双峰塔架构：Racket 前端（思想纯粹性）+ C++ 后端（代码执行力）
- IR 宪法契约：前后端共享的中间表示规范
- 自举路径：从前端自举 → 后端自举的分阶段计划

## 快速开始

```bash
# 1. 理解为什么是 Racket + C++/LLVM
open docs/philosophy/DESIGN_PHILOSOPHY.md

# 2. 从前端开始学习
open docs/racket/day-01-racket-intro.md

# 3. 跟踪后端标准演进
open docs/cpp26/cpp26-daily-updates-2026-04.md

# 4. 从代码库分析中找需求灵感
open code-learn/linux/README.md
```

## 学习路线

1. **架构篇** → `philosophy/` — 理解分层设计哲学
2. **前端篇** → `racket/` Day 01-14 — 从宏到 CNL 到生产部署
3. **后端篇** → `cpp26/` — Contracts / std::meta / execution
4. **需求篇** → `code-learn/linux/` — 128 篇内核分析提炼 DSL 需求

## 许可证

MIT License
