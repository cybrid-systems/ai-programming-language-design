# 174-container_runtime — 容器运行时深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cgroup/cpuset.c` + `kernel/ns/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

Linux 容器依赖 namespace（资源隔离）和 cgroup（资源限制）。容器运行时（Docker/runc/containerd）通过这些内核机制创建隔离环境。

---

## 1. Namespace 隔离

```c
// 6种Namespace：

CLONE_NEWUTS    // UTS（主机名/域名）
CLONE_NEWIPC     // IPC（System V IPC）
CLONE_NEWPID     // PID（进程ID）
CLONE_NEWNET     // NET（网络）
CLONE_NEWNS      // MNT（挂载）
CLONE_NEWUSER    // USER（用户ID）

// unshare 系统调用创建新 namespace
// clone(CLONE_NEWNS|CLONE_NEWUTS|...) 创建新进程并加入 namespace
```

---

## 2. Cgroup 资源限制

```
容器典型的 cgroup 限制：

cpu:/docker/abc123
  cpu.shares=1024
  cpu.cfs_quota=100000  // 100ms/100ms = 1 CPU

memory:/docker/abc123
  memory.limit_in_bytes=1G
  memory.soft_limit_in_bytes=512M

blkio:/docker/abc123
  blkio.weight=500
```

---

## 3. seccomp

```
seccomp 限制系统调用：

// Docker 默认 seccomp 配置：
{
//   "defaultAction": "SCMP_ACT_ERRNO",
//   "syscalls": [
//     { "names": ["open", "read", ...], "action": "SCMP_ACT_ALLOW" }
//   ]
// }
```

---

## 4. runc 启动流程

```
runc create container
    │
    ├─ clone(CLONE_NEWNS|CLONE_NEWPID|...) → 新进程
    │
    ├─ 设置 cgroup
    │
    ├─ pivot_root() → 切换根文件系统
    │
    ├─ mount() → 挂载容器文件系统
    │
    ├─ seccomp() → 设置系统调用限制
    │
    └─ execve("/bin/sh") → 运行容器进程
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/ns/proc.c` | `create_new_namespaces` |
| `kernel/cgroup/cpuset.c` | cpuset 配置 |

---

## 6. 西游记类喻

**Container** 就像"取经队伍的独立营地"——

> 营地（容器）建在独立的岛上（namespace），每个营地的妖怪看不到其他营地的人（PID/UTS隔离），但营地的大小（CPU/内存限制）被天庭规定死了（cgroup）。如果妖怪想偷偷使用超过限制的资源（系统调用），门口的守将就会拦住（seccomp）。runc 像管理营地的官员，负责按照规定（镜像配置）建立营地、分配资源、设置守卫。

---

## 7. 关联文章

- **namespace**（article 134）：Linux namespace
- **cgroup**（article 135）：资源限制