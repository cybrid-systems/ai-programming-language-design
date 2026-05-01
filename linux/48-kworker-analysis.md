# 48-kworker — 内核工作线程深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**kworker** 是 workqueue 系统创建的内核工作线程，执行延迟或异步的工作项。每个 CPU 有多个 kworker 线程（普通/高优先级）。

---

## 1. 线程结构

```
kworker 线程名格式：
  kworker/<cpu>:<id><flags>
    U = unbound（未绑定 CPU）
    H = highpri（高优先级）
    I = cpu intensive（CPU 密集型）

示例：
  kworker/0:0       ← CPU 0 的第一个工作线程
  kworker/1:2H      ← CPU 1 的高优先级线程
  kworker/u8:3      ← 第 8 个 unbound 池的第 3 个线程
```

---

*分析工具：doom-lsp（clangd LSP）*
