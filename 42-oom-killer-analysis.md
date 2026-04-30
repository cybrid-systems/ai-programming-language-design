# OOM Killer — 内存耗尽杀手深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/oom_kill.c` + `include/linux/oom.h`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**OOM Killer** 在系统内存耗尽时，选择一个进程**杀掉**（SIGKILL）以释放内存。

---

## 1. 触发条件

```c
// mm/oom_kill.c — out_of_memory
void out_of_memory(struct oom_context *oc)
{
    // 检查 watermark
    // 如果所有 zone 都低于WMARK_MIN，触发 OOM

    // 也可能由 userspace（ `/proc/sys/vm/overcommit_memory`）配置触发
}
```

---

## 2. 选择算法（oom_badness）

```c
// mm/oom_kill.c — oom_badness
long oom_badness(struct task_struct *p, struct oom_context *oc)
{
    long points;
    long adj;

    // 1. 基础分数 = 内存占用（RSS + Swap）
    points = get_mm_rss(p->mm) + get_mm_swap(p->mm);

    // 2. 调整因子
    adj = p->signal->oom_score_adj;  // -1000 ~ +1000

    // 3. 乘以调整
    if (adj != 0) {
        if (adj < 0)
            points += (points * adj) / -1000;  // adj=-1000 → 分数降为 0
        else
            points += (points * adj) / 1000;   // adj=+1000 → 分数翻倍
    }

    // 4. 排除特殊情况
    if (p->flags & PF_OOM_ORIGIN)
        return LONG_MAX;  // 标记为 OOM 目标，一定被杀
    if (p->flags & PF_NO_OOM)
        return 0;          // 永不杀
    if (p->mm && is_global_init(p->mm))
        return 0;          // 不杀 init

    return points;
}
```

---

## 3. oom_kill_process — 执行杀死

```c
// mm/oom_kill.c — oom_kill_process
void oom_kill_process(struct oom_context *oc, const char *message)
{
    struct task_struct *p;
    struct signal_struct *sig;
    long points;

    // 1. 遍历所有进程，找最高分
    for_each_process(p) {
        // 计算分数
        if (oom_badness(p, oc) > max_points) {
            max_points = oom_badness(p, oc);
            victim = p;
        }
    }

    // 2. 发送 SIGKILL
    send_sig(SIGKILL, victim, 0);

    // 3. 打印日志
    pr_warn("OOM killed process %s (pid %d) score %ld\n",
           victim->comm, victim->pid, max_points);
}
```

---

## 4. /proc 接口

```c
// /proc/<pid>/oom_score_adj  ← OOM 调整（-1000 ~ +1000）
// /proc/<pid>/oom_score      ← 当前分数（只读）

// 设置永不杀死：
echo -1000 > /proc/$PID/oom_score_adj

// 设置优先杀死：
echo 1000 > /proc/$PID/oom_score_adj
```

---

## 5. 完整文件索引

| 文件 | 函数 |
|------|------|
| `mm/oom_kill.c` | `out_of_memory`、`oom_badness`、`oom_kill_process` |
| `include/linux/oom.h` | `oom_score_adj` |