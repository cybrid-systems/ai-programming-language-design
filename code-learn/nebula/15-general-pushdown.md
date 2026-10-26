# 15 — 边上的可下推框架：表达式、部分聚合、TopN

> 接着 [10](10-pushdown-capability.md)、[11](11-scenario2-beauty-buyers.md)。
> 源码基线是 `v3.8.0` `fa92893`，上面先有 [`v3.8.0-dst-only-edge-filter.patch`](patches/v3.8.0-dst-only-edge-filter.patch)，再叠 [`v3.8.0-partial-edge-agg.patch`](patches/v3.8.0-partial-edge-agg.patch)。
> 实现和测试记录在 [16](16-partial-agg-impl.md)。多进程加 `tc netem` 的数在 [17](17-distributed-bench.md)。
> 分析日期：2026-10-26。

上一份补丁只认一句：一步 `GO`、谓词只碰这条边、`YIELD DISTINCT 边._dst`。销售额排序不走它。这篇把判定从那一句里抽出来，说明哪些能进 storaged、哪些必须留在 graphd，以及和现有规则怎么接，而不是再为美妆写一个计划节点。

---

## 1. 不新造一条执行链

| 已有机制 | 它实际做的事 | 这份框架怎么用 |
|----------|--------------|----------------|
| `PushFilterDown*Rule`，尤其 `PushFilterDownExpandAllRule` | 把 graphd `Filter` 拆开，边谓词写进 `ExpandAll.filter`，再由 `getNeighbors` 带走 | 部分聚合的规则要求过滤已经进 `ExpandAll.filter`，或者还留在紧挨着的 `Filter` 上。判定函数和这条规则用的是同一类「边表达式」 |
| `PushEFilterDownRule` | MATCH 的边过滤进 `Traverse` | 判定函数可以复用。本阶段**不**改 `TraverseExecutor`。MATCH 仍走原来的 `eFilter` |
| `PushFilterDownAggregateRule` | 把不含聚合函数的 `Filter` 挪到 `Aggregate` 下面。两边都在 graphd | 不碰。它不下推聚合本身 |
| `AggregateNode` / `StatProp` | `storage.thrift` 写明是 **每个源点** 的邻居统计。`GetNeighbors` 行布局是 `vid \| stats \| tags \| edges \| exprs` | **不**把它当成 `GROUP BY dst`。改这行列会破坏现有客户端。按用户求和另走 `getDstBySrc` 的可选字段 |
| `GetDstBySrc` | 只回 dst，host 内去重 | 过滤字段（上一份补丁）和部分聚合字段（这一份）都加在这个请求上。响应多一个 `partial_agg` |
| `TopNRule` / `PushTopNDownIndexScanRule` | 前者只在 graphd 把 `Sort+Limit` 收成 `TopN`；后者只匹配索引扫描 | 分组键不是 part 键时，TopN 留在最终合并之后 |

`PlanNode::cost_` 仍恒为 0。规则靠形状匹配，不靠代价比较。`--enable_optimizer` 关着时 `QueryRules` 不跑，两条新开关都不起作用。

---

## 2. 什么样的表达式可以进 storaged

实现在 `src/graph/util/EdgePushdown.h` 的 `EdgePushdown::canPush`。`DstOnlyEdgeFilter::canPush` 现在直接调用它，不再单独维护一套 visitor。

允许：

- 常量
- 算术、比较、逻辑、类型转换、一元 `+`/`-`/`NOT`、`IS NULL` 一类
- list / set / map 的元素，只要元素本身可下推
- 具名边的属性、`_src`、`_dst`、`_type`、`_rank`（符号不是 `*`，也不是空）
- **纯函数**。`FunctionManager::getIsPure(name, arity)` 为真才递归参数。`now()`、无参 `timestamp()` 为假，拒绝

拒绝：

- tag、`$^`、`$$`、输入列、变量、整条 `Edge` / `Vertex`
- 聚合、`CASE`、谓词表达式、下标、属性访问、label
- 自增自减
- `getIsPure` 查不到的函数（含未加载的 UDF）

空值和类型：

- 过滤：`toBool()` 不是 true 就丢边，和 `FilterNode::checkTagAndEdge` 一致。NULL 比较得到 NULL，边被丢掉。
- `SUM` / `COUNT`：和 `AggFunctionManager` 一样，状态从 NULL 收成 0，然后跳过 NULL 和 empty；非数值 `SUM` 变成 bad null，之后不再累加。
- `MIN` / `MAX`：跳过 NULL 和 empty，状态保持 NULL 直到第一个可比较的值。
- `COUNT(*)` 在计划里是常量 `"*"`。常量非空，每条通过过滤的边加 1。这和 graphd 对 `COUNT(常量)` 的计数一致，也和「跳过 NULL 属性」的 `COUNT(buy.amount)` 不同。

`now()` 的拒绝是相对上一份补丁的行为变化。上一份 visitor 会让 `buy.ts > now()` 整句下推，每台 storaged 各调一次 `now()`。时钟接近时结果差不多，但不是同一常量。要下推，先在 graphd 把 `now()` 折成字面量。美妆压测用的就是字面量 `1753660800`。

---

## 3. 合取拆开，剩余留在 graphd

`EdgePushdown::splitAnd` 只沿 `LogicalAnd` 拆。`OR` / `XOR` 整段要么可下推，要么整段留下。

拆完之后谁消费：

| 调用方 | 能留下剩余谓词的条件 |
|--------|----------------------|
| `YIELD DISTINCT 边._dst` 的 `getDstBySrc` | 不能。响应没有边属性，剩余谓词无法在 graphd 再算。`DstOnlyEdgeFilter` 仍要求整句 `canPush` |
| 部分聚合 | 本阶段同样要求整句可下推。剩余若还要读 `amount` 或 tag，扫描已经把行收成 `(dst, 部分和)`，graphd 没有那些列。`splitAnd` 的单测覆盖了「`ts > now()` 留下、`amount > 0` 可下推」，规则本身看到剩余就 **不变换** |
| 以后若扫描仍回剩余谓词要的列 | 可下推的合取进 storage，剩余留在 `Filter`。那是同一函数的下一步，这次没接进计划 |

---

## 4. 投影和去重

`getDstBySrc` 在没有聚合时只投影 `_dst`，host 内去重，graphd `Dedup` 再并 host。这就是上一份补丁。

有部分聚合时，投影是 `_dst` 加每个聚合一列（`_pa0`…）。跨源点、跨 part 的「去重」变成按 dst 合并部分状态，不是 VID 集合。同一个用户在多个 part 上各有一行部分和，graphd 的 `Aggregate` 再加总。不能在 storage 把用户 VID 去重后丢掉 `amount`。

属性裁剪（`PrunePropertiesVisitor`）仍不访问 `Expand` / `ExpandAll`。本阶段的裁剪是规则自己只把聚合参数和 `_dst` 放进 RPC，不靠那次后处理。

---

## 5. 可分解聚合

`src/common/function/PartialAgg.h`：

| 最终运算 | storage 上每条边 | 跨 part / 跨 host 合并 |
|----------|------------------|------------------------|
| `SUM(expr)` | `applyPartial(SUM)` | 部分和相加 |
| `COUNT(expr)` | `applyPartial(COUNT)` | **把部分计数相加**（合并函数是 `SUM`，不是再 `COUNT` 一次） |
| `MIN` / `MAX` | 局部最小 / 最大 | 再取最小 / 最大。一侧是 NULL（该 part 没有可比较值）则忽略 |
| `AVG` | 不单发 | 应拆成 `SUM` + `COUNT`，graphd 再除。除数 0 时结果是 NULL，不是 `0/0`。**本阶段规则直接拒绝 `AVG`** |
| `DISTINCT` 聚合、`COLLECT`、`STD` | 不可分解成常数大小的状态 | 拒绝 |

分组键：

- 本阶段只接受 **恰好一个** 分组键，且沿 `Project` 的别名展开后是具名边的 `_dst`。
- 分组项里的非聚合表达式也必须展开成同一个 `_dst`（`YIELD $-.uid, sum($-.amt)` 这种）。
- 空输入：分组键还在时，graphd `AggregateExecutor` 不会造出一行 0。storage 只为「至少有一条边通过过滤」的 dst 发部分行。全空则 graphd 看到空输入，结果是空，不是一个 NULL 键加 0。
- 全局聚合（没有分组键）可以是「每个 part 一行部分状态，graphd 合成一行」。规则没做。空输入时 graphd 对「全是聚合函数」会造一行默认值（`SUM`/`COUNT` 为 0）。接上之前要和这个默认行对齐。

`GetNeighbors` 的 `stat_props` 仍是每个源点一行。销售按用户聚合不能靠它：一个用户的购买边挂在多个商品 VID 上，源点统计加总的是商品，不是用户。

存储侧扫描在 `GetDstBySrcNode::iterateEdges`。过滤不通过的边不进入聚合，也不占用 `FLAGS_max_edge_returned_per_vertex`（默认 `INT_MAX`）。这个上限和 `GetNeighbors` 一样，是返回边数而不是扫描边数；把它调小会让部分和变短，和未下推的计划截断同一批边。

host 内多个 part 的 map 在 `GetDstBySrcProcessor::mergePartialGroups` 合并。成功时响应 `partial_agg = true`。

---

## 6. TopN 什么时候能在每个 host 做

分组键是用户（边的 dst），边落在 **商品 VID 的 part** 上。同一个用户的购买分散在多个 host。每个 host 的本地 TopN 再合并，会丢掉「单 host 不在前 N、加总后进前 N」的用户。

| 条件 | 能否本地 TopN |
|------|----------------|
| 分组键就是 part 的划分键，每个键只出现在一个 part | 可以。本地 TopN 的并是全局 TopN |
| 分组键是 dst，数据按 src（商品）划分 | **不可以**。先部分聚合，graphd 合并后再 `ORDER BY` / `TopN` |
| 没有分组、只要全局最大的若干原始边 | 每个 part 的 TopN 再合并是对的。`PushTopNDownIndexScanRule` 已经覆盖索引扫描这一支，不在这次的 GO 规则里 |

美妆的 `ORDER BY sales DESC LIMIT 100` 因此留在合并之后。规则匹配的是 `Aggregate`，不改上面的 `TopN`。

---

## 7. 多步 GO 和 MATCH

一步：`Expand` 的 `maxSteps` 为 0（只把 VID 传下去），真正发 RPC 的是 `ExpandAll(min=max=1)`。规则只认这个形状。

多步：中间跳上过滤会改变可达集合。部分聚合若做在中间跳，dst 还要当下一跳的 src，聚合把边收掉之后接不上下一跳。最后一跳可以套用同一判定，但要保证前面的跳不过滤。`TraverseExecutor` 是另一条 RPC。**本阶段两者都不改。** 开关打开时，多步 `GO | GROUP BY` 仍是原来的 `ExpandAll` 计划。

`BOTH`：`edgeProps` 里会有正负两个 type。未下推的 `GetNeighbors` 也会把两个方向都扫进来再求和。下推后同样两个方向都进部分和，不额外加倍。规则没有把「只有一个 type」写成硬条件。`OVER *` 若某条边没有聚合要用的属性，storage 的 `validateEdgeRef` 返回 `E_EDGE_PROP_NOT_FOUND`，查询失败，而不是把缺的属性当 0。

反向：`REVERSELY` 仍是负的 edge type，RPC 方向参数保持 `OUT_EDGE`。和 [11](11-scenario2-beauty-buyers.md) 相同。

---

## 8. 协议、滚动升级、开关

请求仍是 `GraphStorageService.getDstBySrc`，不新增方法，也不改 `GetNeighbors` 的行。

`storage.thrift`：

- `GetDstBySrcRequest.aggs`：可选的 `list<PartialEdgeAgg>`（`op` + `Expression::encode`）
- `GetDstBySrcResponse.partial_agg`：可选 bool，默认不置位

旧 storaged 忽略未知字段，回的是 dst VID，`partial_agg` 不在响应里。graphd `ExpandExecutor::partialAgg` 看到任一台没有把该位置上，就 **丢掉这批 VID**，用同一批源 VID 再发 `getNeighbors`（带原来的 filter 和 `edgeProps`），在 graphd 上按 dst 做成同样的部分行，再交给上面的合并 `Aggregate`。结果与未下推一致，只是少了少传字节的收益，并且多一次 RPC。

不把「dst VID 列表」当成部分和。上一份过滤字段没有这个回应位，旧 storaged 会静默返回未过滤的 dst，所以那个开关要求整集群升级。聚合这条用回应位避免同类错误。

升级顺序：

1. 先升级全部 storaged（旧 graphd 不发 `aggs`，行为不变）。
2. 再升级 graphd。
3. 最后打开 `--enable_partial_edge_agg`。提前打开时，旧 storaged 触发上面的回退，结果仍对。

两个开关都默认 false：

| 开关 | 默认 | 打开后 |
|------|------|--------|
| `--enable_dst_only_edge_filter` | false | 一步、整句可下推、`YIELD DISTINCT 边._dst` 走带 filter 的 `getDstBySrc` |
| `--enable_partial_edge_agg` | false | 下面第 9 节的形状改写成部分聚合。优化器必须开着 |

回退就是关掉对应开关。计划回到 `ExpandAll` + graphd `Aggregate`。

---

## 9. 规则认的形状

`PushPartialEdgeAggRule` 注册在 `QueryRules`，模式是任意 `Aggregate`，`match()` 再往下走。只在 `--enable_partial_edge_agg` 为真时返回 true。

认这两类，中间可以夹若干 `Project` 和一个 `Filter`：

```text
Aggregate
  Project*
    ExpandAll(1,1)          -- 直接 GO FROM <vids>
      Expand(maxSteps=0)
        <vid 输入>

Aggregate
  Project*
    HashInnerJoin           -- LOOKUP | GO。probe 键是 _expand_vid
      <左：vid 来源>
      ExpandAll(1,1)
```

变换后：

```text
Aggregate          -- 分组键 _dst；SUM 合并 SUM，COUNT 合并 SUM，MIN/MAX 再取最值
  Expand           -- maxSteps=1，partialAgg 列在 EXPLAIN 里
    <原来的 vid 输入；若 hash 键不是左表第 0 列，先 Project 出那一列>
```

`HashInnerJoin` 可以拿掉，是因为 `GO FROM $-.id` 的扫描输入已经是左表的 VID，内连接不再丢行（没有边的 VID 本来也不会产生分组）。分组键或聚合参数若还引用左表的其它列（例如商品名），规则不匹配，连接留着。

管道 `LOOKUP | GO | GROUP BY | ORDER BY | LIMIT` 在过滤被 `PushFilterDownExpandAllRule` 写进 `ExpandAll.filter` 之后，下一轮才能匹配。规则列表里部分聚合写在过滤规则后面，探索又是自底向上，同一轮里过滤先落进 `ExpandAll`。

不匹配时计划与打开开关之前相同。`AVG`、多步、`DISTINCT` 聚合、分组键不是 `_dst`、谓词含 `now()` 或 tag，都走这条退路。

---

## 10. 和美妆两句的关系

| 查询 | 开关 | 计划 |
|------|------|------|
| `YIELD DISTINCT buy._dst`，`buy.ts > 字面量` | 只需 `enable_dst_only_edge_filter` | 仍是上一份补丁的 `getDstBySrc` + filter。部分聚合规则不匹配（没有 `Aggregate`） |
| `YIELD uid, sum(amount) \| GROUP BY uid \| ORDER BY \| LIMIT` | `enable_partial_edge_agg` | 应变成「部分和 Expand + 合并 Aggregate + 原来的 TopN」 |
| 同上，但 `WHERE buy.ts > now()` | 两个都开 | `now()` 不可下推，规则不匹配，销售额仍走 `GetNeighbors` |
| `GROUP BY amount` 或按商品属性分组 | 部分聚合开着也不匹配 | 分组键展开后不是 `_dst` |

同一用户散在多个商品 part 上时，每个 host 的部分和都要加。`replica_factor=3` 时 RPC 仍只打 leader，同一条边不会因为三副本加三次。leader 切换后，新 leader 扫到的是同一 part 的数据，部分和的键仍是 dst，合并方式不变。某个 part 失败且 `accept_partial_success=false`（默认）时，`handleCompleteness` 让整句失败，不返回缺了一部分用户的和。

这些句子的实测在 [16](16-partial-agg-impl.md) 和 [17](17-distributed-bench.md)。
