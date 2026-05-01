# 32-fanotify — 文件系统事件通知深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**fanotify** 是 Linux 文件系统事件通知机制，比 inotify 更强大，支持：
- 访问/修改/打开/关闭事件
- **访问控制**（PRE_OPEN/PERM 事件，用户决定允许/拒绝）
- 仅需监控整个挂载点（而非逐个文件）

---

## 1. 核心数据流

```
fanotify_mark(fd, mark_type, mask, dfd, pathname)
  │
  └─ do_fanotify_mark(fd, flags, mask, dfd, pathname)
       └─ fanotify_add_mark(group, path, mask, flags)
            └─ 将 mark 添加到 inode 的 i_fsnotify_marks 链表

文件操作触发 ↓
  │
  fsnotify_access(file) / fsnotify_modify(file)
    └─ __fsnotify_parent()
    └─ fsnotify(inode, mask, data, data_type, file)
         └─ fanotify_handle_event()
              └─ 创建事件 → 加入 group 队列
              └─ 唤醒等待的 fd（fanotify fd 变为可读）

用户空间：
  read(fanotify_fd, buf, bufsize)
    → 收到事件（struct fanotify_event_metadata）
  write(fanotify_fd, buf, sizeof(struct fanotify_response))
    → 回复（仅 PREM 事件需要）
```

---

*分析工具：doom-lsp（clangd LSP）*
