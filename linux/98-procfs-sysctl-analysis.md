# 98-procfs-sysctl — Linux procfs 和 sysctl 子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**procfs**（`/proc`）是进程信息文件系统——读取时动态生成进程状态、内存映射等。**sysctl**（`/proc/sys/`）是内核运行时参数接口——通过 `struct ctl_table` 注册的键值对，通过红黑树管理目录条目。

**核心设计**：sysctl 使用红黑树（`rb_node`）管理 `/proc/sys/` 目录下的条目。注册时 `__register_sysctl_table()` → `insert_header()` 构建 `ctl_dir` → `ctl_node` 红黑树。读写时 `find_entry()` 在红黑树中搜索匹配的 `ctl_table` → 调用 `proc_handler`。

```
注册路径:
  register_sysctl("kernel/fs", table)
    → __register_sysctl_table()
      → insert_header() → 创建/查找 ctl_dir 目录节点
      → 逐行遍历 table[] → insert_entry()
        → 将 table 条目插入父目录的红黑树
    ↓
  /proc/sys/kernel/fs/xxx 可见

读写路径:
  open("/proc/sys/kernel/fs/xxx") → proc_sys_make_inode() 创建 inode
  read() → proc_sys_read()
    → find_entry() → 红黑树查找
    → table->proc_handler() → 读取内核变量
  write() → proc_sys_write()
    → find_entry() → proc_handler(write=1)
```

**doom-lsp 确认**：`fs/proc/proc_sysctl.c`（1,726 行，100 符号）。

---

## 1. 核心数据结构

### 1.1 struct ctl_table——sysctl 条目

```c
// include/linux/sysctl.h
struct ctl_table {
    const char *procname;                    // 文件名
    const char *data;                        // 内核变量地址
    int maxlen;                              // 最大长度
    umode_t mode;                             // 文件权限

    proc_handler *proc_handler;              // 读写处理函数
    struct ctl_table_poll *poll;

    // 内建 proc_handler：
    // proc_dostring     — 字符串
    // proc_dointvec     — int 数组
    // proc_doulongvec_minmax — unsigned long + 范围
    // proc_dobool       — 布尔
    // proc_dointvec_jiffies — jiffies
};
```

### 1.2 struct ctl_table_header——表头

```c
struct ctl_table_header {
    struct ctl_table *ctl_table;             // 条目数组
    struct ctl_node *node;                   // 红黑树节点数组
    struct ctl_table_root *root;
    struct ctl_table_set *set;
    struct ctl_dir *parent;                  // 父目录
    int count;
    int nreg;
};
```

### 1.3 红黑树目录结构

```c
// /proc/sys/ 的目录条目通过红黑树管理：
// struct ctl_dir { struct ctl_table_header h; ... };  // 目录=一种特殊的表头
// struct ctl_node { struct rb_node node; };            // 红黑树节点

// find_entry @ :113 — 红黑树查找：
static const struct ctl_table *find_entry(
    struct ctl_table_header **phead, struct ctl_dir *dir,
    const char *name, int namelen)
{
    struct rb_node *node = dir->h.node[0].node.rb_node;
    while (node) {
        ctl_node = rb_entry(node, struct ctl_node, node);
        // 通过 table->procname 匹配文件名
        cmp = namecmp(name, entry->procname, namelen);
        if (cmp < 0) node = node->rb_left;
        else if (cmp > 0) node = node->rb_right;
        else return entry;
    }
    return NULL;
}
```

---

## 2. 注册路径

```c
// register_sysctl("kernel", table)
// → __register_sysctl_sz(&sysctl_table_root, "kernel", table, ...)

struct ctl_table_header *__register_sysctl_table(
    struct ctl_table_root *root, const char *path, ...)
{
    // 1. 组装目录路径
    // "kernel/fs" → [kernel, fs]

    // 2. 遍历路径，创建或查找目录
    for (each component) {
        dir = find_dir(dir, component, false);
        if (!dir) dir = new_dir(dir, component);
    }

    // 3. insert_header() — 挂载表头到目录 @ :228
    // → link 到父目录

    // 4. insert_entry() — 逐个插入条目 @ :146
    // → 将 ctl_table 中的每个条目插入 dir 的红黑树
}
```

---

## 3. 读写路径

```c
// 用户读取 /proc/sys/kernel/hostname：
// → proc_sys_read(file, buf, len, ppos)
//   → find_entry() 红黑树查找
//   → table->proc_handler(table, 0, buf, lenp, ppos)
//   → proc_dostring():
//     → 从 table->data 读取字符串
//     → copy_to_user(user_buf, data, len)

// 用户写入：
// → proc_sys_write()
//   → find_entry()
//   → table->proc_handler(table, 1, buf, lenp, ppos)
//   → proc_dostring():
//     → copy_from_user(data, user_buf, len)
//     → 字符串存入内核变量

// proc_sys_make_inode() — 创建 sysctl 文件的 inode：
// → 在该次 open 时查找条目
// → 将 table->proc_handler 与 inode 关联
```

---

## 4. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `find_entry` | `:113` | 红黑树查找 sysctl 条目 |
| `insert_entry` | `:146` | 条目插入红黑树 |
| `insert_header` | `:228` | 表头挂载到目录 |
| `new_dir` | — | 创建 sysctl 目录 |
| `find_dir` | — | 查找 sysctl 目录 |
| `proc_sys_read` | — | sysctl 文件读取 |
| `proc_sys_write` | — | sysctl 文件写入 |
| `proc_sys_make_inode` | — | sysctl inode 创建 |

---

## 5. 调试

```bash
sysctl kernel.hostname
sysctl -w kernel.hostname=myhost
ls /proc/sys/kernel/
cat /proc/sys/kernel/panic
echo 10 > /proc/sys/kernel/panic
```

---

## 6. 总结

sysctl 通过 `find_entry`（`:113`，红黑树二分查找）定位 `/proc/sys/` 下的条目，读写通过 `proc_handler` 回调访问内核变量。注册通过 `__register_sysctl_table` → `insert_header`（`:228`）挂载表头 → `insert_entry`（`:146`）插入红黑树。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
