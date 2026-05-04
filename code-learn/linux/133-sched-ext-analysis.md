# 133-sched-ext — 读 kernel/sched/ext.c

---

## sched_ext 的设计约束

sched_ext 是一个 BPF 可编程的调度器类，优先级在 RT 和 CFS 之间。但它必须满足一个关键约束：**安全性**。BPF 调度器可以用任何代码替换调度策略，但内核不能因为调度器崩溃而崩溃。

这个约束体现在代码的多个方面：

1. **scx_tasks 全局列表**（L39）：sched_ext 维护一个独立的进程列表，跟踪所有在 fork 和 free 之间的进程。当 BPF 调度器被禁用（`scx_ops_disable`）时，内核需要遍历所有 SCX 任务并将其移回 CFS——此时 PIDs 可能已经释放，`task_struct` 的 PID 列表不可用，所以需要一个独立的列表。

2. **scx_bypass_lock**（L47）：禁用 BPF 调度器时，需要确保没有 CPU 正在执行 BPF 调度器的回调。bypass 模式使用一个 per-CPU 的 cpumask 来跟踪哪些 CPU 仍在 BPF 路径中。

3. **双锁模型**：`scx_enable_mutex`（全局互斥锁，防止并发 enable/disable）+ `scx_sched_lock`（原始自旋锁，保护 sched list 的写操作）。读者只需 `rcu_read_lock()`。

---

## DSQ（Dispatch Queue）——调度的核心抽象

sched_ext 没有使用红黑树或任何通用排序结构。它的核心抽象是**调度队列（DSQ）**——FIFO 或优先级队列，BPF 调度器将任务放入 DSQ，CPU 从 DSQ 中取出任务执行。

三种 DSQ：
- **SCX_DSQ_LOCAL**：每个 CPU 本地 DSQ（FIFO）
- **SCX_DSQ_GLOBAL**：全局 FIFO DSQ
- **用户 DSQ**：BPF 调度器创建的任意 DSQ（通过 `scx_bpf_dsq_insert()`）

---

## 回调路径

```
select_task_rq_scx()      // 唤醒时选择目标 CPU
  → ops.select_cpu(p, prev_cpu, wake_flags)
    → BPF 设置 p->scx.dsq（直接入队某 DSQ）
    → 返回目标 CPU

enqueue_task_scx()        // 任务入队
  → 如果 select_cpu 已经入队了 → 跳过
  → ops.enqueue(p, enq_flags)
    → BPF 决定：scx_bpf_dsq_insert(task, dsq_id, slice, flags)

dispatch（CPU 本地队列空时调用）
  → ops.dispatch(cpu, prev)
    → scx_bpf_dsq_move_to_local() 从用户 DSQ 取任务
    → scx_bpf_dsq_insert() 直接插入本地 DSQ

pick_next_task_scx()      // 选择下一个运行的任务
  → 检查本地 DSQ（FIFO 队列）
  → 如果空 → ops.dispatch() 让 BPF 填充
  → 取本地 DSQ 的第一个任务
```

---

## 为什么用 DSQ 而不是红黑树

CFS/EEVDF 使用红黑树按 deadline 排序。sched_ext 使用 DSQ 是因为：

1. **DSQ 是通用基元**——FIFO 或优先级队列是任何调度算法的输出基元
2. **BPF 验证器限制**——BPF 程序不能在内核红黑树上操作（不能访问 `rb_node` 结构）
3. **性能**——DSQ 操作是 O(1)（list_add / list_del），BPF 调度器自己决定何时排序
4. **批量**——`dispatch_max_batch` 限制单次 dispatch 可以移动的任务数，控制延迟
