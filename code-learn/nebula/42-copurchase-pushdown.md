# 42 — 共同购买下推

> 叠在 v5（`e6e9a65`，[41](41-adaptive-multihop-v5.md)）上。补丁 [`patches/v3.8.0-copurchase-pushdown.patch`](patches/v3.8.0-copurchase-pushdown.patch) 打在 v5 补丁之后，`patch -p1` 后和当前树逐文件 `cmp` 过。
> 日期：2026-10-31。时延、QPS、ping、重叠率、每跳行数都是测到的。原始行在 `bench/copurchase/results/`。

图是用户买商品。边 `buy` 的 rank 是购买时间（unix 秒），点 `product` 上有整数 `sales`。查询从用户 A 出发，在闭区间时间窗里走完下面五步，最后按销量给出最多 20 个商品。

---

## 1. 排序

窗是闭区间：rank 等于 `window_start` 或 `window_end` 都算。实现在 `src/common/algorithm/Copurchase.h` 的 `inWindow`。

商品（A 自己的出边，取 5 个）：购买次数降序，次数相同比最晚的 rank，再比商品 id 升序。`betterProduct`。

用户（取 15 个）：

- `coCount`：窗内买过的、属于这 5 个商品的不同商品数。同一个商品买两次仍然是 1。
- `purchaseCount`：窗内全部购买边的条数，包括重复购买，也包括这 5 个以外的商品。
- `latestTs`：窗内购买边的最大 rank。
- `coCount` 为 0 的用户丢掉。
- 次序：`coCount` 降序，然后 `purchaseCount` 降序，然后 `latestTs` 降序，然后用户 id 升序。`betterUser`。

销量（取 20 个）：`sales` 降序，相同比商品 id 升序。`betterSales`。

`keepTop` 用 `nth_element` 再 `sort`。比较函数是全序，所以次序稳定。

---

## 2. 基线 nGQL

3.8 没有一句能走完这五步。`bench/copurchase/measure.py` 的 `baseline` 发四句，服务器时延是四次 `ResultSet.latency()` 相加。客户端只做和 `Copurchase.h` 相同的排序，这段 CPU 不在服务器时延里，在 QPS 的墙钟里。

```
GO FROM $A OVER buy
  WHERE buy._rank >= $start AND buy._rank <= $end
  YIELD buy._dst AS pid, buy._rank AS ts
| GROUP BY $-.pid
  YIELD $-.pid AS pid, count(*) AS cnt, max($-.ts) AS ts
| ORDER BY $-.cnt DESC, $-.ts DESC, $-.pid ASC
| LIMIT 5
```

```
GO FROM $p1, $p2, ... OVER buy REVERSELY
  WHERE buy._rank >= $start AND buy._rank <= $end
  YIELD buy._dst AS buyer, buy._src AS pid, buy._rank AS ts
```

反向边上，key 里的 src 是商品、dst 是买家。单机 tck 打出来的第一行是 `(1, 14, 180)`：买家 1、商品 14、rank 180。这和 `StorageExpressionContext::getEdgeProp` 对 `_src` / `_dst` 的读法一致。

```
GO FROM $buyers OVER buy
  WHERE buy._rank >= $start AND buy._rank <= $end
  YIELD buy._src AS uid, buy._dst AS pid, buy._rank AS ts
```

客户端按上面的用户序取 15 人，再：

```
FETCH PROP ON product $pids
  YIELD id(vertex) AS pid, product.sales AS sales
```

客户端按销量排序取 20。四句都是客户端往返，所以基线的「轮次」记的是语句数 4。每句打到几个 storaged 没有从结果里读出来，不估。

单机 tck（`bench/copurchase/run_tck.py`）上这四句的最终 9 行和手算一致。

---

## 3. 精确路径

`COPURCHASE FROM <uid> WINDOW <start>, <end>`。`--enable_copurchase` 默认关。开了以后 `QueryInstance::execute` 在解析前看前缀，命中就走 `CopurchaseDriver`，不进 `GQLParser`。所以 `PROFILE COPURCHASE ...` 不会有执行计划。结果列是 `product, sales`。计划打在 graphd 的 INFO：

```
copurchase_plan mode=exact fallback=0 rounds=4 buyers=... hop_rows=... hop_hosts=... scanned=... users=... products=...
```

`users=` 是 `uid:coCount:purchaseCount:latestTs`。`products=` 是 `pid:sales`。

Thrift 在 `storage.thrift`。服务方法 `copurchase`。请求 `CopurchaseRequest`：`parts`、正的 `edge_type`、`phase`、窗、`product_ids`、`top_k`、可选的 `product_tag_id` / `sales_prop`、`exclude_user`（用户 A，不和自己比）。响应 `copurchase_applied` 只有真正跑了这一相才置位。旧二进制没有这个方法；`--storaged_accept_copurchase=false` 直接 `onFinished`，不置位。graphd 把「未置位」和 RPC 异常都当成回退。

相位：

| 相位 | 谁扫 | 返回 |
|------|------|------|
| `HOP1_TOP_PRODUCTS` | A 的出边，正 edge type，rank 落在窗里 | 本地 top5 的商品 id、次数、最晚 rank |
| `HOP2A_BUYERS` | 这 5 个商品的入边，负 edge type | 窗内买家 id，本机去重，去掉 A |
| `FUSED_COCOUNT` | 候选用户的出边 | 本机按完整 `coCount` 取 top15，带上这些人窗内买过的全部商品 |
| `HOP4_SALES` | 商品点的 tag | 本机按 `sales` 取 top20 |

`CopurchaseProcessor::scan` 用 `NebulaKeyUtils::edgePrefix(..., rank)` 做 `[window_start, window_end+1)` 的 `range`。rank 的编码保持数值序，所以窗在存储层就切完，不是把边拉回 graphd 再滤。`rows_scanned` 是窗内看到的边（或 hop4 读到的点）。

`StorageClient::copurchase` 用和 `getDstBySrc` 一样的 `clusterIdsToHosts`，一个 leader 一个 RPC，请求里带这个 host 上的 part 映射。

### 为什么 top15 是精确的

用户的出边写在用户所在的 part 上。`scoreUser` 在那一台 storaged 上看到这个用户窗内的每一条出边，`coCount` 不用和别的机器加。一台机器上的 top15 之外的人，比本机至少 15 个人差，也就进不了全局 top15。各机 top15 的并集包含全局 top15。`mergeExact` 只按完整分数排序，不把同一个人的分数相加；同一个人出现两次时留下更好的那份（正常情况下不会发生，因为一个人只有一个 part）。

销量是商品点上的属性，商品在哪个 part 就存在哪。每台机器按 `sales` 取 top20，并集包含全局 top20。`mergeSales` 按 pid 去重后再取 20。

所以精确路径是 4 轮 RPC：hop1 打到 A 的那一台（`hop_hosts` 中位 1），hop2a 打到这 5 个商品所在的 host，fused 打到候选用户的 host，hop4 打到商品的 host。`rounds` 在准确率那 12 条上全是 4，`fallback` 全是 0。

### 朴素路径为什么丢

`COPURCHASE ... NAIVE`。hop1 相同。下一轮是 `NAIVE_PARTIAL`：在商品所在的 host 上扫这 5 个商品的入边，按本机看到的部分 `coCount` 取 top15。一个人的 5 次共同购买如果落在不同 host 上，就被拆开。graphd 的 `mergeNaive` 只把各机交回来的行加起来：`coCount` 是这些行里的不同商品数，`purchaseCount` 相加，`latestTs` 取最大。某一台上没进 top15 的那一份不会出现。两边都没进 top15 的人直接消失。

这一步的 `purchaseCount` / `latestTs` 只覆盖焦点商品上的边，不是精确路径里「窗内全部购买」。单机 tck 上用户 5 的精确分数是 `5:4:5:190`（4 个焦点商品加商品 30，最晚 190），朴素分数是 `5:4:4:140`。人的次序没变，商品列表仍然 9 行全对。误差要等焦点商品分到多台机器才看得到。

朴素选出的 15 个人之后，再发一轮 `FUSED_COCOUNT`，只为了读他们窗内买过的商品 id。这一轮的 `coCount` 不用来重排，否则朴素就变成精确了。然后 hop4。所以朴素也是 4 轮，不是 3 轮。第二轮返回的是各机 top15 的用户行（30 日中位 45，三台各约 15），第三轮是这 15 个人（中位 15）。

---

## 4. 回退

`--storaged_accept_copurchase=false` 时处理器成功返回，`copurchase_applied` 不置位。graphd 看到未置位，或者 `future_copurchase` 抛异常（旧 storaged 没有这个方法），就走 `fallback`。回退用现成的 `getNeighbors`：A 的出边、焦点商品的入边、买家的出边，窗在 graphd 上滤，排序仍用 `Copurchase.h`。销量用 `getProps`。日志 `fallback=1`。

单机上把这个旗标关掉再查用户 1、窗 `[100, 200]`：`fallback=1 rounds=4`，用户行 `5:4:5:190,2:3:4:181,3:2:3:182,4:1:2:183`，商品 9 行和精确路径相同。`hop_rows` 在回退里是 `getNeighbors` 交回来的边数（hop1 是 6，含窗外商 15 的那条），不是下推路径的 top-k 行数。

回退的朴素模式按 `vid % partsNum + 1` 把入边分到 part 上再做各 part 的 top15，和精确回退不是同一条路径。压测没有走回退：`fallback_n=0`。

---

## 5. 图

`bench/copurchase/generate.py`，种子 42。`graph.json`：

| 项 | 值 |
|----|----|
| 用户 | 20000，id 1..20000 |
| 商品 | 2000，id 1000001 起 |
| 边 | 379948 |
| 每人购买 | `8 + (user % 23)` 个不同商品，一条边 |
| 商品热度 | zipf，α = 1 |
| rank | `[1761868800 - 60 天, 1761868800]` 上均匀 |
| 30 日窗 | `[1759276800, 1761868800]` |
| 7 日窗 | `[1761264000, 1761868800]` |
| sales | `1000000 / (1 + 一个与热度无关的排列)` |

空间 `copurchase`，`partition_num=9`，`replica_factor=1`，`vid_type=INT64`。3 个 storaged。抽样关掉：`--local_dst_ratio_sample_interval_secs=0`，避免 tick 进 P99。

part id 是 8 字节 vid 按小端读成 uint64 再 `% numParts + 1`（`MetaClient::partId`）。正的 int64 上就是 `vid % 9 + 1`。

---

## 6. 测试

| 项 | 结果 |
|----|------|
| `copurchase_test` | 5 过。含 top5 的平局和闭区间、用户四键次序、精确合并包含全局 top15、朴素丢掉 co=3 的人并少算幸存者、销量 top20 |
| `local_multihop_test` | 40 过 |
| `meta_key_utils_test` `*LocalDstRatio*` | 1 过 |
| `bench/copurchase/run_tck.py` | `TCK_OK`。精确、朴素、四句 nGQL 都是那 9 行 |
| `bench/local_multihop/run_tck.py` | `TCK_OK`。三步和 m-to-n 仍是 `multihop_applied=True`，带 WHERE 的那条仍是 false |

朴素的单机 tck 和精确一致，因为 4 个共同购买者都进得了 top15。第 5 节的丢行是 9 个 part、3 台机器上的事。

---

## 7. 压测

集群是 `bench/scenario2/start_dist.sh`。graphd `10.88.0.31:9669`，存储 `.21/.22/.23:9779`。主机到 graphd 的路径没有加延迟。RTT 是 `ns-graph1` ping `10.88.0.21`。

桥（没有 forwarder）：

| 路径 | min / avg / max / mdev (ms) |
|------|------------------------------|
| graph → stor1 | 0.018 / 0.022 / 0.081 / 0.013 |
| stor1 → stor2 | 0.018 / 0.023 / 0.094 / 0.016 |
| graph → meta1 | 0.014 / 0.022 / 0.087 / 0.014 |

`usdelay 2.5` 之后第一轮 ping 丢了 3/20。forwarder 起来后再 ping，20/20，`5.182 / 5.404 / 5.720 / 0.113`。表用这一轮。

时延是 `ResultSet.latency()`，单位毫秒。P50/P99 是最近秩（`round(p/100*(n-1))`）。QPS 是这一波完成数除以墙钟。c=1 是 30 次串行，c=10 是一波 10，c=50 是一波 50。c=1 的 QPS 含两次查询之间的客户端时间，所以低于 `1000/P50`。错误数都是 0。

### 桥，ping 约 0.02 ms

| 模式 | 窗 | c | P50 | P99 | QPS |
|------|----|---|-----|-----|-----|
| 精确 | 30d | 1 | 16.074 | 44.655 | 16.17 |
| 精确 | 30d | 10 | 23.486 | 39.468 | 52.92 |
| 精确 | 30d | 50 | 20.676 | 97.849 | 53.24 |
| 朴素 | 30d | 1 | 3.325 | 5.853 | 19.96 |
| 朴素 | 30d | 10 | 3.399 | 8.604 | 96.26 |
| 朴素 | 30d | 50 | 4.506 | 12.168 | 89.04 |
| nGQL | 30d | 1 | 81.756 | 160.269 | 0.80 |
| nGQL | 30d | 10 | 76.304 | 158.340 | 1.02 |
| nGQL | 30d | 50 | 106.383 | 217.585 | 0.83 |
| 精确 | 7d | 1 | 3.216 | 9.581 | 20.47 |
| 精确 | 7d | 10 | 3.896 | 10.835 | 70.88 |
| 精确 | 7d | 50 | 4.140 | 12.575 | 62.95 |
| 朴素 | 7d | 1 | 1.417 | 3.362 | 20.85 |
| 朴素 | 7d | 10 | 2.505 | 4.271 | 101.47 |
| 朴素 | 7d | 50 | 1.876 | 9.308 | 123.89 |
| nGQL | 7d | 1 | 10.468 | 29.891 | 9.76 |
| nGQL | 7d | 10 | 13.588 | 23.073 | 14.73 |
| nGQL | 7d | 50 | 10.291 | 28.928 | 16.95 |

### 约 5.4 ms

| 模式 | 窗 | c | P50 | P99 | QPS |
|------|----|---|-----|-----|-----|
| 精确 | 30d | 1 | 47.331 | 68.906 | 10.96 |
| 精确 | 30d | 10 | 51.756 | 70.621 | 48.79 |
| 精确 | 30d | 50 | 89.963 | 183.530 | 61.14 |
| 朴素 | 30d | 1 | 27.501 | 33.144 | 10.69 |
| 朴素 | 30d | 10 | 41.108 | 49.243 | 70.66 |
| 朴素 | 30d | 50 | 40.937 | 53.637 | 120.35 |
| nGQL | 30d | 1 | 160.820 | 323.756 | 0.71 |
| nGQL | 30d | 10 | 173.314 | 405.844 | 0.96 |
| nGQL | 30d | 50 | 209.094 | 492.481 | 0.81 |
| 精确 | 7d | 1 | 28.896 | 37.825 | 10.82 |
| 精确 | 7d | 10 | 37.948 | 51.379 | 70.06 |
| 精确 | 7d | 50 | 39.986 | 50.076 | 123.63 |
| 朴素 | 7d | 1 | 24.812 | 29.777 | 11.23 |
| 朴素 | 7d | 10 | 38.324 | 57.287 | 71.81 |
| 朴素 | 7d | 50 | 38.842 | 58.469 | 133.28 |
| nGQL | 7d | 1 | 42.709 | 86.216 | 6.20 |
| nGQL | 7d | 10 | 44.138 | 95.806 | 13.87 |
| nGQL | 7d | 50 | 44.635 | 87.614 | 16.21 |

30 日、c=1、桥上，精确 P50 16.074 ms，nGQL 81.756 ms。同一格在约 5.4 ms 上是 47.331 对 160.820。朴素更快，因为它只把各机 top15 送回来，不把几千个买家的出边扫完；代价在下一节。

nGQL 的 30 日延迟波有一条样例行数：hop1 返回 5，反向边 326，买家出边 3475，FETCH 156。7 日那条是 1 / 5 / 16 / 12。这是延迟波里某一个用户，不是中位。

---

## 8. 准确率

12 个用户，`1 + i*997`（1, 998, …, 10968）。每个窗、每种模式各 12 条。真值是 `bench/copurchase/ground.py` 的 `exact`，规则和第 1 节相同，输入是生成器写下来的边，不是服务器再吐出来的边。

重叠率是 `|结果 id ∩ 真值 id| / |真值 id|`。真值不足 15 或 20 时分母是真值的长度。

| 模式 | 窗 | 用户重叠均值 | 用户列表全同 | 商品重叠均值 | 商品列表全同 |
|------|----|--------------|--------------|--------------|--------------|
| 精确 | 30d | 1 | 12/12 | 1 | 12/12 |
| 精确 | 7d | 1 | 12/12 | 1 | 12/12 |
| nGQL | 30d | 1 | 12/12 | 1 | 12/12 |
| nGQL | 7d | 1 | 12/12 | 1 | 12/12 |
| 朴素 | 30d | 0.106 | 0/12 | 0.375 | 0/12 |
| 朴素 | 7d | 0.289 | 1/12 | 0.375 | 2/12 |

朴素 30 日的 12 个用户重叠是 0, 0, 0, 0, 0, 0.067, 0.133, 0.133, 0.133, 0.200, 0.267, 0.333。商品重叠从 0.25 到 0.50。7 日有两条用户列表和两条商品列表与真值相同，其余用户重叠大多在 0.2 以下。

这 12 条上的跳统计（中位）：

| 模式 | 窗 | buyers | hop_rows | hop_hosts | scanned |
|------|----|--------|----------|-----------|---------|
| 精确 | 30d | 7404 | 5, 8139, 45, 60 | 1, 3, 3, 3 | 10, 8145, 79941, 153 |
| 精确 | 7d | 492 | 3, 492, 45, 59 | 1, 1, 3, 3 | 3, 496, 1679, 66 |
| 朴素 | 30d | 15 | 5, 45, 15, 60 | 1, 3, 3, 3 | 10, 8145, 189, 119 |
| 朴素 | 7d | 15 | 3, 15, 15, 31 | 1, 1, 3, 3 | 3, 496, 46, 31 |

`hop_rows` 四段是 hop1 的 top 商品、hop2a（朴素则是各机交回的用户行）、fused（朴素则是那 15 个人的商品收集）、hop4。`buyers` 是 graphd 去重后的人数。精确 30 日 hop2a 的行中位 8139，`buyers` 中位 7404：同一个人在两台机器上都买了焦点商品时，行数大于人数。用户 1 的那条是 `hop_rows=5,319,45,60`、`buyers=315`。fused 的 45 是三台各约 15，合并之后日志里的 `users=` 才是全局 15。`scanned` 的第三段是这些用户的出边：精确 30 日中位 79941，朴素只有 189，因为朴素不再扫那 7404 个人。

延迟波的 `plan_summary` 把 30 日和 7 日混在一起，而且 `nebula-graphd.INFO` 是指向同一文件的符号链接，行数被算了两次（exact 的 `n=360`，实际查询 180）。中位轮次仍是 4，`fallback_n=0`。表用上面这 12 条带窗标签的计划，不用那个混合中位。

`ground.py` 里还有一个按 part 切的朴素函数。服务器是按 host 切的：一个 storaged 上的多个 part 先合成一份再取 top15（30 日朴素 `hop_rows` 第二段中位 45，不是 9×15）。那个 Python 函数不复现服务器的用户集，文档里的损失只用服务器结果对精确真值。

---

## 9. 边界

- 只支持 INT64 vid。别的 vid 类型处理器返回 `E_INVALID_VID`，`copurchase_applied` 不置位，graphd 回退。
- 旗标默认关。语句不是语法的一部分，旗标关掉时解析器会报语法错。
- 边的时间在 rank 上，不在边上的属性里。`buy` 没有属性。
- 朴素的 `purchaseCount` 和 `latestTs` 只统计进了本地 top 的焦点边。精确路径统计窗内每一条出边。
- 回退把边拉回 graphd。单机小图上结果和精确路径相同；大图上它是兼容路径，不是压测里的第三列。
- nGQL 的存储 fanout 没有测。测到的是 4 句和每句的服务器时延之和。
- QPS 是墙钟。c=1 的墙钟含客户端间隔。基线还含把几千条边收到客户端的时间，所以 30 日 c=1 的墙钟是 37.4 s，而 P50 只有 81.8 ms。
- 约 5.4 ms 那一轮没有重跑准确率。重叠率不依赖 RTT，数字来自桥上那 72 条。
- 主机到 graphd 没有加延迟。RTT 是 namespace 之间的 ping。

剪枝、限额和 15 万用户上的 v1/v2 对比在 [43](43-copurchase-pushdown-prod.md)。
