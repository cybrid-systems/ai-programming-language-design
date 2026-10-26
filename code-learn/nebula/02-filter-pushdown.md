# 02-filter-pushdown — Filter 下推：规则、表达式、GO 与 MATCH

> 源码基线与 [01-optimizer-framework](01-optimizer-framework.md) 相同：master `426266b5`，对照 `v3.8.0` `fa928930` / `release-3.8` `15fc0b7`。
> 本节涉及的 Filter 规则在这三份树上内容一致（`git diff release-3.8 master -- src/graph/optimizer/rule/PushFilter*` 为空）。
> 分析日期：2026-10-26

---

## 0. 概述

Filter 下推做的事情是：把 `Filter` 算子上的谓词拆开，能在存储层算的那一半写进 `GetNeighbors` / `ExpandAll` / `Traverse` / `ScanVertices` 的 `filter` 字段，剩下的留在 graphd。判断「能不能下」的不是规则类名，而是 `ExtractFilterExprVisitor` 对表达式种类的开关。

本文按调用链写：

1. 哪些规则注册在 `QueryRules`，模式分别是什么。
2. `ExtractFilterExprVisitor` 对 `$^`、`$$`、边属性、函数调用的判定。
3. `GO` 为什么不走 `PushFilterDownGetNbrsRule`。
4. `MATCH` 的 `Traverse` 如何把边谓词先放进 `eFilter`，再由 `PushEFilterDownRule` 送进 storage。
5. `all()`、终点属性、`src()` / `dst()` 和原笔记不一致的地方。

---

## 1. 规则一览

全部在构造函数里 `RuleSet::QueryRules().addRule(this)`，因此依赖 `--enable_optimizer=true`（发行 conf 默认打开，flag 默认值是 false）。见 [01](01-optimizer-framework.md)。

| 规则 | 模式 | 额外 match 条件 | 写到哪里 |
|------|------|-----------------|----------|
| `PushFilterDownGetNbrsRule` | `Filter -> GetNeighbors` | `edgeProps` 非空 | `GetNeighbors::setFilter` |
| `PushFilterDownExpandAllRule` | `Filter -> ExpandAll` | `minSteps == maxSteps` 且 `edgeProps` 非空 | `ExpandAll::setFilter` |
| `PushFilterDownTraverseRule` | `Filter -> Traverse` | `Traverse::isOneStep()` | `Traverse::setEdgeFilter`（还不是 storage filter） |
| `EmbedEdgeAllPredIntoTraverseRule` | `Filter -> Traverse` | 谓词里有边上的 `all()` | 改写后 `setEdgeFilter` |
| `PushEFilterDownRule` | 单个 `Traverse` | `eFilter != nullptr` 且 `!zeroStep()` | `eFilter` 改写后并入 `Traverse::filter` |
| `PushFilterDownNodeRule` | 单个 `Traverse` 或 `AppendVertices` | 已有 `vFilter` | 可下推的部分进 `firstStepFilter` 或 `AppendVertices::filter`，其余留在 `vFilter` |
| `PushFilterDownScanVerticesRule` | `Filter -> ScanVertices` | 无 | `ScanVertices::setFilter`，visitor 用 `kGetVertices` |
| `PushVFilterDownScanVerticesRule` | `AppendVertices -> ScanVertices` | src 是 vid 列，且 `vFilter` 里没有 `*` tag | `vFilter` 与 `filter` 并入 `ScanVertices::filter` |
| `PushFilterDownAllPathsRule` | `Filter -> AllPaths` | `edgeProps` 非空（和 GetNbrs/ExpandAll 同一道门）；子表达式可下推在 `transform` 里再查 | `AllPaths::setFilter` |
| `PushFilterDownProjectRule` | `Filter -> Project` | 穿过 Project | 不直接进 storage |
| `PushFilterThroughAppendVerticesRule` | `Filter -> AppendVertices` | 穿过取点 | 不直接进 storage |

头文件里的示意图就是规则作者定义的变换。`PushFilterDownGetNbrsRule.h` 写的是：

```
Filter ($^.player.age>3 AND $$.player.age<4)
        |
   GetNeighbors

        变成

Filter ($$.player.age<4)
        |
GetNeighbors ($^.player.age>3)
```

起点属性可以进 GetNeighbors，终点属性留在 graphd。这是源码注释，不是推断。

---

## 2. ExtractFilterExprVisitor：真正的判定表

文件：`src/graph/visitor/ExtractFilterExprVisitor.h`、`.cpp`。

访问器有三种 `PushType`，默认是 `kGetNeighbors`。`makePushGetVertices` / `makePushGetEdges` 会改类型。`PushFilterDownGetNbrsRule` 用的是默认构造，也就是 `kGetNeighbors`，并且 **不传** `SchemaManager`（`spaceId_ == -1`），所以优化期不做「tag/边是否存在」的检查。storage 端的 `QueryBaseProcessor::checkExp` 会再查一次 schema。

`visit` 对叶子的结论：

| 表达式 | `kGetNeighbors` | `kGetVertices`（Scan/GetVertices） | `kGetEdges` |
|--------|-----------------|--------------------------------------|-------------|
| `EdgeProperty`（`follow.degree`） | 可 | 不可 | 可 |
| `SourceProperty`（`$^.tag.prop`） | 可 | 不可 | 不可 |
| `DestProperty`（`$$.tag.prop`） | 不可 | 可 | 不可 |
| `EdgeSrc` / `EdgeDst` / `EdgeRank` / `EdgeType` | 可 | 不可 | 可 |
| `TagProperty` | 不可 | 可；`sym == "*"` 不可 | 不可 |
| `Label`、`UUID`、`Vertex`、`Edge`、`InputProperty`、`Column`、`SubscriptRange` | 不可 | 不可 | 不可 |
| `LabelTagProperty` | 不可。注释写明 storage 不支持，应事先改写成 tag/vertex 属性 | 同左 | 同左 |
| `Variable` | 仅 inner var 可 | 同左 | 同左 |
| `VariableProperty` | 属性名在构造时传入的 `colNames_` 里才可 | 同左 | 同左 |
| 常量 | 可 | 可 | 可 |

函数调用没有单独判死。`ExprVisitorImpl::visit(FunctionCallExpression)` 只递归参数；参数里一旦出现不可下推的叶子，`canBePushed_` 就变成 false。因此：

- `src(e)`、`dst(e)`、`properties(e)` 的参数是 `Label` 或 `Edge`，**不能**下推。
- `id($$)`、`properties($$)` 碰到 `Vertex` / `DestProperty`，在 `kGetNeighbors` 下**不能**下推。
- `follow._src`、`follow._dst` 在解析器里就是 `EdgeSrcIdExpression` / `EdgeDstIdExpression`（`src/parser/parser.yy` 的 `edge_prop_expression`），**可以**下推。`follow.degree` 不是：`edge_prop_expression` 只产 Type/SrcId/DstId/Rank 四个，`follow.degree` 走 `name_label DOT name_label`（`parser.yy:849`）先成 `LabelAttributeExpression`，之后由 `rewriteLabelAttr2EdgeProp`（`GoValidator.cpp:77`）才改写成边属性。可下推性不变。
- `abs(follow.degree)` 这种包住边属性的函数，访问器会认为可以下推。storage 的 `checkExp` 对 `kFunctionCall` 也只递归参数，不维护函数黑名单。能不能算对，取决于 storaged 的表达式求值里有没有这个函数，而不是优化器拒收。

`NOT (A AND B)` / `NOT (A OR B)` 被显式拒绝：注释写明这种 NOT 本应先被化简，没化简就下推会产生错误结果（`ExtractFilterExprVisitor::visit(UnaryExpression)`）。

AND / OR 的拆分：

- AND：任一子式可下推就把可下推的留在原表达式（随后被规则写进存储算子），不可下推的放进 `remainedExpr()`，留给 graphd `Filter`。
- OR：只有一种形式允许拆。注释写的是「恰好一个不能下推的操作数，且它是 AND」时，把 OR 改写成 AND 的分配。其他 OR 只要有一支出不去，整支都不下推。
- 嵌在 AND 里的复杂逻辑在 `isNested_` 时更保守：不能全部下推就整段留下。

规则侧的使用方式在 `PushFilterDownGetNbrsRule::transform`：

```cpp
graph::ExtractFilterExprVisitor visitor(pool);
condition->accept(&visitor);
if (!visitor.ok()) {
  return TransformResult::noTransform();
}
auto remainedExpr = std::move(visitor).remainedExpr();
// condition 已被 visitor 改成「可下推的那一半」
auto newGNFilter = condition;
if (gn->filter() != nullptr) {
  newGNFilter = LogicalExpression::makeAnd(pool, condition, gn->filter()->clone());
}
newGN->setFilter(newGNFilter);
```

`remainedExpr == nullptr` 时删掉 graphd `Filter`，整条谓词进 `GetNeighbors`。否则上面留一个只含剩余谓词的 `Filter`。

`PushFilterDownGetNbrsRule::match` 还有一道门：`edgeProps == nullptr` 或为空就直接跳过。不取边属性的 GetNeighbors 不会嵌这条 Filter。

---

## 3. GO：Filter 落在 ExpandAll，不落在 GetNeighbors

### 3.1 校验器先改写谓词

`GoValidator::validateWhere`（`src/graph/validator/GoValidator.cpp`）把 `follow.degree` 这类 label attribute 改成 `EdgePropertyExpression`，做常量折叠和类型检查，再 `deduceProps` 收集用到的边、tag。`buildColumns` 里如果有 filter，会 `extractPropExprs` 并把谓词改写成**列上的变量属性**：

```cpp
if (filter != nullptr) {
  NG_RETURN_IF_ERROR(extractPropExprs(filter, uniqueEdgeVertexExpr));
  goCtx_->filter = rewrite2VarProp(filter);
}
```

`checkDstPropOrVertexExist` 看到 `$$` 或 `kDstProperty` 就把 `joinDst` 设为 true。终点属性不进遍历算子的 filter，而是多一个 `GetVertices` + `HashLeftJoin`（`GoPlanner::buildJoinDstPlan`）。这就是「终点属性先拉回 graphd」的具体计划形状。

`WHERE` 本身也会让 `isSimpleCase()` 返回 false。简单计划（只 yield `edge._dst`、无 filter、无 step limit）走 `Expand`，不会建带属性的 `ExpandAll`。一带 WHERE，就进入 `doPlan` 的 `Expand` + `ExpandAll` + 可选 join + `Filter` + `Project`。

### 3.2 规则只认一步

`PushFilterDownExpandAllRule::match`：

```cpp
if (expandAll->minSteps() != expandAll->maxSteps()) {
  return false;
}
auto edgeProps = expandAll->edgeProps();
return edgeProps != nullptr && !edgeProps->empty();
```

`GO 2 STEPS` 的 min 和 max 相等，可以尝试。`GO 1 TO 3 STEPS` 不相等，整条 WHERE 留在 graphd `Filter`。`GoPlanner::doBuildEdgeProps` 至少会放 `kDst`，所以正常的 `OVER follow` 能通过 `edgeProps` 非空这道检查。

`transform` 用的 visitor 是 `ExtractFilterExprVisitor(pool, colNames)`。GO 的谓词此时已经是变量属性，只有列名出现在 `ExpandAll` 输出列里才算可下推。通过之后 `rewriteVarProp` 把列名换回 `vertexColumns` / `edgeColumns` 上的原始表达式（边属性或起点属性），再 `ExpandAll::setFilter`。

执行器在每一步的最后一跳把这个 filter 交给 storage（`src/graph/executor/query/ExpandAllExecutor.cpp`）：

```cpp
return storageClient->getNeighbors(param,
                                   {nebula::kVid},
                                   std::move(vids),
                                   {},
                                   storage::cpp2::EdgeDirection::OUT_EDGE,
                                   nullptr,
                                   expand_->vertexProps(),
                                   expand_->edgeProps(),
                                   nullptr,
                                   false,
                                   sample_,
                                   std::vector<storage::cpp2::OrderBy>(),
                                   limit,
                                   expand_->filter(),
                                   nullptr);
```

注意方向参数这里写死了 `OUT_EDGE`，边的反向由 `edgeProps` 里的负 edge type 表达。filter 为空（规则没推下来）时，RPC 不带过滤，graphd 上的 `Filter` 算子再滤。

### 3.3 和「GO 一定比 MATCH 容易下推」的差别

一步、显式边类型、谓词只引用边属性或 `$^` 时，GO 确实会进 `ExpandAll.filter`，再进 `getNeighbors`。下面这些情况规则直接放弃，和 MATCH 谁更「容易」无关：

- `m TO n` 变步。
- 谓词引用 `$$`。计划会 `joinDst`，过滤发生在 join 之后的 graphd `Filter`。
- 谓词在改写后含有不在 `ExpandAll` 列名中的变量属性。
- `--enable_optimizer=false`。

---

## 4. MATCH / Traverse：边谓词要走两步

`MatchPathPlanner` 为每一跳生成 `Traverse`（`src/graph/planner/match/MatchPathPlanner.cpp`），并 `setEdgeProps`。边上的 WHERE 不会一开始就进 `Traverse::filter`。

### 4.1 一步边属性：PushFilterDownTraverseRule

`match` 要求 `traverse->isOneStep()`。多跳 `[*2..5]` 不走这条规则。

`transform` 用 `ExpressionUtils::splitFilter` 挑选「相对 `edgeAlias` 的一步边属性」。挑选时如果碰到 `InputProperty`、`VarProperty`，或者 `exists(...)`，整段放弃（源码里有 `TODO(jie): Handle the strange exists expr`）。挑中的表达式经 `rewriteEdgePropertyFilter` 后并入 `eFilter`。没挑中的留在上面的 `Filter`。

此时谓词还在 `eFilter`，`TraverseExecutor` 会在 graphd 上对 `GetNeighborsIter` 求值（见下）。

### 4.2 all()：EmbedEdgeAllPredIntoTraverseRule

只认谓词函数名 `all`，collection 是边别名，内部变量是 inner var，属性名是常量字符串。`NOT` 会把 `all` 变成 `any` 的语义，规则直接 `neverPicked`。内部的 `e.prop` 被改写成 `EdgePropertyExpression("*", prop)`，并入 `eFilter`。

所以笔记里的「`all()` 等部分谓词可以嵌入」只覆盖 **边上的 `all()`**，不覆盖 `any()`，也不覆盖带 `NOT` 的 `all()`。

### 4.3 送进 storage：PushEFilterDownRule

```cpp
bool PushEFilterDownRule::match(...) const {
  auto traverse = static_cast<const Traverse *>(matched.planNode({0}));
  // zero step 与 1 step 对 eFilter 的要求冲突，有 0 步就不下推
  return traverse->eFilter() != nullptr && !traverse->zeroStep();
}
```

`transform` 先 `rewriteStarEdge`：边类型只有一个（或 BOTH 下成对的正负类型）时，把 `*` 换成具体边名；多种边时包成 `_any(...)`。然后用默认的 `ExtractFilterExprVisitor`（`kGetNeighbors`）再滤一次。通过后：

- `Traverse::eFilter` 改成 **不能**下推的剩余式（可能是 nullptr）。
- 可下推的那一半 AND 进 `Traverse::filter`。

`TraverseExecutor::selectFilter` 把 `filter` 放进 `StorageClient::getNeighbors` 的 filter 参数；第 0 步且 `range.min()==0` 时不用这份 filter。`eFilter` 不进 RPC，留在 `TraverseExecutor::expand` 里对迭代器 `eval`。

因此 EXPLAIN 上要分三个字段，不能只看一个 `filter:`：

| 字段 | 谁填的 | 在哪执行 |
|------|--------|----------|
| `filter` | `PushEFilterDownRule` 等写进 `Traverse::filter` | storaged `FilterNode` |
| `edge filter` | 还没推下去的 `eFilter` | graphd `TraverseExecutor::expand` |
| `vertex filter` | 终点/点上的 `vFilter` | graphd，同函数里 `currentStep_ == 1` 时求值 |
| `first step filter` | `PushFilterDownNodeRule` 从 `vFilter` 拆出的可下推部分 | 第 1 步并进 `selectFilter()`，随 RPC 下发 |
| `tag filter` | 起点 tag | 仅 `currentStep_ == 1` 时作为 `tagFilter` 下发 |

`PushFilterDownNodeRule` 用 `makePushGetVertices`。`$$.tag.prop` 在这个类型下是**可**下推的，但目的地是 `firstStepFilter` / `AppendVertices.filter`，不是终点顶点已经在存储层按 tag 索引过滤。`DestProperty` 对 `kGetNeighbors` 仍然不可下推，所以它不会出现在普通 GetNeighbors 的 `filter` 里。多跳上的终点属性继续留在 `vFilter`，由 graphd 滤。

---

## 5. 点扫描上的 Filter

`MATCH (v)` 没有可定位的起点时，`ScanSeek::transformNode` 生成 `ScanVertices`（`src/graph/planner/match/ScanSeek.cpp`）。`ScanSeek::matchEdge` 固定返回 false，边模式不能直接 ScanSeek，注释是 `Unimplemented for edge pattern`。边扫描要等 `GetEdgesTransformRule`，见 [03](03-limit-pushdown.md)。

`PushFilterDownScanVerticesRule` 用 `makePushGetVertices`。tag 属性可以进 `ScanVertices.filter`，边属性不行。`PushVFilterDownScanVerticesRule` 只处理一种特殊形状：`AppendVertices` 的 src 就是 `ScanVertices` 吐出的 vid 列，把点过滤挪到扫描上。src 不是 vid，或者 `vFilter` 里有 `*.prop`，规则不匹配。

---

## 6. 对原笔记的更正

| 原笔记 | 源码 |
|--------|------|
| GO / GetNeighbors / Traverse 上的边属性条件可以下推到 storage | 一步 GO 走 `ExpandAll.filter`；`PushFilterDownGetNbrsRule` 只匹配真正的 `GetNeighbors`。MATCH 的边谓词先进入 `eFilter`，再由 `PushEFilterDownRule` 进入 `Traverse.filter`。变步 GO、带 0 步的 Traverse 不下推。 |
| 终点 `$$.tag.prop`、`properties($$)` 多跳时无法下推 | 成立。`kGetNeighbors` 拒绝 `DestProperty` 和 `Vertex`。GO 会因此 `joinDst`。`PushFilterDownNodeRule` 可以把一部分点过滤放进 first-step filter，但不是多跳终点过滤。 |
| `src()` / `dst()` / `properties()` / `id()` 通常阻碍下推，原生 `edge._src` 更好 | 机制成立，原因是参数种类而不是「函数」这个语法类别。`follow._src` 是 `EdgeSrcIdExpression`，可以下推。`src(e)` 的参数是 label，不可以。包住边属性的普通函数（如 `abs(follow.degree)`）访问器不会拒绝。 |
| `all()` 等部分谓词可嵌入 | 仅 `EmbedEdgeAllPredIntoTraverseRule` 处理边上的 `all()`。`any()` 和被 `NOT` 包住的 `all()` 不嵌入。 |
| 显式边类型更容易下推 | `PushEFilterDownRule::rewriteStarEdge` 在单一边类型时把 `*` 换成边名；多种边则包 `_any`。`edgeProps` 为空时 GetNeighbors / ExpandAll 两条规则直接 match 失败。显式 `OVER follow` 让规划器带上边属性，这条观察成立。 |

不确定、源码里没有写死的部分：某种具体 nGQL 在 EXPLAIN 里最终落在 `filter` 还是 `edge filter`，还取决于 yield 列名是否被 `rewrite2VarProp` 收进 `ExpandAll` 的输出列。上面给出的是规则条件，不是把每条语句都跑过一遍的执行日志。

能力总表见 [10](10-pushdown-capability.md)。「美妆类商品、近 3 个月购买、用户去重」这条 1 跳反向边的计划，以及 `getDstBySrc` 补丁，见 [11](11-scenario2-beauty-buyers.md)。变步 GO 仍然不下推。
