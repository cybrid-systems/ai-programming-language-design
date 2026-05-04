# 082-pipe-splice-vmsplice — Linux 管道和零拷贝 splice/vmsplice 深度源码分析

> 基于 Linux 7.0-rc1 主线源码 | 使用 doom-lsp 进行逐行符号解析

## 0. 概述

**pipe**（管道）是 Linux 最古老的进程间通信机制，**splice/vmsplice** 是在管道基础上实现的零拷贝数据传输系统调用。splice 在两个文件描述符之间传输数据而无需用户空间缓冲，vmsplice 将用户空间内存页直接映射到管道。

**doom-lsp 确认**：`fs/pipe.c`（pipe 核心），`fs/splice.c`（splice/vmsplice 实现）。

---

## 1. 核心数据结构

### 1.1 `struct pipe_inode_info`——管道实例

```c
struct pipe_inode_info {
    struct mutex            mutex;          // 保护管道操作
    wait_queue_head_t       rd_wait;        // 读等待队列
    wait_queue_head_t       wr_wait;        // 写等待队列
    unsigned int            head;           // 环形缓冲区 head（最新写入位置）
    unsigned int            tail;           // 环形缓冲区 tail（最早未读位置）
    unsigned int            max_usage;      // 最大使用缓冲数
    unsigned int            ring_size;      // 环形缓冲区大小
    bool                    note_loss;      // 写入丢失通知
    struct pipe_buffer      *bufs;          // 环形缓冲区数组
    ...
};
```

### 1.2 `struct pipe_buffer`——缓冲区条目

```c
struct pipe_buffer {
    struct page             *page;          // 物理页
    unsigned int            offset;         // 页内偏移
    unsigned int            len;            // 数据长度
    const struct pipe_buf_operations *ops;  // 操作（release/confirm/steal）
    unsigned int            flags;          // PIPE_BUF_FLAG_*
    struct page             *page2;         // 零拷贝使用的第二个页
};
```

## 2. 数据流

### 2.1 管道写

```
sys_write(fd[1], buf, len)
  └─ pipe_write(file, buf, len, ppos)
       └─ 获取 pipe_inode_info
       └─ 在环形缓冲区分配新条目：
            pipe->bufs[head].page = alloc_page(GFP_HIGHUSER)
            page = pipe->bufs + head
            page->page = alloc_page()
            copy_page_from_iter(buf, page, offset)
            pipe->head++
       └─ wake_up(&pipe->rd_wait)  // 唤醒读端
```

### 2.2 管道读

```
sys_read(fd[0], buf, len)
  └─ pipe_read(file, buf, len, ppos)
       └─ while (tail < head):
            page = pipe->bufs[tail]
            copy_page_to_iter(page->page, buf, page->offset, len)
            pipe->tail++               // 消费条目
       └─ wake_up(&pipe->wr_wait)     // 唤醒写端
```

### 2.3 splice——零拷贝

```
splice(fd_in, off_in, fd_out, off_out, len, flags)
  └─ 读端：generic_file_splice_read()
       → 将文件页缓存中的 page 直接插入 pipe buffer
       → 不拷贝，只增加 page 引用计数
  └─ 写端：splice_write()
       → 从 pipe buffer 取出 page
       → 直接写入目标 fd（如 socket）
       → 引用计数减 1

  零拷贝的关键：splice 在文件页缓存和 socket 之间通过 pipe 传递 page，全程无数据拷贝。
```

### 2.4 vmsplice——用户空间页注入

```
vmsplice(fd, iov, nr_segs, flags)
  └─ 将用户空间页面通过 get_user_pages_fast() 锁定
  └─ 直接插入 pipe buffer（不需要拷贝到内核空间）
  └─ 接收端通过 splice 从 pipe 读取并写入文件/设备
```

## 3. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct pipe_inode_info` | include/linux/pipe_fs_i.h | 核心 |
| `pipe_write()` | fs/pipe.c | 相关 |
| `pipe_read()` | fs/pipe.c | 相关 |
| `sys_splice()` | fs/splice.c | syscall |
| `generic_file_splice_read()` | fs/splice.c | 零拷贝读 |
| `splice_write()` | fs/splice.c | 零拷贝写 |
| `sys_vmsplice()` | fs/splice.c | 用户页注入 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
