# 08 — 索引 key：类型怎样排成有序字节

> 源码基线与 [06-key-encoding](06-key-encoding.md) 相同。
> 实现在 `src/common/utils/IndexKeyUtils.h` 与 `IndexKeyUtils.cpp`。
> `encodeInt64`、`encodeDouble`、`encodeValues`、`vertexIndexKeys` 这**四个函数**在 `v3.8.0` 与 master 之间没有 diff。所在文件 `IndexKeyUtils.h` 有 8 行差异，全部在 `toValueType` 里（master 增加 LIST / SET 的映射），而建索引时这些类型会被拒绝，见 [07](07-row-encoding.md)。
> 分析日期：2026-10-26

---

## 0. Key 的外壳

顶点索引（`vertexIndexKeys`）和边索引（`edgeIndexKeys`）共用 `kIndex = 3` 的 4 字节头，头的字节序见 [06](06-key-encoding.md)。

```
顶点: | type|part (4) | IndexID (4，主机序) | 各列编码 | [nullable u_short] | VID |
边:   | type|part (4) | IndexID (4，主机序) | 各列编码 | [nullable u_short] | src VID | rank (8，有序) | dst VID |
```

`IndexID` 是 `int32_t`，主机序写入。`indexPrefix(partId, indexId)` 是前 8 字节。扫一个索引就是这个前缀。IndexID 256 和 IndexID 1 的字节序问题与 TagID 相同；前缀扫描用的是完整 IndexID，不依赖「数值相邻」。

VID 的补齐和 rank 的 `encodeRank` 与数据 key 相同。rank 复用 `encodeInt64`。

列编码由 `encodeValues` 拼好，再交给 `vertexIndexKeys` / `edgeIndexKeys` 套上外壳。地理索引一列可以产生多条 key，见第 5 节。

---

## 1. 谁可以进索引

`CreateTagIndexProcessor` / `CreateEdgeIndexProcessor`（两边的检查对称）：

- 最多 16 列。注释写明 16 bit 的 nullable 位图够用。
- `DURATION` 不能索引。
- master 上 LIST / SET 不能索引（`E_INVALID_PARM`）。`v3.8.0` 没有这些类型。
- `STRING` 必须带 `type_length`，且 `1 .. MAX_INDEX_TYPE_LENGTH`。`CommonMacro.h` 里这个宏是 256。通过之后，索引列的类型被改写成 `FIXED_STRING`，长度是用户写的那个前缀长度。
- schema 里已经是 `FIXED_STRING` 的列，索引定义里不能再写长度（`E_UNSUPPORTED`）。编码时用 schema 的长度。这段代码没有把 schema 长度再和 256 比较。
- `GEOGRAPHY` 只能单独成索引，不能和别的列组合。注释 TODO：联合地理索引未做。
- 其它类型若写了 `type_length`，`E_INVALID_PARM`。

因此字符串索引在 key 里一定是定长：短了补 `'\0'`，长了 `substr(0, len)`。`encodeValue(Value, len)` 只对 `STRING` 做这件事；`encodeValues` 在列类型已经是 `FIXED_STRING` 时走这条路径。

---

## 2. 整数与布尔

`encodeInt64` 与边的 rank 相同：

```text
v ^= 1 << 63
folly::Endian::big 后写出
```

头文件里的例子：

| 数值 | 字节 |
|------|------|
| `INT64_MAX` | 8 个 `\377` |
| 1 | `\200\000\000\000\000\000\000\001` |
| 0 | `\200` 后跟 7 个 0 |
| -1 | `\177` 后跟 7 个 `\377` |
| `INT64_MIN` | 8 个 0 |

所有整数属性（INT8/16/32/64、TIMESTAMP）在 `toValueType` 里都是 `Value::INT`，索引里一律占 8 字节。比较顺序就是数值顺序。

布尔是 1 字节主机序 `bool`，没有符号变换。`false` 是 0，`true` 是 1，false 排在前面。

---

## 3. 浮点

`encodeDouble` 的注释：IEEE 是符号位 + 阶码 + 尾数，符号位 1 表示负，直接按字节排会把负数排到正数后面。处理是：

| 输入 | 字节 |
|------|------|
| NaN | 8 个 `0xFF` |
| `>= 0` | 大端，再把最高字节的最高位置 1 |
| `< 0` | 按整数位取反，再大端写出 |

`decodeDouble`：大端读回后，最高位为 1 就清掉它（正数路径）；否则整体取反（负数路径）。正数因此排在负数后面，NaN 排在最后，和「全 `0xFF`」的 null 占位重叠，靠第 6 节的位图区分。

FLOAT 与 DOUBLE 都走 `Value::FLOAT`，索引里都是 8 字节 double。没有单独的 4 字节 float 索引编码。

---

## 4. 日期与时间

全部按大端、按日历字段从大到小排：

| 类型 | 顺序 | 宽度 |
|------|------|------|
| TIME | 时、分、秒各 int8，微秒 int32 | 7 |
| DATE | 年 int16，月，日 | 4 |
| DATETIME | 年 int16，月，日，时，分，秒，微秒 int32 | 11 |

年用 `big16`，微秒用 `big32`。同一类型内字典序等于时间先后。这些宽度和行内字段区一致，但行内是主机序，索引里是大端。两边不能直接 `memcmp`。

---

## 5. 地理

`encodeValues` 发现列类型是 `GEOGRAPHY` 时要求只有这一列。非空值走 `encodeGeography`：`GeoIndex::indexCells` 得到一组 S2 cell id，每个 cell id 用 `encodeUint64`（纯大端，不翻转符号）变成一条列编码。一个点因此有多条索引 key，条数由 `s2_max_level` / `s2_max_cells` 决定；索引上没写这两个参数时用 `RegionCoverParams` 的默认值。默认值在 `RegionCoverParams` 里，本文没有再展开 S2 的覆盖算法。

`decodeValue` 对 `GEOGRAPHY` 固定返回 `Value::kNullBadData`。注释写明：索引 key 里不是原始 Geography，要原始值去读数据表。`decodeGeography` 只在测试里把 key 解回 cell id。

空值占 8 字节 `0xFF`（注释写的是一个 S2CellId 的宽度），并把 nullable 位图的最高位置 1。

---

## 6. NULL 与 16 列位图

任一列 `nullable_ref` 为真，`encodeValues` 就在列编码末尾追加一个 `u_short`。这个整数按主机序写入，没有 `Endian::big`。小端上 `0x8000` 的字节是 `00 80`。

第 `i` 列（从 0 起）为 null 时 `nullableBitSet |= 0x8000 >> i`。null 的列字节是 `encodeNullValue`：按该类型宽度填满 `0xFF`。字符串用索引长度，地理用 8。

`getValueFromIndexKey` 从 key 尾部往前跳过 VID（边索引还要跳过 rank 和 dst），再读这 2 字节。`bitset<16>::test` 从低位算；`nullableColPosit` 从 15 往下减，和 `0x8000 >> i` 对齐。

后果：

- 列字节本身把 null 排在该类型几乎所有合法值之后，因为合法值很少是全 `0xFF`。
- `encodeInt64(INT64_MAX)` 和 `encodeDouble(NaN)` 也是 8 个 `0xFF`。它们和 null 的列字节相同，只靠后面的 `u_short` 区分。非 null 的位图是 0，小端字节 `00 00`；第 0 列为 null 时位图是 `0x8000`，小端字节 `00 80`。所以在列字节相同的情况下，null 排在 `INT64_MAX` / NaN 后面。
- 位图在所有列之后、VID 之前。比较两条索引时，先比列，列相同再比「是否 null」，再比 VID。同一列值、同一 null 状态下，VID 决定顺序。

`checkValue` 拒绝 `UNKNOWN_PROP`、非 nullable 列上的 NULL、`BAD_DATA`、`NaN` 等。`collectIndexValues` 失败时 `AddVerticesProcessor::indexKeys` 返回空 vector，这条索引项不会写入。调用方把空 vector 当成「没有 key」，不会把编码错误单独返回给客户端。这是 `indexKeys` 的实际行为。

---

## 7. 索引 value：只有 TTL

`IndexKeyUtils::indexVal`：

```text
| size_t 长度（主机序） | CompactSerializer 序列化的 Value |
```

`AddVerticesProcessor::addVerticesWithIndex` 里，只有 `CommonUtils::ttlValue` 成功才把 TTL 列的 `Value` 写成这个 value；否则 value 是空串。边索引在 `AddEdgesProcessor` 里同样处理。

`IndexScanNode::checkTTL`：value 为空，或者 schema 没开 TTL，就保留这条索引。否则 `parseIndexTTL` 反序列化，再调用 `CommonUtils::checkDataExpiredForTTL`。过期返回 false，扫描跳过。数据行本身的 TTL 判断见 [07](07-row-encoding.md)。索引里这份时间是写入索引时的列值，不是行尾微秒时间戳。

重建期间，新索引项会先写成 `OperationKeyUtils::modifyOperationKey`，value 仍是这份 TTL 序列化；删除则把索引 key 放进 delete 操作的 value。操作 key 的布局见 [06](06-key-encoding.md)。

---

## 8. 扫描时谓词怎么变成前缀

`IndexScanNode.cpp` 的 `Path::encodeValue` 把 hint 的起始值编码进 `indexPrefix(partId)` + IndexID 之后。字符串列使用 `colDef.type_length`。这只覆盖「从某一列的某个值开始」的前缀，不是任意表达式。表达式过滤仍要在读出索引行之后做；那一层和 `FilterNode` 的关系见 [04](04-storage-execution.md)，索引选择器本身不在本文。

地理索引的前缀是 cell id 的大端形式。一个查询区域可能对应多个 cell，因此是多次前缀，而不是一条范围。
