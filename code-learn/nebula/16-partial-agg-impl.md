# 16 — 部分聚合：实现、边界和美妆重测

> 设计在 [15](15-general-pushdown.md)。多节点数字在 [17](17-distributed-bench.md)。
> 补丁叠放：先 [`v3.8.0-dst-only-edge-filter.patch`](patches/v3.8.0-dst-only-edge-filter.patch)，再 [`v3.8.0-partial-edge-agg.patch`](patches/v3.8.0-partial-edge-agg.patch)。两份都 `patch -p1` 打在 `v3.8.0` `fa92893` 上，第二份在本机干净树上复打通过。
> 单机二进制是这份源码的 Release 构建。graphd conf 末尾是 `--enable_dst_only_edge_filter=true`、`--enable_partial_edge_agg=true`、`--num_worker_threads=4`。
> 原始结果在 [`bench/scenario2/results/`](bench/scenario2/results/)。
> 日期：2026-10-26。

这一份只做 [15](15-general-pushdown.md) 里风险能看住的那一截：一步扫描、整句谓词可下推、分组键展开后是具名边的 `_dst`、聚合是 `SUM` / `COUNT` / `MIN` / `MAX`。`AVG`、`now()`、按 `amount` 分组、多步 GO、MATCH 的 `Traverse` 都不改计划。

---

## 1. 代码落在哪

| 文件 | 作用 |
|------|------|
| `src/graph/util/EdgePushdown.h` | `canPush`、`splitAnd`。`DstOnlyEdgeFilter::canPush` 改成调用它 |
| `src/common/function/PartialAgg.h` | `applyPartial` / `mergePartial`。`COUNT` 的合并是相加 |
| `src/graph/optimizer/rule/PushPartialEdgeAggRule.*` | 匹配 `Aggregate`，改写成带 `partialAgg` 的 `Expand`，上面留合并用的 `Aggregate` |
| `src/interface/storage.thrift` | `GetDstBySrcRequest.aggs`，`GetDstBySrcResponse.partial_agg` |
| `src/storage/exec/GetDstBySrcNode.h` | 过滤后的边按 dst 做部分状态 |
| `src/storage/query/GetDstBySrcProcessor.*` | host 内多个 part 再合并，成功时把 `partial_agg` 置 true |
| `src/graph/executor/query/ExpandExecutor.cpp` | 任一台没置位就丢掉这批 VID，用同一批源 VID 再 `getNeighbors`，在 graphd 上做成同样的部分行 |

`Value` 的默认状态是 `__EMPTY__`，不是 `NULL`。`partialUninitialized()` 把 `empty()` 和 `isNull()` 同等看待。漏掉这一点时，`state + val` 会停在 `__EMPTY__`，`SUM` / `COUNT` / `MIN` 在有边的情况下也是 0 或 NULL。

直接 `GO FROM <vids>` 时，`Expand.inputVar` 必须是 `PlannerUtil::buildConstantInput` 放 VID 的那个变量。规则若改写成 `Start` 的空输出，这条语句返回 0 行。`LOOKUP | GO` 的 `HashInnerJoin` 只在聚合列不再引用左表其它列时拿掉。

TopN 不进 storage。分组键是 dst，边按商品 VID 分 part，本地 TopN 会丢掉「单 host 不在前 N、加总后进前 N」的用户。

---

## 2. 单测和 tck

`src/graph/optimizer/test/DstOnlyEdgeFilterTest.cpp`：

- 边时间比较可下推；`now()` 整句不可下推
- `splitAnd` 把 `amount > 0 AND ts > now()` 拆成可下推的 `amount` 和留下的 `ts`
- `OR` 整段留下；`*`、`$^`、`$$`、整条边函数拒绝
- `SUM` 跳过 NULL / empty，跨 part 相加；全是 NULL 收成 0；非数值之后不再累加
- `COUNT` 跳过 NULL，两个部分计数相加
- `MIN` / `MAX` 忽略 NULL 部分状态

`tests/tck/features/go/PartialEdgeAgg.feature` 有两条：按 dst 的 `SUM`+`COUNT`（NULL amount 不计），以及过滤后没有边时不产生分组。这次没有跑 tck 运行器。

gtest 目标名是 `dst_only_edge_filter_test`。结果在第 7 节。

---

## 3. 小图：`edge_cases`

`bench/scenario2/correctness.py`，空间 `edge_cases`，3 个 part。结果 [`results/edge_cases.json`](bench/scenario2/results/edge_cases.json)。10 条都是 `ok: true`。

| 用例 | 部分聚合在计划里 | 结果 |
|------|------------------|------|
| `reverse_sum_count_null` | 是 | 两个用户，NULL amount 没进 SUM，COUNT 少 1 |
| `reverse_min_max` | 是 | MIN=MAX=5 |
| `empty_filter` | 是 | 0 行 |
| `no_filter_sum` | 是 | 3 个用户 |
| `forward_sum` | 是 | 正向边 |
| `bidirect_matches_reverse` | 是 | 正反两个方向都进和，和未下推的两边扫描一致 |
| `second_edge_type` | 是 | 第二条边类型单独成组 |
| `group_by_amount_not_pushed` | 否 | 按 amount 分组，留在 `ExpandAll` |
| `avg_not_pushed` | 否 | `AVG` 不匹配规则 |
| `now_not_pushed` | 否 | `now()` 不可下推，0 行是过滤结果，不是聚合被丢掉 |

这张图没有单独造一个大度点，也没有把某个 part 的 RPC 弄失败。50 万边的扫描在第 4 节。杀掉一台 storaged 的记录在 [17](17-distributed-bench.md)。

---

## 4. 美妆单机重测

数据和 [12](12-scenario2-bench.md) 相同：500000 条 `buy`，命中窗口的边 40415，用户 4000，`sum(amount)=10073144`。用户集合 sha256 `ca7e464a7a501db98ca99fba8b12cb48f56e2b37f666450e05012923a1f0a2b8`。机器 4 vCPU。结果 [`results/partial_w4.json`](bench/scenario2/results/partial_w4.json)。四条查询 `ok: true`。

计划（PROFILE）：

| 查询 | 计划 | storage 行 |
|------|------|------------|
| q_users | `Expand`，`GetDstBySrc`，没有 `partialAgg` | `vertices: 4000` |
| q_sales | `TopN → Aggregate → Expand(partialAgg=["SUM(buy.amount)"])`，`partial_agg_applied: 1` | `vertices: 4000` |
| q_count | `Expand(partialAgg=["COUNT(buy.amount)"])`，`partial_agg_applied: 1` | `vertices: 4000`，各组 COUNT 之和 40415 |
| q_by_amount | 仍是 `ExpandAll` + `GetNeighborsNode`，规则不匹配 | 分组 500，COUNT 之和 40415 |

q_sales 的全量聚合 4000 组，`sum_got = sum_expect = 10073144`。Top 100 的第一行是 `(uid=97, sales=6669.0)`。

server 时延是 `ResultSet.latency()`，单位毫秒。和 [12](12-scenario2-bench.md) 的 4 worker 表比。12 的 q_sales 两条计划都是 `ExpandAll`，flag 开没有收益。

### q_sales

| | c=1 P50 | c=1 QPS | c=10 P50 | c=10 QPS | c=200 P50 | c=200 QPS |
|--|---------|---------|----------|----------|-----------|-----------|
| 12，flag 关 | 45.92 | 21.12 | 180.12 | 53.17 | 3502.18 | 51.53 |
| 12，flag 开（仍是 ExpandAll） | 48.12 | 19.20 | 179.63 | 52.52 | 3702.95 | 50.72 |
| 这次，部分聚合，4 worker | 16.433 | 55.62 | 90.496 | 95.69 | 1801.447 | 102.06 |

并发 1 的 P50 是 12 里 flag 关的 16.433/45.92 = 0.358。并发 200 的 QPS 从大约 52 到 102。P99 仍随并发涨：这次 c=200 的 server P99 是 2176 ms。缩短的是单次扫描回传的行（40415 条边收成 4000 个部分和），不是排队本身。

### q_users

同一条 dst-only 计划。这次 c=1 server P50 12.031，QPS 31.85。12 的 flag 开是 13.69 ms。c=200 QPS 38.35，和 12 里大约 40 的平台同一量级。部分聚合规则不匹配这句，没有新的收益。

### 另外两句

| 查询 | c=1 P50 | c=1 QPS | c=200 P50 | c=200 QPS |
|------|---------|---------|-----------|-----------|
| q_count（部分 COUNT） | 17.389 | 24.45 | 20.227 | 26.83 |
| q_by_amount（不下推） | 41.383 | 22.24 | 2111.477 | 55.65 |

q_by_amount 的 c=1 P50 和 12 里未下推的 q_sales（45.92）同一档，用来确认规则没有把「分组键不是 dst」也改掉。

---

## 5. 旧 storaged：回退，不把 VID 当和

单机集群里 graphd 仍是带 `aggs` 的新二进制，storaged 换成上一份补丁的 `/tmp/nebula-storaged-dstonly`（认识 filter，不认识 `aggs`，响应里没有 `partial_agg`）。

q_sales 全量聚合：`ok`，4000 行，`sum=10073144.0`，server 52945 µs。PROFILE：`partial_agg_applied: 0`。同一次会话里第二次 PROFILE（40205 µs）同时有：

- `step1 resp [0]`：`GetDstBySrcProcessorTotal`，`vertices: 4000`
- `resp[0]`：`GetNeighborsNode` 32564 µs，`FilterNode` 2037 µs

第一跳被丢掉，第二跳在 graphd 上重算。和是对的。代价是多一次 RPC，这次比部分聚合生效时的大约 17 ms 慢。

---

## 6. q_model 加 DISTINCT，以及 worker 数

复合索引那句原来返回 40415 条边。加上 `DISTINCT` 之后用户集合与 q_users 的 sha256 相同（`ca7e464a…`），4000 人。结果 [`q_model_distinct_w4.json`](bench/scenario2/results/q_model_distinct_w4.json)、[`workers16.json`](bench/scenario2/results/workers16.json)、[`workers32.json`](bench/scenario2/results/workers32.json)。

worker 16/32 的 q_sales 仍是未下推的 `ExpandAll`（c=1 P50 47.72 和 49.05，和 12 的 45–48 ms 同一档）。那两次在部分聚合之前。

| | graphd workers | c=1 server P50 | c=1 client P50 | c=1 QPS | c=200 QPS |
|--|----------------|----------------|----------------|---------|-----------|
| q_model，12，40415 行 | 4 | 79.68 | 284.03 | 3.43 | 约 4 |
| q_model DISTINCT | 4 | 85.18 | 107.1 | 9.48 | 17.62 |
| q_model DISTINCT | 16 | 71.98 | 88.9 | 10.81 | 17.76 |
| q_model DISTINCT | 32 | 71.15 | 87.9 | 10.09 | 18.07 |
| q_sales，未下推 | 16 | 47.72 | 48.7 | 20.25 | 52.04 |
| q_sales，未下推 | 32 | 49.05 | 50.5 | 20.15 | 51.50 |
| q_sales，部分聚合 | 4 | 16.433 | （与 server 接近，结果只有 100 行） | 55.62 | 102.06 |

DISTINCT 把客户端要解码的行从 40415 降到 4000，client P50 从 284 ms 降到 107 ms。server P50 仍在 70–85 ms：索引扫描还是那些边，去重在 graphd。worker 加到 16 或 32 没有把未下推 q_sales 的 c=200 QPS 拉过 52，这台机器是 4 个 vCPU。部分聚合在 4 个 worker 上把同一句的 c=200 QPS 做到 102，靠的是少回传，不是多线程。

---

## 7. gtest

`make -j3 dst_only_edge_filter_test` 在 `/tmp/nebula-380/build` 里结束，`BUILD_EXIT:0`。然后：

```text
[==========] 15 tests from 2 test suites ran. (0 ms total)
[  PASSED  ] 15 tests.
```

15 条是第 2 节列的谓词判定、`splitAnd` 和 `SUM` / `COUNT` / `MIN` / `MAX`。编译有 `-Woverloaded-virtual`（`EdgePushdownVisitor` 盖住了基类的 `visit`），没有当成错误。

tck 运行器没有执行 `PartialEdgeAgg.feature`。没有单测覆盖「一个 part 的 RPC 失败」。那条在 [17](17-distributed-bench.md)：默认 `accept_partial_success=false`，缺 part 时整句失败。
