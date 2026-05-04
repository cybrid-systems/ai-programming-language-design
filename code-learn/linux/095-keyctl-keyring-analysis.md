# 095-keyctl-keyring — Linux 密钥管理系统（keyctl/keyring）深度源码分析

> 基于 Linux 7.0-rc1 主线源码 | 使用 doom-lsp 逐行解析

## 0. 概述

Linux 密钥管理（keyrings）是内核的密钥存储与检索系统，通过 keyctl 系统调用管理。密钥按类型（user、logon、big_key、cifs 等）分类，存储在 keyring 中，支持 ACL 权限控制。用户空间通过 keyctl 工具使用。

---

## 1. 核心数据结构

```c
struct key {
    refcount_t              usage;          // 引用计数
    key_serial_t            serial;         // 序列号（全局唯一）
    struct rw_semaphore     sem;            // 保护密钥数据的读写信号量
    struct key_user         *user;          // 所属用户
    void                    *security;      // LSM 安全数据
    time64_t                expiry;         // 过期时间
    uid_t                   uid, gid;       // 属主/属组
    key_perm_t              perm;           // 权限（ACL）
    unsigned short          quotalen;       // 配额长度
    unsigned short          datalen;        // 数据长度

    struct keyring_payload  *payload;       // 密钥数据
    struct key_type         *type;          // 密钥类型（user/logon/big_key...）
    struct key_tag          *domain_tag;    // 域标签
};
```

基于 do_mmap 实现低延迟的**沙箱机制**（`kernel/seccomp.c: ~2100 行`）。

## 2. 操作 API

| keyctl 操作 | 功能 | 内核函数 |
|------------|------|---------|
| KEYCTL_JOIN_SESSION_KEYRING | 加入会话 keyring | join_session_keyring() |
| KEYCTL_READ | 读取密钥数据 | keyctl_read_key() |
| KEYCTL_SEARCH | 搜索密钥 | keyctl_search() |
| KEYCTL_LINK | 链接密钥到 keyring | keyctl_keyring_link() |
| KEYCTL_UNLINK | 从 keyring 解链 | keyctl_keyring_unlink() |

## 3. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct key` | include/linux/key.h | 核心 |
| `keyctl_read_key()` | security/keys/keyctl.c | 读取密钥 |
| `keyctl_search()` | security/keys/keyctl.c | 搜索密钥 |
| `join_session_keyring()` | security/keys/keyctl.c | 加入 keyring |

---

*分析工具：doom-lsp | 2026-05-04*
