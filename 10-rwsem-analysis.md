# Linux Kernel rwsem 读写信号量 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/rwsem.h` + `kernel/locking/rwsem.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-23 学习笔记

---

## 0. 什么是 rwsem？

**rw_semaphore** 是支持**多读者单写者**的信号量：
- 任意数量读者可同时持有读锁（读-读不互斥）
- 写者独占（写-读、写-写都互斥）
- 适合**读多写少**场景（page cache、dentry、mmap）

---

## 1. 核心数据结构

```c
// include/linux/rwsem.h:48 — Linux 7.0 最新结构
context_lock_struct(rw_semaphore) {
    atomic_long_t count;       // 读者计数 + 写者标志 + 等待标志
    atomic_long_t owner;       // 当前持有者（writer task_struct* 或 reader count）
#ifdef CONFIG_RWSEM_SPIN_ON_OWNER
    struct optimistic_spin_queue osq;  // MCS 乐观自旋队列
#endif
    raw_spinlock_t wait_lock;           // 保护 wait_list
    struct list_head wait_list;         // 等待者链表
#ifdef CONFIG_DEBUG_RWSEM
    const char *name;
    struct lockdep_map dep_map;
#endif
};
```

---

## 2. count 字段编码

```c
// include/linux/rwsem.h:69-70
#define RWSEM_UNLOCKED_VALUE      0UL
#define RWSEM_WRITER_LOCKED      (1UL << 0)   // bit 0 = 写者持有标志

// count 布局：
//  bit 0         : RWSEM_WRITER_LOCKED（写者持有）
//  bit 1         : 等待的写者标志
//  bit 2-31/63   : 读者计数（正数）或等待读者数

// 状态解读：
//   count = 0              → 未锁定
//   count > 0              → count 位读者持有（读锁）
//   count & RWSEM_WRITER_LOCKED → 有写者持有
```

---

## 3. owner 字段与状态机

```c
// kernel/locking/rwsem.c:702-706
enum owner_state {
    OWNER_NULL         = 1 << 0,   // owner = NULL，无人持有
    OWNER_WRITER       = 1 << 1,   // 有写者持有
    OWNER_READER       = 1 << 2,   // 有读者持有
    OWNER_NONSPINNABLE = 1 << 3,   // 不可自旋（避免浪费 CPU）
};

// rwsem_owner_state() — 从 owner 字段推断状态
static inline enum owner_state rwsem_owner_state(struct rw_semaphore *sem)
{
    if (flags & RWSEM_NONSPINNABLE)
        return OWNER_NONSPINNABLE;
    if (flags & RWSEM_READER_OWNED)
        return OWNER_READER;
    return owner ? OWNER_WRITER : OWNER_NULL;
}
```

---

## 4. wait_list 管理

```c
// kernel/locking/rwsem.c:338 — 等待者节点
struct rwsem_waiter {
    struct list_head list;      // 接入 wait_list
    struct task_struct *task;   // 等待的任务
    enum rwsem_waiter_type type;  // RWSEM_WAITING_FOR_READ / WRITE
    unsigned long timeout;     // 超时
    bool handoff_set;          // 写者优先交接标志
};

// wait_list 链表顺序：
//  队首 → 写者(优先) → 读者堆叠 → 写者 → 读者 → ...
//
// 写者优先规则：
//   - up_write 时唤醒队首（如果队首是写者）
//   - up_read 时如果所有读者都离开，唤醒队首
//   - 读者不会唤醒写者（避免写饥饿）
```

---

## 5. 核心 API

```c
// 读锁
void down_read(struct rw_semaphore *sem);              // 获取读锁（阻塞）
int down_read_trylock(struct rw_semaphore *sem);       // 尝试获取读锁
void up_read(struct rw_semaphore *sem);                // 释放读锁

// 写锁
void down_write(struct rw_semaphore *sem);             // 获取写锁（阻塞）
int down_write_trylock(struct rw_semaphore *sem);      // 尝试获取写锁
void up_write(struct rw_semaphore *sem);                // 释放写锁

// 升降级
int downgrade_write(struct rw_semaphore *sem);         // 写锁降级为读锁
```

---

## 6. 乐观自旋（Optimistic Spinning）

```c
// kernel/locking/rwsem.c:840 — 乐观自旋核心
static bool rwsem_optimistic_spin(struct rw_semaphore *sem)
{
    bool taken = false;
    int prev_owner_state = OWNER_NULL;
    int loop = 0;
    u64 rspin_threshold = 0;

    // 1. 先尝试获取 MCS 队列锁（osq）
    if (!osq_lock(&sem->osq))
        return false;  // 另一线程已在 osq 中

    // 2. 检查是否可以自旋
    for (;;) {
        enum owner_state owner_state = rwsem_owner_state(sem);

        // OWNER_NULL = 无持有者 → 直接抢锁
        if (owner_state == OWNER_NULL) {
            if (atomic_long_try_cmpxchg(&sem->count, &orig, curr)) {
                rwsem_set_owner(sem);
                taken = true;
            }
            break;
        }

        // OWNER_WRITER = 写者持有 → 检查是否在运行
        if (owner_state == OWNER_WRITER) {
            if (rwsem_spin_on_owner(sem))  // 检查 owner 是否在 CPU 上运行
                continue;  // 仍在运行，继续自旋
            break;  // 写者已睡眠，退出自旋
        }

        // OWNER_READER = 读者持有 → 检查读者数
        if (owner_state == OWNER_READER) {
            // 短暂自旋，等待读者释放
            if (++loop > 10)
                break;
            cpu_relax();
            continue;
        }

        // OWNER_NONSPINNABLE → 不可自旋，直接退出
        break;
    }

    osq_unlock(&sem->osq);
    return taken;
}
```

---

## 7. up_write 唤醒流程

```c
// kernel/locking/rwsem.c — up_write 核心路径
void up_write(struct rw_semaphore *sem)
{
    // 1. 清除 owner
    rwsem_clear_owner(sem);

    // 2. 尝试原子地解锁
    //    如果 count 从 WRITER_LOCKED → 0，无等待者 → 完成
    //    如果有等待者，失败，进入慢路径
    if (atomic_long_try_cmpxchg(&sem->count, &orig, orig - RWSEM_WRITER_LOCKED)) {
        if (unlikely(!list_empty(&sem->wait_list)))
            rwsem_wake(sem);  // 唤醒等待者
    }
}

// rwsem_wake — 唤醒队首
// 1. 取 wait_list 第一个等待者
// 2. 如果是写者 → 只唤醒一个（写-写互斥）
// 3. 如果是读者 → 唤醒所有连续读者（批量）
```

---

## 8. vs spinlock / mutex

| 特性 | spinlock | **rwsem** | mutex |
|------|---------|-----------|-------|
| 读者并发 | ❌ 互斥 | **✅ 可多读** | ❌ 互斥 |
| 写者独占 | ✅ | **✅** | ✅ |
| 持有时间 | 极短 | 任意 | 任意 |
| 中断上下文 | ✅ | ❌ | ❌ |
| 睡眠 | ❌ | **✅** | ✅ |
| 优先级继承 | ❌ | **✅（via RT-MUTEX）** | ✅ |

---

## 9. 真实内核使用案例

### 9.1 mmap_lock（`mm/mmap.c`）

```c
// 地址空间读锁
struct mm_struct {
    struct rw_semaphore mmap_lock;  // 保护 mmap
};

// 读操作（可并发）
down_read(&mm->mmap_lock);
// 遍历 VMA、查找地址等
up_read(&mm->mmap_lock);

// 写操作（独占）
down_write(&mm->mmap_lock);
// mmap、munmap、brk 等修改地址空间
up_write(&mm->mmap_lock);
```

### 9.2 inode 锁（`fs/inode.c`）

```c
// inode 读写锁
down_read(&inode->i_rwsem);    // 读取 inode 属性
up_read(&inode->i_rwsem);

down_write(&inode->i_rwsem);   // 修改 inode
up_write(&inode->i_rwsem);
```

---

## 10. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| count 正数 = 读者数 | 简单判断：count > 0 且无 WRITER_LOCKED → 有读者持有 |
| owner 字段 | optimistic spinning 需要知道持有者是否在运行 |
| osq MCS 队列 | 减少多核自旋时的 cacheline 竞争 |
| 读者堆叠 | 多个读者连续排队时批量唤醒，减少上下文切换 |
| 写者优先 | 避免写者饥饿（读者可以并发，唤醒一个写者代价不大）|

---

## 11. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/rwsem.h` | rw_semaphore 定义、API 声明 |
| `kernel/locking/rwsem.c` | 完整实现（rwsem_optimistic_spin、rwsem_wake、rwsem_mark_wake）|
| `kernel/locking/rwsem.c:728` | `rwsem_can_spin_on_owner` |
| `kernel/locking/rwsem.c:767` | `rwsem_spin_on_owner` |
| `kernel/locking/rwsem.c:840` | `rwsem_optimistic_spin` |
| `kernel/sched/sched.h` | OSQ（optimistic spin queue）MCS 实现 |
