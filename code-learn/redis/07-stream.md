# 07 — Stream：RadixTree + ListPack 的高效消息队列

> Redis 主线源码深度分析系列 · 第七篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Stream 是 Redis 5.0 引入的数据类型，定位是**高性能内存消息队列**。它不是简单的 append-only log——它综合了 RadixTree（基数树）+ ListPack 两种紧凑数据结构的优点，同时支持消费者组（Consumer Group）这种类似 Kafka 的分发语义。

核心设计：

```
Stream
├── rax (radix tree) — 全局索引，按 ID 排序
│   └── listpack(es) — 每个 rax node 存储一批连续消息
├── streamCG (consumer group) — 消费者组
│   ├── rax(pel) — 组级 PEL（Pending Entries List）
│   └── rax(consumers) — 消费者列表
│       └── rax(pel) — 消费者级 PEL
└── streamNACK — 单条待确认消息状态
```

**doom-lsp 确认**：核心文件

| 文件 | 行数 | 职责 |
|------|:----:|------|
| `src/rax.h` | 216 | RadixTree 节点/迭代器/API 定义 |
| `src/rax.c` | 1927 | RadixTree 完整实现 |
| `src/stream.h` | 150 | Stream/CG/Consumer/NACK 定义 + API |
| `src/t_stream.c` | 4035 | XADD/XREAD/XREADGROUP/XTRIM/... 全部实现 |

---

## 1. RadixTree（基数树）

### 1.1 什么是 Radix Tree

RadixTree（又称 Patricia Trie / 压缩前缀树）是一种空间优化的 Trie。不同于传统 Trie 每个节点存一个字符，RadixTree 将**没有分叉的连续字符压缩到一个节点路径**中。

```
传统 Trie：                     RadixTree（压缩）：
                                  root
        root                      │
     ┌───┼───┬───┐           ["foobar"]
     │   │   │   │                │
     a   b   f   g             [a,oo]
     │   │   │   │                │
     n   a   o   o         (end)  ├──────┐
     │   │   │   │                │      │
       ... │   │                  d     o
           o   o                  │      │
           │   │               ["d"]  ["d"]
          b   d                  │      │
           │   │               (end)  (end)
           a   a
           │   │
           r   r
```

Redis 的 rax 实现将**共享前缀**和**连续单链路径**都压缩到一个节点。每个节点要么是**压缩节点**（iscompr=1，一个子节点，路径含多个字符），要么是**非压缩节点**（iscompr=0，多个子节点，每个对应一个字符）。

### 1.2 raxNode——节点的内存布局

```c
// rax.h:98-131 — doom-lsp 确认
typedef struct raxNode {
    uint32_t iskey:1;     // 是否存有 value
    uint32_t isnull:1;    // value 是 NULL
    uint32_t iscompr:1;   // 是否压缩节点
    uint32_t size:29;     // 子节点数量（非压缩）或路径长度（压缩）
    unsigned char data[]; // 柔性数组：字符数据 + 子节点指针 + (可选)value指针
} raxNode;
```

**非压缩节点**（iscompr=0）的 data 布局：

```
[header iscompr=0][abc][a-ptr][b-ptr][c-ptr](value-ptr?)
```

- `size` 字节的字符数据，每个 byte 是一个分支字符
- `size` 个 `raxNode*` 指针，与字符一一对应
- 如果 `iskey=1`，最后附加一个 `void*` value 指针

**压缩节点**（iscompr=1）的 data 布局：

```
[header iscompr=1][xyz][z-ptr](value-ptr?)
```

- `size` 字节的压缩路径字符串
- 只有 **1 个** `raxNode*` 子节点指针
- 如果 `iskey=1`，最后附加一个 `void*` value 指针

**寻址辅助宏**：

```c
// rax.c:141-144 — doom-lsp 确认
// 子节点指针需要对齐到 sizeof(void*) 边界，所以字符数据后有 padding
#define raxPadding(nodesize) \
    ((sizeof(void*)-((nodesize+4) % sizeof(void*))) & (sizeof(void*)-1))

// 第一个子节点指针的位置
#define raxNodeFirstChildPtr(n) ((raxNode**) ((n)->data + (n)->size + raxPadding((n)->size)))

// 节点总大小
#define raxNodeCurrentLength(n) ( \
    sizeof(raxNode) + (n)->size + \
    raxPadding((n)->size) + \
    ((n)->iscompr ? sizeof(raxNode*) : sizeof(raxNode*)*(n)->size) + \
    ((n)->iskey && !(n)->isnull) * sizeof(void*) \
)
```

`raxNode` 是**自描述**的——给定一个指针，通过 `iscompr`、`size`、`iskey`、`isnull` 四个 bit 就能完全解析它的内容和子节点位置。不需要额外的分配元数据。

### 1.3 查找——raxLowWalk

rax 的查找核心函数 `raxLowWalk`（rax.c 内部）从根节点出发，逐层匹配 key：

```
输入 key = "foobar"

root node (iscompr=1, size=6: "foobar")
  → 匹配全部 6 个字符 → 找到！
  → return node（节点 iskey=1 → 有 value）

输入 key = "food"

root node (iscompr=1, size=6: "foobar")
  → 只匹配到 "foo"（4 个字符），第 5 个字符 'b' ≠ 'd'
  → return splitpos=4, miss
  → 需要在 "foo" 处分裂节点：
    "foobar" → "foo" + ["bar", "d"]
```

**最坏情况 O(N)**（N = key 长度 = 128 位 = 16 字节），不是 O(log N)——因为 rax 的查找深度取决于 key 的公共前缀长度，而不是元素数量。对于 Stream ID 这种 128 位的固定长度 key，查找总是 O(16)。

### 1.4 插入——raxInsert

```c
// rax.c:904 — doom-lsp 确认
int raxInsert(rax *rax, unsigned char *s, size_t len, void *data, void **old)
```

插入过程：
1. `raxLowWalk` 沿路径行走，记录栈踪（`raxStack` 保存父节点链）
2. 如果完全匹配且 iskey=1 → 替换已有 value
3. 如果不完全匹配 → 在 split 位置分裂节点
4. 创建新叶子节点，插入子节点指针
5. 更新 `numele` / `numnodes`

**当 Stream 插入新 ID 时**，这个 ID 被编码为 16 字节 big-endian，作为 key 插入 rax。由于 ID 是连续的（近似），增量 XADD 都会落在同一个 rax node 中——直到 listpack 满了才分裂新节点。

### 1.5 删除——raxRemove

```c
// rax.c:1022 — doom-lsp 确认
int raxRemove(rax *rax, unsigned char *s, size_t len, void **old)
```

1. `raxLowWalk` 找到节点
2. 删除 iskey 标记，清除 value 指针
3. 如果删除后节点没有子节点 → 向上回溯，删除空节点
4. 如果兄弟节点可以合并（压缩路径相连）→ 合并节点

### 1.6 迭代器——raxSeek / raxNext / raxPrev

```c
// rax.c:1511 — doom-lsp 确认
int raxSeek(raxIterator *it, const char *op, unsigned char *ele, size_t len);
int raxNext(raxIterator *it);   // 前向遍历
int raxPrev(raxIterator *it);   // 后向遍历
```

`raxSeek` 支持操作符：
- `"^"` — 跳到第一个 key
- `"$"` — 跳到最后一个 key
- `">"` — 跳到大于 ele 的第一个 key
- `"<"` — 跳到小于 ele 的第一个 key
- `"="` — 跳到等于 ele 的 key
- `">="` — 跳到大于等于 ele 的第一个 key

`raxNext` / `raxPrev` 通过中序遍历（depth-first 顺序）逐个输出 key。

Stream 的 XREAD / XRANGE 基于 rax 迭代器实现：

```
XRANGE stream 1700000000000-0 +∞  COUNT 100
  → raxSeek(it, ">=", encode(1700000000000-0))  // 跳到起始 ID
  → raxNext(it) × 100                            // 遍历 100 条
```

---

## 2. Stream 的底层编码——RadixTree of ListPacks

### 2.1 总体结构

```
Stream（内存结构）
│
└── rax (radix tree)
    │
    ├── node_key = encode(1700000000000-0)    → listpack (消息 0~999)
    ├── node_key = encode(1700000000100-0)    → listpack (消息 1000~1999)
    ├── node_key = encode(1700000000200-0)    → listpack (消息 2000~2999)
    └── ...
```

rax 的 key 是 **streamID 的 16 字节 big-endian 编码**。每个 rax 节点的 value 是一个 **listpack**（参见第四篇），内部存储一批连续的消息。

为什么是 big-endian？因为 rax 按**字典序**存储 key，big-endian 编码保证了：
- `ms` 高位在前 → 时间戳大的 ID 自然排在后面
- `seq` 跟在 ms 后面 → 同毫秒内的 ID 按 seq 递增

```c
// t_stream.c:492 — doom-lsp 确认
// streamID 编码为 128 位 big-endian，共 16 字节
void streamEncodeID(void *buf, streamID *id) {
    uint64_t ms = htonu64(id->ms);
    uint64_t seq = htonu64(id->seq);
    memcpy(buf, &ms, sizeof(ms));
    memcpy(buf+8, &seq, sizeof(seq));
}
```

### 2.2 Master Entry——消息压缩

这是 Stream 最巧妙的设计。每个 listpack 的第一个 entry 是一个**主条目（master entry）**，记录该 listpack 中所有消息共享的字段名：

```
Master Entry 结构（listpack 中的第一条）：
┌───────┬──────────┬────────────┬─────────┬─────┬─────────┬──────┐
│ count │  deleted │ num-fields │ field_1 │ ... │ field_N │  0   │
│ (int) │  (int)   │   (int)    │ (string)│     │ (string)│(term)│
└───────┴──────────┴────────────┴─────────┴─────┴─────────┴──────┘
```

后面的消息 entry：

```
标准编码（字段不同）：
┌───────┬─────────┬─────────┬──────────┬───────┬─────┬──────────┬──────────┐
│ flags │ ms-diff │seq-diff │num-fields│field_1│ ... │  value_N │lp-count  │
│(int)  │ (int)   │ (int)   │  (int)   │(string)│    │ (string) │  (int)   │
└───────┴─────────┴─────────┴──────────┴───────┴─────┴──────────┴──────────┘

SAMEFIELDS 编码（字段与 master 相同）：
┌───────┬─────────┬─────────┬───────┬─────┬──────────┬──────────┐
│ flags │ ms-diff │seq-diff │val_1  │ ... │  value_N │lp-count  │
│ &SAMEFIELDS    │         │       │     │          │          │
└───────┴─────────┴─────────┴───────┴─────┴──────────┴──────────┘
```

**`STREAM_ITEM_FLAG_SAMEFIELDS`**（标志位 `1<<1`）是压缩关键。当消息的字段与 master entry 完全相同时（大多数场景——`XADD mystream * temp 25.1 humidity 0.80` 每次字段都一样），**字段名不需要重复存储**。只存 value 即可。

```c
// t_stream.c:644-662 — doom-lsp 确认
if (numfields == master_fields_count) {
    // 逐个比较字段名
    for (i = 0; i < master_fields_count; i++) {
        sds field = argv[i*2]->ptr;
        if (sdslen(field) != (size_t)e_len || memcmp(e,field,e_len) != 0)
            break;
        lp_ele = lpNext(lp, lp_ele);
    }
    if (i == master_fields_count)
        flags |= STREAM_ITEM_FLAG_SAMEFIELDS;  // 全部匹配 → 压缩！
}
```

### 2.3 消息 ID 的 delta 编码

消息 ID 不存完整 `ms` 和 `seq`，而是存与 **master entry 的 ID** 的差值：

```c
// t_stream.c:656-658 — doom-lsp 确认
lp = lpAppendInteger(lp, id.ms - master_id.ms);   // ms delta
lp = lpAppendInteger(lp, id.seq - master_id.seq);  // seq delta
```

由于一个 listpack 中的 ID 是连续的（在同一个 rax node 中），`ms-diff` 通常是 0 或很小的数，`seq-diff` 从 1 开始递增。listpack 的整数编码用最小字节数存储这些差值。

### 2.4 lp-count——反向遍历

每个消息 entry 末尾有一个 `lp-count` 字段，记录了这个 entry 占了多少个 listpack element。反向遍历时从尾部 `lpPrev()` 读取 `lp-count`，然后向前跳 N 步到 `flags` 位置。不需要扫完整条消息就能定位到下一个 entry。

```c
// t_stream.c:662-668 — doom-lsp 确认
int64_t lp_count = numfields;
lp_count += 3; // flags + ms-diff + seq-diff
if (!(flags & STREAM_ITEM_FLAG_SAMEFIELDS)) {
    lp_count += numfields + 1; // + num-fields + 各 field 名
}
lp = lpAppendInteger(lp, lp_count);
```

### 2.5 什么时候切分新 listpack

`streamAppendItem` 在 `t_stream.c:535-549` 检查两个条件：

```c
// t_stream.c:535 — doom-lsp 确认
if (lp_bytes + totelelen >= node_max_bytes) {
    new_node = 1; // ★ 字节超限 → 切新节点
} else if (server.stream_node_max_entries) {
    // ★ 条目超限 → 切新节点
    int64_t count = lpGetInteger(lp_ele) + lpGetInteger(lpNext(lp,lp_ele));
    if (count >= server.stream_node_max_entries) new_node = 1;
}
```

| 配置项 | 默认值 | 作用 |
|--------|:------:|------|
| `stream-node-max-bytes` | 4096 | 每个 listpack 最大字节数 |
| `stream-node-max-entries` | 100 | 每个 listpack 最大消息数 |

当配置为 0 时表示"不限制"。两个条件任一满足就创建新的 rax node + 新的 listpack。

---

## 3. streamAppendItem——XADD 核心

```c
// t_stream.c:426 — doom-lsp 确认
int streamAppendItem(stream *s, robj **argv, int64_t numfields,
                     streamID *added_id, streamID *use_id, int seq_given)
```

完整流程：

```
XADD mystream * temp 25.1 humidity 0.80

1. 生成 ID：当前毫秒时间戳 + seq
   → 如果与 last_id 在同一毫秒，seq++

2. 检查 ID 递增性：streamCompareID(&id, &s->last_id) > 0

3. 计算总数据大小：totelelen = sum of all field+value lengths

4. 定位尾节点：
   raxSeek(&ri, "$", NULL, 0)  // 跳到 rax 最末尾的 node
   读取末尾 listpack 的字节数 lp_bytes

5. 检查是否需要新节点：
   如果 lp_bytes + totelelen ≥ node_max_bytes → 创建新 rax node

6. 创建/更新 master entry：
   如果是新 listpack：写入 master entry（count=1, deleted=0, 字段名）
   如果是旧 listpack：count++

7. 写入消息 entry：
   flags | ms-diff | seq-diff | (fields) | (values) | lp-count
   如果字段与 master 相同 → SAMEFIELDS，省略字段名

8. 更新 rax 树中的 listpack 指针
   s->length++; s->last_id = id;
```

---

## 4. XTRIM——消息淘汰

```c
// t_stream.c:700 — doom-lsp 确认
int64_t streamTrim(stream *s, streamAddTrimArgs *args)
```

两种淘汰策略：

### 4.1 MAXLEN——按长度修剪

```
XTRIM mystream MAXLEN ~ 1000
```

`~` 表示近似模式。在近似模式下，只**整节点删除**——如果 rax 头节点的消息数 ≤ maxlen 就不删。这避免了频繁的 listpack 尾部删除。

非近似模式（不给出 `~`）会精确逐条删除，但这会导致 listpack 内部的删除操作。

### 4.2 MINID——按 ID 修剪

```
XTRIM mystream MINID ~ 1700000000000-0
```

删除所有 ID 早于指定值的消息。同样有近似模式，只整节点删。

近似修剪在 `streamTrim` 中的实现：

```c
// t_stream.c:755-771 — 近似修剪的核心
// 如果近似模式，检查是否可以删除整个 rax node
// 基于 listpack 头部记录的 count 和 deleted 信息
int64_t entries = lpGetInteger(p);  // 有效消息数
int64_t deleted = ...               // 已删除消息数

// MAXLEN: 如果 s->length - entries > maxlen → 删整个节点
// MINID: 如果整个节点的 ID < minid → 删整个节点
```

**整节点删除**的优势：raxRemove 一次 O(N) 调用 + zfree 释放整个 listpack，比逐条删除高效得多。

---

## 5. 消费者组——Consumer Group

### 5.1 数据结构

```c
// stream.h:136-148 — doom-lsp 确认
typedef struct streamCG {
    streamID last_id;           // 组内最后递送的消息 ID
    long long entries_read;     // 组累计读取消息数
    rax *pel;                   // 组级待确认列表（radix tree）
    rax *consumers;             // 消费者列表（radix tree）
} streamCG;

typedef struct streamConsumer {
    mstime_t seen_time;         // 最后活跃时间
    sds name;                   // 消费者名称
    rax *pel;                   // 消费者级 PEL（指向与组级 PEL 相同的 streamNACK）
} streamConsumer;

typedef struct streamNACK {
    mstime_t delivery_time;     // 上次递送时间
    uint64_t delivery_count;    // 递送次数
    streamConsumer *consumer;   // 最后递送的消费者
} streamNACK;
```

### 5.2 消息递送与 PEL（Pending Entries List）

```
XREADGROUP GROUP mygroup consumer1 COUNT 10 STREAMS mystream >

1. raxSeek 从组 last_id 开始遍历 rax 树
2. 遍历 listpack 中的消息
3. 对每条消息：
   a. 创建 streamNACK（delivery_time=now, delivery_count=1）
   b. 加入组级 PEL（streamCG->pel）
   c. 加入消费者级 PEL（streamConsumer->pel）— 共享相同 streamNACK*
4. 更新组 last_id
5. 返回消息给客户端

XACK mystream mygroup 1700000000000-0

1. 从组级 PEL（rax）中删除该消息 ID
2. 从消费者 PEL 中删除
3. 释放 streamNACK
```

**PEL 使用 radix tree**：key 是消息 ID 的 16 字节 big-endian 编码，value 是 `streamNACK*`。这使得 `XACK` 可以在 O(1) ~ O(16) 时间内找到待确认消息，也使得 `XPENDING` 遍历 PEL 是按 ID 序的。

---

## 6. Stream 的迭代器

```c
// stream.h:86-112 — doom-lsp 确认
typedef struct streamIterator {
    stream *stream;
    streamID master_id;                 // 当前 listpack master entry 的 ID
    uint64_t master_fields_count;       // master entry 的字段数
    unsigned char *master_fields_start; // master entry 字段开始位置
    unsigned char *master_fields_ptr;   // 当前字段位置
    int entry_flags;                    // 当前 entry 的 flags
    int rev;
    int skip_tombstones;
    uint64_t start_key[2];              // 起始 ID（128bit big-endian）
    uint64_t end_key[2];                // 结束 ID
    raxIterator ri;                     // rax 迭代器
    unsigned char *lp;                  // 当前 listpack
    unsigned char *lp_ele;              // 当前 listpack entry 位置
    unsigned char *lp_flags;            // 当前 entry 的 flags 位置
    unsigned char field_buf[LP_INTBUF_SIZE];  // 字段字符串缓冲区
    unsigned char value_buf[LP_INTBUF_SIZE];  // 值字符串缓冲区
} streamIterator;
```

使用方式（`streamReplyWithRange` 内部）：

```c
streamIteratorStart(&si, stream, &start_id, &end_id, rev);
while (streamIteratorGetID(&si, &id, &numfields)) {
    // 读取字段值对
    while (numfields--) {
        streamIteratorGetField(&si, &field, &value, &flen, &vlen);
    }
}
streamIteratorStop(&si);
```

**streamIteratorStart** 在 raxSeek 中定位起始 ID，加载第一个 listpack。

**streamIteratorGetID** 在 listpack 内遍历 entry，根据 SAMEFIELDS flag 决定是否从 master entry 读取字段名。

**streamIteratorGetField** 逐一返回 field/value，使用 `field_buf`/`value_buf` 处理整数到字符串的转换。

---

## 7. 性能与内存分析

### 7.1 时间复杂度

| 操作 | 复杂度 | 说明 |
|------|:------:|------|
| `XADD` | O(M) | M = field 数，插入到尾部 listpack，O(1) 均摊 |
| `XRANGE` start..end | O(log N + K) | N = rax node 数，K = 返回消息数 |
| `XREAD` | O(log N + K) | 与 XRANGE 相同 |
| `XREADGROUP` | O(K + PEL 操作) | 除读取外还需维护 PEL |
| `XACK` | O(log P) | P = PEL 大小（rax tree 查找） |
| `XPENDING` | O(log P) | rax 迭代器扫描 |
| `XTRIM ~ MAXLEN` | O(整节点删除) | 只需要删除头部的 rax node |
| `XDEL` | O(log N) | 在 listpack 中标记删除位 |

### 7.2 内存效率

假设消息 `{"temp": 25.1, "humidity": 0.80}`，10 字节 + 8 字节的大致值：

| 模式 | 每条消息 |
|------|:--------:|
| Master entry + SAMEFIELDS + delta ID | ~44 字节 |
| 无 SAMEFIELDS（字段不同） | ~72 字节 |
| 直接用 dict 存储每条消息 | ~120+ 字节 |

Stream 的紧凑编码在字段重复率高的场景下（日志、时序数据）内存效率显著优于逐条 dict。

---

## 8. 从第一篇到第七篇的完整数据模型

```
redisObject (16B)
│
├── OBJ_STRING
│   ├── OBJ_ENCODING_RAW       → sds (02)
│   ├── OBJ_ENCODING_EMBSTR    → robj+sds 融合 (02)
│   └── OBJ_ENCODING_INT       → 共享整数
│
├── OBJ_LIST
│   └── OBJ_ENCODING_QUICKLIST → quicklist of listpack nodes (04)
│
├── OBJ_HASH
│   ├── OBJ_ENCODING_LISTPACK  → listpack (04)
│   └── OBJ_ENCODING_HT        → dict (03)
│
├── OBJ_ZSET
│   ├── OBJ_ENCODING_LISTPACK  → listpack (04)
│   └── OBJ_ENCODING_SKIPLIST  → zset(dict+skiplist) (05)
│
├── OBJ_SET
│   ├── OBJ_ENCODING_INTSET    → intset (06)
│   └── OBJ_ENCODING_HT        → dict (03)
│
└── OBJ_STREAM
    └── OBJ_ENCODING_STREAM    → rax(tree) of listpack (07, 本文)
```

至此，Redis 所有 7 种核心数据结构的底层编码都已覆盖完整。
