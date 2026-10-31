# 40 — 自适应多跳 v4：均匀抽样、置信先验、混合查询收成基线

> v3 在 [39](39-adaptive-multihop-v3.md)。那篇的表对应 `a3f0970` / `b9dc90a`，不要用现在的顶层 JSON 去对那篇的数字。
> 补丁 [`patches/v3.8.0-adaptive-local-multihop-v4.patch`](patches/v3.8.0-adaptive-local-multihop-v4.patch) 打在 v3 补丁之上。
> 这篇的延迟表是同一次六路重跑。v4 的漂移是这之后又跑的一轮，原因写在第 6 节。
> 日期：2026-10-31。查询时延都是测到的。抽样耗时单独标了。`--local_multihop_assumed_rtt_us=5000` 仍是配置值。

v3 有三处实测退步。亲和在约 5ms、c=1 的 P50 是 17.9ms，因为 9 个分区各 5% 探索，PROFILE 经常是 `multi_parts=8 base_parts=1`，整句被拖回 3 个 wave。随机图的心跳样本是每个 part 前缀上的前 64 条边，比例偏高，v3 不肯留在基线。混合查询在 c=10 是 49.3ms，基线是 28.2ms，PROFILE 是 5 个 wave、17 条 host 回复。

v4 改四件事，都不加新的 thrift 字段。

1. storaged 只数出边，part 能在扫描上限里走完就发布精确比例，走不完就对已经看到的出边做蓄水池。随机图的先验落到 0.32–0.35。
2. 先验落在 `[prior_low, prior_high)` 外面时不再做 5% 探索。这个判断在已经有基线样本之后仍然有效，避免「试过一次基线就永远改去试多跳」。
3. 一条查询里只要有分区选了基线，整句收成一次基线 RPC。基线分区自己就要一跳一个 wave，多跳不会把关键路径缩短。
4. graphd 把心跳里的比例表合并进缓存。空的 `HBResp` 不把缓存清掉。meta leader 的表仍只在内存里。

没有做后台影子 RPC。置信的时候直接不探。不置信的时候探索还在关键路径上，但只要探出基线，第 3 条会把整句收成基线。

---

## 1. 抽样

`LocalDstRatioSampler` 仍是后台线程。间隔 `--local_dst_ratio_sample_interval_secs`（默认 10，这次压测 2，0 关掉）。每轮最多 `--local_dst_ratio_sample_parts` 个本机 leader part（默认 32，压测 64）。

前缀还是 `NebulaKeyUtils::edgePrefix(partId)`，迭代器要拿一个左值 `std::string`，右值那个 `prefix` 重载是删掉的。`isEdge` 通过之后再看 `getEdgeType`。`<= 0` 的是入边，key 里的 dst 是原来的 src，不是 GO 的本地终点比例，直接跳过，也不计入扫描条数。原始 key 的访问另有 `sample_scan * 8` 的上限，避免一个 part 里全是入边时停不下来。

出边用 Algorithm R。`reservoirConsider` 在计数之后接受 `[1, seen]` 上的均匀整数；落在 `1..keep` 里就替换槽位。`--local_dst_ratio_sample_edges`（默认 64）现在是蓄水池大小，不是前缀截断。

part 在 `--local_dst_ratio_sample_scan`（默认 4096）条出边之内走完时，发布的是 `本地出边 / 扫到的出边`，不是蓄水池里的 64 条。这次数据每个 part 大约 2400 条出边，32 个 part 都是 `exact`，`capped=0`。超过扫描上限时才发布蓄水池比例，那是扫过的出边里的均匀样本，不是整个 part 的均匀样本。

dst 的 part 仍是 `MetaClient::partId`，本地与否仍是 `NebulaStore::isLeader`。

stor1 在这次放置压测期间 308 次 `local_dst_ratio_sample_us`。`us` 的最小 / 中位 / 最大是 **12158 / 23707 / 63135**。这是整轮扫描的墙钟，不是单条边的估算。稳定阶段的一行是 `parts=32 kept=74970 scanned=74970 exact=32 capped=0`，旁边的 `us` 大约 17ms。space 5（`ad_affinity`）三个 part 都是 1。space 6（`ad_random`）是 0.320117–0.35299。space 7（`ad_mixed`）是 0.243311–1。后面临时 space 变多时，同一轮会到 `exact=36 scanned=86087`，中位数被拉到 23.7ms。查询路径不等这轮扫描。它和查询抢同一份 RocksDB。

样本经 `publishLocalDstRatio` 放进下一次 `HBReq.local_dst_ratio`。`HBProcessor` 仍把表留在 meta leader 的内存里，不写 KV。`HBResp` 把当前整张表回给心跳客户端。

---

## 2. 置信先验和混合收束

`choose` 的探索只在先验不置信时发生。`skipConfidentExplore` 打开、而且先验 `>= prior_high`（默认 0.8）或 `<= prior_low`（默认 0.4）时，这次 `draw` 不翻转。中间带仍按 `--local_multihop_explore_rate`（0.05）。

只在冷启动里看先验是不够的。`exploitOf` 在「只有基线样本」时原来会再试一次多跳。PROFILE 是检查查询之后的第二句，第一句已经记下基线，第二句就被这条规则改成多跳，置信跳过探索之后就锁死了。v4 把两条规则放在样本计数之前：

- 先验 `<= prior_low`：基线。
- 先验 `>= prior_high`：多跳。hop-1 streak 不挡它。挡住的话，streak 要靠一次完整多跳才能清掉，而决策又拒绝这次多跳，切不回去。
- 先验低于 `min_local_ratio`（0.6）但还没到 `prior_low`：有了基线样本之后也不再试多跳。这种 part 的守卫会在第一跳停下，试多跳省不了往返。

`localDstRatioFresh` 用墙上的毫秒。`--local_multihop_prior_stale_ms` 默认 30000，0 表示不过期。没收到过心跳，或者超过这个年龄，先验 lambda 返回 false，当作没有样本。graphd 进程起来时，`loadData` 里的那次心跳已经把表填上，比 `Register time task` 更早。压测在 graphd 拉起后再等 6 秒，盖住「心跳线程第一次要等一个间隔加最多 0.9 秒抖动」。

`reconcilePartChoices` 在 `collapseMixed` 打开时，只要同一句里既有多跳 part 又有基线 part，就把所有 part 改成基线。亲和 part 的先验是 1，不会自己去探索。混合图里偶数 part 的出边落在 `{2,4,6,8}` 上，本机 leader 只占其中 1 或 2 个，比例大约 0.25 或 0.5。0.5 低于 0.6，选基线，于是整句基线。

`hostBatchGroups` 没改。多跳 part 仍按 leader 合成一个 `GetDstBySrc`。这次混合查询收成基线之后，这条路径在混合图上不会被走到。

graphd 的心跳回调把非空的 `local_dst_ratio` 合并进 `localDstRatio_`，并记下 `localDstRatioAtMs_`。空回复不覆盖。这是 meta leader 切换时的 graphd 侧缓存，不是 KV。时间戳是整张表一份，不是每个 part 一份。合并也不会删掉已经消失的 part。

---

## 3. 集群和这次怎么测

3 meta + 3 storaged + 1 graphd。`local_multihop_test` 38 条全过。静态 tck（`--enable_local_multihop=true --local_multihop_affinity=1`）：`{10,12}`、`{7,9,10,12,15}`、空、`{7,9,15}`，WHERE 那句没有 `applied`。

桥上 graph → `10.88.0.21`，20 包 0 丢：0.019 / 0.111 / 1.843 / 0.397 ms。有一包 1.843ms，所以均值不是 0.02ms。stor1 → stor2 是 0.018 / 0.022 / 0.068 / 0.010 ms。延迟转发器上 graph → stor1，20 包 0 丢：5.151 / 5.396 / 6.251 / 0.213 ms。

9 part，社区 300，度约 8，种子 7。预热 3。c=1 是 8 个样本，c=10 是 80，c=50 是 400。下面每格 `ok` 都是真，错误数都是 0。PROFILE 的 choice 是检查查询之后的那句 `PROFILE`，不是 c=1 的八个样本。

六路：baseline、static（守卫关）、v1（整句，不用心跳）、v2（一分区一次 RPC，不用心跳）、v3（按 leader 合并，用心跳，但 `skip_confident_explore=false`、`collapse_mixed=false`）、v4（这两项为 true，`prior_high=0.8`，`prior_low=0.4`）。storaged 是同一份二进制。v3 的决策规则还是 v3，抽样已经是 v4 的出边精确比例。39 篇里随机图被前缀 64 条边抬高、混合 c=10 到 49.3ms，是旧抽样上的数字，不是这张表里的 v3 列。

---

## 4. 约 5ms

c=1，P50 是毫秒。waves / hosts 来自那句 PROFILE。

| 放置 | 模式 | P50 | P99 | QPS | waves | hosts | choice |
|------|------|-----|-----|-----|-------|-------|--------|
| affinity | baseline | 21.881 | 23.445 | 20.16 | 3 | 9 | |
| affinity | static | 7.220 | 14.252 | 33.69 | 1 | 3 | |
| affinity | v1 | 7.472 | 17.644 | 32.85 | 1 | 3 | multi |
| affinity | v2 | 8.521 | 19.104 | 29.14 | 1 | 9 | multi_parts=9 |
| affinity | v3 | 12.932 | 24.508 | 24.49 | 1 | 3 | multi_parts=9 |
| affinity | v4 | 7.553 | 14.225 | 33.92 | 1 | 3 | multi_parts=9 |
| random | baseline | 21.351 | 26.289 | 20.73 | 3 | 9 | |
| random | static | 26.181 | 30.406 | 18.41 | 4 | 12 | |
| random | v1 | 22.805 | 26.163 | 19.00 | 3 | 9 | base |
| random | v2 | 23.247 | 33.564 | 18.68 | 3 | 9 | base_parts=6 |
| random | v3 | 24.453 | 36.107 | 18.47 | 5 | 15 | multi_parts=5 base_parts=1 |
| random | v4 | 22.566 | 29.215 | 20.28 | 3 | 9 | base_parts=6 |
| mixed | baseline | 21.436 | 23.346 | 20.96 | 3 | 9 | |
| mixed | static | 26.164 | 29.043 | 18.47 | 4 | 10 | |
| mixed | v1 | 19.353 | 22.876 | 22.05 | 3 | 9 | base |
| mixed | v2 | 19.868 | 32.649 | 21.38 | 3 | 12 | multi_parts=5 base_parts=2 |
| mixed | v3 | 21.831 | 24.687 | 20.41 | 5 | 16 | multi_parts=6 base_parts=1 |
| mixed | v4 | 21.883 | 24.994 | 20.73 | 3 | 9 | base_parts=7 |

v4 亲和是 9 个 part 都走多跳、1 个 wave、3 条 host 回复。c=1 P50 **7.553ms**。静态是 7.220，v1 是 7.472。39 篇那次 v3 是 17.944，这次 v3 的 PROFILE 碰巧是 `multi_parts=9`，但 8 个样本的 P50 仍是 12.932、P99 24.508，探索还在把一部分句子拉回 3 个 wave。

v4 随机是整句基线，3 个 wave、9 条 host、没有 `applied`。c=1 比基线高 1.2ms（22.566 对 21.351）。c=10 是 31.364 对基线 30.309，c=50 是 31.639 对 30.392。v3 这次是 5 个 wave、15 条 host，c=1 24.453，c=10 32.335。

v4 混合是整句基线，7 个源 part，3 个 wave、9 条 host。c=10 P50 **28.968**，基线 **28.694**，v3 **31.921**。c=50 是 30.066 对基线 29.130 对 v3 31.841。39 篇的 49.3 对 28.2 是旧抽样上的 v3，不是这列。

c=10 / c=50 的亲和 P50：v4 是 9.491 / 9.707，v1 是 9.469 / 9.582，静态是 8.756 / 9.607，v3 是 12.398 / 12.079，基线是 28.283 / 27.974。

---

## 5. 桥，c=1 P50

亲和：基线 3.462，静态 1.952，v1 2.795，v2 2.232（11 host，PROFILE 是 8+1），v3 2.679（6 host，8+1），v4 2.066（3 host，`multi_parts=9`，1 wave）。

随机：基线 2.696，静态 4.008，v1 3.194，v2 3.088，v3 3.204（`multi_parts=6`），v4 3.326（`base_parts=6`，3 wave，9 host）。v4 比基线高 0.6ms。

混合：基线 2.945，静态 3.306，v1 3.073，v2 3.139（12 host），v3 2.974（16 host，5 wave），v4 3.084（`base_parts=7`，3 wave，9 host）。

---

## 6. 两个方向各用了几条查询

换边、重新灌入之后、开始返回查询之前，睡 **8 秒**。这 8 秒给抽样（2 秒）和心跳（2 秒）留时间，算在方法里，不是隐藏的预热查询。v4 漂移在延迟表之后又跑了一轮：上一轮二进制里，高先验会被 hop-1 streak 挡住，桥上的返回阶段 8 条全是基线。streak 只能被一次完整多跳清掉，而决策又拒绝这次多跳。最终代码改为高先验直接选多跳。延迟表里的三种放置没有走到那条分支：亲和没有提前停，随机和混合整句是基线。下面的 v4 漂移是改完之后的。

约 5ms，v4，空间 `ad_drift_v4`，全部正确。

- 亲和 12 条。第 1 条就是 `multi_parts=9 rpc=1`（11.82ms）。第 5–8 条是整句基线（`base_parts=9 rpc=3`，21–24ms），第 9 条回到 `multi_parts=9`。这四条的形状和「有 part 没选多跳，collapse 把整句收成基线」一致。日志没有打出每个 part 的先验，不把原因写成已经测到的事实。
- 随机 16 条。前 2 条仍是 `multi_parts=6 rpc=3`（旧的亲和先验还在，守卫把 wave 留在 3）。**第 3 条**起全部是 `base_parts=6 rpc=3`。中位 23.8ms 再 22.3ms。
- 返回 12 条。**第 1 条**就是 `multi_parts=9 rpc=1`，客户端 9.29ms。12 条都是多跳，窗内 P50 7.859ms（10 条）和 9.101ms（后 2 条）。

同一套约 5ms 的设置里，v2 返回 24 条结束时仍是 `mixed multi_parts=8 base_parts=1`，没有出现 `multi_parts=9`。v3 返回的第 1 条是 `multi_parts=9 rpc=1`（9.27ms），后面 16 条里有 6 条因为探索又变成 mixed。v1 的随机阶段 20 条里 19 条仍是 multi。

桥上 v4 返回 8 条全部是 `multi_parts=9 rpc=1`，第 1 条客户端 3.85ms，窗内 P50 2.144ms。随机阶段同样是前 2 条多跳、第 3 条起基线。

---

## 7. v1 到 v4，以及要不要上

约 5ms、c=1 的 P50，毫秒。同一列的放置见上表。

| | 决策 | 亲和 | 随机 | 混合 | 切回多跳 |
|--|------|------|------|------|----------|
| v1 | 整句 EWMA，5% 探索，守卫兜底 | 7.472，1 wave | 22.805，留在基线 | 19.353 | 这次没做返回 |
| v2 | 按源 part，两跳 hop-1 就切基线 | 8.521，9 次 RPC | 23.247 | 19.868，仍是混合 | 24 条里没有 9 part |
| v3 | 按 leader 合并，心跳先验，仍探索 | 12.932，样本被探索拉开 | 24.453，5 wave | 21.831，5 wave / 16 host | 第 1 条，但返回阶段还会探索 |
| v4 | 置信不探索，混合收成基线，出边精确比例 | 7.553，1 wave / 3 host | 22.566，整句基线 | 21.883，整句基线 | 第 1 条，返回阶段 12 条都是多跳 |

v1 在「整句都是亲和」时和 v4 一样快，代码更少。它不能按 part 分开，混合图要么整句多跳要么整句基线，切回要靠 5% 探索把 EWMA 慢慢拉过来。

v2 把亲和 part 留在多跳、随机 part 留在基线。RPC 数上去了，亲和比 v1 慢。切回在 24 条里没完成。

v3 把 RPC 合并回去，并用心跳做冷启动和 streak 之后的重试。探索仍在关键路径上，所以亲和的样本分布比 PROFILE 的那一句难看。旧抽样还让随机图的先验偏高。

v4 是这四版里唯一同时做到这三件事的：亲和回到大约 7.5ms 且稳定 1 个 wave，随机图停在基线上，混合图不再多加 wave。代价是混合查询里的亲和 part 也不走多跳。那些 part 省下的往返会被基线 part 的 3 个 wave 盖住，多出来的 RPC 只加并发。

生产上如果 GO 的源 part 会混着「几乎全本地」和「明显不本地」，用 v4 的默认旗标：`host_batch`、`heartbeat_prior`、`skip_confident_explore`、`collapse_mixed`，`prior_high=0.8`，`prior_low=0.4`，`min_local_ratio=0.6`。抽样间隔保持默认 10 秒。这次压测设成 2 秒，stor1 中位 23.7ms / 轮，是后台扫描，不是查询时延。part 大于 4096 条出边时比例只对扫过的前缀均匀，要看日志里的 `capped`。meta leader 切换不丢 graphd 已有的表，但 30 秒没有新心跳之后先验失效。不要在随机图上开静态多跳。

---

## 8. 边界

- 亲和 v4 的 7.553ms 是这 8 个样本的 P50，不是 7.3。静态是 7.220，v1 是 7.472。1 wave、3 host、`multi_parts=9` 是测到的。
- 随机 v4 比基线高大约 1ms（c=1 22.566 对 21.351，c=10 31.364 对 30.309）。形状是基线。没有把这 1ms 收成零。
- 混合 v4 的 c=10 是 28.968，基线是 28.694。39 篇的 49.3 是旧抽样。这次 v3 列已经用了新抽样，c=10 是 31.921，PROFILE 仍是 5 wave / 16 host。
- 抽样 308 次的中位是 23707µs / 轮。part 都没碰到扫描上限，所以是精确比例。更大的 part 会变成蓄水池，并且只均匀于扫过的出边。
- 桥上的 ping 均值是 0.111ms，因为有一包 1.843ms。约 5ms 那次均值是 5.396ms。`assumed_rtt_us=5000` 不是这次 ping。
- 漂移返回前的 8 秒是方法的一部分。随机阶段的前 2 条仍是多跳，第 3 条才是整句基线。返回阶段的第 1 条就是 `multi_parts=9`。
- 亲和漂移中间有 4 条整句基线。形状和 collapse 一致，每个 part 的先验没有单独记下来。
- 比例表不进 meta KV。graphd 合并缓存，空心跳不清。一个时间戳覆盖整张表。
