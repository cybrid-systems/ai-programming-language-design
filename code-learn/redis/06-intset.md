# 06 — IntSet：全整数集合的紧凑编码

> Redis 主线源码深度分析系列 · 第六篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前几篇依次拆解了 SDS（字符串）、dict（哈希表）、listpack 与 quicklist（紧凑列表）、skip list（跳表）。Set（集合）类型还有自己的紧凑编码——**IntSet（整数集合）**。

IntSet 是 Set 在**全整数且数量有限**时的专用编码。它只有 547 行（`src/intset.c` + `src/intset.h`），是 Redis 中最小巧的数据结构之一。

核心思路：**排序数组 + 二分查找 + 按需升级（upgrade）**。

当 Set 中所有元素都是整数时，用 `int16_t` / `int32_t` / `int64_t` 中最紧凑的一种来存储有序数组。插入新值时如果超出当前类型的范围，**自动升级编码**并把所有现有元素转换为更大的整数类型。

**doom-lsp 确认**：核心文件

| 文件 | 行数 | 职责 |
|------|:----:|------|
| `src/intset.h` | 55 | intset 结构体定义 + API |
| `src/intset.c` | 547 | 全部实现（升迁、插入、删除、查找、随机采样） |
| `src/t_set.c` | 1150+ | Set 命令 + 编码切换逻辑 |

---

## 1. 数据结构——IntSet

```c
// intset.h:30-34 — doom-lsp 确认
typedef struct intset {
    uint32_t encoding;   // 编码方式：INTSET_ENC_INT16 / INT32 / INT64
    uint32_t length;     // 元素数量
    int8_t contents[];   // 柔性数组：有序的整型数组
} intset;
```

**4 字节 header（big-endian）+ 4 字节长度 + 紧凑的有序数组**，总共只有 8 字节开销。

三种编码通过 encoding 字段值区分：

```c
// intset.c:39-41 — doom-lsp 确认
#define INTSET_ENC_INT16 (sizeof(int16_t))  // = 2
#define INTSET_ENC_INT32 (sizeof(int32_t))  // = 4
#define INTSET_ENC_INT64 (sizeof(int64_t))  // = 8
```

编码选择规则：

```c
// intset.c:44-50 — doom-lsp 确认
static uint8_t _intsetValueEncoding(int64_t v) {
    if (v < INT32_MIN || v > INT32_MAX)     // [-2^31, 2^31) 之外
        return INTSET_ENC_INT64;             // → 64 位
    else if (v < INT16_MIN || v > INT16_MAX) // [-32768, 32767] 之外
        return INTSET_ENC_INT32;             // → 32 位
    else
        return INTSET_ENC_INT16;             // → 16 位
}
```

**内存布局示例**（INTSET_ENC_INT16，3 个元素）：

```
┌──────────┬──────────┬──────┬──────┬──────┐
│ encoding │ length   │  -3  │  42  │  99  │
│ = 2      │ = 3      │      │      │      │
│ (4B BE)  │ (4B LE)  │ 2B   │ 2B   │ 2B   │
└──────────┴──────────┴──────┴──────┴──────┘
               total = 8 + 3 × 2 = 14 字节
```

同样的 3 个整数，用 dict（HT 编码）至少需要 3 × 24 字节 dict entry + 3 个 SDS header + 链表指针 ≈ 150+ 字节。IntSet 只有 14 字节，**内存效率是天差地别**。

---

## 2. 二分查找——intsetSearch

```c
// intset.c:103-139 — doom-lsp 确认
static uint8_t intsetSearch(intset *is, int64_t value, uint32_t *pos) {
    int min = 0, max = intrev32ifbe(is->length) - 1, mid = -1;
    int64_t cur = -1;

    // 空集合
    if (intrev32ifbe(is->length) == 0) {
        if (pos) *pos = 0;
        return 0;
    }

    // 快速边界检查：比最大还大 → 插末尾；比最小还小 → 插开头
    if (value > _intsetGet(is, max)) {
        if (pos) *pos = intrev32ifbe(is->length);
        return 0;
    } else if (value < _intsetGet(is, 0)) {
        if (pos) *pos = 0;
        return 0;
    }

    // 标准二分查找
    while (max >= min) {
        mid = ((unsigned int)min + (unsigned int)max) >> 1;
        cur = _intsetGet(is, mid);
        if (value > cur) {
            min = mid + 1;
        } else if (value < cur) {
            max = mid - 1;
        } else {
            break;  // 找到
        }
    }

    if (value == cur) {
        if (pos) *pos = mid;
        return 1;   // 已存在
    } else {
        if (pos) *pos = min;
        return 0;   // 不存在，pos 指向插入位置
    }
}
```

**设计要点**：

1. **快速边界检查**：如果 value 超出最大或最小值，直接确定插入位置（末尾或开头），跳过二分查找。这利用了 IntSet 有序数组的性质。`SADD` 连续添加递增序列时每次都走这个快速路径。

2. **`mid = (min + max) >> 1`**：无分支溢出保护的写法。

3. **找不到时的 `*pos = min`**：插入位置正好是 `min` 指向的位置（第一个大于 value 的元素），省去额外的计算。

**intsetSearch 的时间复杂度** = O(log N)。对于 IntSet 默认的 512 个元素上限，最多 9 次比较即可定位。

---

## 3. 元素读取与写入

### 3.1 _intsetGet——读指定位置

```c
// intset.c:53-68 — doom-lsp 确认
static int64_t _intsetGetEncoded(intset *is, int pos, uint8_t enc) {
    int64_t v64;
    int32_t v32;
    int16_t v16;

    if (enc == INTSET_ENC_INT64) {
        memcpy(&v64, ((int64_t*)is->contents) + pos, sizeof(v64));
        memrev64ifbe(&v64);
        return v64;
    } else if (enc == INTSET_ENC_INT32) {
        memcpy(&v32, ((int32_t*)is->contents) + pos, sizeof(v32));
        memrev32ifbe(&v32);
        return v32;
    } else {
        memcpy(&v16, ((int16_t*)is->contents) + pos, sizeof(v16));
        memrev16ifbe(&v16);
        return v16;
    }
}

static int64_t _intsetGet(intset *is, int pos) {
    return _intsetGetEncoded(is, pos, intrev32ifbe(is->encoding));
}
```

`_intsetGet` 根据当前的 `encoding` 从 `is->contents` 指定位置读取相应大小的整数。所有值在网络存储中统一为 big-endian，所以读取时调用 `memrev*ifbe` 做大小端转换——在小端 CPU 上反转，大端 CPU 上无操作。

### 3.2 _intsetSet——写入指定位置

```c
// intset.c:71-83 — doom-lsp 确认
static void _intsetSet(intset *is, int pos, int64_t value) {
    uint32_t encoding = intrev32ifbe(is->encoding);

    if (encoding == INTSET_ENC_INT64) {
        ((int64_t*)is->contents)[pos] = value;
        memrev64ifbe(((int64_t*)is->contents) + pos);
    } else if (encoding == INTSET_ENC_INT32) {
        ((int32_t*)is->contents)[pos] = value;
        memrev32ifbe(((int32_t*)is->contents) + pos);
    } else {
        ((int16_t*)is->contents)[pos] = value;
        memrev16ifbe(((int16_t*)is->contents) + pos);
    }
}
```

写入后立即 `memrev*ifbe` 转为 big-endian。这样 IntSet 在序列化（RDB/AOF）时不需要额外转换——已经是磁盘格式。

---

## 4. 插入——intsetAdd

```c
// intset.c:216-235 — doom-lsp 确认
intset *intsetAdd(intset *is, int64_t value, uint8_t *success) {
    uint8_t valenc = _intsetValueEncoding(value);
    uint32_t pos;
    if (success) *success = 1;

    // 分支 1：需要升级编码
    if (valenc > intrev32ifbe(is->encoding)) {
        return intsetUpgradeAndAdd(is, value);
    }
    // 分支 2：编码够用，检查是否已存在
    else {
        if (intsetSearch(is, value, &pos)) {
            if (success) *success = 0;   // 已存在，什么都不做
            return is;
        }

        // 扩容 + 后移腾出位置
        is = intsetResize(is, intrev32ifbe(is->length) + 1);
        if (pos < intrev32ifbe(is->length))
            intsetMoveTail(is, pos, pos + 1);
    }

    // 写入值 + 更新 length
    _intsetSet(is, pos, value);
    is->length = intrev32ifbe(intrev32ifbe(is->length) + 1);
    return is;
}
```

### 4.1 升级——intsetUpgradeAndAdd

当新值超出当前编码的范围时（如 INT16 → INT32），需要升级：

```c
// intset.c:142-170 — doom-lsp 确认
static intset *intsetUpgradeAndAdd(intset *is, int64_t value) {
    uint8_t curenc = intrev32ifbe(is->encoding);  // 旧编码
    uint8_t newenc = _intsetValueEncoding(value);  // 新编码
    int length = intrev32ifbe(is->length);
    int prepend = value < 0 ? 1 : 0;               // 负数 → 插开头，正数 → 插末尾

    // 1. 设置新编码 + 扩容（+1 为新值留位）
    is->encoding = intrev32ifbe(newenc);
    is = intsetResize(is, intrev32ifbe(is->length) + 1);

    // 2. 从后往前逐元素升级（避免覆盖未读数据）
    while (length--)
        _intsetSet(is, length + prepend,
                   _intsetGetEncoded(is, length, curenc));

    // 3. 在开头或末尾设置新值
    if (prepend)
        _intsetSet(is, 0, value);
    else
        _intsetSet(is, intrev32ifbe(is->length), value);

    is->length = intrev32ifbe(intrev32ifbe(is->length) + 1);
    return is;
}
```

**升级过程图解**（INTSET_ENC_INT16 含 3 个元素，新加 `65536`）：

```
升级前（INT16，小端值表示）：
  contents: [ -3, 42, 99 ]
  每个元素 2 字节，总数据 6 字节

新值 65536 需要 INT32 编码

扩容后（INT32，8 + 4 = 12 字节数据空间）：
  contents: [ ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? ]

从后往前升级（length--）：
  位置 2 (旧 99  → 位置 3): [ ?, ?, ?, ?, 99, 0, 0, 0, ?, ?, ?, ? ]
  位置 1 (旧 42  → 位置 2): [ ?, ?, ?, ?, 99, 0, 0, 0, 42, 0, 0, 0, ?, ?, ?, ? ]
  位置 0 (旧 -3  → 位置 1?):
    prepend=0（正数）→ 位置 1
    [ -3, 0, 0, 0, 42, 0, 0, 0, 99, 0, 0, 0 ]

  最后在末尾写入新值 65536：
  [ -3, 0, 0, 0, 42, 0, 0, 0, 99, 0, 0, 0, 65536, 0, 0, 0]
```

**`prepend` 优化**：负数一定小于所有正数，所以新值如果是负数，一定插入到开头（prepend=1）；如果是正数，一定在末尾（prepend=0）。升级时从后往前遍历旧元素，每个在偏移 `prepend` 的位置写入新格式。

**为什么不降级**？如果所有 INT64 的值都被删除到只有 INT16 的范围，IntSet 不会回退编码。注释在 intset.c 中没有显式说明，但这与 ziplist 的 prevlen 不回缩同样的原则：**编码只升不降，避免"摆动"效应**。

---

## 5. 删除——intsetRemove

```c
// intset.c:238-254 — doom-lsp 确认
intset *intsetRemove(intset *is, int64_t value, int *success) {
    uint8_t valenc = _intsetValueEncoding(value);
    uint32_t pos;
    if (success) *success = 0;

    if (valenc <= intrev32ifbe(is->encoding) && intsetSearch(is, value, &pos)) {
        uint32_t len = intrev32ifbe(is->length);

        if (success) *success = 1;

        // 覆盖被删除元素：把后面的元素前移
        if (pos < (len - 1)) intsetMoveTail(is, pos + 1, pos);
        // 缩容
        is = intsetResize(is, len - 1);
        is->length = intrev32ifbe(len - 1);
    }
    return is;
}
```

`intsetMoveTail`（intset.c:173-199）使用 `memmove` 将删除位置之后的元素整体前移一个位置：

```c
static void intsetMoveTail(intset *is, uint32_t from, uint32_t to) {
    void *src, *dst;
    uint32_t bytes = intrev32ifbe(is->length) - from;
    uint32_t encoding = intrev32ifbe(is->encoding);

    // 按 encoding 计算字节数
    if (encoding == INTSET_ENC_INT64) {
        src = (int64_t*)is->contents + from;
        dst = (int64_t*)is->contents + to;
        bytes *= sizeof(int64_t);
    } else if (encoding == INTSET_ENC_INT32) {
        // ...
    } else {
        src = (int16_t*)is->contents + from;
        dst = (int16_t*)is->contents + to;
        bytes *= sizeof(int16_t);
    }
    memmove(dst, src, bytes);
}
```

`memmove` 处理源和目标可能重叠的情况（from < to 时是从前向后拷贝，from > to 时是向后向前）。

**删除后编码不变（不降级）**：即使删除了所有 INT64 的值，IntSet 也不会降级到 INT32。这条限制使得 IntSet 的编码转换只在升级方向单向进行，简化了实现。

---

## 6. 其他操作

### 6.1 intsetFind——判断成员

```c
// intset.c:258-263 — doom-lsp 确认
uint8_t intsetFind(intset *is, int64_t value) {
    uint8_t valenc = _intsetValueEncoding(value);
    return valenc <= intrev32ifbe(is->encoding) && intsetSearch(is, value, NULL);
}
```

先检查编码是否兼容——如果 value 的编码大于当前 encoding，说明这个值肯定不在集合中（因为任何已存在的值都不会超出当前 encoding 的范围）。这个快速检查避免了不必要的二分查找。

### 6.2 intsetRandom——随机采样

```c
// intset.c:266-271 — doom-lsp 确认
int64_t intsetRandom(intset *is) {
    uint32_t len = intrev32ifbe(is->length);
    assert(len);
    return _intsetGet(is, rand() % len);
}
```

用于 `SRANDMEMBER`。因为是连续数组，O(1) 即可随机访问任意元素（与 dictGetRandomKey 相比，无需处理碰撞链和空桶跳过）。

### 6.3 intsetGet——按位置索引

```c
// intset.c:274-280 — doom-lsp 确认
uint8_t intsetGet(intset *is, uint32_t pos, int64_t *value) {
    if (pos < intrev32ifbe(is->length)) {
        *value = _intsetGet(is, pos);
        return 1;
    }
    return 0;
}
```

用于 `SMISMEMBER` 等内部操作。O(1) 的随机访问。

---

## 7. Set 编码切换——intset ↔ dict

### 7.1 创建

```c
// t_set.c:41-48 — doom-lsp 确认
robj *setTypeCreate(sds value) {
    // 值可以表示为 long long → intset
    if (isSdsRepresentableAsLongLong(value, NULL) == C_OK)
        return createIntsetObject();          // intset 编码
    // 否则直接用 dict
    return createSetObject();                 // HT 编码
}
```

### 7.2 插入时自动转换——setTypeAdd

```c
// t_set.c:53-97 — doom-lsp 确认
int setTypeAdd(robj *subject, sds value) {
    if (subject->encoding == OBJ_ENCODING_INTSET) {
        if (isSdsRepresentableAsLongLong(value, &llval) == C_OK) {
            // 整数 → 插入 intset
            subject->ptr = intsetAdd(subject->ptr, llval, &success);
            if (success) {
                // ★ intset 元素太多 → 转为 dict
                if (intsetLen(subject->ptr) > server.set_max_intset_entries)
                    setTypeConvert(subject, OBJ_ENCODING_HT);
            }
        } else {
            // ★ 不是整数 → 立刻转为 dict
            setTypeConvert(subject, OBJ_ENCODING_HT);
            hashtableAdd(subject->ptr, sdsdup(value));
        }
    }
    // ...
}
```

**两种触发转换的条件**：

1. **元素超限**：`set_max_intset_entries`（默认 512，`config.c:3123`）。intset 的元素数超过这个值 → 转为 HT 编码。
2. **非整数元素**：插入的不是整数 → 无法用 intset 表示 → 立即转为 HT 编码。

### 7.3 转换——setTypeConvert

```c
// t_set.c:239-254 — doom-lsp 确认
void setTypeConvert(robj *setobj, int enc) {
    if (enc == OBJ_ENCODING_HT) {
        int64_t intele;
        hashtable *d = hashtableCreate(&setHashtableType);

        // 预分配：避免逐元素插入时多次 rehash
        hashtableExpand(d, intsetLen(setobj->ptr));

        // 遍历 intset，逐个转为 sds + 插入 hashtable
        si = setTypeInitIterator(setobj);
        while (setTypeNext(si, &element, &intele) != -1) {
            element = sdsfromlonglong(intele);
            hashtableAdd(d, element);
        }
        setTypeReleaseIterator(si);

        setobj->encoding = OBJ_ENCODING_HT;
        zfree(setobj->ptr);
        setobj->ptr = d;
    }
}
```

**反向转换不存在**：一旦转为 HT，就不再转回 intset。这与 ZSet 不同——ZSet 在元素减少时可以用 `zsetConvertToListpackIfNeeded` 反向转换为 listpack。Set 没有这个机制。

---

## 8. 性能特征

### 8.1 复杂度矩阵

| 操作 | IntSet | Dict (HT) |
|------|:------:|:---------:|
| SADD | O(log N) + O(N) memmove | O(1) 均摊 |
| SREM | O(log N) + O(N) memmove | O(1) + lazyfree |
| SISMEMBER | O(log N) | O(1) |
| SCARD | O(1) | O(1) |
| SRANDMEMBER | O(1) | O(1) ~ O(N) |
| SMEMBERS | O(N) | O(N) |
| 内存（100 个 int） | 8 + 100×2~8 ≈ 208~808 字节 | > 100×64 ≈ 6400+ 字节 |

### 8.2 IntSet 的优缺点

**优点**：
| 维度 | 说明 |
|------|------|
| **内存密集** | 8 字节开销 | 3 字节/元素（INT16）起 | 无指针间接 |
| **Cache 友好** | 连续内存，顺序遍历时预取效果好 |
| **序列化简单** | 已经是 big-endian 格式，直接写入 RDB/AOF |
| **随机采样快** | 数组随机访问 O(1)，无空桶跳过 |

**缺点**：
| 维度 | 说明 |
|------|------|
| **插入/删除 O(N)** | 插入需要 memmove 移动元素，删除同理 |
| **查找 O(log N)** | 二分查找虽快，但不及哈希表 O(1) |
| **仅限整数** | 字符串 / 浮点数 / 非整数 long long 无法使用 |
| **只升不降** | 编码不降级，删除大量大数后不回收空间 |
| **上限 512** | 默认 `set_max_intset_entries` = 512，超过即淘汰 |

### 8.3 典型应用场景

- 小集合的**用户 ID**、**标签 ID** 存储（全是整数）
- **范围扫描**（SMEMBERS 走连续数组，cache hit 率高）
- 不需要频繁删除的**小整数集合**

---

## 9. 与系列其他文章的关联

```
第一篇：redisObject    → 每个值的统一包装（SERVER.h:858）
第六篇：IntSet         → Set 类型的一种 encoding（OBJ_ENCODING_INTSET）

完整的 Set 生命周期：

SADD myset "42"          ← 字符串 "42" 可转为 long long
  setTypeCreate("42")    ← isSdsRepresentableAsLongLong("42")=OK
    → createIntsetObject()  → 创建空 intset

SADD myset "100"
  intsetAdd(intset, 100) → 插入有序数组 [42, 100]

SADD myset "hello"       ← "hello" 不能转为整数！
  setTypeConvert → intset 转为 dict (HT)
  hashtableAdd(dict, "hello")
  → 从此 Set 使用 dict 编码，不再回头
```

---

## 总结

| 维度 | IntSet |
|------|--------|
| **本质** | 按 encoding 动态变化的**有序数组** |
| **编码** | INT16 / INT32 / INT64，按需升级（只升不降） |
| **查找** | 二分查找 O(log N) + 边界快速判断 |
| **插入** | 升级 O(N) + 后移 O(N)，或直接后移 O(N) |
| **删除** | 前移覆盖 O(N) + 缩容 |
| **内存开销** | 8 字节 header + N × encoding 字节 |
| **序列化** | big-endian，无需转化直接落盘 |
| **阈值** | `set_max_intset_entries` = 512 |
| **转换方向** | 仅 intset → HT，不可逆 |
