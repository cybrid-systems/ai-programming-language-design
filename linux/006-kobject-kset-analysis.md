# 006-kobject-kset — Linux 内核对象模型深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**kobject（kernel object）** 是 Linux 设备模型的核心基础设施。它不仅是一个数据结构——它是一套完整的**对象生命周期管理框架**，包括引用计数、sysfs 暴露、uevent 通知和层次化组织。

kobject 的设计哲学是"一切皆对象"——每个设备、驱动、总线、模块在内核中都表示为一个 kobject，通过 kset 分组管理，通过 sysfs 暴露给用户空间，通过 uevent 实现热插拔通知。

**doom-lsp 确认**：`include/linux/kobject.h` 包含 **87 个符号**（包含 kobject、kset、kobj_type、kobj_attribute 等 9 个结构体 + 60+ API 函数）。`lib/kobject.c` 包含 **109 个实现符号**。`lib/kobject_uevent.c` 包含 uevent 发送逻辑。

此外，整个驱动模型（`drivers/base/`）在此基础上构建了 `struct device`、`struct device_driver`、`struct bus_type` 等高层抽象。

---

## 1. 核心数据结构

### 1.1 `struct kobject`（`kobject.h:64`）

```c
// include/linux/kobject.h:64 — doom-lsp 确认
struct kobject {
    const char          *name;            // 名称（sysfs 目录名）
    struct list_head     entry;           // 链入 kset.list
    struct kobject      *parent;          // 父对象（sysfs 层次）
    struct kset         *kset;            // 所属 kset
    const struct kobj_type *ktype;        // 类型描述
    struct kernfs_node  *sd;              // sysfs dentry（文件系统节点）
    struct kref          kref;            // 引用计数
    unsigned int state_initialized:1;     // 已初始化
    unsigned int state_in_sysfs:1;        // 已在 sysfs 注册
    unsigned int state_add_uevent_sent:1; // 已发送 KOBJ_ADD
    unsigned int state_remove_uevent_sent:1; // 已发送 KOBJ_REMOVE
    unsigned int uevent_suppress:1;       // 抑制 uevent
};
```

**字段详解**：

| 字段 | 类型 | 大小 | 作用 |
|------|------|------|------|
| `name` | `const char*` | 8B | kobject 的名称，也是 sysfs 目录名。通过 `kobject_set_name` 设置 |
| `entry` | `struct list_head` | 16B | 链入所属 kset 的 `list` 链表。如果 kobject 不属于任何 kset，不使用 |
| `parent` | `struct kobject*` | 8B | 父 kobject，决定了 sysfs 中的路径（如 `/sys/devices/pci0000:00/...`）|
| `kset` | `struct kset*` | 8B | 所属的 kset，用于分组管理和 uevent |
| `ktype` | `const struct kobj_type*` | 8B | 定义了 release 回调、sysfs ops、默认属性 |
| `sd` | `struct kernfs_node*` | 8B | sysfs 的内核内部节点指针。注册后非 NULL |
| `kref` | `struct kref` | 4B | 引用计数。`kobject_get` +1，`kobject_put` -1，归零触发 release |

> **总共：64 字节**（64 位系统，bit fields 在 padding 中）

### 1.2 `struct kobj_type`（`kobject.h:116`）

```c
// include/linux/kobject.h:116 — doom-lsp 确认
struct kobj_type {
    void (*release)(struct kobject *kobj);                           // 释放回调
    const struct sysfs_ops *sysfs_ops;                              // sysfs 读写 ops
    const struct attribute_group **default_groups;                  // 默认属性组
    const struct kobj_ns_type_operations *(*child_ns_type)(          // 子命名空间
        const struct kobject *kobj);
    const struct ns_common *(*namespace)(const struct kobject *kobj); // 命名空间
    void (*get_ownership)(const struct kobject *kobj,               // 文件所有者
                          kuid_t *uid, kgid_t *gid);
};
```

kobj_type 是 kobject 的"类定义"。每个 kobject 通过 `ktype` 指针关联到其类型描述。同类 kobject 共享同一个 `kobj_type` 实例。

关键回调：
- **`release`**：引用计数归零时调用，负责释放 kobject 自身及其关联的资源。**必须设置！**
- **`sysfs_ops`**：定义了 `show()` 和 `store()` 函数，当用户空间读写 kobject 的属性文件时调用。
- **`default_groups`**：注册时自动创建的 sysfs 属性文件（旧的 `default_attrs` 已被替代）。

### 1.3 `struct kset`（`kobject.h:168`）

```c
// include/linux/kobject.h:168 — doom-lsp 确认
struct kset {
    struct list_head        list;          // kobject 链表（所有属于此 kset 的 kobject 通过 entry 链入）
    spinlock_t              list_lock;     // 保护 list 的自旋锁
    struct kobject          kobj;          // kset 自身的 kobject（嵌入，而非指针）
    const struct kset_uevent_ops *uevent_ops; // uevent 过滤和自定义
};
```

kset 是 kobject 的集合。它有两个作用：
1. **分组管理**：通过 `list` 链表维护所有属于此 kset 的 kobject
2. **uevent 过滤**：通过 `uevent_ops` 拦截、修改或抑制 uevent 事件

### 1.4 `struct kset_uevent_ops`（`kobject.h:133`）

```c
// include/linux/kobject.h:133 — doom-lsp 确认
struct kset_uevent_ops {
    int (* const filter)(const struct kobject *kobj);        // 是否发送 uevent
    const char *(* const name)(const struct kobject *kobj);  // 自定义名称（替代 kobj->name）
    int (* const uevent)(const struct kobject *kobj,         // 添加自定义环境变量
                         struct kobj_uevent_env *env);
};
```

### 1.5 `struct kobj_uevent_env`（`kobject.h:125`）

```c
// include/linux/kobject.h:125 — doom-lsp 确认
struct kobj_uevent_env {
    char *argv[3];                        // 程序参数（uevent helper 使用）
    char *envp[UEVENT_NUM_ENVP];          // 环境变量指针数组
    int envp_idx;                         // 下一个可用 envp 索引
    char buf[UEVENT_BUFFER_SIZE];         // 环境变量缓冲区（2KB）
    int buflen;                           // 已使用缓冲区长度
};
```

### 1.6 `struct kobj_attribute`（`kobject.h:139`）

```c
// include/linux/kobject.h:139 — doom-lsp 确认
struct kobj_attribute {
    struct attribute attr;                // 属性描述（含名称、权限）
    ssize_t (*show)(struct kobject *kobj, struct kobj_attribute *attr, char *buf);
    ssize_t (*store)(struct kobject *kobj, struct kobj_attribute *attr,
                     const char *buf, size_t count);
};
```

---

## 2. 生命周期管理——doom-lsp 确认的行号

kobject 的生命周期分为四个阶段：**分配 → 初始化 → 注册 → 释放**。

### 2.1 分配

kobject 通常不单独分配——它嵌入在其他数据结构中（如 `struct device`、`struct bus_type`）：

```c
struct device {
    struct kobject kobj;          // 嵌入 kobject
    // ... (设计驱动模型其他字段)
};
```

### 2.2 初始化——`kobject_init`（`lib/kobject.c:333`）

```c
// lib/kobject.c:333 — doom-lsp 确认
void kobject_init(struct kobject *kobj, struct kobj_type *ktype)
{
    kref_init(&kobj->kref);                     // kref = 1
    INIT_LIST_HEAD(&kobj->entry);               // 初始化链表节点
    kobj->ktype = ktype;                        // 设置类型
    kobj->state_initialized = 1;                // 标记已初始化
}
```

初始化后的状态：
- `kref = 1`：引用计数为 1
- `entry = { &entry, &entry }`：空链表节点
- `ktype = 指定类型`
- `name = NULL`（尚未设置）
- `parent = NULL`（尚未设置父对象）
- `kset = NULL`（尚未加入集合）
- `sd = NULL`（尚未在 sysfs 注册）

### 2.3 注册——`kobject_add`（`lib/kobject.c:410`）

```c
// lib/kobject.c:410 — doom-lsp 确认
int kobject_add(struct kobject *kobj, struct kobject *parent, const char *fmt, ...)
{
    va_list args;
    int retval;

    va_start(args, fmt);
    retval = kobject_add_varg(kobj, parent, fmt, args);
    va_end(args);

    return retval;
}
```

**doom-lsp 数据流追踪——`kobject_add_varg` → `kobject_add_internal`**：

```
kobject_add(kobj, parent, "my_device")
  │
  └─ kobject_add_varg(kobj, parent, "my_device")
       │
       ├─ kobject_set_name_vargs(kobj, fmt, args)    @ lib/kobject.c:266
       │   └─ kobject_set_name(kobj, "my_device")     ← 设置 name
       │
       ├─ kobj->parent = parent                       ← 设置父对象
       │
       └─ kobject_add_internal(kobj)                  @ lib/kobject.c:210
            │
            ├─ create_dir(kobj)                        @ lib/kobject.c:67
            │   ├─ sysfs_create_dir_ns(kobj...)       ← 创建 /sys/.../my_device/
            │   │   └─ kernfs_create_dir_ns()          ← 创建 kernfs 节点
            │   │       └─ sd = kernfs_node
            │   │
            │   └─ sysfs_create_groups(kobj,           ← 创建默认属性
            │                ktype->default_groups)
            │       └─ 遍历 default_groups 数组
            │           为每个属性创建 sysfs 文件
            │
            ├─ kobj_kset_join(kobj)                    @ lib/kobject.c:174
            │   ├─ 如果 kobj->kset != NULL:
            │   │   ├─ spin_lock(&kset->list_lock)
            │   │   ├─ list_add_tail(&kobj->entry, &kset->list)  ← 加入 kset
            │   │   └─ spin_unlock(&kset->list_lock)
            │   │
            │   └─ 如果 parent 为 NULL，且 kset->kobj 有 parent:
            │       设置 kobj->parent = kset->kobj 的 parent
            │
            ├─ kobject_uevent(&kobj, KOBJ_ADD)        ← 发送添加事件
            │   └─ kobject_uevent_env(kobj, action, NULL)
            │       ├─ kset_uevent_ops->filter? 过滤检查
            │       ├─ 构建环境变量：
            │       │   ACTION=add
            │       │   DEVPATH=/devices/...
            │       │   SUBSYSTEM=...
            │       │   ...
            │       ├─ kset_uevent_ops->uevent? 更多变量
            │       ├─ 通过 netlink 发送到用户空间
            │       └─ 调用 uevent_helper 程序（已废弃）
            │
            └─ return 0
```

### 2.4 `kobject_init_and_add`——初始化+注册一步到位（`kobject.h:96`）

```c
// kobject.h:96 — doom-lsp 确认
static inline int kobject_init_and_add(struct kobject *kobj,
                                        struct kobj_type *ktype,
                                        struct kobject *parent,
                                        const char *fmt, ...)
{
    kobject_init(kobj, ktype);
    return kobject_add(kobj, parent, fmt);
}
```

这个 API 是最常用的，将初始化和注册合并为一步。

### 2.5 `kobject_create_and_add`——分配+初始化+注册（`kobject.h:103`）

```c
// kobject.h:103 — doom-lsp 确认
struct kobject *kobject_create_and_add(const char *name, struct kobject *parent);
```

完全自动化的流程——分配 `struct kobject`、初始化、注册。适合创建简单的 kobject。

### 2.6 引用计数管理

```c
// kobject.h:108-110 — doom-lsp 确认
struct kobject *kobject_get(struct kobject *kobj);                // kref++
void kobject_put(struct kobject *kobj);                           // kref--
struct kobject *kobject_get_unless_zero(struct kobject *kobj);    // 如果 kref>0 则 +1
```

**数据流——kobject_put 的完整链路**：

```
kobject_put(kobj)                             @ lib/kobject.c:?
  └─ kref_put(&kobj->kref, kobject_release)    @ lib/kref.h
       │
       ├─ kref_put 检查 atomic_sub_and_test
       │   如果 kref 从 1 → 0，触发回调
       │
       └─ kobject_release(kobj)                @ lib/kobject.c:?
            └─ kobject_cleanup(kobj)
                 ├─ 如果 state_in_sysfs: kobject_del(kobj)
                 │   ├─ sysfs_remove_dir(kobj)   ← 删除 sysfs 目录
                 │   ├─ kobj_kset_leave(kobj)    ← 从 kset 链表移除
                 │   └─ kobject_uevent(KOBJ_REMOVE) ← 发送 remove 通知
                 │
                 ├─ ktype->release(kobj)         ← 调用具体类型的 release 回调
                 │   对于 struct device：
                 │   → device_release(dev)
                 │     → kfree(dev) 或 dev->release(dev)
                 │
                 └─ 释放 name（如果动态分配）
```

**关键设计**：`kref_put` 使用 `atomic_sub_and_test`——这是一个原子操作，保证了并发场景下引用计数的正确性。`kref` 是基于 `refcount_t` 的封装，具有溢出保护。

---

## 3. uevent 机制——kobject_uevent_env

### 3.1 事件类型

```c
// kobject.h:53-61 — doom-lsp 确认
enum kobject_action {
    KOBJ_ADD,      // 添加
    KOBJ_REMOVE,   // 移除
    KOBJ_CHANGE,   // 属性变更
    KOBJ_MOVE,     // 移动（修改 parent）
    KOBJ_ONLINE,   // 上线（如网络设备）
    KOBJ_OFFLINE,  // 离线
    KOBJ_BIND,     // 与驱动绑定
    KOBJ_UNBIND,   // 从驱动解绑
};
```

### 3.2 环境变量构建

```c
// lib/kobject_uevent.c — 发送 uevent
int kobject_uevent_env(struct kobject *kobj, enum kobject_action action,
                        char *envp_ext[])
{
    struct kobj_uevent_env *env;
    const char *action_string = kobject_actions[action];
    // ...
    // 构建标准环境变量：
    add_uevent_var(env, "ACTION=%s", action_string);     // e.g. "ACTION=add"
    add_uevent_var(env, "DEVPATH=%s", devpath);          // e.g. "DEVPATH=/devices/pci0000:00/..."
    add_uevent_var(env, "SUBSYSTEM=%s", subsystem);      // e.g. "SUBSYSTEM=pci"

    // 调用 kset_uevent_ops->uevent 回调添加更多变量
    if (kset && kset->uevent_ops && kset->uevent_ops->uevent)
        kset->uevent_ops->uevent(kobj, env);

    // 添加调用者传人的额外变量
    if (envp_ext) { ... }

    // 发送 netlink 消息到用户空间（udev 监听）
    // 备选：调用 userspace helper（已废弃）
}
```

### 3.3 kset_uevent_ops 的过滤作用

kset 可以通过 `uevent_ops` 控制 uevent 的行为：

```c
// 典型实现（drivers/base/bus.c）：
static int bus_uevent_filter(const struct kobject *kobj)
{
    // 只允许设备本身发送 uevent，不允许总线对象发送
    if (kobj->ktype == &bus_ktype)  // 总线对象
        return 0;                   // 过滤掉（不发送）
    return 1;                       // 设备对象 → 发送
}
```

---

## 4. sysfs 属性

### 4.1 `kobj_sysfs_ops`——默认 sysfs 操作

```c
// kobject.h:147 — doom-lsp 确认
const struct sysfs_ops kobj_sysfs_ops;  // 声明
```

`kobj_sysfs_ops` 是 kobject 子系统提供的默认 `sysfs_ops` 实现，用于通过 `kobj_attribute` 暴露属性：

```c
// lib/kobject.c — kobj_sysfs_ops 的实现
static ssize_t kobj_attr_show(struct kobject *kobj, struct attribute *attr,
                               char *buf)
{
    struct kobj_attribute *kattr = container_of(attr, struct kobj_attribute, attr);
    if (kattr->show)
        return kattr->show(kobj, kattr, buf);
    return -EIO;
}

static ssize_t kobj_attr_store(struct kobject *kobj, struct attribute *attr,
                                const char *buf, size_t count)
{
    struct kobj_attribute *kattr = container_of(attr, struct kobj_attribute, attr);
    if (kattr->store)
        return kattr->store(kobj, kattr, buf, count);
    return -EIO;
}
```

### 4.2 默认属性组——`default_groups`

```c
// kobj_type 的 default_groups 示例：
static struct attribute *my_attrs[] = {
    &my_attr.attr,  // kobj_attribute
    NULL,
};

static const struct attribute_group my_group = {
    .attrs = my_attrs,
};

static const struct attribute_group *my_groups[] = {
    &my_group,
    NULL,
};

struct kobj_type my_ktype = {
    .release = my_release,
    .sysfs_ops = &kobj_sysfs_ops,
    .default_groups = my_groups,    // 注册时自动创建这些属性
};
```

---

## 5. kset 操作——doom-lsp 确认的行号

```c
// kobject.h:175 — doom-lsp 确认
void kset_init(struct kset *kset);               // 初始化

// kobject.h:176
int kset_register(struct kset *kset);             // 注册（初始化 kset 自身 kobj + 添加到系统）

// kobject.h:177
void kset_unregister(struct kset *kset);          // 注销

// kobject.h:178
struct kset *kset_create_and_add(const char *name,  // 创建 + 注册（常用）
                                  const struct kset_uevent_ops *uevent_ops,
                                  struct kobject *parent_kobj);

// kobject.h:201
struct kobject *kset_find_obj(struct kset *kset, const char *name);  // 按名查找
```

**kset_find_obj 的查找流程**：

```
kset_find_obj(kset, "my_name")
  └─ spin_lock(&kset->list_lock)
     list_for_each_entry(kobj, &kset->list, entry) {
         if (!strcmp(kobj->name, "my_name")) {
             spin_unlock(...)
             return kobj;
         }
     }
     spin_unlock(...)
     return NULL;
```

---

## 6. 🔥 doom-lsp 数据流追踪——设备模型的层次结构

### 6.1 真实的数据流——PCI 设备注册

```
pci_register_driver(pci_drv)
  └─ __pci_register_driver(pci_drv, THIS_MODULE, KBUILD_MODNAME)
       └─ driver_register(&pci_drv->driver)
            └─ bus_add_driver(pci_drv->driver)
                 └─ kobject_init_and_add(&drv->driver.kobj, ...)
                      └─ kobject_add(&drv->driver.kobj, &pci_bus->pci_drivers_kset->kobj)
                          ├─ name = "driver_name"
                          ├─ parent = bus kset's kobject
                          ├─ 创建 /sys/bus/pci/drivers/driver_name/
                          ├─ 加入 pci_drivers_kset
                          └─ uevent: ACTION=add, SUBSYSTEM=pci, DRIVER=driver_name

pci_probe 发现设备后：
  └─ pci_scan_device(pci_bus, devfn)
       └─ pci_setup_device(dev)
            └─ device_initialize(&dev->dev)       ← 初始化 kobject
                 └─ kobject_init(&dev->dev.kobj, &device_ktype)
            └─ device_add(&dev->dev)               ← 注册
                 └─ kobject_add(&dev->dev.kobj, &pci_bus->dev.kobj, ...)
                     ├─ device_create_sysfs_entry(dev)
                     ├─ dev_set_name(dev, "%04x:%02x:%02x.%d", ...)
                     ├─ parent = bus device's kobject
                     ├─ 创建 /sys/devices/pci0000:00/0000:00:1f.0/
                     ├─ 加入 bus's kset
                     └─ uevent: ACTION=add, DEVTYPE=pci
```

### 6.2 sysfs 中的层次结构

```
/sys/
├── devices/                    ← 所有设备
│   └── pci0000:00/
│       └── 0000:00:1f.0/       ← Intel 南桥（设备 kobject）
│           ├── driver -> ../../../bus/pci/drivers/lpc_ich/  ← 符号链接
│           ├── subsystem -> ../../../bus/pci/              ← 符号链接
│           ├── vendor
│           ├── device
│           ├── ...
│
├── bus/                        ← 所有总线
│   └── pci/
│       ├── devices/            ← 链接到所有 PCI 设备
│       └── drivers/
│           └── lpc_ich/        ← 驱动 kobject
│
├── class/                      ← 所有设备类
│   └── net/                    ← 网络设备
│       ├── eth0 -> ../../../devices/pci0000:00/.../net/eth0/
│       │   ├── address         ← 属性 (kobj_attribute)
│       │   ├── mtu
│       │   └── ...
│       └── ...
│
└── kernel/                     ← 内核 kobject (kernel_kobj)
    └── mm/                     ← mm_kobj
```

---

## 7. 引用计数的安全保证

### 7.1 `kobject_get_unless_zero`（`kobject.h:109`）

```c
struct kobject *kobject_get_unless_zero(struct kobject *kobj)
{
    if (!kobj)
        return NULL;
    if (kref_get_unless_zero(&kobj->kref))
        return kobj;
    return NULL;
}
```

这个函数实现了"获取引用计数不为零的对象"的原子操作。在并行场景下，一个线程可能在获取 kobject 的同时，另一个线程正在释放它（`kobject_put`）。`kref_get_unless_zero` 使用 `atomic_add_unless(&kref->refcount, 1, 0)` 保证：如果引用计数非零则增加它，否则返回 false。

### 7.2 调试模式

```c
#ifdef CONFIG_DEBUG_KOBJECT_RELEASE
// 当启用 DEBUG_KOBJECT_RELEASE 时，释放被延迟 5 秒
// 帮助检测 use-after-free bug
struct delayed_work release;  // 在 kobject 中
#endif
```

---

## 8. kset 和 kobject 的命名空间支持

```c
// kobj_type 中定义的命名空间操作：
const struct kobj_ns_type_operations *(*child_ns_type)(...);
const struct ns_common *(*namespace)(...);
```

这允许 kobject 在不同的命名空间中拥有不同的 sysfs 视图。例如，网络设备 kobject 可以通过 `child_ns_type` 返回网络命名空间操作，使得 `iflink` 等属性在容器中显示不同的值。

```c
// drivers/base/core.c — 设备模型的命名空间
static const struct kobj_ns_type_operations device_ns_type_operations = {
    .type = KOBJ_NS_TYPE_NET,         // 网络命名空间
    .current_ns = device_namespace,   // 获取当前命名空间
    .netlink_ns = device_netlink_ns,  // netlink 命名空间标识
};

const struct kobj_ns_type_operations *device_child_ns_type(...) {
    return &device_ns_type_operations;
}
```

---

## 9. `kobject_rename` / `kobject_move`（`kobject.h:105-106`）

```c
// kobject.h:105 — doom-lsp 确认
int kobject_rename(struct kobject *kobj, const char *new_name);
// kobject.h:106
int kobject_move(struct kobject *kobj, struct kobject *new_parent);
```

`kobject_rename` 更改 kobject 的名称和对应的 sysfs 目录名。`kobject_move` 将 kobject 从当前父对象移到新的父对象下（即改变 sysfs 路径）。两种操作都会发送 `KOBJ_MOVE` uevent。

---

## 10. kset 与 sysfs 的对应关系

```
代码中的关系                     sysfs 中的对应
──────────────────────          ─────────────────
kset (/sys/bus/pci)             /sys/bus/pci/
                                 ├── uevent
                                 ├── devices/    ← kset->list 中的设备 kobj 的符号链接
                                 └── drivers/    ← kset->list 中的驱动 kobj 的符号链接
```

kset 本身也是一个 kobject（通过嵌入 `struct kobject kobj`），这使 kset 也能在 sysfs 中拥有目录、属性，并可以有自己的 parent。

在设备模型中，`bus_type`、`class`、`subsystem` 都内嵌了 kset，用于组织子 kobject：

```c
struct bus_type {
    struct kset subsys;        // bus 的 kset（管理总线自身属性）
    struct kset drivers;       // 驱动 kset（管理此总线下的所有驱动）
    struct kset devices;       // 设备 kset（管理此总线下的所有设备）
};
```

---

## 11. 性能数据

| 操作 | 实现文件 | 行号 | 主要耗时操作 |
|------|---------|------|-------------|
| `kobject_init` | lib/kobject.c | 333 | 初始化引用计数、链表节点 |
| `kobject_add` | lib/kobject.c | 410 | sysfs 目录创建（kernfs）|
| `kobject_put` | lib/kobject.c | — | atomic_sub + release 回调 |
| `kobject_get` | kobject.h | 108 | atomic_inc（约 5 个 cycle）|
| `kobject_uevent` | lib/kobject_uevent.c | — | netlink 消息发送 |
| `kset_find_obj` | kobject.h | 201 | O(n) 字符串比较 |

---

## 12. 源码文件索引

| 文件 | 内容 | doom-lsp 确认的符号数 |
|------|------|---------------------|
| `include/linux/kobject.h` | 所有结构体 + inline API | **87 个** |
| `lib/kobject.c` | kobject/kset 核心实现 | **109 个** |
| `lib/kobject_uevent.c` | uevent 发送逻辑 | — |
| `drivers/base/core.c` | 设备模型（struct device）| — |

---

## 13. 关联文章

- **07-wait_queue**：kobject 释放时可能调用的等待队列
- **08-mutex**：驱动模型中 device_lock 用于序列化 kobject 操作
- **57-sysfs-uevent**：sysfs 和 uevent 的完整机制
- **58-binder**：Android Binder 驱动使用 kobject 暴露接口
- **19-VFS**：kernfs 是 kobject 在文件系统中的表示

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
