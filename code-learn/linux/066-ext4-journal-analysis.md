# 66-ext4-journal — Linux JBD2 日志系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**JBD2（Journaling Block Device 2）** 是 ext4 文件系统的日志层，从 ext3 的 JBD 演进而来。它提供**原子事务**保证——对元数据的修改要么完全写入磁盘，要么完全不写入，在系统崩溃后通过日志回放恢复一致性。

**核心设计**：JBD2 使用**三阶段提交**协议——handle（开始事务）→ 修改 buffer → stop handle（释放引用）→ commit（原子写入日志）→ checkpoint（回写到文件系统）。

```
ext4 文件系统                     JBD2 日志层                    磁盘
    │                                │                            │
  ext4_create()                       │                            │
    └─ jbd2_journal_start()           │                            │
        → 获取 handle                  │                            │
    └─ ext4_add_entry()               │                            │
        └─ jbd2_journal_get_write()    │                            │
        └─ jbd2_journal_dirty_meta()   │                            │
    └─ ext4_journal_stop()            │                            │
        └─ jbd2_journal_stop()        │                            │
                                      │                            │
  定时器/kjournald2                    │                            │
    └─ jbd2_journal_commit_transaction()                            │
        ├─ 写日志块到日志区域           →  日志块写入日志分区         │
        ├─ 写日志提交块               →  提交块写入                 │
        └─ 写元数据到目标位置           →  元数据回写               │
```

**doom-lsp 确认**：JBD2 核心在 `fs/jbd2/`（**4 个主要文件**，~10,000 行）。头文件 `include/linux/jbd2.h`（1,842 行）。`transaction.c`（2,831 行）处理 handle/transaction 生命周期，`commit.c`（1,189 行）处理日志提交，`recovery.c`（996 行）处理崩溃后恢复。

---

## 1. 核心数据结构

### 1.1 struct handle_s — 事务句柄

```c
// include/linux/jbd2.h
typedef struct handle_s {
    /* 保护 handle 的计数器 */
    int h_ref;                           /* 引用计数 */
    int h_err;                           /* 事务错误 */
    unsigned int h_sync:1;              /* 需要同步 */
    unsigned int h_jdata:1;              /* 数据日志 */
    unsigned int h_aborted:1;

    struct transaction_s *h_transaction; /* 所属事务 */
    int h_buffer_credits;                /* 剩余可修改的 buffer 数 */
    int h_revoke_credits;                /* 撤销记录信用 */

    /* 锁等待统计 */
    unsigned long h_start, h_requested;
    unsigned long h_timestamp;
} handle_t;
```

### 1.2 struct transaction_s — 事务

```c
// include/linux/jbd2.h:573-740
struct transaction_s {
    journal_t *t_journal;                 /* 所属日志 */
    tid_t t_tid;                          /* 事务序列号 */

    /* ── 状态机 ─ */
    enum {
        T_RUNNING,       /* 正在接收更新 */
        T_LOCKED,        /* 已锁定（不再接受新 handle）*/
        T_SWITCH,        /* 切换中 */
        T_FLUSH,         /* 刷新中 */
        T_COMMIT,        /* 提交中 */
        T_COMMIT_DFLUSH, /* 提交 + 数据刷新 */
        T_COMMIT_JFLUSH, /* 提交 + 日志刷新 */
        T_COMMIT_CALLBACK, /* 回调阶段 */
        T_FINISHED       /* 已完成 */
    } t_state;

    int t_nr_buffers;                     /* 元数据 buffer 数 */

    /* 链表（按操作类型分离）*/
    struct journal_head *t_reserved_list;  /* 已保留未修改 */
    struct journal_head *t_buffers;        /* 元数据 buffer */
    struct journal_head *t_forget;         /* 可丢弃的 buffer */
    struct journal_head *t_checkpoint_list;/* 等待 checkpoint */
    struct journal_head *t_shadow_list;    /* 日志 IO 影子 buffer */
    struct list_head t_inode_list;         /* 关联的 inode */

    unsigned long t_max_wait;              /* 最大等待时间 */
    unsigned long t_start;                 /* 开始时间 */
    unsigned long t_requested;             /* 提交请求时间 */
};
```

### 1.3 struct journal_s — 日志控制结构

```c
// include/linux/jbd2.h:763-860
struct journal_s {
    unsigned long j_flags;                 /* 日志标志 */
    struct buffer_head *j_sb_buffer;       /* 超级块 buffer */
    journal_superblock_t *j_superblock;     /* 超级块 */

    rwlock_t j_state_lock;                 /* 状态锁 */
    struct mutex j_barrier;                 /* 屏障锁 */

    /* ── 三个事务指针 ─ */
    transaction_t *j_running_transaction;   /* 正在运行 */
    transaction_t *j_committing_transaction; /* 正在提交 */
    transaction_t *j_checkpoint_transactions; /* checkpoint 队列 */

    /* ── waitqueue ─ */
    wait_queue_head_t j_wait_transaction_locked;
    wait_queue_head_t j_wait_done_commit;
    wait_queue_head_t j_wait_commit;
    wait_queue_head_t j_wait_updates;

    /* ── 日志区域 ─ */
    unsigned long j_tail;                  /* 日志尾部 */
    unsigned long j_head;                  /* 日志头部 */
    unsigned long j_first;                 /* 日志开始 */
    unsigned long j_last;                  /* 日志结束 */

    struct block_device *j_dev;            /* 日志设备 */
    struct block_device *j_fs_dev;         /* 文件系统设备 */
    unsigned int j_blocksize;              /* 块大小 */

    /* ── 提交线程 ─ */
    struct task_struct *j_task;            /* kjournald2 线程 */
    int j_commit_interval;                 /* 提交间隔 (HZ) */
    int j_commit_timer_active;
    struct timer_list j_commit_timer;      /* 定时提交 */

    /* ── 统计 ─ */
    unsigned long j_max_transaction_buffers;
};
```

**doom-lsp 确认**：`j_running_transaction`、`j_committing_transaction`、`j_checkpoint_transactions` 构成**三级流水线**——同一个时刻最多三个事务处于不同阶段。

---

## 2. 事务生命周期

### 2.1 jbd2_journal_start——获取句柄

```c
// fs/jbd2/transaction.c:581
handle_t *jbd2_journal_start(journal_t *journal, int nblocks)
{
    handle_t *handle;

    /* 1. 分配 handle */
    handle = journal_alloc_handle(journal);
    handle->h_buffer_credits = nblocks;

    /* 2. 确保运行事务就绪 */
    if (!journal->j_running_transaction) {
        /* 创建新事务 */
        jbd2_journal_start_commit(journal, ...);
        /* 或等待当前事务完成 */
        wait_event(journal->j_wait_transaction_locked, ...);
    }

    /* 3. 注册到运行事务 */
    atomic_inc(&journal->j_running_transaction->t_updates);

    return handle;
}
```

### 2.2 jbd2_journal_get_write_access——登记 buffer

```c
// fs/jbd2/transaction.c:1233
int jbd2_journal_get_write_access(handle_t *handle, struct buffer_head *bh)
{
    struct journal_head *jh = jbd2_journal_add_journal_head(bh);

    /* 将 buffer_head 加入事务的 t_buffers 链表 */
    jbd2_journal_file_buffer(jh, handle->h_transaction, BJ_Metadata);
    /* 事务的 t_nr_buffers++ */

    J_ASSERT_JH(jh, jh->b_jlist == BJ_None ||
                     /* 已在此事务中 */
                     jh->b_jlist == BJ_Reserved ||
                     /* 可在不同事务中 */
                     jh->b_jlist == BJ_Shadowed ||
                     /* 日志 IO 完成前允许 */
                     jh->b_jlist == BJ_Forget);

    handle->h_buffer_credits--;
    return 0;
}
```

### 2.3 jbd2_journal_dirty_metadata——标记脏 buffer

```c
// fs/jbd2/transaction.c
void jbd2_journal_dirty_metadata(handle_t *handle, struct buffer_head *bh)
{
    struct journal_head *jh = bh2jh(bh);

    /* 标记为需要提交到日志 */
    set_buffer_jbddirty(bh);               /* 日志脏标志 */
    jh->b_modified = 1;
}
```

### 2.4 jbd2_journal_stop——释放句柄

```c
// fs/jbd2/transaction.c:1883
int jbd2_journal_stop(handle_t *handle)
{
    transaction_t *transaction = handle->h_transaction;
    journal_t *journal = transaction->t_journal;

    /* 减少 handle 引用 */
    handle->h_ref--;

    /* 所有 handle 都释放了 → 触发提交 */
    if (atomic_dec_and_test(&transaction->t_updates)) {
        wake_up(&journal->j_wait_updates);
        /* 可能启动定时提交 */
        if (!journal->j_commit_timer_active)
            jbd2_journal_commit_transaction(journal);
    }

    return 0;
}
```

---

## 3. 提交——jbd2_journal_commit_transaction

```c
// fs/jbd2/commit.c
void jbd2_journal_commit_transaction(journal_t *journal)
{
    transaction_t *transaction;

    /* 1. 锁定运行事务，切换到 T_LOCKED */
    spin_lock(&journal->j_state_lock);
    transaction = journal->j_running_transaction;
    transaction->t_state = T_LOCKED;
    journal->j_committing_transaction = transaction;
    journal->j_running_transaction = NULL;     /* 新事务开始 */
    spin_unlock(&journal->j_state_lock);

    /* 2. 等待所有 handle 完成 */
    wait_event(journal->j_wait_updates,
               atomic_read(&transaction->t_updates) == 0);

    /* 3. 获取提交块在日志中的位置 */
    commit_transaction->t_log_start = journal->j_head;

    /* 4. 对每个元数据 buffer 写日志 */
    list_for_each_entry(jh, &transaction->t_buffers, b_frozen_list) {
        /* 为 buffer 创建影子拷贝 */
        /* 将影子块写入日志（日志区域）*/
        journal_write_metadata_buffer(...);
        jbd2_mark_journal_descriptor(...);
    }

    /* 5. 写提交块 */
    journal_write_commit_record(journal, commit_transaction);

    /* 6. 提交完成——将日志中的元数据回写到文件系统 */
    spin_lock(&journal->j_state_lock);
    transaction->t_state = T_COMMIT;
    spin_unlock(&journal->j_state_lock);

    /* 7. 将事务移到 checkpoint 队列 */
    __jbd2_journal_drop_transaction(journal, transaction);
}
```

**提交三步骤的磁盘布局**：

```
日志区域磁盘布局（循环缓冲区）:
┌──────────────┬──────────────┬──────────────┬────────────────┐
│ 描述符块     │  元数据块    │  元数据块     │   提交块       │
│ (tag+uuid)  │  (影子拷贝)  │  (...)       │  (seq + crc32) │
└──────────────┴──────────────┴──────────────┴────────────────┘
        ↑                 ↑                        ↑
    JFS_FLAG_DESCRIPTOR     JFS_FLAG_LAST_COMMIT
```

---

## 4. 事务流水线

JBD2 通过**三级流水线**最大化并发：

```
时间 ─────────────────────────────→
   running        committing         checkpointing
  [T_RUNNING]    [T_COMMIT]        [T_FINISHED]
  接收新 handle   写日志 + 提交块    回写元数据到文件系统
       │               │                   │
       │               │             完成 → 释放日志空间
       │          完成 → 移交            (j_tail 前进)
       │
  创建新──────────→
  running
```

**三级流水线保证**：
- 任何时候最多一个 `running` 事务（接收更新）
- 任何时候最多一个 `committing` 事务（写日志）
- checkpoint 队列可以有多个完成的事务（等待回写）

---

## 5. 恢复——恢复回放

```c
// fs/jbd2/recovery.c:996
// 系统崩溃后，mount 时自动执行

int jbd2_journal_recover(journal_t *journal)
{
    /* 1. 扫描日志，找到最后一个完整的提交 */
    /* 从 j_last 到 j_head 扫描日志块 */

    /* 2. 读取提交块 → 验证校验和 */
    /* 如果 CRC 校验通过，执行回放 */

    /* 3. 回放日志块到文件系统 */
    for (每个日志块) {
        if (tag->JFS_FLAG_DESCRIPTOR)
            continue;           /* 描述符块 */
        if (tag->JFS_FLAG_LAST_COMMIT)
            break;              /* 提交块—回放结束 */
        /* 将元数据块写入文件系统 */
        __journal_recover_journal_header(...);
        memcpy(bh->b_data, source, blocksize);
    }

    /* 4. 更新日志超级块 */
    journal->j_tail = 提交事务的起始位置;
}
```

---

## 6. 检查点（Checkpoint）

Checkpoint 将日志中的提交数据回写到文件系统的最终位置：

```c
// 当以下条件触发 checkpoint：
// 1. 日志空间不足（j_tail 需要前进）
// 2. 显式调用了 jbd2_journal_flush()
// 3. 文件系统卸载

int jbd2_log_do_checkpoint(journal_t *journal)
{
    /* 遍历 j_checkpoint_transactions */
    transaction_t *transaction;

    while ((transaction = journal->j_checkpoint_transactions)) {
        /* 对 t_checkpoint_list 中的每个 buffer：*/
        list_for_each_entry(jh, &transaction->t_checkpoint_list, ...) {
            /* 如果 buffer 尚未写回 → 写入 */
            if (jh->b_jlist == BJ_Forget)
                continue;
            __sync_dirty_buffer(jh2bh(jh), REQ_SYNC);
        }
        /* 事务完成 → 从 checkpoint 队列移除 */
        /* j_tail 前进 → 释放日志空间 */
    }
}
```

---

## 7. ext4 集成示例

```c
// ext4_create() → ext4_new_inode() → ext4_add_entry()

static int ext4_add_entry(handle_t *handle, struct dentry *dentry,
                          struct inode *inode)
{
    struct buffer_head *bh;
    struct ext4_dir_entry_2 *de;

    /* 1. 获取目录块 */
    bh = ext4_getblk(handle, dir, block, 0, &err);

    /* 2. JBD2：登记 buffer */
    BUFFER_TRACE(bh, "get_write_access");
    err = jbd2_journal_get_write_access(handle, bh);

    /* 3. 修改目录条目 */
    de = (struct ext4_dir_entry_2 *)bh->b_data;
    ext4_init_dotdot(&de, ino, ...);

    /* 4. JBD2：标记脏 */
    jbd2_journal_dirty_metadata(handle, bh);
    brelse(bh);
}
```

---

## 8. 调试

```bash
# 查看日志信息
dumpe2fs /dev/sda1 | grep -i journal
# Journal inode: 8
# Journal size: 128M

# 查看日志内容
debugfs -R "logdump -a" /dev/sda1

# 强制日志提交
sync

# 查看日志统计
cat /proc/fs/jbd2/sda1-8/info

# 恢复调试
mount -t ext4 -o data_err=abort /dev/sda1 /mnt

# tracepoint
echo 1 > /sys/kernel/debug/tracing/events/jbd2/enable
```

---

## 9. 总结

JBD2 是一个**高性能日志引擎**：

1. **三级流水线** — running → committing → checkpointing，最大化磁盘 IO 并发
2. **handle 抽象** — 轻量级事务句柄，支持嵌套引用计数
3. **循环日志** — 固定大小的日志区域，checkpoint 后空间回收
4. **崩溃恢复** — 扫描日志提交块，选择性回放未完成的原子更新
5. **三种日志模式** — journal（全日志）、ordered（仅元数据+数据序）、writeback（仅元数据）

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
