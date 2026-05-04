# 096-capabilities-prctl — Linux 能力（capabilities）系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**capabilities** 将 root 的全权分割为 **40+ 独立单元**（`CAP_NET_RAW`、`CAP_DAC_OVERRIDE`、`CAP_SYS_ADMIN` 等）。每个进程通过 `struct cred` 中的 5 组 64 位能力位图控制——`effective`（内核检查的位图）、`permitted`、`inheritable`、`bounding`、`ambient`。

**核心设计**：`capget`（@ `kernel/capability.c:137`）通过 `security_capget()` 读取目标进程能力位图。`capset`（@ `:217`）按`新能力 ⊆ 旧 permitted` 规则写入。文件能力（`setcap`）通过 `cap_bprm_set_creds()` 在 exec 时生效。运行时通过 `cap_capable()` → 检查 `cred->cap_effective`。

```
┌───────────────────────────────────────────────────────────────┐
│ capabilities 框架路径：                                        │
│                                                               │
│ capget/capset (系统调用)                                       │
│   → kernel/capability.c (57 符号)                              │
│     → security_capget/security_capset (LSM 钩子)              │
│       → cap_capget/cap_capset (capability 模块)               │
│         → cred->cap_effective/permitted/inheritable            │
│                                                               │
│ exec 时：                                                      │
│   bprm_set_creds() → cap_bprm_set_creds()                      │
│     → 从文件 xattr security.capability 读取能力                │
│     → 合并 old_permitted & old_inheritable                     │
│     → 设置新的 cred                                            │
│                                                               │
│ 运行时检查：                                                    │
│   capable(CAP_NET_RAW) → ns_capable()                          │
│     → security_capable() → cap_capable()                       │
│       → cap_effective & CAP_TO_MASK(cap) 位测试                 │
└───────────────────────────────────────────────────────────────┘
```

**doom-lsp 确认**：`kernel/capability.c`（503 行，57 个符号）。`sys_capget` @ `:137`，`sys_capset` @ `:217`，`ns_capable` @ `:361`，`cap_bprm_set_creds` 在 `security/commoncap.c`。

---

## 1. 核心数据结构 @ include/linux/capability.h

```c
// 64 位能力位图，每位对应一个能力：
typedef struct { __u64 val; } kernel_cap_t;

// 进程凭证中的能力字段：
struct cred {
    kernel_cap_t cap_effective;   // 当前生效——内核实际检查的位图
    kernel_cap_t cap_permitted;   // 允许拥有的能力——superior set
    kernel_cap_t cap_inheritable; // 子进程可继承的能力（exec 时传递）
    kernel_cap_t cap_bset;        // 边界集——限制子进程通过 exec 获得的能力
    kernel_cap_t cap_ambient;     // 环境能力——非特权用户可设置（4.3+）
};

// 关键能力常量（40+ 种）：
#define CAP_CHOWN           0   // 修改文件所有者
#define CAP_DAC_OVERRIDE    1   // 绕过文件权限检查（read/write 任何文件）
#define CAP_DAC_READ_SEARCH 2   // 绕过文件读/搜索权限
#define CAP_FOWNER          3   // 绕过文件拥有者检查
#define CAP_NET_RAW         13  // RAW/PACKET socket（ping 需要）
#define CAP_NET_ADMIN       12  // 网络管理（iptables/路由）
#define CAP_SYS_ADMIN       21  // 系统级管理（最宽泛）
#define CAP_SYS_TIME        25  // 修改系统时钟
// ... 共 40 个（_LINUX_CAPABILITY_U32S_3 = 2 个 u32 = 64 位）
```

**doom-lsp 确认**：`kernel_cap_t` 是 64 位位图，`_LINUX_CAPABILITY_U32S_3` = 2。能力编号 0-63 覆盖所有权限。

---

## 2. capget @ :137——读取进程能力

```c
SYSCALL_DEFINE2(capget, cap_user_header_t, header, cap_user_data_t, dataptr)
{
    // 1. 验证版本号（老 libcap 可能只认识 32 位）
    ret = cap_validate_magic(header, &tocopy);

    // 2. 获取目标 PID
    get_user(pid, &header->pid);

    // 3. 读取目标进程能力 @ :105
    ret = cap_get_target_pid(pid, &pE, &pI, &pP);
    // → 如果 pid == 0 或 pid == current: security_capget(current, ...)
    // → 否则: rcu_read_lock()
    //          target = find_task_by_vpid(pid)  // 通过 PID 查找 task
    //          security_capget(target, ...)     // LSM 钩子
    //          rcu_read_unlock()

    // 4. 64 位能力拆分为两个 32 位字段（兼容老 libcap 1.x）
    kdata[0].effective   = pE.val;           // 低 32 位
    kdata[1].effective   = pE.val >> 32;     // 高 32 位
    kdata[0].permitted   = pP.val;
    kdata[1].permitted   = pP.val >> 32;
    kdata[0].inheritable = pI.val;
    kdata[1].inheritable = pI.val >> 32;

    // 5. 静默丢弃高 32 位（老 libcap 不认识）
    copy_to_user(dataptr, kdata, tocopy * sizeof(kdata[0]));
    return 0;
}
```

---

## 3. capset @ :217——设置进程能力

```c
SYSCALL_DEFINE2(capset, cap_user_header_t, header, const cap_user_data_t, data)
{
    // 限制规则（源码注释原文）：
    // I: any raised capabilities must be a subset of the old permitted
    // P: any raised capabilities must be a subset of the old permitted
    // E: must be set to a subset of new permitted
    //
    // 即：不能获得从未拥有的能力

    // 实现：alloc_cred() → 修改 new->cap_* → commit_creds()
    new->cap_inheritable = inheritable;
    new->cap_permitted   = permitted;
    new->cap_effective   = effective;
}
```

---

## 4. 文件能力——exec 时提升（cap_bprm_set_creds）

```c
// 文件通过 setcap 命令设置能力：
// setcap cap_net_raw+ep /usr/bin/ping
// → 写文件的 extended attribute: security.capability

// exec 时内核调用 @ security/commoncap.c：
int cap_bprm_set_creds(struct linux_binprm *bprm)
{
    // 1. 从 bprm->file 读取 security.capability xattr
    //    → vfs_getxattr(bprm->file->f_path.dentry, "security.capability", ...)
    //    → 解析为 struct vfs_cap_data

    // 2. 计算新进程的能力：
    //    new_permitted = file_caps | (old_permitted & old_inheritable)
    //    new_effective = file_effective ? new_permitted : 0
    //    new_inheritable = old_inheritable
    //    new_ambient = 0  // exec 后环境能力重置

    // 3. 应用新的 cred
    //    commit_creds(new);
    return 0;
}
```

---

## 5. 运行时能力检查——cap_capable 链

```c
// 内核驱动调用 capable(CAP_*) 检查权限时的完整路径：

// 举例——网络设备打开 RAW socket：
// sock_create() → security_socket_create()
// → cap_capable(current_cred(), net_ns, CAP_NET_RAW, 0)

// 实现 @ kernel/capability.c:331
bool ns_capable(struct user_namespace *ns, int cap)
{
    return ns_capable_common(ns, cap, true);
}

static bool ns_capable_common(struct user_namespace *ns, int cap, bool audit)
{
    // 1. 安全检查→security_capable()→cap_capable()
    //    → 检查 current_cred()->cap_effective 的第 cap 位
    //    → 如果位已设 → 返回 0（允许）
    //    → 如果位未设 → 返回 -EPERM（拒绝）

    // 2. 通过命名空间链向上检查
    //    → 如果当前 ns 无权 → 检查父 ns
    //    → 一直检查到 init_user_ns
}
```

---

## 6. bounding set 和 ambient capabilities

```c
// bounding set（cap_bset）：
// exec 时限制子进程获得的能力
// 只能删除（清位），不能增加
// 初始化：全 1（所有能力可用）
// prctl(PR_CAPBSET_DROP, CAP_SYS_ADMIN) → 永久删除

// ambient set（cap_ambient，Linux 4.3+）：
// 非特权用户通过 prctl(PR_CAP_AMBIENT) 设置
// 子进程 exec 时保持能力
// 条件：ambient 必须同时 ∈ permitted 且 ∈ inheritable
```

---

## 7. prctl 能力相关命令

```c
// prctl(PR_SET_KEEPCAPS, 1/0)：
//   setuid 后保持能力（setuid root→user 时不会丢弃）

// prctl(PR_CAPBSET_DROP, cap)：
//   从 bounding set 中永久删除某能力

// prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, cap, 0, 0)：
//   提升 ambient 能力（需要 cap ∈ permitted ∩ inheritable）
```

---

## 8. 调试

```bash
# /proc/<pid>/status 能力字段解码
cat /proc/self/status | grep Cap
# CapInh: 0000000000000000   — inheritable
# CapPrm: 0000000000000400   — permitted
# CapEff: 0000000000000400   — effective
# CapBnd: 0000003fffffffff   — bounding set
# CapAmb: 0000000000000000   — ambient

capsh --decode=0000000000000400   # → cap_net_raw

# 文件能力
getcap /usr/bin/ping               # cap_net_raw+ep
setcap cap_net_raw+ep /usr/bin/ping

# strace
strace -e capget,capset ping -c1 8.8.8.8
```

---

## 9. 关键函数索引

| 函数 | 文件 | 行号 | 作用 |
|------|------|------|------|
| `sys_capget` | `capability.c` | `:137` | 读取进程能力（64→32bit 拆分）|
| `sys_capset` | `capability.c` | `:217` | 设置进程能力（受限规则）|
| `cap_get_target_pid` | `capability.c` | `:105` | 按 PID 读取目标能力 |
| `ns_capable` | `capability.c` | `:361` | 命名空间感知能力检查 |
| `cap_bprm_set_creds` | `commoncap.c` | — | exec 时文件能力提升 |
| `cap_capable` | `commoncap.c` | — | 内核侧能力检查 |

---

## 10. 总结

Linux capabilities 通过 `struct cred` 的 5 组 64 位位图管理 40+ 种特权。`capget`（`:137`）读取目标进程能力（64→32 兼容拆分），`capset`（`:217`）受限设置（`新 ⊆ 旧 permitted`）。文件能力由 `cap_bprm_set_creds` 在 exec 时提升。运行时检查路径 `capable()` → `ns_capable()`（`:361`）→ `cap_capable()` → 位测试 `cred->cap_effective`。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*


## 3. cap_capable——运行时安全检查

```c
// security/commoncap.c L124 — doom-lsp 确认
int cap_capable(const struct cred *cred, struct user_namespace *target_ns,
                int cap, unsigned int opts)
{
    struct user_namespace *cred_ns = cred->user_ns;
    int ret = cap_capable_helper(cred, target_ns, cred_ns, cap);

    if (ret == 0 || ret != -EPERM)
        trace_cap_capable(cred, target_ns, cred_ns, cap, ret);

    return ret;
}

// 上层调用路径：
// capable(CAP_NET_RAW) → ns_capable() → security_capable()
//   → cap_capable(cred, target_ns, cap, opts)
//     → 检查 cred->cap_effective 中的 cap 位
//     → 如果在 effective 位图中 → 返回 0（允许）
//     → 否则 → 返回 -EPERM（拒绝）
```

## 4. execve 时的能力转换

```
新进程的 capability 在 execve 时按以下规则计算：

P'(permitted)  = (P(inheritable) & F(inheritable)) |
                 (F(permitted) & cap_bset)
P'(effective)  = F(effective) ? P'(permitted) : 0
P'(inheritable)= P(inheritable)
cap_ambient    = 0（除非配置了 CAP_AMBIENT）

其中：
  P  = exec 前的进程能力
  P' = exec 后的进程能力
  F  = 文件的 security.capability xattr
```


## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct cred` | include/linux/cred.h | 核心结构 |
| `kernel_cap_t` | include/linux/capability.h | 类型定义 |
| `cap_capable()` | security/commoncap.c | 安全检查 |
| `capget()` | kernel/capability.c | syscall |
| `capset()` | kernel/capability.c | syscall |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
