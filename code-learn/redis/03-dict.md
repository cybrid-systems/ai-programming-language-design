# 03 — dict：Redis 哈希表的渐进式艺术

> Redis 主线源码深度分析系列 · 第三篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

哈希表是数据库的核心。Redis 的 `dict`（`src/dict.c` + `src/dict.h`，约 1555 行）是一份教科书级的实现——链表法解决冲突、按 2 的幂扩容、渐进式 rehash 分摊迁移成本。

但 dict 的看点远不止"一个哈希表"那么简单：

- **双哈希表结构**：`ht_table[2]` 支撑渐进式 rehash，迁移过程中两个表并存
- **多态 dictType**：通过函数指针表实现 key hash、compare、dup、destructor 全定制化
- **SipHash + 随机种子**：抵制 hash 碰撞攻击（HashDoS）
- **反向二进制游标**：`dictScan` 用 reverse binary iteration 实现 rehash-safe 的全表遍历
- **指纹检测**：unsafe 迭代器通过 fingerprint 禁止迭代期间修改

本文逐一拆解这些设计。

**doom-lsp 确认**：核心文件分布

| 文件 | 行数 | 职责 |
|------|:----:|------|
| `src/dict.h` | 217 | 数据结构定义 + API 声明 |
| `src/dict.c` | 1338 | 全部实现，含 benchmark 测试 |
| `src/siphash.c` | 373 | SipHash 1-2 实现 |
| `src/mt19937-64.c` | 187 | Mersenne Twister PRNG（随机种子源） |

---

## 1. 数据结构——双表架构与多态

### 1.1 dict 结构体

```c
// dict.h:79-89 — doom-lsp 确认
struct dict {
    dictType *type;

    dictEntry **ht_table[2];     // 两张哈希表：ht_table[0] 活跃表，ht_table[1] rehash 目标
    unsigned long ht_used[2];    // 元素计数

    long rehashidx;              // rehash 进度：-1 表示不在 rehash，>=0 表示当前迁移到哪个 bucket
    int16_t pauserehash;         // >0 暂停 rehash（迭代器使用时）

    signed char ht_size_exp[2];  // 2 的幂指数：size = 1 << ht_size_exp
};
```

**`ht_size_exp` 的设计**：Redis 不使用 `unsigned long size` 来记录哈希表大小，而是存一个 `signed char` 指数。`DICTHT_SIZE(exp)` 宏在编译期只能计算 `1 << exp`：

```c
// dict.h:75 — doom-lsp 确认
#define DICTHT_SIZE(exp) ((exp) == -1 ? 0 : (unsigned long)1<<(exp))
#define DICTHT_SIZE_MASK(exp) ((exp) == -1 ? 0 : (DICTHT_SIZE(exp))-1)
```

存指数而非大小的原因：**只需要 1 个 signed char，也方便 `__builtin_clzl` 直接算指数**。

`sizeof(struct dict)` = **只有 32 字节**（在 64 位系统上：2×8B ht_table + 2×8B ht_used + 8B rehashidx + 2B pauserehash + 2B ht_size_exp）。

### 1.2 dictEntry——链表法节点

```c
// dict.h:47-58 — doom-lsp 确认
typedef struct dictEntry {
    void *key;
    union {
        void *val;
        uint64_t u64;
        int64_t s64;
        double d;
    } v;
    struct dictEntry *next;     // 链地址法：同 bucket 的下一节点
    void *metadata[];           // 零长度柔性数组，按需附加元数据
} dictEntry;
```

**union 多类型 value**：`void *val` 用于通常对象引用，`uint64_t`/`int64_t`/`double` 则允许在不额外分配的情况下直接存数值——在 `dictSetSignedIntegerVal` 等宏中使用。

**`metadata[]` 柔性数组**：`dictType->dictEntryMetadataBytes()` 可以指定每个 entry 额外携带多少字节的元数据。这些元数据在 entry 分配时自动补齐（`zmalloc(sizeof(*entry) + metasize)`）。

### 1.3 dictType——多态行为

```c
// dict.h:63-73 — doom-lsp 确认
typedef struct dictType {
    uint64_t (*hashFunction)(const void *key);
    void *(*keyDup)(dict *d, const void *key);
    void *(*valDup)(dict *d, const void *obj);
    int (*keyCompare)(dict *d, const void *key1, const void *key2);
    void (*keyDestructor)(dict *d, void *key);
    void (*valDestructor)(dict *d, void *obj);
    int (*expandAllowed)(size_t moreMem, double usedRatio);
    size_t (*dictEntryMetadataBytes)(dict *d);
} dictType;
```

Redis 数据库中的所有哈希表都通过 `dictType` 定制行为：

| dictType 实例 | 位置 | hashFunction | keyDup | keyCompare | expandAllowed |
|---------------|------|-------------|--------|-----------|---------------|
| `dbDictType` | `server.c` | dictObjHash | NULL | dictObjKeyCompare | dbDictExpandAllowed |
| `keyptrDictType` | `server.c` | dictSdsHash | NULL | dictSdsKeyCompare | NULL |
| `setDictType` | `t_set.c` | dictSdsHash | NULL | dictSdsKeyCompare | NULL |
| `hashDictType` | `t_hash.c` | dictSdsHash | NULL | dictSdsKeyCompare | NULL |
| `zsetDictType` | `t_zset.c` | dictSdsHash | NULL | dictSdsKeyCompare | NULL |

> **key 存储方式**：Redis 数据库 (`dbDictType`) 存的是 **robj**（`redisObject *`），所以 hashFunction 是 `dictObjHash`（先取 `o->ptr` 得到 sds 再 hash）；而 `keyptrDictType` 等存的是裸 **sds**，所以 hashFunction 是 `dictSdsHash`（直接对 sds 做 hash）。

`expandAllowed` 是 Redis 7.0 引入的回调——在一些场景（如 command 执行期间）允许 dict 拒绝扩容，防止大 rehash 导致的延迟毛刺。

---

## 2. 扩容与缩容

### 2.1 初始化

```c
// dict.c:125-132 — doom-lsp 确认
dict *dictCreate(dictType *type)
{
    dict *d = zmalloc(sizeof(*d));
    _dictInit(d, type);
    return d;
}

int _dictInit(dict *d, dictType *type)
{
    _dictReset(d, 0);
    _dictReset(d, 1);
    d->type = type;
    d->rehashidx = -1;
    d->pauserehash = 0;
    return DICT_OK;
}
```

初始状态：两张表全部置空（`ht_size_exp = -1`），`rehashidx = -1`。直到第一次 `dictAddRaw` 触发 `_dictExpandIfNeeded` 才会分配初始桶数组。

### 2.2 _dictExpandIfNeeded——扩容触发条件

`dict.c:1010` 的 `_dictExpandIfNeeded` 是每次 `dictAddRaw` 前的守卫：

```c
// dict.c:1010-1029 — doom-lsp 确认
static int _dictExpandIfNeeded(dict *d)
{
    if (dictIsRehashing(d)) return DICT_OK;   // 已经在 rehash，不重复触发

    if (DICTHT_SIZE(d->ht_size_exp[0]) == 0)
        return dictExpand(d, DICT_HT_INITIAL_SIZE);  // 首次分配：4 个 bucket

    if ((dict_can_resize == DICT_RESIZE_ENABLE &&
         d->ht_used[0] >= DICTHT_SIZE(d->ht_size_exp[0])) ||        // 1:1 满载
        (dict_can_resize != DICT_RESIZE_FORBID &&
         d->ht_used[0] / DICTHT_SIZE(d->ht_size_exp[0]) > dict_force_resize_ratio)) // 5:1 强制
    {
        if (!dictTypeExpandAllowed(d))
            return DICT_OK;
        return dictExpand(d, d->ht_used[0] + 1);
    }
    return DICT_OK;
}
```

**两条触发路径**：

1. **正常扩容**：`dict_can_resize == DICT_RESIZE_ENABLE`，且负载 ≥ 1.0（元素数 ≥ bucket 数）
2. **强制扩容**：`dict_can_resize` 不为 FORBID，但负载 > `dict_force_resize_ratio`（= 5，dict.c:59）。这是安全阀——即使 resize 被禁用（如 BGSAVE 期间），当冲突链长度超过 5 时仍然扩容

```
DICT_HT_INITIAL_EXP = 2           // dict.h:108
DICT_HT_INITIAL_SIZE = 1 << 2 = 4 // 初始 4 个 bucket
```

### 2.3 _dictNextExp——寻找下一个 2 的幂

```c
// dict.c:1035-1042 — doom-lsp 确认
static signed char _dictNextExp(unsigned long size)
{
    if (size <= DICT_HT_INITIAL_SIZE) return DICT_HT_INITIAL_EXP;
    if (size >= LONG_MAX) return (8*sizeof(long)-1);

    return 8*sizeof(long) - __builtin_clzl(size-1);
}
```

**`__builtin_clzl`**（count leading zeros）将任意 `size` 向上取整到最近的 2 的幂。例如：
- `size = 10` → `10-1 = 9` → `__builtin_clzl(9)` = 60 → `64 - 60 = 4` → `2^4 = 16`
- `size = 16` → `16-1 = 15` → `__builtin_clzl(15)` = 60 → `64 - 60 = 4` → `2^4 = 16`（保持不变）

扩容总是**翻倍**：从表大小 `T` → `2T`。

### 2.4 _dictExpand——分配新表

```c
// dict.c:144-188 — doom-lsp 确认
int _dictExpand(dict *d, unsigned long size, int* malloc_failed)
{
    // ... 前置检查 ...
    signed char new_ht_size_exp = _dictNextExp(size);
    size_t newsize = 1ul << new_ht_size_exp;

    // 分配新 hash 表（calloc，所有指针初始化为 NULL）
    new_ht_table = zcalloc(newsize * sizeof(dictEntry*));

    if (d->ht_table[0] == NULL) {
        // 首次初始化：设置 ht_table[0]，不触发 rehash
        d->ht_size_exp[0] = new_ht_size_exp;
        d->ht_table[0] = new_ht_table;
        return DICT_OK;
    }

    // 设置 ht_table[1] 为扩容目标，开启 rehash
    d->ht_size_exp[1] = new_ht_size_exp;
    d->ht_table[1] = new_ht_table;
    d->rehashidx = 0;    // ← 从 bucket 0 开始迁移
    return DICT_OK;
}
```

**关键设计**：当 `d->ht_table[0]` 已经是活跃表时，新表写入 `ht_table[1]`，`rehashidx` 设为 0。此时 dict 进入 rehash 状态（`dictIsRehashing(d)` 返回 true）。后续的每次查找、插入、删除都会顺带迁移一个 bucket。

### 2.5 dictResize——缩容

```c
// dict.c:125-133 — doom-lsp 确认
int dictResize(dict *d)
{
    if (dict_can_resize != DICT_RESIZE_ENABLE || dictIsRehashing(d))
        return DICT_ERR;
    minimal = d->ht_used[0];           // 最小表大小 = 元素数
    if (minimal < DICT_HT_INITIAL_SIZE)
        minimal = DICT_HT_INITIAL_SIZE; // 下限 4
    return dictExpand(d, minimal);     // 同样走 _dictExpand → 渐进式 rehash
}
```

**缩容时机**：由 `databasesCron()`（`server.c` 的周期性任务）触发，当表的负载因子低于 `0.1`（即元素数不足 bucket 数的 10%）时调用 `dictResize`。缩容同样走渐进式 rehash——不是瞬间释放一半 bucket，而是逐个迁移。

---

## 3. 渐进式 Rehash——核心中的核心

传统的哈希表扩容是「全量迁移」：分配新表 → 遍历旧表全部元素 → 重算每个 key 的 hash → 插入新表 → 释放旧表。这个操作与表的大小成正比。对于内存数据库，一张大表（百万级 entry）全量 rehash 可能阻塞服务数毫秒甚至更久。

Redis 的方案：**每次操作迁移一个 bucket**。

### 3.1 dictRehash——单步迁移

```c
// dict.c:207-267 — doom-lsp 确认
int dictRehash(dict *d, int n) {
    int empty_visits = n * 10;
    unsigned long s0 = DICTHT_SIZE(d->ht_size_exp[0]);
    unsigned long s1 = DICTHT_SIZE(d->ht_size_exp[1]);

    // 当 resize 被标记为 AVOID 时，检查比例是否在阈值内
    if (dict_can_resize == DICT_RESIZE_AVOID &&
        ((s1 > s0 && s1 / s0 < dict_force_resize_ratio) ||
         (s1 < s0 && s0 / s1 < dict_force_resize_ratio)))
        return 0;

    while (n-- && d->ht_used[0] != 0) {
        dictEntry *de, *nextde;

        // 跳过空 bucket（最多跳 n*10 个）
        assert(DICTHT_SIZE(d->ht_size_exp[0]) > (unsigned long)d->rehashidx);
        while (d->ht_table[0][d->rehashidx] == NULL) {
            d->rehashidx++;
            if (--empty_visits == 0) return 1;
        }

        // 取出该 bucket 的全部 entry
        de = d->ht_table[0][d->rehashidx];
        while (de) {
            uint64_t h;
            nextde = de->next;

            // 用新表 mask 重算索引
            h = dictHashKey(d, de->key) & DICTHT_SIZE_MASK(d->ht_size_exp[1]);
            // 头插法插入新表
            de->next = d->ht_table[1][h];
            d->ht_table[1][h] = de;

            d->ht_used[0]--;
            d->ht_used[1]++;
            de = nextde;
        }
        d->ht_table[0][d->rehashidx] = NULL;  // 清空旧 bucket
        d->rehashidx++;                        // 前进到下一个 bucket
    }

    // 检查是否全部迁移完毕
    if (d->ht_used[0] == 0) {
        zfree(d->ht_table[0]);                 // 释放旧表
        d->ht_table[0] = d->ht_table[1];       // 新表上位
        d->ht_used[0] = d->ht_used[1];
        d->ht_size_exp[0] = d->ht_size_exp[1];
        _dictReset(d, 1);                      // 清空 ht[1]
        d->rehashidx = -1;                     // rehash 完成
        return 0;
    }
    return 1;  // 还有未迁移的 bucket
}
```

**设计要点**：

1. **`empty_visits = n * 10`**：最多跳过 10n 个空 bucket。如果连续碰到大量空 bucket 而缺乏实际数据，会提前返回，避免单次 rehash 调用阻塞太久。

2. **头插法迁移**：`de->next = d->ht_table[1][h]; d->ht_table[1][h] = de`。每次插入新表都是头插，rehash 后同 bucket key 的链表顺序会反转。但这不重要——哈希表的 bucket 内顺序没有语义依赖。

3. **rehash 完成收尾**：`ht_used[0] == 0` 时，`zfree(ht_table[0])` 释放旧表，ht_table[1] 成为新的 ht_table[0]（不需要内存拷贝，只是指针赋值），然后 `_dictReset(1)`。

### 3.2 触发 rehash 的三条路径

```c
// 路径一：dictAddRaw / dictFind 等操作中顺带触发
// dict.c:335 — doom-lsp 确认
if (dictIsRehashing(d)) _dictRehashStep(d);   // 每次插入前迁移 1 个 bucket

// dict.c:421 — doom-lsp 确认
if (dictIsRehashing(d)) _dictRehashStep(d);   // 每次查找前迁移 1 个 bucket

// 路径二：serverCron 周期性任务
// dict.c:283-299 — doom-lsp 确认
int dictRehashMilliseconds(dict *d, int ms) {
    long long start = timeInMilliseconds();
    int rehashes = 0;
    while (dictRehash(d, 100)) {   // 每次 100 步
        rehashes += 100;
        if (timeInMilliseconds() - start > ms) break;
    }
    return rehashes;
}

// 路径三：_dictRehashStep—每次操作迁移 1 bucket
static void _dictRehashStep(dict *d) {
    if (d->pauserehash == 0) dictRehash(d, 1);
}
```

| 触发方式 | 粒度 | 时机 | 用途 |
|----------|:----:|------|------|
| `_dictRehashStep` | 1 bucket | 每次插入/查找/删除前 | 精细分摊，延迟敏感路径 |
| `dictRehashMilliseconds` | 100 bucket/轮 | 每 1 毫秒（serverCron） | 主动追赶，保证在无操作时也能完成 |
| `dictRehash` 直接调用 | N bucket | 需要批量时 | 用于测试和特定批量场景 |

**每个命令平均触发一次 `_dictRehashStep`**，迁移 1 个 bucket。假设 bucket 平均 2 个 entry，这意味着每个命令承担约 2 次 hash 重算 + 2 次指针更新。对于 O(1) 的命令来说，这个增量足够小。

### 3.3 pauserehash——保护迭代器

```c
// dict.h:166-167 — doom-lsp 确认
#define dictPauseRehashing(d) (d)->pauserehash++
#define dictResumeRehashing(d) (d)->pauserehash--
```

当 `pauserehash > 0` 时，`_dictRehashStep()` 不执行任何操作。主要用于：
- **dictScan** 全表遍历加锁期间
- **dictGetSafeIterator 等安全迭代器**使用期间

因为 rehash 时元素在两个表之间迁移，如果正在迭代的某个 bucket 的 key 被迁移到了另一个表，迭代器可能重复遍历或遗漏元素。

---

## 4. 哈希函数——SipHash + 随机种子

### 4.1 SipHash 1-2

Redis 从 4.0 起用 SipHash 替代了 MurmurHash2。原因：**HashDoS 攻击防护**。

SipHash 是一个 keyed hash 函数——除了输入数据外，还需要一个 16 字节密钥（seed）。相同的输入，不同的 seed 产生不同的输出。攻击者不知道 seed，就无法构造出全部碰撞到同一 bucket 的 key 集。

```c
// dict.c:72-78 — doom-lsp 确认
static uint8_t dict_hash_function_seed[16];

void dictSetHashFunctionSeed(uint8_t *seed) {
    memcpy(dict_hash_function_seed, seed, sizeof(dict_hash_function_seed));
}

uint64_t dictGenHashFunction(const void *key, size_t len) {
    return siphash(key, len, dict_hash_function_seed);
}
```

Redis 使用了 SipHash 的 **1-2** 变体（1 轮压缩、2 轮最终化），而非标准推荐 2-4。antirez 在 `siphash.c` 开头解释了原因：

```
// siphash.c:35-40 — 经 antirez 修改的版本说明
// 1. 使用 SipHash 1-2。强度不如 2-4，但目前没有已知攻击能利用
//    降低轮数的版本，且速度与旧 MurmurHash2 相同
// 2. 硬编码轮数以便编译器优化
// 3. 返回值直接为 uint64_t（而非 16 字节输出缓冲区）
// 4. 提供 case-insensitive 变体
```

`siphash_nocase` 是 Redis 的特色——它先将大写字母转为小写再 hash，用于 `dictGenCaseHashFunction`。这使得 `KEY` 和 `key` 在哈希表中被视为相同。

### 4.2 种子随机化

```c
// server.c:1890 — doom-lsp 确认（在 initServer 中）
// 使用 Mersenne Twister 生成 16 字节种子
uint8_t seed[16];
for (int i = 0; i < 16; i += 4) {
    uint64_t r = genrand64_int64();
    memcpy(seed + i, &r, 4);
}
dictSetHashFunctionSeed(seed);
```

在 `initServer` 期间，每次 Redis 启动都会生成一个新的随机种子。这意味着**两次不同的 Redis 进程对同一个 key 的 hash 结果不同**——攻击者无法通过离线构造碰撞集来攻击在线服务。

### 4.3 取模：hash & mask，而不是 hash % size

```c
// dict.c:348 — doom-lsp 确认
idx = hash & DICTHT_SIZE_MASK(d->ht_size_exp[table]);

// dict.h:76
#define DICTHT_SIZE_MASK(exp) ((exp) == -1 ? 0 : (DICTHT_SIZE(exp))-1)
```

因为表大小永远是 2 的幂，`hash % N` 等价于 `hash & (N-1)`。位运算比取模快一个数量级。

```
例：hash = 0xABCD, table_size = 1024 (2^10)
  hash % 1024 = 0xABCD & 0x3FF = 0x2CD = 717
```

---

## 5. 查找、插入与删除——rehash 下的正确性

### 5.1 dictFind——两个表都要查

```c
// dict.c:418-436 — doom-lsp 确认
dictEntry *dictFind(dict *d, const void *key)
{
    if (dictSize(d) == 0) return NULL;
    if (dictIsRehashing(d)) _dictRehashStep(d);  // ← 顺带迁移一个 bucket

    h = dictHashKey(d, key);
    for (table = 0; table <= 1; table++) {
        idx = h & DICTHT_SIZE_MASK(d->ht_size_exp[table]);
        he = d->ht_table[table][idx];
        while (he) {
            if (key == he->key || dictCompareKeys(d, key, he->key))
                return he;
            he = he->next;
        }
        if (!dictIsRehashing(d)) break;  // 不在 rehash 则只需查表 0
    }
    return NULL;
}
```

**两个表的搜索顺序**：先查 `ht_table[0]`，如果没找到且正在 rehash，再查 `ht_table[1]`。如果不在 rehash 状态，直接 break。

**为什么不只在 `ht_table[0]` 查？** 因为 rehash 是分批进行的——某个 key 可能还没从 `ht_table[0]` 迁移到 `ht_table[1]`，也可能已经迁移过去了。两个表都要搜。

### 5.2 dictAddRaw——插入优先到新表

```c
// dict.c:325-360 — doom-lsp 确认
dictEntry *dictAddRaw(dict *d, void *key, dictEntry **existing)
{
    if (dictIsRehashing(d)) _dictRehashStep(d);

    if ((index = _dictKeyIndex(d, key, dictHashKey(d, key), existing)) == -1)
        return NULL;

    // ★ 插入时：在 rehash 则插入 ht_table[1]，否则 ht_table[0]
    htidx = dictIsRehashing(d) ? 1 : 0;
    entry = zmalloc(sizeof(*entry) + metasize);
    entry->next = d->ht_table[htidx][index];
    d->ht_table[htidx][index] = entry;
    d->ht_used[htidx]++;
    dictSetKey(d, entry, key);
    return entry;
}
```

**关键**：`_dictKeyIndex` 查找 key 时会同时扫描两个表，但如果要插入一个新 key，会优先插入 `ht_table[1]`（因为 `ht_table[0]` 正在被逐步清空）。这是 rehash 中的约定——所有新元素只进入新表，旧表只出不出。

### 5.3 dictGenericDelete——删除也是两个表

```c
// dict.c:377-410 — doom-lsp 确认
static dictEntry *dictGenericDelete(dict *d, const void *key, int nofree) {
    if (dictSize(d) == 0) return NULL;

    if (dictIsRehashing(d)) _dictRehashStep(d);

    h = dictHashKey(d, key);
    for (table = 0; table <= 1; table++) {
        idx = h & DICTHT_SIZE_MASK(d->ht_size_exp[table]);
        he = d->ht_table[table][idx];
        prevHe = NULL;
        while (he) {
            if (key == he->key || dictCompareKeys(d, key, he->key)) {
                if (prevHe) prevHe->next = he->next;
                else d->ht_table[table][idx] = he->next;
                if (!nofree) dictFreeUnlinkedEntry(d, he);
                d->ht_used[table]--;
                return he;
            }
            prevHe = he;
            he = he->next;
        }
        if (!dictIsRehashing(d)) break;
    }
    return NULL;
}
```

删除也是同样的双表模式。`dictUnlink`（dict.c:397）则是 `dictGenericDelete` 的 `nofree=1` 变体——先解除链表链接，把 entry 返回给调用者处理（典型场景：lazyfree 后台释放）。

---

## 6. dictScan——rehash-safe 的全表遍历

`KEYS` 命令在大库中会阻塞服务多秒——因为它一次性返回所有 key。`SCAN` 命令通过游标（cursor）分批次遍历，但游标在 rehash 期间面临严重问题：如果遍历过程中表在扩容/缩容，同一个 key 可能被遍历多次或遗漏。

### 6.1 反向二进制迭代（Reverse Binary Iteration）

Redis 的方案来自 Dan Bernstein 的设计：

```
正常二进制计数：（从低位递增）
000 → 001 → 010 → 011 → 100 → 101 ...
扩容后（4→8）：
  从 011 到 110 时，011 扩容后分裂到 011 和 111
  → 111 之前已经遍历过 → 出现遗漏

反向二进制迭代：（位反转后递增）
000 → 100 → 010 → 110 → 001 → 101 ...
扩容后（4→8）：
  从 110 到 001 时，110 扩容后分裂到 110 和 010
  → 010 还未遍历 → 不会遗漏，不会重复
```

核心代码在 `dictScan`（dict.c:911-1000）：

```c
// dict.c:937-946 — 不在 rehash 时的扫描
if (!dictIsRehashing(d)) {
    htidx0 = 0;
    m0 = DICTHT_SIZE_MASK(d->ht_size_exp[htidx0]);

    // 遍历当前 bucket
    if (bucketfn) bucketfn(d, &d->ht_table[htidx0][v & m0]);
    de = d->ht_table[htidx0][v & m0];
    while (de) { fn(privdata, de); de = de->next; }

    // 反向游标递增
    v |= ~m0;      // 设置 unmasked 位，使递增操作不影响掩码部分
    v = rev(v);    // 位反转
    v++;           // 递增
    v = rev(v);    // 位反转回来
}
```

`rev()` 逐位反转一个 unsigned long（如 0b001 → 0b100）。反转后递增再反转回去的效果就是「高位加 1」，等价于「前一个遍历的 bucket 的后半部分在扩容后也是已遍历区域」。

### 6.2 Rehash 期间的扫描

当 dict 正在 rehash 时，dictScan 需要同时处理两张表：

```c
// dict.c:949-990 — rehash 期间的扫描
if (dictIsRehashing(d)) {
    // 确保 htidx0 是较小表，htidx1 是较大表
    if (DICTHT_SIZE(d->ht_size_exp[htidx0]) > DICTHT_SIZE(d->ht_size_exp[htidx1])) {
        htidx0 = 1; htidx1 = 0;
    }
    m0 = DICTHT_SIZE_MASK(d->ht_size_exp[htidx0]);
    m1 = DICTHT_SIZE_MASK(d->ht_size_exp[htidx1]);

    // 遍历小表的一个 bucket
    de = d->ht_table[htidx0][v & m0];
    while (de) { fn(privdata, de); de = de->next; }

    // 遍历大表中对应的所有分裂 bucket
    do {
        de = d->ht_table[htidx1][v & m1];
        while (de) { fn(privdata, de); de = de->next; }

        v |= ~m1;
        v = rev(v); v++; v = rev(v);
    } while (v & (m0 ^ m1));  // 继续直到用完小表掩码覆盖的位
}
```

**大表分裂遍历**：扩容时，小表的一个 bucket 对应大表的连续两个 bucket（`00` → `000`, `100`）。`m0 ^ m1` 是两张表掩码的差异位。`dictScan` 会遍历小表的一个 bucket 对应的所有大表 bucket，确保不遗漏也不重复。

---

## 7. 迭代器系统——安全与非安全

### 7.1 迭代器结构

```c
// dict.h:96-102 — doom-lsp 确认
typedef struct dictIterator {
    dict *d;
    long index;
    int table, safe;
    dictEntry *entry, *nextEntry;
    unsigned long long fingerprint;  // 不安全迭代器的状态快照
} dictIterator;
```

两种迭代器：

| 模式 | 创建方式 | 允许修改 | 性能 | 使用场景 |
|------|---------|---------|------|---------|
| 安全 | `dictGetSafeIterator` | 是 | 稍慢 | 遍历中需要增删查 |
| 非安全 | `dictGetIterator` | 否 | 最快 | 只读遍历 |

### 7.2 安全迭代器——pauserehash

```c
// dict.c:596-600 — doom-lsp 确认
dictIterator *dictGetSafeIterator(dict *d) {
    dictIterator *i = dictGetIterator(d);
    i->safe = 1;
    return i;
}
```

安全迭代器在初始化时递增 `pauserehash`（通过 `dictPauseRehashing`），在释放时递减。期间 rehash 暂停，但 `dictAdd/dictFind` 等操作仍然安全——因为 **rehash 暂停不等于禁止所有修改**。

### 7.3 非安全迭代器——fingerprint 检测

```c
// dict.c:638-646 — doom-lsp 确认
void dictReleaseIterator(dictIterator *iter) {
    // ...
    if (!iter->safe) {
        // 非安全迭代器：释放时校验 fingerprint
        if (dictFingerprint(iter->d) != iter->fingerprint) {
            assert(0);  // 迭代期间有人修改了 dict！crash！
        }
    }
    // ...
}
```

`dictFingerprint()`（dict.c:452）将 `ht_table[0]`、`ht_size_exp[0]`、`ht_used[0]`、`ht_table[1]`、`ht_size_exp[1]`、`ht_used[1]` 这 6 个值 xor 哈希成一个 64 位数。非安全迭代器在创建时记录 fingerprint，释放时校验——如果变了，说明有人在迭代期间执行了写操作，直接 `assert(0)` 中止。

这是一个**调试期保护**——在 production build 中 `assert` 可能被 `NDEBUG` 禁用，但在 Redis 的 `redisassert.h` 中 assert 总是生效的。

### 7.4 dictNext——遍历状态推进

```c
// dict.c:603-634 — doom-lsp 确认
dictEntry *dictNext(dictIterator *iter)
{
    while (1) {
        if (iter->entry == NULL) {
            // 跳到下一个 bucket
            if (iter->index == -1 && iter->table == 0) {
                // 安全迭代器在首次获取时暂停 rehash
                if (iter->safe) dictPauseRehashing(d);
                else iter->fingerprint = dictFingerprint(d);
            }
            iter->index++;
            // 检查当前表的 bucket 是否遍历完
            if (iter->index >= (long)DICTHT_SIZE(d->ht_size_exp[iter->table])) {
                if (dictIsRehashing(d) && iter->table == 0) {
                    // rehash 中：继续遍历 ht_table[1]
                    iter->table++;
                    iter->index = 0;
                } else {
                    // 遍历完毕
                    if (iter->safe) dictResumeRehashing(d);
                    else assert(iter->fingerprint == dictFingerprint(d));
                    break;
                }
            }
            iter->entry = d->ht_table[iter->table][iter->index];
        } else {
            iter->entry = iter->nextEntry;
        }

        if (iter->entry) {
            iter->nextEntry = iter->entry->next;
            return iter->entry;
        }
    }
    return NULL;
}
```

**双表遍历**：如果在 rehash 期间遍历，`dictNext` 先遍历完 `ht_table[0]` 的所有 bucket，然后继续遍历 `ht_table[1]` 的 bucket。这是对用户透明的——迭代器使用者不需要知道 rehash 的存在。

---

## 8. 随机 Key 获取

### 8.1 dictGetRandomKey——随机采一个

```c
// dict.c:649-698 — doom-lsp 确认
dictEntry *dictGetRandomKey(dict *d)
{
    if (dictSize(d) == 0) return NULL;
    if (dictIsRehashing(d)) _dictRehashStep(d);

    if (dictIsRehashing(d)) {
        // rehash 中：随机范围包括两个表
        unsigned long s0 = DICTHT_SIZE(d->ht_size_exp[0]);
        do {
            h = d->rehashidx + (randomULong() % (dictSlots(d) - d->rehashidx));
            he = (h >= s0) ? d->ht_table[1][h - s0] : d->ht_table[0][h];
        } while (he == NULL);
    } else {
        do {
            h = randomULong() & DICTHT_SIZE_MASK(d->ht_size_exp[0]);
            he = d->ht_table[0][h];
        } while (he == NULL);
    }

    // 从找到的 bucket 的链表中随机选一个
    listlen = 0;
    orighe = he;
    while (he) { he = he->next; listlen++; }
    listele = random() % listlen;
    he = orighe;
    while (listele--) he = he->next;
    return he;
}
```

用于 `RANDOMKEY` 命令。有趣的是，rehash 期间的采样范围从 `rehashidx` 开始而非 0——因为 `rehashidx` 之前的旧表 bucket 已经全部迁移到了新表，直接跳过空桶节约步骤。

### 8.2 dictGetFairRandomKey——更均匀的随机

```c
// dict.c:803-840 — doom-lsp 确认
dictEntry *dictGetFairRandomKey(dict *d)
{
    // 先收集一些随机 key，再从中均匀选取
    dictEntry *keys[DICT_FAIR_RANDOM_KEY_SAMPLE];
    unsigned count = dictGetSomeKeys(d, keys, DICT_FAIR_RANDOM_KEY_SAMPLE);
    if (count == 0) return NULL;
    return keys[random() % count];
}
```

`DICT_FAIR_RANDOM_KEY_SAMPLE` = 16。与 `dictGetRandomKey` 不同，`dictGetFairRandomKey` 避免了长冲突链中的 key 被采样的概率远高于短链中的 key 的问题。

---

## 9. 全局 resize 控制——COW 友好

```c
// dict.c:57 — doom-lsp 确认
static dictResizeEnable dict_can_resize = DICT_RESIZE_ENABLE;

// server.c:2800 — doom-lsp 确认
void updateDictResizePolicy(void) {
    if (server.rdb_child_pid != -1 || server.aof_child_pid != -1)
        dictSetResizeEnabled(DICT_RESIZE_AVOID);
}
```

**当有子进程在执行 BGSAVE/BGREWRITEAOF 时，Redis 会尽量避开 resize**。原因：copy-on-write 环境下，哈希表扩容会触发大量内存拷贝（父进程写入新 page → COW 复制）。如果负载超过 5:1 的强制扩容阈值还是会触发——避免无限增长的冲突链影响性能。

---

## 10. dict × redisObject——从 db.c 看完整数据流

第一篇讲了 `redisObject` 的 16 字节包装。第二篇讲了 SDS 的字符串表示。本篇文章连接前两篇，看看它们在数据库中的实际配合：

```
SET mykey "hello"
  ↓
setCommand()              → t_string.c
  ↓
setGenericCommand()
  ↓
setKey(c->db, key, val)   → db.c
  ↓
dbAdd(c->db, key, val)    → db.c
  ↓
dictAdd(c->db->dict,      → dict.c  (数据库主 dict)
       key->ptr,           ← sds（@see 02-sds.md）
       val)                ← robj（@see 01-data-model.md）
  ↓
_dictExpandIfNeeded(d)    → 必要时扩容
_dictRehashStep(d)        → 必要时 rehash 一个 bucket
  ↓
dictAddRaw(d, key)        → 插入 dbDictType 管理的 dict
```

完整的调用链展示了第一篇的 robj、第二篇的 SDS、第三篇的 dict 如何串联：

| 组件 | 角色 | 文件 |
|------|------|------|
| `redisObject` | 值的统一包装（16 字节） | `server.h` / `object.c` |
| `sds` | key 的字符串表示 | `sds.h` / `sds.c` |
| `dict` | 数据库主索引结构 | `dict.h` / `dict.c` |
| `dictType (dbDictType)` | 定制 hash、compare、expand 行为 | `server.c` |

真正的 Redis 数据库就是 **一个 dict**（`server.c` 中的 `struct redisDb` 包含 `dict *dict` 字段），key 是 sds，value 是 robj。

---

## 总结

| 特性 | 设计 |
|------|------|
| 冲突解决 | 链表法（chaining），同 bucket 的 entry 组成单链表 |
| 大小 | 2 的幂（`ht_size_exp` 指数编码），`hash & mask` 代替 `%` |
| 渐进式 rehash | `ht_table[2]` 双表，`rehashidx` 游标前进，每次操作迁移 1 bucket |
| 扩容触发 | 1:1 满载正常扩容，5:1 强制扩容（COW 期间也生效） |
| 缩容触发 | `databasesCron` 负载 < 10% 时触发 |
| Hash 函数 | SipHash 1-2，启动时随机 16 字节种子 |
| HashDoS 防护 | 随机种子 + SipHash keyed hash |
| 全表遍历 | 反向二进制迭代（rehash-safe 游标） |
| 随机采样 | `dictGetRandomKey`（RANDOMKEY）/ `dictGetFairRandomKey`（更均匀） |
| 迭代器安全 | safe（暂停 rehash）vs unsafe（fingerprint 校验） |
| COW 友好 | `updateDictResizePolicy` 子进程期间仅允许 5:1 强制扩容 |
