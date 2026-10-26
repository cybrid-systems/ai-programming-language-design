# 21 — 中间表示：面向生产的通用方案

> 字节和列布局来自 [20](20-intermediate-representation.md)。计划形状、行数、水位来自 [11](11-scenario2-beauty-buyers.md) 和 [12](12-scenario2-bench.md)。调度来自 [13](13-control-flow.md)，变量所有权来自 [14](14-data-flow.md)。下推停在哪一层来自 [10](10-pushdown-capability.md)。
> 源码：tag `v3.8.0` `fa928930`。写本文时 origin/main 上没有 15–19。那一组若是下推的泛化，和本文的关系以第 6 节为准，本文不去改那些文件，也不改 `patches/`、`bench/`。
> 新增数字来自同一次 `cd code-learn/nebula/poc-repr && make run`。堆仍是本机 glibc 的 `malloc_usable_size`，不是 [12](12-scenario2-bench.md) 那次 jemalloc，也不是 graphd 的 RSS。Thrift 规则与 [20](20-intermediate-representation.md) 相同，夹具字节没有变。
> 分析日期：2026-10-26

---

## 0. 先看结论

对外协议保持 `graph.thrift` 的 `ExecutionResponse.data`（`DataSet`）。`executeJson` 也还是这份结果的 JSON。客户端、控制台、`nebula3-python` 不换行格式。要省的是 graphd 执行器里的行、storaged 组响应时的行，以及两边 RPC 里多出来的列。

按「结果不变就能做」和「要动协议才能做」分成三段：

| 阶段 | 改什么 | 协议 | 场景二上已经量到的量级 |
|------|--------|------|------------------------|
| P0 | 投影列收紧、`AggData` 按需分配 `Set`、行向量 `reserve` / `shrink_to_fit`、单列 INT 去重的哈希键 | 不改。`LookupIndex` / `GetNeighbors` 仍是现在的 `DataSet`，只是请求里的属性名变少，或进程内少分配 | 见第 2 节。最大的一笔是 q_model 少回 `amount`：`DataSet` 3,839,533 → 3,354,539。四键列才是 2,303,722，到不了 `Project` 的 848,740 |
| P1 | graphd 内部的定长 VID 列；`GetNeighbors` 增加可选的扁平边列表；只把下一算子会读的 cell 解成 `Value` | 新增可选字段。旧字段保留。flag 关掉时两边仍走现在的嵌套列 | 扁平化针对 q_users / q_sales 的双层 `List`（堆 3.42 MB / 4.07 MB，wire 1.51 MB / 1.99 MB）。紧凑 VID 列的上界是 [20](20-intermediate-representation.md) 的裸 `list<i64>` 32,005 对一列 INT `DataSet` 84,025 |
| P2 | 算子之间按批交接；列式批；向量化表达式；调度器不再等整个算子的 future | 内部批格式。到客户端边界仍收成 `DataSet` | 调度器今天等齐依赖再 `execute`，见 [13](13-control-flow.md)。列式加法的微基准在 [20](20-intermediate-representation.md)，不是查询时延 |

P0 里两处已经写成补丁，放在 [`poc-repr/`](poc-repr/)，没有打进 `patches/`，也没有链进 nebula 二进制。`patch -p1 --dry-run` 能贴上 `fa928930`。单测和 tck 没有在这台机器上跑。

---

## 1. 这次多量了什么

[20](20-intermediate-representation.md) 的表继续有效。下面只加方案要引用的新行。基数仍是 40415 条边、4000 个用户、382 个商品。

| 标记 | 含义 |
|------|------|
| 实测·这次 | 同一次 `make run` 打出来的 `p0_*`、`agg_map`、`flat_expandall_*`、`q_model_vector_reserved`、`bench dedup_*` |
| 实测·[20] | 上一篇已经发表、这次 Thrift 夹具仍然对得上的数字 |
| 估算 | 两个实测相减以外的推断，文中另标 |

这次把七列 `reserve(40415)` 又打了一遍：`q_model_vector_reserved live 7436536`。[20](20-intermediate-representation.md) 写的是 **7,436,568**。Thrift `q_model_dataset` 两次都是 **3,839,533**。32 字节的堆差留在 glibc 计数里，下面凡是和七列比堆，都用这次的 7,436,536，避免把两轮的 usable 混减。

`AggData` 的两张表、四键列的堆、Thrift 各档，在紧挨着的另一次运行里字节相同。带 `"beauty"` 的五列 / 六列堆，另一次高了 16 字节。下面写的是这一次的输出。

| 输出行 | 值 |
|--------|----|
| `agg_map live` | 1,600,248（4000 组 × 2 个 `AggData`，各带空 `Set`） |
| `p0_agg_map_no_set live` | 1,152,248 |
| `flat_expandall_users` | 4,486,840，容量 65536 |
| `p0_expandall_users_reserved` | 3,879,840，容量 40415 |
| `flat_expandall_sales` | 4,482,768，容量 65536 |
| `p0_expandall_sales_reserved` | 3,879,840，容量 40415 |
| `p0_dedup_shrink` | 缩之前 1,066,008 / 容量 40415；`shrink_to_fit` 之后 192,056 / 容量 4000 |
| `p0_heap keys4` | 3,879,856（`_src,_dst,_rank,_type`，cell `reserve(4)`） |
| `p0_thrift keys4_dataset` / `lookup_resp` | 2,303,722 / 2,303,769 |
| `p0_heap keys_plus_item_type` | 6,143,128 |
| `p0_thrift keys_plus_item_type_dataset` / `lookup_resp` | 2,869,549 / 2,869,596 |
| `p0_heap keys_item_type_ts` | 6,789,800 |
| `p0_thrift keys_item_type_ts_dataset` / `lookup_resp` | 3,354,539 / 3,354,586 |
| `bench dedup_i64_ms_median` / `dedup_val_ms_median` | 0.187953 / 0.21173（50 次中位） |

同一次还打了 `bench sum_row_ms_median 0.070169`、`sum_col_ms_median 0.020229`。[20](20-intermediate-representation.md) 发表的是 0.069 和 0.020。这个循环仍不是 [12](12-scenario2-bench.md) 里 q_model 并发 1 的 server P50（79.68 ms）。

去重微基准的前一次运行是 0.201432 ms 和 0.211321 ms。两次都是 `std::unordered_set`，插入 40415 个键、唯一值只有 `i % 4000`。它不是 `DedupExecutor` 里的 `robin_hood::unordered_flat_set<const Row*>`。

---

## 2. P0：结果不变，协议不变

这四项都落在现有的 `Value` / `DataSet` 上。graphd 把根变量 `moveValue` 进 `ExecutionResponse` 的路径（`QueryInstance::fillRespData`）不用改。

### 2.1 投影列只收真正要读的属性

**改动点**

- `src/graph/visitor/DeducePropsVisitor.cpp` 的 `visit(EdgeExpression)`（约 254–268 行）在 `edgeTypes_` 非空时插入 `_src,_dst,_rank,_type` 和 schema 的每个字段。`src(edge)` 的参数就是 parser 造出来的 `EdgeExpression`（`parser.yy` 里 `KW_EDGE`）。`visit(FunctionCallExpression)` 今天没有特判，子节点会走到这条路径。
- `visit(VertexExpression)` 对名字不是 `$^` / `$$` 的顶点同样插入该 tag 的全部字段。`id(vertex)` 因此把 `name` 和 `type` 带进 LOOKUP 的 `returnCols`。
- `src/graph/validator/LookupValidator.cpp` 的 `validateYield` 对边扫描先种下 `_src,_dst,_rank,_type`，再 `extractExprProps` 把 `exprProps_` 里的名字追加进 `idxReturnCols_`。`validateWhere` 对同一份 `exprProps_` 再做一次 `deduceProps`。
- 运行时 `IndexScanExecutor` 用 `Iterator::Kind::kProp`。`PropIter::getEdge` 要求 `_type,_src,_dst,_rank` 都是合法值，否则返回 `kNullBadType`。`src()` 的实现（`FunctionManager.cpp`）在边上读的是 `edge.src` / `edge.dst`，方向由 `edge.type` 决定。所以存储响应里这四列要留着，`Project` 才能算出 `src(edge)`。
- `IndexScanNode::init` 把索引列从「必须读基线」的集合里擦掉，但 `FIXED_STRING` 和 `GEOGRAPHY` 不擦。`item_type` 留在 `returnCols` 里时，`needAccessBase_` 仍为真。

**补丁做了什么**

[`poc-repr/v3.8.0-returncols-key-funcs.patch`](poc-repr/v3.8.0-returncols-key-funcs.patch) 给 `DeducePropsVisitor` 增加 `visit(FunctionCallExpression)`：

- `src` / `dst` / `rank` / `typeid` 的唯一参数是 `EdgeExpression` 时，只插入四个键列，不访问这个 `EdgeExpression`。
- `id` 的唯一参数是名字为 `VERTEX` 的 `VertexExpression` 时，直接返回。`$^` / `$$` 仍走原来的 `visit(VertexExpression)`。
- `properties(edge)`、`YIELD edge AS e` 仍会访问 `EdgeExpression`，schema 字段还在。

WHERE 里的属性不在这个补丁里。q_model 的 `item_type` 和 `ts` 是 `validateWhere` 收进去的，优化器再把谓词做成索引 column hint，graphd 上不再有 `Filter`。补丁打上之后，q_model 的存储列预期是四个键加上这两个过滤列，也就是这次量的 `keys_item_type_ts`，不是一列 `user`。

**收益**

| 形态 | 堆（这次） | Thrift `DataSet` | 相对七列 `DataSet` 3,839,533 |
|------|------------|------------------|------------------------------|
| 七列（含 `amount`） | 7,436,536 | 3,839,533 | — |
| 六列：键 + `item_type` + `ts`（补丁能到的 q_model） | 6,789,800 | 3,354,539 | 少 484,994 |
| 五列：再去掉整数索引列 `ts` | 6,143,128 | 2,869,549 | 少 969,984 |
| 四键列 | 3,879,856 | 2,303,722 | 少 1,535,811 |
| `Project` 一列 INT | 这次 `q_model_project` 1,940,064（[20](20-intermediate-representation.md) 记 1,940,048） | 848,740 | 少 2,990,793 |

六列是补丁对应的实测。五列和四列是进一步丢掉 WHERE 列之后的形状，补丁没有做，数字是把那些列从测量程序里拿掉之后的实测。四键列仍然比 `Project` 的 848,740 大，因为 `PropIter::getEdge` 要四列。

`id(vertex)` 少回 tag 的 `name` / `type`：382 行的四列 `LookupIndexResp` 在 [20](20-intermediate-representation.md) 里是 22,825。只留 `_vid` 的那一档这次没有单测。

**工作量**

补丁是一个 visitor 加头文件声明。WHERE 列能不能从 `idxReturnCols_` 去掉，要在 `LookupValidator::extractExprProps` 和索引 hint 之间再对一次：谓词已经由索引决定、且该列不是 `IndexScanNode::init` 拒绝擦掉的 `FIXED_STRING` / `GEOGRAPHY` 时，才从返回列删掉。`ts` 属于这一类。`item_type` 在删掉之前，扫描仍会为了复核未截断的定长字符串去读基线。

**风险**

- `EXPLAIN` 的 `returnCols` 会变。用户可见的 YIELD 列不变。
- `src()` 在反向边上返回的是 `dst`。补丁仍插入四个键，避免只留 `_src`。
- 把 `FIXED_STRING` 过滤列从返回列删掉、同时不再读基线，会放过「索引前缀命中、完整字符串不命中」的行。这一步默认不要做。
- `id($^)` 故意没有收紧，避免 GO 上少拉 tag 属性。

建议 flag：`enable_tight_return_cols`，默认 false，加在 `GraphFlags.cpp`。关掉则 visitor 走今天的 `ExprVisitorImpl::visit`。

### 2.2 `AggData` 的 `Set` 按需分配

**改动点**

`src/common/function/AggFunctionManager.h` 的 `AggData` 构造函数在 `uniques == nullptr` 时 `make_unique<Set>()`。`Set` 是 `unordered_set<Value>`。全库只有 `AggregateExpression::eval` 调用 `uniques()`，而且只在 `distinct_` 为真时解引用。`COLLECT` / `COLLECT_SET` 把列表和集合写在 `result_` 里（`AggFunctionManager.cpp`），不读这个成员。

[`poc-repr/v3.8.0-aggdata-lazy-set.patch`](poc-repr/v3.8.0-aggdata-lazy-set.patch)：构造函数不再分配；新增 `ensureUniques()`；`eval` 仅在 `distinct_` 时调用它。

**收益**

4000 组、每组两个 `AggData`（q_sales 的 uid 和 `sum`）：1,600,248 → 1,152,248，少 **448,000**。448,000 / 8000 = 56，等于这次进程里 `sizeof(unordered_set<int>)` 的打印值。差值里没有另一块 bucket 堆，说明这套 libstdc++ 在第一次 `insert` 之前不为空 set 分配桶。输出 `DataSet` 仍是 [20](20-intermediate-representation.md) 的 256,024，那张表和哈希表是两笔内存。

[12](12-scenario2-bench.md) 的二进制用 jemalloc。56 字节对象在 jemalloc 上的 size class 这次没有量，不把 448,000 写成那次进程的 RSS。

**工作量**

两个文件。`AggregateExpressionTest.cpp` 已经有 `SUM` / `COUNT` / `COLLECT` 的 `distinct` true 和 false。补丁没有编译这份测试。

**风险**

低，只要 `distinct_` 为假时没有人解引用 `uniques()`。当前源码满足这一点。动态加载的聚合函数（`AggFunctionManager::load` 现在直接返回不支持）若将来在函数体里调用 `uniques()`，要改成 `ensureUniques()`。

建议 flag：`enable_aggdata_lazy_set`，默认 false。结果应与 flag 关一致，tck 通过后可以改为默认 true。

### 2.3 行容器的 `reserve`、`shrink_to_fit` 和移动

**改动点**

| 位置 | 今天 | 改法 |
|------|------|------|
| `ExpandAllExecutor::buildResult` | `result_.rows.emplace_back`，不 `reserve` | 边数在 `GetNeighborsIter::size()` 里已经知道，先 `reserve` |
| `LookupProcessor` 收集进 `resultDataSet_` | part 的 `deque<Row>` 再 `emplace`，vector 不 `reserve` | 各 part 行数已知后 `reserve` 再移动 |
| `DedupExecutor` | `unstableErase` 交换尾元素并 `pop_back`，容量保持 40415 | 去重结束后 `shrink_to_fit` |
| `TopNExecutor` | `eraseRange` 之后容量仍是聚合时的行数 | 同样 `shrink_to_fit` |
| `GetNeighborsNode` 的外层边 `List` | 逐条 `emplace`，不 `reserve` | 该 VID 的边数在迭代前往往未知；能从索引范围估出上界时再 `reserve`。估不出就保持今天的增长 |
| `HashInnerJoin::newRow`、`IndexProjectionNode::project` | 已经按列数 `reserve` | 不动 |
| `Executor::movable` / `Filter` 就地删 | `userCount == 1` 时可移动 | 保持。`GetNeighborsIter` 强制不可移动，多线程 filter 因此跳过 |

**收益**

| 项 | 实测 |
|----|------|
| q_users 的 `ExpandAll`：容量 65536 → 40415 | 4,486,840 → 3,879,840，少 607,000 |
| q_sales 的 `ExpandAll`（四列，cell 容量仍是 4） | 4,482,768 → 3,879,840，少 602,928 |
| 一列 INT 从 40415 行 `pop` 到 4000 再 `shrink_to_fit` | 1,066,008 / 容量 40415 → 192,056 / 容量 4000，少 873,952 |
| q_model 存储侧 deque 与 vector 重叠 | [20](20-intermediate-representation.md) 的峰值 9,836,928。`reserve` 能去掉翻倍留下的空槽；重叠本身要等 deque 清空，这次没有把「先 reserve 再从 deque move」重测一遍 |

`shrink_to_fit` 减的是 `malloc_usable_size` 意义下的 live。glibc 和 jemalloc 都可能把页留在 arena 里。它降低后续分配的峰值，不保证 `/proc/meminfo` 的 `MemAvailable` 立刻回升。水位检查看的是整机 available/total（`MemoryUtils.cpp`），所以这项对 [12](12-scenario2-bench.md) 那种 0.8 拒绝是间接的。

**工作量**

每个执行器几行。`ExpandAll` 和 `Dedup` 的行数是现成的。`LookupProcessor` 要在 part 回调全部结束、移动进 `resultDataSet_` 之前加总。外层邻居 list 的上界若没有，就不要为了 `reserve` 先扫一遍边。

**风险**

低。`shrink_to_fit` 使迭代器失效；`DedupExecutor` 在 `reset()` 之前做，并且没有把 `Row*` 留在集合里。`reserve` 不改变行内容。多线程 `runMultiJobs` 在 `FLAGS_max_job_size` 默认 1 时一批就是全部行，`reserve` 加在合并后的输出上即可。

建议 flag：`enable_exec_container_tight`，默认 false。只包 `shrink_to_fit` 和新增的 `reserve`，方便回退。

### 2.4 单列 INT / VID 的去重哈希

**改动点**

`DedupExecutor` 使用 `robin_hood::unordered_flat_set<const Row*, std::hash<const Row*>>`。`using Row = List`，`List.h` 里 `std::hash<const List*>` 和 `std::equal_to<const List*>` 按行内容哈希、按行内容相等。单列 INT 仍然要走进 `Value`。`GetDstBySrc` 用 `robin_hood::unordered_flat_set<Value>`。`VidHashSet` 已经是 `unordered_set<Value, VertexHash, VertexEqual>`。

特化只在「去重列全是 INT，且没有浮点、字符串、列表」时把键换成 `int64_t`（多列则用定长元组）。其它类型继续走 `Row*`。

**收益**

容器从 `std::unordered_set<const void*>` 换成 robin_hood 的收益，[20](20-intermediate-representation.md) 已经写成估算（589,824 对实测多出来的 1,306,304），而且执行器已经在用 robin_hood。剩下的是哈希函数。

这次的 stand-in：`std::unordered_set<int64_t>` 中位 0.187953 ms，`std::unordered_set<Val>` 中位 0.21173 ms。前一次是 0.201432 和 0.211321。差距大约 0.01–0.02 ms。[12](12-scenario2-bench.md) 里 q_users 并发 1 的 server P50 是 36.16 ms。这项不作为 P0 的主要收益。

**工作量**

`DedupExecutor` 在列类型全是 INT 时走另一张表。`MinusExecutor` 用了同一个 `Row*` 集合，要一起看，避免两条路径的相等语义分叉。

**风险**

中等偏低。漏掉 NULL / `__EMPTY__` / 多列时的内容相等，会少删行。flag `enable_int_dedup_key` 默认 false。关着时保持 `Row*`。

---

## 3. P1：进程内换布局，线上多一个可选字段

### 3.1 定长 VID / 整数列

`Value` 固定 16 字节（`Value.h` 的 `static_assert`）。一列 INT 的 `DataSet`（4000 行）Thrift 是 84,025；裸 `list<i64>` 是 32,005；逻辑上 4000×8 = 32,000。三份连续 `vector` 的堆是 678,648，那是三块缓冲加在一起，不是 32,000。

graphd 内部可以在 `Project` 之后、进入 `Dedup` / `Aggregate` 之前，把「全是 INT 或 double 的 `DataSet`」收成按列的 `vector<int64_t>` / `vector<double>`。`fillRespData` 再展开回 `DataSet`。客户端看不见。

storaged 到 graphd 的 RPC 若仍是 `DataSet`，wire 不变，省的是解码之后的堆。要省 wire，得在 `storage.thrift` 上加可选列，见 3.2 的协商方式。

**工作量** 大。`SequentialIter`、`PropIter`、表达式的 `eval` 都假定当前行是 `vector<Value>`。先只包「下游是 Dedup 或 Aggregate、列类型是 INT/double」的输出，比改全部执行器小。

**风险** 中。展开回 `DataSet` 的顺序必须和现在的 YIELD 顺序一致。flag `enable_scalar_columns` 默认 false。

### 3.2 扁平的 `GetNeighbors` 响应

今天每个 VID 一行，边在 `_edge:+/-<name>:<props>` 这一格的 `list<list<Value>>` 里。`buildYields` 总会追加 `_expr`。空边是 `__EMPTY__`，不是空 list。q_users 均分时堆 3,421,016、响应 1,509,200；q_sales 均分堆 4,067,624、响应 1,994,187。均分和「全挤在一个顶点」的响应差 4,572 字节，扇出假设对 wire 影响很小。

扁平响应用一块 `list<Value>` 按「固定键 + 属性」重复，每个边少一层 `List` 对象。graphd 的 `GetNeighborsIter` 仍能由 graphd 自己把扁平列表组回今天的嵌套 `DataSet`，这样 `ExpandAllExecutor` 可以分两步改：先只改 storaged 和解码，输出 `DataSet` 不变。

`getDstBySrc` 已经把「只要 DISTINCT dst」的 q_users 从 1,509,200 收到 84,052。扁平化对这条路径没有额外收益。q_sales 要 `amount`，仍然走 `GetNeighbors`。

**工作量** 大。`storage.thrift`、`GetNeighborsNode`、`GetNeighborsIter`、各语言的生成代码。生成代码可以后做：新字段是 optional，旧客户端不读它。

**风险** 高，若用「旧进程忽略未知字段」来切换语义。`enable_dst_only_edge_filter` 的注释写了这个失败方式：旧 storaged 不认识新请求字段时，返回的是未过滤的 dst。扁平布局用第 5 节的显式字段，不用这个失败方式。

### 3.3 延迟物化

P0 的返回列是「列根本不在 RPC 里」。延迟物化是「列还在字节流里，下一算子读到才变成 `Value`」。q_model 上这两笔是同一批多余列时，收益已经在 2.1 里拿过一次，不要加总。

还剩下的是：七列里 `Project` 确实要读的四键列，可以先留在 Thrift 缓冲里，按行解码。上界是这次的四键列堆 3,879,856 对 wire 2,303,722。差额大约 1.6 MB，而且解码最终还是要付。只有下游在 `LIMIT` 处停住、后面的行永不解码时，这笔才留得住。q_model 没有 `LIMIT`。

**工作量** 中，若只包 `IndexScan` 的响应缓冲。**风险** 中：`MemoryCheckGuard` 今天包在 `DataSet` 的 `read` 上（`DataSetOps-inl.h`）。改成延迟解码后，水位检查要包住真正碰到字节的那次读。

---

## 4. P2：调度和列式批

`AsyncMsgNotifyBasedScheduler` 对依赖 `folly::collect`，然后调用该算子的 `execute`。执行器没有 `next()`。`FLAGS_max_job_size` 默认 1，`FLAGS_min_batch_size` 默认 8192，只在 `max_job_size > 1` 时把**一个算子的输入**拆开。把 `max_job_size` 调大不会让 `ExpandAll` 的输出流进 `Aggregate`。

P2 要改的是调度器：一个算子产出固定行数的批（建议先沿用 8192），下游的 future 按批完成，而不是按整表完成。批在 graphd 内部可以是 Arrow 式的列数组；`fillRespData` 把最后一批收成 `DataSet`。向量化表达式只做已经是列数组的 INT / double 比较和 `SUM`。

**收益** 并发峰值从「并发 × 全表」变成「并发 × 一批」，外加每列去掉 16 字节的 `Value`。q_model 七列按 graphd `reserve` 形态，200 × 7,436,568 = 1,487,313,600 字节约 1.39 GiB。[12](12-scenario2-bench.md) 记录的那台机器，水位触发前的余量大约 5.48 GiB，1.39 GiB 单独填不满。分批仍然线性地降低 graphd 上这一项。列式加法的 0.02 ms 对 79.68 ms 可以忽略，直到表达式和 RPC 解码也在列上做。

**工作量** 很大。调度、背压、错误（一个批失败时已发出的批如何撤销）、`Select` / `Loop` 的整表语义都要重新定义。`Loop` 的多步 GO 今天把一步的输出整表交给下一步。

**风险** 高。flag `enable_batched_execution` 默认 false，且只对白名单算子（`Project`、`Filter`、`Aggregate` 的 SUM/COUNT）打开。`GetNeighborsIter` 保持整表，直到 P1 的扁平响应落地。

---

## 5. 怎么落地

### 5.1 版本和滚动升级

现有的版本钩子不够用：

- `common.thrift` 的 `version` 是 `"3.0.0"`。`GraphService::future_verifyClientVersion` 用 `FLAGS_enable_client_white_list` 对客户端握手，错误码 `E_CLIENT_SERVER_INCOMPATIBLE`（-3061）。这是客户端和 graphd，不是 graphd 和 storaged 的能力位。
- `storage.thrift` 的 `RequestCommon` 只有 `session_id`、`plan_id`、`profile_detail`。没有 IR 能力字段。

P0 不增加 RPC 字段。新 graphd 对旧 storaged 发的仍是「少几个属性名」的 `LookupIndex` 请求，旧 storaged 本来就按请求的列返回。

P1 的新布局：

1. 请求增加 optional bool，例如 `flat_neighbors`。缺省等于 false。
2. 响应增加 optional 的扁平列表。旧的嵌套 `DataSet` 在 bool 为 false 时照旧填满。
3. 新 storaged 只有在 bool 为 true 时才填扁平字段，并可以留空嵌套列。旧 storaged 看不到这个字段，嵌套列照旧填满，扁平字段不存在。
4. 新 graphd 以「响应里扁平字段有值」为准来解码。字段没有值就走今天的 `GetNeighborsIter`。不要在字段缺失时假定对方已经按新语义过滤过。

滚动顺序和 `enable_dst_only_edge_filter` 的注释同一套：先把全部 storaged 换成能识别 optional 字段、默认请求仍走旧响应的版本，再换 graphd，最后打开 flag。回退是把 flag 设回 false 并重启 graphd。已经发出的请求仍带旧字段，storaged 不需要降级。

对外 `ExecutionResponse` 不增加列类型。内部列在 `fillRespData` 展开。

### 5.2 Flag、灰度和回退

行为开关用 gflags，默认 false，和 `enable_optimizer` 在 `GraphFlags.cpp` 里的默认值、以及 `enable_dst_only_edge_filter` 一样。发行 conf 里要显式写上，避免只改二进制默认值。

| Flag | 阶段 | 关掉之后 |
|------|------|----------|
| `enable_tight_return_cols` | P0 返回列 | `DeducePropsVisitor` 恢复「整条边 / 整个 tag」 |
| `enable_aggdata_lazy_set` | P0 | 构造 `AggData` 时分配空 `Set` |
| `enable_exec_container_tight` | P0 | 不额外 `reserve`，不去重后不 `shrink_to_fit` |
| `enable_int_dedup_key` | P0 | `Dedup` 继续哈希 `Row*` |
| `enable_scalar_columns` | P1 | 执行器之间只用 `DataSet` |
| `enable_flat_neighbors` | P1 | 请求不带 `flat_neighbors` |
| `enable_batched_execution` | P2 | 调度器整表 `collect` |

灰度按 space 或会话打开比按进程打开更安全，但 v3.8.0 的 gflags 是进程级的。第一版按进程：先在一只 graphd 上打开 P0，对同一条语句采样结果校验和，再铺开。P1 必须等该 graphd 会连到的每只 storaged 都已升级。

### 5.3 内存水位和 `MemoryTracker`

两套机制并存：

- `MemoryUtils.cpp`：`(1 - available/total) > FLAGS_system_memory_high_watermark_ratio`（默认 0.8）。这是 cgroup 或 `/proc/meminfo` 的整机数。[12](12-scenario2-bench.md) 的失败文案是这一条。查询、storaged、客户端解码算在一起。
- `ENABLE_MEMORY_TRACKER` 编译进来之后，`handleMemoryTracker` 用 `FLAGS_memory_tracker_limit_ratio`（默认 0.8）设跟踪器上限，`FLAGS_memory_tracker_untracked_reserved_memory_mb` 默认 50。`DataSet` 解码和 storage processor 上有 `MemoryCheckGuard`。

P0 的少分配走 `operator new`，跟踪器打开时会计入。水位那条要等分配器把页还给系统才看得到。方案里不把「少了 448,000 字节的 `Set`」写成「200 并发不再撞 0.8」。200 路七列结果约 1.39 GiB，相对那次快照上约 5.48 GiB 的余量仍然解释不了拒绝，这一点 [20](20-intermediate-representation.md) 已经写过。P0 少列会把 1.39 GiB 这项按列数缩小；P2 分批会把乘数从整表改成一批。两笔都要再跑 [12](12-scenario2-bench.md) 的并发 200 才能说水位。

### 5.4 正确性

| 检查 | 用来抓住什么 |
|------|----------------|
| `AggregateExpressionTest` 里 `distinct` 为 true 和 false 的 SUM / COUNT / COLLECT / COLLECT_SET | 懒 `Set` 在 DISTINCT 上仍去重，非 DISTINCT 的 SUM 不变，COLLECT 仍写在 `result_` |
| nebula 的 tck | flag 关着时回归。flag 开着时同一批 tck 再跑一遍 |
| 差分：同一条语句 flag 关 / 开，客户端 `DataSet` 的校验和 | 返回列和去重键。场景二沿用 [12](12-scenario2-bench.md) 的做法：用户集合的 SHA-256，销售额合计 10073144 |
| `YIELD edge AS e` 仍含 `amount`；`YIELD src(edge)` 的 vid 与 flag 关一致；WHERE 里非索引列仍能滤掉行 | 2.1 的边界 |
| `properties(edge)`、`id($^)` 的列和今天一致 | visitor 没有把这两条误收紧 |
| 多列 DISTINCT、含 NULL 的 DISTINCT | `enable_int_dedup_key` 必须走回 `Row*` |

这次没有编译 nebula，也没有跑 tck。补丁只做了 `patch --dry-run`。

### 5.5 性能和观测

沿用 [12](12-scenario2-bench.md)：server 的 `latency_in_us` 和客户端墙钟分开记，PROFILE 看行数。本文不给出新的时延。

`graph/util/Utils.cpp` 的 `collectRespProfileData` 现在写 `host`、`exec`、`total`、`vertices`，以及可选的 `storage_detail`。没有字节。建议在同一张 folly 对象里加两项：storage 响应缓冲的长度（RPC 层读到的字节，含帧头时单独标），以及 graphd 上该算子输出 `DataSet` 的行数和列数。应用层 Thrift 宽度可以用 [20](20-intermediate-representation.md) 的规则离线算，在线先记缓冲长度，避免在热路径上再扫一遍 `Value`。

P0 合入前的门槛：场景二的三条语句在 flag 开 / 关下校验和一致；PROFILE 行数与 [12](12-scenario2-bench.md) 一致（382 / 40415 / 4000 / TopN 100）；`returnCols` 在 flag 开时不再出现 q_model 的 `amount`。时延只记录，不作为合入条件，直到有一轮和 [12](12-scenario2-bench.md) 相同的单机配置。

---

## 6. 和下推的关系，以及场景二

[10](10-pushdown-capability.md) 里和表示法重叠的三行：

- 投影：GO 的 YIELD / WHERE 会收进 `edgeProps`，但 `PrunePropertiesVisitor` 不访问 `Expand` / `ExpandAll` / `GetNeighbors`。LOOKUP 的 `idxReturnCols` 就是 2.1 没收干净的那一列。
- Aggregate：没有按 dst 的 GROUP BY 下推。`stat_props` 是一个顶点上的标量，`AggregateNode` 只服务 `GetNeighbors`。
- Limit / TopN：q_model 没有 `LIMIT`。q_sales 的 `ORDER BY` / `LIMIT` 在 graphd。

写本文时 15–19 不在 origin/main 上。若那一组把上述三条收成可复用的下推，和本文的分工是：下推减少行数，本文减少留下来的每一行的字节和峰值。两边都做时，收益相乘，不要把 [20](20-intermediate-representation.md) 的字节和「少了一半行」再加一次。

| 项 | 关系 |
|----|------|
| 2.1 返回列 | 补上 LOOKUP 上 `visit(EdgeExpression)` / `id(vertex)` 的过度收集。和投影下推是同一件事的剩余部分 |
| 2.2 空 `Set`、2.3 `reserve` / `shrink` | 纯执行器。下推不覆盖 |
| 2.4 INT 哈希 | 纯执行器。host 内 DISTINCT dst 已由 `getDstBySrc` 在另一条 RPC 上做完 |
| 3.2 扁平邻居 | q_users 在 flag 开的 `getDstBySrc` 上已经被绕开。q_sales 仍需要 |
| 3.3 延迟物化 | 列已经不在请求里时，没有剩余收益 |
| P2 分批 | 不代替 `PushLimit`。q_model 没有 LIMIT，分批只降低峰值 |
| 按 dst 的 SUM 下推到 storaged | 与 2.2 不重复。下推成功时 40415 行的 `amount` 不必进 graphd，2.2 的 448,000 字节也不再出现。下推做不到跨 part 的全局和，graphd 上的 `Aggregate` 仍要 2.2 |

建议顺序：

1. 已经在做的下推和 `getDstBySrc`（少行、少 RPC）。q_users 的大头在这里，不在表示法。
2. P0，与第 1 步并行。返回列对 q_model 立刻减 wire；`AggData` 和 `reserve` 不依赖 storaged 版本。
3. WHERE 列从 `returnCols` 删除（`ts` 可以，`item_type` 在定长复核还在时保留）。
4. P1。storaged 先升级，再开 `enable_flat_neighbors`。
5. P2。等 P0/P1 的 PROFILE 字节上来之后，用那些字节决定批大小，而不是先改调度器。

场景二各阶段留下什么：

| 查询 | P0 | P1 | P2 |
|------|----|----|----|
| q_users，`getDstBySrc` 关 | tag 上的 `id(vertex)` 不再为了 id 去拉 `name`/`type`（382 行，相对后面的边可以忽略）。`ExpandAll` 堆 4,486,840 → 3,879,840。去重后 `shrink_to_fit` 把一列 INT 从容量 40415 收到 4000（1,066,008 → 192,056）。邻居响应仍约 1.51 MB | 扁平边列表砍掉双层 `List`。紧凑 VID 列作用在去重后的 4000 个 INT 上（84,025 → 裸 list 32,005 是上界） | 40415 行按批进入 `Dedup`，峰值从整表变成一批。DISTINCT 的结果仍要见过全部行才能定 |
| q_users，`getDstBySrc` 开 | 响应已经是 84,052。P0 的 `ExpandAll` 不再出现。`shrink` 几乎没有 40415 的容量可缩 | 扁平邻居用不上这条 RPC | 4000 行本身已经小于 8192，分批没有行可拆 |
| q_sales | `AggData` 少 448,000。`ExpandAll` 少 602,928。`amount` 必须留下，`GetNeighbors` 仍约 1.99 MB | 扁平化是这条查询的 wire 收益。按 dst 的 SUM 若由下推做成，这一行的 P1 收益改记在下推上 | `Aggregate` 可以按批更新哈希表，4000 组的表仍要活到结束 |
| q_model | 补丁去掉 `amount`：`DataSet` 少 484,994，堆从 7,436,536 到 6,789,800。`item_type` 还在，基线仍要读。再去掉 `ts` 是五列那一档（`DataSet` 2,869,549）。四键列是 2,303,722，不是 848,740 | 四键列若改成定长整数列，wire 才从 2,303,722 往 32,005×4 的量级走。这次没有量「四条裸 i64 list」的 Thrift | 没有 LIMIT，分批降低的是 200 并发时同时活着的全表份数。1.39 GiB 这个乘法里的 7,436,568 会随列数变小 |

---

## 7. PoC 的边界

| 文件 | 状态 |
|------|------|
| [`poc-repr/v3.8.0-aggdata-lazy-set.patch`](poc-repr/v3.8.0-aggdata-lazy-set.patch) | 对 `/tmp` 里的 `fa928930` `patch -p1 --dry-run` 通过。没有 apply，没有编译 `AggregateExpressionTest` |
| [`poc-repr/v3.8.0-returncols-key-funcs.patch`](poc-repr/v3.8.0-returncols-key-funcs.patch) | 同样只做了 dry-run。没有跑 LOOKUP / GO 的 tck |
| [`poc-repr/measure.cpp`](poc-repr/measure.cpp) | 第 1 节的新行。`make run` 复现。二进制不要提交 |

没有把补丁放进 `patches/`。`enable_dst_only_edge_filter` 仍由那一边的补丁独占。
