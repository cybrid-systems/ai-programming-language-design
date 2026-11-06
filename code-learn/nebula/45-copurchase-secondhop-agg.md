# 45 — 共现推荐第二跳聚合下推（设计 + 原型）

> 对照源码：`v3.8.0` `fa928930ab34f150db522933323aa610e54f26e7`
> 补丁：[patches/v3.8.0-copurchase-secondhop-agg.patch](patches/v3.8.0-copurchase-secondhop-agg.patch)
> 分支：`feature/copurchase-pushdown`
> 日期：2026-11-06
> 状态：原型，已在本机单机集群验证；不是生产实现

---

## 0. 结论

第二跳的 `GROUP BY dst(edge) + COUNT(1)` 可以下推到 storaged：各 storaged 在边迭代器上过滤、按 `dst(edge)` 做部分计数，只回 `(item, partial_count)`；graphd 等全部 RPC 返回后合并、排序、取 top 20。原型在 4 个买家 / 5 个商品的小图上跑通，结果与未下推路径一致。

但有两个和原始设计稿不同的地方，必须先写清楚：

1. **`| WHERE` 不是合法 nGQL。** `WHERE` 属于第二个 `GO`，不能作为独立管道：
   ```nGQL
   GO FROM "p" OVER buy REVERSELY YIELD DISTINCT src(edge) AS uid
   | GO FROM $-.uid OVER buy WHERE dst(edge) != "p" YIELD dst(edge) AS item
   | GROUP BY $-.item YIELD $-.item AS rec_item, COUNT(1) AS score
   | ORDER BY $-.score DESC | LIMIT 20
   ```
2. **管道 GO 不规划成 `GetNeighbors`。** 实测计划是 `Expand → ExpandAll → Filter → HashInnerJoin`；第二跳的 storage 调用在 `ExpandAllExecutor` 里。补丁因此是按 `ExpandAll` 接的，不是按 `GetNeighbors`。

---

## 1. 目标查询

```nGQL
GO FROM "p" OVER buy REVERSELY
YIELD DISTINCT src(edge) AS uid
| GO FROM $-.uid OVER buy
  WHERE dst(edge) != "p"
  YIELD dst(edge) AS item
| GROUP BY $-.item
  YIELD $-.item AS rec_item, COUNT(1) AS score
| ORDER BY $-.score DESC
| LIMIT 20;
```

业务含义：从商品 `p` 找到买过它的买家，再看这些买家买过的其他商品（排除 `p`），按共现次数排序，返回 top 20。

和上一版 3.2 查询的主要差异：

| 点 | 上一版 3.2 | 本查询 |
|----|-----------|--------|
| 第一跳 LIMIT | 有 per-vertex LIMIT | 无，取全部买家 |
| 第二跳 LIMIT | 有 per-vertex LIMIT | 无 |
| DISTINCT | 无 | 第一跳有 DISTINCT src |
| 过滤 | 无 | 排除原商品 |
| 起点 | 常量 | 变量（仍是单个） |

---

## 2. 物理事实

- **第一跳（商品 → 买家）**：`buy` 的反向边按商品 VID 存储，只落在 `p` 对应的一个 part 上；这个 part 的 leader 在一台 storaged 上。第一跳是单机。
- **第二跳（买家 → 商品）**：买家按 VID 哈希散落在多个 part，第二跳是多机。
- **过滤时机**：`WHERE dst(edge) != "p"` 属于第二个 `GO`，必须在部分计数之前生效；否则 `p` 也会拿到分数。
- **大多数场景走非亲和路径。**

---

## 3. 实际计划形状（v3.8.0 实测）

`EXPLAIN` 的节点和依赖：

```
TopN(16) → Aggregate(13) → Project(12) → HashInnerJoin(19)
  left : Dedup(5) → Project(4) → ExpandAll(3) → Expand(2) → Start(1)   // 第一跳
  right: Filter(18) → ExpandAll(17) → Expand(8) → Argument(7)          // 第二跳
```

要点：

- 第一跳 `GO ... REVERSELY` 走 `Expand` / `ExpandAll`，不是 `GetNeighbors`。
- 第二跳 `GO FROM $-.uid` 的输入是 `Argument`，同样走 `Expand` / `ExpandAll`。
- `HashInnerJoin` 把第一跳的买家列表和第二跳结果按 `uid` 拼起来。
- `Aggregate(13)` 的输入是 `Project(12)`，`groupKeys=["$-.item"]`，`groupItems=[{$-.item}, {COUNT(1)}]`。
- `ExpandAll(17)` 的 `edgeTypes()` 是空，边类型在 `edgeProps` 里以通配 `-2` 表示。

因此下推点不是 `GetNeighborsExecutor`，而是 `ExpandAllExecutor` 的 `getNeighbors` 调用。

---

## 4. 核心设计：第二跳聚合下推

baseline：第二跳各 storaged 回全部边，graphd 做 `WHERE` + `GROUP BY item` + `COUNT`。

优化后：各 storaged 在第二跳的边迭代器上直接过滤、按 `dst(edge)` 做部分计数，只回 `(item, partial_count)`；graphd 合并部分和、排序、取 top 20。

```
第二跳各 storaged：
  扫描本机买家的出边
  ↓
  执行可下推的边谓词（如 dst(edge) != "p"）
  ↓
  按 dst(edge) 计数（对边计数，不去重）
  ↓
  回 (item, partial_count)

graphd：
  等所有第二跳 RPC 返回
  ↓
  合并所有部分和
  ↓
  全局排序 + LIMIT 20
```

### 4.1 关键约束

- **对边计数，不去重**：保留 `COUNT(1)` 的原始语义；同一买家买同一商品多条边时每条边都计数。
- **过滤在聚合之前**：原商品不得计入任何 score。
- **非亲和路径不做局部 TopN**：每台机器只看到部分买家，局部 TopN ≠ 全局 TopN。
- **第一跳 DISTINCT**：必须先去重买家，避免同一买家被多次展开。
- **全部分和回来后才合并**：第二跳并行发、全部回来才继续，P99 由最慢的一台决定。

### 4.2 收益量级

回传行数 ≈ Σ（各 storaged 局部去重 item 数）。压缩比取决于买家购买的 item 重复度：重复度高时收益显著，重复度低时接近零。原型没有做真实数据集的压缩比测量。

---

## 5. 子图划分局部性

下推聚合不依赖局部性也能正确工作；有子图划分时额外更好。

| 情况 | 第二跳机器数 | 效果 |
|------|--------------|------|
| 无局部性（买家散落） | 多 | 有压缩，但 RPC 多 |
| 有局部性（买家相对集中） | 少 | 压缩更好、RPC 更少、P99 更低 |
| 完全亲和（全在一台） | 1 | 可走 LOCAL_CHAIN，直接回最终结果 |

**当前原型没有实现 LOCAL_CHAIN，也没有做亲和门闩。** 文档里的 `LOCAL_CHAIN`、`touched_parts`、`isLeader` 门闩属于后续设计，不在本补丁里。

---

## 6. 模式识别边界

仅当同时满足以下条件时才改写，任一不满足走原路径：

1. 第一跳起点为单个 VID（常量或变量均可，但必须是单个）。
2. 第一跳为 `GO ... OVER edge REVERSELY`，YIELD 为 `DISTINCT src(edge)` 或等价。
3. 第二跳为 `GO FROM $-.uid OVER same_edge`（正向，不带 REVERSELY），YIELD 为 `dst(edge)`。
4. 有 `WHERE` 排除原商品（`dst(edge) != $product_id` 或等价）。
5. `GROUP BY` 恰好一个 key，且为第二跳的 dst 字段。
6. 聚合函数为 `COUNT(1)` 或等价；`COUNT(DISTINCT ...)` 不匹配。
7. `ORDER BY` 仅按聚合结果 `DESC`，无 tie-breaker。
8. 最终 `LIMIT` 为常量整数。
9. 管道结构为：第一跳 GO → 第二跳 GO → GROUP BY → ORDER BY → LIMIT。

原型的识别实现比这套边界窄：只认“一个 dst 分组键 + COUNT(1) + OUT 单边类型”的计划形状，不解析 3/4/7/8 的全部语法变体。

---

## 7. 调度与回退

- 门闩在第一跳完成后精确计算，检查实际返回的全部买家是否都在第一跳那台 storaged 上。
- 运行时证明（`isLeader` + `touched_parts` + graphd guard）失败 → 整句回退。
- RPC / 超时 / 限额 → 丢弃部分结果，走原路径。
- 所有失败边指向 `FallbackOriginal`。

原型只实现了“可下推则下推、不可下推则保留原计划”，没有实现亲和门闩和显式的 `FallbackOriginal` 枚举。

---

## 8. 原型实现

补丁：[`patches/v3.8.0-copurchase-secondhop-agg.patch`](patches/v3.8.0-copurchase-secondhop-agg.patch)（基于 `fa928930`，`git apply --check` 通过）。

| 文件 | 作用 |
|------|------|
| `src/interface/storage.thrift` | `TraverseSpec.group_by_dst` |
| `src/storage/exec/GroupByDstNode.h` | 按 `dst(edge)` 计数，flush `(item, partial_count)`，去掉定长 VID 的 NUL 填充 |
| `src/storage/query/GetNeighborsProcessor.*` | 识别 `group_by_dst`；单线程；通配边类型从 schema 展开；过滤在计数前；host 内多个 part 共用一个计数 map |
| `src/graph/executor/query/AggregateExecutor.*` | 识别 `Aggregate → Project → HashInnerJoin → Filter → ExpandAll` 模式；把 `COUNT(1)` 改成对 `_group_count` 求和 |
| `src/graph/executor/query/ExpandAllExecutor.cpp` | 第二跳把 `group_by_dst` 带到 storage，返回 `(item, partial_count)` |
| `src/graph/executor/query/FilterExecutor.cpp` | 分组行 pass-through；原型按 `dst(EDGE) != "literal"` 丢掉被排除的商品 |
| `src/graph/executor/query/ProjectExecutor.cpp` | 分组行 pass-through，不再对 `dst(EDGE)` 求值 |
| `src/graph/executor/query/InnerJoinExecutor.cpp` | `HashInnerJoin` 在分组模式下直接返回右侧结果，不做 join |
| `src/clients/storage/StorageClient.*` | `getNeighbors` 透传 `group_by_dst` |
| `src/graph/planner/plan/Query.*` | `GetNeighbors` / `Expand` / `HashInnerJoin` 的下推标志、clone、explain |
| `tests/copurchase_pushdown_test.py` | 单机最小数据集集成测试 |

---

## 9. 验证

### 9.1 环境

- 单机 metad / storaged / graphd，graphd `127.0.0.1:9669`，storaged `9779`，metad `9559`。
- 构建：`g++-11` + `/home/dev/nebula-third-party`；`ninja -C build nebula-graphd nebula-storaged nebula-metad`。

### 9.2 数据

空间 `copurchase`，3 个 part，边类型 `buy`：

```
u1 -> p, a, b, c
u2 -> p, a, b
u3 -> p, b, c
u4 -> p, c, d
```

### 9.3 结果

```text
got:      {'b': 3, 'c': 3, 'a': 2, 'd': 1}
expected: {'a': 2, 'b': 3, 'c': 3, 'd': 1}
PASS
```

日志：

```text
graphd : co-purchase pushdown: ExpandAll 17 returns (item, partial_count)
storaged: co-purchase pushdown: flushed 5 grouped rows
```

5 行是 a/b/c/d/p 的部分计数（p 在 graphd 侧按 WHERE 丢弃）。`tests/copurchase_pushdown_test.py` 在干净空间上可重复跑出 `PASS`。

### 9.4 没有证明的事

- 没有做真实数据集的压缩比 / P99 / QPS 对比；只证明了结果等价。
- 没有多机集群、没有杀 storaged、没有 RF=3 的回退验证。
- 没有测同分截断（TopN 无 tie-breaker，同分允许不同子集）。

---

## 10. 原型的限制（重要）

1. **通配边类型会扫描全部边类型。** 计划里 `ExpandAll.edgeTypes()` 为空、边在 `edgeProps` 里是 `-2`；原型从 space schema 展开所有边类型。只有 space 里恰好只有 `buy` 时结果才正确。多边类型 space 需要把 `OVER buy` 的具体类型带到 storage。
2. **过滤是原型解析。** graphd 侧从 `dst(EDGE) != "literal"` 里取字面量；不是通用表达式求值。生产应把边谓词编码后随请求下推，或复用 `ExpandAll.filter`。
3. **单线程部分计数。** 一个请求内的多 part 共用一个 map，牺牲并发换正确性；生产应做 sharded map 或 per-part 状态再合并。
4. **没有 LOCAL_CHAIN / 亲和门闩。** 文档第 5 节的单机路径未实现。
5. **没有局部 TopN。** 非亲和路径只在 graphd 合并后排序；这是正确的，但没有减少最后一段行数。
6. **没有 `FallbackOriginal` 枚举。** 只做“识别失败就走原计划”。

---

## 11. 和 15 / 16 / 42 / 43 的关系

- [15](15-general-pushdown.md) 给的是“边上的可下推框架”，[16](16-partial-agg-impl.md) 的补丁走 `GetDstBySrc`，聚合是 `SUM/COUNT/MIN/MAX` 的**单跳**部分聚合。
- [42](42-copurchase-pushdown.md) / [43](43-copurchase-pushdown-prod.md) 是另一套 `COPURCHASE` 专用算子（含时间窗、剪枝、精确 top15），补丁叠在 v5 上；本篇不改解析器，只优化标准 `GO` 管道的第二跳 `GROUP BY dst + COUNT(1)`，补丁直接打在 `v3.8.0` 上。
- 本篇是**两跳共现推荐**：第二跳是 `GO FROM $-.uid`，计划走 `ExpandAll` + `HashInnerJoin`，下推的是 `GROUP BY dst + COUNT(1)`。
- 两套补丁不要同时叠：16 改的是 `GetDstBySrcRequest/Response`，本篇改的是 `GetNeighborsRequest.TraverseSpec` 和 `ExpandAll` 路径。共同点是“storage 做部分状态、graphd 合并”。

---

## 12. 下一步

1. 把 `OVER buy` 的具体 edge type 从 planner 带到 `ExpandAll`，去掉“扫全部边类型”的假设。
2. 把过滤从字面量解析改成可下推表达式（复用 `EdgePushdown` / `FilterNode`）。
3. 多 part / 多线程 sharded 计数，再合并。
4. 在 12/17 的美妆数据集上测回传行数、压缩比、P99；和 baseline 对比。
5. 若要实现文档第 5 节的 LOCAL_CHAIN，先补亲和元数据与门闩，再谈单机局部 TopN。
