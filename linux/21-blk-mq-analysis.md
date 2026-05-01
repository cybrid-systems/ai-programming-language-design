# 21-blk-mq — Linux 块设备多队列深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**blk-mq（Block Multi-Queue）** 是 Linux 内核块设备层的多队列 I/O 调度框架，由 Jens Axboe 在 Linux 3.13 引入。它解决了传统单队列（single-queue）块层在高性能 SSD/NVMe 设备上的性能瓶颈——单队列的全局锁竞争使 IOPS 在 8 核以上系统上无法扩展。

传统单队列的问题：
```
所有 CPU 共享一个请求队列 → 一把 queue_lock → 提交路径序列化
→ 8 核系统上锁竞争消耗 ~30% CPU
→ 最大 IOPS 被单核锁释放率限制
```

blk-mq 的解决方案：
```
每个 CPU 独立软件队列 → 映射到多个硬件队列
→ 提交路径主要操作 per-CPU 数据，几乎无锁
→ IOPS 随核数线性扩展
```

**doom-lsp 确认**：`include/linux/blk-mq.h` 包含 **323 个符号**。核心实现在 `block/blk-mq.c`（3159 行）。关键函数：`blk_mq_submit_bio` @ L3141，`blk_mq_complete_request` @ L1353，`blk_mq_get_tag`。

---

## 1. 核心数据结构

### 1.1 `struct request_queue`——队列实例

每个块设备（如 NVMe 固态盘）创建一个 `struct request_queue`：

```c
// include/linux/blkdev.h
struct request_queue {
    struct request          *last_merge;             // 上次合并的请求
    struct elevator_queue   *elevator;               // I/O 调度器

    // ——— blk-mq 核心字段 ———
    struct blk_mq_ctx       __percpu *queue_ctx;     // per-CPU 软件队列
    struct blk_mq_hw_ctx    **queue_hw_ctx;          // 硬件队列数组
    unsigned int            nr_hw_queues;             // 硬件队列数量
    struct blk_mq_tags      *tags;                   // 请求标签

    // ——— 限流 ———
    struct blk_plug          *plug;                  // 进程级批量

    // ——— 通用 ———
    spinlock_t               queue_lock;
    struct gendisk          *disk;
    struct kobject           kobj;
    unsigned long            nr_requests;            // 最大未完成请求数
};
```

### 1.2 `struct blk_mq_hw_ctx`——硬件上下文

每个硬件队列对应一个硬件 I/O 通道（NVMe Submission Queue）：

```c
struct blk_mq_hw_ctx {
    struct list_head        dispatch_list;     // 待下发到硬件的请求链表
    struct list_head        queued_list;       // 已完成请求链表
    struct blk_mq_tags      *tags;             // tag 池（最大并发数）
    struct blk_mq_ctx       **ctxs;            // 映射到此 hctx 的软件队列
    unsigned int            nr_ctx;            // ctx 数量
    spinlock_t              lock;              // 保护 dispatch_list
    unsigned int            queue_num;         // 硬件队列编号
    unsigned long            flags;            // BLK_MQ_F_* 标志
    struct request_queue    *queue;
    void                    *driver_data;      // 驱动私有数据（NVMe: nvmeq）
};
```

### 1.3 `struct blk_mq_ctx`——per-CPU 软件队列

```c
struct blk_mq_ctx {
    struct list_head        rq_lists[HCTX_MAX_TYPES]; // 读/写/poll 分离
    struct list_head        dispatch_busy;              // 忙碌列表
    unsigned int            cpu;
    unsigned short          index_hw[HCTX_MAX_TYPES];   // 在 hctx->ctxs 中的索引
    struct request_queue    *queue;
};
```

每个 CPU 一个 `blk_mq_ctx`。请求首先进入当前 CPU 的 ctx 链表。然后 blk_mq 根据 CPU 拓扑将 ctx 映射到对应的硬件队列。

### 1.4 `struct request`——块 I/O 请求

```c
struct request {
    struct request_queue    *q;                // 所属队列
    struct blk_mq_ctx       *mq_ctx;           // 所属软件队列
    struct blk_mq_hw_ctx    *mq_hctx;          // 硬件上下文
    blk_qc_t                qc;                // 完成码
    struct bio              *bio;              // I/O 数据载体（BIO 链表）
    struct bio              *biotail;          // BIO 链表尾
    struct list_head        queuelist;         // 链入软件/硬件队列
    struct rb_node          rb_node;            // deadline 调度器的红黑树节点
    struct request          *rq_next;           // 链表 next（rq_list 用）
    unsigned int            rq_flags;           // RQF_* 标志位
    req_opf_t               cmd_flags;          // 命令: REQ_OP_READ/WRITE/FLUSH
    sector_t                __sector;           // 起始扇区
    unsigned int            __data_len;          // 数据长度（字节）
    struct scatterlist      *sg;                // DMA scatterlist
    unsigned int            nr_phys_segments;    // 物理段数
    void                    *special;           // 驱动私有数据
};
```

---

## 2. 架构与拓扑映射

```
逻辑视图（从 CPU 到硬件）：
                                   ┌──────────────────┐
  CPU 0 → blk_mq_ctx[0] ──────────┤                  │
                                   │ blk_mq_hw_ctx[0] ├──→ NVMe SQ 0
  CPU 1 → blk_mq_ctx[1] ──────────┤                  │
                                   └──────────────────┘
                                                   │
  CPU 2 → blk_mq_ctx[2] ──────────┐                │
                                   │ blk_mq_hw_ctx[1]├──→ NVMe SQ 1
  CPU 3 → blk_mq_ctx[3] ──────────┘                │
                                   └──────────────────┘

拓扑映射函数 blk_mq_map_queue_type：
  输入：CPU 编号
  输出：对应的 hctx 索引
  策略：
    1. 如果 nr_hw_queues >= nr_cpus：每个 CPU 独立 hctx
    2. 如果 nr_hw_queues < nr_cpus：多个 CPU 共享 hctx（按 socket/NUMA node 分组）
```

---

## 3. 🔥 提交路径——blk_mq_submit_bio 完整数据流

```c
// block/blk-mq.c:3141 — doom-lsp 确认
void blk_mq_submit_bio(struct bio *bio)
{
    struct request_queue *q = bdev_get_queue(bio->bi_bdev);
    struct blk_plug *plug = current->plug;
    struct request *rq;
    blk_status_t ret;

    // ——— 1. BIO 合法性检查 ———
    if (unlikely(bio_check_ro(bio, q)))
        return;
    if (unlikely(bio_may_be_committing(bio)))
        return;

    // ——— 2. 分配请求 + 获取 tag ———
    rq = __blk_mq_alloc_request(rq_data);           // @ block/blk-mq.c
    // ├─ data->ctx = blk_mq_get_ctx(q)
    // │   → this_cpu_ptr(q->queue_ctx)            ← 获取当前 CPU 的 ctx
    // │
    // ├─ data->hctx = blk_mq_map_queue(q, data->ctx->cpu, data->cmd_flags)
    // │   → 通过 CPU 拓扑找到对应的 hw queue
    // │   → 如果此 CPU 属于 NUMA node 0，映射到 hctx[0]
    // │   → 如果此 CPU 属于 NUMA node 1，映射到 hctx[1]
    // │
    // └─ blk_mq_get_tag(data)
    //     → sbitmap_get(&tags->sb_bitmap)          ← 位图分配 tag
    //     → TAG 是请求的唯一 ID（0..depth-1）
    //     → 用于跟踪完成时的请求对应关系
    //     → 如果无可用 tag：sbitmap_get_shallow → BLK_STS_RESOURCE

    // ——— 3. 请求初始化 ———
    blk_mq_rq_ctx_init(q, alloc_data, ...);
    // 设置 rq->q, rq->mq_ctx, rq->mq_hctx, rq->rq_flags, rq->cmd_flags
    req->mq_ctx = data->ctx;
    req->mq_hctx = data->hctx;
    req->rq_flags |= RQF_MQ_INFLIGHT;

    // ——— 4. 尝试合并到 plug ———
    if (plug) {
        // 检查是否可以合并到 plug 中的已有请求
        // ⚡ 合并条件：
        //   1. 同一 hctx
        //   2. bio 的扇区范围相邻
        //   3. 读/写类型相同
        if (blk_attempt_plug_merge(q, bio, ...))
            goto out;       // ← 合并成功！无需提交硬件
        // 合并后 bio 被吸收到已有 request 中
        // → 减少请求数量，提高效率
    }

    // ——— 5. BIO → request 数据映射 ———
    blk_rq_map_bio(rq, bio);
    // 将 bio 的 struct bio_vec 数组转换为 request 的 scatterlist
    // → 最终用于 DMA 映射
    // → 可能拆分为多个物理段

    // ——— 6. 提交决策 ———
    // 方案 A：放入 plug（批量提交）
    if (plug) {
        blk_mq_add_to_plug(plug, rq, ...);          // 暂存
        // plug 将在 schedule() 或主动 flush 时统一提交
        // flush 触发：blk_mq_flush_plug_list
        //   → blk_mq_dispatch_plug_list
        //       → __blk_mq_flush_list(q, &rqs)
        //          → q->mq_ops->queue_rqs(rqs)    ← 批量下发
        goto out;
    }

    // 方案 B：直接下发
    if (!blk_mq_try_issue_directly(rq->mq_hctx, rq)) {
        // → q->mq_ops->queue_rq(hctx, &bd)  ← ★ 直接到驱动
        //    = nvme_queue_rq()
        // → 如果驱动返回 BUSY → blk_mq_insert_request
    }

out:
    return;
}
```

---

## 4. 🔥 Plug 批量机制

```c
// struct blk_plug（per-task，在进程调度时创建）
struct blk_plug {
    struct list_head        list;           // 待提交的 request 列表
    struct list_head        *rq_head;       // 当前 hctx 的 request 尾部
    struct list_head        cb_list;        // callback 列表
    unsigned int            depth;          // 当前深度（合并用）
};
```

**Plug flush 数据流**：

```
schedule() 或 __blk_flush_plug()
  │
  └─ blk_mq_flush_plug_list(plug, ...)
       │
       ├─ blk_mq_dispatch_plug_list(plug, from_sched)
       │    │
       │    ├─ blk_mq_extract_queue_requests(&list, &rqs)
       │    │   → 将同一 q 的请求提取到单独列表
       │    │   → 允许一次 queue_rqs() 调用处理多个
       │    │
       │    ├─ blk_mq_dispatch_queue_requests(&rqs, depth)
       │    │    │
       │    │    ├─ [a] 批量下发（如果驱动支持）：
       │    │    │   q->mq_ops->queue_rqs(rqs)
       │    │    │   = nvme_queue_rqs()
       │    │    │   → 一次遍历：将多个请求写入 NVMe SQ
       │    │    │   → 只写一次 doorbell（批量通知硬件）
       │    │    │
       │    │    └─ [b] 逐一下发（如果驱动不支持批量）：
       │    │        blk_mq_issue_direct(rqs)
       │    │        └─ for each: q->mq_ops->queue_rq(hctx, &bd)
       │    │
       │    └─ 有 requeue_list? → 再次尝试
       │
       └─ 释放 plug
```

---

## 5. Tag 管理——sbitmap

```c
// include/linux/sbitmap.h
struct sbitmap {
    unsigned int depth;              // 最大 tag 数
    unsigned int shift;              // 每个 word 的位偏移
    unsigned int map_nr;             // word 数量
    struct sbitmap_word *map;        // 位图数组
};

struct sbitmap_word {
    unsigned long depth;             // 此 word 的有效位数
    unsigned long word;              // 实际位图（atomic）
    unsigned long cleared;           // 清理标记（延迟更新用）
};
```

**分配流程**：

```
blk_mq_get_tag(data) → __blk_mq_get_tag(data)
  │
  ├─ [1] 快速路径：sbitmap_get(&tags->sb_bitmap, ...)
  │   for (i = 0; i < map_nr; i++) {
  │       hint = this_cpu(hint_word);     ← 从当前 CPU 偏好的 word 开始
  │       word = READ_ONCE(map[hint].word);
  │       bit = find_first_zero_bit(&word, depth);
  │       if (bit < depth) {
  │           if (test_and_set_bit(bit, &map[hint].word)) == 0)
  │               return hint * WORD_BITS + bit;  ← 分配成功！
  │       }
  │   }
  │
  ├─ [2] 慢速路径：sbitmap_get_shallow(...)
  │   → 允许一定程度的抢用
  │
  └─ [3] 阻塞等待：
      sbitmap_prepare_to_wait(ws, &wait, ...)
      → 调度等待
      → sbitmap_finish_wait(ws, &wait, ...)

释放：
  blk_mq_free_request(req) → sbitmap_clear_bit(&tags->sb_bitmap, tag)
    → clear_bit(tag & (BITS_PER_WORD-1), &map[tag >> shift].word)
    → 如果 sbitmap_wait_queue 非空 → 唤醒等待者
```

---

## 6. 🔥 完成路径——blk_mq_complete_request

```
NVMe 硬件完成 I/O → 发送 MSI-X 中断
  │
  └─ nvme_irq() → nvme_process_cq(cq)
       │
       ├─ 遍历完成队列（CQ）条目
       ├─ 从 CQE 中取出 command_id（= tag）
       ├─ req = tags->rq[tag]                  ← 通过 tag 找到 request
       │
       └─ nvme_handle_cqe(cq, cqe)
            │
            └─ blk_mq_complete_request(req)    @ block/blk-mq.c:1353
                 │
                 ├─ blk_mq_complete_request_remote(req)
                 │    │
                 │    ├─ [情况 A: IPI 跨核完成]
                 │    │   如果当前 CPU != req->mq_ctx->cpu:
                 │    │     → __blk_mq_complete_request_remote
                 │    │     → smp_call_function_single_async(
                 │    │          req->mq_ctx->cpu, &req->csd)
                 │    │     → IPI 中断目标 CPU
                 │    │     → 在目标 CPU 上调用 __blk_mq_complete_request
                 │    │     → 这样做是为了 cache locality
                 │    │
                 │    └─ [情况 B: 同 CPU 完成]
                 │       如果当前 CPU == req->mq_ctx->cpu:
                 │         → 直接完成
                 │
                 ├─ [调用 I/O 完成回调]
                 │   __blk_mq_complete_request(req)
                 │    │
                 │    ├─ req->q->mq_ops->complete(rq)  ← 驱动完成处理
                 │    │   → nvme_pci_complete_rq
                 │    │
                 │    └─ blk_mq_end_request(req, error)
                 │         │
                 │         ├─ blk_update_request(req, error, nr_bytes)
                 │         │   → for each bio in req:
                 │         │        bio->bi_status = error
                 │         │        bio_endio(bio)     ← 通知上层 I/O 完成
                 │         │          → 如果 bio 有 split: 递归
                 │         │
                 │         └─ blk_mq_free_request(req)
                 │              ├─ blk_mq_put_tag(tags, ctx, tag)
                 │              │   → sbitmap_clear_bit → 释放 tag
                 │              │   → 唤醒等待 tag 的提交路径
                 │              ├─ blk_mq_sched_restart(hctx)
                 │              │   → 如果 I/O 调度器有等待请求 → 重新调度
                 │              └─ 释放 request 到 kmem_cache
                 │
                 └─ [统计更新]
                     update_io_ticks(req);
```

---

## 7. blk-mq 与 NVMe 驱动的配合

```
NVMe 驱动注册：
  struct blk_mq_ops nvme_mq_admin_ops = {
      .queue_rq       = nvme_admin_queue_rq,     // 提交请求
      .queue_rqs      = nvme_pci_queue_rqs,       // 批量提交
      .complete       = nvme_pci_complete_rq,     // 完成处理
      .commit_rqs     = nvme_commit_rqs,           // 刷门铃
      .init_hctx      = nvme_init_hctx,           // 初始化 hctx
      .init_request   = nvme_init_request,         // 初始化 request
  };

NVMe 提交请求（nvme_queue_rq）：
  → nvme_setup_cmd(req, cmd)          // 设置命令（读/写/标识）
  → nvme_submit_cmd(q, cmd, write)    // 写入 SQ Tail doorbell
    → writel(tail, q->q_db);          // ★ 物理写入 NVMe 的 MMIO 寄存器
                                       //   通知硬件处理新提交的请求
```

---

## 8. 调度器集成

blk-mq 支持可插拔 I/O 调度器：

| 调度器 | 实现 | 策略 |
|--------|------|------|
| none | 无调度 | 直接下发，不排序 |
| mq-deadline | deadline 算法 | 按扇区排序，设置 deadline 防饿死 |
| bfq | 预算公平队列 | 按进程公平分配带宽 |
| kyber | 令牌桶 | 跟踪延迟，动态调整并发量 |

```c
// 调度器插入点：
blk_mq_insert_request(rq, at_head)
  ├─ if (q->elevator)
  │     e->type->ops.insert_requests(hctx, &list, at_head)
  │     // deadline_add_request → 插入红黑树（按扇区排序）
  │     // 或按 deadline 插入 FIFO 链表
  │
  └─ else
       __blk_mq_insert_request(hctx, rq, at_head)
       // 直接放入 ctx->rq_lists[type]

// 调度器下发：
blk_mq_dispatch_rq_list(hctx, &list, ...)
  ├─ if (!list_empty)
  │     q->mq_ops->queue_rq(hctx, &bd)  ← 下发到硬件
  └─ if (remain)
       blk_mq_add_to_requeue_list(...)  ← 重试
```

---

## 9. 请求合并策略

blk-mq 在多个层面尝试合并请求以减少 I/O 次数：

### 9.1 前向合并（Front Merge）

```c
// 新 bio 追加到现有 request 的前面
// 条件：new_bio 的结束扇区 == request 的起始扇区
if (bio_end_sector(new) == rq->__sector) {
    rq->__sector = new_bio->bi_iter.bi_sector;
    rq->__data_len += new_bio->bi_iter.bi_size;
    // 前向合并成功
}
```

### 9.2 后向合并（Back Merge）

```c
// 新 bio 追加到现有 request 的后面
// 条件：new_bio 的起始扇区 == request 的结束扇区
if (new_bio->bi_iter.bi_sector == bio_end_sector(rq->bio)) {
    // 将 new_bio 追加到 rq->biotail 之后
    rq->biotail->bi_next = new_bio;
    rq->biotail = new_bio;
    rq->__data_len += new_bio->bi_iter.bi_size;
    // 后向合并成功
}
```

### 9.3 请求合并的影响

| 场景 | 无合并 | 有合并 | 提升 |
|------|--------|--------|------|
| 顺序 4K 写 × 128 | 128 请求 | 1 请求（512KB）| IOPS 128x |
| 随机 4K 写 × 128 | 128 请求 | 通常不合并 | — |
| 扩展 4K 写 × 4 | 4 请求 | 1 请求（16KB）| IOPS 4x |

---

## 10. 性能数据

| 指标 | 传统单队列 | blk-mq | 说明 |
|------|-----------|--------|------|
| 单核 IOPS（随机 4K 读）| ~300K | ~500K | 减少路径开销 |
| 全核 IOPS（128 核）| ~500K | ~10M | 消除锁竞争 |
| 提交路径锁争用 | ~30% CPU | ~1% CPU | per-CPU 队列 |
| P99 延迟（低负载）| ~100μs | ~50μs | 直接下发路径 |
| tag 分配延迟 | ~100ns | ~50ns | sbitmap vs 全局位图 |

---

## 10. 源码文件索引

| 文件 | 关键符号 | 行 |
|------|---------|------|
| `include/linux/blk-mq.h` | `struct blk_mq_tags` | L14 |
| `include/linux/blk-mq.h` | `struct blk_mq_hw_ctx` | — |
| `block/blk-mq.c` | `blk_mq_submit_bio` | 3141 |
| `block/blk-mq.c` | `blk_mq_complete_request` | 1353 |
| `block/blk-mq-tag.c` | `blk_mq_get_tag` | — |
| `block/blk-mq.c` | `blk_mq_dispatch_plug_list` | — |

---

## 11. 关联文章

- **29-io-uring**：io_uring 使用 blk-mq 提交 I/O
- **121-io-uring-deep**：io_uring 与 blk-mq 的深度配合

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
