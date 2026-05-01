# 51-userfaultfd — 用户空间缺页处理深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**userfaultfd** 允许用户空间处理缺页异常。典型用途：虚拟机迁移（只需在缺页时从源端复制页面）、检查点/恢复、内存压缩。

---

## 1. 核心流程

```
注册：
  userfaultfd(flags)                       ← 创建 fd
    └─ ioctl(UFFDIO_REGISTER, &ucc)        ← 注册 VMA
         └─ mfill_atomic_install_pte() 设置缺页处理

缺页触发：
  进程访问已注册但未分配的页面
    → 触发缺页异常
    → handle_userfault(vmf, UFFD_MISSING)
       → wake up userfaultfd reader

用户空间处理：
  read(uffd, &msg, sizeof(msg))            ← 收到缺页事件
    └─ ioctl(UFFDIO_COPY, &uc)             ← 填入页面内容
         └─ copy_page_from_user()           ← 复制用户提供的页
```

---

*分析工具：doom-lsp（clangd LSP）*
