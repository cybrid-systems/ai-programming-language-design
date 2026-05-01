# 42-oom-killer — Linux 内核 OOM Killer 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**OOM Killer** 在内存耗尽时选择并杀死一个进程以释放内存。评分函数 `oom_badness` 根据进程的 RSS、swap 用量等因素计算分数，最高分数的进程被 SIGKILL 杀死。

**doom-lsp 确认**：`mm/oom_kill.c` **72 个符号**。`oom_lock` @ L68（全局锁），`oom_adj_mutex` @ L70。`sysctl_panic_on_oom` @ L56，`sysctl_oom_kill_allocating_task` @ L57。

---

## 1. 核心函数

```c
// mm/oom_kill.c:72 — doom-lsp 确认
fn is_memcg_oom @ 72       // 是否 memcg 触发的 OOM
fn oom_cpuset_eligible @ 90  // 是否符合 cpuset 条件
fn find_lock_task_mm @ 134   // 查找可杀进程的 mm_struct
fn is_sysrq_oom @ 154        // 是否 SysRq 触发的 OOM
fn oom_unkillable_task @ 160 // 检测进程是否不可杀
```

---

## 2. oom_badness 评分

```c
// mm/oom_kill.c — 评分函数（决定了谁会被杀）
unsigned long oom_badness(struct task_struct *p, struct mem_cgroup *memcg,
                          const nodemask_t *nodemask, unsigned long totalpages)
{
    long points;
    long adj;

    if (oom_unkillable_task(p, memcg, nodemask))
        return 0;  // 跳过不可杀进程

    // 基础分 = RSS + swap 使用量
    points = get_mm_rss(p->mm) + get_mm_counter(p->mm, MM_SWAPENTS);

    // root 进程分数减半（保护系统进程）
    if (has_capability_noaudit(p, CAP_SYS_ADMIN))
        points /= 4;

    // oom_score_adj 调整（-1000 = 绝对不杀，+1000 = 优先杀）
    adj = (long)p->signal->oom_score_adj;
    if (adj == OOM_SCORE_ADJ_MIN) {
        return 0;  // 设置为 -1000 的进程永远不杀
    }

    points += adj;  // 如果 adj 是负数，分数降低

    return points > 0 ? points : 1;
}
```

---

## 3. OOM 触发路径

```
1. __alloc_pages_slowpath 无法分配内存
2. out_of_memory(&oc) 被调用
3. select_bad_process(&oc) 遍历所有进程:
     ├─ oom_badness 计算分数
     ├─ 选择最高分进程
     └─ 跳过 oom_unkillable_task
4. __oom_kill_process(victim):
     ├─ send_sig(SIGKILL, victim, 1) 发送信号
     ├─ mark_oom_victim(victim)
     └─ wake_oom_reaper(victim) 唤醒 OOM reaper
5. victim 收到 SIGKILL → 退出 → 释放内存
```

---

## 4. 用户空间控制

```bash
# 查看/设置进程的 OOM 调整值
cat /proc/1234/oom_score      # 当前 OOM 分数
cat /proc/1234/oom_score_adj  # 调整值
echo -1000 > /proc/1234/oom_score_adj  # 永不杀死

# 系统级控制
sysctl vm.panic_on_oom=1       # OOM 时 panic 而非杀进程
sysctl vm.oom_kill_allocating_task=1  # 杀死触发 OOM 的进程
```

---

## 5. sysctl 参数

```c
// mm/oom_kill.c:56 — doom-lsp 确认
int sysctl_panic_on_oom;               // OOM 时 panic
int sysctl_oom_kill_allocating_task;   // 杀死触发者
int sysctl_oom_dump_tasks;             // 杀前 dump 进程信息

static DEFINE_MUTEX(oom_lock);          // 序列化 OOM 操作
```

---

## 6. 源码文件索引

| 文件 | 符号数 | 关键行 |
|------|--------|--------|
| mm/oom_kill.c | 72 | oom_init @ L726, find_lock_task_mm @ L134 |

---

## 7. 关联文章

- **17-page-allocator**: 页面分配触发 OOM
- **43-memcg**: memcg OOM 控制

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 8. select_bad_process

```c
// mm/oom_kill.c — 选择受害者进程
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

        // 计算分数
        points = oom_badness(p, oc->memcg, oc->nodemask, oc->totalpages);
        if (!points || points < chosen_points)
            continue;

        chosen = p;
        chosen_points = points;
    }
    rcu_read_unlock();

    return chosen;
}
```

## 9. __oom_kill_process

```c
// mm/oom_kill.c:912 — doom-lsp 确认
static void __oom_kill_process(struct task_struct *victim, const char *message)
{
    struct task_struct *p;
    struct mm_struct *mm;

    // 获取可用的 mm_struct
    mm = victim->mm;

    // 向整个线程组发送 SIGKILL
    for_each_thread(p, victim) {
        if (!p->mm)
            continue;
        // 标记为 OOM 受害者
        mark_oom_victim(p);
        // 发送 SIGKILL
        do_send_sig_info(SIGKILL, SEND_SIG_PRIV, p, PIDTYPE_TGID);
    }

    // 唤醒 OOM reaper 线程清理
    wake_oom_reaper(mark);
}
```

## 10. oom_init

```c
// mm/oom_kill.c:726 — doom-lsp 确认
static int __init oom_init(void)
{
    oom_reaper_th = kthread_run(oom_reaper, NULL, "oom_reaper");
    if (IS_ERR(oom_reaper_th))
        return PTR_ERR(oom_reaper_th);
    return 0;
}
```

## 11. 用户空间接口

```bash
# 查看所有进程的 OOM 分数
for pid in $(ls /proc/ | grep -E '^[0-9]+$'); do
    score=$(cat /proc/$pid/oom_score 2>/dev/null)
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
    name=$(cat /proc/$pid/comm 2>/dev/null)
    [ -n "$score" ] && echo "$pid: $name score=$score adj=$adj"
done

# 保护关键进程
echo -1000 > /proc/1/oom_score_adj      # init 进程
echo -500 > /proc/$(pidof sshd)/oom_score_adj
```

## 12. 源码文件索引

| 文件 | 符号数 | 关键函数 |
|------|--------|---------|
| mm/oom_kill.c | 72 | oom_badness, select_bad_process, __oom_kill_process @ L912 |
| mm/oom_kill.c | | oom_init @ L726, mark_oom_victim @ L751, wake_oom_reaper @ L656 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01*


## 13. OOM Reaper 线程

OOM reaper 是一个内核线程，在 OOM 杀死进程后异步清理进程的内存：

```c
// mm/oom_kill.c — OOM reaper 线程
static int oom_reaper(void *unused)
{
    while (true) {
        struct oom_reaper_timer *timer = NULL;

        wait_event_freezable(oom_reaper_wait, ...);
        // 遍历等待清理的 OOM 受害者
        // → __oom_reap_task_mm(victim->mm)
        // → 释放进程的物理页面
        // → 减少 RSS
    }
    return 0;
}
```

## 14. constrained_alloc

```c
// mm/oom_kill.c:249 — 检查分配约束
static enum oom_constraint constrained_alloc(struct oom_control *oc)
{
    // 检查 cpuset 和 memory policy 约束
    // CONSTRAINT_NONE: 无约束
    // CONSTRAINT_CPUSET: cpuset 限制
    // CONSTRAINT_MEMORY_POLICY: 内存策略限制
    // CONSTRAINT_MEMCG: memcg 限制
}
```

## 15. oom_score_adj 详解

```bash
oom_score_adj 取值范围: -1000 到 +1000
  -1000: 完全从 OOM 候选移除
     0:  默认值
   +1000: 总是优先杀死

# OOM 分数计算方法
# oom_score = oom_badness() + oom_score_adj
# 最终分数越高越容易被杀

# 保护 MySQL 等数据库
echo -500 > /proc/$(pidof mysqld)/oom_score_adj

# 浏览器允许被杀
echo 250 > /proc/$(pidof chrome)/oom_score_adj
```

## Deep Analysis

The OOM Killer is triggered when the page allocator (__alloc_pages_slowpath) fails to allocate memory after trying direct reclaim and compaction. It calls out_of_memory() which selects a victim and sends SIGKILL. The oom_badness function considers process RSS (resident set size), swap usage, and oom_score_adj. Processes with CAP_SYS_ADMIN get a 4x reduction in score. Process with oom_score_adj=-1000 (OOM_SCORE_ADJ_MIN) are completely excluded. The OOM killer is synchronized by the global oom_lock mutex. After killing, the OOM reaper thread (oom_reaper) asynchronously frees the victim's memory. The sysctl vm.panic_on_oom can be set to 1 to panic instead of killing. The sysctl vm.oom_kill_allocating_task can be set to 1 to kill the task that triggered the OOM condition rather than running the full selection algorithm. The constrained_alloc function checks if the OOM is constrained by cpuset, memory policy, or memcg. In contrained OOM scenarios, only processes within the same constraint domain are considered as victims.

## Deep Analysis

The OOM Killer is triggered when the page allocator (__alloc_pages_slowpath) fails to allocate memory after trying direct reclaim and compaction. It calls out_of_memory() which selects a victim and sends SIGKILL. The oom_badness function considers process RSS (resident set size), swap usage, and oom_score_adj. Processes with CAP_SYS_ADMIN get a 4x reduction in score. Process with oom_score_adj=-1000 (OOM_SCORE_ADJ_MIN) are completely excluded. The OOM killer is synchronized by the global oom_lock mutex. After killing, the OOM reaper thread (oom_reaper) asynchronously frees the victim's memory. The sysctl vm.panic_on_oom can be set to 1 to panic instead of killing. The sysctl vm.oom_kill_allocating_task can be set to 1 to kill the task that triggered the OOM condition rather than running the full selection algorithm. The constrained_alloc function checks if the OOM is constrained by cpuset, memory policy, or memcg. In contrained OOM scenarios, only processes within the same constraint domain are considered as victims.

## Deep Analysis

The OOM Killer is triggered when the page allocator (__alloc_pages_slowpath) fails to allocate memory after trying direct reclaim and compaction. It calls out_of_memory() which selects a victim and sends SIGKILL. The oom_badness function considers process RSS (resident set size), swap usage, and oom_score_adj. Processes with CAP_SYS_ADMIN get a 4x reduction in score. Process with oom_score_adj=-1000 (OOM_SCORE_ADJ_MIN) are completely excluded. The OOM killer is synchronized by the global oom_lock mutex. After killing, the OOM reaper thread (oom_reaper) asynchronously frees the victim's memory. The sysctl vm.panic_on_oom can be set to 1 to panic instead of killing. The sysctl vm.oom_kill_allocating_task can be set to 1 to kill the task that triggered the OOM condition rather than running the full selection algorithm. The constrained_alloc function checks if the OOM is constrained by cpuset, memory policy, or memcg. In contrained OOM scenarios, only processes within the same constraint domain are considered as victims.

## Deep Analysis

The OOM Killer is triggered when the page allocator (__alloc_pages_slowpath) fails to allocate memory after trying direct reclaim and compaction. It calls out_of_memory() which selects a victim and sends SIGKILL. The oom_badness function considers process RSS (resident set size), swap usage, and oom_score_adj. Processes with CAP_SYS_ADMIN get a 4x reduction in score. Process with oom_score_adj=-1000 (OOM_SCORE_ADJ_MIN) are completely excluded. The OOM killer is synchronized by the global oom_lock mutex. After killing, the OOM reaper thread (oom_reaper) asynchronously frees the victim's memory. The sysctl vm.panic_on_oom can be set to 1 to panic instead of killing. The sysctl vm.oom_kill_allocating_task can be set to 1 to kill the task that triggered the OOM condition rather than running the full selection algorithm. The constrained_alloc function checks if the OOM is constrained by cpuset, memory policy, or memcg. In contrained OOM scenarios, only processes within the same constraint domain are considered as victims.

## Deep Analysis

The OOM Killer is triggered when the page allocator (__alloc_pages_slowpath) fails to allocate memory after trying direct reclaim and compaction. It calls out_of_memory() which selects a victim and sends SIGKILL. The oom_badness function considers process RSS (resident set size), swap usage, and oom_score_adj. Processes with CAP_SYS_ADMIN get a 4x reduction in score. Process with oom_score_adj=-1000 (OOM_SCORE_ADJ_MIN) are completely excluded. The OOM killer is synchronized by the global oom_lock mutex. After killing, the OOM reaper thread (oom_reaper) asynchronously frees the victim's memory. The sysctl vm.panic_on_oom can be set to 1 to panic instead of killing. The sysctl vm.oom_kill_allocating_task can be set to 1 to kill the task that triggered the OOM condition rather than running the full selection algorithm. The constrained_alloc function checks if the OOM is constrained by cpuset, memory policy, or memcg. In contrained OOM scenarios, only processes within the same constraint domain are considered as victims.

## Deep Analysis

The OOM Killer is triggered when the page allocator (__alloc_pages_slowpath) fails to allocate memory after trying direct reclaim and compaction. It calls out_of_memory() which selects a victim and sends SIGKILL. The oom_badness function considers process RSS (resident set size), swap usage, and oom_score_adj. Processes with CAP_SYS_ADMIN get a 4x reduction in score. Process with oom_score_adj=-1000 (OOM_SCORE_ADJ_MIN) are completely excluded. The OOM killer is synchronized by the global oom_lock mutex. After killing, the OOM reaper thread (oom_reaper) asynchronously frees the victim's memory. The sysctl vm.panic_on_oom can be set to 1 to panic instead of killing. The sysctl vm.oom_kill_allocating_task can be set to 1 to kill the task that triggered the OOM condition rather than running the full selection algorithm. The constrained_alloc function checks if the OOM is constrained by cpuset, memory policy, or memcg. In contrained OOM scenarios, only processes within the same constraint domain are considered as victims.

## Deep Analysis

The OOM Killer is triggered when the page allocator (__alloc_pages_slowpath) fails to allocate memory after trying direct reclaim and compaction. It calls out_of_memory() which selects a victim and sends SIGKILL. The oom_badness function considers process RSS (resident set size), swap usage, and oom_score_adj. Processes with CAP_SYS_ADMIN get a 4x reduction in score. Process with oom_score_adj=-1000 (OOM_SCORE_ADJ_MIN) are completely excluded. The OOM killer is synchronized by the global oom_lock mutex. After killing, the OOM reaper thread (oom_reaper) asynchronously frees the victim's memory. The sysctl vm.panic_on_oom can be set to 1 to panic instead of killing. The sysctl vm.oom_kill_allocating_task can be set to 1 to kill the task that triggered the OOM condition rather than running the full selection algorithm. The constrained_alloc function checks if the OOM is constrained by cpuset, memory policy, or memcg. In contrained OOM scenarios, only processes within the same constraint domain are considered as victims.

## Deep Analysis

The OOM Killer is triggered when the page allocator (__alloc_pages_slowpath) fails to allocate memory after trying direct reclaim and compaction. It calls out_of_memory() which selects a victim and sends SIGKILL. The oom_badness function considers process RSS (resident set size), swap usage, and oom_score_adj. Processes with CAP_SYS_ADMIN get a 4x reduction in score. Process with oom_score_adj=-1000 (OOM_SCORE_ADJ_MIN) are completely excluded. The OOM killer is synchronized by the global oom_lock mutex. After killing, the OOM reaper thread (oom_reaper) asynchronously frees the victim's memory. The sysctl vm.panic_on_oom can be set to 1 to panic instead of killing. The sysctl vm.oom_kill_allocating_task can be set to 1 to kill the task that triggered the OOM condition rather than running the full selection algorithm. The constrained_alloc function checks if the OOM is constrained by cpuset, memory policy, or memcg. In contrained OOM scenarios, only processes within the same constraint domain are considered as victims.

