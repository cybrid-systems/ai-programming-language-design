# 11 — 场景二：买过美妆、且发生在近 3 个月的用户

> 用户原文里的目标句是：购买过美妆类商品、且购买时间在近 3 个月内的活跃用户。再按销售额排序。
> 线上观察（用户提供，不是本次测量）：10–200 并发时 P99 135–345 ms；加上销售额排序后到不了 35 ms。
> 源码：`v3.8.0` `fa928930` 与 master `426266b5` 在本文引用的 planner / executor 上一致，除了补丁本身。
> 补丁：[`patches/v3.8.0-dst-only-edge-filter.patch`](patches/v3.8.0-dst-only-edge-filter.patch)，`git apply` 打在 `v3.8.0`。
> 单机实测（数字在 [12](12-scenario2-bench.md)，不是线上的 135–345 ms）：[`bench/scenario2/`](bench/scenario2/)。
> 分析日期：2026-10-26。

35 ms 相对 135–345 ms 大约是 4–10 倍。少回传 40% 的边，时延下界仍然在 80 ms 以上。下面先改用户拆解里和源码不一致的地方，再写补丁实际切的是哪一段，以及为什么销售额排序更该改模型。

---

## 1. 和用户拆解对照

用户的六步，对照 `v3.8.0`（优化器按发行 conf 打开）：

| # | 用户的说法 | 源码 |
|---|------------|------|
| 1 | 持有 type 索引的那台 storaged 做 IndexScan，`type == 美妆` | 索引键按 part 前缀，`indexPrefix(partId, indexId)`，见 [08](08-index-key-encoding.md)。LOOKUP 扫的是**每个 part** 上的这份索引，不是某一台机器。非全文 LOOKUP 的计划节点是 `TagIndexFullScan`（`LookupPlanner::transform`），随后 `IndexScanRule` / `OptimizeTagIndexScanByFilterRule` 可以把 `type == "beauty"` 收成前缀。全文索引才是 IndexScan 再 `GetVertices` |
| 2 | GetVertices 拿商品 VID，可能跨节点 | 非全文 LOOKUP 的 yield 列（至少 `id(vertex)`）从索引行里出来，**没有** `GetVertices`。要商品上索引没覆盖的属性，才需要另一次 FETCH，那是第 6 步的形态 |
| 3 | 每个商品 VID 一次 GetInEdges，这是跨节点热点 | 没有 GetInEdges 这个 RPC。`REVERSELY` 把 `buy` 的 type 取负，RPC 仍是 `getNeighbors` 或 `getDstBySrc`，方向参数保持 `OUT_EDGE`。`StorageClient::clusterIdsToHosts` 把落在同一 host 上的 VID **拼成一次请求**，按 part 放进 `parts` map。RPC 次数约等于「拥有至少一个命中商品的 host 数」，不是商品个数。host 内部仍按商品 VID 做前缀扫描，CPU 和边条数成正比。反向边的 key 写在商品所在 part，所以这次 RPC 的目标 host 就是商品 VID 的 host |
| 4 | 边上 `timestamp > now-3个月`，希望在 storaged 做 | **一步 GO、优化器打开、谓词是边属性时，这已经发生。** 见下一节。没发生的是：`YIELD DISTINCT buy._dst` 被 WHERE 挡在 `getDstBySrc` 外面，过滤后的用户 VID 仍以整条边的形式回来 |
| 5 | Project / Dedup 在 graphd | 投影：storage 按 `edgeProps` 回列，graphd `Project` 再裁成 YIELD。`buildYields` 不算任意表达式。去重：`GetNeighbors` 的 `dedup` 标志是「每个顶点的邻居行」，不是跨商品的用户 VID。跨 host 的 DISTINCT 只能在 graphd 收尾 |
| 6 | 可选的第二次 GetVertices 拉用户属性 | 只有 `$$` / 终点 tag，或后面再 FETCH。`YIELD buy._dst` 不会自动取用户点 |

通信上真正随「美妆商品很多」变大的，是每个 host 上**命中边的条数**（GetNeighbors 的 `list<list<Value>>`），以及 host 数。边过滤下推去掉的是时间窗口外的边，不去掉窗口内每个购买仍回一行这件事。

---

## 2. 两种写法各自的计划

购买边按 `user -[buy {ts, amount}]-> item` 存。从商品找回用户是入边，nGQL 用 `REVERSELY`。反向 key 的 dst 才是用户。

### 2.1 `LOOKUP | GO`，YIELD 里有金额

```ngql
LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id
| GO FROM $-.id OVER buy REVERSELY
    WHERE buy.ts > now() - 7776000
    YIELD buy._dst AS uid, buy.amount AS amt
| GROUP BY $-.uid YIELD $-.uid AS uid, sum($-.amt) AS sales
| ORDER BY $-.sales DESC
| LIMIT 100
```

`GoValidator::isSimpleCase` 要求 YIELD 每一列都是 `EdgeDst`（`buy._dst`），并且原来只要有 WHERE 就返回 false。这条语句 YIELD 了金额，走 `GoPlanner::doPlan`。管道再往上接 Aggregate、Sort、Limit。`TopNRule` 把 offset 为 0 的 `Limit → Sort` 收成 graphd `TopN`。根在上：

```
TopN                         ← ORDER BY + LIMIT，graphd
  Aggregate                  ← GROUP BY，graphd
    Project                  ← GO 的 YIELD
      Filter                 ← 最初在 HashInnerJoin 之上；一步且优化器开时会被拆掉
        HashInnerJoin
          TagIndexFullScan   ← LOOKUP，列 0 必须是 vid
          ExpandAll(1,1)     ← 其下 Expand 步数为 0，不发 RPC
```

这次没有 graphd 进程，上面是 planner 和规则 match 条件串起来的，不是一份 EXPLAIN 日志。

`validateWhere` 之后 `buildColumns` 用 `ExtractPropExprVisitor` 把 `buy.ts` 收成匿名列 `__COL_n`（`AnonColGenerator`），`rewrite2VarProp` 把 WHERE 改成 `VariableProperty("", "__COL_n")`。`ExpandAll` 的 `colNames` 来自 `edgeColumns` 的别名，管道场景再在前面插入 `_expand_vid`。`__COL_n` 在右孩子的列名里。

`PushFilterDownHashInnerJoinRule` 用 `ExpressionUtils::checkColName` 拆谓词。`checkColName` 只认 `VariableProperty` / `Vertex` / `Edge`。改写后的 WHERE 是 `VariableProperty`，右孩子列名对得上，Filter 被挪到 `ExpandAll` 之上。下一轮 `PushFilterDownExpandAllRule`：`minSteps == maxSteps`，`edgeProps` 非空，把谓词写进 `ExpandAll.filter`，graphd 上的 Filter 去掉。`ExpandAllExecutor::getNeighbors` 把这个 filter 放进 `GetNeighborsRequest`。

所以「边 timestamp 过滤下推」在这条语句上**已经有了**。没下推的是 `GROUP BY` 和 `ORDER BY ... LIMIT`。`PushTopNDownIndexScanRule` 要求 `TopN` 的正下方是 `Project → IndexScan`。这里 TopN 下面是 Aggregate，匹配不上。`AggregateNode`（`src/storage/exec/AggregateNode.h`）只对**一个顶点的全部合格边**做 SUM/AVG/MIN/MAX/COUNT，列名是 `_stats:...`，不是按 dst 分组。

`$$.user.xxx` 会把 `joinDst` 设上，终点谓词留在 `HashLeftJoin` 之上，不进 GetNeighbors。

### 2.2 `LOOKUP | GO`，只要去重后的用户

```ngql
LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id
| GO 1 STEP FROM $-.id OVER buy REVERSELY
    WHERE buy.ts > now() - 7776000
    YIELD DISTINCT buy._dst AS user
```

`dst(edge)` 在 `isSimpleCase` 执行时仍是函数调用，kind 不是 `kEdgeDst`。`rewriteVertexEdge2EdgeProp` 只改写 `id($$)`、`id($^)`、`rank(edge)`、`typeid(edge)`。要进简单计划，YIELD 必须写成 `buy._dst`。

flag `--enable_dst_only_edge_filter` **默认 false** 时，有 WHERE 就不是 simple，计划与 2.1 同类：`GetNeighbors` 回每一条命中边（至少 `_dst` 和 `ts`），graphd 再 `Dedup`。过滤已经在 storaged，回传仍是「一条购买一行」。

flag 打开、且谓词能通过 `DstOnlyEdgeFilter::canPush`、且正好 1 步、且 YIELD 只有 `buy._dst` 时，`isSimpleCase` 为 true。`doSimplePlan` 的 `Expand` 步数是 1，不建 `ExpandAll`，`ExpandExecutor` 走 `getDstBySrc` 而不是 `getNeighbors`（`joinInput` 在简单计划上不置位，管道的 VID 从上一句输出的第 0 列读）。`LOOKUP` 的第一列必须是 `id(vertex)`。

### 2.3 MATCH

```ngql
MATCH (i:item)<-[e:buy]-(u)
WHERE i.type == "beauty" AND e.ts > now() - 7776000
RETURN DISTINCT id(u)
```

方向：`(i)-[e:buy]->(u)` 是从商品沿出边走，和「用户指向商品」的存储相反。入边要写成 `<-[e:buy]-`。`MatchPathPlanner` 把 `edge.direction` 设到 `Traverse`。

`i.type == "beauty"` 若能被 `PropIndexSeek::matchNode` 收成索引过滤，起点是 `IndexScan`（再 `Dedup`），不是 GetVertices。`e.ts > t` 先放在 `Traverse.eFilter`，`PushEFilterDownRule` 在非 0 步时并入 `Traverse.filter`，每一跳的 `GetNeighbors` 都带。`RETURN DISTINCT` 由 `YieldClausePlanner` 在 graphd 加 `Dedup`。`traverse->setDedup()` 另外让 storage 在最后一跳按该顶点的邻居行去重，仍然不是跨商品的用户集合。

MATCH 这条补丁**不改**。边过滤已经在 storaged，用户去重仍在 graphd，销售额聚合也仍在 graphd。

---

## 3. 补丁：1 步 DISTINCT dst 走 getDstBySrc

### 3.1 为什么是这一处

场景二的第 3 步，在过滤已经下推之后，剩下的跨 host 字节是「窗口内的每一条购买」。`GetDstBySrc` 本来就只回 dst，并且在 `onProcessFinished` 里按 host 去重，但它的请求没有 filter，`SingleEdgeNode` 还把 `maySkipDecode` 设成 true，值都不读。`GoValidator::isSimpleCase` 看到 WHERE 就放弃这条 RPC。

补丁让下面这句在 flag 打开后走 `getDstBySrc`：

- `GO 1 STEP`（不是 `M TO N`，也不是 2 步以上——中间跳不能过滤，否则走不到终点）
- `YIELD DISTINCT buy._dst`（与原来的简单计划相同；多列或 `dst(edge)` 仍走 `GetNeighbors`）
- WHERE 只含有名字的边属性、边的 `_src/_dst/_rank/_type`、常量、比较、算术、逻辑、函数（参数也得满足这些）。`*`、`$$`、`$^`、tag、输入变量、整条 `edge` 表达式都拒绝
- 没有 SAMPLE / 每步 LIMIT（原来的 `isSimpleCase` 已经拒绝非空 `limits`）

`now()` 在 `FunctionManager` 里注册了，返回 `INT`，`getIsPure("now")` 不是纯函数，不会被折成常量。每个 storaged 在扫边时各自求值。3 个月的窗口对秒级时钟差不敏感；若要全集群用同一个截止时间，把字面量写进语句。

host 内同一个用户买了多件美妆，响应从「每条边一行」变成「每个用户一个 VID」。不同 host 上的同一个用户仍会各回一次，graphd 的 `Dedup` 保留。这是部分去重，不是全局去重下推。

销售额语句 YIELD 了 `amount`，`isSimpleCase` 的 YIELD 检查失败，**补丁不生效**。那条语句的时间过滤本来就会进 `GetNeighbors`。补丁解决不了「按 `sum(amount)` 排序」。

### 3.2 改动点

| 位置 | 做什么 |
|------|--------|
| `src/interface/storage.thrift` `GetDstBySrcRequest` | 增加 `5: optional binary filter` |
| `GetDstBySrcProcessor::buildEdgeFilter` | 解码表达式。**不**调用 `checkExp`：`checkExp` 会把被引用的属性塞进 `propContexts_`，而 `GetDstBySrcNode::setCurrentEdgeInfo` 用 `DCHECK` 要求这个列表只有 `_dst`。行读取器照样能读到 `ts` |
| `validateEdgeFilter` / `validateEdgeRef` | 只允许边键和边属性；边名必须出现在本次请求的 `indexMap_`（正向或负向 type）里；属性必须在 schema 上。否则 `E_INVALID_FILTER` / `E_EDGE_NOT_FOUND` / `E_EDGE_PROP_NOT_FOUND`，查询失败，不会当成「不过滤」 |
| `GetDstBySrcNode::passEdgeFilter` | `toBool()` 不是 true 就丢边，和 `FilterNode::checkTagAndEdge` 一样。NULL 比较是 false。AND/OR 的三值逻辑在 `LogicalExpression::eval` |
| `iterateEdges` | `limit_` 只数**回传**的边，和 `GetNeighborsNode` 一样。被过滤掉的边不占用 `FLAGS_max_edge_returned_per_vertex`，否则 rank 序靠前的过期边会把窗口内的边截掉 |
| 有 filter 时 `maySkipDecode = false` | `StorageExpressionContext::getEdgeProp` 在 `reader_ == nullptr` 时不读 key 里的 rank，直接去 `edgeFilters_`。所以即使用 `buy._rank` 过滤，这一版也要解码 value。rank 当时间并不能少读 value，见第 4 节 |
| `DstOnlyEdgeFilter::canPush` | graphd 侧同一套叶子判断。单测 `dst_only_edge_filter_test` |
| `GoValidator::isSimpleCase` | flag 开、1 步、谓词可下推时，不再因为 WHERE 返回 false。`buildColumns` 会把 filter 改写成列引用，所以在那之前把边属性形式 clone 到 `GoContext::dstOnlyFilter` |
| `GoPlanner::doSimplePlan` | 把 `dstOnlyFilter` 设到那一个 `Expand` 上 |
| `ExpandExecutor::GetDstBySrc` | 把 `expand_->filter()` 交给 `StorageClient::getDstBySrc` |
| `--enable_dst_only_edge_filter` | 默认 **false** |

### 3.3 正确性与兼容

- **多边类型。** `OVER buy, follow WHERE buy.ts > t` 时，`follow` 边上 `getEdgeProp("buy", "ts")` 因为边名不符返回 `kEmpty`，比较失败，边被丢掉。`GetNeighbors` 的 filter 也是这个语义，不是新行为。场景二只有 `buy`。
- **变步。** `M TO N` 即使 flag 打开也不走这条路径。中间跳若过滤，简单计划的 `getDstBySrc` 没有「只在最后一跳过滤」的分支，会改可达性。
- **滚动升级。** 字段 5 是 optional。旧 storaged 若忽略未知字段，会返回**未过滤**的 dst，而 graphd 的简单计划不再自己滤一遍（它手里没有 `ts`）。因此 flag 默认关闭，三份 conf 里也是注释掉的 false。全部 storaged 升级后再开。
- **关 flag。** `isSimpleCase` 与改前相同：有 WHERE 就走 `GetNeighbors`。一步边过滤仍由现有的 `PushFilterDownExpandAllRule` 下推。
- **去重语义。** `getDstBySrc` 的 host 内去重本来就不保留同一 dst 的重复行。简单计划本来就要求 DISTINCT，并在 graphd 再 `Dedup` 一次。不写 DISTINCT 的语句进不了这条路径，重复购买仍按边返回。

### 3.4 销售额：storaged 上能做的部分和，以及为什么这次没写进补丁

`sum` 对用户可结合。一个 host 可以把窗口内的购买收成 `(user, partial_sum)`，graphd 按 user 再加一次，然后才能 `ORDER BY` / `LIMIT`。不能在 host 上先取 Top 100 再合并：没进这 100 的用户，加上别的 host 的金额后可能才是全局前 100。

要做部分和，得改 `GetNeighborsResponse` 的按顶点嵌套格式，或者新加一个按 dst 聚合的 RPC。`stat_props` 的形状是「每个 src 顶点一个标量」，对不上「每个 dst 一个 sum」。这次没有改响应格式。销售额排序的字节仍然是「每条命中边带回 `amount`」。

---

## 4. 建模和补丁比

内核补丁减的是「DISTINCT 用户」这条语句的回传宽度，不减商品 VID 的前缀扫描次数，也不减销售额语句的行数。下面四条建模都能少扫或不扫「每个美妆商品的全部购买边」。

| 做法 | 查询变成什么 | 相对补丁 |
|------|----------------|----------|
| 边上冗余 `item_type`，复合索引 `(item_type, ts)`，金额也在边上 | `LOOKUP ON buy WHERE buy.item_type == "beauty" AND buy.ts > t YIELD src(edge) AS uid, buy.amount AS amt`。`LookupPlanner` 对边是 `EdgeIndexFullScan`，优化器把前两列收成范围扫描。一次索引扫描取代「索引找商品 + 每个商品扫边」 | 销售额和去重都走这条。写入时要维护索引，边变宽。这是场景二里收益最大的一档，补丁替代不了它 |
| 只在边上建 `ts` 索引 | 扫的是近 3 个月的**全部**购买，再在 graphd 或索引过滤里丢掉非美妆。美妆占比低时，候选集比「先按类目」更大 | 不如复合索引。补丁也不做这件事 |
| 类目中间点 `beauty -[has]-> item`，再 2 步到用户 | 多一跳 GetNeighbors。类目点的出边是热点，见 [09](09-write-read-chain.md) 的超级顶点 | 通常更差，除非再物化 `beauty -[bought_by {ts, amount}]-> user` 并在写入时维护。那是 ETL，不是优化器 |
| `rank` 存购买时间 | 边 key 的 rank 是符号位翻转后的大端，同类型下按 rank 有序，见 [06](06-key-encoding.md)。范围迭代可以不碰更老的 rank。**当前** `SingleEdgeNode` 只用 `(part, vid, type)` 前缀，没有 rank 上下界。`getEdgeProp` 在没有 reader 时也不读 key 里的 rank。所以只把时间塞进 rank、过滤写成 `buy._rank > t`，这一版补丁仍会解码每一条边的 value，只是谓词能走 `getDstBySrc`。要少读盘，还得给 `GetDstBySrc` / `GetNeighbors` 加 key 范围，本次没做 | 和补丁正交。`rank(edge)` 这种函数形式 `DstOnlyEdgeFilter` 拒绝（参数是整条 `Edge`），要写 `buy._rank` |

结论：只要结果里有 `sum(amount)` 或用户属性，优先把类目和时间放进购买边的复合索引。补丁只在「只要去重后的用户 VID」且集群已整体升级时打开。

---

## 5. 补丁怎么打

在 `v3.8.0` 的源码树上：

```bash
git apply --check code-learn/nebula/patches/v3.8.0-dst-only-edge-filter.patch
git apply code-learn/nebula/patches/v3.8.0-dst-only-edge-filter.patch
```

`storage.thrift` 变了，要重新生成 `storage_types`。打开开关：

```text
--enable_optimizer=true
--enable_dst_only_edge_filter=true
```

单测源文件是 `src/graph/optimizer/test/DstOnlyEdgeFilterTest.cpp`，目标名 `dst_only_edge_filter_test`。它只覆盖「谓词能不能走这条 RPC」。storage 端的过滤和去重没有在本次环境里跑过，见 [12](12-scenario2-bench.md)。
