# 06-kobject / kset / uevent — 内核对象层级与热插拔事件深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/kobject.h` + `lib/kobject.c` + `kernel/sysfs.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**kobject** 是 Linux 设备模型的基础结构：
- 每个设备用 `struct kobject` 表示，形成层级树（sysfs）
- `kref` 引用计数管理生命周期
- `kset` 是 kobject 的集合（类似目录）
- `uevent` 机制在设备热插拔时通知用户空间

---

## 1. 核心数据结构

### 1.1 struct kref — 引用计数

```c
// include/linux/kref.h — kref
struct kref {
    atomic_t          refcount;   // 原子引用计数
};

// 核心操作：引用计数归零时自动调用析构函数
#define kref_read(kref)   atomic_read(&(kref)->refcount)

static inline void kref_get(struct kref *kref)
{
    atomic_inc(&kref->refcount);
}

static inline int kref_put(struct kref *kref, void (*release)(struct kref *kref))
{
    if (atomic_dec_and_test(&kref->refcount)) {
        release(kref);    // 计数归零，调用析构
        return 1;
    }
    return 0;
}
```

### 1.2 struct kobject — 内核对象

```c
// include/linux/kobject.h:49 — kobject
struct kobject {
    const char          *name;           // sysfs 中的名字
    struct list_head    entry;          // 接入 kset 的链表
    struct kobject      *parent;        // 父 kobject（形成树）
    struct kset         *kset;         // 所属 kset（集合）
    const struct kobj_type   *ktype;   // 对象类型（决定 release 方法）
    struct kref         kref;          // 引用计数
    unsigned int        state_initialized:1;
    unsigned int        state_in_sysfs:1;
    unsigned int        state_add_uevent_sent:1;
    unsigned int        state_remove_uevent_sent:1;
    unsigned int        uevent_suppress:1;
};

// 位字段说明：
// state_initialized：是否已初始化
// state_in_sysfs：是否已在 sysfs 导出
// uevent_suppress：是否抑制 uevent
```

### 1.3 struct kobj_type — 对象类型

```c
// include/linux/kobject.h:26 — kobj_type
struct kobj_type {
    void (*release)(struct kobject *kobj);          // 析构函数
    const struct sysfs_ops  *sysfs_ops;             // sysfs 操作
    struct attribute        **default_attrs;          // 默认属性
    struct attribute_group  **default_groups;         // 默认属性组
    const struct kobj_ns_type_operations *(*child_ns_type)(struct kobject *);
    const void *(*namespace)(struct kobject *);
};
```

### 1.4 struct kset — 对象集合

```c
// include/linux/kobject.h:79 — kset
struct kset {
    struct list_head        list;           // kobject 链表
    spinlock_t              list_lock;      // 保护链表的锁
    struct kobject          kobj;           // 内嵌的 kobject（kset 本身也是 kobject）
    const struct kset_uevent_ops *uevent_ops; // uevent 操作
};
```

---

## 2. kobject 生命周期

### 2.1 kobject_create — 创建

```c
// lib/kobject.c — kobject_create
struct kobject *kobject_create(void)
{
    struct kobject *kobj;

    kobj = kzalloc(sizeof(*kobj), GFP_KERNEL);
    if (!kobj)
        return NULL;

    kobject_init(kobj);  // 初始化
    return kobj;
}

// kobject_init：
static void kobject_init(struct kobject *kobj, const struct kobj_type *ktype)
{
    kref_init(&kobj->kref);     // refcount = 1
    INIT_LIST_HEAD(&kobj->entry); // 链表初始化
    kobj->state_initialized = 1;
    kobj->ktype = ktype;
}
```

### 2.2 kobject_add — 添加到 sysfs

```c
// lib/kobject.c — kobject_add
int kobject_add(struct kobject *kobj, struct kobject *parent, const char *fmt, ...)
{
    // 1. 设置父对象
    if (parent)
        kobj->parent = kobject_get(parent);
    else
        kobj->parent = kset->kobj;  // 使用 kset 的 parent

    // 2. 在 sysfs 创建目录
    error = sysfs_create_dir(kobj);
    if (error)
        goto exit;

    // 3. 创建属性文件
    error = populate_dir(kobj);  // kobj->ktype->default_attrs

    // 4. 发送 uevent（热插拔事件）
    kobject_uevent(kobj, KOBJ_ADD);

    return 0;

exit:
    kobject_put(kobj);  // 出错时减少引用
    return error;
}
```

### 2.3 kobject_put — 释放

```c
// lib/kobject.c — kobject_put
void kobject_put(struct kobject *kobj)
{
    if (kobj) {
        if (!kref_put(&kobj->kref, kobject_release))
            return;
    }
    // kref 归零 → 调用 kobject_release
}

// kobject_release：sysfs 清理 + kobj_type->release(kobj)
```

---

## 3. uevent — 热插拔事件

### 3.1 uevent 流程

```
设备插入
  ↓
kobject_uevent(kobj, KOBJ_ADD)
  ↓
kset_uevent_dir(kobj)  ← 选择 uevent 发送目录
  ↓
call_usermodehelper(KOBJ_ADD)  ← 用户空间程序（如 udev）接收
  ↓
udev 创建设备节点 (/dev/xxx)
```

### 3.2 kobject_uevent

```c
// lib/kobject_uevent.c — kobject_uevent
int kobject_uevent(struct kobject *kobj, enum kobject_action action)
{
    // 1. 检查是否抑制
    if (kobj->uevent_suppress)
        return 0;

    // 2. 查找 kset 的 uevent_ops
    if (kobj->kset && kobj->kset->uevent_ops) {
        // 调用 filter
        if (kset->uevent_ops->filter)
            if (!kset->uevent_ops->filter(kobj))
                return 0;

        // 调用 uevent
        if (kset->uevent_ops->uevent)
            kset->uevent_ops->uevent(kobj, action, envp);
    }

    // 3. 发送 netlink 消息到用户空间
    return uevent_netlink_sent(kobj, action, envp);
}

// action 类型：
//   KOBJ_ADD      — 添加
//   KOBJ_REMOVE   — 移除
//   KOBJ_CHANGE   — 变化
//   KOBJ_MOVE     — 移动
```

### 3.3 uevent 环境变量

```c
// lib/kobject_uevent.c — add_uevent_var
// 每个 uevent 附带环境变量：
//   ACTION=add
//   DEVPATH=/class/net/eth0
//   SUBSYSTEM=net
//   SEQNUM=1234
//   INTERFACE=eth0
```

---

## 4. sysfs — sysfs 文件系统

### 4.1 sysfs_create_file

```c
// fs/sysfs/file.c — sysfs_create_file
int sysfs_create_file(struct kobject *kobj, const struct attribute *attr)
{
    // sysfs 文件 = attribute（名字 + show + store）
    // 每个 kobject 可以有多个 attribute

    // 示例：/sys/class/net/eth0/operstate
    // attribute: { .name = "operstate", .show = operstate_show, .store = NULL }
}

// attribute 结构：
struct attribute {
    const char          *name;    // 文件名
    umode_t             mode;      // 权限
    show_func            show;      // 读函数
    store_func           store;     // 写函数
};
```

### 4.2 sysfs_ops

```c
// fs/sysfs/file.c — sysfs_ops
const struct sysfs_ops sysfs_file_ops = {
    .show   = sysfs_show,
    .store  = sysfs_store,
};

// sysfs_show：
//   调用 kobj->ktype->sysfs_ops->show(kobj, attr, buf)
//   将内核数据格式化输出到用户空间

// sysfs_store：
//   调用 kobj->ktype->sysfs_ops->store(kobj, attr, buf, count)
//   从用户空间读取数据写入内核
```

---

## 5. device 模型层级

### 5.1 device 结构

```c
// include/linux/device.h — device
struct device {
    struct device           *parent;     // 父设备（总线/控制器）
    struct kobject         kobj;        // 内嵌 kobject
    const char             *init_name;  // 初始名
    struct bus_type        *bus;        // 总线类型
    struct device_driver   *driver;     // 驱动
    void                   *platform_data; // 平台数据
    // ...
};
// device 内嵌 kobject，继承了 sysfs 导出能力
```

### 5.2 sysfs 层级示例

```
/sys/
├── devices/              ← 所有设备的树
│   └── system/
│       └── cpu/
│           └── cpu0/
│               ├── node_id        ← device_attribute
│               └── online
├── class/               ← 按类别分组
│   ├── net/             ← 网络设备
│   │   └── eth0/
│   └── block/           ← 块设备
│       └── sda/
├── bus/                 ← 总线类型
│   ├── pci/
│   └── usb/
└── kernel/
    └── kobj_material/  ← kobject 示例
```

---

## 6. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| kref 引用计数 | 自动释放，无内存泄漏 |
| kobject 嵌入而非继承 | 所有设备/驱动都能使用 kobject 机制 |
| kset 聚合 | 同类设备归组（如所有块设备）|
| uevent netlink | 用户空间实时响应热插拔 |
| sysfs 导出 | 提供人可读的配置接口 |

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/kobject.h` | `struct kobject`、`struct kset`、`struct kobj_type` |
| `include/linux/kref.h` | `struct kref`、`kref_get`、`kref_put` |
| `lib/kobject.c` | `kobject_create`、`kobject_add`、`kobject_put`、`kobject_release` |
| `lib/kobject_uevent.c` | `kobject_uevent`、`uevent_netlink_sent` |
| `fs/sysfs/file.c` | `sysfs_create_file`、`sysfs_ops` |

---

## 8. 西游记类比

**kobject** 就像"取经队伍的档案系统"——

> 每个徒弟（device）都有一份电子档案（kobject），档案里有他们的编号（kref 引用计数）、上级领导（parent）、所属部门（kset）、职位类型（kobj_type）。档案一旦创建，就自动在玉帝的系统里出现（sysfs）。如果有人想要这个徒弟的档案，先调用 `kobject_get()`（增加计数）；用完了调用 `kobject_put()`（减少计数）。当计数归零时，档案自动销毁（release）。如果有新徒弟加入或者有徒弟离开，就发送一个 uevent 给天庭系统（udev），通知相关神仙更新系统。

---

## 9. 关联文章

- **sysfs/uevent**（article 57）：kobject 的 sysfs 导出
- **device model**（设备驱动部分）：kobject 在设备驱动中的使用
- **refcount**（基础）：kref 的原子计数实现