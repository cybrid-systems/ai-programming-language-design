# 097-procfs-sysctl — Linux procfs 和 sysctl 子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**sysctl**（`/proc/sys/`）是 Linux 内核参数运行时配置接口。内核模块通过 `register_sysctl()` 注册 `struct ctl_table` 到 `/proc/sys/` 目录树，用户通过文件读写或 `sysctl()` 系统调用访问。

**核心设计**：sysctl 使用**红黑树**（rb_tree）管理 `/proc/sys/` 下的目录结构。`find_entry`（`proc_sysctl.c:113`）在红黑树中二分查找匹配 `ctl_table` 条目，`insert_entry`（`:146`）将新条目插入红黑树。读写通过 `proc_handler` 回调访问内核变量。

```
注册路径:
  register_sysctl("kernel/pty", pty_table)
    → __register_sysctl_table()
      → insert_header() → 创建/查找 ctl_dir
      → for each table entry: insert_entry()
        → 在父目录红黑树中按名字排序插入

读写路径:
  open("/proc/sys/kernel/pty/max")
    → proc_sys_make_inode()
  read()
    → proc_sys_read() → find_entry() → 红黑树二分查找
    → table->proc_handler() → proc_dointvec() 等
  write()
    → proc_sys_write() → find_entry() → proc_handler(write=1)
```

**doom-lsp 确认**：`fs/proc/proc_sysctl.c`（1,726 行，100 符号）。`find_entry` @ `:113`，`insert_entry` @ `:146`。

---

## 1. 核心数据结构

### 1.1 struct ctl_table——sysctl 条目

```c
// include/linux/sysctl.h
struct ctl_table {
    const char *procname;            // 文件名（如 "hostname"、"max"）
    const char *data;                 // 内核变量地址
    int maxlen;                       // buffer 最大长度
    umode_t mode;                     // 文件权限

    proc_handler *proc_handler;       // 读写处理函数
    struct ctl_table_poll *poll;

    // 内建处理器：
    proc_dostring          — 字符串变量
    proc_dointvec          — int 数组
    proc_doulongvec_minmax — unsigned long + 范围约束
    proc_dobool            — 布尔值
    proc_dointvec_jiffies  — jiffies 值
};
```

### 1.2 struct ctl_table_header——表头

```c
struct ctl_table_header {
    struct ctl_table *ctl_table;       // 条目数组（最多 CTL_MAX_NAME 个）
    struct ctl_node *node;             // 红黑树节点数组（与 ctl_table 一一对应）
    struct ctl_table_root *root;
    struct ctl_table_set *set;
    struct ctl_dir *parent;            // 父目录指针
    int count;                         // 引用计数
    int nreg;
};
```

### 1.3 红黑树目录索引

```c
// 每个 /proc/sys/ 目录对应一个 struct ctl_dir——ctl_dir->root 是红黑树根
// struct ctl_node { struct rb_node node; };    // 红黑树节点
// struct ctl_dir  { struct ctl_table_header h; };

// find_entry @ :113——红黑树二分查找
// 按 procname 字符串比较定位
static const struct ctl_table *find_entry(
    struct ctl_table_header **phead, struct ctl_dir *dir,
    const char *name, int namelen)
{
    struct rb_node *node = dir->root.rb_node;

    while (node) {
        ctl_node = rb_entry(node, struct ctl_node, node);
        head = ctl_node->header;
        entry = &head->ctl_table[ctl_node - head->node];
        cmp = namecmp(name, namelen, entry->procname, strlen(entry->procname));
        if (cmp < 0)  node = node->rb_left;
        else if (cmp > 0) node = node->rb_right;
        else { *phead = head; return entry; }
    }
    return NULL;
}

// insert_entry @ :146——红黑树插入
// 按 procname 排序，namecmp 决定左右子树
static int insert_entry(struct ctl_table_header *head, const struct ctl_table *entry)
{
    struct rb_node **p = &head->parent->root.rb_node;
    // ... 标准红黑树插入
    rb_link_node(node, parent, p);
    rb_insert_color(node, &head->parent->root);
}
```

---

## 2. 注册路径——__register_sysctl_table

```c
// 内核模块注册 sysctl：
// register_sysctl("kernel/pty", pty_table)
// → __register_sysctl_sz(&sysctl_table_root, "kernel/pty", pty_table, ...)

// 内部流程：
// 1. 将 "kernel/pty" 按 '/' 分割为组件
// 2. 从 sysctl_table_root.default_set.dir 开始
//    → find_dir(dir, "kernel") 查找或创建 kernel 目录
//    → find_dir(dir, "pty")    查找或创建 pty 目录
// 3. insert_header() — 将新表挂载到 pty 目录下
// 4. for each entry in table[]:
//    → insert_entry() — 插入红黑树
```

---

## 3. 读写路径

### 3.1 proc_sys_read——读取

```c
// 用户读取 /proc/sys/kernel/pty/max：
// → proc_sys_read(file, buf, len, ppos)
//   → 1. sysctl_follow_link() → find_entry() 红黑树查找
//   → 2. table->proc_handler(table, 0, buffer, lenp, ppos)
//   → 3. 例如 proc_dostring():
//        → copy_to_user(user_buf, table->data, strlen(table->data))
```

### 3.2 proc_sys_write——写入

```c
// 用户写入 echo 100 > /proc/sys/kernel/pty/max
// → proc_sys_write()
//   → 1. find_entry() 红黑树查找
//   → 2. table->proc_handler(table, 1, buffer, lenp, ppos)
//   → 3. 例如 proc_dointvec():
//        → kstrtoint(user_buf, 0, &val) 解析整数
//        → *(int *)(table->data) = val 写入内核变量
```

---

## 4. 关键 sysctl 路径示例

```c
// /proc/sys/kernel/hostname → sysctl_table 指向 utsname()->nodename
static struct ctl_table kern_table[] = {
    {
        .procname   = "hostname",
        .data       = &init_uts_ns.name.nodename,
        .maxlen     = __NEW_UTS_LEN,
        .proc_handler = proc_dostring,
    },
    {
        .procname   = "panic",
        .data       = &panic_timeout,
        .maxlen     = sizeof(int),
        .proc_handler = proc_dointvec,
    },
};
```

---

## 5. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `find_entry` | `:113` | 红黑树二分查找 sysctl 条目 |
| `insert_entry` | `:146` | 红黑树插入 sysctl 条目 |
| `insert_header` | `:228` | 表头注册到目录 |
| `namecmp` | `:103` | 条目名称比较函数 |
| `new_dir` | — | 创建 sysctl 目录 |
| `find_dir` | — | 查找 sysctl 目录 |
| `__register_sysctl_table` | — | 注册入口 |

---

## 6. 调试

```bash
# sysctl 操作
sysctl kernel.hostname
sysctl -w kernel.hostname=myhost
sysctl -a | grep kernel

# /proc/sys 文件
cat /proc/sys/kernel/panic
echo 10 > /proc/sys/kernel/panic

# 查看所有 sysctl 文件树
find /proc/sys/ -type f | head -20
```

---

## 7. 文件操作表

```c
// /proc/sys/ 文件的 file_operations：
static const struct proc_ops proc_sys_file_operations = {
    .proc_read     = proc_sys_read,
    .proc_write    = proc_sys_write,
    .proc_poll     = proc_sys_poll,
    .proc_ioctl    = proc_sys_ioctl,
    .proc_mmap     = proc_sys_mmap,
};

// 目录操作：
static const struct proc_ops proc_sys_dir_file_operations = {
    .proc_read     = proc_sys_readdir,
    .proc_iterate  = proc_sys_readdir,
    .proc_llseek   = default_llseek,
};
```

## 8. proc_sys_make_inode——inode 创建

```c
// 每次 open /proc/sys/kernel/xxx 时调用
// → proc_sys_make_inode(sb, head, entry)
//   → new_inode(sb) + inode->i_ino = get_next_ino()
//   → inode->i_mtime = current_time(inode)
//   → inode->i_mode = entry->mode | S_IFREG (或 S_IFDIR)
//   → inode->i_private = (void *)entry (用于 proc_sys_read/write 查找)
```

## 9. 常用 sysctl 表注册示例

```c
// kernel/sysctl.c 中的注册：
static struct ctl_table kern_table[] = {
    {
        .procname   = "hostname",
        .data       = &init_uts_ns.name.nodename,
        .maxlen     = __NEW_UTS_LEN,
        .proc_handler = proc_dostring,
    },
    {
        .procname   = "panic",
        .data       = &panic_timeout,
        .maxlen     = sizeof(int),
        .proc_handler = proc_dointvec,
    },
};
register_sysctl("kernel", kern_table);
```

## 10. 总结

sysctl 通过红黑树管理 `/proc/sys/` 目录结构——`find_entry`（`:113`）二分查找、`insert_entry`（`:146`）排序插入。`proc_sys_make_inode` 创建 inode，`proc_sys_read`/`write` 通过 `proc_handler` 回调访问内核变量。`register_sysctl` → `__register_sysctl_table` → `insert_header` + 逐条目 `insert_entry` 注册键值对。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 11. sysctl 热插拔注册

```c
// 动态加载模块时的 sysctl 注册：
// 模块 init → register_sysctl("net/ipv4", ipv4_table)
// → __register_sysctl_table() → insert_header()
// → 在 /proc/sys/net/ipv4/ 下创建文件

// 模块 exit → unregister_sysctl_table(header)
// → erase_header() → 从红黑树移除条目
// → 删除 /proc/sys/ 下的对应文件

// 常用注册位置：
// kernel/sysctl.c   — kernel.*  (kernel.hostname, kernel.panic)
// net/sysctl_net.c  — net.*     (net.ipv4.tcp_syncookies)
// fs/proc/proc_sysctl.c — vm.* (vm.dirty_ratio, vm.swappiness)
```

## 12. sysctl 目录树管理

```c
// /proc/sys/ 下的目录树通过 sysctl_lock 保护：

// insert_links @ :93 — 插入目录链接：
// → 在父目录的 dentry 树中创建符号链接
// → 支持同一个 sysctl 表在多个路径下可见

// put_links @ :94 — 移除链接：
// → unregister_sysctl_table 时调用
// → 清理所有相关符号链接

// erase_entry @ :185 — 从红黑树删除条目：
// → rb_erase(&node->node, &dir->root)
// → 释放 ctl_node 和 ctl_table_header

// drop_sysctl_table @ :90 — 释放表头：
// → refcount 归零时释放
// → 递归向上清理父目录（如果父目录空）
```

## 13. sysctl 的目录操作

```c
// /proc/sys 的目录文件操作：
// var proc_sys_dir_file_operations @ :30
// → .proc_iterate = proc_sys_readdir
// → 遍历 sysctl 目录红黑树

// var proc_sys_dir_operations @ :31
// → .proc_lookup = proc_sys_lookup
// → 在红黑树中按名称查找

// var proc_sys_dentry_operations @ :27
// → dentry 操作（用于路径解析）

// sysctl 的 inode 操作：
// var proc_sys_inode_operations @ :29
// → .permission — 权限检查
// → .getattr — 获取属性
```

## 14. proc_sys_poll_notify @ :62

```c
// sysctl 文件支持 poll（epoll 监听变化）：
// proc_sys_poll_notify(struct ctl_table_poll *poll)
// → poll_wait(file, &poll->wait, pt)
// → 值变化时 wake_up(&poll->wait)

// 使用场景：
// → 监控内核参数变化
// → 不频繁轮询 /proc/sys/ 文件
// → 通过 epoll 等待参数变化通知
```

## 15. 关键函数索引

| 函数 | 符号 | 作用 |
|------|------|------|
| `proc_sysctl.c` | 100 | sysctl 文件系统 |
| `find_entry` | `:113` | 红黑树二分查找 |
| `insert_entry` | `:146` | 红黑树插入 |
| `erase_entry` | `:185` | 红黑树删除 |
| `insert_links` | `:93` | 目录链接插入 |
| `put_links` | `:94` | 目录链接移除 |
| `drop_sysctl_table` | `:90` | 表头释放 |
| `proc_sys_poll_notify` | `:62` | 文件变化通知 |


## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct proc_dir_entry` | include/linux/proc_fs.h | 核心 |
| `proc_create()` | fs/proc/generic.c | 创建 proc 文件 |
| `struct ctl_table` | include/linux/sysctl.h | 核心 |
| `register_sysctl()` | fs/proc/proc_sysctl.c | 注册 sysctl |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
