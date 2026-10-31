# 31-scheduler-and-lifetime — 依赖图、Promise/Future 与内存水位

> 源码：<https://github.com/vesoft-inc/nebula>，tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`
> 范围：`src/graph/scheduler/`、`src/graph/executor/Executor.{h,cpp}`
> 分析日期：2026-10-31

---

## 0. 概述

`AsyncMsgNotifyBasedScheduler` 把 executor 图变成 Promise/Future 依赖图：每个 executor 等待所有依赖的 future，完成后向自己的后继 promise 发通知。它不是线程池调度器，而是“消息驱动 + 线程池执行”的组合。

本文只讲调度和生命周期，不重复 [13-control-flow](13-control-flow.md) 里的执行模型分类。

---

## 1. 入口

`QueryInstance::execute`（`src/graph/service/QueryInstance.cpp:39`）在 optimize 之后调用：

```cpp
scheduler_->schedule()
```

查询结束 `onFinish`（126 行）调用 `scheduler_->waitFinish()`（140 行），后者在 `AsyncMsgNotifyBasedScheduler.cpp:18` 用条件变量等待 `executing_ == 0`。

---

## 2. doSchedule：建 Promise/Future 图

`schedule`（`AsyncMsgNotifyBasedScheduler.cpp:31`）：

1. 如果开启 `FLAGS_enable_lifetime_optimize`，先把 root 的 outputVar `userCount` 设为 `max`，再 `analyzeLifetime(root)`；
2. `Executor::create(root, qctx_)` 建 executor 图；
3. `doSchedule(executor)`。

`doSchedule`（44 行）用两个 map：

```cpp
std::unordered_map<int64_t, std::vector<folly::Promise<Status>>> promiseMap;
std::unordered_map<int64_t, std::vector<folly::Future<Status>>> futureMap;
```

BFS 遍历 executor 图：

- 每个 executor 的 `futures` 来自它的依赖：为每个依赖建一个 Promise，把 future 放进当前 executor 的列表，把 Promise 放进依赖的列表；
- `Argument` 节点特殊：它不按 `depends()`，而是按输入变量的 `writtenBy` 找生产者；
- 根 executor 额外挂一个 `promiseForRoot`，它的 future 就是整个查询的返回。

第二遍（queue2）对每个 executor 调 `scheduleExecutor`（127 行），把 future 列表、executor、runner 传进去，并在末尾 `notifyOK` / `notifyError`。

---

## 3. 四类执行路径

`scheduleExecutor` 按节点类型分派：

| 类型 | 函数 | 行为 |
|------|------|------|
| 普通节点、有依赖 | `runExecutor`（177） | `collect(futures).via(runner)` 后 `execute(exe)` |
| 叶子节点 | `runLeafExecutor`（187） | 直接 `execute(exe).via(runner)` |
| `Select` | `runSelect`（151） | 先执行 condition，再按 bool 调度 then/otherwise 分支 |
| `Loop` | `runLoop`（192） | 执行 condition，true 则调度 body，再递归 runLoop |

`checkStatus`（219 行）在依赖 future 完成后检查是否有错误；`notifyOK`（228 行）给后继 Promise 设值，`notifyError`（234 行）设异常。

---

## 4. execute / runExecute

`execute`（241 行）是单次执行的包装：

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

`runExecute`（262 行）负责异常边界：

- `addExecuting(executor)` 增加执行计数；
- 如果已经有失败状态，直接返回；
- 用 `MemoryCheckGuard` 包住 `executor->execute()`；
- 把 `std::bad_alloc` 转成 `GraphMemoryExceeded`，其它异常转 `Status::Error`。

失败后 `setFailStatus`（299 行）只记录第一个错误；后续 executor 看到 `hasFailStatus()` 会直接返回，避免继续执行。

---

## 5. 生命周期：userCount 与 drop

`Scheduler::analyzeLifetime`（`Scheduler.cpp:24`）用栈 DFS：

- 每个 `inputVar` 的 `userCount` 加 1；
- 根、`Select` condition、`Loop` condition 的 `userCount` 设为 `max`；
- `Loop` body 记录 `loopLayers`。

执行时：

- `Executor::movable(var)`（`Executor.cpp:709`）只有当 `userCount == 1` 且不在 Loop/Select 特殊位置时才返回 true；
- `Executor::drop`（647 行）在 `finish` 后对每个 inputVar `fetch_sub(1)`，减到 0 就 `ectx_->dropResult(name)`；
- `finish`（734 行）在 outputVar 的 `userCount == 0` 时直接不保存结果。

这套机制让“最后一个消费者”可以 move/释放上游数据，减少大 DataSet 的拷贝和驻留。

---

## 6. 内存与批量

- `Executor::open` 调 `checkMemoryWatermark`（625 行）：query 节点命中 `MemoryUtils::kHitMemoryHighWatermark` 就失败；
- `runExecute` 用 `MemoryCheckGuard` 捕获 `bad_alloc`；
- `Executor::getBatchSize`（762 行）按 `FLAGS_max_job_size` / `FLAGS_min_batch_size` 计算 batch；
- `runMultiJobs`（`Executor.h` 模板）把 iterator 切块，每个 job `iter->copy()`，`folly::via(runner())` 并发，最后 `collectAll` + gather。

注意：`runMultiJobs` 的 scatter 会为每个 batch 复制 iterator，内存占用是“原数据 + 并发副本”；所以 batch 太大或 worker 太多都会推高水位。

---

## 7. 常见误解

1. **“每个 executor 一个线程”**：不是。executor 的 future 绑到共享 runner；叶子可能直接在调度线程执行。
2. **“依赖完成就立即执行”**：要等所有依赖 future 都通知，且没有全局失败状态。
3. **“lifetime 优化总是安全”**：Loop/Select 的 condition 和 body 有特殊规则；`movable` 在这些位置返回 false。
4. **“内存错误只在 allocate 时出现”**：`open` 的水位检查、`MemoryCheckGuard`、scheduler 的 bad_alloc 捕获共同构成边界。

---

## 8. 验证方式

- 在 `v3.8.0` 上编译 `graph` 目标。
- 用 doom-lsp 对 `AsyncMsgNotifyBasedScheduler` 的 `schedule/doSchedule/execute` 和 `Executor::movable/drop/finish` 做符号定位。
- 行号来自当前 tag；没有引用 master。

---

## 9. 和本系列的关系

- Executor 框架：见 [28-executor-framework](28-executor-framework.md)。
- 遍历算子：见 [29-traversal-executors](29-traversal-executors.md)。
- 查询算子：见 [30-query-operators](30-query-operators.md)。
- 算法算子：见 [32-algo-executors](32-algo-executors.md)。
