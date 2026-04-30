# Linux Kernel Scheduler Domains 与 Load Balancing 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/topology.c` + `kernel/sched/fair.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 Scheduler Domains？

**Scheduler Domains** 是 Linux 多核调度器的**层次化负载均衡**机制，按 CPU 亲和性分层（同一核心→同簇→同节点→跨节点），在每层独立进行负载均衡。

---

## 1. sched_domain 层次结构

```c
// include/linux/sched/sd_flags.h — sched_domain
struct sched_domain {
    /* 层次结构 */
    struct sched_domain *parent;    // 父域（更大范围）
    struct sched_domain *child;   // 子域（更小范围）

    /* 覆盖的 CPU 集合 */
    struct cpumask __rcu *span;  // 此域覆盖的 CPU

    /* 负载均衡组 */
    struct sched_group *groups;    // 此域的调度组链表

    /* 平衡间隔 */
    unsigned long       interval;    // 平衡间隔（jiffies）
    unsigned long       last_balance;
    unsigned long       balance_interval;

    /* 标志 */
    int                 level;        // 域层级（SD_INIT）
    enum sched_domain_level {
        SD_LV_NONE = 0,
        SD_LV_SIBLING,      // 兄弟核
        SD_LV_MC,           // 核心内（包含 LLC）
        SD_LV_CPU,          // 包（同一 socket）
        SD_LV_NUMA,        // NUMA
        SD_LV_ALLNODES,    // 所有节点
        SD_LV_SYSTEM,      // 系统级
    };

    /* 平衡函数 */
    int (*balance)(struct rq *this_rq, struct rq_cpu *cpu);
    int (*负荷阈值);
};

// sched_group — 调度组（可一起调度的 CPU 集合）
struct sched_group {
    struct sched_group *next;      // 组链表
    struct sched_domain *sd;      // 所属域
    unsigned long       cpu_mask; // 组内 CPU 位掩码
    unsigned long       capacity;  // 组容量
    unsigned long       capacity_orig;
    unsigned int        idle_cpus;
};
```

---

## 2. 层次图

```
系统调度域（SD_LV_SYSTEM）：
  span = all CPUs
  │
  ├─ NUMA 域（SD_LV_NUMA）：
  │    span = 同一 NUMA 节点内的所有 CPU
  │    │
  │    └─ CPU 包域（SD_LV_CPU）：
  │         span = 同一 socket/PKG 内的所有 CPU
  │         │
  │         └─ MC/核心域（SD_LV_MC）：
  │              span = 同一物理核心内的逻辑 CPU（SMT）
  │              │
  │              └─ 兄弟核（SD_LV_SIBLING）：
  │                   span = SMT 线程对（如 CPU0+CPU4）
```

---

## 3. load_balance — 核心均衡

```c
// kernel/sched/fair.c — load_balance
static int load_balance(int this_rq, int this_cpu, struct rq_flags *rf)
{
    // 1. 找到最繁忙的调度组
    struct sched_group *busiest = find_busiest_group(this_rq, this_cpu);

    // 2. 如果 busiest->group_weight <= 1，跳过
    if (!busiest || busiest->group_weight <= 1)
        return 0;

    // 3. 获取 busiest 的 runqueue
    struct rq *busiest_rq = busiest->rq;

    // 4. 从 busiest_rq 迁移任务到 this_rq
    do {
        unsigned long imm = 0, tot = 0;

        // 计算需要迁移的任务数
        // nr_migrate = (busiest_rq->cfs.h_nr_running - this_rq->cfs.h_nr_running) / 2
        nr_migrate = (busiest_rq->cfs.h_nr_running -
                      this_rq->cfs.h_nr_running) / 2;

        // 5. 锁定 busiest_rq
        double_lock_balance(this_rq, busiest_rq);

        // 6. 迁移任务
        move_tasks(this_rq, this_cpu, busiest_rq, this_cpu,
                   imm, tot, &pinned);

        // 7. 更新统计
        update_blocked_averages(this_rq);

    } while (busiest_rq->cfs.h_nr_running > this_rq->cfs.h_nr_running + 8);

    return 1;
}
```

---

## 4. find_busiest_group — 找最繁忙组

```c
// kernel/sched/fair.c — find_busiest_group
static struct sched_group *find_busiest_group(struct rq *this_rq, int this_cpu)
{
    // 1. 遍历调度域层级
    for_each_domain(this_cpu, sd) {
        // 2. 计算每个组的负载
        for_each_sg(sd->groups, sg, i) {
            load = sg->group_weight;  // 或乘以 avg_load

            if (load > busiest_load) {
                busiest = sg;
                busiest_load = load;
            }
        }

        // 3. 如果 busiest 负载不超过阈值，停止向更高层遍历
        if (busiest_load < sd->imbalance_pct * sg->capacity / 100)
            break;
    }

    return busiest;
}
```

---

## 5. nohz_idle_balance — 非交互核心

```c
// 当 CPU 进入 idle（nohz）时：
// 1. nohz.next_balance 记录下次需要平衡的时间
// 2. 离开 idle 时调用 nohz_idle_balance()
// 3. 一次性处理所有之前积压的负载均衡
```

---

## 6. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| 分层均衡 | 同 SMT 核优先均衡，减少跨核延迟 |
| SD_LV_MC → NUMA 层级 | 优先在低延迟层级均衡 |
| busiest_load / capacity 比较 | 考虑 CPU 容量（异构系统）|
| imbalance_pct 阈值 | 避免过度均衡 |
| double_lock_balance | 迁移时同时锁住两个 rq |

---

## 7. 参考

| 文件 | 内容 |
|------|------|
| `kernel/sched/topology.c` | `sched_domain`、`sched_group`、`build_sched_domains` |
| `kernel/sched/fair.c` | `load_balance`、`find_busiest_group`、`move_tasks` |
| `include/linux/sched/sd_flags.h` | `SD_LV_*` 层级定义 |
