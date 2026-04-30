# 195-devtmpfs — 设备文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/base/devtmpfs.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**devtmpfs** 是内核自动在 `/dev` 挂载的内存文件系统，自动创建设备节点，无需 udev 手动创建。

---

## 1. devtmpfs 挂载

```bash
# /dev 通常是 devtmpfs：
mount | grep /dev
# devtmpfs on /dev type devtmpfs (rw,nosuid,relatime,size=...)
```

---

## 2. device_add

```c
// drivers/base/core.c — device_add
void device_add(struct device *dev)
{
    // 1. 注册到 bus
    device_add_class(dev);

    // 2. 自动创建设备节点（devtmpfs）
    if (dev->devt)
        devtmpfs_create_node(dev);

    // 3. uevent 通知 udev
    kobject_uevent(&dev->kobj, KOBJ_ADD);
}
```

---

## 3. 西游记类喻

**devtmpfs** 就像"天庭的自动门牌系统"——

> devtmpfs 像天庭的自动门牌系统——每个新来的神仙（设备）都会自动获得一个门牌（/dev/xxx），无需人工登记。这就是热插拔的基础——设备一插入，门牌就自动出现。

---

## 4. 关联文章

- **device model**（相关）：device_add 是设备注册核心