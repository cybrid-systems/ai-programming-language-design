# 15 — 事务与 WATCH：Redis 的乐观锁与原子执行

> Redis 主线源码深度分析系列 · 第十五篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

Redis 的事务有一套自己的设计哲学——它不提供传统数据库的回滚（rollback），也不需要两阶段锁（2PL）。Redis 用两个正交的机制实现原子性与隔离性：

- **MULTI / EXEC / DISCARD**：命令队列的**原子批处理**。MULTI 后所有命令不执行只入队，EXEC 时一次性执行全部。
- **WATCH**：**乐观锁（optimistic locking）**。在 EXEC 之前检测被 watch 的 key 是否被其他客户端修改过——如果修改了，EXEC 返回 nil 不执行。

**doom-lsp 确认**：核心文件

| 文件 | 行数 | doom-lsp 符号数 |
|------|:----:|:-------------:|
| `src/multi.c` | 480 | 22 |
| `src/db.c` | — | `signalModifiedKey` → `touchWatchedKey` |

doom-lsp 完整符号列表：

```
struct watchedKey @271           // WATCH 条目（key + db + client + expired flag）
fn initClientMultiState @35      // 初始化事务状态
fn freeClientMultiState @45      // 释放事务状态
fn queueMultiCommand @60         // ★ 命令入队
fn discardTransaction @98        // 回滚事务
fn flagTransaction @107          // 标记 DIRTY_EXEC
fn multiCommand @112             // MULTI 命令
fn discardCommand @122           // DISCARD 命令
fn execCommand @148              // ★ EXEC 命令（事务执行核心）
fn watchForKey @279              // ★ WATCH 一个 key
fn unwatchAllKeys @312           // 清空 WATCH 列表
fn isWatchedKeyExpired @340      // 检查 watched key 是否过期
fn touchWatchedKey @357          // ★ 修改 key 时标记 dirty
fn touchAllWatchedKeysInDb @405  // FLUSHDB/SWAPDB 时的全局 touch
fn watchCommand @450             // WATCH 命令
fn unwatchCommand @467           // UNWATCH 命令
fn multiStateMemOverhead @473    // 内存开销统计
```

---

## 1. MULTI / EXEC——命令队列

### 1.1 MULTI——进入事务模式

```c
// multi.c:112 — doom-lsp 确认
void multiCommand(client *c) {
    if (c->flags & CLIENT_MULTI) {
        addReplyError(c, "MULTI calls can not be nested");
        return;                          // 不允许嵌套 MULTI
    }
    c->flags |= CLIENT_MULTI;            // 设置事务标志
    addReply(c, shared.ok);
}
```

`CLIENT_MULTI` 标志一旦设置，后续的写命令不再直接执行，而是入队。

### 1.2 命令入队——queueMultiCommand

当 `CLIENT_MULTI` 标志设置时，`processCommand()` 不会立即执行命令，而是调用 `queueMultiCommand`：

```c
// multi.c:60 — doom-lsp 确认
void queueMultiCommand(client *c, uint64_t cmd_flags) {
    // ★ 如果事务已经被标记失效，直接跳过（浪费内存没意义）
    if (c->flags & (CLIENT_DIRTY_CAS | CLIENT_DIRTY_EXEC))
        return;

    // 初始分配 2 个 multiCmd 槽位（默认至少两个命令）
    if (c->mstate.count == 0) {
        c->mstate.commands = zmalloc(sizeof(multiCmd) * 2);
        c->mstate.alloc_count = 2;
    }
    // 扩容：翻倍
    if (c->mstate.count == c->mstate.alloc_count) {
        c->mstate.alloc_count *= 2;
        c->mstate.commands = zrealloc(c->mstate.commands,
            sizeof(multiCmd) * c->mstate.alloc_count);
    }

    // ★ 从 client 结构复制命令（argv 是 robj**，需要 incrRefCount）
    multiCmd *mc = c->mstate.commands + c->mstate.count;
    mc->cmd = c->cmd;
    mc->argc = c->argc;
    mc->argv = c->argv;
    mc->argv_len = c->argv_len;

    c->mstate.count++;
    c->mstate.cmd_flags |= cmd_flags;
    c->mstate.argv_len_sums += c->argv_len_sum + sizeof(robj*) * c->argc;

    // ★ 清零 client 参数（所有权转移到 mstate）
    c->argv = NULL;
    c->argc = 0;
    c->argv_len_sum = 0;
    c->argv_len = 0;
}
```

**入队时机**——`processCommand` 中的关键路径：

```c
// server.c — processCommand
int processCommand(client *c) {
    // ... 权限检查、集群重定向 ...

    // ★ 如果在 MULTI 模式中且不是 EXEC/DISCARD/WATCH/MULTI，则入队
    if (c->flags & CLIENT_MULTI &&
        c->cmd->proc != execCommand &&
        c->cmd->proc != discardCommand &&
        c->cmd->proc != multiCommand &&
        c->cmd->proc != watchCommand &&
        c->cmd->proc != unwatchCommand)
    {
        queueMultiCommand(c, cmd_flags);
        addReply(c, shared.queued);       // 回复 +QUEUED
        return C_OK;
    }

    // 普通模式：直接执行
    call(c, CMD_CALL_FULL);
}
```

**事务中最损坏的命令**会将事务标记为 `DIRTY_EXEC`；`queueMultiCommand` 遇到 `DIRTY_EXEC` 直接跳过——相当于后续命令的 `+QUEUED` 也不会再回复。

### 1.3 DISCARD——放弃事务

```c
// multi.c:122 — doom-lsp 确认
void discardCommand(client *c) {
    if (!(c->flags & CLIENT_MULTI)) {
        addReplyError(c, "DISCARD without MULTI");
        return;
    }
    discardTransaction(c);
    addReply(c, shared.ok);
}

// multi.c:98 — doom-lsp 确认
void discardTransaction(client *c) {
    freeClientMultiState(c);     // 释放所有入队命令的 argv
    initClientMultiState(c);     // 重置 mstate
    c->flags &= ~(CLIENT_MULTI | CLIENT_DIRTY_CAS | CLIENT_DIRTY_EXEC);
    unwatchAllKeys(c);            // 清空 WATCH
}
```

### 1.4 EXEC——原子执行

```c
// multi.c:148 — doom-lsp 确认
void execCommand(client *c) {
    if (!(c->flags & CLIENT_MULTI)) {
        addReplyError(c, "EXEC without MULTI");
        return;
    }

    // ★ 检查 WATCH 的 key 是否过期
    //    事务期间过期的 key 也视为脏，abort
    if (isWatchedKeyExpired(c))
        c->flags |= CLIENT_DIRTY_CAS;

    // ★ 两个 abort 条件
    if (c->flags & (CLIENT_DIRTY_CAS | CLIENT_DIRTY_EXEC)) {
        if (c->flags & CLIENT_DIRTY_EXEC)
            addReplyErrorObject(c, shared.execaborterr);  // -EXECABORT
        else
            addReply(c, shared.nullarray[c->resp]);       // *-1 (nil)

        discardTransaction(c);
        return;
    }

    // ★ 执行所有入队命令
    unwatchAllKeys(c);        // 先清空 WATCH（避免 CPU 浪费）
    server.in_exec = 1;

    addReplyArrayLen(c, c->mstate.count);  // 响应数组长度

    for (j = 0; j < c->mstate.count; j++) {
        c->argc = c->mstate.commands[j].argc;
        c->argv = c->mstate.commands[j].argv;
        c->cmd = c->mstate.commands[j].cmd;

        // ★ 重做 ACL 检查（入队后 ACL 可能已变更）
        acl_retval = ACLCheckAllPerm(c, &acl_errpos);
        if (acl_retval != ACL_OK) {
            addReplyErrorFormat(c, "-NOPERM ...");
        } else {
            call(c, CMD_CALL_FULL);  // 正常执行
        }

        // 恢复 mstate（call 可能修改了 argv）
        c->mstate.commands[j].argc = c->argc;
        c->mstate.commands[j].argv = c->argv;
    }

    discardTransaction(c);    // 释放事务状态
    server.in_exec = 0;
}
```

**执行时的特殊行为**：

1. **ACL 重检查**：入队时间和 EXEC 时间之间，ACL 可能被修改。EXEC 时重新检查每条命令的权限。
2. **拒绝阻塞命令**：`CLIENT_DENY_BLOCKING` — 事务中不允许 BLPOP 等阻塞命令。
3. **每条命令的结果被收集**：`addReplyArrayLen` 先声明响应数组长度，然后依次输出每个命令的回复。

---

## 2. WATCH——乐观锁

WATCH 实现了一种**CAS（Compare-And-Swap）**语义。它不是在 WATCH 时锁住 key，而是在 EXEC 时检查 key 是否被修改过。

### 2.1 数据结构

```c
// multi.c:271 — doom-lsp 确认
typedef struct watchedKey {
    robj *key;
    redisDb *db;
    client *client;
    unsigned expired:1;  // WATCH 时 key 已过期
} watchedKey;
```

每个 client 有一个 `watched_keys` 链表：

```c
// server.h — client 中的相关字段
list *watched_keys;                // 此 client watch 的 key 列表（watchedKey*）
dict *watched_keys;                // DB 级的 dict: key → list<watchedKey*>
```

全局的数据流：

```
client[WATCH key1, key2]
  │
  │  c->watched_keys 链表：
  │  [wk(key1,db,c)] → [wk(key2,db,c)]
  │
  │  db->watched_keys dict：
  │  key1 → list<wk1(idle), wk3(other_client)>
  │  key2 → list<wk2(this_client)>
```

key 被修改时（`SET key`），`signalModifiedKey` → `touchWatchedKey` 会遍历 `db->watched_keys[key]` 链表，给所有 watch 这个 key 的 client 打上 `CLIENT_DIRTY_CAS` 标记。

### 2.2 watchForKey——注册观察者

```c
// multi.c:279 — doom-lsp 确认
void watchForKey(client *c, robj *key) {
    // 1. 去重：已经 watch 的就跳过
    listRewind(c->watched_keys, &li);
    while ((ln = listNext(&li))) {
        wk = listNodeValue(ln);
        if (wk->db == c->db && equalStringObjects(key, wk->key))
            return;
    }

    // 2. 在 db->watched_keys 中创建或复用 key → list
    clients = dictFetchValue(c->db->watched_keys, key);
    if (!clients) {
        clients = listCreate();
        dictAdd(c->db->watched_keys, key, clients);
        incrRefCount(key);           // key 名引用计数++
    }

    // 3. 创建 watchedKey 结构
    wk = zmalloc(sizeof(*wk));
    wk->key = key;
    wk->client = c;
    wk->db = c->db;
    wk->expired = keyIsExpired(c->db, key);  // ★ 记录是否已过期

    incrRefCount(key);   // 另一个引用计数（client->watched_keys 也需要）
    listAddNodeTail(c->watched_keys, wk);      // client 链表
    listAddNodeTail(clients, wk);              // DB 级链表
}
```

**`expired` flag**：如果 WATCH 时 key 已过期（在 expires dict 中但已到过期时间），`expired=1`。后续 key 被删除（惰性过期或主动过期）不算"修改"——因为 WATCH 时它就已经是逻辑不存在的状态。这个 flag 避免了一个已过期 key 被删除时错误地触发 EXEC abort。

### 2.3 touchWatchedKey——修改时触发

```c
// multi.c:357 — doom-lsp 确认
void touchWatchedKey(redisDb *db, robj *key) {
    if (dictSize(db->watched_keys) == 0) return;
    clients = dictFetchValue(db->watched_keys, key);
    if (!clients) return;

    listRewind(clients, &li);
    while ((ln = listNext(&li))) {
        watchedKey *wk = listNodeValue(ln);
        client *c = wk->client;

        // ★ expired flag 特殊处理
        if (wk->expired) {
            // 如果 key 从已过期变为已删除，不算 dirty（逻辑无变化）
            if (kvstoreHashtableFind(db->keys, 0, key->ptr, ...) == NULL) {
                wk->expired = 0;        // 清理标记
                goto skip_client;       // 不标记 dirty
            }
            break;  // 否则 normal path
        }

        c->flags |= CLIENT_DIRTY_CAS;  // ★ 标记为脏！
        // 一经标记就清空该 client 的所有 WATCH（释放内存）
        unwatchAllKeys(c);

    skip_client: continue;
    }
}
```

**调用链**：所有修改 key 的命令最终都会调用 `signalModifiedKey` → `touchWatchedKey`：

```
SET key value
  → setKey(db, key, val)        ← db.c:309
    → signalModifiedKey(db, key) ← db.c:604
      → touchWatchedKey(db, key) ← multi.c:357
        → client->flags |= CLIENT_DIRTY_CAS
```

DEL、RENAME、MOVE、LPUSH、SADD……所有修改操作都走这个路径。

### 2.4 EXEC 时的 WATCH 检查

EXEC 时做三件事：

```c
// execCommand — WATCH 相关检查
// 1. 检查已过期的 watched key
if (isWatchedKeyExpired(c))
    c->flags |= CLIENT_DIRTY_CAS;

// 2. 如果 dirty → 返回 nil
if (c->flags & CLIENT_DIRTY_CAS) {
    addReply(c, shared.nullarray[c->resp]);  // *-1\r\n (RESP2) 或 []\r\n (RESP3)
    discardTransaction(c);
    return;
}
```

`isWatchedKeyExpired`（`multi.c:340`）遍历 `c->watched_keys` 链表，检查任何 WATCH 时未过期但**现在已过期**的 key：

```c
int isWatchedKeyExpired(client *c) {
    while ((ln = listNext(&li))) {
        wk = listNodeValue(ln);
        if (wk->expired) continue;  // WATCH 时已过期 → 忽略
        if (keyIsExpired(wk->db, wk->key)) return 1;  // 现在过期了！
    }
    return 0;
}
```

### 2.5 unwatchAllKeys——清理

```c
// multi.c:312 — doom-lsp 确认
void unwatchAllKeys(client *c) {
    while ((ln = listNext(&li))) {
        wk = listNodeValue(ln);
        // 从 db->watched_keys[key] 链表中移除
        clients = dictFetchValue(wk->db->watched_keys, wk->key);
        listDelNode(clients, listSearchKey(clients, wk));
        if (listLength(clients) == 0)
            dictDelete(wk->db->watched_keys, wk->key);  // 空链表 → 删除 dict 条目

        // 从 client 链表中移除
        listDelNode(c->watched_keys, ln);
        decrRefCount(wk->key);
        zfree(wk);
    }
}
```

**被自动调用的时机**：
- `EXEC`（执行前清空，避免后续操作浪费 CPU）
- `DISCARD`（放弃事务）
- `UNWATCH`（主动解除 watch）
- `freeClient`（client 断开时清理）

---

## 3. 事务的隔离特性

### 3.1 原子性

`EXEC` 执行期间，其他 client 的命令**不会插入**——因为 Redis 是单线程事件循环。`EXEC` 中的多条命令一次性连续执行完毕才返回事件循环。

但也意味着：如果 `EXEC` 执行到第 N 条命令时发生错误，前 N-1 条命令的修改已经生效。**Redis 不回滚**——`execCommand` 不提供 `undo` 机制。

### 3.2 WATCH + MULTI = 乐观锁

```
Client A:                      Client B:
WATCH balance                  (nothing)
MULTI
INCR balance
                              INCR balance  ← 修改了同一个 key
EXEC → 返回 nil
      (A 的 INCR 未执行)
```

没有锁，没有阻塞。如果 A 的 EXEC 检测到 WATCH 的 key 被修改过，EXEC 返回 nil 不执行。应用程序重试整个事务即可。

### 3.3 DISCARD 时的 DIRTY_CAS

```c
// multi.c:98 — doom-lsp 确认
void discardTransaction(client *c) {
    freeClientMultiState(c);
    initClientMultiState(c);
    c->flags &= ~(CLIENT_MULTI | CLIENT_DIRTY_CAS | CLIENT_DIRTY_EXEC);
    unwatchAllKeys(c);
}
```

DISCARD 清理所有标记。如果 client 在 EXEC 之前决定不执行了，一切恢复原状。

---

## 4. 与系列前文的联系

```
WATCH key
  → watchForKey(multi.c:279)
    → c->watched_keys 链表
    → db->watched_keys dict  ← (03: dict)

SET key value
  → setKey(db.c)
    → signalModifiedKey(db.c:604)
      → touchWatchedKey(multi.c:357)
        → client->flags |= CLIENT_DIRTY_CAS
        → unwatchAllKeys(c)   ← 清空 WATCH 链表释放内存

MULTI
  → multiCommand(multi.c:112)
    → c->flags |= CLIENT_MULTI

SET key value (在 MULTI 中)
  → processCommand(server.c)
    → queueMultiCommand(multi.c:60)
      → c->mstate.commands[] 数组 ← 命令参数复制（robj 引用计数）

EXEC
  → execCommand(multi.c:148)
    → isWatchedKeyExpired   → (13: db.c keyIsExpired)
    → CLIENT_DIRTY_CAS/EXEC 检查
    → call(c, CMD_CALL_FULL)  ← (09: networking 的命令执行)
      → 每条命令的响应收集为数组
    → discardTransaction
```
