# cpufreq — CPU 频率调节器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/cpufreq/cpufreq.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**cpufreq** 根据负载动态调节 CPU 频率，平衡性能和功耗：
- **Performance**：始终最高频率
- **Powersave**：始终最低频率
- **Ondemand**：负载高时提升频率，闲置时降低
- **Conservative**：缓慢调整（更省电）
- **Schedutil**：基于调度器的反馈（4.14+）

---

## 1. 核心数据结构

### 1.1 cpufreq_policy — 策略

```c
// drivers/cpufreq/cpufreq.c — cpufreq_policy
struct cpufreq_policy {
    // CPU 信息
    unsigned int            cpu;           // 主导 CPU
    unsigned int            last_cpu;      // 上次更新的 CPU

    // 频率范围
    unsigned int            min;           // 最小频率（kHz）
    unsigned int            max;           // 最大频率（kHz）

    // 当前状态
    unsigned int            cur;           // 当前频率
    unsigned int            requestio;      // 请求的频率

    // CPU 核心
    const struct cpufreq_cpuinfo  *cpuinfo; // 硬件限制

    // 调节器
    const char              *governor;     // 当前调节器名
    struct cpufreq_governor *governor;    // 调节器对象

    // 统计数据
    struct cpufreq_stats    *stats;        // 频率统计

    // 频率表
    struct cpufreq_frequency_table *freq_table; // 可用频率列表

    // 过渡（transition）锁
    struct rw_semaphore      transition;   // 频率切换时加锁

    // 延迟（延迟限制）
    unsigned int            transition_delay_us; // 最小转换间隔

    // 冷却设备
    struct thermal_cooling_device *cdev; // 散热冷却设备

    // 亲和性
    struct cpumask          *cpus;        // 受策略影响的 CPU 掩码
    struct cpumask          *related_cpus; // 相关 CPU（需同步的）
};
```

### 1.2 cpufreq_governor — 调节器

```c
// drivers/cpufreq/cpufreq.c — cpufreq_governor
struct cpufreq_governor {
    char            name[CPUFREQ_NAME_LEN]; // 调节器名
    int             (*init)(struct cpufreq_policy *);
    int             (*exit)(struct cpufreq_policy *);
    int             (*start)(struct cpufreq_policy *);
    int             (*stop)(struct cpufreq_policy *);
    int             (*update)(struct cpufreq_policy *policy, unsigned int event);
    ssize_t         (*show)(struct cpufreq_policy *, char *);
    ssize_t         (*store)(struct cpufreq_policy *, const char *, size_t);

    // 调节器特定数据
    void            *governor_data;
};
```

### 1.3 cpufreq_frequency_table — 频率表

```c
// include/linux/cpufreq.h — cpufreq_frequency_table
struct cpufreq_frequency_table {
    unsigned int    flags;          // CPUFREQ_TABLE_*
    unsigned int    driver_data;   // 驱动特定数据
    unsigned int    frequency;      // 频率（kHz）
};

#define CPUFREQ_ENTRY_INVALID     ~0
#define CPUFREQ_TABLE_END          ~1
```

---

## 2. 调节器详解

### 2.1 schedutil — 基于调度器（推荐）

```c
// kernel/sched/cpufreq_schedutil.c — schedutil
struct schedutil_governor {
    struct cpufreq_governor   base;

    unsigned int             up_rate_limit_us;  // 上调延迟（μs）
    unsigned int             down_rate_limit_us; // 下调延迟（μs）
    struct sched_group       *sg;              // 调度组
    unsigned long            util;              // 估算利用率
    unsigned long             max;               // 最大频率（饱和）
    unsigned int              next_freq;         // 下一个目标频率
};

static int sugov_update(struct cpufreq_policy *policy, unsigned int event)
{
    struct schedutil_data *data = policy->governor_data;

    if (event == CPUFREQ_GOV_START) {
        // 启动时注册 scheduler callbacks
        // util_update_callbacks(data);
    }

    if (event == CPUFREQ_GOV_UPDATE) {
        // 获取调度器提供的利用率
        util = schedtil_get_util(data);

        // 计算目标频率（频率 = util * max_freq）
        next_freq = clamp(util * max_freq / 100, policy->min, policy->max);

        // 应用
        __cpufreq_driver_target(policy, next_freq, CPUFREQ_RELATION_L);
    }
}
```

### 2.2 ondemand — 按需调节

```c
// drivers/cpufreq/cpufreq_ondemand.c — dbs_check_cpu
static void dbs_check_cpu(struct cpu_dbs_common *cdbs)
{
    struct cpufreq_policy *policy = cdbs->policy;
    unsigned int load;

    // 1. 计算 CPU 利用率
    load = cpufreq_get_current_load(policy->cpu);

    // 2. 如果负载 > up_threshold（默认 80%）
    if (load > dbs_info->up_threshold) {
        // 选择最高频率（除非已达 max）
        __cpufreq_driver_target(policy, policy->max, CPUFREQ_RELATION_H);
    }
    // 3. 如果负载 < down_differential（默认 20%）
    else if (load < dbs_info->down_differential) {
        // 选择最低频率
        __cpufreq_driver_target(policy, policy->min, CPUFREQ_RELATION_L);
    }
}
```

---

## 3. 核心 API

### 3.1 cpufreq_driver_target

```c
// drivers/cpufreq/cpufreq.c — __cpufreq_driver_target
int __cpufreq_driver_target(struct cpufreq_policy *policy,
                           unsigned int target_freq,
                           unsigned int relation)
{
    unsigned int old_target_freq = target_freq;

    // 1. 查找频率表中的合法频率
    target_freq = cpufreq_frequency_table_target(policy, target_freq, relation);

    // 2. 如果频率没变，无需操作
    if (target_freq == policy->cur)
        return 0;

    // 3. 获取转换互斥锁
    down_write(&policy->transition);

    // 4. 调用驱动设置频率
    ret = policy->freq_table[target_freq].driver->set(policy, target_freq);

    // 5. 更新 policy->cur
    if (ret == 0)
        policy->cur = target_freq;

    up_write(&policy->transition);

    return ret;
}
```

### 3.2 cpufreq_register_governor — 注册调节器

```c
// drivers/cpufreq/cpufreq.c — cpufreq_register_governor
int cpufreq_register_governor(struct cpufreq_governor *governor)
{
    int ret;

    // 检查是否已存在
    for (i = 0; i < num_online_cpus(); i++) {
        if (!governor->cpu_data[i])
            continue;
        if (!strcmp(governor->name, cpu_data[i]->governor->name))
            return -EBUSY;
    }

    // 加入全局链表
    list_add(&governor->governor_list, &cpufreq_governor_list);

    return 0;
}
```

---

## 4. 调度器集成

### 4.1 sugov_update_util — schedutil 更新入口

```c
// kernel/sched/cpufreq_schedutil.c — sugov_update_util
static inline void sugov_update_util(struct sugov_cpu *sg_cpu, u64 time, unsigned int flags)
{
    unsigned long util, max;
    unsigned int next_f;

    // 1. 获取 CPU 利用率（schedutil）
    util = sg_cpu->util_avg;
    max = sg_cpu->max;

    // 2. 计算下一个频率
    //    next_freq = (util / max) * policy->max
    next_f = (util * policy->max) >> SCHED_CAPACITY_SHIFT;

    // 3. 节流（避免频繁调整）
    if (time - sg_cpu->last_update < sugov_up_rate_limit)
        return;

    // 4. 应用
    sg_request_update(sg_cpu, next_f);
}
```

---

## 5. sysfs 接口

```
/sys/devices/system/cpu/cpu0/cpufreq/
├── scaling_available_governors   ← 可用调节器
├── scaling_cur_freq             ← 当前频率（只读）
├── scaling_governor             ← 当前调节器
├── scaling_max_freq             ← 最大频率
├── scaling_min_freq             ← 最小频率
├── scaling_setspeed            ← userspace 调节器的目标频率
└── related_cpus                 ← 相关 CPU（需同步的）
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/cpufreq/cpufreq.c` | `struct cpufreq_policy`、`cpufreq_driver_target` |
| `drivers/cpufreq/cpufreq_ondemand.c` | `dbs_check_cpu` |
| `kernel/sched/cpufreq_schedutil.c` | `sugov_update`、`schedutil_governor` |
| `include/linux/cpufreq.h` | `struct cpufreq_frequency_table` |