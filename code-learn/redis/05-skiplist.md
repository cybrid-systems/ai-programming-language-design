# 05 — ZSet：跳表与哈希表的双结构协奏

> Redis 主线源码深度分析系列 · 第五篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Sorted Set（ZSet）是 Redis 最精巧的数据类型之一：它同时维护**两种视图**，让 O(log N) 的范围查询和 O(1) 的单元素操作可以共存于同一个结构上。

- **按 score 排序**：跳表（skiplist）支撑 `ZRANGE`、`ZRANK`、`ZCOUNT`
- **按 member 查找**：哈希表（dict）支撑 `ZSCORE`、`ZREM`（O(1) 定位 member）

两套结构共享同一个 SDS string（`ele`），不冗余存储。

```c
// server.h:1272-1275 — doom-lsp 确认
typedef struct zset {
    dict *dict;       // member → score 映射（O(1) 查找）
    zskiplist *zsl;   // score → member 排序（O(log N) 范围查询）
} zset;
```

加上第四篇讲过的 listpack 紧凑编码，ZSet 在数据量小时也用 listpack 存储，超过阈值再转为 skiplist+dict。

**doom-lsp 确认**：核心文件

| 文件 | 行数 | 职责 |
|------|:----:|------|
| `src/t_zset.c` | 4382 | 跳表实现 + ZSet 命令 |
| `src/server.h:1256-1275` | — | zskiplistNode / zskiplist / zset 定义 |
| `src/server.h:485-486` | — | ZSKIPLIST_MAXLEVEL / ZSKIPLIST_P 常量 |

---

## 1. 跳表原理——概率平衡树

### 1.1 为什么不用平衡树

Pugh 1990 年的论文提出的核心洞察：**有序链表的查找可以通过多层「快车道」加速**。每一层是下一层的子集，查找时从最高层快速跳过大量节点。

```
Level 3:  head ──────────────────────────────────────→ tail
Level 2:  head ──────────→ 17 ──────────────────────→ tail
Level 1:  head ─→ 5 ─→ 9 ─→ 17 ─→ 25 ─→ 30 ─→ 42 ─→ tail
查找 30：从 L3(head) → L2(17) → L1(25 → 30)，3 步。
```

**Redis 选择跳表而非平衡树的理由**（antirez 在 t_zset.c 开头的注释）：

```
// t_zset.c:24-32 — 三种主要修改
// a) 允许重复 score
// b) 比较不仅按 score，还按 satellite data（ele 字典序）
// c) level 1 上有 backward 指针，形成双向链表
```

跳表相对于红黑树的工程优势：
1. **实现更简单**：插入/删除不需旋转或 recoloring
2. **范围查询友好**：`ZRANGE 0 99` 可以在 level 1 链上直接顺序遍历
3. **内存分布更均匀**：每个节点随机层高，避免平衡树的结构倾斜

### 1.2 节点结构

```c
// server.h:1256-1264 — doom-lsp 确认
typedef struct zskiplistNode {
    sds ele;                            // 成员名称（与 dict 共享同一个 SDS）
    double score;                        // 排序分值
    struct zskiplistNode *backward;     // level 1 的后向指针（双向链表）
    struct zskiplistLevel {
        struct zskiplistNode *forward;  // 向前指针
        unsigned long span;             // 到下一个节点的"跨度"（元素个数 - 1）
    } level[];                          // 柔性数组，每个节点实际分配 level 个
} zskiplistNode;
```

**关键字段**：

- **`ele`**（`sds`）：与 dict 中**共享同一个指针**。zslFreeNode 释放时才会 `sdsfree(node->ele)`，dict 的 value destructor 设为 NULL，由跳表一方统一管理。
- **`backward`**：只在 level 1 有意义，使跳表在 level 1 上成为**双向链表**。用于 `ZREVRANGE` 从尾到头遍历。
- **`span`**：每个 level 段中，从当前节点到 `forward` 之间跨越了多少个 level 1 节点。这是跳表实现 `ZRANK`（按 rank 索引）的关键——不需要遍历所有 level 1 节点。

```c
// server.h:1266-1270 — doom-lsp 确认
typedef struct zskiplist {
    struct zskiplistNode *header, *tail;
    unsigned long length;   // 节点总数
    int level;              // 当前最大层高
} zskiplist;
```

- **`header`**：哨兵节点，不存实际数据。`level` 总是 `ZSKIPLIST_MAXLEVEL`（32），所有 `forward` 初始为 NULL。
- **`tail`**：尾节点指针，`ZREVRANGE` 从 `zsl->tail` 开始沿 `backward` 遍历。

### 1.3 概率层高

```c
// server.h:485-486 — doom-lsp 确认
#define ZSKIPLIST_MAXLEVEL 32    // 2^64 元素也够了
#define ZSKIPLIST_P 0.25         // 晋升概率 = 1/4

// t_zset.c:106-111 — doom-lsp 确认
int zslRandomLevel(void) {
    static const int threshold = ZSKIPLIST_P * RAND_MAX;
    int level = 1;
    while (random() < threshold)
        level += 1;
    return (level < ZSKIPLIST_MAXLEVEL) ? level : ZSKIPLIST_MAXLEVEL;
}
```

**`P = 1/4`** 意味着：

| 层高 | 概率 | 1 亿节点的期望节点数 |
|:----:|:----:|:------------------:|
| 1 | 75% | 75,000,000 |
| 2 | 18.75% | 18,750,000 |
| 3 | 4.69% | 4,687,500 |
| 4 | 1.17% | 1,171,875 |
| 5 | 0.29% | 292,969 |
| … | … | … |
| 16 | ~3.6×10⁻¹⁰ | ~0.36 |

**为什么是 1/4 而不是 1/2**（常见的跳表实现）？`P` 越小，高层越稀疏，查找时的"电梯"跳更快，但每层只能跳过更少的节点。Redis 选择 1/4 倾向于**更快的查找速度**，以略多的内存为代价。

**`ZSKIPLIST_MAXLEVEL = 32`**：按 `P = 1/4`，层高 ≥ 32 的概率是 `(1/4)^31 ≈ 8.6×10⁻¹⁹`，2^64 个元素也只有不到 1 个。32 层实际上永远不会用满。

---

## 2. 插入——zslInsert

```c
// t_zset.c:133-186 — doom-lsp 确认
zskiplistNode *zslInsert(zskiplist *zsl, double score, sds ele) {
    zskiplistNode *update[ZSKIPLIST_MAXLEVEL], *x;
    unsigned long rank[ZSKIPLIST_MAXLEVEL];
    int i, level;

    serverAssert(!isnan(score));
    x = zsl->header;

    // 阶段一：从顶到底查找插入位置，沿途记录 update 和 rank
    for (i = zsl->level-1; i >= 0; i--) {
        rank[i] = (i == zsl->level-1) ? 0 : rank[i+1];
        while (x->level[i].forward &&
               (x->level[i].forward->score < score ||
                (x->level[i].forward->score == score &&
                 sdscmp(x->level[i].forward->ele, ele) < 0)))
        {
            rank[i] += x->level[i].span;    // 累计跨过的节点数
            x = x->level[i].forward;
        }
        update[i] = x;                       // 记录每层需要更新的节点
    }

    // 阶段二：随机生成新节点的层高
    level = zslRandomLevel();
    if (level > zsl->level) {
        // 新层：header 在更高层的 span 初始化为 length
        for (i = zsl->level; i < level; i++) {
            rank[i] = 0;
            update[i] = zsl->header;
            update[i]->level[i].span = zsl->length;
        }
        zsl->level = level;
    }

    // 阶段三：创建节点并逐层插入
    x = zslCreateNode(level, score, ele);
    for (i = 0; i < level; i++) {
        x->level[i].forward = update[i]->level[i].forward;
        update[i]->level[i].forward = x;

        /* 更新 span */
        x->level[i].span = update[i]->level[i].span - (rank[0] - rank[i]);
        update[i]->level[i].span = (rank[0] - rank[i]) + 1;
    }

    // 阶段四：更新未触及层的 span
    for (i = level; i < zsl->level; i++) {
        update[i]->level[i].span++;
    }

    // 阶段五：设置 backward 和 tail
    x->backward = (update[0] == zsl->header) ? NULL : update[0];
    if (x->level[0].forward)
        x->level[0].forward->backward = x;
    else
        zsl->tail = x;

    zsl->length++;
    return x;
}
```

### 2.1 Rank 和 Span 的协同

跳表的 rank 操作依赖 **span** 字段。每个 level 段都记录了从当前节点到 forward 之间跨越了多少个 level 1 节点。

```
例子：一列 5 个节点（score 1.0 ~ 5.0）

header
  │
L3: [───span=5─────────→ 跳过所有 5 个节点]
L2: [───span=3─────────→ 3.0 ───span=2─────────→ 5.0]
L1: [→ 1.0 ─→ 2.0 ─→ 3.0 ─→ 4.0 ─→ 5.0]
```

插入时，`rank[i]` 记录了在 level i 查找过程中跳过了多少个 level 1 节点。这样插入新节点时，可以精确计算它在每层的 span 变化：

```
新节点 score=2.5，插入到 2.0 和 3.0 之间。

插入前 update[2]-header 的 span=5
插入前 update[1]=3.0 的 span=2
插入前 update[0]=2.0 的 span=1

新节点在 L1（插入 update[0] 之后）：
  x->level[0].span = update[0]->level[0].span - (rank[0] - rank[0])
                   = 1 - 0 = 1
  update[0]->level[0].span = (rank[0] - rank[0]) + 1 = 1

新节点在 L2（插入 update[1] 之后）：
  x->level[1].span = update[1]->level[1].span - (rank[0] - rank[1])
                   = 2 - (4 - 2) = 0
  update[1]->level[1].span = (rank[0] - rank[1]) + 1 = 3
```

**span 的精妙之处**：让 `ZRANK` 和 `ZREVRANK` 只需要走一遍跳表查找路径，累加沿路 span，就可以在 O(log N) 时间内得到元素排名，不需要遍历整个底层链表。

### 2.2 分数相同时的字典序比较

当 score 相同时，Redis 按 **element 的字典序**比较：

```c
x->level[i].forward->score == score &&
sdscmp(x->level[i].forward->ele, ele) < 0
```

这意味着 ZSet 的排序是 **(score, ele)** 二元组——score 优先，score 相等时按 sds 的字节序排序。这确保了 `ZRANGE` 在有相同 score 时输出稳定有序。

---

## 3. 删除——zslDelete

```c
// t_zset.c:220-260 — doom-lsp 确认
int zslDelete(zskiplist *zsl, double score, sds ele, zskiplistNode **node) {
    zskiplistNode *update[ZSKIPLIST_MAXLEVEL], *x;
    int i;

    x = zsl->header;
    for (i = zsl->level-1; i >= 0; i--) {
        while (x->level[i].forward &&
               (x->level[i].forward->score < score ||
                (x->level[i].forward->score == score &&
                 sdscmp(x->level[i].forward->ele, ele) < 0)))
        {
            x = x->level[i].forward;
        }
        update[i] = x;
    }

    x = x->level[0].forward;
    if (x && score == x->score && sdscmp(x->ele, ele) == 0) {
        zslDeleteNode(zsl, x, update);   // 从各层链表中移除
        if (!node) zslFreeNode(x);       // 释放节点（含 sds）
        else *node = x;                   // 返回给调用者延迟释放
        return 1;
    }
    return 0;
}
```

`zslDeleteNode` 负责实际的链表操作：

```c
// t_zset.c:192-215 — doom-lsp 确认
void zslDeleteNode(zskiplist *zsl, zskiplistNode *x, zskiplistNode **update) {
    int i;
    for (i = 0; i < zsl->level; i++) {
        if (update[i]->level[i].forward == x) {
            // 更新 span 并跳过被删除节点
            update[i]->level[i].span += x->level[i].span - 1;
            update[i]->level[i].forward = x->level[i].forward;
        } else {
            update[i]->level[i].span -= 1;  // 只是减少了一个元素
        }
    }
    // 更新 backward 和 tail
    if (x->level[0].forward)
        x->level[0].forward->backward = x->backward;
    else
        zsl->tail = x->backward;

    // 如果最高层空了，降低 level（保持效率）
    while (zsl->level > 1 &&
           zsl->header->level[zsl->level - 1].forward == NULL)
        zsl->level--;

    zsl->length--;
}
```

**span 更新的两种情形**：
- `update[i]->forward == x`：实际的删除节点，span 要加上被删节点的 span 再减 1（自己）
- `update[i]->forward != x`：该层只是被跨越，span 减 1 即可

---

## 4. 范围查询——RANK 和 RANGE

### 4.1 ZRANK——GetRank

```c
// t_zset.c:476-497 — doom-lsp 确认
unsigned long zslGetRank(zskiplist *zsl, double score, sds ele) {
    unsigned long rank = 0;
    int i;
    x = zsl->header;

    for (i = zsl->level-1; i >= 0; i--) {
        while (x->level[i].forward &&
               (x->level[i].forward->score < score ||
                (x->level[i].forward->score == score &&
                 sdscmp(x->level[i].forward->ele, ele) <= 0)))
        {
            rank += x->level[i].span;        // 累加 span
            x = x->level[i].forward;
        }

        if (x->ele && x->score == score && sdscmp(x->ele, ele) == 0)
            return rank;                     // 找到了
    }
    return 0;                                // 没找到
}
```

**时间复杂度 O(log N)**：只走了一遍查找路径（从最高层到最低层），累加沿路的 span 值。不需要遍历所有 level 1 节点。

### 4.2 ZRANGE——GetElementByRank

```c
// t_zset.c:500-520 — doom-lsp 确认
zskiplistNode* zslGetElementByRank(zskiplist *zsl, unsigned long rank) {
    unsigned long traversed = 0;
    int i;
    x = zsl->header;

    for (i = zsl->level-1; i >= 0; i--) {
        while (x->level[i].forward &&
               (traversed + x->level[i].span) <= rank)
        {
            traversed += x->level[i].span;
            x = x->level[i].forward;
        }
        if (traversed == rank)
            return x;
    }
    return NULL;
}
```

**反向操作**：根据 rank 找到节点。同样 O(log N)——从最高层快速跳过，直到 `traversed + span > rank` 时降层。

### 4.3 ZRANGE——实际遍历

`zrangeCommand`（t_zset.c:3139）最终调用 `zrangeGenericCommand`，使用 `zslGetElementByRank` 找到起始节点，然后沿 level 1 的 `forward` 或 `backward` 顺序遍历：

```c
// t_zset.c:3239 附近的跳表部分
// 先用 zslGetElementByRank 定位起始节点
ln = zslGetElementByRank(zsl, start + 1);

// 然后沿 level 0 的 forward（正向）或 backward（反向）逐个输出
while (ln && limit--) {
    handler->emitResultFromCBuffer(handler, ln->ele, sdslen(ln->ele), ln->score);
    ln = reverse ? ln->backward : ln->level[0].forward;
}
```

**`ZRANGE key 0 -1 WITHSCORES` 的完整路径**：
1. `ZRANGE` → `zrangeGenericCommand` → `zslGetElementByRank(zsl, 1)` → O(log N) 找到第一个节点
2. 沿 `level[0].forward` 逐一 `emitResultFromCBuffer` → O(M) 输出 M 个元素
3. 总复杂度 O(log N + M)

### 4.4 ZRANGEBYSCORE——区间查找

```c
// t_zset.c:313 — doom-lsp 确认
// zslFirstInRange / zslLastInRange 在跳表中查找第一个 / 最后一个在 score 区间内的节点
// 同样 O(log N)：从顶到底，比较 score 与 range 边界
zskiplistNode *zslFirstInRange(zskiplist *zsl, zrangespec *range) {
    x = zsl->header;
    for (i = zsl->level-1; i >= 0; i--) {
        while (x->level[i].forward &&
               !zslValueGteMin(x->level[i].forward->score, range))
            x = x->level[i].forward;
    }
    x = x->level[0].forward;
    if (x && zslValueLteMax(x->score, range)) return x;
    return NULL;
}
```

`zslValueGteMin` / `zslValueLteMax` 处理开闭区间（即 `(1.5` 和 `1.5` 的区别）：

```c
// 开区间：(
spec->minex = 1;    // min exclusive

// zslValueGteMin:
//   minex=0 时：score >= min
//   minex=1 时：score >  min
```

---

## 5. 双结构一致性——dict + zsl

`zset` 同时维护 dict 和 skiplist，两套结构共享同样的 SDS string。一致性是关键。

### 5.1 ZADD——zsetAdd

```c
// t_zset.c:1319-1468 — doom-lsp 确认
int zsetAdd(robj *zobj, double score, sds ele, int in_flags, int *out_flags, double *newscore) {
    // ... 前置检查（NX/XX/GT/LT/INCR 标志、NaN 检查）

    if (zobj->encoding == OBJ_ENCODING_LISTPACK) {
        // listpack 模式：查找 + 更新/插入
        // 检查是否超限 → 切换到 SKIPLIST
    }

    if (zobj->encoding == OBJ_ENCODING_SKIPLIST) {
        zset *zs = zobj->ptr;
        de = dictFind(zs->dict, ele);

        if (de != NULL) {
            // ★ 更新现有元素
            curscore = *(double*)dictGetVal(de);

            if (score != curscore) {
                // 变分：skiplist 删除再插入（O(log N) + O(log N)）
                // dict 更新 score 指针
                znode = zslUpdateScore(zs->zsl, curscore, ele, score);
                dictGetVal(de) = &znode->score;  // dict 指向新节点的 score
            }
        } else {
            // ★ 插入新元素
            ele = sdsdup(ele);                    // 深拷贝 SDS
            znode = zslInsert(zs->zsl, score, ele); // 插入跳表
            dictAdd(zs->dict, ele, &znode->score);   // 插入 dict
            // ★ 同一个 SDS 指针（ele）被 dict 的 key 和
            //    skiplist node 的 ele 共享
        }
    }
}
```

**共享 SDS 的代价**：删除时必须先删 dict，再删 skiplist。

```c
// t_zset.c:1469-1493 — doom-lsp 确认
static int zsetRemoveFromSkiplist(zset *zs, sds ele) {
    de = dictUnlink(zs->dict, ele);
    if (de != NULL) {
        score = *(double*)dictGetVal(de);
        // ★ 先删 dict（unlink），再删 skiplist
        //    因为 skiplist 的 sds 释放会同时干掉 dict 指向的 key
        zslDelete(zs->zsl, score, ele, NULL);
        dictFreeUnlinkedEntry(zs->dict, de);
        return 1;
    }
    return 0;
}
```

为什么删除顺序必须是 **dict 先 → skiplist 后**？因为 `zslDelete` → `zslFreeNode` → `sdsfree(node->ele)` 会释放 dict 中共享的 SDS。如果 skiplist 先释放，dict 的 key 就成了悬垂指针。

### 5.2 变分——zslUpdateScore

```c
// t_zset.c:270-286 附近 — zslUpdateScore
// 如果 score 变化，但新 score 与原位置兼容（前后节点不会越过新 score），
// 直接原地更新 score。否则走删除→再插入。
zskiplistNode *zslUpdateScore(zskiplist *zsl, double curscore, sds ele, double newscore) {
    // ...
    // 尝试原地更新：检查前驱和后继的 score 约束
    // 如果 violate → zslDelete + zslInsert（成本 2 × O(log N)）
}
```

**优化**：如果 score 变化但节点在跳表中的位置不变（前后相邻节点的 score 仍保持区间），直接在原节点上修改 `score` 字段。否则删除再插入。这个优化避免了大多数 ZINCRBY 导致的完整重插。

### 5.3 编码转换——listpack ↔ skiplist

当 ZSet 满足以下条件时，使用 listpack 编码（参见第四篇）：

```c
// server.h:1857-1858
size_t zset_max_listpack_entries;  // 默认 128
size_t zset_max_listpack_value;    // 默认 64
```

`zsetAdd` 中在落入 listpack 分支时：

```c
// t_zset.c:1394
if (zzlLength(zobj->ptr) + 1 > server.zset_max_listpack_entries ||
    sdslen(ele) > server.zset_max_listpack_value ||
    !lpSafeToAdd(zobj->ptr, sdslen(ele)))
{
    zsetConvert(zobj, OBJ_ENCODING_SKIPLIST);
}
```

`zsetConvert`（t_zset.c:1167-1240）遍历 listpack，为每个 entry 创建 dict entry + skiplist node。

反向转换 `zsetConvertToListpackIfNeeded`（t_zset.c:1242）在**元素被删除后**检查条件，如果当前大小回落到阈值以下，从 skiplist 转回 listpack：

```c
void zsetConvertToListpackIfNeeded(robj *zobj, size_t maxelelen, size_t totelelen) {
    if (zobj->encoding == OBJ_ENCODING_LISTPACK) return;
    zset *zset = zobj->ptr;

    if (zset->zsl->length <= server.zset_max_listpack_entries &&
        maxelelen <= server.zset_max_listpack_value &&
        lpSafeToAdd(NULL, totelelen))
    {
        zsetConvert(zobj, OBJ_ENCODING_LISTPACK);
    }
}
```

---

## 6. 内存对比

### 6.1 双结构的内存代价

假设排序集有 N 个元素，skiplist + dict 的开销：

| 组件 | 每个元素的开销 | 总计 |
|------|:------------:|:----:|
| dict entry | 24 字节 + 指针 | ≈ 32N |
| dict 链表达 | — | ≈ 4N |
| skiplist node（平均 level 1.33） | 32+ (1.33×(8+8)) + SDS | ≈ 64N + SDS |
| skiplist header 哨兵 | 32 × (8+8) = 512 字节 | 固定 |
| **双结构总计** | | **≈ 100N + 512 + SDS × N** |

### 6.2 Listpack 编码的记忆效率

当 N ≤ 128 且所有 member 长度 ≤ 64 时，用 listpack：

| 每个元素 | 大小 |
|---------|:----:|
| encoding header | 1-5 字节 |
| member | 1-64 字节 |
| score（double） | 9 字节（8B + 1B encoding） |
| backlen | 1-2 字节 |

**大 ZSet 的 skiplist 内存 ≈ listpack 的 3-5 倍**。以 100 万个元素为例（member 16 字节）：

| 编码 | 估算内存 |
|------|:--------:|
| listpack（如果能用） | ≈ 50 MB |
| skiplist + dict | ≈ 150-200 MB |

所以内存敏感场景能用 listpack 就用——**但问题在于 skiplist 有 O(log N) 的范围查询，而 listpack 的范围查询是 O(N)**。大 ZSet 必须用 skiplist。

---

## 7. 总结与对照

### 7.1 操作复杂度

| 操作 | listpack 编码 | skiplist 编码 |
|------|:-----------:|:------------:|
| `ZADD`（插入/更新） | O(N) | O(log N) |
| `ZSCORE` | O(N) | O(1)（dict） |
| `ZREM` | O(N) + 可能级联 | O(log N)（跳表）+ O(1)（dict） |
| `ZRANK` | O(N) | O(log N)（span 累积） |
| `ZRANGE` start..stop | O(N + M) | O(log N + M) |
| `ZRANGEBYSCORE` | O(N) | O(log N + M) |
| `ZCOUNT` | O(N) | O(log N)（范围查找） |
| `ZCARD` | O(1)（header cache 或扫描） | O(1)（zsl->length） |

### 7.2 与其他数据结构的对比

| 结构 | 排序 | 查找 | 范围查询 | 随机访问 |
|------|:----:|:----:|:--------:|:--------:|
| 平衡树（红黑树） | 有序 O(log N) | O(log N) | 中序遍历 O(log N+M) | ❌ |
| 跳表（Redis） | 有序 O(log N) | O(log N) | level 1 遍历 O(log N+M) | O(log N) via span |
| 哈希表（dict） | 无序 | O(1) | ❌ | ❌ |
| 数组（排序） | 有序 | O(log N) | O(M) | O(1) |
| Listpack | 插入顺序 | O(N) | O(N) | O(N) |

**跳表相对于平衡树的独特优势**：
- span 机制让按 rank 查找（`ZRANGE start stop` 中的 start）也做到 O(log N)
- 实现简单，不容易有实现 bug
- 不需要 rebalance 的开销
- 静态结构（不修改时）开销仅仅是内存

---

## 8. ZSet 命令 → 源码路径速查

| 命令 | 源码入口 | 跳表函数 | dict 函数 |
|------|---------|----------|-----------|
| `ZADD` | `zaddCommand` → `zsetAdd` | `zslInsert` / `zslUpdateScore` | `dictAdd` / `dictFind` |
| `ZREM` | `zremCommand` → `zsetRemoveFromSkiplist` | `zslDelete` | `dictUnlink` |
| `ZSCORE` | `zscoreCommand` → `zsetScore` | — | `dictFind` |
| `ZRANK` | `zrankCommand` | `zslGetRank` | — |
| `ZREVRANK` | `zrevrankCommand` | (反向 rank) | — |
| `ZRANGE` | `zrangeCommand` → `zrangeGenericCommand` | `zslGetElementByRank` + level 0 遍历 | — |
| `ZRANGEBYSCORE` | `zrangebyscoreCommand` | `zslFirstInRange` / `zslLastInRange` + 遍历 | — |
| `ZCARD` | `zcardCommand` | `zsl->length` | — |
| `ZCOUNT` | `zcountCommand` | `zslFirstInRange` + rank 差 | — |
| `ZINCRBY` | `zincrbyCommand` → `zsetAdd` (incr) | `zslUpdateScore` | `dictGetVal` |
