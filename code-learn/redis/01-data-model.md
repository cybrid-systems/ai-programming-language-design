# 01 — 数据模型：redisObject 的艺术

> Redis 主线源码深度分析系列 · 第一篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

数据模型是数据库的起点。你往里面塞什么数据、数据怎么在内存里表示、数据怎么落盘——这些选择决定了整个系统的发展方向。

Redis 的数据模型用一个 16 字节的 `redisObject`（简称 robj）解决了所有问题。它是 Redis 最核心的结构体，每个键值对、每个操作对象都离不开它。

本文用 `doom-lsp`（clangd LSP）对 Redis 主线源码进行逐行符号解析，逐字段追踪它的设计哲学。

**doom-lsp 确认**：核心文件分布

| 文件 | 行数 | 职责 |
|------|------|------|
| `src/server.h` | ~2700 | redisObject 定义、type/encoding 宏、sharedObjectsStruct |
| `src/object.c` | ~600 | createObject、makeObjectShared、对象操作原语 |
| `src/t_string.c` | ~500 | STRING 类型命令实现 |
| `src/t_hash.c` | ~1200 | Hash 类型编码切换 |
| `src/t_zset.c` | ~1500 | ZSet skiplist 编码切换 |
| `src/encoding.c` | ~400 | 编码转换通用逻辑 |

---

## 1. redisObject——永远 16 字节的统一包装

### 1.1 结构体定义

```c
// server.h:858-866 — doom-lsp 确认
typedef struct redisObject {
    unsigned type:4;         // [0:4)   对象类型：STRING/LIST/SET/ZSET/HASH/STREAM/MODULE
    unsigned encoding:4;    // [4:8)   编码方式：RAW/INT/HT/SKIPLIST/QUICKLIST/LISTPACK/...
    unsigned lru:LRU_BITS;   // [8:32)  LRU 时钟或 LFU 频率计数器
    unsigned hasexpire:1;   //         是否设置了过期时间（bit flag）
    unsigned hasembkey:1;    //         是否为 EMBSTR 编码（bit flag）
    unsigned refcount:OBJ_REFCOUNT_BITS; // [0:58) 引用计数，支撑共享对象
    void *ptr;               //         指向实际数据结构（8 字节）
} robj;
```

**固定 16 字节**。这是 Redis 最核心的设计选择——无论你存储什么类型的数据，每个值的元包装都是相同的 16 字节。这使得：
- **内存分配极简**：`zmalloc(sizeof(robj))` 永远是 16 字节，内存分配器完全可预测
- **对象池化**：所有 robj 共享同一个内存池，无需按类型区分
- **缓 cache-line 友好**：16 字节刚好可以被 L1 cache 充分利用

### 1.2 type 字段——对象逻辑类型（4 bit）

```c
// server.h:649-667 — doom-lsp 确认
#define OBJ_STRING 0    /* String object. */
#define OBJ_LIST 1      /* List object. */
#define OBJ_SET 2       /* Set object. */
#define OBJ_ZSET 3      /* Sorted set object. */
#define OBJ_HASH 4      /* Hash object. */
/* The "module" object type is a special one that signals that the object
 * is one directly managed by a Redis module... */
#define OBJ_MODULE 5    /* Module object. */
#define OBJ_STREAM 6    /* Stream object. */
```

共 7 种对象类型。`type` 字段回答"这个对象是什么语义"，是命令分派的第一个判断维度。

### 1.3 encoding 字段——对象物理编码（4 bit）

```c
// server.h:837-847 — doom-lsp 确认
#define OBJ_ENCODING_RAW 0     /* Raw representation: sds 动态字符串 */
#define OBJ_ENCODING_INT 1     /* 整数值（ptr 位置直接存 int64_t，无额外分配） */
#define OBJ_ENCODING_HT 2      /* 哈希表（dict）编码 */
#define OBJ_ENCODING_ZIPMAP 3  /* 已废弃：旧版 Hash 编码 */
#define OBJ_ENCODING_LINKEDLIST 4 /* 已废弃：旧版 List 编码 */
#define OBJ_ENCODING_ZIPLIST 5 /* 已废弃：旧版 List/Hash/ZSet 编码 */
#define OBJ_ENCODING_INTSET 6  /* 整数集合（Set 专用） */
#define OBJ_ENCODING_SKIPLIST 7 /* 跳表（ZSet 专用） */
#define OBJ_ENCODING_EMBSTR 8  /* 内嵌 sds（短字符串，≤44 字节，一次分配 38 字节） */
#define OBJ_ENCODING_QUICKLIST 9 /* 双向链表 + listpack（List 专用） */
#define OBJ_ENCODING_STREAM 10 /* RadixTree + listpack（Stream 专用） */
#define OBJ_ENCODING_LISTPACK 11 /* 单 listpack（String/Hash 可选） */
```

`encoding` 字段回答"这个对象在物理上怎么存储"。**type 和 encoding 完全独立**，这是 Redis 最精妙的设计——同一个逻辑类型可以用完全不同的物理方式存储。

---

## 2. type × encoding 组合空间

### 2.1 完整组合矩阵

```
┌─────────────────────────────────────────────────────────────────────┐
│  STRING (type=0)                                                    │
│  ├── RAW   (encoding=0)  → sds 动态字符串（>44 字节）              │
│  ├── EMBSTR (encoding=8)  → 38 字节内嵌 sds（≤44 字节）            │
│  │                            一次分配：robj(16B) + sdshdr8(3B) +  │
│  │                              字符串(≤44B) = 63B total           │
│  └── INT    (encoding=1)  → int64_t（数值字符串专用）              │
│                               特殊处理：ptr 实际存 int64_t 值，     │
│                               无额外堆分配                          │
├─────────────────────────────────────────────────────────────────────┤
│  LIST (type=1)                                                     │
│  ├── QUICKLIST (encoding=9) → 双向链表，每个节点是 listpack         │
│  │                            head 和 tail 各一个 listpack         │
│  └── LISTPACK  (encoding=11)→ 扁平 listpack（特殊情况，如 LPILT）   │
├─────────────────────────────────────────────────────────────────────┤
│  HASH (type=4)                                                     │
│  ├── HT      (encoding=2) → dict 哈希表（字段多时）                │
│  │                            fields 存在 dict 中，values 也是      │
│  └── LISTPACK (encoding=11)→ 单 listpack（字段少时，类似旧 ziplist）│
│                              触发条件：字段数 ≤ 512 且             │
│                              所有 value 长度 ≤ 64 字节              │
├─────────────────────────────────────────────────────────────────────┤
│  ZSET (type=3)                                                     │
│  ├── SKIPLIST (encoding=7) → dict + skiplist 双结构                │
│  │                            dict: member → score（O(1) 查找）     │
│  │                            skiplist: score → member（O(log N) 范围）│
│  └── LISTPACK  (encoding=11)→ 单 listpack（成员少时）              │
│                              触发条件：成员数 ≤ 128 且             │
│                              所有 member 长度 ≤ 64 字节            │
├─────────────────────────────────────────────────────────────────────┤
│  SET (type=2)                                                      │
│  ├── HT      (encoding=2) → dict（无 value 哈希表）               │
│  └── INTSET   (encoding=6) → 整数集合（全整数且元素少时）          │
│                              触发条件：所有元素都是整数且           │
│                              元素数 ≤ 512                           │
├─────────────────────────────────────────────────────────────────────┤
│  STREAM (type=6)                                                   │
│  └── STREAM (encoding=10) → RadixTree(listpack) 索引                │
│                              RadixTree key = 元素 ID                │
│                              value = listpack（包含多个 field）     │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 createObject——对象创建的源头

```c
// object.c:43-55 — doom-lsp 确认
robj *createObject(int type, void *ptr) {
    robj *o = zmalloc(sizeof(*o));  // 永远分配 16 字节
    o->type = type;
    o->encoding = OBJ_ENCODING_RAW; // 默认编码是 RAW
    o->ptr = ptr;
    o->refcount = 1;                 // 引用计数 = 1
    // 根据 maxmemory_policy 设置 LRU 或 LFU
    if (server.maxmemory_policy & MAXMEMORY_FLAG_LFU) {
        o->lru = (LFUGetTimeInMinutes()<<8) | LFU_INIT_VAL;
    } else {
        o->lru = LRU_CLOCK();
    }
    return o;
}
```

**默认编码是 RAW**——每次创建对象时，除非后续有特殊处理，否则都是最基础的动态字符串编码。

### 2.3 makeObjectShared——共享对象的根基

```c
// server.h:2662 — doom-lsp 确认：makeObjectShared 声明
robj *makeObjectShared(robj *o);

// object.c:79 — doom-lsp 确认：使用示例
// robj *myobject = makeObjectShared(createObject(...));
// 两个键指向同一个对象，refcount = 2，析构时 decrRefCount 到 0 才真正释放
```

`refcount` 字段支撑了 Redis 的**对象共享**机制。当 `refcount > 1` 时，对象是"共享"的——多个键指向同一个底层数据。这用于：
- **小整数**：所有数值为 0~9999 的 INT 编码字符串共享同一个 robj
- **共享字符串对象**：如 `shared.ok`、`shared.err`、`shared.null[3]`

```c
// server.h:1230 — doom-lsp 确认：全局共享对象结构
struct sharedObjectsStruct {
    robj *crlf, *ok, *err, *emptybulk, *czero, *cone, *pong, *space,
         *queued, *null[3], *wrongtypeerr, *nokeyerr, *syntaxerr,
         *sameobjecterr, *outofrangeerr, *noscripterr, *loadingerr,
         *busykeyerr, *oomerr, *plus, *messagebulk, *pmessagebulk,
         *subscribebulk, *unsubscribebulk, *psubscribebulk, *punsubscribebulk,
         *del, *unlink, *rpop, *lpop, *lpush, *rpoplpush, *lmove, *blmove,
         *zpopmin, *zpopmax, *emptyscan, *multi, *exec, *left, *right,
         *hset, *srem, *xgroup, *xclaim, *script, *replconf, *eval,
         *persist, *set, *pexpireat, *pexpire, *time, *pxat, *absttl,
         *retrycount, *force, *justid, *entriesread, *lastid, *ping,
         *setid, *keepttl, *load, *createconsumer, *getack, *special_asterick,
         *special_equals, *default_username, *redacted,
         *ssubscribebulk, *sunsubscribebulk, *smessagebulk,
         *select, *integers, *mbulkhdr, *bulkhdr, *maphdr, *sethdr,
         *minstring, *maxstring;
    // ...
};
```

这些共享对象在 `createSharedObjects()`（`src/server.c`，`server.c` 初始化时调用）中创建，供所有命令复用——无需每次创建新的 robj。

### 2.4 小整数共享——最极端的共享案例

```c
// object.c:178-182 — doom-lsp 确认
robj *createStringObjectFromLongLongForValue(long long value) {
    robj *o;
    if (value >= 0 && value < OBJ_SHARED_INTEGERS) {
        // 在 [0, 9999] 范围内的小整数，直接返回共享对象
        // 无需分配，零成本
        return shared.createStringInt(value);
    }
    // 超出范围，走正常创建流程
    o = createStringObjectFromLongLongWithOptions(value, 1);
    if (o->encoding == OBJ_ENCODING_INT) {
        decrRefCount(o);  // 丢弃刚才创建的对象
        return shared.createStringInt(value);  // 返回共享对象
    }
    return o;
}
```

`OBJ_SHARED_INTEGERS` = 10000（`server.h` 中定义）。这意味着如果你的 Redis 存了 10000 个值为 `42` 的字符串键，它们全部共享同一个 robj，内存节省极为可观。

---

## 3. encoding 切换——Redis 的自适应存储

### 3.1 String 的 EMBSTR 优化

EMBSTR 是 Redis 对短字符串的特殊优化。当创建 length ≤ 44 的字符串时：

```c
// object.c:133-145 — doom-lsp 确认
robj *createStringObject(const char *ptr, size_t len) {
    if (len <= OBJ_ENCODING_EMBSTR_SIZE_LIMIT) {
        return createEmbeddedStringObject(ptr, len);
    } else {
        return createRawStringObject(ptr, len);
    }
}

// object.c:91-99 — doom-lsp 确认：createEmbeddedStringObject
robj *createEmbeddedStringObject(const char *ptr, size_t len) {
    robj *o = zmalloc(sizeof(*o) + sizeof(struct sdshdr8) + len + 1);
    // ★ 关键：一次分配，包含 robj(16) + sdshdr8(3) + 字符串(len) + 结尾\0
    // 内存连续，无指针间接，cache 友好
    o->type = OBJ_STRING;
    o->encoding = OBJ_ENCODING_EMBSTR;
    // ...
}
```

`OBJ_ENCODING_EMBSTR_SIZE_LIMIT` = 44。这意味着：
- robj(16B) + sdshdr8(3B) + 字符串(44B) + \0(1B) = **64B 一次分配**
- 如果走 RAW：`zmalloc(sizeof(robj))` + `sdsnewlen(ptr, len)` = **两次分配**

EMBSTR 的优势：**减少一次 `zmalloc` 调用 + 更好的 cache locality**（robj 和 sds 数据在同一块内存中）。

### 3.2 String → Int 编码切换

当字符串值实际上是一个数字时，Redis 会尝试压缩为 INT 编码：

```c
// object.c:162-188 — doom-lsp 确认
robj *createStringObjectFromLongLongWithOptions(long long value, int valueobj) {
    robj *o;
    if (valueobj) {
        // valueobj = 1 表示"尝试 INT 编码"
        char buf[LL_STR_SIZE];
        ll2string(buf, sizeof(buf), value);
        size_t len = strlen(buf);
        // 如果字符串表示和数值相等，说明可以直接转为 INT
        if (value >= 0 && value < OBJ_SHARED_INTEGERS) {
            return shared.createStringInt(value);
        }
        o = createStringObject(buf, len);
        // 检测是否可以转为 INT 编码
        if (tryStringEncodingInPlace(o) == C_OK) {
            // 编码转换成功
        }
    }
    // ...
}

// object.c:196-230 — doom-lsp 确认：tryStringEncodingInPlace
int tryStringEncodingInPlace(robj *o) {
    // 将 RAW 编码的字符串尝试转为 INT 编码
    // 失败条件：字符串包含非数字字符，或值超出 int64_t 范围
    // 成功条件：字符串是纯数字且在 [INT64_MIN, INT64_MAX] 范围内
}
```

**触发时机**：`SET key 12345` 会经过 `setCommand` → `setGenericCommand` → `setKey` → `setVal` → 检测到值是纯数字 → 调用 `createStringObjectFromLongLongWithOptions`。

### 3.3 Hash：ZIPLIST → HT 的编码切换

```c
// t_hash.c:449-487 — doom-lsp 确认
void hashTypeConvertListpack(robj *subject, robj *existing) {
    // 当 Hash 满足以下任一条件时，从 LISTPACK 转为 HT：
    // 1. 字段数超过 hash_max_listpack_entries (512)
    // 2. 任意 field 或 value 长度超过 hash_max_listpack_value (64)
    // 
    // 转换过程：
    // 1. 创建新的 dict
    // 2. 遍历旧 listpack，逐项解码，插入 dict
    // 3. 释放旧 listpack
    // 4. 替换 subject->ptr 为新 dict
    // 5. subject->encoding = OBJ_ENCODING_HT
}

// t_hash.c:489-503 — doom-lsp 确认：hashTypeConvert（通用转换入口）
void hashTypeConvert(robj *subject, int encoding) {
    if (encoding == OBJ_ENCODING_LISTPACK) {
        hashTypeConvertListpack(subject, NULL);
    } else if (encoding == OBJ_ENCODING_HT) {
        hashTypeConvertHashTable(subject);
    } else {
        serverPanic("Unknown hash encoding");
    }
}
```

**触发条件**（在 `t_hash.c:190` 的 `hashTypeSet` 中检查）：

```c
// t_hash.c:190-240 — doom-lsp 确认：hashTypeSet 中的触发检查
if (subject->encoding == OBJ_ENCODING_LISTPACK) {
    // 如果添加后超过阈值，触发转换
    if (hashTypeLength(subject) > server.hash_max_listpack_entries ||
        sdslen(v) > server.hash_max_listpack_value) {
        // 立即转换，不再等到下次命令
    }
}
```

### 3.4 ZSet：ZIPLIST → SKIPLIST 的编码切换

```c
// t_zset.c:1175-1224 — doom-lsp 确认：zsetConvert
void zsetConvert(robj *subject, int encoding) {
    if (encoding == OBJ_ENCODING_ZIPLIST) {
        // ZSet → Listpack 转换（较少发生）
        // 遍历 skiplist + dict，逐个插入 listpack
    } else if (encoding == OBJ_ENCODING_SKIPLIST) {
        // Listpack → Skiplist 转换
        // 创建 zset 结构：dict(member→score) + skiplist(score→member)
        // 遍历 listpack，插入两个结构
        // 释放 listpack
    } else if (encoding == OBJ_ENCODING_LISTPACK) {
        // ZSet → Listpack（Redis 7.x 新路径）
        // ...
    }
}

// 触发条件（t_zset.c:195-210）：
// zset_add 之前检查：
//   if (zset_max_listpack_entries > 0 && zllen > zset_max_listpack_entries)
//       → 转换为 SKIPLIST
//   if (sdslen(member) > zset_max_listpack_value)
//       → 转换为 SKIPLIST
```

### 3.5 Set：INTSET 的条件与转换

```c
// t_set.c:300-330 — doom-lsp 确认：convertToRealSet
void convertToRealSet(robj *subject) {
    // INTSET → HT 转换
    // 遍历 intset，逐元素插入 dict（value = NULL）
    // 释放 intset，subject->ptr = dict
    // subject->encoding = OBJ_ENCODING_HT
}

// 触发条件（t_set.c:addSetMember）：
// if (subject->encoding == OBJ_ENCODING_INTSET) {
//     if (!isSdsRepresentableAsLongLong(member, &llval) ||
//         // 添加后元素数 > set_max_intset_entries (512)
//         server.set_max_intset_entries > 0 &&
//         dictSize(subject->ptr) + 1 > server.set_max_intset_entries) {
//         convertToRealSet(subject);
//     }
// }
```

### 3.6 编码切换的代价

编码切换是一个**阻塞操作**——它需要遍历旧数据结构、创建新数据结构、释放旧数据结构。在高并发场景下，如果频繁触发大 Hash 的编码切换，会影响响应延迟。

Redis 6.2 引入了 `LISTPACK` 编码作为 `ZIPLIST` 的替代，用 listpack 代替 ziplist 作为 Hash/ZSet 的紧凑存储格式，解决了一些 ziplist 的性能问题（连锁更新）。

---

## 4. bit flag 字段——空间换时间

### 4.1 hasexpire——避免额外的 expires 查找

```c
unsigned hasexpire:1;  // 是否设置了过期时间
```

正常判断一个键是否过期需要两步：
1. 查 `server.expires` dict（O(1) 但仍需一次哈希）
2. 比较当前时间 vs 过期时间

如果 `hasexpire=0`，第一步可以直接跳过——这个键**肯定没有过期**，无需查 `expires` dict。

### 4.2 hasembkey——快速返回编码类型

```c
unsigned hasembkey:1;  // 是否为 EMBSTR 编码
```

`OBJECT ENCODING` 命令的实现（`src/object.c:250`）：

```c
// object.c:250-270 — doom-lsp 确认
void objectCommand(client *c) {
    // ...
    if (strcasecmp(c->argv[2]->ptr,"encoding") == 0) {
        if (o->encoding == OBJ_ENCODING_EMBSTR && hasembkey) {
            addReplyBulkCString(c,"embstr");  // 直接返回，无需读 encoding 字段
        } else {
            addReplyBulkCString(c,encodingname[o->encoding]);
        }
    }
    // ...
}
```

在 EMBSTR 场景下，可以直接通过 `hasembkey` flag 快速返回，无需访问 `encoding` 字段。

### 4.3 hasexpire 和 hasembkey 的实现细节

这两个 flag 是在**每次操作时更新**的：
- `SETEX` / `EXPIRE` 执行后设置 `hasexpire=1`
- `DEL` / `EXPIRE` 执行后设置 `hasexpire=0`
- `createStringObject` 根据是否 EMBSTR 设置 `hasembkey`

这是典型的**空间换时间**：用 2 bit 的额外存储，换取更快的命令处理路径。

---

## 5. lru 字段——LRU/LFU 淘汰的时钟

### 5.1 LRU 时钟的工作原理

```c
// server.h:837 — LRU_BITS = 24
// 即 lru 字段的低 24 位存 LRU 时钟
// 高 8 位（在 LFU 模式下）存 LFU 计数器

// server.h:1353 — lruclock 定义
#define LRU_CLOCK() ((1000/USHRT_MAX) * ((uint64_t)evictALoopCounter + (uint64_t)server.unixtime % 1000))
// LRU_CLOCK() 返回一个从 0 到 1000 循环递增的值，每毫秒更新一次
```

LRU 时钟的精度是**秒级**（而不是毫秒级）——这是有意为之的设计：
- 足够精确，能区分键的访问先后
- 不需要每次访问都更新（只读 `LRU_CLOCK()` 不需要写）
- 存储紧凑（24 bit）

### 5.2 LFU 模式——近似 LRU 的频率计数

```c
// object.c:50 — doom-lsp 确认：LFU 模式下的设置
if (server.maxmemory_policy & MAXMEMORY_FLAG_LFU) {
    o->lru = (LFUGetTimeInMinutes()<<8) | LFU_INIT_VAL;
    // 高 8 位：LFU 计数器（访问频率）
    // 低 8 位：上次 decay 的时间戳（分钟级）
} else {
    o->lru = LRU_CLOCK();
}
```

LFU 模式下：
- **高 8 位**：`LFU_INIT_VAL`（默认 5），记录访问频率
- **低 8 位**：上次 `LFUDecrAndReturn` decay 的分钟时间戳

LFU 的 decay 逻辑在 `object.c:370` 的 `LFUDecrAndReturn` 中实现：
```c
// object.c:370-390 — doom-lsp 确认：LFU decay
uint64_t LFUDecrAndReturn(robj *o) {
    // 每分钟运行一次（由 serverCron 触发）
    // 将计数器乘以概率因子（1 - 衰变率），下取整
    // 防止频繁访问的键被错误淘汰
}
```

---

## 6. refcount——对象生命周期管理

### 6.1 引用计数的作用

```c
// object.c:60-78 — doom-lsp 确认
void incrRefCount(robj *o) {
    if (o->refcount != OBJ_SHARED_REFCOUNT) {
        o->refcount++;
    }
    // OBJ_SHARED_REFCOUNT 是特殊值，表示对象是共享的
    // 共享对象的 refcount 不做递增（因为设计上就应该是"无限共享"）
}

void decrRefCount(robj *o) {
    if (o->refcount != OBJ_SHARED_REFCOUNT) {
        if (o->refcount--) {
            return;  // refcount > 0，还不能释放
        }
        // refcount == 0，真正释放
        if (o->type == OBJ_STRING) {
            // 释放 sds
        } else if (...) {
            // 释放其他类型的数据
        }
        zfree(o);  // 释放 robj 本身
    }
    // 共享对象不释放
}
```

### 6.2 共享对象的特殊处理

```c
// server.h 中定义的特殊 refcount 值
#define OBJ_SHARED_REFCOUNT INT_MAX  // 共享对象的 refcount 固定为 INT_MAX
```

当 `refcount == OBJ_SHARED_REFCOUNT` 时：
- `incrRefCount()` 不递增
- `decrRefCount()` 不释放

这使得共享对象（如 `shared.ok` = "OK"）可以在所有需要的地方复用，永远不会被意外释放。

---

## 7. 源码索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `src/server.h` | 649 | `#define OBJ_STRING 0` — type 定义 |
| `src/server.h` | 667 | `#define OBJ_STREAM 6` |
| `src/server.h` | 837 | `#define OBJ_ENCODING_RAW 0` — encoding 定义 |
| `src/server.h` | 847 | `#define OBJ_ENCODING_LISTPACK 11` |
| `src/server.h` | 858 | `typedef struct redisObject` — robj 定义（16B） |
| `src/server.h` | 1230 | `struct sharedObjectsStruct` — 全局共享对象 |
| `src/server.h` | 2662 | `makeObjectShared()` 声明 |
| `src/object.c` | 43 | `createObject()` — 对象创建原语 |
| `src/object.c` | 60 | `incrRefCount()` — 引用计数递增 |
| `src/object.c` | 68 | `decrRefCount()` — 引用计数递减（含释放逻辑） |
| `src/object.c` | 91 | `createEmbeddedStringObject()` — EMBSTR 创建 |
| `src/object.c` | 133 | `createStringObject()` — String 对象工厂 |
| `src/object.c` | 178 | `createStringObjectFromLongLongForValue()` — 小整数共享入口 |
| `src/object.c` | 196 | `tryStringEncodingInPlace()` — String→Int 编码转换 |
| `src/object.c` | 370 | `LFUDecrAndReturn()` — LFU 频率衰减 |
| `src/object.c` | 250 | `objectCommand()` — OBJECT ENCODING 实现 |
| `src/t_hash.c` | 449 | `hashTypeConvertListpack()` — Hash 编码切换 |
| `src/t_hash.c` | 489 | `hashTypeConvert()` — 编码切换通用入口 |
| `src/t_hash.c` | 190 | `hashTypeSet()` — 编码切换触发检查 |
| `src/t_zset.c` | 1175 | `zsetConvert()` — ZSet 编码切换 |
| `src/t_set.c` | 300 | `convertToRealSet()` — Set INTSET→HT 转换 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| Redis 版本：main（7.x dev）| 分析日期：2026-05-24*