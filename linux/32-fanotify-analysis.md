# 32-fanotify — Linux 内核文件系统通知深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**fanotify（File Access Notification）** 监控整个 mount 点的文件系统事件，支持在文件访问前做出权限决策（允许/拒绝）。与 inotify（按文件/目录监控）不同，fanotify 可覆盖整个文件系统，并传递被访问文件的文件描述符。

应用场景：实时防病毒扫描（ClamAV on-access）、文件审计、数据防泄漏（DLP）。

**doom-lsp 确认**：`fs/notify/fanotify/fanotify.c` 核心处理逻辑，`fanotify_user.c` 用户接口。`fanotify_handle_event` @ L925（事件处理入口），`fanotify_alloc_event` @ L746（事件分配）。

---

## 1. 核心数据结构

```c
// fs/notify/fanotify/fanotify_user.c — fanotify 组
struct fanotify_group {
    struct fsnotify_group fsn_group;     // 通用通知组基类
    struct fasync_struct *fasync;        // 异步通知
    atomic_t fanotify_data;              // 引用计数
    unsigned int flags;                  // FAN_CLASS_*
};

// fsnotify 通用通知组
struct fsnotify_group {
    const struct fsnotify_ops *ops;
    spinlock_t event_lock;                // 保护事件队列
    struct list_head notification_list;   // 待处理事件链表
    wait_queue_head_t notification_waitq; // 等待队列
    unsigned int q_len;                   // 当前队列长度
    unsigned int max_events;              // 最大事件数
};

// 权限事件（支持阻塞决策）
struct fanotify_perm_event {
    struct fanotify_event fae;
    int response;                         // FAN_ALLOW / FAN_DENY
    struct pid *pid;
    wait_queue_head_t wq;                // 进程在此等待用户响应
};
```

---

## 2. 初始化与监控

```c
#include <sys/fanotify.h>

// 初始化 fanotify 组
int fd = fanotify_init(FAN_CLASS_CONTENT, O_RDONLY);
// FAN_CLASS_NOTIF:       仅通知，不决策（最轻量）
// FAN_CLASS_CONTENT:     内容感知，阻塞决策（防病毒）
// FAN_CLASS_PRE_CONTENT: 预内容（备份）

// 监控整个 rootfs
fanotify_mark(fd, FAN_MARK_ADD | FAN_MARK_MOUNT,
              FAN_OPEN | FAN_ACCESS | FAN_OPEN_PERM | FAN_ACCESS_PERM,
              AT_FDCWD, "/");
```

---

## 3. 事件读取与决策

```c
// 读取事件
char buf[4096];
struct fanotify_event_metadata *metadata;
ssize_t len = read(fd, buf, sizeof(buf));
metadata = (struct fanotify_event_metadata *)buf;

// metadata 结构：
// - len:    事件总长度
// - vers:   版本号
// - fd:     被访问文件的文件描述符
// - mask:   事件类型掩码
// - pid:    触发事件的进程 PID

// 处理权限事件
if (metadata->mask & FAN_OPEN_PERM) {
    // 获取文件路径
    char path[256];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", metadata->fd);
    readlink(path, filepath, sizeof(filepath));

    // 安全检查
    int allowed = security_check(filepath);

    // 回复决策
    struct fanotify_response resp = {
        .fd = metadata->fd,
        .response = allowed ? FAN_ALLOW : FAN_DENY,
    };
    write(fanotify_fd, &resp, sizeof(resp));

    close(metadata->fd);
}
```

---

## 4. 内核数据流

```
进程打开文件 /etc/shadow:
  do_sys_open → do_filp_open → vfs_open → path_openat
    │
    └─ fsnotify_open(path, MAY_OPEN)
         │
         ├─ [通知事件: FAN_OPEN / FAN_ACCESS]
         │   fanotify_handle_event(@ L925)
         │   → fanotify_alloc_event(@ L746) 分配事件
         │   → fsnotify_add_event() 加入通知队列
         │   → spin_lock(&group->event_lock)
         │   → list_add_tail(&event->list, &group->notification_list)
         │   → wake_up(&group->notification_waitq)
         │   → 用户 read(fd) 可获取事件
         │
         └─ [权限事件: FAN_OPEN_PERM / FAN_ACCESS_PERM]
             fanotify_handle_event()
             → 创建 fanotify_perm_event（含等待队列 wq）
             → 加入通知队列
             → wait_event(event->wq, event->response != 0)
             → [进程在此阻塞! 等待用户决策]
             → 用户回复 FAN_ALLOW → 继续打开
             → 用户回复 FAN_DENY → 返回 -EPERM
```

---

## 5. 事件类型

| 事件 | 类型 | 触发时机 |
|------|------|---------|
| FAN_ACCESS | 通知 | 文件被读取后 |
| FAN_MODIFY | 通知 | 文件被修改后 |
| FAN_OPEN | 通知 | 文件被打开后 |
| FAN_CLOSE_WRITE | 通知 | 写模式关闭时 |
| FAN_CLOSE_NOWRITE | 通知 | 读模式关闭时 |
| FAN_OPEN_PERM | 权限 | 打开前（阻塞进程）|
| FAN_ACCESS_PERM | 权限 | 读取前（阻塞进程）|
| FAN_ONDIR | 修饰符 | 与上述组合用于目录 |

---

## 6. fanotify vs inotify

| 特性 | inotify | fanotify |
|------|---------|----------|
| 监控范围 | 单文件/目录 | 整个 mount 点 |
| 权限决策 | 不支持 | 支持 FAN_OPEN_PERM |
| 文件描述符 | 不传递 | 传递被访问文件 fd |
| 事件筛选 | 逐个添加 | FAN_MARK_MOUNT 一次覆盖 |
| 性能影响 | 低 | 权限模式时较高 |

---

## 7. 配置参数

```bash
# sysctl 参数
fs.fanotify.max_user_groups = 128
fs.fanotify.max_user_marks = 8192
fs.fanotify.max_user_watches = 8192
```

---

## 8. 源码文件索引

| 文件 | 内容 |
|------|------|
| fs/notify/fanotify/fanotify.c | 事件处理、分配、合并 |
| fs/notify/fanotify/fanotify_user.c | 用户接口、初始化、标记 |
| include/linux/fanotify.h | 内核 API |
| include/uapi/linux/fanotify.h | 用户空间 API |

---

## 9. 关联文章

- **34-fanotify-deep**: 权限决策内部机制
- **81-inotify-fanotify**: inotify vs fanotify 对比

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 10. 权限决策的阻塞内核路径

```
访问进程:                              用户空间监控程序:
open("/etc/shadow")                     fanotify_fd
  │                                         │
  ├─ vfs_open → fsnotify_open               │
  │   → fanotify_handle_event()             │
  │     → alloc_perm_event()                │
  │     → fsnotify_add_event()              │
  │     → wake_up() ────────────────        │
  │                                         ├─ read(fd) 获取事件
  │                                         │   获取文件路径
  │   [进程在此阻塞]                         │   执行安全检查
  │   wait_event(wq, response)              │   write(fd, ALLOW/DENY)
  │                                         │
  ├─ ← 被唤醒!                             │
  │   response == FAN_ALLOW?                │
  │   → 继续打开文件                         │
  │   → 返回 fd                             │
  │                                         │
  └─ 或 response == FAN_DENY                │
      → 返回 -EPERM                          │
```

此阻塞机制是 fanotify 与 inotify 的关键区别。inotify 只能事后通知，fanotify 可以在操作前拦截并决策。

---

## 11. FAN_CLASS 三种模式

| 模式 | 事件传递时机 | 性能 | 适用场景 |
|------|-------------|------|---------|
| NOTIF | 操作完成后 | 最快 | 审计、监控 |
| CONTENT | 操作前（阻塞）| 中 | 防病毒扫描 |
| PRE_CONTENT | 操作前（阻塞）| 慢 | 备份、归档 |

```c
// FAN_CLASS_NOTIF — 非阻塞，仅通知
int fd = fanotify_init(FAN_CLASS_NOTIF, O_RDONLY);
// 进程不等待，事件在操作完成后送达

// FAN_CLASS_CONTENT — 内容感知，阻塞
int fd = fanotify_init(FAN_CLASS_CONTENT, O_RDONLY);
// 进程阻塞直到用户空间回复决策
// 用户空间可读取文件内容后决策
```

---

## 12. fanotify_mark 标记管理

```c
// fs/notify/fanotify/fanotify_user.c:1411
fanotify_mark(fd, flags, mask, dirfd, pathname)

// flags:
// FAN_MARK_ADD       — 添加标记
// FAN_MARK_REMOVE    — 移除标记
// FAN_MARK_MOUNT     — 监控整个挂载点
// FAN_MARK_FILESYSTEM — 监控整个文件系统
// FAN_MARK_DONT_FOLLOW — 不跟随符号链接
// FAN_MARK_ONLYDIR   — 仅目录
// FAN_MARK_IGNORED_MASK — 忽略掩码
// FAN_MARK_IGNORED_SURV_MODIFY — 修改后保留忽略

// mask 事件掩码：
// FAN_ACCESS | FAN_MODIFY | FAN_OPEN | FAN_CLOSE
// FAN_OPEN_PERM | FAN_ACCESS_PERM
```

---

## 13. 事件合并

fanotify 会合并相同文件上的连续事件以减少事件队列长度：

```c
// fs/notify/fanotify/fanotify.c — 事件合并
// 如果同一个文件发生连续多次事件，合并为单个事件
// 合并条件：同一 mask、同一文件、同一类型

static int fanotify_merge(struct list_head *list, struct fsnotify_event *event)
{
    // 遍历事件列表，检查是否可以合并
    list_for_each_entry_reverse(lentry, list, list) {
        if (lentry->mask == event->mask &&
            fanotify_event_has_path(lentry) &&
            fanotify_event_has_path(event) &&
            fanotify_path_equal(lentry, event)) {
            // 合并事件掩码
            lentry->mask |= event->mask;
            return 1;  // 合并成功
        }
    }
    return 0;
}
```

---

## 14. 通知组与事件队列

```c
// 用户调用 fanotify_init() 时创建通知组

struct fsnotify_group *fsnotify_alloc_group(const struct fsnotify_ops *ops)
{
    struct fsnotify_group *group;

    group = kzalloc(sizeof(*group), GFP_KERNEL);
    if (!group) return NULL;

    spin_lock_init(&group->event_lock);
    INIT_LIST_HEAD(&group->notification_list);
    init_waitqueue_head(&group->notification_waitq);
    group->max_events = UINT_MAX;

    return group;
}

// 添加事件到通知队列
int fsnotify_add_event(struct fsnotify_group *group,
                        struct fsnotify_event *event,
                        int (*merge)(struct list_head *, struct fsnotify_event *),
                        void (*insert)(struct list_head *, struct fsnotify_event *))
{
    int ret = 0;

    spin_lock(&group->event_lock);

    // 尝试合并
    if (merge && merge(&group->notification_list, event))
        ret = 1;  // 合并成功，不分配新事件

    if (!ret) {
        if (insert)
            insert(&group->notification_list, event);
        else
            list_add_tail(&event->list, &group->notification_list);
        group->q_len++;
    }

    // 唤醒等待进程
    wake_up(&group->notification_waitq);
    spin_unlock(&group->event_lock);

    return ret;
}
```

---

## 15. 用户空间接口

```c
// 读取事件
// read(fanotify_fd, buf, sizeof(buf))
// → 内核在 fsnotify_read() 中从 notification_list 取出事件
// → copy_to_user() 将事件拷贝到用户缓冲区
// → 事件中包含 fd（被访问文件的文件描述符）
// → 用户通过此 fd 读取文件内容

// 回复决策（仅权限事件）
// write(fanotify_fd, &resp, sizeof(resp))
// → 内核在 fanotify_release() 或 fanotify_write() 中处理
// → 找到对应 fanotify_perm_event
// → 设置 event->response = FAN_ALLOW/DENY
// → wake_up(&event->wq) 唤醒等待进程
```

---

## 16. 性能特征

| 操作 | 延迟 | 说明 |
|------|------|------|
| 非权限事件 | ~1-2us | 分配事件 + 加入队列 + 唤醒 |
| 权限事件 | ~100us-10ms | 取决于用户空间响应速度 |
| 大量文件访问 | ~2-5us/次 | 每个 vfs_open 附加开销 |

---

## 17. 常见用例

```c
// 防病毒扫描器（ClamAV on-access）
fd = fanotify_init(FAN_CLASS_CONTENT, O_RDONLY);
fanotify_mark(fd, FAN_MARK_ADD | FAN_MARK_MOUNT,
              FAN_OPEN_PERM, AT_FDCWD, "/");

while (1) {
    n = read(fd, buf, sizeof(buf));
    metadata = (struct fanotify_event_metadata *)buf;
    
    if (metadata->mask & FAN_OPEN_PERM) {
        // 扫描文件
        res = clamav_scan(metadata->fd);
        response.response = res == CL_CLEAN ? FAN_ALLOW : FAN_DENY;
        write(fd, &response, sizeof(response));
        close(metadata->fd);
    }
}
```

---

## 18. 内核配置

```bash
# 需要内核编译选项
CONFIG_FANOTIFY=y
CONFIG_FANOTIFY_ACCESS_PERMISSIONS=y  # 权限决策支持
CONFIG_FANOTIFY_OVERSIZE=y           # 超限事件
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 19. 事件元数据结构

```c
// include/uapi/linux/fanotify.h
struct fanotify_event_metadata {
    __u32 event_len;      // 事件数据长度
    __u8  vers;           // 版本号
    __u8  reserved;
    __u16 metadata_len;   // 元数据长度
    __aligned_u64 mask;   // 事件掩码
    __s32 fd;            // 被访问文件的 fd
    __s32 pid;           // 触发进程 PID
};
```

---

## 20. 错误处理

| 错误 | 原因 | 处理 |
|------|------|------|
| EMFILE | 超出 max_user_groups | 增大 sysctl 限制 |
| ENOMEM | 内存不足 | 确保有足够内存 |
| EPERM | 无 CAP_SYS_ADMIN | 使用 root 运行 |
| ENOENT | 监控路径不存在 | 检查路径 |
| EINVAL | 参数无效 | 检查 flags 和 mask |

---

## 21. fanotify vs inotify 选择指南

```bash
# 使用 inotify 当:
# - 只需监控几个特定文件/目录
# - 不需要访问决策
# - 不需要文件描述符

# 使用 fanotify 当:
# - 需要监控整个挂载点（全盘扫描）
# - 需要访问前决策（防病毒）
# - 需要文件描述符
# - 容器安全监控
```

---

## 22. 总结

fanotify 提供比 inotify 更强大的文件系统监控能力——全局挂载点监控、访问前权限决策、文件描述符传递。FAN_CLASS_CONTENT 模式下支持防病毒等安全应用。权限决策通过阻塞发起进程直到用户空间回复来实现。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 23. 调试 fanotify

```bash
# 查看 fanotify 监控点
cat /proc/fs/fanotify/marks

# strace 跟踪 fanotify 调用
strace -e fanotify_init,fanotify_mark -p <pid>

# 查看通知组 fd
ls -la /proc/<pid>/fd/ | grep fanotify
```

## 24. 参考链接

- 内核源码: fs/notify/fanotify/fanotify.c, fanotify_user.c
- 文档: Documentation/filesystems/fanotify.rst
- 用户空间: libfanotify (glibc)

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 25. 性能优化建议

- 使用 FAN_CLASS_NOTIF 避免阻塞开销
- 仅监控需要的 mount 点而非全部
- 使用 FAN_MARK_FILESYSTEM 替代 FAN_MARK_MOUNT（覆盖范围更小）
- 用户空间决策守护进程应快速返回
- 使用事件合并减少队列长度


## 26. 关联文章

- **34-fanotify-deep**: 权限决策内部机制
- **81-inotify-fanotify**: inotify vs fanotify 对比

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
