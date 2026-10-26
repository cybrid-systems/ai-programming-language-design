# 12 — 场景二压测：未实测，以及多节点怎么复现

> 目标句和计划见 [11](11-scenario2-beauty-buyers.md)。
> 用户给出的线上区间是 P99 135–345 ms（10–200 并发），销售额排序后达不到 35 ms。这是用户的观察，不是本次跑出来的数。
> 40% 时延下降和 35 ms 都是目标。下面没有用估算去填这两个数。
> 分析日期：2026-10-26。

---

## 1. 这次没有跑出时延

`/tmp/nebula` 是源码树，`third-party/` 里只有 `install-third-party.sh` 等安装脚本，没有 folly、fbthrift、RocksDB 的构建产物，也没有 `build/`。本机没有 `nebula-graphd` / `nebula-storaged` / `nebula-console`。

原版和补丁版都没有开始编译。卡在第三方依赖还没装：`install-third-party.sh` 会下载并编译整套依赖，本次没有跑它，因此也没有 `cmake && make` 的编译错误可以贴。单测 `dst_only_edge_filter_test` 同样没链接。

没有集群，就没有 P50/P99、没有 PROFILE 的 `exec_time`、没有回传行数。脚本在 `bench/scenario2/`，跑起来会先写 nGQL；找不到 console 就退出，并在 stdout 写明未实测。

单机 VM 即便以后编译成功，也还原不了用户的跨节点开销：

- 本机 loopback 的 RPC 没有多机 RTT。用户的 135–345 ms 里，host 之间的 `getNeighbors` 往返占多少，这里拆不开。
- 一个进程里的多个 storaged 仍共享磁盘和页缓存。美妆商品按 VID 打散后的缓存失效，单盘上看不出来。
- `num_parts` 再大，请求也不出网卡。

所以下面不写「预计能到 35 ms」。

---

## 2. 行数上补丁能少什么

这不是时延。设一个 host 上窗口内的购买边有 E 条，涉及 U 个不同用户，每条边回传 `_dst` 加 `ts`（以及销售额语句里的 `amount`）。

| 语句 | flag 关（现有 3.8，优化器开） | flag 开 |
|------|------------------------------|---------|
| `YIELD DISTINCT buy._dst`，`WHERE buy.ts > t` | 边过滤已在 `GetNeighbors`。该 host 仍回约 E 行，每行带边上的列，graphd 再去重 | `getDstBySrc` 回约 U 个 VID，host 内已经去重 |
| `YIELD buy._dst, buy.amount` 再 `GROUP BY` / `ORDER BY` / `LIMIT` | 回约 E 行。补丁不进入这条计划 | 与 flag 关相同 |
| 建模：`LOOKUP ON buy WHERE item_type AND ts` | 不扫每个商品的邻边。回的是索引命中的边，条数约等于全图窗口内的美妆购买，而不是「美妆商品数 × 每件商品的历史边」 | 与补丁无关 |

U/E 要靠真实分布。脚本里的 `--beauty-ratio` 和 `--recent-ratio` 只决定造数，不代替测量。

40% 若理解成「字节少 40%」，DISTINCT 用户语句在 U 远小于 E 时可以超过；销售额语句这份补丁是 0。35 ms 相对 135 ms 需要大约 4 倍，少回传用户 VID 单独不够，除非同时去掉按商品扇出的前缀扫描（第 4 节的复合索引）。

---

## 3. 脚本

目录 [`bench/scenario2/`](bench/scenario2/)。

```bash
python3 code-learn/nebula/bench/scenario2/gen_data.py \
  --users 100000 --items 20000 --edges 2000000 \
  --beauty-ratio 0.15 --recent-ratio 0.2 \
  --out code-learn/nebula/bench/scenario2/out

# 有集群和 nebula-console 时：
NEBULA_CONSOLE=/path/to/nebula-console \
NEBULA_ADDR=127.0.0.1:9669 \
CONCURRENCY=10,50,100,200 \
code-learn/nebula/bench/scenario2/run_bench.sh
```

`gen_data.py` 写四份文件：

| 文件 | 内容 |
|------|------|
| `schema_stock.ngql` | tag `user`、`item(type)`，edge `buy(ts, amount)`，`item(type)` 索引 |
| `schema_model.ngql` | 同上，边上多 `item_type`，索引 `(item_type(16), ts)` |
| `data_stock.ngql` / `data_model.ngql` | 同一随机种子的点边。`rank` 固定 0，时间在属性 `ts` 里。`item_type` 只在 model 边上 |
| `queries.ngql` | 下面四条，外加 `PROFILE` |

四条查询：

1. **Q1** 原版计划：`LOOKUP item` 管道 `GO 1 STEP ... REVERSELY WHERE buy.ts > t YIELD DISTINCT buy._dst`。flag 关。
2. **Q2** 同一句，graphd 打开 `--enable_dst_only_edge_filter=true`（storaged 必须是补丁版）。
3. **Q3** 建模：`LOOKUP ON buy WHERE buy.item_type == "beauty" AND buy.ts > t YIELD src(edge)`。不依赖补丁。
4. **Q4** 销售额：Q1 的 YIELD 改成 `buy._dst, buy.amount`，再 `GROUP BY` / `ORDER BY sales DESC` / `LIMIT 100`。flag 开或关计划相同。

`t` 由生成器按 `--now` 和 90 天写进 `queries.ngql`，避免各 storaged 各算一遍 `now()`。对比 Q1 与 Q2 时用这个字面量。

`run_bench.sh` 做的事：

- 导入 schema 和 data（`NEBULA_SKIP_LOAD=1` 可跳过）。
- 每条查询先跑 3 次丢掉，再跑 `ROUNDS`（默认 20）次，用 console 的耗时打印算单线程的近似 P50/P99。这不是 10–200 并发。
- 并发段调用 `concurrent.py`。它只有在 `nebula3-python` 能 import 时才开 N 个会话；import 失败就写「并发未实测」，退出码仍由顺序段决定。
- 每个查询保存一份 `PROFILE` 到 `out/profile/`。看 `GetNeighbors` 或 `GetDstBySrc` 的 resp 行数，以及 total。
- 正确性：Q1 与 Q2 的用户集合必须一致（排序后 diff）。Q3 的用户集合应与 Q1 相同，因为 model 边上的 `item_type` 是从商品 type 抄的。不一致就非 0 退出。

本次执行结果：没有 console，脚本没有在本环境运行。数字表空着。

| 查询 | 并发 | 原版 P50 | 原版 P99 | 补丁 P50 | 补丁 P99 | 建模 P50 | 建模 P99 |
|------|------|----------|----------|----------|----------|----------|----------|
| Q1/Q2/Q3 用户去重 | 10–200 | 未实测 | 未实测 | 未实测 | 未实测 | 未实测 | 未实测 |
| Q4 销售额 Top 100 | 10–200 | 未实测 | 未实测 | 与原版同一计划 | 与原版同一计划 | 未实测 | 未实测 |

相对 40% 和 35 ms：没有测量，不能报下降比例。

---

## 4. 多节点复现

至少 3 个 storaged 进程、不同的 `--local_ip` 和端口，1 个 metad，1 个 graphd。space：

```ngql
CREATE SPACE beauty_buy(partition_num=30, replica_factor=1, vid_type=INT64);
```

`partition_num` 要大于 storaged 个数，商品 VID 才会摊到不同 host。`vid_type=INT64` 时 part 是 8 字节 VID 按无符号整数取模，见 [06](06-key-encoding.md)。不要用 replica 把每条边复制到所有节点，否则每个 host 都持有全量，看不出扇出。

步骤：

1. 在**未打补丁**的二进制上建 `schema_stock`，导入 `data_stock.ngql`，`REBUILD TAG INDEX` 之后等 job SUCCEEDED。
2. graphd `--enable_optimizer=true`，**不要**开 `--enable_dst_only_edge_filter`。
3. 用 `concurrent.py` 对 Q1、Q4 打 10、50、100、200 并发，每档预热 3 轮，记录 P50/P99。同时留一份 `PROFILE`，确认算子是 `ExpandAll` 或 `GetNeighbors`，resp 行数接近命中边数而不是用户数。
4. 换**已打补丁**的 graphd 和**全部** storaged。只换 graphd 就打开 flag 会得到未过滤的 dst（旧 storaged 不认识字段 5）。
5. 打开 `--enable_dst_only_edge_filter=true`，重跑 Q1（即 Q2）和 Q4。Q2 的 PROFILE 应出现 `Expand` + `getDstBySrc`，resp 行数接近该 host 上的用户数。Q4 仍应是 `GetNeighbors`。Q1 与 Q2 的结果集合做 diff。
6. 另建 space 导入 `schema_model` / `data_model`，`REBUILD EDGE INDEX`，跑 Q3。这条不需要补丁。
7. 对比时把磁盘缓存清掉或每档之前重启 storaged，否则后跑的那一档会吃到页缓存。

单机上若只能起多个 storaged 进程，在报告里写明 RPC 走 loopback，P99 不能和 135–345 ms 横比。可以横比的是 PROFILE 里的 resp 行数，以及同一台机器上 Q1 / Q2 / Q3 的相对差。
