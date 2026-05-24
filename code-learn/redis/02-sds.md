# 02 — SDS：Simple Dynamic Strings 深度解析

> Redis 主线源码深度分析系列 · 第二篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Redis 最常打交道的数据结构是什么？不是哈希表，不是跳表，而是——**字符串**。每一个 Redis key 都是字符串，大多数 value 也是字符串。如果字符串的实现不够极致，Redis 的整个性能大厦都会倾斜。

C 标准库的 `char*` 以 `\0` 结尾、用 `strlen()` 遍历计长度、`strcat()` 假定目标缓冲区足够大——这些设计在 Redis 的高频读写场景下处处是坑。于是 Redis 造了自己的轮子：**SDS（Simple Dynamic Strings）**。

SDS 库（`src/sds.h` + `src/sds.c`）大约 1400 行，实现了 C 字符串的全部日常操作，同时做到了：

| 特性 | C 字符串 | SDS |
|------|----------|-----|
| 长度获取 | O(n) — `strlen()` 遍历 | O(1) — header 读出 |
| 二进制安全 | ❌ `\0` 截断 | ✅ len 字段记录长度 |
| 追加安全 | ❌ 缓冲区溢出 | ✅ 预分配 + 自动扩容 |
| 预分配 | ❌ | ✅ 小于 1MB 翻倍，大于 1MB 加 1MB |
| 内存复用 | ❌ `realloc` 逐个 | ✅ `sdsResize` / `sdsRemoveFreeSpace` |

本文从 `sds.h` 和 `sds.c` 源码出发，逐行解读 SDS 的数据结构设计、内存布局、扩容策略，以及与第一篇 `redisObject` 的配合。

---

## 1. sdshdr 五兄弟——类型选择与内存布局

SDS 的核心思想：**在字符串数据前放一个 header，记录元信息**。但不同大小的字符串不需要相同的 header 精度——5 位就能表示 32 字节以内的字符串，没必要用 64 位。

### 1.1 五大变体

`sds.h:47-73` 定义了五个 header 结构体，均以 `__attribute__((__packed__))` 修饰以消除对齐填充：

```c
// sds.h:47
struct __attribute__((__packed__)) sdshdr5 {
    unsigned char flags;          // 3 lsb = type=0, 5 msb = len（最多 31）
    char buf[];
};

// sds.h:51
struct __attribute__((__packed__)) sdshdr8 {
    uint8_t len;                  // 已用长度
    uint8_t alloc;                // 总分配（不含 header 和 null term）
    unsigned char flags;          // 3 lsb = type=1
    char buf[];
};

// sds.h:57
struct __attribute__((__packed__)) sdshdr16 {
    uint16_t len;
    uint16_t alloc;
    unsigned char flags;
    char buf[];
};

// sds.h:63
struct __attribute__((__packed__)) sdshdr32 {
    uint32_t len;
    uint32_t alloc;
    unsigned char flags;
    char buf[];
};

// sds.h:69
struct __attribute__((__packed__)) sdshdr64 {
    uint64_t len;
    uint64_t alloc;
    unsigned char flags;
    char buf[];
};
```

> **doom-lsp 验证**：`sds.h:51 sdshdr8` 跳转到定义 → `sds.h:51` ✓（类型定义为 struct tag）
> `sds.h:57 sdshdr16` → `sds.h:57` ✓

### 1.2 各变体的 header 大小

| type 常量 | 宏值 | header 结构 | 字段大小 | header 总字节 |
|-----------|------|-------------|----------|:------------:|
| `SDS_TYPE_5` | 0 | `sdshdr5` | 1 byte (flags) | **1** |
| `SDS_TYPE_8` | 1 | `sdshdr8` | 1+1+1 | **3** |
| `SDS_TYPE_16` | 2 | `sdshdr16` | 2+2+1 | **5** |
| `SDS_TYPE_32` | 3 | `sdshdr32` | 4+4+1 | **9** |
| `SDS_TYPE_64` | 4 | `sdshdr64` | 8+8+1 | **17** |

`sds.c:44-56` 的 `sdsHdrSize()` 函数将 type 映射到实际 `sizeof`：

```c
// sds.c:44
inline int sdsHdrSize(char type) {
    switch(type&SDS_TYPE_MASK) {
        case SDS_TYPE_5:  return sizeof(struct sdshdr5);   // = 1
        case SDS_TYPE_8:  return sizeof(struct sdshdr8);   // = 3
        case SDS_TYPE_16: return sizeof(struct sdshdr16);  // = 5
        case SDS_TYPE_32: return sizeof(struct sdshdr32);  // = 9
        case SDS_TYPE_64: return sizeof(struct sdshdr64);  // = 17
    }
    return 0;
}
```

> **注意**：`sdshdr5` 只有 `flags` 和 `buf[]`，没有独立的 `len` 和 `alloc` 字段。长度仅存于 flags 的高 5 位，最大 31 字节，且只能读取无法重新分配。`sds.c:103` 中 `sdsReqType()` 对空字符串直接跳过 type 5：`if (type == SDS_TYPE_5 && initlen == 0) type = SDS_TYPE_8;`

### 1.3 类型选择策略

`sds.c:60-65` 的 `sdsReqType()` 根据字符串长度选择最紧凑的 header：

```c
// sds.c:60
inline char sdsReqType(size_t string_size) {
    if (string_size < 1<<5)  return SDS_TYPE_5;   // < 32 → type 5
    if (string_size < 1<<8)  return SDS_TYPE_8;   // < 256 → type 8
    if (string_size < 1<<16) return SDS_TYPE_16;  // < 65536 → type 16
    if (string_size < 1<<32) return SDS_TYPE_32;  // < 4GB → type 32
    return SDS_TYPE_64;                           // >= 4GB → type 64
}
```

### 1.4 最大容量

`sds.c:73-82` 的 `sdsTypeMaxSize()` 限制了每种 type 能表达的最大分配大小。type 8 最大 255 字节，type 16 最大 65535，以此类推：

```c
// sds.c:73
static inline size_t sdsTypeMaxSize(char type) {
    if (type == SDS_TYPE_5)  return (1<<5) - 1;
    if (type == SDS_TYPE_8)  return (1<<8) - 1;
    if (type == SDS_TYPE_16) return (1<<16) - 1;
    if (type == SDS_TYPE_32) return (1ll<<32) - 1;
    return -1; // 64-bit max
}
```

---

## 2. sds 指针的魔法——负偏移 flags 读取

SDS 最巧妙的设计藏在 `sds.h:43` 的 typedef 里：

```c
// sds.h:43
typedef char *sds;
```

**sds 就是一个 `char*`**，但它**不指向开头**，而指向 header 之后的 `buf[]`。这使得 SDS 可以直接传递给 C 标准库函数（`printf`、`strcmp` 等），同时通过负偏移访问 header 元信息。

### 2.1 flags 读取——s[-1]

SDS header 的最后一个字段永远是 `unsigned char flags`。由于结构体按 `__packed__` 排列，flags 总是在 buf 的前一个字节：

```
内存布局 (type 8)：
 ┌──────┬──────┬───────┬──────────────┬──────┐
 │ len  │ alloc│ flags │ buf[...]     │ '\0' │
 └──────┴──────┴───────┴──────────────┴──────┘
                        ↑
                       sds 指针指向这里
```

因此：**`s[-1]` 就是 flags 字节**。

`sds.h:87-102` 的 `sdslen()` 展示了这个模式的完整实现：

```c
// sds.h:87
static inline size_t sdslen(const sds s) {
    unsigned char flags = s[-1];                       // ← 负偏移读 flags
    switch(flags&SDS_TYPE_MASK) {                      // 低 3 位 = type
        case SDS_TYPE_5:
            return SDS_TYPE_5_LEN(flags);              // 高 5 位编码长度
        case SDS_TYPE_8:
            return SDS_HDR(8,s)->len;                  // 通过 SDS_HDR 反算 header
        case SDS_TYPE_16:
            return SDS_HDR(16,s)->len;
        case SDS_TYPE_32:
            return SDS_HDR(32,s)->len;
        case SDS_TYPE_64:
            return SDS_HDR(64,s)->len;
    }
    return 0;
}
```

### 2.2 SDS_HDR 宏——从 sds 指针反算 header

`sds.h:83`：

```c
#define SDS_HDR(T,s) ((struct sdshdr##T *)((s)-(sizeof(struct sdshdr##T))))
```

这个宏将 sds 指针减去 header 大小，得到 header 起始地址。`sdsavail()`、`sdsalloc()` 等函数都用同一模式，以 `s` 为支点通过 `s[-1]` 获取 type 后 dispatch。

> **doom-lsp 验证**：`sds.h:87 sdslen` → `sds.h:87` 函数定义 ✓，内联函数无外部调用点（被编译到调用者的 IR 中）

---

## 3. 创建与销毁——sdsnewlen / sdsfree

### 3.1 sdsnewlen——统一构造入口

`sds.c:100-161` 的 `_sdsnewlen()` 是 SDS 创建的核心。我们逐行追踪关键路径：

```c
// sds.c:100
sds _sdsnewlen(const void *init, size_t initlen, int trymalloc) {
    void *sh;
    sds s;
    char type = sdsReqType(initlen);              // ← 选择最优 type (sds.c:60)
    if (type == SDS_TYPE_5 && initlen == 0)
        type = SDS_TYPE_8;                        // ← 空字符串强制用 type 8（可扩容）
    int hdrlen = sdsHdrSize(type);                // ← 计算 header 大小 (sds.c:44)
    unsigned char *fp;
    size_t usable;

    sh = trymalloc?
        s_trymalloc_usable(hdrlen+initlen+1, &usable) :  // 总分配 = hdr + data + '\0'
        s_malloc_usable(hdrlen+initlen+1, &usable);

    s = (char*)sh+hdrlen;                         // ← sds 指针指向 buf 开头
    fp = ((unsigned char*)s)-1;                   // ← flags 指针就是 s[-1]

    usable = usable-hdrlen-1;                     // allocator 实际可用大小（减 header 和 null）
    if (usable > sdsTypeMaxSize(type))
        usable = sdsTypeMaxSize(type);             // 不能超过 type 能表达的范围

    switch(type) {
        case SDS_TYPE_8: {
            SDS_HDR_VAR(8,s);
            sh->len = initlen;                    // 设置 len
            sh->alloc = usable;                   // 设置 alloc = 实际可用
            *fp = type;                            // 设置 flags
            break;
        }
        // ... 其他 type 同理
    }
    if (initlen && init)
        memcpy(s, init, initlen);                 // 拷贝数据
    s[initlen] = '\0';                            // 总是 null-terminated
    return s;
}
```

> **关键设计点**：
> 1. `usable` 来自 `s_malloc_usable`——jemalloc 实际分配的 chunksize 可能比请求大，SDS 把这个额外空间也纳入 `alloc` 字段（`sds.c:139-141`）。这意味着**首次分配就可能带 free 空间**。
> 2. 空字符串规避 type 5（`sds.c:103-104`）：type 5 没有 `alloc` 字段，无法追踪剩余空间，`sdsMakeRoomFor` 每次都会 realloc——空字符串往往要 append，所以直接跳到 type 8。

### 3.2 对外接口

| 函数 | 行号 | 说明 |
|------|:----:|------|
| `sdsnewlen()` | `223` | `_sdsnewlen(init, initlen, 0)` — 标准分配，分配失败 crash |
| `sdstrynewlen()` | `227` | `_sdsnewlen(init, initlen, 1)` — try 模式，分配失败返回 NULL |
| `sdsempty()` | `233` | `sdsnewlen("", 0)` — 创建空字符串 |
| `sdsnew()` | `238` | `sdsnewlen(init, strlen(init))` — 从 C 字符串创建 |
| `sdsdup()` | `244` | `sdsnewlen(s, sdslen(s))` — 深拷贝 |

### 3.3 sdsfree——提前释放决定 type

`sds.c:249` 的释放逻辑利用了 SDS 的 type 自描述能力：

```c
// sds.c:249
void sdsfree(sds s) {
    if (s == NULL) return;
    s_free((char*)s-sdsHdrSize(s[-1]));   // ← 通过 s[-1] 取得 type，计算 header 大小
}
```

`(char*)s - sdsHdrSize(s[-1])` 从 sds 指针反算到整个分配块的起始地址，然后 `s_free()`（实际是 Redis 的 `zfree`，sdsalloc.h:47）。不需要 caller 记住 type，不需要外部维护额外元信息。

---

## 4. 预分配策略——sdsMakeRoomFor

这是 SDS 性能的核心。`sds.c:294-347` 的 `_sdsMakeRoomFor()` 实现了 Redis 的增量扩容策略。

```c
// sds.c:294
sds _sdsMakeRoomFor(sds s, size_t addlen, int greedy) {
    void *sh, *newsh;
    size_t avail = sdsavail(s);
    size_t len, newlen;
    char type, oldtype = s[-1] & SDS_TYPE_MASK;
    int hdrlen;

    if (avail >= addlen) return s;              // ← 已有空间，直接返回

    len = sdslen(s);
    sh = (char*)s-sdsHdrSize(oldtype);
    newlen = (len+addlen);

    if (greedy == 1) {
        if (newlen < SDS_MAX_PREALLOC)          // SDS_MAX_PREALLOC = 1MB (sds.h:36)
            newlen *= 2;                         // ← 翻倍增长
        else
            newlen += SDS_MAX_PREALLOC;          // ← 线性增长（每次只加 1MB）
    }

    type = sdsReqType(newlen);
    if (type == SDS_TYPE_5) type = SDS_TYPE_8;   // ← 再次规避 type 5
```

### 4.1 翻倍 vs 线性增长

`SDS_MAX_PREALLOC` 定义在 `sds.h:36`：

```c
#define SDS_MAX_PREALLOC (1024*1024)  // 1MB
```

扩容公式：

| 当前长度 | 扩容策略 | 示例 |
|----------|----------|------|
| < 1MB | `newlen *= 2` | 100B → 200B → 400B → ... |
| ≥ 1MB | `newlen += 1MB` | 2MB → 3MB → 4MB → ... |

这在实践中意味着：如果你的字符串从空开始持续追加，前 20 次追加才从 0 增长到 ~1MB（指数爆炸），之后每次只加 1MB。**小字符串快速扩张减少 realloc 次数，大字符串避免浪费数十 MB 的冗余空间。**

### 4.2 同 type / 跨 type 扩容

`_sdsMakeRoomFor` 的另一个精巧之处在于处理 header type 变化：

```c
// sds.c:321
    if (oldtype==type) {
        // type 不变：直接 realloc（header 大小不变）
        newsh = s_realloc_usable(sh, hdrlen+newlen+1, &usable);
        s = (char*)newsh+hdrlen;
    } else {
        // type 变：header 大小变了，无法 in-place realloc
        // 需要 malloc + memcpy + free
        newsh = s_malloc_usable(hdrlen+newlen+1, &usable);
        memcpy((char*)newsh+hdrlen, s, len+1);  // 拷贝数据 + null term
        s_free(sh);                               // 释放旧内存
        s = (char*)newsh+hdrlen;
        s[-1] = type;                             // 写入新 type
        sdssetlen(s, len);                        // 设置新 len
    }

    usable = usable-hdrlen-1;
    if (usable > sdsTypeMaxSize(type))
        usable = sdsTypeMaxSize(type);
    sdssetalloc(s, usable);                       // 设置 alloc = jemalloc 实际可用
    return s;
```

> **重要设计**：`s_malloc_usable` / `s_realloc_usable` 返回 jemalloc 实际分配的可用大小。SDS 不是用请求的大小来设 `alloc`，而是用**实际得到的大小**。这意味着 jemalloc 的 arena 对齐特性会被 SDS 自动利用——你可以免费获得几个字节的额外空间。

`sdsMakeRoomFor()`（`sds.c:349`）和 `sdsMakeRoomForNonGreedy()`（`sds.c:354`）只是 `_sdsMakeRoomFor` 的 greedy 开关包装：

```c
// sds.c:349
sds sdsMakeRoomFor(sds s, size_t addlen) {
    return _sdsMakeRoomFor(s, addlen, 1);   // greedy=1：翻倍/加 1MB
}

// sds.c:354
sds sdsMakeRoomForNonGreedy(sds s, size_t addlen) {
    return _sdsMakeRoomFor(s, addlen, 0);   // greedy=0：刚好够用
}
```

### 4.3 sdsResize——双向调整

`sds.c:377` 的 `sdsResize()` 可以增大或缩小分配；缩小会截断数据（`truncate`）。还考虑了 jemalloc 的 `nallocx` 优化——当目标长度不改变 jemalloc 的实际 allocation size 时，跳过 `realloc()` 调用：

```c
// sds.c:418
#if defined(USE_JEMALLOC)
    alloc_already_optimal = (je_nallocx(newlen, 0) == zmalloc_size(sh));
#endif
```

---

## 5. 常用 API 一览

### 5.1 追加系列

| 函数 | 行号 | 说明 |
|------|:----:|------|
| `sdscatlen(s, t, len)` | `540` | 追加指定长度二进制安全数据 |
| `sdscat(s, t)` | `555` | 追加 C 字符串（`strlen` 取长度） |
| `sdscatsds(s, t)` | `563` | 追加另一个 sds（长度从 header 取） |
| `sdscatprintf(s, fmt, ...)` | `732` | printf 风格格式化追加 |
| `sdscatfmt(s, fmt, ...)` | `757` | 快速格式化（不支持完整 printf，但更快） |

**sdscatlen 实现** `sds.c:540`：

```c
sds sdscatlen(sds s, const void *t, size_t len) {
    size_t curlen = sdslen(s);              // O(1)
    s = sdsMakeRoomFor(s, len);             // 确保有空间（可能 realloc）
    memcpy(s+curlen, t, len);               // 直接 memcpy
    sdssetlen(s, curlen+len);               // 更新 len
    s[curlen+len] = '\0';                   // 保持 null-terminate
    return s;                               // 返回 s（可能地址变了！）
}
```

**⚠️ 关键 API 语义**：所有 SDS 修改函数（`sdscat*`、`sdscpy*`、`sdstrim` 等）都可能因 **realloc** 而改变 sds 指针自身。调用者**必须**使用返回值更新自己的引用：

```c
// ❌ 错误用法：s 可能已变成悬垂指针
sdscat(s, "hello");
printf("%s", s);  // BUG: realloc 后 s 可能已释放

// ✅ 正确用法：用返回值更新
s = sdscat(s, "hello");
```

### 5.2 裁剪系列

| 函数 | 行号 | 说明 |
|------|:----:|------|
| `sdstrim(s, cset)` | `866` | 去掉两端的 cset 字符，**memmove** 就位 |
| `sdssubstr(s, start, len)` | `884` | 截取子串，**memmove** 就位 |
| `sdsrange(s, start, end)` | `917` | 区间截取，支持负数索引；内部调 `sdssubstr` |

**sdstrim 实现细节** `sds.c:866-880`：

```c
sds sdstrim(sds s, const char *cset) {
    char *sp = s;
    char *ep = s + sdslen(s) - 1;
    while(sp <= end && strchr(cset, *sp)) sp++;    // 从左扫描可删字符
    while(ep > sp && strchr(cset, *ep)) ep--;      // 从右扫描可删字符
    len = (ep-sp)+1;
    if (s != sp) memmove(s, sp, len);               // 非原位则 memmove
    s[len] = '\0';
    sdssetlen(s, len);
    return s;
}
```

**不释放空间**：`sdstrim` 和 `sdssubstr` 只移动数据和更新 `len`，不缩小 `alloc`。如果需要回收空间，应调用 `sdsRemoveFreeSpace()`（`sds.c:364`）。

### 5.3 工具函数

| 函数 | 行号 | 说明 |
|------|:----:|------|
| `sdsfromlonglong(v)` | `667` | `long long` → sds，避免 `sprintf` |
| `sdscmp(s1, s2)` | `953` | `memcmp` 二进制安全比较 |
| `sdssplitlen(s, len, sep, seplen, &count)` | `981` | 分割字符串，返回 sds 数组 |
| `sdscatrepr(s, p, len)` | `1043` | 追加转义后的字符串表示（" 和 \\ 加反斜杠） |
| `sdsjoin(argv, argc, sep)` | `1273` | C 字符串数组连接 |
| `sdsjoinsds(argv, argc, sep, seplen)` | `1285` | sds 数组连接 |

`sdsfromlonglong` 的实现 `sds.c:667-675` 展示了 SDS 如何避免 `sprintf` 的昂贵调用：

```c
sds sdsfromlonglong(long long value) {
    char buf[SDS_LLSTR_SIZE];           // SDS_LLSTR_SIZE = 21 (sds.c:625)
    int len = sdsll2str(buf, value);    // 手动数字→字符串，反转法
    return sdsnewlen(buf, len);
}
```

`sdsll2str()` 在 `sds.c:628-664`：通过反复除 10 取模构造倒序字符串，再反转——避免 `sprintf` 的格式化开销。这一优化在 Redis 的共享整数对象路径上（第一个 article 的 section 2.2）尤为重要。

---

## 6. SDS × robj——EMBSTR 的融合之美

第一篇介绍了 `redisObject`（`server.h:858`）的 16 字节设计。SDS 与 robj 的配合，在**嵌入式字符串对象（EMBSTR）**中达到了极致。

### 6.1 两种编码

`object.c:90-91` — RAW 编码：两段独立分配

```c
robj *createRawStringObject(const char *ptr, size_t len) {
    return createObject(OBJ_STRING, sdsnewlen(ptr,len));
    // robj: zmalloc(16)     ← 一个分配
    // sds:  s_malloc(hdrlen+len+1)  ← 另一个分配
}
```

`object.c:97-118` — EMBSTR 编码：一次性分配

```c
robj *createEmbeddedStringObject(const char *ptr, size_t len) {
    robj *o = zmalloc(sizeof(robj) + sizeof(struct sdshdr8) + len + 1);
    //             ^ 16          ^ 3             ^ len  ^ '\0'
    struct sdshdr8 *sh = (void*)(o+1);
    o->type = OBJ_STRING;
    o->encoding = OBJ_ENCODING_EMBSTR;
    o->ptr = sh+1;                     // sds 指针 = robj + 16 + 3 = 偏移 19
    o->refcount = 1;
    // ... LRU/LFU 初始化 ...

    sh->len = len;
    sh->alloc = len;                   // 嵌入式字符串不可修改，alloc = len
    sh->flags = SDS_TYPE_8;            // 固定 type 8
    memcpy(sh->buf, ptr, len);
    sh->buf[len] = '\0';
    return o;
}
```

**内存布局**（len = 44 时完美适配 jemalloc 64B arena）：

```
[jemalloc 64B chunk]
┌──────────┬─────────┬───────────────────────────────────────┐
│ robj     │ sdshdr8 │ buf[44] + '\0'                       │
│ (16B)    │ (3B)    │                                       │
└──────────┴─────────┴───────────────────────────────────────┘
↑           ↑         ↑
zmalloc      o+1      o->ptr = sh+1
返回地址
```

### 6.2 EMBSTR_SIZE_LIMIT = 44 的数学

`object.c:131`：

```c
#define OBJ_ENCODING_EMBSTR_SIZE_LIMIT 44
```

为什么是 44？

```
sizeof(robj)  + sizeof(sdshdr8) + len + 1  ≤ 64（jemalloc 最小 arena）
    16        +       3        + len + 1   ≤ 64
                              len          ≤ 44
```

**jemalloc 的 64 字节 arena 是最小分配单元**。`zmalloc(16+3+44+1) = zmalloc(64)` 恰好填满一个 slab slot。任何小于 44 字节的字符串都享用这个零碎开销分配。大于 44 则无法一 malloc 装下全部，fallback 到两段分配的 RAW。

### 6.3 EMBSTR vs RAW 的实际差异

| 维度 | RAW | EMBSTR |
|------|-----|--------|
| 分配次数 | `zmalloc` + `s_malloc` = 2 | `zmalloc` = 1 |
| 缓存局部性 | robj 和 buf 在两个 cacheline | 连续内存，**1 个 cacheline** |
| 可修改性 | 可追加/修改（有独立 alloc） | **只读**（`o->ptr` 不可写） |
| 适用字符串 | > 44 字节 | ≤ 44 字节 |
| 释放 | `zfree(robj)` + `s_free(sds)` 两次 | 一次 `zfree` 整块 |

`createStringObject()` 在 `object.c:133-138` 根据长度选择：

```c
robj *createStringObject(const char *ptr, size_t len) {
    if (len <= OBJ_ENCODING_EMBSTR_SIZE_LIMIT)
        return createEmbeddedStringObject(ptr, len);
    else
        return createRawStringObject(ptr, len);
}
```

### 6.4 释放的歧路

`object.c:301-309` — `freeStringObject()` 宏（在 `server.h` 中定义）：

当 encoding 为 RAW 时，需要 `sdsfree(o->ptr)` 释放 SDS（独立的 alloc）；当 encoding 为 EMBSTR 时，SDS 和 robj 在同一块内存中，不需要单独释放——整个块随 `zfree(o)` 释放。

```c
// object.c:304-305
if (o->encoding == OBJ_ENCODING_RAW) {
    sdsfree(o->ptr);      // RAW: 释放独立的 SDS 分配
}
// EMBSTR: o->ptr 指向同一块内存内的偏移，不需要额外释放
```

> **doom-lsp 验证**：`object.c:304` 的 `sdsfree` → 跳转到 `sds.c:249` ✓
> `object.c:305` 的 `o->ptr` → `server.h:865` robj 的 ptr 字段 ✓

---

## 7. allocator 层

SDS 通过 `sdsalloc.h`（仅 22 行）将内存分配委托给 Redis 的 `zmalloc`：

```c
// sdsalloc.h:43-52
#define s_malloc            zmalloc
#define s_realloc           zrealloc
#define s_free              zfree
#define s_malloc_usable     zmalloc_usable
#define s_realloc_usable    zrealloc_usable
#define s_trymalloc_usable  ztrymalloc_usable
```

这种间接层有两大好处：
1. **统一统计**：所有 SDS 分配都通过 `zmalloc`，被计入 `used_memory`，受 `maxmemory` 限制
2. **jemalloc 感知**：`*_usable` 系列函数返回 jemalloc 的实际分配大小，SDS 利用这个超额空间减少 realloc

外部暴露了三个包装函数（`sds.c:1301-1303`），供其他模块（如 hiredis 客户端）直接使用 SDS 的 allocator：

```c
void *sds_malloc(size_t size)   { return s_malloc(size); }
void *sds_realloc(void *ptr, size_t size) { return s_realloc(ptr,size); }
void sds_free(void *ptr)           { s_free(ptr); }
```

---

## 8. 内存布局总览

一个 100 字节的 SDS 字符串（type 8）的完整内存布局：

```
Heap (actual from jemalloc arena):
┌─────┬──────┬───────┬────────────────────────────────────────────┬────────┐
│ len │ alloc│ flags │              buf[100]                      │  '\0'  │
│  1  │  100 │  0x01 │  'R' 'e' 'd' 'i' 's' ... 's' 'd' 's'     │   0    │
│  1B │  1B  │  1B   │                 100B                       │   1B   │
└─────┴──────┴───────┴────────────────────────────────────────────┴────────┘
↑                        ↑
sh(sdshdr8*)             s(sds) = sh + 3
```

SDS 不存储指向自己的指针——**caller 保存的是 `buf[]` 的地址**。所有元信息通过负偏移 `s[-1]` 获取。

---

## 9. 源码索引

本文涉及的所有源代码位置汇总：

| 文件 | 行号 | 符号 | 说明 |
|------|:----:|------|------|
| `sds.h` | `36` | `SDS_MAX_PREALLOC` | 预分配阈值 1MB |
| `sds.h` | `43` | `sds` | `typedef char *sds` |
| `sds.h` | `47` | `sdshdr5` | type 5 header（实际不用于分配） |
| `sds.h` | `51` | `sdshdr8` | type 8 header（uint8_t len/alloc） |
| `sds.h` | `57` | `sdshdr16` | type 16 header（uint16_t len/alloc） |
| `sds.h` | `63` | `sdshdr32` | type 32 header（uint32_t len/alloc） |
| `sds.h` | `69` | `sdshdr64` | type 64 header（uint64_t len/alloc） |
| `sds.h` | `78` | `SDS_TYPE_MASK` | `7` — 低 3 位取 type |
| `sds.h` | `83` | `SDS_HDR(T,s)` | 从 sds 指针反算 header 地址 |
| `sds.h` | `87` | `sdslen` | O(1) 长度获取 |
| `sds.h` | `104` | `sdsavail` | 剩余空间 |
| `sds.h` | `130` | `sdssetlen` | 设置长度 |
| `sds.h` | `180` | `sdsalloc` | 总分配大小 |
| `sds.h` | `197` | `sdssetalloc` | 设置总分配 |
| `sds.h` | `249` | `sdsfree` | 释放 |
| `sds.c` | `44` | `sdsHdrSize` | type → header 字节数 |
| `sds.c` | `60` | `sdsReqType` | 字符串长度 → 最优 type |
| `sds.c` | `73` | `sdsTypeMaxSize` | type 能表达的最大大小 |
| `sds.c` | `100` | `_sdsnewlen` | 统一创建（核心） |
| `sds.c` | `223` | `sdsnewlen` | 标准创建 |
| `sds.c` | `227` | `sdstrynewlen` | try 模式创建 |
| `sds.c` | `233` | `sdsempty` | 创建空字符串 |
| `sds.c` | `238` | `sdsnew` | 从 C 字符串创建 |
| `sds.c` | `244` | `sdsdup` | 复制 |
| `sds.c` | `249` | `sdsfree` | 释放 |
| `sds.c` | `294` | `_sdsMakeRoomFor` | 扩容核心 |
| `sds.c` | `349` | `sdsMakeRoomFor` | 预分配扩容 |
| `sds.c` | `354` | `sdsMakeRoomForNonGreedy` | 精确扩容 |
| `sds.c` | `364` | `sdsRemoveFreeSpace` | 去除多余空间 |
| `sds.c` | `377` | `sdsResize` | 调整大小 |
| `sds.c` | `442` | `sdsAllocSize` | 总分配大小（含 header） |
| `sds.c` | `449` | `sdsAllocPtr` | 分配块起始地址 |
| `sds.c` | `476` | `sdsIncrLen` | 增量调整长度 |
| `sds.c` | `540` | `sdscatlen` | 按长度追加 |
| `sds.c` | `555` | `sdscat` | 追加 C 字符串 |
| `sds.c` | `563` | `sdscatsds` | 追加 sds |
| `sds.c` | `667` | `sdsfromlonglong` | long long → sds |
| `sds.c` | `866` | `sdstrim` | 裁剪两端 |
| `sds.c` | `884` | `sdssubstr` | 截取子串 |
| `sds.c` | `953` | `sdscmp` | 二进制安全比较 |
| `sds.c` | `981` | `sdssplitlen` | 分割字符串 |
| `sds.c` | `1043` | `sdscatrepr` | 转义表示 |
| `sds.c` | `1273` | `sdsjoin` | 连接 C 字符串数组 |
| `sds.c` | `1285` | `sdsjoinsds` | 连接 sds 数组 |
| `sds.c` | `1301` | `sds_malloc` | allocator 对外暴露 |
| `sds.c` | `1311` | `sdstemplate` | 模板替换 |
| `sdsalloc.h` | `43` | `s_malloc` | → `zmalloc` |
| `sdsalloc.h` | `47` | `s_free` | → `zfree` |
| `object.c` | `90` | `createRawStringObject` | 两段分配 |
| `object.c` | `97` | `createEmbeddedStringObject` | 单分配 EMBSTR |
| `object.c` | `131` | `OBJ_ENCODING_EMBSTR_SIZE_LIMIT` | 44 阈值 |
| `object.c` | `133` | `createStringObject` | 根据长度选择编码 |
| `server.h` | `858` | `redisObject` | robj 结构体 |

---

## 10. 总结

SDS 是 Redis 字符串的基石，其设计围绕着三个核心诉求：

1. **O(1) 长度获取** — 通过 header 存储 `len`，用 `s[-1]` 取 type 后 dispatch
2. **二进制安全** — `len` 字段独立于 `\0`，数据可以包含任意字节
3. **预分配减少 realloc** — 翻倍增长 + jemalloc usable size 感知

与 `redisObject` 配合时，EMBSTR 编码通过一次性 `zmalloc` 将 robj、sdshdr8、buf 放在同一块内存中，完美适配 jemalloc 64 字节 arena——这是 Redis 将"小字符串"场景优化到极致的设计。

> **下一篇预告**：03 — dict：Redis 哈希表的渐进式 rehash 与增量迁移
