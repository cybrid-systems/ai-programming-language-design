# Linux Kernel userfaultfd 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/userfaultfd.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 userfaultfd？

**userfaultfd**（Linux 4.3+）允许用户空间程序**处理自己地址空间的 page fault**，用于：
- 用户空间页面管理（自定义页面换入换出）
- 虚拟机内存管理（QEMU/KVM）
- 用户空间页故障处理框架

---

## 1. API

```c
// 用户空间
#include <linux/userfaultfd.h>

// 1. 创建 userfaultfd
int ufd = syscall(__NR_userfaultfd, O_CLOEXEC | O_NONBLOCK);

// 2. 注册内存区域
struct uffdio_api api = { .api = UFFD_API };
ioctl(ufd, UFFDIO_API, &api);

struct uffdio_register reg = {
    .range = { .start = 0x10000, .len = 0x1000 },
    .mode = UFFD_REGISTER_MODE_MISSING   // 只处理缺失 fault
};
ioctl(ufd, UFFDIO_REGISTER, &reg);

// 3. 事件循环
while (1) {
    read(ufd, &event, sizeof(event));  // 阻塞读取 fault 事件
    // event: { .event = UFFD_EVENT_PAGEFAULT, .address, .reason }
    // 处理 page fault：
    //   copy_page_to_user(event.address, page_data);
    //   ioctl(ufd, UFFDIO_COPY, &copy);
}
```

---

## 2. 核心结构

```c
// fs/userfaultfd.c — userfaultfd_ctx
struct userfaultfd_ctx {
    int                     fd;           // userfaultfd 文件描述符
    struct rw_semaphore    map_changing;  // 映射改变信号
    bool                    released;       // 已释放
    atomic_t                ref;
    struct userfaultfd_ctx *mm_changing;  // 映射改变时临时上下文
};
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `fs/userfaultfd.c` | userfaultfd 核心实现 |
| `include/uapi/linux/userfaultfd.h` | UFFDIO_REGISTER、UFFD_EVENT_PAGEFAULT 等 |
