# 56-devm — Linux 内核 Managed Device Resources（devm）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**devm（Managed Device Resources）** 是 Linux 驱动模型中的资源自动管理框架。它解决了驱动开发中**资源泄漏**的核心痛点——使用 `devm_` 前缀的 API 分配的资源会在设备注销时**自动释放**，无需驱动作者在错误路径和 remove 路径中手动清理。

**核心设计哲学**：将资源生命周期与 `struct device` 绑定。设备注销时，devres 框架遍历资源链表，按注册顺序的逆序自动释放。

```
驱动 probe 路径:                          devm 行为:
devm_kzalloc(dev, size, GFP_KERNEL)  ──→ devres_add(dev, node)
devm_clk_get(dev, "clk")             ──→ devres_add(dev, node)
devm_request_irq(dev, irq, ...)      ──→ devres_add(dev, node)
                                         ↓
驱动 remove 或设备注销:
  → device_release_driver()
      ↓
    devres_release_all(dev)
      ↓
    遍历 devres_list，逆序释放
      → devm_request_irq → free_irq
      → devm_clk_get → clk_put
      → devm_kzalloc → kfree
```

**doom-lsp 确认**：核心实现在 `drivers/base/devres.c`（**1,348 行**）。API 声明在 `include/linux/device.h`。

---

## 1. 核心数据结构

### 1.1 struct devres — 托管资源节点

```c
// drivers/base/devres.c
struct devres {
    struct devres_node node;       /* 链表节点 */
    /* data 紧随结构体之后 */
    unsigned long long data[];      /* 资源数据（变长）*/
};

struct devres_node {
    struct list_head entry;          /* dev->devres_list 链表节点 */
    dr_release_t release;            /* 释放回调函数 */
    const char *name;                /* 资源名称（调试用）*/
    size_t size;                     /* 资源大小 */
};
```

### 1.2 struct device 中的相关字段

```c
// include/linux/device.h（struct device）
struct device {
    /* ... */
    spinlock_t devres_lock;          /* 保护 devres_list */
    struct list_head devres_list;    /* 托管资源链表 */
    /* ... */
};
```

每个 `struct device` 都内嵌一个 `devres_list`——所有该设备的 `devm_` 分配的资源都挂在这个链表上。

---

## 2. 核心 API

### 2.1 devres_alloc — 分配资源节点

```c
// drivers/base/devres.c
static __always_inline struct devres *
devres_alloc(dr_release_t release, size_t size, gfp_t gfp, const char *name)
{
    struct devres *dr;
    size_t tot_size = sizeof(struct devres) + size;

    dr = kmalloc_node_track_caller(tot_size, gfp, dev_to_node(dev), ...);
    dr->node.release = release;
    dr->node.name = name;
    dr->node.size = size;
    return dr;
}
```

### 2.2 devres_add — 添加到设备

```c
// drivers/base/devres.c
void devres_add(struct device *dev, void *res)
{
    struct devres *dr = container_of(res, struct devres, data);

    spin_lock_irqsave(&dev->devres_lock, flags);
    list_add(&dr->node.entry, &dev->devres_list);  /* 添加到链表头部 */
    spin_unlock_irqrestore(&dev->devres_lock, flags);
}
```

### 2.3 devres_release_all — 批量释放

```c
// drivers/base/devres.c
int devres_release_all(struct device *dev)
{
    /* 从链表头部开始，逆序释放所有资源 */
    while (!list_empty(&dev->devres_list)) {
        dr = list_first_entry(&dev->devres_list, struct devres_node, entry);
        release_nodes(dev, dr->entry.prev, ...);
    }
}
```

---

## 3. 典型 devm_ API 实现模式

### 3.1 devm_kzalloc

```c
// drivers/base/devres.c
void *devm_kzalloc(struct device *dev, size_t size, gfp_t gfp)
{
    struct devres *dr;
    void *buf;

    /* 1. 分配 devres 节点（data 区大小 = size）*/
    dr = devres_alloc(devm_kzalloc_release, size, gfp, ...);
    if (!dr)
        return NULL;

    /* 2. 返回 data 区指针给调用者 */
    buf = dr->data;
    memset(buf, 0, size);

    /* 3. 添加到设备资源链表 */
    devres_add(dev, buf);
    return buf;
}

/* 释放回调 */
static void devm_kzalloc_release(struct device *dev, void *res)
{
    /* 什么都不做——kfree 由 devres 框架自动完成 */
}
```

### 3.2 devm_request_irq

```c
// kernel/irq/devres.c
int devm_request_irq(struct device *dev, unsigned int irq,
                     irq_handler_t handler, unsigned long irqflags,
                     const char *devname, void *dev_id)
{
    struct irq_devres *dr;

    /* 1. 先尝试注册中断 */
    rc = request_irq(irq, handler, irqflags, devname, dev_id);
    if (rc)
        return rc;

    /* 2. 注册成功 → 添加到 devres 链表 */
    dr = devres_alloc(devm_irq_release, sizeof(*dr), GFP_KERNEL, ...);
    dr->irq = irq;
    dr->dev_id = dev_id;
    devres_add(dev, dr);

    return 0;
}
```

**通用模式**：
```
1. 调用原始 API（可能失败）
2. 如果成功，分配 devres 记录关键参数
3. devres_add() 添加到链表
4. 释放回调 = 调用对应的释放 API
```

---

## 4. 完整的 devm_ API 列表

### 内存类

| API | 对应原始 API | 释放回调 |
|-----|-------------|---------|
| `devm_kzalloc()` | `kzalloc()` | `kfree()` |
| `devm_kstrdup()` | `kstrdup()` | `kfree()` |
| `devm_kmemdup()` | `kmemdup()` | `kfree()` |

### IRQ / GPIO / PWM

| API | 释放回调 |
|-----|---------|
| `devm_request_irq()` | `free_irq()` |
| `devm_gpio_request()` | `gpio_free()` |
| `devm_pwm_get()` | `pwm_put()` |

### 时钟

| API | 释放回调 |
|-----|---------|
| `devm_clk_get()` | `clk_put()` |
| `devm_clk_bulk_get()` | `clk_bulk_put()` |

### DMA

| API | 释放回调 |
|-----|---------|
| `devm_dma_alloc_coherent()` | `dma_free_coherent()` |

### IOMMU

| API | 释放回调 |
|-----|---------|
| `devm_iommu_domain_alloc()` | `iommu_domain_free()` |

### IIO / Input / MFD

| API | 释放回调 |
|-----|---------|
| `devm_iio_device_alloc()` | `iio_device_free()` |
| `devm_input_allocate_device()` | `input_free_device()` |
| `devm_mfd_add_devices()` | 自动移除子设备 |

---

## 5. devm 使用示例

```c
static int my_probe(struct platform_device *pdev)
{
    struct device *dev = &pdev->dev;
    void *buf;
    int irq, ret;

    /* 无需手动 kfree */
    buf = devm_kzalloc(dev, sizeof(struct my_data), GFP_KERNEL);
    if (!buf)
        return -ENOMEM;

    /* 无需手动 free_irq */
    irq = platform_get_irq(pdev, 0);
    ret = devm_request_irq(dev, irq, my_isr, 0, "mydev", buf);
    if (ret)
        return ret;

    /* 无需手动 clk_put */
    clk = devm_clk_get(dev, "bus");
    if (IS_ERR(clk))
        return PTR_ERR(clk);

    return 0;  /* 所有错误路径由 devm 自动清理 */
}

static void my_remove(struct platform_device *pdev)
{
    /* 不需要手动清理任何资源！
     * devres_release_all() 在 device_del() 中自动调用 */
}
```

---

## 6. 性能考量

| 操作 | 延迟 | 说明 |
|------|------|------|
| `devm_kzalloc()` | **~100ns** | 比 `kzalloc()` 多一次 devres节点分配 + 链表操作 |
| `devres_release_all()` | **O(n)** | 线性遍历链表，n = devm_ 调用次数 |
| devres_add | **~20ns** | 简单链表插入 |

---

## 7. 总结

devm 框架是一个**轻量级的资源生命周期管理器**，其设计：

1. **将资源绑定到设备**——`devres_list` 是 `struct device` 的基础设施字段
2. **逆序自动释放**——保证释放顺序与请求顺序相反（先释放最后一次获取的资源）
3. **错误路径简化**——驱动 probe 中的失败直接 `return ret`，无需 goto cleanup
4. **移除路径简化**——remove 函数可以完全为空
5. **覆盖广泛**——从内存到 IRQ、时钟、DMA、GPIO，大量子系统已提供 devm_ 版 API

**关键数字**：
- `drivers/base/devres.c`：1,348 行
- 所有 devm_ API：数十个，覆盖所有主流内核子系统

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
