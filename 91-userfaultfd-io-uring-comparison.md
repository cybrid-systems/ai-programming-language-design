# Linux Kernel userfaultfd vs io_uring 对比 深度分析

> 基于 Linux 7.0-rc1 主线源码（`fs/userfaultfd.c` + `io_uring/`）

---

## 0. 两者对比

| 特性 | userfaultfd | io_uring |
|------|-------------|----------|
| 解决的问题 | 页面按需分配 | 高效 I/O 提交/完成 |
| 触发点 | page fault | 系统调用 |
| 关键优势 | 用户页故障处理 | 零 syscall（SQPOLL）|
| 典型用户 | QEMU/KVM、数据库 | 高性能服务器 |
| 内核版本 | 4.3+ | 5.1+ |

---

## 1. userfaultfd — 页面故障处理

```
用户空间注册 [start, start+len] 内存区域
  ↓
应用访问未映射页 → 触发 page fault
  ↓
内核发送 UFFD_EVENT_PAGEFAULT 给用户空间
  ↓
用户空间分配页、填充数据、ioctl UFFDIO_COPY
  ↓
内核完成映射，应用继续执行
```

---

## 2. io_uring — 高效 I/O

```
传统：每次 read/write 都要 syscall
io_uring：
  - 用户写 SQE → 共享内存（无 syscall）
  - 内核线程轮询 SQ（SQPOLL）
  - 内核写 CQE → 共享内存（无 syscall）
  - 应用直接读取 CQE
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `fs/userfaultfd.c` | userfaultfd 实现 |
| `io_uring/io_uring.c` | io_uring 核心 |
