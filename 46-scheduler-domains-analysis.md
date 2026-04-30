# scheduler domains — 多核负载均衡深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/topology.c` + `kernel/sched/deadline.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Scheduler Domains** 将 CPU 分组为层级域，实现多级负载均衡：
- **SCHED_SOFTIRQ**：触发负载均衡
- **SD_SHARE_PKG_RESOURCES**：共享缓存/Memory bandwidth
- **SD_SHARE_CPU_GROUPS**：共享 CPU 包

---

## 1. 核心数据结构

### 1.1 sched_domain — 调度域

```c
// include/linux/sched/topology.h — sched_domain
struct sched_domain {
    // 层级信息
    int                     span_top;       // 域内 CPU 数
    unsigned long           span[1];        // 域内 CPU 掩码（bitmask）

    // 父/子域
    struct sched_domain     *parent;        // 上一级（更大的域）
    struct sched_domain     *child;         // 下一级（更小的域）

    // 分组信息
    struct sched_domain_shared *shared;     // 域间共享资源
    struct sched_group      *groups;        // 域内 CPU 组

    // 负载信息
    unsigned long           lb_count[SD_BALANCE_EXEC]; // 平衡次数
    unsigned long           lb_flags[SD_BALANCE_EXEC];   // 平衡标志
    unsigned long           last_balance;   // 上次平衡时间
    unsigned int            balance_exec;   // 本次平衡执行耗时

    // 域配置（SD_* 标志）
    unsigned int            flags;          // SD_* 标志
    int                     level;          // 层级（0=最近）

    // 触发频率
    unsigned int            min_interval;   // 最小平衡间隔
    unsigned int            max_interval;   // 最大平衡间隔
    unsigned int            busy_factor;    // 繁忙因子（跳过繁忙组的平衡）

    // 名称（调试用）
    const char              *name;          // "SMT" "MC" "DIE" "NODE"
};
```

### 1.2 sched_group — CPU 组

```c
// include/linux/sched/topology.h — sched_group
struct sched_group {
    struct sched_domain     *sd;            // 所属域
    unsigned long           cpumask;        // 组内 CPU 掩码
    unsigned long           capacity;       // 组容量（容量 = CPU数 * 调度实体）
    unsigned long           capacity_orig;   // 原始容量
    unsigned int            group_weight;   // 组内"权重"
    unsigned int            nr_running;     // 组内运行任务数

    // 统计
    struct sched_avg        avg;            // 组平均负载

    // 下一个组（形成循环）
    struct sched_group      *next;          // 同级下一个组
};
```

### 1.3 sched_domain_shared — 域间共享

```c
// include/linux/sched/topology.h — sched_domain_shared
struct sched_domain_shared {
    // 共享资源
    atomic_t                nr_busy_cpus;   // 域内繁忙 CPU 数
    unsigned long           has_blocked;    // 有阻塞任务的标志
    unsigned long           imbalance;      // 不平衡程度
    struct callback_head    *rcu;           // RCU 回调

    // 共享状态
    unsigned long           topology_hetero_level; // 异构层级
};
```

---

## 2. 负载均衡触发

### 2.1 load_balance — 主动均衡

```c
// kernel/sched/fair.c — load_balance
static int load_balance(int cpu, struct rq *rq,
                        struct sched_domain *sd, enum cpu_idle_type idle)
{
    struct sched_group *group;
    unsigned long leader_mismatch;
    unsigned long load;
    int pulled = 0;

    // 1. 计算本地 CPU 当前负载
    load = rq->nr_running * SCHED_CAPACITY_SCALE;

    // 2. 找到最繁忙的组
    busiest = find_busiest_group(cpu, sd, &idle, &load, &imbalance);

    if (!imbalance)
        return 0;  // 已经平衡

    // 3. 从 busiest 组迁移任务
    pulled = move_tasks(rq, cpu, busiest, &imbalance, sd);

    // 4. 更新统计
    sd->balance_exec += local_clock() - start_time;

    return pulled;
}
```

### 2.2 find_busiest_group — 找最繁忙的组

```c
// kernel/sched/fair.c — find_busiest_group
static struct sched_group *find_busiest_group(int cpu, struct sched_domain *sd, ...)
{
    struct sched_domain_shared *sds = sd->shared;

    // 1. 计算每个组的负载
    //    group_load = 组的 nr_running * 组的 capacity
    for_each_cpu(cpu, group->cpumask) {
        load = cpu_rq(cpu)->nr_running;
        total += load * cpu_capacity(cpu);
    }

    // 2. 找到超过阈值的组
    //    如果 busiest组的负载 > 本组的负载 * 1.25（SF_PICK）
    //    → 返回 busiest 组

    // 3. 否则返回平衡的组
    return sd->groups;
}
```

---

## 3. 不平衡阈值（imbalance）

```c
// kernel/sched/fair.c — calculate_imbalance
static unsigned long calculate_imbalance(struct sched_domain *sd, ...)
{
    unsigned long busiest_load, busiest_capacity;
    unsigned long this_load, this_capacity;

    // 计算不平衡量
    // imbalance = (busiest_load / busiest_capacity) - (this_load / this_capacity)
    // 如果 > 小于 sd->imbalance_pct（默认 25%），不需要移动

    if (busiest_load > this_load * sd->imbalance_pct / 100)
        return busiest_load - this_load;

    return 0;
}
```

---

## 4. idle 平衡类型

```c
// include/linux/sched/idle.h — enum cpu_idle_type
enum cpu_idle_type {
    CPU_IDLE,         // idle 线程（无任务）
    CPU_NOT_IDLE,     // 非 idle（正常负载）
    CPU_NEWLY_IDLE,   // 刚刚进入 idle（有任务要迁移）
    CPU_MAX_IDLE_TYPE // 边界
};

// 平衡频率：
// CPU_IDLE → 慢（避免频繁唤醒）
// CPU_NEWLY_IDLE → 快（尽快迁移，避免浪费）
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/sched/topology.h` | `struct sched_domain`、`struct sched_group` |
| `kernel/sched/topology.c` | `sched_init_numa`、`build_sched_domains` |
| `kernel/sched/fair.c` | `load_balance`、`find_busiest_group` |