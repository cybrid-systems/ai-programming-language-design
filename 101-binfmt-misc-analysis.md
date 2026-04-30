# Linux Kernel binfmt_misc 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/binfmt_misc.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. binfmt_misc 概述

**binfmt_misc** 允许注册**自定义二进制格式解释器**，让内核能够运行非原生格式：
- `qemu-user-static`：注册 `/usr/bin/qemu-arm` 处理 ARM 二进制
- Windows PE：注册 wine 加载 Windows 程序
- Python `.py` 脚本（`#! /usr/bin/python`）

---

## 1. 注册格式

```c
// echo ":python:M::#!/usr/bin/python:./python" > /proc/sys/fs/binfmt_misc/register

// 格式：
// :name:flags:interpreter:signature
//
// name  — 注册名称
// flags — M（magic）/ E（extension）
// interpreter — 解释器路径
// signature — 文件头 magic 字节或文件扩展名
```

---

## 2. 核心结构

```c
// fs/binfmt_misc.c — binfmt_entry
struct binfmt_entry {
    struct list_head        list;           // 链表
    int                     type;            // ENT_TYPE_MAGIC / ENT_TYPE_EXT
    char                    *interpreter;     // 解释器路径（如 qemu-arm）
    char                    *proc_slot;       // /proc/PID/exe 的替换
    size_t                  offset;           // magic 偏移
    size_t                  magic_size;       // magic 长度
    unsigned char            *magic;          // magic 字节
    unsigned long            flags;           // M/E 标志
};
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `fs/binfmt_misc.c` | `load_misc_binary`、`lookup_entry` |
