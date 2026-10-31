# 37 — 自适应本地多跳实测

> 设计和实现在 [36](36-adaptive-multihop-design-impl.md)。按分区的 v2 和双向漂移在 [38](38-adaptive-multihop-v2.md)。
> 38 篇重跑覆盖了顶层的 `bridge_*` / `rtt5_*` 里 baseline、static 和两份 ping。下面的表对应 `c0c2851` 里的那些文件。静态多跳上一轮的 83.5ms 在 [35](35-local-multihop-bench.md)，那一版还没有把同一深度的 host 回复合成一个 frontier。
> 脚本：[`bench/local_multihop/run_adaptive.sh`](bench/local_multihop/run_adaptive.sh)、[`drift.py`](bench/local_multihop/drift.py)、[`measure.py`](bench/local_multihop/measure.py)。JSON 在 [`results/`](bench/local_multihop/results/)，前缀 `bridge_`、`rtt5_`、`drift_`。
> 二进制是 `fa928930` 加上 [`v3.8.0-local-multihop.patch`](patches/v3.8.0-local-multihop.patch) 和 [`v3.8.0-adaptive-local-multihop.patch`](patches/v3.8.0-adaptive-local-multihop.patch)。4 vCPU，`Linux 6.12.94+`。
> 日期：2026-10-31。下面每张表都是这次进程里测到的，不是估算。

查询是 `GO 3 STEPS FROM <每社区一个种子> OVER know YIELD DISTINCT know._dst`。时延是 `ResultSet.latency()`，毫秒。每个并发档先丢掉 3 次预热，再记 8 次；c=10 是 80 个样本，c=50 是 400 个。错误数全是 0。终点和 `gen_data.walk` 逐个 vid 对过，`check.ok` 全是 true。

三路开关：

| 名字 | graphd |
|------|--------|
| baseline | `--enable_local_multihop=false --enable_adaptive_local_multihop=false` |
| static | `--enable_local_multihop=true --local_multihop_affinity=1`，请求里的 `min_local_ratio=0`（守卫关） |
| adaptive | `--enable_adaptive_local_multihop=true`，`--local_multihop_min_local_ratio=0.6`，探索率 0.05，EWMA alpha 0.2。`--local_multihop_assumed_rtt_us=5000` 是代价模型的配置值，不是这次 ping |

storaged 都是 `--storaged_accept_local_multihop=true`。

---

## 1. 集群和数据

3 meta + 3 storaged + 1 graphd，网络命名空间，和 17 / 35 篇同一套 `start_dist.sh`。内核没有 `sch_netem`。近零 RTT 是桥。约 5ms 是 `l2_delay.py --delay-ms 2.5`，往返大约两倍单程再加转发器自己的时间。

桥上 graph → `10.88.0.21`，20 包 0 丢：min/avg/max/mdev = 0.017 / 0.022 / 0.088 / 0.015 ms。

延迟转发器上同一对，20 包 0 丢：5.097 / 5.399 / 6.157 / 0.249 ms。

9 part，RF=1，社区大小 300，出度大约 8，种子 7。边数是生成器实际写进去的，不是按 `300*8*9` 估的。

| 放置 | 边 | 3 跳终点 |
|------|----|----------|
| affinity | 21523 | 2167 |
| random | 21537 | 2176 |
| mixed | 21546 | 2116 |

mixed：偶数社区（0,2,4,6,8，五个）用 `c + i*9`，整社区在一个 part。奇数社区（1,3,5,7，四个）只在这些社区本来会占用的 vid 池里打乱，那个池就是奇数 part。不是「每条边 50% 出社区」。

PROFILE 的 `waves` 是 `step{N}` 的个数，`hosts` 是 host 回复条数。adaptive 的 `choice` 是同一次 PROFILE 上的 `adaptive_choice`，不在计时的 8 次样本里。计时样本不含 PROFILE。

---

## 2. 正确性

`local_multihop_test` 30 条全过，含提前停、两深度重放、EWMA、`mergeSameHop`。

`run_tck.py` 对单机、`--enable_local_multihop=true --local_multihop_affinity=1`：

| 场景 | 结果 | applied |
|------|------|---------|
| `GO 3 STEPS FROM 3` | `{10, 12}`，1097µs | 是 |
| `GO 2 TO 3` | `{7, 9, 10, 12, 15}`，928µs | 是 |
| `GO 3 STEPS FROM 100` | 空，330µs | 是 |
| `WHERE know.w > 0` | `{7, 9, 15}`，1534µs | 否 |

同一份数据把 `--storaged_accept_local_multihop=false` 之后再跑，四句终点不变，三句多跳的 applied 变成否（WHERE 本来就不是多跳）。这是修 `mergeSameHop` 之前的那次；修完之后又用 accept=true 跑过上面这张表。单机只有一个 storaged，合成 frontier 不会改变这四句。

分布式上三路九个 space 的终点都和生成器一致，见第 3、4 节的 `got`。

---

## 3. 近零 RTT

c=1 只有 8 个样本。桥上的差是 1ms 上下，和 35 篇一样，不要把它读成稳定加速。波次是硬的。

c=1：

| 放置 | 模式 | P50 | P99 | QPS | waves | hosts | choice |
|------|------|-----|-----|-----|-------|-------|--------|
| affinity | baseline | 2.939 | 3.508 | 55.35 | 3 | 9 | |
| affinity | static | 2.324 | 2.996 | 58.89 | 1 | 3 | |
| affinity | adaptive | 1.952 | 2.602 | 63.31 | 1 | 3 | multi |
| random | baseline | 2.892 | 3.181 | 59.36 | 3 | 9 | |
| random | static | 3.705 | 4.377 | 55.32 | 4 | 12 | |
| random | adaptive | 3.280 | 3.896 | 50.37 | 3 | 9 | base |
| mixed | baseline | 2.970 | 3.144 | 57.70 | 3 | 9 | |
| mixed | static | 3.407 | 4.017 | 56.38 | 4 | 10 | |
| mixed | adaptive | 3.274 | 3.707 | 57.47 | 3 | 9 | base |

c=10 的 P50：affinity baseline 3.032 / static 2.500 / adaptive 1.946；random 3.057 / 4.091 / 3.191；mixed 3.179 / 3.310 / 3.141。QPS 都在 70–78。

亲和自适应和静态一样，1 个 wave、3 个 host、`local_ratio=1`、`early_stop=0`、`steps_done=3`。随机和 mixed 的自适应 PROFILE 是 `base`，3 wave、9 host，和基线同一形状。静态随机是 4 wave、12 host，守卫没开，`local_ratio` 大约 0.30 但 `early_stop=0`。

---

## 4. 约 5ms RTT

这是要看的那档。ping 均值 5.399ms。

c=1：

| 放置 | 模式 | P50 | P99 | QPS | waves | hosts | choice |
|------|------|-----|-----|-----|-------|-------|--------|
| affinity | baseline | 21.595 | 23.774 | 20.71 | 3 | 9 | |
| affinity | static | 7.377 | 15.317 | 33.29 | 1 | 3 | |
| affinity | adaptive | 7.494 | 15.291 | 32.57 | 1 | 3 | multi |
| random | baseline | 21.498 | 24.600 | 21.05 | 3 | 9 | |
| random | static | 27.541 | 28.425 | 18.64 | 4 | 12 | |
| random | adaptive | 22.098 | 24.413 | 20.38 | 3 | 9 | base |
| mixed | baseline | 21.556 | 24.218 | 21.46 | 3 | 9 | |
| mixed | static | 25.477 | 27.925 | 19.05 | 4 | 10 | |
| mixed | adaptive | 22.215 | 24.112 | 21.45 | 3 | 9 | base |

c=10 / c=50 的 P50：

| 放置 | 模式 | c=10 P50 | c=10 P99 | c=10 QPS | c=50 P50 | c=50 P99 | c=50 QPS |
|------|------|----------|----------|----------|----------|----------|----------|
| affinity | baseline | 30.302 | 39.513 | 66.28 | 29.741 | 41.610 | 69.05 |
| affinity | static | 9.439 | 15.519 | 73.74 | 9.512 | 14.574 | 77.98 |
| affinity | adaptive | 9.474 | 27.702 | 74.98 | 9.505 | 26.848 | 77.69 |
| random | baseline | 31.700 | 46.793 | 64.87 | 30.913 | 45.510 | 68.13 |
| random | static | 42.302 | 52.887 | 67.06 | 41.040 | 57.758 | 69.81 |
| random | adaptive | 30.958 | 43.289 | 67.32 | 30.634 | 47.992 | 70.83 |
| mixed | baseline | 27.148 | 37.519 | 71.16 | 29.250 | 40.363 | 72.84 |
| mixed | static | 35.820 | 51.718 | 70.65 | 36.849 | 49.087 | 74.07 |
| mixed | adaptive | 28.683 | 37.501 | 68.65 | 29.832 | 43.836 | 73.96 |

亲和上自适应和静态重合：大约 7.4ms 对基线 21.6ms，1 个 wave 对 3 个。c=10 的自适应 P99 27.7ms 比静态的 15.5ms 高，8 次预热加 80 个样本里会夹进大约 5% 的基线探索（基线这一档 P50 是 30ms）。P50 没被拉开。

随机上自适应 P50 22.1ms，基线 21.5ms，静态 27.5ms。波次 3 / 3 / 4，host 回复 9 / 9 / 12。自适应没有去追静态那一截。mixed 同样：自适应 22.2，基线 21.6，静态 25.5。mixed 的整句比例盖不住 0.6，控制器停在基线，亲和的那一半社区也没有被收成 1 个 wave。这是 36 篇第 7 节写的粒度。

35 篇静态随机在约 5ms 下是 P50 83.5ms、13 wave、27 host。那次二进制没有 `mergeSameHop`。本补丁把同一剩余深度的 host 回复合成一个 frontier，静态路径一起变了，所以这里的静态是 4 wave、27.5ms，不是把 83.5 再测一遍。修合成之前有过一版自适应单跳臂：每个 host 的回复单独排队，随机图 PROFILE 是 `choice=base` 但仍有 13 wave、39 条 host 回复，c=1 P50 80.435ms。那份 JSON 被这次重跑覆盖了，数字来自重跑前的同一次日志，不在 `results/` 里。报出的表只算重跑之后的。

---

## 5. 漂移

同一个 space、同一条 `know`、同样 3 跳，先插入亲和边，逐条查询，再删边，换上同一种子的随机放置。形状键不变，EWMA 接着用。没有隐藏预热。延迟是客户端 `latency()`。`choice` / `early` / `rpc` 来自该条查询的 `adaptive_multihop` 日志（`--local_multihop_trace=true --logbufsecs=0`）。`rpc` 是这次 walk 的波次。全部终点正确。

约 5ms，先 30 条亲和，再 40 条随机。每 10 条一个窗：

| 阶段 | 窗 | multi | base | early | rpc 中位 | P50 | P99 |
|------|----|-------|------|-------|----------|-----|-----|
| 亲和 | 0–9 | 10 | 0 | 0 | 1 | 7.423 | 8.959 |
| 亲和 | 10–19 | 10 | 0 | 0 | 1 | 7.037 | 7.342 |
| 亲和 | 20–29 | 8 | 2 | 0 | 1 | 7.313 | 23.722 |
| 随机 | 0–9 | 10 | 0 | 10 | 3 | 22.775 | 27.551 |
| 随机 | 10–19 | 8 | 2 | 8 | 3 | 22.340 | 25.332 |
| 随机 | 20–29 | 10 | 0 | 10 | 3 | 22.162 | 26.555 |
| 随机 | 30–39 | 9 | 1 | 9 | 3 | 23.033 | 23.982 |

亲和阶段一直是 multi、1 次 RPC、没有提前停，P50 约 7.0–7.4ms。第 25 和 29 条是探索出来的 base，客户端 23.96ms 和 21.29ms，把第三个窗的 P99 拉到 23.7ms。

换成随机之后，第一条就是 `early=1`、`rpc=3`、22.67ms。之后 40 条里 37 条仍是 multi，但全部 `early=1` 且 `rpc=3`，P50 停在 22–23ms，和这张表里的基线 21.5ms 同一档，不是静态的 27.5ms，更不是修合成之前的 80ms。选择没有切到 base：守卫把多跳的延迟压到了和基线一样，alpha 0.2 的多跳 EWMA 从大约 7ms 往 22ms 走，40 条之内还没超过亲和阶段探索到的基线样本（大约 23ms）。探索大约每 10 条有 1 条 base，延迟也是 22–25ms。所以漂移之后保住时延的是守卫，不是「EWMA 已经改投基线」。

近零 RTT 的漂移是 20 条亲和 + 30 条随机，同一脚本。亲和 P50 1.86ms 然后 1.71ms，rpc 中位 1，20 条里 19 条 multi。随机三个窗 P50 3.07 / 3.04 / 3.08ms，rpc 中位 3，early 分别 10、9、7。基线在这档的 c=1 P50 是 2.892ms。多出来的大约 0.2ms 在 8～10 个样本的噪声里。选择同样多数留在 multi。

---

## 6. 没测的和不要外推的

- 心跳里的 per-part 采样没做，见 36 篇第 8 节。
- `--local_multihop_assumed_rtt_us=5000` 是写死的配置。这次 ping 均值是 5.399ms。两臂都有样本之后比较的是测到的 EWMA，这个数不参与。单臂公式里它会约掉，只要是正数。
- 单机自适应没有单独压。一个 storaged 领导全部 part 时，亲和和随机都是本地的，守卫不会触发。35 篇已经说明单机看不出 5ms 那档的差。
- c=50 只在约 5ms 那档跑了。桥上只有 c=1 和 c=10。
- 近零 RTT 的 1ms 差、以及漂移随机相对基线的 0.2ms，都落在 c=1 这 8～10 个样本的波动里。5ms 上亲和 7.5 对 21.6、随机自适应 22.1 对静态 27.5，方向和波次一致，不是这个噪声。
- mixed 不会同时拿到亲和的 1-wave 和随机的安全网。要分开，得是两个形状（不同 space、边类型或跳数），不是同一句 `FROM` 所有种子。
