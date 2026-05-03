# 24 — 类型系统：ObObj、ObDatum、ObString 设计

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

经过前面 23 篇文章的积累，我们已经覆盖了 OceanBase 从**存储引擎**（MVCC、Memtable、SSTable、LS-Tree）到 **SQL 执行层**（优化器、PX 并行、Plan Cache）再到**分布式系统**（选举、PALF、CLOG）的完整技术栈。

现在，我们将目光投向整个系统最基础的基石——**类型系统（Type System）**。

### 类型系统的定位

OceanBase 中每一个数据值——无论是存储在磁盘上的一个整数，还是 SQL 表达式中计算出来的一个字符串——都需要用一个统一的数据结构来表达。这个"统一的表达方式"就是类型系统要解决的问题。

```
                    ┌─────────────────────────────────────┐
                    │           SQL 表达式引擎             │
                    │   ObExprCalc, ObExprFilter, ...     │
                    └────────────────┬────────────────────┘
                                     │ 使用 ObDatum 表达
                    ┌────────────────▼────────────────────┐
                    │         类型系统 Type System          │
                    │  ObObj  ──→  ObDatum  ──→  ObString │
                    │  ObObjType · ObObjTypeClass          │
                    └────────────────┬────────────────────┘
                                     │ 被所有子系统使用
         ┌───────────┬───────────┬───┴───┬───────────┬──────────────┐
         ▼           ▼           ▼       ▼           ▼              ▼
    存储引擎    SQL 优化器   SQL 执行   协议序列化  日志回放     各类索引
```

### 核心设计演进

OceanBase 的类型系统经历了两个发展阶段：

| 时期 | 数据结构 | 大小 | 特点 |
|------|----------|------|------|
| 行存（经典） | `ObObj` | 16 字节 | union 联合体，自包含元数据 |
| 列存/编码（现代） | `ObDatum` | 12 字节 | 紧凑布局，元数据分离到 ObObjMeta |

### 代码位置

```
deps/oblib/src/common/object/ob_obj_type.h    — ObObjType 枚举 & ObObjTypeClass
deps/oblib/src/common/object/ob_object.h      — ObObj (16B)、ObObjMeta (4B)、ObObjValue (8B)
deps/oblib/src/lib/string/ob_string.h          — ObString (12B)
src/share/datum/ob_datum.h                      — ObDatum (12B)
src/share/datum/ob_datum_funcs.h               — ObDatum 比较/哈希函数
src/storage/blocksstable/ob_datum_row.h         — ObDatumRow（存储行）
deps/oblib/src/common/object/ob_obj_cast.h     — 类型间转换
```

---

## 1. 类型枚举体系

### 1.1 ObObjType — 所有数据类型

[`ob_obj_type.h` 第 29 行](vscode://file/~/code/oceanbase/deps/oblib/src/common/object/ob_obj_type.h:29)定义了 `ObObjType` 枚举，涵盖 OceanBase 支持的所有数据类型：

```cpp
enum ObObjType {
  ObNullType,          //  0 — NULL 值
  ObTinyIntType,       //  1 — TINYINT
  ObSmallIntType,      //  2 — SMALLINT
  ObMediumIntType,     //  3 — MEDIUMINT
  ObInt32Type,         //  4 — INT32
  ObIntType,           //  5 — INT
  ObUTinyIntType,      //  6 — TINYINT UNSIGNED
  ObUSmallIntType,     //  7 — SMALLINT UNSIGNED
  ObUMediumIntType,    //  8 — MEDIUMINT UNSIGNED
  ObUInt32Type,        //  9 — INT32 UNSIGNED
  ObUInt64Type,        // 10 — BIGINT UNSIGNED
  ObFloatType,         // 11 — FLOAT
  ObDoubleType,        // 12 — DOUBLE
  ObUFloatType,        // 13 — FLOAT UNSIGNED
  ObUDoubleType,       // 14 — DOUBLE UNSIGNED
  ObNumberType,        // 15 — NUMBER/DECIMAL (高精度)
  ObUNumberType,       // 16 — NUMBER UNSIGNED
  ObDateTimeType,      // 17 — DATETIME (MySQL 旧版)
  ObTimestampType,     // 18 — TIMESTAMP
  ObDateType,          // 19 — DATE (MySQL 旧版)
  ObTimeType,          // 20 — TIME
  ObYearType,          // 21 — YEAR
  ObVarcharType,       // 22 — VARCHAR
  ObCharType,          // 23 — CHAR
  ObHexStringType,     // 24 — HEX 字符串
  ObExtendType,        // 25 — 扩展类型（min/max/nop）
  ObUnknownType,       // 26 — 未知类型
  // ... TEXT 系列
  ObTinyTextType,      // 27
  ObTextType,          // 28
  ObMediumTextType,    // 29
  ObLongTextType,      // 30
  // ... MySQL 特有
  ObBitType,           // 31 — BIT
  ObEnumType,          // 32 — ENUM
  ObSetType,           // 33 — SET
  // ... Oracle 模式特有
  ObTimestampTZType,   // 34 — TIMESTAMP WITH TIME ZONE
  ObTimestampLTZType,  // 35 — TIMESTAMP WITH LOCAL TZ
  ObTimestampNanoType, // 36 — TIMESTAMP 纳秒精度
  ObRawType,           // 37 — RAW
  ObIntervalYMType,    // 38 — INTERVAL YEAR TO MONTH
  ObIntervalDSType,    // 39 — INTERVAL DAY TO SECOND
  ObNumberFloatType,   // 40 — NUMBER FLOAT
  ObNVarchar2Type,     // 41 — NVARCHAR2
  ObNCharType,         // 42 — NCHAR
  ObURowIDType,        // 43 — UROWID
  ObLobType,           // 44 — LOB
  ObJsonType,          // 45 — JSON
  ObGeometryType,      // 46 — GEOMETRY
  ObUserDefinedSQLType,// 47 — UDT（自定义类型）
  ObDecimalIntType,    // 48 — Decimal Int（紧凑十进制）
  ObCollectionSQLType, // 49 — 集合类型
  ObMySQLDateType,     // 50 — MySQL DATE（紧凑格式）
  ObMySQLDateTimeType, // 51 — MySQL DATETIME（紧凑格式）
  ObRoaringBitmapType, // 52 — RoaringBitmap
  ObMaxType,           // 53 — 最大值标记
};
```

总计 **54 种类型**（含 ObMaxType），覆盖 MySQL 和 Oracle 两种模式的全部数据类型。

### 1.2 ObObjTypeClass — 类型分类体系

[`ob_obj_type.h` 第 228 行](vscode://file/~/code/oceanbase/deps/oblib/src/common/object/ob_obj_type.h:228)定义了 `ObObjTypeClass`，将具体类型归约为类别：

```cpp
enum ObObjTypeClass {
  ObNullTC,          // NULL
  ObIntTC,           // 有符号整数族
  ObUIntTC,          // 无符号整数族
  ObFloatTC,         // FLOAT
  ObDoubleTC,        // DOUBLE
  ObNumberTC,        // NUMBER/DECIMAL 高精度
  ObDateTimeTC,      // DATETIME
  ObDateTC,          // DATE
  ObTimeTC,          // TIME
  ObYearTC,          // YEAR
  ObStringTC,        // 变长字符串族
  ObExtendTC,        // 扩展
  ObUnknownTC,       // 未知
  ObTextTC,          // TEXT 族
  ObBitTC,           // BIT
  ObEnumSetTC,       // ENUM/SET
  ObEnumSetInnerTC,  // ENUM/SET 内部
  ObOTimestampTC,    // Oracle TIMESTAMP
  ObRawTC,           // RAW
  ObIntervalTC,      // INTERVAL
  ObRowIDTC,         // UROWID
  ObLobTC,           // LOB
  ObJsonTC,          // JSON
  ObGeometryTC,      // GEOMETRY
  ObUserDefinedSQLTC,// UDT
  ObDecimalIntTC,    // Decimal Int
  ObCollectionSQLTC, // 集合
  ObMySQLDateTC,     // MySQL 紧凑 DATE
  ObMySQLDateTimeTC, // MySQL 紧凑 DATETIME
  ObRoaringBitmapTC, // RoaringBitmap
  ObMaxTC,           // 最大值标记
};
```

类型映射关系通过 [`OBJ_TYPE_TO_CLASS`](vscode://file/~/code/oceanbase/deps/oblib/src/common/object/ob_obj_type.h:330) 常量数组定义。例如 `ObTinyIntType → ObIntTC`、`ObVarcharType → ObStringTC`。

### 1.3 VecValueTypeClass — 向量化引擎的类型系统

在 `ObObjTypeClass` 之上，还有一个专门为**向量化执行引擎**设计的 `VecValueTypeClass`（同文件第 1174 行）。它进一步细分了整数和 Decimal Int 的宽度：

```cpp
enum VecValueTypeClass {
  VEC_TC_NULL,
  VEC_TC_INTEGER,
  VEC_TC_UINTEGER,
  VEC_TC_FLOAT,
  VEC_TC_DOUBLE,
  VEC_TC_FIXED_DOUBLE,
  VEC_TC_NUMBER,
  VEC_TC_DATETIME,
  // ...
  VEC_TC_DEC_INT32,   // DecimalInt 32 位
  VEC_TC_DEC_INT64,   // DecimalInt 64 位
  VEC_TC_DEC_INT128,  // DecimalInt 128 位
  VEC_TC_DEC_INT256,  // DecimalInt 256 位
  VEC_TC_DEC_INT512,  // DecimalInt 512 位
  // ...
  MAX_VEC_TC,
};
```

这个分类直接对应 ObDatum 的不同内存布局，见第 3 节。

---

## 2. ObObj — 行存时期的经典设计

### 2.1 内存布局

ObObj 是 OceanBase 最经典的数据表示结构，定义在 [`ob_object.h` 第 1478 行](vscode://file/~/code/oceanbase/deps/oblib/src/common/object/ob_object.h:1478)。它采用**自包含设计**——元数据与值存储在同一 16 字节结构中：

```
 ObObj (16 bytes)
┌──────────────────────────────────────────────────┐
│ ObObjMeta (4 bytes)                              │
│ ┌──────┬──────┬──────┬──────┬──────┬──────┬─────┐│
│ │ type │  cs  │ scale│ cs_l │ ...  │ flag │     ││
│ │ 8bit │ 8bit │ 8bit │ 2bit │ 6bit │      │     ││
│ └──────┴──────┴──────┴──────┴──────┴──────┴─────┘│
├──────────────────────────────────────────────────┤
│ val_len_ / nmb_desc_ / time_ctx_ (4 bytes)       │
│ ┌──────────────────────────────────────────────┐  │
│ │ int32_t val_len_    — 字符串/LOB 长度         │  │
│ │ ObNumber::Desc      — NUMBER 精度描述         │  │
│ │ UnionTZCtx          — 时区上下文              │  │
│ └──────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────┤
│ ObObjValue v_ (8 bytes) — union 联合体           │
│ ┌──────────────────────────────────────────────┐  │
│ │ int64_t / uint64_t  — 整型/日期              │  │
│ │ float / double       — 浮点                   │  │
│ │ const char*          — 字符串指针              │  │
│ │ ObLobCommon*         — LOB 数据               │  │
│ │ ObDecimalInt*        — 紧凑十进制              │  │
│ │ ... (共 15 种字段)                             │  │
│ └──────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

### 2.2 ObObjMeta（`ob_object.h` 第 108 行）

元数据被压缩到 **4 字节**中，通过位域操作访问：

```cpp
struct ObObjMeta {
  // 4 bytes total, bit-packed
  uint32_t type_   : 8;   // [0:8]   ObObjType
  uint32_t cs_level_  : 2;   // [8:10]  Collation Level
  uint32_t cs_type_   : 6;   // [10:16] Collation Type（用了6位）
  uint32_t scale_     : 8;   // [16:24] Scale（小数位）
  // 后面还有 stored_numeric_precision_、extend_type_ 等
};
```

关键设计点：
- **type**（8 bit）— 足够覆盖 54 种 ObObjType（需 6 bit，预留 2 bit）
- **cs_type**（6 bit）— 字符集/排序规则类型（共约 30 种）
- **scale**（8 bit）— 小数精度/LOB 存储类型，使用 union 复用以节省空间

### 2.3 ObObjValue 联合体（`ob_object.h` 第 1444 行）

值部分是一个 **8 字节**的 union，包含 15 种不同的字段解释：

```cpp
union ObObjValue {
  int64_t int64_;           // 有符号整型
  uint64_t uint64_;         // 无符号整型
  float float_;             // FLOAT
  double double_;           // DOUBLE
  const char *string_;      // 字符串指针（指向外部 buffer）
  uint32_t *nmb_digits_;    // NUMBER 的数字数组
  int64_t datetime_;        // DATETIME 时间戳
  int32_t date_;            // DATE
  int64_t time_;            // TIME
  uint8_t year_;            // YEAR
  int64_t ext_;             // 扩展值（min/max/nop）
  int64_t unknown_;         // 未知类型
  const ObLobCommon *lob_;  // LOB 数据
  const ObLobLocator *lob_locator_;  // LOB 定位器
  // ...
};
```

**Union 设计**：所有类型的值共享同一个 8 字节空间。对于整型（int64_t），全部 8 字节都有意义；对于 YEAR 类型，只用了最低 1 字节。这种设计节省了大量内存，但要求使用者必须通过 `meta_.type_` 来确定如何解释 `v_` 中的值。

### 2.4 NOP 和特殊值

ObObj 定义了三个特殊值（`ob_object.h` 第 1482-1488 行），用于存储引擎中的边界比较和空操作标记：

```cpp
static const int64_t MIN_OBJECT_VALUE  = INT64_MIN;  // 最小值
static const int64_t MAX_OBJECT_VALUE  = INT64_MAX;  // 最大值
static const char    *NOP_VALUE_STR    = "NOP";      // 空操作
```

- **Min/Max**：存储引擎中的虚拟边界值，用于范围扫描的起止
- **NOP（No Operation）**：MVCC 多版本中的逻辑删除标记，表示"这个值不存在"

### 2.5 setter/getter 设计

ObObj 为每个数据类型提供了独立的 setter 和 getter 方法。setter 同时设置 `meta_` 中的 type 和 `v_` 中的值：

```cpp
// ob_object.h 第 1596 行
void set_int(const int64_t v) {
  meta_.set_type(ObIntType);
  v_.int64_ = v;
}

// ob_object.h 第 1775 行
int64_t get_int() const {
  return v_.int64_;
}
```

对于不同精度的整数类型（TinyInt、SmallInt、MediumInt、Int32、Int），setter 都复用 `v_.int64_`，只是 `meta_.type_` 不同。这种设计确保比较操作时可以通过 `meta_` 判断语义含义，而值读取则统一为 int64_t。

---

## 3. ObDatum — 列存时代的紧凑设计

### 3.1 设计动机

ObObj 作为行存时代的通用数据表示，有一个显著问题：**16 字节对于大多数类型来说太大了**。对于 YEAR（1 字节）或 FLOAT（4 字节）这样的类型，大量空间被浪费。

随着 OceanBase 引入**列存编码引擎**（参见文章 26），需要一种更紧凑的数据表示。ObDatum 应运而生。

### 3.2 内存布局

ObDatum 定义在 [`ob_datum.h` 第 177 行](vscode://file/~/code/oceanbase/src/share/datum/ob_datum.h:177)，通过多重继承将**指针**和**描述符**组合成一个 **12 字节**的结构：

```
 ObDatum (12 bytes)
┌──────────────────────────────────────────────────┐
│ ObDatumPtr (8 bytes)                             │
│ ┌──────────────────────────────────────────────┐  │
│ │ union { const char* ptr_; int64_t* int_; ... │  │
│ │         float* float_; double* double_; ...  │  │
│ │         ObLobCommon* lob_data_;             │  │
│ │         ObDecimalInt* decimal_int_;         │  │
│ │       }                                       │  │
│ └──────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────┤
│ ObDatumDesc (4 bytes)                             │
│ ┌──────┬──────┬──────────────────────────────┐   │
│ │ len_ │ flag│ null_                        │   │
│ │29bit │ 2bit│ 1bit                         │   │
│ └──────┴──────┴──────────────────────────────┘   │
└──────────────────────────────────────────────────┘
```

ObDatum 的核心思想是：**元数据不再自包含**。ObDatum 只存储指向数据的指针和一个 4 字节的描述符（packed 结构），实际的元数据（类型、精度、字符集）由调用方通过 `ObObjMeta` 单独传递。

### 3.3 ObDatumDesc（`ob_datum.h` 第 115 行）

描述符的位布局：

```cpp
struct ObDatumDesc {
  union {
    struct {
      uint32_t len_   : 29;   // 数据长度（0-536M）
      uint32_t flag_  : 2;    // 标志（NONE/OUTROW/EXT/HAS_LOB_HEADER）
      uint32_t null_  : 1;    // 是否为 NULL
    };
    uint32_t pack_;            // 整体操作
  };
};
```

- **len_**（29 bit）— 覆盖最大 536MB 的数据长度
- **flag_**（2 bit）— 4 种标志：NONE（常规）、OUTROW（LOB 行外存储）、EXT（ObObj 扩展）、HAS_LOB_HEADER
- **null_**（1 bit）— 独立的 NULL 标识

### 3.4 ObObjDatumMapType — 类型到内存布局的映射

[`ob_datum.h` 第 80 行](vscode://file/~/code/oceanbase/src/share/datum/ob_datum.h:80)定义了从 ObObjType 到 ObDatum 内存布局的映射：

```cpp
enum ObObjDatumMapType : uint8_t {
  OBJ_DATUM_NULL,            // 0 B  — NULL
  OBJ_DATUM_STRING,          // 可变 — 字符串（ptr + len）
  OBJ_DATUM_NUMBER,          // 4~40B— NUMBER（desc + digits）
  OBJ_DATUM_8BYTE_DATA,      // 8 B  — int64, double, datetime
  OBJ_DATUM_4BYTE_DATA,      // 4 B  — float, date, int32
  OBJ_DATUM_1BYTE_DATA,      // 1 B  — year
  OBJ_DATUM_4BYTE_LEN_DATA,  // 12 B — 4B len + 8B data（TimestampTZ, IntervalDS）
  OBJ_DATUM_2BYTE_LEN_DATA,  // 10 B — 2B len + 8B data（TimestampLTZ, TimestampNano）
  OBJ_DATUM_FULL,            // 16 B — 完整的 ObObj（Extend 类型）
  OBJ_DATUM_DECIMALINT,      // 4~64B— Decimal Int
  OBJ_DATUM_MAPPING_MAX,
};
```

每种 ObObjType 对应的映射关系如下（来自 `ob_datum.h` 头部的注释表）：

| 类型 | 映射类型 | 最小长度 | 最大长度 |
|------|---------|---------|---------|
| ObNullType | NULL | 0 | 0 |
| ObTinyIntType ~ ObIntType | 8BYTE_DATA | 8 | 8 |
| ObUTinyIntType ~ ObUInt64Type | 8BYTE_DATA | 8 | 8 |
| ObFloatType / ObUFloatType | 4BYTE_DATA | 4 | 4 |
| ObDoubleType / ObUDoubleType | 8BYTE_DATA | 8 | 8 |
| ObNumberType / ObUNumberType | NUMBER | 4 | 40 |
| ObDateTimeType / ObTimestampType | 8BYTE_DATA | 8 | 8 |
| ObDateType | 4BYTE_DATA | 4 | 4 |
| ObYearType | 1BYTE_DATA | 1 | 1 |
| ObVarcharType ~ ObLongTextType | STRING | 0 | 类型最大值 |
| ObTimestampTZType | 4BYTE_LEN_DATA | 12 | 12 |
| ObTimestampLTZType / NanoType | 2BYTE_LEN_DATA | 10 | 10 |
| ObIntervalYMType | 8BYTE_DATA | 8 | 8 |
| ObIntervalDSType | 4BYTE_LEN_DATA | 12 | 12 |
| ObDecimalIntType | DECIMALINT | 4 | 64 |
| ObExtendType | FULL | 16 | 16 |

### 3.5 Obj → Datum 转换

`ObDatum::from_obj()` 方法（`ob_datum.h` 第 336 行）实现了从 ObObj 到 ObDatum 的转换。对于每个数据类型，有一组模板特化的 `obj2datum<>` 和 `datum2obj<>` 方法：

```cpp
// 以 8 字节数据为例
template <>
inline void ObDatum::obj2datum<OBJ_DATUM_8BYTE_DATA>(const ObObj &obj)
{
  // 从 ObObj 的 v_ 中拷贝 8 字节
  memcpy(no_cv(ptr_), &obj.v_.uint64_, sizeof(uint64_t));
  pack_ = sizeof(uint64_t);
}

template <>
inline void ObDatum::datum2obj<OBJ_DATUM_8BYTE_DATA>(ObObj &obj) const
{
  // 反向：从 Datum 恢复到 ObObj
  memcpy(&obj.v_.uint64_, ptr_, sizeof(uint64_t));
}
```

注意这里的 `pack_` 赋值同时设置了 `len_`（29 bit）和 `null_`（1 bit），因为 `null_ == 0` 意味着数据非空。这是 ObDatumDesc 中 union 设计的巧妙之处。

### 3.6 ObDatum 操作函数

`ob_datum_funcs.h`（第 22 行）定义了 Datum 层的比较和哈希函数类型：

```cpp
typedef int (*ObDatumCmpFuncType)(const ObDatum &datum1, const ObDatum &datum2, int &cmp_ret);
typedef int (*ObDatumHashFuncType)(const ObDatum &datum, const uint64_t seed, uint64_t &res);
```

`ObDatumFuncs`（第 35 行）提供了获取比较/哈希函数的工厂方法：

```cpp
static ObDatumCmpFuncType get_nullsafe_cmp_func(
    const ObObjType type1, const ObObjType type2,
    const ObCmpNullPos null_pos, const ObCollationType cs_type,
    const ObScale max_scale, const bool is_oracle_mode,
    const bool has_lob_header, const ObPrecision prec1, const ObPrecision prec2);
```

这里的设计模式是**函数指针表**——不是直接做类型分支判断，而是在初始化时从全局函数表中查找到对应的比较/哈希函数，之后通过函数指针调用。这在 SQL 表达式引擎的高频调用场景中尤为重要。

`get_basic_func()` 方法（第 63 行）返回一组基础函数（比较、哈希、长度计算），用于表达式求值：

```cpp
static sql::ObExprBasicFuncs* get_basic_func(
    const ObObjType type, const ObCollationType cs_type,
    const ObScale scale, const bool is_oracle_mode,
    const bool is_lob_locator, const ObPrecision prec);
```

### 3.7 ObDatumRow — 存储层行格式

[`ob_datum_row.h`](vscode://file/~/code/oceanbase/src/storage/blocksstable/ob_datum_row.h) 定义了存储引擎使用的行格式 `ObDatumRow`：

```cpp
struct ObDatumRow {
  uint16_t count_;                          // 列数
  uint32_t read_flag_;                      // 读取标志位
  ObDmlRowFlag row_flag_;                   // DML 操作类型
  ObMultiVersionRowFlag mvcc_row_flag_;     // MVCC 版本标志
  transaction::ObTransID trans_id_;         // 事务 ID
  int64_t snapshot_version_;                // 快照版本
  int64_t insert_version_;                  // 插入版本
  int64_t delete_version_;                  // 删除版本
  ObStorageDatum *storage_datums_;          // Datum 数组
  // ...
};
```

每个列的值通过 `ObStorageDatum`（ObDatum 的存储层封装）表示。存储引擎不直接操作 ObObj，而是操作 ObDatumRow，仅在必要时（如 SQL 表达式求值）将 Datum 转换为 ObObj。

---

## 4. ObString — 字符串处理

### 4.1 设计和内存布局

ObString 定义在 [`ob_string.h` 第 36 行](vscode://file/~/code/oceanbase/deps/oblib/src/lib/string/ob_string.h:36)，是 OceanBase 中最基础的字符串抽象：

```
 ObString (12 bytes)
┌──────────────────────────────────────────────────┐
│ buffer_size_ (int32_t, 4 bytes)                  │
│ ┌──────────────────────────────────────────────┐  │
│ │ 缓冲区容量（拥有所有权时为 buffer 大小）       │  │
│ └──────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────┤
│ data_length_ (int32_t, 4 bytes)                   │
│ ┌──────────────────────────────────────────────┐  │
│ │ 实际数据长度                                  │  │
│ └──────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────┤
│ ptr_ (char*, 8 bytes — 64位系统)                  │
│ ┌──────────────────────────────────────────────┐  │
│ │ 指向字符串数据的指针                           │  │
│ └──────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

### 4.2 所有权模型

ObString 的核心理念是：**不拥有内存**。它是一个轻量级的视图（view），只是指向一段已经分配好的内存：

```cpp
class ObString final {
  obstr_size_t buffer_size_;   // 缓冲区容量
  obstr_size_t data_length_;   // 实际数据长度
  char *ptr_;                  // 数据指针
};
```

三种使用模式：

| 模式 | assign_ptr | assign_buffer | assign |
|------|-----------|---------------|--------|
| buffer_size_ | 0（不拥有） | buffer 大小 | data_length_ |
| data_length_ | 实际长度 | 0（可写入） | 实际长度 |
| ptr_ | 外部指针 | 内部 buffer | 内部 buffer |
| 能否写入 | ❌ | ✅ | ✅（覆盖写入） |

**浅拷贝模型**：ObString 的拷贝构造函数和赋值运算符使用 C++ 默认的浅拷贝。这意味着两个 ObString 可以指向同一块内存。当需要深拷贝时，调用 `clone()` 方法：

```cpp
// ob_string.h 第 132 行
int clone(const ObString &rv, ObDataBuffer &buf);
```

### 4.3 在 ObObj 和 ObDatum 中的使用

ObString 作为 ObObjValue 联合体中的指针引用：

- **ObObj**：`v_.string_` 指向字符串数据，`val_len_` 存储长度
- **ObDatum**：`ptr_` 指向字符串数据，`len_` 存储长度
- **ObString 接口**：ObDatum 的 `get_string()` 方法封装了长度和指针：

```cpp
// ob_datum.h 第 238 行
inline const ObString get_string() const {
  return ObString(len_, ptr_);
}
```

---

## 5. ObObj vs ObDatum 对比

### 5.1 结构对比

| 维度 | ObObj | ObDatum |
|------|-------|---------|
| 总大小 | 16 字节 | 12 字节 |
| 元数据 | 内置 4 字节（type, cs, scale） | 外部传递（ObObjMeta） |
| 值存储 | 8 字节 union + 4 字节 val_len | 8 字节指针 + 4 字节描述符 |
| 固定长度类型 | 浪费空间（YEAR 也用 16B） | 紧凑（YEAR 只用 1B） |
| 字符串 | 指针 + val_len | 指针 + len |
| NUMBER | nmb_desc + nmb_digits 指针 | desc + digits 内联拷贝 |
| 反序列化 | 直接使用 | 需要 ObjMeta 辅助重建 |
| NULL 表示 | type == ObNullType | null_ 位域独立标记 |

### 5.2 为什么从 ObObj 演进到 ObDatum？

1. **列存编码兼容** — 编码引擎（文章 26）需要把数据表示成紧凑的二进制流。ObDatum 的"数据在连续内存中"特性使得编码/解码可以直接操作内存块。

2. **减少内存分配** — ObObj 中 NUMBER 的 digits 是指向外部 buffer 的指针，需要额外的内存分配。ObDatum 在 `from_obj()` 中将 digits 内联拷贝到 ptr_ 指向的预留空间中。

3. **更快的比较/哈希** — ObDatum 的比较函数直接操作内存（`is_null() 先检查，然后 MEMCMP` 或直接读数值），减少了间接引用。`ObDatum::binary_equal()` 方法（第 194 行）展示了这种优化：

```cpp
static bool binary_equal(const ObDatum &r, const ObDatum &l) {
  if (r.is_null() != l.is_null()) return false;
  if (!r.is_null()) {
    if (r.pack_ != l.pack_) return false;
    return 0 == MEMCMP(r.ptr_, l.ptr_, r.len_);
  }
  return true;
}
```

4. **与向量化引擎配合** — ObDatum 的紧凑布局更容易批量加载到 SIMD 寄存器中进行向量化计算。`ObDatumVector` 结构（第 281 行）提供了批处理能力：

```cpp
struct ObDatumVector {
  ObDatum *at(const int64_t i) const { return datums_ + (mask_ & i); }
  void set_batch(const bool is) { mask_ = is ? UINT64_MAX : 0; }
  ObDatum *datums_ = nullptr;
  uint64_t mask_ = 0;
};
```

### 5.3 两种 NULL 表示

| 方式 | ObObj | ObDatum |
|------|-------|---------|
| NULL 表示 | `type_ == ObNullType` | `null_ == 1`（独立位域） |
| 语义 NULL | 专门类型，与其他类型互斥 | 可与其他类型共存 |
| 性能影响 | 每次读值前需要查 type | 一次位测试即可 |

这是 ObDatum 的一个关键优化——NULL 检查从"读取类型 + 比较"降低到"读取一个 bit"。

---

## 6. 精度与比例管理

### 6.1 ObAccuracy

`ob_object.h` 第 23 行前向声明的 `ObAccuracy` 用于描述列的精度信息：

```cpp
// 用于 ObObjParam 和 ObDataType
struct ObAccuracy {
  uint16_t accuracy_;    // 编码后的精度/长度信息
  // 通过位域操作访问 precision、scale、length_semantics
};
```

精度信息在两种场景下使用：

1. **SQL 参数绑定（ObObjParam）**：记录参数的精度和长度语义
2. **数据类型定义（ObDataType）**：记录列的精度和比例

### 6.2 ObDatum 的精度处理

ObDatum 本身不存储精度信息——精度由调用方（通常是表达式引擎）通过 `ObObjMeta` 传入。当 ObDatum 转换为 ObObj 时：

```cpp
// ob_datum.h 第 422 行
inline int ObDatum::to_obj(ObObj &obj, const ObObjMeta &meta) const
{
  obj.meta_ = meta;  // 从外部传入元数据
  // 然后根据 meta.get_type() 选择对应的 datum2obj 模板
}
```

这是一个重要设计决策：**职责分离**。Datum 只负责"值怎么存放"，不关心"这个值的语义类型是什么"。语义类型由上层通过 ObObjMeta 管理。

---

## 7. 类型间转换

### 7.1 隐式转换规则

[`ob_obj_type.h` 第 411 行](vscode://file/~/code/oceanbase/deps/oblib/src/common/object/ob_obj_type.h:411)定义了隐式转换方向：

```cpp
enum ImplicitCastDirection {
  IC_NOT_SUPPORT,   // 不支持
  IC_NO_CAST,       // 不需要转换（相同类型）
  IC_A_TO_B,        // A 可以隐式转换为 B
  IC_B_TO_A,        // B 可以隐式转换为 A
  IC_TO_MIDDLE_TYPE,// 两者转换为中间类型（如 INT + FLOAT → DOUBLE）
  IC_A_TO_C,        // A 通过 C 间接转换
  IC_B_TO_C,        // B 通过 C 间接转换
};
```

转换规则通过 `OB_OBJ_IMPLICIT_CAST_DIRECTION_FOR_ORACLE` 宏（第 424 行）生成整个类型矩阵（54×54）。

### 7.2 静态转换检查

`ob_can_static_cast()` 函数（同文件第 1695 行）提供静态类型兼容性判断，用于 SQL 编译阶段检查类型转换是否合法。

### 7.3 实际转换入口

`ob_obj_cast.h` 提供了类型转换的核心实现。转换过程涉及：

1. 源类型和目标类型的兼容性检查
2. 精度/比例的调整
3. 字符集转换
4. NULL 处理

---

## 8. 设计决策总结

### 8.1 Union vs 分离存储

ObObj 选择了一个 **16 字节的 union**（4B meta + 4B val_len + 8B v_）来覆盖所有数据类型。优点是：

- **自包含**：一个 ObObj 就是一个完整的数据表达，不需要外部上下文
- **简单**：直接的 struct + union 模式，易于理解和调试

缺点是：
- **空间浪费**：即使只存一个 YEAR（1 字节），也占用 16 字节
- **间接引用**：字符串和 NUMBER 的值存储在外部，需要额外的内存管理

ObDatum 选择了 **12 字节的指针 + 描述符**模式，牺牲了自包含性，换来了：

- **紧凑布局**：每种类型只占用实际所需的最小空间
- **连续内存**：便于编码引擎和 SIMD 优化
- **NULL 独立表示**：位域级别的 NULL 检测

### 8.2 ObString 的浅拷贝设计

ObString 的"不拥有内存"设计是受限于 OceanBase 的内存管理策略：

- **表达式引擎**：在 SQL 表达式求值过程中，字符串的生命周期由 `EvalContext` 管理，不需要 ObString 自己释放
- **存储引擎**：读出的数据在 buffer 释放前一直有效
- **序列化**：`clone()` 方法将字符串拷贝到专门的序列化 buffer 中

这种设计避免了大量的深拷贝开销，但要求调用方严格遵守生命周期约定。

### 8.3 类型系统的未来演进

从 ObObj 到 ObDatum 的演进展示了 OceanBase 的技术路线：

```
ObObj（16B 自包含） → ObDatum（12B 紧凑） → 编码引擎（可变长度二进制）
 行存时期               列存时期               编码压缩
```

下一篇文章（25）将分析 OceanBase 的编码引擎（Encoding Engine），它是 ObDatum 的最大消费者——将 Datum 进一步压缩为高度优化的二进制格式。

---

## 9. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `enum ObObjType` | `ob_obj_type.h` | 29 |
| `enum ObObjTypeClass` | `ob_obj_type.h` | 228 |
| `const ObObjTypeClass OBJ_TYPE_TO_CLASS[]` | `ob_obj_type.h` | 330 |
| `enum VecValueTypeClass` | `ob_obj_type.h` | 1174 |
| `struct ObObjMeta` | `ob_object.h` | 108 |
| `union ObObjValue` | `ob_object.h` | 1444 |
| `class ObObj` | `ob_object.h` | 1478 |
| `ObObj::set_int()` | `ob_object.h` | 1596 |
| `ObObj::get_int()` | `ob_object.h` | 1775 |
| `class ObString` | `ob_string.h` | 36 |
| `ObString::assign_ptr()` | `ob_string.h` | 156 |
| `ObString::assign_buffer()` | `ob_string.h` | 194 |
| `ObString::clone()` | `ob_string.h` | 132 |
| `struct ObDatumPtr` | `ob_datum.h` | 102 |
| `struct ObDatumDesc` | `ob_datum.h` | 115 |
| `struct ObDatum` | `ob_datum.h` | 177 |
| `enum ObObjDatumMapType` | `ob_datum.h` | 80 |
| `ObDatum::from_obj()` | `ob_datum.h` | 336 |
| `ObDatum::to_obj()` | `ob_datum.h` | 422 |
| `ObDatum::obj2datum<OBJ_DATUM_8BYTE_DATA>()` | `ob_datum.h` | 312 |
| `ObDatum::binary_equal()` | `ob_datum.h` | 194 |
| `struct ObDatumVector` | `ob_datum.h` | 281 |
| `struct ObDatumRow` | `ob_datum_row.h` | 177 |
| `class ObDatumFuncs` | `ob_datum_funcs.h` | 35 |
| `enum ImplicitCastDirection` | `ob_obj_type.h` | 411 |

---

> **下一篇预告**：25 — 编码引擎（Encoding Engine），基于 ObDatum 的列存编码/压缩设计。
