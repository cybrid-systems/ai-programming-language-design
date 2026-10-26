# 12 — 场景二压测：单机实测

> 查询和计划见 [11](11-scenario2-beauty-buyers.md)。
> 用户给出的线上区间是 P99 135–345 ms（10–200 并发），销售额排序后达不到 35 ms。那是用户的观察。下面的表是这次在一台 VM 上跑出来的数，不能和那个区间横比。
> 40% 和 35 ms 不作为本次是否达标的标准。表里只放测到的数。
> 原始记录：[`bench/scenario2/results/`](bench/scenario2/results/)。百分位从这些 JSON 再算，不另造。
> 测量日期：2026-10-26。

单机 loopback 还原不了用户的跨机开销，这点不变：

- RPC 走 127.0.0.1，没有多机 RTT。用户的 135–345 ms 里，host 之间的往返占多少，这里拆不开。
- 一个 storaged 进程独占这块盘和自己的 block cache。美妆商品按 VID 打散后的缓存失效，单盘上看不出来。
- `partition_num=10` 也只是本进程里的 10 个 part，请求不出网卡。

所以下面的毫秒数只说明这台机器上三种计划的相对差。

---

## 1. 环境和二进制

两边是**同一棵** `v3.8.0` 源码树、同一次 Release 链接出来的同一组二进制。`--enable_dst_only_edge_filter` 默认关，关掉时 `GoValidator::isSimpleCase` 仍在 `filter != nullptr` 处返回 false，走原来的 `GetNeighbors`。打开之后，DISTINCT 用户那条走 `getDstBySrc`。没有再编一份不带补丁的二进制，也没有用 GitHub 上的 ubuntu2004 包：那个包是另一套工具链（GCC 9 / glibc 2.31），和这次的 GCC 12 放在一起比，时延差里会混进编译器。

| 项 | 值 |
|----|----|
| 源码 | tag `v3.8.0`，`fa928930ab34f150db522933323aa610e54f26e7`，加上 [`patches/v3.8.0-dst-only-edge-filter.patch`](patches/v3.8.0-dst-only-edge-filter.patch) |
| 编译 | `g++-12` 12.4.0，`-O3 -DNDEBUG`（`CMAKE_BUILD_TYPE=Release`），jemalloc 开，测试关 |
| 第三方 | 官方预编译包 `vesoft-third-party-3.3-x86_64-libc-2.39-gcc-12.3.0-abi-11`，装在 `/opt/vesoft/third-party/3.3`。包内记录的编译器是 GCC 12.3.0，glibc 2.39，C++ ABI 11。本机没有 12.3 的编译器，用的是 Ubuntu 的 12.4 |
| Werror | 关掉。GCC 12.4 把 `src/common/memory/MemoryTracker.h` 里的 `std::hardware_destructive_interference_size` 当成 `-Werror=interference-size`。这是上游头文件和 GCC 12 的告警，不是补丁引入的。补丁源文件没有为了编过再改 |
| 机器 | Linux 6.12.94+，glibc 2.39，x86_64。`/proc/cpuinfo` 的 model name 只有 `Intel(R) Xeon(R) Processor`。4 vCPU。`MemTotal` 16387280 kB。`SwapTotal` 0 |
| 进程 | 各一个 `nebula-metad` / `nebula-graphd` / `nebula-storaged`，地址 `127.0.0.1`，端口 9559 / 9669 / 9779 |
| graphd | `--enable_optimizer=true`。运行时 flags：`num_worker_threads=4`，`num_netio_threads=4`（配置写 0，进程按 CPU 数取 4） |
| storaged | 运行时 `num_worker_threads=32`，`rocksdb_block_cache=256`（默认 conf 是 4，这次改成 256 MB） |
| 客户端 | `nebula3-python==3.8.0`，Python 3.12.3。没有用 `nebula-console` |

从 build 树直接起进程时，默认时区文件路径是安装布局 `share/resources/date_time_zonespec.csv`，第一次启动因此退出。三个进程的 flagfile 都加了 `--timezone_file=/tmp/nebula-380/resources/date_time_zonespec.csv`。storaged 在 `ADD HOSTS 127.0.0.1:9779` 之前不会完成监听；`measure.py` 会执行这句并等到 `SHOW HOSTS` 为 `ONLINE`。

补丁在这次加载和全部查询里没有改。flag 关和 flag 开的用户集合 SHA-256 相同，销售额合计都是 10073144，Top 100 的 `(uid, sales)` 顺序也相同。

---

## 2. 数据

`bench/scenario2/gen_data.py` 的 `make_dataset`，种子 2。rank 是每个 `(user, item)` 上的计数，避免第二次购买覆盖第一条；时间在属性 `ts` 里，不在 rank 里。model 边上的 `item_type` 从商品的 `type` 抄来。

| 项 | 值 |
|----|----|
| 点 | user 4000，item 2000，其中 `type=beauty` 的 382 |
| 边 | `buy` 500000。`beauty_ratio=0.2`，`recent_ratio=0.4` |
| 空间 | `beauty_stock`、`beauty_model`。`partition_num=10`，`replica_factor=1`，`vid_type=INT64` |
| 时间 | `now=1761436800`，窗口 90 天，比较字面量 `cutoff=1753660800`。查询里不用 `now()` |
| 命中 | 窗口内美妆购买边 40415。不同用户 4000（这个分布下每个用户至少有一条）。这些边的 `amount` 之和 10073144 |
| 索引 | stock：`item(type(16))`，数据导入后 `REBUILD TAG INDEX`，job `FINISHED`。model：同样的 tag 索引，外加 `buy(item_type(16), ts)`，`REBUILD EDGE INDEX` job `FINISHED` |

第一次 `REBUILD` 会因为 storaged 还没同步到新索引而 `E_INDEX_NOT_FOUND`。脚本等一个心跳后重试，第二次 job 成功。数字来自成功的那次 job，不是失败的那次。

---

## 3. 怎么量

脚本是 [`bench/scenario2/measure.py`](bench/scenario2/measure.py)。`run_bench.sh` 仍然依赖 `nebula-console`，这次没走它。

三条语句：

1. **q_users**，stock 空间。flag 关是原计划，flag 开是补丁计划。语句相同：

```ngql
LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id
| GO 1 STEP FROM $-.id OVER buy REVERSELY
    WHERE buy.ts > 1753660800
    YIELD DISTINCT buy._dst AS user
```

2. **q_sales**，同一空间，flag 关和 flag 开各跑一遍。补丁不该改这条计划：

```ngql
LOOKUP ON item WHERE item.type == "beauty" YIELD id(vertex) AS id
| GO 1 STEP FROM $-.id OVER buy REVERSELY
    WHERE buy.ts > 1753660800
    YIELD buy._dst AS uid, buy.amount AS amt
| GROUP BY $-.uid YIELD $-.uid AS uid, sum($-.amt) AS sales
| ORDER BY $-.sales DESC | LIMIT 100
```

正确性另外跑了不带 `ORDER BY` / `LIMIT` 的聚合，和生成器的按用户合计比较。

3. **q_model**，model 空间，不依赖那个 flag：

```ngql
LOOKUP ON buy
WHERE buy.item_type == "beauty" AND buy.ts > 1753660800
YIELD src(edge) AS user
```

这句没有 `DISTINCT`。返回的是命中的边，用户集合要再去重。

每个 worker 先跑 2 次丢掉，再跑 5 次计入样本。样本数 = 并发 × 5。并发 1 是额外的无竞争点，10/50/100/200 是要对比的档。百分位是成功样本上的线性插值，`rank = p/100 * (n-1)`。并发 1 只有 5 个样本，P99 几乎就是最大值。

两套时间：

- **server**：`ResultSet.latency()`，即 graphd 写进响应的 `latencyInUs`。`RequestContext` 在 `GraphService::future_executeWithParameter` 入口构造，计时包含这次调用在 graphd 里的停留，不只是某个算子的 `exec`。
- **client**：`session.execute` 前后的墙钟，含 Python 把结果解码出来的时间。
- **QPS**：成功次数 /（所有 worker 过 barrier 之后，最早开始到最晚结束）。预热不在这个窗口里。这是这个 Python 客户端的端到端吞吐，不是 storaged 内部的算子吞吐。

顺序：先测 flag 关（含 q_model），再只重启 graphd、打开 flag，测 flag 开的 q_users 和 q_sales。storaged 没重启，block cache 和页缓存对后一次是热的。每个查询自己的 2 次预热也丢掉了。这不是冷缓存对比。

4 个 graphd worker 面对 50/100/200 并发是过订阅。storaged 有 32 个 worker。结果行数大的时候（4000 或 40415），client 远大于 server，因为解码在 CPython 里，GIL 也会把下一次请求推迟。QPS 因此带这个客户端的上限。

---

## 4. 结果是否同一份

| 检查 | 结果 |
|------|------|
| q_users，flag 关 vs 生成器 | 4000 个用户，SHA-256 `ca7e464a7a501db98ca99fba8b12cb48f56e2b37f666450e05012923a1f0a2b8` |
| q_users，flag 开 | 同一个 SHA-256 |
| q_model 的用户集合 | 同一个 SHA-256。原始行 40415，其中重复行 36415 |
| q_sales 全量聚合 | flag 关、flag 开、生成器都是 4000 组，`sum(amount)=10073144` |
| q_sales Top 100 | flag 关和 flag 开的 `(uid, sales)` 列表逐行相同 |

---

## 5. 时延和 QPS

单位毫秒。server / client 的定义在第 3 节。数字四舍五入到 0.01，未舍入的浮点在 JSON 里。

### 5.1 q_users：flag 关（GetNeighbors）vs flag 开（getDstBySrc）

flag 关：

| 并发 | 样本 | server P50 | P95 | P99 | client P50 | P95 | P99 | QPS |
|------|------|------------|-----|-----|------------|-----|-----|-----|
| 1 | 5 | 36.16 | 38.66 | 38.77 | 54.73 | 66.24 | 68.48 | 17.68 |
| 10 | 50 | 59.04 | 159.12 | 159.96 | 234.71 | 456.81 | 577.47 | 35.20 |
| 50 | 250 | 61.75 | 820.39 | 836.27 | 1206.29 | 2847.56 | 3281.35 | 33.97 |
| 100 | 500 | 60.52 | 1707.77 | 1757.11 | 2180.03 | 5650.11 | 7353.60 | 34.62 |
| 200 | 1000 | 61.31 | 2650.57 | 2710.97 | 4684.00 | 11189.30 | 15394.46 | 32.63 |

flag 开：

| 并发 | 样本 | server P50 | P95 | P99 | client P50 | P95 | P99 | QPS |
|------|------|------------|-----|-----|------------|-----|-----|-----|
| 1 | 5 | 13.69 | 14.28 | 14.29 | 30.31 | 42.26 | 44.65 | 30.43 |
| 10 | 50 | 20.82 | 85.19 | 88.90 | 223.71 | 393.22 | 508.53 | 39.93 |
| 50 | 250 | 20.31 | 168.12 | 210.20 | 897.64 | 2060.20 | 2949.92 | 40.74 |
| 100 | 500 | 21.19 | 791.74 | 827.23 | 2026.02 | 4933.00 | 5753.16 | 39.19 |
| 200 | 1000 | 22.76 | 1677.14 | 1716.53 | 3970.29 | 10622.93 | 13103.50 | 37.20 |

并发 1 的 server P50，flag 开是 flag 关的 13.69/36.16 = 0.379。这是这台机器、热缓存、这条数据和这个客户端上的比值，不是线上 135–345 ms 的下降比例。并发从 10 加到 200 时，两边 QPS 都停在大约 33–41：4 个 graphd worker 已经满了。flag 开的 server P50 停在 21 ms 附近，flag 关停在 60 ms 附近；P99 仍随并发涨到秒级，client P99 到 10 秒以上。补丁缩短的是单次执行，没有把 200 并发的排队尾部消掉。

### 5.2 q_sales：同一条 GetNeighbors + Aggregate + TopN

flag 关：

| 并发 | 样本 | server P50 | P95 | P99 | client P50 | P95 | P99 | QPS |
|------|------|------------|-----|-----|------------|-----|-----|-----|
| 1 | 5 | 45.92 | 47.38 | 47.67 | 47.09 | 48.73 | 49.03 | 21.12 |
| 10 | 50 | 180.12 | 191.63 | 206.79 | 188.45 | 216.33 | 221.67 | 53.17 |
| 50 | 250 | 909.76 | 972.20 | 1006.09 | 948.89 | 1057.06 | 1108.31 | 52.95 |
| 100 | 500 | 1780.59 | 1878.53 | 1892.45 | 1878.41 | 2204.64 | 2524.64 | 52.96 |
| 200 | 1000 | 3502.18 | 4082.27 | 4119.16 | 3711.63 | 4509.74 | 6126.83 | 51.53 |

flag 开：

| 并发 | 样本 | server P50 | P95 | P99 | client P50 | P95 | P99 | QPS |
|------|------|------------|-----|-----|------------|-----|-----|-----|
| 1 | 5 | 48.12 | 58.82 | 60.27 | 49.44 | 60.13 | 61.54 | 19.20 |
| 10 | 50 | 179.63 | 201.05 | 206.22 | 189.61 | 227.51 | 245.28 | 52.52 |
| 50 | 250 | 830.37 | 949.55 | 955.77 | 923.70 | 1096.08 | 1422.30 | 52.75 |
| 100 | 500 | 1748.24 | 2158.85 | 2240.41 | 1868.29 | 2434.30 | 2531.70 | 51.21 |
| 200 | 1000 | 3702.95 | 4320.00 | 4436.32 | 3923.24 | 4620.90 | 5034.41 | 50.72 |

结果只有 100 行，client 和 server 接近，解码不是大头。QPS 在并发 10 之后停在大约 51–53。server P50 几乎随并发线性变长（4 个 worker 排队）。flag 开没有单独的优势：并发 1 略慢（48.12 vs 45.92，只有 5 个样本），并发 50 略快（830 vs 910）。同一计划，差在噪声和「flag 开是后跑的、缓存更热」里面，不能记成补丁的收益或回退。

### 5.3 q_model：边上 `(item_type, ts)` 索引

| 并发 | 样本 | server P50 | P95 | P99 | client P50 | P95 | P99 | QPS |
|------|------|------------|-----|-----|------------|-----|-----|-----|
| 1 | 5 | 79.68 | 80.37 | 80.48 | 284.03 | 318.94 | 325.37 | 3.43 |
| 10 | 50 | 94.72 | 465.61 | 473.85 | 2236.75 | 2803.21 | 3161.96 | 4.26 |
| 50 | 250 | 95.09 | 2525.47 | 2544.36 | 11994.26 | 16788.48 | 18528.65 | 4.02 |
| 100 | 500 | 103.92 | 5020.81 | 5042.82 | 24325.96 | 34853.72 | 39542.41 | 3.87 |
| 200 | 1000 里 999 次失败 | — | — | — | — | — | — | — |

并发 200 的失败信息是 graphd 返回的：`Used memory hits the high watermark(0.800000) of total system memory.` 成功 1 次、失败 999 次。那 1 次的延迟不列进表。内存水位是 graphd 自己的 tracker，比例 0.8 乘 `MemTotal`。这条语句一次就吐 40415 行，200 路同时在飞时被拒绝。

并发 1 的 server P50 是 79.68 ms，比 flag 开的 q_users（13.69 ms）慢，也比 flag 关（36.16 ms）慢。原因在下一节的行数：索引命中的是 40415 条边，而且 PROFILE 里投影带了 `amount,item_type,ts` 以及边的 src/dst/rank/type。q_users 的 flag 开只回 4000 个 VID。用户集合三者一致，但 q_model 交给客户端的行数是边数，不是用户数。QPS 停在大约 4，和一次解码 4 万行对得上。

---

## 6. PROFILE 行数

每个查询在并发扫之前做了一次 `PROFILE`。字节数没有测到。`graph/util/Utils.cpp` 的 `collectRespProfileData` 只往 `other_stats` 里放 `host`、`exec`、`total`、`vertices`（大于 0 才写）和 `storage_detail`。没有 response 字节字段。下面不估算字节。行数用算子 `profiles.rows`；`vertices` 只在 flag 开的 Expand 上出现。

`storage_detail` 里的微秒是算子自己记的计数，和 RPC 的 `total` 不是同一把尺子（索引扫描那条里，内部计数比 RPC total 还大）。它们只用来确认走了哪个算子，不拿来做时延表。

| 语句 | 算子 | `profiles.rows` | resp 里能对上的信息 |
|------|------|-----------------|---------------------|
| q_users，flag 关 | `TagIndexPrefixScan` | 382 | `IndexVertexScanNode`，`Path=(type="beauty", )` |
| | `ExpandAll` | 40415 | `GetNeighborsNode` + `FilterNode` |
| | `HashInnerJoin` | 40415 | |
| | `Dedup` | 4000 | 最终结果 4000 行 |
| q_users，flag 开 | `TagIndexPrefixScan` | 382 | 同上，仍是美妆商品 |
| | `Expand` | 4000 | `GetDstBySrcProcessorTotal`，`vertices: 4000`。没有 `ExpandAll` / `GetNeighborsNode` |
| | `Dedup` | 4000 | |
| q_sales，flag 关和 flag 开 | `ExpandAll` | 40415 | 都是 `GetNeighborsNode` + `FilterNode` |
| | `Aggregate` | 4000 | |
| | `TopN` | 100 | 最终结果 100 行 |
| q_model | `EdgeIndexPrefixScan` | 40415 | `IndexEdgeScanNode`，`Path=(item_type="beauty", ts=(1753660800,INF])` |
| | `Project` | 40415 | 最终结果 40415 行 |

flag 关回给后续算子的是 40415 条过滤后的购买边，再在 graphd `Dedup` 成 4000 个用户。flag 开在 storaged 里就收成 4000 个 VID（`vertices` 与算子行数一致），graphd 的 `Dedup` 没有再减行。销售额两条计划树相同，都把 40415 行送进 `Aggregate`。复合索引把谓词放进了索引范围（`ts` 上界是 `INF`，下界是 cutoff），但吐出的仍是每条命中边，不是去重后的用户。

---

## 7. 这次能说的和不能说的

能说的：

- 补丁切到了设计的那条路，并且和原计划、和生成器的用户集合一致。销售额语句没有被切进 `getDstBySrc`，合计与 Top 100 一致。
- 在这台 4 vCPU 的机器上，q_users 并发 1 的 server P50 从 36.16 ms 降到 13.69 ms。并发拉高之后，QPS 只从大约 33 提到大约 40，尾部仍是排队。
- 复合索引的 LOOKUP 用户集合正确，索引条件含 `item_type` 前缀和 `ts` 范围。它返回 40415 行，client 时间和内存都比「只回 VID」的补丁计划重。并发 200 触发了 graphd 内存水位。
- 销售额排序的耗时由聚合前的 40415 行和 4 个 worker 的排队决定。补丁对它没有单独的收益。

不能说的：

- 不能把 13.69 ms 或任何一档 P99 写成用户线上的 135–345 ms 变成了多少。中间缺了多机 RTT、多块盘和真实扇出。
- 不能把并发 1 的 0.379 倍说成已经满足或没有满足「降 40%」这个目标。目标本次不评。
- 不能给回传字节一个数。PROFILE 里没有。

---

## 8. 多节点怎么复现

至少 3 个 storaged、不同的 `--local_ip` 和端口，1 个 metad，1 个 graphd。space 的 `partition_num` 要大于 storaged 个数，`replica_factor=1`，`vid_type=INT64`。不要用 replica 把每条边复制到所有节点。

1. 用同一套 Release 选项编出二进制。比较 flag 关和 flag 开时，不要换编译器。
2. 导入 stock 空间，`REBUILD TAG INDEX` 后等 job `FINISHED`。`t` 用字面量，不要用 `now()`。
3. graphd `--enable_optimizer=true`，flag 关。对 q_users、q_sales 打 10、50、100、200，每档预热再记 P50/P95/P99 和 QPS。PROFILE 应看到 `ExpandAll`，行数接近命中边数。
4. 换上补丁版的 graphd 和**全部** storaged 再开 flag。只换 graphd 会拿到未过滤的 dst。
5. 重跑 q_users 和 q_sales。q_users 的 PROFILE 应出现 `Expand` 和 `vertices`，行数接近用户数。q_sales 仍应是 `GetNeighbors`。两边的用户集合做 diff。
6. 另建 model 空间，`REBUILD EDGE INDEX`，跑 q_model。这条不需要补丁。若要比的是用户集合而不是边，语句上要另加去重；本次测的是上面那句未去重的 LOOKUP。
7. 对比冷缓存时，每档之前重启 storaged 或丢页缓存。本次单机没有做这一步。

多个 storaged 若只是同一台机器上的多个进程，报告里仍要写明 RPC 走 loopback。可以横比的是 PROFILE 行数，以及同一台机器上三种计划的相对差。
