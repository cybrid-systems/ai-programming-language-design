# 32-fanotify — Linux 文件系统通知机制深度源码分析

> 基于 Linux 7.0-rc1 主线源码

---

## 0. 概述

**fanotify（File Access Notification）** 是 Linux 内核的文件系统事件监控机制。与 inotify（按目录/文件监控）不同，fanotify 支持监控整个 mount 点，并支持**访问决策**（允许或拒绝文件访问）。广泛用于实时防病毒扫描、文件访问审计等场景。

**doom-lsp 确认**：`fs/notify/fanotify/` 目录。

---

## 1. fanotify vs inotify

| 特性 | inotify | fanotify |
|------|---------|----------|
| 监控范围 | 单文件/目录 | 整个 mount 点 |
| 访问决策 | ❌ | ✅ FAN_OPEN_PERM, FAN_ACCESS_PERM |
| 事件类型 | IN_* | FAN_* |
| fd 传递 | 否 | ✅ 可获取被访问文件的 fd |
| 缓存模式 | — | ✅ 支持内容/通知/权限模式 |

---

## 2. API

```c
#include <sys/fanotify.h>

// 初始化
int fd = fanotify_init(FAN_CLASS_CONTENT, O_RDONLY);
// FAN_CLASS_NOTIF: 仅通知，不决策
// FAN_CLASS_CONTENT: 内容感知（读取前阻塞）
// FAN_CLASS_PRE_CONTENT: 预内容（打开前阻塞）

// 添加监控标记
fanotify_mark(fd, FAN_MARK_ADD | FAN_MARK_MOUNT,
              FAN_OPEN | FAN_ACCESS | FAN_CLOSE,
              AT_FDCWD, "/");

// 读取事件
char buf[4096];
struct fanotify_event_metadata *metadata;
ssize_t len = read(fd, buf, sizeof(buf));
metadata = (struct fanotify_event_metadata *)buf;
// metadata->mask: 事件类型
// metadata->fd: 被访问文件的文件描述符
// metadata->pid: 访问进程的 PID

// 处理事件
if (metadata->mask & FAN_OPEN_PERM) {
    // 决策：允许或拒绝
    struct fanotify_response resp = {
        .fd = metadata->fd,
        .response = FAN_ALLOW,  // 或 FAN_DENY
    };
    write(fd, &resp, sizeof(resp));
}
```

---

## 3. 权限决策的数据流

```
进程打开文件：
  │
  ├─ do_sys_open → do_filp_open → path_openat
  │
  ├─ fsnotify_open_perm(f_path, MAY_OPEN)
  │   → fanotify_handle_event(FAN_OPEN_PERM)
  │   → 创建 fanotify_perm_event
  │   → 将事件加入通知组队列
  │   → 等待用户空间回应
  │   │    [进程在此阻塞]
  │   │
  │   └─ 用户空间 fanotify 守护进程：
  │       read(fd) → 获取事件
  │       → 安全检查（如扫描病毒）
  │       → write(fd, response, ...) → FAN_ALLOW/DENY
  │
  ├─ 收到 FAN_ALLOW → 继续打开
  └─ 收到 FAN_DENY → 返回 EACCES
```

---

## 4. 通知组（fanotify_group）

```c
struct fanotify_group {
    struct fsnotify_group fsn_group;     // 通用通知组
    struct fasync_struct *fasync;        // 异步通知
    atomic_t fanotify_data;              // 用户空间 fd
    unsigned int flags;                  // FAN_CLASS_*
    unsigned int max_marks;              // 最大标记数
};
```

---

## 5. 事件类型

| 事件 | 含义 | 权限决策 |
|------|------|---------|
| FAN_ACCESS | 文件被读取 | ❌ |
| FAN_MODIFY | 文件被修改 | ❌ |
| FAN_OPEN | 文件被打开 | ❌ |
| FAN_CLOSE_WRITE | 写入后关闭 | ❌ |
| FAN_CLOSE_NOWRITE | 只读关闭 | ❌ |
| FAN_OPEN_PERM | 打开前 | ✅ permsion |
| FAN_ACCESS_PERM | 读取前 | ✅ permsion |
| FAN_ONDIR | 目录操作 | 与上述组合使用 |

---

## 6. 源码文件索引

| 文件 | 内容 |
|------|------|
| fs/notify/fanotify/fanotify.c | 核心逻辑 |
| fs/notify/fanotify/fanotify_user.c | 用户空间接口 |
| include/linux/fanotify.h | 内核 API |
| include/uapi/linux/fanotify.h | 用户 API |

---

## 7. 关联文章

- **81-inotify-fanotify**: inotify vs fanotify 对比

---
