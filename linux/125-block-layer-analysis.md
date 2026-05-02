# 125-block-layer — Linux 块设备层深度源码分析

> Kernel: Linux 7.0-rc1  
> Source: `block/blk-mq.c`, `block/blk-mq-sched.c`, `block/mq-deadline.c`, `block/bfq-iosched.c`, `include/linux/blkdev.h`

---

## 1. 概述：Block Layer 在 I/O 栈中的位置

```
User Process
    ↓ write(2)
VFS (inode, page cache)
    ↓
  Bio                     ← 块层入口：submit_bio()
    ↓
Block Layer (blk-mq)     ← 多队列调度、合并、排序
    ↓
  Request                ← 调度算法操作的单位
    ↓
NVMe/SCSI/SATA Driver
    ↓
Hardware (NVMe SSD / SATA SSD / HDD)
```

Linux Block Layer 经历了从单队列 `bio` -> `request` 到多队列 blk-mq 的演进。blk-mq 的核心设计目标是：**在多核 CPU + 多核 NVMe 时代，消除软件层面的锁竞争瓶颈**，让每个 CPU 核可以独立向各自的硬件队列提交 I/O。

---

## 2. bio 与 request：submit_bio → blk_mq_submit_bio 路径

### 2.1 入口：submit_bio_noacct

`submit_bio_noacct`（`block/bio.c`）是 bio 进入块层的统一入口：

```c
void submit_bio_noacct(struct bio *bio)
{
    // 1. 递归展平：将 bio 链递归转化为迭代
    // 2. 如果是分区设备，更新 bi_bdev 指向整个设备
    // 3. 调用 __submit_bio() 进一步分发
    __submit_bio(bio);
}
```

`__submit_bio()` 根据 `bio_set` 决定走哪个路径：

```c
static void __submit_bio(struct bio *bio)
{
    struct gendisk *disk = bio->bi_bdev->bd_device->disk;

    if (blk_mq_submit_bio(bio))  // blk-mq 路径
        return;
    // 否则走传统路径或驱动自定义 submit_bio
    disk->fops->submit_bio(bio);
}
```

### 2.2 blk_mq_submit_bio 完整路径（blk-mq.c:3141）

```
blk_mq_submit_bio(bio)
├── blk_mq_peek_cached_request(plug, q, opf)    // [1] 检查 plug 缓存
├── bio_queue_enter(bio)                        // [2] 获取 queue 引用
├── bio_unaligned(bio, q) → bio_io_error()      // [3] 对齐检查
├── blk_mq_can_poll(q) / REQ_POLLED             // [4] poll 队列检查
├── __bio_split_to_limits(bio)                  // [5] 拆分 bio 到设备限制
├── bio_integrity_prep(bio)                     // [6] 数据完整性预检
├── blk_mq_attempt_bio_merge(q, bio, nr_segs)  // [7] 尝试 merge 到已有 request
│   ├── blk_attempt_plug_merge()                //    plug 层 merge
│   └── blk_mq_sched_bio_merge()                //    elevator 层 merge
├── blk_zone_plug_bio()                         // [8] 顺序写区域锁优化
├── blk_mq_get_new_requests() / blk_mq_use_cached_rq()  // [9] 获取/复用 request
├── blk_mq_bio_to_request(rq, bio, nr_segs)    // [10] 填充 request 字段
├── blk_crypto_rq_get_keyslot()                 // [11] Inline encryption
├── blk_zone_write_plug_init_request()         // [12] 区域写锁初始化
├── blk_insert_flush(rq)                        // [13] flush 请求特殊处理
├── blk_add_rq_to_plug(plug, rq)               // [14] 加入 plug（延迟提交）
│   └── → return                               //    下次 plug 刷新时才真正入队
├── blk_mq_insert_request() + blk_mq_run_hw_queue()  // 有调度器 or hctx忙
└── blk_mq_try_issue_directly()                // 直接下发硬件
```

### 2.3 Merge 条件：bio → request 的合并

合并发生在两个层面：

**层面一：plug 层合并（blk_attempt_plug_merge）**

在 `blk_add_rq_to_plug` 中，如果 plug 中已有同 queue、同方向的 request，会尝试合并。合并条件：
- `bio_mergeable(bio)` 为 true（相同操作类型、可合并 flag）
- `plug->rq_count < blk_plug_max_rq_count(plug)`
- 新 bio 与 plug 中最近的 request 连续（sector 连续）

**层面二：blk_mq_attempt_bio_merge（blk-mq.c:3034）**

```c
static bool blk_mq_attempt_bio_merge(struct request_queue *q,
                                     struct bio *bio, unsigned int nr_segs)
{
    if (!blk_queue_nomerges(q) && bio_mergeable(bio)) {
        if (blk_attempt_plug_merge(q, bio, nr_segs))  // plug 层
            return true;
        if (blk_mq_sched_bio_merge(q, bio, nr_segs))   // elevator 层
            return true;
    }
    return false;
}
```

- `blk_queue_nomerges(q)` 返回 true 时禁用合并（通常因为 device mapper 或硬件自己做合并）
- `bio_mergeable(bio)` 检查 bio 是否设置了 `REQ_NOMERGE` flag
- 调度器层 merge（如 mq-deadline 的 `dd_bio_merge`）：检查 bio 是否能合并到已排队的 request 的红黑树中（`sort_list`）

### 2.4 request 结构（blk-mq.h:105）

```c
struct request {
    struct request_queue *q;
    struct blk_mq_ctx *mq_ctx;    // 软件队列上下文（per-cpu）
    struct blk_mq_hw_ctx *mq_hctx; // 硬件队列

    blk_opf_t cmd_flags;          // op (READ/WRITE/FLUSH...) + flags
    req_flags_t rq_flags;

    int tag;                      // 驱动 tag（BLK_MQ_NO_TAG = 未分配）
    int internal_tag;             // 调度器内部 tag（如 mq-deadline 无此字段）

    unsigned int __data_len;     // 总字节数
    sector_t __sector;            // 起始扇区

    struct bio *bio;              // 关联的 bio 链
    struct bio *biotail;

    union {
        struct list_head queuelist;   // 调度队列链表节点
        struct request *rq_next;      // 批量 alloc 时用作单链表
    };

    enum mq_rq_state state;       // MQ_RQ_IDLE / MQ_RQ_IN_FLIGHT ...
    atomic_t ref;                  // 引用计数

    unsigned long deadline;       // deadline 调度器用（jiffies）

    union {
        struct hlist_node hash;    // merge hash（在调度器中）
        struct llist_node ipi_list; // softirq 完成队列
    };

    // ... 还有 wbt, crypt_ctx, stats 等
};
```

---

## 3. blk-mq 多队列架构：hctx 与 CPU 的对应关系

### 3.1 三种硬件队列类型（blk-mq.h:488）

```c
enum hctx_type {
    HCTX_TYPE_DEFAULT,   // 普通读写 I/O（大多数场景）
    HCTX_TYPE_READ,      // 纯读 I/O（部分驱动用它实现读优先级）
    HCTX_TYPE_POLL,      // Polled I/O（如 NVMe poll 队列，无中断）
};
```

每个 `blk_mq_hw_ctx` 对应一个物理 hardware queue（或逻辑队列）。驱动通过 `blk_mq_tag_set` 配置：

```c
struct blk_mq_tag_set {
    .nr_hw_queues = 16;           // 硬件队列数
    .queue_depth = 64,            // 每队列深度
    .numa_node = NUMA_NO_NODE,
    .cmd_size = 0,
    .flags = BLK_MQ_F_TAG_QUEUE_SHARED,
    .map = {
        [HCTX_TYPE_DEFAULT] = { .mq_map = cpu_mask },  // 每个 CPU → hctx ID
        [HCTX_TYPE_READ]    = { .mq_map = ... },
        [HCTX_TYPE_POLL]    = { .mq_map = ... },
    },
    .ops = &nvme_mq_ops,
};
```

### 3.2 CPU → hctx 映射路径

bio 到达后，通过 `blk_mq_map_queue` 将 (opf, ctx) 映射到具体的 `blk_mq_hw_ctx`：

```c
// block/blk-mq.h:109
static inline struct blk_mq_hw_ctx *blk_mq_map_queue(blk_opf_t opf,
                                                     struct blk_mq_ctx *ctx)
{
    return ctx->hctxs[blk_mq_get_hctx_type(opf)];
}

static inline enum hctx_type blk_mq_get_hctx_type(blk_opf_t opf)
{
    if (opf & REQ_POLLED)  return HCTX_TYPE_POLL;
    if ((opf & REQ_OP_MASK) == REQ_OP_READ) return HCTX_TYPE_READ;
    return HCTX_TYPE_DEFAULT;
}

// ctx->hctxs[HCTX_TYPE_DEFAULT] 指向该 CPU 对应的 hctx
// 由 blk_mq_map_queues() 在初始化时建立映射
```

最终映射路径：
```
bio → blk_mq_map_queue(opf, ctx) 
    → ctx->hctxs[hctx_type]
    → blk_mq_map_queue_type(q, type, cpu)
    → queue_hctx(q, q->tag_set->map[type].mq_map[cpu])
```

### 3.3 软件队列：blk_mq_ctx（per-cpu）

每个 CPU 有一个 `blk_mq_ctx`，包含该 CPU 上所有软件队列的 request 链表：

```c
struct blk_mq_ctx {
    struct request_queue *queue;
    unsigned int cpu;

    spinlock_t lock;
    struct list_head rq_lists[HCTX_TYPE_POLL + 1];  // 每种 hctx_type 一个链表
    unsigned longpending[HCTX_TYPE_POLL + 1];       // 每个链表是否有 pending
};
```

### 3.4 blk_mq_sched_insert_request 路径（blk-mq.c:2623）

当 request 需要插入调度器或软件队列时，调用 `blk_mq_insert_request`：

```c
static void blk_mq_insert_request(struct request *rq, blk_insert_t flags)
{
    struct request_queue *q = rq->q;
    struct blk_mq_ctx *ctx = rq->mq_ctx;
    struct blk_mq_hw_ctx *hctx = rq->mq_hctx;

    if (blk_rq_is_passthrough(rq)) {
        // passthrough（ATA pass-through等）直接插入 hctx->dispatch
        blk_mq_request_bypass_insert(rq, flags);
    } else if (req_op(rq) == REQ_OP_FLUSH) {
        // flush 请求：插入 hctx->dispatch 前部（高优先级）
        blk_mq_request_bypass_insert(rq, BLK_MQ_INSERT_AT_HEAD);
    } else if (q->elevator) {
        // 有 elevator：调用调度器的 insert_requests
        list_add(&rq->queuelist, &list);
        q->elevator->type->ops.insert_requests(hctx, &list, flags);
    } else {
        // 无 elevator：插入 ctx->rq_lists[hctx->type]
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

调度器的 `insert_requests` 实现（如 mq-deadline）将 request 加入红黑树（`sort_list`）和 FIFO 链表（`fifo_list`）。

---

## 4. 调度算法：mq-deadline 与 BFQ

### 4.1 elevator 框架接口（elevator.h:57）

```c
struct elevator_mq_ops {
    void (*insert_requests)(struct blk_mq_hw_ctx *hctx,
                            struct list_head *list,
                            blk_insert_t flags);
    struct request *(*dispatch_request)(struct blk_mq_hw_ctx *);
    bool (*has_work)(struct blk_mq_hw_ctx *);
    void (*finish_request)(struct request *);
    void (*requeue_request)(struct request *);
    void (*dispatched)(struct request *, bool);
    // ...
};
```

### 4.2 mq-deadline：期限调度（mq-deadline.c）

mq-deadline 实现了一个基于**期限（deadline）**的 I/O 调度器，核心思想是：**防止任何 I/O 饿死**。

**核心数据结构：**

```c
// mq-deadline.c:30-38（默认值）
const int read_expire  = HZ / 2;      // 读请求最大存活时间 500ms
const int write_expire = 5 * HZ;      // 写请求最大存活时间 5s
const int writes_starved = 2;         // 读可"饿死"写的最大次数
const int fifo_batch = 16;            // 一批顺序请求数

struct dd_per_prio {
    struct rb_root sort_list[DD_DIR_COUNT]; // 按 sector 排序的红黑树
    struct list_head fifo_list[DD_DIR_COUNT]; // 按时间排序的 FIFO 队列
    u32 latest_pos[DD_DIR_COUNT];             // 记录上次调度的扇区位置
};

struct deadline_data {
    spinlock_t lock;
    struct dd_per_prio per_prio[DD_PRIO_COUNT]; // 3 个优先级
    int fifo_batch;
    int writes_starved;
    // ...
};
```

**调度算法：`__dd_dispatch_request`（mq-deadline.c:325）**

```
1. 如果 batching < fifo_batch，继续调度同一方向的下一请求（顺序批量优化）

2. 否则选择方向：
   - 若有读 FIFO 非空：
     · 若写 FIFO 有请求且已饿死读（starved >= writes_starved）→ dispatch 写
     · 否则 dispatch 读
   - 否则若写 FIFO 非空 → dispatch 写

3. 选定方向后，找最佳请求：
   - 检查是否有过期请求（fifo 头部的 deadline 已到）→ 用 fifo 顺序
   - 否则用红黑树找 sector 最接近上一位置的下个请求（找最近寻道的）
```

**关键防饥饿机制：**
- `writes_starved = 2`：最多连续饿死 2 次写，就强制 dispatch 写
- 读有更短的 expire 时间（500ms vs 5s）
- `fifo_batch = 16`：批量处理同方向请求减少寻道

**insert_requests（dd_insert_requests, mq-deadline.c:670）：**
- 加入红黑树 `sort_list[data_dir]`：按 sector 排序，用于找最近的请求
- 加入 FIFO `fifo_list[data_dir]`：按时间排序，用于检查 deadline

### 4.3 BFQ：加权公平队列（bfq-iosched.c）

BFQ（Budget Fair Queueing）是一个**基于磁盘时间片分配的加权公平队列**，核心目标是：**给交互式应用提供低延迟，同时保证低吞吐损失**。

**核心概念：**

1. **bfq_queue（bfqq）**：每个进程的 I/O 上下文（对应一个 `bfq_entity`）
2. **bfq_entity**：调度实体，包含虚拟时间（vtime）用于 B-WF2Q+ 排序
3. **weight**：每个 bfqq 有一个权重，默认从 ioprio 计算（1~100）

**B-WF2Q+（Worst-case Fair Weighted Fair Queuing）：**

BFQ 使用 B-WF2Q+ 算法实现加权公平：

```c
// bfq-iosched.c:35
// 每一个 bfq_entity 有一个虚拟时间（vtime），
// 表示该实体"消耗"的磁盘时间片
entity->vtime += service_1 / entity->weight;
// 调度时选 vtime 最小的实体优先服务（类似 CPU CFS）
```

**加权公平性保证：**
- 实体获得的磁盘带宽 = `weight_i / Σ(weight)`（理想情况）
- 权重高的进程获得更多磁盘时间片
- `bfq_entity_service_tree()` 维护最小堆（红黑树），快速找到 vtime 最小的实体

**weight-raising（交互性提升）：**

BFQ 会检测交互式应用（通过 `BFQQ_IO_HIW` flag）：
- 检测到交互式应用时，临时将 weight 提升到 `BFQ_WEIGHTIGHT`
- 持续一段时间后降回默认权重
- 这保证了桌面应用的 I/O 响应速度

**insert_requests（bfq_insert_requests, bfq-iosched.c:6292）：**
- 将 bfqq 的 entity 加入调度树的正确位置（按 vtime 排序）
- 如果 bfqq 不在调度树中，同时加入

**dispatch_request（bfq_dispatch_request, bfq-iosched.c:5297）：**
- B-WF2Q+ 选择 vtime 最小的 bfqq
- 从该 bfqq 中取一个 request
- 更新 bfqq 的 vtime（加上本次服务的 sector 数 / weight）

---

## 5. Dispatch 路径：blk_mq_try_issue_directly vs blk_mq_issue_rq

### 5.1 两条分发路径总览

```
blk_mq_submit_bio()
├── (plug 路径) blk_add_rq_to_plug() → 延迟到 blk_flush_plug_list()
│
├── 调度路径：blk_mq_insert_request() + blk_mq_run_hw_queue()
│              ↓
│          blk_mq_sched_dispatch_requests()  ←── hctx 触发调度
│              ↓
│          __blk_mq_sched_dispatch_requests()
│              ├── 有 elevator → blk_mq_do_dispatch_sched()
│              └── 无 elevator → blk_mq_do_dispatch_ctx()（轮询软件队列）
│
└── 直接下发：blk_mq_try_issue_directly()
                 ├── hctx stopped / queue quiesced → insert + run
                 ├── 需要调度 or 拿不到 tag → insert + run
                 └── 资源充足 → __blk_mq_issue_directly()
```

### 5.2 blk_mq_try_issue_directly（blk-mq.c:2768）

**何时走这条路径？**

在 `blk_mq_submit_bio` 末尾：
```c
if ((rq->rq_flags & RQF_USE_SCHED) ||
    (hctx->dispatch_busy && (q->nr_hw_queues == 1 || !is_sync))) {
    // → 有调度器，或单队列且忙：走调度路径
    blk_mq_insert_request(rq, 0);
    blk_mq_run_hw_queue(hctx, true);
} else {
    // → 无调度器且多队列 or sync I/O：直接下发
    blk_mq_run_dispatch_ops(q, blk_mq_try_issue_directly(hctx, rq));
}
```

**直接下发逻辑：**

```c
static void blk_mq_try_issue_directly(struct blk_mq_hw_ctx *hctx,
                                      struct request *rq)
{
    if (blk_mq_hctx_stopped(hctx) || blk_queue_quiesced(rq->q)) {
        // 硬件队列已停或队列被冻结：先插入调度队列，再触发调度
        blk_mq_insert_request(rq, 0);
        blk_mq_run_hw_queue(hctx, false);
        return;
    }

    if ((rq->rq_flags & RQF_USE_SCHED) || !blk_mq_get_budget_and_tag(rq)) {
        // 需要调度 或 拿不到 budget/tag：走调度
        blk_mq_insert_request(rq, 0);
        blk_mq_run_hw_queue(hctx, rq->cmd_flags & REQ_NOWAIT);
        return;
    }

    ret = __blk_mq_issue_directly(hctx, rq, true);
    switch (ret) {
    case BLK_STS_OK:
        break;                              // 成功
    case BLK_STS_RESOURCE:
    case BLK_STS_DEV_RESOURCE:
        // 硬件资源不足：绕过调度器直接插入 hctx->dispatch
        blk_mq_request_bypass_insert(rq, 0);
        blk_mq_run_hw_queue(hctx, false);
        break;
    default:
        blk_mq_end_request(rq, ret);       // 其他错误直接结束
        break;
    }
}
```

### 5.3 __blk_mq_issue_directly（blk-mq.c:2710）

直接调用驱动的 `queue_rq` 回调：

```c
static blk_status_t __blk_mq_issue_directly(struct blk_mq_hw_ctx *hctx,
                                            struct request *rq, bool last)
{
    struct request_queue *q = rq->q;
    struct blk_mq_queue_data bd = { .rq = rq, .last = last };

    ret = q->mq_ops->queue_rq(hctx, &bd);  // ← 驱动实现，如 nvme_queue_rq()

    switch (ret) {
    case BLK_STS_OK:
        blk_mq_update_dispatch_busy(hctx, false);
        break;
    case BLK_STS_RESOURCE:
    case BLK_STS_DEV_RESOURCE:
        // 驱动返回资源不足，重新入队等待下次调度
        blk_mq_update_dispatch_busy(hctx, true);
        __blk_mq_requeue_request(rq);
        break;
    default:
        blk_mq_update_dispatch_busy(hctx, false);
        break;
    }
    return ret;
}
```

### 5.4 blk_mq_dispatch_rq_list（blk-mq.c:2116）

从调度队列/hctx->dispatch 取一批 request 下发给驱动：

```c
bool blk_mq_dispatch_rq_list(struct blk_mq_hw_ctx *hctx,
                             struct list_head *list, bool get_budget)
{
    do {
        prep = blk_mq_prep_dispatch_rq(rq, get_budget);
        if (prep != PREP_DISPATCH_OK) break;

        bd.rq = rq; bd.last = list_empty(list);
        ret = q->mq_ops->queue_rq(hctx, &bd);  // 驱动提交

        switch (ret) {
        case BLK_STS_OK:
            queued++;
            break;
        case BLK_STS_RESOURCE:
        case BLK_STS_DEV_RESOURCE:
            needs_resource = true;
            blk_mq_handle_dev_resource(rq, list);  // 放回 dispatch
            goto out;
        default:
            blk_mq_end_request(rq, ret);
        }
    } while (!list_empty(list));
out:
    blk_mq_commit_rqs(hctx, queued, false);  // 通知驱动批结束
    // 将未完成的放回 hctx->dispatch，等待下次调度
}
```

### 5.5 hctx->dispatch vs 调度器队列

| 队列 | 位置 | 用途 |
|------|------|------|
| `hctx->dispatch` | 硬件队列对象 | 高优先级：passthrough、flush、硬件资源不足时回归的 request |
| `ctx->rq_lists[]` | per-cpu 软件队列 | 无 elevator 时，request 临时存放，等待轮询 dequeue |
| `elevator sort_list` | elevator 私有 | 有 elevator 时，request 排序（sector 顺序），由 elevator 算法决定 dispatch 顺序 |

**hctx->dispatch 的优先级高于调度器队列：** `__blk_mq_sched_dispatch_requests` 会先检查 `hctx->dispatch`，不为空则优先处理。

---

## 6. Completion：blk_mq_end_request vs blk_mq_free_request

### 6.1 调用关系

```
硬件完成中断 / softirq
    ↓
blk_mq_complete_request(rq)        // 发起完成通知
    ↓
__blk_mq_end_request()             // 真正完成处理
    ├── __blk_mq_end_request_acct()  // 统计（blk stats + 调度器 finished）
    │     ├── blk_stat_add()           // 更新 blk_rq_stat
    │     ├── blk_mq_sched_completed_request()  // 调度器完成钩子
    │     └── blk_account_io_done()     // 磁盘统计
    ├── blk_mq_finish_request()         // 清理 request 状态
    │     ├── blk_zone_finish_request() // 区域锁释放
    │     └── elevator finish_request() // 调度器完成钩子
    ├── rq->end_io(rq, error, NULL)    // 上层回调（如 fsync 完成）
    │     └── 若返回 RQ_END_IO_FREE → 外部持有引用，需要 free_request
    └── blk_mq_free_request(rq)         // 释放 tag + queue 引用
          ├── blk_crypto_free_request()
          ├── blk_pm_mark_last_busy()
          ├── blk_mq_put_tag(hctx->tags, ctx, rq->tag)     // 归还驱动 tag
          ├── blk_mq_put_tag(hctx->sched_tags, ctx, rq->internal_tag) // 归还调度 tag
          ├── blk_mq_sched_restart(hctx)   // 重启硬件队列（如果有等待请求）
          └── blk_queue_exit(q)           // 释放 queue 引用
```

### 6.2 blk_mq_end_request（blk-mq.c:1176）

```c
void blk_mq_end_request(struct request *rq, blk_status_t error)
{
    if (blk_update_request(rq, error, blk_rq_bytes(rq)))  // 更新 bio 状态，拆分
        BUG();
    __blk_mq_end_request(rq, error);
}
```

适用于单 request 场景（如 `bio_submit` 返回后的同步完成）。

### 6.3 blk_mq_end_request_batch（blk-mq.c:1197）

适用于批量完成（多个 request 通过 `io_comp_batch` 一起处理）：

```c
void blk_mq_end_request_batch(struct io_comp_batch *iob)
{
    while ((rq = rq_list_pop(&iob->req_list)) != NULL) {
        blk_complete_request(rq);  // 更新 remaining byte，继续完成流程
        // ...
        if (rq->end_io && rq->end_io(rq, 0, iob) == RQ_END_IO_NONE)
            continue;  // end_io 持有引用，跳过 free
        blk_mq_free_request(rq);
    }
}
```

### 6.4 blk_mq_free_request vs __blk_mq_free_request

**blk_mq_free_request（blk-mq.c:820）：**

```c
void blk_mq_free_request(struct request *rq)
{
    blk_mq_finish_request(rq);          // 清理 elevator 状态
    rq_qos_done(q, rq);                  // QOS throttle 记账

    WRITE_ONCE(rq->state, MQ_RQ_IDLE);
    if (req_ref_put_and_test(rq))        // 引用计数归零
        __blk_mq_free_request(rq);
}
```

**__blk_mq_free_request（blk-mq.c:799）：**

```c
static void __blk_mq_free_request(struct request *rq)
{
    blk_crypto_free_request(rq);
    blk_pm_mark_last_busy(rq);
    rq->mq_hctx = NULL;

    if (rq->tag != BLK_MQ_NO_TAG) {
        blk_mq_dec_active_requests(hctx);
        blk_mq_put_tag(hctx->tags, ctx, rq->tag);    // 归还驱动 tag
    }
    if (rq->internal_tag != BLK_MQ_NO_TAG)
        blk_mq_put_tag(hctx->sched_tags, ctx, rq->internal_tag);

    blk_mq_sched_restart(hctx);          // 触发下一次调度
    blk_queue_exit(q);                   // 释放 queue 引用计数
}
```

### 6.5 blk_mq_sched_restart

在 `__blk_mq_free_request` 的最后调用 `blk_mq_sched_restart(hctx)`：

```c
void __blk_mq_sched_restart(struct blk_mq_hw_ctx *hctx)
{
    clear_bit(BLK_MQ_S_SCHED_RESTART, &hctx->state);
    smp_mb();  // 内存屏障：确保 dispatch list 的修改对调度可见
    blk_mq_run_hw_queue(hctx, true);  // 异步触发调度
}
```

这是 **tag 归还后自动触发调度** 的机制：只要有 request 完成且有等待的 request，就会重新 kickoff `hctx` 的调度循环。

---

## 7. 数据流全景图

```
┌─────────────────────────────────────────────────────────────────┐
│  submit_bio_noacct() → __submit_bio() → blk_mq_submit_bio()     │
└─────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────┐    merge     ┌──────────────────────┐
│ plug (per-task)    │◄────────────│ ctx->rq_lists[]      │
│ cached_rqs         │              │ (无 elevator 时)     │
└────────────────────┘              └──────────────────────┘
         │
         ▼ (plug 刷新或直接路径)
┌──────────────────────────────────────────────────────────────┐
│  blk_mq_insert_request()                                      │
│  ├── passthrough/flush → hctx->dispatch (bypass)            │
│  ├── elevator → dd_insert_requests() / bfq_insert_requests() │
│  │              红黑树 sort_list + FIFO fifo_list              │
│  └── no elevator → ctx->rq_lists[hctx->type]                 │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│  blk_mq_run_hw_queue() → blk_mq_sched_dispatch_requests()     │
│                                                               │
│  hctx->dispatch ≠ ∅ ?                                        │
│    → 直接 blk_mq_dispatch_rq_list()  (bypass 路径，高优先级)  │
│                                                               │
│  q->elevator ≠ NULL ?                                        │
│    → blk_mq_do_dispatch_sched() → 调度器 dispatch_request()  │
│    → mq-deadline:  __dd_dispatch_request() → deadline FIFO    │
│    → BFQ:          __bfq_dispatch_request() → B-WF2Q+ 树       │
│                                                               │
│  q->elevator == NULL ?                                        │
│    → blk_mq_do_dispatch_ctx() → 轮询 ctx->rq_lists           │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│  __blk_mq_issue_directly() 或 blk_mq_dispatch_rq_list()       │
│  → q->mq_ops->queue_rq(hctx, &bd)  ← 驱动: nvme_queue_rq()  │
└──────────────────────────────────────────────────────────────┘
         │
         ▼ (硬件完成)
┌──────────────────────────────────────────────────────────────┐
│  blk_mq_end_request() → __blk_mq_end_request()               │
│    ├── __blk_mq_end_request_acct() (stats)                   │
│    ├── blk_mq_finish_request()                              │
│    ├── end_io 回调                                            │
│    └── blk_mq_free_request()                                │
│          ├── blk_mq_put_tag() (归还 tag)                      │
│          ├── blk_mq_sched_restart(hctx) (触发下一次调度)     │
│          └── blk_queue_exit(q) (释放引用)                     │
└──────────────────────────────────────────────────────────────┘
```

---

## 8. 关键设计决策与性能要点

### 8.1 为什么 blk-mq 能消除锁竞争？

传统单队列 elevator（如 cfq）所有 CPU 的 request 都进入同一个红黑树，需要全局锁。多队列 blk-mq 中：
- **无 elevator 时**：每个 CPU 的 request 进入各自的 `ctx->rq_lists`，完全无锁（只有 per-cpu 的 `ctx->lock`）
- **有 elevator 时**：request 进入 per-hctx 的调度数据结构，锁粒度是 per-hctx 而非全局

### 8.2 plug 机制的作用

plug 将一个任务（进程）的多个相邻 I/O 合并成一个批次提交，减少 `blk_mq_run_hw_queue` 的调用次数，提升吞吐。

### 8.3 blk_mq_sched_restart 的自动调度触发

`__blk_mq_free_request` 末尾的 `blk_mq_sched_restart(hctx)` 保证：**只要有 request 被归还且有待处理的 request，就一定会触发下一次调度**。这是一个 **O(1) 的调度触发机制**，无需额外定时器。

### 8.4 调度器的 dispatch 循环

`blk_mq_do_dispatch_sched` 是一个 `do-while` 循环，不断从 elevator 取 request 直到：
- `need_resched()`（需要让出 CPU）
- 时间超过 1 个 jiffy（防止长时间占用）
- 调度器返回 NULL（队列空了）

### 8.5 BFQ vs mq-deadline 的选择

| 特性 | mq-deadline | BFQ |
|------|------------|-----|
| 核心目标 | 防止 I/O 饿死 | 加权公平 + 低延迟 |
| 适合场景 | SSD、NVMe、低延迟存储 | 桌面、交互式、混合工作负载 |
| 公平性 | 基本按到达顺序，大 I/O 可能饿死小 I/O | 按 weight 比例分配带宽 |
| 延迟 | 有限保证（deadline） | 更好（交互式应用 weight 提升） |
| 开销 | 极低（简单红黑树+FIFO） | 较高（复杂实体树+权重计算） |

---

*分析基于 Linux 7.0-rc1 内核源码*
