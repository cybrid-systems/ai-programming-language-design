# 180-kgdb_kdump — 内核调试器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/debug/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**kgdb** 是 Linux 内核的源码级调试器，配合 gdb 使用。**kdump** 是内核崩溃转储工具，用于在崩溃时保存内存快照。

---

## 1. kgdb

```bash
# kgdb 配置：
# 1. 启动参数：kgdboc=ttyS1,115200 kgdwait
# 2. 目标机器：gdb vmlinux
# 3. 连接：target remote /dev/ttyS1

# kgdb 断点：
#   b function_name
#   c  // continue
#   n  // next
#   s  // step
#   bt  // backtrace
```

---

## 2. kdump

```bash
# kdump 配置：
# 1. 设置 crashkernel=128M
# 2. 崩溃时：
#    → kexec 启动备用内核
#    → 备用内核捕获主内核内存
#    → 保存到 /var/crash/

# 分析：
crash vmlinux vmcore
crash> bt  // 查看崩溃堆栈
crash> dis  // 反汇编
```

---

## 3. kexec

```c
// kexec 系统调用：
// 启动备用内核
sys_kexec_load()
```

---

## 4. 西游记类喻

**kgdb/kdump** 就像"天庭的黑匣子"——

> kgdb 像天庭的远程专家会诊——专家可以通过专线（串口）实时看到天庭内部的情况（源码级调试）。kdump 像飞机上的黑匣子——天庭正常运行时不启用，一旦崩溃（panic），黑匣子自动记录当时的场景（内存快照），事后可以还原崩溃时的状态，找出问题所在。

---

## 5. 关联文章

- **lockdep**（相关）：kgdb 用于调试死锁
- **perf**（article 178）：kdump 捕获崩溃现场