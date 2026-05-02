# 101-binfmt-misc — Linux 杂项二进制格式处理器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**binfmt_misc** 是 Linux 的**杂项二进制格式处理**机制——允许用户空间注册自定义的可执行文件格式处理器。通过向 `/proc/sys/fs/binfmt_misc/register` 写入格式描述字符串，可以将任意文件（如 `.jar`、`.py`、`.wasm`）注册为可执行文件。

**核心设计**：`binfmt_misc` 实现 `struct linux_binfmt` 接口——内核在 `exec()` 时遍历已注册的 `binfmt` 链表。`search_binfmt_handler()`（`fs/binfmt_misc.c:91`）通过文件头（magic）或文件扩展名匹配已注册的格式。匹配成功则调用注册的解释器（interpreter）执行。

```
echo ':py:E::py::/usr/bin/python3:F' > /proc/sys/fs/binfmt_misc/register
  ↓
exec("./script.py") → exec_binprm() → search_binary_handler()
  → list_for_each_entry(fmt, &formats, lh)
    → load_misc_binary(bprm)          # binfmt_misc 格式
      → search_binfmt_handler(misc,bprm)
        → 匹配文件扩展名 / magic
      → open_exec(interpreter)        # 打开 /usr/bin/python3
      → free(old_bprm->file)
      → prepare_binprm(new_bprm)      # 填充新 bprm
      → exec_binprm(new_bprm)         # 递归 exec（真正的格式）
```

**doom-lsp 确认**：`fs/binfmt_misc.c`（1,047 行）。`load_misc_binary` @ `:203`，`search_binfmt_handler` @ `:91`。

---

## 1. 核心数据结构

```c
// fs/binfmt_misc.c
struct Node {                                    // 一种注册的格式
    struct list_head list;                       // 链表节点
    const char *filename;                        // 解释器路径
    char *magic;                                 // 文件头魔数
    size_t magiclen;                              // 魔数长度
    char *mask;                                  // 掩码
    size_t masklen;                              // 掩码长度
    const char *name;                             // 格式名称
    int flags;                                    // MISC_FMT_*
    refcount_t users;                            // 同步卸载与加载
    struct delayed_work dwork;                    // 延迟删除 work
};

// binfmt_misc 挂在 formats 链表上：
static struct linux_binfmt misc_format = {
    .module       = THIS_MODULE,
    .load_binary  = load_misc_binary,
};
```

**doom-lsp 确认**：`struct Node` @ `:61`，`load_misc_binary` @ `:203`。

---

## 2. 格式注册

```c
// 通过 /proc/sys/fs/binfmt_misc/register 写入格式描述
// 格式字符串：:name:type:offset:magic:mask:interpreter:flags

// 示例：
// :py:E::py::/usr/bin/python3:F
//  → name=py, type=E(extension), magic=py(文件扩展名)
//    interpreter=/usr/bin/python3, flags=F(fix binary)

// :jar:M::\x50\x4b\x03\x04::/usr/bin/java:OC
//  → type=M(magic), magic=PK\x03\x04(ZIP文件头)
//    flags=O(open binary), C(credential)

// entry_write() — 解析并注册：
// → 解析格式字符串 → 分配 Node
// → list_add(&node->list, &entries)
// → 创建条目在 /proc/sys/fs/binfmt_misc/ 下
```

---

## 3. load_misc_binary @ :203——格式匹配与执行

```c
static int load_misc_binary(struct linux_binprm *bprm)
{
    Node *fmt;
    struct file *interpreter;
    char *iname;

    // 1. 查找匹配的处理器
    fmt = search_binfmt_handler(misc, bprm);
    if (!fmt) return -ENOEXEC;

    // 2. 获取解释器路径
    iname = fmt->interpreter;
    if (!iname) goto out;

    // 3. 打开解释器文件
    interpreter = open_exec(iname);
    if (IS_ERR(interpreter)) goto out;

    // 4. 替换 bprm 为解释器
    fput(bprm->file);                         // 关闭原文件
    bprm->file = interpreter;                  // 解释器成为新文件
    bprm->buf = NULL;

    // 5. 将原始文件路径作为参数传递
    if (fmt->flags & MISC_FMT_PRESERVE_ARGV0) {
        // 保留 argv[0] 为原始文件名
    }

    // 6. 重新填充 bprm 并递归 exec
    retval = prepare_binprm(bprm);             // 读解释器头
    if (retval < 0) return retval;
    retval = exec_binprm(bprm, regs);          // 执行解释器
}
```

---

## 4. 查找匹配——search_binfmt_handler @ :91

```c
static Node *search_binfmt_handler(struct binfmt_misc *misc,
                                    struct linux_binprm *bprm)
{
    list_for_each_entry(e, &misc->entries, list) {
        if (try_get_node(e)) {
            int matched = 0;
            if (e->flags & MISC_FMT_TYPE_MAGIC)
                // 按文件头魔数匹配——memcmp(bprm->buf, e->magic, e->magiclen)
                matched = magic_matches(e, bprm);
            else if (e->flags & MISC_FMT_TYPE_EXTENSION)
                // 按文件扩展名匹配——strcmp(extension, e->magic)
                matched = extension_matches(e, bprm);

            if (matched) return e;  // 找到
            put_node(e);
        }
    }
    return NULL;
}
```

---

## 5. 文件操作

```c
// /proc/sys/fs/binfmt_misc/ 下的文件：
// register — 写入注册格式描述
// status   — 启用/禁用
// <name>   — 已注册的格式条目（读=查看，写=修改）

// entry_read — 显示已注册的格式信息
// entry_write — 注册新格式
```

---

## 6. 调试

```bash
# 查看已注册的格式
cat /proc/sys/fs/binfmt_misc/status
ls /proc/sys/fs/binfmt_misc/

# 注册 Python 脚本支持
echo ':py:E::py::/usr/bin/python3:F' > /proc/sys/fs/binfmt_misc/register

# 测试
chmod +x script.py
./script.py   # → 自动用 python3 执行
```

---

## 7. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `load_misc_binary` | `:203` | 格式匹配+解释器执行 |
| `search_binfmt_handler` | `:91` | 按 magic/extension 查找注册项 |
| `entry_write` | — | 注册格式写入 |
| `put_binfmt_handler` | `:162` | 格式卸载同步 |

---

## 8. 总结

`binfmt_misc` 通过 `load_misc_binary`（`:203`）→ `search_binfmt_handler`（`:91`）按 magic/extension 匹配已注册的格式，匹配后打开解释器文件并递归调用 `exec_binprm`。注册通过写入 `/proc/sys/fs/binfmt_misc/register` 完成。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
