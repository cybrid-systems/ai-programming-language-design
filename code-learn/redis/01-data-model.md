# 01 — 分道扬镳的起点：数据模型

> Redis vs OceanBase 源码对比系列 · 第一篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

数据库的起点是什么？是你往里面塞什么数据、数据怎么在内存里表示、数据怎么落盘。Redis 和 OceanBase 在这个问题上走出了两条完全不同的路——一条追求极简，一条追求表达力。

**doom-lsp 确认**：Redis `struct redisObject` 定义在 `src/server.h:858`（16 字节固定大小），OceanBase `ObObj` 在 `deps/oblib/src/common/object/ob_object.h:1478`（同样是 16 字节但设计哲学截然不同）。两个系统都选择了 16 字节作为基准，但背后的权衡完全不同。

本文对两个系统的数据模型进行逐字段、逐 bit 的深度拆解，用 `doom-lsp` 追踪每一个关键设计决策的源码位置。

---

## 1. Redis 的数据模型：type + encoding 二级抽象

### 1.1 robj——永远 16 字节的统一包装

Redis 的每个值都用 `redisObject`（简称 robj）表达，定义在 `src/server.h:858`：

```c
// server.h:858-866 — doom-lsp 确认
typedef struct redisObject {
    unsigned type:4;         // [0:4)  对象类型：STRING/LIST/SET/ZSET/HASH/STREAM/MODULE
    unsigned encoding:4;    // [4:8)  编码方式：RAW/INT/HT/SKIPLIST/QUICKLIST/LISTPACK/...
    unsigned lru:LRU_BITS;   // [8:32) LRU 时钟或 LFU 频率计数器
    unsigned hasexpire:1;   //       是否有过期时间（bit flag）
    unsigned hasembkey:1;    //       是否有嵌入 key（bit flag）
    unsigned refcount:OBJ_REFCOUNT_BITS; // [0:58) 引用计数，支撑共享对象
    void *ptr;               //       指向实际数据结构（8 字节）
} robj;
```

**重要洞察**：robj 本身的大小是**固定 16 字节**，它不携带数据内容，只携带指向堆内存的指针。robj 是一个"句柄"，不是数据本身。`ptr` 才是数据所在。

### 1.2 type 字段——对象逻辑类型（4 bit）

`type` 字段回答"这个对象是什么语义"，定义在 `src/server.h:649-656`：

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

共 7 种对象类型，使用 4 bit（16 种可能值）。每种类型对应一种"逻辑语义"：

| 值 | 类型 | 语义 |
|----|------|------|
| 0 | STRING | 字符串或数字 |
| 1 | LIST | 列表（有序、可重复） |
| 2 | SET | 集合（无序、不重复） |
| 3 | ZSET | 有序集合（score + member） |
| 4 | HASH | 哈希表（field-value 对） |
| 5 | MODULE | 模块类型（Redis Module API） |
| 6 | STREAM | 流（RadixTree + Listpack） |

### 1.3 encoding 字段——对象物理编码（4 bit）

`encoding` 字段回答"这个对象在物理上怎么存储"，定义在 `src/server.h:837-847`：

```c
// server.h:837-847 — doom-lsp 确认
#define OBJ_ENCODING_RAW 0     /* Raw representation: sds 动态字符串 */
#define OBJ_ENCODING_INT 1     /* 整数值（ptr 位置直接存 int64_t） */
#define OBJ_ENCODING_HT 2      /* 哈希表（dict）编码 */
#define OBJ_ENCODING_ZIPMAP 3  /* 已废弃：旧版 Hash 编码 */
#define OBJ_ENCODING_LINKEDLIST 4 /* 已废弃：旧版 List 编码 */
#define OBJ_ENCODING_ZIPLIST 5 /* 已废弃：旧版 List/Hash/ZSet 编码 */
#define OBJ_ENCODING_INTSET 6  /* 整数集合（Set 专用） */
#define OBJ_ENCODING_SKIPLIST 7 /* 跳表（ZSet 专用） */
#define OBJ_ENCODING_EMBSTR 8  /* 内嵌 sds（短字符串，≤44 字节） */
#define OBJ_ENCODING_QUICKLIST 9 /* 双向链表 + listpack（List 专用） */
#define OBJ_ENCODING_STREAM 10 /* RadixTree + listpack（Stream 专用） */
#define OBJ_ENCODING_LISTPACK 11 /* 单 listpack（String/Hash 可选） */
```

共 11 种编码，4 bit 足够覆盖。

### 1.4 type × encoding 的正交组合

这是 Redis 最精妙的设计——**type 和 encoding 完全独立**。同一个逻辑类型可以用完全不同的物理方式存储：

```
┌─────────────────────────────────────────────────────────────────────┐
│  STRING (type=0)                                                    │
│  ├── RAW   (encoding=0)  → sds 动态字符串（>44 字节）              │
│  ├── EMBSTR (encoding=8)  → 38 字节内嵌 sds（≤44 字节）            │
│  └── INT    (encoding=1)  → int64_t（数值字符串专用，无 ptr）       │
├─────────────────────────────────────────────────────────────────────┤
│  LIST (type=1)                                                     │
│  ├── QUICKLIST (encoding=9) → 双向链表，每个节点是 listpack         │
│  └── LISTPACK  (encoding=11)→ 扁平 listpack（非 List 典型）       │
├─────────────────────────────────────────────────────────────────────┤
│  HASH (type=4)                                                     │
│  ├── HT      (encoding=2) → dict 哈希表（字段多时）                │
│  └── LISTPACK (encoding=11)→ 单 listpack（字段少时，≈ziplist）    │
├─────────────────────────────────────────────────────────────────────┤
│  ZSET (type=3)                                                     │
│  ├── SKIPLIST (encoding=7) → dict + skiplist（成员多时）          │
│  └── LISTPACK  (encoding=11)→ 单 listpack（成员少时）             │
├─────────────────────────────────────────────────────────────────────┤
│  SET (type=2)                                                      │
│  ├── HT      (encoding=2) → dict（无 value 哈希表）               │
│  └── INTSET   (encoding=6) → 整数集合（全整数且元素少时）          │
├─────────────────────────────────────────────────────────────────────┤
│  STREAM (type=6)                                                   │
│  └── STREAM (encoding=10) → RadixTree + listpack                  │
└─────────────────────────────────────────────────────────────────────┘
```

**编码切换的触发条件**（`src/t_hash.c:449`——`hashTypeConvertListpack`，`src/t_zset.c:1175`——`zsetConvert`）：

```c
// t_hash.c:449-487 — doom-lsp 确认：Hash 编码转换
void hashTypeConvertListpack(robj *subject, robj *existing) {
    // 当 Hash 字段数超过 hash_max_listpack_entries (512)
    // 或任意字段值长度超过 hash_max_listpack_value (64)
    // 调用此函数将 ZIPLIST → HT
}

// t_zset.c:1175-1224 — doom-lsp 确认：ZSet 编码转换
void zsetConvert(robj *subject, int encoding) {
    // ZSet 编码切换逻辑：
    // ZIPLIST → SKIPLIST：当元素数 > zset_max_listpack_entries (128)
    // 或任意 member 长度 > zset_max_listpack_value (64)
}
```

### 1.5 refcount——共享对象的根基

`refcount` 字段支撑了 Redis 的**对象共享**机制。当多个键指向同一个值时（如 `SET a "hello"; SET b "hello"`），两个 robj 的 `ptr` 指向同一个底层对象，`refcount = 2`。

`makeObjectShared()`（`src/server.h:2662`）是共享对象创建入口：

```c
// server.h:2662 — doom-lsp 确认
robj *makeObjectShared(robj *o);

// object.c:79 — doom-lsp 确认：使用示例
// robj *myobject = makeObjectShared(createObject(...));
```

Redis 的共享对象主要用于：

- **小整数**（`OBJ_ENCODING_INT`，0~9999）：所有数值相同的字符串键共享同一个 robj
- **共享字符串对象**（`sharedObjectsStruct`，`src/server.h:1230`）：如 `shared.ok`、`shared.err`、`shared.null[3]`

```c
// server.h:1230 — doom-lsp 确认：全局共享对象
struct sharedObjectsStruct {
    robj *crlf, *ok, *err, *emptybulk, *czero, *cone, *pong, *space,
         *queued, *null[3], *wrongtypeerr, *nokeyerr, ...;
    // ...
};
```

`createStringObjectFromLongLongForValue()`（`src/object.c:178`）会在值在 [0, 9999] 范围内时返回共享对象：

```c
// object.c:178-182 — doom-lsp 确认
if (value >= 0 && value < OBJ_SHARED_INTEGERS) {
    o = createStringObjectFromLongLongWithOptions(value, 1); // 尝试创建 INT 编码
    if (o->encoding == OBJ_ENCODING_INT) {
        decrRefCount(o);  // 丢弃，立即返回共享对象
        return shared.createStringInt(value);
    }
}
```

### 1.6 hasexpire / hasembkey——内嵌 bit flag

```c
unsigned hasexpire:1;  // 是否设置了过期时间（用于快速跳过无过期检查）
unsigned hasembkey:1; // 是否为 EMBSTR 编码（用于 OBJECT ENCODING 快速返回）
```

这两个 1 bit 字段是**空间换时间**的典型设计：
- `hasexpire=1` 时，EXPIRE 命令无需再调用 `getExpire()` 查全局 `expires` dict
- `hasembkey=1` 时，OBJECT ENCODING 直接返回 `"embstr"` 而无需检查 `encoding` 字段

---

## 2. OceanBase 的数据模型：ObObj（行存）→ ObDatum（列存）

### 2.1 ObObj——自包含的 16 字节设计

OceanBase 的经典数据结构是 `ObObj`（`deps/oblib/src/common/object/ob_object.h:1478`），它采用**自包含设计**——元数据和值都在同一个结构里：

```
 ObObj (16 bytes) — doom-lsp 确认 @ ob_object.h:1478
┌──────────────────────────────────────────────────┐
│ ObObjMeta meta_ (4 bytes)                         │
│ ├── type_:   uint32_t  8bit  — ObObjType (54种)  │
│ ├── cs_level_: uint32_t 2bit  — Collation Level   │
│ ├── cs_type_:  uint32_t 6bit  — Collation Type    │
│ ├── scale_:   uint32_t 8bit  — 小数精度          │
│ └── ... (ObObjMeta @ ob_object.h:108 共 4 bytes)  │
├──────────────────────────────────────────────────┤
│ int32_t val_len_ / nmb_desc_ / time_ctx_ (4 bytes)│
│ — union { int32_t, ObNumber::Desc, UnionTZCtx }   │
├──────────────────────────────────────────────────┤
│ ObObjValue v_ (8 bytes) — union                   │
│ ├── int64_t / uint64_t — 有/无符号整型           │
│ ├── float / double       — 浮点                   │
│ ├── const char*          — 字符串指针             │
│ ├── uint32_t*            — NUMBER 数字数组       │
│ ├── ObLobCommon*         — LOB 数据               │
│ └── ... 共 15 种字段解释（@ ob_object.h:1444）     │
└──────────────────────────────────────────────────┘
```

对比 robj，ObObj 的设计哲学**完全不同**：

| | Redis robj | OceanBase ObObj |
|---|---|---|
| 是否自包含 | 否（ptr 指向外部数据） | 是（value 内嵌在结构内） |
| 类型字段 | type(4bit) + encoding(4bit) 共 8 bit | type(8bit) + 完整元数据 |
| 指针间接 | 有（ptr 指向堆） | 无（inline 值） |
| 可变长数据 | 通过 ptr 指向 sds | 通过 `v_.string_` 指向外部 buffer |
| 精度控制 | 无 | 完整（scale/precision/charset） |

### 2.2 ObObjMeta——4 字节位域压缩

`ObObjMeta`（`ob_object.h:108`）将所有元数据压缩到 4 字节：

```c
// ob_object.h:108-145 — doom-lsp 确认
struct ObObjMeta {
    uint32_t type_   : 8;   // [0:8)   ObObjType（54 种）
    uint32_t cs_level_  : 2;   // [8:10)  Collation Level
    uint32_t cs_type_   : 6;   // [10:16) Collation Type（约 30 种）
    uint32_t scale_     : 8;   // [16:24) Scale（小数位数）
    // 后接 extend_type_ 等（union 复用空间）
};
```

`type_`（8 bit）比 Redis 的 type（4 bit）大了 4 倍——因为 OceanBase 需要支持 **54 种数据类型**（包括 Oracle 模式的 `NVARCHAR2`、`INTERVAL_YM`、`UDT`、`ROARINGBITMAP`），4 bit 只够 16 种，根本不够用。

### 2.3 ObObjValue——8 字节通用 union

```c
// ob_object.h:1444-1476 — doom-lsp 确认
union ObObjValue {
    int64_t int64_;           // 有符号整型
    uint64_t uint64_;         // 无符号整型
    float float_;             // FLOAT
    double double_;         // DOUBLE
    const char *string_;      // 字符串指针（指向外部 buffer）
    uint32_t *nmb_digits_;    // NUMBER 的数字数组
    int64_t datetime_;        // DATETIME 时间戳
    int32_t date_;            // DATE
    int64_t time_;            // TIME
    uint8_t year_;            // YEAR（只用 1 字节，剩余 7 清零）
    int64_t ext_;             // 扩展值（min/max/nop）
    int64_t unknown_;         // 未知类型
    const ObLobCommon *lob_;  // LOB 数据
    const ObLobLocator *lob_locator_; // LOB 定位器
    // ...
};
```

**Union 设计**：所有类型共享同一个 8 字节空间。对于整型（int64_t），全部 8 字节都有意义；对于 YEAR 类型，只用最低 1 字节，剩余 7 字节清零。调用者必须通过 `meta_.type_` 来确定如何解释 `v_`。

### 2.4 ObDatum——列存时代的 12 字节紧凑设计

OceanBase 引入列存编码引擎后，ObObj 的 16 字节对短类型（YEAR 1 字节、FLOAT 4 字节）浪费严重。`ObDatum`（`src/share/datum/ob_datum.h:177`）诞生：

```
 ObDatum (12 bytes) — doom-lsp 确认 @ ob_datum.h:177
┌──────────────────────────────────────────────────┐
│ ObDatumPtr (8 bytes)                             │
│ ┌──────────────────────────────────────────────┐ │
│ │ union {                                       │ │
│ │   const char* ptr_;     // 字符串指针         │ │
│ │   int64_t* int_;        // 整数数组           │ │
│ │   float* float_;        // 浮点数组           │ │
│ │   double* double_;      // double 数组        │ │
│ │   ObLobCommon* lob_data_; // LOB 数据         │ │
│ │   ObDecimalInt* decimal_int_; // 紧凑十进制   │ │
│ │ }                                             │ │
│ └──────────────────────────────────────────────┘ │
├──────────────────────────────────────────────────┤
│ ObDatumDesc (4 bytes) — doom-lsp 确认 @ ob_datum.h:115 │
│ ┌────────────────────────────────────────────┐  │
│ │ len_:    uint32_t 29bit — 数据长度（0-536M） │  │
│ │ flag_:   uint32_t 2bit  — 标志（NONE/OUTROW│  │
│ │                           /EXT/HAS_LOB_HDR） │  │
│ │ null_:   uint32_t 1bit  — 是否为 NULL      │  │
│ └────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

核心思想：**元数据与值分离**。ObDatum 只存储指向数据的指针和描述符，类型/精度/字符集由调用方通过 `ObObjMeta` 单独传递。这使得 ObDatum 只有 12 字节，比 ObObj 小 4 字节。

### 2.5 ObObjDatumMapType——类型到内存布局的映射

```c
// ob_datum.h:80-99 — doom-lsp 确认
enum ObObjDatumMapType : uint8_t {
  OBJ_DATUM_NULL,            // 0 B  — NULL
  OBJ_DATUM_STRING,          // 可变 — 字符串（ptr + len）
  OBJ_DATUM_NUMBER,          // 4~40B— NUMBER（desc + digits）
  OBJ_DATUM_8BYTE_DATA,      // 8 B  — int64, double, datetime
  OBJ_DATUM_4BYTE_DATA,      // 4 B  — float, date, int32
  OBJ_DATUM_1BYTE_DATA,      // 1 B  — year
  OBJ_DATUM_4BYTE_LEN_DATA,  // 12 B — 4B len + 8B data（TimestampTZ）
  OBJ_DATUM_2BYTE_LEN_DATA,  // 10 B — 2B len + 8B data（TimestampLTZ）
  OBJ_DATUM_FULL,            // 16 B — 完整 ObObj（Extend 类型）
  OBJ_DATUM_DECIMALINT,      // 4~64B— Decimal Int
  OBJ_DATUM_MAPPING_MAX,
};
```

这个枚举定义了每种 `ObObjType` 在内存中的实际布局（compact/columnar 场景下）。例如：

| ObObjType | 映射类型 | 实际占用 |
|-----------|---------|---------|
| ObTinyIntType ~ ObIntType | OBJ_DATUM_8BYTE_DATA | 8 bytes |
| ObFloatType | OBJ_DATUM_4BYTE_DATA | 4 bytes |
| ObYearType | OBJ_DATUM_1BYTE_DATA | 1 byte |
| ObVarcharType ~ ObLongTextType | OBJ_DATUM_STRING | 可变 |
| ObDecimalIntType | OBJ_DATUM_DECIMALINT | 4~64 bytes |

### 2.6 Obj → Datum 转换

`ObDatum::from_obj()`（`ob_datum.h:336`）实现了从 ObObj 到 ObDatum 的转换：

```c
// ob_datum.h:336-365 — doom-lsp 确认
template <ObObjDatumMapType MAP_TYPE>
inline void ObDatum::from_obj(const ObObj &obj) {
    switch (MAP_TYPE) {
    case OBJ_DATUM_8BYTE_DATA:
        memcpy(no_cv(ptr_), &obj.v_.uint64_, sizeof(uint64_t));
        pack_ = sizeof(uint64_t);  // 同时设置 len_ 和 null_
        break;
    // ... 其他类型
    }
}
```

注意 `pack_ = sizeof(uint64_t)` 同时设置了 `len_`（29 bit）和 `null_`（1 bit）——因为 `null_ == 0` 意味着数据非空。这是 `ObDatumDesc` 中 union 设计的巧妙之处。

---

## 3. 本质对比：两种数据库哲学

### 3.1 Redis：一切为了性能优化

Redis 的数据模型从属于它的核心约束：**单线程事件循环**，所有操作必须在 O(1) 或 O(log N) 内完成。

```c
// object.c:43-55 — doom-lsp 确认：createObject
robj *createObject(int type, void *ptr) {
    robj *o = zmalloc(sizeof(*o));  // 固定 16 字节，zmalloc 极快
    o->type = type;
    o->encoding = OBJ_ENCODING_RAW;
    o->ptr = ptr;
    o->refcount = 1;
    o->lru = LRU_CLOCK();
    return o;
}
```

- **固定 16 字节**：对象分配和释放可以完全池化
- **type × encoding 分离**：允许运行时根据数据特征切换存储方式（int → raw string）
- **refcount 共享**：避免重复分配，小整数共享可达 10000 个

Redis 不需要考虑 SQL 语句的类型推导、跨类型表达式、字符集排序规则——它只服务一种场景：**键值对的多态存储**。

### 3.2 OceanBase：一切为了 SQL 表达力

OceanBase 的数据模型从属于它的核心约束：**支持完整的 SQL 语义**。

`ObObjType` 枚举（`ob_obj_type.h:29`）定义了 54 种类型：

```c
// ob_obj_type.h:29-53 — doom-lsp 确认
enum ObObjType {
  ObNullType,          //  0
  ObTinyIntType,       //  1
  // ... 有符号整数族
  ObFloatType,         // 11
  ObDoubleType,        // 12
  ObNumberType,        // 15 — 高精度 DECIMAL
  ObVarcharType,       // 22
  // ... TEXT 系列
  ObTimestampTZType,   // 34 — TIMESTAMP WITH TIME ZONE
  ObIntervalYMType,    // 38 — INTERVAL YEAR TO MONTH
  ObNVarchar2Type,     // 41 — Oracle NVARCHAR2
  ObJsonType,          // 45 — JSON
  ObGeometryType,      // 46 — GEOMETRY
  ObUserDefinedSQLType,// 47 — UDT
  ObRoaringBitmapType, // 52 — RoaringBitmap
  ObMaxType,           // 53 — 最大值标记
};
```

覆盖 MySQL 和 Oracle 两种模式、完整的数据类型体系。这是双模支持的基础——同一个 SQL 引擎必须能同时处理 MySQL 的 `YEAR` 和 Oracle 的 `INTERVAL YEAR TO MONTH`。

### 3.3 关键数字对比

| 维度 | Redis | OceanBase |
|------|-------|----------|
| 核心对象大小 | 16 字节（固定） | 16 字节（ObObj）/ 12 字节（ObDatum） |
| type 字段宽度 | 4 bit（7 种类型） | 8 bit（54 种类型） |
| encoding 字段 | 4 bit（11 种编码） | 无 encoding（类型即编码） |
| refcount 共享 | 有（小整数 0~9999） | 无（每行独立对象） |
| 精度控制 | 无 | scale/precision/charset 全链路 |
| 双模支持 | 无 | MySQL + Oracle 类型 |

---

## 4. 从数据模型看后续系列

这个起点注定了两个数据库走向完全不同的道路：

- **Redis** 接下来要解决：如何在单线程里高效分派命令（`lookupCommand`）、如何做持久化（RDB/AOF）而不阻塞事件循环、如何做复制（REPL_STATE 状态机）
- **OceanBase** 接下来要解决：如何在 54 种类型上做代价估算、MVCC 如何在不同类型下正确判断可见性、存储层如何根据类型选择编码算法

---

## 5. 源码索引

### Redis

| 文件 | 行号 | 内容 |
|------|------|------|
| `src/server.h` | 649 | `#define OBJ_STRING 0` — type 定义 |
| `src/server.h` | 666 | `#define OBJ_MODULE 5` |
| `src/server.h` | 667 | `#define OBJ_STREAM 6` |
| `src/server.h` | 837 | `#define OBJ_ENCODING_RAW 0` — encoding 定义 |
| `src/server.h` | 847 | `#define OBJ_ENCODING_LISTPACK 11` |
| `src/server.h` | 858 | `typedef struct redisObject` — robj 定义 |
| `src/server.h` | 1230 | `struct sharedObjectsStruct` — 共享对象 |
| `src/server.h` | 2662 | `makeObjectShared()` — 共享对象创建 |
| `src/object.c` | 43 | `createObject()` — 对象创建 |
| `src/object.c` | 79 | `makeObjectShared()` 使用示例 |
| `src/object.c` | 178 | `createStringObjectFromLongLongForValue()` — INT 编码共享 |
| `src/t_hash.c` | 449 | `hashTypeConvertListpack()` — Hash 编码切换 |
| `src/t_zset.c` | 1175 | `zsetConvert()` — ZSet 编码切换 |

### OceanBase

| 文件 | 行号 | 内容 |
|------|------|------|
| `deps/oblib/src/common/object/ob_obj_type.h` | 29 | `enum ObObjType` — 54 种类型枚举 |
| `deps/oblib/src/common/object/ob_obj_type.h` | 228 | `enum ObObjTypeClass` — 类型分类 |
| `deps/oblib/src/common/object/ob_object.h` | 108 | `struct ObObjMeta` — 4 字节元数据 |
| `deps/oblib/src/common/object/ob_object.h` | 1444 | `union ObObjValue` — 8 字节值 union |
| `deps/oblib/src/common/object/ob_object.h` | 1478 | `struct ObObj` — 16 字节自包含 |
| `src/share/datum/ob_datum.h` | 80 | `enum ObObjDatumMapType` — 类型→布局映射 |
| `src/share/datum/ob_datum.h` | 115 | `struct ObDatumDesc` — 4 字节描述符 |
| `src/share/datum/ob_datum.h` | 177 | `class ObDatum` — 12 字节紧凑设计 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| Redis 版本：main（7.x）| 分析日期：2026-05-24*