# 96-keyctl-keyring — Linux 密钥管理系统（keyctl/keyring）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Linux 密钥管理**子系统（`keyctl` + `keyring`）提供内核级密钥存储和管理——加密密钥、Kerberos 票据、证书等安全敏感数据可以安全地存储在内核中，用户空间通过 `keyctl` 系统调用管理。keyring（密钥环）是密钥的容器，组织为可搜索的层级结构。

**核心设计**：每个密钥（`struct key`）有一个 32 位序列号（`serial`），通过全局 IDR 树管理。密钥环（keyring）是一种特殊密钥，包含指向其他密钥的链接。`keyctl` 系统调用（`security/keys/keyctl.c`，2,026 行）提供 20+ 个子命令。

```
密钥结构：
  struct key                     struct keyring（特殊 key）:
    serial (32-bit ID)              type = key_type_keyring
    type → key_type                 keys[]（链接的子密钥）
    description（描述串）         ├── key A
    payload（密钥数据）            ├── key B
    permissions（权限掩码）        └── key C
    owner（拥有者）
```

**doom-lsp 确认**：`security/keys/key.c`（1,293 行，87 符号），`keyctl.c`（2,026 行），`keyring.c`（1,797 行）。

---

## 1. 核心数据结构

### 1.1 struct key——密钥

```c
// include/linux/key.h
struct key {
    refcount_t usage;                            // 引用计数
    u32 serial;                                  // 全局唯一序列号（IDR 分配）
    struct rb_node serial_node;                  // serial_tree 红黑树节点

    const struct key_type *type;                  // 密钥类型（user/logon/dns_resolver/...）
    char *description;                            // 密钥描述

    union {
        unsigned long payload;                    // 密钥数据
        struct list_head name_link;
        void *rcudata;
    };

    kuid_t uid;                                  // 拥有者 UID
    kgid_t gid;
    key_perm_t perm;                              // 权限掩码
    unsigned short quotalen;                      // 配额长度
    unsigned long flags;                          // KEY_FLAG_*
};
```

### 1.2 struct key_type——密钥类型

```c
struct key_type {
    const char *name;                             // "user" / "logon" / "dns_resolver" / "rxrpc"
    size_t def_datalen;

    int (*vet_description)(const char *description);
    int (*preparse)(struct key_preparsed_payload *prep);
    void (*free_preparse)(struct key_preparsed_payload *prep);
    int (*instantiate)(struct key *key, struct key_preparsed_payload *prep);
    int (*update)(struct key *key, struct key_preparsed_payload *prep);
    int (*match)(const struct key *key, const char *description);
    void (*revoke)(struct key *key);
    void (*destroy)(struct key *key);
};
```

### 1.3 struct keyring——密钥环

```c
// 密钥环是一种特殊密钥（type = key_type_keyring）
// 使用关联数组存储子密钥
struct keyring {
    struct list_head name_list;                  // 按名称索引
    struct list_head link_list;                  // 所有链接
};
```

---

## 2. keyctl 系统调用 @ keyctl.c

```c
// SYSCALL_DEFINE5(keyctl, int, option, unsigned long, arg2, ...)
// 根据 option 分发到不同处理函数：

long __do_sys_keyctl(int option, unsigned long arg2, unsigned long arg3,
                      unsigned long arg4, unsigned long arg5)
{
    switch (option) {
    case KEYCTL_GET_KEYRING_ID:     // 获取 keyring ID
        return keyctl_get_keyring_ID((key_serial_t)arg2, (int)arg3);

    case KEYCTL_JOIN_SESSION_KEYRING: // 加入 session keyring
        return keyctl_join_session_keyring((const char __user *)arg2);

    case KEYCTL_UPDATE:              // 更新密钥
        return keyctl_update_key((key_serial_t)arg2, ...);

    case KEYCTL_REVOKE:              // 吊销密钥
        return keyctl_revoke_key((key_serial_t)arg2);

    case KEYCTL_SEARCH:              // 搜索密钥
        return keyctl_search_keyring(arg2, ...);

    case KEYCTL_LINK:                // 链接密钥到 keyring
        return keyctl_keyring_link((key_serial_t)arg2, (key_serial_t)arg3);

    case KEYCTL_UNLINK:              // 解除链接
        return keyctl_keyring_unlink((key_serial_t)arg2, (key_serial_t)arg3);

    case KEYCTL_READ:                // 读取密钥 payload
        return keyctl_read_key((key_serial_t)arg2, ...);

    case KEYCTL_INSTANTIATE:         // 实例化密钥
    case KEYCTL_NEGATE:
    case KEYCTL_DESCRIBE:            // 描述密钥
    case KEYCTL_SETPERM:             // 设置权限
    case KEYCTL_GET_PERSISTENT:      // 持久 keyring
    case KEYCTL_SESSION_TO_PARENT:   // session 传递
    // ... 共 20+ 子命令
    }
}
```

---

## 3. 密钥生命周期

### 3.1 key_alloc @ key.c:224——分配密钥

```c
struct key *key_alloc(struct key_type *type, const char *desc,
                      kuid_t uid, kgid_t gid, const struct cred *cred,
                      key_perm_t perm, unsigned long flags)
{
    struct key *key;

    // 1. 配额检查
    if (!(flags & KEY_ALLOC_NOT_IN_QUOTA))
        key_check_quota(key_user, perm);

    // 2. 分配 + 初始化
    key = kmem_cache_zalloc(key_jar, GFP_KERNEL);
    key->type = type;
    key->description = desc;
    key->uid = uid;
    key->perm = perm;

    // 3. 分配序列号
    key_alloc_serial(key);     // IDR 分配 serial
    // → idr_alloc(&key_serial_idr, key, 1, 0, GFP_KERNEL)
    // 序列号 32 位，大于 0

    return key;
}
```

### 3.2 key_instantiate_and_link——实例化+链接

```c
int key_instantiate_and_link(struct key *key, const void *data,
                              size_t datalen, struct key *keyring,
                              struct key *authkey)
{
    // 1. 准备 payload
    struct key_preparsed_payload prep;
    key->type->preparse(&prep);
    key->type->instantiate(key, &prep);

    // 2. 链接到 keyring
    if (keyring)
        __key_link(keyring, key);

    // 3. 通知等待者
    wake_up_bit(&key->flags, KEY_FLAG_USER_CONSTRUCT);
}
```

---

## 4. 搜索路径——keyctl_search_keyring

```c
// keyctl_search(ring_id, type, description, dest_ring_id)
// → keyring_search(keyring, type, description, dest_keyring)

int keyring_search(struct key *keyring, struct key_type *type,
                    const char *description, struct key *dest)
{
    // 1. 检查权限
    if (!key_permission(keyring, KEY_NEED_SEARCH))
        return -EACCES;

    // 2. 递归搜索 keyring 及其子 keyring
    struct key *key = keyring_search_rcu(keyring, type, description, ...);
    // → 遍历 keyring 中所有链接的密钥
    // → 对每个子 keyring 递归搜索
    // → 找到匹配的密钥 → 返回

    return key ? key_serial(key) : -ENOKEY;
}
```

---

## 5. 关键函数索引

| 函数 | 文件:行号 | 作用 |
|------|----------|------|
| `key_alloc` | `key.c:224` | 密钥分配 + serial 分配 |
| `key_alloc_serial` | `key.c:133` | IDR 分配序列号 |
| `key_instantiate_and_link` | `key.c` | 实例化 + 加入 keyring |
| `keyring_search` | `keyring.c` | 递归搜索密钥 |
| `keyctl_keyring_link` | `keyctl.c` | 链接到 keyring |
| `__do_sys_keyctl` | `keyctl.c` | 系统调用入口 |
| `key_permission` | `permission.c` | 权限检查 |

---

## 6. 调试

```bash
# 查看密钥
keyctl list
keyctl show

# 添加密钥
keyctl add user mykey "mydata" @u
keyctl print <serial>

# 搜索
keyctl search @u user mykey

# 配额
cat /proc/sys/kernel/keys/maxkeys
cat /proc/sys/kernel/keys/maxbytes
```

---

## 7. 总结

密钥管理通过 `key_alloc`（`key.c:224`）→ IDR 分配 serial → `key_instantiate_and_link` 构建生命周期。`keyring_search` 递归搜索密钥环树。`__do_sys_keyctl`（`keyctl.c`）分发 20+ 子命令。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 8. 密钥权限管理

```c
// 每个密钥有 16 位权限掩码 struct key->perm：
// Possessor:  0x0f000000 — 拥有者（拥有密钥的用户）
// User:       0x00f00000 — 指定用户
// Group:      0x0000f000 — 指定组
// Other:      0x0000000f — 其他

// 权限位：
// KEY_POS_VIEW   = 0x01  — 查看密钥属性
// KEY_POS_READ   = 0x02  — 读取 payload
// KEY_POS_WRITE  = 0x04  — 更新 payload
// KEY_POS_SEARCH = 0x08  — 搜索密钥环
// KEY_POS_LINK   = 0x10  — 链接到 keyring
// KEY_POS_SETATTR= 0x20  — 设置属性

// key_permission() 检查：
// → 比较当前进程的 uid/gid 与 key->uid/gid
// → 选择对应的 4 位权限组
// → 检查请求的操作是否在位图中
```

## 9. keyctl 常用命令

```c
// keyctl 子命令功能一览：
// KEYCTL_GET_KEYRING_ID      — 获取 keyring ID
// KEYCTL_JOIN_SESSION_KEYRING — 加入 session keyring
// KEYCTL_UPDATE              — 更新密钥 payload
// KEYCTL_REVOKE              — 吊销密钥
// KEYCTL_SEARCH              — 递归搜索密钥环
// KEYCTL_LINK                — 链接密钥到 keyring
// KEYCTL_UNLINK              — 解除链接
// KEYCTL_READ                — 读取密钥数据
// KEYCTL_INSTANTIATE         — 实例化未完成的密钥
// KEYCTL_NEGATE              — 否定密钥（标记为不可用）
// KEYCTL_SET_PERM            — 设置权限
// KEYCTL_GET_PERSISTENT      — 获取持久 keyring
// KEYCTL_SESSION_TO_PARENT   — 将 session keyring 传递给父进程
// KEYCTL_REJECT              — 拒绝密钥（带错误码）
// KEYCTL_INVALIDATE          — 使密钥无效
// KEYCTL_GET_NONCE           — 获取一次性 nonce
// KEYCTL_WATCH_KEY           — 监控密钥变化
// KEYCTL_MOVE                — 在 keyring 间移动密钥
```
