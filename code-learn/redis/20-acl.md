# 20 — ACL：Redis 的细粒度权限控制

> Redis 主线源码深度分析系列 · 第二十篇
> 基于 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

ACL（Access Control List）是 Redis 6.0 引入的权限系统，替代了旧的 `requirepass` 单一密码模式。每个用户可以拥有独立的命令权限、key 空间访问规则、Pub/Sub 通道权限。

权限模型：

```
USER ─→ 多个 Selector（任一匹配即通过）
          ├── 命令权限（允许/拒绝的命令位图 + 子命令白名单）
          ├── Key 模式（glob 模式匹配列表）
          └── 通道模式（Pub/Sub 通道匹配列表）
```

**doom-lsp 确认**：核心文件

| 文件 | 行数 | doom-lsp 符号数 |
|------|:----:|:-------------:|
| `src/acl.c` | 3051 | 131 |
| `src/server.h` | — | `user` / `aclSelector` 结构 |

关键符号链：完整 ACL 检查路径

```
ACLCheckAllPerm @1808          ← ★ 入口：每次 processCommand 前执行
└── ACLCheckAllUserCommandPerm @1767
    └── ACLSelectorCheckCmd @1612   ← 遍历所有 Selector
        ├── 命令位图检查
        │   └── ACLGetSelectorCommandBit @510
        ├── first-arg 白名单检查
        ├── ACLSelectorCheckKey @1505  ← Key 模式检查
        └── ACLCheckChannelAgainstList @1570  ← 通道检查

ACLSetUser @1233               ← 解析 ACL 规则字符串（"+@all ~* &*"）
ACLSetSelector @997            ← 设置单个 Selector
ACLStringSetUser @1981         ← ACL SETUSER 命令入口
```

数据结构：

```
user @server.h:1048+           // 用户（含密码哈希 + Selector 列表）
struct aclSelector @113        // Selector（权限集合）
struct keyPattern @257         // Key 模式条目
struct ACLLogEntry @2437       // ACL 日志条目
struct aclKeyResultCache @1591 // Key 检查缓存（加速多 Selector 场景）
```

---

## 1. 数据结构

### 1.1 aclSelector——权限集合

```c
// acl.c:113-135 — doom-lsp 确认
typedef struct {
    uint32_t flags;             // SELECTOR_FLAG_*（ALLKEYS, ALLCHANNELS, 等）
    uint64_t allowed_commands[USER_COMMAND_BITS_COUNT/64];
    // ★ 命令权限位图：USER_COMMAND_BITS_COUNT = ~300（命令总数）
    // 每个命令占 1 bit → ~5 个 uint64_t

    sds **allowed_firstargs;   // ★ 子命令白名单（每条命令一个 NULL 结尾的 sds 数组）
    list *patterns;            // ★ 允许的 key 模式列表（keyPattern*）
    list *channels;            // ★ 允许的通道模式列表
} aclSelector;
```

**命令位图**——`allowed_commands[5]`: 约 300 bit，每个命令一个 bit。设置 `+@all` 将所有位设为 1，`-SET` 将 SET 命令的位设为 0。

**子命令白名单**——`allowed_firstargs`: 当一条命令被拒绝但允许某些子命令时（如 `+CONFIG|GET -CONFIG|SET`），`allowed_firstargs` 保存允许的子命令列表。

### 1.2 user——用户

```c
// server.h:1048+ — doom-lsp 确认（ACLCreateUser → 结构在 server.h）
// 字段概要：
//   sds name
//   uint32_t flags          // USER_FLAG_*（OFF, NOPASS, DISABLED, SANITIZE_PAYLOAD）
//   list *selectors         // ★ 用户关联的 Selector 列表（可多个）
//   list *passwords         // SHA256 哈希密码列表
//   robj *acl_string        // ACL 规则的缓存字符串
```

**用户标志**：

| 标志 | 含义 |
|------|------|
| `USER_FLAG_OFF` | 用户被禁用 |
| `USER_FLAG_NOPASS` | 不需要密码 |
| `USER_FLAG_DISABLED` | 用户被禁用（同 OFF） |
| `USER_FLAG_SANITIZE_PAYLOAD` | 在 SLOWLOG 中脱敏 payload |

**多 Selector 机制**：一个用户可以有多个 Selector。检查时任意一个 Selector 匹配即通过（OR 语义）。每个 Selector 有独立的命令、key、通道权限。

### 1.3 keyPattern——Key 模式

```c
// acl.c:257 — doom-lsp 确认
typedef struct {
    uint32_t flags;        // 读写权限标志（KEY_FLAG_READ / KEY_FLAG_WRITE）
    sds pattern;           // glob 模式字符串
} keyPattern;
```

### 1.4 ACLLogEntry——ACL 日志

```c
// acl.c:2437 — doom-lsp 确认
typedef struct ACLLogEntry {
    int64_t count;        // 拒绝次数（合并相同条目）
    char *reason;          // 拒绝原因
    char *context;         // 上下文
    robj *object;          // 被拒绝的命令/key/channel
    sds username;          // 用户名
    mstime_t ctime;        // 创建时间
    sds cinfo;             // 客户端信息
} ACLLogEntry;
```

---

## 2. ACL 规则语法

ACL 规则在配置文件和 `ACL SETUSER` 命令中使用：

```bash
# 创建用户 alice，密码为 p@ss，可读所有 key，只允许 GET/MGET 命令
ACL SETUSER alice on >p@ss ~* +GET +MGET

# 创建用户 bob，密码为 secret，有全部权限
ACL SETUSER bob on >secret +@all ~* &*

# 拒绝特定命令的子命令
ACL SETUSER charlie -CONFIG +CONFIG|GET

# 限制 key 空间
ACL SETUSER dave ~objects:* ~users:*
```

**规则语法**：
```
on|off                ← 启用/禁用用户
>password             ← 添加密码（SHA256 哈希后存储）
#<hashed-password>    ← 直接设置 SHA256 哈希值
<password             ← 删除密码
nopass                ← 无密码
+@<category>          ← 添加命令类别（+@all 所有命令）
-@<category>          ← 删除命令类别
+<command>            ← 允许命令
-<command>            ← 拒绝命令
+<command>|<sub>      ← 允许特定子命令
~<pattern>            ← 添加 key 模式
*<pattern>            ← 添加通道模式
resetkeys             ← 重置所有 key 模式
resetchannels         ← 重置所有通道模式
```

---

## 3. 权限检查路径

### 3.1 完整检查流程

每次命令执行前，`processCommand` 调用 ACL 检查：

```c
// server.c — processCommand 中的 ACL 检查
int processCommand(client *c) {
    // ★ ACL 认证检查
    if (server.acl_enabled && !c->authenticated) {
        addReplyError(c, "NOAUTH Authentication required.");
        return C_OK;
    }

    // ★ ACL 权限检查
    int acl_errpos;
    int acl_retval = ACLCheckAllPerm(c, &acl_errpos);
    if (acl_retval != ACL_OK) {
        addACLLogEntry(c, acl_retval, ACL_LOG_CTX_TOPLEVEL, ...);
        addReplyErrorFormat(c, "NOPERM ...");
        return C_OK;
    }

    call(c, CMD_CALL_FULL);  // 执行命令
}
```

### 3.2 ACLCheckAllPerm——入口

```c
// acl.c:1808 — doom-lsp 确认
int ACLCheckAllPerm(client *c, int *idxptr) {
    return ACLCheckAllUserCommandPerm(c->user, c->cmd, c->argv, c->argc, idxptr);
}
```

### 3.3 ACLCheckAllUserCommandPerm——遍历 Selector

```c
// acl.c:1767 — doom-lsp 确认
int ACLCheckAllUserCommandPerm(user *u, struct redisCommand *cmd,
                                robj **argv, int argc, int *idxptr) {
    if (u == NULL) return ACL_OK;   // 无关联用户 → 放行

    int relevant_error = ACL_DENIED_CMD;
    aclKeyResultCache cache;
    initACLKeyResultCache(&cache);

    // ★ 遍历所有 Selector，任一匹配即通过
    listRewind(u->selectors, &li);
    while ((ln = listNext(&li))) {
        aclSelector *s = (aclSelector *) listNodeValue(ln);
        int acl_retval = ACLSelectorCheckCmd(s, cmd, argv, argc,
                                              &local_idxptr, &cache);
        if (acl_retval == ACL_OK) {
            cleanupACLKeyResultCache(&cache);
            return ACL_OK;          // 该 Selector 匹配 → 放行
        }
        // OR 语义：记录最严重的拒绝原因
        if (acl_retval > relevant_error || ...)
            relevant_error = acl_retval;
    }

    *idxptr = last_idx;
    return relevant_error;          // 全部拒绝 → 返回错误
}
```

### 3.4 ACLSelectorCheckCmd——单 Selector 的三层检查

```c
// acl.c:1612 — doom-lsp 确认
int ACLSelectorCheckCmd(aclSelector *s, struct redisCommand *cmd,
                        robj **argv, int argc, int *idxptr,
                        aclKeyResultCache *cache) {
    // ★ 第一层：命令权限
    if (!ACLGetSelectorCommandBit(s, cmd->id)) {
        // 命令被拒绝，检查是否有子命令白名单
        if (argc >= 2 && ACLSelectorCanExecuteFutureCommands(s, cmd->id)) {
            // ★ 检查 argv[1] 是否在白名单中
            sds **first_args = s->allowed_firstargs;
            if (first_args[cmd->id]) {
                for (int i = 0; first_args[cmd->id][i]; i++) {
                    if (!sdscmp(first_args[cmd->id][i], argv[1]->ptr))
                        goto command_ok;  // 子命令匹配
                }
            }
        }
        return ACL_DENIED_CMD;
    }

command_ok:
    // ★ 第二层：Key 模式检查
    // 对 argv 中每个 key 参数调用 ACLSelectorCheckKey
    for (...) {
        if (ACLSelectorCheckKey(s, key, flags, cache) != ACL_OK)
            return ACL_DENIED_KEY;
    }

    // ★ 第三层：通道模式检查（只对 PUBLISH/SUBSCRIBE 等）
    if (is_pubsub_command && !ACLCheckChannelAgainstList(s, channel))
        return ACL_DENIED_CHANNEL;

    return ACL_OK;
}
```

返回值优先级（`relevant_error` 取最大值）：

| 返回值 | 含义 |
|:------:|------|
| `ACL_OK` (0) | 通过 |
| `ACL_DENIED_CMD` (1) | 命令被拒绝 |
| `ACL_DENIED_KEY` (2) | Key 被拒绝 |
| `ACL_DENIED_CHANNEL` (3) | 通道被拒绝 |

---

## 4. 认证

### 4.1 密码管理

```c
// acl.c:168 — doom-lsp 确认
int ACLHashPassword(char *password) {
    // SHA256 哈希密码
    SHA256_CTX ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, password, strlen(password));
    sha256_final(&ctx, hash);
    // 返回 64 字符十六进制字符串
}
```

密码以 SHA256 哈希形式存储在 `user->passwords` 列表中。原始密码永不落盘。

### 4.2 AUTH 命令

```c
// acl.c:3003 — doom-lsp 确认
void authCommand(client *c) {
    if (c->argc == 2) {
        // AUTH <password> → 检查默认用户
        if (ACLAuthenticateUser(DefaultUser, c->argv[1]) == C_OK) {
            c->authenticated = 1;
            c->user = DefaultUser;
        }
    } else if (c->argc == 3) {
        // AUTH <username> <password>
        user *u = ACLGetUserByName(c->argv[1]->ptr, sdslen(c->argv[1]->ptr));
        if (u && ACLAuthenticateUser(u, c->argv[2]) == C_OK) {
            c->authenticated = 1;
            c->user = u;
        }
    }
}
```

### 4.3 认证缓存

```c
// acl.c:1393 — doom-lsp 确认
int ACLCheckUserCredentials(robj *username, robj *password) {
    user *u = ACLGetUserByName(username->ptr, sdslen(username->ptr));
    if (u == NULL) return C_ERR;
    if (u->flags & USER_FLAG_NOPASS) return C_OK;

    // 逐个密码检查（SHA256 哈希比对）
    listRewind(u->passwords, &li);
    while ((ln = listNext(&li))) {
        sds hashed = ln->value;
        if (ACLCheckPasswordHash(password, hashed)) return C_OK;
    }
    return C_ERR;
}
```

密码检查使用 `time_independent_strcmp`（`acl.c:158`）——恒定时间比较，防止时序侧信道攻击。

---

## 5. 日志与审计

被 ACL 拒绝的操作记录到 ACL 日志中：

```c
// acl.c:2485 — doom-lsp 确认
void addACLLogEntry(client *c, int reason, int context, ...) {
    // 创建 ACLLogEntry
    // 加入 server.acllog 队列
    // 如果队列超过 maxlen，淘汰最老的
}
```

通过 `ACL LOG` 命令查看：

```
redis> ACL LOG
1) 1) "count"
   2) (integer) 1
   3) "reason"
   4) "command"
   5) "context"
   6) "toplevel"
   7) "object"
   8) "CONFIG"
   9) "username"
   10) "alice"
   11) "age-seconds"
   12) "25.34"
   13) "client-info"
   14) "id=5 addr=127.0.0.1:54321 ..."
```

---

## 6. 完整性保护

ACL 规则支持在运行时动态变更：

```
ACL SETUSER alice -SET                # 拒绝 SET
ACL SETUSER alice +SET                # 允许 SET
ACL SETUSER alice ~newpattern:*        # 添加 key 模式
ACL DELUSER alice                      # 删除用户
ACL SAVE                               # 保存到 aclfile
```

**ACL SAVE**（`aclsaveCommand`）将当前 ACL 规则写入 `aclfile`。读取用 `ACL LOAD`。

**ACL 文件格式**（`acl.c:2336 ACLSaveToFile`）：

```
user alice on >hashed-password ~cached:* +GET +MGET -@all +@read
user bob on nopass ~* +@all &*
```

---

## 7. 与系列前文的联系

```
ACL 系统覆盖了系列中多个子系统：

ACL SETUSER alice ~objects:*     ← key 模式匹配用于 lookUpKey (13)
ACL SETUSER alice &channel:*     ← 通道匹配用于 PUBLISH (19)
ACL SETUSER alice +SET -DEL      ← 命令位图在 processCommand 中检查 (09)
ACL LOG                          ← 拒绝日志存储在 server.acllog

AUTH alice password
  → ACLAuthenticateUser          ← SHA256 哈希比对
  → c->user = DefaultUser        ← client.user 指针

processCommand(client)
  → ACLCheckAllPerm              ← 每次命令执行前调用
    → ACLCheckAllUserCommandPerm
      → ACLSelectorCheckCmd       ← 命令 + key + 通道三重检查
```

ACL 系统是 Redis 中覆盖面最广的特征之一——它渗透在命令执行、key 空间访问、Pub/Sub 消息分发等几乎每个子系统中。
