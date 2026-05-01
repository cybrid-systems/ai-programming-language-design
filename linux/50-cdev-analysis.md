# 50-cdev — 字符设备驱动深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**cdev（字符设备）** 是 Linux 三种标准设备类型之一（字符/块/网络），通过 `struct cdev` 注册字符设备驱动，用户通过 `/dev/*` 设备文件访问。

---

## 1. 注册流程

```c
// 字符设备注册步骤：
struct cdev my_cdev;

cdev_init(&my_cdev, &my_fops);      // 绑定 file_operations
my_cdev.owner = THIS_MODULE;

dev_t dev;
alloc_chrdev_region(&dev, 0, 1, "mydev"); // 分配设备号

cdev_add(&my_cdev, dev, 1);          // 注册到内核

// file_operations 示例：
static const struct file_operations my_fops = {
    .owner   = THIS_MODULE,
    .open    = my_open,
    .read    = my_read,
    .write   = my_write,
    .release = my_release,
};
```

---

*分析工具：doom-lsp（clangd LSP）*
