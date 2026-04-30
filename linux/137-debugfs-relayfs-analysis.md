# Linux Kernel debugfs / relayfs 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`fs/debugfs/` + `kernel/relay.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：debugfs_create_file、relay_open、ring buffer、ftrace

---

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

---

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

---

## 3. 参考

| 文件 | 函数 |
|------|------|
| `fs/debugfs/inode.c` | `debugfs_create_file` |
| `kernel/relay.c` | `relay_open`、`relay_write` |
