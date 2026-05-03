# 54-serialization — OceanBase 序列化框架：OB_UNIS、Meta Serialization 与数据格式

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

序列化框架是 OceanBase 的"通用语言"。无论是节点间 RPC 通信、持久化日志写入、事务日志同步，还是内存结构体的跨版本兼容，序列化都处于最底层。

OceanBase 的序列化分为三个层次：

| 层 | 文件 | 职责 |
|----|------|------|
| **基础编码层** | `deps/oblib/src/lib/utility/serialization.h` | varint 编码、定长整数、字符串、浮点数、时间类型、Decimal |
| **OB_UNIS 宏框架** | `deps/oblib/src/lib/utility/ob_unify_serialize.h/cpp` | 自动生成 `serialize/deserialize/get_serialize_size` 三件套 |
| **Meta 序列化** | `deps/oblib/src/common/meta_programming/ob_meta_serialization.h` | 编译期 SFINAE 动态选择序列化路径（Deep vs Normal） |
| **便利模板** | `deps/oblib/src/lib/utility/ob_serialization_helper.h` | `DefaultItemEncode<T>` 对任意类型自动适配 |
| **Hash 序列化** | `deps/oblib/src/lib/hash/ob_serialization.h` | 与 `SimpleArchive` 文件包装器配合的序列化/反序列化接口 |

### 解决的问题

1. **统一接口**：所有可序列化类型通过三个方法 `serialize(buf, buf_len, pos)` / `deserialize(buf, data_len, pos)` / `get_serialize_size()` 与外界交互
2. **版本兼容**：每个结构体携带版本号，支持向后兼容
3. **紧凑编码**：自研 TLV 式编码，小值整数 1 字节编码，字符串 1 字节前导
4. **零反射**：使用 C++ 模板 + 宏，编译期生成所有代码，无运行时 RTTI
5. **C 兼容**：基础编码层纯 C/C++ inline 函数，可被 pnio（纯 C 实现）复用

---

## 1. 基础编码层 — `serialization.h`

### 1.1 编码体系

`deps/oblib/src/lib/utility/serialization.h`（约 3000 行）定义了 OceanBase 所有基础类型的编码原语。这是整个序列化框架的最底层。

编码格式分为两大类：**定长编码** 和 **变长编码**。

### 1.2 变长编码 — Varint 系列

Varint 编码的核心思想：**小值用更少字节**。这是 protobuf 也采用的技术。

#### encode_vi64 / encode_vi32

```cpp
// serialization.h — do-lsp symbol 确认
const uint64_t OB_MAX_V1B = (1ULL << 7) - 1;    // 127，1 字节可表示
const uint64_t OB_MAX_V2B = (1ULL << 14) - 1;    // 16383
const uint64_t OB_MAX_V3B = (1ULL << 21) - 1;
// ... 直到 OB_MAX_V9B

// 编码写入（第 387-410 行）
inline int encode_vi64(char *buf, const int64_t buf_len, int64_t &pos, int64_t val)
{
  uint64_t __v = static_cast<uint64_t>(val);
  // 逐 7 位编码，高位置 1 表示还有后续字节
  while (__v > OB_MAX_V1B) {
    *(buf + pos++) = static_cast<int8_t>((__v) | 0x80);  // 高位置 1
    __v >>= 7;
  }
  *(buf + pos++) = static_cast<int8_t>((__v) & 0x7f);    // 最后字节，高位为 0
}
```

编码规则：
- 每个字节的低 7 位是数据位，最高位是延续位
- 延续位 = 1 → 后续还有字节
- 延续位 = 0 → 这是最后一个字节
- 小端序：**低位在前**

| 值范围 | 编码字节数 |
|--------|-----------|
| 0-127 | 1 |
| 128-16383 | 2 |
| 16384-2097151 | 3 |
| ... | ... |
| 最大 64bit | 10 |

#### decode_vi64

```cpp
// serialization.h（第 441-460 行）
inline int decode_vi64(const char *buf, const int64_t data_len, int64_t &pos, int64_t *val)
{
  uint64_t __v = 0;
  uint32_t shift = 0;
  int64_t tmp_pos = pos;
  // 逐字节读取，直到延续位为 0
  while ((*(buf + tmp_pos)) & 0x80) {
    __v |= (static_cast<uint64_t>(*(buf + tmp_pos++)) & 0x7f) << shift;
    shift += 7;
  }
  __v |= ((static_cast<uint64_t>(*(buf + tmp_pos++)) & 0x7f) << shift);
  *val = static_cast<int64_t>(__v);
  pos = tmp_pos;
}
```

#### encode_fixed_bytes_i64 — 定长 varint 编码

```cpp
// serialization.h（第 425-439 行）
inline int encode_fixed_bytes_i64(char *buf, const int64_t buf_len, int64_t &pos, int64_t val)
{
  // 固定使用 OB_SERIALIZE_SIZE_NEED_BYTES = 5 个字节
  // 这是 OB_UNIS 头部长度字段使用的编码方式
  int n = OB_SERIALIZE_SIZE_NEED_BYTES;
  while (n--) {
    if (n > 0) {
      *(buf + pos++) = static_cast<int8_t>((__v) | 0x80);
      __v >>= 7;
    } else {
      *(buf + pos++) = static_cast<int8_t>((__v) & 0x7f);
    }
  }
}
```

**为什么有这个特殊函数？** OB_UNIS 框架的 payload 长度字段固定用 5 字节编码，这是为了**回写**——先占位写入 payload，回来再覆盖写入真实长度。5 字节意味着最多表示 $(2^{35} - 1) = 34GB$，远超过任何单个消息的大小，同时又保持了 varint 的空间效率。

### 1.3 定长编码 — 大端序整数

```cpp
// serialization.h 第 83-230 行
// encode_i16 / decode_i16 / encode_i32 / decode_i32 / encode_i64 / decode_i64
// 全部使用大端序（网络字节序）

inline int encode_i32(char *buf, const int64_t buf_len, int64_t &pos, int32_t val)
{
  *(buf + pos++) = static_cast<char>(((val) >> 24) & 0xff);
  *(buf + pos++) = static_cast<char>(((val) >> 16) & 0xff);
  *(buf + pos++) = static_cast<char>(((val) >> 8) & 0xff);
  *(buf + pos++) = static_cast<char>((val) & 0xff);
}
```

关键设计决策：**所有定长编码使用大端序**，确保了跨平台兼容性（PowerPC/x86/ARM 的大端/小端问题通过固定网络字节序解决）。

### 1.4 浮点数编码

```cpp
// serialization.h 第 554-584 行
inline int encode_float(char *buf, const int64_t buf_len, int64_t &pos, float val)
{
  // 先将 float 的原始内存位拷贝到 int32_t
  int32_t tmp = 0;
  MEMCPY(&tmp, &val, sizeof(tmp));
  // 然后通过 varint 编码 int32_t
  return encode_vi32(buf, buf_len, pos, tmp);
}

inline int encode_double(char *buf, const int64_t buf_len, int64_t &pos, double val)
{
  int64_t tmp = 0;
  MEMCPY(&tmp, &val, sizeof(tmp));
  return encode_vi64(buf, buf_len, pos, tmp);
}
```

**重要**：浮点数不是直接用 `memcpy` 盲拷贝，而是通过 varint 编码整数位表示。这相当于将浮点数的 IEEE 754 位模式当作整数编码，可以获得一定的压缩效果（当浮点数绝对值较小时）。

### 1.5 字符串编码

字符串有两种编码方式：

#### vstr — 通用字符串

```cpp
// serialization.h 第 639-695 行
// 格式：[varint 长度] [数据] [\0 结尾]
inline int encode_vstr(char *buf, const int64_t buf_len, int64_t &pos,
                       const void *vbuf, int64_t len)
{
  encode_vi64(buf, buf_len, pos, len);     // 先编码长度
  MEMCPY(buf + pos, vbuf, len);            // 再拷贝数据
  pos += len;
  *(buf + pos++) = 0;                      // 最后写入 \0
}
```

vstr 的特点是**自描述**且**包含终止符**，解码时返回原始指针（零拷贝友好）：

```cpp
inline const char *decode_vstr(const char *buf, const int64_t data_len,
                               int64_t &pos, int64_t *lenp)
{
  decode_vi64(buf, data_len, tmp_pos, &tmp_len);
  str = buf + tmp_pos;        // 返回原始 buf 中的指针，零拷贝！
  *lenp = tmp_len++;
  tmp_pos += tmp_len;
  pos = tmp_pos;
}
```

#### str — 紧凑字符串（带类型字节）

```cpp
// serialization.h 第 788-830 行
// 格式：[类型字节(高位标记为 VARCHAR)] [长度] [数据]
// 长度小于 56 的直接编码在类型字节的低 6 位

inline int encode_str(char *buf, const int64_t buf_len, int64_t &pos,
                      const void *vbuf, int64_t len)
{
  int8_t first_byte = OB_VARCHAR_TYPE;  // 0x80
  if (1 == len_size) {
    first_byte |= (len & 0xff);          // 短字符串：长度编码在首字节
  } else {
    first_byte |= (len_size - 1 + 55);
  }
  // ... 编码首字节 + 长度 + 数据
}
```

### 1.6 类型标记编码

对于 ObObj（OceanBase 的通用值类型），`serialization.h` 定义了类型标记：

```cpp
// serialization.h 第 55-67 行
const int8_t OB_VARCHAR_TYPE = static_cast<int8_t>((0x1 << 7));   // 0x80
const int8_t OB_DATETIME_TYPE = static_cast<int8_t>(0xd0);
const int8_t OB_PRECISE_DATETIME_TYPE = static_cast<int8_t>(0xe0);
const int8_t OB_FLOAT_TYPE = static_cast<int8_t>(0xf8);
const int8_t OB_DOUBLE_TYPE = static_cast<int8_t>(0xfa);
const int8_t OB_NULL_TYPE = static_cast<int8_t>(0xfc);
const int8_t OB_BOOL_TYPE = static_cast<int8_t>(0xfd);
const int8_t OB_EXTEND_TYPE = static_cast<int8_t>(0xfe);
const int8_t OB_DECIMAL_TYPE = static_cast<int8_t>(0xff);
```

每个类型的首字节同时携带**类型标识**和**长度值**，在解码时通过位运算提取：

```cpp
// 二进制格式（以 VARCHAR 为例）：
// [1|0|0|0|0|0|0|0] ← OB_VARCHAR_TYPE (0x80)
//   ↑           ↑
//   类型标记     编码长度（低 6 位）
//               当长度 ≤ 55 时直接编码
//               当长度 > 55 时 = 55 + (额外长度字节数 - 1)
```

### 1.7 带符号整数优化 — fast_encode / fast_decode

对于需要特殊处理符号的 ObInt 类型，OceanBase 实现了**带符号的紧凑编码**：

```cpp
// serialization.h 第 890-940 行
inline int fast_encode(char *buf, int64_t &pos, int64_t val, bool is_add = false)
{
  int8_t first_byte = 0;
  if (val < 0) {
    set_bit(first_byte, OB_INT_SIGN_BIT_POS);  // 符号位
    val = -val;
  }
  if (is_add) {
    set_bit(first_byte, OB_INT_OPERATION_BIT_POS);
  }
  // 根据绝对值大小选择编码方式
  if ((uint64_t)val <= OB_MAX_INT_1B) {         // ≤ 23：直接编码在首字节
    first_byte |= static_cast<int8_t>(val);
    buf[pos++] = first_byte;
  } else {
    // 使用 goto 跳转到不同长度编码位置（手动 Duff's Device 风格）
    // ...
  }
}
```

这是一种**非前缀变量**的编码——首字节的低 5 位既是长度指示也是值，当值 ≤ 23 时零额外开销。

### 1.8 时间类型编码

```cpp
// serialization.h 第 1070-1150 行
// 三种时间类型共享 __encode_time_type 实现
// ObDateTime → 0xd0 | 符号位 | 操作位
// ObPreciseDateTime → 0xe0
// ObModifyTime → 0xf0

inline int __encode_time_type(char *buf, const int64_t buf_len,
                              int8_t first_byte, int64_t &pos, int64_t val)
{
  // len 根据值大小决定：5 字节 / 7 字节 / 9 字节
  // 长度标记编码在 first_byte 的低 2 位
  if (7 == len) first_byte |= 1;
  else if (9 == len) first_byte |= 2;
  // 然后编码首字节 + 绝对值
}
```

### 1.9 模板调度 — encode/decode/encoded_length

`serialization.h` 提供了全局模板函数，作为统一入口：

```cpp
// serialization.h 第 1300-1600 行
// 通过重载和模板特化，实现对任意类型的统一调度

// 枚举类型 → 按 int32 编码
template<typename T>
struct EnumEncoder<true, T> {
  static int encode(...) { return encode_vi32(buf, buf_len, pos, (int32_t)val); }
};

// 非枚举类型 → 调用 serialize 方法
template<typename T>
struct EnumEncoder<false, T> {
  static int encode(...) { return val.serialize(buf, buf_len, pos); }
};

// 全局统一入口
template <typename T>
int encode(char *buf, const int64_t buf_len, int64_t &pos, const T &val)
{
  return EnumEncoder<__is_enum(T), T>::encode(buf, buf_len, pos, val);
}

// 基础类型重载（直接调 varint/定长编码）
int encode(char *buf, const int64_t buf_len, int64_t &pos, int64_t val);
int encode(char *buf, const int64_t buf_len, int64_t &pos, float val);
int encode(char *buf, const int64_t buf_len, int64_t &pos, double val);
// ... 还有 int8/16/32、uint 系列、bool、char、数组、pair 等
```

---

## 2. OB_UNIS 宏框架 — `ob_unify_serialize.h`

### 2.1 文件概览

`deps/oblib/src/lib/utility/ob_unify_serialize.h`（478 行）定义了 OceanBase 统一序列化框架的整套宏体系。这是文章 53 中提到的序列化框架的完整展开。

OB_UNIS 不是一个运行时库，而是一个**编译期宏框架**——所有序列化代码在预处理阶段自动生成。

### 2.2 核心三接口

任何支持 OB_UNIS 的结构体都需要实现三个方法：

```cpp
int serialize(char *buf, const int64_t buf_len, int64_t &pos) const;
int deserialize(const char *buf, const int64_t data_len, int64_t &pos);
int64_t get_serialize_size() const;
```

- 所有方法都通过 `SERIAL_PARAMS` / `DESERIAL_PARAMS` 宏定义参数
- `pos` 是**必须传引用**的游标（`int64_t &pos`），序列化时自动推进
- 错误返回码：`OB_SIZE_OVERFLOW`（空间不足）、`OB_DESERIALIZE_ERROR`（数据不完整）

### 2.3 OB_UNIS 宏体系（核心）

#### 声明宏

```cpp
// ob_unify_serialize.h（第 314-320 行）
// 在类声明中插入，声明序列化接口

#define OB_UNIS_VERSION(VER)                            \
  public: OB_DECLARE_UNIS(,);                           \
private:                                                \
  const static int64_t UNIS_VERSION = VER               // 版本号

// OB_DECLARE_UNIS 展开为 6 个方法的声明：
#define OB_DECLARE_UNIS(VIR,PURE)               \
  VIR int serialize(SERIAL_PARAMS) const PURE;   \
  int serialize_(SERIAL_PARAMS) const;          \
  VIR int deserialize(DESERIAL_PARAMS) PURE;     \
  int deserialize_(DESERIAL_PARAMS);            \
  VIR int64_t get_serialize_size() const PURE;   \
  int64_t get_serialize_size_() const;
```

注意：**serialize 和 serialize_ 是两套**。`serialize` 是公共接口（带版本头），`serialize_` 是内部实现（只序列化成员）。这种内外分离的设计保证了版本处理逻辑统一，成员序列化逻辑可复用。

#### 实现宏

```cpp
// ob_unify_serialize.h（第 440-460 行）
// 在 .cpp 中定义实现，自动生成版本头

#define OB_DEF_SERIALIZE(CLS, TEMP...)          \
  TEMP OB_UNIS_SERIALIZE(CLS);                  \  // serialize（带版本头）
  TEMP int CLS::serialize_(SERIAL_PARAMS) const   // serialize_ 定义开始

#define OB_DEF_DESERIALIZE(CLS, TEMP...)        \
  TEMP OB_UNIS_DESERIALIZE(CLS);                \  // deserialize（带版本头）
  TEMP int CLS::deserialize_(DESERIAL_PARAMS)     // deserialize_ 定义开始

#define OB_DEF_SERIALIZE_SIZE(CLS, TEMP...)         \
  TEMP OB_UNIS_SERIALIZE_SIZE(CLS);                 \  // get_serialize_size
  TEMP int64_t CLS::get_serialize_size_(void) const   // get_serialize_size_ 定义开始
```

#### 成员序列化宏

```cpp
// 自动生成结构体所有成员的序列化代码
#define OB_SERIALIZE_MEMBER(CLS, ...)
// 带条件的序列化（条件为 true 时才序列化某个成员）
#define OB_SERIALIZE_MEMBER_IF(CLS, PRED, ...)
// 带继承的序列化
#define OB_SERIALIZE_MEMBER_INHERIT(CLS, PARENT, ...)
```

#### 内部编码宏

```cpp
// ob_unify_serialize.h（第 73-87 行）
// 分别编码单个字段（条件版和直接版）
#define OB_UNIS_ENCODE_IF(obj, PRED)
#define OB_UNIS_DECODE_IF(obj, PRED)
#define OB_UNIS_ENCODE(obj)
#define OB_UNIS_DECODE(obj)

// 计算编码长度
#define OB_UNIS_ADD_LEN_IF(obj, PRED)
#define OB_UNIS_ADD_LEN(obj)

// 数组编码
#define OB_UNIS_ENCODE_ARRAY(objs, objs_count)
#define OB_UNIS_DECODE_ARRAY(objs, objs_count)
#define OB_UNIS_DECODE_ARRAY_AND_FUNC(objs, objs_count, FUNC)  // 含 count 解码

// 指针数组（对象包含指针成员时使用）
#define OB_UNIS_ENCODE_ARRAY_POINTER(objs, objs_count)
#define OB_UNIS_DECODE_ARRAY_POINTER(objs, objs_count, FUNC)
```

### 2.4 序列化编码格式（版本头 + payload）

OB_UNIS 的序列化格式：

```
[version: varint][payload_len: 5-byte fixed-varint][payload: ...]
```

#### serialize — 写入版本头 + 回写长度（`OB_UNIS_SERIALIZE`）

```cpp
// ob_unify_serialize.h（第 232-256 行）
#define OB_UNIS_SERIALIZE(CLS)                                         \
  int CLS::serialize(SERIAL_PARAMS) const                              \
  {                                                                      \
    int ret = OK_;                                                       \
    OB_UNIS_ENCODE(UNIS_VERSION);           // 1. 编码版本号（varint）           \
    if (OB_SUCC(ret)) {                                                  \
      int64_t size_nbytes = NS_::OB_SERIALIZE_SIZE_NEED_BYTES;          \
      int64_t pos_bak = (pos += size_nbytes);  // 2. 占位 5 字节             \
      if (OB_FAIL(serialize_(buf, buf_len, pos))) {  // 3. 编码 payload   \
        // ... error                                                    \
      }                                                                 \
      int64_t serial_size = pos - pos_bak;   // 4. 计算实际长度             \
      int64_t tmp_pos = 0;                                               \
      ret = NS_::encode_fixed_bytes_i64(     // 5. 回写长度               \
        buf + pos_bak - size_nbytes, size_nbytes, tmp_pos, serial_size);\
    }                                                                    \
    return ret;                                                          \
  }
```

#### deserialize — 校验版本 + 提取 payload 子缓冲区

```cpp
// ob_unify_serialize.h（第 258-275 行）
#define OB_UNIS_DESERIALIZE(CLS)                                         \
  int CLS::deserialize(DESERIAL_PARAMS) {                               \
    int ret = OK_;                                                       \
    int64_t version = 0;                                                 \
    int64_t len = 0;                                                     \
    OB_UNIS_DECODE(version);        // 1. 解码版本号                      \
    OB_UNIS_DECODE(len);            // 2. 解码长度                        \
    CHECK_VERSION_LENGTH(CLS, version, len);  // 3. 校验版本是否匹配       \
    // 4. 用子缓冲区调用 deserialize_                                   \
    int64_t pos_orig = pos;                                              \
    pos = 0;                                                             \
    deserialize_(buf + pos_orig, len, pos);                              \
    pos = pos_orig + len;                                                \
  }
```

#### get_serialize_size — 计算总大小

```cpp
// ob_unify_serialize.h（第 277-283 行）
#define OB_UNIS_SERIALIZE_SIZE(CLS)                                      \
  int64_t CLS::get_serialize_size(void) const {                         \
    int64_t len = get_serialize_size_();                                 \
    OB_UNIS_ADD_LEN(UNIS_VERSION);         // 版本号的大小                \
    len += NS_::OB_SERIALIZE_SIZE_NEED_BYTES;  // 5 字节长度字段          \
    return len;                                                          \
  }
```

### 2.5 版本管理

```cpp
// ob_unify_serialize.h（第 214-227 行）
#define CHECK_VERSION_LENGTH(CLS, VER, LEN)                              \
  if (OB_SUCC(ret)) {                                                    \
    if (VER != UNIS_VERSION) {                                           \
      ret = OB_NOT_SUPPORTED;              // 版本不匹配                  \
    } else if (LEN < 0) {                                                \
      ret = OB_ERR_UNEXPECTED;             // 负长度                     \
    } else if (data_len < LEN + pos) {                                   \
      ret = OB_DESERIALIZE_ERROR;          // 数据不完整                  \
    }                                                                    \
  }
```

版本管理策略：
- 每个结构体在 `OB_UNIS_VERSION(V)` 中指定当前版本号
- 序列化时自动编码版本号
- 反序列化时严格校验版本是否匹配
- 当版本升级时，旧版本代码拒绝新版数据（**向前不兼容**）
- 向后兼容：新版本代码可以读取旧版本数据，通过 `deserialize` 在 `deserialize_` 末尾补上默认值

### 2.6 完整使用示例

```cpp
// 头文件声明
// test_res_type_serialization.cpp（doom-lsp symbol 确认）
class ObExprResTypeDeprecated : public ObExprResType
{
  OB_UNIS_VERSION(1);    // 版本号声明+接口声明
public:
  ObExprResTypeDeprecated() : ObExprResType(), ... {}
  // 自定义成员
  ModulePageAllocator inner_alloc_;
  ObFixedArray<ObExprCalcType, ObIAllocator> row_calc_cmp_types_;
};

// .cpp 实现 — 宏展开为 serialize/deserialize/get_serialize_size
OB_SERIALIZE_MEMBER_INHERIT(ObExprResTypeDeprecated,
                             ObObjMeta,
                             accuracy_,
                             calc_accuracy_,
                             calc_type_,
                             res_flags_,
                             row_calc_cmp_types_);
```

`OB_SERIALIZE_MEMBER_INHERIT` 展开后等价于：

```
// serialize：先调用父类 ObObjMeta 的 serialize，
// 然后依次编码其余 5 个成员
int ObExprResTypeDeprecated::serialize(...) {
  ObObjMeta::serialize(buf, buf_len, pos);
  OB_UNIS_ENCODE(accuracy_);
  OB_UNIS_ENCODE(calc_accuracy_);
  OB_UNIS_ENCODE(calc_type_);
  OB_UNIS_ENCODE(res_flags_);
  OB_UNIS_ENCODE(row_calc_cmp_types_);
}

// deserialize：同理
int ObExprResTypeDeprecated::deserialize(...) {
  ObObjMeta::deserialize(buf, data_len, pos);
  OB_UNIS_DECODE(accuracy_);
  // ...
}

// get_serialize_size：累加计算
int64_t ObExprResTypeDeprecated::get_serialize_size() {
  int64_t len = ObObjMeta::get_serialize_size();
  OB_UNIS_ADD_LEN(accuracy_);
  // ...
}
```

### 2.7 EmptyUnisStruct — 序列化的虚基类

```cpp
// ob_unify_serialize.h（第 174-185 行）
struct EmptyUnisStruct
{
  static int serialize(SERIAL_PARAMS) { return 0; }
  static int deserialize(DESERIAL_PARAMS) { return 0; }
  static int64_t get_serialize_size() { return 0; }
};
```

当结构体没有基类时，`EmptyParent` 作为空基类参与继承宏展开，使得 `OB_SERIALIZE_MEMBER` 等价于 `OB_SERIALIZE_MEMBER_INHERIT(CLS, EmptyParent, ...)`。

### 2.8 序列化诊断功能（编译期可选）

```cpp
// ob_unify_serialize.h（第 33-44 行）
// 由 ENABLE_SERIALIZATION_CHECK 编译开关控制
// 在 DEBUG 模式下，记录每个字段的编码长度，与预期对比
enum ObSerializationCheckStatus
{
  CHECK_STATUS_WATING = 0,      // 未激活
  CHECK_STATUS_RECORDING = 1,   // 记录模式：记下每个字段编码后的长度
  CHECK_STATUS_COMPARING = 2    // 比较模式：对比实际长度与记录
};

struct SerializeDiagnoseRecord
{
  uint8_t encoded_lens[MAX_SERIALIZE_RECORD_LENGTH];
  int count = -1;
  int check_index = -1;
  int flag = CHECK_STATUS_WATING;
};

// ob_unify_serialize.h（第 117-140 行）
// 在宏 OB_UNIS_ADD_LEN_IF 中插入诊断代码：
if (IF_NEED_TO_CHECK_SERIALIZATION(obj)) {
  if (CHECK_STATUS_RECORDING == ser_diag_record.flag) {
    ser_diag_record.encoded_lens[count++] = this_len;  // 记录
  } else if (CHECK_STATUS_COMPARING == ser_diag_record.flag) {
    // 比较并输出错误
    if (this_len != record_len) {
      OB_LOG(ERROR, "encoded length not match", ...);
    }
  }
}
```

这个诊断功能用于验证 **get_serialize_size 的准确性**——序列化前先预计大小，序列化后检查实际长度是否匹配。

### 2.9 UNFDummy — 版本兼容的占位符

```cpp
// ob_unify_serialize.h（第 455-457 行）
template <int N>
struct UNFDummy {
  OB_UNIS_VERSION(N);
};
OB_SERIALIZE_MEMBER_TEMP(template<int N>, UNFDummy<N>);
```

当旧版本的某个字段在新版本中被废弃时，使用 `UNFDummy<N>` 占位，N 是版本号。这样旧版本序列化的数据仍然可以正确解码，新版本只需跳过占位字段。

---

## 3. 便利模板 — `ob_serialization_helper.h`

`deps/oblib/src/lib/utility/ob_serialization_helper.h` 定义了 `DefaultItemEncode<T>` 模板，为任意类型提供统一的编码/解码接口。

### 3.1 DefaultItemEncode 的 SFINAE 调度

```cpp
// ob_serialization_helper.h（第 12-65 行）
template <typename T>
struct DefaultItemEncode
{
  static int encode_item(char *buf, const int64_t buf_len, int64_t &pos, const T &item)
  {
    return encode_item_enum(buf, buf_len, pos, item, BoolType<__is_enum(T)>());
  }
  // ...

private:
  // 非枚举类型 → 调用 serialize 方法
  static int encode_item_enum(..., FalseType)
  { return item.serialize(buf, buf_len, pos); }

  // 枚举类型 → 按 int32 编码
  static int encode_item_enum(..., TrueType)
  { return encode_vi32(buf, buf_len, pos, static_cast<int32_t>(item)); }
};
```

### 3.2 基础类型的特化声明

```cpp
// ob_serialization_helper.h（第 97-110 行）
DECLARE_ENCODE_ITEM(int64_t);
DECLARE_ENCODE_ITEM(uint64_t);
DECLARE_ENCODE_ITEM(int32_t);
DECLARE_ENCODE_ITEM(uint32_t);
DECLARE_ENCODE_ITEM(int16_t);
DECLARE_ENCODE_ITEM(int8_t);
DECLARE_ENCODE_ITEM(bool);
DECLARE_ENCODE_ITEM(double);
```

这些使用 `DECLARE_ENCODE_ITEM` 宏声明了特化模板，对应的实现定义在 `.cpp` 文件中。

### 3.3 定长字符数组的模板

```cpp
// ob_serialization_helper.h（第 113-140 行）
template<int64_t SIZE>
int encode_item(char *buf, const int64_t buf_len, int64_t &pos, const char(&item)[SIZE])
{
  return serialization::encode_vstr(buf, buf_len, pos, item);
}
```

定长字符数组（如 `char name[64]`）通过 `encode_vstr` 编码为变长字符串，反序列化时通过 `decode_vstr` 还原。

---

## 4. Meta 序列化 — `ob_meta_serialization.h`

### 4.1 文件定位

`deps/oblib/src/common/meta_programming/ob_meta_serialization.h`（40 行）是 OceanBase MDS（Multi-Data Source）模块的一部分。它是 meta 编程框架中的组件级序列化封装。

### 4.2 MetaSerializer — 编译期序列化包装器

```cpp
// ob_meta_serialization.h（第 18-40 行）
template <typename T>
class MetaSerializer
{
public:
  MetaSerializer(ObIAllocator &alloc, const T &data)
    : alloc_(alloc), data_(const_cast<T &>(data)) {}

  int serialize(char *buf, const int64_t buf_len, int64_t &pos) const
  { return data_.serialize(buf, buf_len, pos); }

  // SFINAE 选择反序列化路径
  template <typename T2 = T,
            typename std::enable_if<OB_TRAIT_SERIALIZEABLE(T2), bool>::type = true>
  int deserialize(const char *buf, const int64_t buf_len, int64_t &pos)
  { return data_.deserialize(buf, buf_len, pos); }  // 普通序列化

  template <typename T2 = T,
            typename std::enable_if<!OB_TRAIT_SERIALIZEABLE(T2) &&
                                    OB_TRAIT_DEEP_SERIALIZEABLE(T2), bool>::type = true>
  int deserialize(const char *buf, const int64_t buf_len, int64_t &pos)
  { return data_.deserialize(alloc_, buf, buf_len, pos); }  // 深序列化（需要 Allocator）

  int64_t get_serialize_size() const { return data_.get_serizalize_size(); }
  //                                                         ↑ 注意拼写 bug！
};
```

### 4.3 特性检测宏

在 `ob_type_traits.h` 中定义的 SFINAE 特性：

```cpp
// ob_type_traits.h（第 171 行）
#define OB_TRAIT_SERIALIZEABLE(CLASS) \
(has_serialize<CLASS, int(char*, const int64_t, int64_t &)>::value &&  \
 has_deserialize<CLASS, int(const char*, const int64_t, int64_t &)>::value &&  \
 has_get_serialize_size<CLASS, int64_t()>::value)

#define OB_TRAIT_DEEP_SERIALIZEABLE(CLASS) \
(has_serialize<CLASS, int(char*, const int64_t, int64_t &)>::value &&  \
 has_deserialize<CLASS, int(ObIAllocator &, const char*, const int64_t, int64_t &)>::value &&  \
 has_get_serialize_size<CLASS, int64_t()>::value)
```

区别：
- **Serializeable**：反序列化只需要 `buf / data_len / pos`（已经分配好内存）
- **Deep Serializeable**：反序列化还需要 `ObIAllocator &`（需要从 Allocator 分配内存）

### 4.4 注册函数特征宏

```cpp
// ob_type_traits.h（第 21-35 行）
#define REGISTER_FUNCTION_TRAIT(function_name) \
template<typename, typename> \
struct has_##function_name {};
// 展开为三个特征的检测：
REGISTER_FUNCTION_TRAIT(serialize);           // → has_serialize
REGISTER_FUNCTION_TRAIT(deserialize);         // → has_deserialize
REGISTER_FUNCTION_TRAIT(get_serialize_size);  // → has_get_serialize_size
REGISTER_FUNCTION_TRAIT(mds_serialize);       // → has_mds_serialize（MDS 专用）
```

每个 `has_*` 结构体使用 **SFINAE + decltype** 在编译期检测类型是否具有指定签名的方法。

### 4.5 MetaSerializer 的作用

`MetaSerializer` 解决了一个实际问题：**某些类型的序列化需要分配器，某些不需要**。通过编译期特性检测，自动选择正确的反序列化路径：

```
          ┌─────────────────────────────┐
          │   T::deserialize(buf, len, pos)         │ ← 普通类型
          │      (已有预分配内存)                     │
          │                             │
T → 是否   │                     或                          │
   是       │   T::deserialize(alloc, buf, len, pos) │ ← 深类型
   类？    │      (需要在堆上分配内存)                   │
          └─────────────────────────────┘
```

**注意**：`MetaSerializer::get_serialize_size()` 中存在拼写错误 `get_serizalize_size()`（缺少 'i'），这是源码中的实际写法。

---

## 5. Hash 序列化 — `ob_serialization.h`

### 5.1 文件定位

`deps/oblib/src/lib/hash/ob_serialization.h` 提供与 `SimpleArchive` 文件包装器配合的序列化/反序列化接口，主要用于 Hash 索引的持久化。

### 5.2 SimpleArchive

```cpp
// ob_serialization.h（第 36-100 行）
class SimpleArchive
{
public:
  int init(const char *filename, int flag);  // 打开文件
  void destroy();                              // 关闭文件
  int push(const void *data, int64_t size);   // 写入（对应 serialize）
  int pop(void *data, int64_t size);          // 读取（对应 deserialize）

  static const int FILE_OPEN_RFLAG = O_CREAT | O_RDONLY;
  static const int FILE_OPEN_WFLAG = O_CREAT | O_TRUNC | O_WRONLY;

private:
  int fd_;  // 文件描述符
};
```

这是一个极其简单的文件序列化包装器——`push` 调用 `write()`，`pop` 调用 `read()`，没有任何缓冲、校验和或版本管理。

### 5.3 基础类型的宏特化

```cpp
// ob_serialization.h（第 107-126 行）
#define _SERIALIZATION_SPEC(type) \
  template <class _archive> \
  int serialization(_archive &ar, type &value) \
  { return ar.push(&value, sizeof(value)); }  // 直接二进制盲拷贝！

#define _DESERIALIZATION_SPEC(type) \
  template <class _archive> \
  int deserialization(_archive &ar, type &value) \
  { return ar.pop(&value, sizeof(value)); }  // 直接二进制盲拷贝！

_SERIALIZATION_SPEC(int8_t);
_SERIALIZATION_SPEC(int16_t);
_SERIALIZATION_SPEC(int32_t);
_SERIALIZATION_SPEC(int64_t);
_SERIALIZATION_SPEC(float);
_SERIALIZATION_SPEC(double);
// ... 以及 const 版本
```

**注意**：这是纯二进制盲拷贝，**没有字节序转换**，因此不是跨平台兼容的。这与 `serialization.h` 使用大端序形成鲜明对比。这个模块仅在单机场景下用于 Hash 表持久化。

### 5.4 HashMapPair 序列化

```cpp
// ob_serialization.h（第 153-167 行）
template <class _archive, typename _T1, typename _T2>
int serialization(_archive &ar, const HashMapPair<_T1, _T2> &pair)
{
  return serialization(ar, pair.first) || serialization(ar, pair.second);
}
```

递归调用 pair 中两个成员的序列化。

---

## 6. 序列化格式对比

| 格式 | 基础编码 | 字节序 | 版本管理 | 跨平台 | 适用场景 |
|------|---------|--------|---------|--------|---------|
| `serialization.h` varint | 变长 LE | 小端 | 无 | 是 | RPC、持久化 |
| `serialization.h` 定长 | 定长 BE | 大端 | 无 | 是 | 固定大小字段 |
| `OB_UNIS` | varint + 5-byte 长度 | 小端 | 有（版本校验） | 是 | 结构化对象序列化 |
| `ob_serialization.h` (Hash) | 盲拷贝 | 平台相关 | 无 | 否 | Hash 持久化 |

---

## 7. 设计决策分析

### 7.1 为什么自研序列化而非 protobuf / flatbuffers？

| 对比点 | OB_UNIS | protobuf | flatbuffers |
|--------|---------|----------|-------------|
| **代码生成** | 宏展开（零外部工具） | `protoc` 生成代码 | `flatc` 生成代码 |
| **运行时反射** | 无 | 有（`descriptor`） | 无 |
| **版本兼容** | 严格校验版本号 | 自动向前/向后兼容 | 字段编号 + 版本 |
| **性能** | 内联函数，零开销 | 有反射查找开销 | 零反序列化 |
| **C 可调用** | 是（模板外的基础编码） | 否（C++ 代码） | C 接口 + C++ 生成 |
| **依赖** | 无外部依赖 | 需要 protobuf 库 | 需要 flatbuffers |
| **大小** | ~200 行宏定义 | 完整的 protoc + runtime | 代码生成 + 链接 |

**核心原因**：
1. **构建简化**：不需要 `protoc` / `flatc` 代码生成步骤，宏在 `gcc` 预处理阶段完成
2. **C 兼容**：基础编码层是 pure C inline 函数，pnio（纯 C 实现）可以直接链接
3. **零反射性能**：OceanBase 的内核路径是微秒级延迟敏感，protobuf 的反射查找不可接受
4. **深度定制**：可以针对 OceanBase 的数据特征设计编码（如 `fast_encode` 对 0-23 值的 1 字节编码）

### 7.2 TLV 格式的优缺点

**优点**：
- 结构简单，易于实现
- 每个字段顺序编码，无须字段编号
- 编码紧凑，无冗余描述信息

**缺点**：
- **无字段编号**：不能跳过未知字段 → 版本必须完全匹配
- **顺序强依赖**：字段顺序改变破坏兼容性
- **无自描述**：不能从二进制流推断含义

OceanBase 通过**版本号校验 + 代码生成**规避了这些缺点——版本号保证了数据格式已知，宏展开保证了字段顺序与声明一致。

### 7.3 Varint 编码的选择

**为什么 varint 而非定长？**

- RPC 消息中大量小整数（命令码、状态码、长度等） → varint 平均 1-2 字节
- 日志序列 ID、时间戳适合变长编码
- 相比定长 8 字节编码，varint 可节省 50-80% 的整数编码空间

**varint 的代价**：CPU 开销略高于定长编码（移位 + 分支）。OceanBase 在确认缓存充足时使用 `int encode()` 直接编码以求更快，而非总是使用安全检查版本。

### 7.4 序列化性能优化

关键性能设计：

1. **内联函数**：`serialization.h` 的所有 encode/decode 函数都是 `inline`，无函数调用开销
2. **预计算大小**：`get_serialize_size()` 先计算准确大小，然后一次性分配缓冲区
3. **缓冲区预留**：`serialize()` 的 `size_nbytes` 回写机制避免了二次分配
4. **零拷贝解码**：`decode_vstr` 返回 `buf` 中的指针而非拷贝，字符串解码零开销
5. **安全检查分级**：`encode_int` 有快路径 `fast_encode`（不检查边界）和慢路径 `encode_int_safe`（检查边界），根据剩余空间动态选择
6. **模板特化避免分支**：`encode_vi32` vs `encode_i32`，编译期选择而非运行时 `if`

### 7.5 版本兼容策略

当前的 OB_UNIS 策略是**严格匹配**：

```
序列化端: 写入 UNIS_VERSION
反序列化端: 校验 version == UNIS_VERSION
                → 不匹配则返回 OB_NOT_SUPPORTED
```

这意味着：
- 节点升级时，如果结构体版本变化，**必须所有节点同步升级**
- **向后兼容**：新版本程序可以手动处理旧版本数据（通过在 `deserialize` 中加特殊逻辑）
- **向前兼容**：默认不支持。但可以通过 `OB_SERIALIZE_MEMBER_IF` 和 `PRED` 条件来控制字段级兼容

### 7.6 Deep Serialization vs Normal Serialization

```
Normal Serialization:
  deserialize(buf, data_len, pos)
  → 数据已从 buf 拷贝到预分配的对象

Deep Serialization:
  deserialize(alloc, buf, data_len, pos)
  → 用 alloc 在堆上分配反序列化所需的内存
  → 适用于大小不固定的字段（如变长字符串、变长数组）
```

---

## 8. 测试与兼容性验证

OceanBase 中包含一组序列化兼容性测试：

| 测试文件 | 测试内容 |
|---------|---------|
| `test_backup_compatible.cpp` | 备份兼容性 |
| `test_expr_serialize_compat.cpp` | 表达式序列化兼容性 |
| `test_table_scan_ctdef_serialize_compat.cpp` | TableScan CTDef 兼容性 |
| `test_physical_plan_ctx_serialize_compat.cpp` | 执行计划上下文兼容性 |
| `test_ob_election_message_compat*.cpp` | 选举消息兼容性 |
| `test_dtl_linked_buffer_serialize_compat.cpp` | DTL 缓冲区兼容性 |

这些测试通过声明一个旧的 `OB_UNIS_VERSION(1)` 类和一个新的 `OB_UNIS_VERSION(2)` 类，验证：

1. 旧版本序列化的数据能否被新版本反序列化
2. 新版本序列化的数据是否被旧版本正确拒绝
3. 序列化/反序列化往返一致性

```cpp
// test_expr_serialize_compat.cpp（doom-lsp symbol 确认）
class ObExprCalcTypeDeprecated { OB_UNIS_VERSION(1); /* ... */ };
class ObExprCalcTypeNew         { OB_UNIS_VERSION(2); /* ... */ };
// 验证 V1 ↔ V2 的序列化兼容性
```

---

## 9. 源码索引

### 序列化框架核心

| 文件 | 行数 | 关键内容 |
|------|------|---------|
| `deps/oblib/src/lib/utility/serialization.h` | ~1700 | 基础编码原语：varint、定长、字符串、浮点、时间、Decimal |
| `deps/oblib/src/lib/utility/ob_unify_serialize.h` | 478 | OB_UNIS 宏体系：声明宏、实现宏、成员序列化宏 |
| `deps/oblib/src/lib/utility/ob_unify_serialize.cpp` | 30 | 序列化诊断（ENABLE_SERIALIZATION_CHECK 编译开关） |
| `deps/oblib/src/lib/utility/ob_serialization_helper.h` | 140 | DefaultItemEncode 便利模板 |
| `deps/oblib/src/common/meta_programming/ob_meta_serialization.h` | 40 | MetaSerializer 编译期序列化包装器 |
| `deps/oblib/src/common/meta_programming/ob_type_traits.h` | 400+ | SFINAE 特征检测宏 |
| `deps/oblib/src/common/meta_programming/ob_meta_define.h` | 28 | DummyAllocator 缺省分配器 |
| `deps/oblib/src/lib/hash/ob_serialization.h` | 170 | Hash 序列化 + SimpleArchive 文件包装器 |

### 代码生成宏

| 宏 | 行号 | 作用 |
|----|------|------|
| `OB_UNIS_VERSION(V)` | 323 | 声明序列化版本和接口 |
| `OB_DECLARE_UNIS` | 308 | 展开 serialize/deserialize/size 声明 |
| `OB_SERIALIZE_MEMBER` | 378 | 自动生成成员序列化 |
| `OB_SERIALIZE_MEMBER_INHERIT` | 200 | 继承父类 + 成员序列化 |
| `OB_SERIALIZE_MEMBER_IF` | 460 | 条件成员序列化 |
| `OB_DEF_SERIALIZE` | 332 | 手动定义 serialize 实现 |
| `OB_DEF_DESERIALIZE` | 336 | 手动定义 deserialize 实现 |
| `OB_DEF_SERIALIZE_SIZE` | 340 | 手动定义 size 实现 |
| `OB_UNIS_SERIALIZE` | 232 | 内部 serialize 宏（版本头 + payload 回写） |
| `OB_UNIS_DESERIALIZE` | 258 | 内部 deserialize 宏（版本校验 + 子缓冲区） |
| `OB_UNIS_SERIALIZE_SIZE` | 277 | 内部 size 宏 |

### 编码原语

| 函数 | 行号 | 作用 |
|------|------|------|
| `encode_vi64 / decode_vi64` | 387/441 | 64bit varint 编码 |
| `encode_vi32 / decode_vi32` | 510/524 | 32bit varint 编码 |
| `encode_fixed_bytes_i64` | 425 | 5-byte 定长 varint |
| `encode_i64 / decode_i64` | 165/188 | 64bit 定长大端序 |
| `encode_i32 / decode_i32` | 130/147 | 32bit 定长大端序 |
| `encode_vstr / decode_vstr` | 639/668 | 变长字符串 |
| `encode_str / decode_str` | 788/807 | 紧凑类型字符串 |
| `encode_float / decode_float` | 554/566 | float → varint |
| `encode_double / decode_double` | 578/590 | double → varint64 |
| `fast_encode / fast_decode` | 890/948 | 带符号整数紧凑编码 |

### 类型标记

| 常量 | 值 | 含义 |
|------|-----|------|
| `OB_VARCHAR_TYPE` | 0x80 | 变长字符串 |
| `OB_DATETIME_TYPE` | 0xd0 | 日期时间 |
| `OB_PRECISE_DATETIME_TYPE` | 0xe0 | 精确日期时间 |
| `OB_FLOAT_TYPE` | 0xf8 | 浮点数 |
| `OB_DOUBLE_TYPE` | 0xfa | 双精度浮点数 |
| `OB_NULL_TYPE` | 0xfc | 空值 |
| `OB_BOOL_TYPE` | 0xfd | 布尔 |
| `OB_EXTEND_TYPE` | 0xfe | 扩展类型 |
| `OB_DECIMAL_TYPE` | 0xff | Decimal/NUMBER |

### 测试文件

| 文件 | 行数 | 测试内容 |
|------|------|---------|
| `unittest/sql/engine/expr/test_expr_serialize_compat.cpp` | ~100 | 表达式序列化兼容性 |
| `unittest/sql/dtl/test_dtl_linked_buffer_serialize_compat.cpp` | ~80 | DTL 缓冲区兼容性 |
| `unittest/storage/backup/test_backup_compatible.cpp` | ~100 | 备份兼容性 |
| `unittest/sql/engine/test_physical_plan_ctx_serialize_compat.cpp` | ~80 | 执行计划上下文 |
| `unittest/sql/engine/table/test_table_scan_ctdef_serialize_compat.cpp` | ~80 | TableScan CTDef |
| `unittest/sql/resolver/expr/test_res_type_serialization.cpp` | ~100 | 类型序列化 |
| `unittest/storage/tx/test_ob_id_meta.cpp` | ~80 | 事务 ID Meta |
| `unittest/storage/tx/test_ob_tx_log.cpp` | ~150 | 事务日志 |
| `unittest/logservice/test_ob_election_message_compat*.cpp` | ~600 | 选举消息兼容性 |

---

## 总结

OceanBase 的序列化框架是一个**深度自研、编译期代码生成、跨层统一**的序列化体系：

1. **`serialization.h`** 是基石，提供了 varint、定长整数、浮点、字符串、时间等所有基础类型的编码原语，所有上层序列化都基于它
2. **`ob_unify_serialize.h`** 的 OB_UNIS 宏体系是核心，通过编译期宏展开自动生成 `serialize/deserialize/size` 三件套，零运行时开销，版本号统一管理
3. **`ob_meta_serialization.h`** 提供了编译期 SFINAE 动态选择反序列化路径的能力，区分普通序列化和深序列化
4. **`ob_serialization_helper.h`** 提供了便利模板，统一了枚举和非枚举类型的编码接口
5. **`ob_serialization.h` (Hash)** 是特殊情况，使用纯二进制盲拷贝适用于单机 Hash 持久化

与通用方案（protobuf、flatbuffers）相比，OB_UNIS 的核心优势在于**零依赖、零反射、C 兼容、极简构建**，但代价是版本兼容策略较为严格——依赖版本号匹配而非字段编号的"未知字段跳过"机制。
