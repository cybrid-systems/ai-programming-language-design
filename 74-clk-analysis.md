# clk — 时钟管理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/clk/clk.c` + `include/linux/clk.h`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**clk** 子系统统一管理 SoC 的时钟树，每个外设的时钟可独立开关和分频。

---

## 1. 核心数据结构

### 1.1 clk — 时钟

```c
// include/linux/clk.h — clk
struct clk {
    const char              *name;         // 时钟名
    const struct clk_ops     *ops;        // 操作函数
    struct clk_hw            *hw;          // 硬件描述

    // 父子关系
    struct clk               *parent;      // 父时钟
    const char               *parent_name;  // 父时钟名

    // 频率
    unsigned long           rate;         // 当前频率
    unsigned long           rate_request;  // 请求的频率

    // 门控
    unsigned int             enable_count;  // 使能计数
    unsigned int             prepare_count; // 准备计数

    // 标志
    unsigned long           flags;        // CLK_* 标志
};
```

### 1.2 clk_ops — 操作函数表

```c
// include/linux/clk.h — clk_ops
struct clk_ops {
    int                     (*enable)(struct clk_hw *);
    void                    (*disable)(struct clk_hw *);
    int                     (*prepare)(struct clk_hw *);
    void                    (*unprepare)(struct clk_hw *);

    unsigned long           (*recalc_rate)(struct clk_hw *, unsigned long parent_rate);
    long                    (*round_rate)(struct clk_hw *, unsigned long, unsigned long *);
    int                     (*set_rate)(struct clk_hw *, unsigned long, unsigned long);

    int                     (*set_parent)(struct clk_hw *, u8 index);
    u8                      (*get_parent)(struct clk_hw *);
};
```

---

## 2. enable / disable

```c
// drivers/clk/clk.c — clk_enable
int clk_enable(struct clk *clk)
{
    int ret = 0;

    if (!clk)
        return 0;

    // 1. 递归使能父时钟
    if (clk->parent)
        clk_enable(clk->parent);

    // 2. prepare（时钟准备，如 PLL 锁定）
    if (clk->ops->prepare)
        clk->ops->prepare(clk->hw);

    // 3. enable（门控打开）
    if (clk->ops->enable)
        ret = clk->ops->enable(clk->hw);

    // 4. 计数
    clk->enable_count++;

    return ret;
}

// clk_disable：减少计数，计数为 0 时关闭时钟
```

---

## 3. set_rate — 设置频率

```c
// drivers/clk/clk.c — clk_set_rate
int clk_set_rate(struct clk *clk, unsigned long rate)
{
    unsigned long best_rate = 0;
    unsigned long parent_rate;

    // 1. 调用 round_rate 获取最佳频率
    long rounded_rate = clk->ops->round_rate(clk->hw, rate, &parent_rate);

    // 2. 如果父时钟频率需要改变
    if (parent_rate != clk->parent->rate)
        clk_set_rate(clk->parent, parent_rate);

    // 3. 设置频率
    return clk->ops->set_rate(clk->hw, rounded_rate, parent_rate);
}
```

---

## 4. sysfs 接口

```
/sys/kernel/clk/
├── clk_summary            ← 所有时钟状态
├── <clk_name>/
│   ├── rate               ← 当前频率
│   ├── enable_count       ← 使能计数
│   └── usr_rate           ← 用户请求的频率
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/clk/clk.c` | `clk_enable`、`clk_set_rate` |
| `include/linux/clk.h` | `struct clk`、`struct clk_ops` |