# membarrier — 内存屏障指令深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/sched/membarrier.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**membarrier**（Linux 4.16+）提供高效的多线程内存屏障，比 `sched_setaffinity` + `sync_core` 快得多。

---

## 1. 问题背景

```
多线程程序中：
  线程 A 修改共享数据（store）
  线程 B 读取共享数据（load）

如果没有内存屏障：
  线程 B 可能看到旧数据（编译器/CPU 重排序）

传统解决方案：
  - CPU 指令：mfence/lfence/sfence（重量级）
  - 编译器屏障：barrier()（只阻止编译器重排）
  - 每线程切换：sched_setaffinity + sync_core（非常重）
```

---

## 2. 核心数据结构

```c
// kernel/sched/membarrier.c — membarrier_state
struct membarrier_state {
    atomic_t                 enabled;          // 是否启用
    atomic_t                 cpuhp_node_state; // CPU 热插拔状态
    unsigned int             flags;           // MEMBARRIER_FLAG_*
};
```

---

## 3. sys_membarrier — 系统调用

```c
// kernel/sched/membarrier.c — sys_membarrier
SYSCALL_DEFINE2(membarrier, int, cmd, unsigned int, flags)
{
    switch (cmd) {
    case MEMBARRIER_CMD_QUERY:
        // 查询支持的命令
        return MEMBARRIER_CMD_GLOBAL | MEMBARRIER_CMD_GLOBAL_EXPEDITED;

    case MEMBARRIER_CMD_REGISTER:
        // 注册 MMIO 屏障（未来使用）
        return 0;

    case MEMBARRIER_CMD_GLOBAL_EXPEDITED:
        // 快速路径：发送 IPI 到所有线程
        // 每个线程在返回用户空间前执行一次内存屏障
        return membarrier_global_expedited();

    case MEMBARRIER_CMD_PRIVATE_EXPEDITED:
        // 仅指定线程组
        return membarrier_private_expedited(flags);

    case MEMBARRIER_CMD_SYNC_CORE:
        // 确保所有核心看到相同的内存视图
        return membarrier_sync_core();
    }

    return -EINVAL;
}
```

---

## 4. membarrier_global_expedited — 快速全局屏障

```c
// kernel/sched/membarrier.c — membarrier_global_expedited
static int membarrier_global_expedited(void)
{
    int cpu;

    // 1. 遍历所有在线 CPU
    for_each_online_cpu(cpu) {
        if (cpu == smp_processor_id())
            continue;  // 跳过当前 CPU

        // 2. 发送 IPI（核间中断）
        // 每个 CPU 在 IPI 处理函数中执行 smp_mb()
        smp_call_function_single(cpu, membarrier_ipi, NULL, 0);
    }

    // 3. 当前 CPU 执行内存屏障
    smp_mb();

    return 0;
}

// IPI 处理函数：
static void membarrier_ipi(void *info)
{
    // 在返回用户空间前插入内存屏障
    smp_mb();
}
```

---

## 5. private expedited — 私有线程组屏障

```c
// kernel/sched/membarrier.c — membarrier_private_expedited
static int membarrier_private_expedited(unsigned int flags)
{
    struct task_struct *p;
    int cpu;

    // 1. 获取线程组
    struct task_struct *leader = current->group_leader;

    // 2. 遍历线程组所有线程
    for_each_thread(leader, p) {
        if (p == current)
            continue;

        cpu = task_cpu(p);

        // 3. 发送 IPI 到每个线程所在的 CPU
        smp_call_function_single(cpu, membarrier_ipi, NULL, 0);
    }

    // 4. 当前线程执行屏障
    smp_mb();

    return 0;
}
```

---

## 6. 与其他屏障的对比

| 方法 | 延迟 | 开销 |
|------|------|------|
| `__sync_synchronize()` | 高 | 全核同步 |
| `smp_mb()` | 中 | 仅 SMP |
| `dma_mb()` | 中低 | 设备内存 |
| `membarrier(GLOBAL_EXPEDITED)` | 低 | 仅 IPI |

---

## 7. 完整文件索引

| 文件 | 函数 |
|------|------|
| `kernel/sched/membarrier.c` | `sys_membarrier`、`membarrier_global_expedited` |
| `include/uapi/linux/membarrier.h` | MEMBARRIER_CMD_* |