# 202-syscall_table — 系统调用表深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`arch/x86/entry/syscalls/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**syscall table** 是系统调用的入口表，x86_64 有约 450 个 syscall，映射 syscall 编号到内核函数。

---

## 1. x86_64 syscall 编号

```c
// arch/x86/entry/syscalls/syscall_64.tbl
// 0-31: 保留
// 32: read
// 33: write
// 56: openat
// 57: close
// 59: execve
// 60: exit
// 62: kill
// 63: newfstat
// ...

// 查看当前系统调用：
cat /proc/sys/kernel/osrelease | head -1
ausyscall --dump  # 查看所有系统调用
```

---

## 2. syscall入口

```c
// arch/x86/entry/entry_64.S
// syscall:
syscall:
    // 1. 保存寄存器
    // 2. 调用 sys_call_table[rax]
    call *sys_call_table(%rax, %rsp)
```

---

## 3. 西游记类喻

**syscall table** 就像"天庭的挂号处"——

> syscall 像挂号处——每个挂号窗口（syscall 编号）对应一个部门（内核函数）。挂号处（syscall table）把窗口号映射到具体的部门。妖怪（用户进程）通过挂号（syscall）让天庭（内核）办事，办完后再回到妖怪那里。

---

## 4. 关联文章

- **syscall**（相关）：所有系统调用的基础