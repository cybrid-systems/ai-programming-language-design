# Linux Block Layer 深度分析：从 bio 到 request 的完整路径

> 基于 Linux 7.0-rc1 内核源码分析

---

## 概览：bio → request → dispatch → completion 全路径 ASCII 图

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        PAGE WRITEBACK (fs/buffer.c)                         │
│  block_write_full_folio() → __block_write_full_folio()                       │
│      ↓ 遍历 folio 的 buffer_head，每个 dirty buffer 生成一个 bio            │
└──────────────────────────────────────────────────────────────────────────────┘
                                       ↓ submit_bio(bio)
┌──────────────────────────────────────────────────────────────────────────────┐
│                     submit_bio() [blk-core.c:916]                            │
│  submit_bio() → submit_bio_noacct() → __submit_bio_noacct()                  │
│      ↓ 检查 BD_HAS_SUBMIT_BIO 标志                                            │
│      ├─ 有 → disk->fops->submit_bio(bio)        (legacy 路径)              │
│      └─ 无 → blk_mq_submit_bio(bio)             (blk-mq 路径) ← 主流        │
└──────────────────────────────────────────────────────────────────────────────┘
                                       ↓ blk_mq_submit_bio()
┌──────────────────────────────────────────────────────────────────────────────┐
│                   blk_mq_submit_bio() [blk-mq.c:3141]                        │
│                                                                              │
│  1. plug 缓存请求查找: blk_mq_peek_cached_request()                          │
│     ├─ 命中 → blk_mq_use_cached_rq() 复用 plug 中缓存的 request              │
│     └─ 未命中 → blk_mq_get_new_requests() 分配新 request                     │
│                                                                              │
│  2. q_usage_counter 进入 (bio_queue_enter)                                   │
│                                                                              │
│  3. bio_split: __bio_split_to_limits() 对齐和分段                            │
│                                                                              │
│  4. bio_merge 尝试: blk_mq_attempt_bio_merge()                               │
│     ├─ 成功合并 → 直接 queue_exit 退出                                      │
│     └─ 无法合并 → 继续                                                      │
│                                                                              │
│  5. zone_write_plugging: bio_needs_zone_write_plugging()                    │
│     ├─ 需要 → blk_zone_plug_bio() 暂存，回头再拆分                           │
│     └─ 不需要 → 继续                                                        │
│                                                                              │
│  6. request 构建: blk_mq_bio_to_request(rq, bio, nr_segs)                   │
│     ├─ bio → rq->bio / rq->biotail                                          │
│     ├─ rq->__sector = bio->bi_iter.bi_sector                                 │
│     └─ rq->__data_len = bio->bi_iter.bi_size                                  │
│                                                                              │
│  7. flush 检测: op_is_flush(bio->bi_opf)                                      │
│     └─ 是 flush → blk_insert_flush(rq) → 加入 flush 队列 → return           │
│                                                                              │
│  8. plug 缓存: blk_add_rq_to_plug() 加入 plug->cached_rqs → return          │
│     (plug 批处理 later by flush_plug_callbacks)                              │
│                                                                              │
│  9. 直接派发路径（无 plug 或 sync IO）:                                       │
│     hctx = rq->mq_hctx                                                       │
│     ├─ RQF_USE_SCHED set 或 hardware queue 拥塞:                           │
│     │    blk_mq_insert_request(rq, 0)  →  加入 scheduler/sw queue         │
│     │    blk_mq_run_hw_queue(hctx, true)  →  触发调度                       │
│     └─ 否则: blk_mq_try_issue_directly(hctx, rq)  →  直接给 driver         │
└──────────────────────────────────────────────────────────────────────────────┘
                                       ↓ blk_mq_insert_request() 或 plug flush
┌──────────────────────────────────────────────────────────────────────────────┐
│              blk_mq_insert_request() [blk-mq.c:2623]                        │
│                                                                              │
│  根据 request 类型分发到不同队列:                                            │
│                                                                              │
│  ├─ passthrough (REQ_OP_FLUSH 以外):                                         │
│  │     blk_mq_request_bypass_insert() → 直接进 hctx->dispatch (最高优先级)   │
│  │                                                                            │
│  ├─ REQ_OP_FLUSH:                                                            │
│  │     blk_mq_request_bypass_insert(rq, BLK_MQ_INSERT_AT_HEAD)             │
│  │     → 加入 hctx->dispatch 队首 (NCQ 环境下减少 flush 延迟)               │
│  │                                                                            │
│  ├─ 有 elevator 活跃:                                                        │
│  │     q->elevator->type->ops.insert_requests(hctx, &list, flags)            │
│  │     → 调度器内部数据结构 (deadline 的 sort_list/fifo_list / bfq 的 bfqq) │
│  │                                                                            │
│  └─ 无 elevator:                                                            │
│        spin_lock(&ctx->lock)                                                 │
│        list_add_tail(&rq->queuelist, &ctx->rq_lists[hctx->type])            │
│        blk_mq_hctx_mark_pending(hctx, ctx)                                   │
└──────────────────────────────────────────────────────────────────────────────┘
                                       ↓ blk_mq_run_hw_queue() / plug flush
┌──────────────────────────────────────────────────────────────────────────────┐
│           blk_mq_run_hw_queue() → blk_mq_sched_dispatch_requests()           │
│                              [blk-mq.c:2387]                                  │
│                                                                              │
│  __blk_mq_sched_dispatch_requests():                                         │
│                                                                              │
│  1. hctx->dispatch 非空?                                                     │
│     ├─ 有 → list_splice_init(&hctx->dispatch, &rq_list)                    │
│     │      blk_mq_dispatch_rq_list(hctx, &rq_list, true)                    │
│     └─ 无 → need_dispatch = hctx->dispatch_busy                              │
│                                                                              │
│  2. 有 elevator? → blk_mq_do_dispatch_sched()                                │
│     └─ 无 elevator? → blk_mq_do_dispatch_ctx() (无调度直接从 sw queue 取)   │
└──────────────────────────────────────────────────────────────────────────────┘
                                       ↓ blk_mq_do_dispatch_sched() / blk_mq_do_dispatch_ctx()
┌──────────────────────────────────────────────────────────────────────────────┐
│           blk_mq_do_dispatch_sched() [blk-mq-sched.c:85]                    │
│                                                                              │
│  with elevator (mq-deadline / bfq):                                          │
│                                                                              │
│  ┌─ deadline dispatch_request():                                            │
│  │    按扇区排序从 sort_list 取出; 或从 fifo_list 紧急取 (expired)         │
│  │                                                                            │
│  ├─ bfq dispatch_request():                                                  │
│  │    B-WF2Q+ 算法选中的 bfq_queue 中取首位 request                          │
│  │                                                                            │
│  └─ 每取一个 request: blk_mq_get_driver_tag(rq) 分配 hardware tag          │
│     list_add_tail(&rq->queuelist, &rq_list)                                  │
│                                                                              │
│  multi_hctxs 情况: list_sort(NULL, &rq_list, sched_rq_cmp) 按 hctx 分组   │
│                                                                              │
│  → blk_mq_dispatch_rq_list(hctx, &rq_list, true)                            │
└──────────────────────────────────────────────────────────────────────────────┘
                                       ↓ blk_mq_dispatch_rq_list()
┌──────────────────────────────────────────────────────────────────────────────┐
│        blk_mq_dispatch_rq_list() [blk-mq.c:2116]                             │
│                                                                              │
│  遍历 rq_list 的每个 request:                                                │
│                                                                              │
│  prep = blk_mq_prep_dispatch_rq(rq, get_budget)                              │
│     └─ 检查 budget/token，失败则 PREP_DISPATCH_NO_TAG                       │
│                                                                              │
│  bd.rq = rq;  bd.last = list_empty(list)                                    │
│  ret = q->mq_ops->queue_rq(hctx, &bd)   ← 调用 driver 的 queue_rq 回调      │
│                                                                              │
│  switch(ret):                                                                │
│    ├─ BLK_STS_OK:            queued++  正常完成                             │
│    ├─ BLK_STS_RESOURCE:      blk_mq_handle_dev_resource() → hctx->dispatch │
│    └─ default:              blk_mq_end_request(rq, ret)  错误结束          │
│                                                                              │
│  out:                                                                        │
│    blk_mq_commit_rqs(hctx, queued, from_schedule)  →  driver commit_rqs()  │
│                                                                              │
│    hctx->dispatch 非空?                                                      │
│      ├─ 是 → list_splice_tail_init(list, &hctx->dispatch)                  │
│      └─ 否 → SCHED_RESTART 标记，等待下次调度                              │
└──────────────────────────────────────────────────────────────────────────────┘
                                       ↓ driver queue_rq() 回调返回后
┌──────────────────────────────────────────────────────────────────────────────┐
│                    blk_mq_try_issue_directly() [blk-mq.c:2768]              │
│                                                                              │
│  直接派发路径 (无 scheduler, hardware queue 有空闲):                          │
│                                                                              │
│  1. hctx stopped 或 queue quiesced?                                          │
│     → blk_mq_insert_request() + blk_mq_run_hw_queue()                       │
│                                                                              │
│  2. RQF_USE_SCHED set 或 获取 budget+tag 失败?                               │
│     → blk_mq_insert_request() + blk_mq_run_hw_queue()                       │
│                                                                              │
│  3. __blk_mq_issue_directly(hctx, rq, last)                                 │
│     → q->mq_ops->queue_rq(hctx, &bd)  直接给 driver                         │
│     失败 → blk_mq_request_bypass_insert() + blk_mq_run_hw_queue()            │
└──────────────────────────────────────────────────────────────────────────────┘
                                       ↓ driver 硬件处理完成 → 中断/DMA 完成
┌──────────────────────────────────────────────────────────────────────────────┐
│                      COMPLETION 完成路径                                      │
│                                                                              │
│  设备驱动完成中断 → blk_mq_complete_request(rq)                             │
│                                                                              │
│  blk_mq_complete_request(): [blk-mq.c:1353]                                  │
│     └─ blk_mq_complete_request_remote(rq)?                                  │
│         ├─ 同 CPU / 同一 cache domain / polled request                      │
│         │    → 本地完成: rq->q->mq_ops->complete(rq)                         │
│         └─ 需要 IPI:                                                         │
│              blk_mq_complete_send_ipi() → 发送 IPI 到 rq->mq_ctx->cpu       │
│              → 远端 CPU raise BLOCK_SOFTIRQ → blk_mq_softirq_done()         │
│                                                                              │
│  RQ_END_IO path:                                                             │
│                                                                              │
│  blk_mq_end_request() [blk-mq.c:1176]                                        │
│     ├─ blk_update_request() → 分段 bio 完成处理                             │
│     └─ __blk_mq_end_request():                                               │
│          ├─ blk_mq_finish_request(rq)                                        │
│          │    ├─ blk_zone_finish_request()                                  │
│          │    └─ elevator->type->ops.finish_request(rq) (if RQF_USE_SCHED) │
│          ├─ rq->end_io(rq) 回调 (如果有)                                     │
│          └─ blk_mq_free_request(rq)                                         │
│                                                                              │
│  blk_mq_free_request() [blk-mq.c:820]                                       │
│     ├─ blk_mq_finish_request() 再次 (post-finish 清理)                     │
│     ├─ rq_qos_done(q, rq)  关闭 wbt/cgroup 等 QoS 统计                      │
│     ├─ req_ref_put_and_test(rq)  释放引用计数                               │
│     └─ __blk_mq_free_request():                                              │
│          ├─ blk_crypto_free_request()                                        │
│          ├─ blk_mq_put_tag()  归还 hardware tag                             │
│          ├─ blk_mq_sched_restart(hctx)  标记 SCHED_RESTART                  │
│          └─ blk_queue_exit(q)  释放 q_usage_counter                         │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 1. bio 和 request 关系串联

### 1.1 从 submit_bio 到 blk_mq_submit_bio 的完整路径

```c
submit_bio(bio)              // [blk-core.c:916]
  → submit_bio_noacct(bio)  // [blk-core.c:780]
    → __submit_bio_noacct(bio)  // [blk-core.c:671]
        → __submit_bio(bio)  // [blk-core.c:627]
            ├─ BD_HAS_SUBMIT_BIO set?
            │   → disk->fops->submit_bio(bio)   // legacy 设备
            │   → blk_queue_exit(q)             // 然后退出
            └─ 默认
                → blk_mq_submit_bio(bio)        // blk-mq 主流路径
        → blk_finish_plug(&plug)
```

关键设计决策：**plug 机制**。每个任务线程有一个 `struct blk_plug *current->plug`，用于批量缓存来自同一任务周期的多个 request，延迟派发以增加合并机会。

### 1.2 bio 如何变成 request

`blk_mq_submit_bio()` 的核心转换步骤：

```c
// blk-mq.c:3141
void blk_mq_submit_bio(struct bio *bio)
{
    struct request_queue *q = bdev_get_queue(bio->bi_bdev);
    struct blk_plug *plug = current->plug;

    // Step 1: 尝试从 plug 缓存中复用 request
    rq = blk_mq_peek_cached_request(plug, q, bio->bi_opf);
    if (rq && bio_zone_write_plugging(bio)) {
        blk_queue_exit(q);   // cached rq 已持有一个 reference
        goto new_request;    // 跳过 re-enter
    }

    // Step 2: q_usage_counter 进入
    if (!rq && bio_queue_enter(bio))  // 失败则 bio 已 error 完成
        return;

    // Step 3: bio 对齐检查 & split
    if (unlikely(bio_unaligned(bio, q))) {
        bio_io_error(bio);
        goto queue_exit;
    }

    // Step 4: 按 queue limits 拆分（块大小对齐、max_sectors 等）
    bio = __bio_split_to_limits(bio, &q->limits, &nr_segs);
    if (!bio) goto queue_exit;

    // Step 5: bio_integrity (校验和保护)
    integrity_action = bio_integrity_action(bio);
    if (integrity_action) bio_integrity_prep(bio, integrity_action);

    // Step 6: 初始化
    blk_mq_bio_issue_init(q, bio);

    // Step 7: 尝试与 sw queue 中的 request 合并
    if (blk_mq_attempt_bio_merge(q, bio, nr_segs))
        goto queue_exit;

    // Step 8: zone write plugging（ZNS/叠瓦盘优化）
    if (bio_needs_zone_write_plugging(bio)) {
        if (blk_zone_plug_bio(bio, nr_segs))
            goto queue_exit;  // 被 zone plug 吸收
    }

new_request:
    // Step 9: 分配 request（复用 cached 或新建）
    if (rq) {
        blk_mq_use_cached_rq(rq, plug, bio);  // 重置已缓存 rq
    } else {
        rq = blk_mq_get_new_requests(q, plug, bio);  // 真正分配
        if (!rq) {
            if (bio->bi_opf & REQ_NOWAIT)
                bio_wouldblock_error(bio);
            goto queue_exit;
        }
    }

    // Step 10: 将 bio 转换为 request（绑定 bio 链表到 rq）
    blk_mq_bio_to_request(rq, bio, nr_segs);
    //   rq->bio = rq->biotail = bio
    //   rq->__sector = bio->bi_iter.bi_sector
    //   rq->__data_len = bio->bi_iter.bi_size

    // Step 11: crypto keyslot 获取
    ret = blk_crypto_rq_get_keyslot(rq);
    if (ret != BLK_STS_OK) {
        bio->bi_status = ret;
        bio_endio(bio);
        blk_mq_free_request(rq);
        return;
    }

    // Step 12: zone write plug 初始化
    if (bio_zone_write_plugging(bio))
        blk_zone_write_plug_init_request(rq);

    // Step 13: flush request 特殊处理
    if (op_is_flush(bio->bi_opf) && blk_insert_flush(rq))
        return;

    // Step 14: 加入 plug 缓存（延迟派发）
    if (plug) {
        blk_add_rq_to_plug(plug, rq);
        return;
    }

    // Step 15: 直接派发（非 plug 路径）
    hctx = rq->mq_hctx;
    if ((rq->rq_flags & RQF_USE_SCHED) ||
        (hctx->dispatch_busy && (q->nr_hw_queues == 1 || !is_sync))) {
        blk_mq_insert_request(rq, 0);           // 入 scheduler/sw queue
        blk_mq_run_hw_queue(hctx, true);        // 触发调度
    } else {
        blk_mq_run_dispatch_ops(q, 
            blk_mq_try_issue_directly(hctx, rq));  // 直接给 driver
    }
    return;

queue_exit:
    if (!rq) blk_queue_exit(q);  // 释放 q_usage_counter
}
```

### 1.3 为什么合并？合并的条件

bio 合并的目的是**减少 I/O 次数，提高吞吐量**。一次 DMA 传输多个连续的 bio 比多次小传输更高效。

```c
// blk-mq.c:3034
static bool blk_mq_attempt_bio_merge(struct request_queue *q,
                                     struct bio *bio, unsigned int nr_segs)
{
    // 调度器有自己的 merge 策略
    if (q->elevator && q->elevator->type->ops.bio_merge)
        if (q->elevator->type->ops.bio_merge(q, bio, nr_segs))
            return true;

    // 默认 sw queue 合并（ctx->rq_lists）
    ctx = blk_mq_get_ctx(q);
    hctx = blk_mq_map_queue(bio->bi_opf, ctx);
    type = hctx->type;
    if (list_empty_careful(&ctx->rq_lists[type]))
        return false;

    spin_lock(&ctx->lock);
    if (blk_bio_list_merge(q, &ctx->rq_lists[type], bio, nr_segs))
        ret = true;
    spin_unlock(&ctx->lock);
    return ret;
}
```

合并的条件（`blk_rq_merge_ok`）：
1. **后向合并 (back merge)**：bio 的起始扇区紧接着 rq 的结束扇区
2. **前向合并 (front merge)**：bio 的结束扇区紧接着 rq 的起始扇区（需要 `front_merges` 开启）
3. **bio 和 rq 的操作标志兼容**（同读/同写，非混淆）
4. **数据连续性**：确保 scatter-gather list 不超过限制

### 1.4 plug 机制 — 批量合并的关键

```c
// blk-core.c:1408
static void blk_add_rq_to_plug(struct blk_plug *plug, struct request *rq)
{
    rq_list_add(&plug->cached_rqs, rq);
    plug->multiple_queues = true;  // 标记来自多个 hctx
}
```

plug 在以下时机被 flush：
- 任务结束（schedule）时 → `flush_plug_callbacks()`
- 等待 I/O 时（sync）→ `blk_flush_plug()`
- plug 满（`plug->nr_ios >= BLK_MAX_REQUEST_COUNT * 2`）

```c
// blk-core.c:1226
void __blk_flush_plug(struct blk_plug *plug, bool from_schedule)
{
    // 遍历 cached_rqs，按 queue 分组
    // 调用 blk_mq_flush_plug_list() → 最终到 blk_mq_sched_dispatch_requests()
    ...
}
```

---

## 2. blk-mq 队列路径串联

### 2.1 多队列初始化

```
用户空间打开设备
       ↓
blk_mq_init_queue()  [blk-mq.c]
       ↓
blk_mq_setup_queue() → blk_mq_init_cpu_queues()
       │                    └─ per-cpu struct blk_mq_ctx
       │                        每 CPU 一个 ctx，内含 rq_lists[HCTX_MAX_TYPES]
       │                        每个 CPU 对应多个 hctx（不同类型）
       │
blk_mq_alloc_hctx() × nr_hw_queues
       │
blk_mq_init_hctx()
       ├─ 初始化 hctx->dispatch (list_head)
       ├─ 初始化 hctx->ctx_map (sbitmap) — 软件队列 bitmap
       ├─ 分配 hctx->tags (blk_mq_alloc_rq_map)
       ├─ 分配 flush_rq
       └─ 设置 cpumask（NUMA 亲和性）
```

关键结构：`enum hctx_type`（`blk-mq.h:488`）：
```c
enum hctx_type {
    HCTX_TYPE_DEFAULT,   // 普通 I/O（读/写/其他）
    HCTX_TYPE_POLL,      // poll 类型的 I/O（如 NVMe poll 队列）
    HCTX_MAX_TYPES,
};
```

CPU 到 hctx 的映射（`blk_mq_map_queue_type`）：
```c
hctx = q->queue_hw_ctx[ mapping->mq_map[cpu] ];  // 通过 CPU → hctx_idx 映射表
```

### 2.2 blk_mq_sched_insert_request 的完整路径

实际上在 Linux 7.0-rc1 中，`blk_mq_sched_insert_request` 已被 `blk_mq_insert_request` 替代（API 简化）。完整路径如下：

```
用户: blk_mq_submit_bio() → (无法直接派发)
    ↓
blk_mq_insert_request(rq, flags=0)        // blk-mq.c:2623
    │
    ├─ passthrough (非 fs request) ?
    │    → blk_mq_request_bypass_insert() → 直接入 hctx->dispatch
    │
    ├─ REQ_OP_FLUSH ?
    │    → blk_mq_request_bypass_insert(AT_HEAD) → hctx->dispatch 队首
    │
    ├─ q->elevator 存在 ?
    │    → q->elevator->type->ops.insert_requests(hctx, &list, flags)
    │        (调度器内部数据结构，如 deadline 的 sort_list/fifo)
    │
    └─ 无调度器（NULL elevator）:
         spin_lock(&ctx->lock)
         list_add_tail(&rq->queuelist, &ctx->rq_lists[hctx->type])
         blk_mq_hctx_mark_pending(hctx, ctx)
         spin_unlock(&ctx->lock)
    ↓
blk_mq_run_hw_queue(hctx, async)          // blk-mq.c:2352
    │
    ├─ 检查 hctx 是否需要运行 (blk_mq_hw_queue_need_run)
    │    → !blk_queue_quiesced() && blk_mq_hctx_has_pending(hctx)
    │
    ├─ async=true（不能在中断上下文同步执行）?
    │    → blk_mq_delay_run_hw_queue(hctx, 0) → kblockd workqueue
    │
    └─ sync 执行:
         blk_mq_run_dispatch_ops(hctx->queue,
             blk_mq_sched_dispatch_requests(hctx))  // 直接调用
```

### 2.3 hctx 和 cpu 的对应关系

```
┌──────────────────────────────────────────────────────────────┐
│  CPU 0                 CPU 1                 CPU 2          │
│    │                     │                     │              │
│  struct blk_mq_ctx   struct blk_mq_ctx    struct blk_mq_ctx   │
│    │                     │                     │              │
│    ├─ rq_lists[DEFAULT] │                     │              │
│    ├─ rq_lists[POLL]    │                     │              │
│    │                     │                     │              │
│    │  hctxs[HCTX_TYPE_DEFAULT] → hctx #0 (hw queue 0)     │
│    │  hctxs[HCTX_TYPE_POLL]     → hctx #N (poll queue)    │
└──────────────────────────────────────────────────────────────┘
```

硬件队列数通常等于 CPU 数（或更少）。`blk_mq_map_queue(opf, ctx)` 根据 bio 的操作标志选择 hctx 类型。

---

## 3. 调度算法（elevator）串联

### 3.1 elevator 框架结构

```c
// elevator.h
struct elevator_type {
    const char *elevator_name;
    const char *elevator_alias;
    const struct elevator_ops *ops;
    // ...
};

struct elevator_ops {
    // 合并检查
    bool (*allow_merge)(request_queue*, struct request*, struct bio*);
    bool (*bio_merge)(request_queue*, struct bio*, unsigned int);
    // 请求管理
    int (*request_merge)(request_queue*, struct request*, struct request*);
    void (*request_merged)(request_queue*, struct request*, enum elv_merge);
    // 入队/出队
    void (*insert_requests)(struct blk_mq_hw_ctx*, struct list_head*, blk_insert_t);
    void (*finish_request)(struct request*);
    bool (*has_work)(struct blk_mq_hw_ctx*);
    // 调度核心
    struct request *(*dispatch_request)(struct blk_mq_hw_ctx*);
    // ...
};
```

### 3.2 mq-deadline 调度器

mq-deadline 是经典 deadline 调度器的 blk-mq 版本，核心思想：**保证 I/O 的最坏延迟不超过截止时间**。

```c
// mq-deadline.c - deadline_data 结构
struct deadline_data {
    struct list_head dispatch;               // 待派发的 request 链表
    struct dd_per_prio per_prio[DD_PRIO_COUNT];  // 每种优先级一组队列
    // 每个 prio 下有:
    //   sort_list[DD_DIR_COUNT]  — 红黑树，按扇区排序
    //   fifo_list[DD_DIR_COUNT]  — 链表，按截止时间排序
    int fifo_expire[DD_DIR_COUNT];   // 默认: read=0.5s, write=5s
    int fifo_batch;                  // 默认: 16（批量处理以提高吞吐）
    int writes_starved;              // 默认: 2（read 可饿死 write 的次数）
    int front_merges;                // 默认: 开启
};
```

优先级映射（`ioprio_class_to_prio`）：
```c
[IOPRIO_CLASS_RT]   → DD_RT_PRIO   (实时，最高优先级)
[IOPRIO_CLASS_BE]   → DD_BE_PRIO   (最佳努力)
[IOPRIO_CLASS_IDLE] → DD_IDLE_PRIO (空闲，最低优先级)
```

**deadline 调度核心**：

1. **dispatch_request()**：
   - 优先检查 `per_prio[RT].fifo_list[READ]` — 是否有超时的 read
   - 若 read 未过期但已 batch 次 → 切换到 write
   - write 也受 `writes_starved` 限制（read 饿死 write 的次数上限）
   - 按扇区顺序从 `sort_list[DD_DIR_COUNT]` 取 request

2. **插入策略**：
   - 新 request 按扇区位置插入 `sort_list`（红黑树）
   - 同时加入 `fifo_list`，设置 `fifo_time = now + expire`
   - 前向合并（front merge）默认开启

3. **合并处理**：
   - 前向合并时需要把 request 重新插入红黑树（因为起始扇区变了）
   - 后向合并不需要移动（插入点已在正确位置）

### 3.3 BFQ 调度器

BFQ（Budget Fair Queueing）是一个**比例公平**的调度器，基于**预算（sector 数量）**而非时间片来分配带宽。

**核心概念**：
- **bfq_queue**（对应一个进程/group）有一个 `bfqd->budget`（sector 数）
- **B-WF2Q+ 算法**：根据预算权重计算"虚拟时间"，按字典序排序选择下一个队列
- 一个队列被选中后，持续服务直到预算耗尽（或队列空）

```c
// bfq-iosched.h
struct bfq_queue {
    // 调度相关
    u64 dispatch;                // 已派发的 sector 数
    unsigned long service;       // 本次调度周期已服务量

    // B-WF2Q+ 虚拟时间
    struct bfq_entity *entity;   // 树节点，用于 WFQ 调度

    // 权重提升（interactive / soft-rt 检测）
    unsigned long weight;
    bool *const async;           // 是否异步队列

    // 空闲检测
    unsigned long soft_rt_next_start;  // 软实时队列的下次开始时间
    bool interactive;
    bool soft_real_time;
};
```

**weighted fairness 机制**：
```c
// bfq-iosched.c
// 给定权重 w，虚拟时间推进速度 = 实际时间 / w
// 高权重队列虚拟时间增长慢 → 更早被选中 → 获得更多带宽
// 100 weight 的队列获得的带宽是 10 weight 队列的 10 倍
```

**低延迟特性**：
- `low_latency=1` 时，BFQ 持续检测 interactive 队列（短暂活跃后空闲）
- interactive 队列的权重会被提升（weight-raising）
- soft-rt 队列有单独的检测机制（`bfq_bfqq_softrt_next_start`）

---

## 4. blk_mq_dispatch 路径

### 4.1 调度派发总流程

```
blk_mq_sched_dispatch_requests(hctx)     // 入口 [blk-mq-sched.c:317]
    │
    └─ __blk_mq_sched_dispatch_requests(hctx)
         │
         ├─ hctx->dispatch 非空?
         │    ├─ yes: splice 到 rq_list → blk_mq_dispatch_rq_list()
         │    └─ no: need_dispatch = hctx->dispatch_busy
         │
         ├─ q->elevator 存在?
         │    └─ yes: blk_mq_do_dispatch_sched()
         │         └─ 从 elevator 取 request（deadline: sort_list/fifo）
         │             blk_mq_dispatch_rq_list()
         │
         ├─ need_dispatch && !elevator?
         │    └─ yes: blk_mq_do_dispatch_ctx()
         │         └─ 从 sw queue (ctx->rq_lists) 逐个取 request
         │             blk_mq_dispatch_rq_list()
         │
         └─ none of above:
              blk_mq_flush_busy_ctxs(hctx, &rq_list)
              blk_mq_dispatch_rq_list(hctx, &rq_list, true)
```

### 4.2 blk_mq_dispatch_rq_list 详细路径

```c
// blk-mq.c:2116
bool blk_mq_dispatch_rq_list(struct blk_mq_hw_ctx *hctx,
                               struct list_head *list, bool get_budget)
{
    // list 是准备派发的 request 链表
    queued = 0;
    do {
        bd.rq = list_first_entry(list, ...);
        // 预处理：获取 budget/token
        prep = blk_mq_prep_dispatch_rq(rq, get_budget);
        if (prep != PREP_DISPATCH_OK) break;

        list_del_init(&rq->queuelist);
        bd.last = list_empty(list);

        // 调用 driver 的 queue_rq 回调
        ret = q->mq_ops->queue_rq(hctx, &bd);

        switch (ret) {
        case BLK_STS_OK:
            queued++;
            break;
        case BLK_STS_RESOURCE:
        case BLK_STS_DEV_RESOURCE:
            // 硬件资源不足，重新放回 hctx->dispatch
            blk_mq_handle_dev_resource(rq, list);
            goto out;
        default:
            // 其他错误（如介质错误），直接结束
            blk_mq_end_request(rq, ret);
        }
    } while (!list_empty(list));

out:
    // 通知 driver 没有更多 request 了
    if (!list_empty(list) || ret != BLK_STS_OK)
        blk_mq_commit_rqs(hctx, queued, false);

    // 剩余 request 放回 hctx->dispatch（下次再试）
    if (!list_empty(list))
        list_splice_tail_init(list, &hctx->dispatch);

    // 如果本次没有全部派发，设置 SCHED_RESTART 标记
    if (ret == BLK_STS_RESOURCE || ret == BLK_STS_DEV_RESOURCE)
        blk_mq_sched_mark_restart_hctx(hctx);

    return !list_empty(list) || needs_restart;
}
```

### 4.3 blk_mq_try_issue_directly 和 blk_mq_issue_rq 的关系

在 Linux 7.0-rc1 中，`blk_mq_issue_rq` 已被移除，替代流程如下：

```
blk_mq_try_issue_directly(hctx, rq)   // blk-mq.c:2768
    │
    ├─ hctx stopped 或 queue quiesced?
    │    → blk_mq_insert_request(rq, 0)
    │    → blk_mq_run_hw_queue(hctx, false)
    │
    ├─ RQF_USE_SCHED set 或 budget/tag 获取失败?
    │    → blk_mq_insert_request(rq, 0)
    │    → blk_mq_run_hw_queue(hctx, ...)
    │
    └─ 资源充足:
         __blk_mq_issue_directly(hctx, rq, last=true)
              │
              ├─ q->mq_ops->queue_rq(hctx, &bd)  → BLK_STS_OK
              │    成功: 不做任何额外处理（已在 hctx 中）
              │
              ├─ BLK_STS_RESOURCE / BLK_STS_DEV_RESOURCE:
              │    → blk_mq_request_bypass_insert(rq, 0)
              │    → blk_mq_run_hw_queue(hctx, false)
              │         (重新入队等待下次调度)
              │
              └─ 其他错误:
                   blk_mq_end_request(rq, ret)
```

---

## 5. 完成路径（completion）

### 5.1 完成路径全貌

```
硬件中断 / DMA 完成
    ↓
驱动调用 blk_mq_complete_request(rq)   // [blk-mq.c:1353]
    │
    └─ blk_mq_complete_request_remote(rq)?
          │
          ├─ 同 CPU / 同 cache domain / polled?
          │    → 直接调用: rq->q->mq_ops->complete(rq)
          │         └─ 驱动完成回调（如 NVMe 的 nvme_complete_rq）
          │
          └─ 跨 CPU:
               blk_mq_complete_send_ipi(rq)
                    → smp_call_function_single_async(cpu)
                    → 目标 CPU 执行 llist_add(&rq->ipi_list)
                    → raise BLOCK_SOFTIRQ
                         → blk_mq_softirq_done() 遍历 blk_cpu_done
                              → blk_mq_complete_request_remote()
                                   → mq_ops->complete()
```

### 5.2 blk_mq_end_request 和 blk_mq_free_request 的区别

这是两个层次的概念：

```c
// blk-mq.c:1176
void blk_mq_end_request(struct request *rq, blk_status_t error)
{
    // 处理分段 bio（bio 的 bi_bvec_done / bi_iter）
    if (blk_update_request(rq, error, blk_rq_bytes(rq)))
        BUG();  // 还有剩余 bio 未完成
    __blk_mq_end_request(rq, error);
}

// blk-mq.c:820
void blk_mq_free_request(struct request *rq)
{
    blk_mq_finish_request(rq);    // zone finish + elevator finish
    rq_qos_done(q, rq);          // wbt/cgroup 统计结束

    WRITE_ONCE(rq->state, MQ_RQ_IDLE);
    // 引用计数归零后才真正释放
    if (req_ref_put_and_test(rq))
        __blk_mq_free_request(rq);  // 归还 tag，restart hctx，queue_exit
}
```

| 函数 | 职责 | 调用时机 |
|------|------|---------|
| `blk_mq_end_request()` | 更新 bio 完成状态，调用 `__blk_mq_end_request` | driver 报告 I/O 结束时 |
| `blk_mq_free_request()` | 释放 request 资源（tag、内存、q_ref） | 所有 bio 处理完毕，引用归零 |
| `__blk_mq_end_request()` | 内部：finish_request + end_io 回调 + free_request | end_request 内部 |
| `__blk_mq_free_request()` | 内部：归还 tag、sched_tag，调用 `blk_mq_sched_restart`，`blk_queue_exit` | free_request 内部 |

**流程链**：
```
blk_mq_complete_request()
  → blk_mq_complete_request_remote() 或 mq_ops->complete()
  → blk_mq_end_request(rq, status)
       → blk_update_request()  检查是否还有剩余 bio
       → __blk_mq_end_request()
            → blk_mq_finish_request()
            → rq->end_io(rq) 回调 (如果有)
            → blk_mq_free_request()
                 → blk_mq_finish_request()  (再次)
                 → rq_qos_done()
                 → req_ref_put_and_test()
                      → __blk_mq_free_request()
                           → blk_crypto_free_request()
                           → blk_mq_put_tag()         归还 hw tag
                           → blk_mq_sched_restart()   标记 hctx 需要重启
                           → blk_queue_exit(q)       释放 q_usage_counter
```

---

## 6. writeback 融合

### 6.1 page writeback 到 block 层

VFS page writeback 路径：
```
fs/fs-writeback.c
    writeback_sb_inodes()
        → sync_page_range() / write_one_page()
             ↓
fs/buffer.c
    block_write_full_folio()       // [buffer.c:2625]
    → __block_write_full_folio()  // [buffer.c:1733]
         │
         ├─ folio_create_buffers()    创建 buffer_head 链表
         ├─ get_block()               文件系统 → 块设备扇区映射
         │    (ext4: ext4_get_block;  xfs: xfs_bmapi;  btrfs: ... )
         │
         ├─ 遍历每个 buffer_head:
         │    lock_buffer(bh)
         │    clear_buffer_dirty()
         │    submit_bh(WRITE, bh)     // 关键：每个 buffer_head → 一个 bio
         │    nr_underway++
         │
         └─ 等待所有 buffer_head 的 I/O 完成
              → folio_end_writeback(folio)
```

### 6.2 buffer_head 到 bio 的转换

submit_bh 是 buffer_head 提交的关键：
```c
// fs/buffer.c (在 fs/buffer.c 或 block/blk-core.c 中)
submit_bh(WRITE, bh)
    → struct bio *bio = bio_alloc()
    → bio->bi_iter.bi_sector = bh->b_blocknr
    → bio->bi_bdev = bh->b_bdev
    → bio_add_page(bio, bh->b_page, bh->b_size, bh->b_offset)
    → submit_bio(bio)
```

每个 buffer_head（通常 4KB）生成一个 bio，多个相邻的 buffer_head 可能在 `submit_bh` 之前通过 `bio_add_page` 合并到同一个 bio 中（减少 bio 数量）。

### 6.3 writeback 与 block 层的 QoS 交互

**blk_wbt (Write Barrier Throttling)**：
- 限制脏页回写速率，防止突发 writeback 饿死同步 I/O
- `wbc->nr_to_write` 控制每次 writeback 的 page 数量
- block 层通过 `rq_qos_throttle()` / `rq_qos_done()` 与 wbt 交互

**cgroup writeback**：
```c
// blk-cgroup.c
// 每个 cgroup 有独立的 blkio 控制组
// bio 的 blkg (blkio cg group) 在 submit_bio 时确定
// 调度器（bfq/cfq-iosched）根据 cgroup 权重分配带宽
```

---

## 7. 关键数据结构一览

### 7.1 request 结构

```c
struct request {                      // [blk-mq.h:105]
    struct request_queue *q;         // 所属队列
    struct blk_mq_ctx *mq_ctx;       // 提交时的软件上下文（CPU）
    struct blk_mq_hw_ctx *mq_hctx;   // 目标硬件队列

    blk_opf_t cmd_flags;            // 操作标志（READ/WRITE/FLUSH/SYNC...）
    req_flags_t rq_flags;           // 内部标志（RQF_USE_SCHED/RQF_MQ_INFLIGHT...）

    int tag;                        // hardware tag（块设备队列中的索引）
    int internal_tag;               // scheduler internal tag

    // 数据描述
    unsigned int __data_len;        // 总字节数
    sector_t __sector;              // 起始扇区

    struct bio *bio, *biotail;       // 绑定的 bio 链表

    // 状态
    enum mq_rq_state state;          // MQ_RQ_IDLE / IN_FLIGHT / COMPLETE
    atomic_t ref;                    // 引用计数
    unsigned long deadline;         // 超时截止时间

    // 调度器私有数据
    union {
        struct hlist_node hash;      // merge hash（在调度器中）
        struct llist_node ipi_list;  // completion softirq 链表
    };
    union {
        struct rb_node rb_node;     // 调度器红黑树节点
        struct bio_vec special_vec;  // special payload（REQ_OP_DRV_OUT/IN）
    };
    struct { struct io_cq *icq; void *priv[2]; };  // 调度器/合并用

    // cgroup / wbt
    struct request *elv.priv[2];
};
```

### 7.2 blk_mq_hw_ctx 结构

```c
struct blk_mq_hw_ctx {               // [blk-mq.h]
    struct request_queue *queue;
    unsigned int queue_num;         // hw queue 编号 [0, nr_hw_queues)

    enum hctx_type type;             // DEFAULT / POLL

    struct blk_mq_tags *tags;        // 请求 tag 池
    struct blk_mq_tags *sched_tags; // scheduler 专用 tag（如果有）

    struct sbitmap ctx_map;         // 软件队列 bitmap（哪些 ctx 有 pending）

    struct list_head dispatch;       // **高优先级派发队列**（bypass/flush）
    spinlock_t lock;                 // 保护 dispatch 队列

    struct blk_mq_ctx *dispatch_from;  // round-robin 起点（for no-sched ctx）

    bool dispatch_busy;             // 标记队列繁忙（影响调度决策）

    cpumask_var_t cpumask;           // NUMA / affinity
    int numa_node;

    struct delayed_work run_work;    // kblockd 延迟派发工作项
    unsigned long flags;             // BLK_MQ_F_* 标志
};
```

---

## 8. 完整数据流时间线

```
t=0   submit_bio(bio)              用户进程
t=1   __submit_bio_noacct()        构建 bio_list 栈
t=2   __submit_bio()               plug.start
t=3   blk_mq_submit_bio()          核心转换函数
t=4   blk_mq_peek_cached_request()  尝试 plug 缓存命中
t=5   blk_mq_get_new_requests()    分配 request（tag + memory）
t=6   blk_mq_bio_to_request()      bio → request 绑定
t=7   blk_insert_flush()           flush 请求特殊处理（可选）
t=8   blk_add_rq_to_plug()         缓存到 plug（延迟派发）
          ↓ (plug flush / sync path / plug full)
t=9   blk_mq_insert_request()      入 sw-queue 或 scheduler
t=10  blk_mq_run_hw_queue()        触发 hctx 调度
t=11  blk_mq_sched_dispatch_requests() 调度决策点
t=12  blk_mq_do_dispatch_sched() / blk_mq_do_dispatch_ctx()
t=13  blk_mq_dispatch_rq_list()    调用 driver.queue_rq()
t=14  [DMA/硬件处理]
t=15  blk_mq_complete_request()     硬件完成中断
t=16  blk_update_request()          处理分段完成
t=17  __blk_mq_end_request()        finish + end_io
t=18  blk_mq_free_request()         归还 tag，重启 hctx
t=19  [可选: blk_mq_run_hw_queue()  触发下一轮调度]
```

---

## 9. 总结：bio ↔ request 的核心设计哲学

| 设计决策 | 原因 |
|---------|------|
| bio 是 I/O 原子，request 是调度原子 | bio 可能被 split/merge，但一旦进入 request 就不可分割 |
| plug 机制延迟派发 | 增加合并机会，减少硬件队列空转 |
| hctx 分发（dispatch list）优先级最高 | 绕过调度器，保证 passthrough 和 flush 的低延迟 |
| request 引用计数 | 支持命中的 bio 在 request 完成后（分层释放）再处理 |
| blk_mq_sched_restart 标记 | 避免在释放路径中直接触发调度（锁/中断上下文限制） |
| completion softirq vs IPI | 同 cache domain 内直接完成，减少跨 NUMA 通信 |

---

**参考源码版本**：Linux 7.0-rc1 (commit b6f0f7e38c7c)  
**主要文件**：
- `block/blk-core.c` — 通用块层核心（submit_bio, plug）
- `block/blk-mq.c` — blk-mq 实现（submit_bio, dispatch, completion）
- `block/blk-mq-sched.c` — 调度框架（dispatch 编排）
- `block/elevator.c` — elevator 通用框架
- `block/mq-deadline.c` — deadline 调度器
- `block/bfq-iosched.c` — BFQ 调度器
- `include/linux/blk-mq.h` — request / hctx 结构定义
- `include/linux/blkdev.h` — request_queue 等通用定义
- `fs/buffer.c` — buffer_head 到 bio 的转换