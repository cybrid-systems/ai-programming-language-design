# 20 — 场景二：算子输出和中间表示

> 查询和计划形状见 [11](11-scenario2-beauty-buyers.md)。行数、PROFILE、并发 200 的内存水位见 [12](12-scenario2-bench.md)。
> 调度模型见 [13](13-control-flow.md)：graphd 整批物化，storaged 的 `IndexNode::next` 才是一次一行。变量和 Iterator 的所有权见 [14](14-data-flow.md)。
> 源码：tag `v3.8.0` `fa928930`。`Value` / `DataSet` / `Cpp2Ops` / `GetNeighborsProcessor` 的列布局在 master `426266b5` 上与此相同；本文不再重复那份 diff。
> 基数来自 [12](12-scenario2-bench.md) 的单机数据，不是本文新跑出来的：窗口内美妆购买边 **40415**，美妆商品 **382**，用户 **4000**（这个分布下每个用户至少有一条命中边）。单 storaged。
> 字节是本文的程序 [`poc-repr/measure.cpp`](poc-repr/measure.cpp) 算的。堆是本机 glibc 的 `malloc_usable_size`，**不是** [12](12-scenario2-bench.md) 那次 Release 里的 jemalloc，也不是 graphd 进程的采样。
> 按这些字节做的分阶段方案在 [21](21-ir-optimization-design.md)。
> 分析日期：2026-10-26

---

## 0. 先看结论

三条语句在 graphd 里交换的都是 `Value` 里的 `DataSet`：`using Row = List`，`List` 是 `vector<Value>`。`Value` 固定 16 字节。INT 和 double 不再分配堆；STRING 和 LIST 各有一层 `unique_ptr`。

真正占字节的有两处：

1. **q_users / q_sales 的 `GetNeighbors` 响应。** 382 个商品 VID 各一行，边塞在 `_edge:-buy:...` 这一格的 `list<list<Value>>` 里，合计 40415 条边。按 TBinaryProtocol 算，q_users 这一帧应用层约 **1.51 MB**，q_sales 约 **1.99 MB**（均分假设只影响不到 5 KB，见第 5 节）。graphd 再把它摊成 40415 行的普通 `DataSet`。摊平后的行向量不 `reserve`，容量扩到 65536，glibc 上约 **4.49 MB**，和嵌套结构同时活着。
2. **q_model 的边索引扫描。** YIELD 只有 `src(edge)`，`returnCols` 仍是 `_src,_dst,_rank,_type,amount,item_type,ts` 七列（[12](12-scenario2-bench.md) 的 PROFILE，原因在第 4 节）。40415 行的 Thrift `DataSet` 是 **3,839,533** 字节，加上 `LookupIndexResp` 的外壳是 **3,839,580**。graphd 按行数 `reserve` 之后，glibc 堆 **7,436,568** 字节。`Project` 只留下一列 INT，堆降到 **1,940,048**，Thrift 降到 **848,740**。多出来的六列在投影之前已经进了内存。

flag 开的 q_users 走 `getDstBySrc`。单 host 去重后是 4000 个 INT，响应 **84,052** 字节。这是已有补丁，不是本文新做的。它盖不住 q_sales（要 `amount`），也盖不住 q_model（根本不走邻居 RPC）。

并发 200 把 q_model 打到 `high watermark(0.800000)` 是 [12](12-scenario2-bench.md) 的实测。那次检查看的是**整机** available/total，不是单个查询的 arena。200 份七列 `DataSet`（按 graphd 的 `reserve` 形态）是 `7436568 × 200 = 1,487,313,600` 字节约 1.39 GiB。这个数单独填不满 [12](12-scenario2-bench.md) 记录的那台 16 GB 机器的 0.8 水位。水位里还有 storaged、Python 客户端解码同一批行、以及失败瞬间的其它占用。本文没有重放那次 OOM。

---

## 1. 怎么量，哪些是实测

| 标记 | 含义 |
|------|------|
| 实测·规则 | `measure.cpp` 按 `Cpp2Ops<Value/List/DataSet>::write` 和 TBinaryProtocol 的字段宽度累加。夹具：空 `Value` 1 字节，INT/double 12，`"beauty"` 14，空 `DataSet` 17，空 `failed_parts` 的 `ResponseCommon` 20，两个 INT 的 LIST `Value` 37。没有链接 fbthrift，也没有抓包 |
| 实测·glibc | 同一程序用替换的 `operator new` 构造同形状的 `vector` / `string` / `unordered_set`，读 `malloc_usable_size`。`sizeof` 与容量是 ABI 级的；usable 是 glibc size class，jemalloc 会不同 |
| 估算 | 均分到 382 个顶点、robin_hood 槽位数、两个已测结构同时存活时的相加、200 路线性叠加 |
| 未单测 | 源码路径清楚，但程序没有构造那一个对象 |

协议是 `ThriftClientManager-inl.h` 里的 `T_BINARY_PROTOCOL`。下面的响应字节是应用结构（`GetNeighborsResponse` / `GetDstBySrcResponse` / `LookupIndexResp` / `ExecutionResponse`），不含帧头和方法名。`ExecutionResponse` 只算了必填的 `error_code`、`latency_in_us` 和 `data`；`fillRespData` 不写 `space_name`。

复现：

```bash
cd code-learn/nebula/poc-repr
make run
```

`beauty_item_names.txt` 由 `gen_beauty_names.py` 重放 `gen_data.py` 的前缀 RNG（seed 2，2000 个商品，`beauty_ratio=0.2`），得到 382 个名字、共 1699 个字符。商品名都是 `i` 加编号，最长 `i1996`（5 字节），落在 libstdc++ SSO（本机 `std::string` 容量 15）里。字符串对象仍要单独 `new`，因为 `Value` 拿的是 `unique_ptr<string>`。

本机 `sizeof`：`Val` 16（与 `Value.h` 的 `static_assert` 一致），`vector<Val>` 24，`string` 32，`unique_ptr<string>` 8，`unordered_map<int,int>` 56，`deque<Row>` 80。

单个 cell：

| 形态 | 行内 | 额外堆 | Thrift |
|------|------|--------|--------|
| INT / double | 16 | 0 | 12 |
| `__EMPTY__`（默认 `Value()`，不是 `NullType`） | 16 | 0 | 1 |
| STRING `"beauty"`（6 字节，SSO） | 16 | 一个 `string` 对象 | 14 |
| LIST | 16 | `List` 对象（24 字节）加 `vector` 缓冲 | 13 + 元素 |

INT 的 Thrift 是字段头 3 字节 + i64 8 字节 + field stop 1 字节。空 `Value` 只有 field stop。LIST 的 13 字节是 `lVal` 字段头、`NList` 的 list 头和两边的 field stop。`DataSet` 的一行在 C++ 里就是 `List`，wire 上是 thrift `Row`：Binary 协议不写结构名，两者字节相同，都是 9 + 各 cell。

---

## 2. 公共的存放方式

`ExecutionContext::valueMap_` 是 `unordered_map<string, vector<Result>>`。`Result` 的核是 `shared_ptr<Value>` 加 `unique_ptr<Iterator>`。算子 `finish` 把结果 `setResult` 进输出变量，再 `drop()`：输入变量的 `userCount` 减到 0 就 `dropResult`。`FLAGS_enable_lifetime_optimize` 默认 true。所以峰值一般是「本算子正在建的输出 + 还没 drop 的输入」，不是整条流水线叠在一起。详见 [14](14-data-flow.md)。

`Iterator` 不拉子算子。`SequentialIter` 走已经建好的 `vector<Row>`。`GetNeighborsIter` 只在 `ExpandAllExecutor::handleResponse` 里临时包一层，把各 host 的 `DataSet` 收成 `List`，按顶点行、再按边 list 走。`size()` 是边数，`numRows()` 是顶点数。它不是 `ExpandAll` 的输出。输出是 `buildResult` 推进去的普通 `DataSet`，`ResultBuilder` 默认套 `SequentialIter`。

storaged 侧两条路径：

- 邻居：`GetNeighborsNode::doExecute` 对一个 VID 写一行。边由上游 `IterateNode::next` 拉出来，`collectEdgeProps` 填进内层 `List`，再 `emplace` 到外层 `List`。外层不 `reserve`。
- 索引：`IndexScanNode::doNext` / `IndexEdgeScanNode::decodeFromIndex` 一次返回一行 `Row`。`IndexProjectionNode::project` 对输出行 `reserve(列数)`。`LookupProcessor` 先放进每个 part 的 `deque<Row>`，等全部 part 结束后再 `emplace` 进 `resultDataSet_`。这个 vector 不 `reserve`，容量按 2 倍涨。

拷贝和移动：

- INT / double 的拷贝就是 16 字节。
- STRING 拷贝会再 `new` 一个 `string`。
- `ExpandAll` 对每条边 `eval` 出新的 `Value`，RPC 里的嵌套 `DataSet` 要等到 `handleResponse` 返回才析构。
- `HashInnerJoin` 在较小的一侧建 `unordered_map<Value, vector<const Row*>>`（单键）。probe 侧除了最后一行是 `move`，每一行都拷进新 `Row`；`newRow` 会 `reserve(左宽+右宽)`。`runMultiJobs` 对输出行 `reserve` 到本批行数。`FLAGS_max_job_size` 默认 1，一批就是全部行。
- `Dedup` 用 `robin_hood::unordered_flat_set<const Row*>`，`unstableErase` 就地 `pop_back`，不缩容量。
- `Aggregate` 的表是 `unordered_map<List, vector<unique_ptr<AggData>>>`。每个 `AggData` 构造时都 `new` 一个空 `Set`（`unordered_set<Value>`），SUM 也不例外。
- `TopN` 把前 `offset+count` 行拷进一个 `vector<Row>` 做堆，写回原向量后 `eraseRange`。容量不缩小。
- 根上的 `QueryInstance::fillRespData` 对根变量 `moveValue`，再 `moveDataSet` 进 `ExecutionResponse.data`。

---

## 3. q_users（flag 关）

语句和 [12](12-scenario2-bench.md) 一致。PROFILE 行数：`TagIndexPrefixScan` 382，`ExpandAll` 40415，`HashInnerJoin` 40415，`Dedup` 4000。graphd 上没有留下 `Filter`：`buy.ts > cutoff` 在 `ExpandAll.filter` 里，随 `GetNeighbors` 下推。边属性来自 PROFILE：`[{"props":["_dst","ts"],"type":-18}]`，边列别名 `buy.ts AS __COL_0`、`buy._dst AS __COL_1`。

`std::set` 把属性排成 `_dst`、`ts`。`REVERSELY` 使 edge type 为负，列名是 `_edge:-buy:_dst:ts`。`buildYields` 无论有没有表达式都追加 `_expr`。`GetNeighborsNode` 先放 VID 和空的 `_stats`，再 `resize` 出边列和 `_expr`。没有命中边时边列保持 `__EMPTY__`，不是空 list。382 个商品是否都有窗口内的边，[12](12-scenario2-bench.md) 没给。下面「均分」假设每个顶点都有边（305 个 106 条，77 个 105 条），只用来量外层 list 的容量；另一端是 40415 条边全在一个顶点上。

| 算子 | 输出 | 行 | Iterator / 存放 | 堆（glibc，字节） | Thrift |
|------|------|----|-----------------|-------------------|--------|
| storaged `IndexVertexScanNode` + `IndexProjectionNode` | 列 `item._vid, item._tag, item.name, item.type`。`_vid`/`_tag` 是 INT，`name` 是 `i{iid}`，`type` 是 `"beauty"`。`id(VERTEX)` 会把 tag 上全部字段收进 `returnCols`（PROFILE 就是这四列） | 382 | `IndexNode::next` 一行。part 的 `deque<Row>`，再移进 `DataSet` | 未按 part 切分单测。整表按 emplace 增长：**70,376**，容量 512 | `DataSet` **22,778**；`LookupIndexResp`（含空的 `stat_data`）**22,825** |
| graphd `IndexScanExecutor` | 行拷进新 `DataSet`，`colNames` 改成节点上的名字：`_vid, item._tag, item.name, item.type` | 382 | `kProp`，输出变量 | 与上一行同形状。`insert` 区间会按距离分配，接近 reserve 的 **67,256** | 不再编码 |
| `Project`（`id(VERTEX) AS id`） | 一列 INT `id` | 382 | `SequentialIter`。`rows.reserve` | 按 emplace 不 reserve 外层测得 **21,512**（容量 512）。真正的 Project 会 reserve 到 382，差在 KB，未再单测 | — |
| `Argument` | 一列 INT，`VidHashSet` 去重 | 382 | `SequentialIter`。`rows.reserve` | 哈希集合本身 **18,680**（不含输出行） | — |
| `Expand`（0 步，`joinInput`） | 两列 INT：`_expand_vid`、`_expand_dst`，值都是商品 VID。不发 RPC | 382 | `SequentialIter` | 未单测。382×2 个 INT，远小于后面的边 | — |
| storaged `GetNeighborsNode` | 每 VID 一行，四列：`_vid` INT，`_stats` EMPTY，`_edge:-buy:_dst:ts` 为 `list<list<Value>>`（内层顺序 `_dst` INT、`ts` INT），`_expr` EMPTY | 382 行顶点，里面 40415 条边 | 一个 VID 一次 `doExecute`。边来自 `IterateNode` | 均分：**3,421,016**（外层容量 512，外层 list 多出的槽 8481）。全挤在一个顶点：**3,679,136** | 均分 `DataSet` **1,509,173**，响应 **1,509,200**。单顶点 `DataSet` **1,504,601**，响应 **1,504,628**。差 4,572 字节 |
| `ExpandAll` | 列 `_expand_vid, __COL_0, __COL_1`，全是 INT（商品 VID、ts、用户 VID）。`buildResult` 不 `reserve` | 40415 | 内部临时 `GetNeighborsIter`；输出 `SequentialIter` | **4,486,840**，行容量 65536，每行 cell 容量 4（3 个值涨到 4） | — |
| `HashInnerJoin` | `id, _expand_vid, __COL_0, __COL_1`，全 INT。382 < 40415，哈希建在左表 | 40415 | `SequentialIter`，行向量 `reserve(40415)` | 输出 **3,879,856**（cell 容量 4）。左表加哈希表 **52,048** | — |
| `Project`（`$__COL_1 AS user`） | 一列 INT `user` | 40415 | `SequentialIter`，`reserve(40415)` | **1,940,192**，cell 容量 1 | — |
| `Dedup` | 同一份 `DataSet` 就地删到 4000 行。容量仍是 40415 | 4000 | `SequentialIter`，`robin_hood` 存 `const Row*` | 删完之后 **1,066,152**。`std::unordered_set<const void*>`（reserve 40415，不是 robin_hood）在满表之上再加到 **3,246,496**。robin_hood 槽位估算见第 7 节 | 最终 `ExecutionResponse` 的 `DataSet` 与 4000 个 INT 相同：**84,025**；外壳 **84,047** |

`ExpandAll` 的峰值估算是嵌套响应和解码后的扁平表同时存在：均分时 `3421016 + 4486840 = 7,907,856` 字节。这是两个实测数相加，不是 graphd 里采的 RSS。`handleResponse` 返回后嵌套结构释放，扁平表留下。Join 开始时左表（382 行）和 `ExpandAll` 的输出都还在，Join 再分配自己的 40415 行。

---

## 4. q_sales

和 q_users 同一条 `GetNeighbors` 路径。PROFILE：`ExpandAll` 40415，`Aggregate` 4000，`TopN` 100。边属性 `["_dst","amount","ts"]`，别名 `__COL_0`（ts，INT）、`__COL_1`（`_dst`，INT）、`__COL_2`（`amount`，double）。列名 `_edge:-buy:_dst:amount:ts`。

| 算子 | 和 q_users 的差别 | 堆（glibc） | Thrift |
|------|-------------------|-------------|--------|
| `GetNeighbors` | 内层三个值：INT、double、INT | 均分 **4,067,624**；单顶点 **4,321,816** | 均分响应 **1,994,187**；单顶点 **1,989,615** |
| `ExpandAll` | 四列：`_expand_vid, __COL_0, __COL_1, __COL_2`。cell 仍涨到容量 4 | **4,482,768**，行容量 65536 | — |
| `HashInnerJoin` | 五列。`newRow` `reserve(5)`，本机 cell 容量就是 5 | **4,526,496**（行容量 40415）。不 reserve cell、涨到 8 的对照是 **6,466,400**，那不是这条路径 | — |
| `Project` | `uid` INT、`amt` double。cell 容量 2 | **2,586,576** | — |
| `Aggregate` | 键是只含一个 INT 的 `List`。每组两个 `AggData`（uid 和 `sum`），各带一个空 `Set`。输出两列，`reserve(4000)` | 哈希表 **1,600,248**（bucket 4027）。输出 **256,024** | — |
| `TopN` | 堆上最多 100 行，写回后 `eraseRange`。外层容量保持聚合时的 4000 | 单独建的 100 行是 **6,424**。留在 4000 容量里的空 `Row` 槽是 `(4000-100)×24 = 93,600` 字节，这是 `sizeof(Row)` 的算术，不是 usable | `DataSet` **3,333**；`ExecutionResponse` **3,355** |

`AggData` 的空 `Set` 比 4000 行的输出大。1,600,248 对 256,024。SUM 用不到这个集合，构造函数仍会分配。

---

## 5. q_model

语句是 `LOOKUP ON buy WHERE item_type AND ts YIELD src(edge)`，没有 `DISTINCT`。PROFILE：`EdgeIndexPrefixScan` 40415，`Project` 40415。索引条件已经在 column hint 里（`item_type` 前缀，`ts` 开区间），graphd 上没有 `Filter`。

`returnCols` 是 `["_src","_dst","_rank","_type","amount","item_type","ts"]`。`LookupValidator` 先种下 `_src,_dst,_rank,_type`。`src(edge)` 的参数是 `EdgeExpression`，`DeducePropsVisitor::visit(EdgeExpression)` 在 `edgeTypes_` 非空时把该边上的**每个字段**都插进 `exprProps`（`schemaIds_` 被当作 edge type 传进去）。`amount` 既不在 YIELD 里，也不在 WHERE 里，还是进了返回列。`item_type` 在索引上是 `FIXED_STRING`，`IndexScanNode::init` 不把它从「还要读基线」的集合里擦掉，`amount` 又不是索引列，所以 `needAccessBase_` 为真：每一行还要读边本身，字符串是基线上的 `"beauty"`，不是索引里截断的 16 字节。

| 算子 | 输出 | 堆（glibc） | Thrift |
|------|------|-------------|--------|
| storaged `IndexEdgeScanNode` → `IndexProjectionNode` | 七列，顺序同上。四个 key 字段和 `ts` 是 INT，`amount` 是 double，`item_type` 是 STRING `"beauty"` | part 的 `deque` 装下全部 40415 行：**7,477,616**。移进不 `reserve` 的 `vector` 之后，两者重叠的峰值 **9,836,928**；deque 清空后 vector **8,080,792**，容量 65536，cell 容量 7 | `DataSet` **3,839,533**；`LookupIndexResp` **3,839,580** |
| graphd `IndexScanExecutor` | 同一批行。`insert` 已知长度，容量按 40415 而不是 65536 | **7,436,568** | — |
| `Project`（`src(EDGE) AS user`） | 一列 INT | **1,940,048**，容量 40415 | `DataSet` **848,740**；`ExecutionResponse` **848,762** |

投影之前，输入的七列和输出的一列同时在：`7436568 + 1940048 = 9,376,616` 字节（两个实测相加）。`userCount` 到 0 之后七列被 drop。

---

## 6. flag 开的 q_users：`GetDstBySrc`

[12](12-scenario2-bench.md) 的 PROFILE：`Expand` 4000，`vertices: 4000`，没有 `ExpandAll`。单 storaged 上 host 内去重就是全局的 4000。多 host 时每个 host 各去重一次，graphd 的 `Dedup` 还在；host 数未知，本文不外推行数。

`GetDstBySrcResponse.dsts` 是一列 `_dst`。去重前 `flatResult_` 有 40415 个 INT。实测：这个 vector（容量 65536）**1,048,584**；加上 `std::unordered_set<Val>`（同样不是 robin_hood）**1,545,264**；再加 4000 行输出 **1,737,272**。响应 Thrift **84,052**。相对 flag 关的 `GetNeighbors` 响应 1,509,200，应用层大约小 18 倍。补丁没有改这个 `DataSet` 的形状，只是让这条语句走到它。

---

## 7. 优化空间

收益用上面的字节比。难度和兼容性是对 v3.8.0 这套 Thrift / `Value` 接口的判断，不是工期。

| 方向 | 收益量级 | 难度 | 兼容 | 和下推的关系 |
|------|----------|------|------|----------------|
| q_users 只回 VID（已有 `getDstBySrc`） | 响应 1,509,200 → 84,052，约 18 倍。graphd 不再摊 40415 行 | 已实现，默认关 | 要整集群认识新请求字段，见 [11](11-scenario2-beauty-buyers.md) | 和「DISTINCT 下推到 host」重叠。时间过滤在 flag 关时已经进 `GetNeighbors`。q_sales、q_model 走不到 |
| q_model 别回没 YIELD 的列 | 响应 3,839,580 → 一列 INT 的 `DataSet` 848,740，少约 3.0 MB（78%）。堆从 7,436,568 降到 1,940,048 | 中。改 `visit(EdgeExpression)` 的「整条边所有字段」，或在索引 return 列里丢掉 WHERE 已经用掉、YIELD 没提到的属性 | 中。用户可见列只有 `user`。EXPLAIN 的 `returnCols` 会变。若有执行器读 `_dst` 以外的内部列会坏 | 这是投影下推没做完的那一块，不是邻居过滤下推。补丁碰不到 |
| 只含 VID 的紧凑列 | 4000 个 int64 逻辑上 32,000 字节；裸 `list<i64>` 是 **32,005**。现在一列 INT 的 `DataSet` 是 **84,025**（约 2.6 倍），每个 cell 还占 16 字节行内空间 | 高。`Value` 是 16 字节的 union，Thrift 是公开结构 | 高。客户端和 `SequentialIter` 都认 `DataSet` | 与下推正交。下推减少行数，这个减少每行的常数 |
| 列式 / 一批 Arrow | q_model 七列里 6 个标量可以并成连续数组。本机把 40415 个 double 相加，行式 `Val` 中位 **0.069 ms**，列式 **0.020 ms**（50 次，只加这一列，不是整条查询）。[12](12-scenario2-bench.md) 里 q_model 并发 1 的 server P50 是 79.68 ms，这个循环不是大头 | 高。执行器、表达式、RPC 都要换批次 | 高 | 正交。过滤下推减少的是行，不是 cell 的 16 字节 |
| 延迟物化 | 和「别回没 YIELD 的列」是同一笔钱：`amount` 和 `item_type` 在 `Project` 里被丢掉之前已经从基线读出来了 | 低到中，如果只改 return 列、不改 `Value` | 同上一行 | 就是投影下推 |
| 去掉 `ExpandAll` 和 RPC 嵌套的同时存活 | q_users 均分：嵌套 3.42 MB + 扁平 4.49 MB。边可以边解码边写入输出行 | 中。`handleResponse` 和 `GetNeighborsIter` | 低，只要输出仍是现在的 `DataSet` | q_users 上和 `getDstBySrc` 重叠（那条路径没有嵌套）。q_sales 仍要金额，嵌套还在 |
| 流式 / 分批，压 200 并发的峰值 | 现在一个算子持有全部 40415 行。200 × 7,436,568 = 1.49×10^9 字节。能把峰值从「并发 × 全量」收成「并发 × 一批」 | 高。调度器等整个算子的 future，见 [13](13-control-flow.md) | 中。结果语义不变，但背压和错误处理要重做 | 不重叠。q_model 没有 `LIMIT`，`PushLimit` 帮不上。水位本身是系统 available，见下 |
| `Dedup` 的哈希表 | 已经是 robin_hood 的 `Row*`，不是值拷贝。`reserve(40415)`、80% 负载、容量取 2 的幂到 65536：`65536×(8+1) = 589,824` 字节，**估算**。对照的 `std::unordered_set<const void*>` 实测多占 **1,306,304**。删到 4000 行后容量仍是 40415，堆 **1,066,152** | 低，若只 `shrink_to_fit`。换哈希表没有收益 | 低 | 不重叠。host 内去重已经在 flag 开的路径上 |
| `Aggregate` 的空 `Set` | 4000 组的表 **1,600,248**，输出只有 **256,024**。SUM 可以不分配 `Set` | 低。`AggData` 构造函数 | 低。`COLLECT` 仍要集合 | 不重叠。按 dst 的 SUM 下推到 storage 是另一件事，`AggregateNode` 只做单个 src 的标量，见 [11](11-scenario2-beauty-buyers.md) |
| 拆掉 `GetNeighbors` 的双层 `List` | 每条边两次堆分配（外层 list 的元素 + 内层 `List`）。均分时堆 3.42 MB，wire 只有 1.51 MB | 高。`storage.thrift` 的列布局是公开的，`GetNeighborsIter` 按这个嵌套走 | 高 | q_users 被 `getDstBySrc` 绕开。q_sales 若要少分配，得改响应，而不是再推一次 `ts` 过滤 |

水位：`MemoryUtils.cpp` 里 `(1 - available/total) > FLAGS_system_memory_high_watermark_ratio`，比例默认 0.8。这是 cgroup 或 `/proc/meminfo` 的整机数。[12](12-scenario2-bench.md) 的失败文案就是这条。`load_meta.json` 记下 `MemTotal` 16387280 kB、`MemAvailable` 9019344 kB，那是加载时的快照，不是失败那一瞬间。用它做算术：available 要降到 `0.2 × 16387280 = 3277456` kB 才触发，快照上的余量是 5741888 kB（约 5.48 GiB）。1.39 GiB 的七列结果落在这个余量里。所以「表示太大，所以 200 并发一定越过 0.8」这句话，单靠这份 `DataSet` 说不满。分批仍然线性地降低 graphd 上的峰值，Python 侧解码 40415×7 列也同样受益于少回列。

没有把这些改动打进 `patches/`。低风险、数字已经量过的是 q_model 的返回列和 `AggData` 的空 `Set`。前者动的是校验器收集的属性，要补 LOOKUP 的用例，确认 `src(edge)` / `dst(edge)` 不再把 `amount` 带上，同时 WHERE 里的列在索引能判断之后不再出现在 `returnCols`。本文停在测量，没有改执行器。

---

## 8. 和 11 / 12 / 13 / 14 的边界

[11](11-scenario2-beauty-buyers.md) 写计划为什么长这样，以及补丁切的是哪一条 RPC。[12](12-scenario2-bench.md) 写这台机器上的时延、QPS 和 PROFILE 行数，并明确没有字节。[13](13-control-flow.md) 写算子一次跑完。[14](14-data-flow.md) 写 `Result` 和 `userCount`。本文只补这三条语句的列布局、cell 和字节。均分扇出、jemalloc 的 size class、多 host 上 `getDstBySrc` 的重复 VID，都没有当成实测。
