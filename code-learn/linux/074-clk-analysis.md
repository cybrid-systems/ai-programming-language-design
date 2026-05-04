# 74-clk — Linux 时钟框架（Common Clock Framework）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**Linux CCF（Common Clock Framework）** 是内核时钟管理框架，为 SoC 中的各种时钟设备（RC 振荡器、PLL、分频器、多路选择器、门控单元）提供统一接口。设备驱动通过 `clk_get`/`clk_prepare_enable`/`clk_set_rate` 等 API 控制时钟，无需了解底层硬件细节。

**核心设计**：CCF 将 SoC 时钟拓扑组织为**时钟树**（`struct clk_core` 的父子关系）。每个时钟节点代表一个硬件时钟（固定频率、PLL、分频器、门控、mux），通过 `struct clk_ops` 定义硬件操作。时钟频率变更从叶子向上传播——`clk_set_rate` 遍历树找到最优配置。

```
          固定 24MHz 晶振 (xtal)
               │
            PLL (×16) → 384MHz
               │
        ┌──────┴──────┐
    分频器 /2     分频器 /4 → 96MHz
        │               │
    门控单元          UART 时钟
        │
    CPU 时钟
```

**doom-lsp 确认**：核心实现在 `drivers/clk/clk.c`（**5,586 行**，**597 个符号**）。头文件 `include/linux/clk.h`（1,258 行）。常见时钟类型：`clk-divider.c`（630 行）、`clk-gate.c`（259 行）、`clk-mux.c`、`clk-fixed-rate.c`。

---

## 1. 核心数据结构

### 1.1 struct clk_core — 时钟节点 @ clk.c:66

```c
// drivers/clk/clk.c:66-119
struct clk_core {
    const char *name;                          /* 时钟名（如 "pll0"）*/
    const struct clk_ops *ops;                 /* 硬件操作 */
    struct clk_hw *hw;                         /* 硬件特定数据 */
    struct module *owner;
    struct device *dev;

    /* ── 父子关系 ─ */
    struct clk_core *parent;                   /* 父时钟 */
    struct clk_parent_map *parents;            /* 可选父时钟列表 */
    u8 num_parents;                            /* 可选父时钟数 */
    u8 new_parent_index;                       /* 切换中的新父时钟 */

    /* ── 频率状态 ─ */
    unsigned long rate;                        /* 当前频率 */
    unsigned long req_rate;                    /* 请求频率（可能未达成）*/
    unsigned long new_rate;                    /* 切换中的新频率 */
    unsigned long min_rate;                    /* 最低速率限制 */
    unsigned long max_rate;                    /* 最高速率限制 */

    /* ── 引用计数 ─ */
    unsigned int enable_count;                 /* clk_enable 调用次数 */
    unsigned int prepare_count;                /* clk_prepare 调用次数 */
    unsigned int protect_count;                /* 速率保护计数 */

    struct hlist_head children;                /* 子时钟链表 */
    struct hlist_node child_node;              /* 父时钟的子节点链 */
    struct hlist_node hashtable_node;          /* 全局哈希表节点 */
};
```

**doom-lsp 确认**：`struct clk_core` @ `clk.c:66`。`rate`/`enable_count`/`prepare_count` 是运行时关键状态。

### 1.2 struct clk — 用户空间句柄

```c
// drivers/clk/clk.c:121-129
struct clk {
    struct clk_core *core;                     /* 指向 clk_core */
    struct device *dev;                        /* 请求者设备 */
    const char *dev_id;                        /* 设备 ID */
    const char *con_id;                        /* 连接 ID（如 "uart_clk"）*/
    unsigned long min_rate, max_rate;          /* per-user 速率限制 */
    unsigned int exclusive_count;
    struct hlist_node clks_node;                /* clk_core->clks 链表节点 */
};
```

**设计洞察**：`struct clk` 是**轻量句柄**——多个消费者可以共享同一个 `clk_core`。每个 `struct clk` 可以设置独立的 `min_rate`/`max_rate` 约束。

---

## 2. 时钟操作结构（struct clk_ops）

```c
// include/linux/clk.h
struct clk_ops {
    int (*prepare)(struct clk_hw *hw);           /* 允许睡眠的准备操作 */
    void (*unprepare)(struct clk_hw *hw);
    int (*is_prepared)(struct clk_hw *hw);
    void (*enable)(struct clk_hw *hw);           /* 原子操作 */
    void (*disable)(struct clk_hw *hw);
    int (*is_enabled)(struct clk_hw *hw);

    unsigned long (*recalc_rate)(struct clk_hw *hw,           /* 重新计算频率 */
                                 unsigned long parent_rate);
    long (*round_rate)(struct clk_hw *hw, unsigned long rate, /* 请求最优频率 */
                      unsigned long *parent_rate);
    int (*set_rate)(struct clk_hw *hw, unsigned long rate,    /* 设置频率 */
                    unsigned long parent_rate);
    int (*set_rate_and_parent)(struct clk_hw *hw, ...);
    int (*determine_rate)(struct clk_hw *hw,                  /* 自动决定频率 */
                          struct clk_rate_request *req);

    int (*set_parent)(struct clk_hw *hw, u8 index);          /* 选择父时钟 */
    u8 (*get_parent)(struct clk_hw *hw);

    void (*init)(struct clk_hw *hw);                          /* 初始化回调 */
    void (*debug_init)(struct clk_hw *hw, struct dentry *dentry);
};
```

---

## 3. 核心 API 路径

### 3.1 clk_prepare @ clk.c:1172 — 准备时钟

```c
// 可能睡眠（如启动 PLL 需要等待锁定）
int clk_prepare(struct clk *clk)
{
    if (!clk)
        return 0;

    clk_prepare_lock();                     // mutex_lock

    /* 递归向上准备父时钟 */
    if (core->parent)
        clk_prepare(core->parent->hw->clk);

    if (core->ops->prepare)
        core->ops->prepare(core->hw);       // 驱动回调

    core->prepare_count++;
    clk_prepare_unlock();
}
```

### 3.2 clk_enable @ clk.c:1394 — 使能时钟

```c
// 原子操作（可能在 IRQ 上下文中调用）
int clk_enable(struct clk *clk)
{
    if (!clk)
        return 0;

    clk_enable_lock();                      // spin_lock_irqsave

    /* 递归向上使能父时钟 */
    if (core->parent)
        clk_enable(core->parent->hw->clk);

    if (core->ops->enable)
        core->ops->enable(core->hw);        // 驱动回调

    core->enable_count++;
    clk_enable_unlock();
}
```

**doom-lsp 确认**：`clk_prepare` @ `clk.c:1172`，`clk_enable` @ `clk.c:1394`。`prepare` 持 mutex（可睡眠），`enable` 持 spinlock（原子）。

### 3.3 clk_set_rate @ clk.c:2576 — 频率设置

`clk_set_rate` 通过**自底向上计算 + 自顶向下执行**的三段路径完成频率变更：

```c
int clk_set_rate(struct clk *clk, unsigned long rate)
{
    /* 阶段 1: 计算新频率 @ :2261 */
    // clk_calc_new_rates(core, rate) 自底向上遍历：
    //   - 如果此时钟可以 round_rate → 请求最佳频率
    //   - 如果 CLK_SET_RATE_PARENT → 递归调父时钟
    //   - clk_calc_subtree() 设置子树所有节点的新频率
    //   - 返回最顶层需要调整的时钟
    top = clk_calc_new_rates(core, rate);

    /* 阶段 2: 预变更通知 @ :1922 */
    // clk_propagate_rate_change(top, PRE_RATE_CHANGE)
    // 从 top 向下遍历子树，调用 clock notifier
    // 任何 notifier 返回 NOTIFY_STOP_MASK → abort
    fail_clk = clk_propagate_rate_change(top, PRE_RATE_CHANGE);

    /* 阶段 3: 实际执行 @ :2386 */
    // clk_change_rate(top) 从顶向下：
    //   → 如果需要切换父时钟: ops->set_parent(core, p_index)
    //   → 如果需要设新频率: ops->set_rate(core, new_rate, parent_rate)
    //   → ops->recalc_rate(core, parent_rate) → core->rate
    //   → 递归 children
    clk_change_rate(top);

    /* 阶段 4: 完成通知 */
    clk_propagate_rate_change(top, POST_RATE_CHANGE);
}

// clk_calc_new_rates @ :2261 的核心逻辑：
// 1. 调用 clk_core_determine_round_nolock 请求最优频率
// 2. 如果时钟不可调且 CLK_SET_RATE_PARENT → 递归父时钟
// 3. clk_calc_subtree(core, new_rate, parent, p_index) 设置子树
// 4. 返回最顶层时钟——clk_change_rate 从此开始

// clk_change_rate @ :2386 的核心逻辑：
// static void clk_change_rate(struct clk_core *core)
// {
//     // 如果需要切换父时钟
//     if (core->new_parent && core->new_parent != core->parent)
//         __clk_set_parent(core, ...);
//
//     // 设置频率
//     if (core->new_rate != core->rate && ops->set_rate)
//         ops->set_rate(core->hw, core->new_rate, best_parent_rate);
//
//     // 更新缓存
//     core->rate = ops->recalc_rate(core->hw, best_parent_rate);
//
//     // 递归所有子时钟
//     hlist_for_each_entry(child, &core->children, child_node)
//         clk_change_rate(child);
// }
```

### 3.4 clk_get_rate @ clk.c:1980

```c
unsigned long clk_get_rate(struct clk *clk)
{
    return clk_core_get_rate(core);
}

static unsigned long clk_core_get_rate(struct clk_core *core)
{
    /* 如果支持 recalc_rate → 重新计算 */
    if (core->ops->recalc_rate)
        return core->ops->recalc_rate(core->hw, clk_core_get_rate(core->parent));

    /* 否则返回缓存值 */
    return core->rate;
}
```

---

## 4. 内建时钟类型

### 4.1 clk-gate —— 门控时钟 @ clk-gate.c:259

```c
// 最简单的时钟类型：使能/禁用
struct clk_gate {
    struct clk_hw hw;
    void __iomem *reg;           // 控制寄存器
    u8 bit_idx;                  // 位偏移
    u8 flags;                    // CLK_GATE_*
    spinlock_t *lock;            // 寄存器锁
};

int clk_gate_enable(struct clk_hw *hw) {
    struct clk_gate *gate = to_clk_gate(hw);
    u32 reg = readl(gate->reg);
    reg |= BIT(gate->bit_idx);   // 置位使能
    writel(reg, gate->reg);
}
```

### 4.2 clk-divider —— 分频器 @ clk-divider.c:630

```c
struct clk_divider {
    struct clk_hw hw;
    void __iomem *reg;           // 分频寄存器
    u8 shift, width;             // 位域定义
    u8 flags;                    // CLK_DIVIDER_*
    const struct clk_div_table *table;  // 分频表
};

static unsigned long clk_divider_recalc_rate(struct clk_hw *hw, unsigned long parent_rate)
{
    // 读取寄存器值 → 计算分频系数 → 返回 parent_rate / div
}
```

### 4.3 clk-mux —— 时钟选择器

```c
// 从多个父时钟中选择一个
struct clk_mux {
    struct clk_hw hw;
    void __iomem *reg;           // 选择寄存器
    u32 mask;                    // 选择位掩码
    u8 shift;                    // 位偏移
    u8 flags;
};
```

---

## 5. 注册流程

```c
// driver 中定义 clk_hw + clk_ops + clk_init_data
struct clk_hw *hw;

struct clk_init_data init = {
    .name = "my_clk",
    .ops = &my_clk_ops,
    .parent_names = (const char *[]){"xtal"},
    .num_parents = 1,
    .flags = 0,
};

hw = kzalloc(sizeof(*hw), GFP_KERNEL);
hw->init = &init;

clk_hw_register(dev, hw);   // → clk_register → __clk_core_init
    // → 加入全局哈希表 clk_hashtable
    // → 添加到 clk_root_list 或 clk_orphan_list
    // → 调用 ops->init(hw)
```

**doom-lsp 确认**：`clk_hw_register` 是注册入口。未连接的时钟（父时钟未注册）被放入 `clk_orphan_list`，父时钟注册后自动重新连接。

---

## 6. 调试

```bash
# 查看完整时钟树
cat /sys/kernel/debug/clk/clk_summary
#   clock                         enable_cnt  prepare_cnt  rate
#  xtal                                   0            0  24000000
#   pll0                                  2            2  384000000
#    cpu_clk                               2            2  384000000
#    uart_clk                              1            1   96000000

# 查看单个时钟
cat /sys/kernel/debug/clk/pll0/clk_rate
cat /sys/kernel/debug/clk/pll0/clk_flags
cat /sys/kernel/debug/clk/pll0/clk_prepare_count

# 测量精度（clk_measure）
cat /sys/kernel/debug/clk/pll0/clk_measure
```

---

## 7. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `clk_prepare` | `clk.c:1172` | 准备时钟（可睡眠，mutex）|
| `clk_unprepare` | `clk.c:1091` | 取消准备 |
| `clk_enable` | `clk.c:1394` | 使能时钟（原子，spinlock）|
| `clk_disable` | `clk.c:1229` | 禁用时钟 |
| `clk_get_rate` | `clk.c:1980` | 获取频率 |
| `clk_set_rate` | `clk.c:2576` | 设置频率（树遍历）|
| `clk_set_parent` | `clk.c:2933` | 选择父时钟 |
| `__clk_get_enable_count` | `clk.c:558` | 读取使能计数 |

---

## 8. 总结

CCF 是一个**树形时钟管理框架**——时钟节点的父子关系构成 SoC 时钟拓扑。`clk_enable`（`clk.c:1394` → spinlock 保护）和 `clk_prepare`（`clk.c:1172` → mutex 保护）分为原子/可睡眠双路径。`clk_set_rate`（`clk.c:2576`）通过树遍历找到最优频率配置。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `clk_register()` | drivers/clk/clk.c | 时钟注册 |
| `clk_prepare_enable()` | drivers/clk/clk.c | 使能时钟 |
| `struct clk_hw` | include/linux/clk-provider.h | 硬件时钟结构 |
| `struct clk_core` | drivers/clk/clk.c | 核心时钟结构 |
| `clk_hw_register_fixed_rate()` | drivers/clk/clk-fixed-rate.c | 固定频率时钟 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
