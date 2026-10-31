# 38 — 自适应多跳 v2：按源分区选，连续 hop-1 就改走基线

> v1 的守卫和整句 EWMA 在 [36](36-adaptive-multihop-design-impl.md)，整句实测在 [37](37-adaptive-multihop-bench.md)。
> 补丁 [`patches/v3.8.0-adaptive-local-multihop-v2.patch`](patches/v3.8.0-adaptive-local-multihop-v2.patch) 打在 `v3.8.0-adaptive-local-multihop.patch` 之上。
> 脚本仍是 [`bench/local_multihop/run_adaptive.sh`](bench/local_multihop/run_adaptive.sh)。这次的 JSON 前缀是 `bridge_*`、`rtt5_*`、`drift_v1_rtt5`、`drift_v2_bridge`、`drift_v2_rtt5`。
> 日期：2026-10-31。表里的数都是这次测到的。39 篇重跑覆盖了顶层同名 JSON；38 的表对应 `2b82ac2`。

v1 把整句 `GO` 收成一个形状键。混合图里亲和社区和打乱社区共用这个键，控制器只能选一边。37 篇的 mixed 因此停在基线，亲和的那一半也没有被收成一跳。漂移到随机之后，守卫把多跳延迟压到和基线一样，EWMA 还记着亲和时的 7ms，40 条查询都没改投基线。

v2 做两件事。起点按源分区切开，每个分区自己一条 EWMA，选多跳的分区和选基线的分区在同一波发出去。一个分区连续两次在第 1 跳被守卫拦住，下一次就走基线；一次完整的本地多跳（没有提前停，且 `local_ratio` 不低于阈值）把这个计数清掉，探索打中之后能切回来。

心跳里采样 per-part 本地比例仍然没做。冷启动还是乐观地试多跳，守卫兜底。

---

## 1. 分区怎么切

`partOfIntVid` 和 `MetaClient::partId` 对 8 字节整型 VID 同一条规则：`memcpy` 成 `uint64`，再 `vid % numParts + 1`。`partOfIntVid(0, 9) == 1`，`partOfIntVid(8, 9) == 9`。单测 `IntVidPartMatchesMetaRule` 锁这个。字符串 VID 或 `partition_num` 缺失时退回 v1 的整句键。

形状键 `AdaptiveShape` 加了 `part`。0 是整句（v1）。正数是源分区，分区之间不共享样本。

`fillPerPartJobs`（`LocalMultiHopDriver.h`）在 `ExpandExecutor::GetDstBySrc` 和 `ExpandAllExecutor::GetDstBySrc` 里、`--local_multihop_per_part=true`（默认）时调用：

- 选了多跳的分区**各自**一个 job。不能把两个分区塞进同一次 `GetDstBySrc`：一台 storaged 会把请求里的所有 part 合成一次 BFS，亲和 part 和随机 part 落在同一台机器上时，守卫看到的是混合比例，亲和 part 会被一起提前停。
- 选了基线的分区合成一个 job。单跳不跑守卫，合在一起就是基线的那一次扇出。
- 这些 job 都标 `parallel`。`driveDstWalk` 把栈顶连续的 parallel job 收成一批，`folly::collectAll` 一起等。批内共用一个 `step{N}`，所以 PROFILE 的 wave 数是往返次数，不是 RPC 个数。host 回复用 `step{N} resp [job*1000+i]`，避免下标撞车。

后续 frontier 不再 parallel。同一剩余跳数、同样 `allowMulti` 的继续 job 仍由 `mergeSameHop` 的同类逻辑合成，所以基线分区剩下的两跳还是每跳一次扇出。多跳分区如果走完了，不再占后面的波。`GO 3` 因此是：第 1 波并行（多跳分区在这一波里走完 3 跳，基线分区只走 1 跳），再加基线分区自己的 2 跳。往返次数和基线一样，是 3。多跳分区多出来的是同一波里的并发 RPC，不是多出来的一轮。

每个分区记自己的耗时：只累加它参加的那些波。不能把整句的墙钟记到亲和分区上，否则它会等到基线分区走完，EWMA 会以为多跳和基线一样慢。

PROFILE 的 `adaptive_choice` 是 `multi_parts=N base_parts=M`。`--local_multihop_trace` 打一行 `choice=multi|base|mixed multi_parts= base_parts= early_parts= rpc=`。`rpc` 是波次。

`--local_multihop_per_part=false` 时仍是 v1：一个 job，一个整句键，`choice=multi|base`。

---

## 2. 连续两次 hop-1 就改走基线

`AdaptiveConfig::earlyFlip` 对应 `--local_multihop_early_flip`，默认 true。关掉就是 v1 的延迟比较。

多跳样本里，`early_stop && continue_hop <= 1` 让 `hop1Streak` 加一，并用现有的 `--local_multihop_ewma_alpha`（默认 0.2）更新 `earlyRate`。`choose` 在冷启动判断之后：

- `hop1Streak >= 2`，或者 `earlyN >= 2 && earlyRate >= 0.5`：exploit 改成基线。这时多跳的延迟 EWMA 可能还停在亲和时的低值，不再用它压过这次证据。
- 一次多跳没有提前停，并且 `localRatio >= minLocalRatio`：`hop1Streak`、`earlyRate`、`earlyN` 立刻清零。下一次如果这条延迟低于基线，就切回多跳。

5% 探索还在。切回基线之后，要等一次探索打中、并且这次是完整的本地多跳，计数才会清掉。分区各自计数，所以切回来的是「多跳分区一个一个变多」，不是整句同时翻。

单测 `RepeatedHop1StopOverridesStaleLatency`：基线 22000µs、多跳 7000µs 时仍选多跳；一次 hop-1 还不翻；第二次 hop-1 之后即使延迟 EWMA 仍低于基线也选基线；再来一次比例为 1、没有提前停的样本，又选回多跳。另一个 `part` 的键是冷的。

`local_multihop_test` 32 条全过。静态 tck（`--enable_local_multihop=true --local_multihop_affinity=1`）四句终点和以前一样：`{10,12}`、`{7,9,10,12,15}`、空、`{7,9,15}`，WHERE 那句 `applied` 仍为假。

---

## 3. 集群

3 meta + 3 storaged + 1 graphd，`start_dist.sh`。9 part，社区 300，出度约 8，种子 7。边数和终点与 37 篇同一次装载：亲和 21523 边 / 2167 终点，随机 21537 / 2176，mixed 21546 / 2116。mixed 的偶数社区在一个 part 上，奇数社区只在奇数 part 的 vid 池里打乱。

预热 3，然后 c=1 记 8 次，c=10 记 80，c=50 记 400。错误数 0。终点和 `gen_data.walk` 一致。

桥上 graph → `10.88.0.21`，20 包 0 丢：min/avg/max/mdev = 0.024 / 0.160 / 2.632 / 0.566 ms。平均被一包 2.6ms 拉高了；同一次 stor1 → stor2 是 0.023 / 0.032 / 0.084 / 0.015 ms。延迟转发器上 graph → stor1，20 包 0 丢：5.167 / 5.375 / 5.597 / 0.091 ms。

四路：baseline、static（affinity=1，守卫关）、adaptive-v1（`per_part=false early_flip=false`）、adaptive-v2（两个旗标都开）。`--local_multihop_assumed_rtt_us=5000` 仍是配置值，不是这次 ping。

---

## 4. 约 5ms，c=1

| 放置 | 模式 | P50 | P99 | QPS | waves | hosts | 决策 |
|------|------|-----|-----|-----|-------|-------|------|
| affinity | baseline | 21.517 | 24.327 | 20.59 | 3 | 9 | |
| affinity | static | 7.359 | 13.951 | 34.48 | 1 | 3 | 1 次多跳，ratio=1 |
| affinity | v1 | 7.277 | 14.682 | 33.97 | 1 | 3 | multi |
| affinity | v2 | 9.678 | 21.487 | 30.61 | 1 | 9 | multi_parts=9 |
| random | baseline | 22.501 | 26.288 | 20.19 | 3 | 9 | |
| random | static | 28.267 | 29.111 | 17.90 | 4 | 12 | 守卫关 |
| random | v1 | 22.946 | 27.217 | 19.99 | 3 | 9 | base |
| random | v2 | 23.127 | 36.224 | 18.40 | 3 | 9 | multi_parts=0 base_parts=6 |
| mixed | baseline | 22.044 | 24.512 | 20.51 | 3 | 9 | |
| mixed | static | 26.112 | 27.197 | 18.69 | 4 | 10 | 守卫关 |
| mixed | v1 | 22.771 | 25.796 | 20.74 | 3 | 9 | base |
| mixed | v2 | 20.674 | 24.141 | 22.19 | 3 | 12 | multi_parts=5 base_parts=2 |

v2 的亲和是 9 个分区各一次多跳，9 条 `applied=1 steps_done=3 local_ratio=1`，仍是 1 个 wave。P50 9.678ms，比 v1 的 7.277ms 多大约 2.4ms，是 9 次并发 RPC 的开销，不是多一轮往返。相对基线 21.5ms 还是快的。c=10 / c=50 的 P50：v2 11.672 / 12.201，v1 9.326 / 9.356，基线 29.840 / 28.963。

随机的 9 个种子落在 6 个分区上（VID 撞 part）。v2 这 6 个都选了基线，3 wave、9 host，P50 23.1ms，和基线 22.5、v1 22.9 同一档，低于静态 28.3。c=1 的 P99 36.2ms 高于基线的 26.3，8 个样本里夹了探索。c=50 的 P50 是 33.519，基线 30.334，静态 41.448。

mixed 的 PROFILE 有 5 条 `steps_done=3 local_ratio=1`，对应 5 个偶数社区；另外 2 个分区走基线（4 个奇数种子撞进了 2 个 part）。整句仍是 3 个 wave。查询要等基线分区走完，所以 P50 是 20.7ms，不是亲和的 7ms。它低于静态的 26.1ms，和基线 22.0ms 同一档。v1 整句是 `base`，那 5 个社区没有多跳记录。

c=10 的 mixed P50：基线 29.590，静态 36.214，v1 28.130，v2 31.212。c=50：29.584 / 37.335 / 29.438 / 30.948。v2 没有比基线更快，也没有掉进静态那一档。

---

## 5. 桥

graph→stor1 的平均被一包拉到 0.160ms，不要把它当成稳定的 0.02ms。c=1 的差仍是 1ms 上下。

c=1 P50：亲和基线 3.018，静态 2.319，v1 2.224，v2 2.478（1 wave，9 host，9 条 ratio=1）。随机基线 3.106，静态 4.119，v1 3.179，v2 3.724（3 wave，base_parts=6）。mixed 基线 2.918，静态 3.326，v1 3.447，v2 2.937（3 wave，multi_parts=5，5 条 `steps_done=3`）。

c=50 亲和 P50：基线 2.880，静态 1.811，v1 1.866，v2 2.591。v2 的 9 次并发 RPC 在这档能看出来，仍是 1 个 wave。

---

## 6. 漂移，两个方向

同一 space、同一条 `know`、同样 3 跳。先亲和，再删边换成随机放置，再删边换回亲和。没有隐藏预热。延迟是客户端 `latency()`。`choice` / `multi_parts` / `rpc` 来自该条查询的日志。终点全部对过。

### v1，约 5ms

12 条亲和里 10 条 multi、`rpc=1`，P50 约 7.2–7.4ms；2 条是探索出来的 base，21.7ms 和 21.9ms。

换成随机之后的 20 条：前 10 条里 9 条仍是 multi，但 `early=1`、`rpc=3`，P50 24.1ms；后 10 条变成 7 条 base、3 条 multi，P50 23.3ms。整句键要等延迟 EWMA 爬过基线样本才翻，前一半还停在多跳上。这次没有做 v1 的换回。

### v2，约 5ms

16 条亲和：`multi_parts` 在 9 和 7–8 之间，因为 5% 探索会让一两个分区去试基线。`rpc=1` 的那些 P50 在 7.1–9.8ms；探索把分区打成 base 时 `rpc=3`，延迟 19–26ms。窗 P50 14.7ms 然后 7.1ms。

换成随机（6 个分区）的前几条还是 multi 或 mixed，并且 `early_parts>0`、`rpc=5`（多跳分区被守卫拦住后再并进基线的后续跳，比纯基线多波）。从第 5 条起多数是 `choice=base multi_parts=0 rpc=3`，延迟 20–28ms。中间夹着探索：`multi_parts=1`、`rpc=5`、34–38ms。24 条里后半段以 base 为主。比 v1 的前 10 条仍有 9 条 multi 更快落到基线。

换回亲和的 48 条，`multi_parts` 从 2 往上走，`rpc` 保持 3，P50 停在 21–22ms，因为还有分区在基线、整句要等它们：

| 返回查询 | multi_parts | 客户端延迟 |
|----------|-------------|------------|
| 1 | 2 | 22.4ms |
| 11 | 4 | 22.2ms |
| 27 | 7 | 22.9ms |
| 31 | 8 | 19.2ms |
| 43 | 9 | 7.1ms |
| 44–46 | 9 | 7.5 / 7.1 / 7.7ms |

第 43 条起 9 个分区都是多跳，`rpc=1`。第 47 条又有一个分区被探索打去基线（`multi_parts=8`，19.0ms），第 48 条回到 9 和 7.6ms。切回是分区自己的探索攒出来的，不是同一条查询里 9 个分区一起翻。最后 8 条的窗 P50 是 7.665ms。

### v2，桥

随机阶段同样在几条之内从 `multi_parts=6` 落到 `base`，P50 3.6ms 然后 3.3ms。`rpc=5` 的探索大约 4ms。换回的 40 条 `multi_parts` 从 3 升到 8，没有到 9，`rpc` 一直是 3，P50 从 3.4ms 降到 2.9ms。近零 RTT 下多一轮不那么显眼，40 条不够把最后一个分区探回来。约 5ms 那 48 条才看到 `multi_parts=9` 和 7ms。

---

## 7. 没做的和边界

- 心跳采样仍是 36 篇第 8 节的设计，没有进代码。冷启动每个没见过的分区都会试一次多跳。
- v2 亲和比 v1 多大约 2ms（c=1，约 5ms RTT），因为每个分区一次 RPC。往返仍是 1。分区很多时这批并发 RPC 会比一次扇出重；这次图是 9 个 part。
- mixed 整句的延迟由最慢的那组决定。亲和分区走完 3 跳并不能把整句变成 7ms，只要还有分区在基线。证据是 PROFILE 里的 5 条 `steps_done=3`，不是 P50。
- 随机种子会撞 part。这次 9 个种子在 6 个分区上，PROFILE 的 `base_parts=6` 是这个原因。
- 换回亲和要等每个分区自己的 5% 探索。约 5ms 用了 43 条才到 `multi_parts=9`。桥上 40 条停在 8。
- 桥上 graph→stor1 的 ping 平均 0.160ms，里面有一包 2.632ms。查询表是另外测的。
- `--local_multihop_assumed_rtt_us=5000` 不是 5.375ms 这次 ping 拟合出来的。两臂都有样本时不用它。
