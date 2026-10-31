# 30-query-operators — Filter / Project / Aggregate / Sort / TopN / Limit / Join

> 源码：<https://github.com/vesoft-inc/nebula>，tag `v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`
> 范围：`src/graph/executor/query/` 下的 Filter / Project / Aggregate / Sort / TopN / Limit / Join / Union / Intersect / Minus
> 分析日期：2026-10-31

---

## 0. 概述

执行引擎的查询算子可以分成两类：

1. **流式/逐行**：Filter、Project、Limit、Sort、TopN，输入是一个 `Iterator`，输出新的 `DataSet` 或复用输入；
2. **阻塞/收集**：Aggregate、Join、Union/Intersect/Minus，需要先把输入物化，再建哈希表或做集合运算。

这些算子都从 `ExecutionContext` 读取输入变量，结果通过 `finish(Result&&)` 写回。理解它们的关键不是 SQL 语义，而是 **Iterator 的 Kind**：`kSequential`、`kProp`、`kGetNeighbors` 能做的事不同。

---

## 1. Iterator 与 Result

`Iterator`（`src/graph/context/iterator/Iterator.h:16`）是行访问抽象：

- `Kind`（32 行）：`kDefault`、`kGetNeighbors`、`kSequential`、`kProp`；
- `valid()`（50 行）、`next()`（54 行）、`row()`（68 行）、`size()`（93 行）；
- `erase()` / `unstableErase()` / `select(offset,count)` / `sample(count)`。

`Result`（`Result.h:20`）持有 `Value` + `Iterator` + `State`；`ResultBuilder`（113 行）负责组装。算子通常这样做：

```cpp
auto iter = ectx_->getResult(inputVar).iter();
...
return finish(ResultBuilder().value(Value(std::move(ds))).build());
```

注意 `iter()` 是 `copy()` 出来的新迭代器；`iterRef()` 才是直接引用，只有在确认可 move/可修改时才用。

---

## 2. FilterExecutor

`execute`（`FilterExecutor.cpp:13`）：

```cpp
if (FLAGS_max_job_size == 1 || iter->isGetNeighborsIter()) {
  return handleSingleJobFilter();
} else {
  ... runMultiJobs(...)
}
```

为什么 GetNeighbors iterator 不能多 job？代码注释写得很直接：**GetNeighborsIterator 不是线程安全实现**。它内部通常持有共享的 `List`/切片状态，多个 job 并发遍历会冲突。

单 job 路径 `handleSingleJobFilter`（93 行）先用 `movable(inputVar)` 判断能不能直接改输入：

- 如果输入变量只剩当前消费者，或者输入是 GetNeighbors iterator，就复用它的 `DataSet`，在迭代器上 `erase()` / `unstableErase()`；
- 否则复制行到新的 `DataSet`。

条件求值有三种“假”值：空值、null、隐式 bool 为 false；如果结果是坏 null 或非 bool，直接报错，提示用户写完整布尔表达式。

多 job 路径把 `filter->condition()->clone()` 给每个 job，避免多个 worker 共享同一个表达式状态；gather 时按 iterator kind 决定用 `kSequential` 还是 `kProp` 重建结果。

---

## 3. ProjectExecutor

`execute`（`ProjectExecutor.cpp:13`）在 `FLAGS_max_job_size <= 1` 时单 job，否则 `runMultiJobs`。

`handleJob`（59 行）为每个 job `columns()->clone()`，然后逐行求值：

```cpp
for (auto &col : columns->columns()) {
  Value val = col->expr()->eval(ctx(iter));
  row.values.emplace_back(std::move(val));
}
```

Project 总是产生新的 `DataSet`，不会复用输入行；它的成本主要是表达式求值和行拷贝。

---

## 4. AggregateExecutor

`execute`（`AggregateExecutor.cpp:12`）先做了一个很实用的短路：

```cpp
if (groupKeys.empty() && groupItems.size() == 1 &&
    upper(groupItems[0]->toString()) == "COUNT(*)") {
  ds.rows.emplace_back(Row({Value(static_cast<int64_t>(iter->size()))}));
}
```

无 GROUP BY 的 `COUNT(*)` 不需要逐行聚合，直接取 `iter->size()`。

否则用：

```cpp
std::unordered_map<List, std::vector<std::unique_ptr<AggData>>, std::hash<List>> result;
```

以 group key 的 `List` 为 key，每个 group 一组 `AggData`。输入为空时，如果所有 group item 都是聚合表达式，会生成一行默认值（例如 `COUNT=0`、`SUM=null`）。非聚合表达式在 group 内逐行覆盖 `AggData`。

---

## 5. Sort / TopN / Limit

`SortExecutor::execute`（`SortExecutor.cpp:12`）只接受 `SequentialIter`：

```cpp
if (UNLIKELY(!iter->isSequentialIter())) return Status::Error(...);
std::sort(seqIter->begin(), seqIter->end(), comparator);
```

比较器按 `factors` 的列索引和 ASC/DESC 逐列比较；它直接在原 `DataSet` 上排序，然后 `finish` 同一个 `valuePtr`。

`TopNExecutor::execute`（`TopNExecutor.cpp:12`）是堆实现：

- `heapSize_ = offset + count`（或 size）；
- 取前 `heapSize_` 行建最大堆；
- 剩余行逐个与堆顶比较，更优就替换；
- `sort_heap` 后只保留 `maxCount_` 行，`eraseRange(maxCount_, size)`。

它避免了对全部行做 `std::sort`，适合 `ORDER BY ... LIMIT n`。

`LimitExecutor::execute`（`LimitExecutor.cpp:12`）先 `movable(inputVar)`；可 move 时直接 `iter->select(offset, count)`，否则复制区间行到新 `DataSet`。GetNeighbors iterator 也被强制视为可 move，避免 go 语句计划里的共享数据问题。

---

## 6. Join

`InnerJoinExecutor::execute`（`InnerJoinExecutor.cpp:12`）：

```cpp
NG_RETURN_IF_ERROR(checkInputDataSets());
if (FLAGS_max_job_size <= 1) return join(...);
else return joinMultiJobs(...);
```

`join`（约 31 行）选择**较小的一侧**建哈希表：

```cpp
if (lhsIter_->size() < rhsIter_->size()) {
  buildSingleKeyHashTable(hashKeys.front(), lhsIter_.get(), hashTable);
  result = singleKeyProbe(probeKeys.front(), rhsIter_.get(), hashTable);
} else {
  exchange_ = true;
  buildSingleKeyHashTable(probeKeys.front(), rhsIter_.get(), hashTable);
  result = singleKeyProbe(hashKeys.front(), lhsIter_.get(), hashTable);
}
```

`exchange_` 标记左右是否交换，`close()`（23 行）会重置它。单 key 用 `unordered_map<Value, vector<const Row*>>`；多 key 用 `unordered_map<List, ...>`。`joinMultiJobs`（116 行）把哈希表放在成员里，probe 侧按 batch 并发。

`LeftJoinExecutor`（14 行）结构相同，区别是未匹配的 probe 行要补 null 列。

---

## 7. Union / Intersect / Minus

`UnionExecutor::execute`（`UnionExecutor.cpp:12`）最简单：检查两个输入都是 `SequentialIter`，把左右 `begin()..end()` move 进同一个 `DataSet`。

`IntersectExecutor::execute`（`IntersectExecutor.cpp:12`）和 `MinusExecutor::execute`（`MinusExecutor.cpp:14`）做集合运算；它们需要先物化一侧，再按行/哈希判断存在性。具体实现依赖 `checkInputDataSets` 和输入 iterator 的类型。

---

## 8. 常见误解

1. **“所有算子都能多线程”**：Filter 遇到 GetNeighbors iterator 会强制单 job；Sort/TopN 只接受 SequentialIter。
2. **“Filter 一定复制数据”**：可 move 时直接在输入 iterator 上 erase，甚至复用原 `DataSet`。
3. **“COUNT(*) 也走 GroupBy”**：无 group key 的 COUNT(*) 直接取 size。
4. **“TopN 和 Sort 一样”**：TopN 是 O(n log k) 的堆，Sort 是 O(n log n) 全排序。
5. **“Join 总是把左表建哈希”**：按大小选较小侧，且可能交换左右。

---

## 9. 验证方式

- 在 `v3.8.0` 上编译 `graph` 目标，确认这些 executor 通过。
- 用 doom-lsp 对 `FilterExecutor` / `AggregateExecutor` / `InnerJoinExecutor` 的 `execute` 做符号定位。
- 行号来自当前 tag；未引用 master。

---

## 10. 和本系列的关系

- Executor 框架：见 [28-executor-framework](28-executor-framework.md)。
- 遍历算子：见 [29-traversal-executors](29-traversal-executors.md)。
- 调度与批量：见 [31-scheduler-and-lifetime](31-scheduler-and-lifetime.md)。
