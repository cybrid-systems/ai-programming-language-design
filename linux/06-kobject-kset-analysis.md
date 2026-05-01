# 06-kobject — 内核对象模型深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**kobject（kernel object）** 是 Linux 设备模型的核心基础设施。它不仅是一个数据结构——它是一套完整的**对象生命周期管理框架**，包括引用计数、sysfs 暴露、uevent 通知和层次化组织。

kobject 的设计哲学是"一切皆对象"——每个设备、驱动、总线、模块在内核中都表示为一个 kobject，通过 kset 分组管理，通过 sysfs 暴露给用户空间，通过 uevent 实现热插拔通知。

doom-lsp 确认 `include/linux/kobject.h` 包含 87+ 个符号（9 个结构体），实现位于 `lib/kobject.c`（109 个符号）。

---

## 1. 核心数据结构

### 1.1 struct kobject

```c
struct kobject {
    const char        *name;                       // 名称（sysfs 目录名）
    struct list_head   entry;                      // kset 中的链表节点
    struct kobject    *parent;                     // 父对象（sysfs 层次）
    struct kset       *kset;                       // 所属集合
    struct kobj_type  *ktype;                      // 类型描述（release + sysfs ops）
    struct kernfs_node *sd;                        // sysfs 目录节点
    struct kref        kref;                       // 引用计数
    unsigned int state_initialized:1;              // 已初始化标志
    unsigned int state_in_sysfs:1;                 // 已在 sysfs 注册
    unsigned int state_add_uevent_sent:1;          // 已发送 add uevent
    unsigned int state_remove_uevent_sent:1;       // 已发送 remove uevent
    unsigned int uevent_suppress:1;                // 抑制 uevent
};
```

kobject 的生命周期由三个关键机制共同管理。

第一是引用计数（kref）。每个 kobject 在被创建时引用计数为 1。任何需要持有 kobject 的代码都要调用 `kobject_get` 增加引用计数，使用完毕后调用 `kobject_put` 减少。当引用计数降为 0 时，`ktype->release` 回调被调用。

第二是 sysfs 层次结构。每个注册的 kobject 在 `/sys/` 下对应一个目录。parent 指针决定了目录在 sysfs 中的位置——例如，一个 PCI 设备的 kobject 以总线 kobject 为 parent。通过 sysfs，用户空间可以查看和修改设备属性。

第三是 uevent 通知。当 kobject 被添加到系统时，内核通过 netlink 向用户空间发送 uevent。udev 监听这些事件并执行相应的规则（加载驱动、创建设备节点等）。

### 1.2 struct kobj_type

```c
struct kobj_type {
    void (*release)(struct kobject *kobj);           // 释放回调
    const struct sysfs_ops *sysfs_ops;              // sysfs 读写操作
    struct attribute **default_attrs;               // 默认 sysfs 属性
    const struct kobj_ns_type_operations *(*child_ns_ops)(struct kobject *);
    const struct kobj_ns_type_operations *(*parent_ns_ops)(struct kobject *);
};
```

kobj_type 是 kobject 的"类定义"。不同的对象类型可以有不同的 release 回调、不同的 sysfs 属性和不同的命名空间操作。

---

## 2. 生命周期

### 2.1 初始化

```c
void kobject_init(struct kobject *kobj, struct kobj_type *ktype)
{
    kref_init(&kobj->kref);            // 引用计数 = 1
    INIT_LIST_HEAD(&kobj->entry);      // 初始化链表节点
    kobj->ktype = ktype;              // 设置类型
    kobj->state_initialized = 1;      // 标记已初始化
}
```

### 2.2 注册

```
kobject_add(kobj, parent, "name")
  │
  └─ kobject_add_vtype(kobj, parent, NULL, "name")
       ├─ 设置 parent 和 kset
       ├─ 创建 sysfs 目录（kernfs_create_dir）
       ├─ 创建默认属性文件
       ├─ 加入 kset 链表
       └─ kobject_uevent(KOBJ_ADD)
```

### 2.3 引用计数

```c
struct kobject *kobject_get(struct kobject *kobj)   // +1
void kobject_put(struct kobject *kobj)               // -1
```

引用计数归零时：
```
kobject_put(kobj)
  └─ kref_put(&kobj->kref, kobject_release)
       └─ ktype->release(kobj)          // 调用用户回调
```

---

## 3. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/kobject.h` | `struct kobject` | 定义 |
| `include/linux/kobject.h` | `struct kobj_type` / `struct kset` | 定义 |
| `lib/kobject.c` | `kobject_init` / `kobject_add` / `kobject_put` | 实现 |

---

*分析工具：doom-lsp（clangd LSP）*
