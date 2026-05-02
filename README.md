# AI 编程语言设计实验室

AI 时代的语言，为 AI Agent 设计。

## 目录

```
docs/
├── philosophy/DESIGN_PHILOSOPHY.md     ← 唯一的设计哲学
├── racket/                              ← 语言层的三篇核心
└── cpp26/                               ← 编译器基础设施

code-learn/linux/                        ← 代码库源码分析
```

### `code-learn/linux/`

从生产级代码库中提取真实世界的语义需求。目前是 Linux 内核源码分析。

### `docs/racket/`

语言层的三篇核心：代码即数据、语言生长、可编程编程。

### `docs/cpp26/`

编译器基础设施：Modules（增量编译基座）、std::meta + consteval（编译期代码能力）、Contracts（编译器自检）。

### `docs/philosophy/`

只有一篇 `DESIGN_PHILOSOPHY.md`——定义了整个项目为什么存在。

## 开始

```
open docs/philosophy/DESIGN_PHILOSOPHY.md
```

## 许可证

MIT
