# Linux Kernel mutex 可睡眠互斥锁 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/mutex.h` + `include/linux/mutex_types.h` + `kernel/locking/mutex.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 更新：整合 2026-04-21 学习笔记

---

## 0. 什么是 mutex？

**mutex** 是内核最常用的**可睡眠互斥锁**：
- 一次只能一个任务持有
- 持有者才能解锁（不可跨线程/跨进程）
- 不可递归加锁
- 支持 TASK_INTERRUPTIBLE / TASK_KILLABLE 等待模式
- 可选优先级继承（CONFIG_RT_MUTEXES）

---

## 1. 核心数据结构

### 1.1 `struct mutex`（非 RT）

```c
// include/linux/mutex_types.h — 非 PREEMPT_RT 配置
context_lock_struct(mutex) {
    atomic_long_t       owner;          // 低位存 owner task_struct*，高位存标志
    raw_spinlock_t      wait_lock;      // 保护 wait_list
#ifdef CONFIG_MUTEX_SPIN_ON_OWNER
    struct optimistic_spin_queue osq;  // MCS 自旋锁（减少 cacheline 竞争）
#endif
    struct mutex_waiter *first_waiter __guarded_by(&wait_lock);  // 等待链表头
#ifdef CONFIG_DEBUG_MUTEXES
    void               *magic;           // 调试：魔数
#endif
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    struct lockdep_map  dep_map;       // 死锁检测
#endif
};

// 静态初始化
#define DEFINE_MUTEX(mutexname) \
    struct mutex mutexname = __MUTEX_INITIALIZER(mutexname)

#define __MUTEX_INITIALIZER(mutexname)                \
    {                                               \
        .owner = ATOMIC_LONG_INIT(0),               \
        .wait_lock = __RAW_SPIN_LOCK_UNLOCKED(...),\
        .wait_list = LIST_HEAD_INIT(mutexname.wait_list) \
    }
```

### 1.2 owner 字段编码

```c
// kernel/locking/mutex.c — owner 编码规则
// 低位用于标记：
//   bit 0 = 1 → MUTEX_FLAG_PICKUP（锁被拾取，正在交接）
//   bit 0 = 0 → 正常状态，剩余位存 task_struct* 地址

static inline struct task_struct *__owner_task(unsigned long owner)
{
    return (struct task_struct *)(owner & ~MUTEX_FLAGS);
}

#define MUTEX_FLAGS 0x01

// 判断是否已锁定
static inline bool __mutex_locked(struct mutex *lock)
{
    return atomic_long_read(&lock->owner) != 0;
}
```

---

## 2. 快速路径 vs 慢路径

```
mutex_lock() 路径：

1. __mutex_trylock_fast() — 乐观自旋
   atomic_long_try_cmpxchg_acquire(&lock->owner, &zero, curr)
   → 如果 owner == 0（未锁定），原子地设置为 current → 加锁成功！
   → O(1)，无需睡眠

2. __mutex_lock_slowpath() — 慢路径（抢锁失败）
   1. spin_lock(wait_lock)
   2. 检查是否已解锁（其他 CPU 刚释放）→ 快速路径
   3. add_wait_queue() 加入 wait_list
   4. 设置状态为 TASK_UNINTERRUPTIBLE
   5. spin_unlock(wait_lock)
   6. schedule() — 睡眠让出 CPU
```

```
mutex_unlock() 路径：

1. __mutex_unlock_fast() — 快速路径
   atomic_long_try_cmpxchg_release(&lock->owner, &curr, 0)
   → 如果 current 是持有者，原子地设置为 0 → 解锁成功！
   → O(1)

2. __mutex_unlock_slowpath() — 慢路径（有等待者）
   1. spin_lock(wait_lock)
   2. 如果有等待者：
        ww_mutex → 调用 handoff 交接
        普通 mutex → 唤醒 first_waiter
   3. spin_unlock(wait_lock)
```

---

## 3. 乐观自旋（CONFIG_MUTEX_SPIN_ON_OWNER）

```c
// kernel/locking/mutex.c — mutex_spin_on_owner
static int mutex_spin_on_owner(struct mutex *lock,
                               struct mutex_waiter *waiter)
{
    // 如果锁持有者在运行 → 继续自旋等待
    // 如果锁持有者不运行（睡眠、迁移）→ 退出自旋，睡眠
    for (;;) {
        if (!owner || !osq_locked(&lock->osq))
            break;
        cpu_relax();
    }
}
```

**为什么乐观自旋有效**：
- 锁的持有时间通常很短（几个指令）
- 自旋等待比上下文切换便宜（schedule() 开销约 10-50μs）
- 自旋期间锁可能已释放，无需睡眠

---

## 4. wait_list 与 FIFO 唤醒

```c
// kernel/locking/mutex.c — 添加等待者
static void __mutex_add_waiter(struct mutex *lock,
                                struct mutex_waiter *waiter)
{
    struct mutex_waiter *first_waiter = mutex_waiter_last(lock);
    list_add_tail(&waiter->node, &lock->wait_list);
    if (!first_waiter)  // 第一个等待者
        lock->owner = (unsigned long)(waiter->task | MUTEX_FLAG_WAITERS);
}

// 唤醒等待者（FIFO，不是优先级）
static void __mutex_unlock_slowpath(struct mutex *lock)
{
    // 取出 wait_list 第一个等待者
    waiter = list_first_entry(&lock->wait_list, struct mutex_waiter, node);
    wake_up_process(waiter->task);  // 唤醒
}
```

---

## 5. ww_mutex（ Wound-Wait 死锁避免）

```c
// 内核还支持 ww_mutex，用于多锁同时获取场景（如文件系统）
// Wound-Wait 协议：
//   - 事务 A 等锁，事务 B 持有 → A 等待
//   - 事务 A 持锁，事务 B 要获取 → B 被 wounded（释放已有锁）
//   - 避免循环等待死锁

struct ww_mutex {
    struct mutex base;
    // ...
};
```

---

## 6. API 总览

```c
// 加锁
void mutex_lock(struct mutex *lock);                          // 不可中断
int mutex_lock_interruptible(struct mutex *lock);             // 可被信号中断
int mutex_lock_killable(struct mutex *lock);                 // 可被 kill 信号中断
void mutex_lock_nested(struct mutex *lock, unsigned subclass); // 分层锁
bool mutex_trylock(struct mutex *lock);                      // 非阻塞尝试

// 解锁
void mutex_unlock(struct mutex *lock);

// 查询
bool mutex_is_locked(struct mutex *lock);                    // 是否已锁定
bool mutex_trylock(struct mutex *lock);                      // 尝试加锁
```

---

## 7. 真实内核使用案例

### 7.1 inode 锁（`fs/inode.c`）

```c
// 每个 inode 有 i_mutex
struct inode {
    // ...
    struct mutex i_mutex;  // inode 操作锁
};

// 使用
mutex_lock(&inode->i_mutex);
// 修改 inode
mutex_unlock(&inode->i_mutex);
```

### 7.2 模块加载（`kernel/module.c`）

```c
// 模块列表操作
static DEFINE_MUTEX(module_mutex);  // 保护模块链表

mutex_lock(&module_mutex);
list_add_rcu(&mod->list, &modules);
mutex_unlock(&module_mutex);
```

### 7.3 内存管理（`mm/mmap.c`）

```c
// mmap_sem（部分已迁移到 mmap_lock）
static DEFINE_MUTEX(mm->mmap_lock);
```

---

## 8. vs spinlock

| 特性 | spinlock | **mutex** |
|------|---------|-----------|
| 上下文 | 中断、原子、NMI | **进程上下文** |
| 睡眠 | **不允许** | 允许（schedule） |
| 持有时间 | 极短（几个指令） | 任意长度 |
| 递归 | 不允许 | 不允许 |
| 优先级继承 | 无 | **支持（CONFIG_RT_MUTEXES）** |
| 中断上下文 | ✅ | ❌ |
| 死锁检测（lockdep）| ✅ | **✅** |

---

## 9. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| owner 原子变量 + wait_lock | 快速路径无锁（cmpxchg），争用时用自旋锁 |
| MCS osq | 减少多 CPU cacheline 竞争（每个 CPU 有自己的 MCS 节点）|
| wait_list FIFO | 先到先服务（公平），避免饥饿 |
| spin_on_owner | 锁持有时间通常很短，自旋比睡眠/唤醒便宜 |
| RT-MUTEX 支持 | 优先级继承解决优先级反转问题 |

---

## 10. 参考

| 文件 | 内容 |
|------|------|
| `include/linux/mutex.h` | API 声明、宏定义 |
| `include/linux/mutex_types.h` | mutex 结构体（RT / non-RT） |
| `include/linux/kref.h` | kref 引用计数 |
| `kernel/locking/mutex.c` | 快速路径（trylock/unlock）、慢路径实现 |
