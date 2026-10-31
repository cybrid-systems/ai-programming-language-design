# 36 — 自适应本地多跳：逐跳守卫和 EWMA

> 静态多跳是 [34](34-local-multihop-impl.md)，它的亲和收益和随机放置回退在 [35](35-local-multihop-bench.md)。实测在 [37](37-adaptive-multihop-bench.md)。按源分区拆开、并在连续 hop-1 提前停后改走基线，是 [38](38-adaptive-multihop-v2.md)。
> 补丁 [`patches/v3.8.0-adaptive-local-multihop.patch`](patches/v3.8.0-adaptive-local-multihop.patch) 打在 `v3.8.0-local-multihop.patch` 之上，基线仍是 `fa928930`。
> 日期：2026-10-31。

35 篇里静态多跳把亲和图的 3 跳收成 1 次 RPC，约 5ms RTT 下 P50 从 24.4ms 降到 7.3ms。同一开关在随机放置上把远程边界按深度拆开，graphd 再对每一层发多跳，P50 从 24.2ms 涨到 83.5ms。分布事先不知道时，不能靠 `--local_multihop_affinity=1` 常开。

这一层做两件事。storaged 在每一跳上看「dst 的 leader 在不在本机」，比例低于阈值就停，把这一跳的全部 dst 交回，graphd 从这里改走单跳。graphd 按查询形状记两条路径的延迟，用样本决定下一次发多跳还是单跳，并用一小部分请求去探另一条路径。冷启动先试多跳，守卫是兜底。

心跳里上报每个 part 的本地 dst 比例没有做，只写在第 8 节。

---

## 1. 守卫算在哪

`runLocalMultiHop`（`src/common/algorithm/LocalMultiHop.h`）多了一个参数 `minLocalRatio`，默认 0。小于等于 0 时行为和 34 篇的静态多跳一样，随机图仍会走出那棵远程树。自适应路径把阈值放进请求。

一跳扫完之后，分母是这一跳去重后的 dst，分子是其中 leader 在本机的那些。起点本身不是本跳的 dst：扫描循环里 `!isLocal(vid)` 的 frontier 记在 `remote_depth = step-1`，不进入这个比例。同一条边指向同一个 dst 只算一次，和 `GetDstBySrc` 的跳内去重一致。

```
hopRatio = |local unique dsts| / |local unique dsts ∪ remote unique dsts|
```

`minLocalRatio > 0`、`hopRatio < minLocalRatio`、并且 `step < maxSteps` 时提前返回：

| 字段 | 值 |
|------|----|
| `earlyStop` | true |
| `continueHop` | 刚走完的 `step`（1-based） |
| `stepsDone` | 同一个 `step` |
| `truncated` | true |
| `carry` | 这一跳的全部 dst，本地和远程都在里面 |
| `remoteVids` | 只留下更早深度的远程边界。本跳的远程 dst 已经挪进 `carry`，避免同一批点被排进两个 wave |
| `yielded` | 仅当 `step >= minYield`。`GO n STEPS` 的 `minYield` 是总跳数，提前停下的中间层不进结果 |

最后一跳不提前停。那些 dst 已经是结果，再标一层「从这里继续」只会多一次往返。

`localRatio` 是所有「有 dst 的跳」里最小的那个比例，空跳不更新。`hasLocalRatio` 为假时响应里不带 `local_ratio`。

`truncated` 沿用 34 篇的约定：`consumeLocalMultiHop` 看到它就把后续 wave 的 `allowMulti` 置假。graphd 不需要第二条恢复协议。`GO 3 STEPS` 在第 1 跳被守卫拦住时，是 1 次多跳 RPC（只扫了 1 跳）加 2 次单跳，波次和基线相同，不会长出 13 个 wave。

比例刚好等于阈值时继续走。`0.6` 不拦 `3/5`。

高比例、但每一跳仍有少量远程时，守卫不触发。那些远程仍按深度交回，下一台 storaged 自己再算比例。随机图在第 1 跳就会低于 0.6，走不到这棵树。混合请求如果整批 dst 的比例低于阈值，这一整次 RPC 都在第 1 跳停，亲和的那部分也不会被多跳吃掉。这是按请求而不是按社区切的，第 7 节写了后果。

同一 VID 出现在两个深度时仍然都要展开。守卫把本跳的本地 dst 和远程 dst 一起放进 `carry`，更早深度的远程留在 `remote_vids`。单测 `EarlyStopKeepsEarlierRemoteAndBothDepths` 和 `EarlyStopMatchesSingleHopOnTwoDepths` 用 `1→2→4→5` 与 `1→4→5→6` 对过：只留远程 `4` 会丢掉 `5`，守卫把 `2` 和 `4` 都交回之后，单跳重放的终点和全程单跳一致。`minLocalRatio=0` 的旧路径也和全程单跳一致。

---

## 2. 协议

仍是 `GetDstBySrc` 的可选字段，不是新 RPC。旧 storaged 丢掉未知字段，响应里没有 `multihop_applied`，graphd 把那次回复当成一跳。

`GetDstBySrcRequest` 增加：

- `9: optional double min_local_ratio`。缺省或 `<=0` 关闭守卫。

`GetDstBySrcResponse` 增加：

- `9: optional bool early_stop`
- `10: optional i32 continue_hop`
- `11: optional double local_ratio`

`GetDstBySrcProcessor::runMultiHop` 读 `min_local_ratio_ref().value_or(0)`，传给 `runLocalMultiHop`。扫完后置 `early_stop`。只有真的提前停才置 `continue_hop`。只有算过比例才置 `local_ratio`。`storaged_accept_local_multihop=false` 时仍不进 `runMultiHop`，这三个字段都不会出现。

`StorageClient::getDstBySrc` 多了一个参数，默认 0。只有 `maxSteps > 1` 才把 `min_local_ratio` 写进请求。单跳调用点不用改。

graphd 在 `LocalMultiHopDriveBody.inl` 里如果看到 `early_stop`，把这次回复强制当成 `truncated`。即使 storaged 漏了 `truncated`，也不会把这个 frontier 再送回多跳。PROFILE 字符串在 34 篇的基础上加上 `early_stop`、`continue_hop`、`local_ratio`。

---

## 3. 谁来选路

形状键是 `AdaptiveShape`：`space`、排序去重后的 `edgeTypes`、`steps`、`yieldAll`。`GO n STEPS` 的 Expand 只产出终点，`yieldAll=false`，`steps=maxSteps`。`GO m TO n` 的 ExpandAll 在没有点属性、边属性时 `yieldAll=true`，`steps = maxSteps-minSteps+1`。

3.8 的 `Expand` 节点上没有 tag。简单 GO 的区分度就是 space 和边类型。两个 space 同名边不共享样本。进程内的 `std::map` 加一把锁，不进 meta，graphd 重启就是冷启动。多 graphd 之间也不共享。

`planLocalWalk` 在 `ExpandExecutor::GetDstBySrc` 和 `ExpandAllExecutor::GetDstBySrc` 入口各调用一次。自适应开关打开时，它取代静态 affinity 门，不再看 `--local_multihop_affinity`。静态开关仍走原来的 `shouldLocalMultiHop`，并且发出去的 `min_local_ratio` 是 0，这样 35 篇的回归还能复现。两个开关同时开时自适应优先。`hopsLeft<=1`、frontier 为空或超过 `local_multihop_max_frontier` 时两边都不进 driver，原样走单跳循环。

自适应选了单跳时也进 driver，但 `choseMulti` 为假，每一跳 `reqSteps=1`。后续 wave 即使被 `consume` 标成 `allowMulti`，也会被 `choseMulti` 挡住，不会在同一次查询中途改去多跳。这样记到的延迟是整次查询，不是第一跳。只给第一跳计时的话，第 1 跳就被守卫拦住的多跳会看起来比完整的 3 跳基线更便宜。

`GetDstBySrc` 一次调用会按 leader 扇出。每个 host 的回复如果各变成一个 job，driver 又是串行的，3 跳基线会变成十几次往返。`mergeSameHop` 把剩余跳数和 `allowMulti` 都相同的 frontier 合成一个 job，下一跳仍是一次扇出。深度不同的远程边界不合并，静态多跳的那棵树还在。单测 `SameHopFromSeveralHostsIsOneJob` 锁住这件事。

一次查询结束（`driveDstWalk` 的 job 队列空了，而且 `handleCompleteness` 成功）才 `observe`。失败和超时不进 EWMA。记的是 `time::Duration` 从 state 构造到结束的微秒，包含这次 walk 的全部 RPC，不包含 parse。两条臂用同一把尺子。客户端看到的 `ResultSet.latency()` 还含 parse 和序列化，比这个数大，压测表用的是客户端的数。

选了多跳但没有任何 `multihop_applied`（旧 storaged，或 accept 旗标关掉）时，按「第 1 跳就被守卫拦住、没有比例」来记。下一次在只有多跳样本的情况下会改走基线。

`--local_multihop_trace=true` 时每个成功的自适应查询打一行 `adaptive_multihop choice=... walk_us=... ratio=... early=... hop=... rpc=...`。`rpc` 是这次 walk 的波次。漂移脚本靠它和客户端延迟对齐，所以那次运行还加了 `--logbufsecs=0`。默认关闭。

---

## 4. 代价模型

`AdaptiveController::choose` 先算 exploit，再按 `exploreRate` 翻转。`draw` 是 `[0, 1)` 上的均匀数。`draw < exploreRate` 时走另一条臂。默认 `exploreRate=0.05`。

样本是 EWMA，`alpha` 默认 0.2。第一条样本直接当均值。

| 样本 | exploit |
|------|---------|
| 两臂都没有 | true。冷启动试多跳，守卫兜底 |
| 两臂都有 | `multiLat + 1 < baseLat`。平手走基线，避免白付多跳的组包 |
| 只有多跳，并且上次在第 1 跳提前停 | false。省下的往返是 0，和基线打平，少做那点簿记 |
| 只有多跳，并且在更后面的跳提前停 | 省下的往返是 `continueHop-1`，收益是 `saved * rtt`，开销按 `0.05 * rtt`。收益更大就留下 |
| 只有多跳，守卫没触发 | `saved = (steps-1) * localRatio`，远程边带回来的额外 wave 按 `(1-localRatio)*(steps-1)`。收益大于额外 wave 才留下。`rtt` 在两边，只要是正数就约掉 |
| 只有基线 | true。分布可能已经变了，再试一次多跳，守卫仍在 |

`--local_multihop_assumed_rtt_us` 默认 5000。它只在「只有一条臂有延迟样本」时进入上面的乘积，**不是测到的 RTT**。两臂都有样本之后，比较的是测到的 EWMA，这个旗标不参与。

第 1 跳就被拦住、而且已经有过基线样本时，走表的第一行：谁的 EWMA 低用谁。亲和阶段留下的多跳均值要被新的、接近基线的样本拉上去才会翻。`alpha=0.2` 时大约十几条查询，具体看两条曲线的距离。翻之前守卫已经把随机图按在基线的波次上，不会先付出 35 篇那种 13 wave。

探索是分布从基线漂回亲和时的另一条路：大部分请求停在基线上，约 5% 再试多跳。试中了，多跳 EWMA 下降，下一次 exploit 就切回来。

---

## 5. 开关

| flag | 默认 | 作用 |
|------|------|------|
| `--enable_adaptive_local_multihop` | false | graphd 按形状选路。开了就不再看 affinity |
| `--local_multihop_min_local_ratio` | 0.6 | 自适应多跳请求里的守卫阈值。静态多跳固定送 0 |
| `--local_multihop_explore_rate` | 0.05 | 走另一条臂的概率 |
| `--local_multihop_ewma_alpha` | 0.2 | 新样本的权重 |
| `--local_multihop_assumed_rtt_us` | 5000 | 单臂代价模型里的往返替身，不是实测 |
| `--local_multihop_trace` | false | 每条自适应查询打一行日志 |
| `--enable_local_multihop` | false | 34 篇的静态门，没变 |
| `--local_multihop_affinity` | 0 | 静态估计，没变 |
| `--storaged_accept_local_multihop` | true | false 时仍是旧 storaged |

PROFILE 里自适应查询多一个 `adaptive_choice=multi|base`。静态多跳没有这行。

---

## 6. 测试

`local_multihop_test` 在 34 篇的用例之外增加了守卫和控制器。守卫：

- 全本地、阈值 0.6，三跳不提前停，`localRatio=1`，终点和以前一样
- 1 个本地 dst、2 个远程 dst，第 1 跳停，`carry` 是这三个点且没有重复，`remote` 空，`consume` 得到 `hopsLeft=2`、`allowMulti=false` 的一个 wave
- 比例等于 0.6 不停，0.61 停
- `maxSteps=1` 不提前停，远程 dst 留在 `remote_vids`
- 阈值 0 关闭守卫
- 第 2 跳才停时，第 1 跳的远程边界还在，两个深度的同一个 VID 各有一个 wave
- `minYield=1` 时本跳 dst 进结果一次，不因为 `carry` 再复制一行
- 起点里混进一个非本地 VID 不拉低比例
- `1→2→4→5→6` 与 `1→4→5→6`：守卫重放和关守卫重放的终点都等于全程单跳 `{5,6}`

控制器：

- 冷启动 `draw=0.5` 选多跳，`draw=0` 被 5% 探索打成基线；`exploreRate=0` 不翻转，`1` 必翻转
- 不同 space 的形状不共享样本
- 只有多跳样本且停在第 1 跳时改走基线；补上一条一样慢的基线之后仍走基线
- 停在第 2 跳、或比例为 1 且没提前停时留在多跳
- 两臂都有时跟实测延迟：1000µs 对 5000µs 选多跳；再喂两条 20000µs（EWMA 1000→4800→7840）后改走基线；4000 对 4000 走基线
- 守卫没触发但比例只有 0.2 时，额外 wave 的估计大于省下的往返，走基线
- `planLocalWalk`：自适应打开且 affinity 为 0 仍进 driver；只有静态且 affinity 为 0 不进；静态 affinity 为 1 进 driver 但 `adaptive=false`；1 跳不进

`/tmp/nebula-380/build/bin/test/local_multihop_test` 上 30 条全过。

`tests/tck/features/go/LocalMultiHop.feature` 仍是静态旗标那四句，不打开自适应。单机上每个 part 的 leader 都是同一个 storaged，守卫不会触发，tck 覆盖不了提前停。提前停的正确性在单测的重放里，分布式上的终点集合在 37 篇和生成器逐个 vid 对过。

---

## 7. 和「按社区各走各的」之间的差距

守卫和 EWMA 的粒度都是一次 RPC、一个形状。`GO 3 STEPS FROM` 把每个社区的种子放进同一句时，一台 storaged 收到的是「自己 leader 的那些起点」混在一起的 frontier。亲和社区和随机社区落在同一台机器上时，比例按这一整批算。低于 0.6 就整批在第 1 跳停，亲和社区也拿不到多跳。高于 0.6 就整批继续，随机社区的远程边界还在。

形状键也不分种子。同一个 space、同一条边、同样的跳数，亲和查询和随机查询共用一条 EWMA。漂移实验利用的就是这一点。生产里如果两种分布共用一个形状，控制器会收敛到测到的平均延迟，不会同时给两种分布各一个最优。

静态路径故意不送阈值，深度不同的远程边界仍然各走一趟，不会被守卫收掉。同一深度上多个 host 的回复会被 `mergeSameHop` 合成一个 frontier，所以 35 篇那种「每个 host 一个串行 job」的 13 wave 不会原样出现。35 篇的 83.5ms 是合成之前的二进制。这一版静态随机的波次和时延以 [37](37-adaptive-multihop-bench.md) 的重测为准。

---

## 8. 心跳采样（没做）

storaged 已经按 `--heartbeat_interval_secs` 向 meta 发心跳（`HBProcessor`）。可以在这台机器担任 leader 的每个 part 上，后台扫固定条数的出边，用和守卫相同的 `partId` 规则算「dst leader 在本机」的比例，把 `(space, part) -> ratio` 附在心跳里。meta 存最新值，graphd 经现有的 meta 缓存读出来，当作该 space 的先验：最低 part 的比例已经低于阈值时，冷启动不必先乐观地试一次多跳。

没做的原因：现有心跳的负载是主机状态，不是查询统计；采样要读 RocksDB，和查询抢 IO；leader 切换之后旧值会撒谎；漂移时心跳比 EWMA 更钝。守卫已经把错误的多跳按在基线的波次上，这条先验只省掉冷启动的那一次。真要做的话，字段必须是心跳的可选附件，旧 meta 忽略它，和 `GetDstBySrc` 这组可选字段同一条兼容规则。
