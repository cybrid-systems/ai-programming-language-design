# Linux Kernel Device Mapper (DM) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/md/dm.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 Device Mapper？

**Device Mapper** 是 Linux 的**逻辑卷管理**框架，LVM2、dm-crypt、LUKS、dm-verity 都是基于 DM 实现。DM 在块设备层构建**转换层**，所有 I/O 请求经过映射规则处理后转发到下层设备。

---

## 1. 核心数据结构

### 1.1 mapped_device

```c
// drivers/md/dm.c — mapped_device
struct mapped_device {
    struct request_queue       *queue;         // DM 设备请求队列
    struct gendisk             *disk;          // DM 设备（/dev/dm-N）

    /* 软硬件目标表 */
    struct dm_table           *map;            // 当前活动的映射表

    /* 请求处理 */
    struct workqueue_struct   *wq;             // deferred I/O workqueue
    struct bio_set            bio_set;          // bio 池

    /* 锁 */
    struct mutex              suspend_lock;
    struct completion         *io_completion;

    /* 状态 */
    unsigned long             flags;
    #define DMF_SUSPENDED      0
    #define DMF_FROZEN         1
    #define DMF_FREEING        2
};
```

### 1.2 dm_table

```c
// drivers/md/dm-table.c — dm_table
struct dm_table {
    unsigned int            num_targets;       // 映射目标数量
    unsigned int            num_allocated;    // 已分配目标数
    sector_t                sectors;           // 设备总大小（扇区）
    sector_t                *bvec_align;       // 对齐要求

    /* 目标数组 */
    struct dm_target        **targets;

    /* 可见性掩码（读写）*/
    unsigned int             mode;

    /* 底层设备类型 */
    struct dm_table_type    *type;
};
```

### 1.3 dm_target

```c
// include/linux/device-mapper.h — dm_target
struct dm_target {
    struct dm_table         *table;           // 所属表
    char                    *type;            // 目标类型（如 "linear"、"crypt"）
    sector_t                begin;             // 此目标覆盖的起始扇区
    sector_t                len;               // 此目标覆盖的扇区数

    /* 目标私有数据 */
    void                    *private;

    /* 目标操作 */
    struct dm_target_operations *ops;

    /* 错误处理 */
    int                     (*error)(...);
};

// dm_target_operations
struct dm_target_operations {
    // 映射一个 bio
    int (*map)(struct dm_target *ti, struct bio *bio);
    // 创建目标
    int (*ctr)(struct dm_target *ti, unsigned int argc, char **argv);
    // 销毁目标
    void (*dtr)(struct dm_target *ti);
    // 状态
    int (*status)(...);
};
```

---

## 2. DM 目标类型

```
线性（linear）：        连续扇区映射到另一设备
镜像（mirror）：         RAID1，多路复制
条带（stripe）：        RAID0，条带化
crypt：                透明加密
verity：               dm-verity，只读验证
integrity：             数据完整性
thin：                 精简配置（Thin Provisioning）
snapshot：             COW 快照
multipath：            多路径 I/O
```

---

## 3. bio 映射流程

```
上层 I/O 请求（ext4 文件系统）：
  ↓
generic_make_request()
  ↓
dm_submit_bio()
  ↓
blk_queue_bio()
  ↓
dm_request_fn()  ← DM 设备请求函数
  ↓
dm_table_get_live_table()  ← 获取当前映射表
  ↓
dm_table_find_target()  ← 查找 bio 覆盖的 target
  ↓
target->ops->map()  ← 调用目标类型的 map 函数
  ↓
（目标内部处理，如线性映射：bi_bdev = linear->dev->bdev）
  ↓
submit_bio_noacct()
  ↓
下层块设备（如物理磁盘）
```

---

## 4. dm-linear — 线性映射

```c
// drivers/md/dm-linear.c — linear_ctr / linear_map
static int linear_map(struct dm_target *ti, struct bio *bio)
{
    struct linear_c *lc = ti->private;

    // 将 bio 的设备替换为底层设备
    bio_set_dev(bio, lc->dev->bdev);

    // 将扇区号偏移调整为底层设备的扇区号
    bio->bi_iter.bi_sector = dm_target_offset(ti, bio->bi_iter.bi_sector);

    // 提交到下层设备
    submit_bio_noacct(bio);
    return DM_MAPIO_REMAPPED;
}
```

---

## 5. 多路径（multipath）

```c
// drivers/md/dm-mpath.c
// 多路径 I/O：同一 LUN 有多个路径（多个 HBA）
static int multipath_map(struct dm_target *ti, struct bio *bio)
{
    struct multipath *m = ti->private;

    // 1. 选择路径（round-robin / least-queue / weighted）
    pgpath = select_path(m);

    // 2. 将 bio 路由到选定的路径
    bio_set_dev(bio, pgpath->path->dev->bdev);
    submit_bio_noacct(bio);

    return DM_MAPIO_REMAPPED;
}
```

---

## 6. dmsetup 命令

```c
// 创建线性映射
dmsetup create mylv --table "0 1024000 linear /dev/sda 2048"

// 创建镜像
dmsetup create mymirror --table "0 1024000 mirror core 2 8 nosync 0 /dev/sda 0 /dev/sdb 0"

// 查看状态
dmsetup status
dmsetup table
```

---

## 7. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| target 抽象层 | 所有 DM 设备类型（linear、mirror、crypt）都实现相同接口 |
| bio 替换 bi_bdev | 不复制数据，只修改请求目标 |
| dm_table 快照切换 | dm_switch_table 原子替换整个映射关系，无锁切换 |
| deferred I/O workqueue | 设备忙时缓存 I/O，避免阻塞上层 |

---

## 8. 参考

| 文件 | 内容 |
|------|------|
| `drivers/md/dm.c` | `mapped_device`、`dm_submit_bio`、`dm_request_fn` |
| `drivers/md/dm-table.c` | `dm_table`、`dm_table_find_target` |
| `include/linux/device-mapper.h` | `struct dm_target`、`dm_target_operations` |
| `drivers/md/dm-linear.c` | 线性映射实现 |
| `drivers/md/dm-mpath.c` | 多路径实现 |
