# Linux Kernel blk-mq (Block Multi-Queue) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`block/blk-mq.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 blk-mq？

**blk-mq**（Block Multi-Queue）是 Linux 3.13+ 引入的**多队列块设备队列**，专为 NVMe、SSD 等高 IOPS 设备设计。

**核心问题旧模型有**：
- 单一 `request_queue` + `elv_dispatch_request` → 所有请求排队到一个队列
- 多核下锁竞争严重，无法并行处理请求

**blk-mq 解决方案**：
- 每个 CPU 一个 `software queue`（软队列）
- 每个硬件控制器一个 `hardware queue`（硬队列）
- 软硬队列通过 `blk_mq_hw_ctx` 解耦，锁竞争大幅减少

---

## 1. 核心数据结构

### 1.1 struct request_queue

```c
// block/blk-mq.c — request_queue（块设备请求队列）
struct request_queue {
    struct blk_mq_tag_set   *tag_set;     // 标签集（共享 tag/rq 池）
    struct blk_mq_hw_ctx    **queue_hw_ctx; // 每个 CPU 一个硬件队列
    unsigned int            nr_hw_queues;   // 硬件队列数

    /* 软硬队列映射 */
    struct blk_mq_ctx_map    queue_ctx_map;  // CPU → ctx 映射

    /* 请求处理 */
    blk_mq_req_fn_t          *dq;           // 调度函数

    /* I/O 调度器 */
    struct elevator_queue    *elevator;
};
```

### 1.2 blk_mq_hw_ctx — 硬件队列

```c
// block/blk-mq.c — blk_mq_hw_ctx（每个硬件队列）
struct blk_mq_hw_ctx {
    struct request_queue    *queue;       // 所属队列
    struct blk_mq_ctx_map    ctx_map;     // CPU 亲和

    /* 软中断处理 */
    __u32                   *dispatch;     // 调度到 hw_ctx 的请求
    unsigned int            dispatch_busy;  // 调度忙碌标志

    /* 请求派发 */
    struct list_head         dispatch;     // 待派发的请求链表

    /* 派发锁 */
    spinlock_t              lock;

    /* tags */
    struct blk_mq_tags       *tags;        // 请求标签
    struct blk_mq_tags       *sched_tags;  // 调度标签

    /* CPU 亲和 */
    cpumask_var_t           cpumask;      // 亲和的 CPU
    int                     numa_node;

    /* I/O 计数器 */
    unsigned long           queue_len;
};
```

### 1.3 blk_mq_ctx — per-CPU 软队列

```c
// block/blk-mq.c — blk_mq_ctx（per-CPU 软队列）
struct blk_mq_ctx {
    struct request_queue   *queue;       // 所属队列
    unsigned int           cpu;           // 关联的 CPU

    /* per-CPU 标记表 */
    struct blk_mq_tags     *tags;

    /* 待处理请求链表（per-CPU）*/
    struct list_head       rq_list;     // 提交到硬件队列的请求

    spinlock_t             lock;         // 保护 rq_list
};
```

---

## 2. 提交请求：blk_mq_submit_request

```c
// block/blk-mq.c — blk_mq_submit_request
void blk_mq_submit_request(struct request *rq)
{
    struct blk_mq_ctx *ctx = blk_mq_get_ctx(rq->q);  // 当前 CPU 的 ctx
    struct blk_mq_hw_ctx *hctx = blk_mq_get_cached_hw_ctx(ctx);

    // 1. 分配 tag（从 per-CPU 池获取）
    //    tag = blk_mq_get_tag(hctx);
    //    如果 tag 池耗尽，请求进入 ctx->rq_list 等待

    // 2. 设置请求的 ctx 和 hctx
    rq->mq_ctx = ctx;
    rq->hctx = hctx;

    // 3. 尝试直接派发
    if (blk_mq_try_issue_directly(hctx, rq, false))
        return;  // 成功

    // 4. 失败：加入软队列等待
    spin_lock(&ctx->lock);
    list_add_tail(&rq->queuelist, &ctx->rq_list);
    spin_unlock(&ctx->lock);

    // 5. 触发软中断让 hctx 处理
    blk_mq_trigger_softirq(hctx);
}
```

---

## 3. 处理请求：blk_mq_sched_dispatch

```c
// block/blk-mq.c — __blk_mq_run_hw_ctx
static void __blk_mq_run_hw_ctx(struct blk_mq_hw_ctx *hctx)
{
    // 1. 处理已调度的请求
    while ((rq = list_first_entry_or_null(&hctx->dispatch, ...))) {
        list_del_init(&rq->list);
        __blk_mq_try_issue_request(hctx, rq);
    }

    // 2. 从 per-CPU 软队列收集请求
    ctx = blk_mq_map_queues(hctx);
    spin_lock(&ctx->lock);
    while ((rq = list_first_entry_or_null(&ctx->rq_list, ...))) {
        list_move_tail(&rq->queuelist, &hctx->dispatch);
    }
    spin_unlock(&ctx->lock);
    goto retry;

    // 3. 如果是 I/O 调度器，调用调度器派发
    if (queue->elevator->type->ops.dispatch)
        rq = elevator_dispatch_fn(queue);
}
```

---

## 4. 多队列映射

```
CPU → blk_mq_ctx（软队列）→ blk_mq_hw_ctx（硬队列）→ 设备

           ┌──────────────────────────────┐
           │      request_queue           │
           └──────────────────────────────┘
                        │
    ┌───────────────────┼───────────────────┐
    │                   │                   │
CPU-0 ctx           CPU-1 ctx           CPU-N ctx
    │                   │                   │
    ▼                   ▼                   ▼
hw_ctx[0]           hw_ctx[1]           hw_ctx[N]
(NVMe 队列 0)      (NVMe 队列 1)       (NVMe 队列 N)

软队列数量 = CPU 数量（每个 CPU 一个）
硬队列数量 = min(NVMe 队列数, nr_cpu_ids)
映射策略：blk_mq_map_queues() → 轮询或按 NUMA 节点分组
```

---

## 5. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| per-CPU 软队列 | 减少锁竞争：每个 CPU 有独立的 rq_list |
| 软硬队列分离 | 软队列数 = CPU 数，硬队列数 = NVMe 队列数，按需映射 |
| tag 池 per hctx | 每个硬件队列有独立的请求标签池 |
| blk_mq_trigger_softirq | 批量收集后触发一次软中断，而不是每个请求一次 |

---

## 6. 参考

| 文件 | 内容 |
|------|------|
| `block/blk-mq.c` | `blk_mq_submit_request`、`__blk_mq_run_hw_ctx`、`blk_mq_get_ctx` |
| `include/linux/blk-mq.h` | `struct blk_mq_hw_ctx`、`blk_mq_ctx` |
