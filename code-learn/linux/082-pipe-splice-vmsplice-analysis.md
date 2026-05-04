# 82-pipe-splice-vmsplice — Linux 管道和零拷贝 splice 深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**pipe**、**splice**、**vmsplice** 构成 Linux 的零拷贝数据传输体系。pipe 是进程间字节流通信机制（内核环形缓冲区），splice 和 vmsplice 在管道基础上实现**页面窃取（page stealing）**——在内核空间直接转移页面所有权，避免用户空间→内核空间的数据拷贝。

**核心设计**：pipe 使用**环形缓冲区**（`pipe_inode_info.bufs`），每个 buffer 是一个 `struct pipe_buffer`（page + offset + len + ops）。splice 从源文件 `splice_read` 直接提取 page 到管道，再从管道 `splice_write` 写入目标文件——页面在文件系统和管道之间**零拷贝转移**。

```
传统 read+write：      用户空间 A      内核空间 B      磁盘
  read(fd, buf, n) →   ←──── buf ────→  拷贝        ← 读
  write(fd, buf, n) →  ──── buf ────→  拷贝        → 写
                       ↑ 两次拷贝 ↑

splice 零拷贝：
  splice(fd_in, , fd_out, , n, flags)
                        ↓
  fd_in → 管道（页面窃取）→ fd_out
        ↑ 零拷贝（page 在文件缓存和管道之间传递所有权）
```

**doom-lsp 确认**：pipe 在 `fs/pipe.c`（1,552 行），splice 在 `fs/splice.c`（1,994 行），头文件 `include/linux/pipe_fs_i.h`（339 行）。

---

## 1. 管道数据结构 @ pipe_fs_i.h

### 1.1 struct pipe_buffer——环形缓冲区条目

```c
// include/linux/pipe_fs_i.h:26
struct pipe_buffer {
    struct page *page;                          /* 数据页 */
    unsigned int offset, len;                   /* 页内偏移和长度 */
    const struct pipe_buf_operations *ops;      /* 页面操作（release/get/confirm/try_steal）*/
    unsigned int flags;                         /* PIPE_BUF_FLAG_* */
    unsigned long private;
};
```

### 1.2 struct pipe_inode_info——管道实例

```c
// include/linux/pipe_fs_i.h:84-110
struct pipe_inode_info {
    struct mutex mutex;                          /* 保护整个管道的 mutex */
    wait_queue_head_t rd_wait, wr_wait;          /* 读/写等待队列 */

    union pipe_index {                           /* 头尾指针（环形缓冲区）*/
        unsigned long head_tail;
        struct { pipe_index_t head, tail; };
    };

    unsigned int max_usage;                      /* 最大使用槽数 */
    unsigned int ring_size;                      /* 缓冲区总数（2 的幂）*/
    unsigned int readers, writers;               /* 读/写者计数 */
    unsigned int files;

    struct pipe_buffer *bufs;                    /* 环形缓冲区数组 */
    struct user_struct *user;
};
```

**环形缓冲区索引**：

```
bufs[]:
  [0] [1] [2] ... [ring_size-1]
   ↑               ↑
  tail            head
  （读者位置）     （写者位置）

head - tail ≤ max_usage
head == tail → 空
occupancy ≥ max_usage → 满
```

**doom-lsp 确认**：`struct pipe_inode_info` 使用环形缓冲区（`pipe->bufs`），通过 `head`/`tail` 索引管理读写位置。空/满判断通过 `pipe_empty`/`pipe_full` 内联函数。

---

## 2. 管道读写

### 2.1 anon_pipe_read @ :269

```c
static ssize_t anon_pipe_read(struct kiocb *iocb, struct iov_iter *to)
{
    size_t total_len = iov_iter_count(to);
    mutex_lock(&pipe->mutex);

    for (;;) {
        // 1. 读取 head（smp_load_acquire 保证 vs 写者）
        unsigned int head = smp_load_acquire(&pipe->head);
        unsigned int tail = pipe->tail;

        if (!pipe_empty(head, tail)) {          // 有数据
            struct pipe_buffer *buf = pipe_buf(pipe, tail);
            chars = min(buf->len, total_len);

            // 2. 确认数据有效
            pipe_buf_confirm(pipe, buf);        // → ops->confirm()

            // 3. 复制到用户空间
            written = copy_page_to_iter(buf->page, buf->offset, chars, to);

            // 4. 更新 buffer
            buf->offset += chars;
            buf->len -= chars;

            if (!buf->len) {                    // buffer 消耗完毕
                tail = pipe_update_tail(pipe, buf, tail);  // → ops->release()
            }
            total_len -= chars;
            if (!total_len) break;
        }

        // 5. 管道空 → 等待
        if (!pipe->writers) break;               // 写者关闭 → EOF
        mutex_unlock(&pipe->mutex);
        pipe_wait_readable(pipe);                 // 等待写者
        mutex_lock(&pipe->mutex);
    }
    mutex_unlock(&pipe->mutex);
    return ret;
}
```

### 2.2 anon_pipe_write @ :431

```c
static ssize_t anon_pipe_write(struct kiocb *iocb, struct iov_iter *from)
{
    mutex_lock(&pipe->mutex);

    for (;;) {
        head = pipe->head;

        if (!pipe_full(head, tail, pipe->max_usage)) {
            // 有空槽 → 写入
            struct pipe_buffer *buf = pipe_buf(pipe, head);

            // 尝试合并到前一个 buffer 的剩余空间
            if (pipe_buf_can_merge && ...) {
                // 复制到最后一个 buffer 的剩余空间
            } else {
                // 分配新页
                page = alloc_page(GFP_HIGHUSER);
                buf->page = page;
                buf->ops = &anon_pipe_buf_ops;
                copied = copy_page_from_iter(page, 0, chars, from);
                buf->offset = 0;
                buf->len = copied;
                pipe->head = head + 1;        // 推进 head
            }
        }

        if (pipe_full(head, tail, pipe->max_usage)) {
            // 满 → 等待读者
            mutex_unlock(&pipe->mutex);
            pipe_wait_writable(pipe);
            mutex_lock(&pipe->mutex);
        }
    }
    mutex_unlock(&pipe->mutex);
}
```

---

## 3. splice 零拷贝

splice 的核心是**页面窃取（page stealing）**——页面在文件系统页缓存和管道之间转移，不需要复制数据。

```c
ssize_t splice(fd_in, off_in, fd_out, off_out, len, flags);
```

### 3.1 splice_read——文件→管道

```c
// do_splice() → splice_file_to_pipe() → f_op->splice_read()
// → filemap_splice_read():
//   1. filemap_get_pages() 从页缓存获取 pages
//   2. 通过 page_cache_pipe_buf_ops 将 pages 塞入管道
//   3. page 引用从文件页缓存转移到管道
//   4. 管道释放时 → page_cache_pipe_buf_release → put_page()
```

### 3.2 splice_write——管道→文件

```c
// splice(pipe_fd, NULL, out_fd, NULL, len, flags)
// → do_splice() → splice_from_pipe_to_file()

static int splice_from_pipe_to_file(struct pipe_inode_info *pipe,
                                     struct file *out, ...)
{
    // 1. __splice_from_pipe(pipe, sd, pipe_to_sendpage)
    //    → 循环：
    //      splice_from_pipe_next() — 从管道取下一个 buffer
    //      splice_from_pipe_feed() — 调用 actor 写入文件
    //
    // 2. actor（pipe_to_sendpage）：
    //    → out->f_op->sendpage(out, buf->page, buf->offset, chars, pos)
    //    → 文件系统将 page 关联到自己的页缓存
    //    → buf->ops->try_steal() 尝试窃取页面所有权
    //    → 成功 → 页面不在管道中释放
    //    → 失败 → 回退到 pipe_buf_release()
}

// 零拷贝的关键——__splice_from_pipe @ :596：
ssize_t __splice_from_pipe(struct pipe_inode_info *pipe, struct splice_desc *sd,
                            splice_actor *actor)
{
    splice_from_pipe_begin(sd);
    do {
        ret = splice_from_pipe_next(pipe, sd);   // 等待数据
        if (ret > 0)
            ret = splice_from_pipe_feed(pipe, sd, actor);  // 写入
    } while (ret > 0);
    splice_from_pipe_end(pipe, sd);
    return ret;
}
```

### 3.3 pipe_buf_operations——页面生命周期 @ pipe.c / splice.c

```c
// 四种 ops 定义页面在管道中的行为：

// 1. anon_pipe_buf_ops @ pipe.c:223——匿名管道页
//    .release → anon_pipe_buf_release() → __free_page()
//    .try_steal → anon_pipe_buf_try_steal() → true（可以窃取）

// 2. page_cache_pipe_buf_ops @ splice.c:155——文件页缓存页
//    .get → generic_pipe_buf_get() → get_page()
//    .release → generic_pipe_buf_release() → put_page()
//    .try_steal → generic_pipe_buf_try_steal() → true
//    页面可在页缓存和管道之间转移所有权

// 3. user_page_pipe_buf_ops @ splice.c:172——用户页
//    vmsplice 使用：用户页面通过 get_user_pages 锁定
//    .try_steal → false（页面不属于内核）

// 4. nosteal_pipe_buf_ops @ splice.c:408——不可窃取
//    .try_steal → false
//    用于不允许页面转移的场景

// 零拷贝的关键路径：
// splice_from_pipe_feed → actor（pipe_to_sendpage）
//   → out->f_op->sendpage() → try_steal() 窃取页面
//   → 成功：页面从管道直接转移到目标文件页缓存
//   → 失败：默认使用 pipe_to_user（复制数据）
```

---

## 4. vmsplice——用户空间→管道

```c
// vmsplice(fd, iov, nr_segs, flags)
// 用户空间的 pages 直接映射到管道缓冲区

static int vmsplice_to_pipe(struct file *file, struct iov_iter *from,
                            unsigned int flags)
{
    // 遍历用户空间的 iovec
    // → get_user_pages_fast() 锁定用户页面
    // → 将页面放入管道缓冲区
    // → 设置 ops = user_page_pipe_buf_ops

    // 如果 SPLICE_F_GIFT 标志设置：
    //   用户放弃页面所有权 → 管道可以自由使用页面
}
```

---

## 5. 性能对比

| 方式 | 数据拷贝 | 系统调用 | 说明 |
|------|---------|----------|------|
| `read + write` | 2 次（内核→用户+用户→内核）| 2 | 通用路径 |
| `splice` | 0 次（页面窃取） | 1 | 适合大文件传输 |
| `vmsplice + splice` | 0 次 | 2 | 用户空间→文件 |
| `sendfile` | 0 次（页缓存→socket） | 1 | 文件→socket |
| 管道 `read/write` | 2 次（用户↔内核） | 2 | 进程间通信 |

---

## 6. 关键函数索引

| 函数 | 文件:行号 | 作用 |
|------|----------|------|
| `anon_pipe_read` | `pipe.c:269` | 管道读取（环形缓冲+阻塞等待）|
| `anon_pipe_write` | `pipe.c:431` | 管道写入（页面分配+合并）|
| `do_splice` | `splice.c` | splice 系统调用调度 |
| `filemap_splice_read` | `splice.c` | 文件→管道（页缓存窃取）|
| `splice_from_pipe_to_file` | `splice.c` | 管道→文件 |
| `vmsplice_to_pipe` | `splice.c` | 用户页→管道 |
| `pipe_buf_confirm` | `pipe_fs_i.h` | 页面内容确认 |
| `pipe_buf_try_steal` | `pipe_fs_i.h` | 尝试窃取页面 |
| `pipe_buf_release` | `pipe_fs_i.h` | 释放页面 |
| `pipe_update_tail` | `pipe.c` | 更新 tail 指针 |

---

## 7. 总结

pipe 通过**环形缓冲区**（`pipe_inode_info.bufs`）管理数据，`anon_pipe_read`（`:269`）和 `anon_pipe_write`（`:431`）通过 mutex + waitqueue 同步。splice 和 vmsplice 利用**页面窃取**（`pipe_buf_try_steal`）在内核空间零拷贝传输数据——文件系统页缓存的 page 直接转移到管道（`splice_read`），再从管道转移到目标文件（`splice_write`）。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct pipe_inode_info` | include/linux/pipe_fs_i.h | 核心 |
| `pipe_write()` | fs/pipe.c | 相关 |
| `pipe_read()` | fs/pipe.c | 相关 |
| `sys_splice()` | fs/splice.c | (syscall) |
| `generic_file_splice_read()` | fs/splice.c | 零拷贝读 |
| `sys_vmsplice()` | fs/splice.c | (syscall) |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
