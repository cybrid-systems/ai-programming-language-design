# Linux Kernel inotify / fanotify 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/notify/inotify/` + `fs/notify/fanotify/`）
> 工具： doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 两种文件监控对比

| 特性 | inotify | fanotify |
|------|---------|----------|
| 监控粒度 | 文件/目录 | 整个挂载点/文件系统 |
| 事件类型 | OPEN/CLOSE/MODIFY/ACCESS 等 | 权限检查（PRE-OPEN/PRE-ACCESS）|
| 能否阻止操作 | 否（仅观察） | 是（可拒绝操作）|
| 性能 | 轻量 | 较重（需要元数据）|
| 典型用途 | 桌面文件监控 | 杀毒/审计/容器 |

---

## 1. inotify — 文件级监控

### 1.1 核心结构

```c
// fs/notify/inotify/inotify_user.c — inotify_device
struct inotify_device {
    int                 wd;               // watch descriptor
    struct inode        *inode;           // 监控的文件 inode
    struct watch_mask   mask;             // 监控的事件类型
    struct list_head    events;           // 事件链表
    wait_queue_head_t   wait;             // 等待队列
    spinlock_t          lock;
};
```

### 1.2 用户空间 API

```c
// 用户空间：
int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
int wd = inotify_add_watch(fd, "/path/to/watch", IN_MODIFY | IN_CREATE | IN_DELETE);

// 读取事件：
struct inotify_event {
    int      wd;         // watch descriptor
    uint32_t mask;       // 事件类型
    uint32_t cookie;     // 关联两个事件（如 rename）
    uint32_t len;        // name 长度
    char     name[];     // 文件名（如果有）
};
```

### 1.3 核心函数

```c
// fs/notify/inotify/inotify_user.c — inotify_add_watch
static int inotify_add_watch(struct inotify_device *dev,
                 const char __user * pathname, u32 mask)
{
    // 1. 解析路径获取 inode
    inode = user_path_get(pathname);

    // 2. 分配 watch descriptor
    wd = idr_alloc(&dev->idr, watch, 1, 0, GFP_KERNEL);

    // 3. 注册到 inode 的 i_watchers 链表
    spin_lock(&inode->i_lock);
    list_add(&watch->i_list, &inode->i_watchers);
    spin_unlock(&inode->i_lock);

    return wd;
}
```

---

## 2. fanotify — 挂载/文件系统级监控

### 2.1 fanotify_group

```c
// fs/notify/fanotify/fanotify_user.c — fanotify_event
struct fanotify_event {
    struct fsnotify_event     fse;          // 基类
    __u64                     pid;           // 进程 ID
    __u64                     uid;           // 用户 ID
    const struct path        *path;         // 路径
    unsigned char             mask;          // 事件类型
    unsigned char             response;      // 响应（允许/拒绝）
};
```

### 2.2 权限检查（PRE-OPEN 等）

```c
// fanotify 的核心能力：拦截并可拒绝操作
// 用户空间返回允许/拒绝：

struct fanotify_response response;
response.fd = fd;
response.response = FAN_ALLOW;  // 或 FAN_DENY
write(fanotify_fd, &response, sizeof(response));

// 内核收到 FAN_DENY 后：
//   if (event->response == FAN_DENY)
//       return -EPERM;
```

### 2.3 fanotify_init

```c
// fs/notify/fanotify/fanotify_user.c — do_fanotify_mark
// 设置监控：
fanotify_mark(fanotify_fd, FAN_MARK_ADD | FAN_MARK_MOUNT,
              FAN_OPEN_PERM, AT_FDCWD, "/mount/point");
```

---

## 3. fsnotify — 统一入口

```c
// fs/notify/notification.c — fsnotify
void fsnotify(struct inode *inode, __u32 mask, ...)
{
    // 遍历 inode->i_watchers
    // 调用每个 watch 的 notify() 回调
    // 传递给 inotify 或 fanotify
}
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `fs/notify/inotify/inotify_user.c` | inotify API 实现 |
| `fs/notify/fanotify/fanotify_user.c` | fanotify API 实现 |
| `fs/notify/notification.c` | `fsnotify()` 统一入口 |
| `include/linux/inotify.h` | `struct inotify_event` |
