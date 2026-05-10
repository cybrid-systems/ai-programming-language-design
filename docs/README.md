# 文档结构

```
docs/
├── philosophy/       ← 元设计文档：架构哲学、核心特性、路线图、自举策略
├── racket/           ← AI 语言前端：Racket 学习系列、CNL、DSL 设计、形式验证
├── cpp26/            ← 高性能后端：C++26 标准跟踪、行业分析
├── aura_architecture.md   ← 系统架构：三层分解、模块接口、数据流
├── aura_roadmap.md        ← Ghuloum 37 步增量构建路线图
├── aura_query.md          ← AuraQuery eDSL：原生查询语法、变换、AI 交互
├── aura_serialization.md  ← ABF v2 协议：Trees that Grow + C++26 零拷贝序列化
└── aura_modules.md        ← C++26 模块结构：.ixx 模块划分、CMake 配置
```

## 三层架构对应关系

| 目录/文件 | 对应架构层 | 核心职责 |
|-----------|-----------|----------|
| `philosophy/` | 全局元文档 | 定义三层之间的关系、IR 宪法契约 |
| `aura_architecture.md` | 全局架构 | 模块分解、接口约定、数据流 |
| `aura_roadmap.md` | 全局路线图 | Ghuloum 增量构建计划 |
| `racket/` | 前端（语言层） | 自然语言 → DSL → 形式验证 → IR |
| `cpp26/` | 后端（性能层） | IR → 零开销 C++26 代码生成 + 编译期验证 |
| `aura_serialization.md` | 通信层 | ABF v2 零拷贝二进制协议 |
| `aura_query.md` | AI 交互层 | 原生 eDSL 查询与变换 |
| `aura_modules.md` | 工程层 | C++26 模块文件结构、CMake 构建配置 |

## 实现仓库

设计文档对应的具体实现见 **[Aura](https://github.com/cybrid-systems/aura)** — Racket #lang 原型 + C++26 Compiler as a Service。

## 学习路径

1. 先读 `philosophy/design_philosophy.md` 理解窄门哲学
2. 再读 `aura_architecture.md` 理解三层架构
3. 按番号顺序读 `racket/day-01.md` 到 `racket/day-14.md`
4. 并行参考 `cpp26/` 跟踪后端标准演进
5. 理解序列化和查询：`aura_serialization.md` + `aura_query.md`
6. 参考 `aura_modules.md` 了解 C++26 后端的模块划分
7. 参考 `aura_roadmap.md` 了解开发路线图
8. 到 [Aura 仓库](https://github.com/cybrid-systems/aura) 查看实现状态
