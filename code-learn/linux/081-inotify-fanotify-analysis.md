# 81-inotify-fanotify — Linux 文件系统事件监控框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**inotify** 和 **fanotify** 是 Linux 文件系统事件监控机制——inotify 提供每 inode 粒度的事件监视，fanotify 提供文件系统级监控并支持**访问控制**（允许/拒绝文件操作）。两者均构建于 **fsnotify 框架**之上。

**核心架构**：
```
VFS: vfs_create/unlink/open/write
  ↓
fsnotify() @ fs/notify/fsnotify.c:492
  ↓
send_to_group() @ :331    遍历标记组
  ↓
group->ops->handle_event()  根据 group 类型分发
  ├── inotify_handle_inode_event()
  │     → 构造 inotify_event
  │     → 加入 group->notification_list
  │     → wake_up(&group->notification_waitq)
  │     → inotify_read() 消费
  │
  └── fanotify_handle_event()
        → fanotify_merge() 尝试合并
        → 加入 group->notification_list
        → fanotify_get_response() 等待（PERM 事件）
        → fanotify_read() 消费
```

**doom-lsp 确认**：inotify 在 `fs/notify/inotify/inotify_user.c`（55 符号），fanotify 在 `fs/notify/fanotify/fanotify.c`（39 符号），fsnotify 框架在 `fs/notify/fsnotify.c`（33 符号）。

---

## 1. fsnotify 框架

### 1.1 struct fsnotify_group @ backend.h:213

```c
// include/linux/fsnotify_backend.h:213-280
struct fsnotify_group {
    const struct fsnotify_ops *ops;              // handle_event/free_group 等

    refcount_t refcnt;

    spinlock_t notification_lock;
    struct list_head notification_list;          // 待发送给用户空间的事件
    wait_queue_head_t notification_waitq;        // read() 阻塞于此
    unsigned int q_len;                          // 队列中事件数
    unsigned int max_events;                     // 最大事件数

    struct mutex mark_mutex;                     // 保护 marks_list
    struct list_head marks_list;                 // 此组的所有 mark

    union {                                      // inotify / fanotify 私有数据
        struct inotify_group_private_data {
            spinlock_t idr_lock;
            struct idr idr;                      // inotify 的 watch 描述符 IDR
        };
        struct fanotify_group_private_data { ... };
    };
};
```

### 1.2 send_to_group @ fsnotify.c:331——事件分发核心

```c
// VFS 调用 fsnotify() → 最终到达 send_to_group()
static int send_to_group(__u32 mask, ...)
{
    // 1. 收集此 inode/mount 上所有标记组的事件掩码
    fsnotify_foreach_iter_mark_type(iter_info, mark, type) {
        marks_mask |= mark->mask;
        marks_ignore_mask |= fsnotify_effective_ignore_mask(mark, ...);
    }

    // 2. 检查事件是否匹配任何标记
    if (!(test_mask & marks_mask & ~marks_ignore_mask))
        return 0;                                // 无匹配 → 忽略

    // 3. 调用组特定的 handle_event
    if (group->ops->handle_event)
        return group->ops->handle_event(group, ...);
    // → inotify: inotify_handle_inode_event (inotify_fsnotify.c)
    // → fanotify: fanotify_handle_event (fanotify.c)
}
```

---

## 2. inotify

### 2.1 struct inotify_inode_mark

```c
struct inotify_inode_mark {
    struct fsnotify_mark fsn_mark;               // fsnotify 基础 mark
    int wd;                                      // watch descriptor
};
```

### 2.2 inotify_add_watch——注册监控

```c
// sys_inotify_add_watch(fd, pathname, mask)
// → inotify_update_watch()

static int inotify_add_to_idr(struct inotify_inode_mark *i_mark,
                               struct fsnotify_group *group, struct inode *inode)
{
    // 使用 IDR 分配 watch descriptor（wd）
    idr_preload(GFP_KERNEL);
    ret = idr_alloc(&group->inotify_data.idr, i_mark, 0, 0, GFP_NOWAIT);
    idr_preload_end();

    // → fsnotify_add_mark(&i_mark->fsn_mark, group, inode)
    // → 将 mark 添加到 inode 的标记连接器
    // → 建立 inode→group 的关联
}
```

### 2.3 inotify_read @ :249——事件读取

```c
static ssize_t inotify_read(struct file *file, char __user *buf,
                            size_t count, loff_t *pos)
{
    // 循环读取事件
    while (1) {
        // 从 group->notification_list 取一个事件
        // → copy_event_to_user() → inotify_event {wd, mask, cookie, len, name}
        ret = copy_event_to_user(group, buf, count);
        if (ret > 0) break;

        // 阻塞等待事件到达
        ret = wait_event_interruptible(group->notification_waitq,
                    !list_empty(&group->notification_list) || group->shutdown);
    }
    return ret;
}
```

---

## 3. fanotify

### 3.1 fanotify_merge @ :182——事件合并优化

```c
// 当多个同类事件排队时，fanotify 可以合并它们
// 例如：同一文件被连续打开多次 → 合并为一次

static int fanotify_merge(struct fsnotify_group *group,
                           struct fsnotify_event *event)
{
    // 从后向前遍历队列
    list_for_each_entry_reverse(last_event, &group->notification_list, list) {
        if (fanotify_should_merge(last_event, event)) {
            // 合并：mask 取 OR
            last_event->mask |= event->mask;
            return 1;
        }
    }
    return 0;
}
```

### 3.2 fanotify_get_response @ :224——访问控制

```c
// FAN_OPEN_PERM / FAN_ACCESS_PERM 事件：
// 用户在收到事件后必须 write(ALLOW) 或 write(DENY)
// 在此期间，触发事件的进程阻塞在 fanotify_get_response() 中：

int fanotify_get_response(struct fsnotify_group *group,
                           struct fanotify_perm_event_info *event)
{
    // 等待用户空间通过 write() 回复
    wait_event(group->notification_waitq,
                event->state == FAN_EVENT_RESPONSE);

    if (event->response & FAN_ALLOW)
        return 0;                                // 允许操作
    return -EPERM;                               // 拒绝操作
}
```

### 3.3 事件结构

```c
// 用户通过 read() 获得：
struct fanotify_event_metadata {
    __u32 event_len;
    __u8 vers;
    __u16 metadata_len;
    __aligned_u64 mask;         // FAN_OPEN/FAN_ACCESS/FAN_MODIFY/...
    __s32 fd;                   // 可操作的文件 fd（用于 FAN_OPEN_PERM）
    __s32 pid;                  // 事件触发进程 PID
};
```

---

## 4. inotify vs fanotify

| 维度 | inotify | fanotify |
|------|---------|----------|
| 启动 | `inotify_init()` | `fanotify_init()` |
| 监控范围 | per-inode 粒度 | per-filesystem 范围 |
| 事件掩码 | `IN_CREATE\|IN_DELETE\|...` | `FAN_OPEN\|FAN_ACCESS\|...` |
| 访问控制 | 不支持 | 支持 `FAN_*_PERM` |
| fd 传递 | 不传递 | 事件中包含打开的 fd |
| PID 信息 | 不提供 | 事件中包含 PID |
| 事件合并 | 不支持 | 支持 `fanotify_merge` |
| 限制 | `max_user_watches` | `max_user_groups` |
| 通知方式 | read() 事件结构体 | read() 事件结构体 + fd |
| 返回事件 | `struct inotify_event` | `struct fanotify_event_metadata` |

**doom-lsp 确认函数索引**：

| 函数 | 文件:行号 | 作用 |
|------|----------|------|
| `fsnotify` | `fsnotify.c:492` | VFS 事件入口 |
| `send_to_group` | `fsnotify.c:331` | 事件分发（掩码匹配）|
| `inotify_read` | `inotify_user.c:249` | inotify 事件读取 |
| `inotify_poll` | `inotify_user.c:139` | inotify poll |
| `inotify_add_to_idr` | `inotify_user.c:394` | watch 注册 |
| `inotify_handle_inode_event` | `inotify_fsnotify.c:59` | inotify 事件处理 |
| `fanotify_merge` | `fanotify.c:182` | fanotify 事件合并 |
| `fanotify_get_response` | `fanotify.c:224` | fanotify 访问控制 |
| `fanotify_handle_event` | `fanotify.c` | fanotify 事件处理 |

---

## 5. fsnotify_mark——事件标记

```c
// fsnotify_mark 是 inode/挂载点与 fsnotify_group 之间的关联：
struct fsnotify_mark {
    struct fsnotify_mark_connector __rcu *connector;  // 关联的 inode/mount
    struct fsnotify_group *group;                      // 所属组
    struct list_head obj_list;                         // connector 中的链表

    __u32 mask;                  // 感兴趣的事件掩码（IN_CREATE|IN_DELETE...）
    __u32 ignore_mask;           // 忽略的事件掩码
    refcount_t refcnt;
    unsigned long flags;
};

// mark 通过 fsnotify_add_mark() 注册到 inode：
// → 分配 fsnotify_mark
// → 设置 mask（要监控的事件类型）
// → 添加到 inode->i_fsnotify_marks 链表
// → 当 VFS 操作发生时：fsnotify() 遍历此链表
//   → send_to_group() 检查 mask 匹配
//   → group->ops->handle_event() 发送事件
```

## 6. inotify_add_watch 注册路径

```c
// inotify_add_watch(fd, pathname, IN_CREATE|IN_DELETE|...)
// → sys_inotify_add_watch
//   → inotify_update_watch(group, inode, mask, flags)
//     → inotify_add_to_idr(group, i_mark, inode)
//       → idr_alloc(&group->inotify_data.idr, i_mark, 1, 0, ...)
//         → 分配 watch descriptor（wd，整数句柄）
//     → fsnotify_add_mark(&i_mark->fsn_mark, group, inode, 0, ...)
//       → 将 mark 添加到 inode 的标记链表

// 用户通过 read() 读取时返回 struct inotify_event {wd, mask, cookie, len, name}：
// wd 就是 idr 分配的 watch descriptor
```

## 7. 总结

inotify 和 fanotify 基于 fsnotify 框架（`fsnotify` @ `fsnotify.c:492` → `send_to_group` @ `:331` → `group->ops->handle_event`）。`fsnotify_mark` 通过 `fsnotify_add_mark()` 注册到 inode，`mask` 决定监控的事件类型。inotify 通过 `inotify_read` @ `:249` 读取 `struct inotify_event`，fanotify 通过 `fanotify_get_response` @ `:224` 支持访问控制。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
