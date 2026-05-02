# 02 — 语言生长：最小内核的扩展机制

哲学文档说"最小内核，所有上层语法都是库（macro）"。#lang 机制是这个策略的引擎。

## 核心

`#lang racket` 表示"用 Racket 语言的规则解析后面的代码"。但 Racket 允许定义新的 `#lang`：

```
#lang my-language       ← 用自己的 reader 和 expander 解析
(do-something 42)       ← 代码按 my-language 的语法规则理解
```

定义一个新语言只需要提供两个东西：

1. **reader** — 把代码文本解析为 AST 的规则（可以完全自定义语法）
2. **expander** — 把自定义的 AST 变换回核心语言的宏

这意味着：**语言不是编译器的固定输入，而是种子内核的一个扩展。**

## 生长方式

```
种子内核（最小 Lisp 核心，只有 s-expr + 基本宏）
    ↓ 定义 reader + expander
网络 DSL（#lang net — 引入 socket、packet、connection 原语）
    ↓ 定义 reader + expander
文件系统 DSL（#lang fs — 引入 inode、journal、block 原语）
    ↓ 定义 reader + expander
事务 DSL（#lang tx — 引入 begin、commit、rollback 原语）
```

每个新语言都编译回同一个种子内核。内核不需要变。新的语义只需要在宏层表达。

## 对 AI 意味着什么

AI 遇到一个新的语义域时，不需要等语言设计者加语法。

AI 自己就可以：

1. 分析旧代码库，提取需要的抽象概念
2. 定义新语言（reader + expander）
3. 用新语言重写旧代码
4. 增量编译验证正确性

**语言生长和代码重写是同一步操作。**

## 总结

#lang 机制的本质不是"自定义语法"，而是**语言的自扩展协议**——任何 DSL 都是内核的一个宏展开，内核本身保持不变。这是种子能长成森林的前提条件。
