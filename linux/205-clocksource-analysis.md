# 205-clocksource — 时钟源深度源码分析

> 基于 Linux 7.0-rc1 主线源码（kernel/time/clocksource.c)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**clocksource** 是内核的时间源抽象，提供高精度的时钟读取接口。

---

## 1. clocksource 结构

```c
// kernel/time/clocksource.c — clocksource
struct clocksource {
    u64 (*read)(struct clocksource *cs);
    u64 mask;
    u32 mult;        // 用于 ns → cycles 转换
    u32 shift;        // 缩放因子
    u64 max_idle_ns;
    const char *name;
    struct list_head list;
};
```

---

## 2. clocksource 切换

```bash
# 查看可用时钟源：
cat /sys/devices/system/clocksource/clocksource0/available_clocksource
# tsc hpet acpi_pm

# 查看当前：
cat /sys/devices/system/clocksource/clocksource0/current_clocksource
```

---

## 3. 西游记类喻

**clocksource** 就像"天庭的秒表系统"——

> clocksource 像各种不同的秒表（TSC、HPET、ACPI PM timer），内核选择最精确的一个作为基准。不同硬件平台有不同的秒表，clocksource 提供了统一的接口。

---

## 4. 关联文章

- **timekeeping**（article 200）：clocksource 是 timekeeping 的基础
- **hrtimer**（article 25）：hrtimer 使用 clocksource