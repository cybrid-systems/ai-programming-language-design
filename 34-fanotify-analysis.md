# Linux Kernel fanotify 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/notify/fanotify/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 fanotify？

**fanotify**（File-system Access Notification）是 Linux 2.6.37+ 引入的文件系统事件监控接口，比 inotify 更高效，支持**在事件发生前**进行决策（如拒绝访问）。

**vs inotify**：
- inotify：事件发生后通知（只能记录）
- fanotify：事件发生**前**通知（可以阻止）

---

## 1. 核心 API

```c
// 用户空间
#include <sys/fanotify.h>

// 1. 初始化 fanotify 组
fd = fanotify_init(FAN_CLOEXEC | FAN_NONBLOCK, O_RDWR);

// 2. 监控目录/文件
fanotify_mark(fd, FAN_MARK_ADD | FAN_MARK_FILESYSTEM,
              FAN_ACCESS | FAN_MODIFY | FAN_OPEN, AT_FDCWD, "/path");

// 3. 读取事件
struct fanotify_event_metadata *event;
read(fd, &event, sizeof(event));

// 4. 允许/阻止操作
fanotify_mark(fd, FAN_MARK_MODIFY, event->mask, event->fd, NULL);
close(event->fd);
```

---

## 2. 核心结构

```c
// fs/notify/fanotify/fanotify.h — fanotify_group
struct fanotify_group {
    struct fsnotify_group      fanotify_group;
    unsigned int              mask;           // 监控的事件类型
    struct fanotify_response   *default_response;
    // ...
};
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `fs/notify/fanotify/fanotify.c` | fanotify 核心实现 |
| `fs/notify/fanotify/fanotify_user.c` | 用户空间接口 |
