# inotify / fanotify — 文件系统事件监控深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/notify/inotify/` + `fs/notify/fanotify/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**inotify** 是轻量级文件监控（单文件/目录），**fanotify** 支持权限检查和挂载点监控。

---

## 1. inotify

### 1.1 inotify_group — inotify 实例

```c
// fs/notify/inotify/inotify_user.c — inotify_group
struct inotify_group {
    struct fsnotify_group       group;        // 基类
    struct idr                 *idr;          // inode ID 分配器
    int                        last_wd;       // 上个 watch descriptor
    unsigned int               user_attached;  // 用户关联的 mask
};
```

### 1.2 inotify_mark — 监控项

```c
// fs/notify/inotify/inotify_user.c — inotify_mark
struct inotify_mark {
    struct fsnotify_mark        fsn_mark;      // 基类
    int                         wd;             // watch descriptor
    struct inode               *inode;         // 监控的 inode
    __u32                      mask;           // 监控的事件（IN_MODIFY/IN_CREATE/...）
};
```

---

## 2. fanotify

### 2.1 fanotify_group — fanotify 实例

```c
// fs/notify/fanotify/fanotify_user.c — fanotify_group
struct fanotify_group {
    struct fsnotify_group       group;          // 基类
    unsigned int               flags;          // FAN_* 标志
    unsigned int               max_marks;      // 最大 mark 数
    unsigned int               priority;       // 优先级

    // 权限决策
    struct fanotify_response   *response;     // 用户空间的响应
};
```

---

## 3. fanotify vs inotify 对比

| 特性 | inotify | fanotify |
|------|---------|----------|
| 监控粒度 | 文件/目录 | 挂载点/整个文件系统 |
| 权限检查 | 无 | PRE-OPEN/ACCESS，可拒绝 |
| 性能 | 轻量 | 较重（权限判断开销）|
| 典型用途 | 桌面监控 | 杀毒、审计 |

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/notify/inotify/inotify_user.c` | `inotify_group`、`inotify_mark` |
| `fs/notify/fanotify/fanotify_user.c` | `fanotify_group` |