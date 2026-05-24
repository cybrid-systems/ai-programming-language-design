# 11 — AOF：Redis 的命令日志持久化

> Redis 主线源码深度分析系列 · 第十一篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

RDB 是全量快照——定期把整个数据库 dump 成二进制文件。AOF（Append-Only File）则走另一条路：**记录每一个修改数据库的写命令**。重启时逐条回放命令，重建整个数据集。

AOF 的三大子机制：

```
AOF 日志
├── 实时写入：每执行一条写命令 → feedAppendOnlyFile → server.aof_buf
│   → flushAppendOnlyFile → write(2) → fsync(2)
│   （写入和刷盘时机由 appendfsync 控制）
│
├── 文件加载：启动时 loadSingleAppendOnlyFile → fake client 回放命令
│
└── 日志重写（Rewrite）：rewriteAppendOnlyFileRio
    → 扫描内存中的当前数据 → 写出压缩后的命令序列
    → 临时文件 → 原子替换旧 AOF 文件
```

**doom-lsp 确认**：核心文件

| 文件 | 行数 | 职责 |
|------|:----:|------|
| `src/aof.c` | 2724 | AOF 全部实现 |

---

## 1. AOF 文件格式

AOF 文件就是**RESP 协议文本**的串联：

```
*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n
*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n
*3\r\n$9\r\nPEXPIREAT\r\n$3\r\nkey\r\n$13\r\n1700000000000\r\n
```

本质上就是一个 RESP 命令序列——启动时用 fake client 逐条回放。

**AOF 文件的三种类型**（Redis 7.0+ 多部分 AOF）：

| 类型 | 文件 | 作用 |
|------|------|------|
| Base | `base.rdb` | RDB 格式全量快照（AOF 重写产物） |
| Incremental | `incr.aof` | 增量 RESP 命令日志 |
| Manifest | `aof-manifest` | 记录当前 Base + Incremental 的文件列表 |

`aof-manifest` 文件内容示例：

```
file appendonly.aof.1.base.rdb seq=1 type=b
file appendonly.aof.1.incr.aof seq=1 type=i
```

加载时先加载 base.rdb（RDB 格式，`rdbLoadRio`），再加载 incr.aof（RESP 格式，`loadSingleAppendOnlyFile`）。

---

## 2. 写命令的 AOF 路径

### 2.1 调用链

```
SET key value
  ↓
setCommand → ... → propagate()
  ↓
propagate() → feedAppendOnlyFile(dictid, argv, argc)
  ↓
  → 序列化为 RESP 协议字符串
  → 追加到 server.aof_buf（sds）
  ↓
beforesleep() → flushAppendOnlyFile(force=0)
  ↓
  → write(2) 到 AOF 文件
  → 按 appendfsync 策略 fsync
```

### 2.2 feedAppendOnlyFile——命令序列化

```c
// aof.c:1309 — doom-lsp 确认
void feedAppendOnlyFile(int dictid, robj **argv, int argc) {
    sds buf = sdsempty();

    // 1. 如果需要切换 DB，插入 SELECT 命令
    if (dictid != server.aof_selected_db) {
        buf = sdscatprintf(buf,
            "*2\r\n$6\r\nSELECT\r\n$%lu\r\n%s\r\n",
            (unsigned long)strlen(seldb), seldb);
        server.aof_selected_db = dictid;
    }

    // 2. 将命令序列化为 RESP 协议
    buf = catAppendOnlyGenericCommand(buf, argc, argv);

    // 3. 追加到全局 AOF 缓冲区
    if (server.aof_state == AOF_ON || ...)
        server.aof_buf = sdscatlen(server.aof_buf, buf, sdslen(buf));
}
```

`catAppendOnlyGenericCommand`（aof.c:1280）将任意命令转为 RESP：

```
SET key value
  → *3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n
```

### 2.3 flushAppendOnlyFile——写入 + 刷盘

```c
// aof.c:1062 — doom-lsp 确认
void flushAppendOnlyFile(int force) {
    // 空缓冲区时确保没遗漏 fsync
    if (sdslen(server.aof_buf) == 0) {
        if (server.aof_fsync == AOF_FSYNC_EVERYSEC &&
            server.aof_last_incr_fsync_offset != server.aof_last_incr_size &&
            !aofFsyncInProgress()) {
            goto try_fsync;   // 缓冲区空但需要 fsync
        }
        return;
    }

    // ★ EVERYSEC 策略：如果前一个 fsync 还在进行，最多等 2 秒
    if (server.aof_fsync == AOF_FSYNC_EVERYSEC && !force) {
        if (sync_in_progress) {
            if (server.aof_flush_postponed_start == 0) {
                server.aof_flush_postponed_start = server.unixtime;
                return;  // 推迟写入
            } else if (server.unixtime - server.aof_flush_postponed_start < 2) {
                return;  // 不到 2 秒，继续等
            }
            server.aof_delayed_fsync++;
        }
    }

    // ★ write(2)
    nwritten = aofWrite(server.aof_fd, server.aof_buf, sdslen(server.aof_buf));

    // ★ 写错误处理
    if (nwritten != sdslen(server.aof_buf)) {
        if (server.aof_fsync == AOF_FSYNC_ALWAYS)
            exit(1);  // always 策略下写失败 → 不可恢复，直接退出
        server.aof_last_write_status = C_ERR;
        return;
    }

    // ★ 清空缓冲区（小缓冲区 reuse，大缓冲区 free 重新分配）
    if ((sdslen(server.aof_buf)+sdsavail(server.aof_buf)) < 4000)
        sdsclear(server.aof_buf);
    else {
        sdsfree(server.aof_buf);
        server.aof_buf = sdsempty();
    }

try_fsync:
    // ★ fsync 按策略选择
    if (server.aof_fsync == AOF_FSYNC_ALWAYS) {
        redis_fsync(server.aof_fd);
    } else if (server.aof_fsync == AOF_FSYNC_EVERYSEC && ...) {
        if (!sync_in_progress)
            aof_background_fsync(server.aof_fd);
    }
}
```

### 2.4 fsync 三种策略

```c
// server.h — AOF fsync 策略
#define AOF_FSYNC_NO 0      // 不主动 fsync，交给 OS
#define AOF_FSYNC_ALWAYS 1  // 每次 write 后立即 fsync
#define AOF_FSYNC_EVERYSEC 2 // 每秒 bg fsync 一次
```

| 策略 | 写入时序 | 崩溃时丢数据 | 写 TPS |
|------|---------|:----------:|:------:|
| `no` | 依赖 OS 刷新 page cache | 最近 ~30 秒数据 | 最快 |
| `always` | write + fsync 同步 | 最多 1 条命令 | 最慢（~1000 TPS） |
| `everysec` | write 后后台线程 1 秒内 fsync | 最多 1 秒数据 | 接近 `no` |

**`fsync=always` 的退出策略**：如果 write 失败，`flushAppendOnlyFile` 直接 `exit(1)`。因为 always 策略承诺每次修改都同步到磁盘，写失败意味着打破了承诺，继续运行只会给出虚假的 ACK。

**`everysc` 的推迟机制**：如果前一次 `aof_background_fsync` 还没完成（磁盘忙），主线程最多等待 2 秒。如果超过 2 秒，强制 write 但不等 fsync。通过 `server.aof_delayed_fsync` 计数可监控这个情况。

### 2.5 缓冲区复用优化

```c
// aof.c:1235 — doom-lsp 确认
if ((sdslen(server.aof_buf)+sdsavail(server.aof_buf)) < 4000) {
    sdsclear(server.aof_buf);    // 小缓冲区：清除内容但保留内存
} else {
    sdsfree(server.aof_buf);     // 大缓冲区：释放重分配
    server.aof_buf = sdsempty();
}
```

阈值 4000 字节来自 jemalloc 的最小 arena 大小——4KB。缓冲区不大时复用 sds 分配的内存，减少 malloc 开销；

---

## 3. AOF 重写

### 3.1 为什么需要重写

AOF 是追加式日志——同一个键被修改 100 次，AOF 里就有 100 条 `SET` 命令：
```
SET key 1
SET key 2
...
SET key 100
```

重写（Rewrite）扫描当前数据库状态，只为每个 key 生成**一条**最终状态的命令：
```
SET key 100
```

对于集合类型，重写会批量生成紧凑格式：
```
SADD myset a b c d e f ...  // 最多 AOF_REWRITE_ITEMS_PER_CMD (64) 个元素
```

### 3.2 rewriteAppendOnlyFileRio——核心逻辑

```c
// aof.c:2247 — doom-lsp 确认
int rewriteAppendOnlyFileRio(rio *aof) {
    // 遍历每个 DB
    for (j = 0; j < server.dbnum; j++) {
        // SELECT DB
        rioWrite(aof, "*2\r\n$6\r\nSELECT\r\n", ...);
        rioWriteBulkLongLong(aof, j);

        // 遍历 dict 中的每个 key
        while ((de = dictNext(di)) != NULL) {
            o = dictGetVal(de);

            switch (o->type) {
            case OBJ_STRING:
                rioWrite(aof, "*3\r\n$3\r\nSET\r\n", ...);
                rioWriteBulkObject(aof, &key);
                rioWriteBulkObject(aof, o);
                break;
            case OBJ_LIST:
                rewriteListObject(aof, &key, o);
                break;   // → RPUSH key v1 v2 v3 ...
            case OBJ_SET:
                rewriteSetObject(aof, &key, o);
                break;   // → SADD key v1 v2 v3 ...
            case OBJ_ZSET:
                rewriteSortedSetObject(aof, &key, o);
                break;   // → ZADD key s1 m1 s2 m2 ...
            case OBJ_HASH:
                rewriteHashObject(aof, &key, o);
                break;   // → HMSET key f1 v1 f2 v2 ...
            case OBJ_STREAM:
                rewriteStreamObject(aof, &key, o);
                break;   // → XADD key ... 
            }

            // 过期时间
            if (expiretime != -1) {
                rioWrite(aof, "*3\r\n$9\r\nPEXPIREAT\r\n", ...);
                rioWriteBulkObject(aof, &key);
                rioWriteBulkLongLong(aof, expiretime);
            }
        }
    }
}
```

**命令大小限制**：`AOF_REWRITE_ITEMS_PER_CMD = 64`。每个 RPUSH/SADD/ZADD 命令最多携带 64 个元素，超长集合拆成多条命令，防止单条 RESP 过大。

### 3.3 BGREWRITEAOF——子进程重写

```c
// aof.c:2431 — doom-lsp 确认
int rewriteAppendOnlyFileBackground(void) {
    pid_t childpid;

    if ((childpid = redisFork()) == 0) {
        // 子进程
        char *tmpfile = "temp-rewriteaof-%d.aof";
        fp = fopen(tmpfile, "w");
        rioInitWithFile(&aof, fp);

        rewriteAppendOnlyFileRio(&aof);   // 在子进程中扫描内存，写新 AOF

        // 将重写期间的增量 AOF 数据合并
        aofRewriteBufferWrite(tmpfd, aof.fd);

        exitFromChild(0);
    }

    server.aof_rewrite_pid = childpid;
    // RDB 子进程期间同样让 dict 避免 resize（COW 保护）
}
```

### 3.4 重写期间的增量合并

BGREWRITEAOF 在子进程中扫描内存快照。但此时父进程仍在接受写入，这些增量写命令不能丢。

REDIS 用一个 **rewrite buffer**（`server.aof_rewrite_buf_blocks` 链表）来捕获重写期间的增量：

```
子进程扫描内存快照时：
  ↓
父进程的每个写命令 → propagate()
  → feedAppendOnlyFile           → 写入 aof_buf（当前 AOF 文件）
  → feedAppendOnlyFile + 标志     → 写入 aof_rewrite_buf_blocks（重写合并缓冲区）

重写完成后：将 aof_rewrite_buf_blocks 中的数据追加到新 AOF 文件末尾
→ 新 AOF 包含了"重写开始到结束期间的所有增量"
```

这样新 AOF 文件包含了**完整的数据集**，不丢失重写期间的任何写入。

---

## 4. AOF 加载

### 4.1 启动加载流程

```
loadDataFromDisk()
├── server.aof_enabled && aof_file 存在
│   → loadAppendOnlyFiles(aof_manifest)
│     ├── loadSingleAppendOnlyFile("base.aof")  → 用 fakeClient 回放 RDB 数据
│     └── loadSingleAppendOnlyFile("incr.aof")  → 回放 RESP 命令
│
├── 只有 rdb 文件
│   → rdbLoad(...)
```

### 4.2 loadSingleAppendOnlyFile——逐条回放

```c
// aof.c:1384 — doom-lsp 确认
int loadSingleAppendOnlyFile(char *filename) {
    // 1. 创建 fake client（不连接 socket，只用于解析和执行命令）
    fakeClient = createAOFClient();

    // 2. 逐条读取 RESP 命令
    while (1) {
        // 读一条 RESP 命令到 fakeClient->querybuf
        read: fakeClient->querybuf = sdsMakeRoomFor(fakeClient->querybuf, ...);
        nread = fread(fakeClient->querybuf + qb_len, 1, readlen, fp);

        // 3. processInputBuffer 协议解析
        if (processInputBuffer(fakeClient) == C_ERR) break;

        // 4. 命令已就绪 → processCommand 执行
        if (fakeClient->argc) {
            cmd = processCommand(fakeClient);
            resetClient(fakeClient);
        }
    }
}
```

**fakeClient**（`createAOFClient()`，aof.c:1389）：
- 用 `createClient(NULL)` 创建——不关联 socket
- 设置 `CLIENT_DENY_BLOCKING` 标志——禁止阻塞命令
- 设置 `replstate = SLAVE_STATE_WAIT_BGSAVE_START`——禁止回复输出

加载时每个命令通过 `processCommand` 正常执行，触发所有副作用（修改 dict、更新过期时间、触发 Lua 脚本等）。

### 4.3 截断处理

如果 AOF 文件末尾不完整（系统崩溃导致最后一条 write 不完整），加载器可以加载到最后一个完整命令为止：

```c
// aof.c — 截断检测
// 如果检测到文件末尾的命令不完整
if (truncated) {
    // 记录警告但继续加载前面的数据
    serverLog(LL_WARNING, "AOF 文件尾部截断，"
        "加载已有完整数据");
    ret = AOF_TRUNCATED;
}
```

这个行为受 `aof-load-truncated` 配置控制（默认 yes）。

---

## 5. 数据完整性对比

| 特性 | RDB | AOF |
|------|-----|-----|
| **格式** | 二进制，紧凑 | RESP 文本协议，可读 |
| **丢失窗口** | `save 900 1` → 最多 15 分钟 | `appendfsync always` → 0；`everysec` → 1 秒 |
| **恢复速度** | 快（二进制加载） | 慢（逐条回放命令） |
| **文件大小** | 小（快照） | 大（+ 重写控制） |
| **加载体积** | 加载后直接可用 | 需要重写合并 |
| **可读性** | 不可读 | `cat appendonly.aof` 可读 |

**Redis 7.0+ 混合持久化**：`aof-use-rdb-preamble` 开启后，AOF 重写的输出是 **RDB 格式**而不是 RESP 文本。加载时先用 `rdbLoadRio` 快速加载 RDB 部分，再回放增量 AOF 部分。既保留了 AOF 的低丢失窗口，又实现了接近 RDB 的加载速度。

---

## 6. AOF 与系列前文的联系

AOF 重写是所有类型的一次完整序列化扫描（`rewriteAppendOnlyFileRio`）。它逐个遍历 `server.db` 的 dict，然后按类型生成紧凑的 RESP 命令：

```
STRING = SET key val
LIST   = RPUSH key v1 v2 v3 ...
SET    = SADD key v1 v2 v3 ...
ZSET   = ZADD key s1 m1 s2 m2 ...
HASH   = HMSET key f1 v1 f2 v2 ...
STREAM = XADD key id f1 v1 ...
```

重写输出中的每个类型，都依赖于系列前文讲过的内部数据结构的遍历方法：

```
AOF 重写遍历                     → 读取系列前文的结构
rewriteListObject                → quicklist (04)
rewriteSetObject                 → intset / dict (06, 03)
rewriteSortedSetObject           → zskiplist / listpack (05, 04)
rewriteHashObject                → dict / listpack (03, 04)
rewriteStreamObject              → rax / listpack / streamCG (07)
```

---
