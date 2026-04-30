# Linux Kernel sysfs / uevent 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/sysfs/` + `lib/kobject_uevent.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 sysfs？

**sysfs** 是内核向用户空间**导出设备模型层次结构**的虚拟文件系统，每个 kobject 对应一个目录。

---

## 1. kobject 与 sysfs

```c
// fs/sysfs/file.c — sysfs_create_file
int sysfs_create_file(struct kobject *kobj, const struct attribute *attr)
{
    // 创建 /sys/devices/.../kobj/attr 文件
    // attr->show / attr->store 回调
}

// 示例：/sys/devices/system/cpu/cpu0/online
// show: 显示值
// store: 接收用户空间写入
```

---

## 2. uevent — 热插拔事件

```c
// lib/kobject_uevent.c — kobject_uevent
int kobject_uevent(struct kobject *kobj, enum kobject_action action)
{
    // 发送热插拔事件到用户空间（udev）
    char **envp;
    envp = kobject_uevent_env(kobj, action, NULL);

    // 通过 netlink 套接字发送到用户空间
    // udevd 接收并创建设备节点（/dev）
}
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `fs/sysfs/file.c` | `sysfs_create_file`、`sysfs_open_file` |
| `fs/sysfs/dir.c` | `sysfs_create_dir` |
| `lib/kobject_uevent.c` | `kobject_uevent`、`add_uevent_var` |
