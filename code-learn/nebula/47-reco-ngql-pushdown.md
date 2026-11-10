# 47 — reco Q1–Q6：使能已有下推的 nGQL

> 六条 opt 各自替换 [dev.md](dev.md) 里同名基线。语句之间没有依赖，改一条不会改另外五条的计划。
> 二进制没有换。跑的是本机 `v3.8.0` `fa92893`，优化器打开后已有的 Filter 下推、列裁剪和 `YIELD DISTINCT edge._dst` 简单计划。
> 原始记录：[bench/reco/pushdown/results.json](bench/reco/pushdown/results.json)。百分位从这份 JSON 的 5 次样本再取，不另造。
> 测量日期：2026-11-10。
> 可单独执行的语句：[bench/reco/pushdown/](bench/reco/pushdown/)。

单机 loopback 还原不了跨机 P99：

- RPC 走 `127.0.0.1`，没有多机 RTT。
- 一个 storaged 进程独占本机 RocksDB block cache。分区数 3 也只是本进程里的 3 个 part。
- 下面的微秒只说明这台机器上两条计划的相对差。

---

## 1. 六条改写各自打开什么

| 场景 | 改写 | EXPLAIN 上多出来的下推 |
|------|------|------------------------|
| Q1 最近购买 | 时间窗写进 `GO WHERE buy._rank`，投影改成 `buy._dst` / `buy._rank` | `ExpandAll.filter=(buy._rank>=1761435000)`，边列只剩 `_rank`、`_dst`。`ORDER BY ts DESC \| LIMIT 10` 仍是 graphd `TopN` |
| Q2 曝光减购买 | `dst(edge)` 改成 `expose._dst` / `buy._dst` | 两侧从 `ExpandAll` 收成 `Expand`（`_dst` only）。`MINUS` 仍在 graphd |
| Q3 美妆高潜用户 | 反向边用 `buy._dst`，90 天窗写进 `GO WHERE buy._rank` | `ExpandAll.filter=(buy._rank>=1753660800)`，边类型 `-15`，边列 `_rank`、`_dst`。`Dedup` 和 `Limit 5000` 仍在 graphd |
| Q4 种子扩展 | 第一跳只投影 `buy._dst`；`ORDER BY $-.pid` 再 `GROUP BY`；第二跳 `YIELD DISTINCT buy._dst` | 第一跳边列从「全部 buy 属性」收成 `buy._dst`。第二跳从 `ExpandAll` 收成 `Expand`（类型 `-15`，只 `_dst`）。`Aggregate` / `TopN 100` / `Limit 100000` 仍在 graphd |
| Q5 UserCF | 前两跳 `YIELD DISTINCT buy._dst`；第三跳只投影 `buy._dst`，保留重复边再 `COUNT` | 前两跳收成 `Expand`。第三跳 `ExpandAll` 的边列只剩 `buy._dst`。`Aggregate` 和 `TopN 20` 仍在 graphd |
| Q6 ItemCF | 第一跳 `YIELD DISTINCT buy._dst`；种子排除写进第二跳 `WHERE buy._dst != ...` | 第一跳收成 `Expand`（类型 `-15`）。第二跳 `ExpandAll.filter=(buy._dst!=10000031733)`，边列只剩 `buy._dst`。graphd `Filter` 节点消失 |

`ExpandAll` 是 `GetNeighbors` 那条路径，过滤和列裁剪写在这个节点上。计划里它下面通常还挂着一个只标边类型的 `Expand`，那是 GO 的骨架，存储入口仍是上面的 `ExpandAll`。没有 `ExpandAll`、只剩 `Expand` 且 `edgeProps` 只有 `_dst` 时，走的是简单计划 `getDstBySrc`。

这六条都没有把全局 `LIMIT` 写进 `GO` 的逐步 `LIMIT [n]`。`ExpandAll.limit` 在 JSON 里仍是 `9223372036854775807`。Q4 / Q5 / Q6 在 `GROUP BY` 前的 `ORDER BY` 不是排序语义，是这个二进制上聚合要读到 VID 键的前提：少了它，`GROUP BY $.pid` 只分出一组（实测整条 Q4 返回 0 行，单独跑第一跳聚合返回 1 行）。计划里它对应一个 graphd `Sort`，不减少 storage 回传。

---

## 2. 环境和二进制

| 项 | 值 |
|----|----|
| 二进制 | `~/code/nebula-graph/build/bin/nebula-graphd`，`Git: fa92893`，构建时间 Nov 6 2026 10:00:39，tag `v3.8.0` |
| 源码 | 上游 vesoft `fa928930ab34f150db522933323aa610e54f26e7`。本次没有套 `operator-opt`，也没有新的 C++ patch |
| 进程 | 各一个 metad / storaged / graphd，`127.0.0.1`，端口 9559 / 9779 / 9669。运行目录 `/tmp/nb` |
| graphd | `/tmp/nb/conf/graphd.conf` 里 `--enable_optimizer=true`，`--num_worker_threads=0` |
| storaged | `--num_worker_threads=32`，`--rocksdb_block_cache=4` |
| 机器 | Linux，aarch64，14 vCPU，`MemTotal` 45194344 kB |
| 客户端 | `nebula3-python` 3.8.x，Python 3.14。`EXPLAIN` 读 `ResultSet.plan_desc()`。时延读 `latency()`，单位微秒 |
| 空间 | `reco`，`vid_type=INT64`，`partition_num=3`，`replica_factor=1` |

---

## 3. 数据

生成参数在 [bench/reco/out/vertices_manifest.json](bench/reco/out/vertices_manifest.json)、[buy_manifest.json](bench/reco/out/buy_manifest.json)、[expose_manifest.json](bench/reco/out/expose_manifest.json)。本次测量没有重新灌数。

| 项 | 值 |
|----|----|
| 点 | user `1..10000`，product `10000000001..10000050000`，category 4000。active user 2946，美妆 `product.type==1` 2245 |
| 边 | `buy` 80082，rank 等于购买时间。`expose` 151866，rank 等于曝光时间 |
| 常量 | `now_sec=1761436800`，30 分钟窗 1800，截止 `1761435000`。90 天窗 7776000，截止 `1753660800` |
| 种子 | Q1 / Q2 / Q5 用户 `2`。Q3 美妆类型 `1`。Q4 `UNWIND range(1, 10000)`。Q6 商品 `10000031733` |

---

## 4. 怎么量

脚本 [bench/reco/measure_pushdown.py](bench/reco/measure_pushdown.py)。每条语句先 `EXPLAIN`，再执行 6 次，丢掉第 1 次，留下 5 次。`server_us` 是 `resp.latency()`。`wall_us` 是客户端包住 `execute()` 的 `perf_counter`。p50 是这 5 个数排序后的中位数。

结果是否相同，比的是最后一次结果行的排序多重集 SHA-256，不要求行序相同。`Q2` 和 `Q3` 没有 `ORDER BY`，样本前 5 行可以不同，哈希仍然相同。

六条在同一次会话里按 q1 到 q6 顺序测，每条有自己的 warmup。`--only q1` 可以单测一条；`--out` 会整文件覆盖，不要指到已有的 `results.json`。

---

## 5. 时延

单位微秒。比值是 base p50 / opt p50，用 server latency。

| 查询 | 行数 base / opt | 多重集 | server p50 base | server p50 opt | 比值 | wall p50 base | wall p50 opt |
|------|-----------------|--------|-----------------|----------------|------|---------------|--------------|
| Q1 | 10 / 10 | 相同 | 493 | 315 | 1.57 | 649 | 461 |
| Q2 | 8 / 8 | 相同 | 349 | 262 | 1.33 | 463 | 361 |
| Q3 | 1801 / 1801 | 相同 | 13180 | 9102 | 1.45 | 17995 | 13787 |
| Q4 | 670 / 670 | 相同 | 139191 | 74859 | 1.86 | 141099 | 76841 |
| Q5 | 20 / 20 | 相同 | 2402 | 1565 | 1.53 | 2611 | 1729 |
| Q6 | 20 / 20 | 相同 | 1316 | 893 | 1.47 | 1473 | 1052 |

5 次 server latency 样本：

| 查询 | base | opt |
|------|------|-----|
| Q1 | 623, 493, 479, 643, 454 | 369, 315, 293, 316, 309 |
| Q2 | 349, 332, 352, 639, 343 | 331, 247, 229, 262, 341 |
| Q3 | 12755, 14585, 13610, 12341, 13180 | 9151, 9267, 8882, 8942, 9102 |
| Q4 | 146296, 151904, 137454, 135568, 139191 | 74859, 74960, 73014, 74069, 76856 |
| Q5 | 2362, 2506, 2402, 2640, 2371 | 1565, 1711, 1565, 1720, 1528 |
| Q6 | 1311, 1322, 1316, 1401, 1270 | 893, 807, 896, 819, 948 |

Q1、Q3、Q4、Q5、Q6 的 opt 最大值都低于 base 最小值。Q2 两侧区间重叠（opt 最大 341，base 最小 332），中位数仍从 349 降到 262。Q2 这条在当前数据量上的差距很小。

六条的多重集现在全部相同。Q4 的基线和 opt 只差 `dst(edge)`→`buy._dst` 这一处改写，行数和 SHA-256 都一致（670 行，`51e9d529…`），见第 9 节。它的时延差来自第一跳的边列裁剪：基线把全部 buy 属性拉回 graphd，opt 只取 `buy._dst`。

---

## 6. Q1 最近购买

基线把时间窗放在管道 `YIELD ... WHERE` 上，并用恒假的 `OR $-.pid != $-.pid` 把谓词留在 graphd。opt 把窗和投影都写进 `GO`。

基线：

```ngql
GO FROM 2 OVER buy YIELD dst(edge) AS pid, rank(edge) AS ts | YIELD $-.pid AS pid, $-.ts AS ts WHERE $-.ts >= 1761436800 - 1800 OR $-.pid != $-.pid | ORDER BY $-.ts DESC | LIMIT 10
```

opt，文件 [q1-opt.ngql](bench/reco/pushdown/q1-opt.ngql)：

```ngql
GO FROM 2 OVER buy WHERE buy._rank >= 1761436800 - 1800 YIELD buy._dst AS pid, buy._rank AS ts | ORDER BY $-.ts DESC | LIMIT 10
```

下推前（optimize 304 µs）：

```text
TopN count=10 factors=ts DESC
  Project $-.pid AS pid, $-.ts AS ts
    Filter
      Project dst(EDGE) AS pid, $__COL_0 AS ts
        ExpandAll filter=<empty> joinInput=false limit=max
          edgeProps type 15: _dst _rank _src _type ad_slot_id order_id quantity timestamp
          edgeColumns: EDGE AS EDGE, *._rank AS __COL_0
          Expand props=_dst
            Start
```

下推后（optimize 90 µs）：

```text
TopN count=10 factors=ts DESC
  Project $__COL_1 AS pid, $__COL_0 AS ts
    ExpandAll filter=(buy._rank>=1761435000) joinInput=false limit=max
      edgeProps type 15: _dst _rank
      edgeColumns: buy._rank AS __COL_0, buy._dst AS __COL_1
      Expand props=_dst
        Start
```

graphd 上的 `Filter` 没有了。rank 比较在 `ExpandAll.filter` 里，字面量 `1761435000` 等于 `1761436800 - 1800`。回传列从整条边收成 `_rank` 和 `_dst`。`TopN` 仍在 graphd，`ExpandAll` 没有 order。

结果多重集 SHA-256 都是 `58819b84f72b41a1e04a9d1ff3659287fd121d7e5f9f8e94f158055eb419bc20`。前五行与 [buy_manifest.json](bench/reco/out/buy_manifest.json) 的 `q1_user_2` 一致，首行 `(10000019766, 1761436409)`。

server p50 580 → 282 µs。wall p50 704 → 407 µs。

---

## 7. Q2 曝光减购买

基线：

```ngql
GO FROM 2 OVER expose YIELD DISTINCT dst(edge) AS pid MINUS GO FROM 2 OVER buy YIELD DISTINCT dst(edge) AS pid
```

opt，文件 [q2-opt.ngql](bench/reco/pushdown/q2-opt.ngql)：

```ngql
GO FROM 2 OVER expose YIELD DISTINCT expose._dst AS pid MINUS GO FROM 2 OVER buy YIELD DISTINCT buy._dst AS pid
```

下推前（optimize 86 µs）。两侧对称，左边 expose 类型 16，右边 buy 类型 15：

```text
Minus
  Dedup
    Project dst(EDGE) AS pid
      ExpandAll filter=<empty> edgeColumns=EDGE AS EDGE
        edgeProps: 该边的全部属性
        Expand props=_dst
          Start
  Dedup
    Project dst(EDGE) AS pid
      ExpandAll ... 同上，另一条边
```

下推后（optimize 72 µs）：

```text
Minus
  Project COLUMN[0]
    Dedup
      Expand joinInput=false edgeProps type 16: _dst
        PassThrough
          Start
  Project COLUMN[0]
    Dedup
      Expand joinInput=false edgeProps type 15: _dst
```

两侧都不再解码边 value。`getDstBySrc` 在 storaged 里去重之后，graphd 仍保留 `Dedup`。`MINUS` 仍是 graphd 上的两次结果相减，没有合成一次 storage 调用。

结果 8 行，SHA-256 都是 `7d6a1faae17baef402be4b030792a49c63f56f29a0e156db885ba67f91ea45a6`，与 manifest 里 user 2 的 8 个曝光差集一致。server p50 324 → 270 µs，样本区间重叠。

---

## 8. Q3 美妆高潜用户

基线用 `src(edge)` 加管道上的时间窗，并用恒假 `OR` 把过滤留在 graphd。opt 在 `REVERSELY` 上投影 `buy._dst`（买家），时间窗写进 `GO WHERE`。

基线：

```ngql
LOOKUP ON product WHERE product.type == 1 YIELD id(vertex) AS pid | GO FROM $-.pid OVER buy REVERSELY YIELD src(edge) AS uid, rank(edge) AS ts | YIELD $-.uid AS uid, $-.ts AS ts WHERE $-.ts >= 1761436800 - 7776000 OR $-.uid != $-.uid | YIELD DISTINCT $-.uid AS high_potential_user | LIMIT 5000
```

opt，文件 [q3-opt.ngql](bench/reco/pushdown/q3-opt.ngql)：

```ngql
LOOKUP ON product WHERE product.type == 1 YIELD id(vertex) AS pid | GO FROM $-.pid OVER buy REVERSELY WHERE buy._rank >= 1761436800 - 7776000 YIELD buy._dst AS uid | YIELD DISTINCT $-.uid AS high_potential_user | LIMIT 5000
```

下推前（optimize 657 µs）：

```text
Limit count=5000
  Dedup
    Project $-.uid AS high_potential_user
      Filter
        Project src(EDGE) AS uid, $__COL_0 AS ts
          HashInnerJoin
            Project id(VERTEX) AS pid
              TagIndexPrefixScan
                Start
            ExpandAll filter=<empty> joinInput=true type -15
              edgeProps: 全部 buy 属性
              edgeColumns: EDGE AS EDGE, *._rank AS __COL_0
              Expand props=_dst type -15
                Argument
```

下推后（optimize 266 µs）：

```text
Limit count=5000
  Dedup
    Project $__COL_1 AS high_potential_user
      HashInnerJoin
        Project id(VERTEX) AS pid
          TagIndexPrefixScan
            Start
        ExpandAll filter=(buy._rank>=1753660800) joinInput=true type -15
          edgeProps: _dst _rank
          edgeColumns: buy._rank AS __COL_0, buy._dst AS __COL_1
          Expand props=_dst type -15
            Argument
```

索引扫描还在。graphd `Filter` 没有了，90 天比较进了反向 `ExpandAll`。因为 `WHERE` 还在，这条 `GO` 不是简单计划，存储入口仍是 `GetNeighbors`。`LIMIT 5000` 在 `Dedup` 之上，没有进 `ExpandAll`。返回 1801 行，小于 5000，这个 limit 没有截断结果。

SHA-256 都是 `45e59fd185d339542050700fd013ad009249ef0e6de5d0b4110b6ee8995c4dc2`。server p50 13199 → 9440 µs。wall p50 18074 → 14323 µs。

---

## 9. Q4 种子共买再扩用户

基线和 opt 只差两处：`dst(edge)` → `buy._dst`、`src(edge)` → `buy._dst`。两侧第一跳都在 `GROUP BY` 前带 `| ORDER BY $-.pid`——这不是排序语义，而是这个二进制上聚合要读到 VID 键的前提（见第 12 节）。

基线：

```ngql
UNWIND range(1, 10000) AS uid | GO FROM $-.uid OVER buy YIELD dst(edge) AS pid | ORDER BY $-.pid | GROUP BY $-.pid YIELD $-.pid AS pid, COUNT(*) AS co_buy | ORDER BY $-.co_buy DESC | LIMIT 100 | GO FROM $-.pid OVER buy REVERSELY YIELD DISTINCT src(edge) AS ext_user | LIMIT 100000
```

opt，文件 [q4-opt.ngql](bench/reco/pushdown/q4-opt.ngql)：

```ngql
UNWIND range(1, 10000) AS uid | GO FROM $-.uid OVER buy YIELD buy._dst AS pid | ORDER BY $-.pid | GROUP BY $-.pid YIELD $-.pid AS pid, COUNT(*) AS co_buy | ORDER BY $-.co_buy DESC | LIMIT 100 | GO FROM $-.pid OVER buy REVERSELY YIELD DISTINCT buy._dst AS ext_user | LIMIT 100000
```

下推前（optimize 249 µs）：

```text
Limit count=100000
  Dedup
    Project src(EDGE) AS ext_user
      HashInnerJoin
        TopN count=100 factors=co_buy DESC
          Aggregate groupKeys=$-.pid
            Sort factors=pid ASC
              Project dst(EDGE) AS pid
                HashInnerJoin
                  Unwind
                    Start
                  ExpandAll joinInput=true type 15 filter=<empty>
                    edgeProps: 全部 buy 属性
                    edgeColumns: EDGE AS EDGE
                    Expand props=_dst
                      Argument
        ExpandAll joinInput=true type -15 filter=<empty>
          edgeProps: 全部 buy 属性
          edgeColumns: EDGE AS EDGE
          Expand props=_dst type -15
            Argument
```

下推后（optimize 229 µs）：

```text
Project COLUMN[0]
  Limit count=100000
    Dedup
      Expand joinInput=false type -15 edgeProps=_dst
        TopN count=100 factors=co_buy DESC
          Aggregate groupKeys=$-.pid
            Sort factors=pid ASC
              Project $__COL_0 AS pid
                HashInnerJoin
                  Unwind
                    Start
                  ExpandAll joinInput=true type 15 filter=<empty>
                    edgeProps: _dst
                    edgeColumns: buy._dst AS __COL_0
                    Expand props=_dst
                      Argument
```

两侧第一跳都不再拉顶点，`GetVertices` 从计划里消失。差别在边列：基线把全部 buy 属性拉回 graphd，opt 的 `ExpandAll` 只回 `buy._dst`。`Sort` 是 `ORDER BY $-.pid`，在聚合之前。第二跳没有 `ExpandAll`，`Expand` 只带 `_dst`，边类型 `-15`，`joinInput=false`，上面才是 graphd `Dedup` 和 `Limit 100000`。第一跳没有 rank 谓词，所以这条 `ExpandAll` 的 filter 仍是空的。`TopN 100` 仍在 graphd，输入仍是全部共买计数。

全语句结果：两侧都是 670 行，SHA-256 都是 `51e9d5295d9e5e77ee005c37a60d9f3e73c9ec972fcbe833399325367e1442b5`。

这里要修正本篇早先一版记录里的一个测量缺陷：基线原本多投影了 `$$.product.type`，于是第一跳走 `GetVertices` 把 vid 物化；opt 则用 `| ORDER BY $-.pid` 物化。两条不是同一个查询，`ORDER BY co_buy DESC | LIMIT 100` 在相等键上切哪几个取决于进入 `TopN` 的顺序，于是集合差 1 行，`co_buy=6` 的并列切分被误记成了下推的副作用。把基线也换成 `| ORDER BY $-.pid`、去掉 `$$.product.type` 后，两侧只差 `dst(edge)`/`src(edge)` 到 `_dst` 的改写，逐行一致。

server p50 139191 → 74859 µs。wall p50 141099 → 76841 µs。

---

## 10. Q5 UserCF

前两跳只要 VID 集合。第三跳要按商品计边数，所以保持多行，只把投影收成 `buy._dst`。

基线：

```ngql
GO FROM 2 OVER buy YIELD DISTINCT dst(edge) AS x | GO FROM $-.x OVER buy REVERSELY YIELD DISTINCT src(edge) AS u2 | GO FROM $-.u2 OVER buy YIELD dst(edge) AS y | ORDER BY $-.y | GROUP BY $-.y YIELD $-.y AS rec_item, COUNT(1) AS score | ORDER BY $-.score DESC | LIMIT 20
```

opt，文件 [q5-opt.ngql](bench/reco/pushdown/q5-opt.ngql)：

```ngql
GO FROM 2 OVER buy YIELD DISTINCT buy._dst AS x | GO FROM $-.x OVER buy REVERSELY YIELD DISTINCT buy._dst AS u2 | GO FROM $-.u2 OVER buy YIELD buy._dst AS y | ORDER BY $-.y | GROUP BY $-.y YIELD $-.y AS rec_item, COUNT(1) AS score | ORDER BY $-.score DESC | LIMIT 20
```

下推前（optimize 235 µs）：

```text
TopN count=20 factors=score DESC
  Aggregate groupKeys=$-.y
    Sort factors=y ASC
      Project dst(EDGE) AS y
        HashInnerJoin
          Dedup
            Project src(EDGE) AS u2
              HashInnerJoin
                Dedup
                  Project dst(EDGE) AS x
                    ExpandAll type 15 edgeColumns=EDGE AS EDGE
                      edgeProps: 全部 buy 属性
                      Expand props=_dst
                        Start
                ExpandAll type -15 edgeColumns=EDGE AS EDGE
                  edgeProps: 全部 buy 属性
          ExpandAll type 15 edgeColumns=EDGE AS EDGE
            edgeProps: 全部 buy 属性
```

下推后（optimize 177 µs）：

```text
TopN count=20 factors=score DESC
  Aggregate groupKeys=$-.y
    Sort factors=y ASC
      Project $__COL_2 AS y
        HashInnerJoin
          Project COLUMN[0]
            Dedup
              Expand type -15 joinInput=false edgeProps=_dst
                Project COLUMN[0]
                  Dedup
                    Expand type 15 joinInput=false edgeProps=_dst
                      Start
          ExpandAll type 15 joinInput=true filter=<empty>
            edgeProps: _dst
            edgeColumns: buy._dst AS __COL_2
            Expand props=_dst
              Argument
```

第一跳、第二跳收成 `Expand`。第三跳仍是 `ExpandAll`，因为 `COUNT(1)` 需要每条边一行；边列从整条边收成 `buy._dst`。两边都有 `Sort`，它来自 `ORDER BY $-.y`，聚合留在 graphd。`TopN 20` 留在 graphd。

20 行相同，SHA-256 `5c0ebd20c7c71f420899f1af3ba0fb3f85a40ebcb7dcfdecadb728b4d346a5c3`。样本前三行 `(10000027663, 8)`、`(10000017204, 6)`、`(10000041658, 5)`。server p50 2414 → 1722 µs。

---

## 11. Q6 ItemCF

基线在管道上排除种子商品。opt 把 `buy._dst != 10000031733` 写进第二跳 `GO WHERE`，第一跳改成 `buy._dst`。

基线：

```ngql
GO FROM 10000031733 OVER buy REVERSELY YIELD DISTINCT src(edge) AS uid | GO FROM $-.uid OVER buy YIELD dst(edge) AS item | YIELD $-.item AS item WHERE $-.item != 10000031733 | ORDER BY $-.item | GROUP BY $-.item YIELD $-.item AS rec_item, COUNT(1) AS score | ORDER BY $-.score DESC | LIMIT 20
```

opt，文件 [q6-opt.ngql](bench/reco/pushdown/q6-opt.ngql)：

```ngql
GO FROM 10000031733 OVER buy REVERSELY YIELD DISTINCT buy._dst AS uid | GO FROM $-.uid OVER buy WHERE buy._dst != 10000031733 YIELD buy._dst AS item | ORDER BY $-.item | GROUP BY $-.item YIELD $-.item AS rec_item, COUNT(1) AS score | ORDER BY $-.score DESC | LIMIT 20
```

下推前（optimize 511 µs）：

```text
TopN count=20 factors=score DESC
  Aggregate groupKeys=$-.item
    Sort factors=item ASC
      Project $-.item AS item
        Filter
          Project dst(EDGE) AS item
            HashInnerJoin
              Dedup
                Project src(EDGE) AS uid
                  ExpandAll type -15 edgeColumns=EDGE AS EDGE
                    edgeProps: 全部 buy 属性
                    Expand props=_dst
                      Start
              ExpandAll type 15 filter=<empty> edgeColumns=EDGE AS EDGE
                edgeProps: 全部 buy 属性
```

下推后（optimize 219 µs）：

```text
TopN count=20 factors=score DESC
  Aggregate groupKeys=$-.item
    Sort factors=item ASC
      Project $__COL_1 AS item
        HashInnerJoin
          Project COLUMN[0]
            Dedup
              Expand type -15 joinInput=false edgeProps=_dst
                Start
          ExpandAll filter=(buy._dst!=10000031733) joinInput=true type 15
            edgeProps: _dst
            edgeColumns: buy._dst AS __COL_1
            Expand props=_dst
              Argument
```

第一跳收成 `Expand`。第二跳的不等谓词在 `ExpandAll.filter` 里，graphd `Filter` 节点没有了，边列只剩 `buy._dst`。`Sort`、`Aggregate`、`TopN` 仍在 graphd。谓词是目的 VID 不等，不是 rank 范围。

20 行相同，SHA-256 `d4500be032c76abe085765c447d86dfd0a6d3f39858d58bdac7f66f8567dc6e3`。样本分数都是 1，首行 `10000042680`。server p50 1338 → 886 µs。

---

## 12. 这次没有推进的边界

这六条用的是 `fa92893` 上已经注册的规则。下面这些在本次计划和时延里都还没有发生：

- `ORDER BY ... LIMIT` 仍是 graphd `TopN`。`ExpandAll` 不带 order，limit 仍是 int64 最大值。
- `GROUP BY` / `COUNT` 仍整段在 graphd。Q4 第一跳、Q5 第三跳、Q6 第二跳把计过数的行全部拉回 graphd 再聚合。
- `GROUP BY` 的分组键要靠 `ORDER BY` 物化。`GO ... YIELD dst(edge) AS pid | GROUP BY $.pid ...` 在这个二进制上只分出一组；先加 `| ORDER BY $-.pid`（或让投影多带一列触发 `GetVertices`）才得到正确的分组数。这是 Q4 / Q5 / Q6 都要带 `ORDER BY` 的原因，也是基线与 opt 必须同形的原因。
- `MINUS` 仍在 graphd。Q2 仍是 expose、buy 各一次 `getDstBySrc`。
- Q4 第二跳的 `Dedup + Limit` 没有提前停。这条 `GO` 没有 rank 谓词，`Expand` 上面也还有 `Project`。
- rank 谓词写进了 `ExpandAll.filter`。本次 EXPLAIN 看不到它变成从 rank 上界往回走的迭代器。

单独重跑一条：

```sh
python3 code-learn/nebula/bench/reco/measure_pushdown.py --only q1 --rounds 5 --out /tmp/q1-pushdown.json
```

单独执行 opt：

```sh
~/bin/nebula-console -addr 127.0.0.1 -port 9669 -u root -p nebula \
  -f code-learn/nebula/bench/reco/pushdown/q1-opt.ngql
```

`q2-opt.ngql` 到 `q6-opt.ngql` 同样，每份文件只有 `USE reco` 和那一条语句。
