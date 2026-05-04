# 092-apparmor-selinux — Linux LSM 安全模块深度源码分析

## 0. 概述

**LSM（Linux Security Module）** 是 Linux 的安全钩子框架，SELinux 和 AppArmor 是其两种主要实现。LSM 在内核的关键决策点（文件打开、execve、socket 创建）插入钩子进行安全检查。

---

## 1. LSM 框架

### 1.1 安全钩子

```c
// include/linux/lsm_hooks.h
struct security_hook_list {
    struct hlist_node       list;
    union security_list_options *hook;
};

// 关键钩子点：
// security_file_open()  → 文件被打开时
// security_bprm_check() → execve 时
// security_socket_create() → socket() 时
// security_inode_permission() → 文件权限检查时
```

### 1.2 钩子注册

```c
// 在模块初始化时注册钩子：
security_add_hooks(apparmor_hooks, ARRAY_SIZE(apparmor_hooks), "apparmor");
// 或
selinux_register_hooks(selinux_hooks);

// 所有 LSM 的钩子在 security/security.c 中组合：
security_file_open(file)
  └─ if (selinux_enabled) selinux_file_open()
  └─ if (apparmor_enabled) apparmor_file_open()
```

## 2. SELinux vs AppArmor

| 特性 | SELinux | AppArmor |
|------|---------|----------|
| 标签类型 | 安全上下文（user:role:type） | 路径名 |
| 策略 | 全局统一策略 | 每个进程独立 profile |
| 易用性 | 复杂 | 相对简单 |
| 管理 | semanage | aa-genprof |
| 默认状态 | Android / Red Hat | Ubuntu / Debian / SUSE |

## 3. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct security_hook_list` | include/linux/lsm_hooks.h | 核心 |
| `security_add_hooks()` | security/security.c | 相关 |
| `security_file_open()` | security/security.c | 钩子点 |
| `selinux_file_open()` | security/selinux/hooks.c | SELinux 实现 |
| `apparmor_file_open()` | security/apparmor/lsm.c | AppArmor 实现 |
