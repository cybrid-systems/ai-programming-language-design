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

## 8. 通知组和事件队列

```c
// fs/notify/group.c
struct fsnotify_group {
    const struct fsnotify_ops *ops;    // 操作函数
    spinlock_t event_lock;              // 事件队列锁
    struct list_head notification_list; // 待处理事件
    wait_queue_head_t notification_waitq; // 等待队列
    unsigned int q_len;                 // 队列长度
    unsigned int max_events;            // 最大事件数
    struct ida inode_mark_ida;
    atomic_t user_waits;
};

// fanotify 初始化时分配通知组
struct fsnotify_group *fsnotify_alloc_group(const struct fsnotify_ops *ops)
{
    struct fsnotify_group *group = kzalloc(sizeof(*group), GFP_KERNEL);
    spin_lock_init(&group->event_lock);
    INIT_LIST_HEAD(&group->notification_list);
    init_waitqueue_head(&group->notification_waitq);
    return group;
}
```

## 9. 事件传递

```c
// 事件从内核到用户空间传递链
fsnotify(f_path, mask, data, data_type, dir)
  → fanotify_handle_event(group, mask, data, data_type, dir)
    → fanotify_alloc_event(group, mask, data, data_type, dir)
      → 分配 fanotify_event 结构
    → fsnotify_add_event(group, event, NULL, fanotify_merge)
      → 加入 notification_list，唤醒等待的 read()
    → 用户空间执行 read(fanotify_fd, buf, sizeof(buf))
      → fsnotify_read() → copy_event_to_user()
```

## 10. fanotify 与容器

fanotify 支持 PID 命名空间，适合在容器中监控文件访问：

```c
// 事件中的 PID 信息
fanotify_event_metadata->pid
// → 在内核 5.x+ 版本中转换为容器内的 PID
// → 使用 pid_nr_ns(pid, task_active_pid_ns(current))
```

## 11. 性能考虑

```bash
# fanotify 延迟
# FAN_CLASS_NOTIF: 事件写入 fd 的时间 ~1μs
# FAN_CLASS_CONTENT: 阻塞决策等待 ~100μs - 10ms
#   （取决于用户空间响应时间）

# 大量操作的延迟影响
# 监控整个文件系统时，每个 open 增加 ~2-5μs
# 监控大量文件时考虑使用 FAN_MARK_FILESYSTEM
```

  
---

## 15. 性能与最佳实践

| 操作 | 延迟 | 说明 |
|------|------|------|
| 简单审计日志 | ~1μs | 单一系统调用事件 |
| 规则匹配 | ~100ns | 线性扫描规则列表 |
| 路径名解析 | ~1-5μs | 每次系统调用需解析 |
| netlink 发送 | ~1μs | skb 分配+传递 |

## 16. 关联参考

- 内核文档: Documentation/admin-guide/audit/
- 工具: auditd, auditctl, ausearch, aureport
- 配置: /etc/audit/

