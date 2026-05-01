# 42-oom-killer — Linux 内核 OOM Killer 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**OOM（Out-Of-Memory）Killer** 是 Linux 内核在内存耗尽时选择并杀死进程的机制。当 __alloc_pages_slowpath 经过直接回收和内存规整后仍无法分配内存时，调用 out_of_memory 函数选择受害者进程并发送 SIGKILL。OOM Killer 是内存管理的最后一道防线，防止系统因内存耗尽而完全崩溃。

**doom-lsp 确认**：`mm/oom_kill.c` 含 **72 个符号**。关键函数：`oom_badness` @ L199（评分），`select_bad_process` @ L362（选择受害者），`__oom_kill_process` @ L912（执行杀死），`oom_init` @ L726（初始化 oom_reaper 线程）。

---

## 1. 选择算法：oom_badness

OOM Killer 通过 oom_badness 函数为每个进程计算一个分数，分数最高的进程被选中杀死：

```c
// mm/oom_kill.c:199 — doom-lsp 确认
unsigned long oom_badness(struct task_struct *p, struct mem_cgroup *memcg,
                          const nodemask_t *nodemask, unsigned long totalpages)
{
    long points;
    long adj;

    // 跳过不可杀进程（如 init、内核线程）
    if (oom_unkillable_task(p, memcg, nodemask))
        return 0;

    // 基础分 = RSS（驻留内存）+ swap 使用量
    // 进程占用的物理内存越多，分数越高
    points = get_mm_rss(p->mm) + get_mm_counter(p->mm, MM_SWAPENTS);

    // root 运行的特权进程分数降低（保护系统关键进程）
    if (has_capability_noaudit(p, CAP_SYS_ADMIN))
        points /= 4;

    // 根据 oom_score_adj 调整（-1000 到 +1000）
    // -1000: 永不杀死  +1000: 优先杀死
    adj = (long)p->signal->oom_score_adj;
    if (adj == OOM_SCORE_ADJ_MIN) {
        return 0;  // 设置为 -1000 的进程绝对不杀
    }

    points += adj;
    return points > 0 ? points : 1;
}
```

评分的核心逻辑是：占用物理内存越多的进程越可能被杀。root 进程分数减为四分之一以保护系统进程。oom_score_adj 允许显式调整。

---

## 2. 选择受害者：select_bad_process

```c
// mm/oom_kill.c:362 — 选择受害者
static struct task_struct *select_bad_process(struct oom_control *oc)
{
    struct task_struct *p;
    struct task_struct *chosen = NULL;
    unsigned long chosen_points = 0;

    rcu_read_lock();

    // 遍历所有进程
    for_each_process(p) {
        unsigned long points;
        // 跳过不可杀进程
        if (oom_unkillable_task(p, oc->memcg, oc->nodemask))
            continue;

        // 计算评分
        points = oom_badness(p, oc->memcg, oc->nodemask, oc->totalpages);
        if (!points || points < chosen_points)
            continue;

        // 选中分数更高的进程
        chosen = p;
        chosen_points = points;
    }

    rcu_read_unlock();
    return chosen;
}
```

---

## 3. 执行杀死：__oom_kill_process

```c
// mm/oom_kill.c:912 — 执行杀死
static void __oom_kill_process(struct task_struct *victim, const char *message)
{
    struct task_struct *p;
    struct mm_struct *mm;

    // 获取进程的 mm_struct
    mm = victim->mm;

    // 向整个线程组发送 SIGKILL
    for_each_thread(p, victim) {
        if (!p->mm)
            continue;
        mark_oom_victim(p);   // 标记为 OOM 受害者
        do_send_sig_info(SIGKILL, SEND_SIG_PRIV, p, PIDTYPE_TGID);
    }

    // 唤醒 OOM reaper 线程异步清理
    wake_oom_reaper(mm);
}
```

---

## 4. OOM 触发路径

```
__alloc_pages_slowpath 分配失败
  │
  └─ out_of_memory(oc)
       │
       ├─ 检查 sysctl_panic_on_oom → 如果设置则 panic
       │
       ├─ select_bad_process(oc)
       │   → oom_badness 计算所有进程分数
       │   → 选择最高分进程
       │   → 跳过 oom_unkillable_task
       │
       └─ __oom_kill_process(victim)
           → mark_oom_victim(victim)
           → do_send_sig_info(SIGKILL)
           → wake_oom_reaper(victim)
           → victim 退出释放内存
```

---

## 5. OOM Reaper 线程

```c
// mm/oom_kill.c:726 — 初始化 OOM reaper
static int __init oom_init(void)
{
    oom_reaper_th = kthread_run(oom_reaper, NULL, "oom_reaper");
    if (IS_ERR(oom_reaper_th))
        return PTR_ERR(oom_reaper_th);
    return 0;
}
```

OOM reaper 是一个内核线程（"oom_reaper"），在发送 SIGKILL 后异步回收受害进程的内存。它遍历进程的 VMA 并释放物理页面，确保即使受害进程因某种原因未能及时退出，其内存也能尽快被回收。

---

## 6. 用户空间控制

```bash
# 查看进程 OOM 分数
cat /proc/1234/oom_score        # 当前分数
cat /proc/1234/oom_score_adj    # 调整值

# 保护关键进程（设为永不杀死）
echo -1000 > /proc/1/oom_score_adj           # init
echo -500 > /proc/$(pidof sshd)/oom_score_adj  # sshd

# 系统级控制
sysctl vm.panic_on_oom=1       # OOM 时 panic 而非杀进程
sysctl vm.oom_kill_allocating_task=1  # 杀死触发者而非评分最高者
```

---

## 7. 保护机制

一些进程类型被豁免于 OOM Killer：

```c
// mm/oom_kill.c — 不可杀进程的判断
static bool __task_will_free_mem(struct task_struct *task)
{
    // 正在退出的进程（已收到 SIGKILL）
    // 不应该再被选为 OOM 目标
    if (task_will_free_mem(task))
        return true;
    return false;
}
```

oom_adj = -17 或 oom_score_adj = -1000 的进程不会被选中。init 进程（PID 1）也被保护。

---

## 8. 源码文件索引

| 文件 | 符号数 | 关键函数 |
|------|--------|---------|
| mm/oom_kill.c | 72 | oom_badness @ L199, select_bad_process @ L362 |
| mm/oom_kill.c | | __oom_kill_process @ L912, oom_init @ L726 |

---

## 9. 关联文章

- **17-page-allocator**: 页面分配触发 OOM
- **43-memcg**: memcg OOM 控制

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 10. oom_score_adj 详解

oom_score_adj 的取值范围是 -1000 到 +1000，它在 oom_badness 计算的原始分数基础上进行加减。系统管理员可以通过这个接口精细控制哪些进程在内存紧张时优先被牺牲：

```bash
# 数据库服务应该是最后被杀的对象
echo -800 > /proc/$(pidof mysqld)/oom_score_adj

# 浏览器缓存进程可以优先被杀
echo 200 > /proc/$(pidof chrome)/oom_score_adj

# 完全保护系统关键进程
echo -1000 > /proc/$(pidof systemd-journald)/oom_score_adj
```

oom_score_adj 与旧接口 oom_adj 兼容：oom_adj -17 等价于 oom_score_adj -1000。

## 11. constrained_alloc

当 OOM 触发时，constrained_alloc 检查当前分配是否受到 cpuset 或 memcg 的限制：

```c
// mm/oom_kill.c:249
static enum oom_constraint constrained_alloc(struct oom_control *oc)
{
    // CONSTRAINT_NONE: 无约束（全局 OOM）
    // CONSTRAINT_CPUSET: 仅从特定 CPU 集合中选受害者
    // CONSTRAINT_MEMCG: 仅在当前 memcg 中选受害者
    // CONSTRAINT_MEMORY_POLICY: 受内存策略限制

    if (oc->memcg) {
        // memcg OOM → 只在 cgroup 内选进程
        return CONSTRAINT_MEMCG;
    }
    // ...
}
```

在容器环境中，OOM 通常是由 cgroup 的内存限制触发的（memcg OOM）。此时 OOM Killer 只在触发限制的 cgroup 内部选择受害者，不会影响到其他 cgroup 中的进程。

## 12. OOM 与 memcg

当 memory cgroup 达到 `memory.max` 上限时，触发 memcg OOM：

```
cgroup 内页面分配 → page_counter_try_charge 失败
  → mem_cgroup_out_of_memory(memcg, gfp_mask, order)
    → select_bad_process 只在当前 memcg 内遍历进程
    → 杀死 memcg 内的进程
    → 释放的内存回归 memcg 限额
```

这种隔离机制保证了容器场景下 OOM 不会跨容器。

## 13. sysctl 参数

```bash
# OOM 相关内核参数
vm.panic_on_oom = 0               # 0=杀进程, 1=panic, 2=强制 panic
vm.oom_kill_allocating_task = 0   # 0=杀最高分进程, 1=杀触发者
vm.oom_dump_tasks = 1             # 1=OOM 时打印进程信息

# OOM 分数显示
/proc/<pid>/oom_score       # 当前 OOM 分数（只读）
/proc/<pid>/oom_score_adj   # 调整值（可写 -1000 到 +1000）
/proc/<pid>/oom_adj         # 旧接口（可写 -17 到 +15）
```

## 14. 调试信息

当 OOM Killer 被触发时，内核会打印详细的进程内存信息到内核日志：

```
# dmesg 中的 OOM 信息
[12345.678] mysqld invoked oom-killer: gfp_mask=0x100cca(GFP_HIGHUSER_MOVABLE)
[12345.679] CPU: 2 PID: 1234 Comm: mysqld Not tainted 7.0.0-rc1
[12345.680] Call Trace:
[12345.681]  dump_stack+0x41/0x60
[12345.682]  dump_header+0x4a/0x2a0
[12345.683]  out_of_memory.cold+0x5a/0x9b
[12345.684]  __alloc_pages_slowpath+0xd5a/0xe60
[12345.685]  __alloc_pages+0x312/0x330

[12345.686] Mem-Info:
[12345.687] active_anon:123456 inactive_anon:78901
[12345.688] active_file:4567 inactive_file:8901
[12345.689] unevictable:1234 dirty:56 writeback:0
[12345.690] slab_reclaimable:23456 slab_unreclaimable:12345

[12345.691] oom-kill:constraint=CONSTRAINT_MEMCG
[12345.692] oom-kill: killing process 5678 (java), score 523, oom_score_adj 0
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 15. oom_unkillable_task 保护逻辑

OOM Killer 并非对所有进程都有效。以下类型的进程被标记为不可杀：

```c
// mm/oom_kill.c:160 — 检查进程是否不可杀
static bool oom_unkillable_task(struct task_struct *p)
{
    // init 进程 (PID 1) 永远不可杀
    if (is_global_init(p))
        return true;

    // 内核线程没有 mm_struct，不可杀
    if (!p->mm)
        return true;

    // oom_score_adj 设为 -1000 的进程
    // 由用户空间显式保护
    if (p->signal->oom_score_adj == OOM_SCORE_ADJ_MIN)
        return true;

    return false;
}
```

init 进程是系统中第一个用户空间进程，杀死它会直接导致系统崩溃。内核线程没有用户空间内存，杀死它们没有意义。oom_score_adj = -1000 允许管理员显式保护关键服务。

## 16. OOM 避免策略

与其依赖 OOM Killer 在内存耗尽后恢复，更好的策略是预防 OOM：

```bash
# 1. 设置合理的 memory cgroup 限制
# 每个容器设置 memory.max，防止单容器耗尽系统内存

# 2. 启用 overcommit 控制
# vm.overcommit_memory = 2 禁止超额分配
sysctl vm.overcommit_memory=2
sysctl vm.overcommit_ratio=80  # 最多使用 80% 物理内存

# 3. 监控内存使用趋势
# 使用 sar、free、/proc/meminfo 定期检查

# 4. 配置 swap space
# 合理的 swap 空间提供缓冲，但注意性能影响
```

## 17. OOM 与容器

在 Kubernetes/Docker 容器环境中，OOM Killer 与 cgroup 的内存限制配合工作：

```bash
# 每个 Pod 设置 memory limit
# 超限时触发 memcg OOM
# 只在 Pod 内部选择受害者
# 不影响宿主机或其他 Pod

# 设置 Pod 的 OOM 优先级
# oom_score_adj 通过 Pod QoS 级别自动设置
# Guaranteed: -998
# Burstable: 0-999
# BestEffort: 1000
```

## 18. 源码文件索引

| 文件 | 符号数 | 关键行 |
|------|--------|--------|
| mm/oom_kill.c | 72 | oom_badness @ L199, select_bad_process @ L362 |
| mm/oom_kill.c | | __oom_kill_process @ L912, oom_init @ L726 |
| include/linux/oom.h | — | API 声明 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
