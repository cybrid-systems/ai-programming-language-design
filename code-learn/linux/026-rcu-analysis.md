# 26-rcu — Linux 内核 RCU 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**RCU（Read-Copy-Update）** 是 Linux 内核中一种无锁的并发同步机制，由 Paul E. McKenney 于 2002 年引入。它允许读者（reader）在不加锁、不使用原子操作、不触发缓存行 bouncing 的情况下读取共享数据，而写者（writer）通过创建新副本替换旧数据、延迟回收旧数据来保证并发安全。

RCU 的核心理念：

```
读者路径（极快——无锁、无原子操作、无内存屏障）：
  rcu_read_lock();
  ptr = rcu_dereference(gbl_ptr);
  data = ptr->data;      // 读取数据（可能正在被写者替换）
  rcu_read_unlock();
  // 读者完全不受写者影响！

写者路径：
  new_ptr = kmalloc(...);
  *new_ptr = *old_ptr;   // 创建副本
  new_ptr->data = new_val;
  rcu_assign_pointer(gbl_ptr, new_ptr);  // 原子替换指针
  synchronize_rcu();                      // 等待所有读者完成！
  kfree(old_ptr);                         // 安全释放旧数据
```

**doom-lsp 确认**：核心实现在 `kernel/rcu/` 目录。`tree.c` 实现了 Tree RCU，`srcu.c` 实现了 SRCU，`tasks.h` 实现了 Tasks RCU。API 在 `include/linux/rcupdate.h`。

---

## 1. RCU 的核心概念

### 1.1 宽限期（Grace Period）

宽限期是 RCU 中最核心的概念。它保证了"所有在宽限期开始前已经开始的 RCU 读临界区都已经完成"：

```
时间轴：
  CPU 0:  [[RCU读临界区]]
  CPU 1:  [[RCU读临界区]]
  CPU 2:                          synchronize_rcu() 返回
  ───────────────┼─────────────────┼──────────────►
                 开始宽限期         宽限期结束（所有读者退出）
```

写者在 `synchronize_rcu()` 返回后，才能安全地释放旧数据。

### 1.2 静止状态（Quiescent State，QS）

静止状态是 RCU 检测"读者已完成"的手段。一个 CPU 的静止状态意味着该 CPU 上当前**没有正在执行的 RCU 读临界区**。

静止状态的类型：
```
1. 用户态执行（user mode）—— 不在内核中，不会持有 rcu_read_lock
2. idle 循环 —— CPU 空闲，无读者
3. 上下文切换 —— 进程调度，读者必然已退出
```

### 1.3 grace period 的检测

每个 CPU 的 tick（定时器中断）中通过调度时钟中断检查是否需要报告 QS：

```c
// kernel/rcu/tree.c: 调度时钟中断处理
// 如果当前 CPU 在用户态或 idle（不在 RCU 读临界区）
// → 标记此 CPU 通过了 QS
// 实际路径：update_process_times → rcu_sched_clock_irq(user)
//   → rcu_flavor_sched_clock_irq(user)
```

---

## 2. RCU API

### 2.1 读者侧

```c
// 读临界区开始（极快——只是一个屏障）
rcu_read_lock();
// → 对于 PREEMPT_RCU：
//    禁止抢占（preempt_disable）
//    → 防止读者被调度出去 → 保证读者不穿越宽限期
// → 对于非 PREEMPT 内核：
//    barrier() 阻止编译器优化

// ★ 读取被 RCU 保护的指针
ptr = rcu_dereference(gbl_ptr);
// → 相当于 READ_ONCE(ptr) + 阻止编译器重排
// → 保证读取到完整的指针值（不被撕裂）

// 使用读取的数据...
do_something_with(ptr);

// 读临界区结束
rcu_read_unlock();
// → 恢复抢占
```

### 2.2 写者侧

```c
// 1. 创建新副本
struct foo *new = kmalloc(sizeof(*new), GFP_KERNEL);
*new = *old;                 // 复制旧数据
new->data = updated_value;   // 修改

// 2. 原子替换指针
rcu_assign_pointer(gbl_ptr, new);
// → 相当于 smp_store_release(&ptr, new)
// → 保证之前的写入对通过 rcu_dereference 读取的读者可见

// 3. 等待所有现有读者完成
synchronize_rcu();
// → 阻塞直到所有在 rcu_assign_pointer 之前进入读临界区的读者退出
// → 此时可以安全释放旧数据

// 4. 释放旧数据
kfree(old);
```

### 2.3 异步宽限期

```c
// 异步版本——不阻塞写者
struct rcu_head *rh = &old->rcu_head;
call_rcu(rh, my_free_callback);
// → 在宽限期结束后，在软中断上下文中调用 my_free_callback(rh)
// → 写者可以继续执行，不等待宽限期

void my_free_callback(struct rcu_head *rh)
{
    struct foo *p = container_of(rh, struct foo, rcu_head);
    kfree(p);
}
```

---

## 3. Tree RCU 实现

### 3.1 数据结构

```c
// kernel/rcu/tree.c — Tree RCU 核心结构

// 每个 CPU 一个 rcu_data
struct rcu_data {
    unsigned long completed;      // 完成的宽限期数
    unsigned long gp_seq;         // 当前宽限期序列号
    bool          qs_pending;     // 是否有 QS 等待报告
    bool          beenonline;     // CPU 是否在线
    struct rcu_node *mynode;      // 所属的 rcu_node（树节点）
    unsigned long  ticks_this_gp; // 当前宽限期内的 tick 数
};

// 树形节点
struct rcu_node {
    raw_spinlock_t __private lock;
    unsigned long gp_seq;         // 此节点的宽限期序列号
    unsigned long qsmask;         // 哪些子节点（或 CPU）尚未报告 QS
    unsigned long qsmaskinit;     // 初始化的 qsmask
    struct rcu_node *parent;      // 父节点
    u8  level;                    // 树层级（0=叶子, level_max=根）
};
```

### 3.2 Tree RCU 的树形结构

```
小型系统（4 CPU）：
      根节点（level 2）
        /        \
    叶子节点   叶子节点
    (CPU 0-1)  (CPU 2-3)

大型系统（4096 CPU）：
        根节点（level 3）
        /        \
      节点        节点
     /    \      /    \
  叶子  叶子   叶子   叶子
  CPU   CPU    CPU    CPU
  0-7   8-15  16-23  24-31
```

**树形结构的优势**：宽限期检测从叶子到根传播，避免集中扫描所有 CPU。

```
宽限期检测的数据流：

    所有 CPU 报告 QS
          │
      ┌───┴───┐
    叶子     叶子 ← 检查 qsmask 是否全 0
      │       │      如果是 → 上报父节点
      └───┬───┘
          │
        内节点 ← qsmask 全 0 → 上报根节点
          │
        根节点 ← qsmask 全 0 → grace period 结束！
```

---

## 4. synchronize_rcu 的数据流

```c
// kernel/rcu/tree.c — synchronize_rcu 的简化数据流
synchronize_rcu()
  │
  ├─ [1. 启动宽限期]
  │   rcu_gp_init()
  │   ├─ raw_spin_lock(&rcu_state.gp_lock)
  │   ├─ rcu_state.gp_seq++          ← 新序列号
  │   ├─ for_each_rcu_node(rnp)：
  │   │     rnp->qsmask = rnp->qsmaskinit
  │   │     → 标记所有子节点/CPU 为"未通过 QS"
  │   ├─ rcu_state.gp_flags |= GP_INIT
  │   └─ raw_spin_unlock(...)
  │
  ├─ [2. 等待所有 CPU 报告静止状态]
  │   while (!rcu_gp_completed()) {
  │       // 在每个 CPU 的 tick 中：
  │       // rcu_check_callbacks() → rcu_flavor_sched_clock_irq()
  │       //   → 如果不在 RCU 读临界区：
  │       //      此 CPU 通过 QS
  │       //      rcu_report_qs_rdp(cpu, rdp)
  │       //        → 上报到 rcu_node 树
  │       //        → 叶子 qsmask 清除
  │       //        → 如果全清除：上报父节点
  │       //        → ...递归到根节点
  │       //        → 根节点 qsmask == 0 → GP 结束
  │       schedule();  // 休眠等待
  │   }
  │
  └─ [3. 宽限期结束]
      rcu_gp_cleanup()
      → 唤醒所有在 synchronize_rcu() 中等待的进程
```

---

## 5. call_rcu 的数据流

```c
// kernel/rcu/tree.c
void call_rcu(struct rcu_head *head, rcu_callback_t func)
{
    head->func = func;
    // 将 head 加入当前 CPU 的 call_rcu 回调链表
    __call_rcu_core(head, rdp);
    // → 如果不在中断中，唤醒 RCU 软中断
    // → raise_softirq(RCU_SOFTIRQ)
}
```

```
宽限期结束后：
  rcu_do_batch(rdp)
  │
  ├─ 遍历 rdp->cblist（已完成宽限期的回调）
  │
  ├─ for each rcu_head:
  │   ├─ rcu_lock_acquire(&rcu_callback_map)
  │   ├─ head->func(head)      ← ★ 执行回调！
  │   │  → my_free_callback()  → kfree(old)
  │   └─ rcu_lock_release(...)
  │
  └─ 如果列表仍有回调 → 再次 raise_softirq(RCU_SOFTIRQ)
```

---

## 6. RCU 变体

| 变体 | 读者限制 | 宽限期含义 | 使用场景 |
|------|---------|-----------|---------|
| Classic RCU | 不可抢占/休眠 | 所有 CPU 的 QS | 通用 |
| PREEMPT RCU | 可被抢占（仍不可休眠）| 所有在线 CPU 的 QS | PREEMPT 内核 |
| SRCU | 可休眠！ | 所有 CPU + 显式 srcu_read_unlock | 可休眠读路径 |
| Tasks RCU | 内核线程/任务 | 所有任务上下文切换 | trampoline 卸载 |
| Tiny RCU | UP 系统 | 简化实现 | 嵌入式 |

### 6.1 SRCU（Sleepable RCU）

```c
// SRCU 读者可以休眠！
struct srcu_struct ss;
DEFINE_SRCU(ss);

// 读者（可休眠）：
idx = srcu_read_lock(&ss);
ptr = rcu_dereference(gbl_ptr);
data = ptr->data;
// ... 可以在临界区内休眠！
srcu_read_unlock(&ss, idx);

// 写者：
synchronize_srcu(&ss);  // 等待 SRCU 读者
```

SRCU 通过在每个 CPU 上维护两个计数器（`srcu_data`）来实现可休眠的读临界区。

### 6.2 Tasks RCU

Tasks RCU 用于跟踪内核线程/任务的运行状态，主要用于函数跳转（ftrace 的 `ftrace_modify_all_code`）：

```c
// Tasks RCU 等待所有任务经历一次上下文切换
synchronize_rcu_tasks();
// → 确保没有任务正在执行被追踪的代码
```

---

## 7. RCU 的软中断处理

```c
// RCU_SOFTIRQ 的处理函数：
// kernel/rcu/tree.c — 注册在 rcu_init() 中
static void rcu_core_si(void)               // tree.c:2884
{
    // 处理此 CPU 上等待的回调
    rcu_do_batch(rdp);
    // 检查是否需要启动新宽限期
    if (rcu_state.gp_flags & GP_INIT)
        rcu_gp_init();
}

// 注册为 RCU_SOFTIRQ 处理函数：
open_softirq(RCU_SOFTIRQ, rcu_core_si);     // tree.c:4887
```

---

## 8. RCU 链表操作

```c
// include/linux/rculist.h — RCU 安全的链表操作

// RCU 遍历（读者）：
rcu_read_lock();
list_for_each_entry_rcu(pos, &head, member) {
    // pos 可能正在被写者替换
    // 但能保证要么看到旧值，要么看到新值
}
rcu_read_unlock();

// RCU 替换（写者）：
new = kmalloc(sizeof(*new), GFP_KERNEL);
*new = *old;
new->data = val;

// 在链表中替换 old 为 new
list_replace_rcu(&old->list, &new->list);

// 等待所有读者退出
synchronize_rcu();
kfree(old);  // 安全释放
```

---

## 9. 性能对比

| 操作 | 延迟 | 说明 |
|------|------|------|
| rcu_read_lock | ~1ns | barrier() 或 preempt_disable |
| rcu_read_lock (PREEMPT) | ~10ns | preempt_disable + 跟踪 |
| rcu_dereference | ~5ns | READ_ONCE |
| synchronize_rcu | ~10-100μs | 等待所有 CPU 的 QS |
| call_rcu | ~100ns | 链表操作 + raise_softirq |
| SRCU read_lock | ~20ns | per-CPU 计数器操作 |
| 自旋锁读 | ~20ns + 竞争成本 | CAS (xchg) |

---

## 10. 源码文件索引

| 文件 | 内容 |
|------|------|
| `include/linux/rcupdate.h` | RCU API 声明 |
| `include/linux/rcutree.h` | Tree RCU 宏 |
| `include/linux/rculist.h` | RCU 链表操作 |
| `kernel/rcu/tree.c` | Tree RCU 核心 |
| `kernel/rcu/srcu.c` | SRCU |
| `kernel/rcu/tasks.h` | Tasks RCU |
| `kernel/rcu/rcu_segcblist.c` | 分段回调链表 |

---

## 11. 关联文章

- **01-list_head**：RCU 链表操作基础
- **24-softirq**：RCU_SOFTIRQ
- **27-cgroup**：RCU 在 cgroup 中的使用
- **186-RCU-implementation**：RCU 实现深度分析

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 12. RCU 回调的分段链表

```c
// kernel/rcu/rcu_segcblist.c
struct rcu_segcblist {
    struct rcu_head *head;           // 链表头
    struct rcu_head **tails[RCU_CBLIST_NSEGS]; // 各段尾部指针
    unsigned long gp_seq[RCU_CBLIST_NSEGS];    // 各段关联的 grace period
    long len;                         // 回调总数
    long len_lazy;                    // 延迟回收数量
};

// 分段：
// [0]: 等待下一期宽限期
// [1]: 等待当期宽限期
// [2]: 宽限期已完成，等待执行
```

---

## 13. RCU 在 slab 分配器中的使用

```c
// mm/slab_common.c — kmem_cache_free 使用 RCU

// 延迟释放（RCU 宽限期后才归还 slab）：
void kmem_cache_free(struct kmem_cache *s, void *x)
{
    // 如果对象使用 SLAB_TYPESAFE_BY_RCU：
    // → call_rcu(&object->rcu, rcu_free_callback)
    // → 在 RCU 宽限期结束后才回收
    // → 确保正在 RCU 读临界区中访问此对象的读者安全
}

// slab 分配器利用 RCU 使得：
// 1. 读者可以不加锁访问已释放的对象
// 2. 对象在宽限期结束前不会被重用（内容不会被覆盖）
// 3. SLAB_TYPESAFE_BY_RCU 保证"释放后宽限期前，对象内容不变化"
```

---

## 14. RCU 与 tickless idle

在 CPU 进入 extended quiescent state（如 tickless idle）时，RCU 通过动态 tick 机制处理：

```c
// kernel/rcu/tree.c / tree_plugin.h
// 当 CPU 进入 idle 不再产生 tick 时：
// rcu_dynticks 计数器递增，标记 CPU 处于 EQS（Extended Quiescent State）
// 在 EQS 中，RCU 认为该 CPU 持续处于 QS 状态
// 即使不产生 tick，也不会阻碍宽限期完成
// 退出 idle 时递减计数器，恢复 tick 检测
```

---

## 15. RCU 的 CPU 热插拔

```c
// CPU 下线时 rcuc 线程的处理：
// kernel/rcu/tree.c
int rcutree_prepare_cpu(unsigned int cpu)      // tree.c:4240
{
    struct rcu_data *rdp = per_cpu_ptr(&rcu_data, cpu);
    // 初始化 rdp
    rdp->gp_seq = rcu_state.gp_seq;
    rdp->cpu_no_qs.b.norm = true;
    rdp->core_needs_qs = true;
    return 0;
}

int rcutree_dead_cpu(unsigned int cpu)          // tree.c:4504
{
    // CPU 下线时迁移其回调到其他 CPU
    // 确保所有 pending 的 call_rcu 回调会被执行
    rcu_boost_kthread_setaffinity(rdp->mynode, -1);
    return 0;
}
```

---

## 16. RCU 的调试和跟踪

```bash
# 查看 RCU 状态
cat /proc/rcu/rcu_pending  # 每 CPU 的 RCU 统计
cat /proc/rcu/rcu_sched    # RCU 状态摘要

# 使用 tracepoint 跟踪 RCU
echo 1 > /sys/kernel/debug/tracing/events/rcu/enable
cat /sys/kernel/debug/tracing/trace

# CONFIG_RCU_TRACE 使能后：
# /sys/kernel/debug/rcu/ 目录包含详细统计
```

---

## 17. RCU 的经典使用——struct rcu_head

```c
// 任何需要被 RCU 释放的结构中嵌入 rcu_head
struct my_data {
    int data;
    struct rcu_head rcu;  // 用于 call_rcu
};

// 写者路径：
struct my_data *old = rcu_dereference(gbl_data);
struct my_data *new = kmalloc(...);
*new = *old;
new->data = new_value;
rcu_assign_pointer(gbl_data, new);
call_rcu(&old->rcu, my_rcu_callback);

void my_rcu_callback(struct rcu_head *rh)
{
    struct my_data *p = container_of(rh, struct my_data, rcu);
    kfree(p);
}
```

---

## 18. hlist 的 RCU 操作

```c
// include/linux/rculist.h

// RCU 遍历 hlist：
rcu_read_lock();
hlist_for_each_entry_rcu(pos, &head, member) {
    // 安全的 RCU 遍历
}
rcu_read_unlock();

// RCU 添加 hlist 头部：
hlist_add_head_rcu(n, &head);
// → smp_store_release(&first->pprev, &n->next)
// → WRITE_ONCE(h->first, n)

// RCU 删除：
hlist_del_rcu(n);
// → WRITE_ONCE(*pprev, next)  // 只毒化 prev，保留 next！
// → 读者通过 next 正向遍历依然安全
```

---

## 19. RCU 阅读建议

| 概念 | 难度 | 建议阅读 |
|------|------|---------|
| rcu_read_lock/rcu_dereference | 简单 | Documentation/RCU/whatisRCU.rst |
| synchronize_rcu | 中等 | Documentation/RCU/rcu.rst |
| Tree RCU | 困难 | kernel/rcu/tree.c |
| SRCU | 中等 | kernel/rcu/srcu.c |
| Tasks RCU | 中等 | kernel/rcu/tasks.h |
| RCU 链表 | 中等 | include/linux/rculist.h |

---

## 20. 总结

RCU 是 Linux 内核中性能最高的读者-写者同步机制。读者路径仅需两条指令（rcu_read_lock/unlock = barrier + preempt_disable），完全无原子操作和缓存行 bouncing。写者通过创建副本 + 原子指针替换 + 延迟回收（宽限期）来保证一致性。

RCU 在 Linux 内核中极其广泛——几乎所有子系统（网络、VFS、内存管理、cgroup）都使用 RCU 保护其关键数据结构。写好 RCU 代码的关键是理解宽限期的意义：`synchronize_rcu()` 等待的不只是时间，而是"所有当前正在运行的 RCU 读者都已经完成"这一事实。

EOF
wc -c ~/code/ai-programming-language-design/linux/26-rcu-analysis.md
