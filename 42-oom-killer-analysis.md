# Linux Kernel OOM Killer 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/oom_kill.c`）
> 工具： doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 OOM Killer？

**OOM Killer（Out-Of-Memory Killer）** 是内核在内存耗尽时的**最后防线**——选择并杀死一个"最佳"进程，释放其占用的内存。

**触发条件**：
- `alloc_pages()` 无法分配内存（所有水位线都耗尽）
- `out_of_memory()` 被调用

---

## 1. oom_score — 进程评分

```c
// mm/oom_kill.c — oom_evaluate_task
static int oom_evaluate_task(struct task_struct *task, void *arg)
{
    struct oom_control *oc = arg;
    long points;

    // 计算 OOM 评分
    points = oom_score(task, oc->scan_flags);

    if (points > oc->chosen_points) {
        // 比当前最优更好
        if (oc->chosen)
            put_task_struct(oc->chosen);
        get_task_struct(task);
        oc->chosen = task;
        oc->chosen_points = points;
    }

    return 0;
}

// mm/oom_kill.c — oom_score
long oom_score(struct task_struct *p, unsigned int flags)
{
    long points;

    // 基础分 = 占用内存（RSS / 1024）
    points = get_mm_rss(p->mm) + get_mm_pgd_size(p->mm) / PAGE_SIZE;

    // 乘以 OOM_ADJ（-17 ~ +1000，可通过 /proc/pid/oom_score_adj 调整）
    points *= (1000 - p->signal->oom_score_adj) / 1000.0;

    // nice 值加成（nice > 0 的进程更可能被杀）
    if (has_capability_noaudit(p, CAP_SYS_ADMIN))
        points /= 100;  // CAP_SYS_ADMIN 进程大幅降低

    return points;
}
```

---

## 2. out_of_memory — OOM 入口

```c
// mm/oom_kill.c:1103 — out_of_memory
bool out_of_memory(struct oom_control *oc)
{
    // 1. 检查是否是 memcg OOM
    if (is_memcg_oom(oc))
        memcg_oom_synchronize(oc);

    // 2. 选择要杀死的进程
    select_bad_process(oc);

    // 3. 没找到可杀的进程
    if (!oc->chosen || oc->chosen == (void *)-1UL)
        return false;

    // 4. 杀死进程
    oom_kill_process(oc, "Memory cgroup out of memory");

    return true;
}
```

---

## 3. oom_kill_process — 杀进程

```c
// mm/oom_kill.c — oom_kill_process
static void oom_kill_process(struct oom_control *oc, const char *message)
{
    struct task_struct *victim = oc->chosen;
    struct task_struct *p;
    int tasks_to_kill = 1;  // 默认只杀一个

    // 1. 如果 victim 是 subreaper，杀所有子进程
    if (task_will_free_mem(victim))
        dump_tasks(oc->memcg, oc->nodemask);

    // 2. 发送 SIGKILL
    send_sig(SIGKILL, victim, 0);

    // 3. 通知内存 cgroup
    memcg = get_mem_cgroup_from_mm(victim->mm);
    memcg_oom_reclaim(oc->memcg, 0);  // 尝试先回收

    // 4. 记录日志
    dump_header(oc, victim);
    pr_err("%s: Killed process %d (%s) total-vm:%lukB, anon-rss:%lukB, file-rss:%lukB\n",
        message, task_pid_nr(victim), victim->comm,
        oc->chosen_points);
}
```

---

## 4. oom_score_adj

```c
// /proc/pid/oom_score_adj 范围：
//   -1000：完全免疫（永不被杀）
//   -17 ~ +1000：评分加成
//   +1000：最大评分（几乎必杀）

// 用户空间操作：
echo -1000 > /proc/$$/oom_score_adj  // 保护当前 shell
echo -1000 > /proc/$(pidof mysqld)/oom_score_adj  // 保护数据库

// sysctl：
vm.oom_score_adj = 0  // 全局默认
```

---

## 5. 完整流程

```
内存耗尽 → alloc_pages 失败 → out_of_memory()
  → is_memcg_oom() ? → memcg OOM
  → select_bad_process() → 遍历所有进程
      → oom_score(task) = RSS * oom_score_adj / 1000
      → 选择分数最高的进程
  → oom_kill_process()
      → send_sig(SIGKILL)
      → 进程退出，内存被释放
```

---

## 6. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| RSS 作为评分基础 | 占用内存越多，越应该为内存压力负责 |
| oom_score_adj 可调 | 允许用户保护关键进程（数据库等）|
| CAP_SYS_ADMIN 降低 | 有管理员权限的进程不应轻易被杀 |
| 只杀一个进程 | 避免过度杀伤 |
| task_will_free_mem | 如果子进程会释放内存，先不杀父进程 |

---

## 7. 参考

| 文件 | 内容 |
|------|------|
| `mm/oom_kill.c` | `out_of_memory`、`select_bad_process`、`oom_kill_process`、`oom_score` |
| `kernel/signal.c` | `send_sig`、`SIGKILL` |
