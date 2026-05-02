# 90-membarrier — Linux 内存屏障系统调用深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**membarrier** 是 Linux 的**内存屏障系统调用**（`kernel/sched/membarrier.c`，679 行），允许用户空间通过单个 syscall 向一组 CPU 发送 `smp_mb()`。用于用户空间 RCU 实现——写侧只需一次 `membarrier()` 即可等待所有读侧完成，读侧零额外指令开销。

**核心设计**：
```
读线程（无开销）:            写线程（一次 syscall）:
  rcu_read_lock()              │
    → 无额外指令              synchronize_rcu()
  p = rcu_dereference(gp)       → membarrier(PRIVATE_EXPEDITED)
  rcu_read_unlock()               → IPI 到所有匹配 CPU
    → 无额外指令                   → ipi_mb() → smp_mb()
                                   → 所有读侧已可见 → 释放旧数据
```

**doom-lsp 确认**：`kernel/sched/membarrier.c`。`ipi_mb` @ `:184`，`membarrier_private_expedited` @ `:316`，`membarrier_global_expedited` @ `:250`。

---

## 1. 系统调用入口

```c
SYSCALL_DEFINE3(membarrier, int, cmd, unsigned int, flags, int, cpu_id)
{
    switch (cmd) {
    case MEMBARRIER_CMD_GLOBAL:
    case MEMBARRIER_CMD_GLOBAL_EXPEDITED:
        return membarrier_global_expedited();

    case MEMBARRIER_CMD_PRIVATE_EXPEDITED:
    case MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE:
    case MEMBARRIER_CMD_PRIVATE_EXPEDITED_RSEQ:
        return membarrier_private_expedited(flags, cpu_id);

    case MEMBARRIER_CMD_REGISTER_GLOBAL_EXPEDITED:
    case MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED:
        // atomic_or(state_bit, &mm->membarrier_state)
        return membarrier_register(cmd);
    }
}
```

---

## 2. IPI 回调 @ :184

```c
// 目标 CPU 收到 IPI 后执行的函数：
static void ipi_mb(void *info)
{
    smp_mb();   // 全内存屏障（x86: mfence, arm64: dmb）
}
```

---

## 3. membarrier_state——进程匹配

```c
// 每个 mm_struct 和每个 CPU 的 runqueue 维护 membarrier_state 位：

#define MEMBARRIER_STATE_GLOBAL_EXPEDITED       (1 << 0)  // 注册了全局屏障
#define MEMBARRIER_STATE_PRIVATE_EXPEDITED      (1 << 1)  // 注册了进程内屏障

// 进程切换时同步 @ :241：
// membarrier_arch_switch_mm(prev, next) {
//     int state = 0;
//     if (next_mm)
//         state = atomic_read(&next_mm->membarrier_state);
//     WRITE_ONCE(rq->membarrier_state, state);
// }
//
// 这样 membarrier_private_expedited 遍历 CPU 时，
// 通过检查 rq->membarrier_state 确定此 CPU 是否正在运行此进程
```

---

## 4. membarrier_private_expedited @ :316

```c
static int membarrier_private_expedited(int flags, int cpu_id)
{
    SERIALIZE_IPI();             // mutex_lock(&membarrier_ipi_mutex)

    // 1. 遍历在线 CPU，找出运行此 mm 的 CPU
    for_each_online_cpu(cpu) {
        if (!(READ_ONCE(cpu_rq(cpu)->membarrier_state) &
              MEMBARRIER_STATE_PRIVATE_EXPEDITED))
            continue;
        cpumask_set_cpu(cpu, tmpmask);
    }

    // 2. 向匹配 CPU 发送 IPI 执行内存屏障
    smp_call_function_many(tmpmask, ipi_mb, NULL, 1);
    // → ipi_mb() 在目标 CPU 上执行 smp_mb()
    // → 确保之前所有的写操作对目标 CPU 可见
}
```

---

## 5. 性能

| 命令 | 延迟 | 说明 |
|------|------|------|
| `GLOBAL_EXPEDITED` | ~10-100μs | IPI 到所有 CPU |
| `PRIVATE_EXPEDITED` | ~5-50μs | IPI 到匹配 CPU |
| 读侧（`rcu_read_lock`） | **0** | 无额外指令 |

---

## 6. 总结

`membarrier` 通过 `SYSCALL_DEFINE3` → 按命令分发 → `membarrier_private_expedited`（`:316`）→ 检查 `rq->membarrier_state` → `smp_call_function_many` → `ipi_mb`（`:184`）→ `smp_mb()` 实现进程级/全局内存屏障。`membarrier_state` 位掩码在进程切换时同步到 runqueue，用于 IPI 的目标 CPU 过滤。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
