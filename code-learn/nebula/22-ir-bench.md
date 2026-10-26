# 22 — 中间表示：P0 的吞吐和时延

> 问的是 [21](21-ir-optimization-design.md) 里那些改动，对场景二的吞吐和时延有多少。本节只写这次进程打出来的数。字节差仍在 [20](20-intermediate-representation.md) 和 [21](21-ir-optimization-design.md)，不把字节比当成时延比。
> 源码 tag `v3.8.0` `fa928930`。数据和种子与 [12](12-scenario2-bench.md) 相同：种子 2，用户 4000，商品 2000，边 500000，`beauty_ratio` 0.2，`recent_ratio` 0.4，`now` 1761436800，窗口 90 天，`cutoff` 1753660800，10 个 part，VID `INT64`。美妆边 40415，近期美妆用户 4000，销售额合计 10073144。
> 这是原版 graphd/storaged 对 P0 三份补丁，两边都没有 `patches/v3.8.0-dst-only-edge-filter.patch`，也没有 [16](16-partial-agg-impl.md) 的部分聚合。q_users 因此仍走 `GetNeighbors` / `ExpandAll`。并发 1 的 server P50 落在 35–43 ms，和 [12](12-scenario2-bench.md) 里 flag 关的 36.16 ms 是同一档。
> 脚本和原始 JSON 在 [`poc-repr/ir-bench/`](poc-repr/ir-bench/)。`bench/scenario2/` 和 `patches/` 没有改。
> 分析日期：2026-10-26。

---

## 0. 先看结论

P0 改了执行计划里的返回列，结果集合与原版一致。吞吐和时延没有落在轮次噪声外面的稳定收益。

并发 1，零水位的轮次：

| 查询 | 原版 server P50 | P0 server P50 | 原版 QPS | P0 QPS |
|------|-----------------|---------------|----------|--------|
| q_users | 35.79 ms（34.75–42.59，n=5） | 36.28 ms（35.38–46.99，n=5） | 18.03（15.43–18.11） | 17.97（14.20–18.17） |
| q_sales | 46.13 ms（44.10–51.48，n=5） | 45.56 ms（44.24–46.96，n=4） | 21.29（17.63–22.36） | 21.40（20.89–21.98） |
| q_model | 72.71 ms（63.69–78.99，n=5） | 62.02 ms（60.58–64.28，n=4） | 3.25（3.06–3.97） | 3.74（3.62–3.93） |

表内第一个数是中位，括号是最小到最大。QPS 的区间两边重叠。q_users、q_sales 的 server P50 也重叠。q_model 的 server P50 区间只差 0.6 ms（P0 最高 64.28，原版最低 63.69），中位大约低 11 ms，但 QPS 并不跟着分开。PROFILE 里 `EdgeIndexPrefixScan` 的 `total_duration` 原版 43.3–58.3 ms、P0 39.4–51.0 ms，同样重叠。所以这 11 ms 记在噪声里，不写成稳定加速。

并发 10/50/100/200 上，完整成功的轮次同样重叠；后几轮机器可用内存掉到水位以下，原版和 P0 都会被拒绝。P0 没有消掉 `high watermark(0.800000)`。采样到的 graphd / storaged RSS 峰值也没有稳定地更低。

P1、P2 的吞吐和时延是估算，依据是这次 PROFILE 的算子耗时，见第 5 节。上界是相关算子自己的 `exec_duration`，不是 [20](20-intermediate-representation.md) 的字节比。

---

## 1. 怎么编、怎么跑

两边同一棵 `/tmp` 浅克隆，tag `fa928930`。编译器 `g++-12` 12.4.0。三方库是官方包 `vesoft-third-party-3.3-x86_64-libc-2.39-gcc-12.3.0-abi-11`，装在 `/opt/vesoft/third-party/3.3`。CMake：Ninja，`Release`，`-O3 -DNDEBUG`，`ENABLE_JEMALLOC=ON`，`ENABLE_WERROR=OFF`，`ENABLE_TESTING=ON`。[12](12-scenario2-bench.md) 那次 `ENABLE_TESTING=OFF`。这次打开测试是为了链出 `expression_test` / `executor_test` / `validator_test`；原版和 P0 用的是同一次 CMake 配置，server 目标仍是 `-O3 -DNDEBUG`。jemalloc 静态链进二进制。

P0 在原版编完、二进制拷到 `/tmp/nebula-bins/base` 之后，打上这三份补丁再增量编译，拷到 `/tmp/nebula-bins/p0`：

- [`v3.8.0-aggdata-lazy-set.patch`](poc-repr/v3.8.0-aggdata-lazy-set.patch)
- [`v3.8.0-returncols-key-funcs.patch`](poc-repr/v3.8.0-returncols-key-funcs.patch)
- [`v3.8.0-exec-reserve-shrink.patch`](poc-repr/v3.8.0-exec-reserve-shrink.patch)

`graphd` 两边都约 59 MB，`cmp` 不相同。启动脚本是 [`ir-bench/start_cluster.sh`](poc-repr/ir-bench/start_cluster.sh)，从 `bench/scenario2/start_cluster.sh` 抄来，删掉了 `--enable_dst_only_edge_filter`（这两份二进制没有这个 flag，gflags 会直接拒绝启动）。`rocksdb_block_cache=256`，`--timezone_file` 指向仓库里的 `date_time_zonespec.csv`。一进程 metad / storaged / graphd，`127.0.0.1`，端口 9559 / 9669 / 9779。`num_worker_threads=0`，在这台 4 vCPU 上就是 4。`system_memory_high_watermark_ratio=0.8`。水位看的是系统可用内存：`(1 - available/total) > 0.8`，也就是可用低于 MemTotal 的 20%。加载时 MemTotal 16387280 kB，MemAvailable 14031372 kB。

客户端 `nebula3-python==3.8.0`。server 时延是 `ResultSet.latency()`（`latency_in_us`）。客户端时延是 `execute` 前后的墙钟，含 Python 解码。QPS 是成功样本数除以最早开始到最晚结束的墙钟。分位是线性插值，`rank = p/100*(n-1)`。每个并发先热身 2 次，再记 5 次，样本数 = 并发 × 5。RSS 每 0.2 s 读一次 `/proc/<pid>/status` 的 `VmRSS`，记下该并发档期间的采样最大值；这是下界，不是连续峰值。`VmHWM` 只升不降，后一档的 HWM 含着同一进程里前面各档，所以表里用采样最大值。

数据只加载一次（原版进程）。然后交替：

| 轮 | 顺序 | 并发 |
|----|------|------|
| r1 | 原版，P0 | 1, 10, 50, 100, 200 |
| r2 | P0，原版 | 同上 |
| r3 | 原版，P0 | 同上 |
| r4 | 原版，P0 | 只有 1 |
| r5 | P0，原版 | 只有 1 |

r4/r5 是 r3 撞水位之后补的并发 1，用来把低并发的噪声区间补满。集群在每一轮重启，数据目录不换。

---

## 2. 正确性、单测、tck

每一轮能跑完校验的查询都通过：用户集合 SHA-256 与生成器一致（`ca7e464a7a501db98ca99fba8b12cb48f56e2b37f666450e05012923a1f0a2b8`），q_sales 合计 10073144.0。q_model 行数 40415，去重后仍是这 4000 个用户。

PROFILE 的 `returnCols` 说明补丁进了计划，而且只动了该动的列：

| 算子 | 原版 | P0 |
|------|------|----|
| q_model `EdgeIndexPrefixScan` | `_src,_dst,_rank,_type,amount,item_type,ts` | `_src,_dst,_rank,_type,item_type,ts`（没有 `amount`） |
| q_users / q_sales `TagIndexPrefixScan` | `_vid,_tag,name,type` | `_vid,type` |
| `ExpandAll` | q_users 是 `_dst,ts`；q_sales 是 `_dst,amount,ts` | 与原版相同 |

`item_type` 和 `ts` 还在，WHERE 没有被裁掉。`amount` 在 q_sales 的 `ExpandAll` 里还在。

P0 构建上的单测（`LD_LIBRARY_PATH` 指向三方库）：

| 二进制 | filter | 结果 |
|--------|--------|------|
| `expression_test` | `AggregateExpressionTest.*` | 1 passed |
| `executor_test` | `DedupTest.*:TopNTest.*` | 9 passed |
| `validator_test` | `LookupValidatorTest.*` | 4 passed |

`LookupValidatorTest` 查的是计划形状，不断言 `returnCols` 里有没有 `amount`。返回列以上面的 PROFILE 为准。

tck 跑的是 P0 的 `build/bin`，官方 `tests/nebula-test-run.py --cmd start` 拉起集群并装入 nba 等数据集，再跑 `Agg.feature` 和 `LookupEdge.feature`。本机 Python 3.12 配上游钉死的 pytest 5 跑不起来，用的是 pytest 7.4.4 + pytest-bdd 4.0.2。另外只在 `/tmp` 的树上改了三处，没有进这个仓库：`nbv.py` 的 `(?i:true|false)`（ply 在 3.12 上拒收 `(?i)true|false`）、`pytest_xdist_node_collection_finished` 标成 optional hook、以及一个只加载这两个 feature 的 `test_ir_subset.py`。结果：**80 passed，352.58 s**。`LookupEdge` 的 feature 级 `Examples` 在 pytest-bdd 4 下展开进了这 80 个。

---

## 3. 时延和吞吐

「干净」指该档 `errors = 0` 且 `worker_errors` 为空。中位和最小–最大来自 [`results/summary.txt`](poc-repr/ir-bench/results/summary.txt)，由 `summarize.py` 从 JSON 算出。单位 ms，QPS 是成功样本 / 墙钟。

### 3.1 并发 1

见第 0 节的表。五轮原版、四到五轮 P0，水位都是 0。

q_model 的客户端 P50 是 249–318 ms（原版）和 252–278 ms（P0）。server 只有 60–79 ms。QPS 约 3–4，墙钟花在 Python 解码 40415 行，不在 graphd 的那几十毫秒上。列少一列 `amount` 没有把客户端 QPS 拉出噪声。

### 3.2 更高并发里两边都跑完的档

只列干净轮次。P95/P99 的完整格子在 `summary.txt`。

| 查询 | 并发 | 原版 server P50 | P0 server P50 | 原版 QPS | P0 QPS |
|------|------|-----------------|---------------|----------|--------|
| q_users | 10 | 53.84（47.39–56.27，n=3） | 55.59（54.18–68.34，n=3） | 36.93（36.08–37.58） | 32.66（31.79–37.02） |
| q_users | 50 | 53.43（50.33–57.08，n=3） | 59.75（58.42–76.11，n=3） | 35.75（35.30–36.23） | 33.75（32.20–35.63） |
| q_users | 100 | 54.34（53.73–62.48，n=3） | 58.06（54.05–70.35，n=3） | 34.97（34.96–36.33） | 34.11（33.21–36.82） |
| q_users | 200 | 55.53（55.11–61.77，n=3） | 64.81（60.27–69.35，n=2） | 33.97（33.91–34.74） | 33.06（32.14–33.99） |
| q_sales | 10 | 163.36（162.45–164.58，n=3） | 171.63（166.29–176.98，n=2） | 56.00（53.13–56.78） | 54.41（52.60–56.22） |
| q_sales | 50 | 803.78（789.35–845.43，n=3） | 794.66（793.79–795.52，n=2） | 54.42（53.03–57.31） | 54.77（53.16–56.38） |
| q_sales | 100 | 1569.95（1523.88–1616.03，n=2） | 1454.37（1411.95–1496.78，n=2） | 55.36（53.88–56.84） | 54.69（52.91–56.47） |
| q_sales | 200 | 3396.83（3245.89–3547.78，n=2） | 3515.51（n=1） | 54.00（51.97–56.02） | 52.79（n=1） |
| q_model | 10 | 91.55（69.77–106.52，n=3） | 75.28（73.55–77.01，n=2） | 4.38（3.68–4.40） | 4.52（4.38–4.66） |
| q_model | 50 | 97.30（n=1） | 71.63（69.07–74.18，n=2） | 4.12（n=1） | 4.16（4.11–4.22） |
| q_model | 100 | 97.63（n=1） | 67.55（65.72–69.38，n=2） | 4.02（n=1） | 4.20（4.19–4.20） |
| q_model | 200 | 104.73（n=1） | 67.44（67.13–67.75，n=2） | 3.93（n=1） | 4.20（4.20–4.20） |

q_users 从并发 10 起 QPS 就停在 33–37，server P50 停在 50–70 ms，P95 随并发涨到数秒。饱和之后 P0 的 QPS 不高于原版。

q_sales 的 QPS 从并发 10 起停在 52–57。并发 100 的 server P50 区间（原版 1524–1616，P0 1412–1497）不相交，差大约 70–200 ms，相对 1.5 s 的 P50 大约 5–10%。并发 200 的干净原版有两轮（3246 和 3548），P0 只有一轮 3516，落在原版区间里。并发 50 的 P50 几乎重合。因此不把并发 100 这一格单独写成收益。

q_model 并发 10 的 P95：原版 377–498 ms（n=3），P0 312–315 ms（n=2），区间不相交。P50 仍重叠（原版最低 69.77，P0 最高 77.01）。QPS 重叠。并发 50 及以上原版只剩下 r1 一轮干净样本，P0 有两轮。r1 的 P95 在并发 200 是 9666.9 ms，两轮 P0 是 6410.2 和 6520.9 ms。尾部差很大，但原版没有第二轮，不能从「r1 原版更慢」里分出补丁效应。这两轮 P0 的 QPS 是 4.20，r1 原版是 3.93，仍在并发 1 原版自己的 QPS 区间（3.06–3.97）边上。

### 3.3 RSS

采样最大值，单位 KiB。并发 1 的 q_users：graphd 原版 78744–84496，P0 78620–88380；storaged 原版 76248–79652，P0 78308–83552。同一量级。

q_model 并发 200，仅干净轮：graphd 原版 2138468（n=1），P0 2201560–2438632（n=2）；storaged 原版 1868132，P0 1652284–1727096。graphd 峰值 P0 没有更低。0.2 s 采样会漏掉更尖的峰。`shrink_to_fit` 把 malloc 容量还回去，不保证 RSS 还给内核；水位用的又是系统可用内存，不是这个 RSS。

### 3.4 水位

`MemoryUtils::hitsHighWatermark` 在可用内存低于 MemTotal 的 20% 时拒绝查询，错误文本是 `Used memory hits the high watermark(0.800000) of total system memory.`。`measure.py` 只把已经返回的样本计进 `watermark_errors`。热身失败记在 `worker_errors`，样本数可以是 0。下表把两种都算进去。

| 轮 | 发生的位置 | 次数 |
|----|------------|------|
| r1 原版、r1 P0 | 无 | 0 |
| r2 P0 q_sales 并发 200 | `Execution had been killed`，文本里没有 watermark | 1/1000，其余 999 成功 |
| r2 原版 q_model 并发 50 | watermark | 154/250 |
| r2 原版 q_model 并发 100、200 | 热身即 watermark，没有成功样本 | worker 文本 65 和 58 条 |
| r3 原版 q_sales 并发 100 | watermark | 370/500 |
| r3 原版 q_sales 并发 200 | 热身 watermark | worker 文本 188 条 |
| r3 原版 q_model 并发 50 | watermark | 250/250 |
| r3 原版 q_model 并发 100、200 | 热身 watermark | worker 文本 100 和 174 条 |
| r3 P0 q_users 并发 200 | watermark | 842/1000 |
| r3 P0 接着 `USE beauty_stock` | 同一条 watermark，q_sales / q_model 没有跑 | 进程退出码 1 |

r2 先跑的是 P0，q_model 并发 200 完整成功（graphd 采样 2438632 KiB）。紧接着的原版在 q_model 并发 50 就开始被拒绝。顺序是「先跑的那一边把可用内存打下去」，不是 P0 更省。r1 当时 MemAvailable 约 13.4 GiB，两遍 q_model 并发 200 都过了。r4/r5 只跑并发 1，水位 0。

没有一处卡死。r3 P0 停在 `USE beauty_stock` 的水位错误，日志是 `/tmp/ir-bench.log` 末尾的 `RuntimeError`。

---

## 4. PROFILE 把时间花在哪

每次查询在压测循环之前打一条 `PROFILE`。`exec_duration_in_us` 是算子自身，`total_duration_in_us` 含等待存储的时间。下面是各轮 PROFILE 的范围，单位微秒。

q_users，原版五次，server 39106–44446：

| 算子 | exec | total |
|------|------|-------|
| `TagIndexPrefixScan` | 0 | 1153–2084 |
| `ExpandAll` | 10599–11008 | 28586–33002 |
| `HashInnerJoin` | 4634–5749 | 同量级 |
| `Project`（40415 行） | 2473–2881 | 同量级 |
| `Dedup` | 858–1107 | 同量级 |

P0 的 `ExpandAll` exec 在四次不含水位轮的 PROFILE 里是 10310–10821，和原版的 10599–11008 叠在一起。`Dedup` 858–1107 对 874–1053，也叠在一起。`reserve` / `shrink_to_fit` 没有在这条 36 ms 的查询上留下可分开的耗时。

q_sales，原版 `Aggregate` exec 4667–5723，`ExpandAll` exec 12083–14344，`TopN` exec 221–254。P0 的 `Aggregate` 4548–4618（四次）。差几百微秒，并发 1 的 server P50 噪声是数毫秒，盖住了这一截。

q_model，原版 `EdgeIndexPrefixScan` total 43255–58250，`Project` exec 20604–24407。P0 的扫描 total 39404–50957，`Project` exec 17857–22543。少了 `amount` 之后，扫描和 `Project` 的区间仍和原版重叠。

---

## 5. P1 / P2 估算

以下全部是估算。上界取这次 PROFILE 里对应算子的自身耗时，不把 [20](20-intermediate-representation.md) 的堆或 Thrift 字节比直接乘到 QPS 上。

**P1 扁平 `GetNeighbors`（q_users / q_sales）.** 原版 `ExpandAll` 自身大约 11 ms，占 q_users 并发 1 server P50（中位 35.8 ms）的三成。`total - exec` 大约 18 ms，是索引扫描和存储侧过滤，扁平响应不去改 RocksDB。本地回环上 [21](21-ir-optimization-design.md) 那 1.51 MB 的拷贝不到 1 ms，时间在 graphd 把嵌套 `List` 解成 `Value`。估算：server P50 下降 **0–11 ms**。这 11 ms 占并发 1 server P50 的约三成；饱和段 QPS 已经停在 34–37，若这 11 ms 全是可去掉的 CPU，QPS 上界大约是三成。11 ms 里还有拼 `DataSet` 行，收紧后的估算是 **QPS 0–15%**。并发 1 的客户端 P50 比 server 还多出大约 16 ms，那一档的 QPS 对这 11 ms 不敏感。

**P1 定长整数列 / 延迟物化（q_model）.** `Project` 自身 18–24 ms。P0 已经去掉 `amount`，`Project` 并没有从这 20 ms 里掉出去，所以「少一列 `Value`」不是这 20 ms 的主体。估算 server P50 **0–5 ms**。客户端 P50 是 250–320 ms，QPS 大约 3–4。估算这条查询在当前客户端下的 **QPS 变化约 0**。要动 QPS，得少传 40415 行或少在客户端解码，那不是 graphd 内部列布局。

**P2 按批调度、列式 `SUM`.** q_model 是一次 `EdgeIndexPrefixScan` 再 `Project`，存储调用本来就等整批 40415 行回来。分批不和另一段计算重叠，估算并发 1 的 server P50 **0–5%**。q_sales 的 `Aggregate` 自身约 5 ms，相对 46 ms 的 P50、以及并发 10 以上已经饱和的 53 QPS。列式 `SUM` 就算吃掉这 5 ms，估算 QPS **0–10%**，和现在轮次之间的 QPS 波动（q_sales 并发 10 是 53–57）同一量级。

**P2 与水位.** 外部响应仍是整表 `DataSet`。并发 200 时每条 q_model 都要拿住 40415 行直到客户端读完，Python 还在 GIL 上解码。分批只缩短算子内部的中间表，不把「200 份最终结果」变成一批。这次水位是系统可用内存低于 20%，后几轮原版和 P0 都会撞上。估算：P2 **不会**让这个 harness 的并发 200 水位次数掉到 0。RSS 要下来，还得让结果流式离开进程，那已经超出 [21](21-ir-optimization-design.md) 里「到客户端边界仍收成 `DataSet`」的 P2。

没有跑 `perf stat`。算子拆分用的是 PROFILE 的 `exec_duration_in_us` / `total_duration_in_us`。`perf` 会把 graphd 和 200 个 Python 线程混在一起，分不出上面这几行。
