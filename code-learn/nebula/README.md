# NebulaGraph 算子下推源码分析

> 社区版 graphd 规则优化器如何把 Filter / Limit 写进存储请求，以及 storaged 如何执行。
> 对照仓库：<https://github.com/vesoft-inc/nebula>
> master `426266b5c3df856d27f747b55b916dec542b7b59`（2026-09-08）
> tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`（2024-05-17）
> 分支 `release-3.8` `15fc0b7a12ba69b3977c6f4a9d70d15ec7f98742`（2025-03-19）
> `v3.6.0` 只用于核对「3.8 才出现」的说法。

`v3.8.0` 与 `release-3.8` 在 `src/graph/optimizer`、`src/graph/planner`、`src/graph/executor`、`src/storage/query` 上没有差异。master 的优化器只改了地理索引选择；GetNeighbors 的 limit 裁剪见第 04 篇。

分析日期：2026-10-26。

---

## 系列

| # | 文档 | 回答的问题 |
|---|------|------------|
| 01 | [优化器框架](01-optimizer-framework.md) | `OptRule` / `OptGroup`、三套 RuleSet、`--enable_optimizer`、代价恒为 0、属性裁剪后处理 |
| 02 | [Filter 下推](02-filter-pushdown.md) | `ExtractFilterExprVisitor`、GO 走 `ExpandAll`、MATCH 的 `eFilter` → `filter`、`all()` 与 `$$` |
| 03 | [Limit 下推](03-limit-pushdown.md) | `PushLimit*`、`GetEdgesTransformRule`、全表扫描与 `-1005`、SHORTEST PATH 的解析器折叠 |
| 04 | [存储侧执行](04-storage-execution.md) | `Expression::encode`、`FilterNode`、Scan、3.6/3.8/master 的 limit 旗标 |
| 05 | [EXPLAIN 与写法](05-explain-writing.md) | `filter` 与 `condition` 的区别、写法对照、原笔记更正表 |

阅读顺序是 01 → 02 → 03 → 04 → 05。05 的更正表是对早期笔记的集中修订，结论都以前面几篇的源码锚点为准。

---

## 主线

```
nGQL
  → Parser / Validator
  → Planner（GoPlanner、MatchPathPlanner、PathPlanner、ScanSeek）
  → Optimizer::findBestPlan
        RuleSet 探索（默认 5 轮）
        PrunePropertiesVisitor
  → Executor
        StorageClient::{getNeighbors,scanVertex,scanEdge,getProps}
  → storaged
        QueryBaseProcessor::buildFilter / checkExp
        FilterNode 或 Scan*PropNode
```

发行配置 `conf/nebula-graphd.conf.default` 打开 `--enable_optimizer=true`。`GraphFlags.cpp` 里该 flag 的默认值是 false。Filter / Limit 规则都注册在 `QueryRules`，关开关时不会跑。

---

## 和早期笔记相比，先记住的三件事

1. 普通 `GO ... WHERE` 下推到 `ExpandAll.filter`，不是 `PushFilterDownGetNbrsRule` 所匹配的 `GetNeighbors`。变步不下推。
2. `FIND SHORTEST PATH ... | LIMIT n` 在 offset 为 0 时由解析器折进语句，再由 `PathPlanner::setLimit` 写到最短路算子。这是 3.6.0 没有、3.8.0 已有的行为。它不是一条 `PushLimit` 规则。
3. 笔记中的 `-1005: scan vertices or edges need to specify a limit number...` 不在上述社区源码里。`-1005` 是 `E_EXECUTION_ERROR`。
