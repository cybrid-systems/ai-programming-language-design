# 198-cpuhp — CPU热插拔深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cpu.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**CPU Hotplug** 允许在线添加/移除 CPU 核心，无需重启。cpuhp 子系统管理热插拔状态转换。

---

## 1. CPU 热插拔状态

```c
// CPU 热插拔状态机：
//   CPUHP_OFFLINE          → CPU 已下线
//   CPUHP_CREATE_CPU       → 正在创建 CPU
//   CPUHP_PREPARE         → 准备中
//   CPUHP_ONLINE          → 上线中
//   CPUHP_ONLINE_IDLE     → 在线空闲
```

---

## 2. cpuhp

```c
// kernel/cpu.c — cpu_up
int cpu_up(unsigned int cpu)
{
    // 1. 分配 per-CPU 区域
    alloc_cpupkgs(cpu);

    // 2. 触发状态转换
    cpuhp_iniste(cpu, CPUHP_ONLINE);

    // 3. 启动调度
    idle_thread_get(cpu);
    rq_unlock(cpu_rq(cpu));
}
```

---

## 3. 西游记类喻

**CPU Hotplug** 就像"天庭的增兵撤兵"——

> CPU hotplug 像天庭可以在线增兵（上线新 CPU）或撤兵（下线 CPU）。增兵时先分配营房（per-CPU 数据），然后通知各部门（驱动注册），最后正式入编（调度器接受）。撤兵时顺序反过来。

---

## 4. 关联文章

- **sched_entity**（article 182）：idle 进程管理
- **memory_hotplug**（article 196）：CPU 和内存热插拔配合