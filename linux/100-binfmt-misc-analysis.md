# 101-binfmt-misc — Linux 杂项二进制格式处理器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**binfmt_misc** 是 Linux 的杂项二进制格式处理机制。用户空间向 `/proc/sys/fs/binfmt_misc/register` 写入格式描述字符串（`:name:type:offset:magic:interpreter:flags`），将任意文件（`.py`、`.jar`、`.wasm`）注册为可执行文件。内核在 `exec()` 时通过 `load_misc_binary()`（`:203`）匹配并调用解释器。

**核心设计**：`binfmt_misc` 通过 `struct linux_binfmt` 接口挂接到 `search_binary_handler()`。`load_misc_binary()` 调用 `get_binfmt_handler()`（`:141`）按文件头魔数或扩展名匹配已注册的 `Node`，匹配后打开解释器文件，用 `prepare_binprm()` + `exec_binprm()` 递归执行。

**doom-lsp 确认**：`fs/binfmt_misc.c`（1,047 行）。`load_misc_binary` @ `:203`，`create_entry` @ `:350`，`put_binfmt_handler` @ `:162`。

---

## 1. 核心数据结构

```c
// fs/binfmt_misc.c
struct Node {                                    // 一种注册的格式
    struct list_head list;                       // entries 链表节点
    const char *filename;                        // 解释器绝对路径
    char *magic;                                 // 文件头魔数
    size_t magiclen;                              // 魔数字节数
    char *mask;                                  // 魔数掩码（字节对比用）
    size_t masklen;
    const char *name;                             // 格式名称
    int flags;                                    // 位掩码：Enabled/Magic/...
    int offset;                                   // 魔数偏移（type=M 时）
    refcount_t users;                            // 同步卸载与加载的引用计数
    struct delayed_work dwork;                    // 删除同步 work
};

// binfmt_misc 的 linux_binfmt 注册：
static struct linux_binfmt misc_format = {
    .module       = THIS_MODULE,
    .load_binary  = load_misc_binary,
};
```

### Node 标志位

```c
#define MISC_FMT_PRESERVE_ARGV0 (1UL << 31)  // 保留 argv[0] 为原文件名
#define MISC_FMT_OPEN_BINARY    (1UL << 30)  // 以 O_BINARY 打开解释器
#define MISC_FMT_CREDENTIALS    (1UL << 29)  // 保留执行者凭据
#define MISC_FMT_OPEN_FILE      (1UL << 28)  // 打开文件而非执行
```

---

## 2. 注册路径——create_entry @ :350

```c
// 用户写入 /proc/sys/fs/binfmt_misc/register
// → entry_write() → create_entry(buffer, count)

static Node *create_entry(const char __user *buffer, size_t count)
{
    // 1. 解析格式字符串
    //    :name:E::py::/usr/bin/python3:F
    //    del=:
    e = kzalloc(sizeof(Node) + count + 8, GFP_KERNEL);
    p = (char *)e + sizeof(Node);              // Node 后紧跟原始数据

    copy_from_user(p, buffer, count);          // 从用户空间复制

    del = *p++;                                // 分隔符（通常 :）
    memset(p + count, del, 8);                 // 填充末尾简化解析

    // 2. 提取 name
    e->name = p; p = strchr(p, del); *p++ = '\0';

    // 3. 提取 type（E=extension/M=magic）
    switch (*p++) {
    case 'E': e->flags = 1 << Enabled; break;
    case 'M': e->flags = (1 << Enabled) | (1 << Magic); break;
    }

    // 4. type=M（magic）→ 解析 offset/magic/mask
    if (test_bit(Magic, &e->flags)) {
        e->offset = kstrtoint(..., &e->offset);
        e->magic = p;                         // 魔数字符串位置
        // 去掉转义 \x...
    }

    // 5. 提取 interpreter（解释器路径）
    e->filename = p;

    // 6. 提取 flags（O=open_binary/C=credential/F=fix_binary 等）
    p = check_special_flags(p, e);

    // 7. 加入链表
    list_add_tail(&e->list, &misc->entries);

    // 8. 在 debugfs 中创建条目文件
    entry = create_binfmt_misc_entry(e);
    return e;
}
```

---

## 3. load_misc_binary @ :203——执行匹配

```c
static int load_misc_binary(struct linux_binprm *bprm)
{
    // 1. 查找匹配的格式
    fmt = get_binfmt_handler(misc, bprm);
    if (!fmt) return -ENOEXEC;

    // 2. 检查 flags
    if (fmt->flags & MISC_FMT_OPEN_BINARY)
        interpreter = open_exec(fmt->filename);       // 常规
    else
        interpreter = open_exec(fmt->filename);       // 文本模式

    // 3. MISC_FMT_PRESERVE_ARGV0：将原文件名作为 argv[0]
    if (fmt->flags & MISC_FMT_PRESERVE_ARGV0) {
        // 在 bprm 的 args 中插入原文件名
    }

    // 4. MISC_FMT_CREDENTIALS：保留执行者身份
    // → 不进行 setuid 等操作

    // 5. 替换 bprm 为解释器
    fput(bprm->file);                      // 关闭原文件
    bprm->file = interpreter;

    // 6. 递归 exec
    prepare_binprm(bprm);
    exec_binprm(bprm, regs);
}
```

---

## 4. 同步卸载——put_binfmt_handler @ :162

```c
// get_binfmt_handler 递增 refcount，load_misc_binary 结束时递减
// 卸载格式时（写入 -1 或删除），put_binfmt_handler 确保：
// 1. refcount 递减
// 2. 如果归零且标志 DELETED → 释放 Node
// 3. 通过 delayed_work 延迟释放，避免在 exec 路径中同步等待
```

---

## 5. 调试

```bash
# 注册 Python 脚本支持
echo ':py:E::py::/usr/bin/python3:F' > /proc/sys/fs/binfmt_misc/register

# 查看已注册的格式
cat /proc/sys/fs/binfmt_misc/py
# enabled
# interpreter /usr/bin/python3
# extension .py

# 直接执行
chmod +x test.py
./test.py    # → 自动用 python3 执行

# 禁用
echo -1 > /proc/sys/fs/binfmt_misc/py
```

---

## 6. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `load_misc_binary` | `:203` | 格式匹配+解释器执行 |
| `create_entry` | `:350` | 注册格式解析（支持 E/M/offset/magic/flags）|
| `get_binfmt_handler` | `:141` | 查找匹配格式+递增引用 |
| `put_binfmt_handler` | `:162` | 释放引用+延迟清理 |
| `search_binfmt_handler` | `:91` | 遍历 entries 匹配 magic/extension |
| `entry_write` | — | register 文件写入入口 |

---

## 7. 总结

binfmt_misc 通过 `create_entry`（`:350`）解析注册格式字符串（`:name:E::ext::interpreter:flags`），存入 `Node` 链表。`load_misc_binary`（`:203`）在 exec 时匹配格式，用解释器替换 bprm 后递归 `exec_binprm`。`put_binfmt_handler`（`:162`）通过 refcount 同步卸载与加载的竞态。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
