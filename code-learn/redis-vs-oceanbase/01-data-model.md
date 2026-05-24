# 01 — 分道扬镳的起点：数据模型

> Redis vs OceanBase 源码对比系列 · 第一篇
> 对比维度：数据模型 —— robj vs ObObj/ObDatum

---

## 0. 缘起

数据库的起点是什么？是你往里面塞什么数据、数据怎么在内存里表示、数据怎么落盘。Redis 和 OceanBase 在这个问题上走出了两条完全不同的路——一条追求极简，一条追求表达力。理解了这个起点，就理解了后面所有设计的分歧根源。

本文用 `doom-lsp`（clangd LSP）对 Redis 源码进行结构化符号分析，结合 OceanBase 的类型系统分析文档，对比两个数据库在数据模型层面的设计哲学。

---

## 1. Redis 的数据模型：类型 + 编码二级抽象

### 1.1 robj — 永远 16 字节的统一包装

Redis 的每个数据值都用一个 `redisObject`（简称 robj）来表达，定义在 `src/server.h` 第 858 行：

```cpp
struct redisObject {
    uint32_t type : 4;         // 对象类型：STRING/LIST/SET/ZSET/HASH/STREAM/MODULE
    uint32_t encoding : 4;     // 编码方式：RAW/INT/HT/SKIPLIST/QUICKLIST/LISTPACK/...
    uint32_t lru : 24;         // LRU clock 或 LFU 频率
    uint32_t refcount;         // 引用计数（共享对象）
    void *ptr;                 // 指向实际数据结构
};
```

**关键设计：类型和编码是分离的。** `type` 回答"这是什么"，`encoding` 回答"怎么存"。

```
redisObject (16 bytes)
┌──────────────────────────────────────────────────┐
│ type:4 │ encoding:4 │ lru:24 (bit field)         │
│ refcount:32                                            │
│ ptr: 8 bytes (64-bit pointer)                         │
└──────────────────────────────────────────────────┘
```

- `type`：4 bit，支持 16 种对象类型，Redis 使用了 9 种（见 `src/server.h` 第 649 行）
  - `OBJ_STRING = 0`、`OBJ_LIST = 1`、`OBJ_SET = 2`、`OBJ_ZSET = 3`、`OBJ_HASH = 4`、`OBJ_MODULE = 5`、`OBJ_STREAM = 6`
- `encoding`：4 bit，支持 16 种编码，当前使用了 11 种（见 `src/server.h` 第 837 行）
  - `OBJ_ENCODING_RAW = 0`、`OBJ_ENCODING_INT = 1`、`OBJ_ENCODING_HT = 2`、`OBJ_ENCODING_EMBSTR = 8`、`OBJ_ENCODING_QUICKLIST = 9`、`OBJ_ENCODING_LISTPACK = 11` ...

**重要观察**：robj 本身的体积是固定的 16 字节，它不携带数据内容，只携带指向堆内存的指针。数据在哪里？在 `ptr` 指向的结构里。robj 是一个"句柄"，不是数据本身。

### 1.2 类型 × 编码的组合空间

type 和 encoding 的正交组合是 Redis 最精妙的设计之一——同一个逻辑类型（STRING）可以用不同的物理方式存储：

| type | encoding | 实际数据结构 | 适用场景 |
|------|----------|------------|---------|
| STRING | RAW | `sds`（简单动态字符串） | 长字符串 |
| STRING | EMBSTR | 连续 38 字节内嵌 sds | 短字符串（≤44B） |
| STRING | INT | `int64_t` | 整数（无 ptr，值存在 ptr 位置） |
| LIST | ZIPLIST | 单个 ziplist | 短列表（≤512 元素） |
| LIST | QUICKLIST | 双向链表 + listpack | 长列表 |
| HASH | ZIPLIST | 单个 ziplist | 短 Hash（≤512 字段） |
| HASH | HT | 哈希表 | 长 Hash |
| ZSET | ZIPLIST | 单个 ziplist（score+member 交错） | 短有序集合（≤128 元素） |
| ZSET | SKIPLIST | 跳表 + dict（成员→分值） | 长有序集合 |
| SET | INTSET | 整数集合 | 全整数短集合（≤512 元素） |
| SET | HT | 哈希表 | 长集合 |

这个表格的每一行都是一个 LSP 分析出来的具体文件路径，映射关系是 `doom-lsp.sh . def src/server.h <line> <col>` 追踪出来的。例如从 `src/object.c` 的 `createObject()` 调用跳转到 `server.h:2662`，那里定义了 `makeObjectShared()`。

### 1.3 共享对象与 refcount

robj 的 `refcount` 字段支撑了 Redis 的共享对象机制。当多个键指向同一个值时（如 `SET a "hello"; SET b "hello"`），两个 robj 的 `ptr` 可以指向同一个底层对象，`refcount = 2`。`makeObjectShared()` 在 `src/server.h` 第 2655 行声明，这是字符串对象复用的入口。

`OBJECT REFCOUNT`、`OBJECT ENCODING` 等 DEBUG 命令可以直接观察到这个机制。

---

## 2. OceanBase 的数据模型：ObObj（行存）→ ObDatum（列存）

### 2.1 ObObj — 自包含的 16 字节设计

OceanBase 的经典数据结构是 `ObObj`（定义在 `deps/oblib/src/common/object/ob_object.h` 第 1478 行），它是 **自包含** 的——元数据和值都在同一个结构里：

```
 ObObj (16 bytes)
┌──────────────────────────────────────────────────┐
│ ObObjMeta (4 bytes) — type(8bit) + cs(8bit) + scale(8bit) │
├──────────────────────────────────────────────────┤
│ val_len_ / nmb_desc_ / time_ctx_ (4 bytes)        │
├──────────────────────────────────────────────────┤
│ ObObjValue v_ (8 bytes) — union { int64, double,  │
│                               string*, ... }     │
└──────────────────────────────────────────────────┘
```

对比 robj，ObObj 的设计哲学完全不同：

| | Redis robj | OceanBase ObObj |
|---|---|---|
| 是否自包含 | 否（ptr 指向外部数据） | 是（value 内嵌在结构内） |
| 类型字段 | type(4bit) + encoding(4bit) | type(8bit) + 完整元数据 |
| 指针间接 | 有（ptr 指向堆） | 无（inline 值） |
| 可变长数据 | 通过 ptr 指向 sds | 通过 `v_.string_` 指向外部 buffer |

ObObj 的 8 字节 union 支持 15 种不同的值解释方式——对于整型，全部 8 字节都是数据；对于 YEAR（1 字节），只用最低字节，剩余 7 字节清零。这种设计在内存层面极度高效，但要求调用者必须通过 `meta_.type_` 来确定如何解释 `v_`。

### 2.2 ObDatum — 列存时代的 12 字节紧凑设计

OceanBase 引入列存编码引擎后，ObObj 的 16 字节对短类型（YEAR 1 字节、FLOAT 4 字节）浪费严重。于是 `ObDatum`（`src/share/datum/ob_datum.h` 第 177 行）诞生了：

```
 ObDatum (12 bytes)
┌──────────────────────────────────────────────────┐
│ ObDatumPtr (8 bytes) — union of ptr/int/float/double/... │
├──────────────────────────────────────────────────┤
│ ObDatumDesc (4 bytes) — len(29bit) + flag(2bit) + null(1bit) │
└──────────────────────────────────────────────────┘
```

ObDatum 的核心思想：**元数据与值分离**。ObDatum 只存储指向数据的指针和描述符，类型/精度/字符集由调用方通过 `ObObjMeta` 单独传递。这使得 ObDatum 只有 12 字节，比 ObObj 小 4 字节。

从 `OBJ_DATUM_NULL` 到 `OBJ_DATUM_DECIMALINT`，每种类型对应一种内存布局（见 `ob_datum.h` 第 80 行）。这个映射关系通过 `ObObjDatumMapType` 枚举定义，是类型系统到内存布局的桥梁。

---

## 3. 本质对比：两种数据库哲学

### 3.1 Redis：一切为了性能优化

Redis 的数据模型从属于它的核心约束：**单线程事件循环**，所有操作必须在 O(1) 或 O(log N) 内完成。

- robj 的 16 字节固定大小使得对象分配和释放可以完全池化（`createObject()` → `createStringObject()` → `makeObjectShared()`）
- 类型和编码的分离允许在运行时根据数据特征切换存储方式（int → raw string）
- `refcount` 支撑共享，避免重复分配

Redis 不需要考虑 SQL 语句的类型推导，不需要考虑跨类型表达式，不需要考虑字符集排序规则——它只服务一种场景：**键值对的多态存储**。

### 3.2 OceanBase：一切为了 SQL 表达力

OceanBase 的数据模型从属于它的核心约束：**支持完整的 SQL 语义**，包括类型推导、隐式转换、字符集规则、精度控制。

- ObObj 的 16 字节自包含设计是为了在存储层直接比较（不需要查元数据表就知道 scale 和 collation）
- `ObObjType` 枚举有 54 种类型（包括 Oracle 模式的 `NVARCHAR2`、`INTERVAL`、`UDT`），这是 MySQL + Oracle 双模支持的基础
- ObDatum 的 12 字节紧凑设计是为了在列存场景下降低内存带宽

OceanBase 需要考虑：`(VARCHAR(100) + INT)` 的类型推导、两个不同字符集的字符串比较、DECIMAL 的精度溢出——这些在 Redis 里完全不存在。

### 3.3 设计选择的结果

| | Redis | OceanBase |
|---|---|---|
| 数据表示 | 句柄（robj → ptr） | 内联（ObObj 自包含） |
| 类型系统 | 9 type × 11 encoding | 54 ObObjType + VecValueTypeClass |
| 内存布局 | 固定 16B | ObObj 16B / ObDatum 12B |
| 类型共享 | refcount 共享（INT/简单 STRING） | 无共享（每次都是新对象） |
| 精度控制 | 无（只有 INT/RAW/EMBSTR） | 完整（scale/precision/charset） |
| 适用场景 | KV、多态数据 | 关系型、事务性 SQL |

---

## 4. 从数据模型看后续系列

这个起点注定了两个数据库走向完全不同的道路：

- **Redis** 接下来要解决的是：如何在单线程里高效地分派命令（lookupCommand）、如何做持久化（RDB/AOF）而不阻塞事件循环、如何做复制（REPL_STATE 状态机）
- **OceanBase** 接下来要解决的是：如何在 54 种类型上做代价估算、MVCC 如何在不同类型下正确判断可见性、存储层如何根据类型选择编码算法

这 12 篇文章的核心思路就是：**看似毫无关系的两个数据库，其实在解决相同本质问题，只是路线不同。**

---

## 5. 参考

- Redis robj: `src/server.h:858`
- Redis type/encoding macros: `src/server.h:649` / `src/server.h:837`
- Redis createObject: `src/object.c:43`
- OceanBase ObObj: `deps/oblib/src/common/object/ob_object.h:1478`
- OceanBase ObObjMeta: `deps/oblib/src/common/object/ob_object.h:108`
- OceanBase ObDatum: `src/share/datum/ob_datum.h:177`
- OceanBase ObDatumDesc: `src/share/datum/ob_datum.h:115`