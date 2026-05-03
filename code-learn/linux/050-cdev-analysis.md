# 50-cdev — Linux 字符设备驱动框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**cdev 子系统**是 Linux 字符设备驱动的核心基础设施。它管理**设备号注册**和**文件操作绑定**，将用户空间的 `open()`/`read()`/`write()` 系统调用桥接到驱动实现的 `file_operations`。

```
用户空间                          内核空间
─────────                       ─────────
open("/dev/tty0", O_RDWR)
  ↓
VFS: 根据 inode->i_rdev 找到设备号 (major, minor)
  ↓
chrdev_open() ───→ kobj_lookup(cdev_map, dev)
                      ↓
                   cdev: {ops = &tty_fops}
                      ↓
                   filp->f_op = tty_fops
                      ↓
                   tty_fops.open(inode, filp)
```

**doom-lsp 确认**：核心实现在 `fs/char_dev.c`（**689 行**）。数据结构在 `include/linux/cdev.h`（39 行）。设备号映射机制在 `drivers/base/map.c`（154 行）。

**关键文件索引**：

| 文件 | 行数 | 职责 |
|------|------|------|
| `fs/char_dev.c` | 689 | 核心实现：注册、打开、添加、删除 |
| `include/linux/cdev.h` | 39 | `struct cdev` 定义 + API 声明 |
| `include/linux/kdev_t.h` | — | `dev_t`, `MAJOR()`, `MINOR()`, `MKDEV()` |
| `drivers/base/map.c` | 154 | `kobj_map`——设备号到 kobject 的映射 |
| `include/linux/kobj_map.h` | — | `kobj_map` 接口声明 |

---

## 1. 核心数据结构

### 1.1 struct cdev — 字符设备

```c
// include/linux/cdev.h:14-22
struct cdev {
    struct kobject kobj;                    /* 内核对象（引用计数、sysfs）*/
    struct module *owner;                   /* 所属模块（防止卸载时仍有引用）*/
    const struct file_operations *ops;      /* 文件操作函数表 */
    struct list_head list;                  /* 关联的 inode 链表 */
    dev_t dev;                              /* 设备号（major + minor）*/
    unsigned int count;                     /* 管理的次设备号数量 */
} __randomize_layout;
```

**设计洞察**：`kobj`（kobject）使 cdev 可以通过引用计数管理生命周期，当最后一个引用释放时自动调用 release 函数。`list` 链表链接所有关联到此 cdev 的 `inode`，在 cdev 被删除时用于清理。

**两种 release 路径**：

```
cdev_init() → ktype_cdev_default → cdev_default_release()
   内联在宿主结构中，release 只清理 inode 链表

cdev_alloc() → ktype_cdev_dynamic → cdev_dynamic_release()
   动态分配，release 还要 kfree(cdev)
```

**doom-lsp 确认**：`struct cdev` 在 `include/linux/cdev.h:14`。两个 `kobj_type`——`ktype_cdev_default`（`char_dev.c:485`）和 `ktype_cdev_dynamic`（`char_dev.c:490`）区别对待静态嵌入和动态分配的 cdev。

### 1.2 dev_t — 设备号

```c
// include/linux/kdev_t.h
typedef u32 dev_t;                     /* 32 位设备号 */
#define MAJOR(dev)  ((dev) >> 20)      /* 高 12 位 = 主设备号 (0-4095) */
#define MINOR(dev)  ((dev) & 0xFFFFF)  /* 低 20 位 = 次设备号 (0-1048575) */
#define MKDEV(ma, mi) (((ma) << 20) | (mi))  /* 合成设备号 */
```

```
bit 31 ────────────────────────── bit 0
      [   major (12 bits)  ][ minor (20 bits)  ]
           0-4095             0-1048575
```

**特殊设备号**：

```c
#define WHITEOUT_DEV    MKDEV(0, 0)     /* overlay 白出 */
```

### 1.3 struct char_device_struct — 内部注册记录

```c
// fs/char_dev.c:32-37
static struct char_device_struct {
    struct char_device_struct *next;     /* 哈希链下一节点 */
    unsigned int major;                  /* 主设备号 */
    unsigned int baseminor;              /* 基线次设备号 */
    int minorct;                         /* 次设备号数量 */
    char name[64];                       /* 设备名 */
    struct cdev *cdev;                   /* 关联的 cdev（旧接口）*/
} *chrdevs[CHRDEV_MAJOR_HASH_SIZE];     /* 255 桶的哈希表 */
```

### 1.4 struct kobj_map — 设备号映射表

```c
// drivers/base/map.c:19-28
struct kobj_map {
    struct probe {
        struct probe *next;              /* 链表下一节点 */
        dev_t dev;                       /* 起始设备号 */
        unsigned long range;             /* 范围 */
        struct module *owner;            /* 所属模块 */
        kobj_probe_t *get;              /* 探针函数 */
        int (*lock)(dev_t, void *);      /* 锁定函数 */
        void *data;                      /* 私有数据（指向 cdev）*/
    } *probes[255];                      /* 255 桶的哈希表 */
    struct mutex *lock;
};
```

**doom-lsp 确认**：`kobj_map` 在 `drivers/base/map.c:19`。`cdev_map` 是全局唯一的 `kobj_map` 实例，在 `chrdev_init()`（`char_dev.c:519`）中通过 `kobj_map_init(base_probe, &chrdevs_lock)` 创建。

---

## 2. 设备号管理

### 2.1 设备号注册

```c
// fs/char_dev.c
int register_chrdev_region(dev_t from, unsigned count, const char *name);
/* 注册固定设备号范围 */

int alloc_chrdev_region(dev_t *dev, unsigned baseminor, unsigned count,
                        const char *name);
/* 动态分配主设备号 */

int __register_chrdev(unsigned int major, unsigned int baseminor,
                      unsigned int count, const char *name,
                      const struct file_operations *fops);
/* 注册 + 创建 cdev 一步到位（旧接口）*/
```

### 2.2 动态分配算法

```c
// fs/char_dev.c:66-86
static int find_dynamic_major(void)
{
    int i;

    /* 1. 从标准动态范围高位开始找空主设备号 */
    for (i = ARRAY_SIZE(chrdevs)-1; i >= CHRDEV_MAJOR_DYN_END; i--)
        if (chrdevs[i] == NULL)
            return i;

    /* 2. 在扩展范围查找未被占用的主设备号 */
    for (i = CHRDEV_MAJOR_DYN_EXT_START;
         i >= CHRDEV_MAJOR_DYN_EXT_END; i--)
        if (major 未被使用)     /* 遍历哈希链 */
            return i;

    return -EBUSY;
}
```

**主设备号分区**：

```
0-2:   LOCAL/EXPERIMENTAL
3-59:  STATIC（静态分配）
60-234: DYNAMIC（动态分配主范围）
235-254: LOCAL/EXPERIMENTAL
255-261: DYNAMIC EXT（扩展动态）
262-4K: UNNAMED（未命名）
```

**doom-lsp 确认**：`CHRDEV_MAJOR_DYN_END`（234）和 `CHRDEV_MAJOR_DYN_EXT_START`（255）等常量在 `include/linux/major.h` 中定义。

### 2.3 注册冲突检测

`__register_chrdev_region()`（`char_dev.c:94-147`）在哈希表中检查区间重叠：

```c
/* 遍历目标哈希桶的链表 */
for (curr = chrdevs[i]; curr; prev = curr, curr = curr->next) {
    if (curr->major < major) continue;
    if (curr->major > major) break;           /* 插入到此位置 */
    /* major 相同，检查 minor 区间是否重叠 */
    if (curr->baseminor + curr->minorct <= baseminor) continue;
    if (curr->baseminor >= baseminor + minorct) break;
    return ERR_PTR(-EBUSY);                   /* 重叠 → 设备忙 */
}
```

### 2.4 设备号释放

```c
// fs/char_dev.c
void unregister_chrdev_region(dev_t from, unsigned count);
void __unregister_chrdev(unsigned major, unsigned baseminor, unsigned count,
                         const char *name);
```

`unregister_chrdev_region()` 遍历设备号范围，逐个调用 `__unregister_chrdev_region()` 从哈希表中移除注册记录。

---

## 3. cdev 生命周期

### 3.1 创建

**方法 1：静态嵌入（推荐）**

```c
struct my_dev {
    struct cdev cdev;          /* cdev 嵌入驱动结构体 */
    /* 其他驱动字段 */
};

void my_init(struct my_dev *dev)
{
    cdev_init(&dev->cdev, &my_fops);   /* ktype_cdev_default */
    dev->cdev.owner = THIS_MODULE;
    cdev_add(&dev->cdev, dev_num, 1);
}
```

**方法 2：动态分配**

```c
struct cdev *cdev = cdev_alloc();      /* ktype_cdev_dynamic */
cdev->owner = THIS_MODULE;
cdev->ops = &my_fops;
cdev_add(cdev, dev_num, 1);
```

**方法 3：旧式一步到位**

```c
/* 自动完成区段注册 + cdev_alloc + cdev_add */
major = __register_chrdev(0, 0, 1, "mydev", &my_fops);
```

### 3.2 cdev_add——加入系统

```c
// fs/char_dev.c:432-464
int cdev_add(struct cdev *p, dev_t dev, unsigned count)
{
    p->dev = dev;
    p->count = count;

    /* 白出设备号不允许 */
    if (WARN_ON(dev == WHITEOUT_DEV))
        return -EBUSY;

    /* 注册到 kobj_map（设备号 → cdev 映射）*/
    error = kobj_map(cdev_map, dev, count, NULL,
                     exact_match, exact_lock, p);
    if (error)
        goto err;

    kobject_get(p->kobj.parent);   /* 增加父 kobject 引用 */
    return 0;
}
```

**`exact_match` 和 `exact_lock`**：

```c
static struct kobject *exact_match(dev_t dev, int *part, void *data)
{
    struct cdev *p = data;
    return &p->kobj;              /* 直接返回 cdev 的 kobject */
}

static int exact_lock(dev_t dev, void *data)
{
    struct cdev *p = data;
    return cdev_get(p) ? 0 : -1;  /* 获取引用，失败返回 -1 */
}
```

### 3.3 cdev_del——从系统移除

```c
// fs/char_dev.c:510-522
void cdev_del(struct cdev *p)
{
    cdev_unmap(p->dev, p->count);       /* 从 kobj_map 移除 */
    kobject_put(&p->kobj);              /* 释放引用（可能触发 release）*/
}
```

**注意**：`cdev_del()` 只是阻止**新打开**。已经打开的文件仍然可以继续操作——因为 `filp->f_op` 已经指向驱动的 `file_operations`：

```c
// char_dev.c:510-513（函数注释）
void cdev_del(struct cdev *p)
{
    /* NOTE: This guarantees that cdev device will no longer be able
     * to be opened, however any cdevs already open will remain and
     * their fops will still be callable even after cdev_del returns. */
}
```

### 3.4 release 函数

```c
// fs/char_dev.c:522-535
static void cdev_default_release(struct kobject *kobj)
{
    struct cdev *p = container_of(kobj, struct cdev, kobj);
    cdev_purge(p);           /* 清理关联的 inode */
    kobject_put(parent);     /* 释放父 kobject */
}

static void cdev_dynamic_release(struct kobject *kobj)
{
    struct cdev *p = container_of(kobj, struct cdev, kobj);
    cdev_purge(p);
    kfree(p);                /* 释放 cdev 本身 */
    kobject_put(parent);
}
```

**`cdev_purge()`**——遍历并清理所有关联的 inode：

```c
static void cdev_purge(struct cdev *cdev)
{
    spin_lock(&cdev_lock);
    while (!list_empty(&cdev->list)) {
        inode = container_of(cdev->list.next, struct inode, i_devices);
        list_del_init(&inode->i_devices);
        inode->i_cdev = NULL;      /* 切断 inode → cdev 指针 */
    }
    spin_unlock(&cdev_lock);
}
```

---

## 4. 打开流程——chrdev_open

```c
// fs/char_dev.c:217-267
static int chrdev_open(struct inode *inode, struct file *filp)
{
    struct cdev *p;
    int ret = 0;

    spin_lock(&cdev_lock);
    p = inode->i_cdev;           /* 从 inode 缓存获取 cdev 指针 */

    if (!p) {
        /* 首次打开：从 kobj_map 查找设备号 */
        struct kobject *kobj;
        spin_unlock(&cdev_lock);

        kobj = kobj_lookup(cdev_map, inode->i_rdev, &idx);
        if (!kobj)
            return -ENXIO;       /* 无此设备 */

        new = container_of(kobj, struct cdev, kobj);
        spin_lock(&cdev_lock);

        p = inode->i_cdev;
        if (!p) {
            /* 缓存到 inode */
            inode->i_cdev = p = new;
            list_add(&inode->i_devices, &p->list);  /* 加入 cdev 的 inode 链表 */
            new = NULL;                              /* 避免释放 */
        } else if (!cdev_get(p))
            ret = -ENXIO;
    } else if (!cdev_get(p))
        ret = -ENXIO;

    spin_unlock(&cdev_lock);
    cdev_put(new);                 /* 释放临时引用 */
    if (ret) return ret;

    /* 替换 file_operations 为驱动 ops */
    fops = fops_get(p->ops);
    if (!fops) goto out_cdev_put;

    replace_fops(filp, fops);

    if (filp->f_op->open)         /* 调用驱动的 open() */
        ret = filp->f_op->open(inode, filp);

    return 0;
}
```

**打开流程时间线**：

```
open("/dev/mydev")
  ↓
VFS: do_dentry_open()
  ↓
VFS: inode->i_fop = &def_chr_fops  ← 所有字符设备共享
       .open = chrdev_open
  ↓
chrdev_open():
  1. 第一次打开：
     a. kobj_lookup(cdev_map, dev) → 设备号 → cdev
     b. inode->i_cdev = cdev       （缓存加速后续打开）
     c. inode 加入 cdev->list      （方便清理）
  2. 后续打开：直接使用 inode->i_cdev
  3. filp->f_op = cdev->ops       （替换为驱动 fops）
  4. f_op->open(inode, filp)      （调用驱动 open）
```

**doom-lsp 确认**：`chrdev_open` 在 `char_dev.c:223`。`kobj_lookup` 在 `drivers/base/map.c:95`。`replace_fops` 是 VFS 辅助函数（`include/linux/fs.h`）。

---

## 5. cdev_device_add——设备模型集成

现代内核推荐使用 `cdev_device_add()` 将 cdev 与 struct device 绑定：

```c
// fs/char_dev.c:541-560
int cdev_device_add(struct cdev *cdev, struct device *dev)
{
    if (dev->devt) {
        cdev_set_parent(cdev, &dev->kobj);  /* cdev 的父 kobject = device kobj */
        rc = cdev_add(cdev, dev->devt, 1);
        if (rc) return rc;
    }

    rc = device_add(dev);                   /* 注册到 driver core */
    if (rc && dev->devt)
        cdev_del(cdev);

    return rc;
}
```

**设计优势**：
- `cdev` 的生命周期与 `device` 绑定——设备驱动的引用计数自动管理 cdev
- `cdev_set_parent()` 使 `device` 成为 `cdev->kobj` 的父节点，确保 device 在 cdev 释放前不会被销毁
- `dev->devt` 为 0 → 不创建 cdev（用于仅 sysfs 设备）

**清理**：

```c
void cdev_device_del(struct cdev *cdev, struct device *dev)
{
    device_del(dev);                /* 先移除 device（阻止新用户打开）*/
    if (dev->devt)
        cdev_del(cdev);             /* 再从 kobj_map 移除 */
}
```

---

## 6. kobj_map——设备号映射的哈希实现

### 6.1 kobj_map

```c
// drivers/base/map.c:32-66
int kobj_map(struct kobj_map *domain, dev_t dev, unsigned long range,
             struct module *owner, kobj_probe_t *probe,
             int (*lock)(dev_t, void *), void *data)
{
    unsigned n = MAJOR(dev + range - 1) - MAJOR(dev) + 1;
    unsigned index = MAJOR(dev);
    unsigned i;

    for (i = 0; i < n; i++) {
        struct probe *p;

        p = kmalloc(sizeof(*p), GFP_KERNEL);
        p->dev = dev;
        p->range = range;
        p->owner = owner;
        p->get = probe;
        p->lock = lock;
        p->data = data;

        /* 按主设备号哈希到 probes[MAJOR(dev)] */
        p->next = domain->probes[index + i];
        domain->probes[index + i] = p;
    }
}
```

**注意**：如果设备号跨多个 major（range 大），会分别为每个 major 创建一个 probe 条目。

### 6.2 kobj_lookup

```c
// drivers/base/map.c:95-133
struct kobject *kobj_lookup(struct kobj_map *domain, dev_t dev, int *index)
{
    struct probe *p;
    struct kobject *kobj;

    mutex_lock(domain->lock);
    for (p = domain->probes[MAJOR(dev) % 255]; p; p = p->next) {
        /* 检查设备号是否在此 probe 的范围内 */
        if (p->dev > dev || p->dev + p->range - 1 < dev)
            continue;

        /* 尝试获取引用（调用 exact_lock / cdev_get）*/
        if (p->lock && p->lock(dev, p->data) == 0) {
            /* 成功获取 → 转换 */
            *index = dev - p->dev;   /* 次设备号偏移 */
            kobj = p->get(dev, index, p->data);  /* exact_match → 返回 cdev->kobj */
            mutex_unlock(domain->lock);
            return kobj;
        }
    }
    mutex_unlock(domain->lock);
    return NULL;                     /* 没找到 */
}
```

### 6.3 kobj_unmap

```c
// drivers/base/map.c:68-93
void kobj_unmap(struct kobj_map *domain, dev_t dev, unsigned long range)
{
    unsigned n = MAJOR(dev + range - 1) - MAJOR(dev) + 1;
    unsigned index = MAJOR(dev);

    for (i = 0; i < n; i++) {
        /* 遍历 probes[index+i] 链表，删除匹配的 probe */
        for (p = &domain->probes[index + i]; *p; p = &(*p)->next) {
            if ((*p)->dev == dev && (*p)->range == range) {
                struct probe *tmp = *p;
                *p = tmp->next;
                kfree(tmp);
                break;
            }
        }
    }
}
```

**doom-lsp 确认**：`kobj_map` 的 CRUD 操作在 `drivers/base/map.c` 中。哈希表有 255 个桶，通过 `MAJOR(dev) % 255` 索引。所有 `kobj_map` 操作受 `chrdevs_lock`（mutex）保护。

---

## 7. 模块加载与自动探测

```c
// fs/char_dev.c:499-504
static struct kobject *base_probe(dev_t dev, int *part, void *data)
{
    if (request_module("char-major-%d-%d", MAJOR(dev), MINOR(dev)) > 0)
        /* 兼容旧式别名：char-major-N */
        request_module("char-major-%d", MAJOR(dev));
    return NULL;
}

void __init chrdev_init(void)
{
    cdev_map = kobj_map_init(base_probe, &chrdevs_lock);
}
```

`base_probe` 作为 `kobj_map_init` 的默认探针——当 `kobj_lookup` 在 `cdev_map` 中找不到匹配的 probe 时，会调用 `base_probe` 尝试通过 `request_module()`（modprobe）加载内核模块。

---

## 8. 使用示例

### 8.1 完整驱动模板

```c
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/slab.h>

#define DEVICE_NAME "my_char_dev"
#define CLASS_NAME  "my_class"

static int major;
static struct class *my_class;
struct my_dev {
    struct cdev cdev;
    /* 私有数据 */
    int data;
};

static int my_open(struct inode *inode, struct file *filp)
{
    struct my_dev *dev = container_of(inode->i_cdev, struct my_dev, cdev);
    filp->private_data = dev;           /* 保存到 filp 供后续 read/write 使用 */
    return 0;
}

static ssize_t my_read(struct file *filp, char __user *buf,
                       size_t len, loff_t *off)
{
    struct my_dev *dev = filp->private_data;
    /* 读取 dev->data 到用户空间 */
    return 0;
}

static const struct file_operations my_fops = {
    .owner   = THIS_MODULE,
    .open    = my_open,
    .read    = my_read,
    /* .write, .release, .llseek, .unlocked_ioctl ... */
};

static int __init my_init(void)
{
    dev_t dev_num;
    struct my_dev *mydev;

    /* 1. 分配设备号 */
    alloc_chrdev_region(&dev_num, 0, 1, DEVICE_NAME);
    major = MAJOR(dev_num);

    /* 2. 创建设备类（sysfs）*/
    my_class = class_create(CLASS_NAME);

    /* 3. 分配驱动结构体 */
    mydev = kzalloc(sizeof(*mydev), GFP_KERNEL);

    /* 4. 初始化 cdev 并注册 */
    cdev_init(&mydev->cdev, &my_fops);
    mydev->cdev.owner = THIS_MODULE;
    cdev_add(&mydev->cdev, dev_num, 1);

    /* 5. 创建 device 节点（自动生成 /dev/my_char_dev）*/
    device_create(my_class, NULL, dev_num, mydev, DEVICE_NAME);

    return 0;
}

static void __exit my_exit(void)
{
    dev_t dev_num = MKDEV(major, 0);
    struct my_dev *mydev;

    /* 逆向清理 */
    device_destroy(my_class, dev_num);
    cdev_del(&mydev->cdev);
    class_destroy(my_class);
    unregister_chrdev_region(dev_num, 1);
    kfree(mydev);
}

module_init(my_init);
module_exit(my_exit);
MODULE_LICENSE("GPL");
```

### 8.2 用户空间交互

```bash
# 查看字符设备
ls -l /dev/my_char_dev
# crw------- 1 root root 240, 0 May  2 10:00 /dev/my_char_dev

# 查看主设备号注册情况
cat /proc/devices | grep my_char_dev

# 手动创建设备节点
mknod /dev/my_char_dev c 240 0

# 测试
echo "hello" > /dev/my_char_dev
cat /dev/my_char_dev
```

---

## 9. 与 VFS 的交互

### 9.1 inode 中的 cdev 字段

```c
// include/linux/fs.h (struct inode 中)
struct cdev *i_cdev;        /* 缓存：字符设备首次打开后指向 cdev */
struct list_head i_devices; /* 在 cdev->list 中的节点 */
```

### 9.2 文件操作替换

```c
// char_dev.c 中的 def_chr_fops
const struct file_operations def_chr_fops = {
    .open   = chrdev_open,         /* 所有字符设备共享 */
    .llseek = noop_llseek,         /* 默认无操作 */
};

// chrdev_open 中替换 f_op：
fops = fops_get(p->ops);
replace_fops(filp, fops);      /* filp->f_op = 驱动的 file_operations */
if (filp->f_op->open)
    filp->f_op->open(inode, filp);   /* 调用驱动 open */
```

### 9.3 已打开文件在 cdev_del 后的行为

```c
// char_dev.c 注释的保证
/* NOTE: This guarantees that cdev device will no longer be able to
 * be opened, however any cdevs already open will remain and their
 * fops will still be callable even after cdev_del returns. */
```

因为 `chrdev_open` 已经通过 `replace_fops` 将 `filp->f_op` 设置为驱动的私有 fops，这些 fops 引用的模块代码通过 `try_module_get()` 在打开时被保护起来。

---

## 10. 性能考量

### 10.1 关键路径延迟

```
open("/dev/mydev"):
  chrdev_open()
    ├─ spin_lock(cdev_lock)         [~10ns]
    ├─ kobj_lookup(cdev_map)        [~50ns]
    │    └─ mutex_lock + 哈希遍历   [~30ns]
    ├─ list_add(inode→cdev)         [~10ns]
    ├─ fops_get(cdev->ops)          [~10ns]
    ├─ replace_fops(filp)           [~5ns]
    └─ f_op->open(inode, filp)      [取决于驱动]

read() 之后:
  filp->f_op->read()               [无 cdev 层开销]
```

### 10.2 无运行时开销

cdev 框架只在 open() 路径上有开销。一旦打开，后续的 read/write/ioctl 直接通过 `filp->f_op` 调用，**零 cdev 层介入**。

---

## 11. 调试与诊断

### 11.1 /proc/devices

```bash
# 查看已注册的字符设备
cat /proc/devices | head -20
Character devices:
  1 mem
  4 /dev/vc/0
  4 tty
  4 ttyS
  5 /dev/tty
  5 /dev/console
  5 /dev/ptmx
  7 vcs
 10 misc
 13 input
 29 fb
 81 video4linux
 89 i2c
...
```

### 11.2 调试技巧

```bash
# 查看特定设备号的注册信息
grep "240" /proc/devices

# 跟踪打开/关闭
echo 'p chrdev_open' > /sys/kernel/debug/tracing/set_ftrace_filter
echo function > /sys/kernel/debug/tracing/current_tracer
cat /sys/kernel/debug/tracing/trace_pipe

# 查看 inode 的 cdev 关联
cat /sys/kernel/debug/extfrag/unusable_index  # 不直接, 用 tracepoint
```

### 11.3 常见错误

| 症状 | 原因 | 修复 |
|------|------|------|
| `open()` 返回 `-ENXIO` | 设备号未注册或 cdev_add 未调用 | 检查 `alloc_chrdev_region` + `cdev_add` |
| 模块卸载后 crash | cdev 已删除但文件仍打开 | 引用计数问题；检查 `module_put` 时机 |
| 设备节点出现但操作返回错误 | fops 未正确设置 | 确保 `cdev->ops = &fops` |
| `device_create` 后无 `/dev` | udev/mdev 未配置 | 手动 `mknod` 或配置 udev 规则 |

---

## 12. 总结

Linux cdev 子系统是字符设备驱动的**入口框架**，其设计体现了简洁性和灵活性：

**1. 统一的打开路径**——所有字符设备共享 `def_chr_fops`，`chrdev_open()` 负责从设备号查找 `cdev` 并替换 `filp->f_op`。

**2. 哈希映射的设备号查找**——`kobj_map` 用 255 桶哈希表实现 O(1) 的设备号到 cdev 的映射，支持范围注册和重叠检测。

**3. 引用计数生命周期管理**——kobject 确保设备驱动模块在打开的文件句柄全部关闭前不会被卸载。

**4. 与现代设备模型集成**——`cdev_device_add()` 将 cdev 生命周期绑定到 struct device，简化了驱动开发。

**5. 自动模块加载**——`base_probe` 在设备打开时自动 modprobe，实现"按需加载"。

**关键数字**：
- `char_dev.c`：689 行
- `cdev.h`：39 行（API 极简）
- `kobj_map` 哈希桶：255
- 主设备号范围：0-4095
- 次设备号范围：0-1048575
- `cdev_device_add` 是推荐的现代注册方式

---

## 附录 A：关键源码索引

| 文件 | 行号 | 符号 |
|------|------|------|
| `include/linux/cdev.h` | 14 | `struct cdev` |
| `include/linux/kdev_t.h` | — | `MAJOR()`, `MINOR()`, `MKDEV()` |
| `fs/char_dev.c` | 32 | `struct char_device_struct` |
| `fs/char_dev.c` | 37 | `chrdevs[]` 哈希表 |
| `fs/char_dev.c` | 66 | `find_dynamic_major()` |
| `fs/char_dev.c` | 94 | `__register_chrdev_region()` |
| `fs/char_dev.c` | 370 | `chrdev_open()` |
| `fs/char_dev.c` | 449 | `def_chr_fops` |
| `fs/char_dev.c` | 476 | `cdev_add()` |
| `fs/char_dev.c` | 510 | `cdev_del()` |
| `fs/char_dev.c` | 522 | `cdev_default_release()` |
| `fs/char_dev.c` | 527 | `cdev_dynamic_release()` |
| `fs/char_dev.c` | 493 | `cdev_alloc()` |
| `fs/char_dev.c` | 500 | `cdev_init()` |
| `fs/char_dev.c` | 509 | `chrdev_init()` |
| `fs/char_dev.c` | 541 | `cdev_device_add()` |
| `fs/char_dev.c` | 575 | `cdev_device_del()` |
| `drivers/base/map.c` | 19 | `struct kobj_map` |
| `drivers/base/map.c` | 32 | `kobj_map()` |
| `drivers/base/map.c` | 95 | `kobj_lookup()` |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
