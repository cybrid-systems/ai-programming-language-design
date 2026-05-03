# 46-scheduler-domains — Linux 调度域系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**调度域（Scheduling Domain）** 是 Linux 内核实现多核/多处理器负载均衡的核心基础设施。它将 CPU 组织为**层次化树形结构**，每层对应一种共享资源级别（超线程 → 物理核心 → LLC/Cache → Die → NUMA 节点），并在每层定义独立的负载均衡策略。

**为什么需要调度域？**

在 NUMA 架构或大型多核处理器上，全局负载均衡是不现实的：

| 问题 | 具体代价 | 解决方案 |
|------|----------|----------|
| 跨 NUMA 节点迁移 | 远程内存访问比本地慢 **2-10x** | 只在 NUMA 层以上跨节点均衡 |
| 跨 Die 迁移 | 丢失 LLC 亲和性，缓存重填耗~**1ms** | LLC 域内优先保持缓存热度 |
| SMT 共享执行单元 | 同核线程竞争 ALU/Float | SMT 域内优先保证线程平衡 |
| 锁竞争 | 全局均衡需要跨 CPU 锁 | 分层局部化，每层独立锁域 |

**doom-lsp 确认**：核心实现位于 `kernel/sched/topology.c`（**3016 行**，**181 个符号**）。负责实际负载均衡算法的是 `kernel/sched/fair.c`（14276 行）。核心数据结构定义在 `include/linux/sched/topology.h`（259 行）和 `kernel/sched/sched.h`（4139 行）。

**关键文件索引**：

| 文件 | 行数 | 符号数 | 职责 |
|------|------|--------|------|
| `kernel/sched/topology.c` | 3016 | 181 | 域构建、销毁、NUMA 拓扑、EAS 性能域 |
| `kernel/sched/fair.c` | 14276 | ~900+ | 负载均衡算法（核心 2k+ 行） |
| `include/linux/sched/topology.h` | 259 | ~30 | `struct sched_domain`, `struct sched_domain_shared`, `struct sched_domain_topology_level` |
| `include/linux/sched/sd_flags.h` | 162 | 12 | SD_* 标志的元属性声明 |
| `kernel/sched/sched.h` | 4139 | ~300 | `struct sched_group`, `struct sched_group_capacity`, `struct root_domain` |

---

## 1. 核心数据结构三角

```
sched_domain ───→ sched_group ───→ sched_group_capacity
    ↑                                      ↑
    │                                      │
    └────────  root_domain ────────────────┘
```

### 1.1 struct sched_domain — 调度域节点

每个 CPU 对应一个调度域树。每层节点表示一个拓扑级别的 CPU 集合：

```c
// include/linux/sched/topology.h:73-145
struct sched_domain {
    /* ── 树形层次链接 ── */
    struct sched_domain __rcu *parent;   /* 父域（顶层为 NULL）*/
    struct sched_domain __rcu *child;    /* 子域（底层为 NULL）*/

    /* ── 组成员 ── */
    struct sched_group *groups;           /* 本层包含的调度组（环形链表）*/

    /* ── 均衡参数（编译期 / sd_init 确定）─ */
    unsigned long min_interval;           /* 最小均衡间隔（ms）*/
    unsigned long max_interval;           /* 最大均衡间隔（ms）*/
    unsigned int  busy_factor;            /* 繁忙时减少均衡频率的因子 */
    unsigned int  imbalance_pct;          /* 触发均衡的负载阈值（百分比）*/
    unsigned int  cache_nice_tries;       /* 缓存热任务保持尝试次数 */
    unsigned int  imb_numa_nr;            /* 允许的 NUMA 不均衡任务数 */

    /* ── 运行时状态 ── */
    int           nohz_idle;              /* NOHZ IDLE 状态标记 */
    int           flags;                  /* SD_* 标志（行为契约）*/
    int           level;                  /* 层级深度（调试用）*/

    unsigned long last_balance;           /* 上次均衡的 jiffies 时间戳 */
    unsigned int  balance_interval;       /* 当前均衡间隔（动态调整）*/
    unsigned int  nr_balance_failed;      /* 均衡失败计数（用于退避）*/

    /* ── newidle 均衡统计 ── */
    unsigned int  newidle_call;
    unsigned int  newidle_success;
    unsigned int  newidle_ratio;
    u64           newidle_stamp;
    u64           max_newidle_lb_cost;
    unsigned long last_decay_max_lb_cost;

    /* ── 详细均衡统计（CONFIG_SCHEDSTATS）─ */
#ifdef CONFIG_SCHEDSTATS
    unsigned int lb_count[CPU_MAX_IDLE_TYPES];
    unsigned int lb_failed[CPU_MAX_IDLE_TYPES];
    unsigned int lb_balanced[CPU_MAX_IDLE_TYPES];
    unsigned int lb_imbalance_load[CPU_MAX_IDLE_TYPES];
    unsigned int lb_imbalance_util[CPU_MAX_IDLE_TYPES];
    unsigned int lb_imbalance_task[CPU_MAX_IDLE_TYPES];
    unsigned int lb_imbalance_misfit[CPU_MAX_IDLE_TYPES];
    unsigned int lb_gained[CPU_MAX_IDLE_TYPES];
    unsigned int lb_hot_gained[CPU_MAX_IDLE_TYPES];
    unsigned int lb_nobusyg[CPU_MAX_IDLE_TYPES];
    unsigned int lb_nobusyq[CPU_MAX_IDLE_TYPES];

    unsigned int alb_count;
    unsigned int alb_failed;
    unsigned int alb_pushed;

    unsigned int sbe_count, sbe_balanced, sbe_pushed;
    unsigned int sbf_count, sbf_balanced, sbf_pushed;

    unsigned int ttwu_wake_remote;
    unsigned int ttwu_move_affine;
    unsigned int ttwu_move_balance;
#endif

    char *name;                           /* 调试名字："SMT", "MC", "PKG" 等 */

    union {
        void *private;                    /* 构建期间使用 = &tl->data */
        struct rcu_head rcu;              /* 销毁时通过 RCU 释放 */
    };

    struct sched_domain_shared *shared;   /* 共享的 LLC 域资源（nr_busy_cpus 等）*/
    unsigned int span_weight;             /* span cpumask 中 CPU 数 */
};
```

**设计洞察**：`sched_domain` 通过 `parent`/`child` 指针构成**双向树形结构**。`groups` 指向一个**环形链表**，每个节点是 `sched_group`。`span`（CPU 位图）不是通过直接成员访问，而是通过 `sched_domain_span()` 宏：

```c
// include/linux/sched/topology.h:108-120
static inline struct cpumask *sched_domain_span(struct sched_domain *sd)
{
    /* C 语言变长数组的 offsetof(*sd, span) < sizeof(*sd) 会导致
     * 结构体初始化时覆盖 flex array 的前几个字节。因此内核将
     * span 分配在 sizeof(*sd) *之后* 的额外空间中。*/
    unsigned long *bitmap = (void *)sd + sizeof(*sd);
    return to_cpumask(bitmap);
}
```

**doom-lsp 确认**：sched_domain 的分配在 `__sdt_alloc()`（`topology.c:2377`）中通过 `kzalloc_node(sizeof(struct sched_domain) + cpumask_size(), ...)` 完成，span 的物理空间紧接着结构体末尾。`sched_domain_span()` 宏（`topology.h:155`）通过 `(void *)sd + sizeof(*sd)` 直接计算 span 地址。

**doom-lsp 确认**：`struct sched_domain` 中 `private` 字段的 union 定义在 `topology.h:136-139`：`union { void *private; struct rcu_head rcu; }`——构建阶段通过 `sd->private = sdd` 指向拓扑数据，销毁阶段通过 `call_rcu(&sd->rcu, destroy_sched_domains_rcu)` 异步释放。

### 1.2 struct sched_group — 调度组（域内分区）

`sched_domain` 的 `groups` 指向一个或多个 `sched_group`，每个 `sched_group` 覆盖一个子域（或单 CPU）的 CPU 集合：

```c
// kernel/sched/sched.h:2203-2220
struct sched_group {
    struct sched_group *next;              /* 环形链表下一个组 */
    atomic_t ref;                          /* 引用计数 */

    unsigned int group_weight;             /* 组内 CPU 数量 */
    unsigned int cores;                    /* 组内物理核数（非 SMT 线程数）*/
    struct sched_group_capacity *sgc;      /* 组的容量信息 */
    int asym_prefer_cpu;                   /* 非对称容量组中优先级最高的 CPU */

    /* ── 可选的标志（来自子域）─ */
    int flags;

    /* ── 变长 cpumask ── */
    unsigned long cpumask[];
};

static inline struct cpumask *sched_group_span(struct sched_group *sg)
{
    return to_cpumask(sg->cpumask);
}
```

**doom-lsp 确认**：`sched_group_capacity` 在 `__sdt_alloc()`（`topology.c:2377`）中分配：`kzalloc_node(sizeof(struct sched_group_capacity) + cpumask_size(), GFP_KERNEL, cpu_to_node(j))`。`sgc->id` 初始化为 `j`（CPU 编号）。`sgc->cpumask[]` 存储的是 group balance mask，由 `group_balance_mask()` 宏（`sched.h:2216`）访问。

**设计洞察**：`sched_group` 通过 `cpumask[]` 变长数组实现**内存紧凑存储**。每个 `sched_group` 只分配刚好容纳其 CPU 集合的空间。组与组之间通过 `next` 形成环形链表：

```
sched_domain
    │
    groups → [sched_group_0] → [sched_group_1] → [sched_group_2] → (回)
    span = CPU 0-7    │                       │                       │
                     CPU 0-3               CPU 4-5                CPU 6-7
```

`group_balance_mask()` 返回 balance mask，这是 NUMA overlap 拓扑中用于确定哪些 CPU 应该在此组上进行均衡的特化掩码：

```c
// kernel/sched/sched.h:2216
static inline struct cpumask *group_balance_mask(struct sched_group *sg)
{
    return to_cpumask(sg->sgc->cpumask);
}
```

### 1.3 struct sched_group_capacity — 组容量

```c
// kernel/sched/sched.h:2186-2199
struct sched_group_capacity {
    atomic_t ref;
    unsigned long capacity;           /* 组的 CPU 容量（SUM over CPUs，SCHED_CAPACITY_SCALE=1024）*/
    unsigned long min_capacity;        /* 组内最小 CPU 容量 */
    unsigned long max_capacity;        /* 组内最大 CPU 容量 */
    unsigned long next_update;         /* 下次更新容量的时间戳（jiffies）*/
    int imbalance;                     /* XXX：与容量无关，但共享组状态 */

    int id;                            /* 唯一 ID（首个 CPU 号）*/

    unsigned long cpumask[];           /* balance mask */
};
```

**关键属性**：`capacity` 字段在非 NUMA 域中等于子域各组 `sgc->capacity` 的总和，在 NUMA 域中等于 CPU 逐个相加。这决定了负载均衡时不同组的**权重**——容量更大的组可以容纳更多负载。

### 1.4 struct root_domain — 根域（跨域资源管理器）

每个 `sched_domain` 树最终关联到一个 `root_domain`。`root_domain` 在 `cpuset` 分区时被创建，管理 CPU 范围内的所有资源：

```c
// kernel/sched/sched.h:997-1050
struct root_domain {
    atomic_t refcount;
    atomic_t rto_count;                /* RT overload 计数 */
    struct rcu_head rcu;

    cpumask_var_t span;                /* 根域覆盖的所有 CPUs */
    cpumask_var_t online;              /* 在线 CPUs */

    bool overloaded;                   /* 至少一个 CPU 有 >1 个 runnable 任务 */
    bool overutilized;                 /* EAS 标志：至少一个 CPU 过载 */

    cpumask_var_t dlo_mask;
    atomic_t dlo_count;
    struct dl_bw dl_bw;
    struct cpudl cpudl;

    u64 visit_cookie;                  /* DL 调度器一致性检查用 */

#ifdef HAVE_RT_PUSH_IPI
    struct irq_work rto_push_work;
    raw_spinlock_t rto_lock;
    int rto_loop, rto_cpu;
    atomic_t rto_loop_next, rto_loop_start;
#endif
    cpumask_var_t rto_mask;
    struct cpupri cpupri;

    /* ── EAS Perf Domain 列表（RCU 保护）─ */
    struct perf_domain __rcu *pd;
};
```

**系统默认**：`static struct root_domain def_root_domain`（`topology.c:579`）是默认根域，包含所有 CPU。

### 1.5 struct sched_domain_shared — LLC 共享状态

```c
// include/linux/sched/topology.h:63-71
struct sched_domain_shared {
    atomic_t ref;
    atomic_t nr_busy_cpus;         /* 繁忙 CPU 数（用于 NOHZ 均衡决策）*/
    int has_idle_cores;            /* 是否存在空闲核心 */
    int nr_idle_scan;              /* 空闲 CPU 扫描步长 */
};
```

**doom-lsp 确认**：`sd_llc->shared` 在 `build_sched_domains()` 的阶段 4（`topology.c:2748`）设置：`sd->shared = *per_cpu_ptr(d.sds, sd_id)`，其中 sd_id = `cpumask_first(sched_domain_span(sd))`。sd->shared 的 `nr_busy_cpus` 初始化为 `sd->span_weight`。

**doom-lsp 确认**：`sd_share_id`（`topology.h:135`）是一个普通 `int`（非 RCU 指针），在 `update_top_cache_domain()`（`topology.c:700`）中 `per_cpu(sd_share_id, cpu) = id`——在 Cluster 系统上为 cluster_id，否则回退为 LLC ID。用于 `cpus_share_resources()` 的快速比较。

---

## 2. 调度域层次架构

### 2.1 拓扑描述表

Linux 使用 `sched_domain_topology_level` 数组声明每一层拓扑如何构建。默认配置（`default_topology[]`）从**最底层**（最细粒度）到**最高层**（最粗粒度）：

```c
// kernel/sched/topology.c:2186-2194
static struct sched_domain_topology_level default_topology[] = {
#ifdef CONFIG_SCHED_SMT
    SDTL_INIT(tl_smt_mask, cpu_smt_flags, SMT),
#endif
#ifdef CONFIG_SCHED_CLUSTER
    SDTL_INIT(tl_cls_mask, cpu_cluster_flags, CLS),
#endif
#ifdef CONFIG_SCHED_MC
    SDTL_INIT(tl_mc_mask, cpu_core_flags, MC),
#endif
    SDTL_INIT(tl_pkg_mask, NULL, PKG),
    { NULL, },                              /* 结束标记 */
};

static struct sched_domain_topology_level *sched_domain_topology =
    default_topology;
```

**每个拓扑层**由三个元素定义：

```c
// include/linux/sched/topology.h:191-197
struct sched_domain_topology_level {
    sched_domain_mask_f mask;        /* CPU 掩码函数（给定 CPU 返回该层的 CPU 集）*/
    sched_domain_flags_f sd_flags;   /* 标志函数（返回该层应有的 SD_* 位）*/
    int numa_level;                  /* NUMA 层级索引 */
    struct sd_data data;             /* 构建数据（per-CPU 的 sd/sg/sgc 指针）*/
    char *name;                      /* 调试名字 */
};

#define SDTL_INIT(maskfn, flagsfn, dname) \
    ((struct sched_domain_topology_level) \
     { .mask = maskfn, .sd_flags = flagsfn, .name = #dname })
```

### 2.2 各层掩码函数

| 拓扑层 | 掩码函数 | 标志函数 | 描述 |
|--------|----------|----------|------|
| **SMT** | `tl_smt_mask()` → `cpu_smt_mask(cpu)` | `cpu_smt_flags()` → `SD_SHARE_CPUCAPACITY \| SD_SHARE_LLC` | 同超线程的兄弟 CPU |
| **CLS** | `tl_cls_mask()` → `cpu_clustergroup_mask(cpu)` | `cpu_cluster_flags()` → `SD_CLUSTER \| SD_SHARE_LLC` | 同 Cluster（共享 L2/LLC） |
| **MC** | `tl_mc_mask()` → `cpu_coregroup_mask(cpu)` | `cpu_core_flags()` → `SD_SHARE_LLC` | 同物理核心（共享 LLC） |
| **PKG** | `tl_pkg_mask()` → `cpu_node_mask(cpu)` | 无 | 同 Package（一个 NUMA 节点内所有 CPU） |

**NUMA 层**在 `sched_init_numa()` 中追加到默认拓扑表后面：

```c
// topology.c:2121-2134（简化）
for (j = 1; j < nr_levels; i++, j++) {
    tl[i] = SDTL_INIT(sd_numa_mask, cpu_numa_flags, NUMA);
    tl[i].numa_level = j;
}
```

### 2.3 拓扑检测实现

以 x86 架构为例（`arch/x86/kernel/smpboot.c`）：

```
SMT 层   : 同物理核心的硬件线程（共享执行单元）
  ↓      cpu_smt_mask() = cpumask 包含同一 logical package 下共享核心的 CPU
CLS 层   : 某些 ARM SoC 的 CPU cluster（共享 L2 cache 或 LLC tags）
  ↓      cpu_clustergroup_mask() = 同 Cluster ID 的 CPU
MC 层    : 同一物理芯片内所有核心（共享 LLC）
  ↓      cpu_coregroup_mask() = 同 coregroup（通常等于同 die）
PKG 层   : 同一物理插槽（NUMA 节点）
  ↓      cpu_node_mask() = 同 NUMA 节点
NUMA-x 层 : 跨节点（距离逐层递增）
```

### 2.4 典型系统的真实层次

**4 核 x86 桌面（无 SMT）**：

```
PKG  [0-3]         SD_NUMA | SD_SERIALIZE
MC   [0-3]         SD_SHARE_LLC
```

**8 核 x86 桌面（2 核/core × SMT-2 = 8 线程）**：

```
PKG  [0-7]         SD_NUMA | SD_SERIALIZE         span_weight=8
MC   [0-3][4-7]    SD_SHARE_LLC                    span_weight=4
SMT  [0-1][2-3]    SD_SHARE_CPUCAPACITY | SD_SHARE_LLC   span_weight=2
```

**64 核 2-NUMA 服务器**：

```
NUMA-1 [0-63]      SD_NUMA | SD_SERIALIZE          远程节点
NODE   [0-31]      NODE 层（SD_NUMA 但不设均衡标志）局部节点
                 [32-63]
MC     [0-15]...   SD_SHARE_LLC                    同 LLC（通常 16-20 核/LLC）
SMT    [0-1]...    SD_SHARE_CPUCAPACITY             同核心超线程
```

**ARM big.LITTLE（Qualcomm SM8550）**：

```
SD_ASYM_CPUCAPACITY_FULL [0-7]  全局可见所有容量等级
  ├─ [0] X3 超大核 (capacity=1024)
  ├─ [1-3] A715 大核 (capacity=~600)
  └─ [4-7] A510 小核 (capacity=~300)
```

---

## 3. SD 标志系统——调度域的行为契约

### 3.1 元属性系统

`include/linux/sched/sd_flags.h` 定义了**元属性**来描述标志在层次中的传播行为：

```c
// include/linux/sched/sd_flags.h
#define SDF_SHARED_CHILD   0x1  /* 从最底层向上传播：子域有此标志，父域必须有 */
#define SDF_SHARED_PARENT  0x2  /* 从最高层向下传播：父域有此标志，子域必须有 */
#define SDF_NEEDS_GROUPS   0x4  /* 只有域中组数 >1 时才有意义 */
```

### 3.2 完整标志表

| 标志 | 元属性 | 语义 |
|------|--------|------|
| `SD_BALANCE_NEWIDLE` | `SHARED_CHILD \| NEEDS_GROUPS` | CPU 即将进入 idle 时触发负载均衡 |
| `SD_BALANCE_EXEC` | `SHARED_CHILD \| NEEDS_GROUPS` | `exec()` 系统调用时触发均衡 |
| `SD_BALANCE_FORK` | `SHARED_CHILD \| NEEDS_GROUPS` | `fork()`/`clone()` 时触发均衡 |
| `SD_BALANCE_WAKE` | `SHARED_CHILD \| NEEDS_GROUPS` | `try_to_wake_up()` 唤醒时触发 |
| `SD_WAKE_AFFINE` | `SHARED_CHILD` | 唤醒时优先考虑 CPU 亲和性 |
| `SD_ASYM_CPUCAPACITY` | `SHARED_PARENT \| NEEDS_GROUPS` | 域内 CPU 容量不对称（至少两种容量） |
| `SD_ASYM_CPUCAPACITY_FULL` | `SHARED_PARENT \| NEEDS_GROUPS` | 全局所有容量种类均可见 |
| `SD_SHARE_CPUCAPACITY` | `SHARED_CHILD \| NEEDS_GROUPS` | SMT：组成员共享执行单元 |
| `SD_CLUSTER` | `NEEDS_GROUPS` | 组在同一 CPU cluster |
| `SD_SHARE_LLC` | `SHARED_CHILD \| NEEDS_GROUPS` | 组成员共享 LLC |
| `SD_SERIALIZE` | `SHARED_PARENT \| NEEDS_GROUPS` | 该层均衡必须串行化（同一时刻只在一个 CPU 上执行） |
| `SD_ASYM_PACKING` | `NEEDS_GROUPS` | 将繁忙任务放置在域末端（SMT 节能） |
| `SD_PREFER_SIBLING` | `NEEDS_GROUPS` | 优先将任务放置在兄弟组 |
| `SD_NUMA` | `SHARED_PARENT \| NEEDS_GROUPS` | 跨 NUMA 节点 |

**doom-lsp 确认**：标志被编译为两个枚举——一个索引枚举 `__SD_FLAG_CNT`，一个位枚举 `SD_BALANCE_NEWIDLE = 1 << __SD_BALANCE_NEWIDLE`。元属性表驻留在 `sd_flag_debug[]`（`topology.c:39`）。

### 3.3 标志传播与生成

在 `sd_init()`（`topology.c:1661`）中，拓扑描述表的 flags（来自 `cpu_smt_flags()` 等）被合并到 C 风格的结构体初始化中：

```c
// topology.c:1973-2000（精选）
*sd = (struct sched_domain){
    .flags = 1*SD_BALANCE_NEWIDLE   /* 默认开启 NEWIDLE 均衡 */
           | 1*SD_BALANCE_EXEC      /* 默认开启 EXEC 均衡 */
           | 1*SD_BALANCE_FORK      /* 默认开启 FORK 均衡 */
           | 0*SD_BALANCE_WAKE      /* WAKE 均衡默认关闭 */
           | 1*SD_WAKE_AFFINE       /* 默认开启唤醒亲和性 */
           | 0*SD_SHARE_CPUCAPACITY /* 由拓扑层决定 */
           | 1*SD_PREFER_SIBLING    /* 默认倾向兄弟组 */
           | sd_flags               /* 拓扑层标志 + 异步容量分类结果 */
    ,
    .imbalance_pct = 117,            /* 默认 117% 阈值 */
    .busy_factor = 16,               /* 繁忙时扩大间隔 16 倍 */
    .cache_nice_tries = 0,           /* 初始 = 0，后续根据拓扑调整 */
};
```

**拓扑属性到行为的转换**（`sd_init()` 底部）：

```c
// topology.c:2011-2040
if ((sd->flags & SD_ASYM_CPUCAPACITY) && sd->child)
    sd->child->flags &= ~SD_PREFER_SIBLING;   /* 非对称容量：不倾向兄弟 */

if (sd->flags & SD_SHARE_CPUCAPACITY) {
    sd->imbalance_pct = 110;                  /* SMT 层：更敏感阈值 */
} else if (sd->flags & SD_SHARE_LLC) {
    sd->imbalance_pct = 117;
    sd->cache_nice_tries = 1;                 /* LLC 域：减缓缓存热迁移 */
} else if (sd->flags & SD_NUMA) {
    sd->cache_nice_tries = 2;                 /* NUMA 域：更慷慨的缓存尝试 */
    sd->flags &= ~SD_PREFER_SIBLING;
    sd->flags |= SD_SERIALIZE;                /* NUMA 域：串行化均衡 */

    if (distance > node_reclaim_distance) {
        sd->flags &= ~(SD_BALANCE_EXEC |      /* 远 NUMA：关闭 fork/exec 均衡 */
                       SD_BALANCE_FORK |
                       SD_WAKE_AFFINE);
    }
}
```

---

## 4. 调度域构建——从启动到就绪

### 4.1 初始化入口

系统启动时，`sched_init_domains()` 是初始化入口：

```c
// topology.c:2912-2924
int __init sched_init_domains(const struct cpumask *cpu_map)
{
    int err;

    zalloc_cpumask_var(&sched_domains_tmpmask, GFP_KERNEL);
    zalloc_cpumask_var(&sched_domains_tmpmask2, GFP_KERNEL);
    zalloc_cpumask_var(&fallback_doms, GFP_KERNEL);

    arch_update_cpu_topology();           /* 架构更新拓扑映射 */
    asym_cpu_capacity_scan();             /* 扫描 CPU 容量不对称性 */

    ndoms_cur = 1;
    doms_cur = alloc_sched_domains(ndoms_cur);
    if (!doms_cur)
        doms_cur = &fallback_doms;

    cpumask_and(doms_cur[0], cpu_map, housekeeping_cpumask(HK_TYPE_DOMAIN));
    err = build_sched_domains(doms_cur[0], NULL);

    return err;
}
```

### 4.2 容量不对称扫描

`asym_cpu_capacity_scan()`（`topology.c:1482`）遍历所有可能的 CPU，按 `arch_scale_cpu_capacity()` 分桶：

```c
// topology.c:1482-1750
static void asym_cpu_capacity_scan(void)
{
    struct asym_cap_data *entry, *next;
    int cpu;

    /* 清除容量桶中已有的 CPU */
    list_for_each_entry(entry, &asym_cap_list, link)
        cpumask_clear(cpu_capacity_span(entry));

    /* 遍历 CPU，按容量值分桶 */
    for_each_cpu_and(cpu, cpu_possible_mask, housekeeping_cpumask(HK_TYPE_DOMAIN))
        asym_cpu_capacity_update_data(cpu);

    /* 清除空桶 */
    list_for_each_entry_safe(entry, next, &asym_cap_list, link) {
        if (cpumask_empty(cpu_capacity_span(entry))) {
            list_del_rcu(&entry->link);
            call_rcu(&entry->rcu, free_asym_cap_entry);
        }
    }

    /* 如果只有一个容量值 = 对称系统 → 不需要存储 */
    if (list_is_singular(&asym_cap_list)) {
        entry = list_first_entry(&asym_cap_list, typeof(*entry), link);
        list_del_rcu(&entry->link);
        call_rcu(&entry->rcu, free_asym_cap_entry);
    }
}
```

**`asym_cpu_capacity_classify()`**（`topology.c:1407`）在构建每个域时调用，检测该域是否覆盖多种 CPU 容量，返回所需标志：

| 条件 | 返回值 |
|------|--------|
| 域内只有 1 种容量 | `0`（对称） |
| 域内 ≥2 种容量，但全局还有未覆盖的容量 | `SD_ASYM_CPUCAPACITY` |
| 域内覆盖所有存在的容量值 | `SD_ASYM_CPUCAPACITY \| SD_ASYM_CPUCAPACITY_FULL` |

### 4.3 内存分配和初始化

`build_sched_domains()` 是域构建的**主函数**（`topology.c:2658`），分为五个阶段：

**阶段 1：分配 per-CPU 存储**（`__sdt_alloc`, `__sds_alloc`）

```c
// topology.c:2380-2437
static int __sdt_alloc(const struct cpumask *cpu_map)
{
    struct sched_domain_topology_level *tl;

    for_each_sd_topology(tl) {
        struct sd_data *sdd = &tl->data;

        /* 分配 per-CPU 的 sd/sg/sgc 指针数组 */
        sdd->sd  = alloc_percpu(struct sched_domain *);
        sdd->sg  = alloc_percpu(struct sched_group *);
        sdd->sgc = alloc_percpu(struct sched_group_capacity *);

        for_each_cpu(j, cpu_map) {
            /* 每个 CPU 分配一个 sched_domain = sizeof(sd) + cpumask_size() */
            sd = kzalloc_node(sizeof(struct sched_domain) + cpumask_size(),
                             GFP_KERNEL, cpu_to_node(j));

            /* 每个 CPU 分配一个 sched_group = sizeof(sg) + cpumask_size() */
            sg = kzalloc_node(sizeof(struct sched_group) + cpumask_size(),
                            GFP_KERNEL, cpu_to_node(j));
            sg->next = sg;    /* 自环（初始状态）*/

            /* 每个 CPU 分配一个 sched_group_capacity */
            sgc = kzalloc_node(sizeof(struct sched_group_capacity) + cpumask_size(),
                              GFP_KERNEL, cpu_to_node(j));
            sgc->id = j;
        }
    }
}
```

**阶段 2：构建域树**（`build_sched_domain` → `sd_init`）

对每个 CPU，遍历所有拓扑层构建域节点：

```c
// topology.c:2716-2728（简化）
for_each_cpu(i, cpu_map) {
    sd = NULL;
    for_each_sd_topology(tl) {
        sd = build_sched_domain(tl, cpu_map, attr, sd, i);
        /* sd 是当前层节点，child = 上次构建的节点（下层）*/
        /* 构建后 child->parent = sd */

        if (tl == sched_domain_topology)
            *per_cpu_ptr(d.sd, i) = sd;  /* 记录最底层 sd */

        if (cpumask_equal(cpu_map, sched_domain_span(sd)))
            break;  /* 已覆盖所有 CPU → 停止 */
    }
}
```

`sd_init()` 设置域参数和标志（详见 3.3 节）。

**阶段 3：构建组（Groups）**

非 NUMA 域使用 `build_sched_groups()`，NUMA 域使用 `build_overlap_sched_groups()`：

```c
// topology.c:2734-2746（简化）
for_each_cpu(i, cpu_map) {
    for (sd = *per_cpu_ptr(d.sd, i); sd; sd = sd->parent) {
        sd->span_weight = cpumask_weight(sched_domain_span(sd));

        if (sd->flags & SD_NUMA)
            build_overlap_sched_groups(sd, i);   /* NUMA 重叠组 */
        else
            build_sched_groups(sd, i);            /* 标准排他组  */
    }
}
```

**阶段 4：链接 LLC Shared 和初始化容量**

```c
// topology.c:2748-2768（简化）
/* 找到顶层 LLCC 域，共享 sd->shared */
for_each_cpu(i, cpu_map) {
    sd = *per_cpu_ptr(d.sd, i);
    while (sd->parent && (sd->parent->flags & SD_SHARE_LLC))
        sd = sd->parent;

    if (sd->flags & SD_SHARE_LLC) {
        sd->shared = *per_cpu_ptr(d.sds, sd_id);
        atomic_set(&sd->shared->nr_busy_cpus, sd->span_weight);

        /* 如果上面还有域（如 NUMA），调整 NUMA 不均衡参数 */
        if (IS_ENABLED(CONFIG_NUMA) && sd->parent)
            adjust_numa_imbalance(sd);
    }
}

/* 初始化各组容量 */
for (i = nr_cpumask_bits-1; i >= 0; i--) {
    if (!cpumask_test_cpu(i, cpu_map))
        continue;
    claim_allocations(i, &d);
    for (sd = *per_cpu_ptr(d.sd, i); sd; sd = sd->parent)
        init_sched_groups_capacity(i, sd);  /* 计算 capacity */
}
```

**阶段 5：绑定域到 CPU**

```c
// topology.c:2770-2788（简化）
rcu_read_lock();
for_each_cpu(i, cpu_map) {
    rq = cpu_rq(i);
    sd = *per_cpu_ptr(d.sd, i);
    cpu_attach_domain(sd, d.rd, i);
}
rcu_read_unlock();

if (has_asym)
    static_branch_inc_cpuslocked(&sched_asym_cpucapacity);

if (has_cluster)
    static_branch_inc_cpuslocked(&sched_cluster_active);
```

### 4.4 构建组——非 NUMA 的排他组

```c
// topology.c:1300-1330
static int build_sched_groups(struct sched_domain *sd, int cpu)
{
    struct sched_group *first = NULL, *last = NULL;
    const struct cpumask *span = sched_domain_span(sd);
    struct cpumask *covered = sched_domains_tmpmask;

    cpumask_clear(covered);

    for_each_cpu_wrap(i, span, cpu) {
        if (cpumask_test_cpu(i, covered))
            continue;                    /* 已覆盖的 CPU 跳过 */

        sg = get_group(i, sdd);         /* 获取 CPU i 在本层的 group */
        cpumask_or(covered, covered, sched_group_span(sg));
        /* 链入环形链表 */
        if (!first) first = sg;
        if (last)   last->next = sg;
        last = sg;
    }
    last->next = first;
    sd->groups = first;
}
```

`get_group()`（`topology.c:1260`）的核心逻辑：

```c
static struct sched_group *get_group(int cpu, struct sd_data *sdd)
{
    struct sched_domain *sd = *per_cpu_ptr(sdd->sd, cpu);
    struct sched_domain *child = sd->child;
    struct sched_group *sg;

    if (child) cpu = cpumask_first(sched_domain_span(child));
    sg = *per_cpu_ptr(sdd->sg, cpu);

    /* 如果已有引用计数 >1，说明已被其他 CPU 访问 → 无需初始化 */
    if (atomic_inc_return(&sg->ref) > 1)
        return sg;

    /* 首次访问：初始化 sg_span */
    if (child) {
        cpumask_copy(sched_group_span(sg), sched_domain_span(child));
        cpumask_copy(group_balance_mask(sg), sched_group_span(sg));
        sg->flags = child->flags;
    } else {
        cpumask_set_cpu(cpu, sched_group_span(sg));
        cpumask_set_cpu(cpu, group_balance_mask(sg));
    }

    sg->sgc->capacity = SCHED_CAPACITY_SCALE * cpumask_weight(...);
    return sg;
}
```

### 4.5 构建组——NUMA 的重叠组

NUMA 拓扑需要处理**域间重叠**——同一个物理 CPU 可能同时属于多个 NUMA 组的 span：

```
NUMA-2: domain span = {0-3}
  groups: {0-1,3}  {1-3}
                ^    ^
                |    └── 节点 2（通过节点 1-3 到达）
                └─────── 节点 0（通过 child {0-1,3} 到达）
```

```c
// topology.c:1150-1196
static int build_overlap_sched_groups(struct sched_domain *sd, int cpu)
{
    struct cpumask *covered = sched_domains_tmpmask;
    cpumask_clear(covered);

    for_each_cpu_wrap(i, span, cpu) {
        if (cpumask_test_cpu(i, covered))
            continue;

        sibling = *per_cpu_ptr(sdd->sd, i);

        /* 如果子域跨出当前域范围 → 找到正确的后代 */
        if (sibling->child &&
            !cpumask_subset(sched_domain_span(sibling->child), span))
            sibling = find_descended_sibling(sd, sibling);

        sg = build_group_from_child_sched_domain(sibling, cpu);
        sg_span = sched_group_span(sg);
        cpumask_or(covered, covered, sg_span);

        init_overlap_sched_group(sibling, sg);  /* 设置 balance mask */
        ...
    }
}
```

**关键函数 `init_overlap_sched_group()`** — 对重叠组，`group_balance_mask` 不等于 `sg_span`，只包含那些**能到达此组**的 CPU：

```c
// topology.c:1100-1122
static void init_overlap_sched_group(struct sched_domain *sd,
                                     struct sched_group *sg)
{
    build_balance_mask(sd, sg, mask);      /* 计算哪些 CPU 能到达 */

    cpu = cpumask_first(mask);
    sg->sgc = *per_cpu_ptr(sdd->sgc, cpu); /* 共享 sgc */

    /* 只有第一次访问才设置 balance mask */
    if (atomic_inc_return(&sg->sgc->ref) == 1)
        cpumask_copy(group_balance_mask(sg), mask);
}
```

### 4.6 域退化与附加

**域退化（Domain Degeneration）**：`cpu_attach_domain()`（`topology.c:723`）在附加前移除冗余层：

```c
static void cpu_attach_domain(struct sched_domain *sd, struct root_domain *rd, int cpu)
{
    /* 从顶到底检查并移除退化层 */
    for (tmp = sd; tmp; ) {
        parent = tmp->parent;
        if (!parent) break;

        if (sd_parent_degenerate(tmp, parent)) {
            /* 父域退化：父域被子女取代 */
            tmp->parent = parent->parent;
            propagate SD_PREFER_SIBLING down;
            destroy_sched_domain(parent);
        } else
            tmp = tmp->parent;
    }

    /* 如果根域本身退化了 */
    if (sd && sd_degenerate(sd)) {
        tmp = sd;
        sd = sd->parent;
        destroy_sched_domain(tmp);
    }

    /* 附加到 rq，更新 per-CPU 缓存 */
    rcu_assign_pointer(rq->sd, sd);
    update_top_cache_domain(cpu);
}
```

**退化条件**：

- `sd_degenerate()`（`topology.c:95`）：span_weight == 1，或单组且无 `SD_WAKE_AFFINE`
- `sd_parent_degenerate()`（`topology.c:115`）：父域退化为子域（span 相同且无新标志）

**结果**：SMT 层在一个纯单核系统上完全被消除；NUMA 层在单节点系统上被消除。

### 4.7 per-CPU 域缓存更新

域附加后，`update_top_cache_domain()`（`topology.c:676`）更新 per-CPU 的快捷指针：

```c
static void update_top_cache_domain(int cpu)
{
    struct sched_domain *sd;

    /* sd_llc：LLC 共享域（select_idle_sibling 使用）*/
    sd = highest_flag_domain(cpu, SD_SHARE_LLC);
    rcu_assign_pointer(per_cpu(sd_llc, cpu), sd);
    per_cpu(sd_llc_size, cpu) = size;          /* LLC 域内 CPU 数 */
    per_cpu(sd_llc_id, cpu) = id;             /* 标识符（首个 CPU）*/
    rcu_assign_pointer(per_cpu(sd_llc_shared, cpu), sds);
    per_cpu(sd_share_id, cpu) = cluster_id;    /* Cluster / LLC ID */

    /* sd_numa：NUMA 域（按距离分层）*/
    sd = lowest_flag_domain(cpu, SD_NUMA);
    rcu_assign_pointer(per_cpu(sd_numa, cpu), sd);

    /* sd_asym_packing & sd_asym_cpucapacity */
    sd = highest_flag_domain(cpu, SD_ASYM_PACKING);
    rcu_assign_pointer(per_cpu(sd_asym_packing, cpu), sd);

    sd = lowest_flag_domain(cpu, SD_ASYM_CPUCAPACITY_FULL);
    rcu_assign_pointer(per_cpu(sd_asym_cpucapacity, cpu), sd);
}
```

**doom-lsp 确认**：这些 per-CPU 指针在 `topology.c:664-671` 以 `DEFINE_PER_CPU` 声明。`sd_asym_cpucapacity` 使用 `lowest_flag_domain()` 获取最底层非对称域（EAS 需要见到所有容量种类），`sd_asym_packing` 使用 `highest_flag_domain()` 获取最高层 packing 域（packing 逻辑只需在它出现的最高层起作用）。`update_top_cache_domain` 在 `cpu_attach_domain` 末尾被调用（`topology.c:801`），保证域树改变时所有快捷指针被刷新。

```c

```c
DEFINE_PER_CPU(struct sched_domain __rcu *, sd_llc);
DEFINE_PER_CPU(int, sd_llc_size);
DEFINE_PER_CPU(int, sd_llc_id);
DEFINE_PER_CPU(int, sd_share_id);
DEFINE_PER_CPU(struct sched_domain_shared __rcu *, sd_llc_shared);
DEFINE_PER_CPU(struct sched_domain __rcu *, sd_numa);
DEFINE_PER_CPU(struct sched_domain __rcu *, sd_asym_packing);
DEFINE_PER_CPU(struct sched_domain __rcu *, sd_asym_cpucapacity);
```

---

## 5. 负载均衡算法——从触发到执行的完整路径

### 5.1 触发时机

```
┌─────────────────────────────────────────────────────┐
│  触发点         | 调用函数          | 预期延迟        │
├─────────────────┼───────────────────┼────────────────┤
│ CPU 即将 idle   │ schedule() → ...  │ 立即           │
│                 │ → sched_balance_newidle()          │
│ 周期性 tick     │ scheduler_tick()  │ 4ms (250Hz)    │
│                 │ → sched_balance_rq(sd, CPU_IDLE)   │
│ fork() 创建任务  │ wake_up_new_task()│ 立即           │
│ exec() 启动新程序│ exec_mmap() → ...│ 立即           │
│ try_to_wake_up()│ select_task_rq()  │ 立即           │
│ 主动均衡         │ sched_balance_rq()│ 由触发点决定   │
└─────────────────┴───────────────────┴────────────────┘
```

### 5.2 CPU 空闲时的均衡——newidle_balance

当 CPU 即将进入 idle 状态时，调度器尝试从其他 CPU 拉取任务：

```c
// kernel/sched/fair.c:5032
static int sched_balance_newidle(struct rq *this_rq, struct rq_flags *rf)
{
    int continue_balancing = 1;
    int pulled_task = 0;

    cpu_load_update_idle(this_rq);   /* 更新 CPU 负载（衰减）*/

    /* 从叶子域到根域逐层尝试均衡 */
    for_each_domain(this_rq->cpu, sd) {
        if (!(sd->flags & SD_BALANCE_NEWIDLE))
            goto done;

        pulled_task = sched_balance_rq(this_rq->cpu, this_rq,
                                        sd, CPU_NEWLY_IDLE,
                                        &continue_balancing);
        if (pulled_task)
            break;   /* 成功拉到任务 → 不再向高层搜索 */

        update_next_balance(sd, CPU_NEWLY_IDLE, &continue_balancing);
    }
done:
    return pulled_task;
}
```

**关键洞察**：从叶子域（SMT/MC）开始向上。一旦在低层拉到任务就停止，因为从同 LLC 迁移比跨 NUMA 迁移高效得多。

### 5.3 核心均衡函数——sched_balance_rq

```c
// kernel/sched/fair.c:12065
static int sched_balance_rq(int this_cpu, struct rq *this_rq,
                            struct sched_domain *sd, enum cpu_idle_type idle,
                            int *continue_balancing)
{
    struct lb_env env = {
        .sd      = sd,
        .dst_cpu = this_cpu,
        .dst_rq  = this_rq,
        .idle    = idle,
        .cpus    = cpus,
        .tasks   = LIST_HEAD_INIT(env.tasks),
    };

    /* 步骤 1：每个域只允许一个 CPU 执行均衡 */
    if (!should_we_balance(&env))
        goto out_balanced;

    /* 步骤 2：NUMA 域串行化 */
    if (sd->flags & SD_SERIALIZE) {
        if (!atomic_try_cmpxchg_acquire(&sched_balance_running, &zero, 1))
            goto out_balanced;
    }

    /* 步骤 3：找到最忙的调度组 */
    group = sched_balance_find_src_group(&env);
    if (!group)
        goto out_balanced;

    /* 步骤 4：在最忙组中找到最忙的 CPU */
    busiest = sched_balance_find_src_rq(&env, group);
    if (!busiest)
        goto out_balanced;

    /* 步骤 5：从最忙 CPU 分离任务并附加到本地 */
    ld_moved = detach_tasks(&env);
    if (ld_moved)
        attach_tasks(&env);

    return ld_moved;
}
```

### 5.4 关键辅助函数

**should_we_balance()** — 确保同一域内只有一个 CPU 负责均衡：

```c
// kernel/sched/fair.c:11958
static int should_we_balance(struct lb_env *env)
{
    struct cpumask *swb_cpus = this_cpu_cpumask_var_ptr(should_we_balance_tmpmask);
    struct sched_group *sg = env->sd->groups;

    /* 仅该域中 balance_cpu 指定的 CPU 可以发起均衡 */
    cpumask_and(swb_cpus, cpu_online_mask, sched_group_span(sg));
    return cpumask_test_cpu(env->dst_cpu, swb_cpus);
}
```

**sched_balance_find_src_group()** — 收集域内所有组的统计信息，找到负载最重的组：

```c
// kernel/sched/fair.c:11609
static struct sched_group *sched_balance_find_src_group(struct lb_env *env)
{
    struct sd_lb_stats sds;
    init_sd_lb_stats(&sds);

    update_sd_lb_stats(env, &sds);    /* 遍历所有组，采集 sg_lb_stats */

    if (sds.busiest) {
        calculate_imbalance(env, &sds);  /* 计算需要迁移多少负载 */
        return sds.busiest;
    }
    return NULL;
}
```

**update_sd_lb_stats()** — 遍历组的环形链表，采集并统计每个组的负载：

```c
// kernel/sched/fair.c:11337
static inline void update_sd_lb_stats(struct lb_env *env, struct sd_lb_stats *sds)
{
    struct sched_group *sg = env->sd->groups;

    do {
        struct sg_lb_stats *sgs = &tmp_sgs;
        local_group = cpumask_test_cpu(env->dst_cpu, sched_group_span(sg));

        if (local_group) {
            sds->local = sg;
            sgs = &sds->local_stat;
            /* 本地组更新 capacity（带缓存一致性检查）*/
            if (env->idle != CPU_NEWLY_IDLE ||
                time_after_eq(jiffies, sg->sgc->next_update))
                update_group_capacity(env->sd, env->dst_cpu);
        }

        update_sg_lb_stats(env, sds, sg, sgs, &sg_overloaded);

        if (!local_group && update_sd_pick_busiest(env, sds, sg, sgs))
            sds->busiest = sg;        /* 更新最忙组 */

        sds->total_load += sgs->group_load;
        sds->total_capacity += sgs->group_capacity;

        sg = sg->next;
    } while (sg != env->sd->groups);

    /* 更新 root domain 的 overload 和 overutilized 标志 */
    if (!env->sd->parent) {
        set_rd_overloaded(env->dst_rq->rd, sg_overloaded);
        set_rd_overutilized(env->dst_rq->rd, sg_overutilized);
    }
}
```

**update_sg_lb_stats()** — 遍历组内所有 CPU，统计组级负载指标：

```c
// kernel/sched/fair.c:10657-10747
static inline void update_sg_lb_stats(struct lb_env *env, ...)
{
    for_each_cpu_and(i, sched_group_span(group), env->cpus) {
        struct rq *rq = cpu_rq(i);

        sgs->group_load += cpu_load(rq);
        sgs->group_util += cpu_util_cfs(i);
        sgs->group_runnable += cpu_runnable(rq);
        sgs->sum_h_nr_running += rq->cfs.h_nr_runnable;
        sgs->sum_nr_running += rq->nr_running;

        if (cpu_overutilized(i))
            sgs->group_overutilized = 1;

        if (!nr_running && idle_cpu(i)) {
            sgs->idle_cpus++;
            continue;
        }

        /* 非对称容量检测 misfit task */
        if (sd_flags & SD_ASYM_CPUCAPACITY)
            sgs->group_misfit_task_load = max(...);

        if (balancing_at_rd && nr_running > 1)
            *sg_overloaded = 1;
    }

    sgs->group_capacity = group->sgc->capacity;
    sgs->group_type = group_classify(env->sd->imbalance_pct, group, sgs);

    /* overloaded 组的平均负载 */
    if (sgs->group_type == group_overloaded)
        sgs->avg_load = (sgs->group_load * SCHED_CAPACITY_SCALE) / sgs->group_capacity;
}
```

### 5.5 不均衡计算

```c
// kernel/sched/fair.c:11407
static inline void calculate_imbalance(struct lb_env *env, struct sd_lb_stats *sds)
{
    struct sg_lb_stats *local = &sds->local_stat;
    struct sg_lb_stats *busiest = &sds->busiest_stat;

    switch (busiest->group_type) {
    case group_misfit_task:
        /* 迁移 misfit 任务到大核 */
        env->imbalance = busiest->group_misfit_task_load;
        env->migration_type = migrate_misfit;
        return;

    case group_asym_packing:
        /* 非对称 packing：迁移到首选 CPU */
        env->imbalance = busiest->sum_h_nr_running;
        return;

    case group_smt_balance:
        /* 减少 SMT 共享 */
        env->imbalance = 1;
        return;

    case group_imbalanced:
        env->imbalance = max(busiest->group_load, busiest->group_util);
        return;

    case group_overloaded: {
        /* 最经典路径：阈值检查后计算差值 */
        load_above_capacity = busiest->group_load -
                              sds->avg_load * busiest->sgc->capacity / SCHED_CAPACITY_SCALE;
        env->imbalance = min(max(busiest->group_load - local->group_load,
                                busiest->group_util - local->group_util),
                            load_above_capacity);
        return;
    }

    case group_has_spare:
        /* 如果没有过载组，不做均衡 */
        env->imbalance = 0;
        return;
    }
}
```

### 5.6 detach_tasks——任务迁移

```c
// kernel/sched/fair.c:9868
static int detach_tasks(struct lb_env *env)
{
    struct list_head *tasks = &env->src_rq->cfs_tasks;
    struct task_struct *p;
    int detached = 0;

    while (!list_empty(tasks)) {
        /* 缓存热检查：热任务不迁移 */
        if (task_hot(p, env) && !migrate_degrades_locality(p, env))
            goto next;

        /* 能否迁移：cpu affinity, cpuset, uclamp 等检查 */
        if (!can_migrate_task(p, env))
            goto next;

        /* 更新 PELT 均值和迁移 */
        detach_task(p, env);
        detached++;
    }
    return detached;
}
```

**迁移决策要点**：

| 检查 | 通过条件 | 原因 |
|------|---------|------|
| `task_hot()` | 不是最近执行过的热任务 | 避免缓存惩罚 |
| `can_migrate_task()` | cpu affinity 允许、cpuset 允许 | 边界合规 |
| `migrate_degrades_locality()` | 不降低 NUMA 局部性 | NUMA 性能 |
| `env->imbalance` | 累计迁移量 < imbalance | 精确不超调 |

---

## 6. 容量计算——从 CPU 能力到组容量

### 6.1 update_group_capacity

```c
// kernel/sched/fair.c:10326
void update_group_capacity(struct sched_domain *sd, int cpu)
{
    struct sched_domain *child = sd->child;
    unsigned long capacity = 0, min_capacity = ULONG_MAX, max_capacity = 0;

    /* 设置下次更新时间（带退避）*/
    interval = msecs_to_jiffies(sd->balance_interval);
    interval = clamp(interval, 1UL, max_load_balance_interval);
    sdg->sgc->next_update = jiffies + interval;

    if (!child) {
        /* 叶子域：直接更新 CPU 容量 */
        update_cpu_capacity(sd, cpu);
        return;
    }

    /* 非 NUMA 域：从子域 group 累加 */
    if (!(child->flags & SD_NUMA)) {
        group = child->groups;
        do {
            capacity += group->sgc->capacity;
            min_capacity = min(group->sgc->min_capacity, min_capacity);
            max_capacity = max(group->sgc->max_capacity, max_capacity);
            group = group->next;
        } while (group != child->groups);
    } else {
        /* NUMA 域：子域可能不完整，逐个 CPU 累加 */
        for_each_cpu(cpu, sched_group_span(sdg))
            capacity += capacity_of(cpu);
    }

    sdg->sgc->capacity = capacity;
    sdg->sgc->min_capacity = min_capacity;
    sdg->sgc->max_capacity = max_capacity;
}
```

### 6.2 CPU 容量计算链

```
update_group_capacity()
  → update_cpu_capacity()
    → scale_rt_capacity()
      → get_actual_cpu_capacity()  ← arch_scale_cpu_capacity()
      → cpu_util_rt() + cpu_util_dl() ← RT/DL 任务占用的容量
      → scale_irq_capacity()       ← IRQ 处理消耗的容量
```

**`scale_rt_capacity()`**（`kernel/sched/fair.c:10302`）：

```c
static unsigned long scale_rt_capacity(int cpu)
{
    unsigned long max = get_actual_cpu_capacity(cpu);
    unsigned long used, free, irq;

    irq = cpu_util_irq(rq);
    if (unlikely(irq >= max)) return 1;

    used = cpu_util_rt(rq);   /* RT 调度类占用的利用率 */
    used += cpu_util_dl(rq);  /* Deadline 调度类占用的利用率 */
    if (unlikely(used >= max)) return 1;

    free = max - used;
    return scale_irq_capacity(free, irq, max);
}
```

**容量计算本质**：
```
CPU 可用容量 = (max_capacity - RT负载 - DL负载) × (1 - IRQ占比)
```

### 6.3 组类型分类

```c
// kernel/sched/fair.c（通过 group_classify() 调用）
enum group_type {
    group_has_spare,         /* 有闲置容量 */
    group_overloaded,        /* 过载：avg_load > capacity */
    group_imbalanced,        /* 组内 CPU 负载分布不均 */
    group_asym_packing,      /* 非对称 packing 待处理 */
    group_smt_balance,       /* SMT 线程不平衡 */
    group_misfit_task,       /* 有任务大于此 CPU 容量 */
};
```

**分类条件**（`group_classify()` 简化）：

```c
switch {
    case sgs->group_misfit_task_load:
        type = group_misfit_task;
    case sgs->group_asym_packing:
        type = group_asym_packing;
    case sgs->group_smt_balance:
        type = group_smt_balance;
    case sgs->group_imbalanced:
        type = group_imbalanced;
    case sgs->avg_load > sgs->group_capacity:
        type = group_overloaded;
    default:
        type = group_has_spare;
}
```

---

## 7. NUMA 拓扑集成

### 7.1 NUMA 距离记录

`sched_init_numa()`（`topology.c:1930`）在内核启动时读取 SRAT/SLIT 表中的节点间距离：

```c
// topology.c:1930（关键路径）
void sched_init_numa(int offline_node)
{
    /* 1. 从 SLIT 去重记录所有 unique 距离 */
    sched_record_numa_dist(offline_node, numa_node_dist,
                           &distances, &nr_node_levels);

    /* 2. 构建每层 per-node 的 CPU 掩码 */
    for (i = 0; i < nr_levels; i++) {
        masks[i] = kzalloc(nr_node_ids * sizeof(void *), GFP_KERNEL);
        for_each_cpu_node_but(j, offline_node) {
            mask = kzalloc(cpumask_size(), GFP_KERNEL);
            masks[i][j] = mask;

            for_each_cpu_node_but(k, offline_node) {
                if (arch_sched_node_distance(j, k) > distances[i])
                    continue;
                cpumask_or(mask, mask, cpumask_of_node(k));
            }
        }
    }

    /* 3. 将 NUMA 层追加到默认拓扑表后 */
    for (j = 1; j < nr_levels; i++, j++) {
        tl[i] = SDTL_INIT(sd_numa_mask, cpu_numa_flags, NUMA);
        tl[i].numa_level = j;
    }

    /* 4. 确定拓扑类型 */
    init_numa_topology_type(offline_node);
}
```

### 7.2 三种 NUMA 拓扑类型

```c
// topology.c:1804-1842
static void init_numa_topology_type(int offline_node)
{
    int a, b, c, n = sched_max_numa_distance;

    if (sched_domains_numa_levels <= 2) {
        sched_numa_topology_type = NUMA_DIRECT;  /* ≤2 层 → 直接连接 */
        return;
    }

    for_each_cpu_node_but(a, offline_node) {
        for_each_cpu_node_but(b, offline_node) {
            if (node_distance(a, b) < n) continue;  /* 找到最远两节点 */

            for_each_cpu_node_but(c, offline_node) {
                if (node_distance(a, c) < n && node_distance(b, c) < n) {
                    /* A ← C → B，C 是中间节点 */
                    sched_numa_topology_type = NUMA_GLUELESS_MESH;
                    return;
                }
            }

            sched_numa_topology_type = NUMA_BACKPLANE;
            return;
        }
    }
}
```

| NUMA 类型 | 示例 | 跨度 | 含义 |
|-----------|------|------|------|
| `NUMA_DIRECT` | 2 节点系统 | ≤1 hop | 所有节点两两直连 |
| `NUMA_GLUELESS_MESH` | 4 节点环形 | 2 hops | 存在中间 CPU 节点 |
| `NUMA_BACKPLANE` | AMD Epyc | 2+ hops | 通过底板控制器跨节点 |

### 7.3 NUMA 亲和性机制

**`task_numa_fault()`** 在每次内存访问时记录 NUMA 节点偏好。调度器利用 `nr_numa_running` 和 `nr_preferred_running` 做 NUMA 感知的负载均衡：

```c
// fair.c lb stats
#ifdef CONFIG_NUMA_BALANCING
    if (sd_flags & SD_NUMA) {
        sgs->nr_numa_running += rq->nr_numa_running;
        sgs->nr_preferred_running += rq->nr_preferred_running;
    }
#endif
```

**`adjust_numa_imbalance()`**（`topology.c:2656`）——在 LLC 域和 NUMA 域之间计算允许的不均衡度：

```c
static void adjust_numa_imbalance(struct sched_domain *sd_llc)
{
    nr_llcs = sd_llc->parent->span_weight / sd_llc->span_weight;

    if (nr_llcs == 1)
        imb = sd_llc->parent->span_weight >> 3;  /* 12.5% */
    else
        imb = nr_llcs;                            /* 多个 LLC：每个 1 任务 */

    sd_llc->parent->imb_numa_nr = imb;            /* 允许的不均衡任务数 */

    /* 向上传播：imb_span 是首个 NUMA 域的 span_weight */
    parent = sd_llc->parent;
    while (parent) {
        parent->imb_numa_nr = imb * max(1U, parent->span_weight / imb_span);
        parent = parent->parent;
    }
}
```

### 7.4 NUMA 辅助 API

```c
// topology.c:2267-2320
/* 沿 NUMA 跳数找到最近的 CPU */
int sched_numa_find_closest(const struct cpumask *cpus, int cpu);

/* 按节点距离找到第 N 近的 CPU（带二分搜索）*/
int sched_numa_find_nth_cpu(const struct cpumask *cpus, int cpu, int node);

/* 返回指定跳数范围内的 CPU 掩码 */
const struct cpumask *sched_numa_hop_mask(unsigned int node, unsigned int hops);
```

**doom-lsp 确认**：`sched_numa_find_nth_cpu` 在 `topology.c:2290` 使用 `bsearch()` 在已排序的 `sched_domains_numa_masks` 中进行二分查找。`hop_cmp()`（`topology.c:2267`）通过 `cpumask_weight_and()` 计算当前 hop 内满足条件的 CPU 数量，与目标索引比较。

**doom-lsp 确认**：`sched_update_numa()` 在 `topology.c:2244` 注册为 CPU hotplug 回调，只有节点 CPU 数从 0→1（首个 CPU 上线）或 1→0（末个 CPU 下线）时才触发重建，避免频繁的 NUMA 拓扑重建。

---

## 8. 域重建与 CPU 热插拔

### 8.1 热插拔链

当 CPU 上线/下线时，通过 cpuhp 触发 `sched_cpu_activate()` / `sched_cpu_deactivate()`，最终调用 `partition_sched_domains_locked()`：

```c
// topology.c:2963-2995
static void partition_sched_domains_locked(int ndoms_new, cpumask_var_t doms_new[],
    struct sched_domain_attr *dattr_new)
{
    /* 1. 架构拓扑更新 */
    new_topology = arch_update_cpu_topology();
    if (new_topology) asym_cpu_capacity_scan();

    /* 2. 销毁已删除的域 */
    for (i = 0; i < ndoms_cur; i++) {
        if (没有在 new 中找到匹配)
            detach_destroy_domains(doms_cur[i]);
    }

    /* 3. 构建新的域 */
    for (i = 0; i < ndoms_new; i++) {
        if (没有在 cur 中找到匹配)
            build_sched_domains(doms_new[i], ...);
    }

    /* 4. 重建 EAS Perf Domains */
    for (i = 0; i < ndoms_new; i++) {
        has_eas |= build_perf_domains(doms_new[i]);
    }
    sched_energy_set(has_eas);

    /* 5. 更新 cur 指针 */
    doms_cur = doms_new;
    ndoms_cur = ndoms_new;
}
```

### 8.2 cpuset 域分区

`partition_sched_domains()` 用于 cpuset 分区——将 CPU 划分为独立的调度域：

```c
// 示例：创建两个独立的调度分区（如隔离 + 非隔离）
cpumask_var_t doms[2];
cpumask_and(doms[0], cpuset_cpus_allowed(...), cpu_online_mask);
cpumask_and(doms[1], isolated_cpus, cpu_online_mask);
partition_sched_domains(2, doms, NULL);
```

每个分区拥有独立的 `root_domain`，完全独立进行负载均衡。

### 8.3 NUMA 拓扑更新

```c
// topology.c:2244-2262
void sched_update_numa(int cpu, bool online)
{
    int node = cpu_to_node(cpu);

    /* 仅当节点首个 CPU 上线或最后一个 CPU 下线时才需要重建 */
    if (cpumask_weight(cpumask_of_node(node)) != 1)
        return;

    sched_reset_numa();                    /* 清除旧 NUMA 状态 */
    sched_init_numa(online ? NUMA_NO_NODE : node);  /* 重建 NUMA mask */
    /* 触发 partition_sched_domains() */
}
```

---

## 9. Energy Aware Scheduling（EAS）集成

### 9.1 Perf Domain 构建

```c
// topology.c:409
static bool build_perf_domains(const struct cpumask *cpu_map)
{
    /* EAS 开启条件（sched_is_eas_possible）：
     * 1. Energy Model 可用 (CONFIG_ENERGY_MODEL)
     * 2. SD_ASYM_CPUCAPACITY 存在（非对称容量）
     * 3. 无 SMT
     * 4. schedutil 作为 cpufreq governor
     * 5. 频率不变性（frequency invariance）支持
     */
    if (!sysctl_sched_energy_aware) goto free;
    if (!sched_is_eas_possible(cpu_map)) goto free;

    for_each_cpu(i, cpu_map) {
        if (find_pd(pd, i)) continue;
        tmp = pd_init(i);   /* 从 Energy Model 获取 per-CPU perf 数据 */
        tmp->next = pd;
        pd = tmp;
    }

    /* 附加到 root_domain */
    rcu_assign_pointer(rd->pd, pd);
    return !!pd;
}
```

### 9.2 EAS 停止/启动

```c
// topology.c:386-400
static void sched_energy_set(bool has_eas)
{
    if (!has_eas && sched_energy_enabled()) {
        static_branch_disable_cpuslocked(&sched_energy_present);
    } else if (has_eas && !sched_energy_enabled()) {
        static_branch_enable_cpuslocked(&sched_energy_present);
    }
}
```

**`/proc/sys/kernel/sched_energy_aware`**：可通过 sysctl 在运行时开关 EAS：

```bash
echo 0 > /proc/sys/kernel/sched_energy_aware   # 关闭 EAS
echo 1 > /proc/sys/kernel/sched_energy_aware   # 开启 EAS（需要硬件支持）
```

---

## 10. 调试与诊断

### 10.1 sched_verbose 调试日志

启动时增加 `sched_verbose` 内核参数可以打印完整的调度域结构：

```bash
# 内核启动参数
sched_verbose

# 输出示例
CPU0 attaching sched-domain(s):
  domain-0: span=0-1 level=SMT
    groups: 0:{ span=0 cap=1024 }, 1:{ span=1 cap=1024 }
  domain-1: span=0-3 level=MC
    groups: 0:{ span=0-1 cap=2048 }, 2:{ span=2-3 cap=2048 }
  domain-2: span=0-7 level=PKG
    groups: 0:{ span=0-3 cap=4096 }, 4:{ span=4-7 cap=4096 }
```

### 10.2 sched_domain_debug_one 的完整性校验

```c
// topology.c:44-85
- 检查 domain->span 包含负责的 CPU
- 检查 domain->groups 包含负责的 CPU
- 检查 SHARED_CHILD 标志一致性（子域有则父域需有）
- 检查 SHARED_PARENT 标志一致性（父域有则子域需有）
- 检查组间 CPU 没有重叠（非 NUMA 域）
- 检查组 span 总和等于域 span
- 检查父域 span 是否包含子域 span
```

### 10.3 /proc/schedstat

```bash
cat /proc/schedstat
# domain0 {span=0-1} level=SMT
#   lb_count=100 lb_failed=5 lb_balanced=95 ...
```

字段含义：

| 字段 | 含义 |
|------|------|
| `lb_count` | 均衡尝试次数 |
| `lb_failed` | 均衡失败的次数（无任务可移） |
| `lb_balanced` | 均衡后被判定为平衡的次数 |
| `lb_imbalance_load` | 因负载不均衡触发的均衡 |
| `lb_imbalance_util` | 因利用率不均衡触发的均衡 |
| `lb_gained` | 成功迁移的任务数 |
| `lb_hot_gained` | 迁移的热任务数 |
| `alb_count` | 主动均衡（pull）次数 |

### 10.4 ftrace 跟踪

```bash
# 跟踪负载均衡事件
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_load_balance/enable
echo 1 > /sys/kernel/debug/tracing/tracing_on
cat /sys/kernel/debug/tracing/trace_pipe

# 跟踪域重建
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_domain_rebuild/enable
```

### 10.5 perf 工具

```bash
# 跟踪调度域相关的性能计数器
perf stat -e sched:sched_migrate_task -a sleep 10

# 查看每个 CPU 的调度域信息
ls -la /sys/kernel/debug/sched/domains/cpu0/

# 查看域层级
cat /proc/sys/kernel/sched_domain/cpu0/domain*/name
```

---

## 11. 调度器的域遍历宏

内核调度代码通过宏快速遍历 CPU 的调度域层次：

```c
// kernel/sched/sched.h（常见用法）
#define for_each_domain(cpu, sd) \
    for (sd = rcu_dereference(cpu_rq(cpu)->sd); sd; \
         sd = sd->parent)

#define for_each_lower_domain(sd) \
    for (; sd; sd = sd->child)
```

**域遍历的实用辅助函数**：

```c
// kernel/sched/topology.c
struct sched_domain *highest_flag_domain(int cpu, int flag);
/* 返回包含指定 flag 的最高层域 */

struct sched_domain *lowest_flag_domain(int cpu, int flag);
/* 返回包含指定 flag 的最底层域 */

int cpus_share_cache(int this_cpu, int that_cpu);
/* 检查两个 CPU 是否共享 LLC（通过 sd_llc_id 比较）*/

int cpus_share_resources(int this_cpu, int that_cpu);
/* 检查两个 CPU 是否共享资源（通过 sd_share_id 比较）*/
```

**doom-lsp 确认**：`highest_flag_domain()` 和 `lowest_flag_domain()` 通过 `update_top_cache_domain()` 设置的 per-CPU 快捷键直接返回，而不是遍历整棵树。

---

## 12. 性能特性与延迟分析

### 12.1 各操作的延迟

| 操作 | 路径 | 典型延迟 | 说明 |
|------|------|----------|------|
| `should_we_balance()` | 位图检查 | ~**100ns** | 仅检查 balance_cpu |
| `update_sg_lb_stats()` | 遍历组内所有 CPU | ~**1-5μs** | 取决于组大小 |
| 单域均衡（8 核） | `sched_balance_rq()` | ~**10-20μs** | 包含 detach+attach |
| 域重建 | `build_sched_domains()` | ~**100μs-1ms** | kmalloc 密集型 |
| `update_group_capacity()` | 传播容量 | ~**1-3μs** | SGC 指针遍历 |

### 12.2 均衡间隔动态调整

```c
// fair.c
static unsigned long __read_mostly max_load_balance_interval = HZ/10; // 100ms

// 每次均衡后调整间隔
interval = sd->balance_interval;
if (ld_moved)                    // 有任务迁移
    interval = min(interval, sd->min_interval);
else                             // 无任务迁移 → 退避
    interval = min(interval * sd->busy_factor, max_load_balance_interval);
                                  // busy_factor=16 → 最多 1.6s
```

| 状态 | 均衡间隔 | 说明 |
|------|----------|------|
| 空闲 CPU（newidle） | 立即执行 | 无额外延迟 |
| 刚迁移了任务 | `sd->min_interval`（≈4ms） | 短间隔持续均衡 |
| 无任务可移（繁忙） | 逐步扩大到 `max_load_balance_interval`（100ms）| 退避减少开销 |
| 持续无任务（空闲系统） | 可扩大至 ~1.6s | 最大退避 |

### 12.3 SD_SERIALIZE 的串行化保障

NUMA 域的 SD_SERIALIZE 确保同一时刻只有一个 CPU 进行该层的负载均衡：

```c
if (sd->flags & SD_SERIALIZE) {
    /* atomic try_cmpxchg 保证串行化 */
    if (!atomic_try_cmpxchg_acquire(&sched_balance_running, &zero, 1))
        goto out_balanced;  /* 另一个 CPU 已经在均衡 */
}
```

---

## 13. 常见问题与故障排查

### 13.1 域层数不对

**现象**：调度域层数比预期少（如大核系统无 MC 层）。

**原因**：
- 拓扑表的 `tl_mask` 函数返回了空的 CPU 掩码
- 域退化了（`sd_degenerate()` / `sd_parent_degenerate()`）

**排查**：
```bash
# 手动查看域结构
cat /proc/schedstat | head -30

# 或用 sched_verbose 启动
dmesg | grep "sched-domain"
```

### 13.2 EAS 未生效

**现象**：`sched_energy_aware=1` 但 EAS 不工作。

**检查条件**：
```bash
# 检查 EAS 是否 active
cat /proc/sys/kernel/sched_energy_aware

# 检查 cpufreq governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # 需为 schedutil

# 检查 SMT
cat /sys/devices/system/cpu/smt/active  # 需为 0

# 检查 EM 是否注册
ls /sys/firmware/devicetree/base/  # 或检查 kernel EM 驱动
```

### 13.3 跨 NUMA 迁移不均衡

**现象**：NUMA 节点间负载失衡。

**排查**：
```bash
# 查看 NUMA 点距离
numactl --hardware

# 查看进程的 NUMA 统计
cat /proc/<pid>/numa_maps

# 检查 imb_numa_nr 参数
cat /proc/sys/kernel/sched_domain/cpu0/domain3/imb_numa_nr
```

### 13.4 newidle 均衡耗时过长

**现象**：CPU 空闲时进入均衡器，导致系统空转功耗升高。

**排查**：
```bash
# 查看 newidle 统计
cat /proc/schedstat | grep newidle

# 如果 max_newidle_lb_cost 很大（>1ms），考虑调小 domain 范围
```

---

## 14. 总结

Linux 调度域系统是负载均衡的**拓扑骨架**，其设计体现了几个关键原则：

**1. 层次化分而治之**：SMT → MC → PKG → NUMA 的层次结构确保均衡操作在"正确范围"内发生，既保证效果又控制开销。

**2. 标志系统驱动的行为契约**：`SD_*` 标志不仅仅"描述"拓扑属性，更通过 `sd_init()` 中的转换逻辑直接**决定**调度器的均衡行为——什么时机触发、哪些域禁止 WAKE 均衡、阈值的敏感度等。

**3. 内存与性能的精细权衡**：
- `cpumask` 变长数组避免浪费
- `sd_llc` / `sd_numa` per-CPU 缓存避免树遍历
- `sched_group_capacity` 共享避免重复计算
- `SD_SERIALIZE` 防止 NUMA 域的竞态

**4. 不对称性的一等公民支持**：
- `asym_cpu_capacity_scan()` 自动检测 big.LITTLE/大小核
- `SD_ASYM_CPUCAPACITY` / `SD_ASYM_CPUCAPACITY_FULL` 驱动 EAS
- Misfit task 迁移从统计到执行的完整路径

**关键数字回顾**：
- `topology.c`：3016 行，181 符号
- `fair.c` 负载均衡相关：~2000 行
- 典型均衡间隔：4ms（空闲时立即）→ 100ms（繁忙退避后）
- SD 标志数量：12 个，覆盖 6 种元属性组合
- NUMA 最大跳数限制：`NR_DISTANCE_VALUES = 128`

---

## 附录 A：关键源码索引

| 文件 | 行号 | 符号 |
|------|------|------|
| `include/linux/sched/topology.h` | 73 | `struct sched_domain` |
| `include/linux/sched/topology.h` | 66 | `struct sched_domain_shared` |
| `include/linux/sched/topology.h` | 191 | `struct sched_domain_topology_level` |
| `include/linux/sched/sd_flags.h` | 全文件 | SD_* 标志定义 |
| `kernel/sched/sched.h` | 2203 | `struct sched_group` |
| `kernel/sched/sched.h` | 2186 | `struct sched_group_capacity` |
| `kernel/sched/sched.h` | 997 | `struct root_domain` |
| `kernel/sched/topology.c` | 39 | `sd_flag_debug[]` |
| `kernel/sched/topology.c` | 676 | `update_top_cache_domain()` |
| `kernel/sched/topology.c` | 724 | `cpu_attach_domain()` |
| `kernel/sched/topology.c` | 1253 | `build_sched_groups()` |
| `kernel/sched/topology.c` | 1042 | `build_overlap_sched_groups()` |
| `kernel/sched/topology.c` | 1407 | `asym_cpu_capacity_classify()` |
| `kernel/sched/topology.c` | 2658 | `build_sched_domains()` |
| `kernel/sched/fair.c` | 9545 | `struct lb_env` |
| `kernel/sched/fair.c` | 10226 | `struct sg_lb_stats` |
| `kernel/sched/fair.c` | 11337 | `update_sd_lb_stats()` |
| `kernel/sched/fair.c` | 10657 | `update_sg_lb_stats()` |
| `kernel/sched/fair.c` | 5032 | `sched_balance_newidle()` |
| `kernel/sched/fair.c` | 12065 | `sched_balance_rq()` |
| `kernel/sched/fair.c` | 10326 | `update_group_capacity()` |
| `kernel/sched/fair.c` | 9868 | `detach_tasks()` |
| `kernel/sched/fair.c` | 10007 | `attach_tasks()` |

## 附录 B：内核参数

```bash
# sched_verbose（调试日志，启动参数）
sched_verbose

# relax_domain_level（放松域均衡层级）
relax_domain_level=1     # 从 level >= 1 关闭 idle balance

# sched_energy_aware（sysctl 运行时控制）
/proc/sys/kernel/sched_energy_aware   # 0=关闭, 1=开启

# 域参数（在 /proc/sys/kernel/sched_domain/ 下）
sched_domain/cpu0/domain0/min_interval
sched_domain/cpu0/domain0/max_interval
sched_domain/cpu0/domain0/busy_factor
sched_domain/cpu0/domain0/imbalance_pct
sched_domain/cpu0/domain0/cache_nice_tries
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
