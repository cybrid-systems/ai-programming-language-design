# device mapper — 逻辑卷管理深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/md/dm.c` + `include/linux/device-mapper.h`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Device Mapper（DM）** 是 Linux 的逻辑卷管理框架，是 LVM2、dm-crypt、RAID 的底层机制。核心概念：
- **target**：指定类型（如 linear、mirror、crypt）
- **table**：映射表（source → target）
- **device**：映射后的逻辑设备

---

## 1. 核心数据结构

### 1.1 mapped_device — 逻辑设备

```c
// drivers/md/dm.h — mapped_device
struct mapped_device {
    // 基础
    struct kobject           kobj;           // sysfs
    unsigned long            flags;          // DMF_* 标志
    unsigned int             type;           // 设备类型

    // 队列
    request_queue_t          *queue;         // 块设备请求队列
    struct bio_set           *io_pool;       // BIO 内存池
    struct bio_set           *bs;            // BIO set

    // DM 表
    struct dm_table          *map;           // 当前映射表

    // 活跃请求
    atomic_t                 pending;        // 待完成的请求数
    wait_queue_head_t       wait;           // 等待队列

    // 历史
    struct dm_stats          *stats;         // 统计

    // 内部设备
    struct gendisk           *disk;          // 通用磁盘

    // UUID/名称
    char                    *name;           // 设备名
    char                    *uuid;           // UUID
};
```

### 1.2 dm_table — 映射表

```c
// drivers/md/dm.h — dm_table
struct dm_table {
    unsigned int             type;           // DM_TYPE_* 类型

    // 目标数组
    unsigned int             num_targets;     // 目标数
    struct dm_target         **targets;      // 目标数组

    // 下层设备
    dev_t                    *devices_devid;  // 设备 ID
    unsigned int             num_devices;     // 设备数

    // 类型
    unsigned int             md_count;        // 引用计数
    void                    *tio_pool;       // target I/O 池
};
```

### 1.3 dm_target — 单个目标

```c
// drivers/md/dm.h — dm_target
struct dm_target {
    // 范围
    sector_t                 begin;          // 起始扇区
    sector_t                 len;           // 长度

    // 类型
    char                     *type;          // target 类型名（"linear" "crypt"）

    // 私有数据
    void                    *private;       // target 私有数据

    // 操作函数表
    struct dm_target_ops     *ops;          // 操作函数

    // 边界
    unsigned                 discards_supported:1;
    unsigned                 flush_supported:1;
    unsigned                 zero_supported:1;
};
```

### 1.4 dm_target_ops — 操作函数表

```c
// include/linux/device-mapper.h — dm_target_ops
struct dm_target_ops {
    // 构造函数
    int (*ctr)(struct dm_target *ti, unsigned int argc, char **argv);

    // 析构函数
    void (*dtr)(struct dm_target *ti);

    // 请求映射
    int (*map)(struct dm_target *ti, struct bio *bio);

    // 迭代器
    int (*iterate)(struct dm_target *ti, iterate_devices_fn *fn);

    // 边界
    void (*status)(struct dm_target *ti, status_type_t type, char *result, unsigned int maxlen);

    // 消息
    int (*message)(struct dm_target *ti, unsigned int argc, char **argv, char *result, unsigned int maxlen);

    // 合理大小
    void (*prepare_write_hints)(struct dm_target *ti, struct bio *bio);
};
```

---

## 2. 目标类型

### 2.1 linear — 线性映射

```c
// drivers/md/dm-linear.c — linear_ctr / linear_map
struct linear_c {
    struct block_device     *dev;          // 底层设备
    sector_t                 start;        // 起始偏移
};

static int linear_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
    // argv[0] = 设备路径（/dev/sda2）
    // argv[1] = 起始扇区

    struct linear_c *lc = kmalloc(sizeof(*lc), GFP_KERNEL);

    // 打开底层设备
    lc->dev = open_dev(argv[0]);
    lc->start = simple_strtoull(argv[1], NULL, 10);

    ti->private = lc;
    ti->len = ti->len;  // 扇区数

    return 0;
}

static int linear_map(struct dm_target *ti, struct bio *bio)
{
    struct linear_c *lc = ti->private;

    // 将 bio 转发到下层设备
    bio->bi_bdev = lc->dev;
    // 调整扇区偏移
    bio->bi_iter.bi_sector = bio->bi_iter.bi_sector + lc->start;

    return DM_MAPIO_REMAPPED;  // 已映射
}
```

### 2.2 crypt — 加密映射

```c
// drivers/md/dm-crypt.c — crypt_map
static int crypt_map(struct dm_target *ti, struct bio *bio)
{
    struct crypt_config *cc = ti->private;

    // 1. 读取 sector 获取 key
    sector_t sector = dm_target_offset(ti, bio->bi_iter.bi_sector);
    u8 *iv = crypt_iv(cc, sector);

    // 2. 加密/解密数据
    if (bio_data_dir(bio) == READ)
        crypt_decrypt(cc, bio, iv);
    else
        crypt_encrypt(cc, bio, iv);

    // 3. 映射到下层设备
    bio->bi_bdev = cc->dev;
    return DM_MAPIO_REMAPPED;
}
```

### 2.3 striped — RAID0 条带化

```c
// drivers/md/dm-stripe.c — stripe_map
static int stripe_map(struct dm_target *ti, struct bio *bio)
{
    struct stripe_c *sc = ti->private;

    // 计算条带编号
    // stripe = (sector >> stripe_shift) % nr_stripes
    sector_t sector = dm_target_offset(ti, bio->bi_iter.bi_sector);
    unsigned stripe = sector >> sc->stripe_shift;
    unsigned offset = sector & sc->stripe_mask;

    // 设置底层设备
    bio->bi_bdev = sc->dev[stripe];
    bio->bi_iter.bi_sector = offset + sc->stripe_offset[stripe];

    return DM_MAPIO_REMAPPED;
}
```

---

## 3. DM 创建流程

### 3.1 dmsetup create — 创建 DM 设备

```c
// dmsetup create <name> --table '<table>'
// 1. 解析 table：linear 0 1000000 /dev/sda2 0
// 2. 创建设备：ioctl(DM_DEV_CREATE)
// 3. 加载 table：ioctl(DM_TABLE_LOAD)

// 内核流程：
// dm_create() → 分配 mapped_device
// dm_table_add_target() → 添加 target
// dm_table_complete() → 完成 table
// dm_table_switch() → 切换到新 table
```

---

## 4. Bio 映射流程

```c
// drivers/md/dm.c — dm_make_request
static blk_qc_t dm_make_request(struct request_queue *q, struct bio *bio)
{
    struct mapped_device *md = q->queuedata;
    struct dm_table *table = dm_get_live_table(md);
    struct dm_target *ti;
    int run_io;

    // 1. 查找目标
    ti = dm_table_find_target(table, bio->bi_iter.bi_sector);

    // 2. 调用 target->map
    run_io = ti->ops->map(ti, bio);

    // 3. 处理结果
    if (run_io)
        generic_make_request(bio);  // 转发到下层设备

    return BLK_STS_OK;
}
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/md/dm.c` | `mapped_device`、`dm_make_request`、`dm_table` |
| `drivers/md/dm-linear.c` | `linear_ctr`、`linear_map` |
| `drivers/md/dm-crypt.c` | `crypt_map` |
| `include/linux/device-mapper.h` | `struct dm_target_ops` |