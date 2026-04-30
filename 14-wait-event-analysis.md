# Linux Kernel wait_event 可睡眠条件等待 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/wait.h` + `kernel/sched/wait.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-27 学习笔记

---

## 0. 什么是 wait_event？

**wait_event** 是一组宏，把"条件等待 + 睡眠 + 唤醒"封装成一行代码。

**核心场景**：
- 驱动程序 `read()` 等待数据到达
- `poll()` 等待文件描述符就绪
- 调度器内部条件等待

**与 completion 的区别**：
- `wait_event`：通用条件等待，条件可以是任意表达式
- `completion`：一次性完成信号，语义更简单

---

## 1. 核心数据结构

```c
// include/linux/wait.h — 等待队列头
struct wait_queue_head {
    spinlock_t lock;              // 保护队列
    struct list_head head;        // 等待者链表
};

typedef struct wait_queue_head wait_queue_head_t;

#define DECLARE_WAIT_QUEUE_HEAD(name) \
    wait_queue_head_t name = __WAIT_QUEUE_HEAD_INITIALIZER(name)

#define __WAIT_QUEUE_HEAD_INITIALIZER(name) \
    { .lock = __SPIN_LOCK_UNLOCKED(name.lock), \
      .head = { &name.head, &name.head } }
```

**等待队列项**（每个等待者一个）：
```c
// include/linux/wait.h — wait_queue_entry
struct wait_queue_entry {
    unsigned int flags;           // WQ_FLAG_EXCLUSIVE（独占等待）
    void *private;                // 通常是 task_struct*
    wait_queue_func_t func;       // 唤醒回调（default: autoremove_wake_function）
    struct list_head entry;       // 挂到 wait_queue_head->head
};
```

---

## 2. wait_event 宏体系

### 2.1 完整宏列表

```c
// include/linux/wait.h

// 不可中断（最常用）
wait_event(wq_head, condition)
wait_event_timeout(wq_head, condition, timeout)
wait_event_exclusive(wq_head, condition)   // 只唤醒一个

// 可被信号打断
wait_event_interruptible(wq_head, condition)
wait_event_interruptible_timeout(wq_head, condition, timeout)

// 可被 kill
wait_event_killable(wq_head, condition)

// 可冻结（系统 suspend 时自动唤醒）
wait_event_freezable(wq_head, condition)
wait_event_freezable_exclusive(wq_head, condition)

// IO 调度专用
io_wait_event(wq_head, condition)
```

### 2.2 wait_event 实现

```c
// include/linux/wait.h:329 — __wait_event 宏
#define __wait_event(wq_head, condition) \
    (void)___wait_event(&(wq_head), condition, TASK_UNINTERRUPTIBLE, 0, 0, schedule)

// include/linux/wait.h:302 — ___wait_event 核心宏
#define ___wait_event(wq_head, condition, state, exclusive, ret, cmd) \
    long __ret = 0; \
    might_sleep(); \
    for (;;) { \
        if (condition) \
            break; \
        if (signal_pending(current)) { \
            __ret = -ERESTARTSYS; \
            break; \
        } \
        cmd;   /* 通常是 schedule() */ \
    } \
    __ret;
```

### 2.3 wait_event_interruptible 实现

```c
// include/linux/wait.h — 可中断版本
#define wait_event_interruptible(wq_head, condition) \
({ \
    int __ret = 0; \
    might_sleep(); \
    if (!(condition)) \
        __ret = __wait_event_interruptible(wq_head, condition); \
    __ret; \
})

// __wait_event_interruptible 内部检查 signal_pending
// 如果收到信号，返回 -ERESTARTSYS
```

---

## 3. prepare_to_wait + finish_wait 模式

### 3.1 手动控制（驱动开发用）

```c
// include/linux/wait.h — 底层 API
void prepare_to_wait(struct wait_queue_head *wq_head,
                     struct wait_queue_entry *wq_entry,
                     int state);        // TASK_INTERRUPTIBLE / TASK_UNINTERRUPTIBLE

void finish_wait(struct wait_queue_head *wq_head,
                struct wait_queue_entry *wq_entry);

// 使用模式：
void my_driver_wait(struct driver_data *drv)
{
    struct wait_queue_entry wait;
    init_waitqueue_entry(&wait, current);

    prepare_to_wait(&drv->wait_q, &wait, TASK_INTERRUPTIBLE);
    if (!data_available(drv))
        schedule();           // 睡眠
    finish_wait(&drv->wait_q, &wait, TASK_INTERRUPTIBLE);
    // 处理数据
}

// 唤醒端：
void my_driver_interrupt(...)
{
    data_available = 1;
    wake_up(&drv->wait_q);    // 唤醒一个
}
```

### 3.2 WQ_FLAG_EXCLUSIVE — 独占等待

```c
// include/linux/wait.h
#define WQ_FLAG_EXCLUSIVE   0x01   // 独占等待标志

// 等待者标记为 EXCLUSIVE：
prepare_to_wait_exclusive(&wq, &wq_entry, TASK_UNINTERRUPTIBLE);

// 唤醒时：
wake_up(&wq)  // 唤醒一个 EXCLUSIVE + 所有非 EXCLUSIVE

// 这样设计避免惊群（thundering herd）：
// - 多个非 EXCLUSIVE 等待者可同时被唤醒
// - EXCLUSIVE 每次只唤醒一个
```

---

## 4. wake_up 系列

```c
// include/linux/wait.h — wake_up 家族
wake_up(x)                  // 唤醒一个（优先 EXCLUSIVE）
wake_up_all(x)              // 唤醒全部
wake_up_locked(x)           // 在已持锁状态下唤醒
wake_up_nr(x, nr)           // 唤醒最多 nr 个（nr=0 全部）
wake_up_interruptible(x)     // 只唤醒可中断的
wake_up_sync(x)             // 同步唤醒（不 schedule）
```

---

## 5. 完整状态机

```
等待者：
  prepare_to_wait(&wq, &entry, TASK_INTERRUPTIBLE)
    → set_current_state(TASK_INTERRUPTIBLE)
    → add_wait_queue(&wq, &entry)   // 加入链表

  schedule()   // 真正睡眠

  wake_up(&wq) → try_to_wake_up(entry.private)
    → entry.func(entry)   // 默认：autoremove_wake_function
    → finish_wait(&wq, &entry)
      → list_del(&entry.entry)
      → set_current_state(TASK_RUNNING)

唤醒者：
  条件满足 → wake_up(&wq) → 遍历链表 → 唤醒合适任务
```

---

## 6. wait_on_bit — 位等待

```c
// 特殊的 bit wait，用于等待某个内存位的值变化
wait_on_bit(void *word, int bit, unsigned mode);
// mode: TASK_INTERRUPTIBLE / TASK_UNINTERRUPTIBLE

// 内核内部大量使用：
//   wait_on_bit(&inode->i_state, I_NEW);
//   inode 就绪后 set_bit(I_NEW, &inode->i_state) → wake_up_bit
```

---

## 7. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| `condition` 是宏参数 | 每次循环重新检查，防止虚假唤醒 |
| `might_sleep()` | 编译期检测是否在不可睡眠上下文调用 |
| `prepare_to_wait` / `finish_wait` 分离 | 允许在睡眠前执行额外操作 |
| `WQ_FLAG_EXCLUSIVE` | 避免惊群：唤醒一个 EXCLUSIVE 后其他可继续睡眠 |
| `swait` vs `wait` | RT 下用 swait 支持优先级继承 |

---

## 8. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/wait.h` | wait_event 系列宏、wait_queue_entry |
| `kernel/sched/wait.c` | `prepare_to_wait`、`finish_wait`、`wake_up` 实现 |
| `include/linux/swait.h` | `swait_queue_head`（RT 用）|
