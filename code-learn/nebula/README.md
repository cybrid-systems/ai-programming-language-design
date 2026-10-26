# NebulaGraph 源码分析

> 对照仓库：<https://github.com/vesoft-inc/nebula>
> master `426266b5c3df856d27f747b55b916dec542b7b59`（2026-09-08）
> tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`（2024-05-17）
> 分支 `release-3.8` `15fc0b7a12ba69b3977c6f4a9d70d15ec7f98742`（2025-03-19）
> `v3.6.0` 只用于核对「3.8 才出现」的说法。

两条线：01–05 是算子下推，06–09 是数据格式。下推系列里 `v3.8.0` 与 `release-3.8` 在 `src/graph/optimizer`、`src/graph/planner`、`src/graph/executor`、`src/storage/query` 上没有差异。编码系列以 master 与 `v3.8.0` 的 diff 为准：key 与标量索引编码相同，LIST / SET 行格式只在 master。

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
| 06 | [存储 key](06-key-encoding.md) | `NebulaKeyUtils` 的点、边、系统键、VID 定长与小端头对前缀扫描的影响 |
| 07 | [行 value](07-row-encoding.md) | `RowWriterV2` / `RowReaderV2`、null bitmap、schema 版本、默认值、TTL、LIST/SET |
| 08 | [索引 key](08-index-key-encoding.md) | 整数、浮点、字符串、null、地理如何编成有序字节 |
| 09 | [写入读出与建模](09-write-read-chain.md) | INSERT / FETCH / GO / LOOKUP / ALTER 各用哪套编码，以及 VID、热点、大属性 |

下推阅读顺序是 01 → 02 → 03 → 04 → 05。05 的更正表是对早期笔记的集中修订，结论都以前面几篇的源码锚点为准。

编码阅读顺序是 06 → 07 → 08 → 09。09 把前三篇接到一条写入读出链上。04 只讲 filter / limit 怎么进 storaged，不讲 key 和行格式。

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
