# fanotify — 文件系统事件监控深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/notify/fanotify/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**fanotify**（Linux 2.6.36+）是比 inotify 更强大的文件监控机制，支持：
- **权限检查**（PRE-OPEN/PRE-ACCESS），可**拒绝操作**
- **监控挂载点**而非单个目录
- 支持 **fanotify groups**（多观察者）

---

## 1. fanotify vs inotify 对比

| 特性 | inotify | fanotify |
|------|---------|----------|
| 监控粒度 | 目录/文件 | 挂载点/文件系统 |
| 权限检查 | 无（仅观察）| 有（可拒绝）|
| 性能 | 轻量 | 较重 |
| 典型用途 | 桌面监控 | 杀毒/审计/容器 |

---

## 2. 核心数据结构

### 2.1 fanotify_event — 事件

```c
// fs/notify/fanotify/fanotify_user.c — fanotify_event
struct fanotify_event {
    struct fsnotify_event   fse;              // 基类
    __u64                 pid;               // 进程 ID
    __u64                 uid;               // 用户 ID
    const struct path    *path;             // 路径
    unsigned char         mask;              // 事件类型
    unsigned char         response;         // 响应（ALLOW/DENY）
};
```

### 2.2 fanotify_group — 观察组

```c
// fs/notify/fanotify/fanotify.h — fanotify_group
struct fanotify_group {
    // 基础
    struct fsnotify_group    *group;         // 基类
    unsigned int            priority;         // 优先级

    // 标志
    unsigned int            flags;            // FAN_ALL_FLAGS

    // 事件限制
    unsigned int            max_marks;         // 最大 mark 数
    unsigned int            num_marks;         // 当前 mark 数

    // 反馈
    struct fanotify_response *response;         // 响应队列
};
```

### 2.3 fanotify_mark — 标记

```c
// fs/notify/fanotify/fanotify_user.c — fanotify_mark
struct fanotify_mark {
    struct fsnotify_mark     fsn_mark;       // 基类
    unsigned int            mask;            // 监控的事件
    unsigned int            flags;            // FAN_MARK_* 标志
};
```

---

## 3. 事件类型

```c
// include/uapi/linux/fanotify.h
#define FAN_ACCESS          0x00000001  // 文件被访问
#define FAN_MODIFY          0x00000002  // 文件被修改
#define FAN_CREATE          0x00000100  // 文件被创建
#define FAN_DELETE          0x00000200  // 文件被删除
#define FAN_OPEN            0x00002000  // 文件被打开
#define FAN_OPEN_PERM      0x00010000  // 打开需要权限检查（关键！）
#define FAN_ACCESS_PERM    0x00020000  // 访问需要权限检查
#define FAN_ONDIR           0x40000000  // 目录事件
#define FAN_EVENT_ON_CHILD  0x08000000  // 子节点事件
```

---

## 4. PRE-OPEN 权限检查流程

```c
// fs/notify/fanotify/fanotify_user.c — fanotify_mask_event
static int fanotify_mask_event(...)
{
    // 1. 发送事件到用户空间
    fd = fanotify_fd;
    write(fd, &event, sizeof(event));

    // 2. 用户空间返回允许/拒绝
    read(fd, &response, sizeof(response));

    if (response.response == FAN_DENY) {
        // 拒绝操作
        return -EPERM;
    }

    return 0;
}
```

---

## 5. 用户空间 API

```c
// 创建 fanotify 组
int fd = fanotify_init(FAN_CLOEXEC | FAN_NONBLOCK, O_RDWR);

// 注册监控
fanotify_mark(fd, FAN_MARK_ADD | FAN_MARK_MOUNT,
              FAN_OPEN_PERM, AT_FDCWD, "/mount/point");

// 读取事件
struct fanotify_event_metadata event;
read(fd, &event, sizeof(event));

// 发送响应
struct fanotify_response response = {
    .fd = event.fd,
    .response = FAN_ALLOW,  // 或 FAN_DENY
};
write(fd, &response, sizeof(response));
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/notify/fanotify/fanotify_user.c` | `fanotify_init`、`fanotify_mark` |
| `fs/notify/fanotify/fanotify.h` | `struct fanotify_group`、`struct fanotify_event` |
| `include/uapi/linux/fanotify.h` | `FAN_OPEN_PERM` 等事件类型 |