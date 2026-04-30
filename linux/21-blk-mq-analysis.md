# 21-blk-mq — 块设备多队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`block/blk-mq.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**blk-mq（Block Multi-Queue）** 是 Linux 3.13 引入的块设备新框架，为 SSD/NVMe 等高速设备设计。每个 CPU 有独立的软中断队列（soft queue），消除锁竞争。

---

## 1. 核心数据结构

### 1.1 blk_mq_hw_queues — 硬件队列

```c
// block/blk-mq.h — blk_mq_hw_queues
struct blk_mq_hw_queues {
    struct blk_mq_hw_queue  **queues;  // per-CPU 硬件队列
};
```

### 1.2 blk_mq_hw_queue — 硬件队列

```c
// block/blk-mq.h — blk_mq_hw_queue
struct blk_mq_hw_queue {
    spinlock_t              lock;      // 保护请求队列
    struct list_head        dispatch;   // 待分发的请求链表
    unsigned long           state;      // BLK_MQ_F_TAG_QUEUE_SHARED 等

    // 请求队列
    struct blk_mq_ctx       *queue_ctx; // per-CPU 软中断上下文
    struct request          *fq;        // 请求铁轨（I/O scheduler）

    // 硬件
    void                   *driver_data; // 驱动私有数据
    struct blk_mq_tags     *tags;      // 请求标签
};
```

### 1.3 struct request — I/O 请求

```c
// block/blk-mq.h — request
struct request {
    struct request_queue   *q;           // 所属队列
    struct blk_mq_hw_queue *mq_hctx;     // 硬件队列

    // 请求标识
    unsigned int           cmd_flags;      // REQ_* 标志
    unsigned int           tag;            // 标签（ blk_mq_tags 中的索引）

    // 扇区
    sector_t              sector;          // 起始扇区
    unsigned long         nr_sectors;     // 扇区数

    // bio
    struct bio            *bio;          // 关联的 bio
    struct io_context     *ioprio;

    // 队列
    struct list_head       queuelist;     // 接入软件队列的链表
};
```

---

## 2. 软队列与硬队列

```
blk-mq 分层：

用户进程
      ↓ submit_bio
软件层（per-CPU）：
  CPU0 → blk_mq_ctx[0]  ──┐
  CPU1 → blk_mq_ctx[1]  ──┼── 每个 CPU 有自己的软队列
  ...                       ──┘
      ↓ dispatch
硬件层（per-HW）：
  HW Queue 0 ──→ NVMe SSD（多队列）
  HW Queue 1 ──→ ...
```

---

## 3. 提交请求

### 3.1 blk_mq_submit_bio — 提交 bio

```c
// block/blk-mq.c — blk_mq_submit_bio
void blk_mq_submit_bio(struct bio *bio)
{
    struct request_queue *q = bio->bi_bdev->bd_disk->queue;
    struct blk_mq_hw_queue *hctx;
    struct blk_mq_ctx *ctx;

    // 1. 找到 per-CPU 软队列
    ctx = blk_mq_get_cpu_ctx(q);

    // 2. 分配 request
    struct request *rq = blk_mq_alloc_request(q, bio, ...);
    rq->bio = bio;

    // 3. 加入 per-CPU 软队列
    spin_lock(&ctx->lock);
    list_add_tail(&rq->queuelist, &ctx->rq_list);
    spin_unlock(&ctx->lock);

    // 4. 如果需要，触发软中断
    if (blk_mq_need_unplug(q))
        blk_mq_trigger_unplug(q);
}
```

---

## 4. 软中断处理

### 4.1 blk_mq_run_softirq — 运行软中断

```c
// block/blk-mq.c — blk_mq_run_softirq
void blk_mq_run_softirq(void *data)
{
    struct blk_mq_ctx *ctx = data;
    struct request_queue *q = ctx->q;

    // 遍历 per-CPU 队列
    while (!list_empty(&ctx->rq_list)) {
        struct request *rq;

        spin_lock(&ctx->lock);
        rq = list_first_entry(&ctx->rq_list, struct request, queuelist);
        list_del_init(&rq->queuelist);
        spin_unlock(&ctx->lock);

        // 分发到硬件队列
        blk_mq_dispatch_rq(rq);
    }
}
```

### 4.2 blk_mq_dispatch_rq — 分发请求

```c
// block/blk-mq.c — blk_mq_dispatch_rq
static int blk_mq_dispatch_rq(struct request *rq)
{
    struct blk_mq_hw_queue *hctx = rq->mq_hctx;

    // 加锁
    spin_lock(&hctx->lock);

    // 加入硬件队列的 dispatch 链表
    list_add_tail(&rq->queuelist, &hctx->dispatch);

    // 标记队列需要处理
    blk_mq_hw_queues_mark_pending(hctx);

    spin_unlock(&hctx->lock);

    // 触发硬件队列的完成中断
    blk_mq_trigger_complete(hctx);

    return 0;
}
```

---

## 5. 硬件队列处理

```c
// NVMe 驱动（drivers/nvme/host/pci.c）
// 硬件队列的中断处理：
nvme_irq(irq, *data):
    // 1. 读取完成队列（CQ）
    nvme_complete_cqes(nvmeq, ...);

    // 2. 清理已完成请求
    blk_mq_free_request(req);

    // 3. 如果 CQ 不满，触发新的提交
    nvme_submit_sqes(nvmeq);
```

---

## 6. 与传统 IO Scheduler 的对比

| 特性 | blk-mq（无 scheduler）| 传统（cfq/mq-deadline）|
|------|---------------------|----------------------|
| 队列数 | 数千（per-CPU+per-HW）| 少量（全局）|
| 锁竞争 | 低（每队列独立锁）| 高（全局锁）|
| SSD 友好 | ✓（多队列匹配 SSD 内部并行）| ✗ |
| HDD 友好 | 一般 | ✓（全局调度优化寻道）|

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `block/blk-mq.h` | `struct blk_mq_hw_queue`、`struct request` |
| `block/blk-mq.c` | `blk_mq_submit_bio`、`blk_mq_run_softirq`、`blk_mq_dispatch_rq` |

---

## 8. 西游记类比

**blk-mq** 就像"取经路上的多驿站快递系统"——

> 以前的快递是统一一个中转站（单队列 + 全局锁），所有货物都挤在一起，锁竞争严重。blk-mq 就像每个大城市都有自己独立的快递站（per-CPU soft queue），每个驿站（hardware queue）也有自己的发货通道。货物从最近的驿站发出（bio → request），快递员（softirq）定期从 per-CPU 站点取货，送到对应的硬件队列（NVMe 的内部多队列）。这样即使某个驿站繁忙，其他驿站也不受影响，真正实现了并发。

---

## 9. 关联文章

- **IO scheduler**（相关）：mq-deadline、bfq 等为 blk-mq 设计的调度器
- **block layer**（相关）：bio → request 转换