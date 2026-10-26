# 10 — 下推能力总表

> 源码基线与 [01](01-optimizer-framework.md) 相同：master `426266b5`，对照 `v3.8.0` `fa928930`。
> 本文不重复 02–05 的规则正文，只回答「这种算子、这种语句，停在 graphd 还是 storaged」。
> 场景二的计划形状和补丁在 [11](11-scenario2-beauty-buyers.md)。
> 分析日期：2026-10-26。

`v3.8.0` 与 master 在 Filter / Limit / TopN / Aggregate 这些规则上，除了地理索引选择（`GeoPredicateIndexScanBaseRule`）和 `GetNeighborsProcessor` 对 `FLAGS_max_edge_returned_per_vertex` 的上限，计划形状相同。下面的表对这两份树都成立。发行 conf 打开 `--enable_optimizer=true`；`GraphFlags.cpp` 里该 flag 的默认值是 false。关着时 `QueryRules` 不跑，下表里标「规则」的项全部留在 graphd。属性裁剪是后处理，不看这个 flag，见 [01](01-optimizer-framework.md)。

---

## 1. 总表

「能下推」指谓词或限额写进了发往 storaged 的 RPC（`GetNeighbors` / `getDstBySrc` / `Traverse` 的 filter，或 IndexScan 的前缀）。graphd 里把 Filter 挪到另一个算子下面，但 RPC 没带 filter，记为「只在 graphd 重排」。

| 能力 | GO | MATCH | LOOKUP（非全文） | FETCH | 最短路 |
|------|----|-------|------------------|-------|--------|
| 边属性 Filter | 一步：`PushFilterDownExpandAllRule` → `ExpandAll.filter` → `getNeighbors`。变步不下推。`YIELD DISTINCT 边._dst` 且只有边谓词时，补丁路径见 [11](11-scenario2-beauty-buyers.md) | `eFilter` 由 `PushEFilterDownRule` 并入 `Traverse.filter`，多跳每跳都带（0 步除外） | 索引列进 IndexScan 的前缀/范围；非索引列留在扫描后的 `Filter` | 语句没有 WHERE。后面的 `\| WHERE` 没有 `PushFilter*` 规则匹配 `GetVertices` / `GetEdges`，留在 graphd | 路径算子自己的过滤，不是这套 `PushFilter*` |
| `$^` 起点属性 | 可进 `GetNeighbors`（`ExtractFilterExprVisitor` 的 `kGetNeighbors` 允许 `SourceProperty`） | 多跳的 `vFilter` 留在 graphd；`PushFilterDownNodeRule` 只能把一部分放进 first-step | 不适用 | 不进 storage | 不适用 |
| `$$` 终点属性 | 不可进 `GetNeighbors`。`GoValidator::checkDstPropOrVertexExist` 置 `joinDst`，终点用 `GetVertices` + `HashLeftJoin`，谓词在 join 之上 | 终点 `AppendVertices` 上的过滤留在 graphd | 不适用 | FETCH 本身就是取点 | 不适用 |
| 投影 / 属性裁剪 | YIELD 和 WHERE 用到的边、点属性由 validator 收进 `edgeProps` / `vertexProps`，RPC 只列这些列。`PrunePropertiesVisitor` 不访问 `Expand` / `ExpandAll` / `GetNeighbors` | 访问 `Traverse`、`AppendVertices` | IndexScan 的 `idxReturnCols` / yield 列 | `FetchVerticesPlanner` / `FetchEdgesPlanner` 按 YIELD 列填 props | 返回路径，不按属性裁成标量列 |
| 任意表达式投影 | graphd `Project`。storage 的 `buildYields` 写着 `todo(doodle): support expression yields later`，直接返回成功，不算表达式 | 同左 | 同左 | 同左 | 同左 |
| 索引选择 | 不从 GO 起扫 | `PropIndexSeek` / `LabelIndexSeek` 能把起点收成 `IndexScan` 时才走索引 | `LookupPlanner` 直接 `TagIndexFullScan` / `EdgeIndexFullScan`。`IndexScanRule`、`Optimize*IndexScanByFilter` 把等值和前缀收成范围。全文才是 IndexScan 再 `GetVertices` / `GetEdges` | 不走索引 | 不走索引 |
| Limit | `PushLimitDownExpandAllRule` 要求 `minSteps == maxSteps`。一步 GO 可以带进 RPC 的 per-vertex limit | `TraverseExecutor` 只在最后一跳把 `limit` 发给 storage | 有 `PushLimitDownScan*`。全表扫描的限额行为见 [03](03-limit-pushdown.md) | `PushLimitDownGetVerticesRule` 存在，限的是点属性 RPC，不是邻居 | `FIND SHORTEST PATH \| LIMIT` 在 offset 0 时由解析器折进语句，`PathPlanner::setLimit`。不是 `PushLimit` 规则。见 [03](03-limit-pushdown.md)、[05](05-explain-writing.md) |
| TopN | `TopNRule`：`Limit(offset==0)` 盖在 `Sort` 上变成 graphd `TopN`。没有把 TopN 推进 `ExpandAll` | 同左，停在 graphd | `PushTopNDownIndexScanRule` 只匹配 `TopN → Project → IndexScan`，排序列必须是点或边属性，`limit = offset + count` | 无 | 无全局 TopN 下推 |
| Aggregate `count/sum/min/max` | 无 GROUP BY 下推。`stat_props` 是**一个顶点的邻居统计**，`AggregateNode` 头注释写明只用于 GetNeighbors。`TraverseExecutor` 只在最后一跳带 `statProps` | 同左 | 索引扫描不做 sum | 无 | 无 |
| `GROUP BY` 后再 Filter | `PushFilterDownAggregateRule`：过滤条件里不能出现聚合函数，否则不变换。变换是把 Filter 换到 Aggregate 下面，两边都在 graphd | 同左 | 同左 | 同左 | 不适用 |
| 跨分区 DISTINCT / `sum` | 做不完。一个 storaged 只看到自己 part 上的边。host 内去重之后，graphd 还要再并一次 | `YieldClausePlanner` 在 `RETURN DISTINCT` 时加 graphd `Dedup`。`Traverse::setDedup` 只在最后一跳让 storage 按**该顶点的邻居行**去重 | Index seek 路径上 `PropIndexSeek` 会加一次 `Dedup`，去的是索引扫出来的 vid，不是后面的用户 | 无 | 无 |

`PlanNode::cost_` 恒为 0。规则要赢，必须自己 `eraseCurr` / `eraseAll`。没有代价模型在「下推过滤」和「不下推」之间做选择。

---

## 2. 三条语句实际长什么样

下面三行是场景二会写出来的句子。算子链在 [11](11-scenario2-beauty-buyers.md) 展开，这里只标已经下推的那一段。

| 写法 | 规划器 | 边时间条件 | 用户 VID 去重 |
|------|--------|------------|----------------|
| `LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id \| GO FROM $-.id OVER buy REVERSELY WHERE buy.ts > t YIELD buy._dst AS user, buy.amount AS amt` | `TagIndexFullScan`，再 `HashInnerJoin` + `ExpandAll` | 一步且优化器开：`PushFilterDownHashInnerJoinRule` 把列名对得上的谓词压到 `ExpandAll` 一侧，下一轮 `PushFilterDownExpandAllRule` 写入 `ExpandAll.filter` | graphd `Dedup` 只有 YIELD 写了 DISTINCT 才有。storage 不去重用户 |
| 同上，但 `YIELD DISTINCT buy._dst` | 见 [11](11-scenario2-beauty-buyers.md)。flag 关时与上一行同一类 `GetNeighbors`；flag 开且谓词只有边时走 `getDstBySrc` | flag 开：`GetDstBySrcRequest.filter`。flag 关：仍是 `GetNeighbors` 的 filter | flag 开：每个 host 的 `GetDstBySrcProcessor::onProcessFinished` 去重，graphd `Dedup` 再并 host |
| `MATCH (i:item)<-[e:buy]-(u) WHERE i.type == "beauty" AND e.ts > t RETURN DISTINCT id(u)` | 起点能被 `PropIndexSeek::matchNode` 认成索引时是 `IndexScan`，然后 `Traverse` | `PushEFilterDownRule` 把 `e.ts > t` 放进 `Traverse.filter`。方向来自模式：从商品指向用户必须写成 `<-[e:buy]-`，否则扫的是出边 | `RETURN DISTINCT` → `YieldClausePlanner` 的 graphd `Dedup`。`traverse->setDedup()` 只对单个顶点的邻居行 |

`GO ... REVERSELY` 不是单独的 GetInEdges RPC。`GoPlanner::buildEdgeTypes` 把边类型取负，`ExpandAllExecutor::getNeighbors` 仍然传 `EdgeDirection::OUT_EDGE`。反向键写在商品这个顶点所在的 part 上（插入时 src/dst 对调、type 取负）。见 [09](09-write-read-chain.md)。

---

## 3. 下不下去的原因

1. **变步 GO。** `GO M TO N` 的 `ExpandAll` 每一跳都 yield。storage 若在中间跳过滤，后面的跳会断。`PushFilterDownExpandAllRule::match` 在 `minSteps != maxSteps` 时返回 false。MATCH 的 `Traverse` 相反：边过滤本来就要剪枝，所以多跳也下推。
2. **跨 part 的分组。** `sum(buy.amount) GROUP BY user` 的同一个用户会出现在多个 storaged 上。单机 part 里做完的 sum 只是部分和。全局 TopN 不能先在每个 host 截断再合并，因为截断前的部分和不是最终和。
3. **`$$` 和 tag 属性。** `kGetNeighbors` 拒绝 `DestProperty`、`TagProperty`、`Vertex`。AND 可以拆，OR 只在「恰好一个不可下推分支本身是 AND」时拆。见 [02](02-filter-pushdown.md)。
4. **0 步 MATCH。** `PushEFilterDownRule` 在 `zeroStep()` 时不把 `eFilter` 放进 `GetNeighbors`，注释写了 0 步和 1 步对过滤的要求冲突。
5. **FETCH 之后的 Filter。** `src/graph/optimizer/rule/PushFilter*` 里没有一条 pattern 是 `GetVertices` 或 `GetEdges`。
6. **storage 表达式列。** `QueryBaseProcessor::buildYields` 未实现。`stat_props` 只能是边属性或 rank 上的 SUM/COUNT/AVG/MIN/MAX，按顶点出一列，不是按 dst 分组。

NULL 的比较在 storage `FilterNode::checkTagAndEdge` 里是：`toBool()` 之后不是 bool 就当 false，边被丢掉。三值逻辑的 AND/OR 在 `LogicalExpression::eval` 里算完，再交给这个判断。下推不会把 NULL 变成 true。
