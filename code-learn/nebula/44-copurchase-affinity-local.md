# 44 — 亲和感知的共同购买下推

> 叠在 [43](43-copurchase-pushdown-prod.md) 的 v2 上。v2 本身叠在 v5（[41](41-adaptive-multihop-v5.md)）。补丁 [`patches/v3.8.0-copurchase-affinity.patch`](patches/v3.8.0-copurchase-affinity.patch) 用 `patch -p1` 打在那棵树上。
> 日期：2026-11-02。时延、QPS、ping、RPC、payload、veth 字节、jiffies、RSS、重叠都是这次测到的。没有测到的格子写未测，不估成表内数字。

查询仍是 `COPURCHASE FROM <uid> WINDOW <start>, <end>`。排序定义和 42、43 相同。多出来的是：图按 VID 把一个社区放进同一个 part 时，整条链（hop1、hop2a、剪枝、hop2b、hop4）在那台 storaged 上跑完；统计量不够或运行时证明失败时，不采用这份结果，回到 v2 的多相位合并。拆到多台机器时，每台可以按上界丢掉不可能进 top15 的买家。

`--copurchase_affinity` 默认关。关掉以后语句、RPC 和剪枝都是 v2。`NOAFFINITY` 在旗标开着时把这一次退回 v2。

---

## 1. 分片规则和放置

`MetaClient::partId`（`src/clients/meta/MetaClient.cpp`）对 8 字节 vid 把字节拷进 `uint64_t`，再 `vid % numParts + 1`。正的 int64 小端存储就是这个整数。出边写在源点的 part 上，入边写在目标点的 part 上。`Copurchase.h` 的 `partOfInt64` 是同一条规则，单测对 1、3、9、16 个 part 对过。

不改这个函数。改了以后已有 key 的 part 前缀全错，等于把每个 space 重写一遍。放置只选 vid：

```
affinityVid(seq, partIndex, numParts) = seq * numParts + partIndex
```

`partIndex` 从 0 起，得到的 part 是 `partIndex + 1`。`seq` 在用户和商品之间不共用，避免两个点撞 vid。一个社区用一个 part。平衡之后一个 part 只有一个 leader，所以这个社区的用户、他们的出边、商品、商品的入边和 `sales` 都在同一台 storaged 上。

迁移成本是换 vid，不是换分片函数。已有数据要删掉再按新 vid 插入。没有在线把一个点从一个 part 搬到另一个 part 的路径。副本数、Raft group 的成员不变。

`bench/copurchase/generate_affinity.py` 用这个公式。`communities == parts == 9`。整数除法之后实际是 2997 个用户、297 个商品，不是 3000 和 300。

| 放置 | 边 | 跨社区边 | 种子 |
|------|----|----------|------|
| affinity | 17955 | 0 | 42 |
| random | 18520 | 565 | 42 |
| mixed | 18559 | 604 | 42 |

random 把同一批逻辑点的 vid 打乱。mixed 把偶数社区留在原 part，奇数社区在这些社区本来占用的 vid 里打乱，并且三种放置里只有 affinity 不加跨社区边。窗是 30 日 `[1759276800, 1761868800]`。7 日窗这次没跑。

热点商品的入边镜像见第 5 节。它不改变「单机完备只认 canonical part」这件事。

---

## 2. 什么时候尝试单机

`localityAllows`（`CopurchaseDriver.cpp`）在发 RPC 之前看 v5 的心跳样本。

1. `NAIVE`、`NOAFFINITY`、或 `--copurchase_affinity=false`：不尝试。日志 `reason=off`。
2. `--copurchase_affinity_force=true`：不看样本也尝试。这次压测没有开。
3. 否则读用户 part 上购买边的出边比例 `localDstRatioForEdges(space, part, {+edge})`。样本缺、过期、或小于 `--copurchase_affinity_min_ratio`（默认 1.0）就不尝试。负的 edge type 不再回退到 edge 0 的旧最小值，避免把出边比例当成买家覆盖率。
4. 出边比例过了以后，在这台 leader 负责的每个 part 上读负 edge type 的比例。那是入边里「买家的 part 也由本进程领导」的条数比。没有一份完成的负边样本就不尝试。有的话取最小值，再和同一个阈值比。

v5 的抽样只在 part 前缀走完时发布，比例是全量计数，不是蓄水池。蓄水池仍然不参与决策。抽样现在也数入边：正边的「本地」是目标点的 part，负边的「本地」是买家的 part。心跳字段 9 的最小值仍然只取正边，负边不把 v4 的最小值拉低。

过了门闩才发 `LOCAL_CHAIN`。storaged 上的证明和门闩是两件事。门闩用的是上一轮扫完的样本，中间可以插入新边。所以样本通过也不等于结果可用。

---

## 3. 单机链和运行时证明

`CopurchasePhase::LOCAL_CHAIN` 只收到用户 A 所在的 part。处理器自己算别的 vid 的 part，并且只读 `NebulaStore::isLeader` 为真的 part。

1. hop1：扫 A 的出边，窗是 `[window_start, window_end+1)` 的 rank range，和 v2 相同。`topProducts` 取 5。
2. 每个焦点商品的 part 必须由本进程领导。有一个不是，`local_stop=2`，`local_complete=false`，只带回这 5 个 id。graphd 从 hop2a 接着走，不用这份未完成的买家集。
3. 五个商品的入边都在本机时，`coCount` 就是并集的大小，`upper == lower`。`pruneCandidates` 和 43 篇是同一个函数。
4. 每个留下的买家：他的 part 在本机就扫他的出边，`scoreUser` 看到窗内每一条出边。有一个不在，`local_stop=3`，本机已算完的人带 `score_exact`，其余 id 放进 `remote_ids`。graphd 只对远程的人发 `FUSED_COCOUNT`，再 `mergeExact`。
5. 人都在本机时，销量是商品点上的 tag。part 不在本机的商品放进 `remote_ids`，`local_stop=4`。graphd 用 `HOP4_SALES` 补这些点，再按销量取 20。本地提前截成 top20 会丢掉一台远程机器上更高的销量，所以这里不截。
6. 全部 part 都在本机：返回前再查一次 `isLeader`。有一个丢了，清空行列，`local_stop=5`。graphd 把这次 RPC 丢掉，整句走 v2。

`local_complete` 只在 `local_stop=1` 时为真。graphd 还要自己做一次 guard：响应来自恰好一台 host，`touched_parts` 非空，并且 `StorageClient::getLeader` 对每个 part 都等于这台 host。对不上就丢弃，走 v2。storaged 在读的时候是 leader，graphd 在收的时候 leader 仍是它，两边都过才采用。

证明，在 guard 成立时：

- 出边只在源点的 part 上。A 的 part 由这台机器领导，hop1 的 range 覆盖闭区间窗，top5 是完整的。
- 入边只在商品的 part 上。五个商品的 part 都由这台机器领导，每个买家的焦点商品集合是完整的。`pruneCandidates` 在 `upper == lower` 时留下的集合包含全局 top15，论证和 43 篇相同。
- 留下的人的出边只在他们自己的 part 上，这些 part 也由这台机器领导。`scoreUser` 的 `purchaseCount` 和 `latestTs` 不需要和别的机器相加。`localTopUsers` 在这个超集上取 15，就是全局 top15。
- `sales` 是点属性，点在自己的 part 上。这些 part 都在本机，`localTopSales` 就是全局 top20。

`touched_parts` 是实际读过的 part。没读过的 part 不出现在证明里，也不能被算进完备。

单测 `AffinityProofAndCoarseEightSeeds` 用 8 个种子（1..8）在内存里放 9 个 part、3 台 host。没有跨 host 边时 `proveLocalChain` 为真；有跨 host 的焦点商品或买家时为假。这 8 个种子不经过 storaged。

---

## 4. 不能单机时的上界

`LOCAL_CHAIN` 停在 stop 2，或者门闩没过，hop2a 仍在各台 storaged 上扫本机的焦点商品。请求带上全部焦点 id，`parts` 里只有这台机器的商品。`missing = |焦点| - |本机商品|`。每个买家：

- `lower` = 本机看到的焦点商品数
- `upper` = `lower + missing`

`--copurchase_coarse` 或 `--copurchase_affinity` 打开、并且这次不是 `NOPRUNE` / `NOAFFINITY` 时，storaged 用 `coarseKeep`（就是 `pruneCandidates`）丢掉 `upper < threshold` 的人。`threshold` 是本机 lower 的第 15 高。

这个阈值不会高于全局第 15 名的真实 `coCount`：本机的 lower 都不超过那个人的真实次数，一个子集的第 k 高也不会超过全集的第 k 高。于是 `upper < threshold` 的人真实次数也到不了全局第 15。打平的留下。各机留下的人的并集包含全局 top15。一个人如果真实次数够高，他在每一台看到他的机器上 `upper` 都至少是这个次数，那些机器都不会丢他，他的商品 id 也都会报上来。graphd 上原来的 `pruneCandidates` 还在，用的是这些报上来的并集。

一台机器没回来时不能把 missing 当成 0。现有的失败路径不发被截断的请求：`limit_hit`、RPC 失败都走 43 篇的失败策略。

`NOAFFINITY` 不置 `coarse`。那一次的 hop2a 和 v2 相同，一个人都不在存储层丢。

---

## 5. 镜像为什么不能单独当证明

`--copurchase_mirror_in_edges` 默认关。打开以后，正边的写入在源 part 的同一批 KV 里多写一把 `kKeyValue` 键，顺序是边类型、商品、rank、用户。删除正边时把同一把键删掉。它和出边在同一个 Raft group 里，对本 part 的买家是完整的。

它不是商品 part 上的入边。别的 part 的买家不在这把键里。跨 part 再复制一份入边要进另一个 Raft group，不能和原边一次提交，读到的可能是半份。所以 `LOCAL_CHAIN` 不读镜像。单机完备只读 canonical 的出边、入边和点。镜像的单测只检查同一商品的两把键共享前缀。

这次压测把旗标打开了，用来确认插入和删除能编过、能写入。结果表不依赖它。

---

## 6. 旗标和计数

| 旗标 | 默认 | 作用 |
|------|------|------|
| `copurchase_affinity` | false | 样本够高时尝试 `LOCAL_CHAIN`，并打开 hop2a 的上界剪枝 |
| `copurchase_affinity_force` | false | 不看样本也尝试。guard 仍在 |
| `copurchase_affinity_min_ratio` | 1.0 | 出边比例和买家覆盖率的下限。1 表示计到的边的另一端都由同一台 storaged 领导 |
| `copurchase_coarse` | false | 只打开 hop2a 的上界剪枝，不尝试单机链 |
| `copurchase_mirror_in_edges` | false | 源 part 上的商品倒排。不参与精确结果 |
| `NOAFFINITY` | 语句 | 这一次退回 v2，包含关掉存储层剪枝 |

原有的 `enable_copurchase`、限额、`copurchase_failure_policy`、`local_multihop_prior_stale_ms`、`local_multihop_prior_per_entry` 不变。这次压测把 `prior_stale_ms` 设成 120000，心跳间隔 2 秒。抽样是 1 秒一 tick、每 tick 最多 8192 条边、预算 3000µs、最多 3 个 part。

计划行在 43 篇的字段后面加：

```
affinity=1 stop=1 reason=stats ratio=1 cov=1 rpc=1 payload=1484
```

`rpc` 是这句打到 storaged 的次数，含被 guard 丢掉的那次。`payload` 是请求和响应里整数字段的字节，不是 TCP，也不是 veth。`reason` 取值：`off`、`stats`、`force`、`ratio`、`cov`、`no_ratio`、`no_cov`、`guard`、`not_applied`、`stop`、`parts`、`leader`。

graphd 计数：`num_copurchase_local`、`copurchase_rpc`、`copurchase_payload_bytes`，加上 43 篇已有的。storaged：`copurchase_local_complete`、`copurchase_coarse_pruned`，加上原有的扫描和限额计数。

### 灰度

1. 先升 storaged。`LOCAL_CHAIN` 是新相位，旧 graphd 不发。负边样本多占心跳字段 10 的一条，字段 9 的最小值仍只含正边。镜像默认关。
2. 再升 metad。它只是转发多出来的负边条目。
3. 最后升 graphd，`--copurchase_affinity=false`。行为是 v2。
4. 在一个 space 上打开 affinity。用 `NOAFFINITY` 和默认各对一批已知用户，商品列表必须一致。`reason=stats` 且 `stop=1` 的句子才是单机结果。
5. 回滚：graphd 关 `copurchase_affinity`，或在语句上加 `NOAFFINITY`。已经写进 meta KV 的比例留着，不挡 v2。

---

## 7. 集群

3 meta + 3 storaged + 1 graphd，`bench/scenario2/start_dist.sh`。9 个 part，副本 1。二进制是 `fa928930` 加上 v5、copurchase v2 和本补丁。`CLK_TCK=100`。

桥上 graph namespace → `10.88.0.21`，时延表那一轮之后的 20 包 0 丢：`0.029 / 0.048 / 0.059 / 0.008` ms。文件 `results/affinity/ping-bridge-rerun.txt`。

`usdelay 2.5` 之后同一路径 20 包 0 丢：`5.158 / 5.421 / 6.184 / 0.224` ms。文件 `ping-rtt5.txt`。主机到 graphd 的路径在 usdelay 之后从桥上拆开，客户端改在 `ns-graph1` 里连 `127.0.0.1:9669`。graphd 到 storaged 仍走这条 5.421 ms 的路径。这一轮的 veth 计数没读到（命名空间里没有宿主机的 `v-stor*` 统计），表里写未测。

c=1 是 20 次串行。c=50、c=100 各是一波。时延是 `ResultSet.latency()`，单位毫秒，最近秩。QPS 是完成数除以墙钟。c=1 的墙钟含客户端往返，所以低于 `1000/P50`。错误数单独写。P50 只来自成功的样本。

准确率是每种放置 8 个用户，三种语句（单机路径、`NOAFFINITY`、四句 nGQL）。真值是 `ground.exact`。桥上和 5.421 ms 上各跑了一遍，都是 24/24。这是种子 42 的一张图，不是 8 张不同的图。8 个种子的证明在第 9 节的单测里。

### 桥，ping 平均 0.048 ms

亲和，170 句 `reason=stats`、`rpc` 中位 1、payload 中位 1484 字节。`NOAFFINITY` 170 句 `reason=off`、`rpc` 中位 4、payload 中位 9324。

| 模式 | c | n | P50 | P99 | QPS | 错误 | veth 字节 |
|------|---|---|-----|-----|-----|------|-----------|
| 单机 | 1 | 20 | 0.989 | 1.671 | 20.33 | 0 | 31325 |
| 单机 | 50 | 50 | 0.740 | 1.355 | 114.80 | 0 | 48380 |
| 单机 | 100 | 100 | 0.661 | 1.578 | 116.21 | 0 | 129976 |
| v2 | 1 | 20 | 2.290 | 3.608 | 20.35 | 0 | 123997 |
| v2 | 50 | 50 | 1.645 | 3.422 | 125.67 | 0 | 307447 |
| v2 | 100 | 100 | 1.653 | 15.846 | 118.35 | 0 | 602030 |
| nGQL | 1 | 20 | 6.092 | 7.416 | 15.53 | 0 | 452775 |
| nGQL | 50 | 50 | 5.009 | 7.798 | 56.09 | 0 | 1009293 |
| nGQL | 100 | 100 | 4.717 | 7.733 | 48.27 | 0 | 2025285 |

veth 是 `v-stor1..3` 的 rx+tx 在这一波上的差，含心跳。c=1 的墙钟大约 1 秒，心跳占得比较多，不能把 31325 除以 20 当成单句的纯查询字节。payload 中位 1484 对 9324 是查询字段本身。

同一波的 CPU。jiffies 是 utime+stime 的差。1 jiffy 是 10 ms。波长短于 1 秒时，差 1 个 jiffy 就是整格的精度。RSS 是波结束时的 VmRSS，单位 KB。

| 模式 | c | 墙钟 s | storaged jiffies | storaged RSS | graphd jiffies | graphd RSS |
|------|---|--------|------------------|--------------|----------------|------------|
| 单机 | 1 | 0.984 | 1 | 75692, 74412, 78764 | 4 | 46012 |
| 单机 | 100 | 0.861 | 5 | 75696, 74416, 78756 | 10 | 46016 |
| v2 | 1 | 0.983 | 3 | 75696, 74416, 78928 | 5 | 46040 |
| v2 | 100 | 0.845 | 9 | 75700, 74424, 79588 | 15 | 46692 |
| nGQL | 1 | 1.288 | 7 | 75684, 74424, 80128 | 12 | 46984 |
| nGQL | 100 | 2.072 | 24 | 75384, 74420, 80844 | 43 | 47212 |

按 `jiffies / 墙钟 / 100`，亲和 c=100 的三台 storaged 合计大约 0.058 个核，v2 大约 0.11，nGQL 大约 0.12。这个换算和 jiffy 的 10 ms 粒度绑在一起，不拿来比 0.01 个核以下的差。

随机。门闩没过：预热那句 `ratio=0.337057`，`reason=ratio`，`cov=-1`（出边比例已经不够，不再读覆盖率）。170 句走多相位，`rpc` 中位 9，payload 中位 11516。`NOAFFINITY` 的 170 句 `rpc` 中位 9，payload 中位 11572。上界剪枝在这张图上几乎没少字节。没有一句 `stop=1`。

| 模式 | c | P50 | P99 | QPS | 错误 | veth |
|------|---|-----|-----|-----|------|------|
| 门闩拒绝后的多相位 | 1 | 1.788 | 3.401 | 20.59 | 0 | 207474 |
| 同上 | 50 | 1.838 | 3.902 | 102.67 | 0 | 461465 |
| 同上 | 100 | 2.129 | 4.366 | 89.08 | 0 | 929491 |
| v2 | 1 | 1.978 | 2.862 | 20.40 | 0 | 194706 |
| v2 | 50 | 2.427 | 4.433 | 112.11 | 0 | 444425 |
| v2 | 100 | 2.314 | 3.994 | 135.78 | 0 | 915207 |
| nGQL | 1 | 5.264 | 7.258 | 15.53 | 0 | 489631 |
| nGQL | 50 | 5.064 | 8.887 | 47.41 | 0 | 1279226 |
| nGQL | 100 | 4.903 | 7.238 | 50.94 | 0 | 2547335 |

混合。预热 `ratio=0.971042`，`reason=ratio`。跨社区边把出边比例从 1 拉下来，门闩拒绝。170 句 `rpc` 中位 6，payload 中位 5864。`NOAFFINITY` 170 句 `rpc` 中位 6，payload 中位 10064。剪枝少了字节，没有少 RPC，也没有单机完成。

| 模式 | c | P50 | P99 | QPS | 错误 | veth |
|------|---|-----|-----|-----|------|------|
| 门闩拒绝后的多相位 | 1 | 2.324 | 3.164 | 20.42 | 0 | 133816 |
| 同上 | 50 | 1.951 | 4.040 | 123.95 | 0 | 284583 |
| 同上 | 100 | 1.708 | 3.905 | 129.83 | 0 | 544051 |
| v2 | 1 | 1.999 | 3.335 | 20.55 | 0 | 160238 |
| v2 | 50 | 1.878 | 3.423 | 143.42 | 0 | 333497 |
| v2 | 100 | 1.700 | 3.361 | 100.81 | 0 | 686209 |
| nGQL | 1 | 5.712 | 8.031 | 15.50 | 0 | 444015 |
| nGQL | 50 | 5.261 | 8.619 | 54.80 | 0 | 1063765 |
| nGQL | 100 | 5.216 | 7.096 | 47.31 | 0 | 2248268 |

### 平均 5.421 ms

亲和仍是 170 句 `rpc=1`、payload 中位 1484，对 v2 的 4 和 9324。veth 未测。

| 模式 | c | P50 | P99 | QPS | 错误 |
|------|---|-----|-----|-----|------|
| 单机 | 1 | 6.470 | 8.192 | 14.30 | 0 |
| 单机 | 50 | 9.466 | 15.697 | 220.25 | 0 |
| 单机 | 100 | 12.006 | 24.434 | 281.44 | 0 |
| v2 | 1 | 24.269 | 26.954 | 10.89 | 0 |
| v2 | 50 | 50.148 | 55.996 | 341.22 | 0 |
| v2 | 100 | 79.869 | 91.840 | 169.94 | 0 |
| nGQL | 1 | 31.591 | 38.559 | 9.43 | 0 |
| nGQL | 50 | 45.345 | 55.851 | 72.46 | 0 |
| nGQL | 100 | 38.363 | 49.448 | 83.73 | 1 |

c=100 的那一次 nGQL 错误是 `Session not existed`。P50 来自成功的 99 次。没有返回一个被截短的商品列表。

c=1 上单机 6.470 ms，v2 24.269 ms。一句 RPC 对四句。c=100 是 12.006 对 79.869。

随机，仍然没有单机。`rpc` 中位两边都是 9。

| 模式 | c | P50 | P99 | QPS | 错误 |
|------|---|-----|-----|-----|------|
| 门闩拒绝 | 1 | 23.871 | 29.633 | 11.48 | 0 |
| 门闩拒绝 | 50 | 75.378 | 90.490 | 269.62 | 0 |
| 门闩拒绝 | 100 | 79.107 | 99.345 | 160.19 | 0 |
| v2 | 1 | 25.498 | 29.435 | 11.35 | 0 |
| v2 | 50 | 59.656 | 62.371 | 318.49 | 0 |
| v2 | 100 | 112.643 | 127.229 | 286.44 | 0 |
| nGQL | 1 | 27.605 | 34.580 | 8.56 | 0 |
| nGQL | 50 | 44.040 | 55.194 | 64.15 | 1 |
| nGQL | 100 | 39.255 | 52.301 | 62.18 | 0 |

c=50 的 nGQL 错误同样是 session 不存在。P50 来自成功的 49 次。

混合，没有单机。带上界剪枝的 170 句 payload 中位 5864，v2 是 10064。`rpc` 中位都是 6。

| 模式 | c | P50 | P99 | QPS | 错误 |
|------|---|-----|-----|-----|------|
| 门闩拒绝 | 1 | 24.761 | 28.233 | 11.35 | 0 |
| 门闩拒绝 | 50 | 50.959 | 60.912 | 309.41 | 0 |
| 门闩拒绝 | 100 | 67.669 | 84.588 | 173.61 | 0 |
| v2 | 1 | 24.476 | 28.298 | 11.15 | 0 |
| v2 | 50 | 62.819 | 69.815 | 308.33 | 0 |
| v2 | 100 | 119.472 | 132.397 | 295.57 | 0 |
| nGQL | 1 | 31.693 | 36.205 | 8.44 | 0 |
| nGQL | 50 | 44.338 | 59.662 | 76.13 | 0 |
| nGQL | 100 | 40.622 | 56.624 | 79.46 | 0 |

5.421 ms 上，亲和的单机 c=1 是 6.470 ms，随机的多相位是 23.871 ms。差出来的是少了三轮 RPC，不是抽样把随机图也收成了单机。

---

## 8. 故障

副本 1。用户 9 在亲和图上，杀掉 stor1、stor2 之后再查，仍是 20 行，和杀掉之前相同。杀掉 stor3（这张图上领导用户 9 那个 part 的那台）之后，返回 `copurchase rpc`，没有结果行。日志是 `not_applied` 然后 fallback，fallback 看到 `hop_hosts=0`，不再把「没人应答」当成「这个用户没有购买」。

三台都杀掉时同样是 `copurchase rpc`，0 行。

meta1 被 `kill -9` 的当下，新建会话是 `Leader changed`，没有结果行。8 秒后再查，`USE` 成功，同一句仍是 20 行。没有看到一份被截短的商品列表。

---

## 9. 测试

| 项 | 结果 |
|----|------|
| `copurchase_test` | 9 过。含 vid 与 hash part 一致、镜像前缀、8 个种子的 `proveLocalChain` 和 `coarseKeep` |
| `local_multihop_test` | 40 过 |
| `meta_key_utils_test` `*LocalDstRatio*` | 1 过 |
| 集群准确率 | 每种放置、两种 RTT，8 个用户 × 3 种语句，都是 24/24 |

8 个种子没有各自灌进集群。集群只有种子 42。

---

## 10. 边界

- 单机能完成的是这次的亲和图：0 条跨 part 的边，出边比例和买家覆盖率都是 1，170 句 `stop=1`、`rpc=1`。随机图比例 0.337，混合图 0.971，门闩拒绝，一句都没有 `stop=1`。
- 比例是上一轮扫完的全量计数。默认阈值是 1.0。差一条跨社区边就不再尝试单机。尝试了也被 guard 丢掉，不会把不完整的链当成结果。
- 镜像不是全局入边。跨 Raft group 的副本没有做，因为不能和原边一次提交。
- 图是 2997 用户、297 商品、约 1.8 万条边。不是 43 篇的 15 万用户。更大的图这次没灌。
- 7 日窗没跑。
- 5.421 ms 的 veth 字节未测。桥上的 veth 含心跳。
- c=1 的 QPS 含客户端间隔。服务器 P50 是 `ResultSet.latency()`。
- jiffies 的粒度是 10 ms。短波上的核数只说明量级。
- nGQL 在 5.421 ms 上有两次 `Session not existed`（亲和 c=100 一次，随机 c=50 一次）。那两格的 P50 不含这两次。
- 抽样 tick 在压测时开着，预算 3000µs。没有单独做「抽样关着」的对照波。
- `copurchase_affinity` 默认关。不关的话，随机图只是多一次比例判断，然后走带上界剪枝的多相位，不是单机。
