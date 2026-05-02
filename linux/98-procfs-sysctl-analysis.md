# 98-procfs-sysctl — Linux procfs 和 sysctl 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**procfs**（`/proc`）是 Linux 的进程信息文件系统，提供进程状态、内存映射、文件描述符等信息的视图。**sysctl**（`/proc/sys` 和 `sysctl` 系统调用）是内核参数运行时配置接口——通过 `struct ctl_table` 注册键值对，用户通过 `/proc/sys/` 文件或 `sysctl()` 系统调用读写。

**核心设计**：procfs 通过 `proc_fops`（`fs/proc/inode.c`）在读取时调用进程信息生成函数。sysctl 通过 `__register_sysctl_table()` 将 `struct ctl_table` 注册到 `/proc/sys/` 目录树，每次读写通过 `proc_sys_write`/`proc_sys_read` 调用 `ctl_table->proc_handler`。

```
sysctl 结构：
  register_sysctl("kernel", table) @ proc_sysctl.c
    ↓
  __register_sysctl_table() → 创建 ctl_table_header + ctl_dir
    ↓
  /proc/sys/kernel/ 目录

用户读 /proc/sys/kernel/hostname:
  → proc_sys_read() → sysctl_follow_link() → find_entry()
    → table->proc_handler(proc_dostring, ...)
    → copy_to_user()

用户写:
  → proc_sys_write() → find_entry() → proc_handler(proc_dostring, ...)
```

**doom-lsp 确认**：sysctl @ `fs/proc/proc_sysctl.c`（1,726 行，100 符号）。`include/linux/sysctl.h`（311 行）。

---

## 1. 核心数据结构

### 1.1 struct ctl_table——sysctl 条目

```c
// include/linux/sysctl.h
struct ctl_table {
    const char *procname;                    // 文件名（如 "hostname"）
    const char *data;                        // 内核变量地址
    int maxlen;                              // 数据最大长度
    umode_t mode;                            // 文件权限

    proc_handler *proc_handler;              // 读写处理函数
    struct ctl_table_poll *poll;

    // 内建 proc_handler：
    // proc_dostring     — 字符串
    // proc_dointvec     — 整数数组
    // proc_doulongvec_minmax — long 数组+范围
    // proc_dobool       — 布尔
};
```

### 1.2 struct ctl_table_header——sysctl 表头

```c
struct ctl_table_header {
    struct ctl_table *ctl_table;             // 条目数组
    struct ctl_node *node;
    struct ctl_table_root *root;
    struct ctl_table_set *set;
    struct ctl_dir *parent;                  // 父目录
    int count;                                // 引用计数
};
```

**doom-lsp 确认**：`struct ctl_table` 在 `sysctl.h`，`proc_sys_read`/`write` 在 `proc_sysctl.c`。

---

## 2. 注册路径——__register_sysctl_table

```c
// 内核代码注册 sysctl 参数：
// register_sysctl("kernel", table)
// → __register_sysctl_table(&sysctl_table_root, "kernel", table, ...)
//   → 1. insert_header() — 创建 ctl_table_header
//   → 2. insert_entry() — 逐个插入条目 @ :146
//     → find_entry() 定位父目录
//     → 创建 sysfs dentry
//   → 3. 注册完成的表在 /proc/sys/kernel/xxx 可见
```

---

## 3. 读写路径

### 3.1 proc_sys_read @ :read 路径

```c
// 用户读取 /proc/sys/kernel/xxx
// → proc_sys_read() → sysctl_follow_link() → find_entry()
// → table->proc_handler(table, write=0, buffer, lenp, ppos)
// → 例如 proc_dostring():
//     → 从 data 指针读取字符串
//     → copy_to_user(user_buf, data, len)

// proc_sys_write:
// → find_entry() 定位条目
// → table->proc_handler(table, write=1, buffer, lenp, ppos)
// → proc_dostring:
//     → copy_from_user(data, user_buf, len)
//     → 写入内核变量
```

### 3.2 find_entry @ :113——sysctl 查找

```c
static const struct ctl_table *find_entry(struct ctl_table_header **phead,
    struct ctl_dir *dir, const char *name, int namelen)
{
    // 1. 遍历目录中的条目
    // 2. namecmp(name, entry->procname) 匹配文件名
    // 3. 如果找到 → 返回条目
    // 4. 如果是目录 → 递归查找
}
```

---

## 4. procfs 进程信息

```c
// /proc/<pid>/ 文件：
// status → proc_pid_status() 读取进程状态
// maps  → proc_pid_maps() 读取 VMA
// fd/   → proc_fd_link() 读取符号链接

// /proc/self/ → 指向当前进程的 proc 条目

// 核心 proc 操作表：
static const struct proc_ops proc_pid_operations = {
    .proc_open   = proc_single_open,   // 打开
    .proc_read   = seq_read,           // 读取
    .proc_write  = proc_pid_write,     // 写入
    .proc_release = single_release,    // 关闭
};
```

---

## 5. 调试

```bash
# sysctl 操作
sysctl kernel.hostname
sysctl -w kernel.hostname=myhost

cat /proc/sys/kernel/hostname

# 查看所有 sysctl
sysctl -a | grep kernel

# /proc 信息
cat /proc/self/status
cat /proc/self/maps
ls -la /proc/self/fd/
```

---

## 6. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `__register_sysctl_table` | — | 注册 sysctl 表 |
| `find_entry` | `:113` | sysctl 条目查找 |
| `insert_entry` | `:146` | sysctl 条目插入 |
| `proc_sys_read` | — | sysctl 读取 |
| `proc_sys_write` | — | sysctl 写入 |

---

## 7. 总结

sysctl 通过 `__register_sysctl_table` → `insert_entry`（`:146`）将 `struct ctl_table` 注册到 `/proc/sys/` 目录树。读写通过 `find_entry`（`:113`）定位条目后调用 `proc_handler`。procfs 通过 `proc_pid_operations` 在读取时动态生成进程信息。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
