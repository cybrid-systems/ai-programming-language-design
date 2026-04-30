# Linux Kernel eBPF 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/bpf/` + `net/core/filter.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 eBPF？

**eBPF（extended Berkeley Packet Filter）** 是 Linux 4.x+ 引入的**内核沙箱**，允许用户空间程序在内核中运行自定义代码（经过验证），用于：
- 网络过滤（XDP、tc BPF）
- 性能跟踪（bpftrace、perf）
- 安全监控（系统调用审计）

---

## 1. 核心数据结构

```c
// kernel/bpf/syscall.c — bpf syscall
// 用户空间创建 eBPF 程序：
// prog = bpf(BPF_PROG_LOAD, &attr, sizeof(attr));

// 内核验证器
int bpf_check(struct bpf_prog *prog)
{
    // 1. 静态分析：检查无效指令、越界跳转
    // 2. 模拟执行：防止死循环、恶意访问
    // 3. 加载到内核
}
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `kernel/bpf/syscall.c` | `bpf()` syscall、`BPF_PROG_LOAD` |
| `kernel/bpf/verifier.c` | eBPF 验证器 |
| `net/core/filter.c` | BPF_PROG_TYPE_SOCKET_FILTER |
