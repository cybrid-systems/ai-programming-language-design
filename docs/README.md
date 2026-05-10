# 文档结构

```
docs/
├── philosophy/       ← 元设计文档：架构哲学、核心特性、路线图、自举策略
├── racket/           ← AI 语言前端：Racket 学习系列、CNL、DSL 设计、形式验证
├── cpp26/            ← 高性能后端：C++26 标准跟踪、行业分析
├── ARCHITECTURE.md   ← 系统架构：三层分解、模块接口、数据流
├── AURAQUERY.md      ← AuraQuery eDSL：原生查询语法、变换、AI 交互
└── SERIALIZATION.md  ← ABF v2 协议：Trees that Grow + C++26 零拷贝序列化
```

## 三层架构对应关系

| 目录/文件 | 对应架构层 | 核心职责 |
|-----------|-----------|----------|
| `philosophy/` | 全局元文档 | 定义三层之间的关系、IR 宪法契约 |
| `ARCHITECTURE.md` | 全局架构 | 模块分解、接口约定、数据流 |
| `racket/` | 前端（语言层） | 自然语言 → DSL → 形式验证 → IR |
| `cpp26/` | 后端（性能层） | IR → 零开销 C++26 代码生成 + 编译期验证 |
| `SERIALIZATION.md` | 通信层 | ABF v2 零拷贝二进制协议 |
| `AURAQUERY.md` | AI 交互层 | 原生 eDSL 查询与变换 |

## 学习路径

1. 先读 `philosophy/DESIGN_PHILOSOPHY.md` 理解窄门哲学
2. 再读 `ARCHITECTURE.md` 理解三层架构
3. 按番号顺序读 `racket/day-01.md` 到 `racket/day-14.md`
4. 并行参考 `cpp26/` 跟踪后端标准演进
5. 理解序列化和查询：`SERIALIZATION.md` + `AURAQUERY.md`
