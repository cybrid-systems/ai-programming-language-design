# AI 编程语言设计实验室

为 AI Agent 设计的语言。从最小 Lisp 核心开始，自然生长，替换旧生态。

## 目录

```
docs/
├── philosophy/          DESIGN_PHILOSOPHY.md（唯一的设计哲学）
├── racket/              01 代码即数据 / 02 语言生长 / 03 可编程编程
└── cpp26/               01 Modules / 02 std::meta / 03 Contracts

code-learn/linux/        代码库语义分析
```

## 实现仓库

本仓库为设计研究仓库。具体实现见：[**Aura**](https://github.com/cybrid-systems/aura) — Racket #lang 原型 + C++26 Compiler as a Service。

| 设计文档 | 对应实现模块 |
|-----------|------------|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | aura 项目的整体架构蓝图 |
| [SERIALIZATION.md](docs/SERIALIZATION.md) | AST 序列化协议 (ABF v2) |
| [AURAQUERY.md](docs/AURAQUERY.md) | AuraQuery eDSL 查询引擎 |
| [CXX_MODULES.md](docs/CXX_MODULES.md) | C++26 后端模块骨架 |

## 开始

```
open docs/philosophy/DESIGN_PHILOSOPHY.md
```

## 许可证

MIT
