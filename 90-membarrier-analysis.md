# Linux Kernel membarrier / 内存屏障 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/membarrier.c` + `include/linux/membarrier.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. membarrier 系统调用

```c
// 用户空间：
// 确保跨线程内存可见性，无需锁或自旋锁

// 1. 注册 private expedited missions
int ret = syscall(__NR_membarrier, MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED, 0);

// 2. 发起 memory barrier
syscall(__NR_membarrier, MEMBARRIER_CMD_PRIVATE_EXPEDITED, 0);
```

---

## 1. 内存屏障类型

```c
// include/linux/membarrier.h
// 编译屏障（阻止编译器重排）
#define barrier()  asm volatile("" ::: "memory")

// CPU 内存屏障（阻止 CPU 重排）
#define smp_mb()   ...  // 完整屏障
#define smp_rmb()  ...  // 读屏障
#define smp_wmb()  ...  // 写屏障
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `kernel/membarrier.c` | `sys_membarrier` 实现 |
| `include/linux/membarrier.h` | 内存屏障宏定义 |
