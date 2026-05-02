# Linux Block Layer 深度分析：Bio、请求队列与调度器

> Kernel Source: Linux 7.0-rc1 (blk-core.c / blk-mq.c / blkdev.h)
> 分析工具: doom-lsp (clangd LSP)

---

## 一、BIO 与 Request：submit_bio 完整路径

### 1.1 入口：submit_bio → submit_bio_noacct

```c
// block/blk-core.c:916
void submit_bio(struct bio *bio)
{
    if (bio_op(bio) == REQ_OP_READ) {
        task_io_account_read(bio->bi_iter.bi_size);
        count_vm_events(PGPGIN, bio_sectors(bio));
    } else if (bio_op(bio) == REQ_OP_WRITE) {
        count_vm_events(PGPGOUT, bio_sectors(bio));
    }
    bio_set_ioprio(bio);       // 基于进程 nice 值初始化 IOPRIO
    submit_bio_noacct(bio);
}
EXPORT_SYMBOL(submit_bio);
```

`submit_bio_noacct` 是入口门神，只负责初始化 cgroup 统计、trace 记录，然后分发：

```c
// :780
void submit_bio_noacct(struct bio *bio)
{
    blk_cgroup_bio_start(bio);
    if (!bio_flagged(bio, BIO_TRACE_COMPLETION)) {
        trace_block_bio_queue(bio);
        bio_set_flag(bio, BIO_TRACE_COMPLETION);
    }

    if (current->bio_list) {
        // 嵌套 submit_bio 场景（DM/LVM 等 stacked 设备）
        if (split)
            bio_list_add_head(&current->bio_list[0], bio);
        else
            bio_list_add(&current->bio_list[0], bio);
    } else if (!bdev_test_flag(bio->bi_bdev, BD_HAS_SUBMIT_BIO)) {
        // blk-mq 设备走这里
        __submit_bio_noacct_mq(bio);
    } else {
        // 传统 SCSI / 虚拟设备走这里
        __submit_bio_noacct(bio);
    }
}
```

**关键决策点**：检查 `BD_HAS_SUBMIT_BIO` 标志。如果块设备驱动在 `bd_read_write` 或等效路径设置了此标志，说明该设备有自己的 `->submit_bio()` 实现（例如 SCSI、virtio-blk）；否则默认使用 blk-mq 路径。

### 1.2 `__submit_bio_noacct_mq` → `__submit_bio`

```c
// :715
static void __submit_bio_noacct_mq(struct bio *bio)
{
    struct bio_list bio_list[2] = { };
    current->bio_list = bio_list;

    do {
        __submit_bio(bio);
    } while ((bio = bio_list_pop(&bio_list[0])));

    current->bio_list = NULL;
}
```

这里用 `current->bio_list` 实现递归收集。关键在于 `__submit_bio`：

```c
// :627
static void __submit_bio(struct bio *bio)
{
    struct blk_plug plug;
    blk_start_plug(&plug);

    if (!bdev_test_flag(bio->bi_bdev, BD_HAS_SUBMIT_BIO)) {
        blk_mq_submit_bio(bio);        // ← blk-mq 路径
    } else if (likely(bio_queue_enter(bio) == 0)) {
        struct gendisk *disk = bio->bi_bdev->bd_disk;

        if ((bio->bi_opf & REQ_POLLED) &&
            !(disk->queue->limits.features & BLK_FEAT_POLL)) {
            bio->bi_status = BLK_STS_NOTSUPP;
            bio_endio(bio);
        } else {
            disk->fops->submit_bio(bio);   // 驱动自定义 submit_bio
        }
        blk_queue_exit(disk->queue);
    }

    blk_finish_plug(&plug);
}
```

### 1.3 `blk_mq_submit_bio`：BIO → Request 的转换

这是 blk-mq 的核心入口（:3141）。完整路径：

```c
void blk_mq_submit_bio(struct bio *bio)
{
    struct request_queue *q = bdev_get_queue(bio->bi_bdev);
    struct blk_plug *plug = current->plug;
    const int is_sync = op_is_sync(bio->bi_opf);
    struct blk_mq_hw_ctx *hctx;
    unsigned int nr_segs;
    struct request *rq;
    blk_status_t ret;

    // ① 从 plug 的 cached_rqs 中尝试取一个可复用的 request
    rq = blk_mq_peek_cached_request(plug, q, bio->bi_opf);

    // ② zone-write-plugging 生物已持有 q 引用，跳过获取
    if (bio_zone_write_plugging(bio)) {
        nr_segs = bio->__bi_nr_segments;
        if (rq)
            blk_queue_exit(q);
        goto new_request;
    }

    // ③ 没有可复用 request，则加 q_usage_counter 引用
    if (!rq) {
        if (unlikely(bio_queue_enter(bio)))   // 队列被 freeze 时阻塞
            return;
    }

    // ④ 对齐检查 / poll 能力检查
    if (unlikely(bio_unaligned(bio, q))) {
        bio_io_error(bio);
        goto queue_exit;
    }
    if ((bio->bi_opf & REQ_POLLED) && !blk_mq_can_poll(q)) {
        bio->bi_status = BLK_STS_NOTSUPP;
        bio_endio(bio);
        goto queue_exit;
    }

    // ⑤ BIO 分割（超过 queue limits 就拆开）
    bio = __bio_split_to_limits(bio, &q->limits, &nr_segs);
    if (!bio)
        goto queue_exit;

    // ⑥ 完整性校验（t10-pi / 数据保护）
    integrity_action = bio_integrity_action(bio);
    if (integrity_action)
        bio_integrity_prep(bio, integrity_action);

    // ⑦ 初始化 issue_time（用于 cgroup IO 统计）
    blk_mq_bio_issue_init(q, bio);

    // ⑧ 尝试 BIO 合并（plug merge 或 scheduler merge）
    if (blk_mq_attempt_bio_merge(q, bio, nr_segs))
        goto queue_exit;

    // ⑨ zone-write-plugging 检查
    if (bio_needs_zone_write_plugging(bio)) {
        if (blk_zone_plug_bio(bio, nr_segs))
            goto queue_exit;
    }

new_request:
    // ⑩ 使用缓存的 request 或分配新的
    if (rq) {
        blk_mq_use_cached_rq(rq, plug, bio);
    } else {
        rq = blk_mq_get_new_requests(q, plug, bio);
        if (unlikely(!rq)) {
            if (bio->bi_opf & REQ_NOWAIT)
                bio_wouldblock_error(bio);
            goto queue_exit;
        }
    }

    trace_block_getrq(bio);
    rq_qos_track(q, rq, bio);          // WBT / iostat 记录 start_time

    blk_mq_bio_to_request(rq, bio, nr_segs);

    ret = blk_crypto_rq_get_keyslot(rq);  // 内联加密 keyslot 获取
    if (ret != BLK_STS_OK) {
        bio->bi_status = ret;
        bio_endio(bio);
        blk_mq_free_request(rq);
        return;
    }

    if (bio_zone_write_plugging(bio))
        blk_zone_write_plug_init_request(rq);

    // ⑪ flush 请求走特殊插入路径
    if (op_is_flush(bio->bi_opf) && blk_insert_flush(rq))
        return;

    // ⑫ 有 plug → 加入 plug 的 rq 列表（延迟 dispatch）
    if (plug) {
        blk_add_rq_to_plug(plug, rq);
        return;
    }

    // ⑬ 无 plug 或无法合并 → 立即 dispatch
    hctx = rq->mq_hctx;
    if ((rq->rq_flags & RQF_USE_SCHED) ||
        (hctx->dispatch_busy && (q->nr_hw_queues == 1 || !is_sync))) {
        // 需要 scheduler 或 队列繁忙 → 走调度器路径
        blk_mq_insert_request(rq, 0);
        blk_mq_run_hw_queue(hctx, true);
    } else {
        // 直接尝试派发到硬件
        blk_mq_run_dispatch_ops(q, blk_mq_try_issue_directly(hctx, rq));
    }
    return;

queue_exit:
    if (!rq)
        blk_queue_exit(q);
}
```

**核心设计哲学**：BIO 到 Request 的转换不是简单的 1:1 映射。blk-mq 会：

1. **先尝试合并**：plug merge（当前进程 plug 列表） > scheduler bio merge
2. **延迟派发**：有 plug 时不立即下硬件，而是积累一批再统一 `blk_flush_plug`
3. **分割超限 BIO**：`__bio_split_to_limits` 拆成多段
4. **zone write plugging**：顺序写入的 HDD/SSD zone 设备通过 zone plug 机制减少写放大

---

## 二、BIO 合并条件详解

### 2.1 `blk_mq_attempt_bio_merge` 的两阶段检查

```c
// block/blk-mq.c:3034
static bool blk_mq_attempt_bio_merge(struct request_queue *q,
                 struct bio *bio, unsigned int nr_segs)
{
    if (!blk_queue_nomerges(q) && bio_mergeable(bio)) {
        if (blk_attempt_plug_merge(q, bio, nr_segs))   // ← 阶段1：plug merge
            return true;
        if (blk_mq_sched_bio_merge(q, bio, nr_segs))  // ← 阶段2：scheduler merge
            return true;
    }
    return false;
}
```

**阶段 1：plug merge**（:1408）
plug 是每个进程级别的请求缓冲（`struct blk_plug` 在 task_struct 中）。当进程执行 IO 时，`blk_start_plug` 创建局部 plug，积累一批 request 后在进程调度时或显式调用 `blk_finish_plug` 时统一 flush。

plug merge 的判断条件（grep 找 `blk_attempt_plug_merge` 实现）：
- request 与 bio 在同一个 queue
- `bio_mergeable()` 检查 BIO 是否可合并（不是 passthrough、不是 flush 等）
- 物理连续性：`blk_rq_pos(rq) + blk_rq_sectors(rq) == bio->bi_iter.bi_sector`
- request 没有被标记 `REQ_NOMERGE`（通常错误 handling 的 request 会设）

**阶段 2：scheduler bio merge**
```c
// block/blk-mq-sched.c
bool blk_mq_sched_bio_merge(struct request_queue *q, struct bio *bio,
                            unsigned int nr_segs)
{
    if (q->elevator) {
        // 调用 elevator 的 .bio_merge_fn
        return q->elevator->type->ops.bio_merge(q, bio, nr_segs);
    }
    return false;
}
```

不同的调度器实现自己的 `.bio_merge_fn`。例如 mq-deadline 在 `dd_bio_merge()` 中只允许后向合并（相邻区域），而 bfq 可以做更多复杂判断。

**不可合并的 BIO**：
- `REQ_OP_DRV_IN/OUT`（passthrough）
- 设了 `REQ_NOMERGE` flag
- 来自不同 cgroup（blkcg 隔离）
- 超过 queue 的 `max_sectors` 限制（需先 split）

---

## 三、blk-mq 多队列架构

### 3.1 硬件队列与 CPU 的映射关系

每个 `struct request_queue` 持有一组 `struct blk_mq_hw_ctx`：

```c
// include/linux/blkdev.h:request_queue
struct request_queue {
    unsigned int        nr_hw_queues;      // 硬件队列数
    struct blk_mq_hw_ctx * __rcu *queue_hw_ctx __counted_by_ptr(nr_hw_queues);

    /* 软件队列：每 CPU 一个 */
    struct blk_mq_ctx __percpu *queue_ctx;
    ...
};
```

**映射规则**：

| 场景 | nr_hw_queues | 映射方式 |
|------|-------------|---------|
| SATA / SCSI | 通常 1 | 所有 CPU 共用同一个 hctx |
| NVMe | 通常 = CPU 数（或少一些） | `blk_mq_ctx → hctx` 通过 `cpumask` |
| 单队列 legacy | 1 | 强制用 HCTX_TYPE_DEFAULT |

每个 CPU 有一个 `struct blk_mq_ctx`，其中 `ctx->index_hw[hctx->type]` 是 sbitmap 中标记该 ctx 与 hctx 关联的 bit。

hctx 类型枚举（`enum hctx_type`）：
- `HCTX_TYPE_DEFAULT` — 普通读写请求
- `HCTX_TYPE_READ` — 同步读请求（可以优先派发）
- `HCTX_TYPE_POLL` — poll 模式请求（无锁轮询）

### 3.2 `blk_mq_sched_insert_request` 完整路径

当 rq 需要经过 IO 调度器时，调用 `blk_mq_insert_request`（:2623）：

```c
static void blk_mq_insert_request(struct request *rq, blk_insert_t flags)
{
    struct request_queue *q = rq->q;
    struct blk_mq_ctx *ctx = rq->mq_ctx;
    struct blk_mq_hw_ctx *hctx = rq->mq_hctx;

    if (blk_rq_is_passthrough(rq)) {
        // passthrough 直接进 hctx->dispatch（绕过 scheduler）
        blk_mq_request_bypass_insert(rq, flags);
    } else if (req_op(rq) == REQ_OP_FLUSH) {
        // flush 请求也直接进 hctx->dispatch（带 BLK_MQ_INSERT_AT_HEAD）
        blk_mq_request_bypass_insert(rq, BLK_MQ_INSERT_AT_HEAD);
    } else if (q->elevator) {
        // 有 elevator → 调用调度器的 insert_requests
        LIST_HEAD(list);
        WARN_ON_ONCE(rq->tag != BLK_MQ_NO_TAG);
        list_add(&rq->queuelist, &list);
        q->elevator->type->ops.insert_requests(hctx, &list, flags);
    } else {
        // 无 elevator → 进入 per-cpu sw queue（ctx->rq_lists）
        trace_block_rq_insert(rq);
        spin_lock(&ctx->lock);
        if (flags & BLK_MQ_INSERT_AT_HEAD)
            list_add(&rq->queuelist, &ctx->rq_lists[hctx->type]);
        else
            list_add_tail(&rq->queuelist, &ctx->rq_lists[hctx->type]);
        blk_mq_hctx_mark_pending(hctx, ctx);
        spin_unlock(&ctx->lock);
    }
}
```

**三层队列架构**：

```
BIO
  ↓ blk_mq_submit_bio()
request
  ├─ 有 plug → 加入 plug.cached_rqs（延迟）
  ├─ 有 scheduler → elevator queue（blk_mq_ctx → sw queue → elevator）
  ├─ passthrough/flush → hctx->dispatch (bypass)
  └─ 无 scheduler → ctx->rq_lists[hctx->type] (sw queue)
```

---

## 四、调度算法：mq-deadline 与 BFQ

### 4.1 mq-deadline

mq-deadline 是多队列时代的 deadline 算法实现，核心目标是**保障延迟**（不饿死），而非吞吐。

**数据结构**：
- 每个 hctx 有 4 个红黑树（`struct deadline`**）：`wb_list[WRITE]`、`rb_root[READ]`、`fb_list[WRITE]`、`rb_root[WRITE]`
- `wait_list` 双向链表：因扇区不连续而无法合并的请求等待

**关键参数**：
- `read_expire` / `write_expire`：READ/WRITE 过期时间（默认 500ms / 500ms）
- `fifo_batch`：一次 dispatch 多少个同方向的请求（默认 4）
- `writes_starved`：READ 饥饿阈值（READ 连续服务 N 批后切 WRITE）

**dispatch 逻辑**（`dd_dispatch_request`）：

```c
static struct request *dd_dispatch_request(struct blk_mq_hw_ctx *hctx)
{
    struct deadline_data *dd = hctx->sched_data;
    struct request *rq;

    // ① 超期 READ优先
    if (!list_empty(&dd->wait_list)) {
        rq = dd_from_waitlist(hctx);
        if (rq) goto done;
    }

    // ② 从 READ 红黑树拿最旧的
    rq = deadline_fetch_rq(dd, READ);
    if (rq) goto dispatch_write_batch;

    // ③ 超过 writes_starved 阈值 → 切 WRITE
    if (dd->writes_starved >= dd->writes_starved_threshold)
        goto dispatch_write;

    // ④ WRITE 红黑树
    rq = deadline_fetch_rq(dd, WRITE);
    if (!rq) {
        // 没有 WRITE 了，等 READ
        rq = dd_move_waiting_rq_to_front(dd);
        if (rq) goto done;
        return NULL;
    }

dispatch_write_batch:
    // ⑤ 批量处理 WRITE
    deadline_move_rq_to_fifo(&dd->wb_list, rq);
    ...
done:
    return rq;
}
```

**合并策略**（`dd_bio_merge`）：
- 仅允许 **后向合并**（backward merge）：bio 接到 request **前面**
- 合并条件：`bio_end_sector(rq) == bio->bi_iter.bi_sector`
- 不允许前向合并（避免饥饿）

### 4.2 BFQ（Budget Fairness Queueing）

BFQ 是基于权重的公平调度算法，目标是 **吞吐量公平性 + 低延迟**，适合多媒体/桌面场景。

**核心数据结构**：
```c
struct bfq_queue {
    struct bfq_entity *entity;        // 调度实体
    struct bfq_data *bfqd;            // per-hctx 全局状态
    enum bfq_queue_priority priority; // BE / RT（实时）
    unsigned int weight;              // 调度权重
    u64 dispatch_start;               // 上次 dispatch 时间
    ...
};
```

**调度层级**：
```
bfq_data (per-hctx)
  └── bfq_service_tree (3个：RT/BE/IDLE)
        └── bfq_entity (红黑树)
              └── bfq_queue (每个进程一个)
```

**权重 fairness**：BFQ 按权重比例分配磁盘时间片，而非简单的时间片轮转。高权重进程获得更多带宽。

**公平性保证**：
- 同级队列间严格按权重比例分配
- 实体选择使用 "最早虚拟 Finish Time" 算法（`bfq_wf2q.c` 中的 `bfq_lookup_next_entity`）
- cgroup 支持：通过 `bfq_cgroup.c` 实现 blkcg 层级权重

**key difference vs mq-deadline**：
| 特性 | mq-deadline | BFQ |
|------|------------|-----|
| 目标 | 延迟保障（不饿死） | 公平 + 吞吐 |
| 饥饿控制 | 时间片 + writes_starved | 权重 + 虚拟时间 |
| 合并 | 仅后向 | 允许前向 + 后向 |
| cgroup | 无 | 完全支持 |

---

## 五、Dispatch 路径：blk_mq_try_issue_directly vs blk_mq_issue_rq

### 5.1 `blk_mq_try_issue_directly`

当 plug 中没有缓存 request，或从 scheduler 出来后，路径是 `blk_mq_try_issue_directly`（:2768）：

```c
static void blk_mq_try_issue_directly(struct blk_mq_hw_ctx *hctx,
        struct request *rq)
{
    blk_status_t ret;

    // ① hctx 已停止或 queue 被 quiesce → 退回 scheduler 路径
    if (blk_mq_hctx_stopped(hctx) || blk_queue_quiesced(rq->q)) {
        blk_mq_insert_request(rq, 0);
        blk_mq_run_hw_queue(hctx, false);
        return;
    }

    // ② 需要 scheduler 或 获取 tag/budget 失败 → 退回
    if ((rq->rq_flags & RQF_USE_SCHED) || !blk_mq_get_budget_and_tag(rq)) {
        blk_mq_insert_request(rq, 0);
        blk_mq_run_hw_queue(hctx, rq->cmd_flags & REQ_NOWAIT);
        return;
    }

    // ③ 真正下发到驱动
    ret = __blk_mq_issue_directly(hctx, rq, true);
    switch (ret) {
    case BLK_STS_OK:
        break;
    case BLK_STS_RESOURCE:
    case BLK_STS_DEV_RESOURCE:
        // 资源不足 → 插入 hctx->dispatch（priority bypass queue）
        blk_mq_request_bypass_insert(rq, 0);
        blk_mq_run_hw_queue(hctx, false);
        break;
    default:
        blk_mq_end_request(rq, ret);   // 错误直接结束
        break;
    }
}
```

### 5.2 `__blk_mq_issue_directly`

```c
static blk_status_t __blk_mq_issue_directly(struct blk_mq_hw_ctx *hctx,
                                            struct request *rq, bool last)
{
    struct request_queue *q = hctx->queue;
    blk_status_t ret;

    // 调用驱动的 .queue_rq 回调
    ret = q->mq_ops->queue_rq(hctx, rq);

    if (ret == BLK_STS_OK && last)
        blk_mq_commit_rqs(hctx, -1, false);  // 通知驱动 last
    return ret;
}
```

### 5.3 `blk_mq_request_bypass_insert` — hctx->dispatch

当资源不足（`BLK_STS_RESOURCE`）或需要保证优先级（flush/passthrough），request 被插入 `hctx->dispatch` 链表：

```c
static void blk_mq_request_bypass_insert(struct request *rq,
        blk_insert_t flags)
{
    struct blk_mq_hw_ctx *hctx = rq->mq_hctx;

    spin_lock(&hctx->lock);
    if (flags & BLK_MQ_INSERT_AT_HEAD)
        list_add(&rq->queuelist, &hctx->dispatch);
    else
        list_add_tail(&rq->queuelist, &hctx->dispatch);
    spin_unlock(&hctx->lock);
}
```

`hctx->dispatch` 是**优先级派发队列**，其中请求优先于 sw queue 中的请求被处理。

### 5.4 dispatch 循环：`blk_mq_dispatch_rq_list`

```c
// block/blk-mq-sched.c:216
bool blk_mq_dispatch_rq_list(struct blk_mq_hw_ctx *hctx,
                             struct list_head *list, bool got_budget)
{
    // list 是要派发的 request 链表
    // got_budget 表示当前是否持有派发 budget

    while (!list_empty(list)) {
        struct request *rq = list_first_entry(list, struct request, queuelist);

        // 获取 budget（如果没有的话）
        if (!got_budget) {
            if (!blk_mq_get_dispatch_budget(hctx, rq))
                break;
            got_budget = true;
        }

        // 调用驱动的 queue_rq
        ret = hctx->queue->mq_ops->queue_rq(hctx, rq);
        if (ret == BLK_STS_RESOURCE || ret == BLK_STS_DEV_RESOURCE)
            break;
        if (ret != BLK_STS_OK)
            blk_mq_end_request(rq, ret);  // 错误
    }

    // commit 已成功派发的 rq（通知驱动 "这批结束了"）
    if (queued)
        blk_mq_commit_rqs(hctx, queued, false);
}
```

### 5.5 对比总览

| 路径 | 场景 | 队列 |
|------|------|------|
| `blk_mq_try_issue_directly` | plug 空、无 scheduler、同步 IO | 直接 → 驱动 |
| `blk_mq_insert_request` | 有 scheduler、需要排序 | → elevator 或 sw queue |
| `blk_mq_request_bypass_insert` | flush/passthrough/资源不足 | → hctx->dispatch (bypass) |

---

## 六、完成路径：blk_mq_end_request vs blk_mq_free_request

### 6.1 完整调用链

```
硬件完成中断
  → 驱动调用 blk_mq_complete_request(rq)
      → __blk_mq_complete_request()
          → blk_mq_free_request()      ← 释放 tag
          或
          → blk_mq_end_request()        ← end_io + free

批量完成（iopoll / irq mode）
  → blk_mq_end_request_batch(iob)
      → __blk_mq_end_request_acct()    ← 统计
      → blk_mq_free_request()
```

### 6.2 `blk_mq_end_request`

```c
// block/blk-mq.c:1176
void blk_mq_end_request(struct request *rq, blk_status_t error)
{
    __blk_mq_end_request(rq, error);
}
EXPORT_SYMBOL(blk_mq_end_request);

// :1159
inline void __blk_mq_end_request(struct request *rq, blk_status_t error)
{
    u64 now = 0;

    if (rq->rq_flags & RQF_IO_STAT) {
        now = blk_time_get_ns();
        __blk_mq_end_request_acct(rq, now);   // 更新 io stat
    }

    if (rq->end_io) {
        rq->end_io(rq, error);
    } else {
        blk_mq_free_request(rq);
    }
}
```

**两个分支**：
1. **有 `end_io` 回调**：用于多路径（DM 链路上游）、心跳等场景，调用方自己决定后续
2. **无 `end_io`**：直接 `blk_mq_free_request`

### 6.3 `blk_mq_free_request` 与 `__blk_mq_free_request`

```c
// :820
void blk_mq_free_request(struct request *rq)
{
    __blk_mq_free_request(rq);
}

// :799
static void __blk_mq_free_request(struct request *rq)
{
    struct request_queue *q = rq->q;
    struct blk_mq_hw_ctx *hctx = rq->mq_hctx;
    struct blk_mq_ctx *ctx = rq->mq_ctx;

    // ① 释放 tag（交还分配器）
    blk_mq_put_tag(hctx->tags, rq->tag, ctx);

    // ② 释放 budget（如果持有的话）
    blk_mq_put_budget(hctx);

    // ③ 更新 hctx 的 sbitmap（ctx 关联标记）
    blk_mq_hctx_clear_pending(hctx, ctx);

    // ④ 减少 q_usage_counter（对应 bio_queue_enter 的 hold）
    blk_queue_exit(q);
}
```

**tag + budget 的成对释放**是 blk-mq 资源管理的核心：
- `bio_queue_enter(q)` → `q_usage_counter` +1
- `blk_queue_exit(q)` → `q_usage_counter` -1
- `blk_mq_get_budget_and_tag()` → tag + budget 分配
- `blk_mq_put_tag` / `blk_mq_put_budget` → 归还

### 6.4 批量完成 `blk_mq_end_request_batch`

```c
// :1197
void blk_mq_end_request_batch(struct io_comp_batch *iob)
{
    u64 now = blk_time_get_ns();
    struct request *rq;

    rq = rq_list_pop(&iob->req_list);
    while (rq) {
        if (rq->rq_flags & RQF_IO_STAT)
            __blk_mq_end_request_acct(rq, now);  // 批量时间记账
        blk_mq_free_request(rq);
        rq = rq_list_pop(&iob->req_list);
    }
}
```

用于 poll 模式和硬件批量完成（NVMe IRQ coalescing），减少 per-request 开销。

---

## 七、Writeback 与 Block 层的协作

### 7.1 Page Writeback 到 Block Layer 的路径

```
mm/page-writeback.c
  → write_one_credit()
  → balance_dirty_pages()
  →wb_writeback() ─────────────────┐
                                  ↓
fs/fs-writeback.c                 |
  → wb_writeback_work::fn  (struct writeback_control)
  → write_cache_pages() ───────────┐
                                  ↓
  → mpage_submit_page() ──────────┐
                                  ↓
  → do_writepages() ──────────────↓
      address_space::writepages   ↓
        block_write_full_folio()   ↓   fs/buffer.c
          → __block_write_full_folio()
              → submit_bio() ──────────────────→ block layer
```

### 7.2 `submit_bio` 与 Writeback 的质量保证

Block 层通过几个机制配合 writeback：

**1. `REQ_FUA` / `REQ_PREFLUSH`：电容保护**

```c
// writeback 场景（fs/buffer.c）
if (dio && defer_after_block)
    submit_bio(bio);              // 延迟 flush
else if (atomic)
    submit_bio_with_fua(bio);     // 包含 REQ_FUA
else
    submit_bio(bio);
```

`REQ_OP_WRITE` + `REQ_PREFLUSH` 触发写前 flush（确保数据落盘），`REQ_FUA` 触发写后 flush。电容保护的 SSD 在断电时靠电容完成写入；HDD 则用 flush 指令 `ata/flush` 等。

**2. `bio_set_op_attrs` 与 write cache 策略**

```c
if (blk_queue_write_cache(q)) {
    // 设备有 write-back cache
    if (wbc->sync_mode == WB_SYNC_ALL)
        bio->bi_opf |= REQ_PREFLUSH;  // fsync 时需要 flush
}
```

用户通过 `fsync(2)` / `fdatasync(2)` 触发的 writeback 会带 `REQ_PREFLUSH`，确保元数据同步。

**3. `QUEUE_FLAG_BIO_ISSUE_TIME` 与 cgroup IO 统计**

```c
// blk_mq_bio_issue_init()
if (test_bit(QUEUE_FLAG_BIO_ISSUE_TIME, &q->queue_flags))
    bio->issue_time_ns = blk_time_get_ns();
```

blkcg 通过 `bio_issue_time` 计算 IO 延迟分布，用于 cgroup 权重公平性验证。

**4. blk-throttle（IO 限速）与 writeback**

```c
// blk_throtl_bio() 被 submit_bio_noacct 调用
if (blk_throtl_bio(bio))
    return;  // 被限速的 bio 直接返回，不入队
```

页面回收（writeback）是高频操作，如果所有 dirty page 都被限速，会导致系统阻塞。blk-throttle 在 writeback 场景有特殊处理：thrrottling 不影响同步 IO 的最小带宽保证。

### 7.3 Zone Write Plugging 与 Writeback

顺序写入的 zoned 设备（NVMe ZNS、SMR HDD）通过 zone write plug 机制减少写入碎片：

```c
// 写入开始时 plug
if (bio_needs_zone_write_plugging(bio))
    blk_zone_plug_bio(bio, nr_segs);
```

zone write plug 会延迟提交 bio，积累同 zone 的多个写请求后再一起下发，减少 zone 写入放大。这与 page writeback 的批量聚集（本意是让进程积累更多 dirty page）有协同效应。

---

## 八、核心数据结构关系图

```
┌─────────────────────────────────────────────────────┐
│ submit_bio(bio)                                     │
│   → submit_bio_noacct(bio)                         │
│        → __submit_bio_noacct_mq()                   │
│             → __submit_bio()                        │
│                  → blk_mq_submit_bio()              │
│                       │                             │
│               ┌───────┴───────┐                    │
│               ↓               ↓                    │
│        plug cached      get_new_request            │
│         rq merge          │                        │
│               ↓            ↓                        │
│        blk_add_rq_to_plug │ blk_mq_bio_to_request  │
│               ↓            ↓                        │
│         plug.flush()  →  blk_mq_insert_request     │
│               ↓            ↓                        │
│         blk_flush_plug()  ├─ elevator: → sw queue  │
│               ↓            ├─ passthrough: → dispatch
│         触发 dispatch     └─ no-sched: → ctx rq_list
│               ↓                               ↓
│    blk_mq_run_hw_queue  ─────────────────────────┐
│               ↓                                  ↓
│   blk_mq_dispatch_rq_list  ←── hctx->dispatch ←──┘
│               ↓
│   hctx->queue->mq_ops->queue_rq()  ← 驱动派发
│               ↓
│   hardware completion → blk_mq_end_request → blk_mq_free_request
```

---

## 九、关键代码位置索引

| 功能 | 文件:行号 |
|------|----------|
| `submit_bio` 入口 | `blk-core.c:916` |
| `submit_bio_noacct` | `blk-core.c:780` |
| `__submit_bio` | `blk-core.c:627` |
| `__submit_bio_noacct_mq` | `blk-core.c:715` |
| `blk_mq_submit_bio` | `blk-mq.c:3141` |
| `blk_mq_peek_cached_request` | `blk-mq.c:3080` |
| `blk_mq_attempt_bio_merge` | `blk-mq.c:3034` |
| `blk_mq_insert_request` | `blk-mq.c:2623` |
| `blk_mq_try_issue_directly` | `blk-mq.c:2768` |
| `__blk_mq_issue_directly` | `blk-mq-sched.c:...` (内联) |
| `blk_mq_request_bypass_insert` | `blk-mq.c:...` (inline) |
| `blk_mq_dispatch_rq_list` | `blk-mq-sched.c:216` |
| `blk_mq_end_request` | `blk-mq.c:1176` |
| `__blk_mq_end_request` | `blk-mq.c:1159` |
| `blk_mq_free_request` | `blk-mq.c:820` |
| `__blk_mq_free_request` | `blk-mq.c:799` |
| `blk_mq_end_request_batch` | `blk-mq.c:1197` |
| `blk_add_rq_to_plug` | `blk-mq.c:1408` |
| `bio_split_to_limits` | `blk-core.c:bio_split_to_limits` |
| `blk_insert_flush` | `blk-mq.c:blk_insert_flush` |
| `mq-deadline dispatch` | `blk-mq-sched.c` dd_* 函数 |
| `BFQ dispatch` | `bfq-iosched.c:bfq_dispatch_request` |
| `elevator registered` | `elevator.c:elevator_register_fn` |
| `blk_plug` struct | `include/linux/blkdev.h` (struct blk_plug) |
| `request_queue` | `include/linux/blkdev.h:request_queue` |
| `blk_mq_hw_ctx` | `block/blk-mq.h` (struct blk_mq_hw_ctx) |

---

## 十、设计哲学总结

1. **BIO 不是 request**：BIO 是最小 IO 描述单元，但经过 merge / split / alloc 后才变成 request。两者不是一一对应关系。

2. **Plug 延迟派发**：以进程为单位的 request 缓存，减少锁竞争，让合并在进程上下文内完成。

3. **调度器可插拔**：elevator 框架统一管理 sw queue → hw queue 的映射，调度算法完全独立于块设备驱动。

4. **资源标签化**：tag + budget + q_usage_counter 三层资源管理，每层都有对应的 release 路径，确保不泄漏。

5. **Bypass 优先于调度**：passthrough / flush / 资源不足时直接进 hctx->dispatch，绕过 scheduler 保证关键 IO 的低延迟。

6. **分层统计**：blkcg 通过 `bio->issue_time_ns`，WBT 通过 `rq_qos_track`，iopoll 通过 `io_comp_batch`，各层各司其职。