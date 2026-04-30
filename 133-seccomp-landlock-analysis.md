# Linux Kernel seccomp / landlock 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/seccomp.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：syscall 过滤、BPF、SECCOMP_RET_*

---

## 1. seccomp — 系统调用过滤

### 1.1 过滤模式

```c
// SECCOMP_MODE_STRICT：
// 只允许 read、write、_exit、sigreturn
// prctl(PR_SET_SECCOMP, SECCOMP_MODE_STRICT);

// SECCOMP_MODE_FILTER：
// 使用 BPF 程序过滤
// prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &fprog);
```

### 1.2 seccomp_data — BPF 输入

```c
// include/uapi/linux/seccomp.h — seccomp_data
struct seccomp_data {
    int         nr;           // 系统调用号（__NR_read 等）
    __u32       arch;        // AUDIT_ARCH_*（x86_64、arm64）
    __u64       instruction_pointer; // 程序计数器
    __u64       args[6];    // 系统调用参数
};
```

### 1.3 返回值

```c
// SECCOMP_RET_ALLOW：  允许
// SECCOMP_RET_KILL：   杀死进程
// SECCOMP_RET_TRAP：   发送 SIGSYS
// SECCOMP_RET_ERRNO：  返回错误码
// SECCOMP_RET_TRACE：  交给 ptracer
// SECCOMP_RET_LOG：    记录日志并允许
// SECCOMP_RET_INVALID：无效
```

---

## 2. landlock — 文件系统沙箱

```c
// landlock：基于 cgroup 的安全沙箱

// 用户空间：
struct landlock_ruleset_attr attr = {
    .handled_access_fs = LANDLOCK_ACCESS_FS_READ |
                         LANDLOCK_ACCESS_FS_WRITE,
};
int fd = landlock_create_ruleset(&attr, sizeof(attr), 0);

// 添加路径限制
struct landlock_path_beneath_attr pb = {
    .parent_fd = open("/tmp", O_PATH),
};
landlock_add_rule(fd, LANDLOCK_RULE_PATH_BENEATH, &pb, 0);

// 限制进程
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
landlock_restrict_self(fd, 0);
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `kernel/seccomp.c` | seccomp 实现 |
| `security/landlock/` | landlock 实现 |
