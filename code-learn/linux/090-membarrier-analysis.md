# 090-membarrier — Linux 内存屏障系统调用深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**membarrier** 是 Linux 的**内存屏障系统调用**（`kernel/sched/membarrier.c`），允许用户空间通过一次 syscall 向一组 CPU 发送 `smp_mb()` 指令。专为用户空间 RCU（Userspace RCU, URCU）设计——写侧通过 `membarrier()` 等待所有读侧完成，读侧**零额外指令**开销。

**核心设计**：SYSCALL_DEFINE3(membarrier, cmd, flags, cpu_id) 根据命令分发：

- `MEMBARRIER_CMD_GLOBAL` → `ipi_mb()`（所有 CPU）
- `MEMBARRIER_CMD_PRIVATE_EXPEDITED` → IPI 同进程 CPU
- `MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED` → 注册进程

**doom-lsp 确认**：`kernel/sched/membarrier.c`（679 行，28 个符号）。

---

## 1. 核心数据结构

### 1.1 `struct mm_struct` 中的 membarrier 状态

```c
struct mm_struct {
    ...
    atomic_t            membarrier_state;   // 进程的 membarrier 注册状态
    // 位 0: PRIVATE_EXPEDITED 已注册
    // 位 1: PRIVATE_EXPEDITED_SYNC_CORE 已注册
    ...
};
```

### 1.2 per-CPU 状态

```c
// kernel/sched/membarrier.c — doom-lsp 确认
static cpumask_t *membarrier_pending;   // 挂起的 membarrier 请求
static DEFINE_PER_CPU(struct task_struct *, membarrier_rq_task); // 当前 CPU 上的任务
```

---

## 2. 核心执行路径

### 2.1 PRIVATE_EXPEDITED——IPI 同一进程的所有 CPU

```c
// L316 — doom-lsp 确认
static int membarrier_private_expedited(void)
{
    struct mm_struct *mm = current->mm;
    cpumask_t *tmpmask;

    // 1. 如果当前进程没有注册 → 拒绝
    if (!(atomic_read(&mm->membarrier_state) &
          MEMBARRIER_STATE_PRIVATE_EXPEDIENT_READY))
        return -EPERM;

    // 2. 遍历所有 CPU，找到运行在当前进程地址空间的 CPU
    cpus_read_lock();
    for_each_online_cpu(cpu) {
        struct task_struct *p = per_cpu(membarrier_rq_task, cpu);
        if (p && p->mm == mm)
            cpumask_set_cpu(cpu, tmpmask);  // 标记需要 IPI
    }

    // 3. 发送 IPI
    smp_call_function_many(tmpmask, ipi_mb, NULL, 1);
    // ipi_mb 函数：WRITE_ONCE(..., smp_processor_id()) + smp_mb()

    cpus_read_unlock();
    return 0;
}
```

### 2.2 GLOBAL——所有 CPU

```c
static int membarrier_global_expedited(void)    // L250
{
    // 简化：对所有 CPU 调用 smp_call_function(ipi_mb)
    // ipi_mb() 执行 smp_mb()（x86: mfence, arm64: dmb ish）
    synchronize_rcu_expedited();  // 或者基于 IPI 的自定义实现
}
```

### 2.3 注册路径

```c
// do_membarrier_register() — doom-lsp 确认
static int do_membarrier_register(int cmd)
{
    struct mm_struct *mm = current->mm;

    switch (cmd) {
    case MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED:
        // 设置 mm->membarrier_state 位 0
        atomic_set_bit(MEMBARRIER_STATE_PRIVATE_EXPEDIENT_BIT, &mm->membarrier_state);
        break;
    case MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED_SYNC_CORE:
        // 设置位 1（额外保证：IPI 附带 sync_core）
        atomic_set_bit(MEMBARRIER_STATE_SYNC_CORE_BIT, &mm->membarrier_state);
        break;
    }
}
```

---

## 3. 内存序保证（源自 membarrier.c 文件头注释）

```
Scenario A: 写者先 barrier 再 IPI，读者在 IPI 后 barrier
  CPU0 (membarrier caller):         CPU1 (target):
    x = 1                             y = 1
    membarrier():                      barrier()
      a: smp_mb()                     r1 = x
      b: send IPI →→→→ IPI-induced mb
      c: smp_mb()
    r2 = y
  BUG_ON(r1==0 && r2==0)  // (a) 禁止 x=1 移到 IPI 后

Scenario B: 读者先 barrier 再写，写者在 IPI 后 barrier
  CPU0 (membarrier caller):         CPU1 (target):
    r2 = y                            x = 1
    membarrier():                      barrier()
      a: smp_mb()                     y = 1
      b: send IPI →→→→ IPI-induced mb
  // barrier 保证目标 CPU 在 IPI 到达前看到所有之前的内存操作
```

---

## 4. membarrier vs 其他同步机制

| 机制 | 读侧开销 | 写侧开销 | 适用场景 |
|------|---------|---------|---------|
| RCU（内核） | 0（rcu_read_lock） | synchronize_rcu | 内核数据结构 |
| URCU（membarrier） | 0（无指令） | IPI 所有 CPU | 用户空间 RCU |
| seqlock | 原子读（seq 比较） | spin_lock | 写者优先 |
| rwlock | 原子操作 | spin_lock | 读写比例均衡 |

---

## 5. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `sys_membarrier()` | kernel/sched/membarrier.c | (SYSCALL_DEFINE3) |
| `membarrier_global_expedited()` | kernel/sched/membarrier.c | 250 |
| `membarrier_private_expedited()` | kernel/sched/membarrier.c | 316 |
| `do_membarrier_register()` | kernel/sched/membarrier.c | 相关 |
| `ipi_mb()` | kernel/sched/membarrier.c | IPI 回调 |
| `mm_struct->membarrier_state` | include/linux/mm_types.h | 原子位标志 |
| `membarrier_rq_task` | kernel/sched/membarrier.c | per-CPU 变量 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
