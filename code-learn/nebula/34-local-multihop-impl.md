# 34 — LocalMultiHop：按 3.8 源码落地的一阶段

> 设计稿是 [33](33-local-multihop-design.md)。压测在 [35](35-local-multihop-bench.md)。自适应层（逐跳本地比例守卫 + EWMA）在 [36](36-adaptive-multihop-design-impl.md)。
> 补丁 [`patches/v3.8.0-local-multihop.patch`](patches/v3.8.0-local-multihop.patch) 打在 `v3.8.0` `fa928930` 上，不依赖 16 的部分聚合补丁。
> 日期：2026-10-31。

33 篇把第一阶段写成 Expand-only：不改 Raft、不在 storaged 造完整 `Path`、默认关闭、旧 storaged 能退回单跳。这一份按那个范围做。和设计稿不一致的地方以 `fa928930` 的源码为准，记在下面。

---

## 1. 3.8 里多跳实际走哪

`GO n STEPS ... YIELD DISTINCT edge._dst` 且没有 WHERE、没有 LIMIT，`GoValidator::isSimpleCase` 为真。`GoPlanner::doSimplePlan` 建一个 `Expand(maxSteps=n)`。`ExpandExecutor::GetDstBySrc` 每跳一次 `StorageClient::getDstBySrc`，只把最后一跳的 dst 交出去，跳内用集合去重。

`GO m TO n STEPS ... YIELD DISTINCT edge._dst` 先用 `Expand` 走到 `m-1`（`m==1` 时 `maxSteps=0`，原样吐出起点），再由 `ExpandAll` 在 `vertexColumns` 和 `edgeColumns` 都为空时走 `GetDstBySrc`，**每一跳的 dst 都放进结果**。`ExpandAllExecutor` 里 `currentStep_` 从 `minSteps` 起、进入函数先 `++`，扫描次数是 `maxSteps - minSteps + 1`。

有 WHERE、要边属性、或 `joinInput` 时走 `getNeighbors`。这一阶段不改那条路径。过滤查询的结果必须和关开关时一样，但 RPC 不会被收成一跳。

---

## 2. 和 33 篇的差别

| 设计稿 | 这次 |
|--------|------|
| 新 RPC `getMultiHop` | 加在现有 `GetDstBySrcRequest` 的可选字段上。旧 storaged 丢掉未知字段，响应里没有 `multihop_applied`，graphd 把那次回复当成一跳接着走。新方法名在旧进程上是一次失败的 RPC，多一次往返 |
| meta 里的 `partition_group_id` | 3.8 的 meta 没有这个字段。`local` 定义成「dst 的 part 由当前 storaged 担任 leader」。`partId = (uint64)vid % parts + 1`，和 `MetaClient::partId` 对 8 字节整型 VID 的算法相同 |
| `affinity` 来自分区器 | 没有元数据时估计值是 `--local_multihop_affinity`，默认 `0`。默认因此不会发多跳，即使 `--enable_local_multihop=true`。压测把估计值设成 `1`，让开关真正走到新路径 |
| `remainingSteps > max_steps` 则整句不做 | 单次 RPC 裁到 `local_multihop_max_steps`（默认 3），剩下的 frontier 继续。`GO 5 STEPS` 不会因为超过 3 就退回全程单跳 |
| 超级点单独丢回 graphd | 扫描仍受 `FLAGS_max_edge_returned_per_vertex` 限制，和单跳同一刀。另做一套出度上限会和基线差行 |
| PathPrefix、Traverse | 33 篇自己标成第二阶段，这次不做 |
| 采样 / EWMA | 没接。估计值就是那个 flag |

`local stop` 不是 `failed_parts`。`handleCompleteness` 只在扫描错误、leader 变更或 RPC 失败时失败整句。预算打满时 `truncated=true`，未展开的本地 frontier 放在 `carry_vids`，graphd 用单跳走完，不再送回多跳，避免来回弹。

---

## 3. 协议

`GetDstBySrcRequest` 增加可选的 `max_steps`、`min_yield_step`、`row_budget`、`frontier_budget`。缺省或 `max_steps<=1` 时处理器走原来的单跳，不置 `multihop_applied`。

`GetDstBySrcResponse` 增加：

- `dsts`：本机上、深度落在 `[min_yield_step, max_steps]` 的 dst
- `remote_vids` / `remote_depth`：leader 不在本机的 dst，以及走到它用了几跳
- `carry_vids`：还要继续展开的本地 frontier（裁剪或预算）
- `steps_done`、`truncated`、`multihop_applied`

storaged 侧 `--storaged_accept_local_multihop` 默认 true。设成 false 时忽略 `max_steps`，行为与旧二进制相同，用来在同一份二进制上测回退。

---

## 4. 谁决定走多跳

判定在 `shouldLocalMultiHop`（`src/common/algorithm/LocalMultiHop.h`），不是一条 OptRule。`GoPlanner` 的形状没变：多步 GO 本来就是执行器里的循环。优化器测试如果去匹配一个不存在的计划节点，测的就不是 3.8。

`local_multihop_test` 里的 `LocalMultiHopDecisionTest` 锁的就是这个判定：flag、affinity 阈值、frontier 上限、`hopsLeft<=1` 拒绝、超过 `max_steps` 仍允许并由 `clipLocalMultiHopSteps` 裁剪。

同一测试里的 BFS 覆盖：三跳只产出终点、空起点、无边、跳内去重、环（第 2 跳回到起点）、跨 part 的 dst 进 remote 且深度为 2、`min_yield=1` 的 M..N、裁剪后的 carry、行预算丢弃半截步、扫描失败不算远程边界。`consumeLocalMultiHop` 覆盖旧服务器的一跳解释、终点上的 remote 要产出、M..N 的中间 remote 既产出又继续、`truncated` 后只走单跳。

同一 VID 在不同深度再次成为远程边界时必须各记一次。只留第一次会丢掉更长的那条路：`GO 3 STEPS` 里 `1→4` 和 `1→2→4` 都要继续扩 `4`，否则终点少一截。这是对照随机图时抓到的，修完后随机图的 2176 个终点和生成器一致。单测 `SameVidAtTwoDepthsIsExpandedTwice` 锁住这个行为。

14 条在 `/tmp/nebula-380/build/bin/test/local_multihop_test` 上全过。

---

## 5. 开关

| flag | 默认 | 作用 |
|------|------|------|
| `--enable_local_multihop` | false | graphd 是否尝试合并 |
| `--local_multihop_affinity` | 0 | 静态估计。0 表示不尝试 |
| `--local_multihop_affinity_threshold` | 0.6 | 估计值的下限 |
| `--local_multihop_max_steps` | 3 | 单次 RPC 的跳数上限 |
| `--local_multihop_max_frontier` | 10000 | 起点过多则不合并 |
| `--local_multihop_row_budget` | 1000000 | 单次 RPC 扫描的边数 |
| `--local_multihop_frontier_budget` | 10000 | 本地 frontier 过大则把剩余交回 |
| `--storaged_accept_local_multihop` | true | false 时假装旧 storaged |

PROFILE 里多跳成功的 RPC 带 `local_multihop[i]=applied=1 steps_done=... remote=... carry=... truncated=...`。没有这个状态就是单跳。
