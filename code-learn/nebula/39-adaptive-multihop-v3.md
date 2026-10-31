# 39 — 自适应多跳 v3：按 leader 合并 RPC，心跳样本做先验

> v2 按源分区各发一次 RPC，亲和在约 5ms 下比 v1 慢。那一版在 [38](38-adaptive-multihop-v2.md)。
> 补丁 [`patches/v3.8.0-adaptive-local-multihop-v3.patch`](patches/v3.8.0-adaptive-local-multihop-v3.patch) 打在 v2 补丁之上。
> 这篇的表对应提交 `a3f0970`（文档指针 `b9dc90a`）。v4 那次重跑覆盖了顶层 JSON，数字以这篇正文为准，不要回头读现在的文件。[40](40-adaptive-multihop-v4.md) 是下一版。
> 当时的 JSON 是顶层 `bridge_*` / `rtt5_*` 里带 `adaptive-v3` 的文件，以及 `drift_v3_bridge.json`、`drift_v3_rtt5.json`。同一次重跑也覆盖了 baseline / static / v1 / v2 的顶层文件。38 篇的表仍以当时的提交为准。
> 日期：2026-10-31。没有估出来的查询时延。抽样耗时单独标了。

v2 的决策是对的，RPC 形状不对。9 个亲和分区各一次 `GetDstBySrc`，PROFILE 是 9 条 host 回复。v1 和静态是 3 条，因为 `StorageClient` 按 leader 扇出一次。v3 把**已经选了多跳**、并且 leader 相同的分区合成一个 job。`StorageClient` 再按 host 拆开，亲和图回到每台 storaged 一次请求。守卫仍按源分区算：`min_local_ratio > 0` 且请求里有多个 part 时，`GetDstBySrcProcessor::runMultiHop` 对每个 part 单独跑 `runLocalMultiHop`。一个 part 提前停，只把那个 part 的 carry 记成 `remote_depth = continue_hop`，别的 part 继续走完。响应里多了平行数组 `part_ids`、`part_early_stop`、`part_local_ratio`、`part_continue_hop`。graphd 用它们更新对应分区的 EWMA，不再把一台机器上的所有分区记成同一次提前停。

基线分区仍然合成**另一个** job，和多跳 job 并行。单跳请求不跑守卫，这些分区可以混在一次扇出里。它们不进多跳请求：那一次 BFS 会把低比例 part 和亲和 part 扫在一起。

`--local_multihop_host_batch=false` 就是 v2 的一分区一次 RPC。`--local_multihop_heartbeat_prior=false` 时忽略心跳样本。

---

## 1. 心跳抽样

36 篇第 8 节。storaged 上 `LocalDstRatioSampler` 每隔 `--local_dst_ratio_sample_interval_secs`（默认 10，这次压测设 2，0 表示关掉）扫一遍。每轮最多 `--local_dst_ratio_sample_parts` 个本机 leader part（默认 32），每个 part 用 `edgePrefix(partId)` 做前缀迭代，最多读 `--local_dst_ratio_sample_edges` 条边（默认 64）。dst 的 part 用 `MetaClient::partId`，本地与否是 `NebulaStore::isLeader`。比例是 `本地 dst 数 / 读到的边数`。

样本放进 `MetaClient::publishLocalDstRatio`。下一次心跳的 `HBReq.local_dst_ratio`（可选字段 9）带上。`HBProcessor` 记在 meta leader 进程的内存里，不写 KV，leader 一切换就空，要等下一轮心跳再填。`HBResp.local_dst_ratio`（字段 6）把当前表回给所有心跳客户端。graphd 在心跳回调里放进 `MetaClient::localDstRatio`。

`choose` 在 `--local_multihop_heartbeat_prior=true` 时用这个数：

- 冷启动且样本 `< min_local_ratio`：不试多跳。
- `hop1Streak >= 2` 但样本 `>= min_local_ratio`：直接再试多跳，不等 5% 探索。
- 没有样本时仍是 v2 的规则。

这次压测把 graphd 和 storaged 的 `--heartbeat_interval_secs` 设成 2，和抽样间隔一样。默认心跳是 10 秒。

stor1 的 glog 里 218 次 `local_dst_ratio_sample`。最后几次是 `parts=30 edges=1920`。`us` 的最小 / 中位 / 最大是 **276 / 577 / 1959**。这是整轮扫描的墙钟，含 30 个 part、1920 条边，不是单条边的估算。30 和 1920 碰到了 32 part × 64 边的上限（这台机器上还有别的 space）。

抽样读的是每个 part 前缀上的**前 64 条**边，不是均匀抽样。随机放置时这个前缀可以比 3 跳终点更「像本地」。下面随机图 v3 仍选了多跳，就是这个偏差。

---

## 2. 混合查询的关键路径

第 1 波已经把多跳 job 和基线 job `collectAll` 在一起。多跳分区在这一波里可以走完 3 跳。基线分区的第 2 跳必须看见第 1 跳的 dst，不能在多跳回包之前就发出去。所以整句时延的下界是基线分区自己的 3 次往返，不是亲和的 1 次。多跳提前做完不会把整句变成 7ms。

这次没有再做流水线。测到的 mixed v3 在约 5ms、c=10/c=50 上比基线更慢（下面的表），因为有的多跳分区被守卫提前停之后，`truncated` 把后续 frontier 拆成了额外的波。PROFILE 是 5 个 wave、17 条 host 回复，而基线是 3 个 wave、9 条。c=1 的 22.3ms 仍和基线 21.4ms 同一档。

---

## 3. 集群

3 meta + 3 storaged + 1 graphd。桥上 graph → `10.88.0.21`，20 包 0 丢：0.017 / 0.021 / 0.078 / 0.013 ms。延迟转发器上同一对：5.246 / 5.463 / 7.650 / 0.505 ms（有一包 7.65ms）。

9 part，社区 300，种子 7。预热 3。c=1 是 8 个样本，c=10 是 80，c=50 是 400。错误数 0，终点和生成器一致。`local_multihop_test` 34 条全过。静态 tck：`{10,12}`、`{7,9,10,12,15}`、空、`{7,9,15}`，WHERE 那句没有 `applied`。

五路：baseline、static（守卫关）、v1（整句）、v2（一分区一次 RPC，不用心跳先验）、v3（按 leader 合并，用心跳先验）。

---

## 4. 约 5ms，c=1

| 放置 | 模式 | P50 | P99 | QPS | waves | hosts |
|------|------|-----|-----|-----|-------|-------|
| affinity | baseline | 21.824 | 25.613 | 20.10 | 3 | 9 |
| affinity | static | 7.587 | 14.218 | 34.21 | 1 | 3 |
| affinity | v1 | 7.403 | 16.251 | 33.94 | 1 | 3 |
| affinity | v2 | 7.457 | 21.293 | 28.98 | 1 | 9 |
| affinity | v3 | 17.944 | 22.577 | 25.05 | 3 | 6 |
| random | baseline | 21.416 | 23.635 | 21.32 | 3 | 9 |
| random | static | 27.835 | 32.315 | 17.83 | 4 | 12 |
| random | v1 | 22.059 | 26.228 | 20.64 | 3 | 9 |
| random | v2 | 30.909 | 34.773 | 18.18 | 3 | 9 |
| random | v3 | 24.078 | 35.810 | 18.62 | 3 | 9 |
| mixed | baseline | 21.433 | 22.064 | 21.46 | 3 | 9 |
| mixed | static | 25.916 | 30.518 | 18.14 | 4 | 10 |
| mixed | v1 | 19.494 | 22.187 | 23.07 | 3 | 9 |
| mixed | v2 | 20.426 | 26.198 | 21.57 | 3 | 12 |
| mixed | v3 | 22.329 | 32.829 | 19.46 | 5 | 17 |

v3 亲和的 PROFILE 是 `multi_parts=8 base_parts=1`，3 条 `applied`（三台 storaged 各一次多跳），同时还有 1 个分区在基线，所以整句是 3 个 wave、6 条 host 回复。9 个分区各 5% 探索时，一条查询里至少有一个分区走基线的概率大约是 `1-0.95^9`。那一分区把整句拖回 3 次往返。c=1 只有 8 个样本，P50 被拉到 17.944ms，**没有**回到静态的 7.6ms。c=10 的 P50 是 10.818（v1 是 9.569，v2 是 11.850），c=50 是 12.090（v1 9.492，v2 13.628）。漂移里 `multi_parts=9` 且 `rpc=1` 的亲和查询 P50 约 7.1–7.2ms，那才是「九个分区都走多跳、每台机器一次 RPC」的时延。

随机 v3 的 PROFILE 是 `multi_parts=6 base_parts=0`、3 条 applied、3 个 wave。心跳先验没有把它留在基线上：前缀上的 64 条边比这次查询更像本地，先验高于 0.6，streak 被盖掉，每条查询都再试多跳。守卫把 wave 数保持在 3，P50 24.078，介于基线 21.416 和静态 27.835 之间。v1 是 22.059，更接近基线。

mixed v3 的 PROFILE 是 5 个多跳分区、2 个基线分区、3 条 `steps_done=3` 的 applied，外加 5 个 wave。c=1 P50 22.329，和基线 21.433 接近。c=10 是 49.333，c=50 是 52.653，基线同一档是 28.224 和 29.529。多出来的波在 c=10 以上被放大了。

---

## 5. 桥，c=1 P50

亲和：基线 2.868，静态 2.314，v1 1.914，v2 2.284（9 host），v3 2.454（3 host，`multi_parts=9`，3 条 applied，1 wave）。这里 v3 的 host 回复数和 v1 一样是 3。c=50：v1 1.926，v2 2.492，v3 2.410。

随机：基线 2.760，静态 4.288，v1 2.970，v2 3.397，v3 3.315。v3 仍是 `multi_parts=6`，3 wave。

mixed：基线 2.701，静态 3.444，v1 2.923，v2 2.937（12 host），v3 3.098（16 host，5 wave）。近零 RTT 上多出来的波只有大约 0.4ms。

---

## 6. 切回多跳用了几条查询

换边之后、开始「返回亲和」之前，v3 睡了 **8 秒**，给抽样（2 秒）和两次心跳（各 2 秒）留时间。这 8 秒不是查询，算在方法里。

约 5ms，v3 返回阶段 16 条全部正确。**第 1 条**就是 `choice=multi multi_parts=9 rpc=1`，客户端 10.151ms。后面的窗里 P50 降到 8.7ms（6 条里 4 条是完整多跳，2 条还有分区在探索）。v2 同一次设置、不用心跳先验、返回阶段 24 条：结束时仍是 `mixed multi_parts=5 rpc=3`，没有出现 `multi_parts=9`。

桥上 v3 返回阶段的第 1 条也是 `multi_parts=9 rpc=1`，客户端 3.780ms。随机阶段在大约 10 条里从 mixed 落到 `base`、`rpc=3`。

v1 在约 5ms 的随机阶段 20 条里，前 10 条有 8 条仍是 multi（`early=1 rpc=3`），后 10 条 6 条 multi、4 条 base。没有做 v1 的换回。

---

## 7. 边界

- c=1 亲和 v3 的 17.9ms 是测到的，不是 7.3ms。稳定靠近 v1 的是 c=10 的 10.8ms，以及漂移里九个分区都选多跳时的约 7.1ms。
- 心跳样本是前缀上的前 64 条边。随机图上它偏高，v3 不肯留在基线。守卫仍然把 wave 数限制在 3。
- mixed 的整句下界是基线分区的 3 次往返。v3 在 c=10/c=50 上因为额外的 wave 比基线慢。没有做跨波流水线。
- 样本表只在 meta leader 的内存里。leader 切换后要等下一轮心跳。
- 抽样 218 次的中位耗时是 577µs / 轮（30 part、1920 边）。这是 stor1 的日志，不是查询时延。
- `--local_multihop_assumed_rtt_us=5000` 仍是配置值。这次 ping 均值是 5.463ms。
