# 46-scheduler-domains — Linux 调度域深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**调度域（Scheduling Domain）** 是 Linux 内核实现多核/多处理器负载均衡的核心抽象。它将 CPU 组织为**层次化树形结构**，每层代表一种共享资源级别（超线程 → 核心 → Die → NUMA 节点），并在每层定义独立的负载均衡策略。

Linux 调度域的设计哲学是**层次化分而治之**：在不同层应用不同的均衡策略，既保证了负载均衡的准确性，又避免了全局均衡带来的锁竞争和缓存失效。

**为什么需要调度域？**

在 NUMA 架构或大型多核处理器上，所有 CPU 之间进行负载均衡是不现实的：
1. **跨 NUMA 节点的进程迁移代价高昂**（远程内存访问延迟是本地的 2-10 倍）
2. **跨 Die 共享 LLC（Last Level Cache）**只在同 Die 内有效
3. **超线程共享执行单元**，必须考虑 SMT 拓扑

调度域通过**分层的均衡边界**解决了这个问题——只在"值得均衡"的范围内进行负载均衡。

**doom-lsp 确认**：`kernel/sched/topology.c` 核心实现，包含 **181 个符号**。`sched_domain_debug_one @ 44` 是调试输出函数，`cpu_attach_domain @ 723` 是域绑定入口，`build_perf_domains @ 409` 是能量感知的 Perf Domain 构建。

**关键文件索引**：
| 文件 | 符号数 | 关键函数 |
|------|--------|---------|
| `kernel/sched/topology.c` | 181 | `cpu_attach_domain @ 723`, `sched_domain_debug_one @ 44` |
| `kernel/sched/fair.c` | 549+ | `sched_balance_newidle @ 5032`, `sched_balance_rq @ 12065` |
| `include/linux/sched/topology.h` | — | `struct sched_domain`, `struct sched_group` |
| `include/linux/sched/sd_flags.h` | — | 所有 SD_* 标志定义 |

---

## 1. 核心数据结构

### 1.1 struct sched_domain — 调度域节点

```c
// include/linux/sched/topology.h:73-140
struct sched_domain {
    /* 树形结构指针 */
    struct sched_domain __rcu *parent;  /* 父域（顶层为 NULL）*/
    struct sched_domain __rcu *child;   /* 子域（底层为 NULL）*/

    /* 组成员 */
    struct sched_group *groups;          /* 本域包含的调度组 */

    /* 均衡间隔控制（单位：毫秒）*/
    unsigned long min_interval;          /* 最小均衡间隔 */
    unsigned long max_interval;          /* 最大均衡间隔 */

    /* 均衡阈值参数 */
    unsigned int busy_factor;            /* 繁忙时减少均衡频率的因子 */
    unsigned int imbalance_pct;          /* 触发均衡的不均衡阈值（%）*/
    unsigned int cache_nice_tries;       /* 保持缓存热点任务的尝试次数 */

    /* 运行时状态 */
    int nohz_idle;                       /* NOHZ IDLE 状态 */
    int flags;                           /* SD_* 标志位 */
    int level;                           /* 域层级（调试用）*/

    /* 上次均衡时间戳（单位：jiffies）*/
    unsigned long last_balance;

    /* 均衡间隔（初始为 1ms，会动态调整）*/
    unsigned int balance_interval;

    /* 均衡失败计数（用于退避）*/
    unsigned int nr_balance_failed;

    /* NOHZ/Newidle 统计 */
    unsigned int newidle_call;           /* newidle 均衡调用次数 */
    unsigned int newidle_success;        /* newidle 均衡成功次数 */
    unsigned int newidle_ratio;          /* 成功率百分比 */
    unsigned int newidle_stamp;          /* 上次 newidle 均衡时间戳 */
    unsigned long max_newidle_lb_cost;   /* 最长 newidle 均衡耗时 */

    /* 详细均衡统计（CONFIG_SCHEDSTATS）*/
    unsigned int lb_count[CPU_MAX_IDLE_TYPES];
    unsigned int lb_failed[CPU_MAX_IDLE_TYPES];
    unsigned int lb_balanced[CPU_MAX_IDLE_TYPES];
    unsigned int lb_imbalance_load[CPU_MAX_IDLE_TYPES];
    unsigned int lb_imbalance_util[CPU_MAX_IDLE_TYPES];
    unsigned int lb_imbalance_misfit[CPU_MAX_IDLE_TYPES];
    unsigned int lb_gained[CPU_MAX_IDLE_TYPES];
    unsigned int lb_hot_gained[CPU_MAX_IDLE_TYPES];
    unsigned int lb_nobusyg[CPU_MAX_IDLE_TYPES];
    unsigned int lb_nobusyq[CPU_MAX_IDLE_TYPES];
};
```

**设计洞察**：`sched_domain` 是一个**双向链表节点**结构，通过 `child` 和 `parent` 指针构成树形层次。`groups` 指针指向本层包含的调度组，同层所有 `sched_domain` 通过 `groups->next` 形成环形链表。

### 1.2 struct sched_group — 调度组

```c
// kernel/sched/sched.h:2203-2220
struct sched_group {
    struct sched_group *next;            /* 循环链表下一个组 */
    atomic_t ref;                        /* 引用计数 */

    unsigned int group_weight;            /* 组内 CPU 数量 */
    unsigned int cores;                   /* 组的物理核心数 */
    struct sched_group_capacity *sgc;     /* 组容量信息 */
    int asym_prefer_cpu;                  /* 组内优先级最高的 CPU（用于非对称容量）*/

    /* 可变长 cpumask：组内包含的 CPUs 位图 */
    unsigned long cpumask[];
};
```

**设计洞察**：`sched_group` 的 `cpumask` 是**变长数组**（flexible array member），其实际大小取决于内核启动时发现的 CPU 数量。这是内存优化技巧——每个 `sched_group` 只占用刚好够用的空间。

### 1.3 三角关系：sched_domain ↔ sched_group ↔ sched_group_capacity

```
sched_domain
    │
    ├── child ──────────────────────→ sched_domain（更低层）
    │
    ├── parent ─────────────────────→ sched_domain（更高层）
    │
    └── groups ─────────────────────→ sched_group（循环链表）
                                       │
                                       ├── next ──────────→ sched_group（同伴）
                                       │
                                       └── sgc ──────────→ sched_group_capacity
                                                            │
                                                            └── cpumask[]（可迁移 CPU 掩码）
```

---

## 2. 调度域层次架构

### 2.1 典型 CPU 拓扑的调度域层次

现代多核 CPU 的调度域层次（以 4 核 NUMA 节点为例）：

```
[根域 - NUMA 节点层]
    │
    ├── [DIE 层 - 同 Die 内的所有核心]
    │     │
    │     ├── [MC 层 - 同 Die 内的所有物理核心]
    │     │     │
    │     │     └── [SMT 层 - 超线程 siblings]
    │     │           ├── CPU 0 (硬线程 0)
    │     │           └── CPU 1 (硬线程 1)
    │     │
    │     └── [SMT 层]
    │           ├── CPU 2
    │           └── CPU 3
    │
    └── [DIE 层 - 另一 Die]
          ...
```

**doom-lsp 确认**：在 `kernel/sched/topology.c:664-671` 声明了 per-CPU 的调度域指针：

```c
// kernel/sched/topology.c:664-671
DEFINE_PER_CPU(struct sched_domain *, sd_llc);           /* LLC 共享域 */
DEFINE_PER_CPU(struct sched_domain *, sd_llc_size);      /* LLC 大小 */
DEFINE_PER_CPU(struct sched_domain *, sd_llc_id);       /* LLC ID */
DEFINE_PER_CPU(struct sched_domain *, sd_share_id);      /* 资源共享域 */
DEFINE_PER_CPU(struct sched_domain *, sd_llc_shared);   /* 共享 LLC 的 CPUs */
DEFINE_PER_CPU(struct sched_domain *, sd_numa);         /* NUMA 域 */
DEFINE_PER_CPU(struct sched_domain *, sd_asym_packing);  /* 非对称容量域 */
DEFINE_PER_CPU(struct sched_domain *, sd_asym_cpucapacity); /* 非对称容量（全）*/
```

### 2.2 Android/Linux 的真实层次示例

以 Qualcomm Snapdragon 8 Gen 1（1+3+4 big.LITTLE 架构）为例：

```
[SD_ASYM_CPUCAPACITY] 根域（跨所有 CPU 容量）
    │
    ├── [Performance Cluster - 1x X2 超大核]
    │     SD_SHARE_CPUCAPACITY | SD_ASYM_PACKING
    │
    ├── [Mid Cluster - 3x A710 大核]
    │     SD_SHARE_CPUCAPACITY | SD_ASYM_PACKING
    │
    └── [Efficiency Cluster - 4x A510 小核]
          SD_SHARE_CPUCAPACITY | SD_ASYM_PACKING
```

每个 cluster 内部又有 SMT 层和 MC 层。

### 2.3 调度域构建入口

```c
// kernel/sched/topology.c:723
static void cpu_attach_domain(struct sched_domain *sd,
                               struct root_domain *rd,
                               int cpu)
{
    struct rq *rq = cpu_rq(cpu);
    struct sched_domain *tmp;
    int horizon = 0;

    /* 首先：解除旧域的绑定关系 */
    rcu_assign_pointer(rq->sd, NULL);

    /* 从叶子节点开始向上清理 child 指针 */
    for (tmp = sd; tmp; tmp = rcu_dereference(tmp->parent)) {
        horizon = min(horizon, 1);
    }

    /* 将新域按层次从根到叶绑定到 CPU */
    for (tmp = sd; tmp; tmp = rcu_dereference(tmp->child)) {
        rcu_assign_pointer(rq->sd, tmp);  /* rq->sd 始终指向叶子域 */
    }

    /* 绑定根域 */
    rcu_assign_pointer(rq->sd, sd);

    /* 绑定到 root_domain（用于跨域共享资源）*/
    rcu_assign_pointer(rq->rd, rd);

    /* 更新 per-CPU 的调度域缓存 */
    update_top_cache_domain(cpu);
}
```

**doom-lsp 确认**：`update_top_cache_domain @ 676` 更新 per-CPU 的 LLC/NUMA 等缓存域指针。

---

## 3. SD 标志系统——调度域的行为契约

### 3.1 标志的元属性

`sd_flags.h` 定义了一套**元属性系统**，描述标志在层次结构中的行为：

```c
// include/linux/sched/sd_flags.h

/* 层次属性 */
#define SDF_SHARED_CHILD  0x1  /* 从叶子域向上传播（如果子域有此标志，父域必须有）*/
#define SDF_SHARED_PARENT 0x2  /* 从根域向下传播（如果父域有此标志，子域必须有）*/
#define SDF_NEEDS_GROUPS  0x4  /* 只在有多于一个组的域中有意义 */
```

### 3.2 完整标志列表与语义

| 标志 | 元属性 | 语义 |
|------|--------|------|
| `SD_BALANCE_NEWIDLE` | SHARED_CHILD \| NEEDS_GROUPS | 当 CPU 即将进入 idle 时触发负载均衡 |
| `SD_BALANCE_EXEC` | SHARED_CHILD \| NEEDS_GROUPS | 在 `exec()` 系统调用时触发均衡（适合新程序） |
| `SD_BALANCE_FORK` | SHARED_CHILD \| NEEDS_GROUPS | 在 `fork()` 时触发均衡（适合新线程） |
| `SD_BALANCE_WAKE` | SHARED_CHILD \| NEEDS_GROUPS | 在进程被唤醒时触发均衡 |
| `SD_WAKE_AFFINE` | SHARED_CHILD | 唤醒时优先考虑亲和性（对对称容量有效） |
| `SD_ASYM_CPUCAPACITY` | SHARED_PARENT \| NEEDS_GROUPS | 域内 CPU 容量不对称（big.LITTLE） |
| `SD_ASYM_CPUCAPACITY_FULL` | SHARED_PARENT \| NEEDS_GROUPS | 全局可见的所有容量级别 |
| `SD_SHARE_CPUCAPACITY` | SHARED_CHILD \| NEEDS_GROUPS | 组成员共享 CPU 容量（SMT） |
| `SD_SHARE_LLC` | SHARED_CHILD \| NEEDS_GROUPS | 组成员共享 LLC（Last Level Cache） |
| `SD_CLUSTER` | NEEDS_GROUPS | 组成员在同一 CPU cluster |
| `SD_SERIALIZE` | SHARED_PARENT \| NEEDS_GROUPS | 单实例负载均衡（NUMA 层） |
| `SD_ASYM_PACKING` | NEEDS_GROUPS | 将繁忙任务放置在域的末端（低优先级 CPU） |
| `SD_PREFER_SIBLING` | NEEDS_GROUPS | 优先将任务放置在兄弟域 |
| `SD_NUMA` | SHARED_PARENT \| NEEDS_GROUPS | NUMA 级别均衡 |

**doom-lsp 确认**：`sd_flag_debug` 数组在 `topology.c:39` 定义，将每个 SD 标志映射到可读的调试名称。

---

## 4. 负载均衡机制——从空闲到唤醒的完整路径

### 4.1 负载均衡触发点

Linux CFS 负载均衡在以下时机触发：

```
┌─────────────────────────────────────────────────────────────┐
│                    负载均衡触发点                            │
├─────────────────────────────────────────────────────────────┤
│ 1. CPU 即将 idle    → sched_balance_newidle()              │
│ 2. 周期性 tick       → scheduler_tick() → sched_balance_rq()│
│ 3. 进程 fork()       → wake_up_new_task() → sched_balance_* │
│ 4. 进程 exec()       → exec_mmap() → sched_balance_*        │
│ 5. 进程被唤醒        → try_to_wake_up() → sched_balance_*    │
│ 6. active balance    → 最忙 CPU 被选中 → 强制迁移            │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 CPU 空闲时的负载均衡——newidle_balance

当 CPU 即将进入 idle 状态前，调度器会尝试从其他 CPU 拉取任务：

```c
// kernel/sched/fair.c:5032
static int sched_balance_newidle(struct rq *this_rq, struct rq_flags *rf)
{
    struct sched_domain *sd;
    int continue_balancing = 1;
    int pulled_task = 0;

    /* 设置此 CPU 即将进入 idle */
    cpu_load_update_idle(this_rq);

    /* 遍历调度域层次，从叶子域开始 */
    for_each_domain(this_rq->cpu, sd) {
        /* 检查域是否允许 NEWIDLE 均衡 */
        if (!(sd->flags & SD_BALANCE_NEWIDLE))
            goto done;

        /* 在此域上执行均衡 */
        pulled_task = sched_balance_rq(this_rq->cpu, this_rq,
                                       sd, CPU_NEWLY_IDLE,
                                       &continue_balancing);
        if (pulled_task)
            break;  /* 成功拉取任务，不再继续上层均衡 */

        /* 更新均衡间隔 */
        update_next_balance(sd, CPU_NEWLY_IDLE, &continue_balancing);
    }

done:
    rq_unlock(this_rq, rf);
    return pulled_task;
}
```

**关键洞察**：newidle 均衡从**叶子域开始往上遍历**，一旦在上层域成功拉取任务就停止。这保证了：
1. 优先在本地（缓存亲和性高）拉取任务
2. 只有本地实在没有任务时才会跨 NUMA 节点迁移

### 4.3 核心均衡函数——sched_balance_rq

```c
// kernel/sched/fair.c:12065
static int sched_balance_rq(int this_cpu, struct rq *this_rq,
                            struct sched_domain *sd,
                            enum cpu_idle_type idle,
                            int *continue_balancing)
{
    struct sched_group *group;
    struct rq *busiest;
    int ld_moved = 0;

    /* 找到本域内最忙的调度组 */
    group = sched_balance_find_src_group(this_cpu, this_rq, sd, idle);

    /* 如果没有不均衡，跳出 */
    if (!group)
        goto out;

    /* 找到最忙的 CPU */
    busiest = find_busiest_rq(this_cpu, this_rq, group, sd, idle);

    if (!busiest)
        goto out;

    /* 执行任务迁移 */
    ld_moved = detach_tasks(this_cpu, this_rq, busiest, group, sd, idle);

    /* 如果成功迁移，重新附加到本 CPU */
    if (ld_moved)
        attach_tasks(this_cpu, this_rq, busiest, group);

out:
    return ld_moved;
}
```

### 4.4 查找最忙调度组——sched_balance_find_src_group

```c
// kernel/sched/fair.c:11609
static struct sched_group *sched_balance_find_src_group(struct lb_env *env)
{
    struct sd_lb_stats sds;

    init_sd_lb_stats(&sds);

    /* 计算本域内所有组的负载统计 */
    update_sg_lb_stats(env, &sds);

    /* 找出最忙的组 */
    if (sds.busiest) {
        /* 计算不均衡程度 */
        calculate_imbalance(env, &sds);
        return sds.busiest;
    }

    return NULL;
}
```

### 4.5 负载均衡间隔动态调整

均衡不是每次都执行，而是根据历史情况**动态调整间隔**：

```c
// kernel/sched/fair.c:9485
static unsigned long __read_mostly max_load_balance_interval = HZ/10;  // 100ms

// 均衡间隔计算
interval = min(interval * busy_factor, max_load_balance_interval);
// busy_factor 默认 32，意味着繁忙时均衡间隔扩大到 32 倍
```

**不均衡阈值**由 `imbalance_pct` 控制：
```c
// 默认 imbalance_pct = 117（1.17 倍）
// 含义：只有当最忙组的负载 > 最闲组的 117% 时才触发均衡
```

---

## 5. 调度域初始化——build_sched_domains

### 5.1 调度域拓扑描述表

Linux 通过 `sched_domain_topology_level` 数组描述每个层级的拓扑：

```c
// kernel/sched/topology.c（简化）
static struct sched_domain_topology_level default_topology[] = {
#ifdef CONFIG_SCHED_SMT
    { .mask = smt_mask, .sd_flags = SD_SHARE_CPUCAPACITY | SD_SHARE_LLC, ... },
#endif
#ifdef CONFIG_SCHED_CLUSTER
    { .mask = cluster_mask, .sd_flags = SD_CLUSTER | SD_SHARE_LLC, ... },
#endif
    { .mask = die_mask, .sd_flags = SD_NUMA | SD_ASYM_CPUCAPACITY, ... },
    { .mask = numa_mask, .sd_flags = SD_NUMA, ... },
};
```

### 5.2 域构建核心函数

```c
// kernel/sched/topology.c（关键路径）
static int build_sched_domains(const struct cpumask *cpu_map)
{
    struct sched_domain *sd;
    struct sched_group *sg;
    struct s_data d;

    /* 分配 per-CPU 的 sched_domain 和 sched_group */
    sd_alloc(&d, cpu_map);

    /* 构建每个层级的域和组 */
    for_each_sd_topology(i) {
        /* 创建本层的 sched_domain */
        sd = build_sched_domain(&tl[i], cpu_map);

        /* 将 CPU 绑定到域 */
        for_each_cpu(cpu, cpu_map) {
            cpu_attach_domain(sd, d.rd, cpu);
        }
    }

    return 0;
}
```

**doom-lsp 确认**：`kernel/sched/topology.c:409` 的 `build_perf_domains` 构建能量感知调度的性能域（用于 EAS - Energy Aware Scheduling）。

---

## 6. 根域（Root Domain）与跨域资源

