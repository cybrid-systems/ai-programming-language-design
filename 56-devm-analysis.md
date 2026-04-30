# Linux Kernel devm_* / devres 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/base/devres.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 devres？

**devres（Device Resource Management）** 是 Linux 驱动开发的**资源自动管理**框架——驱动注册的资源在设备卸载时**自动释放**，无需手动 cleanup。

---

## 1. devm_kmalloc

```c
// drivers/base/devres.c — devm_kmalloc
void *devm_kmalloc(struct device *dev, size_t size, gfp_t gfp)
{
    // 分配内存，同时注册到 devres
    struct devres *dr;

    dr = alloc_dr(sizeof(*dr) + size, gfp);
    devres_add(dev, dr);

    return dr->data;
}

// 设备卸载时自动调用：
void devres_release_all(struct device *dev)
{
    // 遍历 devres 链表，按 LIFO 顺序释放
    while (!list_empty(&dev->devres_head)) {
        dr = list_first_entry(&dev->devres_head, devres, entry);
        dr->node->release(dev, dr->data);
    }
}
```

---

## 2. 常用 API

```c
// 内存
devm_kmalloc(dev, size, GFP_KERNEL);
devm_kzalloc(dev, size, GFP_KERNEL);

// I/O
devm_ioremap(dev, phys, size);
devm_ioremap_resource(dev, res);

// 中断
devm_request_threaded_irq(dev, irq, handler, thread_fn, ...);

// clk
devm_clk_get(dev, name);
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/base/devres.c` | `devm_kmalloc`、`devres_add`、`devres_release_all` |
| `include/linux/device.h` | `DECLARE_DEV_POPULATOR` |
