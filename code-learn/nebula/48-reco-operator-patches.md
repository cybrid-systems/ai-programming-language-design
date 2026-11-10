# 48 — reco Q1–Q6：正交补丁对照优化后的 nGQL

> 比较对象是 [47](47-reco-ngql-pushdown.md) 里六条已经下推过的 opt 语句，跑在同一份 `reco` 数据上。
> 基线二进制是 gcc-11 重编的上游 `fa92893`，标签 `00-baseline`。文档 47 的微秒来自 11 月 6 日的另一份二进制，不和本表混用。两边的结果多重集 SHA 相同。
> 每个补丁单独换二进制再测。06 叠在 05 上，07 叠在 05+06 上，09 叠在 03 上，10 是 02+03+09，11 是 01+02+03+09 再加 rank 窗口。除此之外不叠。
> 原始记录：[bench/reco/patch-measure/](bench/reco/patch-measure/)。表里的 p50 从这些 JSON 的 7 次样本再取。
> 测量日期：2026-11-10。

单机 loopback 还原不了跨机 P99。RPC 走 `127.0.0.1`，一个 storaged 独占本机 RocksDB，分区数 3 只是本进程里的 3 个 part。下面的微秒只说明这台机器上、这份夹具上，补丁相对 `00-baseline` 的差。

---

## 1. 补丁各自动哪一个算子

补丁在 `patches/reco-q/`。源是 `/home/dev/code/nebula` 的 `operator-opt`（`116b6a4`）相对 `fa92893` 的提交，按算子切开，再改到能在 `fa92893` 上单独 apply。测试文件没进补丁（`ENABLE_TESTS=OFF`）。

| 补丁 | 依赖 | 动的算子 | 这六条 opt 上的结果 |
|------|------|----------|---------------------|
| `01-rank-bounded.patch` | `fa92893` | `GetNeighbors` 的 `SingleEdgeNode`：`rangeWithPrefix` + `RankBoundedKVIterator` | 计划不变，SHA 相同。提取器只认 `kEdgeProperty`。nGQL 的 `buy._rank` 是 `kEdgeRank`，这次 seek 没有发生 |
| `02-project-down-join.patch` | `fa92893` | `PushProjectDownHashInnerJoinRule`，去掉 Join 上方那层 Project | Q3/Q4/Q5/Q6 的计划少一层 Project。SHA 相同 |
| `03-distinct-limit-single-src.patch` | `fa92893` | 单源 `PushDistinctLimitDownExpandRule` | 计划不变，SHA 相同。Q4 第二跳本来就是简单 `Expand`，`LIMIT 100000` 也不截断 |
| `04-agg-key-reuse.patch` | `fa92893` | 聚合键复用，少一次 List 键拷贝 | 计划不变，SHA 相同。聚合在 graphd |
| `05-agg-single-key.patch` | `fa92893` | 单列 `GROUP BY` 走 FastGroup | 计划不变。Q4/Q5/Q6 的 SHA 变了，分数直方图没变，Q4 仍是 670 行 |
| `06-agg-int-count.patch` | 先 05 | `COUNT` 用 `int64` 平坦表。行数 ≥ 2^20 且顺序迭代才分片 | 计划不变。Q4 变成 671 行，是 `co_buy=6` 的并列切分。并行分支没进 |
| `07-topn-into-count.patch` | 先 05+06 | 把 TopN 的堆塞进 COUNT 的发射 | 计划仍是 `TopN Aggregate`。SHA 与 06 相同。Q5/Q6 更慢 |
| `08-filter-prop-prune.patch` | `fa92893` | 过滤列是输出列的子集时不再多读 | 计划不变，SHA 相同。这六条的过滤列本来就在输出里 |
| `09-shared-dedup-limit.patch` | 先 03 | 多源 `DISTINCT`+`LIMIT` 收成一次 `GetDstBySrc`，请求级 visited | Q3 计划不变。Join 和 `ExpandAll` 之间还有 Project，规则不匹配 |
| `11-getdst-rank-range.patch` | 先 01，并且 `GetDstBySrcProcessor` 已是 09 的版本 | `buy._rank` 识别成 `kEdgeRank`，边界取精确值；`GetDstBySrc` 把这个窗口交给 `SingleEdgeNode` | 见第 7 节。单独的 02+03+09（标签 10）会丢掉这个窗口 |

10 不是一份补丁文件。它是 02+03+09 编出来的二进制，用来说明 09 的 Join 规则在没有 rank 窗口时会改结果。

`edge._rank` 在 `parser.yy` 里走 `RANK_PROP`，生成 `EdgeRankExpression`（`Kind::kEdgeRank`）。01 原来的 `extractRankBounds` 只接受 `kEdgeProperty`，所以 `GetNeighbors` 退回整段前缀扫描，计划和结果都跟基线一样。11 把同一次比较改成同时接受 `kEdgeRank` 和 `kEdgeProperty`。`GT`/`LT` 用开区间端点（`v+1` / `v-1`）。`GetDstBySrc` 不计算 `EdgeNode::exp_`，超集边界会把端点上的边算进来。这六条用的是 `>=`，端点本身就在窗口里。

提不出窗口时，11 让 `GetDstBySrc` 返回 `E_INVALID_FILTER`，不再静默扫完全部 rank。

---

## 2. 怎么叠

在 `fa92893` 上 `git apply --check` 通过、并且单独编过的：01、02、03、04、05、08。

06 的上下文在 05 的 `AggregateExecutor.cpp` 和旗标锚点上。07 的上下文在 05+06 上。09 的上下文在 03 上。09 自己带了 `JoinOutputColumn` / `hasOutputColumns`，所以不先打 02 也能编译；`hasOutputColumns()` 此时为假，Join 规则直接 `noTransform`。

先 02 再 03 再 09 时，02 的 `Query.h` 会和 09 已经加上的 `JoinOutputColumn` 冲突。`git apply --reject` 只留下 `Query.h.rej`，其余文件能上去。rej 就是这份重复的 API，删掉即可。02 的 `Query.cpp`（`outputColumns_` 的 explain / clone）和 `PushProjectDownHashInnerJoinRule` 仍要留下，否则 Join 规则看不到输出列，Q3 不会改写。

11 打在「01 已改过的 `GetNeighborsProcessor.cpp`」和「09 已改过的 `GetDstBySrcProcessor.*`」上。这次对这三份文件做过 `git apply --check`。它不能打在裸的 `fa92893` 上。

03、09 改了 `storage.thrift` 的 `GetDstBySrc` 字段。graphd 和 storaged 要同一套。01 和 11 只动存储执行，thrift 没变，但 seek 在 storaged 里，这两份也要换 storaged。metad 的 thrift 没变，十一份二进制的 metad 都与 `00-baseline` 逐字节相同。

和基线 storaged 逐字节相同的标签：02、05、06、07、08。01 的 graphd 与基线逐字节相同。10 的 storaged 与 09 逐字节相同。11 的 graphd 与 10 逐字节相同，storaged 是 16:50 新链出来的。

---

## 3. 环境和二进制

| 项 | 值 |
|----|----|
| 源码 | `/home/dev/code/nebula`，测量时 HEAD 脱离在 `fa92893`，再打上面对应的补丁。分支 `operator-opt` 停在 `116b6a4`，没有把这些补丁提交回 nebula |
| 编译器 | `/home/dev/gcc11/usr/bin/g++-11`，`NEBULA_THIRDPARTY_ROOT=/home/dev/nebula-third-party`（GCC 11.2，glibc 2.34，aarch64） |
| 选项 | Release，`ENABLE_WERROR=ON`，`ENABLE_TESTS=OFF`，`ENABLE_JEMALLOC=ON`，`ENABLE_MEMORY_TRACKER=ON` |
| 进程 | 各一个 metad / storaged / graphd，`127.0.0.1`，端口 9559 / 9779 / 9669。运行目录 `/tmp/nb`。换二进制用 `bench/reco/swap_bins.sh` |
| graphd | `--enable_optimizer=true`，`--num_worker_threads=0` |
| storaged | `--num_worker_threads=32`，`--rocksdb_block_cache=4` |
| 机器 | Linux，aarch64，14 vCPU，`MemTotal` 45194344 kB |
| 空间 | `reco`，`vid_type=INT64`，`partition_num=3`，`replica_factor=1`。没有动 `copurchase` |

数据与 [47 第 3 节](47-reco-ngql-pushdown.md) 相同：user `1..10000`，product 5 万，buy 80082，expose 151866，美妆商品 2245，active user 2946。`now_sec=1761436800`。每用户 buy 度大约 20。没有 click、contains，也没有按负 rank 重灌。

---

## 4. 怎么量

脚本 [bench/reco/measure_patches.py](bench/reco/measure_patches.py)。只跑 47 的六条 opt。每条先 `EXPLAIN`，再执行 8 次，丢掉第 1 次，留下 7 次。`server_us` 是 `resp.latency()`，`wall_us` 是客户端 `perf_counter`。p50 是这 7 个数的中位数。

结果比的是排序后的行多重集 SHA-256。Q4 另有一条停在 `| ORDER BY $-.co_buy DESC | LIMIT 100` 的探针，用来看 `co_buy` 直方图和 `co_buy≥7` 的商品集合。Q5/Q6 的最后一列是分数，直接做直方图。

00 到 10 是同一次换二进制循环，中间没有编译。负载从 `3.52 7.54 8.22` 降到 `0.96 5.16 7.25`。Q1/Q2/Q5/Q6 的绝对差大多落在这个负载坡度里。Q4 一条就要大约 90 ms，同样受负载影响。样本区间互不重叠、而且计划或存储路径确实变了的，才在下面单独写。

11 是这次循环之后补测的，负载 `0.53 1.00 3.62`。编译穿插的上一轮在 `bench/reco/patch-measure/during-build/`，那一轮负载更高，表里不用。

---

## 5. 时延

单位微秒，server p50。行数与 `00-baseline` 相同、SHA 也相同的格子不加标记。`*` 表示 SHA 与基线不同。

| 标签 | 负载 1/5/15 | Q1 | Q2 | Q3 | Q4 | Q5 | Q6 |
|------|-------------|----|----|----|----|----|----|
| 00-baseline | 3.52 / 7.54 / 8.22 | 441 | 372 | 12217 | 94852 | 1834 | 930 |
| 01-rank-bounded | 2.96 / 7.22 / 8.10 | 449 | 413 | 12019 | 98753 | 1940 | 1309 |
| 02-project-down-join | 2.67 / 7.01 / 8.03 | 382 | 371 | 11158 | 90326 | 1784 | 894 |
| 03-distinct-limit | 2.16 / 6.69 / 7.90 | 404 | 338 | 10867 | 91026 | 1687 | 877 |
| 04-agg-key-reuse | 1.82 / 6.46 / 7.82 | 411 | 360 | 11396 | 87245 | 1589 | 841 |
| 05-agg-single-key | 1.57 / 6.18 / 7.70 | 423 | 315 | 12295 | 91632* | 1631* | 936* |
| 06-agg-int-count | 1.41 / 5.99 / 7.63 | 386 | 345 | 11610 | 82452* | 1609* | 926* |
| 07-topn-into-count | 1.23 / 5.73 / 7.51 | 431 | 398 | 12144 | 81261* | 1907* | 1064* |
| 08-filter-prop-prune | 1.04 / 5.54 / 7.43 | 474 | 375 | 11988 | 96940 | 1754 | 866 |
| 09-shared-dedup | 0.88 / 5.36 / 7.35 | 455 | 330 | 12506 | 97517 | 1708 | 925 |
| 10-q3-compose | 0.96 / 5.16 / 7.25 | 482 | 325 | 15910* | 89640 | 1712 | 947 |
| 11-q3-rank | 0.53 / 1.00 / 3.62 | 377 | 339 | 15622 | 87066 | 1813 | 1038 |

基线 SHA 前缀：Q1 `58819b84f72b`，Q2 `7d6a1faae17b`，Q3 `45e59fd185d3`，Q4 `51e9d5295d9e`，Q5 `5c0ebd20c7c7`，Q6 `d4500be032c7`。行数 10 / 8 / 1801 / 670 / 20 / 20。

05 的 Q4/Q5/Q6 SHA 前缀是 `0afcfce9343a` / `bf5db3263c28` / `7c372080f88a`，Q4 仍是 670 行。06 和 07 的前缀是 `27bcc5e755fc` / `4337ac997e51` / `3cf23bf5ba94`，Q4 是 671 行。10 的 Q3 SHA 前缀是 `e393e8dee9a4`，2719 行。11 的 Q3 回到 `45e59fd185d3`，1801 行。

Q4 探针的 `co_buy` 直方图在每个标签上都是 9×2、8×19、7×66、6×13。`co_buy≥7` 的 87 个商品集合也相同。06/07 多出来的那一行出在 `co_buy=6` 的并列商品上，反向扩展后外层行数从 670 变成 671。Q5 的分数直方图都是 `{8:1, 6:1, 5:1, 4:4, 3:5, 2:8}`。Q6 的 20 行分数都是 1。

Q3 的 7 次样本：基线 11713–12666，10 是 15463–16569，11 是 15232–16014。11 和基线的区间不相交，而且 11 的负载更低。这条变慢是测量得到的，不是负载坡度。

wall p50 写在各自的 JSON 里。Q3 的 wall p50：基线 17084，10 是 23045，11 是 20192。

---

## 6. 计划

00、01、03、04、05、06、07、08、09 的算子脊柱与基线相同：

| 查询 | 脊柱 |
|------|------|
| Q1 | `TopN Project ExpandAll Expand Start` |
| Q2 | `Minus Project Dedup Expand PassThrough Start Project Dedup Expand` |
| Q3 | `Limit Dedup Project HashInnerJoin Project TagIndexPrefixScan Start ExpandAll Expand Argument` |
| Q4 | `Project Limit Dedup Expand TopN Aggregate Sort Project HashInnerJoin Unwind Start ExpandAll Expand Argument` |
| Q5 | `TopN Aggregate Sort Project HashInnerJoin Project Dedup Expand Project Dedup Expand Start ExpandAll Expand Argument` |
| Q6 | `TopN Aggregate Sort Project HashInnerJoin Project Dedup Expand Start ExpandAll Expand Argument` |

Q1 的 `ExpandAll.filter` 是 `(buy._rank>=1761435000)`。Q3 的 `ExpandAll.filter` 是 `(buy._rank>=1753660800)`，边类型 `-15`。rank seek 即使发生，也在 storaged 的迭代器里，EXPLAIN 不会多一个节点。01 的脊柱因此和基线相同；再对照第 1 节，这次它的提取器也没配上 `kEdgeRank`。

02 去掉 Join 上方的 Project。SHA 和行数保持基线：

| 查询 | 脊柱 |
|------|------|
| Q3 | `Limit Dedup HashInnerJoin Project TagIndexPrefixScan Start ExpandAll Expand Argument` |
| Q4 | `Project Limit Dedup Expand TopN Aggregate Sort HashInnerJoin Unwind Start ExpandAll Expand Argument` |
| Q5 | `TopN Aggregate Sort HashInnerJoin Project Dedup Expand Project Dedup Expand Start ExpandAll Expand Argument` |
| Q6 | `TopN Aggregate Sort HashInnerJoin Project Dedup Expand Start ExpandAll Expand Argument` |

Q1、Q2 没有这层 Project，脊柱不变。时延差和负载坡度叠在一起，看不出稳定的加速。计划变化本身是这次测量确认的。

07 的规则留下了 `TopN` 节点。堆只减少最终发射的组，`GROUP BY` 仍然扫完全部分组，存储 RPC 的次数不变。Q4 的 p50 从 06 的 82452 到 81261，Q5 从 1609 到 1907，Q6 从 926 到 1064。没有把这个差值写成融合收益。

---

## 7. Q3 的组合

09 单独看，Q3 仍是基线那条 `HashInnerJoin` + `ExpandAll`，1801 行，SHA `45e59fd185d3`。规则要求 `Limit → Dedup → HashInnerJoin`，右子是单步 `ExpandAll`，并且 `hasOutputColumns()` 为真。09 自己不调用 `setOutputColumns`，中间还有 02 才会去掉的 Project，所以不改写。

10（02+03+09，没有 01，也没有 11）把 Q3 收成：

```text
Limit Dedup Expand Project TagIndexPrefixScan Start
```

`Expand` 上能看到 `dedup=1`、`limit=5000`、`filter=(buy._rank>=1753660800)`、`joinInput=false`。storaged 的 `GetDstBySrcProcessor::buildPlan` 把表达式指针传成 `nullptr`，`SingleEdgeNode` 也没有 `RankRange`。`EdgeNode::exp_` 在这条路径上不参与扫描。过滤文本留在计划里，RocksDB 仍按整段反向边前缀扫描。实测 2719 行，SHA `e393e8dee9a4`。2719 是美妆商品的全部去重买家，90 天窗口没有生效。`LIMIT 5000` 大于这个数，所以多出来的是被丢掉的过滤，不是截断。这组 15910 µs 不能拿去和基线的 12217 µs 比快慢。

同一份 10 的二进制上，Q1/Q2/Q4/Q5/Q6 的 SHA 与行数仍是基线（Q4/Q5/Q6 的计划是 02 的计划）。错只出在 Q3 这条被改写的 `GetDstBySrc`。

11 在 10 的 graphd 上换了带 rank 窗口的 storaged。Q3 的脊柱与 10 相同，`Expand.filter` 仍是 `(buy._rank>=1753660800)`。存储侧对 `kEdgeRank` 取出下界 `1753660800`，`SingleEdgeNode` 用 `rangeWithPrefix` 从这条 rank 开始扫。结果 1801 行，SHA `45e59fd185d339542050700fd013ad009249ef0e6de5d0b4110b6ee8995c4dc2`，与基线和文档 47 的 opt 相同。

server p50 是 15622，样本 15232–16014。基线是 12217，样本 11713–12666。窗口生效之后这条改写仍然更慢。`sharedDedupLimit` 把这次 `GetDstBySrc` 收成单线程顺序扫描；1801 小于 5000，提前停止不触发；反向边度大约是 80082/50000。少解码省下来的时间盖不住少掉的 32 个 storage worker。Q4/Q5/Q6 在 11 上保持 02 的计划和基线 SHA，Q4 的 87 个 `co_buy≥7` 商品与基线相同。

Q1 在 11 里会走改正后的 `kEdgeRank` seek。p50 377，样本 311–471。负载更低的其它标签落在 382–482。度大约 20、窗口 1800 秒，这次看不出稳定的差。EXPLAIN 仍然是 `TopN Project ExpandAll`。

---

## 8. 这六条上没有挪走的算子

- Q1 的 `ORDER BY ts DESC | LIMIT 10` 仍是 graphd `TopN`。`PushLimitDownExpandAllRule` 只匹配 `Limit` 直接压在 `ExpandAll` 上。
- Q2 的 `MINUS` 仍在 graphd。
- Q4/Q5/Q6 的 `GROUP BY` / `COUNT` 仍在 graphd。部分聚合没有做。这是还留在 graphd 的大块 RPC，本轮补丁里没有它。
- 07 没有去掉 `TopN` 节点，也没有少一次存储往返。
- 06 的分片条件是顺序迭代且 `rowCount >= 1<<20`。这份夹具到不了这个门槛。06 实际走的是 `int64` 平坦表。
- 没有为「最近 10 条」做 rank 反向迭代器。`LIMIT [n]` 也没有写进这六条：那是逐步截断，按 rank 升序会返回最老的边，并且会关掉简单计划。
- 09 的请求级提前停止要求去重结果先攒满 `LIMIT`。Q3 的 5000 大于 1801，Q4 第二跳的 100000 大于扩展用户数。
- 08 对这六条是空操作：过滤用到的属性已经在 `YIELD` 里。
- 03 对这六条是空操作：能收成简单 `Expand` 的跳已经是单源 `getDstBySrc`，多源且要保留重复边做 `COUNT` 的跳必须留下 `ExpandAll`。

---

## 9. 重跑

```bash
# 二进制目录里要有 nebula-metad、nebula-storaged、nebula-graphd
bench/reco/swap_bins.sh /tmp/nb-bins/00-baseline all
python3 bench/reco/measure_patches.py \
  --label 00-baseline --rounds 7 \
  --out /tmp/reco-00.json
```

`--out` 不要指向已经提交的那份 JSON。测完用 `~/bin/nbctl stop` 然后 `~/bin/nbctl start` 把进程换回 `nebula-graph` 的构建。`~/bin/nbctl` 的 `BIN` 指着 `/home/dev/code/nebula-graph/build/bin`，不会加载 `/home/dev/code/nebula` 的补丁二进制。
