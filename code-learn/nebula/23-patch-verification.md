# NebulaGraph v3.8.0 下推 patch 验证报告（v3，2026-10-27 终版）

**基线**：vesoft-inc/nebula tag `v3.8.0` = `fa928930ab34f150db522933323aa610e54f26e7`（2024-05-17），与文档 README 锚定的 hash 完全一致。
**对照**：已额外拉取 `origin/master` = `426266b5c3df856d27f747b55b916dec542b7b59`、`origin/release-3.8` = `15fc0b7a12ba69b3977c6f4a9d70d15ec7f98742`、`v3.6.0` = `de9b3ed80`，**文档里所有跨版本断言现在都能核**。
**文档**：cybrid-systems/ai-programming-language-design → code-learn/nebula/（22 篇 md + 3 个 patch + 3 个 poc-repr patch）。

---

## 一、结论速览

| 对象 | 状态 |
|---|---|
| `patches/v3.8.0-dst-only-edge-filter.patch` (P1) | apply 干净；**单独编译不过**（9 个 overloaded-virtual），修好后通过 |
| `patches/v3.8.0-partial-edge-agg.patch` (P2) | **有 2 处真实缺陷**，修好后通过；**必须叠在 P1 之上** |
| `poc-repr/v3.8.0-aggdata-lazy-set.patch` | apply 干净 |
| `poc-repr/v3.8.0-returncols-key-funcs.patch` | apply 干净 |
| 修好后整树编译 | **0 error / 0 link error**，三个 daemon 产出且可执行 |
| 新增 gtest | **23 个测试全过**（10 + 5 + 8，3 个 suite） |
| ctest 全量回归 | **146/146 通过**，无回归 |

---

## 二、三个真实缺陷（比 v1 报告多一个）

### 缺陷 1（阻断性，P2）：`git apply` 直接失败

5 个新增文件的 diff 头缺 `new file mode 100644` 和 `--- /dev/null`，只有 `index e69de29..<hash>` + `--- a/<path>`：

- `src/common/function/PartialAgg.h`
- `src/graph/optimizer/rule/PushPartialEdgeAggRule.h`
- `src/graph/optimizer/rule/PushPartialEdgeAggRule.cpp`
- `src/graph/util/EdgePushdown.h`
- `tests/tck/features/go/PartialEdgeAgg.feature`

结果：`git apply --check` 报 `error: src/graph/util/EdgePushdown.h: No such file or directory`；而 `patch -p1` 会**猜成新文件并成功**——所以它能蒙混过关，但在干净树上实际有 **10 个 hunk 失败**（storage.thrift #2；GetDstBySrcNode.h #1/#2/#4；GetDstBySrcProcessor.cpp #1-#4；.h #1/#2）。

### 缺陷 2（阻断性，P2）：编译不过

上游约定（`ExtractFilterExprVisitor.h:64`）在 visitor 类里写 `using ExprVisitorImpl::visit;`，否则派生类的 `visit(UnaryExpression*)` 等 override 会**遮蔽**基类其余 31 个 overload，触发 `-Werror=overloaded-virtual`。P2 的 `EdgePushdownVisitor` 缺这一行，炸在两个 include 它的 TU：`GoValidator.cpp` 和 `PushPartialEdgeAggRule.cpp`（错误实际报在头文件 `src/common/expression/ExprVisitorImpl.h` 里）。

> doc16 L155 把这条记成「PLAUSIBLE」——现在是 **CONFIRMED**。

### 缺陷 3（阻断性，**P1 也有**，v1 报告漏了）：P1 单独也编译不过

P1 的 `DstOnlyEdgeFilterVisitor` 同样缺 `using ExprVisitorImpl::visit;`。在**只打 P1** 的干净 v3.8.0 上做语法编译，得到 **9 个** overloaded-virtual 错误（`ExprVisitorImpl.h` 的 19/33/36/37/40/42/45/46/47 行全部被遮蔽）。补上那一行后，P1 触及的 7 个 TU 全部 0 error。

**v1 报告写的「P1 单独可编译」是错的**，这里更正。

**为什么整套打就没事**：P2 会把 P1 的 `DstOnlyEdgeFilter.h` 整体重写成一行 `return EdgePushdown::canPush(expr);`（P2 的 hunk `@@ -6,141 +6,18 @@`），把有问题的 visitor 类整个删掉——所以 P1 的缺陷被 P2 顺手盖住了。**只打 P1 就会炸。**

### 修好的 patch（在 `patches/`）

- **P1**：只加一行 `using ExprVisitorImpl::visit;`。
- **P2**：修 5 个 new-file 头 + 给 `EdgePushdown.h` 加 `using ExprVisitorImpl::visit;`。

两份都是用 `git diff` 重新生成的（不是手改 patch 文本），所以 **P2 依然叠在修好的 P1 之上**：

```
git apply --check v3.8.0-dst-only-edge-filter.patch   -> OK   (pristine v3.8.0)
git apply --check v3.8.0-partial-edge-agg.patch       -> OK   (叠在修好的 P1 上)
+ poc-repr 两个 patch                                -> OK
结果树 vs 已编译通过的 /tmp/neb-full                  -> diff -rq 无差异（逐字节相同）
```

---

## 三、Patch 语义核对（都成立）

- 规则注册没问题：自注册模式（`RuleSet::QueryRules().addRule(this)`），和 `TopNRule` 一样，不存在「漏注册」。
- graphd 确实把 1 步 `GO ... YIELD DISTINCT edge._dst`（带纯边属性谓词）路由进 `getDstBySrc`，由 storage 逐边过滤。
- storage 侧确实逐边求值，且**故意不调** `checkExp`（否则会破坏 `propContexts_`），`maySkipDecode` 被强制为 false 保证值真的被解码。
- 被 filter 掉的边**不消耗** limit（这个修得对）。
- 回退路径 `fallbackPartialAgg()` 真实存在：任一 host 的响应没有 `partial_agg` 位，graphd 就用保存的源 VID 列表重发 `getNeighbors`（同一 filter + edgeProps），在 graphd 侧重建分组，结果等价，多一次 RPC。
- thrift 字段全 optional；`filter` 字段**没有响应确认位**，旧 storaged 会静默忽略过滤并返回未过滤结果 → **启用前必须升级全部 storaged**。`partial_agg` 特意加了确认位正是为了避开这点。
- P2 的 `EdgePushdown::canPush` 会拒绝 `now()`、零参 `timestamp()` 等非纯函数——**这是相对 P1 的行为变更**（P1 的单测里 `buy.ts > now()` 原本是可下推的）。

---

## 四、跨版本断言核验（最大覆盖缺口，已闭合）

三个版本都拉下来后，文档里所有「v3.8.0 与 master 无差异」类断言**全部可核，且基本全部成立**：

| 文档断言 | 核验结果 |
|---|---|
| 01/10：v3.8.0 与 release-3.8 optimizer 树相同 | ✅ **0 个文件不同** |
| 01/10：master 只差 `GeoPredicateIndexScanBaseRule.cpp` | ✅ **恰好这 1 个文件** |
| 06：`NebulaKeyUtils.*`/`Types.h` 两版相同 | ✅ diff 为空 |
| 08：`encodeInt64/encodeDouble/encodeValues/vertexIndexKeys` 相同 | ✅ 四个函数体 md5 相同 |
| 13：所引文件两版无差异 | ✅ diff 为空 |
| 13：§1.4 master 未向量化 | ✅ master 全树无 immintrin/avx2/emmintrin |
| 20：`GetNeighborsProcessor` 列布局相同 | ✅ diff 为空 |
| 04：master 的 limit 逻辑是 `if (*limit_ref >= 0) limit = *limit_ref;` | ✅ 逐字一致 |
| 04：v3.6.0 的 limit 逻辑 | ✅ **文档贴的代码和 v3.6.0 实际代码逐字相同** |
| 03/05：v3.6.0 无 parser 折叠 | ✅ v3.6.0 命中 0 次 / v3.8.0 命中 1 次 |
| 03/05：v3.6.0 无 `PathPlanner::setLimit` | ✅ v3.6.0 命中 0 次 |
| 03：v3.6.0 已有 AllPaths/ExpandAll 下推规则 | ✅ 两个规则文件在 v3.6.0 已存在 |
| 07/09：master 行格式多出 LIST/SET | ✅ RowWriterV2 +163 / RowReaderV2 +97 / SchemaProvider +8 行 |
| 08：master 拒绝 LIST/SET 建索引 | ✅ `CreateTagIndexProcessor.cpp:148-153` |

**唯一要收紧的**：doc 08 L5 说 `encodeInt64/encodeDouble/encodeValues/vertexIndexKeys` 相同——这四个函数确实逐字相同，但**所在文件** `IndexKeyUtils.h` 在 master 上多了 8 行（LIST_*/SET_* 的类型映射）。结论对，范围应写「这四个函数」而不是「文件相同」。

---

## 五、文档错误清单（逐条对源码核过）

### 机制说错（结论可能仍成立，但推理是反的）

- **doc 03 L17/91/100/161、doc 05 L114/159**：Scan 默认 limit 是 **-1 不是 int64 max**，且 `ScanVertices`/`ScanEdges` 在 `src/graph/planner/plan/Query.h:822/887`，**不在** `Scan.h`（`Scan.h` 里只有 IndexScan 子类，它们的默认才是 int64 max）。是 **storage 侧**把负数转成 int64 max（`ScanVertexProcessor.cpp:32`）。
- **doc 15 L194**：规则顺序解释反了——P2 把 `PushPartialEdgeAggRule.cpp` 插在 `PushFilterDownExpandAllRule.cpp` **之前**（patch:457/459），自注册按链接序 → 部分聚合规则**先**注册；真正让它生效的是优化器**迭代到不动点**（`Optimizer.cpp:76-96` 的 `while (octx->changed())`），不是规则顺序。
- **doc 15 L50 vs doc 16 L25 自相矛盾**：MIN/MAX 初始状态是 `Value::__EMPTY__`（`Value.h:86`），不是 NULL。
- **doc 14 L110**：内存高水位实际是 **抛 `std::runtime_error`**（`Iterator.cpp:16-30`），`Iterator::valid()` 返回的是 `!hitsSysMemoryHighWatermark()` 即 true。「优雅结束迭代」这个降级路径不存在。
- **doc 14 L188/198/200**：`TraverseExecutor` 没有 `paths_` 成员（`grep -rn 'paths_' src/graph/` 只有两条**注释**），真身是 `dst2PathsMap_`（`VertexMap<Row>`，`TraverseExecutor.h:102`），是按 dst VID 的扁平 map，不是按路径长度分数组。
- **doc 09 L73 / doc 06 L144**：v3.8.0 的 INSERT EDGE 走不到 TOSS 写路径——`useChainInsert` 有人写没人读（getter 零调用者），`InsertEdgesExecutor` 硬编码 `useExperimentalFeature=false`。
- **doc 21 L221/265**：`enable_dst_only_edge_filter` **不是** v3.8.0 原有代码（`rg 'dst_only|dstOnly|dst-only' v3.8.0` 零命中），是本仓库 patch 引入的；§3.2/§5.1 把它当既有行为讲。
- **doc 20 L147**：`GetDstBySrc` 去重容器是 `robin_hood::unordered_flat_set<Value, std::hash<Value>>`（`GetDstBySrcProcessor.cpp:282`），不是 `std::unordered_set<Val>`。
- **doc 06 L161**：`schemaTagKey` 存的版本号是**反转的**（`max() - version`，`MetaKeyUtils.cpp:596-605`），所以新版排在前面；文档的平铺描述漏了这个影响排序的细节。
- **doc 02 L84**：`follow.degree` 在 parser 里**不是** `EdgePropertyExpression`——`edge_prop_expression` 语法只产 Type/SrcId/DstId/Rank（`parser.yy:1026-1043`），`follow.degree` 走 `name_label DOT name_label`（:849）成为 `LabelAttributeExpression`，之后才被 `rewriteLabelAttr2EdgeProp` 改写。doc 02 自己的 §3.1 写对了，全文自相矛盾。

### 描述不精确

- **doc 03 L23**：「`limit->countExpr()` 必须 `isEvaluableExpr`」不是共同条件——15 条 limit/step/topN 规则里只有 **8 条**有这句。
- **doc 03 L31**：`PushLimitDownScanEdgesAppendVerticesRule` 的 pattern 多一层 `Project`（实际 `Limit→AppendVertices→Project→ScanEdges`）。
- **doc 03 L37 vs doc 10 L25 自相矛盾**：`PushTopNDownIndexScanRule` 的 pattern 是 `TopN→Project→IndexScan`，doc 03 漏了 Project，doc 10 写对了。
- **doc 03 L40**：`PushStepLimitDownGetNeighborsRule` 克隆的是**外层 LIMIT 的 count 表达式**（`newGn->setLimit(limit->countExpr()->clone())`），不是「step limit 表达式」；step limit 只当比较用的守卫。
- **doc 02 L37**：`PushFilterDownAllPathsRule` 的额外匹配条件是 `edgeProps != nullptr && !edgeProps->empty()`，不是「子表达式可下推」。
- **doc 04 L87**：`PushVFilterDownScanVerticesRule` 写的是 `ScanVertices::setFilter`，走 **scanVertex** 路径，不是 `GetPropProcessor`。
- **doc 05 表**：`Explore::explain` 对**所有** Explore 子类都吐 `space/dedup/limit/filter/orderBy`（`Query.cpp:36-44`），不止表里列的那几个。
- **doc 13 L280**：`isSimpleCase` 的边属性检查实际是 `props.size() != 1 && props.find(kDst) == props.end()`（`GoValidator.cpp:301`）——**只拒多属性且缺 _dst**；单个非 _dst 边属性能过这关、只被后面的 yield 列检查拒掉。文档写得比代码严。
- **doc 14 L79**：`Executor::finish` 的 `drop()` 是 **`if (FLAGS_enable_lifetime_optimize)`** 条件下的（`Executor.cpp:744-746`），不是无条件。
- **doc 07 L81**：DATETIME 头注释写 `15 bytes`（`RowWriterV2.h:64`），`fieldSize` 实际是 **11**（`NebulaSchemaProvider.cpp:158-165`）。
- **doc 07 L167**：TTL 列类型白名单（INT64/TIMESTAMP）在 `src/storage/CommonUtils.cpp:33-37`，不在 `SchemaUtil`。
- **doc 09 L79**：`GetPropNode` 只经 `tagKey` 读顶点/标签行；边属性走 `FetchEdgeNode`/`edgeKey`。
- **doc 09 L93**：索引扫描的计划根是 `IndexVertexScanNode`/`IndexEdgeScanNode`，不是裸的 `IndexScanNode`。
- **doc 06 L35**：partId 是**高** 24 位、type 是低 8 位；partId 溢出是截断自己的高位，**不会**和 type 重叠。失败模式描述反了。
- **doc 13 L226-227**：`PassThrough`/`Argument` 的构造点清单不全（漏 `SetValidator.cpp:82` 等）。
- **doc 20 L136**：`reserve(40415)` 是 libstdc++ `vector::insert` 的增长副作用，不是源码保证。

### 数字类（不可从源码验证）

doc 20/21 的绝对字节数与堆数字来自 `poc-repr/measure.cpp` 的**进程级实测**，不是源码事实（宽度模型本身可复现，且逐字节复现 doc 20 的 84,025 / 84,052 / 84,047）。另外 doc 20 L24 与 doc 21 L36 的 7 列宽度**互相差 32 字节**（7,436,568 vs 7,436,536），doc 20 的 1,487,313,600 推不出来。doc 20 L46 的「2000 items / 0.2」不是 `gen_data.py` 的默认值（200 / 0.15）。

---

## 六、aarch64 编译配方（实测，踩了 4 个坑）

```bash
# 1) third-party：官方 CDN 对本机 403，用 GitHub release 同名归档
curl -LO https://github.com/vesoft-inc/nebula-third-party/releases/download/v3.3/vesoft-third-party-3.3-aarch64-libc-2.34-gcc-11.2.0-abi-11.sh
sh vesoft-third-party-3.3-aarch64-libc-2.34-gcc-11.2.0-abi-11.sh   # 装到 /tmp/vesoft-tp-11

# 2) 编译器必须与 third-party 匹配（gcc-11/g++-11），且加 -march=armv8-a
#    否则 folly F14 会从 F14LinkCheck<1> 错配成 F14LinkCheck<2>，链接期炸
cmake -DCMAKE_C_COMPILER=gcc-11 -DCMAKE_CXX_COMPILER=g++-11 \
      -DCMAKE_C_FLAGS=-march=armv8-a -DCMAKE_CXX_FLAGS=-march=armv8-a \
      -DCMAKE_PREFIX_PATH=/tmp/vesoft-tp-11 ..
make -k -j$(nproc)
```

坑：

1. `pkill -f 'make -j14'` 会**误杀调用它的 shell 自己** → 用 `pkill -f '[m]ake -j14'`。
2. 查编译错误**不能**只匹配 `.cpp:[0-9]+:[0-9]+: error:`——本次两个错误都在**头文件**里（`ExprVisitorImpl.h`）。用 `grep -E 'error:'`。
3. third-party 版本必须和源码年代匹配（v3.8 用 v3.3 那套 aarch64 包）。
4. `-march=armv8-a` 不能省——folly F14 的 CRC32 模式依赖它。

---

## 七、复现命令

```bash
git clone --depth 1 -b v3.8.0 https://github.com/vesoft-inc/nebula.git /tmp/nebula38
git -C /tmp/nebula38 fetch origin '+refs/heads/master:refs/remotes/origin/master' \
                           '+refs/heads/release-3.8:refs/remotes/origin/release-3.8'
git -C /tmp/nebula38 fetch origin 'refs/tags/v3.6.0:refs/tags/v3.6.0'

cd /tmp/nebula38 && git worktree add --detach /tmp/t v3.8.0 && cd /tmp/t
git apply patches/v3.8.0-dst-only-edge-filter.patch
git apply patches/v3.8.0-partial-edge-agg.patch
git apply /tmp/apld-design/code-learn/nebula/poc-repr/v3.8.0-aggdata-lazy-set.patch
git apply /tmp/apld-design/code-learn/nebula/poc-repr/v3.8.0-returncols-key-funcs.patch

# 编译 + 回归
mkdir build && cd build && cmake .. && make -k -j$(nproc)
git apply patches/v3.8.0-dst-only-edge-filter-storage-test.patch

ctest --output-on-failure -j8          # 146/146
./bin/test/dst_only_edge_filter_test    # 15/15
./bin/test/get_dst_by_src_filter_test  # 8/8
```

---

## 八、仍未做（诚实边界）

- 没有在**真实 Nebula 集群**上跑端到端验收：TCK、`EXPLAIN` 对照、过滤/聚合结果比对、混合版本滚动升级、性能测试——都还没做。
- 所有**性能数字**（doc 17 的 1121 行 / 3 host / 397318.0 等）只在**源码层面自洽**，没有实测复现。
- 修好的 patch 与本文已推到设计仓库 `origin/main`（见第九节）。


## 九、已落地到设计仓库的更正（已推送 main）

在 `/tmp/apld-design`（`cybrid-systems/ai-programming-language-design` 的克隆）上：

- 已合入 `origin/main`：commit `347a6aa`（16 篇 md 的 43 处更正 + 两份修好的 patch）；后续 `4773a89` 补上 storage 专项测试 patch，本文随同一个提交进仓库。
- **16 篇 md 改了 43 处**（每个替换都做了「原文恰好出现一次」的断言，43/43 命中；再用「从上游 `origin/main` 出发逐条重放 43 个替换」的方式验证，结果树**逐字节相同**）。
- **2 个 patch 换成修好的版本**（P1 补 using 声明；P2 修 5 个 new-file 头 + 补 using 声明）。
- 用仓库里改好的 patch 重跑整条链：四份 patch 在 pristine `v3.8.0` 上全部 `git apply --check` 通过，结果树与已编译 + 已跑测的 `/tmp/neb-full` **逐字节相同**。
- 改过的 md 表格做过结构体检：与改前逐行对比，**新引入的表格错位 0 处**（原本就有的 12 处行/表头列数不齐是原文自带的，未动）。

已推送：`origin/main` `347a6aa`（文档更正与两份 patch）→ `4773a89`（storage-test patch 与本文）。


## 十、验证期间上游又动了一次

验证做到一半时，设计仓库的 `origin/main` 从 `3a638a2` 前进到 `7ff3a83`（`measure P0 IR latency against baseline`），新增了：

- `code-learn/nebula/22-ir-bench.md`（185 行）
- `code-learn/nebula/poc-repr/v3.8.0-exec-reserve-shrink.patch`（第 5 份 patch，给 `Iterator` 加 `shrinkToFit()`）
- `code-learn/nebula/poc-repr/ir-bench/*`（bench 脚本与结果）

处理：

- 本分支已 rebase 到新的 `origin/main`，提交由 `19df696` 变为 **`347a6aa`**；16 篇 md 的更正**全部保住**——只有 `21-ir-optimization-design.md` 因为上游也改了它而产生 6 增 5 删，两边内容都在（我的 2 处更正 + 上游的 P0 段落）。
- 新加的第 5 份 patch 在 **pristine `v3.8.0` 上 apply 干净**，叠在我改好的 P1 + P2 + 两个 poc-repr 之后**也干净**——五份一起 apply 全过。
- `22-ir-bench.md` 没有引用源码文件路径或符号，断言都是实测数字（P50/P95/P99、QPS、RSS）与估算，和本文对 doc 20/21 的源码级更正不冲突；它自己也写明「二进制不含 16 的部分聚合补丁」。它记的运行参数（用户 4000 / 商品 2000 / `beauty_ratio` 0.2）与本文对 doc 20 L46 的更正**一致**：那确实是那次运行的参数，不是 `gen_data.py` 的默认值。

---

## 十一、storage 级专项测试（2026-10-27 新增）

在本次验证的前半段，两个 patch 自带的 gtest（`dst_only_edge_filter_test`，15 个）只验证 **graphd 侧**：规则命中与表达式构造。
**storage 侧真正执行 filter 与部分聚合的那段代码从未被执行过**——包括 P1 的 `GetDstBySrcNode::passEdgeFilter()`，
以及 P2 的 `buildEdgeAggs()` + `mergePartialGroups()`。这正是下推类 patch 最容易「graphd 侧全对、storage 侧语义反了」的地方。

因此补了一个独立的 storage 级测试 `src/storage/test/GetDstBySrcFilterTest.cpp`（8 个 case），
直接构造 `GetDstBySrcRequest` 打给 `GetDstBySrcProcessor`，用 mock 集群的 serve 边数据断言 **返回值**：

| case | 断言的 storage 行为 |
|---|---|
| `BaselineWithoutFilter` | 无 filter 时 6 个 dst（Tracy McGrady 效力的 6 支球队）全在 |
| `EdgePropFilterKeepsOnlyMatchingEdges` | `teamAvgScore > 20` 后只剩 Magic(28.0)、Rockets(24.4) |
| `EdgePropFilterIsAppliedPerEdge` | **逐边**过滤：LeBron James 对 Cavaliers 有两条边(29.7/27.5)，只有过线的边计入；Lakers(25.7) 那条被丢掉 |
| `EdgePropFilterMatchingNothingYieldsNoDst` | 阈值 100 → 0 个 dst（不报错） |
| `EdgePropFilterOnUnknownPropIsRejected` | 不存在的属性 → `E_EDGE_PROP_NOT_FOUND`（`validateEdgeRef` 拦下，不进扫描） |
| `EdgePropFilterOnEdgeOutsideRequestIsRejected` | filter 引用未在请求里的边类型 102 → `E_INVALID_FILTER` |
| `PartialAggSumGroupsByDst` | P2 部分聚合：按 dst 分组求和，Cavaliers **548+301=849**（证明是 group-by-dst 而不是 per-edge），Heat 294、Lakers 115；`partial_agg=true`，列名 `_dst`/`_agg0` |
| `PartialAggRespectsFilter` | filter 与部分聚合**同时**下发时，只有过 filter 的边参与聚合 |

结果：**8/8 全过**。全量 ctest 随之变成 **146/146**（原 145 + 本测试 1 个 target），无回归。

- 测试源码与 CMake 条目已打成 patch：`patches/v3.8.0-dst-only-edge-filter-storage-test.patch`
  （在 pristine `v3.8.0` 上 `git apply --check` 干净）。
- **mock 的两个坑**（写这个测试时踩到的，写在这里免得下一个人再踩）：
  - mock 的 `AdHocSchemaManager::toEdgeName` 返回 **边类型的数字字符串**（`"101"`），不是 `"serve"`。
    所以 storage 侧的 `EdgePropertyExpression` 必须写 `"101"`；写 `"serve"` 会在 `validateEdgeRef` 里被 `toEdgeType` 解析失败。
  - mock 的 serve 边 **属性顺序**是 playerName/teamName/startYear/endYear/teamCareer/teamGames/teamAvgScore…，
    `teamAvgScore` 是 **DOUBLE**；拿它跟 INT 常量比会走 `Value::lessThan` 的 INT/FLOAT 混合分支（`kEpsilon=1e-8`），阈值取 20 这类整数边界值才安全。
- **仍未覆盖**（诚实边界）：真实集群端到端、TCK、混合版本滚动升级、性能；以及 P1 的 filter 字段
  **没有响应确认位**这件事本身——旧 storaged 会静默忽略 filter 并返回未过滤结果，这仍是上线前必须全量升级 storaged 的理由，
  本次验证没有改变它。
