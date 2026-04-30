# kobject / kset — 内核对象模型深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`lib/kobject.c` + `include/linux/kobject.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**kobject** 是 Linux 设备模型的基础单元，通过 **kset**（kobject 集合）和 **ktype**（kobject 类型）组织成层次结构，同时通过 **sysfs** 导出到用户空间。

---

## 1. 核心数据结构

### 1.1 kobject — 内核对象

```c
// include/linux/kobject.h — kobject
struct kobject {
    const char              *name;           // 对象名称（sysfs 文件名）
    struct list_head        entry;          // 接入父 kset 的链表
    struct kobject         *parent;         // 父对象
    struct kset             *kset;         // 所属 kset
    const struct kobj_type *ktype;         // 对象类型（操作函数表）
    struct kref             refcount;       // 引用计数
    struct sysfs_dirent     *sd;           // sysfs 目录项
    unsigned long           state_initialized:1; // 是否已初始化
    unsigned long           state_in_sysfs:1;   // 是否在 sysfs
    unsigned long           state_add_uevent_sent:1;
    unsigned long           state_remove_uevent_sent:1;
    unsigned long           uevent_suppress:1;  // 是否抑制 uevent
};
```

### 1.2 kref — 引用计数

```c
// include/linux/kref.h — kref
struct kref {
    atomic_t refcount;
};

#define kref_init(k)    atomic_set(&(k)->refcount, 1)

static inline void kref_get(struct kref *kref)
{
    atomic_inc(&kref->refcount);
}

static inline int kref_put(struct kref *kref, void (*release)(struct kref *))
{
    if (atomic_dec_and_test(&kref->refcount)) {
        release(kref);
        return 1;
    }
    return 0;
}
```

### 1.3 kset — kobject 集合

```c
// include/linux/kobject.h — kset
struct kset {
    struct list_head        list;           // 链表
    spinlock_t            list_lock;
    struct kobject         kobj;          // 自身是一个 kobject
    const struct kset_operations *ops;    // kset 操作
};
```

### 1.4 kobj_type — 对象类型

```c
// include/linux/kobject.h — kobj_type
struct kobj_type {
    void (*release)(struct kobject *kobj);        // 释放函数
    const struct sysfs_ops  *sysfs_ops;           // sysfs 操作
    struct attribute **default_attrs;              // 默认属性
    const struct attribute_group **default_groups;  // 属性组
    const struct kobj_ns_type_operations *(*child_ns_type)(struct kobject *kobj);
    const void *(*namespace)(const struct kobject *kobj);
};
```

---

## 2. kobject 生命周期

### 2.1 kobject_init — 初始化

```c
// lib/kobject.c — kobject_init
void kobject_init(struct kobject *kobj, const struct kobj_type *ktype)
{
    if (!kobj)
        return;

    kref_init(&kobj->refcount);          // 引用计数 = 1
    INIT_LIST_HEAD(&kobj->entry);        // 初始化链表节点
    kobj->ktype = ktype;                // 设置类型
    kobj->state_in_sysfs = 0;
    kobj->state_add_uevent_sent = 0;
    kobj->state_remove_uevent_sent = 0;
    kobj->uevent_suppress = 0;
}
```

### 2.2 kobject_add — 添加到 sysfs

```c
// lib/kobject.c — kobject_add
int kobject_add(struct kobject *kobj, struct kobject *parent, const char *fmt, ...)
{
    // 1. 注册到 sysfs
    error = sysfs_create_dir(kobj);
    if (error)
        return error;

    // 2. 如果有父对象，加入父对象的 kset
    if (kobj->kset)
        kset_init(kobj);

    // 3. 发送 uevent
    kobject_uevent(kobj, KOBJ_ADD);

    return 0;
}
```

### 2.3 kobject_put — 释放引用

```c
// lib/kobject.c — kobject_put
void kobject_put(struct kobject *kobj)
{
    if (kobj) {
        if (!kref_put(&kobj->refcount, kobject_release))
            return;
        kobject_cleanup(kobj);
    }
}
```

---

## 3. sysfs 导出

**sysfs** 目录结构：
```
/sys/
├── block/
│   ├── sda/
│   └── sdb/
├── bus/
│   ├── usb/
│   └── pci/
├── class/
│   ├── net/
│   └── graphics/
└── devices/
    └── platform/
```

**每个 kobject 对应一个 sysfs 目录**：
- `kobject->name` = 目录名
- `kobject->parent` = 父目录
- `kobject->ktype->sysfs_ops` = 属性操作（show/store）

---

## 4. uevent — 热插拔事件

```c
// lib/kobject_uevent.c — kobject_uevent
int kobject_uevent(struct kobject *kobj, enum kaction action)
{
    // 发送 uevent 到用户空间（udev）
    // 通过 netlink 套接字发送环境变量
    return kobject_uevent_env(kobj, action, NULL);
}

// 环境变量：
// ACTION = add/remove/change
// DEVPATH = /sys/devices/...
// SUBSYSTEM = usb/block/net/...
```

---

## 5. 完整文件索引

| 文件 | 函数 |
|------|------|
| `lib/kobject.c` | `kobject_init`、`kobject_add`、`kobject_put`、`kobject_cleanup` |
| `lib/kobject_uevent.c` | `kobject_uevent`、`add_uevent_var` |
| `include/linux/kobject.h` | `struct kobject`、`struct kset`、`struct kobj_type` |
| `include/linux/kref.h` | `kref_get`、`kref_put` |
