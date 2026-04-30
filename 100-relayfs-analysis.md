# relayfs — 高速日志传输深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/relay.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**relayfs** 提供高速内核到用户空间的数据传输通道，用于 tracepoints（ftrace、blktrace）和性能分析工具。

---

## 1. 核心概念

```
relayfs 工作原理：
  - 内核分配环形缓冲区（per-CPU）
  - 多个读端可并发读取（无锁）
  - 用户空间通过 mmap 访问缓冲区
  - 写入无需系统调用（零拷贝）
```

---

## 2. relay_open — 打开通道

```c
// kernel/relay.c — relay_open
struct rchan *relay_open(const char *filename, size_t subbuf_size, size_t n_subbufs, ...)
{
    struct rchan *chan;
    struct dentry *parent;

    // 1. 分配 channel
    chan = kzalloc(sizeof(*chan), GFP_KERNEL);

    // 2. 创建 debugfs 文件
    parent = debugfs_create_dir(filename, NULL);

    // 3. 为每个 CPU 分配缓冲区
    for_each_possible_cpu(cpu) {
        chan->buf[cpu] = alloc_buf(subbuf_size, n_subbufs);
    }

    return chan;
}
```

---

## 3. relay_write — 写入

```c
// kernel/relay.c — relay_write
void relay_write(struct rchan *chan, const void *data, size_t len)
{
    struct rchan_buf *buf = get_buf(chan, get_cpu());

    // 1. 如果空间不够，跳到下一个子缓冲区
    if (buf->offset + len > subbuf_size) {
        advance_subbuf(buf);
    }

    // 2. 写入数据
    memcpy(buf->data + buf->offset, data, len);
    buf->offset += len;

    put_cpu();
}
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/relay.c` | `relay_open`、`relay_write` |