# Linux Kernel ext4 Journal / fsync 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/ext4/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. ext4 日志机制

ext4 使用 **JBD2（Journaling Block Device 2）** 实现日志：
- **writeback 模式**：只记录元数据操作
- **ordered 模式**（默认）：数据先落盘，再写日志
- **journal 模式**：所有操作都记录日志

---

## 1. JBD2 日志

```c
// fs/jbd2/journal.c — journal_start
handle_t *journal_start(struct super_block *sb, int nblocks)
{
    // 1. 获取日志锁
    transaction *journal->j_running_transaction;

    // 2. 分配 handle（轻量级事务）
    handle_t *handle = kmalloc(sizeof(*handle), ...);
    handle->h_transaction = journal->j_running_transaction;
    handle->h_ref++;

    // 3. 预留 nblocks 个日志块
    jbd2_journal_grab_journal_head();

    return handle;
}

// fs/jbd2/transaction.c — journal_stop
void journal_stop(handle_t *handle)
{
    // 4. 提交事务
    jbd2_journal_end_transaction(handle);
}
```

---

## 2. fsync — 保证数据落盘

```c
// fs/ext4/sync.c — ext4_sync_file
int ext4_sync_file(struct file *file, loff_t start, loff_t end, int datasync)
{
    // 1. 写回所有 dirty inode
    filemap_write_and_wait_range(inode->i_mapping);

    // 2. 提交 inode 相关的日志
    jbd2_log_force_commit(inode->i_sb);

    // 3. 如果是 data=journal 模式，同步数据日志
    //    jbd2_submit_inode_data();

    return 0;
}
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `fs/jbd2/journal.c` | JBD2 日志核心 |
| `fs/jbd2/transaction.c` | 事务提交 |
| `fs/ext4/super.c` | ext4 日志初始化 |
| `fs/ext4/sync.c` | `ext4_sync_file` |
