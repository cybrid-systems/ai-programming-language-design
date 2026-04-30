# Linux Kernel relayfs (relay) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/relay.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. relayfs 概述

**relayfs** 是内核向用户空间传递**高频日志/事件数据**的高速通道（零拷贝、环形缓冲），ftrace 底层就用 relayfs。

---

## 1. 核心概念

```
用户空间 mmap 映射 relay channel
        ↓
内核写入 relay channel（ring buffer）
        ↓
用户空间直接读取（mmap），无需 syscall
```

---

## 2. 核心结构

```c
// kernel/relay.c — rchan
struct rchan {
    struct rchan_buf    *buf[NR_CPUS];   // 每 CPU 一个缓冲区
    struct dentry       *parent;          // debugfs 目录
    size_t              alloc_size;      // 每 CPU 缓冲区大小
    size_t              subbuf_size;      // 子缓冲区大小
    size_t              n_subbufs;        // 子缓冲区数量
    unsigned int        curr_cpu;         // 当前 CPU
};

// rchan_buf — 每 CPU 环形缓冲
struct rchan_buf {
    void                 *start;         // 缓冲起始地址
    void                 *data;          // 当前写位置
    size_t               alloc_bytes;     // 已分配字节
    size_t               padding[4];
    struct page          **page_array;    // 页数组
};
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `kernel/relay.c` | `relay_open`、`relay_write`、`relay_close` |
| `include/linux/relay.h` | relay channel API |
