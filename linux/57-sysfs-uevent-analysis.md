# sysfs / uevent — 设备属性与热插拔通知深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/sysfs/` + `lib/kobject_uevent.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**sysfs** 在 `/sys` 中导出内核对象层级结构，每个 kobject 对应一个目录。**uevent** 在设备添加/移除时发送热插拔通知到用户空间。

---

## 1. 核心数据结构

### 1.1 sysfs_dirent — sysfs 节点

```c
// fs/sysfs/sysfs.h — sysfs_dirent
struct sysfs_dirent {
    atomic_t                s_count;       // 引用计数
    atomic_t                s_active;      // 活跃引用计数
    struct sysfs_dirent    *s_parent;      // 父节点
    const char              *s_name;        // 名称

    // 类型
    unsigned short          s_mode;        // 文件模式
    union {
        struct bin_attribute *bin;          // 二进制属性
        struct attribute     *attr;         // 普通属性
        struct sysfs_elem_dir   *dir;       // 目录
        struct sysfs_elem_symlink *symlink; // 符号链接
    };

    // 子节点
    struct rb_root          s_children;     // 子节点红黑树
    struct list_head        s_sibling;      // 兄弟节点链表

    // namespace
    const void             *ns;
};
```

### 1.2 attribute — sysfs 属性

```c
// include/linux/sysfs.h — attribute
struct attribute {
    const char              *name;         // 属性名
    umode_t                 mode;         // 权限（S_IRUGO 等）
    ssize_t (*show)(struct kobject *, struct attribute *, char *);
    ssize_t (*store)(struct kobject *, const char *, size_t);
};
```

### 1.3 kobject_uevent — uevent 环境

```c
// lib/kobject_uevent.c — kobject_uevent
struct kobject_uevent_env {
    char                    *envp[UEVENT_ENVP_SIZE]; // 环境变量数组
    int                     envp_idx;                  // 当前索引
    char                    *argv[3];                  // argv
    char                    *buf;                      // 缓冲
    int                     buflen;                    // 缓冲长度
};
```

---

## 2. sysfs 写入流程

### 2.1 sysfs_ops — show/store 操作

```c
// fs/sysfs/file.c — sysfs_file_ops
static const struct sysfs_ops sysfs_file_ops = {
    .show   = sysfs_attr_show,
    .store  = sysfs_attr_store,
};

// fs/sysfs/file.c — sysfs_attr_show
static ssize_t sysfs_attr_show(struct kobject *kobj, struct attribute *attr,
                                char *buf)
{
    struct sysfs_ops *ops = kobj->ktype->sysfs_ops;

    // 调用驱动的 show 函数
    return ops->show(kobj, attr, buf);
}

// fs/sysfs/file.c — sysfs_attr_store
static ssize_t sysfs_attr_store(struct kobject *kobj, struct attribute *attr,
                                 const char *buf, size_t count)
{
    struct sysfs_ops *ops = kobj->ktype->sysfs_ops;

    // 调用驱动的 store 函数
    return ops->store(kobj, attr, buf, count);
}
```

---

## 3. uevent 发送流程

### 3.1 kobject_uevent — 发送 uevent

```c
// lib/kobject_uevent.c — kobject_uevent
int kobject_uevent(struct kobject *kobj, enum kobject_action action)
{
    struct kobject_uevent_env *env;

    // 1. 分配环境变量
    env = kzalloc(sizeof(*env), GFP_KERNEL);

    // 2. 添加默认环境变量
    add_uevent_var(env, "ACTION=%s", kobject_actions[action]);
    add_uevent_var(env, "DEVPATH=%s", kobj->path);
    add_uevent_var(env, "SEQNUM=%llu", ++uevent_seqnum);

    // 3. 触发 netlink 套接字
    if (uevent_sock)
        send_uevent_netlink(env);

    // 4. 调用 uevent_ops（如果有）
    if (kobj->kset && kobj->kset->uevent_ops)
        kobj->kset->uevent_ops->uevent(kobj, env);

    kfree(env);

    return 0;
}
```

### 3.2 用户空间接收

```c
// 用户空间（udev）：
// 1. 打开 netlink 套接字（类型=SOCK_DGRAM，协议=NETLINK_KOBJECT_UEVENT）
// 2. 绑定到 netlink 组（1<<2）
// 3. recv() 接收 uevent 消息
// 4. 解析环境变量，创建设备节点（/dev/）

// /dev/null 的 uevent 示例：
// ACTION=add
// DEVPATH=/devices/pci0000:00/0000:00:1f.2/ata1/host0/target0:0:0/0:0:0:0
// SUBSYSTEM=block
// DEVNAME=sda
```

---

## 4. 属性文件创建

### 4.1 sysfs_create_file — 创建属性

```c
// fs/sysfs/file.c — sysfs_create_file
int sysfs_create_file(struct kobject *kobj, const struct attribute *attr)
{
    struct sysfs_dirent *sd;

    // 1. 创建 sysfs_dirent
    sd = sysfs_new_dirent(kobj->sd, attr->name, mode, SYSFS_FILE);

    // 2. 设置 attribute 指针
    sd->s_attr.attr = attr;

    // 3. 加入父目录的红黑树
    sysfs_add_one(sd, kobj->sd);

    return 0;
}
```

---

## 5. uevent 过滤

```c
// lib/kobject_uevent.c — kobject_uevent_env
static int kobject_uevent_env(struct kobject *kobj, enum kobject_action action,
                              char *envp[])
{
    // 过滤：检查 uevent_suppress
    if (kobj->uevent_suppress)
        return 0;

    // 过滤：检查 kset uevent_ops filter
    if (kobj->kset && kobj->kset->uevent_ops &&
        kobj->kset->uevent_ops->filter) {
        if (!kset->uevent_ops->filter(kobj))
            return 0;
    }

    // 发送 uevent
}
```

---

## 6. /sys 目录结构

```
/sys/
├── block/                ← 块设备
├── bus/                 ← 总线类型（pci, usb, ...）
├── class/               ← 设备类（net, block, tty, ...）
├── devices/             ← 设备树（拓扑）
├── firmware/           ← 固件信息
├── fs/                  ← 文件系统（如 devpts）
├── kernel/             ← 内核配置（如 debug）
└── module/             ← 已加载模块
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/sysfs/sysfs.h` | `struct sysfs_dirent` |
| `fs/sysfs/file.c` | `sysfs_attr_show/store`、`sysfs_create_file` |
| `lib/kobject_uevent.c` | `kobject_uevent`、`send_uevent_netlink` |
| `include/linux/sysfs.h` | `struct attribute` |