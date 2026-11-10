# 46 — operator-opt 分支实测与下推前提校正

> 对照仓库：<https://gitcode.com/guoshaohong1/nebula>
> 对照源码：`v3.8.0` `fa928930ab34f150db522933323aa610e54f7`
> 分支：`operator-opt` `116b6a453dfd95d312a6ab0574d360d8a243570c`（2026-11-06）
> 基线：上游 `v3.8.0` `fa928930`，分支在其之上 11 个提交
> 行号锚点一律按 `v3.8.0` 基线计；`operator-opt` 上同名函数的行号见文末对照
> 日期：2026-11-10
> 状态：源码分析 + 本机单机集群实测（基线 `v3.8.0` 二进制）；分支 `operator-opt` 已单独编译并与基线 A/B 对照，见第 7 节；不是生产实现

---

## 0. 结论

1. `operator-opt` 的 11 个提交集中在**存储侧去重/截断下推**和**graphd 侧聚合性能**。分支**没有**实现聚合融合下推（存储侧局部聚合）、集合运算融合下推（MINUS），也**没有**任何 REVERSELY 专门处理。
2. 分支已经用一个**新的优化器规则**（而不是改 `isSimpleCase`）实现了管道计划下的去重下推：`Limit → Dedup → HashInnerJoin → ExpandAll(joinInput)` 被整体改写成一次存储侧 `Expand`。
3. 用 EXPLAIN 在本机集群实测了 nGQL 改写层面的前提，三条结论是**一正、一误、一半**：
   - ✅ `edge._dst` 走简单计划（`getDstBySrc`）：「改动 1」的方向是对的，EXPLAIN 证实。
   - ❌ REVERSELY 下 `edge._dst` 与 `src(edge)` **语义等价**，文档「改写会返回商品 B 的 VID、结果完全错误」的警告不成立。于是 Q6 第一跳的去重下推**不需要补丁**，改写即可拿到。
   - ⚠️ `LIMIT [N]` 是 GO 段的**逐步截断**，不是 per-vertex limit；而且它会让简单计划失效，与「改动 1」互斥。
4. 把分支单独编译后与基线 A/B（第 7 节），有两个本文原先不知道的事实：
   - **分支按现状编译不过**：`116b6a4` 给 `GetDstBySrcNode` 加了 `sharedDedupLimit_` 成员但没同步初始化列表顺序，项目的 `-Werror` 把 `-Wreorder` 变成致命错误。两行可修。
   - **补丁 A 确实存在**，但走的不是本文推测的路径：实测 Q3 opt 把 `HashInnerJoin + ExpandAll` 收成一次 `Expand`，Q5 / Q6 opt 把 `Project` 压到 join 之下。
   - **但结果在并列切分上不等价**：同样的语句、同样的数据，两个二进制返回的行集合不同。机制是聚合的分组输出顺序变了（上游 `unordered_map<List, ...>` vs 分支单键快路径 `unordered_map<Value, ...>`），遇到并列键时 `TopN` 切出的不是同一批。这直接限定了「多重集 SHA 相同」这个判据的适用范围。

---

## 1. 分支的 11 个提交

基线是上游 `v3.8.0`（`fa928930`），分支在其上线性叠加 11 个提交，作者 `guosh`，日期 2026-11-02 → 11-06。

| Commit | 主题 | 落点 |
|---|---|---|
| `787480f` | rank 有界边遍历 | `src/storage/exec/EdgeNode.h` 的 `RankBoundedKVIterator`；用 `_rank` 上下界在源点前缀内 seek/stop，只有 AND 合取可提取，其余回退前缀扫描 |
| `45757a5` | 投影下推进 HashInnerJoin | 新规则 `PushProjectDownHashInnerJoinRule`；仅对单消费者、join 列名唯一、可解析自然列布局的形态生效 |
| `1440120` | 去重与截断下推进 getDstBySrc | `GetDstBySrcRequest` 加 `dedup`/`limit`；storaged 侧按源提前停止 |
| `2d8035c` | 聚合：复用分组键 | `AggregateExecutor` 复用 key buffer、`try_emplace`、惰性分配 distinct set |
| `3b057a3` | 聚合：单键快路径 | 单键 GROUP BY 用连续存储的状态数组，避开每行一个 `List` key |
| `aad0c4f` | 聚合：flat map 与并行分片 | INT64 COUNT 组用 robin_hood flat map，大输入最多 8 路分片，混合键回退 `Value` |
| `635fc7e` | TopN 融进 count 聚合 | 新规则 `PushTopNIntoAggregateRule`；COUNT-only 聚合直接产出 top(offset+count) 组 |
| `d512ee4` | 裁剪只被 WHERE 用的边属性 | `GoValidator` / `GoPlanner` 分离 YIELD 与 WHERE 的属性依赖；安全的一步纯边属性过滤只回传被 YIELD 用到的属性 |
| `c9a4d22` | 补测试 | 覆盖上述优化路径 |
| `b6abb46` | review 收口 | `isSafeEdgeFilter`、投影 join 的空输入与别名冲突回退、COUNT 快路径的行语义与水位检查、dedup 前先套原始边上限、TopN 的负数/溢出保护 |
| `116b6a4` | 多源去重截断下推进 storaged | request 级共享 visited set 与 rank filter；thrift 加 `shared_dedup_limit`/`filter` 与响应侧能力标记 `shared_dedup_limit_supported`，用于拒绝混版本 storaged |

---

## 2. 与补丁设计 A/B/C/D/E/F 的对应

| 补丁 | 分支里的对应物 | 状态 | 差异 |
|---|---|---|---|
| **A** 管道计划下推 | `PushDistinctLimitDownExpandRule`（`1440120`）+ `PushDistinctLimitDownJoinExpandRule`（`116b6a4`） | 已实现 | 走的是**新增规则改写**，不是扩展 `isSimpleCase`；因此不受「起点来自 Argument」限制，但也和 `isSimpleCase` 的其它约束无关 |
| **B** REVERSELY 语义映射 | 无 | **未实现** | 全分支 `src/graph/optimizer`、`src/storage/query` 对 REVERSELY 零处理 |
| **C** 多起点局部聚合 | 无 | **未实现** | 全分支无 `_group_count`/`partial_count`；聚合改动全在 graphd 侧 |
| **D** 集合运算融合 | 无 | **未实现** | 优化器里没有任何集合差集代码 |
| **E** 全局 TopN 两阶段阈值剪枝 | `635fc7e` | **变体** | 是单 graphd 内把 TopN 融进 COUNT 聚合的一个 heap 剪枝，没有第一阶段 RPC、没有跨 host 阈值下界 |
| **F** 全局 Limit 流式截断 | 无 | **未实现** | 且它本来就不是独立补丁 |

另有两处不属于 A–F 但直接服务「过滤 + 投影裁剪」这一半：`d512ee4`（只回传 YIELD 需要的边属性）与 `b6abb46` 的 `isSafeEdgeFilter` 安全门。

---

## 3. 实测：三个前提

测试环境：`/tmp/nb` 的本机集群（上游 `v3.8.0` 二进制），`probe_space` / `probe2` 两个临时 space，用 `buyer`/`item`/`purchased` 这类**不同名的 tag** 来区分端点，测完已 drop。

### 3.1 ✅ `edge._dst` 确实走简单计划

`isSimpleCase()`（`src/graph/validator/GoValidator.cpp:286`）要求 YIELD 的每一列都是 `Expression::Kind::kEdgeDst`：

```cpp
for (auto& col : goCtx_->yieldExpr->columns()) {
  auto expr = col->expr();
  if (expr->kind() != Expression::Kind::kEdgeDst) {
    return false;
  }
  ...
}
```

而解析器把两种写法落在**不同的表达式种类**上（`src/parser/parser.yy:1035`）：

```
| name_label DOT DST_ID_PROP {
    $$ = EdgeDstIdExpression::make(qctx->objPool(), *$1);
}
```

`buy._dst` 走这条规则，得到 `EdgeDstIdExpression`（`kEdgeDst`）；而 `dst(edge)` 是 builtin 函数（`src/common/function/FunctionManager.cpp:2049` 注册的 `"dst"`），是函数调用，`kind` 不是 `kEdgeDst`。

EXPLAIN 实测（同一 space、同一条边）：

```
GO FROM "u1" OVER buy YIELD DISTINCT dst(edge) AS pid;
  → Start → Expand → ExpandAll → Project → Dedup     ← 非简单计划

GO FROM "u1" OVER buy YIELD DISTINCT buy._dst AS pid;
  → Start → Expand → Dedup → Project                  ← 简单计划
```

`GoPlanner::doSimplePlan()`（`src/graph/planner/ngql/GoPlanner.cpp:145`）产出 `Expand` + `Dedup` + `Project`，列名固定 `_expand_vid`；`ExpandExecutor::execute()`（`src/graph/executor/query/ExpandExecutor.cpp:66`）在没有 `joinInput`、没有 `stepLimits` 时走 `GetDstBySrc()`——也就是存储侧去重。

**结论**：「把 `dst(edge)` 改成 `edge._dst` 以触发存储侧去重」这条改写是有效的，方向正确。

### 3.2 ❌ REVERSELY 下 `edge._dst` 不改变语义

用不同名的 tag 做判别性测试（`buyer` 与 `item` 端点可区分）：

```
GO FROM "I1" OVER purchased REVERSELY YIELD src(edge) AS who;
  → B1, B2          ← 买家
GO FROM "I1" OVER purchased REVERSELY YIELD purchased._dst AS who;
  → B1, B2          ← 同样是买家，与 src(edge) 完全一致
GO FROM "I1" OVER purchased REVERSELY YIELD dst(edge) AS who;
  → I1, I1          ← 才是商品自己
```

原因在存储布局：反向边在存储层是**独立的一行**，src/dst 对调、type 取负（`src/graph/util/SchemaUtil.cpp:383` 的 `getEdgeProps()` 对 `reversely` 取 `-edgeType`）。因此反向下 `_dst` 读到的正是**原始 src**。

这带来一个比原设计更好的结论：REVERSELY 下改写 `src(edge)` → `edge._dst` 是**语义安全**的，而且改写后**还能拿到简单计划**：

```
GO FROM "p1" OVER buy REVERSELY YIELD DISTINCT buy._dst AS uid;
  → Start → Expand → Dedup → Project       ← 简单计划
GO FROM "p1" OVER buy REVERSELY YIELD DISTINCT src(edge) AS uid;
  → Start → Expand → ExpandAll → Project → Dedup   ← 非简单计划
```

因为 `src(edge)` 是 `kEdgeSrc`（`EdgeSrcIdExpression`），过不了 `isSimpleCase` 的 `kEdgeDst` 检查；`edge._dst` 能过。

**结论**：

- 文档里「REVERSELY 下 `buy._dst` 是商品 B 自己、改写会返回错误结果」的判断**是错的**；
- 真正的障碍不是语义，而是 `src(edge)` 的表达式种类；
- 于是 **Q6 第一跳的存储侧去重不需要任何补丁**——把 `src(edge)` 写成 `edge._dst` 就能同时拿到正确结果和简单计划；
- 补丁 B 因此应当**取消**，或改写成「让 `isSimpleCase` 在 REVERSELY 下接受 `kEdgeDst`」这种更小的改动。

### 3.3 ⚠️ `LIMIT [N]` 不是 per-vertex limit，而且和「改动 1」互斥

`LIMIT [N]` 走的是 GO 段的截断子句。`GoValidator::validateTruncate()`（`src/graph/validator/GoValidator.cpp:99`）要求它是一个**长度等于步数的 LIST**：

```
GO FROM "u1" OVER buy YIELD dst(edge) AS pid LIMIT 200;
  → SemanticError: `200` type must be LIST.
```

即 `LIMIT [200]` 是**逐步（per-step）**截断，不是 per-vertex limit。它在存储层落到 `PushStepSampleDownGetNeighborsRule`（`src/graph/optimizer/rule/PushStepSampleDownGetNeighborsRule.cpp:56`）的 `GetNeighbors.limit`。

更要紧的是它和简单计划冲突：`isSimpleCase()` 的第一行就要求 `goCtx_->limits.empty()`。实测：

```
GO FROM "u1" OVER buy YIELD DISTINCT buy._dst AS pid;
  → Start → Expand → Dedup → Project                  ← 简单计划
GO FROM "u1" OVER buy YIELD DISTINCT buy._dst AS pid LIMIT [200];
  → Start → Expand → ExpandAll → Project → Dedup       ← 简单计划消失
```

**结论**：文档里「改动 1（`edge._dst`）+ 改动 2（`LIMIT [N]`）一起做」在基线下**不能同时生效**——加了 `LIMIT [N]` 就丢掉了简单计划，也就丢掉了存储侧去重。二者只能择一；若要 per-vertex 截断且保住去重，得走 `116b6a4` 的 `shared_dedup_limit` 路线（请求级共享 visited set + 请求级 limit），而不是 GO 段的 `LIMIT [N]`。

---

## 4. 对补丁设计的修正建议

1. **补丁 B 取消或缩小。** REVERSELY 的语义映射不需要做（存储层的 src/dst 对调已经是对的）；真正要做的只是让 `src(edge)` 这种写法也能走简单计划，而改写成 `edge._dst` 已经在 nGQL 层做到了，零代码。
2. **补丁 A 与分支已有实现二选一。** `PushDistinctLimitDownJoinExpandRule` 已经能改写管道计划下的去重下推，再去扩展 `isSimpleCase` 是两条不同的路；前者不改 `isSimpleCase`，后者会让「简单计划」这条路也吃到管道场景，两者收益重叠、边界不同，需要先定清楚谁是主路。
3. **补丁 C 的前提要重估。** `635fc7e`/`aad0c4f` 证明 COUNT+GROUP BY 在 graphd 侧用 flat map + 最多 8 路分片已经能扛；「百万行回传是瓶颈」这个假设要用真实分布重测，再决定值不值得做存储侧局部聚合。
4. **`LIMIT [N]` 的收益论述要撤回。** 它是逐步截断、且破坏简单计划；Q2/Q3/Q4/Q5/Q6 里凡是把它当 per-vertex limit 用来「兜底防爆」的方案，都要改成 `shared_dedup_limit` 那一路。

---

## 5. 复现方法

```bash
# 分支（只拉近 14 天）
git clone --branch operator-opt --single-branch --shallow-since="14 days ago" --no-tags \
  https://gitcode.com/guoshaohong1/nebula.git

# 看规则改写
git show 116b6a4 -- src/graph/optimizer/rule/PushDistinctLimitDownJoinExpandRule.cpp

# 看存储侧共享去重与能力标记
git show 116b6a4 -- src/interface/storage.thrift src/storage/exec/GetDstBySrcNode.h
```

EXPLAIN 侧（基线 `v3.8.0` 二进制）：

```bash
# 建判别性图：buyer / item 用不同 tag，端点可区分
CREATE SPACE probe(partition_num=1, replica_factor=1, vid_type=FIXED_STRING(32));
USE probe;
CREATE TAG buyer(); CREATE TAG item(); CREATE EDGE purchased();

# 每次调用都是新会话，USE 要和查询写在同一个 -f 文件里
nebula-console -addr 127.0.0.1 -port 9669 -u root -p nebula -f probe.ngql
```

注意：`CREATE SPACE` 必须显式给 `vid_type`；`CREATE TAG` 之后要等 meta 把 schema 同步下来才能 INSERT；`EXPLAIN` 只能走 `-f` 文件，`-e` 不支持。

---

## 6. 已知边界

- 第 3 节的三条前提在本机单集群（上游 `v3.8.0` 二进制）上验证了**计划形状和结果正确性**。分支 `operator-opt` 自身在第 7 节单独编译后做了 A/B：计划形状有 3 条不同（补丁 A 确实存在），但**结果在并列切分上不等价**——详见 7.5。
- 第 7 节的 A/B 只覆盖 [47](47-reco-ngql-pushdown.md) 的 12 条语句，没有覆盖更大数据量或更多形态。
- `116b6a4` 引入的 `shared_dedup_limit_supported` 能力标记是**混版本护栏**：graphd 在 storaged 不支持时直接报错而不是静默降级。这意味着分支的 graphd 和 storaged 必须同版本，不能滚动升级。
- 第 3 节的三条结论只覆盖**单跳、无 WHERE、无 LIMIT** 的形态。带 WHERE、带截断、多跳的形态下简单计划是否成立，本文没有逐一枚举。
- `operator-opt` 分支与本文引用的上游 `v3.8.0` 在 `src/graph/optimizer`、`src/graph/planner` 上有差异时，本文以分支自身的代码为准；未标注差异的地方以 `v3.8.0` 为准。

### 6.1 行号锚点对照

正文里的行号一律按 `v3.8.0` 基线计。分支改动过 `GoValidator.cpp` 和 `GoPlanner.cpp`，同名函数在 `operator-opt` 上的行号不同；三个被引用的函数体在两棵树上逐字相同，所以结论对两棵树都成立，只是行号要换。

| 锚点 | v3.8.0 | operator-opt |
|---|---|---|
| `GoValidator::isSimpleCase()` | 286 | 297 |
| `GoValidator::validateTruncate()` | 99 | 108 |
| `parser.yy` 的 `DST_ID_PROP` 规则 | 1035 | 1035 |
| `FunctionManager` 注册 `"dst"` | 2049 | 2049 |
| `GoPlanner::doSimplePlan()` | 145 | 148 |
| `ExpandExecutor` 走 `GetDstBySrc()` | 66 | 66 |
| `SchemaUtil::getEdgeProps()`（`reversely` 重载） | 383 | 383 |
| `PushStepSampleDownGetNeighborsRule` | 56 | 56 |

## 7. 分支实测：编译与 A/B

### 7.1 分支按现状编译不过

`operator-opt` HEAD `116b6a4` 直接编译失败：

```text
src/storage/exec/GetDstBySrcNode.h:141:11: error: 'nebula::storage::GetDstBySrcNode::scanLimit_' will be initialized after [-Werror=reorder]
src/storage/exec/GetDstBySrcNode.h:139:8:  error: 'bool nebula::storage::GetDstBySrcNode::sharedDedupLimit_' [-Werror=reorder]
```

`116b6a4` 给 `GetDstBySrcNode` 加了 `sharedDedupLimit_` 成员，声明放在 `dedup_` 之后、`limit_` 之前，但构造函数的初始化列表仍按旧顺序写（`dedup_`、`limit_`、`scanLimit_`、`sharedDedupLimit_`）。项目开 `-Werror`，`-Wreorder` 直接致命。把初始化列表改成与声明同序即可，两行，不改语义：

```cpp
      : context_(context),
        edgeNodes_(edgeNodes),
        edgeContext_(edgeContext),
        result_(result),
        dedup_(dedup),
        sharedDedupLimit_(sharedDedupLimit),
        limit_(limit),
        scanLimit_(scanLimit) {
```

### 7.2 编译配方

第三方的头文件和库在共享前缀下，但 cmake 认的是 `NEBULA_THIRDPARTY_ROOT`，不是 `CMAKE_PREFIX_PATH`：

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/home/dev/gcc11/usr/bin/gcc-11 \
  -DCMAKE_CXX_COMPILER=/home/dev/gcc11/usr/bin/g++-11 \
  -DNEBULA_THIRDPARTY_ROOT=/home/dev/nebula-third-party \
  -DENABLE_TESTS=OFF
ninja -C build -j 10 nebula-graphd nebula-storaged nebula-metad
```

两个坑：只给 `CMAKE_PREFIX_PATH` 时链接行变成 `-L /lib -L /lib64`，报一串 `cannot find -lfolly` / `-lfmt` / `-lwangle`；daemon 还要在自己的工作目录下找到 `share/resources/date_time_zonespec.csv`，否则启动即退（`GraphDaemon.cpp:118 Invalid timezone file`）。

### 7.3 A/B：同一个 metad + storaged + 数据，只换 graphd

用上游 `v3.8.0` 的 graphd（9669）和 `operator-opt` 的 graphd（9670）连同一个 metad/storaged、同一份 reco 数据，跑 [47](47-reco-ngql-pushdown.md) 的 12 条语句。

计划主干 9 条相同，3 条不同：

| 场景 | 上游 | operator-opt |
|---|---|---|
| Q3 opt | `Limit → Dedup → Project → HashInnerJoin → TagIndexPrefixScan → Start → ExpandAll → Expand → Argument` | `Limit → Dedup → Expand → Project → TagIndexPrefixScan → Start` |
| Q5 / Q6 opt | `… Sort → Project → HashInnerJoin → Dedup → Expand …` | `… Sort → HashInnerJoin → Project → Dedup → Expand …` |

Q3 opt 把 `HashInnerJoin + ExpandAll` 收成一次 `Expand`，正是第 2 节那张表里补丁 A 的那条新规则（`PushDistinctLimitDownJoinExpandRule`）；Q5 / Q6 opt 是 `PushProjectDownHashInnerJoinRule` 把投影压到 join 之下。补丁 A 确实存在，只是路径与本文原先的推测不同。

### 7.4 混版本护栏按设计生效

`operator-opt` 的 graphd 配上游的 storaged，带新下推的语句直接报错，不静默降级：

```text
[ERROR (-1005)]: storaged does not support shared dedup/filter semantics; graphd and storaged versions must match
```

与第 6 节的判断一致：graphd 与 storaged 必须同版本。

### 7.5 但结果不是逐行一致：并列切分变了

结果层面，同一份数据、同一条语句，两个 graphd 给出的**行集合不同**：

| 场景 | 上游 | operator-opt | 分数多重集 | 差异 |
|---|---|---|---|---|
| Q1 / Q2 / Q3 base | 10 / 8 / 1801 | 同 | 同 | 无 |
| Q4 base | 670 行 | 671 行 | 第一跳 `co_buy` 多重集相同 | 集合不同 |
| Q5 / Q6 base | 20 / 20 | 20 / 20 | **相同** | 成员不同 |

控制实验：同一条 Q4 base 语句在上游连开 3 个独立会话，行数和 sha 完全一致，所以差异不是运行期抖动。

机制是聚合的**分组输出顺序**变了。上游用 `unordered_map<List, vector<AggData>>`（`AggregateExecutor.cpp:33`），operator-opt 的单键快路径用 `unordered_map<Value, FastGroup>`（`AggregateExecutor.cpp:117`）。哈希键类型不同 → 桶序不同 → `Aggregate` 吐出的分组顺序不同 → 遇到**并列键**时 `TopN` 切出的就不是同一批。

Q4 最直观：第一跳 `co_buy` 分布是 9 → 2 个、8 → 19 个、7 → 66 个、6 → **280** 个，`LIMIT 100` 要在 280 个并列的里面取 100 个，取哪 100 个取决于分组顺序，于是下游 `ext_user` 集合不同（670 vs 671）。

**所以：这些改写在聚合值上等价，在并列切分上不等价。** [47](47-reco-ngql-pushdown.md) 用的「排序后多重集 SHA 相同」这个判据，只有在没有并列键时才等价于「结果相同」；一旦有并列键，它只能证明聚合值一致，不能证明返回的行集合一致。

这一条对 [47](47-reco-ngql-pushdown.md) 本身也成立：Q4 / Q5 / Q6 的 base 与 opt 之所以能对上，是因为那一对是在同一个二进制上比的，聚合输出顺序相同。

