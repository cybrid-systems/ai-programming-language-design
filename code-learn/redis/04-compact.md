# 04 — 紧凑数据结构的进化史：ziplist → listpack → quicklist

> Redis 主线源码深度分析系列 · 第四篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前几篇讲的是 Redis 的"大"结构：sds 动态字符串、dict 哈希表。但 Redis 的内存效率不仅来自这些——当数据量较小时，Redis 会选择**紧凑编码（compact encoding）**来把多个元素挤在一个连续内存块里，省掉哈希表指针和链表节点的开销。

这个方向经历了三代演进：

```
ziplist（Redis 1.x ~ 6.x，已废弃）
  ↓ 问题：级联更新（cascade update）导致插入/删除 O(N²)
listpack（Redis 7.0+，全面接班）
  ↓ 好处：每个 entry 自成一体，无级联更新
quicklist（Redis 3.2 ~ 至今）
  → 双向链表 + 每个节点 = listpack/plain node
  → 每端 N 个节点 LZF 压缩
```

本文从源码出发，详细拆解这三种数据结构的内部布局、关键算法、以及为什么 listpack 解决了 ziplist 的根本缺陷。

**doom-lsp 确认**：核心文件

| 文件 | 行数 | 职责 |
|------|:----:|------|
| `src/ziplist.h` | 74 | Ziplist API 声明 |
| `src/ziplist.c` | 2666 | Ziplist 实现（含 cascade update） |
| `src/listpack.h` | 100 | Listpack API 声明 |
| `src/listpack.c` | 2415 | Listpack 完整实现 |
| `src/quicklist.h` | 212 | Quicklist + Node 结构定义 |
| `src/quicklist.c` | 3250 | Quicklist 实现 |
| `src/lzf_c.c` / `lzf.h` | 200+ | LZF 压缩/解压 |

---

## 1. Ziplist——紧凑先锋

### 1.1 整体布局

Ziplist 是一个**大端连续字节数组**，没有任何指针间接。整体分为三部分：

```
┌──────────┬──────────────┬──────────────────────┬────────┐
│ Ziplist  │              │      Entry N         │ ZIP_END│
│ Header   │   Entry 1    │      Entry 2         │  0xFF  │
│ (3 字段) │              │                      │        │
└──────────┴──────────────┴──────────────────────┴────────┘
```

**Header（10 字节）**：

```c
// ziplist.c:232-258 — doom-lsp 确认
#define ZIPLIST_BYTES(zl)       (*((uint32_t*)(zl)))          // 总字节数（4B）
#define ZIPLIST_TAIL_OFFSET(zl) (*((uint32_t*)((zl)+4)))      // 尾 entry 偏移（4B）
#define ZIPLIST_LENGTH(zl)      (*((uint16_t*)((zl)+8)))      // entry 数（2B）
#define ZIPLIST_HEADER_SIZE     (sizeof(uint32_t)*2+sizeof(uint16_t))  // = 10
#define ZIPLIST_END_SIZE        (sizeof(uint8_t))              // 结尾 0xFF（1B）
```

- **`ZIPLIST_BYTES`**：整个 ziplist 的字节数，用于 `realloc` 扩容。
- **`ZIPLIST_TAIL_OFFSET`**：尾 entry 的偏移（从 zl 开头计算），使得 `LPOP`/`RPOP` 尾端操作 O(1)。
- **`ZIPLIST_LENGTH`**：entry 数量，但上限 **65535**。超过时存 `UINT16_MAX`，读取时需全量扫描。

**结尾标志**：`0xFF` 表示 ziplist 结束。

### 1.2 Entry 结构

```
每个 entry：
┌────────────┬──────────┬──────────────────────┐
│ prevlen    │ encoding │ entry-data          │
│ (1 or 5 B) │ (1-5 B)  │ (optional)          │
└────────────┴──────────┴──────────────────────┘
```

```c
// ziplist.c:285-299 — doom-lsp 确认
typedef struct zlentry {
    unsigned int prevrawlensize; // 编码 prevlen 使用的字节数（1 或 5）
    unsigned int prevrawlen;     // 前一个 entry 的总长度
    unsigned int lensize;        // 编码 type/length 使用的字节数
    unsigned int len;            // entry-data 的字节数
    unsigned int headersize;     // prevrawlensize + lensize
    unsigned char encoding;      // ZIP_STR_* 或 ZIP_INT_*
    unsigned char *p;            // 指向 entry 开头
} zlentry;
```

**prevlen 编码**（`ZIP_BIG_PREVLEN = 254`）：

| 值范围 | 编码格式 |
|--------|----------|
| 0 ≤ prevlen ≤ 253 | 1 字节：直接存 |
| prevlen ≥ 254 | 5 字节：`0xFE` + 4 字节小端整数 |

```c
// ziplist.c:195-200 — doom-lsp 确认
#define ZIP_BIG_PREVLEN 254
```

**encoding 编码**——按首字节的高位区分类型：

| 首字节高位 | 类型 | 数据编码 |
|-----------|------|----------|
| `00xxxxxx` | 6 位长字符串 | `ZIP_STR_06B` — 1B header，长度在低 6 位 |
| `01xxxxxx` `xxxxxxxx` | 14 位长字符串 | `ZIP_STR_14B` — 2B header |
| `10000000` `xxxxxxxx` … | 32 位长字符串 | `ZIP_STR_32B` — 5B header |
| `11000000` | 16 位有符号整数 | `ZIP_INT_16B` — 2B data |
| `11010000` | 32 位有符号整数 | `ZIP_INT_32B` — 4B data |
| `11100000` | 64 位有符号整数 | `ZIP_INT_64B` — 8B data |
| `11110000` | 24 位有符号整数 | `ZIP_INT_24B` — 3B data |
| `11111110` | 8 位有符号整数 | `ZIP_INT_8B` — 1B data |
| `1111xxxx` | 4 位立即整数 | `ZIP_INT_IMM` — 0B data，值在低 4 位，范围 0~12（编码为 xxxx-1）|

```c
// ziplist.c:204-220 — doom-lsp 确认
#define ZIP_STR_MASK 0xc0
#define ZIP_INT_MASK 0x30
#define ZIP_STR_06B (0 << 6)     // 00xxxxxx
#define ZIP_STR_14B (1 << 6)     // 01xxxxxx
#define ZIP_STR_32B (2 << 6)     // 10xxxxxx
#define ZIP_INT_16B (0xc0 | 0<<4) // 11000000
#define ZIP_INT_32B (0xc0 | 1<<4) // 11010000
#define ZIP_INT_64B (0xc0 | 2<<4) // 11100000
#define ZIP_INT_24B (0xc0 | 3<<4) // 11110000
#define ZIP_INT_8B 0xfe          // 11111110
#define ZIP_INT_IMM_MIN 0xf1     // 11110001（4 位立即整数）
#define ZIP_INT_IMM_MAX 0xfd     // 11111101
```

### 1.3 前向遍历与反向遍历

**前向遍历**：`p += entry->headersize + entry->len`。跳过当前 entry 的全部内容，到达下一个 entry 的 prevlen 字段。

**反向遍历**：唯一的途径就是读当前 entry 的 `prevlen` 字段：

```c
// ziplist.c:507-534 — 核心思想
// p 指向当前 entry 开头
// 读 p[0] 的给定位确定 prevrawlensize（1 或 5）
// 从 p 读 prevrawlen 字节 = 前一个 entry 的总长度
// p - prevrawlen = 前一个 entry 的开头
```

这就是 ziplist 反向遍历**唯一**依赖 `prevlen` 的原因——没有它，从任意位置无法向左走。这也是 cascade update 问题的根源。

### 1.4 级联更新（Cascade Update）——根本缺陷

当一个 entry 被**插入**或**删除**时，它的下一个 entry 的 `prevlen` 必须更新为前一个 entry 的新长度。

如果更新的 `prevlen` 刚好从 1 字节变为 5 字节（即前一个 entry 长度从 ≤253 变为 ≥254），这个 entry 本身就会**膨胀 4 字节**，进而导致它的下一个 entry 的 `prevlen` 也膨胀……如此连锁反应下去，就是**级联更新**。

```c
// ziplist.c:751 — doom-lsp 确认
unsigned char *__ziplistCascadeUpdate(unsigned char *zl, unsigned char *p) {
    // p 指向需要检查的第一个 entry
    // delta = 4（prevlen 从 1B 涨到 5B 多出的字节数）

    // 第一阶段：计算需要多少额外空间
    while (p[0] != ZIP_END) {
        if (cur.prevrawlen == prevlen) break;       // prevlen 没变 → 不需要更新
        if (cur.prevrawlensize >= prevlensize) break; // 空间够大 → 停下
        extra += delta;
        cnt++;
    }

    // 第二阶段：从尾到头反向更新
    // memmove 整体移动数据 + 逐个 entry 写新 prevlen
    while (cnt) {
        memmove(p - (rawlen - cur.prevrawlensize),
                zl + prevoffset + cur.prevrawlensize,
                rawlen - cur.prevrawlensize);
        p -= (rawlen + delta);
    }
}
```

**最坏情况**：假设一个 ziplist 所有 entry 长度都在 250~253 字节之间，每个 entry 的 `prevlen` 都是 1 字节。此时插入一个 ≥254 字节的新 entry，会触发整条链的级联更新——**O(N) 个 entry 全部膨胀 4 字节**，每次更新都是 `memmove` 加逐个写入，总复杂度 O(N²)。

ziplist.c 的作者在注释中明确承认了这个问题：

```
// ziplist.c:740-748 — doom-lsp 确认
// 注意：这种效果也可能反向发生（prevlen 变小）。
// 但故意忽略了减小的情况，因为可能引起"摆动"效应：
// 连续插入先胀大、后缩小。宁可让 prevlen 保持较大
```

**缩小方向忽略**意味着：一旦一个 entry 因为 cascade 而被迫用 5 字节 `prevlen`，即使后续删除让它的前驱变小了，这个 entry 也不缩回去——代价是浪费最多 4 字节。但对于"变大"方向，不做不行——否则前驱 entry 会溢出到下一个 entry 的编码字段。

### 1.5 为什么 ziplist 在 Redis 7.0 中被废弃

ziplist 有以下不可忽视的问题：

1. **级联更新 O(N²)**：虽然实际中很少触发（需要连续 253+ 字节的 entry），但一旦触发，延迟毛刺不可接受。
2. **反向遍历依赖前驱**：每个 entry 存的是**前驱**长度（`prevlen`），而不是自身长度。这导致 `lpPrev` 必须解码前驱 entry 才能知道往后退了多少。
3. **大端字节序**：`intrev32ifbe` 随处可见，给跨平台带来开销。
4. **长度计数上限**：`ZIPLIST_LENGTH` 只有 2 字节，>65535 时必须全量扫描。

---

## 2. Listpack——无级联更新的紧凑序列

antirez 在 2017 年设计了 listpack 作为 ziplist 的替代品，在 Redis 7.0 中全面接管了 ziplist 的位置。核心改进：**每个 entry 只存自己的长度，不需要知道前驱的长度**。

### 2.1 整体布局

```
┌──────────┬──────────────────────┬────────┐
│ Listpack │      Entry N         │   EOF  │
│ Header   │      Entry 2         │  0xFF  │
│ (6 字节) │      Entry 1         │        │
└──────────┴──────────────────────┴────────┘
```

```c
// listpack.c:48 — doom-lsp 确认
#define LP_HDR_SIZE 6  // 32 bit total len + 16 bit number of elements

#define lpGetTotalBytes(p)   (((uint32_t)(p)[0]<<0) | ... )  // 4B 总大小
#define lpGetNumElements(p)  (((uint32_t)(p)[4]<<0) | ... )  // 2B 元素数
```

**与 ziplist 的关键差异**：
- Header 只有 **6 字节**（4B total + 2B count），没有 tail offset
- 尾部是 `0xFF` EOF 标记
- 没有 `prevlen` 字段——反向遍历靠的是 entry 内部的 **backlen（向后长度）**

### 2.2 Entry 结构

```
┌──────────┬──────────────────────┬──────────┐
│ encoding │ entry-data          │ backlen  │
│ (1-9 B)  │ (optional)          │ (1-5 B)  │
└──────────┴──────────────────────┴──────────┘
```

每个 entry 由三部分组成：编码头、数据、backlen（反向解析长度）。关键变化：**没有 prevlen，数据在中间，backlen 在末尾**。

**Encoding 编码**——同样通过首字节高位的标志位判断类型：

```c
// listpack.c:52-95 — doom-lsp 确认
#define LP_ENCODING_INT 0
#define LP_ENCODING_STRING 1

// 整数编码
#define LP_ENCODING_7BIT_UINT       0      // 0xxxxxxx (128 种值，0-127)
#define LP_ENCODING_13BIT_INT       0xC0   // 110xxxxx xxxxxxxx (8192 种值)
#define LP_ENCODING_16BIT_INT       0xF1   // 11110001 xx xx (16位)
#define LP_ENCODING_24BIT_INT       0xF2   // 11110010 xx xx xx (24位)
#define LP_ENCODING_32BIT_INT       0xF3   // 11110011 xx xx xx xx (32位)
#define LP_ENCODING_64BIT_INT       0xF4   // 11110100 xx xx xx xx xx xx xx xx (64位)

// 字符串编码
#define LP_ENCODING_6BIT_STR        0x80   // 10xxxxxx (64 种长度)
#define LP_ENCODING_12BIT_STR       0xE0   // 1110xxxx xx xx (4096 种长度)
#define LP_ENCODING_32BIT_STR       0xF0   // 11110000 xx xx xx xx (4GB 长度)
```

| 编码 | 首字节高位 | 总 header 大小 | 数值范围 |
|------|-----------|:------------:|----------|
| 7-bit uint | `0xxx xxxx` | 1B | 0 ~ 127 |
| 6-bit string | `10xx xxxx` | 1B | 长度 0 ~ 63 |
| 13-bit int | `110x xxxx` | 2B | -4096 ~ 8191 |
| 12-bit string | `1110 xxxx` | 2B | 长度 0 ~ 4095 |
| 32-bit string | `1111 0000` | 5B | 长度 0 ~ 4GB-1 |
| 16-bit int | `1111 0001` | 2B + 2B data | int16 范围 |
| 24-bit int | `1111 0010` | 2B + 3B data | int24 范围 |
| 32-bit int | `1111 0011` | 2B + 4B data | int32 范围 |
| 64-bit int | `1111 0100` | 2B + 8B data | int64 范围 |

与 ziplist 相比，listpack 增加了 7-bit uint 编码（单个 byte 就能存 0-127 的整数，无需额外的 data 字节），每个 entry 整体更紧凑。

### 2.3 Backlen——反向遍历的钥匙

`backlen` 是 listpack 最重要的创新。它在每个 entry 的末尾，编码的是**整个 entry 的长度（encoding header + data）**。

```c
// listpack.c:347-382 — doom-lsp 确认
// backlen 是逆向编码的变长字段：从最后一个字节开始，每字节高 1 位是继续标志
// 低 7 位拼起来就是长度值
static inline unsigned long lpEncodeBacklen(unsigned char *buf, uint64_t l) {
    if (l <= 127) {
        if (buf) buf[0] = l;
        return 1;
    } else if (l < 16383) {
        if (buf) {
            buf[0] = l>>7;           // 高位字节（最高位=0，表示结束）
            buf[1] = (l&127)|128;    // 低位字节（最高位=1，表示还有后续）
        }
        return 2;
    } else if (l < 2097151) {
        // 3 字节编码
    } else if (l < 268435455) {
        // 4 字节编码
    } else {
        // 5 字节编码
    }
}
```

**backlen 的特点**：编码顺序是**高字节在前，低字节在后**。最高有效字节的 MSB = 0（结束标志），后续字节的 MSB = 1（继续标志）。

这意味着从 entry 末尾向前解码时：

```c
// listpack.c:384-399 — doom-lsp 确认
static inline uint64_t lpDecodeBacklen(unsigned char *p) {
    uint64_t val = 0;
    uint64_t shift = 0;
    do {
        val |= (uint64_t)(p[0] & 127) << shift;  // 取低 7 位
        if (!(p[0] & 128)) break;                  // MSB=0 → 结束
        shift += 7;
        p--;                                        // 向前走一个字节
        if (shift > 28) return UINT64_MAX;         // 超长保护
    } while(1);
    return val;
}
```

**反向遍历**变得简单直接：

```c
// listpack.c:488-497 — doom-lsp 确认
unsigned char *lpPrev(unsigned char *lp, unsigned char *p) {
    if (p - lp == LP_HDR_SIZE) return NULL;       // 已到开头
    p--;                                           // 回退到上一个 entry 的 backlen 末尾
    uint64_t prevlen = lpDecodeBacklen(p);         // 解码出上一个 entry 的总长度
    prevlen += lpEncodeBacklen(NULL, prevlen);     // 加上 backlen 自身的大小
    p -= prevlen - 1;                              // 跳到上一个 entry 开头
    return p;
}
```

**前向遍历**同样简单：

```c
// listpack.c:495 — doom-lsp 确认
unsigned char *lpSkip(unsigned char *p) {
    unsigned long entrylen = lpCurrentEncodedSizeUnsafe(p);  // 当前 entry 的数据长度
    entrylen += lpEncodeBacklen(NULL, entrylen);              // 加上 backlen 长度
    p += entrylen;
    return p;
}
```

### 2.4 为什么 listpack 没有级联更新

对比两种结构的**反向遍历方式**：

| 特性 | Ziplist | Listpack |
|------|---------|----------|
| 反向遍历的依据 | 当前 entry 存**前驱**的 `prevlen` | 当前 entry 末尾存**自身**的 `backlen` |
| 插入/删除时 | 下一个 entry 的 `prevlen` 必须更新 | 上一个和下一个的 `backlen` 都不变 |
| 级联更新？ | **会**——prevlen 编码变大导致相邻 entry 长度改变 | **不会**——backlen 编码的是自身长度，不受邻居影响 |

在 listpack 中，每个 entry 是**完全自包含**的：
- 前向遍历：读 encoding header 中编码的长度 → 跳过 entry
- 反向遍历：从 entry 末尾读 backlen → 知道跳回多少

插入或删除一个 entry，**只影响该 entry 本身**，不会改变任何已有 entry 的 backlen。

### 2.5 lpInsert——插入/删除的核心

```c
// listpack.c:768-895 — doom-lsp 确认
unsigned char *lpInsert(unsigned char *lp,
    unsigned char *elestr, unsigned char *eleint,
    uint32_t size, unsigned char *p, int where, unsigned char **newp)
{
    // 1. 编码新元素（字符串或整数）
    enctype = lpEncodeGetType(elestr, size, intenc, &enclen);

    // 2. 计算 backlen 和总大小变化
    backlen_size = lpEncodeBacklen(backlen, enclen);
    new_bytes = old_bytes + enclen + backlen_size - replaced_len;

    // 3. realloc + memmove 调整空间
    memmove(dst + enclen + backlen_size, dst, old_bytes - poff);

    // 4. 写入 entry 数据（或删除时不写）
    if (enctype == LP_ENCODING_INT) memcpy(dst, eleint, enclen);
    else lpEncodeString(dst, elestr, size);

    // 5. 写入 backlen
    memcpy(dst + enclen, backlen, backlen_size);

    // 6. 更新 header 中的 total bytes 和 num elements
    lpSetTotalBytes(lp, new_bytes);
    if (delete) lpSetNumElements(lp, numele - 1);
    else lpSetNumElements(lp, numele + 1);
}
```

没有级联更新，没有额外遍历。插入就是一次 `memmove` + 两次 `memcpy`。复杂度 **O(N)** 在 `memmove` 上（可能需要移动后面的所有数据），而不是 O(N²) 的级联更新。

### 2.6 为什么 listpack 不需要 tail offset

Ziplist 用 4 字节的 tail offset 来支持 O(1) 尾端访问。但 tail offset 在级联更新时也需要维护——又增加了复杂度。

Listpack 的 `lpLast()` 是这样做的：

```c
// listpack.c:519-523 — doom-lsp 确认
unsigned char *lpLast(unsigned char *lp) {
    unsigned char *p = lp + lpGetTotalBytes(lp) - 1;  // 直接跳到文件末尾的 EOF
    return lpPrev(lp, p);                               // 反向走一步 = 最后一个 entry
}
```

**尾端操作 O(1)**：只需要从末尾的 `0xFF` 减 1 字节 → `lpDecodeBacklen` → 得到最后一个 entry 的开头。由于 backlen 最多 5 字节，这一操作总是常数时间。

---

## 3. Quicklist——List + Listpack 的混合体

### 3.1 设计动机

ziplist 和 listpack 解决了"紧凑存储"问题，但它们都有一个共同限制：**插入/删除中间元素需要 O(N) 的 memmove**。对于 List 这种频繁在两端操作的场景，单一大块的紧凑数组插入头部时会频繁 realloc + memmove 整个块。

quicklist 的设计思路：**用双向链表把多个小 listpack 串起来**。头尾插入只在端节点修改，中间节点的分裂和合并只在需要时发生。

### 3.2 结构体

```c
// quicklist.h:23-70 — doom-lsp 确认
// quicklistNode：32 字节，用位域压缩
typedef struct quicklistNode {
    struct quicklistNode *prev;           // 前驱节点指针（8B）
    struct quicklistNode *next;           // 后继节点指针（8B）
    unsigned char *entry;                 // 指向 listpack 数据（或 LZF 压缩数据）（8B）
    size_t sz;                            // entry 大小（8B）
    unsigned int count : 16;              // listpack 中元素数（2B，上限 65536）
    unsigned int encoding : 2;            // RAW=1, LZF=2
    unsigned int container : 2;           // PLAIN=1（大元素单节点）, PACKED=2（listpack）
    unsigned int recompress : 1;          // 是否曾解压用于操作
    unsigned int attempted_compress : 1;  // 尝试过压缩但失败
    unsigned int dont_compress : 1;       // 阻止压缩（即将被使用）
    unsigned int extra : 9;               // 保留位
} quicklistNode;  // 总共 32 字节
```

**quicklistNode 的内存布局**（均为 packed）：
- `prev` + `next` + `entry` + `sz` = 32 字节（4 × 8B）
- `count` 等位域填满 32 位的剩余部分

```c
// quicklist.h:92-115 — doom-lsp 确认
typedef struct quicklist {
    quicklistNode *head;                   // 头节点（8B）
    quicklistNode *tail;                   // 尾节点（8B）
    unsigned long count;                   // 全部 listpack 中的元素总数（8B）
    unsigned long len;                     // quicklistNode 节点数（8B）
    signed int fill : QL_FILL_BITS;        // fill factor
    unsigned int compress : QL_COMP_BITS;  // 压缩深度
    unsigned int bookmark_count : QL_BM_BITS;
    quicklistBookmark bookmarks[];         // 柔性数组，书签
} quicklist;  // 40 字节（64 位系统，不含 bookmarks）
```

`fill`（fill factor）控制每个 listpack 的目标大小：

| fill 值 | 行为 |
|---------|------|
| > 0 | 每个节点最多存放 `fill` 个元素 |
| -1 ~ -5 | 对应优化级别：`-1` = 4KB, `-2` = 8KB, `-3` = 16KB, `-4` = 32KB, `-5` = 64KB |

`compress` 控制两端不压缩的节点数。`compress = 2` 表示头尾各 2 个节点保持未压缩，中间节点 LZF 压缩。

### 3.3 PushHead/PushTail——插入逻辑

```c
// quicklist.c:545-571 — doom-lsp 确认
int quicklistPushHead(quicklist *quicklist, void *value, size_t sz) {
    quicklistNode *orig_head = quicklist->head;

    // 大元素（超过 packed_threshold）→ 独立 PLAIN 节点
    if (unlikely(isLargeElement(sz))) {
        __quicklistInsertPlainNode(quicklist, quicklist->head, value, sz, 0);
        return 1;
    }

    // 普通大小：尝试插入现有头节点的 listpack
    if (_quicklistNodeAllowInsert(quicklist->head, quicklist->fill, sz)) {
        quicklist->head->entry = lpPrepend(quicklist->head->entry, value, sz);
    } else {
        // 头节点已满 → 创建新节点
        quicklistNode *node = quicklistCreateNode();
        node->entry = lpPrepend(lpNew(0), value, sz);
        _quicklistInsertNodeBefore(quicklist, quicklist->head, node);
    }
    quicklist->count++;
    quicklist->head->count++;
    return (orig_head != quicklist->head);
}
```

**三个分支**：

1. **`isLargeElement(sz)`**：元素超过 `listpack-max-listpack-size` 配置（默认 8KB），单独成节点（`PLAIN` container），不走 listpack。
2. **`_quicklistNodeAllowInsert` 允许**：当前 head 节点还有空间 → `lpPrepend` 直接插入现有 listpack。
3. **不允许**：创建新 quicklistNode + 新 listpack，插入链表头部。

`_quicklistNodeAllowInsert` 的判断逻辑：

```c
// quicklist.c:470-493 — doom-lsp 确认
REDIS_STATIC int _quicklistNodeAllowInsert(const quicklistNode *node,
                                           const int fill, const size_t sz) {
    if (!node) return 0;
    if (QL_NODE_IS_PLAIN(node) || isLargeElement(sz)) return 0;

    // 估算插入后大小
    size_t new_sz = node->sz + sz + SIZE_ESTIMATE_OVERHEAD;

    // 优先使用 size limit（当 fill < 0 时）
    if (_quicklistNodeSizeMeetsOptimizationRequirement(new_sz, fill))
        return 1;
    // 安全上限检查
    else if (!sizeMeetsSafetyLimit(new_sz))
        return 0;
    // 使用 count limit（当 fill > 0 时）
    else if ((int)node->count < fill)
        return 1;
    else
        return 0;
}
```

**两种模式**：
- `fill > 0`：按**元素数**限制（如每个节点最多 50 个元素）
- `fill < 0`：按**字节大小**限制（如每个节点 ≤ 8KB）

### 3.4 节点分裂与合并

**插入中间元素**时，如果目标节点满了，`quicklistInsertAfter`/`quicklistInsertBefore` 会：

1. 如果目标节点的 listpack 能容纳 → 直接 `lpInsert`
2. 如果满了 → 将目标节点**分裂**成两个节点
3. 如果相邻节点有空间 → 尝试**合并**两个小节点

```c
// quicklist.c:1076-1097 — quicklistInsertAfter 简化逻辑
void quicklistInsertAfter(quicklistIter *iter, quicklistEntry *entry, ...) {
    // 不能放入现有节点 → 分裂
    if (!_quicklistNodeAllowInsert(node, fill, sz)) {
        // 1. 在 entry 位置把节点分成左右两个 listpack
        // 2. 新元素插入到右节点头部
        // 3. 把新节点插入链表
    } else {
        // 直接插入现有节点的 listpack
    }

    // 尝试与相邻节点合并
    // _quicklistListpackMerge() 会递归检查左右两对相邻节点
}
```

### 3.5 LZF 压缩——中间节点压缩

Quicklist 支持对中间节点做 **LZF 压缩**以节省内存。使用场景：长 list 的中间部分很少被访问。

```c
// quicklist.c:214-241 — doom-lsp 确认
REDIS_STATIC int __quicklistCompressNode(quicklistNode *node) {
    if (node->dont_compress) return 0;

    // 太小就不压缩了
    if (node->sz < MIN_COMPRESS_SIZE) return 0;

    quicklistLZF *lzf = zmalloc(sizeof(*lzf) + node->sz);
    lzf->sz = lzf_compress(node->entry, node->sz, lzf->compressed, node->sz);

    // 压缩效果不够好（压缩比不够或没怎么减小）
    if (lzf->sz == 0 || lzf->sz + MIN_COMPRESS_IMPROVE >= node->sz) {
        zfree(lzf);
        return 0;
    }

    // 按实际压缩大小 realloc
    lzf = zrealloc(lzf, sizeof(*lzf) + lzf->sz);
    node->entry = (unsigned char *)lzf;
    node->encoding = QUICKLIST_NODE_ENCODING_LZF;
    return 1;
}
```

**压缩触发时机**：
- 新节点插入且需要"推走"一个原本在末端的未压缩节点时
- 节点被访问并解压后，释放时重新压缩（`recompress` flag）

**压缩范围**：`quicklist->compress` 指定了 **两端保留多少个节点不压缩**。例如 `compress = 2`：

```
head → [节点1][节点2][节点3][节点4]...[节点N-3][节点N-2][节点N-1][节点N]
        ↑            ↑                        ↑                       ↑
      不压缩      可压缩                    可压缩                  不压缩
```

这确保了两端频繁操作的节点总是可用状态，而中间节点以压缩形式保存。

### 3.6 Quicklist 的效率特征

| 操作 | 复杂度 | 说明 |
|------|:------:|------|
| `LPUSH` | O(1) | 头节点 `lpPrepend`，列表满了才新建节点 |
| `RPUSH` | O(1) | 尾节点 `lpAppend` |
| `LPOP` | O(1) | 头节点的第一个 listpack entry 删除 |
| `RPOP` | O(1) | 尾节点的最后一个 listpack entry 删除 |
| `LINDEX` | O(N/node) | 遍历节点找目标 listpack，再 listpack 内 O(1) 定位 |
| `LINSERT` | O(N/node + listpack N) | 分裂+合并可能触发 |
| 压缩 | 后台 | serverCron 或操作后 |

**内存效率对比**：

| 元素数 | ziplist | quicklist (fill=-2=8KB) |
|--------|---------|------------------------|
| 10 个小元素 | ~100 字节 | ~200 字节（额外节点指针） |
| 1000 个小元素 | ~10KB | ~10KB + 少量节点 overhead |
| 100000 个元素 | ~1MB | ~1MB + ~20KB 节点 overhead |

Quicklist 在**小列表**时比 ziplist 略慢（多了链表指针的间访问），但 **大列表**时的插入/删除不触发 O(N) 的 memmove。

---

## 4. 编码切换全景——补齐前面的图

第一篇展示了 `type × encoding` 矩阵。现在补齐每个紧凑编码的生命周期：

```
Hash:
  HSET → hashTypeSet()
    如果编码是 LISTPACK（或旧版 ZIPLIST）：
      → 检查字段数是否 > hash_max_listpack_entries (512)
      → 检查 field/value 长度是否 > hash_max_listpack_value (64)
      → 超限 → hashTypeConvertListpack() 转为 HT (dict)

List:
  LPUSH → lpushCommand()
    如果编码是 LISTPACK（list-compress-depth=0 且 list-max-listpack-size>0）：
      → quicklistPushHead() 进入 listpack 节点
    如果列表仅 1 个元素（通过 LPUSH/LPOP 等操作发现）：
      → 可以用 listpack 编码（listTypeTryConversion）
    大元素（> list-max-listpack-size）：
      → 单独 PLAIN 节点，不进入 listpack

ZSet:
  ZADD → zsetAdd()
    如果编码是 LISTPACK：
      → 检查成员数 > zset_max_listpack_entries (128)
      → 检查 member 长度 > zset_max_listpack_value (64)
      → 超限 → zsetConvert() 转为 SKIPLIST

Set:
  SADD → setTypeAdd()
    如果编码是 INTSET：
      → 检查新元素是否能表示为 long long
      → 检查元素数 > set_max_intset_entries (512)
      → 任一条不满足 → setTypeConvert() 转为 HT
```

---

## 5. 对比总览

| 维度 | Ziplist | Listpack | Quicklist |
|------|---------|----------|-----------|
| 存储格式 | 连续数组 | 连续数组 | 双向链表 + listpack 节点 |
| Header | 10 字节 (bytes+tail+count) | 6 字节 (bytes+count) | 40 字节（不含书签） |
| 反向遍历 | `prevlen`（依赖前驱） | `backlen`（自身末尾编码） | 链表 `prev` 指针 |
| 级联更新 | **有**（O(N²) 最坏） | **无** | 无（listpack 内部） |
| 尾端 O(1) | 是（tail offset） | 是（末尾 backlen） | 是（链表 tail） |
| 中间插入 | O(N) memmove | O(N) memmove | O(1) 节点级分裂 |
| 压缩 | 不支持 | 不支持 | LZF 支持（中间节点） |
| 当前状态 | **废弃**（Redis 7.0） | 活跃（Hash/ZSet） | 活跃（List） |
| 最大存储 | 1GB | 1GB | 无限制 |
| 大小端 | BE（需转换） | LE | N/A（listpack 内 LE） |

---

## 6. 与之前文章的联系

可以画出一个完整的数据模型图谱了：

```
Redis 数据模型的三层抽象
═══════════════════════════

redisObject (16B)            ← 01-data-model.md
├── type: OBJ_STRING
│   └── encoding:
│       ├── OBJ_ENCODING_RAW    → sds               ← 02-sds.md
│       ├── OBJ_ENCODING_EMBSTR → robj+sds 融合
│       └── OBJ_ENCODING_INT   → 共享整数
│
├── type: OBJ_LIST
│   └── encoding:
│       └── OBJ_ENCODING_QUICKLIST → quicklist
│           └── listpack nodes                  ← 本文
│
├── type: OBJ_HASH
│   └── encoding:
│       ├── OBJ_ENCODING_LISTPACK → listpack    ← 本文
│       └── OBJ_ENCODING_HT    → dict           ← 03-dict.md
│
├── type: OBJ_ZSET
│   └── encoding:
│       ├── OBJ_ENCODING_LISTPACK → listpack
│       └── OBJ_ENCODING_SKIPLIST → zset(dict+skiplist)
│
└── type: OBJ_SET
    └── encoding:
        ├── OBJ_ENCODING_INTSET → intset
        └── OBJ_ENCODING_HT    → dict
```

每一层的紧凑编码（listpack/quicklist）都是开放路径的优化入口——在数据量小的时候用紧凑形式节省内存，数据量大了就退化为更高效的指针结构（dict/skiplist）。
