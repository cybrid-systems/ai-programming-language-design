# Linux Kernel keyctl / keyring 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`security/keys/keyctl.c`）

---

## 0. keyctl — 内核密钥管理

```c
// security/keys/keyctl.c
// 用户空间：
key_serial_t key = add_key("user", "mykey", value, len, KEY_SPEC_PROCESS_KEYRING);

// 使用：
keyctl(KEYCTL_READ, key_serial, buffer, buflen);

// 查找：
key_serial_t key = request_key("user", "mykey", NULL, KEY_SPEC_PROCESS_KEYRING);
```

---

## 1. 核心结构

```c
// include/linux/key.h — key
struct key {
    atomic_t            usage;           // 引用计数
    key_serial_t        serial;          // 序列号
    struct key_type     *type;           // 密钥类型（user/reverse/encrypted）
    char                *description;    // 描述
    unsigned long        flags;          // KEY_* 标志
    __u32               perm;            // 权限
    struct list_head    type_data;       // 类型特定数据
    struct rb_node      serial_node;     // 红黑树节点
};
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `security/keys/keyctl.c` | `sys_add_key`、`sys_keyctl` |
| `security/keys/internal.h` | keyring 实现 |
