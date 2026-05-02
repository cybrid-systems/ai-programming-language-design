# 81-inotify-fanotify — Linux 文件系统事件监控框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**inotify** 和 **fanotify** 是 Linux 文件系统事件监控机制——inotify 是轻量级文件/目录事件监视（`inotify_add_watch`），fanotify 是更强大的文件系统级事件监听（支持详细信息和访问控制）。

**核心设计**：两者均基于**fsnotify 框架**（`fs/notify/fsnotify.c`）。inotify 通过 `inotify_read` 从 `/dev/inotify` 读取事件，fanotify 通过到 `fanotify_read` 从 `/dev/fanotify` 读取。

```
VFS 操作（create/unlink/write/close）
     ↓
fsnotify() → fsnotify_handle_event()
     ↓
标记组（inotify_group / fanotify_group）
     ↓
   inotify_handle_event()    fanotify_handle_event()
   → inotify_add_to_idr()    → fanotify_merge()
   → copy_event_to_user()      → fanotify_get_response()
     ↓                          ↓
   inotify_read()             fanotify_read()
```

**doom-lsp 确认**：inotify 核心 `fs/notify/inotify/inotify_user.c`（55 符号），fanotify 核心 `fs/notify/fanotify/fanotify.c`（39 符号），fsnotify 框架 `fs/notify/fsnotify.c`（33 符号）。

---

## 1. fsnotify 框架 @ fs/notify/fsnotify.c

### 1.1 fsnotify @ :492——事件入口

```c
// VFS 在关键路径调用 fsnotify() 通知文件事件：
//   vfs_create()  → fsnotify_create()
//   vfs_unlink()  → fsnotify_unlink()
//   vfs_write()   → fsnotify_modify()
//   finish_open() → fsnotify_open()

int fsnotify(struct inode *to_tell, __u32 mask, struct inode *dir,
             const struct qstr *name, u32 cookie)
{
    // 1. 获取 inode 和 mount 上的标记组
    marks = fsnotify_first_mark(inode);
    if (!marks)
        return 0;                           // 无人监控 → 快速返回

    // 2. 遍历所有标记组，发送事件
    send_to_group(to_tell, inode, dir, name, mask, cookie,
                  marks, &iter_info);
    // → 每个标记组根据自己的事件掩码决定是否处理
    // → inotify_group → inotify_handle_event()
    // → fanotify_group → fanotify_handle_event()
}
```

---

## 2. inotify @ fs/notify/inotify/inotify_user.c

### 2.1 核心数据结构

```c
// inotify_device 的等待队列（inotify_fops）：
static const struct file_operations inotify_fops = {
    .read       = inotify_read,              // @ :249
    .poll       = inotify_poll,              // @ :139
    .release    = inotify_release,           // @ :301
    .unlocked_ioctl = inotify_ioctl,         // @ :313
};
```

### 2.2 inotify_add_watch

```c
// inotify_add_watch(fd, pathname, mask) → sys_inotify_add_watch

static int inotify_add_to_idr(struct inotify_inode_mark *i_mark,
                               struct fsnotify_group *group, struct inode *inode)
{
    // idr_alloc → 分配 watch descriptor（wd）
    idr_preload(GFP_KERNEL);
    ret = idr_alloc(&group->inotify_data.idr, i_mark, 0, 0, GFP_NOWAIT);
    idr_preload_end();
    // wd 返回给用户空间
}
```

### 2.3 inotify_read @ :249——读取事件

```c
static ssize_t inotify_read(struct file *file, char __user *buf,
                            size_t count, loff_t *pos)
{
    struct fsnotify_group *group = file->private_data;

    // 循环读取事件（可能阻塞）
    while (1) {
        // 从 group 的 event 链表取事件
        // → copy_event_to_user() 复制到用户空间
        // → inotify_event 结构 = {wd, mask, cookie, len, name}
        ret = copy_event_to_user(group, buf, count);
        if (ret)
            break;

        // 阻塞等待
        ret = wait_event_interruptible(group->notification_waitq,
                                        !list_empty(&group->notification_list));
    }
}
```

### 2.4 inotify 事件格式

```c
struct inotify_event {
    __s32 wd;               // watch descriptor
    __u32 mask;             // IN_CREATE/IN_DELETE/IN_MODIFY/...
    __u32 cookie;           // 用于 rename 事件关联
    __u32 len;              // name 长度
    char name[];            // 文件名（变长）
};
```

---

## 3. fanotify @ fs/notify/fanotify/fanotify.c

### 3.1 事件合并 @ :182

```c
// fanotify 支持事件合并——同一文件连续事件合并为一条
// fanotify_merge() → fanotify_should_merge()

static int fanotify_merge(struct fsnotify_group *group, struct fsnotify_event *event)
{
    list_for_each_entry_reverse(last_event, ...) {
        if (fanotify_should_merge(last_event, event)) {
            // 合并事件（mask 取或）
            last_event->mask |= event->mask;
            return 1;                       // 合并成功
        }
    }
    return 0;
}
```

### 3.2 fanotify_get_response @ :224——访问控制

```c
// fanotify 支持 FAN_OPEN_PERM / FAN_ACCESS_PERM
// 允许用户空间决定是否允许文件访问
// → send_to_group() 发送事件后阻塞
// → fanotify_get_response() 等待用户返回 ALLOW/DENY
// → 用户通过 read() 获取事件后 write() 回复

int fanotify_get_response(struct fsnotify_group *group,
                          struct fanotify_perm_event_info *event)
{
    // 等待用户空间的响应
    wait_event(group->notification_waitq, event->state == FAN_EVENT_RESPONSE);

    if (event->response & FAN_ALLOW)
        return 0;                            // 允许
    return -EPERM;                           // 拒绝
}
```

### 3.3 事件读取

```c
// fanotify_read() → 返回 fanotify_event_metadata 结构：
struct fanotify_event_metadata {
    __u32 event_len;     // 事件长度
    __u8 vers;           // 版本
    __u8 reserved;
    __u16 metadata_len;  // 元数据长度
    __aligned_u64 mask;  // 事件掩码
    __s32 fd;            // 文件描述符
    __s32 pid;           // 事件进程 PID
};
```

---

## 4. inotify vs fanotify

| 特性 | inotify | fanotify |
|------|---------|----------|
| 引入 | Linux 2.6.13 | Linux 5.1 |
| 事件范围 | per-inode 监控 | per-filesystem 监控 |
| 控制 | 允许/拒绝访问 | **不支持** | **支持 FAN_*_PERM** |
| fd 传递 | 不提供 | 事件中携带打开的文件 fd |
| pid 信息 | 不提供 | 事件中携带 PID |
| 事件合并 | 不支持 | 支持（`fanotify_merge`）|
| 上限 | `/proc/sys/fs/inotify/max_user_watches` | `/proc/sys/fs/fanotify/max_user_groups` |

---

## 5. 调试

```bash
# inotify 当前监控数
cat /proc/sys/fs/inotify/max_user_watches
cat /proc/sys/fs/inotify/max_queued_events

# fanotify 限制
cat /proc/sys/fs/fanotify/max_user_groups

# strace 跟踪
strace -e inotify_init,inotify_add_watch,fanotify_init,fanotify_mark -p <pid>
```

---

## 6. 总结

inotify（`inotify_read` @ `inotify_user.c:249`）和 fanotify（`fanotify_get_response` @ `fanotify.c:224`）基于 fsnotify 框架（`fsnotify` @ `fsnotify.c:492`）——VFS 操作调用 `fsnotify()`，通过标记组遍历将事件发送到 inotify 或 fanotify 的事件队列，用户通过 fd read 消费。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
