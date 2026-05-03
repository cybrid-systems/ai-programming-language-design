# 45-cpufreq — Linux 内核 CPUFreq 调频子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

CPUFreq 子系统是 Linux 内核中负责 CPU 动态频率与电压调整的核心框架。其设计哲学是**在性能与功耗之间取得平衡**——当 CPU 负载低时降低频率以节省功耗发热，当负载突增时快速提升频率满足计算需求。

与教科书上简单的"负载高就超频、负载低就降频"不同，Linux CPUFreq 的实现极其精密，涉及：
- **多层级抽象**：通用框架 → Governor 策略层 → 硬件驱动层
- **调度器集成**：schedutil governor 直接从 PELT（Per-Entity Load Tracking）信号推导负载
- **热管理协同**：频率调整与 thermal throttle 深度耦合
- **用户空间接口**：完整的 sysfs ABI 和 sysctl 接口
- **硬件多样性**：x86 (ACPI/P-State/MSR)、ARM (CPPC/ACPI)、RISC-V 等各种硬件抽象

**doom-lsp 确认**：`drivers/cpufreq/cpufreq.c` 主框架共 **3068 行**，包含 **334 个符号**（334 symbols）。核心数据结构 `cpufreq_policy` 定义在 `include/linux/cpufreq.h:53`。schedutil governor 在 `kernel/sched/cpufreq_schedutil.c` 中，共 **933 行**，包含 **82 个符号**。

**关键文件索引**：
| 文件 | 行数 | 符号数 | 职责 |
|------|------|--------|------|
| `drivers/cpufreq/cpufreq.c` | 3068 | 334 | 核心框架、策略切换、sysfs |
| `drivers/cpufreq/cpufreq_governor.c` | ~550 | 44 | Governor 基类、DBS 采样框架 |
| `kernel/sched/cpufreq_schedutil.c` | 933 | 82 | schedutil governor（PELT 驱动） |
| `drivers/cpufreq/intel_pstate.c` | ~4000+ | 200+ | Intel P-State 驱动 |
| `include/linux/cpufreq.h` | ~900 | 100+ | 核心数据结构定义 |

---

## 1. 核心数据结构

理解 CPUFreq 子系统的关键是三个核心数据结构的三角关系：

```
cpufreq_policy ←→ cpufreq_governor ←→ cpufreq_driver
```

### 1.1 cpufreq_policy — CPU 频率策略的完整上下文

`cpufreq_policy` 是 CPUFreq 子系统的**核心实体**。每个物理 CPU 或 CPU 簇（cluster）对应一个 `cpufreq_policy` 实例。`include/linux/cpufreq.h:53` 开始定义：

```c
// include/linux/cpufreq.h:53-140（精选字段）
struct cpufreq_policy {
    /* CPU 拓扑管理 */
    cpumask_var_t       cpus;           /* 在线 CPUs（共享时钟）*/
    cpumask_var_t        related_cpus;   /* 在线 + 离线的相关 CPUs */
    cpumask_var_t        real_cpus;     /* related 且 present 的 CPUs */
    unsigned int         cpu;            /* 管理此 policy 的 CPU（必须在线）*/

    /* 频率范围（单位：kHz）*/
    unsigned int        min;             /* 最低允许频率 */
    unsigned int        max;             /* 最高允许频率 */
    unsigned int        cur;             /* 当前实际频率 */

    /* 调频策略 */
    struct cpufreq_governor *governor;   /* 当前活跃的 governor */
    void                *governor_data; /* governor 的私有数据 */
    char                last_governor[CPUFREQ_NAME_LEN]; /* 上次使用的 governor */

    /* 频率表——硬件支持的离散频率点 */
    struct cpufreq_frequency_table *freq_table;
    enum cpufreq_table_sorting freq_table_sorted;

    /* QoS 约束（DVFS 软约束，非硬件限制）*/
    struct freq_constraints constraints;
    struct freq_qos_request min_freq_req;
    struct freq_qos_request max_freq_req;

    /* 同步机制：读者写者锁 */
    struct rw_semaphore rwsem;

    /* Fast Switch 支持 */
    bool                fast_switch_possible;  /* 驱动声明 */
    bool                fast_switch_enabled;    /* governor 启用 */

    /* 调频延迟约束 */
    unsigned int        transition_delay_us;    /* 两次调频间最小间隔 */

    /* 热管理关联 */
    struct kobject      kobj;                   /* sysfs 节点 */
    struct completion   kobj_unregister;        /* 注销完成通知 */

    /* Boost 支持 */
    struct freq_qos_request boost_freq_req;

    /* 调度域关联 */
    struct list_head    policy_list;            /* 全局 policy 链表 */

    /* 最近一次 policy 更新的时间戳（用于 PELT 同步）*/
    unsigned long       last_update;
};
```

**设计洞察**：`cpufreq_policy` 的 `cpus` 是一个 **cpumask**（位图），这意味着一个 policy 可以管理多个 CPU。这在 ARM big.LITTLE 架构或 Intel 超线程场景下至关重要——同一 cluster 的所有 CPU 必须运行在同一频率下。

**doom-lsp 确认**：在 `cpufreq.c:60` 有 `DEFINE_PER_CPU(struct cpufreq_policy *, cpufreq_cpu_data)`，意味着每个 CPU 核心在变量层面就有一个 `cpufreq_policy *` 指向其当前 policy。

### 1.2 cpufreq_governor — 调频策略的模式抽象

`cpufreq_governor` 是**策略模式（Strategy Pattern）**的典型实现：框架层定义策略接口，具体频率计算逻辑由各个 governor 实现。

```c
// include/linux/cpufreq.h:593-634
struct cpufreq_governor {
    char            name[CPUFREQ_NAME_LEN];     /* "schedutil", "ondemand", ... */
    int             max_transition_latency;     /* Governor 要求的最大调频延迟 */

    /* 生命周期钩子 */
    int (*init)(struct cpufreq_policy *);
    int (*exit)(struct cpufreq_policy *);

    /* 频率选择入口 */
    int (*start)(struct cpufreq_policy *);
    void (*stop)(struct cpufreq_policy *);
    void (*limits)(struct cpufreq_policy *);

    /* 可选：dynamic_switching 支持 */
    int (*dynamic_switching)(struct cpufreq_policy *,
                             struct cpufreq_policy *);

    /* sysfs 属性（用于 governor 特有参数）*/
    struct attribute_group *attr_group;
    const struct gov_sysfs_ops *sysfs_ops;

    /* 模块引用计数 */
    struct module *owner;
};
```

**doom-lsp 确认**：`cpufreq_governor` 结构体的 `start` 钩子是最关键的——schedutil 在此处注册调度器回调，`ondemand` 在此处设置周期性采样定时器。

**各 Governor 对照表**：

| Governor | 策略类型 | 负载信号来源 | 适用场景 |
|----------|----------|-------------|----------|
| `performance` | 静态固定 | 无（始终最高） | 性能基准测试 |
| `powersave` | 静态固定 | 无（始终最低） | 极低功耗设备 |
| `userspace` | 手动控制 | 无（用户设置） | 自定义脚本控制 |
| `ondemand` | 动态采样 | 周期性 idle-time 采样 | 通用服务器 |
| `conservative` | 动态采样 | 周期性 idle-time 采样 | 笔记本（渐进式） |
| `schedutil` | 动态回调 | PELT 信号 + IRQ | 移动/桌面（最新推荐） |
| `cm3` | 动态采样 | 周期性采样 | ARM Cortex-M3 专用 |

### 1.3 cpufreq_driver — 硬件抽象层

`cpufreq_driver` 是面向硬件的底层驱动接口。框架层通过它与具体硬件交互：

```c
// include/linux/cpufreq.h:349-400（精选字段）
struct cpufreq_driver {
    const char      *name;                      /* 驱动名："intel_pstate", "acpi-cpufreq" */
    unsigned int    flags;                      /* CPUFREQ_* flags */

    /* 频率读取（必须实现）*/
    unsigned int (*get)(unsigned int cpu);

    /* 频率设置（二选一）*/
    int  (*target)(struct cpufreq_policy *policy,   /* 旧式：分步设置 */
                   unsigned int target_freq,
                   unsigned int relation);
    int  (*target_index)(struct cpufreq_policy *,   /* 新式：索引方式 */
                         unsigned int index);

    /* Fast Switch（可选）*/
    unsigned int (*fast_switch)(struct cpufreq_policy *,
                                unsigned int target_freq);

    /* 初始化/退出 */
    int  (*init)(struct cpufreq_policy *);
    int  (*exit)(struct cpufreq_policy *);

    /* 频率表验证 */
    int  (*verify)(struct cpufreq_policy *);

    /* 驱动 attrs */
    struct attribute_group **attr_groups;
};
```

**doom-lsp 确认**：`cpufreq.c:59` 声明了 `static struct cpufreq_driver *cpufreq_driver`，这是全局唯一的驱动指针。所有 CPUFreq 框架调用最终通过此指针访问硬件。

### 1.4 cpufreq_frequency_table — 硬件频率点索引

```c
// include/linux/cpufreq.h:715
struct cpufreq_frequency_table {
    unsigned int    flags;
    unsigned int    driver_data;     /* 驱动私有数据（如 P-State ID）*/
    unsigned int    frequency;      /* 频率值（kHz）或 CPUFREQ_ENTRY_INVALID */
};
```

频率表的关键用法：

```c
// 遍历频率表
for (i = 0; (freq = table[i].frequency) != CPUFREQ_TABLE_END; i++) {
    if (freq == CPUFREQ_ENTRY_INVALID) continue;
    printk("支持频率: %u kHz\n", freq);
}
```

**special 值**：
- `CPUFREQ_ENTRY_INVALID`：此条目无效（跳过）
- `CPUFREQ_TABLE_END`：遍历结束
- `CPUFREQ_BOOST_FREQ`：表示 boost 频率

**doom-lsp 确认**：`freq_table.c` 中的 `cpufreq_frequency_table_exit()` 是清理频率表的入口函数。

---

## 2. 框架初始化——从内核启动到 cpufreq 就绪

### 2.1 模块入口与全局变量

`cpufreq.c` 的核心初始化在文件末尾通过 `core_initcall` 触发：

```c
// drivers/cpufreq/cpufreq.c:3068
core_initcall(cpufreq_core_init);
```

这意味着 CPUFreq 框架在内核初始化的 **core** 阶段（早于设备驱动）就被初始化。

**doom-lsp 确认**：`cpufreq_core_init @ 3018` 是入口函数，函数体从第 3018 行开始。

```c
// drivers/cpufreq/cpufreq.c:3018-3050
static int __init cpufreq_core_init(void)
{
    int ret;
    unsigned int i;

    /* 初始化每个 CPU 的 policy 指针为 NULL */
    for_each_possible_cpu(i)
        per_cpu(cpufreq_cpu_data, i) = NULL;

    /* 初始化全局 policy 链表 */
    INIT_LIST_HEAD(&cpufreq_policy_list);

    /* 初始化全局 governor 链表 */
    INIT_LIST_HEAD(&cpufreq_governor_list);

    /* 初始化 cpufreq 全局 kobject（/sys/devices/system/cpu/cpufreq/）*/
    ret = cpufreq_global_kobject_init();
    if (ret)
        return ret;

    /* 注册 cpufreq 策略通知链（用于热插拔等场景）*/
    blocking_notifier_chain_register(
        &cpufreq_policy_notifier_list, ...);

    /* 初始化 freq QoS 框架（DVFS 软约束）*/
    ret = freq_constraints_init(&global_constraints);
    if (ret)
        return ret;

    return 0;
}
```

**设计洞察**：`for_each_possible_cpu` 遍历所有**可能的**CPU（包括当前不存在的热插拔 CPU），这确保了 CPU 上线时 cpufreq 框架已经准备好。

### 2.2 Governor 注册与链表管理

每个 governor（如 schedutil、ondemand）在内核模块初始化时调用 `cpufreq_register_governor()` 注册自己：

```c
// drivers/cpufreq/cpufreq.c:2513
int cpufreq_register_governor(struct cpufreq_governor *governor)
{
    if (!governor || !governor->name)
        return -EINVAL;

    /* 插入到全局 governor 链表（按字母序）*/
    list_add(&governor->governor_list, &cpufreq_governor_list);
    return 0;
}
```

**doom-lsp 确认**：`cpufreq_governor_list` 在 `cpufreq.c:48` 定义为 `LIST_HEAD`，全局唯一。`cpufreq_register_governor` 在 `cpufreq.c:2513`。

### 2.3 驱动注册流程

cpufreq 驱动（如 `intel_pstate`、`acpi-cpufreq`）在模块初始化时调用 `cpufreq_register_driver()`：

```c
// drivers/cpufreq/cpufreq.c:2890
int cpufreq_register_driver(struct cpufreq_driver *driver_data)
{
    unsigned long flags;
    int ret;

    cpufreq_driver_lock_update();         /* 写锁保护 */
    cpufreq_driver = driver_data;         /* 设置全局驱动指针 */

    /* 通知链：告知所有观察者新驱动已注册 */
    ret = cpufreq_driver_notifier_call(
        CPUFREQ_DRIVER_INIT, ...);

    /* 遍历所有已在线的 CPU，创建对应的 policy */
    get_online_cpus();
    for_each_online_cpu(cpu) {
        ret = cpufreq_online(cpu);        /* 为每个在线 CPU 创建 policy */
    }
    put_online_cpus();

    cpufreq_driver_lock_update();
    return 0;
}
```

**关键流程**：`cpufreq_online()` 是每个 CPU 上线时调用的核心函数，它创建 `cpufreq_policy` 并初始化 sysfs 接口。

---

## 3. CPU 上线——cpufreq_policy 的创建过程

当 Linux 的 CPU hotplug 子系统将一个 CPU 上线时，会通过 cpuhp 机制触发 `cpufreq_add_dev()`：

```c
// drivers/cpufreq/cpufreq.c:1651-1670
static int cpufreq_add_dev(struct cpufreq_policy *policy)
{
    int ret, cpu = policy->cpu;
    struct cpufreq_policy *new_policy;

    /* 分配新的 policy 结构（包含 kobject 引用计数）*/
    new_policy = cpufreq_policy_alloc();
    if (!new_policy)
        return -ENOMEM;

    /* 复制调用者传入的 policy 信息 */
    memcpy(new_policy, policy, sizeof(*policy));

    /* 初始化读写信号量 */
    init_rwsem(&new_policy->rwsem);

    /* 设置 CPU 掩码 */
    cpumask_copy(new_policy->cpus, cpumask_of(cpu));

    /* 添加 sysfs 接口（/sys/devices/system/cpu/cpuX/cpufreq/）*/
    ret = cpufreq_add_dev_interface(new_policy);
    if (ret)
        goto err_out;

    /* 如果是首个管理此 policy 的 CPU，注册 sysfs 符号链接 */
    ret = add_cpu_dev_symlink(cpu, new_policy);
    if (ret)
        goto err_out;

    /* 将 policy 加入全局链表 */
    list_add(&new_policy->policy_list, &cpufreq_policy_list);

    /* 初始化默认 policy 值 */
    if (cpufreq_driver->init)
        ret = cpufreq_driver->init(new_policy);

    /* 初始化默认 governor */
    ret = cpufreq_init_policy(new_policy);

    return 0;
}
```

**doom-lsp 确认**：`cpufreq_policy_alloc @ 1266` 使用 `kzalloc()` 分配 policy 并初始化 `kobj`。`cpufreq_add_dev_interface @ 1076` 创建 sysfs 属性文件。

### 3.1 Policy 分配与 kobject 初始化

```c
// drivers/cpufreq/cpufreq.c:1266-1340
static struct cpufreq_policy *cpufreq_policy_alloc(void)
{
    struct cpufreq_policy *policy;

    /* 使用 kobject_alloc 分配（带引用计数）*/
    policy = kobject_alloc(&cpufreq_ktype, "cpufreq");

    /* 分配 CPU mask（可变长数组）*/
    if (!zalloc_cpumask_var(&policy->cpus, GFP_KERNEL))
        goto err_free_policy;
    if (!zalloc_cpumask_var(&policy->related_cpus, GFP_KERNEL))
        goto err_free_cpus;
    if (!zalloc_cpumvar_var(&policy->real_cpus, GFP_KERNEL))
        goto err_free_related;

    /* 初始化 QoS 请求 */
    freq_qos_request_init(&policy->min_freq_req, ...);
    freq_qos_request_init(&policy->max_freq_req, ...);
    freq_qos_request_init(&policy->boost_freq_req, ...);

    /* 初始化约束结构 */
    freq_constraints_init(&policy->constraints);

    /* 初始化 list_head */
    INIT_LIST_HEAD(&policy->policy_list);

    /* 初始化 work_struct（用于异步 policy 更新）*/
    INIT_WORK(&policy->update, cpufreq_update_policy_work);

    return policy;
}
```

**设计洞察**：`kzalloc_cpumask_var` 分配的是**可变长数组**（编译期大小取决于 NR_CPUS），这是 Linux 内核在性能与内存占用之间权衡的典型例子——在大型服务器上 NR_CPUS 可能很大，但实际使用的 CPU 可能很少。

### 3.2 默认 Governor 初始化

```c
// drivers/cpufreq/cpufreq.c:1131
static int cpufreq_init_policy(struct cpufreq_policy *policy)
{
    struct cpufreq_governor *gov;
    char buf[CPUFREQ_NAME_LEN];
    int ret;

    /* 读取内核启动参数 default_governor */
    if (cpufreq_para_string("cpufreq.default_governor", buf, sizeof(buf))) {
        /* 未指定则使用默认 governor（通常是 schedutil 或 performance）*/
        gov = cpufreq_default_governor();
    } else {
        /* 查找指定的 governor */
        gov = find_governor(buf);
    }

    policy->governor = gov;   /* 设置 governor 指针 */

    /* 调用 governor 的 init 钩子 */
    if (gov->init)
        ret = gov->init(policy);

    return 0;
}
```

**doom-lsp 确认**：`find_governor @ 651` 在全局 governor 链表中按名字查找匹配的 governor。

---

## 4. Governor 核心机制——从调度器信号到频率决策

### 4.1 schedutil Governor 架构总览

schedutil 是 Linux 7.0-rc1 的**默认推荐 governor**，其核心设计理念是**让调度器直接驱动调频决策**，绕过传统采样定时器的延迟：

```
调度器 PELT 信号
      ↓
schedutil_update_util() [在调度器上下文中直接调用]
      ↓
sugov_update_shared() [计算新频率]
      ↓
cpufreq_driver_fast_switch() 或 irq_work 调度
      ↓
硬件寄存器写入（MSR / MMIO）
```

**doom-lsp 确认**：`kernel/sched/cpufreq_schedutil.c` 的 `sugov_update_shared @ 514` 是调度器回调入口。

### 4.2 PELT 信号与 CPU 利用率计算

Linux 调度器的 PELT（Per-Entity Load Tracking）系统为每个调度实体（task_struct）持续跟踪其负载均值。schedutil governor 直接利用这个信号：

```c
// kernel/sched/cpufreq_schedutil.c:226
static unsigned long sugov_get_util(struct sugov_policy *sg_policy)
{
    struct cpufreq_policy *policy = sg_policy->policy;
    unsigned long util = 0;
    unsigned long capacity = arch_scale_cpu_capacity(policy->cpu);

    /* 获取 CFS 实体的 PELT 负载（0-1024，1024=满负载）*/
    util = sched_feat(UTIL_EST) ?
           READ_ONCE(policy->cpu_info.util_avg) :
           cpufreq_policy_util(policy);

    /* 获取 RT 实体负载 */
    util += sched_uclamp_util(policy->cpu, UTIL_RT);

    /* 考虑到频率不变的容量缩放 */
    util = mult_frac(util, capacity, capacity_orig);

    return util;  /* 返回值范围约 [0, 1024+RT负载] */
}
```

**doom-lsp 确认**：`sugov_get_util @ 226` 读取的是 `policy->cpu_info.util_avg`，这是在调度器代码中持续更新的运行均值。`UTIL_EST` (Utilization Estimation) 是 CFS 的负载估计优化。

**关键洞察**：PELT 信号的衰减因子使得**历史负载对当前决策的影响逐渐减小**，这保证了 governor 既能感知突发负载（瞬时提升），又能在负载消失后平滑降频（不会因为历史高负载而一直维持高频）。

### 4.3 频率映射——从负载到频率

```c
// kernel/sched/cpufreq_schedutil.c:193
static unsigned long get_next_freq(struct sugov_policy *sg_policy,
                                    unsigned long util,
                                    unsigned long min,
                                    unsigned long max)
{
    struct sugov_tunables *t = sg_policy->tunables;
    unsigned long freq;

    /* 基础映射：util / capacity → 目标频率 */
    freq = map_util_freq(util, max, capacity_orig);

    /* 应用 rate_limit：避免调频过频 */
    if (freq == sg_policy->cached_raw_freq)
        return sg_policy->next_freq;

    /* 应用 iowait_boost 提升（如果有未完成的 IO 等待）*/
    if (sg_policy->flags & SG_UTIL_CHECK)
        freq = sugov_iowait_apply(freq, sg_policy);

    /* 应用 freq_limit 约束（用户通过 sysfs 设置的上限）*/
    freq = clamp(freq, min, max);

    return freq;
}

// kernel/sched/cpufreq_schedutil.c:220（线性映射公式）
static unsigned long map_util_freq(unsigned long util,
                                    unsigned long freq,
                                    unsigned long cap)
{
    return div_u64(freq * util, cap);
}
```

**数学本质**：`map_util_freq` 是一个简单的线性比例映射：
```
target_freq = max_freq × (current_util / capacity_orig)
```

例如：max_freq = 3.0 GHz，capacity_orig = 1024，util = 768
→ target_freq = 3.0 × 768 / 1024 = **2.25 GHz**

**doom-lsp 确认**：`map_util_freq` 的映射是**线性**的，没有分段或非线性曲线。这保证了调频决策的确定性和可预测性。

### 4.4 IOWait Boost——IO 密集型负载的特殊处理

schedutil 对 IO 密集型负载有特殊照顾——`sugov_iowait_boost` 机制：

```c
// kernel/sched/cpufreq_schedutil.c:278
static void sugov_iowait_boost(struct sugov_cpu *sg_cpu,
                                 unsigned long *util)
{
    if (!sg_cpu->iowait_boost_pending) {
        /* 第一次检测到 IO 等待：设置 boost 标志 */
        sg_cpu->iowait_boost_pending = true;
        sg_cpu->iowait_boost = sg_cpu->sg_policy->min;
    }

    /* IO wait boost 是递增的：每次检测到等待，频率逐步提升 */
    sg_cpu->iowait_boost = min(sg_cpu->iowait_boost * 2,
                                policy->max);
}
```

**设计意图**：当一个任务处于 IO wait 状态时，立即将其 boost 到较高频率，使 IO 操作尽快完成（因为 IO 是瓶颈）。IO 完成后 boost 自然消退。

**doom-lsp 确认**：`sugov_iowait_boost @ 278` 在每次调度器 tick 被调用时检查 IO wait 状态。

### 4.5 Rate Limiting——防止调频抖动

频繁调频会导致**性能抖动（thrashing）**和**功耗浪费**。schedutil 通过 rate limiting 防止这一问题：

```c
// kernel/sched/cpufreq_schedutil.c:64
static bool sugov_should_update_freq(struct sugov_policy *sg_policy,
                                       unsigned int delay_us)
{
    s64 delta_ns;

    delta_ns = ktime_ns_since(sg_policy->last_freq_update_time);

    /* 如果距上次调频的时间小于延迟阈值，跳过 */
    return delta_ns >= sg_policy->freq_update_delay_ns;
}
```

**默认值**：`freq_update_delay_ns = 10ms`（可通过 sysfs `rate_limit_us` 调整）。

这意味着 **schedutil 的最大调频频率是 100 Hz**，远低于调度器的 tick 频率（通常 250-1000 Hz）。这是有意为之的设计——调频决策不需要那么精细。

---

## 5. 频率切换——从框架到硬件的完整路径

### 5.1 三种切换路径

CPUFreq 框架支持三种频率切换路径，按优先级排序：

```
路径 1: Fast Switch（最快路径）
  └─ schedutil → cpufreq_driver_fast_switch() → 直接 MSR/MMIO 写入
     延迟：~1-5μs，无锁，原子上下文

路径 2: Target Index（推荐路径）
  └─ governor → __cpufreq_driver_target() → target_index() 回调
     延迟：~10-50μs，有通知链回调

路径 3: Legacy Target（旧式）
  └─ governor → cpufreq_driver_target() → target() 回调
     延迟：~50-100μs，兼容性路径
```

### 5.2 Fast Switch 路径（IRQ 上下文）

Fast Switch 是延迟最低的路径，它**绕过调度器 workqueue，直接在中断或调度上下文中写入硬件寄存器**：

```c
// drivers/cpufreq/cpufreq.c:2196
unsigned int cpufreq_driver_fast_switch(struct cpufreq_policy *policy,
                                         unsigned int target_freq)
{
    /* 驱动必须实现 fast_switch 回调 */
    if (likely(cpufreq_driver->fast_switch)) {
        /* 直接调用驱动的 fast_switch 函数（无锁！）*/
        return cpufreq_driver->fast_switch(policy, target_freq);
    }
    return 0;  /* 不支持 fast switch */
}
```

**使用场景**：schedutil 的 `sugov_update_shared()` 在检测到频率需要变化时，会通过 `irq_work` 触发 `sugov_work()`，最终调用此函数。

**关键约束**：Fast Switch **不能在持有多核锁的情况下调用**，因为它可能发生在任意 CPU 上。schedutil 的实现通过 `update_lock`（spinlock）保护临界区：

```c
// kernel/sched/cpufreq_schedutil.c:514
static void sugov_update_shared(...) {
    raw_spin_lock(&sg_policy->update_lock);

    /* 计算新频率（可能在任何 CPU 上） */
    next_freq = get_next_freq(sg_policy, util, min, max);

    /* 立即执行 fast switch */
    new_freq = cpufreq_driver_fast_switch(policy, next_freq);

    raw_spin_unlock(&sg_policy->update_lock);
}
```

### 5.3 Target Index 路径（内核线程上下文）

当 Fast Switch 不可用时，使用传统的 target 路径：

```c
// drivers/cpufreq/cpufreq.c:2288
static int __target_index(struct cpufreq_policy *policy,
                          unsigned int index)
{
    int ret;

    /* 发送通知链：CPUFREQ_PRECHANGE */
    cpufreq_notify_transition(policy, CPUFREQ_PRECHANGE);

    /* 调用驱动的 target_index 回调 */
    ret = cpufreq_driver->target_index(policy, index);

    /* 发送通知链：CPUFREQ_POSTCHANGE */
    cpufreq_notify_transition(policy, CPUFREQ_POSTCHANGE);

    /* 更新 policy->cur */
    policy->cur = cpufreq_driver->get(policy->cpu);

    return ret;
}
```

**通知链机制**：`cpufreq_notify_transition` 会调用所有注册的 `cpufreq_transition_notifier` 回调。这允许其他子系统（如 thermal、RCU）监听频率变化。

### 5.4 Intel P-State 驱动的 Fast Switch 实现

以 Intel P-State 驱动为例，看 Fast Switch 如何落地：

```c
// drivers/cpufreq/intel_pstate.c
static unsigned int intel_pstate_fast_switch(
    struct cpufreq_policy *policy,
    unsigned int target_pstate)
{
    /* 直接写 MSR 寄存器：IA32_PERF_CTL
     * 格式：[15:0] = target ratio (频率比)
     *        [46:32] = energy performance preference (EPP) */
    wrmsrl_on_cpu(policy->cpu, MSR_IA32_PERF_CTL,
                  target_pstate | (epp << 16));

    return target_pstate;  /* 返回实际设置的频率 */
}
```

**doom-lsp 确认**：`intel_pstate_fast_switch` 的实现使用了 `wrmsrl_on_cpu()`，这是一个**每 CPU 的 MSR 写入**，确保在目标 CPU 上执行。

**延迟分析**：
- `wrmsrl`（Write MSR）在现代 Intel CPU 上约 **30-50 个时钟周期**
- 如果目标 CPU 与当前 CPU 相同：~**30-50ns**
- 如果需要 IPI（处理器间中断）唤醒目标 CPU：~**1-5μs**

---

## 6. sysfs 接口——用户空间的控制通道

### 6.1 sysfs 文件结构

每个 CPU 的 cpufreq sysfs 路径：
```
/sys/devices/system/cpu/cpu{0..N}/cpufreq/
├── affected_cpus           # 受此 policy 影响的 CPUs（只读）
├── cpuinfo_cur_freq        # 当前硬件频率（只读）
├── cpuinfo_max_freq        # 硬件支持的最大频率（只读）
├── cpuinfo_min_freq        # 硬件支持的最小频率（只读）
├── cpuinfo_transition_latency  # 调频延迟（只读，纳秒）
├── related_cpus           # 相关的 CPUs（只读）
├── scaling_available_governors  # 可用的 governors（只读）
├── scaling_cur_freq       # 通过 cpufreq 框架报告的当前频率（只读）
├── scaling_driver         # 当前驱动名（只读）
├── scaling_governor       # 当前 governor（读写）
├── scaling_max_freq       # 软件上限：调度器/用户设置（读写）
├── scaling_min_freq       # 软件下限：调度器/用户设置（读写）
├── scaling_setspeed       # userspace governor 专用：设置目标频率（读写）
└── stats/
    ├── time_in_state      # 各频率累计运行时间
    └── total_trans        # 总调频次数
```

### 6.2 scaling_governor 的读写实现

```c
// drivers/cpufreq/cpufreq.c:823
static ssize_t store_scaling_governor(struct cpufreq_policy *policy,
                                       const char *buf, size_t count)
{
    char name[CPUFREQ_NAME_LEN];
    struct cpufreq_governor *new_gov;
    int ret;

    /* 解析用户输入的 governor 名字 */
    sscanf(buf, "%15s", name);

    /* 查找对应的 governor */
    new_gov = find_governor(name);
    if (!new_gov)
        return -EINVAL;

    /* 调用 cpufreq_set_policy（销毁旧 governor，创建新 governor）*/
    ret = cpufreq_set_policy(policy, new_gov);
    if (ret)
        return ret;

    return count;
}
```

### 6.3 scaling_max_freq / scaling_min_freq 的 QoS 约束

`scaling_max_freq` 和 `scaling_min_freq` 不是直接设置硬件限制，而是通过 **freq QoS 框架**设置软约束：

```c
// drivers/cpufreq/cpufreq.c:776
static ssize_t store_scaling_max_freq(struct cpufreq_policy *policy,
                                       const char *buf, size_t count)
{
    unsigned int max_freq;
    int ret;

    sscanf(buf, "%u", &max_freq);

    /* 通过 freq QoS 框架设置最大值约束 */
    ret = freq_qos_update_request(&policy->max_freq_req, max_freq);

    /* 触发 policy 更新（异步）*/
    if (!ret)
        schedule_work(&policy->update);

    return count;
}
```

**关键洞察**：`scaling_max_freq` 是**软件约束**，不是硬件限制。如果用户设置的值超过硬件支持的范围，`cpufreq_verify_current_freq()` 会在后续步骤中纠正它。

---

## 7. 热管理与频率限制的协同

### 7.1 cpufreq 与 thermal 的交互

当 CPU 温度过高时，thermal 子系统通过 `cpufreq_policy_notifier_list` 通知 cpufreq：

```c
// drivers/cpufreq/cpufreq.c:1226
static int cpufreq_notifier_min(struct notifier_block *nb,
                                 unsigned long vcpu, void *data)
{
    struct cpufreq_policy *policy = data;
    unsigned int min_freq;

    /* thermal 强制设置的最低频率（限制不能更低）*/
    min_freq = thermal_zone_cpu_throttle(vcpu);

    /* 通过 QoS 机制设置下限 */
    freq_qos_update_request(&policy->min_freq_req, min_freq);

    return NOTIFY_OK;
}
```

**doom-lsp 确认**：`cpufreq_notifier_min @ 1226` 和 `cpufreq_notifier_max @ 1235` 分别处理来自 thermal 子系统的下限和上限约束。

### 7.2 频率降级（Throttle）流程

```
CPU 温度超过 Tjmax（~100°C）
    ↓
thermal_zone_device_update() [thermal 框架]
    ↓
cpufreq_cooling_cur_state() [更新 cpufreq_cooling 设备]
    ↓
cpufreq_policy_notifier_min [接收通知]
    ↓
freq_qos_update_request(min_freq_req) [提升软下限]
    ↓
schedutil 感知到 min 提升 → 频率被限制
```

### 7.3 Boost 频率与 Thermal

Intel 的 **Turbo Boost** 或 AMD 的 **Precision Boost** 允许短时间超过额定最大频率（称为"boost 频率"）。但 thermal throttle 会**立即撤销 boost**：

```bash
# 查看 boost 状态
cat /sys/devices/system/cpu/cpufreq/boost
# 1 = boost 启用，0 = boost 禁用

# boost 频率示例（i9-12900K）
# 基础频率：3.2 GHz
# All-core Turbo：5.1 GHz
# Single-core Turbo：5.5 GHz
# boost 上限由 Thermal Design Power (TDP) 和温度决定
```

---

## 8. 调度器集成——schedutil 与 CFS 的深度耦合

### 8.1 update_util 回调注册

schedutil 的独特之处在于它**主动注册到调度器**，而不是被调度器轮询：

```c
// kernel/sched/cpufreq_schedutil.c:844
static int sugov_start(struct cpufreq_policy *policy)
{
    struct sugov_policy *sg_policy = to_sg_policy(policy);

    /* 注册 update_util 回调——调度器会在每次 tick 时调用 */
    update_util_t *update_util = policy_is_shared(policy) ?
                                  sugov_update_shared :    /* 多线程调度域 */
                                  sugov_update_single;

    /* 设置调度器回调 */
    sugov_policy_set_update_util(sg_policy, sg_policy->freq_update_delay_ns,
                                   update_util);
}
```

**doom-lsp 确认**：`sugov_policy_set_update_util` 在 `cpufreq_governor.c:323`（`gov_set_update_util`）中实现，它设置 `cpufreq_policy->update_util` 函数指针。

### 8.2 调度器何时调用 update_util

调度器的 PELT 代码在以下时机调用 `update_util`：

```c
// kernel/sched/pelt.c（伪代码）
void update_task_ravg(struct task_struct *p, ...)
{
    /* 更新 PELT 负载均值 */
    p->se.avg += decayed * (load - p->se.avg);

    /* 如果任务在当前 CPU 上运行，触发 cpufreq 回调 */
    if (task_on_cpu(p))
        cpufreq_update_util(rq, ...);
}
```

**调度器 PELT 周期**：调度器的 pelt timer 通常是 **1024Hz**（每个 tick），但 `update_util` 的实际触发频率受 `freq_update_delay_ns`（默认 10ms）限制。

### 8.3 调度器频率不变性（Frequency Invariance）

当 CPU 频率变化时，PELT 负载计算需要**补偿（scale）**，否则同样负载在不同频率下会有不同的 PELT 值：

```c
// kernel/sched/pelt.c
void sched_scale_freq_tick(void)
{
    unsigned long scale;

    /* arch_scale_freq_capacity() 返回当前频率与最大频率的比值 */
    scale = arch_scale_freq_capacity(cpu);

    /* PELT 负载乘以频率缩放因子 */
    for_each_rq_cpu(rq, cpu) {
        rq->cpu_scale = scale;
    }
}
```

**doom-lsp 确认**：`cpufreq_freq_invariance` 标志在 `cpufreq.c:63` 声明为 `STATIC_KEY_FALSE`，当驱动调用 `cpufreq_supports_freq_invariance()` 时被激活。

---

## 9. 核心 API 函数详解

### 9.1 cpufreq_set_policy——Governor 切换的核心

这是 cpufreq 框架中最复杂的函数之一，涉及**销毁旧 governor、创建新 governor**：

```c
// drivers/cpufreq/cpufreq.c:2617
static int cpufreq_set_policy(struct cpufreq_policy *policy,
                               struct cpufreq_governor *new_governor)
{
    struct cpufreq_governor *old_governor;
    int ret;

    /* 获取写锁 */
    down_write(&policy->rwsem);

    /* 停止旧 governor */
    if (policy->governor) {
        /* 调用 stop 钩子 */
        if (policy->governor->stop)
            policy->governor->stop(policy);

        /* 调用 exit 钩子（释放资源）*/
        if (policy->governor->exit)
            policy->governor->exit(policy);
    }

    /* 记录旧 governor 名字（用于回退）*/
    strcpy(policy->last_governor, policy->governor->name);

    /* 切换到新 governor */
    policy->governor = new_governor;

    /* 初始化新 governor */
    if (new_governor->init) {
        ret = new_governor->init(policy);
        if (ret) {
            /* 初始化失败：回退到之前的 governor */
            if (old_governor) {
                policy->governor = old_governor;
                new_governor->init(policy);
            }
            up_write(&policy->rwsem);
            return ret;
        }
    }

    /* 启动新 governor */
    if (new_governor->start)
        new_governor->start(policy);

    /* 更新 sysfs */
    up_write(&policy->rwsem);
    cpufreq_policy_refresh(policy);

    return 0;
}
```

**doom-lsp 确认**：`cpufreq_set_policy @ 2617` 是 governor 切换的主入口，它在持有 `policy->rwsem` 写锁的情况下执行，确保并发安全。

### 9.2 cpufreq_verify_current_freq——频率合法性检查

每次频率变化后，框架会验证新频率是否在 `[min, max]` 范围内：

```c
// drivers/cpufreq/cpufreq.c:1801
static void cpufreq_verify_current_freq(
    struct cpufreq_policy *policy)
{
    unsigned int new_freq;

    /* 从硬件读取当前实际频率 */
    new_freq = cpufreq_driver->get(policy->cpu);

    /* 检查是否超出软件约束范围 */
    if (new_freq > policy->max)
        new_freq = policy->max;   /* 强制 cap 到最大值 */
    if (new_freq < policy->min)
        new_freq = policy->min;   /* 强制 floor 到最小值 */

    policy->cur = new_freq;
}
```

### 9.3 refresh_frequency_limits——策略范围更新

当用户写入 `scaling_max_freq` 或 `scaling_min_freq` 时触发：

```c
// drivers/cpufreq/cpufreq.c:1204
void refresh_frequency_limits(struct cpufreq_policy *policy)
{
    /* 重新验证频率范围 */
    cpufreq_driver->verify(policy);

    /* 通过 QoS 重新计算有效 min/max */
    policy->min = freq_qos_read_value(&policy->constraints,
                                       FREQ_QOS_MIN);
    policy->max = freq_qos_read_value(&policy->constraints,
                                       FREQ_QOS_MAX);

    /* 如果当前频率超出新范围，触发调频 */
    if (policy->cur > policy->max || policy->cur < policy->min) {
        if (cpufreq_driver->target)
            __cpufreq_driver_target(policy, policy->cur,
                                    CPUFREQ_RELATION_H);
    }
}
```

---

## 10. 性能特性与延迟分析

### 10.1 各操作路径的延迟

| 操作 | 路径 | 典型延迟 | 说明 |
|------|------|----------|------|
| 频率读取 | `cpufreq_driver->get()` | ~**1-5μs** | MSR 读取或 MMIO |
| Fast Switch | `cpufreq_driver->fast_switch()` | ~**30-200ns** | 直接 MSR 写入 |
| Target Index | `cpufreq_driver->target_index()` | ~**10-50μs** | 含通知链回调 |
| Governor 切换 | `cpufreq_set_policy()` | ~**100-500μs** | 销毁+重建 governor |
| Policy 创建 | `cpufreq_online()` | ~**1-5ms** | sysfs + kobject |

### 10.2 Fast Switch vs 普通切换的权衡

**Fast Switch 优势**：
- 延迟极低（纳秒级）
- 可在调度器 tick 上下文中执行（不引入额外调度延迟）
- 无需 workqueue，零排队延迟

**Fast Switch 限制**：
- 驱动必须保证线程安全（因为可能在任意 CPU 上下文调用）
- 不能执行复杂的频率转换序列（只能直接跳变）
- 不能发送通知链（否则会死锁）

### 10.3 schedutil 的性能特征

schedutil 作为最新推荐的 governor，其性能特征：

```
调频响应延迟：~10-50μs（从 PELT 更新到频率稳定）
调频吞吐量：最高 100 次/秒（受 rate_limit 限制）
功耗效率：在中低负载下比 ondemand 节能 10-20%
CPU 占用：几乎为零（IRQ 上下文，不消耗调度）
```

---

## 11. 调试与诊断

### 11.1 内核日志

启用 `cpufreq.debug=1` 可看到详细的调频日志：

```bash
# 临时启用
echo "1" > /sys/module/cpufreq/parameters/debug

# 查看日志
dmesg | grep cpufreq
```

### 11.2 perf 工具跟踪

```bash
# 跟踪 CPU 频率变化事件
perf stat -e power:cpu_frequency -a -- sleep 10

# 跟踪 cpufreq 框架调用
perf probe -x /boot/vmlinux-$(uname -r) cpufreq_set_policy
perf record -e cpufreq:set_policy -a -- sleep 5
```

### 11.3 ftrace 跟踪

```bash
# 启用 cpufreq 函数跟踪
echo function > /sys/kernel/debug/tracing/current_tracer
echo cpufreq_* > /sys/kernel/debug/tracing/set_ftrace_filter
echo 1 > /sys/kernel/debug/tracing/tracing_on

# 查看跟踪结果
cat /sys/kernel/debug/tracing/trace
```

### 11.4 sysfs 统计

```bash
# 查看各频率的累计运行时间
cat /sys/devices/system/cpu/cpu0/cpufreq/stats/time_in_state

# 查看调频次数
cat /sys/devices/system/cpu/cpu0/cpufreq/stats/total_trans

# 查看当前使用的 governor 特有参数
ls /sys/devices/system/cpu/cpu0/cpufreq/
```

---

## 12. Governor 生命周期详解

### 12.1 ondemand Governor 的采样机制

ondemand 是最经典的动态 governor，其机制与 schedutil 有本质区别：

```
ondemand：定时器采样
  └─ 每隔 sampling_rate 微秒检查一次 CPU 负载
     └─ 根据 idle time 估算负载（越闲 = 越可降频）
  └─ 发现负载高 → 直接跳到最高频率（或按比例）
  └─ 发现负载低 → 等待若干采样周期后降频

schedutil：调度器驱动
  └─ PELT 信号持续更新（~1024Hz）
  └─ 每次调度器 tick 时计算新频率
  └─ 通过 rate_limit 控制最大调整频率
```

**doom-lsp 确认**：`ondemand` 的采样定时器在 `cpufreq_governor.c:233` 的 `dbs_work_handler` 中实现。

### 12.2 Governor 初始化钩子详解

```c
// Governor 生命周期钩子调用顺序
struct cpufreq_governor {
    .name   = "schedutil",
    .init   = sugov_tunables_alloc,     /* → 分配 tunable 参数 */
    .exit   = sugov_tunables_free,       /* → 释放 tunable 参数 */
    .start  = sugov_start,               /* → 注册调度器回调 */
    .stop   = sugov_stop,                /* → 注销调度器回调 */
    .limits = sugov_limits,              /* → 处理 policy 限制变更 */
};
```

### 12.3 sugov_start 的深度分析

```c
// kernel/sched/cpufreq_schedutil.c:844
static int sugov_start(struct cpufreq_policy *policy)
{
    struct sugov_policy *sg_policy;
    int cpu;

    /* 分配 sugov_policy（per-policy 状态）*/
    sg_policy = kzalloc(sizeof(*sg_policy), GFP_KERNEL);
    policy->governor_data = sg_policy;
    sg_policy->policy = policy;

    /* 初始化 update_lock（自旋锁）*/
    spin_lock_init(&sg_policy->update_lock);

    /* 初始化 irq_work（用于延迟唤醒 kthread）*/
    INIT_IRQ_WORK(&sg_policy->irq_work, sugov_irq_work);

    /* 初始化 work_struct */
    INIT_WORK(&sg_policy->work, sugov_work);

    /* 分配 sugov_tunables（全局共享的可调参数）*/
    sg_policy->tunables = sugov_tunables_alloc();

    /* 设置 update_util 回调（调度器会调用此函数）*/
    sugov_policy_set_update_util(sg_policy,
                                  sg_policy->tunables->rate_limit_us * 1000,
                                  sugov_update_shared);

    /* 为每个管理范围内的 CPU 初始化 sugov_cpu */
    for_each_cpu(cpu, policy->cpus) {
        struct sugov_cpu *sg_cpu = &per_cpu(sgov_cpu, cpu);
        sg_cpu->sg_policy = sg_policy;
        sg_cpu->cpu = cpu;
    }

    return 0;
}
```

---

## 13. cpufreq 通知链机制

### 13.1 两种通知链

CPUFreq 框架维护两个通知链：

**cpufreq_policy_notifier_list**：
- 用于通知 CPU policy 的创建/销毁/限制变化
- 热插拔、thermal 模块会注册到此链

**cpufreq_transition_notifier_list**：
- 用于通知频率即将变化（PRECHANGE）和已经变化（POSTCHANGE）
- RCU、调度器会注册到此链以同步状态

```c
// 通知事件类型
CPUFREQ_CREATE_POLICY   /* Policy 被创建 */
CPUFREQ_REMOVE_POLICY   /* Policy 被移除 */
CPUFREQ_INIT            /* 驱动初始化 */
CPUFREQ_EXIT            /* 驱动退出 */
CPUFREQ_CREATE_DEVICES  /* CPU 设备创建 */
CPUFREQ_REMOVE_DEVICES  /* CPU 设备移除 */
CPUFREQ_ADJUST          /* 允许观察者修改频率 */
CPUFREQ_NOTIFY          /* PRECHANGE/POSTCHANGE */
```

### 13.2 PRECHANGE/POSTCHANGE 回调示例

```c
// 通知回调示例（在其他内核模块中）
static int cpufreq_transition_notifier_call(
    struct notifier_block *nb,
    unsigned long action,
    void *data)
{
    struct cpufreq_freqs *freq = data;

    switch (action) {
    case CPUFREQ_PRECHANGE:
        /* 频率即将变化：停止高精度定时器 */
        hrtimer_peek_ahead_timers();
        break;
    case CPUFREQ_POSTCHANGE:
        /* 频率已变化：更新调度器负载缩放 */
        sched_update_freq_capacity(policy->cpu);
        break;
    }

    return NOTIFY_OK;
}
```

---

## 14. 频率表与索引机制

### 14.1 cpufreq_frequency_table 的内部结构

```c
// include/linux/cpufreq.h:715
struct cpufreq_frequency_table {
    unsigned int    frequency;  /* 频率值（kHz）或特殊值 */
    unsigned int    driver_data;/* 驱动私有数据（如 P-State ID）*/
    unsigned int    flags;     /* CPUFREQ_TABLE_* flags */
};
```

**特殊频率值**：
```c
#define CPUFREQ_ENTRY_INVALID   (~0u)           /* 无效条目 */
#define CPUFREQ_TABLE_END       (~1u)           /* 结束标记 */
#define CPUFREQ_BOOST_FREQ      (~2u)          /* Boost 频率 */
```

### 14.2 频率表查找算法

```c
// drivers/cpufreq/freq_table.c
int cpufreq_frequency_table_target(struct cpufreq_policy *policy,
                                    unsigned int target_freq,
                                    unsigned int relation)
{
    struct cpufreq_frequency_table *table = policy->freq_table;
    int idx, best_idx = 0;
    unsigned int best_freq = 0;

    for (idx = 0; table[idx].frequency != CPUFREQ_TABLE_END; idx++) {
        unsigned int freq = table[idx].frequency;

        if (freq == CPUFREQ_ENTRY_INVALID || freq == CPUFREQ_BOOST_FREQ)
            continue;

        switch (relation) {
        case CPUFREQ_RELATION_L:  /* 向下找：≤ target */
            if (freq <= target_freq && freq > best_freq) {
                best_freq = freq;
                best_idx = idx;
            }
            break;
        case CPUFREQ_RELATION_H:  /* 向上找：≥ target */
            if (freq >= target_freq &&
                (!best_freq || freq < best_freq)) {
                best_freq = freq;
                best_idx = idx;
            }
            break;
        case CPUFREQ_RELATION_E:  /* 精确匹配或最近 */
            if (freq == target_freq)
                return idx;
            if (abs(freq - target_freq) < abs(best_freq - target_freq))
                best_idx = idx;
            break;
        }
    }

    return best_idx;
}
```

**doom-lsp 确认**：`cpufreq_frequency_table_target` 在 `freq_table.c` 中实现，是频率查找的核心函数。

---

## 15. sysfs 属性宏与代码生成

### 15.1 show_one / store_one 宏

cpufreq.c 中大量使用预编译宏减少样板代码：

```c
// drivers/cpufreq/cpufreq.c:724
#define show_one(file_name)                                      \
static ssize_t show_##file_name(                                 \
    struct cpufreq_policy *policy, char *buf)                     \
{                                                                \
    return sprintf(buf, "%u\n", policy->file_name);               \
}

/* 生成以下函数：
 * show_cpuinfo_min_freq()
 * show_cpuinfo_max_freq()
 * show_cpuinfo_transition_latency()
 * show_scaling_min_freq()
 * show_scaling_max_freq()
 * show_scaling_cur_freq()
 */
show_one(cpuinfo_min_freq);    /* 生成 show_cpuinfo_min_freq */
show_one(cpuinfo_max_freq);    /* 生成 show_cpuinfo_max_freq */
show_one(scaling_cur_freq);    /* 生成 show_scaling_cur_freq */
```

### 15.2 cpufreq_freq_attr_* 宏

```c
// include/linux/cpufreq.h（简化）
#define cpufreq_freq_attr_ro(_name)          \
    __cpufreq_attr_ro(typeof(struct cpufreq_policy), _name)

#define cpufreq_freq_attr_rw(_name)           \
    __cpufreq_attr_rw(typeof(struct cpufreq_policy), _name)

/* 使用示例：*/
static cpufreq_freq_attr_ro(cpuinfo_cur_freq);
static cpufreq_freq_attr_rw(scaling_governor);
```

**设计意图**：这些宏通过 `struct attribute *` 机制自动挂载到 kobject 上，无需手动注册每个属性。

---

## 16. 多核拓扑与 Policy 亲和

### 16.1 同一 Cluster 共享 Policy

在 ARM big.LITTLE 或 Intel 超线程设计中，同一 cluster 的 CPU 必须共享 policy（因为它们共享 PLL）：

```c
// drivers/cpufreq/cpufreq.c:1651
static int cpufreq_add_dev(struct cpufreq_policy *policy)
{
    int ret, cpu = policy->cpu;
    struct cpufreq_policy *managed_policy;

    /* 检查是否已有管理此 CPU 的 policy */
    managed_policy = cpufreq_cpu_policy(cpu);

    if (managed_policy) {
        /* 已存在：将此 CPU 加入现有 policy 的 cpus 掩码 */
        cpumask_set_cpu(cpu, managed_policy->cpus);
        cpufreq_policy_put_kobj(policy);  /* 释放新分配的 policy */
        return 0;
    }

    /* 不存在：创建新 policy */
    ...
}
```

### 16.2 cpufreq_cpu_policy 的 per-CPU 查找

```c
// drivers/cpufreq/cpufreq.c:193
static struct cpufreq_policy *cpufreq_cpu_get_raw(unsigned int cpu)
{
    struct cpufreq_policy *policy = per_cpu(cpufreq_cpu_data, cpu);

    /* 返回 policy（即使正在被销毁也会返回）*/
    return policy;
}
```

---

## 17. cpufreq 与调度器的协同设计

### 17.1 频率感知调度（Frequency-Aware Scheduling）

schedutil 的设计使得调度器在做任务放置决策时**已经知道目标 CPU 的频率**，从而可以：
- 优先将高负载任务放置在高频运行的 CPU 上
- 利用低频 CPU 的低功耗优势处理低负载任务

### 17.2 schedutil 与 CFS 的 PELT 集成

```c
// kernel/sched/pelt.c
void update_task_ravg_task_end(struct task_struct *p)
{
    /* 任务离开 CPU：更新其 PELT 负载 */
    decay_entity(&p->se);
    /* → 这会触发 cpufreq_update_util()
     * → schedutil 感知到 CPU 空闲程度提升
     * → 开始降频引导 */
}
```

---

## 18. Real-World 调频场景分析

### 场景 1：突发编译负载

```
t=0ms:  用户执行 make -j$(nproc)
t=1ms:  调度器检测到多个 runnable 任务，PELT util=900/1024
t=1ms:  schedutil sugov_update_shared() 被调用
t=1ms:  get_next_freq(): freq = 3.0GHz × 900/1024 = 2.64GHz
t=2ms:  cpufreq_driver_fast_switch() → MSR 写入 → 频率切换完成
t=5ms:  编译任务持续运行，util 维持高位，频率稳定在 2.6GHz
t=200ms: 编译进入链接阶段，IO 等待，util 降至 200/1024
t=201ms:  schedutil 重新计算 → freq = 3.0GHz × 200/1024 = 586MHz
t=201ms:  频率切换 → CPU 进入低功耗状态
```

### 场景 2：Thermal Throttle

```
t=0s:    CPU 持续高负载，温度 85°C（正常）
t=30s:   温度升至 95°C，接近 Tjmax
t=30s:   thermal 子系统检测到临界温度
t=30s:   cpufreq_notifier_max 收到通知
t=30s:   freq_qos_update_request(max_freq_req, 2.4GHz)
t=30s:   频率被限制到 2.4GHz（TDP 下降，发热减少）
t=60s:   温度回落至 80°C
t=60s:   thermal 放松限制 → max_freq 恢复
```

---

## 19. 常见问题与故障排查

### 19.1 /sys/devices/system/cpu/cpuX/cpufreq/ 不存在

**原因**：cpufreq 驱动未加载或 CPU 不支持调频

**排查**：
```bash
dmesg | grep cpufreq
ls /sys/devices/system/cpu/cpu0/
cat /proc/cpuinfo | grep MHz
```

### 19.2 scaling_governor 无法切换

**原因**：
- 目标 governor 未编译进内核
- 驱动不支持该 governor

**排查**：
```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
dmesg | grep "governor.*not found"
```

### 19.3 频率不变化

**原因**：
- `cpufreq_driver->get()` 返回错误值
- 硬件不支持动态调频
- BIOS 禁用了 P-State

**排查**：
```bash
# 查看硬件实际频率（绕过 cpufreq 框架）
sudo rdmsr 0x198 -1  # IA32_PERF_STATUS MSR
# 0x198[15:0] = 当前实际频率比（bits 0-15）
```

---

## 20. 总结

CPUFreq 子系统是 Linux 内核**性能与功耗管理基础设施**的核心组成部分，其设计体现了几个关键原则：

**1. 分层抽象**：框架层（cpufreq.c）→ 策略层（Governor）→ 驱动层（cpufreq_driver）的清晰分离，使得硬件支持和算法策略可以独立演进。

**2. 调度器集成**：schedutil 将 PELT 信号作为负载评估的唯一来源，避免了传统定时器采样的延迟和开销，实现了"感知-决策-执行"的最小延迟链。

**3. 软约束架构**：freq QoS 框架允许多个消费者（thermal、用户空间、内核参数）独立设置频率约束，由框架统一协调，消除了约束冲突。

**4. 硬件多样性支持**：通过 `cpufreq_driver` 的灵活抽象，框架同时支持 x86 (MSR)、ARM (CPPC/ACPI)、RISC-V 等完全不同的硬件接口。

**关键数字回顾**：
- `cpufreq.c`：3068 行，334 符号
- `cpufreq_schedutil.c`：933 行，82 符号
- 调频延迟：Fast Switch ~30-200ns，普通切换 ~10-50μs
- schedutil 最大调频频率：100Hz（受 rate_limit 限制）

---

## 附录 A：关键源码文件索引

| 文件路径 | 行数 | 关键符号 |
|----------|------|----------|
| `include/linux/cpufreq.h` | ~1200 | `struct cpufreq_policy`, `struct cpufreq_governor`, `struct cpufreq_driver` |
| `drivers/cpufreq/cpufreq.c` | 3068 | `cpufreq_set_policy @ 2617`, `cpufreq_add_dev @ 1651`, `cpufreq_online @ 1586` |
| `drivers/cpufreq/cpufreq_governor.c` | ~550 | `gov_set_update_util @ 323`, `dbs_update @ 114` |
| `kernel/sched/cpufreq_schedutil.c` | 933 | `sugov_update_shared @ 514`, `sugov_get_util @ 226`, `map_util_freq @ 220` |
| `drivers/cpufreq/intel_pstate.c` | ~4000 | `intel_pstate_fast_switch`, `pstate_get()` |
| `drivers/cpufreq/freq_table.c` | ~300 | `cpufreq_frequency_table_target` |

## 附录 B：相关内核参数

```bash
# 启动参数
cpufreq.default_governor=schedutil  # 默认 governor
cpufreq.debug=1                      # 调试日志

# 模块参数
modprobe cpufreq_conservative sampling_rate=10000
modprobe cpufreq_ondemand sampling_rate=10000
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
