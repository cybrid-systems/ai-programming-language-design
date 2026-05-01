# 06-kobject-kset — 内核对象模型深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**kobject**（kernel object）是 Linux 设备模型的核心抽象。它提供了一个统一的引用计数、sysfs 暴露和生命周期管理框架。**kset** 是同类型 kobject 的集合，而 **ktype** 定义了 kobject 的行为。

简单来说：**kobject = 一个在 sysfs 中表现为目录的"内核对象"**。它让内核中的设备、驱动、总线等概念以一致的方式暴露给用户空间。

doom-lsp 确认 `include/linux/kobject.h` 包含 87+ 个符号（9 个结构体），实现位于 `lib/kobject.c`（约 200 行）。

---

## 1. 核心数据结构

### 1.1 struct kobject

```c
struct kobject {
    const char        *name;        // 名称（sysfs 目录名）
    struct list_head   entry;       // kset 中的链表节点
    struct kobject    *parent;      // 父对象（形成层次结构）
    struct kset       *kset;        // 所属的 kset
    struct kobj_type  *ktype;       // 对象类型描述
    struct kernfs_node *sd;         // sysfs 目录项
    struct kref        kref;        // 引用计数
    unsigned int state_initialized:1;  // 初始化状态位
    unsigned int state_in_sysfs:1;     // 是否已注册到 sysfs
    unsigned int state_add_uevent_sent:1; // uevent 是否已发送
    unsigned int state_remove_uevent_sent:1;
    unsigned int uevent_suppress:1;     // 抑制 uevent
};
```

关键字段关系：

```
kobject
  ├─ kref        → 引用计数（决定何时释放）
  ├─ ktype       → 释放回调 + sysfs 属性
  ├─ kset        → 所属集合（同类型分组）
  ├─ parent      → 在 sysfs 中的父目录
  └─ sd          → 实际关联的 sysfs 节点
```

### 1.2 struct kobj_type

```c
struct kobj_type {
    void (*release)(struct kobject *kobj);  // 释放回调（必须）
    const struct sysfs_ops *sysfs_ops;      // sysfs 读写操作
    struct attribute **default_attrs;       // 默认 sysfs 属性
    const struct kobj_ns_type_operations *(*child_ns_ops)(struct kobject *kobj);
    const struct kobj_ns_type_operations *(*parent_ns_ops)(struct kobject *kobj);
};
```

`release` 是所有 kobject **必须实现**的回调。引用计数归零时调用。

### 1.3 struct kset

```c
struct kset {
    struct list_head   list;       // 包含的 kobject 链表
    spinlock_t         list_lock;  // 保护链表
    struct kobject     kobj;       // 自身也是一个 kobject
    const struct kset_uevent_ops *uevent_ops;  // uevent 过滤
};
```

kset 自身也是 kobject，所以 kset 在 sysfs 中既是一个目录，又包含了同类型的子 kobject。

---

## 2. 对象生命周期

### 2.1 初始化：kobject_init

```c
void kobject_init(struct kobject *kobj, struct kobj_type *ktype)
{
    // 初始化引用计数为 1
    kref_init(&kobj->kref);
    // 初始化链表节点
    INIT_LIST_HEAD(&kobj->entry);
    // 设置类型
    kobj->ktype = ktype;
    // 标记已初始化
    kobj->state_initialized = 1;
}
```

**注意**：初始化后引用计数为 1，代表"存在"本身占据一个引用。

### 2.2 注册到 sysfs：kobject_add

```c
int kobject_add(struct kobject *kobj, struct kobject *parent, const char *fmt, ...)
```

```
kobject_add(kobj, parent, "name")
  │
  ├─ kobject_add_vtype(kobj, parent, NULL, fmt, args)
  │    ├─ 设置 parent 和 kset
  │    ├─ 创建 sysfs 目录（kernfs_create_dir）
  │    ├─ 创建默认属性（ktype->default_attrs）
  │    ├─ 添加到 kset 的链表
  │    │    └─ kset_put() → 发送 uevent
  │    └─ 标记 state_in_sysfs
  │
  └─ return 0 / -errno
```

### 2.3 引用计数

```c
struct kobject *kobject_get(struct kobject *kobj)  // +1
void kobject_put(struct kobject *kobj)              // -1 → 归零时调用 release
```

引用计数归零时的调用链（doom-lsp 追踪）：

```
kobject_put(kobj)
  └─ kref_put(&kobj->kref, kobject_release)
       └─ kobject_release(kobj)
            └─ kobject_cleanup(kobj)
                 ├─ ktype->release(kobj)    ← 用户提供的释放回调
                 └─ kfree(kobj)             ← 如果您使用 kmalloc 分配
```

---

## 3. uevent 机制

当 kobject 被添加到系统时，内核通过 kobject_uevent 向用户空间发送事件通知：

```
kobject_uevent(kobj, KOBJ_ADD)
  │
  ├─ kset->uevent_ops->filter(kset, kobj)   ← 过滤事件
  │    └─ 返回 0 = 不发送
  │
  ├─ kset->uevent_ops->name(kset, kobj)     ← 获取子系统名
  │
  ├─ kset->uevent_ops->uevent(kset, kobj, envp)
  │    └─ 添加环境变量
  │
  └─ 通过 netlink 发送到用户空间（udev）
       └─ UEHOTPLUG 程序 /lib/udev
```

这是 Linux 设备热插拔的基础：插入 USB 设备 → 内核创建 kobject → uevent → udev 加载驱动。

---

## 4. sysfs 层次结构

kobject 的 parent 指针决定了 sysfs 的目录层次：

```
/sys/
  ├── devices/          ← kset (devices_kset)
  │   ├── system/       ← kobject (parent = devices_kset.kobj)
  │   │   ├── cpu0/     ← kobject (parent = system)
  │   │   └── cpu1/
  │   └── pci0000:00/   ← kobject (parent = devices_kset.kobj)
  ├── bus/              ← kset (bus_kset)
  └── class/            ← kset (class_kset)
```

每个目录就是一个 kobject，通过 parent 指针形成树状结构。

---

## 5. 数据类型流

```
创建与注册：
  kmalloc(struct my_device)          ← 分配父结构
    └─ my_device.kobj.ktype = &my_ktype  ← 设置类型
    └─ kobject_init(&my_device.kobj)    ← 初始化
    └─ kobject_add(&my_device.kobj, parent, name) ← 注册
         ├─ sysfs 创建目录
         └─ uevent 发送

使用：
  kobject_get(&my_device.kobj)   ← 增加引用
  kobject_put(&my_device.kobj)   ← 减少引用
                                   └─ 归零时 → ktype->release()

sysfs 访问（用户空间读属性）：
  cat /sys/.../attr
    └─ sysfs_ops->show(kobj, attr, buf)
         └─ 返回属性值
```

---

## 6. 设计决策总结

| 决策 | 原因 |
|------|------|
| 引用计数 + release 回调 | 统一生命周期管理 |
| kset 为 kobject 集合 | 分组管理 + 批量 uevent |
| 嵌入而非指针 | 减少动态分配，直接管理 |
| sd (kernfs_node) | 延迟创建 sysfs 直至需要 |
| uevent 过滤钩子 | 用户可定制事件行为 |

---

## 7. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|-----|
| `include/linux/kobject.h` | `struct kobject` | 核心 |
| `include/linux/kobject.h` | `struct kobj_type` | 核心 |
| `include/linux/kobject.h` | `struct kset` | 核心 |
| `lib/kobject.c` | `kobject_init` | 实现 |
| `lib/kobject.c` | `kobject_add` | 实现 |
| `lib/kobject.c` | `kobject_uevent` | 实现 |
| `lib/kobject_uevent.c` | `kobject_uevent_env` | uevent 发送 |

---

## 8. 关联文章

- **device model**（article 244）：kobject 是设备模型的基础
- **sysfs**（article 57）：kobject 通过 sysfs 暴露给用户空间
- **uevent**（article 57）：设备热插拔的通知机制

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
