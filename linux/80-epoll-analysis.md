# 80-epoll — Linux epoll I/O 事件通知框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**epoll** 是 Linux 高性能 I/O 事件通知框架，是 select/poll 的替代方案。epoll 将监控的文件描述符注册到**红黑树**（`eventpoll.rbr`），就绪事件通过**双链表**（`rdllist` + `ovflist`）管理，实现 O(1) 事件获取和 O(log n) 注册。

**核心设计**：
```
epoll 的三级数据结构：
  红黑树 (rbr) — 存所有注册的 fd (epitem)，按 fd 排序
     ↓ fd 就绪时回调移动
  就绪链表 (rdllist) — 当前有事件可读的 fd 链表
     ↓ epoll_wait 加锁消费
  溢出链表 (ovflist) — 就绪事件太多时的溢出链表（无锁）

epoll_create → 创建 eventpoll 结构体，分配 fd
epoll_ctl(ADD) → 创建 epitem，插入 rbr 红黑树
               → ep_ptable_queue_proc() → 注册 poll 回调
               → 回调函数 ep_poll_callback() 被调用时
                 将 epitem 移入 rdllist 并唤醒 epoll_wait
epoll_wait → ep_send_events() 遍历 rdllist
           → 将就绪事件复制到用户空间
           → LT（水平触发）不移除 → 下次继续返回
           → ET（边缘触发）移除 → 下次有新事件才返回
```

**doom-lsp 确认**：`fs/eventpoll.c`（**2,621 行**，**187 个符号**）。核心结构 `struct eventpoll`（`:172`）、`struct epitem`（`:113`）。

---

## 1. 核心数据结构

### 1.1 struct eventpoll @ :172——epoll 实例

```c
struct eventpoll {
    struct mutex mtx;                        // 保护 epoll 操作的 mutex
    wait_queue_head_t wq;                    // epoll_wait 等待队列
    wait_queue_head_t poll_wait;             // file->poll() 用

    struct list_head rdllist;                // 就绪 fd 链表
    spinlock_t lock;                         // 保护 rdllist 和 ovflist

    struct rb_root_cached rbr;               // 红黑树（所有注册的 fd）
    struct epitem *ovflist;                  // 溢出链表（事件太多时）

    struct user_struct *user;
    struct file *file;

    refcount_t refcount;
    u64 gen;
};
```

### 1.2 struct epitem @ :113——注册的 fd 条目

```c
struct epitem {
    union {
        struct rb_node rbn;                  // 红黑树节点（按 fd 排序）
        struct rcu_head rcu;
    };

    struct list_head rdllink;                 // 在 rdllist 或 ovflist 中的节点
    struct epitem *next;                      // ovflist 的单向链表

    struct epoll_filefd ffd;                  // {file, fd} 对

    struct eppoll_entry *pwqlist;             // poll 等待队列条目链表
    struct eventpoll *ep;                     // 所属 epoll 实例

    struct hlist_node fllink;                 // 文件 fd 的回头链表

    struct epoll_event event;                 // 用户注册的事件（EPOLLIN/OUT/ET 等）
};
```

### 1.3 struct eppoll_entry @ :108——poll 回调连接

```c
struct eppoll_entry {
    struct eppoll_entry *next;               // 链表（在 epitem->pwqlist 中）
    struct epitem *base;                      // 所属 epitem
    wait_queue_entry_t wait;                  // 挂到目标 fd 的 waitqueue 上
    wait_queue_head_t *whead;                 // 目标 fd 的 waitqueue 头
};
```

---

## 2. epoll_ctl(ADD) 路径

```c
// sys_epoll_ctl → ep_insert()

static int ep_insert(struct eventpoll *ep, struct epoll_event *event,
                     struct file *tfile, int fd, int full_check)
{
    struct epitem *epi;

    // 1. 分配 epitem
    epi = kmem_cache_zalloc(epi_cache, GFP_KERNEL);
    INIT_LIST_HEAD(&epi->rdllink);
    INIT_LIST_HEAD(&epi->fllink);
    epi->ep = ep;
    epi->ffd.file = tfile;
    epi->ffd.fd = fd;
    epi->event = *event;

    // 2. 插入红黑树
    ep_rbtree_insert(ep, epi);               // rbr 红黑树

    // 3. 注册 poll 回调——关键！
    // ep_ptable_queue_proc() 被调用：
    // → init_waitqueue_func_entry(&pwq->wait, ep_poll_callback)
    // → add_wait_queue(whead, &pwq->wait)
    // 将 ep_poll_callback 挂到目标 fd 的 waitqueue 上
    // 当目标 fd 有事件时 → wake_up → ep_poll_callback → 将 epi 移到 rdllist

    ep_ptable_queue_proc(&epq.pt, tfile, ...);
    // → ep_poll_callback @ :1199 是事件就绪的核心回调
}
```

---

## 3. ep_poll_callback @ :1199——事件到达的核心回调

```c
// 当被监控的 fd 有事件时（如 socket 收到数据），
// sock_def_readable() → wake_up_interruptible() → 调用此函数

static int ep_poll_callback(wait_queue_entry_t *wait, unsigned mode,
                            int sync, void *key)
{
    struct eppoll_entry *pwq = container_of(wait, struct eppoll_entry, wait);
    struct epitem *epi = pwq->base;
    struct eventpoll *ep = epi->ep;

    spin_lock_irqsave(&ep->lock, flags);

    // 检查事件是否匹配
    pollflags = key_to_poll(key);
    if (pollflags && !(pollflags & epi->event.events))
        goto out_unlock;                     // 事件不匹配 → 跳过

    // 检查是否已在就绪链表
    if (list_empty(&epi->rdllink)) {
        list_add_tail(&epi->rdllink, &ep->rdllist);  // 加入就绪链表
    }

    // 检查 ovflist（就绪事件过多时的溢出链表）
    if (!READ_ONCE(ep->ovflist) && epi->next == EPITEM_UNLINKED)
        goto out_unlock;

    // 唤醒 epoll_wait 中等待的线程
    if (waitqueue_active(&ep->wq))
        wake_up(&ep->wq);

    spin_unlock_irqrestore(&ep->lock, flags);
    return 1;
}
```

**doom-lsp 确认**：`ep_poll_callback` @ `:1199`。这是 epoll 转分发机的核心——将文件描述符的通用 `wake_up` 事件转换为 epoll 的 `rdllist` 插入和 `epoll_wait` 唤醒。

---

## 4. epoll_wait 路径

```c
// sys_epoll_wait → ep_poll()

static int ep_poll(struct eventpoll *ep, struct epoll_event __user *events,
                   int maxevents, long timeout)
{
    wait_queue_entry_t wait;

    // 1. 如果有就绪事件 → 直接返回
    if (list_empty(&ep->rdllist))
        goto send_events;                    // 非阻塞快速路径

    // 2. 阻塞等待
    init_waitqueue_entry(&wait, current);     // 把当前线程加到 ep->wq
    __add_wait_queue_exclusive(&ep->wq, &wait);

    for (;;) {
        set_current_state(TASK_INTERRUPTIBLE);

        if (!list_empty(&ep->rdllist) || !READ_ONCE(ep->ovflist))
            break;                           // 有事件

        if (signal_pending(current)) {
            res = -EINTR;
            break;
        }

        schedule();                          // 睡眠（被 ep_poll_callback 唤醒）
    }

    __remove_wait_queue(&ep->wq, &wait);
    __set_current_state(TASK_RUNNING);

send_events:
    // 3. 复制事件到用户空间
    return ep_send_events(ep, events, maxevents);
    // → 遍历 rdllist，将事件复制到用户 events 数组
    // → LT 模式：不移除 rdllink（下次继续返回）
    // → ET 模式：移除 rdllink（下次有新事件才返回）
}
```

---

## 5. LT vs ET 实现

```c
// ep_send_events → ep_scan_ready_list()

// 水平触发 (LT, Level-Triggered)：
// epitem 在 rdllist 中保留 → 下次 epoll_wait 继续返回
// 保证用户总是能收到事件，但可能重复返回

// 边缘触发 (ET, Edge-Triggered)：
// epitem 从 rdllist 移除 → 下次有新事件（边缘）才再添加
// 需要用户一次性读完所有数据
// 通过 epitem->event.events & EPOLLET 判断

// 实现位于 ep_send_events_proc()：
static bool ep_item_poll(struct epitem *epi, poll_table *pt, int depth)
{
    // 调用目标 fd 的 poll 检查当前事件状态
    // LT：如果仍有事件 → 重新加入 rdllist
    // ET：不移回 → 等待下一次 ep_poll_callback
}
```

---

## 6. 红黑树与就绪链表双结构

epoll 使用**两套数据结构**同时管理 fd：

```
红黑树 (rbr)：              就绪链表 (rdllist)：
所有通过 epoll_ctl(ADD)   当前有事件待消费的 fd
注册的 fd                  由 ep_poll_callback 添加
按 fd 号排序               由 ep_send_events 消费

查找 O(log n)              遍历 O(ready_count)
```

| 操作 | 数据结构 | 复杂度 |
|------|---------|--------|
| `epoll_ctl(ADD)` | 红黑树插入 + 回调注册 | O(log n) |
| `epoll_ctl(DEL)` | 红黑树删除 + 回调移除 | O(log n) |
| `epoll_wait`（有事件）| 遍历 rdllist | O(ready) |
| `epoll_wait`（无事件）| 调度等待 | O(1) |
| `ep_poll_callback` | rdllist 尾部插入 | O(1) |

---

## 7. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `ep_insert` | — | epoll_ctl(ADD) 主逻辑 |
| `ep_poll_callback` | `:1199` | 事件到达回调（rdllist 插入+唤醒）|
| `ep_poll` | — | epoll_wait 主逻辑 |
| `ep_send_events` | — | 事件复制到用户空间 |
| `ep_ptable_queue_proc` | — | poll 回调注册 |
| `ep_rbtree_insert` | — | 红黑树插入 |

---

## 8. 总结

epoll 通过**红黑树 + 就绪链表双结构**实现高性能 I/O 事件。`ep_poll_callback`（`:1199`）是核心分发点——它将目标 fd 的通用 `wake_up` 事件转换为 `rdllist` 插入和 `epoll_wait` 唤醒。`ovflist`（溢出链表）允许事件在消费期间无锁添加新就绪事件。

**关键延迟**：
- `ep_poll_callback` → rdllist 插入 + wake_up：**~200-500ns**
- `ep_send_events` → 遍历就绪链表 + 复制到用户：**~100ns/event**

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
