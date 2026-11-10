# 50 — 局部 COUNT

49 说下一张值得写的是设计 C：多起点的 `GROUP BY edge._dst, COUNT` 在 storaged 里先按目的点加总，graphd 再把各分区的部分和加起来。`ORDER BY count | LIMIT` 留在 graphd。本文在放大后的 `reco` 上把这张补丁接到现在的六条 opt，并用同一个二进制做开关对比。

语句仍以 [dev.md](dev.md) 的 opt 为准。48 的 80k 边时延不能和这里的数字放在一张表里。

---

## 结论

全量分组对得上。Q4、Q5、Q6 去掉末尾 `LIMIT` 之后，`(vid, count)` 的排序多重集 SHA 两边相同。Q4 是 47425 组，Q5 是 46795 组，Q6 是 2559 组。

带 `LIMIT` 的最终行在并列处会换人。Q4 前 100 的 `co_buy` 直方图相同，所以 `co_buy >= 26` 的 80 个商品两边都在。100 个里有 85 个相同，多出来的 15 个落在 `co_buy = 25` 这一档（这一档在前 100 里占 20 个）。后面的反向 `GO` 因此得到 2083 和 2095 个用户。Q5 的 20 行分数多重集相同（24、23、23，然后 22 有 7 个，21 有 3 个，20 有 7 个），分数 20 的那一档会换商品。Q6 的 2559 个分组里，进 `LIMIT 20` 的分数全是 2，这 20 行整个都是并列。

时延是 server latency 的 p50，1 次热身加 7 次，负载大约 9–12。Q4 从 621 ms 到 193 ms，Q5 从 213 ms 到 82 ms。Q6 从 5.4 ms 到 4.1 ms。Q1、Q2、Q3 的计划没有 Aggregate，规则匹配不到，计划主干与开关前相同。

`TopN` 仍在合并聚合之上。没有加 `LIMIT [N]`，计数那一跳也没有 `DISTINCT`。

---

## 数据

用户仍是 1..10000，商品仍是 50000，`seed=42`，`now_sec=1761436800`。Q4 的 `UNWIND range(1, 10000)` 和 Q6 的商品 `10000031733` 都还在。`--edge-scale` 默认 1，把每个用户的购买条数和额外曝光条数乘上去。默认 1 重新生成出来仍是 80082 条 `buy`，用户 2 的 Q1 首行仍是 `10000019766 / 1761436409`。

这次加载用的是 `--edge-scale 8`：

| | scale 1 | scale 8 |
|--|---------|---------|
| 活跃用户近 30 分钟购买 | 12 | 96 |
| 活跃用户 90 天内其余购买 | 8 | 64 |
| 不活跃用户更早的购买 | 3 | 24 |
| `buy` | 80082 | 640656 |
| `expose` | 151866 | 1074928 |

640656 条购买边收成 47425 个在架商品，大约 13.5 比 1。最大入度 32，商品 `10000031733` 的入度是 25。清单在 `bench/reco/out-scale8/`。space `copurchase` 没有动。

换规模要先 `gen_vertices.py load` 重建 `reco`。`DROP EDGE` 的删除是异步的，紧接着插入会把前面的边清掉。两个生成器都不执行 `DROP EDGE`。

scale 8 上用户 2 的 Q1 首行是 `10000017687 / 1761436798`，10 行。用户 1 仍是空。Q2 是 64 行（用户 2）和 32 行（用户 1）。Q3 是 2945 行：160 次购买里几乎每个活跃用户都会碰到美妆，2946 个活跃用户里只差 1 个。这和 scale 1 的 1801 行不是同一份数据。

---

## 补丁

打在 `fa92893` 上，顺序是 `patches/v3.8.0-dst-only-edge-filter.patch`，然后 `patches/v3.8.0-partial-edge-agg.patch`。第二张是 15/16 的 `GetDstBySrc` 部分聚合：请求带 `aggs`，响应带 `partial_agg`。旧 storaged 不设这个位时，graphd 用同样的过滤走 `GetNeighbors` 再自己聚合。`--enable_dst_only_edge_filter` 保持默认关闭，所以 Q2、Q3 不会被另一条规则改写。`--enable_partial_edge_agg` 默认关闭。

opt 在 `GROUP BY` 前有 `ORDER BY $-.vid`。这个 `Sort` 夹在 `Aggregate` 和扫描之间，原来的 `absorb()` 只穿过 `Project` 和 `Filter`，规则匹配不上。现在 `Sort` 也穿过：它不改列名，重写时连同它一起拿掉。重写之后聚合的输入是 `Expand` 吐出的 `(_dst, 部分和)`，不再是直接从 `ExpandAll` 投影出来的 VID。

三跳分别是：

| 语句 | 被下推的聚合 | 过滤 |
|------|----------------|------|
| Q4 第一跳 | `COUNT(*)`，存储侧 `COUNT("*")` | 无 |
| Q5 第三跳 | `COUNT(1)` | 无 |
| Q6 第二跳 | `COUNT(1)` | `buy._dst != 10000031733`，留在这次 `Expand` 上 |

编译是文档 46 的 gcc-11 Release 配方。测量时 metad、storaged、graphd 都换成这套二进制，因为 `storage.thrift` 变了。开关只改 graphd 的 `--enable_partial_edge_agg`。测完这个 flag 已从 `/tmp/nb/conf/graphd.conf` 去掉。

---

## 计划

flag 关，Q4 的主干和 48 一样：

```
Project Limit Dedup Expand TopN Aggregate Sort Project HashInnerJoin Unwind Start ExpandAll Expand Argument
```

flag 开：

```
Project Limit Dedup Expand TopN Aggregate Expand Unwind Start
```

聚合键是 `$_dst`，`Expand` 上是 `partialAgg=["COUNT(\"*\")"]`。上面的 `TopN`、反向 `Expand` 和 `LIMIT` 还在。

Q5 关：`TopN Aggregate Sort Project HashInnerJoin … ExpandAll`。开：`TopN Aggregate Expand Project Dedup Expand Project Dedup Expand Start`，`partialAgg=["COUNT(1)"]`。

Q6 关：`TopN Aggregate Sort … ExpandAll`，过滤在 `ExpandAll`。开：`TopN Aggregate Expand …`，过滤和 `COUNT(1)` 都在同一个 `Expand` 上。

Q1 两边都是 `TopN Project ExpandAll Expand Start`。Q2 两边都是两条 `Expand` 再 `Minus`。Q3 两边都是 `Limit Dedup Project HashInnerJoin … ExpandAll`，过滤仍是 `buy._rank>=1753660800`。

---

## 时延

server latency，微秒。p50 后面的括号是 7 次里的最小和最大。JSON 在 `bench/reco/patch-measure/c-scale8-off.json` 和 `c-scale8-on.json`。

| 语句 | 关 | 开 | 最终行数 | 全量分组 |
|------|----|----|----------|----------|
| Q1 | 855 (638–1729) | 1495 (799–18579) | 10 / 10，SHA 相同 | 无分组 |
| Q2 | 752 (561–2349) | 2050 (1257–10506) | 64 / 64，SHA 相同 | 无分组 |
| Q3 | 38202 (36929–49331) | 61866 (41518–70075) | 2945 / 2945，SHA 相同 | 无分组 |
| Q4 | 621311 (595137–653140) | 192798 (159183–204204) | 2083 / 2095 | 47425 组，SHA 相同 |
| Q5 | 212911 (198946–217568) | 81570 (73774–99767) | 20 / 20 | 46795 组，SHA 相同 |
| Q6 | 5404 (4555–6376) | 4111 (3762–4996) | 20 / 20 | 2559 组，SHA 相同 |

Q4 的 wall p50 从 628481 到 199870。只跑分组、不跑后面反向 `GO` 的那一次（不是 7 次中位数）是 609709 到 158908。Q5 那一次是 214383 到 81513，Q6 是 4889 到 3886。

Q4、Q5 两边的区间没有重叠。Q1、Q2 的计划相同，p50 差在 1 ms 这一档，区间重叠。Q3 的计划也相同，p50 从 38 ms 到 62 ms，区间在 41–49 ms 碰到。这条语句没有 `Aggregate`，`PushPartialEdgeAggRule` 不会进 `match()`。当时 loadavg 大约 9–12。

Q4 前 100 的 `co_buy` 直方图两边都是 32×1、30×2、29×3、28×11、27×21、26×42、25×20。100 个商品里有 85 个相同。Q5 的分数直方图两边都是 24×1、23×2、22×7、21×3、20×7。样本里分数 24 和两个 23 的商品相同。

---

## 还没做的

设计 D（`MINUS` 融合）和设计 E（两阶段 TopN）这次没有写。Q1 的 `TopN`、Q2 的 `MINUS`、Q5/Q6 的 `LIMIT 20` 仍在 graphd。Q3 仍走 `GetNeighbors`。49 里「Q3 若还要动，只修 `GetNeighbors` 对 `kEdgeRank` 的 seek」这一点没变。
