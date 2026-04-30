# blk-mq — 块设备多队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`block/blk-mq.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**blk-mq（Block Multi-Queue）** 是 Linux 3.13+ 引入的块设备 I/O 框架，专为**多核 CPU + SSD/NVMe** 设计：
- 每个 CPU 一个**软件队列**（soft queue）
- 每个硬件队列一个**硬件队列**（hard queue）
- 消除锁竞争，最大化并发

---

## 1. 核心数据结构

### 1.1 blk_mq_hw_queue — 硬件队列

```c
// block/blk-mq.h — blk_mq_hw_queue
struct blk_mq_hw_queue {
    spinlock_t          lock;           // 保护队列
    struct list_head    dispatch;       // 待分发的请求链表
    unsigned long       state;          // HCTX_STATE_* 状态

    /* 请求 */
    struct blk_mq_tags   *tags;         // 标签（请求描述符）
    struct blk_mq_tags   *sched_tags;   // 调度器标签（如果使用 MQ scheduler）

    /* CPU 映射 */
    struct blk_mq_ctx   **ctxs;        // 指向每个 CPU 的 soft queue
    unsigned int         nr_ctx;         // ctx 数量
};
```

### 1.2 blk_mq_ctx — 软件队列（per-CPU）

```c
// block/blk-mq.h — blk_mq_ctx
struct blk_mq_ctx {
    unsigned int        cpu;              // CPU 编号
    spinlock_t          lock;             // 保护本 CPU 的请求
    struct list_head    rq_lists[HCTX_MAX_QUEUES]; // 每种类型的请求链表
    // HCTX_TYPE_DEFAULT = 0（普通请求）
    // HCTX_TYPE_READ = 1（读请求）
    // HCTX_TYPE_POLL = 2（polled I/O）
};
```

### 1.3 blk_mq_tag_set — 标签集

```c
// block/blk-mq.h — blk_mq_tag_set
struct blk_mq_tag_set {
    const struct blk_mq_ops *ops;         // 硬件操作函数表
    unsigned int        nr_hw_queues;     // 硬件队列数
    unsigned int        queue_depth;       // 每队列请求深度
    unsigned int        reserved_tags;     // 保留标签数
    unsigned int        cmd_size;         // 每请求私有数据大小

    /* 分配 */
    struct blk_mq_tags  *tags[MAX_QUEUE_DEPTH]; // 标签数组
    struct blk_mq_tags  *shared_tags;     // 共享标签

    unsigned int        nr_maps;          // 映射数量（HCTX_MAX_QUEUES）
    struct blk_mq_queue_map queue_map[HCTX_MAX_QUEUES]; // CPU→HW 队列映射
};
```

### 1.4 request — I/O 请求

```c
// include/linux/blkdev.h — request
struct request {
    struct request_queue   *q;           // 所属队列
    struct blk_mq_hw_queue *mq_hctx;   // 硬件队列
    unsigned int        cmd_flags;       // REQ_OP_* | REQ_* 标志
    sector_t            __sector;       // 起始扇区
    unsigned long       nr_sectors;     // 扇区数
    struct bio          *bio;           // 关联的 bio

    /* 标签（用于在硬件队列中标识请求）*/
    unsigned int        tag;            // 请求标签
    unsigned int        internal_tag;   // 内部标签

    struct list_head    queuelist;      // 链表（用于调度）
    struct list_head    mq_list;        // 接入软队列的链表
};
```

---

## 2. 提交请求流程

### 2.1 blk_mq_submit_request

```c
// block/blk-mq.c — blk_mq_submit_request
void blk_mq_submit_request(struct request *rq, bool no_mq)
{
    struct blk_mq_ctx *ctx = rq->mq_ctx;
    struct blk_mq_hw_queue *hctx = rq->mq_hctx;

    // 1. 如果有调度器，先尝试调度
    if (q->elevator)
        blk_mq_sched_insert_request(rq, ...);
    else
        blk_mq_insert_requests(hctx, ctx, list, 0);

    // 2. 尝试直接 dispatch
    if (!no_mq)
        blk_mq_try_issue_list_directly(hctx, &rq);
}
```

### 2.2 blk_mq_insert_requests — 插入软队列

```c
// block/blk-mq.c — blk_mq_insert_requests
void blk_mq_insert_requests(struct blk_mq_hw_queue *hctx, struct blk_mq_ctx *ctx, ...)
{
    spin_lock(&ctx->lock);

    // 将请求链表加入 ctx 的 rq_lists
    list_splice_tail(list, &ctx->rq_lists[hctx->type]);

    spin_unlock(&ctx->lock);
}
```

---

## 3. Dispatch 流程

### 3.1 blk_mq_do_dispatch — 从软队列取出请求

```c
// block/blk-mq.c — blk_mq_do_dispatch
static void blk_mq_do_dispatch(struct blk_mq_hw_queue *hctx)
{
    LIST_HEAD(list);

    // 遍历每个 CPU 的软队列
    for (i = 0; i < hctx->nr_ctx; i++) {
        ctx = hctx->ctxs[i];

        spin_lock(&ctx->lock);
        list_splice_init(&ctx->rq_lists[hctx->type], &list);
        spin_unlock(&ctx->lock);

        // 分发到硬件队列
        list_for_each_entry(rq, &list, queuelist)
            blk_mq_try_issue_directly(hctx, rq, false);
    }
}
```

### 3.2 blk_mq_try_issue_directly — 直接发送到硬件

```c
// block/blk-mq.c — blk_mq_try_issue_directly
static blk_status_t blk_mq_try_issue_directly(struct blk_mq_hw_queue *hctx,
                         struct request *rq, ...)
{
    // 1. 尝试获取硬件队列
    if (!blk_mq_get_driver_tag(hctx, rq, NULL))
        return BLK_STS_RESOURCE;

    // 2. 调用驱动的 queue_rq
    ret = hctx->tags->ops->queue_rq(hctx, rq);

    if (ret != BLK_STS_OK)
        blk_mq_put_driver_tag(hctx, rq);

    return ret;
}
```

---

## 4. 硬件操作函数表

```c
// include/linux/blk-mq.h — blk_mq_ops
struct blk_mq_ops {
    // 队列请求
    blk_status_t (*queue_rq)(struct blk_mq_hw_queue *, struct request *);

    // 命令提交
    blk_status_t (*submit_bio)(struct bio *);

    // 映射队列
    int (*map_queues)(struct blk_mq_tag_set *set);

    // 空闲回调
    void (*timeout)(struct request *);

    // 优先级
    int (*poll)(struct blk_mq_hw_queue *, struct io_comp_batch *);

    // 完成
    void (*complete)(struct request *);
};
```

---

## 5. 多队列映射

```
CPU 0 ─┐
CPU 1 ─┼─► Hardware Queue 0 ──► SSD/NVMe
CPU 2 ─┤
CPU 3 ─┘

映射策略（blk_mq_map_queues）：
  - 轮询：将 CPU 均匀分配到硬件队列
  - 掩码：CPU 亲和性掩码
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `block/blk-mq.c` | `blk_mq_submit_request`、`blk_mq_do_dispatch` |
| `block/blk-mq.h` | `struct blk_mq_hw_queue`、`struct blk_mq_ctx` |
| `include/linux/blk-mq.h` | `struct blk_mq_ops`、`struct request` |
