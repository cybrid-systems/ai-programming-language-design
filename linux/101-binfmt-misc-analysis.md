# 101-binfmt-misc — 二进制格式注册深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/binfmt_misc.c`）
> 工具： doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**binfmt_misc** 是 Linux 的可配置二进制格式处理程序，允许通过文件（通常是 `/proc/sys/fs/binfmt_misc/`）注册新的可执行格式，无需修改内核代码。Java bytecode、Python、Unity 等都依赖它。

---

## 1. 核心数据结构

### 1.1 struct binfmt_entry — 格式条目

```c
// fs/binfmt_misc.c — binfmt_entry
struct binfmt_entry {
    struct list_head        list;         // 链表
    unsigned long           aout_flags;    // 格式标志
    struct linux_binprm    *interp;       // 解释器

    // 匹配信息
    char                   *name;         // 格式名称（如 "Java"）
    size_t                  name_len;      // 名称长度
    u8                     offset;        // magic 偏移
    size_t                  size;          // magic 大小
    u8                     *magic;        // magic 字节序列
    u8                     *mask;         // mask（用于部分匹配）

    // 标志
    unsigned int           flags;
    //   E: enabled
    //   M: magic 匹配
    //   C: 置信（credential）
    //   P: 权限覆盖
    //   Q: SEGV 的 SIGQUIET 模式
    //   O: ONSIGHUP 的 open 模式
};
```

---

## 2. 注册流程

### 2.1 binfmt_misc_register — 注册格式

```c
// fs/binfmt_misc.c — binfmt_misc_register
int binfmt_misc_register(struct dentry *dentry)
{
    // 1. 创建 /proc/sys/fs/binfmt_misc/XXX 文件
    // 2. 分配 binfmt_entry
    // 3. 加入格式链表
    list_add(&entry->list, &entries);
}
```

### 2. 用户空间注册

```bash
# 格式：name offset magic mask interpreter flags
# 注册 Java bytecode：
echo ':Java:M::\xca\xfe\xba\xbe::/usr/bin/java:' > /proc/sys/fs/binfmt_misc/register

# 或者通过 mount：
mount -t binfmt_misc none /proc/sys/fs/binfmt_misc
echo ':Python:E::pyt#!::/usr/bin/python:' > /proc/sys/fs/binfmt_misc/register
```

---

## 3. 查找流程（load_misc_binary）

### 3.1 load_misc_binary — 加载二进制

```c
// fs/binfmt_misc.c — load_misc_binary
static int load_misc_binary(struct linux_binprm *bprm)
{
    struct binfmt_entry *e;
    bool found = false;

    // 1. 遍历所有注册的格式
    list_for_each_entry(e, &entries, list) {
        if (!test_bit(EFL_ENABLED, &e->flags))
            continue;

        // 2. 检查 magic 或 extension
        if (test_bit(EFL_BINARY, &e->flags)) {
            // magic 匹配
            if (match_magic(e, bprm->buf, bprm->binary))
                found = true;
        } else if (test_bit(EFL_EXTENSION, &e->flags)) {
            // 文件扩展名匹配
            if (match_extension(e, bprm->filename))
                found = true;
        }

        if (found)
            break;
    }

    if (!found)
        return -ENOEXEC;

    // 3. 调用解释器
    return search_binary_handler(bprm);
}
```

---

## 4. magic 匹配

### 4.1 match_magic

```c
// fs/binfmt_misc.c — match_magic
static bool match_magic(struct binfmt_entry *e, char *buf, size_t len)
{
    size_t off = e->offset;

    // 检查偏移范围
    if (off + e->size > len)
        return false;

    // 逐字节比较（带 mask）
    for (i = 0; i < e->size; i++) {
        if ((buf[off + i] & e->mask[i]) != e->magic[i])
            return false;
    }

    return true;
}
```

---

## 5. 使用示例

```bash
# 注册 Python 解释器：
echo ':Python:E::#!/*python*/::/usr/bin/python:' > /proc/sys/fs/binfmt_misc/register

# 查看已注册的格式：
ls /proc/sys/fs/binfmt_misc/

# 禁用：
echo -1 > /proc/sys/fs/binfmt_misc/python/status

# 删除：
echo -1 > /proc/sys/fs/binfmt_misc/python/register
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/binfmt_misc.c` | `struct binfmt_entry`、`load_misc_binary`、`match_magic` |

---

## 7. 西游记类比

**binfmt_misc** 就像"取经队伍的多语言翻译官"——

> 每种语言（Java、Python）都有自己的"语法规则"（binfmt_entry）。翻译官（binfmt_misc）根据文件头部的魔法字节（magic，如 Java 的 `\xCA\xFE\xBA\xBE`）识别这是什么语言。如果是 Java，就找 Java 翻译官（/usr/bin/java）来处理；如果是 Python，就找 Python 翻译官。最妙的是，这些翻译规则不需要改天庭的规矩（内核代码），只需要在公文栏（/proc/sys/fs/binfmt_misc/）登记就行了。

---

## 8. 关联文章

- **VFS**（article 19）：`linux_binprm` 和 `search_binary_handler`
- **exec**（相关）：二进制执行的通用路径