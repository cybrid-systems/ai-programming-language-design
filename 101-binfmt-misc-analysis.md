# binfmt_misc — misc 二进制格式处理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/binfmt_misc.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**binfmt_misc** 允许注册自定义二进制格式处理器，无需修改内核即可运行非原生格式（如 Java、Python）。

---

## 1. 核心数据结构

### 1.1 binfmt — 格式条目

```c
// fs/binfmt_misc.c — mstate
struct mstate {
    // 格式标识
    const char             *name;          // 名称（如 "Java"）
    const char             *interpreter;   // 解释器路径（如 "/usr/bin/java"）
    const char             *flags;         // 标志

    // 模式
    enum {
        E_ENABLED,     // 启用
        E_DISABLED,    // 禁用
    } enabled;

    // 匹配
    unsigned char           offset;         // magic 偏移
    unsigned char           size;           // magic 大小
    char                   *magic;          // 魔数（字节序列）

    // 注册
    struct file            *interp_file;    // 解释器文件
    struct dentry          *entry;          // /proc 入口
    struct list_head        list;           // 链表
};
```

---

## 2. 注册格式

### 2.1 parse_binfmt — 解析格式定义

```c
// fs/binfmt_misc.c — parse_binfmt
static int parse_binfmt(const char *buffer, const struct file *filep)
{
    // 格式：name:Magic:offset:interpreter:flags
    // 例如：Java:\xCA\xFE\xBA\xBE:0:/usr/bin/java

    // 1. 解析名称和解释器
    // 2. 读取 magic 字节
    // 3. 设置偏移和大小
    // 4. 打开解释器文件
}
```

### 2.2 load_misc_binary — 加载二进制

```c
// fs/binfmt_misc.c — load_misc_binary
static int load_misc_binary(struct linux_binprm *bprm)
{
    struct mstate *m;

    // 1. 查找匹配的格式
    list_for_each_entry(m, &entries, list) {
        if (match_magic(m, bprm->buf))
            break;
    }

    // 2. 打开解释器
    if (m && m->enabled) {
        // 使用 m->interpreter 执行文件
        return search_binary_handler(bprm);
    }

    return -ENOEXEC;
}
```

---

## 3. proc 接口

```c
// /proc/sys/fs/binfmt_misc/
// 触发注册：
echo ':name:Magic:offset:interpreter:flags' > /proc/sys/fs/binfmt_misc/register

// 取消注册：
echo -1 > /proc/sys/fs/binfmt_misc/<name>/status
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/binfmt_misc.c` | `mstate`、`load_misc_binary` |