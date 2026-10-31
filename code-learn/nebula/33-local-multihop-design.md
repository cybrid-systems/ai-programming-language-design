# 33-local-multihop-design — 子图亲和前提下的 LocalMultiHop 详细设计

> 基线源码：<https://github.com/vesoft-inc/nebula>，tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`
> 性质：设计稿，不是 3.8 已实现的功能
> 前提：分区器已经做了社区/子图划分，meta 能提供“partition group / 亲和性”元数据
> 分析日期：2026-10-31

---

## 0. 范围与前提

Nebula 3.8 默认按 VID 哈希分区，没有社区亲和；本文不假设现有集群直接具备亲和性，而是回答：

**如果已经有一个社区感知的分区器，并且 storaged 能判断“邻居是否在本 partition group”，多跳执行应该怎么设计。**

设计目标是：

- 把“本地能连续扩的 hop”在 storaged 内一次做完；
- 遇到远程邻居就停下，把 `remote_frontier` 交回 graphd；
- graphd 继续用现有单跳路径处理远程部分；
- Expand（只要终点）和 Traverse（要路径）都能接；
- 默认关闭，失败/不满足亲和时回退，不影响现有语义。

非目标：

- 不修改 Raft/存储格式；
- 不要求 storaged 保存全局 visited；
- 不把完整 `Path` 对象放进 storaged；
- 不在第一阶段做 Traverse 的路径前缀。

---

## 1. 术语

| 术语 | 含义 |
|------|------|
| PartitionGroup | 同一社区/子图落在同一组 partition，通常由同一 storaged 持有 leader |
| local neighbor | dst 的 partition leader 在当前 storaged 的 partition group 内 |
| affinity | 某个 frontier 的邻居中 local 的比例估计 |
| frontier | 当前这一层待扩展的 VID 集合 |
| remote_frontier | LocalMultiHop 因跨节点而停下、交还 graphd 的 VID 集合 |
| steps_done | storaged 内实际连续扩展的跳数 |
| path prefix | 一段连续本地路径的紧凑表示，不是完整 `Path` |

“local”是相对 **partition leader** 的：请求会发给 leader；leader 不在本 storaged 时，本地扩展无从谈起。leader 迁移后亲和性也会变化。

---

## 2. 总体架构

```
graphd
  ExpandExecutor / TraverseExecutor
        │
        │  1. shouldLocalMultiHop(affinity, frontier, steps, budget)
        ▼
  StorageClient ───────────────► storaged (partition group leader)
        │                               │
        │  2. getMultiHop(req)          │  MultiHopProcessor
        │                               │   local BFS, stop at remote
        │  3. resp {rows, remote_frontier, steps_done, truncated}
        ▼                               │
  merge local rows                      │
  frontier = remote_frontier            │
  fallback getNeighbors/getDstBySrc ────┘
```

新增两个组件：

1. **storaged：`MultiHopProcessor`**：在本地 partition group 内做有界 BFS，返回本地行 + 远程边界；
2. **graphd：`LocalMultiHopPlanner`（逻辑模块）**：决定何时合并、如何合并、何时回退。

现有 `ExpandExecutor` / `TraverseExecutor` 不改语义，只在循环里插入分支。

---

## 3. 亲和性判定

### 3.1 元数据

分区器在 meta 里记录：

- `partition_group_id`：社区/子图组；
- `community_id`：点所属社区（可选）；
- `local_ratio_estimate`：该 partition group 的 N 跳本地比例估计（可选）；
- `group_leader`：group 内各 partition 的 leader。

graphd 不需要知道每个邻居的精确位置，只需要一个**估计值**来决定是否值得合并。

### 3.2 判定函数

```text
shouldLocalMultiHop(affinity, remainingSteps, frontierSize, flags):
  if !flags.enable_local_multihop: return false
  if remainingSteps <= 1: return false
  if frontierSize > flags.max_frontier: return false
  if affinity < flags.affinity_threshold: return false
  if remainingSteps > flags.max_steps: return false
  return true
```

默认值建议：

- `affinity_threshold = 0.6`
- `max_steps = 3`
- `max_frontier = 10000`
- `row_budget = 1,000,000`
- `path_budget = 100,000`（仅第二阶段）

### 3.3 affinity 从哪来

按成本从低到高：

1. **静态元数据**（首选）：分区器在导入/重平衡时算好每个 group 的局部率；
2. **运行时 EWMA**：同一查询前几跳的实际 local 比例，按 `alpha=0.3` 平滑；
3. **采样探测**（最后手段）：对 frontier 抽样 1%，发一次 `getDstBySrc`，看 dst 的 partition 分布。采样本身是一次 RPC，短查询不要用。

没有元数据时默认 `affinity=0`，直接走现有单跳。

---

## 4. 协议设计

在 `storage.thrift` 增加（字段编号仅为示意）：

```thrift
struct MultiHopRequest {
  1: i32 space_id;
  2: list<i32> part_ids;
  3: list<binary> start_vids;
  4: i32 max_steps;
  5: list<EdgeType> edge_types;
  6: EdgeDirection direction;
  7: optional binary filter;          // 编码后的表达式
  8: optional list<i64> step_limits;  // 每步 limit，和 Expand 的 stepLimits 对齐
  9: optional i64 sample;
  10: bool need_path;
  11: bool local_only = true;
  12: i32 frontier_budget;
  13: i32 row_budget;
  14: optional binary visited_bloom;   // graphd 已知访问集的可选提示
  15: optional i64 request_id;        // 幂等/重试
}

struct PathPrefix {
  1: i32 start_index;                 // 对应 start_vids 的下标
  2: list<binary> vids;
  3: list<Edge> edges;
}

struct MultiHopResponse {
  1: ErrorCode code;
  2: list<DataSet> rows;              // dst 行或 path prefix 行
  3: list<binary> remote_frontier;
  4: i32 steps_done;
  5: bool truncated;
  6: optional list<PathPrefix> path_prefixes;
  7: optional i32 leader_part;
  8: optional HostAddr leader;
}
```

关键语义：

- `local_only=true`：只扩本地，遇到远程 dst 就放入 `remote_frontier`；
- `truncated=true`：预算耗尽，剩余 frontier 也放 `remote_frontier`；
- `code` 只表示真实错误（leader 变更、超时、WAL/读取失败）；**“本地扩不动”不是错误**；
- 不要复用 `StorageAccessExecutor::handleCompleteness` 的“部分成功”语义来表示 local stop，否则 `accept_partial_success=false` 会让查询失败。

---

## 5. storaged：MultiHopProcessor

### 5.1 输入与前置检查

- 校验 space/part、edge type、direction、vid 类型；
- 只处理本 storaged 持有 leader 的 partition；
- 如果请求的 part 不是本地 leader，返回 `E_LEADER_CHANGED + leader`；
- 加载 `visited_bloom`（可选），初始化本地 visited 集合。

### 5.2 本地 BFS 伪代码

```text
frontier = start_vids
visited = local_visited(start_vids)
rows = []
prefixes = []
steps_done = 0

for step in 1..max_steps:
  if frontier empty: break
  next = []
  for vid in frontier:
    if !isLocalLeaderPartition(vid):
      remote_frontier.add(vid)
      continue
    for edge in scanLocalEdges(vid, edge_types, direction):
      dst = edge.dst
      if !isLocalLeaderPartition(dst):
        remote_frontier.add(dst)
        continue
      if filter && !evalFilter(edge, dst): continue
      if visited.contains(dst): continue
      visited.add(dst)
      next.add(dst)
      rows.add({src: vid, dst: dst, edge: edge})
      if need_path: prefixes.add(extendPrefix(vid, edge))
      if rows.size + prefixes.size > row_budget:
        truncated = true
        remote_frontier.addAll(next); break
  frontier = dedup(next)
  steps_done = step
  if truncated: break
```

要点：

- 每一步只扩**本地 leader** 的 partition；跨 group 立即停；
- `visited` 是本地视角，graphd 还会做全局去重；
- `need_path` 时只记录**前缀**，不构造完整 `Path`；
- 每一步都检查 `row_budget` / `frontier_budget`，超了就把剩余 frontier 交回；
- 超级节点：单 VID 出度超过 `max_out_degree` 时直接放入 `remote_frontier`，强制 graphd 处理。

### 5.3 返回

```text
MultiHopResponse {
  code: SUCCEEDED,
  rows: local rows,
  remote_frontier: ...,
  steps_done: ...,
  truncated: ...
}
```

如果 `need_path`，`path_prefixes` 与 `rows` 按 `start_index` 对齐；graphd 只做拼接，不重新扫边。

---

## 6. graphd：接入 Expand / Traverse

### 6.1 Expand（第一阶段，不带路径）

`ExpandExecutor::execute`（41 行）现在：

```cpp
if (joinInput || !stepLimits_.empty()) return getNeighbors();
return GetDstBySrc();
```

新增分支只放在 `GetDstBySrc` 这一支：

```text
while currentStep < maxSteps && !frontier.empty:
  if shouldLocalMultiHop(...):
    resp = storageClient->multiHop(frontier, remaining, edgeTypes, ...)
    merge(resp.rows)
    frontier = resp.remote_frontier
    currentStep += resp.steps_done
    if resp.truncated: fallbackRemaining()
  else:
    resp = storageClient->getDstBySrc(frontier, edgeTypes)
    ...
```

`joinInput`、`stepLimits`、需要边属性的路径继续走现有 `getNeighbors`，不改。

### 6.2 Traverse（第二阶段，带路径前缀）

`TraverseExecutor::getNeighbors`（79 行）现在按 `finalStep` 下推 filter/limit/orderBy；路径由 `buildPathMultiJobs`（430 行）在 graphd 拼。

LocalMultiHop 只应替换**中间跳的本地扩展**，不改变：

- `finalStep` 的过滤/排序/limit；
- `selectFilter` 的 firstStepFilter/tagFilter 语义；
- `dst2PathsMap_` 的全局路径拼接。

graphd 收到 `path_prefixes` 后，把前缀并入 `dst2PathsMap_`，再按现有 `buildPathMultiJobs` 生成完整 Path。跨节点的最后一跳仍然走 `getNeighbors`。

### 6.3 结果合并

- 本地 rows 与远程 rows 统一按 `(vid, step, path_id)` 去重；
- `remote_frontier` 去重、限长；
- `limit` / `step_limits` / `sample` 的语义必须和单跳路径一致；
- 查询被 kill 时立即停止，不再发新的 multiHop；
- 内存水位检查沿用 `MemoryCheckGuard`，budget 超限回退。

---

## 7. 路径前缀设计

不返回完整 `Path`，只返回连续本地段：

```text
PathPrefix {
  start_index,
  vids: [v0, v1, v2],
  edges: [e0, e1]
}
```

约束：

- `vids.size() == edges.size() + 1`；
- 前缀长度 ≤ `max_path_len`（默认 8）；
- 每个 start 最多返回 `max_paths_per_start` 条（默认 1024）；
- 超过预算时 `truncated=true`，剩余 frontier 回 graphd；
- graphd 拼接时检查环和重复边；带环路径在 `visited` 阶段就被丢弃。

这样 storaged 不需要 `Path` 类型，也不需要全局 visited；路径的最终语义仍由 graphd 的 `TraverseExecutor` 负责。

---

## 8. 正确性

### 8.1 不变量

1. **路径长度**：返回的每条本地行对应一条长度 ≤ `steps_done` 的路径；
2. **本地/远程互斥**：`remote_frontier` 与 local rows 的 dst 不重叠；
3. **过滤顺序**：中间跳只应用 `step_limits` / `sample`；最终过滤、排序、limit 只在 finalStep 应用（和现有 Traverse 一致）；
4. **去重**：graphd 的全局 visited 是最终裁决；storaged 的 visited 只是本地剪枝；
5. **部分结果**：local stop 是正常结果，不是 partial failure；只有真实 storage 错误才走 `handleCompleteness`；
6. **幂等**：`request_id` 相同且参数相同的重试返回同一结果或明确 `E_RETRY`。

### 8.2 与单跳路径的差分测试

同一查询分别跑：

- baseline：现有 `getNeighbors` / `getDstBySrc` 循环；
- local-multihop：新路径；

比较：

- 去重后的 VID 集合；
- 路径集合（如果 need_path）；
- 行数、limit、sample 结果；
- 错误码和 partial success 行为。

任何差异都视为 bug。

---

## 9. 失败与降级

| 场景 | 行为 |
|------|------|
| 旧 storaged 不支持 multiHop | 返回 `E_MULTIHOP_UNSUPPORTED`，graphd 回退单跳 |
| leader 迁移 | 返回 `E_LEADER_CHANGED + leader`，graphd 更新路由后重试一次 |
| 预算耗尽 | `truncated=true + remote_frontier`，graphd 继续单跳 |
| 超时 | 回退单跳；不要标记 partial success |
| 真实 storage 错误 | 按 `handleCompleteness` 处理 |
| 查询 kill | 立即返回，不再扩 |

Feature flag：

```text
enable_local_multihop=false
local_multihop_max_steps=3
local_multihop_affinity_threshold=0.6
local_multihop_max_frontier=10000
local_multihop_row_budget=1000000
local_multihop_path_budget=100000
```

默认关闭，按 space 或查询 hint 开启，便于灰度。

---

## 10. 观测

新增统计：

- `local_multihop_rpc_total`
- `local_multihop_steps_total`
- `local_multihop_rows_total`
- `remote_frontier_size`（直方图）
- `fallback_total{reason}`
- `storage_cpu_us` / `storage_rows`（按 group）

PROFILE 里保留：

- `total_rpc_time`
- `expandTime`
- `step[i].storage`
- `local_multihop.steps_done`
- `local_multihop.truncated`

没有这些数据，不要开默认；先证明 RPC 轮次是瓶颈。

---

## 11. 测试计划

1. **单元**：MultiHopProcessor 的 BFS、边界、预算、visited、supernode；
2. **差分**：随机图 + 社区图，Expand/Traverse 对 baseline 逐行比较；
3. **正确性矩阵**：环、重复边、limit/sample/stepLimits、finalStep filter、orderBy、dedup；
4. **故障**：leader 迁移、storaged 挂掉、超时、旧版本、部分成功；
5. **路径**：前缀拼接、跨本地/远程、环、最大长度、path budget；
6. **性能**：合成高亲和图，测 RPC 次数、P50/P95、storage CPU、rows、frontier；
7. **回归**：现有 01–32 里的查询/压测场景。

---

## 12. 分阶段落地

- **P0（测量）**：只加统计，确认 `Expand`/`Traverse` 的 RPC 占比；
- **P1（Expand-only）**：无路径 LocalMultiHop，flag 控制，旧 storaged 回退；
- **P2（Traverse 路径前缀）**：紧凑 PathPrefix，先限 `max_steps<=3`；
- **P3（自适应）**：EWMA/元数据驱动阈值，storage 负载高时自动关闭。

---

## 13. 风险与开放问题

- **分区器是否真的产生亲和**：没有社区划分，这个设计没有收益；哈希分区下本地率 ≈ 1/partition_num。
- **storage CPU/内存**：多跳把计算搬到 storaged；共享集群里可能伤害其他查询。
- **超级节点**：必须设出度/行数/路径上限，否则单请求打爆 storaged。
- **路径语义**：PathPrefix 与 graphd 的 `dst2PathsMap_` 合并需要严格测试。
- **协议兼容**：新 RPC/结构体需要版本协商和旧节点回退。
- **部分结果 UX**：local stop + truncated 对用户意味着“结果可能不完整”，需要明确提示或自动补远程。

---

## 14. 和现有代码的接入点

- `ExpandExecutor::execute`（41 行）：插入 LocalMultiHop 分支；`GetDstBySrc`（69 行）保留为回退。
- `TraverseExecutor::getNeighbors`（79 行）：只在中间跳替换；`buildPathMultiJobs`（430 行）继续负责完整 Path。
- `StorageAccessExecutor::handleCompleteness`（41 行）：只用于真实 storage 失败，不用于 local stop。
- 新增 `MultiHopProcessor`：放在 storaged，复用现有本地邻居扫描；不要改 `GetNeighborsProcessor` 的单跳语义。
- `StorageClient`：新增 `multiHop` 方法，按 host/partition 批量发送。

---

## 15. 一句话结论

在“子图划分 + 亲和性”成立的前提下，**把本地连续的 hop 放进 storaged 的 MultiHopProcessor，远程边界以 remote_frontier 交回 graphd，路径只返回紧凑前缀**，是可行的；但必须先做 Expand-only、先测量 RPC 占比，并且 default-off + 回退。没有亲和性分区，这个设计不应该开启。
