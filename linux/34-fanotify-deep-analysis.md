# 34-fanotify-deep -- fanotify internals

> Based on Linux 7.0-rc1

## 0. Overview

Deep dive into fanotify permission decision mechanism and notification groups.

## 1. Permission event handling

fanotify_perm_event: response, pid, wait_queue_head_t

## 2. FAN_CLASS_CONTENT caching

Content mode caches file data for scanner access.

## 3. Performance

Non-permission: ~1us per event
Permission: ~100us-10ms (blocking)

## 4. Kernel config

CONFIG_FANOTIFY=y
CONFIG_FANOTIFY_ACCESS_PERMISSIONS=y


Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis
Deep analysis

## 4. fanotify 权限决策阻塞

用户空间响应前，发起文件访问的进程阻塞在内核中。

## 5. 缓存

FAN_CLASS_CONTENT 模式下，文件内容被缓存供扫描器访问。


## 4. 权限事件阻塞

用户空间响应前，访问文件的进程在内核中阻塞等待。

## 5. FAN_CLASS_CONTENT 缓存

文件内容被缓存供扫描器访问。减少扫描时的磁盘 I/O。

## 6. 性能和配置

非权限模式: ~1us/event
权限模式: ~100us-10ms (阻塞)
fs.fanotify.max_user_groups = 128
fs.fanotify.max_user_marks = 8192

## 7. 关联文章

- **32-fanotify**: fanotify 基础
- **81-inotify-fanotify**: 对比


## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## Permission event flow

Userspace reads event, performs security check, writes response. Process blocks on wait_event in the kernel. When userspace writes FAN_ALLOW, wait_event completes and the file access continues. When FAN_DENY, the syscall returns EPERM. The response is written via write() on the fanotify fd.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.

## FAN_CLASS_CONTENT caching

For antivirus use cases, Content class caches file data locally. This avoids re-reading from disk when the scanner accesses the file through the provided fd. The cache is invalidated after the permission check completes.
