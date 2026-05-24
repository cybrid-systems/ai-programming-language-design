# 10 — RDB：Redis 的二进制序列化格式

> Redis 主线源码深度分析系列 · 第十篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

RDB（Redis Database）是 Redis 的**全量快照持久化**格式——将内存中的所有数据结构序列化为一个紧凑的二进制文件。它是 Redis 数据模型的完整映射：前 9 篇文章讲的每一种编码在 RDB 中都有对应的序列化路径。

RDB 的设计目标：
- **紧凑**：利用整数编码、LZF 压缩、紧凑数据结构本身的性质（listpack/intset 二进制兼容）
- **快**：写时复制子进程（fork 后由子进程序列化，主线程不阻塞）
- **可校验**：CRC64 校验和 + 每字段长度前缀

**doom-lsp 确认**：核心文件

| 文件 | 行数 | 职责 |
|------|:----:|------|
| `src/rdb.h` | 179 | 类型常量 + API 声明 |
| `src/rdb.c` | 3587 | RDB 写入/读取/加载全实现 |
| `src/rio.h/c` | — | 抽象 I/O 层（文件/缓冲区/网络） |

---

## 1. RDB 文件格式总览

```
┌─────────────────────────────────────────────┐
│  MAGIC: "REDIS0009" (9B)                    │  RDB 版本
├─────────────────────────────────────────────┤
│  AUX FIELDS (多个)                          │
│  例: redis-ver=7.0.15, redis-bits=64, ...   │
├─────────────────────────────────────────────┤
│  FUNCTION 库数据 (可选)                     │
├─────────────────────────────────────────────┤
│  SELECTDB (opcode=254) + DB_NUMBER          │  → DB 0
│  RESIZEDB (opcode=251) + hashtable_sizes    │  resize hint
│  EXPIRETIME_MS (opcode=252) + IDLE/FREQ     │  (可选 per key)
│  RDB_TYPE + KEY + VALUE                     │  → 键值对
│  ...                                        │  (循环直到 DB 结束)
│  SELECTDB (opcode=254) + DB_NUMBER          │  → DB 1
│  ...                                        │
├─────────────────────────────────────────────┤
│  EOF (opcode=255)                           │
├─────────────────────────────────────────────┤
│  CRC64 (8B, big-endian)                     │  校验和
└─────────────────────────────────────────────┘
```

### 1.1 类型编码

RDB 定义了一套独立于内存编码的**磁盘类型编号**（`rdb.h:48-80`）：

```c
#define RDB_TYPE_STRING 0
#define RDB_TYPE_LIST   1
#define RDB_TYPE_SET    2
#define RDB_TYPE_ZSET   3
#define RDB_TYPE_HASH   4
#define RDB_TYPE_ZSET_2 5  /* double 以二进制格式存储 */
#define RDB_TYPE_MODULE 6
#define RDB_TYPE_MODULE_2 7

/* 紧凑编码类型 */
#define RDB_TYPE_HASH_ZIPMAP    9    /* 已废弃 */
#define RDB_TYPE_LIST_ZIPLIST  10    /* 已废弃 */
#define RDB_TYPE_SET_INTSET    11
#define RDB_TYPE_ZSET_ZIPLIST  12    /* 已废弃 */
#define RDB_TYPE_HASH_ZIPLIST  13    /* 已废弃 */
#define RDB_TYPE_LIST_QUICKLIST 14
#define RDB_TYPE_STREAM_LISTPACKS 15
#define RDB_TYPE_HASH_LISTPACK 16
#define RDB_TYPE_ZSET_LISTPACK 17
#define RDB_TYPE_LIST_QUICKLIST_2   18
#define RDB_TYPE_STREAM_LISTPACKS_2 19
```

**磁盘类型 ≠ 内存类型**。磁盘类型区分编码（listpack vs ht, intset vs ht），以便加载时直接恢复原始编码，无需额外的编码检测。

---

## 2. RDB 保存——rdbSave

### 2.1 rdbSave——写文件

```c
// rdb.c:1396 — doom-lsp 确认
int rdbSave(int req, char *filename, rdbSaveInfo *rsi) {
    // 1. 写临时文件
    snprintf(tmpfile, 256, "temp-%d.rdb", (int)getpid());
    fp = fopen(tmpfile, "w");
    rioInitWithFile(&rdb, fp);
    startSaving(RDBFLAGS_NONE);

    // 2. 序列化
    rdbSaveRio(req, &rdb, &error, RDBFLAGS_NONE, rsi);

    // 3. 原子 rename
    fclose(fp);
    rename(tmpfile, filename);
    stopSaving(1);
    return C_OK;
}
```

**临时文件 + rename**：先写 `temp-<pid>.rdb`，完成后原子 rename 为最终文件。如果写过程中崩溃，不会留下半成品。

### 2.2 rdbSaveBackground——子进程方式

```c
// rdb.c:1469 — doom-lsp 确认
int rdbSaveBackground(int req, char *filename, rdbSaveInfo *rsi) {
    pid_t childpid;

    if ((childpid = redisFork()) == 0) {
        // 子进程：继承父进程内存快照（COW）
        int retval = rdbSave(req, filename, rsi);
        exitFromChild((retval == C_OK) ? 0 : 1);
    }
    // 父进程：继续服务
    server.rdb_child_pid = childpid;
    // updateDictResizePolicy() 会设置 DICT_RESIZE_AVOID
    // → 子进程期间避免 dict 扩容（减少 COW 内存页复制）
}
```

**Copy-on-Write**：fork 后子进程拥有父进程的内存快照。父子进程共享物理内存页，只有当父进程修改数据时才复制。这意味着 `BGSAVE` 期间 Redis 仍然可以处理写入，只是写入会触发 COW 页面复制。

### 2.3 rdbSaveRio——序列化循环

```c
// rdb.c:1326 — doom-lsp 确认
int rdbSaveRio(int req, rio *rdb, int *error, int rdbflags, rdbSaveInfo *rsi) {
    char magic[10];

    // 1. Magic: "REDIS" + 4 位版本号
    snprintf(magic, sizeof(magic), "REDIS%04d", RDB_VERSION);  // RDB_VERSION=10
    rdbWriteRaw(rdb, magic, 9);

    // 2. Aux 字段
    rdbSaveInfoAuxFields(rdb, rdbflags, rsi);

    // 3. 函数库数据
    rdbSaveFunctions(rdb);

    // 4. 遍历所有 DB
    for (j = 0; j < server.dbnum; j++)
        rdbSaveDb(rdb, j, rdbflags, &key_counter);

    // 5. EOF
    rdbSaveType(rdb, RDB_OPCODE_EOF);

    // 6. CRC64 校验和
    cksum = rdb->cksum;
    memrev64ifbe(&cksum);
    rioWrite(rdb, &cksum, 8);
}
```

### 2.4 rdbSaveDb——保存一个 DB

```c
// rdb.c 内部 — rdbSaveDb
static void rdbSaveDb(rio *rdb, int dbid, int rdbflags, long *key_counter) {
    // 1. SELECTDB opcode + DB 编号
    rdbSaveType(rdb, RDB_OPCODE_SELECTDB);
    rdbSaveLen(rdb, dbid);

    // 2. RESIZEDB hint：dict 大小 + 过期键数量
    //    帮助加载时预分配，避免多次 rehash
    rdbSaveType(rdb, RDB_OPCODE_RESIZEDB);
    rdbSaveLen(rdb, dictSlots(d));
    rdbSaveLen(rdb, dictSize(expires));

    // 3. 遍历 dict，写每个 key-value
    dictIterator *di = dictGetIterator(d);
    while ((de = dictNext(di)) != NULL) {
        sds keystr = dictGetKey(de);
        robj *key = createStringObject(keystr, sdslen(keystr));
        robj *val = dictGetVal(de);

        // 写过期时间
        expire = getExpire(db, key);
        rdbSaveKeyValuePair(rdb, key, val, expire, dbid);
        decrRefCount(key);
    }
}
```

**RESIZEDB hint**：告诉加载器数据库 dict 和 expires dict 的大小，`dictExpand` 预分配桶数，避免加载时多次渐进式 rehash。

### 2.5 rdbSaveKeyValuePair——写单个键值对

```c
// rdb.c:1091 — doom-lsp 确认
int rdbSaveKeyValuePair(rio *rdb, robj *key, robj *val,
                        long long expiretime, int dbid)
{
    // 1. 过期时间（毫秒精度）
    if (expiretime != -1) {
        rdbSaveType(rdb, RDB_OPCODE_EXPIRETIME_MS);
        rdbSaveMillisecondTime(rdb, expiretime);
    }

    // 2. LRU / LFU 信息（用于加载时恢复淘汰状态）
    if (savelru)
        rdbSaveType(rdb, RDB_OPCODE_IDLE);
        rdbSaveLen(rdb, estimateObjectIdleTime(val));
    if (savelfu)
        rdbSaveType(rdb, RDB_OPCODE_FREQ);
        rdbSaveLen(rdb, val->lru & 255);

    // 3. 对象类型编码
    rdbSaveObjectType(rdb, val);

    // 4. Key 字符串
    rdbSaveStringObject(rdb, key);

    // 5. Value（按类型分派）
    rdbSaveObject(rdb, val, key, dbid);
}
```

### 2.6 rdbSaveObject——按类型分派序列化

核心的序列化分派函数（`rdb.c:797`）为每种类型做了专门处理：

| 类型 | RDB 编码 | 序列化方式 |
|------|---------|-----------|
| STRING | `RDB_TYPE_STRING` | 整数编码尝试 → LZF 压缩 → 裸存长度+数据 |
| LIST | `RDB_TYPE_LIST_QUICKLIST_2` | 遍历 quicklistNode，每个节点存 container 类型 + 裸数据或 LZF 压缩数据 |
| SET (HT) | `RDB_TYPE_SET` | 存元素数 N + N 个 sds |
| SET (intset) | `RDB_TYPE_SET_INTSET` | 直接 dump 整个 intset blob |
| ZSET (skiplist) | `RDB_TYPE_ZSET_2` | 从 tail 开始反向存（加载时插头，O(1)），element + binary double |
| ZSET (listpack) | `RDB_TYPE_ZSET_LISTPACK` | 直接 dump 整个 listpack blob |
| HASH (HT) | `RDB_TYPE_HASH` | 存 field 数 N + N 对 field/value |
| HASH (listpack) | `RDB_TYPE_HASH_LISTPACK` | 直接 dump 整个 listpack blob |
| STREAM | `RDB_TYPE_STREAM_LISTPACKS_2` | 遍历 rax，存每个 rax key + listpack + stream 元信息 + 消费者组 |
| MODULE | `RDB_TYPE_MODULE_2` | 模块 ID → 调用模块的 `rdb_save` 回调 |

**反向遍历 skiplist**（`rdb.c:870`）：

```c
// ZSET 从 tail 开始反向遍历，按 score 降序存储
zskiplistNode *zn = zsl->tail;
while (zn != NULL) {
    rdbSaveRawString(rdb, zn->ele, sdslen(zn->ele));
    rdbSaveBinaryDoubleValue(rdb, zn->score);
    zn = zn->backward;
}
```

加载时从前往后逐个插入 skiplist 头部，每个插入 O(1)。如果用正向顺序，每次插入 skiplist 都要 O(log N) 定位。

### 2.7 字符串的三级序列化

`rdbSaveRawString`（`rdb.c:434`）有三种策略：

```c
// rdb.c:434 — doom-lsp 确认
ssize_t rdbSaveRawString(rio *rdb, unsigned char *s, size_t len) {
    // 策略 1：整数编码（长度 ≤ 11）
    if (len <= 11) {
        enclen = rdbTryIntegerEncoding((char*)s, len, buf);
        if (enclen > 0) return rdbWriteRaw(rdb, buf, enclen);
    }

    // 策略 2：LZF 压缩（长度 > 20 且开启压缩）
    if (server.rdb_compression && len > 20) {
        n = rdbSaveLzfStringObject(rdb, s, len);
        if (n > 0) return n;
    }

    // 策略 3：裸存（长度前缀 + 原始数据）
    rdbSaveLen(rdb, len);
    rdbWriteRaw(rdb, s, len);
}
```

```
"12345" → 整数编码 (1~5 字节，取决于值范围)
"aaaaaaaaaaaaaaaaaaaaaaaaaa" (26个a) → LZF 压缩
普通长字符串 → 长度前缀 + 裸存
```

**整数编码格式**（`rdbTryIntegerEncoding` / `rdbEncodeInteger`）：

```
RDB_ENCVAL (11|xxxxxx) + RDB_ENC_INT8  → 1B 编码前缀 + 1B 有符号整数
RDB_ENCVAL (11|xxxxxx) + RDB_ENC_INT16 → 1B 编码前缀 + 2B 有符号整数 (big-endian)
RDB_ENCVAL (11|xxxxxx) + RDB_ENC_INT32 → 1B 编码前缀 + 4B 有符号整数 (big-endian)
```

---

## 3. RDB 加载——rdbLoad

### 3.1 rdbLoadRio——反序列化循环

```c
// rdb.c:2888 — doom-lsp 确认
int rdbLoadRio(rio *rdb, int rdbflags, rdbSaveInfo *rsi) {
    // 1. 校验 MAGIC + 版本号
    if (rioRead(rdb, magic, 9) == 0) goto eoferr;
    if (memcmp(magic, "REDIS", 5) != 0) {
        serverLog(LL_WARNING, "Wrong signature trying to load DB from file");
        return C_ERR;
    }
    rdbver = atoi(magic+5);
    if (rdbver < 1 || rdbver > RDB_VERSION) { ... }

    // 2. 循环解析 opcode
    while (1) {
        int type;
        if ((type = rdbLoadType(rdb)) == -1) goto eoferr;

        switch(type) {
        case RDB_OPCODE_EXPIRETIME_MS:
            // 读毫秒过期时间
            expiretime = rdbLoadMillisecondTime(rdb, rdbver);
            break;
        case RDB_OPCODE_EXPIRETIME:
            // 读秒级过期时间（旧格式）
            expiretime = rdbLoadTime(rdb) * 1000;
            break;
        case RDB_OPCODE_IDLE:
            // LRU idle time
            lru_idle = rdbLoadLen(rdb, NULL);
            break;
        case RDB_OPCODE_FREQ:
            // LFU counter
            lru_freq = rdbLoadLen(rdb, NULL);
            break;
        case RDB_OPCODE_AUX:
            // Aux 元数据字段
            rdbLoadAux(rdb, rdbver);
            break;
        case RDB_OPCODE_RESIZEDB:
            // resize hint
            db_size = rdbLoadLen(rdb, NULL);
            expires_size = rdbLoadLen(rdb, NULL);
            break;
        case RDB_OPCODE_SELECTDB:
            // 切换到指定 DB
            dbid = rdbLoadLen(rdb, NULL);
            // 预分配 dict
            if (db_size) dictExpand(d->dict, db_size);
            if (expires_size) dictExpand(d->expires, expires_size);
            break;
        case RDB_OPCODE_EOF:
            // 文件结束
            goto readkey;
        case RDB_OPCODE_MODULE_AUX:
            // 模块辅助数据
            break;
        default:
            // ★ 普通键值对（type = RDB_TYPE_*）
            // 读 key
            key = rdbLoadStringObject(rdb);
            // 读 value
            val = rdbLoadObject(type, rdb, key->ptr, dbid, &error);
            // 设置过期/LRU/LFU
            if (expiretime != -1) setExpire(c, db, key, expiretime);
            // dictAdd / hashtableAdd 插入 DB
            dbAdd(db, key, val);
            break;
        }
    }
}
```

### 3.2 rdbLoadObject——按类型反序列化

`rdbLoadObject`（`rdb.c` 中约 400 行）是加载器的核心，为每个 `RDB_TYPE_*` 做对应的反序列化：

```c
// rdb.c — rdbLoadObject 伪代码
robj *rdbLoadObject(int rdbtype, rio *rdb, sds key, int dbid, int *error) {
    switch(rdbtype) {
    case RDB_TYPE_STRING:
        return rdbLoadStringObject(rdb);

    case RDB_TYPE_SET_INTSET:
        // 读 intset 裸数据 blob
        ds = rdbGenericLoadStringObject(rdb, RDB_LOAD_PLAIN, NULL);
        o = createObject(OBJ_SET, ds);
        o->encoding = OBJ_ENCODING_INTSET;
        return o;

    case RDB_TYPE_SET:
        // 读 N 个元素，检查是否能用 intset
        // 如果全部是整数且 N ≤ set_max_intset_entries → intset
        // 否则 → HT
        len = rdbLoadLen(rdb, NULL);
        while (len--) {
            ele = rdbGenericLoadStringObject(rdb, RDB_LOAD_SDS, NULL);
            setTypeAdd(o, ele);
        }
        return o;

    case RDB_TYPE_ZSET_LISTPACK:
        // 直接加载 listpack blob
        ds = rdbGenericLoadStringObject(rdb, RDB_LOAD_PLAIN, NULL);
        o = createObject(OBJ_ZSET, ds);
        o->encoding = OBJ_ENCODING_LISTPACK;
        return o;

    case RDB_TYPE_ZSET_2:
        // 逐元素插入 skiplist + dict
        zset *zs = zmalloc(sizeof(*zs));
        zs->dict = dictCreate(&zsetDictType);
        zs->zsl = zslCreate();
        len = rdbLoadLen(rdb, NULL);
        while (len--) {
            ele = rdbGenericLoadStringObject(rdb, RDB_LOAD_SDS, NULL);
            rdbLoadBinaryDoubleValue(rdb, &score);
            znode = zslInsert(zs->zsl, score, ele);  // O(1) 头插
            dictAdd(zs->dict, ele, &znode->score);
        }
        ...
    }
}
```

**加载时编码恢复**：RDB_TYPE_SET_INTSET 直接恢复为 intset；RDB_TYPE_SET 会检查是否所有元素都能编码为整数且数量 ≤ `set_max_intset_entries`，是则转为 intset。同样，listpack 编码的类型直接在 RDB 中保存 listpack 的二进制 blob，加载时无需转换。

---

## 4. RDB 的核心机制

### 4.1 RDB_VERSION 与向后兼容

```c
#define RDB_VERSION 10
```

RDB 类型编号是**永久固定的**——一旦分配就不会改变。新增类型必须分配新的 `RDB_TYPE_*` 编号（当前最高 `RDB_TYPE_STREAM_LISTPACKS_2` = 19）。旧的类型编号（如 `RDB_TYPE_HASH_ZIPLIST` = 13）不会被删除但不再写入，加载时兼容。

`rdbLoadObject` 通过 switch-case 处理所有历史版本的类型，包括已废弃的 ziplist 编码。

### 4.2 CRC64 校验

```c
// rdb.c:1370 — doom-lsp 确认
cksum = rdb->cksum;   // 累积校验值
memrev64ifbe(&cksum);  // 转 big-endian
rioWrite(rdb, &cksum, 8);
```

每次写入时 `rio` 层自动更新 CRC64 校验和。写完全文件后把校验和追加到末尾。加载同样走一遍 CRC64 计算，比对末尾的 8 字节，不一致则拒绝加载。

### 4.3 长度编码（rdbSaveLen）

RDB 的长度编码非常紧凑，通过首字节的高 2 位来区分（`rdb.h:18-34`）：

```
00|xxxxxx     → 6 位长度 (0~63)，1 字节
01|xxxxxx xxxxxxxx → 14 位长度 (0~16383)，2 字节
10|000000 [32bit] → 32 位长度，1B 前缀 + 4B
10|000001 [64bit] → 64 位长度，1B 前缀 + 8B
11|xxxxxx     → 后续 6 位表示特殊编码：INT8/INT16/INT32/LZF
```

大部分 key 长度 ≤ 63，所以多数 key 只需 1 字节编码。

```c
// rdb.c:164 — doom-lsp 确认
int rdbSaveLen(rio *rdb, uint64_t len) {
    if (len < (1<<6)) {
        // 1 字节：00 + 6 bit
    } else if (len < (1<<14)) {
        // 2 字节：01 + 14 bit
    } else if (len < (1<<32)) {
        // 5 字节：10000000 + 4B
    } else {
        // 9 字节：10000001 + 8B
    }
}
```

### 4.4 LZF 压缩

RDB 对字符串做可选的 LZF 压缩（`server.rdb_compression`，默认开启）：

```c
// rdb.c:362-385 — doom-lsp 确认
ssize_t rdbSaveLzfStringObject(rio *rdb, unsigned char *s, size_t len) {
    if (len <= 4) return 0;  // 太小，不压缩
    outlen = len - 4;
    out = zmalloc(outlen + 1);
    comprlen = lzf_compress(s, len, out, outlen);
    if (comprlen == 0) { zfree(out); return 0; }  // 压缩失败

    // 写入：类型标志 + 压缩后长度 + 原始长度 + 压缩数据
    rdbSaveLzfBlob(rdb, out, comprlen, len);
}
```

**收益计算**：最小压缩增益 4 字节。如果压缩后比原始长度只少了不到 4 字节，就不压缩。LZF 的压缩率在文本数据（JSON/HTML）上通常 2~4 倍。

---

## 5. 性能分析

### 5.1 各类型的序列化开销

| 类型 | 序列化方式 | 加载方式 | 空间效率 |
|------|-----------|---------|:--------:|
| STRING (整数) | 1~5 字节整数编码 | `createStringObjectFromLongLong` | 极高 |
| STRING (小文本) | LZF 压缩 | 解压 → createObject | 高 |
| STRING (大文本) | 裸存 | 裸读 | 1:1 |
| LIST (quicklist) | LZF 节点 + 裸节点 | LZF 解压 + lpNew | 中等 |
| SET (intset) | intset blob dump | 二进制兼容加载 | 原生 |
| SET (HT) | N 个 sds | 逐个插入 hashtable | 原始 |
| ZSET (listpack) | listpack blob dump | 二进制兼容加载 | 原生 |
| ZSET (skiplist) | N 个 (ele+score) pair | 反向插入 skiplist | 原始 |
| STREAM | rax key + listpack blob | raxInsert + lpNew | 原生 |

**二进制兼容编码**（listpack、intset）直接 dump/load blob，序列化成本几乎为零。这是紧凑数据结构的一个重要优势——它们的内存格式就是序列化格式。

### 5.2 文件压缩效果

```
原始内存                     RDB 文件
100 万个小 String (<=20B)    ~20MB + LZF (~10MB)
100 万个 intset SET          ~8MB (intset blob)
100 万个 skiplist ZSET       ~40MB (存全量数据 + 元信息)
Stream 1M 条 (SAMEFIELDS)    ~50MB (listpack 原生存储)
```

### 5.3 加载速度

加载时的主要瓶颈：
1. **字符串分配**：每个 key/value 创建 robj + sds
2. **数据结构重建**：dict 插入需要 hash + 碰撞链遍历；skiplist 插入需要 O(log N) 定位
3. **CRC64 校验**：全文件校验计算

---

## 6. RDB 与系列前文的联系

```
rdbSaveObject / rdbLoadObject 覆盖了前 9 篇的所有内容：

RDB_TYPE_STRING        → robj + sds (01, 02)
RDB_TYPE_SET_INTSET    → intset (06)
RDB_TYPE_SET           → dict / hashtable (03)
RDB_TYPE_HASH_LISTPACK → listpack (04)
RDB_TYPE_HASH          → dict (03)
RDB_TYPE_ZSET_LISTPACK → listpack (04)
RDB_TYPE_ZSET_2        → zskiplist + dict (05)
RDB_TYPE_LIST_QUICKLIST_2 → quicklist + listpack (04)
RDB_TYPE_STREAM_LISTPACKS_2 → rax + listpack + streamCG (07)
```

RDB 是整个系列中**最完整的横切面**——它把前 9 篇讨论的每一种数据结构都展现在磁盘格式中。
