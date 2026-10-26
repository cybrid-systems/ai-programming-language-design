# 01-optimizer-framework — NebulaGraph 优化器框架与规则入口

> 源码：<https://github.com/vesoft-inc/nebula>
> master `426266b5c3df856d27f747b55b916dec542b7b59`（2026-09-08，`Set fixed GID/UID in Dockerfile`）
> tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`（2024-05-17）
> 分支 `release-3.8` `15fc0b7a12ba69b3977c6f4a9d70d15ec7f98742`（2025-03-19）
> 范围：`src/graph/optimizer/`、`src/graph/service/QueryEngine.cpp`、`src/graph/service/QueryInstance.cpp`
> 分析日期：2026-10-26

---

## 0. 概述

NebulaGraph 的算子下推不是独立的存储优化器，而是 graphd 上的**基于规则的计划改写**。规划器先按语句类型拼出一棵 `PlanNode` 树，优化器再把这棵树装进 Memo（`OptGroup` / `OptGroupNode`），用 `OptRule` 做模式匹配和替换。Filter、Limit 能不能进 storage，取决于有没有一条规则认出当前子树，并且表达式访问器判定子表达式可以下推。

本文回答六个问题：

1. 查询从 `QueryEngine` 到 `Optimizer::findBestPlan` 的入口在哪里。
2. `DefaultRules`、`QueryRules0`、`QueryRules` 各自装了什么，`--enable_optimizer` 关掉之后还剩什么。
3. `Pattern` / `MatchedResult` / `TransformResult` 如何描述一条规则。
4. 探索为什么不是 Cascades 式的代价搜索。
5. master、`v3.8.0`、`release-3.8` 在优化器上差了什么。
6. 属性裁剪为什么发生在规则探索之后，而不是某条 `Push*Project*` 规则。

### 与本系列其他篇的关系

| 文章 | 关系 |
|------|------|
| [02-filter-pushdown](02-filter-pushdown.md) | Filter 规则、`ExtractFilterExprVisitor`、GO 与 MATCH 的不同落点 |
| [03-limit-pushdown](03-limit-pushdown.md) | Limit 规则，以及 SHORTEST PATH 的 `| LIMIT` 折叠 |
| [04-storage-execution](04-storage-execution.md) | `filter` / `limit` 如何进 RPC，storaged 如何执行 |
| [05-explain-writing](05-explain-writing.md) | EXPLAIN 字段、写法，以及对原笔记的更正 |

---

## 1. 三个版本差在哪里

对照方式：浅克隆 master，再 `git fetch --depth 1` 取 tag `v3.8.0`、`v3.6.0` 和分支 `release-3.8`。下面的结论都来自 `git diff --stat` 和对应文件的直接阅读，没有用中间提交编造「某 PR 引入了某规则」。

| 对比 | `src/graph/optimizer/` |
|------|------------------------|
| `v3.8.0` vs `release-3.8` | 无差异。`src/graph/planner`、`src/graph/executor`、`src/storage/query` 同样无差异。 |
| `release-3.8` vs master | 只有 `rule/GeoPredicateIndexScanBaseRule.cpp`。master 按谓词里的 geography 属性名挑选索引，3.8 用 `indexItems.back()`。这不影响 Filter / Limit 下推规则。 |
| `v3.6.0` vs `v3.8.0` | `PushFilterDownGetNbrsRule`、`PushLimitDownScanEdgesRule`、`PushLimitDownAllPathsRule`、`PushLimitDownExpandAllRule` 在 3.6.0 已经存在。3.8 新增的不是这套规则本身，见 [03](03-limit-pushdown.md)。 |

master 相对 `release-3.8`，和本文相关的另一处差异在 storage，不在优化器：`GetNeighborsProcessor::doProcess` 对请求 limit 的裁剪方式变了，见 [04](04-storage-execution.md)。

`src/graph/optimizer/rule/` 在 master 上有 57 个 `*Rule.cpp`。规则在各自构造函数里把自己注册进某个 `RuleSet`，没有一张集中的注册表。

---

## 2. 优化器在查询链路里的位置

```
nGQL
  │
  ▼
Parser (src/parser/parser.yy)
  │  Sentence
  ▼
Validator  →  AstContext（GoContext / PathContext / ...）
  │
  ▼
Planner（GoPlanner / MatchPathPlanner / PathPlanner / ...）
  │  PlanNode 树，此时 Filter、Limit 多半还在 graphd 算子上
  ▼
QueryInstance::findBestPlan()
  │
  ▼
Optimizer::findBestPlan()
  │  prepare: PlanNode → OptGroup
  │  doExploration: 按 RuleSet 顺序反复套规则
  │  postprocess: 属性裁剪
  ▼
Executor（GetNeighbors / ExpandAll / Traverse / ScanEdges / ...）
  │  把算子上的 filter、limit 编码进 StorageClient RPC
  ▼
storaged（GetNeighborsProcessor / ScanEdgeProcessor / ...）
```

入口在 `QueryEngine::init`（`src/graph/service/QueryEngine.cpp`）。它先 `PlannersRegister::registerPlanners()`，再按开关组装规则集，构造唯一的 `opt::Optimizer`。每条查询由 `QueryInstance::execute` 走到 `findBestPlan`：

```cpp
// src/graph/service/QueryInstance.cpp
Status QueryInstance::findBestPlan() {
  auto plan = qctx_->plan();
  SCOPED_TIMER(plan->optimizeTimeInUs());
  auto rootStatus = optimizer_->findBestPlan(qctx_.get());
  NG_RETURN_IF_ERROR(rootStatus);
  auto root = std::move(rootStatus).value();
  plan->setRoot(const_cast<PlanNode *>(root));
  return Status::OK();
}
```

`Optimizer::findBestPlan`（`src/graph/optimizer/Optimizer.cpp`）的顺序是固定的：

```
findBestPlan(qctx)
  ├── checkPlanDepth(root)          // FLAGS_max_plan_depth，默认 512
  ├── prepare()
  │     └── convertToGroup()        // 自顶向下建 OptGroup，Select/Loop 的 body 另挂
  ├── rootGroup->setRootGroup()
  ├── doExploration()
  │     └── 最多 kMaxIterationRound（5）轮
  │           └── 每个 RuleSet 里的每条规则
  │                 ├── rootGroup->exploreUntilMaxRound(rule)  // 单规则最多 128 轮
  │                 ├── rootGroup->validate(rule)
  │                 └── rootGroup->setUnexplored(rule)
  └── postprocess()
        ├── rewriteArgumentInputVar()
        └── PrunePropertiesVisitor     // FLAGS_enable_optimizer_property_pruner_rule，默认 true
```

`doExploration` 的外层循环在 `octx->changed()` 为真时继续。规则 `transform` 成功会 `setChanged(true)`。五轮用完就停，不管计划是否还能再改。

---

## 3. 三套 RuleSet，以及默认开关

`RuleSet` 只有三个静态实例（`src/graph/optimizer/OptRule.cpp`）：

| RuleSet | 名字 | 谁注册进来 | 何时启用 |
|---------|------|------------|----------|
| `DefaultRules()` | `DefaultRuleSet` | 索引全扫描、索引选择、地理谓词索引 | 始终 |
| `QueryRules0()` | `QueryRuleSet0` | `EliminateFilterRule` | `FLAGS_enable_optimizer == true` |
| `QueryRules()` | `QueryRuleSet` | 全部 `PushFilter*`、`PushLimit*`、`PushEFilterDownRule`、`EmbedEdgeAllPredIntoTraverseRule`、`GetEdgesTransformRule` 等 | 同上 |

装配代码：

```cpp
// src/graph/service/QueryEngine.cpp
std::vector<const opt::RuleSet*> rulesets{&opt::RuleSet::DefaultRules()};
if (FLAGS_enable_optimizer) {
  rulesets.emplace_back(&opt::RuleSet::QueryRules0());
  rulesets.emplace_back(&opt::RuleSet::QueryRules());
}
optimizer_ = std::make_unique<opt::Optimizer>(rulesets);
```

`GraphFlags.cpp` 里的默认值是 **false**：

```cpp
// src/graph/service/GraphFlags.cpp
DEFINE_bool(enable_optimizer, false, "Whether to enable optimizer");
```

发行配置把这个开关打开了。`conf/nebula-graphd.conf.default`、`conf/nebula-graphd.conf.production`、`conf/nebula-standalone.conf.default` 都写着 `--enable_optimizer=true`。`v3.8.0` 与 master 都是这样。

因此：

- 用官方 graphd 配置启动时，Filter / Limit 规则会跑。
- 不带这份配置、只靠 flag 默认值时，`QueryRules` 整组不加载。索引相关的 `DefaultRules` 仍在，但 `PushFilterDownGetNbrsRule` 这类规则不会执行。下文讨论的下推都假设优化器已打开。

一条规则注册自己的方式是构造函数副作用。例如：

```cpp
// src/graph/optimizer/rule/PushFilterDownGetNbrsRule.cpp
PushFilterDownGetNbrsRule::PushFilterDownGetNbrsRule() {
  RuleSet::QueryRules().addRule(this);
}
```

静态 `kInstance` 在加载该翻译单元时构造，从而完成注册。`addRule` 对同一指针去重。规则之间没有显式优先级字段，顺序就是各 `.cpp` 被链接、静态初始化的顺序，再叠加探索时「先子节点、后当前节点」的后序。

---

## 4. OptRule：模式、匹配、替换

### 4.1 Pattern

`Pattern::create(kind, {子模式...})` 描述一棵算子树（`src/graph/optimizer/OptRule.h`）。`MatchNode` 允许 kind 列表，`kUnknown` 匹配任意算子。依赖按 `OptGroupNode` 的 `dependencies()` 下标对应，不是按数据流变量随便连。

`PushFilterDownGetNbrsRule` 的模式是 Filter 下面挂 GetNeighbors：

```cpp
const Pattern &PushFilterDownGetNbrsRule::pattern() const {
  static Pattern pattern =
      Pattern::create(PlanNode::Kind::kFilter, {Pattern::create(PlanNode::Kind::kGetNeighbors)});
  return pattern;
}
```

`MatchedResult::planNode({0, 1, 0})` 的下标约定写在 `OptRule.h` 的注释里：空下标是当前节点，`{0, 0}` 是第一个依赖。规则作者用这个路径取出要改的 `PlanNode`。

### 4.2 两段 match

`OptRule::match(ctx, groupNode)` 先用 `pattern().match` 对上树形，再调用虚函数 `match(ctx, matched)`。子类在这里加语义条件。基类还会走 `checkDataflowDeps`：输出变量的读者必须真的依赖当前 group，避免控制流和数据流不一致时误改。注释写明，少数规则可以自己保证正确性并绕过这层检查。

### 4.3 TransformResult

```cpp
struct TransformResult {
  bool eraseCurr{false};   // 删掉当前 group 里被匹配的那个 OptGroupNode
  bool eraseAll{false};    // 清空整个 group，只留下 newGroupNodes
  std::vector<OptGroupNode *> newGroupNodes;
};
```

`eraseAll` 用于「这条新计划必须取代旧计划」。`eraseCurr` 用于「删掉被匹配的节点，新节点已挂进同一 group」。返回 `noTransform()` 表示匹配到了但表达式不满足，计划不变。

探索实现在 `OptGroup::explore`（`src/graph/optimizer/OptGroup.cpp`）：

1. 先 `groupNode->explore(rule)`，也就是先优化子 group 和 Select/Loop 的 body。
2. 再对当前节点 `rule->match` / `transform`。
3. `eraseAll` 时清空 `groupNodes_` 再放入新节点。
4. 否则把新节点 `addGroupNode` 到链表尾部；若 `eraseCurr`，再删掉迭代器指向的旧节点。
5. 产生新节点会 `setUnexplored(rule)`，让 `exploreUntilMaxRound` 再跑。单规则上限是 `kMaxExplorationRound = 128`。

---

## 5. findBestPlan 不按代价选计划

组内「最优」来自 `OptGroup::findMinCostGroupNode`：遍历 `groupNodes_`，取 `getCost()` 最小者。`OptGroupNode::getCost` 直接返回 `node_->cost()`。

```cpp
// src/graph/planner/plan/PlanNode.h
double cost() const {
  return cost_;
}
// ...
double cost_{0.0};
```

全仓库没有 `setCost`，也没有给 `cost_` 赋值的语句。`cloneMembers` 的注释还写着 `TODO maybe shall copy cost_`。所有算子代价都是 `0.0`。

比较条件是 `if (minCost > cost)`，相等不替换。因此全是 0 时，**链表里的第一个 OptGroupNode 胜出**。新节点是追加到尾部的，所以：

- 规则使用 `eraseCurr` 或 `eraseAll` 把旧节点清掉时，新计划才会成为唯一（或新的第一个）节点，从而被 `getPlan()` 选中。
- 只追加、不删除的规则，旧节点仍排在前面，新计划不会被用到。

这不是 CBO，也不是「多条等价计划里挑便宜的」。名字叫 `findBestPlan`，实现是「规则改写 + 保留链表头」。下推是否生效，只看规则有没有把 filter/limit 写进存储算子并删掉或改掉旧节点。

---

## 6. 规划器先定形，优化器再搬表达式

下推规则只能改**已经存在**的算子邻接关系。语句种类决定初始树，这比规则本身更能解释「写法敏感」。

| 语句 | 规划器 | WHERE / LIMIT 的初始位置 |
|------|--------|--------------------------|
| `GO ... WHERE` | `GoPlanner::doPlan` | `Filter` 盖在 `ExpandAll` 上面，不是直接盖在 `GetNeighbors` 上 |
| `MATCH` 变长路径 | `MatchPathPlanner` | 生成 `Traverse`，边上的过滤先留在 `eFilter` / `vFilter` |
| `MATCH ()-[e]->() RETURN e LIMIT n` | 先是 `Project-Limit-Traverse-ScanVertices` | `GetEdgesTransformRule` 在满足条件时改成 `ScanEdges` |
| `FIND SHORTEST PATH ... \| LIMIT n` | `PathPlanner` | 解析器在 offset 为 0 时把 LIMIT 折进 `FindPathSentence`，规划器 `setLimit` 到 `BFSShortestPath` / `MultiShortestPath` |
| `FIND ALL PATH` | `PathPlanner::allPathPlan` | WHERE 是 `AllPaths` 上面的 `Filter`；管道 LIMIT 仍是独立 `Limit` 算子 |

`GO` 的初始形状（`src/graph/planner/ngql/GoPlanner.cpp`）：

```cpp
if (goCtx_->filter != nullptr) {
  dep = Filter::make(qctx, dep, goCtx_->filter);
}
dep = Project::make(qctx, dep, goCtx_->yieldExpr);
```

这里的 `dep` 在过滤之前已经是 `ExpandAll`（一步或变步）。所以 `PushFilterDownGetNbrsRule` 的模式 `Filter -> GetNeighbors` **对不上普通 GO**。GO 走的是 `PushFilterDownExpandAllRule`，而且 `match` 要求 `minSteps() == maxSteps()`。`GO 1 TO 3 STEPS` 不会被这条规则下推。细节见 [02](02-filter-pushdown.md)。

`ExpandAllExecutor` 头注释把这个分工写明了（`src/graph/executor/query/ExpandAllExecutor.h`）：`minSteps == maxSteps` 时，filter 和 limit 才可以下到 storage；变步时每一步的结果要在 graphd 侧合并。

---

## 7. 属性裁剪是后处理，不是 Push 规则

`Optimizer::postprocess` 在探索结束之后跑 `PrunePropertiesVisitor`（`src/graph/visitor/PrunePropertiesVisitor.h`）。开关 `FLAGS_enable_optimizer_property_pruner_rule` 默认 true，和 `--enable_optimizer` 无关：只要进了 `findBestPlan`，就会尝试裁剪。

访问器覆盖的节点包括 `Filter`、`Project`、`Aggregate`、`Traverse`、`ScanEdges`、`AppendVertices`、`HashJoin`、`Union`、`CrossJoin`、`Unwind`。它自顶向下记录表达式真正读到的属性，再回头删 `Traverse` / `AppendVertices` / `ScanEdges` 上多余的 prop。失败只打日志，不让查询失败：

```cpp
if (!visitor.ok()) {
  LOG(INFO) << "Failed to prune properties of query plan in post process of optimizer: "
            << visitor.status();
}
```

原笔记里的「Project 相关规则做属性裁剪」不准确。和 Project 相邻的规则是 `PushLimitDownProjectRule`、`PushFilterDownProjectRule`、`CollapseProjectRule`、`MergeGetNbrsAndProjectRule`，它们移动 Limit/Filter 或合并 Project，不负责裁 prop。裁 prop 的是这个 visitor。它能少拉一些列，但只处理自己 `visit` 到的算子；`GetNeighbors` 本身没有单独的 `visit` 重载，GO 路径上的 `Expand` / `ExpandAll` 也不在访问器的声明里。所以裁剪覆盖面有限，这一点和笔记的结论一致，机制不同。

---

## 8. 读代码时的锚点

| 符号 | 文件 | 作用 |
|------|------|------|
| `QueryEngine::init` | `src/graph/service/QueryEngine.cpp` | 组装 RuleSet，创建 Optimizer |
| `QueryInstance::findBestPlan` | `src/graph/service/QueryInstance.cpp` | 用优化结果替换 plan root |
| `Optimizer::findBestPlan` / `doExploration` | `src/graph/optimizer/Optimizer.cpp` | 5 轮规则探索 + 属性裁剪 |
| `RuleSet::DefaultRules/QueryRules0/QueryRules` | `src/graph/optimizer/OptRule.cpp` | 三个静态规则集 |
| `OptGroup::explore` / `exploreUntilMaxRound` | `src/graph/optimizer/OptGroup.cpp` | 后序匹配、erase、128 轮上限 |
| `PlanNode::cost` | `src/graph/planner/plan/PlanNode.h` | 恒为 0，选择退化为链表头 |
| `FLAGS_enable_optimizer` | `src/graph/service/GraphFlags.cpp` | 代码默认 false，发行 conf 为 true |
| `PrunePropertiesVisitor` | `src/graph/visitor/PrunePropertiesVisitor.h` | 探索之后的列裁剪 |
