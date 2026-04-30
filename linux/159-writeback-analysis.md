# 159-writeback — 脏页回写深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/page-writeback.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**Writeback** 是 Linux 页缓存的回写机制：当内存中的页被标记为"脏"（修改过）时，writeback 线程定期将这些页写回磁盘。核心是 `pdflush/flush` 内核线程和 `bdi_writeback`。

---

## 1. 核心数据结构

### 1.1 struct backing_dev_info — BDI

```c
// include/linux/backing-dev.h — backing_dev_info
struct backing_dev_info {
    struct device           *dev;              // 设备

    // 回写线程
    struct bdi_writeback   *wb;               // 主回写线程

    // 能力
    unsigned long           capabilities;        // BDI_CAP_*

    // 脏页控制
    unsigned long           prev_dirty;         // 上次检测时的脏页数
    unsigned int            class_cookie;       // 类 cookie
};
```

### 1.2 struct bdi_writeback — 回写线程

```c
// include/linux/backing-dev.h — bdi_writeback
struct bdi_writeback {
    struct backing_dev_info  *bdi;              // 所属 BDI
    unsigned int            nr_pages;           // 本次回写页数
    unsigned long           last_old_flush;      // 上次刷新时间

    // 脏页链表
    struct list_head        b_dirty;           // 脏页链表
    struct list_head        b_io;              // 正在写的页
    struct list_head        b_more_io;          // 更多的 IO

    // 等待队列
    wait_queue_head_t       dwork->wait;       // 等待条件

    // 线程
    struct task_struct     *task;              // 回写线程
};
```

### 1.3 脏页链表

```
脏页链表结构：

bdi_writeback.b_dirty:
  [ dirty page ] → [ dirty page ] → [ dirty page ] → ...

bdi_writeback.b_io:
  [ being written ] → [ being written ] → ...

bdi_writeback.b_more_io:
  [ waiting for IO slot ] → ...
```

---

## 2. set_page_dirty — 标记脏

### 2.1 set_page_dirty

```c
// mm/page-writeback.c — set_page_dirty
int __set_page_dirty_nobuffers(struct page *page)
{
    // 1. 如果页不在页缓存，跳过
    if (!page->mapping)
        return 0;

    // 2. 如果已经是脏，跳过
    if (PageDirty(page))
        return 0;

    // 3. 标记为脏
    SetPageDirty(page);

    // 4. 加入回写队列
    radtree = mapping->i_pages;
    tag_pages_for_writeback(page);

    // 5. 触发回写线程
    if (bdi_cap_writeback_dirty(bdi))
        wb_wake_background(&bdi->wb);

    return 0;
}
```

---

## 3. writeback_sb_inodes — 扫描脏 inode

### 3.1 writeback_sb_inodes

```c
// mm/page-writeback.c — writeback_sb_inodes
static void writeback_sb_inodes(struct super_block *sb,
                                struct bdi_writeback *wb,
                                unsigned long nr_pages)
{
    struct inode *inode;

    // 遍历文件系统的 inode
    list_for_each_entry(inode, &sb->s_inodes, i_sb_list) {
        // 只处理脏 inode
        if (!inode->i_state & I_DIRTY_ALL)
            continue;

        // 如果有特殊标志，跳过
        if (inode->i_state & I_FREEING)
            continue;

        // 回写单个 inode 的脏页
        __writeback_single_inode(inode, wb);
    }
}
```

---

## 4. __writeback_single_inode — 单 inode 回写

### 4.1 __writeback_single_inode

```c
// mm/page-writeback.c — __writeback_single_inode
static int __writeback_single_inode(struct inode *inode,
                                    struct bdi_writeback *wb)
{
    int ret = 0;

    // 1. 获取写回控制
    struct writeback_control wbc = {
        .sync_mode = WB_SYNC_ALL,
        .nr_to_write = pages,
    };

    // 2. 调用文件系统的 write_inode
    if (inode->i_sb->s_op->write_inode)
        ret = inode->i_sb->s_op->write_inode(inode, &wbc);

    // 3. 如果是顺序文件，清理 I_DIRTY_PAGES
    if (ret == 0 && inode->i_state & I_DIRTY_PAGES)
        inode->i_state &= ~I_DIRTY_PAGES;

    return ret;
}
```

---

## 5. wb_writeback — 回写循环

### 5.1 wb_writeback

```c
// mm/page-writeback.c — wb_writeback
static long wb_writeback(struct bdi_writeback *wb, long nr_pages)
{
    struct writeback_control wbc = {
        .sync_mode = sync_mode,
        .pages = nr_pages,
    };

    // 遍历所有 super_block
    list_for_each_entry(sb, &super_blocks, s_list) {
        if (sb->s_bdi != wb->bdi)
            continue;

        // 回写
        writeback_sb_inodes(sb, wb, nr_pages);
    }
}
```

---

## 6. flush 线程

### 6.1 wb_wakeup_delayed — 唤醒 flush

```c
// mm/page-writeback.c — wb_wakeup_delayed
void wb_wakeup_delayed(struct bdi_writeback *wb)
{
    // 延迟唤醒 flush 线程
    // 等待 dirty_writeback_centisecs 秒后再唤醒
    mod_delayed_work(system_unbound_wq, &wb->dwork,
                     msecs_to_jiffies(delay));
}
```

### 6.3 flush 线程唤醒时机

```bash
# 触发回写的条件：
# 脏页超过 bdi->dirty_ratelimit 时
# dirty_writeback_centisecs 到期时（默认 500 centisecs = 5 秒）
# sync 系统调用时
# 内存压力时（write_inode 触发）
```

---

## 7. balance_dirty_pages — 脏页平衡

### 7.1 balance_dirty_pages

```c
// mm/page-writeback.c — balance_dirty_pages
void balance_dirty_pages(struct address_space *mapping)
{
    unsigned long nr_dirty = global_node_page_state(NR_FILE_DIRTY);
    unsigned long limit = dirty_threshold();

    // 如果脏页超过限制，阻塞等待回写
    while (nr_dirty > limit) {
        // 唤醒回写线程
        wakeup_flusher_threads();

        // 等待
        wait_event(kupdate_wait, !over_bground_thresh());

        nr_dirty = global_node_page_state(NR_FILE_DIRTY);
    }
}
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/page-writeback.c` | `set_page_dirty`、`writeback_sb_inodes`、`__writeback_single_inode`、`wb_writeback` |
| `mm/page-writeback.c` | `balance_dirty_pages`、`wb_wakeup_delayed` |
| `include/linux/backing-dev.h` | `struct backing_dev_info`、`struct bdi_writeback` |

---

## 9. 西游记类喻

**writeback** 就像"天庭的账本同步官"——

> 天庭的官员（CPU）在各自的营房里记账（修改内存页），但账本还在草稿纸上（脏页）。同步官（flush 线程）定期把草稿纸上的账目抄写到正式的账本（磁盘）。如果草稿纸太多（脏页过多），官员必须等同步官把一部分账目抄完才能继续记（balance_dirty_pages）。如果天庭突然要查账（sync），同步官会立即把所有草稿都抄一遍。同步官有条不紊地工作——先把草稿纸上的内容分组（b_dirty → b_io），一批一批地抄，写完一批再抄下一批。这就是为什么 Linux 在高并发写入时性能好——大部分写入都在内存中完成，不立即同步磁盘，同步官会在后台慢慢把数据写回去。

---

## 10. 关联文章

- **page_cache**（article 20）：writeback 基于页缓存
- **bio**（相关）：writeback 生成 bio 提交到块设备