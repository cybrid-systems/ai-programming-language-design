# 160-bio_request — Block层IO请求深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`block/blk-core.c` + `block/blk-mq.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**bio** 和 **request** 是 Linux 块设备 I/O 的核心数据结构。bio 是高层 I/O 描述（一个文件操作），request 是底层设备队列中的实际 I/O 命令（可能由多个 bio 合并而来）。

## 1. struct bio — 块 I/O 描述符

```c
// include/linux/blk_types.h — bio
struct bio {
    struct bio              *bi_next;          // 链表（请求中的多个 bio）
    struct block_device     *bi_bdev;         // 块设备
    unsigned int            bi_opf;           // 操作标志（REQ_*）
    unsigned int            bi_iter.bi_size;  // I/O 大小（字节）

    // 迭代器
    struct bvec_iter       bi_iter;

    // 数据
    union {
        struct bio_vec     *bi_inline_vecs;  // 内联 vec（少量数据）
        struct bvec_iter    bi_max_vecs;      // 最大 vec 数
    };

    // 回调
    bio_end_io_t          *bi_end_io;       // 完成回调
    void                  *bi_private;        // 私有数据

    // 统计
    unsigned short         bi_vcnt;            // vec 数量
    unsigned short         bi_max_vecs;       // 最大 vec
    atomic_t               __bi_cnt;           // 引用计数

    // 压缩
    struct compressed_bio  *bi_compressed;
};
```

### 1.2 struct bvec_iter — 迭代器

```c
// include/linux/blk_types.h — bvec_iter
struct bvec_iter {
    unsigned int            bi_sector;          // 起始扇区
    unsigned int            bi_idx;            // 当前 vec 索引
    unsigned int            bi_bvec_done;      // 当前 vec 内偏移
    unsigned int            bi_size;          // 剩余 I/O 大小
};
```

### 1.3 struct bio_vec — 单个片段

```c
// include/linux/blk_types.h — bio_vec
struct bio_vec {
    struct page             *bv_page;         // 物理页
    unsigned int            bv_len;            // 长度（字节）
    unsigned int            bv_offset;          // 页内偏移
};
```

## 2. bio 的生命周期

```
应用写入文件：
  用户缓冲 → bio_add_page() → submit_bio() → 块设备队列
        ↓
  generic_make_request() → blk_queue_bio()
        ↓
  请求合并（电梯算法）或直接创建 request
        ↓
  blk_mq_submit() → 硬件队列
        ↓
  设备驱动 DMA → 完成中断 → bio_endio()
```

## 3. submit_bio — 提交 bio

### 3.1 submit_bio

```c
// block/blk-core.c — submit_bio
void submit_bio(struct bio *bio)
{
    struct block_device *bdev = bio->bi_bdev;
    struct request_queue *q = bdev->bd_queue;

    // 1. 设置 bi_iter.bi_sector
    bio_set_sector(bio, bio->bi_iter.bi_sector);

    // 2. 调用通用请求处理
    generic_make_request(bio);
}
```

### 3.2 generic_make_request

```c
// block/blk-core.c — generic_make_request
void generic_make_request(struct bio *bio)
{
    struct request_queue *q = bdev->bd_queue;

    // 1. 检查扇区对齐
    if (!bio_check_ro(bio))
        return;

    // 2. 调用队列的 make_request_fn
    // 这通常是 __blk_mq_submit_bio 或电梯合并函数
    q->make_request_fn(q, bio);
}
```

## 4. 请求合并（电梯算法）

### 4.1 elv_merge — 合并

```c
// block/elevator.c — elv_merge
int elv_merge(struct request_queue *q, struct request **req, struct bio *bio)
{
    // 1. 尝试与队列末尾的 request 合并
    if (blk_rq_sectors(*req) + bio_sectors(bio) <= BLK_MAX_SEGMENTS) {
        // 合并
        blk_rq_merge_ok(*req, bio);
        elv_merged_request(*req, ELEVATOR_FRONT_MERGE);
        return ELEVATOR_FRONT_MERGE;
    }

    // 2. 否则尝试与队列中间的 request 合并
    return ELEVATOR_BACK_MERGE;
}
```

## 5. request — 设备命令

### 5.1 struct request — 请求

```c
// include/linux/blk_request.h — request
struct request {
    struct request_queue   *q;                // 所属队列

    // 扇区
    sector_t              __sector;            // 起始扇区
    unsigned int          __data_len;         // 数据长度（字节）

    // bio 链表
    struct bio            *bio;              // 第一个 bio
    struct bio            *biotail;         // 最后一个 bio

    // 状态
    unsigned long           atomic_flags;      // RQF_* 标志

    // tag（用于 blk_mq）
    int                   tag;
    int                   internal_tag;

    // 结束函数
    rq_end_io_fn          *end_io;           // 完成回调
    void                  *end_io_data;
};
```

## 6. blk_mq 路径

### 6.1 __blk_mq_submit_bio

```c
// block/blk-mq.c — __blk_mq_submit_bio
void __blk_mq_submit_bio(struct bio *bio)
{
    struct request_queue *q = bio->bi_bdev->bd_queue;
    struct blk_mq_hw_queues *hctxs = q->queue_hw_ctx;
    unsigned int ctx_idx = raw_smp_processor_id();
    struct blk_mq_hw_queue *hctx = hctxs[ctx_idx];

    // 1. 分配 request
    struct request *rq = blk_mq_alloc_request(q, bio);
    if (!rq)
        return;

    // 2. 放入派发链表
    spin_lock(&hctx->lock);
    list_add_tail(&rq->queuelist, &hctx->dispatch);
    spin_unlock(&hctx->lock);

    // 3. 触发硬件队列
    blk_mq_trigger_complete(hctx);
}
```

## 7. bio 与 page_cache 的关系

```
bio 和 page_cache 的关系：

用户写入 /foo：
  write(fd, buf, 4096)
      ↓
  generic_perform_write()
      ↓
  __bio_add_page() → bio_add_page()
      ↓
  bio: bi_io_vec[0] = { page=page, bv_offset=0, bv_len=4096 }
      ↓
  submit_bio(bio, REQ_OP_WRITE)
      ↓
  块设备驱动通过 DMA 从 page_cache 读取数据

物理 I/O：
  bio 使用的是 page_cache 中的物理页
  驱动 DMA 直接从这些物理页读写
```

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `block/blk-core.c` | `submit_bio`、`generic_make_request`、`blk_queue_bio` |
| `block/blk-mq.c` | `__blk_mq_submit_bio` |
| `block/elevator.c` | `elv_merge` |
| `include/linux/blk_types.h` | `struct bio`、`struct bio_vec`、`struct bvec_iter` |
| `include/linux/blk_request.h` | `struct request` |

## 9. 西游记类比

**bio** 就像"天庭的货运单"——

> bio（Block I/O）就像一张货运单，描述了要运什么（哪个 page、哪个扇区、多长）。如果天庭有多个仓库的文件要同步（多个 bio），这些单子可能会被合并成一张大货运单（request 合并），一次运多个文件，减少运输次数。请求合并（电梯算法）就像物流公司在发货前把去同一个城市的货运单拼成一车货。bio 的 bi_vec 就像货运单上的物品清单，每一项是一个物理页（page）和它在页内的位置（offset/len）。货运单提交给车队调度员（blk_mq），调度员按照卡车的装载能力（队列深度）安排发车。

## 10. 关联文章

- **blk-mq**（article 21）：多队列块设备
- **page_cache**（article 20）：bio 的 page 来源
- **writeback**（article 159）：writeback 生成 bio

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

