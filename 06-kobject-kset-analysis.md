# Linux Kernel kobject + kset 设备模型 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/kobject.h` + `lib/kobject.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-19 学习笔记

---

## 0. 什么是 kobject / kset？

**kobject**：内核对象的最小单元，**所有设备、驱动、模块的父类**。提供引用计数、sysfs 表示、生命周期管理。

**kset**：同类 kobject 的集合（带 `list_head` + 自己的 `kobject`），构成 sysfs 目录树。

**核心价值**：统一设备模型的基石，让 /sys、uevent、udev、热插拔共享同一套对象机制。

---

## 1. 核心数据结构

### 1.1 `struct kobject` — 内核对象最小单元

```c
// include/linux/kobject.h:64
struct kobject {
    const char              *name;          // 对象名称（/sys 目录名）
    struct list_head        entry;         // 挂在 kset 链表里
    struct kobject         *parent;        // 父 kobject（形成 sysfs 目录树）
    struct kset            *kset;          // 所属 kset
    const struct kobj_type *ktype;        // 对象类型（提供 release、show、store 方法）
    struct kernfs_node     *sd;            // sysfs 目录节点（kernfs 子系统）
    struct kref             kref;          // 引用计数
#ifdef CONFIG_DEBUG_KOBJECT_RELEASE
    struct delayed_work     release_work;  // 延迟释放（调试用）
#endif
};
```

### 1.2 `struct kset` — kobject 集合

```c
// include/linux/kobject.h:168
struct kset {
    struct list_head        list;           // 所有子 kobject 链表
    spinlock_t              list_lock;      // 保护 list
    struct kobject          kobj;           // 集合本身也是一个 kobject（构成父子树）
    const struct kset_uevent_ops *uevent_ops;  // uevent 回调
};
```

### 1.3 `struct kobj_type` — 对象类型

```c
// include/linux/kobject.h:84
struct kobj_type {
    void (*release)(struct kobject *kref);       // 引用计数归零时调用
    const struct sysfs_ops *sysfs_ops;            // sysfs show/store 操作
    struct attribute **default_attrs;              // 默认属性
    const struct kobj_ns_type_operations *(*child_ns_type)(struct kobject *);
    const void *(*namespace)(struct kobject *);
};
```

### 1.4 `struct kref` — 引用计数

```c
// include/linux/kref.h:19
struct kref {
    refcount_t refcount;  // 原子引用计数
};

static inline void kref_init(struct kref *kref)
{
    refcount_set(&kref->refcount, 1);
}

// 获取引用
static inline void kref_get(struct kref *kref)
{
    refcount_inc(&kref->refcount);
}

// 释放引用（到 0 时调用 release）
static inline int kref_put(struct kref *kref, void (*release)(struct kref *kref))
{
    if (refcount_dec_and_test(&kref->refcount)) {
        release(kref);
        return 1;
    }
    return 0;
}
```

---

## 2. sysfs 目录结构图

```
/sys 目录结构对应 kobject 树：

/sys
├── block/          ← kset (block_kset)
│   ├── sda/       ← kobject (disk kobj)
│   └── sdb/
├── bus/           ← kset
│   ├── pci/       ← kset
│   │   ├── drivers/
│   │   └── devices/
├── class/         ← kset
│   ├── net/       ← kset
│   └── devices/    ← kset (链接到 /sys/devices)
├── devices/       ← 设备树根 (system_bus_kset)
│   ├── platform/
│   └── pci0000:00/
└── module/        ← kset (每个加载的模块一个 kobject)

每个 kobject：
  - entry         → kset->list 链表节点
  - parent        → 父 kobject
  - kset          → 所属 kset
  - name          → 目录名
  - sd            → sysfs 目录节点
```

---

## 3. kset 链表管理

```c
// kset 内部用 list_head 管理子 kobject

struct kset {
    struct list_head list;   // 头节点
    spinlock_t list_lock;
    struct kobject kobj;    // 集合自身也是 kobject
};

// 添加 kobject 到 kset：
//   list_add(&kobj->entry, &kset->list);
//   kobj->kset = kset;
//   kobj->parent = &kset->kobj;

// kobject 同时属于两棵树：
//   1. kset list 树（通过 entry）
//   2. sysfs 目录树（通过 parent）
```

---

## 4. 核心 API

### 4.1 生命周期

```c
// 创建 + 初始化 + 注册
int kobject_init_and_add(struct kobject *kobj,
                         const struct kobj_type *ktype,
                         struct kobject *parent,
                         const char *fmt, ...);

// 引用计数增加
struct kobject *kobject_get(struct kobject *kobj);

// 引用计数减少（归零时调用 ktype->release）
void kobject_put(struct kobject *kobj);

// 从 sysfs 和 kset 中删除
void kobject_del(struct kobject *kobj);

// 创建 kset
struct kset *kset_create_and_add(const char *name,
                                  const struct kset_uevent_ops *u,
                                  struct kobject *parent_kobj);
```

### 4.2 uevent 机制

```c
// include/linux/kobject.h — uevent 操作类型
enum kobject_action {
    KOBJ_ADD,      // 设备添加
    KOBJ_REMOVE,   // 设备移除
    KOBJ_CHANGE,    // 设备状态变化
    KOBJ_MOVE,      // 设备移动
    KOBJ_ONLINE,    // 设备上线
    KOBJ_OFFLINE,   // 设备下线
    KOBJ_BIND,      // 驱动绑定
    KOBJ_UNBIND,    // 驱动解绑
};

// uevent 通知用户态（udev）：
//   kobject_uevent(kobj, KOBJ_ADD, envp);
```

---

## 5. kref 引用计数机制

```
引用计数流程：

kobject_create()
  → kref_init(kref, 1)

kobject_init_and_add()
  → sysfs_create_dir()  // 不增加引用

kobject_get()
  → kref_get()          // refcount++

kobject_put()
  → kref_put()
    → refcount-- 后为 0
    → ktype->release()  // 释放内存 + kobject_del()
```

---

## 6. 真实内核使用案例

### 6.1 模块（`kernel/module.c`）

```c
// 每个模块有一个 kobject
struct module {
    struct kobject *mkobj;   // 模块自己的 kobject
    // ...
};

// 模块加载 → kobject_init_and_add(mkobj, &module_ktype, ...)
```

### 6.2 设备（`drivers/base/core.c`）

```c
// 每个设备（struct device）嵌入一个 kobject
struct device {
    struct kobject kobj;       // 设备对象
    struct device *parent;     // 父设备
    struct bus_type *bus;      // 所在总线
    struct device_driver *driver; // 绑定驱动
    // ...
};
```

### 6.3 总线（`drivers/base/bus.c`）

```c
// 总线是一个 kset
struct bus_type {
    struct kset *subsys_priv;  // 总线的私有数据
    // ...
};

// 每个注册的总线在 /sys/bus/ 下有一个目录
```

---

## 7. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| kobject 用 list_head 加入 kset | O(1) 添加/删除 |
| kset 自身也是 kobject | 统一父子树结构，sysfs 目录自然形成 |
| kref 引用计数 | 延迟释放，避免 use-after-free |
| ktype->release 回调 | 统一的资源释放接口 |
| uevent 机制 | 热插拔事件通知用户态（udev） |

---

## 8. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/kobject.h` | kobject / kset / kobj_type 定义 |
| `include/linux/kref.h` | kref 引用计数实现 |
| `lib/kobject.c` | kobject 核心操作（add/del/get/put） |
| `drivers/base/core.c` | device kobject 使用 |
| `kernel/module.c` | module kobject 使用 |
