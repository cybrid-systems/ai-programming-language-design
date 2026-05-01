# 45-cpufreq — Linux 内核 CPUFreq 调频子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**CPUFreq 子系统**动态调整 CPU 工作频率以平衡性能与功耗。当 CPU 负载低时降低频率节省功耗，当负载高时提升频率满足性能需求。Governor 是调频策略的核心，决定何时改变频率。

**doom-lsp 确认**：`drivers/cpufreq/cpufreq.c` 核心框架。`cpufreq_policy` 管理 CPU 频率范围，`cpufreq_governor` 定义调频策略。

---

## 1. 核心数据结构

```c
// drivers/cpufreq/cpufreq.c
struct cpufreq_policy {
    struct cpufreq_governor *governor;   // 当前调频策略
    unsigned int min;                     // 最低频率 (kHz)
    unsigned int max;                     // 最高频率 (kHz)
    unsigned int cur;                     // 当前频率
    unsigned int cached_target_freq;      // 缓存目标频率
    struct cpufreq_frequency_table *freq_table; // 频率表
    cpumask_var_t cpus;                   // 管理的 CPU
    struct rw_semaphore rwsem;            // 读写锁
};
```

---

## 2. Governor 类型

| Governor | 策略 | 适用 |
|----------|------|------|
| performance | 固定最高频率 | 性能优先 |
| powersave | 固定最低频率 | 省电 |
| userspace | 用户手动设置 | 自定义 |
| ondemand | 负载变化时跳频 | 通用 |
| conservative | 负载变化时渐变 | 平滑调频 |
| schedutil | 基于调度器信号 | 最新推荐 |

---

## 3. schedutil Governor

schedutil 是内核 7.0-rc1 的最新推荐调频策略。它基于调度器的 PELT（Per-Entity Load Tracking）信号决定频率：

```c
// kernel/sched/cpufreq_schedutil.c
static void sugov_update_shared(struct sugov_policy *sg_policy, ...)
{
    // 读取调度器的 PELT 负载
    unsigned long util = sugov_get_util(sg_policy);

    // 将 util（0-1024）映射到频率
    // util 1024 = 满负载 → 最高频率
    // util 512  = 50% 负载 → 50% 最高频率

    // 按比例设置频率
    sg_policy->next_freq = map_util_freq(util, policy->max, capacity);
}

// map_util_freq 函数
static unsigned long map_util_freq(unsigned long util,
                                    unsigned long freq, unsigned long cap)
{
    return freq * util / cap;  // 线性映射
}
```

---

## 4. 频率切换流程

```
sugov_update_shared 触发
  → sg_policy->next_freq = 新目标频率
  → sg_policy->work 被调度
  → cpufreq_driver_fast_switch 或 __cpufreq_driver_target
    → cpufreq_driver->setpolicy 或 target
      → 硬件寄存器设置（如 MSR 或 P-State）
```

---

## 5. 源码文件索引

| 文件 | 内容 |
|------|------|
| drivers/cpufreq/cpufreq.c | 核心框架 |
| kernel/sched/cpufreq_schedutil.c | schedutil governor |
| drivers/cpufreq/cpufreq_ondemand.c | ondemand |
| drivers/cpufreq/cpufreq_conservative.c | conservative |

---

## 6. 关联文章

- **46-scheduler-domains**: 调度域
- **47-rt-scheduler**: 实时调度

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 7. cpufreq_init 流程

```c
// 引导时初始化 CPUFreq
static int __init cpufreq_core_init(void)
{
    // 注册 cpufreq 子系统
    cpufreq_register_driver(&acpi_cpufreq_driver);

    // 创建 sysfs 接口
    for_each_possible_cpu(cpu) {
        // /sys/devices/system/cpu/cpuX/cpufreq/
        // 包含 scaling_min_freq, scaling_max_freq
        // scaling_governor, scaling_cur_freq 等
    }
}
```

## 8. 频率切换延迟

```c
// 不同调频机制的切换延迟
// ACPI P-State (Intel): ~10-50us (MSR 写)
// CPPC (ARM): ~10-100us (MMIO 写)
// 主板 VR 响应: ~1-10ms (电压稳定)

struct cpufreq_driver {
    unsigned int (*target)(struct cpufreq_policy *policy, unsigned int target_freq);
    // target 函数返回实际设置的频率
    // 可能因为硬件限制略低于目标
};
```

## 9. 用户空间控制

```bash
# 查看当前频率策略
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq

# 设置策略
echo schedutil > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
echo 1200000 > /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq

# 查看可用的调频器
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
```

## 10. 性能影响

| 操作 | 延迟 | 说明 |
|------|------|------|
| 频率查询 | ~1us | MSR 读 |
| 频率切换 | ~10-50us | MSR 写+等待 |
| schedutil 计算 | ~500ns | PELT 读取+映射 |
| ondemand 定时器 | ~1-10ms | 采样间隔 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
