# 56-devm — 设备管理资源深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**devm（Device Resource Management）** 自动管理设备驱动中的资源（内存、中断、IO 映射等），驱动只需在 probe 时分配，资源在 remove 或驱动卸载时自动释放。

---

## 1. 核心思想

```
传统模式：
  probe:   alloc A → alloc B → request_irq → ...
  remove:  ... → free_irq → free B → free A
  （必须严格逆序，否则内存泄漏）

devm 模式：
  probe:   devm_kmalloc → devm_request_irq → ...
  remove:  无需操作，devres 自动逆序释放
```

---

*分析工具：doom-lsp（clangd LSP）*
