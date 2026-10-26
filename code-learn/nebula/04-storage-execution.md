# 04-storage-execution — filter / limit 如何进入 storaged

> 源码基线与 [01-optimizer-framework](01-optimizer-framework.md) 相同。
> graphd 编码在 `src/clients/storage/StorageClient.cpp`，storaged 执行在 `src/storage/query/` 与 `src/storage/exec/`。
> key / 行 / 索引的字节布局在 [06](06-key-encoding.md)–[09](09-write-read-chain.md)，本文不重复。
> `v3.8.0` 与 `release-3.8` 的 `src/storage/query` 无差异。master 相对 3.8 只改了 `GetNeighborsProcessor::doProcess` 里 limit 与 `FLAGS_max_edge_returned_per_vertex` 的关系。
> 分析日期：2026-10-26

---

## 0. 概述

优化器只把表达式指针和整数写在 `PlanNode` 上。真正跨进程的是 graphd 执行器调用 `StorageClient`，把 `Expression::encode()` 的字节和 `limit` 填进 Thrift 请求。storaged 再 `Expression::decode`，挂到存储执行计划的 `FilterNode` 或 `Scan*PropNode` 上，在读出每条边或点时求值。

本文沿三条 RPC：

1. `getNeighbors`：GO 的 `ExpandAll`、MATCH 的 `Traverse`、直接的 `GetNeighbors`。
2. `scanVertex` / `scanEdge`：`ScanVertices` / `ScanEdges`。
3. `getProps`：`GetVertices` / `GetEdges` 上被推下来的 filter 和 limit。

以及 3.6、3.8、master 对 GetNeighbors limit 上限的三次不同写法。

---

## 1. graphd：从算子字段到 RPC

### 1.1 GetNeighbors

`GetNeighborsExecutor::execute`（`src/graph/executor/query/GetNeighborsExecutor.cpp`）把算子原样交出去：

```cpp
storageClient->getNeighbors(param,
                            {nebula::kVid},
                            std::move(vids),
                            gn_->edgeTypes(),
                            gn_->edgeDirection(),
                            gn_->statProps(),
                            gn_->vertexProps(),
                            gn_->edgeProps(),
                            gn_->exprs(),
                            gn_->dedup(),
                            gn_->random(),
                            gn_->orderBy(),
                            gn_->limit(qec),
                            gn_->filter(),
                            nullptr);   // tagFilter 这里是 nullptr
```

`ExpandAllExecutor::getNeighbors` 同样调用 `getNeighbors`，filter 用 `expand_->filter()`，limit 用 `min(stepLimit, expand_->limit())`。边类型列表传的是空，方向写死 `OUT_EDGE`，具体边靠 `edgeProps` 里的 type。

`TraverseExecutor::getNeighbors` 更挑：

```cpp
finalStep ? traverse_->limit(qctx()) : -1,
selectFilter(),
currentStep_ == 1 ? traverse_->tagFilter() : nullptr
```

非最后一步把 limit 设为 **-1**。storage 对 GetNeighbors 的负数含义见下一节，和 Scan 不完全一样。`selectFilter()` 在 `currentStep_ == 1 && range_.min() == 0` 时不用 `Traverse::filter`，避免 0 步结果被边过滤掉。第 1 步还会把 `firstStepFilter` AND 进去。

`StorageClient::getNeighbors`（`src/clients/storage/StorageClient.cpp`）按 vid 把请求分到各个 storaged，填 `cpp2::TraverseSpec`：

```cpp
spec.limit_ref() = limit;
if (filter != nullptr) {
  spec.filter_ref() = filter->encode();
}
if (tagFilter != nullptr) {
  spec.tag_filter_ref() = tagFilter->encode();
}
req.traverse_spec_ref() = std::move(spec);
```

`encode()` 是表达式的二进制序列化，不是把 nGQL 文本发给存储。属性列表 `vertex_props` / `edge_props` 决定存储层读哪些列；filter 引用的列如果不在其中，`QueryBaseProcessor::checkExp` 会按 schema 把缺失属性补进 prop context（`addPropContextIfNotExists`），而不是无声地滤错。

### 1.2 Scan 与 GetProp

`ScanEdgesExecutor` / `ScanVerticesExecutor`：

```cpp
client->scanEdge(param, *se->props(), se->limit(), se->filter());
storageClient->scanVertex(param, *sv->props(), sv->limit(), sv->filter());
```

`StorageClient::scanEdge` / `scanVertex` 把 limit 和 `filter->encode()` 放进 `ScanEdgeRequest` / `ScanVertexRequest` 的 `limit` 与 `filter` 字段。

`StorageClient::getProps` 同样：`req.limit_ref() = limit`，`req.filter_ref() = filter->encode()`。`PushLimitDownGetVerticesRule`、`PushLimitDownGetEdgesRule` 写在算子上的值从这里进 `GetPropProcessor`。`PushVFilterDownScanVerticesRule` 不一样：它写的是 `ScanVertices::setFilter`，走 **scanVertex** 路径（`StorageClient.cpp:270-272` → `ScanVertexProcessor`），不进 `GetPropProcessor`。

---

## 2. storaged：解码、校验、接进执行节点

### 2.1 buildFilter

`QueryBaseProcessor::buildFilter`（`src/storage/query/QueryBaseProcessor-inl.h`）是 GetNeighbors、Scan、GetProp 共用的：

```cpp
filter_ = Expression::decode(pool, *filterStr);
if (filter_ == nullptr) {
  return nebula::cpp2::ErrorCode::E_INVALID_FILTER;
}
// GetNeighbors 还会解码 tag_filter
return checkExp(filter_, false, true, false, true);
```

`checkExp` 白名单式地递归。允许常量、算术、比较、逻辑、`IN`、列表/集合/映射、`CASE`、函数调用（只检查参数）、tag/边属性、起点属性、边的 src/dst/rank/type。下面这些种类直接 `E_INVALID_FILTER`：

```
kInputProperty, kLabelTagProperty, kLabelAttribute, kVertex, kEdge,
kLabel, kVarProperty, kDstProperty, kUUID, kPathBuild, kColumn,
kESQUERY, kAggregate, kSubscriptRange, kVersionedVar, kMatchPathPattern
```

这和 [02](02-filter-pushdown.md) 的访问器是两道闸。优化器拒绝的表达式通常到不了这里；万一规则把 `$$` 或变量属性编码进了请求，storage 会返回 `E_INVALID_FILTER`，而不是在存储层按终点属性过滤。

`kDstProperty` 在这张表里是非法的。终点过滤不能靠 GetNeighbors 的 filter 字符串完成，只能留在 graphd，或者走 `joinDst` 之后的另一次取点。

### 2.2 GetNeighbors 的存储计划

`GetNeighborsProcessor::buildPlan`（`src/storage/query/GetNeighborsProcessor.cpp`）的节点顺序：

```
每个 tag  → SingleTagNode
每个 edge → SingleEdgeNode
        │
        ▼
HashJoinNode（tag 与 edge 按 vid 接在一起）
        │  没有边时改用 MultiTagNode，并 setFilterMode(TAG_ONLY)
        ▼
FilterNode<VertexID>     仅当 filter_ 非空
        │  上游是 HashJoin 时，边往外弹，tag 数据已经放进 StorageExpressionContext
        ▼
AggregateNode            仅当有 stat
        │
        ▼
GetNeighborsNode 或 GetNeighborsSampleNode（random 时）
        构造参数里带着 limit
```

`FilterNode` 的注释（`src/storage/exec/FilterNode.h`）说明它只接受一个上游。GetNeighbors 的 filter 同时含 tag 和边时，上游必须是 `HashJoinNode`：join 把 tag 放进表达式上下文，再逐条边调用 `check()`。`checkTagAndEdge` 先算 `tagFilterExp_`，再算 `filterExp_`。结果不是 bool，或者是 NULL，都当成不通过（注释：NULL is always false）。不通过则 `resultStat_ = FILTER_OUT` 或 `TAG_FILTER_OUT`，`next()` 继续下一条。

limit 不在 `FilterNode` 里截断，而在计划末端的 `GetNeighborsNode` / `GetNeighborsSampleNode`。过滤先发生，limit 作用在已经滤过的边上。

### 2.3 GetNeighbors 的 limit 与旗标：3.6 / 3.8 / master

`FLAGS_max_edge_returned_per_vertex` 定义在 `src/storage/StorageFlags.cpp`，默认 `INT_MAX`，注释是 "Max edge number returned searching vertex"。

`v3.6.0` 的 `GetNeighborsProcessor::doProcess`：

```cpp
int64_t limit = FLAGS_max_edge_returned_per_vertex;
if (traverse_spec.limit 有值 && *limit >= 0) {
  limit = *limit;          // 请求里的非负 limit 直接覆盖旗标
}
```

`v3.8.0` / `release-3.8` 收紧了：

```cpp
int64_t traverseLimit = *limit_ref;
if (traverseLimit >= 0 && traverseLimit < limit) {
  limit = traverseLimit;   // 只有比旗标更小才采用
}
```

master（`426266b5`）又改回「非负就采用」，不再要求 `< FLAGS_max_edge_returned_per_vertex`：

```cpp
if (*limit_ref >= 0) {
  limit = *limit_ref;
}
```

默认旗标是 `INT_MAX` 时，3.8 的额外条件和 master 几乎看不出差别：优化器嵌入的 `offset+count` 远小于 `INT_MAX`。一旦有人把旗标调小，3.8 会把下推的 limit **再裁**到旗标，master 和 3.6.0 则让请求 limit 覆盖旗标。负数在三份代码里都不会覆盖初始值，于是退回旗标。`TraverseExecutor` 对非最后一步传 `-1`，因此中间步受旗标限制，不受语句 LIMIT 限制。

Scan 不读这个旗标。`ScanEdgeProcessor` 只把请求 limit 为负时换成 `int64` 最大值。

### 2.4 Scan 的过滤点

`ScanEdgeProcessor::buildPlan` 不建独立的 `FilterNode`，而是把 `filter_->clone()` 交给 `ScanEdgePropNode`。`ScanVertexProcessor` 同样交给 `ScanVertexPropNode`。求值在 `ScanNode.h`：对当前 key 调 `filter_->eval(*expCtx_)`，`QueryUtils::vTrue` 为假就跳过。limit 是同一个节点的构造参数，在扫描循环里递减。

`GetPropProcessor` 把 filter 和 limit 传给取属性的节点（`GetPropNode.h` 里同样是 `filter_->eval`）。`AppendVertices` 上被 `PushFilterDownNodeRule` 或 `PushVFilterDownScanVerticesRule` 推下来的点过滤，走的是这条 getProps / scan 路径，不是 GetNeighbors 的 `FilterNode`。

### 2.5 Lookup

`LookupProcessor`（`src/storage/index/LookupProcessor.cpp`）在 index context 的 `filter` 非空时 `Expression::decode`。地理谓词规则会把条件下推进 index context（master 与 3.8 的差别只在选哪个 geography 索引，见 [01](01-optimizer-framework.md)）。索引范围本身由 `IndexScan` 的 column hint 决定，filter 是范围扫描之上的残余谓词。

---

## 3. 一条边过滤从 nGQL 到磁盘的调用链

以一步 `GO FROM "vid" OVER follow WHERE follow.degree > 1 YIELD follow.degree`，且 `--enable_optimizer=true` 为例。这是规则条件都满足时的路径，不是所有 GO 的路径。

```
GoValidator::validateWhere
  rewriteLabelAttr2EdgeProp，收集 edge prop degree
  rewrite2VarProp，Filter 里变成列变量
        │
GoPlanner::doPlan
  ExpandAll(edgeProps 至少含 _dst 和 degree)
  Filter(改写后的谓词) 在 ExpandAll 之上
        │
PushFilterDownExpandAllRule   （minSteps == maxSteps，edgeProps 非空）
  列名命中 → rewriteVarProp 还原 EdgeProperty
  ExpandAll.setFilter(follow.degree > 1)
  graphd Filter 若没有剩余谓词则被 erase
        │
ExpandAllExecutor::getNeighbors
  StorageClient::getNeighbors(..., limit, expand_->filter())
        │
TraverseSpec.filter = (follow.degree > 1).encode()
TraverseSpec.limit  = min(stepLimit, expand.limit)
TraverseSpec.edge_props 含 follow.degree
        │
GetNeighborsProcessor::buildFilter → checkExp
  通过则 FilterNode 挂在 HashJoin 之后
GetNeighborsNode 按 doProcess 算出的 limit 截断
```

`$$.player.age > 30` 在 `GoValidator` 就设 `joinDst`。`PushFilterDownExpandAllRule` 的 visitor 对终点属性判失败，`ExpandAll.filter` 不会带上它。`GetVertices` 把终点属性取回，graphd `Filter`（`condition` 字段，不是 `filter` 字段）再滤。RPC 的 `TraverseSpec.filter` 里不该出现 `kDstProperty`；出现了会被 `checkExp` 打成 `E_INVALID_FILTER`。

---

## 4. 属性列表和 filter 是两条通道

下推 filter 不会自动变成「只读过滤用到的列」。列由规划器的 `buildEdgeProps` / `SchemaUtil::getEdgeProps` 和优化结束后的 `PrunePropertiesVisitor` 决定。storage 的 `checkExp` 发现 filter 引用了尚未在 context 里的属性，会补 prop context，保证过滤能读到值。

`PrunePropertiesVisitor` 不访问 `Expand` / `ExpandAll` / `GetNeighbors`。GO 路径上少拉哪些边属性，主要看 `GoPlanner::doBuildEdgeProps` 从 `exprProps` 收集的集合，外加永远补上的 `kDst`。MATCH 的 `Traverse` 在 visitor 的 `visit` 列表里，`pruneCurrent(Traverse)` 会按上方用到的属性删 prop。笔记说属性裁剪「有限」，对 GO 尤其准确。

---

## 5. 执行期仍留在 graphd 的过滤

即使 RPC 已经带了 filter，这些求值点仍在 graphd：

| 位置 | 做什么 |
|------|--------|
| `FilterExecutor` | 规则没推下去的 `Filter.condition` |
| `TraverseExecutor::expand` | 残留的 `eFilter`、第 1 步的 `vFilter` |
| `LimitExecutor` | `offset` 和最终 `count`。存储侧拿到的是 `offset+count` |
| `GetNeighbors` 之上的 `HashLeftJoin` | GO `joinDst` 之后才能看见终点属性 |

`FilterNode` 在存储层滤掉的边不会出现在 `GetNeighborsResponse` 里。PROFILE 里 `TraverseExecutor` 给每一步记 `step[i].storage` 和 `total_rpc_time`（`TraverseExecutor::addStats`）。行数变少说明存储返回变少，但不能单靠 RPC 时间判断谓词是在 `FilterNode` 里滤的，还是根本没读到。要看计划上的 `filter` 字段，见 [05](05-explain-writing.md)。
