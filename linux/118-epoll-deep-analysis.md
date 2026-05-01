# Linux Kernel epoll 深度源码分析（doom-lsp 全面解析）

> 基于 Linux 7.0-rc1 主线源码（`fs/eventpoll.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：eventpoll、epitem、ep_poll_callback、ep_ptable_queue_proc、LT/ET、红黑树

## 0. epoll 概述与历史

**epoll** 是 Linux 2.6+ 引入的 I/O 多路复用机制，解决了 `select`/`poll` 的 O(n) 扫描问题。核心设计：

- **O(1) 事件通知**：仅返回就绪的 FD，而非遍历所有 FD
- **红黑树管理**：所有监控的 FD 以 O(log n) 插入/删除
- **内核回调**：FD 就绪时主动调用回调，而非被动轮询

### 与 select/poll 对比

```
select/poll:
  用户 → copy fd_set to kernel → 遍历 all FD → copy result to user
                                      O(n) 每次

epoll:
  epoll_ctl:  红黑树插入         O(log n)
  FD 就绪:    回调 → 加入 rdllist O(1)
  epoll_wait: 仅复制 rdllist     O(k) k=就绪数
```

## 1. 核心数据结构（逐字段解析）

### 1.1 eventpoll — epoll 实例

```c
// fs/eventpoll.c:155 — struct eventpoll
struct eventpoll {
    // 互斥锁（保护所有操作）
    struct mutex              mtx;              // 行 179

    // 等待队列（epoll_wait 阻塞在此）
    wait_queue_head_t         wq;               // 行 182

    // poll 等待队列（FD 的 poll 等待队列头）
    wait_queue_head_t         poll_wait;        // 行 185

    // 就绪链表（FD 就绪后加入此链表）
    struct list_head          rdllist;          // 行 188

    // 自旋锁（保护 rdllist / ovflist）
    spinlock_t                lock;             // 行 191

    // 红黑树根（所有监控的 epitem）
    struct rb_root_cached     rbr;              // 行 194

    // 离线事件链表（正在处理中但还未到 rdllist 的事件）
    struct list_head          ovflist;          // 行 201

    // wakeup 源
    struct eppoll_entry       *ws;              // 行 204

    // 创建此 epoll 的用户
    struct user_struct        *user;            // 行 207

    // epoll 文件本身
    struct file               *file;            // 行 209

    // 循环检查深度（防止死锁）
    int                      loop_check_gen;   // 行 214

    // 引用计数
    refcount_t                refcount;         // 行 217
};
```

### 1.2 epitem — 每个监控的 FD

```c
// fs/eventpoll.c:113 — struct epitem (嵌入在 rb_node 中)
struct epitem {
    // 红黑树节点（接入 eventpoll->rbr）
    struct rb_node            rbn;              // 行 134

    // RCU 节点（安全删除）
    struct rcu_head           rcu;              // 行 136

    // 就绪链表节点（接入 eventpoll->rdllist）
    struct list_head          rdllink;          // 行 140

    // 链表节点（用于 next 指针）
    struct list_head          next;             // 行 146

    // (fd, file) 对
    struct epoll_filefd       ffd;              // 行 149

    // 此 FD 的 poll wait 队列条目列表
    struct list_head          pwqlist;          // 行 152

    // 所属 eventpoll
    struct eventpoll          *ep;              // 行 155

    // 等待事件链表
    struct epitems_head       *ws;              // 行 161

    // 监控的事件类型（EPOLLIN/EPOLLOUT/EPOLLET 等）
    __poll_t                  event;            // 行 164
};
```

### 1.3 eppoll_entry — 等待队列条目

```c
// fs/eventpoll.c:108 — struct eppoll_entry
struct eppoll_entry {
    // 链表节点（接入 epitem->pwqlist）
    struct list_head          next;             // 行 110

    // 所属 epitem
    struct epitem            *base;             // 行 113

    // 等待队列头（实际被添加到 FD 的 poll 等待队列）
    wait_queue_entry_t        wait;             // 行 119

    // 指向包含此 wait 的 poll 等待队列头
    wait_queue_head_t         *whead;            // 行 122
};
```

### 1.4 epoll_filefd — (fd, file) 封装

```c
// fs/eventpoll.c:102 — struct epoll_filefd
struct epoll_filefd {
    struct file               *file;            // 行 103
    int                      fd;               // 行 104
};
```

## 2. epoll_create / epoll_create1

```c
// fs/eventpoll.c:2248 — do_epoll_create
static int do_epoll_create(int flags)
{
    int error, fd;
    struct eventpoll *ep;
    struct file *file;

    // 1. 分配 eventpoll 结构
    ep = kzalloc(sizeof(*ep), GFP_KERNEL);

    // 2. 初始化所有字段
    mutex_init(&ep->mtx);                  // 行 179
    init_waitqueue_head(&ep->wq);         // 行 182
    init_waitqueue_head(&ep.poll_wait);   // 行 185
    INIT_LIST_HEAD(&ep->rdllist);         // 行 188
    spin_lock_init(&ep->lock);            // 行 191
    ep->rbr = RB_ROOT_CACHED;             // 行 194
    INIT_LIST_HEAD(&ep->ovflist);         // 行 201
    refcount_set(&ep->refcount, 1);       // 行 217

    // 3. 创建匿名 inode（获取 fd）
    file = anon_inode_getfile("eventpoll",
                   &eventpoll_fops, ep, O_RDWR | flags);
    file->private_data = ep;

    fd = get_unused_fd_flags(O_RDWR | flags);
    fd_install(fd, file);

    return fd;
}
```

## 3. epoll_ctl — 核心：插入/修改/删除 FD

### 3.1 epoll_ctl 代码

```c
// fs/eventpoll.c:3969 — SYSCALL_DEFINE4(epoll_ctl, ...)
long epoll_ctl(int epfd, int op, int fd, struct epoll_event *event)
{
    int error;
    bool locked;
    struct file *efile, *tfile;
    struct eventpoll *ep;
    struct epitem *epi;

    // 1. 获取 epoll 文件和目标文件
    efile = fdget(epfd);
    tfile = fdget(fd);
    ep = efile->private_data;

    // 2. 根据 op 分支
    switch (op) {
    case EPOLL_CTL_ADD:
        // 插入新 epitem
        error = ep_insert(ep, event, tfile);
        break;
    case EPOLL_CTL_DEL:
        // 从红黑树删除
        epi = ep_find(ep, tfile);
        error = ep_remove(ep, epi);
        break;
    case EPOLL_CTL_MOD:
        // 修改监控事件
        epi = ep_find(ep, tfile);
        error = ep_modify(ep, epi, event);
        break;
    }
}
```

### 3.2 ep_insert — 插入 FD（最关键）

```c
// fs/eventpoll.c:1070 附近 — ep_insert
static int ep_insert(struct eventpoll *ep, struct epoll_event *event,
             struct file *tfile, int fd)
{
    int error;
    struct epitem *epi;

    // 1. 分配 epitem（从 slab cache epitem_cache 分配）
    epi = kmem_cache_alloc(epi_cache, GFP_KERNEL);

    // 2. 初始化 epitem
    epi->ffd.fd = fd;
    epi->ffd.file = tfile;          // 引用目标文件
    epi->ep = ep;
    epi->event = *event;             // 复制用户传入的事件

    // 3. 初始化 poll wait 队列
    INIT_LIST_HEAD(&epi->pwqlist);

    // 4. 插入红黑树
    ep_rbtree_insert(epi, &ep->rbr);  // O(log n)

    // 5. **关键**：设置 poll 回调
    //    调用 tfile->f_op->poll(tfile, &epq.pt)
    //    → 回调 ep_ptable_queue_proc()
    //    → 将此 epi 的 wait 加入 FD 的 poll 等待队列
    tfile->f_op->poll(tfile, &epq.pt);

    return 0;
}
```

## 4. ep_ptable_queue_proc — epoll 高效的核心

这是 epoll 区别于 select/poll 的**关键机制**：

```c
// fs/eventpoll.c:1360 — ep_ptable_queue_proc
// 此函数被注入到目标 FD 的 poll 等待队列

static void ep_ptable_queue_proc(struct file *file, wait_queue_head_t *whead,
                 poll_table *pt)
{
    struct ep_pqueue *epq = container_of(pt, struct ep_pqueue, pt);
    struct epitem *epi = epq->epi;
    struct eppoll_entry *pwq;

    if (unlikely(!epi))
        return;

    // 1. 分配 eppoll_entry
    pwq = kmem_cache_alloc(pwq_cache, GFP_KERNEL);

    // 2. 初始化等待条目
    pwq->base = epi;             // 关联到 epitem
    pwq->whead = whead;          // 指向 FD 的 poll 等待队列

    // 3. 设置回调函数为 ep_poll_callback（核心！）
    init_waitqueue_func_entry(&pwq->wait, ep_poll_callback);

    // 4. 将等待条目添加到 FD 的 poll 等待队列
    //    当 FD 就绪时，wake_up() 会调用 pwq->wait.func = ep_poll_callback
    add_wait_queue(whead, &pwq->wait);

    // 5. 将 pwq 关联到 epi（方便后续删除）
    list_add_tail(&pwq->list, &epi->pwqlist);
}
```

**机制解释**：
- `select/poll` 在每次调用时**重新设置**等待队列，每次都要遍历
- `epoll` 通过回调机制，仅在 `epoll_ctl(ADD)` 时设置一次，之后 FD 就绪时**主动回调**，无需遍历

## 5. ep_poll_callback — FD 就绪时的回调

```c
// fs/eventpoll.c:1350 附近 — ep_poll_callback
static int ep_poll_callback(wait_queue_entry_t *wait, unsigned mode, int sync, void *key)
{
    struct eppoll_entry *pwq = container_of(wait, struct eppoll_entry, wait);
    struct epitem *epi = pwq->base;
    struct eventpoll *ep = epi->ep;
    __poll_t revents = key_to_poll(key);

    // 1. 如果没有监控的事件类型，直接返回
    if (!(epi->event & revents))
        return 0;

    // 2. 快速路径：将 epi 加入就绪链表
    spin_lock(&ep->lock);
    if (list_empty(&epi->rdllink)) {
        list_add_tail(&epi->rdllink, &ep->rdllist);
    }
    spin_unlock(&ep->lock);

    // 3. 唤醒 epoll_wait
    wake_up_locked(&ep->wq);

    return 1;
}
```

## 6. epoll_wait — 等待就绪事件

```c
// fs/eventpoll.c:5250 附近 — do_epoll_wait
static int do_epoll_wait(int epfd, struct epoll_event __user *events,
             int maxevents, int timeout)
{
    int error;
    struct epoll_wait {
        struct epoll_event *events;
        int maxevents;
        struct eventpoll *ep;
    } *ew;

    ew = ...;

    // 1. 如果就绪链表不为空，直接处理
    // 2. 否则，如果没有超时，阻塞等待
    if (timeout > 0) {
        schedule_timeoutInterruptible(timeout);
    } else if (timeout == 0) {
        // 立即返回（轮询模式）
    }

    // 3. 从 rdllist 取出 epi
    // 4. 复制事件到用户空间
    // 5. 返回就绪数量
}
```

## 7. LT（水平触发）vs ET（边缘触发）

```c
// 水平触发（LT，默认）：
//   只要 FD 处于就绪状态，每次 epoll_wait 都返回
//   即使你已经读取过，只要还有数据，就继续返回

// 边缘触发（ET，通过 EPOLLET 设置）：
//   FD 从"未就绪"变为"就绪"时，只返回一次
//   必须循环读取/写入直到 EAGAIN

// 代码实现（ep_poll_callback 中）：
//   LT: 每次调用都加入 rdllist
//   ET: 边缘触发需要设置 EPOLLONESHOT，之后需要 epoll_ctl(MOD) 重新激活
```

## 8. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| 红黑树管理 FD | O(log n) 插入/删除，适合大量 FD |
| ep_ptable_queue_proc 回调 | FD 就绪时主动通知，避免每次遍历 |
| 两层链表（rdllist + ovflist）| 避免边调用回调边遍历链表的数据竞争 |
| 自旋锁 + mutex 双锁 | 读多写少场景，读用锁，写用原子操作 |
| refcount 引用计数 | 防止 close(fd) 时释放正在使用的 epitem |

## 9. 参考

| 文件 | 函数 | 行 |
|------|------|-----|
| `fs/eventpoll.c` | `do_epoll_create` | 2248 |
| `fs/eventpoll.c` | `ep_insert` | 1070+ |
| `fs/eventpoll.c` | `ep_ptable_queue_proc` | 1360 |
| `fs/eventpoll.c` | `ep_poll_callback` | 1350 |
| `fs/eventpoll.c` | `do_epoll_wait` | 5250 |
| `fs/eventpoll.c` | `ep_rbtree_insert` | 红黑树工具 |
| `include/linux/eventpoll.h` | `struct epoll_event` | 用户空间接口 |


---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `include/linux/list.h` | 51 | 0 | 51 | 0 |
| `include/linux/sched.h` | 567 | 70 | 134 | 7 |
| `include/linux/mm.h` | 793 | 24 | 527 | 18 |

### 核心数据结构

- **audit_context** `sched.h:58`
- **bio_list** `sched.h:59`
- **blk_plug** `sched.h:60`
- **bpf_local_storage** `sched.h:61`
- **bpf_run_ctx** `sched.h:62`
- **bpf_net_context** `sched.h:63`
- **capture_control** `sched.h:64`
- **cfs_rq** `sched.h:65`
- **fs_struct** `sched.h:66`
- **futex_pi_state** `sched.h:67`
- **io_context** `sched.h:68`
- **io_uring_task** `sched.h:69`
- **mempolicy** `sched.h:70`
- **nameidata** `sched.h:71`
- **nsproxy** `sched.h:72`
- **perf_event_context** `sched.h:73`
- **perf_ctx_data** `sched.h:74`
- **pid_namespace** `sched.h:75`
- **pipe_inode_info** `sched.h:76`
- **rcu_node** `sched.h:77`
- **reclaim_state** `sched.h:78`
- **robust_list_head** `sched.h:79`
- **root_domain** `sched.h:80`
- **rq** `sched.h:81`
- **sched_attr** `sched.h:82`

### 关键函数

- **INIT_LIST_HEAD** `list.h:43`
- **__list_add_valid** `list.h:136`
- **__list_del_entry_valid** `list.h:142`
- **__list_add** `list.h:154`
- **list_add** `list.h:175`
- **list_add_tail** `list.h:189`
- **__list_del** `list.h:201`
- **__list_del_clearprev** `list.h:215`
- **__list_del_entry** `list.h:221`
- **list_del** `list.h:235`
- **list_replace** `list.h:249`
- **list_replace_init** `list.h:265`
- **list_swap** `list.h:277`
- **list_del_init** `list.h:293`
- **list_move** `list.h:304`
- **list_move_tail** `list.h:315`
- **list_bulk_move_tail** `list.h:331`
- **list_is_first** `list.h:350`
- **list_is_last** `list.h:360`
- **list_is_head** `list.h:370`
- **list_empty** `list.h:379`
- **list_del_init_careful** `list.h:395`
- **list_empty_careful** `list.h:415`
- **list_rotate_left** `list.h:425`
- **list_rotate_to_front** `list.h:442`
- **list_is_singular** `list.h:457`
- **__list_cut_position** `list.h:462`
- **list_cut_position** `list.h:488`
- **list_cut_before** `list.h:515`
- **__list_splice** `list.h:531`
- **list_splice** `list.h:550`
- **list_splice_tail** `list.h:562`
- **list_splice_init** `list.h:576`
- **list_splice_tail_init** `list.h:593`
- **list_count_nodes** `list.h:755`

### 全局变量

- **__tracepoint_sched_set_state_tp** `sched.h:350`
- **__tracepoint_sched_set_need_resched_tp** `sched.h:352`
- **def_root_domain** `sched.h:407`
- **sched_domains_mutex** `sched.h:408`
- **cad_pid** `sched.h:1749`
- **init_stack** `sched.h:1964`
- **class_migrate_is_conditional** `sched.h:2519`
- **_totalram_pages** `mm.h:53`
- **high_memory** `mm.h:74`
- **sysctl_legacy_va_layout** `mm.h:86`
- **mmap_rnd_bits_min** `mm.h:92`
- **mmap_rnd_bits_max** `mm.h:93`
- **mmap_rnd_bits** `mm.h:94`
- **sysctl_user_reserve_kbytes** `mm.h:210`
- **sysctl_admin_reserve_kbytes** `mm.h:211`

### 成员/枚举

- **utime** `sched.h:366`
- **stime** `sched.h:367`
- **lock** `sched.h:368`
- **seqcount** `sched.h:386`
- **starttime** `sched.h:387`
- **state** `sched.h:388`
- **cpu** `sched.h:389`
- **utime** `sched.h:390`
- **stime** `sched.h:391`
- **gtime** `sched.h:392`
- **sched_priority** `sched.h:413`
- **pcount** `sched.h:421`
- **run_delay** `sched.h:424`
- **max_run_delay** `sched.h:427`
- **min_run_delay** `sched.h:430`
- **last_arrival** `sched.h:435`
- **last_queued** `sched.h:438`
- **max_run_delay_ts** `sched.h:441`
- **weight** `sched.h:461`
- **inv_weight** `sched.h:462`

