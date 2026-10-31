# 29-traversal-executors — GetNeighbors / Expand / Traverse：三种图遍历执行器

> 源码：<https://github.com/vesoft-inc/nebula>，tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`
> 范围：`src/graph/executor/query/{GetNeighbors,Expand,Traverse}Executor.cpp`、`src/graph/executor/StorageAccessExecutor.h`
> 分析日期：2026-10-31

---

## 0. 概述

图查询的“执行”大部分时间花在三种遍历算子上：

- `GetNeighborsExecutor`：一跳邻居，GO 的基础；
- `ExpandExecutor`：多跳扩展，不生成路径；
- `TraverseExecutor`：多跳 + 路径跟踪，MATCH 变长路径的基础。

它们都继承 `StorageAccessExecutor`，通过 `StorageClient` 把请求发到 storaged；区别在于每一步是否保留边/路径、是否做存储侧过滤、是否走 `GetDstBySrc` 优化。

---

## 1. StorageAccessExecutor

`StorageAccessExecutor`（`StorageAccessExecutor.h:31`）提供三件公共能力：

1. `handleCompleteness`（41 行）：检查 `StorageRpcResponse::completeness()`。100% 成功 → `kSuccess`；部分成功且 `FLAGS_accept_partial_success` → `kPartialSuccess` 并 `qctx()->setPartialSuccess()`；否则把失败的 part 错误映射成用户可读的 `Status`。
2. `handleErrorCode`（64 行）：把 `E_RPC_FAILURE`、`E_LEADER_CHANGED`、`E_RAFT_*`、`E_GRAPH_MEMORY_EXCEEDED` 等错误码翻译成具体错误信息。
3. `buildRequestListByVidType`（173 行）：从输入 iterator 里按 VID 类型构造请求列表，去重/类型校验。

这层解释了一个常见现象：storage 部分失败时，查询可能返回部分结果而不是直接报错；是否接受由 flag 决定。

---

## 2. GetNeighborsExecutor：一跳

`buildRequestVids`（`GetNeighborsExecutor.cpp:14`）从输入变量取 `Iterator`，调 `buildRequestListByVidType` 生成 vids。

`execute`（24 行）：

```cpp
return storageClient->getNeighbors(param, {kVid}, std::move(vids),
                                   gn_->edgeTypes(), gn_->edgeDirection(),
                                   gn_->statProps(), gn_->vertexProps(),
                                   gn_->edgeProps(), gn_->exprs(),
                                   gn_->dedup(), gn_->random(),
                                   gn_->orderBy(), gn_->limit(qec),
                                   gn_->filter(), nullptr)
```

注意这里把 `filter`、`limit`、`orderBy`、`dedup`、`random` 都传给了 storage：一跳查询的过滤/排序/限制尽量在 storaged 做，graphd 只负责收结果。

`handleResponse`（81 行）：

- `handleCompleteness` 决定 `Result::State`；
- 把每个 response 的 `vertices` 放进 `List`；
- 用 `Iterator::Kind::kGetNeighbors` 建结果。

因此 `GetNeighborsExecutor` 的产物不是普通 `DataSet`，而是 `List<DataSet>` 的 GetNeighbors iterator；下游 Filter 对它有特殊处理（见第 30 篇）。

---

## 3. ExpandExecutor：多跳、不建路径

`execute`（`ExpandExecutor.cpp:41`）先读 `maxSteps_`、`sample_`、`stepLimits_`。三条分支：

1. `maxSteps_ == 0`：只把输入 vid 原样输出（0 跳）；
2. `joinInput()` 或 `stepLimits_` 非空：走 `getNeighbors()`，因为需要边属性/每步 limit/与输入 join；
3. 否则走 `GetDstBySrc()`，这是 3.8 的优化路径。

`GetDstBySrc`（69 行）只请求“每个 src 的 dst”，不取边属性：

```cpp
return storageClient->getDstBySrc(param, std::move(vids), expand_->edgeTypes())
```

它按 `currentStep_ < maxSteps_` 循环，把上一轮的 dst 作为下一轮 src；只有最后一轮才组装 `DataSet`。这条路径适合“只要终点、不要边”的变长扩展。

`getNeighbors`（135 行）是通用路径：每步调用 `getNeighbors`，方向固定 `OUT_EDGE`，带 `edgeProps`、`sample_`、`stepLimit`；然后 `handleResponse`（274 行）解析结果，若还有下一步且 `nextStepVids_` 非空就递归。

`expandFromCache`（195 行）在“下一跳为空但缓存里还有未访问点”时继续用 `adjDsts_` 扩展；`sample_` 用 `ReservoirSampling` 控制每步采样。

---

## 4. TraverseExecutor：多跳 + 路径

`execute`（`TraverseExecutor.cpp:25`）读取 `range_ = stepRange()`、`genPath_`，然后 `buildRequestVids()`。

`buildRequestVids`（36 行）有一个关键分支：如果 `trackPrevPath()` 为真，它会把输入行的上一段路径存进 `dst2PathsMap_`，并用 `movable` 决定能不能 `moveRow()`；否则只取 VID 并做类型检查。

`getNeighbors`（79 行）每步发 RPC，但参数按 `finalStep` 裁剪：

```cpp
finalStep ? traverse_->statProps() : nullptr,
...
finalStep ? traverse_->exprs() : nullptr,
finalStep ? traverse_->dedup() : false,
finalStep ? traverse_->random() : false,
finalStep ? traverse_->orderBy() : ...,
finalStep ? traverse_->limit(qctx()) : -1,
selectFilter(),
currentStep_ == 1 ? traverse_->tagFilter() : nullptr
```

也就是说，中间步骤不应用最终过滤/排序/limit，只有最后一跳才下推；`selectFilter` 会把普通 `filter` 和 `firstStepFilter` 合并，且当第一步 `range.min()==0` 时跳过过滤（0 步路径不需要边过滤）。

`handleResponse`（276 行）分两条路：

- 首步且没有 `eFilter`/`vFilter`：走 `expandOneStep`，直接建邻接表；
- 有过滤：把 responses 包成 `GetNeighborsIter`，再 `expand(iter)` 逐行应用 `vFilter`/`eFilter`。

`asyncExpandOneStep`（200 行）按每个 response 并行 `buildAdjList`，最后合并 `initVertices_`、`vids_`、`adjList_`；`expandOneStep`（259 行）在行数小于 `FLAGS_traverse_parallel_threshold_rows`（默认 150000）时并行，否则串行，避免小结果集被线程调度拖慢。

路径生成在 `buildPathMultiJobs`（430 行）里完成；`genPath_` 为真时才会生成完整路径，否则只返回点/边。

---

## 5. 三者的选择

| 执行器 | 步数 | 路径 | 典型场景 |
|--------|------|------|----------|
| GetNeighbors | 1 跳 | 不保留 | `GO 1 STEP`、单跳邻居 |
| Expand | 多跳 | 不保留 | 变长扩展、只要终点/边 |
| Traverse | 多跳 | 可保留 | `MATCH` 变长路径、需要路径语义 |

几个容易忽略的点：

- `Expand` 不是“多跳 GetNeighbors”：无 join、无 stepLimit 时走 `GetDstBySrc`，根本不取边属性；
- `Traverse` 的 storage filter/limit 只在最后一跳下推，中间跳传 `nullptr`/默认值；
- `GetNeighbors` 的结果 iterator 是 `kGetNeighbors`，不是 `kSequential`，下游 Filter 不能对它做多线程切分（见第 30 篇）。

---

## 6. 常见误解

1. **“所有遍历都走 getNeighbors”**：Expand 的优化路径走 `getDstBySrc`。
2. **“每跳都应用 WHERE”**：Traverse 只有 finalStep 应用 storage 侧表达式/limit；中间跳只做必要的路径构建。
3. **“Expand 会生成路径”**：不会；路径由 Traverse 的 `genPath_` / `trackPrevPath` 负责。
4. **“部分失败一定报错”**：`handleCompleteness` 在 `accept_partial_success` 时返回部分结果。

---

## 7. 验证方式

- 在 `v3.8.0` 上编译 `graph` 目标，确认 `GetNeighborsExecutor` / `ExpandExecutor` / `TraverseExecutor` 通过。
- 用 doom-lsp 对三个 executor 的 `execute` 和 `handleResponse` 做符号定位，核对行号。
- 本文只讨论 graphd 侧；storaged 的 `GetNeighborsProcessor` / `ScanEdgeProcessor` 见 04 篇。

---

## 8. 和本系列的关系

- Executor 框架：见 [28-executor-framework](28-executor-framework.md)。
- Filter / Project / Aggregate 等：见 [30-query-operators](30-query-operators.md)。
- 调度与生命周期：见 [31-scheduler-and-lifetime](31-scheduler-and-lifetime.md)。
