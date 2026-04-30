# Linux Kernel regulator framework 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/regulator/core.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. regulator 子系统

**regulator** 管理 SoC 的**电源管理 IC（PMIC）**，提供电压/电流调节。

---

## 1. 核心结构

```c
// drivers/regulator/core.c — regulator_dev
struct regulator_dev {
    const struct regulator_desc *desc;   // 描述符
    struct regulator    *rdev;          // 消费者端
    struct list_head    consumer_list;    // 此 reg 使用者链表
    struct regulation_constraints *constraints;  // 约束

    /* 操作 */
    int (*enable)(struct regulator_dev *);
    int (*disable)(struct regulator_dev *);
    int (*set_voltage)(struct regulator_dev *, int min_uV, int max_uV);
    int (*get_voltage)(struct regulator_dev *);
};
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `drivers/regulator/core.c` | 核心实现 |
| `include/linux/regulator/driver.h` | regulator_desc |
