# Linux Kernel memcg (Memory Cgroup) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/memcontrol.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 memcg？

**memcg（Memory Cgroup）** 是 cgroup v2 中**内存资源控制**子系统，允许对进程组的内存使用量施加限制。

**核心能力**：
- 设置内存上限（memory.max）
- 内存低水位回收（memory.high）
- 匿名页/文件页分开统计
- 层次化记账（子 cgroup 继承父 cgroup 的限制）

---

## 1. 核心数据结构

```c
// mm/memcontrol.c — mem_cgroup
struct mem_cgroup {
    struct cgroup_subsys_state css;  // cgroup 基类

    /* 层次结构 */
    struct mem_cgroup *parent;       // 父 cgroup
    struct list_head siblings;       // 兄弟链表
    struct list_head children;      // 子 cgroup

    /* 内存限制（来自 memory.max 等）*/
    unsigned long memory_max;        // 硬限制（byte）
    unsigned long memory_high;       // 软限制（触发异步回收）
    unsigned long swap_max;         // swap 上限

    /* 统计计数器 */
    atomic_long_t memory_current;   // 当前内存使用
    atomic_long_t memory_stat[NR_MEMCG_STAT];  // 详细统计

    /* 内存使用量 */
    struct page_counter memory;      // 内存页计数器
    struct page_counter swap;       // swap 计数器
    struct page_counter memsw;      // memory+swap 总和

    /* LRU 链表（用于回收）*/
    struct list_head lru_gen_lists;  // LRU 代际链表

    /* OOM 处理 */
    struct wait_queue_head oom_waitq;
    atomic_int oom_psi_flag;
};
```

---

## 2. 内存限制检查

```c
// mm/memcontrol.c — try_charge
bool try_charge(struct mem_cgroup *memcg, gfp_t gfp_mask, unsigned int nr_pages)
{
    // 1. 检查 memory.current 是否超过 memory.max
    if (atomic_long_read(&memcg->memory_current) >= memcg->memory_max) {
        // 超过硬限制，触发回收
        ret = memcg_reclaim(memcg, gfp_mask, nr_pages);
        if (ret != MEMCG_RECLAIM_SOME)
            goto force;  // 回收失败
    }

    // 2. 如果超过 memory.high，触发异步回收
    if (atomic_long_read(&memcg->memory_current) >= memcg->memory_high) {
        memcg_schedule_high_work();  // 触发 memcg kworker 异步回收
    }

    // 3. 增加引用计数
    page_counter_charge(&memcg->memory, nr_pages);
    return true;

force:
    // 4. 硬限制触发 OOM
    memcg_oom(memcg, gfp_mask);
    return false;
}
```

---

## 3. 层次化回收

```c
// mm/memcontrol.c — memcg_reclaim
static int memcg_reclaim(struct mem_cgroup *memcg, gfp_t gfp_mask, unsigned long nr_pages)
{
    // 1. 从 LRU 回收
    //    遍历 memcg 的 lru_gen_lists
    //    回收 inactive anon / inactive file / active anon / active file

    // 2. 递归向上直到根
    do {
        lru_gen_shrink_list(memcg, nr_pages);
        memcg = memcg->parent;
    } while (memcg && nr_pages > 0);

    return ret;
}
```

---

## 4. PSI (Pressure Stall Information)

```c
// PSI 追踪内存压力
// /proc/pressure/io、/proc/pressure/memory
// 报告：
//   some：至少一个任务在等待内存
//   full：所有任务都在等待内存
```

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `mm/memcontrol.c` | `mem_cgroup`、`try_charge`、`memcg_reclaim`、`page_counter_charge` |
| `mm/memcontrol.h` | `struct mem_cgroup`、`memory_cgroup_subsys` |
