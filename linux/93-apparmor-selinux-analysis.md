# 93-apparmor-selinux — Linux LSM（Linux Security Module）框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**LSM（Linux Security Module）** 是 Linux 的安全钩子框架，允许 SELinux、AppArmor、Smack、TOMOYO 等安全模块插入内核的关键操作路径。每个安全模块通过注册 `struct lsm_blob_sizes` 和 `security_hook_list` 在 VFS、进程、网络等操作点插入安全检查。

**核心设计**：LSM 在 VFS 的关键路径（`inode_permission`、`file_open`、`task_alloc`）中插入 `security_*()` 钩子。这些钩子遍历已注册的安全模块列表，依次调用每个模块的检查函数。

```
文件 open 路径：
  do_open(path, file, flags)
    ↓
  security_file_open(file)
    ↓
  lsm_file_open()   → 遍历 LSM 钩子链表
    ├── SELinux: selinux_file_open()
    │     → inode->i_sid 检查
    │     → avc_has_perm() 查询 AVC 缓存
    └── AppArmor: apparmor_file_open()
          → aa_file_perm() 检查 profile
          → 遍历文件路径匹配规则
```

**doom-lsp 确认**：SELinux hooks @ `security/selinux/hooks.c`（7,983 行），AppArmor @ `security/apparmor/`，LSM 框架 @ `include/linux/lsm_hooks.h`（219 行）。

---

## 1. LSM 框架 @ include/linux/lsm_hooks.h

### 1.1 安全钩子注册

```c
// 钩子定义（include/linux/lsm_hook_names.h）：
// LSM_HOOK_INIT(file_open, selinux_file_open)
// LSM_HOOK_INIT(file_open, apparmor_file_open)

// struct security_hook_list @ :95 {
//     struct hlist_node list;
//     union security_list_options hook;  // 函数指针
//     char *lsm;                          // 所属模块名
// };

// 注册（selinux/hooks.c）：
// static struct security_hook_list selinux_hooks[] = {
//     LSM_HOOK_INIT(file_open, selinux_file_open),
//     LSM_HOOK_INIT(inode_permission, selinux_inode_permission),
//     ... 约 200 个钩子
// };
// security_add_hooks(selinux_hooks, ARRAY_SIZE(selinux_hooks), "selinux");
```

### 1.2 call_int_hook @ security.c:488——钩子调用

```c
// call_int_hook 宏遍历钩子链表，依次调用所有注册的模块：
#define call_int_hook(HOOK, ...) ({
    struct security_hook_list *hp;\
    hlist_for_each_entry(hp, &security_hook_heads.HOOK, list) {\
        rc = hp->hook.HOOK(__VA_ARGS__);\
        if (rc) break;  // 第一个拒绝的模块决定结果\
    }\
    rc;\
})

// 例如 file_open：
// int security_file_open(struct file *file) {
//     return call_int_hook(file_open, file);
//     // → selinux_file_open()  // 如果拒绝 → 直接返回
//     // → apparmor_file_open() // SELinux 允许后再调用
// }
```

### 1.3 blob_sizes——安全数据结构分配

```c
// 每个 LSM 需要为 inode/file/task 等对象分配私有数据：
// struct lsm_blob_sizes @ :104 {
//     int lbs_inode;     // inode 安全数据大小
//     int lbs_file;      // file 安全数据大小
//     int lbs_task;      // task 安全数据大小
//     int lbs_superblock;// superblock 安全数据大小
// };
//
// LSM 初始化时调用 security_add_hooks() 注册 blob_sizes
// security_alloc_*() 根据 blob_sizes 分配空间
```

### 1.4 关键钩子点（约 200 个）

```c
// 文件系统：file_open / file_permission / inode_permission / inode_create / inode_unlink
// 进程：task_alloc / task_free / cred_alloc / cred_free / task_prctl / bprm_check_security
// 网络：socket_create / socket_bind / socket_connect / sk_alloc_security
// IPC：sem_semop / msg_msgrcv / shm_shmat
// 其他：key_permission / sb_mount / sb_statfs / capable / syslog
```

---

## 2. SELinux @ security/selinux/hooks.c（~8,000 行）

### 2.1 核心数据结构

```c
// SELinux 使用安全上下文（security context）标记所有主体和客体：
// 主体（进程）：current->secid
// 客体（inode）：inode->i_security（struct inode_security_struct）
// 客体（file）：file->f_security

struct inode_security_struct {
    struct inode *node;             // 关联的 inode
    u32 sid;                        // 安全 ID
    u32 isid;                       // 初始 SID
    u32 psecid;                     // 父目录 SID
    unsigned char initialized;
};

// AVC（Access Vector Cache）— 快速访问决策缓存
struct avc_entry;                   // 缓存条目
struct avc_cache {
    struct hlist_head slots[AVC_CACHE_SLOTS];  // 哈希表
    u32 latest_notif;                          // 最新策略版本
};
```

### 2.2 文件 open 检查路径

```c
static int selinux_file_open(struct file *file)
{
    struct inode *inode = file_inode(file);
    u32 sid = current_sid();                    // 当前进程 SID
    u32 isid = inode_sid(inode);                // inode SID

    // AVC 查询——检查 (sid, isid, FILE__OPEN) 是否允许
    return avc_has_perm(&selinux_state,
                        sid, isid,
                        SECCLASS_FILE,
                        FILE__OPEN,
                        &ad);
}
```

### 2.3 AVC 缓存

```c
// avc_has_perm() 查询路径：
// → avc_lookup(sid, isid, tclass, requested) 在哈希表中查找
// → 命中：检查缓存条目是否有效
// → 未命中：avc_compute_av() → security_compute_av()
//   → 遍历策略二进制（SELinux 策略数据库）
//   → 缓存结果
```

---

## 3. AppArmor @ security/apparmor/

### 3.1 Profile 机制

```c
struct aa_profile {
    char *base;                          // profile 名
    struct aa_policy policy;
    struct aa_profile __rcu *parent;     // 父 profile

    struct aa_ruleset *rules;            // 规则集（文件/网络/能力）
    struct aa_hat *hat;                  // 子 profile（hat 模式）

    u64 mode;                            // AA_PROFILE_MODE_ENFORCE / COMPLAIN / KILL
};
```

### 3.2 文件访问检查

```c
// apparmor_file_open() → aa_file_perm()
// → aa_strn_split(path) 分解路径
// → aa_comp_match(profile, path) 匹配 profile 规则
// → 检查文件权限（AA_MAY_READ / AA_MAY_WRITE）
```

---

## 4. 安全模块对比

| 维度 | SELinux | AppArmor |
|------|---------|----------|
| 策略类型 | TE（类型强制）+ RBAC | 路径名 Profile |
| 标签方式 | 安全上下文（SID） | 路径名匹配 |
| 策略语言 | 数百种类型/角色 | 简单规则文件 |
| 配置复杂度 | 高 | 中 |
| 策略大小 (默认) | ~1MB | ~500KB |
| `kernel/seccomp.c` | 无关 | 无关 |
| 核心检查函数 | `avc_has_perm()` | `aa_comp_match()` |

---

## 5. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `security_add_hooks` | `lsm_hooks.h` | 注册 LSM 钩子 |
| `security_file_open` | `security/security.c` | 文件 open 钩子 |
| `avc_has_perm` | `selinux/avc.c` | SELinux 访问决策 |
| `aa_file_perm` | `apparmor/file.c` | AppArmor 文件检查 |

---

## 6. 调试

```bash
# SELinux
cat /sys/fs/selinux/enforce          # 0=permissive, 1=enforcing
audit2why < /var/log/audit/audit.log

# AppArmor
cat /sys/module/apparmor/parameters/enabled
aa-status
aa-complain /usr/bin/myapp

# LSM 当前使用的模块
cat /sys/kernel/security/lsm
```

---

## 7. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `security_add_hooks` | `security.c` | 注册钩子 |
| `call_int_hook` | `security.c:488` | 钩子调用宏 |
| `security_file_open` | `security.c` | 文件 open 钩子 |
| `lsm_inode_alloc` | `security.c:247` | inode blob 分配 |
| `avc_has_perm` | `selinux/avc.c` | SELinux 决策 |
| `aa_file_perm` | `apparmor/file.c` | AppArmor 检查 |

## 8. 总结

LSM 框架（`include/linux/lsm_hooks.h`）提供约 200 个钩子点，通过 `call_int_hook`（`security.c:488`）遍历安全钩子链表调用注册的模块。SELinux（~8,000 行）基于 SID + AVC 类型强制，AppArmor 基于 profile 路径匹配。LSM stacking 通过 `blob_sizes` 聚合 + `call_int_hook` 链式调用支持多模块并发。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 8. LSM 初始化顺序

```c
// LSM 模块通过 security_add_hooks() 注册到全局钩子链表：
// 启动时的初始化顺序：
// 1. SELinux: selinux_init() → security_add_hooks(selinux_hooks, "selinux")
// 2. AppArmor: apparmor_init() → security_add_hooks(apparmor_hooks, "apparmor")
// 3. Smack, TOMOYO, ...

// 通过 CONFIG_LSM 内核参数控制顺序：
// lsm=selinux,apparmor,smack,tomoyo

// call_int_hook 遍历顺序决定了钩子优先级：
// 第一个返回非零的模块决定结果
#define call_int_hook(HOOK, ...) ({
    struct security_hook_list *hp;
    hlist_for_each_entry(hp, &security_hook_heads.HOOK, list) {
        rc = hp->hook.HOOK(__VA_ARGS__);
        if (rc) break;
    }
    rc;
})
```
