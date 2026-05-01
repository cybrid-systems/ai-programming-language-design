# 58-binder — Android Binder IPC 驱动深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**Binder** 是 Android 中进程间通信（IPC）的核心机制。每个 Android 服务都通过 Binder 对外提供接口，唯一的 Binder 驱动在内核中实现。

---

## 1. 核心路径

```
Client → Binder 驱动 → Server
  │
  ├─ client: 通过 ioctl(BINDER_WRITE_READ) 发送事务
  ├─ driver: binder_transaction()
  │    ├─ 复制用户数据到内核空间
  │    ├─ 查找目标进程的 handle
  │    ├─ 将事务放入目标进程的待处理队列
  │    └─ 唤醒目标进程
  └─ server: ioctl(BINDER_WRITE_READ) 读取事务
       └─ 处理请求 → 通过 binder 发送回复
```

---

*分析工具：doom-lsp（clangd LSP）*
