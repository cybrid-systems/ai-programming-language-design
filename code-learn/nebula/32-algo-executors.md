# 32-algo-executors — ShortestPath / BFS / Multi / AllPaths / Subgraph

> 源码：<https://github.com/vesoft-inc/nebula>，tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`
> 范围：`src/graph/executor/algo/`
> 分析日期：2026-10-31

---

## 0. 概述

算法算子是执行引擎里最“重”的部分：它们不满足于逐行流式处理，而是要在 graphd 侧维护 visited 集合、边表、路径表，甚至做双向 BFS。Nebula 3.8 把最短路、全路径、子图分别实现成独立 executor，并在内部按输入规模选择单线程/批量/并行策略。

---

## 1. ShortestPathExecutor

`execute`（`ShortestPathExecutor.cpp:18`）：

```cpp
if (FLAGS_num_path_thread == 0) FLAGS_num_path_thread = get_nprocs_conf();
HashSet startVids, endVids;
size_t rowSize = checkInput(startVids, endVids);
std::unique_ptr<ShortestPathBase> pathPtr;
if (rowSize <= FLAGS_num_path_thread) {
  pathPtr = std::make_unique<SingleShortestPath>(...);
} else {
  pathPtr = std::make_unique<BatchShortestPath>(...);
}
auto status = pathPtr->execute(startVids, endVids, &result).get();
```

三个要点：

- `checkInput`（37 行）从输入 iterator 取 start/end VID，校验类型；当 `stepRange().min()==0` 且 start==end 时跳过（0 步路径）；
- 以 `startVids.size() * endVids.size()` 作为 rowSize，和 `FLAGS_num_path_thread` 比较：小规模走 `SingleShortestPath`，大规模走 `BatchShortestPath`；
- `pathPtr->execute(...).get()` 在当前 executor 的 future 里阻塞等待内部路径 future。也就是说，这个 executor 本身是“同步等待”的，但外层仍然在 runner 线程里。

---

## 2. BFSShortestPathExecutor

`execute`（`BFSShortestPathExecutor.cpp:12`）是双向 BFS：

```cpp
auto leftFuture = folly::via(runner(), [this]() { return buildPath(false); });
auto rightFuture = folly::via(runner(), [this]() { return buildPath(true); });
return folly::collectAll(futures)
    .via(runner())
    .thenValue([this](...) { return conjunctPath(); })
```

- `buildPath(false/true)`（88 行）分别从左侧/右侧扩展，维护 `leftVisitedVids_` / `rightVisitedVids_` 和 `allLeftEdges_` / `allRightEdges_`；
- 两侧并行跑，`collectAll` 后 `conjunctPath` 找交汇点；
- `step_` 递增，`limit_` 和 `terminateEarlyVar_` 控制提前结束；
- 每个 future 内部都有 `MemoryCheckGuard`，bad_alloc 转 `GraphMemoryExceeded`。

这也是为什么双向 BFS 比单向更省：每一侧只扩展一半深度，visited 集合和边表都更小。

---

## 3. MultiShortestPathExecutor

`execute`（`MultiShortestPathExecutor.cpp:10`）处理“多对多”最短路：

- `init`（92 行）初始化起点/终点集合；
- `buildPath(reverse)`（131 行）分别构建左右路径；
- `doConjunct`（235 行）在交汇点拼路径；
- `setNextStepVid`（392 行）把当前层的结果写到下一层变量。

它和 BFS 版的区别是：BFS 版一次处理一对/一组起终点，Multi 版在内部维护多组 path 状态，减少重复调度。

---

## 4. AllPathsExecutor

`execute`（`AllPathsExecutor.cpp:19`）求所有路径：

- `buildRequestVids`（41 行）准备起点/终点；
- `expand`（181 行）逐层扩展，维护路径表；
- `buildOneWayPath`（439 行）和 `buildHashTable`（607 行）负责把边表拼成完整路径。

全路径的数量可能指数级增长，所以这个 executor 最容易触发内存水位；代码里同样用 `MemoryCheckGuard` 和 bad_alloc 捕获兜底。

---

## 5. SubgraphExecutor

`execute`（`SubgraphExecutor.cpp:15`）处理 `GET SUBGRAPH`：

- 按起点和步数做 BFS/扩展；
- `filterEdges`（101 行）按版本/边过滤；
- 结果是点和边的子图，而不是路径。

---

## 6. 常见误解

1. **“最短路就是单向 BFS”**：BFSShortestPath 是双向 BFS，左右并行。
2. **“所有起点终点都用同一种策略”**：按 `rowSize` 和 `FLAGS_num_path_thread` 选 Single/Batch。
3. **“全路径和 widow 一样”**：AllPaths 会保留所有路径，内存增长远快于最短路。
4. **“算法算子不会阻塞 runner”**：ShortestPathExecutor 内部 `.get()` 会阻塞当前 runner 线程直到路径 future 完成。

---

## 7. 验证方式

- 在 `v3.8.0` 上编译 `graph` 目标。
- 用 doom-lsp 对 `ShortestPathExecutor::execute`、`BFSShortestPathExecutor::buildPath`、`AllPathsExecutor::expand` 做符号定位。
- 行号来自当前 tag；未引用 master。

---

## 8. 和本系列的关系

- Executor 框架：见 [28-executor-framework](28-executor-framework.md)。
- 遍历算子：见 [29-traversal-executors](29-traversal-executors.md)。
- 查询算子：见 [30-query-operators](30-query-operators.md)。
- 调度与生命周期：见 [31-scheduler-and-lifetime](31-scheduler-and-lifetime.md)。
