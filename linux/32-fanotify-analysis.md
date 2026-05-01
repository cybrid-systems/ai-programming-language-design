# 32-fanotify — Linux 内核文件通知深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**fanotify（File Access Notification）** 是 Linux 内核的文件系统事件通知机制。与 inotify 不同，fanotify 可以监控整个文件系统，并支持**访问决策**（允许/拒绝访问）。

**doom-lsp 确认**：`fs/notify/fanotify/` 目录。

---

## 1. API

```c
// 创建 fanotify 组
int fd = fanotify_init(FAN_CLASS_CONTENT, O_RDONLY);

// 添加监视
fanotify_mark(fd, FAN_MARK_ADD | FAN_MARK_MOUNT,
              FAN_ACCESS | FAN_MODIFY | FAN_OPEN | FAN_CLOSE,
              AT_FDCWD, "/");

// 读取事件
struct fanotify_event_metadata *event;
read(fd, buf, sizeof(buf));
// event->mask: FAN_ACCESS, FAN_OPEN, etc.
// event->fd: 被访问文件的 fd
```

---

## 2. 事件类型

| 事件 | 含义 |
|------|------|
| FAN_ACCESS | 文件被读取 |
| FAN_MODIFY | 文件被修改 |
| FAN_OPEN | 文件被打开 |
| FAN_CLOSE_WRITE | 写后关闭 |
| FAN_ONDIR | 目录 |
| FAN_OPEN_PERM | 打开前决策 |
| FAN_ACCESS_PERM | 读取前决策 |

---

## 3. 源码文件索引

| 文件 | 内容 |
|------|------|
| fs/notify/fanotify/fanotify.c | 核心 |
| include/linux/fanotify.h | API |

---

## 4. 关联文章

- **81-inotify-fanotify**：inotify vs fanotify 对比

---

*分析工具：doom-lsp*
