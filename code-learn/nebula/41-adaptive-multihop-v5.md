# 41 — 自适应多跳 v5：分 tick 抽样，比例表进 meta KV

> v4 在 [40](40-adaptive-multihop-v4.md)。40 篇的表对应 `7965d1c`。v5 重跑覆盖了顶层 JSON，40 篇的数字以那篇正文为准。
> 补丁 [`patches/v3.8.0-adaptive-local-multihop-v5.patch`](patches/v3.8.0-adaptive-local-multihop-v5.patch) 打在 v4 补丁之上。
> 日期：2026-10-31。查询时延、tick 墙钟、CPU、leader 切换都是测到的。`--local_multihop_assumed_rtt_us=5000` 仍是配置值。

v4 把出边扫完才发布精确比例，所以随机图的先验是对的。代价是 stor1 一轮扫描的中位 **23707µs**、最大 **63135µs**。比例表只在 meta leader 的内存里，一张表共用一个时间戳。v5 把扫描拆成有预算的 tick，把每条样本写进 meta KV，过期按条目算。

---

## 1. 抽样

`LocalDstRatioSampler` 仍是一条后台线程。`--local_dst_ratio_sample_interval_secs=0` 关掉它。增量模式（`--local_dst_ratio_sample_incremental=true`，默认开）每次醒来只做这么多：

- `--local_dst_ratio_sample_tick_ms`（默认 200，这次延迟表用 100）
- `--local_dst_ratio_sample_budget_us`（默认 2000，这次 1500）
- `--local_dst_ratio_sample_edges_per_tick`（默认 512，这次 2048）
- `--local_dst_ratio_sample_parts_per_tick`（默认 1，这次 4）

游标按 `(space, part)` 留着。没扫过的 part 用 `prefix(edgePrefix)`。扫到一半用 `rangeWithPrefix(cursor, edgePrefix)`，起点是下一把还没读的 key。出边才计数。`getEdgeType <= 0` 的入边跳过。每个正的 edge type 各有一份计数和一份蓄水池。

part 的前缀走完才发布。比例是 `本地出边 / 扫到的出边`，不是蓄水池里的 64 条。蓄水池用 Algorithm R，状态跟着游标走，所以它均匀于整个 part，不是前 4096 条。日志里的 `reservoir=` 是这份样本，`ratio=` 是精确计数。决策用精确计数。part 没走完不发布，避免再把前缀当成整个 part。

下一轮从排序后的 leader 名单往下轮转，不每次都从头扫同一两个 part。正在扫的 part 排在前面，先把它扫完。

`--local_dst_ratio_sample_incremental=false` 时一个 tick 把当前 leader part 全部扫完，用来对照 v4 那种整轮成本。`sample_scan` 和 `sample_parts` 还留着，增量路径不用它们，旧旗标文件还能解析。

stor1 在延迟表那次（tick 100ms，每 tick 2048 条边，budget 1500µs）7072 次 `full=0` 的 tick。`us` 最小 / 中位 / p99 / 最大是 **268 / 617 / 1521 / 4100**。整轮扫描（`full=1`，impact 段，28 次）是 **15072 / 15620 / 23294**。v4 那次中位 23707、最大 63135，是同一类整轮扫描。

stor1 上和 v4 对得上的精确比例（edge type 是 schema 里的正类型）：

| space | part | v5 ratio | seen | v4 同 part |
|-------|------|----------|------|------------|
| 5 `ad_affinity` | 3, 6, 9 | 1.000000 | 2393, 2389, 2390 | 1 |
| 6 `ad_random` | 3 | 0.352990 | 2391 | 0.35299 |
| 6 | 6 | 0.348263 | 2389 | 落在 0.320117–0.35299 |
| 6 | 9 | 0.320117 | 2396 | 0.320117 |
| 7 `ad_mixed` | 6 | 0.243311 | 2392 | 0.243311 |
| 7 | 3, 9 | 1.000000 | 2397, 2394 | 1 |

这三台机器各领 3 个 part。上表是 stor1 的。蓄水池（k=64）在 0.30–0.42 之间晃，不拿来做决策。

完成的样本经 `publishLocalDstRatio` 放进下一次心跳的 `local_dst_ratio_entries`（`HBReq` 字段 10）。字段 9 仍是每个 part 上各 edge type 的最小值，给只认识 v4 的 graphd。

---

## 2. meta KV 和逐条过期

key 是 `__local_dst_ratio__` + space id + part id + edge type。value 是 8 字节比例、8 字节 `ts_ms`、8 字节 version。`MetaKeyUtils::localDstRatioKey` / `localDstRatioVal` 做来回。version 是这个 `(space, part, edge)` 每完成一轮加一。

`HBProcessor` 第一次处理心跳时，如果本进程还没载入，就 `prefix` 这张表。成功才把 `gLocalDstRatioLoaded` 设上。`E_LEADER_CHANGED` 直接返回，等下一次心跳；那是 follower 上的请求，不是载入失败。其它错误打一条 warning。载入之后，storage 心跳里的条目合并进内存，并放进同一次 `doSyncPut`。`HBResp` 字段 7 把整张表回给 graphd，字段 6 是按 part 取的最小值。

graphd 按 `(space, part, edge)` 合并。时间戳用样本自己的 `ts_ms`，不用收到心跳的时刻，所以 leader 切换不会把旧样本刷成新的。`--local_multihop_prior_per_entry=true`（默认）时，查询要的每个 edge type 都必须 `ratioEntryFresh`。过期或缺样本，先验 lambda 返回 false，这一 part 是不确定的，不是置信基线，也不是置信多跳。edge type 对不上时才退回 edge 0 的旧聚合。`--local_multihop_prior_per_entry=false` 时仍用整表一个 `localDstRatioAtMs_`，那是 v4。

`--local_multihop_plain_baseline=true`（默认）时，收束之后如果没有 part 选多跳，就不进 adaptive driver，走普通的一跳 `GetDstBySrc`。PROFILE 仍写 `multi_parts=0 base_parts=N`。`--local_multihop_trace=true` 时再打一行 `adaptive_multihop choice=base`，否则 drift 脚本在日志里看不到这句。v4 的压测把这两项设成 false，driver 还在。

---

## 3. 集群

3 meta + 3 storaged + 1 graphd。`local_multihop_test` 40 条全过，含分段蓄水池和过期判断。`meta_key_utils_test` 的 `LocalDstRatioRoundTrip` 过了。静态 tck：`{10,12}`、`{7,9,10,12,15}`、空、`{7,9,15}`，WHERE 没有 `applied`。

桥上 graph → `10.88.0.21`，20 包 0 丢：0.022 / 0.030 / 0.092 / 0.014 ms。约 5ms 那次：5.112 / 5.399 / 5.976 / 0.181 ms。

9 part，社区 300，度约 8，种子 7。预热 3。c=1 是 8 个样本，c=10 是 80，c=50 是 400。错误数都是 0。四路：baseline、static、v4（逐条过期关，plain baseline 关）、v5（这两项开）。抽样在这四路里都是增量 tick，不是 v4 的整轮扫描。整轮扫描只在后面的 impact 段打开。

---

## 4. 约 5ms，c=1 P50

| 放置 | 模式 | P50 | P99 | waves | hosts | choice |
|------|------|-----|-----|-------|-------|--------|
| affinity | baseline | 21.722 | 25.550 | 3 | 9 | |
| affinity | static | 7.575 | 15.402 | 1 | 3 | |
| affinity | v4 | 7.441 | 14.880 | 1 | 3 | multi_parts=9 |
| affinity | v5 | 10.123 | 15.438 | 1 | 3 | multi_parts=9 |
| random | baseline | 24.706 | 28.036 | 3 | 9 | |
| random | static | 29.540 | 34.561 | 4 | 12 | |
| random | v4 | 22.846 | 24.474 | 3 | 9 | base_parts=6 |
| random | v5 | 24.898 | 26.549 | 3 | 9 | base_parts=6 |
| mixed | baseline | 21.989 | 26.561 | 3 | 9 | |
| mixed | static | 27.639 | 31.163 | 4 | 10 | |
| mixed | v4 | 23.199 | 25.707 | 3 | 9 | base_parts=7 |
| mixed | v5 | 21.677 | 26.238 | 3 | 9 | base_parts=7 |

v5 亲和的 PROFILE 仍是 1 wave、3 host、`multi_parts=9`。c=1 的 8 个样本 P50 是 10.123，比静态 7.575 和 v4 的 7.441 高。c=10 是 10.122 对静态 10.353、v4 9.715。c=50 是 9.913 对静态 10.050、v4 10.171。c=1 这 8 个点没有把和静态的差距削掉。

v5 随机是整句基线。c=1 比基线高 0.192ms（24.898 对 24.706）。c=10 是 29.546 对基线 29.746。c=50 是 30.941 对基线 30.588。plain baseline 把请求放回普通一跳路径之后，这三档和基线的差都在零点几毫秒里，没有再出现 v4 文档里那稳定的约 1ms。v4 这次 c=1 随机是 22.846，比基线 24.706 还低，n=8 的抖动盖过了那 1ms。

v5 混合 c=10 是 30.578，基线 29.703，v4 31.561。c=1 是 21.677 对基线 21.989。形状是 `base_parts=7`，3 wave，9 host。

---

## 5. 桥，c=1 P50

亲和：基线 2.976，静态 2.071，v4 2.172（`multi_parts=9`，1 wave，3 host），v5 2.026（同样 1 wave，3 host）。

随机：基线 2.835，静态 3.815，v4 3.167，v5 2.956。v5 和基线差 0.121ms，都是 3 wave、9 host、`base_parts=6`。

混合：基线 2.694，静态 3.043，v4 3.325，v5 3.043。v5 是 `base_parts=7`。

---

## 6. 抽样开着和关着，c=50

约 5ms，v5 的 graphd，400 个样本。stor1 的 CPU 是这段 `measure` 前后的 utime+stime，除以墙钟。窗长大约 5.5–6.1 秒。

| 抽样 | 放置 | P50 | P99 | stor1 核 |
|------|------|-----|-----|----------|
| 关 | affinity | 11.002 | 33.349 | 0.1067 |
| 关 | random | 30.684 | 43.379 | 0.1442 |
| 增量 | affinity | 11.033 | 34.167 | 0.1213 |
| 增量 | random | 31.093 | 45.947 | 0.1548 |
| 整轮 | affinity | 10.131 | 18.603 | 0.1056 |
| 整轮 | random | 31.938 | 44.063 | 0.1516 |

增量比关掉高大约 0.01 核。整轮在这个 6 秒窗里没有稳定地更高：affinity 整轮的 P50 反而最低。窗比抽样间隔短，整轮扫描不一定落进每一次测量。能分开的是 tick 墙钟：增量中位 617µs，整轮中位 15620µs。查询 P50 在这三档之间没有一条超出这 400 个样本自己的抖动。

---

## 7. 漂移和 meta leader

延迟表用的 tick 是 100ms、每 tick 2048 条边。part 多的时候一轮要接近 8 秒，返回前那 8 秒不够把新图扫完。漂移在测完延迟之后又跑了一轮：tick 50ms、每 tick 4096 条边、budget 3000µs，一轮大约 1 秒。等待仍是 **8 秒**，算在方法里。

约 5ms，v5，空间 `ad_drift_v5`，12 条返回全部 `choice=multi`，`rpc` 中位 1，前 10 条 P50 **7.761ms**。随机阶段 16 条里 14 条仍是 `choice=multi` 且 `early` 为真（守卫把 wave 留在 3，P50 约 23ms），只有 2 条是 base。查询比一轮抽样快，亲和先验还没被新的随机边换掉。v4 同一次设置的返回阶段 12 条全是 `choice=base`，P50 23.322ms，8 秒里没有切回多跳。

桥上 v5 的返回阶段后 5 条是 `multi_parts=9 rpc=1`（2.3–4.4ms），前 3 条是 plain baseline（日志里的 `choice=base`，5–6ms）。

meta leader：08:55:51 meta1（pid 92655）在收心跳。`ad_random` 上 `GO 3` 成功，1760 行，23224µs，日志 `choice=base multi_parts=0 base_parts=9 space=6`。杀掉 meta1。08:56:00 meta2 打出 `local_dst_ratio_kv_load entries=171`，随后开始收 storage 心跳。同一句再查，1760 行，24802µs，仍是 `choice=base ... space=6`。原文在 `results/v5_meta_leader.txt`。

---

## 8. 旗标

| 旗标 | 默认 | 作用 |
|------|------|------|
| `local_dst_ratio_sample_interval_secs` | 10 | 0 关掉线程。tick_ms 为 0 时也是 tick 间隔 |
| `local_dst_ratio_sample_incremental` | true | 游标续扫。false 时一个 tick 扫完所有 leader part |
| `local_dst_ratio_sample_tick_ms` | 200 | 增量 tick 间隔 |
| `local_dst_ratio_sample_budget_us` | 2000 | 每个 tick 的时间预算。0 不限 |
| `local_dst_ratio_sample_edges_per_tick` | 512 | 每个 tick 最多读的出边 |
| `local_dst_ratio_sample_parts_per_tick` | 1 | 每个 tick 最多打开的 part |
| `local_dst_ratio_sample_edges` | 64 | 蓄水池大小。发布的是精确计数 |
| `local_multihop_prior_per_entry` | true | 按条目的 `ts_ms` 过期。false 是 v4 的整表时间戳 |
| `local_multihop_plain_baseline` | true | 全基线走普通一跳 RPC |
| `local_multihop_prior_stale_ms` | 30000 | 超过这个年龄算不确定。0 不过期 |
| `local_multihop_prior_high` / `prior_low` | 0.8 / 0.4 | 置信带 |
| `local_multihop_skip_confident_explore` | true | 置信时不做 5% 探索 |
| `local_multihop_collapse_mixed` | true | 有基线 part 就把整句收成基线 |

---

## 9. 灰度

1. 先升 storaged。默认就是增量抽样。旧 graphd 只读心跳字段 9，行为仍是 v4 的比例值，只是后台扫描变短。要退回整轮扫描，设 `local_dst_ratio_sample_incremental=false`。要完全停掉，设 `local_dst_ratio_sample_interval_secs=0`。
2. 再升 metad。新进程从 KV 载入。旧 metad 不认识字段 10，不能和这版 storaged 长期混跑：旧 metad 会丢掉条目，只留下字段 9 的最小值。
3. 最后升 graphd。`prior_per_entry=true` 和 `plain_baseline=true` 是 v5。灰度时把这两项设成 false，决策回到 v4，抽样仍是增量的。
4. 回滚 graphd 只改旗标，不必换二进制。回滚抽样改 storaged 旗标，已写入的 KV 留着，不挡旧路径。

不要在随机图上开静态多跳。混合查询在 v5 里整句基线，亲和 part 不会单独走多跳。

---

## 10. 边界

- 亲和 v5 在约 5ms、c=1 的 P50 是 10.123ms，不是 7.5。同一轮 v4 是 7.441，静态是 7.575。c=50 上 v5 是 9.913，静态是 10.050。
- 随机 v5 和基线的差在 c=1 是 +0.192ms，c=10 是 -0.200ms，c=50 是 +0.353ms。没有把这点差收成零。
- 增量 tick 的中位是 617µs（7072 次）。整轮是 15620µs（28 次）。c=50 那 6 秒窗里的 CPU 和 P50 分不开抽样开关。
- 精确比例和 v4 在 stor1 的 part 上对到打印出来的 6 位。蓄水池不是决策值。
- 漂移返回前的 8 秒是方法的一部分。v5 在约 5ms 的返回阶段 12 条都是多跳。随机阶段 16 条里有 14 条还停在多跳上，查询跑完时新样本还没换上。v4 那次返回阶段 12 条都是基线。
- 比例在 meta KV 里，新 leader 载入了 171 条。follower 上的 prefix 会得到 `E_LEADER_CHANGED`，不记成已加载。
- 一条时间戳是样本完成的时刻。30 秒没有新的完成轮次，这一条变成不确定，不是整张表一起过期。
