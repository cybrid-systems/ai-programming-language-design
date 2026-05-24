# 18 — SORT：Redis 最复杂的命令

> Redis 主线源码深度分析系列 · 第十八篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

如果说 DEL 是最危险的命令，那 SORT 就是 Redis 中**最复杂的命令**。它融合了：

- 多种输入类型的处理（List / Set / Sorted Set）
- SQL 风格的 LIMIT、ASC/DESC、BY、GET 从句
- 可选的 STORE 目标
- 用 `qsort` 或 `pqsort`（partial qsort）做排序
- 跨 key 的间接值查找（`BY pattern*`）
- 哈希 field 的间接 GET（`->` 语法）

注释直接警告：`/* The SORT command is the most complex command in Redis. */`

**doom-lsp 确认**：核心文件

| 文件 | 行数 | doom-lsp 符号数 |
|------|:----:|:-------------:|
| `src/sort.c` | 616 | 7 |
| `src/pqsort.c` | — | partial qsort 实现 |

```
type redisSortOperation @38        // GET 操作（type + pattern）
fn createSortOperation @38         // 创建 GET 操作节点
fn lookupKeyByPattern @61          // ★ 模式替换 + 键值查找（含 hash "->" 语法）
fn sortCompare @138                // ★ qsort 比较器（数字/字母序/desc）
fn sortCommandGeneric @189         // ★ 主函数（~430 行）
fn sortroCommand @610              // SORT_RO（只读变体）
fn sortCommand @614                // SORT（写变体）
```

---

## 1. 参数解析——SQL 风格的从句

```c
void sortCommandGeneric(client *c, int readonly) {
    // 解析从句，循环迭代 argv[2..]:
    while(j < c->argc) {
        if (!strcasecmp(c->argv[j]->ptr, "asc")) {
            desc = 0;                    // 升序
        } else if (!strcasecmp(...,"desc")) {
            desc = 1;                    // 降序
        } else if (!strcasecmp(...,"alpha")) {
            alpha = 1;                   // 字典序
        } else if (!strcasecmp(...,"limit") && leftargs >= 2) {
            getLongFromObjectOrReply(c, argv[j+1], &limit_start, NULL);
            getLongFromObjectOrReply(c, argv[j+2], &limit_count, NULL);
        } else if (!strcasecmp(...,"store") && leftargs >= 1) {
            storekey = argv[j+1];        // 结果存入 key
        } else if (!strcasecmp(...,"by") && leftargs >= 1) {
            sortby = argv[j+1];          // BY 权重模式
            if (strchr(pattern, '*') == NULL)
                dontsort = 1;            // ★ 无 '*' → 不排序
        } else if (!strcasecmp(...,"get") && leftargs >= 1) {
            listAddNodeTail(operations,
                createSortOperation(SORT_OP_GET, argv[j+1]));
        }
    }
}
```

**SORT 的完整语法**：
```
SORT <key>
  [ASC | DESC]           ← 排序方向
  [ALPHA]                ← 字母序（默认数字序）
  [BY <pattern>]         ← 用外部 key 的值排序
  [LIMIT <offset> <count>] ← 分页
  [GET <pattern> [...]]  ← 提取外部 key
  [STORE <dest>]         ← 结果存为新 list
```

---

## 2. 值查找——lookupKeyByPattern

这是 SORT 中最有特色的一个函数。它实现 `BY` 和 `GET` 从句中的模式替换。

```c
// sort.c:61 — doom-lsp 确认
robj *lookupKeyByPattern(redisDb *db, robj *pattern, robj *subst) {
    // 模式 "#" 直接返回 subst 本身
    if (spat[0] == '#' && spat[1] == '\0') {
        incrRefCount(subst);
        return subst;         // SORT key GET # → 返回元素本身
    }

    // 查找 '*' 的位置
    p = strchr(spat, '*');
    if (!p) return NULL;       // 无通配符，返回 NULL

    // ★ 检测 "->" 语法（hash field 引用）
    if ((f = strstr(p+1, "->")) != NULL && *(f+2) != '\0') {
        fieldlen = sdslen(spat) - (f - spat) - 2;
        fieldobj = createStringObject(f+2, fieldlen);
    }

    // 用 subst 替换 '*' → 构造完整 key 名
    keyobj = sdsnewlen(NULL, prefixlen + sublen + postfixlen);
    memcpy(k, spat, prefixlen);           // 前缀
    memcpy(k+prefixlen, ssub, sublen);    // 替换内容
    memcpy(k+prefixlen+sublen, p+1, postfixlen);  // 后缀

    // 查找该 key
    o = lookupKeyRead(db, keyobj);
    if (o == NULL) goto noobj;

    if (fieldobj) {
        // → 语法：从 hash 中取 field
        o = hashTypeGetValueObject(o, fieldobj->ptr);
    } else {
        incrRefCount(o);
    }
    return o;
}
```

**模式替换例子**：

| 场景 | 模式 | subst | 生成的 key | 结果 |
|------|------|-------|-----------|------|
| GET 自身 | `#` | `"apple"` | — | `"apple"` |
| BY 权重 | `weight_*` | `"obj:1"` | `weight_obj:1` | 该 key 的值（做排序权重） |
| GET 名称 | `name_*` | `"obj:1"` | `name_obj:1` | 该 key 的值（作为结果输出）|
| 哈希 field | `user:*->name` | `"42"` | `user:42` 的 hash field `name` | 该 field 的值 |

**典型用法**：

```
SORT user_ids                 ← 排序元素集合（假设是 1, 42, 99）
  BY user:*->age              ← 按 user:<id> 哈希表的 age 字段排序
  GET user:*->name            ← 输出 user:<id> 哈希表的 name 字段
  GET user:*->email           ← 输出 email 字段
  LIMIT 0 10                  ← 只取前 10 条
```

---

## 3. 排序向量——加载数据

```c
// 根据集合类型加载元素到排序向量
switch(sortval->type) {
case OBJ_LIST:
    // 遍历 quicklist，逐个拿出元素
    listTypeIterator *li = listTypeInitIterator(sortval, 0, LIST_TAIL);
    while(listTypeNext(li, &entry)) {
        vector[j].obj = listTypeGet(&entry);
        j++;
    }
    break;

case OBJ_SET:
    // 遍历 intset 或 dict
    while((sdsele = setTypeNextObject(si)) != NULL) {
        vector[j].obj = createObject(OBJ_STRING, sdsele);
        j++;
    }
    break;

case OBJ_ZSET:
    if (dontsort && LIMIT) {
        // ★ 优化：利用 skiplist 的 ZRANGE 语义
        // 用 zslGetElementByRank 直接定位 start，
        // 然后沿 level0 链表顺序取 range 个元素
        ln = zsl->tail;
        if (start > 0)
            ln = zslGetElementByRank(zsl, zsetlen - start);
        while(rangelen--) {
            vector[j].obj = createStringObject(ln->ele, ...);
            ln = desc ? ln->backward : ln->level[0].forward;
        }
    } else {
        // 全量遍历 dict（skiplist 全扫描）
    }
    break;
}
```

**ZSet + dontsort + LIMIT 的三重优化**：如果 SORT ZSet 不用 `BY`（`dontsort`）且指定了 `LIMIT`，不用加载全部元素，而是用 `zslGetElementByRank` 直接跳到起始位置，只加载 `range` 个元素。排序向量的大小从 N 降为 range，qsort 复杂度从 O(N log N) 降为 O(range log range)。

---

## 4. 排序——qsort 与 pqsort

```c
// 计算排序权重
for (j = 0; j < vectorlen; j++) {
    if (sortby) {
        // ★ 按 BY 模式查找权重 key
        byval = lookupKeyByPattern(c->db, sortby, vector[j].obj);
    } else {
        byval = vector[j].obj;  // ★ 没 BY → 用元素自身排序
    }

    if (alpha) {
        vector[j].u.cmpobj = getDecodedObject(byval);  // 存字符串
    } else {
        vector[j].u.score = strtod(byval->ptr, &eptr);  // 转浮点数
    }
}

// ★ 排序
if (sortby && (start != 0 || end != vectorlen-1))
    pqsort(vector, vectorlen, sizeof(redisSortObject),
           sortCompare, start, end);
else
    qsort(vector, vectorlen, sizeof(redisSortObject), sortCompare);
```

**`pqsort`（partial qsort）**：只排序 `[start, end]` 区间，其余部分不保证有序。当 `LIMIT start count` 只取部分结果时，`qsort` 全排浪费 O(N log N)，`pqsort` 只排必要的区间效率更高。

**`sortCompare`**（`sort.c:138`）——统一的比较器：

```c
int sortCompare(const void *s1, const void *s2) {
    if (!server.sort_alpha) {
        // ★ 数字序
        if (so1->u.score > so2->u.score) cmp = 1;
        else if (so1->u.score < so2->u.score) cmp = -1;
        else cmp = compareStringObjects(so1->obj, so2->obj);
               // ↑ score 相同→字典序兜底（保证确定性）
    } else {
        // ★ 字母序
        if (server.sort_store)
            cmp = compareStringObjects(so1->u.cmpobj, so2->u.cmpobj);
        else
            cmp = strcoll(so1->u.cmpobj->ptr, so2->u.cmpobj->ptr);
    }
    return server.sort_desc ? -cmp : cmp;
}
```

**确定性保障**：当数字排序中两个元素的 score 相同时，用 `compareStringObjects`（字典序）兜底。这确保了在 AOF 重放或 replica 执行相同的 SORT 命令时得到完全一致的结果。

---

## 5. 输出——GET 和 STORE

### 5.1 直接回复

```c
// 无 STORE → 直接回复 client
for (j = start; j <= end; j++) {
    if (!getop)
        addReplyBulk(c, vector[j].obj);    // 直接输出元素
    else
        // 执行 GET 操作
        while((ln = listNext(&li))) {
            val = lookupKeyByPattern(c->db, pattern, vector[j].obj);
            addReplyBulk(c, val);
        }
}
```

### 5.2 STORE

```c
// ★ STORE → 结果存为 list
robj *sobj = createQuicklistObject();
for (j = start; j <= end; j++) {
    listTypePush(sobj, vector[j].obj, LIST_TAIL);
}
setKey(c, c->db, storekey, &sobj, 0);
```

当 `STORE dest` 且没有 `GET` 时，SORT 的结果是一个 list。这常用于在服务端缓存排序结果，避免重复排序。

```c
redis> SORT huge_set BY weight_* GET name_* GET score_* STORE cache
(integer) 5000   // 存了 5000 个元素到 cache key 中
redis> LRANGE cache 0 -1  // 以后直接取，不用再 SORT
```

---

## 6. 只读变体——SORT_RO

```c
// sort.c:610 — doom-lsp 确认
void sortroCommand(client *c) {
    sortCommandGeneric(c, 1);   // readonly = 1
}

void sortCommand(client *c) {
    sortCommandGeneric(c, 0);   // readonly = 0
}
```

`SORT_RO`（Redis 7.0+）是 `SORT` 的只读变体，拒绝 `STORE` 选项。在 Redis Cluster 中可免去 `STORE` 带来的跨 slot 写操作风险。同时 ACL 系统中可以对 `SORT_RO` 和 `SORT` 分别设置权限。

---

## 7. 性能特征

| 因素 | 影响 |
|------|------|
| **排序 N 个元素** | qsort O(N log N)，$ 建议元素数 ≤ 10000 |
| **BY 模式** | 每次 N 次 `lookupKeyByPattern` 查找，每个额外的 key 查找 O(1) |
| **GET 多字段** | 每个元素 × 每个 GET 从句的 `lookupKeyByPattern` |
| **ZSet + dontsort + LIMIT** | O(log N + range) 级别，无需全量排序 |
| **pqsort vs qsort** | pqsort 只排 LIMIT 区间，小范围时显著快于全排 |
| **STORE 到 list** | O(range) 的 quicklist 构建 |

---

## 8. 与系列前文的联系

```
SORT list
  → lookupKeyRead                ← db.c (13)
  → listTypeInitIterator         ← listType（quicklist 遍历）(04)
  → setTypeNextObject            ← setType（intset/dict 遍历）(06, 03)
  → zslGetElementByRank          ← zskiplist (05)
  → lookupKeyByPattern           ← db.c lookupKeyRead (13)
    → hashTypeGetValueObject     ← hash 遍历 (04)
  → qsort / pqsort               ← 标准库
  → addReplyBulk                 ← networking.c (09)
  → setKey / listTypePush        ← db.c (13) / quicklist (04)
```

SORT 命令像一个"万用瑞士军刀"，它整合了 Redis 中几乎所有数据结构的遍历能力——并且通过 `BY`/`GET` 模式替换间接访问其他 key。

---

## 9. 命令示例速查

```bash
# 按自身排序（数字序）
SORT numbers

# 按自身排序（字母序）
SORT names ALPHA

# 降序 + 分页
SORT user_scores DESC LIMIT 0 3

# 按外部 key 的值排序
SORT user_ids BY user:*->age

# 排序后 GET 多个字段 + 缓存
SORT user_ids BY user:*->age GET user:*->name GET user:*->email STORE result

# 只读变体（Redis 7+）
SORT_RO user_ids BY user:*->age GET user:*->name
```
