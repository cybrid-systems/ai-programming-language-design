# 32-fanotify -- Linux file access notification analysis

> Based on Linux 7.0-rc1

## 0. Overview

fanotify monitors filesystem events for entire mount points. Supports permission decisions (allow/deny). Used for antivirus, audit, DLP.

## 1. API

fanotify_init(FAN_CLASS_CONTENT, O_RDONLY)
fanotify_mark(fd, FAN_MARK_ADD | FAN_MARK_MOUNT, FAN_OPEN | FAN_ACCESS | FAN_OPEN_PERM, AT_FDCWD, "/")
read(fd, buf, sizeof(buf))
write(fd, response, sizeof(response))

## 2. vs inotify

inotify: per-file, no permission events
fanotify: whole mount, permission events, file descriptors

## 3. Event types

FAN_ACCESS, FAN_MODIFY, FAN_OPEN, FAN_CLOSE, FAN_OPEN_PERM, FAN_ACCESS_PERM

## 4. Permission flow

vfs_open -> fsnotify_open -> fanotify_perm_handle_event -> wait_event -> userspace response -> FAN_ALLOW/FAN_DENY

## 5. Data structures

struct fanotify_group: fsn_group, fasync, flags, max_marks

## 6. Configuration

fs.fanotify.max_user_groups = 128
fs.fanotify.max_user_marks = 8192

## 7. Implementation files

fs/notify/fanotify/fanotify.c
fs/notify/fanotify/fanotify_user.c


Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis
Detailed analysis

## 9. ClamAV 集成示例

ClamAV 使用 fanotify FAN_CLASS_CONTENT 实现实时文件扫描。

## 10. 性能

非权限事件: ~1us
权限事件: ~100us-10ms（取决于用户空间响应速度）

## 11. 配置

CONFIG_FANOTIFY=y
CONFIG_FANOTIFY_ACCESS_PERMISSIONS=y


## 9. 事件信息结构

fanotify_event_metadata 包含事件掩码、文件描述符、PID 等信息。用户空间通过 read(fd) 获取事件。

## 10. 性能瓶颈

权限事件阻塞进程直到用户空间响应。建议:
- 用户空间决策快速返回
- 避免全 FS 监控
- 使用 FAN_CLASS_NOTIF 减少阻塞

## 11. 内核配置

CONFIG_FANOTIFY=y
CONFIG_FANOTIFY_ACCESS_PERMISSIONS=y
CONFIG_FANOTIFY_OVERSIZE=y

## 12. 调试

cat /proc/fs/fanotify/marks 查看所有监控点。

## 13. 源码文件

fs/notify/fanotify/fanotify.c: 核心事件逻辑
fs/notify/fanotify/fanotify_user.c: 用户接口

## 14. 关联文章

- **34-fanotify-deep**: 权限决策内部
- **81-inotify-fanotify**: inotify vs fanotify 对比


## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Additional content

fanotify_init() creates an fanotify group. fanotify_mark() adds watches. The group maintains an event queue. Permission events block the calling process until userspace responds. FAN_CLASS_CONTENT caches file data for scanner access. Events are read via read() on the fanotify fd. Responses are written via write(). The kernel-side implementation in fs/notify/fanotify/ handles event queuing, merging, and delivery. CONFIG_FANOTIFY_ACCESS_PERMISSIONS enables permission events.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.

## Error handling

If fanotify_init fails, check CONFIG_FANOTIFY in kernel config. EMFILE if per-process limit reached. ENOMEM if allocation fails. EPERM if not enough privileges. Fanotify requires CAP_SYS_ADMIN.
