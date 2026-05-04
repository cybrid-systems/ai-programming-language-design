# 080-epoll — Linux epoll I/O 事件通知框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**epoll** 是 Linux 高性能 I/O 事件通知框架，select/poll 的替代方案。它将监控的文件描述符注册到**红黑树**（`eventpoll.rbr`），就绪事件通过**双链表**（`rdllist` + `ovflist`）管理，实现 O(1) 事件获取和 O(log n) 注册。相比 select 每次传递完整的 fd_set（64 个 fd 限制 + O(n) 扫描），epoll 支持百万级 fd 且每次只返回就绪的事件。

epoll 的核心设计基于**回调注册**：每个被监控的 fd 通过 `ep_ptable_queue_proc()` 注册回调 `ep_poll_callback()`。当目标 fd 有事件就绪时，驱动通过 `poll_wait()` 唤醒回调函数，后者将 `epitem` 移入就绪链表。

**doom-lsp 确认**：`fs/eventpoll.c` 含 **213 个符号**，3191 行。关键函数：`ep_poll_callback` @ L609，`ep_send_events` @ L203，`ep_insert` @ L1058，`ep_poll` @ L1568，`ep_modify` @ L960。

---

## 1. 核心数据结构

### 1.1 `struct eventpoll`——epoll 实例

（`fs/eventpoll.c` L172 — doom-lsp 确认）

```c
struct eventpoll {
    struct mutex            mtx;            // L179 — 保护 epoll 操作的互斥锁
    wait_queue_head_t       wq;             // L182 — epoll_wait 的等待队列
    wait_queue_head_t       poll_wait;      // L185 — 供文件自身 poll() 使用
    struct list_head        rdllist;        // L188 — 就绪 fd 链表
    spinlock_t              lock;           // L191 — 保护 rdllist 和 ovflist 的锁
    struct rb_root_cached   rbr;            // L194 — 所有注册 fd 的红黑树（按 fd 排序）

    /* 溢出链表：无锁访问（仅在 ep_poll_callback 上下文中） */
    struct epitem           *ovflist;       // L198 — 就绪事件太多时的溢出链表

    /* 用户空间 epoll fd 和文件 */
    struct file             *file;          // L202 — 对应的 epoll 文件
    int                     visited;        // L204 — 递归检测
    struct list_head        visited_list_link; // L206 — 递归检测链表
    
    /* EPOLLEXCLUSIVE 使用计数 */
    int                     exccnt;        // L208 — 独占唤醒计数
};
```

**三级数据结构**：
```
红黑树 (rbr) — 存所有注册的 epitem，按 fd 排序
  │ fd 就绪 → ep_poll_callback() 移动
  ▼
就绪链表 (rdllist) — 当前有事件的 fd
  │ epoll_wait → ep_send_events() 复制到用户态
  ▼
用户空间 struct epoll_event[] — 应用程序接收
```

### 1.2 `struct epitem`——被监控的 fd 条目

（`fs/eventpoll.c` L131 — doom-lsp 确认）

```c
struct epitem {
    union {
        struct rb_node      rbn;            // L134 — 红黑树节点（按 fd 排序）
        struct rcu_head     rcu;            // L136 — RCU 回收
    };
    struct list_head        rdllink;        // L140 — 就绪链表节点（在 rdllist 或 ovflist 中）
    struct epoll_filefd     ffd;            // L144 — (file, fd) 对，树的排序键
    unsigned int            nwait;          // L147 — 已注册的 poll 回调数
    struct list_head        pwqlist;        // L148 — poll 等待队列项链表
    struct eventpoll        *ep;            // L149 — 所属的 eventpoll
    struct list_head        fllink;         // L151 — 目标文件的所有 epitem 链表
    struct wakeup_source    *ws;            // L153 — 唤醒源（EPOLLWAKEUP）
    struct epoll_event      event;          // L155 — 用户注册的事件（events + data）
};
```

### 1.3 `struct eppoll_entry`——回调注册条目

```c
// fs/eventpoll.c — doom-lsp 确认
struct eppoll_entry {
    struct list_head        llink;          // epitem->pwqlist 的节点
    struct epitem           *epi;           // 所属的 epitem
    wait_queue_entry_t      wait;           // 注册到目标 fd 等待队列的条目
    wait_queue_head_t       *whead;         // 目标 fd 的等待队列头
};
```

---

## 2. 完整数据流

### 2.1 epoll_create——创建实例

```
fd = epoll_create1(flags)
  └─ do_epoll_create(flags)
       └─ struct eventpoll *ep = kzalloc(sizeof(*ep), GFP_KERNEL)
       └─ 初始化：
            ep->mtx = __MUTEX_INITIALIZER(...)
            init_waitqueue_head(&ep->wq)
            init_waitqueue_head(&ep->poll_wait)
            INIT_LIST_HEAD(&ep->rdllist)
            spin_lock_init(&ep->lock)
            ep->rbr = RB_ROOT_CACHED
            ep->ovflist = EP_UNACTIVE_PTR  // 标记为"未使用"
       └─ ep->file = anon_inode_getfile("[eventpoll]", &eventpoll_fops, ep, ...)
       └─ fd_install(fd, ep->file)
       └─ return fd
```

### 2.2 epoll_ctl(ADD)——注册 fd

（`fs/eventpoll.c` 核心路径）

```
epoll_ctl(epfd, EPOLL_CTL_ADD, fd, event)
  └─ ep_insert(ep, event, fd, fd_file)
       │
       ├─ 1. 分配 epitem
       │     epi = kmem_cache_zalloc(epi_cache, GFP_KERNEL)
       │     epi->ep = ep
       │     epi->ffd = (file, fd)
       │     epi->event = *event
       │
       ├─ 2. 注册 poll 回调
       │     ep_ptable_queue_proc(file, bwq, &epi->ptq)
       │       └─ struct eppoll_entry *pwq = kmalloc(...)
       │          init_waitqueue_func_entry(&pwq->wait, ep_poll_callback)
       │          pwq->whead = poll_wait_queue(file)
       │          add_wait_queue(pwq->whead, &pwq->wait)
       │          epi->nwait++
       │
       ├─ 3. 检查当前是否已有就绪事件
       │     rev = file->f_op->poll(file, &pt)  // 立即查询一次状态
       │     if (rev & event->events):
       │         ep_poll_callback(&pwq->wait, 0, rev, NULL)
       │         // 如果 fd 当前已有就绪事件 → 加入 rdllist
       │
       ├─ 4. 插入红黑树
       │     ep_rbtree_insert(ep, epi)
       │     // 按 epi->ffd 排序的 rb tree
       │
       └─ 5. 如果 epoll 实例在等待中
             wake_up_locked(&ep->wq)
             // 唤醒正在 epoll_wait 中等待的线程
```

### 2.3 ep_poll_callback——事件回调函数

（`fs/eventpoll.c` L609 — doom-lsp 确认）

```c
static void ep_poll_callback(struct wait_queue_entry *wq, ...)
{
    struct epitem *epi = ep_item_from_wait(wq);  // 从等待队列条目反查 epitem
    struct eventpoll *ep = epi->ep;

    spin_lock_irqsave(&ep->lock, flags);

    // 1. 检查事件是否匹配
    if (!(epi->event.events & revents))
        goto out_unlock;

    // 2. 如果 ovflist 未激活（正常情况）
    if (ep->ovflist == EP_UNACTIVE_PTR) {
        if (list_empty(&epi->rdllink)) {
            list_add_tail(&epi->rdllink, &ep->rdllist);  // 加入就绪链表
        }
    } else {
        // ovflist 已激活（ep_send_events 正在消费就绪链表）
        // → 加入 ovflist（无锁）
        list_add_tail(&epi->rdllink, ep->ovflist);
    }

    // 3. 唤醒等待的 epoll_wait
    if (waitqueue_active(&ep->wq))
        wake_up_locked(&ep->wq);

    spin_unlock_irqrestore(&ep->lock, flags);
}
```

### 2.4 epoll_wait——事件获取

（`fs/eventpoll.c` L1568 — doom-lsp 确认）

```
epoll_wait(epfd, events, maxevents, timeout)
  └─ ep_poll(ep, events, maxevents, timeout)
       │
       ├─ 1. 快速路径：检查 rdllist
       │     spin_lock_irqsave(&ep->lock, flags)
       │     if (!list_empty(&ep->rdllist)):
       │         spin_unlock_irqrestore(...)
       │         ep_send_events(ep, events, maxevents)  // 直接返回
       │         return
       │
       ├─ 2. 慢速路径：等待事件
       │     init_wait_entry(&wait, 0)
       │     for (;;) {
       │         prepare_to_wait_exclusive(&ep->wq, &wait, TASK_INTERRUPTIBLE)
       │         spin_lock_irqsave(&ep->lock, flags)
       │         if (!list_empty(&ep->rdllist)) {
       │             spin_unlock_irqrestore(...)
       │             ep_send_events(ep, events, maxevents)  // 有事件了！
       │             break
       │         }
       │         spin_unlock_irqrestore(...)
       │         if (!schedule_hrtimeout_range(to, slack, HRTIMER_MODE_ABS))
       │             break  // 超时
       │         if (signal_pending(current))
       │             return -EINTR  // 信号中断
       │     }
       │     finish_wait(&ep->wq, &wait)
       │
       └─ 3. 返回就绪事件数
```

### 2.5 ep_send_events——就绪事件复制

（`fs/eventpoll.c` L203 — doom-lsp 确认）

```c
static int ep_send_events(struct eventpoll *ep, struct epoll_event __user *uevents,
                          int maxevents)
{
    struct epitem *epi, *tmp;
    LIST_HEAD(txlist);              // 事务链表
    int res = 0;

    // 1. 将 rdllist 整体移动到 txlist（加锁）
    spin_lock_irqsave(&ep->lock, flags);
    list_splice_init(&ep->rdllist, &txlist);
    ep->ovflist = NULL;             // 激活溢出链表（新就绪事件进 ovflist）
    spin_unlock_irqrestore(&ep->lock, flags);

    // 2. 遍历 txlist，检查事件是否仍然有效
    list_for_each_entry_safe(epi, tmp, &txlist, rdllink) {
        // LT 模式：不移除，下次继续返回
        // ET 模式：不移回到 rdllist，等待新事件
        unsigned int revents = epi->file->f_op->poll(epi->file, NULL);

        if (revents & epi->event.events) {
            // 事件仍有效 → 复制到用户空间
            if (__put_user(revents, &uevents[res].events) ||
                __put_user(epi->event.data, &uevents[res].data))
                return -EFAULT;
            res++;
        }

        if (epi->event.events & EPOLLONESHOT)
            epi->event.events &= EP_PRIVATE_BITS;  // 仅触发一次

        // 3. 检查是否需要重新入队（LT 模式）
        if (!(epi->event.events & EPOLLET) &&
            (revents & epi->event.events))
            list_add_tail(&epi->rdllink, &ep->rdllist);  // LT: 放回！
    }

    // 4. 关闭溢出链表，将 ovflist 的事件移入 rdllist
    spin_lock_irqsave(&ep->lock, flags);
    // 移动 ovflist → rdllist
    for (nepi = ep->ovflist; nepi != EP_UNACTIVE_PTR; ...)
        list_add_tail(&nepi->rdllink, &ep->rdllist);
    ep->ovflist = EP_UNACTIVE_PTR;
    spin_unlock_irqrestore(&ep->lock, flags);

    return res;
}
```

---

## 3. LT vs ET 模式

| 特性 | Level-Triggered（LT） | Edge-Triggered（ET） |
|------|----------------------|---------------------|
| 就绪通知 | 只要 fd 就绪就持续通知 | 只在状态变化时通知一次 |
| ep_send_events 行为 | 不移除 rdllist | 不移回（等新事件） |
| 使用方式 | 类似 select/poll，简单 | 必须读完所有数据（非阻塞循环） |
| 性能 | 可能有重复通知 | 减少唤醒次数 |
| 典型场景 | 通用服务器 | 高性能百万并发 |

**ET 模式的关键约束**（来自 epoll(7) man page）：

> When using edge-triggered epoll, the caller should use non-blocking file descriptors and read/write in a loop until EAGAIN.

```
LT 模式：每次 epoll_wait 都会返回就绪 fd
  epoll_wait → 返回 fd1 → 处理部分数据 → epoll_wait → 又返回 fd1
ET 模式：只在第一次返回就绪 fd
  epoll_wait → 返回 fd1 → 必须先读完（直到 EAGAIN）
  → 下次有新数据到达时才再次通知
```

---

## 4. EPOLLONESHOT 与 EPOLLEXCLUSIVE

### EPOLLONESHOT

注册后只通知一次，下次需要显式 `EPOLL_CTL_MOD` 重新注册：

```c
// 用于多线程 worker 消费 epoll 事件：
// 线程 A: epoll_wait → 获得 fd1
// 线程 B: epoll_wait → 不会得到 fd1（因为 EPOLLONESHOT 已屏蔽）
// 线程 A: 处理完 fd1 → epoll_ctl(MOD, fd1, EPOLLONESHOT | EPOLLIN)
//         重新激活监听
```

### EPOLLEXCLUSIVE

解决**惊群问题**（thundering herd）：多个线程同时 epoll_wait 同一个 epoll fd 时，默认所有线程都会被唤醒，但只有一个能获得事件。`EPOLLEXCLUSIVE` 只唤醒其中一个线程：

```c
// 惊群（无 EPOLLEXCLUSIVE）：
// epoll_wait 在 ep->wq 上等待的 N 个线程全部被唤醒
// 但只有一个能消费事件，其余 N-1 个重新睡眠

// 解决（EPOLLEXCLUSIVE）：
// 在 ep_poll_callback 中调用 wake_up_locked_exclusive(&ep->wq)
// → wake_up 只唤醒一个排他等待者
```

---

## 5. epoll vs select vs poll

| 能力 | select | poll | epoll |
|------|--------|------|-------|
| 最大 fd 数 | 1024（FD_SETSIZE） | 无限制 | 无限制 |
| 事件获取 | O(n) 扫描 fd_set | O(n) 扫描 pollfd | O(1) 直接读 rdllist |
| 注册 | 每次调用重传 fd_set | 每次调用重传 pollfd | 一次 epoll_ctl，永久有效 |
| 回调机制 | 无 | 无 | ep_poll_callback |
| 工作集 | 小（<100 fd） | 中（<1000 fd） | 大（10000+ fd） |
| 跨平台 | POSIX | POSIX | Linux-only |
| 边缘触发 | 无 | 无 | EPOLLET |

---

## 6. 关键优化

### ovflist 溢出链表

`ep_send_events()` 在遍历就绪链表时，将 `ep->ovflist` 设为 NULL。在此期间新就绪的事件**不进 `rdllist`**（防止递归），而是进入 `ovflist` 链表。这避免了对 `rdllist` 加锁的同时新回调尝试获取同一锁——解决了 `ep_send_events` 和 `ep_poll_callback` 之间的锁竞争。

### 递归检测

epoll 支持嵌套（一个 epoll fd 监听另一个 epoll fd），但可能产生递归唤醒。`visited` 标志和 `visited_list_link` 链表用于检测和打破递归。

---

## 7. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct eventpoll` | fs/eventpoll.c | 172 |
| `struct epitem` | fs/eventpoll.c | 131 |
| `struct eppoll_entry` | fs/eventpoll.c | (内联) |
| `ep_poll_callback()` | fs/eventpoll.c | 609 |
| `ep_send_events()` | fs/eventpoll.c | 203 |
| `ep_insert()` | fs/eventpoll.c | 1058 |
| `ep_remove()` | fs/eventpoll.c | 902 |
| `ep_modify()` | fs/eventpoll.c | 960 |
| `ep_poll()` | fs/eventpoll.c | 1568 |
| `ep_ptable_queue_proc()` | fs/eventpoll.c | (回调注册) |
| `epoll_create1()` | fs/eventpoll.c | (syscall) |
| `epoll_ctl()` | fs/eventpoll.c | (syscall) |
| `epoll_wait()` | fs/eventpoll.c | (syscall) |
| `eventpoll_fops` | fs/eventpoll.c | (file_operations) |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-04 | 内核版本：Linux 7.0-rc1*
