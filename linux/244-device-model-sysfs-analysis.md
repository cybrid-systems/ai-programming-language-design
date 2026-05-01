# device_model — Linux 设备模型与 sysfs 深度分析

## 1. 概述

Linux 设备模型是内核对所有硬件设备、软件抽象实体进行统一建模的核心框架。它以 **kobject** 为最小单元，通过 **kset** 组织成集合，以 **kobject** 的 parent 指针构建树形层级，最终所有有名字的 kobject 都在用户空间的 **sysfs** 文件系统中呈现为目录结构。

```
/sys/                          ← sysfs 根（挂载点）
├── block/                     ← 块设备集合
├── bus/                       ← 所有总线（platform, pci, usb, i2c...）
│   └── pci/
│       ├── devices/           ← 挂在该总线上的设备
│       └── drivers/           ← 该总线的驱动
├── class/                     ← 设备类别（net, block, tty, input...）
│   └── net/
│       └── eth0/              ← 网络设备实例
├── devices/                   ← 设备树全局视图
│   └── system/
│       └── cpu/               ← CPU 设备
├── devtmpfs/                  ← devtmpfs 管理的设备节点
└── kernel/                    ← 内核其他杂项
```

核心数据结构之间的拓扑关系：

```
struct bus_type (外部可见)
        │
        └── struct subsys_private *priv (内部隐藏)
                │
                ├── struct kset subsys         ← /sys/bus/<name>
                ├── struct kset *devices_kset  ← /sys/bus/<name>/devices/
                └── struct kset *drivers_kset  ← /sys/bus/<name>/drivers/

struct device (嵌入 struct kobject kobj)
        │
        └── kobj.parent ──→ 父级 kobject

struct device_driver (嵌入 struct kobject kobj)
        │
        └── kobj.kset ──→ 所属 bus 的 drivers_kset

kset ──→ 内嵌 struct kobject kobj
        │
        └── list (struct list_head) ──→ 所有子 kobject，通过 entry 串联
```

## 2. kobject / kset 层级串联

### 2.1 kobject 的结构

```c
struct kobject {
    const char          *name;          // sysfs 中的目录名
    struct list_head    entry;          // 链接到 kset->list
    struct kobject      *parent;        // 父级 kobject（树形结构的关键）
    struct kset        *kset;          // 所属 kset，提供了默认 parent
    const struct kobj_type *ktype;     // 描述属性操作等行为
    struct kref         kref;
    int                 state_in_sysfs;    // 是否已在 sysfs 中
    int                 state_add_uevent_sent;
    int                 state_remove_uevent_sent;
    int                 state_initialized;
    u8                  uevent_suppress:1;
    // ...
};
```

### 2.2 kset 的结构

```c
struct kset {
    struct list_head list;              // 所有子 kobject 的链表头
    spinlock_t list_lock;
    struct kobject kobj;                // kset 自身也是一个 kobject
    const struct kset_uevent_ops *uevent_ops;
};
```

### 2.3 树形结构的建立：`parent` 指针

kobject 的树形结构完全依赖 **parent 指针**。`kobject_add_internal()` 中的核心逻辑：

```c
static int kobject_add_internal(struct kobject *kobj)
{
    struct kobject *parent;

    // 1. 优先使用调用者传入的 parent
    parent = kobject_get(kobj->parent);

    // 2. 如果没有 parent，但有 kset，则使用 kset 的 kobj 作为 parent
    if (kobj->kset) {
        if (!parent)
            parent = kobject_get(&kobj->kset->kobj);  // kset.kobj 作为 parent
        kobj_kset_join(kobj);   // 加入 kset 的 list
        kobj->parent = parent;
    }

    // 3. 在 sysfs 中创建目录
    error = create_dir(kobj);
    if (error) {
        kobj_kset_leave(kobj);
        kobject_put(parent);
        kobj->parent = NULL;
    } else {
        kobj->state_in_sysfs = 1;
    }
}
```

**结论：**
- `parent` 指针决定 sysfs 中的目录层级（`/sys/devices/system.cpu/`）
- `kset->list` 维护同一个 kset 内所有 kobject 的链表（平级集合关系）
- `kobject_add()` 的第三个参数 `fmt` 是**相对于 parent 的路径名**，不传入则 kobj 自身名字作为目录名
- **parent 与 kset 的 list 是独立的两套串联机制**：parent 管树形层级，kset.list 管平级集合

### 2.4 kset 的 uevent_ops 链

每个 kset 都有自己的 `uevent_ops`，在上报 uevent 之前会调用 filter/name/uevent 来过滤或补充环境变量：

```c
struct kset_uevent_ops {
    int (*filter)(struct kobject *kobj);
    const char *(*name)(struct kobject *kobj);
    int (*uevent)(struct kobject *kobj, struct kobj_uevent_env *env);
};
```

## 3. struct bus_type 和设备注册路径

### 3.1 struct bus_type

```c
struct bus_type {
    const char      *name;           // "pci", "usb", "platform"...
    const char      *dev_name;       // 用于生成设备名，如 "pci0000:00"
    struct device   dev_root;        // 总线根设备
    struct bus_type_private *p;      // 私有数据
    // ...
};
```

外部的 `struct bus_type` 通过 `bus_to_subsys()` 找到内部隐藏的 `struct subsys_private`：

```c
struct subsys_private {
    struct kset             subsys;          // /sys/bus/<name>
    struct kset            *devices_kset;     // /sys/bus/<name>/devices/
    struct kset            *drivers_kset;     // /sys/bus/<name>/drivers/
    const struct bus_type   *bus;             // 回指 bus_type
    struct klist            klist_devices;   // 总线上所有设备
    struct klist            klist_drivers;   // 总线上所有驱动
    // ...
};
```

### 3.2 bus_register 的初始化

```c
int bus_register(const struct bus_type *bus)
{
    priv = kzalloc_obj(struct subsys_private);
    priv->bus = bus;

    // priv->subsys.kobj 是该总线的根目录 kobject
    kobject_set_name(&priv->subsys.kobj, "%s", bus->name);
    priv->subsys.kobj.kset = bus_kset;         // 加入 bus_kset 集合
    priv->subsys.kobj.ktype = &bus_ktype;

    kset_register(&priv->subsys);             // 创建 /sys/bus/<name>

    // 在总线目录下创建 devices/ 和 drivers/ 子 kset
    priv->devices_kset = kset_create_and_add("devices", NULL, bus_kobj);
    priv->drivers_kset = kset_create_and_add("drivers", NULL, bus_kobj);
}
```

### 3.3 device_register → device_add → bus_add_device

设备注册分两阶段：`device_register()` 调用 `device_initialize()` + `device_add()`。

`device_add()` 中的关键路径：

```
device_add(dev)
  ├── kobject_add(&dev->kobj, ...)         // 创建 /sys/devices/.../xxx
  ├── device_create_file(dev, &dev_attr_uevent)
  ├── device_add_class_symlinks(dev)       // 创建 /sys/class/... 的符号链接
  ├── device_add_attrs(dev)                // 添加设备属性文件
  ├── bus_add_device(dev)                  // ★ 将设备挂到总线上
  ├── dpm_sysfs_add(dev)                   // power management sysfs
  ├── device_pm_add(dev)
  ├── (major/devt) device_create_sys_dev_entry + devtmpfs_create_node
  ├── bus_notify(dev, BUS_NOTIFY_ADD_DEVICE)   // 通知总线监听者
  ├── kobject_uevent(&dev->kobj, KOBJ_ADD)    // ★ 发送 uevent 到用户空间
  └── bus_probe_device(dev)                    // ★ 自动探测驱动
```

**bus_add_device() 的核心操作**（`drivers/base/bus.c:545`）：

```c
int bus_add_device(struct device *dev)
{
    struct subsys_private *sp = bus_to_subsys(dev->bus);

    // 1. 在 /sys/bus/<name>/devices/ 下创建指向 dev->kobj 的符号链接
    sysfs_create_link(&sp->devices_kset->kobj, &dev->kobj, dev_name(dev));

    // 2. 在 dev->kobj 下创建指回 subsys 的符号链接 "subsystem"
    sysfs_create_link(&dev->kobj, &sp->subsys.kobj, "subsystem");

    // 3. 将设备节点加入总线的设备链表 klist_devices
    klist_add_tail(&dev->p->knode_bus, &sp->klist_devices);
}
```

**sysfs 路径对应关系：**

| 路径 | 来源 |
|------|------|
| `/sys/bus/<name>/devices/<dev>` | `sysfs_create_link(devices_kset, dev->kobj)` 符号链接指向 `/sys/devices/.../xxx` |
| `/sys/devices/.../xxx` | `kobject_add()` 在这里创建（实际设备目录） |
| `/sys/bus/<name>/devices/` 下每个入口 | 全部是符号链接 |

即 **`/sys/bus/<name>/devices/` 是 `/sys/devices/` 的镜像视图**，不是独立目录。

## 4. uevent 机制：从内核到用户空间

### 4.1 完整发送路径 ASCII 图

```
kobject_uevent(kobj, KOBJ_ADD)
  │
  └─→ kobject_uevent_env(kobj, action, NULL)
        │
        ├─ 1. 沿着 parent 链向上找到顶层 kset（用于 uevent_ops）
        │
        ├─ 2. uevent_ops->filter()  ← 可在此过滤事件
        │
        ├─ 3. uevent_ops->name()    ← 获取 SUBSYSTEM 名称
        │
        ├─ 4. 构建环境变量 env：
        │     ACTION=add
        │     DEVPATH=/devices/.../xxx
        │     SUBSYSTEM=pci         ← 来自 uevent_ops->name()
        │     SEQNUM=12345          ← 全局递增序列号
        │     [MAJOR=x] [MINOR=y]   ← 如有 devt
        │
        ├─ 5. uevent_ops->uevent()  ← 可在此添加自定义 ENV 变量
        │
        ├─ 6. kobject_uevent_net_broadcast()  ★ 发送 netlink 广播
        │     │
        │     └─→ alloc_uevent_skb()  组包 "add@/devices/.../xxx"
        │         │
        │         └─→ list_for_each_entry(ue_sk, &uevent_sock_list)
        │             netlink_broadcast()  → 发送到用户空间
        │
        ├─ 7. (CONFIG_UEVENT_HELPER) call_usermodehelper(uevent_helper)
        │     uevent_helper 默认是 /sbin/hotplug（已被废弃，现代系统用 netlink）
        │
        └─ 8. 标记 kobj->state_add_uevent_sent = 1
```

### 4.2 环境变量的生成来源

`kobject_uevent_env()` 中生成的核心 ENV 变量：

```c
// lib/kobject_uevent.c
add_uevent_var(env, "ACTION=%s", action_string);       // add/remove/move/online/offline
add_uevent_var(env, "DEVPATH=%s", devpath);            // kobject_get_path() 的结果
add_uevent_var(env, "SUBSYSTEM=%s", subsystem);        // uevent_ops->name() 或 kset 名
// SEQNUM 在广播前添加
add_uevent_var(env, "SEQNUM=%llu", atomic64_inc_return(&uevent_seqnum));
// KOBJ_ADD 时添加 devt
if (MAJOR(devt))
    add_uevent_var(env, "MAJOR=%u", MAJOR(devt));
    add_uevent_var(env, "MINOR=%u", MINOR(devt));
```

总线特定 uevent_ops 的 `bus_uevent_ops`（`drivers/base/bus.c:230`）可在此基础上添加 `PRODUCT`、`CONFIG_ID` 等总线特定变量。

### 4.3 用户空间接收

用户空间通过 **netlink** 接收（协议 `NETLINK_KOBJECT_UEVENT`，多播组 1）：

```bash
# 用 udevadm 监听
udevadm monitor --environment --udev

# 或用 netlink 套接字直接接收
cat /sys/kernel/uevent_sink  # 旧接口
```

现代系统使用 **systemd-udevd**，监听 netlink 套接字，根据 uevent 创建 `/dev/` 下的设备节点。

## 5. device_add 和 driver_probe 的匹配流程

### 5.1 device_add 中 probe 何时触发

```
device_add(dev)
  ...
  bus_probe_device(dev)      ← 在设备添加的最后阶段调用
```

`bus_probe_device()` 本身只是调用 `device_initial_probe(dev)`，真正匹配逻辑在内核更下层：

```c
void bus_probe_device(struct device *dev)
{
    device_initial_probe(dev);
    // 通知所有 subsys_interface 的 add_dev 回调
    list_for_each_entry(sif, &sp->interfaces, node)
        if (sif->add_dev) sif->add_dev(dev, sif);
}
```

`device_initial_probe()` 设置一个内部标记后，实际 probe 路径是 `__device_attach()` → `bus_for_each_drv()` → 对每个驱动调用 `driver_probe_device()`。

### 5.2 驱动匹配的三种机制

设备与驱动的匹配由总线的 `match()` 回调定义，不同总线注册不同的匹配函数：

#### 5.2.1 platform 总线

```c
// drivers/base/platform.c（典型）
static int platform_match(struct device *dev, struct device_driver *drv)
{
    // 1. ID table 匹配（acpi_match_id / of_match_id / platform_device_id）
    // 2. 设备树 (OF) 匹配：of_driver_match_device()
    // 3. ACPI 匹配：acpi_driver_match_device()
    // 4. 名称匹配：platform_bus_type.dev_name
}
```

#### 5.2.2 ACPI 匹配

ACPI 驱动通过 `acpi_device_id` table 注册，`acpi_driver_match_device()` 返回第一个匹配项。

#### 5.2.3 设备树 (OF) 匹配

通过 `of_device_id` table，`of_driver_match_device()` 比较 `compatible` 字符串。

### 5.3 完整 driver probe 路径

```
device_add(dev)
  └─→ bus_probe_device(dev)
        └─→ device_initial_probe(dev)
              └─→ __device_attach(drv, false)
                    │
                    └─→ bus_for_each_drv(dev->bus, NULL, __driver_attach)
                          │
                          └─→ __driver_attach(drv, dev)
                                │
                                ├─→ drv->bus->match(dev, drv)  ← 匹配检查
                                │   返回 1 表示匹配
                                │
                                └─→ driver_probe_device(drv, dev)
                                      │
                                      ├─→ really_probe(dev, drv)
                                      │     ├─→ dev->bus->probe(dev, drv)  ← 驱动自定义
                                      │     ├─→ pm_runtime_*               ← runtime PM
                                      │     └─→ device_links_check_suppliers()
                                      │
                                      └─→ kobject_uevent(dev, KOBJ_BIND)
```

**probe 何时被叫起来：**  
在 `device_add()` 中 `bus_probe_device()` 之前，`dev->fwnode->dev = dev` 会建立 fwnode 链接，用于 fw_devlink 机制。`really_probe()` 调用驱动的 `probe()` 回调（总线提供的或驱动自己的）。

## 6. device_link：为什么需要，如何建立

### 6.1 为什么 device_link 是必要的

Linux 设备之间存在依赖关系：
- **consumer（消耗者）**依赖 **supplier（供应者）**
- 例如：USB Hub 依赖电源管理芯片；SoC 依赖 PMIC

没有 device_link 时，驱动加载顺序无法保证，consumers 可能在 supplier 就绪之前尝试 probe。device_link 提供了：

1. **runtime PM 联动**：consumer suspend 时自动 suspend supplier（`DL_FLAG_PM_RUNTIME`）
2. **sync_state 同步**：确保所有 consumers 都完成 sync_state 后 supplier 才能执行（`DL_FLAG_SYNC_STATE_ONLY`）
3. **probe 顺序控制**：fw_devlink 在 supplier 未就绪时阻止 consumers probe
4. **状态追踪**：`DL_FLAG_AUTOREMOVE_CONSUMER/SUPPLIER` 在 device 移除时自动删除 link

### 6.2 struct device_link 的结构

```c
struct device_link {
    struct device       *consumer;       // 消耗方设备
    struct device       *supplier;        // 供应方设备
    struct device_link  *link_dev;       // 伪装成一个 device（用于 sysfs 暴露）
    enum dl_flag        flags;
    struct list_head    s_node;           // supplier->links.consumers 链表节点
    struct list_head    c_node;          // consumer->links.suppliers 链表节点
    struct kref         kref;
    enum dl_dev_state   status;          // DL_STATE_*
    struct work_struct  rm_work;         // 异步删除工作
};
```

### 6.3 标志位与 runtime PM

```c
#define DL_FLAG_STATELESS         BIT(0)  // 纯追踪，无行为干预
#define DL_FLAG_AUTOREMOVE_CONSUMER BIT(1) // consumer 删除时自动删除 link
#define DL_FLAG_PM_RUNTIME        BIT(2)  // runtime PM 联动（核心标志）
#define DL_FLAG_RPM_ACTIVE        BIT(3)  // supplier 保持 active 状态
#define DL_FLAG_AUTOREMOVE_SUPPLIER BIT(4) // supplier 删除时自动删除 link
#define DL_FLAG_AUTOPROBE_CONSUMER BIT(5) // consumer probe 成功后自动删除 link
#define DL_FLAG_MANAGED           BIT(6)  // 内部标记：link 已被 device_links 系统管理
#define DL_FLAG_SYNC_STATE_ONLY   BIT(7)  // 只参与 sync_state 顺序，不影响 PM
#define DL_FLAG_INFERRED          BIT(8)  // fw_devlink 推断的 link（非显式创建）
#define DL_FLAG_CYCLE             BIT(9)  // 循环依赖检测
```

**`DL_FLAG_STATELESS` 与 PM 的关系：**

- 如果 `flags & DL_FLAG_STATELESS`：link 纯粹是信息性的，不触发任何 runtime PM 行为
- 如果设置了 `DL_FLAG_PM_RUNTIME`：consumeruntime_get(supplier) 在 link 建立时调用
- 如果同时设置了 `DL_FLAG_RPM_ACTIVE`：supplier 一直保持 active（不 autosuspend）

### 6.4 device_link 的建立

```
device_link_add(consumer, supplier, flags)
  │
  ├─ PM_RUNTIME + RPM_ACTIVE → pm_runtime_get_sync(supplier)
  │
  ├─ 检查 supplier 状态与依赖关系
  │
  ├─ flags |= DL_FLAG_MANAGED (if not STATELESS)
  │
  ├─ 创建 struct device_link link
  │
  ├─ link->link_dev 是伪装 device（用于注册到 sysfs）
  │    device_register(&link->link_dev) → 在 /sys/devices/... 下暴露
  │
  ├─ consumer->links.suppliers += link
  └─ supplier->links.consumers += link
```

## 7. class 和设备节点：device_create 与 class_create 的关系

### 7.1 class 的本质

`struct class` 是对同类型设备的分组抽象（网络、块设备、终端等）。每个 class 都可以有自己的属性文件。

```c
struct class {
    const char      *name;          // "net", "block", "tty"...
    struct kset     class_kset;    // /sys/class/<name>
    // ...
};
```

### 7.2 device_create 的完整流程

`device_create()` (`drivers/base/core.c:4420`)：

```
device_create(class, parent, devt, drvdata, fmt, ...)
  │
  └─→ device_create_groups_vargs()
        │
        ├─ device_create_with_groups()
        │     │
        │     ├─ dev = device_create_vargs(class, parent, devt, drvdata, groups, fmt, vargs)
        │     │
        │     └─ if (devt) device_create_sys_dev_entry(dev)
        │            │
        │            └─ sysfs_create_link(devices_kset, dev->kobj, "10:0")
        │                 // 创建 /sys/class/<name>/<dev>/dev 符号链接指向 /sys/devices/...
        │
        └─→ devtmpfs_create_node(dev)  ← ★ 在 devtmpfs 中创建 /dev/ 下的设备节点
```

### 7.3 /dev 设备节点是如何生成的

**devtmpfs** 是内核内置的临时文件系统（CONFIG_DEVTMPFS），在系统启动时挂载在 `/dev`。关键流程：

```
device_add(dev)
  │
  └─ if (MAJOR(dev->devt))
        ├─ device_create_sys_dev_entry(dev)
        │      // 在 /sys/devices/.../xxx/dev 的 sysfs 属性中暴露 devt
        │
        └─ devtmpfs_create_node(dev)
               │
               └─→ devtmpfs_notify(dev, DEVTMPSYS_CREATE, ...)
                     │
                     └─→ 遍历 uevent_sock_list，发送 netlink 消息
                          用户空间 systemd-udevd 接收后：
                            1. 读取 sysfs 中的 devt（cat /sys/.../dev）
                            2. mknod /dev/xxx c MAJOR MINOR
                            3. 设置权限、owner
```

**class 目录到设备的符号链接链：**

```
/sys/class/net/eth0/      ← class 目录
  └── dev → ../../devices/.../eth0/dev    ← 符号链接指向具体设备
```

udev 规则可以基于 `SUBSYSTEM`, `DEVPATH`, `MAJOR`, `MINOR` 等匹配创建 `/dev/` 下的设备文件或符号链接。

### 7.4 device_destroy

```c
void device_destroy(const struct class *class, dev_t devt)
{
    // 找到注册的设备
    // device_unregister(dev)
    //   ├─ kobject_uevent(kobj, KOBJ_REMOVE)
    //   ├─ device_remove_file(...)
    //   ├─ bus_remove_device(dev)
    //   └─ kobject_del(kobj)
}
```

## 8. 完整的 kobject 树形结构 ASCII 图

```
/sys/ (sysfs)
│
├── devices/              ← system_kset: 所有设备的顶层容器
│   └── system/          ← /sys/devices/system/
│       └── cpu/         ← CPU device kobject
│           └── topology/
│
├── bus/                 ← bus_kset: 所有总线的容器
│   ├── pci/
│   │   ├── devices/    ← pci_priv->devices_kset (全部是符号链接)
│   │   │   ├── 0000:00:00.0 → ../../devices/...
│   │   │   └── 0000:00:01.0 → ../../devices/...
│   │   └── drivers/    ← pci_priv->drivers_kset
│   │       └── e1000e/
│   └── platform/
│       ├── devices/    ← platform_priv->devices_kset
│       └── drivers/
│
├── class/               ← 所有 class 的容器
│   ├── net/            ← net class
│   │   └── eth0/       ← 设备 class 目录（符号链接到 /sys/devices/...）
│   │       ├── uevent
│   │       ├── address
│   │       ├── device → ../../.../devices/.../xxx   (link to device tree)
│   │       └── dev    ← dev_t 暴露 (10:0)
│   └── block/
│       └── sda/
│
└── kernel/              ← 其他内核对象
    └── mm/
```

**kobject 树 vs sysfs 目录的映射：**

```
device.dev->kobj            → /sys/devices/.../xxx/
device.dev->kobj.parent     → /sys/devices/system/
kset.kobj                    → /sys/bus/pci/      （一个 kset = 一个 sysfs 目录）
  └── devices_kset.kobj     → /sys/bus/pci/devices/  （子 kset）
  └── drivers_kset.kobj     → /sys/bus/pci/drivers/   （子 kset）
```

## 9. uevent 发送路径 ASCII 图（完整版）

```
应用层
  ▲
  │ netlink (NETLINK_KOBJECT_UEVENT, multicast group 1)
  │
  │ socket = uevent_sock (init in uevent_net_init)
  │ list_for_each_entry(ue_sk, &uevent_sock_list)
  │
  └─────────────────────────────────────────────┐
                                                 ▼
                           ┌───────────────────────────────┐
                           │ kobject_uevent_env()         │
                           │ (lib/kobject_uevent.c:476)   │
                           └───────────────────────────────┘
                                    │
                    ┌───────────────┼────────────────┐
                    ▼               ▼                ▼
            uevent_ops.filter() uevent_ops.name()  uevent_ops.uevent()
            (过滤事件)          (获取 SUBSYSTEM)   (添加额外 ENV)
                    │
                    ▼
            ┌──────────────────────────┐
            │ add_uevent_var()        │
            │  ACTION=add             │
            │  DEVPATH=/devices/... │
            │  SUBSYSTEM=pci         │
            │  SEQNUM=12345          │
            │  MAJOR=10              │
            │  MINOR=0               │
            └──────────────────────────┘
                    │
                    ▼
            ┌──────────────────────────┐
            │ uevent_net_broadcast()   │
            │ (CONFIG_NET)             │
            └──────────────────────────┘
                    │
        ┌───────────┴────────────┐
        ▼                        ▼
 alloc_uevent_skb()      uevent_net_broadcast_tagged()
 拼接 action@devpath        (带标签的多播，容器场景)
        │                        │
        └───────────┬────────────┘
                    ▼
            ┌──────────────────────────┐
            │ netlink_broadcast()     │
            │ → 发送至用户空间         │
            └──────────────────────────┘
                    │
                    ▼
        ┌───────────────────────────────────┐
        │ systemd-udevd / udevadm monitor   │
        │ 读取 ENV → 应用规则 → mknod     │
        └───────────────────────────────────┘
```

## 10. 小结

| 机制 | 核心数据结构 | 核心文件 |
|------|-------------|----------|
| kobject 基础 | `struct kobject` | `lib/kobject.c` |
| kset 容器 | `struct kset` | `lib/kobject.c` |
| 总线注册 | `struct bus_type` + `struct subsys_private` | `drivers/base/bus.c` |
| 设备注册 | `struct device` + `device_add()` | `drivers/base/core.c` |
| 驱动匹配 | 总线 `match()` 回调（platform/ACPI/OF） | `drivers/base/` 各总线 |
| uevent | `kobject_uevent_env()` + netlink | `lib/kobject_uevent.c` |
| device_link | `struct device_link` | `drivers/base/core.c` |
| class 与设备节点 | `device_create()` + devtmpfs | `drivers/base/core.c` |

理解 Linux 设备模型的关键是把握两条独立的链：**(1) kobject.parent 构成的树形层级** 和 **(2) kset.list 构成的平级集合**，两者共同决定 sysfs 的目录布局。device_link 则在设备模型之上引入了跨设备的依赖追踪机制，配合 runtime PM 和 sync_state 共同管理系统电源与初始化顺序。


---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `drivers/base/core.c` | 489 | 3 | 278 | 113 |

### 核心数据结构

- **device_attr_group_devres** `core.c:2848`
- **class_dir** `core.c:3193`
- **root_device** `core.c:4256`

### 关键函数

- **fw_devlink_is_permissive** `core.c:44`
- **__fw_devlink_link_to_consumers** `core.c:45`
- **__fwnode_link_add** `core.c:68`
- **fwnode_link_add** `core.c:97`
- **__fwnode_link_del** `core.c:111`
- **__fwnode_link_cycle** `core.c:126`
- **fwnode_links_purge_suppliers** `core.c:139`
- **fwnode_links_purge_consumers** `core.c:155`
- **fwnode_links_purge** `core.c:171`
- **fw_devlink_purge_absent_suppliers** `core.c:177`
- **fw_devlink_purge_absent_suppliers** `core.c:191`
- **__fwnode_links_move_consumers** `core.c:200`
- **__fw_devlink_pickup_dangling_consumers** `core.c:223`
- **device_links_write_lock** `core.c:241`
- **device_links_write_unlock** `core.c:246`
- **device_links_read_lock** `core.c:251`
- **device_links_read_unlock** `core.c:256`
- **device_links_read_lock_held** `core.c:261`
- **device_link_synchronize_removal** `core.c:266`
- **device_link_remove_from_lists** `core.c:271`
- **device_is_ancestor** `core.c:277`
- **device_link_flag_is_sync_state_only** `core.c:290`
- **device_is_dependent** `core.c:303`
- **device_link_init_status** `core.c:334`
- **device_reorder_to_tail** `core.c:378`
- **device_pm_move_to_tail** `core.c:411`
- **status_show** `core.c:424`
- **auto_remove_on_show** `core.c:457`
- **runtime_pm_show** `core.c:474`
- **sync_state_only_show** `core.c:483`
- **device_link_release_fn** `core.c:501`
- **devlink_dev_release** `core.c:526`
- **device_link_wait_removal** `core.c:543`
- **device_link_wait_removal** `core.c:552`
- **devlink_add_symlinks** `core.c:560`

### 全局变量

- **deferred_sync** `core.c:41`
- **defer_sync_state_count** `core.c:42`
- **fwnode_link_lock** `core.c:43`
- **fw_devlink_drv_reg_done** `core.c:46`
- **fw_devlink_best_effort** `core.c:47`
- **device_link_wq** `core.c:48`
- **__UNIQUE_ID_addressable_fw_devlink_purge_absent_suppliers_6** `core.c:191`
- **device_links_lock** `core.c:238`
- **device_links_srcu_srcu_data** `core.c:239`
- **device_links_srcu_srcu_usage** `core.c:239`
- **device_links_srcu** `core.c:239`
- **dev_attr_status** `core.c:455`
- **dev_attr_auto_remove_on** `core.c:472`
- **dev_attr_runtime_pm** `core.c:481`
- **dev_attr_sync_state_only** `core.c:490`

### 成员/枚举

- **group** `core.c:2849`
- **groups** `core.c:2850`
- **kobj** `core.c:3194`
- **class** `core.c:3195`
- **dev** `core.c:4257`
- **owner** `core.c:4258`

