# Linux Kernel debugfs / relayfs 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/debugfs/` + `kernel/relay.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：debugfs_create_file、relay_open、ring buffer、ftrace

## 1. debugfs — 调试文件系统

### 1.1 创建调试文件

```c
// fs/debugfs/inode.c — debugfs_create_file
struct dentry *debugfs_create_file(const char *name, umode_t mode,
                  struct dentry *parent, void *data,
                  const struct file_operations *fops)
{
    // 1. 创建 dentry
    dentry = d_alloc_name(parent, name);

    // 2. 创建 inode
    inode = debugfs_get_inode(parent->d_sb);

    // 3. 设置文件操作
    inode->i_fop = &debugfs_file_operations;
    inode->i_private = data;  // 私有数据传给 fops

    // 4. 注册
    d_instantiate(dentry, inode);

    return dentry;
}
```

### 1.2 常用 API

```c
// 创建各种类型的文件
debugfs_create_file(name, mode, parent, data, &fops);
debugfs_create_u32(name, mode, parent, value_ptr);
debugfs_create_u64(name, mode, parent, value_ptr);
debugfs_create_bool(name, mode, parent, value_ptr);
debugfs_create_atomic_t(name, mode, parent, value_ptr);
debugfs_create_blob(name, mode, parent, blob);
```

## 2. relayfs — 内核到用户高速通道

### 2.1 relay_channel

```c
// kernel/relay.c — rchan
struct rchan {
    // 每 CPU 环形缓冲
    struct rchan_buf   *buf[NR_CPUS];  // 行 52

    // 每 CPU 缓冲大小
    size_t              alloc_size;     // 行 55

    // 子缓冲大小
    size_t              subbuf_size;    // 行 58

    // 子缓冲数量
    size_t              n_subbufs;      // 行 61

    // 消费位置
    size_t              consumed_bytes; // 行 64

    // 回调
    const struct rchan_callbacks *cb;  // 行 67

    // 用户空间可见
    struct dentry       *parent;         // 行 70
};
```

### 2.2 relay_open — 创建 channel

```c
// kernel/relay.c — relay_open
struct rchan *relay_open(const char *filename, struct dentry *parent,
                size_t subbuf_size, size_t n_subbufs, ...)
{
    // 1. 分配 rchan
    chan = kzalloc(sizeof(*chan), GFP_KERNEL);

    // 2. 为每个 CPU 分配环形缓冲
    for_each_possible_cpu(cpu) {
        chan->buf[cpu] = relay_create_buf(subbuf_size, n_subbufs);
    }

    // 3. 创建 debugfs 文件
    chan->parent = debugfs_create_file(filename, ..., chan);

    return chan;
}
```

### 2.3 relay_write — 写入数据

```c
// kernel/relay.c — relay_write
void relay_write(struct rchan *chan, const void *data, size_t count)
{
    struct rchan_buf *buf = chan->buf[get_cpu()];

    // 1. 检查空间
    if (buf->offset + count > subbuf_size) {
        // 子缓冲满，调用回调
        chan->cb->buf_end(buf);
        buf->offset = 0;
    }

    // 2. 复制数据
    memcpy(buf->data + buf->offset, data, count);
    buf->offset += count;

    put_cpu();
}
```

## 3. 参考

| 文件 | 函数 |
|------|------|
| `fs/debugfs/inode.c` | `debugfs_create_file` |
| `kernel/relay.c` | `relay_open`、`relay_write` |


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

