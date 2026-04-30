# 193-userfaultfd — 用户空间缺页处理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/userfaultfd.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**userfaultfd** 允许用户空间程序处理自己地址空间的缺页中断，实现自定义的页面管理（如写时复制、内存压缩、用户空间页替换）。

---

## 1. userfaultfd API

```c
// 创建 userfaultfd：
int uffd = syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK);

// 注册内存区域：
struct uffdio_register reg = {
    .mode = UFFDIO_REGISTER_MODE_MISSING,
    .range = { .start = 0x1000, .len = 0x1000 }
};
ioctl(uffd, UFFDIO_REGISTER, &reg);

// 读取缺页事件：
struct uffd_msg msg;
read(uffd, &msg, sizeof(msg));
// msg.event = UFFD_EVENT_PAGEFAULT
// msg.arg.pagefault.address = fault 地址

// 解决缺页：
struct uffdio_copy copy = {
    .dst = msg.arg.pagefault.address,
    .src = page_buffer,
    .len = PAGE_SIZE
};
ioctl(uffd, UFFDIO_COPY, &copy);
```

---

## 2. 缺页类型

```
userfaultfd 处理的缺页类型：
  UFFD_EVENT_PAGEFAULT — 缺页
  UFFD_EVENT_FORK — 进程 fork
  UFFD_EVENT_REMOVE — 注销区域
  UFFD_EVENT_UNMAP — 区域被 unmap
```

---

## 3. 西游记类喻

**userfaultfd** 就像"天庭的托管驿站"——

> userfaultfd 像天庭把某个营地的管理权托管给用户空间。如果妖怪（进程）访问营地时发现门关了（缺页），妖怪会去找托管官员（userfaultfd）报告，官员可以决定是给钥匙开门（填充页）还是拒绝进入（SIGBUS）。

---

## 4. 关联文章

- **page_fault**（相关）：userfaultfd 增强缺页处理
- **KVM**（相关）：KVM 使用 userfaultfd 实现嵌套虚拟化