# 16 — 惰性释放与后台线程：Redis 的异步回收机制

> Redis 主线源码深度分析系列 · 第十六篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Redis 是单线程事件循环——任何耗时的操作都会阻塞整个服务。在早期 Redis 中，`DEL` 一个包含百万元素的大 key 会卡住服务数百毫秒，`FLUSHDB` 甚至可能卡住数秒。

解决方案：**释放大对象的工作交给后台线程处理**。这个机制由两个文件协作完成：

- `bio.c`：后台 I/O 线程框架——管理线程池、任务队列、条件变量
- `lazyfree.c`：惰性释放策略——判断什么该异步释放 + 各类释放函数

**doom-lsp 确认**：核心文件与符号

| 文件 | 行数 | doom-lsp 符号数 |
|------|:----:|:-------------:|
| `src/lazyfree.c` | 228 | 18 |
| `src/bio.c` | 320 | 6+ |
| `src/bio.h` | — | `BIO_LAZY_FREE` = 2 |

lazyfree.c 符号映射：

```
var lazyfree_objects @ 6        // 待释放对象计数（原子）
var lazyfreed_objects @ 7       // 已释放对象计数（原子）
fn lazyfreeFreeObject @ 11      // 后台线程释放单个对象
fn lazyfreeFreeDatabase @ 21    // 后台线程释放整个 DB
fn lazyFreeTrackingTable @ 33   // 后台线程释放 tracking table
fn lazyFreeLuaScripts @ 42      // 后台线程释放 Lua 脚本 dict
fn lazyFreeFunctionsCtx @ 51    // 后台线程释放 functions 上下文
fn lazyFreeReplicationBacklogRefMem @ 60 // 后台线程释放 repl backlog
fn lazyfreeGetPendingObjectsCount @ 72   // 获取待释放数
fn lazyfreeGetFreedObjectsCount @ 79     // 获取已释放数
fn lazyfreeResetStats @ 85      // 重置统计
fn lazyfreeGetFreeEffort @ 104  // ★ 评估释放工作量（类型+大小）
fn freeObjAsync @ 159           // ★ 异步释放对象（主线程入口）
fn emptyDbAsync @ 176           // ★ 异步清空 DB
fn freeTrackingRadixTreeAsync @ 187
fn freeLuaScriptsAsync @ 198
fn freeFunctionsAsync @ 208
fn freeReplicationBacklogRefMemAsync @ 218
```

bio.c 关键函数：

```
bioInit                            // 启动 3 个后台线程
bioProcessBackgroundJobs           // 线程主循环（等待 job → 处理）
bioCreateLazyFreeJob               // 投递惰性释放 job
bioCreateCloseJob                  // 投递后台 close(fd) job
bioCreateFsyncJob                  // 投递后台 fsync job
bioSubmitJob                       // 入队 + 条件变量 signal
```

---

## 1. BIO——后台 I/O 线程框架

### 1.1 三种后台任务

```c
// bio.h
#define BIO_CLOSE_FILE   0     // 后台 close(fd)
#define BIO_AOF_FSYNC    1     // 后台 fsync AOF
#define BIO_LAZY_FREE    2     // 后台惰性释放（本文核心）
#define BIO_NUM_OPS      3
```

启动时 `bioInit` 为每种类型创建一个专用线程：

```c
// bio.c — bioInit 核心
void bioInit(void) {
    for (j = 0; j < BIO_NUM_OPS; j++) {
        pthread_mutex_init(&bio_mutex[j], NULL);
        pthread_cond_init(&bio_newjob_cond[j], NULL);
        bio_jobs[j] = listCreate();       // 每线程一个任务队列
        bio_pending[j] = 0;
    }

    // 设置 4MB 线程栈
    for (j = 0; j < BIO_NUM_OPS; j++)
        pthread_create(&thread, &attr, bioProcessBackgroundJobs, (void*)(long)j);
}
```

### 1.2 线程主循环——bioProcessBackgroundJobs

```c
// bio.c — 线程主函数
void *bioProcessBackgroundJobs(void *arg) {
    unsigned long type = (unsigned long) arg;

    pthread_mutex_lock(&bio_mutex[type]);
    while (1) {
        // ★ 队列空 → 条件变量等待（不占 CPU）
        if (listLength(bio_jobs[type]) == 0) {
            pthread_cond_wait(&bio_newjob_cond[type], &bio_mutex[type]);
            continue;
        }

        // 出队 job
        ln = listFirst(bio_jobs[type]);
        job = ln->value;
        listDelNode(bio_jobs[type], ln);
        bio_pending[type]--;
        pthread_mutex_unlock(&bio_mutex[type]);

        // ★ 按类型 dispatch
        switch (type) {
        case BIO_CLOSE_FILE:
            close(job->fd_args.fd);
            break;
        case BIO_AOF_FSYNC:
            redis_fsync(job->fd_args.fd);
            break;
        case BIO_LAZY_FREE:
            // ★ 调用具体的释放函数
            job->free_args.free_fn(job->free_args.free_args);
            break;
        }

        zfree(job);  // 释放 job 结构
        pthread_mutex_lock(&bio_mutex[type]);
    }
}
```

### 1.3 投递任务——bioCreateLazyFreeJob

```c
// bio.c — 惰性释放 job 的创建
void bioCreateLazyFreeJob(lazy_free_fn free_fn, int arg_count, ...) {
    va_list valist;
    bio_job *job = zmalloc(sizeof(*job) + sizeof(void*) * arg_count);
    job->free_args.free_fn = free_fn;

    va_start(valist, arg_count);
    for (int i = 0; i < arg_count; i++)
        job->free_args.free_args[i] = va_arg(valist, void*);
    va_end(valist);

    bioSubmitJob(BIO_LAZY_FREE, job);  // 入队 + signal
}

void bioSubmitJob(int type, bio_job *job) {
    pthread_mutex_lock(&bio_mutex[type]);
    listAddNodeTail(bio_jobs[type], job);   // 入队
    bio_pending[type]++;
    pthread_cond_signal(&bio_newjob_cond[type]);  // 唤醒线程
    pthread_mutex_unlock(&bio_mutex[type]);
}
```

**无结果回传**——后台线程释放完成后不通知主线程。主线程通过 `bioPendingJobsOfType(BIO_LAZY_FREE)` 查询队列中是否还有 pending job。`evict.c` 的 `performEvictions` 在 `cant_free` 分支中会等待后台线程释放：

```c
// evict.c:677 — doom-lsp 确认
while (bioPendingJobsOfType(BIO_LAZY_FREE) && timer_not_expired) {
    if (getMaxmemoryState(...) == C_OK) break;
    usleep(1000);  // 等后台线程释放一些内存
}
```

---

## 2. lazyfree——惰性释放引擎

### 2.1 什么值得异步释放？

`lazyfreeGetFreeEffort`（`lazyfree.c:104`）评估释放一个对象的工作量：

```c
// lazyfree.c:104 — doom-lsp 确认
size_t lazyfreeGetFreeEffort(robj *key, robj *obj, int dbid) {
    if (obj->type == OBJ_LIST) {
        quicklist *ql = obj->ptr;
        return ql->len;                    // quicklist 节点数
    } else if (obj->type == OBJ_SET && obj->encoding == OBJ_ENCODING_HT) {
        return dictSize(obj->ptr);          // dict entry 数
    } else if (obj->type == OBJ_ZSET && ...) {
        return zs->zsl->length;             // skiplist 节点数
    } else if (obj->type == OBJ_HASH && ...) {
        return dictSize(obj->ptr);          // hash field 数
    } else if (obj->type == OBJ_STREAM) {
        // rax 节点数 + consumer group PEL 数量
        effort += s->rax->numnodes;
        effort += raxSize(s->cgroups) * (1 + raxSize(cg->pel));
        return effort;
    } else if (obj->type == OBJ_MODULE) {
        // 由模块自己的 free_effort 回调评估
        return moduleGetFreeEffort(key, obj, dbid);
    } else {
        return 1;  // intset/listpack/sds 等 → 单次分配
    }
}
```

**`LAZYFREE_THRESHOLD = 64`**：只有 `free_effort > 64` 且 `refcount == 1`（没有被共享引用）的对象才启用异步释放。

### 2.2 freeObjAsync——异步释放对象

```c
// lazyfree.c:159 — doom-lsp 确认
void freeObjAsync(robj *key, robj *obj, int dbid) {
    size_t free_effort = lazyfreeGetFreeEffort(key, obj, dbid);

    if (free_effort > LAZYFREE_THRESHOLD && obj->refcount == 1) {
        atomicIncr(lazyfree_objects, 1);       // 统计
        bioCreateLazyFreeJob(lazyfreeFreeObject, 1, obj);  // 投递 BIO
    } else {
        decrRefCount(obj);                     // 普通释放
    }
}
```

**被调用的场景**：

| 调用方 | 路径 | 配置 |
|--------|------|------|
| `dbSyncDelete` / `dbAsyncDelete` | `db.c` | `lazyfree_lazy_server_del` |
| `performEvictions` | `evict.c:663` | `lazyfree_lazy_eviction` |
| `dbOverwrite` | `db.c:269` | `lazyfree_lazy_server_del` |
| `emptyDb` (FLUSHDB) | `db.c` | `lazyfree_lazy_user_flush` |

### 2.3 lazyfreeFreeObject——后台执行

```c
// lazyfree.c:11 — doom-lsp 确认
void lazyfreeFreeObject(void *args[]) {
    robj *o = (robj *) args[0];
    decrRefCount(o);                        // 最终释放对象
    atomicDecr(lazyfree_objects, 1);
    atomicIncr(lazyfreed_objects, 1);
}
```

就是在一个后台线程中调用 `decrRefCount`。因为对象的引用计数降到 0，`decrRefCount` 会触发 `freeObject`/`freeHashObject`/`freeListObject`/`freeZsetObject` 等具体释放函数。这些函数在后台线程执行，不阻塞主线程。

### 2.4 emptyDbAsync——后台清空数据库

```c
// lazyfree.c:176 — doom-lsp 确认
void emptyDbAsync(redisDb *db) {
    // ★ 保存旧的 keys/expires kvstore
    kvstore *oldkeys = db->keys;
    kvstore *oldexpires = db->expires;

    // ★ 用全新的 kvstore 替换
    db->keys = kvstoreCreate(&kvstoreKeysHashtableType, 0, ...);
    db->expires = kvstoreCreate(&kvstoreExpiresHashtableType, 0, ...);

    // ★ 旧的 kvstore 交给后台线程释放
    atomicIncr(lazyfree_objects, kvstoreSize(oldkeys));
    bioCreateLazyFreeJob(lazyfreeFreeDatabase, 2, oldkeys, oldexpires);
}
```

**核心思路**：不释放数据，而是**偷天换日**。主线程瞬间得到一个空数据库（新建两个空 kvstore），旧的 kvstore 全部指给后台线程慢慢释放。`FLUSHDB ASYNC` 几乎瞬间完成——无论数据库多大。

### 2.5 lazyfreeFreeDatabase

```c
// lazyfree.c:21 — doom-lsp 确认
void lazyfreeFreeDatabase(void *args[]) {
    kvstore *kvs1 = (kvstore *) args[0];
    kvstore *kvs2 = (kvstore *) args[1];

    size_t numkeys = kvstoreSize(kvs1);
    kvstoreRelease(kvs1);   // 释放整个键空间
    kvstoreRelease(kvs2);   // 释放整个 expires 表
    atomicDecr(lazyfree_objects, numkeys);
    atomicIncr(lazyfreed_objects, numkeys);
}
```

---

## 3. 使用场景——同步 vs 异步的选择点

### 3.1 DEL vs UNLINK

```c
// db.c:737-741 — doom-lsp 确认
void delCommand(client *c) {
    delGenericCommand(c, 0);    // 同步删除
}

void unlinkCommand(client *c) {
    delGenericCommand(c, 1);    // 异步删除（走 freeObjAsync）
}

// db.c:719 — delGenericCommand
void delGenericCommand(client *c, int lazy) {
    for (j = 1; j < c->argc; j++) {
        if (lazy)
            dbAsyncDelete(c->db, c->argv[j]);   // → freeObjAsync → BIO
        else
            dbSyncDelete(c->db, c->argv[j]);    // → decrRefCount → 同步
    }
}
```

`DEL` 同步释放，适合小对象。`UNLINK` 异步释放，适合大对象。当 `free_effort ≤ LAZYFREE_THRESHOLD` 时，`freeObjAsync` 也会退化为同步释放。

### 3.2 FLUSHDB ASYNC vs 同步 FLUSHDB

```c
// db.c:680 — doom-lsp 确认
void flushdbCommand(client *c) {
    int flags = getFlushCommandFlags(c, "FLUSHDB");
    if (flags & FLUSH_ASYNC) {
        // ASYNC 模式
        kvstore *oldkeys = db->keys;
        kvstore *oldexpires = db->expires;
        db->keys = ...;    // 替换为空
        db->expires = ...;
        bioCreateLazyFreeJob(lazyfreeFreeDatabase, 2, oldkeys, oldexpires);
    } else {
        // 同步模式
        signalFlushedDb(dbid, ...);
        emptyDbStructure(db);      // 遍历删除所有 key
    }
}
```

### 3.3 淘汰与覆盖

```c
// evict.c:663 — doom-lsp 确认
if (server.lazyfree_lazy_eviction)
    dbAsyncDelete(db, keyobj);    // 淘汰走异步
else
    dbSyncDelete(db, keyobj);     // 淘汰走同步

// db.c:269 — dbOverwrite
if (server.lazyfree_lazy_server_del)
    freeObjAsync(key, old, db->id);  // 覆盖也走异步
else
    decrRefCount(old);
```

---

## 4. 性能预期

| 场景 | 同步阻塞 | 异步（主线程） | 后台线程 |
|------|---------|:------------:|:--------:|
| `DEL` 100 万元素的 list | ~300ms | — | — |
| `UNLINK` 100 万元素的 list | — | ~1μs（入队） | ~300ms |
| `FLUSHDB` 1000 万 key | ~5s | — | — |
| `FLUSHDB ASYNC` 1000 万 key | — | ~1μs（替换指针） | ~5s |
| 淘汰大 hash | ~50ms | — | — |
| lazy eviction 大 hash | — | ~1μs（入队） | ~50ms |

异步释放只适合**释放工作量远大于检查工作量**的场景。`freeObjAsync` 中的 `lazyfreeGetFreeEffort` 本身需要遍历统计大小——对于大对象，这个评估成本相对于释放成本来说微不足道。但对于小对象，评估成本可能接近释放成本本身，所以 `LAZYFREE_THRESHOLD=64` 筛选掉。

---

## 5. 与系列前文的联系

```
BIO 子系统 (bio.c)
├── BIO_CLOSE_FILE    (type=0)  → close(fd)        ← replication/replbacklog
├── BIO_AOF_FSYNC     (type=1)  → redis_fsync(fd)  ← AOF (11)
└── BIO_LAZY_FREE     (type=2)  → 看下方

BIO_LAZY_FREE 的释放函数 (lazyfree.c)
├── lazyfreeFreeObject      → decrRefCount(o)  ← 所有 robj 类型 (01)
├── lazyfreeFreeDatabase    → kvstoreRelease   ← dict (03)
├── lazyFreeTrackingTable   → raxFree          ← client tracking (07)
├── lazyFreeLuaScripts      → dictRelease      ← Lua scripting
├── lazyFreeFunctionsCtx    → functionsLibCtxFree ← functions
└── lazyFreeReplicationBacklogRefMem → listRelease + raxFree ← replication (14)

判断入口
├── freeObjAsync @159         → 由 dbAsyncDelete / eviction / dbOverwrite 调用
├── emptyDbAsync @176         → 由 FLUSHDB/FLUSHALL ASYNC 调用
└── freeTrackingRadixTreeAsync @187 → 由 CLIENT TRACKING 关闭时调用
```
