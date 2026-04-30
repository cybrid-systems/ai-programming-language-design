# devm — 设备资源管理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/base/devres.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**devm**（Device Managed Resources）自动管理设备生命周期，避免内存泄漏和 use-after-free：
- 分配：`devm_kmalloc()` — 设备专属内存，超出 scope 自动释放
- 释放：无需手动调用 free，设备卸载时自动完成

---

## 1. 核心数据结构

### 1.1 devres_node — 资源节点

```c
// drivers/base/devres.c — devres_node
struct devres_node {
    struct list_head        entry;         // 链表
    unsigned long           flags;        // 标志
    unsigned int            size;         // 资源大小
};

struct devres {
    struct devres_node      node;
    unsigned long long      data[];        // 实际数据
};
```

### 1.2 devres_group — 资源组（用于批量释放）

```c
// drivers/base/devres.c — devres_group
struct devres_group {
    struct devres_node      node;         // 基类
    struct list_head        children;     // 子资源链表
    void                   *id;          // 组 ID
    unsigned long           flags;       // DRESS_GROUP_* 标志
};
```

### 1.3 devres_entry — 资源条目（per-device）

```c
// drivers/base/devres.c — devres_entry
struct devres_entry {
    struct devres_node      node;         // 基类
    struct device           *device;       // 所属设备
    void                   *data;        // 资源数据
    devres_release_t        release;     // 释放函数
};
```

---

## 2. 分配（devm_kmalloc）

```c
// drivers/base/devres.c — devm_kmalloc
void *devm_kmalloc(struct device *dev, size_t size, gfp_t gfp)
{
    struct devres *res;

    // 1. 分配 devres 结构（含数据）
    res = alloc_dr(devres, sizeof(*res) + size, gfp);
    if (!res)
        return NULL;

    // 2. 初始化
    res->release = kfree;  // 释放函数

    // 3. 加入设备的 devres 链表
    devres_add(dev, &res->node);

    return res->data;  // 返回数据部分
}
```

### 2.1 alloc_dr — 分配 devres

```c
// drivers/base/devres.c — alloc_dr
static struct devres *alloc_dr(release_t release, size_t size, gfp_t gfp)
{
    struct devres *res;

    // 分配 devres + 数据
    res = kmalloc(sizeof(*res) + size, gfp | __GFP_ZERO);
    if (!res)
        return NULL;

    res->node.data = res;  // data 指向自身

    return res;
}
```

### 2.2 devres_add — 加入链表

```c
// drivers/base/devres.c — devres_add
void devres_add(struct device *dev, struct devres_node *node)
{
    spin_lock(&dev->devres_lock);

    // 加入全局 devres 链表
    list_add_tail(node->entry, &dev->devres_head);

    // 记录设备指针
    node->dev = dev;

    spin_unlock(&dev->devres_lock);
}
```

---

## 3. 释放（devres_release）

### 3.1 device_release_driver → devres_release_all

```c
// drivers/base/driver.c — device_release_driver
static void device_release_driver(struct device *dev)
{
    // 设备卸载时：
    // 1. 解绑驱动
    // 2. 释放所有 devres
    devres_release_all(dev);
}
```

### 3.2 devres_release_all — 释放所有资源

```c
// drivers/base/devres.c — devres_release_all
int devres_release_all(struct device *dev)
{
    struct devres_entry *ent;

    // 遍历所有 devres_entry
    while (!list_empty(&dev->devres_head)) {
        ent = list_first_entry(&dev->devres_head,
                               struct devres_entry, node.entry);

        // 调用 release 函数
        ent->release(ent->data);

        // 从链表移除
        list_del(&ent->node.entry);

        // 释放 devres_entry
        kfree(ent);
    }

    return 0;
}
```

---

## 4. 常用 devm API

```c
// 内存
void *devm_kmalloc(struct device *dev, size_t size, gfp_t gfp);
void *devm_kzalloc(struct device *dev, size_t size, gfp_t gfp);
void  devm_kfree(struct device *dev, void *p);

// GPIO
int devm_gpio_request(struct device *dev, unsigned gpio, const char *label);
void devm_gpio_free(struct device *dev, unsigned gpio);

// IRQ
int devm_request_threaded_irq(struct device *dev, unsigned irq,
                               irq_handler_t handler, irq_handler_t thread_fn,
                               unsigned long irqflags, const char *devname,
                               void *dev_id);
void devm_free_irq(struct device *dev, unsigned int irq, void *dev_id);

// 时钟
struct clk *devm_clk_get(struct device *dev, const char *id);
void devm_clk_put(struct device *dev, struct clk *clk);

// DMA
void *dmam_alloc_coherent(struct device *dev, size_t size,
                           dma_addr_t *dma_handle, gfp_t gfp);
void devm_dma_free(struct device *dev, size_t size, void *vaddr, dma_addr_t dma_handle);
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/base/devres.c` | `devm_kmalloc`、`devres_add`、`devres_release_all` |
| `include/linux/device.h` | `devm_kmalloc` 声明 |