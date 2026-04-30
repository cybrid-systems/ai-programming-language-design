# Linux Kernel io_uring Deep Dive 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`io_uring/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 进阶特性

io_uring 相比 epoll 的核心优势：
- **Registered Ring**：绕过系统调用，直接提交
- **Fixed File**：注册文件 fd，避免每次 open/close
- **Fixed Buffer**：注册内存缓冲区，避免每次传递用户缓冲区
- **SQPOLL**：内核线程轮询 SQ，消除 syscall 开销

---

## 1. Registered Ring

```c
// 用户空间注册 SQ/CQ 环
struct io_uring_sqe *sqe = &sq->sqes[ sq->sqe_head % sq->ring_mask ];

// 零 syscall 的方式：
// 设置 IORING_SETUP_SQPOLL
// 应用只需写 SQEs，内核线程自动轮询
```

---

## 2. Fixed Buffer

```c
// io_uring_register() — 注册缓冲区
io_uring_register(ring_fd, IORING_REGISTER_BUFFERS, buffers, nr);

// 使用固定缓冲区：
// SQE.opcode = IORING_OP_READ_FIXED
// SQE.addr = buffer_id（已注册缓冲区的 ID）
// SQE.fd = fd

// 优势：
// - 无需每次传递用户缓冲区地址
// - 内核直接使用已映射的缓冲区，无 copy_from_user
```

---

## 3. References

| File | Content |
|------|---------|
| `io_uring/io_uring.c` | Registered ring, fixed buffer |
| `io_uring/rw.c` | IORING_OP_READ_FIXED |
