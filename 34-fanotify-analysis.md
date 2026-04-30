# fanotify — 文件系统事件通知深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/notify/fanotify/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**fanotify** 是 Linux 的高级文件系统事件通知机制，支持：
- 监控文件/目录上的事件（OPEN、CLOSE_WRITE、ACCESS、MODIFY 等）
- 在权限检查点阻止操作（PRE-OPEN、PRE-ACCESS）
- 相比 inotify 更适合企业级文件监控（大规模目录监控）

---

## 1. fanotify vs inotify

| 特性 | inotify | fanotify |
|------|---------|---------|
| 粒度 | 单用户监听 | 组播（多用户）|
| 权限事件 | 不支持 | 支持（PRE-OPEN 等）|
| 大规模监控 | 需多个实例 | 单实例监控大量目录 |
| fanotify_mark | 需要 | 支持 |
| 典型用途 | 个人桌面 | 企业文件服务器 |

---

## 2. 核心数据结构

### 2.1 fanotify_group — 通知组

```c
// fs/notify/fanotify/fanotify.h — fanotify_group
struct fanotify_group {
    // 通知机制
    struct fsnotify_mark_entry  **marks;    // 监控标记（按 inode/标记分组）
    struct hlist_head            mark_list;   // 标记链表

    // 溢出
    unsigned int                overflow_flags; // 溢出标志

    // 反应
    unsigned int                flags;        // FAN_* 标志
    struct fanotify_response   *default_response; // 默认响应

    // 状态
    unsigned long               mask;        // 监控事件掩码
    unsigned long               priority;     // 优先级
};
```

### 2.2 fanotify_mark — 监控标记

```c
// fs/notify/fanotify/fanotify.h — fanotify_mark
struct fanotify_mark {
    struct fsnotify_mark_entry  entry;        // 基类
    unsigned long               mask;        // 事件掩码
    struct fanotify_event       *events;      // 事件队列
};
```

### 2.3 事件掩码

```c
// include/uapi/linux/fanotify.h — 事件类型
#define FAN_ACCESS          0x00000001   // 文件被访问（read）
#define FAN_MODIFY          0x00000002   // 文件被修改（write）
#define FAN_CLOSE_WRITE     0x00000008   // 可写文件关闭
#define FAN_CLOSE_NOWRITE   0x00000010   // 只读文件关闭
#define FAN_OPEN            0x00000020   // 文件打开
#define FAN_OPEN_EXEC       0x00001000   // 执行文件打开
#define FAN_ATTRIB          0x00000004   // 文件属性变化
#define FAN_MOVED_FROM      0x00000040   // 文件移出
#define FAN_MOVED_TO        0x00000080   // 文件移入
#define FAN_CREATE          0x00000100   // 文件创建
#define FAN_DELETE          0x00000200   // 文件删除
#define FAN_DELETE_SELF     0x00000400   // 监控的目录/文件被删除
#define FAN_MOVE_SELF       0x00000800   // 监控的目录/文件被移动

// 权限事件（需要应用响应）：
#define FAN_OPEN_PERM       0x00010000   // OPEN 需要权限
#define FAN_ACCESS_PERM     0x00020000   // ACCESS 需要权限

// 全部：
#define FAN_ALL_EVENTS      (FAN_ACCESS | FAN_MODIFY | FAN_CLOSE_WRITE | ...)

// 目录事件：
#define FAN_ALL_DIR_EVENTS  (FAN_CREATE | FAN_MOVED_FROM | FAN_MOVED_TO | ...)
```

---

## 3. fanotify_init — 初始化

```c
// fs/notify/fanotify/fanotify_user.c — sys_fanotify_init
SYSCALL_DEFINE2(fanotify_init, unsigned int, flags, unsigned int, event_f_flags)
{
    struct fanotify_group *group;
    struct dentry *notify_dentry;
    struct file *event_file;

    // 1. 验证标志
    if (flags & ~FAN_ALL_INIT_FLAGS)
        return -EINVAL;

    // 2. 分配组
    group = kmem_cache_alloc(fanotify_group_cache, GFP_KERNEL);
    if (!group)
        return -ENOMEM;

    // 3. 初始化
    group->flags = flags;
    group->mask = 0;
    group->priority = 0;

    // 4. 创建用于读取事件的 fd
    event_file = anon_inode_getfile("[fanotify]", &fanotify_fops, group, O_RDWR);
    if (IS_ERR(event_file))
        return PTR_ERR(event_file);

    return anon_inode_getfd("[fanotify]", event_file);
}
```

---

## 4. fanotify_mark — 设置监控

```c
// fs/notify/fanotify/fanotify_user.c — sys_fanotify_mark
SYSCALL_DEFINE5(fanotify_mark, int, fanotify_fd, unsigned int, flags,
                __u64, mask, int, dfd, const char *, pathname)
{
    struct file *filp;
    struct fanotify_group *group;
    struct path path;
    unsigned int mark_type;
    int ret;

    // 1. 获取 fanotify 实例 fd
    filp = fget(fanotify_fd);
    group = filp->private_data;

    // 2. 解析标志
    if (flags & FAN_MARK_ADD)
        mark_type = FSNOTIFY_MARK_TYPE_INODE; // inode 标记
    else if (flags & FAN_MARK_REMOVE)
        mark_type = FSNOTIFY_MARK_TYPE_INODE;

    // 3. 获取路径
    ret = user_path_at(dfd, pathname, LOOKUP_FOLLOW, &path);

    // 4. 添加/移除监控
    if (flags & FAN_MARK_ADD) {
        ret = fsnotify_add_mark(&group->mark[mark_type],
                                path.dentry->d_inode,
                                mask, group);
    } else if (flags & FAN_MARK_REMOVE) {
        fsnotify_remove_mark(&group->mark[mark_type], ...);
    }

    return ret;
}
```

---

## 5. 权限事件处理流程

```c
// fanotify 权限事件流程：

// 1. 应用调用：
fd = fanotify_init(FAN_CLASS_PRE_CONTENT, O_RDWR);
// → 创建 fanotify_group

// 2. 设置监控：
fanotify_mark(fd, FAN_MARK_ADD, FAN_OPEN_PERM, AT_FDCWD, "/path");

// 3. 内核事件触发：
open("/path/file") → do_sys_open → fanotify_handle_event
  → 检查是否有 mark 匹配
  → 如果是 FAN_OPEN_PERM：
    → 分配 fanotify_fid 事件
    → 发送到应用
    → 进程阻塞（等待响应）

// 4. 应用收到事件：
read(fd, &event, sizeof(event));
// event 中包含文件的 fanotify_fid

// 5. 应用决定允许/拒绝：
//   FAN_ALLOW → 允许操作继续
//   FAN_DENY  → 返回 -EPERM

write(fd, &response, sizeof(response));
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/notify/fanotify/fanotify.h` | `struct fanotify_group`、`struct fanotify_mark` |
| `fs/notify/fanotify/fanotify_user.c` | `sys_fanotify_init`、`sys_fanotify_mark` |
| `include/uapi/linux/fanotify.h` | `FAN_*` 事件和标志 |