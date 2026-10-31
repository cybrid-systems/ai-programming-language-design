# 28-executor-framework — Executor 框架：PlanNode 树到异步执行 DAG

> 源码：<https://github.com/vesoft-inc/nebula>，tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`
> 范围：`src/graph/executor/Executor.{h,cpp}`、`src/graph/scheduler/`、`src/graph/service/QueryInstance.cpp`
> 工具：doom-lsp（clangd）对 `Executor` / `AsyncMsgNotifyBasedScheduler` 做符号定位
> 分析日期：2026-10-31

---

## 0. 概述

NebulaGraph 的执行引擎不是传统的 Volcano 拉取模型：没有统一的 `next()` 让父算子逐行向子算子要数据。它把物理计划里的每个 `PlanNode` 变成一个 `Executor` 对象，按依赖组成有向无环图；每个 `Executor::execute()` 返回 `folly::Future<Status>`，结果通过 `finish(...)` 写回 `ExecutionContext`，下游由调度器的 Promise/Future 触发。

这套设计带来三个直接结果：

1. 算子可以异步 fan-out（例如一次 RPC 发多个 partition）；
2. 算子之间的数据流是“变量”而不是函数返回值；
3. 生命周期和内存可以在 executor 级别做优化（`movable` / `drop`）。

---

## 1. 查询入口

`QueryInstance::execute`（`src/graph/service/QueryInstance.cpp:39`）先做 validate + optimize：

```cpp
Status status = validateAndOptimize();
...
scheduler_->schedule()
    .thenValue([this](Status s) { ... });
```

`validateAndOptimize` 在 77 行，内部调用 `findBestPlan`（255 行）拿到优化后的 `ExecutionPlan`。真正启动执行的是 `scheduler_->schedule()`（55 行）；查询结束时 `onFinish`（126 行）会 `scheduler_->waitFinish()`（140 行），等待所有 executor 退出。

---

## 2. PlanNode → Executor

`Executor::create`（`src/graph/executor/Executor.cpp:117`）是入口：

```cpp
Executor *Executor::create(const PlanNode *node, QueryContext *qctx) {
  std::unordered_map<int64_t, Executor *> visited;
  return makeExecutor(node, qctx, &visited);
}
```

`makeExecutor`（123 行）做三件事：

1. 用 `visited` 按 `PlanNode::id()` 去重，保证共享子计划只生成一个 executor；
2. 处理 `Select` / `Loop` 的分支体：`setThenBody` / `setElseBody` / `setLoopBody`（139–154 行）；
3. 对每个依赖递归建 executor，并 `exec->dependsOn(...)`（156 行），同时维护反向的 `successors_`。

节点类型到 executor 类的映射在 `makeExecutor(qctx, node)` 的 `switch`（158 行起）。例如 `kAggregate` 会先打点 `kNumAggregateExecutors`，再 `makeAndAdd<AggregateExecutor>`。所以“执行引擎的算子目录”本质就是这张 switch 表。

---

## 3. Executor 的生命周期

`Executor` 在 `Executor.h` 里定义，关键接口：

| 方法 | 位置 | 作用 |
|------|------|------|
| 构造函数 | Executor.cpp:581 | 绑定 id/name/node/qctx/ectx；DCHECK outputVar 已预分配 |
| `open()` | 595 | 检查 query 是否被 kill、内存水位；重置 profiling |
| `execute()` | 纯虚 | 算子主体，返回 `Future<Status>` |
| `close()` | 610 | 把 `ProfilingStats`（总耗时、行数、exec 时间、otherStats）写回 plan |
| `start(status)` | 639 | 把 future 绑到 `runner()` 线程池 |
| `error(status)` | 643 | 返回失败的 future |
| `finish(Result&&)` | 734 | 把结果写入 `ExecutionContext` 的 outputVar |
| `finish(Value&&)` | 750 | 用 `ResultBuilder` 包装成默认 iterator 后调用上面的 finish |

`open()` 的两个检查值得注意：

```cpp
if (qctx_->isKilled()) return Status::Error("Execution had been killed");
NG_RETURN_IF_ERROR(checkMemoryWatermark());
```

`checkMemoryWatermark`（625 行）只对 `node_->isQueryNode()` 生效：命中 `MemoryUtils::kHitMemoryHighWatermark` 时直接返回错误，避免查询继续吃内存。写操作/管理命令不在这里拦。

---

## 4. ExecutionContext 与 Result

`ExecutionContext`（`src/graph/context/ExecutionContext.h`）是按变量名存 `Result` 的容器。源码注释明确说它**不是线程安全的**：变量在语义分析阶段预分配，运行时同一变量按计划顺序读写，因此不需要为每次访问加锁。

`Result`（`src/graph/context/Result.h:20`）由三部分组成：

- `Value`：结果值（通常是 `DataSet` 或 `List`）；
- `Iterator`：对 `Value` 的行访问抽象；
- `State`：`kUnExecuted` / `kPartialSuccess` / `kSuccess`。

`Iterator::Kind`（`Iterator.h:32`）有四种：`kDefault`、`kGetNeighbors`、`kSequential`、`kProp`。不同类型决定算子能不能 move、能不能多线程过滤（见第 30 篇）。

`ResultBuilder`（`Result.h:113`）负责组装：`value(...)`、`iter(...)`、`state(...)`。默认 iterator 是 `kSequential`。

---

## 5. 调度器如何调用

`AsyncMsgNotifyBasedScheduler::schedule`（`src/graph/scheduler/AsyncMsgNotifyBasedScheduler.cpp:31`）：

```cpp
auto executor = Executor::create(root, qctx_);
return doSchedule(executor);
```

真正的单次执行包装在 `execute`（241 行）：

```cpp
auto status = executor->open();
if (!status.ok()) return executor->error(std::move(status));
auto exeStatus = runExecute(executor);
return std::move(exeStatus).thenValue([this, executor](Status s) {
  if (!s.ok()) { setFailStatus(s); ... }
  auto ret = executor->close();
  ...
});
```

`runExecute`（262 行）用 `MemoryCheckGuard` 包住 `executor->execute()`，并把 `std::bad_alloc` 转成 `GraphMemoryExceeded`；其它异常转成 `Status::Error`。因此算子内部可以放心用 STL 容器，内存异常会在调度器边界统一收敛。

---

## 6. 生命周期优化：movable / drop

`FLAGS_enable_lifetime_optimize` 默认开启。`Scheduler::analyzeLifetime`（`Scheduler.cpp:24`）从根节点 DFS：

- 对每个 `inputVar` 做 `userCount.fetch_add(1)`；
- 根节点、`Select` 的 condition、`Loop` 的 condition 把 `userCount` 设为 `max`（调度器自己要用，不能回收）；
- `Loop` 的 body 记录 `loopLayers`。

执行时 `Executor::movable(var)`（709 行）判断“这个输入变量是否只剩当前 executor 一个使用者”：

- `Loop` 节点、`Select` 节点直接返回 false；
- `Loop` body 里的非 `Filter` 也返回 false；
- 否则 `var->userCount == 1` 才允许 move。

`Executor::drop`（647 行）在 `finish` 后调用：对每个 inputVar 做 `fetch_sub(1)`，减到 0 就 `ectx_->dropResult(name)`。这样上游结果在被最后一个下游消费后立刻释放，而不是等整个查询结束。

`finish`（734 行）也配合这个逻辑：

```cpp
if (!FLAGS_enable_lifetime_optimize ||
    node()->outputVarPtr()->userCount.load(...) != 0) {
  ectx_->setResult(node()->outputVar(), std::move(result));
} else {
  VLOG(1) << "Drop variable " << node()->outputVar();
}
```

也就是说，如果 outputVar 已经没人用，executor 连结果都不存。

---

## 7. 批量任务

`Executor::getBatchSize`（762 行）：

```cpp
size_t batchSizeTmp = std::ceil(static_cast<float>(totalSize) / FLAGS_max_job_size);
size_t batchSize = batchSizeTmp > FLAGS_min_batch_size ? batchSizeTmp : FLAGS_min_batch_size;
```

`runMultiJobs`（`Executor.h` 模板）把输入 iterator 按 batch 切开，每个 job 用 `iter->copy()` 独立遍历，`folly::via(runner(), ...)` 并发执行，最后 `collectAll(...).thenValue(gather)` 合并。Filter / Project / Join 的多线程路径都复用它；gather 里必须重新检查异常和内存。

---

## 8. 常见误解

1. **“Executor 是 Volcano 算子”**：不是。没有统一的 `next()`；`execute()` 是异步的，可以返回一个稍后完成的 future。
2. **“结果通过返回值传给父算子”**：不是。结果写进 `ExecutionContext` 的变量，父算子从变量读。
3. **“finish 只是保存结果”**：它还负责生命周期 drop；开启优化时可能直接丢弃没人用的变量。
4. **“内存水位在每次分配时检查”**：`checkMemoryWatermark` 在 `open()` 检查 query 节点；运行期还有 `MemoryCheckGuard` 和 bad_alloc 捕获。

---

## 9. 验证方式

- 在 `v3.8.0` 上编译并运行 `nebula-graphd --version`（Git `fa92893`）。
- 用 doom-lsp 对 `Executor.h`、`AsyncMsgNotifyBasedScheduler.h` 做 `doc`，核对 `Executor::create`、`open/execute/close`、`schedule/doSchedule` 的符号位置。
- 本文行号均来自该 tag 源码；没有引用 master。

---

## 10. 和本系列的关系

- 具体遍历算子的实现：见 [29-traversal-executors](29-traversal-executors.md)。
- Filter / Project / Aggregate / Sort / Join：见 [30-query-operators](30-query-operators.md)。
- 依赖图、Promise/Future、生命周期与内存：见 [31-scheduler-and-lifetime](31-scheduler-and-lifetime.md)。
- 最短路 / 全路径：见 [32-algo-executors](32-algo-executors.md)。
