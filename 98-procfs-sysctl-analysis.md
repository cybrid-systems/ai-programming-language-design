# procfs / sysctl — 进程文件系统与系统控制深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/proc/` + `kernel/sysctl.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**procfs** 在 `/proc` 中提供内核和进程信息接口，**sysctl** 通过 `/proc/sys` 允许运行时调整内核参数。

---

## 1. procfs 结构

### 1.1 proc_dir_entry — proc 目录项

```c
// fs/proc/internal.h — proc_dir_entry
struct proc_dir_entry {
    unsigned int            low_ino;           // inode 号
    const char             *name;              // 名称
    umode_t                mode;               // 权限
    const struct inode_operations *proc_iops; // inode 操作
    const struct file_operations *proc_fops; // 文件操作

    // 链表
    struct proc_dir_entry  *parent;           // 父目录
    struct rb_node          subdir_node;      // 子目录红黑树
    struct list_head        subdir_list;       // 子链表

    // 数据
    void                   *data;             // 私有数据
    read_proc_t            *read_proc;         // 读取函数（旧 API）
    write_proc_t           *write_proc;       // 写入函数（旧 API）
};
```

---

## 2. proc 文件读取

### 2.1 single_open — 单次打开读取

```c
// fs/proc/generic.c — single_open
int single_open(struct file *file, int (*show)(struct seq_file *, void *), void *data)
{
    // 1. 分配 seq_file
    struct seq_file *seq = __seq_open(file, &single_seq_ops, sizeof(*seq));

    // 2. 调用 show 填充内容
    seq->private = data;
    show(seq, data);

    return 0;
}
```

### 2.2 seq_show — 序列文件输出

```c
// lib/seq_file.c — seq_printf
int seq_printf(struct seq_file *m, const char *fmt, ...)
{
    // 将格式化的字符串写入 seq_file 缓冲区
    // 最终输出到用户空间
}
```

---

## 3. sysctl — 内核参数

### 3.1 sysctl_init — sysctl 初始化

```c
// kernel/sysctl.c — sysctl_init
static int __init sysctl_init(void)
{
    // 1. 创建 /proc/sys 目录
    proc_sys_root = proc_mkdir("sys", NULL);

    // 2. 注册 sysctl 表
    register_sysctl_paths(sysctl_base_table, default_table);

    return 0;
}
```

### 3.2 sysctl proc handler

```c
// kernel/sysctl.c — proc_dointvec_minmax
int proc_dointvec_minmax(struct ctl_table *table, int write,
                          void *buffer, size_t *lenp, loff_t *ppos)
{
    // 读取或写入整数向量
    // write=0: 读取内核值到 buffer
    // write=1: 从 buffer 写入内核值

    // table->data：指向内核变量
    // table->maxval / table->minval：范围限制

    return proc_int_vec(table, write, buffer, lenp, ppos);
}
```

---

## 4. 常用 /proc 接口

```
/proc/cpuinfo           ← CPU 信息
/proc/meminfo          ← 内存统计
/proc/loadavg          ← 系统负载
/proc/uptime           ← 运行时间
/proc/PID/cmdline      ← 进程命令行
/proc/PID/maps         ← 内存映射
/proc/PID/status       ← 进程状态
/proc/PID/fd/          ← 文件描述符
/proc/sys/             ← 可调参数
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/proc/generic.c` | `single_open` |
| `fs/proc/internal.h` | `proc_dir_entry` |
| `kernel/sysctl.c` | `proc_dointvec_minmax`、`sysctl_init` |
| `lib/seq_file.c` | `seq_printf` |