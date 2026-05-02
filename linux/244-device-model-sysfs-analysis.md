# device_model — Linux 设备模型与 sysfs 深度分析

> Linux 7.0-rc1 | 基于 `drivers/base/core.c`、`lib/kobject.c`、`drivers/base/bus.c`、`lib/kobject_uevent.c` 逐符号溯源
>
> *分析工具：doom-lsp (clangd LSP) | 分析日期：2026-05-01*

---

## 0. 架构总览图

```
用户空间
─────────────────────────────────────────────────────────────
/dev        ← 设备节点（mdev/udev 根据 uevent 创建）
/sys        ← sysfs 虚拟文件系统（全部由 kobject 层级映射）
│   /sys/bus/        ← 总线类型目录（bus_type）
│   │   pci/ devices/    ← pci 总线上的设备符号链接
│   │   i2c/ devices/
│   │   ...
│   /sys/class/      ← 设备类别目录（block, net, input...）
│   /sys/devices/    ← 真实设备树（/sys/devices/platform/...）
│   /sys/block/      ← 块设备视图（指向 devices/ 的链接）
│   /sys/subsystem/  ← 子系统视图
│
内核空间
─────────────────────────────────────────────────────────────
kobject ──────→ 父子链（parent 指针）──────→ 构成 sysfs 目录树
  │              kset->list  链表
  │              kset 是同类 kobject 的"容器"
kset ─────────→ uevent_ops（filter / name / uevent 回调）
  │              注册到 bus / class 时创建
  │
device ──────→ 内嵌 kobject，bus/parent/class 三重定位
  │
struct bus_type ──→ match()、probe()、uevent()、drivers_kset
  │
struct device_driver ─→ attach/detach 绑定逻辑
  │
device_link  ──→ supplier ↔ consumer，有 PM runtime 语义
  │
devres       ──→ 以 device 为中心的资源管理（自动释放）
```

---

## 1. kobject / kset 层级串联：树形结构的两条链

### 1.1 kobject 本身只做"目录节点"

```c
// include/linux/kobject.h
struct kobject {
    const char              *name;           // 目录名
    struct list_head        entry;           // 挂入 kset->list
    struct kobject         *parent;         // 父 kobject（决定 sysfs 路径）
    struct kset            *kset;           // 所属 kset（同类分组）
    const struct kobj_type *ktype;         // 操作集（release / sysfs_ops）
    struct kref            kref;
    unsigned int            state_initialized:1;
    unsigned int            state_in_sysfs:1;
    unsigned int            state_add_uevent_sent:1;
    unsigned int            state_remove_uevent_sent:1;
    // ...
};
```

`parent` 指针决定该 kobject 在 sysfs 中的**路径**（`/sys/devices/...` 的层级）。
`kset` 本身也是一个 kobject（`struct kset { struct kobject kobj; ... }`），所以 kset 可以嵌套。

### 1.2 parent vs kset：两条正交的链

```
kobject 树形结构（sysfs 目录层级）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
parent 指针链：/sys/devices/platform/... → /sys/devices → /sys → 根

kset 链表：同一 kset 下的 kobject 被 kset->list 组织在一起
           但这条链只用于"同类型聚合"，不参与 sysfs 路径计算
```

**为什么 kobject 本身不存储子系统信息？**

因为 kobject 只负责**目录结构**，它不知道自己是属于"总线子系统"还是"设备类别子系统"。子系统信息由 **parent 链** 隐式表达：

- `/sys/bus/` 下的 kobject → parent = bus_kset
- `/sys/class/` 下的 kobject → parent = class_kset
- `/sys/devices/` 下的 kobject → parent = devices_kset

要找到 subsystem，只需要沿着 `parent` 指针向上遍历，直到找到一个在 `kset->uevent_ops` 中注册过的 kset。

### 1.3 kobject_add_internal：parent 解析逻辑

```c
// lib/kobject.c:210
static int kobject_add_internal(struct kobject *kobj)
{
    struct kobject *parent;

    parent = kobject_get(kobj->parent);        // 优先用显式 parent

    if (kobj->kset) {
        if (!parent)                            // 没有显式 parent 时
            parent = kobject_get(&kobj->kset->kobj);  // 用 kset 的 kobject
        kobj_kset_join(kobj);                   // 加入 kset->list
        kobj->parent = parent;                 // 同步 parent 指针
    }
    // parent 指针决定 sysfs 中的目录层级
    error = create_dir(kobj);                  // 在 sysfs 创建目录
    if (error) {
        kobj_kset_leave(kobj);
        kobject_put(parent);
        kobj->parent = NULL;
    }
    return error;
}
```

关键逻辑：**优先用 kset 的 kobject 作为 parent**。这解释了为什么注册到总线时设备会自动出现在 `/sys/bus/pci/devices/` 下——总线注册时会创建对应的 kset，设备的 kset 指针指向总线，而总线的 kobject 就是那个目录。

---

## 2. struct bus_type 和设备注册路径

### 2.1 bus_type 定义

```c
// include/linux/device.h
struct bus_type {
    const char      *name;          // "pci", "i2c", "usb"...
    const char     *dev_name;      // 设备命名模板，如 "gpiochip%d"
    struct bus_attribute *bus_attrs;
    struct device_attribute *dev_attrs;
    struct driver_attribute *drv_attrs;

    int (*match)(struct device *dev, struct device_driver *drv);
    int (*uevent)(struct device *dev, struct kobj_uevent_env *env);
    int (*probe)(struct device *dev);
    int (*remove)(struct device *dev);
    void (*shutdown)(struct device *dev);

    int (*online)(struct device *dev);
    int (*offline)(struct device *dev);

    int (*rescan)(struct device *dev);

    struct subsys_private *p;      // 私有数据，不在总线代码中直接操作
};
```

### 2.2 device_register → device_add → bus_add_device

完整调用链（从 `device_register` 到挂载到 sysfs）：

```
device_register(dev)
└── device_add(dev)
    ├── kobject_add(&dev->kobj)          // 挂入 kobject 树
    │   └── kobject_add_internal()
    │       └── create_dir()             // 创建 /sys/devices/.../xxx 目录
    ├── device_create_file()             // 创建 uevent 属性文件
    ├── device_add_class_symlinks()      // 创建 /sys/class/xxx -> ../../.../devices/...
    ├── device_add_attrs()               // 添加 bus/root dir 属性
    ├── bus_add_device(dev)              // ← 关键：注册到总线
    │   ├── device_add_groups()          // 添加总线属性组
    │   ├── sysfs_create_link()         // /sys/bus/pci/devices/ -> ../../devices/xxx
    │   ├── sysfs_create_link()         // /sys/devices/xxx/subsystem -> /sys/bus/pci
    │   └── klist_add_tail()             // 加入 bus->p->klist_devices
    ├── kobject_uevent(&dev->kobj, KOBJ_ADD)  // 发送热插拔事件
    ├── bus_probe_device(dev)            // 触发驱动匹配
    └── klist_add_tail()                 // 加入父设备的 children 链表
```

### 2.3 bus_add_device：sysfs 链接的关键

```c
// drivers/base/bus.c:545
int bus_add_device(struct device *dev)
{
    struct subsys_private *sp = bus_to_subsys(dev->bus);

    // 在 /sys/bus/pci/devices/ 下创建符号链接，指向 /sys/devices/.../xxx
    error = sysfs_create_link(&sp->devices_kset->kobj, &dev->kobj, dev_name(dev));

    // 在 /sys/devices/.../xxx/ 下创建符号链接，指向 /sys/bus/pci（subsystem）
    error = sysfs_create_link(&dev->kobj, &sp->subsys.kobj, "subsystem");

    // 加入总线的设备链表（bus_for_each_dev 迭代用）
    klist_add_tail(&dev->p->knode_bus, &sp->klist_devices);
}
```

这解释了 sysfs 的布局：
- `/sys/bus/pci/devices/` 下的每个文件都是符号链接，指向 `/sys/devices/.../`
- 设备目录下的 `subsystem` 链接指向总线 subsystem 目录

### 2.4 bus_find_device：遍历总线设备链表

```c
// drivers/base/bus.c:405
struct device *bus_find_device(const struct bus_type *bus,
                               struct device *start,
                               const void *data,
                               device_match_t match)
{
    struct subsys_private *sp = bus_to_subsys(bus);
    struct device *dev;

    if (!sp) return NULL;

    if (start)
        dev = list_entry(start->p->knode_bus.next,
                         struct device, p->knode_bus);
    else
        dev = list_entry(sp->klist_devices.next,
                         struct device, p->knode_bus);

    for (; &dev->p->knode_bus != &sp->klist_devices; dev = next_device(dev))
        if (match(dev, data))
            return dev;
    return NULL;
}
```

遍历的是 `sp->klist_devices`，即 `bus_add_device()` 时 `klist_add_tail()` 加入的链表。

---

## 3. uevent 机制：从驱动层到用户空间

### 3.1 完整发送路径图

```
kobject_uevent(kobj, KOBJ_ADD)
└── kobject_uevent_env(kobj, action, NULL)
    │
    ├── [1] 向上遍历找 kset
    │    top_kobj = kobj;
    │    while (!top_kobj->kset && top_kobj->parent)
    │        top_kobj = top_kobj->parent;
    │    kset = top_kobj->kset;
    │
    ├── [2] uevent_ops->filter(kobj)     ← 可过滤事件
    │
    ├── [3] uevent_ops->name(kobj)      ← 确定 SUBSYSTEM 名称
    │
    ├── [4] 构造 env 环境变量
    │    add_uevent_var(env, "ACTION=%s", action_string);  // "add"
    │    add_uevent_var(env, "DEVPATH=%s", devpath);       // "/devices/..."
    │    add_uevent_var(env, "SUBSYSTEM=%s", subsystem);   // "usb" / "pci"
    │    add_uevent_var(env, "SEQNUM=%llu", ...);          // 递增序列号
    │
    │    [bus_uevent_ops->uevent() 可追加额外变量]
    │    e.g. PCI 总线追加 "PCI_CLASS=%04X", "PCI_ID=%04X:%04X"
    │
    ├── [5] kobject_uevent_net_broadcast()  ← Netlink 广播到用户空间
    │    struct sk_buff *skb;
    │    netlink_broadcast(sock, ..., NETLINK_KOBJECT_UEVENT, ...);
    │
    └── [6] CONFIG_UEVENT_HELPER（早期启动用，现代系统不用）
         call_usermodehelper(uevent_helper[0], argv, envp);
         uevent_helper = "/sbin/hotplug"（已被 udev 取代）
```

### 3.2 ENV 变量生成细节

`device_add` 触发 uevent 之前，会在 `bus_add_device` 中先完成 `sysfs_create_link`，然后 `device_add_attrs` 中设置属性（设备名、主次设备号等），再通过 `kobject_uevent_env` 发送：

```c
// drivers/base/core.c:2646（在 bus_uevent 中）
add_uevent_var(env, "DRIVER=%s", drv->name);       // 已绑定驱动时
add_uevent_var(env, "MAJOR=%u", MAJOR(dev->devt)); // 主设备号
add_uevent_var(env, "MINOR=%u", MINOR(dev->devt)); // 次设备号
add_uevent_var(env, "DEVNAME=%s", name);            // 设备节点名
```

### 3.3 uevent 与 udev 的关系

```
内核 uevent (Netlink)
        │
        │  多播到 NETLINK_KOBJECT_UEVENT 组
        ▼
   用户空间 udevd (systemd-udevd)
        │
        ├── 读取环境变量（ACTION, DEVPATH, SUBSYSTEM...）
        ├── 根据 /etc/udev/rules.d/ 规则匹配
        │    e.g. KERNEL=="sd[a-z]*", NAME="disk/%k", ...
        └── 创建设备节点：mknod /dev/sda ... + 设置权限
```

udev 不依赖 `/sbin/hotplug`（旧的 uevent_helper 机制已被废弃），而是通过 **Netlink 插座**接收 uevent 事件。`/sbin/hotplug` 在现代系统中仅用于 early boot（当 Netlink 还未就绪时）。

---

## 4. device_add 和 driver_probe：匹配与绑定

### 4.1 总线匹配路径

```
device_add(dev)                              ← 设备加入
    │
    bus_probe_device(dev)                    ← 触发总线探测
        │
        device_initial_probe(dev)
            │
            __device_attach(dev, true)       ← 异步允许
                │
                bus_for_each_drv(dev->bus, NULL, &data, __device_attach_driver)
                    │
                    __device_attach_driver(drv, data)
                        │
                        driver_match_device(drv, dev)   ← 匹配判断
                        │
                        if (match) driver_probe_device(drv, dev)
                            │
                            __driver_probe_device(drv, dev)
                                │
                                really_probe(drv, dev)  ← 调用驱动 probe
                                │
                                ← 返回：成功绑定 or -ENODEV
```

### 4.2 driver_match_device：ACPI / OF / platform 三路匹配

匹配函数因总线而异，通常按以下顺序尝试：

```
driver_match_device(drv, dev)
└── drv->bus->match(dev, drv)    ← 总线的 match 回调
    │
    ├── 通常是 of_driver_match_device()     ← 设备树（DT）匹配
    │    比较 .compatible 字符串
    │
    ├── acpi_driver_match_device()           ← ACPI 固件匹配
    │    比较 HID/CID
    │
    └── platform_match()                    ← 平台总线（无 OF/ACPI 时）
         比较 name/id_table
```

`bus->match` 是总线驱动实现的核心回调。PCI 总线用它匹配设备的 Vendor ID / Device ID；USB 总线用它匹配 bInterfaceClass；平台总线用它匹配 `platform_device.id_table`。

### 4.3 probe 何时被调用

**`device_add` 本身不调用 probe。** 它只把设备挂到总线上，然后 `bus_probe_device()` 触发匹配过程。真正的 probe 调用路径：

```
bus_probe_device(dev)                        ← 设备加入后立即调用
    └── device_initial_probe(dev)
        └── __device_attach(dev, true)
            └── bus_for_each_drv(..., __device_attach_driver)
                └── if (driver_match_device(drv, dev))
                        driver_probe_device(drv, dev)
                            └── really_probe(drv, dev)
                                    └── drv->probe(dev)  ← 驱动实现
```

另外，如果用户空间手动 echo "driver_name" > `/sys/bus/.../drivers/.../bind`，则通过 `driver_bind` → `device_driver_attach` → `__driver_probe_device` 路径触发 probe。

---

## 5. device_link：supplier / consumer 关系

### 5.1 为什么需要 device_link？

现代系统（特别是 ACPI fw_devlink）存在大量隐式依赖关系。设备 A 依赖设备 B 才能工作（例如 USB 集线器依赖电源管理芯片），但这种依赖在驱动代码中并不显式表达。`device_link` 建立了**有方向的 supplier-consumer 依赖图**，使得：

1. **电源管理**：consumer 运行时 supplier 必须处于活跃状态
2. **驱动同步**：supplier 的 `sync_state()` 先于 consumer 执行
3. **设备拓扑**：驱动核心知道谁依赖谁，可以阻止 dangling 依赖
4. **热插拔顺序**：设备卸载时 consumer 先于 supplier

### 5.2 device_link 的 flags

```c
// drivers/base/core.c:658
#define DL_MANAGED_LINK_FLAGS (
    DL_FLAG_AUTOREMOVE_CONSUMER |    // consumer 卸载时自动删除 link
    DL_FLAG_AUTOREMOVE_SUPPLIER |    // supplier 卸载时自动删除 link
    DL_FLAG_AUTOPROBE_CONSUMER |     // supplier 绑定后自动探测 consumer
    DL_FLAG_SYNC_STATE_ONLY |        // 仅影响 sync_state() 顺序
    DL_FLAG_INFERRED |               // fw_devlink 推断出的 link
    DL_FLAG_CYCLE                    // 环检测标记
)

// 独立 flags
DL_FLAG_STATELESS    // 不加入 dev->links.consumers/suppliers，仅记录返回值
DL_FLAG_PM_RUNTIME   // runtime PM 语义：consumer 激活时 supplier 必须活跃
DL_FLAG_RPM_ACTIVE   // 创建时强制 supplier 进入 active 状态
```

### 5.3 device_link_add 的关键实现

```c
// drivers/base/core.c:725
struct device_link *device_link_add(consumer, supplier, flags)
{
    // 验证 flags 组合合法性
    if (flags & DL_FLAG_STATELESS && flags & DL_MANAGED_LINK_FLAGS)
        return NULL;  // 互斥

    if (flags & DL_FLAG_PM_RUNTIME && flags & DL_FLAG_RPM_ACTIVE)
        pm_runtime_get_sync(supplier);  // 强制 supplier 活跃

    if (!(flags & DL_FLAG_STATELESS))
        flags |= DL_FLAG_MANAGED;       // 非 stateless → 加入全局管理

    // 检查循环依赖
    if (device_is_dependent(consumer, supplier))
        return NULL;

    // 创建 link：consumer->suppliers 双向链表
    link->supplier = supplier;
    link->consumer = consumer;
    list_add(&link->s_hook, &supplier->links.consumers);
    list_add(&link->c_hook, &consumer->links.suppliers);

    return link;
}
```

### 5.4 DL_FLAG_STATELESS 与 PM_runtime 的关系

```
DL_FLAG_STATELESS：不加入全局管理链表
  → caller 自己持有 device_link*，自己决定何时删除
  → 典型用法：固件层面的临时 link

DL_FLAG_PM_RUNTIME：runtime PM 语义
  → consumer 的 runtime PM get() 会级联到 supplier
  → supplier 的 rpm_active refcount 增加
  → 这两个 flag 可以叠加（DL_FLAG_STATELESS | DL_FLAG_PM_RUNTIME）
     表示"仅用于 PM 语义，不参与设备拓扑管理"
```

---

## 6. class 和设备节点：device_create / class_create

### 6.1 class 是设备的高层视图

`struct class` 并不直接对应 sysfs 目录，而是提供**设备分组的抽象**。典型 class 有：`block`、`net`、`input`、`tty`、`sound`、`misc` 等。

```
class 层级（/sys/class/）
├── /sys/class/net/        ← 所有网卡
│   └── eth0 → ../../devices/.../net/eth0
├── /sys/class/block/      ← 所有块设备
│   └── sda → ../../devices/.../block/sda
└── /sys/class/misc/       ← 杂项设备
```

### 6.2 device_create 和 class 的关系

```c
// drivers/base/core.c:4400
struct device *device_create(class, parent, devt, drvdata, fmt, ...)
{
    return device_create_with_groups(class, parent, devt, drvdata,
                                     NULL, fmt, ...);
}

struct device *device_create_with_groups(class, parent, devt, drvdata,
                                         groups, fmt, ...)
{
    dev = device_create_groups_vargs(class, parent, devt, drvdata, groups,
                                     fmt, vargs);
    // 创建 /dev/ 节点：devtmpfs 会话处理
    devtmpfs_create_node(dev);
    // 添加到 class 的设备链表
    // klist_add_tail(&dev->p->knode_class, &class->p->klist_devices);
}
```

`device_create` 执行：
1. 创建 `struct device`（devtmpfs 用）
2. 注册到 class 的 `klist_devices` 链表（`class_for_each_device` 迭代用）
3. 通过 `devtmpfs_create_node()` 在 `/dev/` 创建设备节点
4. 创建 `/sys/class/` 下的符号链接

### 6.3 devtmpfs、mdev 和 udev 的区别

```
用户空间创建设备节点的三种方式：

udev (systemd-udevd)
  - 通过 Netlink 接收 uevent
  - 读取 /etc/udev/rules.d/ 规则
  - 创建设备节点 + 设置权限 + 发送 INOTIFY 事件
  - 支持动态规则、热插拔、权限管理

mdev ( BusyBox / musl )
  - 监听 Netlink uevent（和 udev 相同底层）
  - 使用 /etc/mdev.conf 规则（比 udev 简单得多）
  - 直接调用 mknod，由 uevent_helper 或 Netlink 触发
  - 无 INOTIFY，无规则热重载

devtmpfs（内核直接创建 /dev/ 节点）
  - 内核在设备注册时通过 devtmpfs_create_node()
  - 不依赖任何用户空间守护进程
  - 设备节点名固定（无法根据 ID 重命名）
  - 现代系统通常以 devtmpfs 为主，udev/mdev 做规则匹配和权限调整
```

**现代系统的实际流程**：`device_add` 调用 `devtmpfs_create_node(dev)` → 内核在 `/dev/` 创建节点 → `udevd` 收到 uevent 后根据规则重命名、调整权限 → 最终 `/dev/sda` 可能替换 devtmpfs 创建的临时节点。

### 6.4 /dev 节点怎么通过 class 找到？

```
udevd 接收 uevent
  │
  DEVPATH=/devices/.../block/sda
  SUBSYSTEM=block
  │
  遍历 /sys/class/block/ 下的符号链接
  （这些链接指向 /sys/devices/.../block/sda）
  │
  从 uevent DEVPATH 提取设备节点名
  执行 mknod + chmod
```

udev 并不真正"通过 class 找设备节点"。它的逻辑是：**从 uevent 的 DEVPATH 知道设备是谁，然后根据规则决定设备节点名**。class 的作用是给 udev 规则提供**分类视角**（`SUBSYSTEM=block`，`KERNEL=sd*`）。

---

## 7. devres：设备资源管理

### 7.1 为什么需要 devres？

驱动程序中最常见的 bug 是：**注册了资源但设备移除时忘记释放**。`devres` 将所有资源（内存、IRQ、dma_buf 等）绑定到 `struct device`，设备被 `put_device()` 释放时，所有关联的 devres 自动释放。

### 7.2 devres_group：嵌套作用域

```c
// drivers/base/devres.c:32
struct devres_group {
    struct devres_node       node[2];   // 双重节点（open/close 配对）
    void                    *id;        // 作用域标识
};
```

`devres_open_group` → `devres_close_group` 构成一个作用域：

```c
void *devres_open_group(dev, id, gfp)
{
    struct devres_group *grp;
    grp = alloc(devres_group, gfp);
    devres_node_init(&grp->node[0], &group_open_release, dev); // open
    devres_node_init(&grp->node[1], &group_close_release, dev); // close
    add_dr(dev, &grp->node[0]);
    return grp;
}

void devres_close_group(dev, id)
{
    // 找到对应 group，从 node[0] 到 node[1] 之间的所有 devres 标记为已关闭
    // 下一次 devm_xxx 不会插入到已关闭 group
}
```

### 7.3 devres_open / close 的设计意图

`devres_group` 不是 RAII（没有隐式 close）。典型用法：

```c
static int foo_probe(struct device *dev)
{
    void *grp = devres_open_group(dev, NULL, GFP_KERNEL);

    devres_add(dev, devm_kmalloc(dev, sizeof(...), ...));
    devres_add(dev, devm_ioremap(dev, res->start, size));

    // 如果某个步骤失败，手动回滚
    if (error) {
        devres_release_group(dev, grp);  // 释放所有本 group 内资源
        return error;
    }

    devres_close_group(dev, grp);  // 标记 group 为"已完成初始化"
    return 0;
}

static int foo_remove(struct device *dev)
{
    // 整个 group 一起释放（按 reverse 顺序）
    devres_release_group(dev, NULL);  // 传入 NULL 释放所有 group
}
```

### 7.4 devres 与 devm_kmalloc 的关系

```c
void *devm_kmalloc(dev, size, gfp)
{
    void *ptr = kmalloc(size, gfp);
    devres_add(dev, ptr);           // 记录到 device 的 devres 链表
    return ptr;
}

void devres_add(dev, res)
{
    // 找到当前 open 的 group（devres_open_group 创建的）
    // 将 res 插入到 group 的资源链表
}

void put_device(dev)                 // 最终释放 device
    └── device_release(dev)
            └── devres_release_group(dev, NULL)  // 释放所有 devres
```

devres 的关键设计：**devres_add 找到当前打开的 group**，所有在同一 group 内分配的 devres，在 group close 或 device release 时按 LIFO 顺序释放。

---

## 8. ASCII 全图：kobject 树形结构

```
/sys
├── block/                      ← kset: block_kset
│   ├── sda → ../../devices/.../block/sda       (符号链接)
│   └── sdb → ...
├── bus/                        ← kset: bus_kset
│   ├── pci/
│   │   ├── devices/            ← kset: pci_bus_kset
│   │   │   ├── 0000:00:00.0 → ../../../devices/...
│   │   │   └── 0000:00:1f.2 → ../../../devices/...
│   │   ├── drivers/            ← kset: pci_driver_kset
│   │   └── subsystem → ../../subsystem/pci
│   ├── usb/
│   │   ├── devices/
│   │   └── drivers/
│   └── ...
├── class/                      ← kset: class_kset
│   ├── net/                    ← 由 net_class 创建，parent=class_kset
│   │   └── eth0 → ../../../devices/.../net/eth0
│   ├── block/                  ← 由 block_class 创建
│   ├── input/                  ← 由 input_class 创建
│   └── ...
├── devices/                    ← kset: devices_kset (根设备目录)
│   ├── system/                 ← platform_bus 的父级
│   │   └── platform/           ← platform_bus kset
│   │       ├── serial@xxx/
│   │       └── i2c@xxx/
│   └── platform/
│       └── serial@xxx/
│           ├── driver -> ../../../bus/platform/drivers/serial
│           ├── subsystem -> ../../../../bus/platform
│           ├── uevent         (内核写此文件触发 uevent)
│           ├── power/
│           └── ...
└── subsystem/                   ← kset: subsys_kset (各类子系统视图)
    ├── pci/
    ├── usb/
    └── ...

kobject.parent 决定 sysfs 目录层级
kobject.kset   决定所属分组（影响 uevent SUBSYSTEM 和 bus/devices/ 链接）

设备加入 sysfs 的调用链：
device_register(dev)
  → device_add(dev)
      → kobject_add(&dev->kobj)              // 创建 /sys/devices/.../xxx/
      → bus_add_device(dev)                   // 创建 /sys/bus/xxx/devices/链接
      → kobject_uevent(KOBJ_ADD)              // → 用户空间 udev
      → bus_probe_device(dev)                 // → 驱动匹配/probe
      → device_add_class_symlinks()            // 创建 /sys/class/xxx/ 链接
```

---

## 9. ASCII 全图：uevent 发送路径

```
┌─────────────────────────────────────────────────────────────────┐
│                         device_add(dev)                          │
│                                                                   │
│   ┌── kobject_add(&dev->kobj)                                     │
│   │   └── create_dir() → /sys/devices/.../xxx/ 目录                │
│   │                                                               │
│   ┌── bus_add_device(dev)                                         │
│   │   ├── sysfs_create_link(bus->devices_kset, dev)               │
│   │   │    → /sys/bus/pci/devices/xxx → ../../devices/.../xxx       │
│   │   └── sysfs_create_link(dev, bus->subsys.kobj, "subsystem")    │
│   │        → /sys/devices/.../xxx/subsystem → /sys/bus/pci          │
│   │                                                               │
│   ┌── kobject_uevent(&dev->kobj, KOBJ_ADD)                        │
│   │    │                                                          │
│   │    ▼                                                          │
│   │  kobject_uevent_env(kobj, action, NULL)                         │
│   │    │                                                          │
│   │    ├─[1] 找 kset：向上遍历 parent 直到 kset != NULL            │
│   │    │    top_kobj = kobj;                                       │
│   │    │    while (!top_kobj->kset && top_kobj->parent)            │
│   │    │        top_kobj = top_kobj->parent;                       │
│   │    │    kset = top_kobj->kset;                                 │
│   │    │                                                          │
│   │    ├─[2] uevent_ops->filter(kobj)   ← 可丢弃事件              │
│   │    │                                                          │
│   │    ├─[3] uevent_ops->name(kobj)    ← 确定 SUBSYSTEM 字符串   │
│   │    │    e.g. 返回 "pci" (bus_kset 的名字)                    │
│   │    │                                                          │
│   │    ├─[4] 分配 kobj_uevent_env，填充标准变量：                  │
│   │    │    ACTION=add                                             │
│   │    │    DEVPATH=/devices/...                                   │
│   │    │    SUBSYSTEM=pci                                          │
│   │    │    SEQNUM=1234                                            │
│   │    │                                                          │
│   │    │    uevent_ops->uevent(kobj, env) ← 总线可追加变量        │
│   │    │    e.g. PCI: PCI_ID, PCI_CLASS, DRIVER=xxx               │
│   │    │                                                          │
│   │    ├─[5] kobject_uevent_net_broadcast()                       │
│   │    │    │                                                      │
│   │    │    └── netlink_broadcast(sk, ..., NETLINK_KOBJECT_UEVENT)│
│   │    │         → 多播到所有订阅 NETLINK_KOBJECT_UEVENT 的进程    │
│   │    │                                                          │
│   │    └─[6] CONFIG_UEVENT_HELPER（仅 early boot）                │
│   │         call_usermodehelper("/sbin/hotplug", argv, envp)       │
│   │         （已被 udev 取代，现代系统通常不启用）                 │
│   │                                                              │
│   └── bus_probe_device(dev)        ← 驱动匹配（独立路径）         │
│        └── __device_attach(dev)     ← 遍历总线上的驱动             │
│             └── if (match) really_probe() → drv->probe()         │
└─────────────────────────────────────────────────────────────────┘
            │
            ▼ Netlink 多播
   ┌────────────────────────┐
   │   用户空间 udevd        │
   │   (systemd-udevd)       │
   │                         │
   │   接收环境变量：         │
   │   ACTION=add            │
   │   DEVPATH=/devices/...  │
   │   SUBSYSTEM=pci         │
   │   SEQNUM=1234           │
   │                         │
   │   读取 /etc/udev/rules.d/│
   │   匹配 KERNEL/SUBSYSTEM │
   │                         │
   │   执行规则：             │
   │   - mknod /dev/sda ...  │
   │   - chown / chmod       │
   │   - 符号链接命名         │
   │   - INOTIFY 通知        │
   └────────────────────────┘
```

---

## 10. 核心数据结构索引

| 结构体 | 定义位置 | 核心作用 |
|--------|----------|----------|
| `struct kobject` | `include/linux/kobject.h` | sysfs 目录节点，parent 决定路径 |
| `struct kset` | `include/linux/kobject.h` | kobject 容器，含 uevent_ops |
| `struct bus_type` | `include/linux/device.h` | 总线抽象，含 match/probe/uevent 回调 |
| `struct device` | `include/linux/device.h` | 设备实体，内嵌 kobject |
| `struct device_driver` | `include/linux/device.h` | 驱动实体，含 probe/bind 回调 |
| `struct device_link` | `include/linux/device.h` | supplier-consumer 依赖链 |
| `struct class` | `include/linux/device.h` | 设备高层分类抽象 |
| `struct subsys_private` | `drivers/base/bus.c` | bus/class 的私有数据（链表/kset） |
| `struct kobj_uevent_env` | `lib/kobject_uevent.c` | uevent 环境变量缓冲 |
| `struct devres_node` | `drivers/base/devres.c` | devres 链表节点 |
| `struct devres_group` | `drivers/base/devres.c` | devres 嵌套作用域 |

---

## 11. 关键函数调用路径汇总

```
注册设备到 sysfs：
device_register()
└── device_add()
    ├── kobject_add()
    ├── bus_add_device()
    │   └── sysfs_create_link() × 2
    ├── kobject_uevent(KOBJ_ADD)
    │   └── kobject_uevent_env()
    │       └── kobject_uevent_net_broadcast()  → Netlink
    └── bus_probe_device()
        └── device_initial_probe()
            └── __device_attach()
                └── driver_probe_device()
                    └── really_probe()
                        └── drv->probe()

注册总线：
bus_register()
└── bus_register_private()      // 创建 subsys_private
    ├── kset_create_and_add()   // 创建 bus->p->bus_kset
    │   └── kobject_add() → /sys/bus/xxx/
    ├── sysfs_create_bin_file() // 创建 uevent 属性
    └── driver_attach(bus)      // 重新扫描已有驱动
```