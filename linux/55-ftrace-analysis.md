# 55-ftrace — 内核跟踪器深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**ftrace** 是 Linux 内核内置的跟踪工具，可以跟踪函数调用、延迟、中断等事件，而无需重新编译内核。支持 function tracer、function graph tracer、tracepoints、kprobes 等多种方式。

---

## 1. 核心路径

```
函数跟踪（function tracer）：
  │
  ├─ 编译时：每个函数入口插入 nop 指令
  │
  ├─ 启用时：
  │    └─ ftrace_update_code()
  │         └─ 将 nop 替换为 call ftrace_caller
  │
  ├─ ftrace_caller：
  │    └─ 保存上下文
  │    └─ 调用注册的回调函数
  │    └─ 恢复上下文 → 返回原函数继续执行
  │
  └─ trace 数据写入 ring buffer：
       └─ trace_function(tr, ip, parent_ip, flags, pc)
```

---

*分析工具：doom-lsp（clangd LSP）*
