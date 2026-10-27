# NebulaGraph 源码分析

> 对照仓库：<https://github.com/vesoft-inc/nebula>
> master `426266b5c3df856d27f747b55b916dec542b7b59`（2026-09-08）
> tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`（2024-05-17）
> 分支 `release-3.8` `15fc0b7a12ba69b3977c6f4a9d70d15ec7f98742`（2025-03-19）
> `v3.6.0` 只用于核对「3.8 才出现」的说法。

三条线：01–05 是算子下推，06–09 是数据格式，13–14 是控制流和数据流。下推系列里 `v3.8.0` 与 `release-3.8` 在 `src/graph/optimizer`、`src/graph/planner`、`src/graph/executor`、`src/storage/query` 上没有差异。编码系列以 master 与 `v3.8.0` 的 diff 为准：key 与标量索引编码相同，LIST / SET 行格式只在 master。13–14 对照的是 `v3.8.0` 与 master `426266b5`：调度器、`GoPlanner`、`RelNode` 无差异。

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
| 10 | [下推能力总表](10-pushdown-capability.md) | Filter、投影、索引、Limit、TopN、Aggregate 在 GO / MATCH / LOOKUP / FETCH / 最短路上各自停在哪一层 |
| 11 | [场景二：美妆购买用户](11-scenario2-beauty-buyers.md) | 类目索引 → 反向购买边 → 边时间过滤 → 用户去重，以及销售额排序；和用户拆解的出入；`getDstBySrc` 补丁与建模对比 |
| 12 | [场景二压测](12-scenario2-bench.md) | 单机实测：flag 关 / flag 开 / 购买边复合索引，P50/P95/P99、QPS、PROFILE 行数；多节点复现步骤 |
| 13 | [控制流](13-control-flow.md) | 请求入口与会话、future 调度、执行模型（物化 / Volcano / 向量化）、`Select`/`Loop`/`PassThrough`、GO 与 MATCH 的计划 |
| 14 | [数据流](14-data-flow.md) | `ExecutionContext` / `Result` / `Iterator`、拷贝与释放、graphd→storaged 的 RPC 合并、GO 与 MATCH 的行、写路径到 Raft |
| 15 | [边上的可下推框架](15-general-pushdown.md) | 表达式判定、合取拆分、部分聚合、TopN 的分区前提、滚动升级；和现有 Filter / Aggregate / GetDstBySrc 怎么接 |
| 16 | [部分聚合实现与测试](16-partial-agg-impl.md) | 第二份补丁、null/多边/回退、美妆 q_sales 重测、q_model DISTINCT、graphd worker |
| 17 | [多节点压测](17-distributed-bench.md) | 3 meta + 3 storage + 1 graph、实测 RTT、RF=1/3、分区数、leader、杀进程 |
| 20 | [中间表示](20-intermediate-representation.md) | 场景二三条查询的算子输出：`Value` / `DataSet` 列布局、Thrift 字节、glibc 堆；和水位、下推的关系 |
| 21 | [中间表示方案](21-ir-optimization-design.md) | 按收益和风险分的通用改法：P0 不改对外协议，P1 改 storage 可选字段，P2 改调度；含 v3.8.0 上的 PoC patch |
| 22 | [中间表示收益实测](22-ir-bench.md) | 同一棵 `fa928930` 上原版对 P0：P50/P95/P99、QPS、RSS、水位；P1/P2 只给估算 |
| 23 | [下推 patch 验证报告](23-patch-verification.md) | `v3.8.0` 上两份下推 patch 与 poc-repr 的 apply / 编译 / gtest / ctest 结果，修掉的三个缺陷，以及 storage 专项测试 |

下推阅读顺序是 01 → 02 → 03 → 04 → 05，然后 10。11 是场景二，12 是它的压测记录。05 的更正表是对早期笔记的集中修订，结论都以前面几篇的源码锚点为准。

编码阅读顺序是 06 → 07 → 08 → 09。09 把前三篇接到一条写入读出链上。04 只讲 filter / limit 怎么进 storaged，不讲 key 和行格式。

控制流和数据流是 13 → 14。13 回答「算子按什么模型被拉动」，14 回答「行放在哪个变量里」。01 的优化器、04 的 `FilterNode`、09 的编码在这两篇里只引用，不重复。

15 是下推框架。16 是它在 `v3.8.0` 上的实现和单机重测。17 是同一台 VM 上的多进程集群，RTT 来自 ping，不是 `tc netem`（这个内核没编进 `sch_netem`）。

[20](20-intermediate-representation.md) 接在 11–14 后面：用场景二的 40415 条边、382 个商品、4000 个用户，写每个算子吐出的 `DataSet` 和 Thrift 字节。12 有时延和行数，没有这组字节。[21](21-ir-optimization-design.md) 把这些字节收成 graphd、storaged 和两边协议的分阶段改法。写 21 时 origin/main 上还没有 15–19，下推重叠以 [10](10-pushdown-capability.md) 为准。15–17 是后来补上的下推实现，不改 20/21 里的字节计数。[22](22-ir-bench.md) 是 P0 补丁在场景二上的时延实测，二进制不含 16 的部分聚合补丁。[23](23-patch-verification.md) 不是分析章节，是 15/16/21 三组 patch 的验证记录：pristine `v3.8.0` 上的 apply、aarch64 编译配方、gtest/ctest 结果，以及仍未覆盖的边界。

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
        AsyncMsgNotifyBasedScheduler 按依赖 future 启动
        StorageClient::{getNeighbors,scanVertex,scanEdge,getProps}
  → storaged
        QueryBaseProcessor::buildFilter / checkExp
        FilterNode 或 Scan*PropNode
```

调度、`Expand` / `ExpandAll` 与 `Traverse` 的差别、变量和 `Iterator` 见 [13](13-control-flow.md)、[14](14-data-flow.md)。

发行配置 `conf/nebula-graphd.conf.default` 打开 `--enable_optimizer=true`。`GraphFlags.cpp` 里该 flag 的默认值是 false。Filter / Limit 规则都注册在 `QueryRules`，关开关时不会跑。

---

## 和早期笔记相比，先记住的三件事

1. 普通 `GO ... WHERE` 下推到 `ExpandAll.filter`，不是 `PushFilterDownGetNbrsRule` 所匹配的 `GetNeighbors`。变步不下推。
2. `FIND SHORTEST PATH ... | LIMIT n` 在 offset 为 0 时由解析器折进语句，再由 `PathPlanner::setLimit` 写到最短路算子。这是 3.6.0 没有、3.8.0 已有的行为。它不是一条 `PushLimit` 规则。
3. 笔记中的 `-1005: scan vertices or edges need to specify a limit number...` 不在上述社区源码里。`-1005` 是 `E_EXECUTION_ERROR`。
4. 一步 `GO ... WHERE 边属性` 在 `--enable_optimizer=true` 时已经进 `GetNeighbors` 的 filter。它减的是回传边的行数，不减「每个商品 VID 一次 RPC」——`StorageClient` 按 host 把 VID 拼成一次请求。`YIELD DISTINCT 边._dst` 原本因为有 WHERE 而不能走 `getDstBySrc`。见 [11](11-scenario2-beauty-buyers.md)。
