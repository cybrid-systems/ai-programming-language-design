# Linux Kernel epoll / select / poll 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/eventpoll.c` + `fs/select.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 三种 I/O 多路复用对比

| 特性 | select | poll | epoll |
|------|--------|------|-------|
| FD 数量 | 受 `FD_SETSIZE` 限制（默认 1024）| 无限制 | 无限制 |
| 时间复杂度 | O(n) 遍历所有 FD | O(n) 遍历所有 FD | O(1) 回调 |
| 内存复制 | 每次复制整个 fd_set | 每次复制 `struct pollfd` 数组 | 仅复制活跃 FD |
| 水平触发 | ✓ | ✓ | ✓ + 边缘触发 |

---

## 1. epoll 核心数据结构

```c
// fs/eventpoll.c — eventpoll
struct eventpoll {
    /* 红黑树：所有监控的 FD */
    struct rb_root          rbr;               // 监控的 FD 红黑树
    struct list_head        rdllist;           // 就绪事件链表
    wait_queue_head_t       wq;               // 等待队列（epoll_wait）
    wait_queue_head_t       poll_wait;        // poll 等待队列

    /* 互斥 */
    spinlock_t              lock;
    struct mutex            mtx;

    /* 文件描述符引用 */
    struct file             *file;
};

// fs/eventpoll.c — epitem
struct epitem {
    struct rb_node          rbn;              // 接入 rbr 红黑树
    struct list_head        rdllink;          // 接入 rdllist
    struct epoll_filefd     ffd;              // (fd, file) 对
    int                     nwait;            // 等待的事件数量
    struct list_head        pwqlist;          // poll wait queue 链表
    struct eventpoll        *ep;              // 所属 eventpoll
    struct ep_pqueue        epq;              // 回调包
    __poll_t                events;           // 监控的事件
};
```

---

## 2. epoll_create / epoll_create1

```c
// fs/eventpoll.c — do_epoll_create
static int do_epoll_create(int flags)
{
    // 1. 分配匿名 inode（获取 fd）
    struct file *file = anon_inode_getfile("eventpoll", ...);

    // 2. 分配 eventpoll 结构
    struct eventpoll *ep = kzalloc(sizeof(*ep), GFP_KERNEL);

    // 3. 初始化
    rb_root_init(&ep->rbr);
    list_head_init(&ep->rdllist);
    init_poll_funcptr(&ep->pt, ep_ptable_queue_proc);  // 关键：poll 回调

    file->private_data = ep;

    return 0;
}
```

---

## 3. epoll_ctl — 添加/修改/删除 FD

```c
// fs/eventpoll.c — epoll_ctl
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event)
{
    struct file *efile = fget(epfd);
    struct file *ffile = fget(fd);
    struct eventpoll *ep = efile->private_data;
    struct epitem *epi;

    switch (op) {
    case EPOLL_CTL_ADD:
        // 1. 分配 epitem
        epi = kzalloc(sizeof(*epi), GFP_KERNEL);
        epi->events = event->events;
        epi->ffd.fd = fd;
        epi->ffd.file = ffile;
        epi->ep = ep;

        // 2. 插入红黑树
        ep_rbtree_insert(epi, &ep->rbr);

        // 3. 设置 poll 回调（关键！）
        //    ffile->f_op->poll(ffile, &epi->pt);
        //    → ep_ptable_queue_proc() 被调用
        //    → poll_wait(file, &epi->pwq->wait, pt);
        //    → 当 FD 就绪时，poll 回调触发 ep_poll_callback()
        break;

    case EPOLL_CTL_DEL:
        // 从红黑树删除
        ep_rbtree_remove(epi, &ep->rbr);
        break;

    case EPOLL_CTL_MOD:
        // 修改 events
        epi->events = event->events;
        break;
    }
}
```

---

## 4. ep_ptable_queue_proc — 关键回调

```c
// fs/eventpoll.c — ep_ptable_queue_proc
// 这是 epoll 高效的核心：当 FD 的 poll 被调用时，
// 此函数被注入到该 FD 的 poll 等待队列
static void ep_ptable_queue_proc(struct file *file, wait_queue_head_t *wait_address,
                     poll_table *pt)
{
    struct epitem *epi = container_of(pt, struct epitem, epq.pt);

    // 分配 poll wait entry
    struct ep_ppoll *pwq = kmem_cache_alloc(pwq_cache, GFP_KERNEL);
    pwq->whead = wait_address;
    pwq->epi = epi;

    // 添加到 FD 的等待队列
    init_waitqueue_func_entry(&pwq->wait, ep_poll_callback);
    add_wait_queue(wait_address, &pwq->wait);

    // 关联到 epi
    list_add_tail(&pwq->list, &epi->pwqlist);
}
```

---

## 5. ep_poll_callback — FD 就绪时唤醒

```c
// fs/eventpoll.c — ep_poll_callback
static int ep_poll_callback(wait_queue_entry_t *wait, unsigned mode, int sync, void *key)
{
    struct epitem *epi = container_of(wait, struct epitem, pwq->wait);
    struct eventpoll *ep = epi->ep;
    __poll_t revents = key_to_poll(key);

    spin_lock(&ep->lock);

    // 1. 如果 FD 有事件，加入就绪链表
    if (revents & epi->events) {
        list_add_tail(&epi->rdllink, &ep->rdllist);

        // 2. 唤醒 epoll_wait
        wake_up_locked(&ep->wq);
    }

    spin_unlock(&ep->lock);
}
```

---

## 6. epoll_wait

```c
// fs/eventpoll.c — do_epoll_wait
static int do_epoll_wait(int epfd, struct epoll_event *events,
              int maxevents, int timeout)
{
    // 1. 从 rdllist 取出就绪的 epitem
    // 2. 复制到用户空间 events 数组
    // 3. 返回就绪数量

    // 如果 rdllist 为空且 timeout != 0，阻塞等待
}
```

---

## 7. epoll 水平触发 vs 边缘触发

```
水平触发（LT，默认）：
  - FD 就绪时，每次 epoll_wait 都返回
  - 即使你已经处理过，只要 FD 还是就绪状态，就继续返回

边缘触发（ET）：
  - FD 从未就绪→就绪时，只返回一次
  - 必须循环读取/写入直到 EAGAIN

例：管道写端写入 100 字节
  LT: epoll_wait 返回，读取 50 字节，再次 epoll_wait 仍返回
  ET: epoll_wait 返回，读取 50 字节，再次 epoll_wait 不返回（未再次就绪）
```

---

## 8. 参考

| 文件 | 内容 |
|------|------|
| `fs/eventpoll.c` | `do_epoll_create`、`epoll_ctl`、`do_epoll_wait`、`ep_poll_callback` |
| `fs/select.c` | `core_sys_select`、`do_select` |
| `include/linux/eventpoll.h` | `struct eventpoll`、`struct epitem` |
