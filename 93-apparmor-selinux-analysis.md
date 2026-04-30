# Linux Kernel AppArmor / SELinux MAC 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`security/apparmor/` + `security/selinux/`）

---

## 0. MAC（强制访问控制）

DAC（root/user UID）→ 可被绕过
MAC → 内核强制执行，不可绕过

---

## 1. SELinux — 安全增强 Linux

```c
// security/selinux/selinuxfs.c — selinuxfs
// 基于 MLS（多级安全）策略

// 核心结构：
struct selinux_policy {
    struct avc_cache  avc;          // 访问向量缓存
    struct type_attr_map *type_map;  // 类型映射
    struct selinux_ood *ood;         // 对象类定义
};

// 检查流程：
// 1. SID（安全标识符）→ 进程/文件的安全上下文
// 2. avc_has_perm() → 检查权限（read/write/exec）
```

---

## 2. AppArmor — 路径MAC

```c
// security/apparmor/
// 与 SELinux 不同：基于路径而非 inode
// 更简单，策略文件易读

// apparmorfs：/sys/kernel/security/apparmor/
// profiles/ — 加载的策略文件
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `security/selinux/selinuxfs.c` | SELinux 文件系统 |
| `security/apparmor/apparmorfs.c` | AppArmor 文件系统 |
