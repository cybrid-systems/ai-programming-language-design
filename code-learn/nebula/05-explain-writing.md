# 05-explain-writing — EXPLAIN 字段、写法与笔记更正

> 源码基线与 [01-optimizer-framework](01-optimizer-framework.md) 相同。
> EXPLAIN 文本来自 `PlanNode::explain` / `addDescription`，不是单独的一套优化器。
> 分析日期：2026-10-26

---

## 0. 概述

前面四篇把规则和 RPC 拆开了。这篇回答两件使用时会碰到的事：EXPLAIN / PROFILE 上哪个字段才表示「已经交给 storage」，以及原笔记里哪些句子可以保留、哪些要改。

社区版源码（master 与 `release-3.8`）里没有子查询计划整体下推的实现，也没有名为 NDP 的模块。企业版 5.x 是否更完整，这份树回答不了，只能确认开源树没有这条路径。

---

## 1. 计划节点上的字段名

`addDescription` 把键值对放进 `PlanNodeDescription`。不同算子的键不是同一个词。

| 算子 | 键 | 源码 | 含义 |
|------|----|------|------|
| `Filter` | `condition` | `Filter::explain` | 仍在 graphd 执行的谓词 |
| `Limit` | `offset`、`count` | `Limit::explain` | graphd 再截一次。存储拿到的通常是两者之和 |
| `GetNeighbors` / `Expand` / `Scan*`（`Explore` 子类） | `filter`、`limit` | `Explore::explain` | 执行器会传给 `StorageClient` 的那两个字段 |
| `Traverse` | 上面的 `filter`、`limit`，再加上 `vertex filter`、`edge filter`、`first step filter`、`tag filter` | `Traverse::explain` 调用 `GetNeighbors::explain` 后再追加 | `filter` 进 RPC；`edge filter` / `vertex filter` 在 `TraverseExecutor::expand` 里算 |
| `AppendVertices` | `vertex_filter` | `AppendVertices::explain` | 点过滤还在 graphd 取点算子上 |
| `AllPaths` / `BFSShortest` / `MultiShortestPath` | `limit` | `Algo.cpp` 的 `explain` | 最短路是规划器 `setLimit` 写上的；AllPaths 还可能来自 `PushLimitDownAllPathsRule` |

因此笔记里「算子上出现 `filter:` 或 `limit:` 就表示已下推」需要收窄：

- `GetNeighbors`、`Expand`、`ExpandAll`、`ScanVertices`、`ScanEdges`、`IndexScan` 上的 `filter` / `limit` 会进入 RPC。
- 同名键出现在 `Traverse` 的 `filter` 上，也会进入 `selectFilter()`；旁边的 `edge filter` 表示还没推完。
- graphd `Filter` 的键是 `condition`，不是 `filter`。只看到 `condition`，谓词仍在 graphd。
- graphd `Limit` 的键是 `offset` 和 `count`。它几乎总会留下，因为存储 limit 含 offset。看到它不代表下推失败；要同时看下面扫描或 Expand 的 `limit` 是否变成了 `offset+count`。

PROFILE 在执行器里追加状态，不改变这套键。`GetNeighborsExecutor` 记 `total_rpc_time` 和每个 host 的 `resp[i]`。`TraverseExecutor` 记 `step[i]`。`ExpandAllExecutor` 记 `graphExpandAllTime+步号`。这些是耗时，不是谓词文本。

---

## 2. 用 EXPLAIN 核对时看哪一层

一步 GO，谓词只有边属性，优化器打开：

```
Project
  ExpandAll          filter: follow.degree > 1     limit: ...
    Expand
```

上面不应再有带这条谓词的 `Filter`。若 `GO 1 TO 3 STEPS`，`PushFilterDownExpandAllRule` 不匹配，`Filter.condition` 还在，`ExpandAll.filter` 为空。

一步 MATCH，边谓词已经走完 `PushEFilterDownRule`：

```
Traverse
  filter: <改写后的边谓词>
  edge filter:            （空）
  vertex filter:          （空，或者只剩 $$ 相关）
```

若 `edge filter` 仍有内容，`PushEFilterDownRule` 没把它吃掉：常见原因是 `zeroStep()` 为真，或剩余子式含 `DestProperty` / label / `Vertex`。`vFilter` 非空时 `GetEdgesTransformRule` 也不会把 `Traverse` 改成 `ScanEdges`。

`MATCH ()-[e:follow]->() RETURN e LIMIT 10` 改写成功时，`Traverse -> ScanVertices` 会变成带 `limit` 的 `ScanEdges`，上面还留着 `Limit`（`offset` + `count`）。没改写时仍能看到 `ScanVertices` 或 `Traverse`，limit 只出现在 graphd `Limit` 上。

`FIND SHORTEST PATH ... | LIMIT 10` 且没有 OFFSET：计划里 **没有** 独立 `Limit` 算子，`BFSShortest` 或 `MultiShortestPath` 的 `limit` 为 10。带 OFFSET 时折叠不发生，`Limit` 算子还在，最短路算子的 `limit` 保持默认 `-1`。

---

## 3. 写法对应到哪条规则

下面每条都假设发行配置里的 `--enable_optimizer=true`。flag 默认值是 false，关掉之后 `QueryRules` 里的 Push 规则全部不跑，只剩索引类 `DefaultRules` 和属性裁剪。

```ngql
GO FROM "vid" OVER follow
WHERE follow.degree > 1
YIELD follow._src AS src, follow._dst AS dst, follow.degree AS degree;
```

一步、单一边类型、谓词是边属性。`GoValidator` 把 `follow.degree` 收成边属性列，`PushFilterDownExpandAllRule` 有机会写进 `ExpandAll.filter`。`follow._src` / `follow._dst` 是 `EdgeSrcIdExpression` / `EdgeDstIdExpression`，访问器允许。这是笔记里最稳的一种写法，但计划节点是 `ExpandAll`，不是 `GetNeighbors`。

```ngql
GO FROM "vid" OVER follow
WHERE follow.degree > 1
YIELD follow._dst AS vid
| FETCH PROP ON player $-.vid
YIELD vertex AS v;
```

WHERE 仍按上面的路径处理。`FETCH` 是管道后的另一条语句，不会把终点过滤塞回 GO。这比在 GO 的 WHERE 里写 `$$.player.age` 更符合 `joinDst` 的实现：终点属性本来就要再取一次。

```ngql
GO FROM "vid" OVER follow
WHERE $$.player.age > 30
YIELD follow._dst AS dst;
```

`checkDstPropOrVertexExist` 置 `joinDst`。`kGetNeighbors` 拒绝 `DestProperty`。过滤留在 join 之后。

```ngql
MATCH ()-[e:follow]->()
RETURN e
LIMIT 10;
```

需要 `GetEdgesTransformRule` 匹配成功：一步、没有残留 `eFilter` / `vFilter`、yield 不是路径、边类型不成对正反。成功后 `ScanEdges.limit = 10`（offset 为 0），graphd `Limit` 仍在。

```ngql
MATCH (v)
RETURN v
LIMIT 10;
```

`ScanSeek` 生成 `ScanVertices`。Limit 要靠 `PushLimitDownScanAppendVerticesRule` 穿过 `AppendVertices`：src 是 vid 列，`vFilter` 为空，并且 `ScanVertices` 上不能再挂 filter。没有 LIMIT 时扫描仍会生成，默认 limit 是 `int64` 最大值，**不会**稳定地报笔记中的那句 `-1005`。见 [03](03-limit-pushdown.md)。

```ngql
FIND SHORTEST PATH FROM "src" TO "dst" OVER follow
YIELD path AS p
| LIMIT 10;
```

`v3.8.0` 起，offset 为 0 的管道 LIMIT 在解析器折进 `FindPathSentence`，`PathPlanner` 写到最短路算子。这不是 `PushLimitDownGetNeighborsRule`。`| LIMIT 10 OFFSET 1` 不会折。`v3.6.0` 没有这段折叠。

```ngql
GO FROM "vid" OVER follow
WHERE src(edge) == "vid"
YIELD src(edge) AS s;
```

`src(edge)` 是函数，参数是 label。`ExtractFilterExprVisitor` 对 `Label` 返回不可下推。同样的条件下面写成 `follow._src` 才是 `EdgeSrcIdExpression`。函数包住 **已经是边属性** 的表达式（例如对 `follow.degree` 做算术）不会被这条规则拒绝；storage `checkExp` 允许 `kFunctionCall`。

```ngql
MATCH (v)-[e:follow*1..3]->(t)
WHERE all(x IN e WHERE x.degree > 1)
RETURN t;
```

`EmbedEdgeAllPredIntoTraverseRule` 只在 `all`、边别名、inner var、常量属性名都满足时把谓词改写成 `eFilter`，再由 `PushEFilterDownRule` 尝试送进 `Traverse.filter`。`*1..3` 不是 `isOneStep()`，`PushFilterDownTraverseRule` 不跑；`all()` 那条规则的模式只要求 `Filter -> Traverse`，不要求一步。`zeroStep()` 为真时 `PushEFilterDownRule` 放弃。`NOT all(...)` 不会嵌入。

---

## 4. 原笔记对照

保留的判断：

- 3.8 社区版是规则下推，不是把任意谓词都送到存储。覆盖面取决于算子种类和表达式种类，写法变了计划就变。
- 简单边谓词、显式边类型，比终点属性、`src()` / `properties()` 这种包住 label 或 `$$` 的函数更容易进 storage。
- 变步、多跳终点属性，数据仍会回到 graphd。
- 属性裁剪不彻底。
- 企业版若把子查询计划整段下推，那是社区树里没有的能力。master 与 `release-3.8` 都没有 NDP 或等价实现。具体边界以企业版自己的文档为准，这里不补版本号或数字。

需要改的判断：

| 原句 | 更正 |
|------|------|
| 主要规则是 `PushFilterDownGetNbrsRule`，GO 的边过滤下推到 GetNeighbors | 普通 GO 的计划是 `Filter -> ExpandAll -> Expand`。一步且 `minSteps == maxSteps` 时走 `PushFilterDownExpandAllRule`。`PushFilterDownGetNbrsRule` 只匹配真正的 `GetNeighbors`。 |
| `PushLimitDownProjectRule` 是 Limit 下推的代表 | 它只把 Limit 从 Project 上面搬到下面。嵌进扫描的是 `PushLimitDownScanEdgesRule`、`PushLimitDownIndexScanRule`、`GetEdgesTransformRule` 等。 |
| SHORTEST PATH 的 Limit 下推是 3.8 优化器增强 | 3.6.0 已有 `PushLimitDownAllPathsRule`。3.8 新增的是解析器对 `FIND SHORTEST PATH \| LIMIT n`（offset 为 0）的折叠，以及 `PathPlanner::setLimit`。带 offset 不折叠。 |
| 无 LIMIT 全表扫描报 `-1005: scan vertices or edges need to specify a limit number, or limit number can not push down` | 这句话不在 3.6.0、3.8.0、`release-3.8`、master 中。`-1005` 是 `E_EXECUTION_ERROR`。`Scan*` 默认 limit 为 `int64` 最大值；storage 把负数当作不限制。 |
| 函数包裹通常阻碍下推 | 阻碍的是不可下推的参数种类（label、`$$`、`Vertex`、`Edge`）。`abs(follow.degree)` 这类不会被访问器拒绝。 |
| `all()` 等部分谓词可嵌入 | 只有边上的 `all()`，且不能被 `NOT` 包住。`any()` 不走 `EmbedEdgeAllPredIntoTraverseRule`。 |
| 属性裁剪来自 Project 规则 | 来自探索之后的 `PrunePropertiesVisitor`。它不访问 `ExpandAll` / `GetNeighbors`。 |
| 优化器会做代价选择 | `PlanNode::cost_` 恒为 0，组内选链表第一个节点。下推是否生效取决于规则有没有 `eraseCurr` / `eraseAll`。 |
| master 与 3.8 的下推可以当成同一套 | 规则代码除地理索引选择外一致。GetNeighbors 的 limit 与 `FLAGS_max_edge_returned_per_vertex` 的关系不同：3.8 取二者较小值，master 在请求 limit 非负时直接采用。默认旗标是 `INT_MAX`。见 [04](04-storage-execution.md)。 |

---

## 5. 建议的核对顺序

1. 确认 graphd 实际带了 `--enable_optimizer=true`。只看源码默认值会以为规则没编译进去。
2. `EXPLAIN` 而不是只看语句文本。记录算子名，以及 `filter` / `edge filter` / `condition` / `limit` / `offset`+`count` 分别在哪。
3. 一步、单一 `OVER edge`、谓词只用 `edge.prop` 或 `edge._src`，作为「应该能下推」的对照。
4. 把谓词改成 `$$.tag.prop` 或 `src(e)`，对照同一位置的字段是否从 `filter` 退回 `condition` 或 `edge filter`。
5. 变步 `GO m TO n` 和 `[*m..n]` 不要期望和一步共用同一条规则。
6. 最短路用 `| LIMIT n` 时看最短路算子自己的 `limit`，不要去 `GetNeighbors` 上找一条不存在的 PushLimit 规则。
