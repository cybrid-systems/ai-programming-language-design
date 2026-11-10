# 49 — 六条查询的下推边界，以及补丁该打在哪

语句以 [dev.md](dev.md) 里现在能跑的写法为准，数字以 [47](47-reco-ngql-pushdown.md) 和 [48](48-reco-operator-patches.md) 的实测为准。下面这版设计稿里有三处和实测相反，本文按实测改过来：

- `LIMIT [N]` 是逐步截断，按 rank 从旧到新停，而且会关掉简单计划。它不是「每个顶点最近 N 条」。六条 opt 都没有它。
- `REVERSELY` 下 `buy._dst` 就是买家，和 `src(edge)` 等价。改写成 `buy._dst` 不会返回商品自己。补丁 B 取消。
- `YIELD DISTINCT edge._dst` 在管道起点上已经走 `getDstBySrc`。多起点本身不断开这条路。断开它的是过滤、逐步 `LIMIT`，以及 `COUNT` 必须保留的重复边。

`$user_id` 不能写进 `GO FROM`。`| WHERE` 不是合法管道子句。过滤写在 `GO` 段里，列名用 `` `buy._rank` ``。`GROUP BY` 前要先 `ORDER BY` 那个 VID，否则这条二进制上聚合键是空的。

---

## 结论

| 还留在 graphd 的 | 根因 | 补丁 | 这份夹具上的结论 |
|------------------|------|------|------------------|
| Q1 的 `ORDER BY ts DESC \| LIMIT 10` | 全局 TopN | 设计 E，未做 | 过滤后只有大约 10 条边，两阶段 RPC 不划算。01 的 rank seek 没配上表达式种类 |
| Q2 的 `MINUS` | 集合运算 | 设计 D，未做 | 两侧已经是 `getDstBySrc`。差集仍在 graphd。度大约 20，融合看不出 |
| Q3 的 90 天过滤 + 全局去重 | 有过滤就不能走简单计划 | 09+11 把整段收成 `GetDstBySrc` | 结果能修对，p50 12217 → 15622，**慢 28%**。不要为了时延合入 |
| Q4 第一跳 `GROUP BY + COUNT` | 局部聚合没有做 | 设计 C，未做。04–07 只改 graphd 哈希表 | **这是六条里唯一的大头，基线 94852 µs。** 现有补丁没有把它搬进 storaged |
| Q4 第二跳、Q5 前两跳、Q6 第一跳的 `DISTINCT` | 无。nGQL 已经是 `getDstBySrc` | 设计 A/B 都不需要再写 | 计划已经是 `Expand` |
| Q5 第三跳、Q6 第二跳的 `COUNT` | 同 C。这两跳必须留重复边 | 设计 C | 07 把堆塞进 COUNT，RPC 次数不变，Q5/Q6 更慢 |
| Q5/Q6 的 `ORDER BY + LIMIT 20` | 全局 TopN | 设计 E，未做 | 要等 C 把候选压小之后才有意义。单独做两阶段会多一次往返 |

落地顺序改成：**先不要合 10；C 是下一张值得写的补丁；B 取消；A 的无过滤情形已经在 3.8 里；D 和 E 留到超级点上再估。**

---

## 场景 1：最近购买

基线把时间窗放在管道 `YIELD` 上，整段出边回到 graphd 再滤。opt 把谓词放进 `GO`：

```sql
GO FROM 2 OVER buy WHERE buy._rank >= 1761436800 - 1800 YIELD buy._dst AS pid, buy._rank AS ts | ORDER BY $-.ts DESC | LIMIT 10;
```

| 算子 | 现在在哪 | 说明 |
|------|----------|------|
| `buy._rank >= 1761435000` | storaged，`ExpandAll.filter` | 不满足的边不进回传。计划是 `TopN Project ExpandAll` |
| 投影 `buy._dst`, `buy._rank` | storaged | 只回这两列 |
| `ORDER BY ts DESC \| LIMIT 10` | graphd `TopN` | `PushLimitDownExpandAllRule` 只认 `Limit` 直接压在 `ExpandAll` 上，不认 `TopN` |
| rank seek | 没发生 | `buy._rank` 是 `kEdgeRank`。补丁 01 只认 `kEdgeProperty`，整段前缀照扫。补丁 11 配上了种类，Q1 p50 377，落在 382–482 的噪声里 |

`LIMIT [10]` 会返回最旧的 10 条，并且这条就不再是「过滤后排序取最新」。opt 不加它。最近 10 条要的是降序；存储键是 rank 升序，没有反向迭代器。

补丁 01 是这条查询唯一对得上的存储补丁，实测没有收益。设计 E 打的是全局 TopN，这份数据上用户 2 的窗口里本来就只有 10 条边。

---

## 场景 2：看过但没买

```sql
GO FROM 2 OVER expose YIELD DISTINCT expose._dst AS pid MINUS GO FROM 2 OVER buy YIELD DISTINCT buy._dst AS pid;
```

两侧都是单起点、无过滤、`YIELD DISTINCT edge._dst`。EXPLAIN 已经是两个 `Expand`（`getDstBySrc`），存储侧去重已经发生。`MINUS` 仍在 graphd。

设计 D 是把同一个起点的 expose 和 buy 合成一次 storaged 差集。分支和 `patches/reco-q/` 里都没有这张补丁。用户 2 的两侧都是个位数到几十条，融合的收益在这份夹具上测不出来。超级点上它才是 Q2 的下一张补丁。

`LIMIT [5000]` 会关掉上面的简单计划，和 `edge._dst` 互斥。opt 不加。

---

## 场景 3：美妆高潜用户

```sql
LOOKUP ON product WHERE product.type == 1 YIELD id(vertex) AS pid | GO FROM $-.pid OVER buy REVERSELY WHERE buy._rank >= 1761436800 - 7776000 YIELD buy._dst AS uid | YIELD DISTINCT $-.uid AS high_potential_user | LIMIT 5000;
```

`REVERSELY` 下 `buy._dst` 是买家。实测 1801 行，SHA `45e59fd185d3`。不要改回 `src(edge)`：那一列是 `kEdgeSrc`，简单计划不认，去重会退回 graphd。

| 算子 | 现在在哪 | 补丁打过没有 |
|------|----------|--------------|
| `LOOKUP` 索引 | storaged `TagIndexPrefixScan` | 数据获取，不是这批补丁 |
| `buy._rank >= 1753660800` | `ExpandAll.filter`，扫的时候逐条丢 | 01 想改成 seek，种类没配上 |
| 边列只有 `_dst` | storaged | 47 的写法已经做到 |
| 因为有 `WHERE`，走 `GetNeighbors` 而不是 `getDstBySrc` | 多起点 + 过滤 | 09 想收成一次 `GetDstBySrc` |
| 全局 `DISTINCT` 和 `LIMIT 5000` | graphd | 1801 < 5000，截断不发生 |

09 单独不匹配：Join 上面还有一层 Project。02 去掉那层之后规则才开火。02+03+09（标签 10）把过滤文本留在计划上，存储却整段扫描，结果变成 2719 行，那是全部去重买家。11 把 `kEdgeRank` 收成下界交给 `SingleEdgeNode`，行数回到 1801，p50 15622，比基线慢 28%。原因是共享去重把扫描收成单线程，32 个 storage worker 没了，提前停止又到不了 5000。

所以 Q3 的下一张补丁不是再改写计划，而是让现有的 `GetNeighbors` 路径认出 `kEdgeRank` 做 seek，并且继续并行。11 在 Q1 上试过这条 seek，度大约 20，看不出加速。美妆商品的反向边更稀，seek 同样不是这份夹具的大头。

---

## 场景 4：共购再扩展

```sql
UNWIND range(1, 10000) AS uid | GO FROM $-.uid OVER buy YIELD buy._dst AS pid | ORDER BY $-.pid | GROUP BY $-.pid YIELD $-.pid AS pid, COUNT(*) AS co_buy | ORDER BY $-.co_buy DESC | LIMIT 100 | GO FROM $-.pid OVER buy REVERSELY YIELD DISTINCT buy._dst AS ext_user | LIMIT 100000;
```

`ORDER BY $-.pid` 必须留在 `GROUP BY` 前面。拿掉它，这条二进制的聚合键是空的，结果是 0 行。第一跳不能加 `DISTINCT`：`COUNT` 要数边。

| 跳 | 计划 | 下推情况 |
|----|------|----------|
| 第一跳 | `ExpandAll`，边列只有 `buy._dst` | 投影下了。`GROUP BY + COUNT + TopN 100` 全在 graphd。1 万用户 × 约 20 条边在 graphd 聚合 |
| 第二跳 | `Expand`，`getDstBySrc` | `YIELD DISTINCT buy._dst` 已经是存储侧去重，尽管起点来自管道。`LIMIT 100000` 不截断 |

设计 A 要解决的「管道起点不能 `getDstBySrc`」，第二跳已经做到了。第一跳做不到，是因为要保留重复边，不是因为起点来自 `UNWIND`。

设计 C 才打第一跳：storaged 按商品回 `(pid, partial_count)`，graphd 把计数相加，再做 Top 100。`COUNT` 数的是边。同一用户对同一商品的多条边要累加，不能在存储侧先对 dst 去重。Top 100 不能在 storaged 做，局部 TopN 会丢全局名次。

现有的 04、05、06、07 都是 graphd 里的哈希表。05 改了并列商品的输出顺序，分数直方图不变。06/07 让外层从 670 行变成 671 行，`co_buy≥7` 的 87 个商品不变。时延随负载下降，没有一张把 95 ms 的第一跳搬进 storaged。

第二跳不要加 `LIMIT [20000]`。那会关掉已经在跑的 `getDstBySrc`，并且按 rank 从旧到新截断。

---

## 场景 5：UserCF

```sql
GO FROM 2 OVER buy YIELD DISTINCT buy._dst AS x | GO FROM $-.x OVER buy REVERSELY YIELD DISTINCT buy._dst AS u2 | GO FROM $-.u2 OVER buy YIELD buy._dst AS y | ORDER BY $-.y | GROUP BY $-.y YIELD $-.y AS rec_item, COUNT(1) AS score | ORDER BY $-.score DESC | LIMIT 20;
```

| 跳 | 计划 | 原因 |
|----|------|------|
| 第 1 跳 | `Expand` | 单起点 + `DISTINCT buy._dst` |
| 第 2 跳 | `Expand` | 管道起点也走了 `getDstBySrc`。`REVERSELY` 下 `buy._dst` 是共同买家 |
| 第 3 跳 | `ExpandAll`，只带 `buy._dst` | `COUNT` 需要重复边，不能 `DISTINCT` |
| 聚合和 Top 20 | graphd | 设计 C 打聚合，设计 E 打 Top 20 |

分数直方图在每个补丁上都是 `{8:1, 6:1, 5:1, 4:4, 3:5, 2:8}`。07 比 06 更慢（1609 → 1907）。三跳都不要加 `LIMIT [N]`。

---

## 场景 6：ItemCF

```sql
GO FROM 10000031733 OVER buy REVERSELY YIELD DISTINCT buy._dst AS uid | GO FROM $-.uid OVER buy WHERE buy._dst != 10000031733 YIELD buy._dst AS item | ORDER BY $-.item | GROUP BY $-.item YIELD $-.item AS rec_item, COUNT(1) AS score | ORDER BY $-.score DESC | LIMIT 20;
```

| 算子 | 现在在哪 |
|------|----------|
| 第一跳 `DISTINCT buy._dst` | `Expand` / `getDstBySrc`。买家就是 `buy._dst`。这是设计 B 想写的映射，nGQL 改写已经拿到 |
| 第二跳 `buy._dst != 10000031733` | `ExpandAll.filter`。排除条件在扫边时丢掉。这不是 rank，补丁 01 打不中 |
| 第二跳投影 | 只回 `buy._dst` |
| `GROUP BY + COUNT` 和 Top 20 | graphd。第二跳必须留重复边 |

20 行的分数都是 1。07 比 06 更慢（926 → 1064）。第一跳不要改回 `src(edge)`，也不要加 `LIMIT [2000]`。

---

## 根因：哪些还在，哪些已经被语句打掉

| 编号 | 设计稿里的说法 | 按现在的计划和二进制 |
|------|----------------|----------------------|
| R1 管道起点断掉 `getDstBySrc` | 起点来自 `$-` 就不能简单计划 | **无过滤、只取 `edge._dst` 时不成立。** Q4 第二跳、Q5 第 2 跳、Q6 第一跳都是管道起点上的 `Expand`。过滤（Q1、Q3、Q6 第二跳）和「要数重复边」（Q4 第一跳、Q5 第 3 跳、Q6 第二跳）才会留下 `ExpandAll` |
| R2 `REVERSELY` 认不出买家 | `src(edge)` 对不上 `edge._dst`，硬改会返回商品 | **不成立。** 反向边在存储里已经把 src/dst 对调。`buy._dst` 就是买家。补丁 B 取消 |
| R3 多起点聚合没有局部和 | `COUNT` 可以分片再相加，TopN 不行 | **成立，而且没做。** 这是 Q4 的 95 ms |
| R4 `MINUS` 没有本地差集 | 同一起点的两组边可以在 storaged 相减 | **成立，没做。** Q2 两侧的去重已经在存储侧 |
| R5 全局 TopN 没有阈值剪枝 | 局部 TopN 不等于全局 TopN | **成立，没做。** Q1 的候选集太小。Q5/Q6 要先有 C，否则剪的是还没聚合的边 |

跨 host 的最终去重和最终排序仍然要全量可见。补丁只负责把进这道全局计算的行变少。

---

## 补丁对照

设计稿的 A–F，和 `patches/reco-q/` 里已经切开的 01–11。

| 设计 | 仓库里的补丁 | 打哪几条 | 实测 |
|------|--------------|----------|------|
| A 管道去重下推 | 3.8 的 `isSimpleCase` 已经覆盖无过滤的 `DISTINCT edge._dst`。03 是单源 `LIMIT` 下推。09 是「带过滤的 Join + ExpandAll」收成一次 `GetDstBySrc` | Q2、Q4 第二跳、Q5 前两跳、Q6 第一跳靠语句，不靠新补丁。09 的目标是 Q3 | 03、09 单独打，六条不变。09 要叠 02 才改 Q3，再叠 11 才结果正确，然后变慢 |
| B REVERSELY 映射 | 不写 | Q3、Q4 第二跳、Q5 第 2 跳、Q6 第一跳用 `buy._dst` | 取消。语句已经等价 |
| C 局部 `COUNT` | **没有。** 04 键复用，05 单列 FastGroup，06 int64 表，07 堆塞进发射，全在 graphd | Q4 第一跳，Q5 第 3 跳，Q6 第二跳 | 分数直方图不变。06/07 的 Q4 多 1 行并列。没有少 RPC |
| D `MINUS` 融合 | 没有 | Q2 | 无变化 |
| E 两阶段 TopN | 没有。07 不是它 | Q1、Q5、Q6 的最终 TopN | 07 的计划仍是 `TopN Aggregate`，Q5/Q6 比 06 慢 |
| F 全局 Limit | 不做独立补丁 | Q3 的 5000、Q4 的 100000 | 两个上限都大于结果集，现在就不是瓶颈 |
| 01 rank 窗口 | 设计稿里没有单独编号。它服务 Q1/Q3 的 `ExpandAll.filter` | Q1、Q3 | 01 没认出 `kEdgeRank`。11 在 `GetDstBySrc` 上认出了 |
| 02 Project 下推 Join | 为了让 09 看见 `Limit Dedup HashInnerJoin` | Q3–Q6 | 计划少一层 Project。SHA 不变。时延在负载噪声内 |
| 08 过滤列裁剪 | 无对应根因 | 过滤列已经在 `YIELD` 里 | 六条不变 |
| 10 = 02+03+09 | 错误组合 | Q3 | 2719 行。不能和基线比时延 |
| 11 = 01 的种类修正 + 10 | Q3 的正确组合 | Q3 结果；Q1 的 seek | Q3 1801 行，慢 28%。Q1 的 seek 在噪声内 |

01、02、03、04、05、08 可以单独 `git apply` 到 `fa92893`。06 叠 05，07 叠 05+06，09 叠 03，11 叠 01 和 09。依赖和 p50 全表在 [48](48-reco-operator-patches.md)。

---

## 下一张补丁只写 C

C 的形状：

- 匹配 Q4 第一跳、Q5 第三跳、Q6 第二跳：多起点 `GO`，`YIELD` 只有 `edge._dst`，后面是 `GROUP BY` 该列 + `COUNT(*)` 或 `COUNT(1)`。
- storaged 按 dst 回部分计数。graphd 相加。`ORDER BY count DESC | LIMIT` 留在 graphd。
- 有过滤的第二跳（Q6 的 `buy._dst != 商品`）先滤再数。
- 不在 storaged 做 TopN。
- 不把 Q4 第一跳改成 `DISTINCT`。
- 响应带确认位。旧 storaged 不认时，graphd 退回现在的全量聚合。

这张补丁不在 `patches/reco-q/` 里。45 篇是另一条共同购买 RPC，不要和 Q4 的 `buy` 聚合混用。

D 和 E 的设计可以留着，触发条件写成：同一用户的 expose/buy 达到超级点，或者 TopN 的候选集远大于 K 并且多一次 RTT 仍然便宜。这份 1 万用户的夹具不满足。

B 不写。A 不再扩展 `isSimpleCase` 去覆盖「带 rank 过滤」的 Q3；那条路就是 11，已经测出变慢。Q3 若还要动，只修 `GetNeighbors` 对 `kEdgeRank` 的 seek，不把计划改成单线程 `GetDstBySrc`。
