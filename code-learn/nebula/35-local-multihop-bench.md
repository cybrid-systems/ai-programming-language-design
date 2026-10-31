# 35 — 子图亲和与随机分布：LocalMultiHop 实测

> 实现和与 [33](33-local-multihop-design.md) 的差别在 [34](34-local-multihop-impl.md)。自适应层怎么避免这篇里随机放置的回退，在 [36](36-adaptive-multihop-design-impl.md) 和 [37](37-adaptive-multihop-bench.md)。
> 脚本：[`bench/local_multihop/`](bench/local_multihop/)。原始 JSON 在 [`results/`](bench/local_multihop/results/)。
> 二进制是 `v3.8.0` `fa928930` 加上 [`v3.8.0-local-multihop.patch`](patches/v3.8.0-local-multihop.patch)。4 vCPU，`Linux 6.12.94+`。
> 日期：2026-10-31。

查询都是 `GO 3 STEPS FROM <每社区一个种子> OVER know YIELD DISTINCT know._dst`。server 时延是 `ResultSet.latency()`，单位毫秒。每一档先丢掉 1 次预热，再记 5 次。错误数全是 0，除非单独写明。

---

## 1. 数据

INT64 的 part 是 `(vid % partition_num) + 1`，和 `MetaClient::partId` 一致。9 个社区、每个 300 点、每点大约 8 条社区内边，种子 7。亲和放置把社区 `c` 的第 `i` 个点编成 `c + i * 9`，整社区落在同一个 part。随机放置用同一张边表，只打乱 vid。

| 放置 | 边 | 3 跳终点 |
|------|----|----------|
| 亲和 | 21600 | 2167 |
| 随机 | 21600 | 2176 |

两边终点个数不同，是因为 vid 打乱之后 `DISTINCT` 的集合不同，不是丢点。每条结果都和 `gen_data.walk` 逐个 vid 对过。

3.8 没有分区组元数据。flag 开的跑法是 `--enable_local_multihop=true --local_multihop_affinity=1`。只开 enable、affinity 仍为 0 时，执行器不会发多跳。

---

## 2. 正确性

[`run_tck.py`](bench/local_multihop/run_tck.py) 跑了补丁里 `tests/tck/features/go/LocalMultiHop.feature` 的四句。官方 pytest-bdd 没启，脚本按 feature 里的语句和期望表执行。空间 3 part。

| 场景 | 结果 | `local_multihop` |
|------|------|------------------|
| `GO 3 STEPS FROM 3` | `{10, 12}` | applied，`steps_done=3`。10 在另一个 part，由 remote 交回后再扩 |
| `GO 2 TO 3 STEPS` | `{7, 9, 10, 12, 15}` | applied |
| `GO 3 STEPS FROM 100` | 空 | applied，0 行 |
| `GO 2 STEPS ... WHERE know.w > 0` | `{7, 9, 15}` | **没有** applied。WHERE 让 `isSimpleCase` 为假，仍走 `getNeighbors` |

旧 storaged：`--storaged_accept_local_multihop=false`，graphd 仍发 `max_steps`。同一句 `GO 3 STEPS FROM 3` 得到 `{10, 12}`，PROFILE 没有 `applied=1`，而是 `step0`、`step1`、`step2` 三次单跳。

杀掉 `10.88.0.21`（part 3/6/9 的 leader）之后：

- `GO 3 STEPS FROM 0`：0 在 part 1，leader 是 `.23`，查询成功，248 行。死掉的 host 上没有这条种子的边。
- `GO 3 STEPS FROM 0,1,2,3,4,5,6,7,8`：要碰到死掉的 part，失败，`Storage Error: RPC failure, probably timeout.`，没有返回少了一截的终点。

第一版随机图 flag 开少了 16 个 vid（2160/2176）。原因是同一个 dst 先在浅层记成 remote 之后，更深的一次到达被丢掉。单跳没有这种全局去重。修完再跑，2176 全对。34 里有对应单测。

---

## 3. 单机

一台 storaged 是全部 9 个 part 的 leader，所以亲和和随机在存储侧都是「全本地」。差别只剩 vid 是否扎堆。三轮交替，flag 关 / 开 × 两种放置。

并发 1 的 server P50，三轮的最小到最大：

| 放置 | flag 关 | flag 开 | PROFILE |
|------|---------|---------|---------|
| 亲和 | 3.116–3.750 | 3.231–4.429 | 关：3 次 RPC，回传 72 / 523 / 2167。开：1 次，`steps_done=3 remote=0`，回传 2167 |
| 随机 | 3.005–3.243 | 3.533–3.679 | 同样是 3 次对 1 次。开的时候 remote 也是 0 |

两边的区间叠在一起。flag 开没有更慢到能单独分开，也没有更快。并发 10/50/100/200 的 P50 都在 2.8–3.2 ms 附近，QPS 大约 80–90，同样重叠。例如亲和 flag 开、并发 200 的三轮 P50 是 2.830、2.887、2.883。P95/P99 和每一轮的原始值在 JSON 里。

单机上少两次 loopback RPC，省下来的时间盖不住 storaged 里把三跳扫在一次请求里的开销。

---

## 4. 三台 storaged，内核桥

`start_dist.sh`：3 metad、3 storaged、1 graphd。`ping` graph→stor1，20 包，0 丢包，min/avg/max = 0.021 / 0.067 / 0.877 ms（有一个 0.877 的离群点；stor1→stor2 是 0.018 / 0.034 / 0.121）。两轮，数据不重灌。

RPC 行数是 PROFILE 里 `step* resp` 的条数。亲和 flag 开是一轮 3 个 host（每个 host 把自己的社区走完）。flag 关是 3 轮 × 3 个 host = 9 条。随机 flag 开因为每层都有 remote，PROFILE 里有 13 个波次、27 条 host 响应。

并发 1 的 server P50：

| 放置 | flag | 第 1 轮 | 第 2 轮 | QPS 第 1 / 第 2 轮 |
|------|------|---------|---------|-------------------|
| 亲和 | 关 | 2.776 | 2.893 | 62.26 / 63.51 |
| 亲和 | 开 | 1.845 | 2.032 | 68.19 / 65.66 |
| 随机 | 关 | 3.258 | 3.850 | 58.92 / 57.40 |
| 随机 | 开 | 5.753 | 6.235 | 50.32 / 49.36 |

亲和 flag 开的两轮都低于 flag 关的两轮（1.85–2.03 对 2.78–2.89）。并发 10 也是：开 1.619 / 2.136，关 2.742 / 2.821。并发 200 开的是 1.696 / 2.118，关的是 2.610 / 3.195。QPS 在并发 10 以后两边都到 85–91，尾部是 4 个 graphd worker 在排队，不是 RPC 次数。

随机 flag 开的两轮都高于 flag 关（5.75–6.24 对 3.26–3.85）。并发 200 是 6.63 / 7.70 对 2.76 / 3.12。多跳把每一层的 remote 再发一轮，波次从 3 变成 13，比单跳更贵。结果仍然是 2176，和生成器一致。

---

## 5. 大约 5 ms 的 RTT

`tc netem` 在这个内核里没有（`CONFIG_NET_SCH_NETEM` 未编进）。延迟来自 [17](17-distributed-bench.md) 的 `l2_delay.py`，单向 2.5 ms。刚切过去的 10 个 ping 里丢了 3 个，收到的 RTT 是 5.239 / 5.451 / 6.125 ms。之后补的 20 个 ping 是 0 丢包，5.125 / 5.319 / 5.466 ms。查询本身没有错误。

只跑了一轮（桥上的两轮已经分开了）。

| 放置 | flag | c=1 P50 | c=1 P95 | c=1 P99 | c=1 QPS | c=200 P50 | host 响应 |
|------|------|---------|---------|---------|---------|-----------|-----------|
| 亲和 | 关 | 24.395 | 31.169 | 32.490 | 19.97 | 29.732 | 9 |
| 亲和 | 开 | 7.287 | 15.451 | 15.508 | 32.51 | 9.513 | 3 |
| 随机 | 关 | 24.165 | 28.087 | 28.651 | 21.02 | 30.950 | 9 |
| 随机 | 开 | 83.505 | 83.940 | 84.009 | 8.49 | 139.868 | 27 |

亲和、3 跳、一次往返：flag 开的 c=1 P50 是 flag 关的大约 0.30。随机、13 个波次：flag 开是 flag 关的大约 3.5 倍。RTT 把 RPC 次数放大了，方向和桥上一样，差距更大。

并发 10/50/100 的数在对应 JSON 里，没有改变这个方向。亲和 flag 开的 c=10 P50 是 9.112，flag 关是 31.507。随机 flag 开的 c=10 P50 是 126.099，flag 关是 30.481。

---

## 6. 能说的和不能说的

能说的：

- 社区 vid 对齐到同一个 part 时，三台 storaged 上 `GO 3 STEPS` 的 dst 去重结果和单跳一致，RPC 从 3 轮收成 1 轮。桥上 c=1 P50 从大约 2.8 ms 到大约 1.9 ms；ping 平均 5.3 ms 时从 24.4 ms 到 7.3 ms。
- 边随机跨 part 时，多跳为了不丢更长的路径会多发 remote 波次，时延变差，结果仍然对。
- 单机上所有 part 都在同一台 leader 上，1 次 RPC 对 3 次 RPC 的时延落在三轮噪声里，不能写成加速。
- 关掉 storaged 的接受位，graphd 退回三轮单跳，终点不变。需要死掉的 part 时整句失败。

不能说的：

- 不能把这台 VM 的 7.3 ms 写成机房数字。磁盘和 CPU 是共享的，转发器自己有抖动。
- 不能在 affinity 估计为 0 时期望收益。3.8 没有 33 篇里的分区组元数据，估计值要调用方自己给。
- 过滤、边属性、路径不在这次的多跳里。`WHERE` 的那句 PROFILE 没有 `applied`。
