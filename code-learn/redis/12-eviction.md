# 12 — Eviction：Redis 的内存淘汰艺术

> Redis 主线源码深度分析系列 · 第十二篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Redis 定位为"缓存"还是"数据库"的区别，很大程度上取决于**内存淘汰策略**。当写入导致内存超过 `maxmemory` 限制时，Redis 必须决定：删除哪些 key 来腾出空间？

这个问题远比表面复杂：

- **LRU 不是真 LRU**：Redis 不维护全局访问链表，而是用**近似 LRU**——采样 + 淘汰池（eviction pool）
- **LFU 是带老化机制的LFU**：24 bit 拆成计数器 + 衰减时间，计数器的递增概率随值增大而降低
- **淘汰时间预算**：`maxmemory-eviction-tenacity` 控制单次淘汰循环的耗时上限，防止服务卡死
- **惰性释放整合**：淘汰可走 `UNLINK` 路径（dbAsyncDelete），大 key 在后台线程释放

**doom-lsp 确认**：核心文件

| 文件 | 行数 | 职责 |
|------|:----:|------|
| `src/evict.c` | 773 | 淘汰池 + LRU/LFU/TTL 算法 + 主循环 |
| `src/object.c:370` | — | `LFUDecrAndReturn` |
| `src/server.h:526-529` | — | `MAXMEMORY_FLAG_*` 策略标志 |
| `src/server.h:113` | — | `OBJ_SHARED_INTEGERS` |
| `src/db.c` | — | `dbAsyncDelete` / `dbSyncDelete` |

**doom-lsp 符号映射** (`evict.c`)：

```c
// — doom-lsp 确认：完整 24 个符号 —
struct evictionPoolEntry @ 56     // 淘汰池条目
static EvictionPoolLRU @ 63       // 全局淘汰池（16 个槽位）
fn getLRUClock @ 72               // 低精度 LRU 时钟
fn LRU_CLOCK @ 80                 // 从缓存或系统调用获取时钟
fn estimateObjectIdleTime @ 92    // 通过 lru 字段估算空闲时间
fn evictionPoolAlloc @ 123        // 初始化淘汰池
fn evictionPoolPopulate @ 146     // 采样填充淘汰池
fn LFUGetTimeInMinutes @ 283      // LFU 时间戳（16 bit 分钟）
fn LFUTimeElapsed @ 291           // 计算时间差（处理回绕）
fn LFULogIncr @ 299               // 对数递增计数器
fn LFUDecrAndReturn @ 319         // 衰减计数器
fn freeMemoryGetNotCountedMemory @ 336   // 不计入的内存（AOF/repl buffer）
fn getMaxmemoryState @ 397        // 检查是否超限
fn overMaxmemoryAfterAlloc @ 438  // 分配后检查超限
static evictionTimeProc @ 455     // 定时器驱动的持续淘汰
fn startEvictionTimeProc @ 469    // 启动淘汰定时器
fn isSafeToPerformEvictions @ 481 // 安全检查
fn evictionTimeLimitUs @ 499      // 时间预算计算
fn performEvictions @ 540         // ★ 主淘汰函数
```

---

## 1. 淘汰策略速览

```c
// server.h:526-529 — doom-lsp 确认
#define MAXMEMORY_FLAG_LRU (1<<0)
#define MAXMEMORY_FLAG_LFU (1<<1)
#define MAXMEMORY_FLAG_ALLKEYS (1<<2)
```

Redis 的 8 种淘汰策略用 3 个 bit flag 组合表示：

| 策略 | Flags | 作用域 | 选择依据 |
|------|-------|--------|---------|
| `noeviction` | 无 | — | 拒绝写入 |
| `allkeys-lru` | ALLKEYS+LRU | 所有 key | 近似 LRU，闲置最久 |
| `allkeys-lfu` | ALLKEYS+LFU | 所有 key | 近似 LFU，访问最少 |
| `allkeys-random` | ALLKEYS | 所有 key | 随机 |
| `volatile-lru` | LRU | 有 TTL 的 key | 近似 LRU |
| `volatile-lfu` | LFU | 有 TTL 的 key | 近似 LFU |
| `volatile-random` | 无 | 有 TTL 的 key | 随机 |
| `volatile-ttl` | 无 | 有 TTL 的 key | 最短 TTL |

`FLAG_ALLKEYS` 决定扫描范围：所有 key vs 只扫描有 TTL 的 key。

---

## 2. 近似 LRU——采样+淘汰池

### 2.1 为什么不用真 LRU

传统 LRU 要求维护一个全局访问链表——每次访问一个 key，把它移到链表头部。这个链表本身就是 O(1) 的操作，但在 Redis 的单线程模型中，每次 GET 都修改链表节点位置带来了**不必要的 cache miss 和锁竞争**（考虑多线程 I/O 场景）。

Redis 的近似 LRU 对每个 key 只存一个**24 bit 的 LRU 时间戳**（在 redisObject 的 `lru` 字段中）：

```c
// server.h:850 — doom-lsp 确认
#define LRU_BITS 24
// object.c:50 — doom-lsp 确认
o->lru = LRU_CLOCK();  // 每次访问时更新
```

**LRU 时钟**（`evict.c:72`）：

```c
// evict.c:72 — doom-lsp 确认
unsigned int getLRUClock(void) {
    return (mstime() / LRU_CLOCK_RESOLUTION) & LRU_CLOCK_MAX;
}
```

时钟精度 `LRU_CLOCK_RESOLUTION = 1000`（毫秒），用 24 位存储，约 194 天回绕一次。回绕时 `estimateObjectIdleTime` 处理：

```c
// evict.c:92 — doom-lsp 确认
unsigned long long estimateObjectIdleTime(robj *o) {
    unsigned long long lruclock = LRU_CLOCK();
    if (lruclock >= o->lru) {
        return (lruclock - o->lru) * LRU_CLOCK_RESOLUTION;
    } else {
        return (lruclock + (LRU_CLOCK_MAX - o->lru)) *
                LRU_CLOCK_RESOLUTION;
    }
}
```

用 `LRU_CLOCK_MAX`（`(1<<24)-1`）处理时钟回绕——假设最多回绕一次。

### 2.2 淘汰池 EvictionPool

```c
// evict.c:54-63 — doom-lsp 确认
#define EVPOOL_SIZE 16                    // 固定 16 个槽位
#define EVPOOL_CACHED_SDS_SIZE 255        // 预分配 key 名缓冲区
struct evictionPoolEntry {
    unsigned long long idle;              // 空闲时间（LRU）或反频率（LFU）
    sds key;                              // key 名称
    sds cached;                           // 预分配的 sds 缓存（≤255 字节免分配）
    int dbid;                             // DB 编号
};
static struct evictionPoolEntry *EvictionPoolLRU;
```

`EVPOOL_SIZE = 16`——淘汰池固定 16 个槽位，按 `idle` 值升序排列。

### 2.3 evictionPoolPopulate——采样填充

```c
// evict.c:146-279 — doom-lsp 确认
void evictionPoolPopulate(int dbid, dict *sampledict, dict *keydict,
                          struct evictionPoolEntry *pool) {
    // ★ 通过 dictGetSomeKeys 随机采样 N 个 key
    //   N = maxmemory-samples（默认 5）
    count = dictGetSomeKeys(sampledict, samples, server.maxmemory_samples);

    for (j = 0; j < count; j++) {
        // 计算每个采样 key 的淘汰分数
        if (server.maxmemory_policy & MAXMEMORY_FLAG_LRU) {
            idle = estimateObjectIdleTime(o);    // LRU: 空闲时间
        } else if (server.maxmemory_policy & MAXMEMORY_FLAG_LFU) {
            idle = 255 - LFUDecrAndReturn(o);    // LFU: 反频率
        } else if (server.maxmemory_policy == MAXMEMORY_VOLATILE_TTL) {
            idle = ULLONG_MAX - (long)dictGetVal(de); // TTL: 剩余时间
        }

        // ★ 插入池中合适位置（升序）
        k = 0;
        while (k < EVPOOL_SIZE && pool[k].key && pool[k].idle < idle) k++;

        // 比池中最差的还差 → 跳过
        if (k == 0 && pool[EVPOOL_SIZE-1].key != NULL) continue;

        // 插入或替换
        if (pool[EVPOOL_SIZE-1].key == NULL) {
            // 有空位 → 右移
            memmove(pool+k+1, pool+k, sizeof(pool[0])*(EVPOOL_SIZE-k-1));
        } else {
            // 无空位 → 丢弃最差（pool[0]），左移
            k--;
            memmove(pool, pool+1, sizeof(pool[0])*k);
        }

        // 设置 key（≤255 字节用缓存，否则 sdsdup）
        if (klen > EVPOOL_CACHED_SDS_SIZE)
            pool[k].key = sdsdup(key);
        else
            memcpy(pool[k].cached, key, klen+1);
        pool[k].idle = idle;
        pool[k].dbid = dbid;
    }
}
```

**采样-池机制图解**：

```
每次淘汰循环：
  for (每个 DB):
    dictGetSomeKeys(db, 5)          ← 每个 DB 随机采 5 个 key
    → evictionPoolPopulate()        ← 插入淘汰池（16 槽）
  pool = [最差, 次差, ..., 最佳]
          ↑pool[0]            ↑pool[15]
  
  从 pool[15] 开始淘汰（最佳 candidate）
  → 检查 key 是否还存在（可能已被其他路径删除）
  → 存在则 dbAsyncDelete / dbSyncDelete
  → 释放后 mem_freed += delta
```

`maxmemory-samples`（默认 5）控制每次采样数量。值越大 LRU 越精确，但淘汰循环耗时也越长。

### 2.4 LRU 近似程度对比

```
100% 精确 LRU：
  [a][b][c][d][e][f][g][h]
  淘汰 h → 淘汰到够为止

Redis maxmemory-samples=5：
  {a, c, e, f, h} 采样集合
  h 被选中 ✓
  
Redis maxmemory-samples=10：
  {a, b, c, d, e, f, g, h} 更大采样
  h 被选中 ✓ 概率更高
```

测试数据表明 `samples=5` 时淘汰质量约 90%，`samples=10` 时约 99%。Redis 默认 5 是性能与精度的折中。

---

## 3. LFU——对数计数器 + 时间衰减

### 3.1 LRU 字段的复用

```c
// server.h:850 — doom-lsp 确认
// 24 bit LRU 字段在 LFU 模式下拆分为：
// ┌──────────────────────┬──────────┐
// │  16 bit              │  8 bit   │
// │  Last decrement time │ LOG_C    │
// │  (分钟级时间戳)      │ (计数器)  │
// └──────────────────────┴──────────┘
```

高 16 位：上次衰减时间的分钟戳（`LFUGetTimeInMinutes`）
低 8 位：对数计数器（0~255）

```c
// object.c:50 — doom-lsp 确认
if (server.maxmemory_policy & MAXMEMORY_FLAG_LFU) {
    o->lru = (LFUGetTimeInMinutes()<<8) | LFU_INIT_VAL;
    // 初始化时间戳 + 初始计数器 5
}
```

### 3.2 LFULogIncr——对数递增

```c
// evict.c:299 — doom-lsp 确认
uint8_t LFULogIncr(uint8_t counter) {
    if (counter == 255) return 255;      // 饱和

    double r = (double)rand() / RAND_MAX;
    double baseval = counter - LFU_INIT_VAL;
    if (baseval < 0) baseval = 0;

    // ★ 概率 p = 1 / (baseval * lfu_log_factor + 1)
    double p = 1.0 / (baseval * server.lfu_log_factor + 1);

    if (r < p) counter++;    // 概率递增
    return counter;
}
```

**概率曲线**：

| 当前 counter | baseval | p (lfu_log_factor=10) | 每次访问递增概率 |
|:-----------:|:-------:|:--------------------:|:--------------:|
| 0 | 0 | 1.0 | 100% |
| 5 (INIT_VAL) | 0 | 1.0 | 100% |
| 10 | 5 | ~0.02 | ~2% |
| 50 | 45 | ~0.002 | ~0.2% |
| 100 | 95 | ~0.001 | ~0.1% |
| 255 | 250 | ~0.0004 | ~0.04% |

低频率时几乎肯定增长，高频时增长概率极低——形成对数饱和曲线，使得少数高频访问不会无限制增长而淹没其他数据。

### 3.3 LFUDecrAndReturn——时间衰减

```c
// evict.c:319 — doom-lsp 确认
unsigned long LFUDecrAndReturn(robj *o) {
    unsigned long ldt = o->lru >> 8;                     // 上次衰减时间
    unsigned long counter = o->lru & 255;                 // 当前计数器
    unsigned long num_periods = server.lfu_decay_time ?
        LFUTimeElapsed(ldt) / server.lfu_decay_time : 0;  // 衰减期数
    if (num_periods)
        counter = (num_periods > counter) ? 0 : counter - num_periods;
    return counter;
}
```

`lfu-decay-time`（默认 1）定义每多少分钟衰减一次。衰减规则：
- 每经过 `lfu-decay-time` 分钟，counter 减 1
- 如果累计衰减期数超过 counter → counter 归零

这样，一个曾经频繁访问但最近不再使用的 key，其 counter 会随时间逐渐衰减，最终被淘汰。

### 3.4 淘汰池中的 LFU 分数计算

```c
// evict.c:181 — doom-lsp 确认
// pool 中存的是"反频率"——idle 越大表示访问越少
idle = 255 - LFUDecrAndReturn(o);
```

pool 按 `idle` 升序排列，淘汰时从最大值（访问最少）开始。

---

## 4. performEvictions——主淘汰循环

```c
// evict.c:540 — doom-lsp 确认
int performEvictions(void) {
    // 1. 安全检查
    if (!isSafeToPerformEvictions()) return EVICT_OK;
    // 脚本正在执行？加载中？从库忽略 maxmemory？client pause？→ 跳过

    // 2. 是否超限？
    if (getMaxmemoryState(&mem_reported, NULL, &mem_tofree, NULL) == C_OK)
        return EVICT_OK;  // 未超限

    // 3. noeviction 策略 → 拒写
    if (server.maxmemory_policy == MAXMEMORY_NO_EVICTION)
        return EVICT_FAIL;

    // 4. ★ 主淘汰循环
    while (mem_freed < (long long)mem_tofree) {
        // 4a. 填充淘汰池
        for (i = 0; i < server.dbnum; i++) {
            kvs_iter = (ALLKEYS) ?
                db->keys : db->expires;            // 作用域
            evictionPoolPopulate(i, dict, keydict, EvictionPoolLRU);
        }

        // 4b. 从池中选出最佳 candidate（pool[15] → pool[0]）
        for (k = EVPOOL_SIZE-1; k >= 0; k--) {
            if (pool[k].key == NULL) continue;
            // 检查 key 是否仍然存在
            if (kvstoreHashtableFind(...) == NULL) continue; // ghost key
            bestkey = ...; break;
        }

        // 4c. 删除 key
        if (server.lazyfree_lazy_eviction)
            dbAsyncDelete(db, keyobj);     // UNLINK 路径
        else
            dbSyncDelete(db, keyobj);      // DEL 路径
        mem_freed += delta;

        // 4d. 每 16 次删除检查：是否超时？
        if (keys_freed % 16 == 0) {
            if (elapsedUs(evictionTimer) > eviction_time_limit_us) {
                startEvictionTimeProc();    // 未完成 → 启动定时器
                break;
            }
        }
    }
}
```

### 4.1 时间预算——evictionTimeLimitUs

```c
// evict.c:499 — doom-lsp 确认
static unsigned long evictionTimeLimitUs() {
    if (server.maxmemory_eviction_tenacity <= 10)
        return 50uL * server.maxmemory_eviction_tenacity;  // ≤ 10 → 500us

    if (server.maxmemory_eviction_tenacity < 100)
        return (unsigned long)(500.0 * pow(1.15, tenacity - 10.0));  // 几何增长
    
    return ULONG_MAX;  // 100 → 无限制
}
```

`maxmemory-eviction-tenacity`（默认 10）控制淘汰力度。换算关系：

| tenacity | 时间预算 | 场景 |
|:--------:|:--------:|------|
| 0 | 0 | 淘汰被禁用 |
| 10（默认）| 500μs | 正常负载，快速采样 |
| 50 | ~8ms | 内存吃紧，加大淘汰力度 |
| 80 | ~2s | 极端场景 |
| 99 | ~2min | 极不推荐 |
| 100 | 无限 | — |

超过时间预算时，`performEvictions` 停止当前循环，通过 `startEvictionTimeProc` 注册一个 **aeTimeEvent** 继续在后续事件循环中淘汰：

```c
// evict.c:455 — doom-lsp 确认
static int evictionTimeProc(...) {
    if (performEvictions() == EVICT_RUNNING) return 0;  // 下次再淘汰
    isEvictionProcRunning = 0;
    return AE_NOMORE;  // 淘汰完毕，停止定时器
}
```

### 4.2 幽灵 key（Ghost Key）

淘汰池中的 key 可能在两次淘汰循环之间被其他命令删除（EXPIRE、DEL、或别的淘汰）。`performEvictions` 从池中选 candidate 时重新检查 key 是否存在：

```c
// evict.c:633-640 — doom-lsp 确认
de = kvstoreHashtableFind(db->keys, pool[k].key);
if (de) {
    bestkey = ((dictEntry*)de)->key;
    break;
} else {
    // Ghost key! 从池中移除，继续选下一个
}
```

ghost key 的 key 名已经在 pool 里但数据已被删除，读取并丢弃即可。

### 4.3 不计入的内存

```c
// evict.c:336 — doom-lsp 确认
size_t freeMemoryGetNotCountedMemory(void) {
    // AOF 缓冲区 + 复制缓冲区不计入淘汰内存
    // 防止 feedback loop：淘汰产生 DEL → AOF buf 增长 → 需要更多淘汰
}
```

淘汰循环中产生的 `DEL` 命令会被写入 AOF 缓冲区和复制缓冲区。如果把这些算进 `mem_used`，会导致"淘汰 → 缓冲区涨 → 仍需淘汰 → 更多 DEL → 缓冲区再涨"的死循环。

---

## 5. 内存分配的拦截——freeMemoryIfNeeded

淘汰触发点在 `processCommand` 执行写命令之前，以及 `zmalloc` 分配内存后：

```c
// server.c — doom-lsp 确认
// 每次写命令执行前：检查当前内存是否超限
int processCommand(client *c) {
    if (server.maxmemory && !isInsideYieldingLongCommand()) {
        int out_of_memory = (performEvictions() == EVICT_FAIL);
        if (out_of_memory && rejectCommand) {
            rejectCommand(c, shared.oomerr);  // OOM
            return C_OK;
        }
    }
}
```

```c
// evict.c:438 — doom-lsp 确认
// 大内存分配后：检查是否超限
int overMaxmemoryAfterAlloc(size_t moremem) {
    size_t mem_used = zmalloc_used_memory();
    if (mem_used + moremem <= server.maxmemory) return 0;  // 安全
    // 减去不计入的内存
    size_t overhead = freeMemoryGetNotCountedMemory();
    mem_used = (mem_used > overhead) ? mem_used - overhead : 0;
    return mem_used + moremem > server.maxmemory;
}
```

---

## 6. 时效性——老化（Aging）

```c
// server.h:113 — doom-lsp 确认
#define OBJ_SHARED_INTEGERS 10000
```

前面讲过共享整数对象范围 0~9999。对于 LRU 来说，共享整数对象的一个问题是——所有引用同一个共享整数 robj 的 key 共享同一个 `lru` 字段，导致"刚访问的和十年没访问的"看起来一样老。

此外，LRU 时钟的 194 天回绕也不能完全忽视——长期运行的 Redis 实例中，`lruclock` 可能回绕多次，`estimateObjectIdleTime` 只在"最近一次回绕"假设下工作，长期运行的 key 可能被错误淘汰。

Redis 通过 `serverCron` 每 100ms 更新一次全局 `server.lruclock`：

```c
// server.c — doom-lsp 确认
server.lruclock = getLRUClock();  // serverCron 中更新
```

`LRU_CLOCK()` 读取时优先取缓存值，减少系统调用：

```c
// evict.c:80 — doom-lsp 确认
unsigned int LRU_CLOCK(void) {
    unsigned int lruclock;
    if (1000/server.hz <= LRU_CLOCK_RESOLUTION) {
        atomicGet(server.lruclock, lruclock);  // 取缓存
    } else {
        lruclock = getLRUClock();               // 系统调用
    }
    return lruclock;
}
```

条件 `1000/server.hz <= 1000`：默认 `hz=10`，100ms 一次 serverCron → 1000/10=100 ≤ 1000 → true → 走缓存。如果配置了非常低的 `hz`（如 1），才需要每次系统调用。

---

## 7. 三种算法对比

| 维度 | LRU | LFU | TTL |
|------|-----|-----|-----|
| 淘汰依据 | 最后一次访问时间 | 访问频率 + 时间衰减 | 剩余过期时间 |
| 字段 | 24 bit 时钟戳 | 16 bit 时间戳 + 8 bit 计数器 | — |
| 适合场景 | 通用缓存 | 反热 key 倾斜，防止"缓存污染" | 已知 TTL 数据 |
| 主要缺陷 | 扫描型业务污染（一次性遍历清空热的） | 新 key 就绪慢（INIT_VAL=5） | TTL 越短越先被淘汰 |
| 精度控制 | `maxmemory-samples`（默认 5） | `lfu-log-factor` + `lfu-decay-time` | — |

---

## 8. 与系列前文的联系

淘汰机制是 redisObject 字段（第一篇）的消费者：

```
redisObject (16B)                     ← 01-data-model.md
├── lru (24 bit)
│   ├── LRU 模式：last access clock
│   └── LFU 模式：timestamp (16b) | counter (8b)
├── refcount                           ← 共享对象保护（OBJ_SHARED_INTEGERS）
└── ptr                                指向实际的 sds/dict/listpack 等

淘汰机制依赖前文：
  estimateObjectIdleTime    → 读 redisObject.lru 字段      ← 第一篇
  dictGetSomeKeys           → 随机采样 dict 中的 key       ← 第三篇
  intsetBlobLen             → SERVER 未用，但内存统计中    ← 第六篇
  dbAsyncDelete / dbSyncDelete → 删除 key                  ← 第九篇
  sdsclear / sdsfree         → 淘汰计数用 sds 作为 key 名  ← 第二篇
```
