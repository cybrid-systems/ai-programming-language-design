# 51 — 补丁和六条场景

语句以 [dev.md](dev.md) 的 opt 为准。编号 01–11 的测量在 [48](48-reco-operator-patches.md)，边界说明在 [49](49-reco-patch-map.md)，局部 COUNT 的开关对比在 [50](50-reco-partial-count.md)。本文把它们和 12–15 收成一张对照。两套夹具的微秒不能写进同一列。

scale 1 是 80082 条 `buy`。scale 8 是 640656 条 `buy`，清单在 `bench/reco/out-scale8/`。space `copurchase` 没有动。

---

## 场景

| 场景 | 算子现在在哪 | 编号 | 实测 |
|------|----------------|------|------|
| Q1 最近购买 | 时间窗在 `ExpandAll.filter`。`ORDER BY ts DESC \| LIMIT 10` 是 graphd `TopN` | 01、11 想做 rank seek。14 是设计 E，把降序 Top 10 放进 `GetNeighbors` | scale 8 上 14 的 10 行 SHA 与关相同（`a091c6eb7ba2`）。`rankTopN: 10`，`rank_topn_applied` 为 1，存储回 10 行。窗口里大约 96 条边，p50 从 504 µs 到 449 µs，区间重叠。01 没认出 `kEdgeRank`。11 在小夹具上的 seek 落在 382–482 µs 里 |
| Q2 看过但没买 | 两侧已经是 `getDstBySrc`。`MINUS` 在 graphd | 13 是设计 D，同一起点的差集进一次 `GetDstBySrc` | 64 行，SHA `97ea73403731`，与关相同。计划收成 `Project Dedup Expand`，`minusEdgeTypes` 是 buy，`minus_applied` 为 1。紧挨着的一对 Q2：关 515 µs（459–606），开 394 µs（352–544），区间重叠 |
| Q3 美妆高潜 | `LOOKUP` 在索引上。90 天过滤在 `ExpandAll`。全局 `DISTINCT` 和 `LIMIT 5000` 在 graphd | 10、11 想收成 `GetDstBySrc`。15 是设计 F，只在 `Dedup` 上标注 `stopAfter` | 小夹具上 10 是 2719 行。11 回到 1801 行，p50 12217 → 15622，慢 28%。scale 8 上 F 仍是 2945 行，SHA `6f4ed19c98e4`。`stopAfter: 5000`，`dedup_limit_binds` 为 0（21030 行进，2945 行出）。p50 23987 → 22768，区间重叠 |
| Q4 共购再扩展 | 第一跳 `COUNT(*)` 原来整段回到 graphd。第二跳 `DISTINCT` 已经是 `getDstBySrc` | 04–07 改 graphd 哈希表。12 是设计 C，第一跳局部 COUNT。15 给外层 `LIMIT 100000` 上面的 `Dedup` 标 `stopAfter` | C：全量 47425 组 SHA 相同，p50 621 ms → 193 ms。04–07 没有少掉这次扫描。F 的 `stopAfter` 是 100000，最终行 SHA 与关相同，2083 行小于这个上限 |
| Q5 UserCF | 前两跳 `DISTINCT` 已经是 `getDstBySrc`。第三跳 `COUNT(1)` 要留重复边 | 12 打第三跳 | 全量 46795 组 SHA 相同，p50 213 ms → 82 ms。07 把堆塞进 COUNT，RPC 还在，小夹具上比 06 慢 |
| Q6 ItemCF | 第一跳 `DISTINCT buy._dst` 已经是买家。第二跳先滤 `buy._dst != 商品` 再 `COUNT(1)` | 12 打第二跳。设计 B 取消 | 全量 2559 组 SHA 相同，p50 5.4 ms → 4.1 ms。反向边的 `buy._dst` 就是买家 |

设计 A 要解决的「管道起点不能 `getDstBySrc`」，在无过滤、只取 `edge._dst` 时，3.8 的简单计划已经做到。Q4 第二跳、Q5 前两跳、Q6 第一跳都是。带 rank 过滤的 Q3 不要再扩这条路，那就是 11。

设计 B 不写补丁。`REVERSELY` 下 `buy._dst` 是买家。

设计 E 只推 Q1 这种「按 `buy._rank` 降序、再 `LIMIT`」的 `TopN`。Q5、Q6 的 `TopN` 排的是聚合分数，规则匹配不到。局部 Top-K 计数会把「每个分区的第一名」加成全局名次，这两条不做。

设计 F 不删行。`Dedup` 用交换删除，扫完之前的前 N 行不是最终的去重顺序。执行器只在扫完后记 `dedup_limit_binds`。把 `LIMIT` 推进 `GetDstBySrc` 就是 11 那条单线程扫描。

---

## 编号

| 编号 | 信 | 文件 | 打在 | 一句话 |
|------|----|------|------|--------|
| 01 | rank seek | `patches/reco-q/01-rank-bounded.patch` | Q1、Q3 的 `ExpandAll.filter` | 只认 `kEdgeProperty`。`buy._rank` 是 `kEdgeRank`，seek 没发生 |
| 02 | 去掉 Join 上的 Project | `02-project-down-join.patch` | 为了让 09 看见 Q3 | SHA 不变。单独打，六条时延在噪声里 |
| 03 | 单源 `LIMIT` | `03-distinct-limit-single-src.patch` | 设计 A 的一小块 | 单独打，六条不变 |
| 04 | 聚合键复用 | `04-agg-key-reuse.patch` | Q4 的 graphd 哈希表 | 扫描还在。时延随负载走 |
| 05 | 单列分组 | `05-agg-single-key.patch` | Q4、Q5、Q6 | 分数直方图不变。并列顺序变了，SHA 变，行数不变 |
| 06 | int64 计数表 | `06-agg-int-count.patch`，要叠 05 | Q4 | 小夹具 Q4 从 670 行到 671 行，多出来的是 `co_buy = 6` 的并列。`co_buy ≥ 7` 的商品还在 |
| 07 | 堆塞进 COUNT | `07-topn-into-count.patch`，要叠 05+06 | 有人把它当成 E | 计划仍是 `TopN Aggregate`。Q5、Q6 比 06 慢。扫描还在 |
| 08 | 过滤列裁剪 | `08-filter-prop-prune.patch` | 过滤列已经在 `YIELD` 里 | 六条不变 |
| 09 | 共享去重加 limit | `09-shared-dedup-limit.patch`，要叠 03 | 想收 Q3 | 单独打匹配不到 Q3。Join 上面还有 Project |
| 10 | 02+03+09 | 没有单独文件 | Q3 | 2719 行。90 天窗口被丢掉。不能用 |
| 11 | `kEdgeRank` 窗口 + 10 | `11-getdst-rank-range.patch` | Q3，顺带 Q1 的 seek | Q3 回到 1801 行，慢 28%。共享去重把扫描收成单线程，`LIMIT 5000` 又大于结果集 |
| 12 | C 局部 COUNT | 见 [`12-partial-edge-agg.md`](patches/reco-q/12-partial-edge-agg.md) | Q4 第一跳、Q5 第三跳、Q6 第二跳 | 全量分组 SHA 相同。Q4 621 ms → 193 ms，Q5 213 ms → 82 ms，Q6 5.4 ms → 4.1 ms |
| 13 | D `MINUS` 融合 | 和 14、15 在同一张 [`13-15-minus-rank-topn-dedup-stop.patch`](patches/reco-q/13-15-minus-rank-topn-dedup-stop.patch) | 只有 Q2 | 64 行 SHA 相同。见下面的开关 |
| 14 | E rank TopN | 同上 | 只有 Q1 | 10 行 SHA 相同。`TraverseSpec.limit` 仍是「按 rank 从旧到新的前 N 条」，这张用的是新字段 `rank_topn` |
| 15 | F `stopAfter` | 同上 | Q3 的 5000，Q4 外层的 100000 | 行集不变。扫描不缩短 |
| B | REVERSELY 映射 | 不写 | — | 取消 |

12 的两张 diff 打在 `fa92893` 上，顺序是 `v3.8.0-dst-only-edge-filter.patch`，然后 `v3.8.0-partial-edge-agg.patch`。第二张的新文件头是 `@@ -0,0 +1,429 @@`。13–15 这一张再叠上去。01–11 单独打在 `fa92893` 上，不要叠到 12 的二进制上。

四个开关都默认关闭，彼此独立：

| 编号 | graphd 开关 |
|------|-------------|
| 12 | `--enable_partial_edge_agg` |
| 13 | `--enable_minus_fusion` |
| 14 | `--enable_traverse_rank_topn` |
| 15 | `--enable_dedup_limit_stop` |

`--enable_dst_only_edge_filter` 保持关闭。打开它会把带过滤的 `DISTINCT` 收成 `GetDstBySrc`。

旧 storaged 不认新字段时：12 看 `partial_agg`，没有就退回 `GetNeighbors` 再在 graphd 聚合；14 看 `rank_topn_applied`，没有就仍由 graphd `TopN` 排全量；13 看 `minus_applied`，没有就两次 `GetDstBySrc` 再在 graphd 做差。13 的确认位不能省。旧 storaged 若忽略 `minus_edge_types`，响应里只有左侧，那是错的差集。15 不进存储协议。

13 只融合「左右各一个、而且是同一个常量 VID」的 `MINUS`。多个起点的全局差集，不等于各分区差集的并：起点 1 曝光了 P、起点 2 买了 P，全局要去掉 P，按起点各自相减再并起来会留下 P。Q2 是 `GO FROM 2`，满足这一条。

---

## scale 1 的时延

server latency 的 p50，单位微秒，1 次热身加 7 次。行数除注明外是 10 / 8 / 1801 / 670 / 20 / 20。`*` 表示 SHA 与 00 不同。全表和负载在 [48 附录 A](48-reco-operator-patches.md)。JSON 在 `bench/reco/patch-measure/00-baseline.json` 到 `11-*.json`。

| 标签 | Q1 | Q2 | Q3 | Q4 | Q5 | Q6 |
|------|----|----|----|----|----|----|
| 00 | 441 | 372 | 12217 | 94852 | 1834 | 930 |
| 05 | 423 | 315 | 12295 | 91632* | 1631* | 936* |
| 06 | 386 | 345 | 11610 | 82452*，671 行 | 1609* | 926* |
| 07 | 431 | 398 | 12144 | 81261*，671 行 | 1907* | 1064* |
| 10 | 482 | 325 | 15910*，2719 行 | 89640 | 1712 | 947 |
| 11 | 377 | 339 | 15622 | 87066 | 1813 | 1038 |

01、02、03、04、08、09 的六列落在这段里：Q1 382–474，Q2 330–413，Q3 10867–12506，Q4 87245–98753，Q5 1589–1940，Q6 841–1309。和 00 比，没有一条稳定地更短。

00 的 SHA 前缀：Q1 `58819b84f72b`，Q2 `7d6a1faae17b`，Q3 `45e59fd185d3`。Q3 在 scale 8 上是 2945 行，SHA `6f4ed19c98e4`，和上面的 1801 不是同一份数据。

01、02、03、04、05、08 可以单独 `git apply`。06 叠 05，07 叠 05+06，09 叠 03，11 叠 01 和已经打过 09 的 `GetDstBySrcProcessor`。03 和 09 都改 `storage.thrift`。09 带 `JoinOutputColumn`，先打 02 再打 09 会在 `Query.h` 上冲突。

---

## scale 8 的局部 COUNT

这是另一套二进制，JSON 是 `c-scale8-off.json` 和 `c-scale8-on.json`。下面的毫秒只和这一对比。细节和直方图在 [50](50-reco-partial-count.md)。

| | 关 | 开 | 全量分组 |
|--|----|----|----------|
| Q4 | 621 ms | 193 ms | 47425 组，SHA `e9db60c2c11e` |
| Q5 | 213 ms | 82 ms | 46795 组，SHA `885debd49d46` |
| Q6 | 5.4 ms | 4.1 ms | 2559 组，SHA `307127de67d4` |

带 `LIMIT` 的最终 SHA 会在并列处换人。Q4 前 100 的 `co_buy` 直方图相同：32×1、30×2、29×3、28×11、27×21、26×42、25×20。`co_buy ≥ 26` 的 80 个商品两边都在。Q1–Q3 没有聚合，计划与关相同，那一轮 p50 的起伏不要算进 C。

`ORDER BY` 那个 VID 要留在 `GROUP BY` 前面，规则把这个 `Sort` 吸掉再下推。计数那一跳不加 `DISTINCT`，也不加 `LIMIT [N]`。

---

## scale 8 的 D、E、F

同一套二进制，C 的代码在里面，`--enable_partial_edge_agg` 关闭。一次只开一个开关。1 次热身加 7 次。JSON：

| 文件 | 开关 |
|------|------|
| `bench/reco/patch-measure/def-scale8-off.json` | 全关 |
| `def-scale8-d.json` | 只开 13 |
| `def-scale8-e.json` | 只开 14 |
| `def-scale8-f.json` | 只开 15 |

关的时候 p50（最小–最大），单位微秒：Q1 504（406–692），Q2 451（326–526），Q3 23987（21837–24464），Q4 458026（450716–464777），Q5 148290（145264–153084），Q6 3341（3213–3448）。这一列和上面 C 的 621 ms 不是同一次进程，不能相减。

| 开关 | 被改到的查询 | 行 / SHA | p50 |
|------|----------------|----------|-----|
| 13 | Q2 | 64 / `97ea73403731`，与关相同 | 这次 JSON 是 396 µs，负载大约 0.7，关那轮负载大约 3–6。紧挨着再跑的一对是 515 → 394，区间重叠 |
| 13 | Q1、Q3–Q6 | SHA 与关相同，分组 SHA 也相同 | Q4 463 ms，Q5 148 ms，落在关的区间里 |
| 14 | Q1 | 10 / `a091c6eb7ba2` | 449（403–535） |
| 14 | Q2–Q6 | SHA 与关相同 | 计划主干不变。Q5、Q6 的 `TopN` 不是 rank |
| 15 | Q3 | 2945 / `6f4ed19c98e4` | 22768（22027–23039） |
| 15 | Q1、Q2、Q4–Q6 | SHA 与关相同 | Q4 的 `Dedup` 带 `stopAfter: 100000`，行数仍是 2083 |

三张都没有把 Q4 的 458 ms 降下去。scale 8 上还明显短于 35 ms 目标的，是 12 的 Q4 和 Q5。13 的两侧是 64 和 160 条边，14 的窗口大约 96 条边，15 的上限大于结果集。

13 第一版二进制把存储返回的列名 `_dst` 和 `Expand` 的 `_expand_vid` 对不上，`DataSet::append` 把行丢掉，Q2 变成 0 行。现在的 `def-scale8-d.json` 是改列名之后的那一轮。

---

## 仍然留在 graphd 的

- 最终的 `ORDER BY count DESC | LIMIT`。局部计数可以相加，局部名次不能当成全局名次。
- 跨分区的并、全局 `DISTINCT`、全局 `MINUS` 的多起点情形。
- Q3 的 `GetNeighbors` 扫描。要再动它，只在这条路径上对 `kEdgeRank` 做 seek，并且保持并行。不要走 10 或 11。
- `LIMIT [N]`。它按 rank 从旧到新停，还会关掉简单计划。六条 opt 里都没有它。
