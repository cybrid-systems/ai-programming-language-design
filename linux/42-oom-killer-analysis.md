# 42-OOM-Killer — 内存耗尽杀手深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/oom_kill.c` + `include/linux/oom.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**OOM Killer（Out-Of-Memory Killer）** 是 Linux 内存耗尽时的最后防线：当所有内存回收手段用尽后，选择一个进程杀掉（`SIGKILL`）以释放内存。核心函数是 `out_of_memory()` → `select_bad_process()` → `oom_kill_process()`。

---

## 1. 触发路径

```
内存分配失败（__alloc_pages）
        ↓
out_of_memory(oc)        // mm/page_alloc.c
        ↓
检查 watermark（水位线）
        ↓
如果所有 zone 都低于 WMARK_MIN
        ↓
调用 OOM Killer
```

---

## 2. 核心数据结构

### 2.1 struct oom_control — OOM 上下文

```c
// include/linux/oom.h — oom_control
struct oom_control {
    struct zonelist           *zonelist;       //zonelist，用于确定 cpuset
    nodemask_t               *nodemask;        // 节点掩码（mempolicy）

    // Memory cgroup：如果是 memcg OOM，则不为 NULL
    struct mem_cgroup        *memcg;

    const gfp_t               gfp_mask;         // 触发 OOM 的 GFP 掩码
    const int                 order;             // 分配阶（order == -1 表示 sysrq 触发）

    // 以下由 OOM 实现填充
    unsigned long             totalpages;        // 可用总页数
    struct task_struct       *chosen;           // 被选中的 victim 进程
    long                     chosen_points;     // victim 的 oom_badness 分数

    // 约束类型
    enum oom_constraint       constraint;
    //   CONSTRAINT_NONE         = 无特殊约束（全局 OOM）
    //   CONSTRAINT_CPUSET       = cpuset 限制
    //   CONSTRAINT_MEMORY_POLICY = NUMA mempolicy 限制
    //   CONSTRAINT_MEMCG        = memcg 限制
};
```

### 2.2 enum oom_constraint — 约束类型

```c
// include/linux/oom.h
enum oom_constraint {
    CONSTRAINT_NONE,          // 全局 OOM，无特殊限制
    CONSTRAINT_CPUSET,        // 受 cpuset 节点限制
    CONSTRAINT_MEMORY_POLICY, // 受 NUMA mempolicy 限制
    CONSTRAINT_MEMCG,         // 受 memory cgroup 限制
};
```

---

## 3. 选择算法

### 3.1 oom_badness — 计算进程的 OOM 分数

```c
// mm/oom_kill.c:177 — oom_badness
long oom_badness(struct task_struct *p, unsigned long totalpages)
{
    long points;
    long adj;

    // 排除不可杀任务
    if (oom_unkillable_task(p))
        return LONG_MIN;

    // 获取有效的 mm
    p = find_lock_task_mm(p);
    if (!p)
        return LONG_MIN;

    // 排除特殊标记的进程
    adj = (long)p->signal->oom_score_adj;
    if (adj == OOM_SCORE_ADJ_MIN ||               // oom_score_adj = -1000（永不杀）
            mm_flags_test(MMF_OOM_SKIP, p->mm) || // 已标记跳过
            in_vfork(p)) {                         // vfork 中的进程
        task_unlock(p);
        return LONG_MIN;
    }

    // 基础分数 = RSS + Swap + 页表占用
    points = get_mm_rss_sum(p->mm)                 // 物理页（匿名+文件）
           + get_mm_counter_sum(p->mm, MM_SWAPENTS) // Swap 项数
           + mm_pgtables_bytes(p->mm) / PAGE_SIZE; // 页表大小

    task_unlock(p);

    // 将 oom_score_adj（-1000~+1000）归一化到 totalpages
    adj *= totalpages / 1000;
    points += adj;

    return points;
}
```

### 3.2 oom_unkillable_task — 不可杀任务

```c
// mm/oom_kill.c:146 — oom_unkillable_task
static bool oom_unkillable_task(struct task_struct *p)
{
    if (is_global_init(p))     // 不杀 init（PID 1）
        return true;
    if (p->flags & PF_KTHREAD) // 不杀内核线程
        return true;
    return false;
}
```

### 3.3 oom_evaluate_task — 评估单个进程

```c
// mm/oom_kill.c:281 — oom_evaluate_task
static int oom_evaluate_task(struct task_struct *task, void *arg)
{
    struct oom_control *oc = arg;
    long points;

    if (oom_unkillable_task(task))
        goto next;

    if (!is_memcg_oom(oc) && !oom_cpuset_eligible(task, oc))
        goto next;

    // 已 OOM victim，跳过（除非有 MMF_OOM_SKIP）
    if (!is_sysrq_oom(oc) && tsk_is_oom_victim(task)) {
        if (mm_flags_test(MMF_OOM_SKIP, task->signal->oom_mm))
            goto next;
        goto abort;  // 放弃扫描
    }

    // 有 PF_OOM_ORIGIN 标记的进程，优先杀
    if (oom_task_origin(task)) {
        points = LONG_MAX;
        goto select;
    }

    // 计算分数
    points = oom_badness(task, oc->totalpages);
    if (points == LONG_MIN || points < oc->chosen_points)
        goto next;

select:
    // 更新 victim
    if (oc->chosen)
        put_task_struct(oc->chosen);
    get_task_struct(task);
    oc->chosen = task;
    oc->chosen_points = points;

next:
    return 0;
abort:
    if (oc->chosen)
        put_task_struct(oc->chosen);
    oc->chosen = (void *)-1UL;
    return 1;  // 终止扫描
}
```

---

## 4. 选择进程（select_bad_process）

### 4.1 select_bad_process

```c
// mm/oom_kill.c:360 — select_bad_process
static void select_bad_process(struct oom_control *oc)
{
    oc->chosen_points = LONG_MIN;

    if (is_memcg_oom(oc))
        // memcg OOM：只扫描该 memcg 内的任务
        mem_cgroup_scan_tasks(oc->memcg, oom_evaluate_task, oc);
    else
        // 全局 OOM：扫描所有进程
        rcu_read_lock();
        for_each_process(p)
            if (oom_evaluate_task(p, oc))
                break;
        rcu_read_unlock();
}
```

---

## 5. 杀死进程（oom_kill_process）

### 5.1 oom_kill_process

```c
// mm/oom_kill.c:493 — oom_kill_process
void oom_kill_process(struct oom_control *oc, const char *message)
{
    struct task_struct *victim = oc->chosen;
    struct oom_reaper *reaper;

    // 找到有效进程
    victim = find_lock_task_mm(victim);
    if (!victim)
        return;  // 进程已退出

    // 标记为 OOM victim
    mark_oom_victim(victim);
    wake_oom_reaper(victim);

    // 发送 SIGKILL
    send_sig(SIGKILL, victim, 0);

    pr_warn("%s: oom_kill_process killed process %s (pid=%d, oom_score_adj=%ld)\n",
            message, victim->comm, victim->pid, victim->signal->oom_score_adj);

    task_unlock(victim);
    put_task_struct(victim);
}
```

---

## 6. OOM 杀死的保护机制

| 进程标记 | 效果 |
|----------|------|
| `PF_OOM_ORIGIN` | 一定被选中（分数=LONG_MAX）|
| `oom_score_adj = -1000`（`OOM_SCORE_ADJ_MIN`）| 永不杀死 |
| `oom_score_adj = +1000` | 分数翻倍，优先被杀 |
| `PF_KTHREAD` | 内核线程永不杀 |
| `is_global_init()` | init 进程（PID 1）永不杀 |
| `MMF_OOM_SKIP` | 已OOM victim的进程跳过 |

---

## 7. /proc 接口

```bash
# 调整 OOM 优先级（-1000 ~ +1000）
echo -1000 > /proc/$PID/oom_score_adj   # 永不杀
echo 0     > /proc/$PID/oom_score_adj   # 正常
echo 1000  > /proc/$PID/oom_score_adj   # 优先杀

# 只读分数
cat /proc/$PID/oom_score

# 全局 OOM 配置
cat /proc/sys/vm/overcommit_memory      # 内存过载策略
cat /proc/sys/vm/panic_on_oom           # OOM 时 panic（0=杀进程）
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/oom.h` | `struct oom_control`、`enum oom_constraint` |
| `mm/oom_kill.c` | `oom_badness`、`oom_evaluate_task`、`select_bad_process` |
| `mm/oom_kill.c` | `oom_unkillable_task`、`oom_kill_process`、`dump_tasks` |

---

## 9. 西游记类比

**OOM Killer** 就像"取经路上的天庭资源局"——

> 当大唐驿站的粮食（内存）耗尽时，土地神（OOM Killer）必须决定杀掉哪个妖怪据点（进程）来腾出粮食。算法很简单：看哪个据点占用的粮食最多（oom_badness = RSS + Swap + 页表）。如果某个据点被标记为"优先杀掉"（oom_score_adj=+1000），分数翻倍；如果标记了"永不杀"（-1000），分数直接归零。土地神先看看有没有用 OOM_ORIGIN 标记的（强制杀），没有就找吃得最多的那个，给驿站的粮食腾地方。被选中的据点会被立即驱逐（SIGKILL），然后天兵天将（OOM reaper）会来善后。

---

## 10. 关联文章

- **page_allocator**（article 17）：`__alloc_pages` 触发 OOM 的路径
- **memcg**（article 136）：cgroup 内存限制导致的 OOM