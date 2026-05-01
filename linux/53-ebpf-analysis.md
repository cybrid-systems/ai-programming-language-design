# 53-eBPF — 扩展伯克利包过滤器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**eBPF** 允许用户空间在内核中安全运行沙箱化程序。eBPF 程序通过内核验证器检查后，由 JIT 编译器转换为本地代码。用于跟踪、网络过滤、安全等场景。

doom-lsp 确认 `kernel/bpf/verifier.c` 包含约 1140+ 个符号。

---

## 1. 核心路径

```
eBPF 程序生命周期：
  │
  ├─ [加载] bpf() 系统调用
  │    └─ bpf_prog_load(attr, uattr, linfo)
  │         └─ bpf_check(prog, attr)        ← 验证器
  │              ├─ 检查指令合法性
  │              ├─ 构建 CFG（控制流图）
  │              ├─ 检查栈大小（MAX_BPF_STACK = 512）
  │              ├─ 模拟每条指令执行
  │              │    └─ check_alu_op / check_jmp_op / check_mem_access
  │              └─ 确保程序终止（无循环）
  │
  ├─ [JIT 编译] bpf_jit_binary_alloc + arch JIT hook
  │    └─ x86_64: do_jit()
  │
  └─ [附加] bpf_prog_attach(target, prog, type)
       └─ 附加到跟踪点/XDP/TC/cgroup 等
```

---

*分析工具：doom-lsp（clangd LSP）*
