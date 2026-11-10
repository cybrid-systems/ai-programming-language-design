# 48 — reco Q1–Q6：每个补丁打在哪条查询上，收益是什么

比较对象是 [47](47-reco-ngql-pushdown.md) 里六条已经改写过的 opt 语句。基线是 gcc-11 重编的上游 `fa92893`（标签 `00-baseline`），同一份 `reco` 数据。文档 47 的微秒来自另一份二进制，不放进本表。两边的结果多重集 SHA 相同。

补丁在 `patches/reco-q/`。原始 JSON 在 [bench/reco/patch-measure/](bench/reco/patch-measure/)。测量日期 2026-11-10。时延是 server `latency()` 的 p50，单位微秒，1 次预热加 7 次。

单机 loopback 还原不了跨机 P99。下面的差只对这台机器、这份夹具成立。00 到 10 同一次换二进制，负载从 `3.52` 降到 `0.96`，Q1/Q2/Q5/Q6 上几百微秒的起伏落在这条坡度里。

---

## 结论

这份夹具上，**没有一个补丁把任何一条 opt 语句稳定地变快。**

| 结论 | 依据 |
|------|------|
| 单独打上去就有计划或结果变化的，只有 02、05、06、07 | 02 让 Q3–Q6 少一层 Project，时延进了负载噪声。05/06/07 改 graphd 聚合，分数直方图不变 |
| Q3 收成 `GetDstBySrc` 必须连 11 | 只有 02+03+09（标签 10）时 Q3 变成 2719 行，90 天窗口被丢掉。加上 11 后回到 1801 行，SHA 与基线相同，p50 从 12217 升到 15622，**慢 28%** |
| 01、03、04、08、09 单独打，六条都不变 | 计划脊柱与 SHA 都等于基线 |
| 还留在 graphd、本轮没有补丁的大头 | Q1 的 TopN、Q2 的 MINUS、Q4/Q5/Q6 的全量 `GROUP BY`。Q4 基线 94852 µs，是六条里最重的一条 |

合入建议：不为了时延合入这些补丁。若合入 Q3 的 `GetDstBySrc` 改写，11 必须一起合，否则结果是错的；合入后这条在当前度数上更慢。

---

## 查询和补丁的对应

47 的 opt 已经把能走的简单 `Expand`、边列裁剪、`buy._rank` 过滤写进了语句。下表是这些语句上还剩什么，以及哪张补丁想再推进一步。

| 查询 | opt 在算什么 | 47 之后的计划落在哪 | 想再优化它的补丁 | 实测 |
|------|--------------|---------------------|------------------|------|
| Q1 最近购买 | 用户 2，`buy._rank` 最近 1800 秒，按时间倒序取 10 | 过滤已在 `ExpandAll`。`ORDER BY … LIMIT 10` 仍是 graphd `TopN` | **01 / 11**：把 rank 谓词变成 RocksDB seek | 01 的提取器只认 `kEdgeProperty`，`buy._rank` 是 `kEdgeRank`，seek 没发生。11 配上了，p50 377，落在其它标签的 382–482 里，看不出加速 |
| Q2 曝光减购买 | `expose` MINUS `buy`，两侧只要对端 | 两侧已是 `Expand`。`MINUS` 仍在 graphd | 无 | 十一份二进制的计划和 SHA 都不变 |
| Q3 美妆高潜用户 | 类型 1 的商品，反向 `buy`，90 天窗口，去重买家，`LIMIT 5000` | `HashInnerJoin` + `ExpandAll`，过滤在存储侧，边还要解码 | **02** 去掉 Join 上的 Project。**09** 想收成一次 `GetDstBySrc`。**11** 让 rank 窗口在这条路径上生效 | 02：计划少一层，时延噪声内。09 单独不匹配这条计划。10：2719 行，结果错。11：1801 行，慢 28% |
| Q4 共购再扩展 | 1 万用户的购买，按商品 `COUNT`，取共购 Top 100，再反向找出买家，外层 `LIMIT 100000` | 第一跳 `ExpandAll` 只带 `buy._dst`，`GROUP BY` 在 graphd。第二跳已是简单 `Expand` | **02** 去掉 Join 上的 Project。**05/06/07** 加速 graphd 的 `COUNT`。**03/09** 想把 `LIMIT` 推进 `Expand` | 02 改了计划。05/06/07 改了聚合哈希序；06/07 的外层行数 670→671，是 `co_buy=6` 的并列切分。`co_buy≥7` 的 87 个商品不变。03/09 打不中：第二跳已经是简单 `Expand`，100000 也不截断。时延随负载下降，不能写成补丁收益 |
| Q5 UserCF | 用户 2 的物品 → 共同买家 → 这些买家的物品，第三跳保留重复边做 `COUNT`，Top 20 | 前两跳已是 `Expand`。第三跳必须是 `ExpandAll`（`COUNT` 需要重复边）。聚合在 graphd | 同 Q4 的 **02、05、06、07** | 分数直方图始终是 `{8:1, 6:1, 5:1, 4:4, 3:5, 2:8}`。07 比 06 更慢（1609→1907）。无稳定加速 |
| Q6 ItemCF | 商品 `10000031733` 的买家，再买的其它商品，`COUNT`，Top 20 | 第一跳已是 `Expand`。第二跳 `ExpandAll`，过滤是 `buy._dst != 商品`，不是 rank | **02、05、06、07**。01 打不中，因为过滤不是 rank | 20 行分数都是 1。07 比 06 更慢（926→1064）。无稳定加速 |

---

## 每个补丁的收益

单元格是相对这条查询的动作。「不变」表示计划脊柱和结果 SHA 都等于 `00-baseline`。时延全表在附录。

| 补丁 | 它改什么 | Q1 | Q2 | Q3 | Q4 | Q5 | Q6 | 收益 |
|------|----------|----|----|----|----|----|----|------|
| 01 `01-rank-bounded` | `GetNeighbors` 按 rank 做 `rangeWithPrefix` | 想 seek，表达式种类没配上，不变 | — | 想 seek，没配上，不变 | — | — | — | **无。** seek 没执行 |
| 02 `02-project-down-join` | 去掉 HashInnerJoin 上方的 Project | — | — | 计划少一层 Project | 同左 | 同左 | 同左 | **计划变了，时延在噪声内。** SHA 与行数不变 |
| 03 `03-distinct-limit-single-src` | 单源 `DISTINCT`+`LIMIT` 下推到 Expand | — | — | — | 第二跳已经是简单 Expand，打不中 | — | — | **无** |
| 04 `04-agg-key-reuse` | 聚合键少一次拷贝 | — | — | — | 聚合仍是 List 键，不变 | 不变 | 不变 | **无** |
| 05 `05-agg-single-key` | 单列 `GROUP BY` 走 FastGroup | — | — | — | SHA 变，670 行，直方图不变 | SHA 变，直方图不变 | 同左 | **聚合路径变了。** 时延在噪声内。并列商品的输出顺序变了 |
| 06 `06-agg-int-count`（叠 05） | `COUNT` 用 int64 平坦表 | — | — | — | SHA 变，**671 行** | SHA 变，直方图不变 | 同左 | **无稳定加速。** 并行分片要求行数 ≥ 2^20，这份夹具进不去。多出的 1 行是 `co_buy=6` 并列切分 |
| 07 `07-topn-into-count`（叠 05+06） | TopN 的堆放进 COUNT 发射 | — | — | — | 计划仍是 `TopN Aggregate`，671 行 | 比 06 慢 | 比 06 慢 | **无。** 仍然扫完全部分组，存储 RPC 次数不变 |
| 08 `08-filter-prop-prune` | 过滤列已在输出列里时不再多读 | 过滤列本来就在 YIELD 里 | — | 同左 | — | — | 同左 | **无** |
| 09 `09-shared-dedup-limit`（叠 03） | 多源去重 + LIMIT 收成一次 `GetDstBySrc` | — | — | 中间还有 Project，规则不匹配，不变 | 外层 LIMIT 不截断，不变 | — | — | **无** |
| 10 = 02+03+09 | 让 09 的规则真正匹配 Q3。不是单独的补丁文件 | — | — | **结果错：2719 行** | 计划同 02，SHA 同基线 | 同左 | 同左 | **不能用。** 计划上有 `buy._rank>=1753660800`，存储没拿它做扫描 |
| 11 `11-getdst-rank-range`（叠 01+02+03+09） | `kEdgeRank` 收成精确窗口，交给 `GetDstBySrc` | seek 发生了，时延在噪声内 | — | 计划收成 `Limit Dedup Expand …`，**1801 行，慢 28%** | 计划同 02 | 同左 | 同左 | **Q3 结果修好了，时延变差。** 其余查询无新增收益 |

10 的 Q3 是 2719 行、SHA `e393e8dee9a4`，这是美妆商品的全部去重买家。11 的 Q3 是 1801 行、SHA `45e59fd185d339542050700fd013ad009249ef0e6de5d0b4110b6ee8995c4dc2`。基线 Q3 的 7 次样本是 11713–12666，11 是 15232–16014，区间不相交，而且 11 的负载更低。

Q4 在每个标签上，`co_buy≥7` 的 87 个商品都相同，探针直方图都是 9×2、8×19、7×66、6×13。Q5 的分数直方图都是 `{8:1, 6:1, 5:1, 4:4, 3:5, 2:8}`。Q6 的 20 行分数都是 1。

---

## 为什么 Q3 的改写更慢

11 把 Q3 从

```text
Limit Dedup Project HashInnerJoin … ExpandAll
```

收成

```text
Limit Dedup Expand Project TagIndexPrefixScan Start
```

`Expand` 上是 `dedup=1`、`limit=5000`、`filter=(buy._rank>=1753660800)`。存储从 rank `1753660800` 开始扫反向边。

这条路径打开 `sharedDedupLimit` 后是单线程顺序扫描。买家只有 1801，到不了 5000，提前停止不触发。反向边大约 80082/50000 条。少解码省下的时间盖不住少掉的 32 个 storage worker。基线的 `ExpandAll` 仍是这 32 个 worker 上的 `GetNeighbors`。

---

## 附录 A. 全部 server p50

`*` 表示 SHA 与基线不同。行数除注明外是 10 / 8 / 1801 / 670 / 20 / 20。

| 标签 | 负载 1/5/15 | Q1 | Q2 | Q3 | Q4 | Q5 | Q6 |
|------|-------------|----|----|----|----|----|----|
| 00-baseline | 3.52 / 7.54 / 8.22 | 441 | 372 | 12217 | 94852 | 1834 | 930 |
| 01-rank-bounded | 2.96 / 7.22 / 8.10 | 449 | 413 | 12019 | 98753 | 1940 | 1309 |
| 02-project-down-join | 2.67 / 7.01 / 8.03 | 382 | 371 | 11158 | 90326 | 1784 | 894 |
| 03-distinct-limit | 2.16 / 6.69 / 7.90 | 404 | 338 | 10867 | 91026 | 1687 | 877 |
| 04-agg-key-reuse | 1.82 / 6.46 / 7.82 | 411 | 360 | 11396 | 87245 | 1589 | 841 |
| 05-agg-single-key | 1.57 / 6.18 / 7.70 | 423 | 315 | 12295 | 91632* | 1631* | 936* |
| 06-agg-int-count | 1.41 / 5.99 / 7.63 | 386 | 345 | 11610 | 82452* / 671 行 | 1609* | 926* |
| 07-topn-into-count | 1.23 / 5.73 / 7.51 | 431 | 398 | 12144 | 81261* / 671 行 | 1907* | 1064* |
| 08-filter-prop-prune | 1.04 / 5.54 / 7.43 | 474 | 375 | 11988 | 96940 | 1754 | 866 |
| 09-shared-dedup | 0.88 / 5.36 / 7.35 | 455 | 330 | 12506 | 97517 | 1708 | 925 |
| 10-q3-compose | 0.96 / 5.16 / 7.25 | 482 | 325 | 15910* / 2719 行 | 89640 | 1712 | 947 |
| 11-q3-rank | 0.53 / 1.00 / 3.62 | 377 | 339 | 15622 | 87066 | 1813 | 1038 |

基线 SHA 前缀：Q1 `58819b84f72b`，Q2 `7d6a1faae17b`，Q3 `45e59fd185d3`，Q4 `51e9d5295d9e`，Q5 `5c0ebd20c7c7`，Q6 `d4500be032c7`。

05 的 Q4/Q5/Q6 前缀：`0afcfce9343a` / `bf5db3263c28` / `7c372080f88a`。06 和 07：`27bcc5e755fc` / `4337ac997e51` / `3cf23bf5ba94`。Q3 的 wall p50：基线 17084，10 是 23045，11 是 20192。编译穿插的上一轮在 `during-build/`，负载更高，上表不用。

00、01、03、04、05、06、07、08、09 的脊柱：

| 查询 | 脊柱 |
|------|------|
| Q1 | `TopN Project ExpandAll Expand Start`，过滤 `(buy._rank>=1761435000)` |
| Q2 | `Minus Project Dedup Expand PassThrough Start Project Dedup Expand` |
| Q3 | `Limit Dedup Project HashInnerJoin Project TagIndexPrefixScan Start ExpandAll Expand Argument`，过滤 `(buy._rank>=1753660800)`，边类型 `-15` |
| Q4 | `Project Limit Dedup Expand TopN Aggregate Sort Project HashInnerJoin Unwind Start ExpandAll Expand Argument` |
| Q5 | `TopN Aggregate Sort Project HashInnerJoin Project Dedup Expand Project Dedup Expand Start ExpandAll Expand Argument` |
| Q6 | `TopN Aggregate Sort Project HashInnerJoin Project Dedup Expand Start ExpandAll Expand Argument` |

02、10、11 在 Q4/Q5/Q6 上去掉 Join 上方的 Project，脊柱里 `Sort Project HashInnerJoin` 变成 `Sort HashInnerJoin`。10 和 11 的 Q3 脊柱是 `Limit Dedup Expand Project TagIndexPrefixScan Start`。rank seek 发生在迭代器里，EXPLAIN 不会多一个节点。

---

## 附录 B. 依赖、环境和重跑

在 `fa92893` 上能单独 `git apply` 的：01、02、03、04、05、08。06 要先有 05，07 要先有 05+06，09 要先有 03。11 要先有 01，并且 `GetDstBySrcProcessor` 已是 09 的版本。

09 自带 `JoinOutputColumn`，不先打 02 也能编译，此时 `hasOutputColumns()` 为假，Join 规则不改写。先 02 再 09 时，02 的 `Query.h` 会和这份 API 冲突，留下的 `Query.h.rej` 删掉即可；02 的 `Query.cpp` 和 `PushProjectDownHashInnerJoinRule` 要留下。

03 和 09 改了 `storage.thrift`，graphd 与 storaged 必须同一套。01 和 11 的 seek 在 storaged。metad 十一份都与基线逐字节相同。storaged 与基线逐字节相同的标签：02、05、06、07、08。

| 项 | 值 |
|----|----|
| 源码 | `/home/dev/code/nebula` 脱离在 `fa92893` 再打补丁。`operator-opt` 停在 `116b6a4`，补丁没有提交回 nebula |
| 编译 | g++-11，`NEBULA_THIRDPARTY_ROOT=/home/dev/nebula-third-party`，Release，`ENABLE_WERROR=ON`，`ENABLE_TESTS=OFF` |
| 进程 | `/tmp/nb`，127.0.0.1，9559 / 9779 / 9669。graphd `--enable_optimizer=true`。storaged 32 worker，block cache 4 MB |
| 数据 | user 1 万，product 5 万，buy 80082，expose 151866，美妆商品 2245。`now_sec=1761436800`。每用户 buy 度大约 20 |

```bash
bench/reco/swap_bins.sh /tmp/nb-bins/00-baseline all
python3 bench/reco/measure_patches.py \
  --label 00-baseline --rounds 7 \
  --out /tmp/reco-00.json
```

`--out` 不要指向已提交的 JSON。测完 `~/bin/nbctl stop` 再 `~/bin/nbctl start`，进程回到 `/home/dev/code/nebula-graph/build/bin`。
