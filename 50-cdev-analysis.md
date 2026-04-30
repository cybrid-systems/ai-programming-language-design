# Linux Kernel Character Device / cdev 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/char_dev.c` + `include/linux/cdev.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 cdev？

**cdev** 是字符设备驱动的基础结构，通过 `alloc_chrdev_region()` 注册主设备号，通过 `cdev_init()/cdev_add()` 注册到 VFS。

---

## 1. 注册流程

```c
// fs/char_dev.c — alloc_chrdev_region
int alloc_chrdev_region(dev_t *dev, unsigned baseminor, unsigned count, const char *name)
{
    // 从动态设备号区分配主设备号
    // 将 baseminor ~ baseminor+count-1 的设备号注册到 chrdevs[]
    // chrdevs[major] = name
    return 0;
}

// fs/char_dev.c — cdev_init
void cdev_init(struct cdev *p, const struct file_operations *fops)
{
    p->ops = fops;
    cdev_set_parent(p, &p->kobj);
    kobject_init(&p->kobj, &ktype_cdev_default);
}

// fs/char_dev.c — cdev_add
int cdev_add(struct cdev *p, dev_t dev, unsigned count)
{
    // 将 cdev 添加到系统中
    // 在 /dev 中创建设备节点（通过 udev）
    kobject_add(&p->kobj, &system_kset->kobj, "cdev:%s", name);
    kobject_uevent(&p->kobj, KOBJ_ADD);
}
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `fs/char_dev.c` | `alloc_chrdev_region`、`cdev_init`、`cdev_add` |
| `include/linux/cdev.h` | `struct cdev`、`struct file_operations` |
