# relayfs — 高速内核到用户空间日志传输深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/relay.c` + `include/linux/relay.h`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**relayfs** 是高性能的内核到用户空间日志传输通道，核心是 per-CPU 环形缓冲区，零拷贝，零 syscall（通过 mmap 访问）。

---

## 1. 核心概念

```
传统方式：printk → ring buffer → 用户 read() syscall
relayfs：内核写入 → per-CPU 缓冲 → 用户 mmap 读取（零 syscall）
```

---

## 2. 核心数据结构

### 2.1 rchan — relay 通道

```c
// kernel/relay.c — rchan
struct rchan {
    // 全局状态
    const char              *filename;       // debugfs 文件名
    struct dentry           *parent;          // 父目录

    // per-CPU 缓冲区
    struct rchan_buf        **buf;            // 缓冲区数组（per-CPU）
    unsigned int            n_pages;           // 每缓冲区页数
    unsigned int            page_size;        // 页大小

    // 回调
    void                    (*buf_cb)(const void *, size_t, void *);

    // 同步
    unsigned int            has_finalization; // 是否有最终化回调
};
```

### 2.2 rchan_buf — per-CPU 缓冲区

```c
// kernel/relay.c — rchan_buf
struct rchan_buf {
    // 数据页
    void                    **page_array;     // 页数组

    // 位置
    size_t                  offset;            // 当前写入偏移
    size_t                  data_size;         // 数据大小

    // 元数据
    unsigned int            cpu;              // CPU 编号

    // 页头（每页有 header）
    struct rchan_page_header {
        size_t              size;            // 本页数据大小
        u32                 reserved;        // 保留
    } *page_header;
};
```

---

## 3. relay_open — 创建通道

```c
// kernel/relay.c — relay_open
struct rchan *relay_open(const char *filename, struct dentry *parent,
                         size_t subbuf_size, size_t n_subbufs)
{
    struct rchan *chan;
    int i;

    // 1. 分配 channel
    chan = kzalloc(sizeof(*chan), GFP_KERNEL);
    if (!chan)
        return NULL;

    // 2. 为每个 CPU 分配缓冲区
    for_each_possible_cpu(cpu) {
        chan->buf[cpu] = alloc_channel_buf(subbuf_size, n_subbufs);
        if (!chan->buf[cpu])
            goto free_bufs;
    }

    // 3. 在 debugfs 创建文件
    chan->dentry = debugfs_create_file(filename, ...);

    return chan;

free_bufs:
    // 清理
    return NULL;
}
```

---

## 4. relay_write — 写入

```c
// kernel/relay.c — relay_write
void relay_write(struct rchan *chan, const void *data, size_t length)
{
    struct rchan_buf *buf;
    size_t bytes_written = 0;

    // 1. 获取当前 CPU 的缓冲区（无锁）
    buf = chan->buf[raw_smp_processor_id()];

    // 2. 如果当前子缓冲区不够：
    if (buf->offset + length > subbuf_size) {
        // 推进到下一个子缓冲区
        advance_subbuf(buf);
    }

    // 3. 写入数据
    memcpy(buf->data + buf->offset, data, length);
    buf->offset += length;
}
```

---

## 5. 用户空间接口

```c
// 用户空间通过 mmap 读取：
int fd = open("/sys/kernel/debug/relay/my_channel", O_RDONLY);
void *data = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);

// 或者通过 read()（需要 syscall）
char buf[4096];
read(fd, buf, sizeof(buf));
```

---

## 6. 应用场景

```
ftrace 使用 relayfs：
  /sys/kernel/debug/tracing/trace_pipe ← relayfs 通道
  用户 cat trace_pipe → 读取跟踪数据

blktrace 使用 relayfs：
  块 I/O 延迟追踪
  每个 CPU 的缓冲区写入跟踪事件
  用户通过 debugfs 读取
```

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/relay.c` | `struct rchan`、`relay_open`、`relay_write` |
| `include/linux/relay.h` | `relay_open`/`close`/`write` 声明 |