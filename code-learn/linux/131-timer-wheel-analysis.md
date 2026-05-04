# 131-timer-wheel — 读 kernel/time/timer.c

---

## 设计动机——超时定时器的优化

（`kernel/time/timer.c` 文件头注释 L65-125）

timer wheel 的设计前提：**绝大多数定时器在到期前被取消**。网络连接的超时、磁盘 I/O 的超时、锁的超时——90%+ 的定时器会在其回调被调用之前被 `del_timer` 或 `mod_timer` 移除。

这意味着 timer wheel 必须优先优化"添加和删除定时器"的性能，而不是"到期处理的精度"。无级联（no cascading）设计就是这个取舍的结果：传统定时器轮每 tick 需要将高 level 的定时器逐级下移到低 level，而 Linux 的 timer wheel 完全不做级联——每个定时器在其所属的 level 中直接到期。

```
无级联的代价：高 level 的定时器有到期误差
  Level 0: 1ms 粒度（HZ=1000）  → 精确到期
  Level 1: 8ms 粒度             → 最大 ±7ms 误差
  Level 2: 64ms 粒度            → 最大 ±63ms 误差
  ...
  Level 8: ~4h 粒度             → 最大 ±~4h 误差

如果定时器在到期前被取消（常见情况）：你获得了最快的 add/del
如果定时器确实到期了（异常情况）：精度损失可接受
```

---

## 数据结构

timer_base 是 per-CPU 的。每个 CPU 有 1 或 3 个 base（取决于 NOHZ 配置）：

```c
// L250
struct timer_base {
    raw_spinlock_t      lock;               // L251 — 保护整个 base
    struct timer_list   *running_timer;     // L252 — 当前正在执行回调的定时器
    unsigned long       clk;                // L257 — 当前 timer 时钟（jiffies + 1 offset）
    unsigned long       next_expiry;        // L258 — 下一次到期的 jiffies
    unsigned int        cpu;                // L259 — 所属 CPU
    bool                timers_pending;     // L262 — 有挂起的定时器
    DECLARE_BITMAP(pending_map, WHEEL_SIZE); // L263 — 各 bucket 非空位图
    struct hlist_head   vectors[WHEEL_SIZE]; // L264 — bucket 数组（512 个）
};

static DEFINE_PER_CPU(struct timer_base, timer_bases[NR_BASES]);  // L267
```

`pending_map` 是一个 512-bit 的位图，每个 bit 表示对应的 bucket 是否有定时器挂起。`collect_expired_timers` 通过 `find_next_bit` 快速找到非空 bucket，避免遍历。

---

## calc_wheel_index——到期时间到 bucket 的映射

（`kernel/time/timer.c` L541）

```c
static int calc_wheel_index(unsigned long expires, unsigned long clk)
{
    unsigned long delta = expires - clk;

    // delta 越小 → level 越低 → 精度越高
    if (delta < LVL_START(1))        idx = calc_index(expires, 0);
    else if (delta < LVL_START(2))   idx = calc_index(expires, 1);
    else if (delta < LVL_START(3))   idx = calc_index(expires, 2);
    // ... 共 LVL_DEPTH 层
    else if ((long)delta < 0)         // 已过期：放 level 0 当前 bucket
        idx = clk & LVL_MASK;
    else                               // 超过最大范围：截断
        idx = calc_index(expires, LVL_DEPTH - 1);
}
```

到期时间与当前时钟的差值决定放入哪个 level。差值越小，level 越低，到期精度越高。已经过期的定时器（`(long)delta < 0`）直接放入 level 0 的当前 bucket——它们在下一个 `__run_timers` 时立即到期。

---

## expire_timers——定时器执行

（`kernel/time/timer.c` L1766）

```c
static void expire_timers(struct timer_base *base, struct hlist_head *head)
{
    // 遍历 bucket 中的所有定时器
    while (!hlist_empty(head)) {
        struct timer_list *timer;
        timer = hlist_entry(head->first, struct timer_list, entry);

        // 从 bucket 中移除
        detach_timer(timer, true);

        // 如果是可延迟定时器（DEFERRABLE）且 CPU 在 idle，跳过
        if (timer->flags & TIMER_DEFERRABLE)
            continue;

        // 设置 running_timer（给 timer_delete_sync 使用）
        base->running_timer = timer;

        // 调用回调函数
        timer->function(timer);

        // 清理
        base->running_timer = NULL;
    }
}
```

`base->running_timer` 的存在是为了 `timer_delete_sync`：当其他 CPU 调用 `del_timer_sync` 删除定时器时，如果发现 `base->running_timer == timer`，说明定时器正在被回调中，需要等待它完成。

---

## 总结

Timer wheel 的优化假设是"大部分定时器不会到期"。无级联、分级粒度、位图加速查找、per-CPU base——这些设计的共同目标都是让 `add_timer` 和 `del_timer` 尽可能快。精度在级别之间递降（1ms → 8ms → 64ms → ... → 4h），但如果定时器到期了，误差不再重要。
