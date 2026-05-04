# Linux sched_ext（可扩展调度器）深度分析

## 概述

sched_ext（`SCHED_EXT`）是 Linux 6.12 引入的新调度器类，它允许通过 BPF 程序加载用户编写的调度策略，而无需修改内核代码或重启系统。由 Meta（Tejun Heo, David Vernet）主导开发，旨在解决 Linux 调度器的一个长期痛点：调度策略的改进需要修改内核并等待合入主线——这对于需要实验新调度算法（如 EEVD 的变体、特定工作负载优化）的研究者和工程师来说门槛极高。

与传统的 CFS→EEVDF 演进的渐进式不同，sched_ext 是一等公民：它注册为内核调度类之一（优先级高于 fair/EEVDF，低于 deadline/RT），通过一组 BPF 可编程的操作回调（`struct sched_ext_ops`）暴露调度决策点。

## 架构

### 调度类优先级

```
stop_sched_class      (最高优先级)
dl_sched_class        (SCHED_DEADLINE)
rt_sched_class        (SCHED_FIFO/RR)
ext_sched_class       (SCHED_EXT — 可扩展调度器)
fair_sched_class      (SCHED_NORMAL/BATCH — EEVDF)
idle_sched_class      (最低优先级)
```

`sched_ext` 的优先级在实时（RT）之上、公平（CFS/EEVDF）之下，这意味着：
- RT 任务优先于 sched_ext 任务（保证实时响应）
- sched_ext 任务优先于 CFS/EEVDF 任务（保证自定义调度不受默认调度器的干扰）
- sched_ext 支持多个子调度器实例，通过 cgroup 绑定

### 核心概念

sched_ext 引入三个核心抽象：

1. **调度器（struct scx_sched）**：一个 BPF 调度程序实例，包含 `struct sched_ext_ops` 回调表和调度状态
2. **调度队列（DSQ — Dispatch Queue）**：FIFO 或优先级队列，任务可以由 BPF 调度器分配到任意 DSQ
3. **任务状态**：每个 SCX 任务有 `struct sched_ext_entity` 嵌入 `task_struct`，跟踪 slice 耗尽、排队状态等

## 核心数据结构

### struct sched_ext_ops — BPF 调度器回调

（`kernel/sched/ext_internal.h` L292）

```c
struct sched_ext_ops {
    /* CPU 选择：任务唤醒时选择目标 CPU */
    s32 (*select_cpu)(struct task_struct *p, s32 prev_cpu, u64 wake_flags);

    /* 入队：将任务放入 BPF 调度器 */
    void (*enqueue)(struct task_struct *p, u64 enq_flags);

    /* 出队：从 BPF 调度器移除任务 */
    void (*dequeue)(struct task_struct *p, u64 deq_flags);

    /* 调度：CPU 本地队列为空时，从外部 DSQ 拉取任务 */
    void (*dispatch)(s32 cpu, struct task_struct *prev);

    /* 周期性 tick */
    void (*tick)(struct task_struct *p);

    /* 任务状态转换回调 */
    void (*runnable)(struct task_struct *p, u64 enq_flags);
    void (*running)(struct task_struct *p);
    void (*stopping)(struct task_struct *p, bool runnable);
    void (*quiescent)(struct task_struct *p, u64 deq_flags);

    /* 任务属性更新 */
    void (*set_weight)(struct task_struct *p, u32 weight);
    void (*set_cpumask)(struct task_struct *p, const struct cpumask *cpumask);
    void (*update_idle)(s32 cpu, bool idle);

    /* cgroup 相关 */
    void (*cgroup_set_weight)(struct cgroup *cgrp, u32 weight);
    void (*cgroup_move)(struct task_struct *p, struct cgroup *from, struct cgroup *to);

    /* 调度器初始化和退出 */
    s32 (*init)(void);
    void (*exit)(struct scx_exit_info *ei);

    /* 调度器标志 */
    u64 flags;

    /* 调度器名称 */
    char name[SCX_OPS_NAME_LEN];
};
```

每个回调对应的调度决策点：

```
  select_cpu() ← 唤醒路径：选择目标 CPU
      │
      ├─ 如果任务被直接入队到 DSQ（scx_bpf_dsq_insert）→ 跳过 enqueue
      │
      └─ enqueue() ← 任务入队到 BPF 调度器
           │
     dispatch() ← CPU 就绪，从 BPF 调度器或用户 DSQ 拉取任务
           │
     running() ← 任务开始在 CPU 上运行
           │
     stopping() ← 任务停止运行
           │
     quiescent() ← 任务不再可运行
```

### struct sched_ext_entity — 调度实体

（`include/linux/sched.h`，嵌入 task_struct 中）

```c
struct sched_ext_entity {
    /* 调度状态标志（SCX_TASK_*） */
    u64                         flags;

    /* 剩余时间片（ns） */
    u64                         slice;

    /* 所属 DSQ（本地或全局） */
    struct scx_dispatch_q       *dsq;

    /* BPF 调度器私有数据 */
    struct bpf_local_storage    *storage;

    /* 调度链中的节点 */
    struct list_head            dsq_node;
    struct list_head            tasks_node;

    /* 持有该实体的调度器 */
    struct scx_sched __rcu      *sched;

    /* 持有该实体的 cgroup */
    struct cgroup               *cgrp;

    /* kfunc 辅助结构 */
    struct scx_dsq_list_node    dsq_list;   // DSQ 链表
    struct scx_dsq_list_node    dsq_priq;   // 优先级队列
    ...
};
```

关键标志（`SCX_TASK_*`）：

| 标志 | 含义 |
|------|------|
| `SCX_TASK_QUEUED` | 任务在 BPF 调度器上排队 |
| `SCX_TASK_RESET_RUNTIME` | 重置运行时统计 |
| `SCX_TASK_WATCHDOG_RESET` | 任务看门狗重置 |

### DSQ 系统

sched_ext 的核心抽象是调度队列（Dispatch Queue）。三种 DSQ：

```
本地 DSQ (SCX_DSQ_LOCAL)
  每个 CPU 一个，存放调度器为该 CPU 分配的任务
  如果没有本地队列，触发 dispatch() 回调

全局 DSQ (SCX_DSQ_GLOBAL)
  系统级 FIFO 队列
  任何 CPU 的 dispatch() 都可以从中拉取

用户 DSQ (SCX_DSQ_LOCAL_ON | SCX_DSQ_ID)
  BPF 调度器可以创建任意数量的 DSQ
  每个 DSQ 可以是 FIFO 或优先级模式
  通过 scx_bpf_dsq_insert() 将任务放入
  通过 scx_bpf_dsq_move_to_local() 提取到本地
```

```
                        BPF 调度器
                      ┌──────────────┐
                      │  enqueue()   │──→ 用户 DSQ 1 (FIFO)
                      │  dispatch()  │──→ 用户 DSQ 2 (prio)
                      └──────────────┘
                              │
                              │ scx_bpf_dsq_move_to_local()
                              ↓
                       ┌──────────────┐
                       │  本地 DSQ     │ ← CPU n
                       │  (FIFO)       │
                       └──────────────┘
                              │
                              ↓
                        CPU 执行任务
```

## 数据流：完整调度周期

### 1. 唤醒入队路径

```
try_to_wake_up(p)
  └─ select_task_rq(p, wake_flags)
       └─ select_task_rq_scx(p, wake_flags)     // kernel/sched/ext.c
            └─ ops.select_cpu(p, prev_cpu, wake_flags)
                 └─ BPF 调度器选择目标 CPU
                     ├─ 如果 BPF 选择 idle CPU → kick_cpu
                     └─ 可在此通过 scx_bpf_dsq_insert 直接入队

  └─ enqueue_task_scx(p, enq_flags)             // CFS 的 enqueue_task_fair 对应
       └─ if (p 未通过 select_cpu 直接入队 DSQ):
            ops.enqueue(p, enq_flags)
            └─ BPF 调度器选择入队策略
                 ├─ 放入某个 DSQ
                 └─ 或记录在 BPF 内部数据结构中
```

### 2. 调度选择路径

```
__schedule()
  └─ pick_next_task()
       └─ pick_next_task_scx(rq, prev, rf)      // kernel/sched/ext.c
            └─ scx_next_task(rq, rf)
                 ├─ 1. 检查本地 DSQ
                 │     local = rq->scx.local_dsq
                 │     if (local 非空) → 从 local DSQ 取下一个任务
                 │
                 ├─ 2. 本地 DSQ 空 → 调用 dispatch()
                 │     ops.dispatch(cpu, prev)
                 │     └─ BPF 调度器从用户 DSQ 拉取任务到本地 DSQ
                 │         ├─ scx_bpf_dsq_move_to_local()
                 │         └─ scx_bpf_dsq_insert() 新任务
                 │
                 └─ 3. 再次检查本地 DSQ
                        if (本地 DSQ 仍空) → skip（没有可运行的任务）

       └─ 选中的任务 → ops.running(p)
```

### 3. Tick 处理路径

```
entity_tick_scx(rq, curr, queued)
  └─ ops.tick(curr)             // BPF 调度器的 tick 回调
       └─ BPF 可以设置 curr->scx.slice = 0
           → 触发 dispatch 重新评估
```

### 4. 任务停止路径

```
put_prev_task_scx(prev, next)
  └─ ops.stopping(prev, prev->scx.flags & SCX_TASK_QUEUED)
       // BPF 获得任务停止前的状态通知

dequeue_task_scx(p, deq_flags)
  └─ ops.dequeue(p, deq_flags)  // BPF 从调度器移除任务
  └─ scx_rq_deactivate(p)
  └─ ops.quiescent(p, deq_flags)
```

## scx_sched — 调度器实例管理

每个 BPF 调度程序在内核中对应一个 `struct scx_sched` 实例：

```c
// kernel/sched/ext.c — 核心调度器结构
struct scx_sched {
    struct sched_ext_ops    ops;            // BPF 回调表
    struct list_head        tasks;          // 该调度器的所有任务
    struct cgroup_subsys_state *sub_cgroup_id; // 绑定 cgroup
    struct list_head        sibling;        // 兄弟调度器链表
    struct list_head        children;       // 子调度器链表
    struct rhlist_head      hash_node;      // cgroup 哈希查找节点
    ...
};
```

sched_ext 支持**多个调度器并发运行**（通过 cgroup 绑定）。不同 cgroup 下的任务可以运行不同的 BPF 调度策略：

```
              scx_root
              /      \
        scx_sched_A  scx_sched_B
        (scx_ops_A)  (scx_ops_B)
            │             │
        cgroup A       cgroup B
        task 1,2       task 3,4
```

## 关键 API（kfunc）

sched_ext 通过 BPF kfunc 暴露以下核心操作：

| kfunc | 功能 | 调用上下文 |
|-------|------|-----------|
| `scx_bpf_dsq_insert(p, dsq_id, slice, enq_flags)` | 将任务插入 DSQ | select_cpu, enqueue, dispatch |
| `scx_bpf_dsq_move_to_local(iter)` | 将 DSQ 中的任务移至本地队列 | dispatch |
| `scx_bpf_dsq_move_vtime(p, dsq_id, slice, vtime, enq_flags)` | 带虚拟时间排序的插入 | enqueue, dispatch |
| `scx_bpf_dispatch_from_dsq(iter, dsq_id, slice)` | 从 DSQ 批量迁移 | dispatch |
| `scx_bpf_kick_cpu(cpu, flags)` | 唤醒目标 CPU 触发调度 | 任何 kfunc 上下文 |
| `scx_bpf_task_running(p)` | 检查任务是否运行 | sleepable 上下文 |
| `scx_bpf_cpuperf_cap(cpu)` | 获取 CPU 性能上限 | dispatch, tick |
| `scx_bpf_pick_idle_cpu(p, prev_cpu, flags)` | 选择空闲 CPU | select_cpu |
| `scx_bpf_consume(iter, dsq_id)` | 消费 DSQ 中的任务 | dispatch |

## BPF 调度器示例

一个最小 sched_ext 调度器（简化）：

```c
// SPDX-License-Identifier: GPL-2.0
// minimal.bpf.c — simplest possible sched_ext scheduler
#include <scx/common.bpf.h>

// 任务唤醒时选择 CPU
s32 BPF_STRUCT_OPS(minimal_select_cpu, struct task_struct *p,
                   s32 prev_cpu, u64 wake_flags)
{
    s32 cpu = scx_bpf_pick_idle_cpu(p, prev_cpu, 0);
    if (cpu >= 0) {
        // 直接放入选定 CPU 的本地 DSQ
        scx_bpf_dsq_insert(p, SCX_DSQ_LOCAL, SCX_SLICE_DFL, 0);
        return cpu;
    }
    return prev_cpu;
}

// 入队：放入全局 DSQ
void BPF_STRUCT_OPS(minimal_enqueue, struct task_struct *p, u64 enq_flags)
{
    scx_bpf_dsq_insert(p, SCX_DSQ_GLOBAL, SCX_SLICE_DFL, enq_flags);
}

// 调度：从全局 DSQ 取出到本地
void BPF_STRUCT_OPS(minimal_dispatch, s32 cpu, struct task_struct *prev)
{
    scx_bpf_dsq_move_to_local(SCX_DSQ_GLOBAL);
}

SCX_OPS_DEFINE(minimal_ops,
    .select_cpu     = (void *)minimal_select_cpu,
    .enqueue        = (void *)minimal_enqueue,
    .dispatch       = (void *)minimal_dispatch,
    .name           = "minimal",
    .flags          = SCX_OPS_KEEP_BUILTIN_IDLE,
);
```

这个调度器的行为：
1. 唤醒时优先选择空闲 CPU
2. 入队时放入全局 FIFO DSQ
3. 调度时从全局 DSQ 拉取任务到本地
4. 相当于"全局 FIFO + idle 感知"

## 关键设计决策

### 1. 为什么用 BPF 而不是内核模块

BPF 提供了**安全沙箱**：BPF 验证器（verifier）保证调度程序不会：
- 访问非法内存
- 执行无限循环（必须有界）
- 引发内核崩溃

对比内核模块：
| 特性 | BPF 调度器 | 内核模块调度器 |
|------|-----------|---------------|
| 安全边界 | 验证器保证 | 无（可能崩溃内核） |
| 加载方式 | bpftool + 用户空间程序 | insmod（root） |
| 热更新 | 可调度器切换（线程迁移） | 需要卸载/重载 |
| 性能 | ~5-10% 开销（回调间接调用） | 接近原生 |
| 调试 | BPF 跟踪 + printk 限制 | 完整内核调试 |

### 2. DSQ 抽象 vs 直接红黑树

为什么 sched_ext 不导出一个 "公平队列" 或 "红黑树" 给 BPF？

- **简单性**：DSQ（FIFO 或优先级队列）是最通用的调度基元
- **灵活性**：BPF 调度器可以维护自己的数据结构（红黑树、堆、位图）并决定何时将任务推送到 DSQ
- **确定性**：DSQ 的语义简单明确，BPF 验证器可以安全地检查其使用模式
- **批处理**：`dispatch_max_batch` 控制一次调度可以处理的任务数，适合批量迁移

### 3. slice 管理

时间片管理由 BPF 调度器完全控制：

```c
// BPF 调度器通过设置 scx_bpf_dsq_insert() 的 slice 参数指定时间片
// 也可以直接在 tick 回调中修改 p->scx.slice

// 内核在以下情况触发重新调度：
// 1. 时间片耗尽（slice == 0）
// 2. BPF 调度器通过 scx_bpf_kick_cpu() 强制
// 3. 更高优先级的任务变为可运行（其他调度类）
```

默认 slice：`SCX_SLICE_DFL = 20ms`（比 EEVDF 的 3ms 长得多，因为 BPF 调度器预期自己管理抢占时机）。

### 4. 与 EEVDF/CFS 的协作

sched_ext 不是全部替代——它与其他调度类协作：

- **公平服务器（fair_server）**：sched_ext 任务在 fair_server 中执行，确保非 SCX 任务也能获得 CPU 时间
- **内置空闲管理**：`SCX_OPS_KEEP_BUILTIN_IDLE` 标志使 BPF 调度器可以控制 idle CPU 的管理
- **任务从 SCX 移回公平调度（scx_ops_disable）**：调度器出错时，所有 SCX 任务被迁移回 CFS/EEVDF

## 编写 BPF 调度器的约束

### 验证器限制

- **无动态内存分配**：BPF 程序必须使用预分配或栈变量
- **无锁**：BPF 调度器不能使用自旋锁，必须依赖原子操作和 BPF 的核心同步
- **循环有界**：所有循环必须证明在有限步内结束
- **栈大小**：BPF 栈限制为 512 字节

### 解决策略

- 使用 `bpf_local_storage()` 在任务上附加私有数据
- 使用 `scx_bpf_dsq_move_to_local()` 的迭代器模式实现 DSQ 遍历
- 多个调度器实例共享数据通过 BPF map 实现


## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct sched_ext_ops` | kernel/sched/ext_internal.h | 292 |
| `struct scx_sched` | kernel/sched/ext.c | 22 |
| `struct sched_ext_entity` | include/linux/sched.h | (嵌入 task_struct) |
| `select_task_rq_scx()` | kernel/sched/ext.c | (ops.select_cpu) |
| `enqueue_task_scx()` | kernel/sched/ext.c | (ops.enqueue) |
| `pick_next_task_scx()` | kernel/sched/ext.c | (ops.dispatch) |
| `scx_ops_enable()` | kernel/sched/ext.c | 6520 |
| `scx_bpf_dsq_insert()` | kernel/sched/ext.c | (kfunc) |
| `SCX_SLICE_DFL` | include/linux/sched/ext.h | (20ms) |
