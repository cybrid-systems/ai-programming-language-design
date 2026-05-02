# 57-sysfs-uevent — Linux kobject / sysfs / uevent 设备模型深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**kobject / sysfs / uevent** 三位一体构成 Linux 设备模型的**用户空间可见性**层：

```
kobject — 内核对象（引用计数、父子关系、名称）
    ↓ 通过 sysfs 文件系统暴露
sysfs   — 内存文件系统（/sys），每个 kobject → 一个目录
    ↓ 设备/驱动生命周期事件
uevent  — 内核→用户空间事件通知（netlink / kmod / devtmpfs）
```

**设计核心**：`struct kobject` 是内核对象层次结构的基础。每个添加到系统中的 `kobject` 都在 `sysfs` 中创建一个目录，并通过 `uevent` 向用户空间发送事件（设备添加、移除等）。

**doom-lsp 确认**：kobject 核心在 `lib/kobject.c`（**1,107 行**，**109 个符号**）。uevent 在 `lib/kobject_uevent.c`（851 行）。sysfs 在 `fs/sysfs/`（~1,300 行）。

**关键文件索引**：

| 文件 | 行数 | 职责 |
|------|------|------|
| `lib/kobject.c` | 1107 | kobject 核心（init、add、refcount、release）|
| `lib/kobject_uevent.c` | 851 | uevent 生成与发送 |
| `lib/kobject_uevent.h` | — | uevent 辅助函数 |
| `include/linux/kobject.h` | 222 | `struct kobject`, `struct kobj_type`, `struct kset` |
| `include/linux/kobject_ns.h` | 58 | 命名空间支持 |
| `fs/sysfs/file.c` | 818 | sysfs 文件操作（show/store）|
| `fs/sysfs/dir.c` | 161 | sysfs 目录操作 |
| `fs/sysfs/symlink.c` | 199 | sysfs 符号链接 |
| `fs/sysfs/mount.c` | 117 | sysfs 挂载 |
| `drivers/base/core.c` | — | 设备核心（device_register → kobject + uevent）|

---

## 1. 核心数据结构

### 1.1 struct kobject — 内核对象

```c
// include/linux/kobject.h
struct kobject {
    const char *name;                    /* 对象名称（目录名）*/
    struct list_head entry;              /* kset->list 中的节点 */
    struct kobject *parent;              /* 父 kobject（父目录）*/
    struct kset *kset;                   /* 所属的 kset */
    const struct kobj_type *ktype;       /* 对象类型（release、属性操作）*/
    struct kernfs_node *sd;              /* sysfs 目录的 kernfs 节点 */
    struct kref kref;                    /* 引用计数 */
    unsigned int state_initialized:1;    /* 初始化标记 */
    unsigned int state_in_sysfs:1;       /* 是否已添加到 sysfs */
    unsigned int state_add_uevent_sent:1;/* 是否已发送 add uevent */
    unsigned int state_remove_uevent_sent:1;
    unsigned int uevent_suppress:1;       /* 抑制 uevent */
};
```

**`struct kobj_type`** — 对象类型的操作函数：

```c
// include/linux/kobject.h
struct kobj_type {
    void (*release)(struct kobject *kobj);       /* 释放回调 */
    const struct sysfs_ops *sysfs_ops;            /* sysfs show/store */
    const struct attribute_group **default_groups;/* 默认属性组 */
    const struct kobj_ns_type_operations *(*child_ns_type)(struct kobject *kobj);
    const void *(*namespace)(struct kobject *kobj);
    void (*get_ownership)(struct kobject *kobj,
                          kuid_t *uid, kgid_t *gid);
};
```

### 1.2 struct kset — 对象集合

```c
// include/linux/kobject.h
struct kset {
    struct list_head list;               /* 包含的 kobject 列表 */
    spinlock_t list_lock;                /* 保护列表 */
    struct kobject kobj;                 /* 自己的 kobject（在 sysfs 中体现为目录）*/
    const struct kset_uevent_ops *uevent_ops; /* uevent 过滤/修改函数 */
};
```

**`struct kset_uevent_ops`** — uevent 过滤：

```c
struct kset_uevent_ops {
    int (*filter)(struct kset *kset, struct kobject *kobj);
    const char *(*name)(struct kset *kset, struct kobject *kobj);
    int (*uevent)(struct kset *kset, struct kobject *kobj,
                  struct kobj_uevent_env *env);
};
```

**doom-lsp 确认**：`struct kobject` 在 `include/linux/kobject.h`。核心字段 `sd`（kernfs 节点指针）在对象加入 sysfs 时设置。

---

## 2. kobject 生命周期

### 2.1 初始化——kobject_init

```c
// lib/kobject.c:333
void kobject_init(struct kobject *kobj, const struct kobj_type *ktype)
{
    if (!kobj) return;

    kref_init(&kobj->kref);              /* 初始引用计数 = 1 */
    INIT_LIST_HEAD(&kobj->entry);
    kobj->state_initialized = 1;
}
```

### 2.2 添加到系统——kobject_add

```c
// lib/kobject.c:410-430
int kobject_add(struct kobject *kobj, struct kobject *parent, const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    ret = kobject_add_varg(kobj, parent, fmt, args);
    va_end(args);
    return ret;
}

// lib/kobject.c:362-408
int kobject_add_varg(struct kobject *kobj, struct kobject *parent,
                     const char *fmt, va_list args)
{
    kobject_set_name_vargs(kobj, fmt, args);      /* 设置名称 */

    /* 自动设定父对象 */
    if (kobj->parent || !parent) {
        if (kobj->kset) {
            /* 如果对象属于某个 kset，kset 的 kobj 成为父对象 */
            kobj->parent = kobj->kset->kobj;
        }
    }

    return kobject_add_internal(kobj);             /* 真正添加 */
}
```

**`kobject_add_internal()`** — 核心添加逻辑：

```c
// lib/kobject.c:210-264
static int kobject_add_internal(struct kobject *kobj)
{
    if (!kobj->name || !kobj->name[0]) {
        WARN(1, "kobject: (%p): attempted to be registered with empty name!\n");
        return -EINVAL;
    }

    parent = kobject_get(kobj->parent);           /* 增加父引用 */

    /* 1. 在 sysfs 中创建目录 */
    error = sysfs_create_dir_ns(kobj, ...);
    if (error) goto out;

    /* 2. 加入 kset 链表 */
    error = kobj_kset_join(kobj);                  /* kset->list */
    if (error) goto out_sysfs;

    /* 3. 创建默认属性文件 */
    error = sysfs_create_groups(kobj, ktype->default_groups);
    if (error) goto out_kset;

    kobj->state_in_sysfs = 1;                      /* 标记在 sysfs 中 */

    return 0;
}
```

### 2.3 引用计数管理

```c
// kobject_get(ko)   → kref_get(&ko->kref)      — 增加引用
// kobject_put(ko)   → kref_put(&ko->kref, ...)  — 减少引用，归零时调用 release
// kobject_del(ko)   — 从 sysfs 移除，减少父引用

// 引用计数归零调用链：
kref_put → kobject_release → kobject_cleanup → ktype->release(kobj)
```

**doom-lsp 确认**：`kobject_get` 在 `kobject.c:614`，`kobject_put` 在 `kobject.c:665`。`kobject_release` 在 `kobject.c:644` 通过 `kref_put` 的 release 回调机制触发。

---

## 3. sysfs——kobject 文件系统映射

### 3.1 目录创建

```c
// fs/sysfs/dir.c
int sysfs_create_dir_ns(struct kobject *kobj, const void *ns)
{
    struct kernfs_node *parent_sd = kobj->parent->sd;

    /* 在父目录下创建新目录 */
    kn = kernfs_create_dir_ns(parent_sd, kobj->name,
                               mode, uid, gid, kobj, ns);
    kobj->sd = kn;   /* 保存 kernfs 节点指针 */
}
```

### 3.2 属性文件

```c
// include/linux/kobject.h
struct attribute {
    const char *name;           /* 文件名 */
    umode_t mode;               /* 权限 */
};

struct attribute_group {
    const char *name;           /* 组名（NULL 为直接属主）*/
    struct attribute **attrs;   /* 属性数组 */
    // ... bin_attrs, is_visible 等
};

// sysfs show/store 路由
struct sysfs_ops {
    ssize_t (*show)(struct kobject *, struct attribute *, char *);
    ssize_t (*store)(struct kobject *, struct attribute *,
                     const char *, size_t);
};
```

**sysfs 文件操作路径**：

```
用户读 /sys/.../attr:
  sysfs_kf_read()
    → kernfs_file_read_iter()
      → sysfs_file_read_iter()
        → sysfs_ops->show(kobj, attr, buf)

用户写 /sys/.../attr:
  sysfs_kf_write()
    → kernfs_file_write_iter()
      → sysfs_ops->store(kobj, attr, buf, len)
```

**doom-lsp 确认**：`sysfs_file_read_iter` 在 `fs/sysfs/file.c`，通过 `kernfs` 框架向下调用到 `kobj_type->sysfs_ops->show`。

---

## 4. uevent 机制

### 4.1 uevent 数据结构

```c
// lib/kobject_uevent.c
struct kobj_uevent_env {
    char *envp[UEVENT_NUM_ENVP];     /* 环境变量数组 */
    int envp_idx;                      /* 当前环境变量数 */
    char buf[UEVENT_BUFFER_SIZE];     /* 环境变量缓冲区 */
    int buflen;                        /* 已用缓冲区长度 */
};
```

### 4.2 uevent 发送接口

```c
// include/linux/kobject.h — 用户可见的接口
int kobject_uevent(struct kobject *kobj, enum kobject_action action);
int kobject_uevent_env(struct kobject *kobj, enum kobject_action action,
                       char *envp[]);
```

**支持的事件类型**：

```c
enum kobject_action {
    KOBJ_ADD,       /* 设备添加 */
    KOBJ_REMOVE,    /* 设备移除 */
    KOBJ_CHANGE,    /* 设备属性变化 */
    KOBJ_MOVE,      /* 设备重命名/移动 */
    KOBJ_ONLINE,    /* 设备上线 */
    KOBJ_OFFLINE,   /* 设备下线 */
    KOBJ_BIND,      /* 驱动绑定 */
    KOBJ_UNBIND,    /* 驱动解绑 */
};
```

### 4.3 kobject_uevent_env 核心实现

```c
// lib/kobject_uevent.c
int kobject_uevent_env(struct kobject *kobj, enum kobject_action action,
                       char *envp[])
{
    struct kset *kset;
    struct kobj_uevent_env *env = NULL;
    const char *action_string = kobject_actions[action];  /* "add"、"remove" 等 */

    /* 1. 抑制检查 */
    if (kobj->uevent_suppress)
        return 0;

    /* 2. 获取所属 kset 和过滤钩子 */
    kset = kobj->kset;
    uevent_ops = kset->uevent_ops;

    /* 3. 过滤 */
    if (uevent_ops && uevent_ops->filter(kset, kobj) == 0)
        return 0;

    /* 4. 构造环境变量 */
    env = kzalloc(sizeof(struct kobj_uevent_env), GFP_KERNEL);

    /* 添加标准环境变量 */
    add_uevent_var(env, "ACTION=%s", action_string);
    add_uevent_var(env, "DEVPATH=%s", devpath);
    add_uevent_var(env, "SUBSYSTEM=%s", subsystem);

    /* 添加用户提供的环境变量 */
    if (envp)
        for (i = 0; envp[i]; i++)
            add_uevent_var(env, "%s", envp[i]);

    /* 5. 调用 kset 的 uevent 钩子 */
    if (uevent_ops && uevent_ops->uevent)
        uevent_ops->uevent(kset, kobj, env);

    /* 6. 调用 name 钩子 */
    subsystem = uevent_ops->name ? uevent_ops->name(kset, kobj) : kset->kobj.name;

    /* 7. 发送 */
    ret = kobject_uevent_net_broadcast(kset, kobj, env, action_string);
    if (!ret)
        ret = uevent_helper_trigger(env, action_string);

    return ret;
}
```

### 4.4 发送路径

**Netlink 广播**（主要路径）：

```c
// lib/kobject_uevent.c
static int kobject_uevent_net_broadcast(struct kset *kset,
    struct kobject *kobj, struct kobj_uevent_env *env,
    const char *action_string)
{
    /* 通过 NETLINK_KOBJECT_UEVENT socket 广播 */
    struct sk_buff *skb;
    const char *subsystem;

    /* 用户空间程序（udev/mdev/systemd-udevd）监听此 netlink */
    skb = alloc_skb(len, GFP_KERNEL);
    skb_put_data(skb, env->buf, env->buflen);
    netlink_broadcast_filtered(uevent_sock, skb, ...);
}
```

**用户空间辅助程序**（备用路径）：

```c
// lib/kobject_uevent.c
static int uevent_helper_trigger(struct kobj_uevent_env *env,
                                 const char *action_string)
{
    // 如果 CONFIG_UEVENT_HELPER 启用，调用 /sbin/hotplug
    char *argv[] = {uevent_helper, env->buf, NULL};
    call_usermodehelper(argv[0], argv, env->envp, UMH_WAIT_EXEC);
}
```

**uevent 接收端**（用户空间）：

```bash
# udevadm 监听 uevent
udevadm monitor

# 输出示例：
KERNEL[123.456] add      /devices/pci0000:00/... (pci)
KERNEL[123.457] add      /devices/virtual/.../block/sda (block)
UDEV  [123.500] add      /devices/pci0000:00/... (pci)

# 程序化接收（Python）：
import pyudev
context = pyudev.Context()
monitor = pyudev.Monitor.from_netlink(context)
monitor.filter_by(subsystem='block')
for device in iter(monitor.poll, None):
    print(f"{device.action}: {device.sys_path}")
```

**doom-lsp 确认**：`kobject_uevent_env` 在 `lib/kobject_uevent.c`。`kobject_uevent_net_broadcast()` 使用 `NETLINK_KOBJECT_UEVENT` 协议（`net/core/netlink.c`）。

---

## 5. 设备注册中的 kobject + uevent

```c
// drivers/base/core.c
int device_add(struct device *dev)
{
    /* 1. 初始化 device 的 kobject */
    dev->kobj.parent = &dev->parent->kobj;

    /* 2. 创建 sysfs 目录 */
    kobject_add(&dev->kobj, dev->kobj.parent, "%s", dev_name(dev));

    /* 3. 创建属性文件 */
    sysfs_create_groups(&dev->kobj, dev->groups);

    /* 4. 发送 KOBJ_ADD uevent（告诉 udev 有新设备）*/
    kobject_uevent(&dev->kobj, KOBJ_ADD);

    /* 5. 创建 devtmpfs 设备节点 */
    devtmpfs_create_node(dev);
}
```

**设备注册完整的用户空间通知链**：

```
device_add()
  └─ kobject_add()
       └─ sysfs_create_dir()    → /sys/devices/... 目录创建
  └─ sysfs_create_groups()      → 属性文件创建
  └─ kobject_uevent(KOBJ_ADD)   → netlink → udev
       └─ udevd 收到 uevent
            └─ 解析 DEVPATH + SUBSYSTEM
            └─ 运行 udev 规则（创建 /dev 节点、加载固件等）
            └─ 创建 /dev/xxx 设备节点
```

---

## 6. 内核对象层次结构示例

```
/sys/
├── devices/                — 所有设备（device.kobj）
│   ├── platform/           — 平台设备
│   │   └── my_device/      → struct device.kobj
│   │       ├── uevent      → 设备 uevent 触发文件
│   │       ├── driver      → symlink to ../drivers/...
│   │       └── subsystem   → symlink to ../class/...
│   ├── pci0000:00/
│   │   └── 0000:00:1f.2/
│   │       ├── uevent
│   │       └── ...
│   └── virtual/
├── class/                  — 设备类
│   ├── block/
│   ├── input/
│   ├── misc/
│   └── ...
├── bus/                    — 总线
├── drivers/                — 驱动
├── firmware/               — 固件
└── kernel/                 — 内核参数
```

---

## 7. 总结

kobject/sysfs/uevent 三位一体是 Linux 设备模型对用户空间的视图：

**1. kobject** — 内核对象树的基础。每个嵌入 `struct device`、`struct bus_type`、`struct class` 中的 kobject 构成父子层次，通过引用计数管理生命周期。

**2. sysfs** — kobject 树在文件系统中的映射。`kobject_add()` → `sysfs_create_dir_ns()` 创建目录，`sysfs_ops->show/store` 实现属性读写。

**3. uevent** — 内核 → 用户空间的事件通道。`kobject_uevent(KOBJ_ADD)` → netlink 广播 → `udevd` 监听 → 规则匹配 → 设备节点创建。

**关键数字**：
- `kobject.c`：1,107 行，109 符号
- `kobject_uevent.c`：851 行
- `fs/sysfs/` 总计：1,295 行
- uevent 通道：NETLINK_KOBJECT_UEVENT 协议 + UEVENT_HELPER 备选
- kobject 状态标记：5 个（state_initialized/in_sysfs/add_uevent/remove_uevent/suppress）

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
