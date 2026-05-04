# 90-membarrier — Linux 内存屏障系统调用深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**membarrier** 是 Linux 的**内存屏障系统调用**（`kernel/sched/membarrier.c`，679 行），允许用户空间通过一次 syscall 向一组 CPU 发送 `smp_mb()` 指令。专为用户空间 RCU 设计——写侧通过 `membarrier()` 等待所有读侧完成，读侧**零额外指令**开销。

**核心设计**：`SYSCALL_DEFINE3(membarrier, cmd, flags, cpu_id)` 根据命令类型分发：
- `MEMBARRIER_CMD_GLOBAL_EXPEDITED` → `membarrier_global_expedited()`（`:250`）→ IPI 所有 CPU
- `MEMBARRIER_CMD_PRIVATE_EXPEDITED` → `membarrier_private_expedited()`（`:316`）→ IPI 同进程 CPU

**内存序保证**（源自文件头注释 `:30-90`）：

```
Scenario A: 写者先 barrier 再 IPI，读者在 IPI 后 barrier
  CPU0 (membarrier caller):         CPU1 (target):
    x = 1                             y = 1
    membarrier():                      barrier()
      a: smp_mb()                     r1 = x
      b: send IPI →→→→ IPI-induced mb
      c: smp_mb()
    r2 = y
  BUG_ON(r1==0 && r2==0)  // (a) 禁止 x=1 后移到 IPI 后

Scenario B: 读者先 barrier 再写，写者在 IPI 后 barrier
  CPU0 (membarrier caller):         CPU1 (target):
    r2 = y                            x = 1
    membarrier():                      barrier()
      a: smp_mb()                     y = 1
      b: send IPI →→→→ IPI-induced mb
      c: smp_mb()
    r1 = x
  BUG_ON(r1==0 && r2==1)  // (c) 禁止 r1=x 前移到 IPI 前
```

**doom-lsp 确认**：`ipi_mb` @ `:170`，`membarrier_global_expedited` @ `:250`，`membarrier_private_expedited` @ `:316`，`membarrier_register_global_expedited` @ `:496`，`sync_runqueues_membarrier_state` @ `:438`。

---

## 1. membarrier_state——进程匹配位掩码

```c
// 每个 mm_struct 的 membarrier_state 位掩码：
#define MEMBARRIER_STATE_GLOBAL_EXPEDITED              (1 << 0)  // 已注册
#define MEMBARRIER_STATE_GLOBAL_EXPEDITED_READY        (1 << 4)  // 已就绪
#define MEMBARRIER_STATE_PRIVATE_EXPEDITED             (1 << 1)
#define MEMBARRIER_STATE_PRIVATE_EXPEDITED_READY       (1 << 5)

// 进程切换时同步到 runqueue @ :238：
// void membarrier_update_current_mm(struct mm_struct *next_mm) {
//     int state = next_mm ? atomic_read(&next_mm->membarrier_state) : 0;
//     if (READ_ONCE(rq->membarrier_state) == state) return;
//     WRITE_ONCE(rq->membarrier_state, state);
// }
```

**doom-lsp 确认**：`membarrier_update_current_mm` @ `:238` 在进程切换时由 `membarrier_arch_switch_mm` 调用。

---

## 2. 注册流程——membarrier_register_global_expedited @ :496

```c
// 使用 membarrier 前必须先注册
static int membarrier_register_global_expedited(void)
{
    // 1. 在 mm->membarrier_state 中设置注册位
    atomic_or(MEMBARRIER_STATE_GLOBAL_EXPEDITED, &mm->membarrier_state);

    // 2. 同步所有 CPU 的 runqueue
    ret = sync_runqueues_membarrier_state(mm);
    // → synchronize_rcu() 等待所有 RCU 读侧完成
    // → on_each_cpu_mask(tmpmask, ipi_sync_rq_state, mm, true)
    //   → 在匹配的 CPU 上刷新 membarrier_state

    // 3. 设置 READY 位
    atomic_or(MEMBARRIER_STATE_GLOBAL_EXPEDITED_READY, &mm->membarrier_state);
    return 0;
}
```

---

## 3. membarrier_private_expedited @ :316——IPI 实现

```c
static int membarrier_private_expedited(int flags, int cpu_id)
{
    // 1. 检查注册状态
    if (!(atomic_read(&mm->membarrier_state) & READY_STATE))
        return -EPERM;              // 未注册 → 拒绝

    // 2. 选择 IPI 回调函数
    ipi_func = ipi_mb;              // 默认：smp_mb()
    if (flags == SYNC_CORE)
        ipi_func = ipi_sync_core;   // 额外 sync_core_before_usermode()
    if (flags == RSEQ)
        ipi_func = ipi_rseq;        // 额外 rseq_sched_switch_event()

    // 3. 快速路径：单线程/单 CPU
    if (atomic_read(&mm->mm_users) == 1 || num_online_cpus() == 1)
        return 0;                   // 不需要 IPI

    // 4. 入口内存屏障（Scenario A 的 (a)）
    smp_mb();

    // 5. 遍历 CPU，找出运行此 mm 的线程
    for_each_online_cpu(cpu) {
        p = rcu_dereference(cpu_rq(cpu)->curr);
        if (p && p->mm == mm)
            cpumask_set_cpu(cpu, tmpmask);
    }

    // 6. 发送 IPI
    smp_call_function_many(tmpmask, ipi_func, NULL, true);
    // 每个目标 CPU 执行 ipi_func() → smp_mb()

    // 7. 出口内存屏障（Scenario B 的 (c)）
    smp_mb();
    return 0;
}
```

### IPI 回调函数群

```c
static void ipi_mb(void *info) {
    smp_mb();   // 全内存屏障（x86: mfence, arm64: dmb ish）
}

static void ipi_sync_core(void *info) {
    smp_mb();
    sync_core_before_usermode();   // 指令流同步（ISB/CPUID）
}

static void ipi_rseq(void *info) {
    smp_mb();
    rseq_sched_switch_event(current);  // 可重启序列事件
}
```

---

## 4. SYSCALL_DEFINE3——系统调用入口 @ :627

```c
SYSCALL_DEFINE3(membarrier, int, cmd, unsigned int, flags, int, cpu_id)
{
    switch (cmd) {
    case MEMBARRIER_CMD_QUERY:                  // 查询支持的命令
        return MEMBARRIER_CMD_BITMASK;

    case MEMBARRIER_CMD_GLOBAL:                 // 全局同步（不快速）
        synchronize_rcu();
        return 0;

    case MEMBARRIER_CMD_GLOBAL_EXPEDITED:       // 全局快速
        return membarrier_global_expedited();

    case MEMBARRIER_CMD_PRIVATE_EXPEDITED:      // 进程内快速（默认）
        return membarrier_private_expedited(0, cpu_id);

    case MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE:
        return membarrier_private_expedited(SYNC_CORE, cpu_id);

    case MEMBARRIER_CMD_PRIVATE_EXPEDITED_RSEQ:
        return membarrier_private_expedited(RSEQ, cpu_id);

    case MEMBARRIER_CMD_REGISTER_*:
        return membarrier_register_*(...);

    case MEMBARRIER_CMD_GET_REGISTRATIONS:
        return membarrier_get_registrations();
    }
}
```

---

## 5. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `ipi_mb` | `:170` | IPI 回调：smp_mb() |
| `ipi_sync_core` | `:175` | IPI 回调：smp_mb + sync_core |
| `ipi_rseq` | `:192` | IPI 回调：smp_mb + rseq event |
| `membarrier_update_current_mm` | `:238` | 进程切 runqueue 同步 |
| `membarrier_global_expedited` | `:250` | 全局 IPI 屏障 |
| `membarrier_private_expedited` | `:316` | 进程内 IPI 屏障 |
| `sync_runqueues_membarrier_state` | `:438` | 注册时 runqueue 同步 |
| `membarrier_register_global_expedited` | `:496` | 注册全局屏障 |
| `membarrier_register_private_expedited` | `:515` | 注册进程内屏障 |
| `SYSCALL_DEFINE3(membarrier)` | `:627` | 系统调用入口 |

---

## 6. 性能

| 操作 | 延迟 | 说明 |
|------|------|------|
| `GLOBAL_EXPEDITED` | ~10-100μs | IPI 到所有在线 CPU |
| `PRIVATE_EXPEDITED` | ~5-50μs | IPI 到同进程 CPU |
| 读侧 `rcu_read_lock/unlock` | **0** | 无额外指令 |

---

## 6. 用户空间 RCU 使用模式

```c
// liburcu 中的 synchronize_rcu() 实现（简化）：
void synchronize_rcu(void) {
    // 1. 写屏障：确保写操作在 IPI 前可见
    smp_mb();

    // 2. 调用 membarrier——IPI 到所有同进程 CPU
    membarrier(MEMBARRIER_CMD_PRIVATE_EXPEDITED, 0, 0);

    // 3. 读屏障：确保 IPI 后读操作正确
    smp_mb();
}

// 读侧（零额外开销）：
rcu_read_lock()     → 无操作
p = rcu_dereference(gp) → READ_ONCE()
rcu_read_unlock()   → 无操作
```

## 7. SYSCALL_DEFINE3 @ :627——命令分发详情

```c
SYSCALL_DEFINE3(membarrier, int, cmd, unsigned int, flags, int, cpu_id)
{
    switch (cmd) {
    case MEMBARRIER_CMD_QUERY:
        return MEMBARRIER_CMD_BITMASK;           // 返回支持的命令位图

    case MEMBARRIER_CMD_GLOBAL:
        if (tick_nohz_full_enabled()) return -EINVAL;
        synchronize_rcu();                       // 全局同步（慢）
        return 0;

    case MEMBARRIER_CMD_GLOBAL_EXPEDITED:
        return membarrier_global_expedited();     // IPI 所有 CPU

    case MEMBARRIER_CMD_REGISTER_GLOBAL_EXPEDITED:
        return membarrier_register_global_expedited();

    case MEMBARRIER_CMD_PRIVATE_EXPEDITED:
        return membarrier_private_expedited(0, cpu_id);

    case MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE:
        return membarrier_private_expedited(SYNC_CORE, cpu_id);

    case MEMBARRIER_CMD_PRIVATE_EXPEDITED_RSEQ:
        return membarrier_private_expedited(RSEQ, cpu_id);

    case MEMBARRIER_CMD_GET_REGISTRATIONS:
        return membarrier_get_registrations();
    }
}
```

## 8. 注册路径——membarrier_register_private_expedited

```c
// 使用 membarrier 前必须先注册：
// membarrier(MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED, 0, 0)

static int membarrier_register_private_expedited(int flags)
{
    // atomic_or(MEMBARRIER_STATE_PRIVATE_EXPEDITED, &mm->membarrier_state)
    // sync_runqueues_membarrier_state(mm) 同步所有 CPU 的 runqueue
    // atomic_or(MEMBARRIER_STATE_PRIVATE_EXPEDITED_READY, &mm->membarrier_state)
}
```

## 9. IPI 回调函数详细

```c
// ipi_mb @ :170 — 基础内存屏障
static void ipi_mb(void *info)  { smp_mb(); }

// ipi_sync_core @ :175 — 内存屏障 + 指令流同步
// 用于 SYNC_CORE 命令（修改代码后需要清指令缓存）
static void ipi_sync_core(void *info) {
    smp_mb();
    sync_core_before_usermode();  // x86: CPUID; arm64: ISB
}

// ipi_rseq @ :192 — 内存屏障 + 可重启序列事件
static void ipi_rseq(void *info) {
    smp_mb();
    rseq_sched_switch_event(current);  // 重启 RSEQ 临界区
}

// ipi_sync_rq_state @ :205 — 同步 membarrier_state 到 runqueue
static void ipi_sync_rq_state(void *info) {
    if (current->mm != (struct mm_struct *)info) return;
    this_cpu_write(runqueues.membarrier_state,
                   atomic_read(&current->mm->membarrier_state));
}
```

## 10. 性能

| 命令 | 延迟 | 说明 |
|------|------|------|
| `PRIVATE_EXPEDITED`（单线程）| **~0** | mm_users==1 直接返回 |
| `PRIVATE_EXPEDITED`（多线程）| **~5-50μs** | IPI 到匹配 CPU |
| `GLOBAL_EXPEDITED` | **~10-100μs** | IPI 到所有 CPU |
| `GLOBAL`（慢路径）| **~1-10ms** | synchronize_rcu() |

## 11. 总结

`membarrier`（`kernel/sched/membarrier.c`，679 行）通过 `SYSCALL_DEFINE3`（`:627`）分派 10 个子命令。核心路径 `membarrier_private_expedited`（`:316`）→ 遍历 CPU 检查 `rq->curr->mm` → `smp_call_function_many(tmpmask, ipi_mb, NULL, 1)` → `ipi_mb`（`:170`）→ `smp_mb()`。提供 `ipi_mb`（基础）、`ipi_sync_core`（`:175`，+ISB）、`ipi_rseq`（`:192`，+RSEQ）、`ipi_sync_rq_state`（`:205`，状态同步）四种回调。文件头（`:11-100+`）提供内存序正确性证明。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `sys_membarrier()` | kernel/sched/membarrier.c | (SYSCALL_DEFINE3) |
| `membarrier_global_expedited()` | kernel/sched/membarrier.c | 250 |
| `membarrier_private_expedited()` | kernel/sched/membarrier.c | 316 |
| `do_membarrier_register()` | kernel/sched/membarrier.c | 相关 |
| `ipi_mb()` | kernel/sched/membarrier.c | IPI 回调 |
| `mm_struct->membarrier_state` | include/linux/mm_types.h | 原子位标志 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
