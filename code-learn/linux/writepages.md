# writepages 路径中的关键函数与潜在耗时点

## 调用主干
```
do_writepages
 ├─ ext4_writepages                 (ext4 文件)
 │   ├─ mpage_prepare_extent_to_map
 │   ├─ mpage_map_and_submit_extent
 │   │   ├─ mpage_map_one_extent -> ext4_map_blocks (最重)
 │   │   └─ mpage_map_and_submit_buffers -> mpage_submit_page
 │   │        └─ ext4_bio_write_page -> ext4_io_submit -> submit_bio
 │   └─ __ext4_journal_start/stop
 └─ blkdev_writepages (块设备/BDEV)
     └─ generic_writepages -> write_cache_pages
         └─ __writepage -> blkdev_writepage
             └─ block_write_full_page -> submit_bh_wbc -> submit_bio
```

## 耗时可能较长的点（按实测排序）

**1. 块分配类（最重，几十~百微秒级）**
- `ext4_map_blocks` / `ext4_ext_map_blocks` — trace 中约 **119–138 µs**，是单次 map 的绝对大头
- `ext4_mb_new_blocks` — 约 **64–72 µs**
  - `ext4_mb_regular_allocator` ~27–47 µs
  - `ext4_mb_mark_diskspace_used` ~17–30 µs（含读写 bitmap、日志写访问、csum）
  - `ext4_mb_prefetch` ~13 µs（循环 `ext4_get_group_desc`，长循环时放大）
- `ext4_ext_insert_extent` ~13–30 µs（含 `__ext4_mark_inode_dirty`）

**2. 日志/事务（jbd2）**
- `__ext4_journal_start_sb` → `jbd2__journal_start` 可达 **~35 µs**（一次 `kmem_cache_alloc` 就有 11.5 µs，还夹了一次 GIC IPI 中断）
- 频繁的 `jbd2_journal_get_write_access` / `dirty_metadata`，单次几 µs，但调用次数多

**3. inode 更新**
- `ext4_mark_iloc_dirty` → `ext4_do_update_inode` → `ext4_fill_raw_inode`
- 内含 `crypto_shash_update`（csum）多次，单次 ~20–40 µs

**4. 提交流程（每页都会走）**
- `ext4_bio_write_page` ~24 µs，`mpage_submit_page` ~30 µs
- `submit_bio` → `dm_submit_bio` → `blk_mq_submit_bio`，单页约 **30–60 µs**
- `blk_finish_plug` → `blk_mq_flush_plug_list` 约 49 µs（含调度/下发）

**5. generic_writepages 路径**
- `write_cache_pages` 整体约 **422 µs**（含多个页的 `__writepage`）
- 其中 `blk_finish_plug` / `blk_mq_submit_bio` 各 ~50 µs 级别

## 结论
最值得关注的是 **`ext4_ext_map_blocks` + `ext4_mb_*`**（块分配）和 **`__ext4_journal_start_sb` + inode dirty**（事务），它们占 `mpage_map_and_submit_extent`（**~240 µs**）的绝大部分；顶层 `do_writepages` 总计约 **370–430 µs**。IO 提交（`submit_bio`/`dm`/`blk_mq`）单页也在数十 µs，页数多时会线性累加。


## `ext4_writepages()` 流程详解

## 一、整体结构

函数是 ext4 在 **delalloc（延迟分配）** 模式下的核心回写函数，负责把脏页映射到磁盘块并提交 IO。与之并列的还有 `generic_writepages`（journal 模式）和 `blkdev_writepages`（块设备）。整体分为三段：

```
[前置检查与准备]  →  [retry 主循环（扫描页/extent → 映射 → 提交 IO）]  →  [收尾/更新索引]
```

---

## 二、前置阶段

### 1. 快速退出条件
```c
if (!mapping->nrpages || !mapping_tagged(mapping, PAGECACHE_TAG_DIRTY))
    goto out_writepages;
```
dirty 页都没有，直接返回。**典型场景**: `journal inode` 在最后一次 iput 被调用，避免逆序启动事务。

### 2. 分支处理
- `ext4_should_journal_data(inode)` → 转 `generic_writepages`（journal 数据模式不支持 delalloc）
- `ext4_forced_shutdown` / `EXT4_MF_FS_ABORTED` → 返回 `-EROFS`
- `ext4_has_inline_data(inode)` → 先启动一个 inode 事务，调 `ext4_destroy_inline_data`，把 inline data 转成常规 extent 形式（**只改 inode**，所以只需 1 个 credit）

### 3. 预留块与扫描范围
```c
if (ext4_should_dioread_nolock(inode))
    rsv_blocks = 1 + ext4_chunk_trans_blocks(inode, PAGE_SIZE >> i_blkbits);
```
- `dioread_nolock` 下需要为 extent 转换**预留块**（unwritten → written），防止事务里没块可用
- 确定 `first_page / last_page`：
  - `range_cyclic`: 从 `mapping->writeback_index` 开始，绕回 -1 → 环形扫描
  - 否则用 `wbc->range_start/range_end` 直接换算

`cycled` 标记是否已经绕回起点；`mpd` 是核心状态结构，`ext4_io_submit_init` 初始化 bio 提交状态。

---

## 三、`retry:` 主循环 —— 核心

### 阶段 A：先写“不需要映射”的页（do_map = 0）

```c
mpd.do_map = 0;
mpd.io_submit.io_end = ext4_init_io_end(inode, GFP_KERNEL);
ret = mpage_prepare_extent_to_map(&mpd);
mpage_release_unused_pages(&mpd, false);
ext4_io_submit(&mpd.io_submit);
ext4_put_io_end_defer(mpd.io_submit.io_end);
```

目的（注释说明）：
1. **避免不必要地启动事务** —— 已经映射过的 extent 页可以直接写
2. **避免持事务时在块层拥塞上被阻塞**

只做一轮就结束，这是“热身”阶段。`ext4_put_io_end_defer` 表示此 io_end 无事务保护，但用 deferred 方式释放以防最后一个引用触发 extent 转换。

### 阶段 B：`while` 循环处理需要映射的 delalloc extent

每次迭代对应**一个 extent**：

```c
mpd.io_submit.io_end = ext4_init_io_end(...);
needed_blocks = ext4_da_writepages_trans_blocks(inode);
handle = ext4_journal_start_with_reserve(inode, EXT4_HT_WRITE_PAGE,
                                         needed_blocks, rsv_blocks);
mpd.do_map = 1;

ret = mpage_prepare_extent_to_map(&mpd);      // 扫描脏页，算出 map.m_lblk/m_len
if (!ret && mpd.map.m_len)
    ret = mpage_map_and_submit_extent(handle, &mpd, &give_up_on_write);
```

**关键点：**

| 函数 | 作用 |
|------|------|
| `ext4_da_writepages_trans_blocks` | 根据 inode 状态算本次事务所需 block credits |
| `ext4_journal_start_with_reserve` | 开 jbd2 事务，带 extent 转换预留 |
| `mpage_prepare_extent_to_map` | 用 `pagevec_lookup_range_tag` 收集连续脏页，计算要映射的连续区间 `mpd.map` |
| `mpage_map_and_submit_extent` | **最重**：`ext4_map_blocks` 分配块 + `mpage_map_and_submit_buffers` 提交 IO |

`give_up_on_write` 使后续 `mpage_release_unused_pages` 时对未用页解锁并**清脏**（放弃），而不是保留。

### 事务收尾的顺序讲究（重要注释）

```c
if (!ext4_handle_valid(handle) || handle->h_sync == 0) {
    ext4_journal_stop(handle);
    handle = NULL;
    mpd.do_map = 0;
}
mpage_release_unused_pages(&mpd, give_up_on_write);
ext4_io_submit(&mpd.io_submit);
```
- **同步事务**（`h_sync`）不能在这里 stop：`ext4_journal_stop` 可能等事务 commit，而 commit 又依赖这些页回写完成/锁释放 → **死锁**
- 所以：先 stop 非同步事务；否则把 `ext4_put_io_end_defer` + `ext4_journal_stop` 放到 IO 提交、页解锁之后

```c
if (handle) {
    ext4_put_io_end_defer(mpd.io_submit.io_end);
    ext4_journal_stop(handle);
} else
    ext4_put_io_end(mpd.io_submit.io_end);
```
- 持事务时用 **deferred**：避免最后一个 io_end 引用在持事务时触发 extent 转换
- 不持事务时可直接 `ext4_put_io_end`

### 错误处理

- `-ENOSPC && s_journal`: 强制嵌套 commit 释放块，`ret=0; continue;` 重试
- 其他错误（ENOMEM/EIO）：`break` 退出循环

`ext4_put_io_end`/`ext4_release_io_end` 中的 `kmem_cache_free` 在 trace 里出现过 6 µs 的抖动。

---

## 四、收尾阶段

### 1. 环形扫描回绕
```c
if (!ret && !cycled && wbc->nr_to_write > 0) {
    cycled = 1;
    mpd.last_page = writeback_index - 1;
    mpd.first_page = 0;
    goto retry;
}
```
cyclic 模式下若从中间开始扫描、还没写完且还有配额，就从 0 到 `writeback_index-1` 补扫一轮（最多一次，由 `cycled` 保证）。

### 2. 更新 `writeback_index`
```c
if (wbc->range_cyclic || (range_whole && wbc->nr_to_write > 0))
    mapping->writeback_index = mpd.first_page;
```
记录下次 cyclic 回写的起点。

### 3. 全局锁与 trace
```c
percpu_up_read(&sbi->s_writepages_rwsem);
```
`percpu_down_read` 允许多 CPU 并行 writepages，但会与需要独占的操作（如 resize/remount）互斥。

---

## 五、与 trace 的对应关系

以实测 trace 为例（一次顶层 `do_writepages` ~386 µs）：

```
ext4_writepages
├─ 阶段A（do_map=0）: mpage_prepare_extent_to_map / mpage_release_unused_pages
│                     ext4_io_submit / ext4_put_io_end_defer
├─ while 第1轮:
│   ├─ __ext4_journal_start_sb (jbd2__journal_start)   ← 事务启动 ~35µs
│   ├─ mpage_prepare_extent_to_map
│   ├─ mpage_map_and_submit_extent                     ← ! 240µs，绝对大头
│   │   ├─ mpage_map_one_extent → ext4_map_blocks       ← ! 138µs
│   │   │   └─ ext4_ext_map_blocks → ext4_mb_new_blocks ← ! 64µs
│   │   │       ├─ ext4_mb_regular_allocator            ~27µs
│   │   │       └─ ext4_mb_mark_diskspace_used          ~30µs
│   │   ├─ mpage_map_and_submit_buffers                 ~35µs
│   │   │   └─ mpage_submit_page → ext4_bio_write_page  ~31µs
│   │   └─ __ext4_mark_inode_dirty                      ~42µs
│   ├─ __ext4_journal_stop                              ~2µs
│   └─ ext4_io_submit → submit_bio                      ~63µs
└─ blk_finish_plug
```

**耗时热点排序**：块分配（`ext4_map_blocks`/`ext4_mb_*`）> IO 提交（`submit_bio`+dm+blk_mq）> inode dirty/csum > 事务启动。

---

## 六、设计要点小结

1. **两段式写回**：先写已映射页（无事务），再循环处理 delalloc extent（有事务）——降低锁持有时间与拥塞风险。
2. **每 extent 一个事务 + 一个 io_end**：粒度便于 `-ENOSPC` 回退和 extent 转换预留。
3. **同步事务的 stop 顺序**：必须以“先提交 IO、解锁页、放 io_end”破环，否则死锁。
4. **dioread_nolock 预留块**：保证事务内不需要现分配转换所需的块。
5. **cyclic 回绕 + writeback_index**：避免大文件 dirty 时刚扫过的部分被饿死（公平性）。
6. **`mpd.do_map` 开关**：同一套 `mpage_prepare_extent_to_map` 复用于“只收集已映射页”和“收集并待映射页”两种模式。
