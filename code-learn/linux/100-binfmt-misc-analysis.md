# 100-binfmt-misc — Linux 杂项二进制格式处理框架深度源码分析

## 0. 概述

**binfmt_misc** 允许内核通过文件头 magic 识别并执行非标准的二进制格式。它根据注册的模式匹配文件的 magic 字节，然后调用对应的解释器（如 QEMU 用户态模拟器执行跨架构二进制）。

## 1. 核心结构

```c
struct misc_bintfmt {
    struct list_head        list;               // 注册的格式链表
    struct binfmt_entry     entries[];          // 格式条目
};

struct binfmt_entry {
    struct misc_bintfmt     *binfmt;
    char                    *interpreter;       // 解释器路径（如 /usr/bin/qemu-aarch64）
    char                    *magic;             // 文件头部 magic 字节
    char                    *mask;              // magic 匹配掩码
    int                     size;               // magic 长度
    int                     offset;             // magic 偏移
    unsigned long           flags;              // MISC_FMT_* 标志
    struct file             *interp_file;       // 解释器文件
};
```

## 2. 注册流程

```bash
# 注册 ARM64 二进制格式支持：
echo ':arm64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:/usr/bin/qemu-aarch64:P' > /proc/sys/fs/binfmt_misc/register
```

命令格式：`:name:type:offset:magic:mask:interpreter:flags`
- `M` = magic 匹配（文件头字节）
- `E` = 扩展名匹配（文件后缀）
- `P` = 保留 credit（凭证标志）

## 3. 源码索引

| 符号 | 文件 |
|------|------|
| `struct binfmt_entry` | fs/binfmt_misc.c |
| `load_misc_binary()` | fs/binfmt_misc.c |
| `binfmt_misc` | fs/binfmt_misc.c |
