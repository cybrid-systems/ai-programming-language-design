# 01 — NebulaGraph 3.8 算子下推

> 基于 NebulaGraph 3.8 社区版的能力笔记
> 优化器形态：基于规则的优化器（RBO）
> 关注点：Filter、Limit 能否下推到存储层，或下推到 GetNeighbors、Traverse、Scan 等算子

---

## 0. 概述

NebulaGraph 3.8 的算子下推属于中等水平。RBO 已经能把一部分 Filter 和 Limit 下推到存储层，或下推到 GetNeighbors、Traverse 等算子，但覆盖并不完整。不少查询仍然要在 graphd 侧做二次过滤，而且能不能下推对写法很敏感：同一类过滤，换一种表达式就可能留在计算层。

可以把它理解成「部分下推 + 写法敏感」，而不是「谓词都会下到存储」。

---

## 1. 已支持的下推

| 类型 | 支持程度 | 典型场景与规则 | 说明 |
|------|----------|----------------|------|
| Limit 下推 | 较好 | `PushLimitDownScanEdgesRule`、`PushLimitDownProjectRule`；SHORTEST PATH 的 Limit 下推（3.8 新增） | 可下推到 ScanEdges、部分 IndexScan、GetNeighbors 等。无索引的全量 `MATCH (v) RETURN v LIMIT n`、`MATCH ()-[e:type]->() RETURN e LIMIT n` 可以下推；带复杂条件的扫描仍然受限。 |
| Filter / 谓词下推 | 部分支持 | `PushFilterDownGetNbrsRule`；边谓词嵌入 Traverse | 在 GO、GetNeighbors、Traverse 上，边属性条件可以下推到 storage，显式指定边类型时更明显，例如 `WHERE follow.degree > 1`。`all()` 等部分谓词也可以嵌入算子。 |
| 属性裁剪 | 有限 | Project 相关规则 | 能少拉一部分用不到的属性，但裁剪不彻底。 |

---

## 2. 典型能下推的写法

下面三则是 3.8 里比较容易走到下推路径的写法。

边属性过滤下推到 GetNeighbors：

```ngql
GO FROM "vid" OVER follow
WHERE follow.degree > 1
YIELD follow._src AS src, follow._dst AS dst, follow.degree AS degree;
```

Limit 下推到 ScanEdges：

```ngql
MATCH ()-[e:follow]->()
RETURN e
LIMIT 10;
```

SHORTEST PATH 搭配 Limit。3.8 明确增强了这条路径上的 Limit 下推：

```ngql
FIND SHORTEST PATH FROM "src" TO "dst" OVER follow
YIELD path AS p
| LIMIT 10;
```

无索引的全量点扫描，在 Limit 能够下推时同样可以成立：

```ngql
MATCH (v)
RETURN v
LIMIT 10;
```

带上复杂过滤之后，同样的扫描就可能下推不完整，不能默认它会停在存储层。

---

## 3. 下推受限或不支持的情况

| 场景 | 结果 |
|------|------|
| 终点属性过滤：`$$.tag.prop`、`properties($$)` | 很多多跳查询无法下推，需要先把数据拉回 graphd，再在 graphd 过滤。 |
| 函数包裹：`dst(edge)`、`src(edge)`、`properties(edge)`、`id($$)` 等 | 通常会挡住下推。直接写 `edge._dst`、`edge._src`、`edge.prop` 更容易下推。 |
| 复杂复合条件、跨边类型比较 | 下推不完整。 |
| 部分带索引的 MATCH，再叠加 Limit | Limit 下推不完整。 |
| 无索引全量扫描，且没有可下推的 LIMIT | 直接报错，例如 `-1005: scan vertices or edges need to specify a limit number, or limit number can not push down`。 |
| 子查询计划整体下推（NDP） | 社区版 3.8 不支持，这是企业版 5.x 的能力。 |

函数包裹和原生属性访问的差别：

```ngql
-- 函数包裹，通常阻碍下推
GO FROM "vid" OVER follow
WHERE dst(edge) == "other"
YIELD dst(edge) AS dst;
```

```ngql
-- 原生属性访问，更利于下推
GO FROM "vid" OVER follow
WHERE follow._dst == "other"
YIELD follow._dst AS dst;
```

终点属性也一样。`$$.player.age > 30` 这类条件在多跳里常常留在 graphd。需要终点属性时，先只取出 VID，再管道 `FETCH`，避免在遍历算子上挂一条下不去的点过滤。

---

## 4. 使用建议

1. 优先写 `GO`，并显式给出边类型和边属性条件。相比 MATCH，这条路径更容易触发 Filter 下推。
2. 过滤尽量写在边上，而不是写在终点属性上。确实需要终点属性时，先 `YIELD` VID，再管道 `FETCH`：

```ngql
GO FROM "vid" OVER follow
WHERE follow.degree > 1
YIELD follow._dst AS vid
| FETCH PROP ON player $-.vid
YIELD vertex AS v;
```

3. 用 `EXPLAIN` 或 `PROFILE` 确认是否真下推。算子上出现 `filter:` 或 `limit:`，并且落在 GetNeighbors、Traverse、Scan 上，才表示条件或 Limit 已经进了该算子。只在 graphd 侧的 Project / Filter 里看到条件，说明数据仍然是拉回来之后再滤。
4. 避免没有必要的函数包裹，能用原生属性访问就不要再套 `src()`、`dst()`、`properties()`、`id()`。

---

## 5. 总结

3.8 在 Limit 下推上有明显进步，SHORTEST PATH 的 Limit 是其中明确增强的一块；简单边谓词下推同样可用。整体仍然是「部分下推 + 写法敏感」。复杂多跳、终点属性过滤这些场景里，数据还是会大量回到 graphd，性能提升有限。

子查询计划的整体下推不是社区版 3.8 能覆盖的范围。企业版 5.x 在子查询计划下推方面更完整。
