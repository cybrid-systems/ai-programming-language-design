# RCU 同步机制深度分析

> 内核版本: Linux 7.0-rc1 (tree RCU)
> 源码: /home/dev/code/linux/kernel/rcu/tree.c (4931行) | /home/dev/code/linux/include/linux/rcupdate.h (1184行) | /home/dev/code/linux/kernel/rcu/tree.h (547行)

---

## 一、RCU 核心概念：为什么读端不需要锁？

### 1.1 RCU 的基本假设

RCU (Read-Copy-Update) 的存在理由是：**在读多写少的数据结构中，读端开销可以做到接近零**——不需要原子操作、不需要内存屏障、不需要锁，只需要禁抢占。

关键洞察来自一个简单的问题：**"谁来删除数据？"**

```c
// 传统锁方案：读写都需要竞争锁
read() { lock(); /* 读 */ unlock(); }
update() { lock(); /* 改 */ unlock(); }

// RCU 方案：读端无锁，写端需要等
read() { rcu_read_lock(); /* 读 */ rcu_read_unlock(); }
update() {
    p =删除节点;
    synchronize_rcu();  // 等待所有正在进行的读结束
    kfree(p);
}
```

### 1.2 `rcu_read_lock()` 的本质

```c
// PREEMPT_RCU 配置下 (kernel/rcu/tree.c)
void __rcu_read_lock(void)
{
    preempt_disable();           // 禁止抢占 = 禁止进程切换
    current->rcu_read_lock_nesting++;  // 记录嵌套深度（用于锁dep）
}

// 非 PREEMPT_RCU 配置下（PREEMPT_NONE 或 PREEMPT_VOLUNTARY）
static inline void __rcu_read_lock(void)
{
    preempt_disable();  // 同样禁抢占，但不计嵌套深度
}
```

**`rcu_read_lock()` 本质上是一个"禁抢占"操作**，它保证：在读临界区内，当前线程不会被人抢走，因此不会进入任何等待状态。

### 1.3 `rcu_dereference()` 的本质

```c
// include/linux/rcupdate.h
#define rcu_dereference_raw(p) __rcu_dereference_raw(p, __UNIQUE_ID(rcu))
#define __rcu_dereference_raw(p, local) \
({ \
    /* Dependency order vs. p above. */ \
    typeof(p) local = READ_ONCE(p); \
    ((typeof(*p) __force __kernel *)(local)); \
})
```

`rcu_dereference()` 的核心语义是**编译器屏障 + 内存顺序保证**：
- 防止编译器将 `p` 的读取重排到它前面
- 配合 `smp_store_release()` / `smp_load_acquire` 等配套使用，提供 GCC don't-reorder 语义

它本身不需要 MMIO 屏障（`smp_mb()`），但通过 `dependency ordering` 确保：
- **发布者**用 `rcu_assign_pointer()` 写入 → 发布前的所有初始化操作都对读者可见
- **消费者**用 `rcu_dereference()` 读取 → 读取到的指针指向的内容是完整的

```c
// 发布者
struct foo *gp = NULL;
void update() {
    struct foo *new = kmalloc(sizeof(*new));
    new->a = 42;
    rcu_assign_pointer(gp, new);  // 语义：写入 + 内存屏障
}

// 消费者
void read() {
    struct foo *p = rcu_dereference(gp);  // 语义：读取 + compiler barrier
    if (p)
        printk("%d", p->a);  // 保证看到 new->a = 42
}
```

### 1.4 宽限期（Grace Period）的本质

RCU 的核心问题：**如何安全地释放被删除的节点？**

答案：**等待所有可能的读者都退出读临界区**。这个等待期就叫 Grace Period (GP)。

```
时间 ──────────────────────────────────────────────────────►

线程A:  read() ────────────────────[ GP开始 ]─────────────────────
线程B:  read()   ────────────────[ GP开始 ]───────────────────────
线程C:  update() 删除节点[X]       [ GP开始 ]
                                          [ GP结束，等待X可以释放 ]
                                                          [ X被free ]
```

**何时可以安全释放？** 当且仅当所有 `rcu_read_lock()` 开始时间早于删除操作开始时间的读端都已结束。

这需要满足两个条件：
1. 所有 CPU 都至少发生了一次上下文切换（进入/退出内核 → 报告 QS）
2. 或者所有在 GP 开始前就已经在临界区内的读者都已经退出

### 1.5 `synchronize_rcu()` 的完整等待路径

```c
// kernel/rcu/tree.c
void synchronize_rcu(void)
{
    // 1. 注册到 GP 等待链表
    // 2. 通知 GP kthread 需要启动新的 GP
    // 3. 等待 GP 完成的通知
    // 实际实现在 rcu_sr_normal_gp_* 系列函数中
}
```

---

## 二、rcu_head 结构与 call_rcu 完整路径

### 2.1 rcu_head 的嵌入方式

`rcu_head` 是 RCU 回调机制的核心数据结构：

```c
// 使用方式：嵌入到用户自己的数据结构中
struct my_data {
    int value;
    struct rcu_head rcu;  // 嵌入在末尾
};

// 用户分配时
struct my_data *p = kmalloc(sizeof(*p), GFP_KERNEL);
init_rcu_head(&p->rcu);   // 可选：debug objects 追踪

// 调用方式
call_rcu(&p->rcu, my_callback);

// 回调函数签名
void my_callback(struct rcu_head *head)
{
    struct my_data *p = container_of(head, struct my_data, rcu);
    kfree(p);
}
```

**`container_of` 的魔法**（include/linux/compiler.h）：
```c
#define container_of(ptr, type, member) \
    ((type *)((char *)(ptr) - offsetof(type, member)))
```

`rcu_head` 只需要一个 `func` 指针指向回调，不需要知道对象本身——通过 `container_of` 反推即可。

### 2.2 call_rcu() → __call_rcu_common() 完整路径

```
call_rcu(head, func)
  └── __call_rcu_common(head, func, lazy_in=enable_rcu_lazy)
        ├── debug_rcu_head_queue(head)         // 检查双重入队
        ├── rcu_segcblist_enqueue(&rdp->cblist, head)
        │     // 将 rcu_head 加入当前 CPU 的分段回调链表
        │     // 链表按等待的 GP 编号分段（见下节）
        │
        ├── call_rcu_core(rdp, head, func, flags)
        │     ├── rcutree_enqueue(rdp, head, func)
        │     │     // 确保 callback 进入 cblist
        │     │
        │     └── if (!rcu_is_watching())
        │           invoke_rcu_core()
        │     // 如果 CPU 处于 extended quiescent state
        │     //（如 idle、offline）则立即触发 RCU core
        │     //
        │     └── if (cb 数量过多) {
        │           // 超过 qhimark，尝试触发 GP
        │           if (!rcu_gp_in_progress())
        │               rcu_accelerate_cbs_unlocked()
        │           else
        │               rcu_force_quiescent_state()
        │         }
        │
        └── [ 立即返回，不等待 GP ]
```

**batch 机制**：Linux RCU 不会为每个 `call_rcu()` 单独触发一个 GP。多个 `call_rcu()` 汇聚在同一 CPU 的 `cblist` 中，由 GP kthread 统一处理。回调按其对应的 GP 编号分到不同段：

```
rcu_segcblist 分段结构（include/linux/rcu_segcblist.h）:

[head] ───► [ DONE callbacks (GP已结束，等待调用) ]
  ↑
  tails[RCU_DONE_TAIL] ──────────────────────────

              [ WAIT callbacks (等待当前GP) ]
              gp_seq[X] == 当前GP号
  tails[RCU_WAIT_TAIL] ───────────────────────────

                          [ NEXT_READY callbacks (下一个GP就绪) ]
                          gp_seq[X+1] == 下一个GP号
  tails[RCU_NEXT_READY_TAIL] ───────────────────

                                    [ NEXT callbacks (更新的回调) ]
  tails[RCU_NEXT_TAIL] ──────────────────────────────────────────
```

`rcu_segcblist_advance()` 按 GP 编号推进回调段：`DONE→WAIT→NEXT_READY→NEXT` 的顺序逐段前移。GP 结束时，`DONE` 段的回调全部被调用（通过 `rcu_invoke_callbacks()`）。

---

## 三、Grace Period 检测机制

### 3.1 GP 状态机（rcu_gp_init → rcu_gp_advance → rcu_gp_cleanup）

Linux 7.0 的 tree RCU GP 由 `rcu_gp_kthread` 驱动，状态机如下：

```
rcu_gp_kthread 主循环:

  ┌─────────────────────────────────────────────────────┐
  │  RCU_GP_WAIT_GPS ←── swait_event_idle_exclusive()   │
  │          │                                          │
  │          ▼ (RCU_GP_FLAG_INIT 被 set)               │
  │  ┌───────────────────────┐                         │
  │  │   rcu_gp_init()        │  RCU_GP_INIT            │
  │  │   1. rcu_seq_start()   │  RCU_GP_ONOFF           │
  │  │   2. 扫描叶子 rcu_node │  (CPU hotplug 处理)     │
  │  │   3. 设置 qsmaskinit   │                        │
  │  └───────┬───────────────┘                         │
  │          │ (init 成功)                             │
  │          ▼                                         │
  │  ┌───────────────────────┐                         │
  │  │   rcu_gp_fqs_loop()    │  RCU_GP_WAIT_FQS        │
  │  │   force_qs_rnp()       │  RCU_GP_DOING_FQS       │
  │  │   等待所有 CPU 报告 QS  │                        │
  │  └───────┬───────────────┘                         │
  │          │ (qsmask == 0 且无 blocked readers)       │
  │          ▼                                         │
  │  ┌───────────────────────┐                         │
  │  │   rcu_gp_cleanup()      │  RCU_GP_CLEANUP         │
  │  │   1. 推进所有 rcu_node  │  RCU_GP_CLEANED         │
  │  │   2. 调用 DONE callbacks│                        │
  │  │   3. 启动下一个 GP      │                        │
  │  └───────┬───────────────┘                         │
  │          │                                         │
  └──────────┴─────────────────────────────────────────
          (回到 RCU_GP_WAIT_GPS)
```

### 3.2 rcu_gp_init() 三阶段（内核源码解析）

```c
// kernel/rcu/tree.c:1804
static noinline_for_stack bool rcu_gp_init(void)
{
    // 阶段1: rcu_sr_normal_gp_init()
    //   将 rcu_state.gp_seq 递增（实际是创建一个新的"轮次"编号）
    //   设置 start_new_poll（当 dummy node 不够时）

    // 阶段2: rcu_seq_start(&rcu_state.gp_seq)
    //   将 gp_seq 的低2位设为 RCU_SEQ_STATE_MASK（表示 GP 已开始）
    //   RCU_SEQ_CTR_SHIFT = 2，所以低2位用于状态，高30/62位是计数

    // 阶段3: 遍历叶子 rcu_node
    //   rcu_for_each_leaf_node(rnp) {
    //       // 每个叶子节点对应一组 CPU
    //       // 设置 rnp->qsmaskinit = rnp->qsmaskinitnext
    //       // 如果 CPU 刚从 offline 变 online:
    //       //   rcu_init_new_rnp() - 初始化该节点的 qsmask
    //       // 如果 CPU 全 offline:
    //       //   rcu_cleanup_dead_rnp() - 清理
    //   }
    //   然后向上传播（propagate）qsmaskinit 的变化到根节点
}
```

**关键数据结构**：每个 `rcu_node` 有 `qsmask` 和 `qsmaskinit`：
- `qsmaskinitnext`: 下次 GP 应该等待的 CPU 位图（CPU online 时设置）
- `qsmaskinit`: 当前 GP 开始时复制的 `qsmaskinitnext`
- `qsmask`: 当前还在等待的 CPU 位图（每报告一个 QS 清一位）

### 3.3 Quiescent State (QS) 检测机制

**什么是 quiescent state？** 对于 RCU 读者，quiescent state 是"不再是 RCU 读者"的状态——即退出 `rcu_read_unlock()`。

**正常路径（non-nohz_full）**：
```c
// kernel/rcu/tree.c:2443
static void rcu_report_qs_rdp(struct rcu_data *rdp)
{
    // 在 scheduler clock interrupt 时调用
    // kernel/rcu/tree.c:1994:  rcu_qs(); rcu_report_qs_rdp(this_cpu_ptr(&rcu_data));
    // kernel/sched/core.c: 触发点 -> rcu_sched_clock_irq()

    // 流程:
    // rcu_qs() {
    //     // 设置 rdp->cpu_no_qs.b.norm = false（表示已报告）
    //     __this_cpu_write(rcu_data.cpu_no_qs.b.norm, false);
    // }
    // rcu_report_qs_rdp(rdp) {
    //     mask = rdp->grpmask;
    //     rcu_report_qs_rnp(mask, rnp=rdp->mynode, rnp->gp_seq, flags)
    //         // 持有 leaf rcu_node 的锁
    //         // rnp->qsmask &= ~mask（清除该 CPU 的 bit）
    //         // 如果 qsmask 变为 0，向上传播给 parent
    // }
}
```

**抢占路径（读者在临界区中被抢走）**：
```c
// schedule() → finish_task_switch()
finish_task_switch()
  -> rcu_tasks_qs(current)     // 检查 current->rcu_read_unlock_special.b.norm
  // 只有在 rcu_read_unlock 中才会设置这个 flag
  // 当 CPU 从内核态返回用户态时，finish_task_switch 也检查是否有 pending QS
```

### 3.4 NO_HZ_FULL 模式下的 QS 报告

**问题**：nohz_full CPU 没有调度时钟中断（tick），所以 `rcu_sched_clock_irq()` 不会调用，QS 无法报告。

**解决方案**：
```c
// kernel/rcu/tree.c:640-728
// rcu_urgent_qs() 被调度时钟中断、新任务进入、内核 API 等触发

static void rcu_urgent_qs(void)
{
    // 设置 rdp->rcu_urgent_qs = true
    // 通知目标 CPU 下次进入内核时报告 QS

    if (tick_nohz_full_cpu(rdp->cpu) &&
        !READ_ONCE(rdp->rcu_forced_tick)) {
        // 对 nohz_full CPU，强制触发一次 tick
        WRITE_ONCE(rdp->rcu_forced_tick, true);
        tick_dep_set_cpu(rdp->cpu, TICK_DEP_BIT_RCU);
    }
}

// 当 nohz_full CPU 接收到强制 tick 时:
rcu_sched_clock_irq()
  -> rcu_disable_urgency_upon_qs()
  -> if (tick_nohz_full_cpu(rdp->cpu) && rdp->rcu_forced_tick) {
         tick_dep_clear_cpu(rdp->cpu, TICK_DEP_BIT_RCU);
         rdp->rcu_forced_tick = false;
     }
  -> rcu_report_qs_rdp()
```

**流程图**:

```
nohz_full CPU (用户态长时间运行)
    │
    │  外部事件触发 rcu_urgent_qs()：
    │  - 另一个 CPU 调用 synchronize_rcu()
    │  - 本 CPU 的 tick 驱动重新使能（用户请求）
    │
    ▼
tick_dep_set_cpu(cpu, TICK_DEP_BIT_RCU)
    │
    │  强制唤醒该 CPU 的 tick（即使在 userspace）
    │
    ▼
 tick 中断发生
    │
    ▼
rcu_sched_clock_irq(user=0)
    │
    ▼
rcu_disable_urgency_upon_qs() + rcu_report_qs_rdp()
    │
    ▼
qsmask[leaf] &= ~cpu_mask  → 向上传播
```

**rcu_gp_fqs() 函数**：当 `force_qs_rnp()` 扫描到 nohz_full CPU 没有报告 QS 时，会主动触发 IPI（如果需要）：

```c
// kernel/rcu/tree.c:2112
static void rcu_gp_fqs(bool first_gp_fqs)
{
    force_qs_rnp(rcu_watching_snap_save);   // 第一轮：记录快照
    force_qs_rnp(rcu_watching_snap_recheck); // 第二轮：检查是否停止 watching
    // ...
}
```

`force_qs_rnp()` 会遍历所有 CPU，对没有报告 QS 的 nohz_full CPU 发送 IPI。

---

## 四、Expedited Grace Period（紧急 GP）

### 4.1 普通 GP vs  Expedited GP

普通 GP 的问题：需要等待所有 CPU 经历完整的上下文切换（`jiffies_till_first_fqs` 至少 1 个 jiffy）。

Expedited GP 的做法：**主动 IPI 所有非 idle 在线 CPU，强制它们立即报告 QS**。

```c
// kernel/rcu/tree_exp.h
void synchronize_rcu_expedited(void)
{
    // 1. rcu_exp_gp_seq_snap() - 获取序列号快照
    unsigned long s = rcu_exp_gp_seq_snap();

    // 2. exp_funnel_lock() - funnel 锁防止多个 Expedited GP 并发
    if (exp_funnel_lock(s))
        return;  // 别人已经启动了

    // 3. rcu_exp_sel_wait_wake(s)
    //    a. sync_rcu_exp_select_cpus() - 遍历叶子节点
    //    b. 对每个叶子节点，__sync_rcu_exp_select_node_cpus()
    //         - 检查哪些 CPU 需要 IPI（idle/offline/已有 QS 的跳过）
    //         - 对需要 IPI 的 CPU，smp_call_function_single(cpu, rcu_exp_handler, ...)
    //    c. rcu_exp_wait_wake() - 等待 + 唤醒所有等待者
}
```

### 4.2 rcu_exp_handler() — IPI 处理函数

```c
// kernel/rcu/tree_exp.h
static void rcu_exp_handler(void *unused)
{
    // 三种情况：

    // 情况1: 不在 RCU 读临界区，且不在 softirq/preempt 上下文
    //        → 直接报告 QS
    if (!depth &&
        (!(preempt_count() & (PREEMPT_MASK | SOFTIRQ_MASK)) ||
         rcu_is_cpu_rrupt_from_idle()))
        rcu_report_exp_rdp(rdp);

    // 情况2: 不在 RCU 读临界区，但在 softirq/preempt 上下文
    //        → 延迟报告（下一个 rcu_read_unlock 或调度点）
    else
        rcu_exp_need_qs();  // 设置 rdp->cpu_no_qs.b.exp = true

    // 情况3: 在 RCU 读临界区（CONFIG_PREEMPT_RCU）
    //        → 在 rcu_read_unlock 时报告
    if (depth > 0) {
        rdp->cpu_no_qs.b.exp = true;
        current->rcu_read_unlock_special.b.exp_hint = true;
    }
}
```

### 4.3 IPI 分发与重试

```c
// kernel/rcu/tree_exp.h:__sync_rcu_exp_select_node_cpus()
for_each_leaf_node_cpu_mask(rnp, cpu, mask_ofl_ipi) {
    ret = smp_call_function_single(cpu, rcu_exp_handler, NULL, 0);
    if (ret) {
        // CPU hotplug 竞争 → 延迟后重试
        schedule_timeout_idle(1);
        goto retry_ipi;
    }
    // CPU 在处理 IPI 时会报告 QS
}
```

**关键设计**：Expedited GP 必须在所有 CPU 上等待，而不是只等待一个"足够快"的 GP。因为 Expedited GP 的使用者期望等待时间可预测（毫秒级），不能依赖普通 GP 的不确定延迟。

### 4.4 Expedited GP 的 funnel lock

```c
// kernel/rcu/tree_exp.h:exp_funnel_lock()
static bool exp_funnel_lock(unsigned long s)
{
    // 1. fastpath: trylock 根 mutex + 检查节点序列号
    if (mutex_trylock(&rcu_state.exp_mutex))
        goto fastpath;

    // 2. funnel: 从叶子节点向上遍历
    for (; rnp != NULL; rnp = rnp->parent) {
        if (sync_exp_work_done(s))
            return true;  // 别人已经完成了

        spin_lock(&rnp->exp_lock);
        if (rnp->exp_seq_rq >= s) {
            // 某个更高级别的请求者正在做这个 GP
            spin_unlock(&rnp->exp_lock);
            wait_event(rnp->exp_wq[rcu_seq_ctr(s) & 0x3], ...);
            return true;
        }
        WRITE_ONCE(rnp->exp_seq_rq, s);  // 标记我在等
        spin_unlock(&rnp->exp_lock);
    }

    // 3. 获取根 mutex
    mutex_lock(&rcu_state.exp_mutex);
fastpath:
    if (sync_exp_work_done(s))
        return true;
    rcu_exp_gp_seq_start();  // 开始新的 expedited GP
    return false;
}
```

---

## 五、rcu_bh 与 rcu_sched — 不同上下文的 RCU

### 5.1 为什么需要三种 RCU

Linux 内核有三种 RCU flavor，分别对应不同的"读端上下文"：

| Flavor | 读端 API | 实际保护 | QS 触发条件 |
|--------|----------|----------|-------------|
| `rcu_sched` | `rcu_read_lock_sched()` | 进程上下文 + 软中断 | 调度时钟中断 |
| `rcu_bh` | `rcu_read_lock_bh()` / `rcu_read_unlock_bh()` | 软中断上下文（`local_bh_enable()`之前） | 软中断处理结束时 |
| `rcu_preempt`（默认） | `rcu_read_lock()` | 所有上下文（含进程内的抢占点） | 调度点 + 禁抢占区域结束 |

**为什么分开？**
- `rcu_bh` 主要服务于网络子系统。NET_RX softirq 处理网络包时，底层数据结构需要保护，但 softirq 之间没有调度时钟中断触发 QS
- `rcu_read_lock_bh()` 禁的是 `local_bh_enable()` 之前的区域，即 softirq/BH 被禁用的时段
- 网络接收路径的关键场景：

```c
// 网络设备驱动 rx 处理
static void net_rx_action(struct softirq_action *h)
{
    // 这里 softirq 被视为 rcu_bh 读端临界区
    // local_bh_disable() 隐式地扩展了 rcu_bh 临界区
    struct sk_buff *skb = receive_skb();
    // ... 处理 ...
    local_bh_enable();  // ← 这里自动报告 rcu_bh QS
}
```

### 5.2 rcu_bh 的 QS 机制

```c
// include/linux/rcupdate.h:888
static inline void rcu_read_lock_bh(void)
{
    __local_bh_disable_ip(_THIS_IP_, SOFTIRQ_LOCK_OFFSET);
}

// SOFTIRQ_LOCK_OFFSET = 1，即 softirq count
// __local_bh_disable_ip 设置 preempt_count() 的 SOFTIRQ bit
// QS 报告点：在 __do_softirq() 末尾（local_bh_enable() 路径）

// kernel/softirq.c:invoke_softirq()
if (!force_irqthreads && !ksoftirqd_running(cpu)) {
    if (should_wake_ksoftirqd())
        wake_up_process(smpboot_get_current(ksoftirqd));
}
```

实际上 `rcu_bh` 的 QS 在 `local_bh_enable()` → `account_system_time()` → `rcu_bh_qs()` 中报告。

### 5.3 rcu_sched 的 QS 机制

```c
// include/linux/rcupdate.h:930
static inline void rcu_read_lock_sched(void)
{
    preempt_disable();
}

// 等价于禁用调度 + 禁抢占（但用于 SCHED RCU flavor）
// QS 通过 rcu_sched_clock_irq() 在调度时钟中断时报告

// kernel/rcu/tree.c:1994
void rcu_sched_clock_irq(int user)
{
    rcu_qs();
    // 检查 rdp->core_needs_qs → 如果需要则调用 rcu_report_qs_rdp()
}
```

---

## 六、SRCU — Sleepable RCU

### 6.1 SRCU 与普通 RCU 的核心区别

普通 `rcu_read_lock()` 只能禁抢占，不能睡眠。SRCU 允许在读临界区内睡眠。

```c
// kernel/rcu/srcutree.c
DEFINE_SRCU(my_srcu);

void reader(void)
{
    int idx;
    idx = srcu_read_lock(&my_srcu);   // 返回 idx（计数器索引）
    // 可以睡眠，可以 schedule()
    srcu_read_unlock(&my_srcu, idx);  // idx 必须匹配
}
```

### 6.2 两路计数器机制

SRCU 使用两路计数器轮转来避免"等待所有读者"的问题：

```c
// srcu_struct 核心字段:
struct srcu_struct {
    struct srcu_ctr __percpu *srcu_ctrs;   // 每 CPU 两个计数器 [0] 和 [1]
    // 每 CPU: srcu_ctrs[idx].srcu_locks - 当前 idx 的读者数
    // 每 CPU: srcu_ctrs[idx].srcu_unlocks - 当前 idx 的解锁数
    unsigned long srcu_gp_seq;             // 当前 GP 序列号
    struct mutex srcu_gp_mutex;            // 保护 GP 状态转换
    ...
};

// srcu_read_lock():
__srcu_read_lock(struct srcu_struct *ssp)
{
    struct srcu_ctr __percpu *scp = READ_ONCE(ssp->srcu_ctrp);
    // ssp->srcu_ctrp 指向当前活跃的计数器数组（每次 flip 后切换）
    this_cpu_inc(scp->srcu_locks.counter);  // 增加当前 idx 的 locks
    smp_mb();  // B - 避免临界区泄露
    return __srcu_ptr_to_ctr(ssp, scp);     // 返回 idx
}

// srcu_read_unlock():
__srcu_read_unlock(struct srcu_struct *ssp, int idx)
{
    smp_mb();  // C - 避免临界区泄露
    this_cpu_inc(__srcu_ctr_to_ptr(ssp, idx)->srcu_unlocks.counter);
}
```

### 6.3 synchronize_srcu() 的等待过程

```c
// kernel/rcu/srcutree.c:__synchronize_srcu()
static void __synchronize_srcu(struct srcu_struct *ssp, bool do_norm)
{
    struct rcu_synchronize rcu;
    init_completion(&rcu.completion);
    __call_srcu(ssp, &rcu.head, wakeme_after_rcu, do_norm);
    wait_for_completion(&rcu.completion);
}

// srcu_gp_start_if_needed() 启动 GP:
// 1. 调用 srcu_funnel_gp_start() - 将请求登记到 srcu_node 树
// 2. 如果当前没有 GP，调用 srcu_gp_start()

// srcu_gp_end():
// 1. 等待 idx=0 和 idx=1 上的读者全部退出
//    try_check_zero(ssp, idx, trycount) 循环检查两路计数器的 lock/unlock 差值
// 2. srcu_flip() - 切换 ssp->srcu_ctrp 指向另一路计数器
// 3. 调用 srcu_gp_end() - 结束 GP，触发回调
```

### 6.4 srcu_node 树结构

SRCU 也有树形结构（类似 tree RCU 的 rcu_node 树），用于扩展到大量 CPU：

```
srcu_node 树（来自 srcutree.c）:
每 CPU 的 srcu_data 挂在叶子 srcu_node 上
叶子 srcu_node 逐级向上汇总到根 srcu_node

srcu_node 结构:
  - srcu_have_cbs[idx]: 记录哪些节点有属于当前 GP 的回调
  - srcu_data_have_cbs[idx]: 哪些 srcu_data 有回调
  - srcu_gp_seq_needed_exp: expedited GP 请求序列号

init_srcu_struct_nodes() 构建树，树的深度由 rcu_num_lvls 决定
```

---

## 七、Linux 7.0 的 TREE RCU 架构

### 7.1 rcu_node 层级结构

Linux 7.0 的 RCU 使用完全分层（hierarchical）的 rcu_node 树：

```
大型系统 (256+ CPUs) 的 rcu_node 树示例:

root (level=0)
 ├── node[0] (level=1, 0-63 CPUs)
 │    ├── leaf[0] (level=2, CPUs 0-7)
 │    ├── leaf[1] (level=2, CPUs 8-15)
 │    ├── leaf[2] (level=2, CPUs 16-23)
 │    └── ...
 ├── node[1] (level=1, 64-127 CPUs)
 │    ├── leaf[64] (level=2, CPUs 64-71)
 │    └── ...
 └── node[2] (level=1, 128-191 CPUs)
      └── ...

CONFIG_RCU_FANOUT = 64 (默认)
CONFIG_RCU_FANOUT_LEAF = 64
NUM_RCU_LVLS = 3
```

```c
// kernel/rcu/tree.h
struct rcu_node {
    raw_spinlock_t lock;           // 保护本节点 + 子节点的锁
    unsigned long gp_seq;           // 当前 GP 序列号（本节点视角）
    unsigned long gp_seq_needed;   // 所有 CPU 请求的最远 GP 号
    unsigned long qsmask;          // 还需报告 QS 的 CPU 位图
    unsigned long qsmaskinit;      // GP 开始时的 qsmask 快照
    unsigned long qsmaskinitnext;   // 下次 GP 应等待的 CPU 位图
    unsigned long expmask;          // expedited GP 等待位图
    struct list_head blkd_tasks;    // 阻塞在 RCU 临界区内的任务列表
    struct rcu_node *parent;        // 指向父节点（NULL 表示根）
    int grplo, grphi;               // 本节点包含的 CPU 范围
    u8 level;                       // 层级（根=0，叶子=max）
    ...
};
```

### 7.2 rcu_data — 每 CPU 数据

```c
// kernel/rcu/tree.h
struct rcu_data {
    // GP 相关
    unsigned long gp_seq;           // 本 CPU 视角的 GP 序列号
    unsigned long gp_seq_needed;    // 本 CPU 请求的 GP 号

    // QS 状态
    union rcu_noqs cpu_no_qs;       // { .norm, .exp } 两个标志
    bool core_needs_qs;             // 是否需要报告 QS

    // 回调链表（核心！）
    struct rcu_segcblist cblist;   // 分段回调列表

    // 与 rcu_node 的关联
    struct rcu_node *mynode;        // 本 CPU 对应的叶子 rcu_node
    unsigned long grpmask;          // 在叶子节点中的 bit mask

    // NO_HZ_FULL 支持
    bool rcu_urgent_qs;             // 需要报告 QS（被其他 CPU 请求）
    bool rcu_forced_tick;           // 强制 tick 以报告 QS

    // NOCB (No-CB) offloading
#ifdef CONFIG_RCU_NOCB_CPU
    struct rcu_nocb { ... } nocb;
#endif
};
```

### 7.3 GP 的三阶段状态机（完整图）

```
GP 生命周期完整状态图:

[IDLE] ─────────────────────────────────────────► [WAIT_GPS]
            ▲                                         │
            │                                         │ GP kthread wakeup
            │                                         │ (RCU_GP_FLAG_INIT set)
            │                                         ▼
            │  ┌────────────────────────────────────────────────┐
            │  │                                              │
            │  ▼                                              │
     [CLEANUP] ◄────────────────── [DOING_FQS] ◄── [WAIT_FQS]
            │                              ▲          ▲
            │                              │          │ jiffies_force_qs 到达
            │                              │          │ force_qs_rnp() 扫描
            │                              │          ▼
            │                              │    ┌─────────────────────┐
            │                              │    │  rcu_gp_fqs(first)   │
            │                              │    │  force_qs_rnp(...)   │
            │                              │    │  推进 cblist 段      │
            │                              │    └─────────────────────┘
            │                              │
            └──────────────────────────────┘
                      qsmask == 0 时退出

三阶段详解:

init 阶段 (rcu_gp_init):
  - rcu_seq_start()          设置 gp_seq 低2位为 Running 状态
  - 遍历叶子 rcu_node，设置 qsmaskinit = qsmaskinitnext
  - 若 qsmaskinit 从 0→非0，调用 rcu_init_new_rnp()
  - 若从非0→0 且无 blocked tasks，调用 rcu_cleanup_dead_rnp()
  - 传播变化到根节点

fqs 阶段 (rcu_gp_fqs_loop):
  - swait_event_idle_timeout() 等待到 jiffies_force_qs
  - force_qs_rnp() 遍历所有 rcu_node
  - 对 nohz_full CPU：检查 rcu_urgent_qs，必要时 tick_dep 强制
  - 对其他 CPU：检查 cpu_no_qs，必要时发送 IPI
  - 每轮 force 后，cond_resched_tasks_rcu_qs() 让本 CPU 报告 QS

cleanup 阶段 (rcu_gp_cleanup):
  - 遍历所有 rcu_node，推进 gp_seq 到新号
  - 调用 rcu_accelerate_cbs() 推进各 CPU 的 cblist
  - 如果 needgp，重新设置 RCU_GP_FLAG_INIT 启动下一个 GP
  - 调用 rcu_sr_normal_gp_cleanup() 唤醒所有等待者
```

---

## 八、rcu_head 释放时序图

```
call_rcu() → GP 完成 → callback 调用的完整时序:

时间 ──────────────────────────────────────────────────────►

[阶段1: call_rcu 注册]
CPU0: call_rcu(&obj->rcu, free_func)
  └── call_rcu_core()
        └── rcu_segcblist_enqueue(&rdp->cblist, &obj->rcu)
             // 插入 RCU_NEXT_TAIL 段 (gp_seq 未知)

[阶段2: GP 启动]
GP kthread: rcu_gp_init()
  - rcu_seq_start(gp_seq = N)
  - 设置所有叶子 rcu_node qsmaskinit = qsmaskinitnext
  - 设置所有 rcu_node qsmask = qsmaskinit

[阶段3: QS 传播]
CPU0: rcu_qs() (调度时钟中断)
  └── rcu_report_qs_rdp()
       └── rcu_report_qs_rnp(cpu_mask, leaf_rnp, gp_seq=N)
            └── leaf_rnp->qsmask &= ~cpu_mask
                 // leaf rnp qsmask == 0
                 └── 向上传播: parent->qsmask &= ~child_mask
                      // ... 传播到 root
                      └── root->qsmask == 0
                           └── rcu_report_qs_rsp() → 设置 RCU_GP_FLAG_FQS

[阶段4: GP 结束]
GP kthread: rcu_gp_fqs() (force_qs_rnp 扫描确认)
GP kthread: rcu_gp_cleanup()
  - new_gp_seq = rcu_state.gp_seq
  - rcu_seq_end(new_gp_seq)
  - 遍历所有 rcu_node: rnp->gp_seq = new_gp_seq
  - rcu_accelerate_cbs() → 推进各 CPU cblist
       // RCU_NEXT_TAIL callbacks 获得 gp_seq = N+1
       // RCU_WAIT_TAIL callbacks 移到 RCU_DONE_TAIL
  - rcu_sr_normal_gp_cleanup() → 唤醒等待者

[阶段5: callback 调用]
CPU0 softirq/rcuc: rcu_invoke_callbacks()
  ├── rcu_segcblist_extract_done_cbs(&rdp->cblist, &ready_cbs)
  │     // 将 RCU_DONE_TAIL 段全部移出
  ├── for (rhp = rcu_cblist_dequeue(&ready_cbs); rhp; ...)
  │     debug_rcu_head_unqueue(rhp)
  │     rhp->func(rhp)     // free_func(obj)
  │     // 在 free_func 中: kfree(obj) → 内存归还系统

  └── rcu_segcblist_add_len(&rdp->cblist, -len)
       // 更新 cblist.len
```

---

## 九、rcutorture — RCU 本身如何测试

### 9.1 rcutorture 的设计

`kernel/rcu/rcutorture.c` 是 Linux 内核自带的 RCU 压力测试工具。

**核心数据结构**：
```c
// kernel/rcu/rcutorture.c
struct rcu_torture {
    struct rcu_head rcu;         // RCU 回调头
    int value;                   // 数据值
    struct rcu_torture_reader_check *rtort_chkp;  // 读者检查点
};

// 全局对象池
static struct rcu_torture rcu_tortures[10 * RCU_TORTURE_PIPE_LEN];

// 每 CPU 计数器
static DEFINE_PER_CPU(long[RCU_TORTURE_PIPE_LEN + 1], rcu_torture_count);
static DEFINE_PER_CPU(long[RCU_TORTURE_PIPE_LEN + 1], rcu_torture_batch);
```

### 9.2 writer 与 reader 的 race 模拟

```c
// rcu_torture_writer() - 模拟更新者
rcu_torture_writer()
{
    // 1. 从 freelist 获取一个 rcu_torture 对象
    p = rcu_torture_alloc();

    // 2. 写入数据
    p->value = i;

    // 3. rcu_assign_pointer 更新全局指针
    rcu_assign_pointer(rcu_torture_current, p);

    // 4. 调用 call_rcu() 注册回调（从 freelist 移除）
    call_rcu(&p->rcu, rcu_torture_free);

    // 5. 更新版本号
    rcu_torture_current_version++;
}

// rcu_torture_reader() - 模拟读者
rcu_torture_reader()
{
    // 1. rcu_read_lock()
    // 2. 读取全局指针
    p = rcu_dereference(rcu_torture_current);

    // 3. 读取数据（可能正在被 writer 修改）
    cur = rcu_torture_current_version;
    if (p)
        actual = p->value;

    // 4. rcu_read_unlock()

    // 5. 检查一致性
    if (cur != rcu_torture_current_version)
        atomic_inc(&n_rcu_torture_mberror);
    // 如果 writer 在读期间更新，读到的 version 会不匹配
}
```

### 9.3 rcutorture 的其他测试场景

```
rcutorture 支持的测试场景:

1. RCU vs GP 延迟
   - writer 频繁 call_rcu + 更新
   - reader 长时间持锁（模拟真实延迟）
   - 检测 callback 是否在 GP 后正确被调用

2. NOCB offloading
   - 配置 CONFIG_RCU_NOCB_CPU=y
   - 测试 offloaded CPU 的 cblist 处理

3. Expedited GP
   - rcutorture.exp=1 参数
   - 压力测试 synchronize_rcu_expedited()

4. Priority boosting
   - CONFIG_RCU_BOOST=y
   - 测试读者被抢占时 GP 是否正确等待

5. CPU hotplug
   - 在压力测试中动态 online/offline CPU
   - 验证 rcu_node 树的 hotplug 处理
```

---

## 十、关键数据结构汇总

```
RCU 核心数据结构关系:

rcu_state (全局，单例)
  ├── .node[NUM_RCU_NODES]     rcu_node 树（根 + 中间节点 + 叶子）
  ├── .gp_seq                  当前 GP 序列号
  ├── .gp_flags                { INIT, FQS, OVLD }
  ├── .gp_kthread              GP kthread (rcu_gp_kthread)
  └── .gp_wq                   GP kthread 等待队列

rcu_node (每个节点)
  ├── .lock                    保护本节点 + 传播 QS
  ├── .gp_seq                  本节点视角的 GP 号
  ├── .qsmask                  还需 QS 的 CPU/task 位图
  ├── .qsmaskinit              GP 开始时的 qsmask 快照
  ├── .qsmaskinitnext          下次 GP 的目标 qsmask
  ├── .parent                  指向父节点
  ├── .blkd_tasks              阻塞的任务链表（PREEMPT_RCU）
  └── .exp_xxx                 expedited GP 相关字段

rcu_data (每 CPU 一个)
  ├── .cblist                  分段回调链表
  ├── .gp_seq                  本 CPU 视角的 GP 号
  ├── .cpu_no_qs               { .norm, .exp } 两个 QS 标志
  ├── .mynode                  指向本 CPU 的叶子 rcu_node
  └── .grpmask                 在叶子节点中的 bit

rcu_head (嵌入在使用者的数据结构中)
  └── .func                    回调函数指针

rcu_segcblist (每 CPU 一个回调链表)
  ├── .head                    链表头
  ├── .tails[4]                4 个段的尾指针
  │     [RCU_DONE_TAIL, RCU_WAIT_TAIL, RCU_NEXT_READY_TAIL, RCU_NEXT_TAIL]
  └── .gp_seq[4]               各段对应的 GP 序列号
```

---

## 附录：RCU GP 完整状态机 ASCII 图

```
┌──────────────────────────────────────────────────────────────┐
│                    RCU Grace Period State Machine            │
└──────────────────────────────────────────────────────────────┘

                           ┌──────────────────────┐
                           │    RCU_GP_IDLE       │
                           │  (GP kthread 睡眠)  │
                           └──────────┬───────────┘
                                      │ RCU_GP_FLAG_INIT set
                                      │ (call_rcu / synchronize_rcu)
                                      ▼
                           ┌──────────────────────┐
                           │   RCU_GP_WAIT_GPS    │
                           │ swait_event_idle_    │
                           │ exclusive(gp_wq)     │
                           └──────────┬───────────┘
                                      │ rcu_gp_init() 返回 true
                                      ▼
                           ┌──────────────────────┐
                           │    RCU_GP_INIT        │
                           │ rcu_gp_init()         │
                           │ • rcu_seq_start()     │
                           │ • 遍历叶子 rcu_node   │
                           │ • 设置 qsmaskinit     │
                           │ • 处理 CPU hotplug    │
                           └──────────┬───────────┘
                                      │ init 成功
                                      ▼
                           ┌──────────────────────┐
                           │   RCU_GP_WAIT_FQS    │
                           │ swait_event_idle_    │
                           │ timeout_exclusive()  │
                           │ (等待 jiffies +       │
                           │  QS 传播完成)        │
                           └──────────┬───────────┘
                                      │ qsmask == 0
                                      │ && no blocked tasks
                                      ▼
                           ┌──────────────────────┐
                           │   RCU_GP_DOING_FQS    │
                           │ force_qs_rnp() 扫描   │
                           │ 确认所有 CPU 报告 QS  │
                           └──────────┬───────────┘
                                      │
                          ┌───────────┴───────────┐
                          │ (qsmask 非零)          │ (qsmask == 0)
                          ▼                       ▼
                  ┌──────────────────┐     ┌───────────────────┐
                  │  rcu_gp_fqs()   │     │   RCU_GP_CLEANUP  │
                  │  force_qs_rnp() │     │   rcu_gp_cleanup() │
                  │  可能发送 IPI   │     │   • 推进 gp_seq   │
                  │  设置 jiffies   │     │   • 推进 cblist   │
                  │  下次扫描时间   │     │   • 调用 Done CBs │
                  └────────┬─────────┘     │   • 启动下一 GP   │
                           │                └─────────┬─────────┘
                           └────────────────────────────┘
                                                  │
                                                  ▼
                                         ┌───────────────────┐
                                         │   RCU_GP_CLEANED   │
                                         │  (回到 WAIT_GPS   │
                                         │   或 IDLE)        │
                                         └───────────────────┘

RCU_GP_FLAG_INIT:   有人请求新的 GP（call_rcu 汇聚太多）
RCU_GP_FLAG_FQS:    需要强制扫描 QS（超时或 force_qs）
RCU_GP_FLAG_OVLD:   callback overload 检测到
```

---

## 附录：call_rcu → callback 调用完整路径图

```
用户调用 call_rcu() 到 callback 最终被调用的完整路径:

[User thread / Interrupt context]

call_rcu(&head, func)
  │
  ▼
__call_rcu_common(head, func, lazy)
  │
  ├─ debug_rcu_head_queue(head)      // double-call 检查
  │
  ├─ rcu_segcblist_enqueue()
  │     // 将 head 加入 rdp->cblist 的 RCU_NEXT_TAIL
  │     // gp_seq 未定，等待下次 advance 时分配
  │
  └─ call_rcu_core(rdp, head, func, flags)
        │
        ├─ rcutree_enqueue(rdp, head, func)
        │     // 确保 head 进入 cblist
        │
        ├─ if (!rcu_is_watching())
        │     invoke_rcu_core()
        │     // CPU 在 extended QS（idle/offline）时
        │     // 立即触发 softirq 处理
        │
        └─ if (cblist 太长)
             rcu_force_quiescent_state()
             // 通知 GP kthread 需要启动新 GP

═══════════════════════════════════════════════════════════════════

[GP kthread: rcu_gp_kthread()]

rcu_gp_init()
  - rcu_seq_start(gp_seq = N)
  - 设置叶子 rcu_node qsmaskinit
  - 传播到根

      ── 等待所有 CPU 报告 QS ──

rcu_gp_fqs_loop()
  - force_qs_rnp() 扫描
  - 对 nohz_full CPU 强制 tick
  - 确认 qsmask == 0

rcu_gp_cleanup()
  - new_gp_seq = N + 1
  - rcu_seq_end(gp_seq)
  - rcu_for_each_node_breadth_first()
       rnp->gp_seq = new_gp_seq  // 推进所有节点
  - rcu_accelerate_cbs()
       // 移动 callbacks 到下一个 segment
  - rcu_sr_normal_gp_cleanup()
       // 唤醒 synchronize_rcu() 等待者

═══════════════════════════════════════════════════════════════════

[CPU softirq / rcuc kthread: rcu_core()]

rcu_core()
  - 持有本地 rdp->nocb_lock（如 offload）
  - rcu_advance_cbs(rdp)
       // 按 rnp->gp_seq 推进本 CPU 的 cblist
       // GP N 的 callbacks 从 WAIT → DONE
  - rcu_invoke_callbacks()
       // 提取 DONE 段 callbacks
       // 按序调用 func(head)

      rcu_cblist_dequeue(&ready_cbs)
      for (rhp = rcu_cblist_dequeue(&ready_cbs); rhp; ...)
           rhp->func(rhp)      // ← 用户回调在这里执行
```

---

## 参考文献

- `kernel/rcu/tree.c` — Tree RCU 主实现（4931 行）
- `kernel/rcu/tree_exp.h` — Expedited GP 实现
- `kernel/rcu/srcutree.c` — SRCU 实现
- `kernel/rcu/tree.h` — TREE RCU 核心数据结构（rcu_node, rcu_data, rcu_state）
- `kernel/rcu/rcu_segcblist.h` — 分段回调链表
- `include/linux/rcupdate.h` — 公开 API（rcu_read_lock, call_rcu, synchronize_rcu 等）
- `include/linux/rcu_segcblist.h` — 段定义（RCU_DONE_TAIL 等）
- `Documentation/RCU/` — Linux RCU 设计文档