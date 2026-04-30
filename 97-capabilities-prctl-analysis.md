# Linux Kernel capabilities / prctl 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/capability.c` + `kernel/sys.c`）

---

## 0. capabilities — 细粒度权限

Linux 2.2+ 将 root 特权拆分为**能力集**：

```c
// include/uapi/linux/capability.h
#define CAP_CHOWN        0   // 修改文件所有者
#define CAP_DAC_OVERRIDE  1   // 绕过 DAC 读/写/执行检查
#define CAP_NET_BIND_SERVICE 10  // 绑定到 <1024 端口
#define CAP_SYS_ADMIN    21   // 系统管理员（很多操作）
#define CAP_SYS_RAWIO    22   // 裸 I/O（/dev/mem 等）
```

---

## 1. prctl — 进程控制

```c
// kernel/sys.c — sys_prctl
long sys_prctl(int option, unsigned long arg2, unsigned long arg3,
           unsigned long arg4, unsigned long arg5)
{
    switch (option) {
    case PR_SET_NAME:        // 设置进程名
        comm[15] = 0;
        memcpy(comm, (char *)arg2, 15);
        break;
    case PR_GET_NAME:
        copy_to_user(name, comm, sizeof(comm));
        break;
    case PR_SET_SECCOMP:      // 设置 seccomp
        break;
    case PR_SET_NO_NEW_PRIVS: // 设置 no_new_privs（execve 不获得新权限）
        current->no_new_privs = arg2;
        break;
    }
}
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `kernel/capability.c` | `cap_capable`、`sys_capget`、`sys_capset` |
| `kernel/sys.c` | `sys_prctl` |
