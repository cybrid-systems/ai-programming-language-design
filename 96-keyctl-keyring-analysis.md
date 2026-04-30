# keyctl / keyring — 密钥管理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`security/keys/keyctl.c` + `security/keys/keyring.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**keyctl** 管理 Linux 内核的密钥/密钥环系统，用于存储和查找加密密钥、认证令牌等。

---

## 1. 核心数据结构

### 1.1 key — 密钥

```c
// include/keys/key-type.h — key
struct key {
    // 标识
    key_serial_t           serial;          // 序列号（唯一 ID）
    key_ref_t              id;               // ID 引用
    char                  *description;     // 描述
    struct key_type       *type;           // 密钥类型

    // 安全
    struct list_head       link;             // 链接到密钥环
    struct timespec        ctime;           // 创建时间
    unsigned long          flags;           // KEY_* 标志

    // 数据
    union {
        void               *payload;         // 密钥数据
        // 或特定于类型的 payload
    };

    // 引用计数
    atomic_t               usage;            // 使用计数
};
```

### 1.2 keyring — 密钥环

```c
// security/keys/keyring.c — keyring
struct keyring {
    struct key             key;             // 基类
    struct rb_root         type_data[2];     // 键树（按类型）
};
```

### 1.3 key_type — 密钥类型

```c
// include/keys/key-type.h — key_type
struct key_type {
    const char            name[KSYM_NAME_LEN]; // 类型名
    size_t                payload_len;          // payload 大小

    // 操作
    int (*instantiate)(struct key *, const void *, size_t);
    int (*match)(const struct key *, const void *);
    void (*revoke)(struct key *);
    void (*destroy)(struct key *);
};
```

---

## 2. 系统调用

### 2.1 add_key — 添加密钥

```c
// security/keys/keyctl.c — sys_add_key
SYSCALL_DEFINE5(add_key, const char *, type, const char *, description,
                const void __user *, payload, size_t, plen, key_serial_t, ringid)
{
    struct key_type *ktype;
    struct key *keyring, *key;

    // 1. 查找密钥类型
    ktype = key_type_lookup(type);
    if (IS_ERR(ktype))
        return PTR_ERR(ktype);

    // 2. 分配密钥
    key = key_alloc(ktype, description, current->uid, current->gid, KEY_POS_ALL, 0);

    // 3. 初始化 payload
    if (ktype->instantiate)
        ktype->instantiate(key, payload, plen);

    // 4. 加入密钥环
    keyring = key_lookup(ringid);
    key_link(keyring, key);

    return key->serial;
}
```

### 2.2 request_key — 请求密钥

```c
// security/keys/request_key.c — request_key
struct key *request_key(const struct key_type *type,
                         const char *description,
                         const void *callout_info)
{
    struct key *key;

    // 1. 在当前进程的密钥环中查找
    key = keyring_search(current->thread_keyring, type, description);
    if (key)
        return key;

    // 2. 如果找不到，调用 upcall（userspace 密钥管理程序）
    //    /sbin/request-key 程序负责提供密钥
    if (callout_info) {
        ret = callout_to_userspace(callout_info, &key);
        if (ret < 0)
            return ERR_PTR(ret);
    }

    return key;
}
```

---

## 3. proc 接口

```
/proc/keys              ← 所有密钥列表
/proc/key-users          ← 密钥用户统计

keyctl show             ← 显示密钥环内容
keyctl add <type> <desc> <payload> <ring>   ← 添加密钥
keyctl search <ring> <type> <desc>          ← 搜索密钥
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/keys/key-type.h` | `struct key`、`struct key_type` |
| `security/keys/keyctl.c` | `sys_add_key`、`sys_request_key` |
| `security/keys/keyring.c` | `keyring` |