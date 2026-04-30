# Linux Kernel seccomp / landlock 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/seccomp.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. seccomp — 系统调用过滤

```c
// kernel/seccomp.c — seccomp
// 限制进程可以调用的系统调用

// 用户空间：
// 1. 获取 seccomp filter
struct sock_fprog fprog = {
    .len = nr_filters,
    .filter = filters,
};
prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &fprog);

// 2. 或者：
//    SECCOMP_RET_TRACE → 交给 ptracer
//    SECCOMP_RET_ALLOW → 允许
//    SECCOMP_RET_KILL → 杀死进程
```

---

## 1. landlock — 沙箱

```c
// kernel/landlock — 基于 cgroup 的沙箱
// 比 seccomp 更安全，限制文件系统访问

// 用户空间：
struct landlock_ruleset_attr attr = {
    .handled_access_fs = LANDLOCK_ACCESS_FS_READ | LANDLOCK_ACCESS_FS_WRITE,
};
int ruleset_fd = landlock_create_ruleset(&attr, sizeof(attr), 0);

// 限制只能访问 /tmp
landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, "/tmp", 0);
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `kernel/seccomp.c` | seccomp 实现 |
| `security/landlock/` | landlock 实现 |
