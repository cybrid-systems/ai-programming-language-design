# Linux Kernel CPUFreq 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/cpufreq/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 CPUFreq？

**CPUFreq** 是 Linux 的**动态 CPU 频率调节**子系统，根据负载和策略在性能和功耗之间取得平衡。

**核心组件**：
- **Governor**：调度器（ondemand/conservative/schedutil 等）
- **Driver**：硬件驱动（intel_pstate、AMD P-State、ACPI CPPC）
- **Policy**：每个 CPU 或 CPU 簇的频率策略

---

## 1. 核心数据结构

### 1.1 cpufreq_policy

```c
// drivers/cpufreq/cpufreq.c — cpufreq_policy
struct cpufreq_policy {
    /* 频率范围 */
    unsigned int        min_freq;    // 最低频率
    unsigned int        max_freq;    // 最高频率
    unsigned int        cur_freq;    // 当前频率
    unsigned int        cpu;         // 主导 CPU

    /* 调度器集成 */
    struct cpufreq_governor *governor;  // 当前使用的调度器
    struct cpufreq_governor *last_governor;  // 上一个调度器

    /* 工作队列 */
    struct delayed_work work;       // 频率切换延迟工作

    /* 受影响的 CPU */
    cpumask_var_t      cpus;       // 此策略覆盖的 CPU
    cpumask_var_t      related_cpus; // 相关的 CPU

    /* 回调 */
    struct cpufreq_driver *driver;   // 硬件驱动
    struct cpufreq_freqs  *freqs;    // 频率切换通知
};
```

### 1.2 cpufreq_governor

```c
// drivers/cpufreq/cpufreq.c — cpufreq_governor
struct cpufreq_governor {
    char           name[CPUFREQ_NAME_LEN];
    int            owner;          // 模块引用

    /* 初始化/退出 */
    int  (*init)(struct cpufreq_policy *policy);
    void (*exit)(struct cpufreq_policy *policy);

    /* 频率选择 */
    int  (*governor)(struct cpufreq_policy *policy,
                unsigned int event);

    /* per-CPU 限流 */
    int  (*start)(struct cpufreq_policy *policy);
    void (*stop)(struct cpufreq_policy *policy);
    void (*limits)(struct cpufreq_policy *policy);

    struct list_head    governor_list;
};
```

---

## 2. Governors

### 2.1 schedutil（默认，推荐）

```c
// kernel/sched/cpufreq_schedutil.c — schedutil governor
// 基于调度器的频率提示，直接从 CFS/RT 的负载跟踪获取数据

static unsigned long sugov_next_freq(struct sugov_policy *sg_policy)
{
    unsigned long util = sg_policy->last_util;
    unsigned long max = sg_policy->policy->max;
    unsigned long freq = (util * max) / SCHED_CAPACITY_SCALE;
    return cpufreq_driver_resolve(sg_policy->policy, freq);
}

// schedutil 频率更新
static void sugov_update_commit(struct sugov_policy *sg_policy, u64 time)
{
    next_freq = sugov_next_freq(sg_policy);
    if (next_freq != sg_policy->cached_freq)
        __cpufreq_driver_target(sg_policy->policy, next_freq, CPUFREQ_RELATION_L);
}
```

### 2.2 ondemand

```c
// drivers/cpufreq/cpufreq_ondemand.c
// 基于 CPU 利用率的动态调节
// 采样周期：SUNSET_USEC_DEFAULT = 10ms

// 采样 CPU 使用率：
// 1. 在 tick 中采样 idle_time / busy_time
// 2. 如果使用率 > up_threshold（如 95%），升频
// 3. 如果使用率 < down_differential（如 95% - 10%），降频
// 4. 升频：一步到位；降频：逐步降
```

---

## 3. cpufreq_driver — 硬件驱动

```c
// drivers/cpufreq/cpufreq.c — cpufreq_driver
struct cpufreq_driver {
    char               name[CPUFREQ_NAME_LEN];
    unsigned int       flags;

    /* 目标频率设置 */
    int  (*target)(struct cpufreq_policy *policy, unsigned int target_freq,
                  unsigned int relation);
    int  (*target_index)(struct cpufreq_policy *policy, unsigned int index);

    /* BIOS/ACPI 接口 */
    int  (*init)(struct cpufreq_policy *policy);
    int  (*exit)(struct cpufreq_policy *policy);

    /* 频率表 */
    int  (*verify)(struct cpufreq_policy *policy);
    int  (*setpolicy)(struct cpufreq_policy *policy);
};
```

---

## 4. 频率切换流程

```
调度器更新负载：
  → sugov_update_commit()
    → sugov_next_freq()    // 根据 util 计算目标频率
    → __cpufreq_driver_target()
      → cpufreq_driver->target()
        → intel_pstate_set()
          → MSR_IA32_PERF_CTL 写入
        → acpi_cpufreq_target()
          → write_msr(ACPI_PERF_CTL)
```

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `drivers/cpufreq/cpufreq.c` | `cpufreq_policy`、`cpufreq_governor`、`cpufreq_driver` |
| `kernel/sched/cpufreq_schedutil.c` | `schedutil governor`、`sugov_update_commit` |
| `drivers/cpufreq/intel_pstate.c` | `intel_pstate` 驱动 |
| `drivers/cpufreq/acpi_cpufreq.c` | `acpi_cpufreq` 驱动 |
