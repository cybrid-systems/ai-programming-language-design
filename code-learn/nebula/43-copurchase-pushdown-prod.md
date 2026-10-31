# 43 — 共同购买下推 v2：剪枝和上线约束

> 基线是 [42](42-copurchase-pushdown.md) 的 `6e995d0`。补丁 [`patches/v3.8.0-copurchase-pushdown-v2.patch`](patches/v3.8.0-copurchase-pushdown-v2.patch) 打在那棵树上。
> 日期：2026-10-31。时延、QPS、ping、重叠率、剪枝人数、扫描行数、RSS、jiffies 都是测到的。P999 是最近秩，n≤100 时它就是样本最大值。

v2 不改排序定义，也不改「一个人的共同购买次数只在他自己的 part 上算完」这件事。多出来的是：hop2a 交回每个买家买了哪几个焦点商品，graphd 在发 hop2b 之前丢掉不可能进 top15 的人。结果必须和没剪的那条一样。

---

## 1. 语句

触发不是优化器改写 GO。`QueryInstance::execute` 只在查询去掉空白后以 `COPURCHASE` 开头、并且 `--enable_copurchase=true` 时进入 `CopurchaseDriver`。其它语句仍走 `GQLParser`。没有一条 OptRule 会把 `GO` / `FETCH` 收成这个算子。

语法，多出来的词每个最多一次，次序不限：

```
COPURCHASE FROM <int64> WINDOW <start>, <end> [NAIVE] [NOPRUNE]
```

- 窗是闭区间，rank 等于端点算在内。
- `NAIVE` 是 42 篇的按 host 部分计数，不是这条精确路径。
- `NOPRUNE` 关掉剪枝，用来和 v1 比。默认剪。
- 多一个词、少 `WINDOW`、逗号不是逗号，都是 `SyntaxError: COPURCHASE`，不执行。
- `--copurchase_spaces` 非空且当前 space 不在名单里：返回 `copurchase disabled for space ...`，不执行。同一会话里的 `GO` 不受影响。

单机 tck（`bench/copurchase/run_tck.py`）里，精确、`NOPRUNE`、朴素、四句 nGQL 都是同一组 9 个商品。`GO FROM 1 OVER buy YIELD buy._dst` 返回 10..15，不进 driver。`COPURCHASE FROM 1` 是语法错。`--copurchase_spaces=not_this_space` 时 COPURCHASE 报 disabled，同一条 GO 仍是 6 行。

---

## 2. 剪枝为什么仍然精确

焦点商品各在一个 part 上。入边只写在商品那边。hop2a（`HOP2A_BUYERS`）在每个商品的入边上做窗内 range，按买家记下本机看到的焦点商品 id。`CopurchaseProcessor` 把这些 id 放进 `CopurchaseUserRow.product_ids`，同时仍填 `ids`，旧 graphd 只读 `ids` 也能用。

graphd 等这一轮全部 host 成功返回之后，把同一个买家的 `product_ids` 并起来。并集的大小就是窗内买过的焦点商品数，也就是 `coCount`。没报上来的焦点商品是 0 个，所以上界等于下界。

`pruneCandidates`（`src/common/algorithm/Copurchase.h`）：

- `lower`：已经确认的 `coCount`。
- `upper`：`lower` 加上还没回报的焦点商品数。全部回报之后 `upper == lower`。
- `threshold`：至少有 k 个买家时，第 k 高的 `lower`（k = 15）。不足 k 个人时阈值是最小的 `lower`，一个人都不丢。
- 丢掉 `upper < threshold` 的人。

证明：`coCount` 是第一排序键。阈值是第 15 高的已确认次数。任何人的 `upper` 都到不了这个阈值，他的真实 `coCount` 也到不了，后面的购买次数和最近时间救不了他。`upper >= threshold` 的人全部留下，包括和阈值打平的所有人，hop2b 再用完整的 `purchaseCount`、`latestTs`、用户 id 拆平局。所以留下的集合包含真正的 top15。`mergeExact` 的并集论证和 42 篇一样，没有变。

单测 `PruneKeepsExactTop`：80 个人里 coCount 为 4/2/1，剪完之后全局 top15 都在留下的集合里，被丢掉的人的 coCount 严格小于第 15 名。另一个用例里有人 `lower=1, upper=3`，k=2，阈值是 3，这个人留下来——没回报完的 part 不能当 0 用。线上只在 `seen.partials` 且每个买家都有 product 列表时剪；旧 storaged 不带 `users` 时 `partials=false`，退回把全部 id 发给 hop2b，仍然精确，只是不剪。

hop2b 仍只对本地 top15 带回他们窗内买过的商品。扫描本身是 `edgePrefix` 的 `[window_start, window_end+1)`，窗外的边不进 `rows_scanned`。

---

## 3. 限额、失败、指标

打到限额、超时、RPC 失败、storaged 不认这个方法，都不许返回一个被截短的名次。`--copurchase_failure_policy`：

| 值 | 行为 |
|----|------|
| `fallback`（默认） | 用 `getNeighbors` 把边拉回 graphd，按同一套 `Copurchase.h` 重算。日志 `fallback=1`，`failure=` 写原因 |
| `error` | 返回 `copurchase <reason>`，不给结果行 |
| 其它字符串 | 当 `error` |

回退自己再失败就返回错误，不再套一层。`failure` 的取值：`not_applied`、`rpc`、`limit`、`candidates`、`timeout`。

| 旗标 | 默认 | 作用 |
|------|------|------|
| `--enable_copurchase` | false | 总开关。关着时 COPURCHASE 进解析器，语法错 |
| `--copurchase_spaces` | 空 | 空表示所有 space。否则逗号分隔的 space 名 |
| `--copurchase_prune` | true | 剪枝。语句里的 `NOPRUNE` 覆盖这一次 |
| `--copurchase_failure_policy` | fallback | 见上表 |
| `--copurchase_max_candidates` | 0 | 剪完后发给 hop2b 的人数上限。0 不限。超过走失败策略，不发被截断的请求 |
| `--copurchase_max_edges` | 0 | 单次 RPC 的边数上限，graphd 写进请求。storaged 同名旗标是请求没带时的底 |
| `--copurchase_budget_us` | 0 | 单次 RPC 的时间上限，微秒 |
| `--copurchase_max_buyers` | 0 | 单次 RPC 的不同买家上限 |
| `--copurchase_timeout_ms` | 0 | 整句超时。到点丢弃未完成的 future，走失败策略 |
| `--copurchase_slow_us` | 200000 | 超过打 `copurchase_slow` WARNING |
| `--storaged_accept_copurchase` | true | false 时不置 `copurchase_applied`，模拟旧 storaged |
| `--local_dst_ratio_sample_interval_secs` | 这次压测设 0 | 关掉 v5 抽样，避免 tick 进 P99 |

storaged 碰到边数、人数或时间上限时置 `limit_hit` 和 `limit_code`（1 边，2 人，3 时间），同时置 `copurchase_applied`。graphd 看见 `limit_hit` 不会用这份不完整的 bitmap。

graphd 计数器在 `initGraphStats`：`num_copurchase`、`num_copurchase_fallback`、`num_copurchase_failure`、`copurchase_pruned`、`copurchase_candidates`、`copurchase_rows_scanned`、`copurchase_rounds`，直方图 `copurchase_latency_us`（含 p999）。storaged：`copurchase_edges_scanned`、`copurchase_limit_hits`，再加上原来的 `num_copurchase` / `copurchase_latency_us` 处理器计数。慢查询另外打 WARNING。

计划行：

```
copurchase_plan mode=exact fallback=0 prune=1 pruned=... sent=... rounds=4 buyers=... failure=- hop_rows=... hop_hosts=... scanned=... users=... products=...
```

`buyers` 是剪之前的人数，`sent` 是发给 hop2b 的人数，`pruned` 是丢掉的人数。

### 失败实测（单机 tck 图）

| 场景 | 结果 |
|------|------|
| v1 graphd + v2 storaged | 成功，9 个商品和手算一致。v2 仍填 `ids` |
| v2 graphd + v1 storaged | 成功，同样 9 行。没有 `users` 就不剪 |
| `accept=false` 且 policy=error | `copurchase not_applied`，没有结果行 |
| storaged 被 kill -9 之后再查 | `copurchase not_applied`，没有结果行 |
| `max_candidates=1` 且 policy=error | `copurchase candidates`。sent 本应是 4 |
| 同上但 policy=fallback | `fallback=1 failure=candidates`，商品仍是那 9 行，用户分是精确的 `5:4:5:190` |

没有一种成功的返回是被截短的名次。

### 上线

1. 先升 storaged。新 storaged 对旧 graphd 只是多回了 `users`，`ids` 还在。`--storaged_accept_copurchase` 先保持 true。
2. 再升 graphd，`--enable_copurchase=false`。普通 GO 不变。
3. 在一个 space 上设 `--copurchase_spaces=<那个 space>` 和 `--enable_copurchase=true`。用 `NOPRUNE` 和默认剪枝各对一批已知用户，商品列表必须一致。
4. 限额先保持 0。确认 `num_copurchase_failure` 和 `copurchase_limit_hits` 没有意外增长，再按容量设 `max_candidates` / `max_edges`。
5. 回滚：graphd 关 `--enable_copurchase`。已经发出去的 COPURCHASE 会变成语法错，GO 不受影响。storaged 可以后回滚；旧 graphd 不依赖新字段。

排障：先看 graphd 的 `copurchase_plan` 和 `copurchase_failure`。`failure=limit` 看 storaged 的 `limit_code`。`not_applied` 是方法没有、旗标关掉，或者 host 没回来。`candidates` 是剪完仍然超过 `max_candidates`。不要把 policy 改成一个会返回部分名次的值——没有这个值。

---

## 4. 图和压测

目标是约 100 万用户、10 万商品、两三千万条边。`generate.py` 对 5 万商品做无放回 zipf 抽样时，前 6.5 万用户就要数分钟，500 万级以上的插入在这台 VM 上放不下这次运行。实际生成并灌进集群的是：

| 项 | 值 |
|----|----|
| 用户 | 150000 |
| 商品 | 10000，id 从 1000001 起 |
| 边 | 2849966 |
| 每人购买 | `8 + (user % 23)` 个不同商品 |
| 热度 | zipf α = 1 |
| sales | 与热度无关的排列 |
| 空间 | `copurchase2`，9 part，replica 1 |
| 文件 | `bench/copurchase/graph_v2.npz` |

3 个 storaged。抽样关掉。ping（graph namespace → stor1）：

| | min / avg / max / mdev (ms) |
|--|------------------------------|
| 桥 | 0.019 / 0.025 / 0.089 / 0.014 |
| usdelay 2.5 之后 | 5.317 / 5.419 / 5.687 / 0.079，20/20 |

时延是 `ResultSet.latency()`。c=1 是 30 次串行，c=10/50/100 各一波。QPS 是完成数除以墙钟。错误数单独写。CPU 是这一波里 `/proc/<pid>/stat` 的 utime+stime 差，CLK_TCK=100，所以 jiffies/100/墙钟是这一波的单核占用，RSS 是波结束时的 VmRSS。

准确率：8 个用户 `1+i*997`，两个窗。真值是生成器边上的 `ground.exact`。

| 模式 | 窗 | 商品列表全同 | 用户列表全同 |
|------|----|--------------|--------------|
| 精确 v2（剪枝） | 30d、7d | 8/8、8/8 | 8/8、8/8 |
| 精确 v1（`NOPRUNE`） | 30d、7d | 8/8、8/8 | 8/8、8/8 |
| nGQL 四句 | 30d、7d | 8/8、8/8 | 8/8、8/8 |

这 8 条上 hop 的中位：

| 模式 | 窗 | pruned | buyers | sent | hop_rows | scanned |
|------|----|--------|--------|------|----------|---------|
| v2 | 30d | 49233 | 50332 | 482 | 5, 50801, 45, 60 | 8, 51442, 6193, 174 |
| v1 | 30d | 0 | 50332 | 50332 | 5, 50801, 45, 60 | 8, 51442, 540089, 174 |
| v2 | 7d | 0 | 481 | 430 | 2, 481, 45, 60 | 2, 483, 1443, 80 |
| v1 | 7d | 0 | 481 | 481 | 2, 481, 45, 60 | 2, 483, 1607, 80 |

30 日 v2 丢掉约 4.9 万人，hop2b 扫描 6193 条边；不剪要扫 540089 条。7 日中位 pruned 是 0（8 条里至少一半没有可丢的人），sent 中位 430，仍略小于 buyers 中位 481，两条中位不是同一次查询。

### 桥，P50 / P99 / P999（毫秒），QPS

P999 在 n=30 和 n=50 等于样本最大。n=100 时最近秩下标是 99，仍是最大的那条，和 P99 不同是因为 P99 不是最大。

| 模式 | 窗 | c | n | P50 | P99 | P999 | QPS | 错误 |
|------|----|---|---|-----|-----|------|-----|------|
| v2 | 30d | 1 | 30 | 48.225 | 105.985 | 105.985 | 14.76 | 0 |
| v2 | 30d | 10 | 10 | 82.866 | 148.992 | 148.992 | 49.01 | 0 |
| v2 | 30d | 50 | 50 | 255.566 | 415.205 | 415.205 | 61.24 | 0 |
| v2 | 30d | 100 | 100 | 304.224 | 480.222 | 490.893 | 67.31 | 0 |
| v1 | 30d | 1 | 30 | 146.688 | 266.562 | 266.562 | 6.57 | 0 |
| v1 | 30d | 10 | 10 | 714.180 | 822.522 | 822.522 | 11.79 | 0 |
| v1 | 30d | 50 | 50 | 3723.050 | 3832.018 | 3832.018 | 11.27 | 0 |
| v1 | 30d | 100 | 100 | 8410.411 | 8619.882 | 8649.037 | 10.90 | 0 |
| nGQL | 30d | 1 | 30 | 591.718 | 1022.027 | 1022.027 | 0.084 | 0 |
| nGQL | 30d | 10 | 10 | 750.637 | 1232.776 | 1232.776 | 0.115 | 0 |
| nGQL | 30d | 50 | 7 | 42.173 | 1492.532 | 1492.532 | 0.015 | 43 |
| v2 | 7d | 1 | 30 | 11.250 | 73.767 | 73.767 | 16.62 | 0 |
| v2 | 7d | 10 | 10 | 12.963 | 38.475 | 38.475 | 63.37 | 0 |
| v2 | 7d | 50 | 50 | 11.951 | 50.298 | 50.298 | 62.91 | 0 |
| v2 | 7d | 100 | 100 | 19.452 | 104.829 | 106.204 | 86.92 | 0 |
| v1 | 7d | 1 | 30 | 27.140 | 66.621 | 66.621 | 15.28 | 0 |
| v1 | 7d | 10 | 10 | 115.120 | 134.537 | 134.537 | 55.23 | 0 |
| v1 | 7d | 50 | 50 | 220.448 | 437.525 | 437.525 | 78.43 | 0 |
| v1 | 7d | 100 | 100 | 395.064 | 629.401 | 647.277 | 83.64 | 0 |
| nGQL | 7d | 1 | 30 | 100.428 | 236.129 | 236.129 | 0.87 | 0 |
| nGQL | 7d | 10 | 10 | 135.686 | 225.669 | 225.669 | 1.05 | 0 |
| nGQL | 7d | 50 | 50 | 108.833 | 245.956 | 245.956 | 1.41 | 0 |
| nGQL | 7d | 100 | 100 | 102.093 | 261.063 | 299.629 | 1.56 | 0 |

30 日 nGQL c=50：50 次里 43 次是 `Used memory hits the high watermark(0.800000)`，表里的 P50 只来自成功的 7 次，不能当成这个并发下的延迟。c=100 那一波把测量进程打成 SIGKILL（exit 137），没有数。30 日 c=1 的墙钟是 355.5 s，服务器 P50 只有 591.7 ms，差在客户端收下几千条边。样例行数：反向边 551，买家出边 6193，FETCH 220。

30 日 c=1 这一波的 storaged（jiffies，结束时 RSS KB，由 jiffies/墙钟/100 算出的单核比）：

| 模式 | jiffies | RSS KB | 单核比 |
|------|---------|--------|--------|
| v2 | 51, 35, 39 | 165076, 205312, 234308 | 25%, 17%, 19% |
| v1 | 290, 281, 290 | 240224, 256776, 271292 | 63%, 62%, 63% |
| nGQL | 868, 902, 897 | 168688, 201568, 203900 | 墙钟 355 s 上约 2.4%–2.5% |

v1 在 c=100 结束时 RSS 约 231–249 MB。v2 的 c=100 约 249–272 MB。内存没有因为剪枝变小：bitmap 仍然要在 hop2a 建出来。省的是 hop2b 的扫描和 CPU。

### 约 5.42 ms

| 模式 | 窗 | c | P50 | P99 | P999 | QPS | 错误 |
|------|----|---|-----|-----|------|-----|------|
| v2 | 30d | 1 | 130.886 | 271.766 | 271.766 | 5.67 | 0 |
| v2 | 30d | 10 | 258.148 | 350.463 | 350.463 | 24.25 | 0 |
| v2 | 30d | 50 | 1365.920 | 2095.936 | 2095.936 | 21.03 | 0 |
| v2 | 30d | 100 | 3345.458 | 4207.870 | 4235.421 | 22.73 | 0 |
| v1 | 30d | 1 | 335.576 | 538.726 | 538.726 | 2.88 | 0 |
| v1 | 30d | 10 | 855.933 | 1023.052 | 1023.052 | 9.44 | 0 |
| v1 | 30d | 50 | 4449.408 | 4730.888 | 4730.888 | 10.11 | 0 |
| v1 | 30d | 100 | 8834.326 | 9513.689 | 9528.699 | 10.21 | 0 |
| v2 | 7d | 1 | 51.267 | 121.084 | 121.084 | 10.29 | 0 |
| v2 | 7d | 10 | 115.412 | 132.892 | 132.892 | 58.51 | 0 |
| v2 | 7d | 50 | 256.977 | 546.454 | 546.454 | 82.73 | 0 |
| v2 | 7d | 100 | 315.420 | 744.839 | 911.351 | 82.77 | 0 |
| v1 | 7d | 1 | 70.885 | 153.665 | 153.665 | 9.60 | 0 |
| v1 | 7d | 10 | 146.726 | 189.121 | 189.121 | 44.59 | 0 |
| v1 | 7d | 50 | 281.036 | 778.030 | 778.030 | 58.30 | 0 |
| v1 | 7d | 100 | 223.675 | 364.885 | 392.355 | 68.78 | 0 |

5.42 ms 上的 30 日 nGQL 没有重跑。桥上 c=50 已经触发内存水位，c=100 把客户端杀掉了。7 日 nGQL 在 5.42 ms 上测了，错误数都是 0：

| c | P50 | P99 | P999 | QPS |
|---|-----|-----|------|-----|
| 1 | 159.905 | 367.548 | 367.548 | 0.81 |
| 10 | 213.058 | 284.745 | 284.745 | 1.04 |
| 50 | 188.967 | 494.096 | 494.096 | 1.39 |
| 100 | 187.377 | 457.525 | 512.366 | 1.54 |

30 日 c=50，桥上 v2 P50 255.6 ms，v1 3723 ms。同一格在 5.42 ms 上是 1366 ms 对 4449 ms。剪枝没有把 RTT 消掉：5.42 ms、c=100 时 v2 P50 是 3345 ms，四轮 RPC 在 100 并发下叠在一起。

---

## 5. 测试

| 项 | 结果 |
|----|------|
| `copurchase_test` | 6 过，含剪枝包含全局 top15，以及未完成 part 不能误删 |
| `local_multihop_test` | 40 过 |
| `run_tck.py` 共同购买 | `TCK_OK` |
| `run_tck.py` 本地多跳 | `TCK_OK`，WHERE 那条仍然不是 multihop |
| 混部、限额、storaged 挂掉 | 上一节的表。成功的结果都是手算的 9 行 |

---

## 6. 边界

- 图是 15 万用户、1 万商品、285 万边，不是 100 万 / 10 万 / 两三千万。更大的 zipf 抽样和插入这次没跑完。
- 30 日 nGQL c=100 没有数。c=50 的延迟只描述成功的 7 次，另外 43 次是内存水位错误。
- 5.42 ms 没有 nGQL 列。
- P999 在这些样本量上就是最大样本，不是更长尾上的稳定分位。
- 剪枝省的是 hop2b 的边，不是 hop2a 的 bitmap。RSS 没有跟着降。
- 7 日有的查询 pruned=0：第 15 名的 `coCount` 已经是 1，所有买家都得留下。
- 主机到 graphd 的路径没有加延迟。
- 限额默认是 0。不设上限时，剪完后的人数仍然可能很大，只是比全量买家小。
