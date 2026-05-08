# 74-clk — Linux Common Clock Framework (CCF) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-08 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Common Clock Framework（CCF）** 是 Linux 内核的通用时钟管理子系统，提供一个统一的框架来管理 SoC 上的时钟树（clock tree）。每个时钟节点（如 PLL、分频器、门控、多路选择器）都抽象为 `struct clk_core`，形成从根晶振到外设时钟的树状结构。

**核心抽象**：

```
struct clk_core (内部核心)
    ↑ 用户接口
struct clk (消费者句柄)
    ↑ 驱动接口
struct clk_hw + struct clk_ops (硬件操作)
    ↑ 硬件
SoC 时钟寄存器
```

**两个关键设计**：
1. **prepare/enable 分离**：prepare 可能睡眠（I2C 配置时钟芯片），enable 保持原子（寄存器 MMIO 操作）
2. **引用计数**：`prepare_count` 和 `enable_count` 分别跟踪，支持嵌套调用

---

## 1. 核心数据结构

### 1.1 struct clk_core — 时钟节点 @ clk.c:66

```c
// drivers/clk/clk.c:66
struct clk_core {
    const char *name;
    const struct clk_ops *ops;              /* 驱动操作回调 */
    struct clk_hw *hw;                      /* 硬件数据 */
    struct module *owner;
    struct device *dev;
    struct device_node *of_node;
    struct clk_core *parent;                /* 父时钟指针 */
    struct clk_parent_map *parents;         /* 可选父时钟列表 */
    u8 num_parents;
    u8 new_parent_index;
    unsigned long rate;                     /* 当前频率 */
    unsigned long req_rate;                 /* 请求频率 */
    unsigned long new_rate;                 /* 切换中的目标频率 */
    struct clk_core *new_parent;
    struct clk_core *new_child;
    unsigned long flags;                    /* CLK_* 标志 */
    bool orphan;                            /* 父时钟未就绪？ */
    unsigned int enable_count;              /* enable 引用计数 */
    unsigned int prepare_count;             /* prepare 引用计数 */
    unsigned int protect_count;             /* rate 保护计数 */
    unsigned long min_rate, max_rate;
    unsigned long accuracy;
    int phase;                              /* 相位偏移度 */
    struct clk_duty duty;                   /* 占空比 */
    struct hlist_head children;             /* 子时钟链表 */
    struct hlist_node child_node;
    struct hlist_node hashtable_node;       /* 全局哈希表 */
    struct hlist_head clks;                 /* 指向此 core 的所有句柄 */
    struct kref ref;
};
```

**关键字段**：
- `parent` / `children`：构成时钟树的双向关系
- `orphan`：父时钟尚未注册的节点暂存于 `clk_orphan_list`
- `rate` / `req_rate` / `new_rate`：支持原子频率切换（rate transition）

### 1.2 struct clk — 消费者句柄

```c
// drivers/clk/clk.c
struct clk {
    struct clk_core *core;         /* 指向内部时钟节点 */
    struct device *dev;
    const char *dev_id;
    const char *con_id;
    unsigned long min_rate;
    unsigned long max_rate;
    unsigned int exclusive_count;
    struct hlist_node clks_node;
};
```

`struct clk` 是消费者看到的句柄，所有 API（`clk_get_rate()`、`clk_prepare_enable()`）都通过 `core` 指针转发到底层操作。

### 1.3 struct clk_hw — 硬件接口 @ clk-provider.h:320

```c
// include/linux/clk-provider.h:320
struct clk_hw {
    struct clk *clk;          /* 注册时框架设置 */
    const struct clk_init_data *init; /* 注册用的初始化数据（登记后置 NULL）*/
};
```

驱动提供者分配 `struct clk_hw`（或嵌入在自定义结构体中），填充 `init`，然后调用 `clk_hw_register()` 或 `devm_clk_hw_register()`。

### 1.4 struct clk_ops — 时钟操作回调

```c
// include/linux/clk-provider.h
struct clk_ops {
    int (*prepare)(struct clk_hw *hw);           /* 可睡眠的准备 */
    void (*unprepare)(struct clk_hw *hw);
    int (*is_prepared)(struct clk_hw *hw);

    int (*enable)(struct clk_hw *hw);             /* 原子使能 */
    void (*disable)(struct clk_hw *hw);
    int (*is_enabled)(struct clk_hw *hw);

    int (*save_context)(struct clk_hw *hw);       /* PM 上下文保存 */
    void (*restore_context)(struct clk_hw *hw);

    unsigned long (*recalc_rate)(struct clk_hw *hw,
                                 unsigned long parent_rate);
    int (*determine_rate)(struct clk_hw *hw,
                          struct clk_rate_request *req);
    int (*set_parent)(struct clk_hw *hw, u8 index);
    u8 (*get_parent)(struct clk_hw *hw);
    int (*set_rate)(struct clk_hw *hw,
                    unsigned long rate,
                    unsigned long parent_rate);
    int (*set_rate_and_parent)(struct clk_hw *hw,
                               unsigned long rate,
                               unsigned long parent_rate,
                               unsigned int index);
    int (*round_rate)(struct clk_hw *hw,
                      unsigned long rate,
                      unsigned long *parent_rate);
    long (*round_rate_long)(struct clk_hw *hw,
                            unsigned long rate,
                            unsigned long *parent_rate);
    int (*init)(struct clk_hw *hw);               /* 初始化回调 */
    void (*terminate)(struct clk_hw *hw);
    int (*debug_init)(struct clk_hw *hw, struct dentry *dentry);
    /* ... phase, duty_cycle 等 ... */
};
```

**prepare / enable 分离**：
- `prepare` 可以睡眠（I2C/SPI 访问时钟芯片）
- `enable` 必须原子（读写 MMIO 寄存器）
- 调用顺序：`clk_prepare()` → `clk_enable()` → ... → `clk_disable()` → `clk_unprepare()`
- 便捷函数：`clk_prepare_enable()` / `clk_disable_unprepare()`

---

## 2. 注册流程

### 2.1 __clk_register @ clk.c:4306 — 核心注册

```c
// drivers/clk/clk.c:4306
__clk_register(struct device *dev, struct device_node *np, struct clk_hw *hw)
{
    const struct clk_init_data *init = hw->init;

    /* 注册后清除 init 指针，防止驱动误用 */
    hw->init = NULL;

    /* 1. 分配 clk_core */
    core = kzalloc_obj(*core);

    /* 2. 复制基本信息 */
    core->name = kstrdup_const(init->name, GFP_KERNEL);
    core->ops = init->ops;
    core->dev = dev;
    core->of_node = np;
    core->hw = hw;
    core->flags = init->flags;
    core->num_parents = init->num_parents;

    /* 3. 解析父时钟列表 */
    clk_core_populate_parent_map(core, init);

    /* 4. 创建消费者句柄 */
    hw->clk = alloc_clk(core, NULL, NULL);
    clk_core_link_consumer(core, hw->clk);

    /* 5. 初始化时钟节点（插入树、计算初始频率等）*/
    ret = __clk_core_init(core);

    return hw->clk;
}
```

### 2.2 __clk_core_init @ clk.c:3877 — 节点初始化

```c
// drivers/clk/clk.c:3877
static int __clk_core_init(struct clk_core *core)
{
    /* 1. 处理父子关系 */
    parent = clk_core_get_parent(core);
    if (parent) {
        hlist_add_head(&core->child_node, &parent->children);
        core->orphan = parent->orphan;
    } else if (!core->num_parents) {
        hlist_add_head(&core->child_node, &clk_root_list);    /* 根时钟 */
    } else {
        hlist_add_head(&core->child_node, &clk_orphan_list);  /* 孤子 */
        core->orphan = true;
    }

    /* 2. 加入全局哈希表（名称查找）*/
    hash_add(clk_hashtable, &core->hashtable_node,
             full_name_hash(NULL, core->name, strlen(core->name)));

    /* 3. 计算初始 accuracy */
    if (core->ops->recalc_accuracy)
        core->accuracy = core->ops->recalc_accuracy(core->hw, ...);
    else if (parent)
        core->accuracy = parent->accuracy;
    else
        core->accuracy = 0;

    /* 4. 缓存初始 phase 和 duty cycle */
    core->phase = clk_core_get_phase(core);
    clk_core_update_duty_cycle_nolock(core);

    /* 5. 计算初始频率 */
    if (core->ops->recalc_rate)
        core->rate = core->ops->recalc_rate(core->hw, ...);
    else if (parent)
        core->rate = parent->rate;
    else
        core->rate = 0;

    /* 6. 调用驱动的 init 回调 */
    if (core->ops->init)
        core->ops->init(core->hw);
}
```

### 2.3 注册 API 层次

```c
// 老式 API（已废弃，保持兼容）
struct clk *clk_register(struct device *dev, struct clk_hw *hw)
    → return __clk_register(dev, dev_or_parent_of_node(dev), hw);  // @ clk.c:4430

// 推荐 API
int clk_hw_register(struct device *dev, struct clk_hw *hw)
    → return PTR_ERR_OR_ZERO(__clk_register(dev, ...));          // @ clk.c:4448

// DT 节点注册（无 struct device）
int of_clk_hw_register(struct device_node *node, struct clk_hw *hw)
    → return PTR_ERR_OR_ZERO(__clk_register(NULL, node, hw));    // @ clk.c:4466

// 资源管理版本
struct clk *devm_clk_register(struct device *dev, struct clk_hw *hw);  // @ clk.c:4633
```

**注册流程总结**：

```
clk_hw_register(dev, hw)           @ clk.c:4448
    ↓
__clk_register(dev, np, hw)        @ clk.c:4306
    │
    ├─ kzalloc: struct clk_core
    ├─ core->ops = init->ops
    ├─ clk_core_populate_parent_map()
    ├─ alloc_clk() → hw->clk
    └─ __clk_core_init(core)        @ clk.c:3877
            │
            ├─ hlist_add: children/root/orphan
            ├─ hash_add: clk_hashtable
            ├─ recalc_rate() → core->rate
            └─ init() → 驱动初始化
    ↓
hw->clk 返回（通过 clk_get() 可获取）
```

---

## 3. 时钟操作的核心路径

### 3.1 clk_prepare / clk_unprepare

`clk_prepare()`（@ clk.c:1172）→ `clk_core_prepare_lock()`（@ clk.c:1149）→ `clk_core_prepare()`（@ clk.c:1100）：

```c
static int clk_core_prepare(struct clk_core *core)
{
    int ret = 0;

    if (core->prepare_count == 0) {
        /* 递归：先 prepare 父时钟 */
        ret = clk_core_prepare(core->parent);
        if (ret) return ret;

        /* 调用驱动回调 */
        if (core->ops->prepare)
            ret = core->ops->prepare(core->hw);
        if (ret) goto unprepare;
    }

    core->prepare_count++;
    return 0;
}
```

**关键特性**：prepare 是**自顶向下**递归的——先准备父时钟再准备自身。引用计数允许同一时钟被多个消费者 prepare 而不会重复操作硬件。

### 3.2 clk_enable / clk_disable

`clk_enable()`（@ clk.c:1394）→ `clk_core_enable_lock()` → `clk_core_enable()`：

```c
// clk_core_enable — 递归使能父时钟
static void clk_core_enable(struct clk_core *core)
{
    if (core->enable_count == 0) {
        clk_core_enable(core->parent);       /* 先使能父时钟 */
        if (core->ops->enable)
            core->ops->enable(core->hw);     /* 调用原子使能 */
    }
    core->enable_count++;
}
```

**关键设计**：使能同样递归——先使能父时钟，使时钟树的每个节点都处于可工作状态。

### 3.3 clk_set_rate — 频率设置

```c
clk_set_rate(clk, rate)
    ↓
clk_core_set_rate_nolock(core, rate)
    ↓
1. 调用 ops->determine_rate() 或 __clk_mux_determine_rate()
   → 计算最佳分频组合，确定是否需要换父时钟
    ↓
2. clk_core_set_rate(core, req.rate, req.best_parent_rate)
    ↓
3. clk_change_rate(core)  — 自上而下传播
    ↓
   clk_core_set_rate_and_parent() 或 clk_core_set_rate()
   → ops->set_rate_and_parent() 或 ops->set_rate()
```

**频率传播**：当一个时钟改变频率时，所有依赖它的子时钟通过树遍历重新计算频率。

---

## 4. 内置时钟类型（providers）

CCF 提供了几种常用的硬件抽象时钟类型：

| 时钟类型 | 头文件 | 说明 |
|---------|--------|------|
| **fixed_rate** | `clk-fixed-rate.c` | 固定频率（晶振） |
| **fixed_factor** | `clk-fixed-factor.c` | 固定分频/倍频 |
| **gate** | `clk-gate.c` | 门控时钟（on/off） |
| **divider** | `clk-divider.c` | 可分频时钟 |
| **mux** | `clk-mux.c` | 多路选择器 |
| **fractional_divider** | `clk-fractional-divider.c` | 小数分频 |
| **composite** | `clk-composite.c` | gate + divider + mux 组合 |

### gate 时钟示例

```c
#define to_clk_gate(_hw) container_of(_hw, struct clk_gate, hw)

static int clk_gate_enable(struct clk_hw *hw)
{
    struct clk_gate *gate = to_clk_gate(hw);
    unsigned long flags;

    spin_lock_irqsave(gate->lock, flags);
    clk_gate_set_bit(gate);      /* writel(reg, val | bit) */
    spin_unlock_irqrestore(gate->lock, flags);
    return 0;
}
```

### divider 时钟示例

```c
static unsigned long clk_divider_recalc_rate(struct clk_hw *hw,
                                             unsigned long parent_rate)
{
    struct clk_divider *divider = to_clk_divider(hw);
    unsigned int val;

    val = clk_readl(divider->reg) >> divider->shift;
    val &= clk_div_mask(divider->width);  /* 读取分频值 */
    return divider_recalc_rate(hw, parent_rate, val, divider->table,
                               divider->flags, divider->width);
}
```

---

## 5. 时钟树管理

### 5.1 树结构

```
clk_root_list (全局根节点链表)
    │
    ├─ clk_core (xtal)
    │   └─ children: clk_core (pll)
    │       └─ children: clk_core (divider)
    │           └─ children: clk_core (gate)→外设
    │
    └─ clk_core (osc)
        └─ children: ...

clk_orphan_list (父时钟未注册的节点)
    └─ clk_core (某外设时钟，等待PLL就绪)
```

### 5.2 孤子处理

当 `__clk_core_init()` 发现父时钟不在树中时，将节点挂入 `clk_orphan_list`。当父时钟后来注册时：

```
__clk_core_init(parent)
    → 触发 clk_core_reparent_orphans()
    → 遍历 orphan 列表，重新连接可匹配的子节点
    → 设置 core->orphan = false
```

### 5.3 全局查找

所有时钟通过 `clk_hashtable` 哈希表索引，支持 O(1) 名称查找。`clk_get()` 通过 `of_clk_get_by_name()` 或 `clk_find_hw()` 查找。

---

## 6. 关键同步设计

### 6.1 两把大锁

```c
static DEFINE_MUTEX(prepare_lock);    /* clk_prepare/unprepare 的睡眠锁 */
static DEFINE_SPINLOCK(enable_lock);  /* clk_enable/disable 的原子自旋锁 */
```

- `prepare_lock`：保护时钟树结构变更（注册、取消注册、set_parent、set_rate）
- `enable_lock`：保护引用计数操作（enable/disable，在原子上下文使用）

### 6.2 CLK_SET_RATE_GATE

当设置了此标志，时钟在 prepare 状态下禁止频率变更——防止频率切换时输出不稳定时钟。

```c
if (core->flags & CLK_SET_RATE_GATE)
    clk_core_rate_protect(core);   /* ⬆ protect_count */
```

### 6.3 CLK_IS_CRITICAL

关键时钟（如 DDR 控制器时钟）不能被禁用。框架在 disable 时检查：

```c
if (WARN(core->enable_count == 1 && core->flags & CLK_IS_CRITICAL,
         "Disabling critical %s\n", core->name))
    return;
```

---

## 7. 典型驱动使用模式

### 7.1 消费者使用

```c
/* probe 中 */
struct clk *clk;

clk = devm_clk_get(dev, "bus");           /* 获取时钟句柄 */
if (IS_ERR(clk))
    return PTR_ERR(clk);

ret = clk_prepare_enable(clk);             /* prepare + enable */
if (ret)
    return ret;

/* 使用时钟... */

clk_disable_unprepare(clk);                /* disable + unprepare */
```

### 7.2 提供者注册

```c
// drivers/clk/clk-fixed-rate.c
struct clk_fixed_rate {
    struct clk_hw hw;
    unsigned long fixed_rate;
    unsigned long fixed_accuracy;
};

static const struct clk_ops clk_fixed_rate_ops = {
    .recalc_rate = clk_fixed_rate_recalc_rate,
    .round_rate = clk_fixed_rate_round_rate,
};

struct clk_hw *clk_hw_register_fixed_rate(struct device *dev, ...)
{
    struct clk_fixed_rate *fixed;

    fixed = kzalloc_obj(*fixed);
    fixed->fixed_rate = rate;
    fixed->hw.init = CLK_HW_INIT(name, NULL, &clk_fixed_rate_ops, 0);

    return clk_hw_register(dev, &fixed->hw);   /* @ clk.c:4448 */
}
```

### 7.3 频率切换模式

```
round-trip 模式：
  1. driver: clk_set_rate(clk, target_rate)
  2. framework: ops->determine_rate(hw, &req)
     → 返回最接近且硬件支持的频率
  3. framework: ops->set_rate(hw, rate, parent_rate)
     → 写入分频寄存器
  4. framework: ops->recalc_rate(hw, parent_rate)
     → 读寄存器确认实际频率
```

---

## 8. debugfs 接口

CCF 通过 debugfs 提供时钟树调试信息（`clk_debug_init`）：

```
/sys/kernel/debug/clk/
├── clk_summary        → 所有时钟状态摘要
├── clk_dump           → 完整时钟树 dump
├── <clock-name>/      → 每个时钟的目录
    ├── clk_rate
    ├── clk_enabled
    ├── clk_prepared
    ├── clk_flags
    └── clk_notifier_count
```

---

## 9. 总结

| 概念 | 实现 | 位置 |
|------|------|------|
| **时钟节点** | `struct clk_core` 含 rate/count/parent/children | `clk.c:66` |
| **消费者句柄** | `struct clk` 包裹 core 指针 | `clk.c` |
| **硬件抽象** | `struct clk_hw` + `struct clk_ops` | `clk-provider.h:320` |
| **注册** | `__clk_register` → `__clk_core_init` | `clk.c:4306` |
| **prepare 路径** | 递归自顶向下，I2C 友好 | `clk.c:1100` |
| **enable 路径** | 递归原子使能 | `clk.c` |
| **频率设置** | `determine_rate` → `set_rate` → `recalc_rate` | `clk.c` |
| **树结构** | clk_root_list / clk_orphan_list / clk_hashtable | `clk.c` |
| **同步** | prepare_lock(mutex) + enable_lock(spinlock) | `clk.c` |
| **内置类型** | fixed/gate/divider/mux/composite | `drivers/clk/` |

**完整调用链（外设启用时钟）**：

```
devm_clk_get(dev, "clk_name")            → struct clk * (from DT/table)
    ↓
clk_prepare_enable(clk)
    │
    ├─ clk_prepare()                     @ clk.c:1172
    │   └─ clk_core_prepare_lock()
    │       └─ clk_core_prepare(core)    @ clk.c:1100
    │           └─ clk_core_prepare(core->parent)  ← 递归父时钟
    │               └─ ...递归到根
    │                   └─ ops->prepare(hw)
    │
    └─ clk_enable()                      @ clk.c:1394
        └─ clk_core_enable_lock()
            └─ clk_core_enable(core)
                └─ clk_core_enable(core->parent)   ← 递归父时钟
                    └─ ops->enable(hw)              ← 原子 MMIO 写入
```

---

### 源码索引（LSP 验证）

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct clk_core` | drivers/clk/clk.c | 66 |
| `struct clk_ops` | include/linux/clk-provider.h | ~180 |
| `struct clk_hw` | include/linux/clk-provider.h | 320 |
| `__clk_register()` | drivers/clk/clk.c | 4306 |
| `__clk_core_init()` | drivers/clk/clk.c | 3877 |
| `clk_register()` | drivers/clk/clk.c | 4430 |
| `clk_hw_register()` | drivers/clk/clk.c | 4448 |
| `devm_clk_register()` | drivers/clk/clk.c | 4633 |
| `clk_prepare()` | drivers/clk/clk.c | 1172 |
| `clk_core_prepare()` | drivers/clk/clk.c | 1100 |
| `clk_core_prepare_lock()` | drivers/clk/clk.c | 1149 |
| `clk_enable()` | drivers/clk/clk.c | 1394 |
| `clk_disable()` | drivers/clk/clk.c | 1229 |
| `clk_unprepare()` | drivers/clk/clk.c | |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-08 | 内核版本：Linux 7.0-rc1*
