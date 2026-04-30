# Linux Kernel procfs / sysctl 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/proc/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. procfs 概述

**procfs** 是内核向用户空间导出**进程和系统信息**的虚拟文件系统，每个进程对应 `/proc/PID/`，系统信息对应 `/proc/sys/`。

---

## 1. 核心结构

```c
// fs/proc/internal.h — proc_dir_entry
struct proc_dir_entry {
    const char             *name;           // 目录/文件名称
    umode_t                mode;             // 权限模式
    const struct inode_operations *proc_iops;  // inode 操作
    const struct file_operations *proc_fops;   // 文件操作
    struct proc_dir_entry  **parent;        // 父目录
    struct rb_node          subdir_node;    // 子目录红黑树
    struct rb_root          subdir;          // 子目录树
    void                    *data;           // 私有数据
    int                     (*read_proc)(char *page, char **start, ...);
    int                     (*write_proc)(const char __user *buffer, ...);
    proc_write_t            write_proc;
};
```

---

## 2. /proc/PID/ 内存映射

```c
// fs/proc/task_mmu.c — show_numa_map()
struct vm_area_struct {
    unsigned long          vm_start;
    unsigned long          vm_end;
    struct file            *vm_file;       // 映射的文件（如果有）
    unsigned long          vm_pgoff;        // 页偏移
    struct anon_vma        *anon_vma;       // 匿名映射
    pgprot_t               vm_page_prot;    // 页保护
    unsigned long          vm_flags;        // VM_READ/VM_WRITE/VM_SHARED 等
};

// /proc/PID/maps — 格式：
// 00400000-00409000 r-xp 00000000 fd:00 123456 /bin/ls
//    vm_start - vm_end   mode   offset   device inode   pathname
```

---

## 3. sysctl — /proc/sys/

```c
// fs/proc/proc_sysctl.c — proc_sys_call_handler
int proc_sys_call_handler(...)
{
    // 1. 查找 sysctl 表
    struct ctl_table *table = lookup_sysctl_table(name, name_len);

    // 2. 读写处理
    if (write)
        result = proc_dointvec(table, write, buffer, lenp, ppos);
    else
        result = proc_dointvec(table, read, buffer, lenp, ppos);
}
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `fs/proc/base.c` | `/proc/PID/` 实现 |
| `fs/proc/task_mmu.c` | `/proc/PID/maps` |
| `fs/proc/proc_sysctl.c` | `/proc/sys/` 实现 |
