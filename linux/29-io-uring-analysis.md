# 29-io_uring — 异步 IO 框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**io_uring**（Linux 5.1）通过共享环形缓冲区在内核和用户空间之间传递 IO 请求/完成事件，减少系统调用开销。

---

## 1. 双环架构

```
用户空间：                       内核：
  SQ（提交队列）                     CQ（完成队列）
  ┌──┬──┬──┬──┐                    ┌──┬──┬──┬──┐
  │A │B │  │  │                    │  │  │  │  │
  └──┴──┴──┴──┘                    └──┴──┴──┴──┘
        │                                ▲
        │ io_uring_enter()                │
        ▼                                │
  处理 SQEs → 执行 → 写完成事件 ─────────┘
```

---

## 2. 操作流程

```
用户空间：
  1. io_uring_setup(entries, &params) → 创建 SQ/CQ 环
  2. mmap 共享环
  3. 填充 SQE（操作码 + fd + offset + buf）
  4. io_uring_enter(fd, to_submit, min_complete, flags)
     └─ io_submit_sqes(ctx, to_submit)
          └─ 对每个 SQE：
               ├─ io_read / io_write
               ├─ io_openat / io_send / io_recv
               └─ io_poll_add / io_timeout
     └─ 等待完成
```

---

## 3. 高级特性

| 特性 | 说明 |
|------|------|
| SQPOLL | 内核线程轮询 SQ，零系统调用 |
| Fixed File | 预注册 fd，减少每次转换 |
| Buffer Selection | 自动选择可用缓冲区 |
| Links | 请求链依赖 |

---

*分析工具：doom-lsp（clangd LSP）*
