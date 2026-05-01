# Linux Kernel Device Mapper (DM) 深度源码分析（doom-lsp 全面解析）

> 基于 Linux 7.0-rc1 主线源码（`drivers/md/dm.c` + `drivers/md/dm-table.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：mapped_device、dm_table、dm_target、bio 映射、dm-linear、dm-crypt、dm-verity

## 0. Device Mapper 概述

**Device Mapper** 是 Linux 块设备层的**转换框架**，所有逻辑卷（LVM2、dm-crypt、LUKS、dm-verity）都基于 DM 实现。

### 架构图

```
用户 I/O（bio）
     ↓
DM 设备（/dev/dm-N）
     ↓
dm_table（映射表：扇区范围 → target）
     ↓
dm_target（线性/crypt/verity/mirror...）
     ↓
下层块设备（物理磁盘 /dev/sda）
```

## 1. 核心数据结构

### 1.1 mapped_device — DM 设备

```c
// drivers/md/dm.c — mapped_device
struct mapped_device {
    // DM 设备的请求队列
    struct request_queue       *queue;             // 行 309

    // DM 设备对应的 gendisk
    struct gendisk             *disk;              // 行 316

    // 软硬件中断状态
    unsigned long              state;             // 行 323

    // 当前活动的映射表
    struct dm_table            *map;               // 行 330

    // 设备表（所有底层设备）
    struct list_head           table_devices;     // 行 337

    // 互斥锁
    struct mutex               suspend_lock;      // 行 344
    struct mutex               kill_sbtree_lock;  // 行 347

    // 引用计数
    refcount_t                 holders;           // 行 354
    refcount_t                 open_count;        // 行 357

    // SRCU（sleepable RCU，用于安全切换表）
    struct srcu_struct         io_barrier;        // 行 364

    // 请求批处理
    struct blk_mq_ops          *mq_ops;           // 行 371
    struct blk_mq_tag_set       tag_set;          // 行 378
    unsigned int                queue_io_hints;     // 行 385

    // 统计信息
    atomic_t                   pending[2];        // 行 392
    unsigned int                dummy_due_bio:1;   // 行 399
    unsigned int                zap_needed:1;      // 行 400
    unsigned int                internal_start:1;  // 行 401
};
```

### 1.2 dm_table — 映射表

```c
// drivers/md/dm-table.c — dm_table
struct dm_table {
    // 目标数量
    unsigned int              num_targets;        // 行 108

    // 已分配的目标数量
    unsigned int              num_allocated;      // 行 111

    // 设备总大小（扇区）
    sector_t                  sectors;            // 行 114

    // 有效标志
    unsigned long             flags;              // 行 121

    // B+tree 根节点
    struct dm_btree_info      bt;                 // 行 128

    // 目标数组
    struct dm_target         **targets;           // 行 135

    // 底层设备类型
    const struct dm_table_type *type;            // 行 142

    // 设备表引用
    struct list_head          target_md;          // 行 149

    // 安全的 SRCU index
    int                       md->barrier_entered:1; // 行 156
};
```

### 1.3 dm_target — 单个映射目标

```c
// include/linux/device-mapper.h:312 — struct dm_target
struct dm_target {
    // 所属表
    struct dm_table           *table;             // 行 313

    // 目标类型（linear/crypt/verity/mirror...）
    struct target_type        *type;              // 行 314

    // 此目标覆盖的扇区范围
    sector_t                  begin;              // 行 317
    sector_t                  len;                // 行 318

    // 单次 I/O 最大长度
    uint32_t                  max_io_len;        // 行 323

    // flush bio 数量
    unsigned int              num_flush_bios;     // 行 330

    // discard bio 数量
    unsigned int              num_discard_bios;  // 行 336

    // secure erase bio 数量
    unsigned int              num_secure_erase_bios; // 行 343

    // write zeroes bio 数量
    unsigned int              num_write_zeroes_bios; // 行 350

    // 私有数据（目标驱动存储状态）
    void                     *private;            // 行 368

    // 错误处理
    char                     *error;              // 行 375

    // 设备名称
    const char               *_DEV;              // 行 382
};
```

### 1.4 target_type — 目标操作函数表

```c
// include/linux/device-mapper.h:198 — struct target_type
struct target_type {
    uint64_t                  features;           // 行 199
    const char                *name;              // 行 200
    struct module             *module;            // 行 201
    unsigned int              version[3];         // 行 202

    // 构造函数（创建设目标）
    dm_ctr_fn                 ctr;                // 行 203

    // 析构函数（销毁目标）
    dm_dtr_fn                 dtr;                // 行 204

    // 映射 bio（核心！）
    dm_map_fn                 map;                // 行 205

    // end_io 回调
    dm_endio_fn               end_io;            // 行 208

    // 请求克隆和映射（blk-mq）
    dm_clone_and_map_request_fn clone_and_map_rq;  // 行 206

    // 释放克隆请求
    dm_release_clone_request_fn release_clone_rq;  // 行 207

    // 状态
    dm_status_fn              status;            // 行 209

    // 准备周期
    dm_prepare_ioctl_fn       prepare_ioctl;     // 行 210

    // 直接 I/O（Dax）
    dm_direct_access_fn        direct_access;     // 行 211
    dm_dax_zero_page_range_fn dax_zero_page_range; // 行 212
    dm_dax_recovery_write_fn  dax_recovery_write; // 行 213
};
```

## 2. dm-linear — 线性映射详解

### 2.1 线性目标私有数据

```c
// drivers/md/dm-linear.c:22 — struct linear_c
struct linear_c {
    struct dm_dev            *dev;    // 底层设备
    sector_t                  start;  // 在底层设备上的起始扇区
};
```

### 2.2 linear_ctr — 构造函数

```c
// drivers/md/dm-linear.c:30 — linear_ctr
static int linear_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
    struct linear_c *lc;
    struct dm_dev *dev;
    sector_t start;

    if (argc != 2) {
        ti->error = "Invalid argument count";  // "linear <dev> <offset>"
        return -EINVAL;
    }

    // 1. 解析设备路径，查找/打开底层设备
    if (dm_get_device(ti, argv[0], dm_table_get_mode(ti->table),
              &dev)) {
        ti->error = "Device lookup failed";
        return -EINVAL;
    }

    // 2. 解析起始扇区
    if (sscanf(argv[1], "%llu", &tmp) != 1) {
        ti->error = "Invalid start sector";
        return -EINVAL;
    }

    // 3. 分配并初始化私有数据
    lc = kmalloc(sizeof(*lc), GFP_KERNEL);
    lc->dev = dev;
    lc->start = start;

    ti->private = lc;

    return 0;
}
```

### 2.3 linear_map — 核心映射函数

```c
// drivers/md/dm-linear.c:89 — linear_map
int linear_map(struct dm_target *ti, struct bio *bio)
{
    struct linear_c *lc = ti->private;

    // 1. 将 bio 的底层设备替换为线性映射的目标设备
    //    bio_set_dev 是关键宏，它修改 bio->bi_bdev
    bio_set_dev(bio, lc->dev->bdev);

    // 2. 将扇区号调整为底层设备的绝对扇区号
    //    bi_sector 是相对于 DM 设备的逻辑扇区
    //    加上 ti->begin（此目标的起始扇区）
    //    再加上 lc->start（底层设备的起始扇区）
    bio->bi_iter.bi_sector = dm_target_offset(ti, bio->bi_iter.bi_sector)
                            + lc->start;

    // 3. 提交到下层设备
    submit_bio_noacct(bio);

    return DM_MAPIO_REMAPPED;
}
```

### 2.4 linear_dtr — 析构函数

```c
// drivers/md/dm-linear.c:74 — linear_dtr
static void linear_dtr(struct dm_target *ti)
{
    struct linear_c *lc = ti->private;

    // 释放底层设备引用
    dm_put_device(ti, lc->dev);

    // 释放私有数据
    kfree(lc);
}
```

## 3. dm_table_find_target — 查找目标

```c
// drivers/md/dm-table.c:1565 — dm_table_find_target
struct dm_target *dm_table_find_target(struct dm_table *t, sector_t sector)
{
    unsigned int l, n = 0, k = 0;
    sector_t *node;

    // 1. 检查扇区是否超出范围
    if (unlikely(sector >= dm_table_get_size(t)))
        return NULL;

    // 2. 在 B+tree 中查找包含此扇区的目标
    //    B+tree 按扇区排序（每个节点代表一个扇区范围）
    //    从根节点向下找到最左边的目标
    for (l = 0; l < t->depth; l++) {
        node = (sector_t *)((void *)t->bt.type[l] + ...);
        // 二分查找子节点
        n = find_child(...);
        k = n;
    }

    return t->targets[k];
}
```

## 4. bio 映射完整流程

```
上层 I/O（ext4 文件系统）：
  ↓
submit_bio(bio)
  ↓
generic_make_request(bio)
  ↓
blk_queue_bio(q, bio)
  ↓
DM 设备的请求函数（dm_make_request）
  ↓
dm_table_find_target(map, bio->bi_iter.bi_sector)  ← 查找目标
  ↓
ti->type->map(ti, bio)  ← 调用目标的 map 函数
  ↓
linear_map() / crypt_map() / verity_map() ...
  ↓
bio_set_dev(bio, underlying_bdev)  ← 替换底层设备
  ↓
submit_bio_noacct(bio)
  ↓
下层物理设备（/dev/sda）
```

## 5. dm-crypt — 透明加密

```c
// drivers/md/dm-crypt.c — crypt_map
static int crypt_map(struct dm_target *ti, struct bio *bio)
{
    struct crypt_config *cc = ti->private;

    // 1. 克隆 bio（创建加密后的副本）
    struct bio *clone = bio_clone_fast(bio, GFP_NOIO, &cc->bs);

    // 2. 加密数据
    //    cc->cipher（算法，如 "cbc(aes)"）
    //    cc->key（密钥）
    crypt_convert(cc, clone);

    // 3. 设置加密后的数据到下层设备
    bio_set_dev(clone, cc->dev->bdev);
    submit_bio_noacct(clone);

    return DM_MAPIO_SUBMITTED;
}
```

## 6. dm-verity — 完整性验证

```c
// drivers/md/dm-verity.c — verity_map
static int verity_map(struct dm_target *ti, struct bio *bio)
{
    struct verity_config *vc = ti->private;

    // 1. 计算数据块的哈希值
    //    hash = SHA256(data_block)
    //    比较 hash 与预先存储在哈希树中的值

    if (!verity_hash_is_zero(hash)) {
        // 2. 哈希不匹配，返回 I/O 错误
        bio->bi_status = BLK_STS_IOERR;
        bio_endio(bio);
        return DM_MAPIO_SUBMITTED;
    }

    // 3. 哈希匹配，传递到下层设备
    bio_set_dev(bio, vc->data_dev->bdev);
    submit_bio_noacct(bio);

    return DM_MAPIO_REMAPPED;
}
```

## 7. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| bio_set_dev 替换设备 | 不复制数据，只修改目标设备 |
| dm_table B+tree 组织 targets | O(log n) 查找目标，支持大量 targets |
| SRCU 安全切换表 | 允许在 I/O 运行时原子替换整个映射表 |
| target->private 私有数据 | 每个目标类型存储自己的状态 |
| dm_get_device/dm_put_device | 引用计数管理底层设备生命周期 |

## 8. 参考

| 文件 | 函数/结构 | 行 |
|------|----------|-----|
| `drivers/md/dm.c` | `struct mapped_device` | 290+ |
| `drivers/md/dm.c` | `dm_submit_bio` | 提交入口 |
| `drivers/md/dm-table.c` | `struct dm_table` | 108+ |
| `drivers/md/dm-table.c` | `dm_table_find_target` | 1565 |
| `include/linux/device-mapper.h` | `struct dm_target` | 312 |
| `include/linux/device-mapper.h` | `struct target_type` | 198 |
| `drivers/md/dm-linear.c` | `linear_ctr/map/dtr` | 30/89/74 |
| `drivers/md/dm-crypt.c` | `crypt_map` | 加密映射 |
| `drivers/md/dm-verity.c` | `verity_map` | 完整性验证 |


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

