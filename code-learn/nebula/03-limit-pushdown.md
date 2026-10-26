# 03-limit-pushdown — Limit 下推、全表扫描与 SHORTEST PATH

> 源码基线与 [01-optimizer-framework](01-optimizer-framework.md) 相同。
> `PushLimit*` 规则在 `v3.8.0` 与 master 的 `src/graph/optimizer/rule/` 中一致。
> SHORTEST PATH 的 `| LIMIT` 折叠在 `v3.6.0` 的 `parser.yy` 里不存在，在 `v3.8.0` 的 `src/parser/parser.yy:2966` 已经存在。
> 分析日期：2026-10-26

---

## 0. 概述

Limit 下推比 Filter 机械：规则把上层 `Limit` 的 `offset + count` 写到下面算子的 `limit` 字段，多数情况下 **graphd 的 Limit 还留着**。存储层少读，graphd 再用 offset 丢掉前面的行。

两件容易和笔记混在一起的事：

1. `FIND SHORTEST PATH ... | LIMIT n`（offset 为 0）不是优化器规则，而是解析器把管道折进 `FindPathSentence`，规划器 `setLimit` 到最短路算子。
2. 无 LIMIT 的全表 `ScanVertices` / `ScanEdges` 在这份源码里 **不会** 报笔记里的 `-1005: scan vertices or edges need to specify a limit number`。`-1005` 是通用的 `E_EXECUTION_ERROR`。graphd 侧的默认 limit 是 **-1**（`ScanVertices::make` / `ScanEdges::make`，`src/graph/planner/plan/Query.h:822/887`），storage 收到负数才转成 `int64` 最大值（`ScanVertexProcessor.cpp:32`）。

---

## 1. 规则与模式

这些规则都在 `QueryRules` 里。多条规则的 `transform` 会检查 `limit->countExpr()` 能否 `isEvaluableExpr`（能在优化期算出整数），算不出就 `noTransform()`；但这**不是所有规则的共同条件**——15 条 limit/step/topN 规则里只有 8 条带这个检查，其余直接用 `limit->count(qctx)`。若算子上已经有更小的 limit，也不再改。

写入的行数一律是 `offset + count`，不是 `count`。存储并不知道 offset，多读的前缀由上面的 `Limit` 丢掉。

| 规则 | 模式 | 嵌入之后 Limit 算子还在吗 |
|------|------|---------------------------|
| `PushLimitDownProjectRule` | `Limit -> Project` | 在。Limit 被挪到 Project 下面，好让后面的规则看见它 |
| `PushLimitDownScanEdgesRule` | `Limit -> ScanEdges` | 在。`ScanEdges::setLimit(offset+count)` |
| `PushLimitDownScanEdgesAppendVerticesRule` | `Limit -> AppendVertices -> Project -> ScanEdges` | 在。多一层 `Project`。要求 AppendVertices 上没有过滤 |
| `PushLimitDownScanAppendVerticesRule` | `Limit -> AppendVertices -> ScanVertices/IndexScan` | 在。`vFilter` 非空则失败。`filter` 取自 `AppendVertices::filter()`：为空可以通过；非空时要求扫描节点**不是** `ScanVertices`（扫描节点是 `ScanVertices` 就失败）。索引扫描只放行 `tag._tag IS NOT EMPTY` 这一种 `filter`。src 必须是 vid 列 |
| `PushLimitDownGetNeighborsRule` | `Limit -> GetNeighbors` | 在 |
| `PushLimitDownGetVerticesRule` | `Limit -> GetVertices` | 在 |
| `PushLimitDownGetEdgesRule` | `Limit -> GetEdges` | 在 |
| `PushLimitDownIndexScanRule` | `Limit ->` 七种 IndexScan | 在。kind 包括 `kIndexScan`、`kTagIndexFullScan`、`kTagIndexRangeScan`、`kTagIndexPrefixScan`、`kEdgeIndexFullScan`、`kEdgeIndexRangeScan`、`kEdgeIndexPrefixScan` |
| `PushTopNDownIndexScanRule` | `TopN -> Project -> IndexScan` | TopN 还在，索引扫描带 limit |
| `PushLimitDownFulltextIndexScanRule` / `Rule2` | Limit 与全文索引的两种形状 | 在，或与 `MergeLimitAndFulltextIndexScanRule` 合在一起处理 offset |
| `PushLimitDownExpandAllRule` | `Limit -> ExpandAll` | 在。`match` 要求 `minSteps == maxSteps` |
| `PushStepLimitDownGetNeighborsRule` | `Limit -> GetNeighbors` | 把**外层 LIMIT 的 count 表达式**克隆到 GetNeighbors（`limit->countExpr()->clone()`）；GetNeighbors 原有的 step limit 只当「更小则不改」的比较守卫 |
| `PushStepSampleDownGetNeighborsRule` | `Sample -> GetNeighbors` | sample 的 count 写成 GetNeighbors 的 limit |
| `PushLimitDownAllPathsRule` | `Limit -> AllPaths` | **不在**。`eraseAll`，`AllPaths` 自己记下 `offset` 和 `limit` |

`PushLimitDownScanEdgesRule::transform` 是这组规则的典型写法（`src/graph/optimizer/rule/PushLimitDownScanEdgesRule.cpp`）：

```cpp
if (!graph::ExpressionUtils::isEvaluableExpr(limit->countExpr())) {
  return TransformResult::noTransform();
}
int64_t limitRows = limit->offset() + limit->count(qctx);
if (se->limit(qctx) >= 0 && limitRows >= se->limit(qctx)) {
  return TransformResult::noTransform();
}
auto newLimit = static_cast<Limit *>(limit->clone());
auto newSe = static_cast<ScanEdges *>(se->clone());
newSe->setLimit(limitRows);
```

`PushLimitDownExpandAllRule` 和 Filter 那条一样，变步 `GO m TO n` 不匹配。一步 `GO ... | LIMIT n` 在优化器打开时可以把 limit 写进 `ExpandAll`，执行器取 `min(stepLimit, expand_->limit())` 传给 `getNeighbors`（`ExpandAllExecutor::getNeighbors`）。

---

## 2. MATCH 边扫描：先有 Limit，才改写成 ScanEdges

`GetEdgesTransformRule` 的模式是：

```
Project -> Limit -> Traverse -> ScanVertices
```

`match` 同时要求（`src/graph/optimizer/rule/GetEdgesTransformRule.cpp`）：

- `Traverse` 的步长是 1 到 1。
- `vFilter == nullptr`。点过滤还在就不能改扫描。
- `eFilter == nullptr`。注释写明：边过滤非空表示它还不能下到 storage，规则放弃。
- Project 的 yield 不是 `PathBuild`。`RETURN p` 这种整条路径不改写。
- 倒数第二列名以 `_` 开头（规划器给 src 列的内部命名）。

通过后 `GetEdgesTransformUtils::traverseToScanEdges` 生成 `ScanEdges`，limit 参数是 `limit->offset() + limit->count()`，并把 `Traverse::filter()` 克隆到扫描上。正反边类型同时出现时返回 nullptr（「Don't support to retrieve edges of the inbound/outbound together」）。

所以 `MATCH ()-[e:follow]->() RETURN e LIMIT 10` 能变成带 limit 的 `ScanEdges`，依赖的是这条改写，而不只是 `PushLimitDownScanEdgesRule`。没有 Limit 时模式对不上，`Traverse -> ScanVertices` 会留着。带复杂边过滤且 `eFilter` 还没被 `PushEFilterDownRule` 清掉时，改写也不会发生。笔记里「带复杂条件的扫描受限」指的就是这些 match 失败分支。

`GetEdgesTransformAppendVerticesLimitRule` 是同一思路的另一种树形（中间还有 AppendVertices）。

索引扫描的 Limit 不经过这条改写。`IndexScanRule`、`TagIndexFullScanRule`、`EdgeIndexFullScanRule` 在 `DefaultRules` 里，**不依赖** `--enable_optimizer`。但把 Limit 嵌进索引扫描的 `PushLimitDownIndexScanRule` 在 `QueryRules` 里，依赖优化器开关。只开默认规则集时，索引可以选择，Limit 不会嵌进 IndexScan。

---

## 3. 全表扫描与 -1005

`ScanVertices` / `ScanEdges` 的构造默认值是 **-1**（`src/graph/planner/plan/Query.h:822/887`）。`src/graph/planner/plan/Scan.h` 里只有 IndexScan 子类，它们的默认才是 `int64` 最大值。执行器注释写了 "must have limit parameter"（`ScanVerticesExecutor.h`、`ScanEdgesExecutor.h`），但函数体只是把 `sv->limit()` / `se->filter()` 传给 `StorageClient::scanVertex` / `scanEdge`，没有本地报错。

storage 侧（`ScanVertexProcessor::doProcess`、`ScanEdgeProcessor::doProcess`）：

```cpp
// negative limit number means no limit
limit_ = req.get_limit() < 0 ? std::numeric_limits<int64_t>::max() : req.get_limit();
```

负数才是「不限制」。graphd 侧默认就是 -1，由 storage 转成 `int64` 最大值后带上；请求不会被拒。

`src/common/graph/Response.h` 里：

```
X(E_EXECUTION_ERROR, -1005)
X(E_SYNTAX_ERROR, -1004)
X(E_INVALID_PARM, -2009)
```

`-1005` 是 graphd 的通用执行错误，不是扫描专用码。在 master、`v3.8.0`、`release-3.8`、`v3.6.0` 里搜索 `scan vertices or edges need to specify a limit` 和 `limit number can not push down`，都没有这句字符串。

原笔记把这条错误写成 3.8 的行为，**这份社区源码对不上**。可能来自别的版本、企业版或更早的文档。在当前树上，无 LIMIT 的 `MATCH (v) RETURN v` 会规划成默认 limit 为最大值的扫描，而不是稳定地返回这句 `-1005`。

---

## 4. SHORTEST PATH 的 LIMIT 是解析器折叠

`FIND SHORTEST PATH` 的语法本身没有 LIMIT 子句。`find_path_sentence` 只有 FROM / TO / OVER / WHERE / UPTO / YIELD（`src/parser/parser.yy`）。管道上的 LIMIT 在 `piped_sentence` 里被特殊处理：

```cpp
// src/parser/parser.yy  v3.8.0:2966 与 master 相同
if (kind == Sentence::Kind::kFindPath) {
  auto path = static_cast<FindPathSentence*>($1);
  auto limit = static_cast<LimitSentence *>($3);
  if (path->isShortest() && limit->offset() == 0) {
    path->setLimit(limit->count());
    $$ = path;                 // 不再生成独立的 Limit 句子
  } else {
    $$ = new PipedSentence($1, $3);
  }
}
```

随后 `FindPathValidator` 把 `fpSentence->limit()` 放进 `PathContext`。`PathPlanner::singlePairPlan` / `multiPairPlan` 调用 `path->setLimit(pathCtx_->limit)`，目标是 `BFSShortestPath` 或 `MultiShortestPath`（`src/graph/planner/plan/Algo.h`）。单对端点走 BFS，多对端点走 Multi。

对照 `v3.6.0`：

- `parser.yy` 没有 `shortest && offset == 0` 这段折叠。
- `PathPlanner.cpp` 没有 `setLimit`。
- `Algo.h` 里当时已有 `AllPaths::limit_`（给 `PushLimitDownAllPathsRule` 用），最短路算子还不会从语句接收 limit。

所以笔记说「3.8 的 SHORTEST PATH Limit 是增强」方向是对的，但机制要改写成：

- 它是 **解析期折叠 + 规划期 setLimit**，不是 `PushLimitDown*Rule`。
- 只覆盖 `FIND SHORTEST PATH` / `FIND SINGLE SHORTEST PATH`，并且 **offset 必须是 0**。`| LIMIT 10, 5` 或 `| OFFSET 1 LIMIT 10` 仍是普通管道，不会写进最短路算子。
- `FIND ALL PATH ... | LIMIT n` 不走这段折叠。它仍是 `Limit` 算子，能否嵌进 `AllPaths` 取决于中间还有没有 `Project` / `Filter` 挡住 `PushLimitDownAllPathsRule` 的模式。`allPathPlan` 在有 WHERE 时会先放 `Filter`，再放 `Project`。`PushLimitDownProjectRule` 能把 Limit 挪过 Project；Filter 还在中间时，模式 `Limit -> AllPaths` 对不上。

`v3.6.0` 已经有 `PushLimitDownAllPathsRule` 和 `PushLimitDownExpandAllRule`。不能把「3.8 才有 Limit 下推」理解成这两组规则是 3.8 新写的。浅克隆看不到 3.6 和 3.8 之间的每个提交，只能确定 3.6.0 没有管道折叠、3.8.0 有。

最短路算子上的 `limit_` 如何在 BFS 循环里截断，要看 `SingleShortestPath` / `BatchShortestPath` 的执行器。本文确认的是它 **被写上了**；它不是 storage `TraverseSpec.limit` 那条路径。GetNeighbors 子节点上的 limit 仍由 `PushLimitDownGetNeighborsRule` 决定，而 `PathPlanner::getNeighbors` 生成的是 `GetNeighbors` 上面可选的 `Filter`，没有现成的 `Limit -> GetNeighbors`，除非别处再产生 Limit。

---

## 5. 对原笔记的更正

| 原笔记 | 源码 |
|--------|------|
| Limit 下推较好，规则是 `PushLimitDownScanEdgesRule`、`PushLimitDownProjectRule` | 这两条都在，而且还有 GetNeighbors、GetVertices、GetEdges、IndexScan、全文索引、ExpandAll、AllPaths、TopN、step limit、sample。Project 那条只是把 Limit 搬到 Project 下面。 |
| 无索引的 `MATCH (v) RETURN v LIMIT n`、`MATCH ()-[e:type]->() RETURN e LIMIT n` 可下推 | 边扫描依赖 `GetEdgesTransformRule` 的一整串 match（一步、无 vFilter、无残留 eFilter、不是路径 yield、没有双向边类型）。点扫描依赖 `PushLimitDownScanAppendVerticesRule` 或 Limit 直接压在 `ScanVertices` 上。只写「可下推」会漏掉这些前提。 |
| 带复杂条件或带索引的 MATCH Limit 不完整 | 索引种类本身在 `PushLimitDownIndexScanRule::kIndexScanKinds` 里是覆盖的，但规则属于 `QueryRules`。`eFilter` 还在时边扫描改写失败。这是「不完整」的具体原因。 |
| 无 LIMIT 的全量扫描报 `-1005: scan vertices or edges need to specify a limit number...` | 这句不在 3.6.0 / 3.8.0 / release-3.8 / master 中。`-1005` 是 `E_EXECUTION_ERROR`。graphd 侧扫描默认 limit 是 -1，storage 收到负数才转成 `int64` 最大值。 |
| `SHORTEST PATH + LIMIT` 是 3.8 优化器下推 | 3.8 起，`\| LIMIT n` 且 offset 为 0 时被解析器折进最短路语句，规划器写到 `BFSShortestPath` / `MultiShortestPath`。不是 PushLimit 规则。带 offset 的管道不会折。`FIND ALL PATH` 的 Limit 规则在 3.6.0 就已经存在。 |
