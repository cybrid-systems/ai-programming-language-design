# 81-inotify-fanotify — 文件系统事件监控深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/notify/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**inotify** 和 **fanotify** 是 Linux 内核的文件系统事件监控接口。inotify 用于监控单个文件/目录，fanotify 用于大规模权限检查和跨文件系统监控。

---

## 1. inotify vs fanotify 对比

| 特性 | inotify | fanotify |
|------|---------|-----------|
| 监控粒度 | 单文件/目录 | 文件系统级别 |
| 权限事件 | ✗（只通知）| ✓（可拦截，PRE_OPEN 等）|
| 性能 | 高（单文件）| 较高（全局 hook）|
| 用户空间 API | `inotify_init`/`read` | `fanotify_init`/`fanotify_mark` |
| 典型用途 | 桌面文件监控 | 杀毒软件、容器 |

---

## 2. inotify 核心

### 2.1 inotify 事件

```c
// include/uapi/linux/inotify.h — 事件类型
#define IN_ACCESS        0x00000001   // 文件被访问
#define IN_MODIFY        0x00000002   // 文件被修改
#define IN_ATTRIB        0x00000004   // 元数据改变
#define IN_CLOSE_WRITE   0x00000008   // 写关闭
#define IN_CLOSE_NOWRITE 0x00000010  // 非写关闭
#define IN_OPEN          0x00000020   // 文件打开
#define IN_MOVED_FROM    0x00000040  // 移出
#define IN_MOVED_TO      0x00000080  // 移入
#define IN_CREATE        0x00000100  // 创建
#define IN_DELETE        0x00000200  // 删除
#define IN_DELETE_SELF   0x00000400  // 监控对象被删除
#define IN_MOVE_SELF     0x00000800  // 监控对象被移动
```

### 2.2 inotify 实例

```c
// fs/notify/inotify/inotify_user.c
struct inotify_device {
    struct notification_layer  *notification; // 通知层
    struct ucounts            *ucounts;        // 用户计数
    wait_queue_head_t         wait_queue;      // 等待队列（read 阻塞）
    struct mutex               mutex;
    struct idr                idr;             // inotify 事件 ID 管理
    unsigned int               last_wd;        // 上一个 watch descriptor
};
```

### 2.3 inotify_add_watch — 添加监控

```c
// fs/notify/inotify/inotify_user.c — inotify_add_watch
int inotify_add_watch(int fd, struct inotify_event __user *event,
                      const char __user *pathname, u32 mask)
{
    struct path path;
    struct inode *inode;

    // 1. 用户空间 path → 内核 path
    path = user_path(pathname);

    // 2. 获取 inode
    inode = d_inode(path.dentry);

    // 3. 分配 watch descriptor
    wd = idr_alloc(&device->idr, watch, 1, 0, GFP_KERNEL);

    // 4. 加入 inode 的 watch 链表
    spin_lock(&inode->i_lock);
    list_add(&watch->i_list, &inode->i_watches);
    spin_unlock(&inode->i_lock);

    return wd;
}
```

---

## 3. fanotify 核心

### 3.1 fanotify 事件

```c
// include/uapi/linux/fanotify.h — 事件类型
#define FAN_ACCESS           0x00000001   // 访问事件
#define FAN_MODIFY          0x00000001   // 修改事件
#define FAN_CLOSE_WRITE     0x00000008   // 写关闭
#define FAN_OPEN            0x00002000   // 打开事件

// 权限事件（可拦截）：
#define FAN_OPEN_PERM       0x00010000   // 打开前检查权限
#define FAN_ACCESS_PERM     0x00020000   // 访问前检查权限
#define FAN_ONDIR           0x40000000   // 目录事件
#define FAN_EVENT_ON_CHILD  0x20000000   // 监控子节点
```

### 3.2 struct fanotify_group — fanotify 组

```c
// fs/notify/fanotify/fanotify.c — fanotify_group
struct fanotify_group {
    struct fsnotify_group       fanotify_group; // 基类

    // 配置
    unsigned int               flags;             // FAN_*_ALL 标志
    unsigned int               priority;           // 通知优先级

    // 事件
    struct fanotify_event       *overflow_event;  // 溢出事件
    unsigned int               num_marks;          // mark 数量

    // 权限响应
    struct blocking_notifier_head   notifier;      // 权限回调
    struct mutex               access_mutex;       // 保护 access 响应
};
```

### 3.3 fanotify_mark — 标记监控

```c
// fs/notify/fanotify/fanotify_user.c — fanotify_mark
int fanotify_mark(int fanotify_fd, unsigned int flags,
                 uint64_t mask, int dirfd, const char *pathname)
{
    struct fsnotify_group *group;
    struct fanotify_mark *mark;

    // 获取 group
    group = fdget(fanotify_fd);

    // 解析 path
    path = path_lookupat(dirfd, pathname, ...);

    // 分配/查找 mark
    mark = fanotify_find_add_mark(inode, group, mask);

    // 更新 mask
    mark->mask |= mask;

    return 0;
}
```

---

## 4. PRE-OPEN 权限检查

### 4.1 fanotify_handle_event — 处理事件

```c
// fs/notify/fanotify/fanotify.c — fanotify_handle_event
static int fanotify_handle_event(...)
{
    struct fanotify_event *event;

    // 1. 分配事件
    event = fanotify_alloc_event(group, info);

    // 2. 如果是权限事件，阻塞等待响应
    if (event->mask & FAN_OPEN_PERM) {
        ret = blocking_notifier_call_chain(
            &group->notifier, FAN_OPEN_PERM, &event->data);

        // 用户空间决定：ALLOW 或 DENY
        if (ret & NOTIFY_STOP_MASK)
            return FAN_DENY;  // 拒绝打开
    }

    return FAN_ALLOW;  // 允许
}
```

---

## 5. 使用示例

```c
// inotify 示例：
int fd = inotify_init();
wd = inotify_add_watch(fd, "/tmp", IN_MODIFY | IN_CREATE);

struct inotify_event buf[1024];
read(fd, buf, sizeof(buf));  // 阻塞读取事件

// fanotify 示例：
int fd = fanotify_init(FAN_CLASS_PRE_CONTENT, O_RDWR);
fanotify_mark(fd, FAN_MARK_ADD, FAN_OPEN_PERM,
              AT_FDCWD, "/tmp");

struct fanotify_event_metadata buf[1024];
read(fd, buf, sizeof(buf));   // 读取事件

// 响应权限查询：
struct fanotify_response resp = {
    .fd = fd,
    .response = FAN_ALLOW,  // 或 FAN_DENY
};
write(fd, &resp, sizeof(resp));
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/notify/inotify/inotify_user.c` | `inotify_add_watch`、`inotify_read` |
| `fs/notify/fanotify/fanotify.c` | `fanotify_handle_event`、`fanotify_alloc_event` |
| `fs/notify/fanotify/fanotify_user.c` | `fanotify_mark` |
| `include/uapi/linux/inotify.h` | 事件类型常量 |
| `include/uapi/linux/fanotify.h` | 事件类型常量 |

---

## 7. 西游记类比

**inotify/fanotify** 就像"取经路上的哨兵系统"——

> inotify 像单个哨兵（单文件监控），盯着一个据点（文件/目录），有动静就报信。fanotify 像情报网（全局监控），在各个关卡都布了哨兵，可以在大规模行动前做权限检查——比如有人想进藏经阁（打开文件），哨兵先上报（TELL ME），天庭可以决定放行还是拒绝（ALLOW/DENY）。inotify 只能报信，不能拦截；fanotify 有实权，可以在大门关上前拦截（PRE_OPEN_PERM），这就是两者的本质区别。

---

## 8. 关联文章

- **VFS**（article 19）：文件系统操作是 inotify/fanotify 的 hook 点
- **fanotify**（article 34）：fanotify 的详细对比