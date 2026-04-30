# cdev — 字符设备注册深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/char_dev.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**cdev**（character device）是字符设备的内核抽象，每个字符设备需要注册一个 `struct cdev`。

---

## 1. 核心数据结构

### 1.1 cdev — 字符设备

```c
// include/linux/cdev.h — cdev
struct cdev {
    // 设备号
    dev_t              dev;           // 主设备号 + 次设备号
    unsigned int       count;         // 次设备号数量

    // 操作函数表
    const struct file_operations *ops; // 文件操作（read/write/ioctl）

    // 链表（用于动态分配）
    struct list_head   list;         // 接入全局 cdev_map

    // 拥有者
    struct kobject     *kobj;        // sysfs 对象

    // 模块引用
    struct module      *owner;        // 所属模块（自动持有引用）
};
```

### 1.2 file_operations — 操作函数表

```c
// include/linux/fs.h — file_operations
struct file_operations {
    loff_t (*llseek)(struct file *, loff_t, int);
    ssize_t (*read)(struct file *, char __user *, size_t, loff_t *);
    ssize_t (*write)(struct file *, const char __user *, size_t, loff_t *);
    int (*open)(struct inode *, struct file *);
    int (*release)(struct inode *, struct file *);
    int (*ioctl)(struct file *, unsigned int, unsigned long);
    // ...
};
```

---

## 2. 注册流程

### 2.1 cdev_init — 初始化 cdev

```c
// fs/char_dev.c — cdev_init
void cdev_init(struct cdev *cdev, const struct file_operations *fops)
{
    cdev->ops = fops;              // 设置操作函数表
    INIT_LIST_HEAD(&cdev->list);  // 初始化链表
    kobject_init(&cdev->kobj);    // 初始化 kobject
}
```

### 2.2 cdev_add — 添加到系统

```c
// fs/char_dev.c — cdev_add
int cdev_add(struct cdev *p, dev_t dev, unsigned int count)
{
    int ret;

    // 1. 设置设备号范围
    p->dev = dev;
    p->count = count;

    // 2. 加入全局字符设备映射表
    ret = kobj_map(chardev_table, dev, count, THIS_MODULE, probe, NULL);
    if (ret < 0)
        return ret;

    // 3. 创建设备类（/sys/class/）
    device_create(class, NULL, dev, NULL, "%s%d", name, minor);

    return 0;
}
```

### 2.3 cdev_del — 注销

```c
// fs/char_dev.c — cdev_del
void cdev_del(struct cdev *p)
{
    // 从映射表移除
    kobj_unmap(chardev_table, p->dev, p->count);

    // 销毁 kobject
    kobject_put(&p->kobj);
}
```

---

## 3. 动态分配设备号

```c
// fs/char_dev.c — alloc_chrdev_region
int alloc_chrdev_region(dev_t *dev, unsigned baseminor, unsigned count,
                        const char *name)
{
    // 动态分配主设备号（> 0）
    // baseminor = 第一个次设备号
    // count = 次设备号数量

    dev_t result = __register_chrdev_region(0, baseminor, count, name);
    *dev = MKDEV(MAJOR(result), baseminor);

    return 0;
}

// 获取主设备号：
// cat /proc/devices | grep <name>
```

---

## 4. 设备类（class）

```c
// drivers/base/core.c — device_create
struct device *device_create(struct class *class, struct device *parent,
                              dev_t dev, void *drvdata,
                              const char *fmt, ...)
{
    // 创建设备节点：
    // /sys/class/<class>/<device>/
    // /dev/<device> (由 udev 根据 sysfs 信息创建)
}
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/char_dev.c` | `cdev_init`、`cdev_add`、`cdev_del`、`alloc_chrdev_region` |
| `include/linux/cdev.h` | `struct cdev` |
| `drivers/base/core.c` | `device_create` |