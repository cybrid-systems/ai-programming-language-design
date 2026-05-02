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

## 6. 格式字符串解析——create_entry @ :350

```c
// 写入 register 的格式字符串：:name:type:offset:magic:mask:interpreter:flags
// create_entry() — 完整解析路径：

// 1. 分隔符检测（通常 :，支持自定义）
// 2. name 字段 → e->name（必须非空，不能是 . 或 ..）
// 3. type 字段：
//    'E' → extension（扩展名匹配，如 .py）
//    'M' → magic（文件头魔数匹配）
// 4. type='M' → offset 字段 + magic 字段
//    offset 可空（默认 0）
//    magic 支持 \x 转义（如 \x50\x4b 匹配 ZIP）
// 5. interpreter 字段（解释器绝对路径）
// 6. flags 字段：
//    'P' — preserve argv0（将原文件名作为 argv[0]）
//    'O' — open binary（以 O_BINARY 打开）
//    'C' — credentials（保留执行者凭据）
//    'F' — fix binary（固定二进制，不会受 setuid 影响）
```

## 7. 文件操作

```c
// /proc/sys/fs/binfmt_misc/ 下的文件操作：

// entry_read — 查看已注册的格式：
// → 显示格式名称、类型、magic/extension、解释器路径
// → 显示状态（enabled / disabled）

// entry_write — 注册新格式：
// → 解析格式字符串
// → 调用 create_entry() 创建 Node
// → 添加到 binfmt_misc 的 entries 链表
// → 在 debugfs 中创建条目文件

// 写入 -1 → 删除条目（禁用）
// 写入 0  → 临时禁用
// 写入 1  → 启用
```

## 8. 执行优先级

```c
// 内核处理 exec() 时的 binfmt 优先级：
// 1. binfmt_elf — ELF 可执行文件（优先级最高）
// 2. binfmt_misc — 杂项格式（注册的格式）
// 3. binfmt_script — #! 脚本（shebang）
// 4. binfmt_aout — a.out 格式（旧，已废弃）

// binfmt_misc 在 search_binary_handler() 中被调用
// → load_misc_binary() 处理匹配
// → 如果匹配失败 → 返回 -ENOEXEC → 尝试下一个 binfmt
```

## 9. 关键 doom-lsp 确认

```c
// fs/binfmt_misc.c 关键函数：
// create_entry @ :350        — 格式字符串解析
// load_misc_binary @ :203    — 格式匹配+解释器执行
// get_binfmt_handler @ :141  — 查找匹配格式
// put_binfmt_handler @ :162  — 释放引用
// entry_write                — 注册写入
// entry_read                 — 格式查看
```


## 10. MISC_FMT_OPEN_FILE——文件引用模式

```c
// MISC_FMT_OPEN_FILE 标志（5.x+ 新增）：
// 在 load_misc_binary @ :251 中：
// if (fmt->flags & MISC_FMT_OPEN_FILE) {
//     // 不执行解释器，而是直接打开文件
//     // 用于 FUSE 等文件系统需要文件描述符的场景
//     fd_install(new_fd, get_file(bprm->file));
//     return 0;
// }

// 此标志改变了 binfmt_misc 的传统行为——不是执行解释器
// 而是将匹配的文件 fd 传递给用户空间
```

## 11. 格式禁用与删除

```c
// 通过写入 register 文件控制条目：
// echo -1 > /proc/sys/fs/binfmt_misc/py   → 永久删除
// echo 0 > /proc/sys/fs/binfmt_misc/py    → 禁用
// echo 1 > /proc/sys/fs/binfmt_misc/py    → 重新启用

// 内核侧的删除路径：
// → entry_write() 检测输入为 -1
// → list_del(&e->list) 从链表移除
// → put_binfmt_handler(e) → refcount_dec → 延迟释放
// → 删除 debugfs 中的条目文件
```


## 12. sysctl 接口

```c
// binfmt_misc 的 sysctl 设置：
// fs.binfmt_misc.status — 全局启用/禁用
// fs.binfmt_misc.registered — 已注册的格式数

// register 文件位于 /proc/sys/fs/binfmt_misc/
// 挂载 procfs 后自动可用（无需额外模块参数）
```

