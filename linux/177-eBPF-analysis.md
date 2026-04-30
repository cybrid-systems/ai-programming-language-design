# 177-eBPF — 扩展BPF深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/bpf/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**eBPF（extended Berkeley Packet Filter）** 是 Linux 的内核沙箱，允许用户空间程序在内核中安全执行，实现网络过滤、性能追踪、安全监控等功能。

---

## 1. eBPF 架构

```
用户空间：
  BPF 程序（C 语言） → clang/LLVM 编译 → ELF objdump → eBPF 字节码
         │
         ↓
  bpf() 系统调用 → BPF_PROG_LOAD
         │
         ↓
内核：
  BPF 虚拟机（JIT 编译）→ 执行
         │
         ↓
  验证器（Safety） + JIT 编译
```

---

## 2. BPF 程序类型

```c
// BPF_PROG_TYPE_*：

BPF_PROG_TYPE_SOCKET_FILTER   // 数据包过滤
BPF_PROG_TYPE_KPROBE        // kprobe 探针
BPF_PROG_TYPE_TRACEPOINT   // tracepoint
BPF_PROG_TYPE_XDP          // XDP（快速数据包处理）
BPF_PROG_TYPE_SCHED_CLS    // 流量分类（tc）
BPF_PROG_TYPE_CGROUP_SKB   // cgroup skb
BPF_PROG_TYPE_SOCK_OPS    // socket 选项
BPF_PROG_TYPE_STRUCT_OPS   // struct 操作
BPF_PROG_TYPE_RAW_TRACEPOINT  // 原始 tracepoint
BPF_PROG_TYPE_TRACING     // fentry/fexit/LSM
```

---

## 3. BPF Maps

```c
// BPF Map：内核-用户空间共享数据
// 创建：
bpf(BPF_MAP_CREATE, &attr);
// attr.map_type = BPF_MAP_TYPE_HASH;
// attr.max_entries = 100;

// 操作：
bpf(BPF_MAP_LOOKUP_ELEM, fd, &key, &value);
bpf(BPF_MAP_UPDATE_ELEM, fd, &key, &value, BPF_ANY);
bpf(BPF_MAP_DELETE_ELEM, fd, &key);

// Map 类型：
//   BPF_MAP_TYPE_HASH        — 哈希表
//   BPF_MAP_TYPE_ARRAY       — 数组
//   BPF_MAP_TYPE_PERCPU_HASH — per-CPU 哈希
//   BPF_MAP_TYPE_STACK_TRACE — 栈跟踪
//   BPF_MAP_TYPE_CGROUP_ARRAY — cgroup 数组
//   BPF_MAP_TYPE_RINGBUF    — 环形缓冲区（高性能）
```

---

## 4. XDP（Express Data Path）

```c
// XDP：数据包在网卡驱动层处理
// 在 BPF_PROG_TYPE_XDP 中：
//   return XDP_PASS;   // 继续处理
//   return XDP_DROP;   // 丢弃
//   return XDP_REDIRECT; // 重定向到其他接口
//   return XDP_TX;     // 从同一接口发回

// 性能：单个数据包处理仅需 ~100ns
// vs 传统：~1000ns+
```

---

## 5. BPF 验证器

```c
// kernel/bpf/verifier.c — BPF 验证器
// 1. 无循环（或有界循环）
// 2. 所有内存访问安全
// 3. 栈大小限制（512 字节）
// 4. 不能执行危险指令
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/bpf/syscall.c` | `bpf_prog_load`、`bpf_map_create` |
| `kernel/bpf/verifier.c` | `check_subprog_instructions` |
| `kernel/bpf/jit.c` | `bpf_jit_compile` |

---

## 7. 西游记类喻

**eBPF** 就像"天庭的临时法术"——

> eBPF 允许天庭（用户空间）临时写一个法术（BPF 程序），通过验证器检查安全性后，在天庭内部执行。好处是既有内核速度（零拷贝、无上下文切换），又有用户空间的灵活性。XDP 像在最靠近城门的守将那里（网卡驱动）拦截处理，快到极致；普通 BPF 程序则在内核各个位置执行追踪和过滤。

---

## 8. 关联文章

- **ftrace**（article 55）：BPF 可以 attach 到 tracepoint
- **XDP**（相关）：XDP 是最快的网络数据路径