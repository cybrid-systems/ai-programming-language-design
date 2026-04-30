# 12-futex — 快速用户空间互斥锁深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/futex/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**futex（Fast Userspace Mutex）** 是 Linux 的高性能同步机制，核心思想：**尽量在用户空间完成操作，只有在争用时才进入内核**。零系统调用开销在无竞争时。

---

## 1. 工作原理

```
线程 T1（无竞争）：
  CMXCas(&lock, 0, 1)  → 原子指令，用户空间，O(1)
  如果成功 → 获取锁，结束

线程 T2（持有锁）：
  CMXCas(&lock, 1, 0)  → 用户空间释放
  futex(WAKE, &lock)   → 通知内核唤醒等待者

线程 T1（竞争失败）：
  futex(WAIT, &lock, expected=1) → 进入内核等待
  ↓
  schedule() → 睡眠
  ↓
  被 wake 后，返回用户空间
  CMXCas(&lock, 0, 1)  → 重试获取
```

---

## 2. 核心数据结构

### 2.1 futex_key — futex 标识

```c
// include/linux/futex.h:46 — futex_key
struct futex_key {
    union {
        struct {
            unsigned long pgoff;     // VMA 内页偏移
            unsigned long address;    // 用户空间地址
        } shared;
        struct {
            u32  iuid;             // inode ID (mm_struct ID)
            u32  iseq;            // inode generation
            unsigned long offset;   // VMA 内偏移
        } private;
    };
    struct mm_struct *mm;          // 进程内存描述符
};

// key 是 futex 值的唯一标识
// 同一个地址的 futex 总是有相同的 key（无论哪个进程）
```

### 2.2 futex_q — futex 等待项

```c
// kernel/futex/futex-waitwake.c — futex_q
struct futex_q {
    struct plist_node        list;   // 接入红黑树的节点
    struct futex_key         key;    // futex 标识
    struct futex_operations  *opt;  // 操作函数（PI 或普通）
    void                   *private; // 私有数据（通常是 task_struct）
    struct hrtimer_sleeper  *sleeper; // 超时定时器
    struct task_struct     *task;   // 等待的进程
};
```

---

## 3. 系统调用

### 3.1 sys_futex — 系统调用入口

```c
// kernel/futex/futex.c — sys_futex
SYSCALL_DEFINE6(futex, u32 __user *, uaddr, int, op, u32, val,
                 const struct timespec __user *, utime, u32 __user *, uaddr2, u32, val3)
{
    // op & FUTEX_CMD_MASK = 操作码
    // val = 操作数（WAIT 的期望值，WAKE 的线程数等）

    switch (op & FUTEX_CMD_MASK) {
    case FUTEX_WAIT:
        return futex_wait(uaddr, val, utime, uaddr2, val3);
    case FUTEX_WAKE:
        return futex_wake(uaddr, val);
    case FUTEX_FD:
        return futex_fdt(uaddr, val);
    case FUTEX_REQUEUE:
        return futex_requeue(uaddr, uaddr2, val, val3);
    }
}
```

---

## 4. futex_wait — 等待

### 4.1 futex_wait

```c
// kernel/futex/futex-waitwake.c — futex_wait
static int futex_wait(u32 __user *uaddr, u32 val, u32 bitset,
                      struct timespec *timeout)
{
    struct futex_q q;
    u32 val2;

    // 1. 将用户地址转换为 futex_key
    if (futex_get_user_key(uaddr, &q.key))
        return -EINVAL;

    // 2. 设置超时定时器
    if (timeout) {
        hrtimer_init_sleeper(&q.timer, CLOCK_REALTIME);
        hrtimer_start_expires(&q.timer, HRTIMER_MODE_ABS);
    }

    // 3. 加入哈希表
    futex_queue(&q, vma, address);

    // 4. 检查用户地址的值是否仍是期望值
    //    如果不是（已被其他线程改变），立即返回
    if (get_user(val2, uaddr) != 0)
        goto out;
    if (val2 != val) {
        ret = -EAGAIN;
        goto out;
    }

    // 5. 调度出去（让出 CPU，睡眠）
    schedule();  // 等待 wake_up

out:
    futex_dequeue(&q);
    return ret;
}
```

### 4.2 futex_queue — 加入哈希表

```c
// kernel/futex/futex-waitwake.c — futex_queue
static int futex_queue(struct futex_q *q, struct vm_area_struct *vma, unsigned long address)
{
    // 1. 计算哈希
    q->hash_key = futex_hash(&q->key);

    // 2. 加入 per-CPU 哈希桶的红黑树
    spin_lock(&hash_bucket(q->hash_key).lock);
    plist_node_init(&q->list, current->prio);
    plist_add(&q->list, &hash_bucket(q->hash_key).list);
    spin_unlock(&hash_bucket(q->hash_key).lock);

    return 0;
}
```

---

## 5. futex_wake — 唤醒

### 5.1 futex_wake

```c
// kernel/futex/futex-waitwake.c — futex_wake
static int futex_wake(u32 __user *uaddr, unsigned int nr_wake)
{
    struct futex_key key;
    struct futex_q *this, *next;

    // 1. 获取 futex_key
    if (futex_get_user_key(uaddr, &key))
        return -EINVAL;

    // 2. 找哈希桶
    head = hash_bucket(futex_hash(&key));

    // 3. 遍历等待队列
    plist_for_each_entry_safe(this, next, &head->list, list) {
        if (futex_match_key(this, &key)) {
            // 匹配，唤醒进程
            wake_futex(this);
            if (nr_wake > 0) {
                nr_wake--;
                if (!nr_wake)
                    break;
            }
        }
    }

    return 0;
}
```

### 5.2 wake_futex

```c
// kernel/futex/futex-waitwake.c — wake_futex
static void wake_futex(struct futex_q *q)
{
    struct task_struct *p = q->task;

    // 唤醒等待的进程
    wake_up_process(p);
    put_task_struct(p);
}
```

---

## 6. PI-futex（优先级继承）

### 6.1 什么是优先级反转

```
高优先级线程 H 等待低优先级线程 L 持有的锁
中等优先级线程 M 在运行
→ H 被 M 阻塞（M > H > L 的优先级）
→ H 实际等待时间不确定
→ 这是"优先级反转"
```

### 6.2 PI-futex 解决方案

```c
// kernel/futex/futex-pi.c — futex_lock_pi
static int futex_lock_pi(u32 __user *uaddr, u32 val, struct timespec *timeout)
{
    // 1. 检测 futex 值的当前持有者
    // 2. 如果有持有者，提升其优先级（等于等待者的优先级）
    // 3. 使用 rt_mutex 实现 PI 锁

    // rt_mutex_proxy_start：提升持有者优先级
    // boost_prio(current_owner, waiter.task->prio);
}
```

---

## 7. 用户空间 glibc 实现

```c
// glibc 的 futex 实现（非正式）：

// futex 32 位值的布局：
//   最低 2 位 = 状态标志
//   00 = 无锁
//   01 = 有锁，无等待者
//   10 = 有锁，有等待者
//   11 = 保留

// CMXCas(&lock, 0, 1)：
//   lock xaddl $0, %lock  // 原子比较和交换
//   如果 %lock = 0，设置 %lock = 1，返回 0

// futex(WAIT, addr, expected, timeout)：
//   if (*addr == expected)
//       syscall(SYS_futex, addr, FUTEX_WAIT, expected, timeout)
//   否则返回 -EAGAIN

// futex(WAKE, addr, nr)：
//   syscall(SYS_futex, addr, FUTEX_WAKE, nr)
```

---

## 8. requeue 操作

```c
// futex_requeue：把等待者从 futex A 移动到 futex B
// 常用于实现 pthread_cond_broadcast

futex_requeue(uaddr1, uaddr2, nr_wake=1, nr_move=n):
  // 1. 唤醒 nr_wake 个 uaddr1 的等待者
  // 2. 把 nr_move 个等待者从 uaddr1 移动到 uaddr2
  // 这样可以实现条件变量的广播：只唤醒一个，其他移动到关联的 mutex
```

---

## 9. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| 用户态自旋 + 内核兜底 | 无竞争时零 syscall |
| key = (inode, offset) 标识 | 同一地址的 futex 跨进程共享 |
| plist（优先级链表）| 按优先级唤醒（实时性）|
| 红黑树索引等待者 | O(log n) 查找 |
| PI-futex 优先级继承 | 解决优先级反转问题 |

---

## 10. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/futex/futex.c` | `sys_futex` |
| `kernel/futex/futex-waitwake.c` | `futex_wait`、`futex_wake`、`futex_queue` |
| `kernel/futex/futex-pi.c` | `futex_lock_pi`、`PI-futex` |
| `include/linux/futex.h` | `struct futex_key`、`struct futex_q` |

---

## 11. 西游记类比

**futex** 就像"取经路上的无线门禁"——

> 悟空（线程）走到山洞门口，先看看门是否开着（用户空间读 lock）。如果开着，刷卡进去（CMXCas）。如果门关着，悟空就按一下门铃（futex WAIT），然后找个地方睡觉（schedule）。守门人（内核）看到有人按门铃，就会记录下来。等里面的人办完事出来，按一下外面的开关（futex WAKE），守门人就叫醒门口等待的人（wake_up_process）。这就是为什么无竞争时完全不用惊动天庭（零 syscall）——刷卡比按门铃快多了。如果有人同时按门铃，守门人会按优先级决定叫醒谁（PI-futex）。

---

## 12. 关联文章

- **mutex**（article 08）：内核互斥锁，futex 是用户态 mutex 的基础
- **wait_queue**（article 07）：futex 的等待队列实现
- **rt_mutex**：PI-futex 底层使用 rt_mutex 实现优先级继承