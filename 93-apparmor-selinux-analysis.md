# apparmor / SELinux — 强制访问控制深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`security/apparmor/` + `security/selinux/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**AppArmor** 和 **SELinux** 是 Linux 的强制访问控制（MAC）系统，限制进程权限超越标准 DAC。

---

## 1. AppArmor

### 1.1 apparmor狱警子系统

```c
// security/apparmor/include/apparmor.h — apparmor狱警子系统
struct apparmor狱警 {
    struct security_operations    *ops;         // 安全操作接口

    // 规则
    struct aa_profile           *profile;      // 当前 profile
    struct aa_namespace         *ns;           // 命名空间

    // 缓存
    struct aa_label              *label;       // 标签（用于权限检查）
};

// security/apparmor/include/profile.h — aa_profile
struct aa_profile {
    const char              *name;            // profile 名
    const char              *path;             // 规则文件路径

    // 规则
    struct aa_ruleset       *ruleset;          // 规则集

    // 模式
    enum {
        APPARMOR_ENFORCE,   // 强制模式（拒绝违规）
        APPARMOR_COMPLAIN,   // 投诉模式（记录但不拒绝）
    } mode;

    // 能力
    struct aa_caps           caps;             // CAP_* 限制
};
```

### 1.2 apparmor_access — 访问检查

```c
// security/apparmor/lsm.c — apparmor狱警_access
static int apparmor狱警_access(const char *name, int mask)
{
    struct aa_label *label;
    struct aa_profile *profile;

    // 1. 获取当前进程的 profile
    label = __aa_get_current_label();
    profile = label->profile;

    // 2. 检查规则
    if (profile->mode == APPARMOR_ENFORCE) {
        // 检查文件规则
        if (!aa_file_rules_allowed(profile, name, mask))
            return -EACCES;
    }

    return 0;
}
```

---

## 2. SELinux

### 2.1 selinux_state — 状态

```c
// security/selinux/include/class.h — selinux_state
struct selinux_state {
    // 状态
    bool                    initialized;       // 是否初始化

    // Enforcing / Permissive
    enum {
        SELINUX_ENFORCING = 0,
        SELINUX_PERMISSIVE = 1,
    } enforcing;

    // 策略
    struct selinux_policy   *policy;           // 策略数据库

    // Sid 表
    struct sid_map         *sid_map;           // 安全 ID 映射
};
```

### 2.2 avc — 访问向量缓存

```c
// security/selinux/avc.c — avc_cache
struct avc_cache {
    // 缓存条目（高速查找）
    struct avc_entry       *slots;             // 哈希槽
    unsigned int            slot_used;          // 使用计数

    // 统计
    unsigned long           hits;               // 缓存命中
    unsigned long           misses;             // 未命中
    unsigned long           lookups;            // 查询数
};

// security/selinux/avc.c — avc_lookup
static struct avc_entry *avc_lookup(struct avc_cache *cache, u32 ssid, u32 tsid, u16 tclass)
{
    // 1. 哈希
    u32 hash = avc_hash(ssid, tsid, tclass);

    // 2. 查找缓存
    entry = cache->slots[hash];

    if (entry && entry->ssid == ssid && entry->tsid == tsid && entry->tclass == tclass)
        return entry;  // 缓存命中

    // 3. 未命中 → 调用安全服务器
    return avc_compute_av(ssid, tsid, tclass);
}
```

### 2.3 avc_has_perm — 权限检查

```c
// security/selinux/avc.c — avc_has_perm
int avc_has_perm(u32 ssid, u32 tsid, u16 tclass, u32 requested, ...)
{
    struct avc_entry *entry;
    u32 denied;

    // 1. 查找缓存
    entry = avc_lookup(ssid, tsid, tclass);
    if (!entry)
        return -EINVAL;

    // 2. 检查权限
    denied = requested & ~entry->allowed;

    if (denied) {
        // 3. 审计
        avc_audit(ssid, tsid, tclass, requested, denied);
        return -EACCES;
    }

    return 0;
}
```

---

## 3. 对比

| 特性 | AppArmor | SELinux |
|------|---------|---------|
| 规则语言 | 文件路径 | 上下文标签 |
| 复杂度 | 低 | 高 |
| 默认策略 | 投诉模式 | 强制模式 |
| 典型发行版 | Ubuntu/SUSE | RHEL/Fedora |

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `security/apparmor/include/profile.h` | `aa_profile` |
| `security/apparmor/lsm.c` | `apparmor狱警_access` |
| `security/selinux/avc.c` | `avc_cache`、`avc_has_perm` |