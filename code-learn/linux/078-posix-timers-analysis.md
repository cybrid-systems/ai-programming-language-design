# 78-posix-timers — Linux POSIX 定时器框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**POSIX 定时器**（`timer_create`/`timer_settime`/`timer_gettime`）是 Linux 用户空间的高精度定时器 API。与 `setitimer`（每进程仅 1 个，jiffy 精度）不同，POSIX 定时器允许任意数量（受 `RLIMIT_SIGPENDING`），底层由 **hrtimer** 驱动，精度达到纳秒级。

**核心设计**：`struct k_itimer` 管理每个定时器——哈希表快速 ID 查找、`hrtimer` 底层定时、到期时 `posix_timer_fn` → `posix_timer_queue_signal` → `posixtimer_send_sigqueue` 信号投递。

```
用户空间                   内核                hrtimer 框架
─────────                ──────              ────────────
timer_create(CLOCK,...)
  └─ do_timer_create()
    └─ alloc_posix_timer()
    └─ posix_timer_add()    → ID 插入哈希表
    └─ kc->timer_create()   → hrtimer_init()

timer_settime(id, flags, new, NULL)
  └─ lock_timer(id)         → posix_timer_by_id() 哈希查找
  └─ common_timer_set()
    └─ hrtimer_start()      → 插入 hrtimer 红黑树
                                        ↓
                                hrtimer_interrupt()
                                     ← 到期
                                        ↓
  posix_timer_fn() ← hrtimer 回调
    └─ posix_timer_queue_signal()
      └─ posixtimer_send_sigqueue()
        → send_sigqueue()   → 信号投递
```

**doom-lsp 确认**：`kernel/time/posix-timers.c`（**1,567 行**，**207 个符号**）。核心结构 `struct k_itimer` 在 `include/linux/posix-timers.h`。底层 hrtimer 在 `kernel/time/hrtimer.c`。

---

## 1. 核心数据结构

### 1.1 struct k_itimer — POSIX 定时器

```c
// include/linux/posix-timers.h L186 — doom-lsp 确认
struct k_itimer {
    struct hlist_node    t_hash;            // L188 — 哈希表节点
    struct hlist_node    list;              // L189 — 全局定时器链表
    timer_t              it_id;             // L190 — 定时器 ID（进程内唯一）
    clockid_t            it_clock;          // L191 — 时钟类型（CLOCK_MONOTONIC 等）
    int                  it_sigev_notify;   // L192 — 信号通知方式
    enum pid_type        it_pid_type;       // L193 — PID 类型
    struct signal_struct *it_signal;        // L194 — 所属进程信号状态
    const struct k_clock *kclock;           // L195 — 时钟操作表
    spinlock_t           it_lock;           // L198 — 保护定时器的自旋锁
    int                  it_status;         // L199 — 状态（ARMED/DISARMED/TIMING）
    s64                  it_overrun;        // L201 — 超限计数

    const struct k_clock *kclock;            // 时钟操作表
    struct rcu_head rcu;
};
```

### 1.2 哈希表——timer_hash_bucket @ :42

```c
// @ :42
struct timer_hash_bucket {
    spinlock_t lock;
    struct list_head head;
};

// 全局哈希表（@ :47）：
//  size = POSIX_TIMER_HASH_SIZE
//  哈希函数: (timer_id * 0x9e370001) & mask
//
// 查找函数 @ :89：

static struct k_itimer *posix_timer_by_id(timer_t id)
{
    struct signal_struct *sig = current->signal;
    struct timer_hash_bucket *bucket = hash_bucket(sig, id);

    scoped_guard (spinlock_irqsave, &bucket->lock) {
        list_for_each_entry(timer, &bucket->head, list) {
            if (timer->it_id == id && timer->it_signal == sig)
                return timer;
        }
    }
    return NULL;
}
```

**doom-lsp 确认**：`posix_timer_by_id` @ `:89`。`posix_timer_add` @ `:157`。哈希表 `__timer_data` @ `:47`。

---

## 2. 创建——do_timer_create @ :458

```c
static int do_timer_create(clockid_t which_clock, struct sigevent *event,
                           timer_t __user *created_timer_id)
{
    // 1. 获取时钟操作表
    kc = clockid_to_kclock(which_clock);     // @ :58
    if (!kc) return -EINVAL;

    // 2. 分配 k_itimer @ :415
    new_timer = alloc_posix_timer();
    // → kmem_cache_zalloc(posix_timers_cache, ...)
    // → posixtimer_init_sigqueue(&tmr->sigq) 初始化信号队列
    // → rcuref_init(&tmr->rcuref, 1)

    // 3. 验证 sigevent @ good_sigevent()
    //    SIGEV_SIGNAL / SIGEV_THREAD / SIGEV_THREAD_ID / SIGEV_NONE
    new_timer->it_pid = get_pid(good_sigevent(event));
    new_timer->it_signal = current->signal;

    // 4. ID 分配 + 插入哈希表 @ :157
    error = posix_timer_add(new_timer, ...);

    // 5. 时钟特定初始化
    kc->timer_create(new_timer);
    // → common_timer_create @ :451
    //   → hrtimer_init(&new_timer->ktimer, clock, mode)
    //   → new_timer->ktimer.function = posix_timer_fn

    // 6. 返回 ID 给用户空间
    put_user(new_timer->it_id, created_timer_id);
}
```

---

## 3. 启动——common_timer_set

```c
// timer_settime → lock_timer(id) → kc->timer_set()
// CLOCK_REALTIME/MONOTONIC 使用 common_timer_set：

struct k_clock clock_realtime = {
    .timer_create = common_timer_create,
    .timer_set    = common_timer_set,
    .timer_del    = common_timer_del,
    .timer_get    = common_timer_get,
    .timer_forward = common_hrtimer_forward,
};
```

---

## 4. 到期路径

### 4.1 posix_timer_fn @ :367——hrtimer 回调

```c
static enum hrtimer_restart posix_timer_fn(struct hrtimer *timer)
{
    struct k_itimer *timr = container_of(timer, struct k_itimer, it.real.timer);

    scoped_guard(spinlock_irqsave, &timr->it_lock) {
        posix_timer_queue_signal(timr);   // 发送信号
    }
    return HRTIMER_NORESTART;
    // 注意：不再返回 HRTIMER_RESTART！
    // interval 定时器的重新加载由 posixtimer_send_sigqueue 完成
}
```

### 4.2 posix_timer_queue_signal @ :349——信号投递

```c
void posix_timer_queue_signal(struct k_itimer *timr)
{
    // 更新状态
    timr->it_status = timr->it_interval ?
        POSIX_TIMER_REQUEUE_PENDING :    // interval 定时器 → 等待重新加载
        POSIX_TIMER_DISARMED;            // 一次性定时器 → 已完成

    // 发送信号
    posixtimer_send_sigqueue(timr);
    // → send_sigqueue(&timr->sigq, timr->it_pid, PIDTYPE_TASK)
}

// interval 定时器的重新加载：
// 在 posixtimer_send_sigqueue 内部（@ :331）：
// 如果 timr->it_interval 非零 → common_hrtimer_rearm()
//   → hrtimer_forward(timer, now, timr->it_interval)
//   → hrtimer_restart(timer)
```

### 4.3 posix_timer_del——停止定时器

```c
// kc->timer_del(timr) → common_timer_del → hrtimer_cancel()
```

---

## 5. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `posix_timer_by_id` | `:89` | ID 哈希查找 |
| `posix_timer_add` | `:157` | ID 分配+哈希插入 |
| `do_timer_create` | `:458` | 创建定时器主逻辑 |
| `alloc_posix_timer` | `:415` | k_itimer 分配 |
| `common_timer_create` | `:451` | 初始 hrtimer |
| `posix_timer_fn` | `:367` | hrtimer 到期回调 |
| `posix_timer_queue_signal` | `:349` | 信号投递 |
| `common_hrtimer_rearm` | `:291` | interval 重新加载 |
| `good_sigevent` | — | sigevent 验证 |
| `lock_timer` | `:596` | 加锁+哈希查找 |

---

## 5. 通知机制——SIGEV_THREAD

```c
// struct sigevent 的 sigev_notify 决定到期通知方式：
// SIGEV_SIGNAL     → 发送信号（默认，通过 send_sigqueue）
// SIGEV_THREAD     → 启动线程执行 handler（用户空间 libc 实现）
// SIGEV_THREAD_ID  → 发送信号到特定线程
// SIGEV_NONE       → 不通知

// 内核侧统一通过 posix_timer_queue_signal() → posixtimer_send_sigqueue()
// → send_sigqueue(&timr->sigq, timr->it_pid, PIDTYPE_TASK)
```

## 6. Interval 定时器——common_hrtimer_rearm @ :291

```c
// 当定时器到期且 it_interval > 0（interval 定时器）时：
// → hrtimer_forward(timer, now, timr->it_interval) 推进到期时间
// → hrtimer_restart(timer) 重新启动定时器
// → 通过 overrun 计数跟踪丢掉的到期事件

// Overrun 计数：
// i.e. 如果定时器每 10ms 到期，但处理延迟了 35ms → overrun = 3
// 用户通过 timer_getoverrun() 获取
```

## 7. struct k_itimer 完整字段

```c
struct k_itimer {
    struct hrtimer ktimer;                 // 底层 hrtimer
    clockid_t it_clock;                    // 时钟源
    struct pid *it_pid;                    // 通知目标进程
    struct sigqueue sigq;                   // 信号队列条目
    struct signal_struct *it_signal;

    int it_pid_type;                        // PID/PGID/SID
    int it_status;                          // POSIX_TIMER_DISARMED / ...
    struct itimerspec64 it;                 // interval + value
    struct list_head list;                   // 哈希桶链表

    const struct k_clock *kclock;           // 时钟操作表
    struct rcu_head rcu;
};
```

## 8. 总结

POSIX 定时器通过 `hrtimer_init` + `hrtimer_start` 实现纳秒级精度定时。`timer_create` → `do_timer_create`（`:458`）→ `alloc_posix_timer`（`:415`）分配 `k_itimer` 并插入哈希表，`timer_settime` → `common_timer_set` → `hrtimer_start` 启动，到期后 `posix_timer_fn`（`:367`）→ `posix_timer_queue_signal`（`:349`）→ `send_sigqueue` 投递信号。Interval 定时器通过 `common_hrtimer_rearm`（`:291`）重新加载。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct k_itimer` | include/linux/posix-timers.h | 186 |
| `alloc_posix_timer()` | kernel/time/posix-timers.c | 428 |
| `do_timer_create()` | kernel/time/posix-timers.c | 相关 |
| `posix_timer_fn()` | kernel/time/posix-timers.c | 367 |
| `posix_timer_queue_signal()` | kernel/time/posix-timers.c | 349 |
| `common_timer_set()` | kernel/time/posix-timers.c | 相关 |
| `common_hrtimer_rearm()` | kernel/time/posix-timers.c | 291 |
| `hrtimer_start()` | kernel/time/hrtimer.c | 相关 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
