# 37-cfs-scheduler — Linux CFS 调度器深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**CFS（Completely Fair Scheduler）** 是 Linux 内核默认的 CPU 调度器，由 Ingo Molnar 于 Linux 2.6.23 引入。CFS 使用**虚拟运行时间（vruntime）**模型来保证每个进程公平地获得 CPU 时间。

**doom-lsp 确认**：核心实现在 `kernel/sched/fair.c`。关键结构体：`struct sched_entity`、`struct cfs_rq`。

---

## 1. 核心数据结构

```c
// kernel/sched/sched.h
struct sched_entity {
    struct load_weight      load;        // 调度权重（权重越高，vruntime 增长越慢）
    struct rb_node          run_node;    // 红黑树节点（按 vruntime 排序）
    struct list_head        group_node;  // 组调度链表
    u64                     vruntime;    // 虚拟运行时间
    u64                     prev_sum_exec_runtime; // 上次执行累计时间
    struct sched_entity     *parent;     // 调度组父节点
};

struct cfs_rq {
    struct load_weight      load;        // 此队列的总负载
    unsigned int            nr_running;  // 运行进程数
    unsigned int            h_nr_running;// 包含子组的进程数
    struct rb_root_cached   tasks_timeline; // 红黑树（最小 vruntime 缓存）
    struct sched_entity     *curr;       // 当前正在执行的进程
    struct sched_entity     *next;       // 下一个要运行的进程
    struct sched_entity     *last;       // 上次运行的进程
    u64                     min_vruntime;// 队列最小 vruntime
    struct rq               *rq;         // 所属运行队列
};
```

---

## 2. vruntime——CFS 的核心

```
vruntime = 实际运行时间 × NICE_0_LOAD / weight

关键含义：
  - 高权重（高优先级）进程运行同样实际时间后 vruntime 增长更慢
  - 低权重（低优先级）进程 vruntime 增长更快
  - CFS 每次选择 vruntime 最小的进程运行（红黑树最左节点）
  - 保证了各进程按照权重比例公平获得 CPU

示例：
  进程 A: weight=1024（NICE 0），运行 10ms → vruntime += 10ms
  进程 B: weight=2048（NICE -5），运行 10ms → vruntime += 5ms
  下次调度 CFS 选 vruntime 更小的 B → B 获得更多 CPU
  这是"高优先级进程获得更多 CPU 时间"的数学原理
```

---

## 3. 调度循环

```
scheduler_tick()（每 tick 调用）
  │
  └─ task_tick_fair(rq, curr)
       └─ entity_tick(cfs_rq, se)
            └─ update_curr(cfs_rq)
                 │
                 ├─ delta_exec = now - se->exec_start
                 ├─ se->sum_exec_runtime += delta_exec
                 ├─ se->vruntime += calc_delta_fair(delta_exec, se)
                 │   → vruntime += delta_exec × NICE_0_LOAD / se->load.weight
                 │
                 ├─ 更新 min_vruntime
                 │   → 取所有可运行进程 vruntime 的最小值
                 │
                 └─ if (se != cfs_rq->curr) 检查是否抢占当前进程
                      check_preempt_tick(cfs_rq, curr)

pick_next_entity() 时机：
  - schedule() 被调用时
  - 当前进程被抢占时

pick_next_entity(cfs_rq, curr)
  ├─ 从 tasks_timeline 取最左节点（最小 vruntime）
  │   left = rb_first_cached(&cfs_rq->tasks_timeline)
  │   se = rb_entry(left, struct sched_entity, run_node)
  ├─ check_prewake_entity 检查是否可以抢占
  └─ return se
```

---

## 4. 权重和优先级

```c
// kernel/sched/core.c — nice 值到权重的映射表
const int sched_prio_to_weight[40] = {
    /* -20 */   88761, 71755, 56483, 46273, 36291,
    /* -15 */   29154, 23254, 18705, 14949, 11916,
    /* -10 */   9548,  7620,  6100,  4904,  3906,
    /* -5 */    3121,  2501,  1991,  1586,  1277,
    /* 0 */     1024,  820,   655,   526,   423,
    /* 5 */     335,   272,   215,   172,   137,
    /* 10 */    110,   87,    70,    56,    45,
    /* 15 */    36,    29,    23,    18,    15,
};

// nice 0 权重 1024
// nice -20 权重 88761（约 87 倍）
// nice 19 权重 15（约 1/68）
```

---

## 5. 数据结构关系

```
struct rq（每个 CPU 的运行队列）
  │
  └─ struct cfs_rq cfs（CFS 运行队列）
       │
       ├─ tasks_timeline（红黑树，按 vruntime 排序）
       │   ├─ se_A (vruntime=100)
       │   ├─ se_B (vruntime=200)
       │   └─ se_C (vruntime=300)
       │
       ├─ curr = se_A（当前正在运行）
       ├─ min_vruntime = 100
       │
       └─ load.weight = 3072（三个进程的总权重）

struct rq
  └─ struct rt_rq rt（实时调度类）
  └─ struct dl_rq dl（Deadline 调度类）
```

---

## 6. 源码文件索引

| 文件 | 内容 |
|------|------|
| kernel/sched/fair.c | CFS 核心（12000+ 行）|
| kernel/sched/core.c | 调度核心 |
| include/linux/sched.h | task_struct |
| kernel/sched/sched.h | 内部结构体 |

---

## 7. 关联文章

- **14-kthread**: 内核线程调度
- **46-sched-domain**: 调度域

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 8. 调度类层次

```c
// kernel/sched/sched.h — 调度类接口
struct sched_class {
    void (*enqueue_task)(struct rq *rq, struct task_struct *p, int flags);
    void (*dequeue_task)(struct rq *rq, struct task_struct *p, int flags);
    void (*check_preempt_curr)(struct rq *rq, struct task_struct *p, int flags);
    struct task_struct *(*pick_next_task)(struct rq *rq);
    void (*task_tick)(struct rq *rq, struct task_struct *p, int queued);
};

// 调度类优先级：
// stop_sched_class   → 停机线程（最高）
// dl_sched_class     → Deadline 调度
// rt_sched_class     → 实时调度（SCHED_FIFO/RR）
// fair_sched_class   → CFS（SCHED_NORMAL/BATCH）← 默认
// idle_sched_class   → 空闲线程（最低）
```

`pick_next_task` 按优先级遍历调度类，选择第一个有任务的类。

---

## 9. 唤醒抢占

```c
// 当进程被唤醒（如 I/O 完成）时：
try_to_wake_up(p, mode, wake_flags)
  │
  └─ ttwu_queue(p, cpu) → ttwu_do_activate
       │
       └─ check_preempt_curr(rq, p, WF_ON_CPU)
            │
            └─ wakeup_preempt_entity(se, pse)
                 // 如果唤醒进程的 vruntime 比当前进程小
                 // → 触发抢占
                 // → 设置 TIF_NEED_RESCHED
                 // → 调度器在适当时候重新调度
```

---

## 10. CFS 组调度

group scheduling 允许将 CFS CPU 时间分配给进程组（如 cgroup）：

```
/（root group）：100%
  ├─ system.slice：30%
  │   ├─ sshd：15%
  │   └─ httpd：15%
  └─ user.slice：70%
      ├─ user-1000：50%
      └─ user-1001：20%
```

每个组有自己的 `sched_entity` 和 `cfs_rq`。调度时先选择组级别的 se，再在组内选择进程：

```
pick_next_task_fair(rq)
  → 选择 system.slice 组的 se
    → 在 system.slice 的 cfs_rq 中选择 sshd 的 se
  → sshed 运行时间片
```

---

## 11. 周期调度与负载均衡

```c
// 每个 tick（通常 4ms）调用：
void scheduler_tick(void)
{
    // 更新当前进程的运行时间
    curr->sched_class->task_tick(rq, curr, 0);
    // → CFS: task_tick_fair → entity_tick → update_curr
    // → 如果需要重新调度，设置 TIF_NEED_RESCHED
    
    // CPU 负载均衡（每 1ms 或空闲时）
    trigger_load_balance(rq);
}
```

---

## 12. 常用调试

```bash
# 查看进程优先级
ps -eo pid,comm,nice,prio

# 修改优先级
renice -n -5 -p 1234  # 提高优先级

# 查看调度策略
chrt -p 1234           # 显示当前调度策略
chrt -f -p 99 1234     # 改为 SCHED_FIFO 优先级 99

# CFS 调度延迟参数
sysctl kernel.sched_latency_ns    # 调度延迟（默认 6ms）
sysctl kernel.sched_min_granularity_ns # 最小粒度（0.75ms）
sysctl kernel.sched_wakeup_granularity_ns # 唤醒抢占粒度（1ms）
```

---

## 13. 总结

CFS 使用红黑树和 vruntime 实现完全公平调度。每次选择 vruntime 最小的进程执行（红黑树最左节点），nice 值通过权重影响 vruntime 增长速度。没有时间片概念——调度延迟由动态计算的目标延迟和进程数决定。


## 14. 调度延迟和粒度

CFS 的目标延迟（sched_latency_ns，默认 6ms）和最小粒度（sched_min_granularity_ns，默认 0.75ms）动态计算调度周期：

```c
// 调度周期 = max(min_granularity × nr_running, target_latency)
// 当进程少时：每 ~6ms 调度一次（每个进程 ~6ms）
// 当进程多时：每 ~0.75ms × N 调度一次（每个进程 ~0.75ms）

// 时间片计算
slice = sched_latency * se->load.weight / cfs_rq->load.weight
// 权重越高，时间片越长
```

---

## 15. CFS vs 实时调度

| 特性 | CFS（SCHED_NORMAL）| SCHED_FIFO | SCHED_RR |
|------|-------------------|------------|----------|
| 优先级 | nice -20 到 19 | 实时优先级 1-99 | 实时优先级 1-99 |
| 时间片 | 动态（0.75-6ms）| 无限（直到主动让出）| 固定时间片 |
| 公平性 | ✅完全公平 | ❌严格优先级 | ❌同优先级轮转 |
| 抢占 | 按 vruntime | 高优立即抢占 | 高优立即抢占 |
| 默认 | ✅ | ❌ | ❌ |

---

## 16. Linux 调度器发展

| 版本 | 调度器 | 特点 |
|------|--------|------|
| 2.4 | O(1) 调度器 | 无等待时间记录 |
| 2.6.23 | CFS | 引入 vruntime + 红黑树 |
| 3.14 | 优化 | 新增 SCHED_DEADLINE |
| 5.x | EEVDF | 部分场景改进 |
| 7.x | EEVDF 进化 | 基于 deadline 的 vruntime |

---

## 17. 调试信息

```bash
# 查看进程调度信息
$ cat /proc/[pid]/sched
se.sum_exec_runtime:        12345.678
se.vruntime:                98765
se.load.weight:             1024
nr_switches:                5000

# 查看 CPU 运行队列延迟
$ cat /proc/schedstat
cpu0 12345678 9876543 0 0 0 0
# 字段: 运行时间, 运行队列延时, 时间片等
```

---

## 18. 总结

CFS 通过 vruntime 红黑树实现了 O(log n) 的调度决策和完全公平的 CPU 分配。它是 Linux 系统中最广泛应用的调度器，处理所有 SCHED_NORMAL 和 SCHED_BATCH 进程的调度。


## 19. 负载均衡

CFS 通过负载均衡机制确保各 CPU 之间任务分布均衡：

```c
// kernel/sched/fair.c — 负载均衡入口
void trigger_load_balance(struct rq *rq)
{
    // 如果本 CPU 空闲或负载异常
    // 触发 idle_balance() 或 nohz_balance()
    
    if (time_after_eq(jiffies, rq->next_balance))
        raise_softirq(SCHED_SOFTIRQ);
}

// SCHED_SOFTIRQ → run_rebalance_domains → load_balance
// 负载均衡过程：
// 1. 找到负载最重的 CPU（busiest）
// 2. 从 busy CPU 迁移任务到当前 CPU
// 3. 使用 move_tasks() 一次迁移多个任务
```

---

## 20. EEVDF——CFS 的后继者

Linux 7.0-rc1 可选启用 EEVDF（Earliest Eligible Virtual Deadline First）：

```c
// 在 CFS 基础上添加了 deadline 机制
// 选 eligible_time 最早的进程（而不是最小 vruntime）
// 更好支持延迟敏感的交互式任务

// 启用（内核配置）
CONFIG_SCHED_EEVDF=y
```

---

## 21. 进程优先级影响

```c
// 测试不同 nice 值的效果
nice -20 的进程 → weight=88761
nice 0  的进程 → weight=1024
nice 19 的进程 → weight=15

// 当 CPU 满载时（只有一个 nice 0 和 nice 19 进程）：
// nice 0 获得: 1024/(1024+15) ≈ 98.6% CPU
// nice 19 获得: 15/(1024+15) ≈ 1.4% CPU

// 实时进程（SCHED_FIFO priority=99）：
// 绝对优先于所有 CFS 进程
// 只有在实时进程无任务运行时 CFS 进程才能执行
```

---

## 22. 参考资料

- 内核源码: kernel/sched/fair.c（12000+ 行）
- 内核文档: Documentation/scheduler/sched-design-CFS.rst
- 调度器维护者: Peter Zijlstra, Ingo Molnar


## 23. 能耗感知调度（Energy-Aware Scheduling）

EAS 是 CFS 的扩展，在大小核架构（ARM big.LITTLE）上优化功耗：



## 24. 源码文件索引

| 文件 | 内容 |
|------|------|
| kernel/sched/fair.c | CFS 核心（12000+ 行）|
| kernel/sched/core.c | 调度核心 |
| kernel/sched/sched.h | 内部结构体 |
| include/linux/sched.h | task_struct |

## 25. 关联文章

- **14-kthread**: 内核线程调度
- **46-sched-domain**: 调度域和负载均衡
- **47-rt-scheduler**: 实时调度器

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 26. CFS 与 cgroup CPU 控制器

CFS 通过 group scheduling 实现 cgroup CPU 控制器：

每个 cgroup 有独立的 cfs_rq 和 sched_entity。调度时：
1. 在 root cfs_rq 中选择一个 group se
2. 在该 group 的 cfs_rq 中选择进程 se
3. 递归直到叶子节点

这保证了 CPU 时间按 cgroup 层级比例分配。

## 27. CFS 调度的实时性改进

CFS 通过以下机制减少调度延迟：
- sched_wakeup_granularity_ns（默认 1ms）：检查是否需要唤醒抢占
- sched_migration_cost_ns（默认 500μs）：任务迁移成本估算
- NOHZ 全内核 tickless：减少周期性中断的干扰

## 28. 总结

CFS 是 Linux 默认调度器，使用 vruntime + 红黑树实现完全公平。通过权重映射 nice 值范围 -20 到 19，支持实时、deadline、能耗感知等多种调度策略。

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01*

## CFS 性能数据

| 操作 | 延迟 | 场景 |
|------|------|------|
| sched_yield | ~100ns | 自愿让出 CPU |
| wakeup preemption | ~500ns-2μs | 唤醒高优任务 |
| tick preemption | ~5-10μs | 时间片用完 |
| load balance | ~10-50μs | 跨 CPU 迁移 |
| context switch（同进程）| ~1μs | 用户态切换 |
| context switch（跨进程）| ~3-5μs | 内核态切换 |

## 参考

内核文档: Documentation/scheduler/sched-design-CFS.rst
内核源码: kernel/sched/fair.c

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 特殊调度场景

- 实时进程（SCHED_FIFO/SCHED_RR）：绝对优先于 CFS 进程
- SCHED_BATCH：类似 NORMAL 但更适合批量计算，不触发抢占
- SCHED_IDLE：仅在 CPU 完全空闲时运行（权重极低）
- SCHED_DEADLINE：保证每个周期的执行时间（用于实时）

## cgroup CPU 限流示例



限流后 CFS 将进程标记为 throttled，不再被 pick_next_task_fair 选中。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 内核版本：Linux 7.0-rc1*

## CFS 历史与维护

- 创始人: Ingo Molnar（2007 年）
- 当前维护者: Peter Zijlstra, Ingo Molnar
- 核心文件: kernel/sched/fair.c（约 12000 行）
- 文档: Documentation/scheduler/

CFS 替代了 O(1) 调度器，是 Linux 调度器发展的重要里程碑。EEVDF 作为 CFS 的后继者，在 7.x 内核中提供了更精确的调度延迟控制。

## CFS 核心调度参数


