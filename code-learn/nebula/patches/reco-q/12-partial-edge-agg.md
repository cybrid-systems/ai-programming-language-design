# 12 — 局部 COUNT

编号 12 不是一份新 diff。源码就是这两张，按顺序打在 `fa92893` 上：

1. [`patches/v3.8.0-dst-only-edge-filter.patch`](../v3.8.0-dst-only-edge-filter.patch)
2. [`patches/v3.8.0-partial-edge-agg.patch`](../v3.8.0-partial-edge-agg.patch)

第二张的新文件头必须是 `@@ -0,0 +1,429 @@`。写成 `419` 会把 `PushPartialEdgeAggRule.cpp` 截断，`absorb()` 就穿不过 `Sort`，Q4/Q5/Q6 的规则匹配不上。

`--enable_partial_edge_agg` 默认关闭。`--enable_dst_only_edge_filter` 保持关闭。打开后者会把带过滤的 `DISTINCT` 收成 `GetDstBySrc`，Q2 和 Q3 的计划会变。

测量和计划在 [50-reco-partial-count.md](../../50-reco-partial-count.md)。

13、14、15 叠在这两张之上，源码在 [`13-15-minus-rank-topn-dedup-stop.patch`](13-15-minus-rank-topn-dedup-stop.patch)。三张运行时开关互相独立，补丁本身按 12 然后 13–15 的顺序打。总表在 [51-reco-patch-index.md](../../51-reco-patch-index.md)。
