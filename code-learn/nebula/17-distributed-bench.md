# 17 — 多进程集群上的部分聚合

> 单机 50 万边的重测在 [16](16-partial-agg-impl.md)。框架在 [15](15-general-pushdown.md)。
> 脚本：[`bench/scenario2/start_dist.sh`](bench/scenario2/start_dist.sh)、[`dist_measure.py`](bench/scenario2/dist_measure.py)、[`l2_delay.py`](bench/scenario2/l2_delay.py)。
> 原始 JSON 和 ping 在 [`bench/scenario2/results/dist/`](bench/scenario2/results/dist/)。
> 日期：2026-10-26。机器：4 vCPU，`Linux 6.12.94+`，和 [12](12-scenario2-bench.md) 同一台 VM。

这不是三台物理机。CPU、磁盘、页缓存是一份。跨「主机」的延迟是后加的。下面每张表的 RTT 都是当时 `ping` 打出来的，不是配置里希望达到的数。

---

## 1. 拓扑

`start_dist.sh up`：3 个 metad（`10.88.0.11–13:9559`）、3 个 storaged（`10.88.0.21–23:9779`）、1 个 graphd（`10.88.0.31:9669`）。每个进程一个 network namespace，veth 接到桥 `br-nebula`（`10.88.0.1/24`）。客户端跑在宿主机上，连 `10.88.0.31:9669`。

第一次 `ping` 从 namespace 到 namespace 是 100% 丢包，宿主机到每个 namespace 是通的。原因是 `net.bridge.bridge-nf-call-iptables=1`：桥转发的帧走 iptables FORWARD，namespace 之间被丢掉，宿主机走 INPUT 不受影响。把它和 ip6、arp 的同类开关设成 0 之后，namespace 之间通了。`start_dist.sh` 的 `setup_net` 里现在会设这三项。

数据集不是 50 万边那份。三个空间用同一份生成参数：800 用户、200 商品、20000 条边、seed 2。命中窗口的边 1566，用户 686，`sum(amount)=397318.0`。空间：

| 空间 | partition_num | replica_factor |
|------|---------------|----------------|
| `beauty_p9_rf1` | 9 | 1 |
| `beauty_p9_rf3` | 9 | 3 |
| `beauty_p3_rf1` | 3 | 1 |

导入后 `REBUILD TAG INDEX`。`beauty_p9_rf3` 第一次 job 4 报 `E_INDEX_NOT_FOUND`，脚本重试，job 5 `FINISHED`（当时 leader 只在两台 storaged 上，所以子任务是 2 个）。`beauty_p3_rf1` 的 job 7 三台都 `SUCCEEDED`。

校验：q_users 的集合、q_sales 的 686 个和、q_count 的合计 1566、q_by_amount 的合计 1566。下面每条 `ok: true` 的结果，这四项（或该查询对应的那项）都对上了生成器。

---

## 2. 延迟怎么加的

`/proc/config.gz` 里是 `# CONFIG_NET_SCH_NETEM is not set`。`tc qdisc add ... netem` 返回 `Specified qdisc kind is unknown`。`sch_netem` 模块也不在这块盘上，`modprobe` 不存在。TBF、prio、fq、cake 同样没有编进内核。所以 **0.2 / 1 / 5 ms 不是 `tc netem` 打出来的**。

替代是 [`l2_delay.py`](bench/scenario2/l2_delay.py)：namespace 的 veth 从桥上摘下来，由一个用户态转发进程在宿主机侧的 veth 之间拷贝以太网帧。namespace 到 namespace 的帧等待 `--delay-ms`（单向）。到宿主机的帧不等待，所以客户端到 graphd 的 RTT 不代表 storaged 的 RTT。veth 的 TX checksum / GSO 关掉了；不关的话 ICMP 通、TCP 超时，因为 AF_PACKET 拷走的是未完成的校验和。

`start_dist.sh usdelay <ms>` 做的就是这件事。这次测的时候脚本里还没有这个子命令，命令是手敲的；子命令是事后按当时的步骤收进去的，没有用它把下面的表重跑一遍。

ping 是 `ns-graph1 → 10.88.0.21`，20 个包，间隔 0.05 s。文件在 `results/dist/ping_*.txt`。

| 标签 | 单向设置 | ping min / avg / max (ms) | 丢包 |
|------|----------|----------------------------|------|
| 内核桥，`ping_rtt0.txt` | 无 | 0.021 / 0.025 / 0.047 | 0/20 |
| 转发器，`ping_fwd0.txt` | 0 | 0.200 / 0.716 / 1.011 | 0/20 |
| `ping_rtt0.2.txt` | 0.1 | 0.459 / 0.673 / 0.878 | 0/20 |
| `ping_rtt1.txt` | 0.5 | 1.262 / 1.447 / 1.626 | 0/20 |
| `ping_rtt5.txt` | 2.5 | 5.285 / 5.388 / 5.497 | 0/20 |

0.1 ms 单向没有压过转发器自己的抖动：avg 0.673 和 delay 0 的 avg 0.716 叠在一起。**0.2 ms 这个目标没有达到。** 下面仍列出那一档的查询，用来说明它和 delay 0 分不开。1 ms 目标的实测 avg 是 1.447 ms。5 ms 目标的实测 avg 是 5.388 ms。

同一档里宿主机 → graphd 的 ping（`ping_rtt5.txt`）avg 0.935 ms。查询时延里的 RTT 主要在 graphd → storaged，不在客户端 → graphd。

storaged 之间的 ping（`ping_rtt5.txt` 里 stor1 → stor2）avg 5.446 ms，和 graph → stor 同级。Raft 复制会走这条路；读只打 leader，不打 follower。

---

## 3. 扇出和合并

`beauty_p9_rf1`，内核桥，部分聚合开。PROFILE 的 `step1 resp`：

| host | vertices |
|------|----------|
| 10.88.0.21:9779 | 366 |
| 10.88.0.22:9779 | 411 |
| 10.88.0.23:9779 | 344 |
| 合计 | 1121 |

最终用户 686。1121 > 686：同一个用户的购买落在多个 host 上，每个 host 交一行部分和（或一个 dst VID），graphd 再加总或去重。三台的部分和加完是 397318.0，和生成器一致。没有把某一台的局部 Top 当成全局 Top：计划是 `TopN → Aggregate → Expand`，TopN 在合并之后。

`SHOW PARTS`（RF=1）每个 part 一个副本，9 个 part 每台 3 个 leader。RPC 是 3 次，不是 9 次，也不是 200 个商品一次一个。

`beauty_p3_rf1` 的 PROFILE 主机行数也是 366 / 411 / 344。`SHOW PARTS` 只有 3 行（每台 1 个 part），和 9 part 不是同一份分区表。每台 vertices 碰巧一样，我没有再去对 VID 的 hash。校验和两边都是 397318.0。

`beauty_p9_rf3` 在 `BALANCE LEADER` 之前测的。当时 leader 是 `.23` 上 7 个 part、`.22` 上 2 个、`.21` 上 0 个。PROFILE 只有两台：

| host | vertices |
|------|----------|
| 10.88.0.23:9779 | 627 |
| 10.88.0.22:9779 | 226 |
| 合计 | 853 |

853 仍大于 686，和仍是 397318.0。三副本没有把边加三次：请求打到 leader，不打 follower。扇出等于「有 leader 的 host 数」，不是 replica_factor。

---

## 4. 时延

server P50 / QPS 来自 `ResultSet.latency()`。c=1 是 5 个样本（warmup 1 丢掉），c=10 是 10 个 worker 各 5 个样本。错误数都是 0。单位毫秒。

### 4.1 内核桥，RF=1，9 part，ping avg 0.025 ms

[`p9_rf1_rtt0.json`](bench/scenario2/results/dist/p9_rf1_rtt0.json) 对 [`p9_rf1_rtt0_off.json`](bench/scenario2/results/dist/p9_rf1_rtt0_off.json)。flag 关时 q_sales / q_count 的计划回到 `ExpandAll`，和仍是 397318.0 / 1566。

| 查询 | 部分聚合 | c=1 P50 | c=1 QPS | c=10 P50 | c=10 QPS |
|------|----------|---------|---------|----------|----------|
| q_sales 开 | 是 | 2.672 | 282.55 | 10.966 | 647.50 |
| q_sales 关 | 否 | 3.517 | 226.56 | 9.951 | 576.10 |
| q_count 开 | 是 | 2.621 | 141.18 | 3.152 | 208.15 |
| q_count 关 | 否 | 3.545 | 125.42 | 3.815 | 208.79 |
| q_users 开 | 否（dst-only） | 1.951 | 187.42 | 2.099 | 298.48 |
| q_by_amount 开 | 否 | 3.459 | 133.63 | 3.936 | 285.38 |

1566 条边太少，部分聚合在 c=1 上只少了大约 0.8 ms。c=10 的 q_sales P50 开着是 10.966、关着是 9.951，这一档不能记成收益。50 万边的差距在 [16](16-partial-agg-impl.md)（16.4 ms 对 46 ms），不要拿这 2.7 ms 去比那一列。

### 4.2 转发器，RF=1，q_sales c=1

| ping avg (ms) | 文件 | server P50 | QPS |
|---------------|------|------------|-----|
| 0.025（内核桥，上一节） | `p9_rf1_rtt0.json` | 2.672 | 282.55 |
| 0.716 | `p9_rf1_fwd0.json` | 2.854 | 266.29 |
| 0.673（目标 0.2，没分开） | `p9_rf1_rtt0.2.json` | 3.353 | 233.81 |
| 1.447 | `p9_rf1_rtt1.json` | 7.916 | 115.55 |
| 5.388 | `p9_rf1_rtt5.json` | 14.737 | 56.72 |

从转发器 delay 0 的 2.854 ms 到 ping avg 5.388 的 14.737 ms，多了约 11.9 ms。一条语句有两次跨 host 的 RPC（`TagIndexPrefixScan` 和 `Expand`），并行打 3 台，时延接近 2 个 RTT 而不是 6 个。5.388 × 2 = 10.8，和 11.9 的差在转发器抖动和 storage 自己的扫描里。

同一档 ping avg 5.388，q_by_amount（不下推，回边）c=1 P50 是 14.73，和 q_sales 的 14.737 一样。RTT 占满了，1566 行和 1121 行的字节差看不出来。

q_users 在这档是 13.972 ms，c=10 QPS 237.75。q_count 是 13.786 ms。

### 4.3 RF=3 和 3 part

转发器 delay 0（ping 与 `ping_fwd0.txt` 同一进程，avg 0.716 ms）：

| 空间 | q_sales c=1 P50 | QPS | q_users c=1 P50 |
|------|-----------------|-----|-----------------|
| p9 RF=1 | 2.854 | 266.29 | 2.311 |
| p9 RF=3 | 3.051 | 253.18 | 2.382 |
| p3 RF=1 | 2.753 | 271.22 | 2.109 |

RF=3 的读没有按副本数变慢，也没有把和乘 3。ping avg 5.408 ms 时（`ping_rf3_rtt5.txt`，10 个包）q_sales c=1 P50 14.308，和 RF=1 在 5.388 ms 下的 14.737 同一档。

---

## 5. Leader 和杀一台 storaged

`BALANCE LEADER` 返回 job 8。之前 `beauty_p9_rf3` 的 leader 是 0 / 2 / 7（`.21` / `.22` / `.23`）。job 结束后 `SHOW HOSTS` 三台各 7 个 leader，其中 rf3 各 3 个。`SHOW PARTS`：part 1–3 在 `.21`，4–6 在 `.22`，7–9 在 `.23`。每个 part 的 peers 仍是三台。记录在 [`leaders_after_balance.json`](bench/scenario2/results/dist/leaders_after_balance.json)。`SHOW JOB 8` 在没 `USE` 空间时返回 `Space was not chosen`，完成与否是靠 `SHOW PARTS` 看的，不是靠那条 job 查询。

然后 `kill -9` stor3（当时 pid 39964，`10.88.0.23`），时间 10:48:33 UTC。探针每 3 秒打一次全量 q_sales。记录 [`kill_stor3.json`](bench/scenario2/results/dist/kill_stor3.json)。

| 空间 | 现象 |
|------|------|
| `beauty_p9_rf1` | 从 t=0.006 s 到 t=21 s 的 8 次都失败。错误文本是 `Storage Error: RPC failure, probably timeout.` 单次调用很快返回（间隔是探针自己的 sleep）。RF=1 上 leader 在 `.23` 的 part 没有副本，整句失败，没有返回缺了一部分用户的和 |
| `beauty_p9_rf3` | t=24 s 到 t=39 s 的 6 次同样失败。t=42.102 s 成功：686 行，server 6192 µs，`sum_got=397318.0`，`check_ok=true` |

成功那一次的 `SHOW PARTS`：原先在 `.23` 的 rf3 part 7 改到 `.22`，part 8 和 9 改到 `.21`。选举在杀进程后大约 40 秒完成。同一时刻 `SHOW HOSTS` 仍把 `.23` 标成 `ONLINE`（leader 数还含 rf1 的 3 个 part，那些 part 无处可迁）。进程日志里，新 storaged 要到 10:49:15 才起来，所以 10:49:15 之前的 ONLINE 是 meta 还没把心跳判死，不是进程还活着。

`restart-storage 3` 之后两个空间的全量 q_sales 都是 686 行、和 397318.0（[`after_restart_stor3.json`](bench/scenario2/results/dist/after_restart_stor3.json)）。RF=1 的数据还在那台机器的磁盘上，进程起来就继续当 leader，没有从别的副本追。

没有做的：查询进行中杀掉 leader、网络分区而不是杀进程、`accept_partial_success=true` 下的残缺和。默认 false 时，看到的是整句失败，不是少加了一台的销售额。

---

## 6. 和真多机的差别

这台 VM 上能信的：

- 三个 storaged 的 RPC 走不同 IP，PROFILE 能分开 host 和 `vertices`
- 同一用户跨 host 的部分和由 graphd 合并，和与生成器一致
- RF=3 只扫 leader，不把副本加进和
- leader 可以 `BALANCE LEADER` 搬动；唯一副本被杀时查询失败，三副本在选举完成后和不变
- 把 graph→storage 的 ping 从 0.025 ms 加到 5.4 ms，q_sales 的 c=1 P50 从 2.7 ms 左右加到 14.7 ms

不能当成机房结果的：

- 磁盘和页缓存是一份。三台 storaged 的扫描会抢同一块盘、同一组 CPU。真机上每台有自己的盘，扫描可以并行得更开，RTT 却更稳
- 转发器是一个 Python 进程，delay 0 时 ping avg 已经 0.716 ms，抖动到 1 ms。`tc netem` 在编进内核的机器上底噪低得多。0.2 ms 这次没有测到
- 客户端到 graphd 几乎不延迟。真机上这段也有 RTT
- 没有第二台 graphd，没有跨机架的 meta
- 数据是 2 万条边，不是 50 万。部分聚合少传的字节在 5 ms RTT 下被两次 RPC 盖住

---

## 7. 在真多机上怎么复现

内核要有 `CONFIG_NET_SCH_NETEM`。下面的延迟打在每台机器的业务网卡上，双向都打时 RTT 约是 2 倍，用 `ping` 核对后再跑查询。

1. 三台 storaged、三台 metad、一台 graphd，`--local_ip` 用各自的地址，`--meta_server_addrs` 写三台 meta。不要用同一块数据盘的三个进程代替。
2. `ADD HOSTS` 三台 storage。建两个空间：`partition_num=9, replica_factor=1` 和 `replica_factor=3`，`vid_type=INT64`。用 [`gen_data.py`](bench/scenario2/gen_data.py) 的同一组参数（800/200/20000/seed 2，或换成 50 万边那组）导入，`REBUILD TAG INDEX` 到 `FINISHED`。
3. graphd 打开 `--enable_optimizer`、`--enable_dst_only_edge_filter`、`--enable_partial_edge_agg`。storaged 必须是同一份补丁。先升 storaged，再升 graphd，最后开聚合开关。只升 graphd 时，`partial_agg` 不置位，graphd 会退回 `GetNeighbors`，和仍对，时延不该拿来比。
4. 每台网卡：`tc qdisc add dev <if> root netem delay 0.1ms`（期望 RTT 约 0.2 ms）、`0.5ms`、`2.5ms`。每档先 `ping` 20 个包，把 min/avg/max 写进报告，再跑 `dist_measure.py measure`。
5. `SHOW PARTS` 看 leader。`BALANCE LEADER` 之后再看一次。`kill -9` 一台 leader，RF=1 应整句失败，RF=3 在选举后和不变。把 `SHOW HOSTS` 的 ONLINE/OFFLINE 和进程是否还在对上，心跳过期和 Raft 选举不是同一时刻。
6. 比较 flag 关和开时，只重启 graphd 改 `--enable_partial_edge_agg`，不要同时换数据或延迟。

在这台 VM 上对应的命令是 `start_dist.sh up`，确认 `ping` 通，然后 `usdelay 0` / `usdelay 0.5` / `usdelay 2.5`，再用 `dist_measure.py`。`netem` 子命令会失败，这是内核配置，不是脚本写错 qdisc 名字。
