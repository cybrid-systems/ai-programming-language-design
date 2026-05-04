# 099-relayfs — Linux relayfs 中继文件系统深度源码分析

## 0. 概述

**relayfs**（relay 文件系统）是一种从内核向用户空间高效传输大量数据的机制。内核写入端写入 per-CPU 缓冲区，用户空间通过文件接口读取，无需拷贝（直接映射内核缓冲区到用户空间）。

## 1. 核心结构

```c
struct rchan {
    const struct rchan_callbacks *cb;      // buf_start/buf_end/buf_consume/...
    struct kref             kref;
    unsigned int            subbuf_size;   // 子缓冲区大小
    unsigned int            n_subbufs;     // 子缓冲区数
    struct rchan_buf        **buf;         // per-CPU 缓冲区数组
    int                     is_global;     // 是否全局缓冲区
};

struct rchan_buf {
    struct rchan            *chan;
    void                    *padding;      // 对齐填充
    size_t                  subbuf_id;     // 当前子缓冲区 ID
    size_t                  data_avail;    // 可用数据
    struct dentry           *dentry;       // debugfs 文件
};
```

## 2. 使用模式

```c
// 内核端创建：
struct rchan *buf = relay_open("my_data", NULL, subbuf_size, n_subbufs, &relay_callbacks, NULL);

// 写入数据：
relay_write(buf, data, len);
// 或：
relay_reserve(buf, len) → 返回指向缓冲区的指针，直接写入
// 或使用 buf->data 直接写入（高性能路径）

// 用户端读取：
cat /sys/kernel/debug/my_data
// 或 mmap
```

## 3. 源码索引

| 符号 | 文件 |
|------|------|
| `relay_open()` | kernel/relay.c |
| `relay_write()` | kernel/relay.c |
| `relay_reserve()` | kernel/relay.c |
| `struct rchan` | include/linux/relay.h |
