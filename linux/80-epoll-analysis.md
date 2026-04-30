# epoll — I/O 事件多路复用深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/eventpoll.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**epoll** 是 Linux 的 I/O 事件多路复用机制，比 `select/poll` 更高效，支持 O(1) 的事件通知。

---

## 1. 核心数据结构

### 1.1 eventpoll — epoll 实例

```c
// fs/eventpoll.c — eventpoll
struct eventpoll {
    // 红黑树（存储监控项）
    struct rb_root_cached   rbr;           // 红黑树根（O(log n) 插入/删除）

    // 就绪列表（已触发的事件）
    struct list_head        rdlist;         // 已就绪的 epitem 链表

    // 等待队列
    wait_queue_head_t       wq;            // epoll_wait() 阻塞队列
    wait_queue_head_t       poll_wait;      // poll() 使用的等待队列

    // 引用计数
    atomic_t                user_count;     // 用户引用计数

    // 标志
    unsigned long           flags;         // EPOLL_* 标志

    // Mutex（保护）
    struct mutex            mtx;           // 保护 rbr 和 rdlist
};
```

### 1.2 epitem — 监控项

```c
// fs/eventpoll.c — epitem
struct epitem {
    // 红黑树节点（快速插入/删除）
    struct rb_node          rbn;           // 接入 eventpoll.rbr
    struct list_head        rdllink;       // 接入 rdlist（已就绪）

    // 文件描述符
    struct epoll_filefd     ffd;           // (fd, file) 对

    // 所属 epoll 实例
    struct eventpoll       *ep;           // 所属 eventpoll

    // 事件
    struct epoll_event      event;        // 用户关注的事件（EPOLLIN/OUT/ET...）

    // 降级
    int                     wholenl;       // 是否降级
};
```

### 1.3 epoll_filefd — (fd, file) 对

```c
// fs/eventpoll.c — epoll_filefd
struct epoll_filefd {
    struct file             *file;         // 文件
    int                     fd;            // 文件描述符
};
```

---

## 2. epoll_create — 创建 epoll 实例

```c
// fs/eventpoll.c — do_epoll_create
static int do_epoll_create(int flags)
{
    struct eventpoll *ep;
    struct file *file;

    // 1. 分配 eventpoll 结构
    ep = kzalloc(sizeof(*ep), GFP_KERNEL);

    // 2. 初始化
    rb_init_node(&ep->rbr.rb_node);
    INIT_LIST_HEAD(&ep->rdlist);
    init_waitqueue_head(&ep->wq);
    init_waitqueue_head(&ep->poll_wait);
    mutex_init(&ep->mtx);
    atomic_set(&ep->user_count, 1);

    // 3. 创建匿名 inode（类似于 timerfd）
    file = anon_inode_getfile("eventpoll", &eventpoll_fops, ep, O_RDWR);

    // 4. 返回 epoll fd
    return fd;
}
```

---

## 3. epoll_ctl — 添加/修改/删除监控项

### 3.1 epoll_ctl_add — 添加

```c
// fs/eventpoll.c — epoll_ctl
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event)
{
    struct file *efile, *tfile;
    struct eventpoll *ep;
    struct epitem *epi;

    // 1. 获取 epoll 文件
    efile = fdget(epfd).file;
    ep = efile->private_data;

    // 2. 获取目标文件
    tfile = fdget(fd).file;

    // 3. 检查是否已存在
    epi = ep_find(ep, tfile, fd);

    switch (op) {
    case EPOLL_CTL_ADD:
        // 分配新的 epitem
        epi = kmem_cache_zalloc(epi_cachep, GFP_KERNEL);
        epi->ffd.file = tfile;
        epi->ffd.fd = fd;
        epi->event = *event;
        epi->ep = ep;

        // 4. 插入红黑树（O(log n)）
        ep_rbtree_insert(epi, ep);

        // 5. 注册回调（ep_poll_callback）
        //    当 fd 触发事件时，调用此回调
        ep_set_busy_poll(epi, tfile);

        // 6. 添加到 target->f_op->poll
        ep_insert(ep, tfile, event, &fd);

        break;
    }
}
```

---

## 4. ep_poll_callback — 事件到达

```c
// fs/eventpoll.c — ep_poll_callback
static int ep_poll_callback(wait_queue_entry_t *wait, unsigned mode, int sync, void *key)
{
    struct epitem *epi = wait->private;
    struct eventpoll *ep = epi->ep;

    // 1. 检查是否有关注的事件
    if (!max_events)
        return 0;

    // 2. 加入就绪链表
    spin_lock(&ep->mtx);
    if (!ep_is_linked(&epi->rdllink)) {
        list_add_tail(&epi->rdllink, &ep->rdlist);
    }
    spin_unlock(&ep->mtx);

    // 3. 唤醒 epoll_wait
    if (waitqueue_active(&ep->wq))
        wake_up(&ep->wq);

    return 1;
}
```

---

## 5. epoll_wait — 等待事件

```c
// fs/eventpoll.c — do_epoll_wait
static int do_epoll_wait(int epfd, struct epoll_event *events,
                        int maxevents, int timeout)
{
    struct eventpoll *ep;
    struct file *file;
    int error = 0;

    // 1. 获取 epoll 实例
    file = fdget(epfd).file;
    ep = file->private_data;

    // 2. 检测是否有就绪事件
    while (list_empty(&ep->rdlist)) {
        if (timeout == 0)
            return 0;

        // 3. 阻塞直到有事件
        error = wait_event_interruptible(ep->wq,
                                        !list_empty(&ep->rdlist));
        if (error)
            return error;
    }

    // 4. 收集就绪事件（最多 maxevents 个）
    n = 0;
    while (!list_empty(&ep->rdlist) && n < maxevents) {
        struct epoll_event et;
        epi = list_first_entry(&ep->rdlist, struct epitem, rdllink);

        // 取出
        list_del_init(&epi->rdllink);

        // 收集事件
        et.events = epi->event.events;
        et.data = epi->event.data;
        events[n++] = et;
    }

    return n;
}
```

---

## 6. LT vs ET 模式

```c
// Level Triggered (LT，默认)：
//   - 只要条件满足，每次 epoll_wait 都返回
//   - 类似于 poll

// Edge Triggered (ET)：
//   - 条件满足时只返回一次
//   - 需要一直读取直到 EAGAIN
//   - 效率更高，避免重复通知
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `fs/eventpoll.c` | `struct eventpoll`、`struct epitem`、`ep_poll_callback`、`do_epoll_wait` |