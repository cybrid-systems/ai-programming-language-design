# 34-fanotify-deep — Fanotify 深度分析

## 0. 概述
fanotify 权限决策和通知组的内部实现。

## 1. 权限决策
```c
// fs/notify/fanotify/fanotify.c
struct fanotify_perm_event {
    struct fsnotify_event fse;
    int response;           // FAN_ALLOW/FAN_DENY
    struct pid *pid;
    wait_queue_head_t wq;
};
```

## 2. 缓存
FAN_CLASS_CONTENT 模式使用 content 缓存。

## 3. 关联文章
- **32-fanotify**: fanotify 基础
- **81-inotify-fanotify**: 对比分析
