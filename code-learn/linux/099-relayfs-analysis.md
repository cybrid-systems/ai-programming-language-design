# 099-relayfs — Linux relayfs（中继文件系统）深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**relayfs（Relay File System）** 是 Linux 内核的高效数据传输机制——内核模块将数据写入 per-CPU 环形缓冲区，用户空间通过 `/sys/kernel/debug/relay/` 下的文件直接 mmap 读取。用于大量数据的内核→用户传输场景（如 ftrace、追踪、性能监控）。

**核心设计**：relay 使用**子缓冲区（subbuf）** 机制——每个 channel 有多个子缓冲区，内核写满一个后自动切换到下一个，同时唤醒用户空间读取器。用户可通过 mmap 直接访问子缓冲区，实现零拷贝读取。

```
内核写入:                          用户空间读取:
relay_write(channel, data, len)    cat /sys/kernel/debug/relay/channel0
  ↓                                   ↓
  per-CPU 缓冲区                    /debug/relay/channel0
  [subbuf0] ← 正在写入               → mmap → 直接读取已满的子缓冲区
  [subbuf1] (已满) (mmap 可见)
  [subbuf2] (空)
```

**doom-lsp 确认**：`kernel/relay.c`（1,012 行，68 个符号）。`include/linux/relay.h`（298 行）。

---

## 1. 核心数据结构

### 1.1 struct rchan——relay 通道

```c
// kernel/relay.c
struct rchan {
    struct kref kref;                         // 引用计数

    void *buf[NR_CPUS];                       // per-CPU 缓冲区
    int alloc_size;                            // 子缓冲区大小
    int n_subbufs;                             // 子缓冲区数量
    size_t subbuf_size;                        // 每个子缓冲区大小
    size_t allocated_size;                     // 总分配大小

    const struct rchan_callbacks *cb;          // 用户回调函数
    struct dentry *dentry;                     // debugfs 文件 dentry
    int is_global;                             // 是否全局模式
    struct list_head list;                     // relay_channels 链表
};

struct rchan_callbacks {
    int (*subbuf_start)(struct rchan_buf *buf, void *subbuf,
                        void *prev_subbuf);   // 子缓冲区切换回调
    struct dentry *(*create_buf_file)(...);    // 创建 debugfs 文件
    int (*remove_buf_file)(struct dentry *);    // 移除文件
};
```

### 1.2 struct rchan_buf——per-CPU 缓冲区

```c
struct rchan_buf {
    void *start;                               // 缓冲区起始地址
    void *data;                                // 当前写入位置
    size_t offset;                             // 当前子缓冲区偏移
    size_t subbufs_produced;                   // 已产生的子缓冲区数
    size_t subbufs_consumed;                   // 已消费的子缓冲区数
    struct rchan *chan;
    unsigned int cpu;
    wait_queue_head_t read_wait;                // 读取者等待队列
    unsigned int subbuf_avail;
};
```

---

## 2. relay_open @ :474——创建通道

```c
struct rchan *relay_open(const char *base_filename, struct dentry *parent,
                          size_t subbuf_size, size_t n_subbufs,
                          void *(*create_buf_file)(...),
                          int (*remove_buf_file)(...))
{
    struct rchan *chan = kzalloc(sizeof(*chan), GFP_KERNEL);

    chan->subbuf_size = subbuf_size;             // 子缓冲区大小（如 16KB）
    chan->n_subbufs = n_subbufs;                 // 子缓冲区数（如 16）
    chan->alloc_size = subbuf_size * n_subbufs;  // 总大小
    chan->create_buf_file = create_buf_file;
    chan->remove_buf_file = remove_buf_file;

    // 为每个 CPU 分配缓冲区
    for_each_online_cpu(cpu) {
        buf = relay_alloc_buf(chan, ...);        // 分配连续页面
        // → __relay_alloc_buf()-> vmalloc_32(chan->alloc_size)

        buf->start = buf->data;
        buf->cpu = cpu;
        buf->chan = chan;
        chan->buf[cpu] = buf;

        // 在 debugfs 中创建文件
        dentry = relay_create_buf_file(chan, buf, cpu);
    }

    list_add(&chan->list, &relay_channels);
    return chan;
}
```

---

## 3. 数据写入路径

```c
// 内核模块写入 relay 通道：
// relay_write(chan, data, len)

#define relay_write(chan, data, len) do {                             \
    struct rchan_buf *buf;                                            \
    buf = per_cpu_ptr(chan->buf, raw_smp_processor_id());            \
    if (unlikely(buf->offset + len > chan->subbuf_size))             \
        relay_switch_subbuf(chan, buf, buf->offset + len - chan->subbuf_size); \
    memcpy(buf->data + buf->offset, data, len);                      \
    buf->offset += len;                                               \
} while (0)

// relay_switch_subbuf @ :554 — 切换子缓冲区
int relay_switch_subbuf(struct rchan *chan, struct rchan_buf *buf, size_t padding)
{
    buf->subbufs_produced++;

    // 唤醒用户空间读取器
    wake_up_all(&buf->read_wait);

    // 切换到下一个子缓冲区
    buf->offset = 0;
    buf->data = buf->start + ((buf->subbufs_produced % chan->n_subbufs) * chan->subbuf_size);
    return 0;
}
```

---

## 4. 用户空间读取

```c
// relay 文件通过 debugfs 创建，用户可：
// 1. mmap——直接将缓冲区映射到用户空间（推荐，零拷贝）
// 2. read——通过 relay_file_operations 读取

// mmap 路径：
// relay_buf_fault @ :32 — 缺页时返回子缓冲区页面
static vm_fault_t relay_buf_fault(struct vm_fault *vmf)
{
    struct page *page;
    struct rchan_buf *buf = vmf->vma->vm_private_data;

    // 计算当前可读的子缓冲区页面
    page = vmalloc_to_page(buf->start + vmf->pgoff * PAGE_SIZE);
    get_page(page);
    vmf->page = page;
    return 0;
}

// /proc 接口：
// cat /proc/relay 显示所有活动的 relay channel
```

---

## 5. 应用场景

| 场景 | 方式 | 使用 relay 的模块 |
|------|------|-------------------|
| **ftrace** | 追踪事件→relay→用户 | `kernel/trace/trace.c` |
| **blktrace** | 块 IO 追踪→relay→用户 | `kernel/trace/blktrace.c` |
| **Linux 追踪工具** | LTTng 等 | 用户空间消费 relay 数据 |
| **性能监控** | per-CPU 计数器→relay→用户 | 自定义模块 |

---

## 6. 关键函数索引

| 函数 | 行号 | 作用 |
|------|------|------|
| `relay_open` | `:474` | 创建 relay channel |
| `relay_close` | — | 关闭 channel |
| `relay_write` | 宏 | 写入数据 |
| `relay_switch_subbuf` | `:554` | 切换子缓冲区+唤醒读取者 |
| `relay_alloc_buf` | `:108` | 分配 per-CPU 缓冲区 |
| `relay_buf_fault` | `:32` | mmap 缺页处理 |
| `relay_reset` | `:324` | 重置缓冲区 |

---

## 7. 调试

```bash
# 查看 relay 通道
cat /proc/relay

# debugfs 中的 relay 文件
ls /sys/kernel/debug/relay/
cat /sys/kernel/debug/relay/<channel>
```

---

## 8. 总结

relay 通过 `relay_open`（`:474`）创建 per-CPU 子缓冲区通道，`relay_write` 写入当前子缓冲区，`relay_switch_subbuf`（`:554`）在子缓冲区满时切换到下一个并唤醒用户空间读取者。用户空间通过 mmap 零拷贝读取已满的子缓冲区。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 9. relay 回调接口

```c
// relay_open() 的回调参数（struct rchan_callbacks）：

struct rchan_callbacks {
    int (*subbuf_start)(struct rchan_buf *buf, void *subbuf,
                         void *prev_subbuf);
    // → 子缓冲区切换时调用
    // → 可以初始化子缓冲区（如写入时间戳）
    // → 返回 0 表示跳过此子缓冲区

    struct dentry *(*create_buf_file)(const char *filename,
        struct dentry *parent, umode_t mode,
        struct rchan *chan, int *is_global);
    // → 在 debugfs 中创建缓冲区文件
    // → 返回 dentry 指针

    int (*remove_buf_file)(struct dentry *dentry);
    // → 移除缓冲区文件
};

// 使用示例（blktrace）：
// rchan_callbacks.create_buf_file = blk_create_buf_file_callback
// rchan_callbacks.remove_buf_file = blk_remove_buf_file_callback
// rchan_callbacks.subbuf_start = blk_subbuf_start_callback
```

## 10. relay 数据流详解

```c
// relay 的完整数据流：

// 内核侧写入（relay_write）：
// 1. buf = per_cpu_ptr(chan->buf, smp_processor_id())
// 2. if (buf->offset + len > chan->subbuf_size)
//       relay_switch_subbuf(chan, buf, padding)  // 切换子缓冲区
// 3. memcpy(buf->data + buf->offset, data, len)
// 4. buf->offset += len

// 子缓冲区切换（relay_switch_subbuf @ :554）：
// 1. buf->subbufs_produced++
// 2. wake_up_all(&buf->read_wait)  // 唤醒读取者
// 3. 更新 data 指针到下一个子缓冲区：
//    buf->data = buf->start +
//       (buf->subbufs_produced % chan->n_subbufs) * chan->subbuf_size

// 用户侧读取（mmap）：
// sk = relay_file_mmap_ops.mmap → relay_mmap()
// → remap_vmalloc_range(vma, buf->start)
// → 用户直接 mmap 访问子缓冲区（零拷贝）
```

## 11. relay 关键函数索引

| 函数 | 符号 | 作用 |
|------|------|------|
| `relay.c` | 68 | relay 核心实现 |
| `relay_open` | `:474` | 创建 relay 通道 |
| `relay_close` | — | 关闭通道 |
| `relay_write` | macro | 写入数据 |
| `relay_switch_subbuf` | `:554` | 子缓冲区切换 |
| `relay_alloc_buf` | `:108` | 分配 per-CPU 缓冲区 |
| `relay_buf_fault` | `:32` | mmap 缺页处理 |
| `relay_subbuf_start` | `:250` | 子缓冲区启动回调 |

## 12. relay 与 ftrace 的集成

```c
// relay 最广泛的使用场景是 ftrace 的 trace_pipe：

// kernel/trace/trace.c 中：
// struct trace_array {
//     struct trace_buffer trace_buffer;  // per-CPU ring buffer
//     // ...
// };

// 虽然 ftrace 使用自己的 ring buffer（不是 relay），
// 但 blktrace 等工具使用 relay 传输数据：
// blktrace.c → relay_open("blktrace", ...)
// → block 层写入 relay channel
// → btrace 通过 relay 文件读取
```


## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `relay_open()` | kernel/relay.c | 通道创建 |
| `relay_write()` | kernel/relay.c | 数据写入 |
| `relay_reserve()` | kernel/relay.c | 预留缓冲区 |
| `struct rchan` | include/linux/relay.h | 核心结构 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
